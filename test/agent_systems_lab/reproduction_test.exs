defmodule AgentSystemsLab.ReproductionTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Reproduction

  @license_files ~w(LICENSE LICENSE-DOCS NOTICE)
  @license_paths @license_files ++ ["docs/licensing.md"]
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
    "hex/packages/hexpm/telemetry-1.4.2.tar",
    "mix/archives/hex-2.5.3/hex-2.5.3/ebin/hex.app"
  ]

  setup do
    # Canonical parent avoids Darwin's /tmp -> /private/tmp symlink.
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "lab_reproduction_" <> Ecto.UUID.generate())
    source = Path.join(root, "source")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "scripts"))
    File.mkdir_p!(Path.join(source, "docs"))
    File.write!(Path.join(source, "mix.exs"), "# trusted test source\n")
    File.write!(Path.join(source, "mix.lock"), "%{}\n")
    File.write!(Path.join(source, ".tool-versions"), "erlang 28.4\nelixir 1.20.4-otp-28\n")

    for name <- @license_paths,
        do: File.write!(Path.join(source, name), "License fixture: #{name}\n")

    File.write!(Path.join(source, "lib/probe.ex"), "defmodule Probe, do: nil\n")
    File.write!(Path.join(source, "scripts/probe"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(source, "scripts/probe"), 0o751)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, source: source, output: Path.join(root, "clean")}
  end

  test "export copies only source and records exact bytes and executable modes", context do
    for ignored <- ~w(.runtime deps _build artifacts .git cover) do
      File.mkdir_p!(Path.join(context.source, ignored))
      File.write!(Path.join([context.source, ignored, "must-not-export"]), "old state")
    end

    File.write!(Path.join(context.source, ".env"), "PRIVATE=value")
    File.mkdir_p!(Path.join(context.source, "docs/empty"))
    assert {:ok, exported} = Reproduction.export(context.output, source: context.source)
    assert exported.output_dir == context.output

    assert exported.manifest_path ==
             Path.join(context.output, "reproduction-source-manifest.json")

    assert exported.manifest["file_count"] == 9
    assert exported.manifest["total_bytes"] > 0
    assert byte_size(exported.manifest["entries_sha256"]) == 64
    assert exported.manifest["kind"] == "agent-systems-lab.source-export.v1"
    assert File.dir?(Path.join(context.output, "docs/empty"))

    for name <- @license_files, do: assert(name in exported.manifest["includes"])

    for name <- @license_paths do
      assert File.read!(Path.join(context.output, name)) ==
               File.read!(Path.join(context.source, name))
    end

    assert Enum.find(exported.manifest["entries"], &(&1["path"] == "scripts/probe"))["mode"] ==
             0o751

    assert Bitwise.band(File.stat!(Path.join(context.output, "scripts/probe")).mode, 0o777) ==
             0o751

    assert Bitwise.band(File.stat!(exported.manifest_path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(context.output).mode, 0o777) == 0o700

    for ignored <- ~w(.runtime deps _build artifacts .git cover .env) do
      refute File.exists?(Path.join(context.output, ignored))
    end

    assert {:ok, ^exported} = Reproduction.verify(context.output)
  end

  test "export is deterministic across distinct output paths", context do
    assert {:ok, first} = Reproduction.export(context.output, source: context.source)

    assert {:ok, second} =
             Reproduction.export(context.output <> "-another", source: context.source)

    assert first.manifest == second.manifest
  end

  test "new exports refuse any missing license declaration before creating output", context do
    for name <- @license_paths do
      path = Path.join(context.source, name)
      original = File.read!(path)
      File.rm!(path)

      assert {:error, :reproduction_required_source_missing} =
               Reproduction.export(context.output, source: context.source)

      refute File.exists?(context.output)
      File.write!(path, original)
    end
  end

  test "license declaration byte drift is rejected", context do
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)

    for name <- @license_paths do
      path = Path.join(context.output, name)
      original = File.read!(path)
      File.write!(path, original <> "changed\n")
      assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
      File.write!(path, original)
    end

    assert {:ok, _} = Reproduction.verify(context.output)
  end

  test "the exact historical export contract remains verifiable without rewriting it", context do
    assert {:ok, exported} = Reproduction.export(context.output, source: context.source)
    for name <- @license_paths, do: File.rm!(Path.join(context.output, name))
    entries = Enum.reject(exported.manifest["entries"], &(&1["path"] in @license_paths))

    manifest =
      exported.manifest
      |> Map.put(
        "includes",
        exported.manifest["includes"] -- (@license_files ++ [".gitattributes"])
      )
      |> Map.put("entries", entries)
      |> Map.put("file_count", Enum.count(entries, &(&1["type"] == "file")))
      |> Map.put("total_bytes", Enum.reduce(entries, 0, &(&2 + Map.get(&1, "bytes", 0))))
      |> Map.put("entries_sha256", inventory_hash(entries))

    original = JSON.encode!(manifest) <> "\n"
    File.write!(exported.manifest_path, original)
    assert {:ok, verified} = Reproduction.verify(context.output)
    assert verified.manifest == manifest
    assert File.read!(exported.manifest_path) == original

    copied_output = context.output <> "-repacked"
    assert {:ok, copied} = Reproduction.export(copied_output, source: context.output)
    assert copied.manifest == manifest
    assert {:ok, _} = Reproduction.verify(copied_output)
    for name <- @license_paths, do: refute(File.exists?(Path.join(copied_output, name)))
    assert File.read!(exported.manifest_path) == original

    File.write!(Path.join(context.output, "lib/probe.ex"), "changed frozen source")

    assert {:error, :reproduction_manifest_mismatch} =
             Reproduction.export(context.output <> "-tampered", source: context.output)

    refute File.exists?(context.output <> "-tampered")

    for includes <- [
          manifest["includes"] ++ ["private"],
          exported.manifest["includes"] -- ["NOTICE"]
        ] do
      File.write!(exported.manifest_path, JSON.encode!(Map.put(manifest, "includes", includes)))
      assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
    end
  end

  test "existing destination is refused without overwriting a byte", context do
    File.mkdir!(context.output)
    sentinel = Path.join(context.output, "keep")
    File.write!(sentinel, "keep this")

    assert {:error, :reproduction_output_exists} =
             Reproduction.export(context.output, source: context.source)

    assert File.read!(sentinel) == "keep this"
  end

  test "relative, missing parent, symlink parent and recursive destinations are refused",
       context do
    assert {:error, :reproduction_invalid_destination} =
             Reproduction.export("relative", source: context.source)

    assert {:error, :reproduction_unsafe_directory} =
             Reproduction.export(Path.join(context.root, "missing/clean"), source: context.source)

    link = Path.join(context.root, "parent-link")
    File.ln_s!(context.root, link)

    assert {:error, :reproduction_unsafe_directory} =
             Reproduction.export(Path.join(link, "clean"), source: context.source)

    assert {:error, :reproduction_invalid_destination} =
             Reproduction.export(Path.join(context.source, "lib/clean"), source: context.source)

    refute File.exists?(context.output)
  end

  test "selected symlink and hardlink source entries fail closed before creating output",
       context do
    target = Path.join(context.source, "lib/probe.ex")
    link = Path.join(context.source, "lib/alias.ex")
    File.ln_s!(target, link)

    assert {:error, :reproduction_unsafe_source_entry} =
             Reproduction.export(context.output, source: context.source)

    refute File.exists?(context.output)
    File.rm!(link)
    File.ln!(target, link)

    assert {:error, :reproduction_unsafe_source_entry} =
             Reproduction.export(context.output, source: context.source)

    refute File.exists?(context.output)
  end

  test "case aliases into selected source directories are rejected before any source write",
       context do
    assert {:ok, baseline} = Reproduction.export(context.output, source: context.source)
    alias_parent = Path.join(context.source, "LIB")
    attempted = Path.join(alias_parent, "case-alias-export")
    original_parent = Path.join(context.source, "lib")

    if same_directory?(alias_parent, original_parent) do
      # This branch runs on the default case-insensitive macOS volume. The old
      # lexical check created source/lib/case-alias-export before detecting drift.
      assert {:error, :reproduction_invalid_destination} =
               Reproduction.export(attempted, source: context.source)
    else
      assert {:error, :reproduction_unsafe_directory} =
               Reproduction.export(attempted, source: context.source)
    end

    refute File.exists?(Path.join(original_parent, "case-alias-export"))

    assert {:ok, after_refusal} =
             Reproduction.export(context.output <> "-after", source: context.source)

    assert after_refusal.manifest == baseline.manifest
  end

  test "Unicode aliases of the source root cannot create an export inside selected source",
       context do
    composed = Path.join(context.root, "sourc\u00e9")
    decomposed = Path.join(context.root, "source\u0301")
    File.rename!(context.source, composed)
    File.mkdir_p!(Path.join(composed, "lib/nested"))
    assert {:ok, baseline} = Reproduction.export(context.output, source: composed)
    attempted = Path.join(decomposed, "lib/nested/unicode-alias-export")

    if same_directory?(composed, decomposed) do
      # The spelling of the entire source root differs, so string-prefix checks
      # miss both the top-level lib and its nested selected source directories.
      assert {:error, :reproduction_invalid_destination} =
               Reproduction.export(attempted, source: composed)
    else
      assert {:error, :reproduction_unsafe_directory} =
               Reproduction.export(attempted, source: composed)
    end

    refute File.exists?(Path.join(composed, "lib/nested/unicode-alias-export"))

    assert {:ok, after_refusal} =
             Reproduction.export(context.output <> "-after", source: composed)

    assert after_refusal.manifest == baseline.manifest
  end

  test "oversized, control-character and privileged-mode entries are refused", context do
    big = Path.join(context.source, "lib/oversized.ex")
    File.write!(big, :binary.copy("x", 2_097_153))

    assert {:error, :reproduction_unsafe_source_entry} =
             Reproduction.export(context.output, source: context.source)

    File.rm!(big)
    odd = Path.join(context.source, "lib/odd\nname.ex")
    File.write!(odd, "nil")

    assert {:error, :reproduction_source_limit_or_path} =
             Reproduction.export(context.output, source: context.source)

    File.rm!(odd)
    File.chmod!(Path.join(context.source, "lib/probe.ex"), 0o4644)

    assert {:error, :reproduction_unsafe_source_entry} =
             Reproduction.export(context.output, source: context.source)

    refute File.exists?(context.output)
  end

  test "missing required lock or runtime pins and unknown options are refused", context do
    File.rm!(Path.join(context.source, "mix.lock"))

    assert {:error, :reproduction_required_source_missing} =
             Reproduction.export(context.output, source: context.source)

    assert {:error, :reproduction_invalid_options} =
             Reproduction.export(context.output, source: context.source, command: "anything")

    assert {:error, :reproduction_invalid_options} =
             Reproduction.export(context.output, source: context.source, source: context.source)

    refute File.exists?(context.output)
  end

  test "verification detects byte, mode, added and deleted source drift", context do
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)
    file = Path.join(context.output, "lib/probe.ex")
    original = File.read!(file)
    original_mode = Bitwise.band(File.stat!(file).mode, 0o777)
    File.write!(file, "changed")
    assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
    File.write!(file, original)
    File.chmod!(file, Bitwise.bxor(original_mode, 0o100))
    assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)

    File.chmod!(file, original_mode)

    assert {:ok, _} = Reproduction.verify(context.output)
    extra = Path.join(context.output, "lib/extra.ex")
    File.write!(extra, "nil")
    assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
    File.rm!(extra)
    File.rm!(file)
    assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
  end

  test "build output does not change source verification, while a future manifest is rejected",
       context do
    assert {:ok, exported} = Reproduction.export(context.output, source: context.source)

    for extra <- ~w(.runtime deps _build artifacts) do
      File.mkdir!(Path.join(context.output, extra))
      File.write!(Path.join([context.output, extra, "new"]), "new generated output")
    end

    assert {:ok, _} = Reproduction.verify(context.output)
    manifest = Map.put(exported.manifest, "schema_version", 99)
    File.write!(exported.manifest_path, JSON.encode!(manifest))
    assert {:error, :reproduction_manifest_mismatch} = Reproduction.verify(context.output)
  end

  test "symlink, oversized and malformed manifests are refused", context do
    assert {:ok, exported} = Reproduction.export(context.output, source: context.source)
    File.write!(exported.manifest_path, "{broken")
    assert {:error, _} = Reproduction.verify(context.output)
    File.write!(exported.manifest_path, :binary.copy("x", 4_194_305))
    assert {:error, :reproduction_manifest_invalid} = Reproduction.verify(context.output)
    File.rm!(exported.manifest_path)
    File.ln_s!(Path.join(context.source, "mix.exs"), exported.manifest_path)
    assert {:error, :reproduction_manifest_invalid} = Reproduction.verify(context.output)
  end

  test "plan is fixed data, isolates build and connection settings, and starts no application",
       context do
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)
    assert {:ok, plan} = Reproduction.plan(context.output, port: 55473)
    assert plan["working_directory"] == context.output
    environment = plan["environment"]
    assert environment["PGPORT"] == "55473"
    assert environment["PGHOST"] == "127.0.0.1"
    assert environment["DATABASE_URL"] == nil
    # libpq does not interpret PGSERVICE="" as an unset variable. Preserve
    # explicit nil instructions so the caller removes inherited route settings.
    for key <- ~w(PGSERVICE PGSERVICEFILE PGHOSTADDR PGDATABASE PGOPTIONS) do
      assert Map.has_key?(environment, key)
      assert environment[key] == nil
    end

    assert environment["PGUSER"] == "postgres"
    assert environment["PGPASSWORD"] == ""
    assert environment["PGPASSFILE"] == "/dev/null"
    assert environment["MIX_BUILD_PATH"] == nil
    assert environment["MIX_EXS"] == nil
    assert environment["ERL_LIBS"] == nil
    assert environment["LAB_SCHEDULER_ENABLED"] == "false"
    assert environment["HEX_OFFLINE"] == "1"
    assert environment["MIX_DEPS_PATH"] == Path.join(context.output, "deps")
    assert environment["MIX_BUILD_ROOT"] == Path.join(context.output, "_build")
    assert environment["MIX_HOME"] == Path.join(context.output, ".runtime/mix")

    assert environment["MIX_REBAR3"] ==
             Path.join(context.output, ".runtime/mix/elixir/1-20-otp-28/rebar3")

    assert environment["REBAR_CACHE_DIR"] == Path.join(context.output, ".runtime/rebar/cache")

    assert environment["REBAR_GLOBAL_CONFIG_DIR"] ==
             Path.join(context.output, ".runtime/rebar/config")

    assert environment["HEX_HOME"] == Path.join(context.output, ".runtime/hex")
    assert Enum.find(plan["commands"], &(&1["id"] == "full_check"))["args"] == ["check"]
    assert environment["MIX_ENV"] == "test"

    for id <- ~w(verify p1 history recover fence upgrade) do
      assert Enum.any?(plan["commands"], &(&1["id"] == id))
    end

    assert Enum.find(plan["commands"], &(&1["id"] == "fence"))["args"] == [
             "lab.fence",
             "--output",
             "artifacts/reproduction-fence",
             "--repetitions",
             "1"
           ]

    memory = Enum.find(plan["commands"], &(&1["id"] == "memory_check"))
    assert memory["environment"]["LAB_DATABASE_ENABLED"] == "false"

    for port <- [55432, 0, 65_536, "55473"] do
      assert {:error, :reproduction_invalid_port} = Reproduction.plan(context.output, port: port)
    end

    assert {:error, :reproduction_invalid_options} =
             Reproduction.plan(context.output, command: "anything")

    refute File.exists?(Path.join(context.output, ".runtime"))
    refute File.exists?(Path.join(context.output, "deps"))
    refute File.exists?(Path.join(context.output, "_build"))
  end

  test "cache staging records only pinned warm inputs and never installed state", context do
    seed_caches(context.source)

    for omitted <- ~w(otp/28.4/bin/erl postgres/18.6/bin/postgres pgdata/PG_VERSION) do
      path = Path.join([context.source, ".runtime", omitted])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "must not copy installed state")
    end

    assert {:ok, _} = Reproduction.export(context.output, source: context.source)
    assert {:ok, staged} = Reproduction.stage_cache(context.output, source: context.source)
    assert staged.runtime_dir == Path.join(context.output, ".runtime")
    assert staged.manifest["kind"] == "agent-systems-lab.warm-cache.v1"
    assert staged.manifest["scope"] =~ "not a fresh-machine"
    assert staged.manifest["trust"] =~ "not authentication"
    assert Enum.any?(staged.manifest["build_tools"], &String.starts_with?(&1, "Rebar3"))
    assert staged.manifest["total_bytes"] > 0
    assert byte_size(staged.manifest["entries_sha256"]) == 64

    for item <- @cache_files do
      assert File.read!(Path.join([context.output, ".runtime", item])) == "cache #{item}\n"
    end

    rebar = Path.join(staged.runtime_dir, "mix/elixir/1-20-otp-28/rebar3")
    assert Bitwise.band(File.stat!(rebar).mode, 0o777) == 0o755

    for omitted <- ~w(otp postgres pgdata) do
      refute File.exists?(Path.join(staged.runtime_dir, omitted))
    end

    assert {:ok, _} = Reproduction.verify(context.output)

    assert {:error, :reproduction_output_exists} =
             Reproduction.stage_cache(context.output, source: context.source)
  end

  test "missing or unsafe caches fail before creating runtime or touching source", context do
    seed_caches(context.source)
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)
    missing = Path.join([context.source, ".runtime", hd(@cache_files)])
    File.rm!(missing)

    assert {:error, :reproduction_cache_incomplete_or_changed} =
             Reproduction.stage_cache(context.output, source: context.source)

    refute File.exists?(Path.join(context.output, ".runtime"))
    File.ln_s!(Path.join(context.source, "mix.exs"), missing)

    assert {:error, :reproduction_unsafe_source_entry} =
             Reproduction.stage_cache(context.output, source: context.source)

    refute File.exists?(Path.join(context.output, ".runtime"))
  end

  test "a cache archive reached through a symlinked ancestor is rejected", context do
    seed_caches(context.source)
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)
    downloads = Path.join(context.source, ".runtime/downloads")
    moved = Path.join(context.root, "external-downloads")
    File.rename!(downloads, moved)
    File.ln_s!(moved, downloads)

    assert {:error, :reproduction_unsafe_directory} =
             Reproduction.stage_cache(context.output, source: context.source)

    refute File.exists?(Path.join(context.output, ".runtime"))
  end

  test "missing Rebar3 is rejected before copying a cache that cannot compile locked telemetry",
       context do
    seed_caches(context.source)
    File.rm!(Path.join(context.source, ".runtime/mix/elixir/1-20-otp-28/rebar3"))
    assert {:ok, _} = Reproduction.export(context.output, source: context.source)

    assert {:error, :reproduction_cache_incomplete_or_changed} =
             Reproduction.stage_cache(context.output, source: context.source)

    refute File.exists?(Path.join(context.output, ".runtime"))
  end

  defp seed_caches(source) do
    for item <- @cache_files do
      path = Path.join([source, ".runtime", item])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "cache #{item}\n")
      if String.ends_with?(item, "/rebar3"), do: File.chmod!(path, 0o755)
    end
  end

  defp inventory_hash(entries) do
    entries
    |> Enum.map_join("\n", fn entry ->
      Enum.join(
        [
          entry["path"],
          entry["type"],
          entry["mode"],
          Map.get(entry, "bytes", 0),
          Map.get(entry, "sha256", "")
        ],
        <<0>>
      )
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp same_directory?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, a}, {:ok, b}} ->
        {a.major_device, a.minor_device, a.inode} == {b.major_device, b.minor_device, b.inode}

      _ ->
        false
    end
  end
end
