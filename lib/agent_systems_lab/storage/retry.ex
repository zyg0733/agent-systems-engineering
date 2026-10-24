defmodule AgentSystemsLab.Storage.Retry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "lab_retries" do
    field(:run_id, :string)
    field(:seq, :integer)
    field(:scope, :string)
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    field(:policy_data, :binary)
    field(:policy_sha256, :string)
    field(:state_data, :binary)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :run_id,
      :seq,
      :scope,
      :schema_version,
      :codec_version,
      :policy_data,
      :policy_sha256,
      :state_data
    ])
    |> validate_required([
      :run_id,
      :seq,
      :scope,
      :schema_version,
      :codec_version,
      :policy_data,
      :policy_sha256,
      :state_data
    ])
    |> unique_constraint([:run_id, :seq, :scope])
    |> foreign_key_constraint(:run_id)
  end
end
