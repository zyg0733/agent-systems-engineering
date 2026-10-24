defmodule AgentSystemsLab.DurableIsolationTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    Recovery,
    RecoveryStore,
    Repo,
    RunServer,
    Storage
  }

  alias AgentSystemsLab.Isolation.Policy
  alias AgentSystemsLab.Storage.Codec

  @moduletag :database
  @moduletag :seatbelt

  setup do
    id =
      "durable-isolation-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    root = Path.join(if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"), id)
    File.mkdir_p!(root)
    {:ok, policy} = Policy.new(workspace: root, commands: ["/bin/echo", "/bin/sleep"])

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root, policy: policy}
  end

  test "host policy enrollment is atomic, immutable and independent of the v1 config", c do
    assert {:error, :invalid_isolation_policy} =
             Recovery.create_run(c.id <> "-invalid", "execute",
               isolation_policy: Policy.to_map(c.policy)
             )

    refute Repo.get(AgentSystemsLab.Storage.Run, c.id <> "-invalid")
    assert {:ok, created} = Recovery.create_run(c.id, "execute", isolation_policy: c.policy)
    assert created.recovery.isolation_policy == c.policy
    assert {:ok, saved} = RecoveryStore.load(c.id)
    assert saved.config.schema_version == 1
    refute Map.has_key?(saved.config, :isolation_policy)
    row = Repo.get!(AgentSystemsLab.Storage.Recovery, c.id)
    {:ok, original} = Codec.decode(row.isolation_policy_data, row.codec_version)
    assert original == Policy.to_map(c.policy)
    assert {:error, :invalid_recovery_options} = Recovery.step(c.id, isolation_policy: c.policy)
    {:ok, changed} = Codec.encode(%{original | commands: ["/bin/sleep"]})

    Repo.query!("UPDATE lab_recovery SET isolation_policy_data=$1 WHERE run_id=$2", [
      changed,
      c.id
    ])

    assert {:error, {:corrupt_recovery, :isolation_policy_hash_mismatch}} = Recovery.load(c.id)

    assert {:error, {:corrupt_recovery, :isolation_policy_hash_mismatch}} =
             IntentStore.claim(c.id, "worker")
  end

  test "confirmed isolated receipts are reused without launching another process", c do
    {claim, operation} = waiting(c, "/bin/echo", ["one execution"])
    parent = self()
    opts = [hook: fn stage -> if stage == :after_launch, do: send(parent, :launched) end]
    assert {:ok, {:ok, receipt} = result} = DurableTools.execute(claim, operation, opts)
    assert_receive :launched
    assert receipt.output.output == "one execution\n"
    assert {:ok, ^result} = DurableTools.execute(claim, operation, opts)
    refute_receive :launched, 50
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "completed"
    assert length(record.attempts) == 2
    assert :ok = IntentStore.release(claim)
    assert {:ok, new_claim} = IntentStore.claim(c.id, "replacement")
    assert {:ok, ^result} = DurableTools.execute(new_claim, operation, opts)
    refute_receive :launched, 50

    assert {:ok, _accepted} =
             Storage.dispatch(c.id, new_claim.seq, {:tool_result, operation.operation_id, result},
               claim: new_claim
             )

    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert {:ok, audit} = AgentSystemsLab.RebuildAudit.run(c.id, done.state)
    counts = audit["effect_boundary_calls"]
    assert map_size(counts) == 27
    assert counts["AgentSystemsLab.Tools.Gateway.execute/5"] == 0
    assert counts["AgentSystemsLab.Isolation.execute/3"] == 0
    assert counts["AgentSystemsLab.Isolation.execute/4"] == 0
    assert Enum.all?(counts, fn {_entry, calls} -> calls == 0 end)
  end

  test "a process crash after launch creates a visible unknown receipt without automatic redelivery",
       c do
    {claim, operation} = waiting(c, "/bin/sleep", ["5"])
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        DurableTools.execute(claim, operation,
          hook: fn
            :after_launch ->
              send(parent, {:launched, self()})
              receive do: (:continue -> :ok)

            _ ->
              :ok
          end
        )
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert_receive {:launched, ^pid}, 5000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5000
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")

    assert {:ok, {:unknown, receipt}} =
             DurableTools.execute(next_claim, operation,
               hook: fn stage -> if stage == :after_launch, do: send(parent, :redelivered) end
             )

    refute_receive :redelivered, 50
    assert receipt.output == :receipt_unconfirmed

    assert {:ok, blocked} =
             Storage.dispatch(
               c.id,
               next_claim.seq,
               {:tool_result, operation.operation_id, {:unknown, receipt}},
               claim: next_claim
             )

    assert blocked.state.status == :blocked
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert Enum.map(record.attempts, & &1.outcome) == ["prepared", "unknown"]
  end

  test "a running isolated program holds no Run lock and a cancelled claim cannot archive its late result",
       c do
    {claim, operation} = waiting(c, "/bin/sleep", ["2"])
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          DurableTools.execute(claim, operation,
            hook: fn
              :after_launch ->
                send(parent, {:launched, self()})
                receive do: (:continue -> :ok)

              _ ->
                :ok
            end
          )

        send(parent, {:late_result, result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert_receive {:launched, ^pid}, 5000

    cancel =
      Task.async(fn -> Storage.dispatch(c.id, claim.seq, {:cancel, :operator}, claim: claim) end)

    assert {:ok, cancelled} = Task.await(cancel, 1000)
    assert cancelled.state.status == :cancelled
    send(pid, :continue)
    assert_receive {:late_result, {:error, :stale_claim}}, 5000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    assert {:ok, current} = Recovery.load(c.id)
    assert current.state == cancelled.state
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
  end

  test "the execution wall cap narrows to the remaining host retry window without changing enrollment",
       c do
    {claim, operation} = waiting(c, "/bin/sleep", ["5"])
    deadline = RecoveryStore.now_ms() + 250

    assert {:ok, {:ok, receipt}} =
             DurableTools.execute(claim, operation, deadline_at_ms: deadline)

    assert receipt.output.status == :timed_out
    assert receipt.output.duration_ms <= 1000
    assert {:ok, loaded} = Recovery.load(c.id)
    assert loaded.recovery.isolation_policy == c.policy
    assert c.policy.limits.wall_time_ms == 5000
  end

  test "RunServer persists an isolated worker's unpersistable exit reason and never redelivers",
       c do
    operation = %{
      operation_id: "exec-1",
      tool: "sandbox_exec",
      arguments: %{"command" => "/bin/sleep", "args" => ["5"]}
    }

    server =
      start_supervised!(
        {RunServer,
         run_id: c.id,
         input: "execute",
         storage: :postgres,
         isolation_policy: c.policy,
         script: [{:call, operation}]}
      )

    assert {:ok, waiting} = RunServer.step(server)
    assert waiting.state.status == :waiting_tool
    step = Task.async(fn -> RunServer.step(server) end)
    worker = await_tool_worker(server, 100)
    Process.exit(worker, {:injected_tool_exception, self(), make_ref()})
    assert {:ok, failed} = Task.await(step, 2000)
    assert failed.state.status == :failed
    assert {:unpersistable_failure, :unsupported_term, detail} = failed.state.terminal_reason
    assert detail =~ "tool_worker_exit"
    assert {:ok, persisted} = Storage.load(c.id)
    assert persisted.state == failed.state
    assert persisted.state.operations["exec-1"].result == nil
    assert {:error, {:not_runnable, :failed}} = RunServer.step(server)
    assert :sys.get_state(server).tool_active == nil
    refute Process.alive?(worker)
  end

  defp await_tool_worker(_server, 0), do: flunk("isolated tool did not start")

  defp await_tool_worker(server, attempts) do
    case :sys.get_state(server).tool_active do
      %{task: %{pid: pid}} ->
        pid

      nil ->
        Process.sleep(5)
        await_tool_worker(server, attempts - 1)
    end
  end

  defp waiting(c, command, args) do
    operation = %{
      operation_id: "exec-1",
      tool: "sandbox_exec",
      arguments: %{"command" => command, "args" => args}
    }

    assert {:ok, _} =
             Recovery.create_run(c.id, "execute",
               isolation_policy: c.policy,
               script: [{:call, operation}, {:final, "done"}]
             )

    assert {:ok, snapshot} = Recovery.step(c.id)
    assert snapshot.state.status == :waiting_tool
    assert {:ok, claim} = IntentStore.claim(c.id, "isolated-worker")
    {claim, snapshot.state.operations[operation.operation_id]}
  end
end
