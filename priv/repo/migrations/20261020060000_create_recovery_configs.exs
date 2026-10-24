defmodule AgentSystemsLab.Repo.Migrations.CreateRecoveryConfigs do
  use Ecto.Migration

  def change do
    create table(:lab_recovery, primary_key: false) do
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), primary_key: true
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      add :config_data, :binary, null: false
      add :config_sha256, :text, null: false
      add :progress_data, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lab_recovery, :lab_recovery_schema_version, check: "schema_version = 1")
    create constraint(:lab_recovery, :lab_recovery_codec_version, check: "codec_version = 1")
  end
end
