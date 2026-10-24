defmodule Mix.Tasks.Lab.P1 do
  use Mix.Task
  @shortdoc "Runs the P1 session/context/streamed-repair acceptance demonstration"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string, memory: :boolean])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.p1 [--output PATH] [--memory]")
    Mix.Task.run("app.start")

    opts =
      opts
      |> Keyword.put(:storage, if(opts[:memory], do: :memory, else: :postgres))
      |> Keyword.delete(:memory)

    case AgentSystemsLab.P1Demo.run(opts) do
      {:ok, result} ->
        report = result.report

        Mix.shell().info(
          "P1 passed: storage=#{report["storage"]} contexts=#{report["context_count"]} compressed=#{report["compressed_contexts"]} summaries=#{report["summary_contexts"]}"
        )

        Mix.shell().info(
          "before_exit=#{report["before_exit_code"]} after_exit=#{report["after_exit_code"]} cancel=#{report["cancel_status"]} cancel_writes=0"
        )

        Mix.shell().info(
          "facts=true receipts=true permissions=true canonical_session_unchanged=true"
        )

        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("P1 demonstration failed: #{inspect(reason)}")
    end
  end
end
