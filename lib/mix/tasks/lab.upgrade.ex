defmodule Mix.Tasks.Lab.Upgrade do
  use Mix.Task
  @shortdoc "Exercises legacy migration and native backup/restore in fresh owned databases"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.upgrade [--output PATH]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.HistoryUpgradeDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("legacy_migration=true restore_exact=true old_claim_fenced=true")
        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("Upgrade exercise failed: #{inspect(reason)}")
    end
  end
end
