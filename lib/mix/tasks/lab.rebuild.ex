defmodule Mix.Tasks.Lab.Rebuild do
  use Mix.Task
  @shortdoc "Rebuilds a saved run without invoking providers or tools"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [checkpoint: :boolean])

    if length(rest) != 1 or invalid != [],
      do: Mix.raise("Usage: mix lab.rebuild RUN_ID [--checkpoint]")

    Mix.Task.run("app.start")
    mode = if opts[:checkpoint], do: :checkpoint, else: :full

    case AgentSystemsLab.CheckpointStore.rebuild(hd(rest), mode: mode) do
      {:ok, rebuilt} ->
        Mix.shell().info(
          "status=#{rebuilt.state.status} seq=#{rebuilt.state.seq} mode=#{rebuilt.audit.mode}"
        )

        Mix.shell().info("state_sha256=#{AgentSystemsLab.Context.hash(rebuilt.state)}")

        Mix.shell().info(
          "Read-only reconstruction; no provider, tool, or run worker was invoked."
        )

      {:error, reason} ->
        Mix.raise("Rebuild rejected: #{inspect(reason)}")
    end
  end
end
