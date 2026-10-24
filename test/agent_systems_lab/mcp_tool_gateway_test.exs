defmodule AgentSystemsLab.MCPToolGatewayTest do
  use ExUnit.Case, async: false

  @moduletag :seatbelt
  alias AgentSystemsLab.{Kernel, MCPFixture, RunServer}
  alias AgentSystemsLab.MCP.Policy
  alias AgentSystemsLab.Tools.{Catalog, Gateway}

  setup do
    root = Path.join("/private/tmp", "lab-mcp-gateway-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, policy} = MCPFixture.policy(root)
    %{root: root, policy: policy}
  end

  test "only host-approved schemas and arguments grant an MCP call", c do
    operation = call("echo", %{"text" => "hello"}) |> elem(1)
    assert {:error, {:tool_disabled, "mcp.fixture.echo"}} = Gateway.validate_call(operation, nil)
    assert :ok = Gateway.validate_call(operation, nil, nil, c.policy)
    assert Catalog.mcp_tool?(operation.tool)
    assert Catalog.paired_tool?(operation.tool)
    refute Enum.any?(Catalog.schemas(), &Catalog.mcp_tool?(&1["name"]))
    descriptors = Catalog.schemas(false, false, c.policy)
    assert Enum.filter(descriptors, &Catalog.mcp_tool?(&1["name"])) == Policy.schemas(c.policy)

    assert {:error, _} =
             Gateway.validate_call(%{operation | tool: "mcp.other.echo"}, nil, nil, c.policy)

    assert {:error, _} =
             Gateway.validate_call(
               %{operation | arguments: %{"text" => "hello", "policy" => %{}}},
               nil,
               nil,
               c.policy
             )

    assert {:error, :invalid_operation_id} =
             Gateway.validate_call(
               %{operation | operation_id: String.duplicate("x", 257)},
               nil,
               nil,
               c.policy
             )
  end

  test "RunServer rejects unapproved MCP tools before an intent or server launch", c do
    server =
      start_supervised!(
        {RunServer,
         run_id: "mcp-disabled-#{System.unique_integer([:positive])}",
         input: "echo",
         script: [call("echo", %{"text" => "hello"})]}
      )

    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.terminal_reason == {:tool_disabled, "mcp.fixture.echo"}
    assert failed.state.operations == %{}
    refute File.exists?(Path.join(c.root, ".mcp-trace.jsonl"))
  end

  test "RunServer advertises host authority and records a paired inert MCP receipt", c do
    server =
      start_supervised!(
        {RunServer,
         run_id: "mcp-paired-#{System.unique_integer([:positive])}",
         input: "echo",
         mcp_policy: c.policy,
         script: [call("echo", %{"text" => "paired MCP"}), {:final, "done"}]}
      )

    assert {:ok, waiting} = RunServer.step(server)
    assert waiting.state.status == :waiting_tool
    assert {:ok, executed} = RunServer.step(server)
    receipt = executed.state.operations["mcp-1"].result
    assert receipt.type == "tool_result.v1"
    assert receipt.operation_id == "mcp-1"
    assert receipt.tool == "mcp.fixture.echo"
    assert inspect(receipt.output) =~ "paired MCP"
    assert {:ok, done} = RunServer.step(server)
    [request, next_request] = done.provider.requests
    assert request.permissions.mcp == Policy.to_map(c.policy)
    assert next_request.operations["mcp-1"].result == receipt
    assert {:ok, rebuilt} = Kernel.rebuild(done.state.run_id, done.events)
    assert rebuilt == done.state
  end

  test "RunServer stays responsive and reclaims an active MCP delivery on cancellation", c do
    {:ok, policy} = MCPFixture.policy(c.root, "timeout", request_timeout_ms: 4000)

    server =
      start_supervised!(
        {RunServer,
         run_id: "mcp-cancel-#{System.unique_integer([:positive])}",
         input: "wait",
         mcp_policy: policy,
         script: [call("wait", %{"milliseconds" => 3000})]}
      )

    assert {:ok, _waiting} = RunServer.step(server)
    pending = Task.async(fn -> RunServer.step(server) end)
    worker = await_worker(server, 100)
    assert {:error, :busy} = RunServer.step(server)
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.state.status == :cancelled
    assert {:ok, reply} = Task.await(pending, 1000)
    assert reply.state == cancelled.state
    refute Process.alive?(worker)
  end

  test "an MCP worker crash records paired unknown and never consults the mock for reconciliation",
       c do
    {:ok, policy} = MCPFixture.policy(c.root, "timeout", request_timeout_ms: 4000)

    server =
      start_supervised!(
        {RunServer,
         run_id: "mcp-crash-#{System.unique_integer([:positive])}",
         input: "wait",
         mcp_policy: policy,
         script: [call("wait", %{"milliseconds" => 3000})]}
      )

    assert {:ok, _waiting} = RunServer.step(server)
    pending = Task.async(fn -> RunServer.step(server) end)
    worker = await_worker(server, 100)
    Process.exit(worker, {:injected_mcp_exit, self(), make_ref()})
    assert {:ok, blocked} = Task.await(pending, 2000)
    assert blocked.state.status == :blocked
    operation = blocked.state.operations["mcp-1"]
    assert operation.status == :unknown
    assert operation.result.operation_id == "mcp-1"
    assert operation.result.tool == "mcp.fixture.wait"
    assert operation.result.output["reason"] == "tool_worker_exit"
    assert is_binary(operation.result.output["detail"])
    assert {:ok, _encoded} = AgentSystemsLab.Storage.Codec.encode(operation.result)
    assert {:error, :reconciliation_required} = RunServer.reconcile_from_mock(server)
    assert {:error, :reconciliation_required} = RunServer.step(server)
  end

  defp await_worker(_server, 0), do: flunk("MCP worker did not start")

  defp await_worker(server, attempts) do
    case :sys.get_state(server).tool_active do
      %{task: %{pid: pid}} ->
        pid

      nil ->
        Process.sleep(5)
        await_worker(server, attempts - 1)
    end
  end

  defp call(remote, arguments),
    do: {:call, %{operation_id: "mcp-1", tool: "mcp.fixture." <> remote, arguments: arguments}}
end
