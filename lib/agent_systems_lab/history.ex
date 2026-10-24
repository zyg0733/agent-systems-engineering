defmodule AgentSystemsLab.History do
  @moduledoc """
  Pure, strict event-history reconstruction. Neither path invokes a provider or
  executes tools. Full history always starts at sequence zero. A checkpoint path
  accepts only a trusted checkpoint; its digest detects damage, not forgery.
  Persisted checkpoints must first be checked against their original prefix.
  """
  alias AgentSystemsLab.{Checkpoint, Kernel}

  def rebuild(run_id, events, opts \\ []) do
    with :ok <- valid_tail(events), do: Kernel.rebuild(run_id, events, opts)
  end

  def from_checkpoint(checkpoint, tail) do
    with :ok <- Checkpoint.validate(checkpoint),
         :ok <- valid_tail(tail) do
      Enum.reduce_while(tail, {:ok, checkpoint.state}, fn event, {:ok, state} ->
        case Kernel.apply_event(state, event) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp valid_tail(tail) do
    if proper_list?(tail), do: :ok, else: {:error, {:invalid_history, tail}}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false
end
