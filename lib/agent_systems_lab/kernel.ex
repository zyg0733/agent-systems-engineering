defmodule AgentSystemsLab.Kernel do
  @moduledoc """
  A deterministic, event-driven state machine for one serial agent run.

  Commands express intent; accepted commands produce a new state and one event.
  Rejected commands change nothing and produce no events. Both dispatch and replay
  use the same transition rules. No process, clock, random value, model call, or
  tool execution lives in this module.

  A model response consumes one turn, including a final answer. Tool results and
  reconciliation do not consume turns. A tool's `:error` result lets the model
  continue; `:unknown` blocks the run until an explicit reconciliation. Neither
  retrying a tool nor assuming a timeout means failure is safe by default.

  ## Example

      iex> alias AgentSystemsLab.Kernel
      iex> {:ok, state} = Kernel.new("example")
      iex> {:ok, state, [started]} = Kernel.dispatch(state, {:start, "Say hello"})
      iex> {:ok, state, [finished]} = Kernel.dispatch(state, {:model_response, {:final, "Hello"}})
      iex> state.status
      :succeeded
      iex> Kernel.rebuild("example", [started, finished]) == {:ok, state}
      true

  """

  alias AgentSystemsLab.Kernel.{Event, State}
  alias AgentSystemsLab.Tools.Result

  @terminal_statuses [:succeeded, :failed, :cancelled]
  @statuses [:queued, :running, :waiting_tool, :blocked] ++ @terminal_statuses
  @operation_statuses [:pending, :ok, :error, :unknown]

  @type result :: {:ok, term()} | {:error, term()} | {:unknown, term()}
  @type command ::
          {:start, String.t()}
          | {:model_response,
             {:call, %{operation_id: String.t(), tool: String.t(), arguments: map()}}
             | {:final, String.t()}}
          | {:tool_result, String.t(), result()}
          | {:reconcile, String.t(), {:ok, term()} | {:error, term()}}
          | {:fail, term()}
          | {:cancel, term()}

  @spec new(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def new(run_id, opts \\ []) do
    with :ok <- validate_run_id(run_id),
         {:ok, max_turns} <- read_options(opts) do
      {:ok, %State{run_id: run_id, max_turns: max_turns}}
    end
  end

  @spec dispatch(State.t(), command()) ::
          {:ok, State.t(), [Event.t()]} | {:error, term()}
  def dispatch(%State{} = state, command) do
    with :ok <- validate_state(state),
         {:ok, type, data} <- prepare(state, command) do
      event = %Event{run_id: state.run_id, seq: state.seq + 1, type: type, data: data}

      with {:ok, next_state} <- apply_event(state, event) do
        {:ok, next_state, [event]}
      end
    end
  end

  def dispatch(state, _command), do: {:error, {:invalid_state, state}}

  @spec apply_event(State.t(), Event.t()) :: {:ok, State.t()} | {:error, term()}
  def apply_event(%State{} = state, %Event{} = event) do
    with :ok <- validate_state(state),
         :ok <- validate_envelope(state, event),
         {:ok, command} <- command_from_event(event),
         {:ok, type, data} <- prepare(state, command),
         :ok <- validate_canonical_data(event, type, data) do
      next_state = evolve(state, event)

      with :ok <- validate_state(next_state), do: {:ok, next_state}
    end
  end

  def apply_event(%State{}, event), do: {:error, {:invalid_event, event}}
  def apply_event(state, _event), do: {:error, {:invalid_state, state}}

  @doc """
  Rebuilds from an ordered history using the same run options as dispatch.

  The turn budget is run configuration, so callers must provide the original
  `max_turns` when it differs from the default. Replay rejects mismatched run IDs,
  gaps, duplicates, unsupported schemas, malformed payloads, and illegal transitions.
  """
  @spec rebuild(String.t(), [Event.t()], keyword()) :: {:ok, State.t()} | {:error, term()}
  def rebuild(run_id, events, opts \\ []) do
    with {:ok, initial_state} <- new(run_id, opts),
         :ok <- validate_history(events) do
      Enum.reduce_while(events, {:ok, initial_state}, fn event, {:ok, state} ->
        case apply_event(state, event) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp prepare(%State{status: status}, _command) when status in @terminal_statuses,
    do: {:error, {:terminal_run, status}}

  defp prepare(%State{status: :queued}, {:start, input}) when is_binary(input),
    do: {:ok, :run_started, %{input: input}}

  defp prepare(_state, {:start, input}) when not is_binary(input),
    do: {:error, {:invalid_input, input}}

  defp prepare(state, {:start, _input}), do: invalid_transition(state, :start)

  defp prepare(%State{status: :running} = state, {:model_response, response}) do
    if state.turn_count < state.max_turns do
      prepare_model_response(state, response)
    else
      {:error, {:turn_budget_exhausted, state.max_turns}}
    end
  end

  defp prepare(state, {:model_response, _response}),
    do: invalid_transition(state, :model_response)

  defp prepare(%State{status: :waiting_tool} = state, {:tool_result, operation_id, result}) do
    with :ok <- validate_pending_operation(state, operation_id),
         :ok <- validate_result(result, [:ok, :error, :unknown]),
         :ok <- validate_result_pair(state, operation_id, result) do
      {:ok, :tool_result_recorded, %{operation_id: operation_id, result: result}}
    end
  end

  defp prepare(state, {:tool_result, _operation_id, _result}),
    do: invalid_transition(state, :tool_result)

  defp prepare(%State{status: :blocked} = state, {:reconcile, operation_id, result}) do
    with :ok <- validate_pending_operation(state, operation_id),
         :ok <- validate_result(result, [:ok, :error]),
         :ok <- validate_result_pair(state, operation_id, result) do
      {:ok, :tool_reconciled, %{operation_id: operation_id, result: result}}
    end
  end

  defp prepare(state, {:reconcile, _operation_id, _result}),
    do: invalid_transition(state, :reconcile)

  defp prepare(_state, {:fail, reason}), do: {:ok, :run_failed, %{reason: reason}}
  defp prepare(_state, {:cancel, reason}), do: {:ok, :run_cancelled, %{reason: reason}}
  defp prepare(_state, command), do: {:error, {:invalid_command, command}}

  defp prepare_model_response(state, {:call, call}) do
    case call do
      %{operation_id: operation_id, tool: tool, arguments: arguments}
      when map_size(call) == 3 and is_binary(operation_id) and byte_size(operation_id) > 0 and
             is_binary(tool) and byte_size(tool) > 0 and is_map(arguments) ->
        if Map.has_key?(state.operations, operation_id) do
          {:error, {:duplicate_operation_id, operation_id}}
        else
          {:ok, :tool_requested, call}
        end

      _ ->
        {:error, {:invalid_tool_call, call}}
    end
  end

  defp prepare_model_response(_state, {:final, output}) when is_binary(output),
    do: {:ok, :run_succeeded, %{output: output}}

  defp prepare_model_response(_state, response),
    do: {:error, {:invalid_model_response, response}}

  defp command_from_event(%Event{type: :run_started, data: %{input: input} = data})
       when map_size(data) == 1,
       do: {:ok, {:start, input}}

  defp command_from_event(%Event{type: :tool_requested, data: data}) when is_map(data),
    do: {:ok, {:model_response, {:call, data}}}

  defp command_from_event(%Event{
         type: :tool_result_recorded,
         data: %{operation_id: operation_id, result: result} = data
       })
       when map_size(data) == 2,
       do: {:ok, {:tool_result, operation_id, result}}

  defp command_from_event(%Event{
         type: :tool_reconciled,
         data: %{operation_id: operation_id, result: result} = data
       })
       when map_size(data) == 2,
       do: {:ok, {:reconcile, operation_id, result}}

  defp command_from_event(%Event{type: :run_succeeded, data: %{output: output} = data})
       when map_size(data) == 1,
       do: {:ok, {:model_response, {:final, output}}}

  defp command_from_event(%Event{type: :run_failed, data: %{reason: reason} = data})
       when map_size(data) == 1,
       do: {:ok, {:fail, reason}}

  defp command_from_event(%Event{type: :run_cancelled, data: %{reason: reason} = data})
       when map_size(data) == 1,
       do: {:ok, {:cancel, reason}}

  defp command_from_event(%Event{type: type})
       when type in [
              :run_started,
              :tool_requested,
              :tool_result_recorded,
              :tool_reconciled,
              :run_succeeded,
              :run_failed,
              :run_cancelled
            ],
       do: {:error, {:invalid_event_data, type}}

  defp command_from_event(%Event{type: type}), do: {:error, {:unknown_event_type, type}}

  defp evolve(state, %Event{type: :run_started, data: %{input: input}, seq: seq}),
    do: %{state | status: :running, input: input, seq: seq}

  defp evolve(state, %Event{type: :tool_requested, data: call, seq: seq}) do
    operation = Map.merge(call, %{status: :pending, result: nil})

    %{
      state
      | status: :waiting_tool,
        seq: seq,
        turn_count: state.turn_count + 1,
        operations: Map.put(state.operations, call.operation_id, operation),
        pending_operation_id: call.operation_id
    }
  end

  defp evolve(state, %Event{type: type, data: data, seq: seq})
       when type in [:tool_result_recorded, :tool_reconciled] do
    {outcome, value} = data.result
    operation = Map.fetch!(state.operations, data.operation_id)
    operation = %{operation | status: outcome, result: value}

    %{
      state
      | status: if(outcome == :unknown, do: :blocked, else: :running),
        seq: seq,
        operations: Map.put(state.operations, data.operation_id, operation),
        pending_operation_id: if(outcome == :unknown, do: data.operation_id, else: nil)
    }
  end

  defp evolve(state, %Event{type: :run_succeeded, data: %{output: output}, seq: seq}),
    do: %{
      state
      | status: :succeeded,
        seq: seq,
        turn_count: state.turn_count + 1,
        output: output
    }

  defp evolve(state, %Event{type: :run_failed, data: %{reason: reason}, seq: seq}),
    do: %{state | status: :failed, seq: seq, terminal_reason: reason}

  defp evolve(state, %Event{type: :run_cancelled, data: %{reason: reason}, seq: seq}),
    do: %{state | status: :cancelled, seq: seq, terminal_reason: reason}

  defp validate_envelope(state, event) do
    cond do
      not valid_struct_shape?(event, Event) ->
        {:error, {:invalid_event, event}}

      event.schema_version !== 1 ->
        {:error, {:unsupported_schema_version, event.schema_version}}

      event.run_id !== state.run_id ->
        {:error, {:run_id_mismatch, state.run_id, event.run_id}}

      event.seq !== state.seq + 1 ->
        {:error, {:invalid_event_sequence, state.seq + 1, event.seq}}

      not is_map(event.data) ->
        {:error, {:invalid_event_data, event.type}}

      true ->
        :ok
    end
  end

  defp validate_canonical_data(event, type, data) do
    if event.type === type and event.data === data,
      do: :ok,
      else: {:error, {:invalid_event_data, event.type}}
  end

  defp validate_run_id(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: :ok
  defp validate_run_id(run_id), do: {:error, {:invalid_run_id, run_id}}

  defp read_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _value} -> key == :max_turns end) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      max_turns = Keyword.get(opts, :max_turns, 4)

      if is_integer(max_turns) and max_turns > 0,
        do: {:ok, max_turns},
        else: {:error, {:invalid_max_turns, max_turns}}
    else
      {:error, {:invalid_options, opts}}
    end
  end

  defp read_options(opts), do: {:error, {:invalid_options, opts}}

  defp validate_history(events) when is_list(events), do: :ok
  defp validate_history(events), do: {:error, {:invalid_history, events}}

  defp validate_pending_operation(state, operation_id) do
    if operation_id === state.pending_operation_id,
      do: :ok,
      else: {:error, {:unexpected_operation_id, state.pending_operation_id, operation_id}}
  end

  defp validate_result({outcome, _value} = result, outcomes) do
    if outcome in outcomes, do: :ok, else: {:error, {:invalid_tool_result, result}}
  end

  defp validate_result(result, _outcomes), do: {:error, {:invalid_tool_result, result}}

  defp validate_result_pair(state, operation_id, result) do
    operation = Map.fetch!(state.operations, operation_id)
    Result.validate(result, operation_id, operation.tool)
  end

  defp invalid_transition(state, command),
    do: {:error, {:invalid_transition, state.status, command}}

  defp validate_state(state) do
    cond do
      not valid_struct_shape?(state, State) -> invalid_state(state)
      validate_run_id(state.run_id) != :ok -> invalid_state(state)
      state.status not in @statuses -> invalid_state(state)
      not is_integer(state.seq) or state.seq < 0 -> invalid_state(state)
      not is_integer(state.max_turns) or state.max_turns < 1 -> invalid_state(state)
      not is_integer(state.turn_count) or state.turn_count < 0 -> invalid_state(state)
      state.turn_count > state.max_turns or state.turn_count > state.seq -> invalid_state(state)
      not valid_operations?(state.operations, state.pending_operation_id) -> invalid_state(state)
      not valid_status_fields?(state) -> invalid_state(state)
      true -> :ok
    end
  end

  defp valid_operations?(operations, pending_id) when is_map(operations) do
    valid_values? =
      Enum.all?(operations, fn
        {id, %{operation_id: id, tool: tool, arguments: arguments, status: status} = op}
        when is_binary(id) and byte_size(id) > 0 and is_binary(tool) and byte_size(tool) > 0 and
               is_map(arguments) and status in @operation_statuses and map_size(op) == 5 ->
          Map.has_key?(op, :result) and
            (status == :pending or Result.validate({status, op.result}, id, tool) == :ok)

        _ ->
          false
      end)

    unresolved =
      for {id, %{status: status}} <- operations, status in [:pending, :unknown], do: id

    valid_values? and
      case {pending_id, unresolved} do
        {nil, []} -> true
        {id, [id]} when is_binary(id) -> true
        _ -> false
      end
  end

  defp valid_operations?(_operations, _pending_id), do: false

  defp valid_status_fields?(%State{status: :queued} = state) do
    state.seq == 0 and state.turn_count == 0 and is_nil(state.input) and
      is_nil(state.output) and state.operations == %{} and is_nil(state.pending_operation_id) and
      is_nil(state.terminal_reason)
  end

  defp valid_status_fields?(%State{status: :running} = state),
    do: active_fields?(state) and is_nil(state.pending_operation_id)

  defp valid_status_fields?(%State{status: :waiting_tool} = state),
    do: active_fields?(state) and pending_status?(state, :pending)

  defp valid_status_fields?(%State{status: :blocked} = state),
    do: active_fields?(state) and pending_status?(state, :unknown)

  defp valid_status_fields?(%State{status: :succeeded} = state),
    do:
      is_binary(state.input) and is_binary(state.output) and is_nil(state.pending_operation_id) and
        is_nil(state.terminal_reason)

  defp valid_status_fields?(%State{status: status} = state) when status in [:failed, :cancelled],
    do: (is_nil(state.input) or is_binary(state.input)) and is_nil(state.output)

  defp active_fields?(state),
    do: is_binary(state.input) and is_nil(state.output) and is_nil(state.terminal_reason)

  defp pending_status?(state, expected_status) do
    case Map.get(state.operations, state.pending_operation_id) do
      %{status: ^expected_status} -> true
      _ -> false
    end
  end

  defp valid_struct_shape?(value, module),
    do: Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(module.__struct__()))

  defp invalid_state(state), do: {:error, {:invalid_state, state}}
end
