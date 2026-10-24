defmodule AgentSystemsLab.ApprovalRuntimeTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Approvals, Recovery, Repo}
  alias AgentSystemsLab.Approvals.{Artifact, Cases, Plan}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Workflows.{Definition, Store}
  @moduletag :database

  setup do
    id =
      "approval-runtime-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    base = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"
    root = Path.join(base, id)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "patch.txt"), "IMMUTABLE_PATCH")

    {:ok, definition} =
      Definition.new([
        %{
          id: "worker",
          input: "Review patch",
          options: %{workspace: root, script: [{:final, "complete"}]}
        }
      ])

    {:ok, artifact} = Artifact.new(root, ["patch.txt"])
    {:ok, plan} = Plan.new([%{id: "first", definition: definition, artifacts: [artifact]}])
    {:ok, created} = Cases.create(id, plan)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [created.workflow_id])
      Repo.query!("DELETE FROM lab_queues WHERE name=$1", [Store.queue_name(created.workflow_id)])
      Repo.query!("DELETE FROM lab_approval_cases WHERE id=$1", [id])
      File.rm_rf!(root)
    end)

    %{id: id, root: root, created: created}
  end

  test "a fresh BEAM releases a persisted approved subject as immutable reviewed bytes", c do
    approved = approve(c.created)
    req = request(approved, "fresh-release")
    assert {:ok, report, output} = fresh_release(c.id, req)
    assert report["released"] == true
    assert report["content"] == "IMMUTABLE_PATCH"
    assert report["subject_hash"] == approved.subject.subject_hash
    assert String.contains?(output, "APPROVAL_RUNTIME=")
    {:ok, current} = Cases.load(c.id)
    assert current.status == :approved
    assert Map.has_key?(current.requests, "fresh-release")
    assert current.approval == approved.approval
  end

  test "a fresh BEAM rejects changed artifact bytes and commits revocation of the old approval",
       c do
    approved = approve(c.created)
    File.write!(Path.join(c.root, "patch.txt"), "CHANGED_PATCH")
    assert {:ok, report, _} = fresh_release(c.id, request(approved, "stale-release"))
    assert report["released"] == false
    assert report["invalidated"] == true
    assert report["generation"] > approved.generation
    {:ok, invalidated} = Cases.load(c.id)
    assert invalidated.status == :awaiting_review
    assert is_nil(invalidated.approval)
    assert invalidated.subject.subject_hash != approved.subject.subject_hash
    assert hd(hd(invalidated.subject.artifacts).files).content == "CHANGED_PATCH"
    assert Enum.any?(invalidated.events, &(&1.type == "approval_invalidated"))
  end

  test "an approved Coordinator keeps polling and revokes changed content without a release request",
       c do
    approved = approve(c.created)
    {:ok, workflow} = Store.load(approved.workflow_id)
    run_id = workflow.nodes["worker"].run_id
    {:ok, child_before} = Recovery.load(run_id)
    controller = controller(c.id)
    eventually(fn -> Approvals.status(controller).case_status == :approved end)
    assert Approvals.status(controller).workflow_coordinator == nil
    File.write!(Path.join(c.root, "patch.txt"), "POLL_DETECTED_CHANGE")

    invalidated =
      eventually(fn ->
        {:ok, current} = Cases.load(c.id)
        if current.status == :awaiting_review, do: current
      end)

    assert is_nil(invalidated.approval)
    assert invalidated.generation > approved.generation
    assert invalidated.subject.subject_hash != approved.subject.subject_hash
    {:ok, child_after} = Recovery.load(run_id)
    assert child_after.state == child_before.state
    assert child_after.recovery.progress == child_before.recovery.progress
  end

  test "a blocked Case helper stays single, times out, backs off and recovers while status responds",
       c do
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM lab_approval_cases WHERE id=$1 FOR UPDATE", [c.id])
          send(owner, {:case_locked, self()})
          receive do: (:continue -> :ok)
        end)
      end)

    on_exit(fn -> if Process.alive?(blocker.pid), do: Process.exit(blocker.pid, :kill) end)
    assert_receive {:case_locked, lock_pid}, 2000

    controller =
      controller(c.id,
        database_timeout_ms: 200,
        database_backoff_ms: 250,
        max_database_backoff_ms: 500
      )

    pending = eventually(fn -> Approvals.status(controller).pending_sync end)
    helper = pending.pid
    monitor = Process.monitor(helper)
    for _ <- 1..1000, do: Approvals.wake(controller)
    started = System.monotonic_time(:millisecond)
    status = Approvals.status(controller)
    assert System.monotonic_time(:millisecond) - started < 150
    assert status.pending_sync.pid == helper
    assert status.workflow_coordinator == nil
    assert status.message_queue_len <= 2

    failed =
      eventually(fn ->
        current = Approvals.status(controller)
        if current.database.state == :unavailable, do: current
      end)

    assert failed.database.consecutive_failures == 1
    assert failed.pending_sync == nil
    assert failed.database.retry_in_ms > 100
    assert_receive {:DOWN, ^monitor, :process, ^helper, _}, 1000
    for _ <- 1..1000, do: Approvals.wake(controller)
    Process.sleep(40)
    after_wake = Approvals.status(controller)
    assert after_wake.pending_sync == nil
    assert after_wake.counters.syncs == failed.counters.syncs
    send(lock_pid, :continue)
    assert {:ok, :ok} = Task.await(blocker, 2000)

    recovered =
      eventually(fn ->
        {:ok, current} = Cases.load(c.id)
        if current.status == :awaiting_review, do: current
      end)

    assert recovered.subject != nil
    eventually(fn -> Approvals.status(controller).database.state == :available end)
  end

  defp approve(created) do
    {:ok, workflow} = Store.load(created.workflow_id)
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(workflow.nodes["worker"].run_id)
    {:ok, review} = Cases.sync(created.id)

    {:ok, approved} =
      Cases.decide(created.id, Map.put(request(review, "approve"), :action, :approve))

    approved
  end

  defp controller(id, opts \\ []) do
    {:ok, pid} = Approvals.start_link(Keyword.merge([case_id: id, poll_interval_ms: 10], opts))
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Approvals.stop(pid) end)
    pid
  end

  defp request(view, id),
    do: %{
      actor: "lab-human",
      reason: "Runtime fixture operator",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }

  defp fresh_release(id, request) do
    {:ok, bytes} = Codec.encode(request)

    script = """
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    {:ok, _} = Application.ensure_all_started(:agent_systems_lab)
    {:ok, _} = AgentSystemsLab.Approvals.Cases.load(#{inspect(id)})
    {:ok, request} = AgentSystemsLab.Storage.Codec.decode(Base.decode64!(#{inspect(Base.encode64(bytes))}))
    report = case AgentSystemsLab.Approvals.Cases.release(#{inspect(id)}, request) do
      {:ok, released} -> %{"released" => true, "content" => hd(hd(released.snapshot.artifacts).files).content,
        "subject_hash" => released.snapshot.subject_hash}
      {:error, {:approval_invalidated, _, view}} -> %{"released" => false, "invalidated" => true,
        "generation" => view.generation}
      other -> raise "Unexpected release: " <> inspect(other)
    end
    IO.puts("APPROVAL_RUNTIME=" <> JSON.encode!(report))
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    {output, code} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    with 0 <- code,
         line when is_binary(line) <-
           Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "APPROVAL_RUNTIME=")),
         {:ok, report} <- JSON.decode(String.replace_prefix(line, "APPROVAL_RUNTIME=", "")) do
      {:ok, report, output}
    else
      _ -> {:error, {:fresh_release_failed, code, output}}
    end
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 6000)

  defp eventually(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("Approval runtime did not settle")

        Process.sleep(5)
        eventually(fun, deadline)
    end
  end
end
