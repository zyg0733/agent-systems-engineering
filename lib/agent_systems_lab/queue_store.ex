defmodule AgentSystemsLab.QueueStore do
  @moduledoc """
  Opt-in durable admission and shared dispatch limits for named queues.

  Admission and claim writers lock Queue, then Run, then Intent. Existing
  transitions, heartbeat and release only need the Run lock. Queue capacity
  includes every nonterminal admitted Run, including blocked reconciliation.
  Configuration is immutable; a terminal Run releases capacity implicitly.
  """
  import Ecto.Query
  alias AgentSystemsLab.{RecoveryStore, Repo, RetryStore, Storage, TaskBudgetStore}
  alias AgentSystemsLab.Storage.{Intent, Queue, Run}

  @terminal ["succeeded", "failed", "cancelled"]
  @config [:capacity, :max_inflight, :aging_ms, :starvation_ms]

  def create(name, opts \\ []) do
    with :ok <- boundary(),
         true <- valid_name?(name) || {:error, :invalid_queue_name},
         {:ok, config} <- config(opts) do
      case Repo.insert(Queue.changeset(%Queue{}, Map.put(config, :name, name))) do
        {:ok, row} -> {:ok, view(row)}
        {:error, _} -> {:error, {:queue_already_exists, name}}
      end
    end
  end

  def stats(name) do
    with :ok <- boundary(), true <- valid_name?(name) || {:error, :invalid_queue_name} do
      read(name, fn queue, now, rows ->
        inspected = Enum.map(rows, &inspect_run(&1, queue, now))
        ready = for {:ready, entry} <- inspected, do: entry
        # Explicit reconciliation also consumes a queue lease, even though the
        # Run remains blocked and is excluded from background runnable work.
        live = live_claim_count(Repo, queue.name)
        waiting = Enum.count(inspected, &match?({:waiting_retry, _}, &1))
        blocked = Enum.count(inspected, &(&1 == :blocked))
        invalid = for {:invalid, entry} <- inspected, do: entry

        {:ok,
         Map.merge(view(queue), %{
           active: length(rows),
           pending: length(rows) - blocked,
           ready: length(ready),
           claimed: live,
           live_leases: live,
           waiting_retry: waiting,
           blocked: blocked,
           invalid: length(invalid),
           invalid_candidates: invalid,
           available_slots: max(0, queue.capacity - length(rows)),
           inflight_slots: max(0, queue.max_inflight - live),
           oldest_ready_wait_ms: Enum.reduce(ready, 0, &max(&1.wait_ms, &2)),
           starved: Enum.count(ready, &(&1.wait_ms >= queue.starvation_ms)),
           observed_at_ms: now
         })}
      end)
    end
  end

  def starvation(name, opts \\ []) do
    with :ok <- boundary(),
         true <- valid_name?(name) || {:error, :invalid_queue_name},
         true <-
           (is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit] == [] and
              length(opts) <= 1 and is_integer(Keyword.get(opts, :limit, 100)) and
              Keyword.get(opts, :limit, 100) in 1..1000) || {:error, :invalid_queue_options} do
      read(name, fn queue, now, rows ->
        entries =
          rows
          |> Enum.map(&inspect_run(&1, queue, now))
          |> Enum.flat_map(fn
            {:ready, entry} -> if entry.wait_ms >= queue.starvation_ms, do: [entry], else: []
            _ -> []
          end)
          |> Enum.sort_by(&{-&1.wait_ms, &1.intent_id})
          |> Enum.take(Keyword.get(opts, :limit, 100))

        {:ok, entries}
      end)
    end
  end

  @doc false
  def admit_in_transaction(_repo, nil), do: {:ok, nil}

  def admit_in_transaction(repo, name) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         true <- valid_name?(name) || {:error, :invalid_queue_name},
         {:ok, queue} <- lock_in_transaction(repo, name),
         active =
           repo.aggregate(
             from(run in Run, where: run.queue_name == ^name and run.status not in ^@terminal),
             :count
           ),
         true <- active < queue.capacity || {:error, :queue_full} do
      {:ok, queue}
    end
  end

  @doc false
  def lock_in_transaction(repo, name) do
    if repo.in_transaction?() do
      case repo.one(from(queue in Queue, where: queue.name == ^name, lock: "FOR UPDATE")) do
        nil -> {:error, :queue_not_found}
        row -> {:ok, row}
      end
    else
      {:error, :transaction_required}
    end
  end

  @doc false
  def lock_for_run_in_transaction(repo, id) do
    case repo.one(from(run in Run, where: run.id == ^id, select: run.queue_name)) do
      nil -> {:ok, nil}
      name -> lock_in_transaction(repo, name)
    end
  end

  @doc false
  def ensure_claim_slot(_repo, nil), do: :ok

  def ensure_claim_slot(repo, queue) do
    live = live_claim_count(repo, queue.name)

    if live < queue.max_inflight, do: :ok, else: {:error, :queue_inflight_full}
  end

  defp live_claim_count(repo, name) do
    repo.aggregate(
      from(intent in Intent,
        join: run in Run,
        on: run.id == intent.run_id,
        where:
          run.queue_name == ^name and run.status not in ^@terminal and
            intent.status == "pending" and not is_nil(intent.claim_token) and
            intent.claim_expires_at > fragment("clock_timestamp() AT TIME ZONE 'UTC'")
      ),
      :count
    )
  end

  @doc false
  def advance_scan(repo, queue, cursor, ceiling) do
    {1, _} =
      repo.update_all(from(row in Queue, where: row.name == ^queue.name),
        set: [scan_cursor: cursor, scan_ceiling: ceiling]
      )

    :ok
  end

  defp read(name, fun) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

      case Repo.get(Queue, name) do
        nil ->
          Repo.rollback(:queue_not_found)

        queue ->
          now = RecoveryStore.now_ms(Repo)

          rows =
            Repo.all(
              from(run in Run,
                where: run.queue_name == ^name and run.status not in ^@terminal,
                order_by: run.id,
                limit: ^queue.capacity
              )
            )

          case fun.(queue, now, rows) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp inspect_run(%Run{status: "blocked"}, _queue, _now), do: :blocked

  defp inspect_run(run, queue, now) do
    with {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
         {:ok, budget} <- TaskBudgetStore.policy_in_transaction(Repo, run.id),
         true <- not is_nil(budget) || {:error, :task_budget_missing},
         {:ok, saved} <- RecoveryStore.dispatch_policy_in_transaction(Repo, snapshot),
         %Intent{} = intent <- snapshot.intent,
         true <- run.status in ["running", "waiting_tool"],
         {:ok, eligibility} <-
           RetryStore.dispatch_eligibility_in_transaction(Repo, snapshot, saved.retry_config) do
      wait = max(0, now - DateTime.to_unix(intent.inserted_at, :millisecond))

      entry = %{
        run_id: run.id,
        intent_id: intent.id,
        seq: run.seq,
        priority: run.priority,
        effective_priority: min(9, run.priority + div(wait, queue.aging_ms)),
        wait_ms: wait
      }

      cond do
        not is_nil(intent.claim_token) and
            DateTime.to_unix(intent.claim_expires_at, :millisecond) > now ->
          {:claimed, entry}

        match?({:waiting, _}, eligibility) ->
          {:waiting_retry, Map.put(entry, :due_at_ms, elem(eligibility, 1))}

        true ->
          {:ready, entry}
      end
    else
      {:error, reason} -> {:invalid, %{run_id: run.id, reason: reason}}
      _ -> {:invalid, %{run_id: run.id, reason: :invalid_dispatch_state}}
    end
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: config_keyword(opts), else: {:error, :invalid_queue_options}
  end

  defp config(_), do: {:error, :invalid_queue_options}

  defp config_keyword(opts) do
    attrs = %{
      capacity: Keyword.get(opts, :capacity),
      max_inflight: Keyword.get(opts, :max_inflight),
      aging_ms: Keyword.get(opts, :aging_ms, 1_000),
      starvation_ms: Keyword.get(opts, :starvation_ms, 10_000)
    }

    if Keyword.keys(opts) -- @config == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and is_integer(attrs.capacity) and
         attrs.capacity in 1..10_000 and is_integer(attrs.max_inflight) and
         attrs.max_inflight in 1..attrs.capacity and is_integer(attrs.aging_ms) and
         attrs.aging_ms in 1..86_400_000 and is_integer(attrs.starvation_ms) and
         attrs.starvation_ms in 1..86_400_000,
       do: {:ok, attrs},
       else: {:error, :invalid_queue_options}
  end

  defp view(row),
    do:
      Map.take(row, [
        :name,
        :capacity,
        :max_inflight,
        :aging_ms,
        :starvation_ms,
        :scan_cursor,
        :scan_ceiling
      ])

  defp valid_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) and
        not String.contains?(name, <<0>>)

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)
end
