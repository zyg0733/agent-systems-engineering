defmodule AgentSystemsLab.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:lab_workflows, primary_key: false) do
      add :id, :text, primary_key: true
      add :status, :text, null: false
      add :seq, :bigint, null: false
      add :queue_name, references(:lab_queues, column: :name, type: :text), null: false
      add :definition_data, :binary, null: false
      add :definition_sha256, :text, null: false
      add :progress_data, :binary, null: false
      add :deadline_at_ms, :bigint, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create table(:lab_workflow_nodes, primary_key: false) do
      add :workflow_id, references(:lab_workflows, type: :text, on_delete: :delete_all),
        primary_key: true

      add :node_id, :text, primary_key: true
      add :run_id, :text, null: false
      add :status, :text, null: false
      add :data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_workflow_nodes, [:run_id])

    create table(:lab_workflow_events) do
      add :workflow_id, references(:lab_workflows, type: :text, on_delete: :delete_all),
        null: false

      add :seq, :bigint, null: false
      add :type, :text, null: false
      add :data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_workflow_events, [:workflow_id, :seq])

    alter table(:lab_runs) do
      add :workflow_id, references(:lab_workflows, type: :text, on_delete: :delete_all)
      add :workflow_node_id, :text
    end

    create unique_index(:lab_runs, [:workflow_id, :workflow_node_id],
             where: "workflow_id IS NOT NULL"
           )
  end
end
