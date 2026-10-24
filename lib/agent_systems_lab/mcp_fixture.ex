defmodule AgentSystemsLab.MCPFixture do
  @moduledoc "Trusted, fixed C stdio server used only by the offline MCP lab."

  alias AgentSystemsLab.Isolation.Policy, as: IsolationPolicy
  alias AgentSystemsLab.MCP.Policy

  @source Path.expand("../../priv/mcp/fixture_server.c", __DIR__)
  @runtime Path.expand("../../.runtime/mcp-fixture", __DIR__)
  @modes ~w(normal pages duplicate cursor_loop timeout remote_error tool_error malformed wrong_id notification ping disconnect after_effect_drop schema_drift version_mismatch no_tools stderr fragment oversized late_reply list_changed reverse_request bad_initialize)

  def modes, do: @modes

  def tools do
    [
      tool(
        "echo",
        "Echo bounded text from this host-approved fixture.",
        object(%{"text" => string(0, 256)}, ["text"])
      ),
      tool(
        "write_note",
        "Append bounded text to a file within the isolated workspace.",
        object(%{"path" => string(1, 1024), "content" => string(0, 1024)}, ["path", "content"])
      ),
      tool(
        "wait",
        "Wait for a bounded interval; cancellation is advisory.",
        object(%{"milliseconds" => %{"type" => "integer", "minimum" => 0, "maximum" => 10000}}, [
          "milliseconds"
        ])
      ),
      tool("tool_error", "Return a confirmed fixture tool error.", object(%{}, [])),
      tool("rpc_error", "Return a confirmed fixture JSON-RPC error.", object(%{}, []))
    ]
  end

  def policy(workspace, mode \\ "normal", opts \\ []) do
    with :ok <- options(mode, opts),
         {:ok, executable} <- ensure_executable(),
         {:ok, isolation} <-
           IsolationPolicy.new(
             workspace: workspace,
             commands: [executable],
             limits: Keyword.get(opts, :limits, [])
           ),
         names = Keyword.get(opts, :tools, Enum.map(tools(), & &1.name)),
         true <-
           (is_list(names) and names != [] and length(names) == length(Enum.uniq(names)) and
              Enum.all?(names, fn name -> Enum.any?(tools(), &(&1.name == name)) end)) ||
             {:error, :invalid_fixture_tools} do
      Policy.new(
        [
          server_name: Keyword.get(opts, :server_name, "fixture"),
          command: executable,
          args: [mode],
          isolation_policy: isolation,
          tools: Enum.filter(tools(), &(&1.name in names))
        ] ++
          Keyword.take(opts, [
            :request_timeout_ms,
            :connect_timeout_ms,
            :max_message_bytes,
            :max_tools,
            :max_pages
          ])
      )
    end
  end

  def ensure_executable do
    :global.trans({{__MODULE__, :compile}, self()}, fn ->
      binary = Path.join(@runtime, "server")
      hash_path = Path.join(@runtime, "source.sha256")

      with :ok <- File.mkdir_p(@runtime),
           {:ok, source} <- File.read(@source) do
        hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

        if File.regular?(binary) and File.read(hash_path) == {:ok, hash} do
          {:ok, binary}
        else
          case System.cmd(
                 "/usr/bin/clang",
                 ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", @source, "-o", binary],
                 stderr_to_stdout: true
               ) do
            {_log, 0} ->
              File.chmod!(binary, 0o700)
              File.write!(hash_path, hash)
              {:ok, binary}

            {log, code} ->
              {:error, {:fixture_compile_failed, code, log}}
          end
        end
      end
    end)
  end

  defp options(mode, opts) do
    if mode in @modes and is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) --
           [
             :tools,
             :server_name,
             :limits,
             :request_timeout_ms,
             :connect_timeout_ms,
             :max_message_bytes,
             :max_tools,
             :max_pages
           ] == [], do: :ok, else: {:error, :invalid_fixture_options}
  end

  defp tool(name, description, schema),
    do: %{name: name, description: description, input_schema: schema}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp string(minimum, maximum),
    do: %{"type" => "string", "minLength" => minimum, "maxLength" => maximum}
end
