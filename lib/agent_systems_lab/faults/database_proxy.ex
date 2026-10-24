defmodule AgentSystemsLab.Faults.DatabaseProxy do
  @moduledoc """
  An owned loopback TCP fault fixture, never a production database proxy.

  Only clients explicitly given this listener are affected. `disconnect/1`
  closes its sockets and rejects reconnects until `heal/1`. The COMMIT trap
  forwards the real COMMIT, waits for PostgreSQL's CommandComplete, and drops
  that acknowledgement before the client sees it. TLS is deliberately disabled
  in the isolated child; framed protocol inspection is required by this probe.
  """
  use GenServer

  def start_link(host, port), do: GenServer.start_link(__MODULE__, {host, port})
  def port(server), do: GenServer.call(server, :port)
  def status(server), do: GenServer.call(server, :status)
  def disconnect(server), do: GenServer.call(server, :disconnect)
  def heal(server), do: GenServer.call(server, :heal)
  def trap_commit_ack(server), do: GenServer.call(server, :trap_commit_ack)
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init({host, port}) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, local_port}} = :inet.sockname(listener)
    parent = self()
    acceptor = spawn_link(fn -> accept(listener, parent) end)

    {:ok,
     %{
       listener: listener,
       acceptor: acceptor,
       port: local_port,
       host: to_charlist(host),
       backend_port: port,
       mode: :healthy,
       pairs: %{},
       sockets: %{},
       accepted: 0,
       rejected: 0,
       dropped: 0,
       ack_dropped: 0,
       events: []
     }}
  end

  @impl true
  def handle_call(:port, _, state), do: {:reply, state.port, state}

  def handle_call(:status, _, state) do
    {:reply,
     Map.take(state, [:port, :mode, :accepted, :rejected, :dropped, :ack_dropped])
     |> Map.put(:connections, map_size(state.pairs))
     |> Map.put(:events, Enum.reverse(state.events)), state}
  end

  def handle_call(:disconnect, _, state) do
    state = close_all(state) |> Map.put(:mode, :blocked) |> event(:disconnect)
    {:reply, :ok, state}
  end

  def handle_call(:heal, _, state),
    do: {:reply, :ok, %{state | mode: :healthy} |> event(:heal)}

  def handle_call(:trap_commit_ack, _, %{mode: :healthy} = state),
    do: {:reply, :ok, %{state | mode: :armed} |> event(:commit_trap_armed)}

  def handle_call(:trap_commit_ack, _, state), do: {:reply, {:error, :not_healthy}, state}

  @impl true
  def handle_info({:accepted, socket}, %{mode: :blocked} = state) do
    :gen_tcp.close(socket)
    {:noreply, %{state | rejected: state.rejected + 1}}
  end

  def handle_info({:accepted, frontend}, state) do
    case :gen_tcp.connect(state.host, state.backend_port, [:binary, active: false], 1_000) do
      {:ok, backend} ->
        :inet.setopts(frontend, active: :once)
        :inet.setopts(backend, active: :once)
        ref = make_ref()

        pair = %{
          frontend: frontend,
          backend: backend,
          startup: true,
          front_buffer: <<>>,
          back_buffer: <<>>,
          awaiting_ack: false
        }

        {:noreply,
         %{
           state
           | pairs: Map.put(state.pairs, ref, pair),
             sockets:
               state.sockets |> Map.put(frontend, {ref, :front}) |> Map.put(backend, {ref, :back}),
             accepted: state.accepted + 1
         }
         |> event(:connected)}

      {:error, reason} ->
        :gen_tcp.close(frontend)
        {:noreply, event(state, {:connect_failed, reason})}
    end
  end

  def handle_info({:tcp, socket, bytes}, state) do
    case Map.get(state.sockets, socket) do
      {ref, :front} ->
        pair = Map.fetch!(state.pairs, ref)
        {frames, rest, startup} = frontend(pair.front_buffer <> bytes, pair.startup, [])
        commit? = Enum.any?(frames, &commit?/1)
        awaiting = pair.awaiting_ack or (state.mode == :armed and commit?)
        pair = %{pair | front_buffer: rest, startup: startup, awaiting_ack: awaiting}
        Enum.each(frames, &:gen_tcp.send(pair.backend, &1))
        :inet.setopts(socket, active: :once)
        state = %{state | pairs: Map.put(state.pairs, ref, pair)}
        {:noreply, if(commit? and awaiting, do: event(state, :commit_forwarded), else: state)}

      {ref, :back} ->
        pair = Map.fetch!(state.pairs, ref)
        {frames, rest} = typed_frames(pair.back_buffer <> bytes, [])

        if pair.awaiting_ack and Enum.any?(frames, &(&1 == <<?C, 11::32, "COMMIT", 0>>)) do
          # CommandComplete means the server has completed COMMIT. None of this
          # response batch is forwarded, so ReadyForQuery cannot acknowledge it.
          state = %{state | ack_dropped: state.ack_dropped + 1, mode: :blocked}
          {:noreply, state |> event(:commit_ack_dropped) |> close_all()}
        else
          Enum.each(frames, &:gen_tcp.send(pair.frontend, &1))
          :inet.setopts(socket, active: :once)
          {:noreply, %{state | pairs: Map.put(state.pairs, ref, %{pair | back_buffer: rest})}}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({kind, socket}, state) when kind in [:tcp_closed, :tcp_error],
    do: {:noreply, close_pair(state, socket)}

  def handle_info({:tcp_error, socket, _reason}, state),
    do: {:noreply, close_pair(state, socket)}

  @impl true
  def terminate(_, state) do
    close_all(state)
    :gen_tcp.close(state.listener)
    Process.unlink(state.acceptor)
    Process.exit(state.acceptor, :kill)
    :ok
  end

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, parent)
        send(parent, {:accepted, socket})
        accept(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp frontend(<<length::32, _::binary>> = data, true, frames)
       when length >= 8 and byte_size(data) >= length do
    <<frame::binary-size(^length), rest::binary>> = data
    frontend(rest, false, [frame | frames])
  end

  defp frontend(data, true, frames), do: {Enum.reverse(frames), data, true}

  defp frontend(data, false, frames) do
    {complete, rest} = typed_frames(data, [])
    {Enum.reverse(frames) ++ complete, rest, false}
  end

  defp typed_frames(<<_type, length::32, _::binary>> = data, frames)
       when length >= 4 and byte_size(data) >= length + 1 do
    <<frame::binary-size(^length + 1), rest::binary>> = data
    typed_frames(rest, [frame | frames])
  end

  defp typed_frames(data, frames), do: {Enum.reverse(frames), data}
  defp commit?(<<?Q, _::32, "COMMIT", 0>>), do: true
  defp commit?(_), do: false

  defp close_pair(state, socket) do
    case Map.get(state.sockets, socket) do
      nil ->
        state

      {ref, _} ->
        pair = Map.fetch!(state.pairs, ref)
        :gen_tcp.close(pair.frontend)
        :gen_tcp.close(pair.backend)

        %{
          state
          | pairs: Map.delete(state.pairs, ref),
            sockets: state.sockets |> Map.delete(pair.frontend) |> Map.delete(pair.backend),
            dropped: state.dropped + 1
        }
    end
  end

  defp close_all(state), do: Enum.reduce(Map.keys(state.sockets), state, &close_pair(&2, &1))

  defp event(state, value),
    do: %{
      state
      | events: [
          %{event: inspect(value), at_ms: System.monotonic_time(:millisecond)} | state.events
        ]
    }
end
