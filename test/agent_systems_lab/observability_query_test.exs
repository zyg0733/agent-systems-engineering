defmodule AgentSystemsLab.ObservabilityQueryTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Repo, Storage}
  alias AgentSystemsLab.Approvals.{Artifact, Cases, Plan}
  alias AgentSystemsLab.Observability.{Context, Query}
  alias AgentSystemsLab.Workflows.{ControlStore, Definition, Store}
  alias AgentSystemsLab.Recovery, as: Runtime
  @moduletag :database

  setup do
    if is_nil(Process.whereis(AgentSystemsLab.Observability.Buffer)) do
      assert {:ok, _} = AgentSystemsLab.Observability.restart()
    end

    id =
      "observation-query-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"

    root = Path.join(if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: "/tmp"), id)
    File.mkdir_p!(root)

    on_exit(fn ->
      for workflow_id <- [id, Plan.workflow_id(id, "first"), Plan.workflow_id(id, "second")] do
        Repo.query!("DELETE FROM lab_workflows WHERE id=$1", [workflow_id])
        Repo.query!("DELETE FROM lab_queues WHERE name=$1", [Store.queue_name(workflow_id)])
      end

      Repo.query!("DELETE FROM lab_approval_cases WHERE id=$1", [id])
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", [id <> "%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  test "query options and boundaries fail explicitly", c do
    assert {:error, :invalid_run_id} = Query.run(nil)
    assert {:error, :invalid_run_id} = Query.run("a\0b")

    for opts <- [
          [limit: 0],
          [limit: 201],
          [scope: :all],
          [max_related_runs: 25],
          [limit: 1, limit: 2],
          [hook: fn -> :ok end],
          %{}
        ] do
      assert {:error, :invalid_observability_query_options} = Query.run(c.id, opts)
    end

    assert {:error, :not_found} = Query.run(c.id)

    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn -> Query.run(c.id) end)
  end

  test "read-only query is deterministic and exports no prompt, output, path or policy payload",
       c do
    canary = "PRIVATE-CONTENT-#{c.id}"

    assert {:ok, _} =
             Runtime.create_run(c.id, canary, script: [{:final, canary}], workspace: c.root)

    assert {:ok, %{state: %{status: :succeeded}}} = Runtime.resume(c.id)
    before = run_facts(c.id)
    assert {:ok, query} = Query.run(c.id)
    assert {:ok, ^query} = Query.run(c.id)
    assert before == run_facts(c.id)
    encoded = JSON.encode!(query)
    refute String.contains?(encoded, canary)
    refute String.contains?(encoded, c.root)
    refute String.contains?(encoded, "claim_token")
    assert query["evidence_origin"] == "durable"
    assert query["trace_id"] == Context.trace_id(c.id)
    assert query["metrics"]["model_attempts_reserved"] == 1
    assert query["metrics"]["model_recordings"] == 1
    assert [%{"span_id" => root_span}] = spans(query, "run")
    assert root_span == Context.span_id(:run, c.id)

    assert [%{"correlation" => %{"context_id" => context_id}, "span_id" => model_span}] =
             spans(query, "model_recording")

    assert model_span == Context.span_id(:model, {c.id, context_id})
  end

  test "captured input without an accepted model recording never fabricates a model result", c do
    {:ok, _} =
      Runtime.create_run(c.id, "PRIVATE-PROMPT", script: [{:error, "PRIVATE-PROVIDER-FAILURE"}])

    {:ok, %{state: %{status: :failed}}} = Runtime.resume(c.id)
    {:ok, query} = Query.run(c.id)
    assert spans(query, "model_recording") == []

    assert [
             %{
               "status" => "input_captured_without_recording",
               "correlation" => %{"attempt_id" => context_id},
               "span_id" => span_id
             }
           ] = spans(query, "model_input")

    assert span_id == Context.span_id(:model, {c.id, context_id})
    assert query["metrics"]["model_input_captures"] == 1
    assert query["metrics"]["model_attempts_reserved"] == 1
    refute String.contains?(JSON.encode!(query), "PRIVATE-")
  end

  test "query calls no model, tool, controller, observer or mutation boundary", c do
    {:ok, _} = Runtime.create_run(c.id, "input", script: [{:final, "answer"}])
    {:ok, _} = Runtime.resume(c.id)

    boundaries =
      AgentSystemsLab.RebuildAudit.boundaries() ++
        [
          {Store, :sync, 2},
          {Cases, :sync, 2},
          {ControlStore, :pause, 3},
          {AgentSystemsLab.Observability, :emit, 4}
        ]

    for {module, _, _} <- boundaries, do: Code.ensure_loaded!(module)
    for mfa <- boundaries, do: assert(1 == :erlang.trace_pattern(mfa, true, [:call_count]))

    try do
      assert {:ok, _} = Query.run(c.id)
      assert Enum.all?(boundaries, &(:erlang.trace_info(&1, :call_count) == {:call_count, 0}))
    after
      for mfa <- boundaries, do: :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "a new BEAM derives the same root and model attempt identities", c do
    {:ok, _} = Runtime.create_run(c.id, "input", script: [{:final, "answer"}])
    {:ok, _} = Runtime.resume(c.id)
    {:ok, query} = Query.run(c.id)
    [model] = spans(query, "model_recording")
    context_id = model["correlation"]["context_id"]
    beam_dir = Context |> :code.which() |> List.to_string() |> Path.dirname()

    code =
      "[run, context] = System.argv(); alias AgentSystemsLab.Observability.Context; IO.write(Context.trace_id(run) <> Context.span_id(:run, run) <> Context.span_id(:model, {run, context}))"

    assert {output, 0} =
             System.cmd(
               System.find_executable("elixir"),
               ["-pa", beam_dir, "-e", code, c.id, context_id],
               env: [{"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}]
             )

    assert output == query["trace_id"] <> hd(spans(query, "run"))["span_id"] <> model["span_id"]
  end

  test "unknown non-idempotent outcomes stay visible and querying never reconciles them", c do
    {:ok, _} =
      Runtime.create_run(c.id, "input",
        script: [
          {:call,
           %{operation_id: "effect", tool: "mock_write", arguments: %{"value" => "PRIVATE-TOOL"}}}
        ],
        mock_mode: :unqueryable,
        mock_response: :lost
      )

    assert {:ok, %{state: %{status: :blocked}}} = Runtime.resume(c.id)
    before = run_facts(c.id)
    {:ok, query} = Query.run(c.id)
    assert [%{"manual_reconciliation" => true, "status" => "unknown"}] = spans(query, "operation")
    assert query["metrics"]["manual_reconciliation_operations"] == 1
    assert before == run_facts(c.id)
    [attempt] = spans(query, "tool_attempt")

    assert attempt["span_id"] ==
             Context.span_id(
               :tool,
               {c.id, attempt["correlation"]["operation_id"],
                attempt["correlation"]["attempt_id"]}
             )

    assert Enum.all?(spans(query, "scheduling_intent"), fn intent ->
             intent["span_id"] ==
               Context.span_id(
                 :intent,
                 {c.id, intent["correlation"]["intent_id"], intent["correlation"]["generation"]}
               )
           end)
  end

  test "Run lookup navigates DAG siblings and unadmitted dependencies without authorizing them",
       c do
    {:ok, definition} =
      Definition.new([
        %{id: "root", input: "input", options: %{script: [{:final, "first"}]}},
        %{id: "join", deps: ["root"], input: "join", options: %{script: [{:final, "second"}]}}
      ])

    {:ok, workflow} = Store.create(c.id, definition)
    root_id = workflow.nodes["root"].run_id
    join_id = workflow.nodes["join"].run_id
    {:ok, before} = Query.run(root_id)

    assert Enum.any?(
             before["links"],
             &(&1["relationship"] == "dag_dependency" and
                 &1["from_span_id"] == Context.span_id(:run, root_id) and
                 &1["to_span_id"] == Context.span_id(:run, join_id))
           )

    assert Enum.any?(
             before["links"],
             &(&1["relationship"] == "declared_node" and &1["admission_status"] == "not_admitted")
           )

    assert {:error, :not_found} = Runtime.load(join_id)
    {:ok, _} = Runtime.resume(root_id)
    {:ok, _} = Store.sync(c.id)
    {:ok, related} = Query.run(join_id)
    assert length(spans(related, "run")) == 2
    {:ok, one} = Query.run(join_id, scope: :run)
    assert [%{"correlation" => %{"run_id" => ^join_id}}] = spans(one, "run")
    refute Enum.any?(one["links"], &(&1["to_trace_id"] == Context.trace_id(root_id)))
  end

  test "case approval invalidation and rework link independent round traces without content", c do
    {:ok, created} = Cases.create(c.id, plan(c))
    {:ok, first_workflow} = Store.load(created.workflow_id)
    first_id = first_workflow.nodes["worker"].run_id
    {:ok, _} = Runtime.resume(first_id)
    {:ok, review} = Cases.sync(c.id)
    {:ok, approved} = Cases.decide(c.id, request(review, "approve", :approve))
    File.write!(Path.join(c.root, "first/output.txt"), "PRIVATE-CHANGED")
    {:ok, invalid} = Cases.sync(c.id)
    assert invalid.status == :awaiting_review
    assert invalid.generation > approved.generation
    {:ok, next} = Cases.decide(c.id, request(invalid, "rework", :rework))
    {:ok, second_workflow} = Store.load(next.workflow_id)
    second_id = second_workflow.nodes["worker"].run_id
    before = case_facts(c.id, [created.workflow_id, next.workflow_id], [first_id, second_id])
    {:ok, query} = Query.run(second_id)
    assert length(spans(query, "run")) == 2
    assert Enum.any?(spans(query, "approval_event"), &(&1["event_type"] == "approved"))

    assert Enum.any?(
             spans(query, "approval_event"),
             &(&1["event_type"] == "approval_invalidated")
           )

    assert Enum.any?(spans(query, "approval_event"), &(&1["event_type"] == "rework_started"))

    assert Enum.any?(
             query["links"],
             &(&1["relationship"] == "rework_started_round" and
                 &1["to_span_id"] == Context.span_id(:workflow, next.workflow_id))
           )

    assert Enum.any?(spans(query, "run"), &(&1["trace_id"] == Context.trace_id(first_id)))
    [case_span] = spans(query, "approval_case")
    assert case_span["current_round"] == 1
    assert case_span["approval_present"] == false
    refute String.contains?(JSON.encode!(query), "PRIVATE-")
    refute String.contains?(JSON.encode!(query), c.root)

    assert before ==
             case_facts(c.id, [created.workflow_id, next.workflow_id], [first_id, second_id])
  end

  test "all collection and related-Run bounds are explicit", c do
    {:ok, definition} =
      Definition.new(
        for id <- ["a", "b", "c"],
            do: %{id: id, input: "input", options: %{script: [{:final, "done"}]}}
      )

    {:ok, graph} = Store.create(c.id, definition)
    for {_, node} <- graph.nodes, do: Runtime.resume(node.run_id)
    {:ok, query} = Query.run(graph.nodes["a"].run_id, limit: 1, max_related_runs: 1)
    assert query["partial"]
    assert query["truncation"]["runs"]
    assert query["truncation"]["events"]
    assert length(spans(query, "run")) == 1
    assert length(spans(query, "kernel_event")) == 1
    assert length(spans(query, "model_recording")) <= 1
    assert byte_size(JSON.encode!(query)) < 32_768
  end

  test "legacy Runs and unavailable accounting remain explicit safe metadata", c do
    {:ok, _} = Storage.create_run(c.id, "PRIVATE-LEGACY")
    {:ok, query} = Query.run(c.id)
    assert spans(query, "recovery_accounting") == []
    assert spans(query, "approval_case") == []
    assert length(spans(query, "run")) == 1
    {:ok, _} = Runtime.create_run(c.id <> "-new", "input", script: [{:final, "done"}])
    row = Repo.get!(AgentSystemsLab.Storage.Recovery, c.id <> "-new")
    Repo.update!(Ecto.Changeset.change(row, progress_data: <<0>>))
    {:ok, invalid} = Query.run(c.id <> "-new")
    assert invalid["partial"]

    assert [%{"projection_status" => "unavailable", "model_attempts" => nil}] =
             spans(invalid, "recovery_accounting")
  end

  test "outer rollback never exports committed Workflow or approval observations", c do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Cases.create(c.id, plan(c),
          hook: fn stage ->
            if stage == :before_commit do
              send(parent, {:before_commit, self()})
              receive do: (:continue -> :ok)
            end
          end
        )
      end)

    assert_receive {:before_commit, ^pid}, 5_000
    AgentSystemsLab.Observability.flush()
    round_id = Plan.workflow_id(c.id, "first")

    refute Enum.any?(AgentSystemsLab.Observability.recent(), fn event ->
             event["event_name"] in [
               "workflow_committed",
               "workflow_control_committed",
               "approval_committed",
               "case_created"
             ] and
               (event["correlation"]["workflow_id"] == round_id or
                  event["correlation"]["case_id"] == c.id)
           end)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert {:error, :not_found} = Cases.load(c.id)
    assert {:error, :not_found} = Store.load(round_id)
    assert {:ok, view} = Cases.create(c.id, plan(c))
    AgentSystemsLab.Observability.flush()

    assert Enum.any?(AgentSystemsLab.Observability.recent(), fn event ->
             event["event_name"] == "approval_committed" and
               event["correlation"]["case_id"] == view.id and
               event["attributes"]["phase"] == "committed"
           end)
  end

  test "missing observer cannot affect durable pause, resume or diagnostic facts", c do
    {:ok, view} = Cases.create(c.id, plan(c))
    {:ok, graph} = Store.load(view.workflow_id)
    run_id = graph.nodes["worker"].run_id
    pid = Process.whereis(AgentSystemsLab.Observability.Buffer)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    try do
      pause = request(view, "pause", :approve) |> Map.delete(:action)
      assert {:ok, paused} = Cases.pause(c.id, pause)
      assert {:ok, query} = Query.run(run_id)
      assert [%{"status" => "paused"}] = spans(query, "approval_case")
      resume = request(paused, "resume", :approve) |> Map.delete(:action)
      assert {:ok, resumed} = Cases.resume(c.id, resume)
      assert resumed.deadline_at_ms == view.deadline_at_ms
      assert resumed.status == :running
      assert {:ok, _} = Runtime.resume(run_id)
    after
      assert {:ok, _} = AgentSystemsLab.Observability.restart()
    end
  end

  defp spans(query, kind), do: Enum.filter(query["spans"], &(&1["kind"] == kind))

  defp run_facts(id) do
    for table <-
          ~w(lab_runs lab_events lab_contexts lab_model_results lab_recovery lab_intents lab_operations lab_attempts lab_retries lab_task_budgets lab_mock_effects) do
      field = if table == "lab_runs", do: "id", else: "run_id"
      {table, Repo.query!("SELECT * FROM #{table} WHERE #{field}=$1 ORDER BY 1", [id]).rows}
    end
  end

  defp case_facts(id, workflows, runs) do
    {Enum.map(runs, &run_facts/1),
     Repo.query!("SELECT * FROM lab_approval_cases WHERE id=$1", [id]).rows,
     Repo.query!("SELECT * FROM lab_approval_events WHERE case_id=$1 ORDER BY seq", [id]).rows,
     Repo.query!("SELECT * FROM lab_workflows WHERE id=ANY($1) ORDER BY id", [workflows]).rows,
     Repo.query!(
       "SELECT * FROM lab_workflow_control_events WHERE workflow_id=ANY($1) ORDER BY workflow_id,seq",
       [workflows]
     ).rows}
  end

  defp plan(c) do
    rounds =
      for id <- ["first", "second"] do
        root = Path.join(c.root, id)
        File.mkdir_p!(root)
        {:ok, workspace} = AgentSystemsLab.Tools.Workspace.new(root)

        {:ok, definition} =
          Definition.new([
            %{
              id: "worker",
              input: "PRIVATE-PROMPT",
              options: %{
                workspace: workspace.root,
                script: [
                  {:call,
                   %{
                     operation_id: "write",
                     tool: "file_write",
                     arguments: %{
                       "path" => "output.txt",
                       "content" => "PRIVATE-ARTIFACT",
                       "expected_sha256" => "absent"
                     }
                   }},
                  {:final, "PRIVATE-OUTPUT"}
                ]
              }
            }
          ])

        {:ok, artifact} = Artifact.new(workspace, ["output.txt"])
        %{id: id, definition: definition, artifacts: [artifact]}
      end

    {:ok, plan} = Plan.new(rounds)
    plan
  end

  defp request(view, id, action),
    do: %{
      actor: "lab-human",
      reason: "PRIVATE-HUMAN-REASON",
      request_id: id,
      expected_seq: view.seq,
      subject_hash: if(view.subject, do: view.subject.subject_hash),
      action: action
    }
end
