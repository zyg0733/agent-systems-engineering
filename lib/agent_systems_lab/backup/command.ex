defmodule AgentSystemsLab.Backup.Command do
  @moduledoc "Bounded, shell-free trusted host command; a guardian reaps its owned OS PID."
  @max_output 65_536

  def run(executable, args, env, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    observer = Keyword.get(opts, :notify)
    output_file = Keyword.get(opts, :output_file)

    if valid?(executable, args, env, timeout) and (is_nil(observer) or is_pid(observer)) and
         valid_output_file?(output_file) do
      owner = self()
      ref = make_ref()

      {guardian, monitor} =
        spawn_monitor(fn ->
          guard(owner, ref, executable, args, env, timeout, observer, output_file)
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^guardian, _} ->
          {:error, :backup_command_guardian_failed}
      after
        timeout + 3_000 ->
          send(guardian, {:cancel, ref})
          {:error, :backup_command_guardian_timeout}
      end
    else
      {:error, :invalid_backup_command}
    end
  end

  defp valid_output_file?(nil), do: true

  defp valid_output_file?({path, limit}),
    do: is_binary(path) and Path.type(path) == :absolute and is_integer(limit) and limit > 0

  defp valid_output_file?(_), do: false

  defp valid?(path, args, env, timeout) do
    is_binary(path) and Path.type(path) == :absolute and File.regular?(path) and
      is_list(args) and length(args) <= 32 and
      Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= 4096)) and
      is_list(env) and
      Enum.all?(env, fn {key, value} ->
        is_binary(key) and is_binary(value) and byte_size(value) <= 8192
      end) and is_integer(timeout) and timeout in 1..120_000
  rescue
    _ -> false
  end

  defp guard(owner, ref, executable, args, env, timeout, observer, output_file) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    try do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, args},
          {:env, Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}
        ])

      timer = Process.send_after(self(), :deadline, timeout)

      if observer do
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(observer, {:backup_command_started, os_pid})
      end

      if output_file, do: Process.send_after(self(), :check_file, 20)
      result = collect(port, monitor, ref, <<>>, output_file)
      Process.cancel_timer(timer)
      Process.demonitor(monitor, [:flush])
      send(owner, {ref, result})
    rescue
      _ -> send(owner, {ref, {:error, :backup_command_start_failed}})
    end
  end

  defp collect(port, owner_monitor, ref, output, output_file) do
    receive do
      {^port, {:data, chunk}} when byte_size(output) + byte_size(chunk) <= @max_output ->
        collect(port, owner_monitor, ref, output <> chunk, output_file)

      {^port, {:data, _}} ->
        kill(port)
        {:error, :backup_command_output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error, :backup_command_failed}

      {:DOWN, ^owner_monitor, :process, _, _} ->
        kill(port)
        {:error, :backup_command_owner_gone}

      {:cancel, ^ref} ->
        kill(port)
        {:error, :backup_command_cancelled}

      :deadline ->
        kill(port)
        {:error, :backup_command_timeout}

      :check_file ->
        {path, limit} = output_file

        case File.lstat(path) do
          {:ok, %{type: :regular, size: bytes}} when bytes <= limit ->
            Process.send_after(self(), :check_file, 20)
            collect(port, owner_monitor, ref, output, output_file)

          _ ->
            kill(port)
            {:error, :backup_command_file_limit}
        end

      {:EXIT, ^port, _} ->
        {:error, :backup_command_failed}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        # This PID comes only from this guardian's live Port, never caller input.
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
