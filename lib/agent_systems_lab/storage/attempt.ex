defmodule AgentSystemsLab.Storage.Attempt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "lab_attempts" do
    field(:operation_record_id, Ecto.UUID)
    field(:run_id, :string)
    field(:operation_id, :string)
    field(:claim_generation, :integer)
    field(:claim_data, :binary)
    field(:kind, :string)
    field(:outcome, :string)
    field(:result_data, :binary)
    field(:evidence, :string)
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :id,
      :operation_record_id,
      :run_id,
      :operation_id,
      :claim_generation,
      :claim_data,
      :kind,
      :outcome,
      :result_data,
      :evidence,
      :schema_version,
      :codec_version
    ])
    |> validate_required([
      :operation_record_id,
      :run_id,
      :operation_id,
      :claim_generation,
      :claim_data,
      :kind,
      :outcome,
      :schema_version,
      :codec_version
    ])
    |> foreign_key_constraint(:operation_record_id)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:kind, name: :lab_attempts_valid_kind)
    |> check_constraint(:outcome, name: :lab_attempts_valid_outcome)
  end
end
