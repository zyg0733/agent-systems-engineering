defmodule AgentSystemsLab.Storage.Workflow do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  schema "lab_workflows" do
    field :status, :string
    field :seq, :integer
    field :queue_name, :string
    field :definition_data, :binary
    field :definition_sha256, :string
    field :progress_data, :binary
    field :deadline_at_ms, :integer
    field :control_owner_case_id, :string
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    fields = [
      :id,
      :status,
      :seq,
      :queue_name,
      :definition_data,
      :definition_sha256,
      :progress_data,
      :deadline_at_ms,
      :control_owner_case_id,
      :schema_version,
      :codec_version
    ]

    row
    |> cast(attrs, fields)
    |> validate_required(fields -- [:control_owner_case_id])
    |> unique_constraint(:id, name: :lab_workflows_pkey)
  end
end
