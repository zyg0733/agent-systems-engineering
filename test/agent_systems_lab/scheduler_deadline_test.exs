defmodule AgentSystemsLab.SchedulerDeadlineTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    DurableTools,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    RecoveryStore,
    Repo,
    Scheduler
  }

  @moduletag :database

  setup do
    id =
      "scheduler-deadline-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id = $1", [id]) end)
    %{id: id}
  end

  test "an ambiguous effect survives natural Run expiry as a visible manual reconciliation", c do
    create_waiting(c.id)
    crash_delivery(c.id, :after_effect)
    assert {:ok, [prepared]} = DurableTools.list(c.id)
    assert prepared.status == "prepared"
    assert %{effects: 1} = DurableTools.stats(c.id)
    wait_expiry(c.id)
    scheduler(run_ids: [c.id], recovery_options: [tool_hook: forbid_effect()])
    settled = settled(c.id)
    assert settled.state.status == :blocked
    assert settled.state.pending_operation_id == "once"
    assert settled.recovery.progress.model_attempts == 1
    assert {:ok, entry} = ReconciliationQueue.get(c.id)
    assert entry.safe_mode == :manual
    assert entry.journal_status == "unknown"
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert %{effects: 1, operations: 1} = DurableTools.stats(c.id)
    assert Enum.count(settled.events, &(&1.type == :tool_result_recorded)) == 1
    assert {:ok, [_accepted_model]} = ModelResultStore.list(c.id)
    Process.sleep(80)
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.state === settled.state
    assert %{effects: 1, operations: 1} = DurableTools.stats(c.id)
  end

  test "an already confirmed receipt is accepted after expiry without granting further execution",
       c do
    create_waiting(c.id)
    crash_delivery(c.id, :after_receipt)
    assert {:ok, [confirmed]} = DurableTools.list(c.id)
    assert confirmed.status == "completed"
    assert %{effects: 1} = DurableTools.stats(c.id)
    wait_expiry(c.id)
    scheduler(run_ids: [c.id], recovery_options: [tool_hook: forbid_effect()])
    settled = settled(c.id)
    assert settled.state.status == :failed
    assert settled.state.terminal_reason == {:budget_exceeded, :run_timeout}
    assert settled.state.operations["once"].status == :ok
    assert settled.state.operations["once"].result === elem(confirmed.result, 1)
    assert Enum.count(settled.events, &(&1.type == :tool_result_recorded)) == 1
    assert settled.recovery.progress.model_attempts == 1
    assert settled.recovery.progress.cursor == 1
    assert %{effects: 1, operations: 1} = DurableTools.stats(c.id)
    assert {:ok, [_accepted_model]} = ModelResultStore.list(c.id)
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
  end

  test "an expired tool with no preparation history fails without inventing a receipt or effect",
       c do
    create_waiting(c.id)
    assert %{effects: 0, operations: 0, attempts: 0} = DurableTools.stats(c.id)
    wait_expiry(c.id)
    scheduler(run_ids: [c.id], recovery_options: [tool_hook: forbid_effect()])
    settled = settled(c.id)
    assert settled.state.status == :failed
    assert settled.state.terminal_reason == {:budget_exceeded, :run_timeout}
    assert settled.state.operations["once"].status == :pending
    refute Enum.any?(settled.events, &(&1.type == :tool_result_recorded))
    assert %{effects: 0, operations: 0, attempts: 0} = DurableTools.stats(c.id)
    assert {:ok, []} = DurableTools.list(c.id)
    assert {:ok, [_accepted_model]} = ModelResultStore.list(c.id)
    assert {:ok, []} = ReconciliationQueue.list(run_id: c.id)
  end

  defp create_waiting(id) do
    assert {:ok, _} =
             Recovery.create_run(id, "Preserve target facts across deadline expiry",
               script: [
                 {:call,
                  %{operation_id: "once", tool: "mock_write", arguments: %{"amount" => 1}}},
                 {:final, "must not request this after the deadline"}
               ],
               mock_mode: :unqueryable,
               run_timeout_ms: 800,
               retry_policy: [
                 max_attempts: 3,
                 base_delay_ms: 50,
                 max_delay_ms: 100,
                 max_elapsed_ms: 5_000,
                 tool_timeout_ms: 2_000
               ]
             )

    assert {:ok, current} = Recovery.step(id)
    assert current.state.status == :waiting_tool
    assert current.recovery.progress.model_attempts == 1
  end

  defp crash_delivery(id, boundary) do
    parent = self()

    hook = fn stage ->
      if stage == boundary do
        send(parent, {:deadline_gate, self()})
        receive do: (:continue -> :ok)
      end
    end

    scheduler = scheduler(run_ids: [id], recovery_options: [tool_hook: hook])
    assert_receive {:deadline_gate, tool}, 2_000
    [%{worker: worker, executor: executor}] = Scheduler.status(scheduler).active
    refs = for pid <- Enum.uniq([worker, executor, tool]), do: {Process.monitor(pid), pid}
    Process.exit(worker, :kill)
    # Stop polling before the old lease can expire. A different instance will
    # discover this intent only after both natural deadlines have elapsed.
    assert :ok = Scheduler.stop(scheduler)
    for {ref, pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _reason}, 1_000)
    assert {:ok, saved} = Recovery.load(id)
    assert saved.state.status == :waiting_tool
    assert is_binary(saved.intent.claim_token)
  end

  defp wait_expiry(id) do
    assert {:ok, saved} = Recovery.load(id)

    due =
      if saved.intent.claim_expires_at,
        do:
          max(
            saved.recovery.progress.deadline_at_ms,
            DateTime.to_unix(saved.intent.claim_expires_at, :millisecond)
          ),
        else: saved.recovery.progress.deadline_at_ms

    wait_until(due + 5)
    assert RecoveryStore.now_ms() > due
  end

  defp wait_until(due) do
    remaining = due - RecoveryStore.now_ms()

    if remaining > 0 do
      Process.sleep(min(remaining, 50))
      wait_until(due)
    end
  end

  defp scheduler(opts) do
    opts =
      Keyword.merge(
        [workers: 1, poll_interval_ms: 10, lease_ms: 300, renew_interval_ms: 50],
        opts
      )

    assert {:ok, pid} = Scheduler.start_link(opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Scheduler.stop(pid) end)
    pid
  end

  defp settled(id, left \\ 300)

  defp settled(_id, 0), do: flunk("background delivery did not settle")

  defp settled(id, left) do
    assert {:ok, current} = Recovery.load(id)

    if current.state.status in [:blocked, :failed, :succeeded],
      do: current,
      else:
        (
          Process.sleep(10)
          settled(id, left - 1)
        )
  end

  defp forbid_effect do
    fn stage ->
      if stage in [:before_effect, :after_effect],
        do: flunk("expired continuation must not invoke the target")
    end
  end
end
