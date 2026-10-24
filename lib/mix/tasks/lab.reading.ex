defmodule Mix.Tasks.Lab.Reading do
  use Mix.Task
  @shortdoc "Prepares frozen reading packets and reports actual external-reader gates"
  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case args do
      ["prepare", "--output", path] ->
        result(AgentSystemsLab.ReaderStudy.prepare(Path.expand(path)))

      ["add", study, "--feedback", path] ->
        result(AgentSystemsLab.ReaderStudy.add_feedback(Path.expand(study), Path.expand(path)))

      ["report", study] ->
        result(AgentSystemsLab.ReaderStudy.report(Path.expand(study)))

      ["report", study, "--technical", path] ->
        result(
          AgentSystemsLab.ReaderStudy.report_from_file(Path.expand(study), Path.expand(path))
        )

      _ ->
        Mix.raise(
          "Usage: mix lab.reading prepare --output PATH | add STUDY --feedback FILE | report STUDY [--technical FILE]"
        )
    end
  end

  defp result({:ok, value}), do: Mix.shell().info(JSON.encode!(safe(value)))
  defp result({:error, reason}), do: Mix.raise("Reader study failed: #{inspect(reason)}")

  defp safe(%{output_dir: output, report: report}),
    do: %{"output_dir" => output, "report" => report}

  defp safe(other), do: other
end
