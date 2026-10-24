defmodule AgentSystemsLab.Tools.Result do
  @moduledoc """
  Correlation envelopes shared by current runtime input and kernel replay.

  Replay validates explicitly tagged envelopes while preserving opaque v1
  results from tools whose names may have gained new meaning in later releases.
  Current file calls use `validate_required/3` at the runtime boundary.
  """

  def wrap({outcome, output}, operation_id, tool) when outcome in [:ok, :error, :unknown] do
    {outcome, %{type: "tool_result.v1", operation_id: operation_id, tool: tool, output: output}}
  end

  def validate({_outcome, payload} = result, operation_id, tool) do
    if envelope?(payload) do
      validate_required(result, operation_id, tool)
    else
      :ok
    end
  end

  @doc "Requires the current tagged envelope when accepting a new file result."
  def validate_required({_outcome, payload}, operation_id, tool) do
    case payload do
      %{type: "tool_result.v1", operation_id: ^operation_id, tool: ^tool, output: _} = envelope
      when map_size(envelope) == 4 ->
        :ok

      _ ->
        {:error, {:invalid_tool_result_envelope, operation_id, tool}}
    end
  end

  defp envelope?(%{type: "tool_result.v1"}), do: true
  defp envelope?(_payload), do: false
end
