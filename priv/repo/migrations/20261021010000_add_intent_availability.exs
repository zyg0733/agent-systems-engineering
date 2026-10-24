defmodule AgentSystemsLab.Repo.Migrations.AddIntentAvailability do
  use Ecto.Migration

  def change do
    alter table(:lab_intents) do
      add(:available_at, :utc_datetime_usec)
    end

    create(index(:lab_intents, [:available_at, :id], where: "status = 'pending'"))

    alter table(:lab_runs) do
      add(:priority, :integer, null: false, default: 0)
    end

    create(constraint(:lab_runs, :lab_runs_valid_priority, check: "priority BETWEEN 0 AND 9"))
    create(index(:lab_runs, [:priority, :id], where: "status IN ('running', 'waiting_tool')"))
  end
end
