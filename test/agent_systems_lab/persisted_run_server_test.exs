defmodule AgentSystemsLab.PersistedRunServerTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Demo, Repo, RunServer, Storage}

  @moduletag :database

  setup do
    id = "persisted-run-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id])
    end)

    {:ok, id: id}
  end

  defp start_run(id, opts \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [run_id: id, input: "Record a report", script: Demo.script(), storage: :postgres],
         opts
       )}
    )
  end

  test "every published state has matching committed events and intent", %{id: id} do
    server = start_run(id, max_turns: 3)
    initial = RunServer.snapshot(server)
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == initial.state
    assert saved.events == initial.events
    assert saved.intent.kind == "model"

    assert {:ok, planned} = RunServer.step(server)
    assert planned.tool_stats.effects == 0
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == planned.state
    assert saved.intent.kind == "tool"

    assert {:ok, finished} = RunServer.run_until_pause(server)
    assert finished.state.status == :succeeded
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == finished.state
    assert saved.events == finished.events
    assert saved.intent == nil

    stop_supervised!(RunServer)
    assert {:ok, ^saved} = Storage.load(id)
  end

  test "a persisted unknown outcome keeps a reconciliation intent until confirmed", %{id: id} do
    server = start_run(id, mock_response: :lost)
    assert {:ok, blocked} = RunServer.run_until_pause(server)
    assert blocked.state.status == :blocked
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == blocked.state
    assert saved.intent.kind == "reconcile"
    assert {:ok, _} = RunServer.reconcile_from_mock(server)
    assert {:ok, finished} = RunServer.run_until_pause(server)
    assert finished.tool_stats == %{requests: 1, effects: 1}
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == finished.state
    assert saved.intent == nil
  end

  test "a stale server does not advance its provider or overwrite newer facts", %{id: id} do
    server = start_run(id)
    original = RunServer.snapshot(server)
    assert {:ok, cancelled} = Storage.dispatch(id, 1, {:cancel, "another controller"})
    assert {:error, {:stale_sequence, 1, 2}} = RunServer.step(server)
    assert RunServer.snapshot(server) == original
    assert {:ok, ^cancelled} = Storage.load(id)
  end

  test "an invalid command never changes the saved snapshot", %{id: id} do
    server = start_run(id)
    assert {:ok, original} = Storage.load(id)
    assert {:error, _} = RunServer.command(server, {:tool_result, "missing", {:ok, "no effect"}})
    assert {:ok, ^original} = Storage.load(id)
    assert RunServer.snapshot(server).state == original.state
  end

  test "a fresh BEAM reads runtime receipt and failure tags without executing adapters", %{id: id} do
    server = start_run(id)
    assert {:ok, _} = RunServer.step(server)
    assert {:ok, _} = RunServer.step(server)
    assert {:ok, _} = RunServer.command(server, {:fail, :turn_budget_exceeded})
    stop_supervised!(RunServer)

    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, saved} = AgentSystemsLab.Storage.load(#{inspect(id)})
    true = saved.state.status == :failed
    true = length(saved.events) == 4
    true = saved.intent == nil
    IO.puts("fresh_vm_recovery_ok")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, exit_code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true
      )

    assert exit_code == 0, output
    assert output =~ "fresh_vm_recovery_ok"
  end
end
