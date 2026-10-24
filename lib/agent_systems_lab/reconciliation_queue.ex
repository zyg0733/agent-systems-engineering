defmodule AgentSystemsLab.ReconciliationQueue do
  @moduledoc """
  A read-only view of committed unknown outcomes awaiting reconciliation.

  The blocked Run, unknown event and reconcile intent are the queue's source of
  truth. No second enqueue commit can lose an ambiguous outcome. Listing verifies
  each history and local operation audit; it never queries an external target.
  Legacy runs are visible with `recoverable: false` and conservative manual mode.
  """
  import Ecto.Query

  alias AgentSystemsLab.{DurableTools, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Storage.Run
  alias AgentSystemsLab.Storage.Recovery, as: RecoveryRow

  @doc "Lists oldest unknown outcomes first. Optional filters are :run_id and :limit."
  def list(opts \\ []) do
    with :ok <- options(opts) do
      query =
        from run in Run,
          where: run.status == "blocked",
          order_by: [asc: run.updated_at, asc: run.id],
          select: run.id,
          limit: ^Keyword.get(opts, :limit, 100)

      query =
        if id = Keyword.get(opts, :run_id),
          do: from(run in query, where: run.id == ^id),
          else: query

      Repo.all(query)
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, entries} ->
        case entry(id) do
          {:ok, nil} -> {:cont, {:ok, entries}}
          {:ok, item} -> {:cont, {:ok, [item | entries]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  @doc "Returns one verified queue entry, or :not_in_reconciliation_queue."
  def get(run_id) when is_binary(run_id) do
    case entry(run_id) do
      {:ok, nil} -> {:error, :not_in_reconciliation_queue}
      result -> result
    end
  end

  def get(_), do: {:error, :invalid_queue_options}

  defp entry(run_id) do
    Repo.transaction(fn ->
      with {:ok, snapshot} <- Storage.load(run_id) do
        if snapshot.state.status == :blocked do
          case build(snapshot) do
            {:ok, entry} -> entry
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp build(snapshot) do
    operation = Map.fetch!(snapshot.state.operations, snapshot.state.pending_operation_id)

    with {:ok, records} <- DurableTools.list(snapshot.state.run_id),
         {:ok, policy} <- local_policy(snapshot.state.run_id) do
      record = Enum.find(records, &(&1.operation_id == operation.operation_id))
      attempt = if record, do: List.last(record.attempts)
      intent = snapshot.intent

      {:ok,
       %{
         run_id: snapshot.state.run_id,
         seq: snapshot.state.seq,
         status: :blocked,
         intent_id: intent.id,
         operation_id: operation.operation_id,
         tool: operation.tool,
         reason: operation.result,
         safe_mode:
           if(operation.tool == "mock_write" and policy.mock_mode == :idempotent,
             do: :queryable,
             else: :manual
           ),
         journal_status: if(record, do: record.status, else: nil),
         recoverable: policy.recoverable,
         queued_at: intent.inserted_at,
         age_ms: max(DateTime.diff(DateTime.utc_now(), intent.inserted_at, :millisecond), 0),
         latest_attempt:
           if(attempt,
             do: Map.take(attempt, [:id, :kind, :outcome, :inserted_at, :updated_at]),
             else: nil
           )
       }}
    end
  end

  defp local_policy(run_id) do
    # Avoid an expected nested rollback for legacy rows: Ecto marks the enclosing
    # read transaction aborted even if that error is subsequently handled.
    case Repo.get(RecoveryRow, run_id) do
      nil ->
        {:ok, %{recoverable: false, mock_mode: :unqueryable}}

      _row ->
        with {:ok, saved} <- RecoveryStore.load(run_id),
             do: {:ok, %{recoverable: true, mock_mode: saved.config.mock_mode}}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:run_id, :limit] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(Keyword.get(opts, :run_id)) or is_binary(Keyword.get(opts, :run_id))) and
         is_integer(Keyword.get(opts, :limit, 100)) and Keyword.get(opts, :limit, 100) in 1..1000,
       do: :ok,
       else: {:error, :invalid_queue_options}
  end

  defp options(_), do: {:error, :invalid_queue_options}
end
