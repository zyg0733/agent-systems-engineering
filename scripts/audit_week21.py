#!/usr/bin/env python3
"""Read-only Week 21 artifact crosscheck, independent of the Elixir verifier.

Usage: python3 scripts/audit_week21.py FORMAL_DIRECTORY [AUDIT_JSON_PATH]

Checks file bytes, native archive TOCs and agreement between saved evidence.
It does not connect to PostgreSQL, restore SQL, execute a task, recompute ETF
Context.hash values, authenticate a bundle or independently prove recorded
runtime assertions. Only the requested audit JSON is written.
"""

import hashlib
import json
import os
import pathlib
import re
import selectors
import stat
import subprocess
import sys
import time


HEX = re.compile(r"^[0-9a-f]{64}$")
DATABASE = re.compile(r"^lab_w21_[0-9a-f]{32}$")
LEGACY_VERSION = 20261024020000
CURRENT_VERSION = 20261025000000
TABLES = set("""lab_approval_cases lab_approval_events lab_attempts lab_checkpoints
lab_contexts lab_events lab_history_migrations lab_intents lab_mock_effects
lab_model_results lab_operations lab_queues lab_recovery lab_retries lab_runs
lab_sessions lab_task_budgets lab_workflow_control_events lab_workflow_controls
lab_workflow_events lab_workflow_nodes lab_workflows schema_migrations""".split())
FIXTURES = {
    "run.ex": (1578, "39063764f7fc4556710e697e27585931f3dad87a6bf63d361e7b3724e87d8a26"),
    "event.ex": (1083, "61d0f65f54f4ec152e557aa0c0c9cccdae93a1fbde6e608ffa25e094158b4b10"),
    "storage.ex": (24629, "5e63d27bace911612f7bb140dd12a87d330f2569f6874d4701d743cf8714ded9"),
    "model_result_store.ex": (6864, "b956cd630a67589297c2d1461d9169904a4114f7168e75dec7291410772fa918"),
}
BOUNDARIES = set("""AgentSystemsLab.Scheduler.start_link/1
AgentSystemsLab.Tools.DurableMock.execute/5
AgentSystemsLab.Approvals.Cases.decide/3
AgentSystemsLab.DurableTools.execute/3
AgentSystemsLab.Workflows.ControlStore.pause/3
AgentSystemsLab.Tools.Mock.execute/4
AgentSystemsLab.Workflows.ControlStore.create_owned_in_transaction/3
AgentSystemsLab.Workflows.ControlStore.resume/2
AgentSystemsLab.Approvals.Cases.resume/3
AgentSystemsLab.Evaluation.Scorer.score/5
AgentSystemsLab.DurableTools.confirm/5
AgentSystemsLab.Isolation.execute/4
AgentSystemsLab.Tools.Gateway.execute/4
AgentSystemsLab.Evaluation.Runner.execute/6
AgentSystemsLab.Approvals.Coordinator.start_link/1
AgentSystemsLab.Workflows.Store.create/3
AgentSystemsLab.Tools.DurableMock.execute/4
AgentSystemsLab.Observability.emit/4
AgentSystemsLab.Approvals.Cases.create/3
AgentSystemsLab.Recovery.reconcile/2
AgentSystemsLab.DurableTools.reconcile/3
AgentSystemsLab.Approvals.Artifact.check_baselines/1
AgentSystemsLab.Recovery.execute_claim/2
AgentSystemsLab.Approvals.Artifact.capture/1
AgentSystemsLab.Workflows.Store.cancel/3
AgentSystemsLab.Tools.DurableMock.lookup/3
AgentSystemsLab.RunServer.start_link/1
AgentSystemsLab.Tools.Gateway.execute/5
AgentSystemsLab.Workflows.ControlStore.set_owned_in_transaction/5
AgentSystemsLab.Isolation.execute/3
AgentSystemsLab.Workflows.Store.sync/2
AgentSystemsLab.MCP.execute/3
AgentSystemsLab.Workflows.Coordinator.start_link/1
AgentSystemsLab.Approvals.Cases.sync/2
AgentSystemsLab.Recovery.resume/2
AgentSystemsLab.Providers.Recorded.respond/2
AgentSystemsLab.Providers.Scripted.respond/2
AgentSystemsLab.Workflows.Store.create_in_transaction/4
AgentSystemsLab.Approvals.Cases.cancel/3
AgentSystemsLab.Recovery.step/2
AgentSystemsLab.Tools.Gateway.execute/7
AgentSystemsLab.Tools.Gateway.execute/6
AgentSystemsLab.Providers.Recorded.stream/3
AgentSystemsLab.Tools.Files.execute/4
AgentSystemsLab.Approvals.Cases.release/3
AgentSystemsLab.MCP.execute/4
AgentSystemsLab.Approvals.Cases.pause/3
AgentSystemsLab.DurableTools.observe_timeout/4
AgentSystemsLab.Providers.Scripted.stream/3""".split())


