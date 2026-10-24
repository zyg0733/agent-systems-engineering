defmodule AgentSystemsLab.HistoryUpgradeDemo do
  @moduledoc "Trusted, fresh-database Week 21 upgrade and restore exercise."
  alias AgentSystemsLab.{
    Approvals,
    Backup,
    CheckpointStore,
    Context,
    DurableTools,
    HistoryMigration,
    IntentStore,
    Recovery,
    Repo,
    Storage,
    TaskBudgetStore,
    Workflows
  }

  alias AgentSystemsLab.Approvals.{Artifact, Plan}
  alias AgentSystemsLab.Backup.Command
  alias AgentSystemsLab.History.ReadonlyProof
  alias AgentSystemsLab.Workflows.Definition

  @legacy_version 20_261_024_020_000
  @fixture Path.expand("../../fixtures/history_v1", __DIR__)
  @child Path.expand("../../scripts/history_upgrade_child.exs", __DIR__)

  def run(opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:output]] and
         is_binary(Keyword.get(opts, :output, "artifacts/week21-history-upgrade")) and
         byte_size(Keyword.get(opts, :output, "artifacts/week21-history-upgrade")) in 1..4096 and
         String.valid?(Keyword.get(opts, :output, "artifacts/week21-history-upgrade")) and
         not String.contains?(
           Keyword.get(opts, :output, "artifacts/week21-history-upgrade"),
           <<0>>
         ) do
      run_valid(opts)
    else
      {:error, :invalid_upgrade_options}
    end
  end

  defp run_valid(opts) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week21-history-upgrade"))

    with :ok <- fresh_output(output) do
      Process.put({__MODULE__, :handles}, [])

      try do
        {:ok, source} = new_database("legacy-source")
        {:ok, seeded} = child(source, "seed_legacy", output)
        {:ok, old_bundle} = Backup.dump(source, Path.join(output, "legacy-backup"))
        {:ok, migrated} = child(source, "upgrade", output)
        {:ok, bundle} = Backup.dump(source, Path.join(output, "upgraded-backup"))
        {:ok, restored} = restore(bundle, "current-restore")
        {:ok, source_proof} = read_json(output, "source-proof.json")
        scope = scope(output)

        {:ok, raw_proof} =
          Backup.with_connection(restored, &ReadonlyProof.capture_connection(&1, scope))

        write_json(output, "readonly-restore-proof.json", raw_proof)
        :ok = ReadonlyProof.compare(source_proof, raw_proof)

        {:ok, activation} =
          AgentSystemsLab.History.RestoreGuard.activate(restored, scope, source_proof)

        {:ok, resumed} = child(restored, "resume", output)

        # The old dump genuinely has no history_format columns or migration journal.
        {:ok, legacy_restore} = restore(old_bundle, "legacy-restore")

        {:ok, legacy_migrated} = child(legacy_restore, "upgrade_legacy_restore", output)
        {:ok, %{readonly: true}} = Backup.metadata(legacy_restore)
        {:ok, legacy_proof} = read_json(output, "legacy-restore-proof.json")
        # Maintenance used one privileged, scheduler-free child session; other
        # connections stayed read-only. Re-bundle its verified upgraded bytes,
        # then use the ordinary exact-copy activation path in another fresh DB.
        {:ok, converted_bundle} =
          Backup.dump(legacy_restore, Path.join(output, "converted-legacy-backup"))

        {:ok, converted_restore} = restore(converted_bundle, "converted-legacy-restore")

        {:ok, legacy_activated} =
          AgentSystemsLab.History.RestoreGuard.activate(converted_restore, scope, legacy_proof)

        {:ok, legacy_verified} = child(converted_restore, "verify_activated_legacy", output)

        report = %{
          "schema_version" => 1,
          "all_passed" => true,
          "legacy" => seeded,
          "migration" => migrated,
          "readonly_restore_exact" => true,
          "restore_activation" => activation,
          "safe_continuation" => resumed,
          "old_schema_restore_migration" => legacy_migrated,
          "old_schema_restore_fencing" => legacy_activated,
          "old_schema_restore_verified" => legacy_verified,
          "business_schema_version" => 1,
          "codec_version" => 1,
          "source_history_format" => 1,
          "target_history_format" => 2,
          "database_only_backup" => true,
          "workspace_files_preserved_at_original_authorized_roots" => true
        }

        write_json(output, "report.json", report)
        {:ok, %{output_dir: output, report: report}}
      after
        results = Enum.map(Process.get({__MODULE__, :handles}, []), &Backup.drop/1)

        write_json(output, "database-cleanup.json", %{
          "all_owned_databases_dropped" => Enum.all?(results, &(&1 == :ok))
        })

        Process.delete({__MODULE__, :handles})
      end
    end
  end

  @doc "Fixed trusted child entry point; action and fixture paths are not model tools."
  def child_action(action, output)
      when action in [
             "seed_legacy",
             "upgrade",
             "upgrade_legacy_restore",
             "resume",
             "verify_activated_legacy"
           ] do
    if action == "seed_legacy" do
      Ecto.Migrator.run(Repo, migration_path(), :up, to: @legacy_version, log: false)
      load_legacy_modules!()
      seed_legacy(output)
    else
      Ecto.Migrator.run(Repo, migration_path(), :up, all: true, log: false)
      Storage.preload_vocabulary()

      case action do
        "upgrade" -> upgrade(output, "source-proof.json")
        "upgrade_legacy_restore" -> upgrade(output, "legacy-restore-proof.json")
        "resume" -> resume_restored(output)
        "verify_activated_legacy" -> verify_activated_legacy(output)
      end
    end
  end

  defp seed_legacy(output) do
    prefix = "w21-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(output, "workspace")
    File.mkdir!(root)
    ids = Map.new(~w(file pending unknown budget leased), &{&1, prefix <> "-" <> &1})
    call = {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 21}}}
    opts = [run_timeout_ms: 3_600_000, task_budget: [execution_timeout_ms: 600_000]]

    file_call =
      {:call,
       %{
         operation_id: "write-once",
         tool: "file_write",
         arguments: %{
           "path" => "result.txt",
           "content" => "preserved Week 20 receipt\n",
           "expected_sha256" => "absent"
         }
       }}

    {:ok, _} =
      Recovery.create_run(
        ids["file"],
        "Write once",
        opts ++ [workspace: root, script: [file_call, {:final, "done"}]]
      )

    {:ok, planned} = Recovery.step(ids["file"])
    {:ok, _} = CheckpointStore.create(ids["file"], planned.state.seq)
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(ids["file"])

    for name <- ["pending", "unknown"] do
      mode = if name == "unknown", do: :unqueryable, else: :idempotent

      {:ok, _} =
        Recovery.create_run(
          ids[name],
          "Preserve tool semantics",
          opts ++
            [
              script: [call, {:final, "done"}],
              mock_mode: mode,
              mock_response: if(name == "unknown", do: :lost, else: :ok)
            ]
        )

      if name == "pending",
        do: {:ok, _} = Recovery.step(ids[name]),
        else: {:ok, %{state: %{status: :blocked}}} = Recovery.resume(ids[name])
    end

    {:ok, _} =
      Recovery.create_run(
        ids["budget"],
        "Keep spent budget",
        opts ++ [script: [{:final, "too many bytes"}], max_output_bytes: 1]
      )

    {:ok, %{state: %{status: :failed}}} = Recovery.resume(ids["budget"])

    {:ok, _} =
      Recovery.create_run(
        ids["leased"],
        "Copied worker must be fenced",
        opts ++ [script: [{:final, "after takeover"}]]
      )

    {:ok, claim} = IntentStore.claim(ids["leased"], "source-worker", lease_ms: 3_600_000)
    {:ok, _} = TaskBudgetStore.reserve(claim)

    {:ok, claim_bytes} =
      AgentSystemsLab.Storage.Codec.encode(%{
        claim
        | expires_at: DateTime.to_iso8601(claim.expires_at)
      })

    File.write!(Path.join(output, "private-source-claim.bin"), claim_bytes, [:exclusive])
    File.chmod!(Path.join(output, "private-source-claim.bin"), 0o600)
    case_id = prefix <> "-approval"
    approved = seed_approval(case_id, output)
    %{rows: rows} = Repo.query!("SELECT id FROM lab_runs ORDER BY id", [])
    %{rows: workflows} = Repo.query!("SELECT id FROM lab_workflows ORDER BY id", [])

    scope = %{
      "runs" => List.flatten(rows),
      "workflows" => List.flatten(workflows),
      "cases" => [case_id]
    }

    write_json(output, "scope.json", scope)
    write_json(output, "fixture-ids.json", ids)

    logical =
      logical_proof(%{runs: scope["runs"], workflows: scope["workflows"], cases: scope["cases"]})

    write_json(output, "legacy-logical.json", logical)

    %{rows: [[false]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='lab_runs' AND column_name='history_format')",
        []
      )

    %{
      "legacy_last_migration" => @legacy_version,
      "legacy_has_no_format_column" => true,
      "runs" => length(rows),
      "workflow_count" => length(workflows),
      "approval_status" => Atom.to_string(approved.status),
      "logical_sha256" => Context.hash(logical),
      "unknown_effects" => DurableTools.stats(ids["unknown"]).effects
    }
  end

  defp seed_approval(id, output) do
    rounds =
      for number <- 1..2 do
        root = Path.join(output, "approval-round-#{number}")
        File.mkdir!(root)
        File.write!(Path.join(root, "base.txt"), "BASE")

        call =
          {:call,
           %{
             operation_id: "patch",
             tool: "file_write",
             arguments: %{
               "path" => "patch.txt",
               "content" => "PATCH#{number}",
               "expected_sha256" => "absent"
             }
           }}

        {:ok, definition} =
          Definition.new([
            %{
              id: "writer",
              role: :implementer,
              input: "Prepare offline patch",
              options: %{
                workspace: root,
                script: [call, {:final, "done"}],
                run_timeout_ms: 3_600_000
              }
            }
          ])

        {:ok, artifact} =
          Artifact.new(root, ["patch.txt"],
            baselines: %{"base.txt" => sha("BASE")},
            initial: %{"patch.txt" => "absent"}
          )

        %{id: "r#{number}", definition: definition, artifacts: [artifact]}
      end

    {:ok, plan} = Plan.new(rounds, timeout_ms: 3_600_000)
    {:ok, _} = Approvals.create(id, plan)
    review = finish_review(id)
    {:ok, _} = Approvals.decide(id, request(review, "rework", :rework))
    review = finish_review(id)
    {:ok, approved} = Approvals.decide(id, request(review, "approve", :approve))
    approved
  end

  defp finish_review(id) do
    {:ok, view} = Approvals.sync(id)
    {:ok, workflow} = Workflows.load(view.workflow_id)

    for {_node, node} <- workflow.nodes, node.status in [:running, :ready] do
      {:ok, _} = Recovery.resume(node.run_id)
    end

    {:ok, review} = Approvals.sync(id)
    :awaiting_review = review.status
    review
  end

  defp upgrade(output, proof_name) do
    boundaries =
      AgentSystemsLab.Approvals.Audit.boundaries() ++
        [
          {AgentSystemsLab.Observability, :emit, 4},
          {AgentSystemsLab.Evaluation.Runner, :execute, 6},
          {AgentSystemsLab.Evaluation.Scorer, :score, 5}
        ]

    Enum.each(boundaries, fn {module, _, _} -> Code.ensure_loaded!(module) end)
    Enum.each(boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

    try do
      result = migrate_and_prove(output, proof_name)

      counts =
        Map.new(boundaries, fn {module, name, arity} = mfa ->
          {:call_count, count} = :erlang.trace_info(mfa, :call_count)
          {"#{inspect(module)}.#{name}/#{arity}", count}
        end)

      true = Enum.all?(counts, fn {_, count} -> count == 0 end)
      Map.put(result, "effect_boundary_calls", counts)
    after
      Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end

  defp migrate_and_prove(output, proof_name) do
    scope = scope(output)
    before = logical_proof(scope)
    {:ok, legacy} = read_json(output, "legacy-logical.json")
    true = before == legacy

    migrations =
      for id <- scope.runs do
        {:ok, %{state: state}} = Recovery.load(id)
        {:ok, plan} = HistoryMigration.plan(id)
        true = plan.expected_seq == state.seq
        # Live source claims are deliberately retained and refused. All other
        # runs can be migrated without touching intent tokens or spent budgets.
        case HistoryMigration.migrate(id, state.seq) do
          {:ok, result} ->
            {:ok, %{status: :already_current}} = HistoryMigration.migrate(id, state.seq)

            %{
              "run_id" => id,
              "status" => Atom.to_string(result.status),
              "repeat" => "already_current"
            }

          {:error, :intent_claimed} ->
            %{"run_id" => id, "status" => "live_claim_refused"}

          {:error, {:intent_claimed, _}} ->
            %{"run_id" => id, "status" => "live_claim_refused"}

          other ->
            raise "Unexpected migration result: #{inspect(other)}"
        end
      end

    true = before == logical_proof(scope)
    {:ok, proof} = ReadonlyProof.capture(scope)
    write_json(output, proof_name, proof)

    %{
      "logical_state_identical" => true,
      "legacy_logical_sha256" => Context.hash(before),
      "migrations" => migrations
    }
  end

  defp resume_restored(output) do
    scope = scope(output)
    true = logical_proof(scope) == elem(read_json(output, "legacy-logical.json"), 1)
    {:ok, post_fence} = ReadonlyProof.capture(scope)
    {:ok, source_proof} = read_json(output, "source-proof.json")
    :ok = ReadonlyProof.compare_semantics(source_proof, post_fence)
    write_json(output, "activated-current-proof.json", post_fence)
    {:ok, ids} = read_json(output, "fixture-ids.json")

    claim = read_claim(output)

    {:error, _} = Recovery.execute_claim(claim)
    {:ok, leased} = Storage.load(ids["leased"])
    {:ok, _} = HistoryMigration.migrate(ids["leased"], leased.state.seq)
    file = File.read!(Path.join(output, "workspace/result.txt"))
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(ids["file"])
    true = file == File.read!(Path.join(output, "workspace/result.txt"))
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(ids["pending"])
    1 = DurableTools.stats(ids["pending"]).effects
    {:ok, %{state: %{status: :blocked}}} = Recovery.resume(ids["unknown"])
    1 = DurableTools.stats(ids["unknown"]).effects
    {:ok, _} = AgentSystemsLab.ReconciliationQueue.get(ids["unknown"])
    {:ok, %{state: %{status: :failed}}} = Recovery.resume(ids["budget"])
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(ids["leased"])
    {:ok, case_view} = Approvals.load(hd(scope.cases))
    :approved = case_view.status
    {:ok, _} = Approvals.release(case_view.id, request(case_view, "restore-release"))

    %{
      "old_claim_rejected" => true,
      "completed_file_unchanged" => true,
      "pending_tool_effects" => 1,
      "unknown_stays_manual" => true,
      "unknown_effects" => 1,
      "spent_budget_failure_preserved" => true,
      "leased_run_resumed_with_new_claim" => true,
      "approval_revalidated" => true,
      "post_fence_semantics_and_protected_facts_identical" => true,
      "previously_leased_history_migrated_after_fence" => true
    }
  end

  defp verify_activated_legacy(output) do
    scope = scope(output)
    true = logical_proof(scope) == elem(read_json(output, "legacy-logical.json"), 1)
    {:error, _} = Recovery.execute_claim(read_claim(output))
    {:ok, proof} = ReadonlyProof.capture(scope)
    {:ok, before} = read_json(output, "legacy-restore-proof.json")
    :ok = ReadonlyProof.compare_semantics(before, proof)
    write_json(output, "activated-legacy-proof.json", proof)
    {:ok, ids} = read_json(output, "fixture-ids.json")
    {:ok, leased} = Storage.load(ids["leased"])
    {:ok, _} = HistoryMigration.migrate(ids["leased"], leased.state.seq)

    %{
      "old_claim_rejected" => true,
      "semantic_protected_hashes_preserved" => true,
      "previously_leased_history_migrated_after_fence" => true
    }
  end

  defp logical_proof(scope) do
    %{
      "runs" =>
        Map.new(scope.runs, fn id ->
          {:ok, view} = Recovery.load(id)
          {:ok, budget} = TaskBudgetStore.load(id)
          # Delivery credentials deliberately change on takeover; all task facts,
          # authority, consumed budget, receipts and absolute deadlines do not.
          {id, Context.hash(%{view: Map.delete(view, :intent), budget: budget})}
        end),
      "workflows" =>
        Map.new(scope.workflows, fn id ->
          {:ok, view} = Workflows.load(id)
          {id, Context.hash(view)}
        end),
      "cases" =>
        Map.new(scope.cases, fn id ->
          {:ok, view} = Approvals.load(id)
          {id, Context.hash(view)}
        end)
    }
  end

  defp load_legacy_modules! do
    {:ok, manifest} = @fixture |> Path.join("manifest.json") |> File.read!() |> JSON.decode()

    for name <- ["run.ex", "event.ex", "storage.ex", "model_result_store.ex"] do
      path = Path.join([@fixture, "runtime", name])
      true = sha(File.read!(path)) == manifest["files"][name]["sha256"]
    end

    Code.compiler_options(ignore_module_conflict: true)

    for name <- ["run.ex", "event.ex", "storage.ex", "model_result_store.ex"],
        do: Code.compile_file(Path.join([@fixture, "runtime", name]))
  end

  defp child(handle, action, output) do
    {:ok, env} = Backup.child_env(handle)

    paths =
      :code.get_path()
      |> Enum.filter(&String.contains?(List.to_string(&1), "/_build/"))
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    args = paths ++ [@child, action, output]

    case Command.run(System.find_executable("elixir"), args, env ++ [{"ERL_FLAGS", "+S 2:2"}],
           timeout_ms: 120_000
         ) do
      {:ok, log} ->
        File.write!(Path.join(output, action <> ".log"), log)
        line = Enum.find(String.split(log, "\n"), &String.starts_with?(&1, "UPGRADE_RESULT="))

        if line,
          do: JSON.decode(String.replace_prefix(line, "UPGRADE_RESULT=", "")),
          else: {:error, :missing_child_result}

      error ->
        error
    end
  end

  defp new_database(label), do: remember(Backup.create_lab_database(label))
  defp restore(bundle, label), do: remember(Backup.restore(bundle, label: label))

  defp remember({:ok, handle} = result) do
    Process.put({__MODULE__, :handles}, [handle | Process.get({__MODULE__, :handles}, [])])
    result
  end

  defp remember({:error, {:backup_restore_failed, _reason, handle}} = error) do
    Process.put({__MODULE__, :handles}, [handle | Process.get({__MODULE__, :handles}, [])])
    error
  end

  defp remember(other), do: other

  defp read_claim(output) do
    {:ok, claim} =
      AgentSystemsLab.Storage.Codec.decode(
        File.read!(Path.join(output, "private-source-claim.bin"))
      )

    {:ok, expires, 0} = DateTime.from_iso8601(claim.expires_at)
    %{claim | expires_at: expires}
  end

  defp migration_path, do: Application.app_dir(:agent_systems_lab, "priv/repo/migrations")

  defp request(view, id, action \\ nil) do
    base = %{
      actor: "lab-human",
      reason: "Owned upgrade fixture",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }

    if action, do: Map.put(base, :action, action), else: base
  end

  defp scope(output) do
    {:ok, value} = read_json(output, "scope.json")
    %{runs: value["runs"], workflows: value["workflows"], cases: value["cases"]}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp read_json(output, name), do: output |> Path.join(name) |> File.read!() |> JSON.decode()

  defp write_json(output, name, value),
    do: File.write!(Path.join(output, name), JSON.encode!(value) <> "\n")

  defp fresh_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> File.chmod(output, 0o700)
        {:error, :eexist} -> {:error, {:output_exists, output}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
