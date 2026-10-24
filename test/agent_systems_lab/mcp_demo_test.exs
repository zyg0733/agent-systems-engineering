defmodule AgentSystemsLab.MCPDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{MCPDemo, Repo}

  test "validates options before creating output, a Run or an OS process" do
    for opts <- [
          nil,
          :bad,
          [1],
          [unknown: true],
          [memory: 1],
          [output: 1],
          [output: ""],
          [output: <<255>>],
          [output: <<0>>],
          [on_progress: fn -> :ok end],
          [memory: true, memory: false]
        ] do
      assert {:error, :invalid_mcp_demo_options} = MCPDemo.run(opts)
    end

    assert length(MCPDemo.cases()) == 20
  end

  test "existing output and global consumers cannot be overwritten by an experiment" do
    output = output("protected")
    File.mkdir!(output)
    File.write!(Path.join(output, "prior"), "owned prior evidence")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = MCPDemo.run(output: output, memory: true)
    assert File.ls!(output) == ["prior"]

    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    try do
      Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
      assert {:error, :global_scheduler_enabled} = MCPDemo.run(output: output, memory: true)
    after
      Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end
  end

  test "a starting failure preserves an explicitly incomplete report" do
    output = output("failure")
    on_exit(fn -> File.rm_rf!(output) end)

    assert {:error, {:mcp_verification_failed, result}} =
             MCPDemo.run(
               output: output,
               memory: true,
               on_progress: fn _ -> raise "injected MCP start failure" end
             )

    refute result.report["all_passed"]
    refute result.report["recovery_verified"]
    assert result.report["case_count"] == 0
    assert result.report["expected_case_count"] == 18
    assert result.report["failed_case"]["reason"] =~ "injected MCP start failure"
    assert read_report(output) == result.report
  end

  @tag :database
  @tag :seatbelt
  @tag timeout: 60_000
  test "real stdio probes and durable effect ambiguity pass without redelivery" do
    output = output("real")

    on_exit(fn ->
      case File.read(Path.join(output, "manifest.json")) do
        {:ok, bytes} ->
          namespace = JSON.decode!(bytes)["namespace"]
          Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [namespace <> "%"])

        _ ->
          :ok
      end

      File.rm_rf!(output)
    end)

    assert {:ok, result} = MCPDemo.run(output: output)
    assert result.report["all_passed"]
    assert result.report["recovery_verified"]
    assert result.report["case_count"] == 20
    assert result.report["expected_case_count"] == 20
    assert length(result.report["run_ids"]) == 2
    cases = Map.new(result.report["cases"], &{&1["case"], &1})
    assert cases["discovery_pages"]["discovery_pages"] == 2
    assert cases["file_policy"]["canary_unchanged"]
    assert cases["durable_receipt_reuse"]["zero_effect_boundaries"] == 27
    assert cases["durable_effect_drop"]["status"] == "expected_blocked"
    assert cases["durable_effect_drop"]["effect_count"] == 1
    assert cases["durable_effect_drop"]["tools_call_count"] == 1
    assert cases["timeout_cancel"]["status"] == "unknown"
    assert cases["late_reply"]["status"] == "late_reply_ignored"
    assert cases["caller_crash"]["guardian_exited"]
    assert read_report(output) == result.report
  end

  defp output(label),
    do:
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "lab-mcp-demo-#{label}-#{System.unique_integer([:positive])}"
      )

  defp read_report(output),
    do: output |> Path.join("report.json") |> File.read!() |> JSON.decode!()
end
