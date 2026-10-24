defmodule AgentSystemsLab.HistoryDemo do
  @moduledoc "Creates one real file effect, then verifies a checkpoint and recorded results in a fresh VM."

  alias AgentSystemsLab.{CheckpointStore, Context, ContextStore, ModelResultStore, RunServer}
  alias AgentSystemsLab.Providers.Recorded
  alias AgentSystemsLab.Storage.Codec

  def run(opts \\ []) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week07-history"))
    id = "history-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    with :ok <- create_output(output) do
      workspace = Path.join(output, "workspace")
      File.mkdir!(workspace)

      script = [
        {:call,
         %{
           operation_id: "write-once",
           tool: "file_write",
           arguments: %{
             "path" => "result.txt",
             "content" => "one recorded file effect\n",
             "expected_sha256" => "absent"
           }
         }},
        {:final, "The recorded write completed."}
      ]

      with {:ok, server} <-
             AgentSystemsLab.start_run(
               run_id: id,
               input: "Write once and confirm",
               workspace: workspace,
               storage: :postgres,
               script: script
             ) do
        try do
          {:ok, planned} = RunServer.step(server)
          true = planned.file_stats.writes == 0
          {:ok, checkpoint} = CheckpointStore.create(id, planned.state.seq)
          {:ok, completed} = RunServer.run_until_pause(server)
          true = completed.state.status == :succeeded
          true = completed.file_stats.writes == 1
          {:ok, stored} = ModelResultStore.list(id)
          {:ok, inputs} = ContextStore.list(id)
          2 = length(stored)
          2 = length(inputs)

          # Explicit recorded output reuse is separate from state reconstruction.
          {:ok, recorded} = Recorded.new(Enum.map(stored, & &1.record))
          {:ok, response, recorded} = Recorded.respond(hd(inputs).context, recorded)
          true = response === hd(script)
          1 = recorded.cursor

          before = File.read!(Path.join(workspace, "result.txt"))
          {:ok, audit, child_log} = fresh_audit(id, completed.state)
          true = audit["same_as_expected_state"]
          true = audit["state_sha256"] == Context.hash(completed.state)
          true = before === File.read!(Path.join(workspace, "result.txt"))
          true = RunServer.snapshot(server).file_stats.writes == 1
          {:ok, events_data} = Codec.encode(completed.events)

          report =
            Map.merge(audit, %{
              "same_as_live_state" => audit["same_as_expected_state"],
              "original_file_writes" => 1,
              "file_unchanged_by_rebuild" => true,
              "checkpoint_created_before_file_effect" => true,
              "recorded_response_reused_explicitly" => true
            })

          File.write!(Path.join(output, "report.json"), JSON.encode!(report) <> "\n")
          File.write!(Path.join(output, "fresh-vm.log"), child_log)
          File.write!(Path.join(output, "events.bin"), events_data)

          {:ok,
           %{
             output_dir: output,
             report: report,
             snapshot: completed,
             checkpoint: checkpoint,
             recordings: stored
           }}
        after
          GenServer.stop(server)
        end
      end
    end
  end

  @doc "Starts only Repo/application infrastructure; the child does not start a RunServer."
  def fresh_audit(run_id, expected_state \\ nil) do
    environment = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev
    {:ok, expected_data} = Codec.encode(expected_state)
    expected_base64 = Base.encode64(expected_data)

    script = """
    config = Config.Reader.read!("config/config.exs", env: #{inspect(environment)}, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    AgentSystemsLab.Storage.preload_vocabulary()
    expected_data = Base.decode64!(#{inspect(expected_base64)})
    {:ok, expected_state} = AgentSystemsLab.Storage.Codec.decode(expected_data)
    {:ok, report} = AgentSystemsLab.RebuildAudit.run(#{inspect(run_id)}, expected_state)
    IO.puts("HISTORY_AUDIT=" <> JSON.encode!(report))
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    with 0 <- code,
         line when is_binary(line) <-
           Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "HISTORY_AUDIT=")),
         {:ok, report} <- JSON.decode(String.replace_prefix(line, "HISTORY_AUDIT=", "")) do
      {:ok, report, output}
    else
      _ -> {:error, {:fresh_vm_audit_failed, code, output}}
    end
  end

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
