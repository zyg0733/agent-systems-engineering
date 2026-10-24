defmodule AgentSystemsLab.Repo.Migrations.AddManualToolReconciliation do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE lab_attempts ADD COLUMN IF NOT EXISTS evidence text")
    drop constraint(:lab_attempts, :lab_attempts_valid_kind)

    create constraint(:lab_attempts, :lab_attempts_valid_kind,
             check: "kind IN ('execution', 'lookup', 'manual')"
           )
  end

  def down do
    drop constraint(:lab_attempts, :lab_attempts_valid_kind)

    create constraint(:lab_attempts, :lab_attempts_valid_kind,
             check: "kind IN ('execution', 'lookup')"
           )

    alter table(:lab_attempts), do: remove(:evidence)
  end
end
