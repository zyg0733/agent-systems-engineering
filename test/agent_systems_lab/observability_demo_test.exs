defmodule AgentSystemsLab.ObservabilityDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Approvals, Observability, ObservabilityDemo, Repo}

  setup do
    if is_nil(Process.whereis(AgentSystemsLab.Observability.Buffer)),
      do: assert({:ok, _} = Observability.restart())

    :ok
  end

  test "invalid options fail before creating evidence or executing work" do
    for opts <- [
          nil,
          :bad,
          [1],
          [output: 1],
          [output: ""],
          [output: <<255>>],
          [output: <<0>>],
          [extra: true],
          [on_progress: fn -> :ok end],
          [output: "a", output: "b"]
        ] do
      assert {:error, :invalid_observability_demo_options} = ObservabilityDemo.run(opts)
    end

    assert length(ObservabilityDemo.cases()) == 8
  end

  @tag :database
  test "existing evidence and active global consumers are protected" do
    output = output("protected")
    File.mkdir!(output)
    File.write!(Path.join(output, "prior"), "keep")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = ObservabilityDemo.run(output: output)
    assert File.read!(Path.join(output, "prior")) == "keep"
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = ObservabilityDemo.run(output: output)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end
  end

  @tag :database
  test "a failed verifier leaves an explicitly incomplete, readable report" do
    output = output("failed")
    on_exit(fn -> cleanup(output) end)

    assert {:error, {:observability_verification_failed, result}} =
             ObservabilityDemo.run(
               output: output,
               on_progress: fn _ -> raise "owned verifier failure" end
             )

    refute result.report["all_passed"]
    assert result.report["case_count"] == 0
    assert result.report["expected_case_count"] == 8
    assert result.report["failed_case"]["reason"] =~ "owned verifier failure"
    assert JSON.decode!(File.read!(Path.join(output, "report.json"))) == result.report
  end

  @tag :database
  @tag timeout: 120_000
  test "eight real scenarios preserve execution, bounded buffers and read-only diagnostic facts" do
    output = output("real")
    on_exit(fn -> cleanup(output) end)
    previous = Observability.configuration()
    result = ObservabilityDemo.run(output: output)
    assert match?({:ok, _}, result), failure(result)
    {:ok, result} = result
    assert Observability.configuration() == previous
    report = result.report
    assert report["all_passed"]
    assert report["case_count"] == 8
    assert length(Enum.uniq(report["run_ids"])) == 16
    assert length(report["case_ids"]) == 1
    cases = Map.new(report["cases"], &{&1["case"], &1})
    assert cases["unknown_reconcile"]["effects_per_run"] == 1
    assert cases["export_failure_equivalence"]["semantics_equal"]
    assert length(cases["export_failure_equivalence"]["modes"]) == 5
    assert cases["buffer_saturation"]["attempted"] == 16_000
    assert cases["buffer_saturation"]["stats"]["highwater_entries"] <= 32
    assert cases["buffer_saturation"]["stats"]["highwater_bytes"] <= 16_384
    assert cases["buffer_saturation"]["stats"]["dropped"] > 0
    assert cases["buffer_saturation"]["metric_series"] <= 1
    assert cases["observer_absence"]["execution_owners_unchanged"]
    assert cases["readonly_projection"]["zero_boundaries"] == 47
    assert length(cases["commit_windows"]["windows"]) == 2

    for row <- report["cases"] do
      directory = Path.join(output, row["case"])

      refute File.read!(Path.join(directory, "observations.jsonl")) =~
               "PRIVATE_OBSERVABILITY_CANARY_19"

      for evidence <- row["evidence"] do
        trace = JSON.decode!(File.read!(Path.join(directory, evidence["path"])))
        assert trace["run_id"] == evidence["run_id"]
        assert trace["evidence_origin"] == "durable"
        assert AgentSystemsLab.Context.hash(trace) == evidence["trace_sha256"]
        refute JSON.encode!(trace) =~ "PRIVATE_OBSERVABILITY_CANARY_19"
      end
    end

    assert JSON.decode!(File.read!(Path.join(output, "report.json"))) == report
  end

  defp failure({:error, {:observability_verification_failed, r}}),
    do: inspect(r.report["failed_case"], limit: :infinity)

  defp failure(other), do: inspect(other)

  defp cleanup(output) do
    case File.read(Path.join(output, "manifest.json")) do
      {:ok, bytes} ->
        namespace = JSON.decode!(bytes)["namespace"]

        cases =
          Repo.query!("SELECT id FROM lab_approval_cases WHERE id LIKE $1", [namespace <> "%"])

        for [id] <- cases.rows do
          case Approvals.load(id) do
            {:ok, view} ->
              for round <- view.rounds do
                Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [round.workflow_id])

                Repo.query!("DELETE FROM lab_queues WHERE name=$1", [
                  AgentSystemsLab.Workflows.Store.queue_name(round.workflow_id)
                ])
              end

            _ ->
              :ok
          end
        end

        Repo.query!("DELETE FROM lab_approval_cases WHERE id LIKE $1", [namespace <> "%"])
        Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [namespace <> "%"])
        Repo.query!("DELETE FROM lab_queues WHERE name LIKE $1", [namespace <> "%"])

      _ ->
        :ok
    end

    File.rm_rf!(output)
  end

  defp output(label),
    do:
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "lab-observability-#{label}-#{Ecto.UUID.generate()}"
      )
end
