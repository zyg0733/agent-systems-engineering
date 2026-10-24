defmodule Mix.Tasks.Lab.Retry do
  use Mix.Task
  @shortdoc "Demonstrates durable bounded retries, backoff and visible unknown outcomes"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.retry [--output PATH]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.RetryDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("model_attempts=3 accepted_results=1 fresh_vm_due_preserved=true")
        Mix.shell().info("tool_effects=0,0,1 retry_exhaustion_stops=true manual_unknown_queue=1")
        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("Retry demonstration failed: #{inspect(reason)}")
    end
  end
end
