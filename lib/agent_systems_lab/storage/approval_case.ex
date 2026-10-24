defmodule AgentSystemsLab.Storage.ApprovalCase do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}
  schema "lab_approval_cases" do
    field :status, :string
    field :seq, :integer
    field :plan_data, :binary
    field :plan_sha256, :string
    field :progress_data, :binary
    field :deadline_at_ms, :integer
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    fields = [
      :id,
      :status,
      :seq,
      :plan_data,
      :plan_sha256,
      :progress_data,
      :deadline_at_ms,
      :schema_version,
      :codec_version
    ]

    row
    |> cast(attrs, fields)
    |> validate_required(fields)
    |> unique_constraint(:id, name: :lab_approval_cases_pkey)
  end
end
