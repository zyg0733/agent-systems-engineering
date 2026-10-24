defmodule AgentSystemsLab.Approvals.Artifact do
  @moduledoc """
  Host-authored text artifact selections and immutable review snapshots.

  `files` names outputs, `baselines` names protected source versions, and the
  optional `initial` map checks output versions only before round admission.
  Capture always rechecks protected baselines and freezes bounded output bytes.
  It never writes files or treats model output as additional path authority.
  Persisted and snapshot validation perform no filesystem access.

  All existing components reject symlinks and alternate directory-entry
  spellings; regular files reject hard links. Reads are bounded and checked
  before and after. The host must keep the Workspace private while capturing:
  pathname checks cannot pin inodes against hostile concurrent ancestor renames.
  """

  alias AgentSystemsLab.Context
  alias AgentSystemsLab.Tools.Workspace

  @fields [
    :schema_version,
    :root,
    :files,
    :baselines,
    :initial,
    :max_file_bytes,
    :max_total_bytes
  ]
  @snapshot_fields [:schema_version, :root, :files, :baselines, :initial, :hash]
  @entry_fields [:path, :sha256, :bytes, :content]
  @max_files 16
  @max_total_bytes 1_048_576
  @system_roots ~w(/System /usr /bin /sbin /etc /private/etc /dev /Library /Applications)

  defstruct schema_version: 1,
            root: nil,
            files: [],
            baselines: %{},
            initial: %{},
            max_file_bytes: 65_536,
            max_total_bytes: @max_total_bytes

  def max_files, do: @max_files
  def max_total_bytes, do: @max_total_bytes

  def new(root_or_workspace, files, opts \\ []) do
    root =
      if is_struct(root_or_workspace, Workspace),
        do: root_or_workspace.root,
        else: root_or_workspace

    with :ok <- options_valid(opts),
         {:ok, normalized} <- normalize_paths(files),
         spec = %__MODULE__{
           root: root,
           files: normalized,
           baselines: Keyword.get(opts, :baselines, %{}),
           initial: Keyword.get(opts, :initial, %{}),
           max_file_bytes: Keyword.get(opts, :max_file_bytes, Workspace.max_bytes()),
           max_total_bytes: Keyword.get(opts, :max_total_bytes, @max_total_bytes)
         },
         :ok <- validate(spec),
         {:ok, _} <- workspace(spec) do
      {:ok, spec}
    end
  end

  @doc "Validates inert persisted authority without reading or creating any file."
  def validate(%__MODULE__{} = spec) do
    with :ok <- exact_keys(Map.from_struct(spec), @fields, :invalid_artifact_spec),
         true <- spec.schema_version === 1 || {:error, :unsupported_artifact_version},
         :ok <- root_valid(spec.root),
         true <-
           (is_integer(spec.max_file_bytes) and spec.max_file_bytes in 1..65_536 and
              is_integer(spec.max_total_bytes) and spec.max_total_bytes in 1..@max_total_bytes) ||
             {:error, :invalid_artifact_limits},
         {:ok, files} <- normalize_paths(spec.files),
         true <- files === spec.files || {:error, :noncanonical_artifact_files},
         :ok <- versions_valid(spec.baselines),
         :ok <- versions_valid(spec.initial),
         true <- Map.keys(spec.initial) -- files == [] || {:error, :invalid_artifact_initial},
         true <-
           disjoint_paths?(files, Map.keys(spec.baselines)) ||
             {:error, :artifact_output_baseline_overlap} do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_artifact_spec}

  def to_map(%__MODULE__{} = spec), do: Map.from_struct(spec)

  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @fields, :invalid_artifact_spec),
         spec = struct!(__MODULE__, map),
         :ok <- validate(spec) do
      {:ok, spec}
    end
  end

  def from_map(_), do: {:error, :invalid_artifact_spec}
  def hash(%__MODULE__{} = spec), do: Context.hash(to_map(spec))

  @doc "Checks protected sources and optional original output versions before admission."
  def check_baselines(%__MODULE__{} = spec) do
    with :ok <- validate(spec),
         {:ok, workspace} <- workspace(spec),
         :ok <- check_versions(workspace, spec.baselines),
         :ok <- check_versions(workspace, spec.initial) do
      :ok
    end
  end

  def check_baselines(_), do: {:error, :invalid_artifact_spec}

  @doc "Rechecks protected sources and freezes immutable UTF-8 output bytes."
  def capture(%__MODULE__{} = spec) do
    with :ok <- validate(spec),
         {:ok, workspace} <- workspace(spec),
         :ok <- check_versions(workspace, spec.baselines),
         {:ok, entries} <- capture_files(spec, workspace),
         :ok <- check_versions(workspace, spec.baselines) do
      snapshot = %{
        schema_version: 1,
        root: spec.root,
        files: entries,
        baselines: spec.baselines,
        initial: spec.initial
      }

      {:ok, Map.put(snapshot, :hash, Context.hash(snapshot))}
    end
  end

  def capture(_), do: {:error, :invalid_artifact_spec}

  @doc "Checks immutable bytes, version metadata and hashes without live file access."
  def validate_snapshot(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_fields, :invalid_artifact_snapshot),
         true <- snapshot.schema_version === 1 || {:error, :unsupported_artifact_version},
         :ok <- root_valid(snapshot.root),
         true <- digest?(snapshot.hash) || {:error, :invalid_artifact_hash},
         true <-
           (is_list(snapshot.files) and length(snapshot.files) in 1..@max_files) ||
             {:error, :invalid_artifact_snapshot},
         :ok <- snapshot_entries_valid(snapshot.files),
         :ok <- versions_valid(snapshot.baselines),
         :ok <- versions_valid(snapshot.initial),
         paths = Enum.map(snapshot.files, & &1.path),
         true <- Map.keys(snapshot.initial) -- paths == [] || {:error, :invalid_artifact_initial},
         true <-
           disjoint_paths?(paths, Map.keys(snapshot.baselines)) ||
             {:error, :artifact_output_baseline_overlap},
         true <-
           snapshot.hash == Context.hash(Map.delete(snapshot, :hash)) ||
             {:error, :artifact_snapshot_hash_mismatch} do
      :ok
    end
  end

  def validate_snapshot(_), do: {:error, :invalid_artifact_snapshot}

  @doc "Requires exact host selection, unchanged protected sources and unchanged output bytes."
  def current?(%__MODULE__{} = spec, snapshot) do
    with :ok <- matches_spec(spec, snapshot),
         {:ok, current} <- capture(spec),
         true <-
           current.hash == snapshot.hash ||
             {:error, {:artifact_changed, snapshot.hash, current.hash}} do
      :ok
    end
  end

  def current?(_, _), do: {:error, :invalid_artifact_spec}

  @doc "Checks a snapshot's exact host selection without any filesystem access."
  def matches_spec(%__MODULE__{} = spec, snapshot) do
    with :ok <- validate(spec),
         :ok <- validate_snapshot(snapshot),
         true <-
           (snapshot.root === spec.root and Enum.map(snapshot.files, & &1.path) === spec.files and
              snapshot.baselines === spec.baselines and snapshot.initial === spec.initial and
              Enum.all?(snapshot.files, &(&1.bytes <= spec.max_file_bytes)) and
              Enum.sum(Enum.map(snapshot.files, & &1.bytes)) <= spec.max_total_bytes) ||
             {:error, :artifact_spec_mismatch} do
      :ok
    end
  end

  def matches_spec(_, _), do: {:error, :invalid_artifact_spec}

  defp check_versions(workspace, versions) do
    versions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {path, expected}, :ok ->
      case observed(workspace, path, true) do
        {:ok, value} ->
          actual = if value == :absent, do: "absent", else: Workspace.sha256(value)

          if actual == expected do
            {:cont, :ok}
          else
            {:halt, {:error, {:artifact_baseline_conflict, path, expected, actual}}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp capture_files(spec, workspace) do
    Enum.reduce_while(spec.files, {:ok, [], 0}, fn path, {:ok, entries, total} ->
      case observed(workspace, path, false) do
        {:ok, content} ->
          next_total = total + byte_size(content)

          if next_total <= spec.max_total_bytes do
            entry = %{
              path: path,
              sha256: Workspace.sha256(content),
              bytes: byte_size(content),
              content: content
            }

            {:cont, {:ok, [entry | entries], next_total}}
          else
            {:halt, {:error, :artifact_total_bytes_exceeded}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp observed(workspace, path, allow_absent) do
    with {:ok, full} <- Workspace.resolve(workspace, path, allow_absent),
         :ok <- canonical_path(full, allow_absent) do
      case File.lstat(full, time: :posix) do
        {:error, :enoent} when allow_absent ->
          {:ok, :absent}

        {:ok, %{type: :regular, links: 1} = before} ->
          with {:ok, content} <- Workspace.read(workspace, path),
               {:ok, ^full} <- Workspace.resolve(workspace, path),
               :ok <- canonical_path(full, false),
               {:ok, after_stat} <- File.lstat(full, time: :posix),
               true <-
                 identity(before) === identity(after_stat) ||
                   {:error, {:artifact_changed_during_capture, path}},
               true <-
                 before.size == byte_size(content) ||
                   {:error, {:artifact_changed_during_capture, path}} do
            {:ok, content}
          end

        {:error, :enoent} ->
          {:error, {:artifact_missing, path}}

        {:error, reason} ->
          {:error, {:filesystem, reason}}

        _ ->
          {:error, {:artifact_changed_during_capture, path}}
      end
    else
      {:error, {:filesystem, :enoent}} when not allow_absent ->
        {:error, {:artifact_missing, path}}

      error ->
        error
    end
  end

  defp identity(stat),
    do:
      Map.take(stat, [:type, :links, :inode, :major_device, :minor_device, :size, :mtime, :ctime])

  defp workspace(spec) do
    with {:ok, workspace} <- Workspace.new(spec.root, max_file_bytes: spec.max_file_bytes),
         :ok <- canonical_path(spec.root, false) do
      {:ok, workspace}
    end
  end

  defp canonical_path(path, allow_absent) do
    parts = Path.split(path)

    parts
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {part, index}, parent ->
      full = if parent, do: Path.join(parent, part), else: part

      if parent == nil do
        {:cont, full}
      else
        case File.ls(parent) do
          {:ok, entries} ->
            cond do
              part in entries -> {:cont, full}
              File.exists?(full) -> {:halt, {:error, :non_canonical_path}}
              allow_absent and index == length(parts) - 1 -> {:cont, full}
              true -> {:halt, {:error, {:filesystem, :enoent}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:filesystem, reason}}}
        end
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp normalize_paths(paths) when is_list(paths) and length(paths) in 1..@max_files do
    with :ok <-
           Enum.reduce_while(paths, :ok, fn path, :ok ->
             case Workspace.path_valid(path) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         folded = Enum.map(paths, &fold/1),
         true <- length(Enum.uniq(folded)) == length(folded) || {:error, :duplicate_artifact_path} do
      {:ok, Enum.sort(paths)}
    end
  end

  defp normalize_paths(_), do: {:error, :invalid_artifact_files}

  defp versions_valid(versions)
       when is_map(versions) and not is_struct(versions) and map_size(versions) <= @max_files do
    Enum.reduce_while(versions, :ok, fn {path, expected}, :ok ->
      with :ok <- Workspace.path_valid(path), :ok <- Workspace.expected_valid(expected) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok ->
        folded = Enum.map(Map.keys(versions), &fold/1)

        if length(folded) == length(Enum.uniq(folded)),
          do: :ok,
          else: {:error, :duplicate_artifact_path}

      error ->
        error
    end
  end

  defp versions_valid(_), do: {:error, :invalid_artifact_baselines}

  defp snapshot_entries_valid(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with true <-
             (is_map(entry) and not is_struct(entry)) || {:error, :invalid_artifact_snapshot},
           :ok <- exact_keys(entry, @entry_fields, :invalid_artifact_snapshot),
           :ok <- Workspace.path_valid(entry.path),
           :ok <- Workspace.text_valid(entry.content),
           true <-
             (is_integer(entry.bytes) and entry.bytes === byte_size(entry.content)) ||
               {:error, :artifact_snapshot_bytes_mismatch},
           true <-
             (digest?(entry.sha256) and entry.sha256 == Workspace.sha256(entry.content)) ||
               {:error, :artifact_snapshot_content_mismatch} do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok ->
        paths = Enum.map(entries, & &1.path)

        with {:ok, ^paths} <- normalize_paths(paths),
             true <-
               Enum.sum(Enum.map(entries, & &1.bytes)) <= @max_total_bytes ||
                 {:error, :artifact_total_bytes_exceeded} do
          :ok
        else
          {:ok, _} -> {:error, :noncanonical_artifact_files}
          error -> error
        end

      error ->
        error
    end
  end

  defp root_valid(root) when is_binary(root) do
    broad = ["/", "/Users", "/private", "/tmp", "/private/tmp", System.user_home!()]

    cond do
      not String.valid?(root) or byte_size(root) > 4096 or Path.type(root) != :absolute or
          Path.expand(root) !== root ->
        {:error, :invalid_artifact_root}

      Regex.match?(~r/[\x00-\x1f\x7f\\]/, root) ->
        {:error, :invalid_artifact_root}

      Enum.any?(Path.split(root), &(Workspace.path_valid(&1) == {:error, :protected_path})) ->
        {:error, :protected_path}

      Enum.any?(broad, &(fold(root) == fold(&1))) or
          Enum.any?(@system_roots, &ancestor?(fold(&1), fold(root))) ->
        {:error, :invalid_artifact_root}

      true ->
        :ok
    end
  end

  defp root_valid(_), do: {:error, :invalid_artifact_root}

  defp fold(value),
    do: value |> String.normalize(:nfc) |> :string.casefold() |> String.normalize(:nfc)

  defp ancestor?(root, path), do: root == path or String.starts_with?(path, root <> "/")

  defp disjoint_paths?(first, second),
    do: MapSet.disjoint?(MapSet.new(first, &fold/1), MapSet.new(second, &fold/1))

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp options_valid(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:baselines, :initial, :max_file_bytes, :max_total_bytes] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
       do: :ok,
       else: {:error, :invalid_artifact_options}
  end

  defp exact_keys(map, fields, reason) do
    if Enum.sort(Map.keys(map)) === Enum.sort(fields), do: :ok, else: {:error, reason}
  end
end
