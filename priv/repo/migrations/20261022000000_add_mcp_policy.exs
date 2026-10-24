defmodule AgentSystemsLab.Repo.Migrations.AddMCPPolicy do
  use Ecto.Migration

  def change do
    alter table(:lab_recovery) do
      add :mcp_policy_data, :binary
      add :mcp_policy_sha256, :text
    end
  end
end
