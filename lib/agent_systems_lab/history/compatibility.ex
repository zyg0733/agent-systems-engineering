defmodule AgentSystemsLab.History.Compatibility do
  @moduledoc """
  Fail-closed database envelope compatibility checks for an offline restore.

  This checks every durable table, not just rows selected for a demonstration.
  Kernel and embedded payload versions are additionally verified by ReadonlyProof's
  public readers. Version numbers are separate domains; history format 2 does not
  imply kernel schema 2 or codec 2.
  """
  alias AgentSystemsLab.Repo

  @schemas [
    AgentSystemsLab.Storage.Run,
    AgentSystemsLab.Storage.Event,
    AgentSystemsLab.Storage.Intent,
    AgentSystemsLab.Storage.Session,
    AgentSystemsLab.Storage.Context,
    AgentSystemsLab.Storage.Checkpoint,
    AgentSystemsLab.Storage.ModelResult,
    AgentSystemsLab.Storage.Recovery,
    AgentSystemsLab.Storage.Operation,
    AgentSystemsLab.Storage.Attempt,
    AgentSystemsLab.Storage.MockEffect,
    AgentSystemsLab.Storage.Retry,
    AgentSystemsLab.Storage.Queue,
    AgentSystemsLab.Storage.TaskBudget,
    AgentSystemsLab.Storage.Workflow,
    AgentSystemsLab.Storage.WorkflowNode,
    AgentSystemsLab.Storage.WorkflowEvent,
    AgentSystemsLab.Storage.WorkflowControl,
    AgentSystemsLab.Storage.WorkflowControlEvent,
    AgentSystemsLab.Storage.ApprovalCase,
    AgentSystemsLab.Storage.ApprovalEvent
  ]
  @migration_versions [
    20_261_020_000_000,
    20_261_020_010_000,
    20_261_020_020_000,
    20_261_020_030_000,
    20_261_020_040_000,
    20_261_020_050_000,
    20_261_020_060_000,
    20_261_020_070_000,
    20_261_020_080_000,
    20_261_020_090_000,
    20_261_021_000_000,
    20_261_021_010_000,
    20_261_021_020_000,
    20_261_021_030_000,
    20_261_021_040_000,
    20_261_022_000_000,
    20_261_023_000_000,
    20_261_024_000_000,
    20_261_024_010_000,
    20_261_024_020_000,
    20_261_025_000_000
  ]
  @journal "lab_history_migrations"
  @journal_columns ~w(run_id source_format target_format prefix_seq event_count source_hash target_hash semantic_hash codec_version inserted_at)

  def matrix do
    %{
      "kernel_schema" => [1],
      "event_schema" => [1],
      "codec" => [1],
      "history_format" => [1, 2],
      "sidecar_schema" => [1],
      "unknown_version_policy" => "reject"
    }
  end

  def tables, do: Enum.sort([@journal | Enum.map(@schemas, & &1.__schema__(:source))])
  def migration_versions, do: @migration_versions

  def column_names do
    Map.new(@schemas, fn schema ->
      {schema.__schema__(:source), Enum.map(schema.__schema__(:fields), &Atom.to_string/1)}
    end)
    |> Map.put(@journal, @journal_columns)
  end

  def validate_versions(%{} = versions) do
    allowed = %{
      "kernel_schema" => [1],
      "event_schema" => [1],
      "codec" => [1],
      "history_format" => [1, 2],
      "sidecar_schema" => [1]
    }

    Enum.reduce_while(versions, :ok, fn {domain, version}, :ok ->
      domain = if is_atom(domain), do: Atom.to_string(domain), else: domain

      case Map.fetch(allowed, domain) do
        {:ok, supported} ->
          if version in supported,
            do: {:cont, :ok},
            else: {:halt, {:error, {:incompatible_version, domain, version}}}

        :error ->
          {:halt, {:error, {:unknown_version_domain, domain}}}
      end
    end)
  end

  def validate_versions(_), do: {:error, :invalid_version_manifest}

  def check, do: check_with(&query!/2)

  def check_connection(conn),
    do: check_with(fn sql, params -> Postgrex.query!(conn, sql, params) end)

  defp check_with(query) do
    try do
      actual =
        query.(
          "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'lab\\_%' ESCAPE '\\' ORDER BY tablename",
          []
        ).rows
        |> List.flatten()

      expected = tables()

      cond do
        expected -- actual != [] ->
          {:error, {:missing_history_tables, expected -- actual}}

        actual -- expected != [] ->
          {:error, {:unknown_history_tables, actual -- expected}}

        true ->
          with :ok <- check_migrations(query), do: check_tables(query)
      end
    rescue
      _ -> {:error, :compatibility_query_failed}
    end
  end

  defp check_migrations(query) do
    case query.("SELECT to_regclass('public.schema_migrations')", []).rows do
      [[nil]] ->
        {:error, :missing_schema_migrations}

      _ ->
        versions =
          query.("SELECT version FROM schema_migrations ORDER BY version", []).rows
          |> List.flatten()

        cond do
          @migration_versions -- versions != [] ->
            {:error, {:missing_database_migrations, @migration_versions -- versions}}

          versions -- @migration_versions != [] ->
            {:error, {:unknown_database_migrations, versions -- @migration_versions}}

          true ->
            :ok
        end
    end
  end

  defp check_tables(query) do
    requirements =
      Enum.map(@schemas, fn schema ->
        {schema.__schema__(:source), Enum.map(schema.__schema__(:fields), &Atom.to_string/1)}
      end) ++ [{@journal, @journal_columns}]

    Enum.reduce_while(requirements, {:ok, []}, fn {table, fields}, {:ok, acc} ->
      columns =
        query.(
          "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position",
          [table]
        ).rows

      names = Enum.map(columns, &hd/1)

      cond do
        fields -- names != [] ->
          {:halt, {:error, {:missing_history_columns, table, fields -- names}}}

        names -- fields != [] ->
          {:halt, {:error, {:unknown_history_columns, table, names -- fields}}}

        true ->
          case check_columns(query, table, names) do
            {:ok, versions} ->
              {:cont,
               {:ok, [%{"table" => table, "columns" => columns, "versions" => versions} | acc]}}

            error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, checked} ->
        {:ok,
         %{
           "matrix" => matrix(),
           "migration_versions" => @migration_versions,
           "tables" => Enum.sort_by(checked, & &1["table"])
         }}

      error ->
        error
    end
  end

  defp check_columns(query, table, names) do
    names
    |> Enum.filter(
      &(&1 in [
          "schema_version",
          "codec_version",
          "history_format",
          "source_format",
          "target_format"
        ])
    )
    |> Enum.reduce_while({:ok, %{}}, fn column, {:ok, acc} ->
      supported =
        if column in ["history_format", "source_format", "target_format"], do: [1, 2], else: [1]

      values =
        query.(
          "SELECT DISTINCT #{quote_id(column)} FROM #{quote_id(table)} ORDER BY #{quote_id(column)}",
          []
        ).rows
        |> List.flatten()

      case Enum.find(values, &(&1 not in supported)) do
        nil ->
          if nil in values,
            do: {:halt, {:error, {:incompatible_history_column, table, column, nil}}},
            else: {:cont, {:ok, Map.put(acc, column, values)}}

        version ->
          {:halt, {:error, {:incompatible_history_column, table, column, version}}}
      end
    end)
  end

  defp quote_id(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  defp query!(sql, params), do: Repo.query!(sql, params)
end
