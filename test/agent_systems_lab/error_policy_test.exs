defmodule AgentSystemsLab.ErrorPolicyTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.{ErrorPolicy, RetryPolicy}
  alias AgentSystemsLab.Storage.Codec

  test "recognized transient model errors and request timeouts are eligible" do
    for reason <- [:rate_limited, :econnreset, {:http_status, 503}, {:provider_exit, :killed}] do
      assert %{class: :transient, retryable: true, effect: :none} = ErrorPolicy.classify(reason)
    end

    assert %{class: :timeout, retryable: true} =
             ErrorPolicy.classify({:budget_exceeded, :model_timeout})
  end

  test "global budgets, schema and authorization errors never retry" do
    for reason <- [
          {:budget_exceeded, :run_timeout},
          {:budget_exceeded, :output_bytes},
          :turn_budget_exceeded,
          :invalid_schema,
          :permission_denied,
          :novel_error
        ] do
      assert %{class: :permanent, retryable: false} = ErrorPolicy.classify(reason)
    end
  end

  test "claim conflicts and cancellation never retry" do
    assert %{class: :cancelled, retryable: false} = ErrorPolicy.classify(:user_requested)

    for reason <- [:stale_claim, :claim_expired, {:stale_sequence, 1, 2}] do
      assert %{class: :conflict, retryable: false} = ErrorPolicy.classify(reason)
    end
  end

  test "ambiguous non-idempotent tool failure requires reconciliation" do
    for reason <- [:timeout, :econnreset, {:unknown, :receipt_lost}] do
      assert %{class: :unknown, retryable: false} =
               ErrorPolicy.classify(reason, scope: :tool, idempotent?: false, effect: :possible)
    end

    assert %{class: :timeout, retryable: true} =
             ErrorPolicy.classify(:timeout, scope: :tool, idempotent?: true)

    assert %{class: :transient, retryable: true} =
             ErrorPolicy.classify(:fail_before_effect,
               scope: :tool,
               idempotent?: false,
               effect: :none
             )
  end

  test "confirmed effects and unknown lookup outcomes cannot be retried" do
    assert %{retryable: false} =
             ErrorPolicy.classify(:econnreset,
               scope: :tool,
               idempotent?: true,
               effect: :confirmed
             )

    assert %{class: :unknown, retryable: false} =
             ErrorPolicy.classify(:receipt_unconfirmed, scope: :reconcile, idempotent?: true)
  end

  test "persisted classifications are inert and reject forged retry eligibility" do
    failure = ErrorPolicy.classify(fn -> :never_persist end)
    assert {:unpersistable_failure, text} = failure.reason
    assert is_binary(text)
    assert {:ok, _} = Codec.encode(failure)
    assert :ok = ErrorPolicy.validate(failure)

    assert {:error, :invalid_failure_classification} =
             ErrorPolicy.validate(%{failure | class: :transient, retryable: true})

    assert {:error, :invalid_failure_classification} =
             ErrorPolicy.validate(Map.put(failure, :extra, true))
  end

  test "retry policy is optional, strict and bounded" do
    assert {:ok, nil} = RetryPolicy.new(nil)
    assert {:ok, p} = RetryPolicy.new([])
    assert p.max_attempts == 3
    assert :ok = RetryPolicy.validate(p)

    for opts <- [
          [max_attempts: 0],
          [max_attempts: 21],
          [base_delay_ms: 0],
          [base_delay_ms: 200, max_delay_ms: 100],
          [max_elapsed_ms: 86_400_001],
          [tool_timeout_ms: 1.0],
          [unknown: 1],
          [max_attempts: 2, max_attempts: 3]
        ] do
      assert {:error, _} = RetryPolicy.new(opts)
    end

    assert {:error, {:unsupported_retry_policy_version, 2}} =
             RetryPolicy.validate(%{p | schema_version: 2})
  end

  test "backoff doubles, caps, and exhausts at exact elapsed and run deadlines" do
    assert {:ok, p} =
             RetryPolicy.new(
               max_attempts: 6,
               base_delay_ms: 100,
               max_delay_ms: 250,
               max_elapsed_ms: 10_000
             )

    assert {:retry, 1100} = RetryPolicy.next(p, 1, 1000, 1000)
    assert {:retry, 1300} = RetryPolicy.next(p, 2, 1000, 1100)
    assert {:retry, 1550} = RetryPolicy.next(p, 3, 1000, 1300)
    assert {:exhausted, :attempts} = RetryPolicy.next(p, 6, 1000, 2000)
    assert {:exhausted, :deadline} = RetryPolicy.next(p, 1, 1000, 1000, 1100)
    assert {:exhausted, :elapsed} = RetryPolicy.next(p, 1, 1000, 10_900)
    assert {:error, :invalid_retry_clock} = RetryPolicy.next(p, 0, 1000, 1000)
  end
end
