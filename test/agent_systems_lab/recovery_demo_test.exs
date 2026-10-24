defmodule AgentSystemsLab.RecoveryDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{RecoveryDemo, Repo}
  @moduletag :database

  test "a fresh VM resumes after repeated effect crashes using only persisted policy" do
    root =
      Path.join(File.cwd!(), "artifacts/recovery-demo-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, result} = RecoveryDemo.run(output: root, repetitions: 1)
    report = result.report

    ids =
      Enum.map(report["fault_probes"], & &1["run_id"]) ++
        [report["query_reconciliation"]["run_id"], report["ambiguous_file"]["run_id"]]

    on_exit(fn -> Enum.each(ids, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1])) end)
    assert report["all_passed"]
    assert report["fault_probe_count"] == 5
    assert report["kill_count"] == 7
    assert report["duplicate_mock_effects"] == 0
    fresh = Enum.find(report["fault_probes"], & &1["fresh_vm"])
    assert fresh["crashed_again_during_recovery"]
    assert fresh["effects"] == 1
    assert fresh["attempts"] == 3
    assert fresh["model_attempts"] == 2
    assert fresh["recorded_model_results"] == 2
    assert File.read!(Path.join(root, "fresh-vm.log")) =~ "RECOVERY_AUDIT="
    assert report["query_reconciliation"]["effects"] == 1
    assert report["ambiguous_file"]["automatic_reconcile"] == "reconciliation_required"
    assert report["ambiguous_file"]["operator_evidence_saved"]
    assert {:error, {:output_exists, ^root}} = RecoveryDemo.run(output: root)
  end
end
