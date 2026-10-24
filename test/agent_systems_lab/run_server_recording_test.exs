defmodule AgentSystemsLab.RunServerRecordingTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Context, Recording, RunServer}

  defp start_run(context, script, opts \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [
           run_id: Atom.to_string(context.test),
           input: "record exact model outputs",
           script: script
         ],
         opts
       )}
    )
  end

  test "accepted tool and final results bind exact inputs and committed event sequences", c do
    call =
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{legacy: {:value, 7}}}}

    server = start_run(c, [call, {:final, "done"}])
    assert {:ok, planned} = RunServer.step(server)
    assert [first] = planned.recordings
    assert first.response === call
    assert first.context_id == nil
    assert first.input_seq == 1
    assert first.event_seq == 2
    assert first.input_sha256 == Context.hash(planned.context.context)
    assert first.response_sha256 == Context.hash(call)
    assert :ok = Recording.verify(first, hd(planned.provider.requests))
    assert planned.tool_stats.effects == 0

    assert {:ok, complete} = RunServer.run_until_pause(server)
    assert [^first, second] = complete.recordings
    assert second.response === {:final, "done"}
    assert second.input_seq == 3
    assert second.event_seq == 4
    assert :ok = Recording.verify(second, List.last(complete.provider.requests))
    assert complete.tool_stats.effects == 1
  end

  test "stream recording retains one assembled response rather than transport fragments", c do
    server = start_run(c, [{:stream, [{:text_delta, "你"}, {:text_delta, "好"}, :done]}])
    assert {:ok, complete} = RunServer.step(server)
    assert [%{response: {:final, "你好"}, event_seq: 2}] = complete.recordings
    assert Enum.map(complete.events, & &1.type) == [:run_started, :run_succeeded]
  end

  test "cancelling after done but before provider return cannot record the candidate", c do
    gate = make_ref()

    server =
      start_run(c, [{:stream, [{:text_delta, "candidate"}, :done, {:gate, self(), gate}]}])

    assert {:ok, _} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^gate, worker}
    assert RunServer.snapshot(server).recordings == []
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.recordings == []
    assert cancelled.state.output == nil
    refute Process.alive?(worker)
  end

  test "provider failures, partial streams, budget and schema rejections are not reusable", c do
    cases = [
      {[{:error, :offline}], []},
      {[{:stream, [{:text_delta, "partial"}]}], []},
      {[{:stream, [{:text_delta, "candidate"}, :done, {:error, :late_error}]}], []},
      {[{:final, "too long"}], [max_output_bytes: 1]},
      {[
         {:call,
          %{operation_id: "invalid", tool: "file_read", arguments: %{"path" => "x", "extra" => 1}}}
       ], []}
    ]

    for {{script, opts}, index} <- Enum.with_index(cases) do
      server = start_run(c, script, Keyword.put(opts, :run_id, "#{c.test}-#{index}"))
      assert {:ok, failed} = RunServer.step(server)
      assert failed.state.status == :failed
      assert failed.recordings == []
      assert failed.state.operations == %{}
      assert failed.tool_stats.effects == 0
      stop_supervised!(RunServer)
    end
  end

  test "manual model commands remain explicit imported facts without provider recordings", c do
    server = start_run(c, [])
    assert {:ok, done} = RunServer.command(server, {:model_response, {:final, "imported"}})
    assert done.state.status == :succeeded
    assert done.recordings == []
    assert done.provider.requests == []
  end

  test "legacy live memory arguments remain accepted with explicit unavailable recording", c do
    for {value, index} <- Enum.with_index([self(), make_ref(), fn -> :opaque end, %URI{}]) do
      call = {:call, %{operation_id: "once", tool: "mock_write", arguments: %{opaque: value}}}
      server = start_run(c, [call], run_id: "#{c.test}-#{index}")
      assert {:ok, planned} = RunServer.step(server)
      assert planned.state.status == :waiting_tool
      assert planned.state.operations["once"].arguments.opaque === value
      assert planned.recordings == []

      assert [%{input_seq: 1, event_seq: 2, reason: {:invalid_recording_payload, _}}] =
               planned.recording_errors

      assert {:ok, executed} = RunServer.step(server)
      assert executed.tool_stats.effects == 1
      assert executed.state.operations["once"].result.arguments.opaque === value
      stop_supervised!(RunServer)
    end
  end
end