def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 8_388_608:
        raise ValueError("missing, linked or oversized JSON evidence")
    return json.loads(path.read_text(), object_pairs_hook=unique)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(65_536):
            digest.update(chunk)
    return digest.hexdigest()


def valid_hash(value):
    return isinstance(value, str) and HEX.fullmatch(value) is not None


def same_json(left, right):
    # Python considers True == 1; evidence schema does not.
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def archive_toc(tool, archive):
    """Parse metadata only, with bounded output/deadline and no DB credentials."""
    process = subprocess.Popen([str(tool), "--list", str(archive)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               env={"PATH": os.defpath, "LC_ALL": "C"})
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + 10
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise ValueError("archive metadata timeout")
            for key, _ in selector.select(0.05):
                chunk = os.read(key.fileobj.fileno(), 65_536)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(chunk)
                    if len(output) > 1_048_576:
                        raise ValueError("archive metadata output limit")
        if process.wait(timeout=2) != 0:
            raise ValueError("archive metadata parse failed")
        return output.decode("utf-8", errors="strict")
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        process.stdout.close()


def main(root, destination):
    project = pathlib.Path(__file__).resolve().parent.parent
    checks = []

    def check(name, result, category="recorded_artifact_agreement"):
        checks.append({"name": name, "passed": bool(result), "category": category})

    def attempt(name, function, category="recorded_artifact_agreement"):
        try:
            check(name, function(), category)
        except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.SubprocessError):
            check(name, False, category)

    required = ["report.json", "database-cleanup.json", "scope.json", "fixture-ids.json",
                "legacy-logical.json", "source-proof.json", "readonly-restore-proof.json",
                "legacy-restore-proof.json", "activated-current-proof.json", "activated-legacy-proof.json"]
    evidence = {}
    for name in required:
        try:
            evidence[name] = load(root / name)
            check(name + " present and strictly parsed", True, "file_structure")
        except (OSError, ValueError):
            check(name + " present and strictly parsed", False, "file_structure")
    if len(evidence) != len(required):
        return save(root, destination, checks, {"required_evidence_complete": False})

    report = evidence["report.json"]
    scope = evidence["scope.json"]
    source = evidence["source-proof.json"]
    copy = evidence["readonly-restore-proof.json"]
    converted = evidence["legacy-restore-proof.json"]
    activated = evidence["activated-current-proof.json"]
    activated_legacy = evidence["activated-legacy-proof.json"]
    ids = evidence["fixture-ids.json"]
    expected_runs = set(scope["runs"])
    expected_sequences = {row["sequence"] for row in source["sequences"]}

    fixture = project / "fixtures/history_v1"
    manifest = load(fixture / "manifest.json")
    check("legacy fixture version domains pinned", manifest["schema_version"] == 1 and manifest["legacy_last_migration"] == LEGACY_VERSION and manifest["business_schema_version"] == manifest["codec_version"] == manifest["history_format"] == 1)
    check("exact four pinned old storage modules", set(manifest["files"]) == set(FIXTURES))
    for name, (size, digest) in FIXTURES.items():
        attempt("old fixture " + name + " independent byte SHA-256", lambda name=name, size=size, digest=digest: (fixture / "runtime" / name).stat().st_size == size and sha256(fixture / "runtime" / name) == digest and manifest["files"][name]["sha256"] == digest and manifest["files"][name]["bytes"] == size, "independent_file_bytes")

    check("complete 7 Run / 2 Workflow / 1 Case scope", set(scope) == {"runs", "workflows", "cases"} and [len(scope[key]) for key in ["runs", "workflows", "cases"]] == [7, 2, 1] and all(len(values) == len(set(values)) for values in scope.values()))
    logical = evidence["legacy-logical.json"]
    check("legacy logical proof covers exact scope and hash-shaped values", set(logical) == set(scope) and all(set(logical[key]) == set(scope[key]) and all(valid_hash(value) for value in logical[key].values()) for key in scope))
    check("fixed fixture identities are in complete Run scope", set(ids) == {"budget", "file", "leased", "pending", "unknown"} and set(ids.values()) <= expected_runs)

    databases = [source["database_name"], copy["database_name"], converted["database_name"], activated_legacy["database_name"]]
    check("four distinct managed database identities recorded", len(set(databases)) == 4 and all(DATABASE.fullmatch(value) for value in databases) and activated["database_name"] == copy["database_name"])
    check("recorded version domains and database-only boundary", report["schema_version"] == report["business_schema_version"] == report["codec_version"] == report["source_history_format"] == 1 and report["target_history_format"] == 2 and report["database_only_backup"] is True and report["workspace_files_preserved_at_original_authorized_roots"] is True)
    check("legacy DDL and enrolled scope recorded", report["legacy"]["legacy_last_migration"] == LEGACY_VERSION and report["legacy"]["legacy_has_no_format_column"] is True and report["legacy"]["runs"] == 7 and report["legacy"]["workflow_count"] == 2 and report["legacy"]["approval_status"] == "approved" and report["legacy"]["unknown_effects"] == 1)

    archive_dirs = ["legacy-backup", "upgraded-backup", "converted-legacy-backup"]
    dump_manifests = {}
    native_metadata = {}
    for name in archive_dirs:
        directory = root / name
        archive = directory / "database.dump"
        manifest_path = directory / "manifest.json"
        try:
            dump = load(manifest_path)
            dump_manifests[name] = dump
            check(name + " private directory/archive/manifest modes", not directory.is_symlink() and not archive.is_symlink() and stat.S_IMODE(directory.stat().st_mode) == 0o700 and stat.S_IMODE(archive.stat().st_mode) == stat.S_IMODE(manifest_path.stat().st_mode) == 0o600, "file_structure")
            check(name + " independently hashed custom archive", archive.stat().st_size == dump["dump_bytes"] and 0 < dump["dump_bytes"] <= 268_435_456 and sha256(archive) == dump["dump_sha256"] and archive.open("rb").read(5) == b"PGDMP", "independent_file_bytes")
            check(name + " fixed native tool/server and bundle protocol", dump["schema_version"] == 1 and dump["format"] == "postgresql-custom-trusted-host.v1" and dump["pg_dump_version"] == "pg_dump (PostgreSQL) 18.6" and dump["pg_restore_version"] == "pg_restore (PostgreSQL) 18.6" and dump["server_version"].split()[0] == "18.6")
            migrations = dump["schema_migrations"]
            check(name + " exact ordered DDL frontier", migrations == sorted(set(migrations)) and len(migrations) == (20 if name == "legacy-backup" else 21) and migrations[-1] == (LEGACY_VERSION if name == "legacy-backup" else CURRENT_VERSION))
            toc = archive_toc(project / ".runtime/postgres/18.6/bin/pg_restore", archive)
            tables = re.findall(r"^\d+; \d+ \d+ TABLE DATA public (\S+) \S+$", toc, re.M)
            sequences = re.findall(r"^\d+; \d+ \d+ SEQUENCE SET public (\S+) \S+$", toc, re.M)
            expected_tables = TABLES - ({"lab_history_migrations"} if name == "legacy-backup" else set())
            check(name + " native TOC has every expected TABLE DATA", set(tables) == expected_tables and len(tables) == len(expected_tables), "independent_archive_metadata")
            check(name + " native TOC has all six SEQUENCE SET entries", set(sequences) == expected_sequences and len(sequences) == 6, "independent_archive_metadata")
            native_metadata[name] = {"table_data_entries": len(tables), "sequence_set_entries": len(sequences), "sha256": dump["dump_sha256"]}
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            check(name + " complete native archive evidence", False)
    if len(dump_manifests) == 3:
        check("three archive source identities bound to recorded databases", dump_manifests["legacy-backup"]["source_database"] == dump_manifests["upgraded-backup"]["source_database"] == source["database_name"] and dump_manifests["converted-legacy-backup"]["source_database"] == converted["database_name"])

    for name, proof in [("source", source), ("readonly copy", copy), ("converted old source", converted), ("activated current", activated), ("activated old", activated_legacy)]:
        check(name + " complete proof shape and supported matrix", proof["schema_version"] == 1 and proof["scope_complete"] is True and proof["scope"] == scope and proof["compatibility"]["matrix"] == {"kernel_schema": [1], "event_schema": [1], "codec": [1], "history_format": [1, 2], "sidecar_schema": [1], "unknown_version_policy": "reject"})
        check(name + " exact 23 table fingerprints", {row["table"] for row in proof["tables"]} == TABLES and len(proof["tables"]) == 23 and all(type(row["row_count"]) is int and row["row_count"] >= 0 and valid_hash(row["sha256"]) for row in proof["tables"]))
        check(name + " expected Run projection records", {row["run_id"] for row in proof["runs"]} == expected_runs and len(proof["runs"]) == 7 and all(valid_hash(row["state_hash"]) and valid_hash(row["events_hash"]) and type(row["seq"]) is int and row["seq"] > 0 for row in proof["runs"]))
        check(name + " six sequence states", {row["sequence"] for row in proof["sequences"]} == expected_sequences and len(proof["sequences"]) == 6 and all(type(row["last_value"]) is int and type(row["is_called"]) is bool for row in proof["sequences"]))
    check("source/copy recorded complete raw fingerprints and rebuilt projections agree", all(source[key] == copy[key] for key in ["tables", "sequences", "schema_hash", "database_hash", "protected_hash", "raw_semantic_hash", "runs", "compatibility", "scope"]))
    for label, before, after, activation in [("current target", source, activated, report["restore_activation"]), ("converted legacy target", converted, activated_legacy, report["old_schema_restore_fencing"])]:
        check(label + " recorded post-fence protected and semantic evidence stable", all(before[key] == after[key] for key in ["semantic_hash", "raw_semantic_hash", "protected_hash", "runs", "scope", "sequences", "schema_hash", "compatibility"]) and before["database_hash"] != after["database_hash"])
        check(label + " activation evidence bound to pre/post proofs", activation["activated"] is True and activation["lease_policy"] == "revoke_then_explicit_resume" and activation["source_database_hash"] == before["database_hash"] and activation["restored_database_hash"] == after["database_hash"] and activation["protected_hash"] == before["protected_hash"] and activation["raw_semantic_hash"] == before["raw_semantic_hash"])
        rows = activation["generations"]
        check(label + " exactly three pending generations advance once", activation["revoked_pending_intents"] == len(rows) == 3 and {row["run_id"] for row in rows} == {ids[key] for key in ["leased", "pending", "unknown"]} and all(type(row["before"]) is int and row["after"] == row["before"] + 1 and type(row["seq"]) is int and row["seq"] > 0 for row in rows))
        changed = [before_row["table"] for before_row, after_row in zip(before["tables"], after["tables"]) if before_row != after_row]
        check(label + " only recorded intent raw table fingerprint changes", changed == ["lab_intents"])

    for label in ["migration", "old_schema_restore_migration"]:
        migration = report[label]
        check(label + " logical digest crosschecks; ETF hash not independently recomputed", migration["logical_state_identical"] is True and valid_hash(migration["legacy_logical_sha256"]) and migration["legacy_logical_sha256"] == report["legacy"]["logical_sha256"])
        rows = migration["migrations"]
        check(label + " six migrations and one live claim refusal cover exact scope", len(rows) == 7 and {row["run_id"] for row in rows} == expected_runs and sum(row["status"] == "migrated" for row in rows) == 6 and [row["run_id"] for row in rows if row["status"] == "live_claim_refused"] == [ids["leased"]])
        check(label + " every committed migration explicitly repeated as already_current", all(row.get("repeat") == "already_current" for row in rows if row["status"] == "migrated"))
        calls = migration["effect_boundary_calls"]
        check(label + " exact recorded 49 effect boundary coverage", set(calls) == BOUNDARIES and len(calls) == 49)
        check(label + " recorded boundary counters all zero", all(type(value) is int and value == 0 for value in calls.values()))
    expected_continuation = {"approval_revalidated": True, "completed_file_unchanged": True, "leased_run_resumed_with_new_claim": True, "old_claim_rejected": True, "pending_tool_effects": 1, "spent_budget_failure_preserved": True, "unknown_effects": 1, "unknown_stays_manual": True, "post_fence_semantics_and_protected_facts_identical": True, "previously_leased_history_migrated_after_fence": True}
    check("recorded explicit continuation outcomes", same_json(report["safe_continuation"], expected_continuation))
    check("recorded old-schema target verifies old token rejection and protected facts", same_json(report["old_schema_restore_verified"], {"old_claim_rejected": True, "semantic_protected_hashes_preserved": True, "previously_leased_history_migrated_after_fence": True}))
    expected_artifacts = {"workspace/result.txt": b"preserved Week 20 receipt\n", "approval-round-1/base.txt": b"BASE", "approval-round-1/patch.txt": b"PATCH1", "approval-round-2/base.txt": b"BASE", "approval-round-2/patch.txt": b"PATCH2"}
    attempt("actual preserved workspace bytes match fixed fixture", lambda: all(not (root / name).is_symlink() and (root / name).read_bytes() == value for name, value in expected_artifacts.items()), "independent_file_bytes")
    check("recorded owned database cleanup complete", same_json(evidence["database-cleanup.json"], {"all_owned_databases_dropped": True}))
    check("recorded final exercise status passed", report["all_passed"] is True and report["readonly_restore_exact"] is True)
    return save(root, destination, checks, {"required_evidence_complete": True, "native_archive_metadata": native_metadata, "fixture_count": 4, "run_count": 7, "workflow_count": 2, "case_count": 1, "proof_table_count": 23, "recorded_mfa_sets": 2, "mfas_per_set": 49})


