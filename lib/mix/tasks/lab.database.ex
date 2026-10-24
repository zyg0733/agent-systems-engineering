defmodule Mix.Tasks.Lab.Database do
  use Mix.Task
  @shortdoc "Injects isolated database disconnects, lost COMMIT ACKs and reconnects"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, repetitions: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.database [--output PATH] [--repetitions N]")

    Mix.Task.run("app.start")

    callback = fn update ->
      Mix.shell().info(
        "database: #{update.fault} repetition=#{update.repetition} #{update.status}"
      )
    end

    case AgentSystemsLab.DatabaseFaultDemo.run(Keyword.put(opts, :on_progress, callback)) do
      {:ok, %{output_dir: output, report: report}} ->
        Mix.shell().info(
          "all_passed=#{report["all_passed"]} probes=#{report["fault_probe_count"]}; evidence=#{output}"
        )

      {:error, reason} ->
        Mix.raise("Database fault verification failed: #{inspect(reason)}")
    end
  end
end
