defmodule AgentSystemsLab.Approvals.ArtifactTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Context
  alias AgentSystemsLab.Approvals.Artifact
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.Workspace

  setup do
    temporary = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "lab-review-artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "captures canonical immutable bytes and content hashes independent of selection order",
       c do
    File.write!(Path.join(c.root, "b.txt"), "second\n")
    File.write!(Path.join(c.root, "a.txt"), "first 中文\n")
    {:ok, workspace} = Workspace.new(c.root)
    assert {:ok, spec} = Artifact.new(workspace, ["b.txt", "a.txt"])
    assert spec.files == ["a.txt", "b.txt"]
    assert {:ok, snapshot} = Artifact.capture(spec)
    assert snapshot.files |> Enum.map(& &1.path) == ["a.txt", "b.txt"]
    assert hd(snapshot.files).content == "first 中文\n"
    assert hd(snapshot.files).sha256 == Workspace.sha256("first 中文\n")
    assert hd(snapshot.files).bytes == byte_size("first 中文\n")
    assert :ok = Artifact.validate_snapshot(snapshot)
    assert :ok = Artifact.matches_spec(spec, snapshot)
    assert :ok = Artifact.current?(spec, snapshot)
    assert {:ok, same_spec} = Artifact.new(c.root, ["a.txt", "b.txt"])
    assert same_spec == spec
    assert {:ok, ^snapshot} = Artifact.capture(same_spec)
    assert {:ok, bytes} = Codec.encode(snapshot)
    assert {:ok, ^snapshot} = Codec.decode(bytes)
    File.write!(Path.join(c.root, "a.txt"), "replacement")
    assert hd(snapshot.files).content == "first 中文\n"
    assert {:error, {:artifact_changed, old_hash, new_hash}} = Artifact.current?(spec, snapshot)
    assert old_hash == snapshot.hash
    refute old_hash == new_hash
  end

  test "protected baseline and initial output version have different lifetimes", c do
    source = "before\n"
    File.write!(Path.join(c.root, "source.txt"), source)

    assert {:ok, spec} =
             Artifact.new(c.root, ["patch.diff"],
               baselines: %{"source.txt" => Workspace.sha256(source)},
               initial: %{"patch.diff" => "absent"}
             )

    assert :ok = Artifact.check_baselines(spec)
    assert {:error, {:artifact_missing, "patch.diff"}} = Artifact.capture(spec)
    File.write!(Path.join(c.root, "patch.diff"), "reviewed patch")
    assert {:ok, snapshot} = Artifact.capture(spec)
    assert snapshot.baselines == spec.baselines
    assert snapshot.initial == spec.initial
    assert :ok = Artifact.current?(spec, snapshot)

    assert {:error, {:artifact_baseline_conflict, "patch.diff", "absent", _}} =
             Artifact.check_baselines(spec)

    File.write!(Path.join(c.root, "source.txt"), "external source change\n")

    assert {:error, {:artifact_baseline_conflict, "source.txt", expected, observed}} =
             Artifact.current?(spec, snapshot)

    assert expected == Workspace.sha256(source)
    assert observed == Workspace.sha256("external source change\n")

    assert {:error, {:artifact_baseline_conflict, "source.txt", ^expected, ^observed}} =
             Artifact.capture(spec)
  end

  test "missing and newly created protected sources cause explicit baseline conflicts", c do
    assert {:ok, spec} =
             Artifact.new(c.root, ["out.txt"],
               baselines: %{"source.txt" => Workspace.sha256("base")}
             )

    assert {:error, {:artifact_baseline_conflict, "source.txt", _, "absent"}} =
             Artifact.check_baselines(spec)

    assert {:ok, absent} =
             Artifact.new(c.root, ["out.txt"], baselines: %{"future.txt" => "absent"})

    assert :ok = Artifact.check_baselines(absent)
    File.write!(Path.join(c.root, "future.txt"), "created elsewhere")

    assert {:error, {:artifact_baseline_conflict, "future.txt", "absent", _}} =
             Artifact.check_baselines(absent)
  end

  test "empty output is a real immutable artifact and missing output never means empty", c do
    File.write!(Path.join(c.root, "empty.txt"), "")
    assert {:ok, spec} = Artifact.new(c.root, ["empty.txt"])
    assert {:ok, snapshot} = Artifact.capture(spec)
    assert hd(snapshot.files).bytes == 0
    assert hd(snapshot.files).content == ""
    File.rm!(Path.join(c.root, "empty.txt"))
    assert {:error, {:artifact_missing, "empty.txt"}} = Artifact.current?(spec, snapshot)
    assert :ok = Artifact.validate_snapshot(snapshot)
  end

  test "inert persisted specs and snapshots remain readable after workspace removal", c do
    File.write!(Path.join(c.root, "out.txt"), "recorded")
    assert {:ok, spec} = Artifact.new(c.root, ["out.txt"])
    assert {:ok, snapshot} = Artifact.capture(spec)
    File.rm_rf!(c.root)
    assert {:ok, ^spec} = Artifact.from_map(Artifact.to_map(spec))
    assert :ok = Artifact.validate_snapshot(snapshot)
    assert :ok = Artifact.matches_spec(spec, snapshot)
    assert {:error, {:filesystem, :enoent}} = Artifact.capture(spec)
  end

  test "named outputs cannot expand a reviewed selection or replace protected sources", c do
    for path <- [
          "../outside",
          "/etc/passwd",
          "a/../b",
          "a//b",
          ".git/config",
          ".AWS/key",
          "a\\b",
          "x\n"
        ] do
      assert {:error, _} = Artifact.new(c.root, [path])
    end

    assert {:error, :artifact_output_baseline_overlap} =
             Artifact.new(c.root, ["source.txt"], baselines: %{"source.txt" => "absent"})

    assert {:error, :artifact_output_baseline_overlap} =
             Artifact.new(c.root, ["Source.txt"], baselines: %{"source.txt" => "absent"})

    assert {:error, :invalid_artifact_initial} =
             Artifact.new(c.root, ["out.txt"], initial: %{"outside.txt" => "absent"})

    assert {:error, :duplicate_artifact_path} = Artifact.new(c.root, ["Source.txt", "ſource.txt"])
  end

  test "symbolic links, hard links and linked ancestors are refused", c do
    File.write!(Path.join(c.root, "real.txt"), "private")
    File.ln_s!("real.txt", Path.join(c.root, "symbolic.txt"))
    File.ln!(Path.join(c.root, "real.txt"), Path.join(c.root, "hard.txt"))
    assert {:ok, symbolic} = Artifact.new(c.root, ["symbolic.txt"])
    assert {:error, :symlink_not_allowed} = Artifact.capture(symbolic)
    assert {:ok, hard} = Artifact.new(c.root, ["hard.txt"])
    assert {:error, :hardlink_not_allowed} = Artifact.capture(hard)
    File.mkdir!(Path.join(c.root, "real-dir"))
    File.write!(Path.join(c.root, "real-dir/out.txt"), "inside")
    File.ln_s!("real-dir", Path.join(c.root, "linked-dir"))
    assert {:ok, nested} = Artifact.new(c.root, ["linked-dir/out.txt"])
    assert {:error, :symlink_not_allowed} = Artifact.capture(nested)

    link_root = c.root <> "-link"
    File.ln_s!(c.root, link_root)
    on_exit(fn -> File.rm(link_root) end)
    assert {:error, :symlink_not_allowed} = Artifact.new(link_root, ["real.txt"])
  end

  test "directory entry spelling is exact even on a case-insensitive filesystem", c do
    File.write!(Path.join(c.root, "output.txt"), "result")
    assert {:ok, spec} = Artifact.new(c.root, ["OUTPUT.txt"])

    if File.exists?(Path.join(c.root, "OUTPUT.txt")) do
      assert {:error, :non_canonical_path} = Artifact.capture(spec)
    else
      assert {:error, {:artifact_missing, "OUTPUT.txt"}} = Artifact.capture(spec)
    end
  end

  test "file and aggregate bytes are bounded and binary content is refused", c do
    File.write!(Path.join(c.root, "a.txt"), "12345")
    File.write!(Path.join(c.root, "b.txt"), "67890")
    assert {:ok, small} = Artifact.new(c.root, ["a.txt"], max_file_bytes: 4)
    assert {:error, :file_too_large} = Artifact.capture(small)
    assert {:ok, aggregate} = Artifact.new(c.root, ["a.txt", "b.txt"], max_total_bytes: 9)
    assert {:error, :artifact_total_bytes_exceeded} = Artifact.capture(aggregate)
    File.write!(Path.join(c.root, "a.txt"), <<255>>)
    assert {:ok, spec} = Artifact.new(c.root, ["a.txt"])
    assert {:error, :invalid_utf8} = Artifact.capture(spec)
    File.write!(Path.join(c.root, "a.txt"), <<0>>)
    assert {:error, :nul_in_text} = Artifact.capture(spec)
  end

  test "malformed options, versions, baselines and unbounded selections fail closed", c do
    for files <- [[], Enum.map(1..17, &"f#{&1}"), nil] do
      assert {:error, :invalid_artifact_files} = Artifact.new(c.root, files)
    end

    for opts <- [[dynamic_paths: true], [max_file_bytes: 1, max_file_bytes: 2], %{}] do
      assert {:error, :invalid_artifact_options} = Artifact.new(c.root, ["out"], opts)
    end

    for opts <- [
          [max_file_bytes: 0],
          [max_file_bytes: 65_537],
          [max_total_bytes: 0],
          [max_total_bytes: 1_048_577]
        ] do
      assert {:error, :invalid_artifact_limits} = Artifact.new(c.root, ["out"], opts)
    end

    assert {:error, :invalid_expected_sha256} =
             Artifact.new(c.root, ["out"], baselines: %{"source" => "*"})

    assert {:error, :invalid_artifact_root} = Artifact.new("/", ["out"])
    assert {:ok, spec} = Artifact.new(c.root, ["out"])
    map = Artifact.to_map(spec)
    assert {:error, :unsupported_artifact_version} = Artifact.from_map(%{map | schema_version: 2})
    assert {:error, :invalid_artifact_spec} = Artifact.from_map(Map.put(map, :grant, true))
  end

  test "snapshot validation catches bytes, digest, selection and hash tampering", c do
    File.write!(Path.join(c.root, "out.txt"), "approved")
    assert {:ok, spec} = Artifact.new(c.root, ["out.txt"])
    assert {:ok, snapshot} = Artifact.capture(spec)
    [entry] = snapshot.files

    for changed <- [
          %{snapshot | files: [%{entry | content: "altered"}]},
          %{snapshot | files: [%{entry | bytes: 9}]},
          %{snapshot | files: [%{entry | sha256: Workspace.sha256("other")}]},
          %{snapshot | hash: Workspace.sha256("other")},
          Map.put(snapshot, :approved, true),
          %{snapshot | schema_version: 2}
        ] do
      assert {:error, _} = Artifact.validate_snapshot(changed)
    end

    rebound = %{snapshot | files: [%{entry | path: "other.txt"}]}
    rebound = %{rebound | hash: Context.hash(Map.delete(rebound, :hash))}
    assert :ok = Artifact.validate_snapshot(rebound)
    assert {:error, :artifact_spec_mismatch} = Artifact.matches_spec(spec, rebound)
    assert {:error, :artifact_spec_mismatch} = Artifact.current?(spec, rebound)
  end
end
