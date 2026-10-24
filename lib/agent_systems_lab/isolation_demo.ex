defmodule AgentSystemsLab.IsolationDemo do
  @moduledoc """
  Direct syscall evidence for the supported isolated executor backend.

  All files, canaries, processes and the loopback listener belong to this run.
  The trusted C probe never prints file contents or the host environment.
  """

  alias AgentSystemsLab.Isolation
  alias AgentSystemsLab.Isolation.Policy

  @cases ~w(controlled_file outside_read outside_write symlink_read outside_link executable_link network fork_denied spawn_denied setsid_denied file_size file_descriptors cpu output wall cancel caller_crash unregistered_command)
  @wait_ms 6000

  def cases, do: @cases

  def run(opts \\ []) do
    with :ok <- options(opts),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week15-isolation")),
         :ok <- create_output(output) do
      run_fixture(output, opts)
    end
  end

  defp run_fixture(output, opts) do
    try do
      fixture = fixture(output)
      execute(@cases, [], fixture, opts)
    rescue
      exception ->
        failed(output, [], "initialization", Exception.format(:error, exception, __STACKTRACE__))
    catch
      kind, reason ->
        failed(output, [], "initialization", Exception.format(kind, reason, __STACKTRACE__))
    end
  end

  defp execute([], completed, fixture, _opts) do
    report = report(Enum.reverse(completed), nil)
    write_json(Path.join(fixture.output, "report.json"), report)
    {:ok, %{output_dir: fixture.output, report: report}}
  end

  defp execute([name | rest], completed, fixture, opts) do
    result =
      try do
        progress(opts, name, length(completed), :starting)
        summary = verify(name, Map.put(fixture, :case, name))
        write_json(Path.join(fixture.output, name <> ".json"), summary)
        {:ok, summary}
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        completed = [summary | completed]
        write_json(Path.join(fixture.output, "report.json"), report(Enum.reverse(completed), nil))

        try do
          progress(opts, name, length(completed), :passed)
          execute(rest, completed, fixture, opts)
        rescue
          exception -> failed(fixture.output, completed, name, Exception.message(exception))
        end

      {:error, reason} ->
        failed(fixture.output, completed, name, reason)
    end
  end

  defp fixture(output) do
    workspace = Path.join(output, "workspace")
    File.mkdir!(workspace)
    source = Application.app_dir(:agent_systems_lab, "priv/isolation/probe.c")
    probe = Path.join(output, "probe")

    compiler_result =
      System.cmd(
        "/usr/bin/clang",
        ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", source, "-o", probe],
        stderr_to_stdout: true
      )

    {compiler, _status} = compiler_result
    File.write!(Path.join(output, "compiler.log"), compiler)
    {_compiler, 0} = compiler_result

    write_json(Path.join(output, "fixture.json"), %{
      "source_sha256" => sha(File.read!(source)),
      "executable_sha256" => sha(File.read!(probe)),
      "compiler" => "/usr/bin/clang"
    })

    canary = Path.join(output, "outside-canary")
    File.write!(canary, :crypto.strong_rand_bytes(32))
    File.ln_s!(canary, Path.join(workspace, "outside-link"))

    {:ok, policy} = Policy.new(workspace: workspace, commands: [probe], network: :deny)
    write_json(Path.join(output, "policy.json"), safe(Policy.to_map(policy)))

    %{
      output: output,
      workspace: workspace,
      probe: probe,
      policy: policy,
      canary: canary,
      canary_hash: sha(File.read!(canary))
    }
  end

  defp verify("controlled_file" = name, fixture) do
    path = Path.join(fixture.workspace, "controlled.txt")
    result = invoke(fixture, ["rw", path])

    assert!(
      result.status == :succeeded and decoded(result)["ok"],
      "controlled read/write did not succeed"
    )

    assert!(File.read!(path) == "controlled fixture\n", "controlled fixture content differs")
    summary(name, result, %{"controlled_file_bytes" => File.stat!(path).size})
  end

  defp verify(name, fixture) when name in ["outside_read", "outside_write", "symlink_read"] do
    mode = if name == "outside_write", do: "write-denied", else: "read-denied"

    path =
      if name == "symlink_read",
        do: Path.join(fixture.workspace, "outside-link"),
        else: fixture.canary

    assert!(File.regular?(fixture.canary), "owned canary missing before direct syscall")
    result = invoke(fixture, [mode, path])
    data = decoded(result)

    assert!(
      result.status == :succeeded and data["denied"] == true and data["errno"] in [1, 13],
      "direct outside syscall was not denied by permission"
    )

    assert!(sha(File.read!(fixture.canary)) == fixture.canary_hash, "outside canary changed")

    summary(name, result, %{
      "canary_exists" => true,
      "canary_unchanged" => true,
      "permission_denied" => true
    })
  end

  defp verify("network" = name, fixture) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    try do
      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
      {baseline, 0} = System.cmd(fixture.probe, ["connect", Integer.to_string(port)])
      true = JSON.decode!(baseline)["connected"]
      {:ok, socket} = :gen_tcp.accept(listener, 1000)
      :gen_tcp.close(socket)
      result = invoke(fixture, ["connect-denied", Integer.to_string(port)])
      data = decoded(result)

      assert!(
        result.status == :succeeded and data["denied"] == true and data["connected"] == false,
        "real loopback connect was not denied"
      )

      assert!(
        :gen_tcp.accept(listener, 100) == {:error, :timeout},
        "sandbox reached owned listener"
      )

      summary(name, result, %{
        "baseline_connected" => true,
        "sandbox_connected" => false,
        "permission_denied" => true
      })
    after
      :gen_tcp.close(listener)
    end
  end

  defp verify(name, fixture) when name in ["outside_link", "executable_link"] do
    source = if name == "outside_link", do: fixture.canary, else: fixture.probe
    destination = Path.join(fixture.workspace, name <> "-alias")
    result = invoke(fixture, ["link-denied", source, destination])

    assert!(
      result.status == :succeeded and decoded(result)["denied"] == true,
      "sandbox created a hardlink capability alias"
    )

    assert!(File.lstat(destination) == {:error, :enoent}, "hardlink alias remained")
    summary(name, result, %{"hardlink_denied" => true, "alias_absent" => true})
  end

  defp verify(name, fixture) when name in ["fork_denied", "spawn_denied", "setsid_denied"] do
    result = invoke(fixture, [String.replace(name, "_", "-")])

    assert!(
      result.status == :succeeded and decoded(result)["denied"] == true,
      "sandbox created a descendant"
    )

    summary(name, result, %{"creation_or_escape_denied" => true, "max_target_processes" => 1})
  end

  defp verify("file_size" = name, fixture) do
    path = Path.join(fixture.workspace, "limited.bin")
    result = invoke(fixture, ["file-size", path], max_file_bytes: 4096)
    assert!(File.stat!(path).size <= 4096, "single-file size exceeded hard limit")

    assert!(
      result.status == :resource_limit or
        (result.status == :succeeded and decoded(result)["limited"] == true),
      "file-size hard limit did not trigger"
    )

    summary(name, result, %{
      "max_file_bytes" => 4096,
      "actual_file_bytes" => File.stat!(path).size,
      "hard_limit_observed" => true
    })
  end

  defp verify("cpu" = name, fixture) do
    result = invoke(fixture, ["cpu"], cpu_seconds: 1, wall_time_ms: 5000)

    assert!(
      result.status == :resource_limit,
      "CPU limit did not terminate computation before wall timeout"
    )

    summary(name, result, %{
      "cpu_seconds" => 1,
      "wall_time_ms" => 5000,
      "hard_limit_observed" => true
    })
  end

  defp verify("file_descriptors" = name, fixture) do
    result = invoke(fixture, ["fds"])
    data = decoded(result)

    assert!(
      result.status == :succeeded and data["limited"] == true and data["opened"] <= 61,
      "file-descriptor hard limit did not reject acquisition"
    )

    summary(name, result, %{
      "fd_limit" => 64,
      "opened" => data["opened"],
      "hard_limit_observed" => true
    })
  end

  defp verify("output" = name, fixture) do
    result = invoke(fixture, ["output"], max_output_bytes: 4096)

    assert!(
      result.status == :output_limit and byte_size(result.output) <= 4096,
      "output flood was not stopped with bounded capture"
    )

    summary(name, result, %{
      "max_output_bytes" => 4096,
      "captured_bytes" => byte_size(result.output)
    })
  end

  defp verify("wall" = name, fixture) do
    result = invoke(fixture, ["sleep", "10000"], wall_time_ms: 100)
    assert!(result.status == :timed_out, "wall timeout did not stop sleeping target")
    summary(name, result, %{"wall_time_ms" => 100})
  end

  defp verify(name, fixture) when name in ["cancel", "caller_crash"] do
    parent = self()
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    identity_path = Path.join(fixture.workspace, name <> "-identity.json")
    args = ["sleep", "10000", identity_path, nonce]
    marker = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        result =
          Isolation.execute(fixture.probe, args, fixture.policy,
            on_start: fn handle -> send(parent, {marker, :started, handle}) end
          )

        send(parent, {marker, :result, result})
      end)

    try do
      handle =
        receive do
          {^marker, :started, handle} -> handle
        after
          @wait_ms -> raise "isolated owner did not start"
        end

      identity = await_identity(identity_path, nonce)
      target = identity["pid"]
      assert!(handle.target_pid == target, "target identity differs from trusted guardian frame")
      assert!(alive?(target), "target exited before lifecycle fault injection")
      guardian = handle.os_pid
      assert!(alive?(guardian), "guardian exited before lifecycle fault injection")

      write_json(Path.join(fixture.output, name <> "-started.json"), %{
        "target_pid" => target,
        "guardian_pid" => guardian,
        "identity_nonce_verified" => true
      })

      result =
        if name == "cancel" do
          :ok = Isolation.cancel(handle)

          receive do
            {^marker, :result, {:ok, result}} ->
              write_json(Path.join(fixture.output, name <> "-execution.json"), safe(result))
              assert!(result.status == :cancelled, "cancel did not produce cancelled outcome")
              result
          after
            @wait_ms -> raise "cancelled execute did not return"
          end
        else
          Process.exit(owner, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^owner, :killed} -> :ok
          after
            @wait_ms -> raise "caller did not die"
          end

          nil
        end

      await_dead(target)
      await_dead(guardian)

      base =
        if result,
          do: summary(name, result),
          else: %{"case" => name, "passed" => true, "status" => "caller_crashed"}

      Map.merge(base, %{
        "target_started" => true,
        "target_pid" => target,
        "guardian_pid" => guardian,
        "target_exited" => true,
        "guardian_exited" => true,
        "identity_nonce_verified" => true
      })
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp verify("unregistered_command" = name, fixture) do
    result = Isolation.execute("/usr/bin/true", [], fixture.policy)
    assert!(match?({:error, _}, result), "command outside allowlist executed")

    %{
      "case" => name,
      "passed" => true,
      "status" => "rejected",
      "reason" => inspect(result),
      "command_started" => false
    }
  end

  defp invoke(fixture, args, limits \\ []) do
    {:ok, policy} =
      Policy.new(
        workspace: fixture.workspace,
        commands: [fixture.probe],
        network: :deny,
        limits: limits
      )

    response = Isolation.execute(fixture.probe, args, policy)
    write_json(Path.join(fixture.output, fixture.case <> "-execution.json"), safe(response))
    {:ok, result} = response
    result
  end

  defp summary(name, result, extra \\ %{}) do
    assert!(is_map(result.cleanup), "executor omitted cleanup evidence")
    cleanup = safe(result.cleanup)

    assert!(
      cleanup["target_exited"] == true and cleanup["guardian_exited"] == true and
        cleanup["process_group_gone"] == true,
      "executor omitted successful target, guardian or process-group cleanup"
    )

    await_dead(result.target_pid)
    await_dead(result.os_pid)

    Map.merge(
      %{
        "case" => name,
        "passed" => true,
        "status" => Atom.to_string(result.status),
        "result" => safe(result)
      },
      extra
    )
  end

  defp decoded(result), do: JSON.decode!(result.output)

  defp await_identity(path, nonce),
    do:
      wait_until(
        fn ->
          case File.read(path) do
            {:ok, bytes} ->
              case JSON.decode(bytes) do
                {:ok, %{"nonce" => ^nonce, "pid" => pid} = identity}
                when is_integer(pid) and pid > 1 ->
                  {:ok, identity}

                _ ->
                  :wait
              end

            _ ->
              :wait
          end
        end,
        "target did not publish its owned identity"
      )

  defp await_dead(pid),
    do:
      wait_until(
        fn -> if alive?(pid), do: :wait, else: {:ok, :ok} end,
        "owned OS process still alive: #{pid}"
      )

  defp wait_until(fun, reason),
    do: wait_until(fun, reason, System.monotonic_time(:millisecond) + @wait_ms)

  defp wait_until(fun, reason, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise(reason)
        Process.sleep(10)
        wait_until(fun, reason, deadline)
    end
  end

  defp alive?(pid) when is_integer(pid) and pid > 1 do
    {_output, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  end

  defp report(completed, failed) do
    %{
      "schema_version" => 1,
      "backend" => "seatbelt.v1",
      "backend_enforced" => completed != [],
      "platform" => inspect(:os.type()),
      "architecture" => :erlang.system_info(:system_architecture) |> List.to_string(),
      "expected_probe_count" => length(@cases),
      "probe_count" => length(completed),
      "all_passed" => failed == nil and length(completed) == length(@cases),
      "probes" => completed,
      "failed_probe" => failed,
      "process_scope" => "one fork-denied target plus trusted guardian",
      "unsupported_capabilities" => [
        "Linux container backend",
        "arbitrary target descendants",
        "hard memory quota",
        "total disk quota",
        "network allowlist",
        "multi-tenant boundary"
      ]
    }
  end

  defp failed(output, completed, name, reason) do
    report = report(Enum.reverse(completed), %{"case" => name, "reason" => reason})
    write_json(Path.join(output, "report.json"), report)
    {:error, {:isolation_verification_failed, %{output_dir: output, report: report}}}
  end

  defp progress(opts, name, completed, status) do
    if callback = Keyword.get(opts, :on_progress),
      do: callback.(%{case: name, completed: completed, total: length(@cases), status: status})
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:output, :on_progress] == [] and
         valid_path?(Keyword.get(opts, :output, "artifacts/week15-isolation")) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_isolation_demo_options}
  end

  defp valid_path?(path),
    do:
      is_binary(path) and path != "" and String.valid?(path) and not String.contains?(path, <<0>>)

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        {:error, reason} -> {:error, {:output_directory, reason}}
      end
    end
  end

  defp assert!(true, _), do: :ok
  defp assert!(_, reason), do: raise(reason)
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), safe(item)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)

  defp safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()
  defp safe(value) when is_pid(value) or is_port(value) or is_reference(value), do: inspect(value)
  defp safe(value), do: value
  defp write_json(path, value), do: File.write!(path, JSON.encode!(value) <> "\n")
end
