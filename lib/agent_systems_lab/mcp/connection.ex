defmodule AgentSystemsLab.MCP.Connection do
  @moduledoc """
  One owned MCP 2025-11-25 stdio session, with one bounded in-flight request.
  Discovery never grants permissions. A call is not replayed after cancellation,
  timeout, malformed output, or disconnect: those outcomes are explicitly unknown.
  """
  use GenServer

  alias AgentSystemsLab.MCP.{Policy, Stdio}

  @version "2025-11-25"

  def start_link(policy, opts \\ []) do
    with :ok <- connection_options(opts) do
      owner = Keyword.get(opts, :owner, self())
      GenServer.start_link(__MODULE__, {policy, owner, opts})
    end
  end

  def start(policy, opts \\ []) do
    with :ok <- connection_options(opts) do
      owner = Keyword.get(opts, :owner, self())
      GenServer.start(__MODULE__, {policy, owner, opts})
    end
  end

  def discover(connection), do: GenServer.call(connection, :discover, :infinity)

  def call_tool(connection, remote_name, args, opts \\ []) do
    owner = self()
    ref = make_ref()
    monitor = Process.monitor(connection)

    request =
      :gen_server.send_request(connection, {:call_tool, remote_name, args, owner, ref, opts})

    try do
      receive do
        {:mcp_request_sent, ^ref, metadata} ->
          callback = opts[:on_request]
          if metadata && callback, do: callback.(metadata)

          case :gen_server.receive_response(request, :infinity) do
            {:reply, result} -> result
            {:error, reason} -> {:unknown, unknown("connection_lost", nil, nil, inspect(reason))}
          end

        {:DOWN, ^monitor, :process, _, reason} ->
          {:unknown, unknown("connection_lost", nil, nil, inspect(reason))}
      end
    after
      Process.demonitor(monitor, [:flush])
      # receive_response/2 disables the request alias on timeout. This also
      # releases it when a host callback raises before the normal wait begins.
      :gen_server.receive_response(request, 0)
    end
  end

  def cancel(connection), do: GenServer.call(connection, :cancel, :infinity)
  def close(connection), do: GenServer.call(connection, :close, :infinity)
  def status(connection), do: GenServer.call(connection, :status)

  @impl true
  def init({policy, owner, opts}) do
    with :ok <- Policy.validate(policy),
         true <- is_pid(owner) || {:error, :invalid_mcp_owner},
         {:ok, transport} <- Stdio.open(policy, opts) do
      connection_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      watchdog =
        Process.send_after(self(), :lifetime, policy.isolation_policy.limits.wall_time_ms + 3000)

      {:ok,
       %{
         policy: policy,
         owner_ref: Process.monitor(owner),
         transport: transport,
         id: connection_id,
         next_id: 1,
         phase: :launching,
         pending: nil,
         waiting: nil,
         tools: nil,
         line: <<>>,
         ignored: MapSet.new(),
         close_waiters: [],
         close_timer: nil,
         cleanup: nil,
         watchdog: watchdog,
         opts: opts
       }}
    else
      {:error, reason} -> {:stop, reason}
      false -> {:stop, :invalid_mcp_owner}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    ready = state.transport.ready

    {:reply,
     %{
       phase: state.phase,
       connection_id: state.id,
       request_id: if(state.pending, do: state.pending.id),
       tools: state.tools,
       os_pid: state.transport.os_pid,
       target_pid: if(ready, do: ready["target_pid"]),
       cleanup: state.cleanup
     }, state}
  end

  def handle_call(:discover, from, %{phase: phase, waiting: nil} = state)
      when phase in [:launching, :initializing] do
    {:noreply, %{state | waiting: from}}
  end

  def handle_call(:discover, _from, %{phase: :ready, tools: tools} = state) when is_list(tools),
    do: {:reply, {:ok, tools}, state}

  def handle_call(:discover, from, %{phase: :ready, pending: nil} = state) do
    {:noreply, begin_discovery(state, from)}
  end

  def handle_call(:discover, _from, state),
    do: {:reply, {:error, :mcp_connection_unavailable}, state}

  def handle_call(
        {:call_tool, name, args, owner, ref, opts},
        from,
        %{phase: :ready, pending: nil, tools: tools} = state
      )
      when is_list(tools) do
    with :ok <- valid_call_options(opts),
         true <- is_binary(name) || {:error, :invalid_mcp_tool_name},
         :ok <-
           Policy.validate_call(
             state.policy,
             "mcp." <> state.policy.server_name <> "." <> name,
             args
           ),
         true <- Enum.any?(tools, &(&1["name"] == name)) || {:error, :mcp_tool_not_discovered},
         true <- (is_map(args) and not is_struct(args)) || {:error, :invalid_mcp_arguments},
         {:ok, state} <-
           request(state, :call, "tools/call", %{"name" => name, "arguments" => args}, from, opts) do
      caller_ref = Process.monitor(owner)
      state = %{state | pending: Map.put(state.pending, :caller_ref, caller_ref)}

      metadata = %{
        "connection_id" => state.id,
        "request_id" => state.pending.id,
        "server_name" => state.policy.server_name
      }

      send(owner, {:mcp_request_sent, ref, metadata})
      {:noreply, state}
    else
      {:error, reason} ->
        send(owner, {:mcp_request_sent, ref, nil})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call_tool, _, _, owner, ref, _}, _from, state) do
    send(owner, {:mcp_request_sent, ref, nil})
    {:reply, {:error, :mcp_discovery_required}, state}
  end

  def handle_call(:cancel, _from, %{pending: %{kind: :call} = pending} = state) do
    notify(state, "notifications/cancelled", %{
      "requestId" => pending.id,
      "reason" => "host_cancelled"
    })

    GenServer.reply(pending.from, {:unknown, unknown("cancelled", pending.id, state.id)})
    {:reply, :ok, clear_pending(%{state | phase: :tainted}, true)}
  end

  def handle_call(:cancel, _from, %{phase: phase} = state)
      when phase in [:launching, :initializing],
      do: {:reply, {:error, :mcp_initialize_not_cancellable}, state}

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :no_mcp_call_in_flight}, state}

  def handle_call(:close, _from, %{phase: :closed, cleanup: cleanup} = state),
    do: {:reply, cleanup, state}

  def handle_call(:close, from, state) do
    state = fail_pending(state, "closed")
    Stdio.close_input(state.transport)
    {:noreply, start_close(%{state | close_waiters: [from | state.close_waiters]})}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{transport: %{port: port}} = state) do
    case Stdio.ingest(state.transport, bytes) do
      {:ok, transport, events} ->
        state = %{state | transport: transport}
        {:noreply, Enum.reduce(events, state, &event/2)}

      {:error, reason} ->
        {:noreply, protocol_failure(state, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{transport: %{port: port}} = state) do
    cleanup = Stdio.finish(state.transport, status)
    state = fail_pending(state, "disconnected") |> fail_waiting(:mcp_disconnected)
    Enum.each(state.close_waiters, &GenServer.reply(&1, cleanup))
    if state.close_timer, do: Process.cancel_timer(state.close_timer)
    Process.cancel_timer(state.watchdog)
    {:noreply, %{state | phase: :closed, cleanup: cleanup, close_waiters: [], close_timer: nil}}
  end

  def handle_info({:request_timeout, id}, %{pending: %{id: id, kind: :call} = pending} = state) do
    notify(state, "notifications/cancelled", %{"requestId" => id, "reason" => "request_timeout"})
    GenServer.reply(pending.from, {:unknown, unknown("timeout", id, state.id)})
    {:noreply, clear_pending(%{state | phase: :tainted}, true)}
  end

  def handle_info({:request_timeout, id}, %{pending: %{id: id}} = state),
    do: {:noreply, protocol_failure(state, :mcp_request_timeout)}

  def handle_info({:request_timeout, _}, state), do: {:noreply, state}

  def handle_info(:close_kill, %{phase: phase} = state) when phase != :closed do
    Stdio.cancel(state.transport)
    {:noreply, %{state | close_timer: nil}}
  end

  def handle_info(:close_kill, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    Stdio.cancel(state.transport)
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{pending: %{kind: :call, caller_ref: ref} = pending} = state
      ) do
    notify(state, "notifications/cancelled", %{
      "requestId" => pending.id,
      "reason" => "caller_lost"
    })

    state = fail_pending(state, "caller_lost")
    Stdio.close_input(state.transport)
    {:noreply, start_close(state)}
  end

  def handle_info(:lifetime, %{phase: :closed} = state), do: {:noreply, state}

  def handle_info(:lifetime, state) do
    Stdio.cancel(state.transport)
    state = fail_pending(state, "lifetime_expired") |> fail_waiting(:mcp_lifetime_expired)
    Enum.each(state.close_waiters, &GenServer.reply(&1, {:error, :mcp_cleanup_timeout}))
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{phase: phase, transport: transport}) do
    if phase != :closed, do: Stdio.abandon(transport)
    :ok
  end

  defp event({:ready, _}, %{phase: :launching} = state) do
    params = %{
      "protocolVersion" => @version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "agent-systems-lab", "version" => "0.1.0"}
    }

    case request(%{state | phase: :initializing}, :initialize, "initialize", params, nil, []) do
      {:ok, state} -> state
      {:error, reason} -> protocol_failure(state, reason)
    end
  end

  defp event({:stdout, bytes}, %{phase: phase} = state) when phase not in [:closing, :closed] do
    lines(state, state.line <> bytes)
  end

  defp event({:stderr, _}, state), do: state
  defp event({:final, _}, state), do: state
  defp event(_, state), do: state

  defp lines(state, bytes) do
    case :binary.match(bytes, "\n") do
      {position, 1} ->
        <<line::binary-size(^position), _newline, tail::binary>> = bytes

        if byte_size(line) > state.policy.max_message_bytes do
          protocol_failure(state, :mcp_message_too_large)
        else
          state = decode_message(%{state | line: <<>>}, line)
          if state.phase in [:closing, :closed], do: state, else: lines(state, tail)
        end

      :nomatch ->
        if byte_size(bytes) > state.policy.max_message_bytes,
          do: protocol_failure(state, :mcp_message_too_large),
          else: %{state | line: bytes}
    end
  end

  defp decode_message(state, bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"jsonrpc" => "2.0"} = message} -> message(state, message)
      _ -> protocol_failure(state, :invalid_mcp_json_rpc)
    end
  end

  defp message(state, %{"method" => method} = message) when is_binary(method) do
    cond do
      Map.has_key?(message, "result") or Map.has_key?(message, "error") ->
        protocol_failure(state, :invalid_mcp_json_rpc)

      Map.has_key?(message, "id") ->
        reverse_request(state, message)

      method == "notifications/tools/list_changed" ->
        # A changed manifest removes the discovery snapshot. It cannot expand
        # the immutable host allowlist, and a later call must rediscover.
        %{state | tools: nil}

      true ->
        state
    end
  end

  defp message(state, %{"id" => id} = message) do
    cond do
      MapSet.member?(state.ignored, id) ->
        state

      state.pending == nil ->
        protocol_failure(state, :unpaired_mcp_response)

      state.pending.id !== id ->
        protocol_failure(state, :unpaired_mcp_response)

      Map.has_key?(message, "result") == Map.has_key?(message, "error") ->
        protocol_failure(state, :invalid_mcp_response)

      Map.has_key?(message, "error") ->
        remote_error(state, message["error"])

      true ->
        result(state, message["result"])
    end
  end

  defp message(state, _), do: protocol_failure(state, :invalid_mcp_json_rpc)

  defp reverse_request(state, %{"id" => id, "method" => method})
       when is_binary(id) or is_integer(id) do
    response =
      if method == "ping" do
        %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
      else
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Client capability not granted"}
        }
      end

    case send_json(state, response) do
      :ok -> state
      {:error, reason} -> protocol_failure(state, reason)
    end
  end

  defp reverse_request(state, _), do: protocol_failure(state, :invalid_mcp_server_request)

  defp remote_error(state, %{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message) do
    error = %{
      "type" => "mcp_rpc_error",
      "code" => code,
      "message" => message,
      "mcp" => %{
        "connection_id" => state.id,
        "request_id" => state.pending.id,
        "server_name" => state.policy.server_name
      }
    }

    if state.pending.kind == :call do
      GenServer.reply(state.pending.from, {:error, error})
      clear_pending(state, false)
    else
      protocol_failure(state, {:mcp_handshake_rpc_error, code})
    end
  end

  defp remote_error(state, _), do: protocol_failure(state, :invalid_mcp_rpc_error)

  defp result(
         %{pending: %{kind: :initialize}} = state,
         %{
           "protocolVersion" => @version,
           "capabilities" => %{"tools" => tools},
           "serverInfo" => info
         }
       )
       when is_map(tools) and is_map(info) do
    if is_binary(info["name"]) and is_binary(info["version"]) do
      state = clear_pending(%{state | phase: :ready}, false)

      case notify(state, "notifications/initialized", %{}) do
        :ok ->
          if state.waiting do
            from = state.waiting
            begin_discovery(%{state | waiting: nil}, from)
          else
            state
          end

        {:error, reason} ->
          protocol_failure(state, reason)
      end
    else
      protocol_failure(state, :invalid_mcp_server_info)
    end
  end

  defp result(%{pending: %{kind: :initialize}} = state, _),
    do: protocol_failure(state, :mcp_negotiation_failed)

  defp result(%{pending: %{kind: :list} = pending} = state, %{"tools" => tools} = result)
       when is_list(tools) do
    all = pending.tools ++ tools
    cursor = result["nextCursor"]

    cond do
      length(all) > state.policy.max_tools or not Enum.all?(tools, &valid_tool?/1) ->
        protocol_failure(state, :invalid_mcp_tool_manifest)

      length(Enum.uniq_by(all, & &1["name"])) != length(all) ->
        protocol_failure(state, :duplicate_mcp_tool)

      cursor != nil and (not is_binary(cursor) or cursor == "" or byte_size(cursor) > 1024) ->
        protocol_failure(state, :invalid_mcp_cursor)

      cursor != nil and (cursor in pending.cursors or pending.pages >= state.policy.max_pages) ->
        protocol_failure(state, :mcp_pagination_limit)

      cursor != nil ->
        state = clear_pending(state, false)

        case request(state, :list, "tools/list", %{"cursor" => cursor}, pending.from, []) do
          {:ok, state} ->
            %{
              state
              | pending:
                  Map.merge(state.pending, %{
                    tools: all,
                    cursors: [cursor | pending.cursors],
                    pages: pending.pages + 1
                  })
            }

          {:error, reason} ->
            protocol_failure(%{state | waiting: pending.from}, reason)
        end

      true ->
        case Policy.match_tools(state.policy, all) do
          :ok ->
            GenServer.reply(pending.from, {:ok, all})
            clear_pending(%{state | tools: all}, false)

          {:error, reason} ->
            protocol_failure(state, reason)
        end
    end
  end

  defp result(%{pending: %{kind: :list}} = state, _),
    do: protocol_failure(state, :invalid_mcp_tool_manifest)

  defp result(%{pending: %{kind: :call} = pending} = state, result) do
    case normalize(result) do
      {:ok, normalized} ->
        metadata = %{
          "connection_id" => state.id,
          "request_id" => pending.id,
          "server_name" => state.policy.server_name
        }

        normalized = Map.put(normalized, "mcp", metadata)

        reply =
          if normalized["isError"],
            do: {:error, Map.put(normalized, "type", "mcp_tool_error")},
            else: {:ok, normalized}

        GenServer.reply(pending.from, reply)
        clear_pending(state, false)

      {:error, reason} ->
        protocol_failure(state, reason)
    end
  end

  defp valid_tool?(%{"name" => name, "inputSchema" => schema})
       when is_binary(name) and byte_size(name) in 1..128 and is_map(schema),
       do: schema["type"] == "object"

  defp valid_tool?(_), do: false

  defp normalize(%{"content" => content} = result) when is_list(content) do
    error = Map.get(result, "isError", false)

    if is_boolean(error) and length(content) <= 128 and Enum.all?(content, &content?/1) and
         (not Map.has_key?(result, "structuredContent") or is_map(result["structuredContent"])) do
      {:ok,
       Map.take(result, ["content", "structuredContent", "_meta"]) |> Map.put("isError", error)}
    else
      {:error, :invalid_mcp_tool_result}
    end
  end

  defp normalize(_), do: {:error, :invalid_mcp_tool_result}
  defp content?(%{"type" => "text", "text" => text}), do: is_binary(text)

  defp content?(%{"type" => type, "data" => data, "mimeType" => mime})
       when type in ["image", "audio"], do: is_binary(data) and is_binary(mime)

  defp content?(%{"type" => "resource_link", "uri" => uri, "name" => name}),
    do: is_binary(uri) and is_binary(name)

  defp content?(%{"type" => "resource", "resource" => %{"uri" => uri} = resource}),
    do: is_binary(uri) and (is_binary(resource["text"]) or is_binary(resource["blob"]))

  defp content?(_), do: false

  defp begin_discovery(state, from) do
    case request(state, :list, "tools/list", %{}, from, []) do
      {:ok, state} ->
        %{state | pending: Map.merge(state.pending, %{tools: [], cursors: [], pages: 1})}

      {:error, reason} ->
        protocol_failure(%{state | waiting: from}, reason)
    end
  end

  defp request(state, kind, method, params, from, opts) do
    id = state.id <> ":" <> to_string(state.next_id)

    timeout =
      if kind == :initialize,
        do: state.policy.connect_timeout_ms,
        else: state.policy.request_timeout_ms

    timeout =
      remaining_timeout(
        timeout,
        opts[:deadline_monotonic_ms] || state.opts[:deadline_monotonic_ms]
      )

    if timeout <= 0 do
      {:error, :mcp_deadline_expired}
    else
      message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

      with :ok <- send_json(state, message) do
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)

        {:ok,
         %{
           state
           | pending: %{kind: kind, id: id, from: from, timer: timer},
             next_id: state.next_id + 1
         }}
      end
    end
  end

  defp remaining_timeout(timeout, nil), do: timeout

  defp remaining_timeout(timeout, deadline),
    do: min(timeout, deadline - System.monotonic_time(:millisecond))

  defp send_json(state, map) do
    bytes = JSON.encode!(map)

    if byte_size(bytes) <= state.policy.max_message_bytes,
      do: Stdio.write(state.transport, bytes <> "\n"),
      else: {:error, :mcp_message_too_large}
  end

  defp notify(state, method, params),
    do: send_json(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp clear_pending(state, ignore?) do
    Process.cancel_timer(state.pending.timer)
    if caller_ref = state.pending[:caller_ref], do: Process.demonitor(caller_ref, [:flush])
    ignored = if ignore?, do: MapSet.put(state.ignored, state.pending.id), else: state.ignored
    %{state | pending: nil, ignored: ignored}
  end

  defp fail_pending(%{pending: nil} = state, _), do: state

  defp fail_pending(%{pending: %{kind: :call} = pending} = state, reason) do
    GenServer.reply(pending.from, {:unknown, unknown(reason, pending.id, state.id)})
    clear_pending(state, true)
  end

  defp fail_pending(%{pending: pending} = state, reason) do
    if pending.from, do: GenServer.reply(pending.from, {:error, {:mcp_connection_failed, reason}})
    clear_pending(state, false)
  end

  defp fail_waiting(%{waiting: nil} = state, _), do: state

  defp fail_waiting(state, reason) do
    GenServer.reply(state.waiting, {:error, reason})
    %{state | waiting: nil}
  end

  defp protocol_failure(%{phase: :closed} = state, _), do: state

  defp protocol_failure(state, reason) do
    state = fail_pending(state, reason_string(reason)) |> fail_waiting(reason)
    Stdio.cancel(state.transport)
    start_close(state)
  end

  defp start_close(%{phase: :closed} = state), do: state

  defp start_close(%{close_timer: nil} = state),
    do: %{state | phase: :closing, close_timer: Process.send_after(self(), :close_kill, 100)}

  defp start_close(state), do: %{state | phase: :closing}

  defp valid_call_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:on_request, :deadline_monotonic_ms] == [] and
         (not Keyword.has_key?(opts, :on_request) or is_function(opts[:on_request], 1)) and
         (not Keyword.has_key?(opts, :deadline_monotonic_ms) or
            is_integer(opts[:deadline_monotonic_ms])),
       do: :ok,
       else: {:error, :invalid_mcp_call_options}
  end

  defp connection_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:owner, :deadline_monotonic_ms] == [] and
         (not Keyword.has_key?(opts, :owner) or is_pid(opts[:owner])) and
         (not Keyword.has_key?(opts, :deadline_monotonic_ms) or
            is_integer(opts[:deadline_monotonic_ms])),
       do: :ok,
       else: {:error, :invalid_mcp_connection_options}
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  defp unknown(reason, request_id, connection_id, detail \\ nil) do
    %{
      "type" => "mcp_unknown",
      "reason" => reason,
      "request_id" => request_id,
      "connection_id" => connection_id
    }
    |> then(fn map -> if detail, do: Map.put(map, "detail", detail), else: map end)
  end
end
