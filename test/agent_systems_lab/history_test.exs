defmodule AgentSystemsLab.HistoryTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.{Checkpoint, History, Kernel}
  alias AgentSystemsLab.Kernel.Event
  alias AgentSystemsLab.Storage.Codec

  test "full and checkpoint paths reproduce every cut of a complete history" do
    {state, events} = history()

    for cut <- 0..length(events) do
      {prefix, tail} = Enum.split(events, cut)
      assert {:ok, checkpoint} = Checkpoint.new("history", prefix, max_turns: 7)
      assert checkpoint.last_seq == cut
      assert checkpoint.max_turns == 7
      assert :ok = Checkpoint.verify(checkpoint, prefix)
      assert {:ok, ^state} = History.from_checkpoint(checkpoint, tail)
    end

    assert {:ok, ^state} = History.rebuild("history", events, max_turns: 7)
  end

  test "empty checkpoints preserve a configured turn limit" do
    assert {:ok, checkpoint} = Checkpoint.new("empty", [], max_turns: 1)
    assert checkpoint.last_seq === 0
    assert checkpoint.state.status === :queued
    assert :ok = Checkpoint.verify(checkpoint, [])
    assert {:ok, state} = History.from_checkpoint(checkpoint, [])
    assert state.max_turns == 1
  end

  test "blocked and cancelled checkpoints retain uncertain tool facts" do
    {blocked, events} = history(:blocked)
    assert {:ok, checkpoint} = Checkpoint.new("history", events, max_turns: 7)
    assert {:ok, ^blocked} = History.from_checkpoint(checkpoint, [])
    assert blocked.operations["call-1"].status == :unknown
    assert {:ok, cancelled, [event]} = Kernel.dispatch(blocked, {:cancel, "operator"})
    assert {:ok, ^cancelled} = History.from_checkpoint(checkpoint, [event])
    assert {:ok, terminal} = Checkpoint.new("history", events ++ [event], max_turns: 7)
    assert terminal.state.operations === blocked.operations
    assert {:ok, ^cancelled} = History.from_checkpoint(terminal, [])
  end

  test "strict history rejects gaps duplicates order run ID and noncanonical events" do
    {_state, [first, second | rest] = events} = history()

    for invalid <- [
          tl(events),
          [first, first],
          [second, first],
          [%{first | run_id: "other"}],
          [%{first | seq: 1.0}],
          [%{first | data: %{input: "task", extra: true}}]
        ] do
      assert {:error, _reason} = History.rebuild("history", invalid, max_turns: 7)
    end

    assert {:error, _reason} =
             History.rebuild("history", [first, second | rest] ++ [first], max_turns: 7)
  end

  test "all schema versions are checked in full histories and checkpoint tails" do
    {_state, [first | tail]} = history()
    assert {:ok, checkpoint} = Checkpoint.new("history", [first], max_turns: 7)

    for version <- [2, 0, nil, 1.0, "1"] do
      assert {:error, {:unsupported_schema_version, ^version}} =
               History.rebuild("history", [%{first | schema_version: version}], max_turns: 7)

      [event | remaining] = tail

      assert {:error, {:unsupported_schema_version, ^version}} =
               History.from_checkpoint(checkpoint, [
                 %{event | schema_version: version} | remaining
               ])

      assert {:error, {:unsupported_checkpoint_schema_version, ^version}} =
               Checkpoint.validate(%{checkpoint | schema_version: version})
    end
  end

  test "malformed history containers return errors without crashing" do
    event = %Event{run_id: "history", seq: 1, type: :run_started, data: %{input: "task"}}

    for history <- [nil, %{}, "events", [event | :bad]] do
      assert {:error, {:invalid_history, ^history}} = History.rebuild("history", history)
      assert {:error, {:invalid_history, ^history}} = Checkpoint.new("history", history)
      assert {:ok, cp} = Checkpoint.new("history", [])
      assert {:error, {:invalid_history, ^history}} = History.from_checkpoint(cp, history)
    end
  end

  test "checkpoint fields hashes options and original prefix are all bound" do
    {_state, events} = history()
    assert {:ok, cp} = Checkpoint.new("history", events, max_turns: 7)

    for forged <- [
          Map.put(cp, :extra, true),
          Map.delete(cp, :state),
          %{cp | last_seq: cp.last_seq + 1},
          %{cp | last_seq: 1.0},
          %{cp | max_turns: 4},
          %{cp | run_id: "other"},
          %{cp | state: %{cp.state | output: "forged"}},
          %{cp | state_sha256: String.duplicate("0", 64)},
          %{cp | history_sha256: String.duplicate("0", 64)},
          %{cp | history_sha256: "invalid"}
        ] do
      assert {:error, _reason} = Checkpoint.verify(forged, events)
    end

    [first | tail] = events

    assert {:error, :checkpoint_history_mismatch} =
             Checkpoint.verify(cp, [%{first | data: %{input: "different"}} | tail])
  end

  test "a self-consistent forged state is rejected by journal verification" do
    {_state, events} = history()
    assert {:ok, cp} = Checkpoint.new("history", events, max_turns: 7)
    altered = %{cp.state | output: "forged, but structurally valid"}
    assert {:ok, hash} = Checkpoint.digest(altered)
    forged = %{cp | state: altered, state_sha256: hash}
    assert :ok = Checkpoint.validate(forged)
    assert {:ok, ^altered} = History.from_checkpoint(forged, [])
    assert {:error, :checkpoint_history_mismatch} = Checkpoint.verify(forged, events)
  end

  test "checkpoint tails cannot skip sequence cross runs or continue terminal state" do
    {_state, [first, second | rest] = events} = history()
    assert {:ok, cp} = Checkpoint.new("history", [first], max_turns: 7)
    assert {:error, {:invalid_event_sequence, 2, 3}} = History.from_checkpoint(cp, rest)

    assert {:error, {:run_id_mismatch, "history", "other"}} =
             History.from_checkpoint(cp, [%{second | run_id: "other"}])

    assert {:ok, terminal} = Checkpoint.new("history", events, max_turns: 7)

    event = %Event{
      run_id: "history",
      seq: terminal.last_seq + 1,
      type: :run_cancelled,
      data: %{reason: "late"}
    }

    assert {:error, {:terminal_run, :succeeded}} = History.from_checkpoint(terminal, [event])
  end

  test "codec version validation is strict even for float and malformed metadata" do
    assert {:ok, encoded} = Codec.encode(%{"safe" => true})

    for version <- [1.0, nil, false, 2, "1"] do
      assert {:error, {:unsupported_codec_version, ^version}} = Codec.decode(encoded, version)
    end
  end

  test "hashing validates inert terms and uses deterministic map order" do
    assert Checkpoint.digest(Map.new([{"z", 1}, {"a", 2}])) ===
             Checkpoint.digest(Map.new([{"a", 2}, {"z", 1}]))

    assert {:error, :unsupported_term} = Checkpoint.digest(self())
  end

  defp history(stop \\ :succeeded) do
    {:ok, state} = Kernel.new("history", max_turns: 7)

    commands = [
      {:start, "task"},
      {:model_response,
       {:call, %{operation_id: "call-1", tool: "read_file", arguments: %{"path" => "note.txt"}}}},
      {:tool_result, "call-1", {:unknown, %{"reason" => "lost receipt"}}}
    ]

    commands =
      if stop == :blocked,
        do: commands,
        else:
          commands ++
            [
              {:reconcile, "call-1", {:ok, %{"contents" => "confirmed fact"}}},
              {:model_response, {:final, "complete"}}
            ]

    Enum.reduce(commands, {state, []}, fn command, {current, events} ->
      {:ok, next, emitted} = Kernel.dispatch(current, command)
      {next, events ++ emitted}
    end)
  end
end
