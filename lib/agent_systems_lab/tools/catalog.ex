defmodule AgentSystemsLab.Tools.Catalog do
  @moduledoc """
  The advertised tool catalog and its matching, deliberately small validator.

  File tools accept JSON objects with string keys only. Unknown properties are
  rejected rather than silently discarded. This module validates data; `Files`
  independently enforces workspace paths, file types and content preconditions.
  The legacy `mock_write` tool continues to accept arbitrary maps.
  """

  alias AgentSystemsLab.Tools.Workspace

  @file_tools ~w(file_read file_write file_patch)
  @max_bytes 65_536
  @hash ~r/\A[0-9a-f]{64}\z/

  def file_tool?(name), do: name in @file_tools
  def isolated_tool?(name), do: name == "sandbox_exec"
  def mcp_tool?(name) when is_binary(name), do: String.starts_with?(name, "mcp.")
  def mcp_tool?(_name), do: false
  def paired_tool?(name), do: file_tool?(name) or isolated_tool?(name) or mcp_tool?(name)

  def schemas(files_enabled? \\ false, isolation_enabled? \\ false, mcp_policy \\ nil) do
    mock =
      descriptor("mock_write", "Record one effect in the isolated mock ledger.", %{
        "type" => "object",
        "additionalProperties" => true
      })

    files =
      if files_enabled? do
        [
          mock,
          descriptor(
            "file_read",
            "Read a bounded UTF-8 regular file inside the workspace.",
            object(%{"path" => path_schema()}, ["path"])
          ),
          descriptor(
            "file_write",
            "Create or replace a file after matching its SHA-256 precondition.",
            object(
              %{
                "path" => path_schema(),
                "content" => text_schema(0),
                "expected_sha256" => hash_schema(true)
              },
              ["path", "content", "expected_sha256"]
            )
          ),
          descriptor(
            "file_patch",
            "Apply exact, unique text replacements after matching the file SHA-256.",
            object(
              %{
                "path" => path_schema(),
                "expected_sha256" => hash_schema(false),
                "edits" => %{
                  "type" => "array",
                  "minItems" => 1,
                  "maxItems" => 32,
                  "items" =>
                    object(%{"old" => text_schema(1), "new" => text_schema(0)}, ["old", "new"])
                }
              },
              ["path", "expected_sha256", "edits"]
            )
          )
        ]
      else
        [mock]
      end

    isolated =
      if isolation_enabled? do
        files ++
          [
            descriptor(
              "sandbox_exec",
              "Execute an allowed program inside the host's isolated workspace and resource policy.",
              object(
                %{
                  "command" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
                  "args" => %{
                    "type" => "array",
                    "maxItems" => 128,
                    "items" => %{"type" => "string", "maxLength" => 16384}
                  }
                },
                ["command", "args"]
              )
            )
          ]
      else
        files
      end

    isolated ++ if(mcp_policy, do: AgentSystemsLab.MCP.Policy.schemas(mcp_policy), else: [])
  end

  def validate("mock_write", arguments) when is_map(arguments), do: :ok

  def validate("sandbox_exec", arguments) do
    with :ok <- exact_keys(arguments, ["command", "args"]),
         command = arguments["command"],
         true <-
           (is_binary(command) and String.valid?(command) and byte_size(command) in 1..4096 and
              Path.type(command) == :absolute and not String.contains?(command, <<0>>)) ||
             invalid(:command),
         args = arguments["args"],
         true <-
           (is_list(args) and length(args) <= 128 and
              Enum.all?(
                args,
                &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>))
              ) and Enum.reduce(args, 0, &(byte_size(&1) + &2)) <= 16384) || invalid(:args) do
      :ok
    end
  end

  def validate("file_read", arguments) do
    with :ok <- exact_keys(arguments, ["path"]), do: path(arguments["path"])
  end

  def validate("file_write", arguments) do
    with :ok <- exact_keys(arguments, ["path", "content", "expected_sha256"]),
         :ok <- path(arguments["path"]),
         :ok <- text(arguments["content"], "content", 0),
         :ok <- hash(arguments["expected_sha256"], true),
         do: :ok
  end

  def validate("file_patch", arguments) do
    with :ok <- exact_keys(arguments, ["path", "expected_sha256", "edits"]),
         :ok <- path(arguments["path"]),
         :ok <- hash(arguments["expected_sha256"], false),
         :ok <- edits(arguments["edits"]),
         do: :ok
  end

  def validate("mock_write", _arguments), do: invalid(:arguments)
  def validate(tool, _arguments), do: {:error, {:unsupported_tool, tool}}

  defp exact_keys(arguments, keys) when is_map(arguments) do
    if Enum.sort(Map.keys(arguments)) == Enum.sort(keys), do: :ok, else: invalid(:keys)
  end

  defp exact_keys(_arguments, _keys), do: invalid(:arguments)

  defp path(value) do
    case Workspace.path_valid(value) do
      :ok -> :ok
      {:error, _reason} -> invalid(:path)
    end
  end

  defp text(value, field, minimum) do
    if is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= @max_bytes and
         String.valid?(value) and not String.contains?(value, <<0>>),
       do: :ok,
       else: invalid(field)
  end

  defp hash("absent", true), do: :ok

  defp hash(value, _allow_absent) when is_binary(value) do
    if Regex.match?(@hash, value), do: :ok, else: invalid(:expected_sha256)
  end

  defp hash(_value, _allow_absent), do: invalid(:expected_sha256)

  defp edits(values) when is_list(values) and length(values) in 1..32 do
    Enum.reduce_while(values, :ok, fn edit, :ok ->
      case validate_edit(edit) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp edits(_values), do: invalid(:edits)

  defp validate_edit(edit) do
    with :ok <- exact_keys(edit, ["old", "new"]),
         :ok <- text(edit["old"], "old", 1),
         :ok <- text(edit["new"], "new", 0),
         do: :ok
  end

  defp invalid(field), do: {:error, {:invalid_tool_arguments, field}}

  defp descriptor(name, description, schema),
    do: %{"name" => name, "description" => description, "input_schema" => schema}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp path_schema,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 1024,
      "description" =>
        "Relative workspace path, at most 1024 UTF-8 bytes; no traversal, symlinks, reserved directories, backslash or control characters."
    }

  defp text_schema(minimum),
    do: %{
      "type" => "string",
      "minLength" => minimum,
      "maxLength" => @max_bytes,
      "description" => "UTF-8 text without NUL; runtime also enforces a 65536-byte limit."
    }

  defp hash_schema(allow_absent),
    do: %{
      "type" => "string",
      "minLength" => if(allow_absent, do: 6, else: 64),
      "maxLength" => 64,
      "pattern" => if(allow_absent, do: "^(absent|[0-9a-f]{64})$", else: "^[0-9a-f]{64}$")
    }
end
