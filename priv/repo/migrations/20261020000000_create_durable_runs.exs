defmodule AgentSystemsLab.Repo.Migrations.CreateDurableRuns do
  use Ecto.Migration

  def change do
    create table(:lab_runs, primary_key: false) do
      add :id, :text, primary_key: true
      add :status, :text, null: false
      add :seq, :bigint, null: false
      add :max_turns, :integer, null: false
      add :turn_count, :integer, null: false
      add :state_data, :binary, null: false
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lab_runs, :lab_runs_valid_sequence, check: "seq > 0")

    create constraint(:lab_runs, :lab_runs_valid_status,
             check:
               "status IN ('running', 'waiting_tool', 'blocked', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:lab_runs, :lab_runs_valid_budget,
             check:
               "max_turns > 0 AND turn_count >= 0 AND turn_count <= max_turns AND turn_count <= seq"
           )

    create constraint(:lab_runs, :lab_runs_codec_version, check: "codec_version = 1")

    create table(:lab_events) do
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :type, :text, null: false
      add :schema_version, :integer, null: false, default: 1
      add :data, :binary, null: false
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lab_events, [:run_id, :seq])
    create constraint(:lab_events, :lab_events_positive_sequence, check: "seq > 0")

    create constraint(:lab_events, :lab_events_valid_type,
             check:
               "type IN ('run_started', 'tool_requested', 'tool_result_recorded', 'tool_reconciled', 'run_succeeded', 'run_failed', 'run_cancelled')"
           )

    create constraint(:lab_events, :lab_events_schema_version, check: "schema_version = 1")
    create constraint(:lab_events, :lab_events_codec_version, check: "codec_version = 1")

    create table(:lab_intents) do
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :kind, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :payload, :binary, null: false
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_intents, [:run_id, :seq])

    create unique_index(:lab_intents, [:run_id],
             where: "status = 'pending'",
             name: :lab_intents_one_pending_per_run
           )

    create index(:lab_intents, [:status, :id])
    create constraint(:lab_intents, :lab_intents_positive_sequence, check: "seq > 0")

    create constraint(:lab_intents, :lab_intents_valid_kind,
             check: "kind IN ('model', 'tool', 'reconcile')"
           )

    create constraint(:lab_intents, :lab_intents_valid_status,
             check: "status IN ('pending', 'superseded')"
           )

    create constraint(:lab_intents, :lab_intents_codec_version, check: "codec_version = 1")

    execute(
      "ALTER TABLE lab_intents ADD CONSTRAINT lab_intents_event_fkey FOREIGN KEY (run_id, seq) REFERENCES lab_events (run_id, seq) ON DELETE CASCADE",
      "ALTER TABLE lab_intents DROP CONSTRAINT lab_intents_event_fkey"
    )
  end
end
