defmodule AgentSystemsLab.WorkflowsCoordinatorOptionsTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.Workflows.Coordinator

  test "a controller cannot replace the persisted queue, limits or child authority" do
    for opts <- [
          [],
          [workflow_id: ""],
          [workflow_id: "ok", workflow_id: "other"],
          [workflow_id: "ok", name: 42],
          [workflow_id: "ok", poll_interval_ms: 0],
          [workflow_id: "ok", max_workers: 9],
          [workflow_id: String.duplicate("x", 129)],
          [workflow_id: "ok", scheduler_options: [queue: "replacement"]],
          [workflow_id: "ok", scheduler_options: [max_workers: 9]],
          [workflow_id: "ok", scheduler_options: [run_ids: ["replacement"]]],
          [workflow_id: "ok", scheduler_options: [recovery_options: [script: []]]],
          [workflow_id: "ok", scheduler_options: [lease_ms: 100, renew_interval_ms: 100]],
          [workflow_id: "ok", scheduler_options: [lease_ms: :invalid]],
          [workflow_id: "ok", scheduler_options: [recovery_options: [hook: :bad]]],
          [workflow_id: "ok", database_timeout_ms: 0],
          %{workflow_id: "ok"}
        ] do
      assert {:error, :invalid_coordinator_options} = Coordinator.start_link(opts)
    end
  end
end

