defmodule AgentSystemsLab.P3Verification do
  @moduledoc """
  Scoped P3 acceptance of scheduling, fencing, load control and database recovery.

  Component evidence remains in its original subdirectory. Acceptance includes
  deliberately failed budget probes and preserved manual reconciliation entries;
  it does not mean every Run succeeded. Repetitions apply to the real signal and
  database fault windows. Scheduling and saturation are each measured once.
  """
  alias AgentSystemsLab.{
    Context,
    DatabaseFaultDemo,
    DurableTools,
    FencingDemo,
    History,
    LoadDemo,
    ModelResultStore,
    Recovery,
    ReconciliationQueue,
    Repo,
    Scheduler,
    SchedulingDemo
  }

  alias AgentSystemsLab.Storage.Codec

  @components [
    {"scheduling", "W11", SchedulingDemo},
    {"fencing", "W12", FencingDemo},
    {"load", "W13", LoadDemo},
    {"database", "W14", DatabaseFaultDemo}
  ]
  @default_output "artifacts/week14-p3"

  @doc "Returns the component order without creating Runs or starting processes."
  def components, do: Enum.map(@components, &elem(&1, 0))

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated_fixture(),
         output = Path.expand(Keyword.get(opts, :output, @default_output)),
         :ok <- create_output(output) do
      repetitions = Keyword.get(opts, :repetitions, 2)
      write_report(output, report([], [], repetitions, nil, false))
      execute(@components, [], output, opts, repetitions)
    end
  end

  defp execute([], completed, output, opts, repetitions) do
    result =
      safely(fn ->
        progress(opts, "audit", :starting, length(completed))
        audits = Enum.flat_map(completed, &audit_component/1)
        write_json(Path.join(output, "history-audit.json"), audits)
        progress(opts, "fresh_history", :starting, length(completed))
        fresh = fresh_history_audit(audits, output)
        true = audits === Enum.flat_map(completed, &audit_component/1)
        progress(opts, "fresh_history", :passed, length(completed))
        progress(opts, "audit", :passed, length(completed))
        {audits, fresh}
      end)

    case result do
      {:ok, {audits, fresh}} ->
        final = report(completed, audits, repetitions, nil, true, fresh)
        write_report(output, final)
        {:ok, %{output_dir: output, report: final}}

      {:error, reason} ->
        failure("audit", completed, output, repetitions, reason)
    end
  end

  defp execute([{name, week, module} | rest], completed, output, opts, repetitions) do
    directory = Path.join(output, name)

    result =
      safely(fn ->
        progress(opts, name, :starting, length(completed))

        component_options =
          component_options(name, directory, opts, repetitions, length(completed))

        case module.run(component_options) do
          {:ok, %{report: component_report}} ->
            true = component_report["all_passed"] == true
            criteria = criteria(name, component_report)
            true = Enum.all?(criteria, & &1["passed"])

            %{
              "component" => name,
              "week" => week,
              "evidence" => name,
              "all_passed" => true,
              "acceptance_criteria" => criteria,
              "report" => component_report
            }

          error ->
            raise "component returned #{inspect(error, limit: 30)}"
        end
      end)

    case result do
      {:ok, component} ->
        completed = completed ++ [component]
        write_report(output, report(completed, [], repetitions, nil, false))

        case safely(fn -> progress(opts, name, :passed, length(completed)) end) do
          {:ok, _} -> execute(rest, completed, output, opts, repetitions)
          {:error, reason} -> failure(name, completed, output, repetitions, reason)
        end

      {:error, reason} ->
        failure(name, completed, output, repetitions, reason)
    end
  end

  defp component_options("scheduling", directory, _opts, _repetitions, _completed),
    do: [output: directory, runs: 12]

  defp component_options(name, directory, opts, repetitions, completed) do
    callback = fn detail -> progress(opts, name, :probe, completed, detail) end
    base = [output: directory, on_progress: callback]

    if name == "load",
      do: base ++ [jobs: 12],
      else: base ++ [repetitions: repetitions]
  end

  defp criteria("scheduling", report) do
    [
      criterion(
        "shared_claims",
        "Concurrent pools claim distinct current intents.",
        report["unique_active_claims"] and report["observed_parallel_deliveries"] == 4,
        %{"parallel_deliveries" => report["observed_parallel_deliveries"]}
      ),
      criterion(
        "heartbeat",
        "Renewal retains the owner beyond its original expiry.",
        report["renewal"]["held_beyond_original_expiry"] and
          report["renewal"]["second_owner_rejected"] and
          report["renewal"]["deadline_preserved"],
        report["renewal"]
      ),
      criterion(
        "redelivery",
        "A killed delivery recovers one logical tool effect.",
        report["redelivery"]["actual_worker_kills"] == 1 and
          report["redelivery"]["effects"] == 1,
        report["redelivery"]
      ),
      criterion(
        "due_retry",
        "Background polling drives finite retries when due.",
        report["due_retry_driven_by_background_poll"] and report["model_retry_attempts"] == 3 and
          report["tool_retry_attempts"] == 3,
        Map.take(report, ["model_retry_attempts", "tool_retry_attempts"])
      ),
      criterion(
        "manual_queue",
        "Unknown results remain visible and unchanged during polling.",
        report["manual_queue_status"] == "blocked" and report["manual_unchanged_after_polls"],
        %{"run_id" => report["manual_queue_run_id"]}
      ),
      criterion(
        "application_restart",
        "A fresh application process discovers and completes the persisted intent.",
        report["fresh_application"]["application_scheduler_started"] and
          report["fresh_application"]["status"] == "succeeded" and
          report["fresh_application"]["effects"] == 1,
        report["fresh_application"]
      )
    ]
  end

  defp criteria("fencing", report) do
    [
      criterion(
        "os_pause",
        "A real SIGSTOP/SIGCONT pair pauses each owned BEAM.",
        report["sigstop_count"] == report["expected_probe_count"] and
          report["sigcont_count"] == report["expected_probe_count"] and
          Enum.all?(report["fault_probes"], & &1["whole_beam_paused"]),
        Map.take(report, ["sigstop_count", "sigcont_count", "same_seq_fencing_probes"])
      ),
      criterion(
        "late_result_fenced",
        "Resumed old executors cannot change successor facts.",
        report["stale_generation_overwrites"] == 0 and
          Enum.all?(report["fault_probes"], & &1["original_executor_fenced"]),
        %{"stale_generation_overwrites" => report["stale_generation_overwrites"]}
      ),
      criterion(
        "owned_process_cleanup",
        "Old Workers and executors stop and child exits are observed.",
        Enum.all?(report["fault_probes"], fn probe ->
          probe["worker_stopped"] and probe["executor_stopped"] and
            probe["child_exit_status"] == 0
        end),
        %{"probes" => report["fault_probe_count"]}
      ),
      criterion(
        "effect_preservation",
        "Takeover does not duplicate the Mock effect.",
        report["duplicate_mock_effects"] == 0,
        %{"duplicate_mock_effects" => report["duplicate_mock_effects"]}
      )
    ]
  end

  defp criteria("load", report) do
    saturation = report["saturation"]
    fairness = report["fairness"]
    budgets = report["budgets"]

    [
      criterion(
        "admission",
        "Saturation rejects excess admissions without partial Run records.",
        saturation["admitted"] == saturation["capacity"] and saturation["rejected"] > 0 and
          saturation["rejected_run_records"] == 0 and saturation["all_admitted_completed"],
        Map.take(saturation, ["offered", "admitted", "rejected", "rejected_run_records"])
      ),
      criterion(
        "bounded_processes",
        "The measured W13 delivery processes stay within queue and local pool limits.",
        saturation["peak_live_claims"] <= saturation["shared_max_inflight"] and
          saturation["peak_workers"] <= saturation["configured_pool_capacity"] and
          saturation["peak_task_processes"] <= 8 and
          saturation["peak_nonterminal_runs"] <= saturation["capacity"],
        Map.take(saturation, [
          "peak_live_claims",
          "peak_workers",
          "peak_executors",
          "peak_provider_children",
          "peak_task_processes",
          "peak_nonterminal_runs"
        ])
        |> Map.put("measured_categories", ["Worker", "executor", "provider", "owner watcher"])
        |> Map.put("separate_database_helper_limits", %{
          "claim_helper_per_scheduler" => 1,
          "renew_or_cleanup_helper_per_worker" => 1,
          "included_in_peak_task_processes" => false
        })
      ),
      criterion(
        "fair_service",
        "Aging services an old low priority Run and clears its starvation alert.",
        fairness["low_priority_service_rank_after_incumbent"] == 1 and
          fairness["starvation_detected_before_service"] and
          fairness["starvation_cleared_after_service"],
        Map.take(fairness, [
          "low_priority_service_rank_after_incumbent",
          "low_priority_original_wait_ms",
          "maximum_completion_gap_ms"
        ])
      ),
      criterion(
        "task_limits",
        "Budget exhaustion stops new effects and slow model work is reclaimed.",
        budgets["dispatch_cap_status"] == "failed" and budgets["dispatch_cap_tool_effects"] == 0 and
          budgets["slow_model_status"] == "failed" and budgets["slow_model_accepted_results"] == 0 and
          budgets["slow_provider_stopped_and_awaited"],
        Map.take(budgets, [
          "dispatch_cap_status",
          "dispatch_cap_tool_effects",
          "slow_model_status",
          "slow_model_accepted_results"
        ])
      ),
      criterion(
        "ambiguous_timeout",
        "A timed out ambiguous effect keeps manual evidence and admission credit.",
        budgets["ambiguous_tool_status"] == "blocked" and budgets["ambiguous_tool_effects"] == 1 and
          budgets["ambiguous_executor_stopped_and_awaited"] and
          budgets["unknown_requires_manual_evidence"],
        %{
          "run_id" => budgets["ambiguous_tool_run_id"],
          "effects" => budgets["ambiguous_tool_effects"]
        }
      )
    ]
  end

  defp criteria("database", report) do
    [
      criterion(
        "real_disconnect_windows",
        "Real connection faults cover rollback, lost commit acknowledgement, renewal, tool results and automatic polling recovery.",
        report["fault_probe_count"] == report["expected_probe_count"] and
          Enum.sort(Enum.uniq(Enum.map(report["fault_probes"], & &1["fault"]))) ==
            Enum.sort(DatabaseFaultDemo.cases()) and
          Enum.all?(report["fault_probes"], fn probe ->
            probe["isolated_child_repo"] and probe["shared_database_untouched"] and
              probe["database_error_observed"] and probe["connections_dropped"] >= 1
          end),
        Map.take(report, ["fault_probe_count", "expected_probe_count"])
      ),
      criterion(
        "database_recovery",
        "Every database fault probe completes its asserted recovery classification.",
        report["all_passed"] == true and is_nil(report["failed_probe"]),
        %{"classifications" => Enum.map(report["fault_probes"], & &1["classification"])}
      ),
      criterion(
        "fenced_reconnect",
        "Reconnection preserves successor authority and avoids duplicate Mock effects.",
        report["stale_generation_overwrites"] == 0 and report["duplicate_mock_effects"] == 0 and
          report["fault_probes"]
          |> Enum.filter(& &1["same_intent_takeover"])
          |> Enum.all?(& &1["stale_claim_rejected"]),
        Map.take(report, ["stale_generation_overwrites", "duplicate_mock_effects"])
        |> Map.put(
          "same_intent_takeover_probes",
          Enum.count(report["fault_probes"], & &1["same_intent_takeover"])
        )
      ),
      criterion(
        "lost_acknowledgement",
        "The proxy drops the real commit acknowledgement before the caller can observe it.",
        report["fault_probes"]
        |> Enum.filter(&(&1["fault"] == "commit_ack_lost"))
        |> Enum.all?(&(&1["commit_ack_dropped"] == 1)),
        %{
          "commit_acknowledgements_dropped" =>
            Enum.sum(Enum.map(report["fault_probes"], & &1["commit_ack_dropped"]))
        }
      ),
      criterion(
        "unknown_result_reconciliation",
        "An ambiguous tool result is recorded for manual reconciliation before trusted confirmation.",
        report["fault_probes"]
        |> Enum.filter(&(&1["fault"] == "tool_effect_pending_disconnect"))
        |> Enum.all?(fn probe ->
          probe["unknown_manual_observed"] and probe["operation_id_preserved"] and
            probe["effects"] == 1
        end),
        %{
          "manual_unknown_probes" =>
            Enum.count(report["fault_probes"], & &1["unknown_manual_observed"])
        }
      ),
      criterion(
        "connection_and_process_cleanup",
        "Reconnected probes retain consistent history and leave no active claim or owned child process.",
        Enum.all?(report["fault_probes"], fn probe ->
          probe["pending_claims"] == 0 and probe["child_exit_status"] == 0 and
            probe["state_matches_history"]
        end),
        %{"probes" => report["fault_probe_count"], "pending_claims" => 0}
      ),
      criterion(
        "automatic_poll_recovery",
        "The same Scheduler resumes background polling and completes the persisted intent after reconnection.",
        report["fault_probes"]
        |> Enum.filter(&(&1["fault"] == "auto_poll_reconnect"))
        |> Enum.all?(fn probe ->
          probe["same_scheduler_resumed"] and probe["automatic_completion"] and
            probe["same_intent_takeover"]
        end),
        %{
          "automatically_completed_probes" =>
            Enum.count(report["fault_probes"], &(&1["automatic_completion"] == true))
        }
      )
    ]
  end

  defp criterion(id, requirement, passed, measured),
    do: %{
      "id" => id,
      "requirement" => requirement,
      "passed" => passed == true,
      "measured" => measured
    }

  defp audit_component(component) do
    source = component["report"]
    ids = run_ids(source)
    true = ids != [] and length(ids) == length(Enum.uniq(ids))

    Enum.map(ids, fn id ->
      {:ok, before} = Recovery.load(id)
      before_stats = DurableTools.stats(id)
      {:ok, before_models} = ModelResultStore.list(id)
      {:ok, rebuilt} = History.rebuild(id, before.events, max_turns: before.state.max_turns)
      true = rebuilt === before.state
      {:ok, after_rebuild} = Recovery.load(id)
      true = after_rebuild === before
      true = before_stats == DurableTools.stats(id)
      {:ok, ^before_models} = ModelResultStore.list(id)

      %{rows: [[0]]} =
        Repo.query!(
          """
          SELECT count(*) FROM lab_intents
          WHERE run_id=$1 AND status='pending' AND claim_token IS NOT NULL
            AND claim_expires_at > clock_timestamp() AT TIME ZONE 'UTC'
          """,
          [id]
        )

      expected = expected_status(component["component"], source, id)
      true = Atom.to_string(before.state.status) == expected
      classification = if expected == "succeeded", do: "succeeded", else: "expected_" <> expected

      if expected == "blocked" do
        {:ok, %{safe_mode: :manual}} = ReconciliationQueue.get(id)
      end

      %{
        "component" => component["component"],
        "run_id" => id,
        "status" => expected,
        "classification" => classification,
        "state_sha256" => Context.hash(before.state),
        "projection_sha256" => Context.hash(before),
        "events" => length(before.events),
        "state_matches_history" => true,
        "persisted_facts_unchanged_by_rebuild" => true,
        "tool_effects" => before_stats.effects,
        "tool_stats_sha256" => Context.hash(before_stats),
        "recorded_model_results" => length(before_models),
        "recorded_model_results_sha256" => Context.hash(before_models),
        "live_claims" => 0,
        "manual_reconciliation_preserved" => expected == "blocked"
      }
    end)
  end

  defp fresh_history_audit(audits, output) do
    expected =
      Enum.map(audits, fn audit ->
        {:ok, snapshot} = Recovery.load(audit["run_id"])
        true = Context.hash(snapshot.state) == audit["state_sha256"]
        {audit["run_id"], snapshot.state}
      end)

    {:ok, encoded} = Codec.encode(expected)
    expected_file = Path.join(output, "fresh-history-expected.base64")
    File.write!(expected_file, Base.encode64(encoded) <> "\n")
    environment = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev
    report_file = Path.join(output, "fresh-history-audit.json")

    script = """
    config = Config.Reader.read!("config/config.exs", env: #{inspect(environment)}, target: :host)
    Application.put_all_env(config)
    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    nil = Process.whereis(AgentSystemsLab.Scheduler)
    AgentSystemsLab.Storage.preload_vocabulary()
    expected_bytes = #{inspect(expected_file)} |> File.read!() |> String.trim() |> Base.decode64!()
    {:ok, expected} = AgentSystemsLab.Storage.Codec.decode(expected_bytes)
    base = %{
      "schema_version" => 1, "pid" => System.pid(), "fresh_vm" => true,
      "scheduler_enabled" => Application.get_env(:agent_systems_lab, :scheduler_enabled),
      "scheduler_started" => false, "expected_run_count" => length(expected),
      "run_count" => 0, "all_passed" => false, "audits" => [],
      "cleanup_evidence" => "fresh-history-cleanup.json"
    }
    write = fn report ->
      File.write!(#{inspect(report_file <> ".tmp")}, JSON.encode!(report) <> "\\n")
      File.rename!(#{inspect(report_file <> ".tmp")}, #{inspect(report_file)})
    end
    write.(base)
    report = Enum.reduce(expected, base, fn {id, state}, acc ->
      {:ok, audit} = AgentSystemsLab.RebuildAudit.run(id, state)
      true = audit["same_as_expected_state"]
      true = map_size(audit["effect_boundary_calls"]) == 27
      true = Enum.all?(audit["effect_boundary_calls"], fn {_, count} -> count == 0 end)
      next = %{acc | "audits" => acc["audits"] ++ [audit], "run_count" => acc["run_count"] + 1}
      write.(next)
      next
    end)
    true = report["run_count"] == length(expected)
    report = %{report | "all_passed" => true}
    write.(report)
    IO.puts("FRESH_P3_HISTORY_AUDIT=" <> JSON.encode!(Map.take(report, ["pid", "run_count", "all_passed"])))
    """

    fresh_history_child(script, output)
    {:ok, fresh} = JSON.decode(File.read!(report_file))
    true = fresh["fresh_vm"] and fresh["all_passed"] and fresh["pid"] != System.pid()
    false = fresh["scheduler_enabled"]
    false = fresh["scheduler_started"]
    true = fresh["run_count"] == length(audits) and fresh["expected_run_count"] == length(audits)
    true = Enum.map(fresh["audits"], & &1["run_id"]) == Enum.map(audits, & &1["run_id"])

    for {child, parent} <- Enum.zip(fresh["audits"], audits) do
      true = child["same_as_expected_state"] and child["full_matches_checkpoint"]
      true = child["state_sha256"] == parent["state_sha256"]
      true = child["status"] == parent["status"]
      true = child["recorded_model_results"] == parent["recorded_model_results"]
      true = map_size(child["effect_boundary_calls"]) == 27
      true = Enum.all?(child["effect_boundary_calls"], fn {_, count} -> count == 0 end)
    end

    cleanup = JSON.decode!(File.read!(Path.join(output, "fresh-history-cleanup.json")))

    true =
      cleanup["pid"] == fresh["pid"] and cleanup["exit_observed"] and cleanup["exit_status"] == 0

    fresh
  end

  defp fresh_history_child(script, output) do
    executable = System.find_executable("elixir") || raise "elixir is unavailable"
    args = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++ ["-e", script]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    Process.put({__MODULE__, port, :log}, [])

    try do
      status = await_history_exit(port, System.monotonic_time(:millisecond) + 20_000)
      if status != 0, do: raise("fresh history child exited with status #{status}")
    after
      owned? = Port.info(port, :os_pid) == {:os_pid, pid}

      if owned?,
        do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      try do
        status = await_history_exit(port, System.monotonic_time(:millisecond) + 2_000)

        write_json(Path.join(output, "fresh-history-cleanup.json"), %{
          "pid" => Integer.to_string(pid),
          "kill_sent" => owned?,
          "exit_observed" => true,
          "exit_status" => status
        })
      after
        chunks = Process.delete({__MODULE__, port, :log}) || []

        File.write!(
          Path.join(output, "fresh-history.log"),
          chunks |> Enum.reverse() |> IO.iodata_to_binary()
        )

        Process.delete({__MODULE__, port, :exit})
      end
    end
  end

  defp await_history_exit(port, deadline) do
    case Process.get({__MODULE__, port, :exit}) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)
        if remaining <= 0, do: raise("fresh history child did not exit within the bounded wait")

        receive do
          {^port, {:data, bytes}} ->
            key = {__MODULE__, port, :log}
            Process.put(key, [bytes | Process.get(key, [])])
            await_history_exit(port, deadline)

          {^port, {:exit_status, status}} ->
            Process.put({__MODULE__, port, :exit}, status)
            status
        after
          remaining -> raise "fresh history child did not exit within the bounded wait"
        end

      status ->
        status
    end
  end

  defp expected_status("scheduling", report, id),
    do: if(id == report["manual_queue_run_id"], do: "blocked", else: "succeeded")

  defp expected_status("load", report, id) do
    budgets = report["budgets"]

    cond do
      id in [budgets["dispatch_cap_run_id"], budgets["slow_model_run_id"]] -> "failed"
      id == budgets["ambiguous_tool_run_id"] -> "blocked"
      true -> "succeeded"
    end
  end

  defp expected_status("database", report, id) do
    probe = Enum.find(report["fault_probes"], &(&1["run_id"] == id))
    probe["status"] || "succeeded"
  end

  defp expected_status("fencing", _report, _id), do: "succeeded"

  defp run_ids(report) do
    ids =
      Map.get(report, "run_ids") || Enum.map(Map.get(report, "fault_probes", []), & &1["run_id"])

    if failed = report["failed_probe"], do: Enum.uniq(ids ++ [failed["run_id"]]), else: ids
  end

  defp report(completed, audits, repetitions, failed, audit_complete, fresh \\ nil) do
    frequencies = Enum.frequencies_by(audits, & &1["classification"])

    %{
      "schema_version" => 1,
      "phase" => "P3",
      "repetitions" => repetitions,
      "repetition_scope" =>
        "Signal and database fault windows; scheduling and saturation each run once.",
      "components" => completed,
      "component_count" => length(completed),
      "expected_component_count" => length(@components),
      "run_ids" => Enum.flat_map(completed, &run_ids(&1["report"])),
      "queue_names" => Enum.flat_map(completed, &Map.get(&1["report"], "queue_names", [])),
      "history_audits" => audits,
      "history_audit_count" => length(audits),
      "fresh_history_audit" => fresh,
      "fresh_history_audit_count" => if(is_map(fresh), do: fresh["run_count"], else: 0),
      "audit_complete" => audit_complete,
      "outcomes" => %{
        "succeeded" => Map.get(frequencies, "succeeded", 0),
        "expected_failed" => Map.get(frequencies, "expected_failed", 0),
        "expected_blocked" => Map.get(frequencies, "expected_blocked", 0),
        "all_runs_succeeded" =>
          audit_complete and map_size(frequencies) == 1 and
            Map.get(frequencies, "succeeded", 0) > 0
      },
      "failed_component" => failed,
      "all_passed" =>
        is_nil(failed) and length(completed) == length(@components) and audit_complete and
          is_map(fresh) and fresh["all_passed"] == true and fresh["run_count"] == length(audits),
      "scope" =>
        "Controlled local PostgreSQL, owned BEAM processes and Mock tools. W13 task samples cover Workers/executors/providers/watchers; W14 additionally permits one claim helper per Scheduler and one renew-or-cleanup helper per Worker. These observations are not a global BEAM limit, production SLO or arbitrary external exactly-once guarantee."
    }
  end

  defp failure(name, completed, output, repetitions, reason) do
    raw = read_component_report(output, name)
    failed = %{"component" => name, "reason" => reason, "evidence" => name, "report" => raw}
    failed_report = report(completed, [], repetitions, failed, false)

    failed_report =
      if is_map(raw) do
        failed_report
        |> Map.update!("run_ids", &Enum.uniq(&1 ++ run_ids(raw)))
        |> Map.update!("queue_names", &Enum.uniq(&1 ++ Map.get(raw, "queue_names", [])))
      else
        failed_report
      end

    write_report(output, failed_report)
    {:error, {:p3_verification_failed, %{output_dir: output, report: failed_report}}}
  end

  defp read_component_report(output, name) do
    with {:ok, bytes} <- File.read(Path.join([output, name, "report.json"])),
         {:ok, value} <- JSON.decode(bytes),
         true <- is_map(value) do
      value
    else
      _ -> nil
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp progress(opts, component, status, completed, detail \\ nil) do
    if callback = opts[:on_progress],
      do:
        callback.(%{
          component: component,
          status: status,
          completed: completed,
          total: length(@components),
          detail: detail
        })
  end

  defp options(opts) when is_list(opts) do
    valid_keyword = Keyword.keyword?(opts)
    output = if valid_keyword, do: Keyword.get(opts, :output, @default_output)
    repetitions = if valid_keyword, do: Keyword.get(opts, :repetitions, 2)

    if valid_keyword and Keyword.keys(opts) -- [:output, :repetitions, :on_progress] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(repetitions) and repetitions in 1..10 and is_binary(output) and
         String.valid?(output) and String.trim(output) != "" and
         not String.contains?(output, <<0>>) and
         (is_nil(opts[:on_progress]) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_p3_options}
  end

  defp options(_), do: {:error, :invalid_p3_options}

  defp isolated_fixture do
    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
         Process.whereis(Scheduler),
       do: {:error, :global_scheduler_enabled},
       else: :ok
  end

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        error -> error
      end
    end
  end

  defp write_report(output, value), do: write_json(Path.join(output, "report.json"), value)

  defp write_json(path, value) do
    temp = path <> ".tmp"
    File.write!(temp, JSON.encode!(value) <> "\n")
    File.rename!(temp, path)
  end
end
