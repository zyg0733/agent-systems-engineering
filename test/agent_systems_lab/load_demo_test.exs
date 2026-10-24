defmodule AgentSystemsLab.LoadDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{LoadDemo, QueueStore, ReconciliationQueue, Repo}

  test "rejects malformed load experiments before creating output or touching persistence" do
    for opts <- [
          nil,
          :bad,
          [jobs: 5],
          [jobs: 101],
          [jobs: 6.0],
          [jobs: 6, jobs: 7],
          [output: ""],
          [output: <<0>>],
          [output: 5],
          [on_progress: :bad],
          [on_progress: fn -> :ok end],
          [unknown: true]
        ] do
      assert {:error, :invalid_load_demo_options} = LoadDemo.run(opts)
    end
  end

  test "preserves an existing output directory" do
    output = path("existing")
    File.mkdir_p!(output)
    File.write!(Path.join(output, "evidence.txt"), "preserve")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = LoadDemo.run(output: output)
    assert File.read!(Path.join(output, "evidence.txt")) == "preserve"
  end

  @tag :database
  @tag timeout: 60_000
  test "saturation bounds, aged service, starvation and timeout reclamation are measured" do
    output = path("acceptance")

    on_exit(fn ->
      if File.exists?(Path.join(output, "report.json")) do
        report = JSON.decode!(File.read!(Path.join(output, "report.json")))
        for id <- report["run_ids"], do: Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])

        for name <- report["queue_names"],
            do: Repo.query!("DELETE FROM lab_runs WHERE queue_name=$1", [name])

        for name <- report["queue_names"],
            do: Repo.query!("DELETE FROM lab_queues WHERE name=$1", [name])
      end

      File.rm_rf!(output)
    end)

    parent = self()

    assert {:ok, %{report: report}} =
             LoadDemo.run(output: output, jobs: 6, on_progress: &send(parent, {:load_phase, &1}))

    assert report["all_passed"]
    assert report["saturation"]["admitted"] == 6
    assert report["saturation"]["rejected"] == 6
    assert report["saturation"]["rejected_run_records"] == 0
    assert report["saturation"]["configured_pool_capacity"] == 4
    assert report["saturation"]["peak_live_claims"] == 2
    assert report["saturation"]["peak_workers"] == 2
    assert report["saturation"]["peak_executors"] == 2
    assert report["saturation"]["peak_provider_children"] == 2
    assert report["saturation"]["peak_task_processes"] <= 8
    assert report["saturation"]["peak_nonterminal_runs"] <= 6
    assert report["saturation"]["returned_credits_admitted"] == 2
    assert report["fairness"]["starvation_detected_before_service"]
    assert report["fairness"]["starvation_cleared_after_service"]
    assert report["fairness"]["low_priority_service_rank_after_incumbent"] == 1
    assert report["fairness"]["low_priority_original_wait_ms"] >= 90
    assert report["budgets"]["dispatch_cap_tool_effects"] == 0
    assert report["budgets"]["slow_model_accepted_results"] == 0
    assert report["budgets"]["slow_provider_stopped_and_awaited"]
    assert report["budgets"]["ambiguous_executor_stopped_and_awaited"]
    assert report["budgets"]["ambiguous_tool_effects"] == 1

    assert {:ok, %{safe_mode: :manual}} =
             ReconciliationQueue.get(report["budgets"]["ambiguous_tool_run_id"])

    assert {:ok, %{active: 1, blocked: 1, available_slots: 1}} =
             QueueStore.stats(Enum.at(report["queue_names"], 4))

    assert File.exists?(Path.join(output, "journals.bin"))
    assert JSON.decode!(File.read!(Path.join(output, "report.json"))) == report
    assert JSON.decode!(File.read!(Path.join(output, "metrics.json"))) == report
    assert length(JSON.decode!(File.read!(Path.join(output, "timeline.json")))) >= 12

    for phase <- [:saturation, :fairness, :budgets, :complete],
        do: assert_received({:load_phase, ^phase})
  end

  defp path(suffix),
    do: Path.join(File.cwd!(), "artifacts/load-#{suffix}-#{System.unique_integer([:positive])}")
end
