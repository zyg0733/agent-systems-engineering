defmodule Mix.Tasks.Lab.Observe do
  use Mix.Task

  @shortdoc "Verify bounded observability and durable Run correlation across eight offline scenarios"

  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    if rest != [] or invalid != [] or length(opts) > 1,
      do: Mix.raise("Usage: mix lab.observe [--output DIR]")

    Mix.Task.run("app.config")

    if not Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: Mix.raise("Observability verification requires PostgreSQL (database_required)")

    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
         Process.whereis(AgentSystemsLab.Scheduler),
       do:
         Mix.raise("Disable the global scheduler before verification (global_scheduler_enabled)")

    Mix.Task.run("app.start")

    opts =
      Keyword.put(opts, :on_progress, fn p ->
        Mix.shell().info("[#{p.completed}/#{p.total}] #{p.case}: #{p.status}")
      end)

    case AgentSystemsLab.ObservabilityDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Observability verification passed: #{result.output_dir}/report.json")

      {:error, {:observability_verification_failed, result}} ->
        Mix.raise(
          "Observability verification failed: #{result.output_dir}/report.json\n#{result.report["failed_case"]["reason"]}"
        )

      {:error, reason} ->
        Mix.raise("Observability verification failed: #{inspect(reason)}")
    end
  end
end
