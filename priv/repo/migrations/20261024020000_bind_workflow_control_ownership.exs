defmodule AgentSystemsLab.Repo.Migrations.BindWorkflowControlOwnership do
  use Ecto.Migration

  def up do
    alter table(:lab_workflows) do
      add :control_owner_case_id, :text
    end

    execute """
    UPDATE lab_workflows w SET control_owner_case_id = c.owner_case_id
    FROM lab_workflow_controls c
    WHERE c.workflow_id = w.id AND c.owner_case_id IS NOT NULL
    """
  end

  def down do
    alter table(:lab_workflows) do
      remove :control_owner_case_id
    end
  end
end
