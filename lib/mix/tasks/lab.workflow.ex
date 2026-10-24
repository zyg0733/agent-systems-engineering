defmodule Mix.Tasks.Lab.Workflow do
  use Mix.Task
  @shortdoc "Verifies durable DAG dependencies, joins, cancellation and recovery"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix lab.workflow [--output DIR]")
    Mix.Task.run("app.start")

    opts =
      Keyword.put(opts, :on_progress, fn p ->
        Mix.shell().info("[#{p.completed}/#{p.total}] #{p.case}: #{p.status}")
      end)

    case AgentSystemsLab.WorkflowDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Workflow verification passed: #{result.output_dir}/report.json")

      {:error, reason} ->
        Mix.raise("Workflow verification failed: #{inspect(reason, limit: 20)}")
    end
  end
end
