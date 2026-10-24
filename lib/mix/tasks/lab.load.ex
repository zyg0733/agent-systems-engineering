defmodule Mix.Tasks.Lab.Load do
  use Mix.Task
  @shortdoc "Measures bounded saturation, fairness, budgets and timeout reclamation"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, jobs: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix lab.load [--output DIR] [--jobs 12]")

    Mix.Task.run("app.start")
    opts = Keyword.put(opts, :on_progress, fn phase -> Mix.shell().info("load: #{phase}") end)

    case AgentSystemsLab.LoadDemo.run(opts) do
      {:ok, %{output_dir: output, report: report}} ->
        Mix.shell().info("load checks: #{report["all_passed"]}; evidence: #{output}")

      {:error, reason} ->
        Mix.raise("load experiment failed: #{inspect(reason)}")
    end
  end
end
