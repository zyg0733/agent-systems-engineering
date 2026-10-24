defmodule AgentSystemsLab.Storage.Queue do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  schema "lab_queues" do
    field :capacity, :integer
    field :max_inflight, :integer
    field :aging_ms, :integer
    field :starvation_ms, :integer
    field :scan_cursor, :integer, default: 0
    field :scan_ceiling, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:name, :capacity, :max_inflight, :aging_ms, :starvation_ms])
    |> validate_required([:name, :capacity, :max_inflight, :aging_ms, :starvation_ms])
    |> unique_constraint(:name, name: :lab_queues_pkey)
    |> check_constraint(:capacity, name: :lab_queues_valid_config)
  end
end
