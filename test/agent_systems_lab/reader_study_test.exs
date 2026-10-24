defmodule AgentSystemsLab.ReaderStudyTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{ReaderStudy, Reproduction}
  alias AgentSystemsLab.Evaluation.Report

  # These are synthetic protocol fixtures, never actual reader attestations.
  # Every temporary packet and accepted test record is deleted on exit.
  @chapters ~w(ch02 ch05 ch08 ch14 ch16 ch20)
  @commands ~w(verify p1 history recover fence upgrade)

  setup_all do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "lab_reader_study_" <> Ecto.UUID.generate())
    File.mkdir!(root)
    pristine = Path.join(root, "packet")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, prepared} = ReaderStudy.prepare(pristine)
    %{root: root, pristine: pristine, prepared: prepared, protocol: prepared.protocol}
  end

  setup context do
    root = Path.join(context.root, "case-" <> Ecto.UUID.generate())
    File.mkdir!(root)
    %{case_root: root}
  end

  test "packet freezes six real chapters and a source-only export, with zero human credit",
       context do
    protocol = context.protocol
    study = context.pristine
    assert {:ok, ^protocol} = ReaderStudy.load(study)
    assert {:ok, exported} = Reproduction.verify(Path.join(study, "project"))
    assert protocol["source_manifest_sha256"] == digest(File.read!(exported.manifest_path))
    assert Enum.map(protocol["suite"]["chapters"], & &1["id"]) == @chapters
    assert protocol["suite"]["command_ids"] == @commands

    for chapter <- protocol["suite"]["chapters"], path <- [chapter["path"] | chapter["labs"]] do
      bytes = File.read!(Path.join([study, "project", path]))
      assert protocol["assets"][path]["sha256"] == digest(bytes)
      assert protocol["assets"][path]["bytes"] == byte_size(bytes)
    end

    for ignored <- ~w(.runtime deps _build artifacts .git) do
      refute File.exists?(Path.join([study, "project", ignored]))
    end

    assert File.ls!(Path.join(study, "feedback")) == []
    template = read_json(Path.join(study, "feedback-template.json"))
    assert template == ReaderStudy.template(protocol)
    assert {:error, :invalid_reader_feedback} = ReaderStudy.validate_feedback(template, protocol)
    report = read_json(Path.join(study, "report.json"))
    assert report["external_reader_count"] == 0
    assert report["external_reader_status"] == "pending"
    assert report["technical_status"] == "pending"
    refute report["p5_external_gate_met"]
    assert Report.hash(Map.delete(report, "report_hash")) == report["report_hash"]
    assert Bitwise.band(File.stat!(Path.join(study, "protocol.json")).mode, 0o777) == 0o600
  end

  test "existing study and adjacent evidence are preserved byte for byte", context do
    study = Path.join(context.case_root, "existing")
    File.mkdir!(study)
    sentinel = Path.join(study, "old-evidence.bin")
    prior = Path.join(context.case_root, "prior-report.json")
    File.write!(sentinel, <<0, 1, 255, 2>>)
    File.write!(prior, "previous evidence\n")
    assert {:error, {:output_exists, ^study}} = ReaderStudy.prepare(study)
    assert File.read!(sentinel) == <<0, 1, 255, 2>>
    assert File.read!(prior) == "previous evidence\n"
    refute File.exists?(Path.join(study, "project"))
    assert {:error, :invalid_reading_path} = ReaderStudy.prepare("relative-reader-packet")
  end

  test "first feedback is saved privately and duplicate ID cannot overwrite evidence", context do
    study = copy_packet(context)
    path = feedback_file(context, feedback(context.protocol, "R01"))

    assert {:ok, %{"reader_id" => "R01", "saved" => true}} =
             ReaderStudy.add_feedback(study, path)

    saved = Path.join(study, "feedback/R01.json")
    bytes = File.read!(saved)
    assert Bitwise.band(File.stat!(saved).mode, 0o777) == 0o600
    assert {:error, :duplicate_reader} = ReaderStudy.add_feedback(study, path)
    assert File.read!(saved) == bytes
    assert {:ok, report} = ReaderStudy.report(study)
    assert report["external_reader_count"] == 1
    assert report["external_fresh_reproductions"] == 0
    refute report["p5_external_gate_met"]
  end

  test "agents, authors, templates, partial reading and unknown fields are rejected", context do
    base = feedback(context.protocol, "R01")

    invalid = [
      ReaderStudy.template(context.protocol),
      Map.put(base, "reader_type", "agent"),
      Map.put(base, "reader_type", "automated"),
      Map.put(base, "independent_of_authors", false),
      Map.put(base, "completed", false),
      Map.put(base, "chapters", Enum.take(@chapters, 5)),
      Map.put(base, "chapters", Enum.reverse(@chapters)),
      Map.put(base, "extra", "cannot silently accept this"),
      put_in(base, ["reproduction", "extra"], true),
      Map.put(base, "schema_version", 2),
      Map.put(base, "reader_id", "../R01"),
      Map.put(base, "protocol_hash", String.duplicate("0", 64)),
      Map.put(base, "finished_at_utc", "2026-10-23T00:00:00Z"),
      Map.put(base, "started_at_utc", "not-a-timestamp")
    ]

    study = copy_packet(context)

    for record <- invalid do
      assert {:error, :invalid_reader_feedback} =
               ReaderStudy.validate_feedback(record, context.protocol)

      assert {:error, :invalid_reader_feedback} =
               ReaderStudy.add_feedback(study, feedback_file(context, record))
    end

    assert File.ls!(Path.join(study, "feedback")) == []
  end

  test "passed reproduction requires every fixed command exactly once with successful evidence",
       context do
    record = feedback(context.protocol, "R01", fresh: true)
    assert :ok = ReaderStudy.validate_feedback(record, context.protocol)
    commands = record["reproduction"]["commands"]

    invalid = [
      put_in(record, ["reproduction", "commands"], []),
      put_in(record, ["reproduction", "commands"], tl(commands)),
      put_in(record, ["reproduction", "commands"], [hd(commands) | commands]),
      put_in(record, ["reproduction", "commands", Access.at(0), "outcome"], "failed"),
      put_in(record, ["reproduction", "commands", Access.at(0), "evidence"], ""),
      put_in(record, ["reproduction", "commands", Access.at(0), "id"], "arbitrary-shell"),
      put_in(record, ["reproduction", "commands", Access.at(0), "command"], "execute me"),
      put_in(record, ["reproduction", "environment"], "none")
    ]

    for changed <- invalid do
      assert {:error, :invalid_reader_feedback} =
               ReaderStudy.validate_feedback(changed, context.protocol)
    end
  end

  test "technical evidence cannot substitute for three external humans or a fresh reproduction",
       context do
    protocol = context.protocol
    technical = technical()
    assert {:ok, report} = ReaderStudy.assess(protocol, [], technical)
    assert report["technical_status"] == "passed"
    assert report["external_reader_count"] == 0
    refute report["p5_external_gate_met"]
    records = Enum.map(1..3, &feedback(protocol, reader_id(&1)))
    assert {:ok, report} = ReaderStudy.assess(protocol, records, technical)
    assert report["external_reader_count"] == 3
    assert report["external_fresh_reproductions"] == 0
    assert report["external_reader_status"] == "pending"
    refute report["p5_external_gate_met"]
    records = List.replace_at(records, 0, feedback(protocol, "R01", fresh: true))
    assert {:ok, report} = ReaderStudy.assess(protocol, Enum.take(records, 2), technical)
    refute report["p5_external_gate_met"]
    assert {:ok, report} = ReaderStudy.assess(protocol, records, nil)
    assert report["external_reader_status"] == "passed_self_reported"
    assert report["technical_status"] == "pending"
    refute report["p5_external_gate_met"]
    assert {:ok, report} = ReaderStudy.assess(protocol, records, technical)
    assert report["external_reader_status"] == "passed_self_reported"
    assert report["technical_status"] == "passed"
    assert report["p5_external_gate_met"]
    assert report["evidence_policy"] =~ "self-reports"
  end

  test "a blocker stops the gate without erasing completed reading or technical evidence",
       context do
    records = Enum.map(1..3, &feedback(context.protocol, reader_id(&1), fresh: true))
    blocked = put_in(records, [Access.at(1), "findings"], [finding("blocker")])
    assert {:ok, report} = ReaderStudy.assess(context.protocol, blocked, technical())
    assert report["external_reader_count"] == 3
    assert report["external_fresh_reproductions"] == 3
    assert report["unresolved_blockers"] == 1
    assert report["external_reader_status"] == "needs_revision"
    assert report["technical_status"] == "passed"
    assert report["findings"] == [finding("blocker")]
    refute report["p5_external_gate_met"]
    minor = put_in(records, [Access.at(1), "findings"], [finding("minor")])
    assert {:ok, report} = ReaderStudy.assess(context.protocol, minor, technical())
    assert report["p5_external_gate_met"]
  end

  test "five unique readers are bounded and duplicates or a sixth reader are refused", context do
    records = Enum.map(1..5, &feedback(context.protocol, reader_id(&1), fresh: true))
    assert {:ok, report} = ReaderStudy.assess(context.protocol, records, technical())
    assert report["external_reader_count"] == 5
    assert report["p5_external_gate_met"]

    assert {:error, :reader_limit_reached} =
             ReaderStudy.assess(
               context.protocol,
               records ++ [feedback(context.protocol, "R06")],
               nil
             )

    assert {:error, :duplicate_reader} =
             ReaderStudy.assess(context.protocol, [hd(records), hd(records)], nil)

    study = copy_packet(context)

    for record <- records do
      assert {:ok, _} = ReaderStudy.add_feedback(study, feedback_file(context, record))
    end

    assert {:error, :reader_limit_reached} =
             ReaderStudy.add_feedback(
               study,
               feedback_file(context, feedback(context.protocol, "R06"))
             )

    assert length(File.ls!(Path.join(study, "feedback"))) == 5
  end

  test "technical schema rejects unknown, missing, future or nonboolean attestations", context do
    for invalid <- [
          Map.put(technical(), "full_regression", "passed"),
          Map.delete(technical(), "source_unchanged"),
          Map.put(technical(), "extra", true),
          Map.put(technical(), "schema_version", 2),
          Map.put(technical(), "evidence_sha256", "not-a-hash")
        ] do
      assert {:error, :invalid_technical_evidence} =
               ReaderStudy.assess(context.protocol, [], invalid)
    end

    assert {:ok, report} =
             ReaderStudy.assess(
               context.protocol,
               [],
               Map.put(technical(), "full_regression", false)
             )

    assert report["technical_status"] == "pending"
    refute report["p5_external_gate_met"]
  end

  test "feedback findings and command evidence remain inert text", context do
    study = copy_packet(context)
    marker = Path.join(context.case_root, "must-never-exist")
    text = "File.write!(#{inspect(marker)}, \"executed\"); $(touch #{marker})"

    record =
      feedback(context.protocol, "R01", fresh: true)
      |> Map.put("findings", [%{finding("major") | "description" => text}])
      |> put_in(["reproduction", "commands", Access.at(0), "evidence"], text)

    assert {:ok, _} = ReaderStudy.add_feedback(study, feedback_file(context, record))
    assert {:ok, report} = ReaderStudy.report(study, technical())
    assert hd(report["findings"])["description"] == text
    refute File.exists?(marker)
  end

  test "source drift and altered manifest bytes fail frozen packet identity", context do
    study = copy_packet(context)
    source = Path.join(study, "project/lib/agent_systems_lab/kernel.ex")
    original = File.read!(source)
    File.write!(source, original <> "\n# tampered source\n")
    assert {:error, _} = ReaderStudy.load(study)
    File.write!(source, original)
    assert {:ok, _} = ReaderStudy.load(study)
    manifest = Path.join(study, "project/reproduction-source-manifest.json")
    File.write!(manifest, File.read!(manifest) <> "\n")
    assert {:ok, _} = Reproduction.verify(Path.join(study, "project"))
    assert {:error, :reading_source_mismatch} = ReaderStudy.load(study)
  end

  test "changed protocol hash and incompatible rehashed protocol schema are rejected", context do
    study = copy_packet(context)
    protocol_path = Path.join(study, "protocol.json")

    File.write!(
      protocol_path,
      JSON.encode!(Map.put(context.protocol, "protocol_hash", digest("bad")))
    )

    assert {:error, :invalid_reading_protocol} = ReaderStudy.load(study)

    invalid = [
      Map.put(context.protocol, "schema_version", 2),
      Map.put(context.protocol, "unknown", true),
      put_in(context.protocol, ["suite", "week"], 23),
      put_in(context.protocol, ["suite", "command_ids"], ["arbitrary"]),
      put_in(context.protocol, ["suite", "chapters", Access.at(0), "path"], "../outside"),
      put_in(context.protocol, ["suite", "unknown"], "reject even with a matching checksum")
    ]

    for changed <- invalid do
      changed = rehash(changed)
      assert {:error, :invalid_reading_protocol} = ReaderStudy.validate_protocol(changed)
      File.write!(protocol_path, JSON.encode!(changed))
      assert {:error, :invalid_reading_protocol} = ReaderStudy.load(study)
    end
  end

  test "symlinked protocol, feedback input and feedback directory fail closed", context do
    study = copy_packet(context)
    protocol_path = Path.join(study, "protocol.json")
    outside = Path.join(context.case_root, "outside-protocol.json")
    File.rename!(protocol_path, outside)
    File.ln_s!(outside, protocol_path)
    assert {:error, _} = ReaderStudy.load(study)
    File.rm!(protocol_path)
    File.rename!(outside, protocol_path)
    original = feedback_file(context, feedback(context.protocol, "R01"))
    linked = Path.join(context.case_root, "linked-feedback.json")
    File.ln_s!(original, linked)
    assert {:error, _} = ReaderStudy.add_feedback(study, linked)
    assert File.ls!(Path.join(study, "feedback")) == []
    directory = Path.join(study, "feedback")
    moved = Path.join(context.case_root, "moved-feedback")
    File.rename!(directory, moved)
    File.ln_s!(moved, directory)
    assert {:error, _} = ReaderStudy.add_feedback(study, original)
    assert File.ls!(moved) == []
  end

  test "hardlinked and oversized JSON cannot be accepted or replace current report", context do
    study = copy_packet(context)
    original = feedback_file(context, feedback(context.protocol, "R01"))
    linked = Path.join(context.case_root, "hardlinked-feedback.json")
    File.ln!(original, linked)
    assert {:error, _} = ReaderStudy.add_feedback(study, linked)
    File.rm!(linked)
    big = Path.join(context.case_root, "too-large.json")
    File.write!(big, String.duplicate(" ", 262_145))
    assert {:error, _} = ReaderStudy.add_feedback(study, big)
    assert File.ls!(Path.join(study, "feedback")) == []
    report = Path.join(study, "report.json")
    prior = File.read!(report)
    File.write!(Path.join(study, "protocol.json"), File.read!(big))
    assert {:error, _} = ReaderStudy.report(study)
    assert File.read!(report) == prior
  end

  test "saved feedback filename mismatch or stray files cannot be counted", context do
    study = copy_packet(context)
    directory = Path.join(study, "feedback")
    File.write!(Path.join(directory, "R02.json"), JSON.encode!(feedback(context.protocol, "R01")))
    assert {:error, :invalid_saved_feedback} = ReaderStudy.report(study)
    File.rm!(Path.join(directory, "R02.json"))
    File.write!(Path.join(directory, "extra.txt"), "not accepted feedback")
    assert {:error, :invalid_saved_feedback} = ReaderStudy.report(study)
    refute read_json(Path.join(study, "report.json"))["p5_external_gate_met"]
  end

  test "corrupted saved reports are preserved and cannot be silently replaced", context do
    study = copy_packet(context)
    path = Path.join(study, "report.json")
    original = read_json(path)

    invalid = [
      Map.put(original, "external_reader_count", 3),
      original |> Map.put("schema_version", 2) |> rehash_report(),
      original |> Map.put("unknown", true) |> rehash_report()
    ]

    for value <- invalid do
      bytes = JSON.encode!(value)
      File.write!(path, bytes)
      assert {:error, :invalid_saved_reading_report} = ReaderStudy.report(study)
      assert File.read!(path) == bytes
      refute Enum.any?(File.ls!(study), &String.starts_with?(&1, ".report-"))
    end
  end

  test "rehashed packet still binds the exact frozen suite inside its verified source export",
       context do
    study = copy_packet(context)
    project = Path.join(study, "project")
    suite_path = Path.join(project, "fixtures/reader_study/suite.json")

    changed =
      suite_path
      |> read_json()
      |> Map.put("human_feedback_policy", "Changed suite in a separately verified export")

    File.write!(suite_path, JSON.encode!(changed))
    File.rm!(Path.join(project, "reproduction-source-manifest.json"))
    replacement = Path.join(context.case_root, "replacement-project")
    assert {:ok, exported} = Reproduction.export(replacement, source: project)
    File.rm_rf!(project)
    File.rename!(replacement, project)

    manifest = Path.join(project, "reproduction-source-manifest.json")

    protocol =
      context.protocol
      |> Map.put("source_manifest_sha256", digest(File.read!(manifest)))
      |> rehash()

    assert exported.manifest["file_count"] > 0
    assert {:ok, _} = Reproduction.verify(project)
    assert :ok = ReaderStudy.validate_protocol(protocol)
    File.write!(Path.join(study, "protocol.json"), JSON.encode!(protocol))
    assert {:error, :reading_suite_mismatch} = ReaderStudy.load(study)
  end

  test "bounded individual records may produce a valid report larger than one feedback record",
       context do
    study = copy_packet(context)

    findings =
      for index <- 1..40 do
        finding("minor")
        |> Map.put("location", "synthetic location #{index}")
        |> Map.put("description", String.duplicate("d", 2048))
        |> Map.put("suggestion", String.duplicate("s", 1024))
      end

    for index <- 1..5 do
      record = feedback(context.protocol, reader_id(index), fresh: true)
      record = Map.put(record, "findings", findings)
      assert byte_size(JSON.encode!(record)) < 262_144
      assert {:ok, _} = ReaderStudy.add_feedback(study, feedback_file(context, record))
    end

    assert {:ok, first} = ReaderStudy.report(study, technical())
    assert first["external_reader_count"] == 5
    assert first["p5_external_gate_met"]
    assert byte_size(File.read!(Path.join(study, "report.json"))) > 262_144
    assert {:ok, ^first} = ReaderStudy.report(study, technical())
  end

  test "symlinked output ancestor cannot create any directories at its target", context do
    target = Path.join(context.case_root, "untouched-target")
    File.mkdir!(target)
    sentinel = Path.join(target, "sentinel.bin")
    File.write!(sentinel, "must remain unchanged")
    link = Path.join(context.case_root, "output-link")
    File.ln_s!(target, link)
    assert {:error, _} = ReaderStudy.prepare(Path.join(link, "new-parent/packet"))
    refute File.exists?(Path.join(target, "new-parent"))
    assert File.read!(sentinel) == "must remain unchanged"
    assert File.ls!(target) == ["sentinel.bin"]
  end

  test "valid shaped findings cannot bypass the total feedback byte bound", context do
    large_finding =
      finding("minor")
      |> Map.put("description", String.duplicate("d", 4096))
      |> Map.put("suggestion", String.duplicate("s", 4096))

    record =
      feedback(context.protocol, "R01")
      |> Map.put("findings", List.duplicate(large_finding, 64))

    assert byte_size(JSON.encode!(record)) > 262_144

    assert {:error, :invalid_reader_feedback} =
             ReaderStudy.validate_feedback(record, context.protocol)

    study = copy_packet(context)
    assert {:error, _} = ReaderStudy.add_feedback(study, feedback_file(context, record))
    assert File.ls!(Path.join(study, "feedback")) == []
  end

  test "output inside selected source is refused before mkdir, including the macOS case alias" do
    source_root = Path.expand("../..", __DIR__)
    lib = Path.join(source_root, "lib")
    original = File.ls!(lib) |> Enum.sort()

    names =
      if :os.type() == {:unix, :darwin} and File.dir?(Path.join(source_root, "LIB")),
        do: ["lib", "LIB"],
        else: ["lib"]

    for name <- names do
      selected = Path.join(source_root, name)
      target = Path.join(selected, "must-not-create-reader-packet-" <> Ecto.UUID.generate())
      refute File.exists?(target)
      assert {:error, :reading_output_inside_source} = ReaderStudy.prepare(target)
      refute File.exists?(target)
    end

    assert Enum.sort(File.ls!(lib)) == original
  end

  test "technical JSON file uses bounded inert file rules and preserves report on rejection",
       context do
    study = copy_packet(context)
    valid = Path.join(context.case_root, "technical.json")
    File.write!(valid, JSON.encode!(technical()))
    assert {:ok, report} = ReaderStudy.report_from_file(study, valid)
    assert report["technical_status"] == "passed"
    assert report["external_reader_count"] == 0
    refute report["p5_external_gate_met"]
    prior = File.read!(Path.join(study, "report.json"))
    malformed = Path.join(context.case_root, "malformed-technical.json")
    File.write!(malformed, "{not-json")
    oversized = Path.join(context.case_root, "oversized-technical.json")
    File.write!(oversized, String.duplicate(" ", 262_145))
    symlink = Path.join(context.case_root, "symlink-technical.json")
    File.ln_s!(valid, symlink)
    hardlink = Path.join(context.case_root, "hardlink-technical.json")
    File.ln!(valid, hardlink)
    invalid = Path.join(context.case_root, "invalid-technical.json")
    marker = Path.join(context.case_root, "technical-must-never-execute")
    value = Map.put(technical(), "command", "File.write!(#{inspect(marker)}, \"executed\")")
    File.write!(invalid, JSON.encode!(value))

    for path <- [malformed, oversized, symlink, hardlink, invalid, "relative-technical.json"] do
      assert {:error, _} = ReaderStudy.report_from_file(study, path)
      assert File.read!(Path.join(study, "report.json")) == prior
      refute File.exists?(marker)
    end
  end

  defp copy_packet(context) do
    path = Path.join(context.case_root, "study")
    File.cp_r!(context.pristine, path)
    # cp_r preserves file modes, but directory creation still obeys the current
    # umask. Restore the frozen fixture's directory modes before verifying it.
    restore_directory_modes(context.pristine, path)
    path
  end

  defp restore_directory_modes(source, destination) do
    %{type: :directory, mode: mode} = File.lstat!(source)

    for name <- File.ls!(source) do
      child = Path.join(source, name)

      if File.lstat!(child).type == :directory do
        restore_directory_modes(child, Path.join(destination, name))
      end
    end

    File.chmod!(destination, Bitwise.band(mode, 0o777))
  end

  defp feedback_file(context, record) do
    path = Path.join(context.case_root, "submitted-#{Ecto.UUID.generate()}.json")
    File.write!(path, JSON.encode!(record))
    path
  end

  defp feedback(protocol, id, opts \\ []) do
    reproduction =
      if opts[:fresh] do
        %{
          "status" => "passed",
          "environment" => "fresh_workspace",
          "commands" =>
            Enum.map(
              @commands,
              &%{"id" => &1, "outcome" => "passed", "evidence" => "synthetic test fixture only"}
            )
        }
      else
        %{"status" => "not_attempted", "environment" => "none", "commands" => []}
      end

    %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "reader_id" => id,
      "reader_type" => "external_human",
      "independent_of_authors" => true,
      "completed" => true,
      "started_at_utc" => "2026-10-23T01:00:00Z",
      "finished_at_utc" => "2026-10-23T02:00:00Z",
      "chapters" => @chapters,
      "findings" => [],
      "reproduction" => reproduction
    }
  end

  defp technical do
    %{
      "schema_version" => 1,
      "fresh_source_export" => true,
      "isolated_runtime" => true,
      "isolated_dependencies" => true,
      "isolated_postgres" => true,
      "full_regression" => true,
      "memory_regression" => true,
      "main_experiments" => true,
      "source_unchanged" => true,
      "evidence_sha256" => digest("synthetic technical fixture, not real acceptance")
    }
  end

  defp finding(severity) do
    %{
      "chapter" => "ch02",
      "location" => "2.3",
      "severity" => severity,
      "description" => "Synthetic reader-protocol test finding",
      "suggestion" => "Synthetic fixture, never real reader feedback"
    }
  end

  defp reader_id(number), do: "R" <> String.pad_leading(Integer.to_string(number), 2, "0")
  defp read_json(path), do: path |> File.read!() |> JSON.decode!()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp rehash(protocol),
    do: Map.put(protocol, "protocol_hash", Report.hash(Map.delete(protocol, "protocol_hash")))

  defp rehash_report(report),
    do: Map.put(report, "report_hash", Report.hash(Map.delete(report, "report_hash")))
end
