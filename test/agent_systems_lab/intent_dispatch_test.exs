defmodule AgentSystemsLab.IntentDispatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias AgentSystemsLab.{ErrorPolicy, IntentStore, Recovery, Repo, RetryStore, Storage}

  @moduletag :database

  setup do
    prefix = "dispatch-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [prefix <> "%"]) end)
    %{prefix: prefix}
  end

  test "parallel pollers claim each pending intent once", c do
    ids = for n <- 1..6, do: create(c, "-#{n}")
    parent = self()
    gate = make_ref()

    tasks =
      for n <- 1..12 do
        Task.async(fn ->
          send(parent, {gate, :ready})
          receive do: ({^gate, :go} -> IntentStore.claim_next("worker-#{n}", run_ids: ids))
        end)
      end

    for _ <- tasks, do: assert_receive({^gate, :ready}, 2_000)
    Enum.each(tasks, &send(&1.pid, {gate, :go}))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    claims = for {:ok, claim} <- results, not is_nil(claim), do: claim
    assert Enum.sort(Enum.map(claims, & &1.run_id)) == Enum.sort(ids)
    assert length(Enum.uniq_by(claims, & &1.token)) == 6
    assert Enum.all?(claims, &(&1.generation == 1))
    assert Enum.count(results, &(&1 == {:ok, nil})) == 6
  end

  test "SKIP LOCKED skips a busy Run without waiting for its transaction", c do
    first = create(c, "-busy", priority: 9)
    second = create(c, "-free")
    parent = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM lab_runs WHERE id = $1 FOR UPDATE", [first])
          send(parent, {:locked, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:locked, pid}
    claim = Task.async(fn -> IntentStore.claim_next("free", run_ids: [first, second]) end)
    assert {:ok, %{run_id: ^second}} = Task.await(claim, 1_000)
    assert token(first) == [nil, 0]
    send(pid, :release)
    assert {:ok, :ok} = Task.await(task)
    assert {:ok, %{run_id: ^first}} = IntentStore.claim_next("later", run_ids: [first, second])
  end

  test "priority wins, equal priority uses oldest intent, and a live lease is never preempted",
       c do
    oldest = create(c, "-oldest", priority: 5)
    highest = create(c, "-highest", priority: 9)
    newer = create(c, "-newer", priority: 5)
    ids = [oldest, highest, newer]
    assert {:ok, high_claim = %{run_id: ^highest}} = IntentStore.claim_next("high", run_ids: ids)
    assert {:ok, %{run_id: ^oldest}} = IntentStore.claim_next("older", run_ids: ids)
    assert {:ok, %{run_id: ^newer}} = IntentStore.claim_next("newer", run_ids: ids)
    assert {:ok, nil} = IntentStore.claim_next("cannot-preempt", run_ids: ids)
    assert token(highest) == [high_claim.token, 1]
  end

  test "real lease expiry permits redelivery with a new fencing token", c do
    id = create(c, "-expired")
    assert {:ok, old} = IntentStore.claim_next("lost-worker", run_ids: [id], lease_ms: 50)
    assert {:ok, nil} = IntentStore.claim_next("too-early", run_ids: [id])
    wait_due(DateTime.to_unix(old.expires_at, :millisecond) + 1)
    assert {:ok, replacement} = IntentStore.claim_next("replacement", run_ids: [id])
    assert replacement.generation == 2
    refute replacement.token == old.token
    assert {:error, :stale_claim} = IntentStore.release(old)
    assert {:error, :stale_claim} = IntentStore.renew(old)
    assert {:error, :stale_claim} = Storage.dispatch(id, 1, {:cancel, :old_worker}, claim: old)
    assert token(id) == [replacement.token, 2]
  end

  test "authoritative future retries remain unclaimed, including pre-migration NULL hints", c do
    waiting = create(c, "-waiting", retry_policy: retry_policy(400))
    due = schedule(waiting)
    assert DateTime.to_unix(hint(waiting), :millisecond) == due
    assert {:ok, nil} = IntentStore.claim_next("early", run_ids: [waiting])
    assert token(waiting) == [nil, 1]
    Repo.query!("UPDATE lab_intents SET available_at = NULL WHERE run_id = $1", [waiting])
    assert {:ok, nil} = IntentStore.claim_next("legacy-hint", run_ids: [waiting])
    assert token(waiting) == [nil, 1]
    assert {:ok, retry} = RetryStore.load(waiting, 1, :model)
    assert retry.attempts == 1
    assert retry.next_attempt_at_ms == due
  end

  test "a real due retry is claimable and advances no attempt until execution reserves it", c do
    id = create(c, "-due", retry_policy: retry_policy(70))
    due = schedule(id)
    wait_due(due)
    assert {:ok, claim} = IntentStore.claim_next("due", run_ids: [id])
    assert claim.generation == 2
    assert {:ok, before} = RetryStore.load(id, 1, :model)
    assert before.attempts == 1
    assert {:ok, next} = RetryStore.reserve(claim, before.policy, :model)
    assert next.attempts == 2
    assert hint(id) == nil
  end

  test "future hints cannot hide ready high priority work and early hints cannot run future retries",
       c do
    waiting = create(c, "-future", priority: 9, retry_policy: retry_policy(800))
    schedule(waiting)
    ready = create(c, "-ready", priority: 8)
    low = create(c, "-low", priority: 0)

    Repo.query!(
      "UPDATE lab_intents SET available_at = clock_timestamp() - interval '1 hour' WHERE run_id = $1",
      [waiting]
    )

    Repo.query!(
      "UPDATE lab_intents SET available_at = clock_timestamp() + interval '1 day' WHERE run_id = $1",
      [ready]
    )

    assert {:ok, %{run_id: ^ready}} =
             IntentStore.claim_next("hint-proof", run_ids: [waiting, ready, low])

    assert token(waiting) == [nil, 1]

    assert {:ok, %{run_id: ^low}} =
             IntentStore.claim_next("lower", run_ids: [waiting, ready, low])
  end

  test "a future retry cannot block later eligible Runs at any priority", c do
    ids =
      for n <- 1..4, do: create(c, "-future-#{n}", priority: 9, retry_policy: retry_policy(800))

    Enum.each(ids, &schedule/1)
    ready = create(c, "-ready")
    assert {:ok, %{run_id: ^ready}} = IntentStore.claim_next("scan", run_ids: ids ++ [ready])
    assert Enum.all?(ids, &(token(&1) == [nil, 1]))
  end

  test "blocked reconciliation, legacy Runs, terminals and live claims are excluded", c do
    legacy = c.prefix <> "-legacy"
    assert {:ok, _} = Storage.create_run(legacy, "legacy")
    terminal = create(c, "-terminal")
    assert {:ok, _} = Recovery.resume(terminal)
    claimed = create(c, "-claimed")
    assert {:ok, _} = IntentStore.claim(claimed, "owner")

    blocked =
      create(c, "-blocked",
        script: [{:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 1}}}],
        mock_mode: :unqueryable,
        mock_response: :lost
      )

    assert {:ok, result} = Recovery.resume(blocked)
    assert result.state.status == :blocked

    assert {:ok, nil} =
             IntentStore.claim_next("isolated", run_ids: [legacy, terminal, claimed, blocked])

    assert token(legacy) == [nil, 0]
    assert token(blocked) == [nil, 0]
  end

  test "invalid recovery authority is visible and cannot starve a valid Run", c do
    invalid = create(c, "-invalid", priority: 9)
    valid = create(c, "-valid")
    Repo.query!("UPDATE lab_recovery SET config_sha256 = 'broken' WHERE run_id = $1", [invalid])

    log =
      capture_log(fn ->
        assert {:ok, %{run_id: ^valid}} =
                 IntentStore.claim_next("healthy", run_ids: [invalid, valid])
      end)

    assert log =~ "Dispatch skipped invalid candidates"
    assert log =~ invalid
    assert token(invalid) == [nil, 0]

    assert {:error,
            {:invalid_dispatch_candidates,
             [%{run_id: ^invalid, reason: {:corrupt_recovery, :recovery_config_hash_mismatch}}]}} =
             IntentStore.claim_next("diagnostic", run_ids: [invalid])
  end

  test "invalid retry authority is rejected without claiming or consuming an attempt", c do
    id = create(c, "-bad-retry", retry_policy: retry_policy(400))
    schedule(id)
    Repo.query!("UPDATE lab_retries SET state_data = $2 WHERE run_id = $1", [id, <<0, 1, 2>>])

    assert {:error, {:invalid_dispatch_candidates, [%{run_id: ^id, reason: {:corrupt_retry, _}}]}} =
             IntentStore.claim_next("reject", run_ids: [id])

    assert token(id) == [nil, 1]
  end

  test "claim acknowledgement and identity cross the real COMMIT boundary", c do
    id = create(c, "-commit")
    parent = self()

    task =
      Task.async(fn ->
        IntentStore.claim_next("commit",
          run_ids: [id],
          hook: fn stage ->
            send(parent, {stage, self()})
            receive do: ({:continue, ^stage} -> :ok)
          end
        )
      end)

    assert_receive {:before_commit, pid}
    assert token(id) == [nil, 0]
    assert Task.yield(task, 0) == nil
    send(pid, {:continue, :before_commit})
    assert_receive {:after_commit, ^pid}
    assert [stored, 1] = token(id)
    assert is_binary(stored)
    assert Task.yield(task, 0) == nil
    send(pid, {:continue, :after_commit})
    assert {:ok, %{token: ^stored}} = Task.await(task)
  end

  test "a precommit exception rolls back the new claim generation", c do
    id = create(c, "-rollback")

    assert_raise RuntimeError, "rollback dispatch", fn ->
      IntentStore.claim_next("crashed",
        run_ids: [id],
        hook: fn
          :before_commit -> raise "rollback dispatch"
          :after_commit -> :ok
        end
      )
    end

    assert token(id) == [nil, 0]
    assert {:ok, %{generation: 1}} = IntentStore.claim_next("replacement", run_ids: [id])
  end

  test "retry schedule and its SQL availability hint commit together", c do
    id = create(c, "-projection", retry_policy: retry_policy(400))
    assert {:ok, current} = Recovery.load(id)
    policy = current.recovery.retry_config.policy
    assert {:ok, claim} = IntentStore.claim(id, "first")
    assert {:ok, _} = RetryStore.reserve(claim, policy, :model)
    parent = self()

    task =
      Task.async(fn ->
        RetryStore.schedule(claim, policy, :model, ErrorPolicy.classify(:unavailable),
          hook: fn
            :before_commit ->
              send(parent, {:schedule_precommit, self()})
              receive do: (:commit -> :ok)

            :after_commit ->
              :ok
          end
        )
      end)

    assert_receive {:schedule_precommit, pid}
    assert hint(id) == nil
    send(pid, :commit)
    assert {:ok, retry} = Task.await(task)
    assert DateTime.to_unix(hint(id), :millisecond) == retry.next_attempt_at_ms
  end

  test "abandoned reservation schedules its backoff and projection atomically", c do
    id = create(c, "-abandoned", retry_policy: retry_policy(400))
    assert {:ok, current} = Recovery.load(id)
    policy = current.recovery.retry_config.policy
    assert {:ok, old} = IntentStore.claim(id, "old")
    assert {:ok, _} = RetryStore.reserve(old, policy, :model)
    assert :ok = IntentStore.release(old)
    assert {:ok, next} = IntentStore.claim_next("successor", run_ids: [id])
    assert {:error, {:retry_not_due, due}} = RetryStore.reserve(next, policy, :model)
    assert DateTime.to_unix(hint(id), :millisecond) == due
    assert :ok = IntentStore.release(next)
    assert {:ok, nil} = IntentStore.claim_next("still-wait", run_ids: [id])
    assert token(id) == [nil, 2]
  end

  test "strict options and nested transactions cannot issue scheduler claims", c do
    id = create(c, "-options")

    for opts <- [
          [lease_ms: 0],
          [lease_ms: 86_400_001],
          [run_ids: []],
          [run_ids: [id, id]],
          [run_ids: [nil]],
          [run_ids: id],
          [run_ids: [id], run_ids: [id]],
          [unexpected: true],
          [hook: false],
          %{run_ids: [id]}
        ] do
      assert {:error, :invalid_claim_options} = IntentStore.claim_next("worker", opts)
    end

    assert {:error, :invalid_claim_owner} = IntentStore.claim_next("", run_ids: [id])

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> IntentStore.claim_next("nested", run_ids: [id]) end)

    assert token(id) == [nil, 0]
    assert {:ok, nil} = IntentStore.claim_next("missing", run_ids: [id <> "-missing"])
  end

  defp create(c, suffix, opts \\ []) do
    id = c.prefix <> suffix

    assert {:ok, _} =
             Recovery.create_run(
               id,
               "Durable dispatcher",
               Keyword.put_new(opts, :script, [{:final, "Done"}])
             )

    id
  end

  defp retry_policy(delay),
    do: [max_attempts: 3, base_delay_ms: delay, max_delay_ms: delay, max_elapsed_ms: 5_000]

  defp schedule(id) do
    assert {:ok, current} = Recovery.load(id)
    policy = current.recovery.retry_config.policy
    assert {:ok, claim} = IntentStore.claim(id, "first")
    assert {:ok, _} = RetryStore.reserve(claim, policy, :model)

    assert {:ok, state} =
             RetryStore.schedule(claim, policy, :model, ErrorPolicy.classify(:unavailable))

    assert :ok = IntentStore.release(claim)
    state.next_attempt_at_ms
  end

  defp hint(id) do
    %{rows: [[value]]} =
      Repo.query!(
        "SELECT available_at FROM lab_intents WHERE run_id = $1 AND status = 'pending'",
        [id]
      )

    if value, do: DateTime.from_naive!(value, "Etc/UTC")
  end

  defp token(id) do
    %{rows: [value]} =
      Repo.query!(
        "SELECT claim_token::text, claim_generation FROM lab_intents WHERE run_id = $1 AND status = 'pending'",
        [id]
      )

    value
  end

  defp wait_due(due) do
    now = AgentSystemsLab.RecoveryStore.now_ms()

    if now < due do
      Process.sleep(min(due - now + 1, 50))
      wait_due(due)
    end
  end
end
