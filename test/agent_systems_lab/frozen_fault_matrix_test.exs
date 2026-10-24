defmodule AgentSystemsLab.FrozenFaultMatrixTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{FrozenFaultMatrix, Repo}

  test "the plan fixes all twelve roadmap faults and twenty actual repetitions without starting services" do
    plan = FrozenFaultMatrix.plan()
    assert plan["required_repetitions"] == 20

    assert Enum.map(plan["rows"], & &1["id"]) ==
             for(n <- 1..12, do: "F" <> String.pad_leading(to_string(n), 2, "0"))

    assert Enum.all?(plan["rows"], &(&1["required_repetitions"] == 20))
    assert Enum.map(plan["components"], & &1["windows"]) == [16, 5, 5]
    assert Enum.at(plan["rows"], 6)["name"] == "same_operation_100"
  end

  test "options cannot reduce repetitions, inject a runner or use unsafe paths" do
    for options <- [
          nil,
          :bad,
          [],
          [output: "/private/tmp/unused", repetitions: 1],
          [output: "relative"],
          [output: "/"],
          [output: "/private/tmp/../tmp/unsafe"],
          [output: <<0>>],
          [output: 1],
          [output: "/private/tmp/unused", output: "/private/tmp/unused2"],
          [output: "/private/tmp/unused", on_progress: fn -> :ok end]
        ] do
      assert {:error, _} = FrozenFaultMatrix.run(options)
    end

    assert {:error, :invalid_diagnostic_probe} =
             FrozenFaultMatrix.check_probe("F06", "/private/tmp/unused")
  end

  test "partial, copied and unsupported report envelopes cannot satisfy acceptance" do
    for report <- [
          nil,
          %{},
          %{"schema_version" => 1, "complete" => true, "all_passed" => true},
          %{"schema_version" => 2, "rows" => List.duplicate(%{"passed" => true}, 12)}
        ] do
      assert {:error, :invalid_frozen_matrix_report} = FrozenFaultMatrix.validate_report(report)
    end
  end

  test "verification rejects symlink ancestors, missing and oversized reports without effects" do
    directory = output("verify")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, _} = FrozenFaultMatrix.verify(directory)
    File.write!(Path.join(directory, "report.json"), String.duplicate("x", 4 * 1024 * 1024 + 1))
    assert {:error, _} = FrozenFaultMatrix.verify(directory)
    File.rm!(Path.join(directory, "report.json"))
    actual = Path.join(directory, "actual")
    File.mkdir!(actual)
    File.ln_s!(actual, Path.join(directory, "linked"))

    assert {:error, :unsafe_matrix_directory} =
             FrozenFaultMatrix.verify(Path.join(directory, "linked"))
  end

  test "an existing diagnostic destination is never overwritten" do
    directory = output("existing")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep.txt"), "retain")
    on_exit(fn -> File.rm_rf!(directory) end)

    if Application.get_env(:agent_systems_lab, :database_enabled, true) do
      assert {:error, :matrix_output_exists} = FrozenFaultMatrix.check_probe("F12", directory)
    else
      assert {:error, :database_required} = FrozenFaultMatrix.check_probe("F12", directory)
    end

    assert File.read!(Path.join(directory, "keep.txt")) == "retain"
  end

  test "missing or noninteger counters cannot pass through Erlang term ordering" do
    values = [nil, "2", :unknown, 2.0, %{}]

    for value <- values do
      assert {:error, :invalid_fault_observations} =
               FrozenFaultMatrix.validate_observations(
                 "F02",
                 %{
                   "notification_sent" => false,
                   "wake_requests" => 0,
                   "scans_before_commit" => 1,
                   "scans_after_completion" => value,
                   "status" => "succeeded",
                   "effects" => 0
                 }
               )

      assert {:error, :invalid_fault_observations} =
               FrozenFaultMatrix.validate_observations(
                 "F06",
                 %{
                   "signals" => ["SIGSTOP", "SIGCONT"],
                   "whole_beam_paused" => true,
                   "old_generation" => 1,
                   "successor_generation" => value,
                   "successor_facts_unchanged" => true,
                   "original_executor_fenced" => true,
                   "child_exit_status" => 0,
                   "old_attempts" => [%{"fenced" => true}]
                 }
               )

      assert {:error, :invalid_fault_observations} =
               FrozenFaultMatrix.validate_observations(
                 "F10",
                 %{
                   "original_subject_hash" => String.duplicate("a", 64),
                   "changed_subject_hash" => String.duplicate("b", 64),
                   "old_approval_present" => true,
                   "changed_approval_present" => false,
                   "generation_before" => 1,
                   "generation_after" => value,
                   "release_rejected" => true,
                   "published" => false
                 }
               )
    end

    assert {:error, :invalid_fault_observations} =
             FrozenFaultMatrix.validate_observations("F07", %{})
  end

  @tag :database
  @tag timeout: 180_000
  test "fixed diagnostic probes exercise each new gap using real durable facts and owned OS processes" do
    directory = output("gaps")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for row <- ~w(F01 F02 F03 F04 F05 F07 F08 F09 F10 F12) do
      assert {:ok, result} = FrozenFaultMatrix.check_probe(row, Path.join(directory, row))
      assert result["row"] == row
      assert result["frozen_matrix_passed"] == false
      assert {:error, :invalid_frozen_matrix_report} = FrozenFaultMatrix.validate_report(result)
      id = result["run_id"]
      on_exit(fn -> cleanup(id) end)

      Enum.each(result["evidence"], fn entry ->
        bytes = File.read!(Path.join([directory, row, entry["path"]]))
        assert byte_size(bytes) == entry["bytes"]
        assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == entry["sha256"]
      end)
    end
  end

  defp output(label),
    do:
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "frozen-matrix-test-#{label}-#{System.unique_integer([:positive])}"
      )

  defp cleanup(id) do
    workflow_id = AgentSystemsLab.Approvals.Plan.workflow_id(id, "r1")

    children =
      Repo.query!("SELECT run_id FROM lab_workflow_nodes WHERE workflow_id=$1", [workflow_id]).rows
      |> List.flatten()

    Repo.query!("DELETE FROM lab_approval_cases WHERE id=$1", [id])
    Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [workflow_id])
    Enum.each(children, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1]))

    Repo.query!("DELETE FROM lab_runs WHERE id=$1 OR id=$2 OR id=$3", [
      id,
      id <> "-idempotent",
      id <> "-unqueryable"
    ])
  end
end
