defmodule AgentSystemsLab.Storage do
  @moduledoc """
  PostgreSQL persistence for the pure kernel and its next scheduling decision.

  Every accepted command commits its run projection, ordered event, superseding
  of the previous intent, and next intent in one `Ecto.Multi` transaction. A row
  lock serializes writers; `expected_seq` rejects commands based on stale state.
  A live scheduling claim also requires the worker's exact fencing token;
  operator cancellation and failure can supersede that lease. Recovery cursor
  progress and accepted model recordings share this same commit boundary.
  These functions perform no model or tool calls and do not claim exactly-once
  delivery of external effects.

  Snapshots include the full event history. Reads replay that history and check
  the saved projection and pending intent before returning it. The optional
  `hook: fn stage -> ... end` is a fault-injection seam: `:before_commit` runs as
  the final transaction operation and `:after_commit` runs after PostgreSQL has
  committed but before the caller receives its result. Hook exceptions and exits
  propagate, allowing tests to kill the real calling process at either boundary.
  Writes reject an outer Repo transaction: a nested transaction cannot establish
  this API's promised COMMIT-before-acknowledgement boundary.
  """

  import Ecto.Query

  alias AgentSystemsLab.Observability.Context, as: TraceContext
  alias AgentSystemsLab.Kernel, as: RunKernel
  alias AgentSystemsLab.Kernel.{Event, State}
  alias AgentSystemsLab.{Observability, Repo}
  alias AgentSystemsLab.Storage.{Codec, Intent, Run}
  alias AgentSystemsLab.Storage.Event, as: StoredEvent
  alias AgentSystemsLab.History.Encoding
  alias Ecto.Multi

  @event_types %{
    "run_started" => :run_started,
    "tool_requested" => :tool_requested,
    "tool_result_recorded" => :tool_result_recorded,
    "tool_reconciled" => :tool_reconciled,
    "run_succeeded" => :run_succeeded,
    "run_failed" => :run_failed,
    "run_cancelled" => :run_cancelled
  }

  @type snapshot :: %{state: State.t(), events: [Event.t()], intent: Intent.t() | nil}

  @spec create_run(String.t(), String.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def create_run(run_id, input, opts \\ []) do
    with :ok <- validate_transaction_boundary(),
         :ok <-
           validate_options(opts, [
             :max_turns,
             :hook,
             :recovery_config,
             :priority,
             :queue,
             :task_budget
           ]),
         {:ok, multi} <- create_run_multi(run_id, input, opts) do
      multi |> before_commit(opts) |> commit_creation(run_id, opts)
    end
  end

  @doc false
  def create_run_in_transaction(repo, run_id, input, opts \\ []) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, multi} <- create_run_multi(run_id, input, opts) do
      case repo.transaction(multi) do
        {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp create_run_multi(run_id, input, opts) do
    with :ok <-
           validate_options(opts, [
             :max_turns,
             :hook,
             :recovery_config,
             :priority,
             :queue,
             :task_budget,
             :workflow_id,
             :workflow_node_id,
             :deadline_at_ms
           ]),
         true <-
           (is_nil(Keyword.get(opts, :queue)) or Keyword.has_key?(opts, :recovery_config)) ||
             {:error, :queue_requires_recovery},
         priority = Keyword.get(opts, :priority, 0),
         true <- (is_integer(priority) and priority in 0..9) || {:error, :invalid_priority},
         {:ok, initial} <- RunKernel.new(run_id, Keyword.take(opts, [:max_turns])),
         {:ok, state, events} <- RunKernel.dispatch(initial, {:start, input}),
         {:ok, attrs} <- run_attrs(state),
         {:ok, encoded_events} <- encode_events(events),
         {:ok, next_intent} <- intent_attrs(state) do
      multi =
        Multi.new()
        |> Multi.run(:queue, fn repo, _ ->
          AgentSystemsLab.QueueStore.admit_in_transaction(repo, Keyword.get(opts, :queue))
        end)
        |> Multi.insert(
          :run,
          Run.changeset(
            %Run{},
            attrs
            |> Map.put(:priority, priority)
            |> Map.put(:queue_name, Keyword.get(opts, :queue))
            |> Map.put(:workflow_id, Keyword.get(opts, :workflow_id))
            |> Map.put(:workflow_node_id, Keyword.get(opts, :workflow_node_id))
          )
        )
        |> Multi.run(:events, fn repo, _changes -> insert_events(repo, encoded_events) end)
        |> Multi.run(:intent, fn repo, _changes -> insert_intent(repo, next_intent) end)
        |> Multi.run(:recovery_config, fn repo, _changes ->
          case Keyword.fetch(opts, :recovery_config) do
            :error ->
              {:ok, nil}

            {:ok, config} ->
              with {:ok, row} <-
                     AgentSystemsLab.RecoveryStore.insert_in_transaction(repo, state, config),
                   :ok <-
                     AgentSystemsLab.RecoveryStore.clamp_deadline_in_transaction(
                       repo,
                       row,
                       Keyword.get(opts, :deadline_at_ms)
                     ),
                   do: {:ok, row}
          end
        end)
        |> Multi.run(:task_budget, fn repo, _changes ->
          case Keyword.fetch(opts, :task_budget) do
            {:ok, budget} ->
              AgentSystemsLab.TaskBudgetStore.insert_in_transaction(repo, state, budget)

            :error ->
              if is_nil(Keyword.get(opts, :queue)),
                do: {:ok, nil},
                else: AgentSystemsLab.TaskBudgetStore.insert_in_transaction(repo, state, [])
          end
        end)
        |> Multi.run(:snapshot, fn _repo, %{intent: intent} ->
          {:ok, %{state: state, events: events, intent: intent}}
        end)

      {:ok, multi}
    end
  end

  defp commit_creation(multi, run_id, opts) do
    case commit(multi, opts) do
      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_run?(changeset),
          do: {:error, {:already_exists, run_id}},
          else: {:error, changeset}

      result ->
        result
    end
  end

  @doc "Commits one kernel command if the persisted sequence matches `expected_seq`."
  @spec dispatch(String.t(), non_neg_integer(), RunKernel.command(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def dispatch(run_id, expected_seq, command, opts \\ []) do
    with :ok <- validate_transaction_boundary(),
         :ok <-
           validate_options(opts, [
             :hook,
             :model_result,
             :claim,
             :recovery_progress,
             :workflow_control
           ]),
         :ok <- validate_workflow_control(opts),
         :ok <- validate_model_recording(command, opts),
         :ok <- validate_expected_seq(expected_seq) do
      Multi.new()
      |> Multi.run(:run, fn repo, _changes -> fetch_run(repo, run_id, :update) end)
      |> Multi.run(:current, fn repo, %{run: run} -> snapshot_from_run(repo, run) end)
      |> Multi.run(:claim, fn repo, %{current: current} ->
        authorize_transition(repo, current, expected_seq, command, opts)
      end)
      |> Multi.run(:transition, fn _repo, %{current: current, run: run} ->
        transition(current, expected_seq, command, run.history_format)
      end)
      |> Multi.update(:persist_run, fn %{run: run, transition: transition} ->
        Run.changeset(run, transition.run_attrs)
      end)
      |> Multi.run(:events, fn repo, %{transition: transition} ->
        insert_events(repo, transition.encoded_events)
      end)
      |> Multi.run(:model_result, fn repo, %{current: current, transition: transition} ->
        case Keyword.fetch(opts, :model_result) do
          :error ->
            {:ok, nil}

          {:ok, recording} ->
            AgentSystemsLab.ModelResultStore.insert_for_transition(
              repo,
              current.state,
              transition.events,
              recording
            )
        end
      end)
      |> Multi.run(:recovery_progress, fn repo, %{current: current, transition: transition} ->
        AgentSystemsLab.RecoveryStore.update_in_transaction(
          repo,
          current.state,
          transition.state,
          Keyword.get(opts, :recovery_progress)
        )
      end)
      |> Multi.run(:retry_progress, fn repo, %{current: current, transition: transition} ->
        AgentSystemsLab.RetryStore.complete_transition_in_transaction(
          repo,
          current.state,
          transition.state
        )
      end)
      |> Multi.run(:supersede_intents, fn repo, %{run: run} ->
        {count, _} =
          repo.update_all(
            from(intent in Intent,
              where: intent.run_id == ^run.id and intent.status == "pending"
            ),
            set: [
              status: "superseded",
              claim_token: nil,
              claim_owner: nil,
              claim_expires_at: nil,
              updated_at: DateTime.utc_now()
            ]
          )

        {:ok, count}
      end)
      |> Multi.run(:intent, fn repo, %{transition: transition} ->
        insert_intent(repo, transition.intent_attrs)
      end)
      |> Multi.run(:snapshot, fn _repo, changes ->
        {:ok,
         %{
           state: changes.transition.state,
           events: changes.current.events ++ changes.transition.events,
           intent: changes.intent
         }}
      end)
      |> before_commit(opts)
      |> commit(opts)
    end
  end

  @doc "Loads and verifies one committed snapshot under a shared row lock."
  @spec load(String.t()) :: {:ok, snapshot()} | {:error, term()}
  def load(run_id) do
    Multi.new()
    |> Multi.run(:run, fn repo, _changes -> fetch_run(repo, run_id, :share) end)
    |> Multi.run(:snapshot, fn repo, %{run: run} -> snapshot_from_run(repo, run) end)
    |> commit([])
  end

  @doc false
  def snapshot_in_transaction(repo, %Run{} = row) do
    if repo.in_transaction?(),
      do: snapshot_from_run(repo, row),
      else: {:error, :transaction_required}
  end

  @doc "Lists durable pending decisions; it does not claim or execute them."
  @spec pending_intents() :: [Intent.t()]
  def pending_intents do
    Repo.all(from(intent in Intent, where: intent.status == "pending", order_by: intent.id))
  end

  defp transition(current, expected_seq, command, history_format) do
    if current.state.seq == expected_seq do
      with {:ok, state, events} <- RunKernel.dispatch(current.state, command),
           {:ok, attrs} <- run_attrs(state),
           {:ok, encoded_events} <- encode_events(events, history_format),
           {:ok, next_intent} <- intent_attrs(state) do
        {:ok,
         %{
           state: state,
           events: events,
           run_attrs: attrs,
           encoded_events: encoded_events,
           intent_attrs: next_intent
         }}
      end
    else
      {:error, {:stale_sequence, expected_seq, current.state.seq}}
    end
  end

  defp authorize_transition(repo, current, expected_seq, command, opts) do
    if current.state.seq != expected_seq do
      {:error, {:stale_sequence, expected_seq, current.state.seq}}
    else
      case {Keyword.get(opts, :workflow_control, false), Keyword.fetch(opts, :claim)} do
        {true, :error} ->
          AgentSystemsLab.Workflows.Store.authorize_stop_in_transaction(
            repo,
            current.state.run_id,
            command
          )

        {false, {:ok, claim}} ->
          AgentSystemsLab.IntentStore.verify(repo, current.state.run_id, expected_seq, claim)

        {false, :error} ->
          case command do
            {kind, _reason} when kind in [:cancel, :fail] ->
              {:ok, nil}

            _ ->
              with :ok <-
                     AgentSystemsLab.Workflows.Store.gate_in_transaction(
                       repo,
                       current.state.run_id
                     ),
                   :ok <- AgentSystemsLab.IntentStore.ensure_unclaimed(repo, current.intent),
                   do: {:ok, nil}
          end

        _ ->
          {:error, :invalid_workflow_control_options}
      end
    end
  end

  defp fetch_run(repo, run_id, lock) when is_binary(run_id) do
    query = from(run in Run, where: run.id == ^run_id)

    query =
      case lock do
        :update -> from(run in query, lock: "FOR UPDATE")
        :share -> from(run in query, lock: "FOR SHARE")
      end

    case repo.one(query) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp fetch_run(_repo, run_id, _lock), do: {:error, {:invalid_run_id, run_id}}

  @doc false
  def preload_vocabulary do
    # Safe ETF never interns database-authored atom names. Load the trusted
    # runtime vocabulary first, including mock receipts and driver failure tags,
    # so a fresh VM can read facts written by the shipped runtime.
    Enum.each(
      [
        RunKernel,
        State,
        Event,
        AgentSystemsLab.RunServer,
        AgentSystemsLab.Context,
        AgentSystemsLab.Checkpoint,
        AgentSystemsLab.History,
        AgentSystemsLab.Recording,
        AgentSystemsLab.ModelResultStore,
        AgentSystemsLab.Providers.Recorded,
        AgentSystemsLab.Storage.ModelResult,
        AgentSystemsLab.Session,
        AgentSystemsLab.Budget,
        AgentSystemsLab.Stream,
        JSON,
        AgentSystemsLab.Providers.Scripted,
        AgentSystemsLab.Tools.Catalog,
        AgentSystemsLab.Tools.Gateway,
        AgentSystemsLab.Tools.Result,
        AgentSystemsLab.Tools.Files,
        AgentSystemsLab.Tools.Workspace,
        AgentSystemsLab.Tools.Patch,
        AgentSystemsLab.Tools.Mock,
        AgentSystemsLab.Isolation,
        AgentSystemsLab.Isolation.Policy,
        AgentSystemsLab.MCP,
        AgentSystemsLab.MCP.Policy,
        AgentSystemsLab.MCP.Schema,
        AgentSystemsLab.MCP.Connection,
        AgentSystemsLab.MCP.Stdio,
        AgentSystemsLab.IntentStore,
        AgentSystemsLab.RecoveryStore,
        AgentSystemsLab.Recovery,
        AgentSystemsLab.TaskBudgetStore,
        AgentSystemsLab.QueueStore,
        AgentSystemsLab.Scheduler.Worker,
        AgentSystemsLab.RetryPolicy,
        AgentSystemsLab.RetryStore,
        AgentSystemsLab.ErrorPolicy,
        AgentSystemsLab.ReconciliationQueue,
        AgentSystemsLab.DurableTools,
        AgentSystemsLab.Tools.DurableMock,
        AgentSystemsLab.Workflows.Definition,
        AgentSystemsLab.Workflows.Join,
        AgentSystemsLab.Workflows.Store,
        AgentSystemsLab.Workflows.ControlStore,
        AgentSystemsLab.Approvals.Cases,
        AgentSystemsLab.Approvals.Plan,
        AgentSystemsLab.Approvals.Artifact
      ],
      &Code.ensure_loaded!/1
    )
  end

  defp snapshot_from_run(repo, run) do
    preload_vocabulary()

    rows =
      repo.all(from(event in StoredEvent, where: event.run_id == ^run.id, order_by: event.seq))

    pending =
      repo.all(
        from(intent in Intent, where: intent.run_id == ^run.id and intent.status == "pending")
      )

    with :ok <- Encoding.validate_format(run.history_format),
         :ok <- Encoding.validate_rows(rows, run.history_format),
         {:ok, state} <- Codec.decode(run.state_data, run.codec_version),
         {:ok, events} <- decode_events(rows),
         {:ok, replayed} <- RunKernel.rebuild(run.id, events, max_turns: run.max_turns),
         :ok <- AgentSystemsLab.HistoryMigration.verify_in_transaction(repo, run, rows, events),
         :ok <- verify_projection(run, state, replayed),
         {:ok, intent} <- verify_intent(state, pending) do
      {:ok, %{state: state, events: events, intent: intent}}
    else
      {:error, reason} -> {:error, {:corrupt_storage, reason}}
    end
  end

  defp verify_projection(run, %State{} = state, replayed) do
    if state === replayed and run.id === state.run_id and run.seq === state.seq and
         run.status === Atom.to_string(state.status) and run.max_turns === state.max_turns and
         run.turn_count === state.turn_count,
       do: :ok,
       else: {:error, :projection_mismatch}
  end

  defp verify_projection(_run, _state, _replayed), do: {:error, :invalid_projection}

  defp verify_intent(state, pending) do
    with {:ok, expected} <- intent_attrs(state) do
      case {expected, pending} do
        {nil, []} ->
          {:ok, nil}

        {%{} = attrs, [%Intent{} = intent]} ->
          with {:ok, payload} <- Codec.decode(intent.payload, intent.codec_version),
               {:ok, expected_payload} <- Codec.decode(attrs.payload) do
            if intent.run_id === state.run_id and intent.seq === state.seq and
                 intent.kind === attrs.kind and payload === expected_payload,
               do: {:ok, intent},
               else: {:error, :intent_mismatch}
          end

        _ ->
          {:error, :intent_mismatch}
      end
    end
  end

  defp run_attrs(state) do
    with {:ok, encoded} <- Codec.encode(state) do
      {:ok,
       %{
         id: state.run_id,
         seq: state.seq,
         status: Atom.to_string(state.status),
         max_turns: state.max_turns,
         turn_count: state.turn_count,
         state_data: encoded,
         codec_version: Codec.version()
       }}
    end
  end

  defp encode_events(events, history_format \\ 1) do
    collect(events, fn event ->
      with {:ok, original} <- Codec.encode(event.data),
           {:ok, encoded} <- Encoding.encode(original, history_format) do
        {:ok,
         %{
           run_id: event.run_id,
           seq: event.seq,
           type: Atom.to_string(event.type),
           schema_version: event.schema_version,
           data: encoded,
           codec_version: Codec.version(),
           history_format: history_format
         }}
      end
    end)
  end

  defp decode_events(rows) do
    collect(rows, fn row ->
      with {:ok, type} <- fetch_event_type(row.type),
           {:ok, data} <- Encoding.decode_event(row) do
        {:ok,
         %Event{
           run_id: row.run_id,
           seq: row.seq,
           type: type,
           schema_version: row.schema_version,
           data: data
         }}
      end
    end)
  end

  defp fetch_event_type(type) do
    case Map.fetch(@event_types, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_event_type, type}}
    end
  end

  defp intent_attrs(%State{status: status} = state)
       when status in [:running, :waiting_tool, :blocked] do
    {kind, payload} =
      case status do
        :running -> {"model", %{}}
        :waiting_tool -> {"tool", %{operation_id: state.pending_operation_id}}
        :blocked -> {"reconcile", %{operation_id: state.pending_operation_id}}
      end

    with {:ok, encoded} <- Codec.encode(payload) do
      {:ok,
       %{
         run_id: state.run_id,
         seq: state.seq,
         kind: kind,
         status: "pending",
         payload: encoded,
         codec_version: Codec.version()
       }}
    end
  end

  defp intent_attrs(%State{status: status}) when status in [:succeeded, :failed, :cancelled],
    do: {:ok, nil}

  defp insert_events(repo, attrs),
    do: collect(attrs, fn item -> repo.insert(StoredEvent.changeset(%StoredEvent{}, item)) end)

  defp insert_intent(_repo, nil), do: {:ok, nil}
  defp insert_intent(repo, attrs), do: repo.insert(Intent.changeset(%Intent{}, attrs))

  defp collect(values, function) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp before_commit(multi, opts) do
    Multi.run(multi, :before_commit, fn _repo, _changes ->
      invoke_hook(opts, :before_commit)
      {:ok, :ok}
    end)
  end

  defp commit(multi, opts) do
    case Repo.transaction(multi) do
      {:ok, %{snapshot: snapshot} = changes} ->
        if Map.has_key?(changes, :events), do: observe_commit(snapshot, changes, opts)
        invoke_hook(opts, :after_commit)
        {:ok, snapshot}

      {:error, _operation, reason, _changes} ->
        if reason in [:stale_claim, :claim_expired] and is_map(Keyword.get(opts, :claim)) do
          claim = opts[:claim]

          Observability.emit(
            :lease_rejected,
            Map.take(claim, [:run_id, :seq, :intent_id, :generation]),
            %{},
            phase: :observed,
            reason: if(reason == :stale_claim, do: :stale, else: :expired)
          )
        end

        {:error, reason}
    end
  end

  # Only this outer transaction helper may announce committed Run facts. The
  # internal enrollment helper is deliberately silent until its parent commits.
  defp observe_commit(snapshot, changes, opts) do
    state = snapshot.state
    claim = Keyword.get(opts, :claim)

    refs = %{
      run_id: state.run_id,
      seq: state.seq,
      turn_id: state.turn_count,
      span_id: TraceContext.span_id(:run, state.run_id)
    }

    refs =
      if is_map(claim),
        do: Map.merge(refs, Map.take(claim, [:intent_id, :generation])),
        else: refs

    name = if Map.has_key?(changes, :transition), do: :run_committed, else: :run_created
    Observability.emit(name, refs, %{}, phase: :committed, status: state.status)

    events =
      case Map.get(changes, :transition) do
        %{events: events} -> events
        nil -> snapshot.events
      end

    Enum.each(events, fn event ->
      event_refs =
        Map.merge(refs, %{
          seq: event.seq,
          span_id: TraceContext.span_id(:kernel_event, {state.run_id, event.seq}),
          parent_span_id: TraceContext.span_id(:run, state.run_id)
        })

      Observability.emit(:event_committed, event_refs, %{},
        phase: :committed,
        event_type: event.type,
        status: state.status
      )
    end)

    if recording = Map.get(changes, :model_result) do
      model_refs =
        Map.merge(refs, %{
          attempt_id: recording.context_id,
          span_id: TraceContext.span_id(:model, {state.run_id, recording.context_id}),
          parent_span_id: TraceContext.span_id(:run, state.run_id)
        })

      Observability.emit(:model_recorded, model_refs, %{}, phase: :committed)
    end

    if is_map(claim) do
      intent_refs =
        Map.merge(refs, %{
          seq: claim.seq,
          span_id:
            TraceContext.span_id(:intent, {state.run_id, claim.intent_id, claim.generation}),
          parent_span_id: TraceContext.span_id(:run, state.run_id)
        })

      Observability.emit(:intent_completed, intent_refs, %{}, phase: :committed)
    end
  end

  defp invoke_hook(opts, stage) do
    case Keyword.get(opts, :hook) do
      nil -> :ok
      hook -> hook.(stage)
    end
  end

  defp duplicate_run?(%Ecto.Changeset{data: %Run{}, errors: errors}),
    do:
      Enum.any?(errors, fn {field, {_message, opts}} ->
        field == :id and opts[:constraint] == :unique
      end)

  defp duplicate_run?(_changeset), do: false

  defp validate_expected_seq(seq) when is_integer(seq) and seq >= 0, do: :ok
  defp validate_expected_seq(seq), do: {:error, {:invalid_expected_sequence, seq}}

  defp validate_transaction_boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end

  defp validate_workflow_control(opts) do
    case Keyword.fetch(opts, :workflow_control) do
      :error ->
        :ok

      {:ok, false} ->
        :ok

      {:ok, true} ->
        if(Keyword.has_key?(opts, :claim),
          do: {:error, :invalid_workflow_control_options},
          else: :ok
        )

      _ ->
        {:error, :invalid_workflow_control_options}
    end
  end

  defp validate_model_recording({:model_response, response}, opts) do
    case Keyword.fetch(opts, :model_result) do
      :error ->
        :ok

      {:ok, %{context_id: _context_id, provider: _provider, response: recorded} = value}
      when map_size(value) == 3 and recorded === response ->
        :ok

      {:ok, _value} ->
        {:error, :invalid_model_result_recording}
    end
  end

  defp validate_model_recording(_command, opts) do
    if Keyword.has_key?(opts, :model_result),
      do: {:error, :invalid_model_result_recording},
      else: :ok
  end

  defp validate_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(Keyword.get(opts, :hook)) or is_function(Keyword.get(opts, :hook), 1)),
       do: :ok,
       else: {:error, {:invalid_options, opts}}
  end

  defp validate_options(opts, _allowed), do: {:error, {:invalid_options, opts}}
end
