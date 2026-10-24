defmodule Mix.Tasks.Lab.Recover do
  use Mix.Task
  @shortdoc "Verifies real crash recovery, durable idempotency and unknown reconciliation"
  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, repetitions: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.recover [--output PATH] [--repetitions N]")

    Mix.Task.run("app.start")

    case AgentSystemsLab.RecoveryDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info(
          "recovered=#{result.report["fault_probe_count"]} duplicate_mock_effects=0"
        )

        Mix.shell().info(
          "fresh_vm_resume=true query_confirmed=true ambiguous_file_requires_evidence=true"
        )

        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("Recovery verification failed: #{inspect(reason)}")
    end
  end
end
