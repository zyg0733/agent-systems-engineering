defmodule AgentSystemsLab.Storage.Intent do
  @moduledoc """
  A durable scheduling decision made in the same transaction as its event.

  `pending` describes work to be considered. A separate, expiring claim fences a
  worker's commits without changing this business status. Advancing the run
  supersedes the previous pending intent and revokes its claim.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "lab_intents" do
    field(:run_id, :string)
    field(:seq, :integer)
    field(:kind, :string)
    field(:status, :string, default: "pending")
    field(:payload, :binary)
    field(:codec_version, :integer, default: 1)
    field(:claim_token, Ecto.UUID)
    field(:claim_owner, :string)
    field(:claim_expires_at, :utc_datetime_usec)
    field(:claim_generation, :integer, default: 0)
    field(:available_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [:run_id, :seq, :kind, :status, :payload, :codec_version])
    |> validate_required([:run_id, :seq, :kind, :status, :payload, :codec_version])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:seq, name: :lab_intents_event_fkey)
    |> unique_constraint([:run_id, :seq], name: :lab_intents_run_id_seq_index)
    |> unique_constraint(:run_id, name: :lab_intents_one_pending_per_run)
    |> check_constraint(:seq, name: :lab_intents_positive_sequence)
    |> check_constraint(:kind, name: :lab_intents_valid_kind)
    |> check_constraint(:status, name: :lab_intents_valid_status)
    |> check_constraint(:codec_version, name: :lab_intents_codec_version)
  end
end
