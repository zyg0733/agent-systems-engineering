defmodule AgentSystemsLab.ReleaseStudyTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.{ReleaseStudy, Reproduction}
  alias AgentSystemsLab.Evaluation.Report

  # All human records here are synthetic fixtures in owned temporary directories.
  # They are deleted on exit and cannot count as actual external reader evidence.
  @chapters ~w(ch02 ch05 ch08 ch14 ch16 ch20)
  @commands ~w(verify p1 history recover fence upgrade)
  @root Path.expand("../..", __DIR__)
  @suite File.read!(Path.join(@root, "fixtures/reader_study/suite.json")) |> JSON.decode!()

  setup_all do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "lab_release_study_" <> Ecto.UUID.generate())
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    input = Path.join(root, "source-input")
    File.mkdir!(input)

    paths =
      [
        "mix.exs",
        "mix.lock",
        ".tool-versions",
        "LICENSE",
        "LICENSE-DOCS",
        "NOTICE",
        "docs/licensing.md",
        "docs/recovery-runbook.md",
        "book/reader-study/README.md",
        "lib/never_execute.ex"
      ] ++
        Enum.flat_map(@suite["chapters"], &[&1["path"] | &1["labs"]])

    for path <- Enum.uniq(paths) do
      target = Path.join(input, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "Frozen fixture: " <> path <> "\n")
    end

    File.write!(
      Path.join(input, "lib/never_execute.ex"),
      "raise \"Do not execute reader source\"\n"
    )

    File.mkdir_p!(Path.join(input, "fixtures/reader_study"))

    File.write!(
      Path.join(input, "fixtures/reader_study/suite.json"),
      JSON.encode!(@suite) <> "\n"
    )

    source = Path.join(root, "frozen")
    assert {:ok, _} = Reproduction.export(source, source: input)
    packet = Path.join(root, "pristine")
    assert {:ok, prepared} = ReleaseStudy.prepare(packet, source: source)
    %{root: root, source: source, pristine: packet, protocol: prepared.protocol}
  end

  setup context do
    root = Path.join(context.root, Ecto.UUID.generate())
    File.mkdir!(root)
    packet = Path.join(root, "packet")
    File.cp_r!(context.pristine, packet)
    %{case_root: root, packet: packet}
  end

  test "explicit frozen source and original manifest bytes identify a zero-reader packet", c do
    assert {:ok, protocol} = ReleaseStudy.load(c.packet)
    assert protocol === c.protocol
    source_bytes = File.read!(Path.join(c.source, "reproduction-source-manifest.json"))
    assert protocol["source_manifest_sha256"] == hash(source_bytes)

    assert File.read!(Path.join(c.packet, "project/reproduction-source-manifest.json")) ==
             source_bytes

    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["external_reader_count"] == 0
    assert report["external_fresh_reproductions"] == 0
    assert report["event_count"] == 0
    assert report["external_reader_status"] == "pending"
    refute report["human_gate_met"]
    refute report["release_ready"]
    assert report["report_hash"] == Report.hash(Map.delete(report, "report_hash"))
    refute File.exists?(Path.join(c.packet, "report.json"))
    assert File.read!(Path.join(c.packet, "START-HERE.md")) =~ "trusted Week 25 host"
    assert ReleaseStudy.template(protocol)["completed"] == false

    for path <- ["protocol.json", "head.json", "feedback-template.json"] do
      assert Bitwise.band(File.stat!(Path.join(c.packet, path)).mode, 0o777) == 0o600
    end

    for path <- ~w(.runtime deps _build artifacts) do
      refute File.exists?(Path.join(c.packet, "project/" <> path))
    end
  end

  test "noncanonical but valid original manifest JSON bytes are preserved", c do
    source = Path.join(c.case_root, "frozen")
    File.cp_r!(c.source, source)
    path = Path.join(source, "reproduction-source-manifest.json")
    bytes = " \n" <> File.read!(path) <> " \n"
    File.write!(path, bytes)
    assert {:ok, _} = Reproduction.verify(source)
    output = Path.join(c.case_root, "new-packet")
    assert {:ok, prepared} = ReleaseStudy.prepare(output, source: source)
    assert prepared.protocol["source_manifest_sha256"] == hash(bytes)
    assert File.read!(Path.join(output, "project/reproduction-source-manifest.json")) == bytes
  end

  test "requires a source-only export and preserves existing and selected source destinations",
       c do
    output = Path.join(c.case_root, "new-packet")
    assert {:error, :study_frozen_source_required} = ReleaseStudy.prepare(output)

    assert {:error, :study_frozen_source_required} =
             ReleaseStudy.prepare(output, source: "relative")

    assert {:error, :study_frozen_source_required} =
             ReleaseStudy.prepare(output, source: c.source, ignored: true)

    refute File.exists?(output)
    assert {:error, :study_output_exists} = ReleaseStudy.prepare(c.packet, source: c.source)
    source = Path.join(c.case_root, "frozen")
    File.cp_r!(c.source, source)
    File.write!(Path.join(source, "candidate-manifest.json"), "{}\n")

    assert {:error, :study_source_only_export_required} =
             ReleaseStudy.prepare(output, source: source)

    refute File.exists?(output)
    inside = Path.join(c.source, "book/new-packet")
    assert {:error, :study_output_inside_source} = ReleaseStudy.prepare(inside, source: c.source)
    refute File.exists?(inside)
    inside_root = Path.join(c.source, "new-packet")

    assert {:error, :study_output_inside_source} =
             ReleaseStudy.prepare(inside_root, source: c.source)

    refute File.exists?(inside_root)

    assert {:error, :study_absolute_path_required} =
             ReleaseStudy.prepare("relative-packet", source: c.source)
  end

  test "preserves raw feedback bytes, binds them once, and never executes descriptions", c do
    record = feedback(c.protocol, "R01", findings: [finding("R01-I01")])
    input = input(c, " \n" <> JSON.encode!(record) <> "\n\n")
    raw = File.read!(input)
    assert {:ok, %{"saved" => true}} = ReleaseStudy.add_feedback(c.packet, input)
    path = Path.join(c.packet, "feedback/R01.json")
    assert File.read!(path) == raw
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    event = json(Path.join(c.packet, "events/000001.json"))
    assert event["payload"]["sha256"] == hash(raw)
    assert event["payload"]["bytes"] == byte_size(raw)
    assert event["event_sha256"] == Report.hash(Map.delete(event, "event_sha256"))
    before = File.read!(Path.join(c.packet, "head.json"))
    assert {:error, :study_duplicate_reader} = ReleaseStudy.add_feedback(c.packet, input)
    assert File.read!(path) == raw
    assert File.read!(Path.join(c.packet, "head.json")) == before
    assert {:ok, report} = ReleaseStudy.verify(c.packet)
    assert report["external_reader_count"] == 1
    assert report["unresolved_blockers"] == 1
    assert hd(report["issues"])["finding"]["description"] =~ "$(touch"
  end

  test "rejects synthetic roles, unknown fields, versions, old identities and malformed findings",
       c do
    base = feedback(c.protocol, "R01", findings: [finding("R01-I01")])

    variants = [
      ReleaseStudy.template(c.protocol),
      Map.put(base, "reader_type", "agent"),
      Map.put(base, "independent_of_authors", false),
      Map.put(base, "completed", false),
      Map.put(base, "schema_version", 2),
      Map.put(base, "extra", true),
      Map.put(base, "source_manifest_sha256", String.duplicate("0", 64)),
      Map.put(base, "protocol_hash", String.duplicate("0", 64)),
      Map.put(base, "chapters", tl(@chapters)),
      Map.put(base, "finished_at_utc", "2026-10-23T08:00:00Z"),
      put_in(base, ["findings", Access.at(0), "issue_id"], "R02-I01"),
      put_in(base, ["findings", Access.at(0), "issue_id"], "../escape"),
      put_in(base, ["findings", Access.at(0), "extra"], true),
      Map.put(base, "findings", [finding("R01-I01"), finding("R01-I01")])
    ]

    for record <- variants do
      assert {:error, :invalid_study_feedback} =
               ReleaseStudy.add_feedback(c.packet, input(c, record))
    end

    assert File.ls!(Path.join(c.packet, "events")) == []
    assert File.ls!(Path.join(c.packet, "feedback")) == []
  end

  test "blocker requires a fix and fresh retest by its original reader", c do
    assert {:ok, _} =
             ReleaseStudy.add_feedback(
               c.packet,
               input(c, feedback(c.protocol, "R01", findings: [finding("R01-I01")]))
             )

    original = File.read!(Path.join(c.packet, "feedback/R01.json"))
    fix = fix(c.protocol, "R01-I01", "fix1")
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix))
    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["unresolved_blockers"] == 1
    assert hd(report["issues"])["status"] == "awaiting_original_reader"
    retest = retest(c.protocol, "R01-I01", "fix1")

    for invalid <- [
          Map.put(retest, "reader_id", "R02"),
          Map.put(retest, "reader_type", "agent"),
          Map.put(retest, "source_manifest_sha256", String.duplicate("0", 64)),
          Map.put(retest, "started_at_utc", "2026-10-24T09:00:00Z"),
          Map.put(retest, "extra", true),
          Map.put(retest, "completed", false)
        ] do
      assert {:error, _} = ReleaseStudy.append(c.packet, input(c, invalid))
    end

    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, retest))
    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["unresolved_blockers"] == 0
    assert hd(report["issues"])["status"] == "resolved_self_reported"
    assert File.read!(Path.join(c.packet, "feedback/R01.json")) == original
    refute report["human_gate_met"]
    refute report["release_ready"]
    assert {:error, :invalid_study_retest} = ReleaseStudy.append(c.packet, input(c, retest))
  end

  test "a failed retest stays open and an old fix cannot close a replacement fix", c do
    add_reader(c, "R01", findings: [finding("R01-I01")])
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix(c.protocol, "R01-I01", "fix1")))
    failed = retest(c.protocol, "R01-I01", "fix1") |> Map.put("passed", false)
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, failed))
    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["unresolved_blockers"] == 1

    next_fix =
      fix(c.protocol, "R01-I01", "fix2") |> Map.put("created_at_utc", "2026-10-24T13:00:00Z")

    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, next_fix))

    assert {:error, :invalid_study_retest} =
             ReleaseStudy.append(c.packet, input(c, retest(c.protocol, "R01-I01", "fix1")))

    assert {:error, :invalid_study_fix} = ReleaseStudy.append(c.packet, input(c, next_fix))
    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["event_count"] == 4
    assert report["unresolved_blockers"] == 1
  end

  test "only three to five humans plus a fresh workspace and resolved blockers meet the human gate",
       c do
    add_reader(c, "R01", findings: [finding("R01-I01")], fresh: true)
    add_reader(c, "R02")
    assert {:ok, two} = ReleaseStudy.report(c.packet)
    refute two["human_gate_met"]
    add_reader(c, "R03")
    assert {:ok, blocked} = ReleaseStudy.report(c.packet)
    refute blocked["human_gate_met"]
    assert blocked["unresolved_blockers"] == 1
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix(c.protocol, "R01-I01", "fix1")))

    assert {:ok, _} =
             ReleaseStudy.append(c.packet, input(c, retest(c.protocol, "R01-I01", "fix1")))

    assert {:ok, ready} = ReleaseStudy.report(c.packet)
    assert ready["human_gate_met"]
    assert ready["external_reader_status"] == "passed_self_reported"
    assert ready["external_reader_count"] == 3
    assert ready["external_fresh_reproductions"] == 1
    refute ready["release_ready"]
    add_reader(c, "R04")
    add_reader(c, "R05")

    assert {:error, :study_reader_limit} =
             ReleaseStudy.add_feedback(c.packet, input(c, feedback(c.protocol, "R06")))
  end

  test "a fresh reproduction and every fixed command are required independent of reader count",
       c do
    for id <- ~w(R01 R02 R03), do: add_reader(c, id)
    assert {:ok, report} = ReleaseStudy.report(c.packet)
    refute report["human_gate_met"]
    assert report["external_fresh_reproductions"] == 0
    invalid = feedback(c.protocol, "R04", fresh: true) |> put_in(["reproduction", "commands"], [])

    assert {:error, :invalid_study_feedback} =
             ReleaseStudy.add_feedback(c.packet, input(c, invalid))
  end

  test "replay rejects modified original bytes, orphan feedback and missing binding events", c do
    add_reader(c, "R01")
    feedback = Path.join(c.packet, "feedback/R01.json")
    bytes = File.read!(feedback)
    File.write!(feedback, bytes <> "\n")
    assert {:error, :study_feedback_changed} = ReleaseStudy.report(c.packet)
    File.write!(feedback, bytes)
    File.write!(Path.join(c.packet, "feedback/R02.json"), "{}\n")
    assert {:error, :study_orphan_feedback} = ReleaseStudy.report(c.packet)
    File.rm!(Path.join(c.packet, "feedback/R02.json"))
    File.rm!(Path.join(c.packet, "events/000001.json"))
    assert {:error, :study_head_mismatch} = ReleaseStudy.report(c.packet)
  end

  test "event gaps, bad chains, unknown schemas and head mismatches fail closed", c do
    add_reader(c, "R01", findings: [finding("R01-I01")])
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix(c.protocol, "R01-I01", "fix1")))
    path = Path.join(c.packet, "events/000002.json")
    bytes = File.read!(path)
    event = JSON.decode!(bytes)

    for invalid <- [
          Map.put(event, "previous_sha256", String.duplicate("f", 64)),
          Map.put(event, "schema_version", 2),
          Map.put(event, "seq", 2.0),
          Map.put(event, "extra", true)
        ] do
      File.write!(path, JSON.encode!(invalid))
      assert {:error, :study_event_chain} = ReleaseStudy.report(c.packet)
    end

    File.write!(path, bytes)
    File.rename!(path, Path.join(c.packet, "events/000003.json"))
    assert {:error, :study_event_sequence} = ReleaseStudy.report(c.packet)
  end

  test "changed frozen source and protocol cannot inherit an old reader record", c do
    add_reader(c, "R01")
    target = Path.join(c.packet, "project/book/ch02-agent-state-machine.md")
    File.write!(target, "Changed task facts\n")
    assert {:error, _} = ReleaseStudy.report(c.packet)
    refute File.read!(Path.join(c.packet, "feedback/R01.json")) == ""
    protocol_path = Path.join(c.pristine, "protocol.json")
    protocol = json(protocol_path) |> Map.put("schema_version", 2)
    other = Path.join(c.case_root, "invalid-packet")
    File.cp_r!(c.pristine, other)
    File.write!(Path.join(other, "protocol.json"), JSON.encode!(protocol))
    assert {:error, :invalid_study_protocol} = ReleaseStudy.report(other)
  end

  test "bound report hashes detect ledger changes even though saved report booleans are ignored",
       c do
    assert {:ok, empty} = ReleaseStudy.report(c.packet)

    File.write!(
      Path.join(c.packet, "report.json"),
      JSON.encode!(%{"release_ready" => true, "human_gate_met" => true})
    )

    assert {:ok, ^empty} = ReleaseStudy.report(c.packet)
    add_reader(c, "R01")
    assert {:ok, next} = ReleaseStudy.report(c.packet)
    refute next["report_hash"] == empty["report_hash"]
    refute next["feedback_manifest_sha256"] == empty["feedback_manifest_sha256"]
    refute next["ledger_sha256"] == empty["ledger_sha256"]
    assert next["evidence_policy"] =~ "rewritten head"
  end

  test "a newly frozen revision requires new feedback rather than migrating the old protocol",
       c do
    original = feedback(c.protocol, "R01", fresh: true)
    edited = Path.join(c.case_root, "edited-input")
    File.cp_r!(c.source, edited)
    File.write!(Path.join(edited, "book/ch02-agent-state-machine.md"), "A revised exercise\n")
    File.rm!(Path.join(edited, "reproduction-source-manifest.json"))
    new_source = Path.join(c.case_root, "revised-frozen")
    assert {:ok, _} = Reproduction.export(new_source, source: edited)
    new_packet = Path.join(c.case_root, "revised-packet")
    assert {:ok, prepared} = ReleaseStudy.prepare(new_packet, source: new_source)
    refute prepared.protocol["source_manifest_sha256"] == c.protocol["source_manifest_sha256"]
    refute prepared.protocol["protocol_hash"] == c.protocol["protocol_hash"]

    assert {:error, :invalid_study_feedback} =
             ReleaseStudy.add_feedback(new_packet, input(c, original))

    assert {:ok, report} = ReleaseStudy.report(new_packet)
    assert report["external_reader_count"] == 0
    refute report["human_gate_met"]
    refute report["release_ready"]
  end

  test "a replacement fix reopens a previously resolved blocker until its own retest", c do
    add_reader(c, "R01", findings: [finding("R01-I01")], fresh: true)
    add_reader(c, "R02")
    add_reader(c, "R03")
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix(c.protocol, "R01-I01", "fix1")))

    assert {:ok, _} =
             ReleaseStudy.append(c.packet, input(c, retest(c.protocol, "R01-I01", "fix1")))

    assert {:ok, before} = ReleaseStudy.report(c.packet)
    assert before["human_gate_met"]
    next = fix(c.protocol, "R01-I01", "fix2") |> Map.put("created_at_utc", "2026-10-24T13:00:00Z")
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, next))
    assert {:ok, after_fix} = ReleaseStudy.report(c.packet)
    assert after_fix["unresolved_blockers"] == 1
    refute after_fix["human_gate_met"]

    assert {:error, :invalid_study_retest} =
             ReleaseStudy.append(c.packet, input(c, retest(c.protocol, "R01-I01", "fix1")))
  end

  test "partial publication and a changed head fail closed while original feedback is retained",
       c do
    add_reader(c, "R01", findings: [finding("R01-I01")])
    head_path = Path.join(c.packet, "head.json")
    old_head = File.read!(head_path)
    assert {:ok, _} = ReleaseStudy.append(c.packet, input(c, fix(c.protocol, "R01-I01", "fix1")))
    File.write!(head_path, old_head)
    assert {:error, :study_head_mismatch} = ReleaseStudy.report(c.packet)

    assert {:error, :study_head_mismatch} =
             ReleaseStudy.append(c.packet, input(c, retest(c.protocol, "R01-I01", "fix1")))

    assert File.exists?(Path.join(c.packet, "feedback/R01.json"))
    assert File.exists?(Path.join(c.packet, "events/000002.json"))
  end

  test "exclusive writer lock blocks concurrent appends and abandoned locks require inspection",
       c do
    lock = Path.join(c.packet, ".append.lock")
    File.mkdir!(lock)

    assert {:error, :study_append_locked} =
             ReleaseStudy.add_feedback(c.packet, input(c, feedback(c.protocol, "R01")))

    assert {:error, :study_append_locked} = ReleaseStudy.report(c.packet)
    assert File.ls!(Path.join(c.packet, "feedback")) == []
    File.rmdir!(lock)

    jobs =
      for _ <- 1..8 do
        Task.async(fn ->
          ReleaseStudy.add_feedback(c.packet, input(c, feedback(c.protocol, "R01")))
        end)
      end

    results = Task.await_many(jobs)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or
                 &1 in [{:error, :study_append_locked}, {:error, :study_duplicate_reader}])
           )

    assert {:ok, report} = ReleaseStudy.report(c.packet)
    assert report["event_count"] == 1
  end

  test "symlinks, hardlinks, oversized inputs and unsafe directory ancestors are refused", c do
    original = input(c, feedback(c.protocol, "R01"))
    symlink = Path.join(c.case_root, "symbolic.json")
    hardlink = Path.join(c.case_root, "hard.json")
    assert :ok = File.ln_s(original, symlink)
    assert {:error, :study_unsafe_file} = ReleaseStudy.add_feedback(c.packet, symlink)
    assert :ok = File.ln(original, hardlink)
    assert {:error, :study_unsafe_file} = ReleaseStudy.add_feedback(c.packet, hardlink)
    File.rm!(hardlink)
    too_large = input(c, String.duplicate("x", 262_145))
    assert {:error, :study_unsafe_file} = ReleaseStudy.add_feedback(c.packet, too_large)
    alias_dir = Path.join(c.case_root, "alias")
    File.ln_s!(c.packet, alias_dir)
    assert {:error, :study_unsafe_directory} = ReleaseStudy.report(alias_dir)
    assert {:error, :study_absolute_path_required} = ReleaseStudy.report("relative")
    add_reader(c, "R01")
    path = Path.join(c.packet, "events/000001.json")
    File.ln!(path, Path.join(c.case_root, "linked-event.json"))
    assert {:error, :study_unsafe_file} = ReleaseStudy.report(c.packet)
  end

  defp add_reader(c, id, opts \\ []) do
    assert {:ok, _} =
             ReleaseStudy.add_feedback(c.packet, input(c, feedback(c.protocol, id, opts)))
  end

  defp feedback(protocol, id, opts \\ []) do
    %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "source_manifest_sha256" => protocol["source_manifest_sha256"],
      "reader_id" => id,
      "reader_type" => "external_human",
      "independent_of_authors" => true,
      "completed" => true,
      "started_at_utc" => "2026-10-24T08:00:00Z",
      "finished_at_utc" => "2026-10-24T10:00:00Z",
      "chapters" => @chapters,
      "findings" => Keyword.get(opts, :findings, []),
      "reproduction" =>
        if(Keyword.get(opts, :fresh, false),
          do: %{
            "status" => "passed",
            "environment" => "fresh_workspace",
            "commands" =>
              Enum.map(
                @commands,
                &%{"id" => &1, "outcome" => "passed", "evidence" => "Synthetic fixture log"}
              )
          },
          else: %{"status" => "not_attempted", "environment" => "none", "commands" => []}
        )
    }
  end

  defp finding(id),
    do: %{
      "issue_id" => id,
      "chapter" => "ch02",
      "location" => "Synthetic exercise step",
      "severity" => "blocker",
      "description" => "Inert $(touch forbidden); never run feedback",
      "suggestion" => "Explain environment setup"
    }

  defp fix(protocol, issue, id),
    do: %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "source_manifest_sha256" => protocol["source_manifest_sha256"],
      "type" => "fix",
      "issue_id" => issue,
      "fix_id" => id,
      "created_at_utc" => "2026-10-24T11:00:00Z",
      "description" => "Synthetic environment explanation; project unchanged",
      "evidence_sha256" => hash("Synthetic inert fix evidence")
    }

  defp retest(protocol, issue, fix),
    do: %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "source_manifest_sha256" => protocol["source_manifest_sha256"],
      "type" => "retest",
      "issue_id" => issue,
      "fix_id" => fix,
      "reader_id" => String.slice(issue, 0, 3),
      "reader_type" => "external_human",
      "independent_of_authors" => true,
      "completed" => true,
      "started_at_utc" => "2026-10-24T11:30:00Z",
      "finished_at_utc" => "2026-10-24T12:00:00Z",
      "passed" => true,
      "description" => "Synthetic original-reader retest",
      "evidence_sha256" => hash("Synthetic inert retest evidence")
    }

  defp input(c, value) do
    path = Path.join(c.case_root, "input-" <> Ecto.UUID.generate() <> ".json")
    File.write!(path, if(is_binary(value), do: value, else: JSON.encode!(value) <> "\n"))
    path
  end

  defp json(path), do: path |> File.read!() |> JSON.decode!()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
