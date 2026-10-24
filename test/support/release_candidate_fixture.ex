defmodule AgentSystemsLab.Test.ReleaseCandidateFixture do
  alias AgentSystemsLab.FrozenFaultMatrix
  # These inert synthetic records exercise the verifier. They are unit fixtures,
  # never production acceptance evidence, and invoke no fault/runtime boundary.
  def evidence_fixture(root, source_sha) do
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
end
