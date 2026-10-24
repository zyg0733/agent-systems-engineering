defmodule AgentSystemsLab.Workflows.ControlStore do
  @moduledoc """
  Optional durable delivery gate for a Workflow. Pausing fences every existing
  claim while retaining Run identity, operation receipts and charged budgets.
  Approval cases own their gates; public Workflow controls cannot bypass them.
  """
  import Ecto.Query
  alias AgentSystemsLab.{Context, QueueStore, Repo}

  alias AgentSystemsLab.Storage.{
    Codec,
    Intent,
    Run,
    Workflow,
    WorkflowControl,
    WorkflowControlEvent
  }

  def pause(id, reason \\ :user_requested, opts \\ []), do: change(id, :paused, reason, opts)
  def resume(id, opts \\ []), do: change(id, :running, :resumed, opts)

  def load(id) do
    with :ok <- boundary(), :ok <- valid_id(id) do
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
        if is_nil(Repo.get(Workflow, id)), do: Repo.rollback(:not_found)
        unwrap(load_in_transaction(Repo, id))
      end)
    end
  end

  def rebuild(id), do: load(id)

  @doc false
  def load_in_transaction(repo, id) do
    with true <- repo.in_transaction?() || {:error, :transaction_required} do
      workflow = repo.get(Workflow, id)
      row = repo.get(WorkflowControl, id)

      with :ok <- binding(workflow, row) do
        if row, do: decode(repo, row), else: {:ok, nil}
      end
    end
  end

  @doc false
  def create_owned_in_transaction(repo, workflow, owner_case_id) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         :ok <- valid_id(owner_case_id),
         true <-
           workflow.control_owner_case_id == owner_case_id ||
             {:error, :workflow_control_ownership_mismatch},
         nil <- repo.get(WorkflowControl, workflow.id) do
      write(repo, nil, workflow.id, owner_case_id, :running, :created, [])
    else
      %WorkflowControl{} -> {:error, :workflow_control_already_exists}
      {:error, _} = error -> error
    end
  end

  @doc false
  def set_owned_in_transaction(repo, id, owner_case_id, status, reason) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         :ok <- valid_id(owner_case_id),
         true <- status in [:paused, :running] || {:error, :invalid_workflow_control_status},
         {:ok, _} <- Codec.encode(reason) do
      set_in_transaction(repo, id, status, reason, owner_case_id)
    end
  end

  @doc false
  def gate_in_transaction(repo, workflow, opts \\ []) do
    case repo.one(
           from(c in WorkflowControl, where: c.workflow_id == ^workflow.id, lock: "FOR SHARE")
         ) do
      nil ->
        binding(workflow, nil)

      row ->
        with :ok <- binding(workflow, row), {:ok, control} <- decode(repo, row) do
          if control.status == :paused and not Keyword.get(opts, :reconcile, false),
            do: {:error, {:workflow_paused, control.seq}},
            else: :ok
        end
    end
  end

  defp change(id, status, reason, opts) do
    with :ok <- boundary(),
         :ok <- valid_id(id),
         :ok <- options(opts),
         {:ok, _} <- Codec.encode(reason) do
      case Repo.transaction(fn ->
             value = unwrap(set_in_transaction(Repo, id, status, reason, nil))
             hook(opts, :before_commit)
             value
           end) do
        {:ok, value} ->
          observe_committed(id, value)
          hook(opts, :after_commit)
          {:ok, value}

        error ->
          error
      end
    end
  end

  defp observe_committed(id, value) do
    if value do
      AgentSystemsLab.Observability.emit(
        :workflow_control_committed,
        %{workflow_id: id, case_id: value.owner_case_id, seq: value.seq},
        %{sequence: value.seq},
        phase: :committed,
        status: value.status
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Lock the queue before any child Run, then the Workflow and control. This is
  # the existing admission/claim order; no Run is locked while holding Workflow.
  defp set_in_transaction(repo, id, status, reason, owner_case_id) do
    with %Workflow{} = initial <- repo.get(Workflow, id),
         {:ok, _} <- QueueStore.lock_in_transaction(repo, initial.queue_name) do
      runs =
        repo.all(from(r in Run, where: r.workflow_id == ^id, order_by: r.id, lock: "FOR UPDATE"))

      row = repo.one!(from(w in Workflow, where: w.id == ^id, lock: "FOR UPDATE"))

      saved =
        repo.one(from(c in WorkflowControl, where: c.workflow_id == ^id, lock: "FOR UPDATE"))

      with :ok <- binding(row, saved),
           :ok <- authority(saved, owner_case_id),
           {:ok, current} <- if(saved, do: decode(repo, saved), else: {:ok, nil}),
           true <-
             (status != :running or row.status not in ["succeeded", "failed", "cancelled"]) ||
               {:error, :workflow_closed} do
        if (is_nil(current) and status == :running) or (current && current.status == status) do
          {:ok, current}
        else
          revoked = if status == :paused, do: revoke_claims(repo, runs), else: []
          write(repo, saved, id, owner_case_id, status, reason, revoked)
        end
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp authority(nil, nil), do: :ok
  defp authority(%WorkflowControl{owner_case_id: nil}, nil), do: :ok
  defp authority(%WorkflowControl{owner_case_id: owner}, owner) when is_binary(owner), do: :ok

  defp authority(%WorkflowControl{owner_case_id: owner}, nil) when is_binary(owner),
    do: {:error, :approval_case_managed}

  defp authority(_, _), do: {:error, :workflow_control_owner_mismatch}

  defp binding(%Workflow{control_owner_case_id: owner}, %WorkflowControl{owner_case_id: owner}),
    do: :ok

  defp binding(%Workflow{control_owner_case_id: nil}, nil), do: :ok
  defp binding(nil, _), do: {:error, :not_found}
  defp binding(_, _), do: {:error, :workflow_control_ownership_mismatch}

  defp revoke_claims(repo, runs) do
    ids = Enum.map(runs, & &1.id)

    query =
      from(i in Intent,
        where: i.run_id in ^ids and i.status == "pending" and not is_nil(i.claim_token),
        order_by: i.id
      )

    claims = repo.all(query)

    repo.update_all(exclude(query, :order_by),
      set: [
        claim_token: nil,
        claim_owner: nil,
        claim_expires_at: nil,
        updated_at: DateTime.utc_now()
      ]
    )

    Enum.map(claims, &%{intent_id: &1.id, run_id: &1.run_id, generation: &1.claim_generation})
  end

  defp write(repo, saved, id, owner, status, reason, revoked) do
    previous = if saved, do: unwrap(decode(repo, saved)), else: nil
    seq = if saved, do: saved.seq + 1, else: 1

    p = %{
      schema_version: 1,
      workflow_id: id,
      owner_case_id: owner,
      status: status,
      seq: seq,
      reason: reason,
      revoked_claims: revoked
    }

    row = if saved, do: saved, else: %WorkflowControl{}

    attrs = %{
      workflow_id: id,
      owner_case_id: owner,
      status: to_string(status),
      seq: seq,
      data: encode!(p)
    }

    result =
      if saved,
        do: repo.update(WorkflowControl.changeset(row, attrs)),
        else: repo.insert(WorkflowControl.changeset(row, attrs))

    with {:ok, _} <- result,
         {:ok, _} <-
           repo.insert(
             WorkflowControlEvent.changeset(%WorkflowControlEvent{}, %{
               workflow_id: id,
               seq: seq,
               type: if(saved, do: to_string(status), else: "created"),
               data:
                 encode!(%{
                   previous_sha256: if(previous, do: Context.hash(projection(previous))),
                   projection: p
                 })
             })
           ) do
      {:ok,
       Map.put(
         p,
         :events,
         if(previous, do: previous.events, else: []) ++
           [%{seq: seq, type: if(saved, do: to_string(status), else: "created"), data: p}]
       )}
    end
  end

  defp decode(repo, row) do
    with true <- row.schema_version == 1 || {:error, :unsupported_control_schema_version},
         {:ok, p} <- Codec.decode(row.data, row.codec_version),
         :ok <- validate(row, p),
         {:ok, events} <- replay(repo, row, p) do
      {:ok, Map.put(p, :events, events)}
    else
      {:error, reason} -> {:error, {:corrupt_workflow_control, reason}}
    end
  end

  defp replay(repo, row, final) do
    rows =
      repo.all(
        from(e in WorkflowControlEvent, where: e.workflow_id == ^row.workflow_id, order_by: e.seq)
      )

    result =
      Enum.reduce_while(rows, {:ok, nil, []}, fn e, {:ok, previous, acc} ->
        with true <- e.schema_version == 1 || {:error, :unsupported_control_event_schema_version},
             true <- e.seq == length(acc) + 1 || {:error, :control_event_sequence_gap},
             true <-
               if(previous, do: e.type in ["paused", "running"], else: e.type == "created") ||
                 {:error, :invalid_control_event_type},
             {:ok, %{previous_sha256: hash, projection: p}} <-
               Codec.decode(e.data, e.codec_version),
             true <-
               (is_map(p) and Map.get(p, :status) in [:running, :paused]) ||
                 {:error, :invalid_control_event_projection},
             true <-
               hash == if(previous, do: Context.hash(previous)) ||
                 {:error, :control_event_chain_mismatch},
             :ok <- validate(%{row | seq: e.seq, status: to_string(Map.get(p, :status))}, p),
             true <-
               (is_nil(previous) or
                  (previous.status != p.status and previous.owner_case_id == p.owner_case_id)) ||
                 {:error, :invalid_control_transition},
             true <-
               (e.type == "created" or e.type == to_string(p.status)) ||
                 {:error, :control_event_status_mismatch} do
          {:cont, {:ok, p, [%{seq: e.seq, type: e.type, data: p} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :invalid_control_event}}
        end
      end)

    case result do
      {:ok, ^final, events} when length(events) == row.seq -> {:ok, Enum.reverse(events)}
      {:ok, _, _} -> {:error, :control_projection_mismatch}
      error -> error
    end
  end

  defp validate(row, p) do
    valid =
      is_map(p) and
        Enum.sort(Map.keys(p)) ==
          Enum.sort([
            :schema_version,
            :workflow_id,
            :owner_case_id,
            :status,
            :seq,
            :reason,
            :revoked_claims
          ]) and
        p.schema_version == 1 and p.workflow_id == row.workflow_id and
        p.owner_case_id == row.owner_case_id and
        (is_nil(p.owner_case_id) or valid_id(p.owner_case_id) == :ok) and
        p.status in [:running, :paused] and to_string(p.status) == row.status and p.seq == row.seq and
        p.seq > 0 and
        is_list(p.revoked_claims) and
        Enum.all?(p.revoked_claims, fn c ->
          is_map(c) and Enum.sort(Map.keys(c)) == [:generation, :intent_id, :run_id] and
            is_integer(c.generation) and c.generation > 0 and is_integer(c.intent_id) and
            c.intent_id > 0 and is_binary(c.run_id)
        end) and (p.status == :paused or p.revoked_claims == [])

    if valid, do: :ok, else: {:error, :control_projection_mismatch}
  end

  defp projection(view), do: Map.delete(view, :events)
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
  defp encode!(value), do: unwrap(Codec.encode(value))

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)

  defp valid_id(id),
    do:
      if(
        is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
          not String.contains?(id, <<0>>),
        do: :ok,
        else: {:error, :invalid_workflow_id}
      )

  defp options(opts),
    do:
      if(
        is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:hook] == [] and
          length(opts) <= 1 and (is_nil(opts[:hook]) or is_function(opts[:hook], 1)),
        do: :ok,
        else: {:error, :invalid_workflow_control_options}
      )

  defp hook(opts, stage), do: if(opts[:hook], do: opts[:hook].(stage), else: :ok)
end
