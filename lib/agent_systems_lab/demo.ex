defmodule AgentSystemsLab.Demo do
  @moduledoc "A bounded offline demonstration of intent, effect, and reconciliation."

  alias AgentSystemsLab.{Kernel, RunServer}

  def script do
    [
      {:call,
       %{
         operation_id: "write-report-1",
         tool: "mock_write",
         arguments: %{key: "report", value: "hello from the lab"}
       }},
      {:final, "Report recorded."}
    ]
  end

  def run(opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "lab-demo")

    with {:ok, server} <-
           AgentSystemsLab.start_run(
             run_id: run_id,
             input: "Record a report and confirm completion.",
             script: script(),
             mock_response: if(opts[:lost_response], do: :lost, else: :ok)
           ) do
      try do
        {:ok, paused} = RunServer.run_until_pause(server)

        result =
          if paused.state.status == :blocked do
            {:ok, _} = RunServer.reconcile_from_mock(server)
            {:ok, completed} = RunServer.run_until_pause(server)
            completed
          else
            paused
          end

        {:ok, rebuilt} = Kernel.rebuild(run_id, result.events)

        if rebuilt == result.state and result.state.status == :succeeded do
          {:ok, %{paused: paused, completed: result, replay_matches: true}}
        else
          {:error, :demo_invariant_failed}
        end
      after
        GenServer.stop(server)
      end
    end
  end
end
