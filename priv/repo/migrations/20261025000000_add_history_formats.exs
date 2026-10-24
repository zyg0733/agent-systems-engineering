defmodule AgentSystemsLab.Repo.Migrations.AddHistoryFormats do
  use Ecto.Migration

  def change do
    alter table(:lab_runs) do
      add :history_format, :integer, null: false, default: 1
    end

    alter table(:lab_events) do
      add :history_format, :integer, null: false, default: 1
    end

    create constraint(:lab_runs, :lab_runs_history_format, check: "history_format IN (1, 2)")
    create constraint(:lab_events, :lab_events_history_format, check: "history_format IN (1, 2)")

    create table(:lab_history_migrations, primary_key: false) do
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), primary_key: true
      add :source_format, :integer, null: false
      add :target_format, :integer, null: false
      add :prefix_seq, :integer, null: false
      add :event_count, :integer, null: false
      add :source_hash, :text, null: false
      add :target_hash, :text, null: false
      add :semantic_hash, :text, null: false
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:lab_history_migrations, :lab_history_migrations_supported_transition,
             check: "source_format = 1 AND target_format = 2 AND codec_version = 1"
           )

    create constraint(:lab_history_migrations, :lab_history_migrations_valid_prefix,
             check: "prefix_seq > 0 AND event_count = prefix_seq AND event_count <= 4096"
           )

    create constraint(:lab_history_migrations, :lab_history_migrations_valid_hashes,
             check:
               "source_hash ~ '^[0-9a-f]{64}$' AND target_hash ~ '^[0-9a-f]{64}$' AND semantic_hash ~ '^[0-9a-f]{64}$'"
           )
  end
end
