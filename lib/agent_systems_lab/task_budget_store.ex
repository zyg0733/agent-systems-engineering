defmodule AgentSystemsLab.TaskBudgetStore do
  @moduledoc """
  Immutable per-task delivery limits and crash-persistent dispatch reservations.

  Each new claim token consumes one dispatch before any host hook or effect.
  The execution deadline and the Run deadline use PostgreSQL wall time. Worker
  timers provide prompt reclamation; transactional checks fence late effects and
  model acceptance. Manual reconciliation does not spend a dispatch.
  """
  import Ecto.Query
  alias AgentSystemsLab.{Context, IntentStore, RecoveryStore, Repo, Storage}
  alias AgentSystemsLab.Storage.{Codec, Run, TaskBudget}

  @config_keys ~w(schema_version max_dispatches execution_timeout_ms)a
  @progress_keys ~w(schema_version dispatches last_claim_token last_seq execution_deadline_at_ms)a

  @doc false
  def insert_in_transaction(repo, state, opts) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, config} <- config(opts),
         {:ok, data} <- Codec.encode(config),
         {:ok, progress} <-
           Codec.encode(%{
             schema_version: 1,
             dispatches: 0,
             last_claim_token: nil,
             last_seq: nil,
             execution_deadline_at_ms: nil
           }) do
      repo.insert(
        TaskBudget.changeset(%TaskBudget{}, %{
          run_id: state.run_id,
          config_data: data,
          config_sha256: Context.hash(config),
          progress_data: progress
        })
      )
    end
  end

  def load(id) do
    Repo.transaction(fn ->
      case Repo.one(from(r in Run, where: r.id == ^id, lock: "FOR SHARE")) do
        nil -> Repo.rollback(:not_found)
        run -> unwrap(decode_for_run(Repo.get(TaskBudget, id), run))
      end
    end)
  end

  @doc false
  def policy_in_transaction(repo, id) do
    if repo.in_transaction?(),
      do: decode_for_run(repo.get(TaskBudget, id), repo.get(Run, id)),
      else: {:error, :transaction_required}
  end

  @doc "Reserves once per claim token; abandoned reservations remain charged."
  def reserve(%{run_id: id, seq: seq} = claim) do
    if Repo.in_transaction?() do
      {:error, :nested_transaction_not_supported}
    else
      Repo.transaction(fn ->
        with %Run{} = run <- Repo.one(from(r in Run, where: r.id == ^id, lock: "FOR UPDATE")),
             {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
             {:ok, _} <- IntentStore.verify(Repo, id, seq, claim),
             {:ok, policy} <- RecoveryStore.dispatch_policy_in_transaction(Repo, snapshot),
             row = Repo.get(TaskBudget, id),
             {:ok, budget} <- decode_for_run(row, run) do
          reserve_row(row, budget, claim, policy.progress.deadline_at_ms)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def reserve(_), do: {:error, :invalid_claim}

  # Read before spawning the executor. Starting the timer a little before the
  # durable reservation is deliberately conservative and bounds blocked hooks.
  @doc false
  def timeout(claim, cap) do
    with {:ok, saved} <- RecoveryStore.load(claim.run_id),
         {:ok, budget} <- load(claim.run_id) do
      per_task = if budget, do: budget.config.execution_timeout_ms, else: cap

      remaining = saved.progress.deadline_at_ms - RecoveryStore.now_ms()
      duration = min(cap, per_task)
      reason = if remaining <= duration, do: :run_timeout, else: :execution_timeout
      {:ok, %{timeout_ms: max(1, min(duration, remaining)), reason: {:budget_exceeded, reason}}}
    end
  end

  @doc false
  def check_deadline(id) do
    with {:ok, budget} <- load(id) do
      deadline_check(budget, Repo)
    end
  end

  @doc false
  def check_deadline_in_transaction(repo, id) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, budget} <- decode_for_run(repo.get(TaskBudget, id), repo.get(Run, id)) do
      deadline_check(budget, repo)
    end
  end

  defp deadline_check(budget, repo) do
    if budget && is_integer(budget.progress.execution_deadline_at_ms) &&
         RecoveryStore.now_ms(repo) >= budget.progress.execution_deadline_at_ms,
       do: {:error, {:budget_exceeded, :execution_timeout}},
       else: :ok
  end

  defp reserve_row(nil, nil, _claim, _deadline), do: nil

  defp reserve_row(row, %{config: c, progress: p}, claim, deadline) do
    cond do
      p.last_claim_token == claim.token ->
        Repo.rollback(:dispatch_already_started)

      p.dispatches >= c.max_dispatches ->
        Repo.rollback({:budget_exceeded, :dispatches})

      true ->
        next = %{
          p
          | dispatches: p.dispatches + 1,
            last_claim_token: claim.token,
            last_seq: claim.seq,
            execution_deadline_at_ms:
              min(deadline, RecoveryStore.now_ms() + c.execution_timeout_ms)
        }

        with {:ok, data} <- Codec.encode(next),
             {:ok, _} <- Repo.update(TaskBudget.changeset(row, %{progress_data: data})),
             do: %{config: c, progress: next},
             else: ({:error, reason} -> Repo.rollback(reason))
    end
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Keyword.keys(opts) -- [:max_dispatches, :execution_timeout_ms] == [] do
      c = %{
        schema_version: 1,
        max_dispatches: Keyword.get(opts, :max_dispatches, 32),
        execution_timeout_ms: Keyword.get(opts, :execution_timeout_ms, 5000)
      }

      with :ok <- validate_config(c), do: {:ok, c}
    else
      {:error, :invalid_task_budget}
    end
  end

  defp config(_), do: {:error, :invalid_task_budget}

  defp validate_config(c) when is_map(c) do
    if Enum.sort(Map.keys(c)) == Enum.sort(@config_keys) and c.schema_version === 1 and
         is_integer(c.max_dispatches) and c.max_dispatches in 1..1_000_000 and
         is_integer(c.execution_timeout_ms) and c.execution_timeout_ms in 1..86_400_000,
       do: :ok,
       else: {:error, :invalid_task_budget}
  end

  defp validate_config(_), do: {:error, :invalid_task_budget}

  defp decode_for_run(nil, %Run{queue_name: name}) when not is_nil(name),
    do: {:error, :task_budget_missing}

  defp decode_for_run(row, run) do
    with {:ok, budget} <- decode(row) do
      if budget && run && is_integer(budget.progress.last_seq) &&
           budget.progress.last_seq > run.seq,
         do: {:error, {:corrupt_task_budget, :future_reservation}},
         else: {:ok, budget}
    end
  end

  defp decode(nil), do: {:ok, nil}

  defp decode(row) do
    with true <- row.schema_version === 1 || {:error, :unsupported_schema_version},
         {:ok, c} <- Codec.decode(row.config_data, row.codec_version),
         :ok <- validate_config(c),
         true <- Context.hash(c) === row.config_sha256 || {:error, :config_hash_mismatch},
         {:ok, p} <- Codec.decode(row.progress_data, row.codec_version),
         :ok <- validate_progress(c, p) do
      {:ok, %{config: c, progress: p}}
    else
      {:error, reason} -> {:error, {:corrupt_task_budget, reason}}
    end
  end

  defp validate_progress(c, p) when is_map(p) do
    if Enum.sort(Map.keys(p)) == Enum.sort(@progress_keys) and p.schema_version === 1 and
         is_integer(p.dispatches) and p.dispatches in 0..c.max_dispatches and
         ((p.dispatches == 0 and is_nil(p.last_claim_token) and is_nil(p.last_seq) and
             is_nil(p.execution_deadline_at_ms)) or
            (p.dispatches > 0 and Ecto.UUID.cast(p.last_claim_token) === {:ok, p.last_claim_token} and
               is_integer(p.last_seq) and p.last_seq > 0 and
               is_integer(p.execution_deadline_at_ms) and p.execution_deadline_at_ms > 0)),
       do: :ok,
       else: {:error, :invalid_progress}
  end

  defp validate_progress(_, _), do: {:error, :invalid_progress}
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
