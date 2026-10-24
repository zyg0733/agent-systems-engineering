defmodule AgentSystemsLab.P1Demo do
  @moduledoc "P1 acceptance: compressed canonical input, streamed repair, cancellation and durable manifests."

  alias AgentSystemsLab.{
    Context,
    ContextStore,
    Kernel,
    Repair,
    RunServer,
    Session,
    SessionStore,
    Storage,
    StorageVerification
  }

  alias AgentSystemsLab.Storage.Codec

  @context_options [max_context_bytes: 16_384, keep_recent_messages: 2, max_summary_bytes: 4_096]

  def context_options, do: @context_options

  def session(id) do
    {:ok, initial} =
      Session.new(id,
        facts: %{
          "free_delivery_threshold" => 100,
          "comparison" => "inclusive",
          "test_file" => "test/shipping_test.exs"
        },
        acceptance: [
          "0 and 99 pay 10; 100 and 101 pay 0",
          "Keep the original acceptance tests unchanged"
        ],
        constraints: [
          "Only use the explicitly supplied private workspace",
          "Never execute model-generated shell",
          "Retain complete tool receipts"
        ]
      )

    Enum.reduce(1..40, initial, fn index, current ->
      text = "Historical note #{index}: " <> String.duplicate("untrusted narrative detail; ", 64)
      {:ok, next} = Session.append(current, "note", text)
      next
    end)
  end

  def run(opts \\ []) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week06-p1"))
    storage = Keyword.get(opts, :storage, :postgres)
    unique = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    canonical = session("p1-session-#{unique}")
    run_id = "p1-repair-#{unique}"
    cancel_id = "p1-cancel-#{unique}"

    with true <- storage in [:memory, :postgres],
         :ok <- create_output(output),
         {:ok, ^canonical} <- save_session(canonical, storage),
         run_options =
           [run_id: run_id, storage: storage, context_options: @context_options] ++
             session_option(canonical, storage),
         {:ok, repair} <-
           Repair.run(
             output: Path.join(output, "repair"),
             streaming: true,
             run_options: run_options
           ),
         {:ok, contexts} <- verify_contexts(canonical, repair.snapshot, storage),
         {:ok, cancelled} <-
           demonstrate_cancel(
             canonical,
             storage,
             cancel_id,
             Path.join(output, "repair/workspace")
           ),
         {:ok, crash_evidence} <- crash_evidence(storage),
         :ok <- export_contexts(output, canonical, contexts),
         :ok <- verify_canonical_session(canonical, storage) do
      report = %{
        "stage" => "P1",
        "storage" => Atom.to_string(storage),
        "session_id" => canonical.id,
        "run_id" => run_id,
        "cancel_run_id" => cancel_id,
        "canonical_messages" => length(canonical.messages),
        "canonical_version" => canonical.version,
        "context_count" => length(contexts),
        "max_context_bytes" => @context_options[:max_context_bytes],
        "compressed_contexts" =>
          Enum.count(contexts, &(&1.built.manifest.messages.omitted != [])),
        "summary_contexts" => Enum.count(contexts, &(not is_nil(&1.built.context.summary))),
        "payload_bytes" => Enum.map(contexts, & &1.built.manifest.byte_size),
        "task_facts_preserved" => true,
        "complete_receipts_preserved" => true,
        "permissions_preserved" => true,
        "canonical_session_unchanged" => true,
        "before_exit_code" => repair.report["before_exit_code"],
        "after_exit_code" => repair.report["after_exit_code"],
        "repair_turns" => repair.snapshot.state.turn_count,
        "repair_events" => length(repair.snapshot.events),
        "repair_file_stats" => json_view(repair.snapshot.file_stats),
        "cancel_status" => Atom.to_string(cancelled.state.status),
        "cancel_file_writes" => cancelled.file_stats.writes,
        "postgres_commit_probes" => json_view(crash_evidence)
      }

      File.write!(Path.join(output, "report.json"), JSON.encode!(report) <> "\n")

      {:ok,
       %{
         output_dir: output,
         report: report,
         repair: repair,
         contexts: contexts,
         cancelled: cancelled,
         session: canonical
       }}
    else
      false -> {:error, :invalid_storage}
      {:error, _reason} = error -> error
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

  defp save_session(session, :memory), do: {:ok, session}
  defp save_session(session, :postgres), do: SessionStore.create(session)
  defp session_option(session, :memory), do: [session: session]
  defp session_option(session, :postgres), do: [session_id: session.id]

  defp verify_contexts(session, snapshot, storage) do
    contexts =
      snapshot.provider.requests
      |> Enum.with_index()
      |> Enum.map(fn {payload, index} ->
        {:ok, run} =
          Kernel.rebuild(snapshot.state.run_id, Enum.take(snapshot.events, 1 + 2 * index))

        {:ok, built} = Context.build(session, run, payload.permissions, @context_options)
        true = built.context === payload
        :ok = Context.verify(built, session, run, payload.permissions, @context_options)
        true = payload.task.facts === session.facts
        true = payload.task.acceptance === session.acceptance
        true = payload.task.constraints === session.constraints
        true = payload.operations === run.operations
        false = payload.permissions.shell
        false = payload.permissions.network
        true = built.manifest.messages.omitted != []
        true = not is_nil(payload.summary)
        true = payload.summary.trust == "untrusted_session_narrative"
        %{built: built, run: run, permissions: payload.permissions}
      end)

    if length(contexts) != 4, do: raise("P1 expected exactly four provider inputs")

    case storage do
      :memory ->
        {:ok, contexts}

      :postgres ->
        with {:ok, records} <- ContextStore.list(snapshot.state.run_id),
             true <- length(records) == 4,
             true <-
               Enum.zip(records, contexts)
               |> Enum.all?(fn {record, context} ->
                 record.context === context.built.context and
                   record.manifest === context.built.manifest
               end) do
          {:ok, contexts}
        else
          _ -> {:error, :p1_capture_mismatch}
        end
    end
  end

  defp demonstrate_cancel(session, storage, id, workspace) do
    gate = make_ref()

    opts =
      [
        run_id: id,
        input: "Cancel before writing a file",
        storage: storage,
        workspace: workspace,
        context_options: @context_options,
        script: [
          {:stream,
           [
             {:tool_start, %{operation_id: "never-write", tool: "file_write"}},
             {:arguments_delta, "{"},
             {:gate, self(), gate},
             :done
           ]}
        ]
      ] ++ session_option(session, storage)

    with {:ok, server} <- AgentSystemsLab.start_run(opts) do
      try do
        {:ok, _request} = RunServer.start_stream(server)

        receive do
          {:scripted_gate, ^gate, worker} ->
            monitor = Process.monitor(worker)
            {:ok, cancelled} = RunServer.cancel(server, "p1_cancelled_during_arguments")

            receive do
              {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
            after
              5_000 -> raise "cancelled provider did not stop"
            end

            true = cancelled.state.operations == %{}
            true = cancelled.file_stats.writes == 0

            if storage == :postgres do
              {:ok, saved} = Storage.load(id)
              true = saved.state === cancelled.state
              nil = saved.intent
            end

            {:ok, cancelled}
        after
          5_000 -> {:error, :p1_gate_timeout}
        end
      after
        GenServer.stop(server)
      end
    end
  end

  defp crash_evidence(:memory), do: {:ok, "not_run_in_memory_mode"}
  defp crash_evidence(:postgres), do: StorageVerification.run()

  defp verify_canonical_session(_session, :memory), do: :ok

  defp verify_canonical_session(session, :postgres) do
    case SessionStore.load(session.id) do
      {:ok, ^session} -> :ok
      _ -> {:error, :canonical_session_was_changed}
    end
  end

  defp export_contexts(output, session, contexts) do
    File.mkdir!(Path.join(output, "contexts"))
    {:ok, source} = Codec.encode(Session.to_map(session))
    File.write!(Path.join(output, "session.bin"), source)

    contexts
    |> Enum.with_index(1)
    |> Enum.each(fn {item, index} ->
      prefix =
        Path.join(output, "contexts/#{String.pad_leading(Integer.to_string(index), 2, "0")}")

      bundle = %{
        context: item.built.context,
        manifest: item.built.manifest,
        session: Session.to_map(session),
        run: item.run,
        permissions: item.permissions,
        context_options: @context_options
      }

      {:ok, binary} = Codec.encode(bundle)
      File.write!(prefix <> ".bin", binary)

      File.write!(
        prefix <> "-manifest.json",
        JSON.encode!(json_view(item.built.manifest)) <> "\n"
      )
    end)

    :ok
  end

  defp json_view(value) when is_struct(value), do: value |> Map.from_struct() |> json_view()

  defp json_view(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_view(item)} end)

  defp json_view(value) when is_list(value), do: Enum.map(value, &json_view/1)
  defp json_view(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_view()
  defp json_view(value) when value in [nil, true, false], do: value
  defp json_view(value) when is_atom(value), do: Atom.to_string(value)
  defp json_view(value), do: value
end
