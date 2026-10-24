defmodule Mix.Tasks.Lab.Eval.Compare do
  use Mix.Task
  @shortdoc "Compare saved evaluation reports without executing tasks or starting the application"

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          success_drop_pp: :float,
          cost_increase_pct: :float,
          cost_increase_units: :integer,
          latency_increase_pct: :float,
          latency_increase_us: :integer
        ]
      )

    if length(rest) != 2 or invalid != [] or length(opts) != length(Enum.uniq(Keyword.keys(opts))),
      do:
        Mix.raise(
          "Usage: mix lab.eval.compare BASELINE CANDIDATE [--output DIR] [--success-drop-pp N] [--cost-increase-pct N] [--cost-increase-units N] [--latency-increase-pct N] [--latency-increase-us N]"
        )

    # Compilation/config loading does not start Repo, Scheduler, or execution.
    Mix.Task.run("app.config")
    [baseline, candidate] = rest

    case AgentSystemsLab.Evaluation.compare_files(baseline, candidate, opts) do
      {:ok, result} ->
        Mix.shell().info(
          "Comparison #{result.comparison["status"]}: #{result.output_dir}/comparison.json"
        )

        if not result.comparison["passed"],
          do: Mix.raise("Regression gate failed; saved comparison contains all checks")

      {:error, reason} ->
        Mix.raise("Comparison rejected: #{inspect(reason)}")
    end
  end
end
