defmodule AgentSystemsLab.Recovery do
  @moduledoc """
  Explicit durable continuation for enrolled, fixed-policy scripted runs.

  `load/1` is read-only. `resume/2` and `step/2` may call the model or tools,
  after claiming the current intent. They reconstruct from committed facts and
  durable accounting; they never reset a cursor, deadline or output budget.
  Legacy RunServer runs require explicit enrollment at creation and cannot be
  guessed into resumable runs. Unknown effects require query or trusted evidence.
  """
  alias AgentSystemsLab.{
    Budget,
    DatabaseError,
    Context,
    ContextStore,
    DurableTools,
    IntentStore,
    ErrorPolicy,
    RetryPolicy,
    RetryStore,
    RecoveryStore,
    Repo,
    Observability,
    Session,
    Storage,
    Stream,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Observability.Context, as: TraceContext
  alias AgentSystemsLab.Providers.Scripted
  alias AgentSystemsLab.Storage.Codec
  import Ecto.Query, only: [from: 2]
  alias AgentSystemsLab.Tools.{Catalog, Files, Gateway, Result, Workspace}

  @terminal [:succeeded, :failed, :cancelled]
  @budget_keys ~w(max_output_bytes max_stream_events model_timeout_ms run_timeout_ms max_tool_calls)a
  @config_keys ~w(schema_version provider script session workspace context_options budget max_turns max_model_attempts mock_mode mock_response)a
  @create_keys [
                 :script,
                 :session,
                 :workspace,
                 :context_options,
                 :max_turns,
                 :max_model_attempts,
                 :mock_mode,
                 :mock_response,
                 :hook,
                 :retry_policy,
                 :model_attempt_scripts,
                 :mock_transient_failures,
                 :priority,
                 :queue,
                 :task_budget,
                 :isolation_policy,
                 :mcp_policy
               ] ++ @budget_keys
  @step_keys [:owner, :lease_ms, :hook, :tool_hook, :commit_hook]

  def create_run(run_id, input, opts \\ []) do
    with {:ok, storage_opts} <- creation_options(run_id, opts),
         {:ok, _} <- Storage.create_run(run_id, input, storage_opts) do
      load(run_id)
    end
  end

  @doc false
  def create_run_in_transaction(repo, run_id, input, opts, internal_opts \\ []) do
    with true <- repo.in_transaction?() || {:error, :transaction_required},
         {:ok, storage_opts} <- creation_options(run_id, opts) do
      Storage.create_run_in_transaction(repo, run_id, input, storage_opts ++ internal_opts)
    end
  end

  defp creation_options(run_id, opts) do
    with :ok <- options(opts, @create_keys),
         {:ok, config} <- config(run_id, opts),
         {:ok, retry} <- retry_config(opts),
         {:ok, enrollment} <-
           enrollment(
             config,
             retry,
             Keyword.get(opts, :isolation_policy),
             Keyword.get(opts, :mcp_policy)
           ),
         :ok <- retry_slots(config, retry) do
      {:ok,
       [
         max_turns: config.max_turns,
         priority: Keyword.get(opts, :priority, 0),
         recovery_config: enrollment,
         hook: Keyword.get(opts, :hook),
         queue: Keyword.get(opts, :queue)
       ] ++
         if(Keyword.has_key?(opts, :task_budget) or not is_nil(opts[:queue]),
           do: [task_budget: Keyword.get(opts, :task_budget, [])],
           else: []
         )}
    end
  end

  def load(run_id) do
    with {:ok, saved} <- RecoveryStore.load(run_id),
         {:ok, retry} <- current_retry(saved) do
      recovery =
        saved
        |> Map.take([:config, :progress, :retry_config, :isolation_policy, :mcp_policy])
        |> Map.put(:retry, retry)

      {:ok, Map.put(saved.snapshot, :recovery, recovery)}
    end
  end

  defp enrollment(config, retry, isolation, mcp) do
    with :ok <- optional_policy(isolation, AgentSystemsLab.Isolation.Policy),
         :ok <- optional_policy(mcp, AgentSystemsLab.MCP.Policy) do
      envelope = %{config: config, retry_config: retry}
      envelope = if isolation, do: Map.put(envelope, :isolation_policy, isolation), else: envelope
      envelope = if mcp, do: Map.put(envelope, :mcp_policy, mcp), else: envelope
      {:ok, if(map_size(envelope) == 2 and is_nil(retry), do: config, else: envelope)}
    end
  end

  defp optional_policy(nil, _module), do: :ok
  defp optional_policy(policy, module), do: module.validate(policy)

  @doc "Continues the same durable run until terminal, unknown outcome or the step bound."
  def resume(run_id, opts \\ []) do
    with :ok <- options(opts, @step_keys ++ [:max_steps]),
         steps = Keyword.get(opts, :max_steps, 20),
         true <- (is_integer(steps) and steps >= 0) || {:error, :invalid_step_limit} do
      advance(run_id, Keyword.delete(opts, :max_steps), steps)
    end
  end

  def step(run_id, opts \\ []) do
    with :ok <- options(opts, @step_keys), {:ok, current} <- load(run_id) do
      case current.state.status do
        status when status in @terminal ->
          {:ok, current}

        :blocked ->
          {:error, :reconciliation_required}

        _ ->
          claimed_step(run_id, opts, fn claim ->
            execute_claim(claim, Keyword.take(opts, [:hook, :tool_hook, :commit_hook]))
          end)
      end
    end
  end

  @doc "Executes one enrolled step under an existing claim; the delivery owner renews and releases it."
  def execute_claim(claim, opts \\ [])

  def execute_claim(%{run_id: id, seq: seq} = claim, opts)
      when is_binary(id) and is_integer(seq) do
    with :ok <- options(opts, [:hook, :tool_hook, :commit_hook]),
         true <- not Repo.in_transaction?() || {:error, :nested_transaction_not_supported},
         {:ok, :valid} <-
           Repo.transaction(fn ->
             with %AgentSystemsLab.Storage.Run{} = row <-
                    Repo.one(
                      from(run in AgentSystemsLab.Storage.Run,
                        where: run.id == ^id,
                        lock: "FOR UPDATE"
                      )
                    ),
                  {:ok, current} <- Storage.snapshot_in_transaction(Repo, row),
                  {:ok, _policy} <- RecoveryStore.dispatch_policy_in_transaction(Repo, current),
                  {:ok, _} <- IntentStore.verify(Repo, id, seq, claim),
                  true <-
                    current.state.status in [:running, :waiting_tool] || {:error, :stale_claim} do
               :valid
             else
               nil -> Repo.rollback(:not_found)
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      case TaskBudgetStore.reserve(claim) do
        {:ok, budget} ->
          if budget do
            Observability.emit(:budget_charged, claim_refs(claim), %{dispatches: 1},
              phase: :committed
            )
          end

          Observability.emit(:recovery_started, claim_refs(claim), %{}, phase: :observed)
          started = System.monotonic_time(:millisecond)
          hook(opts, :after_claim)
          result = execute_step(claim, opts)

          Observability.emit(
            :recovery_stopped,
            claim_refs(claim),
            %{duration_ms: max(0, System.monotonic_time(:millisecond) - started)},
            phase: :observed,
            outcome: result_outcome(result)
          )

          result

        {:error, {:budget_exceeded, _} = reason} ->
          Observability.emit(:budget_exhausted, claim_refs(claim), %{}, phase: :observed)
          reclaim(claim, reason)

        error ->
          error
      end
    end
  end

  def execute_claim(_claim, _opts), do: {:error, :invalid_claim}

  @doc "Archives a stopped delivery without model calls, effects or external queries."
  def reclaim(claim, reason) do
    with {:ok, current} <- load(claim.run_id),
         true <- current.state.seq == claim.seq || {:error, :stale_claim} do
      case current.state.status do
        :running -> dispatch(claim, {:fail, reason}, [])
        :waiting_tool -> archive_expired_tool(claim, current, reason, [])
        _ -> {:error, :stale_claim}
      end
    end
  end

  @doc "Queries a blocked operation, or records explicit trusted operator evidence."
  def reconcile(run_id, opts \\ []) do
    with :ok <- options(opts, @step_keys ++ [:result, :evidence]),
         {:ok, current} <- load(run_id),
         true <- current.state.status == :blocked || {:error, :not_blocked} do
      claimed_step(run_id, opts, fn claim ->
        hook(opts, :after_claim)
        operation = Map.fetch!(current.state.operations, current.state.pending_operation_id)
        tool_opts = tool_options(current.recovery.config, opts)

        result =
          case Keyword.fetch(opts, :result) do
            :error ->
              # A receipt may have committed before the reconciliation Event.
              # Accept that fact before reserving another external query attempt.
              with {:ok, receipt} <- DurableTools.confirmed_receipt(claim, operation, tool_opts) do
                if is_nil(receipt),
                  do: query_reconcile(claim, current, operation, tool_opts, opts),
                  else: {:ok, receipt}
              end

            {:ok, {outcome, _} = supplied} when outcome in [:ok, :error] ->
              wrapped =
                if match?({_, %{type: "tool_result.v1"}}, supplied),
                  do: supplied,
                  else: Result.wrap(supplied, operation.operation_id, operation.tool)

              DurableTools.confirm(
                claim,
                operation,
                wrapped,
                Keyword.get(opts, :evidence),
                tool_opts
              )

            {:ok, _invalid} ->
              {:error, :invalid_reconciliation_result}
          end

        with {:ok, receipt} <- result do
          dispatch(claim, {:reconcile, operation.operation_id, receipt}, opts)
        end
      end)
    end
  end

  defp query_reconcile(claim, %{recovery: %{retry_config: nil}}, operation, tool_opts, _opts),
    do: DurableTools.reconcile(claim, operation, tool_opts)

  defp query_reconcile(claim, current, operation, tool_opts, opts) do
    if current.recovery.config.mock_mode != :idempotent or operation.tool != "mock_write" do
      {:error, :reconciliation_required}
    else
      with {:ok, reservation} <-
             RetryStore.reserve(claim, current.recovery.retry_config.policy, :reconcile) do
        hook(opts, :after_retry_reserve)
        deadline = reservation.first_attempt_at_ms + reservation.policy.max_elapsed_ms

        result =
          timed_tool(
            fn -> DurableTools.reconcile(claim, operation, tool_opts) end,
            reservation.policy.tool_timeout_ms,
            deadline
          )

        case result do
          {:error, {:database_unavailable, _, _}} = unavailable ->
            unavailable

          {:ok, receipt} ->
            {:ok, receipt}

          other ->
            reason =
              case other do
                {:ambiguous, _} -> :lookup_timeout
                {:error, reason} -> reason
              end

            failure =
              ErrorPolicy.classify(reason, scope: :reconcile, idempotent?: true, effect: :none)

            with {:ok, state} <-
                   RetryStore.schedule(claim, reservation.policy, :reconcile, failure) do
              hook(opts, :after_retry_schedule)

              if state.status == :waiting,
                do: {:error, {:retry_not_due, state.next_attempt_at_ms}},
                else: {:error, :reconciliation_required}
            end
        end
      end
    end
  end

  def cancel(run_id, reason \\ :user_requested) do
    with {:ok, current} <- load(run_id),
         {:ok, _} <- Storage.dispatch(run_id, current.state.seq, {:cancel, reason}),
         do: load(run_id)
  end

  @doc false
  def validate_config(config) when is_map(config) do
    with true <-
           Enum.sort(Map.keys(config)) === Enum.sort(@config_keys) ||
             {:error, :invalid_recovery_config},
         true <-
           config.schema_version === 1 ||
             {:error, {:unsupported_recovery_config_version, config.schema_version}},
         true <- config.provider === "scripted.v1" || {:error, :unsupported_recovery_provider},
         {:ok, _} <- Scripted.new(config.script),
         {:ok, _} <- Session.from_map(config.session),
         :ok <- Context.validate_options(config.context_options),
         true <-
           (is_map(config.budget) and
              Enum.sort(Map.keys(config.budget)) === Enum.sort(@budget_keys)) ||
             {:error, :invalid_recovery_budget},
         {:ok, _} <- Budget.new(Map.to_list(config.budget)),
         true <-
           (is_integer(config.max_turns) and config.max_turns > 0 and
              is_integer(config.max_model_attempts) and config.max_model_attempts > 0) ||
             {:error, :invalid_recovery_limits},
         true <- config.mock_mode in [:idempotent, :unqueryable] || {:error, :invalid_mock_mode},
         true <-
           config.mock_response in [:ok, :lost, :fail_before_effect] ||
             {:error, :invalid_mock_response},
         true <-
           (is_nil(config.workspace) or
              (is_binary(config.workspace) and
                 Path.type(config.workspace) == :absolute)) ||
             {:error, :invalid_recovery_workspace},
         {:ok, _} <- Codec.encode(config) do
      :ok
    end
  end

  def validate_config(_), do: {:error, :invalid_recovery_config}

  @doc false
  def validate_retry_config(value) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value)) ===
             Enum.sort([
               :schema_version,
               :policy,
               :model_attempt_scripts,
               :mock_transient_failures
             ]) || {:error, :invalid_retry_config},
         true <-
           value.schema_version === 1 ||
             {:error, {:unsupported_retry_config_version, value.schema_version}},
         :ok <- RetryPolicy.validate(value.policy),
         true <-
           (is_map(value.model_attempt_scripts) and not is_struct(value.model_attempt_scripts)) ||
             {:error, :invalid_model_attempt_scripts},
         true <-
           Enum.all?(value.model_attempt_scripts, fn {cursor, entries} ->
             is_integer(cursor) and cursor >= 0 and is_list(entries) and entries != [] and
               match?({:ok, _}, Scripted.new(entries))
           end) || {:error, :invalid_model_attempt_scripts},
         true <-
           (is_integer(value.mock_transient_failures) and value.mock_transient_failures in 0..100) ||
             {:error, :invalid_mock_transient_failures},
         {:ok, _} <- Codec.encode(value) do
      :ok
    end
  end

  def validate_retry_config(_), do: {:error, :invalid_retry_config}

  defp retry_config(opts) do
    with {:ok, policy} <- RetryPolicy.new(Keyword.get(opts, :retry_policy)) do
      if is_nil(policy) do
        if Keyword.has_key?(opts, :model_attempt_scripts) or
             Keyword.has_key?(opts, :mock_transient_failures),
           do: {:error, :retry_policy_required},
           else: {:ok, nil}
      else
        config = %{
          schema_version: 1,
          policy: policy,
          model_attempt_scripts: Keyword.get(opts, :model_attempt_scripts, %{}),
          mock_transient_failures: Keyword.get(opts, :mock_transient_failures, 0)
        }

        with :ok <- validate_retry_config(config), do: {:ok, config}
      end
    end
  end

  defp current_retry(%{retry_config: nil}), do: {:ok, nil}

  defp current_retry(saved) do
    scope =
      if saved.snapshot.state.status == :waiting_tool,
        do: :tool,
        else: if(saved.snapshot.state.status == :blocked, do: :reconcile, else: :model)

    case RetryStore.load(saved.snapshot.state.run_id, saved.snapshot.state.seq, scope) do
      {:error, :retry_not_found} -> {:ok, nil}
      result -> result
    end
  end

  defp config(run_id, opts) do
    with {:ok, budget} <- Budget.new(opts),
         {:ok, session} <- session(run_id, opts),
         {:ok, workspace} <- workspace(Keyword.get(opts, :workspace)),
         config = %{
           schema_version: 1,
           provider: "scripted.v1",
           script: Keyword.get(opts, :script, []),
           session: Session.to_map(session),
           workspace: workspace,
           context_options: Keyword.get(opts, :context_options, []),
           budget: Map.take(budget, @budget_keys),
           max_turns: Keyword.get(opts, :max_turns, 4),
           max_model_attempts: Keyword.get(opts, :max_model_attempts, 8),
           mock_mode: Keyword.get(opts, :mock_mode, :idempotent),
           mock_response: Keyword.get(opts, :mock_response, :ok)
         },
         :ok <- validate_config(config) do
      {:ok, config}
    end
  end

  defp session(run_id, opts) do
    case Keyword.fetch(opts, :session) do
      :error -> Session.new("recovery:" <> Context.hash(run_id))
      {:ok, value} -> with :ok <- Session.validate(value), do: {:ok, value}
    end
  end

  defp workspace(nil), do: {:ok, nil}

  defp workspace(root) do
    with {:ok, files} <- Files.new(root), do: {:ok, files.workspace.root}
  end

  defp advance(id, opts, left) do
    with {:ok, current} <- load(id) do
      cond do
        current.state.status in (@terminal ++ [:blocked]) -> {:ok, current}
        retry_waiting?(current) -> {:ok, current}
        left == 0 -> {:error, :step_limit}
        true -> with {:ok, _} <- step(id, opts), do: advance(id, opts, left - 1)
      end
    end
  end

  defp claimed_step(id, opts, function) do
    owner = Keyword.get(opts, :owner, "worker:" <> Ecto.UUID.generate())

    with {:ok, claim} <-
           IntentStore.claim(id, owner, lease_ms: Keyword.get(opts, :lease_ms, 30_000)) do
      try do
        function.(claim)
      after
        # Successful transitions supersede this intent. On recoverable errors
        # release only our own live token; never revoke a successor's lease.
        IntentStore.release(claim)
      end
    end
  end

  defp execute_step(claim, opts) do
    with {:ok, current} <- load(claim.run_id) do
      deadline =
        with :ok <- RecoveryStore.check_deadline(claim.run_id),
             do: TaskBudgetStore.check_deadline(claim.run_id)

      case deadline do
        :ok ->
          case current.state.status do
            :running -> attempt_step(claim, current, :model, opts)
            :waiting_tool -> attempt_step(claim, current, :tool, opts)
            _ -> {:error, :stale_claim}
          end

        {:error, {:budget_exceeded, _} = reason}
        when current.state.status == :waiting_tool ->
          archive_expired_tool(claim, current, reason, opts)

        {:error, reason} ->
          dispatch(claim, {:fail, reason}, opts)
      end
    end
  end

  # Execution expiry forbids new effects; it cannot erase a prior delivery's
  # confirmed or ambiguous result. Only read/archive existing local evidence.
  defp archive_expired_tool(claim, current, reason, opts) do
    operation = Map.fetch!(current.state.operations, current.state.pending_operation_id)

    with {:ok, journal} <- DurableTools.list(claim.run_id) do
      case Enum.find(journal, &(&1.operation_id == operation.operation_id)) do
        nil ->
          dispatch(claim, {:fail, reason}, opts)

        %{status: "completed", result: receipt} ->
          dispatch(claim, {:tool_result, operation.operation_id, receipt}, opts)

        _ambiguous ->
          with {:ok, receipt} <-
                 DurableTools.observe_timeout(
                   claim,
                   operation,
                   reason,
                   Keyword.delete(tool_options(current.recovery.config, opts), :hook)
                 ),
               do: dispatch(claim, {:tool_result, operation.operation_id, receipt}, opts)
      end
    end
  end

  defp attempt_step(claim, current, scope, opts) do
    case reserve_retry(claim, current, scope) do
      {:ok, reservation} ->
        hook(opts, :after_retry_reserve)
        attempt = if reservation, do: reservation.attempt

        deadline =
          if reservation, do: reservation.first_attempt_at_ms + reservation.policy.max_elapsed_ms

        opts =
          opts |> Keyword.put(:retry_attempt, attempt) |> Keyword.put(:retry_deadline, deadline)

        if scope == :model,
          do: model_step(claim, current, opts),
          else: tool_step(claim, current, opts)

      {:error, {:retry_exhausted, %{class: :unknown} = failure}} when scope == :tool ->
        with {:ok, result} <-
               DurableTools.observe_timeout(
                 claim,
                 Map.fetch!(current.state.operations, current.state.pending_operation_id),
                 failure.reason,
                 tool_options(current.recovery.config, opts) |> Keyword.delete(:hook)
               ),
             do: dispatch(claim, {:tool_result, current.state.pending_operation_id, result}, opts)

      {:error, {:retry_exhausted, failure}} ->
        dispatch(claim, {:fail, {:retry_exhausted, scope, failure.reason}}, opts)

      error ->
        error
    end
  end

  defp reserve_retry(_claim, %{recovery: %{retry_config: nil}}, _scope), do: {:ok, nil}

  defp reserve_retry(claim, current, scope) do
    RetryStore.reserve(claim, current.recovery.retry_config.policy, scope)
  end

  defp retry_waiting?(%{recovery: %{retry: %{status: :waiting, next_attempt_at_ms: due}}}) do
    RecoveryStore.now_ms() < due
  end

  defp retry_waiting?(_), do: false

  defp model_step(claim, current, opts) do
    case RecoveryStore.begin_model_attempt(claim, deadline_at_ms: opts[:retry_deadline]) do
      {:ok, saved} ->
        Observability.emit(
          :budget_charged,
          Map.put(claim_refs(claim), :attempt_id, saved.progress.model_attempts),
          %{model_attempts: 1},
          phase: :committed
        )

        config = saved.config

        with {:ok, session} <- Session.from_map(config.session),
             {:ok, files} <- files(config.workspace),
             {:ok, built} <-
               Context.build(
                 session,
                 current.state,
                 permissions(
                   config,
                   current.recovery.isolation_policy,
                   current.recovery.mcp_policy
                 ),
                 config.context_options
               ),
             {:ok, capture} <-
               ContextStore.capture(
                 current.state,
                 session,
                 permissions(
                   config,
                   current.recovery.isolation_policy,
                   current.recovery.mcp_policy
                 ),
                 built,
                 context_options: config.context_options
               ) do
          hook(opts, :after_input)

          config = %{config | script: model_script(current, opts[:retry_attempt])}

          case call_model(
                 claim,
                 saved.progress,
                 config,
                 built.context,
                 Keyword.put(opts, :model_capture_id, capture.id)
               ) do
            {:ok, response} ->
              budget =
                struct!(
                  Budget,
                  Map.merge(config.budget, %{output_bytes: saved.progress.output_bytes})
                )

              with :ok <-
                     Gateway.validate_response(
                       response,
                       files,
                       current.recovery.isolation_policy,
                       current.recovery.mcp_policy
                     ),
                   :ok <- durable_response(response),
                   :ok <- Budget.allow_response(budget, current.state, response) do
                hook(opts, :after_model)

                dispatch(claim, {:model_response, response}, opts,
                  model_result: %{
                    context_id: capture.id,
                    provider: config.provider,
                    response: response
                  },
                  recovery_progress: %{cursor: saved.progress.cursor + 1}
                )
              else
                {:error, reason} -> retry_failure(claim, current, :model, reason, opts)
              end

            {:error, reason} ->
              retry_failure(claim, current, :model, safe_reason(reason), opts)
          end
        else
          {:error, reason} ->
            retry_failure(claim, current, :model, {:context_error, safe_reason(reason)}, opts)
        end

      {:error, reason} when reason in [:stale_claim, :claim_expired, :invalid_claim] ->
        {:error, reason}

      {:error, reason} ->
        dispatch(claim, {:fail, reason}, opts)
    end
  end

  defp call_model(claim, progress, config, context, opts) do
    with {:ok, :valid} <- RecoveryStore.check_attempt(claim, progress.request_token),
         do: launch_model(claim, progress, config, context, opts)
  end

  defp launch_model(claim, progress, config, context, opts) do
    refs =
      Map.merge(claim_refs(claim), %{
        attempt_id: opts[:model_capture_id],
        span_id: TraceContext.span_id(:model, {claim.run_id, opts[:model_capture_id]})
      })

    started = System.monotonic_time(:millisecond)
    Observability.emit(:model_started, refs, %{}, phase: :observed)
    owner = self()

    task =
      Task.Supervisor.async_nolink(AgentSystemsLab.ProviderSupervisor, fn ->
        watch_owner(owner)

        DatabaseError.protect(fn ->
          key = {__MODULE__, :assembler}
          Process.put(key, Stream.new())
          provider = %Scripted{responses: config.script, cursor: progress.cursor}

          emit = fn event ->
            with {:ok, _charged} <-
                   RecoveryStore.charge_frame(claim, progress.request_token, event) do
              case Stream.push(Process.get(key), event) do
                {:ok, assembler} ->
                  Process.put(key, assembler)
                  hook(opts, :after_frame)
                  :ok

                {:done, _response, assembler} ->
                  Process.put(key, assembler)
                  hook(opts, :after_frame)
                  :ok

                {:error, reason} ->
                  {:error, {:invalid_stream, reason}}
              end
            end
          end

          case Scripted.stream(context, provider, emit) do
            {:ok, _provider} -> Stream.finish(Process.get(key))
            {:error, reason, _provider} -> {:error, reason}
          end
        end)
      end)

    result =
      case await_model(task, claim, progress) do
        {:ok, {:ok, response}} -> {:ok, response}
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, {:provider_exit, safe_reason(reason)}}
        nil -> {:error, {:budget_exceeded, :model_timeout}}
        {:stopped, reason} -> {:error, reason}
      end

    Observability.emit(
      :model_stopped,
      refs,
      %{duration_ms: max(0, System.monotonic_time(:millisecond) - started)},
      phase: :observed,
      outcome: result_outcome(result)
    )

    result
  end

  defp claim_refs(claim) do
    refs = Map.take(claim, [:run_id, :seq, :intent_id, :generation])

    Map.merge(refs, %{
      span_id: TraceContext.span_id(:recovery, {claim.run_id, claim.seq, claim.generation}),
      parent_span_id: TraceContext.span_id(:run, claim.run_id)
    })
  end

  defp result_outcome({:ok, _}), do: :ok
  defp result_outcome(_), do: :error

  defp await_model(task, claim, progress) do
    remaining = progress.request_deadline_at_ms - RecoveryStore.now_ms()

    if remaining <= 0 do
      Task.shutdown(task, :brutal_kill)

      case RecoveryStore.check_attempt(claim, progress.request_token) do
        {:error, reason} -> {:stopped, reason}
        _ -> nil
      end
    else
      case Task.yield(task, min(remaining, 50)) do
        nil ->
          case RecoveryStore.check_attempt(claim, progress.request_token) do
            {:ok, :valid} ->
              await_model(task, claim, progress)

            {:error, reason} ->
              Task.shutdown(task, :brutal_kill)
              {:stopped, reason}
          end

        reply ->
          reply
      end
    end
  end

  defp watch_owner(owner) do
    worker = self()

    spawn(fn ->
      parent_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^parent_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
      end
    end)
  end

  defp tool_step(claim, current, opts) do
    operation = Map.fetch!(current.state.operations, current.state.pending_operation_id)
    tool_opts = tool_options(current.recovery.config, opts)

    tool_opts =
      case current.recovery.retry_config do
        nil ->
          tool_opts

        retry ->
          tool_opts ++
            [
              retry_failed: true,
              transient_failures: retry.mock_transient_failures,
              attempt: opts[:retry_attempt]
            ]
      end

    work = fn -> DurableTools.execute(claim, operation, tool_opts) end

    result =
      case current.recovery.retry_config do
        nil ->
          work.()

        retry ->
          timed_tool(
            work,
            retry.policy.tool_timeout_ms,
            min(current.recovery.progress.deadline_at_ms, opts[:retry_deadline])
          )
      end

    case result do
      {:ok, {:error, %{output: %{kind: "transient", reason: "unavailable", effect: "none"}}}}
      when not is_nil(current.recovery.retry_config) ->
        retry_failure(claim, current, :tool, :unavailable, opts, effect: :none)

      {:ok, receipt} ->
        dispatch(claim, {:tool_result, operation.operation_id, receipt}, opts)

      {:ambiguous, reason} ->
        with {:ok, receipt} <-
               DurableTools.observe_timeout(
                 claim,
                 operation,
                 reason,
                 Keyword.delete(tool_opts, :hook)
               ),
             do: dispatch(claim, {:tool_result, operation.operation_id, receipt}, opts)

      {:error, {:budget_exceeded, _} = reason} ->
        dispatch(claim, {:fail, reason}, opts)

      error ->
        error
    end
  end

  defp timed_tool(work, timeout_ms, run_deadline) do
    remaining = run_deadline - RecoveryStore.now_ms()

    if remaining <= 0 do
      {:error, {:budget_exceeded, :retry_elapsed}}
    else
      run_timed_tool(work, min(timeout_ms, remaining))
    end
  end

  defp run_timed_tool(work, duration) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(AgentSystemsLab.ProviderSupervisor, fn ->
        watch_owner(owner)
        DatabaseError.protect(work)
      end)

    case Task.yield(task, duration) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:ambiguous, {:tool_worker_exit, safe_reason(reason)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:ambiguous, :tool_timeout}
    end
  end

  defp model_script(%{recovery: %{retry_config: nil, config: config}}, _), do: config.script

  defp model_script(current, attempt) do
    script = current.recovery.config.script
    cursor = current.recovery.progress.cursor

    case Map.get(current.recovery.retry_config.model_attempt_scripts, cursor) do
      nil ->
        script

      entries ->
        List.replace_at(script, cursor, Enum.at(entries, min(attempt - 1, length(entries) - 1)))
    end
  end

  defp retry_failure(claim, current, scope, reason, opts, classification_opts \\ []) do
    if DatabaseError.unavailable?(reason),
      do: {:error, reason},
      else: business_retry_failure(claim, current, scope, reason, opts, classification_opts)
  end

  defp business_retry_failure(claim, current, scope, reason, opts, classification_opts) do
    case current.recovery.retry_config do
      nil ->
        dispatch(claim, {:fail, reason}, opts)

      retry ->
        mode = current.recovery.config.mock_mode

        failure =
          ErrorPolicy.classify(reason,
            scope: scope,
            idempotent?: scope == :model or mode == :idempotent,
            effect: Keyword.get(classification_opts, :effect, :none)
          )

        with {:ok, state} <- RetryStore.schedule(claim, retry.policy, scope, failure) do
          hook(opts, :after_retry_schedule)

          if state.status == :waiting do
            load(claim.run_id)
          else
            terminal =
              if failure.retryable, do: {:retry_exhausted, scope, failure.reason}, else: reason

            dispatch(claim, {:fail, terminal}, opts)
          end
        end
    end
  end

  defp dispatch(claim, command, opts, extra \\ []) do
    hook(opts, :before_dispatch)

    case Storage.dispatch(
           claim.run_id,
           claim.seq,
           command,
           [claim: claim, hook: Keyword.get(opts, :commit_hook)] ++ extra
         ) do
      {:ok, _} ->
        hook(opts, :after_dispatch)
        load(claim.run_id)

      {:error, {:budget_exceeded, _} = reason} when elem(command, 0) == :model_response ->
        with {:ok, current} <- load(claim.run_id),
             do: retry_failure(claim, current, :model, reason, opts)

      error ->
        error
    end
  end

  defp tool_options(config, opts),
    do: [
      workspace: config.workspace,
      mock_mode: config.mock_mode,
      mock_response: config.mock_response,
      hook: Keyword.get(opts, :tool_hook),
      deadline_at_ms: Keyword.get(opts, :retry_deadline)
    ]

  defp files(nil), do: {:ok, nil}
  defp files(root), do: Files.new(root)

  defp permissions(config, isolation_policy, mcp_policy) do
    schemas =
      Catalog.schemas(not is_nil(config.workspace), not is_nil(isolation_policy), mcp_policy)

    %{
      available_tools: schemas,
      allowed_tool_names: Enum.map(schemas, & &1["name"]),
      workspace_root: config.workspace,
      filesystem: %{
        enabled: not is_nil(config.workspace),
        max_file_bytes: Workspace.max_bytes(),
        max_patch_edits: 32,
        blocked_components: Workspace.blocked_components(),
        blocked_components_casefold: true
      },
      shell: false,
      network: false,
      budget: Map.put(config.budget, :max_turns, config.max_turns)
    }
    |> Map.merge(
      if isolation_policy,
        do: %{isolation: AgentSystemsLab.Isolation.Policy.to_map(isolation_policy)},
        else: %{}
    )
    |> Map.merge(
      if mcp_policy, do: %{mcp: AgentSystemsLab.MCP.Policy.to_map(mcp_policy)}, else: %{}
    )
  end

  defp safe_reason(reason) do
    case Codec.encode(reason) do
      {:ok, _} -> reason
      {:error, _} -> {:unpersistable_failure, inspect(reason, limit: 10, printable_limit: 512)}
    end
  end

  defp retry_slots(_config, nil), do: :ok

  defp retry_slots(config, retry) do
    if Enum.all?(Map.keys(retry.model_attempt_scripts), &(&1 < length(config.script))),
      do: :ok,
      else: {:error, :invalid_model_attempt_scripts}
  end

  defp durable_response({:final, _}), do: :ok

  defp durable_response({:call, %{operation_id: id, tool: tool}}) do
    cond do
      not (byte_size(id) in 1..256 and String.valid?(id) and not String.contains?(id, <<0>>)) ->
        {:error, :invalid_operation_id}

      tool != "mock_write" and not Catalog.paired_tool?(tool) ->
        {:error, {:unsupported_tool, tool}}

      true ->
        :ok
    end
  end

  defp options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         Enum.all?([:hook, :tool_hook, :commit_hook], fn key ->
           is_nil(opts[key]) or is_function(opts[key], 1)
         end), do: :ok, else: {:error, :invalid_recovery_options}
  end

  defp options(_, _), do: {:error, :invalid_recovery_options}
  defp hook(opts, stage), do: if(opts[:hook], do: opts[:hook].(stage), else: :ok)
end
