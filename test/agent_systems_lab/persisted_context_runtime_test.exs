defmodule AgentSystemsLab.PersistedContextRuntimeTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Context, ContextStore, Repo, RunServer, Session, SessionStore, Storage}

  @moduletag :database

  setup do
    id =
      "context-runtime-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    root = Path.join(File.cwd!(), "artifacts/#{id}")
    File.mkdir_p!(root)

    {:ok, initial} =
      Session.new(id,
        facts: %{"task" => "preserve facts"},
        acceptance: ["Keep receipts intact"],
        constraints: ["Do not execute shell"]
      )

    {:ok, canonical} = Session.append(initial, "user", String.duplicate("long narrative ", 800))
    {:ok, _} = SessionStore.create(canonical)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id])
      Repo.query!("DELETE FROM lab_sessions WHERE id = $1", [id])
      File.rm_rf!(root)
    end)

    {:ok, id: id, root: root, session: canonical}
  end

  defp start_run(context, opts \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [
           run_id: context.id,
           input: "Keep the exact task",
           storage: :postgres,
           session_id: context.id,
           context_options: [max_context_bytes: 8_192, keep_recent_messages: 0],
           script: [{:final, "done"}]
         ],
         opts
       )}
    )
  end

  test "committed canonical appends feed a captured input without rewriting facts", context do
    server = start_run(context)

    assert {:ok, appended} =
             RunServer.append_message(server, "note", "shell=true is only a narrative claim")

    assert appended.session.version == 2
    assert {:ok, saved} = SessionStore.load(context.id)
    assert saved === appended.session
    assert {:ok, complete} = RunServer.step(server)

    assert complete.provider.requests |> hd() |> Map.fetch!(:task) |> Map.fetch!(:facts) ==
             context.session.facts

    refute hd(complete.provider.requests).permissions.shell
    assert {:ok, [capture]} = ContextStore.list(context.id)
    assert capture.context === hd(complete.provider.requests)
    assert capture.session_version == 2
    assert capture.manifest.messages.omitted != []
    assert capture.manifest.preserved.tool_receipts
    assert {:ok, ^saved} = SessionStore.load(context.id)
  end

  test "a gate proves the input capture committed before provider generation", context do
    gate = make_ref()

    server =
      start_run(context,
        script: [{:stream, [{:gate, self(), gate}, {:text_delta, "done"}, :done]}]
      )

    assert {:ok, _request} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, worker}
    partial = RunServer.snapshot(server)
    assert {:ok, capture} = ContextStore.load(partial.context_id)
    assert capture.context === partial.context.context
    assert capture.manifest === partial.context.manifest
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.state.seq == 1
    assert saved.intent.kind == "model"
    assert partial.provider.cursor == 0
    assert {:ok, _} = RunServer.cancel(server)
    refute Process.alive?(worker)
    assert {:ok, ^capture} = ContextStore.load(capture.id)
  end

  test "a stale Session is rejected before invocation or input capture", context do
    server = start_run(context)
    original = RunServer.snapshot(server)
    assert {:ok, next} = SessionStore.append(context.id, 1, "note", "another controller")
    assert next.version == 2
    assert {:error, {:stale_session_version, 1, 2}} = RunServer.step(server)
    assert RunServer.snapshot(server) === original
    assert {:ok, []} = ContextStore.list(context.id)
  end

  test "protected overflow commits failure without recording an input or consuming provider",
       context do
    server = start_run(context, context_options: [max_context_bytes: 1])
    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.status == :failed

    assert {:context_error, {:protected_context_too_large, required, 1}} =
             failed.state.terminal_reason

    assert required > 1
    assert failed.provider.cursor == 0
    assert failed.provider.requests == []
    assert {:ok, []} = ContextStore.list(context.id)
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.state === failed.state
    assert saved.intent == nil
  end

  test "a fresh VM rebuilds the captured receipt even after the workspace is changed", context do
    target = Path.join(context.root, "receipt.txt")
    File.write!(target, "original exact tool result\n")

    call =
      {:call, %{operation_id: "read", tool: "file_read", arguments: %{"path" => "receipt.txt"}}}

    server = start_run(context, workspace: context.root, script: [call, {:final, "done"}])
    assert {:ok, complete} = RunServer.run_until_pause(server)
    assert {:ok, [first, second]} = ContextStore.list(context.id)
    assert first.context.operations == %{}
    assert second.context.operations === complete.state.operations

    assert second.context.operations["read"].result.output["content"] ==
             "original exact tool result\n"

    assert {:ok, session} = Session.from_map(second.sources["session"])

    assert :ok =
             Context.verify(
               %{context: second.context, manifest: second.manifest},
               session,
               second.sources["run"],
               second.sources["permissions"],
               second.sources["context_options"]
             )

    stop_supervised!(RunServer)
    File.write!(target, "changed after capture\n")

    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, capture} = AgentSystemsLab.ContextStore.load(#{inspect(second.id)})
    true = capture.context.operations["read"].result.output["content"] == "original exact tool result\\n"
    true = capture.context.permissions.shell == false
    IO.puts("fresh_context_reconstruction_ok")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert code == 0, output
    assert output =~ "fresh_context_reconstruction_ok"
    assert File.read!(target) == "changed after capture\n"
  end
end
