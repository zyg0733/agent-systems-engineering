defmodule AgentSystemsLab.Observability.Query do
  @moduledoc """
  A bounded, host-only diagnostic projection of existing durable facts by Run ID.

  This is not a replay or an execution API. A single PostgreSQL repeatable-read,
  read-only transaction selects metadata and small accounting projections. It
  never exports prompts, policies, model content, tool arguments/results, artifact
  contents, human identities/reasons or claim tokens. Bounded inert accounting
  and graph payloads are decoded internally through a strict output allowlist. Cross-Run relationships
  are links between independent traces, not inherited authority.

  `:limit` (default 100, maximum 200) bounds each multirow history collection
  across the selected Runs. `:max_related_runs` (default/maximum 24) bounds Run
  expansion and one-per-Run budget/recovery accounting. Workflow and case
  metadata have fixed finite bounds (three declared rounds plus one diagnostic
  overflow Workflow); their histories still use `:limit`.
  `scope: :run` restricts the selection to the requested Run. The default
  `:related` follows only that Run's stored Workflow and approval-case ownership.
  These are trusted-host scopes, not a multi-tenant authorization mechanism.
  Truncated collections and unavailable payload projections are explicit. Metric
  counts describe selected durable records, not provider latency or live spans.
  """
  import Ecto.Query
  alias AgentSystemsLab.Repo
  alias AgentSystemsLab.Observability.Context
  alias AgentSystemsLab.Storage.Context, as: ModelInput

  alias AgentSystemsLab.Storage.{
    ApprovalCase,
    ApprovalEvent,
    Attempt,
    Codec,
    Event,
    Intent,
    ModelResult,
    Operation,
    Recovery,
    Retry,
    Run,
    TaskBudget,
    Workflow,
    WorkflowControl,
    WorkflowControlEvent,
    WorkflowEvent,
    WorkflowNode
  }

  @max_progress_bytes 1_048_576
  @statuses ~w(running waiting waiting_tool blocked succeeded failed cancelled skipped pending superseded completed prepared unknown inflight exhausted closed approved rejected paused awaiting_review released ready advanced)
  @kernel_types ~w(run_started tool_requested tool_result_recorded tool_reconciled run_succeeded run_failed run_cancelled)
  @workflow_types ~w(created advanced cancelled stopped_children)
  @case_types ~w(created advanced awaiting_review review_ready approved rejected rework_started approval_invalidated failed pause resume cancel released)
  @control_types ~w(created paused running)

  def run(run_id, opts \\ []) do
    with :ok <- valid_id(run_id),
         {:ok, config} <- options(opts),
         false <- Repo.in_transaction?() do
      AgentSystemsLab.Storage.preload_vocabulary()

      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

        root =
          Repo.one(
            from r in Run,
              where: r.id == ^run_id,
              select:
                map(r, [
                  :id,
                  :status,
                  :seq,
                  :turn_count,
                  :max_turns,
                  :workflow_id,
                  :workflow_node_id,
                  :inserted_at,
                  :updated_at
                ])
          )

        if is_nil(root), do: Repo.rollback(:not_found)
        project(root, config)
      end)
    else
      true -> {:error, :nested_transaction_not_supported}
      {:error, _} = error -> error
    end
  end

  defp project(root, config) do
    workflow =
      if root.workflow_id,
        do:
          Repo.one(
            from w in Workflow,
              where: w.id == ^root.workflow_id,
              select:
                map(w, [
                  :id,
                  :status,
                  :seq,
                  :control_owner_case_id,
                  :schema_version,
                  :inserted_at,
                  :updated_at
                ])
          )

    case_id = if workflow, do: workflow.control_owner_case_id
    case_row = if case_id, do: case_metadata(case_id)
    related = related_workflows(root, workflow, case_id, config)
    workflow_ids = Enum.map(related, & &1.id)
    {runs, runs_truncated} = related_runs(root, workflow_ids, config)
    run_ids = Enum.map(runs, & &1.id)
    limit = config.limit

    {events, et} =
      limited(
        from(e in Event,
          where: e.run_id in ^run_ids,
          order_by: [e.run_id, e.seq],
          select: map(e, [:run_id, :seq, :type, :schema_version, :inserted_at])
        ),
        limit
      )

    {models, mt} =
      limited(
        from(m in ModelResult,
          where: m.run_id in ^run_ids,
          order_by: [m.run_id, m.event_seq],
          select:
            map(m, [
              :id,
              :run_id,
              :context_id,
              :input_seq,
              :event_seq,
              :schema_version,
              :inserted_at
            ])
        ),
        limit
      )

    {model_inputs, mit} =
      limited(
        from(c in ModelInput,
          left_join: m in ModelResult,
          on: m.context_id == c.id,
          where: c.run_id in ^run_ids,
          order_by: [c.run_id, c.inserted_at, c.id],
          select: %{
            id: c.id,
            run_id: c.run_id,
            run_seq: c.run_seq,
            recording_id: m.id,
            inserted_at: c.inserted_at
          }
        ),
        limit
      )

    {operations, ot} =
      limited(
        from(o in Operation,
          where: o.run_id in ^run_ids,
          order_by: [o.run_id, o.operation_id],
          select:
            map(o, [
              :id,
              :run_id,
              :operation_id,
              :status,
              :schema_version,
              :inserted_at,
              :updated_at
            ])
        ),
        limit
      )

    {attempts, at} =
      limited(
        from(a in Attempt,
          where: a.run_id in ^run_ids,
          order_by: [a.run_id, a.inserted_at, a.id],
          select:
            map(a, [
              :id,
              :run_id,
              :operation_id,
              :claim_generation,
              :kind,
              :outcome,
              :schema_version,
              :inserted_at,
              :updated_at
            ])
        ),
        limit
      )

    {intents, it} =
      limited(
        from(i in Intent,
          where: i.run_id in ^run_ids,
          order_by: [i.run_id, i.seq],
          select: %{
            id: i.id,
            run_id: i.run_id,
            seq: i.seq,
            kind: i.kind,
            status: i.status,
            generation: i.claim_generation,
            claimed: not is_nil(i.claim_token),
            claim_expires_at: i.claim_expires_at,
            available_at: i.available_at,
            inserted_at: i.inserted_at,
            updated_at: i.updated_at
          }
        ),
        limit
      )

    {retries, rt} =
      limited(
        from(r in Retry,
          where: r.run_id in ^run_ids,
          order_by: [r.run_id, r.seq, r.scope],
          select: %{
            id: r.id,
            run_id: r.run_id,
            seq: r.seq,
            scope: r.scope,
            schema_version: r.schema_version,
            codec_version: r.codec_version,
            progress_data:
              fragment(
                "CASE WHEN octet_length(?) <= ? THEN ? ELSE NULL END",
                r.state_data,
                ^@max_progress_bytes,
                r.state_data
              )
          }
        ),
        limit
      )

    budgets =
      Repo.all(
        from b in TaskBudget,
          where: b.run_id in ^run_ids,
          order_by: b.run_id,
          select: %{
            run_id: b.run_id,
            schema_version: b.schema_version,
            codec_version: b.codec_version,
            progress_data:
              fragment(
                "CASE WHEN octet_length(?) <= ? THEN ? ELSE NULL END",
                b.progress_data,
                ^@max_progress_bytes,
                b.progress_data
              )
          }
      )

    recoveries =
      Repo.all(
        from r in Recovery,
          where: r.run_id in ^run_ids,
          order_by: r.run_id,
          select: %{
            run_id: r.run_id,
            schema_version: r.schema_version,
            codec_version: r.codec_version,
            progress_data:
              fragment(
                "CASE WHEN octet_length(?) <= ? THEN ? ELSE NULL END",
                r.progress_data,
                ^@max_progress_bytes,
                r.progress_data
              )
          }
      )

    {workflow_events, wt} =
      limited(
        from(e in WorkflowEvent,
          where: e.workflow_id in ^workflow_ids,
          order_by: [e.workflow_id, e.seq],
          select: map(e, [:workflow_id, :seq, :type, :schema_version, :inserted_at])
        ),
        limit
      )

    controls =
      Repo.all(
        from c in WorkflowControl,
          where: c.workflow_id in ^workflow_ids,
          order_by: c.workflow_id,
          select: map(c, [:workflow_id, :owner_case_id, :status, :seq, :schema_version])
      )

    {control_events, ct} =
      limited(
        from(e in WorkflowControlEvent,
          where: e.workflow_id in ^workflow_ids,
          order_by: [e.workflow_id, e.seq],
          select: map(e, [:workflow_id, :seq, :type, :schema_version, :inserted_at])
        ),
        limit
      )

    {case_events, cat} =
      if case_row,
        do:
          limited(
            from(e in ApprovalEvent,
              where: e.case_id == ^case_id,
              order_by: e.seq,
              select: map(e, [:case_id, :seq, :type, :schema_version, :inserted_at])
            ),
            limit
          ),
        else: {[], false}

    {nodes, nt} =
      limited(
        from(n in WorkflowNode,
          where: n.workflow_id in ^workflow_ids,
          order_by: [n.workflow_id, n.node_id],
          select: %{
            workflow_id: n.workflow_id,
            node_id: n.node_id,
            run_id: n.run_id,
            status: n.status,
            schema_version: n.schema_version,
            codec_version: n.codec_version,
            progress_data:
              fragment(
                "CASE WHEN octet_length(?) <= ? THEN ? ELSE NULL END",
                n.data,
                ^@max_progress_bytes,
                n.data
              )
          }
        ),
        limit
      )

    nodes = if config.scope == :run, do: Enum.filter(nodes, &(&1.run_id == root.id)), else: nodes
    run_map = Map.new(runs, &{&1.id, &1})
    operation_spans = Enum.map(operations, &operation_span(&1, run_map))
    recovery_spans = Enum.map(recoveries, &recovery_span/1)
    budget_spans = Enum.map(budgets, &budget_span/1)
    retry_spans = Enum.map(retries, &retry_span/1)
    recorded_contexts = MapSet.new(models, & &1.context_id)

    spans =
      Enum.map(runs, &run_span/1) ++
        Enum.map(events, &event_span/1) ++
        Enum.map(models, &model_span/1) ++
        Enum.map(
          Enum.reject(model_inputs, &MapSet.member?(recorded_contexts, &1.id)),
          &model_input_span/1
        ) ++
        operation_spans ++
        Enum.map(attempts, &attempt_span/1) ++
        Enum.map(intents, &intent_span/1) ++
        retry_spans ++
        budget_spans ++
        recovery_spans ++
        Enum.map(related, &workflow_span/1) ++
        Enum.map(workflow_events, &workflow_event_span/1) ++
        Enum.map(controls, &control_span/1) ++
        Enum.map(control_events, &control_event_span/1) ++
        Enum.map(case_events, &case_event_span/1) ++
        if(case_row, do: [case_span(case_row)], else: [])

    spans = Enum.sort_by(spans, &{&1["kind"], &1["business_id"]})
    links = links(runs, related, nodes, case_row)

    truncation = %{
      "runs" => runs_truncated,
      "events" => et,
      "models" => mt,
      "model_inputs" => mit,
      "operations" => ot,
      "attempts" => at,
      "intents" => it,
      "retries" => rt,
      "workflow_events" => wt,
      "control_events" => ct,
      "case_events" => cat,
      "nodes" => nt,
      "workflows" => length(related) > 3
    }

    partial =
      Enum.any?(truncation, fn {_, value} -> value end) or
        Enum.any?(spans, &(&1["projection_status"] == "unavailable")) or
        Enum.any?(nodes, &(elem(progress(&1), 1) == "unavailable"))

    %{
      "schema_version" => 1,
      "evidence_origin" => "durable",
      "run_id" => root.id,
      "trace_id" => Context.trace_id(root.id),
      "scope" => to_string(config.scope),
      "limits" => %{
        "per_collection" => limit,
        "max_related_runs" => config.max_related_runs,
        "max_progress_bytes" => @max_progress_bytes
      },
      "spans" => spans,
      "links" => links,
      "truncation" => truncation,
      "partial" => partial,
      "metrics" =>
        Map.put(
          metrics(runs, models, operation_spans, attempts, intents, budget_spans, recovery_spans),
          "model_input_captures",
          length(model_inputs)
        ),
      "notes" => [
        "Durable row timestamps are commit/projection observations, not provider or tool latency.",
        "Missing model recordings do not prove that no request occurred; durable request reservations remain charged.",
        "Unknown or blocked prepared operations require reconciliation; this query neither retries nor clears them.",
        "IDs and relationships are host diagnostics; no link grants execution, file or approval authority."
      ]
    }
  end

  defp related_workflows(_root, nil, _case_id, _config), do: []
  defp related_workflows(_root, workflow, _case_id, %{scope: :run}), do: [workflow]
  defp related_workflows(_root, workflow, nil, _config), do: [workflow]

  defp related_workflows(_root, _workflow, case_id, _config) do
    # A declared case has at most three rounds; one extra row exposes corruption.
    Repo.all(
      from w in Workflow,
        where: w.control_owner_case_id == ^case_id,
        order_by: [w.inserted_at, w.id],
        limit: 4,
        select:
          map(w, [
            :id,
            :status,
            :seq,
            :control_owner_case_id,
            :schema_version,
            :inserted_at,
            :updated_at
          ])
    )
  end

  defp related_runs(root, _workflow_ids, %{scope: :run}), do: {[root], false}
  defp related_runs(root, [], _config), do: {[root], false}

  defp related_runs(root, workflow_ids, config) do
    {others, truncated} =
      limited(
        from(r in Run,
          where: r.workflow_id in ^workflow_ids and r.id != ^root.id,
          order_by: r.id,
          select:
            map(r, [
              :id,
              :status,
              :seq,
              :turn_count,
              :max_turns,
              :workflow_id,
              :workflow_node_id,
              :inserted_at,
              :updated_at
            ])
        ),
        config.max_related_runs - 1
      )

    {Enum.sort_by([root | others], & &1.id), truncated}
  end

  defp case_metadata(id) do
    Repo.one(
      from c in ApprovalCase,
        where: c.id == ^id,
        select: %{
          id: c.id,
          status: c.status,
          seq: c.seq,
          schema_version: c.schema_version,
          codec_version: c.codec_version,
          progress_data:
            fragment(
              "CASE WHEN octet_length(?) <= ? THEN ? ELSE NULL END",
              c.progress_data,
              ^@max_progress_bytes,
              c.progress_data
            )
        }
    )
  end

  defp limited(query, limit) do
    rows = Repo.all(from q in query, limit: ^(limit + 1))
    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp span(kind, id, run_id, refs, attrs) do
    Map.merge(
      %{
        "kind" => kind,
        "business_id" => business_id(id),
        "span_id" => Context.span_id(kind, id),
        "trace_id" => if(run_id, do: Context.trace_id(run_id)),
        "evidence_origin" => "durable",
        "correlation" => refs
      },
      attrs
    )
  end

  defp run_span(r),
    do:
      span(
        "run",
        r.id,
        r.id,
        %{"run_id" => r.id, "workflow_id" => r.workflow_id, "node_id" => r.workflow_node_id},
        %{
          "status" => status(r.status),
          "sequence" => r.seq,
          "turn_count" => r.turn_count,
          "max_turns" => r.max_turns,
          "created_at_unix_ms" => time(r.inserted_at),
          "updated_at_unix_ms" => time(r.updated_at)
        }
      )

  defp event_span(r),
    do:
      span("kernel_event", {r.run_id, r.seq}, r.run_id, %{"run_id" => r.run_id}, %{
        "sequence" => r.seq,
        "event_type" => fixed(r.type, @kernel_types),
        "schema_version" => r.schema_version,
        "recorded_at_unix_ms" => time(r.inserted_at),
        "parent_span_id" => Context.span_id("run", r.run_id)
      })

  defp model_span(r),
    do:
      span(
        "model_recording",
        r.id,
        r.run_id,
        %{
          "run_id" => r.run_id,
          "recording_id" => r.id,
          "context_id" => r.context_id,
          "attempt_id" => r.context_id
        },
        %{
          "span_id" => Context.span_id(:model, {r.run_id, r.context_id}),
          "input_sequence" => r.input_seq,
          "event_sequence" => r.event_seq,
          "schema_version" => r.schema_version,
          "status" => "recorded",
          "recorded_at_unix_ms" => time(r.inserted_at),
          "parent_span_id" => Context.span_id("run", r.run_id)
        }
      )

  defp model_input_span(r) do
    span(
      "model_input",
      r.id,
      r.run_id,
      %{"run_id" => r.run_id, "context_id" => r.id, "attempt_id" => r.id},
      %{
        "span_id" => Context.span_id(:model, {r.run_id, r.id}),
        "parent_span_id" => Context.span_id(:run, r.run_id),
        "input_sequence" => r.run_seq,
        "status" =>
          if(r.recording_id,
            do: "recording_outside_selected_results",
            else: "input_captured_without_recording"
          ),
        "recording_id" => r.recording_id,
        "recorded_at_unix_ms" => time(r.inserted_at)
      }
    )
  end

  defp operation_span(r, runs) do
    unknown =
      r.status == "unknown" or
        (r.status == "prepared" and get_in(runs, [r.run_id, :status]) == "blocked")

    span(
      "operation",
      {r.run_id, r.operation_id},
      r.run_id,
      %{"run_id" => r.run_id, "operation_id" => r.operation_id},
      %{
        "status" => status(r.status),
        "manual_reconciliation" => unknown,
        "schema_version" => r.schema_version,
        "created_at_unix_ms" => time(r.inserted_at),
        "updated_at_unix_ms" => time(r.updated_at),
        "parent_span_id" => Context.span_id("run", r.run_id)
      }
    )
  end

  defp attempt_span(r),
    do:
      span(
        "tool_attempt",
        r.id,
        r.run_id,
        %{
          "run_id" => r.run_id,
          "operation_id" => r.operation_id,
          "attempt_id" => r.id,
          "generation" => r.claim_generation
        },
        %{
          "span_id" => Context.span_id(:tool, {r.run_id, r.operation_id, r.id}),
          "kind_of_attempt" => fixed(r.kind, ~w(execution lookup manual observation)),
          "outcome" => fixed(r.outcome, ~w(prepared completed unknown)),
          "schema_version" => r.schema_version,
          "created_at_unix_ms" => time(r.inserted_at),
          "updated_at_unix_ms" => time(r.updated_at),
          "parent_span_id" => Context.span_id(:run, r.run_id),
          "operation_span_id" => Context.span_id(:operation, {r.run_id, r.operation_id})
        }
      )

  defp intent_span(r),
    do:
      span(
        "scheduling_intent",
        r.id,
        r.run_id,
        %{"run_id" => r.run_id, "intent_id" => r.id, "generation" => r.generation},
        %{
          "span_id" => Context.span_id(:intent, {r.run_id, r.id, r.generation}),
          "sequence" => r.seq,
          "intent_kind" => fixed(r.kind, ~w(model tool reconcile)),
          "status" => status(r.status),
          "claimed" => r.claimed,
          "available_at_unix_ms" => time(r.available_at),
          "lease_expires_at_unix_ms" => time(r.claim_expires_at),
          "created_at_unix_ms" => time(r.inserted_at),
          "updated_at_unix_ms" => time(r.updated_at),
          "parent_span_id" => Context.span_id("run", r.run_id)
        }
      )

  defp retry_span(r) do
    {p, availability} = progress(r)

    span(
      "retry",
      {r.run_id, r.seq, r.scope},
      r.run_id,
      %{"run_id" => r.run_id},
      Map.merge(
        %{
          "sequence" => r.seq,
          "scope" => fixed(r.scope, ~w(model tool reconcile)),
          "schema_version" => r.schema_version,
          "projection_status" => availability,
          "status" => status(p[:status]),
          "parent_span_id" => Context.span_id("run", r.run_id)
        },
        numbers(p, [:attempts, :next_attempt_at_ms, :first_attempt_at_ms])
      )
    )
  end

  defp budget_span(r) do
    {p, availability} = progress(r)

    span(
      "task_budget",
      r.run_id,
      r.run_id,
      %{"run_id" => r.run_id},
      Map.merge(
        %{
          "schema_version" => r.schema_version,
          "projection_status" => availability,
          "parent_span_id" => Context.span_id("run", r.run_id)
        },
        numbers(p, [:dispatches, :last_seq, :execution_deadline_at_ms])
      )
    )
  end

  defp recovery_span(r) do
    {p, availability} = progress(r)

    span(
      "recovery_accounting",
      r.run_id,
      r.run_id,
      %{"run_id" => r.run_id},
      Map.merge(
        %{
          "schema_version" => r.schema_version,
          "projection_status" => availability,
          "parent_span_id" => Context.span_id("run", r.run_id)
        },
        numbers(p, [
          :last_seq,
          :cursor,
          :model_attempts,
          :output_bytes,
          :deadline_at_ms,
          :request_deadline_at_ms
        ])
      )
    )
  end

  defp workflow_span(w),
    do:
      span(
        "workflow",
        w.id,
        nil,
        %{"workflow_id" => w.id, "case_id" => w.control_owner_case_id},
        %{"status" => status(w.status), "sequence" => w.seq, "schema_version" => w.schema_version}
      )

  defp workflow_event_span(e),
    do:
      span("workflow_event", {e.workflow_id, e.seq}, nil, %{"workflow_id" => e.workflow_id}, %{
        "sequence" => e.seq,
        "event_type" => fixed(e.type, @workflow_types),
        "schema_version" => e.schema_version,
        "recorded_at_unix_ms" => time(e.inserted_at),
        "parent_span_id" => Context.span_id("workflow", e.workflow_id)
      })

  defp control_span(c),
    do:
      span(
        "workflow_control",
        c.workflow_id,
        nil,
        %{"workflow_id" => c.workflow_id, "case_id" => c.owner_case_id},
        %{
          "sequence" => c.seq,
          "status" => status(c.status),
          "schema_version" => c.schema_version,
          "parent_span_id" => Context.span_id("workflow", c.workflow_id)
        }
      )

  defp control_event_span(e),
    do:
      span(
        "workflow_control_event",
        {e.workflow_id, e.seq},
        nil,
        %{"workflow_id" => e.workflow_id},
        %{
          "sequence" => e.seq,
          "event_type" => fixed(e.type, @control_types),
          "schema_version" => e.schema_version,
          "recorded_at_unix_ms" => time(e.inserted_at),
          "parent_span_id" => Context.span_id("workflow_control", e.workflow_id)
        }
      )

  defp case_span(c) do
    {p, availability} = progress(c)

    span(
      "approval_case",
      c.id,
      nil,
      %{"case_id" => c.id},
      Map.merge(
        %{
          "sequence" => c.seq,
          "status" => status(c.status),
          "schema_version" => c.schema_version,
          "projection_status" => availability,
          "approval_present" => is_map(p[:approval]),
          "subject_hash" => subject_hash(p[:subject]),
          "approved_subject_hash" => subject_hash(p[:approval]),
          "rounds" => rounds(c)
        },
        numbers(p, [:current_round, :generation, :deadline_at_ms])
      )
    )
  end

  defp case_event_span(e),
    do:
      span("approval_event", {e.case_id, e.seq}, nil, %{"case_id" => e.case_id}, %{
        "sequence" => e.seq,
        "event_type" => fixed(e.type, @case_types),
        "schema_version" => e.schema_version,
        "recorded_at_unix_ms" => time(e.inserted_at),
        "parent_span_id" => Context.span_id("approval_case", e.case_id)
      })

  defp links(runs, workflows, nodes, case_row) do
    child_links =
      for r <- runs,
          r.workflow_id,
          do: link("workflow_child", "workflow", r.workflow_id, "run", r.id)

    owner_links =
      case case_row do
        %{id: owner_id} ->
          for w <- workflows,
              w.control_owner_case_id == owner_id,
              do: link("case_round", "approval_case", owner_id, "workflow", w.id)

        nil ->
          []
      end

    declared_rounds = if case_row, do: rounds(case_row), else: []
    order = Map.new(declared_rounds, &{&1["workflow_id"], &1["round_index"]})

    round_links =
      workflows
      |> Enum.sort_by(&Map.get(order, &1.id, 4))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        link("later_declared_round", "workflow", a.id, "workflow", b.id)
      end)

    rework_links =
      if case_row do
        {p, _} = progress(case_row)

        decisions =
          if is_list(p[:decisions]),
            do:
              Enum.filter(
                p.decisions,
                &(is_map(&1) and &1[:action] == :rework and is_integer(&1[:seq]))
              ),
            else: []

        for {decision, next} <- Enum.zip(Enum.take(decisions, 2), Enum.drop(declared_rounds, 1)),
            next["status"] != "pending",
            do:
              link(
                "rework_started_round",
                "approval_event",
                {case_row.id, decision.seq},
                "workflow",
                next["workflow_id"]
              )
      else
        []
      end

    node_map = Map.new(nodes, &{{&1.workflow_id, &1.node_id}, &1})

    dependency_links =
      Enum.flat_map(nodes, fn node ->
        {p, _} = progress(node)
        deps = if is_list(p[:deps]), do: Enum.take(p.deps, 8), else: []

        for dep <- deps,
            is_binary(dep),
            parent = Map.get(node_map, {node.workflow_id, dep}),
            parent,
            do: link("dag_dependency", "run", parent.run_id, "run", node.run_id)
      end)

    # Node membership remains visible even for a dependency that was never admitted.
    membership =
      for n <- nodes,
          do:
            Map.merge(link("declared_node", "workflow", n.workflow_id, "run", n.run_id), %{
              "node_id" => n.node_id,
              "status" => status(n.status),
              "run_selected" => Enum.any?(runs, &(&1.id == n.run_id)),
              "admission_status" =>
                if(n.status in ["waiting", "skipped"], do: "not_admitted", else: "admitted"),
              "dependency_projection" => elem(progress(n), 1)
            })

    Enum.sort_by(
      child_links ++ owner_links ++ round_links ++ rework_links ++ dependency_links ++ membership,
      &{&1["relationship"], &1["from_span_id"], &1["to_span_id"]}
    )
  end

  defp link(kind, from_kind, from, to_kind, to),
    do: %{
      "relationship" => kind,
      "from_span_id" => Context.span_id(from_kind, from),
      "to_span_id" => Context.span_id(to_kind, to),
      "from_trace_id" => if(from_kind == "run", do: Context.trace_id(from)),
      "to_trace_id" => if(to_kind == "run", do: Context.trace_id(to)),
      "evidence_origin" => "durable"
    }

  defp metrics(runs, models, operations, attempts, intents, budgets, recoveries) do
    %{
      "aggregation" => "selected_durable_records",
      "runs" => length(runs),
      "model_recordings" => length(models),
      "operations" => length(operations),
      "tool_attempts" => length(attempts),
      "scheduling_intents" => length(intents),
      "manual_reconciliation_operations" => Enum.count(operations, & &1["manual_reconciliation"]),
      "dispatches_reserved" => sum(budgets, "dispatches"),
      "model_attempts_reserved" => sum(recoveries, "model_attempts"),
      "output_bytes_charged" => sum(recoveries, "output_bytes")
    }
  end

  defp business_id(id) when is_tuple(id),
    do: id |> Tuple.to_list() |> Enum.map_join(":", &to_string/1)

  defp business_id(id), do: to_string(id)

  defp subject_hash(%{subject_hash: hash}) when is_binary(hash) do
    if String.match?(hash, ~r/\A[a-f0-9]{64}\z/), do: hash
  end

  defp subject_hash(_), do: nil

  defp rounds(c) do
    {p, _} = progress(c)
    candidates = if is_list(p[:rounds]), do: Enum.take(p.rounds, 3), else: []

    for round <- candidates,
        is_map(round),
        is_integer(round[:index]) and round[:index] in 0..2,
        is_binary(round[:workflow_id]) and byte_size(round[:workflow_id]) in 1..128,
        do: %{
          "round_index" => round.index,
          "workflow_id" => round.workflow_id,
          "status" => status(round[:status])
        }
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, fn row, acc -> acc + (row[key] || 0) end)

  defp progress(%{schema_version: 1, progress_data: data, codec_version: version})
       when is_binary(data) do
    case Codec.decode(data, version) do
      {:ok, p} when is_map(p) -> {p, "available"}
      _ -> {%{}, "unavailable"}
    end
  end

  defp progress(_), do: {%{}, "unavailable"}

  defp numbers(map, keys),
    do:
      Map.new(keys, fn key ->
        value = Map.get(map, key)
        {Atom.to_string(key), if(is_integer(value) and value >= 0, do: value)}
      end)

  defp status(nil), do: nil
  defp status(value) when is_atom(value), do: status(Atom.to_string(value))
  defp status(value), do: fixed(value, @statuses)
  defp fixed(value, allowed), do: if(value in allowed, do: value, else: "unrecognized")
  defp time(nil), do: nil
  defp time(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Keyword.keys(opts) -- [:limit, :max_related_runs, :scope] == [] do
      config = %{
        limit: Keyword.get(opts, :limit, 100),
        max_related_runs: Keyword.get(opts, :max_related_runs, 24),
        scope: Keyword.get(opts, :scope, :related)
      }

      if is_integer(config.limit) and config.limit in 1..200 and
           is_integer(config.max_related_runs) and config.max_related_runs in 1..24 and
           config.scope in [:run, :related],
         do: {:ok, config},
         else: {:error, :invalid_observability_query_options}
    else
      {:error, :invalid_observability_query_options}
    end
  end

  defp options(_), do: {:error, :invalid_observability_query_options}

  defp valid_id(id),
    do:
      if(
        is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
          not String.contains?(id, <<0>>),
        do: :ok,
        else: {:error, :invalid_run_id}
      )
end
