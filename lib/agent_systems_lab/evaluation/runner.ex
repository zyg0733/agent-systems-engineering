defmodule AgentSystemsLab.Evaluation.Runner do
  @moduledoc """
  Executes one fixed evaluation task as a new durable Run in a private workspace.

  Samples use charged durable accounting, never the lossy observability buffer.
  The fixed external scorer receives a separately captured artifact, not a live
  workspace or a runtime capability. Scoring cannot authorize another effect.
  A failed, ambiguous or bounded-out execution is still a sample.
  """

  alias AgentSystemsLab.{Context, DurableTools, ModelResultStore, Recovery, TaskBudgetStore}
  alias AgentSystemsLab.Evaluation.Scorer
  alias AgentSystemsLab.Tools.{Files, Workspace}

  @options [:execution_timeout_ms, :scorer_timeout_ms, :max_steps, :run_id]
  @terminal [:succeeded, :failed, :cancelled]
  @max_steps 6
  @execution_timeout_ms 10_000
  @scorer_timeout_ms 3_000
  @budget [
    max_turns: 3,
    max_model_attempts: 3,
    max_tool_calls: 1,
    max_output_bytes: 65_536,
    model_timeout_ms: 1_000,
    run_timeout_ms: 5_000,
    task_budget: [max_dispatches: 6, execution_timeout_ms: 2_000]
  ]

  def budget, do: @budget

  @doc "The versioned fixed execution and scoring bounds used by default cohorts."
  def contract do
    %{
      "schema_version" => 1,
      "runtime_budget_hash" => Context.hash(@budget),
      "max_steps" => @max_steps,
      "execution_timeout_ms" => @execution_timeout_ms,
      "scorer_timeout_ms" => @scorer_timeout_ms
    }
  end

  @doc "Runs one task/profile/trial; an existing output directory is never reused."
  def execute(suite, task, profile, trial, directory, opts \\ []) do
    with :ok <- arguments(suite, task, profile, trial, directory, opts),
         :ok <- database(),
         :ok <- create_directory(directory) do
      started = now()
      directory = Path.expand(directory)
      run_id = Keyword.get_lazy(opts, :run_id, fn -> "eval-" <> Ecto.UUID.generate() end)
      sample_id = task["id"] <> ":" <> Integer.to_string(trial)
      File.write!(Path.join(directory, "run.json"), JSON.encode!(%{"run_id" => run_id}))

      execution = execute_task(task, profile, run_id, directory, opts)
      execution_us = elapsed(started)
      before = source(run_id)
      scoring_started = now()
      artifact = capture(task, directory)
      grade = score(suite, task, sample_id, artifact, opts)
      scorer_us = elapsed(scoring_started)
      after_scoring = source(run_id)
      unchanged = same_source?(before, after_scoring) and same_capture?(artifact)

      {:ok,
       sample(suite, task, profile, trial, run_id, sample_id, execution, before,
         grade: grade,
         artifact: artifact,
         source_unchanged: unchanged,
         contract: effective_contract(opts),
         execution_us: execution_us,
         scorer_us: scorer_us,
         total_us: elapsed(started)
       )}
    end
  rescue
    _ -> {:error, :sample_setup_failed}
  catch
    _, _ -> {:error, :sample_setup_failed}
  end

  @doc "Returns the original source fingerprint without executing or grading."
  def fingerprint(run_id) do
    with {:ok, evidence} <- source(run_id), do: {:ok, evidence["fingerprint"]}
  end

  @doc false
  def settled_usage({:ok, %{"usage" => usage}}, true) when is_map(usage), do: usage
  def settled_usage(_source, _unchanged), do: nil

  @doc "Read-only verified source evidence used for independent sample audits."
  def source(run_id) do
    with {:ok, snapshot} <- Recovery.load(run_id),
         {:ok, budget} when not is_nil(budget) <- TaskBudgetStore.load(run_id),
         {:ok, recordings} <- ModelResultStore.list(run_id),
         {:ok, journal} <- DurableTools.list(run_id) do
      usage = %{
        "model_attempts" => snapshot.recovery.progress.model_attempts,
        "output_bytes" => snapshot.recovery.progress.output_bytes,
        "tool_attempts" =>
          journal |> Enum.flat_map(& &1.attempts) |> Enum.count(&(&1.kind == "execution")),
        "dispatches" => budget.progress.dispatches
      }

      {:ok,
       %{
         "fingerprint" => Context.hash({snapshot, budget, recordings, journal}),
         "status" => Atom.to_string(snapshot.state.status),
         "failure_class" => failure(snapshot.state.terminal_reason),
         "usage" => usage,
         "recording_count" => length(recordings),
         "recording_responses_sha256" => Context.hash(Enum.map(recordings, & &1.record.response)),
         "operations" =>
           Enum.map(journal, fn operation ->
             %{
               "operation_id" => operation.operation_id,
               "tool" => operation.input.tool,
               "status" => operation.status,
               "input_sha256" => Context.hash(operation.input),
               "result_sha256" => Context.hash(operation.result),
               "attempts" =>
                 Enum.map(operation.attempts, fn attempt ->
                   %{
                     "kind" => attempt.kind,
                     "outcome" => attempt.outcome,
                     "result_sha256" => Context.hash(attempt.result)
                   }
                 end)
             }
           end)
       }}
    else
      _ -> {:error, :source_unavailable}
    end
  rescue
    _ -> {:error, :source_unavailable}
  catch
    _, _ -> {:error, :source_unavailable}
  end

  defp execute_task(task, profile, id, directory, opts) do
    worker =
      Task.Supervisor.async_nolink(AgentSystemsLab.ProviderSupervisor, fn ->
        guarded_execution(task, profile, id, directory, opts)
      end)

    case Task.yield(worker, Keyword.get(opts, :execution_timeout_ms, @execution_timeout_ms)) do
      {:ok, {:ok, %{state: %{status: status}}}} when status in @terminal ->
        :complete

      {:ok, {:ok, %{state: %{status: :blocked}}}} ->
        :unknown

      {:ok, {:error, :step_limit}} ->
        :step_limit

      {:ok, _} ->
        :harness_error

      {:exit, _} ->
        :harness_error

      nil ->
        Task.shutdown(worker, :brutal_kill)
        :timeout
    end
  rescue
    _ -> :harness_error
  catch
    _, _ -> :harness_error
  end

  defp guarded_execution(task, profile, id, directory, opts) do
    try do
      workspace = Path.join(directory, "workspace")
      File.mkdir!(workspace)

      with :ok <- initial_files(workspace, task["initial_files"]),
           {:ok, _} <-
             Recovery.create_run(
               id,
               task["input"],
               @budget ++ [workspace: workspace, script: script(task, profile)]
             ) do
        Recovery.resume(id, max_steps: Keyword.get(opts, :max_steps, @max_steps))
      else
        _ -> {:error, :execution_failed}
      end
    rescue
      _ -> {:error, :execution_failed}
    catch
      _, _ -> {:error, :execution_failed}
    end
  end

  defp initial_files(workspace, files) do
    with {:ok, initial} <- Files.new(workspace) do
      files
      |> Enum.sort()
      |> Enum.reduce_while({:ok, initial}, fn {path, bytes}, {:ok, state} ->
        {result, next} =
          Files.execute(state, "fixture-" <> Workspace.sha256(path), "file_write", %{
            "path" => path,
            "content" => bytes,
            "expected_sha256" => "absent"
          })

        case result do
          {:ok, _} -> {:cont, {:ok, next}}
          _ -> {:halt, {:error, :fixture_failed}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  # The oracle is deliberately absent from this enrollment and from all model
  # input. A profile chooses only a fixed provider response and cannot adjust the
  # task, allowed tools, limits, or grader.
  defp script(task, profile) do
    candidate = task["profiles"][profile]

    write =
      {:call,
       %{
         operation_id: "eval-artifact",
         tool: "file_write",
         arguments: %{
           "path" => task["artifact_path"],
           "content" => candidate["artifact"],
           "expected_sha256" => "absent"
         }
       }}

    if candidate["mode"] == "budget_exhaustion" do
      [
        write,
        {:call,
         %{
           operation_id: "eval-extra-call",
           tool: "file_read",
           arguments: %{"path" => task["artifact_path"]}
         }},
        {:final, "TASK SUCCEEDED"}
      ]
    else
      [write, {:final, "TASK SUCCEEDED"}]
    end
  end

  defp capture(task, directory) do
    with {:ok, workspace} <- Workspace.new(Path.join(directory, "workspace")),
         {:ok, bytes} <- Workspace.read(workspace, task["artifact_path"]),
         snapshot = Path.join(directory, "scoring"),
         :ok <- File.mkdir(snapshot),
         path = Path.join(snapshot, "artifact.txt"),
         :ok <- File.write(path, bytes, [:exclusive]),
         :ok <- File.chmod(path, 0o444) do
      {:ok, %{"path" => path, "sha256" => Workspace.sha256(bytes), "bytes" => byte_size(bytes)}}
    else
      _ -> {:error, :artifact_unavailable}
    end
  rescue
    _ -> {:error, :artifact_unavailable}
  end

  defp score(suite, task, sample_id, {:ok, artifact}, opts) do
    Scorer.score(suite, task, sample_id, artifact["path"],
      timeout_ms: Keyword.get(opts, :scorer_timeout_ms, @scorer_timeout_ms)
    )
  rescue
    _ -> {:error, %{"status" => "scorer_error", "reason" => "scorer_exception"}}
  catch
    _, _ -> {:error, %{"status" => "scorer_error", "reason" => "scorer_exit"}}
  end

  defp score(_suite, _task, _sample_id, {:error, _}, _opts),
    do: {:error, %{"status" => "scorer_error", "reason" => "artifact_unavailable"}}

  defp sample(suite, task, profile, trial, id, sample_id, execution, source, attrs) do
    grade = safe_grade(attrs[:grade])
    source_data = if match?({:ok, _}, source), do: elem(source, 1)
    status = if source_data, do: source_data["status"], else: "unavailable"
    usage = settled_usage(source, attrs[:source_unchanged])

    failure_class =
      cond do
        execution in [:timeout, :step_limit] -> "timeout"
        not attrs[:source_unchanged] -> "harness_error"
        execution == :unknown or status == "blocked" -> "unknown"
        execution == :harness_error or is_nil(source_data) -> "harness_error"
        status != "succeeded" -> source_data["failure_class"]
        grade["status"] == "scorer_error" -> "scorer_error"
        grade["passed"] != true -> "incorrect"
        true -> "success"
      end

    success = failure_class == "success"

    artifact_sha256 =
      if match?({:ok, _}, attrs[:artifact]), do: elem(attrs[:artifact], 1)["sha256"]

    semantic = %{
      "task_hash" => task["hash"],
      "status" => status,
      "failure_class" => failure_class,
      "artifact_sha256" => artifact_sha256,
      "grade_passed" => grade["passed"],
      "usage" => usage,
      "operations" => if(source_data, do: source_data["operations"]),
      "recording_responses_sha256" =>
        if(source_data, do: source_data["recording_responses_sha256"])
    }

    %{
      "schema_version" => 1,
      "sample_id" => sample_id,
      "task_id" => task["id"],
      "task_hash" => task["hash"],
      "split" => task["split"],
      "trial" => trial,
      "profile" => profile,
      "run_id" => id,
      "status" => status,
      "task_success" => success,
      "classification" => classification(failure_class),
      "failure_class" => failure_class,
      "usage" => usage,
      "latency_us" => %{
        "execution" => attrs[:execution_us],
        "scoring" => attrs[:scorer_us],
        "total" => attrs[:total_us]
      },
      "artifact_sha256" => artifact_sha256,
      "grade" => grade,
      "semantic_result_hash" => Context.hash(semantic),
      "evidence" => %{
        "origin" => "durable",
        "source_sha256" => if(source_data, do: source_data["fingerprint"]),
        "source_unchanged_by_scorer" => attrs[:source_unchanged],
        "recording_count" => if(source_data, do: source_data["recording_count"]),
        "operation_count" => if(source_data, do: length(source_data["operations"])),
        "artifact_snapshot" => if(artifact_sha256, do: "scoring/artifact.txt")
      },
      "protocol" =>
        suite
        |> Map.take(~w(suite_hash scorer_hash pricing_hash manifest_hash))
        |> Map.put("runtime_budget_hash", Context.hash(@budget))
        |> Map.put("execution_contract_hash", Context.hash(attrs[:contract]))
    }
  end

  defp safe_grade({:ok, grade}) when is_map(grade),
    do:
      Map.take(
        grade,
        ~w(status passed reason task_hash scorer_hash artifact_sha256 os_pid project_app_started)
      )

  defp safe_grade({:error, grade}) when is_map(grade),
    do: Map.take(grade, ~w(status passed reason task_hash scorer_hash artifact_sha256 os_pid))

  defp safe_grade(_), do: %{"status" => "scorer_error", "reason" => "invalid_scorer_result"}

  defp failure({:budget_exceeded, reason})
       when reason in [:run_timeout, :model_timeout, :execution_timeout],
       do: "timeout"

  defp failure({:budget_exceeded, _}), do: "budget"
  defp failure({:retry_exhausted, _scope, reason}), do: failure(reason)
  defp failure(:max_turns), do: "budget"
  defp failure(:reconciliation_required), do: "unknown"

  defp failure(reason) when reason in [:permission_denied, :path_escape, :path_not_allowed],
    do: "permission"

  defp failure(_), do: "harness_error"
  defp classification("success"), do: "success"
  defp classification("scorer_error"), do: "scorer_error"
  defp classification("harness_error"), do: "harness_error"
  defp classification(_), do: "task_failure"

  defp same_source?({:ok, before}, {:ok, after_scoring}),
    do: before["fingerprint"] == after_scoring["fingerprint"]

  defp same_source?(_, _), do: false
  defp same_capture?({:error, _}), do: true

  defp same_capture?({:ok, artifact}) do
    with {:ok, bytes} <- File.read(artifact["path"]),
         do: Workspace.sha256(bytes) == artifact["sha256"],
         else: (_ -> false)
  end

  defp arguments(suite, task, profile, trial, directory, opts) do
    valid =
      is_map(suite) and is_map(task) and is_map(suite["pricing"]) and
        Enum.all?(~w(model_attempt_units output_byte_units tool_attempt_units), fn key ->
          is_integer(suite["pricing"][key]) and suite["pricing"][key] >= 0
        end) and is_binary(task["id"]) and byte_size(task["id"]) in 1..128 and
        is_binary(task["hash"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, task["hash"]) and
        task["split"] in ["dev", "holdout"] and is_binary(task["input"]) and
        is_map(task["initial_files"]) and task["artifact_path"] == "artifact.txt" and
        is_map(task["profiles"]) and profile in ["reference", "regressed"] and
        is_map(task["profiles"][profile]) and
        is_binary(task["profiles"][profile]["artifact"]) and
        task["profiles"][profile]["mode"] in ["artifact", "budget_exhaustion"] and
        is_integer(trial) and trial in 1..100 and is_binary(directory) and
        byte_size(directory) in 1..4096 and String.valid?(directory) and
        :binary.match(directory, <<0>>) == :nomatch and Keyword.keyword?(opts) and
        length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
        Keyword.keys(opts) -- @options == [] and
        Enum.all?(opts, fn
          {:run_id, value} ->
            is_binary(value) and byte_size(value) in 1..128 and
              Regex.match?(~r/\A[A-Za-z0-9_.:@-]+\z/, value)

          {:max_steps, value} ->
            is_integer(value) and value in 0..100

          {_key, value} ->
            is_integer(value) and value in 1..10_000
        end)

    if valid, do: :ok, else: {:error, :invalid_evaluation_runner_arguments}
  rescue
    _ -> {:error, :invalid_evaluation_runner_arguments}
  end

  defp database do
    if Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: :ok,
      else: {:error, :database_required}
  end

  defp effective_contract(opts) do
    opts
    |> Keyword.take([:max_steps, :execution_timeout_ms, :scorer_timeout_ms])
    |> Enum.reduce(contract(), fn {key, value}, result ->
      Map.put(result, Atom.to_string(key), value)
    end)
  end

  defp create_directory(directory) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(directory))) do
      case File.mkdir(directory) do
        :ok -> :ok
        {:error, :eexist} -> {:error, :sample_directory_exists}
        _ -> {:error, :sample_directory_unavailable}
      end
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
  defp elapsed(started), do: max(0, now() - started)
end
