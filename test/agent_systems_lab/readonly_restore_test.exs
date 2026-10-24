defmodule AgentSystemsLab.ReadonlyRestoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    Backup,
    CheckpointStore,
    HistoryMigration,
    IntentStore,
    Recovery,
    Repo,
    Storage
  }

  alias AgentSystemsLab.History.{Compatibility, ReadonlyProof, RestoreGuard}
  @moduletag :database
  @moduletag timeout: 120_000

  setup do
    assert {:ok, source} = Backup.create_lab_database("readonly-proof-test")
    {:ok, options} = Backup.connection_options(source)

    {:ok, pid} =
      Repo.start_link(
        Keyword.merge(Repo.config(), options)
        |> Keyword.delete(:url)
        |> Keyword.merge(name: nil, pool_size: 2)
      )

    Process.unlink(pid)
    previous = Repo.put_dynamic_repo(pid)

    conflict = Code.get_compiler_option(:ignore_module_conflict)

    try do
      Code.put_compiler_option(:ignore_module_conflict, true)

      Ecto.Migrator.run(
        Repo,
        Application.app_dir(:agent_systems_lab, "priv/repo/migrations"),
        :up,
        all: true,
        log: false
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, conflict)
    end

    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "w21-readonly-#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      if Process.alive?(pid), do: GenServer.stop(pid)
      assert :ok = Backup.drop(source)
      File.rm_rf!(root)
    end)

    %{source: source, repo: pid, previous: previous, root: root}
  end

  test "complete proofs are stable, private, read-only and insensitive to history layout" do
    {:ok, _} = Storage.create_run("completed", "SECRET-PROOF-CANARY")
    {:ok, _} = Storage.dispatch("completed", 1, {:model_response, {:final, "done"}})
    {:ok, saved} = Storage.load("completed")
    {:ok, _} = CheckpointStore.create("completed", saved.state.seq)
    scope = %{runs: ["completed"], workflows: [], cases: []}

    boundaries =
      AgentSystemsLab.Approvals.Audit.boundaries() ++
        [
          {AgentSystemsLab.Observability, :emit, 4},
          {AgentSystemsLab.HistoryMigration, :migrate, 2},
          {AgentSystemsLab.HistoryMigration, :migrate, 3},
          {AgentSystemsLab.History.RestoreGuard, :activate, 3}
        ]

    Enum.each(boundaries, fn {module, _, _} = mfa ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(mfa, true, [:call_count])
    end)

    first =
      try do
        assert {:ok, first} = ReadonlyProof.capture(scope)
        assert {:ok, ^first} = ReadonlyProof.capture(scope)

        assert Enum.all?(boundaries, fn mfa ->
                 :erlang.trace_info(mfa, :call_count) === {:call_count, 0}
               end)

        first
      after
        Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
      end

    assert :ok = ReadonlyProof.validate(first, :source)

    for partial <- [
          Map.delete(first, "database_hash"),
          Map.put(first, "semantic_hash", String.duplicate("A", 64)),
          Map.put(first, "scope_complete", false),
          Map.put(first, "tables", []),
          Map.put(first, "sequences", []),
          put_in(first, ["compatibility", "migration_versions"], []),
          Map.delete(first, "verified_readers"),
          Map.put(first, "runs", [])
        ] do
      assert {:error, :invalid_restore_proof} = ReadonlyProof.compare(partial, partial)
      assert {:error, :invalid_restore_proof} = ReadonlyProof.compare_semantics(partial, partial)
    end

    assert length(first["tables"]) === 23
    assert Enum.any?(first["sequences"], &is_boolean(&1["is_called"]))
    refute JSON.encode!(first) =~ "SECRET-PROOF-CANARY"
    assert {:ok, _} = HistoryMigration.migrate("completed", saved.state.seq)
    assert {:ok, migrated} = ReadonlyProof.capture(scope)
    assert first["semantic_hash"] === migrated["semantic_hash"]
    assert first["raw_semantic_hash"] === migrated["raw_semantic_hash"]
    refute first["database_hash"] === migrated["database_hash"]

    assert {:error, {:incomplete_restore_scope, "runs"}} =
             ReadonlyProof.capture(%{runs: [], workflows: [], cases: []})
  end

  test "raw read-only restore matches every column and sequence before explicit lease fencing",
       c do
    assert {:ok, _} =
             Recovery.create_run("pending", "private lease",
               script: [{:final, "done"}],
               task_budget: [max_dispatches: 8]
             )

    assert {:ok, claim} = IntentStore.claim("pending", "private-worker", lease_ms: 30_000)

    assert {:ok, source_proof} =
             ReadonlyProof.capture(%{runs: ["pending"], workflows: [], cases: []})

    assert {:ok, bundle} = Backup.dump(c.source, Path.join(c.root, "bundle"))
    assert {:ok, target} = Backup.restore(bundle)

    try do
      assert {:ok, copy} =
               Backup.with_connection(target, fn conn ->
                 assert {:error, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} =
                          Postgrex.query(conn, "UPDATE lab_runs SET seq=seq", [])

                 ReadonlyProof.capture_connection(conn, source_proof["scope"])
               end)

      assert :ok = ReadonlyProof.compare(source_proof, copy)
      assert source_proof["database_hash"] === copy["database_hash"]
      corrupted = Map.put(source_proof, "database_hash", String.duplicate("0", 64))

      assert {:error, {:restore_proof_mismatch, "database_hash"}} =
               RestoreGuard.activate(target, source_proof["scope"], corrupted)

      assert {:ok, %{readonly: true}} = Backup.metadata(target)
      assert {:ok, activated} = RestoreGuard.activate(target, source_proof["scope"], source_proof)
      assert activated["revoked_pending_intents"] === 1
      assert activated["protected_hash"] === source_proof["protected_hash"]
      assert {:ok, %{readonly: false}} = Backup.metadata(target)

      assert {:error, :restore_target_not_staged} =
               RestoreGuard.activate(target, source_proof["scope"], source_proof)

      {:ok, options} = Backup.connection_options(target)

      {:ok, target_repo} =
        Repo.start_link(
          Keyword.merge(Repo.config(), options)
          |> Keyword.delete(:url)
          |> Keyword.merge(name: nil, pool_size: 2)
        )

      try do
        Process.unlink(target_repo)
        Repo.put_dynamic_repo(target_repo)
        assert {:ok, restored} = ReadonlyProof.capture(source_proof["scope"])
        assert :ok = ReadonlyProof.compare_semantics(source_proof, restored)

        assert {:error, :stale_claim} =
                 Storage.dispatch("pending", 1, {:model_response, {:final, "late"}}, claim: claim)

        assert {:ok, fresh} = IntentStore.claim("pending", "successor", lease_ms: 30_000)
        assert fresh.generation === claim.generation + 2
        assert :ok = IntentStore.release(fresh)
        assert {:ok, env} = Backup.child_env(target)

        code =
          "{:ok, done} = AgentSystemsLab.Recovery.resume(\"pending\"); if done.state.status != :succeeded, do: raise(\"resume failed\")"

        assert {_output, 0} =
                 System.cmd(Path.expand("scripts/mix"), ["run", "--no-compile", "-e", code],
                   env: [{"MIX_ENV", "test"} | env],
                   stderr_to_stdout: true
                 )

        assert {:ok, %{state: %{status: :succeeded}}} = Storage.load("pending")
      after
        Repo.put_dynamic_repo(c.repo)
        GenServer.stop(target_repo)
      end
    after
      assert :ok = Backup.drop(target)
    end
  end

  test "activation preserves the gate when fencing would consume the last claim generation", c do
    assert {:ok, _} = Storage.create_run("edge", "generation bound")
    Repo.query!("UPDATE lab_intents SET claim_generation=2147483646 WHERE run_id='edge'", [])
    scope = %{runs: ["edge"], workflows: [], cases: []}
    assert {:ok, proof} = ReadonlyProof.capture(scope)
    assert {:ok, bundle} = Backup.dump(c.source, Path.join(c.root, "edge-bundle"))
    assert {:ok, target} = Backup.restore(bundle)

    try do
      assert {:error, :fencing_generation_exhausted} = RestoreGuard.activate(target, scope, proof)
      assert {:ok, %{readonly: true}} = Backup.metadata(target)

      assert {:ok, copy} =
               Backup.with_connection(target, &ReadonlyProof.capture_connection(&1, scope))

      assert :ok = ReadonlyProof.compare(proof, copy)
    after
      assert :ok = Backup.drop(target)
    end
  end

  test "future columns and versions fail closed even when a run snapshot is readable" do
    assert {:ok, _} = Storage.create_run("future", "private")
    Repo.query!("ALTER TABLE lab_runs DROP CONSTRAINT lab_runs_codec_version", [])
    Repo.query!("UPDATE lab_runs SET codec_version=99 WHERE id='future'", [])

    assert {:error, {:incompatible_history_column, "lab_runs", "codec_version", 99}} =
             Compatibility.check()

    Repo.query!("UPDATE lab_runs SET codec_version=1 WHERE id='future'", [])
    Repo.query!("ALTER TABLE lab_runs ADD COLUMN future_authority text", [])

    assert {:error, {:unknown_history_columns, "lab_runs", ["future_authority"]}} =
             Compatibility.check()

    Repo.query!("ALTER TABLE lab_runs DROP COLUMN future_authority", [])
    Repo.query!("CREATE TABLE lab_future_protocol(id integer)", [])
    assert {:error, {:unknown_history_tables, ["lab_future_protocol"]}} = Compatibility.check()
    Repo.query!("DROP TABLE lab_future_protocol", [])

    Repo.query!(
      "INSERT INTO schema_migrations(version,inserted_at) VALUES (99999999999999, timezone('UTC',clock_timestamp()))",
      []
    )

    assert {:error, {:unknown_database_migrations, [99_999_999_999_999]}} = Compatibility.check()
    Repo.query!("DELETE FROM schema_migrations WHERE version=99999999999999", [])
    Repo.query!("DELETE FROM schema_migrations WHERE version=20261025000000", [])
    assert {:error, {:missing_database_migrations, [20_261_025_000_000]}} = Compatibility.check()

    Repo.query!(
      "INSERT INTO schema_migrations(version,inserted_at) VALUES (20261025000000, timezone('UTC',clock_timestamp()))",
      []
    )

    Repo.query!("ALTER TABLE lab_runs DROP COLUMN history_format", [])

    assert {:error, {:missing_history_columns, "lab_runs", ["history_format"]}} =
             Compatibility.check()
  end
end
