defmodule AgentSystemsLab.Workflows.Coordinator do
  @moduledoc """
  Replaceable dependency observer with one bounded database helper.

  The Coordinator never executes a node. It observes child Run facts with
  `Store.sync/1` and owns one scoped `AgentSystemsLab.Scheduler`. The shared
  Workflow queue enforces `max_parallel` across competing Coordinators, while
  Run intent claims and fencing remain the sole execution authority.
  """
  use GenServer

  alias AgentSystemsLab.{DatabaseError, Scheduler}
  alias AgentSystemsLab.Scheduler.DatabaseTask
  alias AgentSystemsLab.Workflows.Store

  @terminal [:succeeded, :failed, :cancelled]
  @allowed ~w(workflow_id name poll_interval_ms database_timeout_ms database_backoff_ms max_database_backoff_ms scheduler_options)a
  @scheduler_allowed ~w(poll_interval_ms lease_ms renew_interval_ms execution_timeout_ms recovery_options scan_limit database_timeout_ms database_backoff_ms max_database_backoff_ms)a

  def start_link(opts) do
    with {:ok, config} <- config(opts) do
      GenServer.start_link(__MODULE__, config, Keyword.take(opts, [:name]))
    end
  end

  def status(server), do: GenServer.call(server, :status)
  def stop(server), do: GenServer.stop(server, :normal, :infinity)

  def wake(server) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      pid ->
        case Registry.lookup(AgentSystemsLab.Registry, {__MODULE__, pid}) do
          [{^pid, {_id, signal}}] ->
            if :atomics.compare_exchange(signal, 1, 0, 1) == :ok,
              do: GenServer.cast(pid, :wake),
              else: :ok

          [] ->
            :ok
        end
    end
  end

  @doc false
  def notify(id) do
    Registry.select(AgentSystemsLab.Registry, [
      {{{__MODULE__, :"$1"}, :"$1", {id, :"$2"}}, [], [:"$1"]}
    ])
    |> Enum.each(&wake/1)

    :ok
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    signal = :atomics.new(1, [])

    {:ok, _} =
      Registry.register(
        AgentSystemsLab.Registry,
        {__MODULE__, self()},
        {config.workflow_id, signal}
      )

    {:ok,
     schedule(
       %{
         config: config,
         signal: signal,
         view: nil,
         scheduler: nil,
         pending_sync: nil,
         poll_timer: nil,
         poll_token: nil,
         counters: %{syncs: 0, failures: 0, scheduler_starts: 0},
         database: %{
           state: :available,
           consecutive_failures: 0,
           retry_at_ms: nil,
           last_error: nil
         },
         errors: []
       },
       0
     )}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       workflow_id: state.config.workflow_id,
       workflow_status: if(state.view, do: state.view.status),
       workflow: state.view,
       scheduler: state.scheduler,
       pending_sync:
         if(state.pending_sync, do: Map.take(state.pending_sync, [:pid, :started_at_ms])),
       poll_interval_ms: state.config.poll_interval_ms,
       counters: state.counters,
       database: Map.put(state.database, :retry_in_ms, retry_remaining(state)),
       errors: Enum.reverse(state.errors),
       message_queue_len: elem(Process.info(self(), :message_queue_len), 1)
     }, state}
  end

  @impl true
  def handle_cast(:wake, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info({:poll, token}, %{poll_token: token} = state) do
    :atomics.put(state.signal, 1, 0)
    state = %{state | poll_timer: nil, poll_token: nil}

    state =
      if is_nil(state.pending_sync) and retry_remaining(state) == 0 do
        task =
          DatabaseTask.start(
            fn -> Store.sync(state.config.workflow_id) end,
            state.config.database_timeout_ms,
            :workflow_sync
          )

        %{state | pending_sync: task}
      else
        state
      end

    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:poll, _old}, state), do: {:noreply, state}

  def handle_info(
        {:workflow_sync, token, result},
        %{pending_sync: %{token: token} = task} = state
      ) do
    DatabaseTask.stop(task)
    state = %{state | pending_sync: nil}

    case result do
      {:ok, view} ->
        state = state |> database_available() |> increment(:syncs) |> Map.put(:view, view)
        state = ensure_scheduler(state)

        if view.status in @terminal,
          do: {:noreply, cancel_poll(state)},
          else: {:noreply, schedule(state, state.config.poll_interval_ms)}

      {:error, reason} ->
        state = state |> database_failure(reason) |> record_error(reason)
        {:noreply, schedule(state, state.config.poll_interval_ms)}
    end
  end

  def handle_info(
        {:workflow_sync, :timeout, token},
        %{pending_sync: %{token: token} = task} = state
      ) do
    DatabaseTask.stop(task)
    reason = {:database_timeout, :workflow_sync}
    state = %{state | pending_sync: nil} |> database_failure(reason) |> record_error(reason)
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:workflow_sync, _token, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{pending_sync: %{monitor: ref, pid: pid} = task} = state
      ) do
    DatabaseTask.forget(task)
    state = %{state | pending_sync: nil} |> record_error({:sync_helper_exit, reason})
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:EXIT, scheduler, reason}, %{scheduler: scheduler} = state)
      when is_pid(scheduler) do
    state = %{state | scheduler: nil} |> record_error({:scheduler_exit, reason})
    {:noreply, schedule(state, state.config.poll_interval_ms)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    DatabaseTask.stop(state.pending_sync)
    stop_scheduler(state.scheduler)
  end

  defp ensure_scheduler(%{view: %{control: %{status: :paused}}} = state) do
    stop_scheduler(state.scheduler)
    %{state | scheduler: nil}
  end

  defp ensure_scheduler(%{view: %{status: status}} = state) when status in @terminal do
    stop_scheduler(state.scheduler)
    %{state | scheduler: nil}
  end

  defp ensure_scheduler(%{scheduler: nil, view: view} = state) do
    opts =
      Keyword.merge(state.config.scheduler_options,
        queue: view.queue,
        max_workers: view.definition.max_parallel
      )

    case Scheduler.start_link(opts) do
      {:ok, pid} -> %{state | scheduler: pid} |> increment(:scheduler_starts)
      {:error, reason} -> record_error(state, {:scheduler_start, reason})
    end
  end

  defp ensure_scheduler(state) do
    Scheduler.wake(state.scheduler)
    state
  end

  defp stop_scheduler(nil), do: :ok

  defp stop_scheduler(pid) do
    if Process.alive?(pid) do
      try do
        Scheduler.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp database_available(state),
    do: %{
      state
      | database: %{state: :available, consecutive_failures: 0, retry_at_ms: nil, last_error: nil}
    }

  defp database_failure(state, reason) do
    if DatabaseError.unavailable?(reason) do
      count = state.database.consecutive_failures + 1

      delay =
        min(
          state.config.max_database_backoff_ms,
          state.config.database_backoff_ms * Integer.pow(2, min(count - 1, 20))
        )

      %{
        state
        | database: %{
            state: :unavailable,
            consecutive_failures: count,
            retry_at_ms: System.monotonic_time(:millisecond) + delay,
            last_error: inspect(reason, limit: 12, printable_limit: 300)
          }
      }
    else
      state
    end
  end

  defp retry_remaining(state),
    do:
      if(state.database.retry_at_ms,
        do: max(0, state.database.retry_at_ms - System.monotonic_time(:millisecond)),
        else: 0
      )

  defp increment(state, key), do: put_in(state.counters[key], state.counters[key] + 1)

  defp record_error(state, reason),
    do: %{
      increment(state, :failures)
      | errors: Enum.take([inspect(reason, limit: 12, printable_limit: 300) | state.errors], 20)
    }

  defp cancel_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    %{state | poll_timer: nil, poll_token: nil}
  end

  defp schedule(state, delay) do
    state = cancel_poll(state)
    token = make_ref()
    timer = Process.send_after(self(), {:poll, token}, max(delay, retry_remaining(state)))
    %{state | poll_timer: timer, poll_token: token}
  end

  defp config(opts) when is_list(opts) do
    if keyword?(opts, @allowed) do
      id = opts[:workflow_id]
      poll = Keyword.get(opts, :poll_interval_ms, 20)
      timeout = Keyword.get(opts, :database_timeout_ms, 1_000)
      backoff = Keyword.get(opts, :database_backoff_ms, 100)
      max_backoff = Keyword.get(opts, :max_database_backoff_ms, 5_000)
      scheduler = Keyword.get(opts, :scheduler_options, [])

      if is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
           not String.contains?(id, <<0>>) and valid_name?(opts[:name]) and
           is_integer(poll) and poll in 1..60_000 and is_integer(timeout) and
           timeout in 10..60_000 and
           is_integer(backoff) and backoff in 1..60_000 and is_integer(max_backoff) and
           max_backoff in backoff..60_000 and scheduler_options?(scheduler) do
        {:ok,
         %{
           workflow_id: id,
           poll_interval_ms: poll,
           database_timeout_ms: timeout,
           database_backoff_ms: backoff,
           max_database_backoff_ms: max_backoff,
           scheduler_options:
             Keyword.merge([poll_interval_ms: poll, database_timeout_ms: timeout], scheduler)
         }}
      else
        {:error, :invalid_coordinator_options}
      end
    else
      {:error, :invalid_coordinator_options}
    end
  end

  defp config(_), do: {:error, :invalid_coordinator_options}

  defp scheduler_options?(opts) do
    if keyword?(opts, @scheduler_allowed) do
      lease = Keyword.get(opts, :lease_ms, 30_000)

      renew =
        Keyword.get(opts, :renew_interval_ms, if(is_integer(lease), do: div(lease, 3), else: nil))

      poll = Keyword.get(opts, :poll_interval_ms, 100)
      timeout = Keyword.get(opts, :execution_timeout_ms, 30_000)
      db_timeout = Keyword.get(opts, :database_timeout_ms, 1_000)
      db_backoff = Keyword.get(opts, :database_backoff_ms, 100)
      db_max = Keyword.get(opts, :max_database_backoff_ms, 5_000)
      scan = Keyword.get(opts, :scan_limit, 32)
      hooks = Keyword.get(opts, :recovery_options, [])

      is_integer(lease) and lease in 2..86_400_000 and is_integer(renew) and
        renew in 1..(lease - 1) and
        is_integer(poll) and poll in 1..60_000 and is_integer(timeout) and
        timeout in 1..86_400_000 and
        is_integer(db_timeout) and db_timeout in 10..60_000 and is_integer(db_backoff) and
        db_backoff in 1..60_000 and is_integer(db_max) and db_max in db_backoff..60_000 and
        is_integer(scan) and scan in 1..256 and keyword?(hooks, [:hook, :tool_hook, :commit_hook]) and
        Enum.all?(hooks, fn {_key, value} -> is_nil(value) or is_function(value, 1) end)
    else
      false
    end
  end

  defp keyword?(opts, allowed),
    do:
      is_list(opts) and Keyword.keyword?(opts) and
        Keyword.keys(opts) -- allowed == [] and
        length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0)))

  defp valid_name?(nil), do: true
  defp valid_name?(name) when is_atom(name), do: true
  defp valid_name?({:global, _name}), do: true
  defp valid_name?({:via, module, _name}) when is_atom(module) and not is_nil(module), do: true
  defp valid_name?(_), do: false
end
