defmodule Mix.Tasks.Lab.Approval do
  use Mix.Task
  @shortdoc "Verify durable human approvals, hash invalidation, pause and finite rework"
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    if rest != [] or invalid != [] or length(opts) > 1,
      do: Mix.raise("Usage: mix lab.approval [--output DIR]")

    Mix.Task.run("app.start")

    opts =
      Keyword.put(opts, :on_progress, fn progress ->
        Mix.shell().info(
          "[#{progress.completed}/#{progress.total}] #{progress.case}: #{progress.status}"
        )
      end)

    case AgentSystemsLab.ApprovalDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Approval verification passed: #{result.output_dir}/report.json")

      {:error, {:approval_verification_failed, result}} ->
        Mix.raise(
          "Approval verification failed: #{result.output_dir}/report.json\n#{result.report["failed_case"]["reason"]}"
        )

      {:error, reason} ->
        Mix.raise("Approval verification failed: #{inspect(reason, limit: :infinity)}")
    end
  end
end
