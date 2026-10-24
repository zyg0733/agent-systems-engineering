defmodule Mix.Tasks.Lab.Reproduce do
  use Mix.Task

  @shortdoc "Exports source, verifies it, stages declared caches, or prints a fixed clean-build plan"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, port: :integer])

    unless ((invalid == [] and length(rest) == 1 and opts[:output]) &&
              rest in [["export"], ["verify"], ["cache"], ["plan"]]) and
             length(opts) == length(Keyword.keys(opts) |> Enum.uniq()) and
             (is_nil(opts[:port]) or rest == ["plan"]) do
      Mix.raise(
        "Usage: mix lab.reproduce export|verify|cache|plan --output ABSOLUTE_PATH [--port N]"
      )
    end

    result =
      case rest do
        ["export"] -> AgentSystemsLab.Reproduction.export(opts[:output])
        ["verify"] -> AgentSystemsLab.Reproduction.verify(opts[:output])
        ["cache"] -> AgentSystemsLab.Reproduction.stage_cache(opts[:output])
        ["plan"] -> AgentSystemsLab.Reproduction.plan(opts[:output], Keyword.take(opts, [:port]))
      end

    case result do
      {:ok, value} -> Mix.shell().info(JSON.encode!(value))
      {:error, reason} -> Mix.raise("Reproduction preparation failed: #{inspect(reason)}")
    end
  end
end
