defmodule AgentSystemsLab.HistoryMigration do
  @moduledoc """
  Explicit, bounded migration from history layout 1 to 2, under the Run lock.

  This changes storage representation only. Event schema, projection, intents,
  policies, budgets, captures, checkpoints and model recordings retain their
  original bytes and meanings. A journal binds the migrated prefix; subsequent
  format-2 events extend that prefix without invalidating its provenance.

  Plan is read-only. Migrate requires the current sequence and a real outer
  COMMIT, rejects a live execution lease, and never invokes providers or tools.
  Hooks expose the same before/after COMMIT crash windows as Storage.
  """
  import Ecto.Query
  alias AgentSystemsLab.{IntentStore, Repo, Storage}
  alias AgentSystemsLab.History.Encoding
  alias AgentSystemsLab.Kernel, as: RunKernel
  alias AgentSystemsLab.Storage.{Run, Codec}
  alias AgentSystemsLab.Storage.Event, as: StoredEvent
  alias AgentSystemsLab.Storage.HistoryMigration, as: Journal

  @max_events 4096
  @max_bytes 32 * 1024 * 1024

  def limits, do: %{max_events: @max_events, max_bytes: @max_bytes}

  @doc "Returns a verified migration plan without changing any row."
  def plan(run_id) do
    with :ok <- validate_id(run_id) do
      Repo.transaction(fn ->
        with {:ok, run} <- fetch_run(run_id, "FOR SHARE"),
             {:ok, rows} <- bounded_rows(run_id),
             {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
             {:ok, result} <- build_plan(run, rows, snapshot),
             do: result,
             else: ({:error, reason} -> Repo.rollback(reason))
      end)
    end
  end

  @doc "Migrates only layout 1 to 2; repeated calls validate and return already_current."
  def migrate(run_id, expected_seq, opts \\ []) do
    with :ok <- boundary(),
         :ok <- validate_id(run_id),
         :ok <- validate_sequence(expected_seq),
         :ok <- options(opts) do
      case Repo.transaction(fn -> migrate_locked(run_id, expected_seq, opts) end) do
        {:ok, %{status: :migrated} = result} ->
          hook(opts, :after_commit)
          {:ok, result}

        other ->
          other
      end
    end
  end

  defp migrate_locked(run_id, expected_seq, opts) do
    with {:ok, run} <- fetch_run(run_id, "FOR UPDATE"),
         true <- run.seq === expected_seq || {:error, {:stale_sequence, expected_seq, run.seq}},
         {:ok, rows} <- bounded_rows(run_id),
         {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
         :ok <- IntentStore.ensure_unclaimed(Repo, snapshot.intent),
         {:ok, plan} <- build_plan(run, rows, snapshot) do
      if run.history_format == 2 do
        %{plan | status: :already_current}
      else
        with {:ok, target_rows} <- wrap_rows(rows),
             :ok <- persist_rows(target_rows),
             {:ok, updated_run} <- Repo.update(Run.changeset(run, %{history_format: 2})),
             {:ok, _journal} <- insert_journal(run, rows, target_rows, snapshot),
             {:ok, after_snapshot} <- Storage.snapshot_in_transaction(Repo, updated_run),
             true <- snapshot === after_snapshot || {:error, :migration_semantic_mismatch} do
          hook(opts, :before_commit)
          %{plan | status: :migrated}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def verify_in_transaction(repo, run, rows, events) do
    case {run.history_format, repo.get(Journal, run.id)} do
      {1, nil} -> :ok
      {1, _journal} -> {:error, :unexpected_history_migration}
      {2, nil} -> {:error, :missing_history_migration}
      {2, journal} -> verify_journal(run, rows, events, journal)
      {format, _} -> Encoding.validate_format(format)
    end
  end

  defp verify_journal(run, rows, events, journal) do
    prefix_rows = Enum.take(rows, journal.event_count)
    prefix_events = Enum.take(events, journal.event_count)

    with true <-
           (journal.source_format === 1 and journal.target_format === 2 and
              journal.codec_version === Codec.version() and journal.event_count in 1..@max_events and
              journal.prefix_seq === journal.event_count and journal.prefix_seq <= run.seq and
              length(prefix_rows) === journal.event_count) || {:error, :invalid_history_migration},
         :ok <- bound_bytes(prefix_rows),
         true <-
           Encoding.rows_hash(prefix_rows, 2) === journal.target_hash ||
             {:error, :history_target_hash_mismatch},
         {:ok, source_rows} <- unwrap_rows(prefix_rows),
         true <-
           Encoding.rows_hash(source_rows, 1) === journal.source_hash ||
             {:error, :history_source_hash_mismatch},
         {:ok, state} <- RunKernel.rebuild(run.id, prefix_events, max_turns: run.max_turns),
         true <-
           Encoding.semantic_hash(state, prefix_events) === journal.semantic_hash ||
             {:error, :history_semantic_hash_mismatch},
         do: :ok
  end

  defp build_plan(run, rows, snapshot) do
    case run.history_format do
      1 ->
        with {:ok, target_rows} <- wrap_rows(rows),
             :ok <- bound_bytes(target_rows) do
          {:ok,
           %{
             run_id: run.id,
             status: :ready,
             source_format: 1,
             target_format: 2,
             expected_seq: run.seq,
             prefix_seq: run.seq,
             event_count: length(rows),
             source_hash: Encoding.rows_hash(rows, 1),
             target_hash: Encoding.rows_hash(target_rows, 2),
             semantic_hash: Encoding.semantic_hash(snapshot.state, snapshot.events)
           }}
        end

      2 ->
        journal = Repo.get!(Journal, run.id)

        {:ok,
         %{
           run_id: run.id,
           status: :already_current,
           source_format: 1,
           target_format: 2,
           expected_seq: run.seq,
           prefix_seq: journal.prefix_seq,
           event_count: journal.event_count,
           source_hash: journal.source_hash,
           target_hash: journal.target_hash,
           semantic_hash: journal.semantic_hash
         }}
    end
  end

  defp insert_journal(run, source, target, snapshot) do
    Repo.insert(
      Journal.changeset(%Journal{}, %{
        run_id: run.id,
        source_format: 1,
        target_format: 2,
        prefix_seq: run.seq,
        event_count: length(source),
        source_hash: Encoding.rows_hash(source, 1),
        target_hash: Encoding.rows_hash(target, 2),
        semantic_hash: Encoding.semantic_hash(snapshot.state, snapshot.events),
        codec_version: 1
      })
    )
  end

  defp wrap_rows(rows) do
    collect(rows, fn row ->
      with {:ok, data} <- Encoding.wrap(row.data, 1, 2),
           do: {:ok, %{row | data: data, history_format: 2}}
    end)
  end

  defp unwrap_rows(rows) do
    collect(rows, fn row ->
      with {:ok, data} <- Encoding.unwrap(row.data, row.history_format, row.codec_version),
           do: {:ok, %{row | data: data, history_format: 1}}
    end)
  end

  defp persist_rows(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      {count, _} =
        Repo.update_all(from(event in StoredEvent, where: event.id == ^row.id),
          set: [data: row.data, history_format: 2]
        )

      if count == 1, do: {:cont, :ok}, else: {:halt, {:error, :migration_event_missing}}
    end)
  end

  defp bounded_rows(run_id) do
    # Check aggregate byte length before materializing payloads. A row count cap
    # alone could still allocate gigabytes of hostile historical binaries.
    %{rows: [[count, bytes]]} =
      Repo.query!(
        "SELECT count(*), COALESCE(sum(octet_length(data)), 0)::bigint FROM lab_events WHERE run_id=$1",
        [run_id]
      )

    with true <- count <= @max_events || {:error, :history_migration_event_limit},
         true <- bytes <= @max_bytes || {:error, :history_migration_byte_limit} do
      {:ok,
       Repo.all(
         from(event in StoredEvent,
           where: event.run_id == ^run_id,
           order_by: event.seq,
           limit: @max_events
         )
       )}
    end
  end

  defp bound_bytes(rows) do
    if Enum.reduce(rows, 0, &(byte_size(&1.data) + &2)) <= @max_bytes,
      do: :ok,
      else: {:error, :history_migration_byte_limit}
  end

  defp fetch_run(run_id, lock) do
    query = from(run in Run, where: run.id == ^run_id)

    query =
      if lock == "FOR UPDATE",
        do: from(run in query, lock: "FOR UPDATE"),
        else: from(run in query, lock: "FOR SHARE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp collect(rows, fun) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case fun.(row) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) in 1..256, do: :ok
  defp validate_id(_), do: {:error, :invalid_run_id}
  defp validate_sequence(seq) when is_integer(seq) and seq >= 0, do: :ok
  defp validate_sequence(seq), do: {:error, {:invalid_expected_sequence, seq}}

  defp options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:hook] == [] and
         (not Keyword.has_key?(opts, :hook) or is_function(opts[:hook], 1)),
       do: :ok,
       else: {:error, :invalid_history_migration_options}
  end

  defp hook(opts, stage) do
    if callback = opts[:hook], do: callback.(stage), else: :ok
  end
end
