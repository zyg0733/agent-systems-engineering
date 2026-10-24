defmodule AgentSystemsLab.RunServerTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Demo, Kernel, RunServer}

  defp start_run(context, extra \\ []) do
    opts =
      Keyword.merge(
        [run_id: Atom.to_string(context.test), input: "record", script: Demo.script()],
        extra
      )

    start_supervised!({RunServer, opts})
  end

  test "records tool intent before the effect and rebuilds the complete run", context do
    server = start_run(context)
    assert {:ok, planned} = RunServer.step(server)
    assert planned.state.status == :waiting_tool
    assert planned.tool_stats == %{requests: 0, effects: 0}
    assert List.last(planned.events).type == :tool_requested
    assert {:ok, result} = RunServer.run_until_pause(server)
    assert result.state.status == :succeeded
    assert result.tool_stats == %{requests: 1, effects: 1}
    assert {:ok, result.state} == Kernel.rebuild(result.state.run_id, result.events)
  end

  test "unknown effects pause until lookup and explicit reconciliation", context do
    server = start_run(context, mock_response: :lost)
    assert {:ok, paused} = RunServer.run_until_pause(server)
    assert paused.state.status == :blocked
    assert paused.provider.cursor == 1
    assert paused.tool_stats.effects == 1
    assert {:error, :reconciliation_required} = RunServer.step(server)
    assert paused == RunServer.snapshot(server)
    assert {:ok, _} = RunServer.reconcile_from_mock(server)
    assert {:ok, result} = RunServer.run_until_pause(server)
    assert result.state.status == :succeeded
    assert result.tool_stats == %{requests: 1, effects: 1}
  end

  test "cancelling a planned call prevents the effect", context do
    server = start_run(context)
    assert {:ok, _} = RunServer.step(server)
    assert {:ok, cancelled} = RunServer.command(server, {:cancel, :user_requested})
    assert cancelled.state.status == :cancelled
    assert {:error, {:not_runnable, :cancelled}} = RunServer.step(server)
    assert RunServer.snapshot(server).tool_stats.effects == 0
  end

  test "turn budget fails before an extra provider request", context do
    server = start_run(context, max_turns: 1)
    assert {:ok, failed} = RunServer.run_until_pause(server)
    assert failed.state.status == :failed
    assert failed.state.turn_count == 1
    assert failed.provider.cursor == 1
    assert List.last(failed.events).data.reason == :turn_budget_exceeded
  end

  test "script exhaustion fails visibly", context do
    server = start_run(context, script: [])
    assert {:ok, result} = RunServer.run_until_pause(server)
    assert result.state.status == :failed
    assert result.tool_stats.effects == 0
    assert List.last(result.events).data.reason == {:provider_error, :script_exhausted}
  end

  test "step bound stops without manufacturing a terminal result", context do
    server = start_run(context)
    assert {:error, :step_limit, result} = RunServer.run_until_pause(server, 1)
    assert result.state.status == :waiting_tool
    assert result.tool_stats.effects == 0
  end

  test "one registry name cannot own two live runs", context do
    server = start_run(context)

    assert {:error, {:already_started, ^server}} =
             AgentSystemsLab.start_run(
               run_id: Atom.to_string(context.test),
               input: "another",
               script: []
             )
  end

  test "a stopped temporary run is not silently restarted", context do
    id = Atom.to_string(context.test)
    {:ok, server} = AgentSystemsLab.start_run(run_id: id, input: "record", script: Demo.script())
    assert {:ok, _} = RunServer.run_until_pause(server)
    ref = Process.monitor(server)
    GenServer.stop(server)
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    await_unregistered(id, 100)

    assert {:ok, fresh} =
             AgentSystemsLab.start_run(run_id: id, input: "record", script: Demo.script())

    on_exit(fn -> if Process.alive?(fresh), do: GenServer.stop(fresh) end)
    assert RunServer.snapshot(fresh).state.seq == 1
    assert RunServer.snapshot(fresh).tool_stats.effects == 0
  end

  test "invalid initialization does not create a runnable process" do
    assert {:error, :invalid_options} = RunServer.start_link(run_id: "")

    assert {:error, :invalid_options} =
             AgentSystemsLab.start_run(run_id: "bad-input", input: nil, script: [])
  end

  test "explicit invalid budgets cannot fall back to the default" do
    for budget <- [false, nil, 0, -1, "4"] do
      assert {:error, _} =
               AgentSystemsLab.start_run(
                 run_id: "invalid-budget-#{inspect(budget)}",
                 input: "record",
                 script: [],
                 max_turns: budget
               )
    end
  end

  test "cancellation keeps a confirmed effect in the operation history", context do
    server = start_run(context)
    assert {:ok, _} = RunServer.step(server)
    assert {:ok, _} = RunServer.step(server)
    assert {:ok, cancelled} = RunServer.command(server, {:cancel, :user_requested})
    assert cancelled.state.status == :cancelled
    assert cancelled.tool_stats.effects == 1
    assert cancelled.state.operations["write-report-1"].status == :ok
    assert {:ok, cancelled.state} == Kernel.rebuild(cancelled.state.run_id, cancelled.events)
  end

  defp await_unregistered(_id, 0), do: flunk("registry did not finish asynchronous cleanup")

  defp await_unregistered(id, attempts) do
    if Registry.lookup(AgentSystemsLab.Registry, id) == [] do
      :ok
    else
      receive do
      after
        10 -> await_unregistered(id, attempts - 1)
      end
    end
  end
end
