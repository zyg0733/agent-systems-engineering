defmodule AgentSystemsLab.Storage.ModelResult do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "lab_model_results" do
    field(:context_id, Ecto.UUID)
    field(:run_id, :string)
    field(:input_seq, :integer)
    field(:event_seq, :integer)
    field(:provider, :string)
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    field(:record_data, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :id,
      :context_id,
      :run_id,
      :input_seq,
      :event_seq,
      :provider,
      :schema_version,
      :codec_version,
      :record_data
    ])
    |> validate_required([
      :context_id,
      :run_id,
      :input_seq,
      :event_seq,
      :provider,
      :schema_version,
      :codec_version,
      :record_data
    ])
    |> unique_constraint(:id, name: :lab_model_results_pkey)
    |> unique_constraint(:context_id)
    |> unique_constraint([:run_id, :event_seq])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:run_id, name: :lab_model_results_event_fkey)
    |> foreign_key_constraint(:context_id)
    |> check_constraint(:event_seq, name: :lab_model_results_valid_sequence)
    |> check_constraint(:schema_version, name: :lab_model_results_schema_version)
    |> check_constraint(:codec_version, name: :lab_model_results_codec_version)
  end
end
