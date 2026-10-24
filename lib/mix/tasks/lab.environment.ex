defmodule Mix.Tasks.Lab.Environment do
  use Mix.Task
  @shortdoc "Plans, collects and verifies frozen environment evidence without executing it"

  @impl true
  def run([action | args]) when action in ~w(plan collect verify) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          source: :string,
          candidate: :string,
          profile: :string,
          execution: :string,
          output: :string,
          bundle: :string
        ]
      )

    flags =
      Enum.filter(args, &String.starts_with?(&1, "--"))
      |> Enum.map(&(String.split(&1, "=", parts: 2) |> hd()))

    unless rest == [] and invalid == [] and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             flags == Enum.uniq(flags),
           do: usage()

    Mix.Task.run("compile", ["--quiet"])

    result =
      case action do
        "plan" ->
          AgentSystemsLab.EnvironmentValidation.plan(
            Keyword.get(opts, :source),
            Keyword.delete(opts, :source)
          )

        "collect" ->
          AgentSystemsLab.EnvironmentValidation.collect(opts)

        "verify" ->
          AgentSystemsLab.EnvironmentValidation.verify(
            Keyword.get(opts, :bundle),
            Keyword.delete(opts, :bundle)
          )
      end

    case result do
      {:ok, report} -> Mix.shell().info(JSON.encode!(report))
      {:error, reason} -> Mix.raise("Environment validation failed: #{inspect(reason)}")
    end
  end

  def run(_), do: usage()

  defp usage,
    do:
      Mix.raise(
        "Usage: mix lab.environment plan --source ABS --profile macos-warm|macos-cold|linux-core [--candidate ABS] | collect --source ABS --execution ABS --output ABS [--candidate ABS] | verify --source ABS --bundle ABS [--candidate ABS]"
      )
end
