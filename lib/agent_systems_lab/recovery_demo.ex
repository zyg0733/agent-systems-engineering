defmodule AgentSystemsLab.RecoveryDemo do
  @moduledoc "Controlled real-crash probes and fresh-VM continuation evidence."
  alias AgentSystemsLab.{
    Context,
    DurableTools,
    History,
    ModelResultStore,
    Recovery,
    Repo
  }

  @cases [
    {"model_before_commit", :commit_hook, :before_commit, false},
    {"model_after_commit", :commit_hook, :after_commit, false},
    {"tool_after_prepare", :tool_hook, :after_prepare, true},
    {"tool_after_effect", :tool_hook, :after_effect, true},
    {"tool_after_receipt", :tool_hook, :after_receipt, true}
  ]

  def run(opts \\ []) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week08-recovery"))
    repetitions = Keyword.get(opts, :repetitions, 4)

    prefix =
      "recovery-demo-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    with true <-
           (is_integer(repetitions) and repetitions in 1..20) || {:error, :invalid_repetitions},
         :ok <- create_output(output) do
      probes =
        for {name, key, stage, tool?} <- @cases, index <- 1..repetitions do
          id = "#{prefix}-#{name}-#{index}"
          {:ok, _} = Recovery.create_run(id, "Recover one logical operation", script: script())
          if tool?, do: {:ok, _} = Recovery.step(id)
          kill_step(id, key, stage)
          {:ok, before} = Recovery.load(id)
          fresh_vm? = name == "tool_after_effect" and index == 1

          # A second actual crash during recovery, after the same target operation.
          if fresh_vm?, do: kill_step(id, key, stage)

          completed =
            if fresh_vm? do
              {:ok, child, log} = fresh_resume(id)
              true = child["effects"] == 1 and child["status"] == "succeeded"
              File.write!(Path.join(output, "fresh-vm.log"), log)
              {:ok, saved} = Recovery.load(id)
              true = child["state_sha256"] == Context.hash(saved.state)
              saved
            else
              {:ok, saved} = Recovery.resume(id)
              saved
            end

          {:ok, recordings} = ModelResultStore.list(id)

          {:ok, state} =
            History.rebuild(id, completed.events, max_turns: completed.state.max_turns)

          true = state === completed.state
          true = completed.state.status == :succeeded
          stats = DurableTools.stats(id)
          1 = stats.effects
          2 = length(recordings)

          %{
            "run_id" => id,
            "fault" => name,
            "repetition" => index,
            "caller_killed" => true,
            "acknowledged" => false,
            "crashed_again_during_recovery" => fresh_vm?,
            "fresh_vm" => fresh_vm?,
            "seq_before_recovery" => before.state.seq,
            "cursor_before_recovery" => before.recovery.progress.cursor,
            "status" => "succeeded",
            "effects" => stats.effects,
            "attempts" => stats.attempts,
            "model_attempts" => completed.recovery.progress.model_attempts,
            "recorded_model_results" => length(recordings),
            "state_matches_history" => true
          }
        end

      query = query_probe("#{prefix}-query")
      file = file_probe("#{prefix}-file", output)

      report = %{
        "schema_version" => 1,
        "fault_probes" => probes,
        "fault_probe_count" => length(probes),
        "kill_count" => length(probes) + 2,
        "duplicate_mock_effects" => Enum.sum(Enum.map(probes, &max(0, &1["effects"] - 1))),
        "query_reconciliation" => query,
        "ambiguous_file" => file,
        "all_passed" => true
      }

      File.write!(Path.join(output, "report.json"), JSON.encode!(report) <> "\n")
      {:ok, %{output_dir: output, report: report}}
    end
  end

  @doc "Waits for an actual lease expiry after killing the caller at an observed hook."
  def kill_step(id, key, stage) do
    parent = self()
    ref = make_ref()

    hook = fn reached ->
      if reached == stage do
        send(parent, {ref, :boundary})
        receive do: ({^ref, :release} -> :ok)
      end
    end

    {pid, monitor} =
      spawn_monitor(fn ->
        result = Recovery.step(id, [{key, hook}, {:lease_ms, 250}])
        send(parent, {ref, :ack, result})
      end)

    receive do
      {^ref, :boundary} ->
        :ok

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "Probe exited before boundary: #{inspect(reason)}"
    after
      5_000 ->
        Process.exit(pid, :kill)
        raise "Probe did not reach #{stage}"
    end

    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, :killed} -> :ok)

    receive do
      {^ref, :ack, _} -> raise "Probe acknowledged unexpectedly"
    after
      0 -> :ok
    end

    %{rows: [[remaining]]} =
      Repo.query!(
        "SELECT greatest(0, ceil(extract(epoch FROM (claim_expires_at - clock_timestamp())) * 1000)::bigint) FROM lab_intents WHERE run_id=$1 AND status='pending'",
        [id]
      )

    if remaining, do: Process.sleep(remaining + 1)
    :ok
  end

  def fresh_resume(id) do
    environment = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev

    code = """
    config = Config.Reader.read!("config/config.exs", env: #{inspect(environment)}, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, done} = AgentSystemsLab.Recovery.resume(#{inspect(id)})
    stats = AgentSystemsLab.DurableTools.stats(#{inspect(id)})
    {:ok, results} = AgentSystemsLab.ModelResultStore.list(#{inspect(id)})
    report = %{"status" => Atom.to_string(done.state.status), "seq" => done.state.seq,
      "cursor" => done.recovery.progress.cursor, "model_attempts" => done.recovery.progress.model_attempts,
      "effects" => stats.effects, "attempts" => stats.attempts, "recorded_model_results" => length(results),
      "state_sha256" => AgentSystemsLab.Context.hash(done.state)}
    IO.puts("RECOVERY_AUDIT=" <> JSON.encode!(report))
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", code],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    with 0 <- status,
         line when is_binary(line) <-
           Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "RECOVERY_AUDIT=")),
         {:ok, report} <- JSON.decode(String.replace_prefix(line, "RECOVERY_AUDIT=", "")) do
      {:ok, report, output}
    else
      _ -> {:error, {:fresh_resume_failed, status, output}}
    end
  end

  defp query_probe(id) do
    {:ok, _} =
      Recovery.create_run(id, "Query a lost receipt", script: script(), mock_response: :lost)

    {:ok, blocked} = Recovery.resume(id)
    :blocked = blocked.state.status
    {:ok, _} = Recovery.reconcile(id)
    {:ok, done} = Recovery.resume(id)
    1 = DurableTools.stats(id).effects

    %{
      "run_id" => id,
      "paused_status" => "blocked",
      "status" => Atom.to_string(done.state.status),
      "effects" => 1,
      "query_confirmed_original_receipt" => true
    }
  end

  defp file_probe(id, output) do
    root = Path.join(output, "workspace")
    File.mkdir!(root)

    call =
      {:call,
       %{
         operation_id: "file-once",
         tool: "file_write",
         arguments: %{
           "path" => "receipt.txt",
           "content" => "one original write\n",
           "expected_sha256" => "absent"
         }
       }}

    {:ok, _} =
      Recovery.create_run(id, "Preserve the ambiguous file effect",
        script: [call, {:final, "checked"}],
        workspace: root
      )

    {:ok, _} = Recovery.step(id)
    kill_step(id, :tool_hook, :after_effect)
    path = Path.join(root, "receipt.txt")
    "one original write\n" = File.read!(path)
    {:ok, blocked} = Recovery.resume(id)
    :blocked = blocked.state.status
    {:error, :reconciliation_required} = Recovery.reconcile(id)
    "one original write\n" = File.read!(path)

    {:ok, _} =
      Recovery.reconcile(id,
        result:
          {:ok, %{"checked_sha256" => AgentSystemsLab.Tools.Workspace.sha256(File.read!(path))}},
        evidence:
          "Trusted demonstration operator inspected the controlled fixture and original write; automatic replay remained blocked."
      )

    {:ok, done} = Recovery.resume(id)
    "one original write\n" = File.read!(path)

    %{
      "run_id" => id,
      "paused_status" => "blocked",
      "automatic_reconcile" => "reconciliation_required",
      "status" => Atom.to_string(done.state.status),
      "operator_evidence_saved" => true,
      "file_unchanged_by_recovery" => true
    }
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
      {:final, "done"}
    ]

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        error -> error
      end
    end
  end
end
