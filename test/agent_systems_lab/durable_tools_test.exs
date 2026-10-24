defmodule AgentSystemsLab.DurableToolsTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{DurableTools, IntentStore, Recovery, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.Result

  @moduletag :database

  setup do
    id = "durable-tools-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    root = Path.join(base, id)
    File.mkdir_p!(root)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  test "one operation has many deliveries and exactly one durable mock effect", c do
    {claim, operation} = waiting(c.id)
    assert {:ok, {:ok, receipt} = result} = DurableTools.execute(claim, operation)
    assert receipt.output.effect_index == 1
    assert {:ok, ^result} = DurableTools.execute(claim, operation)
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 2, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "completed"
    assert record.input == Map.take(operation, [:tool, :arguments])
    assert Enum.map(record.attempts, & &1.kind) == ["execution", "execution"]
    assert Enum.all?(record.attempts, &(&1.outcome == "completed"))
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "new-process")
    assert {:ok, ^result} = DurableTools.execute(next_claim, operation)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "lost response is unknown until a receipt lookup proves the result", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, {:unknown, unknown}} =
             DurableTools.execute(claim, operation, mock_response: :lost)

    assert unknown.output == :receipt_lost
    assert DurableTools.stats(c.id).effects == 1

    assert {:ok, blocked} =
             Storage.dispatch(
               c.id,
               claim.seq,
               {:tool_result, operation.operation_id, {:unknown, unknown}},
               claim: claim
             )

    assert blocked.state.status == :blocked
    assert {:ok, next_claim} = IntentStore.claim(c.id, "reconciler")
    assert {:ok, {:ok, result}} = DurableTools.reconcile(next_claim, operation)
    assert result.output.effect_index == 1
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 2, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert Enum.map(record.attempts, & &1.kind) == ["execution", "lookup"]
  end

  test "killed worker after external commit recovers the target receipt without another effect",
       c do
    {claim, operation} = waiting(c.id)
    kill_at(claim, operation, :after_effect)
    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 1, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
    assert record.result == nil
    assert record.attempts |> hd() |> Map.fetch!(:outcome) == "prepared"
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")
    assert {:ok, {:ok, result}} = DurableTools.reconcile(next_claim, operation)
    assert result.output.effect_index == 1
    assert DurableTools.stats(c.id).effects == 1
  end

  test "killed after receipt COMMIT reuses it across a replacement delivery", c do
    {claim, operation} = waiting(c.id)
    kill_at(claim, operation, :after_receipt)
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "completed"
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")
    assert {:ok, result} = DurableTools.execute(next_claim, operation)
    assert result === record.result
    assert DurableTools.stats(c.id).effects == 1
  end

  test "preparation survives a real kill before effect and idempotent target can safely execute",
       c do
    {claim, operation} = waiting(c.id)
    kill_at(claim, operation, :after_prepare)
    assert DurableTools.stats(c.id) == %{effects: 0, attempts: 1, operations: 1}
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")
    assert {:ok, {:ok, _receipt}} = DurableTools.execute(next_claim, operation)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "lookup absence does not invent a success or attempt another effect", c do
    {claim, operation} = waiting(c.id)
    kill_at(claim, operation, :after_prepare)
    assert {:error, :reconciliation_required} = DurableTools.reconcile(claim, operation)
    assert DurableTools.stats(c.id) == %{effects: 0, attempts: 2, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert List.last(record.attempts).kind == "lookup"
  end

  test "a confirmed pre-effect failure is reused without creating an effect", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, {:error, envelope} = result} =
             DurableTools.execute(claim, operation, mock_response: :fail_before_effect)

    assert envelope.output == :failed_before_effect
    assert {:ok, ^result} = DurableTools.execute(claim, operation)
    assert DurableTools.stats(c.id).effects == 0
  end

  test "a prepared file is never automatically executed again even when contents match", c do
    operation = %{
      operation_id: "write",
      tool: "file_write",
      arguments: %{
        "path" => "result.txt",
        "content" => "one write\n",
        "expected_sha256" => "absent"
      }
    }

    {claim, operation} = waiting(c.id, operation)
    kill_at(claim, operation, :after_effect, workspace: c.root)
    assert File.read!(Path.join(c.root, "result.txt")) == "one write\n"
    assert :ok = IntentStore.release(claim)
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")

    assert {:ok, {:unknown, envelope}} =
             DurableTools.execute(next_claim, operation, workspace: c.root)

    assert envelope.output == :receipt_unconfirmed

    assert {:error, :reconciliation_required} =
             DurableTools.reconcile(next_claim, operation, workspace: c.root)

    assert File.read!(Path.join(c.root, "result.txt")) == "one write\n"
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert length(record.attempts) == 3
  end

  test "trusted manual reconciliation stores evidence and a paired receipt without an effect",
       c do
    operation = %{
      operation_id: "write",
      tool: "file_write",
      arguments: %{
        "path" => "result.txt",
        "content" => "one write\n",
        "expected_sha256" => "absent"
      }
    }

    {claim, operation} = waiting(c.id, operation)
    kill_at(claim, operation, :after_prepare, workspace: c.root)
    refute File.exists?(Path.join(c.root, "result.txt"))
    result = Result.wrap({:error, :operator_verified_no_effect}, "write", "file_write")

    assert {:error, :invalid_reconciliation_evidence} =
             DurableTools.confirm(claim, operation, result, " ", workspace: c.root)

    assert {:ok, ^result} =
             DurableTools.confirm(
               claim,
               operation,
               result,
               "Operator inspected the private workspace and confirmed no file exists.",
               workspace: c.root
             )

    refute File.exists?(Path.join(c.root, "result.txt"))
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "completed"
    assert List.last(record.attempts).kind == "manual"
    assert List.last(record.attempts).evidence =~ "confirmed no file"
    assert {:ok, ^result} = DurableTools.execute(claim, operation, workspace: c.root)
  end

  test "unqueryable target does not turn diagnostic knowledge into a receipt", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, {:unknown, _}} =
             DurableTools.execute(claim, operation, mock_mode: :unqueryable, mock_response: :lost)

    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, {:unknown, _}} = DurableTools.execute(claim, operation, mock_mode: :unqueryable)

    assert {:error, :reconciliation_required} =
             DurableTools.reconcile(claim, operation, mock_mode: :unqueryable)

    assert DurableTools.stats(c.id).effects == 1
  end

  test "claim expiry or replacement at fault gates fences dispatch and receipt confirmation", c do
    {claim, operation} = waiting(c.id)

    hook = fn
      :before_effect -> :ok = IntentStore.release(claim)
      _ -> :ok
    end

    assert {:error, :stale_claim} = DurableTools.execute(claim, operation, hook: hook)
    assert DurableTools.stats(c.id).effects == 0
    assert {:ok, next_claim} = IntentStore.claim(c.id, "replacement")

    hook = fn
      :before_receipt -> :ok = IntentStore.release(next_claim)
      _ -> :ok
    end

    assert {:error, :stale_claim} = DurableTools.execute(next_claim, operation, hook: hook)
    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
    assert {:ok, third_claim} = IntentStore.claim(c.id, "third")
    assert {:ok, {:ok, _}} = DurableTools.reconcile(third_claim, operation)
    assert DurableTools.stats(c.id).effects == 1
  end

  test "crossing the durable run deadline at the effect gate prevents any new effect", c do
    operation = %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}
    assert {:ok, _} = Recovery.create_run(c.id, "bounded effect", script: [{:call, operation}])
    assert {:ok, waiting} = Recovery.step(c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "effect-worker")
    operation = Map.fetch!(waiting.state.operations, "charge")

    hook = fn
      :before_effect -> expire_run_deadline(c.id)
      _ -> :ok
    end

    assert {:error, {:budget_exceeded, :run_timeout}} =
             DurableTools.execute(claim, operation, hook: hook)

    assert DurableTools.stats(c.id) == %{effects: 0, attempts: 1, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
  end

  test "an already committed effect can be archived and looked up after the run deadline", c do
    operation = %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}

    assert {:ok, _} =
             Recovery.create_run(c.id, "archive completed effect", script: [{:call, operation}])

    assert {:ok, waiting} = Recovery.step(c.id)
    assert {:ok, claim} = IntentStore.claim(c.id, "effect-worker")
    operation = Map.fetch!(waiting.state.operations, "charge")

    hook = fn
      :after_effect -> expire_run_deadline(c.id)
      _ -> :ok
    end

    assert {:ok, result} = DurableTools.execute(claim, operation, hook: hook)
    assert {:ok, ^result} = DurableTools.reconcile(claim, operation)
    assert DurableTools.stats(c.id).effects == 1
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "completed"
  end

  test "same operation ID cannot change input, including exact numeric types", c do
    {claim, operation} = waiting(c.id)
    assert {:ok, _} = DurableTools.execute(claim, operation)
    changed = put_in(operation.arguments["amount"], 1.0)
    assert {:error, :operation_id_conflict} = DurableTools.execute(claim, changed)
    assert DurableTools.stats(c.id).effects == 1
    {other_claim, other_operation} = waiting(c.id <> "-other")
    assert {:ok, _} = DurableTools.execute(other_claim, other_operation)
    assert DurableTools.stats(c.id <> "-other").effects == 1
  end

  test "invalid schemas, executable terms, nested writes and forged pairing fail before effect",
       c do
    {claim, operation} = waiting(c.id)

    assert {:error, :invalid_operation_id} =
             DurableTools.execute(claim, %{operation | operation_id: <<0>>})

    assert {:error, :invalid_operation_id} =
             DurableTools.execute(claim, %{operation | operation_id: <<255>>})

    assert {:error, :unsupported_term} =
             DurableTools.execute(
               claim,
               put_in(operation.arguments["callback"], fn -> :unsafe end)
             )

    assert {:error, {:invalid_tool_result_envelope, "charge", "mock_write"}} =
             DurableTools.confirm(claim, operation, {:ok, %{unpaired: true}}, "checked")

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn ->
               DurableTools.execute(claim, operation)
             end)

    assert DurableTools.stats(c.id) == %{effects: 0, attempts: 0, operations: 0}
  end

  test "tampered inert inputs and receipt metadata fail closed", c do
    {claim, operation} = waiting(c.id)
    assert {:ok, _} = DurableTools.execute(claim, operation)
    {:ok, changed} = Codec.encode(%{tool: "mock_write", arguments: %{"amount" => 99}})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_operations SET input_data=$1 WHERE run_id=$2", [
      changed,
      c.id
    ])

    assert {:error, :operation_input_mismatch} = DurableTools.list(c.id)
    assert {:error, :operation_input_mismatch} = DurableTools.execute(claim, operation)
    assert DurableTools.stats(c.id).effects == 1
  end

  defp waiting(
         id,
         operation \\ %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}
       ) do
    {:ok, initial} = Storage.create_run(id, "one safe effect")

    {:ok, waiting} =
      Storage.dispatch(id, initial.state.seq, {:model_response, {:call, operation}})

    {:ok, claim} = IntentStore.claim(id, "worker")
    {claim, Map.fetch!(waiting.state.operations, operation.operation_id)}
  end

  defp expire_run_deadline(run_id) do
    row = Repo.get!(AgentSystemsLab.Storage.Recovery, run_id)
    {:ok, progress} = Codec.decode(row.progress_data, row.codec_version)
    {:ok, expired} = Codec.encode(%{progress | deadline_at_ms: RecoveryStore.now_ms() - 1})
    Repo.query!("UPDATE lab_recovery SET progress_data=$1 WHERE run_id=$2", [expired, run_id])
  end

  defp kill_at(claim, operation, target, opts \\ []) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn stage ->
          if stage == target do
            send(parent, {:at_gate, self()})
            receive do: (:continue -> :ok)
          end
        end

        DurableTools.execute(claim, operation, Keyword.put(opts, :hook, hook))
      end)

    assert_receive {:at_gate, ^pid}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end
end
