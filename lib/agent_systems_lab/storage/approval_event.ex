defmodule AgentSystemsLab.Storage.ApprovalEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "lab_approval_events" do
    field :case_id, :string
    field :seq, :integer
    field :type, :string
    field :data, :binary
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    fields = [:case_id, :seq, :type, :data, :schema_version, :codec_version]

    row
    |> cast(attrs, fields)
    |> validate_required(fields)
    |> unique_constraint([:case_id, :seq])
  end
end
