defmodule AgentSystemsLab.Providers.Recorded do
  @moduledoc """
  Explicit reuse of recorded complete outputs for exactly matching inputs.

  This adapter performs no model request, kernel dispatch or tool execution.
  History reconstruction does not need it. A mismatching next input never skips
  ahead or advances the cursor. Streaming emits one complete response and obeys
  the consumer's stop result, preserving arbitrary argument maps exactly.
  """

  @behaviour AgentSystemsLab.Provider

  alias AgentSystemsLab.Recording

  @enforce_keys [:records]
  defstruct records: [], cursor: 0, requests: []

  def new(records) when is_list(records) do
    case Enum.find_index(records, &(Recording.validate(&1) !== :ok)) do
      nil -> {:ok, %__MODULE__{records: records}}
      index -> {:error, {:invalid_recording, index}}
    end
  end

  def new(_records), do: {:error, :invalid_recordings}

  @impl true
  def respond(context, %__MODULE__{} = state) when is_map(context) do
    with {:ok, record} <- next_record(state),
         :ok <- Recording.verify(record, context) do
      next = %{state | cursor: state.cursor + 1, requests: state.requests ++ [context]}
      {:ok, record.response, next}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def respond(_context, %__MODULE__{} = state), do: {:error, :invalid_context, state}

  @impl true
  def stream(context, %__MODULE__{} = state, emit) when is_function(emit, 1) do
    case respond(context, state) do
      {:ok, response, next} ->
        case emit.({:complete, response}) do
          :ok -> {:ok, next}
          {:error, reason} -> {:error, reason, next}
          result -> {:error, {:invalid_emit_result, result}, next}
        end

      {:error, reason, unchanged} ->
        {:error, reason, unchanged}
    end
  end

  def stream(_context, %__MODULE__{} = state, _emit), do: {:error, :invalid_emit, state}

  defp next_record(state) do
    case Enum.fetch(state.records, state.cursor) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :recordings_exhausted}
    end
  end
end
