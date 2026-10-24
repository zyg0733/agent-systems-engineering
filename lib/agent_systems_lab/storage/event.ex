defmodule AgentSystemsLab.Storage.Event do
  @moduledoc "An immutable, ordered kernel fact stored in PostgreSQL."
  use Ecto.Schema
  import Ecto.Changeset

  schema "lab_events" do
    field(:run_id, :string)
    field(:seq, :integer)
    field(:type, :string)
    field(:schema_version, :integer, default: 1)
    field(:data, :binary)
    field(:codec_version, :integer, default: 1)
    field(:history_format, :integer, default: 1)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :type, :schema_version, :data, :codec_version, :history_format])
    |> validate_required([:run_id, :seq, :type, :schema_version, :data, :codec_version])
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :seq], name: :lab_events_run_id_seq_index)
    |> check_constraint(:seq, name: :lab_events_positive_sequence)
    |> check_constraint(:type, name: :lab_events_valid_type)
    |> check_constraint(:schema_version, name: :lab_events_schema_version)
    |> check_constraint(:codec_version, name: :lab_events_codec_version)
    |> check_constraint(:history_format, name: :lab_events_history_format)
  end
end
