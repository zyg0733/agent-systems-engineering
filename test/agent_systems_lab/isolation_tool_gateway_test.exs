defmodule AgentSystemsLab.IsolationToolGatewayTest do
  use ExUnit.Case, async: true

  @moduletag :seatbelt

  alias AgentSystemsLab.{Kernel, RunServer}
  alias AgentSystemsLab.Isolation.Policy
  alias AgentSystemsLab.Tools.{Catalog, Gateway}

  setup do
    root =
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "lab-isolation-gateway-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, policy} = Policy.new(workspace: root, commands: ["/bin/echo"])
    %{root: root, policy: policy}
  end

  test "the isolated command schema excludes policy, environment and resource overrides", c do
    args = %{"command" => "/bin/echo", "args" => ["hello"]}
    assert :ok = Catalog.validate("sandbox_exec", args)

    for extra <- ["policy", "workspace", "network", "environment", "limits", "timeout_ms"] do
      assert {:error, {:invalid_tool_arguments, :keys}} =
               Catalog.validate("sandbox_exec", Map.put(args, extra, %{}))
    end

    for invalid <- [
          %{"command" => "echo", "args" => []},
          %{"command" => "/bin/echo", "args" => [<<0>>]},
          %{"command" => "/bin/echo", "args" => List.duplicate("a", 129)},
          %{"command" => "/bin/echo", "args" => [String.duplicate("a", 16_385)]}
        ] do
      assert {:error, {:invalid_tool_arguments, _}} = Catalog.validate("sandbox_exec", invalid)
    end

    call = %{operation_id: "exec-1", tool: "sandbox_exec", arguments: args}
    assert {:error, {:tool_disabled, "sandbox_exec"}} = Gateway.validate_call(call, nil)
    assert :ok = Gateway.validate_call(call, nil, c.policy)

    assert {:error, _} =
             Gateway.validate_call(
               %{call | arguments: %{args | "command" => "/bin/sh"}},
               nil,
               c.policy
             )

    refute "sandbox_exec" in Enum.map(Catalog.schemas(true), & &1["name"])
    assert "sandbox_exec" in Enum.map(Catalog.schemas(false, true), & &1["name"])
  end

  test "RunServer rejects a model command without host authority before intent creation", c do
    server =
      start_supervised!(
        {RunServer,
         run_id: "isolation-disabled-#{System.unique_integer([:positive])}",
         input: "execute",
         script: [call("/bin/echo", ["hello"])]}
      )

    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.terminal_reason == {:tool_disabled, "sandbox_exec"}
    assert failed.state.operations == %{}
    refute File.exists?(Path.join(c.root, "unauthorized"))
  end

  test "RunServer advertises immutable policy and carries a paired isolated receipt", c do
    server =
      start_supervised!(
        {RunServer,
         run_id: "isolation-enabled-#{System.unique_integer([:positive])}",
         input: "execute",
         isolation_policy: c.policy,
         script: [call("/bin/echo", ["isolated receipt"]), {:final, "done"}]}
      )

    assert {:ok, waiting} = RunServer.step(server)
    assert waiting.state.status == :waiting_tool
    assert {:ok, executed} = RunServer.step(server)
    receipt = executed.state.operations["exec-1"].result
    assert receipt.type == "tool_result.v1"
    assert receipt.operation_id == "exec-1"
    assert receipt.tool == "sandbox_exec"
    assert receipt.output.status == :succeeded
    assert receipt.output.output == "isolated receipt\n"
    assert {:ok, done} = RunServer.step(server)
    [request, next_request] = done.provider.requests
    assert request.permissions.isolation == Policy.to_map(c.policy)
    assert next_request.operations["exec-1"].result == receipt
    assert {:ok, rebuilt} = Kernel.rebuild(done.state.run_id, done.events)
    assert rebuilt == done.state
  end

  test "RunServer remains cancellable while an isolated tool is executing", c do
    {:ok, policy} = Policy.new(workspace: c.root, commands: ["/bin/sleep"])

    server =
      start_supervised!(
        {RunServer,
         run_id: "isolation-cancel-#{System.unique_integer([:positive])}",
         input: "execute",
         isolation_policy: policy,
         script: [call("/bin/sleep", ["5"])]}
      )

    assert {:ok, _} = RunServer.step(server)
    step = Task.async(fn -> RunServer.step(server) end)
    worker = await_tool_worker(server, 100)
    assert Process.alive?(worker)
    assert {:error, :busy} = RunServer.step(server)
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.state.status == :cancelled
    assert {:ok, same} = Task.await(step, 1000)
    assert same.state == cancelled.state
    refute Process.alive?(worker)
    assert cancelled.state.operations["exec-1"].result == nil
  end

  test "RunServer absolute deadline reclaims an isolated tool and resolves its waiting step", c do
    {:ok, policy} = Policy.new(workspace: c.root, commands: ["/bin/sleep"])

    server =
      start_supervised!(
        {RunServer,
         run_id: "isolation-run-timeout-#{System.unique_integer([:positive])}",
         input: "execute",
         run_timeout_ms: 250,
         isolation_policy: policy,
         script: [call("/bin/sleep", ["5"])]}
      )

    assert {:ok, _} = RunServer.step(server)
    step = Task.async(fn -> RunServer.step(server) end)
    worker = await_tool_worker(server, 100)
    assert {:ok, failed} = Task.await(step, 2000)
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:budget_exceeded, :run_timeout}
    assert failed.state.operations["exec-1"].result == nil
    refute Process.alive?(worker)
  end

  defp await_tool_worker(_server, 0), do: flunk("isolated tool did not start")

  defp await_tool_worker(server, attempts) do
    case :sys.get_state(server).tool_active do
      %{task: %{pid: pid}} ->
        pid

      nil ->
        Process.sleep(5)
        await_tool_worker(server, attempts - 1)
    end
  end

  defp call(command, args),
    do:
      {:call,
       %{
         operation_id: "exec-1",
         tool: "sandbox_exec",
         arguments: %{"command" => command, "args" => args}
       }}
end

defmodule AgentSystemsLab.IsolationFailClosedTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Isolation
  alias AgentSystemsLab.Isolation.Policy

  test "unsupported platforms and backends never invoke the trusted executable or start callback" do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(base, "lab-isolation-unavailable-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    executable = Path.join(root, "trusted-fixture")
    marker = Path.join(workspace, "unexpected-launch")
    File.mkdir_p!(workspace)
    File.write!(executable, "#!/bin/sh\nprintf 'unexpected launch\\n' > \"$1\"\n")
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, policy} = Policy.new(workspace: workspace, commands: [executable])
    ref = make_ref()
    callback = fn _handle -> send(self(), {:unexpected_start, ref}) end

    assert {:error, :unsupported_isolation_backend} =
             Isolation.execute(executable, [marker], policy,
               backend: :unsupported,
               on_start: callback
             )

    if :os.type() != {:unix, :darwin} do
      assert {:error, :unsupported_isolation_backend} =
               Isolation.execute(executable, [marker], policy, on_start: callback)

      refute Isolation.capabilities().available
    end

    refute_receive {:unexpected_start, ^ref}, 20
    refute File.exists?(marker)
    assert File.ls!(workspace) == []
  end
end
