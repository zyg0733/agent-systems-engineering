defmodule Mix.Tasks.Lab.Fence do
  use Mix.Task
  @shortdoc "Verifies stale-worker fencing with real SIGSTOP/SIGCONT on owned BEAM processes"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, repetitions: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.fence [--output PATH] [--repetitions N]")

    Mix.Task.run("app.start")

    progress = fn update ->
      if update.status == :passed do
        Mix.shell().info(
          "[#{update.completed}/#{update.total}] #{update.fault} repetition=#{update.repetition} fenced"
        )
      end
    end

    case AgentSystemsLab.FencingDemo.run(Keyword.put(opts, :on_progress, progress)) do
      {:ok, %{output_dir: output, report: report}} ->
        Mix.shell().info(
          "all_passed=#{report["all_passed"]} SIGSTOP=#{report["sigstop_count"]} SIGCONT=#{report["sigcont_count"]} same_seq=#{report["same_seq_fencing_probes"]}"
        )

        Mix.shell().info(
          "stale_overwrites=#{report["stale_generation_overwrites"]} duplicate_effects=#{report["duplicate_mock_effects"]} evidence=#{output}"
        )

      {:error, reason} ->
        Mix.raise("Fencing verification failed: #{inspect(reason)}")
    end
  end
end
