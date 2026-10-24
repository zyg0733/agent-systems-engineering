defmodule AgentSystemsLab.RetryPolicy do
  @moduledoc "Bounded deterministic exponential retry eligibility, without sleeping or effects."

  @defaults %{
    schema_version: 1,
    max_attempts: 3,
    base_delay_ms: 100,
    max_delay_ms: 5000,
    max_elapsed_ms: 30_000,
    tool_timeout_ms: 1000
  }
  @keys Map.keys(@defaults)
  @day_ms 86_400_000

  def new(nil), do: {:ok, nil}

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq(Keyword.keys(opts))),
      do: new(Map.new(opts)),
      else: {:error, :invalid_retry_policy}
  end

  def new(opts) when is_map(opts) do
    if Map.keys(opts) -- @keys == [] do
      policy = Map.merge(@defaults, opts)
      with :ok <- validate(policy), do: {:ok, policy}
    else
      {:error, :invalid_retry_policy}
    end
  end

  def new(_), do: {:error, :invalid_retry_policy}

  def validate(policy) when is_map(policy) do
    cond do
      Enum.sort(Map.keys(policy)) !== Enum.sort(@keys) ->
        {:error, :invalid_retry_policy}

      policy.schema_version !== 1 ->
        {:error, {:unsupported_retry_policy_version, policy.schema_version}}

      not is_integer(policy.max_attempts) or policy.max_attempts not in 1..20 ->
        {:error, :invalid_retry_policy}

      not Enum.all?([:base_delay_ms, :max_delay_ms, :max_elapsed_ms, :tool_timeout_ms], fn key ->
        is_integer(policy[key]) and policy[key] in 1..@day_ms
      end) ->
        {:error, :invalid_retry_policy}

      policy.max_delay_ms < policy.base_delay_ms ->
        {:error, :invalid_retry_policy}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :invalid_retry_policy}

  def next(policy, attempts, first_ms, now_ms, deadline_ms \\ nil) do
    with :ok <- validate(policy),
         true <-
           (is_integer(attempts) and attempts > 0 and is_integer(first_ms) and
              first_ms > 0 and is_integer(now_ms) and now_ms >= first_ms and
              (is_nil(deadline_ms) or (is_integer(deadline_ms) and deadline_ms > 0))) ||
             {:error, :invalid_retry_clock} do
      delay = min(policy.max_delay_ms, policy.base_delay_ms * Integer.pow(2, attempts - 1))
      due = now_ms + delay

      cond do
        attempts >= policy.max_attempts -> {:exhausted, :attempts}
        not is_nil(deadline_ms) and due >= deadline_ms -> {:exhausted, :deadline}
        due >= first_ms + policy.max_elapsed_ms -> {:exhausted, :elapsed}
        true -> {:retry, due}
      end
    end
  end
end
