defmodule Mix.Tasks.Lab.Eval.Verify do
  use Mix.Task
  @shortdoc "Verify six fixed evaluation cohorts, reproducibility and regression gates"
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    if rest != [] or invalid != [] or length(opts) > 1,
      do: Mix.raise("Usage: mix lab.eval.verify [--output DIR]")

    Mix.Task.run("app.config")

    if not Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: Mix.raise("Evaluation requires PostgreSQL (database_required)")

    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false),
      do: Mix.raise("Disable global scheduler (global_scheduler_enabled)")

    Mix.Task.run("app.start")
    opts = Keyword.put(opts, :on_progress, fn p -> Mix.shell().info("#{p.case}: #{p.status}") end)

    case AgentSystemsLab.EvaluationDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Evaluation acceptance passed: #{result.output_dir}/report.json")

      {:error, {:evaluation_verification_failed, result}} ->
        Mix.raise(
          "Evaluation acceptance failed at #{result.report["failed_case"]}: #{result.output_dir}/report.json"
        )

      {:error, reason} ->
        Mix.raise("Evaluation acceptance rejected: #{inspect(reason)}")
    end
  end
end
