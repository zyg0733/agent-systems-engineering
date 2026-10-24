defmodule AgentSystemsLab.Repo.Migrations.AddIsolationPolicy do
  use Ecto.Migration

  def change do
    alter table(:lab_recovery) do
      add :isolation_policy_data, :binary
      add :isolation_policy_sha256, :text
    end
  end
end
