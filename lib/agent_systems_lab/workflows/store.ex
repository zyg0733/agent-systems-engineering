defmodule AgentSystemsLab.Workflows.Store do
  @moduledoc """
  Transactional DAG control plane. Child Runs keep their original policy, lease,
  accounting and receipt journals. Reading or rebuilding a graph never executes it.
  """
  import Ecto.Query

  alias AgentSystemsLab.{
    Context,
    QueueStore,
    Recovery,
    RecoveryStore,
    Repo,
    Storage
  }

  alias AgentSystemsLab.Storage.{
    Codec,
    Operation,
    Queue,
    Run,
    Workflow,
    WorkflowEvent,
    WorkflowNode
  }

  alias AgentSystemsLab.Workflows.{ControlStore, Definition, Join}
  @closed [:failed, :cancelled]
  @statuses [:waiting, :running, :blocked, :succeeded, :failed, :cancelled, :skipped]

  def create(id, definition, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         :ok <- valid_id(id),
         :ok <- Definition.validate(definition),
         {:ok, encoded} <- Codec.encode(Definition.to_map(definition)) do
      transaction(opts, fn -> create_workflow!(id, definition, encoded, []) end)
    end
  end

  @doc false
  def create_in_transaction(repo, id, definition, opts \\ []) do
    with true <- (repo == Repo and repo.in_transaction?()) || {:error, :transaction_required},
         :ok <- valid_id(id),
         :ok <- Definition.validate(definition),
         true <-
           (is_list(opts) and Keyword.keyword?(opts) and
              Keyword.keys(opts) -- [:owner_case_id, :deadline_at_ms] == [] and
              length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))) ||
             {:error, :invalid_workflow_options},
         :ok <- valid_id(opts[:owner_case_id]),
         deadline = Keyword.get(opts, :deadline_at_ms),
         true <-
           (is_nil(deadline) or (is_integer(deadline) and deadline > 0)) ||
             {:error, :invalid_workflow_options},
         {:ok, encoded} <- Codec.encode(Definition.to_map(definition)) do
      {:ok,
       create_workflow!(
         id,
         definition,
         encoded,
         Keyword.reject(opts, fn {_key, value} -> is_nil(value) end)
       )}
    end
  end

  @doc false
  def load_in_transaction(repo, id) do
    with true <- (repo == Repo and repo.in_transaction?()) || {:error, :transaction_required},
         :ok <- valid_id(id) do
      case repo.get(Workflow, id) do
        nil -> {:error, :not_found}
        row -> decode(row)
      end
    end
  end

  defp create_workflow!(id, definition, encoded, internal_opts) do
    if Repo.get(Workflow, id), do: Repo.rollback({:already_exists, id})
    queue = queue_name(id)

    unwrap(
      Repo.insert(
        Queue.changeset(%Queue{}, %{
          name: queue,
          capacity: length(definition.nodes),
          max_inflight: min(definition.max_parallel, length(definition.nodes)),
          aging_ms: 1000,
          starvation_ms: 10000
        })
      )
    )

    deadline =
      min(
        RecoveryStore.now_ms(Repo) + definition.timeout_ms,
        Keyword.get(internal_opts, :deadline_at_ms, 9_223_372_036_854_775_807)
      )

    nodes =
      Map.new(definition.nodes, fn node ->
        {node.id,
         %{
           id: node.id,
           run_id: run_id(id, node.id),
           deps: node.deps,
           role: node.role,
           status: :waiting,
           input: nil,
           completion: nil,
           observed_seq: 0,
           reason: nil
         }}
      end)

    p = %{
      schema_version: 1,
      status: :running,
      nodes: nodes,
      reason: nil,
      deadline_at_ms: deadline
    }

    data = encode!(p)

    row =
      unwrap(
        Repo.insert(
          Workflow.changeset(%Workflow{}, %{
            id: id,
            status: "running",
            seq: 0,
            queue_name: queue,
            definition_data: encoded,
            definition_sha256: Context.hash(Definition.to_map(definition)),
            progress_data: data,
            deadline_at_ms: deadline,
            control_owner_case_id: internal_opts[:owner_case_id]
          })
        )
      )

    p = enroll_ready(row, definition, p)
    row = save(row, p, "created", nil)

    if owner = internal_opts[:owner_case_id],
      do: unwrap(ControlStore.create_owned_in_transaction(Repo, row, owner))

    decode!(row)
  end

  def load(id) do
    with :ok <- boundary(), :ok <- valid_id(id) do
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

        case Repo.get(Workflow, id) do
          nil -> Repo.rollback(:not_found)
          row -> decode!(row)
        end
      end)
    end
  end

  def rebuild(id), do: load(id)

  def list(opts \\ []) do
    with :ok <- boundary(),
         true <- (is_list(opts) and Keyword.keyword?(opts)) || {:error, :invalid_workflow_options},
         true <-
           Keyword.keys(opts) -- [:limit, :status] == [] || {:error, :invalid_workflow_options},
         limit = Keyword.get(opts, :limit, 100),
         true <- (is_integer(limit) and limit in 1..1000) || {:error, :invalid_workflow_options} do
      query = from(w in Workflow, order_by: w.inserted_at, limit: ^limit, select: w.id)

      query =
        if opts[:status],
          do: from(w in query, where: w.status == ^to_string(opts[:status])),
          else: query

      {:ok, Repo.all(query)}
    end
  end

  def sync(id, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, before} <- load(id),
         {:ok, observations} <- observe(before),
         {:ok, view} <-
           transaction(opts, fn ->
             # Queue precedes Run and Workflow locks in the existing dispatcher.
             # We never lock old child Runs while holding the Workflow lock.
             unwrap(QueueStore.lock_in_transaction(Repo, before.queue))
             row = lock!(id)
             current = decode!(row)
             p = projection(current)
             p = apply_observations(p, observations)
             p = advance_status(p, row.deadline_at_ms)

             p =
               cond do
                 p.status in @closed -> skip_waiting(p)
                 get_in(current, [:control, :status]) == :paused -> p
                 true -> enroll_ready(row, current.definition, p)
               end

             p = advance_status(p, row.deadline_at_ms)
             p = if p.status in @closed, do: skip_waiting(p), else: p

             row =
               if p === projection(current),
                 do: row,
                 else: save(row, p, "advanced", projection(current))

             decode!(row)
           end),
         :ok <- fanout(view),
         {:ok, final} <- refresh_after_fanout(view) do
      {:ok, final}
    end
  end

  def cancel(id, reason \\ :user_requested, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, _} <- Codec.encode(reason),
         {:ok, view} <-
           transaction(opts, fn ->
             row = lock!(id)
             current = decode!(row)
             p = projection(current)

             if p.status in [:succeeded, :failed, :cancelled] do
               current
             else
               next = skip_waiting(%{p | status: :cancelled, reason: reason})
               row |> save(next, "cancelled", p) |> decode!()
             end
           end),
         :ok <- fanout(view),
         {:ok, final} <- refresh_after_fanout(view) do
      {:ok, final}
    end
  end

  @doc false
  def gate_in_transaction(repo, id, opts \\ []) do
    with true <- repo.in_transaction?() || {:error, :transaction_required} do
      case repo.get(Run, id) do
        %Run{workflow_id: nil} ->
          if repo.get_by(WorkflowNode, run_id: id),
            do: {:error, :workflow_membership_mismatch},
            else: :ok

        %Run{workflow_id: workflow_id, workflow_node_id: node_id} ->
          case repo.one(from(w in Workflow, where: w.id == ^workflow_id, lock: "FOR SHARE")) do
            nil ->
              {:error, :workflow_missing}

            row ->
              with {:ok, view} <- decode(row),
                   %{run_id: ^id} <- Map.get(view.nodes, node_id),
                   :ok <- ControlStore.gate_in_transaction(repo, row, opts) do
                cond do
                  Keyword.get(opts, :reconcile, false) ->
                    :ok

                  view.status in @closed ->
                    {:error, {:workflow_closed, view.status}}

                  RecoveryStore.now_ms(repo) >= row.deadline_at_ms ->
                    {:error, {:budget_exceeded, :workflow_timeout}}

                  true ->
                    :ok
                end
              else
                nil -> {:error, :workflow_membership_mismatch}
                {:error, _} = error -> error
                _ -> {:error, :workflow_membership_mismatch}
              end
          end

        nil ->
          {:error, :not_found}
      end
    end
  end

  @doc false
  def authorize_stop_in_transaction(repo, id, command) do
    with %Run{workflow_id: workflow_id} when not is_nil(workflow_id) <- repo.get(Run, id),
         %Workflow{} = row <-
           repo.one(from(w in Workflow, where: w.id == ^workflow_id, lock: "FOR SHARE")),
         {:ok, view} <- decode(row),
         true <- view.status in @closed || {:error, :workflow_not_closed} do
      case command do
        {:cancel, _} ->
          {:ok, nil}

        {:tool_result, operation_id, {:unknown, _}} ->
          case repo.one(
                 from(o in Operation, where: o.run_id == ^id and o.operation_id == ^operation_id)
               ) do
            %Operation{status: status} when status in ["prepared", "unknown"] -> {:ok, nil}
            _ -> {:error, :workflow_archive_not_unknown}
          end

        {:tool_result, operation_id, receipt} ->
          case repo.one(
                 from(o in Operation, where: o.run_id == ^id and o.operation_id == ^operation_id)
               ) do
            %Operation{status: "completed"} = operation ->
              with {:ok, saved} <- Codec.decode(operation.result_data, operation.codec_version),
                   true <- saved === receipt || {:error, :confirmed_receipt_conflict},
                   do: {:ok, nil}

            _ ->
              {:error, :workflow_archive_not_confirmed}
          end

        _ ->
          {:error, :invalid_workflow_control}
      end
    else
      nil -> {:error, :workflow_missing}
      {:error, _} = error -> error
      _ -> {:error, :workflow_membership_mismatch}
    end
  end

  def run_id(workflow_id, node_id), do: Definition.run_id(workflow_id, node_id)
  def queue_name(workflow_id), do: "wf-" <> Context.hash(workflow_id)

  defp enroll_ready(row, definition, p) do
    Enum.reduce(definition.order, p, fn id, acc ->
      node = Map.fetch!(acc.nodes, id)

      if node.status == :waiting and Enum.all?(node.deps, &(acc.nodes[&1].status == :succeeded)) do
        spec = Enum.find(definition.nodes, &(&1.id == id))
        completions = Map.new(node.deps, &{&1, acc.nodes[&1].completion})

        case join_input(spec, completions) do
          {:ok, input} ->
            options =
              unwrap(Definition.recovery_options(spec)) |> Keyword.put(:queue, row.queue_name)

            unwrap(
              Recovery.create_run_in_transaction(Repo, node.run_id, input, options,
                workflow_id: row.id,
                workflow_node_id: id,
                deadline_at_ms: row.deadline_at_ms
              )
            )

            put_in(acc, [:nodes, id], %{node | status: :running, input: input, observed_seq: 1})

          {:error, reason} ->
            put_in(acc, [:nodes, id], %{
              node
              | status: :failed,
                reason: {:dependency_join_failed, reason}
            })
        end
      else
        acc
      end
    end)
  end

  defp join_input(%{deps: []} = node, _), do: {:ok, node.input}
  defp join_input(node, completions), do: Join.build(node.input, node.deps, completions)

  defp observe(view) do
    Enum.reduce_while(view.nodes, {:ok, %{}}, fn {id, node}, {:ok, acc} ->
      if node.status in [:running, :blocked] do
        case Recovery.load(node.run_id) do
          {:ok, snapshot} -> {:cont, {:ok, Map.put(acc, id, snapshot)}}
          {:error, reason} -> {:halt, {:error, {:child_load_failed, id, reason}}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp apply_observations(p, observations) do
    Enum.reduce(observations, p, fn {id, snapshot}, acc ->
      node = acc.nodes[id]
      actual = Repo.get(Run, node.run_id)

      if ((node.status in [:running, :blocked] and actual) && actual.seq == snapshot.state.seq) and
           actual.status == to_string(snapshot.state.status) and
           Codec.decode(actual.state_data, actual.codec_version) == {:ok, snapshot.state} and
           snapshot.state.seq >= node.observed_seq do
        status =
          if snapshot.state.status == :waiting_tool, do: :running, else: snapshot.state.status

        completion = if status == :succeeded, do: unwrap(Join.completion(snapshot)), else: nil

        node = %{
          node
          | status: status,
            completion: completion,
            observed_seq: snapshot.state.seq,
            reason: snapshot.state.terminal_reason
        }

        put_in(acc, [:nodes, id], node)
      else
        acc
      end
    end)
  end

  defp advance_status(%{status: status} = p, _) when status in @closed, do: p

  defp advance_status(p, deadline) do
    statuses = Enum.map(p.nodes, fn {_, n} -> n.status end)

    cond do
      Enum.any?(statuses, &(&1 in [:failed, :cancelled])) ->
        %{p | status: :failed, reason: :child_failed}

      Enum.all?(statuses, &(&1 == :succeeded)) ->
        %{p | status: :succeeded, reason: nil}

      RecoveryStore.now_ms(Repo) >= deadline ->
        %{p | status: :failed, reason: {:budget_exceeded, :workflow_timeout}}

      :blocked in statuses ->
        %{p | status: :blocked, reason: :reconciliation_required}

      true ->
        %{p | status: :running, reason: nil}
    end
  end

  defp skip_waiting(p) do
    %{
      p
      | nodes:
          Map.new(p.nodes, fn {id, node} ->
            {id,
             if(node.status == :waiting,
               do: %{node | status: :skipped, reason: :dependency_closed},
               else: node
             )}
          end)
    }
  end

  defp fanout(%{status: status} = view) when status in @closed do
    Enum.reduce_while(view.nodes, :ok, fn {_id, node}, :ok ->
      if node.status in [:running, :blocked] do
        case stop_child(node.run_id, {:workflow_stopped, view.id, view.reason}) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp fanout(_), do: :ok

  defp stop_child(id, reason, attempts \\ 4)
  defp stop_child(_id, _reason, 0), do: {:error, :workflow_cancel_contended}

  defp stop_child(id, reason, attempts) do
    with {:ok, snapshot} <- Recovery.load(id) do
      command =
        case snapshot.state.status do
          status when status in [:succeeded, :failed, :cancelled, :blocked] ->
            nil

          :waiting_tool ->
            opid = snapshot.state.pending_operation_id

            case Repo.one(
                   from(o in Operation, where: o.run_id == ^id and o.operation_id == ^opid)
                 ) do
              %Operation{status: "completed"} = op ->
                {:tool_result, opid, unwrap(Codec.decode(op.result_data, op.codec_version))}

              %Operation{status: status} when status in ["prepared", "unknown"] ->
                op = snapshot.state.operations[opid]

                {:tool_result, opid,
                 AgentSystemsLab.Tools.Result.wrap({:unknown, :workflow_stopped}, opid, op.tool)}

              nil ->
                {:cancel, reason}
            end

          _ ->
            {:cancel, reason}
        end

      if is_nil(command) do
        :ok
      else
        case Storage.dispatch(id, snapshot.state.seq, command, workflow_control: true) do
          {:ok, %{state: %{status: :running}}} -> stop_child(id, reason, attempts - 1)
          {:ok, _} -> :ok
          {:error, {:stale_sequence, _, _}} -> stop_child(id, reason, attempts - 1)
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp refresh_after_fanout(%{status: status} = view) when status in @closed do
    with {:ok, observations} <- observe(view) do
      transaction([], fn ->
        row = lock!(view.id)
        current = decode!(row)
        p = apply_observations(projection(current), observations)

        row =
          if p === projection(current),
            do: row,
            else: save(row, p, "stopped_children", projection(current))

        decode!(row)
      end)
    end
  end

  defp refresh_after_fanout(view), do: {:ok, view}

  defp save(row, p, type, previous) do
    seq = row.seq + 1
    event = %{previous_sha256: if(previous, do: Context.hash(previous)), projection: p}

    unwrap(
      Repo.insert(
        WorkflowEvent.changeset(%WorkflowEvent{}, %{
          workflow_id: row.id,
          seq: seq,
          type: type,
          data: encode!(event)
        })
      )
    )

    Enum.each(p.nodes, fn {id, node} ->
      attrs = %{
        workflow_id: row.id,
        node_id: id,
        run_id: node.run_id,
        status: to_string(node.status),
        data: encode!(node)
      }

      case Repo.get_by(WorkflowNode, workflow_id: row.id, node_id: id) do
        nil -> unwrap(Repo.insert(WorkflowNode.changeset(%WorkflowNode{}, attrs)))
        old -> unwrap(Repo.update(WorkflowNode.changeset(old, attrs)))
      end
    end)

    unwrap(
      Repo.update(
        Workflow.changeset(row, %{
          seq: seq,
          status: to_string(p.status),
          progress_data: encode!(p)
        })
      )
    )
  end

  defp decode(row) do
    Storage.preload_vocabulary()

    with true <- row.schema_version == 1 || {:error, :unsupported_schema_version},
         {:ok, raw} <- Codec.decode(row.definition_data, row.codec_version),
         true <- Context.hash(raw) == row.definition_sha256 || {:error, :definition_hash_mismatch},
         {:ok, definition} <- Definition.from_map(raw),
         {:ok, p} <- Codec.decode(row.progress_data, row.codec_version),
         :ok <- validate_projection(row, definition, p),
         {:ok, events} <- replay_events(row, definition, p),
         :ok <- verify_nodes(row, p) do
      attach_control(row, %{
        id: row.id,
        definition: definition,
        queue: row.queue_name,
        status: p.status,
        nodes: p.nodes,
        seq: row.seq,
        deadline_at_ms: row.deadline_at_ms,
        reason: p.reason,
        events: events,
        unresolved_nodes: for({id, %{status: :blocked}} <- p.nodes, do: id)
      })
    else
      {:error, reason} -> {:error, {:corrupt_workflow, reason}}
    end
  end

  defp attach_control(row, view) do
    with {:ok, control} <- ControlStore.load_in_transaction(Repo, row.id) do
      {:ok, if(control, do: Map.put(view, :control, control), else: view)}
    end
  end

  defp validate_projection(row, definition, p) do
    expected = Enum.sort(Enum.map(definition.nodes, & &1.id))

    valid =
      is_map(p) and
        Enum.sort(Map.keys(p)) ==
          Enum.sort([:schema_version, :status, :nodes, :reason, :deadline_at_ms]) and
        p.schema_version == 1 and p.deadline_at_ms === row.deadline_at_ms and
        row.queue_name === queue_name(row.id) and
        p.status in [:running, :blocked, :succeeded, :failed, :cancelled] and
        to_string(p.status) == row.status and is_map(p.nodes) and
        Enum.sort(Map.keys(p.nodes)) == expected and
        Enum.all?(definition.nodes, fn spec ->
          node = p.nodes[spec.id]

          is_map(node) and
            Enum.sort(Map.keys(node)) ==
              Enum.sort([
                :id,
                :run_id,
                :deps,
                :role,
                :status,
                :input,
                :completion,
                :observed_seq,
                :reason
              ]) and
            node.id == spec.id and node.deps == spec.deps and node.role == spec.role and
            node.run_id == run_id(row.id, spec.id) and
            node.status in @statuses and is_integer(node.observed_seq) and node.observed_seq >= 0 and
            (node.status != :succeeded or
               (is_map(node.completion) and Map.get(node.completion, :run_id) == node.run_id))
        end)

    if valid, do: :ok, else: {:error, :projection_mismatch}
  end

  defp replay_events(row, definition, p) do
    rows = Repo.all(from(e in WorkflowEvent, where: e.workflow_id == ^row.id, order_by: e.seq))

    result =
      Enum.reduce_while(rows, {:ok, nil, []}, fn event, {:ok, previous, acc} ->
        with true <- event.schema_version == 1 || {:error, :unsupported_event_schema_version},
             true <- event.seq == length(acc) + 1 || {:error, :event_sequence_gap},
             true <-
               event.type in ["created", "advanced", "cancelled", "stopped_children"] ||
                 {:error, :unknown_event_type},
             true <-
               if(event.seq == 1, do: event.type == "created", else: event.type != "created") ||
                 {:error, :invalid_event_kind},
             {:ok, %{previous_sha256: hash, projection: current}} <-
               Codec.decode(event.data, event.codec_version),
             true <-
               hash == if(previous, do: Context.hash(previous)) || {:error, :event_chain_mismatch},
             :ok <- validate_history_projection(row, definition, current),
             :ok <- valid_history_transition(previous, current, event.type) do
          {:cont,
           {:ok, current,
            [%{seq: event.seq, type: event.type, schema_version: 1, data: current} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :invalid_event}}
        end
      end)

    case result do
      {:ok, ^p, events} when length(events) == row.seq -> {:ok, Enum.reverse(events)}
      {:ok, _, _} -> {:error, :event_projection_mismatch}
      error -> error
    end
  end

  defp validate_history_projection(row, definition, p) when is_map(p) do
    if Map.get(p, :status) in [:running, :blocked, :succeeded, :failed, :cancelled],
      do: validate_projection(%{row | status: to_string(p.status)}, definition, p),
      else: {:error, :invalid_event_projection}
  end

  defp validate_history_projection(_, _, _), do: {:error, :invalid_event_projection}

  defp valid_history_transition(nil, current, "created") do
    if current.status == :running and
         Enum.all?(current.nodes, fn {_, node} ->
           (node.deps == [] and node.status == :running and node.observed_seq == 1) or
             (node.deps != [] and node.status == :waiting and node.observed_seq == 0)
         end), do: :ok, else: {:error, :invalid_initial_projection}
  end

  defp valid_history_transition(previous, current, type) when is_map(previous) do
    parent_valid =
      previous.status not in [:succeeded, :failed, :cancelled] or
        previous.status == current.status

    nodes_valid =
      Enum.all?(previous.nodes, fn {id, old} ->
        new = current.nodes[id]

        cond do
          old.status in [:succeeded, :failed, :cancelled, :skipped] ->
            old === new

          new.observed_seq < old.observed_seq ->
            false

          old.status == :waiting and new.status == :running ->
            current.status not in @closed and new.observed_seq == 1 and
              Enum.all?(new.deps, &(current.nodes[&1].status == :succeeded))

          old.status == :waiting and new.status == :waiting ->
            old === new

          old.status == :waiting and new.status == :skipped ->
            current.status in @closed and new.observed_seq == 0

          old.status == :waiting and new.status == :failed ->
            match?({:dependency_join_failed, _}, new.reason) and new.observed_seq == 0 and
              Enum.all?(new.deps, &(current.nodes[&1].status == :succeeded))

          old.status in [:running, :blocked] ->
            new.status in [:running, :blocked, :succeeded, :failed, :cancelled]

          true ->
            false
        end
      end)

    kind_valid = type != "cancelled" or current.status == :cancelled

    if parent_valid and nodes_valid and kind_valid,
      do: :ok,
      else: {:error, :invalid_event_transition}
  end

  defp valid_history_transition(_, _, _), do: {:error, :invalid_event_transition}

  defp verify_nodes(row, p) do
    rows = Repo.all(from(n in WorkflowNode, where: n.workflow_id == ^row.id))

    valid =
      length(rows) == map_size(p.nodes) and
        Enum.all?(rows, fn node ->
          expected = Map.get(p.nodes, node.node_id)

          is_map(expected) and node.schema_version == 1 and node.run_id == expected.run_id and
            node.status == to_string(expected.status) and
            Codec.decode(node.data, node.codec_version) == {:ok, expected} and
            valid_membership?(row, expected)
        end)

    if valid, do: :ok, else: {:error, :node_projection_mismatch}
  end

  defp valid_membership?(row, node) do
    case {node.observed_seq, Repo.get(Run, node.run_id)} do
      {0, nil} ->
        true

      {seq, %Run{workflow_id: wid, workflow_node_id: nid, queue_name: queue} = child}
      when seq > 0 ->
        wid == row.id and nid == node.id and queue == row.queue_name and
          matching_child_input?(child, node) and valid_completion?(child, node)

      _ ->
        false
    end
  end

  defp matching_child_input?(child, node) do
    case Codec.decode(child.state_data, child.codec_version) do
      {:ok, %AgentSystemsLab.Kernel.State{input: input}} -> input === node.input
      _ -> false
    end
  end

  defp valid_completion?(child, %{status: :succeeded, completion: completion}) do
    with {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, child),
         {:ok, actual} <- Join.completion(snapshot) do
      actual === completion
    else
      _ -> false
    end
  end

  defp valid_completion?(_child, _node), do: true

  defp projection(view),
    do: %{
      schema_version: 1,
      status: view.status,
      nodes: view.nodes,
      reason: view.reason,
      deadline_at_ms: view.deadline_at_ms
    }

  defp lock!(id),
    do:
      Repo.one(from(w in Workflow, where: w.id == ^id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

  defp decode!(row), do: unwrap(decode(row))
  defp encode!(value), do: unwrap(Codec.encode(value))
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp transaction(opts, function) do
    case Repo.transaction(fn ->
           result = function.()
           hook(opts, :before_commit)
           result
         end) do
      {:ok, result} ->
        observe_committed(result)
        hook(opts, :after_commit)
        {:ok, result}

      error ->
        error
    end
  end

  defp observe_committed(view) do
    measurements = %{
      sequence: view.seq,
      nodes_running: Enum.count(view.nodes, fn {_, node} -> node.status == :running end),
      nodes_blocked: Enum.count(view.nodes, fn {_, node} -> node.status == :blocked end),
      nodes_succeeded: Enum.count(view.nodes, fn {_, node} -> node.status == :succeeded end)
    }

    AgentSystemsLab.Observability.emit(
      :workflow_committed,
      %{workflow_id: view.id, seq: view.seq},
      measurements,
      phase: :committed,
      status: view.status
    )

    for {_id, node} <- view.nodes, node.status not in [:waiting, :skipped] do
      AgentSystemsLab.Observability.emit(
        :workflow_committed,
        %{run_id: node.run_id, workflow_id: view.id, seq: view.seq},
        measurements,
        phase: :committed,
        status: view.status
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp hook(opts, stage), do: if(opts[:hook], do: opts[:hook].(stage), else: :ok)

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)

  defp valid_id(id),
    do:
      if(
        is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
          not String.contains?(id, <<0>>),
        do: :ok,
        else: {:error, :invalid_workflow_id}
      )

  defp options(opts),
    do:
      if(
        is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:hook] == [] and
          length(opts) <= 1 and (is_nil(opts[:hook]) or is_function(opts[:hook], 1)),
        do: :ok,
        else: {:error, :invalid_workflow_options}
      )
end
