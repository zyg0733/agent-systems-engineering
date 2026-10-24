defmodule AgentSystemsLab.Repo.Migrations.CreateTaskBudgets do
  use Ecto.Migration

  def change do
    create table(:lab_task_budgets, primary_key: false) do
      add :run_id, references(:lab_runs, column: :id, type: :text, on_delete: :delete_all),
        primary_key: true

      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      add :config_data, :binary, null: false
      add :config_sha256, :text, null: false
      add :progress_data, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
