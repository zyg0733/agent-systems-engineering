defmodule AgentSystemsLab.History.ReadonlyProof do
  @moduledoc """
  Offline, bounded-in-scope verification without execution or observation export.

  Public readers validate the source's history, recordings, policies, budgets and
  workflow/approval bindings. A restored database stays under its write gate:
  raw SQL verifies identical bytes and independently rebuilds runs/checkpoints.
  A matching copy inherits the source's verified sidecar bindings by exact byte
  equality, not by invoking mutators against the restored database.

  This is a quiescent-database proof, not an online snapshot API. Full-column,
  schema and sequence fingerprints before/after refuse concurrent changes.
  Hashes are integrity evidence, not signatures or an execution authority.
  """
  alias AgentSystemsLab.{
    Approvals,
    Checkpoint,
    CheckpointStore,
    Context,
    ContextStore,
    DurableTools,
    History,
    ModelResultStore,
    Recovery,
    Repo,
    RetryStore,
    SessionStore,
    Storage,
    TaskBudgetStore,
    Workflows
  }

  alias AgentSystemsLab.History.{Compatibility, Encoding}
  alias AgentSystemsLab.Storage.Codec

  @event_types Map.new(
                 ~w(run_started tool_requested tool_result_recorded tool_reconciled run_succeeded run_failed run_cancelled)a,
                 fn type -> {Atom.to_string(type), type} end
               )
  @scope_keys ~w(runs workflows cases)
  @claim_keys ~w(claim_token claim_owner claim_expires_at claim_generation updated_at)

  def capture(scope) do
    guarded(fn ->
      query = &repo_query/2

      with {:ok, scope} <- normalize_scope(scope),
           :ok <- complete_scope(query, scope),
           {:ok, compatibility} <- Compatibility.check(),
           {:ok, before} <- fingerprint(query),
           {:ok, raw} <- raw_runs(query, scope["runs"]),
           {:ok, verified} <- verified_views(scope),
           {:ok, after_proof} <- fingerprint(query),
           true <- before === after_proof || {:error, :database_changed_during_verification} do
        {:ok,
         Map.merge(before, %{
           "schema_version" => 1,
           "proof_kind" => "verified_source",
           "database_name" => database_name(query),
           "scope" => scope,
           "scope_complete" => true,
           "compatibility" => compatibility,
           "raw_semantic_hash" => Context.hash(raw),
           "semantic_hash" => Context.hash(verified),
           "runs" =>
             Enum.map(
               raw,
               &Map.take(&1, [
                 "run_id",
                 "seq",
                 "status",
                 "state_hash",
                 "events_hash",
                 "checkpoint_count"
               ])
             ),
           "verified_readers" =>
             ~w(Storage Recovery full_rebuild checkpoint_rebuild ModelResultStore ContextStore TaskBudgetStore DurableTools RetryStore SessionStore Workflows Approvals)
         })}
      end
    end)
  end

  def capture_connection(conn, scope) do
    guarded(fn ->
      query = fn sql, params -> Postgrex.query!(conn, sql, params) end

      with {:ok, scope} <- normalize_scope(scope),
           :ok <- complete_scope(query, scope),
           {:ok, compatibility} <- Compatibility.check_connection(conn),
           {:ok, before} <- fingerprint(query),
           {:ok, raw} <- raw_runs(query, scope["runs"]),
           {:ok, after_proof} <- fingerprint(query),
           true <- before === after_proof || {:error, :database_changed_during_verification} do
        {:ok,
         Map.merge(before, %{
           "schema_version" => 1,
           "proof_kind" => "readonly_copy",
           "database_name" => database_name(query),
           "scope" => scope,
           "scope_complete" => true,
           "compatibility" => compatibility,
           "raw_semantic_hash" => Context.hash(raw),
           "runs" =>
             Enum.map(
               raw,
               &Map.take(&1, [
                 "run_id",
                 "seq",
                 "status",
                 "state_hash",
                 "events_hash",
                 "checkpoint_count"
               ])
             )
         })}
      end
    end)
  end

  @sequences ~w(lab_approval_events_id_seq lab_events_id_seq lab_intents_id_seq lab_retries_id_seq lab_workflow_control_events_id_seq lab_workflow_events_id_seq)
  @verified_readers ~w(Storage Recovery full_rebuild checkpoint_rebuild ModelResultStore ContextStore TaskBudgetStore DurableTools RetryStore SessionStore Workflows Approvals)
  @hash_pattern ~r/\A[0-9a-f]{64}\z/

  def compare(source, copy) do
    with :ok <- validate(source, :source), :ok <- validate(copy) do
      keys = ~w(schema_version scope database_hash protected_hash raw_semantic_hash compatibility)

      case Enum.find(keys, &(Map.get(source, &1) !== Map.get(copy, &1))) do
        nil -> :ok
        key -> {:error, {:restore_proof_mismatch, key}}
      end
    end
  end

  def compare_semantics(before, after_proof) do
    with :ok <- validate(before, :source), :ok <- validate(after_proof, :source) do
      case Enum.find(
             ~w(scope semantic_hash raw_semantic_hash protected_hash),
             &(Map.get(before, &1) !== Map.get(after_proof, &1))
           ) do
        nil -> :ok
        key -> {:error, {:restore_semantic_mismatch, key}}
      end
    end
  end

  @doc "Checks that a proof has complete, supported metadata before comparisons."
  def validate(proof, kind \\ :any) do
    valid =
      is_map(proof) and proof["schema_version"] === 1 and proof["scope_complete"] === true and
        proof["proof_kind"] in ["verified_source", "readonly_copy"] and
        (kind === :any or (kind === :source and proof["proof_kind"] === "verified_source")) and
        is_binary(proof["database_name"]) and byte_size(proof["database_name"]) in 1..128 and
        match?({:ok, _}, normalize_scope(proof["scope"])) and
        normalize_scope(proof["scope"]) === {:ok, proof["scope"]} and
        Enum.all?(
          ~w(schema_hash database_hash protected_hash raw_semantic_hash),
          &hash?(proof[&1])
        ) and
        valid_tables?(proof["tables"], proof["scope"]) and valid_sequences?(proof["sequences"]) and
        valid_compatibility?(proof["compatibility"]) and
        valid_run_summaries?(proof["runs"], proof["scope"]) and
        (proof["proof_kind"] !== "verified_source" or
           (hash?(proof["semantic_hash"]) and proof["verified_readers"] === @verified_readers))

    if valid, do: :ok, else: {:error, :invalid_restore_proof}
  rescue
    _ -> {:error, :invalid_restore_proof}
  end

  defp valid_tables?(tables, scope) when is_list(tables) do
    names = Compatibility.tables() ++ ["schema_migrations"]

    Enum.map(tables, & &1["table"]) === names and
      Enum.all?(tables, fn row ->
        is_map(row) and Enum.sort(Map.keys(row)) === ~w(row_count sha256 table) and
          is_integer(row["row_count"]) and row["row_count"] >= 0 and hash?(row["sha256"])
      end) and
      Enum.all?(
        [{"lab_runs", "runs"}, {"lab_workflows", "workflows"}, {"lab_approval_cases", "cases"}],
        fn {table, key} ->
          Enum.find(tables, &(&1["table"] === table))["row_count"] === length(scope[key])
        end
      ) and
      Enum.find(tables, &(&1["table"] === "schema_migrations"))["row_count"] ===
        length(Compatibility.migration_versions())
  end

  defp valid_tables?(_, _), do: false

  defp valid_sequences?(sequences) when is_list(sequences) do
    Enum.map(sequences, & &1["sequence"]) === @sequences and
      Enum.all?(sequences, fn row ->
        is_map(row) and Enum.sort(Map.keys(row)) === ~w(is_called last_value sequence) and
          is_boolean(row["is_called"]) and is_integer(row["last_value"]) and
          row["last_value"] in 1..9_223_372_036_854_775_807
      end)
  end

  defp valid_sequences?(_), do: false

  defp valid_compatibility?(%{
         "matrix" => matrix,
         "migration_versions" => migrations,
         "tables" => tables
       })
       when is_list(tables) do
    matrix === Compatibility.matrix() and migrations === Compatibility.migration_versions() and
      Enum.map(tables, & &1["table"]) === Compatibility.tables() and
      Enum.all?(tables, fn row ->
        expected = Compatibility.column_names()[row["table"]]
        columns = row["columns"]

        is_list(columns) and
          Enum.all?(columns, fn
            [name, type, nullable] ->
              is_binary(name) and is_binary(type) and nullable in ["YES", "NO"]

            _ ->
              false
          end) and Enum.sort(Enum.map(columns, &hd/1)) === Enum.sort(expected) and
          valid_version_metadata?(row["versions"], expected)
      end)
  end

  defp valid_compatibility?(_), do: false

  defp valid_version_metadata?(versions, columns) when is_map(versions) do
    keys =
      Enum.filter(
        columns,
        &(&1 in ~w(schema_version codec_version history_format source_format target_format))
      )
      |> Enum.sort()

    Enum.sort(Map.keys(versions)) === keys and
      Enum.all?(versions, fn {key, values} ->
        supported =
          if key in ~w(history_format source_format target_format), do: [1, 2], else: [1]

        is_list(values) and Enum.sort(Enum.uniq(values)) === values and
          Enum.all?(values, &(&1 in supported))
      end)
  end

  defp valid_version_metadata?(_, _), do: false

  defp valid_run_summaries?(runs, scope) when is_list(runs) do
    Enum.map(runs, & &1["run_id"]) === scope["runs"] and
      Enum.all?(runs, fn row ->
        is_integer(row["seq"]) and row["seq"] >= 1 and
          row["status"] in ~w(running waiting_tool blocked succeeded failed cancelled) and
          hash?(row["state_hash"]) and hash?(row["events_hash"]) and
          is_integer(row["checkpoint_count"]) and row["checkpoint_count"] >= 0
      end)
  end

  defp valid_run_summaries?(_, _), do: false
  defp hash?(value), do: is_binary(value) and Regex.match?(@hash_pattern, value)

  def scope do
    {:ok,
     Map.new(
       [{"runs", "lab_runs"}, {"workflows", "lab_workflows"}, {"cases", "lab_approval_cases"}],
       fn {key, table} ->
         {key, repo_query("SELECT id FROM #{table} ORDER BY id", []).rows |> List.flatten()}
       end
     )}
  end

  def fingerprint_connection(conn),
    do: guarded(fn -> fingerprint(fn sql, params -> Postgrex.query!(conn, sql, params) end) end)

  defp verified_views(scope) do
    with {:ok, runs} <- collect(scope["runs"], &verified_run/1),
         {:ok, workflows} <- collect(scope["workflows"], &Workflows.load/1),
         {:ok, cases} <- collect(scope["cases"], &Approvals.load/1),
         session_ids =
           repo_query("SELECT id FROM lab_sessions ORDER BY id", []).rows |> List.flatten(),
         {:ok, sessions} <- collect(session_ids, &SessionStore.load/1) do
      {:ok, %{runs: runs, workflows: workflows, cases: cases, sessions: sessions}}
    end
  end

  defp verified_run(id) do
    with {:ok, snapshot} <- Storage.load(id),
         {:ok, full} <- CheckpointStore.rebuild(id, mode: :full),
         {:ok, checkpoint} <- CheckpointStore.rebuild(id, mode: :checkpoint),
         true <-
           (full.state === checkpoint.state and full.state === snapshot.state) ||
             {:error, :rebuild_state_mismatch},
         {:ok, recovery} <- recovery(id),
         {:ok, results} <- ModelResultStore.list(id),
         {:ok, contexts} <- ContextStore.list(id),
         {:ok, budget} <- TaskBudgetStore.load(id),
         {:ok, operations} <- DurableTools.list(id),
         {:ok, retries} <- RetryStore.list(id) do
      normalized_snapshot = normalize_snapshot(snapshot)

      recovery =
        if recovery, do: Map.put(recovery, :intent, normalized_snapshot.intent), else: nil

      {:ok,
       %{
         snapshot: normalized_snapshot,
         recovery: recovery,
         results: results,
         contexts: contexts,
         budget: budget,
         operations: operations,
         retries: retries
       }}
    end
  end

  defp recovery(id) do
    case repo_query("SELECT 1 FROM lab_recovery WHERE run_id = $1", [id]).rows do
      [] -> {:ok, nil}
      [[1]] -> Recovery.load(id)
    end
  end

  defp normalize_snapshot(snapshot) do
    case snapshot.intent do
      nil ->
        snapshot

      intent ->
        Map.put(
          snapshot,
          :intent,
          intent
          |> Map.from_struct()
          |> Map.drop(Enum.map(@claim_keys, &String.to_existing_atom/1))
        )
    end
  end

  defp raw_runs(query, ids) do
    Storage.preload_vocabulary()

    collect(ids, fn id ->
      [row] =
        query.(
          "SELECT id, status, seq, max_turns, state_data, codec_version, history_format FROM lab_runs WHERE id = $1",
          [id]
        ).rows

      [^id, status, seq, max_turns, bytes, codec, format] = row

      with :ok <- Encoding.validate_format(format),
           {:ok, stored_state} <- Codec.decode(bytes, codec),
           {:ok, events} <- raw_events(query, id, format),
           {:ok, rebuilt} <- History.rebuild(id, events, max_turns: max_turns),
           true <-
             (stored_state === rebuilt and rebuilt.seq === seq and
                Atom.to_string(rebuilt.status) === status) ||
               {:error, :restore_projection_mismatch},
           {:ok, checkpoints} <- raw_checkpoints(query, id, events, rebuilt) do
        {:ok,
         %{
           "run_id" => id,
           "seq" => seq,
           "status" => status,
           "state_hash" => Context.hash(rebuilt),
           "events_hash" => Context.hash(events),
           "checkpoint_count" => length(checkpoints),
           "checkpoints_hash" => Context.hash(checkpoints)
         }}
      end
    end)
  end

  defp raw_events(query, id, format) do
    query.(
      "SELECT seq,type,schema_version,data,codec_version,history_format FROM lab_events WHERE run_id=$1 ORDER BY seq",
      [id]
    ).rows
    |> collect(fn [seq, type, schema, bytes, codec, event_format] ->
      with true <- format === event_format || {:error, :mixed_history_formats},
           {:ok, type} <- event_type(type),
           {:ok, data} <-
             Encoding.decode_event(%{
               data: bytes,
               codec_version: codec,
               history_format: event_format
             }) do
        {:ok,
         %AgentSystemsLab.Kernel.Event{
           run_id: id,
           seq: seq,
           type: type,
           schema_version: schema,
           data: data
         }}
      end
    end)
  end

  defp raw_checkpoints(query, id, events, state) do
    query.(
      "SELECT last_seq,schema_version,codec_version,data FROM lab_checkpoints WHERE run_id=$1 ORDER BY last_seq",
      [id]
    ).rows
    |> collect(fn [seq, schema, codec, bytes] ->
      with {:ok, checkpoint} <- Codec.decode(bytes, codec),
           true <-
             (schema === 1 and checkpoint.schema_version === schema and
                checkpoint.last_seq === seq and checkpoint.run_id === id and
                checkpoint.max_turns === state.max_turns and seq <= state.seq) ||
               {:error, :restore_checkpoint_metadata_mismatch},
           :ok <- Checkpoint.verify(checkpoint, Enum.take(events, seq)),
           {:ok, rebuilt} <- History.from_checkpoint(checkpoint, Enum.drop(events, seq)),
           true <- rebuilt === state || {:error, :restore_checkpoint_state_mismatch} do
        {:ok, checkpoint}
      end
    end)
  end

  defp fingerprint(query) do
    tables = Compatibility.tables() ++ ["schema_migrations"]

    entries =
      Enum.map(tables, fn table ->
        rows =
          query.(
            "SELECT row_to_json(t)::text AS row FROM #{quote_id(table)} t ORDER BY row_to_json(t)::text COLLATE \"C\"",
            []
          ).rows
          |> List.flatten()

        %{"table" => table, "row_count" => length(rows), "sha256" => Context.hash(rows)}
      end)

    protected =
      Enum.map(tables, fn
        "lab_intents" = table ->
          rows =
            query.(
              "SELECT (to_jsonb(t) - ARRAY['claim_token','claim_owner','claim_expires_at','claim_generation','updated_at'])::text AS row FROM lab_intents t ORDER BY (to_jsonb(t) - ARRAY['claim_token','claim_owner','claim_expires_at','claim_generation','updated_at'])::text COLLATE \"C\"",
              []
            ).rows
            |> List.flatten()

          %{"table" => table, "row_count" => length(rows), "sha256" => Context.hash(rows)}

        table ->
          Enum.find(entries, &(&1["table"] === table))
      end)

    sequences =
      query.(
        "SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename",
        []
      ).rows
      |> Enum.map(fn [name] ->
        [[value, called]] = query.("SELECT last_value, is_called FROM #{quote_id(name)}", []).rows
        %{"sequence" => name, "last_value" => value, "is_called" => called}
      end)

    schema =
      query.(
        "SELECT c.relname, a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, pg_get_expr(d.adbin,d.adrelid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname='public' AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped ORDER BY c.relname,a.attnum",
        []
      ).rows

    constraints =
      query.(
        "SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY tablename,indexname",
        []
      ).rows ++
        query.(
          "SELECT c.relname,k.conname,pg_get_constraintdef(k.oid,true) FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' ORDER BY c.relname,k.conname",
          []
        ).rows

    schema_hash = Context.hash({schema, constraints})

    {:ok,
     %{
       "tables" => Enum.sort_by(entries, & &1["table"]),
       "sequences" => sequences,
       "schema_hash" => schema_hash,
       "database_hash" => Context.hash({entries, sequences, schema_hash}),
       "protected_hash" => Context.hash({protected, sequences, schema_hash})
     }}
  end

  defp complete_scope(query, scope) do
    Enum.reduce_while(
      [{"runs", "lab_runs"}, {"workflows", "lab_workflows"}, {"cases", "lab_approval_cases"}],
      :ok,
      fn {key, table}, :ok ->
        actual = query.("SELECT id FROM #{table} ORDER BY id", []).rows |> List.flatten()

        if actual === scope[key],
          do: {:cont, :ok},
          else: {:halt, {:error, {:incomplete_restore_scope, key}}}
      end
    )
  end

  defp normalize_scope(scope) when is_map(scope) do
    normalized =
      Map.new(scope, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

    valid =
      Enum.sort(Map.keys(normalized)) === Enum.sort(@scope_keys) and
        Enum.all?(Map.values(normalized), fn ids ->
          is_list(ids) and length(ids) <= 1000 and
            Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)) and
            length(ids) === length(Enum.uniq(ids))
        end)

    if valid,
      do: {:ok, Map.new(normalized, fn {key, ids} -> {key, Enum.sort(ids)} end)},
      else: {:error, :invalid_restore_scope}
  end

  defp normalize_scope(_), do: {:error, :invalid_restore_scope}

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp guarded(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :readonly_verification_failed}
    catch
      _, _ -> {:error, :readonly_verification_failed}
    end
  end

  defp event_type(type) do
    case Map.fetch(@event_types, type) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_event_type, type}}
    end
  end

  defp database_name(query), do: query.("SELECT current_database()", []).rows |> hd() |> hd()
  defp quote_id(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  defp repo_query(sql, params), do: Repo.query!(sql, params)
end
