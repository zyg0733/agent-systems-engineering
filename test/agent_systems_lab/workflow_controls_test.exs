defmodule AgentSystemsLab.WorkflowControlsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AgentSystemsLab.{DurableTools, IntentStore, Recovery, RecoveryStore, Repo, Workflows}
  alias AgentSystemsLab.Storage.{WorkflowControl, WorkflowControlEvent}
  alias AgentSystemsLab.Workflows.{ControlStore, Definition, Store}
  @moduletag :database

  setup do
    id =
      "workflow-controls-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_workflows WHERE id LIKE $1", [id <> "%"])
      Repo.query!("DELETE FROM lab_queues WHERE name=$1", [Store.queue_name(id)])
    end)

    %{id: id}
  end

  test "legacy Workflow view remains identical without optional controls", c do
    {:ok, before} = Workflows.create(c.id, definition())
    refute Map.has_key?(before, :control)
    assert {:ok, ^before} = Workflows.resume(c.id)
    assert {:ok, ^before} = Workflows.rebuild(c.id)
    assert {:ok, nil} = ControlStore.load(c.id)
  end

  test "pause fences a live claim even across immediate resume without refunding state", c do
    {:ok, graph} = Workflows.create(c.id, definition())
    run = graph.nodes["root"].run_id
    {:ok, claim} = IntentStore.claim(run, "old-owner")
    {:ok, before} = Recovery.load(run)
    {:ok, progress} = RecoveryStore.load(run)
    assert {:ok, paused} = Workflows.pause(c.id, :user_requested)
    assert paused.control.status == :paused
    assert [%{generation: generation, run_id: ^run}] = paused.control.revoked_claims
    assert generation == claim.generation
    assert {:error, {:workflow_paused, 1}} = IntentStore.claim(run, "new-owner")
    assert {:error, {:workflow_paused, 1}} = IntentStore.renew(claim)
    assert {:ok, current} = Recovery.load(run)
    assert current.state == before.state
    assert current.events == before.events
    assert {:ok, after_pause} = RecoveryStore.load(run)
    assert Map.delete(after_pause, :snapshot) == Map.delete(progress, :snapshot)
    assert current.intent.claim_token == nil
    assert {:ok, resumed} = Workflows.resume(c.id)
    assert resumed.control.status == :running
    assert resumed.control.seq == 2
    assert resumed.deadline_at_ms == graph.deadline_at_ms
    assert {:error, :stale_claim} = IntentStore.renew(claim)
    assert {:ok, next} = IntentStore.claim(run, "new-owner")
    assert next.generation == claim.generation + 1
    assert :ok = IntentStore.release(next)
    assert {:ok, ^resumed} = Workflows.rebuild(c.id)
    assert {:ok, control} = ControlStore.rebuild(c.id)
    assert control == resumed.control
  end

  test "pause observes completed parents but defers descendant admission until resume", c do
    {:ok, graph} = Workflows.create(c.id, definition())
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(graph.nodes["root"].run_id)
    assert {:ok, _} = Workflows.pause(c.id)
    assert {:ok, observed} = Workflows.sync(c.id)
    assert observed.nodes["root"].status == :succeeded
    assert observed.nodes["join"].status == :waiting
    assert {:error, :not_found} = Recovery.load(observed.nodes["join"].run_id)
    assert {:ok, _} = Workflows.resume(c.id)
    assert {:ok, resumed} = Workflows.sync(c.id)
    assert resumed.nodes["join"].status == :running
    assert resumed.nodes["join"].run_id == graph.nodes["join"].run_id
  end

  test "both pause COMMIT crash windows preserve a replayable gate", c do
    Workflows.create(c.id, definition())
    parent = self()

    for stage <- [:before_commit, :after_commit] do
      {pid, ref} =
        spawn_monitor(fn ->
          Workflows.pause(c.id, :user_requested,
            hook: fn at ->
              if at == stage do
                send(parent, {:at, self()})
                receive do: (:continue -> :ok)
              end
            end
          )
        end)

      assert_receive {:at, ^pid}, 3_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 3_000
      assert {:ok, view} = Workflows.rebuild(c.id)

      if stage == :before_commit,
        do: refute(Map.has_key?(view, :control)),
        else: assert(view.control.status == :paused)
    end
  end

  test "approval-owned gates enroll atomically and reject public bypass", c do
    assert {:error, :transaction_required} =
             Store.create_in_transaction(Repo, c.id, definition(), owner_case_id: "case-owner")

    assert {:ok, {:ok, graph}} =
             Repo.transaction(fn ->
               Store.create_in_transaction(Repo, c.id, definition(),
                 owner_case_id: "case-owner",
                 deadline_at_ms: RecoveryStore.now_ms(Repo) + 3_000
               )
             end)

    assert graph.control.owner_case_id == "case-owner"
    assert {:error, :approval_case_managed} = Workflows.pause(c.id)
    assert {:error, :approval_case_managed} = Workflows.resume(c.id)

    assert {:ok, {:error, :workflow_control_owner_mismatch}} =
             Repo.transaction(fn ->
               ControlStore.set_owned_in_transaction(
                 Repo,
                 c.id,
                 "other",
                 :paused,
                 :user_requested
               )
             end)

    assert {:ok, {:ok, control}} =
             Repo.transaction(fn ->
               ControlStore.set_owned_in_transaction(
                 Repo,
                 c.id,
                 "case-owner",
                 :paused,
                 :user_requested
               )
             end)

    assert control.status == :paused
    assert {:ok, loaded} = Workflows.load(c.id)
    assert loaded.control == control

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn ->
               ControlStore.set_owned_in_transaction(Repo, c.id, "case-owner", :running, :resumed)
             end)
  end

  test "pause does not extend the absolute deadline or reopen a failed graph", c do
    {:ok, graph} = Workflows.create(c.id, definition(timeout_ms: 70))
    Workflows.pause(c.id)
    Process.sleep(90)
    assert {:ok, failed} = Workflows.sync(c.id)
    assert failed.status == :failed
    assert failed.deadline_at_ms == graph.deadline_at_ms
    assert failed.reason == {:budget_exceeded, :workflow_timeout}
    assert {:error, :workflow_closed} = Workflows.resume(c.id)
  end

  test "missing or stripped ownership controls never turn an owned Workflow into legacy", c do
    assert {:ok, {:ok, graph}} =
             Repo.transaction(fn ->
               Store.create_in_transaction(Repo, c.id, definition(), owner_case_id: "case-owner")
             end)

    original = Repo.get!(WorkflowControl, c.id)
    Repo.delete!(original)
    assert {:error, :workflow_control_ownership_mismatch} = Workflows.load(c.id)

    assert {:error, :workflow_control_ownership_mismatch} =
             IntentStore.claim(graph.nodes["root"].run_id, "bypass")

    Repo.insert!(Ecto.put_meta(original, state: :built))

    Repo.update_all(from(r in WorkflowControl, where: r.workflow_id == ^c.id),
      set: [owner_case_id: nil]
    )

    assert {:error, :workflow_control_ownership_mismatch} = Workflows.load(c.id)
  end

  test "unknown control schemas and middle event corruption fail closed", c do
    Workflows.create(c.id, definition())
    Workflows.pause(c.id)
    Workflows.resume(c.id)

    Repo.update_all(from(r in WorkflowControl, where: r.workflow_id == ^c.id),
      set: [schema_version: 99]
    )

    assert {:error, {:corrupt_workflow_control, :unsupported_control_schema_version}} =
             Workflows.load(c.id)

    Repo.update_all(from(r in WorkflowControl, where: r.workflow_id == ^c.id),
      set: [schema_version: 1]
    )

    Repo.update_all(from(e in WorkflowControlEvent, where: e.workflow_id == ^c.id and e.seq == 1),
      set: [type: "running"]
    )

    assert {:error, {:corrupt_workflow_control, :invalid_control_event_type}} =
             Workflows.rebuild(c.id)
  end

  test "a prepared old tool cannot cross the effect fence after pause", c do
    {:ok, defn} =
      Definition.new([
        %{
          id: "root",
          input: "write",
          options: %{
            mock_mode: :unqueryable,
            script: [
              {:call, %{operation_id: "write", tool: "mock_write", arguments: %{value: "one"}}},
              {:final, "done"}
            ]
          }
        }
      ])

    {:ok, graph} = Workflows.create(c.id, defn)
    run = graph.nodes["root"].run_id
    Recovery.step(run)
    {:ok, snapshot} = Recovery.load(run)
    {:ok, claim} = IntentStore.claim(run, "old-tool")
    operation = snapshot.state.operations[snapshot.state.pending_operation_id]
    parent = self()

    task =
      Task.async(fn ->
        DurableTools.execute(claim, operation,
          mock_mode: :unqueryable,
          hook: fn
            :after_prepare ->
              send(parent, {:prepared, self()})
              receive do: (:continue -> :ok)

            _ ->
              :ok
          end
        )
      end)

    assert_receive {:prepared, executor}, 3_000
    assert {:ok, _} = Workflows.pause(c.id)
    send(executor, :continue)
    assert {:error, {:workflow_paused, 1}} = Task.await(task)
    assert %{effects: 0} = DurableTools.stats(run)
    assert {:ok, _} = Workflows.resume(c.id)
    assert {:ok, %{state: %{status: :blocked}}} = Recovery.resume(run)
    assert {:ok, entry} = AgentSystemsLab.ReconciliationQueue.get(run)
    assert entry.safe_mode == :manual
    assert %{effects: 0} = DurableTools.stats(run)
  end

  test "a late effect remains unknown until manual reconciliation and cannot resume delivery",
       c do
    {:ok, defn} =
      Definition.new([
        %{
          id: "root",
          input: "write",
          options: %{
            mock_mode: :unqueryable,
            script: [
              {:call, %{operation_id: "write", tool: "mock_write", arguments: %{value: "one"}}},
              {:final, "done"}
            ]
          }
        }
      ])

    {:ok, graph} = Workflows.create(c.id, defn)
    run = graph.nodes["root"].run_id
    Recovery.step(run)
    {:ok, snapshot} = Recovery.load(run)
    {:ok, claim} = IntentStore.claim(run, "old-tool")
    operation = snapshot.state.operations[snapshot.state.pending_operation_id]
    parent = self()

    task =
      Task.async(fn ->
        DurableTools.execute(claim, operation,
          mock_mode: :unqueryable,
          hook: fn
            :after_effect ->
              send(parent, {:effect, self()})
              receive do: (:continue -> :ok)

            _ ->
              :ok
          end
        )
      end)

    assert_receive {:effect, executor}, 3_000
    assert %{effects: 1} = DurableTools.stats(run)
    Workflows.pause(c.id)
    Workflows.resume(c.id)
    send(executor, :continue)
    assert {:error, :stale_claim} = Task.await(task)
    assert {:ok, %{state: %{status: :blocked}}} = Recovery.resume(run)
    assert %{effects: 1} = DurableTools.stats(run)
    Workflows.pause(c.id)

    assert {:ok, %{state: %{status: :running}}} =
             Recovery.reconcile(run,
               result: {:ok, %{value: "one"}},
               evidence: "checked target contains exactly one effect"
             )

    assert {:error, {:workflow_paused, 3}} = IntentStore.claim(run, "cannot-continue")
    assert {:ok, view} = Workflows.load(c.id)
    assert view.control.status == :paused
  end

  test "Coordinator retires its live Scheduler on pause and resumes the same Run", c do
    {:ok, defn} =
      Definition.new([%{id: "root", input: "one", options: %{script: [{:final, "done"}]}}])

    {:ok, graph} = Workflows.create(c.id, defn)
    parent = self()

    {:ok, coordinator} =
      Workflows.start_link(
        workflow_id: c.id,
        poll_interval_ms: 5,
        scheduler_options: [
          lease_ms: 500,
          renew_interval_ms: 50,
          recovery_options: [
            hook: fn
              :after_input ->
                send(parent, {:input, self()})
                receive do: (:continue -> :ok)

              _ ->
                :ok
            end
          ]
        ]
      )

    on_exit(fn ->
      try do
        if Process.alive?(coordinator), do: Workflows.stop(coordinator)
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive {:input, executor}, 3_000
    scheduler = Workflows.status(coordinator).scheduler
    ref = Process.monitor(executor)
    assert {:ok, _} = Workflows.pause(c.id)
    assert_receive {:DOWN, ^ref, :process, ^executor, _}, 3_000
    assert eventually(fn -> Workflows.status(coordinator).scheduler == nil end)
    refute Process.alive?(scheduler)
    {:ok, paused} = Recovery.load(graph.nodes["root"].run_id)
    assert paused.recovery.progress.model_attempts == 1
    assert {:ok, _} = Workflows.resume(c.id)
    assert_receive {:input, new_executor}, 3_000
    send(new_executor, :continue)
    assert eventually(fn -> match?({:ok, %{status: :succeeded}}, Workflows.load(c.id)) end)
    assert {:ok, final} = Recovery.load(graph.nodes["root"].run_id)
    assert final.recovery.progress.model_attempts == 2
    assert final.state.run_id == paused.state.run_id
  end

  defp definition(opts \\ []) do
    {:ok, d} =
      Definition.new(
        [
          %{id: "root", input: "root", options: %{script: [{:final, "root result"}]}},
          %{id: "join", deps: ["root"], input: "join", options: %{script: [{:final, "joined"}]}}
        ],
        opts
      )

    d
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(fun, attempts - 1)
          )
      )
end
