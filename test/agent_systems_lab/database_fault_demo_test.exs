defmodule AgentSystemsLab.DatabaseFaultDemoTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{DatabaseFaultDemo, Repo}
  alias AgentSystemsLab.Faults.DatabaseProxy
  alias AgentSystemsLab.Storage.Codec

  test "validates bounded fault options before creating output or starting a child" do
    for opts <- [
          nil,
          :bad,
          [1],
          [unknown: true],
          [repetitions: 0],
          [repetitions: 11],
          [repetitions: 1.0],
          [output: ""],
          [output: <<0>>],
          [output: 1],
          [on_progress: fn -> :ok end],
          [repetitions: 1, repetitions: 2]
        ] do
      assert {:error, :invalid_database_fault_options} = DatabaseFaultDemo.run(opts)
    end

    assert DatabaseFaultDemo.cases() == [
             "before_commit_rollback",
             "commit_ack_lost",
             "heartbeat_disconnect",
             "tool_effect_pending_disconnect",
             "auto_poll_reconnect"
           ]
  end

  test "retains previous database fault evidence" do
    directory = output("exists")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep"), "prior evidence")
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, {:output_exists, ^directory}} = DatabaseFaultDemo.run(output: directory)
    assert File.ls!(directory) == ["keep"]
  end

  test "refuses a global scheduler and records incomplete starting callbacks" do
    directory = output("global")
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled)
    Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
    on_exit(fn -> Application.put_env(:agent_systems_lab, :scheduler_enabled, previous) end)
    assert {:error, :global_scheduler_enabled} = DatabaseFaultDemo.run(output: directory)
    refute File.exists?(directory)
    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)

    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, {:database_verification_failed, result}} =
             DatabaseFaultDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn _ -> raise "injected starting error" end
             )

    refute result.report["all_passed"]
    assert result.report["fault_probe_count"] == 0
    assert result.report["expected_probe_count"] == 5
    assert result.report["failed_probe"]["reason"] =~ "injected starting error"
    refute File.exists?(Path.join(directory, "before_commit_rollback/1/process.json"))
  end

  @tag :database
  @tag timeout: 120_000
  test "real isolated socket faults roll back, lose COMMIT acknowledgement, stop ownership and recover" do
    directory = output("sockets")
    on_exit(fn -> cleanup(directory) end)
    parent = self()
    config = Application.fetch_env!(:agent_systems_lab, Repo)
    backend = Repo.config()
    {:ok, forwarding} = DatabaseProxy.start_link(backend[:hostname], backend[:port])
    userinfo = URI.encode(backend[:username], &URI.char_unreserved?/1)

    userinfo =
      if password = backend[:password],
        do: userinfo <> ":" <> URI.encode(password, &URI.char_unreserved?/1),
        else: userinfo

    url =
      "postgres://#{userinfo}@127.0.0.1:#{DatabaseProxy.port(forwarding)}/" <>
        URI.encode(backend[:database], &URI.char_unreserved?/1)

    # Model a published database endpoint whose listening port differs from
    # inet_server_port(). Existing parent connections remain independent, while
    # every isolated child must use this configured forwarding endpoint.
    Application.put_env(
      :agent_systems_lab,
      Repo,
      config
      |> Keyword.drop([:url, :socket, :socket_dir])
      |> Keyword.merge(hostname: "unreachable.invalid", port: 1, url: url)
    )

    on_exit(fn ->
      Application.put_env(:agent_systems_lab, Repo, config)
      if Process.alive?(forwarding), do: DatabaseProxy.stop(forwarding)
    end)

    assert {:ok, result} =
             DatabaseFaultDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn progress -> send(parent, {:progress, progress}) end
             )

    report = result.report
    assert report["all_passed"]
    assert report["fault_probe_count"] == 5
    assert report["expected_probe_count"] == 5
    assert report["stale_generation_overwrites"] == 0
    assert report["duplicate_mock_effects"] == 0
    assert report["failed_probe"] == nil
    assert DatabaseProxy.status(forwarding).accepted >= report["fault_probe_count"]
    assert_receive {:progress, %{status: :disconnected, completed: 0, total: 5}}
    assert_receive {:progress, %{status: :passed, completed: 5, total: 5}}

    for probe <- report["fault_probes"] do
      root = Path.join(directory, probe["evidence"])
      assert probe["status"] == "succeeded"
      assert probe["isolated_child_repo"]
      assert probe["shared_database_untouched"]
      assert probe["database_error_observed"]
      assert probe["database_errors"] != []
      assert probe["connections_dropped"] >= 1

      assert probe["initial_connection"]["backend_pid"] !=
               probe["healed_connection"]["backend_pid"]

      assert probe["initial_connection"]["database"] == probe["healed_connection"]["database"]
      assert probe["state_matches_history"]
      if probe["same_intent_takeover"], do: assert(probe["stale_claim_rejected"])
      assert probe["successor_facts_unchanged"]
      assert probe["operation_id_preserved"]
      assert probe["pending_claims"] == 0
      assert probe["child_exit_status"] == 0
      assert File.read!(Path.join(root, "child.log")) =~ "DATABASE_FAULT_CHILD="
      assert read_json(root, "cleanup")["exit_observed"]
      assert read_json(root, "cleanup")["proxy_stopped"]
      assert read_json(root, "cleanup")["exit_status"] == 0
      assert read_term(root, "after")["snapshot"]["state"]["status"] == "succeeded"

      case probe["fault"] do
        "before_commit_rollback" ->
          assert read_term(root, "initial")["snapshot"]["state"] ==
                   read_term(root, "disconnected")["snapshot"]["state"]

          assert read_term(root, "initial")["snapshot"]["events"] ==
                   read_term(root, "disconnected")["snapshot"]["events"]

          assert read_term(root, "disconnected")["recordings"] == []
          assert read_term(root, "before-fault") == read_term(root, "disconnected-rows")
          assert probe["stale_claim_rejected"] == nil
          assert probe["commit_ack_dropped"] == 0

        "commit_ack_lost" ->
          assert probe["commit_ack_dropped"] == 1
          assert read_term(root, "disconnected")["snapshot"]["state"]["status"] == "succeeded"
          assert length(read_term(root, "disconnected")["recordings"]) == 1

          assert read_term(root, "disconnected")["snapshot"]["recovery"]["progress"]["cursor"] ==
                   1

          assert read_term(root, "disconnected") == read_term(root, "after")

          assert Enum.any?(
                   read_json(root, "proxy")["events"],
                   &(&1["event"] == ":commit_ack_dropped")
                 )

        name
        when name in [
               "heartbeat_disconnect",
               "tool_effect_pending_disconnect",
               "auto_poll_reconnect"
             ] ->
          assert probe["worker_stopped"] and probe["executor_stopped"]
          assert probe["same_intent_takeover"]
          assert probe["successor_generation"] == probe["old_generation"] + 1

          if name == "auto_poll_reconnect" do
            assert probe["same_scheduler_resumed"]
            assert probe["automatic_completion"]
            assert probe["scheduler_before"] == probe["scheduler_after"]
            assert is_binary(probe["scheduler_before"])
          end

          if name == "tool_effect_pending_disconnect" do
            assert probe["unknown_manual_observed"]
            assert probe["effects"] == 1
            unknown = read_term(root, "unknown")
            assert unknown["snapshot"]["state"]["status"] == "blocked"
            assert unknown["queue"]["operation_id"] == "once"
            assert unknown["queue"]["safe_mode"] == "manual"
            assert [operation] = read_term(root, "after")["operations"]
            assert operation["operation_id"] == "once"
            assert Enum.count(operation["attempts"], &(&1["kind"] == "execution")) == 2
            assert Enum.any?(operation["attempts"], &(&1["kind"] == "manual"))
          end
      end
    end

    assert read_json(directory, "report") == report
  end

  @tag :database
  test "early child failure retains diagnostics and closes the owned proxy" do
    directory = output("child-exit")
    runtime = output("failed-runtime")
    File.mkdir_p!(runtime)
    executable = Path.join(runtime, "elixir")
    File.write!(executable, "#!/bin/sh\nprintf 'injected child startup failure\\n'\nexit 23\n")
    File.chmod!(executable, 0o755)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", runtime <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      cleanup(directory)
      File.rm_rf!(runtime)
    end)

    assert {:error, {:database_verification_failed, result}} =
             DatabaseFaultDemo.run(output: directory, repetitions: 1)

    assert result.report["fault_probe_count"] == 0
    reason = result.report["failed_probe"]["reason"]
    assert reason =~ "child exited 23"
    assert reason =~ "proxy status:"
    assert reason =~ "injected child startup failure"
    root = Path.join(directory, "before_commit_rollback/1")
    assert File.read!(Path.join(root, "child.log")) =~ "injected child startup failure"
    cleanup = read_json(root, "cleanup")
    refute cleanup["kill_sent"]
    assert cleanup["exit_observed"]
    assert cleanup["proxy_stopped"]
    assert cleanup["exit_status"] == 23
  end

  @tag :database
  test "a result before readiness fails promptly with its original error and cleans up" do
    directory = output("early-result")
    runtime = output("early-result-runtime")
    child_directory = Path.join(directory, "before_commit_rollback/1")
    File.mkdir_p!(runtime)

    File.write!(Path.join(runtime, "elixir"), """
    #!/usr/bin/env python3
    import json, pathlib, time
    root = pathlib.Path(#{JSON.encode!(child_directory)})
    process = root / "process.json"
    while not process.exists():
        time.sleep(0.01)
    identity = json.loads(process.read_text())
    result = {**identity, "database_error_observed": False,
              "database_errors": ["{:error, :intent_claimed}"]}
    temporary = root / "result.json.tmp"
    temporary.write_text(json.dumps(result))
    temporary.rename(root / "result.json")
    time.sleep(60)
    """)

    File.chmod!(Path.join(runtime, "elixir"), 0o755)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", runtime <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      cleanup(directory)
      File.rm_rf!(runtime)
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:database_verification_failed, result}} =
             DatabaseFaultDemo.run(output: directory, repetitions: 1)

    assert System.monotonic_time(:millisecond) - started < 5_000
    reason = result.report["failed_probe"]["reason"]
    assert reason =~ "child returned before readiness"
    assert reason =~ "intent_claimed"
    refute reason =~ "bounded wait expired"
    refute File.exists?(Path.join(child_directory, "ready.json"))
    assert File.exists?(Path.join(child_directory, "result.json"))
    cleanup = read_json(child_directory, "cleanup")
    assert cleanup["kill_sent"]
    assert cleanup["exit_observed"]
    assert cleanup["proxy_stopped"]
  end

  @tag :database
  @tag timeout: 30_000
  test "callback failure during an outage closes the owned proxy and awaits its child" do
    directory = output("failure")
    on_exit(fn -> cleanup(directory) end)

    assert {:error, {:database_verification_failed, result}} =
             DatabaseFaultDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn
                 %{status: :disconnected} -> raise "injected outage callback failure"
                 _ -> :ok
               end
             )

    refute result.report["all_passed"]
    assert result.report["fault_probe_count"] == 0
    assert result.report["failed_probe"]["reason"] =~ "injected outage callback failure"
    root = Path.join(directory, "before_commit_rollback/1")
    cleanup = read_json(root, "cleanup")
    assert cleanup["kill_sent"]
    assert cleanup["exit_observed"]
    assert cleanup["proxy_stopped"]

    {_state, status} =
      System.cmd("/bin/ps", ["-p", Integer.to_string(cleanup["pid"]), "-o", "state="])

    assert status != 0
    %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  defp read_term(root, name) do
    assert {:ok, value} = Codec.decode(File.read!(Path.join(root, name <> ".bin")))
    value
  end

  defp read_json(root, name), do: JSON.decode!(File.read!(Path.join(root, name <> ".json")))

  defp output(label),
    do:
      Path.join(
        File.cwd!(),
        "artifacts/database-test-#{label}-#{System.unique_integer([:positive])}"
      )

  defp cleanup(root) do
    report =
      case File.read(Path.join(root, "report.json")) do
        {:ok, bytes} -> JSON.decode!(bytes)
        _ -> %{}
      end

    ids = Enum.map(Map.get(report, "fault_probes", []), & &1["run_id"])
    ids = if failed = report["failed_probe"], do: [failed["run_id"] | ids], else: ids

    if Process.whereis(Repo),
      do: Enum.each(ids, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1]))

    File.rm_rf!(root)
  end
end
