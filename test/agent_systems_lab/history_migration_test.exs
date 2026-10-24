defmodule AgentSystemsLab.HistoryMigrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias AgentSystemsLab.{
    CheckpointStore,
    ContextStore,
    DurableTools,
    HistoryMigration,
    IntentStore,
    ModelResultStore,
    Recovery,
    Repo,
    Storage
  }

  alias AgentSystemsLab.History.Encoding
  alias AgentSystemsLab.Storage.{Run, Codec}
  alias AgentSystemsLab.Storage.Event, as: StoredEvent
  alias AgentSystemsLab.Storage.HistoryMigration, as: Journal
  @moduletag :database

  setup do
    id =
      "history-migration-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"]) end)
    %{id: id}
  end

  test "read-only planning and migration preserve kernel state and exact legacy payloads", c do
    assert {:ok, initial} = Storage.create_run(c.id, "private original", max_turns: 4)
    before = raw(c.id)
    assert {:ok, plan} = HistoryMigration.plan(c.id)
    assert plan.status == :ready
    assert plan.source_format == 1 and plan.target_format == 2
    assert plan.event_count == 1
    assert raw(c.id) == before
    assert {:ok, migrated} = HistoryMigration.migrate(c.id, initial.state.seq)
    assert migrated == %{plan | status: :migrated}
    assert {:ok, ^initial} = Storage.load(c.id)
    assert Repo.get!(Run, c.id).state_data === before.run.state_data
    assert Repo.get!(Run, c.id).codec_version == 1
    [event] = Repo.all(from(row in StoredEvent, where: row.run_id == ^c.id))
    assert event.history_format == 2
    assert {:ok, hd(before.events).data} == Encoding.unwrap(event.data, 2)
    assert Repo.get!(Journal, c.id).prefix_seq == 1
  end

  test "migrated runs append layout 2 while journal continues to bind the old prefix", c do
    assert {:ok, _} = Storage.create_run(c.id, "continue")
    assert {:ok, _} = HistoryMigration.migrate(c.id, 1)
    assert {:ok, done} = Storage.dispatch(c.id, 1, {:model_response, {:final, "done"}})

    assert Enum.all?(
             Repo.all(from(row in StoredEvent, where: row.run_id == ^c.id)),
             &(&1.history_format == 2)
           )

    assert {:ok, ^done} = Storage.load(c.id)
    before = raw(c.id)
    hook = fn _ -> flunk("idempotent migration must not claim a new COMMIT") end

    assert {:ok, %{status: :already_current, prefix_seq: 1, expected_seq: 2}} =
             HistoryMigration.migrate(c.id, 2, hook: hook)

    assert raw(c.id) == before
    assert {:error, {:stale_sequence, 1, 2}} = HistoryMigration.migrate(c.id, 1)
    assert raw(c.id) == before
  end

  test "stale, nested, live-lease and invalid migration requests do not mutate history", c do
    assert {:ok, _} = Storage.create_run(c.id, "held")
    before = raw(c.id)
    assert {:error, {:stale_sequence, 0, 1}} = HistoryMigration.migrate(c.id, 0)

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> HistoryMigration.migrate(c.id, 1) end)

    assert {:error, :invalid_history_migration_options} =
             HistoryMigration.migrate(c.id, 1, target_format: 99)

    assert raw(c.id) == before
    assert {:ok, claim} = IntentStore.claim(c.id, "old-worker", lease_ms: 5_000)
    held = raw(c.id)
    assert {:error, :intent_claimed} = HistoryMigration.migrate(c.id, 1)
    assert raw(c.id) == held
    assert :ok = IntentStore.release(claim)
    assert {:ok, _} = HistoryMigration.migrate(c.id, 1)
  end

  for stage <- [:before_commit, :after_commit] do
    test "real caller kill at #{stage} is atomic and retry is safe", c do
      stage = unquote(stage)
      assert {:ok, initial} = Storage.create_run(c.id, "crash window")
      before = raw(c.id)
      owner = self()
      ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          hook = fn reached ->
            if reached == stage do
              send(owner, {ref, :boundary})
              receive do: ({^ref, :release} -> :ok)
            end
          end

          result = HistoryMigration.migrate(c.id, 1, hook: hook)
          send(owner, {ref, :ack, result})
        end)

      assert_receive {^ref, :boundary}, 5_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      refute_received {^ref, :ack, _}
      assert {:ok, ^initial} = Storage.load(c.id)

      if before_commit?(stage) do
        assert raw(c.id) == before
        assert {:ok, %{status: :migrated}} = HistoryMigration.migrate(c.id, 1)
      else
        assert Repo.get!(Run, c.id).history_format == 2
        assert Repo.get!(Journal, c.id)
        assert {:ok, %{status: :already_current}} = HistoryMigration.migrate(c.id, 1)
      end

      assert {:ok, ^initial} = Storage.load(c.id)
    end
  end

  test "mixed and malformed layout bytes are rejected without fallback or a journal", c do
    assert {:ok, _} = Storage.create_run(c.id, "mixed")
    Repo.query!("UPDATE lab_events SET history_format=2 WHERE run_id=$1", [c.id])
    assert {:error, {:corrupt_storage, :mixed_history_formats}} = Storage.load(c.id)

    assert {:error, {:corrupt_storage, :mixed_history_formats}} =
             HistoryMigration.migrate(c.id, 1)

    assert Repo.get(Journal, c.id) == nil
    Repo.query!("UPDATE lab_runs SET history_format=2 WHERE id=$1", [c.id])
    assert {:error, {:corrupt_storage, :invalid_history_envelope}} = Storage.load(c.id)
    assert {:error, {:corrupt_storage, :invalid_history_envelope}} = HistoryMigration.plan(c.id)
  end

  test "journal and immutable old prefix corruption fail closed even after valid append", c do
    assert {:ok, _} = Storage.create_run(c.id, "prefix")
    assert {:ok, _} = HistoryMigration.migrate(c.id, 1)
    assert {:ok, _} = Storage.dispatch(c.id, 1, {:model_response, {:final, "done"}})
    journal = Repo.get!(Journal, c.id)

    Repo.query!("UPDATE lab_history_migrations SET target_hash=$2 WHERE run_id=$1", [
      c.id,
      String.duplicate("0", 64)
    ])

    assert {:error, {:corrupt_storage, :history_target_hash_mismatch}} = Storage.load(c.id)

    Repo.query!("UPDATE lab_history_migrations SET target_hash=$2 WHERE run_id=$1", [
      c.id,
      journal.target_hash
    ])

    Repo.query!("UPDATE lab_history_migrations SET semantic_hash=$2 WHERE run_id=$1", [
      c.id,
      String.duplicate("0", 64)
    ])

    assert {:error, {:corrupt_storage, :history_semantic_hash_mismatch}} = Storage.load(c.id)

    Repo.query!("UPDATE lab_history_migrations SET semantic_hash=$2 WHERE run_id=$1", [
      c.id,
      journal.semantic_hash
    ])

    Repo.query!(
      "UPDATE lab_history_migrations SET source_hash=$2 WHERE run_id=$1",
      [c.id, String.duplicate("0", 64)]
    )

    assert {:error, {:corrupt_storage, :history_source_hash_mismatch}} = Storage.load(c.id)

    Repo.query!(
      "UPDATE lab_history_migrations SET source_hash=$2 WHERE run_id=$1",
      [c.id, journal.source_hash]
    )

    Repo.delete!(Repo.get!(Journal, c.id))
    assert {:error, {:corrupt_storage, :missing_history_migration}} = Storage.load(c.id)

    assert {:error, {:corrupt_storage, :missing_history_migration}} =
             HistoryMigration.migrate(c.id, 2)
  end

  test "invalid legacy schema and projection are rejected before any wrapping", c do
    assert {:ok, original} = Storage.create_run(c.id, "legacy corruption")
    assert {:ok, forged} = Codec.encode(%{original.state | input: "forged"})
    Repo.query!("UPDATE lab_runs SET state_data=$2 WHERE id=$1", [c.id, forged])
    before = raw(c.id)
    assert {:error, {:corrupt_storage, :projection_mismatch}} = HistoryMigration.migrate(c.id, 1)
    assert raw(c.id) == before

    assert {:error, {:corrupt_storage, {:unsupported_history_format, 77}}} =
             Repo.transaction(fn ->
               run = %{Repo.get!(Run, c.id) | history_format: 77}

               case Storage.snapshot_in_transaction(Repo, run) do
                 {:error, reason} -> Repo.rollback(reason)
                 value -> value
               end
             end)
  end

  test "future event schemas and codecs are explicitly refused by the migration validation path",
       c do
    assert {:ok, original} = Storage.create_run(c.id, "future history")

    # Simulate an imported newer database inside one rolled-back transaction.
    # The shipped constraints themselves reject these versions on normal writes.
    assert {:error, :future_probe_rolled_back} =
             Repo.transaction(fn ->
               Repo.query!("ALTER TABLE lab_events DROP CONSTRAINT lab_events_schema_version", [])
               Repo.query!("ALTER TABLE lab_events DROP CONSTRAINT lab_events_codec_version", [])
               Repo.query!("UPDATE lab_events SET schema_version=99 WHERE run_id=$1", [c.id])

               assert {:error, {:corrupt_storage, {:unsupported_schema_version, 99}}} =
                        Storage.snapshot_in_transaction(Repo, Repo.get!(Run, c.id))

               assert Repo.get(Journal, c.id) == nil

               Repo.query!(
                 "UPDATE lab_events SET schema_version=1,codec_version=99 WHERE run_id=$1",
                 [c.id]
               )

               assert {:error, {:corrupt_storage, {:unsupported_codec_version, 99}}} =
                        Storage.snapshot_in_transaction(Repo, Repo.get!(Run, c.id))

               assert Repo.get(Journal, c.id) == nil
               Repo.rollback(:future_probe_rolled_back)
             end)

    assert {:ok, ^original} = Storage.load(c.id)
    assert {:ok, %{status: :migrated}} = HistoryMigration.migrate(c.id, 1)
    assert {:ok, ^original} = Storage.load(c.id)
  end

  test "captured context, checkpoints, recordings, budget and one-effect recovery survive migration",
       c do
    call = {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"fact" => "keep"}}}

    assert {:ok, _} =
             Recovery.create_run(c.id, "repair offline",
               script: [call, {:final, "done"}],
               task_budget: [max_dispatches: 16, execution_timeout_ms: 2_000]
             )

    assert {:ok, waiting} = Recovery.step(c.id)
    assert {:ok, checkpoint} = CheckpointStore.create(c.id, waiting.state.seq)
    assert {:ok, captures} = ContextStore.list(c.id)
    assert {:ok, records} = ModelResultStore.list(c.id)
    authority = preserved(c.id)
    assert {:ok, _} = HistoryMigration.migrate(c.id, waiting.state.seq)
    assert preserved(c.id) == authority
    assert {:ok, ^waiting} = Recovery.load(c.id)
    assert {:ok, ^captures} = ContextStore.list(c.id)
    assert {:ok, ^records} = ModelResultStore.list(c.id)
    assert {:ok, ^checkpoint} = CheckpointStore.load(checkpoint.id)
    assert {:ok, completed} = Recovery.resume(c.id)
    assert completed.state.status == :succeeded
    assert %{effects: 1, attempts: 1} = DurableTools.stats(c.id)
    assert {:ok, [first, second]} = ModelResultStore.list(c.id)
    assert first == hd(records)
    assert second.event_seq == 4
    assert {:ok, rebuilt} = CheckpointStore.rebuild(c.id)
    assert rebuilt.state === completed.state

    assert Enum.all?(
             Repo.all(from(row in StoredEvent, where: row.run_id == ^c.id)),
             &(&1.history_format == 2)
           )
  end

  test "competing migration callers serialize and produce exactly one journal", c do
    assert {:ok, initial} = Storage.create_run(c.id, "compete")

    results =
      1..8
      |> Task.async_stream(fn _ -> HistoryMigration.migrate(c.id, 1) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result.status end)

    assert Enum.count(results, &(&1 == :migrated)) == 1
    assert Enum.count(results, &(&1 == :already_current)) == 7
    assert Repo.aggregate(from(row in Journal, where: row.run_id == ^c.id), :count) == 1
    assert {:ok, ^initial} = Storage.load(c.id)
  end

  test "event and byte ceilings are checked before loading hostile legacy payloads", c do
    assert {:ok, _} = Storage.create_run(c.id, "bounded")

    Repo.query!(
      """
      INSERT INTO lab_events (run_id,seq,type,schema_version,data,codec_version,history_format,inserted_at)
      SELECT $1, n, 'run_started', 1, (SELECT data FROM lab_events WHERE run_id=$1 AND seq=1), 1, 1, clock_timestamp()
      FROM generate_series(2,4097) n
      """,
      [c.id]
    )

    assert {:error, :history_migration_event_limit} = HistoryMigration.plan(c.id)
    assert {:error, :history_migration_event_limit} = HistoryMigration.migrate(c.id, 1)
    assert Repo.get(Journal, c.id) == nil
    Repo.query!("DELETE FROM lab_events WHERE run_id=$1 AND seq>1", [c.id])
    Repo.query!("UPDATE lab_events SET data=repeat('x',33554433)::bytea WHERE run_id=$1", [c.id])
    assert {:error, :history_migration_byte_limit} = HistoryMigration.plan(c.id)
    assert {:error, :history_migration_byte_limit} = HistoryMigration.migrate(c.id, 1)
    assert Repo.get(Journal, c.id) == nil
    assert Repo.get!(Run, c.id).history_format == 1
  end

  defp raw(id) do
    %{
      run: Repo.get!(Run, id),
      events: Repo.all(from(row in StoredEvent, where: row.run_id == ^id, order_by: row.seq)),
      journal: Repo.get(Journal, id)
    }
  end

  defp preserved(id) do
    for table <- [
          "lab_intents",
          "lab_recovery",
          "lab_task_budgets",
          "lab_contexts",
          "lab_checkpoints",
          "lab_model_results"
        ],
        into: %{} do
      {table,
       Repo.query!(
         "SELECT to_jsonb(t)::text FROM #{table} t WHERE run_id=$1 ORDER BY to_jsonb(t)::text",
         [id]
       ).rows}
    end
  end

  defp before_commit?(stage), do: stage == :before_commit
end
