defmodule AgentSystemsLab.Workflows.Audit do
  @moduledoc "Read-only graph/child reconstruction with explicit execution counters."
  alias AgentSystemsLab.{Context, ModelResultStore, RebuildAudit, Recovery, TaskBudgetStore}
  alias AgentSystemsLab.Workflows.{Coordinator, Store}

  def run(id, expected \\ nil) do
    boundaries =
      RebuildAudit.boundaries() ++
        [
          {Store, :create, 3},
          {Store, :sync, 2},
          {Store, :cancel, 3},
          {Coordinator, :start_link, 1}
        ]

    Enum.each(boundaries, fn {module, _, _} -> Code.ensure_loaded!(module) end)
    Enum.each(boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

    try do
      with {:ok, loaded} <- Store.load(id),
           {:ok, rebuilt} <- Store.rebuild(id),
           true <- loaded === rebuilt,
           true <- is_nil(expected) or expected === loaded,
           {:ok, children} <- children(loaded) do
        counts =
          Map.new(boundaries, fn {module, name, arity} = mfa ->
            {:call_count, count} = :erlang.trace_info(mfa, :call_count)
            {"#{inspect(module)}.#{name}/#{arity}", count}
          end)

        if Enum.all?(counts, fn {_, count} -> count == 0 end) do
          {:ok,
           %{
             "workflow_id" => id,
             "status" => Atom.to_string(loaded.status),
             "seq" => loaded.seq,
             "workflow_sha256" => Context.hash(loaded),
             "children" => children,
             "effect_boundary_calls" => counts,
             "all_passed" => true
           }}
        else
          {:error, {:workflow_rebuild_executed_work, counts}}
        end
      else
        false -> {:error, :workflow_rebuild_mismatch}
        error -> error
      end
    after
      Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end

  defp children(view) do
    view.nodes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {id, node}, {:ok, acc} ->
      if node.observed_seq == 0 do
        case Recovery.load(node.run_id) do
          {:error, :not_found} ->
            {:cont,
             {:ok,
              acc ++
                [
                  %{
                    "node_id" => id,
                    "status" => Atom.to_string(node.status),
                    "run_created" => false
                  }
                ]}}

          _ ->
            {:halt, {:error, {:unexpected_workflow_child, id}}}
        end
      else
        with {:ok, snapshot} <- Recovery.load(node.run_id),
             {:ok, recordings} <- ModelResultStore.list(node.run_id),
             {:ok, budget} <- TaskBudgetStore.load(node.run_id),
             {:ok, rebuilt} <- AgentSystemsLab.CheckpointStore.rebuild(node.run_id, mode: :full),
             true <- rebuilt.state === snapshot.state do
          {:cont,
           {:ok,
            acc ++
              [
                %{
                  "node_id" => id,
                  "run_id" => node.run_id,
                  "status" => Atom.to_string(snapshot.state.status),
                  "state_sha256" => Context.hash(snapshot.state),
                  "recordings_sha256" => Context.hash(recordings),
                  "budget_sha256" => Context.hash(budget),
                  "run_created" => true
                }
              ]}}
        else
          false -> {:halt, {:error, {:workflow_child_rebuild_mismatch, id}}}
          error -> {:halt, error}
        end
      end
    end)
  end
end
