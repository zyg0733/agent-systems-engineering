defmodule AgentSystemsLab.MCP.Policy do
  @moduledoc """
  Host-owned authority for one isolated, stdio MCP server using 2025-11-25.

  Discovery verifies pinned input schemas; it never grants authority. Remote
  descriptions and annotations are untrusted data and cannot alter host tool
  descriptions, filesystem permissions, network policy, or recovery semantics.
  Every approved remote tool is exposed as `mcp.<server_name>.<remote_name>`.
  """

  alias AgentSystemsLab.Isolation.Policy, as: IsolationPolicy
  alias AgentSystemsLab.MCP.Schema

  @defaults %{
    protocol_version: "2025-11-25",
    request_timeout_ms: 5000,
    connect_timeout_ms: 2000,
    max_message_bytes: 65_536,
    max_tools: 32,
    max_pages: 8
  }
  @required [:server_name, :command, :args, :isolation_policy, :tools]
  @option_keys @required ++ Map.keys(@defaults)
  @policy_keys [:schema_version | @option_keys]
  @tool_keys [:name, :input_schema, :description]
  @server_name ~r/\A[A-Za-z0-9_-]{1,32}\z/
  @remote_name ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @enforce_keys @required
  defstruct @required ++ Map.to_list(@defaults) ++ [schema_version: 1]

  @type t :: %__MODULE__{}

  @doc "Constructs a finite policy from trusted host configuration."
  def new(opts) do
    with :ok <- options(opts),
         policy = struct!(__MODULE__, Map.merge(@defaults, Map.new(opts))),
         :ok <- validate(policy) do
      {:ok, policy}
    end
  rescue
    _ -> {:error, :invalid_mcp_policy}
  end

  @doc "Checks the complete authority, including the current isolation prerequisite."
  def validate(%__MODULE__{} = policy) do
    with :ok <- exact_keys(Map.from_struct(policy), @policy_keys),
         true <- policy.schema_version === 1 || invalid(:schema_version),
         true <- identifier?(policy.server_name, @server_name) || invalid(:server_name),
         true <- policy.protocol_version === "2025-11-25" || invalid(:protocol_version),
         :ok <- limits(policy),
         :ok <- IsolationPolicy.command(policy.isolation_policy, policy.command, policy.args),
         :ok <- approved_tools(policy.tools, policy.max_tools) do
      :ok
    end
  rescue
    _ -> {:error, :invalid_mcp_policy}
  end

  def validate(_), do: {:error, :invalid_mcp_policy}

  @doc "Returns only inert maps; no process, connection, or executable term is persisted."
  def to_map(%__MODULE__{} = policy) do
    policy
    |> Map.from_struct()
    |> Map.put(:isolation_policy, IsolationPolicy.to_map(policy.isolation_policy))
  end

  @doc "Loads the exact v1 storage shape, then revalidates host authority."
  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @policy_keys),
         {:ok, isolation} <- IsolationPolicy.from_map(map.isolation_policy),
         policy = struct!(__MODULE__, Map.put(map, :isolation_policy, isolation)),
         :ok <- validate(policy) do
      {:ok, policy}
    end
  rescue
    _ -> {:error, :invalid_mcp_policy}
  end

  def from_map(_), do: {:error, :invalid_mcp_policy}

  @doc "Advertises host text and pinned schemas, never server-supplied descriptions."
  def schemas(%__MODULE__{} = policy) do
    Enum.map(policy.tools, fn tool ->
      %{
        "name" => local_name(policy, tool.name),
        "description" => tool.description,
        "input_schema" => tool.input_schema
      }
    end)
  end

  @doc "Checks a local tool name and its bounded JSON arguments against host approval."
  def validate_call(policy, local, arguments) do
    with :ok <- validate(policy),
         {:ok, remote} <- remote_name(policy, local),
         tool = Enum.find(policy.tools, &(&1.name == remote)) do
      Schema.validate(tool.input_schema, arguments)
    end
  end

  @doc "Resolves an exact approved local name; prefixes and similar names confer no grant."
  def remote_name(%__MODULE__{} = policy, local) when is_binary(local) do
    with :ok <- validate(policy) do
      case Enum.find(policy.tools, &(local_name(policy, &1.name) == local)) do
        nil -> {:error, :mcp_tool_not_allowed}
        tool -> {:ok, tool.name}
      end
    end
  end

  def remote_name(_, _), do: {:error, :mcp_tool_not_allowed}

  @doc """
  Verifies a bounded complete tools/list result against host-approved names and
  exact schemas. Extra discovered tools remain unapproved. Duplicates, missing
  approved tools, invalid entries and schema drift fail closed.
  """
  def match_tools(policy, discovered) do
    with :ok <- validate(policy),
         :ok <- discovered_tools(discovered, policy.max_tools),
         names = Enum.map(discovered, & &1["name"]),
         true <- length(names) == length(Enum.uniq(names)) || {:error, :duplicate_mcp_tools} do
      by_name = Map.new(discovered, &{&1["name"], &1})

      Enum.reduce_while(policy.tools, :ok, fn approved, :ok ->
        case Map.fetch(by_name, approved.name) do
          :error -> {:halt, {:error, {:missing_mcp_tool, approved.name}}}
          {:ok, %{"inputSchema" => schema}} when schema === approved.input_schema -> {:cont, :ok}
          {:ok, _} -> {:halt, {:error, {:mcp_schema_drift, approved.name}}}
        end
      end)
    end
  end

  defp local_name(policy, remote), do: "mcp." <> policy.server_name <> "." <> remote

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- @option_keys == [] and @required -- Keyword.keys(opts) == [],
       do: :ok,
       else: {:error, :invalid_mcp_options}
  end

  defp limits(policy) do
    if integer_in?(policy.request_timeout_ms, 1..60_000) and
         integer_in?(policy.connect_timeout_ms, 1..60_000) and
         integer_in?(policy.max_message_bytes, 256..1_048_576) and
         integer_in?(policy.max_tools, 1..128) and integer_in?(policy.max_pages, 1..32),
       do: :ok,
       else: {:error, :invalid_mcp_limits}
  end

  defp approved_tools(tools, maximum) when is_list(tools) do
    if length(tools) in 1..maximum do
      with :ok <- each(tools, &approved_tool/1),
           names = Enum.map(tools, & &1.name),
           true <- length(names) == length(Enum.uniq(names)) do
        :ok
      else
        false -> {:error, :duplicate_approved_mcp_tools}
        error -> error
      end
    else
      {:error, :invalid_approved_mcp_tools}
    end
  end

  defp approved_tools(_, _), do: {:error, :invalid_approved_mcp_tools}

  defp approved_tool(tool) when is_map(tool) and not is_struct(tool) do
    with :ok <- exact_keys(tool, @tool_keys),
         true <- identifier?(tool.name, @remote_name) || invalid(:tool_name),
         true <- text?(tool.description, 0, 4096) || invalid(:tool_description),
         true <-
           (is_map(tool.input_schema) and tool.input_schema["type"] == "object") ||
             invalid(:tool_schema),
         :ok <- Schema.validate_schema(tool.input_schema) do
      :ok
    end
  end

  defp approved_tool(_), do: {:error, :invalid_approved_mcp_tool}

  defp discovered_tools(tools, maximum) when is_list(tools) do
    if length(tools) <= maximum,
      do: each(tools, &discovered_tool/1),
      else: {:error, :mcp_tool_limit}
  end

  defp discovered_tools(_, _), do: {:error, :invalid_discovered_mcp_tools}

  defp discovered_tool(tool) when is_map(tool) and not is_struct(tool) do
    if identifier?(tool["name"], @remote_name) and
         is_map(tool["inputSchema"]) and not is_struct(tool["inputSchema"]),
       do: :ok,
       else: {:error, :invalid_discovered_mcp_tool}
  end

  defp discovered_tool(_), do: {:error, :invalid_discovered_mcp_tool}

  defp exact_keys(map, expected) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_mcp_policy_shape}
  end

  defp each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp identifier?(value, regex),
    do:
      is_binary(value) and byte_size(value) <= 64 and String.valid?(value) and
        Regex.match?(regex, value)

  defp integer_in?(value, range), do: is_integer(value) and value in range

  defp text?(value, minimum, maximum),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) >= minimum and
        byte_size(value) <= maximum and not String.contains?(value, <<0>>)

  defp invalid(field), do: {:error, {:invalid_mcp_policy_field, field}}
end
