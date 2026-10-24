defmodule AgentSystemsLab.IsolationTest do
  use ExUnit.Case, async: false

  @moduletag :seatbelt

  alias AgentSystemsLab.Isolation
  alias AgentSystemsLab.Isolation.Policy

  setup do
    root = "/private/tmp/lab-executor-#{System.unique_integer([:positive])}"
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, policy} = Policy.new(workspace: workspace, commands: ["/bin/echo"])
    %{root: root, workspace: workspace, policy: policy}
  end

  test "unknown backend and unknown host options reject before any start", c do
    callback = fn _ -> send(self(), :started) end

    assert {:error, :unsupported_isolation_backend} =
             Isolation.execute("/bin/echo", [], c.policy,
               backend: :unsupported,
               on_start: callback
             )

    for opts <- [
          [environment: %{}],
          [on_start: nil],
          [backend: :seatbelt, backend: :seatbelt],
          [deadline_monotonic_ms: "late"]
        ] do
      assert {:error, :invalid_isolation_options} =
               Isolation.execute("/bin/echo", [], c.policy, opts)
    end

    refute_receive :started
    assert File.ls!(c.workspace) == []
    assert {:error, :invalid_execution_handle} = Isolation.cancel(%{})
  end

  test "a workspace cannot grant write access to the executor cache or source" do
    root = Path.expand("../..", __DIR__)
    {:ok, policy} = Policy.new(workspace: root, commands: ["/bin/echo"])
    assert {:error, :workspace_overlaps_executor} = Isolation.execute("/bin/echo", [], policy)

    # A grant below the runtime would expose other invocations' private profiles.
    assert {:error, :protected_path} =
             Policy.new(
               workspace: Path.join(root, ".runtime/isolation/control"),
               commands: ["/bin/echo"]
             )

    workspace = Path.join(root, "priv/isolation")
    {:ok, policy} = Policy.new(workspace: workspace, commands: ["/bin/echo"])
    assert {:error, :workspace_overlaps_executor} = Isolation.execute("/bin/echo", [], policy)
  end

  test "expired absolute host deadline never starts and removes private launch files", c do
    assert {:error, :isolation_deadline_expired} =
             Isolation.execute("/bin/echo", [], c.policy,
               deadline_monotonic_ms: System.monotonic_time(:millisecond) - 1,
               on_start: fn _ -> flunk("expired command started") end
             )

    assert File.ls!(c.workspace) == []
  end

  test "target stdout cannot spoof trusted guardian result or cleanup frames", c do
    fake = <<2, 0, 0, 0, 2>> <> "{}"
    # argv forbids NUL, so use printable, plausible control JSON as hostile data.
    assert {:error, :invalid_isolation_arguments} =
             Isolation.execute("/bin/echo", [fake], c.policy)

    fake = ~s({"reason":"cancelled","target_pid":1,"target_exited":false})
    assert {:ok, result} = Isolation.execute("/bin/echo", [fake], c.policy)
    assert result.status == :succeeded
    assert result.output == fake <> "\n"
    assert result.target_pid > 1
    assert result.cleanup.target_exited
    assert result.cleanup.guardian_exited
    assert File.ls!(c.workspace) == []
  end

  test "a workspace loader profile cannot replace the absolute system bootstrap", c do
    outside = Path.join(c.root, "outside-canary")
    canary = "outside-policy-" <> Base.encode16(:crypto.strong_rand_bytes(24))
    File.write!(outside, canary)

    File.write!(
      Path.join(c.workspace, "dyld-support.sb"),
      "(version 1)\n(allow default)\n(allow file-read*)\n(allow file-write*)\n"
    )

    inside = Path.join(c.workspace, "controlled.txt")
    File.write!(inside, "controlled fixture\n")
    {:ok, policy} = Policy.new(workspace: c.workspace, commands: ["/bin/cat"])

    assert {:ok, allowed} = Isolation.execute("/bin/cat", [inside], policy)
    assert allowed.status == :succeeded
    assert allowed.output == "controlled fixture\n"
    assert {:ok, blocked} = Isolation.execute("/bin/cat", [outside], policy)
    assert blocked.status == :failed
    assert blocked.exit_status != 0
    refute String.contains?(blocked.output, canary)
    assert File.read!(outside) == canary
  end

  test "the target receives only a fixed environment and no stdin authority", c do
    {:ok, policy} = Policy.new(workspace: c.workspace, commands: ["/usr/bin/env"])
    key = "LAB_ISOLATION_INHERIT_TEST"
    previous = System.get_env(key)
    System.put_env(key, "owned-test-value")

    try do
      assert {:ok, result} = Isolation.execute("/usr/bin/env", [], policy)
      assert result.status == :succeeded
      lines = result.output |> String.split("\n", trim: true) |> Enum.sort()
      assert length(lines) == 4
      assert "LANG=C" in lines
      assert "LC_ALL=C" in lines
      assert "PATH=/usr/bin:/bin" in lines
      assert Enum.any?(lines, &String.starts_with?(&1, "TMPDIR=" <> c.workspace <> "/"))
      refute String.contains?(result.output, key)
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end

  test "a host callback exception cancels and awaits the owned native processes", c do
    {:ok, policy} = Policy.new(workspace: c.workspace, commands: ["/bin/sleep"])
    parent = self()

    assert_raise RuntimeError, "owned callback failure", fn ->
      Isolation.execute("/bin/sleep", ["10"], policy,
        on_start: fn handle ->
          send(parent, {:handle, handle})
          raise "owned callback failure"
        end
      )
    end

    assert_receive {:handle, handle}

    for pid <- [handle.os_pid, handle.target_pid] do
      {_out, status} = System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true)
      assert status != 0
    end

    assert File.ls!(c.workspace) == []
    assert {:error, :execution_closed} = Isolation.cancel(handle)
  end

  test "native wall timer completes while a trusted start callback blocks", c do
    {:ok, policy} =
      Policy.new(workspace: c.workspace, commands: ["/bin/sleep"], limits: [wall_time_ms: 100])

    assert {:ok, result} =
             Isolation.execute("/bin/sleep", ["10"], policy,
               on_start: fn _ -> Process.sleep(250) end
             )

    assert result.status == :timed_out
    assert result.duration_ms < 250
    assert result.cleanup.process_group_gone
  end
end
