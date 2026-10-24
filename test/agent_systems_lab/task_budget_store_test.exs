defmodule AgentSystemsLab.TaskBudgetStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    Recovery,
    Repo,
    Scheduler,
    Storage,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Storage.Codec
  @moduletag :database

  setup do
    id = "task-budget-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"])
      Repo.query!("DELETE FROM lab_queues WHERE name=$1", [id])
    end)

    %{id: id}
  end

  test "budget creation validates strictly and rolls back all Run facts", c do
    for opts <- [
          nil,
          %{},
          [max_dispatches: 0],
          [execution_timeout_ms: 0],
          [max_dispatches: 1, max_dispatches: 1],
          [extra: 1]
        ] do
      assert {:error, :invalid_task_budget} =
               Recovery.create_run(c.id, "invalid", task_budget: opts)

      assert {:error, :not_found} = Storage.load(c.id)

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM lab_task_budgets WHERE run_id=$1", [c.id])
    end

    assert {:ok, _} = Recovery.create_run(c.id, "legacy")
    assert {:ok, nil} = TaskBudgetStore.load(c.id)
  end

  test "deleting a queued budget after claim cannot bypass the task policy", c do
    assert {:ok, _} = AgentSystemsLab.QueueStore.create(c.id, capacity: 1, max_inflight: 1)
    assert {:ok, _} = Recovery.create_run(c.id, "must fail closed", queue: c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "before-delete")
    Repo.query!("DELETE FROM lab_task_budgets WHERE run_id=$1", [c.id])
    assert {:error, :task_budget_missing} = Recovery.execute_claim(claim)
    assert {:ok, saved} = Recovery.load(c.id)
    assert saved.recovery.progress.model_attempts == 0
    assert %{effects: 0} = DurableTools.stats(c.id)
  end

  test "claim reservations persist and cannot be charged or executed twice", c do
    assert {:ok, _} = Recovery.create_run(c.id, "reserve", task_budget: [max_dispatches: 2])
    assert {:ok, claim} = IntentStore.claim(c.id, "one")
    assert {:ok, %{progress: %{dispatches: 1}}} = TaskBudgetStore.reserve(claim)
    assert {:error, :dispatch_already_started} = TaskBudgetStore.reserve(claim)
    assert {:error, :dispatch_already_started} = Recovery.execute_claim(claim)
    assert :ok = IntentStore.release(claim)
    assert {:ok, second} = IntentStore.claim(c.id, "two")
    assert {:ok, %{progress: %{dispatches: 2}}} = TaskBudgetStore.reserve(second)
    assert :ok = IntentStore.release(second)
    assert {:ok, third} = IntentStore.claim(c.id, "three")
    assert {:error, {:budget_exceeded, :dispatches}} = TaskBudgetStore.reserve(third)
    assert :ok = IntentStore.release(third)
    assert {:ok, child, _log} = AgentSystemsLab.RecoveryDemo.fresh_resume(c.id)
    assert child["status"] == "failed"
    assert child["effects"] == 0
    assert {:ok, final} = Recovery.load(c.id)
    assert final.state.status == :failed
    assert final.state.terminal_reason == {:budget_exceeded, :dispatches}
    assert {:ok, %{progress: %{dispatches: 2}}} = TaskBudgetStore.load(c.id)
    assert final.recovery.progress.model_attempts == 0
    assert %{effects: 0} = DurableTools.stats(c.id)
  end

  test "corrupt schemas, hashes and progress fail closed without model or target effects", c do
    assert {:ok, _} = Recovery.create_run(c.id, "strict", task_budget: [])
    assert {:ok, claim} = IntentStore.claim(c.id, "strict")
    original = Repo.get!(AgentSystemsLab.Storage.TaskBudget, c.id)
    {:ok, invalid} = Codec.encode(%{schema_version: 1, dispatches: -1})

    for {column, value} <- [
          {"schema_version", 99},
          {"config_sha256", "tampered"},
          {"progress_data", invalid}
        ] do
      Repo.query!("UPDATE lab_task_budgets SET #{column}=$1 WHERE run_id=$2", [value, c.id])
      assert {:error, {:corrupt_task_budget, _}} = Recovery.execute_claim(claim)

      Repo.query!(
        "UPDATE lab_task_budgets SET schema_version=$1, config_sha256=$2, progress_data=$3 WHERE run_id=$4",
        [original.schema_version, original.config_sha256, original.progress_data, c.id]
      )
    end

    assert {:ok, %{progress: %{dispatches: 0}}} = TaskBudgetStore.load(c.id)
    assert %{effects: 0} = DurableTools.stats(c.id)
    assert :ok = IntentStore.release(claim)
  end

  test "a killed Worker keeps its reservation and the successor exhausts the same task", c do
    parent = self()

    hook = fn
      :after_claim ->
        send(parent, {:reserved, self()})
        receive do: (:continue -> :ok)

      _ ->
        :ok
    end

    assert {:ok, _} = Recovery.create_run(c.id, "restart", task_budget: [max_dispatches: 1])
    scheduler = scheduler(c.id, recovery_options: [hook: hook])
    assert_receive {:reserved, executor}, 2000
    [%{worker: worker}] = Scheduler.status(scheduler).active
    ref = Process.monitor(executor)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^executor, _}, 1000
    final = settled(c.id)
    assert final.state.terminal_reason == {:budget_exceeded, :dispatches}
    assert final.recovery.progress.model_attempts == 0
    assert {:ok, %{progress: %{dispatches: 1}}} = TaskBudgetStore.load(c.id)
  end

  test "watchdog reclaims a hook before any model or tool preparation", c do
    parent = self()

    hook = fn
      :after_claim ->
        send(parent, {:stalled, self()})
        receive do: (:continue -> :ok)

      _ ->
        :ok
    end

    assert {:ok, _} = Recovery.create_run(c.id, "stall", task_budget: [execution_timeout_ms: 100])
    scheduler(c.id, recovery_options: [hook: hook])
    assert_receive {:stalled, executor}, 2000
    ref = Process.monitor(executor)
    final = settled(c.id)
    assert_receive {:DOWN, ^ref, :process, ^executor, _}, 1000
    assert final.state.terminal_reason == {:budget_exceeded, :execution_timeout}
    assert final.recovery.progress.model_attempts == 0
    assert %{operations: 0, effects: 0} = DurableTools.stats(c.id)
  end

  test "late model acceptance and new tool effects are transactionally fenced", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "late",
               script: [{:final, "late"}],
               task_budget: [execution_timeout_ms: 30]
             )

    assert {:ok, claim} = IntentStore.claim(c.id, "manual")

    hook = fn
      :after_model -> Process.sleep(45)
      _ -> :ok
    end

    assert {:ok, final} = Recovery.execute_claim(claim, hook: hook)
    assert final.state.status == :failed
    assert final.state.terminal_reason == {:budget_exceeded, :execution_timeout}
    assert {:ok, []} = AgentSystemsLab.ModelResultStore.list(c.id)

    other = c.id <> "-tool"

    assert {:ok, _} =
             Recovery.create_run(other, "late tool",
               script: [
                 {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"amount" => 1}}}
               ],
               task_budget: [execution_timeout_ms: 30]
             )

    assert {:ok, _} = Recovery.step(other)
    assert {:ok, claim} = IntentStore.claim(other, "tool")

    hook = fn
      :before_effect -> Process.sleep(45)
      _ -> :ok
    end

    assert {:ok, final} = Recovery.execute_claim(claim, tool_hook: hook)
    assert final.state.status == :failed
    assert %{effects: 0} = DurableTools.stats(other)
  end

  test "direct continuation cannot start a provider after execution expiry", c do
    assert {:ok, _} =
             Recovery.create_run(c.id, "late start", task_budget: [execution_timeout_ms: 20])

    hook = fn
      :after_claim -> Process.sleep(40)
      _ -> :ok
    end

    assert {:ok, saved} = Recovery.step(c.id, hook: hook)
    assert saved.state.terminal_reason == {:budget_exceeded, :execution_timeout}
    assert saved.recovery.progress.model_attempts == 0

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM lab_contexts WHERE run_id=$1", [c.id])
  end

  test "wake notifications coalesce before reaching a paused Scheduler mailbox", c do
    scheduler = scheduler(c.id)
    assert :ok = :sys.suspend(scheduler)

    try do
      tasks =
        for _ <- 1..10, do: Task.async(fn -> for _ <- 1..1000, do: Scheduler.wake(scheduler) end)

      Enum.each(tasks, &Task.await(&1, 5000))
      {:messages, messages} = Process.info(scheduler, :messages)
      assert Enum.count(messages, &(&1 == {:"$gen_cast", :wake})) == 1
    after
      :sys.resume(scheduler)
    end

    assert Scheduler.status(scheduler).wake_requests == 10_000
  end

  defp scheduler(id, opts \\ []) do
    assert {:ok, pid} =
             Scheduler.start_link(
               Keyword.merge(
                 [
                   run_ids: [id],
                   workers: 1,
                   lease_ms: 120,
                   renew_interval_ms: 30,
                   poll_interval_ms: 10
                 ],
                 opts
               )
             )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Scheduler.stop(pid) end)
    pid
  end

  defp settled(id, left \\ 300)
  defp settled(_, 0), do: flunk("task did not settle")

  defp settled(id, left) do
    assert {:ok, saved} = Recovery.load(id)

    if saved.state.status in [:failed, :succeeded, :blocked],
      do: saved,
      else:
        (
          Process.sleep(10)
          settled(id, left - 1)
        )
  end
end
