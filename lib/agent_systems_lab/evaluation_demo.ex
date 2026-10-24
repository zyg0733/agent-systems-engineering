defmodule AgentSystemsLab.EvaluationDemo do
  @moduledoc "Offline acceptance of complete evaluations, paired replay and visible regressions."
  alias AgentSystemsLab.{Evaluation, Observability}
  alias AgentSystemsLab.Evaluation.{Comparison, Runner, Scorer}

  @cohorts ~w(dev-baseline dev-repeat dev-regressed holdout-baseline holdout-repeat holdout-regressed)
  @checks ~w(reproducibility regression_gate protocol_guards readonly_compare)
  @repeat_invariants ~w(success_rate_pct scoring_and_harness_errors cost.total_units)
  @repeat_latencies for scope <- ~w(execution scoring total),
                        quantile <- ~w(p50 p95),
                        do: "latency_us.#{scope}.#{quantile}"
  def cases, do: @cohorts ++ @checks

  @doc false
  def repeat_invariants?(comparison) do
    with %{"schema_version" => 1, "by_task" => tasks, "paired_changes" => pairs} <- comparison,
         true <- is_list(tasks) and tasks != [] and is_list(pairs) and pairs != [],
         ids = Enum.map(tasks, & &1["task_id"]),
         true <- Enum.all?(ids, &(is_binary(&1) and &1 != "")),
         true <- length(ids) == length(Enum.uniq(ids)),
         true <- Enum.sort(ids) == Enum.sort(Enum.uniq(Enum.map(pairs, & &1["task_id"]))),
         true <- repeat_checks?(comparison["checks"]),
         true <-
           Enum.all?(tasks, fn task ->
             repeat_checks?(task["checks"]) and repeat_flags?(task, task["checks"])
           end),
         all_checks = comparison["checks"] ++ Enum.flat_map(tasks, & &1["checks"]),
         true <- repeat_flags?(comparison, all_checks),
         true <- comparison["regressed"] === not comparison["passed"] do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp repeat_checks?(checks) when is_list(checks) do
    metrics = Enum.map(checks, & &1["metric"])

    Enum.sort(metrics) == Enum.sort(@repeat_invariants ++ @repeat_latencies) and
      Enum.all?(checks, fn check ->
        known_values =
          is_number(check["baseline"]) and check["baseline"] >= 0 and
            is_number(check["candidate"]) and check["candidate"] >= 0

        known_values and
          if(check["metric"] in @repeat_invariants,
            do: check["status"] == "passed",
            else: check["status"] in ["passed", "regressed"]
          )
      end)
  end

  defp repeat_checks?(_), do: false

  defp repeat_flags?(%{"passed" => passed, "status" => status}, checks) do
    all_passed = Enum.all?(checks, &(&1["status"] == "passed"))
    passed === all_passed and status == if(all_passed, do: "passed", else: "regressed")
  end

  defp repeat_flags?(_, _), do: false

  def run(opts \\ []) do
    with :ok <- options(opts),
         true <-
           Application.get_env(:agent_systems_lab, :database_enabled, true) ||
             {:error, :database_required},
         false <-
           Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
             is_pid(Process.whereis(AgentSystemsLab.Scheduler)),
         output =
           Path.expand(Keyword.get(opts, :output, "artifacts/week20-evaluation-acceptance")),
         :ok <- create_directory(output) do
      context = %{output: output}

      save(context, %{
        "schema_version" => 1,
        "all_passed" => false,
        "case_count" => 0,
        "expected_case_count" => 10,
        "cases" => [],
        "active_case" => nil,
        "failed_case" => nil
      })

      execute(context, opts)
    else
      value when value not in [:ok] and not is_tuple(value) -> {:error, :global_scheduler_enabled}
      error -> error
    end
  end

  defp execute(context, opts) do
    try do
      reports =
        Enum.reduce(@cohorts, %{}, fn name, acc ->
          {result, _summary} =
            step(context, opts, name, fn ->
              [split, variant] = String.split(name, "-")

              config = [
                output: Path.join(context.output, name),
                split: split,
                repetitions: 2,
                profile: if(variant == "regressed", do: "regressed", else: "reference")
              ]

              config =
                if variant == "baseline",
                  do: config,
                  else:
                    Keyword.put(
                      config,
                      :baseline,
                      Path.join([context.output, split <> "-baseline", "report.json"])
                    )

              {:ok, result} = Evaluation.run(config)

              check(
                result.report["summary"]["planned_samples"] ==
                  if(String.starts_with?(name, "dev"), do: 12, else: 8),
                "coverage differs"
              )

              {result.report,
               %{
                 "cohort" => name,
                 "report_hash" => result.report["report_hash"],
                 "summary" => result.report["summary"],
                 "semantic_signature" => result.report["semantic_signature"],
                 "run_ids" => Enum.map(result.report["samples"], & &1["run_id"]),
                 "comparison_status" => if(result.comparison, do: result.comparison["status"])
               }}
            end)

          Map.put(acc, name, result)
        end)

      step(context, opts, "reproducibility", fn ->
        checks =
          for split <- ~w(dev holdout) do
            a = reports[split <> "-baseline"]
            b = reports[split <> "-repeat"]

            check(
              a["semantic_signature"] == b["semantic_signature"],
              "repeat semantic signature differs"
            )

            check(a["summary"]["cost"] == b["summary"]["cost"], "repeat charged cost differs")
            check(MapSet.disjoint?(ids(a), ids(b)), "repeat reused a Run")
            {:ok, comparison} = Comparison.compare(a, b)

            check(
              repeat_invariants?(comparison),
              "same-profile replay breached semantic, cost or measurement-completeness guards"
            )

            %{
              "split" => split,
              "semantic_signature_equal" => true,
              "cost_equal" => true,
              "fresh_runs" => true,
              "semantic_cost_gate_passed" => true,
              "latency_reproducibility_claimed" => false,
              "comparison_passed" => comparison["passed"],
              "comparison_status" => comparison["status"]
            }
          end

        {nil,
         %{
           "splits" => checks,
           "semantic_cost_gate_passed" => true,
           "latency_reproducibility_claimed" => false
         }}
      end)

      step(context, opts, "regression_gate", fn ->
        checks =
          for split <- ~w(dev holdout) do
            {:ok, comparison} =
              Comparison.compare(reports[split <> "-baseline"], reports[split <> "-regressed"])

            check(
              not comparison["passed"] and comparison["status"] == "regressed",
              "regression was hidden"
            )

            %{
              "split" => split,
              "status" => comparison["status"],
              "regressed_tasks" => Enum.count(comparison["by_task"], &(not &1["passed"]))
            }
          end

        budget_samples =
          Enum.filter(reports["dev-regressed"]["samples"], &(&1["failure_class"] == "budget"))

        check(length(budget_samples) == 2, "budget failures lost from denominator")

        raw =
          Path.join([context.output, "dev-regressed", "dev-bounded-response-1.sample.json"])
          |> read()

        check(
          raw["status"] == "failed" and raw["grade"]["passed"] == true,
          "artifact pass bypassed runtime failure"
        )

        {nil, %{"splits" => checks, "budget_failed_despite_correct_artifact" => true}}
      end)

      step(context, opts, "protocol_guards", fn ->
        baseline = reports["dev-baseline"]

        {:error, {:incompatible_protocol, _}} =
          Comparison.compare(baseline, reports["holdout-baseline"])

        corrupt = put_in(baseline, ["summary", "successful_samples"], 0)
        corrupt_path = Path.join(context.output, "corrupt-baseline.json")
        write(corrupt_path, corrupt)
        {:error, _} = Evaluation.read_report(corrupt_path)
        target = Path.join(context.output, "must-not-run")
        {:error, _} = Evaluation.run(output: target, baseline: corrupt_path)
        check(not File.exists?(target), "invalid baseline started evaluation")

        {nil,
         %{
           "split_mismatch_rejected" => true,
           "corrupt_summary_rejected" => true,
           "no_run_started" => true
         }}
      end)

      step(context, opts, "readonly_compare", fn ->
        boundaries =
          AgentSystemsLab.Approvals.Audit.boundaries() ++
            [{Observability, :emit, 4}, {Runner, :execute, 6}, {Scorer, :score, 5}]

        Enum.each(boundaries, fn {m, _, _} -> Code.ensure_loaded!(m) end)
        Enum.each(boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

        counts =
          try do
            {:ok, result} =
              Evaluation.compare_files(
                Path.join([context.output, "dev-baseline", "report.json"]),
                Path.join([context.output, "dev-regressed", "report.json"]),
                output: Path.join(context.output, "readonly-comparison")
              )

            check(not result.comparison["passed"], "file comparison lost regression")

            Map.new(boundaries, fn {m, f, a} = mfa ->
              {:call_count, count} = :erlang.trace_info(mfa, :call_count)
              {"#{inspect(m)}.#{f}/#{a}", count}
            end)
          after
            Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
          end

        check(
          Enum.all?(counts, fn {_, count} -> count == 0 end),
          "comparison triggered execution"
        )

        {nil, %{"zero_boundary_count" => map_size(counts), "boundary_calls" => counts}}
      end)

      report = current(context)
      all_ids = Enum.flat_map(report["cases"], &Map.get(&1, "run_ids", []))

      report =
        Map.merge(report, %{
          "all_passed" => true,
          "active_case" => nil,
          "run_ids" => all_ids,
          "run_count" => length(all_ids),
          "cohort_count" => 6
        })

      save(context, report)
      {:ok, %{output_dir: context.output, report: report}}
    rescue
      _ -> failure(context)
    catch
      _, _ -> failure(context)
    end
  end

  defp step(context, opts, name, fun) do
    save(context, Map.put(current(context), "active_case", name))
    progress(opts, name, :starting)
    {result, summary} = fun.()
    report = current(context)
    summary = Map.merge(summary, %{"case" => name, "passed" => true})

    save(context, %{
      report
      | "cases" => report["cases"] ++ [summary],
        "case_count" => report["case_count"] + 1
    })

    progress(opts, name, :passed)
    {result, summary}
  end

  defp failure(context) do
    report = current(context)
    report = Map.merge(report, %{"all_passed" => false, "failed_case" => report["active_case"]})
    save(context, report)
    {:error, {:evaluation_verification_failed, %{output_dir: context.output, report: report}}}
  end

  defp progress(opts, name, state),
    do: if(callback = opts[:on_progress], do: callback.(%{case: name, status: state}))

  defp current(context), do: read(Path.join(context.output, "report.json"))
  defp save(context, report), do: write(Path.join(context.output, "report.json"), report)
  defp read(path), do: path |> File.read!() |> JSON.decode!()

  defp write(path, value) do
    File.write!(path <> ".tmp", JSON.encode!(value) <> "\n")
    File.rename!(path <> ".tmp", path)
  end

  defp ids(report), do: MapSet.new(report["samples"], & &1["run_id"])
  defp check(true, _), do: :ok
  defp check(_, message), do: raise(message)

  defp options(opts) do
    valid =
      Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
        Keyword.keys(opts) -- [:output, :on_progress] == [] and
        is_binary(Keyword.get(opts, :output, "artifacts/week20-evaluation-acceptance")) and
        String.valid?(Keyword.get(opts, :output, "artifacts/week20-evaluation-acceptance")) and
        Keyword.get(opts, :output, "artifacts/week20-evaluation-acceptance") != "" and
        not String.contains?(
          Keyword.get(opts, :output, "artifacts/week20-evaluation-acceptance"),
          <<0>>
        ) and
        (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1))

    if valid, do: :ok, else: {:error, :invalid_evaluation_verification_options}
  rescue
    _ -> {:error, :invalid_evaluation_verification_options}
  end

  defp create_directory(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, path}}
        _ -> {:error, :evaluation_output_unavailable}
      end
    end
  end
end
