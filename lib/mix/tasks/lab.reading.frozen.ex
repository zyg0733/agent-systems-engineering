defmodule Mix.Tasks.Lab.Reading.Frozen do
  use Mix.Task
  @shortdoc "Binds a reading packet to frozen source and appends feedback issue history"
  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case args do
      ["prepare", "--source", source, "--output", output] ->
        result(
          AgentSystemsLab.ReleaseStudy.prepare(Path.expand(output), source: Path.expand(source))
        )

      ["add", study, "--feedback", input] ->
        result(AgentSystemsLab.ReleaseStudy.add_feedback(Path.expand(study), Path.expand(input)))

      ["append", study, "--event", input] ->
        result(AgentSystemsLab.ReleaseStudy.append(Path.expand(study), Path.expand(input)))

      ["report", study] ->
        result(AgentSystemsLab.ReleaseStudy.report(Path.expand(study)))

      _ ->
        Mix.raise(
          "Usage: mix lab.reading.frozen prepare --source FROZEN --output PACKET | add PACKET --feedback FILE | append PACKET --event FILE | report PACKET"
        )
    end
  end

  defp result({:ok, %{output_dir: output, report: report}}),
    do: result({:ok, %{"output_dir" => output, "report" => report}})

  defp result({:ok, value}), do: Mix.shell().info(JSON.encode!(value))
  defp result({:error, reason}), do: Mix.raise("Frozen reader study failed: #{inspect(reason)}")
end