def save(root, destination, checks, details):
    result = {"schema_version": 1, "audit_kind": "offline_artifact_crosscheck", "evidence_directory": str(root),
              "scope": "independent file hashes/archive metadata; saved runtime assertions and ETF hashes crosschecked only",
              "limitations": ["No database connection or SQL execution", "No independent reconstruction of ETF Context.hash", "Runtime counters and behavioral booleans are recorded evidence, not independently re-executed causal checks", "Hashes do not authenticate archive provenance"],
              "checks": checks, "passed": sum(check["passed"] for check in checks), "total": len(checks),
              "complete": all(check["passed"] for check in checks), **details}
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in ["checks", "limitations", "native_archive_metadata"]}, ensure_ascii=False))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    if len(sys.argv) not in [2, 3]:
        raise SystemExit("Usage: python3 scripts/audit_week21.py FORMAL_DIRECTORY [AUDIT_JSON_PATH]")
    root_path = pathlib.Path(sys.argv[1]).resolve(strict=True)
    audit_path = pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else root_path / "audit-python.json"
    try:
        if audit_path.is_symlink():
            raise ValueError("linked audit output")
        audit_path = audit_path.resolve()
        if audit_path.exists() and load(audit_path).get("audit_kind") != "offline_artifact_crosscheck":
            raise ValueError("refuse overwrite of source evidence")
        raise SystemExit(main(root_path, audit_path))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Artifact crosscheck rejected malformed evidence: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(2)
