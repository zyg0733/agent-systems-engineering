defmodule AgentSystemsLab.DurableMCPTest do
  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :seatbelt
  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    MCPFixture,
    RebuildAudit,
    ReconciliationQueue,
    Recovery,
    RecoveryStore,
    Repo,
    Storage
  }

  alias AgentSystemsLab.MCP.Policy
  alias AgentSystemsLab.Storage.Codec

  setup do
    id = "durable-mcp-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"
    root = Path.join("/private/tmp", id)
    File.mkdir_p!(root)
    {:ok, policy} = MCPFixture.policy(root)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root, policy: policy}
  end

  test "MCP host policy is an immutable sidecar and corrupt authority blocks claim and load", c do
    assert {:error, :invalid_mcp_policy} =
             Recovery.create_run(c.id <> "-invalid", "echo", mcp_policy: Policy.to_map(c.policy))

    refute Repo.get(AgentSystemsLab.Storage.Run, c.id <> "-invalid")
    assert {:ok, saved} = Recovery.create_run(c.id, "echo", mcp_policy: c.policy)
    assert saved.recovery.mcp_policy == c.policy
    assert saved.recovery.config.schema_version == 1
    refute Map.has_key?(saved.recovery.config, :mcp_policy)
    assert {:error, :invalid_recovery_options} = Recovery.step(c.id, mcp_policy: c.policy)
    row = Repo.get!(AgentSystemsLab.Storage.Recovery, c.id)
    {:ok, policy_map} = Codec.decode(row.mcp_policy_data, row.codec_version)
    assert policy_map == Policy.to_map(c.policy)
    {:ok, changed} = Codec.encode(%{policy_map | request_timeout_ms: 7})
    Repo.query!("UPDATE lab_recovery SET mcp_policy_data=$1 WHERE run_id=$2", [changed, c.id])
    assert {:error, {:corrupt_recovery, :mcp_policy_hash_mismatch}} = Recovery.load(c.id)

    assert {:error, {:corrupt_recovery, :mcp_policy_hash_mismatch}} =
             IntentStore.claim(c.id, "worker")
  end

  test "legacy enrollment and simultaneous isolated/MCP policy remain independently readable",
       c do
    assert {:ok, legacy} = Recovery.create_run(c.id <> "-legacy", "legacy")
    assert legacy.recovery.mcp_policy == nil

    assert {:ok, combined} =
             Recovery.create_run(c.id, "combined",
               mcp_policy: c.policy,
               isolation_policy: c.policy.isolation_policy,
               retry_policy: []
             )

    assert combined.recovery.mcp_policy == c.policy
    assert combined.recovery.isolation_policy == c.policy.isolation_policy
    assert {:ok, loaded} = RecoveryStore.load(c.id)
    assert loaded.mcp_policy == c.policy
  end

  test "confirmed paired MCP receipts survive a new claim and history reconstruction without redelivery",
       c do
    {claim, operation} = waiting(c, "echo", %{"text" => "one MCP effect"})
    parent = self()
    opts = [hook: fn stage -> if stage == :after_mcp_request, do: send(parent, :called) end]
    assert {:ok, {:ok, receipt} = result} = DurableTools.execute(claim, operation, opts)
    assert_receive :called
    assert receipt.operation_id == operation.operation_id
    assert receipt.tool == operation.tool
    assert inspect(receipt.output) =~ "one MCP effect"
    assert {:ok, ^result} = DurableTools.execute(claim, operation, opts)
    refute_receive :called, 50
    assert :ok = IntentStore.release(claim)
    assert {:ok, replacement} = IntentStore.claim(c.id, "replacement")
    assert {:ok, ^result} = DurableTools.execute(replacement, operation, opts)
    refute_receive :called, 50

    assert {:ok, _} =
             Storage.dispatch(
               c.id,
               replacement.seq,
               {:tool_result, operation.operation_id, result},
               claim: replacement
             )

    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert {:ok, audit} = RebuildAudit.run(c.id, done.state)
    assert map_size(audit["effect_boundary_calls"]) == 27
    assert audit["effect_boundary_calls"]["AgentSystemsLab.MCP.execute/4"] == 0
    assert Enum.all?(audit["effect_boundary_calls"], fn {_name, calls} -> calls == 0 end)
  end

  test "death after tools/call enters manual unknown reconciliation and never repeats the prepared request",
       c do
    {:ok, policy} = MCPFixture.policy(c.root, "timeout", request_timeout_ms: 4000)
    {claim, operation} = waiting(%{c | policy: policy}, "wait", %{"milliseconds" => 3000})
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        DurableTools.execute(claim, operation,
          hook: fn
            :after_mcp_request ->
              send(parent, {:sent, self()})
              receive do: (:continue -> :ok)

            _ ->
              :ok
          end
        )
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:sent, ^pid}, 5000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000
    assert :ok = IntentStore.release(claim)
    assert {:ok, replacement} = IntentStore.claim(c.id, "replacement")

    assert {:ok, {:unknown, receipt} = result} =
             DurableTools.execute(replacement, operation,
               hook: fn stage -> if stage == :after_mcp_request, do: send(parent, :resent) end
             )

    refute_receive :resent, 50
    assert receipt.output == :receipt_unconfirmed

    assert {:ok, blocked} =
             Storage.dispatch(
               c.id,
               replacement.seq,
               {:tool_result, operation.operation_id, result},
               claim: replacement
             )

    assert blocked.state.status == :blocked
    assert {:ok, entry} = ReconciliationQueue.get(c.id)
    assert entry.safe_mode == :manual
    assert entry.journal_status == "unknown"
    assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
    refute_receive :resent, 50
  end

  test "an effect followed by a disconnected MCP result blocks visibly without claiming no effect",
       c do
    {:ok, policy} = MCPFixture.policy(c.root, "after_effect_drop")

    assert {:ok, _} =
             Recovery.create_run(c.id, "write",
               mcp_policy: policy,
               script: [
                 call("write_note", %{"path" => "note.txt", "content" => "committed externally"}),
                 {:final, "done"}
               ]
             )

    assert {:ok, _} = Recovery.step(c.id)
    assert {:ok, blocked} = Recovery.step(c.id)
    assert blocked.state.status == :blocked
    assert File.read!(Path.join(c.root, "note.txt")) == "committed externally"
    assert {:ok, entry} = ReconciliationQueue.get(c.id)
    assert entry.safe_mode == :manual
    assert entry.journal_status == "unknown"
    assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
    assert {:ok, records} = DurableTools.list(c.id)
    assert Enum.all?(records, &(&1.status == "unknown"))
  end

  test "MCP execution holds no SQL Run lock and a cancelled claim rejects its late receipt", c do
    {claim, operation} = waiting(c, "echo", %{"text" => "late receipt"})
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          DurableTools.execute(claim, operation,
            hook: fn
              :after_mcp_request ->
                send(parent, {:sent, self()})
                receive do: (:continue -> :ok)

              _ ->
                :ok
            end
          )

        send(parent, {:late, result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:sent, ^pid}, 5000

    cancel =
      Task.async(fn -> Storage.dispatch(c.id, claim.seq, {:cancel, :operator}, claim: claim) end)

    assert {:ok, cancelled} = Task.await(cancel, 1000)
    assert cancelled.state.status == :cancelled
    send(pid, :continue)
    assert_receive {:late, {:error, :stale_claim}}, 5000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
    assert {:ok, loaded} = Recovery.load(c.id)
    assert loaded.state == cancelled.state
  end

  test "the remaining host retry deadline narrows MCP execution without altering enrollment", c do
    {:ok, policy} = MCPFixture.policy(c.root, "timeout", request_timeout_ms: 4000)
    {claim, operation} = waiting(%{c | policy: policy}, "wait", %{"milliseconds" => 3000})
    deadline = RecoveryStore.now_ms() + 300
    started = System.monotonic_time(:millisecond)

    assert {:ok, {:unknown, receipt}} =
             DurableTools.execute(claim, operation, deadline_at_ms: deadline)

    assert System.monotonic_time(:millisecond) - started < 2000
    assert receipt.operation_id == operation.operation_id
    assert {:ok, loaded} = Recovery.load(c.id)
    assert loaded.recovery.mcp_policy == policy
    assert policy.request_timeout_ms == 4000
  end

  test "a fresh BEAM safely reads a real MCP pre-call error receipt without executing MCP", c do
    {:ok, policy} = MCPFixture.policy(c.root, "version_mismatch")
    {claim, operation} = waiting(%{c | policy: policy}, "echo", %{"text" => "never sent"})
    assert {:ok, {:error, receipt} = result} = DurableTools.execute(claim, operation)
    assert receipt.output == :mcp_negotiation_failed

    assert {:ok, current} =
             Storage.dispatch(c.id, claim.seq, {:tool_result, operation.operation_id, result},
               claim: claim
             )

    assert current.state.operations[operation.operation_id].status == :error

    trace =
      File.read!(Path.join(c.root, ".mcp-trace.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    refute Enum.any?(trace, &(&1["phase"] == "call"))
    assert {:ok, audit, log} = AgentSystemsLab.HistoryDemo.fresh_audit(c.id, current.state)
    assert log =~ "HISTORY_AUDIT="
    assert audit["same_as_expected_state"]
    assert map_size(audit["effect_boundary_calls"]) == 27
    assert Enum.all?(audit["effect_boundary_calls"], fn {_name, calls} -> calls == 0 end)
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.state == current.state

    assert File.read!(Path.join(c.root, ".mcp-trace.jsonl"))
           |> String.split("\n", trim: true)
           |> Enum.map(&JSON.decode!/1) == trace
  end

  defp waiting(c, remote, arguments) do
    assert {:ok, _} =
             Recovery.create_run(c.id, "MCP",
               mcp_policy: c.policy,
               script: [call(remote, arguments), {:final, "done"}]
             )

    assert {:ok, waiting} = Recovery.step(c.id)
    assert waiting.state.status == :waiting_tool
    assert {:ok, claim} = IntentStore.claim(c.id, "mcp-worker")
    {claim, waiting.state.operations["mcp-1"]}
  end

  defp call(remote, arguments),
    do: {:call, %{operation_id: "mcp-1", tool: "mcp.fixture." <> remote, arguments: arguments}}
end
