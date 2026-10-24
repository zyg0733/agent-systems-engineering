defmodule AgentSystemsLab.Providers.Scripted do
  @moduledoc """
  A deterministic provider backed by a validated list of responses or streams.

  Every consumed response records the context in `requests`, in call order.
  Exhaustion and invalid contexts do not consume a response or change the state.
  A scripted `{:error, reason}` is consumed just like a successful response.

  A `{:stream, frames}` entry emits its frames in order through `stream/3`. The
  constructor checks frame shapes, while the runtime's `AgentSystemsLab.Stream`
  assembler checks their ordering and completeness. This allows deliberately
  truncated and out-of-order scripts for failure exercises.

  The fixture controls `{:gate, owner_pid, ref}`, `{:sleep, milliseconds}`,
  `{:crash, reason}`, and `{:error, reason}` are never emitted as model frames.
  A gate sends `{:scripted_gate, ref, worker_pid}` to its owner, then waits for
  `{:release, ref}`. Use gates to coordinate tests without timing assumptions.
  Legacy complete responses emit one `{:complete, response}` frame, preserving
  argument maps exactly, including atom keys and other non-JSON values.

      iex> alias AgentSystemsLab.Providers.Scripted
      iex> {:ok, provider} = Scripted.new([{:final, "done"}])
      iex> {:ok, {:final, "done"}, next} = Scripted.respond(%{messages: []}, provider)
      iex> next.cursor
      1
  """

  @behaviour AgentSystemsLab.Provider

  alias AgentSystemsLab.Provider
  alias AgentSystemsLab.Stream

  @enforce_keys [:responses]
  defstruct responses: [], cursor: 0, requests: []

  @type frame ::
          Provider.stream_event()
          | {:gate, pid(), reference()}
          | {:sleep, non_neg_integer()}
          | {:crash, term()}
          | {:error, term()}
  @type script_entry :: Provider.response() | {:error, term()} | {:stream, [frame()]}
  @type t :: %__MODULE__{
          responses: [script_entry()],
          cursor: non_neg_integer(),
          requests: [map()]
        }

  @doc "Validates the complete script before any response can be consumed."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(responses) when is_list(responses) do
    case Enum.find_index(responses, &(not valid_entry?(&1))) do
      nil -> {:ok, %__MODULE__{responses: responses}}
      index -> {:error, {:invalid_response, index, Enum.at(responses, index)}}
    end
  end

  def new(_responses), do: {:error, :invalid_script}

  @impl true
  @spec respond(map(), t()) ::
          {:ok, AgentSystemsLab.Provider.response(), t()} | {:error, term(), t()}
  def respond(context, %__MODULE__{} = state) do
    case take(context, state) do
      {:ok, {:error, reason}, next} ->
        {:error, reason, next}

      {:ok, {:stream, frames}, next} ->
        case assemble(frames, Stream.new()) do
          {:ok, response} -> {:ok, response, next}
          {:error, reason} -> {:error, reason, next}
        end

      {:ok, response, next} ->
        {:ok, response, next}

      {:error, reason, next} ->
        {:error, reason, next}
    end
  end

  @impl true
  @spec stream(map(), t(), Provider.emit()) :: {:ok, t()} | {:error, term(), t()}
  def stream(context, %__MODULE__{} = state, emit) when is_function(emit, 1) do
    case take(context, state) do
      {:ok, {:error, reason}, next} ->
        {:error, reason, next}

      {:ok, {:stream, frames}, next} ->
        stream_result(emit_frames(frames, emit), next)

      {:ok, response, next} ->
        stream_result(emit_frame({:complete, response}, emit), next)

      {:error, reason, next} ->
        {:error, reason, next}
    end
  end

  def stream(_context, %__MODULE__{} = state, _emit), do: {:error, :invalid_emit, state}

  defp take(context, state) when is_map(context) do
    case Enum.fetch(state.responses, state.cursor) do
      {:ok, entry} ->
        next = %{state | cursor: state.cursor + 1, requests: state.requests ++ [context]}
        {:ok, entry, next}

      :error ->
        {:error, :script_exhausted, state}
    end
  end

  defp take(_context, state), do: {:error, :invalid_context, state}

  defp valid_entry?({:stream, frames}) when is_list(frames),
    do: Enum.all?(frames, &valid_frame?/1)

  defp valid_entry?({:error, _reason}), do: true
  defp valid_entry?(response), do: Provider.valid_response?(response)

  defp valid_frame?({:text_delta, text}) when is_binary(text), do: true
  defp valid_frame?({:arguments_delta, arguments}) when is_binary(arguments), do: true

  defp valid_frame?({:tool_start, %{operation_id: id, tool: tool} = start})
       when map_size(start) == 2 and is_binary(id) and is_binary(tool),
       do: true

  defp valid_frame?(:done), do: true
  defp valid_frame?({:gate, owner, ref}) when is_pid(owner) and is_reference(ref), do: true

  defp valid_frame?({:sleep, milliseconds}) when is_integer(milliseconds) and milliseconds >= 0,
    do: true

  defp valid_frame?({:crash, _reason}), do: true
  defp valid_frame?({:error, _reason}), do: true
  defp valid_frame?(_frame), do: false

  defp emit_frames([], _emit), do: :ok

  defp emit_frames([frame | rest], emit) do
    with :ok <- execute(frame, fn event -> emit_frame(event, emit) end),
         do: emit_frames(rest, emit)
  end

  defp emit_frame(event, emit) do
    case emit.(event) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_emit_result, other}}
    end
  end

  defp stream_result(:ok, next), do: {:ok, next}
  defp stream_result({:error, reason}, next), do: {:error, reason, next}

  defp assemble([], assembler), do: Stream.finish(assembler)

  defp assemble([frame | rest], assembler) do
    case execute(frame, fn event -> Stream.push(assembler, event) end) do
      :ok -> assemble(rest, assembler)
      {:ok, next} -> assemble(rest, next)
      {:done, _response, next} -> assemble(rest, next)
      {:error, _reason} = error -> error
    end
  end

  defp execute({:gate, owner, ref}, _emit) do
    send(owner, {:scripted_gate, ref, self()})

    receive do
      {:release, ^ref} -> :ok
    end
  end

  defp execute({:sleep, milliseconds}, _emit), do: Process.sleep(milliseconds)
  defp execute({:crash, reason}, _emit), do: exit(reason)
  defp execute({:error, reason}, _emit), do: {:error, reason}
  defp execute(frame, emit), do: emit.(frame)
end
