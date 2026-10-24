defmodule AgentSystemsLab.ScenariosTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Demo, Scenarios}

  test "all acceptance fixtures run and reconstruct exactly" do
    tasks = Scenarios.fixtures()
    assert length(tasks) == 10
    assert length(Enum.uniq_by(tasks, & &1.id)) == 10
    assert Enum.all?(Scenarios.verify_all(), & &1.passed)
  end

  test "normal and lost receipt demonstrations both produce one effect" do
    assert {:ok, normal} = Demo.run(run_id: "normal-demo-test")
    assert normal.completed.state.status == :succeeded
    assert normal.completed.tool_stats.effects == 1
    assert normal.replay_matches
    assert {:ok, lost} = Demo.run(run_id: "lost-demo-test", lost_response: true)
    assert lost.paused.state.status == :blocked
    assert lost.completed.state.status == :succeeded
    assert lost.completed.tool_stats == %{effects: 1, requests: 1}
    assert lost.replay_matches
  end
end
