defmodule AgentSystemsLab.PersistedStreamTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Repo, RunServer, Storage}

  @moduletag :database

  setup do
    id =
      "persisted-stream-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id]) end)
    {:ok, id: id}
  end

  defp start_run(id, script, opts \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [run_id: id, input: "Stream a report", script: script, storage: :postgres],
         opts
       )}
    )
  end

  defp wait_finished(id, request, status) do
    assert_receive {:agent_stream, ^id, ^request, _seq, {:finished, ^status}}, 2_000
  end

  test "partial arguments retain only the model intent; completion commits before publication", %{
    id: id
  } do
    gate = make_ref()

    server =
      start_run(id, [
        {:stream,
         [
           {:tool_start, %{operation_id: "stream-op", tool: "mock_write"}},
           {:arguments_delta, ~s({"key":)},
           {:gate, self(), gate},
           {:arguments_delta, ~s("report"})},
           :done
         ]},
        {:final, "Saved"}
      ])

    :ok = RunServer.subscribe(server)
    {:ok, request} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, worker}
    assert {:ok, before} = Storage.load(id)
    assert before.state.status == :running
    assert before.state.seq == 1
    assert length(before.events) == 1
    assert before.intent.kind == "model"
    assert RunServer.snapshot(server).tool_stats == %{requests: 0, effects: 0}

    send(worker, {:release, gate})
    wait_finished(id, request, :waiting_tool)
    planned = RunServer.snapshot(server)
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == planned.state
    assert saved.events == planned.events
    assert saved.intent.kind == "tool"
    assert planned.state.operations["stream-op"].arguments == %{"key" => "report"}
    assert planned.tool_stats.effects == 0
    assert {:ok, completed} = RunServer.run_until_pause(server)
    assert completed.state.status == :succeeded
    assert completed.tool_stats == %{requests: 1, effects: 1}
    assert {:ok, %{state: state, intent: nil}} = Storage.load(id)
    assert state == completed.state
  end

  test "cancellation is durable and late provider traffic cannot change it", %{id: id} do
    gate = make_ref()

    server =
      start_run(id, [
        {:stream,
         [
           {:text_delta, "partial"},
           {:gate, self(), gate},
           {:text_delta, "late"},
           :done
         ]}
      ])

    :ok = RunServer.subscribe(server)
    {:ok, request} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, worker}
    monitor = Process.monitor(worker)
    assert {:ok, cancelled} = RunServer.cancel(server, "stop streaming")
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    wait_finished(id, request, :cancelled)
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == cancelled.state
    assert saved.intent == nil
    assert Enum.map(saved.events, & &1.type) == [:run_started, :run_cancelled]

    assert {:error, :stale_request} =
             GenServer.call(server, {:stream_frame, request, worker, {:text_delta, "late"}})

    send(server, {:model_timeout, request})
    assert RunServer.snapshot(server) == cancelled
    assert {:ok, ^saved} = Storage.load(id)
    assert cancelled.tool_stats.effects == 0
  end

  test "a byte overflow commits failure without saving partial output or a tool intent", %{id: id} do
    server =
      start_run(id, [{:stream, [{:text_delta, "abc"}, {:text_delta, "defgh"}, :done]}],
        max_output_bytes: 7
      )

    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:budget_exceeded, :output_bytes}
    assert failed.budget.output_bytes == 3
    assert failed.state.output == nil
    assert failed.tool_stats.effects == 0
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == failed.state
    assert saved.intent == nil
    assert Enum.map(saved.events, & &1.type) == [:run_started, :run_failed]
  end

  test "killing the owner during a partial stream leaves the complete old transaction", %{id: id} do
    gate = make_ref()
    server = start_run(id, [{:stream, [{:text_delta, "preview"}, {:gate, self(), gate}, :done]}])
    {:ok, _request} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, worker}
    worker_monitor = Process.monitor(worker)
    server_monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert {:ok, saved} = Storage.load(id)
    assert saved.state.status == :running
    assert saved.state.seq == 1
    assert length(saved.events) == 1
    assert saved.intent.kind == "model"
  end

  test "a fresh VM can load the new budget failure vocabulary", %{id: id} do
    server = start_run(id, [{:stream, [{:text_delta, "x"}, :done]}], max_output_bytes: 0)
    assert {:ok, %{state: %{status: :failed}}} = RunServer.step(server)
    stop_supervised!(RunServer)

    assert_fresh_vm_reason(id, {:budget_exceeded, :output_bytes})
  end

  test "malformed JSON produces a durable failure readable in a fresh VM", %{id: id} do
    server =
      start_run(id, [
        {:stream,
         [
           {:tool_start, %{operation_id: "bad-json", tool: "mock_write"}},
           {:arguments_delta, "{"},
           :done
         ]}
      ])

    assert {:ok, failed} = RunServer.step(server)
    reason = {:provider_error, {:invalid_stream, {:invalid_arguments_json, {:unexpected_end, 1}}}}
    assert failed.state.status == :failed
    assert failed.state.terminal_reason == reason
    assert failed.tool_stats.effects == 0
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == failed.state
    assert saved.intent == nil
    stop_supervised!(RunServer)
    assert_fresh_vm_reason(id, reason)
  end

  test "a stale tool owner checks saved cancellation before executing its pending effect", %{
    id: id
  } do
    server =
      start_run(id, [
        {:call, %{operation_id: "cancelled-tool", tool: "mock_write", arguments: %{}}}
      ])

    assert {:ok, planned} = RunServer.step(server)
    assert {:ok, saved} = Storage.dispatch(id, planned.state.seq, {:cancel, "another controller"})
    assert {:error, {:stale_sequence, 2, 3}} = RunServer.step(server)
    assert RunServer.snapshot(server).tool_stats == %{requests: 0, effects: 0}
    assert {:ok, ^saved} = Storage.load(id)
  end

  test "an unencodable automatic provider error still commits a bounded failure", %{id: id} do
    server = start_run(id, [{:error, self()}])
    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.status == :failed
    assert {:unpersistable_failure, :unsupported_term, detail} = failed.state.terminal_reason
    assert detail =~ "#PID<"
    assert String.length(detail) <= 512
    assert {:ok, saved} = Storage.load(id)
    assert saved.state == failed.state
    assert saved.intent == nil
    assert failed.tool_stats == %{requests: 0, effects: 0}
    stop_supervised!(RunServer)
    assert_fresh_vm_reason(id, failed.state.terminal_reason)
  end

  defp assert_fresh_vm_reason(id, expected_reason) do
    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, saved} = AgentSystemsLab.Storage.load(#{inspect(id)})
    true = inspect(saved.state.terminal_reason) == #{inspect(inspect(expected_reason))}
    true = saved.intent == nil
    IO.puts("stream_budget_recovery_ok")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, exit_code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true
      )

    assert exit_code == 0, output
    assert output =~ "stream_budget_recovery_ok"
  end
end
