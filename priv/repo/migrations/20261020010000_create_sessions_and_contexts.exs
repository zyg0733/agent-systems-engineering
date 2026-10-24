defmodule AgentSystemsLab.Repo.Migrations.CreateSessionsAndContexts do
  use Ecto.Migration

  def change do
    create table(:lab_sessions, primary_key: false) do
      add :id, :text, primary_key: true
      add :version, :bigint, null: false
      add :session_data, :binary, null: false
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lab_sessions, :lab_sessions_valid_version, check: "version >= 0")
    create constraint(:lab_sessions, :lab_sessions_codec_version, check: "codec_version = 1")

    create table(:lab_contexts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :run_seq, :bigint, null: false
      add :session_id, references(:lab_sessions, type: :text, on_delete: :restrict)
      add :session_version, :bigint, null: false
      add :codec_version, :integer, null: false, default: 1
      add :sources_data, :binary, null: false
      add :payload_data, :binary, null: false
      add :manifest_data, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:lab_contexts, [:run_id, :inserted_at, :id])
    create index(:lab_contexts, [:session_id])
    create constraint(:lab_contexts, :lab_contexts_valid_run_seq, check: "run_seq > 0")

    create constraint(:lab_contexts, :lab_contexts_valid_session_version,
             check: "session_version >= 0"
           )

    create constraint(:lab_contexts, :lab_contexts_codec_version, check: "codec_version = 1")
  end
end
