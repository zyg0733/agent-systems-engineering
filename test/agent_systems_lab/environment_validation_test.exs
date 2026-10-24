defmodule AgentSystemsLab.EnvironmentValidationTest do
  # Candidate verification inventories thousands of inert files. Run this module
  # after async cases so the harness does not compete for filesystem throughput.
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{EnvironmentValidation, ReleaseAssessment, Reproduction}
  alias AgentSystemsLab.Evaluation.Report

  Code.require_file("../support/frozen_matrix_fixture.exs", __DIR__)
  Code.require_file("../support/release_candidate_fixture.ex", __DIR__)

  @project Path.expand("../..", __DIR__)

  # These inert synthetic host observations test validation only. They are not
  # acceptance evidence for a new machine, Linux, command execution or a person.
  setup_all do
    parent = if :os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(parent, "environment-unit-" <> Ecto.UUID.generate())
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    input = Path.join(root, "input")
    File.mkdir!(input)
    File.mkdir!(Path.join(input, "docs"))

    for path <- ~w(mix.exs mix.lock .tool-versions LICENSE LICENSE-DOCS NOTICE docs/licensing.md),
        do: File.write!(Path.join(input, path), "raise \"source must never execute\"\n")

    source = Path.join(root, "source")
    assert {:ok, _} = Reproduction.export(source, source: input)
    %{root: root, source: source}
  end

  setup context do
    root = Path.join(context.root, Ecto.UUID.generate())
    File.mkdir!(root)
    execution = Path.join(root, "execution")
    File.mkdir!(execution)
    record = execution(context.source, execution, "macos-warm")
    write_execution(execution, record)
    %{case_root: root, execution: execution, record: record, output: Path.join(root, "bundle")}
  end

  test "plans bind explicit source and return only fixed argv without running source", c do
    assert {:ok, plan} = EnvironmentValidation.plan(c.source, profile: "macos-warm")

    assert plan["binding"]["source_manifest_sha256"] ==
             hash(File.read!(Path.join(c.source, "reproduction-source-manifest.json")))

    assert plan["binding"]["candidate_manifest_sha256"] == nil

    assert Enum.map(plan["commands"], & &1["argv"]) ==
             Enum.map(
               ReleaseAssessment.policy()["cold_commands"],
               &ReleaseAssessment.policy()["command_argv"][&1]
             )

    refute plan["release_ready"]
    assert plan["trust"] =~ "no commands executed"
  end

  test "Linux core plans disclose unsupported Seatbelt and never offer Linux full", c do
    assert {:ok, plan} = EnvironmentValidation.plan(c.source, profile: "linux-core")
    assert plan["scope"] == "core"
    assert plan["excluded_tags"] == ["seatbelt"]
    refute Enum.any?(plan["commands"], &(&1["id"] in ~w(runtime postgres matrix isolation)))

    assert {:error, :environment_invalid_profile} =
             EnvironmentValidation.plan(c.source, profile: "linux-full")
  end

  test "warm observations form a read-only verifiable immutable bundle and stay pending", c do
    assert {:ok, report} = collect(c)
    assert report["technical_execution_passed"]
    assert report["environment_status"] == "pending"
    assert "cold_host_and_empty_caches_required" in report["pending_reasons"]
    refute report["release_ready"]
    assert report["release_gates"] == nil
    assert report["report_hash"] == Report.hash(Map.delete(report, "report_hash"))
    assert {:ok, ^report} = EnvironmentValidation.verify(c.output, source: c.source)
    File.write!(Path.join(c.output, "report.json"), "{\"release_ready\":true}\n")
    assert {:ok, ^report} = EnvironmentValidation.verify(c.output, source: c.source)
    assert {:error, :environment_fresh_output_required} = collect(c)
    assert File.read!(Path.join(c.output, "report.json")) =~ "true"
  end

  test "original execution and source manifest bytes survive collection", c do
    path = Path.join(c.execution, "execution.json")
    File.write!(path, " \n" <> File.read!(path) <> " \n")
    assert {:ok, _} = collect(c)
    assert File.read!(Path.join(c.output, "execution.json")) == File.read!(path)

    assert File.read!(Path.join(c.output, "source-manifest.json")) ==
             File.read!(Path.join(c.source, "reproduction-source-manifest.json"))

    assert Bitwise.band(File.stat!(Path.join(c.output, "execution.json")).mode, 0o777) == 0o600
  end

  test "Linux appropriate success still leaves full Linux and exclusions pending", c do
    record = execution(c.source, c.execution, "linux-core")
    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    assert report["technical_execution_passed"]
    assert "full_linux_backend_and_zero_exclusions_required" in report["pending_reasons"]
    assert report["environment_status"] == "pending"
    refute report["release_ready"]
  end

  test "a cold label with reused cache remains pending", c do
    record = put_in(c.record, ["profile"], "macos-cold")
    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    assert "cold_host_and_empty_caches_required" in report["pending_reasons"]
    assert report["environment_status"] == "pending"
  end

  test "cold full regression exclusions are pending even without candidate", c do
    record =
      c.record
      |> Map.put("profile", "macos-cold")
      |> put_in(["self_reported", "new_host"], true)
      |> Map.put("cache_facts", Map.new(c.record["cache_facts"], fn {k, _} -> {k, false} end))

    record =
      log(c.execution, record, "full", "Result: 9 passed (2 doctests, 7 tests), 1 excluded\n")

    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    assert "full_regression_has_exclusions" in report["pending_reasons"]
    assert report["environment_status"] == "pending"
  end

  test "post-command source verification failure cannot be successful execution", c do
    record =
      c.record
      |> put_in(["ownership", "source_verified_after"], false)
      |> put_in(["ownership", "failure"], "source changed after last successful command")

    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    refute report["technical_execution_passed"]
    assert "runner_or_source_verification_failed" in report["pending_reasons"]
    assert report["environment_status"] == "pending"
  end

  test "failure and unrun command records preserve evidence and remain pending", c do
    record =
      update_in(c.record, ["commands"], fn commands ->
        Enum.map(commands, &if(&1["id"] == "full", do: Map.put(&1, "exit_status", 125), else: &1))
      end)

    record = log(c.execution, record, "full", "not run: previous step failed\n")
    record = put_in(record, ["cleanup", "port_released"], false)
    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    refute report["technical_execution_passed"]
    assert "command_failed:full" in report["pending_reasons"]
    assert "owned_cleanup_pending" in report["pending_reasons"]
  end

  test "unknown versions, keys, source binding, platform and spoofed full Linux are rejected",
       c do
    variants = [
      Map.put(c.record, "schema_version", 2),
      Map.put(c.record, "shell", "touch /tmp/never"),
      put_in(c.record, ["binding", "source_manifest_sha256"], String.duplicate("0", 64)),
      put_in(c.record, ["measured", "platform"], "linux"),
      put_in(c.record, ["ownership", "full_linux_isolation_passed"], true)
    ]

    for variant <- variants do
      write_execution(c.execution, variant)
      assert {:error, _} = collect(c)
      refute File.exists?(c.output)
    end
  end

  test "missing, duplicate, reordered and arbitrary commands are rejected", c do
    commands = c.record["commands"]

    for changed <- [
          tl(commands),
          commands ++ [hd(commands)],
          Enum.reverse(commands),
          [Map.put(hd(commands), "argv", ["sh", "-c", "touch /tmp/never"]) | tl(commands)]
        ] do
      write_execution(c.execution, Map.put(c.record, "commands", changed))
      assert {:error, _} = collect(c)
      refute File.exists?(c.output)
    end
  end

  test "regression logs require one consistent success footer", c do
    for raw <- [
          "Result: 9 passed (2 doctests, 8 tests)\n",
          "Result: 10 passed (2 doctests, 8 tests)\nResult: 10 passed (2 doctests, 8 tests)\n",
          "Result: 10 passed (2 doctests, 8 tests)\n  1) failed test\n"
        ] do
      record = log(c.execution, c.record, "full", raw)
      write_execution(c.execution, record)
      assert {:error, :environment_invalid_regression_log} = collect(c)
    end
  end

  test "mismatched full and memory source test counts cannot be collected", c do
    record =
      log(c.execution, c.record, "memory", "Result: 8 passed (2 doctests, 6 tests), 3 excluded\n")

    write_execution(c.execution, record)
    assert {:error, :environment_regression_counts_mismatch} = collect(c)
  end

  test "tampered log, execution, copied source and bundle manifest fail verification", c do
    assert {:ok, _} = collect(c)

    for relative <- [
          "logs/verify.log",
          "execution.json",
          "source-manifest.json",
          "environment-validation.json"
        ] do
      path = Path.join(c.output, relative)
      old = File.read!(path)
      File.write!(path, old <> "tampered")
      assert {:error, _} = EnvironmentValidation.verify(c.output, source: c.source)
      File.write!(path, old)
    end

    assert {:ok, _} = EnvironmentValidation.verify(c.output, source: c.source)
  end

  test "symlinks, hardlinks, traversal and reserved evidence filenames are rejected", c do
    target = Path.join(c.execution, "logs/verify.log")
    bytes = File.read!(target)
    File.rm!(target)
    original = Path.join(c.case_root, "original.log")
    File.write!(original, bytes)
    File.ln_s!(original, target)
    assert {:error, _} = collect(c)
    File.rm!(target)
    File.ln!(original, target)
    assert {:error, _} = collect(c)
    File.rm!(target)
    File.write!(target, bytes)

    for path <- ["../original.log", "execution.json"] do
      changed =
        update_in(c.record, ["commands"], fn list ->
          Enum.map(
            list,
            &if(&1["id"] == "verify", do: put_in(&1, ["log", "path"], path), else: &1)
          )
        end)

      write_execution(c.execution, changed)
      assert {:error, _} = collect(c)
    end
  end

  test "source-only binding and destination guard preserve source and old evidence", c do
    assert {:error, _} = EnvironmentValidation.plan("relative", profile: "macos-warm")

    assert {:error, :environment_invalid_options} =
             EnvironmentValidation.plan(c.source, profile: "macos-warm", approval_recorded: true)

    assert {:error, :environment_invalid_options} =
             EnvironmentValidation.collect(source: c.source, source: c.source)

    assert {:error, :environment_fresh_output_required} =
             EnvironmentValidation.collect(
               source: c.source,
               execution: c.execution,
               output: Path.join(c.source, "bundle")
             )

    assert {:error, :environment_fresh_output_required} =
             EnvironmentValidation.collect(
               source: c.source,
               execution: c.execution,
               output: Path.join(c.execution, "bundle")
             )

    refute File.exists?(Path.join(c.source, "bundle"))
  end

  test "incomplete input provenance and runtime drift remain visible pending", c do
    record =
      c.record
      |> Map.put("inputs", Enum.filter(c.record["inputs"], &(&1["id"] in ~w(source mix_lock))))
      |> put_in(["measured", "tools", "otp"], "unavailable")

    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    assert "installation_input_provenance_missing" in report["pending_reasons"]
    assert "runtime_pins_required" in report["pending_reasons"]
    refute report["technical_execution_passed"]
  end

  test "successful demos require a bounded JSON result receipt", c do
    record =
      update_in(c.record, ["commands"], fn commands ->
        Enum.map(commands, &if(&1["id"] == "p1", do: Map.put(&1, "result", nil), else: &1))
      end)

    write_execution(c.execution, record)
    assert {:error, _} = collect(c)
    refute File.exists?(c.output)
  end

  test "zero checksum placeholders cannot satisfy installation provenance", c do
    record =
      update_in(c.record, ["inputs"], fn inputs ->
        Enum.map(
          inputs,
          &if(&1["id"] == "otp", do: Map.put(&1, "sha256", String.duplicate("0", 64)), else: &1)
        )
      end)

    write_execution(c.execution, record)
    assert {:ok, report} = collect(c)
    assert "installation_input_provenance_missing" in report["pending_reasons"]
    assert report["environment_status"] == "pending"
  end

  test "candidate-bound output is v1 compatible and runner failure cannot fill release gates",
       c do
    source = Path.join(c.case_root, "candidate-source")
    assert {:ok, exported} = Reproduction.export(source, source: @project)
    technical = Path.join(c.case_root, "technical-fixture")
    File.mkdir!(technical)

    AgentSystemsLab.Test.ReleaseCandidateFixture.evidence_fixture(
      technical,
      hash(File.read!(exported.manifest_path))
    )

    candidate = Path.join(c.case_root, "candidate")

    assert {:ok, _} =
             AgentSystemsLab.CandidatePackage.build(candidate,
               source: source,
               evidence: technical
             )

    assert {:error, :environment_candidate_source_mismatch} =
             EnvironmentValidation.plan(c.source, profile: "macos-warm", candidate: candidate)

    record = execution(source, c.execution, "macos-warm")

    assert {:ok, plan} =
             EnvironmentValidation.plan(source, profile: "macos-warm", candidate: candidate)

    record = Map.put(record, "binding", plan["binding"])
    write_execution(c.execution, record)
    opts = [source: source, candidate: candidate, execution: c.execution, output: c.output]

    # Rejection must not leave a partial evidence bundle in a preserved package.
    candidate_before = tree(candidate)
    inside_candidate = Path.join(candidate, "newchild")

    assert {:error, :environment_fresh_output_required} =
             EnvironmentValidation.collect(Keyword.put(opts, :output, inside_candidate))

    refute File.exists?(inside_candidate)
    assert tree(candidate) === candidate_before
    assert {:ok, _} = AgentSystemsLab.CandidatePackage.verify(candidate)

    assert {:ok, report} = EnvironmentValidation.collect(opts)
    assert report["release_gates"]["cold_install_macos"]["status"] == "pending"

    assert {:ok, ^report} =
             EnvironmentValidation.verify(c.output, source: source, candidate: candidate)

    assert {:ok, assessment} = ReleaseAssessment.assess(candidate: candidate, evidence: c.output)
    refute assessment["release_ready"]
    assert assessment["external_evidence"]["environments"] |> length() == 1

    failed =
      record
      |> put_in(["ownership", "source_verified_after"], false)
      |> put_in(["ownership", "failure"], "source verification failed")

    write_execution(c.execution, failed)
    failed_output = c.output <> "-failed"

    assert {:ok, failed_report} =
             EnvironmentValidation.collect(Keyword.put(opts, :output, failed_output))

    refute failed_report["technical_execution_passed"]

    assert {:ok, failed_assessment} =
             ReleaseAssessment.assess(candidate: candidate, evidence: failed_output)

    assert failed_assessment["external_evidence"]["environments"] == []
    assert failed_assessment["gates"]["cold_install_macos"]["status"] == "pending"
  end

  defp collect(c),
    do: EnvironmentValidation.collect(source: c.source, execution: c.execution, output: c.output)

  defp execution(source, root, profile) do
    assert {:ok, plan} = EnvironmentValidation.plan(source, profile: profile)
    File.mkdir_p!(Path.join(root, "logs"))

    commands =
      Enum.map(plan["commands"], fn command ->
        bytes =
          case command["id"] do
            "full" -> "Result: 10 passed (2 doctests, 8 tests)\n"
            "memory" -> "Result: 7 passed (2 doctests, 5 tests), 3 excluded\n"
            _ -> "synthetic unit fixture; not actual command execution\n"
          end

        path = "logs/" <> command["id"] <> ".log"
        File.write!(Path.join(root, path), bytes)

        result =
          if command["id"] in ~w(p1 history recover fence upgrade) do
            result_path = "results/" <> command["id"] <> ".json"
            File.mkdir_p!(Path.join(root, "results"))
            result_bytes = JSON.encode!(%{"synthetic_unit_fixture" => true}) <> "\n"
            File.write!(Path.join(root, result_path), result_bytes)
            reference(result_path, result_bytes)
          end

        Map.merge(command, %{
          "exit_status" => 0,
          "log" => reference(path, bytes),
          "result" => result
        })
      end)

    %{
      "schema_version" => 1,
      "kind" => "agent-systems-lab.environment-execution.v1",
      "binding" => plan["binding"],
      "profile" => profile,
      "measured" => %{
        "platform" => plan["platform"],
        "architecture" => "synthetic-unit",
        "tools" => ReleaseAssessment.policy()["runtime_pins"]
      },
      "self_reported" => %{
        "operator_id" => "synthetic-unit",
        "host_id" => "synthetic-unit",
        "observed_at_utc" => "2026-10-24T00:00:00Z",
        "new_host" => false
      },
      "cache_facts" => %{
        "runtime_cache_reused" => true,
        "dependency_cache_reused" => true,
        "database_reused" => false
      },
      "inputs" =>
        Enum.map(~w(source mix_lock otp elixir postgres), fn id ->
          %{
            "id" => id,
            "origin" => "synthetic unit fixture",
            "sha256" =>
              case id do
                "source" -> plan["binding"]["source_manifest_sha256"]
                "mix_lock" -> hash(File.read!(Path.join(source, "mix.lock")))
                _ -> hash(id)
              end
          }
        end),
      "commands" => commands,
      "cleanup" => %{
        "owned_postgres_stopped" => true,
        "port_released" => true,
        "owned_processes_exited" => true
      },
      "ownership" => %{
        "source_verified_after" => true,
        "failure" => nil,
        "full_linux_isolation_passed" => false,
        "synthetic_unit_fixture" => true
      }
    }
  end

  defp log(root, record, id, bytes) do
    path = "logs/" <> id <> ".log"
    File.write!(Path.join(root, path), bytes)

    update_in(record, ["commands"], fn list ->
      Enum.map(
        list,
        &if(&1["id"] == id, do: Map.put(&1, "log", reference(path, bytes)), else: &1)
      )
    end)
  end

  defp write_execution(root, record),
    do: File.write!(Path.join(root, "execution.json"), JSON.encode!(record) <> "\n")

  defp reference(path, bytes),
    do: %{"path" => path, "sha256" => hash(bytes), "bytes" => byte_size(bytes)}

  defp tree(root, relative \\ "") do
    path = Path.join(root, relative)
    stat = File.lstat!(path)
    entry = {relative, stat.type, Bitwise.band(stat.mode, 0o7777)}

    case stat.type do
      :directory ->
        [entry | Enum.flat_map(Enum.sort(File.ls!(path)), &tree(root, Path.join(relative, &1)))]

      :regular ->
        [{entry, stat.size, hash(File.read!(path))}]
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
