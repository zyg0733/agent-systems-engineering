defmodule AgentSystemsLab.FencingDemo do
  @moduledoc """
  Real SIGSTOP/SIGCONT acceptance of lease expiry and stale-generation fencing.

  Each probe owns a separate BEAM and a scoped Scheduler. A diagnostic controller
  gate lets its original executor make a late write before the overdue heartbeat
  stops it. SIGSTOP itself pauses the entire BEAM, including every heartbeat.
  PostgreSQL time and committed claims, rather than edited timestamps, decide
  takeover. These local Mock probes do not promise exactly-once external effects.
  """
  alias AgentSystemsLab.{
    DurableTools,
    History,
    IntentStore,
    ModelResultStore,
    Recovery,
    RecoveryStore,
    Repo,
    Scheduler,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.Result

  @cases [
    {"model_before_accept_same_seq", :hook, :after_model, :model},
    {"tool_before_effect_same_seq", :tool_hook, :before_effect, :tool},
    {"tool_after_effect_same_seq", :tool_hook, :after_effect, :tool},
    {"tool_after_receipt_same_seq", :tool_hook, :after_receipt, :tool},
    {"model_after_takeover_commit", :hook, :after_model, :committed}
  ]
  @lease_ms 400
  @renew_ms 80
  @wait_ms 10_000

  def cases, do: Enum.map(@cases, &elem(&1, 0))

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated_fixture(),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week12-fencing")),
         :ok <- create_output(output) do
      prefix = "fence-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      repetitions = Keyword.get(opts, :repetitions, 5)

      probes =
        for entry <- @cases, index <- 1..repetitions do
          %{entry: entry, repetition: index, run_id: "#{prefix}-#{elem(entry, 0)}-#{index}"}
        end

      execute(probes, [], output, opts, length(probes))
    end
  end

  defp execute([], completed, output, _opts, total) do
    report = report(Enum.reverse(completed), total, nil)
    write_json(Path.join(output, "report.json"), report)
    {:ok, %{output_dir: output, report: report}}
  end

  defp execute([probe | rest], completed, output, opts, total) do
    {name, _, _, _} = probe.entry
    directory = Path.join([output, name, Integer.to_string(probe.repetition)])
    File.mkdir_p!(directory)

    result =
      try do
        progress(opts, probe, length(completed), total, :starting)
        summary = verify(probe, directory, opts, length(completed), total)
        write_json(Path.join(directory, "summary.json"), summary)
        {:ok, summary}
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        completed = [summary | completed]
        write_json(Path.join(output, "report.json"), report(Enum.reverse(completed), total, nil))

        try do
          progress(opts, probe, length(completed), total, :passed)
          execute(rest, completed, output, opts, total)
        rescue
          exception -> failed(probe, completed, output, total, Exception.message(exception))
        end

      {:error, reason} ->
        failed(probe, completed, output, total, reason)
    end
  end

  defp verify(probe, directory, opts, completed, total) do
    {name, key, stage, mode} = probe.entry
    id = probe.run_id
    script = if mode == :tool, do: script(), else: [{:final, "accepted successor"}]

    {:ok, _} =
      Recovery.create_run(id, "W12: fence the paused generation",
        script: script,
        model_timeout_ms: 30_000,
        run_timeout_ms: 120_000
      )

    if mode == :tool, do: {:ok, _} = Recovery.step(id)
    save_evidence(directory, "initial", evidence(id))
    nonce = Ecto.UUID.generate()

    child_options = %{
      "run_id" => id,
      "directory" => directory,
      "nonce" => nonce,
      "key" => Atom.to_string(key),
      "stage" => Atom.to_string(stage),
      "environment" => Atom.to_string(if(Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev))
    }

    {port, pid} = spawn_child(child_options)

    try do
      write_json(Path.join(directory, "process.json"), %{"pid" => pid, "nonce" => nonce})
      ready = await_json(port, Path.join(directory, "ready.json"))
      true = ready["nonce"] == nonce and ready["pid"] == pid
      true = ready["heartbeat_renewals"] >= 1
      old = decode_claim(ready["claim"])
      :ok = signal_owned(port, pid, "STOP")
      paused_state = await_stopped(port, pid)
      stopped_at = System.monotonic_time(:millisecond)
      paused = evidence(id)
      save_evidence(directory, "paused", paused)
      progress(opts, probe, completed, total, :paused)
      true = paused.snapshot.state.seq == old.seq
      wait_expiry(id)

      {:ok, successor} = IntentStore.claim(id, "fencing-successor:" <> nonce, lease_ms: 15_000)
      true = successor.seq == old.seq and successor.intent_id == old.intent_id
      true = successor.generation == old.generation + 1 and successor.token != old.token
      takeover_at = System.monotonic_time(:millisecond)

      try do
        if mode == :committed, do: {:ok, _} = Recovery.execute_claim(successor)
        taken_over = evidence(id)
        save_evidence(directory, "takenover", taken_over)

        command = %{
          "nonce" => nonce,
          "successor" => encode_claim(successor),
          "same_seq" => mode != :committed
        }

        write_json(Path.join(directory, "command.json"), command)
        :ok = signal_owned(port, pid, "CONT")
        child = await_json(port, Path.join(directory, "result.json"))
        true = child["nonce"] == nonce and child["pid"] == pid
        true = child["all_probes_fenced"]
        true = child["original_executor_fenced"]
        true = child["heartbeat_observed_lease_loss"]
        true = child["worker_stopped"] and child["executor_stopped"]
        :ok = await_child_exit(port)
        after_old = evidence(id)
        save_evidence(directory, "after-old", after_old)
        true = taken_over === after_old

        if mode != :committed, do: {:ok, _} = Recovery.execute_claim(successor)
        {:ok, done} = Recovery.resume(id)
        :succeeded = done.state.status
        {:ok, rebuilt} = History.rebuild(id, done.events, max_turns: done.state.max_turns)
        true = rebuilt === done.state
        final = evidence(id)
        save_evidence(directory, "after", final)
        expected_effects = if mode == :tool, do: 1, else: 0
        true = final.stats.effects == expected_effects
        true = length(final.recordings) == if(mode == :tool, do: 2, else: 1)
        true = done.state.output == "accepted successor"

        %{
          "run_id" => id,
          "fault" => name,
          "repetition" => probe.repetition,
          "evidence" => Path.join(name, Integer.to_string(probe.repetition)),
          "pid" => pid,
          "nonce" => nonce,
          "signals" => ["SIGSTOP", "SIGCONT"],
          "paused_os_state" => paused_state,
          "whole_beam_paused" => true,
          "controller_fixture_gate" => true,
          "initial_heartbeat_renewals" => ready["heartbeat_renewals"],
          "old_generation" => old.generation,
          "successor_generation" => successor.generation,
          "same_seq_before_old_attempts" => mode != :committed,
          "seq_before_old_attempts" => taken_over.snapshot.state.seq,
          "lease_wait_ms" => takeover_at - stopped_at,
          "continuation_ms" => System.monotonic_time(:millisecond) - takeover_at,
          "old_attempts" => child["probes"],
          "original_executor_result" => child["original_executor_result"],
          "original_executor_fenced" => child["original_executor_fenced"],
          "heartbeat_observed_lease_loss" => child["heartbeat_observed_lease_loss"],
          "worker_stopped" => child["worker_stopped"],
          "executor_stopped" => child["executor_stopped"],
          "successor_facts_unchanged" => true,
          "state_matches_history" => true,
          "effects" => final.stats.effects,
          "status" => Atom.to_string(done.state.status),
          "child_exit_status" => 0
        }
      after
        IntentStore.release(successor)
      end
    after
      cleanup = cleanup_child(port, pid)
      write_json(Path.join(directory, "cleanup.json"), cleanup)
      File.write!(Path.join(directory, "child.log"), Process.delete({__MODULE__, port}) || "")
    end
  end

  @doc false
  def child(opts) do
    environment =
      case opts["environment"] do
        "test" -> :test
        "dev" -> :dev
        "prod" -> :prod
      end

    Application.put_all_env(
      Config.Reader.read!("config/config.exs", env: environment, target: :host)
    )

    # The child owns exactly one explicitly scoped pool, even when its shell
    # inherited a global scheduler environment variable from another experiment.
    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)

    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    id = opts["run_id"]
    directory = opts["directory"]
    parent = self()
    key = if opts["key"] == "tool_hook", do: :tool_hook, else: :hook

    stage =
      Enum.find(
        [:after_model, :before_effect, :after_effect, :after_receipt],
        &(Atom.to_string(&1) == opts["stage"])
      )

    hook = fn reached ->
      if reached == stage do
        send(parent, {:boundary, self()})
        receive do: (:release_gate -> :ok)
      end
    end

    {:ok, scheduler} =
      Scheduler.start_link(
        workers: 1,
        run_ids: [id],
        lease_ms: @lease_ms,
        renew_interval_ms: @renew_ms,
        poll_interval_ms: 20,
        recovery_options: [{key, hook}]
      )

    executor =
      receive do
        {:boundary, pid} -> pid
      after
        @wait_ms -> raise "child executor did not reach boundary"
      end

    entry = await_heartbeat(scheduler, executor)
    # Fixture coordination only: retain the old executor until it really makes
    # its stale write. The following OS STOP still freezes the entire VM.
    :ok = :sys.suspend(entry.worker)
    :erlang.trace(executor, true, [:send, {:tracer, self()}])
    {:ok, before} = Recovery.load(id)

    ready = %{
      "pid" => String.to_integer(System.pid()),
      "nonce" => opts["nonce"],
      "claim" => encode_claim(entry.claim),
      "heartbeat_renewals" => entry.renewals,
      "controller_fixture_gate" => true
    }

    write_json(Path.join(directory, "ready.json"), ready)
    command = await_file(Path.join(directory, "command.json"))
    true = command["nonce"] == opts["nonce"]
    successor = decode_claim(command["successor"])
    probes = stale_probes(entry.claim, successor, before, command["same_seq"])
    send(executor, :release_gate)

    original_result =
      receive do
        {:trace, ^executor, :send, {:executor_result, _ref, result}, worker}
        when worker == entry.worker ->
          result
      after
        @wait_ms -> raise "original executor did not report a late result"
      end

    :erlang.trace(:all, false, [:send])
    :ok = :sys.resume(entry.worker)
    status = await_worker_stop(scheduler)
    true = Enum.any?(status.errors, &String.contains?(&1.reason, "lease_lost"))

    report = %{
      "pid" => String.to_integer(System.pid()),
      "nonce" => opts["nonce"],
      "probes" => probes,
      "all_probes_fenced" => Enum.all?(probes, & &1["fenced"]),
      "original_executor_result" => inspect(original_result),
      "original_executor_fenced" => fenced?(original_result),
      "heartbeat_observed_lease_loss" => true,
      "worker_stopped" => not Process.alive?(entry.worker),
      "executor_stopped" => not Process.alive?(executor),
      "scheduler_errors" => dto(status.errors)
    }

    :ok = Scheduler.stop(scheduler)
    write_json(Path.join(directory, "result.json"), report)
    IO.puts("FENCING_CHILD=" <> JSON.encode!(report))
    :ok
  end

  defp stale_probes(old, successor, before, same_seq?) do
    response = {:final, "late old generation"}

    calls = [
      {"renew", fn -> IntentStore.renew(old) end},
      {"release", fn -> IntentStore.release(old) end},
      {"reserve_model", fn -> RecoveryStore.begin_model_attempt(old) end},
      {"model_frame",
       fn ->
         RecoveryStore.charge_frame(
           old,
           before.recovery.progress.request_token,
           {:text_delta, "late"}
         )
       end},
      {"model_result",
       fn -> Storage.dispatch(old.run_id, old.seq, {:model_response, response}, claim: old) end}
    ]

    calls =
      if same_seq? do
        calls ++
          [
            {"current_seq_old_token",
             fn -> IntentStore.renew(%{successor | token: old.token}) end},
            {"current_seq_old_generation",
             fn -> IntentStore.renew(%{successor | generation: old.generation}) end}
          ]
      else
        calls
      end

    calls =
      if before.state.pending_operation_id do
        operation = Map.fetch!(before.state.operations, before.state.pending_operation_id)
        receipt = Result.wrap({:ok, %{"late" => true}}, operation.operation_id, operation.tool)

        calls ++
          [
            {"tool_effect", fn -> DurableTools.execute(old, operation) end},
            {"tool_receipt",
             fn ->
               DurableTools.confirm(old, operation, receipt, "Late obsolete worker evidence")
             end},
            {"tool_result",
             fn ->
               Storage.dispatch(
                 old.run_id,
                 old.seq,
                 {:tool_result, operation.operation_id, receipt},
                 claim: old
               )
             end}
          ]
      else
        calls
      end

    Enum.map(calls, fn {name, fun} ->
      result = fun.()
      %{"name" => name, "result" => inspect(result), "fenced" => fenced?(result)}
    end)
  end

  defp fenced?({:error, :stale_claim}), do: true
  defp fenced?({:error, {:stale_sequence, _, _}}), do: true
  defp fenced?(_), do: false

  defp await_heartbeat(scheduler, executor, left \\ @wait_ms)

  defp await_heartbeat(_scheduler, _executor, left) when left <= 0,
    do: raise("heartbeat not observed")

  defp await_heartbeat(scheduler, executor, left) do
    case Enum.find(
           Scheduler.status(scheduler).active,
           &(&1.executor == executor and &1.renewals >= 1)
         ) do
      nil ->
        Process.sleep(10)
        await_heartbeat(scheduler, executor, left - 10)

      entry ->
        entry
    end
  end

  defp await_worker_stop(scheduler, left \\ @wait_ms)
  defp await_worker_stop(_scheduler, left) when left <= 0, do: raise("old Worker did not stop")

  defp await_worker_stop(scheduler, left) do
    case Scheduler.status(scheduler) do
      %{active: []} = status ->
        status

      _ ->
        Process.sleep(10)
        await_worker_stop(scheduler, left - 10)
    end
  end

  defp evidence(id) do
    {:ok, snapshot} = Recovery.load(id)
    {:ok, operations} = DurableTools.list(id)
    {:ok, recordings} = ModelResultStore.list(id)

    %{
      snapshot: snapshot,
      operations: operations,
      recordings: recordings,
      stats: DurableTools.stats(id)
    }
  end

  defp save_evidence(directory, name, value) do
    plain = dto(value)
    {:ok, encoded} = Codec.encode(plain)
    File.write!(Path.join(directory, name <> ".bin"), encoded)
    write_json(Path.join(directory, name <> ".json"), plain)
  end

  defp dto(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp dto(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp dto(value) when is_struct(value), do: value |> Map.from_struct() |> dto()
  defp dto(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), dto(v)} end)
  defp dto(value) when is_list(value), do: Enum.map(value, &dto/1)
  defp dto(value) when is_tuple(value), do: value |> Tuple.to_list() |> dto()

  defp dto(value) when is_binary(value),
    do:
      if(String.valid?(value),
        do: value,
        else: %{"encoding" => "base64", "data" => Base.encode64(value)}
      )

  defp dto(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp dto(value), do: value

  defp encode_claim(claim), do: dto(claim)

  defp decode_claim(value) do
    {:ok, expires, 0} = DateTime.from_iso8601(value["expires_at"])

    %{
      intent_id: value["intent_id"],
      run_id: value["run_id"],
      seq: value["seq"],
      owner: value["owner"],
      token: value["token"],
      generation: value["generation"],
      expires_at: expires
    }
  end

  defp spawn_child(opts) do
    code = "AgentSystemsLab.FencingDemo.child(JSON.decode!(#{inspect(JSON.encode!(opts))}))"
    executable = System.find_executable("elixir") || raise "elixir is unavailable"
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: paths ++ ["-e", code],
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    Process.put({__MODULE__, port}, "")
    {port, pid}
  end

  defp signal_owned(port, pid, signal) do
    case Port.info(port, :os_pid) do
      {:os_pid, ^pid} ->
        {message, status} =
          System.cmd("/bin/kill", ["-" <> signal, Integer.to_string(pid)], stderr_to_stdout: true)

        if status == 0, do: :ok, else: raise("owned child #{signal} failed: #{message}")

      _ ->
        raise "owned child exited before #{signal}"
    end
  end

  defp await_stopped(port, pid, left \\ 1_000)
  defp await_stopped(_port, _pid, left) when left <= 0, do: raise("SIGSTOP not confirmed by ps")

  defp await_stopped(port, pid, left) do
    drain_port(port)
    {state, 0} = System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "state="])

    if String.contains?(state, "T"),
      do: String.trim(state),
      else:
        (
          Process.sleep(10)
          await_stopped(port, pid, left - 10)
        )
  end

  defp wait_expiry(id), do: wait_expiry(id, System.monotonic_time(:millisecond) + @wait_ms)

  defp wait_expiry(id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: raise("database lease did not expire within the bounded probe wait")

    %{rows: [[remaining]]} =
      Repo.query!(
        "SELECT greatest(0, ceil(extract(epoch FROM (claim_expires_at - (clock_timestamp() AT TIME ZONE 'UTC'))) * 1000)::bigint) FROM lab_intents WHERE run_id=$1 AND status='pending'",
        [id]
      )

    if not is_integer(remaining), do: raise("paused claim is no longer present")

    if remaining > 0 do
      Process.sleep(min(50, remaining + 2))
      wait_expiry(id, deadline)
    end
  end

  defp await_json(port, path, left \\ @wait_ms)
  defp await_json(_port, path, left) when left <= 0, do: raise("child evidence timeout: #{path}")

  defp await_json(port, path, left) do
    drain_port(port)

    case File.read(path) do
      {:ok, bytes} ->
        JSON.decode!(bytes)

      {:error, :enoent} ->
        Process.sleep(10)
        await_json(port, path, left - 10)

      error ->
        raise "child evidence read failed: #{inspect(error)}"
    end
  end

  defp await_file(path, left \\ @wait_ms)
  defp await_file(path, left) when left <= 0, do: raise("controller command timeout: #{path}")

  defp await_file(path, left) do
    case File.read(path) do
      {:ok, bytes} ->
        JSON.decode!(bytes)

      {:error, :enoent} ->
        Process.sleep(10)
        await_file(path, left - 10)
    end
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, bytes}} ->
        Process.put({__MODULE__, port}, Process.get({__MODULE__, port}, "") <> bytes)
        drain_port(port)

      {^port, {:exit_status, status}} ->
        Process.put({__MODULE__, port, :exit}, status)
    after
      0 -> :ok
    end
  end

  defp await_child_exit(port, left \\ 2_000)
  defp await_child_exit(_port, left) when left <= 0, do: raise("owned child did not exit")

  defp await_child_exit(port, left) do
    drain_port(port)

    case Process.get({__MODULE__, port, :exit}) do
      0 ->
        :ok

      nil ->
        Process.sleep(10)
        await_child_exit(port, left - 10)

      status ->
        raise "owned child exit status #{status}"
    end
  end

  defp cleanup_child(port, pid) do
    alive? = Port.info(port, :os_pid) == {:os_pid, pid}

    if alive? do
      # A stopped child must receive CONT before termination; never signal a PID
      # supplied by an arbitrary fixture or the PostgreSQL/parent process.
      System.cmd("/bin/kill", ["-CONT", Integer.to_string(pid)], stderr_to_stdout: true)
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      await_cleanup_exit(port, 2_000)
    end

    drain_port(port)
    status = Process.delete({__MODULE__, port, :exit})
    true = not is_nil(status) and is_nil(Port.info(port))

    %{
      "pid" => pid,
      "continue_sent" => alive?,
      "kill_sent" => alive?,
      "exit_observed" => true,
      "exit_status" => status
    }
  end

  defp await_cleanup_exit(_port, left) when left <= 0,
    do: raise("owned child cleanup timed out without observed process exit")

  defp await_cleanup_exit(port, left) do
    drain_port(port)

    if is_nil(Port.info(port)) and not is_nil(Process.get({__MODULE__, port, :exit})),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_cleanup_exit(port, left - 10)
        )
  end

  defp report(probes, total, failure) do
    %{
      "schema_version" => 1,
      "all_passed" => length(probes) == total and is_nil(failure),
      "expected_probe_count" => total,
      "fault_probe_count" => length(probes),
      "sigstop_count" => length(probes),
      "sigcont_count" => length(probes),
      "same_seq_fencing_probes" => Enum.count(probes, & &1["same_seq_before_old_attempts"]),
      "stale_generation_overwrites" => Enum.count(probes, &(not &1["successor_facts_unchanged"])),
      "duplicate_mock_effects" => Enum.sum(Enum.map(probes, &max(0, &1["effects"] - 1))),
      "failed_probe" => failure,
      "fault_probes" => probes,
      "scope" =>
        "Owned local BEAM processes and PostgreSQL-backed Mock adapter; ordinary exception/timeout cleanup; no separate parent-hard-kill watchdog."
    }
  end

  defp failed(probe, completed, output, total, reason) do
    process_file =
      Path.join([
        output,
        elem(probe.entry, 0),
        Integer.to_string(probe.repetition),
        "process.json"
      ])

    pid =
      case File.read(process_file) do
        {:ok, bytes} -> JSON.decode!(bytes)["pid"]
        _ -> nil
      end

    failure = %{
      "run_id" => probe.run_id,
      "fault" => elem(probe.entry, 0),
      "repetition" => probe.repetition,
      "reason" => reason,
      "pid" => pid
    }

    report = report(Enum.reverse(completed), total, failure)
    write_json(Path.join(output, "report.json"), report)
    {:error, {:fencing_verification_failed, %{output_dir: output, report: report}}}
  end

  defp progress(opts, probe, done, total, status) do
    if callback = opts[:on_progress],
      do:
        callback.(%{
          fault: elem(probe.entry, 0),
          repetition: probe.repetition,
          completed: done,
          total: total,
          status: status
        })
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:output, :repetitions, :on_progress] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(Keyword.get(opts, :repetitions, 5)) and
         Keyword.get(opts, :repetitions, 5) in 1..20 and
         is_binary(Keyword.get(opts, :output, "artifacts/week12-fencing")) and
         byte_size(Keyword.get(opts, :output, "artifacts/week12-fencing")) > 0 and
         String.valid?(Keyword.get(opts, :output, "artifacts/week12-fencing")) and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week12-fencing"), <<0>>) and
         (is_nil(opts[:on_progress]) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_fencing_options}
  end

  defp options(_), do: {:error, :invalid_fencing_options}

  defp isolated_fixture do
    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false),
      do: {:error, :global_scheduler_enabled},
      else: :ok
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

  defp write_json(path, value) do
    # Rename publishes a complete frame to the other VM; it never reads a
    # partially written controller command or handshake.
    temp = path <> ".tmp"
    File.write!(temp, JSON.encode!(value) <> "\n")
    File.rename!(temp, path)
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 12}}},
      {:final, "accepted successor"}
    ]
end
