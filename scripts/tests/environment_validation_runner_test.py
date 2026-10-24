"""Safety properties of the stdlib environment runner (no BEAM/PG required)."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import signal
import threading
import stat
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "environment_validate.py"
SPEC = importlib.util.spec_from_file_location("environment_validate", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asl-w26-test-")
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "scripts").mkdir()
        (self.source / "docs").mkdir()
        for name in ("mix.exs", "mix.lock", "scripts/mix", "scripts/bootstrap_runtime.sh", "scripts/bootstrap_postgres.sh", *runner.LICENSE_PATHS):
            (self.source / name).write_text("fixture\n")
        self.freeze()

    def tearDown(self):
        self.temp.cleanup()

    def freeze(self, root_files=None):
        root_files = runner.ROOT_FILES if root_files is None else root_files
        entries = []
        for path in sorted(self.source.rglob("*")):
            if path.name == runner.MANIFEST:
                continue
            value = {"path": str(path.relative_to(self.source)), "type": "directory" if path.is_dir() else "file", "mode": stat.S_IMODE(path.stat().st_mode)}
            if path.is_file():
                value.update(bytes=path.stat().st_size, sha256=runner.digest(path.read_bytes()))
            entries.append(value)
        rows = ["\0".join([x["path"], x["type"], str(x["mode"]), str(x.get("bytes", 0)), x.get("sha256", "")]) for x in entries]
        value = {"schema_version": 1, "kind": "agent-systems-lab.source-export.v1", "scope": "source only; no prior build, runtime, dependency tree or experiment history", "includes": sorted(root_files | runner.ROOT_DIRS), "excludes": [".git", ".runtime", "deps", "_build", "artifacts", "cover"], "entries": entries, "file_count": sum(x["type"] == "file" for x in entries), "total_bytes": sum(x.get("bytes", 0) for x in entries), "entries_sha256": runner.digest("\n".join(rows).encode())}
        (self.source / runner.MANIFEST).write_text(json.dumps(value))

    def args(self, **values):
        defaults = dict(source=str(self.source), candidate=None, profile="macos-warm", output=str(self.root / "output"), operator_id="operator", host_id="host", new_host=False, cache_from=str(self.root), postgres_prefix=None, port=55593, timeout=30)
        defaults.update(values)
        return argparse.Namespace(**defaults)

    def test_manifest_raw_bytes_binding(self):
        _, sha = runner.verify_source(self.source)
        self.assertEqual(sha, runner.digest((self.source / runner.MANIFEST).read_bytes()))

    def test_changed_source_rejected(self):
        (self.source / "mix.lock").write_text("changed")
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_changed_license_declarations_rejected(self):
        for name in runner.LICENSE_PATHS:
            with self.subTest(name=name):
                path = self.source / name
                original = path.read_bytes()
                path.write_bytes(original + b"changed\n")
                with self.assertRaises(runner.ValidationError):
                    runner.verify_source(self.source)
                path.write_bytes(original)
        runner.verify_source(self.source)

    def test_current_contract_requires_every_license_declaration(self):
        for name in runner.LICENSE_PATHS:
            with self.subTest(name=name):
                path = self.source / name
                original = path.read_bytes()
                path.unlink()
                self.freeze()
                with self.assertRaises(runner.ValidationError):
                    runner.verify_source(self.source)
                path.mkdir()
                self.freeze()
                with self.assertRaises(runner.ValidationError):
                    runner.verify_source(self.source)
                path.rmdir()
                path.write_bytes(original)
        self.freeze()
        runner.verify_source(self.source)

    def test_exact_legacy_contract_verifies_without_rewriting(self):
        for name in runner.LICENSE_PATHS:
            (self.source / name).unlink()
        self.freeze(runner.LEGACY_ROOT_FILES)
        original = (self.source / runner.MANIFEST).read_bytes()
        manifest, sha = runner.verify_source(self.source)
        self.assertEqual(sorted(runner.LEGACY_ROOT_FILES | runner.ROOT_DIRS), manifest["includes"])
        self.assertEqual(runner.digest(original), sha)
        self.assertEqual(original, (self.source / runner.MANIFEST).read_bytes())

    def test_manifest_cannot_extend_or_partially_change_fixed_root_allowlist(self):
        path = self.source / runner.MANIFEST
        original = json.loads(path.read_text())
        for includes in (sorted(runner.ROOT_FILES | runner.ROOT_DIRS | {"private"}), sorted((runner.ROOT_FILES | runner.ROOT_DIRS) - {"NOTICE"})):
            with self.subTest(includes=includes):
                changed = dict(original, includes=includes)
                path.write_text(json.dumps(changed))
                with self.assertRaises(runner.ValidationError):
                    runner.verify_source(self.source)

    def test_undeclared_source_rejected(self):
        (self.source / "scripts/extra").write_text("surprise")
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_runtime_build_artifact_paths_not_source(self):
        for name in (".runtime", "_build", "deps", "artifacts"):
            (self.source / name).mkdir()
            (self.source / name / "unused").write_text("not exported")
        runner.verify_source(self.source)

    def test_manifest_scope_cannot_be_relabelled(self):
        manifest = json.loads((self.source / runner.MANIFEST).read_text())
        manifest["scope"] = "arbitrary"
        (self.source / runner.MANIFEST).write_text(json.dumps(manifest))
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_symlink_source_rejected(self):
        path = self.source / "mix.lock"
        path.unlink()
        path.symlink_to(self.source / "mix.exs")
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_hardlinked_source_rejected(self):
        os.link(self.source / "mix.lock", self.root / "alias")
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_source_mode_mismatch_rejected(self):
        (self.source / "mix.lock").chmod(0o600)
        with self.assertRaises(runner.ValidationError):
            runner.verify_source(self.source)

    def test_special_file_mode_is_rejected_before_read(self):
        path = mock.Mock()
        path.lstat.return_value = mock.Mock(st_mode=stat.S_IFREG | 0o4644, st_nlink=1, st_size=1)
        with self.assertRaises(runner.ValidationError):
            runner.file_bytes(path)
        path.open.assert_not_called()

    def test_linux_pg_prefix_does_not_copy_database(self):
        prefix = self.root / "pg-prefix"
        (prefix / "bin").mkdir(parents=True)
        for name in ("postgres", "initdb", "pg_ctl", "pg_config", "psql", "pg_dump", "pg_restore"):
            (prefix / "bin" / name).write_text("fixture")
        (prefix / "data").mkdir()
        (prefix / "data/secret-database-rows").write_text("never copied")
        workspace = self.root / "workspace"
        workspace.mkdir()
        target = runner.stage_postgres_prefix(prefix, workspace)
        self.assertTrue((target / "bin/pg_dump").is_file())
        self.assertFalse((target / "data").exists())

    def test_relative_paths_reject_escape_and_normalization(self):
        for value in ("../a", "/a", "a/../b", "a//b", "./a", ""):
            with self.subTest(value=value), self.assertRaises(runner.ValidationError):
                runner.relative_path(value)

    def test_candidate_binding_mismatch_rejected(self):
        candidate = self.root / "candidate"
        candidate.mkdir()
        (candidate / "candidate-manifest.json").write_text(json.dumps({"source_manifest_sha256": "0" * 64}))
        with self.assertRaises(runner.ValidationError):
            runner.binding(self.source, candidate)

    def test_plan_is_read_only_and_never_starts_process(self):
        with mock.patch.object(runner.subprocess, "Popen", side_effect=AssertionError("must not execute")), mock.patch.object(runner.subprocess, "run", side_effect=AssertionError("must not execute")):
            plan = runner.make_plan(self.args())
        self.assertFalse(Path(plan["output"]).exists())
        self.assertFalse(plan["full_linux_isolation_passed"])
        self.assertEqual([x["id"] for x in plan["commands"]], list(runner.COMMANDS))

    def test_cold_prohibits_cache_and_requires_host_claim(self):
        for values in (dict(profile="macos-cold"), dict(profile="macos-cold", cache_from=None, new_host=False)):
            with self.subTest(values=values), self.assertRaises(runner.ValidationError):
                runner.make_plan(self.args(**values))
        self.assertEqual("macos-cold", runner.make_plan(self.args(profile="macos-cold", cache_from=None, new_host=True))["profile"])

    def test_warm_cannot_claim_new_host(self):
        with self.assertRaises(runner.ValidationError):
            runner.make_plan(self.args(new_host=True))

    def test_linux_core_fixed_subset_preserves_exclusions(self):
        plan = runner.make_plan(self.args(profile="linux-core", cache_from=None, postgres_prefix=str(self.root)))
        self.assertEqual(["seatbelt"], plan["excluded_tags"])
        self.assertEqual(list(runner.COMMANDS)[2:], [x["id"] for x in plan["commands"]])
        self.assertNotIn("isolation", [x["id"] for x in plan["commands"]])
        self.assertFalse(plan["full_linux_isolation_passed"])

    def test_linux_profile_requires_explicit_pg_prefix(self):
        with self.assertRaises(runner.ValidationError):
            runner.make_plan(self.args(profile="linux-core", cache_from=None))

    def test_existing_output_and_output_inside_source_rejected(self):
        for output in (str(self.root), str(self.source / "fresh")):
            with self.subTest(output=output), self.assertRaises(runner.ValidationError):
                runner.make_plan(self.args(output=output))

    def test_environment_discards_injected_routing_and_flags(self):
        inherited = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "DATABASE_URL": "postgres://production", "PGSERVICE": "production", "PGHOSTADDR": "1.2.3.4", "PGOPTIONS": "unsafe", "ERL_AFLAGS": "evil", "MIX_EXS": "/evil.exs", "HEX_OFFLINE": "1", "LAB_DATABASE_ENABLED": "false"}
        env = runner.sanitize_environment(self.root, 55593, inherited)
        for name in ("DATABASE_URL", "PGSERVICE", "PGHOSTADDR", "PGOPTIONS", "ERL_AFLAGS", "MIX_EXS", "HEX_OFFLINE"):
            self.assertNotIn(name, env)
        self.assertEqual("127.0.0.1", env["PGHOST"])
        self.assertEqual("true", env["LAB_DATABASE_ENABLED"])
        self.assertIn(".runtime/postgres/18.6/bin", env["PATH"])

    def test_stage_has_only_frozen_source(self):
        (self.source / "artifacts").mkdir()
        (self.source / "artifacts/old").write_text("not copied")
        manifest, _ = runner.verify_source(self.source)
        target = self.root / "working"
        runner.stage_source(self.source, target, manifest)
        self.assertFalse((target / "artifacts").exists())
        for name in runner.LICENSE_PATHS:
            self.assertEqual((self.source / name).read_bytes(), (target / name).read_bytes())
        self.assertEqual((self.source / runner.MANIFEST).read_bytes(), (target / runner.MANIFEST).read_bytes())
        runner.verify_source(target)

    def test_busy_port_is_detected_without_contacting_server(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.assertFalse(runner.port_free(sock.getsockname()[1]))

    def test_reusable_active_listener_is_still_refused(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            self.assertFalse(runner.port_free(listener.getsockname()[1]))

    def test_time_wait_without_listener_counts_as_reusable(self):
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        client = socket.socket()
        accepted = None
        try:
            client.connect(("127.0.0.1", port))
            accepted, _ = listener.accept()
            accepted.shutdown(socket.SHUT_WR)
            self.assertEqual(b"", client.recv(1))
        finally:
            if accepted:
                accepted.close()
            client.close()
            listener.close()
        # The server actively closed the accepted connection: the tuple remains
        # TIME_WAIT, yet no listening server exists and PostgreSQL may restart.
        with socket.socket() as bare:
            with self.assertRaises(OSError):
                bare.bind(("127.0.0.1", port))
        self.assertTrue(runner.port_free(port))
        with socket.socket() as probe:
            probe.settimeout(1)
            self.assertNotEqual(0, probe.connect_ex(("127.0.0.1", port)))

    def test_mismatched_platform_never_creates_output(self):
        with mock.patch.object(runner, "observed_platform", return_value="linux"):
            with self.assertRaises(runner.ValidationError):
                runner.run(self.args())
        self.assertFalse((self.root / "output").exists())

    def test_owned_stop_refuses_changed_identity(self):
        pg = runner.OwnedPostgres(self.root / "owned", {}, 55593)
        pg.started, pg.identity = True, {"pid": 1}
        with mock.patch.object(pg, "observed_identity", return_value={"pid": 2}), mock.patch.object(pg, "call", side_effect=AssertionError("must not stop")):
            with self.assertRaises(runner.ValidationError):
                pg.stop()

    def test_preexisting_busy_port_never_initdb_or_stop(self):
        pg = runner.OwnedPostgres(self.root / "owned", {}, 55593)
        with mock.patch.object(runner, "port_free", return_value=False), mock.patch.object(pg, "call", side_effect=AssertionError("no action")):
            with self.assertRaises(runner.ValidationError):
                pg.start()
        self.assertFalse(pg.root.exists())

    def test_command_success_and_nonzero_exit_are_recorded(self):
        env = dict(os.environ)
        for code in (0, 7):
            log = self.root / ("exit-%d.log" % code)
            result, clean = runner.execute([sys.executable, "-c", "print('receipt'); raise SystemExit(%d)" % code], self.root, env, log, 5)
            self.assertEqual(code, result)
            self.assertTrue(clean)
            self.assertEqual(b"receipt\n", log.read_bytes())

    def test_timeout_cleans_owned_process_group(self):
        log = self.root / "timeout.log"
        result, clean = runner.execute([sys.executable, "-c", "import time; time.sleep(30)"], self.root, dict(os.environ), log, 0.1)
        self.assertEqual(124, result)
        self.assertTrue(clean)
        self.assertIn(b"timeout", log.read_bytes())

    def test_output_limit_aborts_with_failure_not_silent_truncation(self):
        log = self.root / "limit.log"
        result, clean = runner.execute([sys.executable, "-c", "import os; os.write(1,b'x'*100000); import time; time.sleep(30)"], self.root, dict(os.environ), log, 5, max_log=1024)
        self.assertEqual(125, result)
        self.assertTrue(clean)
        self.assertIn(b"log limit", log.read_bytes())
        self.assertLess(log.stat().st_size, 1100)

    def test_probe_stderr_warning_cannot_pollute_sql_identity(self):
        value = runner.version_probe([sys.executable, "-c", "import sys; print('/owned/data|55593|123'); print('WARNING: password file', file=sys.stderr)"], dict(os.environ), self.root)
        self.assertEqual("/owned/data|55593|123", value)
        self.assertIn("WARNING", (self.root / "probe-diagnostics.log").read_text())

    def test_signal_exit_status_is_collectible(self):
        log = self.root / "signal.log"
        result, clean = runner.execute([sys.executable, "-c", "import os,signal; os.kill(os.getpid(), signal.SIGTERM)"], self.root, dict(os.environ), log, 5)
        self.assertEqual(143, result)
        self.assertTrue(clean)

    def test_controlled_sigterm_cleans_the_owned_command(self):
        old = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
        timer = threading.Timer(0.1, lambda: os.kill(os.getpid(), signal.SIGTERM))
        try:
            signal.signal(signal.SIGTERM, runner.interrupt_handler)
            timer.start()
            with self.assertRaises(runner.RunnerInterrupted):
                runner.execute([sys.executable, "-c", "import os,time; print(os.getpid(),flush=True); time.sleep(30)"], self.root, dict(os.environ), self.root / "interrupted.log", 5)
            pid = int((self.root / "interrupted.log").read_text().strip())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            timer.cancel()
            timer.join()
            for value, handler in old.items():
                signal.signal(value, handler)

    def test_selector_setup_interruption_cleans_owned_process(self):
        real_popen = runner.subprocess.Popen
        children = []
        def tracked(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            return child
        for probe in (False, True):
            with self.subTest(probe=probe), mock.patch.object(runner.subprocess, "Popen", side_effect=tracked), mock.patch.object(runner.selectors, "DefaultSelector", side_effect=runner.RunnerInterrupted("setup fault")):
                with self.assertRaises(runner.RunnerInterrupted) as caught:
                    if probe:
                        runner.version_probe([sys.executable, "-c", "import time; time.sleep(30)"], dict(os.environ), self.root)
                    else:
                        runner.execute([sys.executable, "-c", "import time; time.sleep(30)"], self.root, dict(os.environ), self.root / "setup.log", 5)
                self.assertTrue(caught.exception.owned_processes_exited)
                self.assertIsNotNone(children[-1].poll())

    def test_signal_during_popen_is_deferred_until_owner_registration(self):
        real_popen = runner.subprocess.Popen
        children = []
        old = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
        def interrupted_spawn(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            children.append(child)
            runner.interrupt_handler(signal.SIGTERM, None)
            return child
        try:
            with mock.patch.object(runner.subprocess, "Popen", side_effect=interrupted_spawn):
                with self.assertRaises(runner.RunnerInterrupted) as caught:
                    runner.execute([sys.executable, "-c", "import time; time.sleep(30)"], self.root, dict(os.environ), self.root / "spawn.log", 5)
                self.assertTrue(caught.exception.owned_processes_exited)
                self.assertIsNotNone(children[-1].poll())
        finally:
            for value, handler in old.items():
                signal.signal(value, handler)

    def test_silent_failure_log_is_nonempty_and_collectible(self):
        log = self.root / "silent.log"
        status, clean = runner.execute([sys.executable, "-c", "raise SystemExit(7)"], self.root, dict(os.environ), log, 5)
        self.assertEqual(7, status)
        self.assertTrue(clean)
        self.assertIn(b"runner exit status: 7", log.read_bytes())
        self.assertGreater(runner.reference(self.root, log)["bytes"], 0)

    def test_reference_rejects_links(self):
        target = self.root / "receipt.log"
        target.write_text("receipt")
        alias = self.root / "alias.log"
        alias.symlink_to(target)
        with self.assertRaises(runner.ValidationError):
            runner.reference(self.root, alias)


if __name__ == "__main__":
    unittest.main()
