defmodule AgentSystemsLab.CandidatePackage do
  @moduledoc """
  Builds and checks a local v0.1 teaching candidate from frozen, inert evidence.

  This trusted-host helper never runs a command, extracts an archive, starts the
  application, or connects to a database. Digests establish byte integrity, not
  authenticity or independent attestation. A candidate label is not a Git tag.
  Use private trees without concurrent writers. A failed build may leave an
  incomplete fresh directory; only a successfully verified manifest is a candidate.
  """

  import Bitwise, only: [band: 2]
  alias AgentSystemsLab.{FrozenFaultMatrix, ReleaseReadiness, Reproduction}

  @root Path.expand("../..", __DIR__)
  @manifest "candidate-manifest.json"
  @evidence "candidate-evidence"
  @source_manifest "reproduction-source-manifest.json"
  @index_keys ~w(schema_version kind source_manifest_sha256 full memory matrix files human_readers linux_validation)
  @regression_keys ~w(path sha256 passed doctests tests excluded exit_status argv)
  @max_file 33_554_432
  @max_json 16_777_216
  @max_total 335_544_320
  @max_entries 20_000
  @drafts ~w(book/ch02-agent-state-machine.md book/ch05-agent-loop-and-tools.md book/ch08-session-context.md book/ch14-history-checkpoints-and-replay.md book/ch16-durable-effects-and-reconciliation.md book/ch20-scheduling-and-recovery.md)
  @manuals ~w(docs/candidate-release.md docs/results-index.md docs/known-limitations.md docs/backlog.md docs/recovery-runbook.md labs/L23-frozen-candidate-release.md labs/solutions/L23.md)

  @doc "Builds a fresh source-only candidate; evidence paths are data, never commands."
  def build(output, opts \\ []) do
    with :ok <- options(opts),
         {:ok, evidence_root} <- directory(Keyword.fetch!(opts, :evidence)),
         {:ok, index, raw_index} <- read_index(evidence_root),
         {:ok, evidence} <- validate_evidence(evidence_root, index),
         source = Keyword.get(opts, :source, @root),
         {:ok, _} <- teaching(source),
         {:ok, exported} <- Reproduction.export(output, source: source),
         {:ok, source_bytes} <- read(exported.output_dir, @source_manifest, @max_json),
         true <- hash(source_bytes) == index["source_manifest_sha256"],
         :ok <- copy_evidence(evidence_root, exported.output_dir, index, raw_index),
         :ok <- private_file(Path.join(exported.output_dir, "START-HERE.md"), start_here()),
         {:ok, manifest} <- derive(exported.output_dir, index, evidence),
         :ok <-
           private_file(Path.join(exported.output_dir, @manifest), JSON.encode!(manifest) <> "\n"),
         {:ok, verified} <- verify(exported.output_dir) do
      {:ok, verified}
    else
      false -> {:error, :candidate_source_binding_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :candidate_build_failed}
    end
  rescue
    _ -> {:error, :candidate_build_failed}
  end

  @doc "Recomputes source, evidence, gates and the complete package inventory without execution."
  def verify(output) do
    with {:ok, root} <- directory(output),
         {:ok, %{mode: root_mode}} <- File.lstat(root),
         true <- band(root_mode, 0o777) == 0o700,
         {:ok, %{mode: manifest_mode}} <- File.lstat(Path.join(root, @manifest)),
         true <- band(manifest_mode, 0o777) == 0o600,
         {:ok, raw} <- read(root, @manifest, @max_json),
         {:ok, manifest} <- JSON.decode(raw),
         {:ok, _} <- Reproduction.verify(root),
         {:ok, _} <- teaching(root),
         {:ok, index, _} <- read_index(Path.join(root, @evidence)),
         {:ok, source_bytes} <- read(root, @source_manifest, @max_json),
         true <- hash(source_bytes) == index["source_manifest_sha256"],
         {:ok, evidence} <- validate_evidence(Path.join(root, @evidence), index),
         {:ok, derived} <- derive(root, index, evidence),
         true <- manifest === derived do
      {:ok, %{output_dir: root, manifest_path: Path.join(root, @manifest), manifest: manifest}}
    else
      false -> {:error, :candidate_manifest_or_source_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :candidate_verification_failed}
    end
  rescue
    _ -> {:error, :candidate_verification_failed}
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:source, :evidence])) and
         Keyword.has_key?(opts, :evidence),
       do: :ok,
       else: {:error, :candidate_invalid_options}
  end

  defp teaching(source) do
    with {:ok, report} <- ReleaseReadiness.check(source: source),
         true <- report["course_count"] == 12 and report["chapter_card_count"] == 30,
         :ok <- each(@drafts ++ @manuals, fn path -> nonempty(source, path) end),
         {:ok, paths} <- lab_paths(source),
         :ok <- each(paths, fn path -> nonempty(source, path) end) do
      {:ok, report}
    else
      {:error, _} = error -> error
      _ -> {:error, :candidate_teaching_material_incomplete}
    end
  end

  defp lab_paths(source) do
    with {:ok, _} <- directory(Path.join(source, "labs")),
         {:ok, names} <- File.ls(Path.join(source, "labs")) do
      Enum.reduce_while(1..23, {:ok, []}, fn number, {:ok, paths} ->
        id = "L" <> String.pad_leading(Integer.to_string(number), 2, "0")
        matches = Enum.filter(names, &Regex.match?(~r/^#{id}-[a-z0-9-]+\.md$/, &1))

        case matches do
          [name] -> {:cont, {:ok, paths ++ ["labs/" <> name, "labs/solutions/" <> id <> ".md"]}}
          _ -> {:halt, {:error, :candidate_teaching_material_incomplete}}
        end
      end)
    end
  end

  defp nonempty(root, path) do
    with {:ok, bytes} <- read(root, path, 2_097_152),
         true <- byte_size(bytes) > 0,
         do: :ok,
         else: (_ -> {:error, :candidate_teaching_material_incomplete})
  end

  defp read_index(root) do
    with {:ok, raw} <- read(root, "index.json", @max_json),
         {:ok, index} <- JSON.decode(raw),
         true <- exact?(index, @index_keys),
         true <- index["schema_version"] === 1,
         true <- index["kind"] === "agent-systems-lab.frozen-evidence.v1",
         true <- digest?(index["source_manifest_sha256"]),
         true <- index["human_readers"] === 0 and index["linux_validation"] === "pending",
         true <- is_list(index["files"]) and length(index["files"]) in 3..@max_entries,
         true <- Enum.all?(index["files"], &file_record?/1),
         paths = Enum.map(index["files"], & &1["path"]),
         true <- length(paths) == length(Enum.uniq(paths)),
         true <- Enum.sum(Enum.map(index["files"], & &1["bytes"])) <= 268_435_456,
         true <- not Enum.any?(paths, &(&1 == "index.json")) do
      {:ok, index, raw}
    else
      _ -> {:error, :candidate_invalid_evidence_index}
    end
  end

  defp validate_evidence(root, index) do
    with :ok <- each(index["files"], &check_record(root, &1)),
         {:ok, full} <- regression(root, index, "full", ["./scripts/mix", "check"]),
         {:ok, memory} <- regression(root, index, "memory", ["./scripts/mix", "test"]),
         true <- full["passed"] == memory["passed"] + memory["excluded"],
         true <- full["excluded"] == 0 and memory["excluded"] > 0,
         true <- exact?(index["matrix"], ~w(path sha256)),
         true <- reference?(index, index["matrix"]),
         true <- Path.basename(index["matrix"]["path"]) == "report.json",
         {:ok, matrix} <-
           FrozenFaultMatrix.verify(Path.dirname(Path.join(root, index["matrix"]["path"]))),
         true <- matrix["complete"] === true and matrix["all_passed"] === true,
         true <- matrix["required_repetitions"] === 20,
         true <- matrix["totals"]["completed_rows"] === 12,
         true <- matrix["totals"]["completed_repetitions"] === 240 do
      {:ok, %{"full" => full, "memory" => memory, "matrix" => matrix}}
    else
      {:error, _} = error -> error
      _ -> {:error, :candidate_evidence_not_passed}
    end
  end

  defp regression(root, index, key, argv) do
    record = index[key]

    with true <- exact?(record, @regression_keys),
         true <- reference?(index, Map.take(record, ~w(path sha256))),
         true <- record["exit_status"] === 0 and record["argv"] === argv,
         true <-
           Enum.all?(
             ~w(passed doctests tests excluded),
             &(is_integer(record[&1]) and record[&1] >= 0)
           ),
         true <- record["passed"] > 0 and record["passed"] == record["doctests"] + record["tests"],
         {:ok, raw} <- read(root, record["path"], @max_file),
         {:ok, observed} <- footer(raw),
         true <- Map.take(record, ~w(passed doctests tests excluded)) === observed do
      {:ok, record}
    else
      _ -> {:error, :candidate_regression_evidence_invalid}
    end
  end

  defp footer(raw) do
    matches =
      Regex.scan(
        ~r/^Result: (\d+) passed \((\d+) doctests, (\d+) tests\)(?:, (\d+) excluded)?\r?$/m,
        raw
      )

    case matches do
      [values] ->
        [_line, passed, doctests, tests | extra] = values

        excluded =
          case extra do
            [value] when value != "" -> String.to_integer(value)
            _ -> 0
          end

        if Regex.match?(~r/^\s*\d+\)\s|^Result:.*(?:failed|failure)/m, raw),
          do: {:error, :candidate_regression_failures},
          else:
            {:ok,
             %{
               "passed" => String.to_integer(passed),
               "doctests" => String.to_integer(doctests),
               "tests" => String.to_integer(tests),
               "excluded" => excluded
             }}

      _ ->
        {:error, :candidate_regression_footer_missing}
    end
  end

  defp reference?(index, reference) do
    exact?(reference, ~w(path sha256)) and
      Enum.any?(
        index["files"],
        &(&1["path"] === reference["path"] and &1["sha256"] === reference["sha256"])
      )
  end

  defp file_record?(record) do
    exact?(record, ~w(path sha256 bytes)) and evidence_path?(record["path"]) and
      digest?(record["sha256"]) and is_integer(record["bytes"]) and
      record["bytes"] in 1..@max_file
  end

  defp check_record(root, record) do
    with {:ok, raw} <- read(root, record["path"], @max_file),
         true <- byte_size(raw) === record["bytes"] and hash(raw) === record["sha256"],
         do: :ok,
         else: (_ -> {:error, :candidate_evidence_integrity_mismatch})
  end

  defp copy_evidence(source, output, index, raw_index) do
    target = Path.join(output, @evidence)

    with :ok <- File.mkdir(target),
         :ok <- File.chmod(target, 0o700),
         :ok <-
           each(index["files"], fn entry ->
             with {:ok, raw} <- read(source, entry["path"], @max_file),
                  true <- hash(raw) === entry["sha256"] and byte_size(raw) === entry["bytes"],
                  :ok <-
                    private_directories(Path.dirname(Path.join(target, entry["path"])), target),
                  do: private_file(Path.join(target, entry["path"]), raw),
                  else: (_ -> {:error, :candidate_evidence_changed})
           end),
         :ok <- private_file(Path.join(target, "index.json"), raw_index),
         {:ok, _} <- validate_evidence(target, index),
         do: :ok
  end

  defp private_directories(path, root) do
    with :ok <- File.mkdir_p(path) do
      path
      |> ancestors_until(root)
      |> each(&File.chmod(&1, 0o700))
    end
  end

  defp ancestors_until(path, path), do: [path]
  defp ancestors_until(path, root), do: [path | ancestors_until(Path.dirname(path), root)]

  defp derive(root, index, evidence) do
    with {:ok, entries} <- inventory(root),
         {:ok, source_bytes} <- read(root, @source_manifest, @max_json),
         {:ok, index_bytes} <- read(root, @evidence <> "/index.json", @max_json),
         {:ok, source_manifest} <- JSON.decode(source_bytes),
         true <- allowed_inventory?(entries, source_manifest, index) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "agent-systems-lab.teaching-candidate.v1",
         "candidate_label" => "v0.1.0-rc.1",
         "candidate_label_kind" => "local_manifest_label_not_git_tag",
         "project_version" => "0.1.0-dev",
         "target_version" => "0.1.0",
         "technical_candidate_ready" => true,
         "release_ready" => false,
         "external_humans" => 0,
         "linux_validation" => "pending",
         "release_blockers" => [
           "3–5 external human readers including independent reproduction",
           "Linux isolation and frozen acceptance matrix"
         ],
         "trust" =>
           "trusted-host execution records; integrity is not authentication or independent attestation",
         "source_manifest_sha256" => hash(source_bytes),
         "source_file_count" => source_manifest["file_count"],
         "evidence_index_sha256" => hash(index_bytes),
         "full_regression" => evidence["full"],
         "memory_regression" => evidence["memory"],
         "matrix" => %{
           "rows" => 12,
           "repetitions_per_row" => 20,
           "completed_repetitions" => 240,
           "all_passed" => true
         },
         "teaching_material" => %{
           "courses" => 12,
           "chapter_cards" => 30,
           "chapter_drafts" => 6,
           "labs" => 23
         },
         "entries" => entries,
         "entry_count" => length(entries),
         "total_bytes" => Enum.reduce(entries, 0, &(&1["bytes"] + &2)),
         "entries_sha256" => hash(JSON.encode!(entries))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :candidate_unlisted_package_entry}
    end
  end

  defp allowed_inventory?(entries, source_manifest, index) do
    source_paths = Enum.map(source_manifest["entries"], & &1["path"])
    evidence_files = Enum.map(index["files"], &(@evidence <> "/" <> &1["path"]))
    evidence_dirs = Enum.flat_map(evidence_files, &relative_parents(Path.dirname(&1)))

    expected =
      MapSet.new(
        source_paths ++
          evidence_files ++
          evidence_dirs ++
          [@source_manifest, "START-HERE.md", @evidence, @evidence <> "/index.json"]
      )

    MapSet.new(Enum.map(entries, & &1["path"])) == expected
  end

  defp relative_parents("."), do: []
  defp relative_parents(path), do: [path | relative_parents(Path.dirname(path))]

  defp inventory(root) do
    with {:ok, names} <- File.ls(root),
         {:ok, entries} <- walk_names(root, "", Enum.reject(names, &(&1 == @manifest)), []),
         true <-
           length(entries) <= @max_entries and
             Enum.sum(Enum.map(entries, & &1["bytes"])) <= @max_total,
         do: {:ok, Enum.sort_by(entries, & &1["path"])},
         else: (_ -> {:error, :candidate_package_inventory_invalid})
  end

  defp walk_names(root, prefix, names, entries) do
    Enum.reduce_while(Enum.sort(names), {:ok, entries}, fn name, {:ok, entries} ->
      relative = if prefix == "", do: name, else: prefix <> "/" <> name

      with true <- relative?(relative) and length(entries) < @max_entries,
           {:ok, stat} <- File.lstat(Path.join(root, relative)),
           true <- band(stat.mode, 0o7000) == 0 do
        case stat do
          %{type: :directory} ->
            entry = %{
              "path" => relative,
              "type" => "directory",
              "mode" => band(stat.mode, 0o777),
              "bytes" => 0
            }

            with {:ok, children} <- File.ls(Path.join(root, relative)),
                 {:ok, next} <- walk_names(root, relative, children, [entry | entries]),
                 do: {:cont, {:ok, next}},
                 else: (_ -> {:halt, {:error, :candidate_package_inventory_invalid}})

          %{type: :regular, links: 1, size: size} when size <= @max_file ->
            with true <- size + Enum.sum(Enum.map(entries, & &1["bytes"])) <= @max_total,
                 {:ok, raw} <- read(root, relative, @max_file) do
              {:cont,
               {:ok,
                [
                  %{
                    "path" => relative,
                    "type" => "file",
                    "mode" => band(stat.mode, 0o777),
                    "bytes" => size,
                    "sha256" => hash(raw)
                  }
                  | entries
                ]}}
            else
              _ -> {:halt, {:error, :candidate_package_inventory_invalid}}
            end

          _ ->
            {:halt, {:error, :candidate_package_inventory_invalid}}
        end
      else
        _ -> {:halt, {:error, :candidate_package_inventory_invalid}}
      end
    end)
  end

  defp read(root, relative, limit) do
    with true <- relative?(relative),
         {:ok, _} <- directory(Path.dirname(Path.join(root, relative))),
         {:ok, %{type: :regular, links: 1, size: size, mode: mode}} <-
           File.lstat(Path.join(root, relative)),
         true <- size <= limit and band(mode, 0o7000) == 0,
         {:ok, raw} <- File.read(Path.join(root, relative)),
         true <- byte_size(raw) == size,
         do: {:ok, raw},
         else: (_ -> {:error, :candidate_unsafe_or_missing_file})
  end

  defp directory(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and String.valid?(path) and safe?(path),
         expanded = Path.expand(path),
         :ok <- directory_components(expanded),
         do: {:ok, expanded},
         else: (_ -> {:error, :candidate_unsafe_directory})
  end

  defp directory(_), do: {:error, :candidate_unsafe_directory}

  defp directory_components(expanded) do
    result =
      Enum.reduce_while(Path.split(expanded), "", fn part, prefix ->
        next = if prefix == "", do: part, else: Path.join(prefix, part)

        case File.lstat(next) do
          {:ok, %{type: :directory}} -> {:cont, next}
          _ -> {:halt, {:error, :candidate_unsafe_directory}}
        end
      end)

    case result do
      final when is_binary(final) -> :ok
      error -> error
    end
  end

  defp relative?(path),
    do:
      is_binary(path) and String.valid?(path) and safe?(path) and path != "" and
        Path.type(path) == :relative and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
        not String.contains?(path, "\\")

  defp evidence_path?(path) do
    relative?(path) and
      Path.extname(path) in ~w(.json .log .txt .bin .dump .diff .patch .ex .exs .jsonl .py .md .sha256 .c .h .sh) and
      Enum.all?(String.split(path, "/"), fn part ->
        not String.starts_with?(part, ".") and
          String.downcase(part) not in ["pgdata", "deps", "_build", "runtime"]
      end)
  end

  defp safe?(value), do: not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp private_file(path, raw),
    do: with(:ok <- File.write(path, raw, [:exclusive]), do: File.chmod(path, 0o600))

  defp each(values, fun),
    do:
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case fun.(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp start_here do
    """
    # Agent Systems Lab v0.1.0-rc.1 候选教学包

    这是本地 manifest 候选标识，并非 Git tag。项目版本保持 `0.1.0-dev`。

    从本目录阅读 [候选指南](docs/candidate-release.md)、[结果索引](docs/results-index.md)、
    [已知限制](docs/known-limitations.md)、[后续 backlog](docs/backlog.md) 和 [L23](labs/L23-frozen-candidate-release.md)。
    教学源码、12 个课程入口、30 张章节卡、6 章长稿与 L01–L23 均在包内。

    在已安装依赖的可信工作区执行 `./scripts/mix lab.candidate verify --output ABSOLUTE_PACKAGE_PATH`。
    验证只读有界文件，不执行包内命令，不连接数据库。SHA256 仅验证完整性，不能证明来源可信。
    `candidate-evidence/index.json` 绑定本次冻结源码与实测日志；本包没有复制运行时、依赖、PGDATA 或凭据。

    技术候选验收通过不代表正式发布：真实外部试读仍为 0 人，Linux 验收待完成，`release_ready` 为 false。
    """
  end
end
