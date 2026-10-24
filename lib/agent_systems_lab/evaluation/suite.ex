defmodule AgentSystemsLab.Evaluation.Suite do
  @moduledoc """
  Loads the small, public teaching evaluation corpus. Every source byte, oracle
  and fixed scorer implementation contributes to its identity. Holdout is an
  explicit split, not a claim that these public fixtures are secret.
  """
  alias AgentSystemsLab.Evaluation.Scorer

  @root Path.expand("../../../fixtures/evaluation", __DIR__)
  @source __ENV__.file
  @external_resource @source
  @source_hash :crypto.hash(:sha256, File.read!(@source)) |> Base.encode16(case: :lower)
  @root_keys ~w(schema_version suite_id version pricing tasks)
  @task_keys ~w(id split artifact_path oracle regressed_mode instruction_file input_file expected_file reference_file regressed_file)
  @pricing %{
    "model_attempt_units" => 1000,
    "output_byte_units" => 1,
    "tool_attempt_units" => 250,
    "currency" => nil
  }
  @file_fields ~w(instruction_file input_file expected_file reference_file regressed_file)

  def load(opts \\ []) do
    with true <- valid_opts?(opts),
         root = Keyword.get(opts, :root, @root),
         true <- is_binary(root) and Path.type(root) == :absolute,
         {:ok, raw} <- read_bounded(Path.join(root, "manifest.json"), 65_536),
         {:ok, manifest} <- decode_manifest(raw),
         :ok <- validate_manifest(manifest),
         {:ok, tasks, files} <- load_tasks(root, manifest["tasks"]) do
      scorer_hash = Scorer.source_hash()
      manifest_hash = hash(raw)
      pricing_hash = digest(manifest["pricing"])

      suite_hash =
        digest(%{
          "manifest_hash" => manifest_hash,
          "files" => files,
          "suite_source_hash" => @source_hash,
          "scorer_hash" => scorer_hash
        })

      {:ok,
       %{
         "schema_version" => 1,
         "id" => manifest["suite_id"],
         "version" => 1,
         "hash" => suite_hash,
         "suite_hash" => suite_hash,
         "scorer_hash" => scorer_hash,
         "pricing_hash" => pricing_hash,
         "manifest_hash" => manifest_hash,
         "source_hash" => @source_hash,
         "pricing" => manifest["pricing"],
         "manifest" => manifest,
         "task_hashes" => Map.new(tasks, &{&1["id"], &1["hash"]}),
         "fixture_hashes" => files,
         "tasks" => tasks
       }}
    else
      {:error, reason} -> {:error, {:invalid_evaluation_suite, reason}}
      _ -> {:error, :invalid_evaluation_suite}
    end
  rescue
    _ -> {:error, :invalid_evaluation_suite}
  end

  def tasks(%{"tasks" => tasks}, split) when split in ["dev", "holdout"],
    do: Enum.filter(tasks, &(&1["split"] == split))

  def tasks(_, _), do: []
  def default_root, do: @root
  def source_hash, do: @source_hash
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def digest(term), do: term |> canonical() |> IO.iodata_to_binary() |> hash()

  defp canonical(map) when is_map(map),
    do: [
      "{",
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: JSON.encode!(value)

  defp decode_manifest(raw) do
    case JSON.decode(raw, nil,
           object_finish: fn pairs, old ->
             keys = Enum.map(pairs, &elem(&1, 0))

             if length(keys) != length(Enum.uniq(keys)),
               do: raise(ArgumentError, "duplicate JSON key")

             {Map.new(pairs), old}
           end
         ) do
      {map, nil, rest} when is_map(map) ->
        if String.trim(rest) == "", do: {:ok, map}, else: {:error, :trailing_json}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp valid_opts?(opts),
    do:
      Keyword.keyword?(opts) and length(opts) <= 1 and
        Enum.all?(opts, fn {key, _} -> key == :root end)

  defp validate_manifest(manifest) when is_map(manifest) do
    rows = manifest["tasks"]

    with true <- Enum.sort(Map.keys(manifest)) == Enum.sort(@root_keys),
         true <- manifest["schema_version"] == 1 and manifest["version"] == 1,
         true <- manifest["suite_id"] == "agent-systems-lab-fixed-v1",
         true <- manifest["pricing"] == @pricing,
         true <- is_list(rows) and length(rows) == 10,
         true <- Enum.all?(rows, &valid_task?/1),
         ids = Enum.map(rows, & &1["id"]),
         true <- length(Enum.uniq(ids)) == length(ids),
         true <- Enum.count(rows, &(&1["split"] == "dev")) == 6,
         true <- Enum.count(rows, &(&1["split"] == "holdout")) == 4 do
      :ok
    else
      _ -> {:error, :manifest_schema}
    end
  end

  defp valid_task?(row) when is_map(row) do
    Enum.sort(Map.keys(row)) == Enum.sort(@task_keys) and
      is_binary(row["id"]) and Regex.match?(~r/^(dev|holdout)-[a-z0-9-]{1,60}$/, row["id"]) and
      row["split"] in ["dev", "holdout"] and String.starts_with?(row["id"], row["split"] <> "-") and
      row["artifact_path"] == "artifact.txt" and row["oracle"] == "exact_bytes_v1" and
      row["regressed_mode"] in ["artifact", "budget_exhaustion"] and
      Enum.all?(@file_fields, fn key ->
        path = row[key]

        is_binary(path) and Regex.match?(~r{^tasks/[a-z0-9-]+/[a-z]+\.txt$}, path) and
          Path.dirname(path) == "tasks/" <> row["id"]
      end)
  end

  defp valid_task?(_), do: false

  defp load_tasks(root, rows) do
    Enum.reduce_while(rows, {:ok, [], %{}}, fn row, {:ok, tasks, files} ->
      case load_task(root, row) do
        {:ok, task, hashes} -> {:cont, {:ok, tasks ++ [task], Map.merge(files, hashes)}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_task(root, row) do
    with {:ok, content, hashes} <- load_files(root, row),
         true <-
           String.valid?(content["instruction_file"]) and String.valid?(content["input_file"]),
         true <- byte_size(content["instruction_file"]) > 0,
         true <- content["reference_file"] == content["expected_file"] do
      task_hash =
        digest(%{"definition" => row, "files" => hashes, "scorer_hash" => Scorer.source_hash()})

      {:ok,
       %{
         "id" => row["id"],
         "hash" => task_hash,
         "sha256" => task_hash,
         "split" => row["split"],
         "input" => content["instruction_file"],
         "initial_files" => %{"input.txt" => content["input_file"]},
         "artifact_path" => "artifact.txt",
         "profiles" => %{
           "reference" => %{"mode" => "artifact", "artifact" => content["reference_file"]},
           "regressed" => %{
             "mode" => row["regressed_mode"],
             "artifact" => content["regressed_file"]
           }
         },
         "oracle" => %{
           "kind" => "exact_bytes_v1",
           "expected_sha256" => hash(content["expected_file"]),
           "expected_bytes" => byte_size(content["expected_file"])
         }
       }, hashes}
    else
      false -> {:error, :invalid_task_content}
      error -> error
    end
  end

  defp load_files(root, row) do
    Enum.reduce_while(@file_fields, {:ok, %{}, %{}}, fn key, {:ok, contents, hashes} ->
      relative = row[key]
      path = Path.join(root, relative)

      with :ok <- no_symlinks(root, relative), {:ok, bytes} <- read_bounded(path, 16_384) do
        {:cont, {:ok, Map.put(contents, key, bytes), Map.put(hashes, relative, hash(bytes))}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp no_symlinks(root, relative) do
    [root | Enum.scan(Path.split(relative), root, &Path.join(&2, &1))]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :fixture_symlink}}
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :missing_fixture}}
      end
    end)
  end

  defp read_at_most(path, max) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, max + 1) do
        bytes when is_binary(bytes) -> bytes
        :eof -> <<>>
        _ -> raise ArgumentError, "unreadable fixture"
      end
    end)
  end

  defp read_bounded(path, max) do
    with {:ok, %{type: :regular, size: size}} when size <= max <- File.lstat(path),
         {:ok, bytes} <- read_at_most(path, max),
         true <- byte_size(bytes) <= max do
      {:ok, bytes}
    else
      _ -> {:error, :fixture_missing_or_too_large}
    end
  end
end
