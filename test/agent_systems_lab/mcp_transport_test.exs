defmodule AgentSystemsLab.MCPTransportTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{MCP, MCPFixture}
  alias AgentSystemsLab.MCP.{Connection, Stdio}

  @moduletag :seatbelt

  setup do
    workspace = "/private/tmp/asl-mcp-test-#{System.unique_integer([:positive])}"
    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "initialize, initialized, discovery and call are paired over real stdio", %{
    workspace: root
  } do
    {:ok, policy} = MCPFixture.policy(root)
    parent = self()

    assert {:ok, result} =
             MCP.execute(policy, "mcp.fixture.echo", %{"text" => "你好\nMCP"},
               on_request: fn metadata -> send(parent, {:request, self(), metadata}) end
             )

    assert [%{"type" => "text", "text" => "你好\nMCP"}] = result["content"]
    assert result["isError"] == false
    assert result["transport"]["target_exited"]
    assert result["transport"]["guardian_exited"]
    assert result["transport"]["process_group_gone"]
    assert_receive {:request, ^parent, metadata}
    assert metadata["request_id"] == result["mcp"]["request_id"]
    phases = Enum.map(trace(root), & &1["phase"])
    assert phases == ["start", "initialize", "initialized", "list", "call", "eof"]
    assert_dead(result["transport"]["target_pid"])
    assert_dead(result["transport"]["guardian_pid"])
  end

  for mode <- ~w(pages fragment stderr notification ping reverse_request) do
    test "#{mode} preserves framing and tool results", %{workspace: root} do
      {:ok, policy} = MCPFixture.policy(root, unquote(mode))
      assert {:ok, result} = MCP.execute(policy, "mcp.fixture.echo", %{"text" => unquote(mode)})
      assert hd(result["content"])["text"] == unquote(mode)
      assert result["transport"]["target_exited"]

      if unquote(mode) == "ping",
        do: assert(Enum.any?(trace(root), &(&1["phase"] == "client_response")))

      if unquote(mode) == "reverse_request",
        do: assert(Enum.any?(trace(root), &(&1["phase"] == "client_error")))
    end
  end

  for mode <- ~w(duplicate cursor_loop schema_drift version_mismatch no_tools bad_initialize) do
    test "#{mode} fails before any tools/call", %{workspace: root} do
      {:ok, policy} = MCPFixture.policy(root, unquote(mode))
      assert {:error, _} = MCP.execute(policy, "mcp.fixture.echo", %{"text" => "never"})
      refute Enum.any?(trace(root), &(&1["phase"] == "call"))
      assert Enum.count(trace(root), &(&1["phase"] == "start")) == 1
    end
  end

  for mode <- ~w(malformed wrong_id disconnect oversized) do
    test "#{mode} after dispatch is unknown without reconnect or replay", %{workspace: root} do
      {:ok, policy} = MCPFixture.policy(root, unquote(mode))
      assert {:unknown, details} = MCP.execute(policy, "mcp.fixture.echo", %{"text" => "one"})
      assert details["type"] == "mcp_unknown"
      assert is_binary(details["request_id"])
      assert details["transport"]["target_exited"]
      assert Enum.count(trace(root), &(&1["phase"] == "call")) == 1
      assert Enum.count(trace(root), &(&1["phase"] == "start")) == 1
    end
  end

  test "tool isError remains a paired result while JSON-RPC error is distinct", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root)

    assert {:error, %{"type" => "mcp_tool_error", "isError" => true} = tool_error} =
             MCP.execute(policy, "mcp.fixture.tool_error", %{})

    assert tool_error["content"] == [%{"type" => "text", "text" => "fixture tool failed"}]
    assert tool_error["mcp"]["server_name"] == "fixture"
    assert is_binary(tool_error["mcp"]["request_id"])
    assert tool_error["transport"]["target_exited"]

    assert {:error, %{"type" => "mcp_rpc_error", "code" => -32602, "transport" => cleanup}} =
             MCP.execute(policy, "mcp.fixture.rpc_error", %{})

    assert cleanup["target_exited"]
    assert Enum.count(trace(root), &(&1["phase"] == "call")) == 2
  end

  test "timeout sends the matching cancellation and never retries", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root, "timeout", request_timeout_ms: 50)

    assert {:unknown, %{"reason" => "timeout"} = details} =
             MCP.execute(policy, "mcp.fixture.echo", %{"text" => "one"})

    [call] = Enum.filter(trace(root), &(&1["phase"] == "call"))
    [cancel] = Enum.filter(trace(root), &(&1["phase"] == "cancelled"))
    assert call["request_id"] == cancel["request_id"]
    assert details["request_id"] == call["request_id"]
    assert details["transport"]["target_exited"]
  end

  test "late reply after timeout is ignored and the session cannot issue another call", %{
    workspace: root
  } do
    {:ok, policy} = MCPFixture.policy(root, "late_reply", request_timeout_ms: 40)
    {:ok, connection} = Connection.start_link(policy)
    assert {:ok, _} = Connection.discover(connection)

    assert {:unknown, %{"reason" => "timeout"}} =
             Connection.call_tool(connection, "echo", %{"text" => "one"})

    Process.sleep(230)
    assert Connection.status(connection).phase == :tainted

    assert {:error, :mcp_discovery_required} =
             Connection.call_tool(connection, "echo", %{"text" => "two"})

    assert {:ok, cleanup} = Connection.close(connection)
    assert cleanup["target_exited"]
    GenServer.stop(connection)
    assert Enum.count(trace(root), &(&1["phase"] == "call")) == 1
  end

  test "explicit cancellation stays responsive while the caller hook is blocked", %{
    workspace: root
  } do
    {:ok, policy} = MCPFixture.policy(root, "timeout")
    {:ok, connection} = Connection.start_link(policy)
    assert {:ok, _} = Connection.discover(connection)
    parent = self()

    task =
      Task.async(fn ->
        Connection.call_tool(connection, "echo", %{"text" => "cancel"},
          on_request: fn metadata ->
            send(parent, {:sent, self(), metadata})

            receive do
              :continue -> :ok
            end
          end
        )
      end)

    assert_receive {:sent, caller, metadata}, 1000
    assert Connection.status(connection).request_id == metadata["request_id"]
    assert :ok = Connection.cancel(connection)
    send(caller, :continue)
    assert {:unknown, %{"reason" => "cancelled"}} = Task.await(task)
    assert {:ok, _} = Connection.close(connection)
    GenServer.stop(connection)
    assert Enum.any?(trace(root), &(&1["phase"] == "cancelled"))
  end

  test "discovery does not grant unapproved names or invalid argument schemas", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root, "normal", tools: ["echo"])
    {:ok, connection} = Connection.start_link(policy)
    assert {:ok, tools} = Connection.discover(connection)
    assert length(tools) == 5

    assert {:error, :mcp_tool_not_allowed} =
             Connection.call_tool(connection, "write_note", %{
               "path" => "no",
               "content" => "never"
             })

    assert {:error, _} = Connection.call_tool(connection, "echo", %{"text" => 1})
    assert {:ok, _} = Connection.close(connection)
    GenServer.stop(connection)
    refute File.exists?(Path.join(root, "no"))
    refute Enum.any?(trace(root), &(&1["phase"] == "call"))
  end

  test "list_changed invalidates discovery without changing host grants", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root, "list_changed", tools: ["echo"])
    {:ok, connection} = Connection.start_link(policy)
    assert {:ok, _} = Connection.discover(connection)
    assert eventually(fn -> Connection.status(connection).tools == nil end)

    assert {:error, :mcp_discovery_required} =
             Connection.call_tool(connection, "echo", %{"text" => "never"})

    assert {:ok, _} = Connection.close(connection)
    GenServer.stop(connection)
    refute Enum.any?(trace(root), &(&1["phase"] == "call"))
  end

  test "a killed caller cancels its in-flight call even when connection owner survives", %{
    workspace: root
  } do
    {:ok, policy} = MCPFixture.policy(root, "timeout")
    {:ok, connection} = Connection.start_link(policy)
    assert {:ok, _} = Connection.discover(connection)
    parent = self()

    caller =
      spawn(fn ->
        Connection.call_tool(connection, "echo", %{"text" => "one"},
          on_request: fn _ ->
            send(parent, :sent)

            receive do
              :never -> :ok
            end
          end
        )
      end)

    assert_receive :sent, 1000
    status = Connection.status(connection)
    Process.exit(caller, :kill)
    assert eventually(fn -> Connection.status(connection).phase == :closed end)
    assert_dead(status.target_pid)
    assert_dead(status.os_pid)
    GenServer.stop(connection)
    assert Enum.count(trace(root), &(&1["phase"] == "call")) == 1
  end

  test "owner death cleans the native target and guardian", %{workspace: root} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, policy} = MCPFixture.policy(root, "timeout")
        {:ok, connection} = Connection.start_link(policy)
        {:ok, _} = Connection.discover(connection)
        send(parent, {:owned, Connection.status(connection)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:owned, status}, 2000
    Process.exit(owner, :kill)
    assert eventually(fn -> dead?(status.target_pid) and dead?(status.os_pid) end)
  end

  test "caller mailbox and effect-after-disconnect are preserved", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root, "after_effect_drop")
    send(self(), {:unrelated, 42})

    assert {:unknown, _} =
             MCP.execute(policy, "mcp.fixture.write_note", %{
               "path" => "once",
               "content" => "effect"
             })

    assert_receive {:unrelated, 42}
    assert File.read!(Path.join(root, "once")) == "effect"
    assert Enum.count(trace(root), &(&1["phase"] == "effect")) == 1
  end

  test "expired host deadline and invalid options fail before server entry", %{workspace: root} do
    {:ok, policy} = MCPFixture.policy(root)

    assert {:error, :mcp_deadline_expired} =
             MCP.execute(policy, "mcp.fixture.echo", %{"text" => "never"},
               deadline_monotonic_ms: System.monotonic_time(:millisecond) - 1
             )

    assert {:error, :invalid_mcp_options} =
             MCP.execute(policy, "mcp.fixture.echo", %{"text" => "never"}, env: %{})

    assert trace(root) == []
  end

  test "private native framing refuses spoofed controls and oversized frames" do
    transport = %{buffer: <<>>, os_pid: 123, ready: nil, final: nil}

    payload =
      JSON.encode!(%{
        "guardian_pid" => 456,
        "target_pid" => 8,
        "profile_applied" => true,
        "exec_acknowledged" => true
      })

    assert {:error, :invalid_mcp_guardian_ready} =
             Stdio.ingest(transport, <<0, byte_size(payload)::32, payload::binary>>)

    assert {:error, :invalid_mcp_guardian_frame} = Stdio.ingest(transport, <<1, 8193::32>>)
  end

  defp trace(root) do
    case File.read(Path.join(root, ".mcp-trace.jsonl")) do
      {:ok, text} -> String.split(text, "\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp assert_dead(pid), do: assert(eventually(fn -> dead?(pid) end))

  defp dead?(pid) do
    {_text, status} = System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status != 0
  end

  defp eventually(fun, attempts \\ 150)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
