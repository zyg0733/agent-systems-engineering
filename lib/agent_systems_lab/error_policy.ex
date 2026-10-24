defmodule AgentSystemsLab.ErrorPolicy do
  @moduledoc """
  Conservative, inert failure classification for explicit recovery.

  Classification grants eligibility, never permission to repeat an ambiguous
  effect. Unknown errors are permanent; a possibly applied non-idempotent tool
  failure requires reconciliation. Limits and durable due times remain the
  responsibility of RetryPolicy and RetryStore.
  """
  alias AgentSystemsLab.Storage.Codec

  @keys ~w(schema_version class scope idempotent? effect retryable reason)a
  @classes [:transient, :permanent, :timeout, :conflict, :cancelled, :unknown]
  @scopes [:model, :tool, :reconcile]
  @effects [:none, :possible, :confirmed]

  def classify(reason, opts \\ []) do
    scope = Keyword.get(opts, :scope, :model)
    idempotent = Keyword.get(opts, :idempotent?, scope == :model)
    effect = Keyword.get(opts, :effect, if(scope == :model, do: :none, else: :possible))

    if scope not in @scopes or not is_boolean(idempotent) or effect not in @effects,
      do: raise(ArgumentError, "invalid error classification options")

    reason = sanitize(reason)
    {class, retryable} = category(reason)

    {class, retryable} =
      cond do
        scope != :model and effect == :possible and not idempotent and
            class in [:transient, :timeout, :unknown] ->
          {:unknown, false}

        effect == :confirmed ->
          {class, false}

        true ->
          {class, retryable}
      end

    %{
      schema_version: 1,
      class: class,
      scope: scope,
      idempotent?: idempotent,
      effect: effect,
      retryable: retryable,
      reason: reason
    }
  end

  def validate(value) when is_map(value) do
    if Enum.sort(Map.keys(value)) === Enum.sort(@keys) and value.schema_version === 1 and
         value.class in @classes and value.scope in @scopes and
         is_boolean(value.idempotent?) and value.effect in @effects and
         is_boolean(value.retryable) and
         (not value.retryable or value.class in [:transient, :timeout]) and
         (not value.retryable or value.effect != :confirmed) and
         (not value.retryable or value.scope == :model or value.idempotent? or
            value.effect == :none) do
      expected =
        classify(value.reason,
          scope: value.scope,
          idempotent?: value.idempotent?,
          effect: value.effect
        )

      case Codec.encode(value) do
        {:ok, data} when byte_size(data) <= 16_384 and value === expected -> :ok
        _ -> {:error, :invalid_failure_classification}
      end
    else
      {:error, :invalid_failure_classification}
    end
  end

  def validate(_), do: {:error, :invalid_failure_classification}

  defp category({:error, reason}), do: category(reason)
  defp category({:provider_error, reason}), do: category(reason)
  defp category({:provider_exit, _}), do: {:transient, true}
  defp category({:abandoned_attempt, :model}), do: {:transient, true}
  defp category({:abandoned_attempt, :reconcile}), do: {:transient, true}
  defp category({:abandoned_attempt, _}), do: {:unknown, false}
  defp category({:budget_exceeded, :model_timeout}), do: {:timeout, true}
  defp category({:budget_exceeded, _}), do: {:permanent, false}
  defp category({:unknown, _}), do: {:unknown, false}

  defp category({:http_status, status}) when status == 429 or status in 500..599,
    do: {:transient, true}

  defp category({:stale_sequence, _, _}), do: {:conflict, false}

  defp category(reason) when reason in [:timeout, :model_timeout, :tool_timeout, :lookup_timeout],
    do: {:timeout, true}

  defp category(reason) when reason in [:cancelled, :canceled, :user_requested],
    do: {:cancelled, false}

  defp category(reason)
       when reason in [
              :stale_claim,
              :claim_expired,
              :invalid_claim,
              :intent_claimed,
              :stale_model_attempt,
              :operation_id_conflict,
              :confirmed_receipt_conflict
            ],
       do: {:conflict, false}

  defp category(reason)
       when reason in [:receipt_unconfirmed, :reconciliation_required, :unknown],
       do: {:unknown, false}

  defp category(reason)
       when reason in [
              :transient,
              :rate_limited,
              :unavailable,
              :service_unavailable,
              :temporarily_unavailable,
              :econnrefused,
              :econnreset,
              :closed,
              :fail_before_effect
            ],
       do: {:transient, true}

  defp category(_), do: {:permanent, false}

  defp sanitize(reason) do
    case Codec.encode(reason) do
      {:ok, data} when byte_size(data) <= 8192 -> reason
      _ -> {:unpersistable_failure, inspect(reason, limit: 10, printable_limit: 512)}
    end
  end
end
