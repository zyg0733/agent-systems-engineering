defmodule AgentSystemsLab.Repo.Migrations.CreateModelResults do
  use Ecto.Migration

  def change do
    create table(:lab_model_results, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :context_id, references(:lab_contexts, type: :uuid, on_delete: :delete_all), null: false
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :input_seq, :bigint, null: false
      add :event_seq, :bigint, null: false
      add :provider, :text, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      add :record_data, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lab_model_results, [:context_id])
    create unique_index(:lab_model_results, [:run_id, :event_seq])

    execute(
      "ALTER TABLE lab_model_results ADD CONSTRAINT lab_model_results_event_fkey " <>
        "FOREIGN KEY (run_id, event_seq) REFERENCES lab_events(run_id, seq) ON DELETE CASCADE",
      "ALTER TABLE lab_model_results DROP CONSTRAINT lab_model_results_event_fkey"
    )

    create constraint(:lab_model_results, :lab_model_results_valid_sequence,
             check: "input_seq > 0 AND event_seq = input_seq + 1"
           )

    create constraint(:lab_model_results, :lab_model_results_schema_version,
             check: "schema_version = 1"
           )

    create constraint(:lab_model_results, :lab_model_results_codec_version,
             check: "codec_version = 1"
           )
  end
end
