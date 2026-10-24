defmodule Mix.Tasks.Lab.Demo do
  @shortdoc "Runs an offline model/tool trace; pass --lost-response to reconcile a lost receipt"
  @moduledoc """
  Runs the W1–W2 demonstration without network or credentials.

      mix lab.demo
      mix lab.demo --lost-response
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [lost_response: :boolean])

    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.demo [--lost-response]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.Demo.run(opts) do
      {:ok, result} ->
        if result.paused.state.status == :blocked do
          Mix.shell().info(
            "Paused: blocked; effect exists but receipt was lost. Querying the mock ledger."
          )
        end

        Enum.each(result.completed.events, fn event ->
          Mix.shell().info("#{event.seq} #{event.type} #{inspect(event.data, pretty: false)}")
        end)

        stats = result.completed.tool_stats

        Mix.shell().info(
          "status=#{result.completed.state.status} turns=#{result.completed.state.turn_count} requests=#{stats.requests} effects=#{stats.effects}"
        )

        Mix.shell().info(
          "rebuild_matches=#{result.replay_matches} (in-memory history; no durable storage)"
        )

      {:error, reason} ->
        Mix.raise("Demo failed: #{inspect(reason)}")
    end
  end
end
