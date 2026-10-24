defmodule AgentSystemsLab.KernelTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Kernel
  alias AgentSystemsLab.Kernel.{Event, State}

  doctest AgentSystemsLab.Kernel

  test "a new run is queued, empty, and bounded" do
    assert {:ok, state} = Kernel.new("run-1")
    assert state == %State{run_id: "run-1", max_turns: 4}
    assert {:ok, ^state} = Kernel.rebuild("run-1", [])
    assert {:ok, %State{max_turns: 2}} = Kernel.new("run-1", max_turns: 2)
  end

  test "damaged event structs are rejected before reading missing fields" do
    {:ok, state} = Kernel.new("run-1")
    event = %Event{run_id: "run-1", seq: 1, type: :run_started, data: %{input: "hello"}}

    for damaged <- [
          Map.delete(event, :seq),
          Map.delete(event, :schema_version),
          Map.put(event, :extra, true)
        ] do
      assert {:error, {:invalid_event, ^damaged}} = Kernel.apply_event(state, damaged)
      assert {:error, {:invalid_event, ^damaged}} = Kernel.rebuild("run-1", [damaged])
    end
  end

  test "invalid run configuration is rejected without crashing" do
    for id <- [nil, "", :run, 1] do
      assert {:error, {:invalid_run_id, ^id}} = Kernel.new(id)
    end

    for max_turns <- [0, -1, 1.0, nil, "4"] do
      assert {:error, {:invalid_max_turns, ^max_turns}} =
               Kernel.new("run-1", max_turns: max_turns)
    end

    for opts <- [nil, %{}, [:max_turns], [extra: 1], [max_turns: 1, max_turns: 2]] do
      assert {:error, {:invalid_options, ^opts}} = Kernel.new("run-1", opts)
    end

    assert {:error, {:invalid_history, :not_a_list}} = Kernel.rebuild("run-1", :not_a_list)
  end

  test "two model turns form a complete deterministic tool trace" do
    call = tool_call("read-1")

    commands = [
      {:start, "Read the note and summarize it"},
      {:model_response, {:call, call}},
      {:tool_result, "read-1", {:ok, "a small note"}},
      {:model_response, {:final, "The note is small."}}
    ]

    {state, events} = run_commands(commands)

    assert state.status == :succeeded
    assert state.seq == 4
    assert state.turn_count == 2
    assert state.input == "Read the note and summarize it"
    assert state.output == "The note is small."
    assert state.pending_operation_id == nil

    assert state.operations["read-1"] == %{
             operation_id: "read-1",
             tool: "read_file",
             arguments: %{path: "note.txt"},
             status: :ok,
             result: "a small note"
           }

    assert Enum.map(events, & &1.type) == [
             :run_started,
             :tool_requested,
             :tool_result_recorded,
             :run_succeeded
           ]

    assert Enum.map(events, & &1.seq) == [1, 2, 3, 4]
    assert Enum.all?(events, &(&1.run_id == "run-1" and &1.schema_version == 1))
    assert {:ok, ^state} = Kernel.rebuild("run-1", events)
    assert run_commands(commands) == {state, events}
  end

  test "a final answer consumes one turn and may contain an empty string" do
    {state, _events} = run_commands([{:start, ""}, {:model_response, {:final, ""}}])
    assert state.status == :succeeded
    assert state.turn_count == 1
    assert state.output == ""
  end

  test "queued runs must start before model or tool commands" do
    {:ok, state} = Kernel.new("run-1")

    for command <- [
          {:model_response, {:final, "too early"}},
          {:model_response, {:call, tool_call("read-1")}},
          {:tool_result, "read-1", {:ok, :value}},
          {:reconcile, "read-1", {:ok, :value}}
        ] do
      assert {:error, {:invalid_transition, :queued, _command_name}} =
               Kernel.dispatch(state, command)
    end

    assert state.seq == 0
    assert state.status == :queued
  end

  test "malformed commands and inputs are rejected" do
    {:ok, queued} = Kernel.new("run-1")
    assert {:error, {:invalid_input, 42}} = Kernel.dispatch(queued, {:start, 42})
    assert {:error, {:invalid_command, :surprise}} = Kernel.dispatch(queued, :surprise)

    {running, _events} = run_commands([{:start, "input"}])

    assert {:error, {:invalid_transition, :running, :start}} =
             Kernel.dispatch(running, {:start, "again"})

    for response <- [{:final, nil}, :unknown, {:text, "hi"}] do
      assert {:error, {:invalid_model_response, ^response}} =
               Kernel.dispatch(running, {:model_response, response})
    end

    for call <- [
          nil,
          %{},
          %{operation_id: "", tool: "read_file", arguments: %{}},
          %{operation_id: "op", tool: "", arguments: %{}},
          %{operation_id: "op", tool: "read_file", arguments: []},
          %{operation_id: 1, tool: "read_file", arguments: %{}},
          Map.put(tool_call("op"), :hidden_field, true)
        ] do
      assert {:error, {:invalid_tool_call, ^call}} =
               Kernel.dispatch(running, {:model_response, {:call, call}})
    end
  end

  test "one pending operation prevents overlapping model responses" do
    {waiting, _events} =
      run_commands([{:start, "input"}, {:model_response, {:call, tool_call("read-1")}}])

    assert waiting.status == :waiting_tool
    assert waiting.pending_operation_id == "read-1"

    for response <- [{:call, tool_call("read-2")}, {:final, "too early"}] do
      assert {:error, {:invalid_transition, :waiting_tool, :model_response}} =
               Kernel.dispatch(waiting, {:model_response, response})
    end

    assert {:error, {:invalid_transition, :waiting_tool, :reconcile}} =
             Kernel.dispatch(waiting, {:reconcile, "read-1", {:ok, :value}})
  end

  test "a tool result must match the pending operation and have a supported outcome" do
    {waiting, _events} =
      run_commands([{:start, "input"}, {:model_response, {:call, tool_call("read-1")}}])

    assert {:error, {:unexpected_operation_id, "read-1", "read-2"}} =
             Kernel.dispatch(waiting, {:tool_result, "read-2", {:ok, :value}})

    for result <- [:ok, {:success, "value"}, {:ok}, {:ok, 1, 2}] do
      assert {:error, {:invalid_tool_result, ^result}} =
               Kernel.dispatch(waiting, {:tool_result, "read-1", result})
    end
  end

  test "tool errors return control to the model without failing the run" do
    {running, events} =
      run_commands([
        {:start, "input"},
        {:model_response, {:call, tool_call("read-1")}},
        {:tool_result, "read-1", {:error, :not_found}}
      ])

    assert running.status == :running
    assert running.pending_operation_id == nil
    assert running.turn_count == 1
    assert running.operations["read-1"].status == :error
    assert running.operations["read-1"].result == :not_found
    assert {:ok, ^running} = Kernel.rebuild("run-1", events)

    assert {:ok, %{status: :succeeded, turn_count: 2}, [_event]} =
             Kernel.dispatch(running, {:model_response, {:final, "The file is missing."}})
  end

  test "duplicate operation IDs and duplicate tool completions are rejected" do
    {running, _events} =
      run_commands([
        {:start, "input"},
        {:model_response, {:call, tool_call("read-1")}},
        {:tool_result, "read-1", {:ok, "value"}}
      ])

    assert {:error, {:duplicate_operation_id, "read-1"}} =
             Kernel.dispatch(running, {:model_response, {:call, tool_call("read-1")}})

    assert {:error, {:invalid_transition, :running, :tool_result}} =
             Kernel.dispatch(running, {:tool_result, "read-1", {:ok, "value"}})

    assert running.seq == 3
    assert running.turn_count == 1
  end

  test "unknown outcomes block progress until an explicit successful reconciliation" do
    {blocked, events} = unknown_run()

    assert blocked.status == :blocked
    assert blocked.pending_operation_id == "read-1"
    assert blocked.operations["read-1"].status == :unknown
    assert blocked.operations["read-1"].result == :connection_lost
    assert {:ok, ^blocked} = Kernel.rebuild("run-1", events)

    for command <- [
          {:model_response, {:final, "guess"}},
          {:model_response, {:call, tool_call("read-2")}},
          {:tool_result, "read-1", {:ok, "late response"}}
        ] do
      assert {:error, {:invalid_transition, :blocked, _command_name}} =
               Kernel.dispatch(blocked, command)
    end

    assert {:error, {:unexpected_operation_id, "read-1", "other"}} =
             Kernel.dispatch(blocked, {:reconcile, "other", {:ok, "value"}})

    assert {:error, {:invalid_tool_result, {:unknown, :still_uncertain}}} =
             Kernel.dispatch(blocked, {:reconcile, "read-1", {:unknown, :still_uncertain}})

    assert {:ok, running, [reconciled]} =
             Kernel.dispatch(blocked, {:reconcile, "read-1", {:ok, "verified value"}})

    assert running.status == :running
    assert running.turn_count == 1
    assert running.pending_operation_id == nil
    assert running.operations["read-1"].status == :ok
    assert running.operations["read-1"].result == "verified value"
    assert reconciled.type == :tool_reconciled
    assert {:ok, ^running} = Kernel.rebuild("run-1", events ++ [reconciled])

    assert {:error, {:invalid_transition, :running, :reconcile}} =
             Kernel.dispatch(running, {:reconcile, "read-1", {:ok, "verified value"}})
  end

  test "reconciliation may establish failure and let the model decide the next step" do
    {blocked, events} = unknown_run()

    assert {:ok, running, [reconciled]} =
             Kernel.dispatch(blocked, {:reconcile, "read-1", {:error, :confirmed_not_executed}})

    assert running.status == :running
    assert running.operations["read-1"].status == :error
    assert running.operations["read-1"].result == :confirmed_not_executed
    assert {:ok, ^running} = Kernel.rebuild("run-1", events ++ [reconciled])
  end

  test "the final model response counts toward the exact turn budget" do
    commands = [
      {:start, "input"},
      {:model_response, {:call, tool_call("read-1")}},
      {:tool_result, "read-1", {:ok, "value"}},
      {:model_response, {:final, "done"}}
    ]

    {state, events} = run_commands(commands, max_turns: 2)
    assert state.status == :succeeded
    assert state.turn_count == state.max_turns
    assert {:ok, ^state} = Kernel.rebuild("run-1", events, max_turns: 2)
    assert {:error, {:turn_budget_exhausted, 1}} = Kernel.rebuild("run-1", events, max_turns: 1)
  end

  test "exhaustion rejects another model response without inventing success or losing tool data" do
    {state, events} =
      run_commands(
        [
          {:start, "input"},
          {:model_response, {:call, tool_call("read-1")}},
          {:tool_result, "read-1", {:ok, "value"}}
        ],
        max_turns: 1
      )

    for response <- [{:final, "done"}, {:call, tool_call("read-2")}] do
      assert {:error, {:turn_budget_exhausted, 1}} =
               Kernel.dispatch(state, {:model_response, response})
    end

    assert state.status == :running
    assert state.output == nil
    assert state.seq == 3
    assert state.operations["read-1"].result == "value"
    assert {:ok, ^state} = Kernel.rebuild("run-1", events, max_turns: 1)

    assert {:ok, %{status: :failed, turn_count: 1}, [_event]} =
             Kernel.dispatch(state, {:fail, :turn_budget_exhausted})
  end

  test "fail and cancel are allowed from every nonterminal status and keep unresolved facts" do
    {:ok, queued} = Kernel.new("run-1")
    {running, _events} = run_commands([{:start, "input"}])

    {waiting, _events} =
      run_commands([{:start, "input"}, {:model_response, {:call, tool_call("read-1")}}])

    {blocked, _events} = unknown_run()

    for state <- [queued, running, waiting, blocked],
        {command, expected_status} <- [fail: :failed, cancel: :cancelled] do
      assert {:ok, terminal, [event]} = Kernel.dispatch(state, {command, :operator_decision})
      assert terminal.status == expected_status
      assert terminal.terminal_reason == :operator_decision
      assert terminal.turn_count == state.turn_count
      assert terminal.operations == state.operations
      assert terminal.pending_operation_id == state.pending_operation_id
      assert {:ok, ^terminal} = Kernel.apply_event(state, event)
    end
  end

  test "all terminal states reject every further command and event" do
    {success, _events} = run_commands([{:start, "input"}, {:model_response, {:final, "done"}}])
    {:ok, initial} = Kernel.new("run-1")
    {:ok, failure, _events} = Kernel.dispatch(initial, {:fail, :reason})
    {:ok, cancelled, _events} = Kernel.dispatch(initial, {:cancel, :reason})

    for state <- [success, failure, cancelled] do
      for command <- [
            {:start, "again"},
            {:model_response, {:final, "again"}},
            {:tool_result, "op", {:ok, "again"}},
            {:reconcile, "op", {:ok, "again"}},
            {:fail, :again},
            {:cancel, :again}
          ] do
        assert {:error, {:terminal_run, status}} = Kernel.dispatch(state, command)
        assert status == state.status
      end

      event = %Event{
        run_id: state.run_id,
        seq: state.seq + 1,
        type: :run_cancelled,
        data: %{reason: :again}
      }

      assert {:error, {:terminal_run, _status}} = Kernel.apply_event(state, event)
    end
  end

  test "replay checks identity, sequence, schema, event type, and payload" do
    {_state, [started]} = run_commands([{:start, "input"}])

    assert {:error, {:run_id_mismatch, "run-1", "other"}} =
             Kernel.rebuild("run-1", [%{started | run_id: "other"}])

    for sequence <- [0, 2, -1, 1.0, "1"] do
      assert {:error, {:invalid_event_sequence, 1, ^sequence}} =
               Kernel.rebuild("run-1", [%{started | seq: sequence}])
    end

    for version <- [0, 2, 1.0, "1", nil] do
      assert {:error, {:unsupported_schema_version, ^version}} =
               Kernel.rebuild("run-1", [%{started | schema_version: version}])
    end

    assert {:error, {:unknown_event_type, :invented}} =
             Kernel.rebuild("run-1", [%{started | type: :invented}])

    for data <- [nil, [], %{}, %{input: "input", extra: true}] do
      assert {:error, {:invalid_event_data, :run_started}} =
               Kernel.rebuild("run-1", [%{started | data: data}])
    end

    assert {:error, {:invalid_input, 12}} =
             Kernel.rebuild("run-1", [%{started | data: %{input: 12}}])

    assert {:error, {:invalid_event, %{type: :run_started}}} =
             Kernel.rebuild("run-1", [%{type: :run_started}])

    incomplete_event = Map.delete(started, :seq)

    assert {:error, {:invalid_event, ^incomplete_event}} =
             Kernel.rebuild("run-1", [incomplete_event])
  end

  test "replaying a duplicate or missing event fails at its first sequence mismatch" do
    {_state, [started, requested, completed, finished]} =
      run_commands([
        {:start, "input"},
        {:model_response, {:call, tool_call("read-1")}},
        {:tool_result, "read-1", {:ok, "value"}},
        {:model_response, {:final, "done"}}
      ])

    assert {:error, {:invalid_event_sequence, 2, 1}} =
             Kernel.rebuild("run-1", [started, started, requested])

    assert {:error, {:invalid_event_sequence, 2, 3}} =
             Kernel.rebuild("run-1", [started, completed, finished])
  end

  test "forged events cannot bypass command transitions or duplicate operation protection" do
    {_state, [started, requested, completed]} =
      run_commands([
        {:start, "input"},
        {:model_response, {:call, tool_call("read-1")}},
        {:tool_result, "read-1", {:ok, "value"}}
      ])

    premature_success = %Event{
      run_id: "run-1",
      seq: 1,
      type: :run_succeeded,
      data: %{output: "forged"}
    }

    assert {:error, {:invalid_transition, :queued, :model_response}} =
             Kernel.rebuild("run-1", [premature_success])

    assert {:error, {:invalid_transition, :waiting_tool, :model_response}} =
             Kernel.rebuild("run-1", [started, requested, %{premature_success | seq: 3}])

    assert {:error, {:duplicate_operation_id, "read-1"}} =
             Kernel.rebuild("run-1", [started, requested, completed, %{requested | seq: 4}])

    assert {:error, {:unexpected_operation_id, "read-1", "other"}} =
             Kernel.rebuild("run-1", [
               started,
               requested,
               %{completed | data: %{operation_id: "other", result: {:ok, "value"}}}
             ])

    forged_reconciliation = %{completed | type: :tool_reconciled}

    assert {:error, {:invalid_transition, :waiting_tool, :reconcile}} =
             Kernel.rebuild("run-1", [started, requested, forged_reconciliation])
  end

  test "corrupted state values are rejected at the public boundary" do
    {:ok, state} = Kernel.new("run-1")

    for corrupted <- [
          %{state | status: :invented},
          %{state | seq: -1},
          %{state | max_turns: 0},
          %{state | turn_count: 1},
          %{state | operations: []},
          %{state | operations: %{"bad" => :not_an_operation}},
          %{state | pending_operation_id: "missing"},
          %{state | input: "already started"},
          Map.delete(state, :status),
          Map.put(state, :unexpected_field, true)
        ] do
      assert {:error, {:invalid_state, ^corrupted}} =
               Kernel.dispatch(corrupted, {:start, "input"})
    end

    assert {:error, {:invalid_state, :not_a_state}} =
             Kernel.dispatch(:not_a_state, {:start, "hi"})

    assert {:error, {:invalid_state, nil}} = Kernel.apply_event(nil, nil)
  end

  test "a matrix of valid histories preserves invariants and replays every prefix" do
    for max_turns <- 1..4, outcome <- [:ok, :error, :unknown] do
      tool_commands =
        if max_turns == 1 do
          []
        else
          Enum.flat_map(1..(max_turns - 1), fn index ->
            operation_id = "read-#{index}"
            request = {:model_response, {:call, tool_call(operation_id)}}
            result = {:tool_result, operation_id, {outcome, {:value, index}}}

            if outcome == :unknown,
              do: [request, result, {:reconcile, operation_id, {:ok, {:verified, index}}}],
              else: [request, result]
          end)
        end

      commands = [{:start, "input"}] ++ tool_commands ++ [{:model_response, {:final, "done"}}]
      {:ok, initial} = Kernel.new("run-1", max_turns: max_turns)

      {final, _history} =
        Enum.reduce(commands, {initial, []}, fn command, {state, history} ->
          assert {:ok, next, [event]} = Kernel.dispatch(state, command)
          assert_invariants(next)
          history = history ++ [event]
          assert {:ok, ^next} = Kernel.rebuild("run-1", history, max_turns: max_turns)
          assert event.seq == length(history)
          {next, history}
        end)

      assert final.status == :succeeded
      assert final.turn_count == max_turns
      assert map_size(final.operations) == max_turns - 1
    end
  end

  defp tool_call(operation_id),
    do: %{operation_id: operation_id, tool: "read_file", arguments: %{path: "note.txt"}}

  defp unknown_run do
    run_commands([
      {:start, "input"},
      {:model_response, {:call, tool_call("read-1")}},
      {:tool_result, "read-1", {:unknown, :connection_lost}}
    ])
  end

  defp run_commands(commands, opts \\ []) do
    {:ok, initial} = Kernel.new("run-1", opts)

    Enum.reduce(commands, {initial, []}, fn command, {state, history} ->
      assert {:ok, next, [event]} = Kernel.dispatch(state, command)
      assert_invariants(next)
      {next, history ++ [event]}
    end)
  end

  defp assert_invariants(state) do
    assert state.seq >= state.turn_count
    assert state.turn_count >= 0
    assert state.turn_count <= state.max_turns

    unresolved =
      for {id, operation} <- state.operations,
          operation.status in [:pending, :unknown],
          do: id

    assert length(unresolved) <= 1

    case state.pending_operation_id do
      nil -> assert unresolved == []
      id -> assert unresolved == [id]
    end

    if state.status == :waiting_tool,
      do: assert(state.operations[state.pending_operation_id].status == :pending)

    if state.status == :blocked,
      do: assert(state.operations[state.pending_operation_id].status == :unknown)

    if state.status == :succeeded do
      assert is_binary(state.output)
      assert is_nil(state.pending_operation_id)
    end
  end
end
