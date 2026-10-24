defmodule AgentSystemsLab.DatabaseError do
  @moduledoc "Classifies lost database authority without authorizing business-effect retries."

  def unavailable?({:error, reason}), do: unavailable?(reason)
  def unavailable?({:exception, DBConnection.ConnectionError, _}), do: true
  def unavailable?({:database_unavailable, _, _}), do: true
  def unavailable?({:database_timeout, _}), do: true
  def unavailable?({:lease_lost, reason}), do: unavailable?(reason)
  def unavailable?({:claim_next, reason}), do: unavailable?(reason)
  def unavailable?({:worker_start, reason}), do: unavailable?(reason)
  def unavailable?({:exit, {:noproc, _}}), do: true
  def unavailable?(_), do: false

  @doc false
  def protect(fun) do
    try do
      fun.()
    rescue
      error in DBConnection.ConnectionError ->
        {:error, {:database_unavailable, :connection, Exception.message(error)}}

      error in Postgrex.Error ->
        if postgres_unavailable?(error),
          do: {:error, {:database_unavailable, :postgres, Exception.message(error)}},
          else: reraise(error, __STACKTRACE__)
    end
  end

  def postgres_unavailable?(%Postgrex.Error{postgres: nil}), do: true

  def postgres_unavailable?(%Postgrex.Error{postgres: fields}) do
    code = Map.get(fields, :pg_code, "")
    String.starts_with?(code, "08") or code in ["57P01", "57P02", "57P03", "53300"]
  end
end
