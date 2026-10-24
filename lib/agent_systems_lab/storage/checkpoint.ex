defmodule AgentSystemsLab.Storage.Checkpoint do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "lab_checkpoints" do
    field(:run_id, :string)
    field(:last_seq, :integer)
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    field(:data, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:run_id, :last_seq, :schema_version, :codec_version, :data])
    |> validate_required([:run_id, :last_seq, :schema_version, :codec_version, :data])
    |> unique_constraint([:run_id, :last_seq])
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:last_seq, name: :lab_checkpoints_valid_seq)
    |> check_constraint(:schema_version, name: :lab_checkpoints_schema_version)
    |> check_constraint(:codec_version, name: :lab_checkpoints_codec_version)
  end
end
