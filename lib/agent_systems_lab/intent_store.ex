defmodule AgentSystemsLab.IntentStore do
  @moduledoc """
  Durable leases for scheduling intents, with tokens that fence stale workers.

  All writers lock the Run before its pending intent. Lease deadlines use the
  PostgreSQL clock; expiry grants eligibility to claim, never permission to
  repeat an unknown external effect. A claim is returned only after COMMIT.
  """
  import Ecto.Query

  alias AgentSystemsLab.{
    Observability,
    QueueStore,
    RecoveryStore,
    Repo,
    RetryStore,
    Storage,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Observability.Context, as: TraceContext
  alias AgentSystemsLab.Storage.{Intent, Run}
  alias AgentSystemsLab.Storage.Recovery, as: RecoveryRow

  require Logger

  @claim_keys [:intent_id, :run_id, :seq, :owner, :token, :generation, :expires_at]
  @max_lease_ms 86_400_000

  @doc "Claims the current pending intent if it has no live lease."
  def claim(run_id, owner, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         true <- (valid_text?(run_id) and valid_text?(owner)) || {:error, :invalid_claim_owner} do
      transaction(
        opts,
        fn ->
          with {:ok, queue} <- QueueStore.lock_for_run_in_transaction(Repo, run_id),
               {:ok, run} <- lock_run(Repo, run_id),
               :ok <- task_budget_policy(run),
               {:ok, _policy} <- RecoveryStore.isolation_policy(run_id),
               {:ok, _mcp} <- RecoveryStore.mcp_policy(run_id),
               {:ok, intent} <- pending(Repo, run_id),
               :ok <-
                 AgentSystemsLab.Workflows.Store.gate_in_transaction(Repo, run_id,
                   reconcile: intent.kind == "reconcile"
                 ),
               {:ok, now} <- database_now(Repo),
               :ok <- available(intent, now),
               :ok <- QueueStore.ensure_claim_slot(Repo, queue) do
            attrs = [
              claim_token: Ecto.UUID.generate(),
              claim_owner: owner,
              claim_expires_at: deadline(now, opts),
              claim_generation: intent.claim_generation + 1,
              updated_at: now
            ]

            {1, [updated]} =
              Repo.update_all(from(row in Intent, where: row.id == ^intent.id, select: row),
                set: attrs
              )

            {:ok, to_claim(updated)}
          end
        end,
        :intent_claimed,
        %{run_id: run_id}
      )
    end
  end

  @doc """
  Claims one executable enrolled Run, ordered by priority then oldest intent.

  Locks only its Run with `SKIP LOCKED` before inspecting the intent. Retry due
  times are validated from the authoritative journal under that lock, without
  consuming an attempt or claim generation. The nullable `available_at` field is
  an observation hint: old rows and stale hints cannot grant early execution or
  hide ready work. Blocked/manual reconciliation and unenrolled Runs are left to
  their explicit drivers. Duplicate delivery remains possible after lease loss.
  """
  def claim_next(owner, opts \\ []) do
    with :ok <- boundary(),
         :ok <- next_options(opts),
         true <- valid_text?(owner) || {:error, :invalid_claim_owner} do
      case transaction(
             opts,
             fn ->
               case Keyword.get(opts, :queue) do
                 nil -> next_candidate(owner, opts, [], [])
                 name -> queued_candidate(owner, name, opts)
               end
             end,
             :intent_claimed
           ) do
        {:ok, {claim, []}} ->
          {:ok, claim}

        {:ok, {nil, rejected}} ->
          {:error, {:invalid_dispatch_candidates, Enum.reverse(rejected)}}

        {:ok, {claim, rejected}} ->
          Logger.warning(
            "Dispatch skipped invalid candidates: #{inspect(Enum.reverse(rejected))}"
          )

          {:ok, claim}

        error ->
          error
      end
    end
  end

  # A fixed ID ceiling closes each scan cycle even when producers keep adding
  # new intents. Every call visits one bounded page; rejected/future candidates
  # cannot hold the scan at its head. Aging determines service within that page.
  defp queued_candidate(owner, name, opts) do
    with {:ok, queue} <- QueueStore.lock_in_transaction(Repo, name) do
      case QueueStore.ensure_claim_slot(Repo, queue) do
        {:error, :queue_inflight_full} ->
          {:ok, {nil, []}}

        :ok ->
          {cursor, ceiling} =
            if queue.scan_cursor >= queue.scan_ceiling,
              do: {0, scan_ceiling(name, opts)},
              else: {queue.scan_cursor, queue.scan_ceiling}

          rows = scan_page(name, cursor, ceiling, opts)

          {rows, ceiling} =
            if rows == [] and cursor > 0 do
              reset_ceiling = scan_ceiling(name, opts)
              {scan_page(name, 0, reset_ceiling, opts), reset_ceiling}
            else
              {rows, ceiling}
            end

          next_cursor =
            if rows == [], do: ceiling, else: Enum.max_by(rows, & &1.intent_id).intent_id

          :ok = QueueStore.advance_scan(Repo, queue, next_cursor, ceiling)
          now_ms = RecoveryStore.now_ms(Repo)

          rows
          |> Enum.sort_by(fn row ->
            wait = max(0, now_ms - DateTime.to_unix(row.inserted_at, :millisecond))
            {-min(9, row.run.priority + div(wait, queue.aging_ms)), row.intent_id}
          end)
          |> claim_page(owner, opts, [])
      end
    end
  end

  defp queue_query(name, opts) do
    query =
      from(run in Run,
        join: intent in Intent,
        on: intent.run_id == run.id and intent.seq == run.seq and intent.status == "pending",
        join: recovery in RecoveryRow,
        on: recovery.run_id == run.id,
        where:
          run.queue_name == ^name and run.status in ["running", "waiting_tool"] and
            intent.kind in ["model", "tool"] and
            (is_nil(intent.claim_token) or
               intent.claim_expires_at <= fragment("clock_timestamp() AT TIME ZONE 'UTC'"))
      )

    if Keyword.has_key?(opts, :run_ids),
      do: from([run, _intent, _recovery] in query, where: run.id in ^opts[:run_ids]),
      else: query
  end

  defp scan_ceiling(name, opts),
    do:
      Repo.one(from([_run, intent, _recovery] in queue_query(name, opts), select: max(intent.id))) ||
        0

  defp scan_page(name, cursor, ceiling, opts) do
    Repo.all(
      from([run, intent, _recovery] in queue_query(name, opts),
        where: intent.id > ^cursor and intent.id <= ^ceiling,
        order_by: [asc: intent.id],
        limit: ^Keyword.get(opts, :scan_limit, 32),
        select: %{run: run, intent_id: intent.id, inserted_at: intent.inserted_at},
        lock: fragment("FOR UPDATE OF ? SKIP LOCKED", run)
      )
    )
  end

  defp claim_page([], _owner, _opts, rejected), do: {:ok, {nil, rejected}}

  defp claim_page([%{run: run} | rest], owner, opts, rejected) do
    case candidate(run) do
      {:ok, intent, :ready} ->
        with {:ok, now} <- database_now(Repo),
             :ok <- available(intent, now),
             {:ok, claim} <- write_claim(intent, owner, now, opts) do
          {:ok, {claim, rejected}}
        else
          {:error, :intent_claimed} -> claim_page(rest, owner, opts, rejected)
          error -> error
        end

      {:ok, _intent, {:waiting, _}} ->
        claim_page(rest, owner, opts, rejected)

      {:error, reason} ->
        claim_page(rest, owner, opts, [%{run_id: run.id, reason: reason} | rejected])
    end
  end

  defp next_candidate(owner, opts, seen, rejected) do
    query =
      from(run in Run,
        join: intent in Intent,
        on: intent.run_id == run.id and intent.seq == run.seq and intent.status == "pending",
        join: recovery in RecoveryRow,
        on: recovery.run_id == run.id,
        where:
          is_nil(run.queue_name) and run.status in ["running", "waiting_tool"] and
            intent.kind in ["model", "tool"] and
            (is_nil(intent.claim_token) or
               intent.claim_expires_at <= fragment("clock_timestamp() AT TIME ZONE 'UTC'")),
        where: run.id not in ^seen,
        order_by: [desc: run.priority, asc: intent.id],
        limit: 1,
        select: run,
        lock: fragment("FOR UPDATE OF ? SKIP LOCKED", run)
      )

    query =
      if Keyword.has_key?(opts, :run_ids),
        do: from(run in query, where: run.id in ^opts[:run_ids]),
        else: query

    case Repo.one(query) do
      nil ->
        {:ok, {nil, rejected}}

      run ->
        case candidate(run) do
          {:ok, intent, :ready} ->
            with {:ok, now} <- database_now(Repo),
                 :ok <- available(intent, now),
                 {:ok, claim} <- write_claim(intent, owner, now, opts) do
              {:ok, {claim, rejected}}
            else
              # The JOIN read the intent at the statement snapshot, while only
              # the Run was locked. A contender may have committed a claim
              # before that lock was acquired. Recheck and keep scanning.
              {:error, :intent_claimed} ->
                next_candidate(owner, opts, [run.id | seen], rejected)

              error ->
                error
            end

          {:ok, _intent, {:waiting, _due}} ->
            next_candidate(owner, opts, [run.id | seen], rejected)

          {:error, reason} ->
            next_candidate(owner, opts, [run.id | seen], [
              %{run_id: run.id, reason: reason} | rejected
            ])
        end
    end
  end

  defp candidate(run) do
    with {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
         :ok <- task_budget_policy(run),
         {:ok, saved} <- RecoveryStore.dispatch_policy_in_transaction(Repo, snapshot),
         {:ok, intent} <- pending(Repo, run.id),
         :ok <- AgentSystemsLab.Workflows.Store.gate_in_transaction(Repo, run.id),
         true <-
           ((run.status == "running" and intent.kind == "model") or
              (run.status == "waiting_tool" and intent.kind == "tool")) ||
             {:error, :intent_dispatch_mismatch},
         {:ok, eligibility} <-
           RetryStore.dispatch_eligibility_in_transaction(Repo, snapshot, saved.retry_config) do
      {:ok, intent, eligibility}
    end
  end

  defp task_budget_policy(run) do
    with {:ok, budget} <- TaskBudgetStore.policy_in_transaction(Repo, run.id),
         true <- (is_nil(run.queue_name) or not is_nil(budget)) || {:error, :task_budget_missing},
         do: :ok
  end

  defp write_claim(intent, owner, now, opts) do
    {1, [updated]} =
      Repo.update_all(from(row in Intent, where: row.id == ^intent.id, select: row),
        set: [
          claim_token: Ecto.UUID.generate(),
          claim_owner: owner,
          claim_expires_at: deadline(now, opts),
          claim_generation: intent.claim_generation + 1,
          updated_at: now
        ]
      )

    {:ok, to_claim(updated)}
  end

  @doc "Renews a live claim; expired claims must be claimed with a new token."
  def renew(claim, opts \\ []) do
    with :ok <- boundary(), :ok <- options(opts), :ok <- valid_claim(claim) do
      transaction(
        opts,
        fn ->
          with {:ok, _run} <- lock_run(Repo, claim.run_id),
               {:ok, intent} <- verify(Repo, claim.run_id, claim.seq, claim) do
            hook(opts, :before_renew_write)
            lease_ms = Keyword.get(opts, :lease_ms, 30_000)

            # A paused caller can cross expiry after verify/4 while holding the
            # Run lock. The write itself must reject that expired token, and its
            # new deadline must be computed at the write rather than before a pause.
            query =
              from(row in Intent,
                where:
                  row.id == ^intent.id and
                    row.claim_expires_at > fragment("clock_timestamp() AT TIME ZONE 'UTC'"),
                update: [
                  set: [
                    claim_expires_at:
                      fragment(
                        "(clock_timestamp() AT TIME ZONE 'UTC') + (? * interval '1 millisecond')",
                        ^lease_ms
                      ),
                    updated_at: fragment("clock_timestamp() AT TIME ZONE 'UTC'")
                  ]
                ],
                select: row
              )

            case Repo.update_all(query, []) do
              {1, [updated]} -> {:ok, to_claim(updated)}
              {0, []} -> {:error, :claim_expired}
            end
          end
        end,
        :lease_renewed,
        claim
      )
    end
  end

  @doc "Releases a live claim, preserving the pending scheduling decision."
  def release(claim) do
    with :ok <- boundary(), :ok <- valid_claim(claim) do
      case transaction(
             [],
             fn ->
               with {:ok, _run} <- lock_run(Repo, claim.run_id),
                    {:ok, intent} <- verify(Repo, claim.run_id, claim.seq, claim),
                    {:ok, now} <- database_now(Repo) do
                 {1, _} =
                   Repo.update_all(from(row in Intent, where: row.id == ^intent.id),
                     set: [
                       claim_token: nil,
                       claim_owner: nil,
                       claim_expires_at: nil,
                       updated_at: now
                     ]
                   )

                 {:ok, :released}
               end
             end,
             :intent_released,
             claim
           ) do
        {:ok, :released} -> :ok
        error -> error
      end
    end
  end

  @doc "Checks a claim under the caller's Run lock and transaction."
  def verify(repo, run_id, seq, claim) do
    with :ok <- valid_claim(claim),
         true <- repo.in_transaction?() || {:error, :transaction_required},
         true <- (claim.run_id === run_id and claim.seq === seq) || {:error, :stale_claim},
         {:ok, intent} <- pending(repo, run_id),
         :ok <-
           AgentSystemsLab.Workflows.Store.gate_in_transaction(repo, run_id,
             reconcile: intent.kind == "reconcile"
           ),
         true <- same_claim?(intent, claim) || {:error, :stale_claim},
         {:ok, now} <- database_now(repo),
         true <- DateTime.compare(intent.claim_expires_at, now) == :gt || {:error, :claim_expired} do
      {:ok, intent}
    else
      {:error, :no_pending_intent} -> {:error, :stale_claim}
      error -> error
    end
  end

  @doc false
  def ensure_unclaimed(_repo, nil), do: :ok

  def ensure_unclaimed(repo, %Intent{} = intent) do
    with {:ok, now} <- database_now(repo), do: available(intent, now)
  end

  defp transaction(opts, function, observation, source \\ %{}) do
    case Repo.transaction(fn ->
           case function.() do
             {:ok, result} ->
               hook(opts, :before_commit)
               result

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, result} ->
        observe_claim(observation, result, source)
        hook(opts, :after_commit)
        {:ok, result}

      {:error, reason} = error ->
        if reason in [:stale_claim, :claim_expired, :invalid_claim, :intent_claimed] do
          Observability.emit(:lease_rejected, claim_refs(source), %{},
            phase: :observed,
            reason: rejection_reason(reason)
          )
        end

        error
    end
  end

  defp observe_claim(name, {claim, _rejected}, source), do: observe_claim(name, claim, source)
  defp observe_claim(_name, nil, _source), do: :ok

  defp observe_claim(name, claim, _source) when is_map(claim),
    do: Observability.emit(name, claim_refs(claim), %{}, phase: :committed)

  defp observe_claim(name, :released, source),
    do: Observability.emit(name, claim_refs(source), %{}, phase: :committed)

  defp claim_refs(claim) do
    refs = Map.take(claim, [:run_id, :seq, :intent_id, :generation])

    Map.merge(refs, %{
      span_id:
        TraceContext.span_id(:intent, {refs[:run_id], refs[:intent_id], refs[:generation]}),
      parent_span_id: TraceContext.span_id(:run, refs[:run_id])
    })
  end

  defp rejection_reason(:stale_claim), do: :stale
  defp rejection_reason(:claim_expired), do: :expired
  defp rejection_reason(:intent_claimed), do: :claimed
  defp rejection_reason(_), do: :invalid

  defp lock_run(repo, run_id) do
    case repo.one(from(row in Run, where: row.id == ^run_id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp pending(repo, run_id) do
    case repo.one(
           from(row in Intent,
             where: row.run_id == ^run_id and row.status == "pending",
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :no_pending_intent}
      intent -> {:ok, intent}
    end
  end

  defp database_now(repo) do
    %{rows: [[now]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT clock_timestamp() AT TIME ZONE 'UTC'", [])

    {:ok, DateTime.from_naive!(now, "Etc/UTC")}
  end

  defp available(%Intent{claim_token: nil}, _now), do: :ok

  defp available(intent, now) do
    if DateTime.compare(intent.claim_expires_at, now) == :gt,
      do: {:error, :intent_claimed},
      else: :ok
  end

  defp same_claim?(intent, claim) do
    intent.id === claim.intent_id and intent.seq === claim.seq and
      intent.claim_token === claim.token and intent.claim_owner === claim.owner and
      intent.claim_generation === claim.generation
  end

  defp to_claim(intent) do
    %{
      intent_id: intent.id,
      run_id: intent.run_id,
      seq: intent.seq,
      owner: intent.claim_owner,
      token: intent.claim_token,
      generation: intent.claim_generation,
      expires_at: intent.claim_expires_at
    }
  end

  defp valid_claim(claim) when is_map(claim) do
    if Enum.sort(Map.keys(claim)) == Enum.sort(@claim_keys) and
         is_integer(claim.intent_id) and claim.intent_id > 0 and valid_text?(claim.run_id) and
         is_integer(claim.seq) and claim.seq > 0 and valid_text?(claim.owner) and
         Ecto.UUID.cast(claim.token) == {:ok, claim.token} and
         is_integer(claim.generation) and claim.generation > 0 and
         match?(%DateTime{time_zone: "Etc/UTC"}, claim.expires_at),
       do: :ok,
       else: {:error, :invalid_claim}
  end

  defp valid_claim(_claim), do: {:error, :invalid_claim}

  defp valid_text?(value),
    do:
      is_binary(value) and byte_size(value) > 0 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp deadline(now, opts),
    do: DateTime.add(now, Keyword.get(opts, :lease_ms, 30_000), :millisecond)

  defp boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:lease_ms, :hook])) and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(Keyword.get(opts, :lease_ms, 30_000)) and
         Keyword.get(opts, :lease_ms, 30_000) in 1..@max_lease_ms and
         (is_nil(Keyword.get(opts, :hook)) or is_function(Keyword.get(opts, :hook), 1)),
       do: :ok,
       else: {:error, :invalid_claim_options}
  end

  defp options(_opts), do: {:error, :invalid_claim_options}

  defp next_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:lease_ms, :hook, :run_ids, :queue, :scan_limit] == [],
         :ok <- options(Keyword.drop(opts, [:run_ids, :queue, :scan_limit])),
         true <- not Keyword.has_key?(opts, :queue) or valid_text?(opts[:queue]),
         true <-
           is_integer(Keyword.get(opts, :scan_limit, 32)) and
             Keyword.get(opts, :scan_limit, 32) in 1..256,
         true <- length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
         true <-
           not Keyword.has_key?(opts, :run_ids) or
             (is_list(opts[:run_ids]) and opts[:run_ids] != [] and
                Enum.all?(opts[:run_ids], &valid_text?/1) and
                length(opts[:run_ids]) == length(Enum.uniq(opts[:run_ids]))) do
      :ok
    else
      _ -> {:error, :invalid_claim_options}
    end
  end

  defp next_options(_), do: {:error, :invalid_claim_options}
  defp hook(opts, stage), do: if(Keyword.get(opts, :hook), do: opts[:hook].(stage), else: :ok)
end
