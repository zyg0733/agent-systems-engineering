defmodule AgentSystemsLab.CheckpointStore do
  @moduledoc """
  Immutable PostgreSQL checkpoints, verified against the authoritative journal.

  Creation holds the run's shared lock through a real COMMIT. Loads audit the
  complete original prefix, so this first implementation deliberately makes no
  checkpoint replay performance claim. A corrupt latest checkpoint fails closed
  rather than silently selecting an older row. These APIs perform no execution.
  """
  import Ecto.Query
  alias AgentSystemsLab.{Checkpoint, History, Repo, Storage}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Storage.Checkpoint, as: StoredCheckpoint

  def create(run_id, expected_seq, opts \\ []) do
    with :ok <- transaction_boundary(),
         :ok <- options(opts, [:hook]),
         :ok <- valid_seq(expected_seq) do
      result =
        Repo.transaction(fn ->
          with {:ok, snapshot} <- Storage.load(run_id),
               :ok <- current_seq(snapshot.state.seq, expected_seq),
               {:ok, checkpoint} <-
                 Checkpoint.new(run_id, snapshot.events, max_turns: snapshot.state.max_turns),
               {:ok, data} <- Codec.encode(checkpoint),
               {:ok, row} <-
                 Repo.insert(
                   StoredCheckpoint.changeset(%StoredCheckpoint{}, %{
                     run_id: run_id,
                     last_seq: expected_seq,
                     schema_version: 1,
                     codec_version: Codec.version(),
                     data: data
                   })
                 ) do
            hook(opts, :before_commit)
            captured(row, checkpoint)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, _value} ->
          hook(opts, :after_commit)
          result

        {:error, %Ecto.Changeset{} = changeset} ->
          if Keyword.has_key?(changeset.errors, :run_id),
            do: {:error, {:checkpoint_already_exists, run_id, expected_seq}},
            else: result

        _ ->
          result
      end
    end
  end

  def load(id) do
    with {:ok, id} <- valid_uuid(id) do
      Repo.transaction(fn ->
        case Repo.get(StoredCheckpoint, id) do
          nil ->
            Repo.rollback(:checkpoint_not_found)

          row ->
            with {:ok, snapshot} <- Storage.load(row.run_id),
                 {:ok, checkpoint} <- decode_row(row, snapshot) do
              checkpoint
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
    end
  end

  def latest(run_id) do
    Repo.transaction(fn ->
      with {:ok, snapshot} <- Storage.load(run_id),
           {:ok, checkpoint} <- latest_row(run_id, snapshot) do
        checkpoint
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def rebuild(run_id, opts \\ []) do
    with :ok <- options(opts, [:mode]),
         mode = Keyword.get(opts, :mode, :checkpoint),
         :ok <- valid_mode(mode) do
      Repo.transaction(fn ->
        with {:ok, snapshot} <- Storage.load(run_id),
             {:ok, result} <- rebuild_snapshot(snapshot, mode) do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp rebuild_snapshot(snapshot, :full),
    do: {:ok, Map.put(snapshot, :audit, full_audit(snapshot))}

  defp rebuild_snapshot(snapshot, :checkpoint) do
    with {:ok, captured} <- latest_row(snapshot.state.run_id, snapshot) do
      case captured do
        nil ->
          rebuild_snapshot(snapshot, :full)

        %{id: id, checkpoint: checkpoint} ->
          tail = Enum.drop(snapshot.events, checkpoint.last_seq)

          with {:ok, state} <- History.from_checkpoint(checkpoint, tail),
               true <- state === snapshot.state do
            {:ok,
             Map.put(snapshot, :audit, %{
               mode: :checkpoint,
               checkpoint_id: id,
               checkpoint_seq: checkpoint.last_seq,
               verified_prefix_events: checkpoint.last_seq,
               replayed_tail_events: length(tail)
             })}
          else
            false -> {:error, {:corrupt_checkpoint, :projection_mismatch}}
            error -> error
          end
      end
    end
  end

  defp latest_row(run_id, snapshot) do
    case Repo.one(
           from(c in StoredCheckpoint,
             where: c.run_id == ^run_id,
             order_by: [desc: c.last_seq],
             limit: 1
           )
         ) do
      nil -> {:ok, nil}
      row -> decode_row(row, snapshot)
    end
  end

  defp decode_row(row, snapshot) do
    Storage.preload_vocabulary()

    with :ok <- schema_version(row.schema_version),
         {:ok, checkpoint} <- Codec.decode(row.data, row.codec_version),
         :ok <- Checkpoint.validate(checkpoint),
         true <-
           row.run_id === snapshot.state.run_id and row.run_id === checkpoint.run_id and
             row.last_seq === checkpoint.last_seq and
             row.schema_version === checkpoint.schema_version and
             checkpoint.max_turns === snapshot.state.max_turns and
             row.last_seq <= snapshot.state.seq,
         :ok <- Checkpoint.verify(checkpoint, Enum.take(snapshot.events, row.last_seq)) do
      {:ok, captured(row, checkpoint)}
    else
      false -> {:error, {:corrupt_checkpoint, :metadata_mismatch}}
      {:error, reason} -> {:error, {:corrupt_checkpoint, reason}}
    end
  end

  defp captured(row, checkpoint),
    do: %{id: row.id, run_id: row.run_id, last_seq: row.last_seq, checkpoint: checkpoint}

  defp full_audit(snapshot),
    do: %{
      mode: :full,
      checkpoint_id: nil,
      checkpoint_seq: nil,
      verified_prefix_events: length(snapshot.events),
      replayed_tail_events: 0
    }

  defp current_seq(seq, seq), do: :ok
  defp current_seq(actual, expected), do: {:error, {:stale_sequence, expected, actual}}
  defp valid_seq(seq) when is_integer(seq) and seq >= 0, do: :ok
  defp valid_seq(seq), do: {:error, {:invalid_expected_sequence, seq}}
  defp valid_mode(mode) when mode in [:full, :checkpoint], do: :ok
  defp valid_mode(mode), do: {:error, {:invalid_rebuild_mode, mode}}
  defp schema_version(1), do: :ok
  defp schema_version(version), do: {:error, {:unsupported_checkpoint_schema_version, version}}

  defp valid_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_checkpoint_id}
    end
  end

  defp transaction_boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end

  defp options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(Keyword.get(opts, :hook)) or is_function(Keyword.get(opts, :hook), 1)),
       do: :ok,
       else: {:error, {:invalid_checkpoint_options, opts}}
  end

  defp options(opts, _allowed), do: {:error, {:invalid_checkpoint_options, opts}}

  defp hook(opts, stage) do
    case Keyword.get(opts, :hook) do
      nil -> :ok
      callback -> callback.(stage)
    end
  end
end
