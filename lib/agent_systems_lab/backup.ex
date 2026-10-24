defmodule AgentSystemsLab.Backup do
  @moduledoc """
  Trusted-host PostgreSQL logical backup exercises in fresh, capability-owned databases.

  Archives execute trusted SQL during restore. A checksum detects damaged bytes; it
  does not authenticate an imported archive. Only bundles minted by this process's
  private registry are accepted. The database default read-only gate is an operational
  interlock, not a security boundary against a database owner or superuser.
  """
  alias AgentSystemsLab.Backup.{Bundle, Command, Handle, Manager}

  @tools Path.expand("../../.runtime/postgres/18.6/bin", __DIR__)
  @max_archive_bytes 268_435_456
  @database_pattern ~r/\Alab_w21_[0-9a-f]{32}\z/
  @marker_prefix "agent_systems_lab.week21:"

  def create_lab_database(label) when is_binary(label) and byte_size(label) in 1..128 do
    with {:ok, connection} <- base_connection(),
         :ok <- tools_available(),
         database = "lab_w21_" <> random_hex(16),
         marker = @marker_prefix <> random_hex(32),
         :ok <- admin(connection, &create_database(&1, database, marker)),
         {:ok, capability} <-
           Manager.put(:database, %{
             database: database,
             marker: marker,
             connection: connection,
             label: label,
             origin: :created,
             readonly: false,
             source_database: nil,
             dump_sha256: nil
           }) do
      {:ok, %Handle{capability: capability}}
    end
  rescue
    _ -> {:error, :backup_database_create_failed}
  catch
    :exit, _ -> {:error, :backup_database_create_failed}
  end

  def create_lab_database(_), do: {:error, :invalid_backup_label}

  def metadata(handle) do
    with {:ok, value} <- owned(handle),
         do:
           {:ok,
            Map.take(value, [
              :database,
              :label,
              :origin,
              :readonly,
              :source_database,
              :dump_sha256
            ])}
  end

  @doc "Private host configuration. Never include these credentials in exported evidence."
  def connection_options(handle) do
    with {:ok, value} <- owned(handle),
         do: {:ok, Keyword.put(value.connection, :database, value.database)}
  end

  def with_connection(handle, fun) when is_function(fun, 1) do
    with {:ok, options} <- connection_options(handle), do: connect(options, fun)
  end

  @doc "Private child environment for a fixed trusted BEAM entry point; never shell source."
  def child_env(handle) do
    with {:ok, value} <- owned(handle) do
      {:ok,
       pg_environment(value.connection, value.database) ++
         [
           {"DATABASE_URL", database_url(value.connection, value.database)},
           {"LAB_DATABASE_ENABLED", "true"},
           {"LAB_SCHEDULER_ENABLED", "false"}
         ]}
    end
  end

  def dump(handle, output_directory) do
    with {:ok, value} <- owned(handle),
         :ok <- fresh_directory(output_directory),
         archive = Path.join(output_directory, "database.dump"),
         temporary_archive = Path.join(output_directory, "database.dump.tmp"),
         manifest_path = Path.join(output_directory, "manifest.json"),
         :ok <- private_file(temporary_archive, ""),
         {:ok, _} <-
           Command.run(
             tool("pg_dump"),
             [
               "--format=custom",
               "--no-owner",
               "--no-acl",
               "--file",
               temporary_archive,
               "--dbname",
               value.database
             ],
             pg_environment(value.connection, value.database),
             timeout_ms: 60_000,
             output_file: {temporary_archive, @max_archive_bytes}
           ),
         {:ok, sha256, bytes} <- archive_digest(temporary_archive),
         {:ok, versions} <- schema_versions(handle),
         {:ok, tool_version} <- tool_version("pg_dump"),
         {:ok, restore_tool_version} <- tool_version("pg_restore"),
         {:ok, server_version} <- server_version(handle),
         manifest = %{
           "schema_version" => 1,
           "format" => "postgresql-custom-trusted-host.v1",
           "source_database" => value.database,
           "dump_sha256" => sha256,
           "dump_bytes" => bytes,
           "pg_dump_version" => tool_version,
           "pg_restore_version" => restore_tool_version,
           "server_version" => server_version,
           "schema_migrations" => versions,
           "logical_scope" => "one database; excludes roles, tablespaces and WAL",
           "trust" => "trusted host archive; checksum is not authentication"
         },
         manifest_bytes = JSON.encode!(manifest),
         :ok <- File.rename(temporary_archive, archive),
         :ok <- private_file(manifest_path, manifest_bytes),
         {:ok, capability} <-
           Manager.put(:bundle, %{
             directory: Path.expand(output_directory),
             archive: Path.expand(archive),
             manifest_path: Path.expand(manifest_path),
             manifest_bytes: manifest_bytes,
             manifest: manifest,
             connection: value.connection
           }) do
      {:ok, %Bundle{capability: capability}}
    end
  rescue
    _ -> {:error, :backup_dump_failed}
  catch
    :exit, _ -> {:error, :backup_dump_failed}
  end

  def bundle_metadata(bundle) do
    with {:ok, value} <- trusted_bundle(bundle), do: {:ok, value.manifest}
  end

  @doc "Restores only into a fresh capability-owned target, never an existing database."
  def restore(bundle, opts \\ []) do
    with :ok <- restore_options(opts),
         {:ok, value} <- trusted_bundle(bundle),
         {:ok, handle} <- create_lab_database(Keyword.get(opts, :label, "restored")) do
      result =
        with {:ok, target} <- owned(handle),
             {:ok, _} <-
               Command.run(
                 tool("pg_restore"),
                 [
                   "--exit-on-error",
                   "--single-transaction",
                   "--no-owner",
                   "--no-acl",
                   "--dbname",
                   target.database,
                   value.archive
                 ],
                 pg_environment(target.connection, target.database),
                 timeout_ms: 60_000
               ),
             :ok <- set_database_readonly(target, true),
             :ok <-
               Manager.update(:database, handle.capability, %{
                 readonly: true,
                 origin: :restored,
                 source_database: value.manifest["source_database"],
                 dump_sha256: value.manifest["dump_sha256"]
               }) do
          {:ok, handle}
        end

      case result do
        {:ok, _} -> result
        {:error, reason} -> {:error, {:backup_restore_failed, reason, handle}}
      end
    end
  rescue
    _ -> {:error, :backup_restore_failed}
  catch
    :exit, _ -> {:error, :backup_restore_failed}
  end

  @doc "Runs trusted proof/fencing before lifting the restored database's default gate."
  def activate_restore(handle, fun) when is_function(fun, 1) do
    :global.trans({{__MODULE__, :activation, handle}, self()}, fn ->
      do_activate_restore(handle, fun)
    end)
  end

  def activate_restore(_, _), do: {:error, :invalid_backup_activation}

  defp do_activate_restore(handle, fun) do
    with {:ok, %{origin: :restored, readonly: true} = target} <- owned(handle),
         {:ok, value} <-
           connect(Keyword.put(target.connection, :database, target.database), fn connection ->
             with {:ok, _} <-
                    Postgrex.query(connection, "SET default_transaction_read_only = off", []),
                  do: fun.(connection)
           end),
         :ok <- set_database_readonly(target, false),
         :ok <- Manager.update(:database, handle.capability, %{readonly: false}) do
      {:ok, value}
    else
      {:ok, _} -> {:error, :backup_target_not_staged}
      {:error, _} = error -> error
    end
  end

  @doc "Drops one exact owned, marker-matching database; active connections cause refusal."
  def drop(%Handle{} = handle) do
    with {:ok, value} <- owned(handle),
         :ok <-
           admin(value.connection, fn connection ->
             sql_ok(connection, "DROP DATABASE #{quote_database(value.database)}")
           end),
         :ok <- Manager.delete(:database, handle.capability) do
      :ok
    end
  end

  def drop(_), do: {:error, :invalid_backup_capability}

  defp owned(%Handle{capability: capability}) do
    with {:ok, value} <- Manager.get(:database, capability),
         true <- Regex.match?(@database_pattern, value.database),
         {:ok, marker} <-
           admin(value.connection, fn connection ->
             case Postgrex.query(
                    connection,
                    "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = $1",
                    [value.database]
                  ) do
               {:ok, %{rows: [[marker]]}} -> {:ok, marker}
               _ -> {:error, :backup_database_not_owned}
             end
           end),
         true <- marker == value.marker do
      {:ok, value}
    else
      false -> {:error, :backup_database_not_owned}
      {:error, _} = error -> error
    end
  end

  defp owned(_), do: {:error, :invalid_backup_capability}

  defp trusted_bundle(%Bundle{capability: capability}) do
    with {:ok, value} <- Manager.get(:bundle, capability),
         :ok <- no_symlinks(value.directory),
         {:ok, %{type: :regular, size: manifest_size}} <- File.lstat(value.manifest_path),
         true <- manifest_size == byte_size(value.manifest_bytes),
         {:ok, manifest_bytes} <- File.read(value.manifest_path),
         true <- manifest_bytes == value.manifest_bytes,
         {:ok, digest, bytes} <- archive_digest(value.archive),
         true <- digest == value.manifest["dump_sha256"] and bytes == value.manifest["dump_bytes"],
         :ok <- tools_available(),
         {:ok, dump_version} <- tool_version("pg_dump"),
         {:ok, restore_version} <- tool_version("pg_restore"),
         true <- dump_version == value.manifest["pg_dump_version"],
         true <- restore_version == value.manifest["pg_restore_version"] do
      {:ok, value}
    else
      false -> {:error, :backup_bundle_integrity_failed}
      _ -> {:error, :backup_bundle_integrity_failed}
    end
  end

  defp trusted_bundle(_), do: {:error, :invalid_backup_bundle}

  defp base_connection do
    config = Application.get_env(:agent_systems_lab, AgentSystemsLab.Repo, [])
    parsed = if config[:url], do: Ecto.Repo.Supervisor.parse_url(config[:url]), else: []
    config = Keyword.merge(config, parsed)
    connection = Keyword.take(config, [:hostname, :port, :username, :password, :ssl, :socket_dir])

    if is_binary(connection[:hostname]) and is_integer(connection[:port]) and
         is_binary(connection[:username]) and
         connection[:ssl] in [nil, false] and is_nil(connection[:socket_dir]) do
      {:ok, connection ++ [connect_timeout: 5_000, timeout: 10_000, backoff_type: :stop]}
    else
      {:error, :unsupported_backup_connection}
    end
  end

  defp admin(options, fun), do: connect(Keyword.put(options, :database, "postgres"), fun)

  defp connect(options, fun) do
    case Postgrex.start_link(options) do
      {:ok, connection} ->
        owner = self()

        spawn(fn ->
          owner_monitor = Process.monitor(owner)
          connection_monitor = Process.monitor(connection)
          send(owner, {:backup_connection_guarded, connection})

          receive do
            {:DOWN, ^owner_monitor, :process, ^owner, _} ->
              if Process.alive?(connection), do: Process.exit(connection, :kill)

            {:DOWN, ^connection_monitor, :process, ^connection, _} ->
              :ok
          end
        end)

        receive do
          {:backup_connection_guarded, ^connection} -> :ok
        end

        Process.unlink(connection)

        try do
          fun.(connection)
        after
          if Process.alive?(connection), do: GenServer.stop(connection)
        end

      _ ->
        {:error, :backup_database_unavailable}
    end
  catch
    :exit, _ -> {:error, :backup_database_unavailable}
  end

  defp create_database(connection, database, marker) do
    with :ok <-
           sql_ok(connection, "CREATE DATABASE #{quote_database(database)} TEMPLATE template0"),
         do: sql_ok(connection, "COMMENT ON DATABASE #{quote_database(database)} IS '#{marker}'")
  end

  defp set_database_readonly(value, enabled) do
    setting = if enabled, do: "on", else: "off"

    admin(
      value.connection,
      &sql_ok(
        &1,
        "ALTER DATABASE #{quote_database(value.database)} SET default_transaction_read_only = #{setting}"
      )
    )
  end

  defp sql_ok(connection, sql) do
    case Postgrex.query(connection, sql, []) do
      {:ok, _} -> :ok
      _ -> {:error, :backup_database_operation_failed}
    end
  end

  defp schema_versions(handle) do
    with_connection(handle, fn connection ->
      case Postgrex.query(connection, "SELECT to_regclass('public.schema_migrations')", []) do
        {:ok, %{rows: [[nil]]}} ->
          {:ok, []}

        {:ok, _} ->
          case Postgrex.query(
                 connection,
                 "SELECT version FROM schema_migrations ORDER BY version",
                 []
               ) do
            {:ok, %{rows: rows}} -> {:ok, List.flatten(rows)}
            _ -> {:error, :backup_schema_read_failed}
          end

        _ ->
          {:error, :backup_schema_read_failed}
      end
    end)
  end

  defp server_version(handle) do
    with_connection(handle, fn connection ->
      case Postgrex.query(connection, "SHOW server_version", []) do
        {:ok, %{rows: [[version]]}} -> {:ok, version}
        _ -> {:error, :backup_server_version_failed}
      end
    end)
  end

  defp tool_version(name) do
    with {:ok, output} <- Command.run(tool(name), ["--version"], [], timeout_ms: 2_000),
         do: {:ok, String.trim(output)}
  end

  defp restore_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:label]] and
         is_binary(Keyword.get(opts, :label, "restored")) do
      :ok
    else
      {:error, :invalid_restore_options}
    end
  end

  defp restore_options(_), do: {:error, :invalid_restore_options}

  defp fresh_directory(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         :ok <- no_symlinks(Path.dirname(path)),
         false <- File.exists?(path),
         :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      true -> {:error, :backup_output_exists}
      false -> {:error, :backup_output_must_be_absolute}
      {:error, _} -> {:error, :backup_output_unavailable}
    end
  end

  defp fresh_directory(_), do: {:error, :invalid_backup_output}

  defp private_file(path, contents) do
    with :ok <- File.write(path, contents, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp archive_digest(path) do
    with {:ok, %{type: :regular, size: bytes}} <- File.lstat(path),
         true <- bytes in 1..@max_archive_bytes,
         digest =
           File.stream!(path, 65_536)
           |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
           |> :crypto.hash_final() do
      {:ok, Base.encode16(digest, case: :lower), bytes}
    else
      _ -> {:error, :backup_archive_invalid}
    end
  end

  defp no_symlinks(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, prefix} ->
      candidate = if prefix == "", do: part, else: Path.join(prefix, part)

      case File.lstat(candidate) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, candidate}}
        _ -> {:halt, {:error, :backup_path_not_directory}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp tools_available do
    if Enum.all?(["pg_dump", "pg_restore"], &File.regular?(tool(&1))),
      do: :ok,
      else: {:error, :backup_native_tools_unavailable}
  end

  defp tool(name), do: Path.join(@tools, name)
  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp quote_database(database) do
    true = Regex.match?(@database_pattern, database)
    "\"" <> database <> "\""
  end

  defp pg_environment(options, database) do
    [
      {"PGHOST", options[:hostname]},
      {"PGPORT", to_string(options[:port])},
      {"PGUSER", options[:username]},
      {"PGPASSWORD", options[:password] || ""},
      {"PGDATABASE", database},
      {"PGCONNECT_TIMEOUT", "5"},
      {"PGHOSTADDR", ""},
      {"PGSERVICE", ""},
      {"PGSSLMODE", "disable"},
      {"PGPASSFILE", "/dev/null"},
      {"PGOPTIONS", "-c statement_timeout=45000 -c lock_timeout=5000"}
    ]
  end

  defp database_url(options, database) do
    user = URI.encode(options[:username], &URI.char_unreserved?/1)

    password =
      if options[:password],
        do: ":" <> URI.encode(options[:password], &URI.char_unreserved?/1),
        else: ""

    "ecto://#{user}#{password}@#{options[:hostname]}:#{options[:port]}/#{database}"
  end
end
