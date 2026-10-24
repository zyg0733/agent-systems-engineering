defmodule Mix.Tasks.Lab.Trace do
  use Mix.Task
  @shortdoc "Read bounded durable metadata by Run ID without running models, tools or recovery"

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, scope: :string, limit: :integer, max_related_runs: :integer]
      )

    if length(rest) != 1 or invalid != [] or length(opts) != length(Enum.uniq(Keyword.keys(opts))) or
         Keyword.get(opts, :scope, "related") not in ["run", "related"],
       do:
         Mix.raise(
           "Usage: mix lab.trace RUN_ID [--json] [--scope run|related] [--limit 1..200] [--max-related-runs 1..24]"
         )

    [id] = rest
    Mix.Task.run("app.config")

    if not Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: Mix.raise("Trace query requires PostgreSQL (database_required)")

    if Application.get_env(:agent_systems_lab, :scheduler_enabled, false) or
         Process.whereis(AgentSystemsLab.Scheduler),
       do:
         Mix.raise(
           "Disable the global scheduler for a read-only trace query (global_scheduler_enabled)"
         )

    Mix.Task.run("app.start")
    scope = if Keyword.get(opts, :scope, "related") == "run", do: :run, else: :related
    query_opts = opts |> Keyword.drop([:json, :scope]) |> Keyword.put(:scope, scope)

    case AgentSystemsLab.Observability.Query.run(id, query_opts) do
      {:ok, trace} ->
        if opts[:json] do
          Mix.shell().info(JSON.encode!(trace))
        else
          Mix.shell().info("Run #{trace["run_id"]} · trace #{trace["trace_id"]}")

          Mix.shell().info(
            "#{length(trace["spans"])} durable projections · #{length(trace["links"])} causal links · partial=#{trace["partial"]}"
          )

          Mix.shell().info(JSON.encode!(trace["metrics"]))

          if trace["partial"],
            do: Mix.shell().info("Truncation: #{JSON.encode!(trace["truncation"])}")
        end

      {:error, reason} ->
        Mix.raise("Trace query failed: #{inspect(reason)}")
    end
  end
end
