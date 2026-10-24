defmodule AgentSystemsLab.Repo.Migrations.AddTimeoutObservations do
  use Ecto.Migration

  def up do
    drop constraint(:lab_attempts, :lab_attempts_valid_kind)

    create constraint(:lab_attempts, :lab_attempts_valid_kind,
             check: "kind IN ('execution', 'lookup', 'manual', 'observation')"
           )
  end

  def down do
    drop constraint(:lab_attempts, :lab_attempts_valid_kind)

    create constraint(:lab_attempts, :lab_attempts_valid_kind,
             check: "kind IN ('execution', 'lookup', 'manual')"
           )
  end
end
