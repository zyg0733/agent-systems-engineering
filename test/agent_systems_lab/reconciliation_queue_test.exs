defmodule AgentSystemsLab.ReconciliationQueueTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    ReconciliationQueue,
    Recovery,
    Repo,
    Storage
  }

  @moduletag :database

  setup do
    id =
      "reconcile-queue-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    root = Path.join(base, id)
    File.mkdir_p!(root)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  test "unqueryable ambiguity is visible, read-only, and remains queued after an unproved lookup",
       c do
    call = %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}

    assert {:ok, _} =
             Recovery.create_run(c.id, "visible ambiguity",
               script: [{:call, call}, {:final, "done"}],
               mock_mode: :unqueryable,
               mock_response: :lost
             )

    assert {:ok, blocked} = Recovery.resume(c.id)
    assert blocked.state.status == :blocked
    before = DurableTools.stats(c.id)
    assert before.effects == 1

    assert {:ok, [entry]} =
             without_target_calls(fn -> ReconciliationQueue.list(run_id: c.id) end)

    assert entry.run_id == c.id
    assert entry.operation_id == "charge"
    assert entry.tool == "mock_write"
    assert entry.safe_mode == :manual
    assert entry.recoverable
    assert entry.reason.output == :receipt_lost
    assert entry.latest_attempt.kind == "execution"
    assert entry.latest_attempt.outcome == "unknown"
    assert entry.age_ms >= 0
    assert {:ok, same} = ReconciliationQueue.get(c.id)
    assert Map.drop(same, [:age_ms]) === Map.drop(entry, [:age_ms])
    assert DurableTools.stats(c.id) == before

    assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
    assert {:ok, [_entry]} = ReconciliationQueue.list(run_id: c.id)
    assert DurableTools.stats(c.id).effects == 1

    assert {:ok, _} =
             Recovery.reconcile(c.id,
               result: {:ok, %{operator_receipt: "external receipt verified"}},
               evidence: "Operator obtained the actual receipt from the target."
             )

    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    assert {:error, :not_in_reconciliation_queue} = ReconciliationQueue.get(c.id)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "queryable unknown is listed without a target call and disappears after reconciliation",
       c do
    call = %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}

    assert {:ok, _} =
             Recovery.create_run(c.id, "queryable receipt",
               script: [{:call, call}, {:final, "done"}],
               mock_response: :lost
             )

    assert {:ok, _} = Recovery.resume(c.id)
    assert {:ok, [entry]} = ReconciliationQueue.list(run_id: c.id)
    assert entry.safe_mode == :queryable
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert length(record.attempts) == 1
    assert {:ok, _} = Recovery.reconcile(c.id)
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "legacy unknown without an operation journal remains visible and cancellable", c do
    call = %{operation_id: "legacy", tool: "mock_write", arguments: %{"amount" => 1}}
    assert {:ok, initial} = Storage.create_run(c.id, "legacy unknown")

    assert {:ok, waiting} =
             Storage.dispatch(c.id, initial.state.seq, {:model_response, {:call, call}})

    assert {:ok, blocked} =
             Storage.dispatch(
               c.id,
               waiting.state.seq,
               {:tool_result, "legacy", {:unknown, :lost}}
             )

    assert {:ok, entry} = ReconciliationQueue.get(c.id)
    assert entry.safe_mode == :manual
    refute entry.recoverable
    assert entry.latest_attempt == nil
    assert entry.reason == :lost
    assert {:ok, _} = Storage.dispatch(c.id, blocked.state.seq, {:cancel, :operator_cancelled})
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
  end

  test "file timeout is visible as manual reconciliation without executing the file", c do
    call = %{
      operation_id: "write",
      tool: "file_write",
      arguments: %{"path" => "out.txt", "content" => "x", "expected_sha256" => "absent"}
    }

    assert {:ok, initial} = Storage.create_run(c.id, "timeout ambiguity")

    assert {:ok, waiting} =
             Storage.dispatch(c.id, initial.state.seq, {:model_response, {:call, call}})

    assert {:ok, claim} = IntentStore.claim(c.id, "timeout-observer")

    assert {:ok, result} =
             DurableTools.observe_timeout(claim, call, :tool_timeout, workspace: c.root)

    assert {:ok, _} =
             Storage.dispatch(c.id, waiting.state.seq, {:tool_result, "write", result},
               claim: claim
             )

    assert {:ok, entry} = ReconciliationQueue.get(c.id)
    assert entry.safe_mode == :manual
    assert entry.latest_attempt.kind == "observation"
    assert entry.reason.output.effect == "unknown"
    refute File.exists?(Path.join(c.root, "out.txt"))
    assert DurableTools.stats(c.id).attempts == 1
  end

  test "invalid filters fail and corrupt operation data cannot become a clean queue entry", c do
    for options <- [[limit: 0], [limit: 1001], [limit: 1.0], [run_id: 1], [effect: :execute]] do
      assert {:error, :invalid_queue_options} = ReconciliationQueue.list(options)
    end

    assert {:error, :invalid_queue_options} = ReconciliationQueue.get(nil)
    call = %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}
    assert {:ok, initial} = Storage.create_run(c.id, "corruption visibility")

    assert {:ok, waiting} =
             Storage.dispatch(c.id, initial.state.seq, {:model_response, {:call, call}})

    assert {:ok, claim} = IntentStore.claim(c.id, "worker")
    assert {:ok, result} = DurableTools.execute(claim, call, mock_response: :lost)

    assert {:ok, _} =
             Storage.dispatch(c.id, waiting.state.seq, {:tool_result, "charge", result},
               claim: claim
             )

    Repo.query!("UPDATE lab_operations SET input_sha256=$1 WHERE run_id=$2", ["bad", c.id])
    assert {:error, :operation_input_mismatch} = ReconciliationQueue.list(run_id: c.id)
    assert DurableTools.stats(c.id).effects == 1
  end

  defp without_target_calls(function) do
    boundaries = [
      {AgentSystemsLab.Tools.DurableMock, :lookup, 3},
      {AgentSystemsLab.Tools.DurableMock, :execute, 5},
      {AgentSystemsLab.Tools.Files, :execute, 4},
      {AgentSystemsLab.Providers.Scripted, :stream, 3}
    ]

    for {module, _, _} = mfa <- boundaries do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:call_count]) == 1
    end

    try do
      result = function.()
      for mfa <- boundaries, do: assert(:erlang.trace_info(mfa, :call_count) == {:call_count, 0})
      result
    after
      for mfa <- boundaries, do: :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end
end
