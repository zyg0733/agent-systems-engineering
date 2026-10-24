defmodule AgentSystemsLab.RecoveryStore do
  @moduledoc """
  Immutable recovery policy and durable cursor, attempts and stream charges.

  Enrollment and accepted cursor advancement share the kernel transaction.
  Output is charged before each provider frame is acknowledged, including output
  from attempts that crash before acceptance. Deadlines use PostgreSQL time and
  never restart when a worker does. This is a local scripted-provider contract.
  """
  import Ecto.Query
  alias AgentSystemsLab.{Budget, Context, IntentStore, Recovery, Repo, Storage}
  alias AgentSystemsLab.Storage.{Codec, ModelResult, Run}
  alias AgentSystemsLab.Storage.Recovery, as: Row
  alias AgentSystemsLab.Isolation.Policy

  @progress_keys ~w(schema_version last_seq cursor output_bytes model_attempts request_events deadline_at_ms request_deadline_at_ms request_token)a

  @doc false
  def insert_in_transaction(repo, state, %{config: config, retry_config: retry} = envelope)
      when map_size(envelope) in [2, 3, 4] do
    if Map.keys(envelope) -- [:config, :retry_config, :isolation_policy, :mcp_policy] == [] do
      with {:ok, retry_attrs} <- retry_attributes(retry),
           {:ok, isolation_attrs} <- isolation_attributes(Map.get(envelope, :isolation_policy)),
           {:ok, mcp_attrs} <- mcp_attributes(Map.get(envelope, :mcp_policy)) do
        insert_config(
          repo,
          state,
          config,
          Map.merge(Map.merge(retry_attrs, isolation_attrs), mcp_attrs)
        )
      end
    else
      {:error, :invalid_recovery_enrollment}
    end
  end

  def insert_in_transaction(repo, state, config) do
    insert_config(repo, state, config, %{})
  end

  defp isolation_attributes(nil), do: {:ok, %{}}

  defp isolation_attributes(policy) do
    with :ok <- Policy.validate(policy),
         policy_map = Policy.to_map(policy),
         {:ok, data} <- Codec.encode(policy_map),
         do:
           {:ok,
            %{isolation_policy_data: data, isolation_policy_sha256: Context.hash(policy_map)}}
  end

  defp mcp_attributes(nil), do: {:ok, %{}}

  defp mcp_attributes(policy) do
    with :ok <- AgentSystemsLab.MCP.Policy.validate(policy),
         policy_map = AgentSystemsLab.MCP.Policy.to_map(policy),
         {:ok, data} <- Codec.encode(policy_map),
         do: {:ok, %{mcp_policy_data: data, mcp_policy_sha256: Context.hash(policy_map)}}
  end

  defp retry_attributes(nil), do: {:ok, %{}}

  defp retry_attributes(retry) do
    with :ok <- Recovery.validate_retry_config(retry),
         {:ok, data} <- Codec.encode(retry) do
      {:ok, %{retry_config_data: data, retry_config_sha256: Context.hash(retry)}}
    end
  end

  defp insert_config(repo, state, config, extra) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         :ok <- Recovery.validate_config(config),
         true <- config.max_turns === state.max_turns || {:error, :recovery_config_mismatch},
         {:ok, config_data} <- Codec.encode(config),
         progress = %{
           schema_version: 1,
           last_seq: state.seq,
           cursor: 0,
           output_bytes: 0,
           model_attempts: 0,
           request_events: 0,
           deadline_at_ms: now_ms(repo) + config.budget.run_timeout_ms,
           request_deadline_at_ms: nil,
           request_token: nil
         },
         {:ok, data} <- Codec.encode(progress) do
      repo.insert(
        Row.changeset(
          %Row{},
          Map.merge(
            %{
              run_id: state.run_id,
              config_data: config_data,
              config_sha256: Context.hash(config),
              progress_data: data
            },
            extra
          )
        )
      )
    end
  end

  @doc false
  def clamp_deadline_in_transaction(_repo, _row, nil), do: :ok

  def clamp_deadline_in_transaction(repo, row, deadline)
      when is_integer(deadline) and deadline > 0 do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, progress} <- Codec.decode(row.progress_data, row.codec_version),
         {:ok, data} <-
           Codec.encode(%{progress | deadline_at_ms: min(progress.deadline_at_ms, deadline)}),
         {:ok, _} <- repo.update(Row.changeset(row, %{progress_data: data})),
         do: :ok
  end

  def clamp_deadline_in_transaction(_, _, _), do: {:error, :invalid_workflow_deadline}

  @doc "Loads policy and progress under the same shared Run lock as its history."
  def load(run_id) do
    Repo.transaction(fn ->
      with {:ok, snapshot} <- Storage.load(run_id),
           {:ok, row} <- fetch(Repo, run_id),
           {:ok, config, progress} <- decode(row, snapshot.state),
           {:ok, retry_config} <- decode_retry(row),
           {:ok, isolation_policy} <- decode_isolation(row),
           {:ok, mcp_policy} <- decode_mcp(row) do
        %{
          config: config,
          progress: progress,
          snapshot: snapshot,
          retry_config: retry_config,
          isolation_policy: isolation_policy,
          mcp_policy: mcp_policy
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def dispatch_policy_in_transaction(repo, snapshot) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, row} <- fetch(repo, snapshot.state.run_id),
         {:ok, config, progress} <- decode(row, snapshot.state),
         {:ok, retry_config} <- decode_retry(row),
         {:ok, isolation_policy} <- decode_isolation(row),
         {:ok, mcp_policy} <- decode_mcp(row) do
      {:ok,
       %{
         config: config,
         progress: progress,
         retry_config: retry_config,
         isolation_policy: isolation_policy,
         mcp_policy: mcp_policy
       }}
    end
  end

  @doc "Reads optional immutable host authority; callers cannot supply a replacement policy."
  def isolation_policy(run_id) do
    case Repo.get(Row, run_id) do
      nil -> {:ok, nil}
      row -> decode_isolation(row)
    end
  end

  @doc "Reads immutable MCP host authority without accepting caller overrides."
  def mcp_policy(run_id) do
    case Repo.get(Row, run_id) do
      nil -> {:ok, nil}
      row -> decode_mcp(row)
    end
  end

  @doc false
  def update_in_transaction(repo, current, next, attrs) do
    if repo.in_transaction?(),
      do: update_progress(repo, current, next, attrs),
      else: {:error, :transaction_required}
  end

  defp update_progress(repo, current, next, attrs) do
    case repo.get(Row, current.run_id) do
      nil when is_nil(attrs) ->
        {:ok, nil}

      nil ->
        {:error, :run_not_resumable}

      row ->
        with {:ok, config, progress} <- decode(row, current),
             :ok <- cursor_update(current, next, progress, attrs),
             :ok <- acceptance_deadline(current, next, progress, repo),
             :ok <- accepted_recording(repo, current, next),
             updated = %{
               progress
               | last_seq: next.seq,
                 cursor: next.turn_count,
                 request_token: nil,
                 request_deadline_at_ms: nil
             },
             :ok <- validate_progress(config, updated, next),
             {:ok, data} <- Codec.encode(updated) do
          repo.update(Row.changeset(row, %{progress_data: data}))
        end
    end
  end

  @doc "Reserves a bounded model attempt before starting the provider."
  def begin_model_attempt(claim, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline_at_ms] == [] and
         length(opts) <= 1 and
         (is_nil(opts[:deadline_at_ms]) or
            (is_integer(opts[:deadline_at_ms]) and opts[:deadline_at_ms] > 0)) do
      begin_model(claim, opts)
    else
      {:error, :invalid_model_attempt_options}
    end
  end

  defp begin_model(claim, opts) do
    with_claim(claim, fn row, config, progress, snapshot ->
      with {:ok, task} <-
             AgentSystemsLab.TaskBudgetStore.policy_in_transaction(Repo, claim.run_id) do
        now = now_ms(Repo)

        task_deadline =
          if task, do: task.progress.execution_deadline_at_ms, else: progress.deadline_at_ms

        cond do
          snapshot.state.status != :running ->
            {:error, :not_model_intent}

          now >= progress.deadline_at_ms ->
            {:error, {:budget_exceeded, :run_timeout}}

          is_integer(opts[:deadline_at_ms]) and now >= opts[:deadline_at_ms] ->
            {:error, {:budget_exceeded, :model_timeout}}

          is_integer(task_deadline) and now >= task_deadline ->
            {:error, {:budget_exceeded, :execution_timeout}}

          progress.model_attempts >= config.max_model_attempts ->
            {:error, {:budget_exceeded, :model_attempts}}

          progress.cursor >= config.max_turns ->
            {:error, :turn_budget_exceeded}

          true ->
            next = %{
              progress
              | model_attempts: progress.model_attempts + 1,
                request_events: 0,
                request_token: Ecto.UUID.generate(),
                request_deadline_at_ms:
                  min(
                    min(progress.deadline_at_ms, task_deadline || progress.deadline_at_ms),
                    min(
                      now + config.budget.model_timeout_ms,
                      Keyword.get(opts, :deadline_at_ms) || progress.deadline_at_ms
                    )
                  )
            }

            with {:ok, _} <- save_progress(row, next) do
              {:ok, %{config: config, progress: next, snapshot: snapshot}}
            end
        end
      end
    end)
  end

  @doc "Charges an accepted frame before ACK; charges survive worker crashes."
  def charge_frame(claim, request_token, event) do
    with_claim(claim, fn row, config, progress, _snapshot ->
      with true <-
             (is_binary(request_token) and progress.request_token === request_token and
                is_integer(progress.request_deadline_at_ms)) || {:error, :stale_model_attempt},
           :ok <- execution_deadline(progress, claim.run_id, Repo),
           budget =
             struct!(
               Budget,
               Map.merge(config.budget, %{
                 output_bytes: progress.output_bytes,
                 events: progress.request_events
               })
             ),
           {:ok, charged} <- Budget.consume(budget, event),
           next = %{progress | output_bytes: charged.output_bytes, request_events: charged.events},
           {:ok, _} <- save_progress(row, next) do
        {:ok, next}
      end
    end)
  end

  @doc "Checks absolute deadlines without changing accounting."
  def check_deadline(run_id) do
    with {:ok, saved} <- load(run_id) do
      if now_ms(Repo) >= saved.progress.deadline_at_ms,
        do: {:error, {:budget_exceeded, :run_timeout}},
        else: :ok
    end
  end

  @doc false
  def check_attempt(claim, request_token) do
    with_claim(claim, fn _row, _config, progress, _snapshot ->
      with true <-
             (is_binary(request_token) and progress.request_token === request_token) ||
               {:error, :stale_model_attempt},
           :ok <- execution_deadline(progress, claim.run_id, Repo),
           do: {:ok, :valid}
    end)
  end

  @doc false
  def check_effect_deadline(repo, run_id) do
    if repo.in_transaction?() do
      case repo.get(Row, run_id) do
        nil ->
          :ok

        row ->
          with {:ok, snapshot} <- Storage.load(run_id),
               {:ok, _config, progress} <- decode(row, snapshot.state),
               {:ok, _isolation} <- decode_isolation(row),
               {:ok, _mcp} <- decode_mcp(row) do
            if now_ms(repo) >= progress.deadline_at_ms,
              do: {:error, {:budget_exceeded, :run_timeout}},
              else: AgentSystemsLab.TaskBudgetStore.check_deadline_in_transaction(repo, run_id)
          end
      end
    else
      {:error, :transaction_required}
    end
  end

  def now_ms(repo \\ Repo) do
    %{rows: [[value]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint",
        []
      )

    value
  end

  defp with_claim(claim, function) do
    if Repo.in_transaction?() do
      {:error, :nested_transaction_not_supported}
    else
      Repo.transaction(fn ->
        with %{run_id: id, seq: seq} <- claim,
             %Run{} <- Repo.one(from(r in Run, where: r.id == ^id, lock: "FOR UPDATE")),
             {:ok, snapshot} <- Storage.load(id),
             {:ok, _intent} <- IntentStore.verify(Repo, id, seq, claim),
             {:ok, row} <- fetch(Repo, id),
             {:ok, config, progress} <- decode(row, snapshot.state),
             {:ok, _isolation} <- decode_isolation(row),
             {:ok, _mcp} <- decode_mcp(row),
             {:ok, result} <- function.(row, config, progress, snapshot) do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:invalid_claim)
        end
      end)
    end
  end

  defp fetch(repo, id) do
    case repo.get(Row, id) do
      nil -> {:error, :run_not_resumable}
      row -> {:ok, row}
    end
  end

  defp decode_mcp(%{mcp_policy_data: nil, mcp_policy_sha256: nil}), do: {:ok, nil}

  defp decode_mcp(row) do
    with {:ok, policy_map} <- Codec.decode(row.mcp_policy_data, row.codec_version),
         true <-
           Context.hash(policy_map) === row.mcp_policy_sha256 ||
             {:error, :mcp_policy_hash_mismatch},
         {:ok, policy} <- AgentSystemsLab.MCP.Policy.from_map(policy_map) do
      {:ok, policy}
    else
      {:error, reason} -> {:error, {:corrupt_recovery, reason}}
    end
  end

  defp decode_isolation(%{isolation_policy_data: nil, isolation_policy_sha256: nil}),
    do: {:ok, nil}

  defp decode_isolation(row) do
    with {:ok, policy_map} <- Codec.decode(row.isolation_policy_data, row.codec_version),
         true <-
           Context.hash(policy_map) === row.isolation_policy_sha256 ||
             {:error, :isolation_policy_hash_mismatch},
         {:ok, policy} <- Policy.from_map(policy_map) do
      {:ok, policy}
    else
      {:error, reason} -> {:error, {:corrupt_recovery, reason}}
    end
  end

  defp decode_retry(%{retry_config_data: nil, retry_config_sha256: nil}), do: {:ok, nil}

  defp decode_retry(row) do
    with {:ok, retry} <- Codec.decode(row.retry_config_data, row.codec_version),
         :ok <- Recovery.validate_retry_config(retry),
         true <-
           Context.hash(retry) === row.retry_config_sha256 ||
             {:error, :retry_config_hash_mismatch} do
      {:ok, retry}
    else
      {:error, reason} -> {:error, {:corrupt_recovery, reason}}
    end
  end

  defp decode(row, state) do
    Storage.preload_vocabulary()

    with true <-
           row.schema_version === 1 ||
             {:error, {:unsupported_recovery_schema_version, row.schema_version}},
         {:ok, config} <- Codec.decode(row.config_data, row.codec_version),
         :ok <- Recovery.validate_config(config),
         true <-
           row.config_sha256 === Context.hash(config) || {:error, :recovery_config_hash_mismatch},
         true <- config.max_turns === state.max_turns || {:error, :recovery_config_mismatch},
         {:ok, progress} <- Codec.decode(row.progress_data, row.codec_version),
         :ok <- validate_progress(config, progress, state) do
      {:ok, config, progress}
    else
      {:error, reason} -> {:error, {:corrupt_recovery, reason}}
    end
  end

  defp validate_progress(config, p, state) when is_map(p) do
    cond do
      Enum.sort(Map.keys(p)) !== Enum.sort(@progress_keys) ->
        {:error, :invalid_recovery_progress}

      p.schema_version !== 1 ->
        {:error, {:unsupported_recovery_progress_version, p.schema_version}}

      p.last_seq !== state.seq or p.cursor !== state.turn_count ->
        {:error, :recovery_progress_mismatch}

      not is_integer(p.model_attempts) or p.model_attempts < p.cursor or
          p.model_attempts > config.max_model_attempts ->
        {:error, :invalid_model_attempt_count}

      not is_integer(p.output_bytes) or p.output_bytes < 0 or
          p.output_bytes > config.budget.max_output_bytes ->
        {:error, :invalid_output_charge}

      not is_integer(p.request_events) or p.request_events < 0 or
          p.request_events > config.budget.max_stream_events ->
        {:error, :invalid_event_charge}

      not is_integer(p.deadline_at_ms) or p.deadline_at_ms <= 0 ->
        {:error, :invalid_recovery_deadline}

      is_nil(p.request_token) and is_nil(p.request_deadline_at_ms) ->
        :ok

      Ecto.UUID.cast(p.request_token) === {:ok, p.request_token} and
        is_integer(p.request_deadline_at_ms) and p.request_deadline_at_ms <= p.deadline_at_ms ->
        :ok

      true ->
        {:error, :invalid_model_attempt}
    end
  end

  defp validate_progress(_config, _p, _state), do: {:error, :invalid_recovery_progress}

  defp cursor_update(current, next, progress, attrs) do
    if next.turn_count == current.turn_count do
      if is_nil(attrs), do: :ok, else: {:error, :invalid_recovery_progress_update}
    else
      if attrs === %{cursor: progress.cursor + 1} and next.turn_count == progress.cursor + 1,
        do: :ok,
        else: {:error, :recovery_progress_required}
    end
  end

  defp acceptance_deadline(current, next, progress, repo) do
    if next.turn_count > current.turn_count do
      if is_binary(progress.request_token),
        do: execution_deadline(progress, next.run_id, repo),
        else: {:error, :model_attempt_required}
    else
      :ok
    end
  end

  defp execution_deadline(progress, run_id, repo) do
    now = now_ms(repo)

    if now >= progress.deadline_at_ms do
      {:error, {:budget_exceeded, :run_timeout}}
    else
      with :ok <- AgentSystemsLab.TaskBudgetStore.check_deadline_in_transaction(repo, run_id),
           do: deadline(progress, now)
    end
  end

  defp accepted_recording(repo, current, next) do
    if next.turn_count > current.turn_count do
      if repo.exists?(
           from(r in ModelResult, where: r.run_id == ^next.run_id and r.event_seq == ^next.seq)
         ), do: :ok, else: {:error, :recovery_model_result_required}
    else
      :ok
    end
  end

  defp save_progress(row, progress) do
    with {:ok, data} <- Codec.encode(progress),
         do: Repo.update(Row.changeset(row, %{progress_data: data}))
  end

  defp deadline(progress, now) do
    cond do
      now >= progress.deadline_at_ms -> {:error, {:budget_exceeded, :run_timeout}}
      now >= progress.request_deadline_at_ms -> {:error, {:budget_exceeded, :model_timeout}}
      true -> :ok
    end
  end
end
