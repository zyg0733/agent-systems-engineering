defmodule AgentSystemsLab.PersistedToolsTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Kernel, Repair, Repo, RunServer, Storage}

  @moduletag :database

  setup do
    id =
      "persisted-tools-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    root = Path.join(File.cwd!(), "artifacts/#{id}")
    File.mkdir_p!(root)
    {:ok, _} = File.cp_r(Repair.fixture_dir(), Path.join(root, "workspace"))

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id])
      File.rm_rf!(root)
    end)

    {:ok, id: id, root: root, workspace: Path.join(root, "workspace")}
  end

  defp start_run(context, script, opts \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [
           run_id: context.id,
           input: "Repair a private fixture",
           storage: :postgres,
           workspace: context.workspace,
           script: script
         ],
         opts
       )}
    )
  end

  defp call(id, tool, arguments),
    do: {:call, %{operation_id: id, tool: tool, arguments: arguments}}

  test "paired read/patch/write results persist and a new VM reads without executing tools",
       context do
    server = start_run(context, Repair.script(Repair.fixture_source()))
    assert {:ok, completed} = RunServer.run_until_pause(server)
    assert completed.state.status == :succeeded
    assert completed.file_stats == %{requests: 3, reads: 1, writes: 2}
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.state == completed.state
    assert saved.events == completed.events
    assert saved.intent == nil
    assert Kernel.rebuild(context.id, saved.events) == {:ok, saved.state}

    for {id, operation} <- completed.state.operations do
      assert operation.result.operation_id == id
      assert operation.result.tool == operation.tool
    end

    stop_supervised!(RunServer)

    target = Path.join(context.workspace, "lib/shipping.ex")
    File.write!(target, "external change after repair\n")

    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, saved} = AgentSystemsLab.Storage.load(#{inspect(context.id)})
    true = saved.state.status == :succeeded
    true = saved.intent == nil
    true = map_size(saved.state.operations) == 3
    IO.puts("fresh_vm_tools_ok")
    """

    assert_fresh_vm(script)
    assert File.read!(target) == "external change after repair\n"
  end

  test "a rejected file schema creates no tool intent or filesystem request", context do
    server =
      start_run(context, [
        call("invalid-schema", "file_write", %{"path" => "new.txt", "content" => "no hash"})
      ])

    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.status == :failed
    assert failed.state.operations == %{}
    assert failed.file_stats.requests == 0
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.intent == nil
    assert Enum.map(saved.events, & &1.type) == [:run_started, :run_failed]
    refute File.exists?(Path.join(context.workspace, "new.txt"))
  end

  test "wrong embedded call ID or tool cannot commit a result", context do
    server = start_run(context, [call("read", "file_read", %{"path" => "lib/shipping.ex"})])
    assert {:ok, planned} = RunServer.step(server)
    assert {:ok, saved} = Storage.load(context.id)

    for {id, tool} <- [{"other-id", "file_read"}, {"read", "file_write"}] do
      payload = %{type: "tool_result.v1", operation_id: id, tool: tool, output: %{}}
      assert {:error, _} = RunServer.command(server, {:tool_result, "read", {:ok, payload}})
      assert RunServer.snapshot(server) == planned
      assert {:ok, ^saved} = Storage.load(context.id)
    end

    assert {:ok, read} = RunServer.step(server)
    assert read.state.operations["read"].status == :ok
    assert {:ok, _} = Storage.load(context.id)
  end

  test "cancellation after a committed write intent leaves its target absent", context do
    server =
      start_run(context, [
        call("create", "file_write", %{
          "path" => "never.txt",
          "content" => "never",
          "expected_sha256" => "absent"
        })
      ])

    assert {:ok, planned} = RunServer.step(server)
    assert planned.file_stats.writes == 0
    assert {:ok, %{intent: %{kind: "tool"}}} = Storage.load(context.id)
    assert {:ok, cancelled} = RunServer.cancel(server, "before file effect")
    assert {:error, {:not_runnable, :cancelled}} = RunServer.step(server)
    assert cancelled.file_stats.requests == 0
    refute File.exists?(Path.join(context.workspace, "never.txt"))
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.state == cancelled.state
    assert saved.intent == nil
  end

  test "a stale persisted owner cannot perform an accepted file write", context do
    server =
      start_run(context, [
        call("create", "file_write", %{
          "path" => "stale.txt",
          "content" => "stale",
          "expected_sha256" => "absent"
        })
      ])

    assert {:ok, planned} = RunServer.step(server)

    assert {:ok, cancelled} =
             Storage.dispatch(context.id, planned.state.seq, {:cancel, "other owner"})

    assert {:error, {:stale_sequence, 2, 3}} = RunServer.step(server)
    assert RunServer.snapshot(server).file_stats.writes == 0
    refute File.exists?(Path.join(context.workspace, "stale.txt"))
    assert {:ok, ^cancelled} = Storage.load(context.id)
  end

  test "a file changed after proposal returns a paired durable error and remains unchanged",
       context do
    [_, patch | _] = Repair.script(Repair.fixture_source())
    server = start_run(context, [patch])
    assert {:ok, _} = RunServer.step(server)
    target = Path.join(context.workspace, "lib/shipping.ex")
    File.write!(target, "changed by workspace owner\n")
    assert {:ok, result} = RunServer.step(server)
    operation = result.state.operations["patch-shipping"]
    assert operation.status == :error
    assert operation.result.operation_id == "patch-shipping"
    assert operation.result.output == :base_mismatch
    assert result.file_stats.writes == 0
    assert File.read!(target) == "changed by workspace owner\n"
    assert {:ok, saved} = Storage.load(context.id)
    assert saved.state == result.state
    assert saved.intent.kind == "model"
    assert {:ok, _} = RunServer.cancel(server)
    stop_supervised!(RunServer)

    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, saved} = AgentSystemsLab.Storage.load(#{inspect(context.id)})
    true = inspect(saved.state.operations["patch-shipping"].result.output) == ":base_mismatch"
    IO.puts("fresh_vm_tools_ok")
    """

    assert_fresh_vm(script)
  end

  defp assert_fresh_vm(script) do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert code == 0, output
    assert output =~ "fresh_vm_tools_ok"
  end
end
