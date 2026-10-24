defmodule AgentSystemsLab.Scenarios do
  @moduledoc "Executable acceptance scenarios for the trusted, local W1–W2 fixtures."

  alias AgentSystemsLab.{Kernel, RunServer}

  def fixtures do
    # This is repository-owned Elixir data, never a model response or user path.
    {tasks, _bindings} = Code.eval_file(Path.expand("../../fixtures/tasks.exs", __DIR__))
    tasks
  end

  def verify_all, do: Enum.map(fixtures(), &verify/1)

  def verify(task) do
    {state, events, effects, replay_opts} = scenario(task)
    {:ok, rebuilt} = Kernel.rebuild(task.id, events, replay_opts)
    ensure!(rebuilt == state, "history reconstruction changed the state")
    ensure!(state.status == task.expected_status, "unexpected final status #{state.status}")

    expected_effects =
      if task.scenario in [:tool_success, :unknown_then_reconcile, :turn_limit], do: 1, else: 0

    expected_effects = if task.scenario == :two_tools, do: 2, else: expected_effects
    ensure!(effects == expected_effects, "unexpected business effect count #{effects}")

    %{
      id: task.id,
      passed: true,
      status: state.status,
      effects: effects,
      event_count: length(events),
      replay_matches: true
    }
  rescue
    error -> %{id: task.id, passed: false, error: Exception.message(error)}
  end

  defp scenario(%{scenario: :cancel_before_start} = task) do
    {:ok, initial} = Kernel.new(task.id)
    {:ok, state, events} = Kernel.dispatch(initial, {:cancel, :user_requested})
    {state, events, 0, []}
  end

  defp scenario(%{scenario: :invalid_transition} = task) do
    {:ok, initial} = Kernel.new(task.id)

    ensure!(
      match?({:error, _}, Kernel.dispatch(initial, {:model_response, {:final, "too early"}})),
      "illegal transition accepted"
    )

    {initial, [], 0, []}
  end

  defp scenario(task) do
    {script, options} = script_for(task.scenario)
    opts = [run_id: task.id, input: task.input, script: script] ++ options
    {:ok, server} = AgentSystemsLab.start_run(opts)

    try do
      case task.scenario do
        :cancel_waiting_tool ->
          {:ok, _} = RunServer.step(server)
          {:ok, _} = RunServer.command(server, {:cancel, :user_requested})

        :explicit_failure ->
          {:ok, _} = RunServer.command(server, {:fail, :explicit_failure})

        :unknown_then_reconcile ->
          {:ok, blocked} = RunServer.run_until_pause(server)
          ensure!(blocked.state.status == :blocked, "lost receipt did not pause")
          ensure!(blocked.provider.cursor == 1, "model continued before reconciliation")

          ensure!(
            blocked.tool_stats == %{requests: 1, effects: 1},
            "lost receipt lost its effect"
          )

          {:ok, _} = RunServer.reconcile_from_mock(server)
          {:ok, _} = RunServer.run_until_pause(server)

        :tool_failure ->
          {:ok, _} = RunServer.step(server)
          {:ok, resumed} = RunServer.step(server)

          ensure!(
            resumed.state.operations["op-1"].status == :error,
            "pre-effect failure was not recorded"
          )

          # A known tool error may be recoverable. This scenario's driver stops.
          {:ok, _} = RunServer.command(server, {:fail, :tool_failed})

        _ ->
          {:ok, _} = RunServer.run_until_pause(server)
      end

      result = RunServer.snapshot(server)
      {result.state, result.events, result.tool_stats.effects, Keyword.take(opts, [:max_turns])}
    after
      GenServer.stop(server)
    end
  end

  defp script_for(:direct_success), do: {[{:final, "done"}], []}
  defp script_for(:two_tools), do: {[call("op-1"), call("op-2"), {:final, "done"}], []}

  defp script_for(:unknown_then_reconcile),
    do: {[call("op-1"), {:final, "done"}], [mock_response: :lost]}

  defp script_for(:tool_failure), do: {[call("op-1")], [mock_response: :fail_before_effect]}
  defp script_for(:turn_limit), do: {[call("op-1"), {:final, "unreachable"}], [max_turns: 1]}
  defp script_for(:cancel_waiting_tool), do: {[call("op-1")], []}
  defp script_for(:explicit_failure), do: {[], []}
  defp script_for(:tool_success), do: {[call("op-1"), {:final, "done"}], []}

  defp call(id),
    do: {:call, %{operation_id: id, tool: "mock_write", arguments: %{key: id, value: "fixture"}}}

  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(ArgumentError, message)
end
