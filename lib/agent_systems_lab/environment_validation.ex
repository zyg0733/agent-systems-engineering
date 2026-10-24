defmodule AgentSystemsLab.EnvironmentValidation do
  @moduledoc """
  File-only plans and bounded evidence collection for the W26 environment runner.

  The Python runner executes a compiled command list against explicitly trusted,
  frozen source. This module never runs source, commands, installers or an app.
  Collection preserves raw observations; it cannot authenticate an operator, a
  new host, a cache declaration or command execution. Linux core is deliberately
  incomplete under the unchanged full Linux release policy.
  """

  import Bitwise, only: [band: 2]
  alias AgentSystemsLab.{CandidatePackage, ReleaseAssessment, Reproduction}
  alias AgentSystemsLab.Evaluation.Report

  @json_limit 4_194_304
  @file_limit 33_554_432
  @total_limit 268_435_456
  @profiles ~w(macos-warm macos-cold linux-core)
  @reserved ~w(execution.json source-manifest.json environment-validation.json report.json environment-evidence.json environment.json)

  @doc "Returns fixed command data, binding verified source and an optional candidate."
  def plan(source, opts \\ []) do
    with :ok <- options(opts, [:profile, :candidate]),
         profile when profile in @profiles <- Keyword.get(opts, :profile),
         {:ok, context} <- context(source, Keyword.get(opts, :candidate)) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "agent-systems-lab.environment-plan.v1",
         "binding" => context.binding,
         "profile" => profile,
         "platform" => platform(profile),
         "scope" => if(profile == "linux-core", do: "core", else: "full"),
         "excluded_tags" => if(profile == "linux-core", do: ["seatbelt"], else: []),
         "commands" => Enum.map(command_ids(profile), &%{"id" => &1, "argv" => argv(&1)}),
         "runtime_pins" => ReleaseAssessment.policy()["runtime_pins"],
         "release_policy_sha256" => Report.hash(ReleaseAssessment.policy()),
         "release_ready" => false,
         "trust" => "Fixed plan only; no commands executed, no host or operator authenticated"
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_invalid_profile}
    end
  rescue
    _ -> {:error, :environment_plan_failed}
  end

  @doc "Copies a validated execution and referenced files into a fresh immutable bundle."
  def collect(opts) do
    with :ok <- options(opts, [:source, :candidate, :execution, :output]),
         {:ok, context} <- context(Keyword.get(opts, :source), Keyword.get(opts, :candidate)),
         {:ok, execution_root} <- directory(Keyword.get(opts, :execution)),
         {:ok, raw} <- read(execution_root, "execution.json", @json_limit),
         {:ok, execution} <- decode(raw),
         {:ok, observed} <- execution(execution_root, execution, context),
         {:ok, files} <- evidence_files(execution_root, execution, raw, context),
         {:ok, output} <-
           fresh(
             Keyword.get(opts, :output),
             Enum.reject([context.source, execution_root, context.candidate], &is_nil/1)
           ),
         :ok <- File.mkdir(output),
         :ok <- File.chmod(output, 0o700),
         :ok <- copy_files(output, files),
         manifest = manifest(execution, files),
         :ok <- json(output, "environment-validation.json", manifest),
         :ok <- release_files(output, execution, context),
         {:ok, report} <- report(output, execution, observed, context),
         :ok <- json(output, "report.json", report) do
      {:ok, report}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_collection_failed}
    end
  rescue
    _ -> {:error, :environment_collection_failed}
  end

  @doc "Recomputes evidence from files and explicit source; cached report.json is ignored."
  def verify(bundle, opts) do
    with :ok <- options(opts, [:source, :candidate]),
         {:ok, context} <- context(Keyword.get(opts, :source), Keyword.get(opts, :candidate)),
         {:ok, root} <- directory(bundle),
         {:ok, raw} <- read(root, "execution.json", @json_limit),
         {:ok, execution} <- decode(raw),
         {:ok, observed} <- execution(root, execution, context),
         {:ok, files} <- evidence_files(root, execution, raw, context),
         {:ok, source_raw} <- read(root, "source-manifest.json", @json_limit),
         true <- source_raw === context.source_raw,
         {:ok, manifest_raw} <- read(root, "environment-validation.json", @json_limit),
         {:ok, actual_manifest} <- decode(manifest_raw),
         true <- actual_manifest === manifest(execution, files),
         :ok <- verify_release_files(root, execution, context),
         {:ok, report} <- report(root, execution, observed, context) do
      {:ok, report}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_bundle_mismatch}
    end
  rescue
    _ -> {:error, :environment_verification_failed}
  end

  defp context(source, candidate) do
    with {:ok, root} <- directory(source),
         {:ok, verified} <- Reproduction.verify(root),
         {:ok, names} <- File.ls(root),
         true <-
           Enum.all?(
             names,
             &(&1 in (verified.manifest["includes"] ++
                        verified.manifest["excludes"] ++ ["reproduction-source-manifest.json"]))
           ),
         {:ok, raw} <- read(root, "reproduction-source-manifest.json", @json_limit),
         {:ok, lock} <- read(root, "mix.lock", @json_limit),
         {:ok, candidate_binding} <- candidate(candidate, hash(raw)) do
      {:ok,
       %{
         source: root,
         source_raw: raw,
         lock_sha: hash(lock),
         candidate: candidate,
         binding: %{
           "source_manifest_sha256" => hash(raw),
           "candidate_manifest_sha256" => candidate_binding
         }
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_source_export_required}
    end
  end

  defp candidate(nil, _source), do: {:ok, nil}

  defp candidate(path, source_sha) do
    with {:ok, root} <- directory(path),
         {:ok, verified} <- CandidatePackage.verify(root),
         true <- verified.manifest["source_manifest_sha256"] === source_sha,
         {:ok, raw} <- read(root, "candidate-manifest.json", @json_limit) do
      {:ok, hash(raw)}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_candidate_source_mismatch}
    end
  end

  defp execution(root, value, context) do
    with true <-
           exact?(
             value,
             ~w(schema_version kind binding profile measured self_reported cache_facts inputs commands cleanup ownership)
           ),
         true <- value["schema_version"] === 1,
         true <- value["kind"] === "agent-systems-lab.environment-execution.v1",
         true <- value["binding"] === context.binding,
         profile when profile in @profiles <- value["profile"],
         true <- exact?(value["measured"], ~w(platform architecture tools)),
         true <- value["measured"]["platform"] === platform(profile),
         true <- text?(value["measured"]["architecture"], 128),
         true <- tools?(value["measured"]["tools"]),
         true <- exact?(value["self_reported"], ~w(operator_id host_id observed_at_utc new_host)),
         true <- Enum.all?(~w(operator_id host_id), &text?(value["self_reported"][&1], 128)),
         {:ok, _, _} <- DateTime.from_iso8601(value["self_reported"]["observed_at_utc"] || ""),
         true <- is_boolean(value["self_reported"]["new_host"]),
         true <-
           exact?(
             value["cache_facts"],
             ~w(runtime_cache_reused dependency_cache_reused database_reused)
           ),
         true <- Enum.all?(Map.values(value["cache_facts"]), &is_boolean/1),
         true <-
           profile != "macos-warm" or
             (value["self_reported"]["new_host"] === false and
                value["cache_facts"]["runtime_cache_reused"] === true),
         true <- inputs?(value["inputs"], context),
         true <-
           exact?(
             value["cleanup"],
             ~w(owned_postgres_stopped port_released owned_processes_exited)
           ),
         true <- Enum.all?(Map.values(value["cleanup"]), &is_boolean/1),
         true <-
           is_map(value["ownership"]) and byte_size(JSON.encode!(value["ownership"])) <= 16_384,
         true <- is_boolean(value["ownership"]["source_verified_after"]),
         true <-
           value["ownership"]["failure"] === nil or text?(value["ownership"]["failure"], 4096),
         true <- value["ownership"]["full_linux_isolation_passed"] === false,
         commands when is_list(commands) <- value["commands"],
         true <- Enum.map(commands, & &1["id"]) === command_ids(profile),
         {:ok, observed} <- map(commands, &command(root, &1)),
         :ok <- regression_pair(observed),
         paths = Enum.flat_map(commands, &references/1) |> Enum.map(& &1["path"]),
         true <- length(paths) === length(Enum.uniq(paths)),
         true <- Enum.all?(paths, &(&1 not in @reserved)) do
      {:ok, observed}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_invalid_execution}
    end
  end

  defp tools?(value),
    do:
      is_map(value) and map_size(value) in 3..20 and
        Enum.all?(~w(elixir otp postgres), &is_map_key(value, &1)) and
        Enum.all?(value, fn {k, v} -> text?(k, 128) and text?(v, 256) end)

  defp inputs?(inputs, context) do
    is_list(inputs) and length(inputs) in 2..20 and
      Enum.all?(
        inputs,
        &(exact?(&1, ~w(id origin sha256)) and text?(&1["id"], 128) and text?(&1["origin"], 1024) and
            digest?(&1["sha256"]))
      ) and
      length(inputs) === length(Enum.uniq_by(inputs, & &1["id"])) and
      Enum.any?(
        inputs,
        &(&1["id"] === "source" and &1["sha256"] === context.binding["source_manifest_sha256"])
      ) and
      Enum.any?(inputs, &(&1["id"] === "mix_lock" and &1["sha256"] === context.lock_sha))
  end

  defp command(root, value) do
    with true <- exact?(value, ~w(id argv exit_status log result)),
         true <- value["argv"] === argv(value["id"]),
         true <- is_integer(value["exit_status"]) and value["exit_status"] in 0..255,
         {:ok, raw} <- record(root, value["log"], @file_limit),
         :ok <- optional_record(root, value["result"]),
         :ok <- result_receipt(root, value),
         {:ok, regression} <- footer(value, raw) do
      {:ok, Map.put(Map.take(value, ~w(id exit_status)), "regression", regression)}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_invalid_command}
    end
  end

  # Exit status and a bounded JSON receipt are checked here. The corresponding
  # demo owns its detailed domain assertions; hashes do not prove it executed.
  defp result_receipt(root, %{"id" => id, "exit_status" => 0} = command)
       when id in ~w(p1 history recover fence upgrade) do
    with {:ok, raw} <- record(root, command["result"], @json_limit),
         {:ok, _} <- decode(raw),
         do: :ok
  end

  defp result_receipt(_, _), do: :ok

  defp footer(%{"id" => id, "exit_status" => 0}, raw) when id in ~w(full memory) do
    case Regex.scan(
           ~r/^Result: (\d+) passed \((\d+) doctests, (\d+) tests\)(?:, (\d+) excluded)?\r?$/m,
           raw
         ) do
      [[_, passed, docs, tests | rest]] ->
        excluded =
          case rest do
            [v] when v != "" -> String.to_integer(v)
            _ -> 0
          end

        result = %{
          "passed" => String.to_integer(passed),
          "doctests" => String.to_integer(docs),
          "tests" => String.to_integer(tests),
          "excluded" => excluded
        }

        if result["passed"] > 0 and result["passed"] === result["doctests"] + result["tests"] and
             not Regex.match?(~r/^\s*\d+\)\s|^Result:.*(?:failed|failure)/m, raw),
           do: {:ok, result},
           else: {:error, :environment_invalid_regression_log}

      _ ->
        {:error, :environment_invalid_regression_log}
    end
  end

  defp footer(_, _), do: {:ok, nil}

  defp regression_pair(commands) do
    by_id = Map.new(commands, &{&1["id"], &1})

    case {by_id["full"]["regression"], by_id["memory"]["regression"]} do
      {%{} = f, %{} = m} ->
        if f["passed"] + f["excluded"] === m["passed"] + m["excluded"] and
             f["doctests"] === m["doctests"],
           do: :ok,
           else: {:error, :environment_regression_counts_mismatch}

      _ ->
        :ok
    end
  end

  defp evidence_files(root, execution, raw, context) do
    refs = Enum.flat_map(execution["commands"], &references/1)

    with true <-
           Enum.sum(Enum.map(refs, & &1["bytes"])) + byte_size(raw) +
             byte_size(context.source_raw) <= @total_limit,
         {:ok, files} <-
           map(refs, fn ref ->
             with {:ok, bytes} <- record(root, ref, @file_limit), do: {:ok, {ref, bytes}}
           end),
         all = [
           {reference("execution.json", raw), raw},
           {reference("source-manifest.json", context.source_raw), context.source_raw} | files
         ],
         true <- Enum.sum(Enum.map(all, fn {r, _} -> r["bytes"] end)) <= @total_limit do
      {:ok, Enum.sort_by(all, fn {r, _} -> r["path"] end)}
    else
      {:error, _} = error -> error
      _ -> {:error, :environment_evidence_size_limit}
    end
  end

  defp references(command),
    do: [command["log"] | if(command["result"], do: [command["result"]], else: [])]

  defp manifest(execution, files),
    do: %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.environment-bundle.v1",
      "binding" => execution["binding"],
      "profile" => execution["profile"],
      "files" => Enum.map(files, &elem(&1, 0))
    }

  defp environment(value) do
    %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.release-environment.v1",
      "id" => value["profile"],
      "type" => if(value["profile"] == "linux-core", do: "linux", else: "cold_install_macos"),
      "scope" => if(value["profile"] == "linux-core", do: "core", else: "full"),
      "source_manifest_sha256" => value["binding"]["source_manifest_sha256"],
      "candidate_manifest_sha256" => value["binding"]["candidate_manifest_sha256"],
      "provenance" =>
        Map.merge(value["self_reported"], value["cache_facts"])
        |> Map.merge(%{
          "platform" => value["measured"]["platform"],
          "self_reported" => true,
          "inputs" => value["inputs"],
          "tools" => value["measured"]["tools"]
        }),
      "excluded_tags" => if(value["profile"] == "linux-core", do: ["seatbelt"], else: []),
      "commands" => value["commands"],
      "cleanup" => value["cleanup"]
    }
  end

  defp release_documents(execution) do
    env_raw = JSON.encode!(environment(execution)) <> "\n"

    index =
      Map.merge(execution["binding"], %{
        "schema_version" => 1,
        "kind" => "agent-systems-lab.release-environment-index.v1",
        "archive" => nil,
        "environments" =>
          if(source_verified?(execution) and usable_inputs?(execution),
            do: [reference("environment.json", env_raw)],
            else: []
          )
      })

    [{"environment.json", env_raw}, {"environment-evidence.json", JSON.encode!(index) <> "\n"}]
  end

  defp release_files(_root, _execution, %{candidate: nil}), do: :ok

  defp release_files(root, execution, _context),
    do: write_pairs(root, release_documents(execution))

  defp verify_release_files(_root, _execution, %{candidate: nil}), do: :ok

  defp verify_release_files(root, execution, _context) do
    with {:ok, _} <-
           map(release_documents(execution), fn {path, bytes} ->
             with {:ok, actual} <- read(root, path, @json_limit),
                  true <- actual === bytes,
                  do: {:ok, true},
                  else: (_ -> {:error, :environment_release_index_mismatch})
           end),
         do: :ok
  end

  defp report(root, execution, observed, context) do
    with {:ok, gates} <- gates(root, context) do
      failures = for c <- observed, c["exit_status"] != 0, do: "command_failed:" <> c["id"]

      cleanup =
        if Enum.all?(Map.values(execution["cleanup"]), & &1),
          do: [],
          else: ["owned_cleanup_pending"]

      pins =
        if Enum.all?(ReleaseAssessment.policy()["runtime_pins"], fn {id, v} ->
             execution["measured"]["tools"][id] === v
           end), do: [], else: ["runtime_pins_required"]

      inputs =
        if usable_inputs?(execution), do: [], else: ["installation_input_provenance_missing"]

      cold =
        if execution["self_reported"]["new_host"] and
             Enum.all?(Map.values(execution["cache_facts"]), &(&1 === false)),
           do: [],
           else: ["cold_host_and_empty_caches_required"]

      scope =
        if execution["profile"] == "linux-core",
          do: ["full_linux_backend_and_zero_exclusions_required"],
          else: cold

      source =
        if source_verified?(execution), do: [], else: ["runner_or_source_verification_failed"]

      full = Enum.find(observed, &(&1["id"] == "full"))

      excluded =
        if full["regression"] && full["regression"]["excluded"] > 0,
          do: ["full_regression_has_exclusions"],
          else: []

      reasons = Enum.uniq(failures ++ cleanup ++ pins ++ inputs ++ scope ++ source ++ excluded)

      report = %{
        "schema_version" => 1,
        "kind" => "agent-systems-lab.environment-validation-report.v1",
        "binding" => context.binding,
        "profile" => execution["profile"],
        "measured" => execution["measured"],
        "commands" => observed,
        "cleanup" => execution["cleanup"],
        "technical_execution_passed" => failures ++ cleanup ++ pins ++ source == [],
        "environment_status" => if(reasons == [], do: "recorded", else: "pending"),
        "pending_reasons" => reasons,
        "release_gates" => gates,
        "release_ready" => false,
        "approval_recorded" => false,
        "publication_status" => "not_published",
        "trust" =>
          "Host-supplied records; hashes authenticate neither hosts nor execution; Linux exclusions do not pass full isolation"
      }

      {:ok, Map.put(report, "report_hash", Report.hash(report))}
    end
  end

  defp source_verified?(execution),
    do:
      execution["ownership"]["source_verified_after"] === true and
        execution["ownership"]["failure"] === nil

  defp usable_inputs?(execution),
    do:
      Enum.all?(ReleaseAssessment.policy()["installation_inputs"], fn id ->
        Enum.any?(execution["inputs"], fn input ->
          input["id"] === id and input["sha256"] !== String.duplicate("0", 64)
        end)
      end)

  defp gates(_root, %{candidate: nil}), do: {:ok, nil}

  defp gates(root, context) do
    with {:ok, report} <- ReleaseAssessment.assess(candidate: context.candidate, evidence: root),
         do: {:ok, report["gates"]}
  end

  defp command_ids("linux-core"),
    do: ~w(dependencies full memory verify p1 history recover fence upgrade)

  defp command_ids(_), do: ReleaseAssessment.policy()["cold_commands"]
  defp argv(id), do: ReleaseAssessment.policy()["command_argv"][id]
  defp platform("linux-core"), do: "linux"
  defp platform(_), do: "macos"

  defp options(opts, allowed) do
    if is_list(opts) and Keyword.keyword?(opts) and
         length(opts) === length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
       do: :ok,
       else: {:error, :environment_invalid_options}
  end

  defp fresh(path, protected) do
    with true <- is_binary(path) and Path.type(path) === :absolute and Path.expand(path) === path,
         {:ok, _} <- directory(Path.dirname(path)),
         {:error, :enoent} <- File.lstat(path),
         true <- Enum.all?(protected, &(path != &1 and not String.starts_with?(path, &1 <> "/"))) do
      {:ok, path}
    else
      _ -> {:error, :environment_fresh_output_required}
    end
  end

  defp copy_files(root, files),
    do: write_pairs(root, Enum.map(files, fn {ref, bytes} -> {ref["path"], bytes} end))

  defp write_pairs(root, pairs) do
    with {:ok, _} <-
           map(pairs, fn {path, bytes} ->
             with :ok <- File.mkdir_p(Path.dirname(Path.join(root, path))),
                  :ok <- File.write(Path.join(root, path), bytes, [:binary, :exclusive]),
                  :ok <- File.chmod(Path.join(root, path), 0o600),
                  do: {:ok, true}
           end),
         do: :ok
  end

  defp json(root, path, value), do: write_pairs(root, [{path, JSON.encode!(value) <> "\n"}])

  defp reference(path, bytes),
    do: %{"path" => path, "sha256" => hash(bytes), "bytes" => byte_size(bytes)}

  defp optional_record(_, nil), do: :ok

  defp optional_record(root, value),
    do: with({:ok, _} <- record(root, value, @file_limit), do: :ok)

  defp record(root, ref, limit) do
    with true <- exact?(ref, ~w(path sha256 bytes)),
         true <- digest?(ref["sha256"]) and is_integer(ref["bytes"]) and ref["bytes"] in 1..limit,
         {:ok, bytes} <- read(root, ref["path"], limit),
         true <- byte_size(bytes) === ref["bytes"] and hash(bytes) === ref["sha256"],
         do: {:ok, bytes},
         else: (_ -> {:error, :environment_evidence_integrity})
  end

  defp read(root, relative, limit) do
    with true <- relative?(relative),
         path = Path.join(root, relative),
         {:ok, _} <- directory(Path.dirname(path)),
         {:ok, before} <- File.lstat(path),
         true <-
           before.type === :regular and before.links === 1 and before.size <= limit and
             band(before.mode, 0o7000) === 0,
         {:ok, bytes} <-
           File.open(path, [:read, :binary], fn io ->
             case IO.binread(io, limit + 1) do
               :eof -> ""
               value -> value
             end
           end),
         {:ok, after_read} <- File.lstat(path),
         true <-
           Map.drop(Map.from_struct(before), [:atime]) ===
             Map.drop(Map.from_struct(after_read), [:atime]) and byte_size(bytes) === before.size do
      {:ok, bytes}
    else
      _ -> {:error, :environment_unsafe_file}
    end
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
         else: (_ -> {:error, :environment_unsafe_directory})
  end

  defp directory(_), do: {:error, :environment_unsafe_directory}

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :environment_invalid_json}
    end
  end

  defp relative?(value),
    do:
      text?(value, 512) and Path.type(value) === :relative and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."])) and
        not String.contains?(value, "\\")

  defp exact?(value, keys), do: is_map(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)
  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max and safe?(value)
  defp safe?(value), do: String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp map(values, fun),
    do:
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case fun.(value) do
          {:ok, next} -> {:cont, {:ok, acc ++ [next]}}
          error -> {:halt, error}
        end
      end)
end
