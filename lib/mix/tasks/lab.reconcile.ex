defmodule Mix.Tasks.Lab.Reconcile do
  use Mix.Task
  @shortdoc "Lists committed unknown outcomes without invoking tools or providers"
  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [run: :string, limit: :integer, json: :boolean])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix lab.reconcile [--run RUN_ID] [--limit N] [--json]")

    Mix.Task.run("app.start")
    filters = opts |> Keyword.take([:limit])
    filters = if opts[:run], do: Keyword.put(filters, :run_id, opts[:run]), else: filters

    case AgentSystemsLab.ReconciliationQueue.list(filters) do
      {:ok, entries} ->
        if opts[:json] do
          rows =
            Enum.map(entries, fn entry ->
              entry
              |> Map.put(:queued_at, DateTime.to_iso8601(entry.queued_at))
              |> Map.put(:status, Atom.to_string(entry.status))
              |> Map.put(:safe_mode, Atom.to_string(entry.safe_mode))
              |> Map.update!(:latest_attempt, fn
                nil ->
                  nil

                attempt ->
                  Map.new(attempt, fn {key, value} ->
                    {key,
                     if(match?(%DateTime{}, value), do: DateTime.to_iso8601(value), else: value)}
                  end)
              end)
              |> Map.put(:reason, inspect(entry.reason, limit: 20, printable_limit: 2048))
            end)

          Mix.shell().info(JSON.encode!(%{count: length(rows), entries: rows}))
        else
          Mix.shell().info("reconciliation_queue=#{length(entries)} (read-only)")

          Enum.each(entries, fn row ->
            Mix.shell().info(
              "#{row.run_id} seq=#{row.seq} operation=#{row.operation_id} tool=#{row.tool} mode=#{row.safe_mode} age_ms=#{row.age_ms}"
            )

            Mix.shell().info("  reason=#{inspect(row.reason, limit: 10, printable_limit: 256)}")
          end)
        end

      {:error, reason} ->
        Mix.raise("Reconciliation queue rejected: #{inspect(reason)}")
    end
  end
end
