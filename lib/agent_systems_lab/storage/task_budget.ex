defmodule AgentSystemsLab.Storage.TaskBudget do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:run_id, :string, autogenerate: false}
  schema "lab_task_budgets" do
    field :schema_version, :integer, default: 1
    field :codec_version, :integer, default: 1
    field :config_data, :binary
    field :config_sha256, :string
    field :progress_data, :binary
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :run_id,
      :schema_version,
      :codec_version,
      :config_data,
      :config_sha256,
      :progress_data
    ])
    |> validate_required([
      :run_id,
      :schema_version,
      :codec_version,
      :config_data,
      :config_sha256,
      :progress_data
    ])
    |> unique_constraint(:run_id, name: :lab_task_budgets_pkey)
    |> foreign_key_constraint(:run_id)
  end
end
