defmodule AgentSystemsLab.RunServerFilesTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Kernel, RunServer}
  alias AgentSystemsLab.Tools.{Files, Gateway, Mock, Result}

  setup do
    root =
      Path.join([
        File.cwd!(),
        "artifacts",
        "test-workspaces",
        "gateway-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, workspace: root}
  end

  defp call(id, tool, arguments),
    do: {:call, %{operation_id: id, tool: tool, arguments: arguments}}

  defp start_run(context, script, extra \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [
           run_id: Atom.to_string(context.test),
           input: "repair",
           script: script,
           workspace: context.workspace
         ],
         extra
       )}
    )
  end

  test "read returns a paired envelope in the next provider context", context do
    server =
      start_run(context, [
        call("read-1", "file_read", %{"path" => "source.txt"}),
        {:final, "done"}
      ])

    assert {:ok, intent} = RunServer.step(server)
    assert intent.file_stats == %{requests: 0, reads: 0, writes: 0}
    assert {:ok, read} = RunServer.step(server)
    envelope = read.state.operations["read-1"].result
    assert envelope.type == "tool_result.v1"
    assert envelope.operation_id == "read-1"
    assert envelope.tool == "file_read"
    assert envelope.output["content"] == "before\n"
    assert {:ok, done} = RunServer.step(server)
    [first, second] = done.provider.requests
    assert first.input == "repair"

    assert Enum.map(first.available_tools, & &1["name"]) ==
             ~w(mock_write file_read file_write file_patch)

    assert second.operations["read-1"].result == envelope
    assert done.file_stats == %{requests: 1, reads: 1, writes: 0}
    assert done.tool_stats == %{requests: 0, effects: 0}
    assert Kernel.rebuild(done.state.run_id, done.events) == {:ok, done.state}
  end

  test "streamed JSON becomes one validated tool intent and one paired result", context do
    json =
      JSON.encode!(%{
        "path" => "new.txt",
        "content" => "created\n",
        "expected_sha256" => "absent"
      })

    split = div(byte_size(json), 2)
    <<first::binary-size(^split), second::binary>> = json

    script = [
      {:stream,
       [
         {:tool_start, %{operation_id: "write-1", tool: "file_write"}},
         {:arguments_delta, first},
         {:arguments_delta, second},
         :done
       ]},
      {:final, "done"}
    ]

    server = start_run(context, script)
    assert {:ok, intent} = RunServer.step(server)
    refute File.exists?(Path.join(context.workspace, "new.txt"))
    assert intent.state.status == :waiting_tool
    assert {:ok, written} = RunServer.step(server)
    assert File.read!(Path.join(context.workspace, "new.txt")) == "created\n"
    assert written.state.operations["write-1"].result.tool == "file_write"
    assert written.file_stats == %{requests: 1, reads: 0, writes: 1}
  end

  test "cancelled planned file write has no effect", context do
    server =
      start_run(context, [
        call("write-1", "file_write", %{
          "path" => "new.txt",
          "content" => "no",
          "expected_sha256" => "absent"
        })
      ])

    assert {:ok, _intent} = RunServer.step(server)
    assert {:ok, cancelled} = RunServer.cancel(server, "stop")
    assert {:error, {:not_runnable, :cancelled}} = RunServer.step(server)
    refute File.exists?(Path.join(context.workspace, "new.txt"))
    assert cancelled.file_stats == %{requests: 0, reads: 0, writes: 0}
    assert cancelled.state.operations["write-1"].status == :pending
  end

  test "cancellation during arguments cannot authorize a file call", context do
    ref = make_ref()

    script = [
      {:stream,
       [
         {:tool_start, %{operation_id: "write-1", tool: "file_write"}},
         {:arguments_delta, "{"},
         {:gate, self(), ref},
         {:arguments_delta, "}"},
         :done
       ]}
    ]

    server = start_run(context, script)
    assert {:ok, _request} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^ref, _worker}
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.state.operations == %{}
    assert cancelled.file_stats == %{requests: 0, reads: 0, writes: 0}
  end

  test "invalid completed provider schema fails before creating intent", context do
    server =
      start_run(context, [
        call("write-1", "file_write", %{"path" => "new.txt", "content" => "no"})
      ])

    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:invalid_tool_arguments, :keys}
    assert failed.state.operations == %{}
    assert Enum.map(failed.events, & &1.type) == [:run_started, :run_failed]
    assert failed.file_stats == %{requests: 0, reads: 0, writes: 0}
    refute File.exists?(Path.join(context.workspace, "new.txt"))
  end

  test "file tools require a configured workspace and are absent from its catalog", context do
    opts = [
      run_id: Atom.to_string(context.test),
      input: "repair",
      script: [call("read-1", "file_read", %{"path" => "source.txt"})]
    ]

    server = start_supervised!({RunServer, opts})
    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.terminal_reason == {:tool_disabled, "file_read"}
    assert failed.state.operations == %{}
    assert failed.file_stats == nil
    assert Enum.map(hd(failed.provider.requests).available_tools, & &1["name"]) == ["mock_write"]
  end

  test "invalid external model commands leave snapshots and budgets unchanged", context do
    server = start_run(context, [])
    before = RunServer.snapshot(server)

    assert {:error, {:invalid_tool_arguments, :keys}} =
             RunServer.command(
               server,
               {:model_response, call("read-1", "file_read", %{path: "source.txt"})}
             )

    assert RunServer.snapshot(server) == before
  end

  test "mismatched external result IDs and tools leave the pending call unchanged", context do
    server = start_run(context, [call("read-1", "file_read", %{"path" => "source.txt"})])
    assert {:ok, before} = RunServer.step(server)
    wrong = Result.wrap({:ok, "fake"}, "read-1", "file_write")

    for payload <- [
          "legacy payload",
          %{type: "tool_result.v2", operation_id: "read-1", tool: "file_read", output: "fake"}
        ] do
      assert {:error, {:invalid_tool_result_envelope, "read-1", "file_read"}} =
               RunServer.command(server, {:tool_result, "read-1", {:ok, payload}})
    end

    assert {:error, {:invalid_tool_result_envelope, "read-1", "file_read"}} =
             RunServer.command(server, {:tool_result, "read-1", wrong})

    assert {:error, {:unexpected_operation_id, "read-1", "other"}} =
             RunServer.command(server, {:tool_result, "other", wrong})

    assert RunServer.snapshot(server) == before
    assert {:ok, done} = RunServer.step(server)
    assert done.state.operations["read-1"].result.output["content"] == "before\n"
  end

  test "new runtime reconciliation requires a file result envelope", context do
    server = start_run(context, [call("read-1", "file_read", %{"path" => "source.txt"})])
    assert {:ok, _intent} = RunServer.step(server)
    unknown = Result.wrap({:unknown, "uncertain"}, "read-1", "file_read")
    assert {:ok, blocked} = RunServer.command(server, {:tool_result, "read-1", unknown})
    assert blocked.state.status == :blocked

    assert {:error, {:invalid_tool_result_envelope, "read-1", "file_read"}} =
             RunServer.command(server, {:reconcile, "read-1", {:error, "unwrapped"}})

    assert RunServer.snapshot(server) == blocked
    confirmed = Result.wrap({:error, "confirmed absent"}, "read-1", "file_read")
    assert {:ok, running} = RunServer.command(server, {:reconcile, "read-1", confirmed})
    assert running.state.status == :running
    assert running.state.operations["read-1"].result.output == "confirmed absent"
  end

  test "gateway validates again before entering the file executor", context do
    {:ok, files} = Files.new(context.workspace)
    mock = start_supervised!({Mock, []})

    operation = %{
      operation_id: "write-1",
      tool: "file_write",
      arguments: %{"path" => "new.txt", "content" => "no"}
    }

    assert {{:error, envelope}, ^files} = Gateway.execute(files, mock, operation, :ok)
    assert envelope.operation_id == "write-1"
    assert envelope.output == {:invalid_tool_arguments, :keys}
    assert Files.stats(files) == %{requests: 0, reads: 0, writes: 0}
    refute File.exists?(Path.join(context.workspace, "new.txt"))
  end

  test "unknown tool preserves a controlled legacy result and advances safely", context do
    server = start_run(context, [call("other-1", "unavailable", %{}), {:final, "cannot execute"}])
    assert {:ok, _intent} = RunServer.step(server)
    assert {:ok, result} = RunServer.step(server)
    assert result.state.operations["other-1"].status == :error
    assert result.state.operations["other-1"].result == {:unsupported_tool, "unavailable"}
    assert {:ok, done} = RunServer.step(server)
    assert done.state.status == :succeeded
    assert done.file_stats == %{requests: 0, reads: 0, writes: 0}
  end
end
