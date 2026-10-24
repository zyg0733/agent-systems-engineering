defmodule AgentSystemsLab.RecoveryStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Context, IntentStore, Recovery, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Storage.Codec

  @moduletag :database

  setup do
    id =
      "recovery-store-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id]) end)
    {:ok, id: id}
  end

  test "enrollment commits fixed config and zero cursor with the first event", %{id: id} do
    assert {:ok, created} = create(id)
    assert created.state.seq == 1
    assert created.recovery.config.script == [{:final, "done"}]
    assert created.recovery.config.provider == "scripted.v1"
    assert created.recovery.progress.cursor == 0
    assert created.recovery.progress.last_seq == 1
    assert created.recovery.progress.output_bytes == 0
    assert created.recovery.progress.model_attempts == 0
    assert created.recovery.progress.request_token == nil
    assert created.recovery.progress.deadline_at_ms > RecoveryStore.now_ms()
    assert counts(id) == [1, 1, 1, 1]
    assert {:ok, ^created} = Recovery.load(id)
  end

  test "enrollment precommit failure rolls back the entire run", %{id: id} do
    assert_raise RuntimeError, "enroll rollback", fn ->
      create(id,
        hook: fn
          :before_commit -> raise "enroll rollback"
          :after_commit -> :ok
        end
      )
    end

    assert counts(id) == [0, 0, 0, 0]
    assert {:error, :not_found} = Recovery.load(id)
  end

  test "enrollment aftercommit failure preserves policy and deadline", %{id: id} do
    assert_raise RuntimeError, "enroll committed", fn ->
      create(id,
        hook: fn
          :before_commit -> :ok
          :after_commit -> raise "enroll committed"
        end
      )
    end

    assert counts(id) == [1, 1, 1, 1]
    assert {:ok, recovered} = Recovery.load(id)
    assert recovered.recovery.config.script == [{:final, "done"}]
    assert recovered.recovery.progress.cursor == 0
    assert {:ok, again} = Recovery.load(id)
    assert recovered.recovery.progress == again.recovery.progress
  end

  test "legacy runs cannot acquire guessed recovery metadata", %{id: id} do
    assert {:ok, original} = Storage.create_run(id, "legacy")
    assert {:error, :run_not_resumable} = Recovery.load(id)
    assert {:error, :run_not_resumable} = Recovery.resume(id)
    assert {:error, :run_not_resumable} = Recovery.cancel(id)
    assert {:ok, ^original} = Storage.load(id)
    assert counts(id) == [1, 1, 1, 0]
  end

  test "continuation refuses changed policy options", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:error, :invalid_recovery_options} = Recovery.resume(id, script: [{:final, "other"}])
    assert {:error, :invalid_recovery_options} = Recovery.step(id, max_output_bytes: 1_000_000)
    assert {:error, :invalid_recovery_options} = Recovery.step(id, workspace: "/tmp")
    assert {:ok, ^original} = Recovery.load(id)
  end

  test "config payload tampering fails its immutable hash", %{id: id} do
    assert {:ok, original} = create(id)
    config = %{original.recovery.config | script: [{:final, "forged"}]}
    update_encoded(id, "config_data", config)
    assert {:error, {:corrupt_recovery, :recovery_config_hash_mismatch}} = Recovery.load(id)
    assert {:error, {:corrupt_recovery, :recovery_config_hash_mismatch}} = Recovery.resume(id)
    assert {:ok, persisted} = Storage.load(id)
    assert persisted.state == original.state
  end

  test "future config versions fail even with a matching payload hash", %{id: id} do
    assert {:ok, original} = create(id)

    for version <- [2, 1.0, nil, false] do
      config = %{original.recovery.config | schema_version: version}
      update_encoded(id, "config_data", config)

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE lab_recovery SET config_sha256 = $2 WHERE run_id = $1",
        [id, Context.hash(config)]
      )

      assert {:error, {:corrupt_recovery, {:unsupported_recovery_config_version, ^version}}} =
               Recovery.load(id)
    end
  end

  test "progress tampering rejects sequence cursor accounting and shape mismatches", %{id: id} do
    assert {:ok, original} = create(id)
    p = original.recovery.progress

    for {progress, reason} <- [
          {%{p | last_seq: 2}, :recovery_progress_mismatch},
          {%{p | cursor: 1}, :recovery_progress_mismatch},
          {%{p | model_attempts: -1}, :invalid_model_attempt_count},
          {%{p | model_attempts: 100}, :invalid_model_attempt_count},
          {%{p | output_bytes: -1}, :invalid_output_charge},
          {%{p | output_bytes: 100_000_000}, :invalid_output_charge},
          {%{p | request_events: -1}, :invalid_event_charge},
          {%{p | deadline_at_ms: 0}, :invalid_recovery_deadline},
          {%{p | request_token: Ecto.UUID.generate()}, :invalid_model_attempt},
          {Map.put(p, :extra, true), :invalid_recovery_progress}
        ] do
      update_encoded(id, "progress_data", progress)
      assert {:error, {:corrupt_recovery, ^reason}} = Recovery.load(id)
    end
  end

  test "future progress versions fail independently of row codec", %{id: id} do
    assert {:ok, original} = create(id)

    for version <- [2, 1.0, nil, false] do
      update_encoded(id, "progress_data", %{original.recovery.progress | schema_version: version})

      assert {:error, {:corrupt_recovery, {:unsupported_recovery_progress_version, ^version}}} =
               Recovery.load(id)
    end
  end

  test "manual model commands cannot advance enrolled cursor without a reserved attempt", %{
    id: id
  } do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "manual")
    response = {:model_response, {:final, "forged"}}
    assert {:error, :recovery_progress_required} = Storage.dispatch(id, 1, response, claim: claim)

    assert {:error, :model_attempt_required} =
             Storage.dispatch(id, 1, response, claim: claim, recovery_progress: %{cursor: 1})

    assert {:ok, loaded} = Recovery.load(id)
    assert loaded.state == original.state
    assert loaded.recovery.progress == original.recovery.progress
    assert counts(id) == [1, 1, 1, 1]
  end

  test "a reserved attempt cannot bypass accepted model result recording", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "manual")
    assert {:ok, _attempt} = RecoveryStore.begin_model_attempt(claim)

    assert {:error, _reason} =
             Storage.dispatch(id, 1, {:model_response, {:final, "forged"}},
               claim: claim,
               recovery_progress: %{cursor: 1}
             )

    assert {:ok, loaded} = Recovery.load(id)
    assert loaded.state == original.state
    assert loaded.recovery.progress.cursor == 0
    assert counts(id) == [1, 1, 1, 1]
  end

  test "frames require an active nonnil request token", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "manual")

    assert {:error, :stale_model_attempt} =
             RecoveryStore.charge_frame(claim, nil, {:text_delta, "unreserved"})

    assert {:ok, loaded} = Recovery.load(id)
    assert loaded.recovery.progress == original.recovery.progress
  end

  test "accounting and absolute deadline survive release and a replacement attempt", %{id: id} do
    assert {:ok, original} = create(id, max_model_attempts: 2)
    assert {:ok, first} = IntentStore.claim(id, "first")
    assert {:ok, a} = RecoveryStore.begin_model_attempt(first)

    assert {:ok, charged} =
             RecoveryStore.charge_frame(first, a.progress.request_token, {:text_delta, "spent"})

    assert charged.output_bytes == 5
    assert charged.request_events == 1
    assert charged.model_attempts == 1
    assert :ok = IntentStore.release(first)
    assert {:ok, second} = IntentStore.claim(id, "second")
    assert {:ok, b} = RecoveryStore.begin_model_attempt(second)
    assert b.progress.model_attempts == 2
    assert b.progress.output_bytes == 5
    assert b.progress.request_events == 0
    assert b.progress.cursor == 0
    assert b.progress.deadline_at_ms == original.recovery.progress.deadline_at_ms
    refute b.progress.request_token == a.progress.request_token

    assert {:error, :stale_model_attempt} =
             RecoveryStore.charge_frame(second, a.progress.request_token, :done)

    assert {:error, {:budget_exceeded, :model_attempts}} =
             RecoveryStore.begin_model_attempt(second)

    assert {:ok, saved} = Recovery.load(id)
    assert saved.recovery.progress == b.progress
  end

  test "overbudget frames cannot erase prior charges or advance the cursor", %{id: id} do
    assert {:ok, _} = create(id, max_output_bytes: 5)
    assert {:ok, claim} = IntentStore.claim(id, "bounded")
    assert {:ok, attempt} = RecoveryStore.begin_model_attempt(claim)

    assert {:ok, charged} =
             RecoveryStore.charge_frame(
               claim,
               attempt.progress.request_token,
               {:text_delta, "abc"}
             )

    assert {:error, {:budget_exceeded, :output_bytes}} =
             RecoveryStore.charge_frame(
               claim,
               attempt.progress.request_token,
               {:text_delta, "def"}
             )

    assert {:ok, loaded} = Recovery.load(id)
    assert loaded.recovery.progress == charged
    assert loaded.state.turn_count == 0
  end

  test "forged claim cannot reserve or charge a model attempt", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "real")
    forged = %{claim | token: Ecto.UUID.generate()}
    assert {:error, :stale_claim} = RecoveryStore.begin_model_attempt(forged)

    assert {:error, :stale_claim} =
             RecoveryStore.charge_frame(forged, Ecto.UUID.generate(), :done)

    assert {:ok, saved} = Recovery.load(id)
    assert saved.recovery.progress == original.recovery.progress
  end

  test "model accounting refuses outer transactions", %{id: id} do
    assert {:ok, _} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "worker")

    assert {:ok,
            {{:error, :nested_transaction_not_supported},
             {:error, :nested_transaction_not_supported}}} =
             Repo.transaction(fn ->
               {RecoveryStore.begin_model_attempt(claim),
                RecoveryStore.charge_frame(claim, nil, :done)}
             end)
  end

  test "internal progress updates refuse detached writes", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "worker")
    assert {:ok, attempt} = RecoveryStore.begin_model_attempt(claim)

    assert {:error, :transaction_required} =
             RecoveryStore.update_in_transaction(Repo, original.state, original.state, nil)

    assert {:ok, saved} = Recovery.load(id)
    assert saved.recovery.progress == attempt.progress
  end

  test "operator cancellation advances recovery sequence and revokes live work", %{id: id} do
    assert {:ok, original} = create(id)
    assert {:ok, claim} = IntentStore.claim(id, "worker")
    assert {:ok, _attempt} = RecoveryStore.begin_model_attempt(claim)
    assert {:ok, cancelled} = Recovery.cancel(id, :operator)
    assert cancelled.state.status == :cancelled
    assert cancelled.recovery.progress.last_seq == 2
    assert cancelled.recovery.progress.cursor == 0
    assert cancelled.recovery.progress.model_attempts == 1
    assert cancelled.recovery.progress.deadline_at_ms == original.recovery.progress.deadline_at_ms
    assert cancelled.recovery.progress.request_token == nil
    assert cancelled.intent == nil
    assert {:error, :stale_claim} = IntentStore.release(claim)
  end

  defp create(id, opts \\ []),
    do:
      Recovery.create_run(
        id,
        "Resume the fixed policy",
        Keyword.put_new(opts, :script, [{:final, "done"}])
      )

  defp update_encoded(id, column, value) when column in ["config_data", "progress_data"] do
    {:ok, data} = Codec.encode(value)

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_recovery SET #{column} = $2 WHERE run_id = $1", [
      id,
      data
    ])
  end

  defp counts(id) do
    %{rows: [row]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT (SELECT count(*) FROM lab_runs WHERE id = $1),
               (SELECT count(*) FROM lab_events WHERE run_id = $1),
               (SELECT count(*) FROM lab_intents WHERE run_id = $1),
               (SELECT count(*) FROM lab_recovery WHERE run_id = $1)
        """,
        [id]
      )

    row
  end
end
