defmodule Mix.Tasks.Lab.P2 do
  use Mix.Task
  @shortdoc "Verifies P2 crash windows with real kills and durable recovery evidence"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, repetitions: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.p2 [--output PATH] [--repetitions N]")

    Mix.Task.run("app.start")

    progress = fn update ->
      if update.status == :passed do
        Mix.shell().info(
          "[#{update.completed}/#{update.total}] #{update.fault} repetition=#{update.repetition} passed"
        )
      end
    end

    case AgentSystemsLab.P2Verification.run(Keyword.put(opts, :on_progress, progress)) do
      {:ok, %{output_dir: output, report: report}} ->
        Mix.shell().info(
          "P2 all_passed=#{report["all_passed"]} probes=#{report["fault_probe_count"]} kills=#{report["kill_count"]}"
        )

        Mix.shell().info(
          "duplicate_effects=#{report["duplicate_mock_effects"]} lost_receipts=#{report["lost_confirmed_receipts"]} stale_overwrites=#{report["stale_token_overwrites"]} cursor_rerequests=#{report["accepted_cursor_rerequests"]}"
        )

        Mix.shell().info("evidence=#{output}")

      {:error, reason} ->
        Mix.raise("P2 verification failed: #{inspect(reason)}")
    end
  end
end
