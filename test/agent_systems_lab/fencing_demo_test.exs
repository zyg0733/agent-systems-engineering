defmodule AgentSystemsLab.FencingDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{FencingDemo, Recovery, Repo, Scheduler}
  alias AgentSystemsLab.Storage.Codec

  test "validates the bounded signal fixture before creating evidence or starting a child" do
    for options <- [
          nil,
          :bad,
          [1],
          [unknown: true],
          [repetitions: 0],
          [repetitions: 21],
          [repetitions: 1.0],
          [output: ""],
          [output: <<0>>],
          [output: 1],
          [on_progress: fn -> :ok end],
          [repetitions: 1, repetitions: 2]
        ] do
      assert {:error, :invalid_fencing_options} = FencingDemo.run(options)
    end

    assert length(FencingDemo.cases()) == 5
    assert length(Enum.uniq(FencingDemo.cases())) == 5
  end

  test "refuses to overwrite previous signal evidence" do
    directory = output("existing")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "keep.txt"), "retain original evidence")
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:error, {:output_exists, ^directory}} = FencingDemo.run(output: directory)
    assert File.ls!(directory) == ["keep.txt"]
    assert File.read!(Path.join(directory, "keep.txt")) == "retain original evidence"
  end

  test "refuses to compete with an application-wide background Scheduler" do
    previous = Application.get_env(:agent_systems_lab, :scheduler_enabled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:agent_systems_lab, :scheduler_enabled),
        else: Application.put_env(:agent_systems_lab, :scheduler_enabled, previous)
    end)

    Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
    directory = output("global-scheduler")

    assert {:error, :global_scheduler_enabled} =
             FencingDemo.run(output: directory, repetitions: 1)

    refute File.exists?(directory)
  end

  @tag :database
  @tag timeout: 120_000
  test "SIGSTOP expires a whole BEAM lease and the actual resumed executor cannot write stale results" do
    directory = output("signals")
    on_exit(fn -> cleanup(directory) end)
    parent = self()

    assert {:ok, result} =
             FencingDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn progress -> send(parent, {:progress, progress}) end
             )

    report = result.report
    assert report["all_passed"]
    assert report["fault_probe_count"] == 5
    assert report["expected_probe_count"] == 5
    assert report["sigstop_count"] == 5
    assert report["sigcont_count"] == 5
    assert report["same_seq_fencing_probes"] == 4
    assert report["stale_generation_overwrites"] == 0
    assert report["duplicate_mock_effects"] == 0
    assert report["failed_probe"] == nil
    assert_receive {:progress, %{status: :paused, completed: 0, total: 5}}
    assert_receive {:progress, %{status: :passed, completed: 5, total: 5}}

    for probe <- report["fault_probes"] do
      root = Path.join(directory, probe["evidence"])
      assert probe["paused_os_state"] =~ "T"
      assert probe["whole_beam_paused"]
      assert probe["controller_fixture_gate"]
      assert probe["renewal_quiescent_at_pause"]
      assert probe["overdue_renewal_before_executor_release"]
      assert probe["initial_heartbeat_renewals"] >= 1
      assert probe["successor_generation"] == probe["old_generation"] + 1
      assert probe["original_executor_fenced"]
      assert probe["heartbeat_observed_lease_loss"]
      assert probe["worker_stopped"]
      assert probe["executor_stopped"]
      assert probe["child_exit_status"] == 0
      assert probe["successor_facts_unchanged"]
      assert probe["state_matches_history"]
      assert probe["status"] == "succeeded"
      assert Enum.all?(probe["old_attempts"], & &1["fenced"])
      assert Enum.all?(probe["old_attempts"], &String.contains?(&1["result"], "stale_"))

      paused = read_term(root, "paused")
      takeover = read_term(root, "takenover")
      after_old = read_term(root, "after-old")
      done = read_term(root, "after")
      assert takeover === after_old
      assert done["snapshot"]["state"]["output"] == "accepted successor"
      assert File.read!(Path.join(root, "child.log")) =~ "FENCING_CHILD="
      assert read_json(root, "cleanup")["exit_observed"]

      if probe["same_seq_before_old_attempts"] do
        assert paused["snapshot"]["state"]["seq"] == takeover["snapshot"]["state"]["seq"]

        for name <- ["current_seq_old_token", "current_seq_old_generation"] do
          assert Enum.find(probe["old_attempts"], &(&1["name"] == name))["result"] ==
                   "{:error, :stale_claim}"
        end
      else
        assert takeover["snapshot"]["state"]["status"] == "succeeded"
        assert probe["original_executor_result"] =~ "stale_sequence"
      end

      if probe["fault"] == "tool_after_receipt_same_seq" do
        [confirmed] = paused["operations"]
        [retained] = done["operations"]
        assert confirmed["status"] == "completed"
        assert retained["result"] == confirmed["result"]
      end
    end
  end

  @tag :database
  test "the pause barrier consumes an in-flight renewal ACK before suspending the Worker" do
    id = "fencing-renewal-barrier-" <> Ecto.UUID.generate()
    parent = self()

    {:ok, _} =
      Recovery.create_run(id, "pause at a quiescent heartbeat", script: [{:final, "done"}])

    hook = fn
      :after_model ->
        send(parent, {:barrier_executor, self()})
        receive do: (:release_gate -> :ok)

      _ ->
        :ok
    end

    {:ok, scheduler} =
      Scheduler.start_link(
        workers: 1,
        run_ids: [id],
        lease_ms: 400,
        renew_interval_ms: 80,
        poll_interval_ms: 20,
        recovery_options: [hook: hook]
      )

    on_exit(fn ->
      if Process.alive?(scheduler) do
        try do
          for entry <- Scheduler.status(scheduler).active,
              Process.alive?(entry.worker),
              do: :sys.resume(entry.worker)

          Scheduler.stop(scheduler)
        catch
          :exit, _ -> :ok
        end
      end

      Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id])
    end)

    assert_receive {:barrier_executor, executor}, 5_000

    entry =
      await(fn ->
        Enum.find(
          Scheduler.status(scheduler).active,
          &(&1.executor == executor and &1.renewals >= 1)
        )
      end)

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM lab_runs WHERE id=$1 FOR UPDATE", [id])
          send(parent, :barrier_row_locked)
          receive do: (:release_lock -> :ok)
        end)
      end)

    on_exit(fn -> send(holder.pid, :release_lock) end)
    assert_receive :barrier_row_locked, 5_000
    await(fn -> :sys.get_state(entry.worker).renewal end)
    barrier = Task.async(fn -> FencingDemo.suspend_quiescent_worker(scheduler, executor) end)
    assert Task.yield(barrier, 20) == nil
    send(holder.pid, :release_lock)
    assert {:ok, :ok} = Task.await(holder)
    {paused, token} = Task.await(barrier)
    state = :sys.get_state(paused.worker)
    assert state.renewal == nil
    assert state.renewals >= 2
    assert state.renew_token == token
    assert state.claim == paused.claim
    assert state.executor == executor
    :ok = :sys.resume(paused.worker)
    :ok = Scheduler.stop(scheduler)
  end

  @tag :database
  test "an early child exit reports its output and cleans up without waiting for evidence timeout" do
    directory = output("early-exit")
    runtime = output("failed-runtime")
    File.mkdir_p!(runtime)
    executable = Path.join(runtime, "elixir")
    File.write!(executable, "#!/bin/sh\nprintf 'injected fencing startup failure\\n'\nexit 23\n")
    File.chmod!(executable, 0o755)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", runtime <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      cleanup(directory)
      File.rm_rf!(runtime)
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:fencing_verification_failed, result}} =
             FencingDemo.run(output: directory, repetitions: 1)

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert result.report["failed_probe"]["reason"] =~ "child exited 23 before evidence"
    assert result.report["failed_probe"]["reason"] =~ "injected fencing startup failure"
    root = Path.join(directory, "model_before_accept_same_seq/1")
    cleanup = read_json(root, "cleanup")
    assert cleanup["exit_observed"]
    assert cleanup["exit_status"] == 23
    refute cleanup["kill_sent"]
  end

  @tag :database
  @tag timeout: 30_000
  test "an exception while the child is actually stopped CONTs, terminates and awaits that owned process" do
    directory = output("paused-failure")
    on_exit(fn -> cleanup(directory) end)

    assert {:error, {:fencing_verification_failed, result}} =
             FencingDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn
                 %{status: :paused} -> raise "injected exception with OS-stopped child"
                 _ -> :ok
               end
             )

    refute result.report["all_passed"]
    assert result.report["fault_probe_count"] == 0
    failed = result.report["failed_probe"]
    assert failed["reason"] =~ "injected exception with OS-stopped child"
    assert failed["fault"] == "model_before_accept_same_seq"
    assert is_integer(failed["pid"])
    root = Path.join([directory, failed["fault"], Integer.to_string(failed["repetition"])])
    cleanup = read_json(root, "cleanup")
    assert cleanup["pid"] == failed["pid"]
    assert cleanup["continue_sent"]
    assert cleanup["kill_sent"]
    assert cleanup["exit_observed"]
    assert is_integer(cleanup["exit_status"])
    assert cleanup["exit_status"] != 0

    {_state, status} =
      System.cmd("/bin/ps", ["-p", Integer.to_string(failed["pid"]), "-o", "state="])

    assert status != 0
    assert read_json(directory, "report") == result.report
  end

  test "a starting callback failure records incomplete acceptance without starting a process" do
    directory = output("starting-failure")
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {:error, {:fencing_verification_failed, result}} =
             FencingDemo.run(
               output: directory,
               repetitions: 1,
               on_progress: fn _ -> raise "injected starting failure" end
             )

    refute result.report["all_passed"]
    assert result.report["expected_probe_count"] == 5
    assert result.report["failed_probe"]["pid"] == nil
    assert result.report["failed_probe"]["repetition"] == 1
    assert result.report["failed_probe"]["reason"] =~ "injected starting failure"
  end

  defp read_term(root, name) do
    assert {:ok, value} = Codec.decode(File.read!(Path.join(root, name <> ".bin")))
    value
  end

  defp read_json(root, name), do: JSON.decode!(File.read!(Path.join(root, name <> ".json")))

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 5_000)

  defp await(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "controlled barrier timed out"
        Process.sleep(1)
        await(fun, deadline)
    end
  end

  defp output(label),
    do:
      Path.join(
        File.cwd!(),
        "artifacts/fencing-test-#{label}-#{System.unique_integer([:positive])}"
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
