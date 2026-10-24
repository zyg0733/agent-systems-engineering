defmodule AgentSystemsLab.Tools.Gateway do
  @moduledoc "Checks tool availability and schemas before intent creation and again before effects."

  alias AgentSystemsLab.Tools.{Catalog, Files, Mock, Result}
  alias AgentSystemsLab.Isolation
  alias AgentSystemsLab.Isolation.Policy

  def validate_call(call, files, isolation_policy \\ nil, mcp_policy \\ nil)

  def validate_call(
        %{operation_id: id, tool: tool, arguments: arguments} = call,
        files,
        isolation_policy,
        mcp_policy
      )
      when map_size(call) == 3 and is_binary(id) and byte_size(id) > 0 and
             is_binary(tool) and byte_size(tool) > 0 and is_map(arguments) do
    cond do
      Catalog.paired_tool?(tool) and
          (byte_size(id) > 256 or not String.valid?(id) or String.contains?(id, <<0>>)) ->
        {:error, :invalid_operation_id}

      Catalog.file_tool?(tool) and is_nil(files) ->
        {:error, {:tool_disabled, tool}}

      Catalog.mcp_tool?(tool) and is_nil(mcp_policy) ->
        {:error, {:tool_disabled, tool}}

      Catalog.mcp_tool?(tool) ->
        AgentSystemsLab.MCP.Policy.validate_call(mcp_policy, tool, arguments)

      Catalog.isolated_tool?(tool) and is_nil(isolation_policy) ->
        {:error, {:tool_disabled, tool}}

      Catalog.isolated_tool?(tool) ->
        with :ok <- Catalog.validate(tool, arguments),
             do: Policy.command(isolation_policy, arguments["command"], arguments["args"])

      Catalog.file_tool?(tool) or tool == "mock_write" ->
        Catalog.validate(tool, arguments)

      true ->
        :ok
    end
  end

  def validate_call(call, _files, _isolation_policy, _mcp_policy),
    do: {:error, {:invalid_tool_call, call}}

  def validate_response(response, files, isolation_policy \\ nil, mcp_policy \\ nil)

  def validate_response({:call, call}, files, isolation_policy, mcp_policy),
    do: validate_call(call, files, isolation_policy, mcp_policy)

  def validate_response({:final, _output}, _files, _isolation_policy, _mcp_policy), do: :ok

  def validate_response(response, _files, _isolation_policy, _mcp_policy),
    do: {:error, {:invalid_model_response, response}}

  def execute(
        files,
        mock,
        %{operation_id: id, tool: tool, arguments: arguments} = operation,
        mock_response,
        isolation_policy \\ nil,
        mcp_policy \\ nil,
        execution_opts \\ []
      ) do
    call = Map.take(operation, [:operation_id, :tool, :arguments])

    case validate_call(call, files, isolation_policy, mcp_policy) do
      :ok ->
        cond do
          tool == "mock_write" ->
            {Mock.execute(mock, id, arguments, response: mock_response), files}

          Catalog.file_tool?(tool) ->
            {result, next_files} = Files.execute(files, id, tool, arguments)
            {Result.wrap(result, id, tool), next_files}

          Catalog.mcp_tool?(tool) ->
            result = AgentSystemsLab.MCP.execute(mcp_policy, tool, arguments, execution_opts)
            {Result.wrap(result, id, tool), files}

          Catalog.isolated_tool?(tool) ->
            result = Isolation.execute(arguments["command"], arguments["args"], isolation_policy)
            {Result.wrap(result, id, tool), files}

          true ->
            {{:error, {:unsupported_tool, tool}}, files}
        end

      {:error, reason} ->
        result =
          if Catalog.paired_tool?(tool),
            do: Result.wrap({:error, reason}, id, tool),
            else: {:error, reason}

        {result, files}
    end
  end
end
