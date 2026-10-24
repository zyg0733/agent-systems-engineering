defmodule AgentSystemsLab.Repo.Migrations.AddIntentClaims do
  use Ecto.Migration

  def change do
    alter table(:lab_intents) do
      add(:claim_token, :uuid)
      add(:claim_owner, :text)
      add(:claim_expires_at, :utc_datetime_usec)
      add(:claim_generation, :bigint, null: false, default: 0)
    end

    create(
      constraint(:lab_intents, :lab_intents_claim_generation, check: "claim_generation >= 0")
    )

    create(
      constraint(:lab_intents, :lab_intents_complete_claim,
        check:
          "(claim_token IS NULL AND claim_owner IS NULL AND claim_expires_at IS NULL) OR " <>
            "(claim_token IS NOT NULL AND claim_owner IS NOT NULL AND claim_expires_at IS NOT NULL AND length(claim_owner) > 0)"
      )
    )
  end
end
