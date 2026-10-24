defmodule AgentSystemsLab.Provider do
  @moduledoc """
  The boundary between the runtime and a model provider.

  Providers receive a context map and their own explicit state. The original
  `respond/2` returns a complete response. `stream/3` delivers frames through a
  synchronous callback; it must wait for each callback result before producing
  another frame. This gives the runtime backpressure and a cancellation boundary.

  A `:done` frame completes assembly, not a runtime transaction. A runtime must
  wait for the provider callback to return successfully before accepting the
  assembled response. A provider can still fail after emitting `:done`.
  """

  @type context :: map()
  @type tool_call :: %{
          required(:operation_id) => String.t(),
          required(:tool) => String.t(),
          required(:arguments) => map()
        }
  @type response :: {:call, tool_call()} | {:final, String.t()}
  @type stream_event ::
          {:text_delta, binary()}
          | {:tool_start, %{required(:operation_id) => String.t(), required(:tool) => String.t()}}
          | {:arguments_delta, binary()}
          | :done
          | {:complete, response()}
  @type emit :: (stream_event() -> :ok | {:error, term()})

  @callback respond(context(), state :: term()) ::
              {:ok, response(), next_state :: term()}
              | {:error, reason :: term(), next_state :: term()}

  @callback stream(context(), state :: term(), emit()) ::
              {:ok, next_state :: term()}
              | {:error, reason :: term(), next_state :: term()}

  @doc "Checks the complete response contract without changing argument key types."
  @spec valid_response?(term()) :: boolean()
  def valid_response?({:call, %{operation_id: id, tool: tool, arguments: arguments} = call})
      when map_size(call) == 3 and is_binary(id) and byte_size(id) > 0 and is_binary(tool) and
             byte_size(tool) > 0 and is_map(arguments),
      do: true

  def valid_response?({:final, answer}) when is_binary(answer), do: true
  def valid_response?(_response), do: false
end
