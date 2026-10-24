defmodule AgentSystemsLab.Observability.Context do
  @moduledoc """
  Versioned deterministic correlation IDs, derived without process-local state.

  These IDs correlate observations across a new BEAM; they do not establish an
  execution authority, an approval, or the truth of an exported observation.
  """

  def trace_id(run_id), do: digest({"lab.trace.v1", run_id}, 32)
  def root_span_id(run_id), do: span_id(:run, run_id)

  def span_id(kind, business_id) do
    kind = if is_atom(kind), do: Atom.to_string(kind), else: kind
    digest({"lab.span.v1", kind, business_id}, 16)
  end

  def event_id(name, refs), do: digest({"lab.observation.v1", name, refs}, 32)

  defp digest(value, length) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, length)
  end
end
