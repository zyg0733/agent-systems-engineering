defmodule AgentSystemsLab.QueueStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    ErrorPolicy,
    IntentStore,
    QueueStore,
    Recovery,
    RecoveryStore,
    Repo,
    RetryStore,
    Storage
  }

  @moduletag :database

  setup do
    prefix = "queue-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [prefix <> "%"])
      Repo.query!("DELETE FROM lab_queues WHERE name LIKE $1", [prefix <> "%"])
    end)

    %{prefix: prefix}
  end

  test "queue configuration is strict, immutable and persisted", c do
    assert {:ok, q} = QueueStore.create(c.prefix, capacity: 4, max_inflight: 2)

    assert Map.take(q, [:capacity, :max_inflight, :aging_ms, :starvation_ms]) == %{
             capacity: 4,
             max_inflight: 2,
             aging_ms: 1000,
             starvation_ms: 10000
           }

    assert {:error, {:queue_already_exists, _}} =
             QueueStore.create(c.prefix, capacity: 8, max_inflight: 4)

    assert {:ok, %{capacity: 4, active: 0}} = QueueStore.stats(c.prefix)

    for opts <- [
          [],
          [capacity: 0, max_inflight: 1],
          [capacity: 10_001, max_inflight: 1],
          [capacity: 2, max_inflight: 3],
          [capacity: 2, max_inflight: 1, aging_ms: 0],
          [capacity: 2, max_inflight: 1, starvation_ms: 0],
          [capacity: 2, max_inflight: 1, extra: true],
          [capacity: 2, capacity: 2, max_inflight: 1],
          %{},
          [nil]
        ] do
      assert {:error, :invalid_queue_options} = QueueStore.create(c.prefix <> "-invalid", opts)
    end

    assert {:error, :invalid_queue_name} = QueueStore.create("", capacity: 1, max_inflight: 1)
    assert {:error, :queue_not_found} = QueueStore.stats(c.prefix <> "-missing")
    assert {:error, :invalid_queue_options} = QueueStore.starvation(c.prefix, limit: 1001)

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn ->
               QueueStore.create(c.prefix <> "-nested", capacity: 1, max_inflight: 1)
             end)
  end

  test "concurrent admission is atomic and rejected work creates no durable records", c do
    assert {:ok, _} = QueueStore.create(c.prefix, capacity: 3, max_inflight: 2)
    gate = make_ref()
    parent = self()

    tasks =
      for n <- 1..12 do
        Task.async(fn ->
          send(parent, {gate, :ready})

          receive do: ({^gate, :go} ->
                         Recovery.create_run(c.prefix <> "-#{n}", "bounded", queue: c.prefix))
        end)
      end

    for _ <- tasks, do: assert_receive({^gate, :ready}, 2000)
    Enum.each(tasks, &send(&1.pid, {gate, :go}))
    outcomes = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 3
    assert Enum.count(outcomes, &(&1 == {:error, :queue_full})) == 9

    for table <- ["lab_runs", "lab_events", "lab_intents", "lab_recovery"] do
      column = if table == "lab_runs", do: "id", else: "run_id"

      assert %{rows: [[3]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} LIKE $1", [
                 c.prefix <> "%"
               ])
    end

    assert {:ok, %{active: 3, available_slots: 0, ready: 3}} = QueueStore.stats(c.prefix)
  end

  test "terminal transition releases capacity while blocked reconciliation retains its slot", c do
    queue(c, capacity: 1, max_inflight: 1)

    blocked =
      create(c, "-blocked",
        script: [{:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 1}}}],
        mock_mode: :unqueryable,
        mock_response: :lost
      )

    assert {:ok, %{state: %{status: :blocked}}} = Recovery.resume(blocked)

    assert {:ok, %{active: 1, blocked: 1, available_slots: 0, ready: 0}} =
             QueueStore.stats(c.prefix)

    assert {:ok, operator_claim} = IntentStore.claim(blocked, "operator-reconcile")

    assert {:ok, %{blocked: 1, live_leases: 1, claimed: 1, inflight_slots: 0}} =
             QueueStore.stats(c.prefix)

    assert :ok = IntentStore.release(operator_claim)

    assert {:error, :queue_full} =
             Recovery.create_run(c.prefix <> "-rejected", "full", queue: c.prefix)

    assert {:ok, _} = Recovery.cancel(blocked, :operator)
    assert {:ok, %{active: 0, available_slots: 1}} = QueueStore.stats(c.prefix)
    assert create(c, "-next") == c.prefix <> "-next"
  end

  test "admission rollback releases the queue lock and all insertions", c do
    queue(c, capacity: 1, max_inflight: 1)

    assert_raise RuntimeError, "admission crash", fn ->
      Recovery.create_run(c.prefix <> "-rollback", "rollback",
        queue: c.prefix,
        hook: fn
          :before_commit -> raise "admission crash"
          _ -> :ok
        end
      )
    end

    assert {:error, :not_found} = Storage.load(c.prefix <> "-rollback")
    assert {:ok, %{active: 0}} = QueueStore.stats(c.prefix)
    create(c, "-replacement")
  end

  test "direct Storage cannot admit an unenrolled Run or bypass the default task budget", c do
    queue(c, capacity: 3, max_inflight: 1)
    legacy = c.prefix <> "-legacy"

    assert {:error, :queue_requires_recovery} =
             Storage.create_run(legacy, "unenrolled", queue: c.prefix)

    assert {:error, :not_found} = Storage.load(legacy)
    source = create(c, "-source")
    assert {:ok, saved} = Recovery.load(source)
    direct = c.prefix <> "-direct"

    assert {:ok, _} =
             Storage.create_run(direct, "enrolled",
               queue: c.prefix,
               recovery_config: saved.recovery.config
             )

    assert {:ok,
            %{
              config: %{max_dispatches: 32, execution_timeout_ms: 5000},
              progress: %{dispatches: 0}
            }} = AgentSystemsLab.TaskBudgetStore.load(direct)

    assert {:ok, %{active: 2}} = QueueStore.stats(c.prefix)
  end

  test "corrupt or missing queued budgets fail closed without starving healthy candidates", c do
    queue(c, capacity: 3, max_inflight: 1)
    corrupt = create(c, "-corrupt", priority: 9)
    missing = create(c, "-missing", priority: 9)
    healthy = create(c, "-healthy")
    Repo.query!("UPDATE lab_task_budgets SET config_sha256 = 'bad' WHERE run_id = $1", [corrupt])
    Repo.query!("DELETE FROM lab_task_budgets WHERE run_id = $1", [missing])

    assert {:error, {:corrupt_task_budget, :config_hash_mismatch}} =
             IntentStore.claim(corrupt, "direct-corrupt")

    assert {:error, :task_budget_missing} = IntentStore.claim(missing, "direct-missing")

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{run_id: ^healthy}} = IntentStore.claim_next("healthy", queue: c.prefix)
    end)

    assert {:ok, %{active: 3, invalid: 2, claimed: 1}} = QueueStore.stats(c.prefix)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT sum(claim_generation)::integer FROM lab_intents WHERE run_id = ANY($1)",
               [
                 [corrupt, missing]
               ]
             )
  end

  test "shared inflight quota bounds parallel pools and explicit claims", c do
    queue(c, capacity: 8, max_inflight: 2)
    ids = for n <- 1..8, do: create(c, "-#{n}")

    results =
      1..12
      |> Task.async_stream(fn n -> IntentStore.claim_next("pool-#{n}", queue: c.prefix) end,
        max_concurrency: 12,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    claims = for {:ok, claim} <- results, not is_nil(claim), do: claim
    assert length(claims) == 2
    assert length(Enum.uniq_by(claims, & &1.run_id)) == 2
    assert {:ok, %{live_leases: 2, inflight_slots: 0, ready: 6}} = QueueStore.stats(c.prefix)
    next = Enum.find(ids, fn id -> Enum.all?(claims, &(&1.run_id != id)) end)
    assert {:error, :queue_inflight_full} = IntentStore.claim(next, "bypass")
    assert :ok = IntentStore.release(hd(claims))
    assert {:ok, _} = IntentStore.claim(next, "explicit-slot")
    assert {:ok, %{live_leases: 2}} = QueueStore.stats(c.prefix)
  end

  test "a caller killed after admission COMMIT cannot release its durable capacity", c do
    queue(c, capacity: 1, max_inflight: 1)
    id = c.prefix <> "-commit"
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Recovery.create_run(id, "committed",
          queue: c.prefix,
          script: [{:final, "Done"}],
          hook: fn
            :after_commit ->
              send(parent, {:admitted, self()})
              receive do: (:never -> :ok)

            _ ->
              :ok
          end
        )
      end)

    assert_receive {:admitted, ^pid}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, %{active: 1, available_slots: 0}} = QueueStore.stats(c.prefix)

    assert {:error, :queue_full} =
             Recovery.create_run(c.prefix <> "-new", "full", queue: c.prefix)

    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(id)
    assert {:ok, %{active: 0, available_slots: 1}} = QueueStore.stats(c.prefix)
  end

  test "a claim acknowledged only by COMMIT holds quota until its real lease expires", c do
    queue(c, capacity: 2, max_inflight: 1)
    first = create(c, "-first")
    second = create(c, "-second")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        IntentStore.claim_next("lost-ack",
          queue: c.prefix,
          lease_ms: 60,
          hook: fn
            :after_commit ->
              send(parent, {:claimed, self()})
              receive do: (:never -> :ok)

            _ ->
              :ok
          end
        )
      end)

    assert_receive {:claimed, ^pid}, 2000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:error, :queue_inflight_full} = IntentStore.claim(second, "too-early")

    assert %{rows: [[expires_at]]} =
             Repo.query!(
               "SELECT claim_expires_at FROM lab_intents WHERE run_id = $1 AND status = 'pending'",
               [first]
             )

    wait_until(DateTime.to_unix(DateTime.from_naive!(expires_at, "Etc/UTC"), :millisecond) + 1)
    assert {:ok, replacement} = IntentStore.claim(first, "replacement")
    assert replacement.generation == 2
    assert {:ok, %{live_leases: 1}} = QueueStore.stats(c.prefix)
  end

  test "expired claims free quota and old tokens remain fenced", c do
    queue(c, capacity: 2, max_inflight: 1)
    first = create(c, "-first")
    second = create(c, "-second")
    assert {:ok, old} = IntentStore.claim(first, "old", lease_ms: 40)
    assert {:ok, nil} = IntentStore.claim_next("early", queue: c.prefix)
    wait_until(DateTime.to_unix(old.expires_at, :millisecond) + 1)
    assert {:ok, replacement} = IntentStore.claim(second, "new")
    assert {:error, :claim_expired} = IntentStore.renew(old)
    assert {:error, :queue_inflight_full} = IntentStore.claim(first, "second-slot")
    assert {:ok, %{live_leases: 1}} = QueueStore.stats(c.prefix)
    assert :ok = IntentStore.release(replacement)
    assert {:ok, newer} = IntentStore.claim(first, "replaced")
    assert newer.generation == old.generation + 1
    assert {:error, :stale_claim} = Storage.dispatch(first, old.seq, {:cancel, :late}, claim: old)
  end

  test "legacy dispatch excludes queue members without changing existing unqueued dispatch", c do
    queue(c, capacity: 2, max_inflight: 1)
    queued = create(c, "-queued", priority: 9)
    legacy = c.prefix <> "-legacy"
    assert {:ok, _} = Recovery.create_run(legacy, "legacy", script: [{:final, "ok"}])
    assert {:ok, %{run_id: ^legacy}} = IntentStore.claim_next("legacy", run_ids: [queued, legacy])
    assert {:ok, nil} = IntentStore.claim_next("bypass", run_ids: [queued])
    assert {:ok, %{run_id: ^queued}} = IntentStore.claim_next("queue", queue: c.prefix)
  end

  test "natural waiting promotes low priority and starvation clears after service", c do
    queue(c, capacity: 3, max_inflight: 1, aging_ms: 5, starvation_ms: 20)
    low = create(c, "-low", priority: 0)
    wait_until(RecoveryStore.now_ms() + 55)
    high = create(c, "-high", priority: 9)
    assert {:ok, observed} = QueueStore.starvation(c.prefix)
    entry = Enum.find(observed, &(&1.run_id == low))
    assert entry != nil
    assert Enum.all?(observed, &(&1.run_id in [low, high] and &1.wait_ms >= 20))
    assert entry.effective_priority == 9
    assert entry.wait_ms >= 45
    assert {:ok, %{run_id: ^low}} = IntentStore.claim_next("fair", queue: c.prefix)
    assert {:ok, remaining} = QueueStore.starvation(c.prefix)
    # The newly enqueued high-priority run may itself age past 20ms while the
    # database serves these calls. Service must clear low's starvation; it must
    # not erase legitimate waiting evidence for the other ready run.
    refute Enum.any?(remaining, &(&1.run_id == low))
    assert Enum.all?(remaining, &(&1.run_id == high and &1.wait_ms >= 20))
    assert {:ok, %{claimed: 1, ready: 1}} = QueueStore.stats(c.prefix)
    assert is_binary(high)
  end

  test "bounded scans persist progress past future retries and corrupt heads", c do
    queue(c, capacity: 9, max_inflight: 1)
    bad = for n <- 1..3, do: create(c, "-bad#{n}", priority: 9)

    Enum.each(
      bad,
      &Repo.query!("UPDATE lab_recovery SET config_sha256 = 'bad' WHERE run_id = $1", [&1])
    )

    future =
      for n <- 1..3,
          do:
            create(c, "-future#{n}",
              priority: 9,
              retry_policy: [base_delay_ms: 1000, max_delay_ms: 1000, max_elapsed_ms: 5000]
            )

    Enum.each(future, &schedule/1)
    ready = create(c, "-ready")

    assert {:error, {:invalid_dispatch_candidates, rejected}} =
             IntentStore.claim_next("page1", queue: c.prefix, scan_limit: 2)

    assert length(rejected) == 2
    assert {:ok, first_stats} = QueueStore.stats(c.prefix)
    assert first_stats.scan_cursor > 0

    assert {:error, {:invalid_dispatch_candidates, [_]}} =
             IntentStore.claim_next("page2", queue: c.prefix, scan_limit: 2)

    assert {:ok, nil} = IntentStore.claim_next("page3", queue: c.prefix, scan_limit: 2)

    assert {:ok, %{run_id: ^ready}} =
             IntentStore.claim_next("page4", queue: c.prefix, scan_limit: 2)

    assert {:ok, %{waiting_retry: 3, invalid: 3, claimed: 1}} = QueueStore.stats(c.prefix)
  end

  test "starvation diagnostics exclude retry timers, live leases and blocked work", c do
    queue(c, capacity: 5, max_inflight: 3, starvation_ms: 20)
    ready = create(c, "-ready")
    live = create(c, "-live")
    assert {:ok, _} = IntentStore.claim(live, "working")

    future =
      create(c, "-future",
        retry_policy: [base_delay_ms: 1000, max_delay_ms: 1000, max_elapsed_ms: 5000]
      )

    schedule(future)

    blocked =
      create(c, "-blocked",
        script: [{:call, %{operation_id: "once", tool: "mock_write", arguments: %{}}}],
        mock_mode: :unqueryable,
        mock_response: :lost
      )

    assert {:ok, %{state: %{status: :blocked}}} = Recovery.resume(blocked)
    wait_until(RecoveryStore.now_ms() + 30)
    assert {:ok, [%{run_id: ^ready}]} = QueueStore.starvation(c.prefix)

    assert {:ok, %{starved: 1, waiting_retry: 1, claimed: 1, blocked: 1}} =
             QueueStore.stats(c.prefix)
  end

  test "strict queue claim options reject invalid bounds without claim mutation", c do
    queue(c, capacity: 1, max_inflight: 1)
    create(c, "-one")

    for opts <- [
          [queue: c.prefix, scan_limit: 0],
          [queue: c.prefix, scan_limit: 257],
          [queue: ""],
          [queue: nil]
        ] do
      assert {:error, :invalid_claim_options} = IntentStore.claim_next("owner", opts)
    end

    assert {:error, :queue_not_found} =
             IntentStore.claim_next("missing", queue: c.prefix <> "-missing")

    assert {:ok, %{live_leases: 0}} = QueueStore.stats(c.prefix)
  end

  defp queue(c, opts), do: assert({:ok, _} = QueueStore.create(c.prefix, opts))

  defp create(c, suffix, opts \\ []) do
    id = c.prefix <> suffix

    assert {:ok, _} =
             Recovery.create_run(
               id,
               "Queue lab",
               Keyword.merge([queue: c.prefix, script: [{:final, "Done"}]], opts)
             )

    id
  end

  defp schedule(id) do
    assert {:ok, current} = Recovery.load(id)
    policy = current.recovery.retry_config.policy
    assert {:ok, claim} = IntentStore.claim(id, "schedule")
    assert {:ok, _} = RetryStore.reserve(claim, policy, :model)

    assert {:ok, _} =
             RetryStore.schedule(claim, policy, :model, ErrorPolicy.classify(:unavailable))

    assert :ok = IntentStore.release(claim)
  end

  defp wait_until(due) do
    now = RecoveryStore.now_ms()

    if now < due do
      Process.sleep(min(25, due - now + 1))
      wait_until(due)
    end
  end
end
