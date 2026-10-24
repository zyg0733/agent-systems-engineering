defmodule AgentSystemsLab.P2SafetyTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    CheckpointStore,
    ContextStore,
    DurableTools,
    IntentStore,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    RecoveryStore,
    Repo,
    RetryStore,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec
  @moduletag :database

  setup do
    id = "p2-safety-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"), id)
    File.mkdir_p!(root)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  for commit_boundary <- [:before_commit, :after_commit] do
    test "tool receipt and Run COMMIT survive a real kill #{commit_boundary}", c do
      create_waiting(c)
      kill_step(c.id, :commit_hook, unquote(commit_boundary))
      assert {:ok, [receipt]} = DurableTools.list(c.id)
      assert receipt.status == "completed"
      assert DurableTools.stats(c.id).effects == 1
      assert {:ok, previous} = Recovery.load(c.id)

      expected_status =
        if unquote(commit_boundary) == :before_commit, do: :waiting_tool, else: :running

      assert previous.state.status == expected_status

      assert {:ok, done} =
               in_new_process(fn ->
                 Recovery.resume(c.id,
                   tool_hook: fn at ->
                     if at == :before_effect, do: flunk("receipt reuse invoked an effect")
                   end
                 )
               end)

      assert done.state.status == :succeeded
      assert done.state.operations["once"].result === elem(receipt.result, 1)
      assert DurableTools.stats(c.id).effects == 1
      assert Enum.count(done.events, &(&1.type == :tool_result_recorded)) == 1
    end
  end

  for retry? <- [false, true] do
    test "manual receipt survives another kill before reconciliation event with retry=#{retry?}",
         c do
      extra = if unquote(retry?), do: [retry_policy: policy()], else: []
      create_waiting(c, [mock_mode: :unqueryable, mock_response: :lost] ++ extra)
      assert {:ok, blocked} = Recovery.step(c.id)
      assert blocked.state.status == :blocked

      kill_call(
        c.id,
        fn opts ->
          Recovery.reconcile(
            c.id,
            opts ++
              [
                result: {:ok, %{external_receipt: "verified once"}},
                evidence: "A trusted operator independently verified the original target receipt."
              ]
          )
        end,
        :tool_hook,
        :after_receipt
      )

      assert {:ok, [operation]} = DurableTools.list(c.id)
      assert operation.status == "completed"
      assert List.last(operation.attempts).kind == "manual"
      assert {:ok, entry} = ReconciliationQueue.get(c.id)
      assert entry.journal_status == "completed"
      assert entry.latest_attempt.kind == "manual"

      assert {:error, _} =
               Recovery.reconcile(c.id,
                 result: {:ok, %{external_receipt: "different unsupported outcome"}},
                 evidence: "A different assertion cannot replace the already confirmed receipt."
               )

      assert {:ok, [unchanged]} = DurableTools.list(c.id)
      assert unchanged.result === operation.result

      assert {:ok, running} =
               in_new_process(fn ->
                 Recovery.reconcile(c.id,
                   tool_hook: fn at ->
                     if at == :before_effect, do: flunk("manual receipt reuse queried a target")
                   end
                 )
               end)

      assert running.state.status == :running
      assert running.state.operations["once"].result === elem(operation.result, 1)
      assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
      assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
      assert DurableTools.stats(c.id).effects == 1
    end
  end

  test "receipt committed by the final allowed query is reused after a second crash", c do
    create_waiting(c,
      mock_response: :lost,
      retry_policy: policy(max_attempts: 1)
    )

    assert {:ok, %{state: %{status: :blocked}}} = Recovery.step(c.id)

    kill_call(
      c.id,
      &Recovery.reconcile(c.id, &1),
      :commit_hook,
      :before_commit
    )

    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert operation.status == "completed"
    assert List.last(operation.attempts).kind == "lookup"
    assert {:ok, %{status: :inflight, attempts: 1}} = RetryStore.load(c.id, 3, :reconcile)

    assert {:ok, running} =
             in_new_process(fn ->
               Recovery.reconcile(c.id,
                 tool_hook: fn at ->
                   if at == :before_effect, do: flunk("confirmed query repeated external lookup")
                 end
               )
             end)

    assert running.state.status == :running
    assert {:ok, audit} = RetryStore.load(c.id, 3, :reconcile)
    assert audit.attempts == 1
    assert audit.status == :succeeded
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert DurableTools.stats(c.id).effects == 1
  end

  test "repeated death during query recovery exhausts its budget while preserving visible unknown",
       c do
    create_waiting(c,
      mock_response: :lost,
      retry_policy: policy(max_attempts: 2)
    )

    assert {:ok, blocked} = Recovery.step(c.id)
    assert blocked.state.status == :blocked

    for ordinal <- 1..2 do
      kill_call(c.id, &Recovery.reconcile(c.id, &1), :hook, :after_retry_reserve)
      assert {:ok, inflight} = RetryStore.load(c.id, 3, :reconcile)
      assert inflight.status == :inflight
      assert inflight.attempts == ordinal

      result = in_new_process(fn -> Recovery.reconcile(c.id) end)

      if ordinal == 1 do
        assert {:error, {:retry_not_due, due}} = result
        remaining = due - RecoveryStore.now_ms() + 2
        if remaining > 0, do: Process.sleep(remaining)
      else
        assert {:error, {:retry_exhausted, _}} = result
      end
    end

    for _ <- 1..3 do
      assert {:error, {:retry_exhausted, _}} =
               in_new_process(fn -> Recovery.reconcile(c.id) end)

      assert {:ok, entry} = ReconciliationQueue.get(c.id)
      assert entry.operation_id == "once"
      assert entry.journal_status == "unknown"
      assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 1}
    end

    assert {:ok, exhausted} = RetryStore.load(c.id, 3, :reconcile)
    assert exhausted.attempts == 2
    assert exhausted.status == :exhausted

    assert Enum.all?(
             exhausted.deliveries,
             &(&1.failure.reason == {:abandoned_attempt, :reconcile})
           )

    assert {:ok, running} =
             Recovery.reconcile(c.id,
               result: {:ok, %{external_receipt: "operator verified original effect"}},
               evidence: "Operator verified the target receipt after query budget exhaustion."
             )

    assert running.state.status == :running
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert DurableTools.stats(c.id).effects == 1
  end

  test "expired old worker cannot confirm after successor commits the original receipt", c do
    create_waiting(c)
    parent = self()
    gate = make_ref()

    {old, monitor} =
      spawn_monitor(fn ->
        result =
          Recovery.step(c.id,
            lease_ms: 200,
            tool_hook: fn at ->
              if at == :after_effect do
                send(parent, {gate, :effect_committed, self()})
                receive do: ({^gate, :release} -> :ok)
              end
            end
          )

        send(parent, {gate, :old_result, result})
      end)

    on_exit(fn -> if Process.alive?(old), do: Process.exit(old, :kill) end)
    assert_receive {^gate, :effect_committed, ^old}, 5_000
    assert DurableTools.stats(c.id).effects == 1
    wait_for_lease(c.id)
    assert {:ok, done} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert done.state.status == :succeeded
    send(old, {gate, :release})
    assert_receive {^gate, :old_result, {:error, :stale_claim}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^old, :normal}, 5_000
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.state === done.state
    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert Enum.map(operation.attempts, & &1.outcome) == ["prepared", "completed"]
  end

  for tool <- ["file_write", "file_patch"], stage <- [:after_effect, :after_receipt] do
    test "#{tool} crash #{stage} preserves a subsequent independent edit", c do
      tool = unquote(tool)
      stage = unquote(stage)
      path = Path.join(c.root, "result.txt")
      if tool == "file_patch", do: File.write!(path, "version one\n")
      call = file_call(tool)
      create_waiting(c, workspace: c.root, script: [{:call, call}, {:final, "done"}])
      kill_step(c.id, :tool_hook, stage)
      assert File.read!(path) == "version two\n"
      File.write!(path, "independent edit after original effect\n")

      assert {:ok, recovered} =
               in_new_process(fn ->
                 Recovery.resume(c.id,
                   tool_hook: fn at ->
                     if at == :before_effect, do: flunk("file operation was sent again")
                   end
                 )
               end)

      assert File.read!(path) == "independent edit after original effect\n"

      assert recovered.state.status ==
               unquote(if stage == :after_effect, do: :blocked, else: :succeeded)

      if recovered.state.status == :blocked do
        assert recovered.state.status == :blocked
        assert {:ok, entry} = ReconciliationQueue.get(c.id)
        assert entry.safe_mode == :manual
        assert entry.journal_status == "unknown"
        assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
      else
        assert recovered.state.status == :succeeded
        assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
        assert {:ok, [operation]} = DurableTools.list(c.id)
        assert operation.status == "completed"
        assert Enum.map(operation.attempts, & &1.outcome) == ["completed", "completed"]
      end
    end
  end

  for tool <- ["file_write", "file_patch"] do
    test "#{tool} manual confirmation survives another crash and preserves an independent edit",
         c do
      tool = unquote(tool)
      path = Path.join(c.root, "result.txt")
      if tool == "file_patch", do: File.write!(path, "version one\n")

      create_waiting(c,
        workspace: c.root,
        script: [{:call, file_call(tool)}, {:final, "done"}],
        retry_policy: policy()
      )

      kill_step(c.id, :tool_hook, :after_effect)
      assert File.read!(path) == "version two\n"
      File.write!(path, "independent edit after original effect\n")
      assert {:ok, %{state: %{status: :blocked}}} = Recovery.resume(c.id)

      kill_call(
        c.id,
        fn opts ->
          Recovery.reconcile(
            c.id,
            opts ++
              [
                result: {:ok, %{external_receipt: "operator verified original file effect"}},
                evidence: "Verified original write independently; preserve subsequent user edit."
              ]
          )
        end,
        :commit_hook,
        :before_commit
      )

      assert {:ok, [record]} = DurableTools.list(c.id)
      assert record.status == "completed"
      assert List.last(record.attempts).kind == "manual"

      assert {:ok, %{state: %{status: :running}}} =
               in_new_process(fn ->
                 Recovery.reconcile(c.id,
                   tool_hook: fn at ->
                     if at == :before_effect, do: flunk("confirmed file was executed again")
                   end
                 )
               end)

      assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
      assert File.read!(path) == "independent edit after original effect\n"
      assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
    end
  end

  test "cancellation after external effect fences receipt and retains immutable effect audit",
       c do
    create_waiting(c, mock_mode: :unqueryable)
    parent = self()
    gate = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          Recovery.step(c.id,
            tool_hook: fn at ->
              if at == :after_effect do
                send(parent, {gate, :effect_committed, self()})
                receive do: ({^gate, :release} -> :ok)
              end
            end
          )

        send(parent, {gate, :result, result})
      end)

    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    assert_receive {^gate, :effect_committed, ^worker}, 5_000
    assert {:ok, cancelled} = Recovery.cancel(c.id)
    send(worker, {gate, :release})
    assert_receive {^gate, :result, {:error, :stale_claim}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert cancelled.state.status == :cancelled
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert operation.status == "prepared"
    assert operation.result == nil
    assert hd(operation.attempts).outcome == "prepared"
    assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 1}
    assert {:ok, unchanged} = in_new_process(fn -> Recovery.resume(c.id) end)
    assert unchanged.state === cancelled.state
    assert {:error, :not_blocked} = Recovery.reconcile(c.id)
    assert {:ok, [_original_proposal]} = ModelResultStore.list(c.id)
    assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 1}
  end

  test "local confirmed receipt requires a live current claim and the exact pending operation",
       c do
    waiting = create_waiting(c)
    operation = waiting.state.operations["once"]
    assert {:ok, old_claim} = IntentStore.claim(c.id, "old receipt reader", lease_ms: 150)
    assert {:ok, result} = DurableTools.execute(old_claim, operation)
    wait_for_lease(c.id)
    assert {:error, :claim_expired} = DurableTools.confirmed_receipt(old_claim, operation)
    assert {:ok, successor} = IntentStore.claim(c.id, "successor receipt reader")
    assert {:error, :stale_claim} = DurableTools.confirmed_receipt(old_claim, operation)

    assert {:error, :operation_id_conflict} =
             DurableTools.confirmed_receipt(
               successor,
               put_in(operation.arguments["value"], 2)
             )

    assert {:ok, ^result} = DurableTools.confirmed_receipt(successor, operation)
    assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 1}
    assert :ok = IntentStore.release(successor)
  end

  test "corrupted delivery audit blocks local receipt reuse without querying or repairing it",
       c do
    create_waiting(c, mock_response: :lost, mock_mode: :unqueryable, retry_policy: policy())
    assert {:ok, %{state: %{status: :blocked}}} = Recovery.step(c.id)

    kill_call(
      c.id,
      fn opts ->
        Recovery.reconcile(
          c.id,
          opts ++
            [
              result: {:ok, %{external_receipt: "confirmed original outcome"}},
              evidence: "Trusted operator checked the target receipt."
            ]
        )
      end,
      :tool_hook,
      :after_receipt
    )

    assert {:ok, before} = Storage.load(c.id)
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert operation.status == "completed"
    {:ok, broken_audit} = Codec.encode(%{})
    attempt_id = List.last(operation.attempts).id

    Repo.query!("UPDATE lab_attempts SET claim_data=$2 WHERE id::text=$1", [
      attempt_id,
      broken_audit
    ])

    assert {:error, :attempt_metadata_mismatch} =
             Recovery.reconcile(c.id,
               tool_hook: fn at -> flunk("corrupt receipt audit reached adapter gate #{at}") end
             )

    assert {:ok, after_failure} = Storage.load(c.id)
    assert after_failure.state === before.state
    assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 2}
    assert {:ok, [_]} = ModelResultStore.list(c.id)
  end

  test "incompatible operation payload prevents recovery from repairing it through adapters", c do
    create_waiting(c)
    kill_step(c.id, :tool_hook, :after_effect)
    assert DurableTools.stats(c.id).effects == 1

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE lab_operations SET schema_version=2 WHERE run_id=$1", [c.id])
    end

    {:ok, future} =
      Codec.encode(%{tool: "mock_write", arguments: %{"value" => 1}, schema_version: 2})

    Repo.query!("UPDATE lab_operations SET input_data=$2 WHERE run_id=$1", [c.id, future])
    assert {:ok, before} = Storage.load(c.id)

    assert {:error, :operation_input_mismatch} =
             Recovery.resume(c.id,
               tool_hook: fn at -> flunk("unsupported operation reached adapter gate #{at}") end
             )

    assert {:ok, after_failure} = Storage.load(c.id)
    assert before.state === after_failure.state
    assert DurableTools.stats(c.id) == %{effects: 1, operations: 1, attempts: 1}
    assert {:ok, [_]} = ModelResultStore.list(c.id)
    assert {:ok, [_]} = ContextStore.list(c.id)
  end

  test "future history and corrupted latest checkpoint fail closed without adapter repair", c do
    assert {:ok, initial} =
             Recovery.create_run(c.id, "freeze history", script: [{:final, "done"}])

    assert {:ok, checkpoint} = CheckpointStore.create(c.id, initial.state.seq)
    {:ok, broken} = Codec.encode(%{checkpoint.checkpoint | schema_version: 2})

    Repo.query!("UPDATE lab_checkpoints SET data=$2 WHERE run_id=$1", [c.id, broken])

    assert {:error, {:corrupt_checkpoint, {:unsupported_checkpoint_schema_version, 2}}} =
             CheckpointStore.rebuild(c.id)

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE lab_events SET schema_version=2 WHERE run_id=$1", [c.id])
    end

    {:ok, future} = Codec.encode(%{input: "freeze history", schema_version: 2})
    Repo.query!("UPDATE lab_events SET data=$2 WHERE run_id=$1", [c.id, future])

    assert {:error, {:corrupt_storage, _}} =
             Recovery.resume(c.id,
               hook: fn at -> flunk("future history reached runtime gate #{at}") end
             )

    assert {:ok, []} = ModelResultStore.list(c.id)
    assert DurableTools.stats(c.id) == %{effects: 0, operations: 0, attempts: 0}
  end

  defp create_waiting(c, opts \\ []) do
    assert {:ok, _} =
             Recovery.create_run(
               c.id,
               "Keep one externally visible effect",
               Keyword.merge([script: [{:call, mock_call()}, {:final, "done"}]], opts)
             )

    assert {:ok, waiting} = Recovery.step(c.id)
    assert waiting.state.status == :waiting_tool
    waiting
  end

  defp mock_call,
    do: %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 1}}

  defp file_call("file_write"),
    do: %{
      operation_id: "file",
      tool: "file_write",
      arguments: %{
        "path" => "result.txt",
        "content" => "version two\n",
        "expected_sha256" => "absent"
      }
    }

  defp file_call("file_patch"),
    do: %{
      operation_id: "file",
      tool: "file_patch",
      arguments: %{
        "path" => "result.txt",
        "expected_sha256" =>
          :crypto.hash(:sha256, "version one\n") |> Base.encode16(case: :lower),
        "edits" => [%{"old" => "version one", "new" => "version two"}]
      }
    }

  defp policy(opts \\ []),
    do:
      Keyword.merge(
        [max_attempts: 3, base_delay_ms: 20, max_delay_ms: 40, max_elapsed_ms: 5_000],
        opts
      )

  defp kill_step(id, key, stage),
    do: kill_call(id, &Recovery.step(id, &1), key, stage)

  defp kill_call(id, function, key, stage) do
    parent = self()
    gate = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn at ->
          if at == stage do
            send(parent, {gate, :at_boundary, self()})
            receive do: ({^gate, :release} -> :ok)
          end
        end

        result = function.(Keyword.put([lease_ms: 200], key, hook))
        send(parent, {gate, :unexpected_return, result})
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {^gate, :at_boundary, _worker}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_received {^gate, :unexpected_return, _}
    wait_for_lease(id)
  end

  defp wait_for_lease(id) do
    assert {:ok, snapshot} = Storage.load(id)

    if snapshot.intent && snapshot.intent.claim_expires_at do
      due = DateTime.to_unix(snapshot.intent.claim_expires_at, :millisecond) + 2
      remaining = due - RecoveryStore.now_ms()
      assert remaining < 1_000
      if remaining > 0, do: Process.sleep(remaining)
    end
  end

  defp in_new_process(function), do: function |> Task.async() |> Task.await(10_000)
end
