defmodule AgentSystemsLab.EvaluationTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Evaluation, Repo}
  alias AgentSystemsLab.Evaluation.{Comparison, Report}

  test "strict options, files and duplicate JSON keys fail before execution" do
    for opts <- [
          nil,
          :bad,
          [1],
          [output: ""],
          [output: <<255>>],
          [output: <<0>>],
          [split: "all"],
          [profile: "model"],
          [repetitions: 0],
          [repetitions: 11],
          [baseline: nil],
          [on_progress: fn -> :ok end],
          [x: true],
          [split: "dev", split: "holdout"]
        ] do
      assert {:error, :invalid_evaluation_options} = Evaluation.run(opts)
    end

    root = directory("bad-files")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:error, _} = Evaluation.read_report(Path.join(root, "missing"))

    for {name, bytes} <- [
          {"duplicate", ~s({"x":1,"x":2})},
          {"big", String.duplicate("x", 2_097_153)},
          {"trailing", "{}{}"}
        ] do
      path = Path.join(root, name)
      File.write!(path, bytes)
      assert {:error, _} = Evaluation.read_report(path)
    end

    assert {:error, _} = Evaluation.read_report(root)
  end

  @tag :database
  test "existing evidence, disabled database and global consumers are rejected" do
    root = directory("protected")
    File.mkdir!(root)
    File.write!(Path.join(root, "keep"), "evidence")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:error, {:output_exists, ^root}} = Evaluation.run(output: root)
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)
    db = Application.get_env(:agent_systems_lab, :database_enabled, true)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = Evaluation.run(output: root)
      Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
      Application.put_env(:agent_systems_lab, :database_enabled, false)
      assert {:error, :database_required} = Evaluation.run(output: root)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
      Application.put_env(:agent_systems_lab, :database_enabled, db)
    end

    assert File.read!(Path.join(root, "keep")) == "evidence"
  end

  @tag :database
  test "interrupted batches persist the full plan but cannot become a baseline" do
    root = directory("interrupted")
    on_exit(fn -> cleanup(root) end)

    assert {:error, {:evaluation_failed, result}} =
             Evaluation.run(
               output: root,
               on_progress: fn _ -> raise "PRIVATE_EVAL_EXCEPTION" end
             )

    assert result.reason == :evaluation_interrupted
    status = read(root, "status.json")
    assert status["state"] == "incomplete"
    refute status["complete"]
    assert status["planned_count"] == 12
    assert status["completed_count"] == 0
    manifest = read(root, "manifest.json")
    assert length(manifest["planned_samples"]) == 12
    refute File.exists?(Path.join(root, "report.json"))
    refute JSON.encode!(status) =~ "PRIVATE_EVAL_EXCEPTION"
    assert {:error, _} = Evaluation.read_report(Path.join(root, "status.json"))
  end

  @tag :database
  @tag timeout: 120_000
  test "fresh repeated cohorts match semantics and cost while real incorrect and bounded tasks regress" do
    roots =
      for name <- ~w(baseline repeat candidate holdout compare bad), do: {name, directory(name)}

    roots = Map.new(roots)
    on_exit(fn -> Enum.each(roots, fn {_, root} -> cleanup(root) end) end)
    assert {:ok, baseline} = Evaluation.run(output: roots["baseline"], repetitions: 2)
    assert :ok = Report.validate(baseline.report)
    assert baseline.report["summary"]["successful_samples"] == 12
    path = Path.join(roots["baseline"], "report.json")
    assert {:ok, repeat} = Evaluation.run(output: roots["repeat"], repetitions: 2, baseline: path)
    assert repeat.report["semantic_signature"] == baseline.report["semantic_signature"]
    assert repeat.report["summary"]["cost"] == baseline.report["summary"]["cost"]
    old_ids = Enum.map(baseline.report["samples"], & &1["run_id"])

    assert MapSet.disjoint?(
             MapSet.new(old_ids),
             MapSet.new(Enum.map(repeat.report["samples"], & &1["run_id"]))
           )

    assert {:ok, candidate} =
             Evaluation.run(
               output: roots["candidate"],
               repetitions: 2,
               profile: "regressed",
               baseline: path
             )

    refute candidate.comparison["passed"]
    assert candidate.comparison["status"] == "regressed"
    assert candidate.report["summary"]["success_rate_pct"] < 100
    assert Enum.count(candidate.report["samples"], &(&1["failure_class"] == "budget")) == 2
    assert candidate.report["summary"]["cost"]["total_units"] > 0
    assert candidate.report["summary"]["planned_samples"] == 12

    assert {:ok, holdout} =
             Evaluation.run(output: roots["holdout"], split: "holdout", repetitions: 1)

    assert holdout.report["summary"]["successful_samples"] == 4

    assert {:error, {:incompatible_protocol, _}} =
             Comparison.compare(baseline.report, holdout.report)

    assert {:error, :incompatible_evaluation_baseline} =
             Evaluation.run(
               output: roots["bad"],
               split: "holdout",
               repetitions: 1,
               baseline: path
             )

    refute File.exists?(roots["bad"])

    assert {:ok, saved} =
             Evaluation.compare_files(path, Path.join(roots["candidate"], "report.json"),
               output: roots["compare"]
             )

    assert saved.comparison == candidate.comparison
    assert read(roots["compare"], "comparison.json") == candidate.comparison

    assert {:error, {:output_exists, _}} =
             Evaluation.compare_files(path, path, output: roots["compare"])

    for root <- [roots["baseline"], roots["repeat"], roots["candidate"], roots["holdout"]] do
      report = read(root, "report.json")
      assert read(root, "status.json")["complete"]

      lines =
        File.read!(Path.join(root, "samples.jsonl"))
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      assert Enum.sort_by(lines, &{&1["task_id"], &1["trial"]}) == report["samples"]
    end
  end

  defp read(root, file), do: root |> Path.join(file) |> File.read!() |> JSON.decode!()

  defp directory(label),
    do:
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "lab-eval-#{label}-#{Ecto.UUID.generate()}"
      )

  defp cleanup(root) do
    case File.read(Path.join(root, "manifest.json")) do
      {:ok, bytes} ->
        data = JSON.decode!(bytes)
        ids = Enum.map(data["planned_samples"] || [], & &1["run_id"])
        if ids != [], do: Repo.query!("DELETE FROM lab_runs WHERE id=ANY($1::text[])", [ids])

      _ ->
        :ok
    end

    File.rm_rf!(root)
  end
end
