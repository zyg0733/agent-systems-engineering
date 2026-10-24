defmodule AgentSystemsLab.SessionStore do
  @moduledoc """
  Transactional canonical Session storage. Appends use a row lock and an expected
  version; compression never updates this table or erases the original messages.
  """
  import Ecto.Query

  alias AgentSystemsLab.{Repo, Session}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Storage.Session, as: StoredSession

  @spec create(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def create(session) do
    with :ok <- transaction_boundary(),
         :ok <- Session.validate(session),
         {:ok, data} <- Codec.encode(Session.to_map(session)) do
      attrs = %{
        id: session.id,
        version: session.version,
        session_data: data,
        codec_version: Codec.version()
      }

      case Repo.insert(StoredSession.changeset(%StoredSession{}, attrs)) do
        {:ok, _row} ->
          {:ok, session}

        {:error, changeset} ->
          if Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
               field == :id and opts[:constraint] == :unique
             end),
             do: {:error, {:already_exists, session.id}},
             else: {:error, changeset}
      end
    end
  end

  @spec load(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def load(id) do
    with :ok <- Session.validate_id(id) do
      case Repo.get(StoredSession, id) do
        nil -> {:error, :session_not_found}
        row -> decode_row(row)
      end
    end
  end

  @spec append(String.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def append(id, expected_version, role, content) do
    with :ok <- transaction_boundary(),
         :ok <- Session.validate_id(id),
         true <- is_integer(expected_version) and expected_version >= 0 do
      Repo.transaction(fn ->
        with {:ok, current} <- lock(id),
             :ok <- expected(current, expected_version),
             {:ok, next} <- Session.append(current, role, content),
             {:ok, encoded} <- Codec.encode(Session.to_map(next)),
             row <- Repo.get!(StoredSession, id),
             {:ok, _updated} <-
               Repo.update(
                 StoredSession.changeset(row, %{version: next.version, session_data: encoded})
               ) do
          next
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :invalid_session_version}
      error -> error
    end
  end

  @doc false
  def lock(id, mode \\ :update) do
    with :ok <- Session.validate_id(id),
         true <- mode in [:update, :share] do
      query = from(session in StoredSession, where: session.id == ^id)

      query =
        if mode == :share,
          do: from(session in query, lock: "FOR SHARE"),
          else: from(session in query, lock: "FOR UPDATE")

      case Repo.one(query) do
        nil -> {:error, :session_not_found}
        row -> decode_row(row)
      end
    else
      false -> {:error, :invalid_session_lock}
      error -> error
    end
  end

  @doc false
  def decode_row(row) do
    with {:ok, map} <- Codec.decode(row.session_data, row.codec_version),
         {:ok, session} <- Session.from_map(map),
         true <- row.id === session.id and row.version === session.version do
      {:ok, session}
    else
      false -> {:error, {:corrupt_session, :projection_mismatch}}
      {:error, reason} -> {:error, {:corrupt_session, reason}}
    end
  end

  defp expected(%{version: expected}, expected), do: :ok

  defp expected(session, expected),
    do: {:error, {:stale_session_version, expected, session.version}}

  defp transaction_boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end
end
