defmodule AgentSystemsLab.DurableTools do
  @moduledoc """
  A claim-fenced operation journal, distinct from delivery attempts and effects.

  Preparation commits before a tool is invoked. Confirmed paired receipts are
  reused across process death. Only the mock target provides durable idempotency
  and lookup; a prepared file or unqueryable operation is ambiguous and never
  automatically executed again. Matching file contents do not prove a receipt.

  Explicit `retry_failed: true` only supersedes this idempotent mock adapter's
  confirmed transient no-effect receipt. Prior attempts remain immutable; manual
  evidence and arbitrary failures cannot authorize another effect. The host's
  durable retry scheduler supplies the attempt ordinal and finite retry budget.

  `observe_timeout/4` must follow stopping the timed-out worker. It archives a
  confirmed receipt or conservatively records unknown, including when the worker
  died before preparation. It invokes no target.

  Fault hooks run outside transactions at `:after_prepare`, `:before_effect`,
  `:after_launch` (isolated processes only), `:after_mcp_request` (MCP call sent),
  `:after_effect`, `:before_receipt` and `:after_receipt`. A claim is verified
  again after the first two gates and before confirming a receipt. Each effect
  also checks an enrolled run's durable absolute deadline under the Run
  lock; receipt archival and reconciliation can still finish after that deadline.
  An external service still needs its own idempotency/fencing contract; a lease alone does
  not provide exactly-once side effects.

  `sandbox_exec` obtains its immutable host policy from enrollment. Execution
  holds no SQL transaction or Run lock. Process completion and receipt COMMIT
  cannot be atomic, so an unconfirmed prepared process is never redelivered;
  it requires operator evidence just like an unqueryable external service.
  """
  import Ecto.Query

  alias AgentSystemsLab.{
    Context,
    IntentStore,
    Observability,
    RecoveryStore,
    Repo,
    Storage,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Observability.Context, as: TraceContext
  alias AgentSystemsLab.Storage.{Attempt, Codec, MockEffect, Operation, Run}
  alias AgentSystemsLab.Tools.{Catalog, DurableMock, Files, Gateway, Result}

  @option_keys [
    :workspace,
    :mock_mode,
    :mock_response,
    :hook,
    :retry_failed,
    :transient_failures,
    :attempt,
    :deadline_at_ms
  ]
  @claim_keys [:intent_id, :run_id, :seq, :owner, :token, :generation, :expires_at]

  def execute(claim, operation, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, call, files, policy} <- validate_call(operation, opts, claim),
         {:ok, prepared} <- prepare(claim, call, "execution", nil, retry: opts) do
      hook(opts, :after_prepare)

      cond do
        prepared.status == "completed" ->
          confirm_result(claim, call, prepared, prepared.result, opts)

        not prepared.fresh and not idempotent?(call, opts) ->
          confirm_result(claim, call, prepared, unknown(call), opts)

        true ->
          hook(opts, :before_effect)

          with {:ok, result} <- observed_effect(claim, call, files, policy, opts, prepared) do
            hook(opts, :after_effect)
            confirm_result(claim, call, prepared, result, opts)
          end
      end
    end
  end

  @doc "Archives a timeout after the worker has stopped; never invokes the target."
  def observe_timeout(claim, operation, reason, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, _reason} <- Codec.encode(reason),
         {:ok, call, _files, _policy} <- validate_call(operation, opts, claim),
         {:ok, prepared} <- prepare(claim, call, "observation", nil) do
      result =
        if prepared.status == "completed" do
          prepared.result
        else
          Result.wrap(
            {:unknown, %{kind: "timeout", reason: reason, effect: "unknown"}},
            call.operation_id,
            call.tool
          )
        end

      confirm_result(claim, call, prepared, result, opts)
    end
  end

  def reconcile(claim, operation, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, call, _files, _policy} <- validate_call(operation, opts, claim),
         {:ok, prepared} <- prepare(claim, call, "lookup", nil, existing: true) do
      hook(opts, :after_prepare)

      cond do
        prepared.status == "completed" ->
          confirm_result(claim, call, prepared, prepared.result, opts)

        idempotent?(call, opts) ->
          hook(opts, :before_effect)

          with {:ok, result} <- lookup(claim, call) do
            hook(opts, :after_effect)

            case confirm_result(claim, call, prepared, result, opts) do
              {:ok, {:unknown, _}} -> {:error, :reconciliation_required}
              reply -> reply
            end
          end

        true ->
          with {:ok, _} <- confirm_result(claim, call, prepared, unknown(call), opts),
               do: {:error, :reconciliation_required}
      end
    end
  end

  @doc "Reads an already confirmed local receipt under the current claim; never queries a target."
  def confirmed_receipt(claim, operation, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, call, _files, _policy} <- validate_call(operation, opts, claim) do
      transaction(fn ->
        with {:ok, _run} <- authorize(claim, call) do
          case Repo.one(
                 from row in Operation,
                   where: row.run_id == ^claim.run_id and row.operation_id == ^call.operation_id
               ) do
            nil ->
              {:ok, nil}

            row ->
              with {:ok, decoded} <- decode_operation(row),
                   true <- decoded.input === input(call) || {:error, :operation_id_conflict},
                   {:ok, _audit} <- attempts(row) do
                {:ok, if(decoded.status == "completed", do: decoded.result)}
              end
          end
        end
      end)
    end
  end

  @doc "Records a trusted operator's paired result and evidence without invoking a tool."
  def confirm(claim, operation, result, evidence, opts \\ []) do
    with :ok <- boundary(),
         :ok <- options(opts),
         {:ok, call, _files, _policy} <- validate_call(operation, opts, claim),
         :ok <- manual_result(result, call, evidence),
         {:ok, prepared} <-
           prepare(claim, call, "manual", evidence,
             existing: true,
             statuses: ["prepared", "unknown"]
           ) do
      hook(opts, :after_prepare)
      confirm_result(claim, call, prepared, result, opts)
    end
  end

  @doc "Reads and validates immutable operation inputs, receipts and delivery audit records."
  def list(run_id) do
    Storage.preload_vocabulary()

    transaction(fn ->
      with {:ok, _run} <- lock_run(run_id, "FOR SHARE"),
           {:ok, snapshot} <- Storage.load(run_id) do
        Repo.all(
          from row in Operation,
            where: row.run_id == ^run_id,
            order_by: [asc: row.inserted_at, asc: row.id]
        )
        |> collect(fn row ->
          with {:ok, operation} <- decode_operation(row),
               source when is_map(source) <- Map.get(snapshot.state.operations, row.operation_id),
               true <- Map.take(source, [:tool, :arguments]) === operation.input,
               {:ok, attempts} <- attempts(row) do
            {:ok, Map.merge(operation, %{attempts: attempts})}
          else
            false -> {:error, :operation_history_mismatch}
            nil -> {:error, :operation_history_mismatch}
            {:error, _} = error -> error
          end
        end)
      end
    end)
  end

  @doc "Diagnostic counters; effect inspection does not authorize reconciliation."
  def stats(run_id) do
    %{
      effects: Repo.aggregate(from(row in MockEffect, where: row.run_id == ^run_id), :count),
      attempts: Repo.aggregate(from(row in Attempt, where: row.run_id == ^run_id), :count),
      operations: Repo.aggregate(from(row in Operation, where: row.run_id == ^run_id), :count)
    }
  end

  defp prepare(claim, call, kind, evidence, opts \\ []) do
    reply =
      transaction(fn ->
        with {:ok, _run} <- authorize(claim, call),
             {:ok, row, fresh} <- operation_row(claim.run_id, call, opts),
             {:ok, decoded} <- decode_operation(row),
             true <- decoded.input === input(call) || {:error, :operation_id_conflict},
             {:ok, decoded} <- reset_retryable(row, decoded, call, Keyword.get(opts, :retry)),
             true <-
               (is_nil(Keyword.get(opts, :statuses)) or
                  decoded.status in Keyword.get(opts, :statuses)) || {:error, :already_confirmed},
             {:ok, claim_data} <- Codec.encode(audit_claim(claim)),
             {:ok, attempt} <-
               Repo.insert(
                 Attempt.changeset(%Attempt{}, %{
                   operation_record_id: row.id,
                   run_id: row.run_id,
                   operation_id: row.operation_id,
                   claim_generation: claim.generation,
                   claim_data: claim_data,
                   kind: kind,
                   outcome: "prepared",
                   evidence: evidence
                 })
               ) do
          {:ok,
           %{
             id: row.id,
             attempt_id: attempt.id,
             fresh: fresh,
             status: decoded.status,
             result: decoded.result,
             kind: kind
           }}
        end
      end)

    case reply do
      {:ok, prepared} ->
        Observability.emit(:tool_prepared, tool_refs(claim, call, prepared), %{},
          phase: :committed
        )

      _ ->
        :ok
    end

    reply
  end

  # Only this adapter's confirmed no-effect transient receipt may be superseded.
  # Manual evidence and arbitrary errors never become retry authorization.
  defp reset_retryable(row, decoded, call, opts) when is_list(opts) do
    if decoded.status == "completed" and Keyword.get(opts, :retry_failed, false) and
         idempotent?(call, opts) and transient_no_effect?(decoded.result) do
      with {:ok, audit} <- attempts(row) do
        if Enum.any?(audit, &(&1.kind == "manual")) or
             not Enum.any?(audit, &(&1.kind == "execution" and &1.result === decoded.result)) do
          {:ok, decoded}
        else
          with {:ok, _} <-
                 Repo.update(Operation.changeset(row, %{status: "prepared", result_data: nil})),
               do: {:ok, %{decoded | status: "prepared", result: nil}}
        end
      end
    else
      {:ok, decoded}
    end
  end

  defp reset_retryable(_row, decoded, _call, _opts), do: {:ok, decoded}

  defp transient_no_effect?(
         {:error,
          %{
            type: "tool_result.v1",
            output: %{kind: "transient", reason: "unavailable", effect: "none"} = output
          } = envelope}
       ),
       do: map_size(envelope) == 4 and map_size(output) == 3

  defp transient_no_effect?(_), do: false

  defp operation_row(run_id, call, opts) do
    case Repo.one(
           from row in Operation,
             where: row.run_id == ^run_id and row.operation_id == ^call.operation_id,
             lock: "FOR UPDATE"
         ) do
      nil ->
        if Keyword.get(opts, :existing, false) do
          {:error, :operation_not_prepared}
        else
          with {:ok, data} <- Codec.encode(input(call)),
               {:ok, row} <-
                 Repo.insert(
                   Operation.changeset(%Operation{}, %{
                     run_id: run_id,
                     operation_id: call.operation_id,
                     tool: call.tool,
                     input_sha256: Context.hash(input(call)),
                     input_data: data,
                     status: "prepared"
                   })
                 ),
               do: {:ok, row, true}
        end

      row ->
        {:ok, row, false}
    end
  end

  # External processes cannot participate in a PostgreSQL transaction. Commit
  # preparation and a current-claim/deadline check before launch, release every
  # SQL lock during execution, then fence the immutable receipt independently.
  # A crash in that gap leaves a prepared, non-idempotent operation for review.

  # Entering this call can still be rejected by fencing/deadline checks. Runtime
  # observations describe the delivery boundary, never proof of an external effect.
  defp observed_effect(claim, call, files, policy, opts, prepared) do
    started = System.monotonic_time(:millisecond)
    refs = tool_refs(claim, call, prepared)
    Observability.emit(:tool_started, refs, %{}, phase: :observed)
    reply = effect(claim, call, files, policy, opts)

    outcome =
      case reply do
        {:ok, {outcome, _}} -> outcome
        _ -> :error
      end

    Observability.emit(
      :tool_stopped,
      refs,
      %{duration_ms: max(0, System.monotonic_time(:millisecond) - started)},
      phase: :observed,
      outcome: outcome
    )

    reply
  end

  defp effect(claim, %{tool: "sandbox_exec"} = call, _files, policy, opts) do
    with {:ok, %{policy: execution_policy, deadline_monotonic_ms: execution_deadline}} <-
           transaction(fn ->
             with {:ok, run} <- authorize(claim, call),
                  :ok <- RecoveryStore.check_effect_deadline(Repo, claim.run_id),
                  :ok <- retry_deadline(opts),
                  {:ok, ^policy} <- RecoveryStore.isolation_policy(claim.run_id),
                  {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
                  {:ok, recovery} <- RecoveryStore.dispatch_policy_in_transaction(Repo, snapshot),
                  {:ok, task_budget} <- TaskBudgetStore.policy_in_transaction(Repo, claim.run_id),
                  {:ok, execution_policy} <-
                    execution_policy(policy, claim, recovery, task_budget, opts) do
               {:ok, execution_policy}
             else
               {:ok, _changed} -> {:error, :isolation_policy_mismatch}
               error -> error
             end
           end) do
      result =
        AgentSystemsLab.Isolation.execute(
          call.arguments["command"],
          call.arguments["args"],
          execution_policy,
          deadline_monotonic_ms: execution_deadline,
          on_start: fn _handle -> hook(opts, :after_launch) end
        )

      {:ok, Result.wrap(result, call.operation_id, call.tool)}
    end
  end

  defp effect(claim, %{tool: "mcp." <> _} = call, _files, policy, opts) do
    with {:ok, deadline} <-
           transaction(fn ->
             with {:ok, run} <- authorize(claim, call),
                  :ok <- RecoveryStore.check_effect_deadline(Repo, claim.run_id),
                  :ok <- retry_deadline(opts),
                  {:ok, ^policy} <- RecoveryStore.mcp_policy(claim.run_id),
                  :ok <-
                    AgentSystemsLab.MCP.Policy.validate_call(policy, call.tool, call.arguments),
                  {:ok, snapshot} <- Storage.snapshot_in_transaction(Repo, run),
                  {:ok, recovery} <- RecoveryStore.dispatch_policy_in_transaction(Repo, snapshot),
                  {:ok, task_budget} <- TaskBudgetStore.policy_in_transaction(Repo, claim.run_id),
                  {:ok, deadline} <- external_deadline(claim, recovery, task_budget, opts) do
               {:ok, deadline}
             else
               {:ok, _changed} -> {:error, :mcp_policy_mismatch}
               error -> error
             end
           end) do
      result =
        AgentSystemsLab.MCP.execute(policy, call.tool, call.arguments,
          deadline_monotonic_ms: deadline,
          on_request: fn _request -> hook(opts, :after_mcp_request) end
        )

      {:ok, Result.wrap(result, call.operation_id, call.tool)}
    end
  end

  defp effect(claim, call, files, _policy, opts) do
    transaction(fn ->
      with {:ok, _run} <- authorize(claim, call),
           :ok <- RecoveryStore.check_effect_deadline(Repo, claim.run_id),
           :ok <- retry_deadline(opts) do
        case call.tool do
          "mock_write" ->
            with {:ok, result} <-
                   DurableMock.execute(
                     Repo,
                     claim.run_id,
                     call,
                     Keyword.get(opts, :mock_response, :ok),
                     Keyword.take(opts, [:transient_failures, :attempt])
                   ),
                 do: {:ok, Result.wrap(result, call.operation_id, call.tool)}

          _file ->
            {result, _next_files} =
              Files.execute(files, call.operation_id, call.tool, call.arguments)

            {:ok, Result.wrap(result, call.operation_id, call.tool)}
        end
      end
    end)
  end

  # Convert a PostgreSQL deadline observation into one non-renewable local cap.
  # MCP also applies its immutable connection/request/isolated process limits.
  defp external_deadline(claim, recovery, task_budget, opts) do
    observed = System.monotonic_time(:millisecond)
    now = RecoveryStore.now_ms(Repo)
    lease = DateTime.to_unix(claim.expires_at, :millisecond)
    task = if task_budget, do: task_budget.progress.execution_deadline_at_ms

    deadline =
      [recovery.progress.deadline_at_ms, task, opts[:deadline_at_ms], lease]
      |> Enum.reject(&is_nil/1)
      |> Enum.min()

    cond do
      now >= lease -> {:error, :claim_expired}
      now >= deadline -> {:error, {:budget_exceeded, :execution_timeout}}
      true -> {:ok, observed + deadline - now}
    end
  end

  # Narrow this invocation's wall budget without changing immutable enrollment.
  # The observed lease expiry is conservative even if a Worker has renewed it;
  # each later dispatch obtains a new proof. No SQL/database failure widens it.
  defp execution_policy(policy, claim, recovery, task_budget, opts) do
    observed_monotonic_ms = System.monotonic_time(:millisecond)
    now = RecoveryStore.now_ms(Repo)
    lease_deadline = DateTime.to_unix(claim.expires_at, :millisecond)
    task_deadline = if task_budget, do: task_budget.progress.execution_deadline_at_ms

    deadline =
      [
        now + policy.limits.wall_time_ms,
        recovery.progress.deadline_at_ms,
        task_deadline,
        opts[:deadline_at_ms],
        lease_deadline
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.min()

    cond do
      now >= lease_deadline ->
        {:error, :claim_expired}

      now >= deadline ->
        {:error, {:budget_exceeded, :execution_timeout}}

      true ->
        {:ok,
         %{
           policy: %{policy | limits: %{policy.limits | wall_time_ms: deadline - now}},
           deadline_monotonic_ms: observed_monotonic_ms + deadline - now
         }}
    end
  end

  defp lookup(claim, call) do
    transaction(fn ->
      with {:ok, _run} <- authorize(claim, call) do
        case DurableMock.lookup(Repo, claim.run_id, call) do
          {:ok, receipt} -> {:ok, Result.wrap({:ok, receipt}, call.operation_id, call.tool)}
          :not_found -> {:ok, unknown(call)}
          error -> error
        end
      end
    end)
  end

  defp confirm_result(claim, call, prepared, result, opts) do
    hook(opts, :before_receipt)

    reply =
      transaction(fn ->
        with {:ok, _run} <- authorize(claim, call),
             %Operation{} = row <- Repo.get(Operation, prepared.id),
             {:ok, decoded} <- decode_operation(row),
             true <- decoded.input === input(call) || {:error, :operation_id_conflict},
             :ok <- Result.validate_required(result, call.operation_id, call.tool),
             :ok <- consistent_result(decoded, result),
             {:ok, data} <- Codec.encode(result),
             status = if(elem(result, 0) == :unknown, do: "unknown", else: "completed"),
             {:ok, _row} <-
               Repo.update(Operation.changeset(row, %{status: status, result_data: data})),
             %Attempt{} = attempt <- Repo.get(Attempt, prepared.attempt_id),
             true <- attempt.operation_record_id === row.id || {:error, :attempt_mismatch},
             {:ok, _attempt} <-
               Repo.update(Attempt.changeset(attempt, %{outcome: status, result_data: data})) do
          {:ok, result}
        else
          nil -> {:error, :operation_not_prepared}
          error -> error
        end
      end)

    case reply do
      {:ok, {outcome, _}} ->
        name = if outcome == :unknown, do: :tool_unknown, else: :tool_completed

        Observability.emit(name, tool_refs(claim, call, prepared), %{},
          phase: :committed,
          outcome: outcome
        )

        if prepared.kind in ["manual", "lookup"] and outcome != :unknown do
          Observability.emit(:tool_reconciled, tool_refs(claim, call, prepared), %{},
            phase: :committed,
            outcome: outcome
          )
        end

        hook(opts, :after_receipt)

      _ ->
        :ok
    end

    reply
  end

  defp tool_refs(claim, call, prepared),
    do:
      claim
      |> Map.take([:run_id, :seq, :intent_id, :generation])
      |> Map.merge(%{
        operation_id: call.operation_id,
        attempt_id: prepared.attempt_id,
        span_id:
          TraceContext.span_id(:tool, {claim.run_id, call.operation_id, prepared.attempt_id}),
        parent_span_id: TraceContext.span_id(:run, claim.run_id)
      })

  defp consistent_result(%{status: "completed", result: previous}, result) do
    if previous === result, do: :ok, else: {:error, :confirmed_receipt_conflict}
  end

  defp consistent_result(_decoded, _result), do: :ok

  defp authorize(claim, call) when is_map(claim) do
    with run_id when is_binary(run_id) <- Map.get(claim, :run_id),
         {:ok, run} <- lock_run(run_id, "FOR UPDATE"),
         {:ok, _intent} <- IntentStore.verify(Repo, run_id, Map.get(claim, :seq), claim),
         {:ok, snapshot} <- Storage.load(run_id),
         true <-
           (snapshot.state.seq === claim.seq and
              snapshot.state.status in [:waiting_tool, :blocked] and
              snapshot.state.pending_operation_id === call.operation_id) ||
             {:error, :operation_not_pending},
         source when is_map(source) <- Map.get(snapshot.state.operations, call.operation_id),
         true <-
           Map.take(source, [:operation_id, :tool, :arguments]) === call ||
             {:error, :operation_id_conflict} do
      {:ok, run}
    else
      nil -> {:error, :invalid_claim}
      error -> error
    end
  end

  defp authorize(_claim, _call), do: {:error, :invalid_claim}

  defp lock_run(run_id, lock) do
    query = from(row in Run, where: row.id == ^run_id)

    query =
      if lock == "FOR UPDATE",
        do: from(row in query, lock: "FOR UPDATE"),
        else: from(row in query, lock: "FOR SHARE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp decode_operation(row) do
    with true <- row.schema_version === 1 || {:error, :unsupported_operation_schema_version},
         {:ok, stored_input} <- Codec.decode(row.input_data, row.codec_version),
         %{tool: tool, arguments: args} <- stored_input,
         true <-
           (map_size(stored_input) == 2 and is_map(args) and tool === row.tool and
              row.input_sha256 === Context.hash(stored_input)) ||
             {:error, :operation_input_mismatch},
         {:ok, result} <- decode_optional(row.result_data, row.codec_version),
         :ok <- valid_stored_result(row, result) do
      {:ok,
       %{
         id: row.id,
         run_id: row.run_id,
         operation_id: row.operation_id,
         tool: row.tool,
         input: stored_input,
         input_sha256: row.input_sha256,
         status: row.status,
         result: result,
         inserted_at: row.inserted_at,
         updated_at: row.updated_at
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_operation_record}
    end
  end

  defp valid_stored_result(%{status: "prepared"}, nil), do: :ok

  defp valid_stored_result(row, {outcome, _} = result)
       when (row.status == "completed" and outcome in [:ok, :error]) or
              (row.status == "unknown" and outcome == :unknown),
       do: Result.validate_required(result, row.operation_id, row.tool)

  defp valid_stored_result(_row, _result), do: {:error, :operation_result_mismatch}

  defp attempts(row) do
    Repo.all(
      from attempt in Attempt,
        where: attempt.operation_record_id == ^row.id,
        order_by: [asc: attempt.inserted_at, asc: attempt.id]
    )
    |> collect(fn attempt ->
      with true <- attempt.schema_version === 1 || {:error, :unsupported_attempt_schema_version},
           {:ok, claim} <- Codec.decode(attempt.claim_data, attempt.codec_version),
           true <-
             (valid_audit_claim?(claim) and
                claim.run_id === row.run_id and claim.generation === attempt.claim_generation and
                attempt.run_id === row.run_id and attempt.operation_id === row.operation_id) ||
               {:error, :attempt_metadata_mismatch},
           true <-
             (attempt.kind in ["execution", "lookup", "manual", "observation"] and
                (attempt.kind != "manual" or valid_evidence?(attempt.evidence))) ||
               {:error, :invalid_attempt_kind},
           {:ok, result} <- decode_optional(attempt.result_data, attempt.codec_version),
           :ok <-
             valid_stored_result(
               %{status: attempt.outcome, operation_id: row.operation_id, tool: row.tool},
               result
             ) do
        {:ok,
         %{
           id: attempt.id,
           kind: attempt.kind,
           outcome: attempt.outcome,
           claim: claim,
           result: result,
           evidence: attempt.evidence,
           inserted_at: attempt.inserted_at,
           updated_at: attempt.updated_at
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_attempt_record}
      end
    end)
  end

  defp validate_call(operation, opts, claim) when is_map(operation) do
    call = Map.take(operation, [:operation_id, :tool, :arguments])
    workspace = Keyword.get(opts, :workspace)

    with true <-
           valid_audit_text?(Map.get(call, :operation_id)) || {:error, :invalid_operation_id},
         {:ok, files} <- files(workspace),
         {:ok, isolation} <- policy_for_claim(claim),
         {:ok, mcp} <- mcp_for_claim(claim),
         :ok <- Gateway.validate_call(call, files, isolation, mcp),
         :ok <- validate_catalog(call),
         {:ok, _encoded} <- Codec.encode(call) do
      {:ok, call, files, if(Catalog.mcp_tool?(call.tool), do: mcp, else: isolation)}
    end
  end

  defp validate_call(_operation, _opts, _claim), do: {:error, :invalid_operation}
  defp policy_for_claim(%{run_id: id}) when is_binary(id), do: RecoveryStore.isolation_policy(id)
  defp policy_for_claim(_), do: {:ok, nil}
  defp mcp_for_claim(%{run_id: id}) when is_binary(id), do: RecoveryStore.mcp_policy(id)
  defp mcp_for_claim(_), do: {:ok, nil}
  defp validate_catalog(%{tool: "mcp." <> _}), do: :ok
  defp validate_catalog(call), do: Catalog.validate(call.tool, call.arguments)
  defp files(nil), do: {:ok, nil}
  defp files(path), do: Files.new(path)
  defp input(call), do: Map.take(call, [:tool, :arguments])

  defp idempotent?(call, opts),
    do: call.tool == "mock_write" and Keyword.get(opts, :mock_mode, :idempotent) == :idempotent

  defp unknown(call),
    do: Result.wrap({:unknown, :receipt_unconfirmed}, call.operation_id, call.tool)

  defp decode_optional(nil, _version), do: {:ok, nil}
  defp decode_optional(data, version), do: Codec.decode(data, version)

  defp manual_result({outcome, _} = result, call, evidence) when outcome in [:ok, :error] do
    with true <- valid_evidence?(evidence) || {:error, :invalid_reconciliation_evidence},
         :ok <- Result.validate_required(result, call.operation_id, call.tool),
         {:ok, _data} <- Codec.encode(result),
         do: :ok
  end

  defp manual_result(_result, _call, _evidence), do: {:error, :invalid_reconciliation_result}

  defp valid_evidence?(value),
    do:
      is_binary(value) and byte_size(value) in 1..8192 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, <<0>>)

  defp audit_claim(claim), do: Map.update!(claim, :expires_at, &DateTime.to_iso8601/1)

  defp valid_audit_claim?(claim) when is_map(claim) do
    Enum.sort(Map.keys(claim)) === Enum.sort(@claim_keys) and
      is_integer(claim.intent_id) and claim.intent_id > 0 and
      is_integer(claim.seq) and claim.seq > 0 and
      is_integer(claim.generation) and claim.generation > 0 and
      valid_audit_text?(claim.run_id) and valid_audit_text?(claim.owner) and
      Ecto.UUID.cast(claim.token) === {:ok, claim.token} and
      is_binary(claim.expires_at) and
      match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(claim.expires_at))
  end

  defp valid_audit_claim?(_claim), do: false

  defp valid_audit_text?(text),
    do:
      is_binary(text) and byte_size(text) > 0 and
        String.valid?(text) and not String.contains?(text, <<0>>)

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- @option_keys == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Keyword.get(opts, :mock_mode, :idempotent) in [:idempotent, :unqueryable] and
         Keyword.get(opts, :mock_response, :ok) in [:ok, :lost, :fail_before_effect] and
         is_boolean(Keyword.get(opts, :retry_failed, false)) and
         is_integer(Keyword.get(opts, :transient_failures, 0)) and
         Keyword.get(opts, :transient_failures, 0) >= 0 and
         is_integer(Keyword.get(opts, :attempt, 1)) and Keyword.get(opts, :attempt, 1) > 0 and
         (is_nil(opts[:deadline_at_ms]) or
            (is_integer(opts[:deadline_at_ms]) and opts[:deadline_at_ms] > 0)) and
         (is_nil(Keyword.get(opts, :workspace)) or is_binary(Keyword.get(opts, :workspace))) and
         (is_nil(Keyword.get(opts, :hook)) or is_function(Keyword.get(opts, :hook), 1)),
       do: :ok,
       else: {:error, :invalid_durable_tool_options}
  end

  defp options(_opts), do: {:error, :invalid_durable_tool_options}

  defp retry_deadline(opts) do
    case opts[:deadline_at_ms] do
      nil ->
        :ok

      limit ->
        if RecoveryStore.now_ms() >= limit,
          do: {:error, {:budget_exceeded, :retry_elapsed}},
          else: :ok
    end
  end

  defp boundary,
    do: if(Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok)

  defp hook(opts, stage),
    do: if(callback = Keyword.get(opts, :hook), do: callback.(stage), else: :ok)

  defp transaction(function) do
    case Repo.transaction(fn ->
           case function.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  defp collect(items, function) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case function.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
