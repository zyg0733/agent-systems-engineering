defmodule AgentSystemsLab.ReleaseAssessmentTest do
  # Each assessment rechecks every source and matrix file. Run these I/O-heavy
  # mutation cases after async modules so their integrity walks do not contend.
  use ExUnit.Case, async: false

  Code.require_file("../support/frozen_matrix_fixture.exs", __DIR__)
  Code.require_file("../support/release_candidate_fixture.ex", __DIR__)

  alias AgentSystemsLab.{CandidatePackage, ReleaseAssessment, ReleaseStudy, Reproduction}
  alias AgentSystemsLab.Test.ReleaseCandidateFixture
  @root Path.expand("../..", __DIR__)

  setup_all do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "release-assessment-" <> Ecto.UUID.generate())
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    source = Path.join(root, "source")
    assert {:ok, exported} = Reproduction.export(source, source: @root)
    evidence = Path.join(root, "technical")
    File.mkdir!(evidence)
    ReleaseCandidateFixture.evidence_fixture(evidence, hash(File.read!(exported.manifest_path)))
    candidate = Path.join(root, "candidate")
    assert {:ok, built} = CandidatePackage.build(candidate, source: source, evidence: evidence)
    study = Path.join(root, "zero-study")
    assert {:ok, _} = ReleaseStudy.prepare(study, source: source)

    binding = %{
      "source_manifest_sha256" => built.manifest["source_manifest_sha256"],
      "candidate_manifest_sha256" => hash(File.read!(built.manifest_path))
    }

    %{
      fixture_root: root,
      candidate: candidate,
      source: source,
      zero_study: study,
      binding: binding
    }
  end

  setup c do
    root = Path.join(c.fixture_root, Ecto.UUID.generate())
    File.mkdir!(root)
    evidence = Path.join(root, "external")
    File.mkdir!(evidence)
    %{case_root: root, evidence: evidence}
  end

  test "missing external evidence stays pending and does not approve or publish", c do
    assert {:ok, report} = ReleaseAssessment.assess(candidate: c.candidate)
    assert report["gates"]["technical_candidate"]["status"] == "passed"
    assert report["gates"]["external_readers"]["external_reader_count"] == 0
    refute report["evidence_complete"]
    refute report["candidate_manifest_release_ready"]
    refute report["approval_recorded"]
    refute report["release_ready"]
    assert report["publication_status"] == "not_published"
    assert {:ok, ^report} = ReleaseAssessment.assess(candidate: c.candidate)
  end

  test "a verified zero-reader study binds source protocol feedback and append ledger", c do
    assert {:ok, report} = assess(c, study: c.zero_study)
    assert report["study"]["source_manifest_sha256"] == c.binding["source_manifest_sha256"]

    for key <-
          ~w(protocol_hash feedback_manifest_sha256 ledger_sha256 ledger_head_sha256 report_hash) do
      assert report["study"][key] =~ ~r/\A[a-f0-9]{64}\z/
    end

    assert report["gates"]["external_readers"]["status"] == "pending"
    refute File.exists?(Path.join(c.zero_study, "report.json"))
  end

  test "policy and approval options cannot lower existing release gates", c do
    assert ReleaseAssessment.policy()["linux"] =~ "zero exclusions"

    for opts <- [
          [candidate: c.candidate, policy: "macos"],
          [candidate: c.candidate, approval_recorded: true],
          [candidate: c.candidate, candidate: c.candidate],
          []
        ] do
      assert {:error, :release_assessment_invalid_options} = ReleaseAssessment.assess(opts)
    end
  end

  test "empty external directory or valid empty index is pending", c do
    assert {:ok, report} = assess(c, evidence: c.evidence)
    assert report["external_evidence"] == nil
    write_index(c, [])
    assert {:ok, report} = assess(c, evidence: c.evidence)
    assert report["external_evidence"]["environments"] == []
    refute report["evidence_complete"]
  end

  test "unknown versions keys and source or candidate identity mismatches are errors", c do
    index = index(c, [])

    for changed <- [
          Map.put(index, "schema_version", 2),
          Map.put(index, "release_ready", true),
          Map.put(index, "source_manifest_sha256", hash("other")),
          Map.put(index, "candidate_manifest_sha256", hash("other"))
        ] do
      write_json(Path.join(c.evidence, "environment-evidence.json"), changed)
      assert {:error, _} = assess(c, evidence: c.evidence)
    end
  end

  test "core Linux execution with seatbelt exclusions never releases full Linux gate", c do
    environment(c, "linux", "core", excluded_tags: ["seatbelt"])
    assert {:ok, report} = assess(c, evidence: c.evidence)
    assert report["gates"]["linux_full"]["status"] == "pending"
    assert "full_scope_required" in report["gates"]["linux_full"]["pending_reasons"]
    refute report["evidence_complete"]
  end

  test "a new workspace or warm cache is not a cold host", c do
    environment(c, "cold_install_macos", "full", warm: true)
    assert {:ok, report} = assess(c, evidence: c.evidence)

    assert "cold_host_and_empty_caches_required" in report["gates"]["cold_install_macos"][
             "pending_reasons"
           ]
  end

  test "hash-bound command logs are checked and original reader claims do not waive missing hosts",
       c do
    study = human_study(c)
    assert {:ok, report} = assess(c, study: study)
    assert report["gates"]["external_readers"]["status"] == "passed"
    refute report["evidence_complete"]
    refute report["approval_recorded"]
    environment(c, "linux", "core")

    File.write!(
      Path.join(c.evidence, "linux/full.log"),
      "changed\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    assert {:error, :release_assessment_evidence_integrity} = assess(c, evidence: c.evidence)
  end

  test "regression successful boolean cannot replace one actual passing footer", c do
    environment(c, "linux", "core", full_log: "passed=true\n")
    assert {:error, :release_assessment_invalid_regression_log} = assess(c, evidence: c.evidence)

    environment(c, "linux", "core",
      full_log: "  1) failed test\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    assert {:error, :release_assessment_invalid_regression_log} = assess(c, evidence: c.evidence)

    environment(c, "linux", "core",
      full_log:
        "Result: 10 passed (2 doctests, 8 tests)\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    assert {:error, :release_assessment_invalid_regression_log} = assess(c, evidence: c.evidence)
  end

  test "regression counts and no-exclusions full scope are independently evaluated", c do
    environment(c, "linux", "core",
      memory_log: "Result: 7 passed (2 doctests, 5 tests), 2 excluded\n"
    )

    assert {:error, :release_assessment_regression_counts_mismatch} =
             assess(c, evidence: c.evidence)

    environment(c, "linux", "full",
      full_log: "Result: 9 passed (2 doctests, 7 tests), 1 excluded\n"
    )

    assert {:ok, report} = assess(c, evidence: c.evidence)
    assert "full_regression_has_exclusions" in report["gates"]["linux_full"]["pending_reasons"]
  end

  test "a mutually consistent smaller test set or missing doctest cannot stand for the candidate source",
       c do
    for {full, memory} <- [
          {"Result: 1 passed (0 doctests, 1 tests)\n",
           "Result: 1 passed (0 doctests, 1 tests)\n"},
          {"Result: 10 passed (1 doctests, 9 tests)\n",
           "Result: 7 passed (1 doctests, 6 tests), 3 excluded\n"}
        ] do
      environment(c, "linux", "full", full_log: full, memory_log: memory)

      assert {:error, :release_assessment_regression_counts_mismatch} =
               assess(c, evidence: c.evidence)
    end
  end

  test "runtime pins and installation source inputs cannot be omitted from a complete environment",
       c do
    complete_environment(c, "cold_install_macos")
    value = read_environment(c, "cold_install_macos")

    value =
      value
      |> put_in(["provenance", "tools"], %{"elixir" => "unknown"})
      |> put_in(["provenance", "inputs"], [
        %{"id" => "source", "origin" => "fixture", "sha256" => hash("other source")}
      ])

    replace_environment(c, "cold_install_macos", value)
    assert {:ok, report} = assess(c, evidence: c.evidence)
    reasons = report["gates"]["cold_install_macos"]["pending_reasons"]
    assert "runtime_pins_required" in reasons
    assert "installation_input_provenance_missing" in reasons
  end

  test "missing commands failed exits and unclean owned resources are pending", c do
    environment(c, "linux", "full", failed: true, cleanup: false)
    assert {:ok, report} = assess(c, evidence: c.evidence)
    reasons = report["gates"]["linux_full"]["pending_reasons"]
    assert "command_pending:full" in reasons
    assert "command_pending:matrix" in reasons
    assert "owned_cleanup_pending" in reasons
  end

  test "unknown environment and command keys or executable text argv are rejected", c do
    environment(c, "linux", "core")
    original = read_environment(c, "linux")

    for changed <- [
          Map.put(original, "passed", true),
          Map.put(original, "schema_version", 2),
          put_in(original, ["commands", Access.at(0), "argv"], ["touch", "sentinel"]),
          put_in(original, ["commands", Access.at(0), "passed"], true)
        ] do
      replace_environment(c, "linux", changed)
      assert {:error, _} = assess(c, evidence: c.evidence)
    end
  end

  test "relative escape symlink hardlink and oversized evidence fail bounded file checks", c do
    environment(c, "linux", "core")
    original = read_environment(c, "linux")

    replace_environment(
      c,
      "linux",
      put_in(original, ["commands", Access.at(0), "log", "path"], "../outside.log")
    )

    assert {:error, _} = assess(c, evidence: c.evidence)
    replace_environment(c, "linux", original)
    file = Path.join(c.evidence, "linux/full.log")
    saved = Path.join(c.case_root, "saved.log")
    File.rename!(file, saved)
    File.ln_s!(saved, file)
    assert {:error, _} = assess(c, evidence: c.evidence)
    File.rm!(file)
    File.ln!(saved, file)
    assert {:error, _} = assess(c, evidence: c.evidence)
    File.rm!(file)
    File.rename!(saved, file)

    replace_environment(
      c,
      "linux",
      put_in(original, ["commands", Access.at(0), "log", "bytes"], 33_554_433)
    )

    assert {:error, _} = assess(c, evidence: c.evidence)
  end

  test "inert log text never executes and optional archive bytes are verified", c do
    marker = Path.join(c.case_root, "executed")

    environment(c, "linux", "core",
      full_log: "$(touch #{marker})\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    archive = Path.join(c.evidence, "candidate.tar.gz")
    File.write!(archive, "synthetic archive bytes, never extracted")
    update_index(c, &Map.put(&1, "archive", record(c.evidence, "candidate.tar.gz")))
    assert {:ok, report} = assess(c, evidence: c.evidence)
    assert report["external_evidence"]["archive"]["sha256"] == hash(File.read!(archive))
    refute File.exists?(marker)
    File.write!(archive, "changed")
    assert {:error, _} = assess(c, evidence: c.evidence)
    refute File.exists?(marker)
  end

  test "duplicate environment types and incomplete matrix results cannot be asserted green", c do
    environment(c, "linux", "full")

    update_index(c, fn index -> Map.update!(index, "environments", fn [one] -> [one, one] end) end)

    assert {:error, _} = assess(c, evidence: c.evidence)
    environment(c, "linux", "full")
    current = read_environment(c, "linux")

    File.write!(
      Path.join(c.evidence, "fake-report.json"),
      JSON.encode!(%{"complete" => true, "all_passed" => true})
    )

    matrix =
      command(c, "linux", "matrix", "matrix passed", record(c.evidence, "fake-report.json"))

    replace_environment(c, "linux", Map.update!(current, "commands", &(&1 ++ [matrix])))
    assert {:error, :release_assessment_matrix_invalid} = assess(c, evidence: c.evidence)
  end

  test "a malformed original candidate is rejected before external assertions", c do
    fake = Path.join(c.case_root, "fake-candidate")
    File.mkdir!(fake)
    write_json(Path.join(fake, "candidate-manifest.json"), %{"technical_candidate_ready" => true})
    assert {:error, _} = ReleaseAssessment.assess(candidate: fake)
  end

  test "complete synthetic evidence is distinguishable from approval and publication", c do
    study = human_study(c)
    complete_environment(c, "cold_install_macos")
    complete_environment(c, "linux")

    write_index(
      c,
      Enum.map(~w(cold_install_macos linux), &record(c.evidence, &1 <> "/environment.json"))
    )

    original = File.read!(Path.join(c.candidate, "candidate-manifest.json"))
    assert {:ok, report} = assess(c, study: study, evidence: c.evidence)
    assert report["evidence_complete"]
    assert Enum.all?(report["gates"], fn {_id, gate} -> gate["status"] == "passed" end)
    refute report["approval_recorded"]
    refute report["release_ready"]
    assert report["publication_status"] == "not_published"
    assert report["trust"] =~ "unverified"
    assert File.read!(Path.join(c.candidate, "candidate-manifest.json")) == original
  end

  test "Linux isolation cannot be replaced by Seatbelt or successful summary booleans", c do
    complete_environment(c, "linux")
    isolation = Path.join(c.evidence, "linux/isolation.json")
    original = isolation |> File.read!() |> JSON.decode!()

    for changed <- [
          Map.put(original, "backend", "seatbelt.v1"),
          Map.put(original, "platform", "{:unix, :darwin}"),
          put_in(original, ["probes", Access.at(1), "permission_denied"], false),
          put_in(original, ["probes", Access.at(1), "result", "cleanup", "target_exited"], false),
          Map.put(original, "unsupported_capabilities", ["network"]),
          put_in(original, ["probes", Access.at(1), "result", "backend"], "seatbelt.v1"),
          put_in(original, ["probes", Access.at(1), "result", "status"], "timed_out"),
          put_in(original, ["probes", Access.at(10), "actual_file_bytes"], -1),
          put_in(original, ["probes", Access.at(11), "opened"], -1),
          put_in(original, ["probes", Access.at(13), "captured_bytes"], -1),
          put_in(original, ["probes", Access.at(1), "unknown_flag"], true),
          Map.put(original, "probes", [])
        ] do
      write_json(isolation, changed)
      value = read_environment(c, "linux")

      commands =
        Enum.map(value["commands"], fn command ->
          if command["id"] == "isolation",
            do: Map.put(command, "result", record(c.evidence, "linux/isolation.json")),
            else: command
        end)

      replace_environment(c, "linux", Map.put(value, "commands", commands))
      assert {:error, :release_assessment_isolation_invalid} = assess(c, evidence: c.evidence)
    end
  end

  test "source changed study is not counted against the original candidate", c do
    source = Path.join(c.case_root, "changed-source")
    assert {:ok, _} = Reproduction.export(source, source: @root)

    File.write!(
      Path.join(source, "README.md"),
      File.read!(Path.join(source, "README.md")) <> "\nchanged\n"
    )

    File.rm!(Path.join(source, "reproduction-source-manifest.json"))
    frozen = Path.join(c.case_root, "changed-frozen")
    assert {:ok, _} = Reproduction.export(frozen, source: source)
    study = Path.join(c.case_root, "changed-study")
    assert {:ok, _} = ReleaseStudy.prepare(study, source: frozen)
    assert {:error, :release_assessment_study_binding_mismatch} = assess(c, study: study)
  end

  defp assess(c, opts), do: ReleaseAssessment.assess([candidate: c.candidate] ++ opts)
  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  defp write_json(path, value), do: File.write!(path, JSON.encode!(value) <> "\n")

  defp record(root, path),
    do: %{
      "path" => path,
      "sha256" => hash(File.read!(Path.join(root, path))),
      "bytes" => File.stat!(Path.join(root, path)).size
    }

  defp index(c, refs),
    do:
      Map.merge(c.binding, %{
        "schema_version" => 1,
        "kind" => "agent-systems-lab.release-environment-index.v1",
        "archive" => nil,
        "environments" => refs
      })

  defp write_index(c, refs),
    do: write_json(Path.join(c.evidence, "environment-evidence.json"), index(c, refs))

  defp update_index(c, fun),
    do:
      write_json(
        Path.join(c.evidence, "environment-evidence.json"),
        fun.(
          c.evidence
          |> Path.join("environment-evidence.json")
          |> File.read!()
          |> JSON.decode!()
        )
      )

  defp environment(c, type, scope, opts \\ []) do
    File.mkdir_p!(Path.join(c.evidence, type))

    commands = [
      command(c, type, "full", opts[:full_log] || "Result: 10 passed (2 doctests, 8 tests)\n"),
      command(
        c,
        type,
        "memory",
        opts[:memory_log] || "Result: 7 passed (2 doctests, 5 tests), 3 excluded\n"
      )
    ]

    commands =
      if opts[:failed], do: put_in(commands, [Access.at(0), "exit_status"], 1), else: commands

    value =
      Map.merge(c.binding, %{
        "schema_version" => 1,
        "kind" => "agent-systems-lab.release-environment.v1",
        "id" => "synthetic-" <> type,
        "type" => type,
        "scope" => scope,
        "provenance" => %{
          "operator_id" => "synthetic unit fixture, not a real reader",
          "host_id" => "synthetic host",
          "platform" => if(type == "linux", do: "linux", else: "macos"),
          "observed_at_utc" => "2026-10-24T00:00:00Z",
          "self_reported" => true,
          "new_host" => !opts[:warm],
          "runtime_cache_reused" => !!opts[:warm],
          "dependency_cache_reused" => !!opts[:warm],
          "database_reused" => false,
          "inputs" =>
            Enum.map(
              ~w(source otp elixir postgres mix_lock),
              &%{
                "id" => &1,
                "origin" => "synthetic unit fixture",
                "sha256" =>
                  if(&1 == "source",
                    do: c.binding["source_manifest_sha256"],
                    else:
                      if(&1 == "mix_lock",
                        do: hash(File.read!(Path.join(c.source, "mix.lock"))),
                        else: hash(&1)
                      )
                  )
              }
            ),
          "tools" => %{"elixir" => "1.20.4", "otp" => "28.4", "postgres" => "18.6"}
        },
        "excluded_tags" => opts[:excluded_tags] || [],
        "commands" => commands,
        "cleanup" => %{
          "owned_postgres_stopped" => opts[:cleanup] != false,
          "port_released" => true,
          "owned_processes_exited" => true
        }
      })

    write_json(Path.join(c.evidence, type <> "/environment.json"), value)
    write_index(c, [record(c.evidence, type <> "/environment.json")])
  end

  defp command(c, type, id, log, result \\ nil) do
    relative = type <> "/" <> id <> ".log"
    File.write!(Path.join(c.evidence, relative), log)

    %{
      "id" => id,
      "argv" => ReleaseAssessment.policy()["command_argv"][id],
      "exit_status" => 0,
      "log" => record(c.evidence, relative),
      "result" => result
    }
  end

  defp read_environment(c, type),
    do: c.evidence |> Path.join(type <> "/environment.json") |> File.read!() |> JSON.decode!()

  defp replace_environment(c, type, value) do
    write_json(Path.join(c.evidence, type <> "/environment.json"), value)
    write_index(c, [record(c.evidence, type <> "/environment.json")])
  end

  # All records below are inert unit fixtures, never external acceptance evidence.
  defp complete_environment(c, type) do
    environment(c, type, "full")
    value = read_environment(c, type)

    ids =
      ReleaseAssessment.policy()[if(type == "linux", do: "linux_commands", else: "cold_commands")]

    extra =
      for id <- ids -- ~w(full memory) do
        result =
          case id do
            "matrix" ->
              destination = Path.join(c.evidence, type <> "/matrix")
              File.cp_r!(Path.join(c.fixture_root, "technical/matrix"), destination)
              record(c.evidence, type <> "/matrix/report.json")

            "isolation" ->
              relative = type <> "/isolation.json"
              write_json(Path.join(c.evidence, relative), synthetic_isolation())
              record(c.evidence, relative)

            _ ->
              nil
          end

        command(
          c,
          type,
          id,
          "synthetic execution log; no command was actually executed\n",
          result
        )
      end

    replace_environment(c, type, Map.update!(value, "commands", &(&1 ++ extra)))
  end

  defp synthetic_isolation do
    probes =
      Enum.map(
        ~w(controlled_file outside_read outside_write symlink_read outside_link executable_link network fork_denied spawn_denied setsid_denied file_size file_descriptors cpu output wall cancel caller_crash unregistered_command),
        fn id ->
          base = %{
            "case" => id,
            "passed" => true,
            "status" => "succeeded",
            "result" => %{
              "cleanup" => %{
                "guardian_exited" => true,
                "process_group_gone" => true,
                "target_exited" => true
              }
            }
          }

          extra =
            case id do
              "controlled_file" ->
                %{"controlled_file_bytes" => 19}

              name when name in ~w(outside_read outside_write symlink_read) ->
                %{"permission_denied" => true, "canary_unchanged" => true}

              name when name in ~w(outside_link executable_link) ->
                %{"hardlink_denied" => true, "alias_absent" => true}

              "network" ->
                %{
                  "baseline_connected" => true,
                  "sandbox_connected" => false,
                  "permission_denied" => true
                }

              name when name in ~w(fork_denied spawn_denied setsid_denied) ->
                %{"creation_or_escape_denied" => true, "max_target_processes" => 1}

              "file_size" ->
                %{
                  "hard_limit_observed" => true,
                  "actual_file_bytes" => 4096,
                  "max_file_bytes" => 4096
                }

              "file_descriptors" ->
                %{"hard_limit_observed" => true, "opened" => 61, "fd_limit" => 64}

              "cpu" ->
                %{"status" => "resource_limit", "hard_limit_observed" => true}

              "output" ->
                %{
                  "status" => "output_limit",
                  "captured_bytes" => 4096,
                  "max_output_bytes" => 4096
                }

              "wall" ->
                %{"status" => "timed_out", "wall_time_ms" => 100}

              "cancel" ->
                %{"status" => "cancelled", "identity_nonce_verified" => true}

              "caller_crash" ->
                %{
                  "guardian_exited" => true,
                  "target_exited" => true,
                  "identity_nonce_verified" => true
                }

              "unregistered_command" ->
                %{"status" => "rejected", "command_started" => false}
            end

          probe = Map.merge(base, extra)

          if id in ~w(caller_crash unregistered_command),
            do: Map.delete(probe, "result"),
            else:
              put_in(
                probe,
                ["result"],
                Map.merge(probe["result"], %{
                  "backend" => "linux.synthetic_unit_fixture",
                  "status" => probe["status"]
                })
              )
        end
      )

    %{
      "schema_version" => 1,
      "all_passed" => true,
      "architecture" => "synthetic-fixture",
      "backend" => "linux.synthetic_unit_fixture",
      "backend_enforced" => true,
      "expected_probe_count" => 18,
      "failed_probe" => nil,
      "platform" => "{:unix, :linux}",
      "probe_count" => 18,
      "probes" => probes,
      "process_scope" => "synthetic unit fixture only",
      "unsupported_capabilities" => []
    }
  end

  defp human_study(c) do
    study = Path.join(c.case_root, "human-study")
    {:ok, prepared} = ReleaseStudy.prepare(study, source: c.source)

    for number <- 1..3 do
      id = "R0" <> to_string(number)

      feedback =
        ReleaseStudy.template(prepared.protocol)
        |> Map.merge(%{
          "reader_id" => id,
          "independent_of_authors" => true,
          "completed" => true,
          "started_at_utc" => "2026-10-24T00:00:00Z",
          "finished_at_utc" => "2026-10-24T01:00:00Z",
          "chapters" => ~w(ch02 ch05 ch08 ch14 ch16 ch20),
          "reproduction" => %{
            "status" => "passed",
            "environment" => "fresh_workspace",
            "commands" =>
              Enum.map(
                ~w(verify p1 history recover fence upgrade),
                &%{
                  "id" => &1,
                  "outcome" => "passed",
                  "evidence" => "synthetic test fixture only, never actual acceptance"
                }
              )
          }
        })

      file = Path.join(c.case_root, id <> ".json")
      write_json(file, feedback)
      assert {:ok, _} = ReleaseStudy.add_feedback(study, file)
    end

    study
  end
end
