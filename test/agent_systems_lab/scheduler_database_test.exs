defmodule AgentSystemsLab.SchedulerDatabaseTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DatabaseError,
    IntentStore,
    QueueStore,
    Recovery,
    Repo,
    Scheduler,
    TaskBudgetStore
  }

  test "connection failures do not classify business errors as database recovery" do
    assert DatabaseError.unavailable?(
             {:error, {:exception, DBConnection.ConnectionError, "closed"}}
           )

    assert DatabaseError.unavailable?({:lease_lost, {:database_timeout, :renew}})
    assert DatabaseError.unavailable?({:database_unavailable, :postgres, "admin shutdown"})
    refute DatabaseError.unavailable?({:exception, Postgrex.Error, "syntax error"})
    refute DatabaseError.unavailable?({:budget_exceeded, :model_timeout})
    refute DatabaseError.unavailable?({:provider_error, :unavailable})
    refute DatabaseError.unavailable?(:stale_claim)
    assert DatabaseError.postgres_unavailable?(%Postgrex.Error{postgres: %{pg_code: "57P01"}})
    refute DatabaseError.postgres_unavailable?(%Postgrex.Error{postgres: %{pg_code: "23505"}})
  end

  test "database deadlines and exponential backoff limits are strict" do
    for opts <- [
          [database_timeout_ms: 0],
          [database_timeout_ms: 60_001],
          [database_backoff_ms: 0],
          [database_backoff_ms: 101, max_database_backoff_ms: 100],
          [database_backoff_ms: "100"],
          [max_database_backoff_ms: 60_001]
        ] do
      assert {:error, :invalid_scheduler_options} = Scheduler.start_link(opts)
    end
  end

  @tag :database
  test "blocked claim remains observable, times out once and wake cannot bypass backoff" do
    id = id("claim")
    cleanup(id)
    assert {:ok, _} = QueueStore.create(id, capacity: 1, max_inflight: 1)

    assert {:ok, _} =
             Recovery.create_run(id, "database lock", queue: id, script: [{:final, "done"}])

    locker = lock("lab_queues", "name", id)

    scheduler =
      scheduler(
        queue: id,
        database_timeout_ms: 120,
        database_backoff_ms: 350,
        max_database_backoff_ms: 700
      )

    status =
      eventually(fn ->
        s = Scheduler.status(scheduler)
        if s.pending_claim, do: s
      end)

    helper = status.pending_claim.pid
    monitor = Process.monitor(helper)

    failed =
      eventually(fn ->
        s = Scheduler.status(scheduler)
        if s.database.state == :unavailable, do: s
      end)

    assert_receive {:DOWN, ^monitor, :process, ^helper, _}, 1000
    assert failed.pending_claim == nil
    assert failed.database.consecutive_failures == 1
    assert failed.database.retry_in_ms > 100
    assert {:ok, %{progress: %{dispatches: 0}}} = TaskBudgetStore.load(id)
    for _ <- 1..1000, do: Scheduler.wake(scheduler)
    Process.sleep(60)
    after_wake = Scheduler.status(scheduler)
    assert after_wake.counters.scans == failed.counters.scans
    assert after_wake.pending_claim == nil
    assert Process.alive?(scheduler)
    release(locker)
    eventually(fn -> match?({:ok, %{state: %{status: :succeeded}}}, Recovery.load(id)) end)

    healthy =
      eventually(fn ->
        s = Scheduler.status(scheduler)
        if s.active == [] and s.database.state == :available, do: s
      end)

    assert healthy.database.consecutive_failures == 0
    assert {:ok, %{progress: %{dispatches: 1}}} = TaskBudgetStore.load(id)
  end

  @tag :database
  test "stopping a Scheduler kills and awaits its blocked claim helper" do
    id = id("stop")
    cleanup(id)
    assert {:ok, _} = QueueStore.create(id, capacity: 1, max_inflight: 1)

    assert {:ok, _} =
             Recovery.create_run(id, "stop pending claim", queue: id, script: [{:final, "done"}])

    locker = lock("lab_queues", "name", id)
    scheduler = scheduler(queue: id, database_timeout_ms: 1000)
    task = eventually(fn -> Scheduler.status(scheduler).pending_claim end)
    ref = Process.monitor(task.pid)
    started = System.monotonic_time(:millisecond)
    assert :ok = Scheduler.stop(scheduler)
    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive {:DOWN, ^ref, :process, _pid, _}, 500
    release(locker)
    assert {:ok, saved} = Recovery.load(id)
    assert saved.intent.claim_token == nil
    assert {:ok, _} = Recovery.resume(id)
  end

  @tag :database
  test "a stalled renewal cannot block executor reclamation or revive a lease" do
    id = id("renew")
    cleanup(id)
    assert {:ok, _} = Recovery.create_run(id, "renewal lock", script: [{:final, "done"}])
    owner = self()

    gate = fn
      :after_input ->
        send(owner, {:execution_gate, self()})
        receive do: (:continue -> :ok)

      _ ->
        :ok
    end

    scheduler =
      scheduler(
        run_ids: [id],
        lease_ms: 500,
        renew_interval_ms: 40,
        database_timeout_ms: 150,
        recovery_options: [hook: gate]
      )

    assert_receive {:execution_gate, executor}, 2000
    [%{worker: worker, claim: observed}] = Scheduler.status(scheduler).active
    executor_ref = Process.monitor(executor)
    worker_ref = Process.monitor(worker)
    locker = lock("lab_runs", "id", id)

    # A heartbeat can commit between the Scheduler observation and acquiring
    # this lock. Freeze the authority actually persisted at the lock barrier;
    # all subsequent renewals are blocked behind this same Run lock.
    %{rows: [[token, generation, expires_at]]} =
      Repo.query!(
        "SELECT claim_token::text, claim_generation, claim_expires_at FROM lab_intents WHERE run_id=$1 AND status='pending'",
        [id]
      )

    assert token == observed.token
    assert generation == observed.generation
    old = %{observed | expires_at: DateTime.from_naive!(expires_at, "Etc/UTC")}

    renewal = eventually(fn -> if Process.alive?(worker), do: :sys.get_state(worker).renewal end)
    renewal_ref = Process.monitor(renewal.pid)
    assert_receive {:DOWN, ^executor_ref, :process, ^executor, :killed}, 1000
    assert_receive {:DOWN, ^renewal_ref, :process, _pid, _}, 1000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1000
    failed = Scheduler.status(scheduler)
    assert Enum.any?(failed.errors, &String.contains?(&1.reason, "database_timeout"))
    assert failed.active == []
    release(locker)
    assert {:ok, saved} = Recovery.load(id)
    assert saved.intent.claim_token == old.token
    assert saved.intent.claim_generation == old.generation
    assert saved.intent.claim_expires_at == old.expires_at
    # A successor is permitted only after the original DB lease naturally expires.
    assert_receive {:execution_gate, successor}, 3000
    send(successor, :continue)
    eventually(fn -> match?({:ok, %{state: %{status: :succeeded}}}, Recovery.load(id)) end)
    assert {:error, _} = IntentStore.renew(old)
  end

  @tag :database
  test "database failure inside a provider frame is not a business retry or completion" do
    id = id("frame")
    cleanup(id)

    assert {:ok, _} =
             Recovery.create_run(id, "frame accounting failure",
               script: [{:final, "charged but unaccepted"}],
               retry_policy: []
             )

    hook = fn
      :after_frame -> raise DBConnection.ConnectionError, "injected accounting connection loss"
      _ -> :ok
    end

    assert {:error, {:database_unavailable, :connection, _}} = Recovery.step(id, hook: hook)
    assert {:ok, saved} = Recovery.load(id)
    assert saved.state.status == :running
    assert saved.recovery.progress.model_attempts == 1
    assert saved.recovery.progress.output_bytes > 0
    assert saved.recovery.progress.cursor == 0
    assert saved.recovery.retry.status == :inflight
    assert saved.recovery.retry.attempts == 1
    assert saved.recovery.retry.next_attempt_at_ms == nil
    assert {:ok, []} = AgentSystemsLab.ModelResultStore.list(id)
    assert length(saved.events) == 1
  end

  @tag :database
  test "database failure after a tool effect preserves pending evidence without a business retry" do
    id = id("effect")
    cleanup(id)

    assert {:ok, _} =
             Recovery.create_run(id, "receipt connection loss",
               retry_policy: [],
               script: [
                 {:call, %{operation_id: "once", tool: "mock_write", arguments: %{}}},
                 {:final, "done"}
               ]
             )

    assert {:ok, %{state: %{status: :waiting_tool}}} = Recovery.step(id)

    hook = fn
      :after_effect -> raise DBConnection.ConnectionError, "injected receipt connection loss"
      _ -> :ok
    end

    assert {:error, {:database_unavailable, :connection, _}} = Recovery.step(id, tool_hook: hook)
    assert {:ok, saved} = Recovery.load(id)
    assert saved.state.status == :waiting_tool
    assert saved.recovery.retry.status == :inflight
    assert saved.recovery.retry.next_attempt_at_ms == nil
    assert %{effects: 1, operations: 1} = AgentSystemsLab.DurableTools.stats(id)
    assert {:ok, [%{status: "prepared"}]} = AgentSystemsLab.DurableTools.list(id)
    refute Enum.any?(saved.events, &(&1.type == :tool_result_recorded))
  end

  defp id(suffix),
    do:
      "scheduler-db-#{suffix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

  defp cleanup(id) do
    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])
      Repo.query!("DELETE FROM lab_queues WHERE name=$1", [id])
    end)
  end

  defp scheduler(opts) do
    assert {:ok, pid} =
             Scheduler.start_link(
               Keyword.merge(
                 [workers: 1, poll_interval_ms: 10, lease_ms: 1000, renew_interval_ms: 200],
                 opts
               )
             )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Scheduler.stop(pid) end)
    pid
  end

  defp lock(table, field, value) do
    owner = self()
    token = make_ref()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM #{table} WHERE #{field}=$1 FOR UPDATE", [value])
          send(owner, {token, :locked})
          receive do: ({^token, :release} -> :ok)
        end)
      end)

    assert_receive {^token, :locked}, 1000
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    {task, token}
  end

  defp release({task, token}) do
    send(task.pid, {token, :release})
    Task.await(task, 2000)
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 4000)

  defp eventually(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) < deadline,
          do:
            (
              Process.sleep(5)
              eventually(fun, deadline)
            ),
          else: flunk("database controller did not settle")
    end
  end
end
