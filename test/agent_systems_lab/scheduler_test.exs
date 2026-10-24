defmodule AgentSystemsLab.SchedulerTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    Repo,
    Scheduler
  }

  @moduletag :database

  setup do
    id = "scheduler-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"]) end)
    %{id: id}
  end

  test "configuration is strict and cannot override a persisted execution policy" do
    for opts <- [
          [workers: 0],
          [workers: 2, max_workers: 2],
          [lease_ms: 100, renew_interval_ms: 100],
          [poll_interval_ms: 0],
          [run_ids: [42]],
          [run_ids: []],
          [name: 42],
          [recovery_options: [script: [{:final, "replacement"}]]],
          [recovery_options: [hook: :not_a_function]],
          [workers: 1, workers: 2],
          %{workers: 2}
        ] do
      assert {:error, :invalid_scheduler_options} = Scheduler.start_link(opts)
    end
  end

  test "free capacity bounds claims and concurrent executors without a preclaimed backlog", c do
    ids = for index <- 1..4, do: c.id <> "-#{index}"

    for id <- ids,
        do: assert({:ok, _} = Recovery.create_run(id, "bounded", script: [{:final, id}]))

    owner = self()
    gate = gate(owner, :after_claim)
    scheduler = scheduler(run_ids: ids, workers: 2, recovery_options: [hook: gate])
    assert_receive {:scheduler_gate, first}, 2_000
    assert_receive {:scheduler_gate, second}, 2_000
    refute_receive {:scheduler_gate, _}, 80
    status = Scheduler.status(scheduler)
    assert status.max_workers == 2
    assert length(status.active) == 2
    assert status.counters.claimed == 2

    claims = Enum.map(status.active, & &1.claim.run_id)
    assert length(Enum.uniq(claims)) == 2

    for id <- ids -- claims do
      assert {:ok, snapshot} = Recovery.load(id)
      assert snapshot.intent.claim_token == nil
      assert snapshot.intent.claim_generation == 0
    end

    send(first, :continue)
    send(second, :continue)
    assert_receive {:scheduler_gate, third}, 2_000
    assert_receive {:scheduler_gate, fourth}, 2_000
    send(third, :continue)
    send(fourth, :continue)
    for id <- ids, do: assert(eventually(fn -> status(id) == :succeeded end))
    assert eventually(fn -> Scheduler.status(scheduler).active == [] end)
    assert Scheduler.status(scheduler).counters.claimed == 4
  end

  test "independent multi Worker schedulers deliver each operation once across duplicate wakeups",
       c do
    ids = for index <- 1..8, do: c.id <> "-#{index}"

    for id <- ids do
      assert {:ok, _} = Recovery.create_run(id, "compete", script: [call(), {:final, "done"}])
    end

    first = scheduler(run_ids: ids, workers: 3)
    second = scheduler(run_ids: ids, workers: 3)
    for _ <- 1..30, scheduler <- [first, second], do: Scheduler.wake(scheduler)
    for id <- ids, do: assert(eventually(fn -> status(id) == :succeeded end))

    for id <- ids do
      assert %{effects: 1, operations: 1, attempts: 1} = DurableTools.stats(id)
      assert {:ok, snapshot} = Recovery.load(id)
      assert snapshot.recovery.progress.cursor == 2
      assert snapshot.recovery.progress.model_attempts == 2
      assert {:ok, records} = ModelResultStore.list(id)
      assert length(records) == 2
    end

    assert eventually(fn ->
             Scheduler.status(first).active == [] and Scheduler.status(second).active == []
           end)

    assert Scheduler.status(first).counters.claimed + Scheduler.status(second).counters.claimed ==
             24
  end

  test "a gated model outlives its original lease through repeated independent renewals", c do
    assert {:ok, _} = Recovery.create_run(c.id, "slow model", script: [{:final, "done"}])

    first =
      scheduler(
        run_ids: [c.id],
        workers: 1,
        lease_ms: 400,
        renew_interval_ms: 60,
        recovery_options: [hook: gate(self(), :after_frame)]
      )

    assert_receive {:scheduler_gate, provider}, 2_000
    assert eventually(fn -> Scheduler.status(first).counters.renewed >= 3 end)
    [delivery] = Scheduler.status(first).active
    original_generation = delivery.claim.generation
    Process.sleep(430)
    assert {:error, :intent_claimed} = IntentStore.claim(c.id, "competitor")
    second = scheduler(run_ids: [c.id], workers: 2)
    Process.sleep(50)
    assert Scheduler.status(second).active == []
    assert Scheduler.status(second).counters.claimed == 0
    [renewed] = Scheduler.status(first).active
    assert renewed.renewals >= 5
    assert renewed.claim.generation == original_generation
    send(provider, :continue)
    assert eventually(fn -> status(c.id) == :succeeded end)
    assert {:ok, snapshot} = Recovery.load(c.id)
    assert snapshot.recovery.progress.model_attempts == 1
  end

  test "cancellation revokes the lease and stops both executor and gated provider", c do
    assert {:ok, _} = Recovery.create_run(c.id, "cancel", script: [{:final, "late"}])

    scheduler =
      scheduler(
        run_ids: [c.id],
        renew_interval_ms: 40,
        recovery_options: [hook: gate(self(), :after_frame)]
      )

    assert_receive {:scheduler_gate, provider}, 2_000

    assert eventually(fn ->
             match?([%{executor: pid}] when is_pid(pid), Scheduler.status(scheduler).active)
           end)

    [%{executor: executor}] = Scheduler.status(scheduler).active
    provider_ref = Process.monitor(provider)
    executor_ref = Process.monitor(executor)
    assert {:ok, cancelled} = Recovery.cancel(c.id)
    assert cancelled.state.status == :cancelled
    assert_receive {:DOWN, ^executor_ref, :process, ^executor, _}, 2_000
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, _}, 2_000
    assert eventually(fn -> Scheduler.status(scheduler).active == [] end)
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert status(c.id) == :cancelled
  end

  test "graceful stop awaits the executor and releases its lease for immediate continuation", c do
    assert {:ok, _} = Recovery.create_run(c.id, "stop", script: [{:final, "done"}])

    scheduler =
      scheduler(
        run_ids: [c.id],
        lease_ms: 10_000,
        recovery_options: [hook: gate(self(), :after_input)]
      )

    assert_receive {:scheduler_gate, executor}, 2_000
    executor_ref = Process.monitor(executor)
    assert :ok = Scheduler.stop(scheduler)
    assert_receive {:DOWN, ^executor_ref, :process, ^executor, _}, 500
    assert {:ok, paused} = Recovery.load(c.id)
    assert paused.intent.claim_token == nil
    successor = scheduler(run_ids: [c.id])
    assert eventually(fn -> status(c.id) == :succeeded end)
    assert eventually(fn -> Scheduler.status(successor).active == [] end)
  end

  test "Worker death after a target effect causes lease expiry and safe duplicate delivery", c do
    assert {:ok, _} = Recovery.create_run(c.id, "effect", script: [call(), {:final, "done"}])
    assert {:ok, _} = Recovery.step(c.id)

    scheduler =
      scheduler(
        run_ids: [c.id],
        workers: 1,
        lease_ms: 250,
        renew_interval_ms: 40,
        recovery_options: [tool_hook: gate(self(), :after_effect)]
      )

    assert_receive {:scheduler_gate, executor}, 2_000
    [%{worker: worker, claim: old_claim}] = Scheduler.status(scheduler).active
    executor_ref = Process.monitor(executor)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^executor_ref, :process, ^executor, _}, 1_000
    assert Process.alive?(scheduler)
    assert %{effects: 1} = DurableTools.stats(c.id)
    assert_receive {:scheduler_gate, replacement}, 3_000
    [%{claim: new_claim}] = Scheduler.status(scheduler).active
    assert new_claim.generation > old_claim.generation
    assert {:error, :stale_claim} = IntentStore.renew(old_claim)
    send(replacement, :continue)
    assert eventually(fn -> status(c.id) == :succeeded end)
    assert %{effects: 1, attempts: 2} = DurableTools.stats(c.id)
    assert {:ok, snapshot} = Recovery.load(c.id)
    assert snapshot.recovery.progress.model_attempts == 2
  end

  test "scheduler death kills linked deliveries and a fresh instance resumes after real expiry",
       c do
    assert {:ok, _} = Recovery.create_run(c.id, "scheduler crash", script: [{:final, "done"}])

    first =
      scheduler(
        run_ids: [c.id],
        lease_ms: 250,
        renew_interval_ms: 40,
        recovery_options: [hook: gate(self(), :after_frame)]
      )

    assert_receive {:scheduler_gate, provider}, 2_000

    assert eventually(fn ->
             match?([%{executor: pid}] when is_pid(pid), Scheduler.status(first).active)
           end)

    [%{worker: worker, executor: executor, claim: claim}] = Scheduler.status(first).active
    refs = for pid <- [worker, executor, provider], do: {Process.monitor(pid), pid}
    Process.exit(first, :kill)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)
    assert {:ok, saved} = Recovery.load(c.id)
    assert saved.intent.claim_token == claim.token
    scheduler(run_ids: [c.id])
    assert eventually(fn -> status(c.id) == :succeeded end)
    assert {:ok, done} = Recovery.load(c.id)
    assert done.recovery.progress.model_attempts == 2
    assert done.recovery.progress.cursor == 1
    assert {:ok, [_]} = ModelResultStore.list(c.id)
  end

  test "future retry consumes no claims or Worker slots and is delivered automatically when due",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "retry",
               script: [{:final, "fallback"}],
               retry_policy: policy(),
               model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "second attempt"}]}
             )

    assert {:ok, waiting} = Recovery.step(c.id)
    assert waiting.recovery.retry.status == :waiting
    generation = waiting.intent.claim_generation
    scheduler = scheduler(run_ids: [c.id], workers: 2, poll_interval_ms: 10)
    Process.sleep(80)
    assert {:ok, before_due} = Recovery.load(c.id)
    assert before_due.recovery.progress.model_attempts == 1
    assert before_due.intent.claim_generation == generation
    assert Scheduler.status(scheduler).active == []
    assert Scheduler.status(scheduler).counters.claimed == 0
    assert eventually(fn -> status(c.id) == :succeeded end)
    assert {:ok, done} = Recovery.load(c.id)
    assert done.state.output == "second attempt"
    assert done.recovery.progress.model_attempts == 2
    assert Scheduler.status(scheduler).counters.claimed == 1
  end

  test "an ambiguous non-idempotent effect stays visible in the queue without automatic redelivery",
       c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "unknown",
               script: [call(), {:final, "done"}],
               mock_mode: :unqueryable
             )

    assert {:ok, _} = Recovery.step(c.id)

    scheduler =
      scheduler(
        run_ids: [c.id],
        lease_ms: 250,
        renew_interval_ms: 40,
        recovery_options: [tool_hook: gate(self(), :after_effect)]
      )

    assert_receive {:scheduler_gate, _executor}, 2_000
    [%{worker: worker}] = Scheduler.status(scheduler).active
    Process.exit(worker, :kill)
    assert eventually(fn -> status(c.id) == :blocked end)
    assert {:ok, [entry]} = ReconciliationQueue.list(run_id: c.id)
    assert entry.safe_mode == :manual
    assert %{effects: 1, attempts: 2} = DurableTools.stats(c.id)
    assert {:ok, blocked} = Recovery.load(c.id)
    generation = blocked.intent.claim_generation
    Scheduler.wake(scheduler)
    Process.sleep(100)
    assert Scheduler.status(scheduler).active == []
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.intent.claim_generation == generation
    assert unchanged.state === blocked.state
    assert %{effects: 1, attempts: 2} = DurableTools.stats(c.id)
  end

  test "unexpected executor exceptions remain bounded diagnostics and do not hot loop", c do
    assert {:ok, _} = Recovery.create_run(c.id, "fail safely", script: [{:final, "done"}])
    failing = fn :after_claim -> raise "injected scheduler failure" end

    scheduler =
      scheduler(
        run_ids: [c.id],
        workers: 1,
        poll_interval_ms: 10,
        recovery_options: [hook: failing]
      )

    assert eventually(fn -> Scheduler.status(scheduler).counters.failed >= 21 end)
    before = Scheduler.status(scheduler)
    assert length(before.errors) == 20
    Process.sleep(80)
    after_wait = Scheduler.status(scheduler)
    assert after_wait.counters.failed - before.counters.failed <= 9
    assert Process.alive?(scheduler)
    assert length(after_wait.errors) == 20
    assert {:ok, snapshot} = Recovery.load(c.id)
    assert snapshot.recovery.progress.model_attempts == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  defp scheduler(opts) do
    opts =
      Keyword.merge(
        [workers: 2, poll_interval_ms: 10, lease_ms: 1_000, renew_interval_ms: 150],
        opts
      )

    assert {:ok, pid} = Scheduler.start_link(opts)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Scheduler.stop(pid)
    end)

    pid
  end

  defp gate(owner, stage) do
    fn current ->
      if current == stage do
        send(owner, {:scheduler_gate, self()})
        receive do: (:continue -> :ok)
      end
    end
  end

  defp status(id) do
    case Recovery.load(id) do
      {:ok, saved} -> saved.state.status
      _ -> nil
    end
  end

  defp eventually(fun, left \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, left) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end

  defp call,
    do: {:call, %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}}

  defp policy,
    do: [
      max_attempts: 3,
      base_delay_ms: 350,
      max_delay_ms: 350,
      max_elapsed_ms: 5_000,
      tool_timeout_ms: 1_000
    ]
end
