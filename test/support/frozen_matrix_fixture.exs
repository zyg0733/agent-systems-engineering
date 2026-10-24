defmodule AgentSystemsLab.Test.FrozenMatrixFixture do
  @moduledoc "Synthetic parser fixtures only. These bytes never represent actual acceptance."
  alias AgentSystemsLab.{DatabaseFaultDemo, FencingDemo, P2Verification}

  def components(root) do
    records =
      for {id, module, repetitions} <- [
            {"p2", P2Verification, 20},
            {"fencing", FencingDemo, 20},
            {"database-1", DatabaseFaultDemo, 10},
            {"database-2", DatabaseFaultDemo, 10}
          ] do
        probes =
          for fault <- module.cases(), repetition <- 1..repetitions do
            probe = %{
              "fault" => fault,
              "repetition" => repetition,
              "run_id" => "synthetic-#{id}-#{fault}-#{repetition}",
              "status" => "succeeded",
              "state_matches_history" => true,
              "effects" => 1,
              "confirmed_receipts_preserved" => true,
              "stale_claim_rejected" => true,
              "kill_count" => 1,
              "successor_facts_unchanged" => true,
              "child_exit_status" => 0,
              "signals" => ["SIGSTOP", "SIGCONT"],
              "original_executor_fenced" => true,
              "old_attempts" => [%{"fenced" => true}],
              "database_error_observed" => true,
              "synthetic_unit_test" => true
            }

            directory = Path.join([root, id, fault, to_string(repetition)])
            File.mkdir_p!(directory)
            write(Path.join(directory, "summary.json"), probe)

            write(Path.join(directory, "cleanup.json"), %{
              "exit_observed" => true,
              "exit_status" => 0,
              "proxy_stopped" => true,
              "synthetic_unit_test" => true
            })

            probe
          end

        report = %{
          "schema_version" => 1,
          "all_passed" => true,
          "failed_probe" => nil,
          "expected_probe_count" => length(probes),
          "fault_probe_count" => length(probes),
          "duplicate_mock_effects" => 0,
          "fault_windows" => 16,
          "lost_confirmed_receipts" => 0,
          "stale_token_overwrites" => 0,
          "stale_generation_overwrites" => 0,
          "sigstop_count" => 100,
          "sigcont_count" => 100,
          "fault_probes" => probes,
          "synthetic_unit_test" => true
        }

        relative = Path.join(id, "report.json")
        write(Path.join(root, relative), report)
        record(root, relative) |> Map.put("id", id)
      end

    %{components: records, files: files(root)}
  end

  def files(root),
    do:
      Path.wildcard(Path.join(root, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

  def record(root, relative) do
    bytes = File.read!(Path.join(root, relative))

    %{
      "path" => relative,
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "bytes" => byte_size(bytes)
    }
  end

  defp write(path, value), do: File.write!(path, JSON.encode!(value) <> "\n")
end
