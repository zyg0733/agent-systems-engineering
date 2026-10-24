defmodule AgentSystemsLab.Tools.Workspace do
  @moduledoc """
  A bounded text workspace for the teaching file tools.

  Every access rejects symbolic links and protected metadata components. Writes
  use an exclusive temporary file in the destination directory and recheck the
  base before rename. The workspace must be private to one lab process: these
  pathname checks are not a sandbox against hostile concurrent renames.
  """

  @max_bytes 65_536
  @blocked ~w(.git .runtime .agents .codex .aws .ssh _build deps)
  defstruct [:root, max_file_bytes: @max_bytes]

  @type t :: %__MODULE__{root: String.t(), max_file_bytes: pos_integer()}

  def new(root, opts \\ []) do
    with :ok <- options_valid(opts),
         :ok <- root_valid(root),
         expanded = Path.expand(root),
         :ok <- directories_valid(expanded) do
      {:ok,
       %__MODULE__{root: expanded, max_file_bytes: Keyword.get(opts, :max_file_bytes, @max_bytes)}}
    end
  end

  def max_bytes, do: @max_bytes
  def blocked_components, do: @blocked

  @doc "Checks a relative path and every existing filesystem component."
  def resolve(%__MODULE__{} = workspace, path, allow_absent \\ false) do
    with :ok <- path_valid(path),
         :ok <- directories_valid(workspace.root),
         full = Path.join(workspace.root, path),
         :ok <- directories_valid(Path.dirname(full)),
         :ok <- regular_file(full, allow_absent) do
      {:ok, full}
    end
  end

  @doc "Reads at most the configured limit plus one byte, then validates UTF-8 text."
  def read(%__MODULE__{} = workspace, path) do
    with {:ok, full} <- resolve(workspace, path),
         {:ok, contents} <- bounded_read(full, workspace.max_file_bytes),
         :ok <- text_valid(contents, workspace.max_file_bytes) do
      {:ok, contents}
    end
  end

  def sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  def text_valid(contents, max_bytes \\ @max_bytes) do
    cond do
      not is_binary(contents) -> {:error, :invalid_text}
      byte_size(contents) > max_bytes -> {:error, :file_too_large}
      not String.valid?(contents) -> {:error, :invalid_utf8}
      :binary.match(contents, <<0>>) != :nomatch -> {:error, :nul_in_text}
      true -> :ok
    end
  end

  @doc "Reads the expected version, including an explicitly absent creation target."
  def base(workspace, path, expected) do
    with :ok <- expected_valid(expected),
         {:ok, full} <- resolve(workspace, path, expected == "absent") do
      case File.lstat(full) do
        {:error, :enoent} when expected == "absent" ->
          {:ok, nil, nil}

        {:ok, _} when expected == "absent" ->
          {:error, :base_mismatch}

        {:ok, stat} ->
          with {:ok, contents} <- read(workspace, path),
               true <- sha256(contents) == expected do
            {:ok, contents, stat.mode}
          else
            false -> {:error, :base_mismatch}
            error -> error
          end

        {:error, reason} ->
          {:error, {:filesystem, reason}}
      end
    end
  end

  @doc "Atomically replaces a text file after checking its SHA-256 base twice."
  def write(workspace, path, contents, expected) do
    with :ok <- text_valid(contents, workspace.max_file_bytes),
         {:ok, previous, mode} <- base(workspace, path, expected),
         {:ok, full} <- resolve(workspace, path, expected == "absent") do
      temporary = Path.join(Path.dirname(full), ".agent-lab-tmp-#{unique_suffix()}")

      with_temporary(temporary, contents, mode, fn ->
        with {:ok, ^previous, _} <- base(workspace, path, expected),
             {:ok, ^full} <- resolve(workspace, path, expected == "absent"),
             :ok <- rename(temporary, full) do
          {:ok, previous}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :base_mismatch}
        end
      end)
    end
  end

  def expected_valid("absent"), do: :ok

  def expected_valid(expected) when is_binary(expected) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, expected),
      do: :ok,
      else: {:error, :invalid_expected_sha256}
  end

  def expected_valid(_), do: {:error, :invalid_expected_sha256}

  def path_valid(path) when is_binary(path) do
    components = String.split(path, "/")

    cond do
      not String.valid?(path) ->
        {:error, :invalid_path}

      path == "" or byte_size(path) > 1024 ->
        {:error, :invalid_path}

      control_characters?(path) ->
        {:error, :invalid_path}

      Path.type(path) != :relative ->
        {:error, :invalid_path}

      String.contains?(path, "\\") ->
        {:error, :invalid_path}

      Enum.any?(components, &(&1 in ["", ".", ".."])) ->
        {:error, :invalid_path}

      Enum.any?(components, &protected_component?/1) ->
        {:error, :protected_path}

      true ->
        :ok
    end
  end

  def path_valid(_), do: {:error, :invalid_path}

  defp options_valid(opts) do
    cond do
      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, :invalid_workspace_options}

      Keyword.keys(opts) -- [:max_file_bytes] != [] ->
        {:error, :invalid_workspace_options}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_workspace_options}

      not (is_integer(Keyword.get(opts, :max_file_bytes, @max_bytes)) and
               Keyword.get(opts, :max_file_bytes, @max_bytes) in 1..@max_bytes) ->
        {:error, :invalid_workspace_options}

      true ->
        :ok
    end
  end

  defp root_valid(root) when is_binary(root) do
    cond do
      not String.valid?(root) ->
        {:error, :invalid_workspace_root}

      Path.type(root) != :absolute ->
        {:error, :invalid_workspace_root}

      control_characters?(root) or String.contains?(root, "\\") ->
        {:error, :invalid_workspace_root}

      Enum.any?(String.split(root, "/"), &(&1 in [".", ".."])) ->
        {:error, :invalid_workspace_root}

      Enum.any?(String.split(root, "/"), &protected_component?/1) ->
        {:error, :protected_path}

      true ->
        :ok
    end
  end

  defp root_valid(_), do: {:error, :invalid_workspace_root}

  # A case-insensitive filesystem may equate both ASCII capitals and Unicode
  # folds such as long s with a protected name. Apply the stricter policy on all
  # platforms, including case-sensitive filesystems.
  defp protected_component?(component) do
    folded = :string.casefold(component)
    folded in @blocked or String.starts_with?(folded, ".agent-lab-tmp-")
  end

  defp control_characters?(path), do: Regex.match?(~r/[\x00-\x1f\x7f]/, path)

  defp directories_valid(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn component, parent ->
      next = if parent, do: Path.join(parent, component), else: component

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> {:cont, next}
        {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_not_allowed}}
        {:ok, _} -> {:halt, {:error, :not_a_directory}}
        {:error, reason} -> {:halt, {:error, {:filesystem, reason}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp regular_file(path, allow_absent) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1}} -> :ok
      {:ok, %{type: :regular}} -> {:error, :hardlink_not_allowed}
      {:ok, %{type: :symlink}} -> {:error, :symlink_not_allowed}
      {:ok, _} -> {:error, :not_a_regular_file}
      {:error, :enoent} when allow_absent -> :ok
      {:error, reason} -> {:error, {:filesystem, reason}}
    end
  end

  defp bounded_read(full, limit) do
    case :file.open(String.to_charlist(full), [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          case :file.read(device, limit + 1) do
            {:ok, contents} when byte_size(contents) <= limit -> {:ok, contents}
            {:ok, _} -> {:error, :file_too_large}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, {:filesystem, reason}}
          end
        after
          :file.close(device)
        end

      {:error, reason} ->
        {:error, {:filesystem, reason}}
    end
  end

  defp with_temporary(path, contents, previous_mode, commit) do
    mode = if previous_mode, do: Bitwise.band(previous_mode, 0o777), else: 0o644

    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        try do
          with :ok <- File.chmod(path, mode),
               :ok <- :file.write(device, contents),
               :ok <- :file.sync(device) do
            commit.()
          else
            {:error, reason} -> {:error, {:filesystem, reason}}
          end
        after
          :file.close(device)
          File.rm(path)
        end

      {:error, reason} ->
        {:error, {:filesystem, reason}}
    end
  end

  defp unique_suffix, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp rename(source, target) do
    case File.rename(source, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem, reason}}
    end
  end
end
