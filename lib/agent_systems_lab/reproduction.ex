defmodule AgentSystemsLab.Reproduction do
  @moduledoc """
  Source-only exports and fixed plans for a same-host clean build exercise.

  This trusted-host helper never evaluates exported source, installs software, or
  starts/stops a database. Checksums detect changed bytes; they do not authenticate
  a source tree or cached archive. Use private directories without concurrent writers.
  """

  import Bitwise, only: [band: 2]

  @root Path.expand("../..", __DIR__)
  @manifest "reproduction-source-manifest.json"
  @directories ~w(.github book config docs fixtures labs lib priv scripts test)
  # Keep the pre-license contract verifiable for immutable W22-W26 evidence.
  @legacy_files [
    ".formatter.exs",
    ".gitignore",
    ".tool-versions",
    "README.md",
    "mix.exs",
    "mix.lock",
    "Agent Systems Engineering 研究与落地计划.md"
  ]
  @license_files ~w(LICENSE LICENSE-DOCS NOTICE)
  @files @legacy_files ++ @license_files ++ [".gitattributes"]
  @max_files 10_000
  @max_source_bytes 67_108_864
  @max_source_file 2_097_152
  @max_manifest_bytes 4_194_304
  @cache_files [
    "downloads/otp-aarch64-apple-darwin.tar.gz",
    "downloads/elixir-1.20.4-otp-28.zip",
    "downloads/postgresql-18.6.tar.bz2",
    "downloads/postgresql-18.6.tar.bz2.sha256",
    "mix/elixir/1-20-otp-28/rebar3",
    "hex/cache.ets",
    "hex/packages/hexpm/db_connection-2.10.2.tar",
    "hex/packages/hexpm/decimal-3.2.0.tar",
    "hex/packages/hexpm/ecto-3.14.2.tar",
    "hex/packages/hexpm/ecto_sql-3.14.0.tar",
    "hex/packages/hexpm/postgrex-0.22.4.tar",
    "hex/packages/hexpm/telemetry-1.4.2.tar"
  ]
  @cache_directory "mix/archives/hex-2.5.3"
  @cache_max_bytes 268_435_456
  @cache_max_file 134_217_728

  def export(output, opts \\ []) do
    with :ok <- options(opts, [:source]),
         {:ok, source} <- directory(Keyword.get(opts, :source, @root)),
         {:ok, files, frozen} <- export_source_files(source),
         {:ok, entries} <- inventory(source, files ++ @directories, @max_source_file),
         :ok <- source_bounds(entries),
         :ok <- required_source(entries, files),
         true <- is_nil(frozen) or frozen == source_manifest(entries, files),
         {:ok, destination} <- fresh_output(output, source, entries),
         :ok <- File.mkdir(destination),
         :ok <- File.chmod(destination, 0o700),
         :ok <- copy_entries(source, destination, entries),
         {:ok, copied} <- inventory(destination, files ++ @directories, @max_source_file),
         true <- entries == copied,
         {:ok, current} <- inventory(source, files ++ @directories, @max_source_file),
         true <- entries == current,
         manifest = source_manifest(entries, files),
         :ok <- private_json(Path.join(destination, @manifest), manifest) do
      {:ok, result(destination, manifest)}
    else
      false -> {:error, :reproduction_source_changed}
      {:error, _} = error -> error
      _ -> {:error, :reproduction_export_failed}
    end
  rescue
    _ -> {:error, :reproduction_export_failed}
  end

  @doc "Checks source files even after deps, builds, runtime and experiment artifacts are added."
  def verify(output) do
    with {:ok, root} <- directory(output),
         {:ok, bytes} <- bounded_file(Path.join(root, @manifest), @max_manifest_bytes),
         {:ok, manifest} <- JSON.decode(bytes),
         {:ok, files} <- source_files(manifest),
         {:ok, entries} <- inventory(root, files ++ @directories, @max_source_file),
         :ok <- source_bounds(entries),
         :ok <- required_source(entries, files),
         true <- manifest == source_manifest(entries, files) do
      {:ok, result(root, manifest)}
    else
      false -> {:error, :reproduction_manifest_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :reproduction_manifest_invalid}
    end
  rescue
    _ -> {:error, :reproduction_manifest_invalid}
  end

  @doc "Copies only pinned warm caches. No installed runtime, deps, builds or database is copied."
  def stage_cache(output, opts \\ []) do
    with :ok <- options(opts, [:source]),
         {:ok, verified} <- verify(output),
         {:ok, source} <- directory(Keyword.get(opts, :source, @root)),
         {:ok, cache_source} <- directory(Path.join(source, ".runtime")),
         runtime = Path.join(verified.output_dir, ".runtime"),
         :ok <- absent(runtime),
         {:ok, entries} <-
           inventory(cache_source, @cache_files ++ [@cache_directory], @cache_max_file),
         true <- Enum.all?(@cache_files, fn name -> Enum.any?(entries, &(&1["path"] == name)) end),
         true <- Enum.any?(entries, &String.starts_with?(&1["path"], @cache_directory <> "/")),
         true <- length(entries) <= @max_files and total_bytes(entries) <= @cache_max_bytes,
         :ok <- File.mkdir(runtime),
         :ok <- File.chmod(runtime, 0o700),
         :ok <- copy_entries(cache_source, runtime, entries),
         {:ok, copied} <-
           inventory(runtime, @cache_files ++ [@cache_directory], @cache_max_file),
         true <- entries == copied,
         {:ok, current} <-
           inventory(cache_source, @cache_files ++ [@cache_directory], @cache_max_file),
         true <- entries == current,
         manifest = %{
           "schema_version" => 1,
           "kind" => "agent-systems-lab.warm-cache.v1",
           "scope" => "same-host cache reuse; not a fresh-machine installation",
           "trust" => "trusted host cache; SHA256 is integrity, not authentication",
           "build_tools" => [
             "Hex 2.5.3 archive",
             "Rebar3 executable at mix/elixir/1-20-otp-28/rebar3"
           ],
           "excludes" => ["installed runtime", "deps", "_build", "PGDATA", "database rows"],
           "entries" => entries,
           "total_bytes" => total_bytes(entries),
           "entries_sha256" => entries_hash(entries)
         },
         path = Path.join(runtime, "cache-provenance.json"),
         :ok <- private_json(path, manifest) do
      {:ok, %{runtime_dir: runtime, manifest_path: path, manifest: manifest}}
    else
      false -> {:error, :reproduction_cache_incomplete_or_changed}
      {:error, _} = error -> error
      _ -> {:error, :reproduction_cache_failed}
    end
  rescue
    _ -> {:error, :reproduction_cache_failed}
  end

  @doc """
  Returns data only. Commands are fixed; environment replaces inherited settings.

  A nil environment value means unset the variable, never the string "null" or
  an empty string. In particular, libpq treats an empty PGSERVICE as a service
  selection rather than clearing inherited service routing.
  """
  def plan(output, opts \\ []) do
    with :ok <- options(opts, [:port]),
         {:ok, verified} <- verify(output),
         port = Keyword.get(opts, :port, 55439),
         true <- is_integer(port) and port in 55433..65535 do
      root = verified.output_dir

      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "agent-systems-lab.clean-build-plan.v1",
         "working_directory" => root,
         "source_sha256" => verified.manifest["entries_sha256"],
         "scope" => "same host; source-only export; declared warm caches; new build and cluster",
         "preconditions" => [
           "private export and no concurrent writers",
           "verify source and cache provenance before executing trusted source",
           "extract cached pinned OTP/Elixir archives into this export",
           "check PostgreSQL source SHA256 and build a new prefix in this export",
           "check requested loopback port is free; never stop a pre-existing server"
         ],
         "environment" => %{
           "DATABASE_URL" => nil,
           "PGHOST" => "127.0.0.1",
           "PGHOSTADDR" => nil,
           "PGPORT" => Integer.to_string(port),
           "PGUSER" => "postgres",
           "PGPASSWORD" => "",
           "PGDATABASE" => nil,
           "PGSERVICE" => nil,
           "PGSERVICEFILE" => nil,
           "PGOPTIONS" => nil,
           "PGPASSFILE" => "/dev/null",
           "MIX_HOME" => Path.join(root, ".runtime/mix"),
           "HEX_HOME" => Path.join(root, ".runtime/hex"),
           "MIX_ARCHIVES" => Path.join(root, ".runtime/mix/archives"),
           "MIX_REBAR3" => Path.join(root, ".runtime/mix/elixir/1-20-otp-28/rebar3"),
           "REBAR_CACHE_DIR" => Path.join(root, ".runtime/rebar/cache"),
           "REBAR_GLOBAL_CONFIG_DIR" => Path.join(root, ".runtime/rebar/config"),
           "MIX_DEPS_PATH" => Path.join(root, "deps"),
           "MIX_BUILD_ROOT" => Path.join(root, "_build"),
           "MIX_BUILD_PATH" => nil,
           "MIX_EXS" => nil,
           "MIX_TARGET" => "host",
           "MIX_ENV" => "test",
           "ERL_LIBS" => nil,
           "ERL_FLAGS" => nil,
           "ERL_AFLAGS" => nil,
           "ERL_ZFLAGS" => nil,
           "ELIXIR_ERL_OPTIONS" => nil,
           "HEX_OFFLINE" => "1",
           "LAB_DATABASE_ENABLED" => "true",
           "LAB_SCHEDULER_ENABLED" => "false"
         },
         "commands" => [
           command("cluster_start", "./scripts/postgres", ["start"]),
           command("dependencies", "./scripts/mix", ["deps.get", "--only", "test"]),
           command("full_check", "./scripts/mix", ["check"]),
           command("memory_check", "./scripts/mix", ["test"], %{
             "LAB_DATABASE_ENABLED" => "false"
           }),
           command("verify", "./scripts/mix", ["lab.verify"]),
           command("p1", "./scripts/mix", ["lab.p1", "--output", "artifacts/reproduction-p1"]),
           command("history", "./scripts/mix", [
             "lab.history",
             "--output",
             "artifacts/reproduction-history"
           ]),
           command("recover", "./scripts/mix", [
             "lab.recover",
             "--output",
             "artifacts/reproduction-recovery",
             "--repetitions",
             "1"
           ]),
           command("fence", "./scripts/mix", [
             "lab.fence",
             "--output",
             "artifacts/reproduction-fence",
             "--repetitions",
             "1"
           ]),
           command("upgrade", "./scripts/mix", [
             "lab.upgrade",
             "--output",
             "artifacts/reproduction-upgrade"
           ]),
           command("cluster_stop_owned_only", "./scripts/postgres", ["stop"])
         ],
         "claims_not_made" => [
           "new machine",
           "cold network installation",
           "cache authenticity from checksums",
           "human reader acceptance",
           "production database backup or isolation"
         ]
       }}
    else
      false -> {:error, :reproduction_invalid_port}
      {:error, _} = error -> error
    end
  end

  defp command(id, executable, args, env \\ %{}),
    do: %{"id" => id, "executable" => executable, "args" => args, "environment" => env}

  defp source_manifest(entries, files) do
    %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.source-export.v1",
      "scope" => "source only; no prior build, runtime, dependency tree or experiment history",
      "includes" => Enum.sort(files ++ @directories),
      "excludes" => [".git", ".runtime", "deps", "_build", "artifacts", "cover"],
      "entries" => entries,
      "file_count" => Enum.count(entries, &(&1["type"] == "file")),
      "total_bytes" => total_bytes(entries),
      "entries_sha256" => entries_hash(entries)
    }
  end

  defp source_files(%{"includes" => includes}) do
    cond do
      includes == Enum.sort(@files ++ @directories) -> {:ok, @files}
      includes == Enum.sort(@legacy_files ++ @directories) -> {:ok, @legacy_files}
      true -> {:error, :reproduction_manifest_mismatch}
    end
  end

  defp source_files(_), do: {:error, :reproduction_manifest_mismatch}

  # Repackaging an already frozen source must retain its verified contract.
  # Unfrozen working trees always use today's contract and require all licenses.
  defp export_source_files(source) do
    case File.lstat(Path.join(source, @manifest)) do
      {:error, :enoent} ->
        {:ok, @files, nil}

      {:ok, _} ->
        with {:ok, verified} <- verify(source),
             {:ok, files} <- source_files(verified.manifest) do
          {:ok, files, verified.manifest}
        end

      _ ->
        {:error, :reproduction_manifest_invalid}
    end
  end

  defp result(root, manifest),
    do: %{output_dir: root, manifest_path: Path.join(root, @manifest), manifest: manifest}

  defp options(opts, allowed) do
    if Keyword.keyword?(opts) and length(opts) == length(Keyword.keys(opts) |> Enum.uniq()) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
       do: :ok,
       else: {:error, :reproduction_invalid_options}
  end

  defp directory(path) when is_binary(path) do
    if Path.type(path) == :absolute and String.valid?(path) and safe_characters?(path) do
      expanded = Path.expand(path)

      case no_symlink_directories(expanded) do
        :ok -> {:ok, expanded}
        error -> error
      end
    else
      {:error, :reproduction_absolute_directory_required}
    end
  end

  defp directory(_), do: {:error, :reproduction_absolute_directory_required}

  defp fresh_output(path, source, entries) when is_binary(path) do
    with true <- Path.type(path) == :absolute and safe_characters?(path),
         destination = Path.expand(path),
         {:ok, _} <- directory(Path.dirname(destination)),
         :ok <- absent(destination),
         :ok <- outside_source_directories(destination, source, entries),
         true <-
           destination != source and
             not Enum.any?(@directories, fn name ->
               prefix = Path.join(source, name)
               destination == prefix or String.starts_with?(destination, prefix <> "/")
             end) do
      {:ok, destination}
    else
      false -> {:error, :reproduction_invalid_destination}
      error -> error
    end
  end

  defp fresh_output(_, _, _), do: {:error, :reproduction_invalid_destination}

  # Paths may have case or Unicode aliases on the host volume. A lexical prefix
  # check cannot establish that the target is outside the selected source tree.
  # Compare every existing ancestor's filesystem identity before the first mkdir.
  defp outside_source_directories(destination, source, entries) do
    selected =
      entries
      |> Enum.filter(&(&1["type"] == "directory"))
      |> Enum.map(fn entry -> directory_identity!(Path.join(source, entry["path"])) end)
      |> MapSet.new()

    destination
    |> Path.dirname()
    |> ancestors()
    |> Enum.reduce_while(:ok, fn ancestor, :ok ->
      if MapSet.member?(selected, directory_identity!(ancestor)),
        do: {:halt, {:error, :reproduction_invalid_destination}},
        else: {:cont, :ok}
    end)
  end

  defp ancestors(path) do
    parent = Path.dirname(path)
    if parent == path, do: [path], else: [path | ancestors(parent)]
  end

  defp directory_identity!(path) do
    %{type: :directory, major_device: major, minor_device: minor, inode: inode} = File.stat!(path)
    {major, minor, inode}
  end

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :reproduction_output_exists}
      _ -> {:error, :reproduction_output_unavailable}
    end
  end

  defp no_symlink_directories(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("", fn part, prefix ->
      candidate = if prefix == "", do: part, else: Path.join(prefix, part)

      case File.lstat(candidate) do
        {:ok, %{type: :directory}} -> {:cont, candidate}
        _ -> {:halt, {:error, :reproduction_unsafe_directory}}
      end
    end)
    |> case do
      final when is_binary(final) -> :ok
      error -> error
    end
  end

  defp inventory(root, names, max_file) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
      case walk(root, name, max_file, entries) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1["path"])}
      error -> error
    end
  end

  defp walk(root, relative, max_file, entries) do
    with true <- length(entries) < @max_files,
         true <- safe_relative?(relative),
         path = Path.join(root, relative),
         :ok <- no_symlink_directories(Path.dirname(path)) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, entries}

        {:ok, %{type: :directory, mode: mode}} when band(mode, 0o7000) == 0 ->
          entry = %{"path" => relative, "type" => "directory", "mode" => band(mode, 0o777)}

          with {:ok, children} <- File.ls(path) do
            Enum.reduce_while(Enum.sort(children), {:ok, [entry | entries]}, fn child,
                                                                                {:ok, acc} ->
              case walk(root, Path.join(relative, child), max_file, acc) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end
            end)
          end

        {:ok, %{type: :regular, mode: mode, size: bytes, links: 1}}
        when band(mode, 0o7000) == 0 and bytes <= max_file ->
          entry = %{
            "path" => relative,
            "type" => "file",
            "mode" => band(mode, 0o777),
            "bytes" => bytes,
            "sha256" => digest_file(path, bytes)
          }

          {:ok, [entry | entries]}

        _ ->
          {:error, :reproduction_unsafe_source_entry}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :reproduction_source_limit_or_path}
    end
  end

  defp source_bounds(entries) do
    if length(entries) <= @max_files and total_bytes(entries) <= @max_source_bytes,
      do: :ok,
      else: {:error, :reproduction_source_limit}
  end

  defp required_source(entries, files) do
    licenses = if files == @files, do: @license_files ++ ["docs/licensing.md"], else: []
    required = ~w(mix.exs mix.lock .tool-versions) ++ licenses

    if Enum.all?(required, fn name ->
         Enum.any?(entries, &(&1["path"] == name and &1["type"] == "file"))
       end),
       do: :ok,
       else: {:error, :reproduction_required_source_missing}
  end

  defp copy_entries(source, destination, entries) do
    directories = Enum.filter(entries, &(&1["type"] == "directory"))
    files = Enum.filter(entries, &(&1["type"] == "file"))

    with :ok <-
           each(directories, fn entry ->
             File.mkdir_p(Path.join(destination, entry["path"]))
           end),
         :ok <-
           each(files, fn entry ->
             target = Path.join(destination, entry["path"])

             with :ok <- File.mkdir_p(Path.dirname(target)),
                  {:ok, from} <- File.open(Path.join(source, entry["path"]), [:read, :binary]) do
               try do
                 with {:ok, to} <- File.open(target, [:write, :binary, :exclusive]) do
                   try do
                     with {:ok, bytes} <- File.copy(from, to, entry["bytes"] + 1),
                          true <- bytes == entry["bytes"],
                          :ok <- File.chmod(target, entry["mode"]) do
                       :ok
                     else
                       _ -> {:error, :reproduction_copy_failed}
                     end
                   after
                     File.close(to)
                   end
                 end
               after
                 File.close(from)
               end
             end
           end) do
      directories
      |> Enum.reverse()
      |> each(fn entry -> File.chmod(Path.join(destination, entry["path"]), entry["mode"]) end)
    end
  end

  defp each(entries, fun) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case fun.(entry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bounded_file(path, max_bytes) do
    with {:ok, %{type: :regular, size: bytes, links: 1}} <- File.lstat(path),
         true <- bytes <= max_bytes,
         {:ok, contents} <- File.read(path),
         true <- byte_size(contents) == bytes do
      {:ok, contents}
    else
      _ -> {:error, :reproduction_manifest_invalid}
    end
  end

  defp private_json(path, value) do
    with :ok <- File.write(path, JSON.encode!(value) <> "\n", [:exclusive]),
         do: File.chmod(path, 0o600)
  end

  defp digest_file(path, expected_bytes) do
    {context, bytes} =
      path
      |> File.stream!(65_536)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn chunk, {context, bytes} ->
        next = bytes + byte_size(chunk)
        if next > expected_bytes, do: raise("source changed while hashing")
        {:crypto.hash_update(context, chunk), next}
      end)

    if bytes != expected_bytes, do: raise("source changed while hashing")
    context |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp entries_hash(entries) do
    entries
    |> Enum.map(fn entry ->
      [
        entry["path"],
        entry["type"],
        to_string(entry["mode"]),
        to_string(Map.get(entry, "bytes", 0)),
        Map.get(entry, "sha256", "")
      ]
      |> Enum.join(<<0>>)
    end)
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp total_bytes(entries), do: Enum.reduce(entries, 0, &(&2 + Map.get(&1, "bytes", 0)))

  defp safe_relative?(relative) do
    String.valid?(relative) and safe_characters?(relative) and Path.type(relative) == :relative and
      Enum.all?(Path.split(relative), &(&1 not in [".", "..", ""]))
  end

  defp safe_characters?(path), do: not Regex.match?(~r/[\x00-\x1f\x7f\\]/u, path)
end
