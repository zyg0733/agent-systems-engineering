defmodule AgentSystemsLab.Repo.Migrations.CreateBoundedQueues do
  use Ecto.Migration

  def change do
    create table(:lab_queues, primary_key: false) do
      add :name, :text, primary_key: true
      add :capacity, :integer, null: false
      add :max_inflight, :integer, null: false
      add :aging_ms, :integer, null: false
      add :starvation_ms, :integer, null: false
      add :scan_cursor, :bigint, null: false, default: 0
      add :scan_ceiling, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lab_queues, :lab_queues_valid_config,
             check:
               "capacity BETWEEN 1 AND 10000 AND max_inflight BETWEEN 1 AND capacity AND aging_ms BETWEEN 1 AND 86400000 AND starvation_ms BETWEEN 1 AND 86400000 AND scan_cursor >= 0 AND scan_ceiling >= 0"
           )

    alter table(:lab_runs) do
      add :queue_name, references(:lab_queues, column: :name, type: :text, on_delete: :restrict)
    end

    create index(:lab_runs, [:queue_name, :status])
  end
end