defmodule AgentSystemsLab.WorkflowsCoordinatorTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    ModelResultStore,
    QueueStore,
    ReconciliationQueue,
    Recovery,
    Repo,
    Scheduler,
    TaskBudgetStore,
    Workflows
  }

  alias AgentSystemsLab.Workflows.{Coordinator, Definition}

  @moduletag :database

  setup do
    id = "coordinator-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    %{id: id}
  end

  test "a real diamond runs both branches together and joins complete paired receipts", c do
    definition = diamond(2)
    create(c.id, definition)
    controller = coordinator(c.id, recovery_options: [hook: gate(self(), :after_input)])
    root = next_gate()
    assert entry(controller, root).claim.run_id == Definition.run_id(c.id, "root")
    send(root, :continue)
    first = next_gate()
    second = next_gate()
    assert eventually(fn -> length(active(controller)) == 2 end)
    ids = Enum.map([first, second], &entry(controller, &1).claim.run_id)
    assert Enum.sort(ids) == Enum.sort(Enum.map(["a", "b"], &Definition.run_id(c.id, &1)))
    assert {:ok, waiting} = Workflows.load(c.id)
    assert waiting.nodes["join"].status == :waiting
    assert {:error, :not_found} = Recovery.load(waiting.nodes["join"].run_id)
    send(first, :continue)
    first_final = next_gate()
    send(first_final, :continue)
    assert eventually(fn -> run_status(hd(ids)) == :succeeded end)
    assert {:ok, still_waiting} = Workflows.sync(c.id)
    assert still_waiting.nodes["join"].status == :waiting
    send(second, :continue)
    second_final = next_gate()
    send(second_final, :continue)
    join = next_gate()
    assert entry(controller, join).claim.run_id == Definition.run_id(c.id, "join")
    assert {:ok, join_run} = Recovery.load(Definition.run_id(c.id, "join"))
    bundle = JSON.decode!(join_run.state.input)
    assert bundle["task_input"] == "join task"
    assert Enum.map(bundle["dependencies"], & &1["node_id"]) == ["a", "b"]

    for source <- bundle["dependencies"] do
      assert source["result_sha256"] != nil
      assert source["operations"]["$map"] != []
    end

    send(join, :continue)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert {:ok, done} = Workflows.load(c.id)
    assert done.nodes["a"].completion.operations["write-a"].status == :ok
    assert done.nodes["b"].completion.operations["write-b"].status == :ok
    assert done.nodes["a"].completion.run_id == Definition.run_id(c.id, "a")
    assert eventually(fn -> Workflows.status(controller).scheduler == nil end)
  end

  test "competing controllers and duplicate wakeups share one queue and one child per node", c do
    create(c.id, diamond(2))
    first = coordinator(c.id)
    second = coordinator(c.id)
    for _ <- 1..100, pid <- [first, second], do: Workflows.wake(pid)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert {:ok, done} = Workflows.load(c.id)
    assert map_size(done.nodes) == 4
    assert done.nodes |> Map.values() |> Enum.map(& &1.run_id) |> Enum.uniq() |> length() == 4

    for node <- ["a", "b"] do
      assert %{effects: 1, operations: 1, attempts: 1} =
               DurableTools.stats(Definition.run_id(c.id, node))
    end

    assert {:ok, stats} = QueueStore.stats(done.queue)
    assert stats.max_inflight == 2
    assert stats.live_leases == 0
    assert stats.active == 0
  end

  test "graceful stop waits for its process subtree and a new controller keeps the same Run", c do
    create(c.id, one_node())
    first = coordinator(c.id, recovery_options: [hook: gate(self(), :after_input)])
    executor = next_gate()
    scheduler = Workflows.status(first).scheduler
    worker = entry(first, executor).worker
    refs = for pid <- [scheduler, worker, executor], do: {Process.monitor(pid), pid}
    assert {:ok, before_stop} = Recovery.load(Definition.run_id(c.id, "root"))
    assert :ok = Workflows.stop(first)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)
    assert {:ok, paused} = Recovery.load(Definition.run_id(c.id, "root"))
    assert paused.state.run_id == before_stop.state.run_id
    assert paused.intent.claim_token == nil
    assert paused.recovery.progress.model_attempts == before_stop.recovery.progress.model_attempts
    coordinator(c.id)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert {:ok, complete} = Recovery.load(Definition.run_id(c.id, "root"))
    assert complete.recovery.progress.model_attempts == 2
    assert {:ok, [_]} = ModelResultStore.list(complete.state.run_id)
  end

  test "a killed controller retires its OTP subtree and resumes the original Run and receipt",
       c do
    definition =
      define(
        [
          node("root", [], [call("root"), {:final, "done"}]),
          node("join", ["root"], [{:final, "joined"}])
        ],
        2
      )

    create(c.id, definition)
    # This case verifies retirement with a known live claim. An in-flight
    # heartbeat has an uncertain ACK and must retain its claim until expiry.
    first =
      coordinator(c.id,
        lease_ms: 30_000,
        renew_interval_ms: 15_000,
        recovery_options: [tool_hook: gate(self(), :after_effect)]
      )

    executor = next_gate()
    scheduler = Workflows.status(first).scheduler
    worker = entry(first, executor).worker
    claim = entry(first, executor).claim
    assert entry(first, executor).renewals == 0
    refs = for pid <- [scheduler, worker, executor], do: {Process.monitor(pid), pid}
    run_id = Definition.run_id(c.id, "root")
    assert %{effects: 1} = DurableTools.stats(run_id)
    Process.exit(first, :kill)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)
    assert {:ok, abandoned} = Recovery.load(run_id)
    assert abandoned.intent.claim_token == nil
    assert abandoned.intent.claim_generation == claim.generation
    coordinator(c.id)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert %{effects: 1, attempts: 2} = DurableTools.stats(run_id)
    assert {:ok, complete} = Recovery.load(run_id)
    assert complete.recovery.progress.cursor == 2
    assert complete.recovery.progress.model_attempts == 2
    assert {:ok, done} = Workflows.load(c.id)
    assert done.nodes["root"].run_id == run_id
    assert {:ok, rebuilt} = Workflows.rebuild(c.id)
    assert rebuilt.nodes == done.nodes
  end

  test "a killed Worker leaves a real expiring lease and the graph fences and recovers its delivery",
       c do
    create(
      c.id,
      define(
        [
          node("root", [], [call("root"), {:final, "done"}]),
          node("join", ["root"], [{:final, "joined"}])
        ],
        2
      )
    )

    controller = coordinator(c.id, recovery_options: [tool_hook: gate(self(), :after_effect)])
    executor = next_gate()
    %{worker: worker, claim: old_claim} = entry(controller, executor)
    Process.exit(worker, :kill)
    assert eventually(fn -> not Process.alive?(executor) end)
    run_id = Definition.run_id(c.id, "root")
    assert {:ok, abandoned} = Recovery.load(run_id)
    assert abandoned.intent.claim_token == old_claim.token
    assert {:ok, waiting} = Workflows.load(c.id)
    assert waiting.nodes["join"].status == :waiting
    replacement = next_gate()
    assert entry(controller, replacement).claim.generation > old_claim.generation
    assert {:error, :stale_claim} = AgentSystemsLab.IntentStore.renew(old_claim)
    send(replacement, :continue)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert %{effects: 1, attempts: 2} = DurableTools.stats(run_id)
  end

  test "an ambiguous non-idempotent child stays visible and cannot unlock its dependent", c do
    definition =
      define(
        [
          node("root", [], [call("root"), {:final, "late"}], mock_mode: :unqueryable),
          node("join", ["root"], [{:final, "must not execute"}])
        ],
        2
      )

    create(c.id, definition)
    first = coordinator(c.id, recovery_options: [tool_hook: gate(self(), :after_effect)])
    executor = next_gate()
    Process.exit(first, :kill)
    assert eventually(fn -> not Process.alive?(executor) end)
    next = coordinator(c.id)
    assert eventually(fn -> workflow_status(c.id) == :blocked end)
    assert {:ok, blocked} = Workflows.load(c.id)
    assert blocked.unresolved_nodes == ["root"]
    assert blocked.nodes["join"].status == :waiting
    assert {:error, :not_found} = Recovery.load(blocked.nodes["join"].run_id)
    run_id = Definition.run_id(c.id, "root")
    assert {:ok, [manual]} = ReconciliationQueue.list(run_id: run_id)
    assert manual.safe_mode == :manual
    assert %{effects: 1, attempts: 2} = DurableTools.stats(run_id)
    for _ <- 1..20, do: Coordinator.wake(next)
    Process.sleep(100)
    assert %{effects: 1, attempts: 2} = DurableTools.stats(run_id)
    assert {:ok, cancelled} = Workflows.cancel(c.id)
    assert cancelled.status == :cancelled
    assert {:ok, [still_manual]} = ReconciliationQueue.list(run_id: run_id)
    assert still_manual.safe_mode == :manual

    assert eventually(fn ->
             status = Workflows.status(next)
             status.scheduler == nil and status.pending_sync == nil
           end)

    assert {:ok, before_confirmation} = ModelResultStore.list(run_id)

    assert {:ok, confirmed} =
             Recovery.reconcile(run_id,
               owner: "owned-workflow-test-operator",
               result: {:ok, %{"receipt" => "owned-fixture-effect-confirmed"}},
               evidence: "Owned test target effect inspected; original operation confirmed."
             )

    assert confirmed.state.run_id == run_id
    assert confirmed.state.status == :running
    assert confirmed.intent.kind == "model"

    assert {:error, {:workflow_closed, :cancelled}} =
             AgentSystemsLab.IntentStore.claim(run_id, "forbidden-followup")

    assert {:error, {:workflow_closed, :cancelled}} = Recovery.step(run_id)
    assert {:ok, ^before_confirmation} = ModelResultStore.list(run_id)
    assert %{effects: 1, attempts: 3} = DurableTools.stats(run_id)
    assert {:ok, archived} = Workflows.sync(c.id)
    assert archived.status == :cancelled
    assert archived.unresolved_nodes == []
    assert archived.nodes["root"].run_id == run_id
    assert archived.nodes["root"].status == :cancelled
    assert archived.nodes["join"].status == :skipped
    assert run_status(run_id) == :cancelled
    assert {:ok, ^before_confirmation} = ModelResultStore.list(run_id)
    assert {:error, :not_in_reconciliation_queue} = ReconciliationQueue.get(run_id)
  end

  test "child failure closes the graph gate, cancels an active sibling and never creates descendants",
       c do
    definition =
      define(
        [
          node("bad", [], [{:error, :unauthorized}]),
          node("slow", [], [{:final, "late"}]),
          node("join", ["bad"], [{:final, "forbidden"}])
        ],
        2
      )

    create(c.id, definition)
    controller = coordinator(c.id, recovery_options: [hook: gate(self(), :after_input)])
    first = next_gate()
    second = next_gate()

    bad =
      Enum.find(
        [first, second],
        &(entry(controller, &1).claim.run_id == Definition.run_id(c.id, "bad"))
      )

    slow = Enum.find([first, second], &(&1 != bad))
    ref = Process.monitor(slow)
    send(bad, :continue)
    assert eventually(fn -> workflow_status(c.id) == :failed end)
    assert_receive {:DOWN, ^ref, :process, ^slow, _}, 2_000
    assert run_status(Definition.run_id(c.id, "slow")) == :cancelled
    assert {:ok, failed} = Workflows.load(c.id)
    assert failed.nodes["join"].status == :skipped
    assert {:error, :not_found} = Recovery.load(Definition.run_id(c.id, "join"))
    assert {:ok, []} = ModelResultStore.list(Definition.run_id(c.id, "slow"))
  end

  test "parent cancellation revokes active work and a replacement controller cannot reopen the gate",
       c do
    create(
      c.id,
      define(
        [node("root", [], [{:final, "late"}]), node("join", ["root"], [{:final, "forbidden"}])],
        2
      )
    )

    first = coordinator(c.id, recovery_options: [hook: gate(self(), :after_input)])
    executor = next_gate()
    ref = Process.monitor(executor)
    assert {:ok, cancelled} = Workflows.cancel(c.id, :user_requested)
    assert cancelled.status == :cancelled
    assert_receive {:DOWN, ^ref, :process, ^executor, _}, 2_000
    assert eventually(fn -> Workflows.status(first).scheduler == nil end)
    coordinator(c.id)
    assert {:ok, _} = Workflows.sync(c.id)
    assert run_status(Definition.run_id(c.id, "root")) == :cancelled
    assert {:error, :not_found} = Recovery.load(Definition.run_id(c.id, "join"))
    assert {:ok, []} = ModelResultStore.list(Definition.run_id(c.id, "root"))
  end

  test "a parent deadline is durable and retires a gated child without extending on restart", c do
    create(
      c.id,
      define(
        [node("root", [], [{:final, "late"}]), node("join", ["root"], [{:final, "forbidden"}])],
        2,
        timeout_ms: 700
      )
    )

    first = coordinator(c.id, recovery_options: [hook: gate(self(), :after_input)])
    executor = next_gate()
    assert {:ok, before_timeout} = Workflows.load(c.id)
    assert eventually(fn -> workflow_status(c.id) in [:failed, :cancelled] end)
    assert eventually(fn -> not Process.alive?(executor) end)
    Workflows.stop(first)
    coordinator(c.id)
    assert {:ok, expired} = Workflows.sync(c.id)
    assert expired.deadline_at_ms == before_timeout.deadline_at_ms
    assert expired.nodes["join"].status == :skipped
    assert {:ok, []} = ModelResultStore.list(Definition.run_id(c.id, "root"))
  end

  test "parallelism changes scheduling while fixed allocations and durable spending remain equal",
       c do
    one = c.id <> "-one"
    two = c.id <> "-two"
    create(one, diamond(1))
    create(two, diamond(2))
    coordinator(one)
    coordinator(two)

    assert eventually(fn ->
             workflow_status(one) == :succeeded and workflow_status(two) == :succeeded
           end)

    assert {:ok, sequential} = Workflows.load(one)
    assert {:ok, parallel} = Workflows.load(two)

    assert Definition.allocations(sequential.definition) ==
             Definition.allocations(parallel.definition)

    assert spending(sequential) == spending(parallel)
    assert spending(parallel) == %{model_attempts: 6, dispatches: 8, effects: 2}

    for id <- [one, two] do
      {:ok, view} = Workflows.load(id)

      for node <- view.definition.nodes do
        {:ok, budget} = TaskBudgetStore.load(Definition.run_id(id, node.id))
        assert budget.config.max_dispatches == node.options.task_budget.max_dispatches
      end
    end
  end

  test "one blocked database helper times out while status and coalesced wake remain responsive",
       c do
    create(c.id, one_node())
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM lab_workflows WHERE id = $1 FOR UPDATE", [c.id])
          send(owner, {:workflow_locked, self()})
          receive do: (:continue -> :ok)
        end)
      end)

    assert_receive {:workflow_locked, blocker_pid}, 2_000
    on_exit(fn -> if Process.alive?(blocker.pid), do: Process.exit(blocker.pid, :kill) end)

    {:ok, controller} =
      Workflows.start_link(
        workflow_id: c.id,
        poll_interval_ms: 5,
        database_timeout_ms: 250,
        database_backoff_ms: 40,
        max_database_backoff_ms: 80
      )

    Process.unlink(controller)
    on_exit(fn -> if Process.alive?(controller), do: Workflows.stop(controller) end)
    assert eventually(fn -> not is_nil(Workflows.status(controller).pending_sync) end)
    first_helper = Workflows.status(controller).pending_sync.pid
    for _ <- 1..1000, do: Workflows.wake(controller)
    started = System.monotonic_time(:millisecond)
    responsive = Workflows.status(controller)
    assert System.monotonic_time(:millisecond) - started < 150
    assert responsive.pending_sync.pid == first_helper
    assert responsive.scheduler == nil
    assert responsive.message_queue_len <= 2
    assert eventually(fn -> Workflows.status(controller).database.state == :unavailable end)
    assert Workflows.status(controller).counters.failures >= 1
    assert eventually(fn -> not Process.alive?(first_helper) end)
    send(blocker_pid, :continue)
    assert {:ok, :ok} = Task.await(blocker, 2_000)
    assert eventually(fn -> workflow_status(c.id) == :succeeded end)
    assert eventually(fn -> Workflows.status(controller).database.state == :available end)
  end

  defp create(id, definition) do
    assert {:ok, _} = Workflows.create(id, definition)

    on_exit(fn ->
      queue =
        case Workflows.load(id) do
          {:ok, view} -> view.queue
          _ -> nil
        end

      Repo.query!("DELETE FROM lab_workflows WHERE id = $1", [id])
      if queue, do: Repo.query!("DELETE FROM lab_queues WHERE name = $1", [queue])
    end)
  end

  defp coordinator(id, opts \\ []) do
    {:ok, pid} =
      Workflows.start_link(
        workflow_id: id,
        poll_interval_ms: 10,
        scheduler_options:
          Keyword.merge([poll_interval_ms: 10, lease_ms: 300, renew_interval_ms: 40], opts)
      )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Workflows.stop(pid) end)
    pid
  end

  defp diamond(max_parallel),
    do:
      define(
        [
          node("root", [], [{:final, "root result"}]),
          node("a", ["root"], [call("a"), {:final, "a result"}]),
          node("b", ["root"], [call("b"), {:final, "b result"}]),
          node("join", ["a", "b"], [{:final, "joined"}])
        ],
        max_parallel
      )

  defp one_node, do: define([node("root", [], [{:final, "done"}])], 1)

  defp define(nodes, max_parallel, opts \\ []) do
    {:ok, definition} = Definition.new(nodes, Keyword.put(opts, :max_parallel, max_parallel))
    definition
  end

  defp node(id, deps, script, opts \\ []),
    do: %{id: id, deps: deps, input: "#{id} task", options: Keyword.put(opts, :script, script)}

  defp call(id),
    do: {:call, %{operation_id: "write-#{id}", tool: "mock_write", arguments: %{"value" => id}}}

  defp gate(owner, stage),
    do: fn current ->
      if current == stage do
        send(owner, {:workflow_gate, self()})
        receive do: (:continue -> :ok)
      end
    end

  defp next_gate do
    assert_receive {:workflow_gate, pid}, 3_000
    pid
  end

  defp active(controller) do
    case Workflows.status(controller).scheduler do
      nil -> []
      pid -> Scheduler.status(pid).active
    end
  end

  defp entry(controller, executor) do
    assert eventually(fn -> Enum.any?(active(controller), &(&1.executor == executor)) end)
    Enum.find(active(controller), &(&1.executor == executor))
  end

  defp workflow_status(id) do
    case Workflows.load(id) do
      {:ok, view} -> view.status
      _ -> nil
    end
  end

  defp run_status(id) do
    case Recovery.load(id) do
      {:ok, run} -> run.state.status
      _ -> nil
    end
  end

  defp spending(view) do
    Enum.reduce(view.nodes, %{model_attempts: 0, dispatches: 0, effects: 0}, fn {_id, node},
                                                                                totals ->
      {:ok, run} = Recovery.load(node.run_id)
      {:ok, budget} = TaskBudgetStore.load(node.run_id)

      %{
        totals
        | model_attempts: totals.model_attempts + run.recovery.progress.model_attempts,
          dispatches: totals.dispatches + budget.progress.dispatches,
          effects: totals.effects + DurableTools.stats(node.run_id).effects
      }
    end)
  end

  defp eventually(fun, left \\ 500)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, left),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, left - 1)
          )
      )
end
