defmodule AgentSystemsLab.RetryStore do
  @moduledoc """
  Claim-fenced pre-effect retry reservations and durable PostgreSQL due times.

  Each delivery is committed before its effect. A repeated reservation with the
  same token fails; a successor token accounts for the abandoned delivery before
  eligibility is reconsidered. Model abandonment can retry after backoff. Tool
  abandonment remains unknown and requires reconciliation. No function sleeps,
  calls providers or executes tools. Old intent rows are historical audit data;
  the Run's current sequence remains the continuation authority.
  """
  import Ecto.Query

  alias AgentSystemsLab.{
    Context,
    ErrorPolicy,
    IntentStore,
    Observability,
    RecoveryStore,
    Repo,
    RetryPolicy,
    Storage
  }

  alias AgentSystemsLab.Storage.{Codec, Intent, Run}
  alias AgentSystemsLab.Storage.Retry, as: Row
  alias AgentSystemsLab.Storage.Recovery, as: RecoveryRow

  @scopes [:model, :tool, :reconcile]
  @state_keys ~w(schema_version attempts status next_attempt_at_ms first_attempt_at_ms last_failure claim_token attempt_started_at_ms exhaustion_reason deliveries)a
  @delivery_keys ~w(attempt claim_token started_at_ms finished_at_ms outcome failure)a
  @statuses [:inflight, :waiting, :exhausted, :succeeded, :closed]

  def reserve(claim, policy, scope, opts \\ []) do
    with :ok <- RetryPolicy.validate(policy), :ok <- valid_scope(scope) do
      with_claim(
        claim,
        opts,
        fn snapshot ->
          with :ok <- scope_matches(scope, snapshot.state.status),
               {:ok, deadline} <- deadline(claim.run_id, scope),
               now = RecoveryStore.now_ms(),
               true <-
                 (is_nil(deadline) or now < deadline) ||
                   {:error, {:budget_exceeded, :run_timeout}},
               {:ok, row, state} <- get_or_create(claim, policy, scope, now) do
            reserve_existing(row, state, claim, policy, scope, now, deadline)
          end
        end,
        :retry_reserved,
        scope
      )
    end
  end

  def schedule(claim, policy, scope, classification, opts \\ []) do
    with :ok <- RetryPolicy.validate(policy),
         :ok <- valid_scope(scope),
         :ok <- ErrorPolicy.validate(classification),
         true <- classification.scope === scope || {:error, :retry_scope_mismatch} do
      with_claim(
        claim,
        opts,
        fn _snapshot ->
          with {:ok, row, state} <- fetch(claim.run_id, claim.seq, scope),
               :ok <- same_policy(row, policy),
               :ok <- inflight(state, claim),
               {:ok, deadline} <- deadline(claim.run_id, scope),
               now = RecoveryStore.now_ms(),
               next = scheduled(state, policy, classification, now, deadline),
               {:ok, _row} <- save(row, next) do
            {:ok, view(row, next, policy)}
          end
        end,
        :retry_scheduled,
        scope
      )
    end
  end

  @doc "Marks a live reservation successful; it does not commit a model result or Run event."
  def finish(claim, scope, opts \\ []) do
    with :ok <- valid_scope(scope) do
      with_claim(
        claim,
        opts,
        fn _snapshot ->
          with {:ok, row, state} <- fetch(claim.run_id, claim.seq, scope),
               :ok <- inflight(state, claim),
               now = RecoveryStore.now_ms(),
               next = %{
                 state
                 | status: :succeeded,
                   next_attempt_at_ms: nil,
                   deliveries: finish_delivery(state.deliveries, :succeeded, nil, now)
               },
               {:ok, _} <- save(row, next),
               {:ok, policy} <- Codec.decode(row.policy_data, row.codec_version) do
            {:ok, view(row, next, policy)}
          end
        end,
        :retry_completed,
        scope
      )
    end
  end

  def load(run_id, seq, scope) do
    with :ok <- valid_scope(scope) do
      read(run_id, fn snapshot ->
        with {:ok, row, state} <- fetch(run_id, seq, scope),
             :ok <- validate_source(row, snapshot),
             {:ok, policy} <- Codec.decode(row.policy_data, row.codec_version),
             do: {:ok, view(row, state, policy)}
      end)
    end
  end

  def list(run_id) do
    read(run_id, fn snapshot ->
      Repo.all(
        from(row in Row, where: row.run_id == ^run_id, order_by: [asc: row.seq, asc: row.scope])
      )
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        with :ok <- validate_source(row, snapshot), {:ok, state, policy} <- decode(row) do
          {:cont, {:ok, acc ++ [view(row, state, policy)]}}
        else
          error -> {:halt, error}
        end
      end)
    end)
  end

  @doc false
  def dispatch_eligibility_in_transaction(repo, snapshot, retry_config) do
    with true <- repo.in_transaction?() || {:error, :transaction_required} do
      scope = if snapshot.state.status == :running, do: :model, else: :tool

      case repo.all(
             from(row in Row,
               where: row.run_id == ^snapshot.state.run_id and row.seq == ^snapshot.state.seq
             )
           ) do
        [] ->
          {:ok, :ready}

        [row] when not is_nil(retry_config) ->
          with :ok <- validate_source(row, snapshot),
               true <- row.scope === Atom.to_string(scope) || {:error, :retry_scope_mismatch},
               {:ok, state, policy} <- decode(row),
               true <- policy === retry_config.policy || {:error, :retry_policy_mismatch} do
            cond do
              state.status == :waiting and RecoveryStore.now_ms(repo) < state.next_attempt_at_ms ->
                {:ok, {:waiting, state.next_attempt_at_ms}}

              state.status in [:closed, :succeeded] ->
                {:error, :retry_dispatch_state_mismatch}

              true ->
                {:ok, :ready}
            end
          end

        _rows ->
          {:error, :retry_dispatch_history_mismatch}
      end
    end
  end

  @doc false
  def complete_transition_in_transaction(repo, current, next) do
    if repo.in_transaction?() do
      repo.all(from(row in Row, where: row.run_id == ^current.run_id and row.seq == ^current.seq))
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        with {:ok, state, _policy} <- decode(row),
             status =
               if(next.status in [:failed, :cancelled, :blocked], do: :closed, else: :succeeded),
             now = RecoveryStore.now_ms(repo),
             updated = %{
               state
               | status: status,
                 next_attempt_at_ms: nil,
                 exhaustion_reason: if(status == :closed, do: state.exhaustion_reason, else: nil),
                 deliveries: finish_delivery(state.deliveries, status, state.last_failure, now)
             },
             {:ok, data} <- Codec.encode(updated),
             {:ok, _} <- repo.update(Row.changeset(row, %{state_data: data})),
             :ok <- project_availability(repo, row, updated) do
          {:cont, {:ok, acc ++ [row.id]}}
        else
          error -> {:halt, error}
        end
      end)
    else
      {:error, :transaction_required}
    end
  end

  defp reserve_existing(
         row,
         %{new_reservation: true} = state,
         _claim,
         policy,
         _scope,
         _now,
         _deadline
       ),
       do: {:ok, view(row, Map.delete(state, :new_reservation), policy)}

  defp reserve_existing(row, state, claim, policy, scope, now, deadline) do
    case state.status do
      :inflight when state.claim_token === claim.token ->
        {:error, :retry_attempt_inflight}

      :inflight ->
        failure =
          ErrorPolicy.classify({:abandoned_attempt, scope},
            scope: scope,
            idempotent?: scope in [:model, :reconcile],
            effect: if(scope in [:model, :reconcile], do: :none, else: :possible)
          )

        next = scheduled(state, policy, failure, now, deadline)

        with {:ok, _} <- save(row, next) do
          {:commit_error, waiting_error(next)}
        end

      :waiting ->
        cond do
          now >= state.first_attempt_at_ms + policy.max_elapsed_ms ->
            exhaust(row, state, :elapsed)

          now < state.next_attempt_at_ms ->
            {:error, {:retry_not_due, state.next_attempt_at_ms}}

          true ->
            start_delivery(row, state, claim, policy, now)
        end

      :exhausted ->
        {:error, {:retry_exhausted, state.last_failure}}

      :succeeded ->
        {:error, :retry_already_succeeded}

      :closed ->
        {:error, :retry_closed}
    end
  end

  defp get_or_create(claim, policy, scope, now) do
    case Repo.one(
           from(row in Row,
             where:
               row.run_id == ^claim.run_id and row.seq == ^claim.seq and
                 row.scope == ^Atom.to_string(scope)
           )
         ) do
      nil ->
        delivery = delivery(1, claim.token, now)

        state = %{
          schema_version: 1,
          attempts: 1,
          status: :inflight,
          next_attempt_at_ms: nil,
          first_attempt_at_ms: now,
          last_failure: nil,
          claim_token: claim.token,
          attempt_started_at_ms: now,
          exhaustion_reason: nil,
          deliveries: [delivery]
        }

        with {:ok, policy_data} <- Codec.encode(policy),
             {:ok, state_data} <- Codec.encode(state),
             {:ok, row} <-
               Repo.insert(
                 Row.changeset(%Row{}, %{
                   run_id: claim.run_id,
                   seq: claim.seq,
                   scope: Atom.to_string(scope),
                   policy_data: policy_data,
                   policy_sha256: Context.hash(policy),
                   state_data: state_data
                 })
               ),
             :ok <- project_availability(Repo, row, state) do
          # A newly committed first delivery is returned directly, rather than
          # interpreted as a duplicate reservation by reserve_existing/7.
          {:ok, row, Map.put(state, :new_reservation, true)}
        end

      row ->
        with :ok <- same_policy(row, policy),
             {:ok, state, _} <- decode(row),
             do: {:ok, row, state}
    end
  end

  defp start_delivery(row, state, claim, policy, now) do
    number = state.attempts + 1

    next = %{
      state
      | status: :inflight,
        attempts: number,
        next_attempt_at_ms: nil,
        claim_token: claim.token,
        attempt_started_at_ms: now,
        exhaustion_reason: nil,
        last_failure: nil,
        deliveries: state.deliveries ++ [delivery(number, claim.token, now)]
    }

    with {:ok, _} <- save(row, next), do: {:ok, view(row, next, policy)}
  end

  defp scheduled(state, policy, failure, now, deadline) do
    eligibility =
      if failure.retryable,
        do: RetryPolicy.next(policy, state.attempts, state.first_attempt_at_ms, now, deadline),
        else: {:exhausted, if(failure.class == :unknown, do: :ambiguous, else: :permanent)}

    {status, due, exhaustion} =
      case eligibility do
        {:retry, due} -> {:waiting, due, nil}
        {:exhausted, reason} -> {:exhausted, nil, reason}
      end

    %{
      state
      | status: status,
        next_attempt_at_ms: due,
        last_failure: failure,
        exhaustion_reason: exhaustion,
        deliveries: finish_delivery(state.deliveries, status, failure, now)
    }
  end

  defp exhaust(row, state, reason) do
    next = %{state | status: :exhausted, next_attempt_at_ms: nil, exhaustion_reason: reason}
    with {:ok, _} <- save(row, next), do: {:commit_error, waiting_error(next)}
  end

  defp waiting_error(%{status: :waiting} = s), do: {:retry_not_due, s.next_attempt_at_ms}
  defp waiting_error(s), do: {:retry_exhausted, s.last_failure}

  defp delivery(n, token, now),
    do: %{
      attempt: n,
      claim_token: token,
      started_at_ms: now,
      finished_at_ms: nil,
      outcome: :inflight,
      failure: nil
    }

  defp finish_delivery(deliveries, outcome, failure, now),
    do:
      List.update_at(
        deliveries,
        -1,
        &%{&1 | finished_at_ms: now, outcome: outcome, failure: failure}
      )

  defp inflight(state, claim) do
    cond do
      state.status != :inflight -> {:error, :retry_attempt_not_inflight}
      state.claim_token !== claim.token -> {:error, :stale_retry_attempt}
      true -> :ok
    end
  end

  defp fetch(id, seq, scope) do
    case Repo.one(
           from(row in Row,
             where: row.run_id == ^id and row.seq == ^seq and row.scope == ^Atom.to_string(scope)
           )
         ) do
      nil -> {:error, :retry_not_found}
      row -> with {:ok, state, _} <- decode(row), do: {:ok, row, state}
    end
  end

  defp same_policy(row, policy) do
    with {:ok, _state, stored} <- decode(row),
         true <- stored === policy || {:error, :retry_policy_mismatch},
         do: :ok
  end

  defp decode(row) do
    Storage.preload_vocabulary()
    Code.ensure_loaded!(ErrorPolicy)
    Code.ensure_loaded!(RetryPolicy)

    with true <-
           row.schema_version === 1 ||
             {:error, {:unsupported_retry_schema_version, row.schema_version}},
         true <-
           row.scope in Enum.map(@scopes, &Atom.to_string/1) || {:error, :invalid_retry_scope},
         {:ok, policy} <- Codec.decode(row.policy_data, row.codec_version),
         :ok <- RetryPolicy.validate(policy),
         true <-
           row.policy_sha256 === Context.hash(policy) || {:error, :retry_policy_hash_mismatch},
         {:ok, state} <- Codec.decode(row.state_data, row.codec_version),
         :ok <- validate_state(state, policy, String.to_existing_atom(row.scope)) do
      {:ok, state, policy}
    else
      {:error, reason} -> {:error, {:corrupt_retry, reason}}
      _ -> {:error, {:corrupt_retry, :invalid_retry_payload}}
    end
  end

  defp validate_state(s, policy, scope) when is_map(s) do
    if Enum.sort(Map.keys(s)) === Enum.sort(@state_keys) and s.schema_version === 1 and
         is_integer(s.attempts) and s.attempts in 1..policy.max_attempts and
         s.status in @statuses and positive?(s.first_attempt_at_ms) and
         positive?(s.attempt_started_at_ms) and s.attempt_started_at_ms >= s.first_attempt_at_ms and
         uuid?(s.claim_token) and is_list(s.deliveries) and length(s.deliveries) == s.attempts and
         valid_failure?(s.last_failure, scope) and
         s.exhaustion_reason in [nil, :attempts, :elapsed, :deadline, :permanent, :ambiguous] and
         ((s.status == :waiting and positive?(s.next_attempt_at_ms) and
             s.next_attempt_at_ms > s.attempt_started_at_ms and
             s.attempts < policy.max_attempts and
             not is_nil(s.last_failure) and s.last_failure.retryable and
             is_nil(s.exhaustion_reason)) or
            (s.status != :waiting and is_nil(s.next_attempt_at_ms))) and
         (s.status != :exhausted or not is_nil(s.exhaustion_reason)) and
         valid_deliveries?(s, scope) and valid_due?(s, policy) do
      :ok
    else
      {:error, :invalid_retry_state}
    end
  end

  defp validate_state(_, _, _), do: {:error, :invalid_retry_state}

  defp valid_deliveries?(state, scope) do
    Enum.with_index(state.deliveries, 1)
    |> Enum.all?(fn {d, n} ->
      is_map(d) and Enum.sort(Map.keys(d)) === Enum.sort(@delivery_keys) and d.attempt === n and
        uuid?(d.claim_token) and positive?(d.started_at_ms) and
        d.started_at_ms >= state.first_attempt_at_ms and d.outcome in @statuses and
        valid_failure?(d.failure, scope) and
        ((d.outcome == :inflight and is_nil(d.finished_at_ms) and is_nil(d.failure)) or
           (d.outcome != :inflight and positive?(d.finished_at_ms) and
              d.finished_at_ms >= d.started_at_ms)) and
        (n == state.attempts or
           (d.outcome == :waiting and not is_nil(d.failure) and d.failure.retryable))
    end) and
      hd(state.deliveries).started_at_ms === state.first_attempt_at_ms and
      Enum.chunk_every(state.deliveries, 2, 1, :discard)
      |> Enum.all?(fn [a, b] -> a.finished_at_ms <= b.started_at_ms end) and
      case List.last(state.deliveries) do
        %{claim_token: token, started_at_ms: started, outcome: outcome, failure: failure} ->
          token === state.claim_token and started === state.attempt_started_at_ms and
            (outcome === state.status or (outcome == :waiting and state.status == :exhausted)) and
            failure === state.last_failure

        _ ->
          false
      end
  end

  defp valid_due?(%{status: :waiting} = s, policy) do
    last = List.last(s.deliveries)

    RetryPolicy.next(policy, s.attempts, s.first_attempt_at_ms, last.finished_at_ms) ===
      {:retry, s.next_attempt_at_ms}
  end

  defp valid_due?(_, _), do: true

  defp valid_failure?(nil, _), do: true

  defp valid_failure?(failure, scope),
    do: ErrorPolicy.validate(failure) == :ok and failure.scope === scope

  defp positive?(n), do: is_integer(n) and n > 0
  defp uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) === {:ok, value}

  defp validate_source(row, snapshot) do
    with true <-
           (is_integer(row.seq) and row.seq > 0 and row.seq <= snapshot.state.seq) ||
             {:error, :retry_history_mismatch},
         true <-
           row.scope in Enum.map(@scopes, &Atom.to_string/1) || {:error, :invalid_retry_scope},
         {:ok, state} <-
           AgentSystemsLab.Kernel.rebuild(row.run_id, Enum.take(snapshot.events, row.seq),
             max_turns: snapshot.state.max_turns
           ),
         :ok <- scope_matches(String.to_existing_atom(row.scope), state.status),
         do: :ok
  end

  defp save(row, state) do
    with {:ok, policy} <- Codec.decode(row.policy_data, row.codec_version),
         :ok <- validate_state(state, policy, String.to_existing_atom(row.scope)),
         {:ok, data} <- Codec.encode(state),
         {:ok, updated} <- Repo.update(Row.changeset(row, %{state_data: data})),
         :ok <- project_availability(Repo, row, state),
         do: {:ok, updated}
  end

  defp project_availability(repo, row, state) do
    due =
      if state.status == :waiting,
        do: DateTime.from_unix!(state.next_attempt_at_ms, :millisecond)

    repo.update_all(
      from(intent in Intent,
        where:
          intent.run_id == ^row.run_id and intent.seq == ^row.seq and intent.status == "pending"
      ),
      set: [available_at: due]
    )

    :ok
  end

  defp view(row, state, policy),
    do:
      Map.merge(state, %{
        run_id: row.run_id,
        seq: row.seq,
        scope: String.to_existing_atom(row.scope),
        policy: policy,
        attempt: state.attempts
      })

  defp with_claim(claim, opts, function, observation, scope) do
    with :ok <- boundary(), :ok <- options(opts) do
      transaction(
        opts,
        fn ->
          with %{run_id: id, seq: seq} <- claim,
               true <- is_binary(id) and is_integer(seq) and seq > 0,
               %Run{} <- Repo.one(from(r in Run, where: r.id == ^id, lock: "FOR UPDATE")),
               {:ok, snapshot} <- Storage.load(id),
               {:ok, _intent} <- IntentStore.verify(Repo, id, seq, claim) do
            case function.(snapshot) do
              {:ok, row, state} -> {:ok, {row, state}}
              result -> result
            end
          else
            {:error, _} = error -> error
            _ -> {:error, :invalid_claim}
          end
        end,
        observation,
        Map.put(claim_refs(claim), :scope, scope)
      )
    end
  end

  defp read(id, function) do
    transaction([], fn ->
      with {:ok, snapshot} <- Storage.load(id), do: function.(snapshot)
    end)
  end

  defp deadline(_id, :reconcile), do: {:ok, nil}

  defp deadline(id, _scope) do
    case Repo.get(RecoveryRow, id) do
      nil -> {:ok, nil}
      _ -> with {:ok, saved} <- RecoveryStore.load(id), do: {:ok, saved.progress.deadline_at_ms}
    end
  end

  defp scope_matches(:model, :running), do: :ok
  defp scope_matches(:tool, :waiting_tool), do: :ok
  defp scope_matches(:reconcile, :blocked), do: :ok
  defp scope_matches(_, _), do: {:error, :retry_scope_mismatch}
  defp valid_scope(scope), do: if(scope in @scopes, do: :ok, else: {:error, :invalid_retry_scope})

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:hook] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(opts[:hook]) or is_function(opts[:hook], 1)),
       do: :ok,
       else: {:error, :invalid_retry_options}
  end

  defp options(_), do: {:error, :invalid_retry_options}
  defp hook(opts, stage), do: if(opts[:hook], do: opts[:hook].(stage), else: :ok)

  defp transaction(opts, function, observation \\ nil, refs \\ %{}) do
    case Repo.transaction(fn ->
           case function.() do
             {:ok, value} ->
               hook(opts, :before_commit)
               {:ok, value}

             {:commit_error, reason} ->
               hook(opts, :before_commit)
               {:error, reason}

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, result} ->
        observe_retry(observation, refs, result)
        hook(opts, :after_commit)
        result

      {:error, _} = error ->
        error
    end
  end

  defp claim_refs(claim) when is_map(claim),
    do: Map.take(claim, [:run_id, :seq, :intent_id, :generation])

  defp claim_refs(_), do: %{}

  defp observe_retry(nil, _refs, _result), do: :ok

  defp observe_retry(name, refs, {:ok, view}) do
    name = if view.status == :exhausted, do: :retry_completed, else: name

    Observability.emit(name, Map.put(Map.delete(refs, :scope), :attempt_id, view.attempt), %{},
      phase: :committed,
      status: view.status,
      scope: refs.scope
    )
  end

  defp observe_retry(_name, refs, {:error, {:retry_not_due, _due}}),
    do:
      Observability.emit(:retry_scheduled, Map.delete(refs, :scope), %{},
        phase: :committed,
        status: :waiting,
        scope: refs.scope
      )

  defp observe_retry(_name, refs, {:error, {:retry_exhausted, _}}),
    do:
      Observability.emit(:retry_completed, Map.delete(refs, :scope), %{},
        phase: :committed,
        status: :exhausted,
        scope: refs.scope
      )

  defp observe_retry(_name, _refs, _result), do: :ok
end
