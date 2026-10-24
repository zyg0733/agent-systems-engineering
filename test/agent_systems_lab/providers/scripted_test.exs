defmodule AgentSystemsLab.Providers.ScriptedTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Providers.Scripted

  doctest Scripted

  test "replays tool calls and final answers while recording contexts in order" do
    call = {:call, %{operation_id: "op-1", tool: "mock", arguments: %{value: "hello"}}}
    {:ok, state} = Scripted.new([call, {:final, "done"}])

    assert {:ok, ^call, next} = Scripted.respond(%{messages: ["first"]}, state)
    assert next.cursor == 1
    assert {:ok, {:final, "done"}, final} = Scripted.respond(%{messages: ["second"]}, next)
    assert final.cursor == 2
    assert final.requests == [%{messages: ["first"]}, %{messages: ["second"]}]
    assert state.cursor == 0
    assert state.requests == []
  end

  test "the same script and contexts produce identical states and results" do
    script = [{:error, :provider_unavailable}, {:final, "recovered"}]
    {:ok, state} = Scripted.new(script)

    replay = fn ->
      {:error, :provider_unavailable, first} = Scripted.respond(%{attempt: 1}, state)
      Scripted.respond(%{attempt: 2}, first)
    end

    assert replay.() === replay.()

    assert {:ok, {:final, "recovered"}, %{cursor: 2, requests: [%{attempt: 1}, %{attempt: 2}]}} =
             replay.()
  end

  test "exhaustion leaves state unchanged, including its request history" do
    {:ok, empty} = Scripted.new([])
    assert {:error, :script_exhausted, ^empty} = Scripted.respond(%{}, empty)

    {:ok, state} = Scripted.new([{:final, "done"}])
    {:ok, _, consumed} = Scripted.respond(%{request: 1}, state)
    assert {:error, :script_exhausted, ^consumed} = Scripted.respond(%{request: 2}, consumed)
  end

  test "validates every entry before the first request" do
    invalid_entries = [
      :final,
      {:final, 42},
      {:call, %{}},
      {:call, %{operation_id: "", tool: "mock", arguments: %{}}},
      {:call, %{operation_id: "op-1", tool: "", arguments: %{}}},
      {:call, %{operation_id: "op-1", tool: "mock", arguments: []}},
      {:call, %{operation_id: "op-1", tool: "mock", arguments: %{}, extra: true}}
    ]

    for entry <- invalid_entries do
      assert {:error, {:invalid_response, 1, ^entry}} = Scripted.new([{:final, "ok"}, entry])
    end

    assert {:error, :invalid_script} = Scripted.new(%{})
  end

  test "an invalid context neither advances nor crashes the provider" do
    {:ok, state} = Scripted.new([{:final, "done"}])
    assert {:error, :invalid_context, ^state} = Scripted.respond(nil, state)
    assert {:ok, {:final, "done"}, _} = Scripted.respond(%{}, state)
  end
end
