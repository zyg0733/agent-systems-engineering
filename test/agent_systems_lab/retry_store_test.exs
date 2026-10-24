defmodule AgentSystemsLab.RetryStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    Context,
    ErrorPolicy,
    IntentStore,
    Repo,
    RetryPolicy,
    RetryStore,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec
  @moduletag :database

  setup do
    id = "retry-test-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id]) end)
    assert {:ok, _} = Storage.create_run(id, "Retry bounded work")
    assert {:ok, claim} = IntentStore.claim(id, "test-worker")

    assert {:ok, policy} =
             RetryPolicy.new(max_attempts: 3, base_delay_ms: 2000, max_delay_ms: 4000)

    {:ok, id: id, claim: claim, policy: policy}
  end

  test "reservation is durable before effect, and duplicate token cannot reserve twice", c do
    assert {:ok, state} = RetryStore.reserve(c.claim, c.policy, :model)
    assert state.status == :inflight
    assert state.attempt == 1

    assert state.deliveries == [
             %{
               attempt: 1,
               claim_token: c.claim.token,
               started_at_ms: state.first_attempt_at_ms,
               finished_at_ms: nil,
               outcome: :inflight,
               failure: nil
             }
           ]

    assert {:ok, ^state} = RetryStore.load(c.id, 1, :model)
    assert {:ok, [^state]} = RetryStore.list(c.id)
    assert {:error, :retry_attempt_inflight} = RetryStore.reserve(c.claim, c.policy, :model)
    assert {:ok, ^state} = RetryStore.load(c.id, 1, :model)
  end

  test "waiting due time survives claims and premature polling consumes no attempts", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)
    failure = ErrorPolicy.classify(:rate_limited)
    assert {:ok, state} = RetryStore.schedule(c.claim, c.policy, :model, failure)
    assert state.status == :waiting

    finished = hd(state.deliveries).finished_at_ms
    assert state.next_attempt_at_ms >= finished + c.policy.base_delay_ms

    assert :ok = IntentStore.release(c.claim)
    assert {:ok, next} = IntentStore.claim(c.id, "next-worker")
    assert {:error, {:retry_not_due, due}} = RetryStore.reserve(next, c.policy, :model)
    assert due == state.next_attempt_at_ms
    assert {:ok, ^state} = RetryStore.load(c.id, 1, :model)
    make_due(c.id)
    assert {:ok, second} = RetryStore.reserve(next, c.policy, :model)
    assert second.attempts == 2
    assert second.status == :inflight
    assert Enum.map(second.deliveries, & &1.outcome) == [:waiting, :inflight]
    assert {:ok, ^second} = RetryStore.load(c.id, 1, :model)
  end

  test "attempt exhaustion is persisted and cannot reset with a new token", c do
    policy = %{c.policy | max_attempts: 1}
    assert {:ok, _} = RetryStore.reserve(c.claim, policy, :model)
    failure = ErrorPolicy.classify(:timeout)
    assert {:ok, exhausted} = RetryStore.schedule(c.claim, policy, :model, failure)
    assert exhausted.status == :exhausted
    assert exhausted.exhaustion_reason == :attempts
    assert :ok = IntentStore.release(c.claim)
    assert {:ok, next} = IntentStore.claim(c.id, "replacement")
    assert {:error, {:retry_exhausted, ^failure}} = RetryStore.reserve(next, policy, :model)
    assert {:ok, ^exhausted} = RetryStore.load(c.id, 1, :model)
  end

  test "permanent failures never schedule and policy is immutable per intent", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)

    assert {:error, :retry_policy_mismatch} =
             RetryStore.reserve(c.claim, %{c.policy | max_attempts: 2}, :model)

    failure = ErrorPolicy.classify(:permission_denied)
    assert {:ok, state} = RetryStore.schedule(c.claim, c.policy, :model, failure)
    assert state.status == :exhausted
    assert state.exhaustion_reason == :permanent
    assert state.next_attempt_at_ms == nil

    assert {:error, :retry_attempt_not_inflight} =
             RetryStore.schedule(c.claim, c.policy, :model, failure)
  end

  test "success closes an audit reservation without changing Run state", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)
    assert {:ok, %{status: :succeeded}} = RetryStore.finish(c.claim, :model)
    assert {:error, :retry_already_succeeded} = RetryStore.reserve(c.claim, c.policy, :model)
    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state.seq == 1
  end

  test "expired and stale claims cannot schedule or finish a delivery", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)
    expire(c.id)

    assert {:error, :claim_expired} =
             RetryStore.schedule(c.claim, c.policy, :model, ErrorPolicy.classify(:timeout))

    assert {:ok, next} = IntentStore.claim(c.id, "replacement")
    assert {:error, :stale_claim} = RetryStore.finish(c.claim, :model)

    assert {:error, :stale_retry_attempt} =
             RetryStore.schedule(next, c.policy, :model, ErrorPolicy.classify(:timeout))
  end

  test "elapsed ceiling rejects a backoff that would use the remaining window", c do
    policy = %{c.policy | max_elapsed_ms: 1}
    assert {:ok, _} = RetryStore.reserve(c.claim, policy, :model)

    assert {:ok, state} =
             RetryStore.schedule(c.claim, policy, :model, ErrorPolicy.classify(:timeout))

    assert state.status == :exhausted
    assert state.exhaustion_reason == :elapsed
    assert state.next_attempt_at_ms == nil
  end

  test "an enrolled Run absolute deadline remains a ceiling for reservations", c do
    id = c.id <> "-deadline"
    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id=$1", [id]) end)

    assert {:ok, _} =
             AgentSystemsLab.Recovery.create_run(id, "deadline", script: [{:final, "done"}])

    %{rows: [[data]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT progress_data FROM lab_recovery WHERE run_id=$1", [
        id
      ])

    {:ok, progress} = Codec.decode(data)

    {:ok, data} =
      Codec.encode(%{progress | deadline_at_ms: AgentSystemsLab.RecoveryStore.now_ms() - 1})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_recovery SET progress_data=$2 WHERE run_id=$1", [
      id,
      data
    ])

    assert {:ok, claim} = IntentStore.claim(id, "deadline-worker")

    assert {:error, {:budget_exceeded, :run_timeout}} =
             RetryStore.reserve(claim, c.policy, :model)

    assert {:ok, []} = RetryStore.list(id)
  end

  test "accepted Kernel transition closes the current retry journal atomically", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)
    assert {:ok, snapshot} = Storage.dispatch(c.id, 1, {:cancel, :operator})
    assert snapshot.state.status == :cancelled
    assert {:ok, state} = RetryStore.load(c.id, 1, :model)
    assert state.status == :closed
    assert hd(state.deliveries).outcome == :closed
    assert state.next_attempt_at_ms == nil
  end

  test "read-only reconciliation can inspect an expired execution Run", c do
    id = c.id <> "-lookup"
    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id=$1", [id]) end)
    call = %{operation_id: "lost", tool: "mock_write", arguments: %{"value" => "one"}}

    assert {:ok, _} =
             AgentSystemsLab.Recovery.create_run(id, "lookup",
               script: [{:call, call}],
               mock_mode: :unqueryable,
               mock_response: :lost
             )

    assert {:ok, _} = AgentSystemsLab.Recovery.step(id)
    assert {:ok, %{state: %{status: :blocked}}} = AgentSystemsLab.Recovery.step(id)

    %{rows: [[data]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT progress_data FROM lab_recovery WHERE run_id=$1", [
        id
      ])

    {:ok, progress} = Codec.decode(data)

    {:ok, data} =
      Codec.encode(%{progress | deadline_at_ms: AgentSystemsLab.RecoveryStore.now_ms() - 1})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_recovery SET progress_data=$2 WHERE run_id=$1", [
      id,
      data
    ])

    assert {:ok, claim} = IntentStore.claim(id, "lookup-worker")
    assert {:ok, state} = RetryStore.reserve(claim, c.policy, :reconcile)
    assert state.status == :inflight

    failure =
      ErrorPolicy.classify(:lookup_timeout, scope: :reconcile, idempotent?: true, effect: :none)

    assert {:ok, %{status: :waiting}} = RetryStore.schedule(claim, c.policy, :reconcile, failure)
  end

  test "changing a due time cannot bypass the persisted backoff", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)

    assert {:ok, state} =
             RetryStore.schedule(c.claim, c.policy, :model, ErrorPolicy.classify(:timeout))

    stored = Map.drop(state, [:run_id, :seq, :scope, :policy, :attempt])
    put_state(c.id, %{stored | next_attempt_at_ms: stored.next_attempt_at_ms - 1})
    assert {:error, {:corrupt_retry, :invalid_retry_state}} = RetryStore.load(c.id, 1, :model)
  end

  test "corrupt journal prevents a partial Run transition", c do
    assert {:ok, state} = RetryStore.reserve(c.claim, c.policy, :model)
    stored = Map.drop(state, [:run_id, :seq, :scope, :policy, :attempt])
    put_state(c.id, %{stored | schema_version: 2})

    assert {:error, {:corrupt_retry, :invalid_retry_state}} =
             Storage.dispatch(c.id, 1, {:cancel, :operator})

    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state.seq == 1
    assert snapshot.state.status == :running
  end

  test "closing a failed Run preserves the finite retry exhaustion reason", c do
    policy = %{c.policy | max_attempts: 1}
    assert {:ok, _} = RetryStore.reserve(c.claim, policy, :model)
    failure = ErrorPolicy.classify(:timeout)

    assert {:ok, %{exhaustion_reason: :attempts}} =
             RetryStore.schedule(c.claim, policy, :model, failure)

    assert {:ok, _} =
             Storage.dispatch(c.id, 1, {:fail, {:retry_exhausted, :model, :timeout}},
               claim: c.claim
             )

    assert {:ok, state} = RetryStore.load(c.id, 1, :model)
    assert state.status == :closed
    assert state.exhaustion_reason == :attempts
    assert state.last_failure === failure
  end

  test "new model claim accounts abandoned reservation and backs off before another call", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)
    expire(c.id)
    assert {:ok, next} = IntentStore.claim(c.id, "replacement")
    assert {:error, {:retry_not_due, due}} = RetryStore.reserve(next, c.policy, :model)
    assert {:ok, state} = RetryStore.load(c.id, 1, :model)
    assert state.status == :waiting
    assert state.attempts == 1
    assert state.next_attempt_at_ms == due
    assert state.last_failure.reason == {:abandoned_attempt, :model}
    make_due(c.id)
    assert {:ok, %{attempts: 2}} = RetryStore.reserve(next, c.policy, :model)
  end

  test "abandoned tool delivery becomes unknown instead of authorizing another effect", c do
    assert :ok = IntentStore.release(c.claim)

    assert {:ok, _} =
             Storage.dispatch(
               c.id,
               1,
               {:model_response,
                {:call, %{operation_id: "one", tool: "mock_write", arguments: %{"value" => "x"}}}}
             )

    assert {:ok, claim} = IntentStore.claim(c.id, "tool-worker")
    assert {:ok, _} = RetryStore.reserve(claim, c.policy, :tool)
    expire(c.id)
    assert {:ok, replacement} = IntentStore.claim(c.id, "tool-replacement")

    assert {:error, {:retry_exhausted, failure}} =
             RetryStore.reserve(replacement, c.policy, :tool)

    assert failure.class == :unknown
    refute failure.retryable
    assert {:ok, state} = RetryStore.load(c.id, 2, :tool)
    assert state.attempts == 1
    assert state.exhaustion_reason == :ambiguous
  end

  test "writer APIs reject nesting and scope mismatches", c do
    assert {:error, :retry_scope_mismatch} = RetryStore.reserve(c.claim, c.policy, :tool)
    assert {:error, :invalid_retry_scope} = RetryStore.reserve(c.claim, c.policy, :bogus)
    assert {:error, :invalid_claim} = RetryStore.reserve(%{}, c.policy, :model)

    assert {:error, :invalid_retry_options} =
             RetryStore.reserve(c.claim, c.policy, :model, surprise: true)

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> RetryStore.reserve(c.claim, c.policy, :model) end)

    assert {:error, :transaction_required} =
             RetryStore.complete_transition_in_transaction(Repo, %{run_id: c.id, seq: 1}, %{
               status: :failed
             })
  end

  test "payload corruption and forged eligibility fail closed", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)

    assert {:ok, state} =
             RetryStore.schedule(c.claim, c.policy, :model, ErrorPolicy.classify(:rate_limited))

    stored = Map.drop(state, [:run_id, :seq, :scope, :policy, :attempt])
    corrupt = %{stored | last_failure: %{stored.last_failure | reason: :permission_denied}}
    put_state(c.id, corrupt)
    assert {:error, {:corrupt_retry, :invalid_retry_state}} = RetryStore.load(c.id, 1, :model)

    assert {:error, {:corrupt_retry, :invalid_retry_state}} =
             RetryStore.reserve(c.claim, c.policy, :model)
  end

  test "policy hash and source sequence are verified during read", c do
    assert {:ok, _} = RetryStore.reserve(c.claim, c.policy, :model)

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_retries SET policy_sha256=$2 WHERE run_id=$1", [
      c.id,
      Context.hash(:different)
    ])

    assert {:error, {:corrupt_retry, :retry_policy_hash_mismatch}} = RetryStore.list(c.id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_retries SET policy_sha256=$2, seq=100 WHERE run_id=$1",
      [c.id, Context.hash(c.policy)]
    )

    assert {:error, :retry_history_mismatch} = RetryStore.list(c.id)
  end

  for stage <- [:before_commit, :after_commit] do
    test "real worker kill #{stage} preserves the retry reservation commit boundary", c do
      assert_reservation_crash(c, unquote(stage))
    end
  end

  defp assert_reservation_crash(c, stage) do
    parent = self()
    gate = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          RetryStore.reserve(c.claim, c.policy, :model,
            hook: fn current ->
              if current == stage do
                send(parent, {gate, :at_commit, self()})

                receive do
                  {^gate, :continue} -> :ok
                end
              end
            end
          )

        send(parent, {gate, :acknowledged, result})
      end)

    assert_receive {^gate, :at_commit, ^pid}, 5000

    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM lab_retries WHERE run_id=$1", [c.id])

    assert count == if(stage == :after_commit, do: 1, else: 0)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000
    refute_receive {^gate, :acknowledged, _}, 20

    if stage == :after_commit do
      assert {:error, :retry_attempt_inflight} = RetryStore.reserve(c.claim, c.policy, :model)
    else
      assert {:ok, %{attempts: 1}} = RetryStore.reserve(c.claim, c.policy, :model)
    end
  end

  defp expire(id),
    do:
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE lab_intents SET claim_expires_at=clock_timestamp()-interval '1 second' WHERE run_id=$1 AND status='pending'",
        [id]
      )

  defp put_state(id, state) do
    {:ok, data} = Codec.encode(state)

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_retries SET state_data=$2 WHERE run_id=$1", [
      id,
      data
    ])
  end

  defp make_due(id) do
    {:ok, state} = RetryStore.load(id, 1, :model)
    state = Map.drop(state, [:run_id, :seq, :scope, :policy, :attempt])
    shift = state.next_attempt_at_ms - AgentSystemsLab.RecoveryStore.now_ms() + 5

    deliveries =
      Enum.map(state.deliveries, fn d ->
        %{
          d
          | started_at_ms: d.started_at_ms - shift,
            finished_at_ms: if(d.finished_at_ms, do: d.finished_at_ms - shift, else: nil)
        }
      end)

    put_state(id, %{
      state
      | first_attempt_at_ms: state.first_attempt_at_ms - shift,
        attempt_started_at_ms: state.attempt_started_at_ms - shift,
        next_attempt_at_ms: state.next_attempt_at_ms - shift,
        deliveries: deliveries
    })
  end
end
