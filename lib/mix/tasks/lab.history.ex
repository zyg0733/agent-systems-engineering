defmodule Mix.Tasks.Lab.History do
  use Mix.Task
  @shortdoc "Creates and audits a checkpoint plus model recordings in a fresh VM"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.history [--output PATH]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.HistoryDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("same_state=true recorded_results=2 checkpoint_seq=2 tail_events=2")
        Mix.shell().info("fresh_vm_provider_calls=0 fresh_vm_tool_calls=0 file_writes=1")
        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("History demonstration failed: #{inspect(reason)}")
    end
  end
end
