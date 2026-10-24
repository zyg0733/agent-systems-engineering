defmodule AgentSystemsLab.Isolation.PolicyTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Isolation.Policy
  alias AgentSystemsLab.Storage.Codec

  setup do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    root = Path.join(base, "agent-lab-policy-#{System.unique_integer([:positive, :monotonic])}")
    workspace = Path.join(root, "workspace")
    executable = Path.join(root, "host-probe")
    private_tmp = Path.join(workspace, ".isolation/private")
    File.mkdir_p!(private_tmp)
    File.chmod!(private_tmp, 0o700)
    File.write!(executable, "host owned executable fixture\n")
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [workspace: workspace, commands: [executable]]
    {:ok, policy} = Policy.new(opts)

    %{
      root: root,
      workspace: workspace,
      executable: executable,
      private_tmp: private_tmp,
      opts: opts,
      policy: policy
    }
  end

  test "default authority is finite, offline, and single process", %{policy: policy} do
    assert policy.schema_version == 1
    assert policy.network == :deny

    assert policy.limits == %{
             wall_time_ms: 5000,
             cpu_seconds: 2,
             max_output_bytes: 65_536,
             max_file_bytes: 1_048_576,
             max_processes: 1
           }

    assert :ok = Policy.validate(policy)
  end

  test "host enrollment rejects unknown, duplicate, and malformed options", %{opts: opts} do
    for invalid <- [
          nil,
          %{},
          [:bad],
          opts ++ [env: %{}],
          opts ++ [network: :deny, network: :deny]
        ] do
      assert {:error, :invalid_isolation_options} = Policy.new(invalid)
    end

    assert {:error, :invalid_isolation_workspace} = Policy.new(commands: [])
    assert {:error, :invalid_isolation_commands} = Policy.new(Keyword.delete(opts, :commands))
  end

  test "all unsupported network grants fail closed", %{opts: opts} do
    for network <- [:allow, :loopback, [], %{allow: ["127.0.0.1:80"]}, nil] do
      assert {:error, :unsupported_network_policy} =
               Policy.new(Keyword.put(opts, :network, network))
    end
  end

  test "limits have hard upper bounds and unsupported capabilities fail", %{opts: opts} do
    for invalid <- [
          nil,
          %{},
          [:bad],
          [wall_time_ms: 0],
          [wall_time_ms: 60_001],
          [wall_time_ms: 1.0],
          [cpu_seconds: 0],
          [cpu_seconds: 61],
          [max_output_bytes: 0],
          [max_output_bytes: 1_048_577],
          [max_file_bytes: 0],
          [max_file_bytes: 16_777_217],
          [max_processes: 0],
          [max_processes: 2],
          [max_processes: 1.0],
          [memory_bytes: 1_048_576],
          [wall_time_ms: 100, wall_time_ms: 200]
        ] do
      assert {:error, :invalid_isolation_limits} = Policy.new(Keyword.put(opts, :limits, invalid))
    end

    assert {:ok, policy} =
             Policy.new(Keyword.put(opts, :limits, wall_time_ms: 1, max_file_bytes: 1))

    assert policy.limits.wall_time_ms == 1
    assert policy.limits.max_file_bytes == 1
    assert policy.limits.cpu_seconds == 2
  end

  test "workspace must be narrow, canonical, existing, and a real directory", %{
    opts: opts,
    workspace: workspace,
    executable: executable
  } do
    for invalid <- [
          nil,
          "relative",
          "/",
          "/tmp",
          "/private/tmp",
          System.user_home!(),
          String.upcase(System.user_home!()),
          "/System/Library",
          workspace <> "/",
          workspace <> "/../workspace",
          workspace <> "//",
          workspace <> "\n"
        ] do
      assert {:error, :invalid_isolation_workspace} =
               Policy.new(Keyword.put(opts, :workspace, invalid))
    end

    assert {:error, {:filesystem, :enoent}} =
             Policy.new(Keyword.put(opts, :workspace, workspace <> "/absent"))

    assert {:error, :not_a_directory} = Policy.new(Keyword.put(opts, :workspace, executable))
  end

  test "workspace symbolic links, including an ancestor, cannot expand authority", %{
    opts: opts,
    root: root,
    workspace: workspace
  } do
    link = Path.join(root, "alias")
    File.ln_s!(workspace, link)
    File.mkdir!(Path.join(workspace, "nested"))
    assert {:error, :symlink_not_allowed} = Policy.new(Keyword.put(opts, :workspace, link))

    assert {:error, :symlink_not_allowed} =
             Policy.new(Keyword.put(opts, :workspace, link <> "/nested"))
  end

  test "case aliases cannot broaden a workspace or name a different executable", %{
    opts: opts,
    workspace: workspace,
    executable: executable
  } do
    workspace_alias = Path.join(Path.dirname(workspace), "WORKSPACE")
    command_alias = Path.join(Path.dirname(executable), "HOST-PROBE")

    if File.dir?(workspace_alias) do
      assert {:error, :non_canonical_path} =
               Policy.new(Keyword.put(opts, :workspace, workspace_alias))
    else
      assert {:error, {:filesystem, :enoent}} =
               Policy.new(Keyword.put(opts, :workspace, workspace_alias))
    end

    if File.exists?(command_alias) do
      assert {:error, :non_canonical_path} =
               Policy.new(Keyword.put(opts, :commands, [command_alias]))
    else
      assert {:error, {:filesystem, :enoent}} =
               Policy.new(Keyword.put(opts, :commands, [command_alias]))
    end
  end

  test "command authority names actual regular executable files", %{
    opts: opts,
    executable: executable,
    root: root
  } do
    for commands <- [
          nil,
          [],
          "true",
          ["true"],
          [executable, executable],
          List.duplicate(executable, 33),
          [executable | :invalid]
        ] do
      assert {:error, _} = Policy.new(Keyword.put(opts, :commands, commands))
    end

    assert {:error, :not_an_executable_file} = Policy.new(Keyword.put(opts, :commands, [root]))
    File.chmod!(executable, 0o600)
    assert {:error, :not_an_executable_file} = Policy.new(opts)
    File.chmod!(executable, 0o4700)
    assert {:error, :privileged_command_not_allowed} = Policy.new(opts)
  end

  test "symlinked or hardlinked executables are rejected", %{
    opts: opts,
    executable: executable,
    root: root
  } do
    symlink = Path.join(root, "symlink")
    hardlink = Path.join(root, "hardlink")
    File.ln_s!(executable, symlink)
    assert {:error, :symlink_not_allowed} = Policy.new(Keyword.put(opts, :commands, [symlink]))
    File.ln!(executable, hardlink)
    assert {:error, :hardlink_not_allowed} = Policy.new(Keyword.put(opts, :commands, [hardlink]))
    assert {:error, :hardlink_not_allowed} = Policy.new(opts)
  end

  test "allowlisted executable files must remain outside the writable workspace", %{
    workspace: workspace,
    opts: opts
  } do
    command = Path.join(workspace, "mutable-probe")
    File.write!(command, "could be replaced by the sandboxed child")
    File.chmod!(command, 0o700)

    assert {:error, :mutable_isolation_command} =
             Policy.new(Keyword.put(opts, :commands, [command]))
  end

  test "preflight refuses existing regular hardlink aliases without following symlinks", %{
    policy: policy,
    workspace: workspace,
    root: root
  } do
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "canary"), "host-owned canary")
    File.ln!(Path.join(outside, "canary"), Path.join(outside, "canary-alias"))
    File.ln_s!(outside, Path.join(workspace, "outside-directory"))
    File.ln_s!(Path.join(outside, "canary"), Path.join(workspace, "outside-file"))
    File.ln_s!(workspace, Path.join(workspace, "loop"))

    assert :ok = Policy.preflight(policy)

    File.mkdir!(Path.join(workspace, "nested"))
    alias_path = Path.join(workspace, "nested/hardlink")
    File.ln!(Path.join(outside, "canary"), alias_path)

    assert :ok = Policy.validate(policy)
    assert {:error, {:workspace_hardlink, "nested/hardlink"}} = Policy.preflight(policy)
    File.rm!(alias_path)
    assert :ok = Policy.preflight(policy)
  end

  test "preflight has a finite workspace entry budget independent of policy validation", %{
    root: root,
    executable: executable
  } do
    workspace = Path.join(root, "bounded-workspace")
    File.mkdir!(workspace)

    for index <- 1..10_000 do
      File.touch!(Path.join(workspace, "entry-#{index}"))
    end

    {:ok, policy} = Policy.new(workspace: workspace, commands: [executable])
    assert :ok = Policy.preflight(policy)
    File.touch!(Path.join(workspace, "one-too-many"))
    assert :ok = Policy.validate(policy)
    assert {:error, :workspace_entry_limit} = Policy.preflight(policy)
  end

  test "command selection never searches PATH or interprets a command string", %{
    policy: policy,
    executable: executable
  } do
    assert :ok =
             Policy.command(policy, executable, ["literal; $(touch outside)", "line\nbreak", ""])

    for command <- ["host-probe", "/bin/sh", executable <> " --flag", nil] do
      assert {:error, :command_not_allowed} = Policy.command(policy, command, [])
    end
  end

  test "argv is bounded and malformed terms never become shell input", %{
    policy: policy,
    executable: executable
  } do
    assert :ok = Policy.command(policy, executable, List.duplicate("x", 128))

    assert :ok =
             Policy.command(policy, executable, List.duplicate(String.duplicate("x", 4096), 4))

    for args <- [
          nil,
          "--flag",
          [nil],
          [1],
          [<<255>>],
          ["nul\0byte"],
          [String.duplicate("x", 4097)],
          List.duplicate("x", 129),
          List.duplicate(String.duplicate("x", 4096), 5),
          ["x" | :invalid]
        ] do
      assert {:error, :invalid_isolation_arguments} = Policy.command(policy, executable, args)
    end
  end

  test "persisted maps preserve exactly the inert closed schema", %{policy: policy} do
    map = Policy.to_map(policy)

    assert Map.keys(map) |> Enum.sort() ==
             Enum.sort([:schema_version, :workspace, :commands, :network, :limits])

    assert {:ok, ^policy} = Policy.from_map(map)
    assert {:ok, bytes} = Codec.encode(map)
    assert {:ok, ^map} = Codec.decode(bytes)
    assert {:error, :invalid_isolation_policy} = Policy.from_map(policy)
    assert {:error, :invalid_isolation_policy} = Policy.from_map(Map.delete(map, :network))

    assert {:error, :invalid_isolation_policy} =
             Policy.from_map(Map.put(map, :profile, "(allow default)"))

    assert {:error, {:unsupported_isolation_policy_version, 2}} =
             Policy.from_map(%{map | schema_version: 2})

    assert {:error, :invalid_isolation_limits} =
             Policy.from_map(%{map | limits: Map.put(map.limits, :memory_bytes, 1)})

    assert {:error, :unsupported_network_policy} = Policy.validate(%{policy | network: :allow})
  end

  test "dispatch rechecks policy filesystem prerequisites", %{
    policy: policy,
    executable: executable,
    workspace: workspace
  } do
    File.chmod!(executable, 0o600)
    assert {:error, :not_an_executable_file} = Policy.command(policy, executable, [])
    File.chmod!(executable, 0o700)
    File.rm_rf!(workspace)
    assert {:error, {:filesystem, :enoent}} = Policy.validate(policy)
  end

  test "profile imports only the narrow loader bootstrap and denies fork and network", %{
    policy: policy,
    private_tmp: private_tmp,
    workspace: workspace,
    executable: executable
  } do
    assert {:ok, profile} = Policy.profile(policy, private_tmp)
    assert profile =~ "(deny default)"
    assert profile =~ "(deny network*)"
    assert profile =~ "(deny process-fork)"
    assert profile =~ "(deny file-link)"

    assert profile =~
             "(import \"/System/Library/Sandbox/Profiles/dyld-support.sb\")"

    refute profile =~ "(import \"dyld-support.sb\")"
    assert profile =~ "(literal \"#{executable}\")"
    assert profile =~ "(subpath \"#{workspace}\")"
    assert profile =~ "(allow file-map-executable"
    refute profile =~ "system.sb"
    refute profile =~ "(allow default)"
    refute profile =~ "(allow network"
    refute profile =~ "(allow process-fork"
    refute profile =~ "(allow mach"
    refute profile =~ "(subpath \"/System\")"
    refute profile =~ "(subpath \"/private/tmp\")"
  end

  test "private temp grants cannot escape the workspace or follow an alias", %{
    policy: policy,
    private_tmp: private_tmp,
    workspace: workspace,
    root: root
  } do
    assert {:error, :invalid_isolation_tmp} = Policy.profile(policy, root)
    assert {:error, :invalid_isolation_tmp} = Policy.profile(policy, workspace)
    assert {:error, :invalid_isolation_tmp} = Policy.profile(policy, workspace <> "-other/tmp")
    assert {:error, :invalid_isolation_tmp} = Policy.profile(policy, workspace <> "/../elsewhere")
    File.chmod!(private_tmp, 0o755)
    assert {:error, :insecure_isolation_tmp} = Policy.profile(policy, private_tmp)
    File.chmod!(private_tmp, 0o700)
    File.ln_s!(private_tmp, Path.join(workspace, "alias"))
    assert {:error, :symlink_not_allowed} = Policy.profile(policy, Path.join(workspace, "alias"))
  end

  test "paths cannot inject sandbox syntax", %{root: root, executable: executable} do
    workspace = Path.join(root, "quoted\"workspace")
    private_tmp = Path.join(workspace, "private")
    File.mkdir_p!(private_tmp)
    File.chmod!(private_tmp, 0o700)
    assert {:ok, policy} = Policy.new(workspace: workspace, commands: [executable])
    assert {:ok, profile} = Policy.profile(policy, private_tmp)
    assert profile =~ "quoted\\\"workspace"
    refute profile =~ "quoted\"workspace"
  end
end
