defmodule AgentSystemsLab.MCP do
  @moduledoc """
  Host-approved MCP tools over an isolated owned stdio connection. A fresh
  connection is initialized and discovered for each execution. No reconnection
  or retry can silently replay a potentially effective tools/call request.
  """

  alias AgentSystemsLab.MCP.{Connection, Policy}

  def execute(policy, local_tool, arguments, opts \\ []) do
    with :ok <- options(opts),
         :ok <- Policy.validate_call(policy, local_tool, arguments),
         {:ok, remote} <- Policy.remote_name(policy, local_tool),
         {:ok, connection} <-
           Connection.start(policy, Keyword.take(opts, [:deadline_monotonic_ms])) do
      try do
        if callback = opts[:on_connected], do: callback.(connection)

        result =
          with {:ok, _tools} <- safe_discover(connection) do
            Connection.call_tool(
              connection,
              remote,
              arguments,
              Keyword.take(opts, [:on_request, :deadline_monotonic_ms])
            )
          end

        cleanup = safe_close(connection)
        attach_cleanup(result, cleanup)
      after
        safe_close(connection)
        safe_stop(connection)
      end
    end
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- [:on_request, :on_connected, :deadline_monotonic_ms] == [] and
         (not Keyword.has_key?(opts, :on_request) or is_function(opts[:on_request], 1)) and
         (not Keyword.has_key?(opts, :on_connected) or is_function(opts[:on_connected], 1)) and
         (not Keyword.has_key?(opts, :deadline_monotonic_ms) or
            is_integer(opts[:deadline_monotonic_ms])),
       do: :ok,
       else: {:error, :invalid_mcp_options}
  end

  defp attach_cleanup({:ok, result}, {:ok, cleanup}),
    do: {:ok, Map.put(result, "transport", cleanup)}

  defp attach_cleanup({:ok, result}, {:error, reason}) do
    metadata = result["mcp"] || %{}

    {:unknown,
     %{
       "type" => "mcp_unknown",
       "reason" => "cleanup_unverified",
       "request_id" => metadata["request_id"],
       "connection_id" => metadata["connection_id"],
       "cleanup_error" => inspect(reason)
     }}
  end

  defp attach_cleanup({:unknown, details}, {:ok, cleanup}),
    do: {:unknown, Map.put(details, "transport", cleanup)}

  defp attach_cleanup({:unknown, details}, {:error, reason}),
    do: {:unknown, Map.put(details, "cleanup_error", inspect(reason))}

  defp attach_cleanup({:error, %{} = details}, {:ok, cleanup}),
    do: {:error, Map.put(details, "transport", cleanup)}

  defp attach_cleanup(result, _), do: result

  defp safe_close(connection) do
    try do
      Connection.close(connection)
    catch
      :exit, _ -> {:error, :mcp_connection_closed}
    end
  end

  defp safe_discover(connection) do
    try do
      Connection.discover(connection)
    catch
      :exit, reason -> {:error, {:mcp_connection_failed, inspect(reason)}}
    end
  end

  defp safe_stop(connection) do
    try do
      GenServer.stop(connection, :normal, 1000)
    catch
      :exit, _ -> :ok
    end
  end
end
