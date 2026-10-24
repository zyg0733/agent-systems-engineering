defmodule AgentSystemsLab.Storage.WorkflowNode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  schema "lab_workflow_nodes" do
    field :workflow_id, :string, primary_key: true
    field :node_id, :string, primary_key: true
    field :run_id, :string
    field :status, :string
    field :data, :binary
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    fields = [:workflow_id, :node_id, :run_id, :status, :data, :schema_version, :codec_version]
    row |> cast(attrs, fields) |> validate_required(fields) |> unique_constraint(:run_id)
  end
end
