defmodule AgentSystemsLab.Scheduler.Worker do
  @moduledoc false
  use GenServer

  alias AgentSystemsLab.{
    DatabaseError,
    IntentStore,
    Observability,
    Recovery,
    Scheduler,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Scheduler.DatabaseTask

  def start_link(claim, config, scheduler),
    do: GenServer.start_link(__MODULE__, {claim, config, scheduler})

  @impl true
  def init({claim, config, scheduler}) do
    worker = self()
    delivery_ref = make_ref()
    started = System.monotonic_time(:millisecond)
    token = make_ref()

    watchdog =
      Process.send_after(
        self(),
        {:execution_timeout, token},
        min(config.execution_timeout_ms, config.database_timeout_ms)
      )

    # Policy reads run in the linked executor, so a blocked database cannot block
    # the controller's timeout, lease-loss or stop handling.
    {executor, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            Scheduler.safely(fn ->
              with {:ok, window} <- TaskBudgetStore.timeout(claim, config.execution_timeout_ms) do
                send(worker, {:execution_window, delivery_ref, window})
                Recovery.execute_claim(claim, config.recovery_options)
              end
            end)

          send(worker, {:executor_result, delivery_ref, result})
        end,
        [:link, :monitor]
      )

    send(scheduler, {:delivery_executor, self(), executor})

    {:ok,
     schedule_renew(%{
       claim: claim,
       config: config,
       scheduler: scheduler,
       executor: executor,
       monitor: monitor,
       delivery_ref: delivery_ref,
       result: nil,
       timer: nil,
       renew_token: nil,
       renewals: 0,
       renewal: nil,
       watchdog: watchdog,
       watchdog_token: token,
       started_at_ms: started,
       policy_ready: false,
       release?: true,
       timeout_reason: {:database_timeout, :execution_policy}
     })}
  end

  @impl true
  def handle_info(
        {:execution_window, ref, window},
        %{delivery_ref: ref, policy_ready: false} = state
      ) do
    Process.cancel_timer(state.watchdog)

    remaining =
      state.config.execution_timeout_ms -
        (System.monotonic_time(:millisecond) - state.started_at_ms)

    token = make_ref()

    watchdog =
      Process.send_after(
        self(),
        {:execution_timeout, token},
        max(1, min(window.timeout_ms, remaining))
      )

    {:noreply,
     %{
       state
       | policy_ready: true,
         watchdog: watchdog,
         watchdog_token: token,
         timeout_reason: window.reason
     }}
  end

  def handle_info({:renew, token}, %{renew_token: token, renewal: nil} = state)
      when not is_nil(token) do
    Process.cancel_timer(state.timer)

    task =
      DatabaseTask.start(
        fn -> IntentStore.renew(state.claim, lease_ms: state.config.lease_ms) end,
        state.config.database_timeout_ms,
        :renew_result
      )

    {:noreply, %{state | renewal: task, timer: nil, renew_token: nil}}
  end

  def handle_info({:renew_result, token, result}, %{renewal: %{token: token} = task} = state) do
    DatabaseTask.stop(task)
    state = %{state | renewal: nil}

    case result do
      {:ok, claim} ->
        acknowledged = System.monotonic_time(:millisecond)

        heartbeat = %{
          sequence: state.renewals + 1,
          acknowledged_at_monotonic_ms: acknowledged,
          duration_ms: acknowledged - task.started_at_ms,
          lease_expires_at: claim.expires_at
        }

        send(state.scheduler, {:delivery_renewed, self(), claim, heartbeat})
        state = %{state | claim: claim, renewals: state.renewals + 1}

        if is_nil(state.executor),
          do: finish(state, state.result),
          else: {:noreply, schedule_renew(state)}

      {:error, reason} ->
        if is_nil(state.executor) and match?({:ok, _}, state.result),
          do: finish(%{state | release?: false}, state.result),
          else: lose_lease(state, reason)
    end
  end

  def handle_info({:renew_result, :timeout, token}, %{renewal: %{token: token} = task} = state) do
    # Stop the business executor before killing an in-flight renewal. Its COMMIT
    # ACK may be unknown, so never release based on a guessed expiry.
    state = stop_executor(state)
    DatabaseTask.stop(task)
    lose_lease(%{state | renewal: nil}, {:database_timeout, :renew})
  end

  def handle_info({:execution_timeout, token}, %{watchdog_token: token} = state) do
    Observability.emit(
      :execution_timed_out,
      claim_refs(state.claim),
      %{duration_ms: max(0, System.monotonic_time(:millisecond) - state.started_at_ms)},
      phase: :observed,
      reason: :timeout
    )

    cancel(state.timer)
    state = stop_executor(state)
    uncertain_renewal = not is_nil(state.renewal)
    DatabaseTask.stop(state.renewal)
    state = %{state | renewal: nil, release?: state.release? and not uncertain_renewal}

    result =
      if state.policy_ready do
        DatabaseTask.run(
          fn -> Recovery.reclaim(state.claim, state.timeout_reason) end,
          state.config.database_timeout_ms
        )
      else
        {:error, state.timeout_reason}
      end

    state = if DatabaseError.unavailable?(result), do: %{state | release?: false}, else: state
    send(state.scheduler, {:delivery_finished, self(), result})
    {:stop, :normal, state}
  end

  def handle_info({:renew, _obsolete_token}, state), do: {:noreply, state}
  def handle_info(:renew, state), do: {:noreply, state}
  def handle_info({:renew_result, _token, _result}, state), do: {:noreply, state}
  def handle_info({:execution_timeout, _obsolete_token}, state), do: {:noreply, state}
  def handle_info({:execution_window, _ref, _window}, state), do: {:noreply, state}

  def handle_info({:executor_result, ref, result}, %{delivery_ref: ref} = state),
    do:
      {:noreply,
       %{
         state
         | result: result,
           release?: state.release? and not DatabaseError.unavailable?(result)
       }}

  def handle_info({:DOWN, ref, :process, pid, reason}, %{monitor: ref, executor: pid} = state) do
    result = state.result || {:error, {:executor_exit, reason}}
    state = %{state | executor: nil, monitor: nil, result: result}
    # Preserve a renewal already in flight until its bounded outcome is known.
    # A stale executor result must not hide the heartbeat's observed lease loss.
    if state.renewal, do: {:noreply, state}, else: finish(state, result)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{renewal: %{monitor: ref, pid: pid} = task} = state
      ) do
    DatabaseTask.forget(task)
    lose_lease(%{state | renewal: nil}, {:database_helper_exit, reason})
  end

  @impl true
  def terminate(_reason, state) do
    cancel(state.timer)
    cancel(state.watchdog)
    state = stop_executor(state)
    DatabaseTask.stop(state.renewal)

    if state.release? and is_nil(state.renewal) do
      DatabaseTask.run(
        fn -> IntentStore.release(state.claim) end,
        state.config.database_timeout_ms
      )
    end

    :ok
  end

  defp finish(state, result) do
    send(state.scheduler, {:delivery_finished, self(), result})
    {:stop, :normal, state}
  end

  defp lose_lease(state, reason) do
    Observability.emit(:lease_lost, claim_refs(state.claim), %{}, phase: :observed)
    state = stop_executor(state)
    send(state.scheduler, {:delivery_finished, self(), {:error, {:lease_lost, reason}}})
    {:stop, :normal, %{state | release?: false}}
  end

  defp schedule_renew(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:renew, token}, state.config.renew_interval_ms)
    %{state | timer: timer, renew_token: token}
  end

  defp stop_executor(%{executor: nil} = state), do: state

  defp stop_executor(state) do
    Process.unlink(state.executor)
    Process.exit(state.executor, :kill)

    receive do
      {:DOWN, ref, :process, pid, _reason} when ref == state.monitor and pid == state.executor ->
        :ok
    end

    %{state | executor: nil, monitor: nil}
  end

  defp claim_refs(claim), do: Map.take(claim, [:run_id, :seq, :intent_id, :generation])

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
