defmodule AgentSystemsLab.ObservabilityTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.Observability
  alias AgentSystemsLab.Observability.{Buffer, Context, Schema}

  setup do
    # Earlier fault suites may legitimately restart an execution dependency.
    # The temporary observer is intentionally not revived by rest_for_one; this
    # host test fixture opts back into observation without changing that policy.
    if Process.whereis(Buffer) == nil, do: assert({:ok, _} = Observability.restart())
    assert :ok = Observability.flush()
    :ok
  end

  defmodule Exporter do
    @behaviour AgentSystemsLab.Observability.Exporter
    @impl true
    def export(events, opts) do
      if owner = opts[:owner], do: send(owner, {:export_batch, self(), events})

      case opts[:mode] do
        :error -> {:error, "SECRET export failure"}
        :raise -> raise "SECRET export exception"
        :exit -> exit({:SECRET, :export_exit})
        :kill -> Process.exit(self(), :kill)
        :hang -> receive do: (:continue -> :ok)
        _ -> :ok
      end
    end
  end

  test "deterministic versioned IDs have trace/span lengths and normalize kind vocabulary" do
    assert Context.trace_id("run-1") == Context.trace_id("run-1")
    refute Context.trace_id("run-1") == Context.trace_id("run-2")
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, Context.trace_id("run-1"))
    assert Regex.match?(~r/\A[0-9a-f]{16}\z/, Context.root_span_id("run-1"))
    assert Context.root_span_id("run-1") == Context.span_id("run", "run-1")
    assert Context.span_id(:model, {"run-1", 7}) == Context.span_id("model", {"run-1", 7})
  end

  test "v1 projection discards content, paths, callbacks, arbitrary labels and error messages" do
    canary = "SECRET-/private/key token=abcd prompt body"

    assert {:ok, event} =
             Schema.project(
               :model_stopped,
               %{
                 run_id: "safe-run",
                 attempt_id: "attempt-1",
                 prompt: canary,
                 path: canary,
                 token: canary
               },
               %{duration_ms: 12, output_bytes: 44, cost_label: canary},
               outcome: :ok,
               status: :succeeded,
               reason: canary,
               error: canary,
               secret: canary,
               observed_at_unix_ms: 123
             )

    assert event["schema_version"] == 1
    assert event["observed_at_unix_ms"] == 123
    assert event["attributes"] == %{"outcome" => "ok", "status" => "succeeded"}
    assert event["correlation"] == %{"run_id" => "safe-run", "attempt_id" => "attempt-1"}
    assert event["measurements"] == %{"duration_ms" => 12, "output_bytes" => 44}
    refute JSON.encode!(event) =~ canary
    refute JSON.encode!(event) =~ "private/key"
  end

  test "event vocabulary, identifiers and finite numbers reject malformed observations" do
    for {name, refs, measurements} <- [
          {:unknown_event, %{}, %{}},
          {"model_started", %{}, %{}},
          {:model_started, %{run_id: "/private/path"}, %{}},
          {:model_started, %{run_id: String.duplicate("x", 257)}, %{}},
          {:model_started, %{generation: -1}, %{}},
          {:model_started, %{span_id: "wrong-length"}, %{}},
          {:model_started, %{parent_span_id: "0000000000000000"}, %{}},
          {:model_started, %{span_id: "0123456789abcdef", parent_span_id: "0123456789abcdef"},
           %{}},
          {:model_started, %{}, %{duration_ms: -1}},
          {:model_started, %{}, %{bytes: 1.0e100}},
          {:model_started, %{run_id: self()}, %{}}
        ] do
      assert {:error, :invalid_observation} = Schema.project(name, refs, measurements)
    end
  end

  test "model and tool lifecycle events share their attempt span and root Run parent" do
    refs = %{run_id: "paired-run", attempt_id: "attempt-1", operation_id: "op-1"}
    {:ok, root} = Schema.project(:run_created, refs, %{})
    {:ok, model_start} = Schema.project(:model_started, refs, %{})
    {:ok, model_stop} = Schema.project(:model_stopped, refs, %{})
    {:ok, tool_start} = Schema.project(:tool_started, refs, %{})
    {:ok, tool_stop} = Schema.project(:tool_stopped, refs, %{})
    assert root["span_id"] == Context.root_span_id("paired-run")
    assert root["parent_span_id"] == nil
    assert model_start["span_id"] == model_stop["span_id"]
    assert tool_start["span_id"] == tool_stop["span_id"]
    refute tool_start["span_id"] == model_start["span_id"]
    assert model_start["parent_span_id"] == root["span_id"]
    assert tool_stop["parent_span_id"] == root["span_id"]
    assert root["trace_id"] == model_start["trace_id"]

    {:ok, root_event} =
      Schema.project(:event_committed, Map.put(refs, :span_id, root["span_id"]), %{})

    assert root_event["parent_span_id"] == nil
  end

  test "configuration is strict, bounded, and never runs exporter on the caller" do
    for opts <- [
          [capacity: 0],
          [max_bytes: 16],
          [batch_size: 257],
          [recent_capacity: 0],
          [export_timeout_ms: 0],
          [backoff_ms: 0],
          [exporter: fn _ -> :ok end],
          [name: 12],
          [capacity: 2, capacity: 3],
          [unknown: true],
          %{}
        ] do
      assert {:error, :invalid_observability_options} = Buffer.start_link(opts)
    end

    {pid, handle} = buffer(exporter: {Exporter, [owner: self()]})
    assert :ok = emit(handle)
    assert_receive {:export_batch, worker, [_]}, 1_000
    refute worker == self()
    refute worker == pid
    assert :ok = Observability.flush(pid)
    assert Observability.stats(pid).exported == 1
  end

  test "error, raise, exit and kill in exporters preserve caller results and observer ownership" do
    for mode <- [:error, :raise, :exit, :kill] do
      {pid, handle} = buffer(exporter: {Exporter, [mode: mode]}, backoff_ms: 5)
      monitor = Process.monitor(pid)

      business = fn ->
        :ok = emit(handle)
        {:committed, 42}
      end

      assert business.() == {:committed, 42}
      assert eventually(fn -> Observability.stats(pid).export_errors == 1 end)
      refute_receive {:DOWN, ^monitor, :process, ^pid, _}, 10
      assert :ok = Observability.flush(pid)
      assert Observability.stats(pid).exported == 0
      refute inspect(Observability.stats(pid)) =~ "SECRET"
      GenServer.stop(pid)
    end
  end

  test "hung exporter is killed at its timeout and can be replaced through host configure" do
    {pid, handle} =
      buffer(
        exporter: {Exporter, [mode: :hang, owner: self()]},
        export_timeout_ms: 30,
        backoff_ms: 200
      )

    assert :ok = emit(handle)
    assert_receive {:export_batch, worker, [_]}, 1_000
    assert {:error, :busy} = Buffer.configure(pid, exporter: {Exporter, []})
    assert eventually(fn -> Observability.stats(pid).export_timeouts == 1 end)
    refute Process.alive?(worker)
    assert :ok = Buffer.configure(pid, exporter: {Exporter, [owner: self()]})
    assert :ok = emit(handle)
    assert_receive {:export_batch, next, [_]}, 1_000
    refute next == worker
    assert :ok = Observability.flush(pid)
    assert Observability.stats(pid).exported == 1
  end

  test "concurrent flood bounds event slots, bytes, mailbox, recent history and exporter workers" do
    {pid, handle} =
      buffer(
        capacity: 16,
        max_bytes: 8_000,
        max_event_bytes: 4_000,
        batch_size: 2,
        recent_capacity: 4,
        recent_max_bytes: 3_000,
        exporter: {Exporter, [mode: :hang, owner: self()]},
        export_timeout_ms: 1_000
      )

    emit(handle)
    assert_receive {:export_batch, worker, [_]}, 1_000

    1..16
    |> Task.async_stream(
      fn producer ->
        for i <- 1..500 do
          assert :ok =
                   Observability.emit(
                     :model_stopped,
                     %{run_id: "run-#{producer}-#{i}"},
                     %{duration_ms: 1},
                     buffer: handle,
                     outcome: :ok
                   )
        end
      end,
      max_concurrency: 16,
      timeout: 10_000
    )
    |> Enum.each(fn result -> assert {:ok, _} = result end)

    stats = Observability.stats(pid)
    assert stats.buffer_entries <= 16
    assert stats.buffer_bytes <= 8_000
    assert stats.highwater_entries <= 16
    assert stats.highwater_bytes <= 8_000
    assert stats.recent_entries <= 4
    assert stats.recent_bytes <= 3_000
    assert stats.mailbox_len <= 2
    assert stats.exporter_pid == worker
    assert stats.dropped > 7_900
    assert stats.admitted + stats.dropped == 8_001
    assert {:error, :timeout} = Observability.flush(pid, 5)
    assert eventually(fn -> Observability.stats(pid).export_timeouts >= 1 end, 2_000)
    assert :ok = Buffer.configure(pid, exporter: {Exporter, []})
    assert :ok = Observability.flush(pid)
    final = Observability.stats(pid)
    assert final.buffer_entries == 0
    assert final.buffer_bytes == 0
    assert final.recent_entries <= 4
    assert final.recent_bytes <= 3_000
  end

  test "metrics exclude Run, Operation and attempt identities as label cardinality" do
    {pid, handle} = buffer(capacity: 256, max_bytes: 1_048_576)

    for i <- 1..100 do
      Observability.emit(
        :model_stopped,
        %{run_id: "run-#{i}", attempt_id: "attempt-#{i}"},
        %{duration_ms: i},
        outcome: :ok,
        buffer: handle
      )
    end

    assert :ok = Observability.flush(pid)

    assert [
             %{
               "event_name" => "model_stopped",
               "outcome" => "ok",
               "count" => count,
               "sums" => sums
             }
           ] = Observability.metrics(pid)

    assert count == 100
    assert sums["duration_ms"] == 5_050
    refute JSON.encode!(Observability.metrics(pid)) =~ "run-"
  end

  test "observer process death and stale handles cannot affect emission or business exceptions" do
    {pid, handle} = buffer([])
    Process.exit(pid, :kill)
    assert eventually(fn -> not Process.alive?(pid) end)
    assert :ok = emit(handle)
    assert :ok = Observability.emit(:invalid, :not_a_map, :not_a_map, :not_keywords)
    assert :ok = Observability.emit(:model_started, %{}, %{}, buffer: :not_a_handle)

    assert_raise RuntimeError, "business failure", fn ->
      emit(handle)
      raise "business failure"
    end

    assert :ok = Observability.span_stop(%{}, :ok)
    assert Observability.span_start(:model_started, :invalid_refs) == nil
  end

  test "local JSONL adapter exports projected rows and export IO failure remains diagnostic" do
    path =
      Path.join(System.tmp_dir!(), "lab-observation-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)

    {pid, handle} =
      buffer(exporter: {AgentSystemsLab.Observability.Exporters.JSONL, [path: path]})

    Observability.emit(
      :tool_completed,
      %{run_id: "jsonl-run", operation_id: "op-1", result: "SECRET"},
      %{count: 1},
      outcome: :ok,
      buffer: handle
    )

    assert :ok = Observability.flush(pid)
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert [%{"event_name" => "tool_completed", "correlation" => %{"run_id" => "jsonl-run"}}] =
             rows

    refute File.read!(path) =~ "SECRET"

    assert :ok =
             Buffer.configure(pid,
               exporter:
                 {AgentSystemsLab.Observability.Exporters.JSONL, [path: path <> "/missing"]}
             )

    assert :ok = emit(handle)
    assert eventually(fn -> Observability.stats(pid).export_errors == 1 end)
  end

  test "bounded recent eviction does not discard finite aggregate counts" do
    {pid, handle} = buffer(recent_capacity: 2, recent_max_bytes: 2_000)

    for i <- 1..10,
        do: Observability.emit(:run_committed, %{run_id: "run-#{i}"}, %{count: 1}, buffer: handle)

    assert :ok = Observability.flush(pid)
    assert length(Observability.recent(pid)) == 2
    assert [%{"count" => 10}] = Observability.metrics(pid)
    assert {:error, :invalid_observability_options} = Buffer.configure(pid, unknown: true)
  end

  test "repeated loss of the default observer never restarts execution siblings" do
    names = [
      AgentSystemsLab.Supervisor,
      AgentSystemsLab.Registry,
      AgentSystemsLab.ProviderSupervisor,
      AgentSystemsLab.RunSupervisor
    ]

    original = Map.new(names, &{&1, Process.whereis(&1)})
    id = "observer-owner-#{System.unique_integer([:positive])}"

    assert {:ok, run} =
             AgentSystemsLab.start_run(run_id: id, input: "survive", script: [{:final, "done"}])

    initial = AgentSystemsLab.RunServer.snapshot(run)

    on_exit(fn ->
      if Process.alive?(run), do: GenServer.stop(run)
      Observability.restart()
    end)

    for _ <- 1..5 do
      old = Buffer.default_handle()
      observer = Process.whereis(Buffer)
      Process.exit(observer, :kill)
      assert eventually(fn -> Process.whereis(Buffer) == nil end)
      assert :ok = emit(old)
      assert :ok = Observability.emit(:run_committed, %{run_id: id})
      assert Map.new(names, &{&1, Process.whereis(&1)}) == original
      assert AgentSystemsLab.RunServer.snapshot(run) == initial
      assert {:ok, replacement} = Observability.restart()
      refute replacement == observer
    end

    assert {:ok, final} = AgentSystemsLab.RunServer.run_until_pause(run)
    assert final.state.status == :succeeded
    assert Map.new(names, &{&1, Process.whereis(&1)}) == original
  end

  test "event byte ceiling and invalid events are accounted without retaining contents" do
    {pid, handle} = buffer(max_event_bytes: 128)
    assert :ok = emit(handle)
    assert :ok = Observability.emit(:unregistered_event, %{}, %{}, buffer: handle)
    stats = Observability.stats(pid)
    assert stats.dropped == 1
    assert stats.invalid == 1
    assert stats.buffer_entries == 0
    assert stats.buffer_bytes == 0
    assert Observability.recent(pid) == []
  end

  test "killing observer ownership also stops its hung exporter before the original timeout" do
    {pid, handle} =
      buffer(exporter: {Exporter, [mode: :hang, owner: self()]}, export_timeout_ms: 60_000)

    emit(handle)
    assert_receive {:export_batch, worker, [_]}, 1_000
    monitor = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    refute Process.alive?(worker)
    assert :ok = emit(handle)
  end

  test "host configuration getter preserves state and permits exact exporter restoration" do
    {pid, handle} =
      buffer(exporter: {Exporter, [mode: :error]}, export_timeout_ms: 30, backoff_ms: 55)

    before = Observability.stats(pid)
    saved = Buffer.configuration(pid)

    assert Map.new(saved) == %{
             exporter: {Exporter, [mode: :error]},
             export_timeout_ms: 30,
             backoff_ms: 55
           }

    assert Observability.stats(pid) == before
    assert :ok = Buffer.configure(pid, exporter: {Exporter, []}, export_timeout_ms: 44)
    assert :ok = emit(handle)
    assert :ok = Observability.flush(pid)
    assert :ok = Buffer.configure(pid, saved)
    assert Buffer.configuration(pid) == saved
    assert :ok = emit(handle)
    assert eventually(fn -> Observability.stats(pid).export_errors == 1 end)
  end

  test "abandoned producer reservations remain bounded and host restart restores observer capacity" do
    assert :ok = Observability.flush()
    saved = Observability.configuration()

    on_exit(fn ->
      Observability.restart()
      Observability.configure(saved)
    end)

    before = Buffer.handle()
    stats = Observability.stats()
    execution = Process.whereis(AgentSystemsLab.RunSupervisor)
    # Model a producer killed after both atomic reservations but before ETS
    # insertion. No callback is added to the real emission path for this test.
    :atomics.put(before.counters, 1, stats.capacity)
    :atomics.put(before.counters, 2, stats.max_bytes)
    assert Observability.stats().queued_entries == 0
    assert :ok = emit(before)
    blocked = Observability.stats()
    assert blocked.dropped == stats.dropped + 1
    assert blocked.buffer_entries == stats.capacity
    assert blocked.buffer_bytes == stats.max_bytes
    assert {:error, :timeout} = Observability.flush(Buffer, 5)
    assert {:ok, _} = Observability.restart()
    assert Process.whereis(AgentSystemsLab.RunSupervisor) == execution
    assert :ok = emit(Buffer.handle())
    assert :ok = Observability.flush()
    recovered = Observability.stats()
    assert recovered.admitted == 1
    assert recovered.exported == 1
    assert recovered.buffer_entries == 0
    assert recovered.buffer_bytes == 0
  end

  @tag :database
  @tag capture_log: true
  test "execution dependency restart leaves the temporary observer absent until explicit host recovery" do
    saved = Observability.configuration()

    dependencies =
      Map.new(
        [
          AgentSystemsLab.Repo,
          AgentSystemsLab.Registry,
          AgentSystemsLab.ProviderSupervisor,
          AgentSystemsLab.RunSupervisor
        ],
        &{&1, Process.whereis(&1)}
      )

    old_repo = dependencies[AgentSystemsLab.Repo]
    old_observer = Process.whereis(Buffer)
    handle = Buffer.handle()

    on_exit(fn ->
      Observability.restart()
      Observability.configure(saved)
    end)

    Process.exit(old_repo, :kill)

    assert eventually(
             fn ->
               Enum.all?(dependencies, fn {name, old} ->
                 replacement = Process.whereis(name)
                 is_pid(replacement) and replacement != old
               end)
             end,
             5_000
           )

    assert Process.whereis(Buffer) == nil
    refute Process.alive?(old_observer)
    assert :ok = emit(handle)
    assert :ok = Observability.emit(:run_committed, %{run_id: "dependency-restarted"})
    assert {:ok, %{rows: [[1]]}} = AgentSystemsLab.Repo.query("SELECT 1")
    refute Process.whereis(Buffer)
    assert {:ok, observer} = Observability.restart()
    refute observer == old_observer
    assert :ok = Observability.configure(saved)
    assert :ok = emit(Buffer.handle())
    assert :ok = Observability.flush()
    assert Observability.stats().exported == 1
  end

  defp buffer(opts) do
    defaults = [name: nil, capacity: 256, batch_size: 2, backoff_ms: 10]

    pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Buffer, :start_link, [Keyword.merge(defaults, opts)]},
        restart: :temporary
      })

    {pid, Buffer.handle(pid)}
  end

  defp emit(handle),
    do:
      Observability.emit(:model_stopped, %{run_id: "test-run"}, %{duration_ms: 1},
        buffer: handle,
        outcome: :ok
      )

  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await(fun, deadline)
  end

  defp await(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(5)
        await(fun, deadline)
      end
    end
  end
end
