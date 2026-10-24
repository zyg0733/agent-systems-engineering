defmodule AgentSystemsLab.HistoryUpgradeDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Context, HistoryUpgradeDemo, Repo}

  test "invalid options cannot start children, rewrite evidence or select arbitrary upgrade actions" do
    for opts <- [
          nil,
          :bad,
          [1],
          [output: 1],
          [output: ""],
          [output: <<0>>],
          [output: <<255>>],
          [extra: true],
          [output: "a", output: "b"],
          [action: "arbitrary-command"],
          [force: true]
        ] do
      assert {:error, :invalid_upgrade_options} = HistoryUpgradeDemo.run(opts)
    end
  end

  test "existing evidence is preserved without opening a fresh database" do
    output = directory("protected")
    File.mkdir!(output)
    File.write!(Path.join(output, "prior-proof"), "keep the prior proof")
    on_exit(fn -> File.rm_rf!(output) end)
    assert {:error, {:output_exists, ^output}} = HistoryUpgradeDemo.run(output: output)
    assert File.read!(Path.join(output, "prior-proof")) == "keep the prior proof"
    assert File.ls!(output) == ["prior-proof"]
  end

  @tag :database
  @tag timeout: 180_000
  test "real legacy databases migrate, restore under the gate, fence copied leases and continue safely" do
    output = directory("real")
    # Failed fixture evidence remains available for diagnosing a failing test;
    # the demo always attempts to drop only its capability-owned databases.
    on_exit(fn -> if File.exists?(Path.join(output, "report.json")), do: File.rm_rf!(output) end)
    assert {:ok, result} = HistoryUpgradeDemo.run(output: output)
    report = result.report
    assert report["all_passed"]
    assert result.output_dir == output
    assert report["business_schema_version"] == 1
    assert report["codec_version"] == 1
    assert report["source_history_format"] == 1
    assert report["target_history_format"] == 2
    assert report["database_only_backup"]
    assert report["workspace_files_preserved_at_original_authorized_roots"]
    assert report["legacy"]["legacy_last_migration"] == 20_261_024_020_000
    assert report["legacy"]["legacy_has_no_format_column"]
    assert report["legacy"]["runs"] == 7
    assert report["legacy"]["workflow_count"] == 2
    assert report["legacy"]["approval_status"] == "approved"
    assert report["legacy"]["unknown_effects"] == 1
    assert report["migration"]["logical_state_identical"]
    statuses = Enum.frequencies_by(report["migration"]["migrations"], & &1["status"])
    assert statuses == %{"migrated" => 6, "live_claim_refused" => 1}

    for row <- report["migration"]["migrations"],
        row["status"] == "migrated",
        do: assert(row["repeat"] == "already_current")

    for key <- ~w(migration old_schema_restore_migration) do
      counts = report[key]["effect_boundary_calls"]
      assert map_size(counts) == 49
      assert Enum.all?(counts, fn {_, count} -> count == 0 end)
    end

    assert report["readonly_restore_exact"]
    assert report["restore_activation"]["activated"]
    assert report["restore_activation"]["lease_policy"] == "revoke_then_explicit_resume"

    assert Enum.all?(report["restore_activation"]["generations"], fn row ->
             row["after"] == row["before"] + 1
           end)

    continuation = report["safe_continuation"]

    for key <-
          ~w(old_claim_rejected completed_file_unchanged unknown_stays_manual spent_budget_failure_preserved leased_run_resumed_with_new_claim approval_revalidated post_fence_semantics_and_protected_facts_identical previously_leased_history_migrated_after_fence),
        do: assert(continuation[key], key)

    assert continuation["pending_tool_effects"] == 1
    assert continuation["unknown_effects"] == 1
    assert report["old_schema_restore_migration"]["logical_state_identical"]
    assert report["old_schema_restore_fencing"]["activated"]

    for key <-
          ~w(old_claim_rejected semantic_protected_hashes_preserved previously_leased_history_migrated_after_fence),
        do: assert(report["old_schema_restore_verified"][key])

    source = read(output, "source-proof.json")
    copy = read(output, "readonly-restore-proof.json")
    assert source["proof_kind"] == "verified_source"
    assert copy["proof_kind"] == "readonly_copy"
    assert source["database_hash"] == copy["database_hash"]
    assert source["protected_hash"] == copy["protected_hash"]
    assert source["raw_semantic_hash"] == copy["raw_semantic_hash"]
    assert length(source["runs"]) == 7
    assert length(source["compatibility"]["tables"]) == 22
    assert source["database_name"] != copy["database_name"]
    activated = read(output, "activated-current-proof.json")
    assert source["semantic_hash"] == activated["semantic_hash"]
    assert source["protected_hash"] == activated["protected_hash"]
    assert source["database_hash"] != activated["database_hash"]
    legacy_proof = read(output, "legacy-restore-proof.json")
    legacy_activated = read(output, "activated-legacy-proof.json")
    assert legacy_proof["semantic_hash"] == legacy_activated["semantic_hash"]
    assert legacy_proof["protected_hash"] == legacy_activated["protected_hash"]

    assert report["migration"]["legacy_logical_sha256"] ==
             Context.hash(read(output, "legacy-logical.json"))

    old_bundle = read(output, "legacy-backup/manifest.json")
    upgraded_bundle = read(output, "upgraded-backup/manifest.json")
    converted_bundle = read(output, "converted-legacy-backup/manifest.json")
    assert length(old_bundle["schema_migrations"]) == 20
    assert length(upgraded_bundle["schema_migrations"]) == 21
    assert length(converted_bundle["schema_migrations"]) == 21
    assert old_bundle["dump_sha256"] != upgraded_bundle["dump_sha256"]
    assert converted_bundle["source_database"] != upgraded_bundle["source_database"]

    for name <- ~w(legacy-backup upgraded-backup converted-legacy-backup) do
      manifest = read(output, name <> "/manifest.json")
      archive = File.read!(Path.join([output, name, "database.dump"]))
      assert byte_size(archive) == manifest["dump_bytes"]

      assert Base.encode16(:crypto.hash(:sha256, archive), case: :lower) ==
               manifest["dump_sha256"]

      assert Bitwise.band(File.stat!(Path.join([output, name, "database.dump"])).mode, 0o777) ==
               0o600
    end

    scope = read(output, "scope.json")
    assert length(scope["runs"]) == 7
    assert length(scope["workflows"]) == 2
    assert length(scope["cases"]) == 1

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM lab_runs WHERE id=ANY($1::text[])", [scope["runs"]])

    assert read(output, "database-cleanup.json")["all_owned_databases_dropped"]
    assert read(output, "report.json") == report
  end

  defp directory(label),
    do:
      Path.join(
        if(:os.type() == {:unix, :darwin}, do: "/private/tmp", else: System.tmp_dir!()),
        "lab-history-upgrade-#{label}-#{Ecto.UUID.generate()}"
      )

  defp read(output, name), do: Path.join(output, name) |> File.read!() |> JSON.decode!()
end
