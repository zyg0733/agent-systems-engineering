defmodule Mix.Tasks.Lab.Eval do
  use Mix.Task
  @shortdoc "Evaluate a fixed development or holdout split with independent scoring"

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          split: :string,
          repetitions: :integer,
          profile: :string,
          baseline: :string
        ]
      )

    if rest != [] or invalid != [] or length(opts) != length(Enum.uniq(Keyword.keys(opts))),
      do:
        Mix.raise(
          "Usage: mix lab.eval [--output DIR] [--split dev|holdout] [--repetitions 1..10] [--profile reference|regressed] [--baseline REPORT]"
        )

    Mix.Task.run("app.config")

    if not Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: Mix.raise("Evaluation requires PostgreSQL (database_required)")

    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false),
      do: Mix.raise("Disable the global scheduler before evaluation (global_scheduler_enabled)")

    Mix.Task.run("app.start")

    opts =
      Keyword.put(opts, :on_progress, fn p ->
        if p.state == "completed", do: Mix.shell().info("#{p.task_id} trial #{p.trial}: recorded")
      end)

    case AgentSystemsLab.Evaluation.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Evaluation completed: #{result.output_dir}/report.json")
        Mix.shell().info(JSON.encode!(result.report["summary"]))

        if result.comparison && not result.comparison["passed"],
          do:
            Mix.raise(
              "Regression gate #{result.comparison["status"]}: #{result.output_dir}/comparison.json"
            )

      {:error, {:evaluation_failed, result}} ->
        Mix.raise("Evaluation incomplete (#{result.reason}): #{result.output_dir}/status.json")

      {:error, reason} ->
        Mix.raise("Evaluation rejected: #{inspect(reason)}")
    end
  end
end
