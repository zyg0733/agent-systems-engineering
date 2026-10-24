defmodule AgentSystemsLab.StorageTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Kernel, Repo, Storage, StorageVerification}
  alias AgentSystemsLab.Storage.Codec

  # These are committed PostgreSQL integration tests. In particular, an outer
  # Sandbox transaction would invalidate both the commit and process-kill tests.
  @moduletag :database

  setup do
    run_id =
      "storage-test-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [run_id])
    end)

    {:ok, run_id: run_id}
  end

  test "creation commits the run, its first event, and one scheduling intent", %{run_id: id} do
    assert {:ok, snapshot} = Storage.create_run(id, "Read a note", max_turns: 2)
    assert snapshot.state.run_id == id
    assert snapshot.state.status == :running
    assert snapshot.state.seq == 1
    assert snapshot.state.max_turns == 2
    assert [%{type: :run_started, seq: 1, data: %{input: "Read a note"}}] = snapshot.events
    assert %{run_id: ^id, seq: 1, kind: "model", status: "pending"} = snapshot.intent
    assert counts(id) == [1, 1, 1, 1]

    assert {:ok, loaded} = Storage.load(id)
    assert loaded == snapshot
    assert {:ok, state} = Kernel.rebuild(id, loaded.events, max_turns: 2)
    assert state == loaded.state
    assert Enum.any?(Storage.pending_intents(), &(&1.run_id == id and &1.kind == "model"))
  end

  test "committed transitions replace the intent and preserve terms through replay", %{run_id: id} do
    assert {:ok, _snapshot} = Storage.create_run(id, "Read a note", max_turns: 2)

    assert {:ok, waiting} = Storage.dispatch(id, 1, {:model_response, {:call, tool_call()}})
    assert waiting.state.status == :waiting_tool
    assert waiting.intent.kind == "tool"
    assert waiting.intent.seq == 2
    assert counts(id) == [1, 2, 2, 1]

    result = {:unknown, %{"attempt" => 1, reason: :lost_response, detail: {"a", [1, :b]}}}
    assert {:ok, blocked} = Storage.dispatch(id, 2, {:tool_result, "read-1", result})
    assert blocked.state.status == :blocked
    assert blocked.intent.kind == "reconcile"
    assert blocked.intent.seq == 3

    verified = %{"metadata" => [nil, true, 42], contents: "a small note"}
    assert {:ok, running} = Storage.dispatch(id, 3, {:reconcile, "read-1", {:ok, verified}})
    assert running.state.status == :running
    assert running.state.operations["read-1"].result == verified
    assert running.intent.kind == "model"

    assert {:ok, finished} =
             Storage.dispatch(id, 4, {:model_response, {:final, "The note is small."}})

    assert finished.state.status == :succeeded
    assert finished.state.turn_count == 2
    assert finished.intent == nil
    assert counts(id) == [1, 5, 4, 0]

    assert {:ok, loaded} = Storage.load(id)
    assert loaded == finished
    assert Enum.map(loaded.events, & &1.seq) == [1, 2, 3, 4, 5]
    assert {:ok, state} = Kernel.rebuild(id, loaded.events, max_turns: 2)
    assert state == loaded.state
    refute Enum.any?(Storage.pending_intents(), &(&1.run_id == id))
  end

  test "failed and cancelled runs retain unresolved facts without pending work", %{run_id: id} do
    for {command, status} <- [fail: :failed, cancel: :cancelled] do
      assert {:ok, _snapshot} = Storage.create_run(id, "Read a note")
      assert {:ok, waiting} = Storage.dispatch(id, 1, {:model_response, {:call, tool_call()}})
      assert {:ok, terminal} = Storage.dispatch(id, 2, {command, :operator_decision})

      assert terminal.state.status == status
      assert terminal.state.pending_operation_id == "read-1"
      assert terminal.state.operations == waiting.state.operations
      assert terminal.intent == nil
      assert counts(id) == [1, 3, 2, 0]
      assert {:error, {:terminal_run, ^status}} = Storage.dispatch(id, 3, {:cancel, :again})
      assert {:ok, ^terminal} = Storage.load(id)

      delete_run(id)
    end
  end

  test "rejected commands and stale callers leave all three tables unchanged", %{run_id: id} do
    assert {:ok, original} = Storage.create_run(id, "Read a note")

    assert {:error, {:invalid_transition, :running, :tool_result}} =
             Storage.dispatch(id, 1, {:tool_result, "read-1", {:ok, "too early"}})

    assert {:error, {:stale_sequence, 0, 1}} =
             Storage.dispatch(id, 0, {:model_response, {:final, "stale"}})

    assert counts(id) == [1, 1, 1, 1]
    assert {:ok, ^original} = Storage.load(id)
  end

  test "duplicate run identifiers cannot create extra events or intents", %{run_id: id} do
    assert {:ok, original} = Storage.create_run(id, "Original", max_turns: 1)
    assert {:error, {:already_exists, ^id}} = Storage.create_run(id, "Duplicate", max_turns: 7)
    assert counts(id) == [1, 1, 1, 1]
    assert {:ok, ^original} = Storage.load(id)
  end

  test "unknown runs are absent and cannot acquire an event or intent", %{run_id: id} do
    assert {:error, :not_found} = Storage.load(id)
    assert {:error, :not_found} = Storage.dispatch(id, 0, {:cancel, :missing})
    assert counts(id) == [0, 0, 0, 0]
  end

  test "an outer transaction cannot turn the after_commit hook into an early acknowledgement", %{
    run_id: id
  } do
    assert {:ok,
            {{:error, :nested_transaction_not_supported},
             {:error, :nested_transaction_not_supported}}} =
             Repo.transaction(fn ->
               {
                 Storage.create_run(id, "Must not nest"),
                 Storage.dispatch(id, 0, {:cancel, :must_not_nest})
               }
             end)

    assert counts(id) == [0, 0, 0, 0]
  end

  test "an exception after all writes rolls back projection, event, and intent together", %{
    run_id: id
  } do
    hook = fn
      :before_commit -> raise "injected before COMMIT"
      :after_commit -> :ok
    end

    assert_raise RuntimeError, "injected before COMMIT", fn ->
      Storage.create_run(id, "Roll back creation", hook: hook)
    end

    assert counts(id) == [0, 0, 0, 0]
    assert {:ok, original} = Storage.create_run(id, "Roll back transition")

    assert_raise RuntimeError, "injected before COMMIT", fn ->
      Storage.dispatch(id, 1, {:model_response, {:call, tool_call()}}, hook: hook)
    end

    assert counts(id) == [1, 1, 1, 1]
    assert {:ok, ^original} = Storage.load(id)
  end

  test "the versioned codec preserves data and rejects active or malformed terms" do
    value = %{"result" => {:ok, [nil, true, 42, 3.5, %{path: "note.txt"}]}}
    assert {:ok, encoded} = Codec.encode(value)
    assert {:ok, ^value} = Codec.decode(encoded)
    assert {:error, {:unsupported_codec_version, 2}} = Codec.decode(encoded, 2)
    assert {:error, :invalid_payload} = Codec.decode(encoded <> <<0>>)
    assert {:error, :invalid_payload} = Codec.decode(<<0, 1, 2>>)

    compressed =
      :erlang.term_to_binary(
        {"AgentSystemsLab.Storage", 1, String.duplicate("x", 4_096)},
        [:compressed]
      )

    assert {:error, :compressed_payload} = Codec.decode(compressed)

    for value <- [self(), make_ref(), fn -> :ok end] do
      assert {:error, :unsupported_term} = Codec.encode(value)

      assert {:error, :unsupported_term} =
               Codec.decode(:erlang.term_to_binary({"AgentSystemsLab.Storage", 1, value}))
    end

    assert {:error, :unsupported_struct} = Codec.encode(%URI{scheme: "https"})
    assert {:error, :improper_list} = Codec.encode([1 | 2])

    too_deep = Enum.reduce(1..66, :leaf, fn _index, nested -> [nested] end)
    assert {:error, :payload_too_deep} = Codec.encode(too_deep)
  end

  test "a forged persisted projection is rejected before another transition", %{run_id: id} do
    assert {:ok, original} = Storage.create_run(id, "Original", max_turns: 3)
    assert {:ok, forged} = Codec.encode(%{original.state | input: "Rewritten outside the kernel"})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_runs SET state_data = $2 WHERE id = $1", [
      id,
      forged
    ])

    assert {:error, {:corrupt_storage, :projection_mismatch}} = Storage.load(id)

    assert {:error, {:corrupt_storage, :projection_mismatch}} =
             Storage.dispatch(id, 1, {:model_response, {:final, "continue"}})

    assert counts(id) == [1, 1, 1, 1]
  end

  test "an intent whose payload disagrees with replay is rejected", %{run_id: id} do
    assert {:ok, _snapshot} = Storage.create_run(id, "Original")
    assert {:ok, forged} = Codec.encode(%{operation_id: "invented"})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_intents SET payload = $2 WHERE run_id = $1",
      [id, forged]
    )

    assert {:error, {:corrupt_storage, :intent_mismatch}} = Storage.load(id)
    assert counts(id) == [1, 1, 1, 1]
  end

  test "PostgreSQL enforces sequence checks and the single pending intent invariant", %{
    run_id: id
  } do
    assert {:ok, original} = Storage.create_run(id, "Original")

    assert {:error, %{postgres: %{code: :check_violation}}} =
             Ecto.Adapters.SQL.query(Repo, "UPDATE lab_runs SET seq = -1 WHERE id = $1", [id])

    assert {:ok, ^original} = Storage.load(id)
    assert {:ok, waiting} = Storage.dispatch(id, 1, {:model_response, {:call, tool_call()}})

    assert {:error, %{postgres: %{code: :unique_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE lab_intents SET status = 'pending' WHERE run_id = $1 AND seq = 1",
               [id]
             )

    assert {:ok, ^waiting} = Storage.load(id)
    assert counts(id) == [1, 2, 2, 1]
  end

  test "two simultaneous callers with the same sequence commit exactly once", %{run_id: id} do
    assert {:ok, _snapshot} = Storage.create_run(id, "Choose one result")
    parent = self()
    ref = make_ref()

    workers =
      for output <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {ref, :ready, self()})

          receive do
            {^ref, :go} -> Storage.dispatch(id, 1, {:model_response, {:final, output}})
          end
        end)
      end

    for _worker <- workers do
      assert_receive {^ref, :ready, pid}, 1_000
      assert pid in Enum.map(workers, & &1.pid)
    end

    Enum.each(workers, &send(&1.pid, {ref, :go}))

    results = Enum.map(workers, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _snapshot}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:stale_sequence, 1, 2}}, &1)) == 1
    assert counts(id) == [1, 2, 1, 0]
    assert {:ok, loaded} = Storage.load(id)
    assert loaded.state.seq == 2
    assert loaded.state.output in ["first", "second"]
    assert loaded.intent == nil
  end

  for operation <- [:create, :dispatch] do
    test "killing a #{operation} caller before COMMIT rolls back without acknowledgement" do
      assert {:ok, evidence} = StorageVerification.crash_probe(:before_commit, unquote(operation))
      assert evidence.visible == false
      assert evidence.acknowledged == false
      assert evidence.exit_reason == :killed
      assert evidence.at_barrier == evidence.after_kill

      expected =
        if unquote(operation) == :create,
          do: %{runs: 0, events: 0, intents: 0, pending: 0},
          else: %{runs: 1, events: 1, intents: 1, pending: 1}

      assert evidence.after_kill == expected
      assert evidence.recovered_seq == if(unquote(operation) == :create, do: 1, else: 2)
    end

    test "killing a #{operation} caller after COMMIT preserves all rows without acknowledgement" do
      assert {:ok, evidence} = StorageVerification.crash_probe(:after_commit, unquote(operation))
      assert evidence.visible == true
      assert evidence.acknowledged == false
      assert evidence.exit_reason == :killed
      assert evidence.at_barrier == evidence.after_kill

      expected =
        if unquote(operation) == :create,
          do: %{runs: 1, events: 1, intents: 1, pending: 1},
          else: %{runs: 1, events: 2, intents: 2, pending: 1}

      assert evidence.after_kill == expected
      assert evidence.recovered_seq == if(unquote(operation) == :create, do: 1, else: 2)
    end
  end

  defp tool_call,
    do: %{operation_id: "read-1", tool: "read_file", arguments: %{path: "note.txt"}}

  defp counts(id) do
    %{rows: [counts]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM lab_runs WHERE id = $1),
          (SELECT count(*) FROM lab_events WHERE run_id = $1),
          (SELECT count(*) FROM lab_intents WHERE run_id = $1),
          (SELECT count(*) FROM lab_intents WHERE run_id = $1 AND status = 'pending')
        """,
        [id]
      )

    counts
  end

  defp delete_run(id),
    do: Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [id])
end
