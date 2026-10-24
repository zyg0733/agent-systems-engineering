defmodule AgentSystemsLab.IsolationDemoTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.IsolationDemo

  test "validates bounded demo options before creating output or starting a probe" do
    for opts <- [
          nil,
          :bad,
          [1],
          [unknown: true],
          [output: ""],
          [output: <<0>>],
          [output: 1],
          [on_progress: fn -> :ok end],
          [output: "a", output: "b"]
        ] do
      assert {:error, :invalid_isolation_demo_options} = IsolationDemo.run(opts)
    end

    assert IsolationDemo.cases() ==
             ~w(controlled_file outside_read outside_write symlink_read outside_link executable_link network fork_denied spawn_denied setsid_denied file_size file_descriptors cpu output wall cancel caller_crash unregistered_command)
  end

  test "preserves previous isolation evidence" do
    directory = output("exists")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep"), "prior evidence")
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, {:output_exists, ^directory}} = IsolationDemo.run(output: directory)
    assert File.ls!(directory) == ["keep"]
  end

  test "an injected starting failure preserves an incomplete report" do
    directory = output("starting")
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, {:isolation_verification_failed, result}} =
             IsolationDemo.run(
               output: directory,
               on_progress: fn _ -> raise "injected starting error" end
             )

    refute result.report["all_passed"]
    assert result.report["probe_count"] == 0
    assert result.report["expected_probe_count"] == 18
    assert result.report["failed_probe"]["reason"] =~ "injected starting error"
    refute File.exists?(Path.join(directory, "workspace/controlled.txt"))
    assert read_report(directory) == result.report
  end

  @tag timeout: 60_000
  @tag :seatbelt
  test "real syscall probes establish boundaries and await owned OS process cleanup" do
    directory = output("syscalls")
    on_exit(fn -> File.rm_rf!(directory) end)
    parent = self()

    if :os.type() == {:unix, :darwin} do
      assert {:ok, result} =
               IsolationDemo.run(
                 output: directory,
                 on_progress: fn progress -> send(parent, {:progress, progress}) end
               )

      report = result.report
      assert report["all_passed"]
      assert report["probe_count"] == 18
      assert report["expected_probe_count"] == 18
      assert report["failed_probe"] == nil
      assert report["process_scope"] == "one fork-denied target plus trusted guardian"
      assert "Linux container backend" in report["unsupported_capabilities"]
      assert "hard memory quota" in report["unsupported_capabilities"]

      assert_receive {:progress,
                      %{case: "controlled_file", status: :starting, completed: 0, total: 18}}

      assert_receive {:progress,
                      %{case: "unregistered_command", status: :passed, completed: 18, total: 18}}

      probes = Map.new(report["probes"], &{&1["case"], &1})
      assert probes["controlled_file"]["controlled_file_bytes"] == 19

      for name <- ~w(outside_read outside_write symlink_read) do
        assert probes[name]["permission_denied"]
        assert probes[name]["canary_exists"]
        assert probes[name]["canary_unchanged"]
      end

      assert probes["outside_link"]["hardlink_denied"]
      assert probes["executable_link"]["hardlink_denied"]
      assert probes["network"]["baseline_connected"]
      refute probes["network"]["sandbox_connected"]
      assert probes["network"]["permission_denied"]
      assert probes["fork_denied"]["creation_or_escape_denied"]
      assert probes["file_size"]["actual_file_bytes"] <= 4096
      assert probes["file_descriptors"]["hard_limit_observed"]
      assert probes["file_descriptors"]["opened"] <= 61
      assert probes["cpu"]["status"] == "resource_limit"
      assert probes["output"]["status"] == "output_limit"
      assert probes["output"]["captured_bytes"] <= 4096
      assert probes["wall"]["status"] == "timed_out"
      assert probes["cancel"]["status"] == "cancelled"

      for name <- ~w(cancel caller_crash) do
        assert probes[name]["target_started"]
        assert probes[name]["target_pid"] > 1
        assert probes[name]["guardian_pid"] > 1
        assert probes[name]["identity_nonce_verified"]
        assert probes[name]["target_exited"]
        assert probes[name]["guardian_exited"]
      end

      refute probes["unregistered_command"]["command_started"]
      assert Enum.all?(report["probes"], & &1["passed"])
      assert read_report(directory) == report
      canary = File.read!(Path.join(directory, "outside-canary"))
      assert :binary.match(File.read!(Path.join(directory, "report.json")), canary) == :nomatch
    else
      assert {:error, {:isolation_verification_failed, result}} =
               IsolationDemo.run(output: directory)

      refute result.report["all_passed"]
    end
  end

  defp output(label) do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    Path.join(base, "agent-lab-isolation-demo-#{label}-#{System.unique_integer([:positive])}")
  end

  defp read_report(directory),
    do: directory |> Path.join("report.json") |> File.read!() |> JSON.decode!()
end
