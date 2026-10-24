defmodule AgentSystemsLab.Tools.Mock do
  @moduledoc """
  An isolated, in-memory mock business system with an operation ledger.

  Each operation ID can produce at most one effect in a server's lifetime.
  Reusing an ID with different arguments fails. This process deliberately owns
  a separate ledger from the runtime so tests can observe a completed effect
  even when its reply was lost. The ledger is **not durable**: stopping or
  resetting the process removes it.

  The `:response` option selects a deterministic fault:

    * `:ok` returns the receipt (the default).
    * `:lost` commits the effect but returns `{:unknown, :receipt_lost}`.
    * `:fail_before_effect` returns an error without creating an effect.

  `stats/1` counts validated execute requests, including retries and conflicts,
  and business effects. Lookups do not increment either counter.
  """

  use GenServer

  @type receipt :: %{
          operation_id: String.t(),
          arguments: map(),
          effect_index: pos_integer()
        }

  @doc "Starts a fresh ledger. Pass `name: ...` only when a registered name is needed."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc "Executes or deduplicates one operation with a caller-supplied stable ID."
  @spec execute(GenServer.server(), term(), term(), term()) ::
          {:ok, receipt()} | {:error, term()} | {:unknown, term()}
  def execute(server, operation_id, arguments, opts \\ []) do
    GenServer.call(server, {:execute, operation_id, arguments, opts})
  end

  @doc "Returns a recorded receipt, or `:not_found` for an uncommitted operation."
  @spec lookup(GenServer.server(), term()) :: {:ok, receipt()} | :not_found | {:error, term()}
  def lookup(server, operation_id), do: GenServer.call(server, {:lookup, operation_id})

  @spec stats(GenServer.server()) :: %{requests: non_neg_integer(), effects: non_neg_integer()}
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Clears only this server's volatile ledger and counters."
  @spec reset(GenServer.server()) :: :ok
  def reset(server), do: GenServer.call(server, :reset)

  @impl true
  def init(:ok), do: {:ok, empty_state()}

  @impl true
  def handle_call({:execute, id, arguments, opts}, _from, state) do
    case validate_request(id, arguments, opts) do
      {:ok, mode} ->
        execute_valid(id, arguments, mode, %{state | requests: state.requests + 1})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, id}, _from, state) when is_binary(id) and byte_size(id) > 0 do
    reply =
      case Map.fetch(state.ledger, id) do
        {:ok, receipt} -> {:ok, receipt}
        :error -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup, _id}, _from, state) do
    {:reply, {:error, :invalid_operation_id}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:requests, :effects]), state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

  defp execute_valid(id, arguments, mode, state) do
    case Map.fetch(state.ledger, id) do
      {:ok, %{arguments: previous_arguments} = receipt} when previous_arguments === arguments ->
        {:reply, receipt_reply(receipt, mode), state}

      {:ok, _receipt} ->
        {:reply, {:error, :operation_id_conflict}, state}

      :error when mode == :fail_before_effect ->
        {:reply, {:error, :failed_before_effect}, state}

      :error ->
        receipt = %{operation_id: id, arguments: arguments, effect_index: state.effects + 1}
        next = %{state | ledger: Map.put(state.ledger, id, receipt), effects: state.effects + 1}
        {:reply, receipt_reply(receipt, mode), next}
    end
  end

  defp receipt_reply(_receipt, :lost), do: {:unknown, :receipt_lost}
  defp receipt_reply(receipt, _mode), do: {:ok, receipt}

  defp validate_request(id, arguments, opts) do
    cond do
      not (is_binary(id) and byte_size(id) > 0) ->
        {:error, :invalid_operation_id}

      not is_map(arguments) ->
        {:error, :invalid_arguments}

      not (is_list(opts) and Keyword.keyword?(opts)) ->
        {:error, :invalid_options}

      Keyword.keys(opts) -- [:response] != [] ->
        {:error, :invalid_options}

      Keyword.get(opts, :response, :ok) not in [:ok, :lost, :fail_before_effect] ->
        {:error, :invalid_response_mode}

      true ->
        {:ok, Keyword.get(opts, :response, :ok)}
    end
  end

  defp empty_state, do: %{ledger: %{}, requests: 0, effects: 0}
end
