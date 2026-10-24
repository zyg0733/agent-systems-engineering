defmodule AgentSystemsLab.RunServerObservabilityTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Observability, RunServer}
  alias AgentSystemsLab.Observability.Context

  setup do
    if is_nil(Process.whereis(AgentSystemsLab.Observability.Buffer)),
      do: assert({:ok, _} = Observability.restart())

    :ok
  end

  test "memory model/tool observations pair attempts without exporting business contents" do
    id = "memory-observe-" <> Ecto.UUID.generate()
    canary = "PRIVATE_MEMORY_PAYLOAD"

    script = [
      {:call, %{operation_id: "write", tool: "mock_write", arguments: %{"value" => canary}}},
      {:final, canary}
    ]

    server = start_supervised!({RunServer, run_id: id, input: canary, script: script})
    assert {:ok, final} = RunServer.run_until_pause(server)
    assert final.state.status == :succeeded
    assert final.state.output == canary
    assert final.tool_stats.effects == 1
    assert :ok = Observability.flush()
    events = Enum.filter(Observability.recent(), &(&1["correlation"]["run_id"] == id))
    assert length(Enum.filter(events, &(&1["event_name"] == "model_started"))) == 2

    for name <- ["model", "tool"] do
      starts = Enum.filter(events, &(&1["event_name"] == name <> "_started"))
      stops = Enum.filter(events, &(&1["event_name"] == name <> "_stopped"))
      assert starts != []

      assert Enum.sort(Enum.map(starts, & &1["span_id"])) ==
               Enum.sort(Enum.map(stops, & &1["span_id"]))

      assert Enum.all?(
               starts ++ stops,
               &(&1["trace_id"] == Context.trace_id(id) and
                   &1["parent_span_id"] == Context.root_span_id(id))
             )

      assert Enum.all?(stops, &is_integer(&1["measurements"]["duration_ms"]))
    end

    refute JSON.encode!(events) =~ canary
  end

  test "cancelling a real gated stream closes observation and preserves cancelled state" do
    id = "cancel-observe-" <> Ecto.UUID.generate()
    ref = make_ref()

    server =
      start_supervised!(
        {RunServer,
         run_id: id,
         input: "PRIVATE_CANCEL_INPUT",
         script: [{:stream, [{:text_delta, "PRIVATE_PARTIAL"}, {:gate, self(), ref}, :done]}]}
      )

    assert {:ok, _} = RunServer.start_stream(server)
    assert_receive {:scripted_gate, ^ref, worker}, 1000
    monitor = Process.monitor(worker)
    assert {:ok, cancelled} = RunServer.cancel(server)
    assert cancelled.state.status == :cancelled
    assert cancelled.state.output == nil
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert :ok = Observability.flush()

    stops =
      Enum.filter(
        Observability.recent(),
        &(&1["correlation"]["run_id"] == id and &1["event_name"] == "model_stopped")
      )

    assert [stop] = stops
    assert stop["attributes"]["outcome"] == "cancelled"
    refute JSON.encode!(stops) =~ "PRIVATE_"
    assert RunServer.snapshot(server) == cancelled
  end
end
