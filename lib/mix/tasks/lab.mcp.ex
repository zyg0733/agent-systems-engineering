defmodule Mix.Tasks.Lab.Mcp do
  use Mix.Task
  @shortdoc "Verifies owned MCP stdio sessions and durable unknown recovery"
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, memory: :boolean])
    if rest != [] or invalid != [], do: Mix.raise("usage: mix lab.mcp [--output DIR] [--memory]")
    Mix.Task.run("app.start")

    opts =
      Keyword.put(opts, :on_progress, fn p ->
        Mix.shell().info("[#{p.completed}/#{p.total}] #{p.case}: #{p.status}")
      end)

    case AgentSystemsLab.MCPDemo.run(opts) do
      {:ok, result} ->
        Mix.shell().info("MCP verification passed: #{result.output_dir}/report.json")

      {:error, reason} ->
        Mix.raise("MCP verification failed: #{inspect(reason, limit: 20)}")
    end
  end
end
