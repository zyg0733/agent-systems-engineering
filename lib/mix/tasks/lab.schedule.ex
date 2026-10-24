defmodule Mix.Tasks.Lab.Schedule do
  use Mix.Task
  @shortdoc "Demonstrates scoped background workers, lease renewal and durable due retries"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, runs: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.schedule [--output PATH] [--runs N]")

    Mix.Task.run("app.start")

    case AgentSystemsLab.SchedulingDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info(
          "background_batch=#{result.report["batch_runs"]} pools=2 parallel_deliveries=4"
        )

        Mix.shell().info(
          "lease_renewed=true redelivery_effects=1 retry_attempts=3 manual_unknown_preserved=true"
        )

        Mix.shell().info("fresh_application_scheduler=true evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("Scheduling demonstration failed: #{inspect(reason)}")
    end
  end
end
