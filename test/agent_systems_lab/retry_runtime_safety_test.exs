defmodule AgentSystemsLab.RetryRuntimeSafetyTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    Context,
    DurableTools,
    IntentStore,
    Recovery,
    RecoveryStore,
    Repo,
    RetryStore,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec
  @moduletag :database

  setup do
    id = "retry-safety-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"]) end)
    %{id: id}
  end

  defp create(id, extra \\ []),
    do:
      Recovery.create_run(
        id,
        "Preserve retry facts",
        Keyword.merge([script: [{:final, "done"}], retry_policy: [base_delay_ms: 20]], extra)
      )

  test "retry enrollment rolls back with creation and survives lost acknowledgement", c do
    assert_raise RuntimeError, "before", fn ->
      create(c.id, hook: fn :before_commit -> raise "before" end)
    end

    assert {:error, :not_found} = Storage.load(c.id)

    assert_raise RuntimeError, "after", fn ->
      create(c.id,
        hook: fn
          :before_commit -> :ok
          :after_commit -> raise "after"
        end
      )
    end

    assert {:ok, saved} = Recovery.load(c.id)
    assert saved.recovery.retry_config.policy.base_delay_ms == 20
    assert saved.recovery.progress.model_attempts == 0
    assert {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(c.id)
  end

  test "changed retry fault plan fails its immutable hash", c do
    assert {:ok, original} = create(c.id)
    forged = %{original.recovery.retry_config | mock_transient_failures: 20}
    update_retry(c.id, forged)
    assert {:error, {:corrupt_recovery, :retry_config_hash_mismatch}} = Recovery.resume(c.id)
    assert {:ok, state} = Storage.load(c.id)
    assert state.state === original.state
    assert DurableTools.stats(c.id).effects == 0
  end

  test "unsupported sidecar versions fail before any attempt even with matching hash", c do
    assert {:ok, original} = create(c.id)

    for version <- [2, 1.0, nil] do
      future = %{original.recovery.retry_config | schema_version: version}
      update_retry(c.id, future)

      Repo.query!("UPDATE lab_recovery SET retry_config_sha256=$2 WHERE run_id=$1", [
        c.id,
        Context.hash(future)
      ])

      assert {:error, {:corrupt_recovery, {:unsupported_retry_config_version, ^version}}} =
               Recovery.step(c.id)
    end

    assert {:ok, []} = RetryStore.list(c.id)
  end

  test "attempt-specific scripts must have an existing durable cursor slot", c do
    assert {:error, :invalid_model_attempt_scripts} =
             create(c.id,
               model_attempt_scripts: %{1 => [{:final, "unreachable"}]}
             )

    assert {:error, :not_found} = Storage.load(c.id)
  end

  test "invalid deadline options cannot reserve or corrupt a model attempt", c do
    assert {:ok, original} = create(c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "deadline-test")

    for opts <- [
          [deadline_at_ms: -1],
          [deadline_at_ms: "later"],
          [other: 1],
          [deadline_at_ms: 1, deadline_at_ms: 2],
          :invalid
        ] do
      assert {:error, :invalid_model_attempt_options} =
               RecoveryStore.begin_model_attempt(claim, opts)
    end

    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged.recovery.progress === original.recovery.progress
  end

  test "a retry window elapsed after reservation cannot start a tool", c do
    call = {:call, %{operation_id: "once", tool: "mock_write", arguments: %{}}}

    assert {:ok, _} =
             create(c.id, script: [call, {:final, "done"}], retry_policy: [max_elapsed_ms: 100])

    assert {:ok, %{state: %{status: :waiting_tool}}} = Recovery.step(c.id)

    assert {:ok, failed} =
             Recovery.step(c.id,
               hook: fn at ->
                 if at == :after_retry_reserve, do: Process.sleep(120)
               end
             )

    assert failed.state.status == :failed
    assert failed.state.terminal_reason == {:budget_exceeded, :retry_elapsed}
    assert %{effects: 0, operations: 0, attempts: 0} = DurableTools.stats(c.id)
  end

  defp update_retry(id, value) do
    {:ok, bytes} = Codec.encode(value)
    Repo.query!("UPDATE lab_recovery SET retry_config_data=$2 WHERE run_id=$1", [id, bytes])
  end
end
