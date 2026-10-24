defmodule AgentSystemsLab.Evaluation.RunnerTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{ContextStore, ModelResultStore, Observability, Recovery, Repo}
  alias AgentSystemsLab.Evaluation.{Runner, Suite}

  setup do
    root =
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "lab-evaluation-runner-" <> Ecto.UUID.generate()
      )

    File.mkdir!(root)

    on_exit(fn ->
      root
      |> Path.join("*/run.json")
      |> Path.wildcard()
      |> Enum.each(fn path ->
        id = JSON.decode!(File.read!(path))["run_id"]
        if Process.whereis(Repo), do: Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])
      end)

      File.rm_rf!(root)
    end)

    {:ok, suite} = Suite.load()
    {:ok, root: root, suite: suite}
  end

  test "invalid arguments cannot create or overwrite a sample", c do
    task = task(c, "dev-normalize-lines")
    destination = Path.join(c.root, "invalid")

    for opts <- [[max_steps: -1], [run_id: "../../bad"], [run_id: ""], [extra: true], nil] do
      assert {:error, :invalid_evaluation_runner_arguments} =
               Runner.execute(c.suite, task, "reference", 1, destination, opts)
    end

    refute File.exists?(destination)
  end

  test "only settled source accounting can become known sample usage" do
    usage = %{
      "model_attempts" => 2,
      "output_bytes" => 135,
      "tool_attempts" => 1,
      "dispatches" => 3
    }

    before = {:ok, %{"usage" => usage, "fingerprint" => String.duplicate("a", 64)}}
    assert Runner.settled_usage(before, true) == usage
    assert Runner.settled_usage(before, false) == nil
    assert Runner.settled_usage(before, nil) == nil
    assert Runner.settled_usage({:error, :source_unavailable}, true) == nil
    assert Runner.settled_usage({:ok, %{"usage" => nil}}, true) == nil
  end

  @tag :database
  test "real repeated runs have unique sources and identical semantic outcomes", c do
    task = task(c, "dev-normalize-lines")
    first = execute(c, task, "reference", "first")
    second = execute(c, task, "reference", "second")
    assert first["task_success"]
    assert first["classification"] == "success"
    assert first["usage"]["model_attempts"] == 2
    assert first["usage"]["tool_attempts"] == 1
    assert first["usage"]["dispatches"] == 3
    assert first["usage"]["output_bytes"] > 0

    assert first["protocol"]["execution_contract_hash"] ==
             AgentSystemsLab.Context.hash(Runner.contract())

    assert first["usage"] == second["usage"]
    assert first["semantic_result_hash"] == second["semantic_result_hash"]
    refute first["run_id"] == second["run_id"]
    refute first["evidence"]["source_sha256"] == second["evidence"]["source_sha256"]

    for sample <- [first, second] do
      assert sample["evidence"]["source_unchanged_by_scorer"]
      assert {:ok, sample["evidence"]["source_sha256"]} == Runner.fingerprint(sample["run_id"])

      assert sample["latency_us"]["total"] >=
               sample["latency_us"]["execution"] + sample["latency_us"]["scoring"]
    end

    assert {:ok, recordings} = ModelResultStore.list(first["run_id"])

    assert {:ok, initial_capture} = ContextStore.load(hd(recordings).context_id)
    refute inspect(initial_capture.context) =~ task["oracle"]["expected_sha256"]

    for recording <- recordings do
      assert {:ok, capture} = ContextStore.load(recording.context_id)
      refute Map.has_key?(capture.context, :oracle)
      assert capture.context.task.acceptance == []
    end

    snapshot = Path.join([c.root, "first", "scoring", "artifact.txt"])
    assert File.read!(snapshot) == task["profiles"]["reference"]["artifact"]
    assert Bitwise.band(File.stat!(snapshot).mode, 0o222) == 0

    assert {:error, :sample_directory_exists} =
             Runner.execute(c.suite, task, "reference", 1, Path.join(c.root, "first"))
  end

  @tag :database
  test "a successful runtime and model self-report do not pass an incorrect artifact", c do
    sample = execute(c, task(c, "dev-sort-inventory"), "regressed", "incorrect")
    assert sample["status"] == "succeeded"
    refute sample["task_success"]
    assert sample["classification"] == "task_failure"
    assert sample["failure_class"] == "incorrect"
    assert sample["grade"]["reason"] == "artifact_mismatch"
    assert sample["grade"]["passed"] == false
    assert sample["evidence"]["source_unchanged_by_scorer"]
    assert {:ok, view} = Recovery.load(sample["run_id"])
    assert view.state.output == "TASK SUCCEEDED"
  end

  @tag :database
  test "a candidate exhausts the unchanged tool budget and retains charged work", c do
    task = task(c, "dev-bounded-response")
    reference = execute(c, task, "reference", "bounded-reference")
    candidate = execute(c, task, "regressed", "bounded-candidate")
    assert reference["task_success"]
    refute candidate["task_success"]
    assert candidate["status"] == "failed"
    assert candidate["failure_class"] == "budget"
    assert candidate["grade"]["passed"]
    assert candidate["artifact_sha256"] == reference["artifact_sha256"]
    assert candidate["usage"]["model_attempts"] == 2
    assert candidate["usage"]["tool_attempts"] == 1
    assert candidate["usage"]["output_bytes"] > 0
    assert candidate["usage"]["dispatches"] == 3
    assert {:ok, left} = Recovery.load(reference["run_id"])
    assert {:ok, right} = Recovery.load(candidate["run_id"])
    assert left.recovery.config.budget == right.recovery.config.budget
    assert left.recovery.config.max_turns == right.recovery.config.max_turns
    assert left.recovery.config.max_model_attempts == right.recovery.config.max_model_attempts
    assert left.state.input == right.state.input
  end

  @tag :database
  test "bounded-out work remains a failure sample without silently continuing it", c do
    sample = execute(c, task(c, "dev-normalize-lines"), "reference", "step-bound", max_steps: 0)
    refute sample["task_success"]
    assert sample["failure_class"] == "timeout"
    assert sample["status"] == "running"

    refute sample["protocol"]["execution_contract_hash"] ==
             AgentSystemsLab.Context.hash(Runner.contract())

    assert sample["usage"] == %{
             "model_attempts" => 0,
             "output_bytes" => 0,
             "tool_attempts" => 0,
             "dispatches" => 0
           }

    assert {:ok, []} = ModelResultStore.list(sample["run_id"])
    assert {:ok, view} = Recovery.load(sample["run_id"])
    assert view.recovery.progress.cursor == 0
  end

  @tag :database
  test "the wall-clock bound stops the executor and retains an explicit timeout sample", c do
    original_children = Task.Supervisor.children(AgentSystemsLab.ProviderSupervisor)

    sample =
      execute(c, task(c, "dev-normalize-lines"), "reference", "execution-timeout",
        execution_timeout_ms: 1
      )

    refute sample["task_success"]
    assert sample["failure_class"] == "timeout"
    assert sample["classification"] == "task_failure"

    assert is_nil(sample["usage"]) or
             Enum.all?(sample["usage"], fn {_name, count} -> is_integer(count) and count >= 0 end)

    assert wait_for_children(original_children, System.monotonic_time(:millisecond) + 1000)
  end

  @tag :database
  test "a scorer timeout preserves successful execution costs and counts as failure", c do
    sample =
      execute(c, task(c, "dev-normalize-lines"), "reference", "scorer-timeout",
        scorer_timeout_ms: 1
      )

    refute sample["task_success"]
    assert sample["status"] == "succeeded"
    assert sample["failure_class"] == "scorer_error"
    assert sample["classification"] == "scorer_error"
    assert sample["usage"]["model_attempts"] == 2
    assert sample["usage"]["tool_attempts"] == 1
    assert sample["evidence"]["source_unchanged_by_scorer"]
  end

  @tag :database
  test "stopping the observer cannot change task success or durable accounting", c do
    if is_nil(Process.whereis(AgentSystemsLab.Observability.Buffer)),
      do: assert({:ok, _} = Observability.restart())

    task = task(c, "dev-normalize-lines")
    baseline = execute(c, task, "reference", "observer-present")
    :ok = Observability.flush()

    :ok =
      Supervisor.terminate_child(AgentSystemsLab.Supervisor, AgentSystemsLab.Observability.Buffer)

    try do
      absent = execute(c, task, "reference", "observer-absent")
      assert absent["task_success"]
      assert absent["usage"] == baseline["usage"]
      assert absent["semantic_result_hash"] == baseline["semantic_result_hash"]
      assert absent["evidence"]["source_unchanged_by_scorer"]
    after
      assert {:ok, _} = Observability.restart()
    end
  end

  @tag :database
  test "fixture failure produces an auditable unknown-cost harness sample", c do
    task = Map.put(task(c, "dev-normalize-lines"), "initial_files", %{"../escape" => "no"})
    sample = execute(c, task, "reference", "fixture-error")
    refute sample["task_success"]
    assert sample["classification"] == "harness_error"
    assert sample["usage"] == nil
    assert sample["status"] == "unavailable"
    assert sample["evidence"]["source_sha256"] == nil
    refute File.exists?(Path.join(c.root, "escape"))
    assert {:error, :source_unavailable} = Runner.fingerprint(sample["run_id"])
  end

  defp execute(c, task, profile, label, opts \\ []) do
    assert {:ok, sample} =
             Runner.execute(c.suite, task, profile, 1, Path.join(c.root, label), opts)

    assert JSON.decode!(JSON.encode!(sample)) == sample
    sample
  end

  defp task(c, id), do: Enum.find(c.suite["tasks"], &(&1["id"] == id))

  defp wait_for_children(original, deadline) do
    if Task.Supervisor.children(AgentSystemsLab.ProviderSupervisor) -- original == [] do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        wait_for_children(original, deadline)
      else
        false
      end
    end
  end
end
