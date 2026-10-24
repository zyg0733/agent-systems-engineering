defmodule Mix.Tasks.Lab.Release do
  use Mix.Task
  @shortdoc "Checks W23 source preparation or prints a fixed release plan (no execution)"

  @impl true
  def run(args) do
    if args not in [["check"], ["plan"]],
      do: Mix.raise("Usage: mix lab.release check | plan")

    Mix.Task.run("compile", ["--quiet"])

    result =
      case args do
        ["check"] -> AgentSystemsLab.ReleaseReadiness.check()
        ["plan"] -> AgentSystemsLab.ReleaseReadiness.plan()
      end

    case result do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("Release source check failed: #{inspect(reason)}")
    end
  end
end
