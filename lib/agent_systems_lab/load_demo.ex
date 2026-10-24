defmodule AgentSystemsLab.LoadDemo do
  @moduledoc "Repeatable, scoped saturation, fairness and task-reclamation measurements."
  alias AgentSystemsLab.{
    DurableTools,
    ModelResultStore,
    QueueStore,
    Recovery,
    ReconciliationQueue,
    Repo,
    RetryStore,
    Scheduler,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Storage.Codec

  @default_output "artifacts/week13-load"
  @terminal [:succeeded, :failed, :cancelled]

  def run(opts \\ []) do
    with :ok <- options(opts),
         output = Path.expand(Keyword.get(opts, :output, @default_output)),
         :ok <- create_output(output) do
      prefix = "load-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      Process.put({__MODULE__, :ids}, [])
      Process.put({__MODULE__, :queues}, [])
      Process.put({__MODULE__, :timeline}, [])

      try do
        progress(opts, :saturation)
        saturation = saturation(prefix, Keyword.get(opts, :jobs, 12))
        progress(opts, :fairness)
        fairness = fairness(prefix)
        progress(opts, :budgets)
        budgets = budgets(prefix)
        ids = Enum.reverse(Process.get({__MODULE__, :ids}))
        queues = Enum.reverse(Process.get({__MODULE__, :queues}))
        journals = Map.new(ids, &{&1, evidence(&1)})
        {:ok, encoded} = Codec.encode(inert(journals))
        File.write!(Path.join(output, "journals.bin"), encoded)
        write_json(Path.join(output, "timeline.json"), Enum.reverse(timeline()))

        report = %{
          "schema_version" => 1,
          "all_passed" => true,
          "run_ids" => ids,
          "queue_names" => queues,
          "saturation" => saturation,
          "fairness" => fairness,
          "budgets" => budgets,
          "scope" =>
            "Two local pools and their task-related children; no global BEAM or production SLO claim."
        }

        write_json(Path.join(output, "metrics.json"), report)
        write_json(Path.join(output, "report.json"), report)
        progress(opts, :complete)
        {:ok, %{output_dir: output, report: report}}
      rescue
        exception -> failure(output, Exception.format(:error, exception, __STACKTRACE__))
      catch
        kind, reason -> failure(output, Exception.format(kind, reason, __STACKTRACE__))
      after
        Process.delete({__MODULE__, :ids})
        Process.delete({__MODULE__, :queues})
        Process.delete({__MODULE__, :timeline})
      end
    end
  end

  defp saturation(prefix, count) do
    queue = queue(prefix <> "-saturation", capacity: count, max_inflight: 2)
    offered = for index <- 1..(count * 2), do: "#{prefix}-offered-#{index}"

    results =
      offered
      |> Task.async_stream(
        fn id ->
          {id, Recovery.create_run(id, "bounded admission", queue: queue, script: [{:final, id}])}
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {accepted, rejected} =
      Enum.split_with(results, fn {_id, result} -> match?({:ok, _}, result) end)

    ids = Enum.map(accepted, &elem(&1, 0))
    Enum.each(ids, &remember_id/1)
    ^count = length(ids)
    ^count = length(rejected)

    Enum.each(rejected, fn {id, {:error, reason}} ->
      :queue_full = reason
      %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM lab_runs WHERE id=$1", [id])
    end)

    parent = self()
    ref = make_ref()
    gate_enabled = :atomics.new(1, [])
    :atomics.put(gate_enabled, 1, 1)
    baseline_children = Task.Supervisor.children(AgentSystemsLab.ProviderSupervisor)

    hook = fn
      :after_frame -> if :atomics.get(gate_enabled, 1) == 1, do: gate(parent, ref)
      _ -> :ok
    end

    sampled =
      with_pool(queue, [max_workers: 2, recovery_options: [hook: hook]], fn first ->
        with_pool(queue, [max_workers: 2, recovery_options: [hook: hook]], fn second ->
          providers = for _ <- 1..2, do: receive_gate(ref)
          await(fn -> active_count([first, second]) == 2 end)

          samples =
            for _ <- 1..12 do
              sample = sample(queue, ids, [first, second], baseline_children)
              true = sample["active_workers"] <= 2
              true = sample["active_executors"] <= 2
              true = sample["new_provider_children"] <= 2
              true = sample["live_claims"] <= 2
              true = sample["nonterminal_runs"] <= count
              # Local delivery has a Worker, executor, provider and owner watcher.
              true = sample["measured_task_processes"] <= 8
              Process.sleep(5)
              sample
            end

          for _ <- 1..200, pool <- [first, second], do: Scheduler.wake(pool)
          await(fn -> Enum.all?([first, second], &(mailbox(&1) == 0)) end)
          :atomics.put(gate_enabled, 1, 0)
          Enum.each(providers, &send(&1, {ref, :release}))
          Enum.each(ids, &await_status(&1, :succeeded))
          await(fn -> active_count([first, second]) == 0 end)
          sample(queue, ids, [first, second], baseline_children)
          samples
        end)
      end)

    second_wave = for index <- 1..2, do: "#{prefix}-credit-#{index}"

    Enum.each(second_wave, fn id ->
      create(id, queue, script: [{:final, "credit returned"}])
    end)

    with_pool(queue, [max_workers: 2], fn _ ->
      Enum.each(second_wave, &await_status(&1, :succeeded))
    end)

    %{
      "queue" => queue,
      "offered" => length(offered),
      "admitted" => count,
      "rejected" => count,
      "rejected_run_records" => 0,
      "capacity" => count,
      "shared_max_inflight" => 2,
      "configured_pool_capacity" => 4,
      "peak_workers" => peak(sampled, "active_workers"),
      "peak_executors" => peak(sampled, "active_executors"),
      "peak_provider_children" => peak(sampled, "new_provider_children"),
      "peak_task_processes" => peak(sampled, "measured_task_processes"),
      "peak_live_claims" => peak(sampled, "live_claims"),
      "peak_nonterminal_runs" => peak(sampled, "nonterminal_runs"),
      "sampled_peak_mailbox" => peak(sampled, "largest_mailbox"),
      "wake_hints_sent" => 400,
      "wake_mailboxes_drained" => true,
      "returned_credits_admitted" => length(second_wave),
      "all_admitted_completed" => true
    }
  end

  defp fairness(prefix) do
    queue =
      queue(prefix <> "-fairness", capacity: 12, max_inflight: 1, aging_ms: 10, starvation_ms: 40)

    blocker = prefix <> "-fair-blocker"
    low = prefix <> "-fair-low"
    create(blocker, queue, priority: 9, script: [{:final, "incumbent"}])
    parent = self()
    ref = make_ref()
    once = :atomics.new(1, [])

    hook = fn
      :after_input -> if :atomics.add_get(once, 1, 1) == 1, do: gate(parent, ref)
      _ -> :ok
    end

    with_pool(queue, [max_workers: 2, recovery_options: [hook: hook]], fn _pool ->
      executor = receive_gate(ref)
      create(low, queue, priority: 0, script: [{:final, "old low priority"}])
      high_ids = for index <- 1..6, do: "#{prefix}-fair-high-#{index}"

      for id <- high_ids do
        Process.sleep(20)
        create(id, queue, priority: 9, script: [{:final, "new high priority"}])
      end

      starved =
        await(fn ->
          {:ok, entries} = QueueStore.starvation(queue)
          if Enum.any?(entries, &(&1.run_id == low and &1.effective_priority == 9)), do: entries
        end)

      {:ok, before_stats} = QueueStore.stats(queue)
      send(executor, {ref, :release})
      ids = [blocker, low | high_ids]

      # Recovery.load/1 takes FOR SHARE. Polling it while dispatch uses SKIP
      # LOCKED can cause the observer itself to defer the oldest ready Run.
      # Observe completion without locks, then validate each durable snapshot.
      await(fn ->
        %{rows: [[completed]]} =
          Repo.query!(
            "SELECT count(*) FROM lab_runs WHERE id=ANY($1) AND status='succeeded'",
            [ids]
          )

        completed == length(ids)
      end)

      Enum.each(ids, &await_status(&1, :succeeded))
      order = completion_order(ids)
      [^blocker, ^low | _] = Enum.map(order, & &1["run_id"])
      {:ok, []} = QueueStore.starvation(queue)
      {:ok, after_stats} = QueueStore.stats(queue)

      %{
        "queue" => queue,
        "aging_ms" => 10,
        "starvation_ms" => 40,
        "high_priority_arrivals" => length(high_ids),
        "low_priority_run_id" => low,
        "low_priority_service_rank_after_incumbent" => 1,
        "low_priority_original_wait_ms" => Enum.find(order, &(&1["run_id"] == low))["wait_ms"],
        "starvation_detected_before_service" => true,
        "starvation_cleared_after_service" => true,
        "starvation_before_service" => json(starved),
        "queue_before_service" => json(before_stats),
        "queue_after_service" => json(after_stats),
        "completion_order" => order,
        "maximum_completion_gap_ms" => completion_gap(order),
        "all_runs_progressed" => true
      }
    end)
  end

  defp budgets(prefix) do
    # SQL preparation must reach the observed model/effect boundary before the
    # experiment deliberately exhausts the same persisted execution budget.
    probe_execution_ms = 1_000
    probe_stall_ms = 5_000
    cap_queue = queue(prefix <> "-budget", capacity: 2, max_inflight: 1)
    capped = prefix <> "-capped"
    create(capped, cap_queue, task_budget: [max_dispatches: 1], script: tool_script())

    with_pool(cap_queue, [max_workers: 1], fn _ ->
      await_status(capped, :failed)
    end)

    %{effects: 0} = DurableTools.stats(capped)
    {:ok, capped_snapshot} = Recovery.load(capped)

    {:ok, %{config: %{max_dispatches: 1}, progress: %{dispatches: 1}} = cap_budget} =
      TaskBudgetStore.load(capped)

    1 = capped_snapshot.recovery.progress.cursor

    slow_queue = queue(prefix <> "-slow", capacity: 2, max_inflight: 1)
    slow = prefix <> "-slow-model"
    follower = prefix <> "-slow-follower"

    create(slow, slow_queue,
      task_budget: [execution_timeout_ms: probe_execution_ms],
      script: [
        {:stream,
         [{:text_delta, "started"}, {:sleep, probe_stall_ms}, {:text_delta, "too late"}, :done]}
      ]
    )

    create(follower, slow_queue, script: [{:final, "reclaimed slot"}])
    parent = self()
    model_ref = make_ref()
    first_frame = :atomics.new(1, [])

    model_hook = fn
      :after_frame ->
        if :atomics.add_get(first_frame, 1, 1) == 1,
          do: send(parent, {model_ref, :observed, self()})

      _ ->
        :ok
    end

    with_pool(slow_queue, [max_workers: 2, recovery_options: [hook: model_hook]], fn pool ->
      provider = receive_observation(model_ref)
      monitor = Process.monitor(provider)
      await_status(slow, :failed)
      await_down(monitor, provider)
      await_status(follower, :succeeded)
      await(fn -> Scheduler.status(pool).active == [] end)
    end)

    {:ok, []} = ModelResultStore.list(slow)
    {:ok, slow_snapshot} = Recovery.load(slow)

    manual_queue = queue(prefix <> "-manual", capacity: 2, max_inflight: 1)
    manual = prefix <> "-manual-timeout"
    manual_follower = prefix <> "-manual-follower"

    create(manual, manual_queue,
      task_budget: [execution_timeout_ms: probe_execution_ms],
      mock_mode: :unqueryable,
      script: tool_script()
    )

    create(manual_follower, manual_queue, script: [{:final, "manual reclaimed slot"}])

    tool_ref = make_ref()

    hook = fn
      :after_effect ->
        send(parent, {tool_ref, :observed, self()})
        Process.sleep(probe_stall_ms)

      _ ->
        :ok
    end

    with_pool(manual_queue, [max_workers: 2, recovery_options: [tool_hook: hook]], fn pool ->
      executor = receive_observation(tool_ref)
      monitor = Process.monitor(executor)
      await_status(manual, :blocked)
      await_down(monitor, executor)
      await_status(manual_follower, :succeeded)
      await(fn -> Scheduler.status(pool).active == [] end)
    end)

    %{effects: 1} = DurableTools.stats(manual)
    {:ok, %{safe_mode: :manual}} = ReconciliationQueue.get(manual)
    {:ok, retained} = QueueStore.stats(manual_queue)
    1 = retained.active
    1 = retained.blocked
    1 = retained.available_slots

    %{
      "dispatch_cap_run_id" => capped,
      "dispatch_cap_status" => "failed",
      "dispatch_cap_accepted_model_results" => 1,
      "dispatch_cap_tool_effects" => 0,
      "dispatch_cap_reason" => inspect(capped_snapshot.state.terminal_reason),
      "dispatch_budget" => json(cap_budget),
      "slow_model_run_id" => slow,
      "slow_model_status" => "failed",
      "slow_model_reason" => inspect(slow_snapshot.state.terminal_reason),
      "slow_model_accepted_results" => 0,
      "slow_provider_stopped_and_awaited" => true,
      "slow_follower_completed" => true,
      "ambiguous_tool_run_id" => manual,
      "ambiguous_tool_status" => "blocked",
      "ambiguous_tool_effects" => 1,
      "ambiguous_executor_stopped_and_awaited" => true,
      "ambiguous_follower_completed" => true,
      "manual_queue_credit_retained" => json(retained),
      "unknown_requires_manual_evidence" => true
    }
  end

  defp sample(queue, ids, pools, baseline_children) do
    active = Enum.flat_map(pools, &Scheduler.status(&1).active)
    workers = active |> Enum.map(& &1.worker) |> Enum.filter(&Process.alive?/1)

    executors =
      active |> Enum.map(& &1.executor) |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))

    providers = Task.Supervisor.children(AgentSystemsLab.ProviderSupervisor) -- baseline_children

    # Owner watchers monitor provider tasks and are counted by their monitors.
    watchers =
      for provider <- providers,
          {:monitored_by, monitors} = Process.info(provider, :monitored_by),
          watcher <- monitors,
          watcher not in executors,
          watcher not in [Process.whereis(AgentSystemsLab.ProviderSupervisor)],
          do: watcher

    pids = Enum.uniq(workers ++ executors ++ providers ++ watchers)

    %{rows: [[claims]]} =
      Repo.query!(
        "SELECT count(*) FROM lab_intents WHERE run_id=ANY($1) AND status='pending' AND claim_expires_at>clock_timestamp()",
        [ids]
      )

    %{rows: [[nonterminal]]} =
      Repo.query!(
        "SELECT count(*) FROM lab_runs WHERE id=ANY($1) AND status NOT IN ('succeeded','failed','cancelled')",
        [ids]
      )

    {:ok, stats} = QueueStore.stats(queue)

    measured = %{
      "at_monotonic_ms" => System.monotonic_time(:millisecond),
      "queue" => queue,
      "active_workers" => length(workers),
      "active_executors" => length(executors),
      "new_provider_children" => length(providers),
      "measured_task_processes" => length(pids),
      "live_claims" => claims,
      "nonterminal_runs" => nonterminal,
      "largest_mailbox" => Enum.max(Enum.map(pools ++ pids, &mailbox/1), fn -> 0 end),
      "queue_stats" => json(stats)
    }

    Process.put({__MODULE__, :timeline}, [measured | timeline()])
    measured
  end

  defp completion_order(ids) do
    Repo.query!(
      """
      SELECT r.id, r.inserted_at, min(c.inserted_at), r.updated_at,
        extract(epoch FROM (min(c.inserted_at)-min(i.inserted_at)))*1000,
        extract(epoch FROM (r.updated_at-r.inserted_at))*1000
      FROM lab_runs r
      JOIN lab_contexts c ON c.run_id=r.id
      JOIN lab_intents i ON i.run_id=r.id
      WHERE r.id=ANY($1)
      GROUP BY r.id
      ORDER BY r.updated_at,r.id
      """,
      [ids]
    ).rows
    |> Enum.map(fn [id, inserted, started, completed, wait, latency] ->
      %{
        "run_id" => id,
        "admitted_at" => NaiveDateTime.to_iso8601(inserted),
        "context_started_at" => NaiveDateTime.to_iso8601(started),
        "completed_at" => NaiveDateTime.to_iso8601(completed),
        "wait_ms" => Decimal.to_float(wait),
        "completion_latency_ms" => Decimal.to_float(latency)
      }
    end)
  end

  defp completion_gap(order) do
    order
    |> Enum.map(&NaiveDateTime.from_iso8601!(&1["completed_at"]))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [before, after_time] ->
      NaiveDateTime.diff(after_time, before, :millisecond)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp with_pool(queue, extra, fun) do
    {:ok, pool} =
      Scheduler.start_link(
        [queue: queue, lease_ms: 800, renew_interval_ms: 100, poll_interval_ms: 10] ++ extra
      )

    try do
      fun.(pool)
    after
      if Process.alive?(pool), do: Scheduler.stop(pool)
    end
  end

  defp queue(name, opts) do
    {:ok, _} = QueueStore.create(name, opts)
    Process.put({__MODULE__, :queues}, [name | Process.get({__MODULE__, :queues})])
    name
  end

  defp create(id, queue, opts) do
    remember_id(id)
    {:ok, _} = Recovery.create_run(id, "load demonstration", [queue: queue] ++ opts)
    id
  end

  defp remember_id(id),
    do: Process.put({__MODULE__, :ids}, [id | Process.get({__MODULE__, :ids})])

  defp timeline, do: Process.get({__MODULE__, :timeline}, [])
  defp active_count(pools), do: Enum.sum(Enum.map(pools, &length(Scheduler.status(&1).active)))

  defp mailbox(pid) do
    case Process.info(pid, :message_queue_len) do
      nil -> 0
      {:message_queue_len, value} -> value
    end
  end

  defp peak(samples, key), do: samples |> Enum.map(& &1[key]) |> Enum.max(fn -> 0 end)

  defp tool_script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 13}}},
      {:final, "done"}
    ]

  defp await_status(id, status) do
    await(fn ->
      case Recovery.load(id) do
        {:ok, %{state: %{status: ^status}} = saved} ->
          saved

        {:ok, %{state: %{status: terminal}} = saved} when terminal in @terminal ->
          raise "unexpected terminal status for #{id}: #{inspect(saved.state)}"

        _ ->
          nil
      end
    end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 15_000)

  defp await(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("load observation timed out")

        Process.sleep(10)
        await(fun, deadline)
    end
  end

  defp gate(parent, ref) do
    send(parent, {ref, :gate, self()})
    receive do: ({^ref, :release} -> :ok)
  end

  defp receive_gate(ref) do
    receive do
      {^ref, :gate, pid} -> pid
    after
      5_000 -> raise "load gate not reached"
    end
  end

  defp receive_observation(ref) do
    receive do
      {^ref, :observed, pid} -> pid
    after
      5_000 -> raise "task observation not reached"
    end
  end

  defp await_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise "timed-out task remained alive"
    end
  end

  defp evidence(id) do
    {:ok, snapshot} = Recovery.load(id)
    {:ok, operations} = DurableTools.list(id)
    {:ok, recordings} = ModelResultStore.list(id)
    {:ok, retries} = RetryStore.list(id)
    {:ok, queue} = ReconciliationQueue.list(run_id: id)

    %{
      snapshot: snapshot,
      operations: operations,
      recordings: recordings,
      retries: retries,
      reconciliation: queue,
      stats: DurableTools.stats(id)
    }
  end

  defp progress(opts, phase), do: if(opts[:on_progress], do: opts[:on_progress].(phase))

  defp create_output(path),
    do: if(File.exists?(path), do: {:error, {:output_exists, path}}, else: File.mkdir_p(path))

  defp options(opts) when is_list(opts) do
    output = if Keyword.keyword?(opts), do: Keyword.get(opts, :output, @default_output), else: nil
    jobs = if Keyword.keyword?(opts), do: Keyword.get(opts, :jobs, 12), else: nil

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:output, :jobs, :on_progress] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and is_integer(jobs) and
         jobs in 6..100 and
         is_binary(output) and String.valid?(output) and String.trim(output) != "" and
         not String.contains?(output, <<0>>) and
         (is_nil(opts[:on_progress]) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_load_demo_options}
  end

  defp options(_), do: {:error, :invalid_load_demo_options}
  defp inert(%{__struct__: _} = value), do: value |> Map.from_struct() |> inert()

  defp inert(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {inert(key), inert(item)} end)

  defp inert(value) when is_list(value), do: Enum.map(value, &inert/1)

  defp inert(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  defp inert(value), do: value
  defp json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value) when value in [nil, true, false], do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)

  defp json(value) when is_tuple(value) or is_pid(value) or is_reference(value),
    do: inspect(value)

  defp json(value), do: value
  defp write_json(path, value), do: File.write!(path, JSON.encode!(json(value)) <> "\n")

  defp failure(output, reason) do
    report = %{
      "schema_version" => 1,
      "all_passed" => false,
      "run_ids" => Enum.reverse(Process.get({__MODULE__, :ids}, [])),
      "queue_names" => Enum.reverse(Process.get({__MODULE__, :queues}, [])),
      "error" => reason
    }

    write_json(Path.join(output, "report.json"), report)
    write_json(Path.join(output, "timeline.json"), Enum.reverse(timeline()))
    {:error, {:load_demo_failed, %{output_dir: output, report: report}}}
  end
end
