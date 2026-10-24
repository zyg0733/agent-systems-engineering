defmodule Mix.Tasks.Lab.Candidate do
  use Mix.Task

  @shortdoc "Builds or verifies an inert frozen v0.1 teaching candidate"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, evidence: :string])

    unless invalid == [] and rest in [["build"], ["verify"]] and opts[:output] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             ((rest == ["build"] and is_binary(opts[:evidence])) or
                (rest == ["verify"] and is_nil(opts[:evidence]))) do
      Mix.raise(
        "Usage: mix lab.candidate build --output ABS --evidence ABS | verify --output ABS"
      )
    end

    result =
      case rest do
        ["build"] ->
          AgentSystemsLab.CandidatePackage.build(opts[:output], evidence: opts[:evidence])

        ["verify"] ->
          AgentSystemsLab.CandidatePackage.verify(opts[:output])
      end

    case result do
      {:ok, value} -> Mix.shell().info(JSON.encode!(value))
      {:error, reason} -> Mix.raise("Candidate package failed: #{inspect(reason)}")
    end
  end
end
