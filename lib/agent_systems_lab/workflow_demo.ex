defmodule AgentSystemsLab.WorkflowDemo do
  @moduledoc "Offline DAG evidence over the original durable Run execution engine."
  alias AgentSystemsLab.{
    Context,
    DurableTools,
    Recovery,
    ReconciliationQueue,
    Scheduler,
    Workflows
  }

  alias AgentSystemsLab.Workflows.{Audit, Definition, Join}

  @cases ~w(serial_baseline parallel_diamond same_budget_reviewer_comparison failure_propagation cancellation unknown_on_cancel controller_crash commit_windows absolute_deadline)
  def cases, do: @cases

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated(),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week17-workflow")),
         :ok <- create_output(output) do
      context = %{output: output, namespace: "w17-" <> Ecto.UUID.generate()}

      write_json(Path.join(output, "manifest.json"), %{
        namespace: context.namespace,
        expected_cases: @cases
      })

      report(context, [], nil)
      execute(@cases, [], context, opts)
    end
  end

  defp execute([], completed, context, _opts) do
    baseline = Enum.find(completed, &(&1["case"] == "serial_baseline"))
    parallel = Enum.find(completed, &(&1["case"] == "parallel_diamond"))
    check(baseline["allocations"] == parallel["allocations"], "comparison allocation changed")
    check(baseline["artifacts"] == parallel["artifacts"], "comparison artifact output differs")
    final = report(context, completed, nil)
    {:ok, %{output_dir: context.output, report: final}}
  end

  defp execute([name | rest], completed, context, opts) do
    result =
      try do
        progress(opts, name, length(completed), :starting)
        directory = Path.join(context.output, name)
        File.mkdir!(directory)

        fixture =
          Map.merge(context, %{directory: directory, id: context.namespace <> "-" <> name})

        summary = verify(name, fixture) |> Map.merge(%{"case" => name, "passed" => true})
        evidence = capture_workflows(summary["workflow_ids"], directory)
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
        {:error, {:workflow_verification_failed, %{output_dir: context.output, report: final}}}
    end
  end

  defp verify(name, fixture) when name in ["serial_baseline", "parallel_diamond"] do
    parallel = if name == "serial_baseline", do: 1, else: 2
    {:ok, definition} = Definition.new(diamond(fixture.directory), max_parallel: parallel)
    {:ok, _} = Workflows.create(fixture.id, definition)
    parent = self()
    marker = make_ref()
    count = :atomics.new(1, [])

    hook = fn
      :after_input ->
        if :atomics.add_get(count, 1, 1) in [2, 3] do
          send(parent, {marker, self()})
          receive do: ({^marker, :release} -> :ok)
        end

      _ ->
        :ok
    end

    started = System.monotonic_time(:millisecond)

    {done, observed} =
      with_controller(fixture.id, [recovery_options: [hook: hook]], fn coordinator ->
        first = receive_gate(marker)
        state = Workflows.status(coordinator)
        scheduler = state.scheduler
        active = Scheduler.status(scheduler).active
        check(length(active) <= parallel, "shared inflight exceeded configured parallelism")

        if parallel == 2 do
          second = receive_gate(marker)
          held = Workflows.status(coordinator)
          active = Scheduler.status(held.scheduler).active

          check(
            length(active) == 2 and length(Enum.uniq(Enum.map(active, & &1.claim.run_id))) == 2,
            "two branches did not overlap"
          )

          {:ok, pending} = Workflows.load(fixture.id)

          check(
            pending.nodes["join"].status == :waiting,
            "join admitted before both parents completed"
          )

          write_json(Path.join(fixture.directory, "overlap.json"), %{
            active: safe(active),
            join_status: pending.nodes["join"].status
          })

          send(first, {marker, :release})
          send(second, {marker, :release})
        else
          send(first, {marker, :release})
          second = receive_gate(marker)

          check(
            length(Scheduler.status(Workflows.status(coordinator).scheduler).active) == 1,
            "single-worker baseline overlapped"
          )

          send(second, {marker, :release})
        end

        {await_status(fixture.id, :succeeded), parallel}
      end)

    {:ok, joined} =
      Join.build(definition, Map.new(done.nodes, fn {id, n} -> {id, n.completion} end))

    input = JSON.decode!(done.nodes["join"].input)

    check(
      Enum.map(input["dependencies"], & &1["node_id"]) == ["a", "b"],
      "join dependency order differs"
    )

    for dep <- input["dependencies"] do
      check(
        dep["result_sha256"] == Context.hash(done.nodes[dep["node_id"]].completion),
        "join receipt hash differs"
      )

      check(dep["run_id"] == done.nodes[dep["node_id"]].run_id, "join source identity differs")
    end

    check(String.contains?(done.nodes["join"].input, "file_write"), "join lost tool receipts")
    {:ok, reviewer} = Recovery.load(done.nodes["join"].run_id)

    check(
      reviewer.recovery.config.workspace == nil and
        reviewer.recovery.config.budget.max_tool_calls == 0,
      "reviewer inherited implementer write authority"
    )

    write_json(Path.join(fixture.directory, "join.json"), joined)
    audit = audit(fixture, done)

    %{
      "workflow_ids" => [fixture.id],
      "status" => "succeeded",
      "observed_parallel" => observed,
      "elapsed_ms" => System.monotonic_time(:millisecond) - started,
      "allocations" => safe(Definition.allocations(definition)),
      "spending" => spending(done),
      "artifacts" =>
        Map.new(["a", "b"], fn id ->
          {id, File.read!(Path.join([fixture.directory, id, "artifact.txt"]))}
        end),
      "audit" => audit
    }
  end

  defp verify("same_budget_reviewer_comparison", fixture) do
    cap = %{
      max_turns: 6,
      max_model_attempts: 6,
      max_output_bytes: 10_000,
      max_tool_calls: 2,
      max_dispatches: 16
    }

    opinion = ~s({"approved":true,"issues":[]})
    task = "Produce artifacts A and B, then return a structured review opinion."

    results =
      Enum.map(["single", "reviewer"], fn mode ->
        workspace = Path.join(fixture.directory, mode)
        File.mkdir!(workspace)
        id = fixture.id <> "-" <> mode

        calls = [
          file_call_at("a-write", "a.txt", "artifact A"),
          file_call_at("b-write", "b.txt", "artifact B")
        ]

        nodes =
          if mode == "single" do
            [
              %{
                id: "single",
                input: task,
                options: %{
                  workspace: workspace,
                  script: calls ++ [{:final, opinion}],
                  max_turns: 6,
                  max_model_attempts: 6,
                  max_output_bytes: 10_000,
                  max_tool_calls: 2,
                  task_budget: %{max_dispatches: 16}
                }
              }
            ]
          else
            [
              %{
                id: "implementer",
                role: :implementer,
                input: task,
                options: %{
                  workspace: workspace,
                  script: calls ++ [{:final, "Both artifacts produced"}],
                  max_turns: 3,
                  max_model_attempts: 3,
                  max_output_bytes: 5000,
                  max_tool_calls: 2,
                  task_budget: %{max_dispatches: 8}
                }
              },
              %{
                id: "reviewer",
                role: :reviewer,
                deps: ["implementer"],
                input: task,
                options: %{
                  script: [{:final, opinion}],
                  max_turns: 3,
                  max_model_attempts: 3,
                  max_output_bytes: 5000,
                  max_tool_calls: 0,
                  task_budget: %{max_dispatches: 8}
                }
              }
            ]
          end

        {:ok, definition} = Definition.new(nodes, budgets: cap, max_parallel: 1)
        {:ok, _} = Workflows.create(id, definition)
        done = with_controller(id, [], fn _ -> await_status(id, :succeeded) end)
        final_id = if mode == "single", do: "single", else: "reviewer"

        if mode == "reviewer" do
          {:ok, reviewer} = Recovery.load(done.nodes["reviewer"].run_id)

          check(
            reviewer.recovery.config.workspace == nil and
              reviewer.recovery.config.budget.max_tool_calls == 0,
            "comparison reviewer inherited tool authority"
          )

          check(
            String.contains?(done.nodes["reviewer"].input, "file_write"),
            "comparison reviewer lost implementation receipts"
          )
        end

        {:ok, audit} = Audit.run(id, done)

        %{
          "mode" => mode,
          "workflow_id" => id,
          "caps" => safe(definition.budgets),
          "allocations" => safe(Definition.allocations(definition)),
          "spending" => spending(done),
          "status" => Atom.to_string(done.status),
          "opinion" => JSON.decode!(done.nodes[final_id].completion.output),
          "artifacts" =>
            Map.new([{"a", "a.txt"}, {"b", "b.txt"}], fn {key, path} ->
              {key, File.read!(Path.join(workspace, path))}
            end),
          "audit" => audit
        }
      end)

    [single, reviewer] = results

    for key <- ["caps", "allocations", "artifacts", "opinion"] do
      check(single[key] == reviewer[key], "same-budget comparison differs: #{key}")
    end

    check(Enum.all?(results, & &1["audit"]["all_passed"]), "comparison rebuild failed")
    write_json(Path.join(fixture.directory, "comparison.json"), results)

    %{
      "workflow_ids" => Enum.map(results, & &1["workflow_id"]),
      "status" => "succeeded",
      "results" => results,
      "scope" => "same task and fixed artifacts/opinion; scripted review is not quality evidence"
    }
  end

  defp verify("failure_propagation", fixture) do
    {:ok, definition} =
      Definition.new([
        %{
          id: "failed",
          input: "Fail before dependent admission",
          options: %{script: [{:error, "owned fixture failure"}]}
        },
        %{
          id: "dependent",
          deps: ["failed"],
          input: "Never execute",
          options: %{script: [{:final, "must not run"}]}
        }
      ])

    {:ok, _} = Workflows.create(fixture.id, definition)
    done = with_controller(fixture.id, [], fn _ -> await_status(fixture.id, :failed) end)
    check(done.nodes["dependent"].status == :skipped, "failed dependency did not propagate")

    check(
      Recovery.load(done.nodes["dependent"].run_id) == {:error, :not_found},
      "failed descendant was created"
    )

    %{
      "workflow_ids" => [fixture.id],
      "status" => "expected_failed",
      "dependent" => "skipped",
      "audit" => audit(fixture, done)
    }
  end

  defp verify("cancellation", fixture) do
    {:ok, definition} =
      Definition.new([
        %{
          id: "held",
          input: "Cancel running work",
          options: %{script: [{:final, "must not commit"}]}
        }
      ])

    {:ok, created} = Workflows.create(fixture.id, definition)
    marker = make_ref()
    parent = self()

    hook = fn
      :after_input ->
        send(parent, {marker, self()})
        receive do: ({^marker, :release} -> :ok)

      _ ->
        :ok
    end

    with_controller(fixture.id, [recovery_options: [hook: hook]], fn coordinator ->
      executor = receive_gate(marker)
      {:ok, cancelled} = Workflows.cancel(fixture.id, "owned cancellation")
      check(cancelled.status == :cancelled, "workflow cancel did not commit")
      Workflows.wake(coordinator)
      wait(fn -> if Process.alive?(executor), do: :wait, else: {:ok, :stopped} end)
    end)

    {:ok, child} = Recovery.load(created.nodes["held"].run_id)
    check(child.state.status == :cancelled, "cancelled child accepted a late result")
    {:ok, done} = Workflows.sync(fixture.id)
    %{"workflow_ids" => [fixture.id], "status" => "cancelled", "audit" => audit(fixture, done)}
  end

  defp verify("unknown_on_cancel", fixture) do
    {:ok, definition} =
      Definition.new([
        %{
          id: "held",
          input: "Effect before cancellation",
          options: %{mock_mode: :unqueryable, script: [mock_call(), {:final, "never finish"}]}
        },
        %{
          id: "dependent",
          deps: ["held"],
          input: "Never admit",
          options: %{script: [{:final, "must not run"}]}
        }
      ])

    {:ok, created} = Workflows.create(fixture.id, definition)
    marker = make_ref()
    parent = self()

    hook = fn
      :after_effect ->
        send(parent, {marker, self()})
        receive do: ({^marker, :release} -> :ok)

      _ ->
        :ok
    end

    with_controller(fixture.id, [recovery_options: [tool_hook: hook]], fn _ ->
      _executor = receive_gate(marker)
      {:ok, stopped} = Workflows.cancel(fixture.id, "cancel after unconfirmed effect")
      check(stopped.status == :cancelled, "parent cancellation was not durable")
    end)

    run_id = created.nodes["held"].run_id
    {:ok, child} = Recovery.load(run_id)
    check(child.state.status == :blocked, "ambiguous child was hidden by cancellation")
    {:ok, entry} = ReconciliationQueue.get(run_id)
    check(entry.safe_mode == :manual, "unknown child lost manual queue")
    check(DurableTools.stats(run_id).effects == 1, "effect count differs")
    {:ok, done} = Workflows.sync(fixture.id)
    check(done.nodes["dependent"].status == :skipped, "cancel unlocked descendant")
    write_json(Path.join(fixture.directory, "reconciliation.json"), entry)

    %{
      "workflow_ids" => [fixture.id],
      "status" => "cancelled_with_manual_reconciliation",
      "effects" => 1,
      "unresolved_nodes" => done.unresolved_nodes,
      "audit" => audit(fixture, done)
    }
  end

  defp verify("controller_crash", fixture) do
    workspace = Path.join(fixture.directory, "worker")
    File.mkdir!(workspace)

    {:ok, definition} =
      Definition.new([
        %{
          id: "writer",
          input: "Write once across coordinator death",
          options: %{
            workspace: workspace,
            script: [file_call("once", "ONE_EFFECT"), {:final, "done"}]
          }
        }
      ])

    {:ok, created} = Workflows.create(fixture.id, definition)
    marker = make_ref()
    parent = self()
    once = :atomics.new(2, [])

    hook = fn
      :after_effect ->
        :atomics.add(once, 2, 1)

      :after_receipt ->
        if :atomics.compare_exchange(once, 1, 0, 1) == :ok do
          send(parent, {marker, self()})
          receive do: ({^marker, :release} -> :ok)
        end

      _ ->
        :ok
    end

    {:ok, coordinator} = start_controller(fixture.id, recovery_options: [tool_hook: hook])
    Process.unlink(coordinator)
    monitor = Process.monitor(coordinator)

    try do
      _executor = receive_gate(marker)
      {:ok, [confirmed]} = DurableTools.list(created.nodes["writer"].run_id)
      check(confirmed.status == "completed", "crash did not occur after receipt COMMIT")
      old_scheduler = Workflows.status(coordinator).scheduler
      Process.exit(coordinator, :kill)

      receive do: ({:DOWN, ^monitor, :process, ^coordinator, :killed} -> :ok),
              after: (5000 -> raise "coordinator survived kill")

      wait(fn -> if Process.alive?(old_scheduler), do: :wait, else: {:ok, :gone} end)

      done =
        with_controller(fixture.id, [recovery_options: [tool_hook: hook]], fn _ ->
          await_status(fixture.id, :succeeded)
        end)

      check(
        done.nodes["writer"].run_id == created.nodes["writer"].run_id,
        "recovery replaced child identity"
      )

      check(:atomics.get(once, 2) == 1, "confirmed tool effect executed again")

      check(
        File.read!(Path.join(workspace, "artifact.txt")) == "ONE_EFFECT",
        "effect content differs"
      )

      %{
        "workflow_ids" => [fixture.id],
        "status" => "succeeded",
        "actual_coordinator_kill" => true,
        "original_scheduler_exited" => true,
        "effect_entry_count" => 1,
        "audit" => audit(fixture, done)
      }
    after
      if Process.alive?(coordinator), do: Workflows.stop(coordinator)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp verify("commit_windows", fixture) do
    windows =
      Enum.map([:before_commit, :after_commit], fn phase ->
        id = fixture.id <> "-" <> Atom.to_string(phase)

        {:ok, definition} =
          Definition.new([
            %{id: "root", input: "Complete parent", options: %{script: [{:final, "root done"}]}},
            %{
              id: "child",
              deps: ["root"],
              input: "Admit exactly once",
              options: %{script: [{:final, "child done"}]}
            }
          ])

        {:ok, initial} = Workflows.create(id, definition)
        {:ok, _} = Recovery.resume(initial.nodes["root"].run_id)
        parent = self()
        marker = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            Workflows.sync(id,
              hook: fn stage ->
                if stage == phase do
                  send(parent, {marker, self()})
                  receive do: ({^marker, :release} -> :ok)
                end
              end
            )
          end)

        try do
          ^pid = receive_gate(marker)
          {:ok, visible} = Workflows.load(id)
          expected = if phase == :before_commit, do: :waiting, else: :running

          check(
            visible.nodes["child"].status == expected,
            "child admission visibility at COMMIT differs"
          )

          Process.exit(pid, :kill)

          receive do: ({:DOWN, ^monitor, :process, ^pid, :killed} -> :ok),
                  after: (5000 -> raise "commit owner survived kill")

          {:ok, resumed} = Workflows.sync(id)
          check(resumed.nodes["child"].status == :running, "admission did not recover")
          done = with_controller(id, [], fn _ -> await_status(id, :succeeded) end)
          {:ok, _} = Audit.run(id, done)

          %{
            "workflow_id" => id,
            "phase" => Atom.to_string(phase),
            "child_before_kill" => Atom.to_string(expected),
            "child_run_id" => done.nodes["child"].run_id,
            "final_status" => "succeeded"
          }
        after
          if Process.alive?(pid), do: Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
        end
      end)

    %{
      "workflow_ids" => Enum.map(windows, & &1["workflow_id"]),
      "status" => "succeeded",
      "windows" => windows
    }
  end

  defp verify("absolute_deadline", fixture) do
    {:ok, definition} =
      Definition.new(
        [
          %{
            id: "slow",
            input: "Expire shared deadline",
            options: %{script: [{:stream, [{:sleep, 1000}, {:text_delta, "late"}, :done]}]}
          }
        ],
        timeout_ms: 150
      )

    {:ok, initial} = Workflows.create(fixture.id, definition)
    {:ok, child} = Recovery.load(initial.nodes["slow"].run_id)

    check(
      child.recovery.progress.deadline_at_ms <= initial.deadline_at_ms,
      "child reopened parent deadline"
    )

    done =
      with_controller(fixture.id, [], fn coordinator ->
        await_status(fixture.id, :failed)
        await_settled_terminal(coordinator, fixture.id, :failed)
      end)

    %{
      "workflow_ids" => [fixture.id],
      "status" => "expected_failed",
      "deadline_at_ms" => initial.deadline_at_ms,
      "child_deadline_at_ms" => child.recovery.progress.deadline_at_ms,
      "audit" => audit(fixture, done)
    }
  end

  @doc false
  def await_settled_terminal(coordinator, id, status)
      when status in [:succeeded, :failed, :cancelled] do
    # A terminal Workflow COMMIT precedes child fanout and its final projection.
    # Observe the completed database helper before stopping its Coordinator or
    # comparing a snapshot in the read-only reconstruction audit.
    wait(fn ->
      case Workflows.status(coordinator) do
        %{workflow_status: ^status, pending_sync: nil} ->
          case Workflows.load(id) do
            {:ok, %{status: ^status} = view} -> {:ok, view}
            _ -> :wait
          end

        _ ->
          :wait
      end
    end)
  end

  defp diamond(directory) do
    for id <- ["a", "b"], do: File.mkdir!(Path.join(directory, id))

    [
      %{
        id: "root",
        input: "Plan two private artifacts",
        options: %{script: [{:final, "root ready"}]}
      },
      %{
        id: "a",
        deps: ["root"],
        input: "Produce artifact A",
        role: :implementer,
        options: %{
          workspace: Path.join(directory, "a"),
          script: [file_call("a-write", "artifact A"), {:final, "A done"}]
        }
      },
      %{
        id: "b",
        deps: ["root"],
        input: "Produce artifact B",
        role: :implementer,
        options: %{
          workspace: Path.join(directory, "b"),
          script: [file_call("b-write", "artifact B"), {:final, "B done"}]
        }
      },
      %{
        id: "join",
        deps: ["b", "a"],
        input: "Review both receipts without inheriting write permission",
        role: :reviewer,
        options: %{max_tool_calls: 0, script: [{:final, ~s({"approved":true,"issues":[]})}]}
      }
    ]
  end

  defp file_call(id, content), do: file_call_at(id, "artifact.txt", content)

  defp file_call_at(id, path, content),
    do:
      {:call,
       %{
         operation_id: id,
         tool: "file_write",
         arguments: %{
           "path" => path,
           "content" => content,
           "expected_sha256" => "absent"
         }
       }}

  defp mock_call,
    do:
      {:call,
       %{operation_id: "ambiguous", tool: "mock_write", arguments: %{target: "owned-effect"}}}

  defp start_controller(id, opts),
    do:
      Workflows.start_link(
        workflow_id: id,
        poll_interval_ms: 10,
        scheduler_options:
          Keyword.merge([poll_interval_ms: 10, lease_ms: 500, renew_interval_ms: 80], opts)
      )

  defp with_controller(id, opts, fun) do
    {:ok, coordinator} = start_controller(id, opts)

    try do: fun.(coordinator),
        after: if(Process.alive?(coordinator), do: Workflows.stop(coordinator))
  end

  defp await_status(id, status),
    do:
      wait(fn ->
        case Workflows.load(id) do
          {:ok, %{status: ^status} = view} -> {:ok, view}
          _ -> :wait
        end
      end)

  defp receive_gate(marker) do
    receive do: ({^marker, pid} -> pid),
            after: (10_000 -> raise "owned workflow gate not reached")
  end

  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + 15_000)

  defp wait(fun, deadline) do
    case fun.() do
      {:ok, result} ->
        result

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("workflow condition timed out")

        Process.sleep(10)
        wait(fun, deadline)
    end
  end

  defp audit(fixture, view) do
    {:ok, result} = Audit.run(view.id, view)
    write_json(Path.join(fixture.directory, "audit.json"), result)
    result
  end

  defp capture_workflows(ids, directory) do
    Enum.map(ids, fn id ->
      {:ok, view} = Workflows.load(id)

      children =
        for {node_id, node} <- Enum.sort_by(view.nodes, &elem(&1, 0)),
            node.observed_seq > 0 do
          {:ok, snapshot} = Recovery.load(node.run_id)
          {:ok, operations} = DurableTools.list(node.run_id)
          {:ok, budget} = AgentSystemsLab.TaskBudgetStore.load(node.run_id)
          {:ok, recordings} = AgentSystemsLab.ModelResultStore.list(node.run_id)

          %{
            node_id: node_id,
            snapshot: snapshot,
            operations: operations,
            task_budget: budget,
            recordings: recordings
          }
        end

      filename = "workflow-" <> Context.hash(id) <> ".json"
      write_json(Path.join(directory, filename), %{workflow: view, children: children})

      %{
        "workflow_id" => id,
        "path" => filename,
        "workflow_sha256" => Context.hash(view),
        "created_children" => length(children)
      }
    end)
  end

  defp spending(view) do
    Enum.reduce(
      view.nodes,
      %{"model_attempts" => 0, "output_bytes" => 0, "tool_calls" => 0, "dispatches" => 0},
      fn {_, node}, acc ->
        {:ok, child} = Recovery.load(node.run_id)
        {:ok, budget} = AgentSystemsLab.TaskBudgetStore.load(node.run_id)

        acc
        |> Map.update!("model_attempts", &(&1 + child.recovery.progress.model_attempts))
        |> Map.update!("output_bytes", &(&1 + child.recovery.progress.output_bytes))
        |> Map.update!("tool_calls", &(&1 + map_size(child.state.operations)))
        |> Map.update!("dispatches", &(&1 + budget.progress.dispatches))
      end
    )
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

  defp report(context, completed, failed) do
    result = %{
      "schema_version" => 1,
      "namespace" => context.namespace,
      "expected_case_count" => length(@cases),
      "case_count" => length(completed),
      "all_passed" => failed == nil and length(completed) == length(@cases),
      "cases" => completed,
      "failed_case" => failed,
      "workflow_ids" => Enum.flat_map(completed, & &1["workflow_ids"]),
      "budget_accounting" =>
        "fixed allocations; no transfer or refund; child spending remains durable",
      "scope" => "static Scripted fixtures; no model-quality or production-performance claim"
    }

    write_json(Path.join(context.output, "report.json"), result)
    result
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:output, :on_progress] == [] and
         is_binary(Keyword.get(opts, :output, "artifacts/week17-workflow")) and
         String.valid?(Keyword.get(opts, :output, "artifacts/week17-workflow")) and
         Keyword.get(opts, :output, "artifacts/week17-workflow") != "" and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week17-workflow"), <<0>>) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_workflow_demo_options}
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

  defp safe(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{"encoding" => "base64", "data" => Base.encode64(value)}
  end

  defp safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe(%_{} = value), do: value |> Map.from_struct() |> safe()

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), safe(v)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)
  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()

  defp safe(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp safe(value) when is_pid(value) or is_port(value) or is_reference(value), do: inspect(value)
  defp safe(value), do: value

  defp write_json(path, value) do
    temporary = path <> ".tmp"
    File.write!(temporary, JSON.encode!(safe(value)) <> "\n")
    File.rename!(temporary, path)
  end
end
