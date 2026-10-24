defmodule AgentSystemsLab.RunServerStreamTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Kernel, RunServer}

  defp start_run(context, script, extra \\ []) do
    start_supervised!(
      {RunServer,
       Keyword.merge(
         [run_id: Atom.to_string(context.test), input: "record", script: script],
         extra
       )}
    )
  end

  defp gate do
    ref = make_ref()
    {ref, {:gate, self(), ref}}
  end

  defp wait_at_gate(ref) do
    assert_receive {:scripted_gate, ^ref, worker}
    worker
  end

  defp release(worker, ref), do: send(worker, {:release, ref})

  defp finished(id, ref, status) do
    assert_receive {:agent_stream, ^id, ^ref, _seq, {:finished, ^status}}, 1_000
  end

  test "ordered live frames commit one final event and can be replayed", context do
    server = start_run(context, [{:stream, [{:text_delta, "你"}, {:text_delta, "好"}, :done]}])
    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    id = Atom.to_string(context.test)
    assert_receive {:agent_stream, ^id, ^request, 1, :started}
    assert_receive {:agent_stream, ^id, ^request, 2, {:text_delta, "你"}}
    assert_receive {:agent_stream, ^id, ^request, 3, {:text_delta, "好"}}
    assert_receive {:agent_stream, ^id, ^request, 4, :done}
    assert_receive {:agent_stream, ^id, ^request, 5, {:finished, :succeeded}}
    result = RunServer.snapshot(server)
    assert result.state.output == "你好"
    assert result.budget.output_bytes == 6
    assert Enum.map(result.events, & &1.type) == [:run_started, :run_succeeded]
    assert result.stream.active? == false
    assert Kernel.rebuild(id, result.events) == {:ok, result.state}
  end

  test "partial output is visible while snapshot and cancellation remain responsive", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [{:text_delta, "partial"}, gate, :done]}])
    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    worker_monitor = Process.monitor(worker)
    partial = RunServer.snapshot(server)
    assert partial.state.status == :running
    assert partial.state.seq == 1
    assert partial.provider.cursor == 0
    assert partial.stream.active?

    assert Enum.any?(partial.stream.events, fn {_seq, event} ->
             event == {:text_delta, "partial"}
           end)

    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.state.status == :cancelled
    assert cancelled.state.terminal_reason == :user_requested
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    finished(partial.state.run_id, request, :cancelled)
    release(worker, ref)
    assert RunServer.snapshot(server) == cancelled
  end

  test "step waits for a request but does not block other calls", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [gate, {:text_delta, "never"}, :done]}])
    caller = Task.async(fn -> RunServer.step(server) end)
    worker = wait_at_gate(ref)
    assert RunServer.snapshot(server).state.status == :running
    assert Task.yield(caller, 0) == nil
    assert {:ok, cancelled} = RunServer.cancel(server, :stop_now)
    assert Task.await(caller) == {:ok, cancelled}
    assert cancelled.state.terminal_reason == :stop_now
    refute Process.alive?(worker)
  end

  test "busy requests and business commands do not consume more budget", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [{:text_delta, "a"}, gate, :done]}])
    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    before = RunServer.snapshot(server)
    assert {:error, :busy} = RunServer.start_stream(server)
    assert {:error, :busy} = RunServer.step(server)
    assert {:error, :busy} = RunServer.command(server, {:model_response, {:final, "injected"}})
    assert {:error, :busy} = RunServer.reconcile_from_mock(server)
    assert RunServer.snapshot(server) == before
    release(worker, ref)
    finished(before.state.run_id, request, :succeeded)
    assert RunServer.snapshot(server).state.status == :succeeded
  end

  test "a done frame does not commit until the provider returns", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [{:text_delta, "ready"}, :done, gate]}])
    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    before = RunServer.snapshot(server)
    assert before.state.status == :running
    assert before.state.seq == 1
    assert before.provider.cursor == 0
    refute_receive {:agent_stream, _, ^request, _, {:finished, _}}
    release(worker, ref)
    finished(before.state.run_id, request, :succeeded)
    assert RunServer.snapshot(server).provider.cursor == 1
  end

  test "a provider error after done cannot commit its apparent answer", context do
    server =
      start_run(context, [
        {:stream, [{:text_delta, "not committed"}, :done, {:error, :late_error}]}
      ])

    assert {:ok, result} = RunServer.step(server)
    assert result.state.status == :failed
    assert result.state.output == nil
    assert result.state.terminal_reason == {:provider_error, :late_error}
    assert Enum.map(result.events, & &1.type) == [:run_started, :run_failed]
  end

  test "incomplete streams fail without authorizing a tool effect", context do
    server =
      start_run(context, [
        {:stream,
         [
           {:tool_start, %{operation_id: "op", tool: "mock_write"}},
           {:arguments_delta, "{\"value\":"}
         ]}
      ])

    assert {:ok, result} = RunServer.step(server)
    assert result.state.status == :failed
    assert result.state.terminal_reason == {:provider_error, :incomplete_stream}
    assert result.state.operations == %{}
    assert result.tool_stats.effects == 0
  end

  test "a complete tool stream records intent and waits for an explicit tool step", context do
    {ref, gate} = gate()

    server =
      start_run(context, [
        {:stream,
         [
           {:tool_start, %{operation_id: "op", tool: "mock_write"}},
           {:arguments_delta, "{\"value\":"},
           gate,
           {:arguments_delta, "\"yes\"}"},
           :done
         ]}
      ])

    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    before = RunServer.snapshot(server)
    assert before.state.operations == %{}
    assert before.tool_stats.effects == 0
    release(worker, ref)
    finished(before.state.run_id, request, :waiting_tool)
    intent = RunServer.snapshot(server)
    assert intent.state.operations["op"].arguments == %{"value" => "yes"}
    assert intent.tool_stats.effects == 0
    assert {:error, {:not_runnable, :waiting_tool}} = RunServer.start_stream(server)
    assert {:ok, result} = RunServer.step(server)
    assert result.tool_stats.effects == 1
  end

  test "cancellation during tool arguments cannot create an operation", context do
    {ref, gate} = gate()

    server =
      start_run(context, [
        {:stream,
         [
           {:tool_start, %{operation_id: "op", tool: "mock_write"}},
           {:arguments_delta, "{"},
           gate,
           {:arguments_delta, "}"},
           :done
         ]}
      ])

    assert {:ok, _} = RunServer.start_stream(server)
    _worker = wait_at_gate(ref)
    assert {:ok, result} = RunServer.cancel(server, :partial_tool)
    assert result.state.operations == %{}
    assert result.tool_stats.effects == 0
  end

  test "output byte budget rejects a UTF-8 chunk before it becomes accepted output", context do
    server = start_run(context, [{:stream, [{:text_delta, "你"}, :done]}], max_output_bytes: 2)
    assert {:ok, result} = RunServer.step(server)
    assert result.state.status == :failed
    assert result.state.terminal_reason == {:budget_exceeded, :output_bytes}
    assert result.budget.output_bytes == 0
    assert result.state.output == nil
  end

  test "stream frame budget counts done as a frame", context do
    server = start_run(context, [{:stream, [{:text_delta, "x"}, :done]}], max_stream_events: 1)
    assert {:ok, result} = RunServer.step(server)
    assert result.state.terminal_reason == {:budget_exceeded, :stream_events}
    assert result.budget.events == 1
    assert result.budget.output_bytes == 1
    assert result.tool_stats.effects == 0
  end

  test "output budget is cumulative across requests but frame budget resets", context do
    call = {:call, %{operation_id: "op", tool: "mock_write", arguments: %{}}}
    cost = byte_size(:erlang.term_to_binary(%{})) + byte_size("op") + byte_size("mock_write")

    server =
      start_run(context, [call, {:stream, [{:text_delta, "xx"}, :done]}],
        max_output_bytes: cost + 1,
        max_stream_events: 2
      )

    assert {:ok, intent} = RunServer.step(server)
    assert intent.budget.output_bytes == cost
    assert {:ok, _tool} = RunServer.step(server)
    assert {:ok, result} = RunServer.step(server)
    assert result.state.terminal_reason == {:budget_exceeded, :output_bytes}
    assert result.budget.output_bytes == cost
    assert result.tool_stats.effects == 1
  end

  test "zero tool-call budget fails before intent or effect", context do
    server =
      start_run(
        context,
        [{:call, %{operation_id: "op", tool: "mock_write", arguments: %{}}}],
        max_tool_calls: 0
      )

    assert {:ok, result} = RunServer.step(server)
    assert result.state.terminal_reason == {:budget_exceeded, :tool_calls}
    assert result.state.operations == %{}
    assert result.tool_stats.effects == 0
  end

  test "model deadline kills a gated worker and releases its waiting step caller", context do
    {ref, gate} = gate()

    server =
      start_run(context, [{:stream, [gate, {:text_delta, "late"}, :done]}], model_timeout_ms: 100)

    caller = Task.async(fn -> RunServer.step(server) end)
    worker = wait_at_gate(ref)
    monitor = Process.monitor(worker)
    assert {:ok, result} = Task.await(caller, 1_000)
    assert result.state.terminal_reason == {:budget_exceeded, :model_timeout}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "run deadline terminates a gated request", context do
    {ref, gate} = gate()

    server =
      start_run(context, [{:stream, [gate, :done]}], run_timeout_ms: 100, model_timeout_ms: 5_000)

    caller = Task.async(fn -> RunServer.step(server) end)
    _worker = wait_at_gate(ref)
    assert {:ok, result} = Task.await(caller, 1_000)
    assert result.state.terminal_reason == {:budget_exceeded, :run_timeout}
  end

  test "an expired actual deadline prevents tool execution even before its timer is handled",
       context do
    server =
      start_run(context, [{:call, %{operation_id: "op", tool: "mock_write", arguments: %{}}}])

    assert {:ok, _intent} = RunServer.step(server)

    :sys.replace_state(server, fn state ->
      %{state | deadline: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:ok, result} = RunServer.step(server)
    assert result.state.terminal_reason == {:budget_exceeded, :run_timeout}
    assert result.tool_stats.effects == 0
  end

  test "old chunks and timers cannot alter an active request", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [gate, {:text_delta, "ok"}, :done]}])
    assert :ok = RunServer.subscribe(server)
    assert {:ok, request} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    before = RunServer.snapshot(server)
    old = make_ref()

    assert {:error, :stale_request} =
             GenServer.call(server, {:stream_frame, old, worker, {:text_delta, "old"}})

    assert {:error, :stale_request} =
             GenServer.call(server, {:stream_frame, request, self(), {:text_delta, "fake"}})

    send(server, {:model_timeout, old})
    send(server, {old, {:ok, before.provider}})
    assert RunServer.snapshot(server) == before
    release(worker, ref)
    finished(before.state.run_id, request, :succeeded)
    assert RunServer.snapshot(server).state.output == "ok"
  end

  @tag capture_log: true
  test "provider process crashes become a failed run without killing its owner", context do
    server = start_run(context, [{:stream, [{:crash, :injected_crash}]}])
    assert {:ok, result} = RunServer.step(server)
    assert result.state.terminal_reason == {:provider_error, {:worker_exit, :injected_crash}}
    assert Process.alive?(server)
    assert result.tool_stats.effects == 0
  end

  test "killing the run owner cannot leave a gated provider alive", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [gate, :done]}])
    assert {:ok, _} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    monitor = Process.monitor(worker)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "repeated subscribe is idempotent and the latest preview is bounded", context do
    frames = List.duplicate({:text_delta, "x"}, 180) ++ [:done]
    server = start_run(context, [{:stream, frames}])
    assert :ok = RunServer.subscribe(server)
    assert :ok = RunServer.subscribe(server)
    assert {:ok, result} = RunServer.step(server)
    request = result.stream.request_id
    id = result.state.run_id
    assert_receive {:agent_stream, ^id, ^request, 1, :started}
    refute_receive {:agent_stream, ^id, ^request, 1, :started}
    assert length(result.stream.events) == 128
    assert hd(result.stream.events) |> elem(0) > 1
    assert result.state.output == String.duplicate("x", 180)
  end

  test "a frame after done fails instead of committing the assembled answer", context do
    server =
      start_run(context, [{:stream, [{:text_delta, "answer"}, :done, {:text_delta, "extra"}]}])

    assert {:ok, result} = RunServer.step(server)

    assert result.state.terminal_reason ==
             {:provider_error, {:invalid_stream, :stream_already_complete}}

    assert result.state.output == nil
    assert result.state.turn_count == 0
  end

  @tag capture_log: true
  test "a linked mock failure retains the original owner failure behavior", context do
    {ref, gate} = gate()
    server = start_run(context, [{:stream, [gate, :done]}])
    assert {:ok, _} = RunServer.start_stream(server)
    worker = wait_at_gate(ref)
    monitor = Process.monitor(server)
    worker_monitor = Process.monitor(worker)
    mock = :sys.get_state(server).mock
    Process.exit(mock, :kill)
    # Linked exit propagation crosses the owner and its task supervisor; its
    # contract is eventual cleanup, not delivery within ExUnit's default 100ms.
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 5_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 5_000
  end

  test "direct model commands obey output and tool budgets without consuming rejected commands",
       context do
    server = start_run(context, [], max_output_bytes: 2)
    before = RunServer.snapshot(server)
    assert {:error, _} = RunServer.command(server, {:model_response, {:call, %{bad: :shape}}})
    assert RunServer.snapshot(server) == before
    assert {:ok, result} = RunServer.command(server, {:model_response, {:final, "long"}})
    assert result.state.terminal_reason == {:budget_exceeded, :output_bytes}
    assert result.provider.cursor == 0
  end

  test "memory mode retains automatic provider diagnostics without codec normalization",
       context do
    reason = %{pid: self(), reference: make_ref(), exception: %ArgumentError{message: "fixture"}}
    server = start_run(context, [{:error, reason}])
    assert {:ok, failed} = RunServer.step(server)
    assert failed.state.terminal_reason == {:provider_error, reason}
    assert failed.state.status == :failed
    assert failed.provider.cursor == 1
  end

  test "dead subscribers are monitored and removed", context do
    server = start_run(context, [])
    owner = self()

    {subscriber, monitor} =
      spawn_monitor(fn ->
        :ok = RunServer.subscribe(server)
        send(owner, {:subscribed, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:subscribed, ^subscriber}
    assert Map.has_key?(:sys.get_state(server).subscribers, subscriber)
    send(subscriber, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    assert_unsubscribed(server, subscriber, 100)
  end

  defp assert_unsubscribed(_server, _subscriber, 0),
    do: flunk("subscriber monitor was not cleaned")

  defp assert_unsubscribed(server, subscriber, remaining) do
    if Map.has_key?(:sys.get_state(server).subscribers, subscriber),
      do: assert_unsubscribed(server, subscriber, remaining - 1),
      else: :ok
  end
end
