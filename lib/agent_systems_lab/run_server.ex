defmodule AgentSystemsLab.RunServer do
  @moduledoc """
  The OTP shell around the pure kernel, with asynchronous, cancellable model I/O.

  `step/1` waits for one completed model response or tool result. `start_stream/1`
  returns immediately; subscribers receive ordered, volatile stream notifications.
  Partial output never becomes a kernel event or authorizes a tool effect. A
  completed response is committed before the provider cursor and finished notice
  are published. Only a later explicit step executes an approved tool call.

  Runs, live stream previews, provider cursors and mock receipts are volatile in
  memory mode. PostgreSQL stores accepted kernel transitions, not partial frames.
  Cancellation stops future work; it does not undo confirmed external effects.

  Each request derives a bounded Context from the canonical Session, accepted run
  facts and host permissions. Its manifest stays outside the provider payload.
  PostgreSQL commits this input capture before starting the provider. Host
  messages do not modify kernel history or grant tool permissions; accepted model
  output and tool receipts remain authoritative facts in the run journal.
  """
  use GenServer, restart: :temporary

  alias AgentSystemsLab.{
    Budget,
    Context,
    ContextStore,
    Observability,
    Recording,
    Session,
    SessionStore,
    Storage,
    Stream
  }

  alias AgentSystemsLab.Kernel, as: RunKernel
  alias AgentSystemsLab.Providers.Scripted
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.{Catalog, Files, Gateway, Mock, Result, Workspace}

  @terminal [:succeeded, :failed, :cancelled]
  @preview_limit 128

  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and is_binary(opts[:run_id]) and opts[:run_id] != "" do
      name = {:via, Registry, {AgentSystemsLab.Registry, opts[:run_id]}}
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @doc "Returns committed state and a bounded preview of the latest request."
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Waits for at most one complete model request or one tool request."
  def step(server), do: GenServer.call(server, :step, :infinity)

  @doc "Starts one model request and immediately returns its correlation reference."
  def start_stream(server), do: GenServer.call(server, :start_stream)

  @doc "Subscribes this process to future `{:agent_stream, id, ref, seq, event}` notices."
  def subscribe(server), do: GenServer.call(server, :subscribe)

  @doc "Appends a host conversation message while no provider request is active."
  def append_message(server, role, content),
    do: GenServer.call(server, {:append_message, role, content})

  @doc "Submits a command. During a model request only cancellation and failure are allowed."
  def command(server, command), do: GenServer.call(server, {:command, command})

  @doc "Cancels the run and its active provider, retaining confirmed tool history."
  def cancel(server, reason \\ :user_requested), do: command(server, {:cancel, reason})

  @doc "Checks a lost mock receipt before recording a reconciliation decision."
  def reconcile_from_mock(server), do: GenServer.call(server, :reconcile_from_mock)

  def run_until_pause(server, max_steps \\ 20)

  def run_until_pause(server, max_steps) when is_integer(max_steps) and max_steps >= 0 do
    current = snapshot(server)

    cond do
      current.state.status in (@terminal ++ [:blocked]) ->
        {:ok, current}

      max_steps == 0 ->
        {:error, :step_limit, current}

      true ->
        case step(server) do
          {:ok, _next} -> run_until_pause(server, max_steps - 1)
          {:error, reason} -> {:error, reason, snapshot(server)}
        end
    end
  end

  def run_until_pause(_server, _max_steps), do: {:error, :invalid_step_limit}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with true <- is_binary(opts[:input]),
         true <- opts[:mock_response] in [nil, :ok, :lost, :fail_before_effect],
         true <- Keyword.get(opts, :storage, :memory) in [:memory, :postgres],
         {:ok, budget} <- Budget.new(opts),
         {:ok, provider} <- Scripted.new(opts[:script]),
         {:ok, files} <- initialize_files(opts),
         {:ok, isolation_policy} <- initialize_isolation(opts),
         {:ok, mcp_policy} <- initialize_mcp(opts),
         {:ok, context_options} <- initialize_context_options(opts),
         {:ok, session, session_id} <- initialize_session(opts),
         {:ok, run, events} <- initialize_run(opts),
         {:ok, mock} <- Mock.start_link([]) do
      observe_created(run, Keyword.get(opts, :storage, :memory))
      deadline_ref = make_ref()
      deadline = now_ms() + budget.run_timeout_ms
      timer = Process.send_after(self(), {:run_timeout, deadline_ref}, budget.run_timeout_ms)

      {:ok,
       %{
         run: run,
         provider: provider,
         mock: mock,
         mock_response: opts[:mock_response] || :ok,
         files: files,
         isolation_policy: isolation_policy,
         mcp_policy: mcp_policy,
         session: session,
         session_id: session_id,
         context_options: context_options,
         context: nil,
         context_id: nil,
         recordings: [],
         recording_errors: [],
         storage: Keyword.get(opts, :storage, :memory),
         events: events,
         budget: budget,
         active: nil,
         tool_active: nil,
         stream: %{active?: false, request_id: nil, events: [], output_bytes: 0},
         subscribers: %{},
         deadline: deadline,
         deadline_ref: deadline_ref,
         run_timer: timer
       }}
    else
      false -> {:stop, :invalid_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call(:subscribe, {pid, _tag}, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:command, {kind, _reason} = command}, _from, state)
      when kind in [:cancel, :fail] do
    reply_to_command(state, command)
  end

  def handle_call({:stream_frame, request_id, worker, event}, {caller, _tag}, state) do
    case state.active do
      %{request_id: ^request_id, task: %{pid: ^worker}} when caller == worker ->
        accept_frame(state, event)

      _ ->
        {:reply, {:error, :stale_request}, state}
    end
  end

  def handle_call(message, _from, %{active: active} = state)
      when not is_nil(active) and
             (message in [:step, :start_stream, :reconcile_from_mock] or
                (is_tuple(message) and elem(message, 0) in [:command, :append_message])) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(message, _from, %{tool_active: active} = state)
      when not is_nil(active) and
             (message in [:step, :start_stream, :reconcile_from_mock] or
                (is_tuple(message) and elem(message, 0) in [:command, :append_message])) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:append_message, _role, _content}, _from, %{run: %{status: status}} = state)
      when status in @terminal do
    {:reply, {:error, {:not_editable, status}}, state}
  end

  def handle_call({:append_message, role, content}, _from, state) do
    result =
      if state.session_id do
        SessionStore.append(state.session_id, state.session.version, role, content)
      else
        Session.append(state.session, role, content)
      end

    case result do
      {:ok, session} ->
        next = %{state | session: session}
        {:reply, {:ok, snapshot_of(next)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:command, command}, _from, state) do
    case deadline_reason(state) do
      nil -> command_with_budget(state, command)
      reason -> reply_to_command(state, {:fail, reason})
    end
  end

  def handle_call(action, from, %{run: %{status: :running}} = state)
      when action in [:step, :start_stream] do
    cond do
      reason = deadline_reason(state) ->
        reject_start(state, action, reason)

      state.run.turn_count >= state.run.max_turns ->
        reject_start(state, action, :turn_budget_exceeded)

      true ->
        case begin_request(state, if(action == :step, do: from, else: nil)) do
          {:ok, next} ->
            if action == :step,
              do: {:noreply, next},
              else: {:reply, {:ok, next.active.request_id}, next}

          {:error, {:context_error, _reason} = reason} ->
            reject_start(state, action, reason)

          {:error, {:request_control, reason}} ->
            reject_start(state, action, reason)

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:step, from, %{run: %{status: :waiting_tool}} = state) do
    case deadline_reason(state) do
      nil -> execute_tool(state, from)
      reason -> reply_to_command(state, {:fail, reason})
    end
  end

  def handle_call(:step, _from, %{run: %{status: :blocked}} = state),
    do: {:reply, {:error, :reconciliation_required}, state}

  def handle_call(action, _from, state) when action in [:step, :start_stream],
    do: {:reply, {:error, {:not_runnable, state.run.status}}, state}

  def handle_call(:reconcile_from_mock, _from, %{run: %{status: :blocked}} = state) do
    case deadline_reason(state) do
      nil ->
        id = state.run.pending_operation_id

        operation = Map.fetch!(state.run.operations, id)

        if Catalog.mcp_tool?(operation.tool) do
          {:reply, {:error, :reconciliation_required}, state}
        else
          case Mock.lookup(state.mock, id) do
            {:ok, receipt} -> reply_to_command(state, {:reconcile, id, {:ok, receipt}})
            :not_found -> {:reply, {:error, :receipt_not_found}, state}
          end
        end

      reason ->
        reply_to_command(state, {:fail, reason})
    end
  end

  def handle_call(:reconcile_from_mock, _from, state),
    do: {:reply, {:error, :not_blocked}, state}

  @impl true
  def handle_info(
        {task_ref, {result, files}},
        %{tool_active: %{task: %{ref: task_ref}} = active} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    observe_finished(active[:observation], result_outcome(result), state)
    state = %{state | tool_active: nil, files: files}

    command =
      case deadline_reason(state) do
        nil -> {:tool_result, active.operation_id, result}
        reason -> {:fail, reason}
      end

    {:reply, reply, next} = reply_to_command(state, command)
    GenServer.reply(active.waiter, reply)
    {:noreply, next}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{tool_active: %{task: %{ref: task_ref}} = active} = state
      ) do
    observe_finished(active[:observation], :error, state)
    state = %{state | tool_active: nil}
    operation = Map.fetch!(state.run.operations, active.operation_id)

    command =
      if Catalog.mcp_tool?(operation.tool) do
        # Process death cannot establish whether the server observed tools/call.
        # Keep that uncertainty paired and require trusted evidence to continue.
        output = %{
          "type" => "mcp_unknown",
          "reason" => "tool_worker_exit",
          "detail" => inspect(reason, limit: 10, printable_limit: 512) |> String.slice(0, 512)
        }

        result = Result.wrap({:unknown, output}, operation.operation_id, operation.tool)
        {:tool_result, operation.operation_id, result}
      else
        {:fail, persistence_safe_failure(state, {:tool_worker_exit, reason})}
      end

    {:reply, reply, next} = reply_to_command(state, command)
    GenServer.reply(active.waiter, reply)
    {:noreply, next}
  end

  def handle_info({task_ref, result}, %{active: %{task: %{ref: task_ref}}} = state) do
    {:noreply, complete_request(state, result)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{active: %{task: %{ref: task_ref}}} = state
      ) do
    {:noreply,
     fail_request(state, deadline_reason(state) || {:provider_error, {:worker_exit, reason}})}
  end

  def handle_info({:model_timeout, request_id}, %{active: %{request_id: request_id}} = state) do
    # Check the monotonic deadline too: stale timer messages cannot fail a new request.
    case deadline_reason(state) do
      nil -> {:noreply, state}
      reason -> {:noreply, fail_request(state, reason)}
    end
  end

  def handle_info({:run_timeout, ref}, %{deadline_ref: ref} = state) do
    if state.run.status in @terminal do
      {:noreply, state}
    else
      {:noreply, fail_request(state, {:budget_exceeded, :run_timeout})}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if Map.get(state.subscribers, pid) == ref,
      do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}},
      else: {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{mock: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_late_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.active, do: observe_finished(state.active[:observation], :cancelled, state)
    if state.tool_active, do: observe_finished(state.tool_active[:observation], :unknown, state)
    stop_worker(state.active)
    stop_isolated_tool(state.tool_active)
    Process.cancel_timer(state.run_timer)
    if Process.alive?(state.mock), do: GenServer.stop(state.mock, :normal)
    :ok
  end

  defp begin_request(state, waiter) do
    permissions = context_permissions(state)

    with {:ok, built} <- build_context(state, permissions),
         {:ok, context_id} <- capture_context(state, permissions, built) do
      case deadline_reason(state) do
        nil -> {:ok, launch_request(state, waiter, built, context_id)}
        reason -> {:error, {:request_control, reason}}
      end
    end
  end

  defp launch_request(state, waiter, built, context_id) do
    request_id = make_ref()
    owner = self()
    context = built.context

    provider = state.provider
    deadline = now_ms() + state.budget.model_timeout_ms
    observation = observe_started(:model, state)

    task =
      Task.Supervisor.async(AgentSystemsLab.ProviderSupervisor, fn ->
        worker = self()

        emit = fn event ->
          GenServer.call(owner, {:stream_frame, request_id, worker, event}, :infinity)
        end

        Scripted.stream(context, provider, emit)
      end)

    timer =
      Process.send_after(self(), {:model_timeout, request_id}, state.budget.model_timeout_ms)

    active = %{
      request_id: request_id,
      task: task,
      waiter: waiter,
      timer: timer,
      deadline: deadline,
      prior_budget: state.budget,
      prior_stream: state.stream,
      prior_context: state.context,
      prior_context_id: state.context_id,
      assembler: Stream.new(),
      response: nil,
      seq: 0,
      observation: observation
    }

    next = %{
      state
      | active: active,
        context: built,
        context_id: context_id,
        budget: Budget.reset_request(state.budget),
        stream: %{
          active?: true,
          request_id: request_id,
          events: [],
          output_bytes: state.budget.output_bytes
        }
    }

    publish(next, :started)
  end

  defp accept_frame(state, event) do
    with nil <- deadline_reason(state),
         {:ok, budget} <- Budget.consume(state.budget, event) do
      case Stream.push(state.active.assembler, event) do
        {:ok, assembler} ->
          next = %{state | budget: budget, active: %{state.active | assembler: assembler}}
          {:reply, :ok, publish(next, event)}

        {:done, response, assembler} ->
          next = %{
            state
            | budget: budget,
              active: %{state.active | assembler: assembler, response: response}
          }

          {:reply, :ok, publish(next, event)}

        {:error, reason} ->
          next = fail_request(state, {:provider_error, {:invalid_stream, reason}})
          {:reply, {:error, reason}, next}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_request(state, reason)}
      reason -> {:reply, {:error, reason}, fail_request(state, reason)}
    end
  end

  defp complete_request(state, {:ok, provider}) do
    cond do
      reason = deadline_reason(state) ->
        fail_request(state, reason)

      is_nil(state.active.response) ->
        fail_request(state, {:provider_error, :incomplete_stream}, provider)

      true ->
        with :ok <-
               Gateway.validate_response(
                 state.active.response,
                 state.files,
                 state.isolation_policy,
                 state.mcp_policy
               ),
             :ok <- Budget.allow_response(state.budget, state.run, state.active.response) do
          commit_response(state, provider)
        else
          {:error, reason} -> fail_request(state, reason, provider)
        end
    end
  end

  defp complete_request(state, {:error, reason, provider}),
    do: fail_request(state, deadline_reason(state) || {:provider_error, reason}, provider)

  defp complete_request(state, other),
    do: fail_request(state, {:provider_error, {:invalid_result, other}})

  defp commit_response(state, provider) do
    attributes = %{
      context_id: state.context_id,
      run_id: state.run.run_id,
      input_seq: state.run.seq,
      event_seq: state.run.seq + 1,
      provider: "scripted.v1",
      input_sha256: Context.hash(state.context.context),
      response: state.active.response
    }

    with {:ok, recording} <- prepare_recording(state, attributes),
         {:ok, next} <-
           transition(state, {:model_response, state.active.response},
             model_result: Map.take(attributes, [:context_id, :provider, :response])
           ) do
      next = retain_recording(next, recording, attributes)
      finish_request(%{next | provider: provider}, {:ok, :snapshot})
    else
      {:error, {:stale_sequence, _expected, _actual} = reason} ->
        reject_request(state, reason)

      {:error, reason} ->
        fail_request(state, {:model_response_rejected, reason}, provider)
    end
  end

  defp prepare_recording(state, attributes) do
    case Recording.new(attributes) do
      {:error, {:invalid_recording_payload, _detail} = reason} when state.storage == :memory ->
        # Legacy memory Mock arguments may contain live terms. Preserve that
        # contract without pretending those values are inert, reusable records.
        {:ok, {:unavailable, reason}}

      result ->
        result
    end
  end

  defp retain_recording(state, {:unavailable, reason}, attributes) do
    error = Map.take(attributes, [:input_seq, :event_seq]) |> Map.put(:reason, reason)
    %{state | recording_errors: state.recording_errors ++ [error]}
  end

  defp retain_recording(state, recording, _attributes),
    do: %{state | recordings: state.recordings ++ [recording]}

  defp fail_request(state, reason, provider \\ nil) do
    reason = persistence_safe_failure(state, reason)

    case transition(state, {:fail, reason}) do
      {:ok, next} ->
        next = if provider, do: %{next | provider: provider}, else: next
        finish_request(next, {:ok, :snapshot})

      {:error, error} ->
        if state.active, do: reject_request(state, error), else: state
    end
  end

  # Automatic provider diagnostics may include process IDs, references or
  # exception structs. Those must never prevent the run_failed transition. User
  # commands retain strict Codec validation and are deliberately not normalized.
  defp persistence_safe_failure(%{storage: :postgres}, reason) do
    case Codec.encode(reason) do
      {:ok, _binary} ->
        reason

      {:error, codec_error} ->
        detail = inspect(reason, limit: 20, printable_limit: 512, structs: false)
        {:unpersistable_failure, codec_error, String.slice(detail, 0, 512)}
    end
  end

  defp persistence_safe_failure(_state, reason), do: reason

  defp command_with_budget(state, {:model_response, response} = command) do
    with {:ok, _validated, _events} <- RunKernel.dispatch(state.run, command),
         :ok <-
           Gateway.validate_response(
             response,
             state.files,
             state.isolation_policy,
             state.mcp_policy
           ),
         {:ok, budget} <-
           Budget.consume(Budget.reset_request(state.budget), {:complete, response}),
         :ok <- Budget.allow_response(budget, state.run, response) do
      case transition(state, command) do
        {:ok, next} ->
          next = %{
            next
            | budget: budget,
              stream: %{next.stream | output_bytes: budget.output_bytes}
          }

          next =
            if next.run.status in @terminal,
              do: finish_request(next, {:ok, :snapshot}),
              else: next

          {:reply, {:ok, snapshot_of(next)}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, {:budget_exceeded, _limit} = reason} -> reply_to_command(state, {:fail, reason})
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp command_with_budget(state, {kind, id, result} = command)
       when kind in [:tool_result, :reconcile] do
    # Replay preserves old opaque v1 facts, including names which later became
    # file tools. New runtime input must use the current correlation envelope.
    with {:ok, _validated, _events} <- RunKernel.dispatch(state.run, command),
         operation = Map.fetch!(state.run.operations, id),
         :ok <- require_current_result(operation, result) do
      reply_to_command(state, command)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp command_with_budget(state, command), do: reply_to_command(state, command)

  defp require_current_result(operation, result) do
    if Catalog.paired_tool?(operation.tool),
      do: Result.validate_required(result, operation.operation_id, operation.tool),
      else: :ok
  end

  defp reply_to_command(state, command) do
    case transition(state, command) do
      {:ok, next} ->
        next =
          if next.run.status in @terminal, do: finish_request(next, {:ok, :snapshot}), else: next

        {:reply, {:ok, snapshot_of(next)}, next}

      {:error, reason} ->
        next = if state.active, do: reject_request(state, reason), else: state
        {:reply, {:error, reason}, next}
    end
  end

  defp reject_start(state, :step, reason), do: reply_to_command(state, {:fail, reason})

  defp reject_start(state, :start_stream, reason) do
    case transition(state, {:fail, reason}) do
      {:ok, next} -> {:reply, {:error, reason}, finish_request(next, {:ok, :snapshot})}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  defp reject_request(state, reason) do
    budget = state.active.prior_budget
    stream = state.active.prior_stream
    context = state.active.prior_context
    context_id = state.active.prior_context_id
    next = finish_request(state, {:error, reason})
    %{next | budget: budget, stream: stream, context: context, context_id: context_id}
  end

  defp finish_request(state, reply) do
    outcome =
      cond do
        match?({:error, _}, reply) -> :error
        state.run.status == :blocked -> :unknown
        state.run.status in [:failed, :cancelled] -> state.run.status
        true -> :ok
      end

    if state.active, do: observe_finished(state.active[:observation], outcome, state)
    if state.tool_active, do: observe_finished(state.tool_active[:observation], :unknown, state)
    stop_worker(state.active)
    stop_isolated_tool(state.tool_active)
    state = if state.active, do: publish(state, {:finished, state.run.status}), else: state
    waiter = if state.active, do: state.active.waiter, else: nil
    next = %{state | active: nil, tool_active: nil, stream: %{state.stream | active?: false}}
    if next.run.status in @terminal, do: Process.cancel_timer(next.run_timer)

    if waiter do
      response = if reply == {:ok, :snapshot}, do: {:ok, snapshot_of(next)}, else: reply
      GenServer.reply(waiter, response)
    end

    if state.tool_active, do: GenServer.reply(state.tool_active.waiter, {:ok, snapshot_of(next)})

    next
  end

  defp stop_worker(nil), do: :ok

  defp stop_worker(active) do
    Process.cancel_timer(active.timer)
    Process.demonitor(active.task.ref, [:flush])
    if Process.alive?(active.task.pid), do: Process.exit(active.task.pid, :kill)
    :ok
  end

  defp stop_isolated_tool(nil), do: :ok

  defp stop_isolated_tool(active) do
    Task.shutdown(active.task, :brutal_kill)
    :ok
  end

  defp publish(state, event) do
    seq = state.active.seq + 1

    for {pid, _monitor} <- state.subscribers,
        do: send(pid, {:agent_stream, state.run.run_id, state.active.request_id, seq, event})

    events = Enum.take(state.stream.events ++ [{seq, event}], -@preview_limit)
    bytes = Map.get(state.budget, :output_bytes, 0)

    %{
      state
      | active: %{state.active | seq: seq},
        stream: %{state.stream | events: events, output_bytes: bytes}
    }
  end

  defp execute_tool(state, from) do
    with :ok <- ensure_current_tool_intent(state),
         nil <- deadline_reason(state) do
      execute_current_tool(state, from)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      reason -> reply_to_command(state, {:fail, reason})
    end
  end

  # This catches an already committed cancellation or other stale decision
  # before a mock effect. The read and external effect are not atomic: leases and
  # fencing are still required to close a concurrent check/effect race.
  defp ensure_current_tool_intent(%{storage: :postgres, run: run}) do
    case Storage.load(run.run_id) do
      {:ok, %{state: ^run}} -> :ok
      {:ok, %{state: current}} -> {:error, {:stale_sequence, run.seq, current.seq}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_current_tool_intent(_state), do: :ok

  defp execute_current_tool(state, from) do
    id = state.run.pending_operation_id
    operation = Map.fetch!(state.run.operations, id)
    observation = observe_started(:tool, state, id)

    execute = fn ->
      Gateway.execute(
        state.files,
        state.mock,
        operation,
        state.mock_response,
        state.isolation_policy,
        state.mcp_policy,
        deadline_monotonic_ms: state.deadline
      )
    end

    if Catalog.isolated_tool?(operation.tool) or Catalog.mcp_tool?(operation.tool) do
      task = Task.Supervisor.async(AgentSystemsLab.ProviderSupervisor, execute)

      {:noreply,
       %{
         state
         | tool_active: %{task: task, waiter: from, operation_id: id, observation: observation}
       }}
    else
      {result, files} = execute.()
      observe_finished(observation, result_outcome(result), state)
      reply_to_command(%{state | files: files}, {:tool_result, id, result})
    end
  end

  defp deadline_reason(%{run: %{status: status}}) when status in @terminal, do: nil

  defp deadline_reason(state) do
    cond do
      now_ms() >= state.deadline -> {:budget_exceeded, :run_timeout}
      state.active && now_ms() >= state.active.deadline -> {:budget_exceeded, :model_timeout}
      true -> nil
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Volatile observations never enter Kernel history or provider input. The
  # facade is best effort; this outer boundary also isolates future adapters.
  defp observe_created(run, :memory) do
    Observability.emit(
      :run_created,
      %{
        run_id: run.run_id,
        seq: run.seq,
        span_id: AgentSystemsLab.Observability.Context.span_id(:run, run.run_id)
      },
      %{},
      phase: :observed,
      status: run.status
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe_created(_run, _storage), do: :ok

  defp observe_started(kind, state, operation_id \\ nil) do
    attempt_id = Ecto.UUID.generate()

    refs = %{
      run_id: state.run.run_id,
      seq: state.run.seq,
      turn_id: state.run.turn_count,
      attempt_id: attempt_id,
      operation_id: operation_id,
      span_id: AgentSystemsLab.Observability.Context.span_id(kind, attempt_id),
      parent_span_id: AgentSystemsLab.Observability.Context.span_id(:run, state.run.run_id)
    }

    name = if kind == :model, do: :model_started, else: :tool_started
    Observability.emit(name, refs, %{}, phase: :observed, outcome: :started)
    %{kind: kind, refs: refs, start_ms: now_ms()}
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp observe_finished(nil, _, _), do: :ok

  defp observe_finished(token, outcome, state) do
    name = if token.kind == :model, do: :model_stopped, else: :tool_stopped

    Observability.emit(name, token.refs, %{duration_ms: max(0, now_ms() - token.start_ms)},
      phase: :observed,
      outcome: outcome,
      status: state.run.status
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp result_outcome({:unknown, _}), do: :unknown
  defp result_outcome({:error, _}), do: :error
  defp result_outcome(_), do: :ok

  defp initialize_files(opts) do
    case Keyword.fetch(opts, :workspace) do
      :error -> {:ok, nil}
      {:ok, root} -> Files.new(root)
    end
  end

  defp initialize_isolation(opts) do
    policy = Keyword.get(opts, :isolation_policy)

    if is_nil(policy) do
      {:ok, nil}
    else
      with :ok <- AgentSystemsLab.Isolation.Policy.validate(policy), do: {:ok, policy}
    end
  end

  defp initialize_mcp(opts) do
    case Keyword.get(opts, :mcp_policy) do
      nil -> {:ok, nil}
      policy -> with :ok <- AgentSystemsLab.MCP.Policy.validate(policy), do: {:ok, policy}
    end
  end

  defp initialize_context_options(opts) do
    context_options = Keyword.get(opts, :context_options, [])

    with true <- length(Keyword.get_values(opts, :context_options)) <= 1,
         :ok <- Context.validate_options(context_options) do
      {:ok, context_options}
    else
      false -> {:error, :invalid_context_options}
      {:error, _reason} = error -> error
    end
  end

  defp initialize_session(opts) do
    cond do
      length(Keyword.get_values(opts, :session)) > 1 or
          length(Keyword.get_values(opts, :session_id)) > 1 ->
        {:error, :invalid_session_options}

      Keyword.has_key?(opts, :session) and Keyword.has_key?(opts, :session_id) ->
        {:error, :conflicting_session_options}

      Keyword.has_key?(opts, :session_id) ->
        if Keyword.get(opts, :storage, :memory) == :postgres do
          with {:ok, session} <- SessionStore.load(opts[:session_id]),
               do: {:ok, session, opts[:session_id]}
        else
          {:error, :session_requires_postgres}
        end

      Keyword.has_key?(opts, :session) ->
        with :ok <- Session.validate(opts[:session]), do: {:ok, opts[:session], nil}

      true ->
        with {:ok, session} <- Session.new("run:" <> Context.hash(opts[:run_id])),
             do: {:ok, session, nil}
    end
  end

  defp context_permissions(state) do
    schemas =
      Catalog.schemas(
        not is_nil(state.files),
        not is_nil(state.isolation_policy),
        state.mcp_policy
      )

    workspace = if state.files, do: state.files.workspace

    %{
      available_tools: schemas,
      allowed_tool_names: Enum.map(schemas, & &1["name"]),
      workspace_root: if(workspace, do: workspace.root),
      filesystem: %{
        enabled: not is_nil(workspace),
        max_file_bytes: if(workspace, do: workspace.max_file_bytes, else: Workspace.max_bytes()),
        max_patch_edits: 32,
        blocked_components: Workspace.blocked_components(),
        blocked_components_casefold: true
      },
      shell: false,
      network: false,
      budget:
        state.budget
        |> Map.take([
          :max_output_bytes,
          :max_stream_events,
          :model_timeout_ms,
          :run_timeout_ms,
          :max_tool_calls
        ])
        |> Map.put(:max_turns, state.run.max_turns)
    }
    |> Map.merge(
      if state.isolation_policy,
        do: %{isolation: AgentSystemsLab.Isolation.Policy.to_map(state.isolation_policy)},
        else: %{}
    )
    |> Map.merge(
      if state.mcp_policy,
        do: %{mcp: AgentSystemsLab.MCP.Policy.to_map(state.mcp_policy)},
        else: %{}
    )
  end

  defp build_context(state, permissions) do
    case Context.build(state.session, state.run, permissions, state.context_options) do
      {:ok, built} -> {:ok, built}
      {:error, reason} -> {:error, {:context_error, reason}}
    end
  end

  defp capture_context(%{storage: :memory}, _permissions, _built), do: {:ok, nil}

  defp capture_context(state, permissions, built) do
    case ContextStore.capture(state.run, state.session, permissions, built,
           session_id: state.session_id,
           context_options: state.context_options
         ) do
      {:ok, captured} -> {:ok, captured.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition(state, command, opts \\ [])

  defp transition(%{storage: :postgres} = state, command, opts) do
    case Storage.dispatch(state.run.run_id, state.run.seq, command, opts) do
      {:ok, saved} -> {:ok, %{state | run: saved.state, events: saved.events}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition(%{storage: :memory} = state, command, _opts) do
    case RunKernel.dispatch(state.run, command) do
      {:ok, run, events} -> {:ok, %{state | run: run, events: state.events ++ events}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_run(opts) do
    kernel_opts = [max_turns: Keyword.get(opts, :max_turns, 4)]

    case Keyword.get(opts, :storage, :memory) do
      :memory ->
        with {:ok, state} <- RunKernel.new(opts[:run_id], kernel_opts),
             do: RunKernel.dispatch(state, {:start, opts[:input]})

      :postgres ->
        case Storage.create_run(opts[:run_id], opts[:input], kernel_opts) do
          {:ok, saved} -> {:ok, saved.state, saved.events}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp snapshot_of(state) do
    %{
      state: state.run,
      events: state.events,
      provider: state.provider,
      tool_stats: Mock.stats(state.mock),
      file_stats: if(state.files, do: Files.stats(state.files), else: nil),
      session: state.session,
      context: state.context,
      context_id: state.context_id,
      recordings: state.recordings,
      recording_errors: state.recording_errors,
      stream: state.stream,
      budget: state.budget
    }
  end
end
