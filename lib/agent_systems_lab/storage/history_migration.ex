defmodule AgentSystemsLab.Storage.HistoryMigration do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:run_id, :string, autogenerate: false}
  schema "lab_history_migrations" do
    field(:source_format, :integer)
    field(:target_format, :integer)
    field(:prefix_seq, :integer)
    field(:event_count, :integer)
    field(:source_hash, :string)
    field(:target_hash, :string)
    field(:semantic_hash, :string)
    field(:codec_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :run_id,
      :source_format,
      :target_format,
      :prefix_seq,
      :event_count,
      :source_hash,
      :target_hash,
      :semantic_hash,
      :codec_version
    ])
    |> validate_required([
      :run_id,
      :source_format,
      :target_format,
      :prefix_seq,
      :event_count,
      :source_hash,
      :target_hash,
      :semantic_hash,
      :codec_version
    ])
    |> foreign_key_constraint(:run_id)
    |> unique_constraint(:run_id, name: :lab_history_migrations_pkey)
    |> check_constraint(:target_format, name: :lab_history_migrations_supported_transition)
    |> check_constraint(:prefix_seq, name: :lab_history_migrations_valid_prefix)
    |> check_constraint(:source_hash, name: :lab_history_migrations_valid_hashes)
  end
end
