defmodule AgentSystemsLab.Scheduler do
  @moduledoc """
  Bounded background delivery of persisted, due scheduling intents.

  Each temporary linked Worker owns one committed claim and one executor. The
  database chooses work; this process holds neither a Run queue nor a retry
  clock. Independent instances may safely poll the same intents. `wake/1` is a
  latency hint only: periodic polling also discovers work without notifications.
  """
  use GenServer

  alias AgentSystemsLab.{DatabaseError, IntentStore}
  alias AgentSystemsLab.Scheduler.{DatabaseTask, Worker}

  @allowed ~w(name workers max_workers poll_interval_ms lease_ms renew_interval_ms run_ids recovery_options queue scan_limit execution_timeout_ms database_timeout_ms database_backoff_ms max_database_backoff_ms)a
  @hooks [:hook, :tool_hook, :commit_hook]

  def start_link(opts \\ []) do
    with {:ok, config} <- config(opts) do
      GenServer.start_link(__MODULE__, config, Keyword.take(opts, [:name]))
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def wake(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      pid ->
        case Registry.lookup(AgentSystemsLab.Registry, {:scheduler_wake, pid}) do
          [{^pid, signal}] ->
            :atomics.add(signal, 2, 1)

            if :atomics.compare_exchange(signal, 1, 0, 1) == :ok,
              do: GenServer.cast(pid, :wake),
              else: :ok

          [] ->
            :ok
        end
    end
  end

  def stop(server \\ __MODULE__), do: GenServer.stop(server, :normal, :infinity)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    signal = :atomics.new(2, [])
    {:ok, _} = Registry.register(AgentSystemsLab.Registry, {:scheduler_wake, self()}, signal)

    state = %{
      config: config,
      signal: signal,
      owner: "scheduler-" <> Ecto.UUID.generate(),
      active: %{},
      pending_claim: nil,
      database: %{state: :available, consecutive_failures: 0, retry_at_ms: nil, last_error: nil},
      poll_timer: nil,
      poll_token: nil,
      counters: %{claimed: 0, completed: 0, failed: 0, renewed: 0, scans: 0},
      errors: []
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    active =
      Enum.map(state.active, fn {pid, entry} ->
        %{
          worker: pid,
          executor: entry.executor,
          claim: entry.claim,
          renewals: entry.renewals,
          heartbeat: entry.heartbeat,
          heartbeat_age_ms:
            if(entry.heartbeat,
              do:
                System.monotonic_time(:millisecond) - entry.heartbeat.acknowledged_at_monotonic_ms
            )
        }
      end)

    {:reply,
     %{
       max_workers: state.config.max_workers,
       active: active,
       counters: state.counters,
       errors: Enum.reverse(state.errors),
       poll_interval_ms: state.config.poll_interval_ms,
       lease_ms: state.config.lease_ms,
       renew_interval_ms: state.config.renew_interval_ms,
       execution_timeout_ms: state.config.execution_timeout_ms,
       queue: state.config.queue,
       scan_limit: state.config.scan_limit,
       wake_requests: :atomics.get(state.signal, 2),
       wake_pending: :atomics.get(state.signal, 1) == 1,
       message_queue_len: elem(Process.info(self(), :message_queue_len), 1),
       database: Map.put(state.database, :retry_in_ms, retry_remaining(state)),
       database_timeout_ms: state.config.database_timeout_ms,
       pending_claim:
         if(state.pending_claim, do: Map.take(state.pending_claim, [:pid, :started_at_ms]))
     }, state}
  end

  @impl true
  def handle_cast(:wake, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info({:poll, token}, %{poll_token: token} = state) do
    :atomics.put(state.signal, 1, 0)
    state = %{state | poll_timer: nil, poll_token: nil}
    state = begin_claim(state)
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:poll, _old_token}, state), do: {:noreply, state}

  def handle_info(
        {:claim_result, token, result},
        %{pending_claim: %{token: token} = task} = state
      ) do
    DatabaseTask.stop(task)
    state = %{state | pending_claim: nil}

    case result do
      {:ok, nil} ->
        {:noreply, schedule(database_available(state), state.config.poll_interval_ms)}

      {:ok, claim} ->
        state = database_available(state)

        case Worker.start_link(claim, state.config, self()) do
          {:ok, pid} ->
            entry = %{
              claim: claim,
              monitor: Process.monitor(pid),
              executor: nil,
              renewals: 0,
              heartbeat: nil
            }

            state = %{state | active: Map.put(state.active, pid, entry)} |> increment(:claimed)
            {:noreply, begin_claim(state)}

          {:error, reason} ->
            DatabaseTask.run(
              fn -> IntentStore.release(claim) end,
              state.config.database_timeout_ms
            )

            {:noreply,
             schedule(
               error(state, claim.run_id, {:worker_start, reason}),
               state.config.poll_interval_ms
             )}
        end

      {:error, reason} ->
        state = record_database_failure(state, reason) |> error(nil, {:claim_next, reason})
        {:noreply, schedule(state, state.config.poll_interval_ms)}
    end
  end

  def handle_info(
        {:claim_result, :timeout, token},
        %{pending_claim: %{token: token} = task} = state
      ) do
    DatabaseTask.stop(task)
    reason = {:database_timeout, :claim}
    state = %{state | pending_claim: nil} |> record_database_failure(reason) |> error(nil, reason)
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:claim_result, _token, _result}, state), do: {:noreply, state}

  def handle_info({:delivery_executor, pid, executor}, state) do
    {:noreply, update_entry(state, pid, &%{&1 | executor: executor})}
  end

  def handle_info({:delivery_renewed, pid, claim, heartbeat}, state) do
    if Map.has_key?(state.active, pid) do
      state =
        update_entry(
          state,
          pid,
          &%{&1 | claim: claim, renewals: &1.renewals + 1, heartbeat: heartbeat}
        )

      {:noreply, state |> increment(:renewed) |> database_available()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:delivery_finished, pid, result}, state) do
    case Map.fetch(state.active, pid) do
      {:ok, entry} ->
        state = update_entry(state, pid, &Map.put(&1, :result, result))

        state =
          case result do
            {:ok, _snapshot} ->
              increment(state, :completed)

            {:error, reason} ->
              state
              |> increment(:failed)
              |> record_database_failure(reason)
              |> error(entry.claim.run_id, reason)
          end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{pending_claim: %{monitor: ref, pid: pid} = task} = state
      ) do
    DatabaseTask.forget(task)
    state = %{state | pending_claim: nil} |> error(nil, {:claim_helper_exit, reason})
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.active, pid) do
      {:ok, %{monitor: ^ref} = entry} ->
        state = %{state | active: Map.delete(state.active, pid)}

        state =
          if Map.has_key?(entry, :result),
            do: state,
            else: state |> increment(:failed) |> error(entry.claim.run_id, {:worker_exit, reason})

        delay =
          if match?({:ok, _}, Map.get(entry, :result)), do: 0, else: state.config.poll_interval_ms

        {:noreply, schedule(state, delay)}

      _ ->
        {:noreply, state}
    end
  end

  # Worker failures are tracked by monitors. GenServer itself handles its OTP
  # parent's EXIT before callbacks, so late child EXITs are harmless here.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    DatabaseTask.stop(state.pending_claim)

    Enum.each(state.active, fn {pid, _entry} ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp begin_claim(state) do
    if is_nil(state.pending_claim) and map_size(state.active) < state.config.max_workers and
         retry_remaining(state) == 0 do
      opts = [lease_ms: state.config.lease_ms, scan_limit: state.config.scan_limit]
      opts = if state.config.queue, do: Keyword.put(opts, :queue, state.config.queue), else: opts

      opts =
        if state.config.run_ids, do: Keyword.put(opts, :run_ids, state.config.run_ids), else: opts

      owner = state.owner <> "/" <> Ecto.UUID.generate()

      task =
        DatabaseTask.start(
          fn -> IntentStore.claim_next(owner, opts) end,
          state.config.database_timeout_ms,
          :claim_result
        )

      %{increment(state, :scans) | pending_claim: task}
    else
      state
    end
  end

  defp database_available(state),
    do: %{
      state
      | database: %{state: :available, consecutive_failures: 0, retry_at_ms: nil, last_error: nil}
    }

  defp record_database_failure(state, reason) do
    if DatabaseError.unavailable?(reason) do
      failures = state.database.consecutive_failures + 1

      delay =
        min(
          state.config.max_database_backoff_ms,
          state.config.database_backoff_ms * Integer.pow(2, min(failures - 1, 20))
        )

      %{
        state
        | database: %{
            state: :unavailable,
            consecutive_failures: failures,
            retry_at_ms: System.monotonic_time(:millisecond) + delay,
            last_error: inspect(reason, limit: 15, printable_limit: 300)
          }
      }
    else
      state
    end
  end

  defp retry_remaining(state) do
    if state.database.retry_at_ms,
      do: max(0, state.database.retry_at_ms - System.monotonic_time(:millisecond)),
      else: 0
  end

  defp update_entry(state, pid, fun) do
    case Map.fetch(state.active, pid) do
      {:ok, entry} -> %{state | active: Map.put(state.active, pid, fun.(entry))}
      :error -> state
    end
  end

  defp increment(state, key), do: put_in(state.counters[key], state.counters[key] + 1)

  defp error(state, run_id, reason) do
    item = %{run_id: run_id, reason: inspect(reason, limit: 15, printable_limit: 300)}
    %{state | errors: Enum.take([item | state.errors], 20)}
  end

  defp schedule(state, delay) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:poll, token}, max(delay, retry_remaining(state)))
    %{state | poll_timer: timer, poll_token: token}
  end

  @doc false
  def safely(fun) do
    try do
      fun.()
    rescue
      error in Postgrex.Error ->
        if DatabaseError.postgres_unavailable?(error),
          do: {:error, {:database_unavailable, :postgres, Exception.message(error)}},
          else: {:error, {:exception, error.__struct__, Exception.message(error)}}

      error ->
        {:error, {:exception, error.__struct__, Exception.message(error)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :throw, reason -> {:error, {:throw, reason}}
    end
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @allowed)) and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         not (Keyword.has_key?(opts, :workers) and Keyword.has_key?(opts, :max_workers)) do
      workers = Keyword.get(opts, :max_workers, Keyword.get(opts, :workers, 4))
      lease = Keyword.get(opts, :lease_ms, 30_000)
      renew = Keyword.get(opts, :renew_interval_ms, div(lease, 3))
      poll = Keyword.get(opts, :poll_interval_ms, 100)
      ids = Keyword.get(opts, :run_ids)
      recovery_opts = Keyword.get(opts, :recovery_options, [])
      queue = Keyword.get(opts, :queue)
      scan_limit = Keyword.get(opts, :scan_limit, 32)
      timeout = Keyword.get(opts, :execution_timeout_ms, 30_000)
      db_timeout = Keyword.get(opts, :database_timeout_ms, 1_000)
      db_backoff = Keyword.get(opts, :database_backoff_ms, 100)
      db_max_backoff = Keyword.get(opts, :max_database_backoff_ms, 5_000)

      if is_integer(workers) and workers in 1..128 and is_integer(poll) and poll in 1..60_000 and
           is_integer(lease) and lease in 2..86_400_000 and is_integer(renew) and renew > 0 and
           renew < lease and valid_ids?(ids) and valid_hooks?(recovery_opts) and
           valid_name?(Keyword.get(opts, :name)) and valid_queue?(queue) and
           is_integer(scan_limit) and scan_limit in 1..256 and
           is_integer(timeout) and timeout in 1..86_400_000 and
           is_integer(db_timeout) and db_timeout in 10..60_000 and
           is_integer(db_backoff) and db_backoff in 1..60_000 and
           is_integer(db_max_backoff) and db_max_backoff in db_backoff..60_000 do
        {:ok,
         %{
           max_workers: workers,
           poll_interval_ms: poll,
           lease_ms: lease,
           renew_interval_ms: renew,
           run_ids: if(is_nil(ids), do: nil, else: Enum.uniq(ids)),
           recovery_options: recovery_opts,
           queue: queue,
           scan_limit: scan_limit,
           execution_timeout_ms: timeout,
           database_timeout_ms: db_timeout,
           database_backoff_ms: db_backoff,
           max_database_backoff_ms: db_max_backoff
         }}
      else
        {:error, :invalid_scheduler_options}
      end
    else
      {:error, :invalid_scheduler_options}
    end
  end

  defp config(_), do: {:error, :invalid_scheduler_options}
  defp valid_ids?(nil), do: true

  defp valid_ids?(ids) when is_list(ids) and ids != [],
    do:
      Enum.all?(
        ids,
        &(is_binary(&1) and byte_size(&1) > 0 and String.valid?(&1) and
            not String.contains?(&1, <<0>>))
      )

  defp valid_ids?(_), do: false
  defp valid_queue?(nil), do: true

  defp valid_queue?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp valid_name?(nil), do: true
  defp valid_name?(name) when is_atom(name), do: true
  defp valid_name?({:global, _name}), do: true
  defp valid_name?({:via, module, _name}) when is_atom(module) and not is_nil(module), do: true
  defp valid_name?(_), do: false

  defp valid_hooks?(opts) when is_list(opts),
    do:
      Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
        Enum.all?(opts, fn {key, value} ->
          key in @hooks and (is_nil(value) or is_function(value, 1))
        end)

  defp valid_hooks?(_), do: false
end
