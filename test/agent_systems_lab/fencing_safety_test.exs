defmodule AgentSystemsLab.FencingSafetyTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    ContextStore,
    DurableTools,
    ErrorPolicy,
    IntentStore,
    ModelResultStore,
    Recovery,
    RecoveryStore,
    Repo,
    RetryPolicy,
    RetryStore,
    Storage
  }

  alias AgentSystemsLab.Tools.Result

  @moduletag :database

  setup do
    id = "fencing-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    workspace = Path.join(base, id)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"])
      File.rm_rf!(workspace)
    end)

    %{id: id, workspace: workspace}
  end

  test "the persisted renewed deadline authorizes a live generation despite its old timestamp",
       c do
    assert {:ok, _} = create(c.id)
    assert {:ok, original} = IntentStore.claim(c.id, "worker", lease_ms: 200)
    assert {:ok, renewed} = IntentStore.renew(original, lease_ms: 2_000)
    assert Map.drop(original, [:expires_at]) == Map.drop(renewed, [:expires_at])
    wait_until(DateTime.to_unix(original.expires_at, :millisecond))

    assert {:error, :intent_claimed} = IntentStore.claim(c.id, "competitor")
    assert {:ok, attempt} = RecoveryStore.begin_model_attempt(original)

    assert {:ok, progress} =
             RecoveryStore.charge_frame(
               original,
               attempt.progress.request_token,
               {:text_delta, "x"}
             )

    assert progress.output_bytes == 1
    assert {:ok, :valid} = RecoveryStore.check_attempt(original, attempt.progress.request_token)
    assert :ok = IntentStore.release(original)
  end

  test "a forged future expiry cannot revive a lease that expired in PostgreSQL", c do
    assert {:ok, _} = create(c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "expired", lease_ms: 120)
    wait_for_expiry(c.id)
    forged = %{claim | expires_at: DateTime.add(claim.expires_at, 86_400, :second)}
    before = fingerprint(c.id)

    assert {:error, :claim_expired} = IntentStore.renew(forged)
    assert {:error, :claim_expired} = IntentStore.release(forged)
    assert {:error, :claim_expired} = Recovery.execute_claim(forged)
    assert {:error, :claim_expired} = RecoveryStore.begin_model_attempt(forged)

    assert {:error, :claim_expired} =
             Storage.dispatch(c.id, claim.seq, {:cancel, :late_worker}, claim: forged)

    assert fingerprint(c.id) == before
  end

  test "same-sequence takeover rejects mixed identity fields without revoking the successor", c do
    assert {:ok, _} = create(c.id)
    assert {:ok, old} = IntentStore.claim(c.id, "old", lease_ms: 120)
    successor = takeover(old)
    assert successor.seq == old.seq
    assert successor.generation == old.generation + 1
    before = fingerprint(c.id)

    proofs = [
      old,
      %{successor | generation: old.generation},
      %{successor | token: old.token},
      %{successor | owner: old.owner},
      %{successor | intent_id: successor.intent_id + 100_000}
    ]

    for proof <- proofs do
      assert {:error, :stale_claim} = IntentStore.renew(proof)
      assert {:error, :stale_claim} = IntentStore.release(proof)
      assert {:error, :stale_claim} = Recovery.execute_claim(proof)

      assert {:error, :stale_claim} =
               Storage.dispatch(c.id, successor.seq, {:cancel, :late_worker}, claim: proof)
    end

    assert fingerprint(c.id) == before
    assert {:ok, done} = Recovery.execute_claim(successor)
    assert done.state.status == :succeeded
  end

  test "an assembled old model response cannot commit after a same-sequence takeover", c do
    assert {:ok, _} = create(c.id)
    assert {:ok, old} = IntentStore.claim(c.id, "old-model", lease_ms: 400)

    worker =
      at_gate(fn hook -> Recovery.execute_claim(old, hook: hook) end, :after_model)

    successor = takeover(old)
    before = fingerprint(c.id)
    assert {:error, :stale_claim} = continue(worker)
    assert fingerprint(c.id) == before
    assert {:ok, []} = ModelResultStore.list(c.id)

    assert {:ok, done} = Recovery.execute_claim(successor)
    assert done.state.status == :succeeded
    assert done.recovery.progress.model_attempts == 2
    assert done.recovery.progress.cursor == 1
    assert {:ok, [_accepted]} = ModelResultStore.list(c.id)
  end

  test "successor model accounting preserves prior charges and fences every old request", c do
    assert {:ok, _} = create(c.id)
    assert {:ok, old} = IntentStore.claim(c.id, "old-model", lease_ms: 200)
    assert {:ok, first} = RecoveryStore.begin_model_attempt(old)
    first_token = first.progress.request_token
    assert {:ok, _} = RecoveryStore.charge_frame(old, first_token, {:text_delta, "spent"})
    successor = takeover(old)
    assert {:ok, second} = RecoveryStore.begin_model_attempt(successor)
    assert second.progress.model_attempts == 2
    assert second.progress.output_bytes == 5
    assert second.progress.request_events == 0
    before = fingerprint(c.id)

    assert {:error, :stale_claim} = RecoveryStore.begin_model_attempt(old)
    assert {:error, :stale_claim} = RecoveryStore.charge_frame(old, first_token, :done)
    assert {:error, :stale_claim} = RecoveryStore.check_attempt(old, first_token)

    assert {:error, :stale_model_attempt} =
             RecoveryStore.charge_frame(successor, first_token, {:text_delta, "late"})

    assert {:error, :stale_model_attempt} = RecoveryStore.check_attempt(successor, first_token)
    assert fingerprint(c.id) == before

    assert {:ok, :valid} =
             RecoveryStore.check_attempt(successor, second.progress.request_token)
  end

  test "a stale execute_claim fails before capturing context or reserving provider work", c do
    assert {:ok, _} = create(c.id)
    assert {:ok, old} = IntentStore.claim(c.id, "old-model", lease_ms: 120)
    _successor = takeover(old)
    before = fingerprint(c.id)
    owner = self()

    assert {:error, :stale_claim} =
             Recovery.execute_claim(old,
               hook: fn gate -> send(owner, {:unexpected_gate, gate}) end
             )

    refute_receive {:unexpected_gate, _}, 20
    assert {:ok, []} = ContextStore.list(c.id)
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert fingerprint(c.id) == before
  end

  test "a file worker resumed before its effect cannot write after lease takeover", c do
    operation = file_call()
    {old, operation} = waiting(c.id, operation, workspace: c.workspace)

    worker =
      at_gate(
        fn hook -> DurableTools.execute(old, operation, workspace: c.workspace, hook: hook) end,
        :before_effect
      )

    successor = takeover(old)
    before = fingerprint(c.id)
    assert {:error, :stale_claim} = continue(worker)
    assert fingerprint(c.id) == before
    refute File.exists?(Path.join(c.workspace, "result.txt"))

    assert {:ok, {:unknown, receipt}} =
             DurableTools.execute(successor, operation, workspace: c.workspace)

    assert receipt.output == :receipt_unconfirmed
    refute File.exists?(Path.join(c.workspace, "result.txt"))
    assert %{effects: 0, operations: 1, attempts: 2} = DurableTools.stats(c.id)
  end

  test "a stale receipt writer cannot replace the successor lookup after a committed effect", c do
    {old, operation} = waiting(c.id)

    worker =
      at_gate(fn hook -> DurableTools.execute(old, operation, hook: hook) end, :before_receipt)

    assert %{effects: 1, operations: 1, attempts: 1} = DurableTools.stats(c.id)
    successor = takeover(old)
    assert {:ok, receipt} = DurableTools.reconcile(successor, operation)
    before = fingerprint(c.id)

    assert {:error, :stale_claim} = continue(worker)
    assert fingerprint(c.id) == before
    assert {:ok, ^receipt} = DurableTools.confirmed_receipt(successor, operation)
    assert %{effects: 1, operations: 1, attempts: 2} = DurableTools.stats(c.id)
  end

  test "a stale manual confirmation cannot override a different successor observation", c do
    {old, operation} = waiting(c.id)
    prepare_without_effect(old, operation)

    old_result =
      Result.wrap({:ok, :untrusted_late_success}, operation.operation_id, operation.tool)

    new_result =
      Result.wrap({:error, :verified_no_effect}, operation.operation_id, operation.tool)

    worker =
      at_gate(
        fn hook ->
          DurableTools.confirm(old, operation, old_result, "Old inspection", hook: hook)
        end,
        :after_prepare
      )

    successor = takeover(old)

    assert {:ok, ^new_result} =
             DurableTools.confirm(successor, operation, new_result, "Successor inspected target")

    before = fingerprint(c.id)
    assert {:error, :stale_claim} = continue(worker)
    assert fingerprint(c.id) == before
    assert {:ok, ^new_result} = DurableTools.confirmed_receipt(successor, operation)
    assert DurableTools.stats(c.id).effects == 0
  end

  test "a stale timeout observation cannot overwrite a successor's confirmed success", c do
    {old, operation} = waiting(c.id)
    prepare_without_effect(old, operation)

    worker =
      at_gate(
        fn hook -> DurableTools.observe_timeout(old, operation, :late_timeout, hook: hook) end,
        :before_receipt
      )

    successor = takeover(old)
    assert {:ok, {:ok, _} = receipt} = DurableTools.execute(successor, operation)
    before = fingerprint(c.id)
    assert {:error, :stale_claim} = continue(worker)
    assert fingerprint(c.id) == before
    assert {:ok, ^receipt} = DurableTools.confirmed_receipt(successor, operation)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "every old tool entry point refuses receipt and audit writes after successor confirmation",
       c do
    {old, operation} = waiting(c.id)
    successor = takeover(old)
    assert {:ok, receipt} = DurableTools.execute(successor, operation)
    before = fingerprint(c.id)

    assert {:error, :stale_claim} = DurableTools.execute(old, operation)
    assert {:error, :stale_claim} = DurableTools.reconcile(old, operation)
    assert {:error, :stale_claim} = DurableTools.confirmed_receipt(old, operation)
    assert {:error, :stale_claim} = DurableTools.observe_timeout(old, operation, :timeout)

    assert {:error, :stale_claim} =
             DurableTools.confirm(old, operation, receipt, "Late duplicate evidence")

    assert fingerprint(c.id) == before
    assert %{effects: 1, operations: 1, attempts: 1} = DurableTools.stats(c.id)
  end

  test "a takeover retry reservation cannot be finished or rescheduled by an older generation",
       c do
    assert {:ok, _} = create(c.id, retry_policy: retry_options())
    assert {:ok, policy} = RetryPolicy.new(retry_options())
    assert {:ok, old} = IntentStore.claim(c.id, "old-retry", lease_ms: 120)
    successor = takeover(old)
    assert {:ok, current} = RetryStore.reserve(successor, policy, :model)
    assert current.attempts == 1
    before = fingerprint(c.id)

    assert {:error, :stale_claim} = RetryStore.reserve(old, policy, :model)

    assert {:error, :stale_claim} =
             RetryStore.schedule(old, policy, :model, ErrorPolicy.classify(:timeout))

    assert {:error, :stale_claim} = RetryStore.finish(old, :model)
    assert fingerprint(c.id) == before
    assert {:ok, %{status: :succeeded, attempts: 1}} = RetryStore.finish(successor, :model)
  end

  test "an abandoned retry remains bounded and its due time survives late completion attempts",
       c do
    assert {:ok, _} = create(c.id, retry_policy: retry_options())
    assert {:ok, policy} = RetryPolicy.new(retry_options())
    assert {:ok, old} = IntentStore.claim(c.id, "abandoned", lease_ms: 120)
    assert {:ok, %{attempts: 1}} = RetryStore.reserve(old, policy, :model)
    successor = takeover(old)
    assert {:error, {:retry_not_due, due}} = RetryStore.reserve(successor, policy, :model)
    before = fingerprint(c.id)

    assert {:error, :stale_claim} = RetryStore.finish(old, :model)

    assert {:error, :stale_claim} =
             RetryStore.schedule(old, policy, :model, ErrorPolicy.classify(:timeout))

    assert fingerprint(c.id) == before

    assert {:ok, %{attempts: 1, status: :waiting, next_attempt_at_ms: ^due}} =
             RetryStore.load(c.id, old.seq, :model)

    wait_until(due)
    assert {:ok, second} = RetryStore.reserve(successor, policy, :model)
    assert second.attempts == 2
    assert Enum.map(second.deliveries, & &1.outcome) == [:waiting, :inflight]
    assert {:error, :stale_claim} = RetryStore.finish(old, :model)
    assert {:ok, ^second} = RetryStore.load(c.id, old.seq, :model)
  end

  test "cancellation after model assembly rejects the buffered response and every old request",
       c do
    assert {:ok, _} = create(c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "cancelled-model", lease_ms: 2_000)

    worker =
      at_gate(fn hook -> Recovery.execute_claim(claim, hook: hook) end, :after_model)

    assert {:ok, reserved} = Recovery.load(c.id)
    token = reserved.recovery.progress.request_token
    assert is_binary(token)
    assert {:ok, cancelled} = Recovery.cancel(c.id, :operator)
    before = fingerprint(c.id)
    assert {:error, {:stale_sequence, 1, 2}} = continue(worker)
    assert {:error, :stale_claim} = RecoveryStore.check_attempt(claim, token)
    assert {:error, :stale_claim} = RecoveryStore.charge_frame(claim, token, :done)
    assert fingerprint(c.id) == before
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert cancelled.recovery.progress.cursor == 0
    assert cancelled.recovery.progress.model_attempts == 1
  end

  defp create(id, opts \\ []),
    do:
      Recovery.create_run(
        id,
        "Fence every durable boundary",
        Keyword.put_new(opts, :script, [{:final, "done"}])
      )

  defp waiting(id, operation \\ mock_call(), opts \\ []) do
    assert {:ok, _} =
             create(id, Keyword.put(opts, :script, [{:call, operation}, {:final, "done"}]))

    assert {:ok, waiting} = Recovery.step(id)
    assert {:ok, claim} = IntentStore.claim(id, "old-tool", lease_ms: 400)
    {claim, Map.fetch!(waiting.state.operations, operation.operation_id)}
  end

  defp takeover(old) do
    wait_for_expiry(old.run_id)
    assert {:ok, successor} = IntentStore.claim(old.run_id, "successor", lease_ms: 5_000)
    assert successor.seq == old.seq
    assert successor.generation > old.generation
    refute successor.token == old.token
    successor
  end

  # Wait on the actual PostgreSQL lease. No test rewrites a deadline or advances
  # the database clock, and a renewal cannot be hidden by an old claim snapshot.
  defp wait_for_expiry(id) do
    %{rows: [[remaining]]} =
      Repo.query!(
        """
        SELECT greatest(0, ceil(extract(epoch FROM
          (claim_expires_at - (clock_timestamp() AT TIME ZONE 'UTC'))) * 1000))::integer
        FROM lab_intents WHERE run_id = $1 AND status = 'pending'
        """,
        [id]
      )

    if remaining > 0 do
      Process.sleep(min(remaining + 2, 50))
      wait_for_expiry(id)
    end
  end

  defp wait_until(due) do
    remaining = due - RecoveryStore.now_ms()

    if remaining > 0 do
      Process.sleep(min(remaining + 2, 50))
      wait_until(due)
    end
  end

  defp fingerprint(id) do
    assert {:ok, recovery} = Recovery.load(id)
    assert {:ok, tools} = DurableTools.list(id)
    assert {:ok, retries} = RetryStore.list(id)
    assert {:ok, contexts} = ContextStore.list(id)
    assert {:ok, models} = ModelResultStore.list(id)

    %{recovery: recovery, tools: tools, retries: retries, contexts: contexts, models: models}
  end

  defp at_gate(function, stage) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn current ->
          if current == stage do
            send(owner, {ref, :gate, self()})
            receive do: ({^ref, :continue} -> :ok)
          end
        end

        result = function.(hook)
        send(owner, {ref, :result, self(), result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {^ref, :gate, ^pid}, 5_000
    %{pid: pid, ref: ref, monitor: monitor}
  end

  defp continue(%{pid: pid, ref: ref, monitor: monitor}) do
    send(pid, {ref, :continue})
    assert_receive {^ref, :result, ^pid, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp prepare_without_effect(claim, operation) do
    worker =
      at_gate(fn hook -> DurableTools.execute(claim, operation, hook: hook) end, :after_prepare)

    Process.exit(worker.pid, :kill)
    monitor = worker.monitor
    pid = worker.pid
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    assert %{effects: 0, operations: 1, attempts: 1} = DurableTools.stats(claim.run_id)
  end

  defp mock_call,
    do: %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}

  defp file_call do
    %{
      operation_id: "write",
      tool: "file_write",
      arguments: %{"path" => "result.txt", "content" => "once\n", "expected_sha256" => "absent"}
    }
  end

  defp retry_options,
    do: [max_attempts: 3, base_delay_ms: 30, max_delay_ms: 60, max_elapsed_ms: 5_000]
end
