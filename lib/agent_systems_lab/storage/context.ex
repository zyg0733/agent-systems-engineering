defmodule AgentSystemsLab.Storage.Context do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "lab_contexts" do
    field(:run_id, :string)
    field(:run_seq, :integer)
    field(:session_id, :string)
    field(:session_version, :integer)
    field(:codec_version, :integer, default: 1)
    field(:sources_data, :binary)
    field(:payload_data, :binary)
    field(:manifest_data, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(context, attrs) do
    context
    |> cast(attrs, [
      :id,
      :run_id,
      :run_seq,
      :session_id,
      :session_version,
      :codec_version,
      :sources_data,
      :payload_data,
      :manifest_data
    ])
    |> validate_required([
      :run_id,
      :run_seq,
      :session_version,
      :codec_version,
      :sources_data,
      :payload_data,
      :manifest_data
    ])
    |> unique_constraint(:id, name: :lab_contexts_pkey)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:run_seq, name: :lab_contexts_valid_run_seq)
    |> check_constraint(:session_version, name: :lab_contexts_valid_session_version)
    |> check_constraint(:codec_version, name: :lab_contexts_codec_version)
  end
end
