defmodule AgentSystemsLab.FrozenFaultMatrix do
  @moduledoc """
  Fixed v0.1 teaching acceptance: twelve fault rows, twenty actual repetitions each.

  This host-operated harness invokes only trusted, bounded fixtures. It does not
  change execution permissions, retry budgets or recovery decisions. Evidence is
  retained on failure; `verify/1` reads inert bounded files and invokes no runtime
  boundary. Counts describe local PostgreSQL and scripted Mock experiments.
  """
  alias AgentSystemsLab.{
    Approvals,
    Context,
    DatabaseFaultDemo,
    DurableTools,
    FencingDemo,
    History,
    IntentStore,
    Kernel,
    P2Verification,
    Recovery,
    RecoveryDemo,
    ReconciliationQueue,
    RetryDemo,
    RetryStore,
    Scheduler,
    StorageVerification
  }

  alias AgentSystemsLab.Approvals.{Artifact, Plan}
  alias AgentSystemsLab.History.{Compatibility, Encoding}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Workflows.Definition

  @repetitions 20
  @rows ~w(before_commit lost_notify claim_before_effect effect_before_receipt result_before_next_turn expired_lease same_operation_100 same_key_changed_args bounded_retry approval_artifact_changed database_disconnect incompatible_version)
  @hash ~r/\A[0-9a-f]{64}\z/
  @max_file 64 * 1024 * 1024
  @max_report 4 * 1024 * 1024

  def plan do
    %{
      "schema_version" => 1,
      "kind" => "v0.1-frozen-fault-matrix",
      "required_repetitions" => @repetitions,
      "rows" =>
        Enum.with_index(@rows, 1)
        |> Enum.map(fn {name, index} ->
          %{"id" => row_id(index), "name" => name, "required_repetitions" => @repetitions}
        end),
      "components" => [
        %{"id" => "p2", "windows" => length(P2Verification.cases()), "repetitions" => 20},
        %{"id" => "fencing", "windows" => length(FencingDemo.cases()), "repetitions" => 20},
        %{
          "id" => "database",
          "windows" => length(DatabaseFaultDemo.cases()),
          "batches" => 2,
          "repetitions_per_batch" => 10
        }
      ],
      "scope" =>
        "Fixed trusted local fixtures; no human trial, remote model or arbitrary external-service guarantee."
    }
  end

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated(),
         output = Keyword.fetch!(opts, :output),
         :ok <- fresh_output(output) do
      context = %{
        output: output,
        namespace: "freeze-" <> Ecto.UUID.generate(),
        started: DateTime.utc_now() |> DateTime.to_iso8601(),
        opts: opts
      }

      initial = new_report(context)
      write_report(context, initial)

      try do
        components = run_components(context)
        report = Map.put(initial, "components", components)
        write_report(context, report)

        completed =
          Enum.reduce(Enum.with_index(@rows, 1), report, fn {name, index}, current ->
            row = execute_row(context, index, name)
            updated = %{current | "rows" => current["rows"] ++ [row]}
            write_report(context, recount(updated))
          end)

        final = recount(completed) |> Map.put("complete", true) |> Map.put("all_passed", true)
        :ok = validate_report(final)
        :ok = verify_evidence(output, final)
        write_report(context, final)
        {:ok, %{output_dir: output, report: final}}
      rescue
        exception -> failed(context, Exception.format(:error, exception, __STACKTRACE__))
      catch
        kind, reason -> failed(context, Exception.format(kind, reason, __STACKTRACE__))
      end
    end
  end

  @doc "Runs one fixed diagnostic probe; its report cannot pass the frozen matrix gate."
  def check_probe(row, output) when row in ~w(F01 F02 F03 F04 F05 F07 F08 F09 F10 F12) do
    with :ok <- valid_absolute(output), :ok <- isolated(), :ok <- fresh_output(output) do
      directory = Path.join([output, "rows", row, "1"])
      File.mkdir_p!(directory)
      id = "freeze-diagnostic-" <> Ecto.UUID.generate()
      context = %{output: output, namespace: id, opts: []}

      try do
        {observations, extra} = probe(row, id, directory, context, 1)
        true = valid_observations?(row, observations)

        result = %{
          "schema_version" => 1,
          "kind" => "single-diagnostic-probe",
          "run_id" => id,
          "row" => row,
          "observations" => observations,
          "evidence" => Enum.map(extra, &record(output, &1)),
          "frozen_matrix_passed" => false
        }

        write_json(Path.join(output, "diagnostic.json"), result)
        {:ok, result}
      rescue
        exception ->
          {:error, {:diagnostic_failed, Exception.format(:error, exception, __STACKTRACE__)}}
      end
    end
  end

  def check_probe(_, _), do: {:error, :invalid_diagnostic_probe}

  @doc "Pure row checks for diagnostic data; this alone never passes a matrix."
  def validate_observations(row, observations) do
    try do
      if valid_observations?(row, observations),
        do: :ok,
        else: {:error, :invalid_fault_observations}
    rescue
      _ -> {:error, :invalid_fault_observations}
    end
  end

  @doc "Pure acceptance validation. A partial or contradictory report is rejected."
  def validate_report(report) do
    try do
      true =
        exact_keys?(
          report,
          ~w(schema_version kind required_repetitions created_at_utc namespace complete all_passed rows components totals failure scope)
        ) and report["schema_version"] === 1

      true = report["kind"] === "v0.1-frozen-fault-matrix"
      true = report["required_repetitions"] === @repetitions
      true = report["complete"] === true and report["all_passed"] === true
      true = is_nil(report["failure"])

      true =
        report["totals"] === %{
          "completed_rows" => 12,
          "completed_repetitions" => 240,
          "required_repetitions" => 240
        }

      rows = report["rows"]
      true = is_list(rows) and length(rows) == 12

      Enum.each(Enum.with_index(rows, 1), fn {row, index} ->
        true = exact_keys?(row, ~w(id name repetitions required_repetitions passed probes))
        true = row["id"] === row_id(index) and row["name"] === Enum.at(@rows, index - 1)

        true =
          row["repetitions"] === 20 and row["required_repetitions"] === 20 and
            row["passed"] === true

        probes = row["probes"]
        true = is_list(probes) and length(probes) == 20
        true = Enum.map(probes, & &1["repetition"]) === Enum.to_list(1..20)
        true = probes |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length() == 20

        Enum.each(probes, fn probe ->
          true =
            probe["passed"] === true and is_binary(probe["run_id"]) and
              byte_size(probe["run_id"]) in 1..256

          true = is_list(probe["evidence"]) and length(probe["evidence"]) in 1..8

          true =
            Enum.all?(
              probe["evidence"],
              &(exact_keys?(&1, ~w(path sha256 bytes)) and valid_record?(&1))
            )

          true = valid_observations?(row["id"], probe["observations"])
        end)
      end)

      ids = Enum.flat_map(rows, fn row -> Enum.map(row["probes"], & &1["run_id"]) end)
      true = length(Enum.uniq(ids)) == 240
      components = report["components"]

      true =
        is_list(components) and
          Enum.map(components, & &1["id"]) === ~w(p2 fencing database-1 database-2)

      true =
        Enum.all?(components, &(exact_keys?(&1, ~w(id path sha256 bytes)) and valid_record?(&1)))

      :ok
    rescue
      _ -> {:error, :invalid_frozen_matrix_report}
    end
  end

  @doc "Verifies the completed report and every referenced file without starting an application."
  def verify(output) do
    with :ok <- valid_absolute(output),
         :ok <- physical_directory(output),
         {:ok, bytes} <- bounded_read(output, "report.json", @max_report),
         {:ok, report} <- JSON.decode(bytes),
         :ok <- validate_report(report),
         :ok <- verify_evidence(output, report),
         do: {:ok, report}
  end

  defp run_components(context) do
    specs = [
      {"p2", P2Verification, 20},
      {"fencing", FencingDemo, 20},
      {"database-1", DatabaseFaultDemo, 10},
      {"database-2", DatabaseFaultDemo, 10}
    ]

    Enum.map(specs, fn {id, module, repetitions} ->
      progress(context, %{component: id, status: :starting})
      directory = Path.join(context.output, id)

      {:ok, %{report: report}} =
        module.run(
          output: directory,
          repetitions: repetitions,
          on_progress: fn update -> progress(context, Map.put(update, :component, id)) end
        )

      true = report["all_passed"]
      record(context.output, Path.join(id, "report.json")) |> Map.put("id", id)
    end)
  end

  defp execute_row(context, index, name) do
    id = row_id(index)

    Enum.reduce(
      1..@repetitions,
      %{
        "id" => id,
        "name" => name,
        "required_repetitions" => 20,
        "repetitions" => 0,
        "passed" => false,
        "probes" => []
      },
      fn repetition, row ->
        directory = Path.join([context.output, "rows", id, Integer.to_string(repetition)])
        File.mkdir_p!(directory)
        run_id = "#{context.namespace}-#{id}-#{repetition}"
        progress(context, %{row: id, repetition: repetition, status: :starting})
        {observations, extra} = probe(id, run_id, directory, context, repetition)
        true = valid_observations?(id, observations)
        path = Path.join(["rows", id, Integer.to_string(repetition), "observations.json"])

        write_json(Path.join(context.output, path), %{
          "run_id" => run_id,
          "repetition" => repetition,
          "row" => id,
          "observations" => observations
        })

        evidence = [record(context.output, path) | Enum.map(extra, &record(context.output, &1))]

        item = %{
          "repetition" => repetition,
          "run_id" => run_id,
          "passed" => true,
          "observations" => observations,
          "evidence" => evidence
        }

        next = %{
          row
          | "repetitions" => repetition,
            "passed" => repetition == 20,
            "probes" => row["probes"] ++ [item]
        }

        # Keep the in-progress row in the durable report, including its real count.
        {:ok, current_bytes} = File.read(Path.join(context.output, "report.json"))
        current = JSON.decode!(current_bytes)

        current =
          Map.put(current, "rows", Enum.reject(current["rows"], &(&1["id"] == id)) ++ [next])

        write_report(context, recount(current))
        progress(context, %{row: id, repetition: repetition, status: :passed})
        next
      end
    )
  end

  defp probe("F01", _id, _directory, _context, _repetition) do
    {:ok, observed} = StorageVerification.crash_probe(:before_commit, :dispatch)

    {%{
       "acknowledged" => observed.acknowledged,
       "exit_reason" => Atom.to_string(observed.exit_reason),
       "at_barrier" => safe(observed.at_barrier),
       "after_kill" => safe(observed.after_kill),
       "persisted_seq" => observed.persisted_seq,
       "recovered_seq" => observed.recovered_seq,
       "recovered_kind" => observed.recovered_kind
     }, []}
  end

  defp probe("F02", id, _directory, _context, _repetition) do
    {:ok, scheduler} =
      Scheduler.start_link(
        run_ids: [id],
        max_workers: 1,
        poll_interval_ms: 50,
        lease_ms: 1_000,
        renew_interval_ms: 100
      )

    try do
      # Establish a polling cycle before committing a brand-new eligible Run.
      wait(fn -> Scheduler.status(scheduler).counters.scans >= 1 end)
      before = Scheduler.status(scheduler)

      {:ok, created} =
        Recovery.create_run(id, "Discover committed work without its wake hint",
          script: [{:final, "periodic scan"}]
        )

      true = created.state.seq == 1
      wait(fn -> match?({:ok, %{state: %{status: :succeeded}}}, Recovery.load(id)) end)
      after_poll = Scheduler.status(scheduler)
      {:ok, done} = Recovery.load(id)

      {%{
         "notification_sent" => false,
         "wake_requests" => after_poll.wake_requests,
         "scans_before_commit" => before.counters.scans,
         "scans_after_completion" => after_poll.counters.scans,
         "status" => Atom.to_string(done.state.status),
         "committed_seq" => 1,
         "completed_seq" => done.state.seq,
         "effects" => DurableTools.stats(id).effects
       }, []}
    after
      if Process.alive?(scheduler), do: Scheduler.stop(scheduler)
    end
  end

  defp probe("F03", id, directory, _context, _repetition) do
    {:ok, _} =
      Recovery.create_run(id, "Kill an owned OS Worker before its tool effect", script: script())

    {:ok, _} = Recovery.step(id)
    crash = kill_owned_application(id, directory, :tool_hook, :before_effect)
    before = DurableTools.stats(id)
    0 = before.effects
    {:ok, done} = Recovery.resume(id)
    :succeeded = done.state.status
    after_stats = DurableTools.stats(id)

    {%{
       "kill_count" => 1,
       "signal" => "SIGKILL",
       "owned_pid" => crash["pid"],
       "exit_observed" => crash["exit_observed"],
       "effects_before_recovery" => before.effects,
       "effects" => after_stats.effects,
       "lease_wait_ms" => crash["lease_wait_ms"],
       "status" => Atom.to_string(done.state.status),
       "generation_before" => crash["generation"]
     },
     [
       Path.join(["rows", "F03", Path.basename(directory), "process.json"]),
       Path.join(["rows", "F03", Path.basename(directory), "child.log"])
     ]}
  end

  defp probe("F04", id, directory, _context, _repetition) do
    results =
      Enum.map([:idempotent, :unqueryable], fn mode ->
        run_id = id <> "-" <> Atom.to_string(mode)

        {:ok, _} =
          Recovery.create_run(run_id, "Lose a target reply and kill before runtime receipt",
            script: script(),
            mock_mode: mode,
            mock_response: :lost,
            retry_policy: [max_attempts: 1]
          )

        {:ok, _} = Recovery.step(run_id)
        child_directory = Path.join(directory, Atom.to_string(mode) <> "-child")
        File.mkdir!(child_directory)
        _crash = kill_owned_application(run_id, child_directory, :tool_hook, :after_effect)
        %{effects: 1} = before = DurableTools.stats(run_id)
        {:ok, [prepared]} = DurableTools.list(run_id)
        true = prepared.status == "prepared" and prepared.result == nil
        {:ok, blocked} = Recovery.resume(run_id)
        :blocked = blocked.state.status
        {:ok, queue} = ReconciliationQueue.get(run_id)

        if mode == :idempotent do
          {:ok, _} = Recovery.reconcile(run_id)
          {:ok, done} = Recovery.resume(run_id)
          :succeeded = done.state.status
        else
          {:error, :reconciliation_required} = Recovery.reconcile(run_id)
          {:ok, remains} = Recovery.load(run_id)
          :blocked = remains.state.status
          :manual = queue.safe_mode
        end

        after_stats = DurableTools.stats(run_id)
        {:ok, operations} = DurableTools.list(run_id)

        write_json(
          Path.join(directory, Atom.to_string(mode) <> ".json"),
          %{
            "run_id" => run_id,
            "before" => safe(before),
            "after" => safe(after_stats),
            "operations" => safe(operations),
            "queue" => safe(queue)
          }
        )

        %{
          "mode" => Atom.to_string(mode),
          "run_id" => run_id,
          "effects" => after_stats.effects,
          "status" => if(mode == :idempotent, do: "succeeded", else: "blocked"),
          "safe_mode" => Atom.to_string(queue.safe_mode),
          "prepared_receipt_absent" => true,
          "reply_lost" => true,
          "caller_killed" => true
        }
      end)

    suffix = Path.basename(directory)

    {%{"modes" => results},
     Enum.flat_map(~w(idempotent unqueryable), fn mode ->
       [
         Path.join(["rows", "F04", suffix, mode <> ".json"]),
         Path.join(["rows", "F04", suffix, mode <> "-child", "process.json"])
       ]
     end)}
  end

  defp probe("F05", id, directory, _context, _repetition) do
    {:ok, _} =
      Recovery.create_run(id, "Restart into a fresh application after a confirmed tool result",
        script: script()
      )

    {:ok, _} = Recovery.step(id)
    crash = kill_owned_application(id, directory, :commit_hook, :after_commit)
    {:ok, before} = Recovery.load(id)
    :running = before.state.status
    %{effects: 1} = before_stats = DurableTools.stats(id)
    {:ok, [operation]} = DurableTools.list(id)
    "completed" = operation.status
    {:ok, child, log} = RecoveryDemo.fresh_resume(id)
    File.write!(Path.join(directory, "fresh-application.log"), log)
    {:ok, done} = Recovery.load(id)
    after_stats = DurableTools.stats(id)
    true = Context.hash(done.state) == child["state_sha256"]

    {%{
       "fresh_application" => true,
       "previous_application_killed" => crash["exit_observed"],
       "signal" => "SIGKILL",
       "status" => child["status"],
       "effects_before" => before_stats.effects,
       "effects_after" => after_stats.effects,
       "tool_attempts_before" => before_stats.attempts,
       "tool_attempts_after" => after_stats.attempts,
       "saved_result_seq" => before.state.seq,
       "final_seq" => done.state.seq,
       "state_sha256" => child["state_sha256"]
     },
     [
       Path.join(["rows", "F05", Path.basename(directory), "fresh-application.log"]),
       Path.join(["rows", "F05", Path.basename(directory), "process.json"])
     ]}
  end

  defp probe("F06", _id, _directory, context, repetition) do
    # Resolve the existing fixture's first same-sequence case from its real report.
    report = JSON.decode!(File.read!(Path.join(context.output, "fencing/report.json")))

    summary =
      Enum.find(
        report["fault_probes"],
        &(&1["repetition"] == repetition and &1["same_seq_before_old_attempts"])
      )

    true = is_map(summary)

    actual =
      Path.join(["fencing", summary["fault"], Integer.to_string(repetition), "summary.json"])

    {%{
       "source_run_id" => summary["run_id"],
       "signals" => summary["signals"],
       "whole_beam_paused" => summary["whole_beam_paused"],
       "old_generation" => summary["old_generation"],
       "successor_generation" => summary["successor_generation"],
       "old_attempts" => summary["old_attempts"],
       "successor_facts_unchanged" => summary["successor_facts_unchanged"],
       "original_executor_fenced" => summary["original_executor_fenced"],
       "child_exit_status" => summary["child_exit_status"]
     }, [actual]}
  end

  defp probe(id, run_id, directory, _context, _repetition) when id in ["F07", "F08"] do
    {claim, operation} = waiting(run_id)

    parent = self()
    marker = make_ref()
    {:ok, supervisor} = Task.Supervisor.start_link()

    tasks =
      for index <- 1..100 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {marker, :ready, self()})

          receive do
            {^marker, :release} -> :ok
          after
            10_000 -> raise "concurrent delivery barrier was not released"
          end

          call =
            if id == "F08" and rem(index, 2) == 0,
              do: %{operation | arguments: %{"value" => "changed-#{index}"}},
              else: operation

          DurableTools.execute(claim, call)
        end)
      end

    results =
      try do
        ready =
          for _ <- 1..100 do
            receive do
              {^marker, :ready, pid} -> pid
            after
              10_000 -> raise "not all one hundred deliveries reached the barrier"
            end
          end

        true = length(Enum.uniq(ready)) == 100 and Enum.all?(ready, &Process.alive?/1)
        Enum.each(ready, &send(&1, {marker, :release}))
        Task.await_many(tasks, 60_000)
      after
        Enum.each(tasks, fn task ->
          if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        end)

        Supervisor.stop(supervisor)
        :ok = IntentStore.release(claim)
      end

    stats = DurableTools.stats(run_id)
    {:ok, [recorded]} = DurableTools.list(run_id)
    successes = Enum.filter(results, &match?({:ok, {:ok, _}}, &1))
    conflicts = Enum.count(results, &(&1 == {:error, :operation_id_conflict}))
    true = Enum.all?(successes, &(&1 == {:ok, recorded.result}))

    write_json(Path.join(directory, "deliveries.json"), %{
      "results" => safe(results),
      "operation" => safe(recorded),
      "stats" => safe(stats)
    })

    {%{
       "concurrent_submissions" => 100,
       "barrier_ready" => 100,
       "barrier_released" => 100,
       "successful_deliveries" => length(successes),
       "explicit_conflicts" => conflicts,
       "operations" => stats.operations,
       "effects" => stats.effects,
       "attempts" => stats.attempts,
       "same_logical_result" => true,
       "original_input_sha256" => recorded.input_sha256
     }, [Path.join(["rows", id, Path.basename(directory), "deliveries.json"])]}
  end

  defp probe("F09", id, directory, _context, _repetition) do
    {:ok, _} =
      Recovery.create_run(id, "Exhaust a finite fixed retry budget",
        script: [{:error, :unavailable}],
        retry_policy: [
          max_attempts: 3,
          base_delay_ms: 20,
          max_delay_ms: 20,
          max_elapsed_ms: 30_000
        ]
      )

    started = System.monotonic_time(:millisecond)
    {:ok, done} = RetryDemo.drive(id)
    {:retry_exhausted, :model, :unavailable} = done.state.terminal_reason
    {:ok, [journal]} = RetryStore.list(id)
    before = done.recovery.progress
    {:ok, again} = Recovery.resume(id)
    true = before == again.recovery.progress
    write_json(Path.join(directory, "retry-journal.json"), safe(journal))

    {%{
       "status" => Atom.to_string(done.state.status),
       "reason" => "retry_exhausted",
       "model_attempts" => done.recovery.progress.model_attempts,
       "persisted_attempts" => journal.attempts,
       "max_attempts" => 3,
       "resume_spent_more" => false,
       "elapsed_ms" => System.monotonic_time(:millisecond) - started
     }, [Path.join(["rows", "F09", Path.basename(directory), "retry-journal.json"])]}
  end

  defp probe("F10", id, directory, _context, _repetition) do
    workspace = Path.join(directory, "workspace")
    File.mkdir!(workspace)
    File.write!(Path.join(workspace, "base.txt"), "BASE")

    {:ok, definition} =
      Definition.new([
        %{
          id: "writer",
          role: :implementer,
          input: "Prepare a patch",
          options: %{workspace: workspace, script: [file_call(), {:final, "patch ready"}]}
        }
      ])

    {:ok, artifact} =
      Artifact.new(workspace, ["patch.txt"],
        baselines: %{"base.txt" => sha("BASE")},
        initial: %{"patch.txt" => "absent"}
      )

    {:ok, plan} =
      Plan.new([%{id: "r1", definition: definition, artifacts: [artifact]}], timeout_ms: 60_000)

    {:ok, _} = Approvals.create(id, plan)

    {:ok, controller} =
      Approvals.start_link(
        case_id: id,
        poll_interval_ms: 10,
        scheduler_options: [poll_interval_ms: 10, lease_ms: 1_000, renew_interval_ms: 100]
      )

    try do
      wait(fn ->
        match?(
          {:ok, %{status: :awaiting_review, subject: subject}} when not is_nil(subject),
          Approvals.load(id)
        )
      end)

      {:ok, review} = Approvals.load(id)
      {:ok, approved} = Approvals.decide(id, request(review, "approve", :approve))
      {:ok, _} = Approvals.release(id, request(approved, "release-original"))
      File.write!(Path.join(workspace, "patch.txt"), "MUTATED")

      {:error, {:approval_invalidated, _, changed}} =
        Approvals.release(id, request(approved, "release-changed"))

      true = is_nil(changed.approval) and changed.generation > approved.generation
      true = changed.subject.subject_hash != approved.subject.subject_hash

      write_json(Path.join(directory, "approval-audit.json"), %{
        "before" => safe(approved),
        "after" => safe(changed)
      })

      {%{
         "original_subject_hash" => approved.subject.subject_hash,
         "changed_subject_hash" => changed.subject.subject_hash,
         "old_approval_present" => not is_nil(approved.approval),
         "changed_approval_present" => not is_nil(changed.approval),
         "generation_before" => approved.generation,
         "generation_after" => changed.generation,
         "release_rejected" => true,
         "published" => false
       }, [Path.join(["rows", "F10", Path.basename(directory), "approval-audit.json"])]}
    after
      if Process.alive?(controller), do: Approvals.stop(controller)
    end
  end

  defp probe("F11", _id, _directory, context, repetition) do
    batch = if repetition <= 10, do: "database-1", else: "database-2"
    local = rem(repetition - 1, 10) + 1

    path =
      Path.join([
        batch,
        "tool_effect_pending_disconnect",
        Integer.to_string(local),
        "summary.json"
      ])

    summary = JSON.decode!(File.read!(Path.join(context.output, path)))

    {%{
       "source_run_id" => summary["run_id"],
       "database_error_observed" => summary["database_error_observed"],
       "successor_facts_unchanged" => summary["successor_facts_unchanged"],
       "effects" => summary["effects"],
       "status" => summary["status"],
       "summary" => summary
     }, [path]}
  end

  defp probe("F12", id, directory, _context, _repetition) do
    {:ok, initial} = Kernel.new(id)
    {:ok, started, [event]} = Kernel.dispatch(initial, {:start, "Read an incompatible history"})
    {:ok, ^started} = History.rebuild(id, [event])
    incompatible = %{event | schema_version: 99}
    {:error, {:unsupported_schema_version, 99}} = rejected = History.rebuild(id, [incompatible])
    {:error, {:unsupported_history_format, 99}} = Encoding.validate_format(99)
    {:error, {:unsupported_codec_version, 99}} = Codec.decode(<<>>, 99)

    {:error, {:incompatible_version, "kernel_schema", 99}} =
      Compatibility.validate_versions(%{"kernel_schema" => 99})

    {:ok, persisted_before} =
      Recovery.create_run(id, "Reject an incompatible durable event",
        script: [{:final, "unused"}]
      )

    {:error,
     %Postgrex.Error{postgres: %{code: :check_violation, constraint: "lab_events_schema_version"}}} =
      AgentSystemsLab.Repo.query("UPDATE lab_events SET schema_version=99 WHERE run_id=$1", [id])

    {:ok, persisted_after} = Recovery.load(id)
    true = persisted_before === persisted_after

    write_json(Path.join(directory, "incompatible-events.json"), %{
      "original" => safe(event),
      "incompatible" => safe(incompatible),
      "rejection" => safe(rejected)
    })

    {%{
       "supported_schema" => 1,
       "incompatible_schema" => 99,
       "original_rebuild_passed" => true,
       "incompatible_rebuild_rejected" => true,
       "format_rejected" => true,
       "codec_rejected" => true,
       "compatibility_rejected" => true,
       "durable_event_rejected" => true,
       "durable_rejection_boundary" => "database_check_constraint",
       "restored_state_unchanged" => true,
       "original_state_sha256" => Context.hash(started)
     }, [Path.join(["rows", "F12", Path.basename(directory), "incompatible-events.json"])]}
  end

  @doc false
  def child_run(id, directory, key, stage, environment)
      when key in [:tool_hook, :commit_hook] and
             stage in [:before_effect, :after_effect, :after_commit] do
    Application.put_all_env(
      Config.Reader.read!("config/config.exs", env: environment, target: :host)
    )

    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)

    hook = fn reached ->
      if reached == stage do
        {:ok, snapshot} = Recovery.load(id)

        write_json(Path.join(directory, "ready.json"), %{
          "run_id" => id,
          "pid" => System.pid(),
          "seq" => snapshot.state.seq,
          "generation" => snapshot.intent.claim_generation,
          "barrier" => Atom.to_string(stage)
        })

        receive do: (:never_release -> :ok)
      end
    end

    result = Recovery.step(id, [{key, hook}, {:lease_ms, 250}])
    raise "owned child acknowledged before expected barrier: #{inspect(result)}"
  end

  defp kill_owned_application(id, directory, key, stage) do
    environment = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev

    code =
      "AgentSystemsLab.FrozenFaultMatrix.child_run(#{inspect(id)}, #{inspect(directory)}, #{inspect(key)}, #{inspect(stage)}, #{inspect(environment)})"

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
    executable = System.find_executable("elixir") || raise "elixir executable missing"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: paths ++ ["-e", code],
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    Process.put({__MODULE__, port, :log}, "")

    try do
      wait(fn ->
        drain(port)
        File.regular?(Path.join(directory, "ready.json"))
      end)

      ready = JSON.decode!(File.read!(Path.join(directory, "ready.json")))
      true = ready["run_id"] == id and ready["pid"] == Integer.to_string(pid)
      true = Port.info(port, :os_pid) == {:os_pid, pid}
      {_, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      wait(fn ->
        drain(port)
        not is_nil(Process.get({__MODULE__, port, :exit}))
      end)

      true = is_nil(Port.info(port))
      started = System.monotonic_time(:millisecond)

      wait(fn ->
        %{rows: [[expired]]} =
          AgentSystemsLab.Repo.query!(
            "SELECT coalesce(claim_expires_at <= clock_timestamp() AT TIME ZONE 'UTC', true) FROM lab_intents WHERE run_id=$1 AND status='pending'",
            [id]
          )

        expired
      end)

      result = %{
        "pid" => pid,
        "signal" => "SIGKILL",
        "run_id" => id,
        "barrier" => Atom.to_string(stage),
        "generation" => ready["generation"],
        "exit_observed" => true,
        "exit_status" => Process.get({__MODULE__, port, :exit}),
        "lease_wait_ms" => System.monotonic_time(:millisecond) - started
      }

      write_json(Path.join(directory, "process.json"), result)
      result
    after
      if Port.info(port, :os_pid) == {:os_pid, pid} do
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        wait(fn ->
          drain(port)
          not is_nil(Process.get({__MODULE__, port, :exit}))
        end)
      end

      drain(port)

      File.write!(
        Path.join(directory, "child.log"),
        "owned_child_pid=#{pid}\n" <> (Process.delete({__MODULE__, port, :log}) || "")
      )

      Process.delete({__MODULE__, port, :exit})
    end
  end

  defp drain(port) do
    receive do
      {^port, {:data, bytes}} ->
        old = Process.get({__MODULE__, port, :log}, "")
        true = byte_size(old) + byte_size(bytes) <= 4 * 1024 * 1024
        Process.put({__MODULE__, port, :log}, old <> bytes)
        drain(port)

      {^port, {:exit_status, status}} ->
        Process.put({__MODULE__, port, :exit}, status)
    after
      0 -> :ok
    end
  end

  defp waiting(id) do
    {:ok, _} = Recovery.create_run(id, "Many deliveries, one logical operation", script: script())
    {:ok, planned} = Recovery.step(id)
    {:ok, claim} = IntentStore.claim(id, "frozen-concurrent", lease_ms: 60_000)

    {claim,
     Map.fetch!(planned.state.operations, "once") |> Map.take([:operation_id, :tool, :arguments])}
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 24}}},
      {:final, "done"}
    ]

  defp file_call,
    do:
      {:call,
       %{
         operation_id: "patch",
         tool: "file_write",
         arguments: %{"path" => "patch.txt", "content" => "PATCH", "expected_sha256" => "absent"}
       }}

  defp request(view, id, action \\ nil) do
    base = %{
      actor: "lab-human",
      reason: "Synthetic trusted fixture request",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }

    if action, do: Map.put(base, :action, action), else: base
  end

  defp valid_observations?("F01", o),
    do:
      is_map(o) and o["acknowledged"] === false and o["exit_reason"] == "killed" and
        o["at_barrier"] === %{"runs" => 1, "events" => 1, "intents" => 1, "pending" => 1} and
        o["at_barrier"] === o["after_kill"] and o["persisted_seq"] === 1 and
        o["recovered_seq"] === 2 and o["recovered_kind"] == "tool"

  defp valid_observations?("F02", o),
    do:
      is_map(o) and o["notification_sent"] === false and o["wake_requests"] === 0 and
        is_integer(o["scans_before_commit"]) and o["scans_before_commit"] >= 1 and
        is_integer(o["scans_after_completion"]) and
        o["scans_after_completion"] > o["scans_before_commit"] and o["status"] == "succeeded" and
        o["effects"] === 0

  defp valid_observations?("F03", o),
    do:
      is_map(o) and o["kill_count"] === 1 and o["signal"] == "SIGKILL" and
        is_integer(o["owned_pid"]) and o["owned_pid"] > 0 and o["exit_observed"] === true and
        o["effects_before_recovery"] === 0 and o["effects"] === 1 and o["status"] == "succeeded"

  defp valid_observations?("F04", %{"modes" => [i, u]}),
    do:
      i["mode"] == "idempotent" and i["effects"] === 1 and i["status"] == "succeeded" and
        u["mode"] == "unqueryable" and u["effects"] === 1 and u["status"] == "blocked" and
        u["safe_mode"] == "manual" and
        Enum.all?(
          [i, u],
          &(&1["prepared_receipt_absent"] === true and &1["reply_lost"] === true and
              &1["caller_killed"] === true)
        )

  defp valid_observations?("F04", _), do: false

  defp valid_observations?("F05", o),
    do:
      is_map(o) and o["fresh_application"] === true and o["previous_application_killed"] === true and
        o["signal"] == "SIGKILL" and o["status"] == "succeeded" and
        o["effects_before"] === 1 and o["effects_after"] === 1 and
        is_integer(o["tool_attempts_before"]) and o["tool_attempts_before"] >= 1 and
        o["tool_attempts_before"] === o["tool_attempts_after"] and hash?(o["state_sha256"])

  defp valid_observations?("F06", o),
    do:
      is_map(o) and o["signals"] === ["SIGSTOP", "SIGCONT"] and o["whole_beam_paused"] === true and
        is_integer(o["old_generation"]) and is_integer(o["successor_generation"]) and
        o["successor_generation"] > o["old_generation"] and
        o["successor_facts_unchanged"] === true and o["original_executor_fenced"] === true and
        o["child_exit_status"] === 0 and is_list(o["old_attempts"]) and o["old_attempts"] != [] and
        Enum.all?(o["old_attempts"], &(&1["fenced"] === true))

  defp valid_observations?("F07", o), do: concurrent?(o, 100, 0)
  defp valid_observations?("F08", o), do: concurrent?(o, 50, 50)

  defp valid_observations?("F09", o),
    do:
      is_map(o) and o["status"] == "failed" and o["reason"] == "retry_exhausted" and
        o["model_attempts"] === 3 and o["persisted_attempts"] === 3 and o["max_attempts"] === 3 and
        o["resume_spent_more"] === false and is_integer(o["elapsed_ms"]) and o["elapsed_ms"] >= 40

  defp valid_observations?("F10", o),
    do:
      is_map(o) and hash?(o["original_subject_hash"]) and hash?(o["changed_subject_hash"]) and
        o["original_subject_hash"] != o["changed_subject_hash"] and
        o["old_approval_present"] === true and o["changed_approval_present"] === false and
        is_integer(o["generation_before"]) and is_integer(o["generation_after"]) and
        o["generation_after"] > o["generation_before"] and
        o["release_rejected"] === true and o["published"] === false

  defp valid_observations?("F11", o),
    do:
      is_map(o) and o["database_error_observed"] === true and
        o["successor_facts_unchanged"] === true and o["effects"] === 1 and
        o["status"] == "succeeded"

  defp valid_observations?("F12", o),
    do:
      is_map(o) and o["supported_schema"] === 1 and o["incompatible_schema"] === 99 and
        hash?(o["original_state_sha256"]) and
        Enum.all?(
          ~w(original_rebuild_passed incompatible_rebuild_rejected format_rejected codec_rejected compatibility_rejected durable_event_rejected restored_state_unchanged),
          &(o[&1] === true)
        )

  defp valid_observations?(_, _), do: false

  defp concurrent?(o, success, conflicts),
    do:
      is_map(o) and o["concurrent_submissions"] === 100 and o["barrier_ready"] === 100 and
        o["barrier_released"] === 100 and o["successful_deliveries"] === success and
        o["explicit_conflicts"] === conflicts and o["operations"] === 1 and o["effects"] === 1 and
        o["attempts"] === success and o["same_logical_result"] === true and
        hash?(o["original_input_sha256"])

  defp verify_evidence(output, report) do
    records =
      report["components"] ++
        Enum.flat_map(report["rows"], fn row -> Enum.flat_map(row["probes"], & &1["evidence"]) end)

    with :ok <-
           Enum.reduce_while(records, :ok, fn item, :ok ->
             with {:ok, bytes} <- bounded_read(output, item["path"], @max_file),
                  true <- byte_size(bytes) === item["bytes"] and sha(bytes) === item["sha256"] do
               {:cont, :ok}
             else
               _ -> {:halt, {:error, {:invalid_matrix_evidence, item["path"]}}}
             end
           end) do
      try do
        Enum.each(report["components"], &verify_component!(output, &1))

        Enum.each(report["rows"], fn row ->
          Enum.each(row["probes"], fn probe ->
            relative =
              Path.join([
                "rows",
                row["id"],
                Integer.to_string(probe["repetition"]),
                "observations.json"
              ])

            true = Enum.any?(probe["evidence"], &(&1["path"] == relative))
            {:ok, bytes} = bounded_read(output, relative, @max_report)

            expected = %{
              "run_id" => probe["run_id"],
              "repetition" => probe["repetition"],
              "row" => row["id"],
              "observations" => probe["observations"]
            }

            true = JSON.decode!(bytes) === expected
          end)
        end)

        :ok
      rescue
        _ -> {:error, :matrix_observations_mismatch}
      end
    end
  end

  defp verify_component!(output, item) do
    id = item["id"]
    true = item["path"] == Path.join(id, "report.json")
    {:ok, bytes} = bounded_read(output, item["path"], @max_report)
    report = JSON.decode!(bytes)

    {faults, repetitions} =
      case id do
        "p2" -> {P2Verification.cases(), 20}
        "fencing" -> {FencingDemo.cases(), 20}
        _ -> {DatabaseFaultDemo.cases(), 10}
      end

    count = length(faults) * repetitions

    true =
      report["schema_version"] === 1 and report["all_passed"] === true and
        is_nil(report["failed_probe"])

    true = report["expected_probe_count"] === count and report["fault_probe_count"] === count
    true = report["duplicate_mock_effects"] === 0

    if id == "p2" do
      true =
        report["fault_windows"] === 16 and report["lost_confirmed_receipts"] === 0 and
          report["stale_token_overwrites"] === 0
    else
      true = report["stale_generation_overwrites"] === 0
    end

    if id == "fencing",
      do: true = report["sigstop_count"] === 100 and report["sigcont_count"] === 100

    probes = report["fault_probes"]
    true = is_list(probes) and length(probes) == count
    true = Enum.sort(Enum.map(probes, & &1["fault"]) |> Enum.uniq()) == Enum.sort(faults)
    true = probes |> Enum.map(& &1["run_id"]) |> Enum.uniq() |> length() == count

    Enum.each(faults, fn fault ->
      matching = Enum.filter(probes, &(&1["fault"] == fault))
      true = Enum.map(matching, & &1["repetition"]) == Enum.to_list(1..repetitions)
    end)

    Enum.each(probes, fn probe ->
      true = probe["status"] == "succeeded" and probe["state_matches_history"] === true
      directory = Path.join([id, probe["fault"], Integer.to_string(probe["repetition"])])
      {:ok, summary} = bounded_read(output, Path.join(directory, "summary.json"), @max_report)
      true = JSON.decode!(summary) === probe

      if id == "p2" do
        true =
          probe["confirmed_receipts_preserved"] === true and
            probe["stale_claim_rejected"] === true and probe["effects"] === 1 and
            probe["kill_count"] in [1, 2]
      else
        true = probe["successor_facts_unchanged"] === true and probe["child_exit_status"] === 0
        {:ok, cleanup} = bounded_read(output, Path.join(directory, "cleanup.json"), @max_report)
        cleanup = JSON.decode!(cleanup)
        true = cleanup["exit_observed"] === true and cleanup["exit_status"] === 0

        if id == "fencing" do
          true =
            probe["signals"] == ["SIGSTOP", "SIGCONT"] and
              probe["original_executor_fenced"] === true

          true = Enum.all?(probe["old_attempts"], &(&1["fenced"] === true))
        else
          true = probe["database_error_observed"] === true and cleanup["proxy_stopped"] === true
        end
      end
    end)
  end

  defp exact_keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)

  defp valid_record?(item),
    do:
      is_map(item) and relative?(item["path"]) and hash?(item["sha256"]) and
        is_integer(item["bytes"]) and item["bytes"] in 1..@max_file

  defp record(output, relative) do
    {:ok, bytes} = bounded_read(output, relative, @max_file)
    %{"path" => relative, "sha256" => sha(bytes), "bytes" => byte_size(bytes)}
  end

  defp bounded_read(root, relative, maximum) do
    with true <- relative?(relative) || {:error, :unsafe_matrix_path},
         :ok <- physical_directory(root),
         :ok <- physical_directory(Path.dirname(Path.join(root, relative))),
         {:ok, stat} <- File.lstat(Path.join(root, relative)),
         true <-
           (stat.type == :regular and stat.links == 1 and stat.size in 1..maximum) ||
             {:error, :invalid_matrix_file},
         {:ok, bytes} <- File.read(Path.join(root, relative)),
         true <- byte_size(bytes) == stat.size || {:error, :changed_matrix_file},
         do: {:ok, bytes}
  end

  defp relative?(path),
    do:
      is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
        Path.type(path) == :relative and not String.contains?(path, [<<0>>, "\\"]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp hash?(value), do: is_binary(value) and Regex.match?(@hash, value)
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp row_id(index), do: "F" <> String.pad_leading(Integer.to_string(index), 2, "0")

  defp new_report(context),
    do: %{
      "schema_version" => 1,
      "kind" => "v0.1-frozen-fault-matrix",
      "required_repetitions" => 20,
      "created_at_utc" => context.started,
      "namespace" => context.namespace,
      "complete" => false,
      "all_passed" => false,
      "rows" => [],
      "components" => [],
      "totals" => %{
        "completed_rows" => 0,
        "completed_repetitions" => 0,
        "required_repetitions" => 240
      },
      "failure" => nil,
      "scope" =>
        "Controlled local Scripted Provider/PostgreSQL Mock fixtures; synthetic trusted approval actor; no real human or arbitrary external-service claim."
    }

  defp recount(report),
    do:
      Map.put(report, "totals", %{
        "completed_rows" => Enum.count(report["rows"], & &1["passed"]),
        "completed_repetitions" => Enum.sum(Enum.map(report["rows"], & &1["repetitions"])),
        "required_repetitions" => 240
      })

  defp write_report(context, report) do
    write_json(Path.join(context.output, "report.json"), report)
    report
  end

  defp failed(context, reason) do
    report =
      JSON.decode!(File.read!(Path.join(context.output, "report.json")))
      |> Map.put("complete", false)
      |> Map.put("all_passed", false)
      |> Map.put("failure", %{"reason" => reason})

    write_report(context, report)
    {:error, {:frozen_matrix_failed, %{output_dir: context.output, report: report}}}
  end

  defp write_json(path, value), do: File.write!(path, JSON.encode!(value) <> "\n")
  defp safe(%_{} = value), do: value |> Map.from_struct() |> safe()

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), safe(item)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)
  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()

  defp safe(value) when is_atom(value),
    do: if(value in [true, false, nil], do: value, else: Atom.to_string(value))

  defp safe(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"base64" => Base.encode64(value)})

  defp safe(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp safe(value), do: value
  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + 15_000)

  defp wait(fun, deadline) do
    if fun.(),
      do: :ok,
      else:
        (
          if System.monotonic_time(:millisecond) >= deadline,
            do: raise("frozen fixture wait expired")

          Process.sleep(10)
          wait(fun, deadline)
        )
  end

  defp progress(context, update) do
    if callback = context.opts[:on_progress], do: callback.(update)
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:output, :on_progress] == [] and Keyword.has_key?(opts, :output) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: valid_absolute(opts[:output]),
       else: {:error, :invalid_frozen_matrix_options}
  end

  defp valid_absolute(path) do
    if is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
         Path.type(path) == :absolute and
         not String.contains?(path, <<0>>) and Path.expand(path) == path and path != "/",
       do: :ok,
       else: {:error, :unsafe_matrix_output}
  end

  defp physical_directory(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while("", fn part, parent ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> {:cont, current}
        _ -> {:halt, {:error, :unsafe_matrix_directory}}
      end
    end)
    |> case do
      result when is_binary(result) -> :ok
      error -> error
    end
  end

  defp fresh_output(path) do
    with :ok <- physical_directory(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> File.chmod(path, 0o700)
        {:error, :eexist} -> {:error, :matrix_output_exists}
        error -> error
      end
    end
  end

  defp isolated do
    cond do
      not Application.get_env(:agent_systems_lab, :database_enabled, true) ->
        {:error, :database_required}

      Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
          Process.whereis(Scheduler) ->
        {:error, :global_scheduler_enabled}

      true ->
        :ok
    end
  end
end
