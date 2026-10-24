defmodule AgentSystemsLab.CheckpointStoreTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AgentSystemsLab.{Checkpoint, CheckpointStore, Repo, Storage}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Storage.Checkpoint, as: Row
  @moduletag :database

  setup do
    id = "checkpoint-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"
    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id]) end)
    {:ok, id: id}
  end

  test "immutable checkpoints reconstruct committed prefix and tail", %{id: id} do
    assert {:ok, original} = Storage.create_run(id, "task", max_turns: 9)
    assert {:ok, cp} = CheckpointStore.create(id, 1)
    assert cp.checkpoint.state === original.state
    assert {:ok, ^cp} = CheckpointStore.load(cp.id)
    assert {:ok, ^cp} = CheckpointStore.latest(id)
    assert {:ok, final} = Storage.dispatch(id, 1, {:model_response, {:final, "done"}})
    assert {:ok, replayed} = CheckpointStore.rebuild(id)
    assert Map.drop(replayed, [:audit]) === final

    assert replayed.audit === %{
             mode: :checkpoint,
             checkpoint_id: cp.id,
             checkpoint_seq: 1,
             verified_prefix_events: 1,
             replayed_tail_events: 1
           }

    assert {:ok, full} = CheckpointStore.rebuild(id, mode: :full)
    assert Map.drop(full, [:audit]) === final
    assert full.audit.mode === :full
    assert full.audit.verified_prefix_events === 2
    assert {:ok, terminal} = CheckpointStore.create(id, 2)
    assert terminal.id != cp.id
    assert {:ok, ^terminal} = CheckpointStore.latest(id)
    assert {:ok, ^cp} = CheckpointStore.load(cp.id)
  end

  test "no checkpoint uses an explicit full history path", %{id: id} do
    assert {:ok, original} = Storage.create_run(id, "task")
    assert {:ok, nil} = CheckpointStore.latest(id)
    assert {:ok, rebuilt} = CheckpointStore.rebuild(id, mode: :checkpoint)
    assert Map.drop(rebuilt, [:audit]) === original
    assert rebuilt.audit.mode === :full
    assert rebuilt.audit.checkpoint_id === nil
  end

  test "duplicates stale sequences invalid options and nested writes do not add rows", %{id: id} do
    assert {:ok, _original} = Storage.create_run(id, "task")
    assert {:ok, cp} = CheckpointStore.create(id, 1)
    assert {:error, {:checkpoint_already_exists, ^id, 1}} = CheckpointStore.create(id, 1)
    assert {:error, {:stale_sequence, 0, 1}} = CheckpointStore.create(id, 0)
    assert {:error, {:stale_sequence, 2, 1}} = CheckpointStore.create(id, 2)

    for seq <- [-1, 1.0, nil] do
      assert {:error, {:invalid_expected_sequence, ^seq}} = CheckpointStore.create(id, seq)
    end

    assert {:error, {:invalid_checkpoint_options, _}} = CheckpointStore.create(id, 1, unknown: 1)

    assert {:error, {:invalid_checkpoint_options, _}} =
             CheckpointStore.rebuild(id, mode: :full, mode: :checkpoint)

    assert {:error, {:invalid_rebuild_mode, :unsafe}} = CheckpointStore.rebuild(id, mode: :unsafe)

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> CheckpointStore.create(id, 1) end)

    assert count(id) == 1
    assert {:ok, ^cp} = CheckpointStore.load(cp.id)
  end

  test "latest corruption fails closed and does not fall back to a valid older checkpoint", %{
    id: id
  } do
    assert {:ok, _original} = Storage.create_run(id, "task")
    assert {:ok, older} = CheckpointStore.create(id, 1)
    assert {:ok, _finished} = Storage.dispatch(id, 1, {:model_response, {:final, "done"}})
    assert {:ok, newest} = CheckpointStore.create(id, 2)
    mutate(newest, %{newest.checkpoint | state_sha256: String.duplicate("0", 64)})
    assert {:ok, ^older} = CheckpointStore.load(older.id)

    assert {:error, {:corrupt_checkpoint, :checkpoint_state_mismatch}} =
             CheckpointStore.latest(id)

    assert {:error, {:corrupt_checkpoint, :checkpoint_state_mismatch}} =
             CheckpointStore.rebuild(id)

    assert {:ok, %{state: %{status: :succeeded}}} = CheckpointStore.rebuild(id, mode: :full)
  end

  test "checkpoint schema envelope metadata and journal prefix are all verified", %{id: id} do
    assert {:ok, original} = Storage.create_run(id, "task")
    assert {:ok, cp} = CheckpointStore.create(id, 1)

    for version <- [2, 1.0, nil] do
      mutate(cp, %{cp.checkpoint | schema_version: version})

      assert {:error, {:corrupt_checkpoint, {:unsupported_checkpoint_schema_version, ^version}}} =
               CheckpointStore.load(cp.id)
    end

    mutate(cp, %{cp.checkpoint | run_id: "other"})
    assert {:error, {:corrupt_checkpoint, _}} = CheckpointStore.load(cp.id)
    mutate(cp, cp.checkpoint)
    assert {:ok, ^cp} = CheckpointStore.load(cp.id)
    {:ok, data} = Codec.encode(%{input: "corrupt", extra: true})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_events SET data = $2 WHERE run_id = $1 AND seq = 1",
      [id, data]
    )

    assert {:error, {:corrupt_storage, {:invalid_event_data, :run_started}}} =
             CheckpointStore.rebuild(id)

    assert original.state.seq == 1
  end

  test "a self consistent forged checkpoint cannot replace the authoritative journal", %{id: id} do
    assert {:ok, _original} = Storage.create_run(id, "task")
    assert {:ok, _finished} = Storage.dispatch(id, 1, {:model_response, {:final, "done"}})
    assert {:ok, cp} = CheckpointStore.create(id, 2)
    state = %{cp.checkpoint.state | output: "forged"}
    {:ok, hash} = Checkpoint.digest(state)
    forged = %{cp.checkpoint | state: state, state_sha256: hash}
    assert :ok = Checkpoint.validate(forged)
    mutate(cp, forged)

    assert {:error, {:corrupt_checkpoint, :checkpoint_history_mismatch}} =
             CheckpointStore.load(cp.id)
  end

  test "a future checkpoint sequence cannot bypass the current journal", %{id: id} do
    assert {:ok, _original} = Storage.create_run(id, "task")
    assert {:ok, cp} = CheckpointStore.create(id, 1)

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_checkpoints SET last_seq = 8 WHERE run_id = $1", [
      id
    ])

    assert {:error, {:corrupt_checkpoint, :metadata_mismatch}} = CheckpointStore.load(cp.id)
  end

  for stage <- [:before_commit, :after_commit] do
    test "killing checkpoint caller #{stage} preserves the commit boundary", %{id: id} do
      assert {:ok, original} = Storage.create_run(id, "task")
      owner = self()
      barrier = make_ref()
      stage = unquote(stage)

      hook = fn current ->
        if current == stage do
          send(owner, {barrier, :at_barrier, self()})

          receive do
            {^barrier, :release} -> :ok
          end
        end
      end

      {pid, monitor} =
        spawn_monitor(fn ->
          result = CheckpointStore.create(id, 1, hook: hook)
          send(owner, {barrier, :ack, result})
        end)

      assert_receive {^barrier, :at_barrier, ^pid}, 5_000
      expected = unquote(if stage == :after_commit, do: 1, else: 0)
      assert count(id) === expected
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      refute_receive {^barrier, :ack, _result}, 20
      assert count(id) === expected
      assert {:ok, ^original} = Storage.load(id)
      assert {:ok, rebuilt} = CheckpointStore.rebuild(id)
      assert rebuilt.state === original.state
    end
  end

  test "missing records and run deletion are explicit", %{id: id} do
    assert {:error, :invalid_checkpoint_id} = CheckpointStore.load("bad")
    assert {:error, :checkpoint_not_found} = CheckpointStore.load(Ecto.UUID.generate())
    assert {:error, :not_found} = CheckpointStore.latest(id)
    assert {:error, :not_found} = CheckpointStore.create(id, 1)
    assert {:ok, _original} = Storage.create_run(id, "task")
    assert {:ok, _cp} = CheckpointStore.create(id, 1)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id])
    assert count(id) === 0
  end

  defp mutate(captured, checkpoint) do
    {:ok, data} = Codec.encode(checkpoint)
    Repo.update_all(from(c in Row, where: c.id == ^captured.id), set: [data: data])
  end

  defp count(id), do: Repo.aggregate(from(c in Row, where: c.run_id == ^id), :count)
end
