defmodule AgentSystemsLab.RetryDemo do
  @moduledoc "Finite retry, actual due-time waiting and visible unknown-outcome evidence."
  alias AgentSystemsLab.{
    Context,
    DurableTools,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    RecoveryDemo,
    RecoveryStore,
    RetryStore
  }

  alias AgentSystemsLab.Storage.Codec

  def run(opts \\ []) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week09-retries"))

    prefix =
      "retry-demo-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    with :ok <- create_output(output) do
      model = model_probe("#{prefix}-model", output)
      exhausted = exhausted_probe("#{prefix}-exhausted")
      tool = tool_probe("#{prefix}-tool")
      manual = timeout_probe("#{prefix}-manual", :unqueryable)
      queryable = timeout_probe("#{prefix}-queryable", :idempotent)
      {:ok, visible} = ReconciliationQueue.get(manual["run_id"])
      File.write!(Path.join(output, "queue-open.json"), JSON.encode!(queue_view(visible)) <> "\n")

      ids = Enum.map([model, exhausted, tool, manual, queryable], & &1["run_id"])

      journals =
        Enum.map(ids, fn id ->
          {:ok, retry} = RetryStore.list(id)
          {:ok, operations} = DurableTools.list(id)
          %{run_id: id, retries: retry, operations: operations}
        end)

      {:ok, data} = Codec.encode(inert(journals))
      File.write!(Path.join(output, "journals.bin"), data)

      File.write!(
        Path.join(output, "journals.log"),
        inspect(journals, pretty: true, limit: :infinity, printable_limit: :infinity, width: 100) <>
          "\n"
      )

      report = %{
        "schema_version" => 1,
        "model_retry" => model,
        "exhausted_retry" => exhausted,
        "idempotent_tool" => tool,
        "manual_unknown" => manual,
        "queryable_timeout" => queryable,
        "open_reconciliation_entries" => 1,
        "all_passed" => true
      }

      File.write!(Path.join(output, "report.json"), JSON.encode!(report) <> "\n")
      {:ok, %{output_dir: output, report: report}}
    end
  end

  @doc "An explicit demonstration caller waits for the persisted due time; no worker holds a lease while waiting."
  def drive(id, left \\ 20)
  def drive(_id, 0), do: {:error, :demo_step_limit}

  def drive(id, left) do
    with {:ok, current} <- Recovery.resume(id) do
      if current.state.status in [:succeeded, :failed, :cancelled, :blocked] do
        {:ok, current}
      else
        %{status: :waiting, next_attempt_at_ms: due} = current.recovery.retry
        Process.sleep(max(0, due - RecoveryStore.now_ms() + 1))
        drive(id, left - 1)
      end
    end
  end

  defp model_probe(id, output) do
    {:ok, _} =
      Recovery.create_run(id, "Retry the same model input",
        script: [{:final, "fallback"}],
        retry_policy: policy(base_delay_ms: 600, max_delay_ms: 800),
        model_attempt_scripts: %{
          0 => [{:error, :unavailable}, {:error, :rate_limited}, {:final, "recovered"}]
        }
      )

    RecoveryDemo.kill_step(id, :hook, :after_retry_schedule)
    {:ok, before} = Recovery.load(id)
    due = before.recovery.retry.next_attempt_at_ms
    1 = before.recovery.retry.attempts

    if RecoveryStore.now_ms() < due do
      {:ok, early} = Recovery.resume(id)
      true = early.recovery.progress === before.recovery.progress
      true = early.intent.claim_generation == before.intent.claim_generation
    end

    {:ok, child, log} = fresh_drive(id, due)
    File.write!(Path.join(output, "fresh-vm.log"), log)
    {:ok, done} = Recovery.load(id)
    true = child["state_sha256"] == Context.hash(done.state)
    :succeeded = done.state.status
    3 = done.recovery.progress.model_attempts
    1 = done.recovery.progress.cursor
    {:ok, [record]} = ModelResultStore.list(id)
    {:final, "recovered"} = record.record.response

    %{
      "run_id" => id,
      "status" => "succeeded",
      "model_attempts" => 3,
      "accepted_results" => 1,
      "cursor" => 1,
      "scheduled_caller_killed" => true,
      "fresh_vm_due_preserved" => child["due_preserved"],
      "state_sha256" => child["state_sha256"]
    }
  end

  def fresh_drive(id, expected_due) do
    environment = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev

    script = """
    config = Config.Reader.read!("config/config.exs", env: #{inspect(environment)}, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, before} = AgentSystemsLab.Recovery.load(#{inspect(id)})
    true = before.recovery.retry.next_attempt_at_ms == #{inspect(expected_due)}
    {:ok, done} = AgentSystemsLab.RetryDemo.drive(#{inspect(id)})
    IO.puts("RETRY_AUDIT=" <> JSON.encode!(%{"due_preserved" => true,
      "status" => Atom.to_string(done.state.status), "model_attempts" => done.recovery.progress.model_attempts,
      "state_sha256" => AgentSystemsLab.Context.hash(done.state)}))
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    with 0 <- code,
         line when is_binary(line) <-
           Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "RETRY_AUDIT=")),
         {:ok, report} <- JSON.decode(String.replace_prefix(line, "RETRY_AUDIT=", "")) do
      {:ok, report, output}
    else
      _ -> {:error, {:fresh_retry_failed, code, output}}
    end
  end

  defp exhausted_probe(id) do
    {:ok, _} =
      Recovery.create_run(id, "Stop after the configured retry bound",
        script: [{:error, :unavailable}],
        retry_policy: policy()
      )

    {:ok, failed} = drive(id)
    :failed = failed.state.status
    {:retry_exhausted, :model, :unavailable} = failed.state.terminal_reason
    3 = failed.recovery.progress.model_attempts
    {:ok, []} = ModelResultStore.list(id)
    {:ok, [journal]} = RetryStore.list(id)

    %{
      "run_id" => id,
      "status" => "failed",
      "expected_failure" => "retry_exhausted",
      "attempts" => journal.attempts,
      "delays_ms" => delays(journal),
      "accepted_results" => 0
    }
  end

  defp tool_probe(id) do
    {:ok, _} =
      Recovery.create_run(id, "Retry only proven no-effect transient tool failures",
        script: tool_script(),
        retry_policy: policy(),
        mock_transient_failures: 2
      )

    {:ok, _} = Recovery.step(id)

    samples =
      for _ <- 1..2 do
        {:ok, paused} = Recovery.step(id)
        :waiting = paused.recovery.retry.status
        0 = DurableTools.stats(id).effects

        Process.sleep(
          max(0, paused.recovery.retry.next_attempt_at_ms - RecoveryStore.now_ms() + 1)
        )

        0
      end

    {:ok, done} = drive(id)
    :succeeded = done.state.status
    %{effects: 1, attempts: 3} = DurableTools.stats(id)

    %{
      "run_id" => id,
      "status" => "succeeded",
      "attempts" => 3,
      "effects" => 1,
      "effect_samples" => samples ++ [1]
    }
  end

  defp timeout_probe(id, mode) do
    {:ok, _} =
      Recovery.create_run(id, "A timeout cannot prove absence of an effect",
        script: tool_script(),
        retry_policy: policy(tool_timeout_ms: 120),
        mock_mode: mode
      )

    {:ok, _} = Recovery.step(id)

    {:ok, blocked} =
      Recovery.step(id,
        tool_hook: fn at ->
          if at == :after_effect, do: Process.sleep(500)
        end
      )

    :blocked = blocked.state.status
    1 = DurableTools.stats(id).effects
    {:ok, entry} = ReconciliationQueue.get(id)
    before = DurableTools.stats(id)

    for _ <- 1..3 do
      {:ok, same} = Recovery.resume(id)
      true = same.state === blocked.state
    end

    true = DurableTools.stats(id) === before

    if mode == :idempotent do
      {:ok, _} = Recovery.reconcile(id)
      {:ok, done} = drive(id)
      :succeeded = done.state.status
      {:ok, []} = ReconciliationQueue.list(run_id: id)
      1 = DurableTools.stats(id).effects

      %{
        "run_id" => id,
        "status" => "succeeded",
        "initial_status" => "blocked",
        "effects" => 1,
        "safe_mode" => Atom.to_string(entry.safe_mode),
        "original_receipt_queried" => true
      }
    else
      {:error, :reconciliation_required} = Recovery.reconcile(id)
      {:ok, [_]} = ReconciliationQueue.list(run_id: id)

      %{
        "run_id" => id,
        "status" => "blocked",
        "effects" => 1,
        "safe_mode" => Atom.to_string(entry.safe_mode),
        "automatic_redeliveries" => 0,
        "manual_evidence_required" => true
      }
    end
  end

  defp delays(journal) do
    journal.deliveries
    |> Enum.take(2)
    |> Enum.map(fn delivery ->
      min(
        journal.policy.max_delay_ms,
        journal.policy.base_delay_ms * Integer.pow(2, delivery.attempt - 1)
      )
    end)
  end

  defp tool_script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
      {:final, "done"}
    ]

  defp policy(overrides \\ []),
    do:
      Keyword.merge(
        [
          max_attempts: 3,
          base_delay_ms: 25,
          max_delay_ms: 50,
          max_elapsed_ms: 10_000,
          tool_timeout_ms: 1000
        ],
        overrides
      )

  defp queue_view(row),
    do: %{
      run_id: row.run_id,
      seq: row.seq,
      operation_id: row.operation_id,
      tool: row.tool,
      safe_mode: Atom.to_string(row.safe_mode),
      reason: inspect(row.reason),
      queued_at: DateTime.to_iso8601(row.queued_at),
      recoverable: row.recoverable
    }

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        error -> error
      end
    end
  end

  defp inert(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp inert(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, inert(value)} end)
  defp inert(list) when is_list(list), do: Enum.map(list, &inert/1)

  defp inert(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  defp inert(value), do: value
end
