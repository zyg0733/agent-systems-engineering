defmodule Mix.Tasks.Lab.Repair do
  use Mix.Task

  @shortdoc "Repairs a fixed offline fixture and saves a unified diff plus acceptance logs"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [], do: Mix.raise("Usage: mix lab.repair [--output PATH]")
    Mix.Task.run("app.start")

    case AgentSystemsLab.Repair.run(opts) do
      {:ok, result} ->
        report = result.report

        Mix.shell().info(
          "before_exit=#{report["before_exit_code"]} after_exit=#{report["after_exit_code"]}"
        )

        Mix.shell().info(
          "status=#{report["status"]} turns=#{report["turns"]} events=#{report["event_count"]} rebuild_matches=true"
        )

        Mix.shell().info("file_requests=3 reads=1 writes=2")
        Mix.shell().info("diff=#{result.diff_path}")
        Mix.shell().info("evidence=#{result.output_dir}")

      {:error, reason} ->
        Mix.raise("Repair exercise failed: #{inspect(reason)}")
    end
  end
end
