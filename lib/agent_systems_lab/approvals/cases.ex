defmodule AgentSystemsLab.Approvals.Cases do
  @moduledoc """
  Durable human review over a finite, host-declared sequence of Workflows.

  Every round reserves its original budget before the first round starts. A
  decision names an observed generation and exact artifact bytes; release only
  returns that immutable snapshot after checking the current filesystem again.
  It performs no publication or tool execution. Identity is supplied by the
  trusted host and checked against the plan's approver allowlist.
  """
  import Ecto.Query
  alias AgentSystemsLab.{Context, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Approvals.{Artifact, Plan}
  alias AgentSystemsLab.Storage.{ApprovalCase, ApprovalEvent, Codec}
  alias AgentSystemsLab.Workflows.{ControlStore, Store}
  @statuses [:running, :paused, :awaiting_review, :approved, :rejected, :cancelled, :failed]
  @closed [:rejected, :cancelled, :failed]
  @projection_keys [
    :status,
    :current_round,
    :rounds,
    :subject,
    :approval,
    :decisions,
    :requests,
    :deadline_at_ms,
    :generation,
    :reason,
    :resume_status
  ]
  @request_keys [:actor, :reason, :request_id, :expected_seq, :subject_hash]

  def create(id, plan, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         :ok <- valid_id(id),
         :ok <- Plan.validate(plan),
         {:ok, checked} <- Plan.from_map(Plan.to_map(plan)),
         {:ok, round} <- Plan.round(checked, 0),
         :ok <- check_admission(round) do
      transaction(opts, fn ->
        if Repo.get(ApprovalCase, id), do: Repo.rollback({:already_exists, id})
        unwrap(check_admission(round))
        deadline = RecoveryStore.now_ms(Repo) + checked.timeout_ms

        rounds =
          checked.rounds
          |> Enum.with_index()
          |> Enum.map(fn {r, index} ->
            %{
              index: index,
              id: r.id,
              workflow_id: Plan.workflow_id(id, r.id),
              status: if(index == 0, do: :running, else: :pending),
              proof: nil
            }
          end)

        p = %{
          status: :running,
          current_round: 0,
          rounds: rounds,
          subject: nil,
          approval: nil,
          decisions: [],
          requests: %{},
          deadline_at_ms: deadline,
          generation: 0,
          reason: nil,
          resume_status: nil
        }

        raw = Plan.to_map(checked)

        row =
          unwrap(
            Repo.insert(
              ApprovalCase.changeset(%ApprovalCase{}, %{
                id: id,
                status: "running",
                seq: 0,
                plan_data: encode!(raw),
                plan_sha256: Context.hash(raw),
                progress_data: encode!(p),
                deadline_at_ms: deadline
              })
            )
          )

        enroll(row, round, 0)
        row |> save(p, "created", nil, nil) |> decode!()
      end)
    end
  end

  def load(id) do
    with :ok <- boundary(), :ok <- valid_id(id) do
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

        case Repo.get(ApprovalCase, id) do
          nil -> Repo.rollback(:not_found)
          row -> decode!(row)
        end
      end)
    end
  end

  def rebuild(id), do: load(id)

  def sync(id, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, before} <- load(id),
         {:ok, workflow} <- sync_workflow(before),
         observation = observe_subject(before, workflow),
         {:ok, view} <-
           transaction(opts, fn ->
             row = lock!(id)
             current = decode!(row)
             p = projection(current)

             p =
               cond do
                 p.status in @closed ->
                   p

                 RecoveryStore.now_ms(Repo) >= row.deadline_at_ms ->
                   pause_owned(current, {:budget_exceeded, :approval_timeout})

                   %{
                     p
                     | status: :failed,
                       reason: {:budget_exceeded, :approval_timeout},
                       approval: nil
                   }

                 current.seq != before.seq ->
                   p

                 p.status == :paused ->
                   p

                 p.status == :running ->
                   observe_workflow(current, p, workflow, observation)

                 p.status in [:awaiting_review, :approved] ->
                   refresh_review(current, p, observation)
               end

             if p === projection(current),
               do: current,
               else: row |> save(p, event_for(current, p), projection(current), nil) |> decode!()
           end),
         :ok <- repair_closed(view) do
      {:ok, view}
    end
  end

  def pause(id, request, opts \\ []), do: control(id, request, :pause, opts)
  def resume(id, request, opts \\ []), do: control(id, request, :resume, opts)
  def cancel(id, request, opts \\ []), do: control(id, request, :cancel, opts)

  def decide(id, request, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         :ok <- request_shape(request, :decision),
         {:ok, before} <- load(id),
         :ok <- identity(before.plan, request),
         {:ok, workflow} <- Store.load(before.workflow_id),
         observation = observe_subject(before, workflow),
         {:ok, result} <-
           transaction(opts, fn ->
             row = lock!(id)
             current = decode!(row)

             case duplicate(current, request, :decision) do
               :new ->
                 unwrap(cas(current, request))
                 unwrap(observation_sequence(current, before))

                 if current.status != :awaiting_review,
                   do: Repo.rollback({:invalid_approval_state, current.status})

                 if RecoveryStore.now_ms(Repo) >= row.deadline_at_ms,
                   do: Repo.rollback({:budget_exceeded, :approval_timeout})

                 decide_new(row, current, request, observation)

               :same ->
                 if current.status == :approved and
                      current.approval.request_id == request.request_id do
                   unwrap(observation_sequence(current, before))

                   case fresh(current, observation) do
                     :ok -> current
                     {:error, reason} -> invalidated(row, current, observation, reason)
                   end
                 else
                   current
                 end

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end),
         :ok <- repair_closed(result_view(result)) do
      result
      |> action_result()
    end
  end

  def release(id, request, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         :ok <- request_shape(request, :control),
         {:ok, before} <- load(id),
         :ok <- identity(before.plan, request),
         {:ok, workflow} <- Store.load(before.workflow_id),
         observation = observe_subject(before, workflow),
         {:ok, result} <-
           transaction(opts, fn ->
             row = lock!(id)
             current = decode!(row)

             if current.status != :approved or is_nil(current.approval),
               do: Repo.rollback({:invalid_approval_state, current.status})

             # Even an idempotent retry must observe current files and generation.
             unwrap(observation_sequence(current, before))

             case fresh(current, observation) do
               :ok ->
                 if RecoveryStore.now_ms(Repo) >= row.deadline_at_ms,
                   do: Repo.rollback({:budget_exceeded, :approval_timeout})

                 case duplicate(current, request, :release) do
                   :new ->
                     unwrap(cas(current, request))
                     unwrap(observation_sequence(current, before))
                     p = record(projection(current), request, :release)
                     view = row |> save(p, "released", projection(current), request) |> decode!()
                     {:released, view}

                   :same ->
                     {:released, current}

                   {:error, reason} ->
                     Repo.rollback(reason)
                 end

               {:error, reason} ->
                 invalidated(row, current, observation, reason)
             end
           end) do
      case result do
        {:released, view} -> {:ok, %{case: view, snapshot: view.subject, approval: view.approval}}
        other -> action_result(other)
      end
    end
  end

  defp control(id, request, action, opts) do
    with :ok <- boundary(),
         :ok <- options(opts),
         :ok <- request_shape(request, :control),
         {:ok, before} <- load(id),
         :ok <- identity(before.plan, request),
         {:ok, workflow} <- Store.load(before.workflow_id),
         observation = observe_subject(before, workflow),
         {:ok, result} <-
           transaction(opts, fn ->
             row = lock!(id)
             current = decode!(row)

             case duplicate(current, request, action) do
               :same ->
                 current

               {:error, reason} ->
                 Repo.rollback(reason)

               :new ->
                 unwrap(cas(current, request))
                 unwrap(observation_sequence(current, before))
                 p = projection(current)

                 if action == :resume and p.status == :paused and p.resume_status == :approved and
                      fresh(current, observation) != :ok do
                   {:error, reason} = fresh(current, observation)
                   invalidated(row, current, observation, reason)
                 else
                   next =
                     case action do
                       :pause ->
                         if p.status in @closed or p.status == :paused,
                           do: Repo.rollback({:invalid_approval_state, p.status})

                         pause_owned(current, {:human_pause, request.actor, request.reason})

                         %{
                           p
                           | status: :paused,
                             resume_status: p.status,
                             reason: {:human_pause, request.reason}
                         }

                       :resume ->
                         if p.status != :paused,
                           do: Repo.rollback({:invalid_approval_state, p.status})

                         if RecoveryStore.now_ms(Repo) >= row.deadline_at_ms,
                           do: Repo.rollback({:budget_exceeded, :approval_timeout})

                         if p.resume_status == :running,
                           do:
                             unwrap(
                               ControlStore.set_owned_in_transaction(
                                 Repo,
                                 current.workflow_id,
                                 current.id,
                                 :running,
                                 {:human_resume, request.actor}
                               )
                             )

                         %{p | status: p.resume_status, resume_status: nil, reason: nil}

                       :cancel ->
                         if p.status in @closed,
                           do: Repo.rollback({:invalid_approval_state, p.status})

                         pause_owned(current, {:human_cancel, request.actor, request.reason})

                         %{
                           p
                           | status: :cancelled,
                             approval: nil,
                             reason: {:human_cancel, request.reason},
                             resume_status: nil
                         }
                     end

                   next = record(next, request, action)
                   row |> save(next, Atom.to_string(action), p, request) |> decode!()
                 end
             end
           end),
         :ok <- repair_closed(result_view(result)) do
      action_result(result)
    end
  end

  defp decide_new(row, current, request, observation) do
    case request.action do
      :approve ->
        case fresh(current, observation) do
          :ok ->
            if is_nil(current.subject), do: Repo.rollback(:artifact_review_unavailable)

            decision =
              Map.take(request, [:actor, :reason, :request_id, :subject_hash])
              |> Map.merge(%{
                action: :approve,
                generation: current.generation,
                seq: current.seq + 1
              })

            p =
              %{
                projection(current)
                | status: :approved,
                  approval: decision,
                  reason: nil,
                  decisions: current.decisions ++ [decision]
              }
              |> record(request, :decision)

            row |> save(p, "approved", projection(current), request) |> decode!()

          {:error, reason} ->
            invalidated(row, current, observation, reason)
        end

      :reject ->
        pause_owned(current, {:human_reject, request.actor, request.reason})
        p = append_decision(current, request, :rejected) |> record(request, :decision)
        row |> save(p, "rejected", projection(current), request) |> decode!()

      :rework ->
        index = current.current_round + 1
        round = unwrap(Plan.round(current.plan, index))
        unwrap(check_admission(round))
        pause_owned(current, {:rework, request.actor, request.reason})
        enroll(row, round, index)
        rounds = List.update_at(current.rounds, index, &%{&1 | status: :running})
        p = append_decision(current, request, :running)

        p =
          %{
            p
            | current_round: index,
              rounds: rounds,
              subject: nil,
              approval: nil,
              generation: p.generation + 1,
              reason: nil
          }
          |> record(request, :decision)

        row |> save(p, "rework_started", projection(current), request) |> decode!()
    end
  end

  defp append_decision(current, request, status) do
    decision =
      Map.take(request, [:actor, :reason, :request_id, :subject_hash, :action])
      |> Map.merge(%{generation: current.generation, seq: current.seq + 1})

    %{
      projection(current)
      | status: status,
        approval: nil,
        reason: {:human_decision, request.action, request.reason},
        decisions: current.decisions ++ [decision]
    }
  end

  defp observe_workflow(current, p, workflow, observation) do
    case workflow.status do
      :succeeded ->
        pause_owned(current, :awaiting_human_review)
        proof = workflow_proof(workflow)

        rounds =
          List.update_at(p.rounds, p.current_round, &%{&1 | status: :succeeded, proof: proof})

        p = %{p | status: :awaiting_review, rounds: rounds, generation: p.generation + 1}
        with_subject(current, p, observation)

      status when status in [:failed, :cancelled] ->
        pause_owned(current, {:round_failed, status})

        %{
          p
          | status: :failed,
            reason: {:round_failed, status},
            approval: nil,
            rounds: List.update_at(p.rounds, p.current_round, &%{&1 | status: status})
        }

      :blocked ->
        %{p | reason: :reconciliation_required}

      _ ->
        p
    end
  end

  defp refresh_review(
         _current,
         %{subject: nil, reason: {:artifact_conflict, reason}} = p,
         {:error, reason}
       ),
       do: p

  defp refresh_review(current, p, observation) do
    case fresh(current, observation) do
      :ok ->
        p

      {:error, reason} ->
        %{
          p
          | status: :awaiting_review,
            approval: nil,
            generation: p.generation + 1,
            reason: {:approval_invalidated, reason}
        }
        |> then(&with_subject(current, &1, observation))
    end
  end

  defp with_subject(current, p, {:ok, snapshots, proof}) do
    subject = %{
      schema_version: 1,
      generation: p.generation,
      workflow_id: current.workflow_id,
      workflow_seq: proof.seq,
      workflow_hash: Context.hash(proof),
      artifacts: snapshots
    }

    hash =
      Context.hash(
        {"approval-subject.v1", current.id, current.plan_hash, current.current_round, subject}
      )

    %{p | subject: Map.put(subject, :subject_hash, hash), reason: nil}
  end

  defp with_subject(_current, p, {:error, reason}),
    do: %{p | subject: nil, reason: {:artifact_conflict, reason}}

  defp with_subject(_current, p, :not_ready), do: p

  defp invalidated(row, current, observation, reason) do
    p =
      %{
        projection(current)
        | status: :awaiting_review,
          approval: nil,
          generation: current.generation + 1,
          resume_status: nil,
          reason: {:approval_invalidated, reason}
      }
      |> then(&with_subject(current, &1, observation))

    view = row |> save(p, "approval_invalidated", projection(current), nil) |> decode!()
    {:invalidated, reason, view}
  end

  defp fresh(current, {:ok, snapshots, proof}) do
    cond do
      is_nil(current.subject) ->
        {:error, :artifact_review_unavailable}

      current.subject.workflow_hash != Context.hash(proof) ->
        {:error, :workflow_proof_changed}

      Enum.map(current.subject.artifacts, & &1.hash) != Enum.map(snapshots, & &1.hash) ->
        {:error, :artifact_changed}

      true ->
        :ok
    end
  end

  defp fresh(_current, {:error, reason}), do: {:error, reason}
  defp fresh(_current, :not_ready), do: {:error, :workflow_not_complete}

  defp observe_subject(view, %{status: :succeeded} = workflow) do
    with {:ok, round} <- Plan.round(view.plan, view.current_round),
         {:ok, snapshots} <- capture(round.artifacts) do
      {:ok, snapshots, workflow_proof(workflow)}
    end
  end

  defp observe_subject(_, _), do: :not_ready

  defp capture(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, acc} ->
      case Artifact.capture(artifact) do
        {:ok, snapshot} -> {:cont, {:ok, acc ++ [snapshot]}}
        error -> {:halt, error}
      end
    end)
  end

  defp check_admission(round) do
    Enum.reduce_while(round.artifacts, :ok, fn artifact, :ok ->
      case Artifact.check_baselines(artifact) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_workflow(%{status: status} = view) when status in @closed,
    do: Store.load(view.workflow_id)

  defp sync_workflow(%{status: :paused} = view), do: Store.load(view.workflow_id)
  defp sync_workflow(view), do: Store.sync(view.workflow_id)

  defp workflow_proof(w) do
    %{
      id: w.id,
      seq: w.seq,
      status: w.status,
      deadline_at_ms: w.deadline_at_ms,
      definition_hash: Context.hash(AgentSystemsLab.Workflows.Definition.to_map(w.definition)),
      nodes: w.nodes
    }
  end

  defp enroll(row, round, _index) do
    unwrap(
      Store.create_in_transaction(Repo, Plan.workflow_id(row.id, round.id), round.definition,
        owner_case_id: row.id,
        deadline_at_ms: row.deadline_at_ms
      )
    )
  end

  defp pause_owned(view, reason),
    do:
      unwrap(
        ControlStore.set_owned_in_transaction(
          Repo,
          view.workflow_id,
          view.id,
          :paused,
          reason
        )
      )

  defp repair_closed(%{status: status} = view) when status in @closed do
    case Store.cancel(view.workflow_id, {:approval_case_closed, view.id, view.reason}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp repair_closed(_), do: :ok

  defp request_shape(request, type) when is_map(request) do
    keys = if type == :decision, do: [:action | @request_keys], else: @request_keys

    valid =
      Enum.sort(Map.keys(request)) == Enum.sort(keys) and
        text?(request.actor, 128) and text?(request.reason, 2048) and
        text?(request.request_id, 128) and
        is_integer(request.expected_seq) and request.expected_seq > 0 and
        (is_nil(request.subject_hash) or hash?(request.subject_hash)) and
        (type != :decision or request.action in [:approve, :rework, :reject])

    if valid, do: :ok, else: {:error, :invalid_approval_request}
  end

  defp request_shape(_, _), do: {:error, :invalid_approval_request}

  defp identity(plan, request),
    do: if(request.actor in plan.approvers, do: :ok, else: {:error, :unauthorized_approver})

  defp observation_sequence(current, before),
    do:
      if(current.seq == before.seq and current.workflow_id == before.workflow_id,
        do: :ok,
        else: {:error, :approval_observation_stale}
      )

  defp cas(current, request) do
    hash = if current.subject, do: current.subject.subject_hash

    cond do
      current.seq != request.expected_seq ->
        {:error, {:stale_sequence, request.expected_seq, current.seq}}

      hash != request.subject_hash ->
        {:error, :stale_approval_subject}

      true ->
        :ok
    end
  end

  defp duplicate(view, request, action) do
    case Map.get(view.requests, request.request_id) do
      nil -> :new
      %{request: ^request, action: ^action} -> :same
      _ -> {:error, :approval_request_conflict}
    end
  end

  defp record(p, request, action),
    do: %{
      p
      | requests: Map.put(p.requests, request.request_id, %{request: request, action: action})
    }

  defp save(row, p, type, previous, request) do
    seq = row.seq + 1

    event = %{
      previous_sha256: if(previous, do: Context.hash(previous)),
      projection: p,
      request: request
    }

    unwrap(
      Repo.insert(
        ApprovalEvent.changeset(%ApprovalEvent{}, %{
          case_id: row.id,
          seq: seq,
          type: type,
          data: encode!(event)
        })
      )
    )

    unwrap(
      Repo.update(
        ApprovalCase.changeset(row, %{
          status: to_string(p.status),
          seq: seq,
          progress_data: encode!(p)
        })
      )
    )
  end

  defp decode(row) do
    Storage.preload_vocabulary()
    Code.ensure_loaded(Plan)
    Code.ensure_loaded(Artifact)

    with true <- row.schema_version == 1 || {:error, :unsupported_schema_version},
         {:ok, raw} <- Codec.decode(row.plan_data, row.codec_version),
         true <- Context.hash(raw) == row.plan_sha256 || {:error, :plan_hash_mismatch},
         {:ok, plan} <- Plan.from_map(raw),
         {:ok, p} <- Codec.decode(row.progress_data, row.codec_version),
         :ok <- validate_projection(row, plan, p),
         :ok <- verify_bindings(row, plan, p),
         {:ok, events} <- replay(row, plan, p) do
      active = Enum.at(p.rounds, p.current_round)

      {:ok,
       Map.merge(p, %{
         id: row.id,
         plan: plan,
         plan_hash: row.plan_sha256,
         seq: row.seq,
         workflow_id: active.workflow_id,
         events: events
       })}
    else
      {:error, reason} -> {:error, {:corrupt_approval_case, reason}}
      _ -> {:error, {:corrupt_approval_case, :invalid_payload}}
    end
  rescue
    _error in [
      KeyError,
      BadMapError,
      BadBooleanError,
      ArgumentError,
      FunctionClauseError,
      Protocol.UndefinedError
    ] ->
      {:error, {:corrupt_approval_case, :invalid_payload}}
  end

  defp validate_projection(row, plan, p) do
    valid =
      is_map(p) and Enum.sort(Map.keys(p)) == Enum.sort(@projection_keys) and
        p.status in @statuses and to_string(p.status) == row.status and
        p.deadline_at_ms == row.deadline_at_ms and is_integer(p.generation) and p.generation >= 0 and
        is_integer(p.current_round) and p.current_round >= 0 and
        p.current_round < length(plan.rounds) and
        is_list(p.rounds) and length(p.rounds) == length(plan.rounds) and
        Enum.all?(Enum.with_index(p.rounds), fn {round, i} ->
          spec = Enum.at(plan.rounds, i)

          Enum.sort(Map.keys(round)) ==
            Enum.sort([:index, :id, :workflow_id, :status, :proof]) and
            round.index == i and round.id == spec.id and
            round.workflow_id == Plan.workflow_id(row.id, spec.id) and
            round.status in [:pending, :running, :succeeded, :failed, :cancelled] and
            (i <= p.current_round or (round.status == :pending and is_nil(round.proof))) and
            (is_nil(round.proof) or (round.status == :succeeded and is_map(round.proof)))
        end)

    valid =
      valid and is_list(p.decisions) and is_map(p.requests) and
        (p.status != :approved or (is_map(p.approval) and is_map(p.subject))) and
        (p.status != :paused or p.resume_status in [:running, :awaiting_review, :approved]) and
        valid_subject?(row, p) and subject_matches_plan?(plan, p) and
        Enum.all?(p.requests, fn {id, entry} ->
          is_binary(id) and is_map(entry) and
            Enum.sort(Map.keys(entry)) == [:action, :request] and
            entry.request.request_id == id and
            request_shape(
              entry.request,
              if(entry.action == :decision, do: :decision, else: :control)
            ) == :ok and
            entry.request.actor in plan.approvers and
            entry.action in [:pause, :resume, :cancel, :release, :decision]
        end)

    if valid, do: :ok, else: {:error, :projection_mismatch}
  end

  defp valid_subject?(_row, %{subject: nil, approval: nil}), do: true

  defp valid_subject?(row, p) when is_map(p.subject) do
    s = p.subject

    expected = [
      :schema_version,
      :generation,
      :workflow_id,
      :workflow_seq,
      :workflow_hash,
      :artifacts,
      :subject_hash
    ]

    Enum.sort(Map.keys(s)) == Enum.sort(expected) and s.schema_version == 1 and
      s.generation == p.generation and
      is_map(Enum.at(p.rounds, p.current_round).proof) and
      Context.hash(Enum.at(p.rounds, p.current_round).proof) == s.workflow_hash and
      Enum.at(p.rounds, p.current_round).proof.seq == s.workflow_seq and
      s.workflow_id == Enum.at(p.rounds, p.current_round).workflow_id and
      is_integer(s.workflow_seq) and s.workflow_seq > 0 and hash?(s.workflow_hash) and
      is_list(s.artifacts) and Enum.all?(s.artifacts, &(Artifact.validate_snapshot(&1) == :ok)) and
      s.subject_hash ==
        Context.hash(
          {"approval-subject.v1", row.id, row.plan_sha256, p.current_round,
           Map.delete(s, :subject_hash)}
        ) and
      (is_nil(p.approval) or
         (p.approval.subject_hash == s.subject_hash and p.approval.generation == p.generation))
  end

  defp valid_subject?(_, _), do: false

  defp subject_matches_plan?(_plan, %{subject: nil}), do: true

  defp subject_matches_plan?(plan, p) do
    round = Enum.at(plan.rounds, p.current_round)
    proof = Enum.at(p.rounds, p.current_round).proof

    proof.id == Enum.at(p.rounds, p.current_round).workflow_id and proof.status == :succeeded and
      proof.definition_hash == Context.hash(round.definition) and
      length(round.artifacts) == length(p.subject.artifacts) and
      Enum.all?(Enum.zip(round.artifacts, p.subject.artifacts), fn {raw_spec, snapshot} ->
        with {:ok, spec} <- Artifact.from_map(raw_spec),
             do: Artifact.matches_spec(spec, snapshot) == :ok
      end)
  end

  defp verify_bindings(row, plan, p) do
    valid =
      Enum.all?(p.rounds, fn round ->
        case Store.load_in_transaction(Repo, round.workflow_id) do
          {:ok, workflow} ->
            ((round.index <= p.current_round and workflow.control) &&
               workflow.control.owner_case_id == row.id) and
              AgentSystemsLab.Workflows.Definition.to_map(workflow.definition) ===
                Enum.at(plan.rounds, round.index).definition and
              workflow.control.status ==
                if(round.index == p.current_round and p.status == :running,
                  do: :running,
                  else: :paused
                ) and
              workflow.deadline_at_ms <= row.deadline_at_ms and
              (is_nil(round.proof) or workflow_proof(workflow) == round.proof)

          {:error, :not_found} ->
            round.index > p.current_round and round.status == :pending

          _ ->
            false
        end
      end)

    valid =
      valid and
        (is_nil(p.subject) or
           with {:ok, selected} <- Plan.round(plan, p.current_round) do
             length(selected.artifacts) == length(p.subject.artifacts) and
               Enum.zip(selected.artifacts, p.subject.artifacts)
               |> Enum.all?(fn {spec, snapshot} ->
                 Artifact.matches_spec(spec, snapshot) == :ok
               end)
           else
             _ -> false
           end)

    if valid, do: :ok, else: {:error, :workflow_or_artifact_binding_mismatch}
  end

  defp replay(row, plan, final) do
    events = Repo.all(from(e in ApprovalEvent, where: e.case_id == ^row.id, order_by: e.seq))

    result =
      Enum.reduce_while(events, {:ok, nil, []}, fn e, {:ok, previous, acc} ->
        with true <- e.schema_version == 1 || {:error, :unsupported_event_schema_version},
             true <- e.seq == length(acc) + 1 || {:error, :event_sequence_gap},
             {:ok, %{previous_sha256: hash, projection: p, request: request}} <-
               Codec.decode(e.data, e.codec_version),
             true <-
               hash == if(previous, do: Context.hash(previous)) || {:error, :event_chain_mismatch},
             :ok <- validate_projection(%{row | status: to_string(p.status)}, plan, p),
             :ok <- history_transition(previous, p, e.type, request, e.seq, plan) do
          {:cont, {:ok, p, acc ++ [%{seq: e.seq, type: e.type, data: p, request: request}]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :invalid_event}}
        end
      end)

    case result do
      {:ok, ^final, events} when length(events) == row.seq -> {:ok, events}
      {:ok, _, _} -> {:error, :event_projection_mismatch}
      error -> error
    end
  end

  defp history_transition(nil, p, "created", nil, 1, _plan) do
    if p.status == :running and p.current_round == 0 and p.generation == 0 and
         p.decisions == [] and p.requests == %{} and is_nil(p.subject) and is_nil(p.approval) and
         Enum.all?(p.rounds, fn r ->
           is_nil(r.proof) and
             r.status == if(r.index == 0, do: :running, else: :pending)
         end),
       do: :ok,
       else: {:error, :invalid_initial_projection}
  end

  defp history_transition(old, p, type, request, seq, plan) when is_map(old) do
    fixed =
      old.deadline_at_ms == p.deadline_at_ms and old.status not in @closed and
        Enum.take(p.decisions, length(old.decisions)) == old.decisions and
        Enum.all?(old.requests, fn {id, entry} -> p.requests[id] === entry end) and
        Enum.all?(Enum.take(old.rounds, old.current_round), fn r ->
          Enum.at(p.rounds, r.index) === r
        end)

    system = type in ["awaiting_review", "advanced", "approval_invalidated", "failed"]

    valid =
      if system do
        is_nil(request) and p.requests == old.requests and p.decisions == old.decisions and
          p.current_round == old.current_round and system_transition(old, p, type)
      else
        action =
          case type do
            "pause" -> :pause
            "resume" -> :resume
            "cancel" -> :cancel
            "released" -> :release
            t when t in ["approved", "rejected", "rework_started"] -> :decision
            _ -> nil
          end

        expected_hash = if old.subject, do: old.subject.subject_hash

        is_map(request) and action != nil and
          request_shape(request, if(action == :decision, do: :decision, else: :control)) == :ok and
          request.actor in plan.approvers and request.expected_seq == seq - 1 and
          request.subject_hash == expected_hash and
          not Map.has_key?(old.requests, request.request_id) and
          p.requests ==
            Map.put(old.requests, request.request_id, %{request: request, action: action}) and
          human_transition(old, p, type, request, seq)
      end

    if fixed and valid, do: :ok, else: {:error, :invalid_event_transition}
  end

  defp history_transition(_, _, _, _, _, _), do: {:error, :invalid_event_transition}

  defp system_transition(old, p, "awaiting_review"),
    do:
      old.status == :running and p.status == :awaiting_review and
        p.generation == old.generation + 1 and is_nil(p.approval) and
        Enum.at(p.rounds, p.current_round).status == :succeeded

  defp system_transition(old, p, "failed"),
    do: p.status == :failed and p.generation == old.generation and is_nil(p.approval)

  defp system_transition(old, p, type) when type in ["advanced", "approval_invalidated"] do
    cond do
      p.status == :awaiting_review and old.status in [:awaiting_review, :approved, :paused] ->
        p.generation == old.generation + 1 and is_nil(p.approval) and p.rounds === old.rounds

      p.status == :running and old.status == :running ->
        p.generation == old.generation and p.rounds === old.rounds and p.subject === old.subject

      true ->
        false
    end
  end

  defp human_transition(old, p, "pause", _r, _seq),
    do:
      old.status not in (@closed ++ [:paused]) and p.status == :paused and
        p.resume_status == old.status and p.generation == old.generation and
        p.rounds === old.rounds and p.subject === old.subject and p.approval === old.approval

  defp human_transition(old, p, "resume", _r, _seq),
    do:
      old.status == :paused and p.status == old.resume_status and is_nil(p.resume_status) and
        p.generation == old.generation and p.rounds === old.rounds and
        p.subject === old.subject and p.approval === old.approval

  defp human_transition(old, p, "cancel", _r, _seq),
    do:
      old.status not in @closed and p.status == :cancelled and is_nil(p.approval) and
        p.generation == old.generation and p.rounds === old.rounds and p.subject === old.subject

  defp human_transition(old, p, "released", _r, _seq),
    do:
      old.status == :approved and p.status == :approved and p.approval === old.approval and
        p.subject === old.subject and p.generation == old.generation and p.rounds === old.rounds and
        p.decisions === old.decisions

  defp human_transition(old, p, type, r, seq)
       when type in ["approved", "rejected", "rework_started"] do
    decision =
      Map.take(r, [:actor, :reason, :request_id, :subject_hash, :action])
      |> Map.merge(%{generation: old.generation, seq: seq})

    common = old.status == :awaiting_review and p.decisions == old.decisions ++ [decision]

    common and
      case type do
        "approved" ->
          r.action == :approve and p.status == :approved and p.approval == decision and
            p.subject === old.subject and p.generation == old.generation and
            p.rounds === old.rounds

        "rejected" ->
          r.action == :reject and p.status == :rejected and is_nil(p.approval) and
            p.subject === old.subject and p.generation == old.generation and
            p.rounds === old.rounds

        "rework_started" ->
          r.action == :rework and p.status == :running and is_nil(p.approval) and
            is_nil(p.subject) and p.current_round == old.current_round + 1 and
            p.generation == old.generation + 1 and
            Enum.at(p.rounds, p.current_round).status == :running and
            Enum.take(p.rounds, p.current_round) === Enum.take(old.rounds, p.current_round)
      end
  end

  defp human_transition(_, _, _, _, _), do: false

  defp event_for(old, %{status: :awaiting_review}) when old.status == :approved,
    do: "approval_invalidated"

  defp event_for(old, %{status: :awaiting_review}) when old.status == :running,
    do: "awaiting_review"

  defp event_for(_, %{status: :failed}), do: "failed"
  defp event_for(_, _), do: "advanced"
  defp result_view({:invalidated, _, view}), do: view
  defp result_view(view), do: view

  defp action_result({:invalidated, reason, view}),
    do: {:error, {:approval_invalidated, reason, view}}

  defp action_result(view), do: {:ok, view}
  defp projection(view), do: Map.take(view, @projection_keys)

  defp lock!(id),
    do:
      Repo.one(from(c in ApprovalCase, where: c.id == ^id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

  defp decode!(row), do: unwrap(decode(row))
  defp encode!(value), do: unwrap(Codec.encode(value))
  defp unwrap(:ok), do: :ok
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp hash?(value),
    do: is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp valid_id(id), do: if(text?(id, 128), do: :ok, else: {:error, :invalid_approval_case_id})

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)

  defp options(opts),
    do:
      if(
        is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:hook] == [] and
          length(opts) <= 1 and (is_nil(opts[:hook]) or is_function(opts[:hook], 1)),
        do: :ok,
        else: {:error, :invalid_approval_options}
      )

  defp transaction(opts, fun) do
    case Repo.transaction(fn ->
           result = fun.()
           hook(opts, :before_commit)
           result
         end) do
      {:ok, result} ->
        observe_committed(result)
        hook(opts, :after_commit)
        {:ok, result}

      error ->
        error
    end
  end

  defp observe_committed({:invalidated, _reason, view}), do: observe_committed(view)
  defp observe_committed({:released, view}), do: observe_committed(view)

  defp observe_committed(view) do
    refs = %{case_id: view.id, workflow_id: view.workflow_id, seq: view.seq}

    measurements = %{
      sequence: view.seq,
      approval_generation: view.generation,
      round_index: view.current_round
    }

    AgentSystemsLab.Observability.emit(:approval_committed, refs, measurements,
      phase: :committed,
      status: view.status
    )

    last_event = List.last(view.events)

    name =
      case last_event && last_event.type do
        "created" -> :case_created
        "review_ready" -> :approval_requested
        "awaiting_review" -> :approval_requested
        "approved" -> :approval_decided
        "rejected" -> :approval_decided
        "approval_invalidated" -> :approval_invalidated
        "rework_started" -> :rework_started
        "pause" -> :case_paused
        "resume" -> :case_resumed
        _ -> :case_changed
      end

    AgentSystemsLab.Observability.emit(name, refs, measurements,
      phase: :committed,
      status: view.status
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp hook(opts, stage), do: if(opts[:hook], do: opts[:hook].(stage), else: :ok)
end
