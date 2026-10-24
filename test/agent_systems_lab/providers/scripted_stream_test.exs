defmodule AgentSystemsLab.Providers.ScriptedStreamTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Providers.Scripted

  test "legacy responses emit a single complete frame with unchanged arguments" do
    call = {:call, %{operation_id: "op-1", tool: "mock_write", arguments: %{nested: {:ok, 7}}}}
    {:ok, provider} = Scripted.new([call])
    owner = self()

    assert {:ok, next} =
             Scripted.stream(%{request: 1}, provider, fn event ->
               send(owner, {:frame, event})
               :ok
             end)

    assert_received {:frame, {:complete, ^call}}
    refute_received {:frame, _}
    assert next.cursor == 1
    assert next.requests == [%{request: 1}]
    assert provider.cursor == 0
  end

  test "frames are synchronous and the next frame waits for its callback ACK" do
    {:ok, provider} =
      Scripted.new([{:stream, [{:text_delta, "one"}, {:text_delta, "two"}, :done]}])

    owner = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Scripted.stream(%{}, provider, fn event ->
          send(owner, {:frame, event, self()})
          receive do: ({:ack, ^ref} -> :ok)
        end)
      end)

    assert_receive {:frame, {:text_delta, "one"}, worker}
    assert Task.yield(task, 0) == nil
    refute_received {:frame, {:text_delta, "two"}, _}
    send(worker, {:ack, ref})
    assert_receive {:frame, {:text_delta, "two"}, ^worker}
    send(worker, {:ack, ref})
    assert_receive {:frame, :done, ^worker}
    send(worker, {:ack, ref})
    assert {:ok, %{cursor: 1}} = Task.await(task)
  end

  test "fixture gates identify the worker and are never emitted" do
    owner = self()
    gate = make_ref()

    frames = [
      {:text_delta, "before"},
      {:gate, owner, gate},
      {:sleep, 0},
      {:text_delta, "after"},
      :done
    ]

    {:ok, provider} = Scripted.new([{:stream, frames}])

    task =
      Task.async(fn ->
        Scripted.stream(%{}, provider, fn event ->
          send(owner, {:frame, event})
          :ok
        end)
      end)

    assert_receive {:scripted_gate, ^gate, worker}
    assert_received {:frame, {:text_delta, "before"}}
    refute_received {:frame, {:text_delta, "after"}}
    assert Task.yield(task, 0) == nil
    send(worker, {:release, gate})
    assert {:ok, %{cursor: 1}} = Task.await(task)
    assert_received {:frame, {:text_delta, "after"}}
    assert_received {:frame, :done}
    refute_received {:frame, {:gate, _, _}}
    refute_received {:frame, {:sleep, _}}
  end

  test "callback cancellation stops delivery immediately and consumes just one response" do
    {:ok, provider} =
      Scripted.new([{:stream, [{:text_delta, "partial"}, :done]}, {:final, "next"}])

    owner = self()

    assert {:error, :cancelled, next} =
             Scripted.stream(%{turn: 1}, provider, fn event ->
               send(owner, {:frame, event})
               {:error, :cancelled}
             end)

    assert_received {:frame, {:text_delta, "partial"}}
    refute_received {:frame, :done}
    assert next.cursor == 1
    assert next.requests == [%{turn: 1}]
    assert {:ok, {:final, "next"}, %{cursor: 2}} = Scripted.respond(%{turn: 2}, next)
  end

  test "a provider can fail after done and the callback result must still be checked" do
    {:ok, provider} =
      Scripted.new([{:stream, [{:text_delta, "draft"}, :done, {:error, :lost_ack}]}])

    owner = self()

    assert {:error, :lost_ack, %{cursor: 1}} =
             Scripted.stream(%{}, provider, fn frame ->
               send(owner, {:frame, frame})
               :ok
             end)

    assert_received {:frame, {:text_delta, "draft"}}
    assert_received {:frame, :done}
    refute_received {:frame, {:error, _}}
  end

  test "a crash control exits the worker without emitting a crash frame" do
    {:ok, provider} = Scripted.new([{:stream, [{:crash, :injected}]}])
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Scripted.stream(%{}, provider, fn frame ->
          send(owner, {:frame, frame})
          :ok
        end)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :injected}
    refute_received {:frame, _}
  end

  test "streaming emits malformed sequences for runtime validation and respond rejects them" do
    scripts = [
      [{:text_delta, "partial"}],
      [:done, {:text_delta, "late"}],
      [{:arguments_delta, "{}"}],
      [{:tool_start, %{operation_id: "", tool: "mock_write"}}, :done]
    ]

    for frames <- scripts do
      assert {:ok, provider} = Scripted.new([{:stream, frames}])
      assert {:ok, %{cursor: 1}} = Scripted.stream(%{}, provider, fn _frame -> :ok end)
      assert {:error, _reason, %{cursor: 1}} = Scripted.respond(%{}, provider)
    end
  end

  test "respond can assemble streamed final answers and tools while retaining its old API" do
    frames = [
      {:tool_start, %{operation_id: "op-1", tool: "mock_write"}},
      {:arguments_delta, ~s({"value":)},
      {:arguments_delta, ~s("hello"})},
      :done
    ]

    {:ok, provider} = Scripted.new([{:stream, frames}, {:stream, [{:text_delta, "done"}, :done]}])

    assert {:ok, {:call, %{arguments: %{"value" => "hello"}}}, next} =
             Scripted.respond(%{}, provider)

    assert {:ok, {:final, "done"}, %{cursor: 2}} = Scripted.respond(%{}, next)
  end

  test "errors consume a response; invalid context, emit, and exhaustion do not" do
    {:ok, provider} = Scripted.new([{:error, :offline}, {:final, "ok"}])
    emit = fn _frame -> flunk("must not emit") end
    assert {:error, :invalid_context, ^provider} = Scripted.stream(nil, provider, emit)
    assert {:error, :invalid_emit, ^provider} = Scripted.stream(%{}, provider, :invalid)
    assert {:error, :offline, next} = Scripted.stream(%{turn: 1}, provider, emit)
    assert next.cursor == 1
    assert {:ok, final} = Scripted.stream(%{turn: 2}, next, fn _ -> :ok end)
    assert {:error, :script_exhausted, ^final} = Scripted.stream(%{turn: 3}, final, emit)
  end

  test "invalid callback results are reported and stop subsequent delivery" do
    {:ok, provider} = Scripted.new([{:stream, [{:text_delta, "a"}, :done]}])

    assert {:error, {:invalid_emit_result, :unexpected}, %{cursor: 1}} =
             Scripted.stream(%{}, provider, fn _ -> :unexpected end)
  end

  test "constructor rejects invalid frame shapes before running anything" do
    for frames <- [
          :invalid,
          [{:text_delta, 42}],
          [{:tool_start, %{}}],
          [{:arguments_delta, nil}],
          [{:sleep, -1}],
          [{:gate, self(), :not_a_reference}],
          [:unknown]
        ] do
      entry = {:stream, frames}
      assert {:error, {:invalid_response, 0, ^entry}} = Scripted.new([entry])
    end
  end
end
