defmodule AgentSystemsLab.IntentStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{IntentStore, Repo, Storage}

  @moduletag :database

  setup do
    id = "intent-test-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id]) end)
    assert {:ok, snapshot} = Storage.create_run(id, "Claim durable work")
    {:ok, id: id, snapshot: snapshot}
  end

  test "claim preserves business intent and is acknowledged after commit", %{id: id} do
    parent = self()

    assert {:ok, claim} =
             IntentStore.claim(id, "worker-a",
               hook: fn stage -> send(parent, {stage, stored_claim(id)}) end
             )

    assert_receive {:before_commit, [token, "worker-a", 1]}
    assert token == claim.token
    assert_receive {:after_commit, [^token, "worker-a", 1]}
    assert claim.run_id == id
    assert claim.seq == 1
    assert claim.owner == "worker-a"
    assert claim.generation == 1
    assert %DateTime{} = claim.expires_at
    assert {:ok, loaded} = Storage.load(id)
    assert loaded.state.seq == 1
    assert loaded.intent.status == "pending"
    assert loaded.intent.claim_token == token
    assert {:error, :intent_claimed} = IntentStore.claim(id, "worker-b")
  end

  test "live claim fences ordinary commits and nil cannot bypass it", %{id: id} do
    assert {:ok, claim} = IntentStore.claim(id, "worker-a")
    command = {:model_response, {:final, "Done"}}
    assert {:error, :intent_claimed} = Storage.dispatch(id, 1, command)
    assert {:error, :invalid_claim} = Storage.dispatch(id, 1, command, claim: nil)

    assert {:error, :stale_claim} =
             Storage.dispatch(id, 1, command, claim: %{claim | owner: "other"})

    assert {:ok, complete} = Storage.dispatch(id, 1, command, claim: claim)
    assert complete.state.status == :succeeded
    assert complete.intent == nil
    assert {:error, :stale_claim} = IntentStore.release(claim)
    assert {:error, :no_pending_intent} = IntentStore.claim(id, "worker-b")
  end

  test "expired tokens never renew, release, or commit, and a replacement increments generation",
       %{id: id} do
    assert {:ok, old} = IntentStore.claim(id, "worker-a")
    expire(id)
    assert {:error, :claim_expired} = IntentStore.renew(old)
    assert {:error, :claim_expired} = IntentStore.release(old)

    assert {:error, :claim_expired} =
             Storage.dispatch(id, 1, {:model_response, {:final, "Old"}}, claim: old)

    assert {:ok, replacement} = IntentStore.claim(id, "worker-b")
    assert replacement.generation == old.generation + 1
    refute replacement.token == old.token
    assert {:error, :stale_claim} = IntentStore.release(old)
    assert {:error, :stale_claim} = IntentStore.renew(old)

    assert {:error, :stale_claim} =
             Storage.dispatch(id, 1, {:model_response, {:final, "Old"}}, claim: old)

    assert stored_claim(id) == [replacement.token, "worker-b", 2]
  end

  test "renew keeps fencing identity and release allows another owner", %{id: id} do
    assert {:ok, original} = IntentStore.claim(id, "worker-a", lease_ms: 10_000)
    assert {:ok, renewed} = IntentStore.renew(original, lease_ms: 60_000)
    assert Map.drop(renewed, [:expires_at]) == Map.drop(original, [:expires_at])
    assert DateTime.compare(renewed.expires_at, original.expires_at) == :gt
    assert :ok = IntentStore.release(renewed)
    assert stored_claim(id) == [nil, nil, 1]
    assert {:error, :stale_claim} = IntentStore.release(renewed)
    assert {:ok, next} = IntentStore.claim(id, "worker-b")
    assert next.generation == 2
  end

  test "expiry only changes claim eligibility and never advances the run", %{
    id: id,
    snapshot: original
  } do
    assert {:ok, _claim} = IntentStore.claim(id, "worker-a")
    expire(id)
    assert {:ok, loaded} = Storage.load(id)
    assert loaded.state == original.state
    assert loaded.events == original.events
    assert loaded.intent.status == "pending"
    # Compatibility for callers outside durable recovery: no live claim exists.
    assert {:ok, complete} = Storage.dispatch(id, 1, {:model_response, {:final, "Done"}})
    assert complete.state.status == :succeeded
  end

  for kind <- [:cancel, :fail] do
    test "operator #{kind} supersedes and revokes a live claim", %{id: id} do
      assert {:ok, claim} = IntentStore.claim(id, "worker-a")
      assert {:ok, snapshot} = Storage.dispatch(id, 1, {unquote(kind), :operator})
      assert snapshot.intent == nil
      assert {:error, :stale_claim} = IntentStore.release(claim)

      assert %{rows: [["superseded", nil, nil, nil]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT status, claim_token, claim_owner, claim_expires_at FROM lab_intents WHERE run_id = $1",
                 [id]
               )
    end
  end

  test "stale sequence is rejected without touching the current claim", %{id: id} do
    assert {:ok, claim} = IntentStore.claim(id, "worker-a")

    assert {:error, {:stale_sequence, 0, 1}} =
             Storage.dispatch(id, 0, {:cancel, :stale}, claim: claim)

    assert stored_claim(id) == [claim.token, claim.owner, claim.generation]
  end

  test "concurrent claimants acquire one lease", %{id: id} do
    parent = self()
    gate = make_ref()

    workers =
      for owner <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {gate, :ready, self()})

          receive do
            {^gate, :go} -> IntentStore.claim(id, owner)
          end
        end)
      end

    for _ <- workers, do: assert_receive({^gate, :ready, _}, 1_000)
    Enum.each(workers, &send(&1.pid, {gate, :go}))
    results = Enum.map(workers, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :intent_claimed})) == 1
    [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert stored_claim(id) == [winner.token, winner.owner, winner.generation]
  end

  test "a precommit exception rolls back claim identity and generation", %{id: id} do
    assert_raise RuntimeError, "claim rollback", fn ->
      IntentStore.claim(id, "doomed",
        hook: fn
          :before_commit -> raise "claim rollback"
          :after_commit -> :ok
        end
      )
    end

    assert stored_claim(id) == [nil, nil, 0]
    assert {:ok, %{generation: 1}} = IntentStore.claim(id, "replacement")
  end

  test "claim operations reject invalid values and outer write transactions", %{id: id} do
    assert {:error, :invalid_claim_owner} = IntentStore.claim(id, "")
    assert {:error, :invalid_claim_options} = IntentStore.claim(id, "worker", lease_ms: 0)

    assert {:error, :invalid_claim_options} =
             IntentStore.claim(id, "worker", lease_ms: 2, lease_ms: 3)

    assert {:error, :invalid_claim_options} = IntentStore.claim(id, "worker", unexpected: true)
    assert {:error, :invalid_claim} = IntentStore.renew(nil)
    assert {:error, :invalid_claim} = IntentStore.release(%{})
    assert {:error, :not_found} = IntentStore.claim(id <> "-missing", "worker")
    assert {:ok, claim} = IntentStore.claim(id, "worker")

    assert {:ok, results} =
             Repo.transaction(fn ->
               {IntentStore.claim(id, "nested"), IntentStore.renew(claim),
                IntentStore.release(claim)}
             end)

    assert results ==
             {{:error, :nested_transaction_not_supported},
              {:error, :nested_transaction_not_supported},
              {:error, :nested_transaction_not_supported}}

    assert {:error, :transaction_required} = IntentStore.verify(Repo, id, 1, claim)
  end

  for stage <- [:before_commit, :after_commit] do
    test "killing a claimant #{stage} observes the real commit boundary", %{id: id} do
      assert_claim_crash(id, unquote(stage))
    end
  end

  defp assert_claim_crash(id, stage) do
    parent = self()
    barrier = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          IntentStore.claim(id, "doomed",
            hook: fn current ->
              if current == stage do
                send(parent, {barrier, :at_commit, self()})

                receive do
                  {^barrier, :continue} -> :ok
                end
              end
            end
          )

        send(parent, {barrier, :acknowledged, result})
      end)

    assert_receive {^barrier, :at_commit, ^pid}, 5_000
    visible = stored_claim(id)
    assert hd(visible) != nil == (stage == :after_commit)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_receive {^barrier, :acknowledged, _}, 20
    assert stored_claim(id) == visible

    if stage == :before_commit do
      assert {:ok, _claim} = IntentStore.claim(id, "recovered")
    else
      assert {:error, :intent_claimed} = IntentStore.claim(id, "recovered")
      expire(id)
      assert {:ok, %{generation: 2}} = IntentStore.claim(id, "recovered")
    end
  end

  defp stored_claim(id) do
    %{rows: [row]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT claim_token::text, claim_owner, claim_generation FROM lab_intents WHERE run_id = $1 AND status = 'pending'",
        [id]
      )

    row
  end

  defp expire(id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_intents SET claim_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE run_id = $1 AND status = 'pending'",
      [id]
    )
  end
end
