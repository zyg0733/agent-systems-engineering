defmodule AgentSystemsLab.Isolation do
  @moduledoc """
  Opt-in, fail-closed single-process Seatbelt executor for the macOS lab host.

  The trusted native guardian applies the profile and hard limits before exec,
  owns a new target session, captures bounded output, and reaps its target. Its
  private framing pipe is separate from untrusted stdout. Neither commands nor
  environment are evaluated by a shell. Unsupported hosts never run a fallback.
  """

  alias AgentSystemsLab.Isolation.Policy

  @backend "seatbelt.v1"
  @runtime Path.expand("../../.runtime/isolation", __DIR__)
  @source Path.expand("../../priv/isolation/guardian.c", __DIR__)
  @compiler "/usr/bin/clang"
  @frame_max 8192

  def capabilities do
    %{
      backend: @backend,
      platform: :os.type(),
      available: supported?(),
      enforcement_verified: false,
      process_scope: :single_fork_denied_target,
      network: :deny,
      hard_memory_quota: false,
      total_disk_quota: false,
      production_supported: false
    }
  end

  @doc "Compiles only the repository's trusted guardian, outside granted workspaces."
  def ensure_runtime do
    if supported?() do
      :global.trans({{__MODULE__, :compile}, self()}, fn -> build_runtime() end)
    else
      {:error, :unsupported_isolation_backend}
    end
  end

  def execute(command, args, policy, opts \\ []) do
    with :ok <- options(opts),
         :ok <- Policy.command(policy, command, args),
         :ok <- runtime_boundary(policy),
         :ok <- Policy.preflight(policy),
         {:ok, guardian} <- ensure_runtime(),
         {:ok, paths} <- prepare(policy) do
      try do
        with {:ok, effective} <- deadline_policy(policy, opts) do
          launch(guardian, command, args, effective, paths, opts)
        end
      after
        cleanup(paths)
      end
    end
  end

  @doc "Cancels an owned execution through its private control pipe, without PID lookup."
  def cancel(%{control: port}) when is_port(port) do
    try do
      if Port.command(port, "C"), do: :ok, else: {:error, :execution_closed}
    rescue
      ArgumentError -> {:error, :execution_closed}
    end
  end

  def cancel(_), do: {:error, :invalid_execution_handle}

  defp supported?,
    do:
      :os.type() == {:unix, :darwin} and File.regular?(@compiler) and
        File.regular?("/usr/bin/sandbox-exec")

  defp options(opts) do
    cond do
      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, :invalid_isolation_options}

      length(opts) != length(Enum.uniq(Keyword.keys(opts))) or
          Keyword.keys(opts) -- [:on_start, :backend, :deadline_monotonic_ms] != [] ->
        {:error, :invalid_isolation_options}

      Keyword.get(opts, :backend, :seatbelt) != :seatbelt ->
        {:error, :unsupported_isolation_backend}

      Keyword.has_key?(opts, :on_start) and not is_function(opts[:on_start], 1) ->
        {:error, :invalid_isolation_options}

      Keyword.has_key?(opts, :deadline_monotonic_ms) and
          not is_integer(opts[:deadline_monotonic_ms]) ->
        {:error, :invalid_isolation_options}

      true ->
        :ok
    end
  end

  defp deadline_policy(policy, opts) do
    case opts[:deadline_monotonic_ms] do
      nil ->
        {:ok, policy}

      deadline ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0,
          do:
            {:ok,
             %{
               policy
               | limits: %{
                   policy.limits
                   | wall_time_ms: min(remaining, policy.limits.wall_time_ms)
                 }
             }},
          else: {:error, :isolation_deadline_expired}
    end
  end

  # A writable grant must never include the native executable, its source, or
  # compiler cache. Otherwise one invocation could poison a later host launch.
  defp runtime_boundary(policy) do
    if Enum.any?([@runtime, Path.dirname(@source)], fn path ->
         path == policy.workspace or String.starts_with?(path, policy.workspace <> "/") or
           String.starts_with?(policy.workspace, path <> "/")
       end),
       do: {:error, :workspace_overlaps_executor},
       else: :ok
  end

  defp build_runtime do
    binary = Path.join(@runtime, "guardian")
    manifest = Path.join(@runtime, "build.json")

    with :ok <- File.mkdir_p(@runtime),
         :ok <- File.chmod(@runtime, 0o700),
         {:ok, source} <- File.read(@source) do
      source_hash = sha(source)

      if valid_binary?(binary, manifest, source_hash) do
        {:ok, binary}
      else
        compile(binary, manifest, source_hash)
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

  defp compile(binary, manifest, source_hash) do
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
                   JSON.encode!(%{"source_sha256" => source_hash, "binary_sha256" => sha(bytes)})
                 ) do
            {:ok, binary}
          end

        {log, status} ->
          {:error, {:isolation_compiler_failed, status, String.slice(log, 0, 4096)}}
      end
    after
      File.rm(temporary)
    end
  end

  defp prepare(policy) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    control = Path.join([@runtime, "control", nonce])
    tmp = Path.join(policy.workspace, ".lab-isolation-" <> nonce)
    profile_path = Path.join(control, "profile.sb")
    paths = %{control: control, tmp: tmp, profile: profile_path}

    with :ok <- File.mkdir_p(Path.dirname(control)),
         :ok <- File.mkdir(control),
         :ok <- File.chmod(control, 0o700),
         :ok <- File.mkdir(tmp),
         :ok <- File.chmod(tmp, 0o700),
         {:ok, profile} <- Policy.profile(policy, tmp),
         :ok <- File.write(profile_path, profile, [:exclusive]),
         :ok <- File.chmod(profile_path, 0o600) do
      {:ok, paths}
    else
      error ->
        cleanup(paths)
        error
    end
  end

  defp launch(guardian, command, args, policy, paths, opts) do
    limits = policy.limits

    argv =
      [
        paths.profile,
        policy.workspace,
        paths.tmp,
        to_string(limits.wall_time_ms),
        to_string(limits.cpu_seconds),
        to_string(limits.max_file_bytes),
        to_string(limits.max_output_bytes),
        command
      ] ++ args

    port =
      Port.open({:spawn_executable, guardian}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: argv
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    janitor = janitor(self(), os_pid, paths, limits.wall_time_ms + 5000)

    state = %{
      port: port,
      os_pid: os_pid,
      ready: nil,
      final: nil,
      buffer: <<>>,
      chunks: [],
      captured: 0,
      deadline: System.monotonic_time(:millisecond) + limits.wall_time_ms + 5000,
      policy: policy,
      opts: opts
    }

    try do
      await(state)
    after
      # Normal completion has consumed exit_status. An abnormal caller exit
      # closes its Port; the guardian observes EOF/SIGTERM and kills its group.
      if Port.info(port) do
        cancel(%{control: port})
        drain_exit(port, System.monotonic_time(:millisecond) + 2500)
        if Port.info(port), do: Port.close(port)
      end

      send(janitor, :completed)
    end
  end

  defp drain_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> drain_exit(port, deadline)
    after
      remaining -> :timeout
    end
  end

  defp await(state) do
    port = state.port
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        case frames(%{state | buffer: state.buffer <> bytes}) do
          {:ok, state} -> await(state)
          {:error, _} = error -> error
        end

      {^port, {:exit_status, status}} ->
        finish(state, status)
    after
      remaining ->
        cancel(%{control: port})
        {:error, :isolation_cleanup_timeout}
    end
  end

  defp frames(%{buffer: buffer} = state) when byte_size(buffer) < 5, do: {:ok, state}

  defp frames(%{buffer: <<type, length::32-big, rest::binary>>} = state) do
    cond do
      length > @frame_max ->
        {:error, :invalid_guardian_frame}

      byte_size(rest) < length ->
        {:ok, state}

      true ->
        <<payload::binary-size(^length), tail::binary>> = rest

        with {:ok, next} <- frame(type, payload, %{state | buffer: tail}) do
          frames(next)
        end
    end
  end

  defp frame(0, payload, %{ready: nil, final: nil} = state) do
    with {:ok, %{"guardian_pid" => guardian, "target_pid" => target} = ready} <-
           JSON.decode(payload),
         true <-
           guardian == state.os_pid and is_integer(target) and target > 1 and
             ready["profile_applied"] == true and ready["exec_acknowledged"] == true do
      handle = %{control: state.port, os_pid: guardian, target_pid: target}
      if callback = state.opts[:on_start], do: callback.(handle)
      {:ok, %{state | ready: ready}}
    else
      _ -> {:error, :invalid_guardian_ready}
    end
  end

  defp frame(1, payload, %{final: nil} = state) do
    captured = state.captured + byte_size(payload)

    if captured <= state.policy.limits.max_output_bytes,
      do: {:ok, %{state | chunks: [payload | state.chunks], captured: captured}},
      else: {:error, :guardian_output_overflow}
  end

  defp frame(2, payload, %{final: nil} = state) do
    case JSON.decode(payload) do
      {:ok, final} when is_map(final) -> {:ok, %{state | final: final}}
      _ -> {:error, :invalid_guardian_final}
    end
  end

  defp frame(_, _, _), do: {:error, :invalid_guardian_frame}

  defp finish(%{final: %{"setup_error" => reason}}, _),
    do: {:error, {:isolation_setup_failed, reason}}

  defp finish(%{final: %{"setup_stage" => stage} = final}, _) when stage > 0,
    do: {:error, {:isolation_setup_failed, stage, final["setup_errno"]}}

  defp finish(%{ready: ready, final: final} = state, 0)
       when is_map(ready) and is_map(final) do
    if final["target_exited"] == true and final["process_group_gone"] == true and
         final["target_pid"] == ready["target_pid"] and
         final["guardian_pid"] == state.os_pid and final["captured_bytes"] == state.captured and
         state.buffer == <<>> do
      {:ok,
       %{
         status: outcome(final, state.policy.limits),
         backend: @backend,
         output: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
         output_bytes: final["output_bytes"],
         truncated: final["output_bytes"] > state.captured,
         exit_status: if(final["exit_status"] >= 0, do: final["exit_status"], else: nil),
         signal: final["signal"],
         duration_ms: final["duration_ms"],
         cpu_ms: final["cpu_ms"],
         os_pid: state.os_pid,
         target_pid: ready["target_pid"],
         cleanup: %{
           target_pid: ready["target_pid"],
           target_exited: true,
           guardian_exited: true,
           process_group_gone: true
         }
       }}
    else
      {:error, :invalid_guardian_cleanup}
    end
  end

  defp finish(_, status), do: {:error, {:isolation_guardian_failed, status}}

  defp outcome(%{"reason" => "wall_time"}, _), do: :timed_out
  defp outcome(%{"reason" => "output_limit"}, _), do: :output_limit

  defp outcome(%{"reason" => reason}, _) when reason in ["cancelled", "owner_lost"],
    do: :cancelled

  defp outcome(%{"signal" => signal, "cpu_ms" => cpu}, limits)
       when signal in [24, 25] or (signal == 9 and cpu >= limits.cpu_seconds * 1000),
       do: :resource_limit

  defp outcome(%{"exit_status" => 0, "signal" => 0}, _), do: :succeeded
  defp outcome(_, _), do: :failed

  defp janitor(owner, guardian, paths, timeout) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :completed -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^owner, _} -> reap_files(guardian, paths, timeout)
      end
    end)
  end

  defp reap_files(guardian, paths, timeout) do
    # Only observe our own guardian PID; native code owns all signalling.
    deadline = System.monotonic_time(:millisecond) + timeout
    await_guardian(guardian, deadline)
    cleanup(paths)
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
