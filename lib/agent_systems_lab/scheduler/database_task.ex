defmodule AgentSystemsLab.Scheduler.DatabaseTask do
  @moduledoc false

  def start(fun, timeout, tag) do
    owner = self()
    token = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = AgentSystemsLab.Scheduler.safely(fun)
          send(owner, {tag, token, result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(owner, {tag, :timeout, token}, timeout)

    %{
      pid: pid,
      monitor: monitor,
      token: token,
      timer: timer,
      started_at_ms: System.monotonic_time(:millisecond)
    }
  end

  # A result signal precedes DOWN from the same helper. Await its exit before
  # reusing a slot; killing on timeout can leave a committed but unacknowledged
  # claim, which must be rediscovered through its lease rather than guessed.
  def stop(nil), do: :ok

  def stop(task) do
    Process.cancel_timer(task.timer)
    Process.unlink(task.pid)
    Process.exit(task.pid, :kill)

    receive do
      {:DOWN, ref, :process, pid, _} when ref == task.monitor and pid == task.pid -> :ok
    end
  end

  def forget(task) do
    Process.cancel_timer(task.timer)
    Process.demonitor(task.monitor, [:flush])
    :ok
  end

  def run(fun, timeout) do
    task = start(fun, timeout, :database_cleanup)

    receive do
      {:database_cleanup, token, result} when token == task.token ->
        stop(task)
        result

      {:database_cleanup, :timeout, token} when token == task.token ->
        stop(task)
        {:error, {:database_timeout, :cleanup}}

      {:DOWN, ref, :process, pid, reason} when ref == task.monitor and pid == task.pid ->
        forget(task)
        {:error, {:database_helper_exit, reason}}
    end
  end
end
