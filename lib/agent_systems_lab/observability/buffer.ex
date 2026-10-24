defmodule AgentSystemsLab.Observability.Buffer do
  @moduledoc """
  Fixed-slot ETS admission, coalesced wakeups and one isolated export worker.

  Producers never cast events into a process mailbox. Slots and payload bytes are
  reserved with bounded atomic compare/exchange attempts; a contended or full
  buffer drops observations. A batch is removed before export and never retried:
  best-effort export loss cannot become execution backpressure. Diagnostic recent
  history is independently bounded by entries and bytes. Metrics have a fixed
  vocabulary and no identifier labels. Exporter code is trusted host code, run
  in a monitored process with a finite timeout and error backoff. The owner traps
  exporter exits, while its link cleans up the exporter if the owner is killed.
  """
  use GenServer
  alias AgentSystemsLab.Observability.{Metrics, Schema}

  @default_key {__MODULE__, :default}
  @defaults [
    name: __MODULE__,
    capacity: 256,
    max_bytes: 1_048_576,
    max_event_bytes: 8_192,
    batch_size: 32,
    recent_capacity: 128,
    recent_max_bytes: 524_288,
    export_timeout_ms: 200,
    backoff_ms: 1_000,
    exporter: {AgentSystemsLab.Observability.Exporters.Null, []}
  ]
  @counters [
    admitted: 5,
    dropped: 6,
    invalid: 7,
    exported: 8,
    export_errors: 9,
    export_timeouts: 10,
    export_lost: 13
  ]

  # Observation ownership may disappear without spending the execution
  # supervisor's restart budget. Recovery is an explicit host operation.
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts \\ []) do
    with {:ok, config} <- config(opts) do
      GenServer.start_link(__MODULE__, config, if(config.name, do: [name: config.name], else: []))
    end
  end

  def handle(server \\ __MODULE__), do: GenServer.call(server, :handle)
  def default_handle, do: :persistent_term.get(@default_key, nil)
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)
  def recent(server \\ __MODULE__), do: GenServer.call(server, :recent)
  def metrics(server \\ __MODULE__), do: GenServer.call(server, :metrics)
  def configuration(server \\ __MODULE__), do: GenServer.call(server, :configuration)
  def configure(server \\ __MODULE__, opts), do: GenServer.call(server, {:configure, opts})

  @doc false
  def admit(nil, _name, _refs, _measurements, _opts), do: :ok

  def admit(
        %{table: _, counters: _, pid: _, capacity: _, max_bytes: _, max_event_bytes: _} = handle,
        name,
        refs,
        measurements,
        opts
      ) do
    try do
      case Schema.project(name, refs, measurements, opts) do
        {:ok, event} ->
          bytes = :erlang.external_size(event)

          if bytes <= handle.max_event_bytes and reserve(handle.counters, 1, 1, handle.capacity) do
            if reserve(handle.counters, 2, bytes, handle.max_bytes) do
              slot = rem(:atomics.add_get(handle.counters, 3, 1), handle.capacity)

              if :ets.insert_new(handle.table, {slot, bytes, event}) do
                :atomics.add(handle.counters, 5, 1)
                highwater(handle.counters, 11, :atomics.get(handle.counters, 1))
                highwater(handle.counters, 12, :atomics.get(handle.counters, 2))

                if :atomics.compare_exchange(handle.counters, 4, 0, 1) == :ok,
                  do: send(handle.pid, :drain)
              else
                release(handle, bytes)
                :atomics.add(handle.counters, 6, 1)
              end
            else
              :atomics.sub(handle.counters, 1, 1)
              :atomics.add(handle.counters, 6, 1)
            end
          else
            :atomics.add(handle.counters, 6, 1)
          end

        {:error, _} ->
          :atomics.add(handle.counters, 7, 1)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def admit(_handle, _name, _refs, _measurements, _opts), do: :ok

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    counters = :atomics.new(13, signed: false)

    handle = %{
      table: table,
      counters: counters,
      pid: self(),
      capacity: config.capacity,
      max_bytes: config.max_bytes,
      max_event_bytes: config.max_event_bytes
    }

    if config.name == __MODULE__, do: :persistent_term.put(@default_key, handle)

    {:ok,
     %{
       config: config,
       handle: handle,
       worker: nil,
       backoff: nil,
       recent: [],
       recent_bytes: 0,
       metrics: %{}
     }}
  end

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:recent, _from, state),
    do: {:reply, Enum.map(Enum.reverse(state.recent), &elem(&1, 1)), state}

  def handle_call(:metrics, _from, state), do: {:reply, Metrics.export(state.metrics), state}

  def handle_call(:configuration, _from, state),
    do:
      {:reply, Map.to_list(Map.take(state.config, [:exporter, :export_timeout_ms, :backoff_ms])),
       state}

  def handle_call(:stats, _from, state) do
    counters = state.handle.counters
    count = Map.new(@counters, fn {name, index} -> {name, :atomics.get(counters, index)} end)
    {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)

    result =
      Map.merge(count, %{
        buffer_entries: :atomics.get(counters, 1),
        queued_entries: :ets.info(state.handle.table, :size),
        buffer_bytes: :atomics.get(counters, 2),
        highwater_entries: :atomics.get(counters, 11),
        highwater_bytes: :atomics.get(counters, 12),
        recent_entries: length(state.recent),
        recent_bytes: state.recent_bytes,
        inflight: state.worker != nil,
        exporter_pid: if(state.worker, do: state.worker.pid, else: nil),
        mailbox_len: mailbox,
        backoff: state.backoff != nil,
        capacity: state.config.capacity,
        max_bytes: state.config.max_bytes,
        max_event_bytes: state.config.max_event_bytes,
        batch_size: state.config.batch_size,
        recent_capacity: state.config.recent_capacity,
        recent_max_bytes: state.config.recent_max_bytes
      })

    {:reply, result, state}
  end

  def handle_call({:configure, opts}, _from, state) do
    allowed = [:exporter, :export_timeout_ms, :backoff_ms]

    cond do
      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:reply, {:error, :invalid_observability_options}, state}

      Enum.any?(Keyword.keys(opts), &(&1 not in allowed)) ->
        {:reply, {:error, :invalid_observability_options}, state}

      state.worker != nil ->
        {:reply, {:error, :busy}, state}

      true ->
        case config(Keyword.merge(Map.to_list(state.config), opts)) do
          {:ok, config} ->
            if state.backoff, do: Process.cancel_timer(state.backoff.timer)
            send(self(), :drain)
            {:reply, :ok, %{state | config: config, backoff: nil}}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_info(:drain, %{worker: nil, backoff: nil} = state), do: {:noreply, drain(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:export_result, ref, result}, %{worker: %{ref: ref} = worker} = state) do
    Process.cancel_timer(worker.timer)
    Process.demonitor(worker.monitor, [:flush])

    if result == :ok do
      :atomics.add(state.handle.counters, 8, worker.count)
      {:noreply, drain(%{state | worker: nil})}
    else
      {:noreply, export_failed(%{state | worker: nil}, false, worker.count)}
    end
  end

  def handle_info({:export_timeout, ref}, %{worker: %{ref: ref} = worker} = state) do
    Process.exit(worker.pid, :kill)
    Process.demonitor(worker.monitor, [:flush])
    {:noreply, export_failed(%{state | worker: nil}, true, worker.count)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{worker: %{monitor: monitor} = worker} = state
      ) do
    Process.cancel_timer(worker.timer)
    {:noreply, export_failed(%{state | worker: nil}, false, worker.count)}
  end

  def handle_info({:backoff_expired, ref}, %{backoff: %{ref: ref}, worker: nil} = state),
    do: {:noreply, drain(%{state | backoff: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.worker, do: Process.exit(state.worker.pid, :kill)

    if state.config.name == __MODULE__ and default_handle() == state.handle,
      do: :persistent_term.erase(@default_key)

    :ok
  end

  defp drain(state) do
    :atomics.put(state.handle.counters, 4, 0)
    items = take(state.handle, state.config.batch_size, [])

    if items == [] do
      state
    else
      events = Enum.map(items, &elem(&1, 1))
      state = Enum.reduce(items, state, &remember/2)
      parent = self()
      ref = make_ref()
      {module, opts} = state.config.exporter

      {pid, monitor} =
        :erlang.spawn_opt(
          fn ->
            result =
              try do
                if module.export(events, opts) == :ok, do: :ok, else: :error
              rescue
                _ -> :error
              catch
                _, _ -> :error
              end

            send(parent, {:export_result, ref, result})
          end,
          [:link, :monitor]
        )

      timer = Process.send_after(self(), {:export_timeout, ref}, state.config.export_timeout_ms)

      %{
        state
        | worker: %{pid: pid, monitor: monitor, ref: ref, timer: timer, count: length(events)}
      }
    end
  end

  defp take(_handle, 0, acc), do: Enum.reverse(acc)

  defp take(handle, remaining, acc) do
    case :ets.first(handle.table) do
      :"$end_of_table" ->
        Enum.reverse(acc)

      slot ->
        case :ets.take(handle.table, slot) do
          [{^slot, bytes, event}] ->
            release(handle, bytes)
            take(handle, remaining - 1, [{bytes, event} | acc])

          [] ->
            Enum.reverse(acc)
        end
    end
  end

  defp remember({bytes, event}, state) do
    {recent, total} =
      trim([{bytes, event} | state.recent], state.recent_bytes + bytes, state.config)

    %{state | recent: recent, recent_bytes: total, metrics: Metrics.add(state.metrics, event)}
  end

  defp trim(recent, total, config) do
    if length(recent) > config.recent_capacity or total > config.recent_max_bytes do
      {bytes, _event} = List.last(recent)
      trim(Enum.drop(recent, -1), total - bytes, config)
    else
      {recent, total}
    end
  end

  defp export_failed(state, timeout?, count) do
    :atomics.add(state.handle.counters, 13, count)
    :atomics.add(state.handle.counters, 9, 1)
    if timeout?, do: :atomics.add(state.handle.counters, 10, 1)
    ref = make_ref()
    timer = Process.send_after(self(), {:backoff_expired, ref}, state.config.backoff_ms)
    %{state | backoff: %{ref: ref, timer: timer}}
  end

  defp reserve(counters, index, amount, limit, attempts \\ 8)
  defp reserve(_counters, _index, _amount, _limit, 0), do: false

  defp reserve(counters, index, amount, limit, attempts) do
    old = :atomics.get(counters, index)

    if old + amount <= limit do
      case :atomics.compare_exchange(counters, index, old, old + amount) do
        :ok -> true
        _ -> reserve(counters, index, amount, limit, attempts - 1)
      end
    else
      false
    end
  end

  defp release(handle, bytes) do
    :atomics.sub(handle.counters, 1, 1)
    :atomics.sub(handle.counters, 2, bytes)
  end

  defp highwater(counters, index, value) do
    old = :atomics.get(counters, index)
    if value > old, do: :atomics.compare_exchange(counters, index, old, value)
    :ok
  end

  defp config(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?(Keyword.keys(opts), &Keyword.has_key?(@defaults, &1)) do
      config = @defaults |> Keyword.merge(opts) |> Map.new()

      {module, exporter_opts} =
        case config.exporter do
          {m, o} -> {m, o}
          _ -> {nil, nil}
        end

      valid =
        (is_nil(config.name) or is_atom(config.name)) and
          in_range?(config.capacity, 1, 65_536) and in_range?(config.max_bytes, 128, 16_777_216) and
          in_range?(config.max_event_bytes, 128, 65_536) and
          config.max_event_bytes <= config.max_bytes and
          in_range?(config.batch_size, 1, min(config.capacity, 256)) and
          in_range?(config.recent_capacity, 1, 65_536) and
          in_range?(config.recent_max_bytes, 128, 16_777_216) and
          in_range?(config.export_timeout_ms, 1, 60_000) and
          in_range?(config.backoff_ms, 1, 60_000) and
          is_atom(module) and module != nil and is_list(exporter_opts) and
          Keyword.keyword?(exporter_opts)

      if valid, do: {:ok, config}, else: {:error, :invalid_observability_options}
    else
      _ -> {:error, :invalid_observability_options}
    end
  end

  defp in_range?(n, low, high), do: is_integer(n) and n >= low and n <= high
end
