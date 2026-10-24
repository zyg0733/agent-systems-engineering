defmodule AgentSystemsLab.Stream do
  @moduledoc """
  A pure assembler for one model response.

  Text deltas and tool arguments remain provisional until an explicit `:done`.
  Tool arguments are parsed and final text is validated as UTF-8 only at that
  boundary, so JSON and UTF-8 may be split across frames. JSON object keys stay
  strings; the assembler never creates atoms from model output. Mixing text and a
  tool call, multiple tool calls, and frames after completion are protocol errors.

  `{:complete, response}` adapts the original provider API without a JSON round
  trip and retains its original binary text contract. It is accepted only as the
  first and only frame. The runtime should call
  `finish/1` after the provider returns to reject an incomplete stream, and should
  commit a response only if both assembly and the provider callback succeeded.
  """

  alias AgentSystemsLab.Provider

  defstruct phase: :empty, text: [], tool: nil, arguments: [], response: nil

  @opaque t :: %__MODULE__{
            phase: :empty | :text | :tool | :done,
            text: [binary()],
            tool: map() | nil,
            arguments: [binary()],
            response: Provider.response() | nil
          }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec push(t(), term()) ::
          {:ok, t()} | {:done, Provider.response(), t()} | {:error, term()}
  def push(%__MODULE__{phase: :done}, _event), do: {:error, :stream_already_complete}

  def push(%__MODULE__{phase: :empty} = state, {:complete, response}) do
    if Provider.valid_response?(response),
      do: complete(state, response),
      else: {:error, {:invalid_complete_response, response}}
  end

  def push(%__MODULE__{}, {:complete, _response}), do: {:error, :complete_after_partial}

  def push(%__MODULE__{phase: phase} = state, {:text_delta, text})
      when phase in [:empty, :text] and is_binary(text),
      do: {:ok, %{state | phase: :text, text: [text | state.text]}}

  def push(%__MODULE__{phase: :tool}, {:text_delta, text}) when is_binary(text),
    do: {:error, :mixed_response}

  def push(%__MODULE__{phase: :empty} = state, {:tool_start, tool}) do
    if valid_tool_start?(tool),
      do: {:ok, %{state | phase: :tool, tool: tool}},
      else: {:error, {:invalid_tool_start, tool}}
  end

  def push(%__MODULE__{phase: :text}, {:tool_start, _tool}),
    do: {:error, :mixed_response}

  def push(%__MODULE__{phase: :tool}, {:tool_start, _tool}),
    do: {:error, :multiple_tool_calls}

  def push(%__MODULE__{phase: :tool} = state, {:arguments_delta, arguments})
      when is_binary(arguments),
      do: {:ok, %{state | arguments: [arguments | state.arguments]}}

  def push(%__MODULE__{phase: phase}, {:arguments_delta, arguments})
      when phase in [:empty, :text] and is_binary(arguments),
      do: {:error, :arguments_before_tool}

  def push(%__MODULE__{phase: phase} = state, :done) when phase in [:empty, :text] do
    text = join(state.text)

    if String.valid?(text),
      do: complete(state, {:final, text}),
      else: {:error, :invalid_text_utf8}
  end

  def push(%__MODULE__{phase: :tool} = state, :done) do
    case JSON.decode(join(state.arguments)) do
      {:ok, arguments} when is_map(arguments) ->
        complete(state, {:call, Map.put(state.tool, :arguments, arguments)})

      {:ok, _arguments} ->
        {:error, :arguments_must_be_object}

      {:error, reason} ->
        {:error, {:invalid_arguments_json, reason}}
    end
  end

  def push(%__MODULE__{}, event), do: {:error, {:invalid_stream_event, event}}

  @doc "Checks that a provider finished the response instead of ending mid-stream."
  @spec finish(t()) :: {:ok, Provider.response()} | {:error, :incomplete_stream}
  def finish(%__MODULE__{phase: :done, response: response}), do: {:ok, response}
  def finish(%__MODULE__{}), do: {:error, :incomplete_stream}

  defp valid_tool_start?(%{operation_id: id, tool: tool} = start)
       when map_size(start) == 2 and is_binary(id) and byte_size(id) > 0 and is_binary(tool) and
              byte_size(tool) > 0,
       do: true

  defp valid_tool_start?(_start), do: false

  defp complete(state, response),
    do: {:done, response, %{state | phase: :done, response: response}}

  defp join(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
