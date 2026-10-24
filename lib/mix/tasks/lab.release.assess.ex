defmodule Mix.Tasks.Lab.Release.Assess do
  use Mix.Task
  @shortdoc "Recomputes versioned release evidence without execution or publication"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [candidate: :string, study: :string, evidence: :string])

    flags =
      Enum.filter(args, &String.starts_with?(&1, "--"))
      |> Enum.map(&(String.split(&1, "=", parts: 2) |> hd()))

    unless rest == [] and invalid == [] and Keyword.has_key?(opts, :candidate) and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and flags == Enum.uniq(flags),
           do:
             Mix.raise(
               "Usage: mix lab.release.assess --candidate ABS [--study ABS] [--evidence ABS]"
             )

    Mix.Task.run("compile", ["--quiet"])

    case AgentSystemsLab.ReleaseAssessment.assess(opts) do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("Release assessment failed: #{inspect(reason)}")
    end
  end
end
