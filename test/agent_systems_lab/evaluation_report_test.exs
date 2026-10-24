defmodule AgentSystemsLab.EvaluationReportTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Evaluation.{Comparison, Report}

  test "all planned trials, failures and their real costs remain in the denominator" do
    samples = [sample("a", 1), sample("a", 2, false), sample("b", 1, false), sample("b", 2)]
    {:ok, report} = Report.build(manifest(), samples)
    summary = report["summary"]
    assert summary["planned_samples"] == 4
    assert summary["successful_samples"] == 2
    assert summary["success_rate_pct"] == 50.0
    assert summary["task_count"] == 2
    assert summary["successful_tasks"] == 0
    assert summary["task_success_rate_pct"] == 0.0
    assert summary["classification_counts"]["task_failure"] == 2
    assert summary["cost"]["total_units"] == 5_004
    assert summary["cost"]["per_planned_sample_units"] == 1_251.0
    assert summary["cost"]["per_successful_sample_units"] == 2_502.0
    assert summary["cost"]["usd"] == nil
    assert :ok = Report.validate(report)
    assert :ok = report |> JSON.encode!() |> JSON.decode!() |> Report.validate()
  end

  test "latency pools individual measurements and uses nearest-rank quantiles" do
    samples =
      Enum.zip([{"a", 1}, {"a", 2}, {"b", 1}, {"b", 2}], [1, 3, 2, 100])
      |> Enum.map(fn {{task, trial}, latency} ->
        sample(task, trial)
        |> put_in(["latency_us"], %{"execution" => latency, "scoring" => 0, "total" => latency})
      end)

    {:ok, report} = Report.build(manifest(), samples)
    assert report["summary"]["latency_us"]["total"]["p50"] == 2
    assert report["summary"]["latency_us"]["total"]["p95"] == 100
    assert report["summary"]["latency_us"]["total"]["count"] == 4
    assert Report.quantile([], 95) == nil
    assert Report.quantile([7], 95) == 7
  end

  test "unknown accounting is explicit and never free or dropped" do
    samples = all_samples() |> List.update_at(0, &Map.put(&1, "usage", nil))
    {:ok, report} = Report.build(manifest(), samples)
    cost = report["summary"]["cost"]
    assert cost["known_sum_units"] == 3_753
    assert cost["unknown_count"] == 1
    assert cost["known_count"] == 3
    refute cost["complete"]
    assert cost["total_units"] == nil
    assert cost["per_planned_sample_units"] == nil
    assert cost["per_successful_sample_units"] == nil
    assert report["summary"]["planned_samples"] == 4
    {:ok, comparison} = Comparison.compare(report, report)
    assert comparison["status"] == "indeterminate"
    assert comparison["regressed"]
    refute comparison["passed"]
  end

  test "a zero-success run has null cost per success and a real planned denominator" do
    samples = Enum.map(all_samples(), &fail/1)
    {:ok, report} = Report.build(manifest(), samples)
    assert report["summary"]["success_rate_pct"] == 0.0
    assert report["summary"]["cost"]["per_successful_sample_units"] == nil
    assert report["summary"]["cost"]["per_planned_sample_units"] == 1_251.0
  end

  test "missing, duplicated task/trial pairs and reused Runs are rejected" do
    samples = all_samples()

    assert {:error, {:invalid_report, :incomplete_samples}} =
             Report.build(manifest(), tl(samples))

    assert {:error, {:invalid_report, :sample_identity}} =
             Report.build(manifest(), [hd(samples) | tl(tl(samples))] ++ [hd(samples)])

    reused = List.update_at(samples, 1, &Map.put(&1, "run_id", hd(samples)["run_id"]))
    assert {:error, {:invalid_report, :duplicate_run}} = Report.build(manifest(), reused)
  end

  test "strict sample schema rejects mixed split, task bytes, malformed counts and incoherent outcomes" do
    changes = [
      {"split", "holdout"},
      {"task_hash", digest("different")},
      {"run_id", ""},
      {"run_id", String.duplicate("x", 257)},
      {"trial", 0},
      {"usage",
       %{"model_attempts" => -1, "output_bytes" => 0, "tool_attempts" => 0, "dispatches" => 0}},
      {"usage",
       %{
         "model_attempts" => :infinity,
         "output_bytes" => 0,
         "tool_attempts" => 0,
         "dispatches" => 0
       }},
      {"latency_us", %{"execution" => 5, "scoring" => 5, "total" => 9}},
      {"task_success", false},
      {"semantic_result_hash", "not-a-hash"}
    ]

    for {key, value} <- changes do
      invalid = List.update_at(all_samples(), 0, &Map.put(&1, key, value))
      assert {:error, {:invalid_report, :sample_schema}} = Report.build(manifest(), invalid)
    end

    invalid = List.update_at(all_samples(), 0, &Map.put(&1, "raw_error", "private"))
    assert {:error, {:invalid_report, :sample_schema}} = Report.build(manifest(), invalid)
  end

  test "manifest bounds and exact fixed pricing bind the measurement protocol" do
    for {key, value} <- [
          {"repetitions", 0},
          {"task_ids", ["b", "a"]},
          {"pricing_hash", digest("different")}
        ] do
      invalid = put_in(manifest(), ["protocol", key], value)
      assert {:error, {:invalid_report, _}} = Report.build(invalid, all_samples())
    end

    assert {:error, {:invalid_report, :manifest_schema}} =
             Report.build(Map.put(manifest(), "timestamp", "now"), all_samples())
  end

  test "saved report validation recomputes summary, samples hashes and semantic signatures" do
    {:ok, report} = Report.build(manifest(), all_samples())

    for path <- [
          ["summary", "successful_samples"],
          ["samples_hash"],
          ["semantic_signature"],
          ["report_hash"]
        ] do
      invalid = put_in(report, path, "edited")
      assert {:error, {:invalid_report, :derived_values_mismatch}} = Report.validate(invalid)

      assert {:error, {:invalid_report, :derived_values_mismatch}} =
               Comparison.compare(report, invalid)
    end
  end

  test "semantic signatures exclude fresh Run IDs, seed, profile and measured latency" do
    {:ok, old} = Report.build(manifest(), all_samples())

    changed =
      Enum.map(all_samples(), fn sample ->
        sample
        |> Map.update!("run_id", &("fresh-" <> &1))
        |> put_in(["latency_us"], %{"execution" => 80, "scoring" => 20, "total" => 100})
      end)

    {:ok, new} =
      Report.build(manifest() |> Map.put("seed", 5) |> Map.put("profile", "other"), changed)

    assert old["semantic_signature"] == new["semantic_signature"]
    refute old["samples_hash"] == new["samples_hash"]
    refute old["report_hash"] == new["report_hash"]
    {:ok, comparison} = Comparison.compare(old, new)
    assert comparison["passed"]
    assert Enum.all?(comparison["paired_changes"], &(&1["outcome_change"] == "unchanged"))
  end

  test "comparison rejects altered suite, scorer, task, split, repetitions, runtime and scope" do
    {:ok, baseline} = Report.build(manifest(), all_samples())

    for key <- ~w(suite_hash scorer_hash execution_contract runtime_version measurement_scope) do
      value = if String.ends_with?(key, "hash"), do: digest("changed"), else: "changed"
      {:ok, changed} = Report.build(put_in(manifest(), ["protocol", key], value), all_samples())
      assert {:error, {:incompatible_protocol, [^key]}} = Comparison.compare(baseline, changed)
    end

    changed_manifest = put_in(manifest(), ["protocol", "split"], "holdout")
    changed_samples = Enum.map(all_samples(), &Map.put(&1, "split", "holdout"))
    {:ok, changed} = Report.build(changed_manifest, changed_samples)
    assert {:error, {:incompatible_protocol, ["split"]}} = Comparison.compare(baseline, changed)

    {:ok, changed} =
      Report.build(
        put_in(manifest(), ["protocol", "repetitions"], 1),
        Enum.filter(all_samples(), &(&1["trial"] == 1))
      )

    assert {:error, {:incompatible_protocol, ["repetitions"]}} =
             Comparison.compare(baseline, changed)

    altered_hash = digest("different task bytes")

    {:ok, changed} =
      Report.build(
        put_in(manifest(), ["protocol", "task_hashes", "a"], altered_hash),
        Enum.map(all_samples(), fn sample ->
          if sample["task_id"] == "a",
            do: Map.put(sample, "task_hash", altered_hash),
            else: sample
        end)
      )

    assert {:error, {:incompatible_protocol, ["task_hashes"]}} =
             Comparison.compare(baseline, changed)
  end

  test "per-task quality regression is visible even when aggregate success stays equal" do
    old = [sample("a", 1), sample("a", 2), sample("b", 1, false), sample("b", 2, false)]
    new = [sample("a", 1, false), sample("a", 2, false), sample("b", 1), sample("b", 2)]
    {:ok, baseline} = Report.build(manifest(), old)
    {:ok, candidate} = Report.build(manifest(), new)
    {:ok, comparison} = Comparison.compare(baseline, candidate)
    assert hd(comparison["checks"])["status"] == "passed"
    assert comparison["status"] == "regressed"
    assert comparison["regressed"]
    assert Enum.find(comparison["by_task"], &(&1["task_id"] == "a"))["status"] == "regressed"
    assert Enum.count(comparison["paired_changes"], &(&1["outcome_change"] == "regressed")) == 2
    assert Enum.count(comparison["paired_changes"], &(&1["outcome_change"] == "improved")) == 2
  end

  test "per-task cost regression is visible when other tasks offset the total" do
    old = Enum.map(all_samples(), &put_in(&1, ["usage", "model_attempts"], 2))

    new =
      Enum.map(
        all_samples(),
        &put_in(&1, ["usage", "model_attempts"], if(&1["task_id"] == "a", do: 3, else: 1))
      )

    {:ok, baseline} = Report.build(manifest(), old)
    {:ok, candidate} = Report.build(manifest(), new)
    {:ok, comparison} = Comparison.compare(baseline, candidate)

    assert Enum.find(comparison["checks"], &(&1["metric"] == "cost.total_units"))["status"] ==
             "passed"

    assert comparison["regressed"]
    assert Enum.find(comparison["by_task"], &(&1["task_id"] == "a"))["status"] == "regressed"
  end

  test "latency requires both the absolute and relative noise guards" do
    {:ok, baseline} = Report.build(manifest(), timed(100_000))

    for {latency, expected} <- [{130_000, "passed"}, {150_000, "passed"}, {150_001, "regressed"}] do
      {:ok, candidate} = Report.build(manifest(), timed(latency))
      {:ok, comparison} = Comparison.compare(baseline, candidate)
      assert comparison["status"] == expected
    end

    {:ok, high_baseline} = Report.build(manifest(), timed(1_000_000))
    {:ok, candidate} = Report.build(manifest(), timed(1_100_000))
    {:ok, comparison} = Comparison.compare(high_baseline, candidate)
    assert comparison["passed"]
  end

  test "zero baseline never divides by zero and still detects a genuine added cost" do
    free =
      Enum.map(
        all_samples(),
        &Map.put(&1, "usage", %{
          "model_attempts" => 0,
          "output_bytes" => 0,
          "tool_attempts" => 0,
          "dispatches" => 0
        })
      )

    {:ok, baseline} = Report.build(manifest(), free)
    {:ok, candidate} = Report.build(manifest(), all_samples())
    {:ok, comparison} = Comparison.compare(baseline, candidate)
    check = Enum.find(comparison["checks"], &(&1["metric"] == "cost.total_units"))
    assert check["zero_baseline"]
    assert check["increase_pct"] == nil
    assert check["status"] == "regressed"
  end

  test "scorer and harness errors are denominator failures and fail the comparison gate" do
    for classification <- ~w(scorer_error harness_error) do
      sample =
        sample("a", 1, false)
        |> Map.put("classification", classification)
        |> Map.put("failure_class", classification)

      samples = List.replace_at(all_samples(), 0, sample)
      {:ok, report} = Report.build(manifest(), samples)
      assert report["summary"]["success_rate_pct"] == 75.0
      {:ok, comparison} = Comparison.compare(report, report)
      assert comparison["status"] == "indeterminate"
      refute comparison["passed"]
    end
  end

  test "thresholds reject nonfinite, duplicate, unsupported and negative settings" do
    {:ok, report} = Report.build(manifest(), all_samples())

    for opts <- [
          [success_drop_pp: -1],
          [success_drop_pp: :infinity],
          [success_drop_pp: 101],
          [latency_increase_us: 0.1],
          [unknown: 1],
          [success_drop_pp: 1, success_drop_pp: 2],
          %{}
        ] do
      assert {:error, {:invalid_comparison, _}} = Comparison.compare(report, report, opts)
    end
  end

  test "canonical hashing does not depend on insertion order or confuse strings and numbers" do
    assert Report.hash(%{"b" => [1, 2], "a" => %{"d" => true, "c" => nil}}) ==
             Report.hash(Map.new([{"a", Map.new([{"c", nil}, {"d", true}])}, {"b", [1, 2]}]))

    refute Report.hash(%{"n" => 1}) == Report.hash(%{"n" => "1"})
  end

  defp manifest do
    %{
      "schema_version" => 1,
      "profile" => "reference",
      "seed" => 0,
      "protocol" => %{
        "suite_hash" => digest("suite"),
        "scorer_hash" => digest("scorer"),
        "pricing_hash" => Report.hash(Report.pricing()),
        "split" => "dev",
        "task_ids" => ["a", "b"],
        "task_hashes" => %{"a" => digest("a"), "b" => digest("b")},
        "repetitions" => 2,
        "execution_contract" => "durable_scripted_files_v1",
        "runtime_version" => "Elixir-test OTP-test",
        "measurement_scope" => "monotonic_us_execution_plus_external_scorer_v1"
      }
    }
  end

  defp sample(task, trial, success \\ true) do
    %{
      "task_id" => task,
      "task_hash" => digest(task),
      "trial" => trial,
      "split" => "dev",
      "run_id" => "run-#{task}-#{trial}",
      "task_success" => success,
      "classification" => if(success, do: "success", else: "task_failure"),
      "failure_class" => if(success, do: "success", else: "incorrect"),
      "usage" => %{
        "model_attempts" => 1,
        "output_bytes" => 1,
        "tool_attempts" => 1,
        "dispatches" => 2
      },
      "latency_us" => %{"execution" => 8, "scoring" => 2, "total" => 10},
      "semantic_result_hash" => digest({task, trial, success})
    }
  end

  defp fail(sample),
    do:
      sample
      |> Map.put("task_success", false)
      |> Map.put("classification", "task_failure")
      |> Map.put("failure_class", "incorrect")

  defp all_samples, do: for(task <- ~w(a b), trial <- 1..2, do: sample(task, trial))

  defp timed(us),
    do:
      Enum.map(
        all_samples(),
        &Map.put(&1, "latency_us", %{"execution" => us, "scoring" => 0, "total" => us})
      )

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
