defmodule AgentSystemsLab.P2VerificationTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{DurableTools, IntentStore, P2Verification, Recovery, Repo}
  alias AgentSystemsLab.Storage.Codec

  test "rejects invalid options before creating output or touching the database" do
    for opts <- [
          nil,
          :bad,
          [1],
          [repetitions: 0],
          [repetitions: 21],
          [repetitions: 1.0],
          [output: ""],
          [output: <<0>>],
          [output: 7],
          [unknown: true],
          [on_progress: fn -> :ok end],
          [repetitions: 1, repetitions: 2]
        ] do
      assert {:error, :invalid_p2_options} = P2Verification.run(opts)
    end

    assert length(P2Verification.cases()) == 16
    assert length(Enum.uniq(P2Verification.cases())) == 16
  end

  test "refuses an existing evidence directory without changing its contents" do
    root = output("existing")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "keep.txt"), "previous evidence")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:error, {:output_exists, ^root}} = P2Verification.run(output: root)
    assert File.ls!(root) == ["keep.txt"]
    assert File.read!(Path.join(root, "keep.txt")) == "previous evidence"
  end

  @tag :database
  @tag timeout: 120_000
  test "all crash windows preserve effects, receipts, fencing and accepted model progress" do
    root = output("matrix")
    on_exit(fn -> cleanup(root) end)
    parent = self()

    assert {:ok, result} =
             P2Verification.run(
               output: root,
               repetitions: 1,
               on_progress: fn progress -> send(parent, {:progress, progress}) end
             )

    report = result.report
    assert report["all_passed"]
    assert report["fault_probe_count"] == 16
    assert report["expected_probe_count"] == 16
    assert report["kill_count"] == 17
    assert report["duplicate_mock_effects"] == 0
    assert report["lost_confirmed_receipts"] == 0
    assert report["stale_token_overwrites"] == 0
    assert report["accepted_cursor_rerequests"] == 0
    assert report["fresh_vm_probes"] == 2
    assert report["failed_probe"] == nil
    assert_receive {:progress, %{status: :starting, completed: 0, total: 16}}
    assert_receive {:progress, %{status: :passed, completed: 16, total: 16}}

    for probe <- report["fault_probes"] do
      directory = Path.join(root, probe["evidence"])
      assert {:ok, before} = Codec.decode(File.read!(Path.join(directory, "before.bin")))
      assert {:ok, after_recovery} = Codec.decode(File.read!(Path.join(directory, "after.bin")))
      assert before.stats.effects in [0, 1]
      assert after_recovery.stats.effects == 1
      assert after_recovery.snapshot.state.status == :succeeded
      assert length(after_recovery.recordings) == 2
      assert length(after_recovery.operations) == 1
      assert File.exists?(Path.join(directory, "summary.json"))

      if probe["fresh_vm"] do
        assert File.read!(Path.join(directory, "fresh-resume.log")) =~ "RECOVERY_AUDIT="
        assert File.read!(Path.join(directory, "fresh-rebuild.log")) =~ "HISTORY_AUDIT="
      end
    end
  end

  test "an interrupted progress consumer leaves a failure report instead of false acceptance" do
    root = output("failed")
    on_exit(fn -> cleanup(root) end)

    assert {:error, {:p2_verification_failed, result}} =
             P2Verification.run(
               output: root,
               repetitions: 1,
               on_progress: fn _ -> raise "injected consumer failure" end
             )

    refute result.report["all_passed"]
    assert result.report["fault_probe_count"] == 0
    assert result.report["expected_probe_count"] == 16
    assert result.report["failed_probe"]["fault"] == "after_claim"
    assert result.report["failed_probe"]["reason"] =~ "injected consumer failure"
    assert {:ok, report} = JSON.decode(File.read!(Path.join(root, "report.json")))
    assert report == result.report
  end

  @tag :database
  test "pre-execution delay expires a tiny lease before the crash hooks, not a live fixture lease" do
    prefix = "p2-pre-execution-#{Ecto.UUID.generate()}"
    ids = for label <- ["expired", "live"], do: prefix <> "-" <> label
    on_exit(fn -> Enum.each(ids, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1])) end)
    parent = self()

    for {id, lease_ms} <- Enum.zip(ids, [200, 1_000]) do
      assert {:ok, _} =
               Recovery.create_run(id, "reach the intended crash window",
                 script: [
                   {:call,
                    %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
                   {:final, "done"}
                 ]
               )

      assert {:ok, %{state: %{status: :waiting_tool}}} = Recovery.step(id)
      assert {:ok, claim} = IntentStore.claim(id, "pre-execution-delay", lease_ms: lease_ms)
      Process.sleep(250)

      {caller, monitor} =
        spawn_monitor(fn ->
          result =
            Recovery.execute_claim(claim,
              hook: fn stage -> if stage == :after_claim, do: send(parent, {id, :after_claim}) end,
              commit_hook: fn
                :after_commit ->
                  send(parent, {id, :after_commit})
                  receive do: (:release -> :ok)

                _ ->
                  :ok
              end
            )

          send(parent, {id, :ack, result})
        end)

      try do
        if lease_ms == 200 do
          assert_receive {^id, :ack, {:error, :claim_expired}}, 2_000
          assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 2_000
          refute_received {^id, :after_claim}
          refute_received {^id, :after_commit}
          assert %{effects: 0} = DurableTools.stats(id)
        else
          assert_receive {^id, :after_claim}, 2_000
          assert_receive {^id, :after_commit}, 2_000
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000
          refute_received {^id, :ack, _}
          assert {:ok, %{state: %{seq: 3, status: :running}}} = Recovery.load(id)
          assert %{effects: 1} = DurableTools.stats(id)
        end
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp output(label),
    do: Path.join(File.cwd!(), "artifacts/p2-test-#{label}-#{System.unique_integer([:positive])}")

  defp cleanup(root) do
    report =
      case File.read(Path.join(root, "report.json")) do
        {:ok, bytes} -> JSON.decode!(bytes)
        _ -> %{}
      end

    ids = Enum.map(Map.get(report, "fault_probes", []), & &1["run_id"])
    ids = if failed = report["failed_probe"], do: [failed["run_id"] | ids], else: ids

    if Process.whereis(Repo),
      do: Enum.each(ids, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1]))

    File.rm_rf!(root)
  end
end
