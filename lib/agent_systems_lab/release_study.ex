defmodule AgentSystemsLab.ReleaseStudy do
  @moduledoc """
  Versioned reading packets bound to an explicit, already frozen source export.

  Original human self-reports and issue events are inert, append-only host files.
  Hashes and a local head detect accidental changes and incomplete writes, not
  forgery by someone able to rewrite the whole packet. Keep an external copy of
  the report hash. No reader is authenticated and no feedback text is executed.
  A changed project requires a new packet and new reader attestations.
  """

  alias AgentSystemsLab.{ReaderStudy, Reproduction}
  alias AgentSystemsLab.Evaluation.Report
  import Bitwise, only: [band: 2]

  @root Path.expand("../..", __DIR__)
  @suite_path Path.join(@root, "fixtures/reader_study/suite.json")
  @external_resource @suite_path
  @suite @suite_path |> File.read!() |> JSON.decode!()
  @kind "agent-systems-lab.frozen-reader-study.v1"
  @report_kind "agent-systems-lab.frozen-reader-study-report.v1"
  @manifest "reproduction-source-manifest.json"
  @protocol_keys ~w(schema_version kind suite assets source_manifest_sha256 protocol_hash)
  @feedback_keys ~w(schema_version protocol_hash source_manifest_sha256 reader_id reader_type independent_of_authors completed started_at_utc finished_at_utc chapters findings reproduction)
  @finding_keys ~w(issue_id chapter location severity description suggestion)
  @fix_keys ~w(schema_version protocol_hash source_manifest_sha256 type issue_id fix_id created_at_utc description evidence_sha256)
  @retest_keys ~w(schema_version protocol_hash source_manifest_sha256 type issue_id fix_id reader_id reader_type independent_of_authors completed started_at_utc finished_at_utc passed description evidence_sha256)
  @event_keys ~w(schema_version seq previous_sha256 protocol_hash source_manifest_sha256 payload event_sha256)
  @head_keys ~w(schema_version protocol_hash event_count last_event_sha256)
  @zero String.duplicate("0", 64)
  @max_json 262_144
  @max_events 512
  @max_ledger_bytes 16_777_216

  def prepare(output, opts \\ []) do
    with :ok <- source_option(opts),
         source = Keyword.fetch!(opts, :source),
         {:ok, frozen} <- Reproduction.verify(source),
         :ok <- source_only(frozen),
         {:ok, manifest_bytes} <- regular(frozen.manifest_path, 4_194_304),
         :ok <- destination(output, frozen),
         :ok <- File.mkdir(output),
         :ok <- File.chmod(output, 0o700),
         {:ok, copied} <- Reproduction.export(Path.join(output, "project"), source: source),
         {:ok, current_manifest_bytes} <- regular(frozen.manifest_path, 4_194_304),
         true <- current_manifest_bytes === manifest_bytes || {:error, :study_source_changed},
         :ok <- preserve_manifest(copied.manifest_path, manifest_bytes),
         {:ok, _} <- Reproduction.verify(Path.join(output, "project")),
         {:ok, suite} <-
           read_json(Path.join([output, "project", "fixtures/reader_study/suite.json"])),
         true <- suite === @suite || {:error, :study_suite_mismatch},
         {:ok, assets} <- asset_hashes(Path.join(output, "project")),
         protocol = %{
           "schema_version" => 1,
           "kind" => @kind,
           "suite" => suite,
           "assets" => assets,
           "source_manifest_sha256" => hash(manifest_bytes)
         },
         protocol = Map.put(protocol, "protocol_hash", Report.hash(protocol)),
         :ok <- validate_protocol(protocol),
         :ok <- private_json(Path.join(output, "protocol.json"), protocol),
         :ok <- private_directory(Path.join(output, "feedback")),
         :ok <- private_directory(Path.join(output, "events")),
         :ok <- private_json(Path.join(output, "head.json"), head(protocol, [])),
         :ok <- private_json(Path.join(output, "feedback-template.json"), template(protocol)),
         :ok <- private_write(Path.join(output, "START-HERE.md"), instructions()),
         {:ok, report} <- verify(output) do
      {:ok, %{output_dir: output, protocol: protocol, report: report}}
    else
      {:error, _} = error -> error
      _ -> {:error, :study_prepare_failed}
    end
  rescue
    _ -> {:error, :study_prepare_failed}
  end

  @doc "Loads and verifies the protocol and frozen project without starting an application."
  def load(study) do
    with :ok <- absolute(study),
         :ok <- directories(study),
         {:ok, protocol} <- read_json(Path.join(study, "protocol.json")),
         :ok <- validate_protocol(protocol),
         {:ok, frozen} <- Reproduction.verify(Path.join(study, "project")),
         {:ok, bytes} <- regular(frozen.manifest_path, 4_194_304),
         true <-
           hash(bytes) === protocol["source_manifest_sha256"] || {:error, :study_source_mismatch},
         {:ok, suite} <- read_json(Path.join(study, "project/fixtures/reader_study/suite.json")),
         true <- suite === protocol["suite"] || {:error, :study_suite_mismatch},
         {:ok, assets} <- asset_hashes(Path.join(study, "project")),
         true <- assets === protocol["assets"] || {:error, :study_assets_mismatch} do
      {:ok, protocol}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_study}
    end
  rescue
    _ -> {:error, :invalid_study}
  end

  @doc "Read-only: recomputes all counts and issue states; no report.json is trusted or written."
  def verify(study) do
    with {:ok, state} <- state(study), do: {:ok, assessment(state)}
  end

  def report(study), do: verify(study)

  @doc "Preserves original feedback bytes and appends an immutable binding event."
  def add_feedback(study, input) do
    with_lock(study, fn ->
      with {:ok, state} <- state(study, true),
           {:ok, bytes} <- regular(input, @max_json),
           {:ok, record} <- JSON.decode(bytes),
           :ok <- validate_feedback(record, state.protocol),
           true <- map_size(state.readers) < 5 || {:error, :study_reader_limit},
           true <-
             not Map.has_key?(state.readers, record["reader_id"]) ||
               {:error, :study_duplicate_reader},
           relative = "feedback/" <> record["reader_id"] <> ".json",
           payload = %{
             "type" => "feedback",
             "reader_id" => record["reader_id"],
             "path" => relative,
             "sha256" => hash(bytes),
             "bytes" => byte_size(bytes)
           },
           :ok <- append_bounds(state, payload),
           :ok <- private_write(Path.join(study, relative), bytes),
           {:ok, event} <- append_event(study, state, payload) do
        {:ok,
         %{
           "reader_id" => record["reader_id"],
           "event_sha256" => event["event_sha256"],
           "saved" => true
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_study_feedback}
      end
    end)
  end

  @doc "Appends a fix or original-reader retest; hashes and descriptions are data only."
  def append(study, input) do
    with_lock(study, fn ->
      with {:ok, state} <- state(study, true),
           {:ok, payload} <- read_json(input),
           {:ok, _next} <- apply_issue_event(state, payload),
           {:ok, event} <- append_event(study, state, payload) do
        {:ok, %{"seq" => event["seq"], "event_sha256" => event["event_sha256"], "saved" => true}}
      end
    end)
  end

  def template(protocol) do
    ReaderStudy.template(protocol)
    |> Map.put("source_manifest_sha256", protocol["source_manifest_sha256"])
  end

  def validate_feedback(record, protocol) do
    findings = if is_map(record), do: record["findings"], else: nil

    valid =
      exact?(record, @feedback_keys) and
        record["source_manifest_sha256"] === protocol["source_manifest_sha256"] and
        is_list(findings) and length(findings) <= 64 and
        Enum.all?(findings, fn item ->
          exact?(item, @finding_keys) and issue_id?(item["issue_id"]) and
            String.starts_with?(item["issue_id"], record["reader_id"] <> "-I")
        end) and Enum.uniq_by(findings, & &1["issue_id"]) === findings

    legacy =
      if valid,
        do:
          record
          |> Map.delete("source_manifest_sha256")
          |> Map.put("findings", Enum.map(findings, &Map.delete(&1, "issue_id")))

    if valid and ReaderStudy.validate_feedback(legacy, protocol) === :ok,
      do: :ok,
      else: {:error, :invalid_study_feedback}
  rescue
    _ -> {:error, :invalid_study_feedback}
  end

  def validate_protocol(protocol) do
    legacy = if is_map(protocol), do: Map.drop(protocol, ["kind", "protocol_hash"]), else: %{}
    legacy = Map.put(legacy, "protocol_hash", Report.hash(legacy))

    if exact?(protocol, @protocol_keys) and protocol["schema_version"] === 1 and
         protocol["kind"] === @kind and
         protocol["protocol_hash"] === Report.hash(Map.delete(protocol, "protocol_hash")) and
         ReaderStudy.validate_protocol(legacy) === :ok,
       do: :ok,
       else: {:error, :invalid_study_protocol}
  rescue
    _ -> {:error, :invalid_study_protocol}
  end

  defp state(study, owns_lock \\ false) do
    with {:ok, protocol} <- load(study),
         :ok <- check_lock(study, owns_lock),
         :ok <- directories(Path.join(study, "feedback")),
         :ok <- directories(Path.join(study, "events")),
         {:ok, names} <- File.ls(Path.join(study, "events")),
         true <- length(names) <= @max_events || {:error, :study_event_limit},
         names = Enum.sort(names),
         true <- names === event_names(length(names)) || {:error, :study_event_sequence},
         initial = %{
           protocol: protocol,
           readers: %{},
           issues: %{},
           fix_ids: MapSet.new(),
           events: [],
           feedback: [],
           ledger: [],
           ledger_bytes: 0
         },
         {:ok, collected} <- replay(study, names, initial),
         {:ok, saved_head_bytes} <- regular(Path.join(study, "head.json"), @max_json),
         {:ok, saved_head} <- JSON.decode(saved_head_bytes),
         true <-
           (exact?(saved_head, @head_keys) and saved_head === head(protocol, collected.events)) ||
             {:error, :study_head_mismatch},
         {:ok, files} <- File.ls(Path.join(study, "feedback")),
         expected = Enum.map(collected.feedback, &Path.basename(&1["path"])) |> Enum.sort(),
         true <- Enum.sort(files) === expected || {:error, :study_orphan_feedback} do
      {:ok, Map.put(collected, :head_sha256, hash(saved_head_bytes))}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_study_ledger}
    end
  rescue
    _ -> {:error, :invalid_study_ledger}
  end

  defp replay(study, names, initial) do
    Enum.reduce_while(names, {:ok, initial}, fn name, {:ok, state} ->
      path = "events/" <> name

      with {:ok, bytes} <- regular(Path.join(study, path), @max_json),
           true <-
             state.ledger_bytes + byte_size(bytes) <= @max_ledger_bytes ||
               {:error, :study_ledger_limit},
           {:ok, event} <- JSON.decode(bytes),
           :ok <- validate_event(event, state),
           {:ok, next} <- apply_payload(study, state, event["payload"]),
           metadata = %{"path" => path, "bytes" => byte_size(bytes), "sha256" => hash(bytes)} do
        {:cont,
         {:ok,
          %{
            next
            | events: state.events ++ [event],
              ledger: state.ledger ++ [metadata],
              ledger_bytes: state.ledger_bytes + byte_size(bytes)
          }}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_study_ledger}}
      end
    end)
  end

  defp validate_event(event, state) do
    last = List.last(state.events)
    previous = if last, do: last["event_sha256"], else: @zero

    if exact?(event, @event_keys) and event["schema_version"] === 1 and
         event["seq"] === length(state.events) + 1 and event["previous_sha256"] === previous and
         bound?(event, state.protocol) and
         event["event_sha256"] === Report.hash(Map.delete(event, "event_sha256")),
       do: :ok,
       else: {:error, :study_event_chain}
  end

  defp apply_payload(study, state, %{"type" => "feedback"} = payload) do
    with true <-
           (exact?(payload, ~w(type reader_id path sha256 bytes)) and
              reader_id?(payload["reader_id"]) and
              payload["path"] === "feedback/" <> payload["reader_id"] <> ".json" and
              digest?(payload["sha256"]) and
              is_integer(payload["bytes"]) and payload["bytes"] in 1..@max_json) ||
             {:error, :invalid_study_feedback_binding},
         true <-
           (map_size(state.readers) < 5 and not Map.has_key?(state.readers, payload["reader_id"])) ||
             {:error, :study_duplicate_reader},
         {:ok, bytes} <- regular(Path.join(study, payload["path"]), @max_json),
         true <-
           (hash(bytes) === payload["sha256"] and byte_size(bytes) === payload["bytes"]) ||
             {:error, :study_feedback_changed},
         {:ok, record} <- JSON.decode(bytes),
         :ok <- validate_feedback(record, state.protocol),
         true <- record["reader_id"] === payload["reader_id"] || {:error, :study_feedback_changed} do
      issues =
        Enum.reduce(record["findings"], state.issues, fn finding, acc ->
          Map.put(acc, finding["issue_id"], %{
            "finding" => finding,
            "reader_id" => record["reader_id"],
            "feedback_finished_at_utc" => record["finished_at_utc"],
            "latest_fix" => nil,
            "latest_retest" => nil,
            "status" => "open"
          })
        end)

      metadata = Map.take(payload, ~w(path bytes sha256))

      {:ok,
       %{
         state
         | readers: Map.put(state.readers, record["reader_id"], record),
           issues: issues,
           feedback: state.feedback ++ [metadata]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_study_feedback_binding}
    end
  end

  defp apply_payload(_study, state, payload), do: apply_issue_event(state, payload)

  defp apply_issue_event(state, %{"type" => "fix"} = payload) do
    issue = state.issues[payload["issue_id"]]

    with true <-
           (exact?(payload, @fix_keys) and payload["schema_version"] === 1 and
              bound?(payload, state.protocol) and
              issue != nil and id?(payload["fix_id"]) and
              not MapSet.member?(state.fix_ids, payload["fix_id"]) and
              text?(payload["description"], 1, 4096) and digest?(payload["evidence_sha256"])) ||
             {:error, :invalid_study_fix},
         true <-
           at_or_after?(payload["created_at_utc"], issue_time(issue)) ||
             {:error, :study_stale_fix} do
      next = %{
        issue
        | "latest_fix" => payload,
          "latest_retest" => nil,
          "status" => "awaiting_original_reader"
      }

      {:ok,
       %{
         state
         | issues: Map.put(state.issues, payload["issue_id"], next),
           fix_ids: MapSet.put(state.fix_ids, payload["fix_id"])
       }}
    else
      {:error, _} = error -> error
    end
  end

  defp apply_issue_event(state, %{"type" => "retest"} = payload) do
    issue = state.issues[payload["issue_id"]]
    fix = if issue, do: issue["latest_fix"]

    with true <-
           (exact?(payload, @retest_keys) and payload["schema_version"] === 1 and
              bound?(payload, state.protocol) and
              issue != nil and fix != nil and issue["latest_retest"] == nil and
              payload["fix_id"] === fix["fix_id"] and
              payload["reader_id"] === issue["reader_id"] and
              payload["reader_type"] === "external_human" and
              payload["independent_of_authors"] === true and payload["completed"] === true and
              is_boolean(payload["passed"]) and
              text?(payload["description"], 1, 4096) and digest?(payload["evidence_sha256"])) ||
             {:error, :invalid_study_retest},
         true <-
           (at_or_after?(payload["started_at_utc"], fix["created_at_utc"]) and
              at_or_after?(payload["finished_at_utc"], payload["started_at_utc"])) ||
             {:error, :study_stale_retest} do
      next = %{
        issue
        | "latest_retest" => payload,
          "status" => if(payload["passed"], do: "resolved_self_reported", else: "open")
      }

      {:ok, %{state | issues: Map.put(state.issues, payload["issue_id"], next)}}
    else
      {:error, _} = error -> error
    end
  end

  defp apply_issue_event(_, _), do: {:error, :invalid_study_issue_event}

  defp issue_time(%{"latest_retest" => %{} = retest}), do: retest["finished_at_utc"]
  defp issue_time(%{"latest_fix" => %{} = fix}), do: fix["created_at_utc"]
  defp issue_time(issue), do: issue["feedback_finished_at_utc"]

  defp assessment(state) do
    readers = Map.values(state.readers)

    issues =
      state.issues
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, issue} -> Map.put(issue, "issue_id", id) end)

    blockers =
      Enum.count(
        issues,
        &(&1["finding"]["severity"] === "blocker" and &1["status"] != "resolved_self_reported")
      )

    fresh =
      Enum.count(
        readers,
        &(&1["reproduction"]["status"] === "passed" and
            &1["reproduction"]["environment"] === "fresh_workspace")
      )

    ready = length(readers) in 3..5 and fresh > 0 and blockers == 0

    result = %{
      "schema_version" => 1,
      "kind" => @report_kind,
      "protocol_hash" => state.protocol["protocol_hash"],
      "source_manifest_sha256" => state.protocol["source_manifest_sha256"],
      "feedback_manifest_sha256" => Report.hash(Enum.sort_by(state.feedback, & &1["path"])),
      "ledger_sha256" => Report.hash(state.ledger),
      "ledger_head_sha256" => state.head_sha256,
      "event_count" => length(state.events),
      "external_reader_count" => length(readers),
      "external_reader_target" => %{"minimum" => 3, "maximum" => 5},
      "external_fresh_reproductions" => fresh,
      "unresolved_blockers" => blockers,
      "issues" => issues,
      "human_gate_met" => ready,
      "external_reader_status" =>
        cond do
          ready -> "passed_self_reported"
          blockers > 0 -> "needs_revision"
          true -> "pending"
        end,
      "release_ready" => false,
      "evidence_policy" =>
        "Host-supplied self-reports; not authenticated humans or execution proofs. Hashes detect integrity changes, not whole-ledger forgery or truncation with a rewritten head. Preserve an external report hash. No source or approval inheritance across packets."
    }

    Map.put(result, "report_hash", Report.hash(result))
  end

  defp append_event(study, state, payload) do
    last = List.last(state.events)

    event = %{
      "schema_version" => 1,
      "seq" => length(state.events) + 1,
      "previous_sha256" => if(last, do: last["event_sha256"], else: @zero),
      "protocol_hash" => state.protocol["protocol_hash"],
      "source_manifest_sha256" => state.protocol["source_manifest_sha256"],
      "payload" => payload
    }

    event = Map.put(event, "event_sha256", Report.hash(event))
    bytes = JSON.encode!(event) <> "\n"
    temp = Path.join(study, ".head-" <> Ecto.UUID.generate() <> ".tmp")

    with true <-
           (event["seq"] <= @max_events and byte_size(bytes) <= @max_json and
              state.ledger_bytes + byte_size(bytes) <= @max_ledger_bytes) ||
             {:error, :study_event_limit},
         :ok <- private_write(Path.join([study, "events", event_name(event["seq"])]), bytes),
         :ok <- private_json(temp, head(state.protocol, state.events ++ [event])),
         :ok <- File.rename(temp, Path.join(study, "head.json")) do
      {:ok, event}
    else
      {:error, _} = error -> error
      _ -> {:error, :study_append_failed}
    end
  end

  defp append_bounds(state, payload) do
    event = %{
      "schema_version" => 1,
      "seq" => length(state.events) + 1,
      "previous_sha256" => @zero,
      "protocol_hash" => state.protocol["protocol_hash"],
      "source_manifest_sha256" => state.protocol["source_manifest_sha256"],
      "payload" => payload,
      "event_sha256" => @zero
    }

    size = byte_size(JSON.encode!(event)) + 1

    if length(state.events) < @max_events and size <= @max_json and
         state.ledger_bytes + size <= @max_ledger_bytes,
       do: :ok,
       else: {:error, :study_event_limit}
  end

  defp head(protocol, events),
    do: %{
      "schema_version" => 1,
      "protocol_hash" => protocol["protocol_hash"],
      "event_count" => length(events),
      "last_event_sha256" => if(events == [], do: @zero, else: List.last(events)["event_sha256"])
    }

  defp event_names(0), do: []
  defp event_names(count), do: Enum.map(1..count, &event_name/1)
  defp event_name(seq), do: String.pad_leading(Integer.to_string(seq), 6, "0") <> ".json"

  defp with_lock(study, fun) do
    with :ok <- absolute(study), :ok <- directories(study) do
      lock = Path.join(study, ".append.lock")

      case File.mkdir(lock) do
        :ok ->
          try do
            with :ok <- File.chmod(lock, 0o700), do: fun.()
          after
            File.rmdir(lock)
          end

        {:error, :eexist} ->
          {:error, :study_append_locked}

        _ ->
          {:error, :study_append_lock_failed}
      end
    end
  rescue
    _ -> {:error, :study_append_failed}
  end

  defp source_option(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) === [:source] and
         absolute(Keyword.fetch!(opts, :source)) === :ok,
       do: :ok,
       else: {:error, :study_frozen_source_required}
  rescue
    _ -> {:error, :study_frozen_source_required}
  end

  defp source_only(frozen) do
    expected =
      [@manifest | Enum.map(frozen.manifest["entries"], &(&1["path"] |> Path.split() |> hd()))]
      |> Enum.uniq()
      |> Enum.sort()

    with {:ok, names} <- File.ls(frozen.output_dir),
         true <- Enum.sort(names) === expected do
      :ok
    else
      _ -> {:error, :study_source_only_export_required}
    end
  end

  defp check_lock(_study, true), do: :ok

  defp check_lock(study, false) do
    case File.lstat(Path.join(study, ".append.lock")) do
      {:error, :enoent} -> :ok
      _ -> {:error, :study_append_locked}
    end
  end

  defp destination(output, frozen) do
    with :ok <- absolute(output),
         :ok <- directories(Path.dirname(output)),
         {:error, :enoent} <- File.lstat(output) do
      selected =
        frozen.manifest["entries"]
        |> Enum.filter(&(&1["type"] == "directory"))
        |> Enum.map(&identity(Path.join(frozen.output_dir, &1["path"])))
        |> then(&[identity(frozen.output_dir) | &1])
        |> MapSet.new()

      if Enum.any?(ancestors(Path.dirname(output)), &MapSet.member?(selected, identity(&1))),
        do: {:error, :study_output_inside_source},
        else: :ok
    else
      {:ok, _} -> {:error, :study_output_exists}
      {:error, _} = error -> error
      _ -> {:error, :study_unsafe_output}
    end
  end

  defp ancestors(path),
    do: if(Path.dirname(path) == path, do: [path], else: [path | ancestors(Path.dirname(path))])

  defp identity(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp preserve_manifest(path, bytes) do
    with :ok <- File.write(path, bytes), do: File.chmod(path, 0o600)
  end

  defp asset_hashes(project) do
    paths =
      (["docs/recovery-runbook.md", "book/reader-study/README.md"] ++
         Enum.flat_map(@suite["chapters"], &[&1["path"] | &1["labs"]]))
      |> Enum.uniq()

    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, assets} ->
      case regular(Path.join(project, path), 2_097_152) do
        {:ok, bytes} ->
          {:cont,
           {:ok, Map.put(assets, path, %{"bytes" => byte_size(bytes), "sha256" => hash(bytes)})}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp read_json(path) do
    with {:ok, bytes} <- regular(path, @max_json),
         {:ok, value} <- JSON.decode(bytes),
         do: {:ok, value}
  end

  defp regular(path, limit) do
    with :ok <- absolute(path),
         :ok <- directories(Path.dirname(path)),
         {:ok, %{type: :regular, links: 1, size: size, mode: mode} = before} <- File.lstat(path),
         true <- size in 1..limit and band(mode, 0o7000) == 0,
         {:ok, bytes} <-
           File.open(path, [:read, :binary], fn io ->
             case IO.binread(io, limit + 1) do
               :eof -> ""
               result -> result
             end
           end),
         true <- is_binary(bytes) and byte_size(bytes) == size,
         {:ok, after_read} <- File.lstat(path),
         true <-
           Map.drop(Map.from_struct(before), [:atime]) ===
             Map.drop(Map.from_struct(after_read), [:atime]) do
      {:ok, bytes}
    else
      _ -> {:error, :study_unsafe_file}
    end
  end

  defp directories(path) do
    path
    |> Path.split()
    |> Enum.reduce_while("", fn part, parent ->
      next = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(next) do
        {:ok, %{type: :directory, mode: mode}} when band(mode, 0o6000) == 0 -> {:cont, next}
        _ -> {:halt, {:error, :study_unsafe_directory}}
      end
    end)
    |> case do
      value when is_binary(value) -> :ok
      error -> error
    end
  end

  defp private_directory(path), do: with(:ok <- File.mkdir(path), do: File.chmod(path, 0o700))
  defp private_json(path, value), do: private_write(path, JSON.encode!(value) <> "\n")

  defp private_write(path, bytes),
    do: with(:ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, 0o600))

  defp absolute(path),
    do:
      if(text?(path, 1, 4096) and Path.type(path) == :absolute and Path.expand(path) == path,
        do: :ok,
        else: {:error, :study_absolute_path_required}
      )

  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) === Enum.sort(keys)

  defp text?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp reader_id?(value), do: is_binary(value) and Regex.match?(~r/\AR[0-9]{2}\z/, value)

  defp issue_id?(value),
    do: is_binary(value) and Regex.match?(~r/\AR[0-9]{2}-I(?:0[1-9]|[1-5][0-9]|6[0-4])\z/, value)

  defp id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/, value)

  defp bound?(value, protocol),
    do:
      value["protocol_hash"] === protocol["protocol_hash"] and
        value["source_manifest_sha256"] === protocol["source_manifest_sha256"]

  defp at_or_after?(later, earlier) do
    with {:ok, last, 0} <- DateTime.from_iso8601(later),
         {:ok, first, 0} <- DateTime.from_iso8601(earlier),
         do: DateTime.compare(last, first) in [:eq, :gt],
         else: (_ -> false)
  rescue
    _ -> false
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp instructions do
    """
    # Frozen source reading packet

    This root entry governs the packet. project/ is the selected historical frozen
    source (for example Week 24), so it does not contain the newer host-side
    lab.reading.frozen or release-assessment commands. Its W22 reading guide remains
    historical. Use the trusted Week 25 host for intake, ledger and assessment.
    Read project/book/reader-study/README.md for the six chapters. Keep project/
    unchanged and run exercises in a separate workspace. The protocol binds the
    original source manifest bytes, not whatever is in the author's current tree.
    Copy feedback-template.json outside this packet. Add an issue_id such as R01-I01
    to each finding. Agents, templates and authors do not count as external readers.
    Submit original JSON to the trusted host; descriptions and evidence hashes are
    inert data. Fixes remain open until the same reader retests the latest fix.

    A same-source fix is a documented explanation or environment correction. Changes
    to source or teaching files require a new packet and new human evidence. No old
    approval is transferred. The report recomputes feedback and events read-only.
    A partial write, stale head or abandoned .append.lock fails closed: preserve the
    packet for inspection and restore from independently held evidence; never delete
    a blocker or rewind the ledger to manufacture acceptance. Hashes are integrity,
    not authentication. Keep a report hash outside this packet. This packet cannot
    authorize a release or bypass permissions, budgets, deadlines or recovery rules.
    """
  end
end
