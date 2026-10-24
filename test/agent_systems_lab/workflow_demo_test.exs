defmodule AgentSystemsLab.WorkflowDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Repo, WorkflowDemo}

  test "rejects malformed options before output or execution" do
    for opts <- [
          nil,
          :bad,
          [1],
          [unknown: true],
          [output: 1],
          [output: ""],
          [output: <<255>>],
          [output: <<0>>],
          [on_progress: fn -> :ok end],
          [output: "a", output: "b"]
        ] do
      assert {:error, :invalid_workflow_demo_options} = WorkflowDemo.run(opts)
    end

    assert length(WorkflowDemo.cases()) == 9
  end

  @tag :database
  test "preserves old output and refuses global consumers" do
    output = output("protected")
    File.mkdir!(output)
    File.write!(Path.join(output, "prior"), "prior evidence")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = WorkflowDemo.run(output: output)
    assert File.ls!(output) == ["prior"]
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = WorkflowDemo.run(output: output)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end
  end

  @tag :database
  test "an injected starting failure retains incomplete report and namespace" do
    output = output("failure")
    on_exit(fn -> cleanup(output) end)

    assert {:error, {:workflow_verification_failed, result}} =
             WorkflowDemo.run(
               output: output,
               on_progress: fn _ -> raise "owned start failure" end
             )

    refute result.report["all_passed"]
    assert result.report["case_count"] == 0
    assert result.report["expected_case_count"] == 9
    assert result.report["failed_case"]["reason"] =~ "owned start failure"
    assert read_report(output) == result.report
    assert JSON.decode!(File.read!(Path.join(output, "manifest.json")))["namespace"] != ""
  end

  @tag :database
  @tag timeout: 90_000
  test "real DAG drill preserves budgets, receipts and ambiguous effects across crashes" do
    output = output("real")
    on_exit(fn -> cleanup(output) end)
    assert {:ok, result} = WorkflowDemo.run(output: output)
    report = result.report
    assert report["all_passed"]
    assert report["case_count"] == report["expected_case_count"]
    assert length(report["workflow_ids"]) == 11
    cases = Map.new(report["cases"], &{&1["case"], &1})
    assert cases["parallel_diamond"]["observed_parallel"] == 2
    assert cases["serial_baseline"]["allocations"] == cases["parallel_diamond"]["allocations"]
    assert cases["serial_baseline"]["artifacts"] == cases["parallel_diamond"]["artifacts"]
    [single, reviewer] = cases["same_budget_reviewer_comparison"]["results"]

    for key <- ["caps", "allocations", "artifacts", "opinion"] do
      assert single[key] == reviewer[key]
    end

    assert single["spending"]["model_attempts"] == 3
    assert reviewer["spending"]["model_attempts"] == 4
    assert cases["failure_propagation"]["dependent"] == "skipped"
    assert cases["unknown_on_cancel"]["effects"] == 1
    assert cases["unknown_on_cancel"]["unresolved_nodes"] == ["held"]
    assert cases["controller_crash"]["effect_entry_count"] == 1
    assert cases["controller_crash"]["actual_coordinator_kill"]
    assert length(cases["commit_windows"]["windows"]) == 2

    for name <- ["serial_baseline", "parallel_diamond", "cancellation", "controller_crash"] do
      counts = cases[name]["audit"]["effect_boundary_calls"]
      assert map_size(counts) == 31
      assert Enum.all?(counts, fn {_, count} -> count == 0 end)
    end

    for row <- report["cases"], evidence <- row["evidence"] do
      saved =
        output
        |> Path.join(row["case"])
        |> Path.join(evidence["path"])
        |> File.read!()
        |> JSON.decode!()

      assert saved["workflow"]["id"] == evidence["workflow_id"]
      assert length(saved["children"]) == evidence["created_children"]
      assert length(saved["workflow"]["events"]) > 0
    end

    assert read_report(output) == report
  end

  @tag :database
  @tag timeout: 30_000
  test "deadline observation waits for terminal fanout acknowledgement before taking its audit snapshot" do
    alias AgentSystemsLab.{Recovery, RecoveryStore, Workflows}
    alias AgentSystemsLab.Scheduler.DatabaseTask
    alias AgentSystemsLab.Workflows.{Audit, Definition, Store}

    id = "w24-workflow-settled-" <> Ecto.UUID.generate()
    parent = self()
    marker = make_ref()
    # Start the real observer before the fixture exists, then replace only its
    # test-owned pending helper. The runtime's Store and Coordinator are unchanged.
    {:ok, coordinator} = Workflows.start_link(workflow_id: id, poll_interval_ms: 60_000)
    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator) do
        :sys.resume(coordinator)
        Workflows.stop(coordinator)
      end

      case Repo.query!("SELECT queue_name FROM lab_workflows WHERE id=$1", [id]).rows do
        [[queue]] ->
          Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [id])
          Repo.query!("DELETE FROM lab_queues WHERE name=$1", [queue])

        [] ->
          :ok
      end
    end)

    :sys.replace_state(coordinator, fn state ->
      if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
      DatabaseTask.stop(state.pending_sync)
      %{state | poll_timer: nil, poll_token: nil, pending_sync: nil}
    end)

    {:ok, definition} =
      Definition.new(
        [
          %{
            id: "slow",
            input: "Expire the original absolute deadline",
            options: %{script: [{:stream, [{:sleep, 1000}, {:text_delta, "late"}, :done]}]}
          }
        ],
        timeout_ms: 150
      )

    {:ok, initial} = Workflows.create(id, definition)
    {:ok, child} = Recovery.load(initial.nodes["slow"].run_id)
    assert child.recovery.progress.deadline_at_ms <= initial.deadline_at_ms

    wait_until = fn recurse ->
      if RecoveryStore.now_ms() >= initial.deadline_at_ms,
        do: :ok,
        else:
          (
            Process.sleep(5)
            recurse.(recurse)
          )
    end

    wait_until.(wait_until)

    :sys.replace_state(coordinator, fn state ->
      task =
        DatabaseTask.start(
          fn ->
            Store.sync(id,
              hook: fn
                :after_commit ->
                  send(parent, {marker, :terminal_commit, self()})
                  receive do: ({^marker, :release} -> :ok)

                _ ->
                  :ok
              end
            )
          end,
          10_000,
          :workflow_sync
        )

      %{state | pending_sync: task}
    end)

    :ok = :sys.resume(coordinator)
    assert_receive {^marker, :terminal_commit, helper}, 5_000
    {:ok, first_terminal} = Workflows.load(id)
    assert first_terminal.status == :failed
    assert first_terminal.nodes["slow"].status == :running
    assert Workflows.status(coordinator).pending_sync.pid == helper

    observer = Task.async(fn -> WorkflowDemo.await_settled_terminal(coordinator, id, :failed) end)
    assert Task.yield(observer, 30) == nil
    assert Process.alive?(helper)
    send(helper, {marker, :release})
    settled = Task.await(observer, 5_000)
    assert Workflows.status(coordinator).pending_sync == nil
    assert Workflows.status(coordinator).workflow_status == :failed
    assert settled.definition.timeout_ms == 150
    assert settled.deadline_at_ms == initial.deadline_at_ms
    assert settled.seq > first_terminal.seq
    assert settled.nodes["slow"].status == :cancelled
    assert {:error, :workflow_rebuild_mismatch} = Audit.run(id, first_terminal)
    assert {:ok, %{"all_passed" => true}} = Audit.run(id, settled)
    Workflows.stop(coordinator)
  end

  defp cleanup(output) do
    case File.read(Path.join(output, "manifest.json")) do
      {:ok, bytes} ->
        namespace = JSON.decode!(bytes)["namespace"]

        queues =
          Repo.query!("SELECT queue_name FROM lab_workflows WHERE id LIKE $1", [namespace <> "%"])

        Repo.query!("DELETE FROM lab_workflows WHERE id LIKE $1", [namespace <> "%"])

        Enum.each(queues.rows, fn [name] ->
          Repo.query!("DELETE FROM lab_queues WHERE name=$1", [name])
        end)

      _ ->
        :ok
    end

    File.rm_rf!(output)
  end

  defp output(label),
    do:
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "lab-workflow-demo-#{label}-#{Ecto.UUID.generate()}"
      )

  defp read_report(output),
    do: output |> Path.join("report.json") |> File.read!() |> JSON.decode!()
end
