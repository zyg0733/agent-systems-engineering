#!/usr/bin/env python3
"""Independent, read-only arithmetic and fixed-fixture audit for week 20.

Usage: python3 scripts/audit_week20.py FORMAL_DIRECTORY
Writes only audit-python.json under that directory. It never executes a task,
imports the evaluator, or edits an existing report/baseline.
"""

import hashlib
import json
import math
import pathlib
import sys


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def bytes_digest(value):
    return hashlib.sha256(value).hexdigest()


def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def main(root):
    project = pathlib.Path(__file__).resolve().parent.parent
    fixture = project / "fixtures/evaluation"
    source_manifest = load(fixture / "manifest.json")
    definitions = {task["id"]: task for task in source_manifest["tasks"]}
    scorer_hash = bytes_digest((project / "lib/agent_systems_lab/evaluation/scorer.ex").read_bytes())
    suite_source_hash = bytes_digest((project / "lib/agent_systems_lab/evaluation/suite.ex").read_bytes())
    files = {}
    task_hashes = {}
    for task in definitions.values():
        hashes = {}
        for key in ["instruction_file", "input_file", "expected_file", "reference_file", "regressed_file"]:
            hashes[task[key]] = bytes_digest((fixture / task[key]).read_bytes())
        files.update(hashes)
        task_hashes[task["id"]] = digest({"definition": task, "files": hashes, "scorer_hash": scorer_hash})
    suite_hash = digest({
        "manifest_hash": bytes_digest((fixture / "manifest.json").read_bytes()),
        "files": files, "suite_source_hash": suite_source_hash, "scorer_hash": scorer_hash,
    })
    checks = []

    def check(name, result):
        checks.append({"name": name, "passed": bool(result)})

    paths = sorted(root.glob("*/report.json"))
    expected_cohorts = {split + "-" + cohort for split in ["dev", "holdout"] for cohort in ["baseline", "repeat", "regressed"]}
    check("all six completed cohorts present", {path.parent.name for path in paths} == expected_cohorts)
    reports = []
    for path in paths:
        report = load(path)
        reports.append((path.parent.relative_to(root).as_posix(), report))
        label = path.parent.relative_to(root).as_posix()
        protocol = report["manifest"]["protocol"]
        selected = sorted(task_id for task_id, task in definitions.items() if task["split"] == protocol["split"])
        samples = report["samples"]
        expected_pairs = {(task, trial) for task in selected for trial in range(1, protocol["repetitions"] + 1)}
        check(label + ": task/trial coverage", {(s["task_id"], s["trial"]) for s in samples} == expected_pairs and len(samples) == len(expected_pairs))
        check(label + ": distinct durable Runs", len({s["run_id"] for s in samples}) == len(samples))
        check(label + ": source suite identity", protocol["suite_hash"] == suite_hash and protocol["scorer_hash"] == scorer_hash)
        check(label + ": actual task bytes", protocol["task_ids"] == selected and protocol["task_hashes"] == {task: task_hashes[task] for task in selected})
        check(label + ": pricing identity", protocol["pricing_hash"] == digest(source_manifest["pricing"]))
        check(label + ": samples hash", report["samples_hash"] == digest(samples))
        semantic = [{k: v for k, v in sample.items() if k not in ["run_id", "latency_us"]} for sample in samples]
        check(label + ": semantic signature", report["semantic_signature"] == digest({"protocol": protocol, "samples": semantic}))
        without_hash = {k: v for k, v in report.items() if k != "report_hash"}
        check(label + ": report hash", report["report_hash"] == digest(without_hash))
        status = load(path.parent / "status.json")
        check(label + ": complete cohort", status["state"] == "completed" and status["complete"] is True and status["completed_count"] == len(samples) == status["planned_count"])
        plan = load(path.parent / "manifest.json")
        check(label + ": frozen pre-execution plan", plan["evaluation_manifest"] == report["manifest"] and sorted((s["task_id"], s["trial"], s["run_id"], s["task_hash"]) for s in plan["planned_samples"]) == sorted((s["task_id"], s["trial"], s["run_id"], s["task_hash"]) for s in samples))
        persisted = [json.loads(line) for line in (path.parent / "samples.jsonl").read_text().splitlines() if line]
        check(label + ": JSONL equals report", sorted(persisted, key=lambda s: (s["task_id"], s["trial"])) == samples)
        for group_label, group, aggregate in [("summary", samples, report["summary"])] + [
            (task["task_id"], [s for s in samples if s["task_id"] == task["task_id"]], task) for task in report["by_task"]
        ] + [(split["split"], [s for s in samples if s["split"] == split["split"]], split) for split in report["by_split"]]:
            prefix = label + ": " + group_label
            success = sum(sample["task_success"] for sample in group)
            check(prefix + " success denominator", aggregate["planned_samples"] == len(group) and aggregate["successful_samples"] == success and aggregate["success_rate_pct"] == success * 100 / len(group))
            grouped_tasks = {s["task_id"] for s in group}
            all_trials_successful = sum(all(s["task_success"] for s in group if s["task_id"] == task) for task in grouped_tasks)
            check(prefix + " task denominator", aggregate["task_count"] == len(grouped_tasks) and aggregate["successful_tasks"] == all_trials_successful and aggregate["task_success_rate_pct"] == all_trials_successful * 100 / len(grouped_tasks))
            check(prefix + " classification counts", aggregate["classification_counts"] == {kind: sum(s["classification"] == kind for s in group) for kind in ["success", "task_failure", "scorer_error", "harness_error"]})
            known = [s for s in group if s["usage"] is not None]
            known_sum = sum(s["usage"]["model_attempts"] * 1000 + s["usage"]["output_bytes"] + s["usage"]["tool_attempts"] * 250 for s in known)
            complete = len(known) == len(group)
            cost = aggregate["cost"]
            check(prefix + " charged usage", aggregate["usage"]["known_sum"] == {key: sum(s["usage"][key] for s in known) for key in ["model_attempts", "output_bytes", "tool_attempts", "dispatches"]} and aggregate["usage"]["unknown_count"] == len(group) - len(known) and aggregate["usage"]["complete"] == complete)
            check(prefix + " synthetic accounting", cost["known_sum_units"] == known_sum and cost["unknown_count"] == len(group) - len(known) and cost["complete"] == complete and cost["total_units"] == (known_sum if complete else None) and cost["usd"] is None)
            check(prefix + " cost normalization", cost["per_planned_sample_units"] == (known_sum / len(group) if complete else None) and cost["per_successful_sample_units"] == (known_sum / success if complete and success else None))
            for scope in ["execution", "scoring", "total"]:
                values = sorted(s["latency_us"][scope] for s in group)
                observed = aggregate["latency_us"][scope]
                check(prefix + " " + scope + " pooled quantiles", observed["count"] == len(values) and observed["p50"] == values[math.ceil(len(values) * .50) - 1] and observed["p95"] == values[math.ceil(len(values) * .95) - 1] and observed["min"] == min(values) and observed["max"] == max(values) and observed["mean"] == sum(values) / len(values))
        for sample in samples:
            sample_label = label + ": " + sample["task_id"] + ":" + str(sample["trial"])
            raw = load(path.parent / (sample["task_id"] + "-" + str(sample["trial"]) + ".sample.json"))
            check(sample_label + " canonical raw projection", {key: raw[key] for key in sample} == sample)
            check(sample_label + " success needs execution and external grade", sample["task_success"] == (raw["status"] == "succeeded" and raw["grade"].get("passed") is True and raw["evidence"]["source_unchanged_by_scorer"] is True and sample["failure_class"] == "success"))
            snapshot = path.parent / (sample["task_id"] + "-" + str(sample["trial"])) / "scoring/artifact.txt"
            if snapshot.exists():
                artifact = snapshot.read_bytes()
                expected = (fixture / definitions[sample["task_id"]]["expected_file"]).read_bytes()
                check(sample_label + " independently graded snapshot", raw["artifact_sha256"] == bytes_digest(artifact) and raw["grade"].get("passed") == (artifact == expected))
                check(sample_label + " bound external scorer receipt", raw["grade"].get("task_hash") == sample["task_hash"] and raw["grade"].get("scorer_hash") == scorer_hash and raw["grade"].get("artifact_sha256") == bytes_digest(artifact))
            check(sample_label + " monotonic latency scopes", all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in sample["latency_us"].values()) and sample["latency_us"]["total"] >= sample["latency_us"]["execution"] + sample["latency_us"]["scoring"])
    # Fresh cohorts of the same profile/protocol must have identical semantic
    # outcomes even though execution IDs and measured timings differ.
    repeated = 0
    for index, (name, report) in enumerate(reports):
        for other_name, other in reports[index + 1:]:
            if report["manifest"]["protocol"] == other["manifest"]["protocol"] and report["manifest"]["profile"] == other["manifest"]["profile"]:
                repeated += 1
                check(name + ": repeat signature versus " + other_name, report["semantic_signature"] == other["semantic_signature"])
                check(name + ": repeat uses new Runs versus " + other_name, not ({s["run_id"] for s in report["samples"]} & {s["run_id"] for s in other["samples"]}))
    check("at least one independently repeated cohort", repeated > 0)

    by_hash = {report["report_hash"]: report for _, report in reports}
    for comparison_path in sorted(root.rglob("comparison.json")):
        comparison = load(comparison_path)
        name = comparison_path.parent.relative_to(root).as_posix() + ": comparison"
        old = by_hash.get(comparison["baseline_report_hash"])
        new = by_hash.get(comparison["candidate_report_hash"])
        check(name + " referenced complete reports", old is not None and new is not None)
        if old is None or new is None:
            continue
        check(name + " identical evaluation protocol", old["manifest"]["protocol"] == new["manifest"]["protocol"] and comparison["protocol_hash"] == digest(old["manifest"]["protocol"]))
        threshold = comparison["thresholds"]

        def statuses(previous, current):
            quality = "regressed" if previous["success_rate_pct"] - current["success_rate_pct"] > threshold["success_drop_pp"] else "passed"
            health = "indeterminate" if any(summary["classification_counts"][kind] for summary in [previous, current] for kind in ["scorer_error", "harness_error"]) else "passed"

            def increase(a, b, relative, absolute):
                delta = b - a
                relative_crossed = delta > 0 if a == 0 else delta * 100 > a * relative
                return "regressed" if relative_crossed and delta > absolute else "passed"

            cost = "indeterminate" if not previous["cost"]["complete"] or not current["cost"]["complete"] else increase(previous["cost"]["total_units"], current["cost"]["total_units"], threshold["cost_increase_pct"], threshold["cost_increase_units"])
            result = {"success_rate_pct": quality, "scoring_and_harness_errors": health, "cost.total_units": cost}
            for scope in ["execution", "scoring", "total"]:
                for quantile in ["p50", "p95"]:
                    result["latency_us." + scope + "." + quantile] = increase(previous["latency_us"][scope][quantile], current["latency_us"][scope][quantile], threshold["latency_increase_pct"], threshold["latency_increase_us"])
            return result

        def outcome(states):
            return "regressed" if "regressed" in states else "indeterminate" if "indeterminate" in states else "passed"

        expected = statuses(old["summary"], new["summary"])
        all_states = list(expected.values())
        check(name + " aggregate gates", expected == {c["metric"]: c["status"] for c in comparison["checks"]})
        old_tasks = {task["task_id"]: task for task in old["by_task"]}
        new_tasks = {task["task_id"]: task for task in new["by_task"]}
        check(name + " task gate coverage", sorted(c["task_id"] for c in comparison["by_task"]) == sorted(old_tasks))
        for task in comparison["by_task"]:
            task_expected = statuses(old_tasks[task["task_id"]], new_tasks[task["task_id"]])
            all_states.extend(task_expected.values())
            check(name + " task gates " + task["task_id"], task_expected == {c["metric"]: c["status"] for c in task["checks"]} and task["status"] == outcome(task_expected.values()) and task["passed"] == all(v == "passed" for v in task_expected.values()))
        check(name + " final fail-closed gate", comparison["status"] == outcome(all_states) and comparison["passed"] == all(v == "passed" for v in all_states) and comparison["regressed"] == (not comparison["passed"]))
        check(name + " paired sample coverage", sorted((p["task_id"], p["trial"]) for p in comparison["paired_changes"]) == sorted((s["task_id"], s["trial"]) for s in old["samples"]))
    result = {"schema_version": 1, "checks": checks, "passed": sum(c["passed"] for c in checks), "total": len(checks), "report_count": len(paths), "complete": all(c["passed"] for c in checks)}
    (root / "audit-python.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "checks"}))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 scripts/audit_week20.py FORMAL_DIRECTORY")
    raise SystemExit(main(pathlib.Path(sys.argv[1]).resolve()))
