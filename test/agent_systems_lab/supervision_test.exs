defmodule AgentSystemsLab.SupervisionTest do
  use ExUnit.Case, async: false

  test "stopping the registry subtree stops dependent runs before readmission" do
    {:ok, server} =
      AgentSystemsLab.start_run(run_id: "registry-loss", input: "record", script: [])

    old_registry = Process.whereis(AgentSystemsLab.Registry)
    old_run_supervisor = Process.whereis(AgentSystemsLab.RunSupervisor)
    ref = Process.monitor(server)
    # Stop the complete subtree, including its named Registry partitions.
    # Arbitrary supervisor-tree corruption is outside the W1-W2 guarantee.
    Supervisor.stop(old_registry, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^server, :shutdown}, 1_000
    await_ready(old_registry, old_run_supervisor, 100)
    assert Registry.lookup(AgentSystemsLab.Registry, "registry-loss") == []

    {:ok, replacement} =
      AgentSystemsLab.start_run(run_id: "registry-loss", input: "record", script: [])

    assert AgentSystemsLab.RunServer.snapshot(replacement).state.seq == 1
    GenServer.stop(replacement)
  end

  defp await_ready(_old_registry, _old_run_supervisor, 0),
    do: flunk("dependent supervisors did not recover")

  defp await_ready(old_registry, old_run_supervisor, attempts) do
    registry = Process.whereis(AgentSystemsLab.Registry)
    run_supervisor = Process.whereis(AgentSystemsLab.RunSupervisor)

    if is_pid(registry) and registry != old_registry and is_pid(run_supervisor) and
         run_supervisor != old_run_supervisor do
      :ok
    else
      receive do
      after
        10 -> await_ready(old_registry, old_run_supervisor, attempts - 1)
      end
    end
  end
end
