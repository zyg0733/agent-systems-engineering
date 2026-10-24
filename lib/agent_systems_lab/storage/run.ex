defmodule AgentSystemsLab.Storage.Run do
  @moduledoc "The transactionally updated projection of a durable kernel run."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "lab_runs" do
    field(:status, :string)
    field(:seq, :integer)
    field(:max_turns, :integer)
    field(:turn_count, :integer)
    field(:priority, :integer, default: 0)
    field(:queue_name, :string)
    field(:workflow_id, :string)
    field(:workflow_node_id, :string)
    field(:state_data, :binary)
    field(:codec_version, :integer, default: 1)
    field(:history_format, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :status,
      :seq,
      :max_turns,
      :turn_count,
      :priority,
      :queue_name,
      :workflow_id,
      :workflow_node_id,
      :state_data,
      :codec_version,
      :history_format
    ])
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> check_constraint(:priority, name: :lab_runs_valid_priority)
    |> foreign_key_constraint(:queue_name)
    |> validate_required([
      :id,
      :status,
      :seq,
      :max_turns,
      :turn_count,
      :state_data,
      :codec_version
    ])
    |> unique_constraint(:id, name: :lab_runs_pkey)
    |> check_constraint(:seq, name: :lab_runs_valid_sequence)
    |> check_constraint(:status, name: :lab_runs_valid_status)
    |> check_constraint(:max_turns, name: :lab_runs_valid_budget)
    |> check_constraint(:codec_version, name: :lab_runs_codec_version)
    |> check_constraint(:history_format, name: :lab_runs_history_format)
  end
end
