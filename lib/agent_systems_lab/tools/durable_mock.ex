defmodule AgentSystemsLab.Tools.DurableMock do
  @moduledoc """
  A durable mock target with a separate idempotency ledger.

  The target's receipt commits before the runtime confirms it. This models a
  queryable external service; it is deliberately separate from lab_operations.
  Its database happens to be local to this lab. Callers must hold the Run row
  lock and validate their claim before calling either transactional function.
  """
  import Ecto.Query
  alias AgentSystemsLab.Context
  alias AgentSystemsLab.Storage.{Codec, MockEffect}

  def execute(repo, run_id, call, mode, opts \\ [])
      when mode in [:ok, :lost, :fail_before_effect] do
    if repo.in_transaction?() do
      case lookup(repo, run_id, call) do
        {:ok, receipt} ->
          {:ok, reply(receipt, mode)}

        :not_found ->
          cond do
            Keyword.get(opts, :attempt, 1) <= Keyword.get(opts, :transient_failures, 0) ->
              {:ok, {:error, %{kind: "transient", reason: "unavailable", effect: "none"}}}

            mode == :fail_before_effect ->
              {:ok, {:error, :failed_before_effect}}

            true ->
              insert(repo, run_id, call, mode)
          end

        error ->
          error
      end
    else
      {:error, :transaction_required}
    end
  end

  def lookup(repo, run_id, call) do
    if repo.in_transaction?(),
      do: lookup_in_transaction(repo, run_id, call),
      else: {:error, :transaction_required}
  end

  defp lookup_in_transaction(repo, run_id, call) do
    case repo.one(
           from row in MockEffect,
             where: row.run_id == ^run_id and row.operation_id == ^call.operation_id,
             lock: "FOR UPDATE"
         ) do
      nil -> :not_found
      row -> decode(row, run_id, call)
    end
  end

  defp insert(repo, run_id, call, mode) do
    input = Map.take(call, [:tool, :arguments])
    count = repo.aggregate(from(row in MockEffect, where: row.run_id == ^run_id), :count)

    receipt = %{
      operation_id: call.operation_id,
      arguments: call.arguments,
      effect_index: count + 1
    }

    with {:ok, input_data} <- Codec.encode(input),
         {:ok, receipt_data} <- Codec.encode(receipt),
         {:ok, _row} <-
           repo.insert(
             MockEffect.changeset(%MockEffect{}, %{
               run_id: run_id,
               operation_id: call.operation_id,
               tool: call.tool,
               input_sha256: Context.hash(input),
               input_data: input_data,
               receipt_data: receipt_data
             })
           ) do
      {:ok, reply(receipt, mode)}
    end
  end

  defp decode(row, run_id, call) do
    expected = Map.take(call, [:tool, :arguments])

    with true <- row.schema_version === 1,
         {:ok, input} <- Codec.decode(row.input_data, row.codec_version),
         true <-
           input === expected and row.run_id === run_id and
             row.operation_id === call.operation_id and row.tool === call.tool and
             row.input_sha256 === Context.hash(input),
         {:ok, receipt} <- Codec.decode(row.receipt_data, row.codec_version),
         %{operation_id: id, arguments: arguments, effect_index: index} <- receipt,
         true <-
           map_size(receipt) == 3 and id === call.operation_id and
             arguments === call.arguments and is_integer(index) and index > 0 do
      {:ok, receipt}
    else
      false -> {:error, :mock_effect_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_mock_receipt}
    end
  end

  defp reply(_receipt, :lost), do: {:unknown, :receipt_lost}
  defp reply(receipt, _mode), do: {:ok, receipt}
end
