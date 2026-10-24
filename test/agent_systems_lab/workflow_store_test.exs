defmodule AgentSystemsLab.WorkflowStoreTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AgentSystemsLab.{DurableTools, IntentStore, Recovery, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Storage.{Codec, Workflow, WorkflowEvent}
  alias AgentSystemsLab.Workflows.{Definition, Store}
  @moduletag :database

  setup do
    id =
      "workflow-store-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_workflows WHERE id LIKE $1", [id <> "%"])
      Repo.query!("DELETE FROM lab_queues WHERE name=$1", [Store.queue_name(id)])
    end)

    %{id: id}
  end

  test "creation atomically enrolls roots and persists an independently validated graph", c do
    {:ok, definition} = definition()
    assert {:ok, view} = Store.create(c.id, definition)
    assert view.nodes["a"].status == :running
    assert view.nodes["join"].status == :waiting
    assert view.nodes["join"].run_id == Definition.run_id(c.id, "join")
    assert {:error, :not_found} = Recovery.load(view.nodes["join"].run_id)
    assert {:ok, ^view} = Store.rebuild(c.id)
    assert {:error, {:already_exists, _}} = Store.create(c.id, definition)

    assert {:error, :nested_transaction_not_supported} =
             elem(Repo.transaction(fn -> Store.create(c.id, definition) end), 1)

    assert {:error, :transaction_required} =
             Recovery.create_run_in_transaction(Repo, "no-txn", "input", [])
  end

  test "workflow control options fail closed instead of crashing the transition boundary", c do
    {:ok, definition} = definition()
    {:ok, view} = Store.create(c.id, definition)
    id = view.nodes["a"].run_id

    for opts <- [
          [workflow_control: nil],
          [workflow_control: 1],
          [workflow_control: "true"],
          [workflow_control: true, claim: %{}]
        ] do
      assert {:error, :invalid_workflow_control_options} =
               Storage.dispatch(id, 1, {:cancel, :test}, opts)
    end

    assert {:ok, %{state: %{status: :running, seq: 1}}} = Recovery.load(id)
  end

  test "both COMMIT windows retain one stable child identity", c do
    {:ok, definition} = definition()
    parent = self()

    for stage <- [:before_commit, :after_commit] do
      {pid, ref} =
        spawn_monitor(fn ->
          Store.create(c.id, definition,
            hook: fn at ->
              if at == stage do
                send(parent, {:at, self()})
                receive do: (:continue -> :ok)
              end
            end
          )
        end)

      assert_receive {:at, ^pid}, 3000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 3000

      if stage == :before_commit do
        assert {:error, :not_found} = Store.load(c.id)
        assert {:error, :not_found} = Recovery.load(Definition.run_id(c.id, "a"))
      else
        assert {:ok, view} = Store.load(c.id)
        assert view.nodes["a"].run_id == Definition.run_id(c.id, "a")
        assert {:ok, _} = Recovery.load(view.nodes["a"].run_id)
      end
    end
  end

  test "concurrent dependency synchronization creates a single child and exact source receipts",
       c do
    {:ok, definition} = definition()
    {:ok, view} = Store.create(c.id, definition)
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(view.nodes["a"].run_id)
    results = for _ <- 1..4, do: Task.async(fn -> Store.sync(c.id) end)
    assert Enum.all?(results, &match?({:ok, _}, Task.await(&1, 5000)))
    assert {:ok, joined} = Store.load(c.id)
    assert joined.nodes["join"].status == :running
    assert joined.nodes["a"].completion.output == "A"
    assert {:ok, child} = Recovery.load(joined.nodes["join"].run_id)
    assert child.state.input == joined.nodes["join"].input
    assert String.contains?(child.state.input, joined.nodes["a"].run_id)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM lab_runs WHERE workflow_id=$1 AND workflow_node_id='join'",
               [c.id]
             )

    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(joined.nodes["join"].run_id)
    assert {:ok, %{status: :succeeded} = final} = Store.sync(c.id)
    assert {:ok, ^final} = Store.rebuild(c.id)
  end

  test "delayed enrollment clamps to the original absolute workflow deadline", c do
    {:ok, definition} = definition(timeout_ms: 3000)
    {:ok, view} = Store.create(c.id, definition)
    {:ok, _} = Recovery.resume(view.nodes["a"].run_id)
    Process.sleep(40)
    assert {:ok, joined} = Store.sync(c.id)
    assert {:ok, child} = RecoveryStore.load(joined.nodes["join"].run_id)
    assert child.progress.deadline_at_ms == view.deadline_at_ms
    assert {:ok, _} = Store.cancel(c.id)
  end

  test "parent cancellation fences claims and retains prepared unknowns in the manual queue", c do
    {:ok, definition} =
      Definition.new([
        %{
          id: "a",
          input: "effect",
          options: %{
            mock_mode: :unqueryable,
            script: [
              {:call, %{operation_id: "effect-1", tool: "mock_write", arguments: %{value: "x"}}},
              {:final, "done"}
            ]
          }
        }
      ])

    {:ok, view} = Store.create(c.id, definition)
    id = view.nodes["a"].run_id
    assert {:ok, %{state: %{status: :waiting_tool}}} = Recovery.step(id)
    {:ok, claim} = IntentStore.claim(id, "effect-owner")
    {:ok, current} = Recovery.load(id)
    operation = current.state.operations[current.state.pending_operation_id]
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
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

    assert_receive {:prepared, ^pid}, 3000
    assert {:ok, stopped} = Store.cancel(c.id)
    assert stopped.status == :cancelled
    assert stopped.unresolved_nodes == ["a"]
    assert {:ok, %{state: %{status: :blocked}}} = Recovery.load(id)
    assert {:ok, entry} = AgentSystemsLab.ReconciliationQueue.get(id)
    assert entry.safe_mode == :manual
    assert {:error, :stale_claim} = IntentStore.renew(claim)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000
    assert {:ok, manual} = IntentStore.claim(id, "operator")
    assert :ok = IntentStore.release(manual)
    assert {:error, :reconciliation_required} = Recovery.step(id)
  end

  test "completed receipts survive parent cancellation without becoming unknown", c do
    {:ok, definition} =
      Definition.new([
        %{
          id: "a",
          input: "effect",
          options: %{
            script: [
              {:call, %{operation_id: "effect-1", tool: "mock_write", arguments: %{value: "x"}}},
              {:final, "done"}
            ]
          }
        }
      ])

    {:ok, view} = Store.create(c.id, definition)
    id = view.nodes["a"].run_id
    {:ok, _} = Recovery.step(id)
    {:ok, claim} = IntentStore.claim(id, "effect-owner")
    {:ok, current} = Recovery.load(id)
    operation = current.state.operations[current.state.pending_operation_id]
    assert {:ok, {:ok, _} = receipt} = DurableTools.execute(claim, operation)
    assert {:ok, cancelled} = Store.cancel(c.id)
    assert cancelled.unresolved_nodes == []
    assert {:ok, child} = Recovery.load(id)
    assert child.state.status == :cancelled
    assert child.state.operations[operation.operation_id].result == elem(receipt, 1)
    assert {:ok, [record]} = DurableTools.list(id)
    assert record.status == "completed"
    assert {:error, :no_pending_intent} = IntentStore.claim(id, "late")
  end

  test "failure propagates to waiting descendants and cancels unrelated active work", c do
    {:ok, definition} =
      Definition.new([
        %{id: "a", input: "fail", options: %{script: []}},
        %{id: "b", input: "side", options: %{script: [{:final, "B"}]}},
        %{id: "join", deps: ["a"], input: "blocked", options: %{script: [{:final, "J"}]}}
      ])

    {:ok, view} = Store.create(c.id, definition)
    {:ok, %{state: %{status: :failed}}} = Recovery.resume(view.nodes["a"].run_id)
    assert {:ok, failed} = Store.sync(c.id)
    assert failed.status == :failed
    assert failed.nodes["join"].status == :skipped
    assert failed.nodes["b"].status == :cancelled
    assert {:error, :not_found} = Recovery.load(failed.nodes["join"].run_id)
  end

  test "schema, projection and intermediate history corruption fail closed", c do
    {:ok, definition} = definition()
    {:ok, view} = Store.create(c.id, definition)
    original = Repo.get!(Workflow, c.id)

    for {column, value} <- [
          {"schema_version", 99},
          {"definition_sha256", "wrong"},
          {"deadline_at_ms", original.deadline_at_ms + 1000},
          {"progress_data", elem(Codec.encode(%{}), 1)}
        ] do
      Repo.query!("UPDATE lab_workflows SET #{column}=$1 WHERE id=$2", [value, c.id])
      assert {:error, {:corrupt_workflow, _}} = Store.load(c.id)

      Repo.update_all(from(w in Workflow, where: w.id == ^c.id),
        set: [
          schema_version: original.schema_version,
          definition_sha256: original.definition_sha256,
          progress_data: original.progress_data,
          deadline_at_ms: original.deadline_at_ms
        ]
      )
    end

    {:ok, _} = Recovery.resume(view.nodes["a"].run_id)
    {:ok, _} = Store.sync(c.id)

    [first, second] =
      Repo.all(from(e in WorkflowEvent, where: e.workflow_id == ^c.id, order_by: e.seq))

    {:ok, data} = Codec.decode(first.data)
    changed = put_in(data, [:projection, :nodes, "join", :status], :running)

    Repo.update_all(from(e in WorkflowEvent, where: e.id == ^first.id),
      set: [data: elem(Codec.encode(changed), 1)]
    )

    {:ok, next} = Codec.decode(second.data)
    next = %{next | previous_sha256: AgentSystemsLab.Context.hash(changed.projection)}

    Repo.update_all(from(e in WorkflowEvent, where: e.id == ^second.id),
      set: [data: elem(Codec.encode(next), 1)]
    )

    assert {:error, {:corrupt_workflow, :invalid_initial_projection}} = Store.load(c.id)
  end

  test "a rewritten success projection must still match the immutable child receipt", c do
    {:ok, definition} = definition()
    {:ok, view} = Store.create(c.id, definition)
    {:ok, _} = Recovery.resume(view.nodes["a"].run_id)
    {:ok, _} = Store.sync(c.id)
    workflow = Repo.get!(Workflow, c.id)
    {:ok, progress} = Codec.decode(workflow.progress_data)
    changed = put_in(progress, [:nodes, "a", :completion, :output], "forged")

    Repo.update_all(from(w in Workflow, where: w.id == ^c.id),
      set: [progress_data: elem(Codec.encode(changed), 1)]
    )

    node = Repo.get_by!(AgentSystemsLab.Storage.WorkflowNode, workflow_id: c.id, node_id: "a")

    Repo.update_all(
      from(n in AgentSystemsLab.Storage.WorkflowNode,
        where: n.workflow_id == ^c.id and n.node_id == "a"
      ),
      set: [data: elem(Codec.encode(changed.nodes["a"]), 1)]
    )

    event = Repo.one!(from(e in WorkflowEvent, where: e.workflow_id == ^c.id and e.seq == 2))
    {:ok, event_data} = Codec.decode(event.data)

    Repo.update_all(from(e in WorkflowEvent, where: e.id == ^event.id),
      set: [data: elem(Codec.encode(%{event_data | projection: changed}), 1)]
    )

    assert node.status == "succeeded"
    assert {:error, {:corrupt_workflow, :node_projection_mismatch}} = Store.load(c.id)
  end

  test "oversized dependency evidence fails visibly without a partial downstream Run", c do
    output = String.duplicate("x", 1_048_576)

    {:ok, definition} =
      Definition.new(
        [
          %{
            id: "a",
            input: "source",
            options: %{script: [{:final, output}], max_output_bytes: 1_100_000}
          },
          %{
            id: "join",
            deps: ["a"],
            input: "retain all source evidence",
            options: %{script: [{:final, "J"}]}
          }
        ],
        budgets: %{max_output_bytes: 1_200_000}
      )

    {:ok, view} = Store.create(c.id, definition)
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(view.nodes["a"].run_id)
    assert {:ok, failed} = Store.sync(c.id)
    assert failed.status == :failed
    assert failed.nodes["join"].reason == {:dependency_join_failed, :workflow_join_too_large}
    assert {:error, :not_found} = Recovery.load(failed.nodes["join"].run_id)
    assert {:ok, ^failed} = Store.load(c.id)
    assert {:ok, audit} = AgentSystemsLab.Workflows.Audit.run(c.id, failed)
    assert audit["all_passed"]
  end

  test "stripping child membership cannot bypass the parent execution gate", c do
    {:ok, definition} = definition()
    {:ok, view} = Store.create(c.id, definition)
    id = view.nodes["a"].run_id
    Repo.query!("UPDATE lab_runs SET workflow_id=NULL, workflow_node_id=NULL WHERE id=$1", [id])
    assert {:error, :workflow_membership_mismatch} = IntentStore.claim(id, "stripped")
    assert {:error, {:corrupt_workflow, :node_projection_mismatch}} = Store.load(c.id)

    Repo.query!("UPDATE lab_runs SET workflow_id=$1, workflow_node_id='a' WHERE id=$2", [c.id, id])
  end

  defp definition(opts \\ []) do
    Definition.new(
      [
        %{id: "a", input: "first", options: %{script: [{:final, "A"}]}},
        %{id: "join", deps: ["a"], input: "join", options: %{script: [{:final, "J"}]}}
      ],
      opts
    )
  end
end
