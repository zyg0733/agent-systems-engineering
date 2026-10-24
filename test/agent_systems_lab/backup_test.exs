defmodule AgentSystemsLab.BackupTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.Backup
  alias AgentSystemsLab.Backup.{Bundle, Command, Handle}

  @moduletag :database
  @moduletag timeout: 60_000

  setup do
    directory = Path.join(System.tmp_dir!(), "lab_w21_backup_" <> Ecto.UUID.generate())
    # macOS /var and /tmp are symlinks. Use their canonical writable parent.
    directory =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        Path.basename(directory)
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, source} = Backup.create_lab_database("backup-test")
    on_exit(fn -> assert Backup.drop(source) == :ok end)
    %{source: source, directory: directory}
  end

  test "native custom archive restores exact bytes into a new database behind a read-only gate",
       %{
         source: source,
         directory: directory
       } do
    assert {:ok, :seeded} =
             Backup.with_connection(source, fn connection ->
               Postgrex.query!(
                 connection,
                 "CREATE TABLE backup_probe (id integer PRIMARY KEY, body bytea NOT NULL)",
                 []
               )

               Postgrex.query!(connection, "INSERT INTO backup_probe VALUES ($1, $2)", [
                 7,
                 <<0, 255, 10, 39>>
               ])

               {:ok, :seeded}
             end)

    archive_directory = Path.join(directory, "archive")
    assert {:ok, bundle} = Backup.dump(source, archive_directory)
    assert {:ok, manifest} = Backup.bundle_metadata(bundle)
    assert manifest["format"] == "postgresql-custom-trusted-host.v1"
    assert manifest["dump_bytes"] > 0
    assert byte_size(manifest["dump_sha256"]) == 64
    assert {:ok, %{mode: mode}} = File.stat(Path.join(archive_directory, "database.dump"))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, %{mode: mode}} = File.stat(archive_directory)
    assert Bitwise.band(mode, 0o777) == 0o700

    assert {:ok, restored} = Backup.restore(bundle, label: "backup-restored-test")
    on_exit(fn -> assert Backup.drop(restored) == :ok end)
    assert {:ok, source_meta} = Backup.metadata(source)
    assert {:ok, %{origin: :restored, readonly: true} = target_meta} = Backup.metadata(restored)
    assert target_meta.database != source_meta.database
    assert target_meta.source_database == source_meta.database

    assert {:ok, :verified} =
             Backup.with_connection(restored, fn connection ->
               assert %{rows: [["on"]]} =
                        Postgrex.query!(connection, "SHOW transaction_read_only", [])

               assert %{rows: [[7, <<0, 255, 10, 39>>]]} =
                        Postgrex.query!(connection, "SELECT id, body FROM backup_probe", [])

               assert {:error, %{postgres: %{code: :read_only_sql_transaction}}} =
                        Postgrex.query(connection, "DELETE FROM backup_probe", [])

               {:ok, :verified}
             end)

    assert {:error, :proof_mismatch} =
             Backup.activate_restore(restored, fn _ -> {:error, :proof_mismatch} end)

    assert {:ok, %{readonly: true}} = Backup.metadata(restored)

    assert {:ok, :fenced} =
             Backup.activate_restore(restored, fn connection ->
               Postgrex.query!(connection, "UPDATE backup_probe SET body = $1 WHERE id = 7", [
                 "activated"
               ])

               {:ok, :fenced}
             end)

    assert {:ok, %{readonly: false}} = Backup.metadata(restored)

    assert {:error, :backup_target_not_staged} =
             Backup.activate_restore(restored, fn _ -> {:ok, :again} end)

    assert {:ok, :written} =
             Backup.with_connection(restored, fn connection ->
               Postgrex.query!(connection, "INSERT INTO backup_probe VALUES (8, 'ok')", [])
               {:ok, :written}
             end)
  end

  test "corrupted and forged bundles are rejected before a restore target is allocated", %{
    source: source,
    directory: directory
  } do
    archive_directory = Path.join(directory, "archive")
    assert {:ok, bundle} = Backup.dump(source, archive_directory)

    assert {:error, :invalid_restore_options} =
             Backup.restore(bundle, database: "agent_systems_lab_test")

    assert {:error, :invalid_restore_options} = Backup.restore(bundle, label: "a", label: "b")

    assert {:error, :backup_bundle_integrity_failed} =
             Backup.restore(%Bundle{capability: :crypto.strong_rand_bytes(32)})

    File.write!(Path.join(archive_directory, "database.dump"), "corruption", [:append])
    assert {:error, :backup_bundle_integrity_failed} = Backup.restore(bundle)
    assert {:error, :backup_output_exists} = Backup.dump(source, archive_directory)
  end

  test "manifest replacement, symlink paths and forged or stale database handles fail closed", %{
    source: source,
    directory: directory
  } do
    assert {:error, :invalid_backup_capability} =
             Backup.drop(%Handle{capability: :crypto.strong_rand_bytes(32)})

    assert {:ok, bundle} = Backup.dump(source, Path.join(directory, "archive"))
    manifest = Path.join(directory, "archive/manifest.json")
    bytes = File.read!(manifest)
    elsewhere = Path.join(directory, "manifest-copy.json")
    File.write!(elsewhere, bytes)
    File.rm!(manifest)
    File.ln_s!(elsewhere, manifest)
    assert {:error, :backup_bundle_integrity_failed} = Backup.restore(bundle)

    linked = Path.join(directory, "linked")
    File.ln_s!(directory, linked)
    assert {:error, :backup_output_unavailable} = Backup.dump(source, Path.join(linked, "new"))

    assert {:ok, disposable} = Backup.create_lab_database("stale")
    assert :ok = Backup.drop(disposable)
    assert {:error, :invalid_backup_capability} = Backup.drop(disposable)
  end

  test "ownership marker changes prevent cleanup of a database no longer recognized as owned", %{
    source: source
  } do
    assert {:ok, options} = Backup.connection_options(source)
    assert {:ok, metadata} = Backup.metadata(source)

    {:ok, connection} = Postgrex.start_link(Keyword.put(options, :database, "postgres"))
    Process.unlink(connection)

    %{rows: [[original_marker]]} =
      Postgrex.query!(
        connection,
        "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = $1",
        [metadata.database]
      )

    quoted = "\"" <> metadata.database <> "\""

    try do
      Postgrex.query!(connection, "COMMENT ON DATABASE #{quoted} IS 'changed-owner'", [])
      assert {:error, :backup_database_not_owned} = Backup.drop(source)
      Postgrex.query!(connection, "COMMENT ON DATABASE #{quoted} IS '#{original_marker}'", [])
    after
      GenServer.stop(connection)
    end
  end

  test "native guardian kills a timed-out process and bounds output" do
    assert {:error, :backup_command_timeout} =
             Command.run("/bin/sleep", ["10"], [], timeout_ms: 20, notify: self())

    assert_receive {:backup_command_started, pid}
    assert eventually_dead(pid)

    assert {:error, :backup_command_output_limit} =
             Command.run("/usr/bin/yes", [], [], timeout_ms: 2_000)

    assert {:error, :invalid_backup_command} =
             Command.run("/bin/sleep", ["10"], [], timeout_ms: 0)
  end

  test "native guardian kills only its owned process when the caller dies" do
    observer = self()

    owner =
      spawn(fn -> Command.run("/bin/sleep", ["30"], [], timeout_ms: 60_000, notify: observer) end)

    assert_receive {:backup_command_started, os_pid}, 2_000
    Process.exit(owner, :kill)
    assert eventually_dead(os_pid)
  end

  test "private PostgreSQL connections are closed if their caller is killed", %{source: source} do
    observer = self()

    owner =
      spawn(fn ->
        Backup.with_connection(source, fn connection ->
          send(observer, {:owned_connection, connection})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:owned_connection, connection}, 2_000
    monitor = Process.monitor(connection)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 2_000
  end

  defp eventually_dead(pid, attempts \\ 100)
  defp eventually_dead(_, 0), do: false

  defp eventually_dead(pid, attempts) do
    case System.cmd("/bin/kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(10)
        eventually_dead(pid, attempts - 1)

      _ ->
        true
    end
  end
end
