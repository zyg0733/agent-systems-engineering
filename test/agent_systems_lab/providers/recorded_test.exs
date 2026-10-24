defmodule AgentSystemsLab.Providers.RecordedTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Context, Recording, Stream}
  alias AgentSystemsLab.Providers.Recorded

  setup do
    context = %{input: "repair", run_id: "recorded-provider", turn_count: 0}
    next_context = %{context | turn_count: 1}
    first = record(context, 1, {:call, %{operation_id: "id", tool: "mock", arguments: %{x: {1}}}})
    second = record(next_context, 3, {:final, "done"})
    %{context: context, next_context: next_context, first: first, second: second}
  end

  test "reuses the next exact recorded input and response without skipping", c do
    assert {:ok, provider} = Recorded.new([c.first, c.second])
    assert {:ok, response, next} = Recorded.respond(c.context, provider)
    assert response === c.first.response
    assert next.cursor == 1
    assert next.requests === [c.context]
    assert {:ok, {:final, "done"}, finished} = Recorded.respond(c.next_context, next)
    assert finished.cursor == 2
    assert finished.requests === [c.context, c.next_context]
    assert {:error, :recordings_exhausted, ^finished} = Recorded.respond(c.context, finished)
  end

  test "mismatched inputs and invalid contexts do not advance or emit", c do
    assert {:ok, provider} = Recorded.new([c.first, c.second])

    assert {:error, :recorded_input_mismatch, ^provider} =
             Recorded.respond(c.next_context, provider)

    assert {:error, :invalid_context, ^provider} = Recorded.respond(nil, provider)

    assert {:error, :recorded_input_mismatch, ^provider} =
             Recorded.stream(c.next_context, provider, fn _frame -> flunk("must not emit") end)
  end

  test "stream is one complete frame preserving legacy tool arguments", c do
    assert {:ok, provider} = Recorded.new([c.first])
    parent = self()
    assert {:ok, next} = Recorded.stream(c.context, provider, &send_frame(parent, &1))
    assert next.cursor == 1
    assert_receive {:frame, {:complete, response}}
    assert response === c.first.response
    assert {:done, ^response, assembler} = Stream.push(Stream.new(), {:complete, response})
    assert {:ok, ^response} = Stream.finish(assembler)
    refute_received {:frame, _other}
  end

  test "stream respects consumer stop and validates callbacks", c do
    assert {:ok, provider} = Recorded.new([c.first])

    assert {:error, :cancelled, next} =
             Recorded.stream(c.context, provider, fn _frame -> {:error, :cancelled} end)

    assert next.cursor == 1

    assert {:error, {:invalid_emit_result, false}, _next} =
             Recorded.stream(c.context, provider, fn _frame -> false end)

    assert {:error, :invalid_emit, ^provider} = Recorded.stream(c.context, provider, nil)
  end

  test "constructor validates the entire list before any output is reused", c do
    for candidate <- [Map.put(c.first, :schema_version, 2), nil, %{}] do
      assert {:error, {:invalid_recording, 1}} = Recorded.new([c.first, candidate])
    end

    assert {:error, :invalid_recordings} = Recorded.new(nil)
    assert {:ok, empty} = Recorded.new([])
    assert {:error, :recordings_exhausted, ^empty} = Recorded.respond(%{}, empty)
  end

  defp record(context, seq, response) do
    {:ok, record} =
      Recording.new(%{
        context_id: nil,
        run_id: context.run_id,
        input_seq: seq,
        event_seq: seq + 1,
        provider: "scripted.v1",
        input_sha256: Context.hash(context),
        response: response
      })

    record
  end

  defp send_frame(parent, frame) do
    send(parent, {:frame, frame})
    :ok
  end
end
