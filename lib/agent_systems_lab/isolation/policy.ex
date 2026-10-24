defmodule AgentSystemsLab.Isolation.Policy do
  @moduledoc """
  Host-owned authority for the laboratory's macOS isolated executor.

  The first backend permits one process, denies all networking, and grants file
  data access only to the workspace, the named executables, and the system
  libraries required to load them. A model supplies a command and argv; it never
  supplies this policy or a sandbox profile. There is no implicit shell.

  Paths are checked again at dispatch. The workspace and its ancestors must be
  real directories, and command files must be regular executable files without
  symbolic or hard links. The host must retain ownership of the workspace root
  and command files while an execution is starting; pathname validation is not
  an inode-pinning mechanism against a hostile host process.
  """

  import Bitwise

  alias AgentSystemsLab.Tools.Workspace

  @defaults %{
    wall_time_ms: 5000,
    cpu_seconds: 2,
    max_output_bytes: 65_536,
    max_file_bytes: 1_048_576,
    max_processes: 1
  }
  @limit_keys Map.keys(@defaults)
  @policy_keys [:schema_version, :workspace, :commands, :network, :limits]
  @option_keys [:workspace, :commands, :network, :limits]
  @system_roots ~w(/System /usr /bin /sbin /etc /private/etc /dev /Library /Applications)
  @workspace_entry_limit 10_000

  @enforce_keys [:workspace, :commands, :network, :limits]
  defstruct [:workspace, :commands, :network, :limits, schema_version: 1]

  @type t :: %__MODULE__{
          schema_version: 1,
          workspace: String.t(),
          commands: [String.t()],
          network: :deny,
          limits: %{
            wall_time_ms: pos_integer(),
            cpu_seconds: pos_integer(),
            max_output_bytes: pos_integer(),
            max_file_bytes: pos_integer(),
            max_processes: 1
          }
        }

  @doc "Constructs a closed policy from trusted host options."
  def new(opts) do
    with :ok <- keyword_options(opts, @option_keys, :invalid_isolation_options),
         {:ok, limits} <- limits(Keyword.get(opts, :limits, [])),
         policy = %__MODULE__{
           workspace: Keyword.get(opts, :workspace),
           commands: Keyword.get(opts, :commands),
           network: Keyword.get(opts, :network, :deny),
           limits: limits
         },
         :ok <- validate(policy) do
      {:ok, policy}
    end
  end

  @doc "Revalidates persisted authority and its current filesystem prerequisites."
  def validate(%__MODULE__{} = policy) do
    with :ok <- exact_keys(Map.from_struct(policy), @policy_keys),
         :ok <- version(policy.schema_version),
         :ok <- network(policy.network),
         :ok <- limits_valid(policy.limits),
         :ok <- workspace_valid(policy.workspace),
         :ok <- commands_valid(policy.commands),
         :ok <- commands_outside_workspace(policy.workspace, policy.commands) do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_isolation_policy}

  @doc """
  Inspects at most 10,000 workspace entries before one isolated launch.

  Existing regular hard links can alias data outside a path-based sandbox, so
  they are refused. Symbolic links are not followed: the OS profile checks their
  eventual target when the child accesses them. This scan is deliberately not
  part of ordinary persisted-policy validation or recovery history loading.
  The host must prevent concurrent workspace mutation while preparing a launch.
  """
  def preflight(policy) do
    with :ok <- validate(policy),
         :ok <- inspect_directories([policy.workspace], policy.workspace, 0) do
      :ok
    end
  end

  @doc "A plain inert map suitable for the existing versioned storage codec."
  def to_map(%__MODULE__{} = policy), do: Map.from_struct(policy)

  @doc "Loads exactly the persisted v1 shape; missing or additional keys fail closed."
  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @policy_keys),
         policy = struct!(__MODULE__, map),
         :ok <- validate(policy) do
      {:ok, policy}
    end
  end

  def from_map(_), do: {:error, :invalid_isolation_policy}

  @doc "Checks the model's command against the host allowlist without executing it."
  def command(policy, executable, args) do
    with :ok <- validate(policy),
         true <- executable in policy.commands || {:error, :command_not_allowed},
         :ok <- arguments_valid(args) do
      :ok
    end
  end

  @doc "Builds a deny-by-default profile with only Apple's narrow dyld bootstrap import."
  def profile(policy, private_tmp) do
    with :ok <- validate(policy),
         :ok <- private_tmp_valid(policy.workspace, private_tmp) do
      read_paths =
        [
          "(subpath #{quote_path(policy.workspace)})",
          "(subpath \"/System/Library\")",
          "(subpath \"/usr/lib\")",
          "(literal \"/dev/null\")",
          "(literal \"/dev/random\")",
          "(literal \"/dev/urandom\")"
        ] ++ Enum.map(policy.commands, &"(literal #{quote_path(&1)})")

      commands = Enum.map_join(policy.commands, "\n  ", &"(literal #{quote_path(&1)})")

      {:ok,
       """
       (version 1)
       (deny default)
       (import "/System/Library/Sandbox/Profiles/dyld-support.sb")
       (deny network*)
       (deny process-fork)
       (deny file-link)
       (allow process-exec
         #{commands})
       (allow file-read*
         #{Enum.join(read_paths, "\n  ")})
       (allow file-map-executable
         (subpath "/System/Library")
         (subpath "/usr/lib")
         #{commands})
       (allow file-write*
         (subpath #{quote_path(policy.workspace)})
         (literal "/dev/null"))
       """}
    end
  end

  defp keyword_options(opts, allowed, reason) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.keys(opts) -- allowed == [],
       do: :ok,
       else: {:error, reason}
  end

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_isolation_policy}
  end

  defp version(1), do: :ok
  defp version(other), do: {:error, {:unsupported_isolation_policy_version, other}}

  defp network(:deny), do: :ok
  defp network(_), do: {:error, :unsupported_network_policy}

  defp limits(opts) do
    with :ok <- keyword_options(opts, @limit_keys, :invalid_isolation_limits),
         limits = Map.merge(@defaults, Map.new(opts)),
         :ok <- limits_valid(limits) do
      {:ok, limits}
    end
  end

  defp limits_valid(limits) when is_map(limits) and not is_struct(limits) do
    if Enum.sort(Map.keys(limits)) == Enum.sort(@limit_keys) and
         integer_in?(limits.wall_time_ms, 1..60_000) and
         integer_in?(limits.cpu_seconds, 1..60) and
         integer_in?(limits.max_output_bytes, 1..1_048_576) and
         integer_in?(limits.max_file_bytes, 1..16_777_216) and limits.max_processes === 1,
       do: :ok,
       else: {:error, :invalid_isolation_limits}
  end

  defp limits_valid(_), do: {:error, :invalid_isolation_limits}

  defp integer_in?(value, range), do: is_integer(value) and value in range

  defp workspace_valid(root) do
    with :ok <- path_valid(root, :invalid_isolation_workspace),
         true <- not broad_workspace?(root) || {:error, :invalid_isolation_workspace},
         {:ok, _workspace} <- Workspace.new(root),
         :ok <- real_directory(root) do
      :ok
    end
  end

  defp broad_workspace?(root) do
    folded = fold(root)

    Enum.any?(
      ["/", "/Users", "/private", "/tmp", "/private/tmp", System.user_home!()],
      &(folded == fold(&1))
    ) or
      Enum.any?(@system_roots, fn system ->
        system = fold(system)
        folded == system or String.starts_with?(folded, system <> "/")
      end)
  end

  defp commands_valid(commands) do
    if commands != [] and bounded_list?(commands, 32) and
         length(commands) == length(Enum.uniq(commands)) do
      Enum.reduce_while(commands, :ok, fn command, :ok ->
        case executable_valid(command) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_isolation_commands}
    end
  end

  defp commands_outside_workspace(workspace, commands) do
    if Enum.any?(commands, &String.starts_with?(&1, workspace <> "/")),
      do: {:error, :mutable_isolation_command},
      else: :ok
  end

  defp inspect_directories([], _root, _count), do: :ok

  defp inspect_directories([directory | remaining], root, count) do
    with {:ok, entries} <- directory_entries(directory),
         true <-
           length(entries) <= @workspace_entry_limit - count ||
             {:error, :workspace_entry_limit},
         {:ok, directories, count} <- inspect_entries(entries, directory, root, count) do
      inspect_directories(directories ++ remaining, root, count)
    end
  end

  defp inspect_entries(entries, directory, root, count) do
    Enum.reduce_while(entries, {:ok, [], count}, fn entry, {:ok, directories, count} ->
      with {:ok, name} <- entry_name(entry),
           path = Path.join(directory, name),
           {:ok, stat} <- entry_stat(path) do
        case stat do
          %{type: :regular, links: links} when links > 1 ->
            {:halt, {:error, {:workspace_hardlink, Path.relative_to(path, root)}}}

          %{type: :directory} ->
            {:cont, {:ok, [path | directories], count + 1}}

          _ ->
            {:cont, {:ok, directories, count + 1}}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  # list_dir_all retains undecodable raw names, unlike Unicode-only directory
  # listing APIs which can omit them. A raw-name alias must fail closed too.
  defp directory_entries(directory) do
    case :file.list_dir_all(directory) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:filesystem, reason}}
    end
  end

  defp entry_name(name) do
    case :unicode.characters_to_binary(name) do
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, :invalid_workspace_entry}
    end
  end

  defp entry_stat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:filesystem, reason}}
    end
  end

  defp executable_valid(command) do
    with :ok <- path_valid(command, :invalid_isolation_command),
         :ok <- real_directory(Path.dirname(command)),
         {:ok, stat} <- File.lstat(command),
         :ok <- canonical_component(Path.dirname(command), Path.basename(command)) do
      cond do
        stat.type == :symlink -> {:error, :symlink_not_allowed}
        stat.type != :regular -> {:error, :not_an_executable_file}
        stat.links != 1 -> {:error, :hardlink_not_allowed}
        band(stat.mode, 0o111) == 0 -> {:error, :not_an_executable_file}
        band(stat.mode, 0o6000) != 0 -> {:error, :privileged_command_not_allowed}
        true -> :ok
      end
    else
      {:error, reason} when reason in [:enoent, :eacces, :enotdir] ->
        {:error, {:filesystem, reason}}

      error ->
        error
    end
  end

  defp path_valid(path, reason) when is_binary(path) do
    if String.valid?(path) and byte_size(path) in 1..4096 and Path.type(path) == :absolute and
         path == Path.expand(path) and not String.contains?(path, "\\") and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, path),
       do: :ok,
       else: {:error, reason}
  end

  defp path_valid(_, reason), do: {:error, reason}

  defp real_directory(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn part, parent ->
      next = if parent, do: Path.join(parent, part), else: part

      case File.lstat(next) do
        {:ok, %{type: :directory}} ->
          case canonical_component(parent, part) do
            :ok -> {:cont, next}
            error -> {:halt, error}
          end

        {:ok, %{type: :symlink}} ->
          {:halt, {:error, :symlink_not_allowed}}

        {:ok, _} ->
          {:halt, {:error, :not_a_directory}}

        {:error, reason} ->
          {:halt, {:error, {:filesystem, reason}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  # lstat alone accepts alternate case/Unicode spellings on common macOS
  # filesystems. Require the directory entry's exact name as well as rejecting
  # symlinks; otherwise a home-directory alias could bypass a narrow-root check.
  defp canonical_component(nil, "/"), do: :ok

  defp canonical_component(parent, component) do
    case File.ls(parent) do
      {:ok, entries} ->
        if component in entries, do: :ok, else: {:error, :non_canonical_path}

      {:error, reason} ->
        {:error, {:filesystem, reason}}
    end
  end

  defp fold(path), do: path |> String.normalize(:nfd) |> :string.casefold()

  defp arguments_valid(args) when is_list(args) do
    if bounded_list?(args, 128) and
         Enum.all?(args, fn arg ->
           is_binary(arg) and String.valid?(arg) and byte_size(arg) <= 4096 and
             :binary.match(arg, <<0>>) == :nomatch
         end) and Enum.sum(Enum.map(args, &byte_size/1)) <= 16_384,
       do: :ok,
       else: {:error, :invalid_isolation_arguments}
  end

  defp arguments_valid(_), do: {:error, :invalid_isolation_arguments}

  defp private_tmp_valid(workspace, private_tmp) do
    with :ok <- path_valid(private_tmp, :invalid_isolation_tmp),
         true <-
           String.starts_with?(private_tmp, workspace <> "/") ||
             {:error, :invalid_isolation_tmp},
         :ok <- real_directory(private_tmp),
         {:ok, stat} <- File.lstat(private_tmp),
         true <- band(stat.mode, 0o077) == 0 || {:error, :insecure_isolation_tmp} do
      :ok
    end
  end

  defp bounded_list?([], _remaining), do: true

  defp bounded_list?([_head | tail], remaining) when remaining > 0,
    do: bounded_list?(tail, remaining - 1)

  defp bounded_list?(_value, _remaining), do: false

  defp quote_path(path), do: "\"" <> String.replace(path, "\"", "\\\"") <> "\""
end
