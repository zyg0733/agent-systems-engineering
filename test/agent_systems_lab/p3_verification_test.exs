defmodule AgentSystemsLab.P3VerificationTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{DatabaseFaultDemo, P3Verification, ReconciliationQueue, Repo, Scheduler}

  test "validates the bounded P3 matrix before creating output or starting components" do
    for opts <- [
          nil,
          :bad,
          [1],
          [repetitions: 0],
          [repetitions: 11],
          [repetitions: 1.0],
          [repetitions: 1, repetitions: 2],
          [output: ""],
          [output: "   "],
          [output: <<0>>],
          [output: <<255>>],
          [output: 1],
          [unknown: true],
          [on_progress: fn -> :ok end]
        ] do
      assert {:error, :invalid_p3_options} = P3Verification.run(opts)
    end

    assert P3Verification.components() == ["scheduling", "fencing", "load", "database"]
  end

  test "preserves an existing evidence directory" do
    directory = output("existing")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep.txt"), "previous P3 evidence")
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, {:output_exists, ^directory}} = P3Verification.run(output: directory)
    assert File.ls!(directory) == ["keep.txt"]
    assert File.read!(Path.join(directory, "keep.txt")) == "previous P3 evidence"
  end

  test "refuses enabled or already registered global schedulers before output creation" do
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:agent_systems_lab, :scheduler_enabled),
        else: Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end)

    directory = output("enabled")
    Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
    assert {:error, :global_scheduler_enabled} = P3Verification.run(output: directory)
    refute File.exists?(directory)

    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
    {pid, monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)

    try do
      Process.register(pid, Scheduler)
      assert {:error, :global_scheduler_enabled} = P3Verification.run(output: directory)
      refute File.exists?(directory)
    after
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    end
  end

  test "an interrupted progress consumer leaves an incomplete failure report" do
    directory = output("interrupted")
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, {:p3_verification_failed, result}} =
             P3Verification.run(
               output: directory,
               repetitions: 1,
               on_progress: fn _ -> raise "injected P3 consumer failure" end
             )

    refute result.report["all_passed"]
    refute result.report["audit_complete"]
    assert result.report["component_count"] == 0
    assert result.report["expected_component_count"] == 4
    assert result.report["failed_component"]["component"] == "scheduling"
    assert result.report["failed_component"]["reason"] =~ "injected P3 consumer failure"
    assert result.report["failed_component"]["report"] == nil
    assert JSON.decode!(File.read!(Path.join(directory, "report.json"))) == result.report
    refute File.exists?(Path.join(directory, "scheduling"))
  end

  @tag :database
  @tag timeout: 30_000
  test "a later component failure preserves completed raw evidence without accepting P3" do
    directory = output("partial")
    on_exit(fn -> cleanup(directory) end)

    assert {:error, {:p3_verification_failed, result}} =
             P3Verification.run(
               output: directory,
               repetitions: 1,
               on_progress: fn
                 %{component: "fencing", status: :starting} ->
                   raise "injected second component failure"

                 _ ->
                   :ok
               end
             )

    refute result.report["all_passed"]
    refute result.report["audit_complete"]
    assert result.report["component_count"] == 1
    assert result.report["failed_component"]["component"] == "fencing"
    assert result.report["failed_component"]["reason"] =~ "injected second component failure"
    [completed] = result.report["components"]
    assert completed["component"] == "scheduling"
    assert completed["all_passed"]

    assert JSON.decode!(File.read!(Path.join(directory, "scheduling/report.json"))) ==
             completed["report"]

    assert File.exists?(Path.join(directory, "scheduling/journals.bin"))
    assert result.report["run_ids"] == completed["report"]["run_ids"]
    assert JSON.decode!(File.read!(Path.join(directory, "report.json"))) == result.report
    refute File.exists?(Path.join(directory, "fencing"))
  end

  @tag :database
  @tag timeout: 240_000
  test "P3 retains raw component evidence and distinguishes expected blocked and failed Runs" do
    directory = output("matrix")
    on_exit(fn -> cleanup(directory) end)
    parent = self()

    result =
      P3Verification.run(
        output: directory,
        repetitions: 1,
        on_progress: &send(parent, {:p3_progress, &1})
      )

    unless match?({:ok, %{report: _}}, result) do
      IO.puts(:stderr, p3_failure_message(result, directory))
    end

    assert {:ok, %{report: report}} = result

    assert report["phase"] == "P3"
    assert report["all_passed"]
    assert report["audit_complete"]
    assert report["component_count"] == 4
    assert report["expected_component_count"] == 4
    assert report["failed_component"] == nil
    assert report["history_audit_count"] == length(report["run_ids"])
    assert report["fresh_history_audit_count"] == report["history_audit_count"]
    assert report["history_audit_count"] > 40
    assert report["outcomes"]["succeeded"] > 0
    assert report["outcomes"]["expected_failed"] == 2
    assert report["outcomes"]["expected_blocked"] >= 2
    refute report["outcomes"]["all_runs_succeeded"]

    for component <- report["components"] do
      assert component["all_passed"]
      assert Enum.all?(component["acceptance_criteria"], & &1["passed"])
      assert Enum.all?(component["acceptance_criteria"], &(map_size(&1["measured"]) > 0))
      path = Path.join([directory, component["evidence"], "report.json"])
      assert JSON.decode!(File.read!(path)) == component["report"]
    end

    scheduling = Enum.find(report["components"], &(&1["component"] == "scheduling"))["report"]
    manifest = JSON.decode!(File.read!(Path.join(directory, "scheduling/experiment.json")))
    assert manifest["run_id_prefix"] == scheduling["run_id_prefix"]
    assert Enum.sort(manifest["planned_run_ids"]) == Enum.sort(scheduling["run_ids"])

    cleanup =
      JSON.decode!(File.read!(Path.join(directory, "scheduling/fresh-application-cleanup.json")))

    assert cleanup["exit_observed"]
    assert cleanup["exit_status"] == 0

    fencing = Enum.find(report["components"], &(&1["component"] == "fencing"))["report"]
    assert fencing["sigstop_count"] == 5
    assert fencing["sigcont_count"] == 5
    database = Enum.find(report["components"], &(&1["component"] == "database"))["report"]
    assert database["fault_probe_count"] == length(DatabaseFaultDemo.cases())
    assert database["duplicate_mock_effects"] == 0
    assert database["stale_generation_overwrites"] == 0

    for audit <- report["history_audits"] do
      assert audit["state_matches_history"]
      assert audit["persisted_facts_unchanged_by_rebuild"]
      assert audit["live_claims"] == 0

      if audit["classification"] == "expected_blocked" do
        assert audit["manual_reconciliation_preserved"]
        assert {:ok, %{safe_mode: :manual}} = ReconciliationQueue.get(audit["run_id"])
      end
    end

    fresh = report["fresh_history_audit"]
    assert fresh["all_passed"]
    assert fresh["fresh_vm"]
    refute fresh["scheduler_enabled"]
    refute fresh["scheduler_started"]
    assert fresh["pid"] != System.pid()
    assert fresh["run_count"] == length(report["run_ids"])
    assert fresh["expected_run_count"] == length(report["run_ids"])
    assert Enum.map(fresh["audits"], & &1["run_id"]) == report["run_ids"]

    for {child, parent} <- Enum.zip(fresh["audits"], report["history_audits"]) do
      assert child["same_as_expected_state"]
      assert child["full_matches_checkpoint"]
      assert child["state_sha256"] == parent["state_sha256"]
      assert child["status"] == parent["status"]
      assert map_size(child["effect_boundary_calls"]) == 27
      assert Enum.all?(child["effect_boundary_calls"], fn {_, count} -> count == 0 end)
    end

    assert JSON.decode!(File.read!(Path.join(directory, "fresh-history-audit.json"))) == fresh
    assert File.read!(Path.join(directory, "fresh-history.log")) =~ "FRESH_P3_HISTORY_AUDIT="

    fresh_cleanup = JSON.decode!(File.read!(Path.join(directory, "fresh-history-cleanup.json")))
    assert fresh_cleanup["pid"] == fresh["pid"]
    assert fresh_cleanup["exit_observed"]
    assert fresh_cleanup["exit_status"] == 0

    assert_received {:p3_progress, %{component: "scheduling", status: :starting, completed: 0}}
    assert_received {:p3_progress, %{component: "database", status: :passed, completed: 4}}
    assert_received {:p3_progress, %{component: "audit", status: :passed, completed: 4}}
    assert_received {:p3_progress, %{component: "fresh_history", status: :passed, completed: 4}}

    assert JSON.decode!(File.read!(Path.join(directory, "history-audit.json"))) ==
             report["history_audits"]

    assert JSON.decode!(File.read!(Path.join(directory, "report.json"))) == report
  end

  defp p3_failure_message({:error, {:p3_verification_failed, %{report: report}}}, directory) do
    failed = report["failed_component"] || %{}
    component_report = failed["report"] || %{}

    summary = %{
      "component_count" => report["component_count"],
      "expected_component_count" => report["expected_component_count"],
      "audit_complete" => report["audit_complete"],
      "completed_components" => Enum.map(report["components"] || [], & &1["component"]),
      "outcomes" => report["outcomes"],
      "run_ids_count" => length(report["run_ids"] || []),
      "failed_component" => Map.take(failed, ["component", "reason", "evidence"]),
      "component_probe_counts" =>
        Map.take(component_report, ["all_passed", "fault_probe_count", "expected_probe_count"]),
      "failed_probe" =>
        Map.take(component_report["failed_probe"] || %{}, [
          "case",
          "fault",
          "window",
          "repetition",
          "run_id",
          "reason",
          "error"
        ]),
      "preserved_evidence" => preserve_p3_failure(directory)
    }

    "P3 failure summary: " <>
      inspect(summary, pretty: true, limit: :infinity, printable_limit: 4_000)
  end

  defp p3_failure_message(result, _directory),
    do: "Unexpected P3 result: " <> inspect(result, limit: 20, printable_limit: 4_000)

  defp preserve_p3_failure(directory) do
    if System.get_env("GITHUB_ACTIONS") == "true" do
      parent = Path.join(File.cwd!(), "artifacts/ci/linux-core")
      destination = Path.join(parent, "p3-failure-" <> Path.basename(directory))
      evidence = Path.join(destination, "evidence")

      # Reserve a fresh destination; keep partial copies if preservation fails.
      with :ok <- File.mkdir_p(parent),
           :ok <- File.mkdir(destination),
           {:ok, _} <- File.cp_r(directory, evidence) do
        evidence
      else
        error -> %{path: destination, copy_error: inspect(error, limit: 20)}
      end
    else
      "CI evidence copy disabled outside GitHub Actions"
    end
  end

  defp output(label),
    do: Path.join(File.cwd!(), "artifacts/p3-test-#{label}-#{System.unique_integer([:positive])}")

  defp cleanup(directory) do
    reports =
      Path.wildcard(Path.join(directory, "**/report.json"))
      |> Enum.flat_map(fn path ->
        with {:ok, bytes} <- File.read(path), {:ok, report} <- JSON.decode(bytes) do
          [report]
        else
          _ -> []
        end
      end)

    ids =
      Enum.flat_map(reports, fn report ->
        Map.get(report, "run_ids", []) ++
          Enum.map(Map.get(report, "fault_probes", []), & &1["run_id"]) ++
          if(report["failed_probe"], do: [report["failed_probe"]["run_id"]], else: [])
      end)

    queues = Enum.flat_map(reports, &Map.get(&1, "queue_names", [])) |> Enum.uniq()

    if Process.whereis(Repo) do
      for id <- Enum.uniq(ids),
          is_binary(id),
          do: Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])

      for name <- queues, do: Repo.query!("DELETE FROM lab_runs WHERE queue_name=$1", [name])
      for name <- queues, do: Repo.query!("DELETE FROM lab_queues WHERE name=$1", [name])
    end

    File.rm_rf!(directory)
  end
end
