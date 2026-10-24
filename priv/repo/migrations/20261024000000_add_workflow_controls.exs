defmodule AgentSystemsLab.Repo.Migrations.AddWorkflowControls do
  use Ecto.Migration

  def change do
    create table(:lab_workflow_controls, primary_key: false) do
      add :workflow_id, references(:lab_workflows, type: :text, on_delete: :delete_all),
        primary_key: true

      add :owner_case_id, :text
      add :status, :text, null: false
      add :seq, :bigint, null: false
      add :data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create table(:lab_workflow_control_events) do
      add :workflow_id,
          references(:lab_workflow_controls,
            column: :workflow_id,
            type: :text,
            on_delete: :delete_all
          ),
          null: false

      add :seq, :bigint, null: false
      add :type, :text, null: false
      add :data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_workflow_control_events, [:workflow_id, :seq])
    create index(:lab_workflow_controls, [:owner_case_id])
  end
end
