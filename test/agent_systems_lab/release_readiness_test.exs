defmodule AgentSystemsLab.ReleaseReadinessTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.ReleaseReadiness

  @root Path.expand("../..", __DIR__)
  @manifest "fixtures/release/manifest.json"

  setup do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    base = Path.join(parent, "lab_release_" <> Ecto.UUID.generate())
    source = Path.join(base, "source")
    manifest = @root |> Path.join(@manifest) |> File.read!() |> JSON.decode!()

    linked =
      Enum.flat_map(["book/chapter-cards.md", "docs/course-map.md"], fn document ->
        Regex.scan(~r/\[[^\]]*\]\(([^\s)]+)\)/u, File.read!(Path.join(@root, document)))
        |> Enum.map(fn [_all, target] -> target end)
        |> Enum.reject(&String.starts_with?(&1, ["https://", "http://", "mailto:", "#"]))
        |> Enum.map(fn target ->
          target
          |> String.split("#", parts: 2)
          |> hd()
          |> URI.decode()
          |> Path.expand(Path.dirname(Path.join(@root, document)))
          |> Path.relative_to(@root)
        end)
      end)

    paths =
      [@manifest] ++
        linked ++
        Enum.map(manifest["pinned_files"] ++ manifest["migrations"], & &1["path"]) ++
        manifest["manuals"] ++
        Enum.flat_map(manifest["courses"], &(&1["labs"] ++ &1["solutions"] ++ &1["tests"]))

    for relative <- Enum.uniq(paths) do
      target = Path.join(source, relative)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, relative), target)
    end

    on_exit(fn -> File.rm_rf!(base) end)
    %{source: source, manifest: manifest, base: base}
  end

  test "complete copied source returns deterministic metadata and leaves every byte unchanged",
       c do
    before = snapshot(c.source)
    assert {:ok, report} = ReleaseReadiness.check(source: c.source)
    assert {:ok, ^report} = ReleaseReadiness.check(source: c.source)
    assert snapshot(c.source) == before
    assert report["source_ready"]
    refute report["release_ready"]
    assert report["project_version"] == "0.1.0-dev"
    assert report["target_version"] == "0.1.0"
    assert report["course_count"] == 12
    assert report["chapter_card_count"] == 30
    assert report["migration_count"] == 21
    assert report["external_humans"] == "not_assessed"
    assert report["week24_matrix"] == "pending"
    assert report["tag"] == "not_created"

    assert report["schema_versions"] == %{
             "kernel" => 1,
             "codec" => 1,
             "history_layouts" => [1, 2]
           }

    assert report["runtime_pins"] == %{
             "elixir" => "1.20.4",
             "otp" => "28.4",
             "postgres" => "18.6"
           }

    assert report["runtime_observation"] =~ "source pins only"
    assert byte_size(report["source_checks_sha256"]) == 64
    assert byte_size(report["manifest_sha256"]) == 64
  end

  test "fixed plan is inert test argv and cannot claim a final release", c do
    before = snapshot(c.source)
    assert {:ok, plan} = ReleaseReadiness.plan(source: c.source)
    assert length(plan["courses"]) == 12
    assert Enum.map(plan["courses"], & &1["id"]) == ids("C", 12)

    for course <- plan["courses"], command <- course["commands"] do
      assert ["./scripts/mix", "test" | tests] = command
      assert tests != []
      assert Enum.all?(tests, &String.starts_with?(&1, "test/agent_systems_lab/"))
      assert Enum.all?(tests, &String.ends_with?(&1, "_test.exs"))
    end

    refute plan["release_ready"]
    assert plan["execution"] =~ "no commands executed"
    assert plan["week24_matrix"] == "pending"
    assert snapshot(c.source) == before
  end

  test "a fresh VM with database and scheduler enabled starts neither application nor effects",
       c do
    probe = """
    names = [AgentSystemsLab.Supervisor, AgentSystemsLab.Repo, AgentSystemsLab.Registry,
      AgentSystemsLab.RunSupervisor, AgentSystemsLab.ProviderSupervisor,
      AgentSystemsLab.Observability.Buffer]
    ensure_absent = fn ->
      if Enum.any?(names, &(Process.whereis(&1) != nil)), do: raise("application started")
      if Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_systems_lab)),
        do: raise("application loaded as started")
      if Enum.any?(Process.list(), fn pid ->
        case Process.info(pid, :initial_call) do
          {:initial_call, {AgentSystemsLab.Scheduler, _, _}} -> true
          _ -> false
        end
      end), do: raise("scheduler started")
    end
    ensure_absent.()
    [source] = System.argv()
    {:ok, checked} = AgentSystemsLab.ReleaseReadiness.check(source: source)
    {:ok, planned} = AgentSystemsLab.ReleaseReadiness.plan(source: source)
    false = checked["release_ready"]
    false = planned["release_ready"]
    ensure_absent.()
    IO.puts("SOURCE_METADATA_ONLY")
    """

    ebin = ReleaseReadiness |> :code.which() |> List.to_string() |> Path.dirname()

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", probe, c.source],
               env: [{"LAB_DATABASE_ENABLED", "true"}, {"LAB_SCHEDULER_ENABLED", "true"}],
               stderr_to_stdout: true
             )

    assert output =~ "SOURCE_METADATA_ONLY"
  end

  test "manifest unknown keys including a forged release gate are rejected", c do
    change_manifest(c, &Map.put(&1, "release_ready", true))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
  end

  test "self-consistent changed runtime pins are rejected", c do
    change_manifest(c, &put_in(&1, ["runtime_pins", "postgres"], "19.0"))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
  end

  test "project target and business schema cannot be promoted by editing the manifest", c do
    for {key, value} <- [
          {"project_version", "0.1.0"},
          {"target_version", "1.0.0"},
          {"schema_version", 2}
        ] do
      write_manifest(c, Map.put(c.manifest, key, value))
      assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
    end

    write_manifest(c, put_in(c.manifest, ["schema_versions", "kernel"], 2))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
  end

  test "missing duplicate reordered and unknown course identity are rejected", c do
    courses = c.manifest["courses"]

    for changed <- [
          tl(courses),
          [hd(courses) | courses],
          Enum.reverse(courses),
          [Map.put(hd(courses), "id", "C99") | tl(courses)]
        ] do
      write_manifest(c, Map.put(c.manifest, "courses", changed))
      assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
    end
  end

  test "course command substitution is data rejected before any invocation", c do
    sentinel = Path.join(c.base, "must-not-run")
    course = hd(c.manifest["courses"])
    injected = Map.put(course, "commands", [["sh", "-c", "touch " <> sentinel]])
    write_manifest(c, Map.put(c.manifest, "courses", [injected | tl(c.manifest["courses"])]))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.plan(source: c.source)
    refute File.exists?(sentinel)
  end

  test "manifest chapter title cannot be changed alongside the card", c do
    [card | rest] = c.manifest["chapters"]
    write_manifest(c, Map.put(c.manifest, "chapters", [Map.put(card, "title", "FORGED") | rest]))
    update(c, "book/chapter-cards.md", &String.replace(&1, card["title"], "FORGED"))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
  end

  test "pinned lock and bootstrap drift are refused", c do
    for path <- ["mix.lock", "scripts/bootstrap_runtime.sh", ".tool-versions"] do
      original = File.read!(Path.join(c.source, path))
      File.write!(Path.join(c.source, path), original <> "\n# drift\n")
      assert {:error, :release_pin_drift} = ReleaseReadiness.check(source: c.source)
      File.write!(Path.join(c.source, path), original)
    end
  end

  test "self-consistent changed file digest cannot re-pin the copied contract", c do
    [pin | rest] = c.manifest["pinned_files"]
    File.write!(Path.join(c.source, pin["path"]), "changed")
    changed = pin |> Map.put("bytes", 7) |> Map.put("sha256", digest("changed"))
    write_manifest(c, Map.put(c.manifest, "pinned_files", [changed | rest]))
    assert {:error, :release_contract_mismatch} = ReleaseReadiness.check(source: c.source)
  end

  test "script execution mode drift is refused even when every byte is unchanged", c do
    path = Path.join(c.source, "scripts/mix")
    original = File.read!(path)
    File.chmod!(path, 0o644)
    assert File.read!(path) == original
    assert {:error, :release_pin_drift} = ReleaseReadiness.check(source: c.source)
  end

  test "an extra migration is rejected instead of silently omitted", c do
    File.write!(
      Path.join(c.source, "priv/repo/migrations/99999999999999_unapproved.exs"),
      "# data"
    )

    assert {:error, :release_migration_inventory_mismatch} =
             ReleaseReadiness.check(source: c.source)
  end

  test "missing migration is refused", c do
    path = hd(c.manifest["migrations"])["path"]
    File.rm!(Path.join(c.source, path))

    assert {:error, {:release_unsafe_or_missing_file, ^path}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "changed migration content is refused", c do
    update(c, hd(c.manifest["migrations"])["path"], &(&1 <> "\n# drift"))
    assert {:error, :release_pin_drift} = ReleaseReadiness.check(source: c.source)
  end

  test "all manual and lab-solution and test entrypoints must exist", c do
    paths = [
      "docs/known-limitations.md",
      "labs/solutions/L22.md",
      "test/agent_systems_lab/kernel_test.exs"
    ]

    for path <- paths do
      original = File.read!(Path.join(c.source, path))
      File.rm!(Path.join(c.source, path))

      assert {:error, {:release_unsafe_or_missing_file, ^path}} =
               ReleaseReadiness.check(source: c.source)

      File.write!(Path.join(c.source, path), original)
    end
  end

  test "chapter missing duplicate reordered unknown markers are refused", c do
    path = "book/chapter-cards.md"
    original = File.read!(Path.join(c.source, path))

    for changed <- [
          String.replace(original, "<!-- chapter:ch01 -->", ""),
          original <> "\n<!-- chapter:ch01 -->",
          String.replace(original, "<!-- chapter:ch01 -->", "<!-- chapter:ch99 -->"),
          original
          |> String.replace("chapter:ch01", "chapter:TEMP")
          |> String.replace("chapter:ch02", "chapter:ch01")
          |> String.replace("chapter:TEMP", "chapter:ch02")
        ] do
      File.write!(Path.join(c.source, path), changed)
      assert {:error, :release_chapter_cards_invalid} = ReleaseReadiness.check(source: c.source)
    end
  end

  test "a missing card rubric or inflated draft status is rejected", c do
    path = "book/chapter-cards.md"
    original = File.read!(Path.join(c.source, path))

    File.write!(
      Path.join(c.source, path),
      String.replace(original, "教师参考：", "REMOVED", global: false)
    )

    assert {:error, :release_chapter_cards_invalid} = ReleaseReadiness.check(source: c.source)

    File.write!(
      Path.join(c.source, path),
      String.replace(original, "状态：design_card", "状态：draft", global: false)
    )

    assert {:error, :release_chapter_cards_invalid} = ReleaseReadiness.check(source: c.source)
  end

  test "course missing duplicate reordered unknown markers are refused", c do
    path = "docs/course-map.md"
    original = File.read!(Path.join(c.source, path))

    for changed <- [
          String.replace(original, "<!-- course:C01 -->", ""),
          original <> "\n<!-- course:C01 -->",
          String.replace(original, "<!-- course:C01 -->", "<!-- course:C99 -->"),
          original
          |> String.replace("course:C01", "course:TEMP")
          |> String.replace("course:C02", "course:C01")
          |> String.replace("course:TEMP", "course:C02")
        ] do
      File.write!(Path.join(c.source, path), changed)
      assert {:error, :release_courses_invalid} = ReleaseReadiness.check(source: c.source)
    end
  end

  test "a course without platform and success criteria is refused", c do
    update(c, "docs/course-map.md", &String.replace(&1, "平台要求：", "REMOVED", global: false))
    assert {:error, :release_courses_invalid} = ReleaseReadiness.check(source: c.source)
  end

  test "empty card and course fields do not count as complete entries", c do
    for {path, label, error} <- [
          {"book/chapter-cards.md", "目标：", :release_chapter_cards_invalid},
          {"docs/course-map.md", "学生任务：", :release_courses_invalid}
        ] do
      update(c, path, fn bytes ->
        Regex.replace(Regex.compile!(Regex.escape(label) <> "[^\\n]*"), bytes, label,
          global: false
        )
      end)

      assert {:error, ^error} = ReleaseReadiness.check(source: c.source)
      File.cp!(Path.join(@root, path), Path.join(c.source, path))
    end
  end

  test "questions need three through five matched teacher entries", c do
    update(c, "book/chapter-cards.md", fn bytes ->
      String.replace(bytes, "习题：① ", "习题：", global: false)
    end)

    assert {:error, :release_chapter_cards_invalid} = ReleaseReadiness.check(source: c.source)
  end

  test "broken card source link is refused even when labels remain", c do
    update(c, "book/chapter-cards.md", fn bytes ->
      String.replace(bytes, "../lib/agent_systems_lab/scenarios.ex", "../lib/missing.ex",
        global: false
      )
    end)

    assert {:error, {:release_invalid_local_link, "book/chapter-cards.md", "../lib/missing.ex"}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "a linked existing file outside the source tree or in artifacts cannot be read", c do
    document = "book/chapter-cards.md"
    original = File.read!(Path.join(c.source, document))
    File.write!(Path.join(c.base, "outside.md"), "must not count as source")
    File.mkdir_p!(Path.join(c.source, "artifacts"))
    File.write!(Path.join(c.source, "artifacts/opaque.md"), "must not count as source")

    for target <- ["../../outside.md", "../artifacts/opaque.md"] do
      File.write!(Path.join(c.source, document), original <> "\n[unsafe](" <> target <> ")\n")

      assert {:error, {:release_invalid_local_link, ^document, ^target}} =
               ReleaseReadiness.check(source: c.source)
    end
  end

  test "a safe source link cannot traverse a symlink", c do
    path = Path.join(c.source, "docs/linked-alias.md")
    File.ln_s!(Path.join(c.source, "docs/public-interfaces.md"), path)
    update(c, "book/chapter-cards.md", &(&1 <> "\n[alias](../docs/linked-alias.md)\n"))

    assert {:error,
            {:release_invalid_local_link, "book/chapter-cards.md", "../docs/linked-alias.md"}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "course actual fixed command cannot be removed while retaining the test label", c do
    course = hd(c.manifest["courses"])
    command = course["commands"] |> hd() |> Enum.join(" ")

    update(
      c,
      "docs/course-map.md",
      &String.replace(&1, command, "COMMAND_REMOVED", global: false)
    )

    assert {:error, :release_courses_invalid} = ReleaseReadiness.check(source: c.source)
  end

  test "course actual lab and solution links cannot be removed", c do
    course = hd(c.manifest["courses"])

    for target <- [hd(course["labs"]), hd(course["solutions"])] do
      update(c, "docs/course-map.md", &String.replace(&1, "../" <> target, "../README.md"))
      assert {:error, :release_courses_invalid} = ReleaseReadiness.check(source: c.source)
      File.cp!(Path.join(@root, "docs/course-map.md"), Path.join(c.source, "docs/course-map.md"))
    end
  end

  test "malformed JSON and non-object manifest are inert invalid data", c do
    for bytes <- ["{broken", "[]", "null", "\"data\""] do
      File.write!(Path.join(c.source, @manifest), bytes)
      assert {:error, _reason} = ReleaseReadiness.check(source: c.source)
    end
  end

  test "oversized manifest and source files fail within file bounds", c do
    File.write!(Path.join(c.source, @manifest), :binary.copy("x", 262_145))

    assert {:error, {:release_unsafe_or_missing_file, @manifest}} =
             ReleaseReadiness.check(source: c.source)

    write_manifest(c, c.manifest)
    path = "docs/known-limitations.md"
    File.write!(Path.join(c.source, path), :binary.copy("x", 2_097_153))

    assert {:error, {:release_unsafe_or_missing_file, ^path}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "source and manifest symlinks are refused", c do
    alias_path = Path.join(c.base, "alias")
    File.ln_s!(c.source, alias_path)
    assert {:error, :release_unsafe_source} = ReleaseReadiness.check(source: alias_path)
    path = Path.join(c.source, @manifest)
    File.rename!(path, path <> ".real")
    File.ln_s!(path <> ".real", path)

    assert {:error, {:release_unsafe_or_missing_file, @manifest}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "symlinked parent and hardlinked required files are refused", c do
    directory = Path.join(c.source, "docs")
    File.rename!(directory, directory <> ".real")
    File.ln_s!(directory <> ".real", directory)

    assert {:error, {:release_unsafe_or_missing_file, _path}} =
             ReleaseReadiness.check(source: c.source)

    File.rm!(directory)
    File.rename!(directory <> ".real", directory)
    path = Path.join(c.source, "mix.lock")
    File.ln!(path, Path.join(c.base, "hardlink"))

    assert {:error, {:release_unsafe_or_missing_file, "mix.lock"}} =
             ReleaseReadiness.check(source: c.source)
  end

  test "relative source and unsupported or duplicate options are rejected", c do
    assert {:error, :release_unsafe_source} = ReleaseReadiness.check(source: "relative")

    assert {:error, :release_invalid_options} =
             ReleaseReadiness.check(source: c.source, execute: true)

    assert {:error, :release_invalid_options} =
             ReleaseReadiness.check(source: c.source, source: c.source)

    assert {:error, :release_invalid_options} = ReleaseReadiness.check(%{})
    assert {:error, :release_invalid_options} = ReleaseReadiness.check([:source])
  end

  test "CLI refuses additional execution and output arguments before compiling" do
    for args <- [
          [],
          ["run"],
          ["check", "--source", "/private/tmp"],
          ["plan", "--execute"],
          ["check", "--output", "must-not-exist"]
        ] do
      assert_raise Mix.Error, ~r/Usage: mix lab.release/, fn ->
        Mix.Tasks.Lab.Release.run(args)
      end
    end
  end

  defp change_manifest(c, fun), do: write_manifest(c, fun.(c.manifest))

  defp write_manifest(c, manifest),
    do: File.write!(Path.join(c.source, @manifest), JSON.encode!(manifest))

  defp update(c, path, fun) do
    target = Path.join(c.source, path)
    File.write!(target, fun.(File.read!(target)))
  end

  defp snapshot(root) do
    Path.wildcard(Path.join(root, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, root), digest(File.read!(path))} end)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ids(prefix, count),
    do: Enum.map(1..count, &(prefix <> String.pad_leading(to_string(&1), 2, "0")))
end
