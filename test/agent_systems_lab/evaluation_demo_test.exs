defmodule AgentSystemsLab.EvaluationDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{EvaluationDemo, Repo}
  alias AgentSystemsLab.Evaluation.{Comparison, Report}

  test "repeat invariants retain latency regressions while rejecting incomplete or regressed task gates" do
    manifest = %{
      "schema_version" => 1,
      "profile" => "reference",
      "seed" => 0,
      "protocol" => %{
        "suite_hash" => Report.hash("suite"),
        "scorer_hash" => Report.hash("scorer"),
        "pricing_hash" => Report.hash(Report.pricing()),
        "split" => "dev",
        "task_ids" => ["a", "b", "c"],
        "task_hashes" => Map.new(~w(a b c), &{&1, Report.hash(&1)}),
        "repetitions" => 1,
        "execution_contract" => "durable_scripted_files_v1",
        "runtime_version" => "Elixir-test OTP-test",
        "measurement_scope" => "monotonic_us_execution_plus_external_scorer_v1"
      }
    }

    samples =
      for task <- ~w(a b c) do
        %{
          "task_id" => task,
          "task_hash" => Report.hash(task),
          "trial" => 1,
          "split" => "dev",
          "run_id" => "baseline-#{task}",
          "task_success" => true,
          "classification" => "success",
          "failure_class" => "success",
          "usage" => %{
            "model_attempts" => 1,
            "output_bytes" => 1,
            "tool_attempts" => 1,
            "dispatches" => 2
          },
          "latency_us" => %{"execution" => 100_000, "scoring" => 0, "total" => 100_000},
          "semantic_result_hash" => Report.hash(task)
        }
      end

    repeated =
      Enum.map(samples, fn sample ->
        sample
        |> Map.put("run_id", "repeat-" <> sample["task_id"])
        |> Map.put("latency_us", %{"execution" => 200_000, "scoring" => 0, "total" => 200_000})
      end)

    assert {:ok, baseline} = Report.build(manifest, samples)
    assert {:ok, repeat} = Report.build(manifest, repeated)
    assert baseline["semantic_signature"] == repeat["semantic_signature"]
    assert baseline["summary"]["cost"] == repeat["summary"]["cost"]
    assert {:ok, comparison} = Comparison.compare(baseline, repeat)
    refute comparison["passed"]
    assert comparison["status"] == "regressed"
    assert EvaluationDemo.repeat_invariants?(comparison)
    refute comparison["passed"]
    assert comparison["status"] == "regressed"

    mixed_samples =
      Enum.map(samples, fn sample ->
        us = %{"a" => 100_000, "b" => 1_000_000, "c" => 2_000_000}[sample["task_id"]]
        Map.put(sample, "latency_us", %{"execution" => us, "scoring" => 0, "total" => us})
      end)

    task_only_repeat =
      Enum.map(mixed_samples, fn sample ->
        updated = Map.put(sample, "run_id", "task-only-repeat-" <> sample["task_id"])

        if sample["task_id"] == "a",
          do:
            Map.put(updated, "latency_us", %{
              "execution" => 200_000,
              "scoring" => 0,
              "total" => 200_000
            }),
          else: updated
      end)

    assert {:ok, mixed_baseline} = Report.build(manifest, mixed_samples)
    assert {:ok, task_only_report} = Report.build(manifest, task_only_repeat)
    assert {:ok, task_only_comparison} = Comparison.compare(mixed_baseline, task_only_report)
    assert Enum.all?(task_only_comparison["checks"], &(&1["status"] == "passed"))
    assert hd(task_only_comparison["by_task"])["status"] == "regressed"
    refute task_only_comparison["passed"]
    assert task_only_comparison["status"] == "regressed"
    assert EvaluationDemo.repeat_invariants?(task_only_comparison)
    refute task_only_comparison["passed"]
    assert task_only_comparison["status"] == "regressed"

    per_task_quality =
      update_in(comparison, ["by_task", Access.at(0), "checks"], fn checks ->
        Enum.map(checks, fn check ->
          if check["metric"] == "success_rate_pct",
            do: Map.put(check, "status", "regressed"),
            else: check
        end)
      end)

    refute EvaluationDemo.repeat_invariants?(per_task_quality)
    unknown = List.update_at(repeated, 0, &Map.put(&1, "usage", nil))
    assert {:ok, unknown_report} = Report.build(manifest, unknown)
    assert {:ok, unknown_comparison} = Comparison.compare(baseline, unknown_report)
    refute EvaluationDemo.repeat_invariants?(unknown_comparison)

    for malformed <- [
          nil,
          %{},
          Map.put(comparison, "by_task", []),
          Map.put(comparison, "by_task", tl(comparison["by_task"])),
          Map.put(comparison, "checks", tl(comparison["checks"])),
          Map.put(comparison, "checks", [hd(comparison["checks"]) | comparison["checks"]]),
          put_in(comparison, ["checks", Access.at(3), "status"], "indeterminate"),
          put_in(comparison, ["by_task", Access.at(0), "checks"], []),
          put_in(comparison, ["by_task", Access.at(0), "checks", Access.at(0), "candidate"], nil),
          Map.put(comparison, "passed", true)
        ] do
      refute EvaluationDemo.repeat_invariants?(malformed)
    end
  end

  test "verification options have no execution or overwrite escape" do
    for opts <- [
          nil,
          :bad,
          [1],
          [output: ""],
          [output: <<0>>],
          [output: <<255>>],
          [on_progress: fn -> :ok end],
          [split: "holdout"],
          [output: "a", output: "b"]
        ] do
      assert {:error, :invalid_evaluation_verification_options} = EvaluationDemo.run(opts)
    end

    assert length(EvaluationDemo.cases()) == 10
  end

  @tag :database
  test "old verification evidence and global schedulers are protected" do
    root = directory()
    File.mkdir!(root)
    File.write!(Path.join(root, "keep"), "keep")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:error, {:output_exists, ^root}} = EvaluationDemo.run(output: root)
    old = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = EvaluationDemo.run(output: root)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, old)
    end

    assert File.read!(Path.join(root, "keep")) == "keep"
  end

  @tag :database
  test "failed acceptance callback is visible and cannot claim completion" do
    root = directory()
    on_exit(fn -> cleanup(root) end)

    assert {:error, {:evaluation_verification_failed, result}} =
             EvaluationDemo.run(
               output: root,
               on_progress: fn _ -> raise "PRIVATE_VERIFICATION_FAILURE" end
             )

    refute result.report["all_passed"]
    assert result.report["case_count"] == 0
    assert result.report["failed_case"] == "dev-baseline"
    refute JSON.encode!(result.report) =~ "PRIVATE_VERIFICATION_FAILURE"
  end

  @tag :database
  @tag timeout: 120_000
  test "sixty fresh samples prove replay, honest failure rates and no-execution comparison" do
    root = directory()
    on_exit(fn -> cleanup(root) end)
    result = EvaluationDemo.run(output: root)
    assert match?({:ok, _}, result), inspect(result, limit: :infinity)
    {:ok, result} = result
    assert result.report["all_passed"]
    assert result.report["case_count"] == 10
    assert result.report["cohort_count"] == 6
    assert result.report["run_count"] == 60
    assert length(Enum.uniq(result.report["run_ids"])) == 60
    rows = Map.new(result.report["cases"], &{&1["case"], &1})
    assert rows["dev-regressed"]["summary"]["successful_samples"] == 8
    assert rows["holdout-regressed"]["summary"]["successful_samples"] == 6
    assert rows["regression_gate"]["budget_failed_despite_correct_artifact"]
    assert rows["reproducibility"]["semantic_cost_gate_passed"] == true
    assert rows["reproducibility"]["latency_reproducibility_claimed"] == false

    for split <- rows["reproducibility"]["splits"] do
      assert split["semantic_cost_gate_passed"] == true
      assert split["latency_reproducibility_claimed"] == false

      comparison =
        root
        |> Path.join(split["split"] <> "-repeat/comparison.json")
        |> File.read!()
        |> JSON.decode!()

      assert split["comparison_passed"] == comparison["passed"]
      assert split["comparison_status"] == comparison["status"]
    end

    assert rows["protocol_guards"]["no_run_started"]
    assert rows["readonly_compare"]["zero_boundary_count"] == 49
    assert Enum.all?(rows["readonly_compare"]["boundary_calls"], fn {_, n} -> n == 0 end)
    assert JSON.decode!(File.read!(Path.join(root, "report.json"))) == result.report
  end

  defp directory,
    do:
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "lab-eval-acceptance-#{Ecto.UUID.generate()}"
      )

  defp cleanup(root) do
    for cohort <- Path.wildcard(Path.join(root, "*/manifest.json")) do
      rows = JSON.decode!(File.read!(cohort))["planned_samples"] || []
      ids = Enum.map(rows, & &1["run_id"])
      if ids != [], do: Repo.query!("DELETE FROM lab_runs WHERE id=ANY($1::text[])", [ids])
    end

    File.rm_rf!(root)
  end
end
