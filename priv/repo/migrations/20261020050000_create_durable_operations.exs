defmodule AgentSystemsLab.Repo.Migrations.CreateDurableOperations do
  use Ecto.Migration

  def change do
    create table(:lab_operations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :operation_id, :text, null: false
      add :tool, :text, null: false
      add :input_sha256, :text, null: false
      add :input_data, :binary, null: false
      add :status, :text, null: false
      add :result_data, :binary
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_operations, [:run_id, :operation_id])

    create constraint(:lab_operations, :lab_operations_valid_status,
             check: "status IN ('prepared', 'completed', 'unknown')"
           )

    create constraint(:lab_operations, :lab_operations_schema_version,
             check: "schema_version = 1"
           )

    create constraint(:lab_operations, :lab_operations_codec_version, check: "codec_version = 1")

    create table(:lab_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :operation_record_id, references(:lab_operations, type: :uuid, on_delete: :delete_all),
        null: false

      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :operation_id, :text, null: false
      add :claim_generation, :bigint, null: false
      add :claim_data, :binary, null: false
      add :kind, :text, null: false
      add :outcome, :text, null: false
      add :result_data, :binary
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:lab_attempts, [:run_id, :operation_id])

    create constraint(:lab_attempts, :lab_attempts_valid_kind,
             check: "kind IN ('execution', 'lookup')"
           )

    create constraint(:lab_attempts, :lab_attempts_valid_outcome,
             check: "outcome IN ('prepared', 'completed', 'unknown')"
           )

    create constraint(:lab_attempts, :lab_attempts_valid_generation,
             check: "claim_generation > 0"
           )

    create constraint(:lab_attempts, :lab_attempts_schema_version, check: "schema_version = 1")
    create constraint(:lab_attempts, :lab_attempts_codec_version, check: "codec_version = 1")

    create table(:lab_mock_effects, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :operation_id, :text, null: false
      add :tool, :text, null: false
      add :input_sha256, :text, null: false
      add :input_data, :binary, null: false
      add :receipt_data, :binary, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lab_mock_effects, [:run_id, :operation_id])

    create constraint(:lab_mock_effects, :lab_mock_effects_schema_version,
             check: "schema_version = 1"
           )

    create constraint(:lab_mock_effects, :lab_mock_effects_codec_version,
             check: "codec_version = 1"
           )
  end
end
