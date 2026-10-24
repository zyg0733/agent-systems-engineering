defmodule AgentSystemsLab.SchedulingDemo do
  @moduledoc "Scoped background scheduling, renewal, redelivery and due-retry experiments."
  alias AgentSystemsLab.{
    Context,
    DurableTools,
    IntentStore,
    ModelResultStore,
    Recovery,
    RecoveryStore,
    ReconciliationQueue,
    RetryStore,
    Scheduler
  }

  alias AgentSystemsLab.Storage.Codec

  def run(opts \\ []) do
    with :ok <- options(opts),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week11-scheduling")),
         :ok <- create_output(output) do
      prefix =
        "schedule-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

      planned_ids =
        Enum.map(1..Keyword.get(opts, :runs, 12), &"#{prefix}-batch-#{&1}") ++
          Enum.map(~w(renewal redelivery manual application), &(prefix <> "-" <> &1))

      write_json(Path.join(output, "experiment.json"), %{
        "schema_version" => 1,
        "run_id_prefix" => prefix,
        "planned_run_ids" => planned_ids,
        "scope" => "Only these fixture IDs may be created; an interrupted Run may not exist."
      })

      try do
        batch = batch(prefix, Keyword.get(opts, :runs, 12))
        renewal = renewal(prefix)
        duplicate = duplicate(prefix)
        manual = manual(prefix)
        fresh = fresh_application(prefix, output)
        ids = batch.ids ++ [renewal.id, duplicate.id, manual.id, fresh.id]
        journals = Map.new(ids, &{&1, evidence(&1)})
        {:ok, data} = Codec.encode(inert(journals))
        File.write!(Path.join(output, "journals.bin"), data)

        report = %{
          "schema_version" => 1,
          "all_passed" => true,
          "run_id_prefix" => prefix,
          "run_ids" => ids,
          "batch_runs" => length(batch.ids),
          "batch_pools" => 2,
          "workers_per_pool" => 2,
          "observed_parallel_deliveries" => batch.parallel,
          "unique_active_claims" => true,
          "model_retry_attempts" => batch.model_attempts,
          "tool_retry_attempts" => batch.tool_attempts,
          "due_retry_driven_by_background_poll" => true,
          "renewal" => Map.drop(renewal, [:id]),
          "redelivery" => Map.drop(duplicate, [:id]),
          "manual_queue_run_id" => manual.id,
          "manual_queue_status" => "blocked",
          "manual_unchanged_after_polls" => true,
          "fresh_application" => Map.drop(fresh, [:id])
        }

        write_json(Path.join(output, "report.json"), report)
        {:ok, %{output_dir: output, report: report}}
      rescue
        exception -> failure(output, prefix, Exception.format(:error, exception, __STACKTRACE__))
      catch
        kind, reason -> failure(output, prefix, Exception.format(kind, reason, __STACKTRACE__))
      end
    end
  end

  defp batch(prefix, count) do
    ids = for index <- 1..count, do: "#{prefix}-batch-#{index}"

    for {id, index} <- Enum.with_index(ids) do
      special =
        case index do
          0 ->
            [
              retry_policy: policy(),
              model_attempt_scripts: %{
                0 => [{:error, :unavailable}, {:error, :rate_limited}, hd(script())]
              }
            ]

          1 ->
            [retry_policy: policy(), mock_transient_failures: 2]

          _ ->
            []
        end

      {:ok, _} =
        Recovery.create_run(
          id,
          "background batch",
          [script: script(), priority: rem(index, 10)] ++ special
        )
    end

    parent = self()
    ref = make_ref()
    gates = :atomics.new(1, [])

    hook = fn
      :after_input ->
        if :atomics.add_get(gates, 1, 1) <= 4, do: gate(parent, ref)

      _ ->
        :ok
    end

    with_pool(ids, [max_workers: 2, recovery_options: [hook: hook]], fn first ->
      with_pool(ids, [max_workers: 2, recovery_options: [hook: hook]], fn second ->
        held = for _ <- 1..4, do: receive_gate(ref)
        active = Scheduler.status(first).active ++ Scheduler.status(second).active
        4 = length(active)
        4 = active |> Enum.map(& &1.claim.intent_id) |> Enum.uniq() |> length()
        Enum.each(held, &send(&1, {ref, :release}))
        Enum.each(ids, &await_status(&1, :succeeded))
        Enum.each(ids, fn id -> %{effects: 1} = DurableTools.stats(id) end)
        {:ok, model_journal} = RetryStore.list(hd(ids))
        {:ok, tool_journal} = RetryStore.list(Enum.at(ids, 1))
        3 = Enum.find(model_journal, &(&1.scope == :model and &1.seq == 1)).attempts
        3 = Enum.find(tool_journal, &(&1.scope == :tool)).attempts
        %{ids: ids, parallel: 4, model_attempts: 3, tool_attempts: 3}
      end)
    end)
  end

  defp renewal(prefix) do
    id = prefix <> "-renewal"
    {:ok, created} = Recovery.create_run(id, "renew live model", script: script())
    parent = self()
    ref = make_ref()
    once = :atomics.new(1, [])

    hook = fn
      :after_input -> if :atomics.add_get(once, 1, 1) == 1, do: gate(parent, ref)
      _ -> :ok
    end

    with_pool([id], [max_workers: 1, recovery_options: [hook: hook]], fn scheduler ->
      executor = receive_gate(ref)
      initial = hd(Scheduler.status(scheduler).active).claim

      active =
        await(fn ->
          case Scheduler.status(scheduler).active do
            [%{renewals: renewals} = active] when renewals >= 4 ->
              if RecoveryStore.now_ms() > DateTime.to_unix(initial.expires_at, :millisecond),
                do: active

            _ ->
              nil
          end
        end)

      {:error, :intent_claimed} = IntentStore.claim(id, "competing-owner")
      true = active.claim.token == initial.token
      true = active.claim.generation == initial.generation
      send(executor, {ref, :release})
      done = await_status(id, :succeeded)
      true = done.recovery.progress.deadline_at_ms == created.recovery.progress.deadline_at_ms

      %{
        :id => id,
        "renewals_observed" => active.renewals,
        "held_beyond_original_expiry" => true,
        "second_owner_rejected" => true,
        "deadline_preserved" => true
      }
    end)
  end

  defp duplicate(prefix) do
    id = prefix <> "-redelivery"
    {:ok, _} = Recovery.create_run(id, "tool effect then worker kill", script: script())
    {:ok, _} = Recovery.step(id)
    parent = self()
    ref = make_ref()
    once = :atomics.new(1, [])

    tool_hook = fn
      :after_effect -> if :atomics.add_get(once, 1, 1) == 1, do: gate(parent, ref)
      _ -> :ok
    end

    with_pool([id], [max_workers: 1, recovery_options: [tool_hook: tool_hook]], fn scheduler ->
      executor = receive_gate(ref)
      active = hd(Scheduler.status(scheduler).active)
      true = active.executor == executor
      monitor = Process.monitor(active.worker)
      Process.exit(active.worker, :kill)

      receive do
        {:DOWN, ^monitor, :process, _pid, :killed} -> :ok
      after
        5_000 -> raise "killed delivery Worker did not terminate"
      end

      done = await_status(id, :succeeded)
      {:ok, [operation]} = DurableTools.list(id)
      %{effects: 1, attempts: 2} = DurableTools.stats(id)
      [first, second] = operation.attempts
      true = second.claim.generation > first.claim.generation
      true = first.claim.token != second.claim.token
      true = done.state.operations["once"].status == :ok

      %{
        :id => id,
        "actual_worker_kills" => 1,
        "effects" => 1,
        "execution_attempts" => 2,
        "first_generation" => first.claim.generation,
        "successor_generation" => second.claim.generation
      }
    end)
  end

  defp manual(prefix) do
    id = prefix <> "-manual"

    {:ok, _} =
      Recovery.create_run(id, "do not redispatch unknown",
        script: script(),
        mock_mode: :unqueryable,
        mock_response: :lost
      )

    with_pool([id], [max_workers: 2], fn scheduler ->
      blocked = await_status(id, :blocked)
      before = DurableTools.stats(id)
      scans = Scheduler.status(scheduler).counters.scans
      await(fn -> Scheduler.status(scheduler).counters.scans >= scans + 3 end)
      {:ok, after_polls} = Recovery.load(id)
      true = after_polls === blocked
      true = before === DurableTools.stats(id)
      {:ok, %{safe_mode: :manual, journal_status: "unknown"}} = ReconciliationQueue.get(id)
      %{id: id}
    end)
  end

  defp fresh_application(prefix, output) do
    id = prefix <> "-application"
    {:ok, _} = Recovery.create_run(id, "background after process restart", script: script())

    code = """
    Application.ensure_all_started(:mix)
    Config.Reader.read!("config/config.exs", env: #{inspect(Mix.env())})
    |> Enum.each(fn {app, values} -> Enum.each(values, fn {key, value} -> Application.put_env(app, key, value) end) end)
    Application.put_env(:agent_systems_lab, :scheduler_enabled, true)
    Application.put_env(:agent_systems_lab, :scheduler_options,
      name: AgentSystemsLab.Scheduler, run_ids: [#{inspect(id)}], max_workers: 2,
      lease_ms: 500, renew_interval_ms: 100, poll_interval_ms: 10)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    snapshot = Enum.reduce_while(1..500, nil, fn _, _ ->
      {:ok, saved} = AgentSystemsLab.Recovery.load(#{inspect(id)})
      if saved.state.status == :succeeded, do: {:halt, saved}, else: (Process.sleep(20); {:cont, nil})
    end)
    :succeeded = snapshot.state.status
    audit = %{"application_scheduler_started" => is_pid(Process.whereis(AgentSystemsLab.Scheduler)),
      "status" => Atom.to_string(snapshot.state.status),
      "state_sha256" => AgentSystemsLab.Context.hash(snapshot.state),
      "effects" => AgentSystemsLab.DurableTools.stats(#{inspect(id)}).effects}
    :ok = Supervisor.terminate_child(AgentSystemsLab.Supervisor, AgentSystemsLab.Scheduler)
    IO.puts("SCHEDULING_AUDIT=" <> JSON.encode!(audit))
    """

    args = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)]) ++ ["-e", code]

    log = fresh_application_child(args, output)
    [_, json] = Regex.run(~r/SCHEDULING_AUDIT=(\{[^\n]+\})/, log)
    audit = JSON.decode!(json)
    true = audit["application_scheduler_started"]
    1 = audit["effects"]
    {:ok, saved} = Recovery.load(id)
    true = audit["state_sha256"] == Context.hash(saved.state)
    Map.put(audit, :id, id)
  end

  defp fresh_application_child(args, output) do
    executable = System.find_executable("elixir") || raise "elixir is unavailable"

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
      status = await_application_exit(port, System.monotonic_time(:millisecond) + 15_000)
      if status != 0, do: raise("fresh application child exited with status #{status}")
      port |> application_log()
    after
      owned? = Port.info(port, :os_pid) == {:os_pid, pid}

      if owned?,
        do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      status = await_application_exit(port, System.monotonic_time(:millisecond) + 2_000)
      File.write!(Path.join(output, "fresh-application.log"), application_log(port))

      write_json(Path.join(output, "fresh-application-cleanup.json"), %{
        "pid" => pid,
        "kill_sent" => owned?,
        "exit_observed" => true,
        "exit_status" => status
      })

      Process.delete({__MODULE__, port, :log})
      Process.delete({__MODULE__, port, :exit})
    end
  end

  defp application_log(port),
    do:
      port
      |> then(&Process.get({__MODULE__, &1, :log}, []))
      |> Enum.reverse()
      |> IO.iodata_to_binary()

  defp await_application_exit(port, deadline) do
    case Process.get({__MODULE__, port, :exit}) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0,
          do: raise("fresh application child did not exit within the bounded wait")

        receive do
          {^port, {:data, bytes}} ->
            key = {__MODULE__, port, :log}
            Process.put(key, [bytes | Process.get(key, [])])
            await_application_exit(port, deadline)

          {^port, {:exit_status, status}} ->
            Process.put({__MODULE__, port, :exit}, status)
            status
        after
          remaining -> raise "fresh application child did not exit within the bounded wait"
        end

      status ->
        status
    end
  end

  defp with_pool(ids, extra, fun) do
    {:ok, pid} =
      Scheduler.start_link(
        [run_ids: ids, lease_ms: 400, renew_interval_ms: 60, poll_interval_ms: 15] ++ extra
      )

    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: Scheduler.stop(pid)
    end
  end

  defp await_status(id, status) do
    await(fn ->
      case Recovery.load(id) do
        {:ok, %{state: %{status: ^status}} = saved} ->
          saved

        {:ok, %{state: %{status: :failed}} = failed} ->
          raise "Run failed: #{inspect(failed.state.terminal_reason)}"

        _ ->
          nil
      end
    end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 10_000)

  defp await(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("background observation timed out")

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
      5_000 -> raise "delivery gate was not reached"
    end
  end

  defp evidence(id) do
    {:ok, saved} = Recovery.load(id)
    {:ok, operations} = DurableTools.list(id)
    {:ok, retries} = RetryStore.list(id)
    {:ok, models} = ModelResultStore.list(id)
    {:ok, queue} = ReconciliationQueue.list(run_id: id)

    %{
      snapshot: saved,
      operations: operations,
      retries: retries,
      recordings: models,
      queue: queue,
      stats: DurableTools.stats(id)
    }
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
      {:final, "done"}
    ]

  defp policy, do: [max_attempts: 3, base_delay_ms: 25, max_delay_ms: 50]

  defp create_output(path) do
    if File.exists?(path), do: {:error, {:output_exists, path}}, else: File.mkdir_p(path)
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:output, :runs] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(Keyword.get(opts, :runs, 12)) and Keyword.get(opts, :runs, 12) in 4..100 and
         is_binary(Keyword.get(opts, :output, "artifacts/week11-scheduling")) and
         String.valid?(Keyword.get(opts, :output, "artifacts/week11-scheduling")) and
         String.trim(Keyword.get(opts, :output, "artifacts/week11-scheduling")) != "" and
         not String.contains?(Keyword.get(opts, :output, "artifacts/week11-scheduling"), <<0>>),
       do: :ok,
       else: {:error, :invalid_scheduling_demo_options}
  end

  defp options(_), do: {:error, :invalid_scheduling_demo_options}
  defp inert(%{__struct__: _} = value), do: value |> Map.from_struct() |> inert()
  defp inert(value) when is_map(value), do: Map.new(value, fn {k, v} -> {inert(k), inert(v)} end)
  defp inert(value) when is_list(value), do: Enum.map(value, &inert/1)

  defp inert(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&inert/1) |> List.to_tuple()

  defp inert(value), do: value
  defp write_json(path, report), do: File.write!(path, JSON.encode!(report) <> "\n")

  defp failure(output, prefix, reason) do
    report = %{
      "schema_version" => 1,
      "all_passed" => false,
      "error" => reason,
      "run_id_prefix" => prefix,
      "experiment" => "experiment.json"
    }

    write_json(Path.join(output, "report.json"), report)
    {:error, {:scheduling_demo_failed, %{output_dir: output, report: report}}}
  end
end
