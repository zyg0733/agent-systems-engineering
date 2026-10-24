defmodule AgentSystemsLab.P2Verification do
  @moduledoc """
  Repeatable P2 crash-window acceptance against real PostgreSQL commits.

  Every barrier kills an observed caller, then waits for the database lease to
  expire. No timestamp, operation, receipt or Run is fabricated by the probe.
  Runs and evidence are retained for inspection. Timings describe this controlled
  local fixture, including its deliberately short lease, rather than a service SLO.
  """
  alias AgentSystemsLab.{
    CheckpointStore,
    Context,
    DurableTools,
    History,
    HistoryDemo,
    IntentStore,
    ModelResultStore,
    Recovery,
    RecoveryDemo,
    ReconciliationQueue,
    Repo,
    RecoveryStore,
    RetryStore,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Storage.MockEffect
  import Ecto.Query

  @cases [
    {"after_claim", :hook, :after_claim, :model},
    {"model_before_commit", :commit_hook, :before_commit, :model},
    {"model_after_commit", :commit_hook, :after_commit, :model},
    {"tool_after_prepare", :tool_hook, :after_prepare, :tool},
    {"tool_before_effect", :tool_hook, :before_effect, :tool},
    {"tool_after_effect", :tool_hook, :after_effect, :tool},
    {"tool_before_receipt", :tool_hook, :before_receipt, :tool},
    {"tool_after_receipt", :tool_hook, :after_receipt, :tool},
    {"tool_result_before_commit", :commit_hook, :before_commit, :tool},
    {"tool_result_after_commit", :commit_hook, :after_commit, :tool},
    {"recovery_after_effect_twice", :tool_hook, :after_effect, :twice},
    {"retry_after_reserve", :hook, :after_retry_reserve, :retry},
    {"retry_after_schedule", :hook, :after_retry_schedule, :retry},
    {"query_before_commit", :commit_hook, :before_commit, :query},
    {"query_after_commit", :commit_hook, :after_commit, :query},
    {"manual_after_receipt", :tool_hook, :after_receipt, :manual}
  ]
  @lease_ms 200

  @doc "Returns the acceptance matrix without invoking any runtime boundary."
  def cases, do: Enum.map(@cases, fn {name, _, _, _} -> name end)

  def run(opts \\ []) do
    with :ok <- options(opts),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week10-p2")),
         :ok <- create_output(output) do
      repetitions = Keyword.get(opts, :repetitions, 20)
      prefix = "p2-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

      probes =
        for entry <- @cases, repetition <- 1..repetitions do
          {name, _, _, _} = entry
          %{entry: entry, repetition: repetition, run_id: "#{prefix}-#{name}-#{repetition}"}
        end

      execute(probes, [], output, opts, length(probes))
    end
  end

  defp execute([], completed, output, _opts, total) do
    report = report(Enum.reverse(completed), total, nil)
    write_json(Path.join(output, "report.json"), report)
    {:ok, %{output_dir: output, report: report}}
  end

  defp execute([probe | remaining], completed, output, opts, total) do
    {name, _, _, _} = probe.entry
    directory = Path.join([output, name, Integer.to_string(probe.repetition)])
    File.mkdir_p!(directory)

    result =
      try do
        notify(opts, name, probe.repetition, length(completed), total, :starting)
        summary = verify_case(probe, directory)
        write_json(Path.join(directory, "summary.json"), summary)
        {:ok, summary}
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        # Checkpoint the acceptance report after every completed case. A stopped
        # CLI therefore cannot leave a stale all_passed:true report behind.
        current = report(Enum.reverse([summary | completed]), total, nil)
        write_json(Path.join(output, "report.json"), current)

        notify_result =
          try do
            notify(opts, name, probe.repetition, length(completed) + 1, total, :passed)
            :ok
          rescue
            exception -> {:error, Exception.message(exception)}
          catch
            kind, reason -> {:error, inspect({kind, reason})}
          end

        case notify_result do
          :ok -> execute(remaining, [summary | completed], output, opts, total)
          {:error, reason} -> failure(probe, [summary | completed], output, total, reason)
        end

      {:error, reason} ->
        save_failure_snapshot(probe.run_id, directory)
        failure(probe, completed, output, total, reason)
    end
  end

  defp verify_case(probe, directory) do
    {name, key, stage, mode} = probe.entry
    id = probe.run_id
    {:ok, _} = Recovery.create_run(id, "P2: one logical write", create_options(mode))
    prepare(id, mode)

    fresh? =
      (probe.repetition == 1 and mode == :twice) or
        (probe.repetition == 1 and name == "tool_result_after_commit")

    if fresh?, do: {:ok, _} = CheckpointStore.create(id, 2)
    before_fault = evidence(id)
    write_term(Path.join(directory, "initial.bin"), before_fault)

    action = if mode in [:query, :manual], do: :reconcile, else: :step
    extra = if mode == :manual, do: manual_options(), else: []
    crash = kill_at(id, action, key, stage, extra)

    crashes =
      if mode == :twice do
        [crash, kill_at(id, :step, key, stage, [])]
      else
        [crash]
      end

    before = evidence(id)
    write_term(Path.join(directory, "crashes.bin"), crashes)
    write_term(Path.join(directory, "before.bin"), before)
    assert_window(name, before)
    fence = verify_fencing(id, List.last(crashes).claim)

    started = System.monotonic_time(:millisecond)

    if mode in [:query, :manual] and before.snapshot.state.status == :blocked do
      {:ok, _} = Recovery.reconcile(id)
    end

    done =
      if fresh? do
        {:ok, child, log} = RecoveryDemo.fresh_resume(id)
        File.write!(Path.join(directory, "fresh-resume.log"), log)
        {:ok, snapshot} = Recovery.load(id)
        true = child["state_sha256"] == Context.hash(snapshot.state)
        snapshot
      else
        {:ok, snapshot} = continue(id, 30)
        snapshot
      end

    continuation_ms = System.monotonic_time(:millisecond) - started
    :succeeded = done.state.status
    2 = done.recovery.progress.cursor
    expected_attempts = if name in ["model_before_commit", "retry_after_schedule"], do: 3, else: 2
    true = done.recovery.progress.model_attempts == expected_attempts

    true =
      done.recovery.progress.deadline_at_ms == before.snapshot.recovery.progress.deadline_at_ms

    true = done.recovery.progress.output_bytes >= before.snapshot.recovery.progress.output_bytes
    after_recovery = evidence(id)
    %{effects: 1} = after_recovery.stats
    2 = length(after_recovery.recordings)
    [] = after_recovery.queue
    true = confirmed_preserved?(before.operations, after_recovery.operations)
    true = Enum.all?(before.target_effects, &Enum.member?(after_recovery.target_effects, &1))
    true = Enum.all?(before.recordings, &Enum.member?(after_recovery.recordings, &1))
    {:ok, rebuilt} = History.rebuild(id, done.events, max_turns: done.state.max_turns)
    true = rebuilt === done.state

    if fresh? do
      {:ok, audit, log} = HistoryDemo.fresh_audit(id, done.state)
      true = audit["same_as_expected_state"]
      true = is_binary(audit["checkpoint_id"])
      2 = audit["checkpoint_seq"]
      2 = audit["verified_prefix_events"]
      2 = audit["replayed_tail_events"]
      true = audit["state_sha256"] == Context.hash(done.state)
      true = Enum.all?(audit["effect_boundary_calls"], fn {_, count} -> count == 0 end)
      File.write!(Path.join(directory, "fresh-rebuild.log"), log)
    end

    write_term(Path.join(directory, "after.bin"), after_recovery)

    %{
      "run_id" => id,
      "fault" => name,
      "repetition" => probe.repetition,
      "status" => "succeeded",
      "kill_count" => length(crashes),
      "caller_acknowledgements" => 0,
      "crashes" =>
        Enum.map(crashes, fn crash ->
          %{
            "barrier" => crash.barrier,
            "action" => crash.action,
            "caller_pid" => crash.caller_pid,
            "down_reason" => "killed",
            "claim_generation" => crash.claim.generation,
            "claim_seq" => crash.claim.seq,
            "acknowledged" => false,
            "lease_wait_ms" => crash.lease_wait_ms
          }
        end),
      "effects_before_recovery" => before.stats.effects,
      "effects" => after_recovery.stats.effects,
      "queue_entries_before_recovery" => length(before.queue),
      "queue_entries_after_recovery" => length(after_recovery.queue),
      "tool_attempts" => after_recovery.stats.attempts,
      "model_attempts" => done.recovery.progress.model_attempts,
      "expected_model_attempts" => expected_attempts,
      "recorded_model_results" => length(after_recovery.recordings),
      "accepted_cursor" => done.recovery.progress.cursor,
      "state_matches_history" => true,
      "confirmed_receipts_preserved" => true,
      "stale_claim_rejected" => fence,
      "deadline_preserved" => true,
      "output_charges_preserved" => true,
      "fresh_vm" => fresh?,
      "pure_fresh_rebuild_verified" => fresh?,
      "state_sha256" => Context.hash(done.state),
      "seq_before_recovery" => before.snapshot.state.seq,
      "seq" => done.state.seq,
      "lease_wait_ms" => Enum.sum(Enum.map(crashes, & &1.lease_wait_ms)),
      "continuation_ms" => continuation_ms,
      "evidence" => "#{name}/#{probe.repetition}"
    }
  end

  defp continue(_id, 0), do: {:error, :p2_step_limit}

  defp continue(id, remaining) do
    case Recovery.resume(id) do
      {:ok, %{state: %{status: status}} = snapshot}
      when status in [:succeeded, :failed, :cancelled, :blocked] ->
        {:ok, snapshot}

      {:ok, %{recovery: %{retry: %{next_attempt_at_ms: due}}}} when is_integer(due) ->
        Process.sleep(max(0, due - RecoveryStore.now_ms() + 1))
        continue(id, remaining - 1)

      {:error, {:retry_not_due, due}} ->
        Process.sleep(max(0, due - RecoveryStore.now_ms() + 1))
        continue(id, remaining - 1)

      error ->
        error
    end
  end

  defp prepare(id, mode) when mode in [:tool, :twice] do
    {:ok, _} = Recovery.step(id)
    :ok
  end

  defp prepare(id, mode) when mode in [:query, :manual] do
    {:ok, blocked} = Recovery.resume(id)
    :blocked = blocked.state.status
    {:ok, _} = ReconciliationQueue.get(id)
    :ok
  end

  defp prepare(_id, _mode), do: :ok

  defp create_options(mode) do
    base = [script: script(), run_timeout_ms: 60_000]

    case mode do
      :query ->
        base ++ [mock_response: :lost, retry_policy: [max_attempts: 1]]

      :manual ->
        base ++ [mock_response: :lost, mock_mode: :unqueryable, retry_policy: [max_attempts: 1]]

      :retry ->
        base ++
          [
            retry_policy: [max_attempts: 4, base_delay_ms: 25, max_delay_ms: 25],
            model_attempt_scripts: %{0 => [{:error, :unavailable}, hd(script())]}
          ]

      _ ->
        base
    end
  end

  defp manual_options do
    [
      result: {:ok, %{"confirmation" => "one original effect checked"}},
      evidence:
        "P2 controlled fixture operator confirmed the original target effect without resending it."
    ]
  end

  defp script do
    [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
      {:final, "done"}
    ]
  end

  defp kill_at(id, action, key, target, extra) do
    parent = self()
    ref = make_ref()

    observer = fn stage ->
      if stage == :after_claim, do: send(parent, {ref, :claim, current_claim(id)})
      if key == :hook and stage == target, do: barrier(parent, ref)
    end

    target_hook = fn stage -> if stage == target, do: barrier(parent, ref) end
    opts = [hook: observer, lease_ms: @lease_ms] ++ extra
    opts = if key == :hook, do: opts, else: Keyword.put(opts, key, target_hook)

    {pid, monitor} =
      spawn_monitor(fn ->
        result = apply(Recovery, action, [id, opts])
        send(parent, {ref, :ack, result})
      end)

    try do
      claim =
        receive do
          {^ref, :claim, claim} ->
            claim

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            raise "caller exited before claim: #{inspect(reason)}"
        after
          10_000 -> raise "caller did not claim #{id}"
        end

      receive do
        {^ref, :boundary} ->
          :ok

        {^ref, :ack, result} ->
          raise "caller acknowledged before #{target}: #{inspect(result)}"

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          raise "caller exited before #{target}: #{inspect(reason)}"
      after
        10_000 -> raise "caller did not reach #{target}"
      end

      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, :killed} -> :ok
      after
        5_000 -> raise "caller did not die"
      end

      receive do
        {^ref, :ack, result} -> raise "killed caller acknowledged: #{inspect(result)}"
      after
        0 -> :ok
      end

      started = System.monotonic_time(:millisecond)
      await_lease(id)

      %{
        claim: claim,
        lease_wait_ms: System.monotonic_time(:millisecond) - started,
        barrier: Atom.to_string(target),
        action: Atom.to_string(action),
        caller_pid: inspect(pid),
        observed_down_reason: :killed,
        acknowledged: false,
        evidence: evidence(id)
      }
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp barrier(parent, ref) do
    send(parent, {ref, :boundary})
    receive do: ({^ref, :release} -> :ok)
  end

  defp current_claim(id) do
    %{rows: [values]} =
      Repo.query!(
        "SELECT id, run_id, seq, claim_owner, claim_token, claim_generation, claim_expires_at FROM lab_intents WHERE run_id=$1 AND status='pending'",
        [id]
      )

    [intent_id, run_id, seq, owner, token, generation, expires_at] = values

    %{
      intent_id: intent_id,
      run_id: run_id,
      seq: seq,
      owner: owner,
      token: Ecto.UUID.load!(token),
      generation: generation,
      expires_at: DateTime.from_naive!(expires_at, "Etc/UTC")
    }
  end

  defp await_lease(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT greatest(0, ceil(extract(epoch FROM (claim_expires_at - clock_timestamp())) * 1000)::bigint) FROM lab_intents WHERE run_id=$1 AND status='pending'",
        [id]
      )

    case rows do
      [[remaining]] when is_integer(remaining) and remaining > 0 ->
        Process.sleep(remaining + 1)
        await_lease(id)

      _ ->
        :ok
    end
  end

  defp verify_fencing(id, old) do
    {:ok, successor} = IntentStore.claim(id, "p2-fencing-check", lease_ms: 5000)
    {:ok, before} = Recovery.load(id)
    {:error, _} = Storage.dispatch(id, old.seq, {:cancel, :stale_probe}, claim: old)
    {:ok, after_probe} = Recovery.load(id)
    true = before === after_probe
    :ok = IntentStore.release(successor)
    true
  end

  defp assert_window(name, evidence) do
    state = evidence.snapshot.state

    expected_seq =
      cond do
        name in [
          "after_claim",
          "model_before_commit",
          "retry_after_reserve",
          "retry_after_schedule"
        ] ->
          1

        name in ["tool_result_after_commit", "query_before_commit", "manual_after_receipt"] ->
          3

        name == "query_after_commit" ->
          4

        true ->
          2
      end

    true = state.seq == expected_seq

    expected_effects =
      if name in [
           "after_claim",
           "model_before_commit",
           "model_after_commit",
           "tool_after_prepare",
           "tool_before_effect",
           "retry_after_reserve",
           "retry_after_schedule"
         ], do: 0, else: 1

    true = evidence.stats.effects == expected_effects

    if name in [
         "tool_after_receipt",
         "tool_result_before_commit",
         "tool_result_after_commit",
         "query_before_commit",
         "query_after_commit",
         "manual_after_receipt"
       ] do
      [%{status: "completed"}] = evidence.operations
    end

    :ok
  end

  defp evidence(id) do
    {:ok, snapshot} = Recovery.load(id)
    {:ok, operations} = DurableTools.list(id)
    {:ok, recordings} = ModelResultStore.list(id)
    {:ok, retries} = RetryStore.list(id)
    {:ok, queue} = ReconciliationQueue.list(run_id: id)
    target_effects = Repo.all(from row in MockEffect, where: row.run_id == ^id)

    %{
      snapshot: snapshot,
      operations: operations,
      recordings: recordings,
      retries: retries,
      queue: queue,
      target_effects: target_effects,
      stats: DurableTools.stats(id)
    }
  end

  defp confirmed_preserved?(before, after_recovery) do
    Enum.all?(before, fn original ->
      original.status != "completed" or
        Enum.any?(after_recovery, fn final ->
          final.operation_id == original.operation_id and final.result === original.result
        end)
    end)
  end

  defp report(probes, total, failed) do
    %{
      "schema_version" => 1,
      "phase" => "P2",
      "fault_probes" => probes,
      "fault_probe_count" => length(probes),
      "expected_probe_count" => total,
      "fault_windows" => length(@cases),
      "kill_count" => Enum.sum(Enum.map(probes, & &1["kill_count"])),
      "duplicate_mock_effects" => Enum.sum(Enum.map(probes, &max(0, &1["effects"] - 1))),
      "lost_confirmed_receipts" => Enum.count(probes, &(!&1["confirmed_receipts_preserved"])),
      "stale_token_overwrites" => Enum.count(probes, &(!&1["stale_claim_rejected"])),
      "accepted_cursor_rerequests" =>
        Enum.sum(Enum.map(probes, &max(0, &1["model_attempts"] - &1["expected_model_attempts"]))),
      "fresh_vm_probes" => Enum.count(probes, & &1["fresh_vm"]),
      "lease_ms" => @lease_ms,
      "lease_wait_ms" => Enum.sum(Enum.map(probes, & &1["lease_wait_ms"])),
      "continuation_ms" => Enum.sum(Enum.map(probes, & &1["continuation_ms"])),
      "failed_probe" => failed,
      "all_passed" => is_nil(failed) and length(probes) == total
    }
  end

  defp failure(probe, completed, output, total, reason) do
    {name, _, _, _} = probe.entry

    failed = %{
      "fault" => name,
      "repetition" => probe.repetition,
      "run_id" => probe.run_id,
      "reason" => reason
    }

    report = report(Enum.reverse(completed), total, failed)
    write_json(Path.join(output, "report.json"), report)
    {:error, {:p2_verification_failed, %{output_dir: output, report: report}}}
  end

  defp save_failure_snapshot(id, directory) do
    case Recovery.load(id) do
      {:ok, snapshot} -> write_term(Path.join(directory, "failure.bin"), snapshot)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp write_term(path, value) do
    {:ok, encoded} = Codec.encode(inert(value))
    File.write!(path, encoded)
  end

  defp inert(%{__struct__: _} = value), do: value |> Map.from_struct() |> inert()

  defp inert(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {inert(key), inert(item)} end)

  defp inert(value) when is_list(value), do: Enum.map(value, &inert/1)

  defp inert(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  defp inert(value), do: value
  defp write_json(path, value), do: File.write!(path, JSON.encode!(value) <> "\n")

  defp notify(opts, name, repetition, completed, total, status) do
    if callback = Keyword.get(opts, :on_progress),
      do:
        callback.(%{
          fault: name,
          repetition: repetition,
          completed: completed,
          total: total,
          status: status
        })
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: keyword_options(opts), else: {:error, :invalid_p2_options}
  end

  defp options(_), do: {:error, :invalid_p2_options}

  defp keyword_options(opts) do
    output = Keyword.get(opts, :output, "artifacts/week10-p2")

    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:output, :repetitions, :on_progress] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_binary(output) and
         output != "" and
         String.valid?(output) and not String.contains?(output, <<0>>) and
         is_integer(Keyword.get(opts, :repetitions, 20)) and
         Keyword.get(opts, :repetitions, 20) in 1..20 and
         (is_nil(opts[:on_progress]) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_p2_options}
  end

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
