defmodule AgentSystemsLab.Storage.WorkflowControl do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:workflow_id, :string, autogenerate: false}
  schema "lab_workflow_controls" do
    field :owner_case_id, :string
    field :status, :string
    field :seq, :integer
    field :data, :binary
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :workflow_id,
      :owner_case_id,
      :status,
      :seq,
      :data,
      :schema_version,
      :codec_version
    ])
    |> validate_required([:workflow_id, :status, :seq, :data, :schema_version, :codec_version])
    |> unique_constraint(:workflow_id, name: :lab_workflow_controls_pkey)
    |> foreign_key_constraint(:workflow_id)
  end
end
