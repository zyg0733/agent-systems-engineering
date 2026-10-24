defmodule AgentSystemsLab.Observability.Metrics do
  @moduledoc "Finite-cardinality aggregates. Business identifiers never become metric labels."
  @ceiling 9_007_199_254_740_991

  def add(metrics, event) do
    name = event["event_name"]
    outcome = get_in(event, ["attributes", "outcome"]) || "unspecified"
    key = {name, outcome}
    measurements = event["measurements"]

    Map.update(metrics, key, %{count: 1, sums: measurements}, fn old ->
      %{
        count: min(old.count + 1, @ceiling),
        sums: Map.merge(old.sums, measurements, fn _, a, b -> min(a + b, @ceiling) end)
      }
    end)
  end

  def export(metrics) do
    metrics
    |> Enum.sort()
    |> Enum.map(fn {{name, outcome}, values} ->
      %{
        "event_name" => name,
        "outcome" => outcome,
        "count" => values.count,
        "sums" => values.sums
      }
    end)
  end
end
