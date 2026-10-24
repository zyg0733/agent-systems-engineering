defmodule AgentSystemsLab.ApprovalDemo do
  @moduledoc "Offline, synthetic human-operator requests against real durable review cases."
  alias AgentSystemsLab.{
    Approvals,
    Context,
    DurableTools,
    IntentStore,
    Recovery,
    ReconciliationQueue,
    Scheduler,
    Workflows
  }

  alias AgentSystemsLab.Approvals.{Artifact, Audit, Plan}
  alias AgentSystemsLab.Workflows.Definition

  @cases ~w(hash_bound_release changed_artifact_revokes baseline_conflict bounded_rework pause_restart pause_effect_unknown human_request_guard approval_commit_windows rework_commit_windows cancel_after_approval deadline_after_pause)
  def cases, do: @cases

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated(),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week18-approval")),
         :ok <- create_output(output) do
      context = %{output: output, namespace: "w18-" <> Ecto.UUID.generate()}

      write_json(Path.join(output, "manifest.json"), %{
        namespace: context.namespace,
        expected_cases: @cases
      })

      report(context, [], nil)
      execute(@cases, [], context, opts)
    end
  end

  defp execute([], completed, context, _opts),
    do: {:ok, %{output_dir: context.output, report: report(context, completed, nil)}}

  defp execute([name | rest], completed, context, opts) do
    result =
      try do
        progress(opts, name, length(completed), :starting)
        directory = Path.join(context.output, name)
        File.mkdir!(directory)

        fixture =
          Map.merge(context, %{directory: directory, id: context.namespace <> "-" <> name})

        summary = verify(name, fixture) |> Map.merge(%{"case" => name, "passed" => true})
        evidence = capture_cases(summary["case_ids"], directory)
        summary = Map.put(summary, "evidence", evidence)
        write_json(Path.join(directory, "summary.json"), summary)
        progress(opts, name, length(completed) + 1, :passed)
        {:ok, summary}
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        completed = completed ++ [summary]
        report(context, completed, nil)
        execute(rest, completed, context, opts)

      {:error, reason} ->
        final = report(context, completed, %{"case" => name, "reason" => reason})
        {:error, {:approval_verification_failed, %{output_dir: context.output, report: final}}}
    end
  end

  defp verify("hash_bound_release", f) do
    {review, _plan, roots} = ready(f)
    {:ok, approved} = Approvals.decide(f.id, request(review, "approve", :approve))
    release_request = request(approved, "release")
    {:ok, released} = Approvals.release(f.id, release_request)
    {:ok, repeated} = Approvals.release(f.id, release_request)
    check(released.snapshot === repeated.snapshot, "release retry changed approved bytes")
    [artifact] = released.snapshot.artifacts
    check(hd(artifact.files).content == "PATCH_V1", "release returned wrong bytes")
    check(File.read!(Path.join(hd(roots), "base.txt")) == "BASE", "release applied a patch")

    %{
      "case_ids" => [f.id],
      "status" => "approved",
      "subject_hash" => released.snapshot.subject_hash,
      "immutable_bytes" => hd(artifact.files).content,
      "published" => false
    }
  end

  defp verify("changed_artifact_revokes", f) do
    {review, _plan, roots} = ready(f)
    {:ok, approved} = Approvals.decide(f.id, request(review, "approve", :approve))
    release_request = request(approved, "release")
    {:ok, released} = Approvals.release(f.id, release_request)
    original_hash = approved.subject.subject_hash
    File.write!(Path.join(hd(roots), "patch.txt"), "MUTATED")
    {:error, {:approval_invalidated, _, invalidated}} = Approvals.release(f.id, release_request)

    check(
      is_nil(invalidated.approval) and invalidated.generation > approved.generation,
      "old approval survived mutation"
    )

    check(
      invalidated.subject.subject_hash != original_hash,
      "subject failed to bind changed output"
    )

    File.write!(Path.join(hd(roots), "patch.txt"), "PATCH_V1")
    {:ok, restored} = Approvals.sync(f.id)

    check(
      is_nil(restored.approval) and restored.subject.subject_hash != original_hash,
      "restoring old bytes revived approval"
    )

    check(
      hd(hd(released.snapshot.artifacts).files).content == "PATCH_V1",
      "previously released immutable bytes changed"
    )

    {:ok, renewed} = Approvals.decide(f.id, request(restored, "approve-again", :approve))
    {:ok, _} = Approvals.release(f.id, request(renewed, "release-new"))

    %{
      "case_ids" => [f.id],
      "status" => "approved_after_new_decision",
      "old_approval_invalidated" => true,
      "old_subject_hash" => original_hash,
      "new_subject_hash" => renewed.subject.subject_hash
    }
  end

  defp verify("baseline_conflict", f) do
    {review, _plan, roots} = ready(f, rounds: 2)
    {:ok, approved} = Approvals.decide(f.id, request(review, "approve", :approve))
    File.write!(Path.join(hd(roots), "base.txt"), "UNREVIEWED_BASE")

    {:error, {:approval_invalidated, _, conflict}} =
      Approvals.release(f.id, request(approved, "stale-release"))

    check(
      conflict.subject == nil and conflict.approval == nil,
      "baseline conflict kept an approval"
    )

    {:error, _} = Approvals.decide(f.id, request(conflict, "forbidden-approve", :approve))
    {:ok, conflict} = Approvals.load(f.id)
    {:ok, next} = Approvals.decide(f.id, request(conflict, "controlled-rework", :rework))
    check(next.current_round == 1, "conflict did not select declared rework round")
    done = finish(f.id)

    %{
      "case_ids" => [f.id],
      "status" => "awaiting_review",
      "baseline_conflict_blocked_release" => true,
      "rework_round" => done.current_round
    }
  end

  defp verify("bounded_rework", f) do
    {first, plan, _roots} = ready(f, rounds: 2)
    {:ok, old_workflow} = Workflows.load(first.workflow_id)
    before = spending(old_workflow)
    rework_request = request(first, "rework", :rework)
    {:ok, next} = Approvals.decide(f.id, rework_request)
    {:ok, same} = Approvals.decide(f.id, rework_request)

    check(
      next.current_round == same.current_round and next.workflow_id == same.workflow_id,
      "rework delivered twice"
    )

    second = finish(f.id)
    {:ok, prior} = Workflows.load(first.workflow_id)
    check(Context.hash(old_workflow) == Context.hash(prior), "rework rewrote original evidence")
    check(spending(prior) == before, "rework reset old counters")

    {:error, :approval_round_not_found} =
      Approvals.decide(f.id, request(second, "over-limit", :rework))

    {:ok, approved} = Approvals.decide(f.id, request(second, "approve-v2", :approve))
    {:ok, released} = Approvals.release(f.id, request(approved, "release-v2"))

    check(
      hd(hd(released.snapshot.artifacts).files).content == "PATCH_V2",
      "rework released old bytes"
    )

    %{
      "case_ids" => [f.id],
      "status" => "approved",
      "declared_rounds" => 2,
      "allocations" => Plan.allocations(plan),
      "prior_spending_unchanged" => true,
      "original_deadline_at_ms" => first.deadline_at_ms,
      "final_deadline_at_ms" => second.deadline_at_ms
    }
  end

  defp verify("pause_restart", f) do
    {plan, _roots} = plan(f)
    {:ok, created} = Approvals.create(f.id, plan)
    parent = self()
    marker = make_ref()
    hook = gate(parent, marker, :after_input)
    {:ok, coordinator} = start_controller(f.id, recovery_options: [hook: hook])

    {paused, old_claim} =
      try do
        executor = receive_gate(marker)
        wf_pid = Approvals.status(coordinator).workflow_coordinator
        scheduler = Workflows.status(wf_pid).scheduler
        [active] = Scheduler.status(scheduler).active
        {:ok, child} = Recovery.load(active.claim.run_id)
        {:ok, paused} = Approvals.pause(f.id, request(created, "pause"))
        {:error, {:workflow_paused, _}} = IntentStore.renew(active.claim)
        wait(fn -> if Process.alive?(executor), do: :wait, else: {:ok, :stopped} end)
        {:ok, after_pause} = Recovery.load(active.claim.run_id)
        check(child.state.run_id == after_pause.state.run_id, "pause changed Run identity")

        check(
          after_pause.recovery.progress.model_attempts >= child.recovery.progress.model_attempts,
          "pause refunded model attempts"
        )

        {paused, active.claim}
      after
        if Process.alive?(coordinator), do: Approvals.stop(coordinator)
      end

    {:ok, loaded} = Approvals.rebuild(f.id)
    check(loaded.status == :paused, "pause did not survive controller stop")
    {:ok, resumed} = Approvals.resume(f.id, request(loaded, "resume"))
    {:error, :stale_claim} = IntentStore.renew(old_claim)
    done = finish(f.id)

    check(
      resumed.deadline_at_ms == created.deadline_at_ms and
        done.deadline_at_ms == created.deadline_at_ms,
      "resume reset deadline"
    )

    %{
      "case_ids" => [f.id],
      "status" => "awaiting_review",
      "pause_seq" => paused.seq,
      "same_workflow_id" => done.workflow_id == created.workflow_id,
      "old_claim_revoked" => true
    }
  end

  defp verify("pause_effect_unknown", f) do
    {plan, _roots} = plan(f, ambiguous: true)
    {:ok, created} = Approvals.create(f.id, plan)
    parent = self()
    marker = make_ref()

    {:ok, coordinator} =
      start_controller(f.id, recovery_options: [tool_hook: gate(parent, marker, :after_effect)])

    paused =
      try do
        _executor = receive_gate(marker)
        {:ok, paused} = Approvals.pause(f.id, request(created, "pause-after-effect"))
        paused
      after
        if Process.alive?(coordinator), do: Approvals.stop(coordinator)
      end

    {:ok, _} = Approvals.resume(f.id, request(paused, "resume"))

    with_controller(f.id, [], fn _ ->
      wait(fn ->
        {:ok, w} = Workflows.load(created.workflow_id)
        if w.status == :blocked, do: {:ok, w}, else: :wait
      end)
    end)

    {:ok, workflow} = Workflows.load(created.workflow_id)
    id = workflow.nodes["writer"].run_id
    {:ok, entry} = ReconciliationQueue.get(id)

    check(
      entry.safe_mode == :manual and DurableTools.stats(id).effects == 1,
      "ambiguous effect was replayed or hidden"
    )

    {:error, :reconciliation_required} = Recovery.reconcile(id)
    {:ok, current} = Approvals.sync(f.id)
    {:ok, _} = Approvals.pause(f.id, request(current, "hold-for-human"))
    write_json(Path.join(f.directory, "reconciliation.json"), entry)

    %{
      "case_ids" => [f.id],
      "status" => "paused_with_manual_reconciliation",
      "effects" => 1,
      "run_id" => id,
      "operation_id" => entry.operation_id
    }
  end

  defp verify("human_request_guard", f) do
    {review, _plan, _roots} = ready(f)
    good = request(review, "approve", :approve)
    {:error, :unauthorized_approver} = Approvals.decide(f.id, %{good | actor: "model-reviewer"})

    {:error, :stale_approval_subject} =
      Approvals.decide(f.id, %{good | subject_hash: String.duplicate("0", 64)})

    {:error, _} = Approvals.decide(f.id, Map.put(good, :script, [{:final, "bypass"}]))
    {:error, :approval_case_managed} = Workflows.resume(review.workflow_id)
    {:ok, approved} = Approvals.decide(f.id, good)
    {:ok, same} = Approvals.decide(f.id, good)

    check(
      length(same.decisions) == 1 and same.seq == approved.seq,
      "duplicate decision counted twice"
    )

    {:error, :approval_request_conflict} =
      Approvals.decide(f.id, %{good | reason: "changed request"})

    %{
      "case_ids" => [f.id],
      "status" => "approved",
      "model_cannot_approve" => true,
      "managed_gate_bypass_denied" => true,
      "decision_count" => length(same.decisions)
    }
  end

  defp verify(name, f) when name in ["approval_commit_windows", "rework_commit_windows"] do
    action = if name == "approval_commit_windows", do: :approve, else: :rework

    windows =
      Enum.map([:before_commit, :after_commit], fn stage ->
        fixture = %{
          f
          | id: f.id <> "-" <> Atom.to_string(stage),
            directory: Path.join(f.directory, Atom.to_string(stage))
        }

        File.mkdir!(fixture.directory)
        {review, plan, _roots} = ready(fixture, rounds: if(action == :rework, do: 2, else: 1))
        req = request(review, "decision", action)
        marker = make_ref()
        parent = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            Approvals.decide(fixture.id, req, hook: gate(parent, marker, stage))
          end)

        try do
          ^pid = receive_gate(marker)
          {:ok, visible} = Approvals.load(fixture.id)

          expected_status =
            if stage == :before_commit,
              do: :awaiting_review,
              else: if(action == :approve, do: :approved, else: :running)

          check(visible.status == expected_status, "decision visibility around COMMIT differs")

          if action == :rework do
            {:ok, round} = Plan.round(plan, 1)
            next_id = Plan.workflow_id(fixture.id, round.id)
            found = Workflows.load(next_id)

            check(
              (stage == :before_commit and found == {:error, :not_found}) or
                (stage == :after_commit and match?({:ok, _}, found)),
              "rework enrollment was not atomic"
            )
          end

          Process.exit(pid, :kill)

          receive do: ({:DOWN, ^monitor, :process, ^pid, :killed} -> :ok),
                  after: (5000 -> raise "decision process survived kill")

          {:ok, recovered} = Approvals.decide(fixture.id, req)
          done = if action == :rework, do: finish(fixture.id), else: recovered
          check(length(done.decisions) == 1, "decision repeated after COMMIT ambiguity")

          %{
            "case_id" => fixture.id,
            "phase" => Atom.to_string(stage),
            "status" => Atom.to_string(done.status),
            "current_round" => done.current_round,
            "decision_count" => length(done.decisions)
          }
        after
          if Process.alive?(pid), do: Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
        end
      end)

    %{
      "case_ids" => Enum.map(windows, & &1["case_id"]),
      "status" => "expected",
      "windows" => windows
    }
  end

  defp verify("cancel_after_approval", f) do
    {review, _plan, _roots} = ready(f)
    {:ok, approved} = Approvals.decide(f.id, request(review, "approve", :approve))
    {:ok, cancelled} = Approvals.cancel(f.id, request(approved, "cancel"))
    {:error, _} = Approvals.release(f.id, request(cancelled, "forbidden-release"))
    {:error, _} = Workflows.resume(cancelled.workflow_id)

    check(
      cancelled.approval == nil and cancelled.status == :cancelled,
      "cancel left usable approval"
    )

    %{"case_ids" => [f.id], "status" => "cancelled", "release_denied" => true}
  end

  defp verify("deadline_after_pause", f) do
    {plan, _roots} = plan(f, timeout_ms: 150)
    {:ok, created} = Approvals.create(f.id, plan)
    {:ok, paused} = Approvals.pause(f.id, request(created, "pause"))
    Process.sleep(180)
    {:ok, expired} = Approvals.sync(f.id)

    check(
      expired.status == :failed and expired.deadline_at_ms == paused.deadline_at_ms,
      "pause extended original deadline"
    )

    {:error, _} = Approvals.resume(f.id, request(expired, "late-resume"))

    %{
      "case_ids" => [f.id],
      "status" => "expected_failed",
      "original_deadline_at_ms" => created.deadline_at_ms
    }
  end

  defp ready(f, opts \\ []) do
    {plan, roots} = plan(f, opts)
    {:ok, _} = Approvals.create(f.id, plan)
    {finish(f.id), plan, roots}
  end

  defp plan(f, opts \\ []) do
    rounds =
      for index <- 1..Keyword.get(opts, :rounds, 1) do
        root = Path.join(f.directory, "round-#{index}")
        File.mkdir!(root)
        File.write!(Path.join(root, "base.txt"), "BASE")
        script = [file_call("PATCH_V#{index}"), {:final, "Produced PATCH_V#{index}"}]
        script = if opts[:ambiguous], do: [mock_call() | script], else: script

        {:ok, definition} =
          Definition.new([
            %{
              id: "writer",
              role: :implementer,
              input: "Produce patch against BASE",
              options: %{
                workspace: root,
                script: script,
                mock_mode: if(opts[:ambiguous], do: :unqueryable, else: :idempotent)
              }
            },
            %{
              id: "reviewer",
              role: :reviewer,
              deps: ["writer"],
              input: "Return fixture review data; only the host can approve",
              options: %{max_tool_calls: 0, script: [{:final, ~s({"approved":true,"issues":[]})}]}
            }
          ])

        {:ok, artifact} =
          Artifact.new(root, ["patch.txt"],
            baselines: %{"base.txt" => sha("BASE")},
            initial: %{"patch.txt" => "absent"}
          )

        %{id: "r#{index}", definition: definition, artifacts: [artifact]}
      end

    {:ok, plan} = Plan.new(rounds, timeout_ms: Keyword.get(opts, :timeout_ms, 60_000))
    {plan, Enum.map(rounds, fn r -> hd(r.artifacts).root end)}
  end

  defp file_call(content),
    do:
      {:call,
       %{
         operation_id: "write-patch",
         tool: "file_write",
         arguments: %{"path" => "patch.txt", "content" => content, "expected_sha256" => "absent"}
       }}

  defp mock_call,
    do:
      {:call,
       %{
         operation_id: "ambiguous",
         tool: "mock_write",
         arguments: %{target: "owned-review-effect"}
       }}

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp request(view, id, action \\ nil) do
    base = %{
      actor: "lab-human",
      reason: "Owned offline fixture operator request",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }

    if action, do: Map.put(base, :action, action), else: base
  end

  defp start_controller(id, opts),
    do:
      Approvals.start_link(
        case_id: id,
        poll_interval_ms: 10,
        scheduler_options:
          Keyword.merge([poll_interval_ms: 10, lease_ms: 500, renew_interval_ms: 80], opts)
      )

  defp with_controller(id, opts, fun) do
    {:ok, pid} = start_controller(id, opts)
    try do: fun.(pid), after: if(Process.alive?(pid), do: Approvals.stop(pid))
  end

  defp finish(id),
    do:
      with_controller(id, [], fn _ ->
        wait(fn ->
          case Approvals.load(id) do
            {:ok, %{status: :awaiting_review, subject: subject} = view}
            when not is_nil(subject) ->
              {:ok, view}

            _ ->
              :wait
          end
        end)
      end)

  defp gate(parent, marker, expected),
    do: fn stage ->
      if stage == expected do
        send(parent, {marker, self()})
        receive do: ({^marker, :release} -> :ok)
      end
    end

  defp receive_gate(marker) do
    receive do: ({^marker, pid} -> pid),
            after: (10_000 -> raise "approval fixture gate not reached")
  end

  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + 15_000)

  defp wait(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("approval fixture timed out")

        Process.sleep(10)
        wait(fun, deadline)
    end
  end

  defp spending(workflow),
    do:
      Map.new(workflow.nodes, fn {id, node} ->
        {:ok, child} = Recovery.load(node.run_id)
        {:ok, budget} = AgentSystemsLab.TaskBudgetStore.load(node.run_id)

        {id,
         %{
           model_attempts: child.recovery.progress.model_attempts,
           output_bytes: child.recovery.progress.output_bytes,
           task: budget
         }}
      end)

  defp capture_cases(ids, directory) do
    Enum.map(ids, fn id ->
      {:ok, view} = Approvals.load(id)
      {:ok, audit} = Audit.run(id, view)

      workflows =
        Enum.flat_map(view.rounds, fn round ->
          case Workflows.load(round.workflow_id) do
            {:ok, workflow} ->
              children =
                for {_id, node} <- workflow.nodes, node.observed_seq > 0 do
                  {:ok, child} = Recovery.load(node.run_id)
                  {:ok, operations} = DurableTools.list(node.run_id)
                  %{snapshot: child, operations: operations}
                end

              [%{workflow: workflow, children: children}]

            {:error, :not_found} ->
              []
          end
        end)

      filename = "case-" <> Context.hash(id) <> ".json"

      write_json(Path.join(directory, filename), %{
        approval_case: view,
        workflows: workflows,
        audit: audit
      })

      %{
        "case_id" => id,
        "path" => filename,
        "audit" => audit,
        "workflow_count" => length(workflows)
      }
    end)
  end

  defp report(context, completed, failed) do
    result = %{
      "schema_version" => 1,
      "namespace" => context.namespace,
      "expected_case_count" => length(@cases),
      "case_count" => length(completed),
      "all_passed" => is_nil(failed) and length(completed) == length(@cases),
      "cases" => completed,
      "case_ids" => Enum.flat_map(completed, & &1["case_ids"]),
      "failed_case" => failed,
      "scope" =>
        "synthetic trusted host actors; fixed Scripted rounds; immutable bytes release, no publication or authentication service"
    }

    result = safe(result)
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
         is_binary(Keyword.get(opts, :output, "artifacts/week18-approval")) and
         String.valid?(Keyword.get(opts, :output, "artifacts/week18-approval")) and
         Keyword.get(opts, :output, "artifacts/week18-approval") != "" and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week18-approval"), <<0>>) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_approval_demo_options}
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
    temporary = path <> ".tmp"
    File.write!(temporary, JSON.encode!(safe(value)) <> "\n")
    File.rename!(temporary, path)
  end
end
