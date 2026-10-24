defmodule AgentSystemsLab.Repo.Migrations.CreateRetries do
  use Ecto.Migration

  def change do
    create table(:lab_retries) do
      add :run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :scope, :text, null: false
      add :schema_version, :integer, null: false, default: 1
      add :codec_version, :integer, null: false, default: 1
      add :policy_data, :binary, null: false
      add :policy_sha256, :text, null: false
      add :state_data, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lab_retries, [:run_id, :seq, :scope])
    create constraint(:lab_retries, :lab_retries_positive_seq, check: "seq > 0")

    create constraint(:lab_retries, :lab_retries_valid_scope,
             check: "scope IN ('model', 'tool', 'reconcile')"
           )

    create constraint(:lab_retries, :lab_retries_schema_version, check: "schema_version = 1")
    create constraint(:lab_retries, :lab_retries_codec_version, check: "codec_version = 1")
  end
end
