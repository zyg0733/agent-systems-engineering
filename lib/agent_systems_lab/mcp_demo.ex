defmodule AgentSystemsLab.MCPDemo do
  @moduledoc "Owned, offline MCP wire and durable recovery evidence; never replays an unknown call."
  alias AgentSystemsLab.{
    DurableTools,
    IntentStore,
    MCP,
    MCPFixture,
    RebuildAudit,
    ReconciliationQueue,
    Recovery,
    Scheduler,
    Storage
  }

  alias AgentSystemsLab.MCP.{Connection, Policy}

  @stdio ~w(handshake_call fragmented_stdio stderr discovery_pages schema_drift unauthorized_tool invalid_arguments version_mismatch rpc_error tool_error timeout_cancel malformed wrong_id disconnected file_policy explicit_cancel caller_crash late_reply)
  @durable ~w(durable_receipt_reuse durable_effect_drop)

  def cases, do: @stdio ++ @durable

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolation(opts),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week16-mcp")),
         :ok <- create_output(output) do
      context = %{
        output: output,
        namespace: "w16-mcp-" <> Ecto.UUID.generate(),
        memory: Keyword.get(opts, :memory, false)
      }

      expected = if context.memory, do: @stdio, else: cases()

      write_json(Path.join(output, "manifest.json"), %{
        namespace: context.namespace,
        expected_cases: expected
      })

      write_report(context, [], nil)
      execute(expected, [], context, opts)
    end
  end

  defp execute([], completed, context, _opts) do
    report = write_report(context, completed, nil)
    {:ok, %{output_dir: context.output, report: report}}
  end

  defp execute([name | rest], completed, context, opts) do
    result =
      try do
        progress(opts, name, length(completed), :starting, context)
        directory = Path.join(context.output, name)
        File.mkdir!(directory)
        workspace = Path.join(directory, "workspace")
        File.mkdir!(workspace)
        fixture = Map.merge(context, %{name: name, directory: directory, workspace: workspace})
        summary = verify(name, fixture)
        summary = Map.merge(%{"case" => name, "passed" => true}, summary)
        write_json(Path.join(directory, "summary.json"), summary)
        progress(opts, name, length(completed) + 1, :passed, context)
        {:ok, summary}
      rescue
        error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        completed = completed ++ [summary]
        write_report(context, completed, nil)
        execute(rest, completed, context, opts)

      {:error, reason} ->
        report = write_report(context, completed, %{"case" => name, "reason" => reason})
        {:error, {:mcp_verification_failed, %{output_dir: context.output, report: report}}}
    end
  end

  defp verify(name, fixture)
       when name in ~w(handshake_call fragmented_stdio stderr discovery_pages) do
    mode =
      %{
        "handshake_call" => "normal",
        "fragmented_stdio" => "fragment",
        "stderr" => "stderr",
        "discovery_pages" => "pages"
      }[name]

    {:ok, result} = invoke(fixture, mode, "echo", %{"text" => "owned MCP receipt"})

    check(
      result["content"] == [%{"type" => "text", "text" => "owned MCP receipt"}],
      "echo response differs"
    )

    trace = trace(fixture)
    phases = Enum.map(trace, & &1["phase"])

    check(
      Enum.take(phases, 3) == ["start", "initialize", "initialized"],
      "handshake order differs"
    )

    calls = Enum.filter(trace, &(&1["phase"] == "call"))

    check(
      length(calls) == 1 and hd(calls)["request_id"] == result["mcp"]["request_id"],
      "wire response pairing differs"
    )

    lists = Enum.count(trace, &(&1["phase"] == "list"))
    check(lists == if(mode == "pages", do: 2, else: 1), "discovery page count differs")

    %{
      "status" => "succeeded",
      "request_id" => result["mcp"]["request_id"],
      "discovery_pages" => lists,
      "cleanup" => result["transport"]
    }
  end

  defp verify(name, fixture) when name in ~w(schema_drift version_mismatch) do
    {:error, reason} = invoke(fixture, name, "echo", %{"text" => "never sent"})
    check(call_count(fixture) == 0, "invalid discovery/version sent tools/call")
    %{"status" => "rejected_before_call", "reason" => safe(reason), "tools_call_count" => 0}
  end

  defp verify(name, fixture) when name in ~w(unauthorized_tool invalid_arguments) do
    remote = if name == "unauthorized_tool", do: "not_approved", else: "echo"

    args =
      if name == "invalid_arguments", do: %{"text" => "hello", "network" => "allow"}, else: %{}

    {:error, reason} = invoke(fixture, "normal", remote, args)
    check(trace(fixture) == [], "invalid authority/arguments started a server")
    %{"status" => "rejected_before_start", "reason" => safe(reason), "tools_call_count" => 0}
  end

  defp verify(name, fixture) when name in ~w(rpc_error tool_error) do
    result = invoke(fixture, "normal", name, %{})
    check(call_count(fixture) == 1, "fixture error did not follow actual call")

    case {name, result} do
      {"rpc_error", {:error, %{"type" => "mcp_rpc_error", "code" => -32602}}} -> :ok
      {"tool_error", {:error, %{"type" => "mcp_tool_error"}}} -> :ok
      _ -> raise "RPC and tool error mapping differs: #{inspect(result)}"
    end

    %{"status" => "confirmed_error", "error" => safe(elem(result, 1))}
  end

  defp verify(name, fixture) when name in ~w(timeout_cancel malformed wrong_id disconnected) do
    mode =
      if name == "timeout_cancel",
        do: "timeout",
        else: if(name == "disconnected", do: "disconnect", else: name)

    {:unknown, details} =
      invoke(fixture, mode, "echo", %{"text" => "uncertain"}, request_timeout_ms: 80)

    check(call_count(fixture) == 1, "ambiguous operation was not sent exactly once")

    if name == "timeout_cancel" do
      [call] = Enum.filter(trace(fixture), &(&1["phase"] == "call"))

      check(
        Enum.any?(
          trace(fixture),
          &(&1["phase"] == "cancelled" and &1["request_id"] == call["request_id"])
        ),
        "timeout did not send matching cancellation"
      )
    end

    %{"status" => "unknown", "details" => details, "tools_call_count" => 1}
  end

  defp verify("file_policy", fixture) do
    canary = Path.join(fixture.directory, "outside-canary")
    File.write!(canary, "owned external canary")

    {:error, %{"type" => "mcp_tool_error"}} =
      invoke(fixture, "normal", "write_note", %{
        "path" => "../outside-canary",
        "content" => "unauthorized"
      })

    check(File.read!(canary) == "owned external canary", "MCP escaped host file policy")

    %{
      "status" => "denied_by_os",
      "canary_unchanged" => true,
      "tools_call_count" => call_count(fixture)
    }
  end

  defp verify("explicit_cancel", fixture) do
    {:ok, policy} = MCPFixture.policy(fixture.workspace, "normal")
    {:ok, connection} = Connection.start_link(policy)

    try do
      {:ok, _} = Connection.discover(connection)
      parent = self()

      task =
        Task.async(fn ->
          Connection.call_tool(connection, "wait", %{"milliseconds" => 3000},
            on_request: fn metadata -> send(parent, {:sent, metadata}) end
          )
        end)

      metadata =
        receive do: ({:sent, metadata} -> metadata),
                after: (5000 -> raise "MCP call was not sent")

      wait(fn -> if call_count(fixture) == 1, do: {:ok, :seen}, else: :wait end)
      :ok = Connection.cancel(connection)
      {:unknown, details} = Task.await(task, 3000)
      check(details["request_id"] == metadata["request_id"], "cancel request pairing differs")
      {:ok, cleanup} = Connection.close(connection)
      verify_cleanup(cleanup)

      check(
        Enum.any?(
          trace(fixture),
          &(&1["phase"] == "cancelled" and &1["request_id"] == metadata["request_id"])
        ),
        "explicit cancel not observed by server"
      )

      %{"status" => "unknown", "request_id" => metadata["request_id"], "cleanup" => cleanup}
    after
      if Process.alive?(connection), do: GenServer.stop(connection)
    end
  end

  defp verify("caller_crash", fixture) do
    parent = self()
    marker = make_ref()
    {:ok, policy} = MCPFixture.policy(fixture.workspace, "timeout")

    {owner, monitor} =
      spawn_monitor(fn ->
        MCP.execute(policy, "mcp.fixture.wait", %{"milliseconds" => 3000},
          on_connected: fn connection -> send(parent, {marker, :connection, connection}) end,
          on_request: fn metadata ->
            send(parent, {marker, :sent, metadata})
            receive do: (:continue -> :ok)
          end
        )
      end)

    try do
      connection =
        receive do: ({^marker, :connection, connection} -> connection),
                after: (5000 -> raise "connection not started")

      metadata =
        receive do: ({^marker, :sent, metadata} -> metadata),
                after: (5000 -> raise "request not sent")

      status = Connection.status(connection)
      wait(fn -> if call_count(fixture) == 1, do: {:ok, :seen}, else: :wait end)
      Process.exit(owner, :kill)

      receive do: ({:DOWN, ^monitor, :process, ^owner, :killed} -> :ok),
              after: (5000 -> raise "owner remained alive")

      await_dead(status.os_pid)
      await_dead(status.target_pid)
      wait(fn -> if Process.alive?(connection), do: :wait, else: {:ok, :gone} end)

      %{
        "status" => "owner_crashed",
        "request_id" => metadata["request_id"],
        "guardian_pid" => status.os_pid,
        "target_pid" => status.target_pid,
        "target_exited" => true,
        "guardian_exited" => true
      }
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp verify("late_reply", fixture) do
    {:ok, policy} = MCPFixture.policy(fixture.workspace, "late_reply", request_timeout_ms: 50)
    {:ok, connection} = Connection.start_link(policy)

    try do
      {:ok, _} = Connection.discover(connection)
      {:unknown, details} = Connection.call_tool(connection, "echo", %{"text" => "late"})
      Process.sleep(250)

      check(
        Connection.status(connection).phase == :tainted,
        "late response revived tainted connection"
      )

      check(
        {:error, :mcp_discovery_required} ==
          Connection.call_tool(connection, "echo", %{"text" => "must not resend"}),
        "tainted connection accepted another call"
      )

      {:ok, cleanup} = Connection.close(connection)
      verify_cleanup(cleanup)
      check(call_count(fixture) == 1, "cancelled call was replayed")

      %{
        "status" => "late_reply_ignored",
        "details" => details,
        "cleanup" => cleanup,
        "tools_call_count" => 1
      }
    after
      if Process.alive?(connection), do: GenServer.stop(connection)
    end
  end

  defp verify("durable_receipt_reuse", fixture) do
    id = fixture.namespace <> "-receipt"
    {:ok, policy} = MCPFixture.policy(fixture.workspace)
    call = call("echo", %{"text" => "durable MCP"})

    {:ok, _} =
      Recovery.create_run(id, "durable MCP", mcp_policy: policy, script: [call, {:final, "done"}])

    {:ok, waiting} = Recovery.step(id)
    {:ok, claim} = IntentStore.claim(id, "mcp-lab")
    operation = waiting.state.operations["mcp-lab-call"]
    {:ok, result} = DurableTools.execute(claim, operation)
    {:ok, ^result} = DurableTools.execute(claim, operation)
    check(call_count(fixture) == 1, "confirmed receipt redelivered")

    {:ok, _} =
      Storage.dispatch(id, claim.seq, {:tool_result, operation.operation_id, result},
        claim: claim
      )

    {:ok, done} = Recovery.resume(id)
    {:ok, audit} = RebuildAudit.run(id, done.state)

    check(
      done.state.status == :succeeded and map_size(audit["effect_boundary_calls"]) == 27,
      "durable rebuild differs"
    )

    write_json(Path.join(fixture.directory, "history-audit.json"), audit)

    %{
      "status" => "succeeded",
      "run_id" => id,
      "tools_call_count" => 1,
      "zero_effect_boundaries" => 27,
      "state_sha256" => audit["state_sha256"]
    }
  end

  defp verify("durable_effect_drop", fixture) do
    id = fixture.namespace <> "-effect-drop"
    {:ok, policy} = MCPFixture.policy(fixture.workspace, "after_effect_drop")

    {:ok, _} =
      Recovery.create_run(id, "effect with lost reply",
        mcp_policy: policy,
        script: [
          call("write_note", %{"path" => "note.txt", "content" => "ONE_EFFECT"}),
          {:final, "done"}
        ]
      )

    {:ok, _} = Recovery.step(id)
    {:ok, blocked} = Recovery.step(id)
    check(blocked.state.status == :blocked, "lost tool result did not block")
    {:ok, queue} = ReconciliationQueue.get(id)

    check(
      queue.safe_mode == :manual and queue.journal_status == "unknown",
      "unknown not visible in manual queue"
    )

    {:error, :reconciliation_required} = Recovery.reconcile(id)

    check(
      File.read!(Path.join(fixture.workspace, "note.txt")) == "ONE_EFFECT",
      "unknown tool effect duplicated"
    )

    check(call_count(fixture) == 1, "unknown MCP call redelivered")
    {:ok, records} = DurableTools.list(id)
    write_json(Path.join(fixture.directory, "reconciliation-queue.json"), safe(queue))
    write_json(Path.join(fixture.directory, "operations.json"), safe(records))

    %{
      "status" => "expected_blocked",
      "run_id" => id,
      "safe_mode" => "manual",
      "journal_status" => "unknown",
      "tools_call_count" => 1,
      "effect_count" => 1
    }
  end

  defp invoke(fixture, mode, remote, arguments, opts \\ []) do
    {:ok, policy} = MCPFixture.policy(fixture.workspace, mode, opts)
    write_json(Path.join(fixture.directory, "policy.json"), safe(Policy.to_map(policy)))
    marker = make_ref()
    parent = self()

    result =
      MCP.execute(policy, "mcp.fixture." <> remote, arguments,
        on_connected: fn pid -> send(parent, {marker, Connection.status(pid)}) end
      )

    status = receive do: ({^marker, status} -> status), after: (0 -> nil)

    write_json(Path.join(fixture.directory, "execution.json"), %{
      outcome: elem(result, 0),
      details: safe(elem(result, 1)),
      initial_status: safe(status)
    })

    if status, do: await_dead(status.os_pid)
    for entry <- trace(fixture), entry["phase"] == "start", do: await_dead(entry["pid"])

    case result do
      {_, %{"transport" => cleanup}} -> verify_cleanup(cleanup)
      _ -> :ok
    end

    result
  end

  defp verify_cleanup(cleanup) do
    check(
      cleanup["target_exited"] == true and cleanup["guardian_exited"] == true and
        cleanup["process_group_gone"] == true,
      "native cleanup unconfirmed"
    )

    await_dead(cleanup["guardian_pid"])
    await_dead(cleanup["target_pid"])
  end

  defp call(remote, args),
    do: {:call, %{operation_id: "mcp-lab-call", tool: "mcp.fixture." <> remote, arguments: args}}

  defp call_count(fixture), do: Enum.count(trace(fixture), &(&1["phase"] == "call"))

  defp trace(fixture) do
    case File.read(Path.join(fixture.workspace, ".mcp-trace.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp await_dead(pid) when is_integer(pid) and pid > 1 do
    wait(fn ->
      {_out, status} = System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true)
      if status == 0, do: :wait, else: {:ok, :gone}
    end)
  end

  defp wait(fun), do: wait(fun, System.monotonic_time(:millisecond) + 6000)

  defp wait(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("owned MCP lifecycle condition timed out")

        Process.sleep(10)
        wait(fun, deadline)
    end
  end

  defp write_report(context, completed, failed) do
    expected = if context.memory, do: @stdio, else: cases()

    report = %{
      "schema_version" => 1,
      "protocol_version" => "2025-11-25",
      "transport" => "stdio",
      "backend" => "seatbelt.mcp_stdio.v1",
      "namespace" => context.namespace,
      "mode" => if(context.memory, do: "stdio_only", else: "full"),
      "recovery_verified" =>
        not context.memory and failed == nil and length(completed) == length(expected),
      "expected_case_count" => length(expected),
      "case_count" => length(completed),
      "all_passed" => failed == nil and length(completed) == length(expected),
      "cases" => completed,
      "failed_case" => failed,
      "run_ids" =>
        Enum.flat_map(completed, fn c -> if c["run_id"], do: [c["run_id"]], else: [] end),
      "unsupported" => [
        "2026-07-28 protocol",
        "HTTP/OAuth",
        "arbitrary JSON Schema",
        "Linux isolation",
        "remote exactly-once"
      ]
    }

    write_json(Path.join(context.output, "report.json"), report)
    report
  end

  defp progress(opts, name, completed, status, context) do
    if callback = opts[:on_progress],
      do:
        callback.(%{
          case: name,
          completed: completed,
          total: if(context.memory, do: length(@stdio), else: length(cases())),
          status: status
        })
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:output, :memory, :on_progress] == [] and
         is_boolean(Keyword.get(opts, :memory, false)) and
         is_binary(Keyword.get(opts, :output, "artifacts/week16-mcp")) and
         String.valid?(Keyword.get(opts, :output, "artifacts/week16-mcp")) and
         Keyword.get(opts, :output, "artifacts/week16-mcp") != "" and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week16-mcp"), <<0>>) and
         (not Keyword.has_key?(opts, :on_progress) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_mcp_demo_options}
  end

  defp isolation(opts) do
    cond do
      Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
          Process.whereis(Scheduler) ->
        {:error, :global_scheduler_enabled}

      not Keyword.get(opts, :memory, false) and
          not Application.get_env(:agent_systems_lab, :database_enabled, true) ->
        {:error, :database_required}

      true ->
        :ok
    end
  end

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        error -> error
      end
    end
  end

  defp check(true, _), do: :ok
  defp check(_, reason), do: raise(reason)

  defp safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp safe(%_{} = value), do: value |> Map.from_struct() |> safe()

  defp safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), safe(item)} end)

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)
  defp safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe()

  defp safe(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp safe(value) when is_pid(value) or is_port(value) or is_reference(value), do: inspect(value)

  defp safe(value), do: value

  defp write_json(path, value) do
    temporary = path <> ".tmp"
    File.write!(temporary, JSON.encode!(safe(value)) <> "\n")
    File.rename!(temporary, path)
  end
end
