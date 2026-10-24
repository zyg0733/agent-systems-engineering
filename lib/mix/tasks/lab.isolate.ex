defmodule Mix.Tasks.Lab.Isolate do
  use Mix.Task

  @shortdoc "Verifies real isolated file/network/resource boundaries and cleanup"

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [output: :string])
    if positional != [] or invalid != [], do: Mix.raise("usage: mix lab.isolate [--output DIR]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.IsolationDemo.run(
           opts ++
             [
               on_progress: fn progress ->
                 Mix.shell().info(
                   "[#{progress.completed}/#{progress.total}] #{progress.case}: #{progress.status}"
                 )
               end
             ]
         ) do
      {:ok, result} ->
        Mix.shell().info("All isolation probes passed: #{result.output_dir}/report.json")

      {:error, reason} ->
        Mix.raise("isolation verification failed: #{inspect(reason, limit: 20)}")
    end
  end
end
