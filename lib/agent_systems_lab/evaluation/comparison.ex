defmodule AgentSystemsLab.Evaluation.Comparison do
  @moduledoc """
  Paired regression gates for reports from the same evaluation protocol.

  Quality and cost gates run for the whole suite and for every task, so an
  improvement elsewhere cannot conceal a regression. Latency must cross both
  relative and absolute noise guards. Incomplete accounting or scoring is an
  explicit indeterminate gate failure, never a zero-cost success.
  """

  alias AgentSystemsLab.Evaluation.Report

  @defaults [
    success_drop_pp: 0,
    cost_increase_pct: 0,
    cost_increase_units: 0,
    latency_increase_pct: 25,
    latency_increase_us: 50_000
  ]

  def compare(baseline, candidate, opts \\ []) do
    with :ok <- Report.validate(baseline),
         :ok <- Report.validate(candidate),
         {:ok, thresholds} <- thresholds(opts),
         :ok <- compatible(baseline, candidate) do
      checks = checks(baseline["summary"], candidate["summary"], thresholds)
      baseline_tasks = Map.new(baseline["by_task"], &{&1["task_id"], &1})

      tasks =
        Enum.map(candidate["by_task"], fn task ->
          task_checks = checks(baseline_tasks[task["task_id"]], task, thresholds)

          %{
            "task_id" => task["task_id"],
            "passed" => passed?(task_checks),
            "status" => status(task_checks),
            "checks" => task_checks
          }
        end)

      all_checks = checks ++ Enum.flat_map(tasks, & &1["checks"])
      passed = passed?(all_checks)

      {:ok,
       %{
         "schema_version" => 1,
         "baseline_report_hash" => baseline["report_hash"],
         "candidate_report_hash" => candidate["report_hash"],
         "baseline_profile" => baseline["manifest"]["profile"],
         "candidate_profile" => candidate["manifest"]["profile"],
         "protocol_hash" => Report.hash(baseline["manifest"]["protocol"]),
         "thresholds" => thresholds,
         "passed" => passed,
         "regressed" => not passed,
         "status" => status(all_checks),
         "checks" => checks,
         "by_task" => tasks,
         "paired_changes" => paired_changes(baseline["samples"], candidate["samples"])
       }}
    end
  rescue
    _ -> {:error, {:invalid_comparison, :malformed_value}}
  end

  defp compatible(baseline, candidate) do
    old = baseline["manifest"]["protocol"]
    new = candidate["manifest"]["protocol"]

    mismatched =
      old
      |> Map.keys()
      |> Enum.filter(&(old[&1] !== new[&1]))
      |> Enum.sort()

    if mismatched == [], do: :ok, else: {:error, {:incompatible_protocol, mismatched}}
  end

  defp thresholds(opts) do
    keys = Keyword.keys(@defaults)

    if is_list(opts) and Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in keys)) do
      merged = Keyword.merge(@defaults, opts)

      valid =
        Enum.all?(merged, fn
          {:success_drop_pp, value} ->
            number_in?(value, 0, 100)

          {key, value} when key in [:cost_increase_pct, :latency_increase_pct] ->
            number_in?(value, 0, 100_000)

          {_key, value} ->
            is_integer(value) and value >= 0 and value <= 1_000_000_000_000_000
        end)

      if valid,
        do: {:ok, Map.new(merged, fn {key, value} -> {Atom.to_string(key), value} end)},
        else: {:error, {:invalid_comparison, :thresholds}}
    else
      {:error, {:invalid_comparison, :options}}
    end
  end

  defp checks(old, new, threshold) do
    quality = %{
      "metric" => "success_rate_pct",
      "baseline" => old["success_rate_pct"],
      "candidate" => new["success_rate_pct"],
      "delta" => new["success_rate_pct"] - old["success_rate_pct"],
      "allowed_drop_pp" => threshold["success_drop_pp"],
      "status" =>
        if(old["success_rate_pct"] - new["success_rate_pct"] > threshold["success_drop_pp"],
          do: "regressed",
          else: "passed"
        )
    }

    errors = fn summary ->
      summary["classification_counts"]["scorer_error"] +
        summary["classification_counts"]["harness_error"]
    end

    score_health = %{
      "metric" => "scoring_and_harness_errors",
      "baseline" => errors.(old),
      "candidate" => errors.(new),
      "status" => if(errors.(old) + errors.(new) == 0, do: "passed", else: "indeterminate")
    }

    cost_complete = old["cost"]["complete"] and new["cost"]["complete"]

    cost =
      if cost_complete do
        increase(
          "cost.total_units",
          old["cost"]["total_units"],
          new["cost"]["total_units"],
          threshold["cost_increase_pct"],
          threshold["cost_increase_units"]
        )
      else
        %{
          "metric" => "cost.total_units",
          "baseline" => old["cost"]["total_units"],
          "candidate" => new["cost"]["total_units"],
          "baseline_unknown_samples" => old["cost"]["unknown_count"],
          "candidate_unknown_samples" => new["cost"]["unknown_count"],
          "status" => "indeterminate"
        }
      end

    latency =
      for scope <- ~w(execution scoring total), quantile <- ~w(p50 p95) do
        increase(
          "latency_us.#{scope}.#{quantile}",
          old["latency_us"][scope][quantile],
          new["latency_us"][scope][quantile],
          threshold["latency_increase_pct"],
          threshold["latency_increase_us"]
        )
      end

    [quality, score_health, cost | latency]
  end

  defp increase(metric, old, new, relative, absolute) do
    delta = new - old
    relative_delta = if old == 0, do: nil, else: delta * 100 / old
    relative_crossed = if old == 0, do: delta > 0, else: delta * 100 > old * relative
    absolute_crossed = delta > absolute

    %{
      "metric" => metric,
      "baseline" => old,
      "candidate" => new,
      "delta" => delta,
      "increase_pct" => relative_delta,
      "zero_baseline" => old == 0,
      "allowed_increase_pct" => relative,
      "allowed_increase_absolute" => absolute,
      "relative_guard_crossed" => relative_crossed,
      "absolute_guard_crossed" => absolute_crossed,
      "status" => if(relative_crossed and absolute_crossed, do: "regressed", else: "passed")
    }
  end

  defp paired_changes(baseline, candidate) do
    old = Map.new(baseline, &{{&1["task_id"], &1["trial"]}, &1})

    Enum.map(candidate, fn new ->
      previous = old[{new["task_id"], new["trial"]}]

      change =
        cond do
          previous["task_success"] and not new["task_success"] ->
            "regressed"

          not previous["task_success"] and new["task_success"] ->
            "improved"

          previous["classification"] != new["classification"] or
              previous["failure_class"] != new["failure_class"] ->
            "changed_failure"

          true ->
            "unchanged"
        end

      %{
        "task_id" => new["task_id"],
        "trial" => new["trial"],
        "baseline_success" => previous["task_success"],
        "candidate_success" => new["task_success"],
        "baseline_classification" => previous["classification"],
        "candidate_classification" => new["classification"],
        "baseline_failure_class" => previous["failure_class"],
        "candidate_failure_class" => new["failure_class"],
        "outcome_change" => change,
        "semantic_result_changed" =>
          previous["semantic_result_hash"] != new["semantic_result_hash"],
        "usage_changed" => previous["usage"] != new["usage"]
      }
    end)
  end

  defp passed?(checks), do: Enum.all?(checks, &(&1["status"] == "passed"))

  defp status(checks) do
    cond do
      Enum.any?(checks, &(&1["status"] == "regressed")) -> "regressed"
      Enum.any?(checks, &(&1["status"] == "indeterminate")) -> "indeterminate"
      true -> "passed"
    end
  end

  defp number_in?(value, min, max), do: is_number(value) and value >= min and value <= max
end
