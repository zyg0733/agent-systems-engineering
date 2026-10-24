defmodule Mix.Tasks.Lab.Freeze do
  use Mix.Task
  @shortdoc "Runs or verifies the fixed 12×20 frozen v0.1 fault acceptance matrix"

  @impl true
  def run(["plan"]) do
    AgentSystemsLab.FrozenFaultMatrix.plan() |> JSON.encode!() |> Mix.shell().info()
  end

  def run([action | args]) when action in ["run", "verify"] do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])
    if rest != [] or invalid != [] or Keyword.keys(opts) != [:output], do: usage()

    result =
      if action == "verify" do
        AgentSystemsLab.FrozenFaultMatrix.verify(opts[:output])
      else
        Mix.Task.run("app.start")

        callback = fn update ->
          if update[:status] == :passed do
            Mix.shell().info(
              "freeze #{update[:component] || update[:row]} repetition=#{update[:repetition]} passed"
            )
          end
        end

        AgentSystemsLab.FrozenFaultMatrix.run(Keyword.put(opts, :on_progress, callback))
      end

    case result do
      {:ok, %{report: report, output_dir: output}} ->
        Mix.shell().info(
          "all_passed=#{report["all_passed"]} row_repetitions=240 evidence=#{output}"
        )

      {:ok, report} ->
        Mix.shell().info("verified=true all_passed=#{report["all_passed"]} row_repetitions=240")

      {:error, reason} ->
        Mix.raise("Frozen acceptance failed: #{inspect(reason)}")
    end
  end

  def run(_), do: usage()

  defp usage,
    do: Mix.raise("Usage: mix lab.freeze plan | run --output ABS_PATH | verify --output ABS_PATH")
end
