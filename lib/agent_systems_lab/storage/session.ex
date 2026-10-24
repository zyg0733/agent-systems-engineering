defmodule AgentSystemsLab.Storage.Session do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "lab_sessions" do
    field(:version, :integer)
    field(:session_data, :binary)
    field(:codec_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:id, :version, :session_data, :codec_version])
    |> validate_required([:id, :version, :session_data, :codec_version])
    |> unique_constraint(:id, name: :lab_sessions_pkey)
    |> check_constraint(:version, name: :lab_sessions_valid_version)
    |> check_constraint(:codec_version, name: :lab_sessions_codec_version)
  end
end
