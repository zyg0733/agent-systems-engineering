defmodule AgentSystemsLab.PersistedHistoryRuntimeTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    CheckpointStore,
    ContextStore,
    HistoryDemo,
    ModelResultStore,
    Repo,
    RunServer,
    Storage
  }

  @moduletag :database

  setup do
    id =
      "history-runtime-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    root = Path.join(File.cwd!(), "artifacts/#{id}")

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  defp start_run(c, script) do
    start_supervised!(
      {RunServer, run_id: c.id, input: "write once", storage: :postgres, script: script}
    )
  end

  test "runtime recordings share the event commit and checkpoint retains a pending tool", c do
    call = {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}}
    server = start_run(c, [call, {:final, "done"}])
    assert {:ok, planned} = RunServer.step(server)
    assert {:ok, [record]} = ModelResultStore.list(c.id)
    assert record.record === hd(planned.recordings)
    assert record.context_id == planned.context_id
    assert {:ok, saved} = Storage.load(c.id)
    assert saved.state === planned.state
    assert saved.intent.kind == "tool"
    assert {:ok, checkpoint} = CheckpointStore.create(c.id, planned.state.seq)
    assert checkpoint.checkpoint.state.pending_operation_id == "once"

    assert {:ok, complete} = RunServer.run_until_pause(server)
    assert {:ok, results} = ModelResultStore.list(c.id)
    assert Enum.map(results, & &1.record) === complete.recordings
    assert Enum.map(results, & &1.event_seq) == [2, 4]
    assert {:ok, rebuilt} = CheckpointStore.rebuild(c.id)
    assert rebuilt.state === complete.state
    assert rebuilt.audit.checkpoint_seq == 2
    assert rebuilt.audit.replayed_tail_events == 2
    assert RunServer.snapshot(server).tool_stats.effects == 1
  end

  test "cancelled complete candidate leaves a captured input and no accepted result", c do
    gate = make_ref()

    server =
      start_run(c, [{:stream, [{:text_delta, "candidate"}, :done, {:gate, self(), gate}]}])

    assert {:ok, _} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, _worker}
    assert {:ok, [_input]} = ContextStore.list(c.id)
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.recordings == []
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, rebuilt} = CheckpointStore.rebuild(c.id)
    assert rebuilt.state === cancelled.state
    assert rebuilt.audit.mode == :full
  end

  test "a stale provider candidate cannot record or replace a concurrent cancellation", c do
    gate = make_ref()

    server =
      start_run(c, [{:stream, [{:text_delta, "candidate"}, :done, {:gate, self(), gate}]}])

    caller = Task.async(fn -> RunServer.step(server) end)
    assert_receive {:scripted_gate, ^gate, worker}
    assert {:ok, cancelled} = Storage.dispatch(c.id, 1, {:cancel, :other_controller})
    send(worker, {:release, gate})
    assert {:error, {:stale_sequence, 1, 2}} = Task.await(caller)
    assert RunServer.snapshot(server).recordings == []
    assert RunServer.snapshot(server).provider.cursor == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, rebuilt} = CheckpointStore.rebuild(c.id)
    assert rebuilt.state === cancelled.state
  end

  test "fresh VM rebuilds exact state with zero provider and tool calls and no repeated write",
       c do
    assert {:ok, result} = HistoryDemo.run(output: c.root)
    id = result.snapshot.state.run_id
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id]) end)
    report = result.report
    assert report["same_as_live_state"]
    assert report["same_as_expected_state"]
    assert report["full_matches_checkpoint"]
    assert report["recorded_model_results"] == 2
    assert report["checkpoint_seq"] == 2
    assert report["verified_prefix_events"] == 2
    assert report["replayed_tail_events"] == 2
    assert report["original_file_writes"] == 1
    assert report["file_unchanged_by_rebuild"]
    assert report["recorded_response_reused_explicitly"]
    assert map_size(report["effect_boundary_calls"]) == 27

    assert Map.has_key?(
             report["effect_boundary_calls"],
             "AgentSystemsLab.Recovery.execute_claim/2"
           )

    assert Map.has_key?(report["effect_boundary_calls"], "AgentSystemsLab.Scheduler.start_link/1")
    assert Enum.all?(report["effect_boundary_calls"], fn {_boundary, count} -> count == 0 end)
    assert File.read!(Path.join(c.root, "fresh-vm.log")) =~ "HISTORY_AUDIT="
    assert File.read!(Path.join(c.root, "workspace/result.txt")) == "one recorded file effect\n"
    assert {:ok, ^report} = JSON.decode(File.read!(Path.join(c.root, "report.json")))
    assert {:error, {:output_exists, _}} = HistoryDemo.run(output: c.root)
  end
end
