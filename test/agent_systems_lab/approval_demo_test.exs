defmodule AgentSystemsLab.ApprovalDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{ApprovalDemo, Approvals, Repo}
  alias AgentSystemsLab.Approvals.Coordinator

  test "invalid options and controller authority fail before execution" do
    for options <- [
          nil,
          :bad,
          [1],
          [output: 1],
          [output: ""],
          [output: <<255>>],
          [output: <<0>>],
          [on_progress: fn -> :ok end],
          [extra: true],
          [output: "a", output: "b"]
        ] do
      assert {:error, :invalid_approval_demo_options} = ApprovalDemo.run(options)
    end

    for options <- [
          [],
          [case_id: ""],
          [case_id: String.duplicate("x", 129)],
          [case_id: "test", scheduler_options: [queue: "bypass"]],
          [case_id: "test", scheduler_options: [recovery_options: [workspace: "/"]]]
        ] do
      assert {:error, :invalid_approval_coordinator_options} = Coordinator.start_link(options)
    end

    assert length(ApprovalDemo.cases()) == 11
  end

  @tag :database
  test "old evidence and global consumers cannot be overwritten" do
    output = output("protected")
    File.mkdir!(output)
    File.write!(Path.join(output, "prior"), "prior evidence")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = ApprovalDemo.run(output: output)
    assert File.ls!(output) == ["prior"]
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = ApprovalDemo.run(output: output)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end
  end

  @tag :database
  test "starting failure preserves namespace and explicitly incomplete report" do
    output = output("failure")
    on_exit(fn -> cleanup(output) end)

    assert {:error, {:approval_verification_failed, result}} =
             ApprovalDemo.run(
               output: output,
               on_progress: fn _ -> raise "owned start failure" end
             )

    refute result.report["all_passed"]
    assert result.report["case_count"] == 0
    assert result.report["expected_case_count"] == 11
    assert result.report["failed_case"]["reason"] =~ "owned start failure"
    assert read_report(output) == result.report
  end

  @tag :database
  @tag timeout: 120_000
  test "real approval, mutation, pause and rework windows preserve existing execution facts" do
    output = output("real")
    on_exit(fn -> cleanup(output) end)
    result = ApprovalDemo.run(output: output)
    assert match?({:ok, _}, result), failure(result)
    {:ok, result} = result
    report = result.report
    assert report["all_passed"]
    assert report["case_count"] == report["expected_case_count"]
    assert length(report["case_ids"]) == 13
    cases = Map.new(report["cases"], &{&1["case"], &1})
    assert cases["hash_bound_release"]["immutable_bytes"] == "PATCH_V1"
    refute cases["hash_bound_release"]["published"]
    assert cases["changed_artifact_revokes"]["old_approval_invalidated"]
    assert cases["baseline_conflict"]["baseline_conflict_blocked_release"]
    assert cases["bounded_rework"]["prior_spending_unchanged"]

    assert cases["bounded_rework"]["original_deadline_at_ms"] ==
             cases["bounded_rework"]["final_deadline_at_ms"]

    assert cases["pause_restart"]["old_claim_revoked"]
    assert cases["pause_restart"]["same_workflow_id"]
    assert cases["pause_effect_unknown"]["effects"] == 1
    assert cases["human_request_guard"]["decision_count"] == 1
    assert length(cases["approval_commit_windows"]["windows"]) == 2
    assert length(cases["rework_commit_windows"]["windows"]) == 2
    assert cases["cancel_after_approval"]["release_denied"]

    for row <- report["cases"], evidence <- row["evidence"] do
      assert evidence["audit"]["all_passed"]

      assert map_size(evidence["audit"]["effect_boundary_calls"]) ==
               length(AgentSystemsLab.Approvals.Audit.boundaries())

      assert Enum.all?(evidence["audit"]["effect_boundary_calls"], fn {_, count} -> count == 0 end)

      saved =
        output
        |> Path.join(row["case"])
        |> Path.join(evidence["path"])
        |> File.read!()
        |> JSON.decode!()

      assert saved["approval_case"]["id"] == evidence["case_id"]
      assert length(saved["approval_case"]["events"]) > 0
    end

    assert read_report(output) == report
  end

  defp failure({:error, {:approval_verification_failed, result}}),
    do: inspect(result.report["failed_case"], limit: :infinity)

  defp failure(other), do: inspect(other, limit: 5)

  defp cleanup(output) do
    case File.read(Path.join(output, "manifest.json")) do
      {:ok, data} ->
        namespace = JSON.decode!(data)["namespace"]

        ids =
          Repo.query!("SELECT id FROM lab_approval_cases WHERE id LIKE $1", [namespace <> "%"])

        for [id] <- ids.rows do
          case Approvals.load(id) do
            {:ok, view} ->
              for round <- view.rounds do
                name = AgentSystemsLab.Workflows.Store.queue_name(round.workflow_id)
                Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [round.workflow_id])
                Repo.query!("DELETE FROM lab_queues WHERE name=$1", [name])
              end

            _ ->
              :ok
          end
        end

        Repo.query!("DELETE FROM lab_approval_cases WHERE id LIKE $1", [namespace <> "%"])

      _ ->
        :ok
    end

    File.rm_rf!(output)
  end

  defp output(label),
    do:
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "lab-approval-demo-#{label}-#{Ecto.UUID.generate()}"
      )

  defp read_report(output),
    do: output |> Path.join("report.json") |> File.read!() |> JSON.decode!()
end
