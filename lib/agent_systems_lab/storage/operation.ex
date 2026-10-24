defmodule AgentSystemsLab.Storage.Operation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "lab_operations" do
    field(:run_id, :string)
    field(:operation_id, :string)
    field(:tool, :string)
    field(:input_sha256, :string)
    field(:input_data, :binary)
    field(:status, :string)
    field(:result_data, :binary)
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :id,
      :run_id,
      :operation_id,
      :tool,
      :input_sha256,
      :input_data,
      :status,
      :result_data,
      :schema_version,
      :codec_version
    ])
    |> validate_required([
      :run_id,
      :operation_id,
      :tool,
      :input_sha256,
      :input_data,
      :status,
      :schema_version,
      :codec_version
    ])
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :operation_id])
    |> check_constraint(:status, name: :lab_operations_valid_status)
    |> check_constraint(:schema_version, name: :lab_operations_schema_version)
    |> check_constraint(:codec_version, name: :lab_operations_codec_version)
  end
end
