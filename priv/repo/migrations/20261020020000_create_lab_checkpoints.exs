defmodule AgentSystemsLab.Repo.Migrations.CreateLabCheckpoints do
  use Ecto.Migration

  def change do
    create table(:lab_checkpoints, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:run_id, references(:lab_runs, type: :text, on_delete: :delete_all), null: false)
      add(:last_seq, :bigint, null: false)
      add(:schema_version, :integer, null: false)
      add(:codec_version, :integer, null: false)
      add(:data, :binary, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lab_checkpoints, [:run_id, :last_seq])
    create constraint(:lab_checkpoints, :lab_checkpoints_valid_seq, check: "last_seq >= 0")

    create constraint(:lab_checkpoints, :lab_checkpoints_schema_version,
             check: "schema_version = 1"
           )

    create constraint(:lab_checkpoints, :lab_checkpoints_codec_version,
             check: "codec_version = 1"
           )
  end
end
