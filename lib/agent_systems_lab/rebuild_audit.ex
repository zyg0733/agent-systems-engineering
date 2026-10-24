defmodule AgentSystemsLab.RebuildAudit do
  @moduledoc "Read-only history comparison with VM function-call counters for effect boundaries."

  alias AgentSystemsLab.{CheckpointStore, Context, ModelResultStore}

  @boundaries [
    {AgentSystemsLab.Providers.Scripted, :stream, 3},
    {AgentSystemsLab.Providers.Scripted, :respond, 2},
    {AgentSystemsLab.Providers.Recorded, :stream, 3},
    {AgentSystemsLab.Providers.Recorded, :respond, 2},
    {AgentSystemsLab.Tools.Gateway, :execute, 4},
    {AgentSystemsLab.Tools.Gateway, :execute, 5},
    {AgentSystemsLab.Tools.Gateway, :execute, 6},
    {AgentSystemsLab.Tools.Gateway, :execute, 7},
    {AgentSystemsLab.MCP, :execute, 3},
    {AgentSystemsLab.MCP, :execute, 4},
    {AgentSystemsLab.Isolation, :execute, 3},
    {AgentSystemsLab.Isolation, :execute, 4},
    {AgentSystemsLab.Tools.Files, :execute, 4},
    {AgentSystemsLab.Tools.Mock, :execute, 4},
    {AgentSystemsLab.RunServer, :start_link, 1},
    {AgentSystemsLab.Recovery, :resume, 2},
    {AgentSystemsLab.Recovery, :step, 2},
    {AgentSystemsLab.Recovery, :reconcile, 2},
    {AgentSystemsLab.Recovery, :execute_claim, 2},
    {AgentSystemsLab.Scheduler, :start_link, 1},
    {AgentSystemsLab.DurableTools, :execute, 3},
    {AgentSystemsLab.DurableTools, :reconcile, 3},
    {AgentSystemsLab.DurableTools, :confirm, 5},
    {AgentSystemsLab.DurableTools, :observe_timeout, 4},
    {AgentSystemsLab.Tools.DurableMock, :execute, 4},
    {AgentSystemsLab.Tools.DurableMock, :execute, 5},
    {AgentSystemsLab.Tools.DurableMock, :lookup, 3}
  ]

  @doc "Trusted execution boundaries for an enclosing read-only workflow audit."
  def boundaries, do: @boundaries

  @doc "Run in an otherwise idle or fresh BEAM: call counters cover all processes in this VM."
  def run(run_id, expected_state \\ nil) do
    Enum.each(@boundaries, fn {module, _name, _arity} -> Code.ensure_loaded!(module) end)
    Enum.each(@boundaries, fn mfa -> 1 = :erlang.trace_pattern(mfa, true, [:call_count]) end)

    try do
      with {:ok, full} <- CheckpointStore.rebuild(run_id, mode: :full),
           {:ok, checkpoint} <- CheckpointStore.rebuild(run_id, mode: :checkpoint),
           {:ok, recordings} <- ModelResultStore.list(run_id),
           true <- full.state === checkpoint.state,
           true <- is_nil(expected_state) or full.state === expected_state do
        counts =
          Map.new(@boundaries, fn {module, name, arity} = mfa ->
            {:call_count, count} = :erlang.trace_info(mfa, :call_count)
            {"#{inspect(module)}.#{name}/#{arity}", count}
          end)

        if Enum.all?(counts, fn {_name, count} -> count == 0 end) do
          {:ok,
           %{
             "run_id" => run_id,
             "status" => Atom.to_string(full.state.status),
             "seq" => full.state.seq,
             "state_sha256" => Context.hash(full.state),
             "full_matches_checkpoint" => true,
             "same_as_expected_state" => if(is_nil(expected_state), do: nil, else: true),
             "recorded_model_results" => length(recordings),
             "checkpoint_id" => checkpoint.audit.checkpoint_id,
             "checkpoint_seq" => checkpoint.audit.checkpoint_seq,
             "verified_prefix_events" => checkpoint.audit.verified_prefix_events,
             "replayed_tail_events" => checkpoint.audit.replayed_tail_events,
             "effect_boundary_calls" => counts
           }}
        else
          {:error, {:unexpected_effect_boundary_calls, counts}}
        end
      else
        false -> {:error, :rebuilt_state_mismatch}
        error -> error
      end
    after
      Enum.each(@boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end
end
