defmodule Week20ReadonlyAudit do
  @moduledoc false
  alias AgentSystemsLab.{Approvals, Repo}
  alias AgentSystemsLab.Evaluation.{Comparison, Report, Runner, Scorer, Suite}

  def snapshot(path) do
    if File.exists?(path), do: raise("refusing to overwrite database snapshot")
    data = %{"schema_version" => 1, "tables" => table_rows()}
    File.write!(path, JSON.encode!(data) <> "\n")
    IO.puts("Saved full-column database row hashes: " <> path)
  end

  def run(root, before_path \\ nil) do
    if Process.whereis(AgentSystemsLab.Scheduler), do: raise("global scheduler must be disabled")
    root = Path.expand(root)
    reports = Path.wildcard(Path.join(root, "*/report.json")) |> Enum.sort()
    before_tables = table_counts()
    before_rows = table_rows()
    before_sources = sources(reports)

    checks = [
      %{"name" => "six completed cohort reports present", "passed" => length(reports) == 6}
    ]

    boundaries =
      Approvals.Audit.boundaries() ++
        [{AgentSystemsLab.Observability, :emit, 4}, {Runner, :execute, 6}, {Scorer, :score, 5}]

    Enum.each(boundaries, fn {module, _, _} = mfa ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(mfa, true, [:call_count])
    end)

    checks =
      try do
        {:ok, suite} = Suite.load()

        checks =
          Enum.reduce(reports, checks, fn path, acc ->
            report = read(path)
            relative = Path.relative_to(path, root)

            acc =
              check(
                acc,
                relative <> ": complete report validation",
                Report.validate(report) == :ok
              )

            acc =
              check(
                acc,
                relative <> ": source suite identity",
                report["manifest"]["protocol"]["suite_hash"] == suite["hash"]
              )

            Enum.reduce(report["samples"], acc, fn sample, rows ->
              {:ok, source} = Runner.source(sample["run_id"])

              raw_path =
                Path.join(
                  Path.dirname(path),
                  "#{sample["task_id"]}-#{sample["trial"]}.sample.json"
                )

              raw = read(raw_path)

              prefix =
                relative <> ": " <> sample["task_id"] <> ":" <> Integer.to_string(sample["trial"])

              rows =
                check(
                  rows,
                  prefix <> " durable source fingerprint",
                  raw["evidence"]["source_sha256"] == source["fingerprint"]
                )

              rows =
                check(
                  rows,
                  prefix <> " charged durable usage",
                  sample["usage"] == source["usage"]
                )

              rows =
                check(
                  rows,
                  prefix <> " terminal source status",
                  raw["status"] == source["status"]
                )

              rows =
                check(
                  rows,
                  prefix <> " scorer left source unchanged",
                  raw["evidence"]["source_unchanged_by_scorer"] == true
                )

              rows =
                check(
                  rows,
                  prefix <> " no project app in scorer",
                  raw["grade"]["project_app_started"] == false
                )

              pid = raw["grade"]["os_pid"]

              rows =
                check(
                  rows,
                  prefix <> " separate OS scorer process",
                  is_integer(pid) and pid > 0 and
                    Integer.to_string(pid) != List.to_string(:os.getpid())
                )

              {_bytes, exit} =
                System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

              check(rows, prefix <> " scorer process exited", exit != 0)
            end)
          end)

        by_hash =
          Map.new(reports, fn path ->
            report = read(path)
            {report["report_hash"], report}
          end)

        Enum.reduce(Path.wildcard(Path.join(root, "**/comparison.json")), checks, fn path, acc ->
          comparison = read(path)

          thresholds =
            comparison["thresholds"]
            |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)

          {:ok, recomputed} =
            Comparison.compare(
              by_hash[comparison["baseline_report_hash"]],
              by_hash[comparison["candidate_report_hash"]],
              thresholds
            )

          check(
            acc,
            Path.relative_to(path, root) <> ": saved pure comparison exact",
            comparison === recomputed
          )
        end)
      after
        # Capture before disabling call counting. The count is a diagnostic of
        # this fresh BEAM only; the script does not install function breakpoints.
        Process.put(
          :audit_boundary_counts,
          Enum.map(boundaries, fn mfa ->
            count =
              case :erlang.trace_info(mfa, :call_count) do
                {:call_count, number} when is_integer(number) -> number
                _ -> :unavailable
              end

            %{"mfa" => inspect(mfa), "count" => count}
          end)
        )

        Enum.each(boundaries, &:erlang.trace_pattern(&1, false, [:call_count]))
      end

    counters = Process.get(:audit_boundary_counts)

    checks =
      check(
        checks,
        "all execution and observation boundaries stayed silent",
        Enum.all?(counters, &(&1["count"] == 0))
      )

    checks =
      check(
        checks,
        "durable source fingerprints unchanged after audit",
        before_sources == sources(reports)
      )

    after_tables = table_counts()

    checks =
      check(
        checks,
        "every public application table count unchanged",
        before_tables == after_tables
      )

    after_rows = table_rows()

    checks =
      check(
        checks,
        "every full-column row hash unchanged during read-only audit",
        before_rows == after_rows
      )

    checks =
      if before_path do
        previous = read(before_path)["tables"]

        check(
          checks,
          "all rows preceding the formal evaluation retain every column",
          prior_rows_preserved?(previous, after_rows)
        )
      else
        checks
      end

    checks = Enum.reverse(checks)
    passed = Enum.count(checks, & &1["passed"])

    result = %{
      "schema_version" => 1,
      "checks" => checks,
      "passed" => passed,
      "total" => length(checks),
      "complete" => passed == length(checks),
      "boundary_count" => length(boundaries),
      "boundary_counts" => counters,
      "application_table_count" => map_size(before_tables),
      "table_counts_before" => before_tables,
      "table_counts_after" => after_tables,
      "full_column_table_hashes" =>
        Map.new(after_rows, fn {table, rows} -> {table, Report.hash(rows)} end),
      "pre_evaluation_database_snapshot" => before_path,
      "source_run_count" => map_size(before_sources),
      "source_fingerprints" => before_sources
    }

    File.write!(Path.join(root, "audit-fresh-beam.json"), JSON.encode!(result) <> "\n")

    IO.puts(
      JSON.encode!(
        Map.take(
          result,
          ~w(passed total complete boundary_count application_table_count source_run_count)
        )
      )
    )

    if not result["complete"], do: System.halt(1)
  end

  defp sources(reports) do
    reports
    |> Enum.flat_map(&read(&1)["samples"])
    |> Map.new(fn sample ->
      {:ok, fingerprint} = Runner.fingerprint(sample["run_id"])
      {sample["run_id"], fingerprint}
    end)
  end

  defp table_counts do
    %{rows: rows} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations' ORDER BY tablename"
      )

    Map.new(rows, fn [table] ->
      quoted = "\"" <> String.replace(table, "\"", "\"\"") <> "\""
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM " <> quoted)
      {table, count}
    end)
  end

  # Hash each complete PostgreSQL row in the database and transfer only hashes.
  # Sorting preserves multiplicity and makes row order irrelevant. This catches
  # equal-count edits, including bytea payload changes, without exporting them.
  defp table_rows do
    %{rows: tables} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations' ORDER BY tablename"
      )

    Map.new(tables, fn [table] ->
      quoted = "\"" <> String.replace(table, "\"", "\"\"") <> "\""

      sql =
        "SELECT encode(sha256(convert_to(row_to_json(t)::text, 'UTF8')), 'hex') AS row_hash FROM " <>
          quoted <> " t ORDER BY row_hash"

      %{rows: rows} = Repo.query!(sql)
      {table, Enum.map(rows, &hd/1)}
    end)
  end

  defp prior_rows_preserved?(previous, current) do
    Enum.sort(Map.keys(previous)) == Enum.sort(Map.keys(current)) and
      Enum.all?(previous, fn {table, rows} ->
        old_counts = Enum.frequencies(rows)
        new_counts = Enum.frequencies(current[table])
        Enum.all?(old_counts, fn {hash, count} -> Map.get(new_counts, hash, 0) >= count end)
      end)
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()
  defp check(rows, name, passed), do: [%{"name" => name, "passed" => passed} | rows]
end

case System.argv() do
  ["--snapshot", path] ->
    Week20ReadonlyAudit.snapshot(path)

  [root] ->
    Week20ReadonlyAudit.run(root)

  [root, before_path] ->
    Week20ReadonlyAudit.run(root, before_path)

  _ ->
    raise "Usage: mix run scripts/audit_week20.exs FORMAL_DIRECTORY [BEFORE_DATABASE_JSON] | --snapshot PATH"
end
