defmodule AgentSystemsLab.Repo.Migrations.AddRecoveryRetryConfig do
  use Ecto.Migration

  def change do
    alter table(:lab_recovery) do
      add :retry_config_data, :binary
      add :retry_config_sha256, :text
    end

    create constraint(:lab_recovery, :lab_recovery_retry_config_pair,
             check: "(retry_config_data IS NULL) = (retry_config_sha256 IS NULL)"
           )
  end
end
