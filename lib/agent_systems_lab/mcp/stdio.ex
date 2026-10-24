defmodule AgentSystemsLab.MCP.Stdio do
  @moduledoc """
  A private framed bridge around one Seatbelt-confined MCP server. The native
  parent owns cleanup; server stdout and stderr can never forge control frames.
  Stdio deliberately has no unsandboxed or shell-based fallback.
  """

  alias AgentSystemsLab.Isolation.Policy

  @runtime Path.expand("../../../.runtime/mcp", __DIR__)
  @source Path.expand("../../../priv/mcp/stdio_guardian.c", __DIR__)
  @compiler "/usr/bin/clang"
  @frame_max 8192

  def ensure_runtime do
    if :os.type() == {:unix, :darwin} and File.regular?(@compiler) and
         File.regular?("/usr/bin/sandbox-exec") do
      :global.trans({{__MODULE__, :compile}, self()}, fn -> build() end)
    else
      {:error, :unsupported_isolation_backend}
    end
  end

  def open(policy, opts \\ []) do
    isolation = policy.isolation_policy

    with :ok <- Policy.command(isolation, policy.command, policy.args),
         :ok <- boundary(isolation),
         :ok <- Policy.preflight(isolation),
         {:ok, executable} <- ensure_runtime(),
         {:ok, paths} <- prepare(isolation) do
      limits = effective_limits(isolation.limits, opts)

      argv =
        [paths.profile, isolation.workspace, paths.tmp] ++
          Enum.map(
            [
              limits.wall_time_ms,
              limits.cpu_seconds,
              limits.max_file_bytes,
              limits.max_output_bytes
            ],
            &to_string/1
          ) ++ [policy.command | policy.args]

      try do
        if limits.wall_time_ms <= 0, do: throw(:mcp_deadline_expired)

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: argv
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        janitor = janitor(self(), os_pid, paths, limits.wall_time_ms + 5000)

        {:ok,
         %{
           port: port,
           os_pid: os_pid,
           ready: nil,
           final: nil,
           buffer: <<>>,
           captured: 0,
           stderr: <<>>,
           limits: limits,
           paths: paths,
           janitor: janitor
         }}
      rescue
        error ->
          cleanup(paths)
          {:error, {:mcp_launch_failed, Exception.message(error)}}
      catch
        :mcp_deadline_expired ->
          cleanup(paths)
          {:error, :mcp_deadline_expired}
      end
    end
  end

  defp effective_limits(limits, opts) do
    case opts[:deadline_monotonic_ms] do
      nil ->
        limits

      deadline ->
        %{
          limits
          | wall_time_ms: min(limits.wall_time_ms, deadline - System.monotonic_time(:millisecond))
        }
    end
  end

  def write(transport, bytes) when is_binary(bytes) and byte_size(bytes) <= 1_048_576,
    do: command(transport, <<1, byte_size(bytes)::32-big, bytes::binary>>)

  def write(_, _), do: {:error, :mcp_input_too_large}
  def close_input(transport), do: command(transport, <<2, 0::32>>)
  def cancel(transport), do: command(transport, <<3, 0::32>>)

  def ingest(transport, bytes) when is_binary(bytes),
    do: frames(%{transport | buffer: transport.buffer <> bytes}, [])

  def finish(%{final: %{"setup_error" => reason}} = transport, _status) do
    release(transport)
    {:error, {:isolation_setup_failed, reason}}
  end

  def finish(%{final: %{"setup_stage" => stage} = final} = transport, _status)
      when stage > 0 do
    release(transport)
    {:error, {:isolation_setup_failed, stage, final["setup_errno"]}}
  end

  def finish(%{ready: ready, final: final} = transport, 0)
      when is_map(ready) and is_map(final) do
    release(transport)

    if final["target_exited"] == true and final["process_group_gone"] == true and
         final["target_pid"] == ready["target_pid"] and
         final["guardian_pid"] == transport.os_pid and
         final["captured_bytes"] == transport.captured and transport.buffer == <<>> do
      {:ok,
       %{
         "backend" => "seatbelt.mcp_stdio.v1",
         "guardian_pid" => transport.os_pid,
         "target_pid" => ready["target_pid"],
         "target_exited" => true,
         "guardian_exited" => true,
         "process_group_gone" => true,
         "reason" => final["reason"],
         "signal" => final["signal"],
         "exit_status" => final["exit_status"],
         "output_bytes" => final["output_bytes"],
         "duration_ms" => final["duration_ms"]
       }}
    else
      {:error, :invalid_mcp_guardian_cleanup}
    end
  end

  def finish(transport, status) do
    release(transport)
    {:error, {:mcp_guardian_failed, status}}
  end

  def abandon(transport) do
    cancel(transport)
    :ok
  end

  defp command(%{port: port}, bytes) do
    try do
      if Port.command(port, bytes), do: :ok, else: {:error, :mcp_connection_closed}
    rescue
      ArgumentError -> {:error, :mcp_connection_closed}
    end
  end

  defp frames(%{buffer: bytes} = transport, events) when byte_size(bytes) < 5,
    do: {:ok, transport, Enum.reverse(events)}

  defp frames(%{buffer: <<type, length::32-big, rest::binary>>} = transport, events) do
    cond do
      length > @frame_max ->
        {:error, :invalid_mcp_guardian_frame}

      byte_size(rest) < length ->
        {:ok, transport, Enum.reverse(events)}

      true ->
        <<payload::binary-size(^length), tail::binary>> = rest

        with {:ok, transport, event} <- frame(type, payload, %{transport | buffer: tail}) do
          frames(transport, [event | events])
        end
    end
  end

  defp frame(0, payload, %{ready: nil, final: nil} = transport) do
    with {:ok, %{"guardian_pid" => guardian, "target_pid" => target} = ready} <-
           JSON.decode(payload),
         true <- guardian == transport.os_pid and is_integer(target) and target > 1,
         true <- ready["profile_applied"] == true and ready["exec_acknowledged"] == true do
      {:ok, %{transport | ready: ready}, {:ready, ready}}
    else
      _ -> {:error, :invalid_mcp_guardian_ready}
    end
  end

  defp frame(type, payload, %{final: nil} = transport) when type in [1, 3] do
    captured = transport.captured + byte_size(payload)

    if captured <= transport.limits.max_output_bytes do
      transport = %{transport | captured: captured}

      if type == 3 do
        # stderr is diagnostic data, with its own small retained tail. It never
        # enters the JSON-RPC parser or model-visible tool result.
        stderr = transport.stderr <> payload

        stderr =
          binary_part(stderr, max(byte_size(stderr) - 4096, 0), min(byte_size(stderr), 4096))

        {:ok, %{transport | stderr: stderr}, {:stderr, payload}}
      else
        {:ok, transport, {:stdout, payload}}
      end
    else
      {:error, :mcp_guardian_output_overflow}
    end
  end

  defp frame(2, payload, %{final: nil} = transport) do
    case JSON.decode(payload) do
      {:ok, final} when is_map(final) -> {:ok, %{transport | final: final}, {:final, final}}
      _ -> {:error, :invalid_mcp_guardian_final}
    end
  end

  defp frame(_, _, _), do: {:error, :invalid_mcp_guardian_frame}

  defp boundary(policy) do
    if Enum.any?([@runtime, Path.dirname(@source)], fn path ->
         path == policy.workspace or String.starts_with?(path, policy.workspace <> "/") or
           String.starts_with?(policy.workspace, path <> "/")
       end),
       do: {:error, :workspace_overlaps_mcp_executor},
       else: :ok
  end

  defp build do
    binary = Path.join(@runtime, "stdio_guardian")
    manifest = Path.join(@runtime, "build.json")

    with :ok <- File.mkdir_p(@runtime),
         :ok <- File.chmod(@runtime, 0o700),
         {:ok, source} <- File.read(@source) do
      source_hash = sha(source)

      if valid_binary?(binary, manifest, source_hash) do
        {:ok, binary}
      else
        temporary = binary <> "." <> Integer.to_string(System.unique_integer([:positive]))

        try do
          case System.cmd(
                 @compiler,
                 [
                   "-std=c11",
                   "-O2",
                   "-Wall",
                   "-Wextra",
                   "-Werror",
                   "-Wno-deprecated-declarations",
                   @source,
                   "-o",
                   temporary,
                   "-lsandbox"
                 ],
                 stderr_to_stdout: true
               ) do
            {_log, 0} ->
              with :ok <- File.chmod(temporary, 0o700),
                   :ok <- File.rename(temporary, binary),
                   {:ok, bytes} <- File.read(binary),
                   :ok <-
                     File.write(
                       manifest,
                       JSON.encode!(%{
                         "source_sha256" => source_hash,
                         "binary_sha256" => sha(bytes)
                       })
                     ) do
                {:ok, binary}
              end

            {log, status} ->
              {:error, {:mcp_compiler_failed, status, String.slice(log, 0, 4096)}}
          end
        after
          File.rm(temporary)
        end
      end
    end
  end

  defp valid_binary?(binary, manifest, source_hash) do
    with {:ok, %{type: :regular, links: 1}} <- File.lstat(binary),
         {:ok, bytes} <- File.read(binary),
         {:ok, saved} <- File.read(manifest),
         {:ok, data} <- JSON.decode(saved) do
      data == %{"source_sha256" => source_hash, "binary_sha256" => sha(bytes)}
    else
      _ -> false
    end
  end

  defp prepare(policy) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    control = Path.join([@runtime, "control", nonce])
    tmp = Path.join(policy.workspace, ".lab-mcp-" <> nonce)
    paths = %{control: control, tmp: tmp, profile: Path.join(control, "profile.sb")}

    with :ok <- File.mkdir_p(Path.dirname(control)),
         :ok <- File.mkdir(control),
         :ok <- File.chmod(control, 0o700),
         :ok <- File.mkdir(tmp),
         :ok <- File.chmod(tmp, 0o700),
         {:ok, profile} <- Policy.profile(policy, tmp),
         :ok <- File.write(paths.profile, profile, [:exclusive]),
         :ok <- File.chmod(paths.profile, 0o600) do
      {:ok, paths}
    else
      error ->
        cleanup(paths)
        error
    end
  end

  defp release(transport) do
    send(transport.janitor, :completed)
    cleanup(transport.paths)
  end

  defp janitor(owner, guardian, paths, timeout) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :completed ->
          Process.demonitor(ref, [:flush])

        {:DOWN, ^ref, :process, ^owner, _} ->
          await_guardian(guardian, System.monotonic_time(:millisecond) + timeout)
          cleanup(paths)
      end
    end)
  end

  defp await_guardian(guardian, deadline) do
    {_out, status} = System.cmd("/bin/kill", ["-0", to_string(guardian)], stderr_to_stdout: true)

    if status == 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      await_guardian(guardian, deadline)
    end
  end

  defp cleanup(paths) do
    File.rm_rf(paths.control)
    File.rm_rf(paths.tmp)
    :ok
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
