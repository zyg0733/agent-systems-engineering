defmodule AgentSystemsLab.ReaderStudy do
  @moduledoc """
  Host-operated reading packets and explicit external-reader acceptance gates.

  Feedback is inert self-reported data. IDs, hashes and attestations bind an
  account to a frozen packet; they do not authenticate a person or independently
  prove that commands were executed. Agents and templates cannot count as people.
  This tooling does not start the application, query storage or execute feedback.
  """
  alias AgentSystemsLab.Evaluation.Report
  alias AgentSystemsLab.Reproduction

  @root Path.expand("../..", __DIR__)
  @suite Path.join(@root, "fixtures/reader_study/suite.json")
  @external_resource @suite
  @expected_suite @suite |> File.read!() |> JSON.decode!()
  @chapters ~w(ch02 ch05 ch08 ch14 ch16 ch20)
  @commands ~w(verify p1 history recover fence upgrade)
  @record_keys ~w(schema_version protocol_hash reader_id reader_type independent_of_authors completed started_at_utc finished_at_utc chapters findings reproduction)
  @technical_keys ~w(schema_version fresh_source_export isolated_runtime isolated_dependencies isolated_postgres full_regression memory_regression main_experiments source_unchanged evidence_sha256)
  @technical_flags @technical_keys -- ~w(schema_version evidence_sha256)
  @max_json 262_144
  @max_report 2_097_152
  @report_keys ~w(schema_version protocol_hash external_reader_count external_reader_target external_reader_status external_fresh_reproductions feedback_sha256 findings unresolved_blockers technical_status technical_evidence p5_external_gate_met evidence_policy report_hash)

  def prepare(output) do
    with :ok <- absolute_path(output),
         :ok <- output_outside_selected_source(output),
         :ok <- fresh_directory(output),
         {:ok, exported} <- Reproduction.export(Path.join(output, "project")),
         {:ok, suite} <- read_json(@suite),
         {:ok, assets} <- assets(suite),
         protocol = %{
           "schema_version" => 1,
           "suite" => suite,
           "assets" => assets,
           "source_manifest_sha256" => file_hash(exported.manifest_path)
         },
         protocol = Map.put(protocol, "protocol_hash", Report.hash(protocol)),
         :ok <- validate_protocol(protocol),
         :ok <- private_json(Path.join(output, "protocol.json"), protocol),
         :ok <- File.mkdir(Path.join(output, "feedback")),
         :ok <- private_json(Path.join(output, "feedback-template.json"), template(protocol)),
         :ok <- File.write(Path.join(output, "START-HERE.md"), instructions()),
         {:ok, report} <- assess(protocol, [], nil),
         :ok <- private_json(Path.join(output, "report.json"), report) do
      {:ok, %{output_dir: output, protocol: protocol, report: report}}
    end
  rescue
    _ -> {:error, :reading_packet_failed}
  end

  def load(study) do
    with :ok <- absolute_path(study),
         :ok <- directories(study),
         {:ok, _} <- Reproduction.verify(Path.join(study, "project")),
         {:ok, protocol} <- read_json(Path.join(study, "protocol.json")),
         :ok <- validate_protocol(protocol),
         {:ok, frozen_suite} <-
           read_json(Path.join(study, "project/fixtures/reader_study/suite.json")),
         true <- protocol["suite"] === frozen_suite || {:error, :reading_suite_mismatch},
         true <-
           file_hash(Path.join(study, "project/reproduction-source-manifest.json")) ===
             protocol["source_manifest_sha256"] || {:error, :reading_source_mismatch},
         :ok <- verify_assets(study, protocol) do
      {:ok, protocol}
    end
  rescue
    _ -> {:error, :invalid_reading_packet}
  end

  def add_feedback(study, feedback_path) do
    with {:ok, protocol} <- load(study),
         {:ok, record} <- read_json(feedback_path),
         :ok <- validate_feedback(record, protocol),
         {:ok, existing} <- records(study, protocol),
         true <- length(existing) < 5 || {:error, :reader_limit_reached},
         true <-
           not Enum.any?(existing, &(&1["reader_id"] === record["reader_id"])) ||
             {:error, :duplicate_reader},
         :ok <-
           private_json(
             Path.join([study, "feedback", record["reader_id"] <> ".json"]),
             record
           ) do
      {:ok, %{"reader_id" => record["reader_id"], "saved" => true}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_reader_feedback}
    end
  end

  def report(study, technical \\ nil) do
    with {:ok, protocol} <- load(study),
         {:ok, records} <- records(study, protocol),
         {:ok, report} <- assess(protocol, records, technical),
         :ok <- replace_report(study, report) do
      {:ok, report}
    end
  end

  @doc "Reads bounded inert technical JSON with the same file rules as feedback."
  def report_from_file(study, path) do
    with {:ok, technical} <- read_json(path), do: report(study, technical)
  end

  @doc "An unfilled template is deliberately invalid as accepted human feedback."
  def template(protocol) do
    %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "reader_id" => "R01",
      "reader_type" => "external_human",
      "independent_of_authors" => false,
      "completed" => false,
      "started_at_utc" => nil,
      "finished_at_utc" => nil,
      "chapters" => [],
      "findings" => [],
      "reproduction" => %{"status" => "not_attempted", "environment" => "none", "commands" => []}
    }
  end

  def assess(protocol, records, technical) when is_list(records) do
    with :ok <- validate_protocol(protocol),
         true <- length(records) <= 5 || {:error, :reader_limit_reached},
         :ok <- each(records, &validate_feedback(&1, protocol)),
         true <-
           Enum.uniq_by(records, & &1["reader_id"]) === records || {:error, :duplicate_reader},
         :ok <- validate_technical(technical) do
      findings = Enum.flat_map(records, & &1["findings"])
      blockers = Enum.count(findings, &(&1["severity"] === "blocker"))
      independent_reproductions = Enum.count(records, &fresh_reproduction?/1)
      human_ready = length(records) in 3..5 and blockers == 0 and independent_reproductions > 0

      technical_ready =
        technical != nil and Enum.all?(@technical_flags, &(technical[&1] === true))

      status =
        cond do
          human_ready -> "passed_self_reported"
          blockers > 0 -> "needs_revision"
          true -> "pending"
        end

      result = %{
        "schema_version" => 1,
        "protocol_hash" => protocol["protocol_hash"],
        "external_reader_count" => length(records),
        "external_reader_target" => %{"minimum" => 3, "maximum" => 5},
        "external_reader_status" => status,
        "external_fresh_reproductions" => independent_reproductions,
        "feedback_sha256" => Report.hash(records),
        "findings" => findings,
        "unresolved_blockers" => blockers,
        "technical_status" => if(technical_ready, do: "passed", else: "pending"),
        "technical_evidence" => technical,
        "p5_external_gate_met" => human_ready and technical_ready,
        "evidence_policy" =>
          "Human records are host-supplied self-reports; automated and agent reviews are excluded. No authentication claim."
      }

      {:ok, Map.put(result, "report_hash", Report.hash(result))}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_reading_assessment}
    end
  end

  def assess(_, _, _), do: {:error, :invalid_reading_assessment}

  def validate_feedback(record, protocol) do
    valid =
      exact?(record, @record_keys) and record["schema_version"] === 1 and
        record["protocol_hash"] === protocol["protocol_hash"] and
        id?(record["reader_id"]) and record["reader_type"] === "external_human" and
        record["independent_of_authors"] === true and record["completed"] === true and
        timestamps?(record["started_at_utc"], record["finished_at_utc"]) and
        record["chapters"] === @chapters and findings?(record["findings"]) and
        reproduction?(record["reproduction"]) and byte_size(JSON.encode!(record)) <= @max_json

    if valid, do: :ok, else: {:error, :invalid_reader_feedback}
  rescue
    _ -> {:error, :invalid_reader_feedback}
  end

  def validate_protocol(protocol) do
    suite = protocol["suite"]
    assets = protocol["assets"]

    valid =
      exact?(protocol, ~w(schema_version suite assets source_manifest_sha256 protocol_hash)) and
        protocol["schema_version"] === 1 and digest?(protocol["source_manifest_sha256"]) and
        digest?(protocol["protocol_hash"]) and
        protocol["protocol_hash"] === Report.hash(Map.delete(protocol, "protocol_hash")) and
        suite === @expected_suite and is_map(suite) and suite["schema_version"] === 1 and
        suite["week"] === 22 and
        suite["minimum_external_readers"] === 3 and suite["maximum_external_readers"] === 5 and
        suite["command_ids"] === @commands and
        is_list(suite["chapters"]) and Enum.map(suite["chapters"], & &1["id"]) === @chapters and
        is_map(assets) and Enum.sort(Map.keys(assets)) === expected_asset_paths(suite) and
        Enum.all?(assets, fn {path, metadata} ->
          relative?(path) and exact?(metadata, ~w(bytes sha256)) and
            is_integer(metadata["bytes"]) and metadata["bytes"] in 1..2_097_152 and
            digest?(metadata["sha256"])
        end) and
        Enum.all?(suite["chapters"], fn row ->
          exact?(row, ~w(id path labs)) and relative?(row["path"]) and
            is_list(row["labs"]) and row["labs"] != [] and
            Enum.all?([row["path"] | row["labs"]], &Map.has_key?(assets, &1))
        end)

    if valid, do: :ok, else: {:error, :invalid_reading_protocol}
  rescue
    _ -> {:error, :invalid_reading_protocol}
  end

  defp validate_technical(nil), do: :ok

  defp validate_technical(value) do
    if exact?(value, @technical_keys) and value["schema_version"] === 1 and
         digest?(value["evidence_sha256"]) and Enum.all?(@technical_flags, &is_boolean(value[&1])),
       do: :ok,
       else: {:error, :invalid_technical_evidence}
  end

  defp findings?(items) when is_list(items) and length(items) <= 64 do
    Enum.all?(items, fn item ->
      exact?(item, ~w(chapter location severity description suggestion)) and
        item["chapter"] in @chapters and item["severity"] in ~w(blocker major minor) and
        text?(item["location"], 1, 256) and text?(item["description"], 1, 4096) and
        text?(item["suggestion"], 0, 4096)
    end)
  end

  defp findings?(_), do: false

  defp reproduction?(value) do
    exact?(value, ~w(status environment commands)) and
      value["status"] in ~w(passed blocked not_attempted) and
      value["environment"] in ~w(fresh_workspace existing_workspace none) and
      is_list(value["commands"]) and length(value["commands"]) <= length(@commands) and
      Enum.all?(value["commands"], fn item ->
        exact?(item, ~w(id outcome evidence)) and item["id"] in @commands and
          item["outcome"] in ~w(passed failed) and text?(item["evidence"], 1, 1024)
      end) and
      Enum.uniq_by(value["commands"], & &1["id"]) === value["commands"] and
      case value["status"] do
        "passed" ->
          value["environment"] != "none" and
            Enum.sort(Enum.map(value["commands"], & &1["id"])) === Enum.sort(@commands) and
            Enum.all?(value["commands"], &(&1["outcome"] === "passed"))

        "not_attempted" ->
          value["environment"] === "none" and value["commands"] === []

        "blocked" ->
          value["environment"] != "none" and value["commands"] != [] and
            Enum.any?(value["commands"], &(&1["outcome"] === "failed"))
      end
  rescue
    _ -> false
  end

  defp fresh_reproduction?(record),
    do:
      record["reproduction"]["status"] === "passed" and
        record["reproduction"]["environment"] === "fresh_workspace"

  defp timestamps?(start, finish) do
    with {:ok, started, 0} <- DateTime.from_iso8601(start),
         {:ok, finished, 0} <- DateTime.from_iso8601(finish),
         do: DateTime.compare(started, finished) in [:lt, :eq],
         else: (_ -> false)
  rescue
    _ -> false
  end

  defp assets(suite) do
    files =
      ["docs/recovery-runbook.md", "book/reader-study/README.md"] ++
        Enum.flat_map(suite["chapters"], &[&1["path"] | &1["labs"]])

    Enum.reduce_while(Enum.uniq(files), {:ok, %{}}, fn relative, {:ok, collected} ->
      path = Path.join(@root, relative)

      case regular(path, 2_097_152) do
        {:ok, bytes} ->
          {:cont,
           {:ok,
            Map.put(collected, relative, %{"bytes" => byte_size(bytes), "sha256" => hash(bytes)})}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp verify_assets(study, protocol) do
    each(protocol["assets"], fn {relative, expected} ->
      with {:ok, bytes} <- regular(Path.join([study, "project", relative]), 2_097_152),
           true <- byte_size(bytes) === expected["bytes"] and hash(bytes) === expected["sha256"],
           do: :ok,
           else: (_ -> {:error, :reading_asset_mismatch})
    end)
  end

  defp records(study, protocol) do
    directory = Path.join(study, "feedback")

    with :ok <- directories(directory),
         {:ok, files} <- File.ls(directory),
         true <- length(files) <= 5 || {:error, :reader_limit_reached} do
      Enum.reduce_while(Enum.sort(files), {:ok, []}, fn file, {:ok, result} ->
        with {:ok, item} <- read_json(Path.join(directory, file)),
             :ok <- validate_feedback(item, protocol),
             true <- file === item["reader_id"] <> ".json" do
          {:cont, {:ok, result ++ [item]}}
        else
          _ -> {:halt, {:error, :invalid_saved_feedback}}
        end
      end)
    end
  end

  defp read_json(path, limit \\ @max_json) do
    with {:ok, bytes} <- regular(path, limit),
         {:ok, value} <- JSON.decode(bytes),
         do: {:ok, value}
  end

  defp regular(path, limit) do
    with :ok <- absolute_path(path),
         :ok <- directories(Path.dirname(path)),
         {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(path),
         true <- size in 1..limit || {:error, :reading_file_limit},
         do: File.read(path),
         else: (_ -> {:error, :unsafe_reading_file})
  end

  defp output_outside_selected_source(output) do
    entities =
      Enum.map(~w(.github book config docs fixtures labs lib priv scripts test), fn name ->
        stat = File.stat!(Path.join(@root, name))
        {stat.major_device, stat.minor_device, stat.inode}
      end)

    Path.split(output)
    |> Enum.reduce_while("", fn part, parent ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      case File.stat(current) do
        {:ok, stat} ->
          if {stat.major_device, stat.minor_device, stat.inode} in entities,
            do: {:halt, {:error, :reading_output_inside_source}},
            else: {:cont, current}

        {:error, :enoent} ->
          {:cont, current}

        _ ->
          {:halt, {:error, :unsafe_reading_directory}}
      end
    end)
    |> case do
      final when is_binary(final) -> :ok
      error -> error
    end
  end

  defp fresh_directory(path) do
    with :ok <- make_directories(Path.dirname(path)) do
      case File.mkdir(path) do
        :ok -> File.chmod(path, 0o700)
        {:error, :eexist} -> {:error, {:output_exists, path}}
        error -> error
      end
    end
  end

  defp make_directories(path) do
    Path.split(path)
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, parent} ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :directory}} ->
          {:cont, {:ok, current}}

        {:error, :enoent} ->
          case File.mkdir(current) do
            :ok -> {:cont, {:ok, current}}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :unsafe_reading_directory}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp expected_asset_paths(suite) do
    (["docs/recovery-runbook.md", "book/reader-study/README.md"] ++
       Enum.flat_map(suite["chapters"], &[&1["path"] | &1["labs"]]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp directories(path) do
    Path.split(path)
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, parent} ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, current}}
        _ -> {:halt, {:error, :unsafe_reading_directory}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp private_json(path, value) do
    with :ok <- File.write(path, JSON.encode!(value) <> "\n", [:exclusive]),
         do: File.chmod(path, 0o600)
  end

  defp replace_report(study, report) do
    path = Path.join(study, "report.json")
    temp = Path.join(study, ".report-#{Ecto.UUID.generate()}.tmp")

    with {:ok, old} <- read_json(path, @max_report),
         true <-
           (exact?(old, @report_keys) and old["schema_version"] === 1 and
              old["report_hash"] === Report.hash(Map.delete(old, "report_hash"))) ||
             {:error, :invalid_saved_reading_report},
         true <-
           old["protocol_hash"] === report["protocol_hash"] || {:error, :reading_report_conflict},
         :ok <- private_json(temp, report),
         :ok <- File.rename(temp, path),
         do: :ok
  end

  defp absolute_path(value) do
    if text?(value, 1, 4096) and Path.type(value) === :absolute and Path.expand(value) === value,
      do: :ok,
      else: {:error, :invalid_reading_path}
  end

  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) === Enum.sort(keys)

  defp text?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp id?(value), do: is_binary(value) and Regex.match?(~r/\AR[0-9]{2}\z/, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp relative?(value),
    do:
      text?(value, 1, 512) and Path.type(value) === :relative and
        not Enum.any?(Path.split(value), &(&1 in [".", "..", ""]))

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp file_hash(path), do: path |> File.read!() |> hash()

  defp each(values, fun),
    do:
      Enum.reduce_while(values, :ok, fn item, :ok ->
        case fun.(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp instructions do
    """
    # Week 22 reading packet

    Start at [六章试读指南](project/book/reader-study/README.md). The project/ tree
    contains frozen source and documentation, without runtime, dependencies,
    compiled beams, artifacts or previous databases. Follow its environment plan
    before running experiments. Use a separate workspace for exercise edits.

    Copy feedback-template.json outside this packet and fill it as your own
    self-report. The blank template is not a completed reader record. Never
    substitute an agent, author or automated run for an external human. Supply
    your record to the trusted host; feedback text is never executed as commands.

    The initial report deliberately has zero external readers and an unmet P5
    gate. Technical reproduction evidence and human evidence have separate gates.
    """
  end
end
