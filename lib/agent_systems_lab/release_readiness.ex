defmodule AgentSystemsLab.ReleaseReadiness do
  @moduledoc """
  Read-only, bounded checks of the W23 publication source contract.

  This trusted-host metadata helper does not start the application, connect to
  PostgreSQL, execute source, run a course command, or assess human readers.
  A source-ready report is never a release gate. Hashes detect drift against
  this compiled contract; they do not authenticate a download or a release.
  Use a private source tree without concurrent writers, as with Reproduction.
  """

  import Bitwise, only: [band: 2]

  @root Path.expand("../..", __DIR__)
  @manifest_path "fixtures/release/manifest.json"
  @external_resource Path.join(@root, @manifest_path)
  @expected_manifest @external_resource |> File.read!() |> JSON.decode!()
  # Explicitly approved immutable W23-W26 and initial GitHub-preparation
  # contracts. Their own pinned files are still checked below; a source cannot
  # supply arbitrary replacement pins by rewriting its manifest.
  @historical_manifest_sha256 ~w(
    cd0f25e40ad2e2b3dd19cb1b08fb1d84a0ab412096d6f84c3fdfc46b46c055e4
    c825fd9cae04c56c4b1a1817f079d7b6fb6a88232b0f32013118394974b4fb91
  )
  @max_manifest 262_144
  @max_file 2_097_152
  @max_total 16_777_216
  @card_labels ["目标：", "前置知识：", "源码入口：", "实验：", "习题：", "教师参考：", "证据：", "状态："]
  @course_labels ["起点：", "学生任务：", "参考解答：", "测试命令：", "成功标准：", "平台要求："]

  @doc "Checks fixed source metadata only; accepts an absolute copied source for tests."
  def check(opts \\ []) do
    with :ok <- options(opts),
         {:ok, source} <- source_directory(Keyword.get(opts, :source, @root)),
         {:ok, raw_manifest} <- read(source, @manifest_path, @max_manifest),
         {:ok, manifest} <- JSON.decode(raw_manifest),
         :ok <- contract(manifest, raw_manifest),
         {:ok, files} <- files(source, required_paths(manifest)),
         :ok <- pins(source, manifest, files),
         :ok <- migrations(source, manifest),
         :ok <- cards(manifest, files),
         :ok <- courses(manifest, files),
         {:ok, files} <- linked_files(source, files) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "agent-systems-lab.release-source-readiness.v1",
         "source_ready" => true,
         "release_ready" => false,
         "project_version" => "0.1.0-dev",
         "target_version" => "0.1.0",
         "runtime_pins" => manifest["runtime_pins"],
         "runtime_observation" => "source pins only; installed BEAM/PostgreSQL not assessed",
         "schema_versions" => manifest["schema_versions"],
         "manifest_sha256" => hash(raw_manifest),
         "source_checks_sha256" => checks_hash(files),
         "checked_file_count" => map_size(files),
         "pinned_file_count" => length(manifest["pinned_files"]),
         "migration_count" => length(manifest["migrations"]),
         "course_count" => length(manifest["courses"]),
         "chapter_card_count" => length(manifest["chapters"]),
         "course_ids" => Enum.map(manifest["courses"], & &1["id"]),
         "chapter_ids" => Enum.map(manifest["chapters"], & &1["id"]),
         "external_humans" => "not_assessed",
         "week24_matrix" => "pending",
         "tag" => "not_created",
         "limitations" => [
           "source metadata is not proof that tests or course commands ran",
           "W22 external human review remains a separate gate",
           "W24 frozen matrix, packaging and candidate tag remain pending"
         ]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_invalid_manifest}
    end
  rescue
    _ -> {:error, :release_check_failed}
  end

  @doc "Returns fixed argv as inert data after checking source; executes no commands."
  def plan(opts \\ []) do
    with {:ok, report} <- check(opts) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "agent-systems-lab.release-plan.v1",
         "source_ready" => true,
         "release_ready" => false,
         "manifest_sha256" => report["manifest_sha256"],
         "execution" => "data_only; no commands executed",
         "courses" =>
           Enum.map(@expected_manifest["courses"], fn course ->
             Map.take(course, ["id", "original_lab", "title", "labs", "commands"])
           end),
         "external_humans" => "not_assessed",
         "week24_matrix" => "pending",
         "tag" => "not_created",
         "pending_gates" => [
           "3–5 external human readers and independent reproduction evidence",
           "W24 frozen full and memory regression matrix",
           "W24 experiment results index and known-limitations review",
           "W24 teaching package verification and candidate tag"
         ]
       }}
    end
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Keyword.keys(opts) in [[], [:source]],
       do: :ok,
       else: {:error, :release_invalid_options}
  end

  defp contract(manifest, raw_manifest) do
    approved =
      manifest === @expected_manifest or hash(raw_manifest) in @historical_manifest_sha256

    if approved and manifest["schema_version"] === 1 and
         manifest["project_version"] === "0.1.0-dev" and
         manifest["target_version"] === "0.1.0" and
         manifest["runtime_pins"] === %{
           "elixir" => "1.20.4",
           "otp" => "28.4",
           "postgres" => "18.6"
         } and
         manifest["schema_versions"] === %{
           "kernel" => 1,
           "codec" => 1,
           "history_layouts" => [1, 2]
         } and
         Enum.map(manifest["courses"], & &1["id"]) === ids("C", 12) and
         Enum.map(manifest["chapters"], & &1["id"]) === ids("ch", 30) and
         fixed_commands?(manifest["courses"]) and
         length(manifest["migrations"]) === 21,
       do: :ok,
       else: {:error, :release_contract_mismatch}
  end

  defp fixed_commands?(courses) do
    Enum.all?(courses, fn course ->
      tests = course["tests"]

      is_list(tests) and tests != [] and length(tests) == length(Enum.uniq(tests)) and
        Enum.all?(tests, &Regex.match?(~r/^test\/agent_systems_lab\/[a-z_]+_test\.exs$/, &1)) and
        course["commands"] === [["./scripts/mix", "test" | tests]]
    end)
  end

  defp required_paths(manifest) do
    (Enum.map(manifest["pinned_files"] ++ manifest["migrations"], & &1["path"]) ++
       manifest["manuals"] ++
       Enum.flat_map(manifest["courses"], &(&1["labs"] ++ &1["solutions"] ++ &1["tests"])))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp files(source, paths) do
    Enum.reduce_while(paths, {:ok, %{}, 0}, fn path, {:ok, entries, total} ->
      with {:ok, bytes} <- read(source, path, @max_file),
           true <- byte_size(bytes) > 0 and total + byte_size(bytes) <= @max_total do
        {:cont, {:ok, Map.put(entries, path, bytes), total + byte_size(bytes)}}
      else
        false -> {:halt, {:error, :release_source_too_large}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _total} -> {:ok, entries}
      error -> error
    end
  end

  defp pins(source, manifest, files) do
    if Enum.all?(manifest["pinned_files"] ++ manifest["migrations"], fn pin ->
         bytes = Map.fetch!(files, pin["path"])

         case File.lstat(Path.join(source, pin["path"])) do
           {:ok, stat} ->
             stat.type == :regular and stat.links == 1 and
               pin["sha256"] === hash(bytes) and pin["bytes"] === byte_size(bytes) and
               pin["mode"] === band(stat.mode, 0o777)

           _ ->
             false
         end
       end),
       do: :ok,
       else: {:error, :release_pin_drift}
  end

  defp migrations(source, manifest) do
    directory = Path.join(source, "priv/repo/migrations")

    with {:ok, names} <- File.ls(directory) do
      actual = Enum.map(Enum.sort(names), &("priv/repo/migrations/" <> &1))
      expected = Enum.map(manifest["migrations"], & &1["path"])

      if actual === expected,
        do: :ok,
        else: {:error, :release_migration_inventory_mismatch}
    end
  end

  defp cards(manifest, files) do
    sections = sections(files["book/chapter-cards.md"], "chapter")

    if Enum.map(sections, &elem(&1, 0)) === ids("ch", 30) and
         Enum.zip(sections, manifest["chapters"])
         |> Enum.all?(fn {{_id, body}, card} ->
           fields = fields(body, @card_labels)

           valid_fields?(fields, @card_labels) and
             contains_all?(body, [card["title"], "状态：" <> card["status"]]) and
             exercises?(fields["习题："]) and exercises?(fields["教师参考："]) and
             exercise_markers(fields["习题："]) == exercise_markers(fields["教师参考："]) and
             linked_field?(fields["源码入口："]) and linked_field?(fields["实验："]) and
             linked_field?(fields["证据："])
         end),
       do: :ok,
       else: {:error, :release_chapter_cards_invalid}
  end

  defp courses(manifest, files) do
    sections = sections(files["docs/course-map.md"], "course")

    if Enum.map(sections, &elem(&1, 0)) === ids("C", 12) and
         Enum.zip(sections, manifest["courses"])
         |> Enum.all?(fn {{_id, body}, course} ->
           fields = fields(body, @course_labels)
           referenced = link_paths(body, "docs/course-map.md")
           normalized = body |> String.split() |> Enum.join(" ")

           valid_fields?(fields, @course_labels) and
             contains_all?(body, [course["title"], course["original_lab"]]) and
             Enum.all?(course["labs"] ++ course["solutions"], &(&1 in referenced)) and
             contains_all?(body, course["tests"]) and
             Enum.all?(course["commands"], &String.contains?(normalized, Enum.join(&1, " ")))
         end),
       do: :ok,
       else: {:error, :release_courses_invalid}
  end

  defp sections(bytes, kind) do
    regex = Regex.compile!("<!-- " <> kind <> ":([^>]*?) -->")
    markers = Regex.scan(regex, bytes, return: :index)

    markers
    |> Enum.with_index()
    |> Enum.map(fn {[{start, length}, {id_start, id_length}], index} ->
      finish =
        case Enum.at(markers, index + 1) do
          [{next, _length} | _rest] -> next
          nil -> byte_size(bytes)
        end

      {binary_part(bytes, id_start, id_length),
       binary_part(bytes, start + length, finish - start - length)}
    end)
  end

  defp contains_all?(body, values), do: Enum.all?(values, &String.contains?(body, &1))

  defp fields(body, labels) do
    regex = Regex.compile!("(?m)^(" <> Enum.map_join(labels, "|", &Regex.escape/1) <> ")")
    matches = Regex.scan(regex, body, return: :index)

    if length(matches) == length(labels) do
      matches
      |> Enum.with_index()
      |> Map.new(fn {[{start, length}, _label], index} ->
        finish =
          case Enum.at(matches, index + 1) do
            [{next, _length} | _rest] -> next
            nil -> byte_size(body)
          end

        {binary_part(body, start, length),
         binary_part(body, start + length, finish - start - length) |> String.trim()}
      end)
    else
      %{}
    end
  end

  defp valid_fields?(fields, labels) do
    map_size(fields) == length(labels) and
      Enum.all?(labels, fn label ->
        value = fields[label]
        is_binary(value) and Regex.match?(~r/[\p{L}\p{N}]/u, value)
      end)
  end

  defp exercises?(nil), do: false

  defp exercises?(body) do
    markers = exercise_markers(body)
    answers = Regex.split(~r/[①②③④⑤](?=\s)/u, body) |> tl()

    markers in [["①", "②", "③"], ["①", "②", "③", "④"], ["①", "②", "③", "④", "⑤"]] and
      Enum.all?(answers, &Regex.match?(~r/[\p{L}\p{N}]/u, &1))
  end

  defp exercise_markers(body), do: Regex.scan(~r/[①②③④⑤](?=\s)/u, body) |> List.flatten()

  defp linked_field?(nil), do: false
  defp linked_field?(body), do: link_targets(body) != []

  defp link_targets(body) do
    Regex.scan(~r/!?\[[^\]]*\]\(([^\s)]+)\)/u, body)
    |> Enum.map(fn [_whole, target] -> target end)
  end

  defp link_paths(body, document) do
    body
    |> link_targets()
    |> Enum.reject(&external_or_anchor?/1)
    |> Enum.map(fn target ->
      path = target |> String.split("#", parts: 2) |> hd() |> URI.decode()
      Path.expand(path, "/" <> Path.dirname(document)) |> String.trim_leading("/")
    end)
  end

  defp external_or_anchor?(target),
    do: String.starts_with?(target, ["https://", "http://", "mailto:", "#"])

  defp linked_files(source, files) do
    documents = ["book/chapter-cards.md", "docs/course-map.md"]

    targets =
      Enum.flat_map(documents, fn document ->
        files[document]
        |> link_targets()
        |> Enum.reject(&external_or_anchor?/1)
        |> Enum.map(&{document, &1})
      end)

    if length(targets) > 1_000 do
      {:error, :release_too_many_links}
    else
      Enum.reduce_while(targets, {:ok, files}, fn {document, target}, {:ok, current} ->
        path = target |> String.split("#", parts: 2) |> hd() |> URI.decode()
        absolute = Path.expand(path, Path.join(source, Path.dirname(document)))
        relative = Path.relative_to(absolute, source)
        allowed = permitted_source_path?(relative)

        with true <- Path.type(path) == :relative and allowed,
             {:ok, bytes} <- read(source, relative, @max_file),
             next = Map.put(current, relative, bytes),
             true <-
               Enum.sum(Enum.map(next, fn {_path, value} -> byte_size(value) end)) <= @max_total do
          {:cont, {:ok, next}}
        else
          _ -> {:halt, {:error, {:release_invalid_local_link, document, target}}}
        end
      end)
    end
  end

  defp permitted_source_path?(relative) do
    safe_relative?(relative) and
      (hd(Path.split(relative)) in ~w(.github book config docs fixtures labs lib priv scripts test) or
         relative in [
           "README.md",
           "mix.exs",
           "mix.lock",
           ".tool-versions",
           "Agent Systems Engineering 研究与落地计划.md"
         ])
  end

  defp ids(prefix, count),
    do: Enum.map(1..count, &(prefix <> String.pad_leading(to_string(&1), 2, "0")))

  defp source_directory(path) when is_binary(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path do
      with :ok <- physical_directories(path), do: {:ok, path}
    else
      {:error, :release_unsafe_source}
    end
  end

  defp source_directory(_path), do: {:error, :release_unsafe_source}

  defp physical_directories(path) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, current} ->
      next = if current == "", do: part, else: Path.join(current, part)

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :release_unsafe_source}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end

  defp read(source, relative, limit) do
    path = Path.join(source, relative)

    with true <- safe_relative?(relative),
         :ok <- physical_directories(Path.dirname(path)),
         {:ok, before} <- File.lstat(path),
         true <- before.type == :regular and before.links == 1 and before.size <= limit,
         true <- band(before.mode, 0o444) != 0,
         {:ok, bytes} <- bounded_read(path, limit),
         true <- byte_size(bytes) == before.size and byte_size(bytes) <= limit,
         {:ok, after_read} <- File.lstat(path),
         true <- stable_stat(before) == stable_stat(after_read) do
      {:ok, bytes}
    else
      _ -> {:error, {:release_unsafe_or_missing_file, relative}}
    end
  end

  defp stable_stat(stat), do: stat |> Map.from_struct() |> Map.delete(:atime)

  defp bounded_read(path, limit) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, limit + 1) do
        :eof -> ""
        bytes -> bytes
      end
    end)
  end

  defp safe_relative?(path) when is_binary(path) do
    Path.type(path) == :relative and Path.split(path) != [] and
      Enum.all?(Path.split(path), &(&1 not in [".", "..", ""])) and
      not String.contains?(path, ["\0", "\\"])
  end

  defp safe_relative?(_path), do: false

  defp checks_hash(files) do
    files
    |> Enum.map(fn {path, bytes} -> {path, hash(bytes)} end)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {path, digest} -> path <> ":" <> digest end)
    |> hash()
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
