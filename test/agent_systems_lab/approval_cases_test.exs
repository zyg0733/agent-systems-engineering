defmodule AgentSystemsLab.ApprovalCasesTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias AgentSystemsLab.{DurableTools, IntentStore, Recovery, RecoveryStore, Repo}
  alias AgentSystemsLab.Approvals.{Artifact, Cases, Plan}
  alias AgentSystemsLab.Storage.{ApprovalCase, ApprovalEvent, Codec, Workflow}
  alias AgentSystemsLab.Tools.Workspace
  alias AgentSystemsLab.Workflows.{ControlStore, Definition, Store}
  @moduletag :database

  setup do
    id = "case-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    base = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"
    root = Path.join(base, id)
    File.mkdir_p!(root)

    on_exit(fn ->
      for round <- ["first", "second"] do
        wid = Plan.workflow_id(id, round)
        Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [wid])
        Repo.query!("DELETE FROM lab_queues WHERE name=$1", [Store.queue_name(wid)])
      end

      Repo.query!("DELETE FROM lab_approval_cases WHERE id=$1", [id])
      File.rm_rf!(root)
    end)

    %{id: id, root: root, test_pid: self()}
  end

  test "case creation reserves finite rounds and atomically owns the first Workflow", c do
    plan = plan(c)
    assert {:ok, view} = Cases.create(c.id, plan)
    assert view.status == :running
    assert view.current_round == 0
    assert Enum.at(view.rounds, 1).status == :pending
    assert {:ok, workflow} = Store.load(view.workflow_id)
    assert workflow.control.owner_case_id == c.id
    assert workflow.deadline_at_ms <= view.deadline_at_ms
    assert {:error, :not_found} = Store.load(Enum.at(view.rounds, 1).workflow_id)
    assert {:ok, ^view} = Cases.rebuild(c.id)
    assert {:error, :approval_case_managed} = ControlStore.resume(view.workflow_id)
    assert {:error, :invalid_approval_plan} = Cases.create(c.id <> "bad", nil)

    assert {:error, :nested_transaction_not_supported} =
             elem(Repo.transaction(fn -> Cases.create(c.id, plan) end), 1)
  end

  test "approval freezes exact bytes and every release retry revalidates changes", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)
    approve = request(review, "approve") |> Map.put(:action, :approve)
    assert {:ok, approved} = Cases.decide(c.id, approve)
    assert approved.status == :approved
    assert {:ok, ^approved} = Cases.decide(c.id, approve)
    release = request(approved, "release")
    assert {:ok, released} = Cases.release(c.id, release)
    assert hd(hd(released.snapshot.artifacts).files).content == "first"
    assert {:ok, again} = Cases.release(c.id, release)
    assert again.snapshot == released.snapshot
    File.write!(Path.join(c.root, "first/output.txt"), "tampered")

    assert {:error, {:approval_invalidated, :artifact_changed, invalid}} =
             Cases.release(c.id, release)

    assert invalid.status == :awaiting_review
    assert invalid.generation > approved.generation
    assert is_nil(invalid.approval)
    File.write!(Path.join(c.root, "first/output.txt"), "first")
    assert {:ok, restored} = Cases.sync(c.id)
    assert restored.subject.subject_hash != approved.subject.subject_hash
    assert {:error, {:invalid_approval_state, :awaiting_review}} = Cases.release(c.id, release)

    assert {:error, {:stale_sequence, _, _}} =
             Cases.decide(
               c.id,
               request(approved, "old-approval") |> Map.put(:action, :approve)
             )

    assert {:ok, ^restored} = Cases.rebuild(c.id)
  end

  test "repeating an approved decision also observes artifact revocation", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)
    req = request(review, "approve") |> Map.put(:action, :approve)
    {:ok, _} = Cases.decide(c.id, req)
    File.write!(Path.join(c.root, "first/output.txt"), "changed")
    assert {:error, {:approval_invalidated, :artifact_changed, invalid}} = Cases.decide(c.id, req)
    assert invalid.status == :awaiting_review
    assert is_nil(invalid.approval)
    assert {:ok, ^invalid} = Cases.decide(c.id, req)
  end

  test "human identity, subject CAS and request IDs reject forged or changed decisions", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)
    req = request(review, "approve") |> Map.put(:action, :approve)
    assert {:error, :unauthorized_approver} = Cases.decide(c.id, %{req | actor: "outsider"})

    assert {:error, :stale_approval_subject} =
             Cases.decide(c.id, %{req | subject_hash: String.duplicate("0", 64)})

    assert {:error, :invalid_approval_request} = Cases.decide(c.id, Map.put(req, :script, []))
    assert {:ok, _} = Cases.decide(c.id, req)
    assert {:error, :approval_request_conflict} = Cases.decide(c.id, %{req | reason: "different"})
  end

  test "controlled rework advances only the next fixed round without budget or deadline refill",
       c do
    plan = plan(c)
    {:ok, view} = Cases.create(c.id, plan)
    review = complete(view)
    before = Plan.allocations(plan)

    assert {:ok, rework} =
             Cases.decide(
               c.id,
               request(review, "rework") |> Map.put(:action, :rework)
             )

    assert rework.current_round == 1
    assert rework.deadline_at_ms == view.deadline_at_ms
    assert Plan.allocations(rework.plan) == before
    assert Enum.at(rework.rounds, 0).proof == Enum.at(review.rounds, 0).proof
    assert {:ok, old} = Store.load(view.workflow_id)
    assert old.control.status == :paused
    assert {:ok, child} = Store.load(rework.workflow_id)
    assert child.control.owner_case_id == c.id
    assert child.deadline_at_ms <= view.deadline_at_ms
    final = complete(rework)

    assert {:error, :approval_round_not_found} =
             Cases.decide(
               c.id,
               request(final, "exhausted") |> Map.put(:action, :rework)
             )

    assert {:ok, ^final} = Cases.load(c.id)
  end

  test "protected baseline changes visibly conflict and allow only rejection or declared rework",
       c do
    {:ok, view} = Cases.create(c.id, plan(c, baseline: true))
    review = complete(view)
    File.write!(Path.join(c.root, "first/source.txt"), "changed")

    assert {:error, {:approval_invalidated, {:artifact_baseline_conflict, _, _, _}, conflicted}} =
             Cases.decide(c.id, request(review, "approve") |> Map.put(:action, :approve))

    assert is_nil(conflicted.subject)
    assert {:ok, same} = Cases.sync(c.id)
    assert same.seq == conflicted.seq

    assert {:ok, rejected} =
             Cases.decide(
               c.id,
               request(conflicted, "reject") |> Map.put(:action, :reject)
             )

    assert rejected.status == :rejected
  end

  test "pause and resume fence original claims and preserve charged counters", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    {:ok, workflow} = Store.load(view.workflow_id)
    run = workflow.nodes["worker"].run_id
    {:ok, claim} = IntentStore.claim(run, "old-worker")
    {:ok, progress} = RecoveryStore.load(run)
    {:ok, paused} = Cases.pause(c.id, request(view, "pause"))
    assert paused.status == :paused
    assert {:error, {:workflow_paused, _}} = IntentStore.renew(claim)
    assert {:error, {:workflow_paused, _}} = Recovery.step(run)
    assert {:ok, resumed} = Cases.resume(c.id, request(paused, "resume"))
    assert resumed.status == :running
    assert {:error, :stale_claim} = IntentStore.renew(claim)
    {:ok, after_resume} = RecoveryStore.load(run)
    assert after_resume.config.budget == progress.config.budget
    assert after_resume.progress.model_attempts == progress.progress.model_attempts
    assert after_resume.progress.output_bytes == progress.progress.output_bytes
    assert after_resume.progress.deadline_at_ms == progress.progress.deadline_at_ms
  end

  test "paused approved content cannot resume a revoked approval", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)
    {:ok, approved} = Cases.decide(c.id, request(review, "approve") |> Map.put(:action, :approve))
    {:ok, paused} = Cases.pause(c.id, request(approved, "pause"))
    File.write!(Path.join(c.root, "first/output.txt"), "changed")

    assert {:error, {:approval_invalidated, :artifact_changed, invalid}} =
             Cases.resume(c.id, request(paused, "resume"))

    assert invalid.status == :awaiting_review
    assert is_nil(invalid.approval)
  end

  test "the original wall deadline continues while human-paused", c do
    {:ok, view} = Cases.create(c.id, plan(c, timeout_ms: 150))
    {:ok, paused} = Cases.pause(c.id, request(view, "pause"))
    Process.sleep(180)
    assert {:ok, expired} = Cases.sync(c.id)
    assert expired.status == :failed
    assert expired.deadline_at_ms == paused.deadline_at_ms

    assert {:error, {:invalid_approval_state, :failed}} =
             Cases.resume(c.id, request(expired, "resume"))
  end

  test "pause rollback and post-commit crash keep Case and owned gate atomic", c do
    {:ok, view} = Cases.create(c.id, plan(c))

    for stage <- [:before_commit, :after_commit] do
      current = elem(Cases.load(c.id), 1)
      req = request(current, "pause-#{stage}")

      {pid, ref} =
        spawn_monitor(fn ->
          Cases.pause(c.id, req,
            hook: fn at ->
              if at == stage do
                send(c.test_pid, {:at, self()})
                receive do: (:continue -> :ok)
              end
            end
          )
        end)

      assert_receive {:at, ^pid}, 4000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 4000
      {:ok, actual} = Cases.load(c.id)
      {:ok, workflow} = Store.load(view.workflow_id)
      expected = if stage == :before_commit, do: :running, else: :paused
      assert actual.status == expected
      assert workflow.control.status == expected
    end
  end

  test "approve COMMIT crash windows retain exactly one immutable decision", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)

    for stage <- [:before_commit, :after_commit] do
      req = request(review, "approve-#{stage}") |> Map.put(:action, :approve)
      kill_at_commit(c.test_pid, stage, fn hook -> Cases.decide(c.id, req, hook: hook) end)
      {:ok, actual} = Cases.load(c.id)

      if stage == :before_commit do
        assert actual == review
        assert actual.decisions == []
      else
        assert actual.status == :approved
        assert length(actual.decisions) == 1
        assert {:ok, ^actual} = Cases.decide(c.id, req)
      end
    end
  end

  test "rework COMMIT crash windows create one owned graph with stable round identity", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)
    next_id = Enum.at(review.rounds, 1).workflow_id

    for stage <- [:before_commit, :after_commit] do
      req = request(review, "rework-#{stage}") |> Map.put(:action, :rework)
      kill_at_commit(c.test_pid, stage, fn hook -> Cases.decide(c.id, req, hook: hook) end)
      {:ok, actual} = Cases.load(c.id)

      if stage == :before_commit do
        assert actual == review
        assert {:error, :not_found} = Store.load(next_id)
      else
        assert actual.current_round == 1
        assert actual.workflow_id == next_id
        assert {:ok, graph} = Store.load(next_id)
        assert graph.control.owner_case_id == c.id
        assert {:ok, ^actual} = Cases.decide(c.id, req)

        assert %{rows: [[1]]} =
                 Repo.query!("SELECT count(*) FROM lab_workflows WHERE id=$1", [next_id])
      end
    end
  end

  test "simultaneous human decisions use sequence CAS and cannot approve two alternatives", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    review = complete(view)

    requests =
      for action <- [:approve, :rework] do
        request(review, Atom.to_string(action)) |> Map.put(:action, action)
      end

    results =
      requests
      |> Enum.map(fn req -> Task.async(fn -> Cases.decide(c.id, req) end) end)
      |> Enum.map(&Task.await(&1, 5000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    {:ok, final} = Cases.load(c.id)
    assert length(final.decisions) == 1
  end

  test "cancel preserves ambiguous non-idempotent work in the visible manual queue", c do
    original = plan(c)
    {:ok, first} = Plan.round(original, 0)

    {:ok, definition} =
      Definition.new([
        %{
          id: "worker",
          input: "write",
          options: %{
            workspace: Path.join(c.root, "first"),
            mock_mode: :unqueryable,
            script: [
              {:call,
               %{operation_id: "unknown", tool: "mock_write", arguments: %{value: "effect"}}},
              {:final, "done"}
            ]
          }
        }
      ])

    {:ok, plan} = Plan.new([%{id: "first", definition: definition, artifacts: first.artifacts}])
    {:ok, view} = Cases.create(c.id, plan)
    {:ok, graph} = Store.load(view.workflow_id)
    run_id = graph.nodes["worker"].run_id
    {:ok, %{state: %{status: :waiting_tool}}} = Recovery.step(run_id)
    {:ok, claim} = IntentStore.claim(run_id, "ambiguous-worker")
    {:ok, current} = Recovery.load(run_id)
    operation = current.state.operations["unknown"]

    {pid, ref} =
      spawn_monitor(fn ->
        DurableTools.execute(claim, operation,
          mock_mode: :unqueryable,
          hook: fn at ->
            if at == :after_prepare do
              send(c.test_pid, {:prepared, self()})
              receive do: (:continue -> :ok)
            end
          end
        )
      end)

    assert_receive {:prepared, ^pid}, 3000
    assert {:ok, stopped} = Cases.cancel(c.id, request(view, "cancel"))
    assert stopped.status == :cancelled
    assert {:ok, %{state: %{status: :blocked}}} = Recovery.load(run_id)
    assert {:ok, %{safe_mode: :manual}} = AgentSystemsLab.ReconciliationQueue.get(run_id)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 3000
    assert {:ok, ^stopped} = Cases.rebuild(c.id)
  end

  test "malformed nested persisted projections return errors instead of raising", c do
    {:ok, _} = Cases.create(c.id, plan(c))
    row = Repo.get!(ApprovalCase, c.id)
    {:ok, saved} = Codec.decode(row.progress_data)

    for bad <- [
          %{saved | rounds: [nil, nil]},
          %{saved | requests: %{"bad" => %{}}},
          %{saved | subject: %{generation: 0}}
        ] do
      {:ok, encoded} = Codec.encode(bad)
      Repo.update!(Ecto.Changeset.change(row, progress_data: encoded))
      assert {:error, {:corrupt_approval_case, _}} = Cases.load(c.id)
    end

    Repo.update!(Ecto.Changeset.change(row, progress_data: row.progress_data))
  end

  test "a valid owned Workflow cannot silently replace the frozen round definition", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    row = Repo.get!(Workflow, view.workflow_id)
    {:ok, raw} = Codec.decode(row.definition_data)

    changed =
      put_in(raw, [:nodes, Access.at(0), :options, :script], [{:final, "different host program"}])

    assert {:ok, _} = Definition.from_map(changed)
    {:ok, bytes} = Codec.encode(changed)

    Repo.update!(
      Ecto.Changeset.change(row,
        definition_data: bytes,
        definition_sha256: AgentSystemsLab.Context.hash(changed)
      )
    )

    assert {:ok, _} = Store.load(view.workflow_id)

    assert {:error, {:corrupt_approval_case, :workflow_or_artifact_binding_mismatch}} =
             Cases.load(c.id)
  end

  test "an invalidated historical subject cannot invent authority even with repaired hashes", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    first = complete(view)
    File.write!(Path.join(c.root, "first/output.txt"), "second version")
    {:ok, final} = Cases.sync(c.id)
    old = Repo.one!(from e in ApprovalEvent, where: e.case_id == ^c.id and e.seq == ^first.seq)
    next = Repo.one!(from e in ApprovalEvent, where: e.case_id == ^c.id and e.seq == ^final.seq)
    {:ok, payload} = Codec.decode(old.data)
    [snapshot] = payload.projection.subject.artifacts
    forged = %{snapshot | root: c.root <> "-not-granted"}
    forged = %{forged | hash: AgentSystemsLab.Context.hash(Map.delete(forged, :hash))}
    subject = %{payload.projection.subject | artifacts: [forged]}

    subject = %{
      subject
      | subject_hash:
          AgentSystemsLab.Context.hash(
            {"approval-subject.v1", c.id, first.plan_hash, first.current_round,
             Map.delete(subject, :subject_hash)}
          )
    }

    projection = %{payload.projection | subject: subject}
    {:ok, bytes} = Codec.encode(%{payload | projection: projection})
    Repo.update!(Ecto.Changeset.change(old, data: bytes))
    {:ok, next_payload} = Codec.decode(next.data)

    {:ok, bytes} =
      Codec.encode(%{next_payload | previous_sha256: AgentSystemsLab.Context.hash(projection)})

    Repo.update!(Ecto.Changeset.change(next, data: bytes))
    assert {:error, {:corrupt_approval_case, _}} = Cases.rebuild(c.id)
  end

  test "historical schema or impossible event transitions fail closed without execution", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    complete(view)
    [event] = Repo.all(from e in ApprovalEvent, where: e.case_id == ^c.id and e.seq == 1)
    {:ok, payload} = Codec.decode(event.data)
    bad = put_in(payload, [:projection, :status], :approved)
    {:ok, data} = Codec.encode(bad)
    Repo.update!(Ecto.Changeset.change(event, data: data))
    assert {:error, {:corrupt_approval_case, _}} = Cases.rebuild(c.id)
    Repo.update!(Ecto.Changeset.change(event, data: event.data))
    row = Repo.get!(ApprovalCase, c.id)
    Repo.update!(Ecto.Changeset.change(row, schema_version: 999))
    assert {:error, {:corrupt_approval_case, :unsupported_schema_version}} = Cases.load(c.id)
  end

  defp kill_at_commit(parent, stage, operation) do
    {pid, ref} =
      spawn_monitor(fn ->
        operation.(fn at ->
          if at == stage do
            send(parent, {:at, self()})
            receive do: (:continue -> :ok)
          end
        end)
      end)

    assert_receive {:at, ^pid}, 5000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5000
  end

  defp plan(c, opts \\ []) do
    rounds =
      for id <- ["first", "second"] do
        root = Path.join(c.root, id)
        File.mkdir_p!(root)
        File.write!(Path.join(root, "source.txt"), "source")
        {:ok, workspace} = Workspace.new(root)

        {:ok, definition} =
          Definition.new(
            [
              %{
                id: "worker",
                input: id,
                options: %{
                  workspace: workspace.root,
                  script: [
                    {:call,
                     %{
                       operation_id: "write",
                       tool: "file_write",
                       arguments: %{
                         "path" => "output.txt",
                         "content" => id,
                         "expected_sha256" => "absent"
                       }
                     }},
                    {:final, id}
                  ]
                }
              }
            ],
            timeout_ms: 30_000
          )

        artifact_opts =
          if opts[:baseline],
            do: [baselines: %{"source.txt" => Workspace.sha256("source")}],
            else: []

        {:ok, artifact} = Artifact.new(workspace, ["output.txt"], artifact_opts)
        %{id: id, definition: definition, artifacts: [artifact]}
      end

    {:ok, plan} = Plan.new(rounds, timeout_ms: Keyword.get(opts, :timeout_ms, 60_000))
    plan
  end

  defp complete(view) do
    {:ok, workflow} = Store.load(view.workflow_id)
    {:ok, %{state: %{status: :succeeded}}} = Recovery.resume(workflow.nodes["worker"].run_id)
    {:ok, review} = Cases.sync(view.id)
    assert review.status == :awaiting_review
    review
  end

  defp request(view, id),
    do: %{
      actor: "lab-human",
      reason: "reviewed by test human",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash)
    }
end
