defmodule AgentSystemsLab.ReleaseAssessment do
  @moduledoc """
  Read-only W25 release evidence assessment under the original full Linux policy.

  `assess/1` takes an explicit verified candidate directory, an optional frozen
  ReleaseStudy directory, and an optional external evidence directory. Missing
  evidence is pending. Present but malformed or mismatched evidence is an error.
  References in environment-evidence.json are bounded regular files relative to
  that evidence directory; source, feedback, commands and archives are never run.

  Hashes and host-supplied execution records establish integrity, not authenticity,
  a person's identity, a new machine, or independent command execution. Even a
  complete assessment records neither release approval nor publication. It does
  not rewrite the historical rc.1 manifest or its release_ready=false decision.
  Use private trees without concurrent writers, as with CandidatePackage.
  """

  import Bitwise, only: [band: 2]
  alias AgentSystemsLab.{CandidatePackage, FrozenFaultMatrix, ReleaseStudy}
  alias AgentSystemsLab.Evaluation.Report

  @max_json 4_194_304
  @max_file 33_554_432
  @commands %{
    "runtime" => ["./scripts/bootstrap_runtime.sh"],
    "postgres" => ["./scripts/bootstrap_postgres.sh"],
    "dependencies" => ["./scripts/mix", "deps.get", "--only", "test"],
    "full" => ["./scripts/mix", "check"],
    "memory" => ["./scripts/mix", "test"],
    "verify" => ["./scripts/mix", "lab.verify"],
    "p1" => ["./scripts/mix", "lab.p1", "--output", "artifacts/reproduction-p1"],
    "history" => ["./scripts/mix", "lab.history", "--output", "artifacts/reproduction-history"],
    "recover" => [
      "./scripts/mix",
      "lab.recover",
      "--output",
      "artifacts/reproduction-recovery",
      "--repetitions",
      "1"
    ],
    "fence" => [
      "./scripts/mix",
      "lab.fence",
      "--output",
      "artifacts/reproduction-fence",
      "--repetitions",
      "1"
    ],
    "upgrade" => ["./scripts/mix", "lab.upgrade", "--output", "artifacts/reproduction-upgrade"],
    "matrix" => ["./scripts/mix", "lab.freeze", "run", "--output", "artifacts/frozen-matrix"],
    "isolation" => ["./scripts/mix", "lab.isolate", "--output", "artifacts/isolation"]
  }
  @cold_commands ~w(runtime postgres dependencies full memory verify p1 history recover fence upgrade)
  @linux_commands ~w(full memory verify p1 history recover fence upgrade matrix isolation)
  @isolation_cases ~w(controlled_file outside_read outside_write symlink_read outside_link executable_link network fork_denied spawn_denied setsid_denied file_size file_descriptors cpu output wall cancel caller_crash unregistered_command)
  @isolation_non_goals [
    "arbitrary target descendants",
    "hard memory quota",
    "total disk quota",
    "network allowlist",
    "multi-tenant boundary"
  ]

  @doc "The immutable v1 policy; a narrower platform requires a separately authorized policy."
  def policy do
    %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.release-policy.v1",
      "policy_id" => "v0.1-original-full-linux-v1",
      "target_version" => "0.1.0",
      "external_readers" => %{"minimum" => 3, "maximum" => 5},
      "required_fresh_workspace_readers" => 1,
      "maximum_unresolved_blockers" => 0,
      "technical_candidate" => "CandidatePackage.verify; unchanged historical rc.1 contract",
      "linux" => "full regression, zero exclusions, 12x20 matrix and 18 isolation probes",
      "cold_install" => "new macOS host, no runtime/dependency/database cache reuse",
      "runtime_pins" => %{"elixir" => "1.20.4", "otp" => "28.4", "postgres" => "18.6"},
      "installation_inputs" => ~w(source otp elixir postgres mix_lock),
      "isolation_non_goals" => @isolation_non_goals,
      "cold_commands" => @cold_commands,
      "linux_commands" => @linux_commands,
      "command_argv" => @commands,
      "approval" => "not assessed; owner decision is separate",
      "publication" => "not implemented"
    }
  end

  @doc "Recomputes release evidence. This function writes no files and starts no application."
  def assess(opts) do
    with :ok <- options(opts),
         {:ok, candidate_root} <- directory(Keyword.fetch!(opts, :candidate)),
         {:ok, candidate} <- CandidatePackage.verify(candidate_root),
         {:ok, manifest_raw} <- read(candidate_root, "candidate-manifest.json", @max_json),
         binding = %{
           "source_manifest_sha256" => candidate.manifest["source_manifest_sha256"],
           "candidate_manifest_sha256" => hash(manifest_raw)
         },
         {:ok, study} <- study(Keyword.get(opts, :study), binding),
         {:ok, external} <-
           external(Keyword.get(opts, :evidence), binding, %{
             "regression" => candidate.manifest["full_regression"],
             "mix_lock_sha256" =>
               Enum.find(candidate.manifest["entries"], &(&1["path"] == "mix.lock"))["sha256"]
           }) do
      gates = %{
        "technical_candidate" => %{
          "status" => "passed",
          "candidate_label" => candidate.manifest["candidate_label"]
        },
        "external_readers" => human_gate(study),
        "cold_install_macos" => environment_gate(external, "cold_install_macos"),
        "linux_full" => environment_gate(external, "linux")
      }

      complete = Enum.all?(gates, fn {_name, gate} -> gate["status"] == "passed" end)

      report = %{
        "schema_version" => 1,
        "kind" => "agent-systems-lab.release-assessment.v1",
        "policy" => policy(),
        "policy_sha256" => Report.hash(policy()),
        "binding" => binding,
        "candidate_manifest_release_ready" => candidate.manifest["release_ready"],
        "study" => study,
        "external_evidence" => external,
        "gates" => gates,
        "evidence_complete" => complete,
        "approval_recorded" => false,
        "publication_status" => "not_published",
        "release_ready" => false,
        "trust" =>
          "host-supplied unverified claims; hashes do not authenticate humans, hosts or execution"
      }

      {:ok, Map.put(report, "report_hash", Report.hash(report))}
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :release_assessment_failed}
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.has_key?(opts, :candidate) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:candidate, :study, :evidence])),
       do: :ok,
       else: {:error, :release_assessment_invalid_options}
  end

  defp study(nil, _binding), do: {:ok, nil}

  defp study(path, binding) do
    with {:ok, root} <- directory(path),
         {:ok, report} <- ReleaseStudy.verify(root),
         true <- report["schema_version"] === 1,
         true <- report["kind"] === "agent-systems-lab.frozen-reader-study-report.v1",
         true <- report["source_manifest_sha256"] === binding["source_manifest_sha256"] do
      {:ok, report}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_assessment_study_binding_mismatch}
    end
  end

  defp external(nil, _binding, _baseline), do: {:ok, nil}

  defp external(path, binding, baseline) do
    with {:ok, root} <- directory(path) do
      case File.lstat(Path.join(root, "environment-evidence.json")) do
        {:error, :enoent} -> {:ok, nil}
        _ -> external_index(root, binding, baseline)
      end
    end
  end

  defp external_index(root, binding, baseline) do
    with {:ok, raw} <- read(root, "environment-evidence.json", @max_json),
         {:ok, index} <- JSON.decode(raw),
         true <-
           exact?(
             index,
             ~w(schema_version kind source_manifest_sha256 candidate_manifest_sha256 archive environments)
           ),
         true <- index["schema_version"] === 1,
         true <- index["kind"] === "agent-systems-lab.release-environment-index.v1",
         true <- bound?(index, binding),
         true <- is_list(index["environments"]) and length(index["environments"]) <= 2,
         {:ok, archive} <- optional_record(root, index["archive"]),
         {:ok, environments} <-
           map(index["environments"], &environment(root, &1, binding, baseline)),
         true <- unique?(environments, "type") and unique?(environments, "id") do
      {:ok, %{"index_sha256" => hash(raw), "archive" => archive, "environments" => environments}}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_assessment_invalid_environment_index}
    end
  end

  defp environment(root, reference, binding, baseline) do
    with {:ok, raw} <- record(root, reference, @max_json),
         {:ok, value} <- JSON.decode(raw),
         true <-
           exact?(
             value,
             ~w(schema_version kind id type scope source_manifest_sha256 candidate_manifest_sha256 provenance excluded_tags commands cleanup)
           ),
         true <-
           value["schema_version"] === 1 and
             value["kind"] === "agent-systems-lab.release-environment.v1",
         true <- bound?(value, binding),
         true <- text?(value["id"], 128) and value["type"] in ~w(cold_install_macos linux),
         true <- value["scope"] in ~w(full core),
         true <- string_list?(value["excluded_tags"], 30),
         :ok <- provenance(value["provenance"], value["type"]),
         true <-
           exact?(
             value["cleanup"],
             ~w(owned_postgres_stopped port_released owned_processes_exited)
           ),
         true <- Enum.all?(Map.values(value["cleanup"]), &is_boolean/1),
         true <- is_list(value["commands"]) and length(value["commands"]) <= map_size(@commands),
         true <- unique?(value["commands"], "id"),
         {:ok, commands} <- map(value["commands"], &command(root, &1)),
         :ok <- command_results(root, value, commands, baseline) do
      reasons = pending_reasons(value, commands, baseline)

      {:ok,
       %{
         "id" => value["id"],
         "type" => value["type"],
         "scope" => value["scope"],
         "record" => reference,
         "provenance" => value["provenance"],
         "excluded_tags" => value["excluded_tags"],
         "commands" => commands,
         "status" => if(reasons == [], do: "passed", else: "pending"),
         "pending_reasons" => reasons
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_assessment_invalid_environment}
    end
  end

  defp provenance(value, type) do
    keys =
      ~w(operator_id host_id platform observed_at_utc self_reported new_host runtime_cache_reused dependency_cache_reused database_reused inputs tools)

    if exact?(value, keys) and text?(value["operator_id"], 128) and text?(value["host_id"], 128) and
         value["platform"] === if(type == "linux", do: "linux", else: "macos") and
         match?({:ok, _, _}, DateTime.from_iso8601(value["observed_at_utc"] || "")) and
         value["self_reported"] === true and
         Enum.all?(
           ~w(new_host runtime_cache_reused dependency_cache_reused database_reused),
           &is_boolean(value[&1])
         ) and
         is_list(value["inputs"]) and length(value["inputs"]) in 1..20 and
         Enum.all?(
           value["inputs"],
           &(exact?(&1, ~w(id origin sha256)) and text?(&1["id"], 128) and
               text?(&1["origin"], 1024) and digest?(&1["sha256"]))
         ) and
         is_map(value["tools"]) and map_size(value["tools"]) in 1..20 and
         Enum.all?(value["tools"], fn {key, val} -> text?(key, 128) and text?(val, 256) end),
       do: :ok,
       else: {:error, :release_assessment_invalid_provenance}
  end

  defp command(root, value) do
    with true <- exact?(value, ~w(id argv exit_status log result)),
         true <- is_map_key(@commands, value["id"]),
         true <- value["argv"] === @commands[value["id"]],
         true <- is_integer(value["exit_status"]) and value["exit_status"] in 0..255,
         {:ok, raw} <- record(root, value["log"], @max_file),
         {:ok, _result} <- optional_record(root, value["result"]),
         {:ok, observed} <- check_footer(value, raw) do
      {:ok, Map.put(value, "observed_regression", observed)}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_assessment_invalid_command}
    end
  end

  defp check_footer(%{"id" => id, "exit_status" => 0}, raw) when id in ~w(full memory) do
    case footer(raw) do
      {:ok, values} -> {:ok, Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end)}
      error -> error
    end
  end

  defp check_footer(_command, _raw), do: {:ok, nil}

  defp command_results(root, value, commands, baseline) do
    by_id = Map.new(commands, &{&1["id"], &1})

    with :ok <- regression_pair(root, by_id, baseline["regression"]),
         :ok <- matrix_result(root, by_id["matrix"]),
         :ok <- isolation_result(root, by_id["isolation"], value["type"]) do
      :ok
    end
  end

  defp regression_pair(
         root,
         %{
           "full" => %{"exit_status" => 0} = full,
           "memory" => %{"exit_status" => 0} = memory
         },
         baseline
       ) do
    with {:ok, raw_full} <- record(root, full["log"], @max_file),
         {:ok, raw_memory} <- record(root, memory["log"], @max_file),
         {:ok, f} <- footer(raw_full),
         {:ok, m} <- footer(raw_memory),
         true <- f.passed + f.excluded == m.passed + m.excluded,
         true <-
           f.passed + f.excluded == baseline["passed"] and f.doctests == baseline["doctests"] and
             m.doctests == baseline["doctests"] do
      :ok
    else
      _ -> {:error, :release_assessment_regression_counts_mismatch}
    end
  end

  defp regression_pair(_root, _commands, _baseline), do: :ok

  defp matrix_result(_root, nil), do: :ok
  defp matrix_result(_root, %{"exit_status" => exit}) when exit != 0, do: :ok

  defp matrix_result(root, command) do
    with %{"path" => relative} <- command["result"],
         true <- Path.basename(relative) == "report.json",
         {:ok, matrix} <- FrozenFaultMatrix.verify(Path.dirname(Path.join(root, relative))),
         true <- matrix["complete"] === true and matrix["all_passed"] === true,
         true <- matrix["totals"]["completed_repetitions"] === 240 do
      :ok
    else
      _ -> {:error, :release_assessment_matrix_invalid}
    end
  end

  defp isolation_result(_root, nil, _type), do: :ok
  defp isolation_result(_root, %{"exit_status" => exit}, _type) when exit != 0, do: :ok

  defp isolation_result(root, command, type) do
    with {:ok, raw} <- record(root, command["result"], @max_json),
         {:ok, report} <- JSON.decode(raw),
         true <-
           exact?(
             report,
             ~w(schema_version all_passed architecture backend backend_enforced expected_probe_count failed_probe platform probe_count probes process_scope unsupported_capabilities)
           ),
         true <- report["schema_version"] === 1 and report["all_passed"] === true,
         true <- report["backend_enforced"] === true and report["failed_probe"] === nil,
         true <- report["probe_count"] === 18 and report["expected_probe_count"] === 18,
         true <-
           is_list(report["probes"]) and
             Enum.map(report["probes"], & &1["case"]) === @isolation_cases,
         true <- Enum.all?(report["probes"], &(known_probe_keys?(&1) and isolation_probe?(&1))),
         true <-
           Enum.all?(report["probes"], fn probe ->
             case probe["result"] do
               nil ->
                 probe["case"] in ~w(caller_crash unregistered_command)

               result ->
                 result["backend"] === report["backend"] and result["status"] === probe["status"]
             end
           end),
         true <-
           is_list(report["unsupported_capabilities"]) and
             Enum.all?(report["unsupported_capabilities"], &(&1 in @isolation_non_goals)),
         true <-
           type != "linux" or
             (text?(report["backend"], 128) and String.starts_with?(report["backend"], "linux.") and
                report["platform"] === "{:unix, :linux}") do
      :ok
    else
      _ -> {:error, :release_assessment_isolation_invalid}
    end
  end

  defp known_probe_keys?(p) do
    allowed =
      ~w(case passed status result controlled_file_bytes canary_exists canary_unchanged permission_denied alias_absent hardlink_denied baseline_connected sandbox_connected creation_or_escape_denied max_target_processes max_file_bytes actual_file_bytes hard_limit_observed fd_limit opened cpu_seconds wall_time_ms max_output_bytes captured_bytes guardian_exited guardian_pid identity_nonce_verified target_exited target_pid target_started command_started reason)

    result_allowed =
      ~w(backend cleanup cpu_ms duration_ms exit_status os_pid output output_bytes signal status target_pid truncated)

    result = p["result"] || %{}
    cleanup = result["cleanup"] || %{}

    Enum.all?(Map.keys(p), &(&1 in allowed)) and is_map(result) and
      Enum.all?(Map.keys(result), &(&1 in result_allowed)) and is_map(cleanup) and
      Enum.all?(
        Map.keys(cleanup),
        &(&1 in ~w(guardian_exited process_group_gone target_exited target_pid))
      )
  end

  defp isolation_probe?(%{"case" => "unregistered_command"} = p),
    do: p["passed"] === true and p["command_started"] === false and p["status"] === "rejected"

  defp isolation_probe?(%{"case" => "caller_crash"} = p),
    do:
      p["passed"] === true and p["guardian_exited"] === true and p["target_exited"] === true and
        p["identity_nonce_verified"] === true

  defp isolation_probe?(p) do
    r = p["result"] || %{}
    cleanup = r["cleanup"] || %{}

    common =
      p["passed"] === true and
        Enum.all?(~w(guardian_exited process_group_gone target_exited), &(cleanup[&1] === true))

    specific =
      case p["case"] do
        "controlled_file" ->
          p["status"] === "succeeded" and p["controlled_file_bytes"] === 19

        name when name in ~w(outside_read outside_write symlink_read) ->
          p["permission_denied"] === true and p["canary_unchanged"] === true

        name when name in ~w(outside_link executable_link) ->
          p["hardlink_denied"] === true and p["alias_absent"] === true

        "network" ->
          p["baseline_connected"] === true and p["sandbox_connected"] === false and
            p["permission_denied"] === true

        name when name in ~w(fork_denied spawn_denied setsid_denied) ->
          p["creation_or_escape_denied"] === true and p["max_target_processes"] === 1

        "file_size" ->
          p["hard_limit_observed"] === true and is_integer(p["actual_file_bytes"]) and
            p["actual_file_bytes"] in 0..4096 and p["max_file_bytes"] === 4096

        "file_descriptors" ->
          p["hard_limit_observed"] === true and is_integer(p["opened"]) and p["opened"] in 0..61 and
            p["fd_limit"] === 64

        "cpu" ->
          p["status"] === "resource_limit" and p["hard_limit_observed"] === true

        "output" ->
          p["status"] === "output_limit" and is_integer(p["captured_bytes"]) and
            p["captured_bytes"] in 0..4096 and p["max_output_bytes"] === 4096

        "wall" ->
          p["status"] === "timed_out" and p["wall_time_ms"] === 100

        "cancel" ->
          p["status"] === "cancelled" and p["identity_nonce_verified"] === true

        _ ->
          false
      end

    common and specific
  end

  defp pending_reasons(value, commands, baseline) do
    required = if value["type"] == "linux", do: @linux_commands, else: @cold_commands
    by_id = Map.new(commands, &{&1["id"], &1})
    p = value["provenance"]
    full = by_id["full"]

    missing =
      for id <- required,
          not match?(%{"exit_status" => 0}, by_id[id]),
          do: "command_pending:" <> id

    scope =
      if value["scope"] == "full" and value["excluded_tags"] == [],
        do: [],
        else: ["full_scope_required"]

    cleanup =
      if Enum.all?(Map.values(value["cleanup"]), &(&1 === true)),
        do: [],
        else: ["owned_cleanup_pending"]

    cache =
      if value["type"] == "cold_install_macos" and
           not (p["new_host"] === true and p["runtime_cache_reused"] === false and
                  p["dependency_cache_reused"] === false and p["database_reused"] === false),
         do: ["cold_host_and_empty_caches_required"],
         else: []

    excluded =
      if full && full["exit_status"] == 0 && full["observed_regression"]["excluded"] > 0,
        do: ["full_regression_has_exclusions"],
        else: []

    pins =
      if Enum.all?(policy()["runtime_pins"], fn {id, version} -> p["tools"][id] === version end),
        do: [],
        else: ["runtime_pins_required"]

    inputs =
      if Enum.all?(policy()["installation_inputs"], fn id ->
           Enum.count(p["inputs"], &(&1["id"] === id)) == 1
         end) and
           Enum.any?(
             p["inputs"],
             &(&1["id"] === "source" and &1["sha256"] === value["source_manifest_sha256"])
           ) and
           Enum.any?(
             p["inputs"],
             &(&1["id"] === "mix_lock" and &1["sha256"] === baseline["mix_lock_sha256"])
           ),
         do: [],
         else: ["installation_input_provenance_missing"]

    missing ++ scope ++ cleanup ++ cache ++ excluded ++ pins ++ inputs
  end

  defp human_gate(nil),
    do: %{"status" => "pending", "reason" => "frozen_study_missing", "external_reader_count" => 0}

  defp human_gate(study) do
    ready =
      study["human_gate_met"] === true and study["external_reader_count"] in 3..5 and
        is_integer(study["external_fresh_reproductions"]) and
        study["external_fresh_reproductions"] >= 1 and study["unresolved_blockers"] === 0

    %{
      "status" => if(ready, do: "passed", else: "pending"),
      "external_reader_count" => study["external_reader_count"],
      "external_fresh_reproductions" => study["external_fresh_reproductions"],
      "unresolved_blockers" => study["unresolved_blockers"]
    }
  end

  defp environment_gate(nil, type),
    do: %{"status" => "pending", "reason" => "environment_evidence_missing", "type" => type}

  defp environment_gate(external, type) do
    case Enum.find(external["environments"], &(&1["type"] == type)) do
      nil -> %{"status" => "pending", "reason" => "environment_evidence_missing", "type" => type}
      record -> Map.take(record, ~w(status id type scope pending_reasons))
    end
  end

  defp footer(raw) do
    case Regex.scan(
           ~r/^Result: (\d+) passed \((\d+) doctests, (\d+) tests\)(?:, (\d+) excluded)?\r?$/m,
           raw
         ) do
      [[_line, passed, doctests, tests | rest]] ->
        excluded =
          case rest do
            [value] when value != "" -> String.to_integer(value)
            _ -> 0
          end

        values = %{
          passed: String.to_integer(passed),
          doctests: String.to_integer(doctests),
          tests: String.to_integer(tests),
          excluded: excluded
        }

        if values.passed > 0 and values.passed == values.doctests + values.tests and
             not Regex.match?(~r/^\s*\d+\)\s|^Result:.*(?:failed|failure)/m, raw),
           do: {:ok, values},
           else: {:error, :release_assessment_invalid_regression_log}

      _ ->
        {:error, :release_assessment_invalid_regression_log}
    end
  end

  defp optional_record(_root, nil), do: {:ok, nil}

  defp optional_record(root, value),
    do: with({:ok, _raw} <- record(root, value, @max_file), do: {:ok, value})

  defp record(root, value, limit) do
    with true <- exact?(value, ~w(path sha256 bytes)),
         true <-
           digest?(value["sha256"]) and is_integer(value["bytes"]) and value["bytes"] in 1..limit,
         {:ok, raw} <- read(root, value["path"], limit),
         true <- byte_size(raw) === value["bytes"] and hash(raw) === value["sha256"],
         do: {:ok, raw},
         else: (_ -> {:error, :release_assessment_evidence_integrity})
  end

  defp read(root, relative, limit) do
    with true <- relative?(relative),
         path = Path.join(root, relative),
         {:ok, _} <- directory(Path.dirname(path)),
         {:ok, before} <- File.lstat(path),
         true <-
           before.type === :regular and before.links === 1 and before.size <= limit and
             band(before.mode, 0o7000) === 0,
         {:ok, raw} <-
           File.open(path, [:read, :binary], fn io ->
             case IO.binread(io, limit + 1) do
               :eof -> ""
               bytes -> bytes
             end
           end),
         {:ok, after_read} <- File.lstat(path),
         true <-
           Map.drop(Map.from_struct(before), [:atime]) ===
             Map.drop(Map.from_struct(after_read), [:atime]) and byte_size(raw) === before.size,
         do: {:ok, raw},
         else: (_ -> {:error, :release_assessment_unsafe_file})
  end

  defp directory(value) when is_binary(value) do
    with true <- Path.type(value) === :absolute and Path.expand(value) === value and safe?(value),
         result =
           Enum.reduce_while(Path.split(value), "", fn part, prefix ->
             next = if prefix == "", do: part, else: Path.join(prefix, part)

             case File.lstat(next) do
               {:ok, %{type: :directory}} -> {:cont, next}
               _ -> {:halt, :error}
             end
           end),
         true <- is_binary(result),
         do: {:ok, value},
         else: (_ -> {:error, :release_assessment_unsafe_directory})
  end

  defp directory(_), do: {:error, :release_assessment_unsafe_directory}

  defp relative?(value),
    do:
      text?(value, 512) and Path.type(value) === :relative and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."])) and
        not String.contains?(value, "\\")

  defp safe?(value), do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max and safe?(value)

  defp string_list?(list, max),
    do:
      is_list(list) and length(list) <= max and length(list) == length(Enum.uniq(list)) and
        Enum.all?(list, &text?(&1, 128))

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp bound?(value, binding),
    do: Enum.all?(binding, fn {key, expected} -> value[key] === expected end)

  defp unique?(list, key),
    do: Enum.all?(list, &is_map/1) and length(list) === length(Enum.uniq_by(list, & &1[key]))

  defp map(list, fun),
    do:
      Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
        case fun.(value) do
          {:ok, next} -> {:cont, {:ok, acc ++ [next]}}
          error -> {:halt, error}
        end
      end)
end
