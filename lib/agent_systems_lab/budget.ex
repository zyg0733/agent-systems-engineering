defmodule AgentSystemsLab.Budget do
  @moduledoc """
  Volatile control limits for one RunServer process.

  Output bytes accumulate across model requests; stream event counts reset for
  each request. Deltas count their actual binary bytes. Legacy complete tool
  responses count the ETF-encoded argument map so existing atom keys and values
  keep their meaning. Tool identifiers and names also count their binary bytes.
  These are resource limits, not model token or money usage.
  Clock deadlines are enforced by RunServer using the two timeout policies.

  Counters and deadlines are not a durable checkpoint. Kernel `max_turns` remains
  separately persisted in the run and event history.
  """

  defstruct max_output_bytes: 65_536,
            max_stream_events: 4_096,
            model_timeout_ms: 5_000,
            run_timeout_ms: 60_000,
            max_tool_calls: 16,
            output_bytes: 0,
            events: 0

  @policies [
    :max_output_bytes,
    :max_stream_events,
    :model_timeout_ms,
    :run_timeout_ms,
    :max_tool_calls
  ]

  @doc "Reads budget policies from RunServer options, rejecting invalid explicit values."
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(@policies, {:ok, %__MODULE__{}}, fn name, {:ok, budget} ->
        value = Keyword.get(opts, name, Map.fetch!(budget, name))
        minimum = if name in [:max_output_bytes, :max_tool_calls], do: 0, else: 1

        if length(Keyword.get_values(opts, name)) <= 1 and is_integer(value) and
             value >= minimum do
          {:cont, {:ok, Map.put(budget, name, value)}}
        else
          {:halt, {:error, {:invalid_budget, name, value}}}
        end
      end)
    else
      {:error, {:invalid_options, opts}}
    end
  end

  def new(opts), do: {:error, {:invalid_options, opts}}

  @doc "Starts a request without resetting the run's cumulative byte count."
  def reset_request(%__MODULE__{} = budget), do: %{budget | events: 0}

  @doc "Checks one frame before accepting it. Rejection leaves the caller's budget unchanged."
  def consume(%__MODULE__{} = budget, event) do
    bytes = budget.output_bytes + frame_bytes(event)
    events = budget.events + 1

    cond do
      events > budget.max_stream_events -> {:error, {:budget_exceeded, :stream_events}}
      bytes > budget.max_output_bytes -> {:error, {:budget_exceeded, :output_bytes}}
      true -> {:ok, %{budget | events: events, output_bytes: bytes}}
    end
  end

  @doc "Allows a tool proposal only while the run has room for another operation."
  def allow_response(%__MODULE__{} = budget, state, {:call, _call}) do
    if map_size(state.operations) < budget.max_tool_calls,
      do: :ok,
      else: {:error, {:budget_exceeded, :tool_calls}}
  end

  def allow_response(%__MODULE__{}, _state, _response), do: :ok

  defp frame_bytes({kind, bytes})
       when kind in [:text_delta, :arguments_delta] and is_binary(bytes),
       do: byte_size(bytes)

  defp frame_bytes({:complete, {:final, text}}) when is_binary(text), do: byte_size(text)

  defp frame_bytes({:tool_start, %{operation_id: id, tool: tool}})
       when is_binary(id) and is_binary(tool),
       do: byte_size(id) + byte_size(tool)

  defp frame_bytes({:complete, {:call, %{operation_id: id, tool: tool, arguments: arguments}}})
       when is_binary(id) and is_binary(tool) and is_map(arguments),
       do: byte_size(id) + byte_size(tool) + byte_size(:erlang.term_to_binary(arguments))

  defp frame_bytes(_event), do: 0
end
