defmodule AgentSystemsLab.CandidatePackageTest do
  use ExUnit.Case, async: true

  Code.require_file("../support/frozen_matrix_fixture.exs", __DIR__)

  alias AgentSystemsLab.{CandidatePackage, FrozenFaultMatrix, Reproduction}

  @root Path.expand("../..", __DIR__)

  setup_all do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "candidate-fixtures-" <> Ecto.UUID.generate())
    File.mkdir!(root)
    source = Path.join(root, "source")
    assert {:ok, exported} = Reproduction.export(source, source: @root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{fixture_root: root, source: source, source_sha: hash(File.read!(exported.manifest_path))}
  end

  setup context do
    root = Path.join(context.fixture_root, Ecto.UUID.generate())
    File.mkdir!(root)
    evidence = Path.join(root, "evidence")
    File.mkdir!(evidence)
    index = evidence_fixture(evidence, context.source_sha)
    %{root: root, evidence: evidence, index: index, output: Path.join(root, "candidate")}
  end

  test "a complete candidate binds source, every evidence file and pending release gates", c do
    assert {:ok, built} = build(c)
    assert built.manifest["technical_candidate_ready"]
    refute built.manifest["release_ready"]
    assert built.manifest["external_humans"] == 0
    assert built.manifest["linux_validation"] == "pending"
    assert built.manifest["project_version"] == "0.1.0-dev"
    assert built.manifest["candidate_label"] == "v0.1.0-rc.1"
    assert built.manifest["candidate_label_kind"] == "local_manifest_label_not_git_tag"
    assert built.manifest["source_manifest_sha256"] == c.source_sha

    assert built.manifest["teaching_material"] == %{
             "courses" => 12,
             "chapter_cards" => 30,
             "chapter_drafts" => 6,
             "labs" => 23
           }

    assert {:ok, ^built} = CandidatePackage.verify(c.output)
    refute File.exists?(Path.join(c.output, ".runtime"))
    refute File.exists?(Path.join(c.output, "deps"))

    assert File.read!(Path.join(c.output, "candidate-evidence/matrix/raw.json")) =~
             "synthetic_unit_test"
  end

  test "changed evidence is rejected even when the successful test footer survives", c do
    assert {:ok, _} = build(c)

    File.write!(
      Path.join(c.output, "candidate-evidence/full.log"),
      "changed\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    assert {:error, _} = CandidatePackage.verify(c.output)
  end

  test "missing catalog files and omitted referenced matrix evidence fail closed", c do
    File.rm!(Path.join(c.evidence, "matrix/raw.json"))
    assert {:error, _} = build(c)
    refute File.exists?(c.output)
    evidence_fixture(c.evidence, c.source_sha)

    update_index(c, fn index ->
      Map.update!(
        index,
        "files",
        &Enum.reject(&1, fn entry -> entry["path"] == "matrix/rows/F01/1/observations.json" end)
      )
    end)

    assert {:error, _} = build(c)
    refute File.exists?(Path.join(c.output, "candidate-manifest.json"))
  end

  test "partial matrix is refused even with a valid new hash catalog", c do
    alter_matrix(c, &Map.put(&1, "complete", false))
    assert {:error, _} = build(c)
    refute File.exists?(c.output)
  end

  test "nineteen repetitions cannot be presented as the twenty repetition gate", c do
    alter_matrix(c, fn matrix ->
      Map.update!(matrix, "rows", fn [first | rest] ->
        [Map.put(first, "probes", Enum.take(first["probes"], 19)) | rest]
      end)
    end)

    assert {:error, _} = build(c)
  end

  test "a frozen source hash from another candidate is refused", c do
    update_index(c, &Map.put(&1, "source_manifest_sha256", String.duplicate("a", 64)))
    assert {:error, :candidate_source_binding_mismatch} = build(c)
    refute File.exists?(Path.join(c.output, "candidate-manifest.json"))
  end

  test "a failed run cannot be hidden behind a copied passing footer", c do
    File.write!(
      Path.join(c.evidence, "full.log"),
      "  1) a failed test\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    reindex(c)
    assert {:error, :candidate_regression_evidence_invalid} = build(c)
  end

  test "claimed counts must match actual regression footers and exclusions", c do
    update_index(c, &put_in(&1, ["full", "passed"], 11))
    assert {:error, :candidate_regression_evidence_invalid} = build(c)
    evidence_fixture(c.evidence, c.source_sha)

    File.write!(
      Path.join(c.evidence, "memory.log"),
      "Result: 7 passed (2 doctests, 5 tests), 2 excluded\n"
    )

    reindex(c)
    update_index(c, &put_in(&1, ["memory", "excluded"], 2))
    assert {:error, _} = build(c)
  end

  test "commands in inert logs never execute and argv cannot replace the fixed command", c do
    sentinel = Path.join(c.root, "executed")

    File.write!(
      Path.join(c.evidence, "full.log"),
      "$(touch #{sentinel})\nResult: 10 passed (2 doctests, 8 tests)\n"
    )

    reindex(c)
    assert {:ok, _} = build(c)
    refute File.exists?(sentinel)
    update_index(c, &put_in(&1, ["full", "argv"], ["touch", sentinel]))

    assert {:error, :candidate_regression_evidence_invalid} =
             CandidatePackage.build(c.output <> "-bad", source: c.source, evidence: c.evidence)

    refute File.exists?(sentinel)
  end

  test "unknown index fields and synthetic human release assertions are rejected", c do
    update_index(c, &Map.put(&1, "release_ready", true))
    assert {:error, :candidate_invalid_evidence_index} = build(c)
    evidence_fixture(c.evidence, c.source_sha)
    update_index(c, &Map.put(&1, "human_readers", 3))
    assert {:error, :candidate_invalid_evidence_index} = build(c)
  end

  test "symlink and hardlink evidence cannot pass bounded regular-file reads", c do
    path = Path.join(c.evidence, "full.log")
    saved = Path.join(c.root, "saved.log")
    File.rename!(path, saved)
    File.ln_s!(saved, path)
    assert {:error, _} = build(c)
    File.rm!(path)
    File.ln!(saved, path)
    assert {:error, _} = build(c)
    refute File.exists?(c.output)
  end

  test "unexpected package files and manifest mode changes are refused", c do
    assert {:ok, _} = build(c)
    extra = Path.join(c.output, ".env")
    File.write!(extra, "DO_NOT_SHIP=fixture")
    assert {:error, _} = CandidatePackage.verify(c.output)
    File.rm!(extra)
    File.chmod!(Path.join(c.output, "candidate-manifest.json"), 0o644)
    assert {:error, _} = CandidatePackage.verify(c.output)
  end

  test "existing outputs are never overwritten", c do
    File.mkdir!(c.output)
    path = Path.join(c.output, "keep")
    File.write!(path, "keep")
    assert {:error, :reproduction_output_exists} = build(c)
    assert File.read!(path) == "keep"
  end

  test "a source directory alias cannot create a nested package", c do
    output = Path.join(c.source, "lib/candidate-output")

    assert {:error, :reproduction_invalid_destination} =
             CandidatePackage.build(output, source: c.source, evidence: c.evidence)

    refute File.exists?(output)
    alias_path = Path.join(c.source, "LIB/candidate-output")

    assert {:error, _} =
             CandidatePackage.build(alias_path, source: c.source, evidence: c.evidence)

    refute File.exists?(output)
  end

  test "changing source mode invalidates the exact exported teaching material", c do
    assert {:ok, _} = build(c)
    path = Path.join(c.output, "lib/agent_systems_lab/candidate_package.ex")
    original = Bitwise.band(File.stat!(path).mode, 0o777)
    File.chmod!(path, Bitwise.bxor(original, 0o100))
    assert {:error, _} = CandidatePackage.verify(c.output)
  end

  test "unsafe evidence paths, duplicate entries and oversized indexes are refused", c do
    update_index(c, fn index ->
      Map.update!(index, "files", fn [first | rest] ->
        [Map.put(first, "path", "../escape.log") | rest]
      end)
    end)

    assert {:error, :candidate_invalid_evidence_index} = build(c)
    evidence_fixture(c.evidence, c.source_sha)

    update_index(c, fn index ->
      Map.update!(index, "files", fn [first | _] = files -> [first | files] end)
    end)

    assert {:error, :candidate_invalid_evidence_index} = build(c)
    File.write!(Path.join(c.evidence, "index.json"), :binary.copy("x", 16_777_217))
    assert {:error, _} = build(c)
    refute File.exists?(c.output)
  end

  defp build(c), do: CandidatePackage.build(c.output, source: c.source, evidence: c.evidence)

  # These inert synthetic records exercise the verifier. They are unit fixtures,
  # never production acceptance evidence, and invoke no fault/runtime boundary.
  defp evidence_fixture(root, source_sha) do
    File.rm_rf!(Path.join(root, "matrix"))
    File.mkdir_p!(Path.join(root, "matrix"))
    synthetic = AgentSystemsLab.Test.FrozenMatrixFixture.components(Path.join(root, "matrix"))
    File.write!(Path.join(root, "full.log"), "Result: 10 passed (2 doctests, 8 tests)\n")

    File.write!(
      Path.join(root, "memory.log"),
      "Result: 7 passed (2 doctests, 5 tests), 3 excluded\n"
    )

    File.write!(
      Path.join(root, "matrix/raw.json"),
      JSON.encode!(%{"synthetic_unit_test" => true})
    )

    rows =
      for {row, number} <- Enum.with_index(FrozenFaultMatrix.plan()["rows"], 1) do
        Map.merge(row, %{
          "repetitions" => 20,
          "passed" => true,
          "probes" =>
            for(
              repetition <- 1..20,
              do: fixture_probe(root, row["id"], number, repetition)
            )
        })
      end

    matrix = %{
      "schema_version" => 1,
      "kind" => "v0.1-frozen-fault-matrix",
      "required_repetitions" => 20,
      "complete" => true,
      "all_passed" => true,
      "failure" => nil,
      "namespace" => "synthetic-unit-fixture",
      "rows" => rows,
      "components" => synthetic.components,
      "totals" => %{
        "completed_rows" => 12,
        "completed_repetitions" => 240,
        "required_repetitions" => 240
      },
      "scope" => "Synthetic unit-test fixture; not actual acceptance evidence",
      "created_at_utc" => "2026-10-23T00:00:00Z"
    }

    File.write!(Path.join(root, "matrix/report.json"), JSON.encode!(matrix))

    files =
      Enum.map(~w(full.log memory.log matrix/raw.json matrix/report.json), &record(root, &1)) ++
        Enum.map(synthetic.files, &record(root, "matrix/" <> &1)) ++
        Enum.flat_map(rows, fn row ->
          Enum.flat_map(row["probes"], fn probe ->
            Enum.map(
              probe["evidence"],
              &Map.update!(&1, "path", fn path -> "matrix/" <> path end)
            )
          end)
        end)

    regression = fn path, passed, tests, excluded, argv ->
      Map.merge(Map.take(record(root, path), ~w(path sha256)), %{
        "passed" => passed,
        "doctests" => 2,
        "tests" => tests,
        "excluded" => excluded,
        "exit_status" => 0,
        "argv" => argv
      })
    end

    index = %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.frozen-evidence.v1",
      "source_manifest_sha256" => source_sha,
      "full" => regression.("full.log", 10, 8, 0, ["./scripts/mix", "check"]),
      "memory" => regression.("memory.log", 7, 5, 3, ["./scripts/mix", "test"]),
      "matrix" => Map.take(record(root, "matrix/report.json"), ~w(path sha256)),
      "files" => files,
      "human_readers" => 0,
      "linux_validation" => "pending"
    }

    File.write!(Path.join(root, "index.json"), JSON.encode!(index))
    index
  end

  defp fixture_probe(root, row_id, number, repetition) do
    relative = "rows/#{row_id}/#{repetition}/observations.json"
    target = Path.join(root, "matrix/" <> relative)
    File.mkdir_p!(Path.dirname(target))

    File.write!(
      target,
      JSON.encode!(%{
        "row" => row_id,
        "run_id" => "unit-#{number}-#{repetition}",
        "repetition" => repetition,
        "observations" => observations(number)
      })
    )

    item = record(root, "matrix/" <> relative) |> Map.put("path", relative)

    %{
      "repetition" => repetition,
      "passed" => true,
      "run_id" => "unit-#{number}-#{repetition}",
      "observations" => observations(number),
      "evidence" => [item]
    }
  end

  defp observations(1),
    do: %{
      "acknowledged" => false,
      "exit_reason" => "killed",
      "at_barrier" => %{"runs" => 1, "events" => 1, "intents" => 1, "pending" => 1},
      "after_kill" => %{"runs" => 1, "events" => 1, "intents" => 1, "pending" => 1},
      "persisted_seq" => 1,
      "recovered_seq" => 2,
      "recovered_kind" => "tool"
    }

  defp observations(2),
    do: %{
      "notification_sent" => false,
      "wake_requests" => 0,
      "scans_before_commit" => 1,
      "scans_after_completion" => 2,
      "status" => "succeeded",
      "effects" => 0
    }

  defp observations(3),
    do: %{
      "kill_count" => 1,
      "signal" => "SIGKILL",
      "owned_pid" => 1,
      "exit_observed" => true,
      "effects_before_recovery" => 0,
      "effects" => 1,
      "status" => "succeeded"
    }

  defp observations(4),
    do: %{
      "modes" => [
        mode("idempotent", "succeeded"),
        mode("unqueryable", "blocked") |> Map.put("safe_mode", "manual")
      ]
    }

  defp observations(5),
    do: %{
      "fresh_application" => true,
      "previous_application_killed" => true,
      "signal" => "SIGKILL",
      "status" => "succeeded",
      "effects_before" => 1,
      "effects_after" => 1,
      "tool_attempts_before" => 1,
      "tool_attempts_after" => 1,
      "state_sha256" => hash("state")
    }

  defp observations(6),
    do: %{
      "signals" => ["SIGSTOP", "SIGCONT"],
      "whole_beam_paused" => true,
      "old_generation" => 1,
      "successor_generation" => 2,
      "successor_facts_unchanged" => true,
      "original_executor_fenced" => true,
      "child_exit_status" => 0,
      "old_attempts" => [%{"fenced" => true}]
    }

  defp observations(7), do: concurrent(100, 0)
  defp observations(8), do: concurrent(50, 50)

  defp observations(9),
    do: %{
      "status" => "failed",
      "reason" => "retry_exhausted",
      "model_attempts" => 3,
      "persisted_attempts" => 3,
      "max_attempts" => 3,
      "resume_spent_more" => false,
      "elapsed_ms" => 40
    }

  defp observations(10),
    do: %{
      "original_subject_hash" => hash("one"),
      "changed_subject_hash" => hash("two"),
      "old_approval_present" => true,
      "changed_approval_present" => false,
      "generation_before" => 1,
      "generation_after" => 2,
      "release_rejected" => true,
      "published" => false
    }

  defp observations(11),
    do: %{
      "database_error_observed" => true,
      "successor_facts_unchanged" => true,
      "effects" => 1,
      "status" => "succeeded"
    }

  defp observations(12),
    do:
      Map.new(
        ~w(original_rebuild_passed incompatible_rebuild_rejected format_rejected codec_rejected compatibility_rejected),
        &{&1, true}
      )
      |> Map.merge(%{
        "supported_schema" => 1,
        "incompatible_schema" => 99,
        "durable_event_rejected" => true,
        "restored_state_unchanged" => true,
        "original_state_sha256" => hash("state")
      })

  defp mode(name, status),
    do: %{
      "mode" => name,
      "effects" => 1,
      "status" => status,
      "prepared_receipt_absent" => true,
      "reply_lost" => true,
      "caller_killed" => true
    }

  defp concurrent(successes, conflicts),
    do: %{
      "concurrent_submissions" => 100,
      "barrier_ready" => 100,
      "barrier_released" => 100,
      "successful_deliveries" => successes,
      "explicit_conflicts" => conflicts,
      "operations" => 1,
      "effects" => 1,
      "attempts" => successes,
      "same_logical_result" => true,
      "original_input_sha256" => hash("input")
    }

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp record(root, path),
    do: %{
      "path" => path,
      "sha256" => hash(File.read!(Path.join(root, path))),
      "bytes" => File.stat!(Path.join(root, path)).size
    }

  defp update_index(c, fun),
    do:
      File.write!(
        Path.join(c.evidence, "index.json"),
        c.evidence
        |> Path.join("index.json")
        |> File.read!()
        |> JSON.decode!()
        |> fun.()
        |> JSON.encode!()
      )

  defp reindex(c) do
    update_index(c, fn index ->
      files = Enum.map(index["files"], &record(c.evidence, &1["path"]))

      Enum.reduce(~w(full memory matrix), Map.put(index, "files", files), fn key, current ->
        path = current[key]["path"]
        put_in(current, [key, "sha256"], record(c.evidence, path)["sha256"])
      end)
    end)
  end

  defp alter_matrix(c, fun) do
    path = Path.join(c.evidence, "matrix/report.json")
    File.write!(path, path |> File.read!() |> JSON.decode!() |> fun.() |> JSON.encode!())
    reindex(c)
  end
end
