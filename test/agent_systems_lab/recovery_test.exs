defmodule AgentSystemsLab.RecoveryTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{ContextStore, DurableTools, Kernel, ModelResultStore, Recovery, Repo}
  @moduletag :database

  setup do
    id = "recovery-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    root = Path.join(File.cwd!(), "artifacts/#{id}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  defp call, do: {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}}

  defp create(c, opts \\ []) do
    assert {:ok, saved} =
             Recovery.create_run(
               c.id,
               "recover safely",
               Keyword.merge([script: [call(), {:final, "done"}]], opts)
             )

    saved
  end

  defp kill_at(c, key, stage, opts \\ []) do
    owner = self()
    ref = make_ref()

    hook = fn reached ->
      if reached == stage do
        send(owner, {ref, :at_boundary, self()})
        receive do: ({^ref, :release} -> :ok)
      end
    end

    {pid, monitor} =
      spawn_monitor(fn ->
        result = Recovery.step(c.id, Keyword.put(opts, key, hook))
        send(owner, {ref, :ack, result})
      end)

    assert_receive {^ref, :at_boundary, _worker}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_received {^ref, :ack, _}
    expire(c.id)
  end

  defp expire(id) do
    Repo.query!(
      "UPDATE lab_intents SET claim_expires_at = clock_timestamp() - interval '1 second' WHERE run_id=$1 AND status='pending' AND claim_token IS NOT NULL",
      [id]
    )
  end

  test "durable cursor policy and exact receipts survive unrelated worker processes", c do
    initial = create(c)
    assert {:ok, planned} = Task.async(fn -> Recovery.step(c.id) end) |> Task.await()
    assert planned.recovery.progress.cursor == 1
    assert planned.state.status == :waiting_tool
    assert planned.recovery.config === initial.recovery.config
    assert {:ok, completed} = Task.async(fn -> Recovery.resume(c.id) end) |> Task.await()
    assert completed.state.status == :succeeded
    assert completed.recovery.progress.cursor == 2
    assert completed.recovery.progress.model_attempts == 2
    assert completed.recovery.progress.deadline_at_ms === initial.recovery.progress.deadline_at_ms
    assert {:ok, completed.state} == Kernel.rebuild(c.id, completed.events)
    assert %{effects: 1, operations: 1, attempts: 1} = DurableTools.stats(c.id)
    assert {:ok, results} = ModelResultStore.list(c.id)
    assert Enum.map(results, & &1.event_seq) == [2, 4]
    assert {:ok, ^completed} = Recovery.resume(c.id)
  end

  for stage <- [:before_commit, :after_commit] do
    test "enrollment and Run share the real #{stage} boundary", c do
      stage = unquote(stage)
      owner = self()
      ref = make_ref()

      hook = fn at ->
        if at == stage do
          send(owner, {ref, :barrier})
          receive do: ({^ref, :release} -> :ok)
        end
      end

      {pid, monitor} = spawn_monitor(fn -> create(c, hook: hook) end)
      assert_receive {^ref, :barrier}, 5_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

      verify_enrollment(c.id, stage)
    end
  end

  test "death after claim leaves no model attempt or tool effect", c do
    create(c)
    kill_at(c, :hook, :after_claim)
    assert {:ok, saved} = Recovery.load(c.id)
    assert saved.recovery.progress.model_attempts == 0
    assert {:ok, []} = ContextStore.list(c.id)
    assert DurableTools.stats(c.id).effects == 0
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
  end

  for {stage, cursor, attempts} <- [{:before_commit, 0, 3}, {:after_commit, 1, 2}] do
    test "model result crash #{stage} keeps cursor result and intent atomic", c do
      create(c)
      kill_at(c, :commit_hook, unquote(stage))
      assert {:ok, saved} = Recovery.load(c.id)
      assert saved.recovery.progress.cursor == unquote(cursor)
      assert saved.state.seq == unquote(cursor) + 1
      assert {:ok, prior} = ModelResultStore.list(c.id)
      assert length(prior) == unquote(cursor)
      assert {:ok, done} = Recovery.resume(c.id)
      assert done.state.status == :succeeded
      assert done.recovery.progress.cursor == 2
      assert done.recovery.progress.model_attempts == unquote(attempts)
      assert DurableTools.stats(c.id).effects == 1
      assert {:ok, results} = ModelResultStore.list(c.id)
      assert length(results) == 2
    end
  end

  test "success then death twice during recovery still produces one logical effect", c do
    create(c)
    assert {:ok, _} = Recovery.step(c.id)
    kill_at(c, :tool_hook, :after_effect)
    assert DurableTools.stats(c.id).effects == 1
    kill_at(c, :tool_hook, :after_effect)
    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert done.recovery.progress.model_attempts == 2
    assert %{effects: 1, attempts: 3, operations: 1} = DurableTools.stats(c.id)
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert Enum.map(operation.attempts, & &1.outcome) == ["prepared", "prepared", "completed"]
  end

  test "confirmed durable receipt is reused after a crash before kernel result acceptance", c do
    create(c)
    assert {:ok, _} = Recovery.step(c.id)
    kill_at(c, :tool_hook, :after_receipt)
    assert {:ok, [operation]} = DurableTools.list(c.id)
    assert operation.status == "completed"

    assert {:ok, done} =
             Recovery.resume(c.id,
               tool_hook: fn stage ->
                 if stage == :before_effect, do: flunk("confirmed effect must not execute")
               end
             )

    assert done.state.status == :succeeded
    assert DurableTools.stats(c.id).effects == 1
  end

  test "lost response pauses and explicit query records the original receipt", c do
    create(c, mock_response: :lost)
    assert {:ok, blocked} = Recovery.resume(c.id)
    assert blocked.state.status == :blocked
    assert blocked.recovery.progress.cursor == 1
    assert %{effects: 1, attempts: 1} = DurableTools.stats(c.id)
    assert {:ok, ^blocked} = Recovery.resume(c.id)
    assert {:ok, reconciled} = Recovery.reconcile(c.id)
    assert reconciled.state.status == :running
    assert reconciled.state.operations["once"].result.output.effect_index == 1
    assert {:ok, done} = Recovery.resume(c.id)
    assert done.state.status == :succeeded
    assert %{effects: 1, attempts: 2} = DurableTools.stats(c.id)
  end

  test "unqueryable target never resends an ambiguous prepared operation", c do
    create(c, mock_mode: :unqueryable)
    assert {:ok, _} = Recovery.step(c.id)
    kill_at(c, :tool_hook, :after_effect)
    assert {:ok, blocked} = Recovery.resume(c.id)
    assert blocked.state.status == :blocked
    assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)
    assert DurableTools.stats(c.id).effects == 1

    assert {:error, :invalid_reconciliation_evidence} =
             Recovery.reconcile(c.id, result: {:ok, "checked"})

    assert {:ok, _} =
             Recovery.reconcile(c.id,
               result: {:ok, "operator-confirmed"},
               evidence: "Receipt checked at target"
             )

    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "ambiguous file effect blocks instead of using matching content to infer success", c do
    file_call =
      {:call,
       %{
         operation_id: "file",
         tool: "file_write",
         arguments: %{
           "path" => "once.txt",
           "content" => "original effect",
           "expected_sha256" => "absent"
         }
       }}

    create(c, workspace: c.root, script: [file_call, {:final, "done"}])
    assert {:ok, _} = Recovery.step(c.id)
    kill_at(c, :tool_hook, :after_effect)
    path = Path.join(c.root, "once.txt")
    assert File.read!(path) == "original effect"
    File.write!(path, "independently changed")
    assert {:ok, blocked} = Recovery.resume(c.id)
    assert blocked.state.status == :blocked
    assert File.read!(path) == "independently changed"
    assert {:error, :reconciliation_required} = Recovery.reconcile(c.id)

    assert {:ok, _} =
             Recovery.reconcile(c.id,
               result: {:ok, %{"observed" => "operator-confirmed prior write"}},
               evidence: "Verified original write separately; preserve later edit"
             )

    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
    assert File.read!(path) == "independently changed"
  end

  test "output charged before a crash cannot be spent again after restart", c do
    create(c, script: [{:stream, [{:text_delta, "four"}, :done]}], max_output_bytes: 6)
    kill_at(c, :hook, :after_frame)
    assert {:ok, partial} = Recovery.load(c.id)
    assert partial.recovery.progress.output_bytes == 4
    assert partial.recovery.progress.cursor == 0
    assert {:ok, failed} = Recovery.resume(c.id)
    assert failed.state.terminal_reason == {:budget_exceeded, :output_bytes}
    assert failed.recovery.progress.output_bytes == 4
    assert failed.recovery.progress.model_attempts == 2
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "an exhausted attempt reservation stops repeated crash attempts", c do
    create(c, max_model_attempts: 1)
    kill_at(c, :hook, :after_input)
    assert {:ok, failed} = Recovery.resume(c.id)
    assert failed.state.terminal_reason == {:budget_exceeded, :model_attempts}
    assert failed.recovery.progress.model_attempts == 1
    assert failed.recovery.progress.cursor == 0
    assert {:ok, [_one_capture]} = ContextStore.list(c.id)
  end

  test "a complete candidate after the deadline is rejected inside the commit", c do
    create(c, script: [{:final, "candidate"}], model_timeout_ms: 100)

    assert {:ok, failed} =
             Recovery.step(c.id,
               hook: fn stage ->
                 if stage == :after_model, do: Process.sleep(120)
               end
             )

    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:budget_exceeded, :model_timeout}
    assert failed.recovery.progress.cursor == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "concurrent cancellation revokes a gated model candidate", c do
    create(c, script: [{:final, "candidate"}])
    parent = self()
    gate = make_ref()

    task =
      Task.async(fn ->
        Recovery.step(c.id,
          hook: fn stage ->
            if stage == :after_model do
              send(parent, {gate, :ready})
              receive do: ({^gate, :release} -> :ok)
            end
          end
        )
      end)

    assert_receive {^gate, :ready}, 5_000
    assert {:ok, cancelled} = Recovery.cancel(c.id)
    send(task.pid, {gate, :release})
    assert {:error, {:stale_sequence, 1, 2}} = Task.await(task)
    assert cancelled.state.status == :cancelled
    assert cancelled.recovery.progress.cursor == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, ^cancelled} = Recovery.resume(c.id)
  end

  test "call budget and incomplete streams keep the original safe failure semantics", c do
    for {opts, reason, index} <- [
          {[max_tool_calls: 0], {:budget_exceeded, :tool_calls}, 1},
          {[max_turns: 1], :turn_budget_exceeded, 2},
          {[script: [{:stream, [{:text_delta, "partial"}]}]], :incomplete_stream, 3}
        ] do
      case_context = %{c | id: "#{c.id}-#{index}"}
      create(case_context, opts)
      assert {:ok, failed} = Recovery.resume(case_context.id)
      assert failed.state.status == :failed
      assert failed.state.terminal_reason == reason
    end
  end

  test "cancellation stops a provider sleeping without emitting another frame", c do
    create(c,
      script: [{:stream, [{:sleep, 10_000}, {:text_delta, "late"}, :done]}],
      model_timeout_ms: 20_000
    )

    owner = self()
    gate = make_ref()

    task =
      Task.async(fn ->
        Recovery.step(c.id,
          hook: fn at ->
            if at == :after_input, do: send(owner, {gate, :started})
          end
        )
      end)

    assert_receive {^gate, :started}, 5_000
    assert {:ok, cancelled} = Recovery.cancel(c.id)
    assert cancelled.state.status == :cancelled
    assert {:error, _fenced} = Task.await(task, 1_000)
    assert Task.Supervisor.children(AgentSystemsLab.ProviderSupervisor) == []
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "tool deadline is rechecked after a pre-effect gate", c do
    create(c, run_timeout_ms: 200)
    assert {:ok, _} = Recovery.step(c.id)

    assert {:ok, failed} =
             Recovery.step(c.id,
               tool_hook: fn at ->
                 if at == :before_effect, do: Process.sleep(220)
               end
             )

    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:budget_exceeded, :run_timeout}
    assert DurableTools.stats(c.id).effects == 0
  end

  test "invalid manual reconciliation returns errors without replacing unknown", c do
    create(c, mock_mode: :unqueryable, mock_response: :lost)
    assert {:ok, blocked} = Recovery.resume(c.id)

    for value <- [nil, :ok, {}, {:unknown, :guess}, {:ok, 1, 2}] do
      assert {:error, :invalid_reconciliation_result} =
               Recovery.reconcile(c.id,
                 result: value,
                 evidence: "Must not turn malformed data into success"
               )
    end

    assert {:ok, saved} = Recovery.load(c.id)
    assert saved.state === blocked.state
    assert DurableTools.stats(c.id).effects == 1
  end

  test "durable-only invalid IDs and unsupported tools fail before creating an intent", c do
    for {id, tool, index} <- [
          {<<0>>, "mock_write", 1},
          {<<255>>, "mock_write", 2},
          {"id", "unknown", 3}
        ] do
      child = %{c | id: "#{c.id}-invalid-#{index}"}
      create(child, script: [{:call, %{operation_id: id, tool: tool, arguments: %{}}}])
      assert {:ok, failed} = Recovery.resume(child.id)
      assert failed.state.status == :failed
      assert failed.state.operations == %{}
      assert {:ok, []} = ModelResultStore.list(child.id)
      assert DurableTools.stats(child.id).effects == 0
    end
  end

  test "expiry while preparing input never starts the provider", c do
    create(c, model_timeout_ms: 100)

    assert {:ok, failed} =
             Recovery.step(c.id,
               hook: fn at ->
                 if at == :after_input, do: Process.sleep(120)
               end
             )

    assert failed.state.terminal_reason == {:budget_exceeded, :model_timeout}
    assert failed.recovery.progress.output_bytes == 0
    assert failed.recovery.progress.cursor == 0
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  defp verify_enrollment(id, :before_commit) do
    assert {:error, :not_found} = Recovery.load(id)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM lab_recovery WHERE run_id=$1", [id])
  end

  defp verify_enrollment(id, :after_commit) do
    assert {:ok, saved} = Recovery.load(id)
    assert saved.recovery.progress.cursor == 0
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(id)
  end
end
