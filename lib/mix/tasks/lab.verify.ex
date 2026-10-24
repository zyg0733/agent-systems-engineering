defmodule Mix.Tasks.Lab.Verify do
  @shortdoc "Checks all 10 offline acceptance fixtures and their reconstructed histories"
  use Mix.Task

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("Usage: mix lab.verify")
    Mix.Task.run("app.start")
    results = AgentSystemsLab.Scenarios.verify_all()

    Enum.each(results, fn
      %{passed: true} = result ->
        Mix.shell().info(
          "PASS #{result.id}: #{result.status}, effects=#{result.effects}, events=#{result.event_count}, rebuild=true"
        )

      %{passed: false} = result ->
        Mix.shell().error("FAIL #{result.id}: #{result.error}")
    end)

    failures = Enum.count(results, &(not &1.passed))
    if failures > 0, do: Mix.raise("#{failures} fixture(s) failed")

    Mix.shell().info(
      "#{length(results)}/#{length(results)} fixtures passed. These are scripted checks, not a model capability benchmark."
    )
  end
end
