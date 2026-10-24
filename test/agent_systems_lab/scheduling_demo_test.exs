defmodule AgentSystemsLab.SchedulingDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{ReconciliationQueue, Repo, SchedulingDemo}

  test "rejects malformed experiment options without touching persistence" do
    for opts <- [
          nil,
          :bad,
          [runs: 3],
          [runs: 101],
          [runs: 4.0],
          [runs: 4, runs: 5],
          [unknown: true],
          [output: ""],
          [output: <<0>>],
          [output: 5]
        ] do
      assert {:error, :invalid_scheduling_demo_options} = SchedulingDemo.run(opts)
    end
  end

  test "does not overwrite existing evidence" do
    path =
      Path.join(
        File.cwd!(),
        "artifacts/scheduling-existing-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    File.write!(Path.join(path, "original.txt"), "retain evidence")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:error, {:output_exists, ^path}} = SchedulingDemo.run(output: path)
    assert File.read!(Path.join(path, "original.txt")) == "retain evidence"
  end

  @tag :database
  @tag timeout: 30_000
  test "background pools, renewals, killed delivery, due retries and application restart agree" do
    path =
      Path.join(File.cwd!(), "artifacts/scheduling-test-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if File.exists?(Path.join(path, "report.json")) do
        report = JSON.decode!(File.read!(Path.join(path, "report.json")))

        for id <- Map.get(report, "run_ids", []),
            do: Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])
      end

      File.rm_rf!(path)
    end)

    assert {:ok, result} = SchedulingDemo.run(output: path, runs: 4)
    report = result.report
    assert report["all_passed"]
    assert length(report["run_ids"]) == 8
    assert report["observed_parallel_deliveries"] == 4
    assert report["model_retry_attempts"] == 3
    assert report["tool_retry_attempts"] == 3
    assert report["renewal"]["renewals_observed"] >= 4
    assert report["renewal"]["second_owner_rejected"]
    assert report["redelivery"]["effects"] == 1
    assert report["redelivery"]["execution_attempts"] == 2
    assert report["fresh_application"]["application_scheduler_started"]
    assert report["fresh_application"]["effects"] == 1
    assert {:ok, %{safe_mode: :manual}} = ReconciliationQueue.get(report["manual_queue_run_id"])
    assert File.exists?(Path.join(path, "journals.bin"))
    assert File.read!(Path.join(path, "fresh-application.log")) =~ "SCHEDULING_AUDIT="
    assert JSON.decode!(File.read!(Path.join(path, "report.json"))) == report
  end
end
