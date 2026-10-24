defmodule Mix.Tasks.Lab.P3 do
  use Mix.Task
  @shortdoc "Accepts P3 scheduling, fencing, backpressure and database recovery"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, repetitions: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.p3 [--output PATH] [--repetitions N]")

    Mix.Task.run("app.start")
    callback = fn update -> Mix.shell().info("p3: #{inspect(update)}") end

    case AgentSystemsLab.P3Verification.run(Keyword.put(opts, :on_progress, callback)) do
      {:ok, %{output_dir: output, report: report}} ->
        Mix.shell().info(
          "all_passed=#{report["all_passed"]} components=#{report["component_count"]}; evidence=#{output}"
        )

      {:error, reason} ->
        Mix.raise("P3 verification failed: #{inspect(reason)}")
    end
  end
end
