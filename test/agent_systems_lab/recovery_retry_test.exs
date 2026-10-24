defmodule AgentSystemsLab.RecoveryRetryTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    ContextStore,
    DurableTools,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    RecoveryStore,
    Repo,
    RetryStore,
    Storage
  }

  @moduletag :database

  setup do
    id =
      "recovery-retry-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"]) end)
    %{id: id}
  end

  test "retry is opt-in and the immutable host plan selects the persisted attempt ordinal", c do
    assert {:ok, legacy} =
             Recovery.create_run(c.id <> "-legacy", "original semantics",
               script: [{:error, :unavailable}]
             )

    assert legacy.recovery.retry_config == nil
    assert {:ok, failed} = Recovery.resume(c.id <> "-legacy")
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == :unavailable
    assert failed.recovery.progress.model_attempts == 1
    assert {:ok, []} = RetryStore.list(c.id <> "-legacy")

    assert {:error, :retry_policy_required} =
             Recovery.create_run(c.id <> "-invalid", "no implicit grants",
               model_attempt_scripts: %{0 => [{:final, "unexpected"}]}
             )

    assert {:error, :not_found} = Storage.load(c.id <> "-invalid")
    baseline_script = [{:final, "fallback must never be selected"}]

    assert {:ok, enrolled} =
             Recovery.create_run(c.id, "retry the same input",
               script: baseline_script,
               retry_policy: policy(base_delay_ms: 80),
               model_attempt_scripts: %{
                 0 => [{:error, :unavailable}, {:final, "selected second"}]
               }
             )

    assert enrolled.recovery.retry_config.policy.max_attempts == 3
    assert enrolled.recovery.config.script == baseline_script
    assert {:error, :invalid_recovery_options} = Recovery.step(c.id, retry_policy: [])
    assert {:error, :invalid_recovery_options} = Recovery.resume(c.id, mock_transient_failures: 0)
    assert {:ok, paused} = Recovery.resume(c.id)
    assert paused.state.status == :running
    assert paused.state.seq == 1
    assert paused.recovery.progress.cursor == 0
    assert paused.recovery.progress.model_attempts == 1
    assert paused.recovery.retry.status == :waiting
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, [_]} = ContextStore.list(c.id)
    wait_due(paused)

    assert {:ok, done} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert done.state.status == :succeeded
    assert done.state.output == "selected second"
    assert done.recovery.progress.cursor == 1
    assert done.recovery.progress.model_attempts == 2
    assert done.recovery.retry_config === enrolled.recovery.retry_config
    assert done.recovery.config.script == baseline_script
    assert {:ok, [record]} = ModelResultStore.list(c.id)
    assert record.record.response == {:final, "selected second"}
    assert {:ok, [_first, _second]} = ContextStore.list(c.id)
    assert {:ok, audit} = RetryStore.load(c.id, 1, :model)
    assert audit.attempts == 2
    assert Enum.map(audit.deliveries, & &1.outcome) == [:waiting, :succeeded]
  end

  test "exponential due times are durable and early resume consumes neither claims nor attempts",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "finite retries",
               script: [{:error, :unavailable}],
               retry_policy: policy(base_delay_ms: 200, max_delay_ms: 400)
             )

    assert {:ok, first} = Recovery.step(c.id)
    retry1 = first.recovery.retry
    assert retry1.status == :waiting
    assert retry1.attempts == 1
    assert retry1.next_attempt_at_ms - List.last(retry1.deliveries).finished_at_ms == 200
    generation = first.intent.claim_generation

    for _ <- 1..3 do
      assert {:ok, early} = Recovery.resume(c.id)
      assert early.recovery.retry === retry1
      assert early.intent.claim_generation == generation
      assert early.recovery.progress.model_attempts == 1
    end

    wait_due(first)
    assert {:ok, second} = in_new_process(fn -> Recovery.step(c.id) end)
    retry2 = second.recovery.retry
    assert retry2.attempts == 2
    assert retry2.next_attempt_at_ms - List.last(retry2.deliveries).finished_at_ms == 400
    assert second.recovery.progress.model_attempts == 2
    wait_due(second)
    assert {:ok, exhausted} = Recovery.resume(c.id)
    assert exhausted.state.status == :failed
    assert exhausted.state.terminal_reason == {:retry_exhausted, :model, :unavailable}
    assert exhausted.recovery.progress.model_attempts == 3
    assert {:ok, after_resume} = Recovery.resume(c.id)
    assert after_resume.state === exhausted.state
    assert {:ok, [audit]} = RetryStore.list(c.id)
    assert audit.attempts == 3
    assert audit.status == :closed
    assert audit.next_attempt_at_ms == nil
    assert Enum.map(audit.deliveries, & &1.outcome) == [:waiting, :waiting, :closed]
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "permanent model errors never schedule a retry", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "do not retry permission denial",
               script: [{:error, :permission_denied}],
               retry_policy: policy()
             )

    assert {:ok, failed} = Recovery.resume(c.id)
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == :permission_denied
    assert failed.recovery.progress.model_attempts == 1
    assert {:ok, [audit]} = RetryStore.list(c.id)
    assert audit.attempts == 1
    assert audit.last_failure.class == :permanent
    refute audit.last_failure.retryable
    assert audit.next_attempt_at_ms == nil
  end

  test "two safe transient tool failures create zero effects before the third attempt succeeds",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "bounded idempotent write",
               script: [{:call, mock_call()}, {:final, "done"}],
               retry_policy: policy(base_delay_ms: 40),
               mock_transient_failures: 2
             )

    assert {:ok, waiting} = Recovery.step(c.id)
    assert waiting.state.status == :waiting_tool

    for expected_attempt <- 1..2 do
      assert {:ok, paused} = Recovery.step(c.id)
      assert paused.state.status == :waiting_tool
      assert paused.state.seq == 2
      assert paused.recovery.retry.status == :waiting
      assert paused.recovery.retry.attempts == expected_attempt
      assert paused.recovery.retry.last_failure.class == :transient
      assert paused.recovery.retry.last_failure.effect == :none
      assert DurableTools.stats(c.id).effects == 0
      wait_due(paused)
    end

    assert {:ok, running} = in_new_process(fn -> Recovery.step(c.id) end)
    assert running.state.status == :running
    assert running.state.operations["charge"].status == :ok
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 3, operations: 1}
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert Enum.map(operation.attempts, &elem(&1.result, 0)) == [:error, :error, :ok]
    assert {:ok, audit} = RetryStore.load(c.id, 2, :tool)
    assert audit.attempts == 3
    assert Enum.map(audit.deliveries, & &1.outcome) == [:waiting, :waiting, :succeeded]
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert done.recovery.progress.model_attempts == 2
    assert DurableTools.stats(c.id).effects == 1
  end

  for {stage, effects} <- [before_effect: 0, after_effect: 1] do
    test "unqueryable tool timeout #{stage} enters the visible queue and never repeats the effect",
         c do
      stage = unquote(stage)
      effects = unquote(effects)

      assert {:ok, _} =
               Recovery.create_run(c.id, "ambiguous non-idempotent write",
                 script: [{:call, mock_call()}, {:final, "done"}],
                 mock_mode: :unqueryable,
                 retry_policy: policy(tool_timeout_ms: 150)
               )

      assert {:ok, _} = Recovery.step(c.id)
      parent = self()
      gate = make_ref()

      hook = fn current ->
        if current == stage do
          send(parent, {gate, :at_tool_gate, self()})
          receive do: ({^gate, :continue} -> :ok)
        end
      end

      assert {:ok, blocked} = Recovery.step(c.id, tool_hook: hook)
      assert_receive {^gate, :at_tool_gate, worker}, 1_000
      refute Process.alive?(worker)
      assert blocked.state.status == :blocked
      assert blocked.intent.kind == "reconcile"
      assert DurableTools.stats(c.id).effects == effects
      assert {:ok, entry} = ReconciliationQueue.get(c.id)
      assert entry.safe_mode == :manual
      assert entry.reason.output == %{kind: "timeout", reason: :tool_timeout, effect: "unknown"}
      assert entry.latest_attempt.kind == "observation"
      assert {:ok, [operation]} = DurableTools.list(c.id)
      assert Enum.map(operation.attempts, & &1.kind) == ["execution", "observation"]

      for _ <- 1..2 do
        assert {:ok, same} = Recovery.resume(c.id)
        assert same.state === blocked.state
      end

      assert DurableTools.stats(c.id).effects == effects
      assert DurableTools.stats(c.id).attempts == 2
      assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
      assert {:ok, [_]} = ReconciliationQueue.list(run_id: c.id)
      assert DurableTools.stats(c.id).effects == effects

      assert {:ok, running} =
               Recovery.reconcile(c.id,
                 result: {:ok, %{operator_receipt: "verified actual outcome"}},
                 evidence:
                   "A trusted operator obtained the target's receipt and verified the outcome."
               )

      assert running.state.status == :running
      assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
      assert {:ok, done} = Recovery.resume(c.id)
      assert done.state.status == :succeeded
      assert DurableTools.stats(c.id).effects == effects
    end
  end

  test "timeout after a confirmed receipt reuses it and does not enqueue an invented unknown",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "known receipt outlives worker",
               script: [{:call, mock_call()}, {:final, "done"}],
               retry_policy: policy(tool_timeout_ms: 150)
             )

    assert {:ok, _} = Recovery.step(c.id)
    parent = self()
    gate = make_ref()

    hook = fn
      :after_receipt ->
        send(parent, {gate, :receipt_committed, self()})
        receive do: ({^gate, :continue} -> :ok)

      _ ->
        :ok
    end

    assert {:ok, running} = Recovery.step(c.id, tool_hook: hook)
    assert_receive {^gate, :receipt_committed, worker}, 1_000
    refute Process.alive?(worker)
    assert running.state.status == :running
    assert running.state.operations["charge"].status == :ok
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert operation.status == "completed"
    assert Enum.map(operation.attempts, & &1.outcome) == ["completed", "completed"]
    assert Enum.map(operation.attempts, & &1.kind) == ["execution", "observation"]
    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert DurableTools.stats(c.id).effects == 1
  end

  test "cancelling during backoff closes retries without another provider request", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "cancel while paused",
               script: [{:final, "fallback"}],
               retry_policy: policy(base_delay_ms: 80),
               model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "too late"}]}
             )

    assert {:ok, paused} = Recovery.resume(c.id)
    assert paused.recovery.retry.status == :waiting
    assert {:ok, cancelled} = Recovery.cancel(c.id)
    assert cancelled.state.status == :cancelled
    wait_due(paused)
    assert {:ok, same} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert same.state === cancelled.state
    assert same.recovery.progress.model_attempts == 1
    assert {:ok, [audit]} = RetryStore.list(c.id)
    assert audit.status == :closed
    assert audit.attempts == 1
    assert audit.next_attempt_at_ms == nil
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, [_]} = ContextStore.list(c.id)
  end

  test "a timed out receipt query backs off visibly and the next bounded query resolves without another effect",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "bounded receipt queries",
               script: [{:call, mock_call()}, {:final, "done"}],
               mock_response: :lost,
               retry_policy: policy(base_delay_ms: 200, max_delay_ms: 400, tool_timeout_ms: 100)
             )

    assert {:ok, blocked} = Recovery.resume(c.id)
    assert blocked.state.status == :blocked
    original_bytes = blocked.recovery.progress.output_bytes
    original_deadline = blocked.recovery.progress.deadline_at_ms
    parent = self()
    gate = make_ref()

    hook = fn
      :after_effect ->
        send(parent, {gate, :query_completed_target_lookup, self()})
        receive do: ({^gate, :continue} -> :ok)

      _ ->
        :ok
    end

    assert {:error, {:retry_not_due, due}} = Recovery.reconcile(c.id, tool_hook: hook)
    assert_receive {^gate, :query_completed_target_lookup, worker}, 1_000
    refute Process.alive?(worker)
    assert {:ok, waiting} = Recovery.load(c.id)
    assert waiting.state === blocked.state
    assert waiting.recovery.retry.scope == :reconcile
    assert waiting.recovery.retry.status == :waiting
    assert waiting.recovery.retry.attempts == 1
    assert waiting.recovery.retry.next_attempt_at_ms == due
    assert waiting.recovery.retry.last_failure.class == :timeout
    assert {:ok, [_]} = ReconciliationQueue.list(run_id: c.id)
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 2, operations: 1}

    no_query_gate = make_ref()

    assert {:error, {:retry_not_due, ^due}} =
             Recovery.reconcile(c.id,
               tool_hook: fn stage -> send(parent, {no_query_gate, stage}) end
             )

    refute_receive {^no_query_gate, _}, 10
    assert DurableTools.stats(c.id).attempts == 2
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.recovery.retry === waiting.recovery.retry
    wait_due(waiting)
    assert {:ok, running} = in_new_process(fn -> Recovery.reconcile(c.id) end)
    assert running.state.status == :running
    assert running.recovery.progress.model_attempts == 1
    assert running.recovery.progress.output_bytes == original_bytes
    assert running.recovery.progress.deadline_at_ms == original_deadline
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    assert {:ok, audit} = RetryStore.load(c.id, blocked.state.seq, :reconcile)
    assert audit.attempts == 2
    assert Enum.map(audit.deliveries, & &1.outcome) == [:waiting, :succeeded]
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert done.recovery.progress.model_attempts == 2
    assert done.recovery.progress.deadline_at_ms == original_deadline
    assert DurableTools.stats(c.id).effects == 1
  end

  test "a model timeout retries with a new bounded attempt and never accepts the stopped stream",
       c do
    first = {:stream, [{:sleep, 200}, {:text_delta, "late output"}, :done]}

    assert {:ok, _} =
             Recovery.create_run(c.id, "bounded model timeout",
               script: [{:final, "fallback"}],
               model_timeout_ms: 40,
               retry_policy: policy(base_delay_ms: 80),
               model_attempt_scripts: %{0 => [first, {:final, "ok"}]}
             )

    assert {:ok, paused} = Recovery.resume(c.id)
    assert paused.recovery.retry.status == :waiting
    assert paused.recovery.retry.last_failure.class == :timeout
    assert paused.recovery.progress.model_attempts == 1
    assert paused.recovery.progress.output_bytes == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
    wait_due(paused)
    assert {:ok, done} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert done.state.status == :succeeded
    assert done.state.output == "ok"
    assert done.recovery.progress.model_attempts == 2
    assert done.recovery.progress.output_bytes == 2
    assert {:ok, [record]} = ModelResultStore.list(c.id)
    assert record.record.response == {:final, "ok"}
  end

  test "real kill after reservation consumes its ordinal and replacement backs off before calling the model",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "reserve before any request",
               script: [{:final, "fallback"}],
               retry_policy: policy(base_delay_ms: 100),
               model_attempt_scripts: %{
                 0 => [{:final, "first reserved ordinal"}, {:final, "replacement ordinal"}]
               }
             )

    kill_step_at(c.id, :after_retry_reserve, lease_ms: 100)
    assert {:ok, before} = Recovery.load(c.id)
    assert before.recovery.retry.status == :inflight
    assert before.recovery.retry.attempts == 1
    assert before.recovery.progress.model_attempts == 0
    assert {:ok, []} = ContextStore.list(c.id)
    wait_until_ms(DateTime.to_unix(before.intent.claim_expires_at, :millisecond) + 1)

    assert {:error, {:retry_not_due, due}} =
             in_new_process(fn -> Recovery.step(c.id) end)

    assert {:ok, after_abandonment} = Recovery.load(c.id)
    assert after_abandonment.recovery.retry.status == :waiting
    assert after_abandonment.recovery.retry.next_attempt_at_ms == due
    assert after_abandonment.recovery.retry.attempts == 1
    assert after_abandonment.recovery.retry.last_failure.reason == {:abandoned_attempt, :model}
    assert after_abandonment.recovery.progress.model_attempts == 0
    assert {:ok, early} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert early.recovery.retry === after_abandonment.recovery.retry
    wait_due(after_abandonment)
    assert {:ok, done} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert done.state.status == :succeeded
    assert done.state.output == "replacement ordinal"
    assert done.recovery.progress.model_attempts == 1
    assert {:ok, [audit]} = RetryStore.list(c.id)
    assert audit.attempts == 2
  end

  test "real kill after retry scheduling preserves the exact due time across a new process", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "schedule before acknowledgement",
               script: [{:final, "fallback"}],
               retry_policy: policy(base_delay_ms: 300, max_delay_ms: 600),
               model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "after crash"}]}
             )

    kill_step_at(c.id, :after_retry_schedule, lease_ms: 100)
    assert {:ok, paused} = Recovery.load(c.id)
    assert paused.recovery.retry.status == :waiting
    assert paused.recovery.retry.attempts == 1
    assert paused.recovery.progress.model_attempts == 1
    due = paused.recovery.retry.next_attempt_at_ms
    generation = paused.intent.claim_generation
    assert {:ok, read_by_replacement} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert read_by_replacement.recovery.retry.next_attempt_at_ms == due
    assert read_by_replacement.intent.claim_generation == generation
    wait_due(paused)
    assert {:ok, done} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert done.state.status == :succeeded
    assert done.state.output == "after crash"
    assert done.recovery.progress.model_attempts == 2
    assert {:ok, [audit]} = RetryStore.list(c.id)
    assert audit.attempts == 2
    assert hd(audit.deliveries).outcome == :waiting
  end

  defp mock_call,
    do: %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}

  defp policy(overrides \\ []) do
    Keyword.merge(
      [
        max_attempts: 3,
        base_delay_ms: 60,
        max_delay_ms: 120,
        max_elapsed_ms: 5_000,
        tool_timeout_ms: 1_000
      ],
      overrides
    )
  end

  defp wait_due(snapshot), do: wait_until_ms(snapshot.recovery.retry.next_attempt_at_ms + 1)

  defp wait_until_ms(due) do
    remaining = due - RecoveryStore.now_ms()
    assert remaining < 1_000
    if remaining > 0, do: Process.sleep(remaining)
  end

  defp in_new_process(function), do: function |> Task.async() |> Task.await(5_000)

  defp kill_step_at(id, target, opts) do
    parent = self()
    gate = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn stage ->
          if stage == target do
            send(parent, {gate, :at_runtime_gate, self()})
            receive do: ({^gate, :continue} -> :ok)
          end
        end

        Recovery.step(id, Keyword.put(opts, :hook, hook))
        send(parent, {gate, :acknowledged})
      end)

    assert_receive {^gate, :at_runtime_gate, ^pid}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_receive {^gate, :acknowledged}, 10
  end
end
