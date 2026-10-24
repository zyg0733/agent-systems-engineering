defmodule AgentSystemsLab.ObservabilityExecutionTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    ErrorPolicy,
    IntentStore,
    ModelResultStore,
    Observability,
    Recovery,
    Repo,
    RetryPolicy,
    RetryStore,
    Storage
  }

  @moduletag :database

  defmodule FailingExporter do
    @behaviour AgentSystemsLab.Observability.Exporter
    @impl true
    def export(_events, opts) do
      case opts[:mode] do
        :error -> {:error, :unavailable}
        :raise -> raise "exporter exception must not enter execution"
        :exit -> exit(:exporter_exit)
        :timeout -> Process.sleep(:infinity)
      end
    end
  end

  setup do
    id =
      "observe-execution-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    # A prior Repo-restart test may legitimately leave the temporary observer
    # stopped. This suite explicitly enables its diagnostic test fixture.
    if is_nil(Process.whereis(AgentSystemsLab.Observability.Buffer)) do
      assert {:ok, _} = Observability.restart()
    end

    assert :ok = Observability.flush()
    configure_null()

    on_exit(fn ->
      :ok = Observability.flush(AgentSystemsLab.Observability.Buffer, 5_000)
      configure_null()
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"])
    end)

    %{id: id}
  end

  test "model, tool, claim and accepted history share Run correlation without exporting contents",
       c do
    secret = "secret body must never be an observation"
    operation = %{operation_id: "once", tool: "mock_write", arguments: %{"secret" => secret}}

    assert {:ok, _} =
             Recovery.create_run(c.id, secret, script: [{:call, operation}, {:final, secret}])

    owner = self()

    hook = fn
      :after_input ->
        {:ok, current} = Recovery.load(c.id)
        send(owner, {:request_token, current.recovery.progress.request_token})

      _ ->
        :ok
    end

    assert {:ok, final} = Recovery.resume(c.id, owner: "owner-secret-not-exportable", hook: hook)
    assert final.state.status == :succeeded
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 1, operations: 1}
    assert {:ok, [_, _] = recordings} = ModelResultStore.list(c.id)
    assert_receive {:request_token, first_token}
    assert_receive {:request_token, second_token}
    events = events(c.id)
    names = Enum.map(events, & &1["event_name"])
    assert "model_recorded" in names
    assert "tool_completed" in names
    assert "intent_claimed" in names
    assert "recovery_stopped" in names
    assert length(Enum.filter(names, &(&1 == "model_started"))) == 2
    assert length(Enum.filter(names, &(&1 == "model_stopped"))) == 2

    for group <- ["model", "tool"] do
      started = Enum.filter(events, &(&1["event_name"] == group <> "_started"))
      stopped = Enum.filter(events, &(&1["event_name"] == group <> "_stopped"))

      assert Enum.map(started, & &1["span_id"]) |> Enum.sort() ==
               Enum.map(stopped, & &1["span_id"]) |> Enum.sort()
    end

    assert length(Enum.uniq(Enum.map(events, & &1["trace_id"]))) == 1
    assert Enum.all?(events, &(&1["span_id"] != &1["parent_span_id"]))
    {:ok, query} = AgentSystemsLab.Observability.Query.run(c.id)
    kernel_events = Enum.filter(events, &(&1["event_name"] == "event_committed"))
    kernel_spans = Enum.filter(query["spans"], &(&1["kind"] == "kernel_event"))

    assert Enum.sort(Enum.map(kernel_events, & &1["span_id"])) ==
             Enum.sort(Enum.map(kernel_spans, & &1["span_id"]))

    encoded = JSON.encode!(events)
    refute encoded =~ secret
    refute encoded =~ "owner-secret"
    refute encoded =~ "arguments"
    refute encoded =~ "claim_token"
    refute encoded =~ first_token
    refute encoded =~ second_token
    starts = Enum.filter(events, &(&1["event_name"] == "model_started"))
    recorded = Enum.filter(events, &(&1["event_name"] == "model_recorded"))

    assert Enum.sort(Enum.map(starts, & &1["span_id"])) ==
             Enum.sort(Enum.map(recorded, & &1["span_id"]))

    assert Enum.sort(Enum.map(starts, & &1["correlation"]["attempt_id"])) ==
             Enum.sort(Enum.map(recordings, & &1.context_id))

    before = length(events)
    assert {:ok, _} = Recovery.load(c.id)
    assert {:ok, _} = AgentSystemsLab.CheckpointStore.rebuild(c.id)
    assert length(events(c.id)) == before
  end

  test "rolled back creation and internal enrollment cannot emit false committed facts", c do
    assert_raise RuntimeError, "before commit", fn ->
      Storage.create_run(c.id, "private input", hook: crash_hook(:before_commit))
    end

    assert {:error, :not_found} = Storage.load(c.id)
    assert events(c.id) == []

    assert {:error, :cancel_enrollment} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Recovery.create_run_in_transaction(Repo, c.id, "private input",
                          script: [{:final, "done"}]
                        )

               Repo.rollback(:cancel_enrollment)
             end)

    assert {:error, :not_found} = Storage.load(c.id)
    assert events(c.id) == []
  end

  test "rollback does not announce a transition; after COMMIT hook failure still has committed evidence",
       c do
    assert {:ok, initial} = Storage.create_run(c.id, "private input")
    before = length(events(c.id))

    assert_raise RuntimeError, "before commit", fn ->
      Storage.dispatch(c.id, initial.state.seq, {:model_response, {:final, "done"}},
        hook: crash_hook(:before_commit)
      )
    end

    assert length(events(c.id)) == before
    assert {:ok, ^initial} = Storage.load(c.id)

    assert_raise RuntimeError, "after commit", fn ->
      Storage.dispatch(c.id, initial.state.seq, {:model_response, {:final, "done"}},
        hook: crash_hook(:after_commit)
      )
    end

    assert {:ok, final} = Storage.load(c.id)
    assert final.state.status == :succeeded

    assert Enum.any?(
             events(c.id),
             &(&1["event_name"] == "run_committed" and &1["attributes"]["phase"] == "committed")
           )

    assert Enum.count(events(c.id), &(&1["event_name"] == "event_committed")) == 2
  end

  test "expired and superseded claims remain rejected, without late success observations", c do
    assert {:ok, _} = Storage.create_run(c.id, "work")
    assert {:ok, old} = IntentStore.claim(c.id, "old-secret-owner")

    Repo.query!(
      "UPDATE lab_intents SET claim_expires_at=clock_timestamp()-interval '1 second' WHERE run_id=$1",
      [c.id]
    )

    assert {:error, :claim_expired} = IntentStore.renew(old)
    assert {:ok, replacement} = IntentStore.claim(c.id, "new-secret-owner")

    assert {:error, :stale_claim} =
             Storage.dispatch(c.id, old.seq, {:model_response, {:final, "late"}}, claim: old)

    assert {:error, :stale_claim} = IntentStore.release(old)
    assert {:ok, current} = Storage.load(c.id)
    assert current.state.status == :running
    assert current.intent.claim_token == replacement.token
    events = events(c.id)

    assert Enum.any?(
             events,
             &(&1["event_name"] == "lease_rejected" and
                 &1["correlation"]["generation"] == old.generation)
           )

    refute Enum.any?(events, &(&1["attributes"]["status"] == "succeeded"))
    refute JSON.encode!(events) =~ old.token
    refute JSON.encode!(events) =~ "secret-owner"
  end

  test "unknown receipt and operator query are visible without another tool effect", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, {:unknown, receipt}} =
             DurableTools.execute(claim, operation, mock_response: :lost)

    assert {:ok, blocked} =
             Storage.dispatch(
               c.id,
               claim.seq,
               {:tool_result, operation.operation_id, {:unknown, receipt}},
               claim: claim
             )

    assert blocked.state.status == :blocked
    assert {:ok, query} = IntentStore.claim(c.id, "reconciler")
    assert {:ok, {:ok, _}} = DurableTools.reconcile(query, operation)
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 2, operations: 1}
    events = events(c.id)

    assert Enum.any?(
             events,
             &(&1["event_name"] == "tool_unknown" and &1["attributes"]["phase"] == "committed")
           )

    assert Enum.any?(
             events,
             &(&1["event_name"] == "tool_reconciled" and
                 &1["correlation"]["operation_id"] == "once")
           )

    assert events
           |> Enum.filter(&(&1["event_name"] == "tool_prepared"))
           |> Enum.map(& &1["correlation"]["attempt_id"])
           |> Enum.uniq()
           |> length() == 2

    assert Enum.count(events, &(&1["event_name"] == "tool_started")) == 1
  end

  test "retry observations follow committed reservation and due time, not rollback or polling",
       c do
    assert {:ok, _} = Storage.create_run(c.id, "retry")
    assert {:ok, claim} = IntentStore.claim(c.id, "worker")
    assert {:ok, policy} = RetryPolicy.new(base_delay_ms: 5000)

    assert_raise RuntimeError, "before commit", fn ->
      RetryStore.reserve(claim, policy, :model, hook: crash_hook(:before_commit))
    end

    refute Enum.any?(events(c.id), &(&1["event_name"] == "retry_reserved"))
    assert {:ok, reserved} = RetryStore.reserve(claim, policy, :model)
    assert reserved.attempt == 1

    assert {:ok, scheduled} =
             RetryStore.schedule(claim, policy, :model, ErrorPolicy.classify(:rate_limited))

    assert scheduled.status == :waiting
    assert :ok = IntentStore.release(claim)
    assert {:ok, next} = IntentStore.claim(c.id, "replacement")
    assert {:error, {:retry_not_due, due}} = RetryStore.reserve(next, policy, :model)
    assert due == scheduled.next_attempt_at_ms
    events = events(c.id)
    assert Enum.count(events, &(&1["event_name"] == "retry_reserved")) == 1
    assert Enum.count(events, &(&1["event_name"] == "retry_scheduled")) == 1
  end

  for mode <- [:error, :raise, :exit, :timeout] do
    @mode mode
    test "exporter #{mode} cannot change effects, model receipts, budgets or final state", c do
      baseline = finish(c.id <> "-baseline")
      before = Observability.stats()

      assert :ok =
               Observability.configure(
                 exporter: {FailingExporter, [mode: @mode]},
                 export_timeout_ms: 20,
                 backoff_ms: 1
               )

      broken = finish(c.id <> "-broken")
      assert broken == baseline
      assert :ok = Observability.flush(AgentSystemsLab.Observability.Buffer, 5_000)
      after_stats = Observability.stats()
      assert after_stats.export_errors > before.export_errors
      if @mode == :timeout, do: assert(after_stats.export_timeouts > before.export_timeouts)
    end
  end

  test "Worker watchdog emits a Run-correlated timeout before reclaiming a gated executor", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "private input",
               script: [{:final, "done"}],
               task_budget: [max_dispatches: 4, execution_timeout_ms: 100]
             )

    parent = self()
    marker = make_ref()

    hook = fn
      :after_input ->
        send(parent, {marker, self()})
        receive do: ({^marker, :continue} -> :ok)

      _ ->
        :ok
    end

    {:ok, scheduler} =
      AgentSystemsLab.Scheduler.start_link(
        run_ids: [c.id],
        max_workers: 1,
        lease_ms: 1000,
        renew_interval_ms: 100,
        poll_interval_ms: 10,
        execution_timeout_ms: 500,
        recovery_options: [hook: hook]
      )

    try do
      assert_receive {^marker, executor}, 3000

      wait_until(fn ->
        match?({:ok, %{state: %{status: :failed}}}, Recovery.load(c.id))
      end)

      refute Process.alive?(executor)
      event = events(c.id) |> Enum.find(&(&1["event_name"] == "execution_timed_out"))
      assert event["attributes"]["phase"] == "observed"
      assert event["attributes"]["reason"] == "timeout"
      assert event["correlation"]["run_id"] == c.id
      assert event["correlation"]["generation"] == 1
      assert event["correlation"]["intent_id"] > 0
      assert DurableTools.stats(c.id).effects == 0
    after
      if Process.alive?(scheduler), do: AgentSystemsLab.Scheduler.stop(scheduler)
    end
  end

  test "Worker heartbeat loss emits the old generation without guessing or executing again", c do
    assert {:ok, _} = Recovery.create_run(c.id, "private input", script: [{:final, "done"}])
    parent = self()
    marker = make_ref()

    hook = fn
      :after_input ->
        send(parent, {marker, self()})
        receive do: ({^marker, :continue} -> :ok)

      _ ->
        :ok
    end

    {:ok, scheduler} =
      AgentSystemsLab.Scheduler.start_link(
        run_ids: [c.id],
        max_workers: 1,
        lease_ms: 1000,
        renew_interval_ms: 100,
        poll_interval_ms: 10,
        recovery_options: [hook: hook]
      )

    try do
      assert_receive {^marker, executor}, 3000
      assert {:ok, _} = Recovery.cancel(c.id)
      wait_until(fn -> Enum.any?(events(c.id), &(&1["event_name"] == "lease_lost")) end)
      refute Process.alive?(executor)
      event = events(c.id) |> Enum.find(&(&1["event_name"] == "lease_lost"))
      assert event["attributes"]["phase"] == "observed"
      assert event["correlation"]["run_id"] == c.id
      assert event["correlation"]["generation"] == 1
      assert event["correlation"]["intent_id"] > 0
      assert DurableTools.stats(c.id).effects == 0
      assert {:ok, %{state: %{status: :cancelled}}} = Recovery.load(c.id)
    after
      if Process.alive?(scheduler), do: AgentSystemsLab.Scheduler.stop(scheduler)
    end
  end

  defp wait_until(predicate, attempts \\ 200)
  defp wait_until(_predicate, 0), do: flunk("condition did not become true")

  defp wait_until(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_until(predicate, attempts - 1)
        )
  end

  defp waiting(id) do
    operation = %{operation_id: "once", tool: "mock_write", arguments: %{"amount" => 1}}
    assert {:ok, initial} = Storage.create_run(id, "safe effect")

    assert {:ok, saved} =
             Storage.dispatch(id, initial.state.seq, {:model_response, {:call, operation}})

    assert {:ok, claim} = IntentStore.claim(id, "worker")
    {claim, Map.fetch!(saved.state.operations, operation.operation_id)}
  end

  defp finish(id) do
    operation = %{operation_id: "once", tool: "mock_write", arguments: %{"amount" => 1}}

    assert {:ok, _} =
             Recovery.create_run(id, "private work",
               script: [{:call, operation}, {:final, "done"}],
               task_budget: [max_dispatches: 8]
             )

    assert {:ok, saved} = Recovery.resume(id)
    assert {:ok, recordings} = ModelResultStore.list(id)
    assert {:ok, task} = AgentSystemsLab.TaskBudgetStore.load(id)

    %{
      status: saved.state.status,
      seq: saved.state.seq,
      output: saved.state.output,
      effects: DurableTools.stats(id),
      recordings: length(recordings),
      dispatches: task.progress.dispatches,
      progress: Map.take(saved.recovery.progress, [:cursor, :model_attempts, :output_bytes])
    }
  end

  defp events(id) do
    assert :ok = Observability.flush(AgentSystemsLab.Observability.Buffer, 5_000)
    Enum.filter(Observability.recent(), &(&1["correlation"]["run_id"] == id))
  end

  defp configure_null do
    assert :ok =
             Observability.configure(
               exporter: {AgentSystemsLab.Observability.Exporters.Null, []},
               export_timeout_ms: 200,
               backoff_ms: 1000
             )
  end

  defp crash_hook(target) do
    fn
      ^target -> raise if(target == :before_commit, do: "before commit", else: "after commit")
      _ -> :ok
    end
  end
end
