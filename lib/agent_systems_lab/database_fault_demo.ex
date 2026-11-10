defmodule AgentSystemsLab.DatabaseFaultDemo do
  @moduledoc """
  Isolated real PostgreSQL disconnect, lost acknowledgement and recovery probes.

  Every probe owns a fresh child BEAM and a loopback TCP proxy. The ordinary
  parent Repo remains connected directly to PostgreSQL and independently audits
  durable facts. No shared server is stopped and no backend is terminated by PID.
  A database error is an uncertain delivery outcome, never permission to repeat
  a non-idempotent effect. This fixture uses the local durable Mock target.
  """

  alias AgentSystemsLab.{
    DurableTools,
    History,
    IntentStore,
    ModelResultStore,
    ReconciliationQueue,
    Recovery,
    Repo,
    Scheduler,
    Storage
  }

  alias AgentSystemsLab.Faults.DatabaseProxy
  alias AgentSystemsLab.Storage.Codec

  @cases ~w(before_commit_rollback commit_ack_lost heartbeat_disconnect tool_effect_pending_disconnect auto_poll_reconnect)
  @wait_ms 12_000
  @lease_ms 500

  def cases, do: @cases

  def run(opts \\ []) do
    with :ok <- options(opts),
         :ok <- isolated_fixture(),
         output = Path.expand(Keyword.get(opts, :output, "artifacts/week14-database")),
         :ok <- create_output(output) do
      prefix =
        "database-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

      probes =
        for name <- @cases,
            repetition <- 1..Keyword.get(opts, :repetitions, 2),
            do: %{name: name, repetition: repetition, run_id: "#{prefix}-#{name}-#{repetition}"}

      execute(probes, [], output, opts, length(probes))
    end
  end

  defp execute([], completed, output, _opts, total) do
    report = report(Enum.reverse(completed), total, nil)
    write_json(Path.join(output, "report.json"), report)
    {:ok, %{output_dir: output, report: report}}
  end

  defp execute([probe | rest], completed, output, opts, total) do
    directory = Path.join([output, probe.name, Integer.to_string(probe.repetition)])
    File.mkdir_p!(directory)

    result =
      try do
        progress(opts, probe, length(completed), total, :starting)
        summary = verify(probe, directory, opts, length(completed), total)
        write_json(Path.join(directory, "summary.json"), summary)
        {:ok, summary}
      rescue
        exception -> {:error, Exception.format(:error, exception, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end

    case result do
      {:ok, summary} ->
        completed = [summary | completed]
        write_json(Path.join(output, "report.json"), report(Enum.reverse(completed), total, nil))

        try do
          progress(opts, probe, length(completed), total, :passed)
          execute(rest, completed, output, opts, total)
        rescue
          exception -> failed(probe, completed, output, total, Exception.message(exception))
        end

      {:error, reason} ->
        failed(probe, completed, output, total, reason)
    end
  end

  defp verify(probe, directory, opts, completed, total) do
    id = probe.run_id
    tool? = probe.name == "tool_effect_pending_disconnect"

    {:ok, _} =
      Recovery.create_run(id, "W14: preserve facts through database connection loss",
        script: if(tool?, do: script(), else: [{:final, "database recovered"}]),
        mock_mode: :unqueryable,
        model_timeout_ms: 30_000,
        run_timeout_ms: 120_000
      )

    if tool?, do: {:ok, _} = Recovery.step(id)
    initial = evidence(id)
    save_evidence(directory, "initial", initial)
    target = target()
    {:ok, proxy} = DatabaseProxy.start_link(target.hostname, target.port)
    nonce = Ecto.UUID.generate()

    child_options = %{
      "run_id" => id,
      "directory" => directory,
      "nonce" => nonce,
      "case" => probe.name,
      "port" => DatabaseProxy.port(proxy),
      "repo" => child_credentials(),
      "environment" => Atom.to_string(if(Code.ensure_loaded?(Mix), do: Mix.env(), else: :dev))
    }

    {port, pid} =
      try do
        spawn_child(child_options)
      rescue
        exception ->
          DatabaseProxy.stop(proxy)
          reraise exception, __STACKTRACE__
      end

    try do
      write_json(Path.join(directory, "process.json"), %{"pid" => pid, "nonce" => nonce})

      ready =
        await_json(port, Path.join(directory, "ready.json"), proxy, %{
          "pid" => pid,
          "nonce" => nonce
        })

      true = ready["nonce"] == nonce and ready["pid"] == pid
      true = ready["connection"]["database"] == target.database
      true = ready["connection"]["backend_pid"] != target.backend_pid
      before_fault = raw_evidence(id)
      save_evidence(directory, "before-fault", before_fault)

      if probe.name == "commit_ack_lost",
        do: :ok = DatabaseProxy.trap_commit_ack(proxy),
        else: :ok = DatabaseProxy.disconnect(proxy)

      write_json(Path.join(directory, "release.json"), %{"nonce" => nonce})
      result = await_json(port, Path.join(directory, "result.json"), proxy)
      true = result["nonce"] == nonce and result["pid"] == pid
      true = result["database_error_observed"]
      proxy_fault = DatabaseProxy.status(proxy)
      true = proxy_fault.mode == :blocked and proxy_fault.connections == 0
      true = proxy_fault.dropped >= 1
      if probe.name == "commit_ack_lost", do: true = proxy_fault.ack_dropped == 1
      disconnected = evidence(id)
      save_evidence(directory, "disconnected", disconnected)
      progress(opts, probe, completed, total, :disconnected)

      {old, successor, unknown} =
        case probe.name do
          "before_commit_rollback" ->
            true = initial.snapshot.state === disconnected.snapshot.state
            true = initial.snapshot.events === disconnected.snapshot.events
            true = disconnected.recordings == []
            after_rows = raw_evidence(id)
            true = before_fault === after_rows
            save_evidence(directory, "disconnected-rows", after_rows)
            wait_expiry(id)
            {nil, nil, nil}

          "commit_ack_lost" ->
            :succeeded = disconnected.snapshot.state.status
            true = disconnected.snapshot.state.seq == initial.snapshot.state.seq + 1
            "database recovered" = disconnected.snapshot.state.output
            true = length(disconnected.recordings) == 1
            true = disconnected.snapshot.recovery.progress.cursor == 1
            {nil, nil, nil}

          "auto_poll_reconnect" ->
            true = result["worker_stopped"] and result["executor_stopped"]
            true = result["scheduler_database_unavailable"]
            old = decode_claim(ready["claim"])
            wait_expiry(id)
            {old, nil, nil}

          mode when mode in ["heartbeat_disconnect", "tool_effect_pending_disconnect"] ->
            true = result["worker_stopped"] and result["executor_stopped"]
            true = ready["heartbeat_renewals"] >= 1
            old = decode_claim(ready["claim"])
            true = disconnected.snapshot.state.seq == old.seq
            wait_expiry(id)
            {:ok, claim} = IntentStore.claim(id, "database-successor:" <> nonce, lease_ms: 15_000)
            true = claim.intent_id == old.intent_id and claim.seq == old.seq
            true = claim.generation == old.generation + 1 and claim.token != old.token
            {:ok, next} = Recovery.execute_claim(claim)

            unknown =
              if tool? do
                :blocked = next.state.status
                {:ok, entry} = ReconciliationQueue.get(id)
                :manual = entry.safe_mode
                true = entry.operation_id == "once"
                true = DurableTools.stats(id).effects == 1
                save_evidence(directory, "unknown", %{snapshot: next, queue: entry})
                entry
              end

            {old, claim, unknown}
        end

      stable = evidence(id)
      save_evidence(directory, "before-heal", stable)
      :ok = DatabaseProxy.heal(proxy)

      write_json(Path.join(directory, "heal.json"), %{
        "nonce" => nonce,
        "old_claim" => if(old, do: dto(old))
      })

      healed = await_json(port, Path.join(directory, "healed.json"), proxy)
      true = healed["nonce"] == nonce and healed["query_succeeded"]
      true = healed["connection"]["backend_pid"] != ready["connection"]["backend_pid"]
      if old, do: true = healed["stale_claim_rejected"]

      if probe.name == "auto_poll_reconnect" do
        true = healed["same_scheduler_resumed"] and healed["automatic_completion"]
        :succeeded = evidence(id).snapshot.state.status
      else
        true = stable === evidence(id)
      end

      :ok = await_child_exit(port)

      if successor, do: IntentStore.release(successor)

      if unknown do
        # Independent parent observed the one durable Mock effect. Preserve the
        # unknown queue evidence first, then record explicit operator evidence.
        {:ok, _} =
          Recovery.reconcile(id,
            result: {:ok, %{"verified_effects" => 1}},
            evidence:
              "W14 direct parent audit verified exactly one Mock effect for operation once"
          )
      end

      {:ok, done} = Recovery.resume(id)
      :succeeded = done.state.status
      {:ok, rebuilt} = History.rebuild(id, done.events, max_turns: done.state.max_turns)
      true = rebuilt === done.state
      final = evidence(id)
      true = final.stats.effects == if(tool?, do: 1, else: 0)
      if probe.name == "commit_ack_lost", do: true = final === disconnected
      true = length(final.operations) == if(tool?, do: 1, else: 0)
      true = is_nil(final.snapshot.intent)
      save_evidence(directory, "after", final)
      proxy_after = DatabaseProxy.status(proxy)
      write_json(Path.join(directory, "proxy.json"), dto(proxy_after))

      %{
        "fault" => probe.name,
        "repetition" => probe.repetition,
        "run_id" => id,
        "evidence" => Path.join(probe.name, Integer.to_string(probe.repetition)),
        "pid" => pid,
        "nonce" => nonce,
        "classification" => classification(probe.name),
        "status" => "succeeded",
        "isolated_child_repo" => true,
        "shared_database_untouched" => true,
        "database_error_observed" => true,
        "database_errors" => result["database_errors"],
        "initial_connection" => ready["connection"],
        "healed_connection" => healed["connection"],
        "proxy_port" => proxy_after.port,
        "connections_dropped" => proxy_after.dropped,
        "reconnects_rejected" => proxy_after.rejected,
        "commit_ack_dropped" => proxy_after.ack_dropped,
        "worker_stopped" => result["worker_stopped"],
        "executor_stopped" => result["executor_stopped"],
        "old_generation" => if(old, do: old.generation),
        "successor_generation" =>
          if(successor,
            do: successor.generation,
            else: get_in(healed, ["takeover_claim", "generation"])
          ),
        "same_intent_takeover" => not is_nil(old),
        "stale_claim_rejected" => healed["stale_claim_rejected"],
        "stale_result" => healed["stale_result"],
        "same_scheduler_resumed" => healed["same_scheduler_resumed"],
        "automatic_completion" => healed["automatic_completion"],
        "scheduler_before" => result["scheduler_pid"],
        "scheduler_after" => healed["scheduler_pid"],
        "successor_facts_unchanged" => true,
        "unknown_manual_observed" => not is_nil(unknown),
        "operation_id_preserved" =>
          if(tool?,
            do: final.operations |> hd() |> Map.fetch!(:operation_id) == "once",
            else: true
          ),
        "effects" => final.stats.effects,
        "state_matches_history" => true,
        "pending_claims" => 0,
        "child_exit_status" => 0
      }
    after
      # Heal before cleanup so an exceptional callback cannot leave even this
      # owned client pool in an intentional outage. The listener is then closed.
      DatabaseProxy.heal(proxy)
      cleanup = cleanup_child(port, pid)
      proxy_status = DatabaseProxy.status(proxy)
      :ok = DatabaseProxy.stop(proxy)

      write_json(
        Path.join(directory, "cleanup.json"),
        Map.put(cleanup, "proxy_stopped", not Process.alive?(proxy))
      )

      write_json(Path.join(directory, "proxy.json"), dto(proxy_status))
      File.write!(Path.join(directory, "child.log"), Process.delete({__MODULE__, port}) || "")
    end
  end

  @doc false
  def child(opts) do
    environment = Enum.find([:test, :dev, :prod], &(Atom.to_string(&1) == opts["environment"]))

    Application.put_all_env(
      Config.Reader.read!("config/config.exs", env: environment, target: :host)
    )

    Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
    config = Application.fetch_env!(:agent_systems_lab, Repo)

    config =
      config
      |> Keyword.drop([:url, :socket, :socket_dir])
      |> Keyword.merge(
        hostname: "127.0.0.1",
        port: opts["port"],
        username: opts["repo"]["username"],
        password: opts["repo"]["password"],
        database: opts["repo"]["database"],
        ssl: false,
        pool_size: 1,
        timeout: 500,
        connect_timeout: 500,
        queue_target: 20,
        queue_interval: 50,
        backoff_min: 50,
        backoff_max: 100
      )

    Application.put_env(:agent_systems_lab, Repo, config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    connection = await_connection()
    id = opts["run_id"]
    directory = opts["directory"]
    base = %{"pid" => String.to_integer(System.pid()), "nonce" => opts["nonce"]}

    result =
      if opts["case"] in ["before_commit_rollback", "commit_ack_lost"] do
        hook = fn
          :before_commit ->
            write_json(
              Path.join(directory, "ready.json"),
              Map.put(base, "connection", connection)
            )

            await_command(Path.join(directory, "release.json"), opts["nonce"])

          _ ->
            :ok
        end

        result =
          Scheduler.safely(fn ->
            Recovery.step(id, lease_ms: @lease_ms, commit_hook: hook)
          end)

        true = match?({:error, _}, result)

        Map.merge(base, %{
          "database_error_observed" => database_error?(result),
          "database_errors" => [inspect(result)],
          "worker_stopped" => nil,
          "executor_stopped" => nil
        })
      else
        scheduler_probe(opts, base, connection)
      end

    write_json(Path.join(directory, "result.json"), result)
    heal = await_command(Path.join(directory, "heal.json"), opts["nonce"])
    healed_connection = await_connection()

    auto =
      if scheduler = Process.get({__MODULE__, :auto_scheduler}) do
        executor =
          receive do
            {:resumed_boundary, pid} -> pid
          after
            @wait_ms -> raise "same Scheduler did not resume after healing"
          end

        entry =
          await_value(
            fn -> Enum.find(Scheduler.status(scheduler).active, &(&1.executor == executor)) end,
            "resumed claim"
          )

        old = decode_claim(heal["old_claim"])

        write_json(
          Path.join(directory, "takeover-claim.json"),
          Map.merge(base, %{
            "old" => dto(old),
            "resumed" => dto(entry.claim),
            "scheduler" => dto(Scheduler.status(scheduler))
          })
        )

        true =
          entry.claim.intent_id == old.intent_id and entry.claim.seq == old.seq and
            entry.claim.generation == old.generation + 1 and entry.claim.token != old.token

        {:ok, before_stale} = Storage.load(id)
        true = before_stale.intent.id == entry.claim.intent_id
        true = before_stale.intent.claim_token == entry.claim.token
        true = before_stale.intent.claim_generation == entry.claim.generation
        stale = IntentStore.renew(old)
        {:ok, after_stale} = Storage.load(id)
        true = before_stale.state === after_stale.state
        true = before_stale.events === after_stale.events
        true = before_stale.intent.claim_token == after_stale.intent.claim_token
        true = before_stale.intent.claim_generation == after_stale.intent.claim_generation
        send(executor, :release_gate)

        await_value(
          fn ->
            case Storage.load(id) do
              {:ok, %{state: %{status: :succeeded}}} -> Scheduler.status(scheduler).active == []
              _ -> false
            end
          end,
          "automatic same Scheduler completion"
        )

        same? = Process.alive?(scheduler)
        :ok = Scheduler.stop(scheduler)

        %{
          "same_scheduler_resumed" => same?,
          "automatic_completion" => true,
          "takeover_claim" => dto(entry.claim),
          "scheduler_pid" => inspect(scheduler),
          "stale" => stale
        }
      end

    stale =
      if auto,
        do: auto["stale"],
        else: if(claim = heal["old_claim"], do: IntentStore.renew(decode_claim(claim)))

    healed =
      Map.merge(base, %{
        "query_succeeded" => true,
        "connection" => healed_connection,
        "stale_claim_rejected" => if(stale, do: stale == {:error, :stale_claim}),
        "stale_result" => if(stale, do: inspect(stale)),
        "same_scheduler_resumed" => if(auto, do: auto["same_scheduler_resumed"]),
        "automatic_completion" => if(auto, do: auto["automatic_completion"]),
        "scheduler_pid" => if(auto, do: auto["scheduler_pid"]),
        "takeover_claim" => if(auto, do: auto["takeover_claim"])
      })

    write_json(Path.join(directory, "healed.json"), healed)
    IO.puts("DATABASE_FAULT_CHILD=" <> JSON.encode!(healed))
    :ok
  end

  defp scheduler_probe(opts, base, connection) do
    parent = self()
    tool? = opts["case"] == "tool_effect_pending_disconnect"
    stage = if tool?, do: :after_effect, else: :after_claim
    key = if tool?, do: :tool_hook, else: :hook
    deliveries = :atomics.new(1, [])

    hook = fn reached ->
      if reached == stage do
        number = :atomics.add_get(deliveries, 1, 1)
        send(parent, {if(number == 1, do: :boundary, else: :resumed_boundary), self()})
        receive do: (:release_gate -> :ok)
      end
    end

    # The reconnect probe must allow its 500 ms connection attempt to complete
    # before a claim helper deadline. Keep renewal plus that deadline below the
    # lease so the observed first takeover still has time to renew. These are
    # bounded demonstration budgets, not production timing guarantees; the other
    # socket-fault probes retain their shorter lease and deadline.
    {lease_ms, renew_interval_ms, database_timeout_ms} =
      if opts["case"] == "auto_poll_reconnect",
        do: {2_000, 250, 1_000},
        else: {@lease_ms, 80, 200}

    {:ok, scheduler} =
      Scheduler.start_link(
        workers: 1,
        run_ids: [opts["run_id"]],
        lease_ms: lease_ms,
        renew_interval_ms: renew_interval_ms,
        poll_interval_ms: 20,
        execution_timeout_ms: 10_000,
        database_timeout_ms: database_timeout_ms,
        database_backoff_ms: 100,
        max_database_backoff_ms: 500,
        recovery_options: [{key, hook}]
      )

    executor =
      receive do
        {:boundary, pid} -> pid
      after
        @wait_ms -> raise "database child executor did not reach boundary"
      end

    entry =
      await_value(
        fn ->
          Enum.find(
            Scheduler.status(scheduler).active,
            &(&1.executor == executor and &1.renewals >= 1)
          )
        end,
        "initial heartbeat"
      )

    write_json(
      Path.join(opts["directory"], "ready.json"),
      Map.merge(base, %{
        "connection" => connection,
        "claim" => dto(entry.claim),
        "heartbeat_renewals" => entry.renewals
      })
    )

    await_command(Path.join(opts["directory"], "release.json"), opts["nonce"])

    status =
      await_value(
        fn ->
          status = Scheduler.status(scheduler)
          if status.active == [] and status.errors != [], do: status
        end,
        "worker stop after database loss"
      )

    true = not Process.alive?(entry.worker) and not Process.alive?(executor)

    unavailable =
      if opts["case"] == "auto_poll_reconnect" do
        status =
          await_value(
            fn ->
              candidate = Scheduler.status(scheduler)
              if candidate.database.state == :unavailable, do: candidate
            end,
            "Scheduler database backoff"
          )

        Process.put({__MODULE__, :auto_scheduler}, scheduler)
        status.database.state == :unavailable
      else
        :ok = Scheduler.stop(scheduler)
        nil
      end

    errors = Enum.map(status.errors, & &1.reason)

    Map.merge(base, %{
      "database_error_observed" => Enum.any?(errors, &database_error?/1),
      "database_errors" => errors,
      "scheduler_pid" => inspect(scheduler),
      "worker_stopped" => not Process.alive?(entry.worker),
      "executor_stopped" => not Process.alive?(executor),
      "scheduler_database_unavailable" => unavailable,
      "scheduler_status" => dto(status)
    })
  end

  defp database_error?(value) do
    text = inspect(value)

    Enum.any?(
      [
        "DBConnection",
        "Postgrex",
        "tcp recv",
        "tcp closed",
        "database_timeout",
        "connection not available"
      ],
      &String.contains?(text, &1)
    )
  end

  defp await_connection do
    await_value(
      fn ->
        case Scheduler.safely(fn -> connection() end) do
          {:error, _} -> nil
          value -> value
        end
      end,
      "healed isolated database connection"
    )
  end

  defp connection do
    %{rows: [[pid, database, user, port]]} =
      Repo.query!(
        "SELECT pg_backend_pid(), current_database(), current_user, inet_server_port()",
        [],
        timeout: 500
      )

    %{"backend_pid" => pid, "database" => database, "user" => user, "server_port" => port}
  end

  defp target do
    %{rows: [[pid, database]]} = Repo.query!("SELECT pg_backend_pid(), current_database()")
    config = Repo.config()

    # Repo.config/0 includes Ecto's parsed URL overrides. A server's physical
    # inet_server_addr/port may differ from the reachable published endpoint.
    %{
      hostname: Keyword.fetch!(config, :hostname),
      port: Keyword.fetch!(config, :port),
      backend_pid: pid,
      database: database
    }
  end

  defp child_credentials do
    config = Repo.config()
    Map.new([:username, :password, :database], &{Atom.to_string(&1), Keyword.get(config, &1)})
  end

  defp evidence(id) do
    {:ok, snapshot} = Recovery.load(id)
    {:ok, operations} = DurableTools.list(id)
    {:ok, recordings} = ModelResultStore.list(id)

    %{
      snapshot: snapshot,
      operations: operations,
      recordings: recordings,
      stats: DurableTools.stats(id)
    }
  end

  defp raw_evidence(id) do
    # Ordinary MVCC reads remain possible while the gated child holds its Run
    # lock; Storage.load's FOR SHARE would instead wait for that transaction.
    Map.new(
      ["lab_runs", "lab_events", "lab_intents", "lab_recovery", "lab_model_results"],
      fn table ->
        column = if table == "lab_runs", do: "id", else: "run_id"

        %{rows: rows} =
          Repo.query!("SELECT row_to_json(t)::text FROM #{table} AS t WHERE #{column}=$1", [id])

        {table, Enum.map(rows, &JSON.decode!(hd(&1)))}
      end
    )
  end

  defp save_evidence(directory, name, value) do
    plain = dto(value)
    {:ok, encoded} = Codec.encode(plain)
    File.write!(Path.join(directory, name <> ".bin"), encoded)
    write_json(Path.join(directory, name <> ".json"), plain)
  end

  defp dto(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp dto(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp dto(value) when is_struct(value), do: value |> Map.from_struct() |> dto()
  defp dto(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), dto(v)} end)
  defp dto(value) when is_list(value), do: Enum.map(value, &dto/1)
  defp dto(value) when is_tuple(value), do: value |> Tuple.to_list() |> dto()
  defp dto(value) when is_pid(value) or is_reference(value), do: inspect(value)

  defp dto(value) when is_binary(value),
    do:
      if(String.valid?(value),
        do: value,
        else: %{"encoding" => "base64", "data" => Base.encode64(value)}
      )

  defp dto(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp dto(value), do: value

  defp decode_claim(value) do
    {:ok, expires, 0} = DateTime.from_iso8601(value["expires_at"])

    %{
      intent_id: value["intent_id"],
      run_id: value["run_id"],
      seq: value["seq"],
      owner: value["owner"],
      token: value["token"],
      generation: value["generation"],
      expires_at: expires
    }
  end

  defp spawn_child(opts) do
    code = "AgentSystemsLab.DatabaseFaultDemo.child(JSON.decode!(#{inspect(JSON.encode!(opts))}))"
    executable = System.find_executable("elixir") || raise "elixir is unavailable"
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: paths ++ ["-e", code],
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    Process.put({__MODULE__, port}, "")
    {port, pid}
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, bytes}} ->
        Process.put({__MODULE__, port}, Process.get({__MODULE__, port}, "") <> bytes)
        drain_port(port)

      {^port, {:exit_status, status}} ->
        Process.put({__MODULE__, port, :exit}, status)
    after
      0 -> :ok
    end
  end

  defp await_json(port, path, proxy, readiness_identity \\ nil) do
    await_value(
      fn ->
        drain_port(port)

        case File.read(path) do
          {:ok, bytes} ->
            JSON.decode!(bytes)

          {:error, :enoent} ->
            if readiness_identity, do: reject_early_result(Path.dirname(path), readiness_identity)

            if status = Process.get({__MODULE__, port, :exit}),
              do: raise("child exited #{status}: #{Process.get({__MODULE__, port})}")

            nil
        end
      end,
      "child evidence #{path}"
    )
  rescue
    exception in RuntimeError ->
      drain_port(port)
      output = Process.get({__MODULE__, port}, "")

      output =
        binary_part(output, max(byte_size(output) - 8_192, 0), min(byte_size(output), 8_192))

      reraise RuntimeError,
              Exception.message(exception) <>
                "\nproxy status: #{inspect(DatabaseProxy.status(proxy))}" <>
                "\nchild output (last 8192 bytes): #{output}",
              __STACKTRACE__
  end

  defp reject_early_result(directory, identity) do
    case File.read(Path.join(directory, "result.json")) do
      {:ok, bytes} ->
        result = JSON.decode!(bytes)

        unless Map.take(result, ["pid", "nonce"]) == identity,
          do: raise("child identity mismatch in result before readiness")

        raise "child returned before readiness: #{inspect(result)}"

      {:error, :enoent} ->
        :ok
    end
  end

  defp await_command(path, nonce) do
    value =
      await_value(
        fn ->
          case File.read(path) do
            {:ok, bytes} -> JSON.decode!(bytes)
            {:error, :enoent} -> nil
          end
        end,
        "controller command #{path}"
      )

    true = value["nonce"] == nonce
    value
  end

  defp await_value(fun, description),
    do: await_value(fun, description, System.monotonic_time(:millisecond) + @wait_ms)

  defp await_value(fun, description, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("bounded wait expired: #{description}")

        Process.sleep(10)
        await_value(fun, description, deadline)
    end
  end

  defp wait_expiry(id) do
    await_value(
      fn ->
        %{rows: [[expired]]} =
          Repo.query!(
            "SELECT claim_expires_at <= (clock_timestamp() AT TIME ZONE 'UTC') FROM lab_intents WHERE run_id=$1 AND status='pending'",
            [id]
          )

        expired
      end,
      "actual database lease expiry"
    )
  end

  defp await_child_exit(port) do
    await_value(
      fn ->
        drain_port(port)

        case Process.get({__MODULE__, port, :exit}) do
          nil -> nil
          0 -> :ok
          status -> raise "owned child exit #{status}"
        end
      end,
      "owned child exit"
    )
  end

  defp cleanup_child(port, pid) do
    alive? = Port.info(port, :os_pid) == {:os_pid, pid}

    if alive?,
      do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    await_value(
      fn ->
        drain_port(port)
        is_nil(Port.info(port)) and not is_nil(Process.get({__MODULE__, port, :exit}))
      end,
      "owned child cleanup"
    )

    %{
      "pid" => pid,
      "kill_sent" => alive?,
      "exit_observed" => true,
      "exit_status" => Process.delete({__MODULE__, port, :exit})
    }
  end

  defp report(probes, total, failure) do
    %{
      "schema_version" => 1,
      "all_passed" => length(probes) == total and is_nil(failure),
      "expected_probe_count" => total,
      "fault_probe_count" => length(probes),
      "fault_probes" => probes,
      "failed_probe" => failure,
      "stale_generation_overwrites" => Enum.count(probes, &(not &1["successor_facts_unchanged"])),
      "duplicate_mock_effects" => Enum.sum(Enum.map(probes, &max(0, &1["effects"] - 1))),
      "scope" =>
        "Owned loopback TCP listeners and isolated BEAM Repo pools only; real PostgreSQL disconnects and framed COMMIT acknowledgement loss; shared PostgreSQL remains online; no external exactly-once guarantee."
    }
  end

  defp classification("before_commit_rollback"), do: "uncommitted transition rolled back"
  defp classification("commit_ack_lost"), do: "committed transition survives lost acknowledgement"

  defp classification("heartbeat_disconnect"),
    do: "lease uncertainty stops executor; actual expiry permits fenced takeover"

  defp classification("tool_effect_pending_disconnect"),
    do: "effect retained; ambiguous original operation enters manual reconciliation"

  defp classification("auto_poll_reconnect"),
    do: "same Scheduler backs off while disconnected and automatically resumes after reconnect"

  defp failed(probe, completed, output, total, reason) do
    report =
      report(Enum.reverse(completed), total, %{
        "fault" => probe.name,
        "run_id" => probe.run_id,
        "repetition" => probe.repetition,
        "reason" => reason
      })

    write_json(Path.join(output, "report.json"), report)
    {:error, {:database_verification_failed, %{output_dir: output, report: report}}}
  end

  defp progress(opts, probe, completed, total, status) do
    if callback = opts[:on_progress],
      do:
        callback.(%{
          fault: probe.name,
          repetition: probe.repetition,
          completed: completed,
          total: total,
          status: status
        })
  end

  defp options(opts) when is_list(opts) do
    output =
      if Keyword.keyword?(opts), do: Keyword.get(opts, :output, "artifacts/week14-database")

    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:output, :repetitions, :on_progress] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         is_integer(Keyword.get(opts, :repetitions, 2)) and
         Keyword.get(opts, :repetitions, 2) in 1..10 and
         is_binary(output) and byte_size(output) > 0 and String.valid?(output) and
         not String.contains?(output, <<0>>) and
         (is_nil(opts[:on_progress]) or is_function(opts[:on_progress], 1)),
       do: :ok,
       else: {:error, :invalid_database_fault_options}
  end

  defp options(_), do: {:error, :invalid_database_fault_options}

  defp isolated_fixture do
    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false),
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

  defp write_json(path, value) do
    temp = path <> ".tmp"
    File.write!(temp, JSON.encode!(value) <> "\n")
    File.rename!(temp, path)
  end

  defp script,
    do: [
      {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 14}}},
      {:final, "database recovered"}
    ]
end
