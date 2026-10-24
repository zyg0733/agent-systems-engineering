defmodule AgentSystemsLab.ObservabilityDemo do
  @moduledoc "Offline observability verification over the original durable execution authorities."
  alias AgentSystemsLab.{
    Approvals,
    Context,
    DurableTools,
    Observability,
    QueueStore,
    Recovery,
    ReconciliationQueue,
    Scheduler,
    Workflows
  }

  alias AgentSystemsLab.Approvals.{Artifact, Plan}
  alias AgentSystemsLab.Observability.{Buffer, Query}
  alias AgentSystemsLab.Observability.Context, as: TraceContext
  alias AgentSystemsLab.Observability.Exporters.{JSONL, Null}
  alias AgentSystemsLab.Workflows.Definition

  @cases ~w(correlated_execution unknown_reconcile approval_rework export_failure_equivalence buffer_saturation observer_absence commit_windows readonly_projection)
  @canary "PRIVATE_OBSERVABILITY_CANARY_19"
  def cases, do: @cases

  defmodule FaultExporter do
    @moduledoc false
    @behaviour AgentSystemsLab.Observability.Exporter
    def export(_batch, opts) do
      case opts[:mode] do
        :error -> {:error, "PRIVATE_OBSERVABILITY_CANARY_19"}
        :raise -> raise "PRIVATE_OBSERVABILITY_CANARY_19"
        :exit -> exit(:owned_exporter_failure)
        :hang -> receive do: (:never_sent -> :ok)
      end
    end
  end

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated(),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week19-observability")),
         :ok <- create_output(output) do
      context = %{output: output, namespace: "w19-" <> Ecto.UUID.generate()}

      write_json(Path.join(output, "manifest.json"), %{
        namespace: context.namespace,
        expected_cases: @cases
      })

      report(context, [], nil)
      execute(@cases, [], context, opts)
    end
  end

  defp execute([], done, context, _opts),
    do: {:ok, %{output_dir: context.output, report: report(context, done, nil)}}

  defp execute([name | rest], done, context, opts) do
    result =
      try do
        progress(opts, name, length(done), :starting)
        directory = Path.join(context.output, name)
        File.mkdir!(directory)
        f = Map.merge(context, %{directory: directory, id: context.namespace <> "-" <> name})
        path = Path.join(directory, "observations.jsonl")
        File.write!(path, "")
        summary = with_exporter({JSONL, [path: path]}, fn -> verify(name, f) end)
        :ok = Observability.flush()
        assert_safe(File.read!(path))
        evidence = capture(summary["run_ids"], directory)
        summary = Map.merge(summary, %{"case" => name, "passed" => true, "evidence" => evidence})
        write_json(Path.join(directory, "summary.json"), summary)
        progress(opts, name, length(done) + 1, :passed)
        {:ok, summary}
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        done = done ++ [summary]
        report(context, done, nil)
        execute(rest, done, context, opts)

      {:error, reason} ->
        result = report(context, done, %{"case" => name, "reason" => reason})

        {:error,
         {:observability_verification_failed, %{output_dir: context.output, report: result}}}
    end
  end

  defp verify("correlated_execution", f) do
    root = Path.join(f.directory, "worker")
    File.mkdir!(root)
    queue = f.id <> "-queue"
    {:ok, _} = QueueStore.create(queue, capacity: 2, max_inflight: 1)
    parent = self()
    marker = make_ref()

    {:ok, _} =
      Recovery.create_run(
        f.id,
        @canary,
        opts(workspace: root, queue: queue, script: [file_call(), {:final, "DONE"}])
      )

    {:ok, scheduler} =
      Scheduler.start_link(
        queue: queue,
        max_workers: 1,
        poll_interval_ms: 10,
        lease_ms: 500,
        renew_interval_ms: 80,
        recovery_options: [hook: gate(parent, marker, :after_input)]
      )

    try do
      executor = receive_gate(marker)
      Process.sleep(120)
      send(executor, {marker, :release})
      # Later model calls use the same hook; release each bounded occurrence.
      release_until(f.id, marker)
    after
      if Process.alive?(scheduler), do: Scheduler.stop(scheduler)
    end

    {:ok, query} = Query.run(f.id)

    check(
      Enum.any?(query["spans"], &(&1["kind"] == "model_recording")),
      "no durable model correlation"
    )

    check(
      Enum.any?(query["spans"], &(&1["kind"] == "tool_attempt")),
      "no durable tool attempt correlation"
    )

    check(File.read!(Path.join(root, "artifact.txt")) == "ONE_EFFECT", "tool artifact differs")

    %{
      "run_ids" => [f.id],
      "status" => "succeeded",
      "queue" => queue,
      "trace_id" => TraceContext.trace_id(f.id),
      "actual_model_gate" => true,
      "effect_content" => "ONE_EFFECT"
    }
  end

  defp verify("unknown_reconcile", f) do
    ids = [f.id <> "-resolved", f.id <> "-manual"]

    for id <- ids do
      {:ok, _} =
        Recovery.create_run(id, @canary, opts(mock_mode: :unqueryable, mock_response: :lost))

      {:ok, blocked} = Recovery.resume(id)
      check(blocked.state.status == :blocked, "lost receipt did not remain blocked")
      {:ok, entry} = ReconciliationQueue.get(id)

      check(
        entry.safe_mode == :manual and DurableTools.stats(id).effects == 1,
        "unknown result was hidden or replayed"
      )
    end

    [resolved, manual] = ids
    {:ok, before} = Query.run(resolved)
    write_json(Path.join(f.directory, "before-reconcile.json"), before)
    {:error, :reconciliation_required} = Recovery.reconcile(resolved)

    {:ok, _} =
      Recovery.reconcile(resolved,
        result: {:ok, %{"receipt" => "owned-fixture-inspected"}},
        evidence: @canary
      )

    {:ok, final} = Recovery.resume(resolved)

    check(
      final.state.status == :succeeded and DurableTools.stats(resolved).effects == 1,
      "confirmation repeated an effect"
    )

    {:ok, after_query} = Query.run(resolved)
    write_json(Path.join(f.directory, "after-reconcile.json"), after_query)

    %{
      "run_ids" => ids,
      "status" => "succeeded_and_manual",
      "resolved_run_id" => resolved,
      "manual_run_id" => manual,
      "effects_per_run" => 1
    }
  end

  defp verify("approval_rework", f) do
    rounds =
      for n <- 1..2 do
        root = Path.join(f.directory, "round-#{n}")
        File.mkdir!(root)

        {:ok, definition} =
          Definition.new([
            %{
              id: "writer",
              role: :implementer,
              input: @canary,
              options: %{workspace: root, script: [file_call(), {:final, "DONE"}]}
            },
            %{
              id: "reviewer",
              role: :reviewer,
              deps: ["writer"],
              input: "Review fixture receipts",
              options: %{max_tool_calls: 0, script: [{:final, ~s({"approved":true})}]}
            }
          ])

        {:ok, artifact} =
          Artifact.new(root, ["artifact.txt"], initial: %{"artifact.txt" => "absent"})

        %{id: "r#{n}", definition: definition, artifacts: [artifact]}
      end

    {:ok, plan} = Plan.new(rounds)
    {:ok, _} = Approvals.create(f.id, plan)
    first = finish_case(f.id)
    first_workflow = first.workflow_id
    {:ok, _} = Approvals.decide(f.id, request(first, "rework", :rework))
    second = finish_case(f.id)
    {:ok, approved} = Approvals.decide(f.id, request(second, "approve", :approve))
    {:ok, _} = Approvals.release(f.id, request(approved, "release"))
    {:ok, old_workflow} = Workflows.load(first_workflow)
    seed = old_workflow.nodes["writer"].run_id
    {:ok, query} = Query.run(seed)
    runs = Enum.filter(query["spans"], &(&1["kind"] == "run"))
    check(length(runs) == 4, "Run ID did not reach other rework round")

    check(
      Enum.any?(query["links"], &(&1["relationship"] == "rework_started_round")),
      "missing causal rework link"
    )

    ids = Enum.map(runs, & &1["correlation"]["run_id"])

    %{
      "run_ids" => ids,
      "case_ids" => [f.id],
      "status" => "approved",
      "entry_run_id" => seed,
      "first_workflow_id" => first_workflow,
      "second_workflow_id" => second.workflow_id,
      "subject_hash" => approved.subject.subject_hash
    }
  end

  defp verify("export_failure_equivalence", f) do
    samples =
      for mode <- [:null, :error, :raise, :exit, :hang] do
        exporter = if mode == :null, do: {Null, []}, else: {FaultExporter, [mode: mode]}
        id = f.id <> "-" <> Atom.to_string(mode)

        value =
          with_exporter(exporter, fn ->
            initial = Observability.stats()
            {:ok, _} = Recovery.create_run(id, @canary, opts())
            {:ok, result} = Recovery.resume(id)
            check(result.state.status == :succeeded, "exporter affected execution result")

            if mode != :null do
              wait(fn ->
                now = Observability.stats()
                if now.export_errors > initial.export_errors, do: {:ok, now}, else: :wait
              end)
            end

            :ok = Observability.flush()
            semantic(id)
          end)

        %{"mode" => Atom.to_string(mode), "run_id" => id, "semantic" => value}
      end

    [baseline | rest] = samples

    check(
      Enum.all?(rest, &(&1["semantic"] == baseline["semantic"])),
      "export failure changed state, receipts or charged budget"
    )

    write_json(Path.join(f.directory, "comparison.json"), samples)

    %{
      "run_ids" => Enum.map(samples, & &1["run_id"]),
      "status" => "succeeded",
      "modes" => samples,
      "semantics_equal" => true
    }
  end

  defp verify("buffer_saturation", f) do
    {:ok, buffer} =
      Buffer.start_link(
        name: nil,
        capacity: 32,
        max_bytes: 16_384,
        max_event_bytes: 4096,
        batch_size: 4,
        recent_capacity: 8,
        recent_max_bytes: 8192,
        export_timeout_ms: 80,
        backoff_ms: 20,
        exporter: {FaultExporter, [mode: :hang]}
      )

    try do
      handle = Buffer.handle(buffer)

      producers =
        for n <- 1..16 do
          Task.async(fn ->
            for index <- 1..1000 do
              Observability.emit(:model_started, %{run_id: "owned-flood-#{n}-#{index}"}, %{},
                buffer: handle,
                outcome: :started
              )
            end
          end)
        end

      Enum.each(producers, &Task.await(&1, 10_000))
      state = Observability.stats(buffer)

      check(
        state.highwater_entries <= 32 and state.highwater_bytes <= 16_384,
        "queue exceeded configured capacity"
      )

      check(
        state.recent_entries <= 8 and state.recent_bytes <= 8192,
        "retained diagnostics grew beyond bounds"
      )

      check(
        state.mailbox_len <= 4 and state.dropped > 0,
        "producer notifications accumulated or saturation was not reached"
      )

      metrics = Observability.metrics(buffer)
      check(length(metrics) <= 1, "Run IDs became metric labels")

      write_json(Path.join(f.directory, "bounds.json"), %{
        stats: state,
        metrics: metrics,
        attempted: 16_000
      })

      %{
        "run_ids" => [],
        "status" => "expected_drops",
        "attempted" => 16_000,
        "stats" => state,
        "metric_series" => length(metrics)
      }
    after
      if Process.alive?(buffer), do: GenServer.stop(buffer)
    end
  end

  defp verify("observer_absence", f) do
    :ok = Observability.flush()

    owners =
      Map.new(
        [
          AgentSystemsLab.Registry,
          AgentSystemsLab.ProviderSupervisor,
          AgentSystemsLab.RunSupervisor
        ],
        &{&1, Process.whereis(&1)}
      )

    :ok = Supervisor.terminate_child(AgentSystemsLab.Supervisor, Buffer)

    try do
      check(Process.whereis(Buffer) == nil, "observer restarted without host action")
      :ok = Observability.emit(:model_started, %{run_id: f.id})
      {:ok, _} = Recovery.create_run(f.id, @canary, opts())
      {:ok, final} = Recovery.resume(f.id)

      check(
        final.state.status == :succeeded and DurableTools.stats(f.id).effects == 1,
        "missing observer affected execution"
      )

      check(
        Enum.all?(owners, fn {name, pid} -> Process.whereis(name) == pid end),
        "observer failure restarted execution infrastructure"
      )

      {:ok, query} = Query.run(f.id)

      check(
        query["trace_id"] == TraceContext.trace_id(f.id),
        "durable diagnostic required an exporter"
      )
    after
      {:ok, _} = Observability.restart()
    end

    %{
      "run_ids" => [f.id],
      "status" => "succeeded",
      "execution_owners_unchanged" => true,
      "explicit_observer_restart" => true
    }
  end

  defp verify("commit_windows", f) do
    windows =
      for stage <- [:before_commit, :after_commit] do
        id = f.id <> "-" <> Atom.to_string(stage)
        marker = make_ref()
        parent = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            Recovery.create_run(
              id,
              @canary,
              opts(script: [{:final, "DONE"}], hook: gate(parent, marker, stage))
            )
          end)

        try do
          ^pid = receive_gate(marker)
          visible = Query.run(id)

          check(
            (stage == :before_commit and visible == {:error, :not_found}) or
              (stage == :after_commit and match?({:ok, _}, visible)),
            "query did not observe actual COMMIT visibility"
          )

          Process.exit(pid, :kill)

          receive do: ({:DOWN, ^monitor, :process, ^pid, :killed} -> :ok),
                  after: (5000 -> raise "commit owner survived kill")

          if stage == :before_commit do
            check(
              Enum.all?(Observability.recent(), fn e -> e["correlation"]["run_id"] != id end),
              "rolled back create emitted committed evidence"
            )

            {:ok, _} = Recovery.create_run(id, @canary, opts(script: [{:final, "DONE"}]))
          end

          {:ok, final} = Recovery.resume(id)
          check(final.state.status == :succeeded, "query did not permit original safe recovery")

          %{
            "run_id" => id,
            "phase" => Atom.to_string(stage),
            "visible_at_gate" => stage == :after_commit
          }
        after
          if Process.alive?(pid), do: Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
        end
      end

    %{
      "run_ids" => Enum.map(windows, & &1["run_id"]),
      "status" => "succeeded",
      "windows" => windows
    }
  end

  defp verify("readonly_projection", f) do
    {:ok, _} = Recovery.create_run(f.id, @canary, opts())
    {:ok, _} = Recovery.resume(f.id)
    :ok = Observability.flush()
    before = fingerprint(f.id)
    boundaries = AgentSystemsLab.Approvals.Audit.boundaries() ++ [{Observability, :emit, 4}]
    Enum.each(boundaries, fn {module, _, _} -> Code.ensure_loaded!(module) end)
    Enum.each(boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

    {query, counts} =
      try do
        {:ok, query} = Query.run(f.id)
        {:ok, same} = Query.run(f.id)
        check(query == same, "durable trace projection changed between identical reads")
        {:ok, truncated} = Query.run(f.id, limit: 1)
        check(truncated["partial"], "limited query concealed truncation")

        counts =
          Map.new(boundaries, fn {m, fun, arity} = mfa ->
            {:call_count, n} = :erlang.trace_info(mfa, :call_count)
            {"#{inspect(m)}.#{fun}/#{arity}", n}
          end)

        check(Enum.all?(counts, fn {_, n} -> n == 0 end), "query triggered execution or emission")
        {query, counts}
      after
        Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
      end

    check(fingerprint(f.id) == before, "read-only query changed durable facts")

    write_json(Path.join(f.directory, "readonly-audit.json"), %{
      effect_boundary_calls: counts,
      source_sha256: before,
      query_sha256: Context.hash(query)
    })

    %{
      "run_ids" => [f.id],
      "status" => "succeeded",
      "zero_boundaries" => map_size(counts),
      "source_facts_unchanged" => true
    }
  end

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [
          script: [mock_call(), {:final, "DONE"}],
          task_budget: [max_dispatches: 16, execution_timeout_ms: 2000]
        ],
        extra
      )

  defp mock_call,
    do:
      {:call,
       %{operation_id: "owned-effect", tool: "mock_write", arguments: %{"private" => @canary}}}

  defp file_call,
    do:
      {:call,
       %{
         operation_id: "owned-file",
         tool: "file_write",
         arguments: %{
           "path" => "artifact.txt",
           "content" => "ONE_EFFECT",
           "expected_sha256" => "absent"
         }
       }}

  defp request(view, id, action \\ nil) do
    req = %{
      actor: "lab-human",
      reason: @canary,
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }

    if action, do: Map.put(req, :action, action), else: req
  end

  defp finish_case(id) do
    {:ok, pid} =
      Approvals.start_link(
        case_id: id,
        poll_interval_ms: 10,
        scheduler_options: [poll_interval_ms: 10, lease_ms: 500, renew_interval_ms: 80]
      )

    try do
      wait(fn ->
        case Approvals.load(id) do
          {:ok, %{status: :awaiting_review, subject: subject} = view} when not is_nil(subject) ->
            {:ok, view}

          _ ->
            :wait
        end
      end)
    after
      if Process.alive?(pid), do: Approvals.stop(pid)
    end
  end

  defp semantic(id) do
    {:ok, s} = Recovery.load(id)
    {:ok, recordings} = AgentSystemsLab.ModelResultStore.list(id)
    {:ok, budget} = AgentSystemsLab.TaskBudgetStore.load(id)

    %{
      status: s.state.status,
      seq: s.state.seq,
      output: s.state.output,
      turns: s.state.turn_count,
      operations: map_size(s.state.operations),
      operation_receipts_sha256: Context.hash(s.state.operations),
      effects: DurableTools.stats(id).effects,
      recordings: length(recordings),
      accepted_responses_sha256: Context.hash(Enum.map(recordings, & &1.record.response)),
      model_attempts: s.recovery.progress.model_attempts,
      output_bytes: s.recovery.progress.output_bytes,
      dispatches: budget.progress.dispatches
    }
  end

  defp fingerprint(id) do
    {:ok, s} = Recovery.load(id)
    {:ok, recordings} = AgentSystemsLab.ModelResultStore.list(id)
    {:ok, budget} = AgentSystemsLab.TaskBudgetStore.load(id)
    {:ok, operations} = DurableTools.list(id)
    Context.hash({s, recordings, budget, operations})
  end

  defp capture(ids, directory) do
    Enum.map(ids, fn id ->
      {:ok, query} = Query.run(id)
      encoded = JSON.encode!(query)
      assert_safe(encoded)
      filename = "trace-" <> Context.hash(id) <> ".json"
      write_json(Path.join(directory, filename), query)

      %{
        "run_id" => id,
        "path" => filename,
        "trace_sha256" => Context.hash(query),
        "source_sha256" => fingerprint(id)
      }
    end)
  end

  defp with_exporter(exporter, fun) do
    :ok = Observability.flush()
    previous = Observability.configuration()
    :ok = Observability.configure(exporter: exporter, export_timeout_ms: 40, backoff_ms: 10)

    try do: fun.(),
        after:
          (
            Observability.flush()

            :ok = Observability.configure(previous)
          )
  end

  defp gate(parent, marker, expected),
    do: fn stage ->
      if stage == expected do
        send(parent, {marker, self()})
        receive do: ({^marker, :release} -> :ok)
      end
    end

  defp receive_gate(marker) do
    receive do: ({^marker, pid} -> pid),
            after: (10_000 -> raise "owned observation gate not reached")
  end

  defp release_until(id, marker),
    do: release_until(id, marker, System.monotonic_time(:millisecond) + 15_000)

  defp release_until(id, marker, deadline) do
    {:ok, s} = Recovery.load(id)

    case s.state.status do
      :succeeded ->
        s

      status when status in [:failed, :cancelled, :blocked] ->
        raise "correlated worker stopped with #{status}"

      _ ->
        check(System.monotonic_time(:millisecond) < deadline, "correlated worker timed out")
        receive do: ({^marker, pid} -> send(pid, {marker, :release})), after: (10 -> :ok)
        release_until(id, marker, deadline)
    end
  end

  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + 15_000)

  defp wait(fun, deadline) do
    case fun.() do
      {:ok, v} ->
        v

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("observation condition timed out")

        Process.sleep(10)
        wait(fun, deadline)
    end
  end

  defp assert_safe(bytes) do
    check(not String.contains?(bytes, @canary), "private content reached observation export")

    for key <- [
          "claim_token",
          "claim_owner",
          "record_data",
          "input_data",
          "result_data",
          "progress_data"
        ] do
      check(
        not String.contains?(bytes, "\"#{key}\":"),
        "raw payload or authority field reached observation export"
      )
    end

    :ok
  end

  defp report(context, done, failed) do
    result =
      safe(%{
        "schema_version" => 1,
        "namespace" => context.namespace,
        "expected_case_count" => length(@cases),
        "case_count" => length(done),
        "all_passed" => is_nil(failed) and length(done) == length(@cases),
        "cases" => done,
        "failed_case" => failed,
        "run_ids" => Enum.flat_map(done, & &1["run_ids"]),
        "case_ids" => Enum.flat_map(done, &Map.get(&1, "case_ids", [])),
        "scope" =>
          "internal v1 logical traces and bounded metrics; host JSONL, no OTLP network or external collector"
      })

    write_json(Path.join(context.output, "report.json"), result)
    result
  end

  defp progress(opts, name, count, status),
    do:
      if(opts[:on_progress],
        do:
          opts[:on_progress].(%{
            case: name,
            completed: count,
            total: length(@cases),
            status: status
          })
      )

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:output, :on_progress] == [] and
         is_binary(Keyword.get(opts, :output, "artifacts/week19-observability")) and
         String.valid?(Keyword.get(opts, :output, "artifacts/week19-observability")) and
         Keyword.get(opts, :output, "artifacts/week19-observability") != "" and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week19-observability"), <<0>>) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_observability_demo_options}
  end

  defp isolated do
    cond do
      not Application.get_env(:agent_systems_lab, :database_enabled, true) ->
        {:error, :database_required}

      Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
          Process.whereis(Scheduler) ->
        {:error, :global_scheduler_enabled}

      Process.whereis(Buffer) == nil ->
        {:error, :observer_required}

      true ->
        :ok
    end
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

  defp check(true, _), do: :ok
  defp check(_, reason), do: raise(reason)

  defp safe(value) when is_binary(value),
    do:
      if(String.valid?(value),
        do: value,
        else: %{"encoding" => "base64", "data" => Base.encode64(value)}
      )

  defp safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe(%_{} = value), do: value |> Map.from_struct() |> safe()

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), safe(v)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)
  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()

  defp safe(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp safe(value) when is_pid(value) or is_reference(value) or is_port(value), do: inspect(value)
  defp safe(value), do: value

  defp write_json(path, value) do
    temp = path <> ".tmp"
    File.write!(temp, JSON.encode!(safe(value)) <> "\n")
    File.rename!(temp, path)
  end
end
