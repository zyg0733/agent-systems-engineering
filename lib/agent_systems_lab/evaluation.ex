defmodule AgentSystemsLab.Evaluation do
  @moduledoc """
  Sequential, fixed-split offline evaluations over new durable Runs.

  Each invocation writes a new directory, a complete plan before execution,
  individual safe sample evidence and a validated report. Interrupted batches
  remain explicitly incomplete; they cannot be compared as completed reports.
  Saved report comparison is pure and never starts or resumes execution.
  """
  alias AgentSystemsLab.Evaluation.{Comparison, Report, Runner, Suite}

  @sample_keys ~w(task_id task_hash trial split run_id task_success classification failure_class usage latency_us semantic_result_hash)
  @max_report_bytes 2_097_152
  @options [:output, :split, :repetitions, :profile, :baseline, :on_progress]

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated(),
         {:ok, suite} <- Suite.load(),
         split = Keyword.get(opts, :split, "dev"),
         tasks = Suite.tasks(suite, split) |> Enum.sort_by(& &1["id"]),
         manifest = manifest(suite, tasks, opts),
         {:ok, baseline} <- baseline(opts[:baseline], manifest),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week20-evaluation")),
         :ok <- create_output(output) do
      namespace = "w20-" <> Ecto.UUID.generate()
      plan = plan(tasks, manifest, namespace)
      context = %{output: output, namespace: namespace, manifest: manifest, plan: plan}

      write_json(Path.join(output, "manifest.json"), %{
        "schema_version" => 1,
        "namespace" => namespace,
        "evaluation_manifest" => manifest,
        "fixture_hashes" => suite["fixture_hashes"],
        "planned_samples" => Enum.map(plan, &Map.drop(&1, ["task"])),
        "scope" => "public scripted teaching corpus; synthetic lab units, no provider invoice"
      })

      File.write!(Path.join(output, "samples.jsonl"), "")
      status(context, [], "running")
      execute(context, suite, opts, baseline)
    end
  end

  @doc "Bounded inert JSON report loading, with every derived field revalidated."
  def read_report(path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_report_bytes <- File.lstat(path),
         {:ok, bytes} <- read_bounded(path),
         true <- byte_size(bytes) <= @max_report_bytes,
         {:ok, report} <- decode_json(bytes),
         :ok <- Report.validate(report) do
      {:ok, report}
    else
      {:error, {:invalid_report, _}} = error -> error
      _ -> {:error, :invalid_evaluation_report_file}
    end
  rescue
    _ -> {:error, :invalid_evaluation_report_file}
  end

  def read_report(_), do: {:error, :invalid_evaluation_report_file}

  defp read_bounded(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, @max_report_bytes + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) <= @max_report_bytes -> {:ok, bytes}
          _ -> {:error, :report_limit}
        end
      after
        File.close(io)
      end
    end
  end

  defp decode_json(bytes) do
    case JSON.decode(bytes, nil,
           object_finish: fn pairs, old ->
             keys = Enum.map(pairs, &elem(&1, 0))
             if length(keys) != length(Enum.uniq(keys)), do: raise(ArgumentError, "duplicate key")
             {Map.new(pairs), old}
           end
         ) do
      {value, nil, rest} ->
        if String.trim(rest) == "", do: {:ok, value}, else: {:error, :invalid_json}

      _ ->
        {:error, :invalid_json}
    end
  end

  @doc "Compare completed report files and save the result in a new host directory."
  def compare_files(baseline_path, candidate_path, opts \\ []) do
    with :ok <- comparison_options(opts),
         {:ok, baseline} <- read_report(baseline_path),
         {:ok, candidate} <- read_report(candidate_path),
         {:ok, comparison} <-
           Comparison.compare(baseline, candidate, Keyword.delete(opts, :output)),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week20-comparison")),
         :ok <- create_output(output) do
      write_json(Path.join(output, "comparison.json"), comparison)
      {:ok, %{output_dir: output, comparison: comparison}}
    end
  end

  defp execute(context, suite, opts, baseline) do
    try do
      samples =
        Enum.map(context.plan, fn row ->
          progress(opts, row, "starting")
          directory = Path.join(context.output, row["directory"])

          sample =
            case Runner.execute(
                   suite,
                   row["task"],
                   context.manifest["profile"],
                   row["trial"],
                   directory,
                   run_id: row["run_id"]
                 ) do
              {:ok, sample} -> sample
              {:error, _} -> throw(:sample_setup_failed)
            end

          write_json(Path.join(context.output, row["directory"] <> ".sample.json"), sample)
          canonical = Map.take(sample, @sample_keys)

          File.write!(
            Path.join(context.output, "samples.jsonl"),
            JSON.encode!(canonical) <> "\n",
            [:append]
          )

          status(context, [], "running")
          progress(opts, row, "completed")
          canonical
        end)

      with {:ok, unchanged} <- Suite.load(),
           true <- unchanged["hash"] == suite["hash"],
           {:ok, report} <- Report.build(context.manifest, samples),
           {:ok, comparison} <- compare_optional(baseline, report) do
        write_json(Path.join(context.output, "report.json"), report)
        if comparison, do: write_json(Path.join(context.output, "comparison.json"), comparison)
        status(context, samples, "completed")
        {:ok, %{output_dir: context.output, report: report, comparison: comparison}}
      else
        false -> failed(context, :suite_changed)
        {:error, _} -> failed(context, :report_validation_failed)
      end
    rescue
      _ -> failed(context, :evaluation_interrupted)
    catch
      :sample_setup_failed -> failed(context, :sample_setup_failed)
      _, _ -> failed(context, :evaluation_interrupted)
    end
  end

  defp manifest(suite, tasks, opts) do
    %{
      "schema_version" => 1,
      "profile" => Keyword.get(opts, :profile, "reference"),
      "seed" => 0,
      "protocol" => %{
        "suite_hash" => suite["hash"],
        "scorer_hash" => suite["scorer_hash"],
        "pricing_hash" => suite["pricing_hash"],
        "split" => Keyword.get(opts, :split, "dev"),
        "task_ids" => Enum.map(tasks, & &1["id"]),
        "task_hashes" => Map.new(tasks, &{&1["id"], &1["hash"]}),
        "repetitions" => Keyword.get(opts, :repetitions, 2),
        "execution_contract" =>
          "durable_scripted_files_v1:" <> AgentSystemsLab.Context.hash(Runner.contract()),
        "runtime_version" =>
          "elixir:#{System.version()};otp:#{:erlang.system_info(:otp_release)};erts:#{:erlang.system_info(:version)};arch:#{:erlang.system_info(:system_architecture)}",
        "measurement_scope" => "monotonic_us_execution_plus_external_scorer_v1"
      }
    }
  end

  defp plan(tasks, manifest, namespace) do
    for task <- tasks, trial <- 1..manifest["protocol"]["repetitions"] do
      %{
        "task" => task,
        "task_id" => task["id"],
        "task_hash" => task["hash"],
        "trial" => trial,
        "split" => task["split"],
        "run_id" => namespace <> "-" <> task["id"] <> "-" <> Integer.to_string(trial),
        "directory" => "#{task["id"]}-#{trial}"
      }
    end
  end

  defp baseline(nil, _manifest), do: {:ok, nil}

  defp baseline(path, manifest) do
    with {:ok, baseline} <- read_report(path) do
      if baseline["manifest"]["protocol"] == manifest["protocol"],
        do: {:ok, baseline},
        else: {:error, :incompatible_evaluation_baseline}
    end
  end

  defp compare_optional(nil, _), do: {:ok, nil}
  defp compare_optional(baseline, candidate), do: Comparison.compare(baseline, candidate)

  defp failed(context, reason) do
    # Completed lines remain available for investigation. No partial report is
    # presented as a valid complete cohort or usable baseline.
    status(context, [], "incomplete", reason)
    {:error, {:evaluation_failed, %{output_dir: context.output, reason: reason}}}
  end

  defp status(context, samples, state, reason \\ nil) do
    completed =
      case File.read(Path.join(context.output, "samples.jsonl")) do
        {:ok, bytes} -> length(String.split(bytes, "\n", trim: true))
        _ -> length(samples)
      end

    write_json(Path.join(context.output, "status.json"), %{
      "schema_version" => 1,
      "state" => state,
      "complete" => state == "completed",
      "planned_count" => length(context.plan),
      "completed_count" => completed,
      "reason" => if(reason, do: Atom.to_string(reason))
    })
  end

  defp progress(opts, row, state) do
    if callback = opts[:on_progress],
      do: callback.(%{task_id: row["task_id"], trial: row["trial"], state: state})
  end

  defp isolated do
    cond do
      not Application.get_env(:agent_systems_lab, :database_enabled, true) ->
        {:error, :database_required}

      Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
          Process.whereis(AgentSystemsLab.Scheduler) ->
        {:error, :global_scheduler_enabled}

      true ->
        :ok
    end
  end

  defp options(opts) do
    valid =
      Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
        Keyword.keys(opts) -- @options == [] and
        path?(Keyword.get(opts, :output, "artifacts/week20-evaluation")) and
        Keyword.get(opts, :split, "dev") in ["dev", "holdout"] and
        Keyword.get(opts, :profile, "reference") in ["reference", "regressed"] and
        is_integer(Keyword.get(opts, :repetitions, 2)) and
        Keyword.get(opts, :repetitions, 2) in 1..10 and
        (not Keyword.has_key?(opts, :baseline) or path?(opts[:baseline])) and
        (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1))

    if valid, do: :ok, else: {:error, :invalid_evaluation_options}
  rescue
    _ -> {:error, :invalid_evaluation_options}
  end

  defp comparison_options(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         path?(Keyword.get(opts, :output, "artifacts/week20-comparison")),
       do: :ok,
       else: {:error, :invalid_evaluation_comparison_options}
  rescue
    _ -> {:error, :invalid_evaluation_comparison_options}
  end

  defp path?(path),
    do:
      is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
        not String.contains?(path, <<0>>)

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        _ -> {:error, :evaluation_output_unavailable}
      end
    end
  end

  defp write_json(path, value) do
    File.write!(path <> ".tmp", JSON.encode!(value) <> "\n")
    File.rename!(path <> ".tmp", path)
  end
end
