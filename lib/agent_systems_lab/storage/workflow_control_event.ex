defmodule AgentSystemsLab.Storage.WorkflowControlEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "lab_workflow_control_events" do
    field :workflow_id, :string
    field :seq, :integer
    field :type, :string
    field :data, :binary
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    fields = [:workflow_id, :seq, :type, :data, :schema_version, :codec_version]

    row
    |> cast(attrs, fields)
    |> validate_required(fields)
    |> unique_constraint([:workflow_id, :seq])
    |> foreign_key_constraint(:workflow_id)
  end
end
