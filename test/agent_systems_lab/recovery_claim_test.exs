defmodule AgentSystemsLab.RecoveryClaimTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{DurableTools, IntentStore, ModelResultStore, Recovery, Repo, Storage}
  @moduletag :database

  setup do
    id = "claimed-step-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"]) end)
    %{id: id}
  end

  test "one claimed delivery accepts one decision, with no second claim or tool execution", %{
    id: id
  } do
    assert {:ok, _} = Recovery.create_run(id, "one step", script: script(), priority: 7)
    assert {:ok, claim} = IntentStore.claim(id, "dispatcher")
    assert {:ok, waiting} = Recovery.execute_claim(claim)
    assert waiting.state.status == :waiting_tool
    assert waiting.state.seq == 2
    assert waiting.recovery.progress.model_attempts == 1
    assert waiting.recovery.progress.cursor == 1
    assert DurableTools.stats(id).effects == 0
    assert {:ok, [_]} = ModelResultStore.list(id)
    assert {:error, :stale_claim} = Recovery.execute_claim(claim)
    assert %{rows: [[7]]} = Repo.query!("SELECT priority FROM lab_runs WHERE id=$1", [id])
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(id)
    assert %{rows: [[7]]} = Repo.query!("SELECT priority FROM lab_runs WHERE id=$1", [id])
  end

  test "invalid and mismatched claims cannot reach the execution boundary", %{id: id} do
    assert {:ok, _} = Recovery.create_run(id, "reject stale", script: script())
    assert {:ok, claim} = IntentStore.claim(id, "dispatcher")

    for invalid <- [nil, %{}, %{claim | owner: "forged"}, %{claim | seq: 2}] do
      assert {:error, _} =
               Recovery.execute_claim(invalid, hook: fn _ -> flunk("invalid claim executed") end)
    end

    assert {:ok, unchanged} = Recovery.load(id)
    assert unchanged.recovery.progress.model_attempts == 0
    assert {:ok, []} = ModelResultStore.list(id)
    assert :ok = IntentStore.release(claim)
  end

  test "caller-owned claim remains held when a transient result schedules a future retry", %{
    id: id
  } do
    assert {:ok, _} =
             Recovery.create_run(id, "retry ownership",
               script: [{:final, "done"}],
               retry_policy: [base_delay_ms: 500, max_delay_ms: 500],
               model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "done"}]}
             )

    assert {:ok, claim} = IntentStore.claim(id, "dispatcher")
    assert {:ok, waiting} = Recovery.execute_claim(claim)
    assert waiting.recovery.retry.status == :waiting
    assert {:error, :intent_claimed} = IntentStore.claim(id, "other")
    assert {:error, {:retry_not_due, _}} = Recovery.execute_claim(claim)
    assert {:ok, renewed} = IntentStore.renew(claim)
    assert :ok = IntentStore.release(renewed)
  end

  test "invalid scheduling priority is rejected before creating durable state", %{id: id} do
    for {value, index} <- Enum.with_index([-1, 10, 1.5, "7", nil]) do
      run_id = id <> "-#{index}"
      assert {:error, :invalid_priority} = Recovery.create_run(run_id, "invalid", priority: value)
      assert {:error, :not_found} = Storage.load(run_id)
    end
  end

  test "claimed execution rejects an outer transaction and mutable delivery configuration", %{
    id: id
  } do
    assert {:ok, _} = Recovery.create_run(id, "preserve boundaries", script: script())
    assert {:ok, claim} = IntentStore.claim(id, "dispatcher")

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> Recovery.execute_claim(claim) end)

    assert {:error, :invalid_recovery_options} = Recovery.execute_claim(claim, script: [])
    assert {:error, :invalid_recovery_options} = Recovery.execute_claim(claim, lease_ms: 1_000)
    assert {:ok, unchanged} = Recovery.load(id)
    assert unchanged.recovery.progress.model_attempts == 0
    assert :ok = IntentStore.release(claim)
  end

  test "legacy persisted intents do not imply permission to execute a provider", %{id: id} do
    assert {:ok, _} = Storage.create_run(id, "legacy")
    assert {:ok, claim} = IntentStore.claim(id, "dispatcher")
    assert {:error, :run_not_resumable} = Recovery.execute_claim(claim)
    assert :ok = IntentStore.release(claim)
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 1}}},
      {:final, "done"}
    ]
end
