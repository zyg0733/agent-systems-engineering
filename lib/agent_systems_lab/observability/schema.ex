defmodule AgentSystemsLab.Observability.Schema do
  @moduledoc """
  Strict, content-free v1 export projection. Unknown fields are discarded.

  Only host-owned business identifiers belong in correlation fields. Arbitrary
  prompts, tool names/arguments/results, paths, exception messages, claim tokens,
  and user-selected labels have no export field. A malformed event is dropped.
  """
  alias AgentSystemsLab.Observability.Context

  @names ~w(run_created run_committed event_committed intent_claimed intent_completed intent_released intent_retried lease_renewed lease_rejected lease_lost recovery_started recovery_stopped model_started model_stopped model_recorded tool_prepared tool_started tool_stopped tool_completed tool_unknown tool_reconciled retry_scheduled retry_reserved retry_completed budget_charged budget_exhausted execution_timed_out workflow_created workflow_changed workflow_cancelled case_created case_changed case_paused case_resumed approval_requested approval_decided approval_invalidated rework_started rework_exhausted workflow_committed workflow_control_committed approval_committed)a
  @refs ~w(run_id workflow_id case_id turn_id operation_id attempt_id intent_id generation seq span_id parent_span_id)a
  @measurements ~w(duration_ms queue_ms bytes output_bytes input_bytes model_attempts tool_calls dispatches retries count lease_ms backoff_ms sequence nodes_running nodes_blocked nodes_succeeded approval_generation round_index)a
  @attributes ~w(phase outcome status classification reason scope event_type storage)a
  @values ~w(committed observed ok error unknown success succeeded failed cancelled blocked running waiting pending paused approved rejected invalidated exhausted denied stale timeout cancelled_by_host transient permanent ambiguous retryable non_retryable model tool reconcile input accepted started stopped requested completed prepared released scheduled claimed renewed rejected_claim unavailable invalid lost expired shutdown not_found budget invalid_result exception exit invalid_recording provider_error tool_error tool_timeout execution_timeout lease_expired already_completed policy_denied operator_decision initial rework awaiting_approval awaiting_review ready skipped running_review running_implementation review_requested review_approved review_rejected changes_requested artifact_changed approval_required invalid_approval new_run model_request model_result tool_call tool_result cancel fail retry control snapshot restored created finished resumed dependency_failed deadline user_requested waiting_tool memory postgres run_started tool_requested tool_result_recorded tool_reconciled run_succeeded run_failed run_cancelled inflight closed)a

  def names, do: @names
  def correlation_keys, do: @refs

  def project(name, refs, measurements, opts \\ []) do
    with true <- name in @names,
         true <- is_map(refs) and is_map(measurements),
         true <- is_list(opts) and Keyword.keyword?(opts),
         {:ok, correlation} <- correlation(refs),
         true <-
           is_nil(correlation["span_id"]) or
             correlation["span_id"] != correlation["parent_span_id"],
         {:ok, numbers} <- numbers(measurements) do
      attrs =
        for key <- @attributes,
            value = Keyword.get(opts, key),
            value in @values,
            into: %{},
            do: {Atom.to_string(key), Atom.to_string(value)}

      run = Map.get(correlation, "run_id")
      identity = run || Map.get(correlation, "workflow_id") || Map.get(correlation, "case_id")
      span = Map.get(correlation, "span_id") || span_id(name, correlation)

      parent =
        Map.get(correlation, "parent_span_id") ||
          if(run && span != Context.root_span_id(run), do: Context.root_span_id(run))

      {:ok,
       %{
         "schema_version" => 1,
         "event_name" => Atom.to_string(name),
         "event_id" => Context.event_id(name, correlation),
         "evidence_origin" => "observation",
         "trace_id" => if(identity, do: Context.trace_id(identity), else: nil),
         "span_id" => span,
         "parent_span_id" => parent,
         "correlation" => correlation,
         "attributes" => attrs,
         "measurements" => numbers,
         "observed_at_unix_ms" => timestamp(opts)
       }}
    else
      _ -> {:error, :invalid_observation}
    end
  rescue
    _ -> {:error, :invalid_observation}
  catch
    _, _ -> {:error, :invalid_observation}
  end

  defp span_id(name, refs) do
    run = refs["run_id"]

    cond do
      run && name in [:run_created, :run_committed] ->
        Context.root_span_id(run)

      run && name in [:model_started, :model_stopped, :model_recorded] ->
        Context.span_id(:model, {run, refs["attempt_id"] || refs["turn_id"]})

      run &&
          name in [
            :tool_started,
            :tool_stopped,
            :tool_prepared,
            :tool_completed,
            :tool_unknown,
            :tool_reconciled
          ] ->
        Context.span_id(:tool, {run, refs["operation_id"], refs["attempt_id"]})

      true ->
        Context.span_id(name, refs)
    end
  end

  defp correlation(refs) do
    Enum.reduce_while(@refs, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(refs, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} when key in [:span_id, :parent_span_id] ->
          if is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{16}\z/) and
               value != "0000000000000000",
             do: {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}},
             else: {:halt, {:error, :invalid_span_id}}

        {:ok, value} when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991 ->
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

        {:ok, value} when is_binary(value) and byte_size(value) in 1..256 ->
          if String.valid?(value) and String.match?(value, ~r/\A[A-Za-z0-9_.:@-]+\z/),
            do: {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}},
            else: {:halt, {:error, :invalid_correlation}}

        _ ->
          {:halt, {:error, :invalid_correlation}}
      end
    end)
  end

  defp numbers(measurements) do
    Enum.reduce_while(@measurements, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(measurements, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} when is_number(value) and value >= 0 and value <= 9_007_199_254_740_991 ->
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

        _ ->
          {:halt, {:error, :invalid_measurement}}
      end
    end)
  end

  defp timestamp(opts) do
    case Keyword.get(opts, :observed_at_unix_ms) do
      n when is_integer(n) and n >= 0 -> n
      _ -> System.system_time(:millisecond)
    end
  end
end
