defmodule AgentSystemsLab.RepairTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Kernel, Repair}
  alias AgentSystemsLab.Storage.Codec

  setup do
    root = Path.join(File.cwd!(), "artifacts/repair-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "a complete offline repair saves paired facts and a patch that applies to the baseline", %{
    root: root
  } do
    output = Path.join(root, "result")
    assert {:ok, result} = Repair.run(output: output)
    assert result.report["before_exit_code"] == 2
    assert result.report["after_exit_code"] == 0
    assert result.report["event_count"] == 8
    assert result.report["file_stats"] == %{"requests" => 3, "reads" => 1, "writes" => 2}
    assert result.snapshot.tool_stats == %{requests: 0, effects: 0}
    assert {:ok, events} = Codec.decode(File.read!(Path.join(output, "events.bin")))
    assert {:ok, rebuilt} = Kernel.rebuild(result.snapshot.state.run_id, events)
    assert rebuilt == result.snapshot.state

    for id <- result.report["call_ids"] do
      operation = rebuilt.operations[id]
      assert operation.status == :ok
      assert operation.result.operation_id == id
      assert operation.result.tool == operation.tool
      assert operation.result.type == "tool_result.v1"
    end

    assert File.read!(Path.join(output, "before-test.log")) =~
             "threshold qualifies for free delivery"

    assert File.read!(Path.join(output, "after-test.log")) =~ "4 passed"
    assert {:ok, decoded_report} = JSON.decode(File.read!(Path.join(output, "report.json")))
    assert decoded_report == result.report

    replay = Path.join(root, "apply-diff")
    {:ok, _} = File.cp_r(Repair.fixture_dir(), replay)

    {log, code} =
      System.cmd("git", ["apply", result.diff_path], cd: replay, stderr_to_stdout: true)

    assert code == 0, log

    for path <- ["lib/shipping.ex", "repair-notes.md"] do
      assert File.read!(Path.join(replay, path)) ==
               File.read!(Path.join([output, "workspace", path]))
    end

    # Replay only changes the in-memory projection, even after a file is changed externally.
    source = Path.join([output, "workspace", "lib/shipping.ex"])
    File.write!(source, "external change after completion\n")
    assert Kernel.rebuild(rebuilt.run_id, events) == {:ok, rebuilt}
    assert File.read!(source) == "external change after completion\n"
  end

  test "an existing evidence directory is never overwritten", %{root: root} do
    marker = Path.join(root, "keep.txt")
    File.write!(marker, "keep")
    assert {:error, {:output_exists, ^root}} = Repair.run(output: root)
    assert File.read!(marker) == "keep"
    assert File.ls!(root) == ["keep.txt"]
  end
end
