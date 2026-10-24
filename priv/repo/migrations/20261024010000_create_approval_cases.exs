defmodule AgentSystemsLab.Repo.Migrations.CreateApprovalCases do
  use Ecto.Migration

  def change do
    create table(:lab_approval_cases, primary_key: false) do
      add :id, :text, primary_key: true
      add :status, :text, null: false
      add :seq, :bigint, null: false
      add :plan_data, :binary, null: false
      add :plan_sha256, :text, null: false
      add :progress_data, :binary, null: false
      add :deadline_at_ms, :bigint, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create table(:lab_approval_events) do
      add :case_id, references(:lab_approval_cases, type: :text, on_delete: :delete_all),
        null: false

      add :seq, :bigint, null: false
      add :type, :text, null: false
      add :data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_approval_events, [:case_id, :seq])
  end
end
