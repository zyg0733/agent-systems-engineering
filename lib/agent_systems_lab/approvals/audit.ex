defmodule AgentSystemsLab.Approvals.Audit do
  @moduledoc "Read-only case, control and child history reconstruction in an idle BEAM."
  alias AgentSystemsLab.{
    CheckpointStore,
    Context,
    ModelResultStore,
    RebuildAudit,
    Recovery,
    TaskBudgetStore
  }

  alias AgentSystemsLab.Approvals.{Artifact, Cases, Coordinator}
  alias AgentSystemsLab.Workflows.{ControlStore, Store}

  def boundaries do
    RebuildAudit.boundaries() ++
      [
        {Store, :create, 3},
        {Store, :sync, 2},
        {Store, :cancel, 3},
        {Store, :create_in_transaction, 4},
        {AgentSystemsLab.Workflows.Coordinator, :start_link, 1},
        {ControlStore, :pause, 3},
        {ControlStore, :resume, 2},
        {ControlStore, :set_owned_in_transaction, 5},
        {ControlStore, :create_owned_in_transaction, 3},
        {Cases, :create, 3},
        {Cases, :sync, 2},
        {Cases, :pause, 3},
        {Cases, :resume, 3},
        {Cases, :cancel, 3},
        {Cases, :decide, 3},
        {Cases, :release, 3},
        {Coordinator, :start_link, 1},
        {Artifact, :capture, 1},
        {Artifact, :check_baselines, 1}
      ]
  end

  def run(id, expected \\ nil) do
    boundaries = boundaries()
    Enum.each(boundaries, fn {module, _, _} -> Code.ensure_loaded!(module) end)
    Enum.each(boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

    try do
      with {:ok, view} <- Cases.load(id),
           {:ok, rebuilt} <- Cases.rebuild(id),
           true <- view === rebuilt,
           true <- is_nil(expected) or expected === view,
           {:ok, workflows} <- workflows(view) do
        counts =
          Map.new(boundaries, fn {module, function, arity} = mfa ->
            {:call_count, count} = :erlang.trace_info(mfa, :call_count)
            {"#{inspect(module)}.#{function}/#{arity}", count}
          end)

        if Enum.all?(counts, fn {_, count} -> count == 0 end) do
          {:ok,
           %{
             "case_id" => id,
             "case_sha256" => Context.hash(view),
             "status" => Atom.to_string(view.status),
             "seq" => view.seq,
             "generation" => view.generation,
             "workflows" => workflows,
             "effect_boundary_calls" => counts,
             "all_passed" => true
           }}
        else
          {:error, {:approval_rebuild_executed_work, counts}}
        end
      else
        false -> {:error, :approval_rebuild_mismatch}
        error -> error
      end
    after
      Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end

  defp workflows(view) do
    Enum.reduce_while(view.rounds, {:ok, []}, fn round, {:ok, acc} ->
      case Store.load(round.workflow_id) do
        {:ok, workflow} ->
          with {:ok, control} <- ControlStore.load(workflow.id),
               {:ok, rebuilt_control} <- ControlStore.rebuild(workflow.id),
               true <- control === rebuilt_control,
               {:ok, children} <- children(workflow) do
            {:cont,
             {:ok,
              acc ++
                [
                  %{
                    "workflow_id" => workflow.id,
                    "workflow_sha256" => Context.hash(workflow),
                    "control_sha256" => Context.hash(control),
                    "children" => children
                  }
                ]}}
          else
            false -> {:halt, {:error, :approval_control_rebuild_mismatch}}
            error -> {:halt, error}
          end

        {:error, :not_found} ->
          {:cont, {:ok, acc ++ [%{"workflow_id" => round.workflow_id, "created" => false}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp children(workflow) do
    Enum.reduce_while(Enum.sort_by(workflow.nodes, &elem(&1, 0)), {:ok, []}, fn {id, node},
                                                                                {:ok, acc} ->
      if node.observed_seq == 0 do
        case Recovery.load(node.run_id) do
          {:error, :not_found} ->
            {:cont, {:ok, acc ++ [%{"node_id" => id, "created" => false}]}}

          _ ->
            {:halt, {:error, :unexpected_approval_child}}
        end
      else
        with {:ok, child} <- Recovery.load(node.run_id),
             {:ok, rebuilt} <- CheckpointStore.rebuild(node.run_id, mode: :full),
             true <- rebuilt.state === child.state,
             {:ok, recordings} <- ModelResultStore.list(node.run_id),
             {:ok, budget} <- TaskBudgetStore.load(node.run_id) do
          {:cont,
           {:ok,
            acc ++
              [
                %{
                  "node_id" => id,
                  "run_id" => node.run_id,
                  "state_sha256" => Context.hash(child.state),
                  "recordings_sha256" => Context.hash(recordings),
                  "budget_sha256" => Context.hash(budget)
                }
              ]}}
        else
          false -> {:halt, {:error, :approval_child_rebuild_mismatch}}
          error -> {:halt, error}
        end
      end
    end)
  end
end
