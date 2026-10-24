defmodule Mix.Tasks.Lab.Stream do
  use Mix.Task

  @shortdoc "Demonstrates model streaming, cancellation, or a byte budget"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [cancel: :boolean, budget: :boolean])

    if rest != [] or invalid != [] or (opts[:cancel] == true and opts[:budget] == true),
      do: Mix.raise("Usage: mix lab.stream [--cancel | --budget]")

    Mix.Task.run("app.start")
    gate = make_ref()

    script = [
      {:stream,
       [
         {:tool_start, %{operation_id: "stream-write-1", tool: "mock_write"}},
         {:arguments_delta, ~s({"key":"report",)},
         {:gate, self(), gate},
         {:arguments_delta, ~s("value":"hello from streaming"})},
         :done
       ]},
      {:stream, [{:text_delta, "Report "}, {:text_delta, "recorded."}, :done]}
    ]

    run_opts = [
      run_id: "stream-demo-#{System.unique_integer([:positive])}",
      input: "Record a report and confirm completion.",
      script: script,
      max_output_bytes: if(opts[:budget], do: 10, else: 65_536)
    ]

    {:ok, server} = AgentSystemsLab.start_run(run_opts)

    try do
      :ok = AgentSystemsLab.RunServer.subscribe(server)
      {:ok, request} = AgentSystemsLab.RunServer.start_stream(server)
      await_finished(server, request, gate, opts[:cancel] == true)

      if AgentSystemsLab.RunServer.snapshot(server).state.status == :waiting_tool do
        {:ok, _} = AgentSystemsLab.RunServer.step(server)
        {:ok, request} = AgentSystemsLab.RunServer.start_stream(server)
        await_finished(server, request, gate, false)
      end

      snapshot = AgentSystemsLab.RunServer.snapshot(server)

      Enum.each(snapshot.events, fn event ->
        Mix.shell().info("event #{event.seq} #{event.type}")
      end)

      {:ok, rebuilt} =
        AgentSystemsLab.Kernel.rebuild(snapshot.state.run_id, snapshot.events)

      Mix.shell().info(
        "status=#{snapshot.state.status} turns=#{snapshot.state.turn_count} " <>
          "requests=#{snapshot.tool_stats.requests} effects=#{snapshot.tool_stats.effects} " <>
          "output_bytes=#{snapshot.budget.output_bytes}"
      )

      Mix.shell().info("reason=#{inspect(snapshot.state.terminal_reason)}")

      Mix.shell().info(
        "rebuild_matches=#{rebuilt == snapshot.state}; partial frames are volatile"
      )
    after
      GenServer.stop(server)
    end
  end

  defp await_finished(server, request, gate, cancel?) do
    receive do
      {:scripted_gate, ^gate, worker} ->
        if cancel? do
          {:ok, _} = AgentSystemsLab.RunServer.cancel(server, :user_requested)
        else
          send(worker, {:release, gate})
        end

        await_finished(server, request, gate, false)

      {:agent_stream, _run_id, ^request, seq, event} ->
        Mix.shell().info("stream #{seq} #{inspect(event)}")

        case event do
          {:finished, _status} -> :ok
          _ -> await_finished(server, request, gate, cancel?)
        end
    after
      10_000 -> Mix.raise("Streaming demonstration timed out")
    end
  end
end
