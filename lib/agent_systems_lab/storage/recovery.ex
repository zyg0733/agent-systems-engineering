defmodule AgentSystemsLab.Storage.Recovery do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:run_id, :string, autogenerate: false}
  schema "lab_recovery" do
    field(:schema_version, :integer, default: 1)
    field(:codec_version, :integer, default: 1)
    field(:config_data, :binary)
    field(:config_sha256, :string)
    field(:progress_data, :binary)
    field(:retry_config_data, :binary)
    field(:retry_config_sha256, :string)
    field(:isolation_policy_data, :binary)
    field(:isolation_policy_sha256, :string)
    field(:mcp_policy_data, :binary)
    field(:mcp_policy_sha256, :string)
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
      :progress_data,
      :retry_config_data,
      :retry_config_sha256,
      :isolation_policy_data,
      :isolation_policy_sha256,
      :mcp_policy_data,
      :mcp_policy_sha256
    ])
    |> validate_required([
      :run_id,
      :schema_version,
      :codec_version,
      :config_data,
      :config_sha256,
      :progress_data
    ])
    |> unique_constraint(:run_id, name: :lab_recovery_pkey)
    |> foreign_key_constraint(:run_id)
  end
end
