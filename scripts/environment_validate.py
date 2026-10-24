#!/usr/bin/env python3
"""Frozen-source environment exercise; Python 3 stdlib, no imported shell commands.

A successful local exercise is not proof of a new host or full Linux isolation.
Run only source you trust. Hashes establish integrity, not source authenticity.
"""
import argparse
from contextlib import contextmanager
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

PINS = {"elixir": "1.20.4", "otp": "28.4", "postgres": "18.6"}
MANIFEST = "reproduction-source-manifest.json"
# Immutable W22-W26 exports used the first contract. Accept only that exact
# legacy list or today's list; a manifest cannot extend its own source allowlist.
LEGACY_ROOT_FILES = {".formatter.exs", ".gitignore", ".tool-versions", "README.md", "mix.exs", "mix.lock", "Agent Systems Engineering 研究与落地计划.md"}
LICENSE_FILES = {"LICENSE", "LICENSE-DOCS", "NOTICE"}
LICENSE_PATHS = LICENSE_FILES | {"docs/licensing.md"}
ROOT_FILES = LEGACY_ROOT_FILES | LICENSE_FILES | {".gitattributes"}
ROOT_DIRS = {".github", "book", "config", "docs", "fixtures", "labs", "lib", "priv", "scripts", "test"}
COMMANDS = {
    "runtime": ["./scripts/bootstrap_runtime.sh"],
    "postgres": ["./scripts/bootstrap_postgres.sh"],
    "dependencies": ["./scripts/mix", "deps.get", "--only", "test"],
    "full": ["./scripts/mix", "check"],
    "memory": ["./scripts/mix", "test"],
    "verify": ["./scripts/mix", "lab.verify"],
    "p1": ["./scripts/mix", "lab.p1", "--output", "artifacts/reproduction-p1"],
    "history": ["./scripts/mix", "lab.history", "--output", "artifacts/reproduction-history"],
    "recover": ["./scripts/mix", "lab.recover", "--output", "artifacts/reproduction-recovery", "--repetitions", "1"],
    "fence": ["./scripts/mix", "lab.fence", "--output", "artifacts/reproduction-fence", "--repetitions", "1"],
    "upgrade": ["./scripts/mix", "lab.upgrade", "--output", "artifacts/reproduction-upgrade"],
}
PROFILES = ("macos-warm", "macos-cold", "linux-core")
MAX_LOG = 32 * 1024 * 1024


class ValidationError(Exception):
    pass


class RunnerInterrupted(Exception):
    pass


_spawn_defer = 0
_pending_signal = None


def interrupt_handler(signum, _frame):
    global _pending_signal
    if _spawn_defer:
        _pending_signal = signum
        return
    # One controlled interruption initiates cleanup; repeated signals cannot cut it short.
    for value in (signal.SIGINT, signal.SIGTERM):
        signal.signal(value, signal.SIG_IGN)
    raise RunnerInterrupted("signal " + str(signum))


def deliver_pending(clean=True):
    global _pending_signal
    value, _pending_signal = _pending_signal, None
    if value is not None:
        try:
            interrupt_handler(value, None)
        except RunnerInterrupted as error:
            error.owned_processes_exited = clean
            raise


@contextmanager
def owned_process(argv, cwd, env, separate_stderr=False):
    # Defer Python's handler across Popen's fork/return/owner-registration window.
    # Blocking the OS mask here would also block signals in the child process.
    global _spawn_defer
    owner, error, startup = {"process": None, "clean": True}, None, True
    _spawn_defer += 1
    try:
        owner["process"] = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE if separate_stderr else subprocess.STDOUT, start_new_session=True)
        startup = False
        _spawn_defer -= 1
        deliver_pending()
        yield owner
    except BaseException as caught:
        error = caught
        raise
    finally:
        if startup:
            _spawn_defer -= 1
        _spawn_defer += 1
        try:
            proc = owner["process"]
            if proc is not None:
                owner["clean"] = terminate_group(proc.pid, proc)
                proc.wait(timeout=5)
                proc.stdout.close()
                if separate_stderr:
                    proc.stderr.close()
        finally:
            _spawn_defer -= 1
            if error is not None:
                error.owned_processes_exited = owner["clean"]
        deliver_pending(owner["clean"])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_bytes(path, limit=MAX_LOG):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_mode & 0o7000 or before.st_size > limit:
        raise ValidationError("unsafe or oversized regular file: " + str(path))
    with path.open("rb") as handle:
        raw = handle.read(limit + 1)
    after = path.lstat()
    if len(raw) > limit or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValidationError("file changed during read: " + str(path))
    return raw


def physical_directory(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve() or not path.is_dir():
        raise ValidationError("expected absolute physical directory: " + str(path))
    return path


def relative_path(value):
    path = PurePosixPath(value)
    if not isinstance(value, str) or not value or str(path) != value or path.is_absolute() or any(x in ("", ".", "..") for x in path.parts):
        raise ValidationError("unsafe relative path")
    return path


def verify_source(source):
    source = physical_directory(source)
    raw = file_bytes(source / MANIFEST, 4 * 1024 * 1024)
    manifest = json.loads(raw)
    if manifest.get("schema_version") != 1 or manifest.get("kind") != "agent-systems-lab.source-export.v1":
        raise ValidationError("not a frozen source-only export")
    if manifest.get("includes") == sorted(ROOT_FILES | ROOT_DIRS):
        root_files = ROOT_FILES
    elif manifest.get("includes") == sorted(LEGACY_ROOT_FILES | ROOT_DIRS):
        root_files = LEGACY_ROOT_FILES
    else:
        raise ValidationError("source manifest contract mismatch")
    if set(manifest) != {"schema_version", "kind", "scope", "includes", "excludes", "entries", "file_count", "total_bytes", "entries_sha256"} or manifest.get("excludes") != [".git", ".runtime", "deps", "_build", "artifacts", "cover"] or manifest.get("scope") != "source only; no prior build, runtime, dependency tree or experiment history":
        raise ValidationError("source manifest contract mismatch")
    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries or len(entries) > 10000:
        raise ValidationError("invalid source inventory")
    expected, paths, total, files = [], [], 0, 0
    for entry in entries:
        name = relative_path(entry["path"])
        if name.parts[0] not in root_files | ROOT_DIRS or (name.parts[0] in root_files and len(name.parts) != 1):
            raise ValidationError("source entry outside fixed allowlist")
        path = source.joinpath(*name.parts)
        for parent in [path] + list(path.parents)[:len(name.parts) - 1]:
            if parent.is_symlink():
                raise ValidationError("source symlink")
        st = path.lstat()
        mode = stat.S_IMODE(st.st_mode)
        if mode & 0o7000 or mode != entry.get("mode"):
            raise ValidationError("source mode mismatch")
        kind = entry.get("type")
        if kind == "directory" and stat.S_ISDIR(st.st_mode):
            if set(entry) != {"path", "type", "mode"}:
                raise ValidationError("invalid directory inventory")
        elif kind == "file" and stat.S_ISREG(st.st_mode):
            data = file_bytes(path, 2 * 1024 * 1024)
            if set(entry) != {"path", "type", "mode", "bytes", "sha256"} or len(data) != entry["bytes"] or digest(data) != entry["sha256"]:
                raise ValidationError("source file mismatch")
            files += 1
            total += len(data)
        else:
            raise ValidationError("source type mismatch")
        paths.append(str(name))
        expected.append("\0".join([str(name), kind, str(mode), str(entry.get("bytes", 0)), entry.get("sha256", "")]))
    if paths != sorted(set(paths)) or total > 64 * 1024 * 1024:
        raise ValidationError("source inventory order, duplicates or bounds")
    actual = []
    for name in sorted(root_files | ROOT_DIRS):
        start = source / name
        if start.exists() or start.is_symlink():
            actual.append(name)
            if start.is_dir() and not start.is_symlink():
                for parent, dirs, names in os.walk(start, followlinks=False):
                    actual.extend(str((Path(parent) / item).relative_to(source)) for item in dirs + names)
    required_licenses = LICENSE_PATHS if root_files == ROOT_FILES else set()
    required = {"mix.exs", "mix.lock", "scripts/mix", "scripts/bootstrap_runtime.sh", "scripts/bootstrap_postgres.sh"} | required_licenses
    if sorted(actual) != paths or not required.issubset(entry["path"] for entry in entries if entry["type"] == "file"):
        raise ValidationError("source inventory missing or undeclared paths")
    if manifest.get("file_count") != files or manifest.get("total_bytes") != total or manifest.get("entries_sha256") != digest("\n".join(expected).encode()):
        raise ValidationError("source manifest summary mismatch")
    return manifest, digest(raw)


def binding(source, candidate=None):
    manifest, source_sha = verify_source(source)
    candidate_sha = None
    if candidate:
        candidate = physical_directory(candidate)
        raw = file_bytes(candidate / "candidate-manifest.json", 4 * 1024 * 1024)
        value = json.loads(raw)
        if value.get("source_manifest_sha256") != source_sha:
            raise ValidationError("candidate and frozen source mismatch")
        candidate_sha = digest(raw)
    return manifest, {"source_manifest_sha256": source_sha, "candidate_manifest_sha256": candidate_sha}


def observed_platform():
    return {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), "unsupported")


def command_ids(profile):
    return list(COMMANDS)[2:] if profile == "linux-core" else list(COMMANDS)


def sanitize_environment(workspace, port, inherited=None):
    inherited = os.environ if inherited is None else inherited
    # Start from an allowlist, so future libpq/BEAM/Mix routing variables cannot leak.
    env = {key: inherited[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy") if key in inherited}
    runtime = workspace / ".runtime"
    env.update({"PGHOST": "127.0.0.1", "PGPORT": str(port), "PGUSER": "postgres", "PGPASSWORD": "", "PGPASSFILE": str(runtime / "empty-pgpass"), "MIX_HOME": str(runtime / "mix"), "HEX_HOME": str(runtime / "hex"), "MIX_ARCHIVES": str(runtime / "mix/archives"), "MIX_REBAR3": str(runtime / "mix/elixir/1-20-otp-28/rebar3"), "REBAR_CACHE_DIR": str(runtime / "rebar/cache"), "REBAR_GLOBAL_CONFIG_DIR": str(runtime / "rebar/config"), "MIX_DEPS_PATH": str(workspace / "deps"), "MIX_BUILD_ROOT": str(workspace / "_build"), "MIX_TARGET": "host", "MIX_ENV": "test", "LAB_DATABASE_ENABLED": "true", "LAB_SCHEDULER_ENABLED": "false"})
    env["PATH"] = os.pathsep.join([str(runtime / "elixir/1.20.4-otp-28/bin"), str(runtime / "otp/28.4/bin"), str(runtime / "postgres/18.6/bin"), env.get("PATH", "/usr/bin:/bin")])
    return env


def port_free(port):
    sock = socket.socket()
    # PostgreSQL can rebind after its accepted connections enter TIME_WAIT.
    # SO_REUSEADDR still refuses an active listener at this exact address/port.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        return False
    finally:
        sock.close()
    return True


def terminate_group(pid, process=None):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
        if process is not None:
            process.poll()
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True


def execute(argv, cwd, env, log, timeout=1800, max_log=MAX_LOG):
    """No shell. Bound duration and captured bytes; kill the owned process group."""
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    count, status, reason = 0, None, None
    with owned_process(argv, cwd, env) as owner:
        proc, selector = owner["process"], None
        try:
            selector = selectors.DefaultSelector()
            selector.register(proc.stdout, selectors.EVENT_READ)
            with log.open("xb") as out:
                os.chmod(log, 0o600)
                while selector.get_map():
                    if time.monotonic() - started > timeout:
                        reason, status = "timeout", 124
                        break
                    for key, _ in selector.select(0.1):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        if count + len(chunk) > max(0, max_log - 64):
                            reason, status = "log limit", 125
                            break
                        out.write(chunk)
                        count += len(chunk)
                    if reason:
                        break
                if reason:
                    out.write(("\nrunner aborted: " + reason + "\n").encode()[:max_log - count])
                if status is None:
                    status = proc.wait(timeout=max(0.1, timeout - (time.monotonic() - started)))
                status = 128 - status if status < 0 else status
                if out.tell() == 0:
                    out.write(("runner exit status: %d\n" % status).encode()[:max_log])
        finally:
            if selector is not None:
                selector.close()
    return status, owner["clean"]


def reference(root, path):
    raw = file_bytes(path, MAX_LOG)
    return {"path": str(path.relative_to(root)), "sha256": digest(raw), "bytes": len(raw)}


def json_write(path, value):
    with path.open("x", encoding="utf-8") as out:
        os.chmod(path, 0o600)
        json.dump(value, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        out.write("\n")


def stage_source(source, workspace, manifest):
    workspace.mkdir(mode=0o700)
    for entry in manifest["entries"]:
        target = workspace / entry["path"]
        if entry["type"] == "directory":
            target.mkdir(mode=entry["mode"])
        else:
            target.write_bytes(file_bytes(source / entry["path"], 2 * 1024 * 1024))
            target.chmod(entry["mode"])
    (workspace / MANIFEST).write_bytes(file_bytes(source / MANIFEST, 4 * 1024 * 1024))
    (workspace / MANIFEST).chmod(0o600)
    verify_source(workspace)


def stage_warm_cache(cache, workspace):
    cache = physical_directory(cache)
    runtime, old = workspace / ".runtime", cache / ".runtime"
    runtime.mkdir(mode=0o700)
    for name in ("otp/28.4", "elixir/1.20.4-otp-28", "postgres/18.6"):
        location = physical_directory(old / name)
        (runtime / name).parent.mkdir(parents=True, exist_ok=True)
        os.symlink(location, runtime / name, target_is_directory=True)
    # Copy writable package caches, never deps, build trees, database or PGDATA.
    for name in ("mix", "hex", "downloads"):
        location = old / name
        if location.exists():
            if location.is_symlink() or not location.is_dir():
                raise ValidationError("cache directory is not physical")
            entries, total = [], 0
            for parent, dirs, files in os.walk(location, followlinks=False):
                for item in dirs:
                    child = Path(parent) / item
                    if child.is_symlink():
                        raise ValidationError("cache symlink rejected")
                for item in files:
                    child = Path(parent) / item
                    data = file_bytes(child, 134217728)
                    total += len(data)
                    entries.append(child)
                    if len(entries) > 10000 or total > 268435456:
                        raise ValidationError("cache bounds exceeded")
            shutil.copytree(location, runtime / name, symlinks=False)


def stage_postgres_prefix(prefix, workspace):
    """Only installed tool directories are copied; no incidental PGDATA or rows."""
    prefix = physical_directory(prefix)
    target = workspace / ".runtime/postgres/18.6"
    target.mkdir(mode=0o700, parents=True)
    for name in ("bin", "lib", "share", "include"):
        origin = prefix / name
        if origin.exists():
            if not origin.is_dir():
                raise ValidationError("PostgreSQL prefix directory invalid")
            shutil.copytree(origin, target / name, symlinks=False)
    if not all((target / "bin" / name).is_file() for name in ("postgres", "initdb", "pg_ctl", "pg_config", "psql", "pg_dump", "pg_restore")):
        raise ValidationError("PostgreSQL prefix lacks required pinned tools")
    return target


def version_probe(argv, env, cwd):
    # Keep stderr separate: libpq warnings must never become SQL identity fields.
    captured, started = {"out": bytearray(), "err": bytearray()}, time.monotonic()
    with owned_process(argv, cwd, env, separate_stderr=True) as owner:
        proc, selector = owner["process"], None
        try:
            selector = selectors.DefaultSelector()
            selector.register(proc.stdout, selectors.EVENT_READ, "out")
            selector.register(proc.stderr, selectors.EVENT_READ, "err")
            while selector.get_map():
                if time.monotonic() - started > 30:
                    raise ValidationError("version/identity probe timeout")
                for key, _ in selector.select(0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        captured[key.data].extend(chunk)
                        if sum(map(len, captured.values())) > 65536:
                            raise ValidationError("version/identity probe output limit")
            code = proc.wait(timeout=5)
        finally:
            if selector is not None:
                selector.close()
    if not owner["clean"]:
        raise ValidationError("version/identity probe group did not exit")
    if captured["err"]:
        diagnostics = Path(cwd) / "probe-diagnostics.log"
        if diagnostics.exists():
            file_bytes(diagnostics, 65536)
        with diagnostics.open("ab") as out:
            os.chmod(diagnostics, 0o600)
            if out.tell() + len(captured["err"]) <= 65536:
                out.write(captured["err"])
    if code:
        raise ValidationError("version/identity probe failed: " + argv[0])
    return captured["out"].decode("utf-8", "replace").strip()


def measure_tools(workspace, env):
    elixir = version_probe(["elixir", "--version"], env, workspace)
    match = re.search(r"Elixir (\d+\.\d+\.\d+)", elixir)
    otp_file = version_probe(["erl", "-noshell", "-eval", 'io:format("~s", [filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])]), halt().'], env, workspace)
    otp = Path(otp_file).read_text().strip()
    postgres = version_probe(["pg_config", "--version"], env, workspace)
    pg = re.search(r"PostgreSQL (\d+\.\d+)", postgres)
    values = {"elixir": match.group(1) if match else "unknown", "otp": otp, "postgres": pg.group(1) if pg else "unknown"}
    if values != PINS:
        raise ValidationError("tool version mismatch: " + json.dumps(values))
    return values


def input_records(source, workspace, env, source_sha):
    records = [{"id": "source", "origin": str(source / MANIFEST), "sha256": source_sha}, {"id": "mix_lock", "origin": str(source / "mix.lock"), "sha256": digest(file_bytes(source / "mix.lock"))}]
    for ident, archives, executable in (("otp", ["otp-aarch64-apple-darwin.tar.gz", "otp-x86_64-apple-darwin.tar.gz"], "erl"), ("elixir", ["elixir-1.20.4-otp-28.zip"], "elixir"), ("postgres", ["postgresql-18.6.tar.bz2"], "pg_config")):
        chosen = next((workspace / ".runtime/downloads" / name for name in archives if (workspace / ".runtime/downloads" / name).is_file()), None)
        if chosen is None:
            binary = shutil.which(executable, path=env["PATH"])
            if not binary:
                # Failure evidence identifies absence instead of inventing input bytes.
                continue
            chosen = Path(binary).resolve()
        records.append({"id": ident, "origin": str(chosen), "sha256": digest(file_bytes(chosen, 134217728))})
    return records


class OwnedPostgres:
    """Only this fresh cluster may be stopped, after PID, data path and SQL checks."""
    def __init__(self, root, env, port, timeout=120):
        self.root, self.env, self.port, self.timeout = root, env, port, timeout
        self.data, self.socket = root / "data", root / "socket"
        self.identity = None
        self.started = False
        self.processes_clean = True
        self.observation = None

    def call(self, ident, argv):
        status, clean = execute(argv, self.root, self.env, self.root / (ident + ".log"), self.timeout)
        self.processes_clean &= clean
        if status:
            raise ValidationError("owned PostgreSQL step failed: " + ident)

    def sql(self, query):
        return version_probe(["psql", "-X", "-A", "-t", "-h", "127.0.0.1", "-p", str(self.port), "-U", "postgres", "-d", "postgres", "-c", query], self.env, self.root)

    def observed_identity(self):
        pid_lines = (self.data / "postmaster.pid").read_text().splitlines()
        if len(pid_lines) < 4:
            raise ValidationError("owned postmaster PID file incomplete")
        sql = self.sql("SELECT current_setting('data_directory') || '|' || current_setting('port') || '|' || system_identifier::text FROM pg_control_system()")
        data, port, system_id = sql.split("|")
        if Path(data).resolve() != self.data.resolve() or int(port) != self.port or Path(pid_lines[1]).resolve() != self.data.resolve() or int(pid_lines[3]) != self.port:
            raise ValidationError("owned PostgreSQL identity mismatch")
        return {"pid": int(pid_lines[0]), "data_directory": str(self.data), "port": self.port, "system_identifier": system_id, "postmaster_started_at": pid_lines[2]}

    def start(self):
        if not port_free(self.port):
            raise ValidationError("requested port is occupied; no server was stopped")
        self.root.mkdir(mode=0o700)
        self.socket.mkdir(mode=0o700)
        self.call("initdb", ["initdb", "-D", str(self.data), "-U", "postgres", "--auth-local=trust", "--auth-host=trust", "--locale=C", "--encoding=UTF8"])
        # All clients use explicit loopback; disabling Unix sockets avoids path limits.
        options = "-h 127.0.0.1 -p %d -k '' -c fsync=on -c synchronous_commit=on -c full_page_writes=on" % self.port
        try:
            self.call("start", ["pg_ctl", "-D", str(self.data), "-l", str(self.root / "server.log"), "-o", options, "-w", "start"])
        finally:
            if (self.data / "postmaster.pid").is_file():
                self.started = True
                self.identity = self.observed_identity()
        if not self.started:
            raise ValidationError("owned PostgreSQL did not create its PID file")
        row = self.sql("SELECT current_setting('fsync') || '|' || current_setting('synchronous_commit') || '|' || current_setting('full_page_writes') || '|' || (SELECT count(*) FROM pg_database WHERE datname LIKE 'agent_systems_lab_%')::text")
        fsync, synchronous_commit, full_page_writes, count = row.split("|")
        self.observation = {"identity": self.identity, "durability": {"fsync": fsync, "synchronous_commit": synchronous_commit, "full_page_writes": full_page_writes}, "initial_lab_database_count": int(count)}
        json_write(self.root / "cluster-observation.json", self.observation)
        if (fsync, synchronous_commit, full_page_writes, int(count)) != ("on", "on", "on", 0):
            raise ValidationError("owned PostgreSQL must be empty with all durability settings on")

    def stop(self):
        if not self.started:
            return not (self.data / "postmaster.pid").exists(), port_free(self.port)
        current = self.observed_identity()
        if self.identity is None or current != self.identity:
            raise ValidationError("ownership changed; refusing to stop PostgreSQL")
        self.call("stop", ["pg_ctl", "-D", str(self.data), "-m", "fast", "-w", "stop"])
        self.started = False
        return not (self.data / "postmaster.pid").exists(), port_free(self.port)


def make_plan(args):
    source = physical_directory(args.source)
    _, bound = binding(source, args.candidate)
    output = Path(args.output)
    if not output.is_absolute() or output.exists() or output.is_symlink() or not output.parent.is_dir() or output.parent != output.parent.resolve() or source == output or source in output.parents:
        raise ValidationError("output must be a fresh absolute physical directory outside source")
    if args.profile not in PROFILES or not 55433 <= args.port <= 65535 or not 1 <= args.timeout <= 3600:
        raise ValidationError("profile, port or timeout is invalid")
    if args.profile == "macos-cold" and (args.cache_from or not args.new_host):
        raise ValidationError("cold profile requires explicit new-host claim and prohibits cache reuse")
    if args.profile == "macos-warm" and (not args.cache_from or args.new_host):
        raise ValidationError("warm profile requires trusted cache and cannot claim new host")
    if args.profile == "linux-core" and not args.postgres_prefix:
        raise ValidationError("Linux core requires explicit trusted --postgres-prefix with pinned pg_dump/pg_restore")
    if args.postgres_prefix:
        if args.profile != "linux-core":
            raise ValidationError("--postgres-prefix belongs only to Linux core")
        physical_directory(args.postgres_prefix)
    if args.profile == "linux-core" and args.cache_from:
        raise ValidationError("Linux core uses preinstalled pinned tools, not macOS caches")
    if args.cache_from:
        physical_directory(args.cache_from)
    return {"schema_version": 1, "kind": "agent-systems-lab.environment-plan.v1", "binding": bound, "profile": args.profile, "source": str(source), "output": str(output), "commands": [{"id": ident, "argv": COMMANDS[ident]} for ident in command_ids(args.profile)], "excluded_tags": ["seatbelt"] if args.profile == "linux-core" else [], "full_linux_isolation_passed": False, "port": args.port, "timeout_seconds": args.timeout, "measured_platform": observed_platform(), "requires_platform": "linux" if args.profile == "linux-core" else "macos", "claims": "host identity/new-host claims are self-reported; no release approval or publication"}


def run(args):
    plan = make_plan(args)
    if plan["measured_platform"] != plan["requires_platform"]:
        raise ValidationError("profile differs from measured platform")
    if not port_free(args.port):
        raise ValidationError("requested port is occupied; no server was stopped")
    output, source = Path(args.output), Path(args.source)
    manifest, bound = binding(source, args.candidate)
    output.mkdir(mode=0o700)
    workspace = output / "workspace"
    records, pg, tools, failure, clean = [], None, {key: "unavailable" for key in PINS}, None, True
    source_verified_after = False
    cleanup = {"owned_postgres_stopped": False, "port_released": False, "owned_processes_exited": False}
    env = sanitize_environment(workspace, args.port)
    try:
        stage_source(source, workspace, manifest)
        if args.cache_from:
            stage_warm_cache(Path(args.cache_from), workspace)
        if args.profile == "linux-core":
            stage_postgres_prefix(Path(args.postgres_prefix), workspace)
        runtime = workspace / ".runtime"
        runtime.mkdir(mode=0o700, exist_ok=True)
        (runtime / "empty-pgpass").write_text("")
        (runtime / "empty-pgpass").chmod(0o600)
        for ident in command_ids(args.profile):
            log = output / "logs" / (ident + ".log")
            if failure:
                log.parent.mkdir(exist_ok=True)
                log.write_text("not run: previous step failed\n")
                log.chmod(0o600)
                code = 125
            else:
                try:
                    if ident == "dependencies":
                        tools = measure_tools(workspace, env)
                        pg = OwnedPostgres(output / "owned-postgres", env, args.port)
                        pg.start()
                        # New private MIX_HOME needs Hex; macOS-warm copies its trusted archive.
                        if not args.cache_from:
                            code, child_clean = execute(["./scripts/mix", "local.hex", "--force"], workspace, env, output / "logs/local-hex.log", args.timeout)
                            clean &= child_clean
                            if code:
                                raise ValidationError("Hex bootstrap failed")
                            code, child_clean = execute(["./scripts/mix", "local.rebar", "--force"], workspace, env, output / "logs/local-rebar.log", args.timeout)
                            clean &= child_clean
                            if code:
                                raise ValidationError("Rebar bootstrap failed")
                    command_env = dict(env)
                    if ident == "memory":
                        command_env["LAB_DATABASE_ENABLED"] = "false"
                    code, child_clean = execute(COMMANDS[ident], workspace, command_env, log, args.timeout)
                    clean &= child_clean
                    if code:
                        failure = ident + " returned " + str(code)
                except Exception as error:
                    clean &= getattr(error, "owned_processes_exited", True)
                    if not log.exists():
                        log.parent.mkdir(exist_ok=True)
                        log.write_text("runner error: " + str(error) + "\n")
                        log.chmod(0o600)
                    code, failure = 125, str(error)
            result = workspace / "artifacts" / {"p1": "reproduction-p1/report.json", "history": "reproduction-history/report.json", "recover": "reproduction-recovery/report.json", "fence": "reproduction-fence/report.json", "upgrade": "reproduction-upgrade/report.json"}.get(ident, "__absent__")
            records.append({"id": ident, "argv": COMMANDS[ident], "exit_status": code, "log": reference(output, log), "result": reference(output, result) if result.is_file() and not result.is_symlink() else None})
        verify_source(workspace)
        source_verified_after = True
    except (Exception, KeyboardInterrupt) as error:
        clean &= getattr(error, "owned_processes_exited", True)
        failure = str(error) or type(error).__name__
    finally:
        if signal.getsignal(signal.SIGTERM) == interrupt_handler:
            for value in (signal.SIGINT, signal.SIGTERM):
                signal.signal(value, signal.SIG_IGN)
        if pg:
            try:
                stopped, released = pg.stop()
                cleanup.update(owned_postgres_stopped=stopped, port_released=released)
            except Exception as error:
                failure = (failure + "; " if failure else "") + str(error)
            clean &= pg.processes_clean
        else:
            cleanup.update(owned_postgres_stopped=True, port_released=port_free(args.port))
        cleanup["owned_processes_exited"] = clean
        # Preserve explicit not-run records for early staging/ownership failures too.
        for ident in command_ids(args.profile)[len(records):]:
            log = output / "logs" / (ident + ".log")
            log.parent.mkdir(exist_ok=True)
            if not log.exists():
                log.write_text("not run: " + (failure or "runner failure") + "\n")
                log.chmod(0o600)
            records.append({"id": ident, "argv": COMMANDS[ident], "exit_status": 125, "log": reference(output, log), "result": None})
        value = {"schema_version": 1, "kind": "agent-systems-lab.environment-execution.v1", "binding": bound, "profile": args.profile, "measured": {"platform": observed_platform(), "architecture": platform.machine(), "tools": tools}, "self_reported": {"operator_id": args.operator_id, "host_id": args.host_id, "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "new_host": bool(args.new_host)}, "cache_facts": {"runtime_cache_reused": args.profile != "macos-cold", "dependency_cache_reused": bool(args.cache_from), "database_reused": False}, "inputs": input_records(source, workspace, env, bound["source_manifest_sha256"]), "commands": records, "cleanup": cleanup, "ownership": {"postgres": pg.identity if pg else None, "cluster_observation": pg.observation if pg else None, "failure": failure, "fresh_source_workspace": str(workspace), "cache_from": args.cache_from, "source_verified_after": source_verified_after, "full_linux_isolation_passed": False}}
        json_write(output / "execution.json", value)
    print(json.dumps({"execution": str(output / "execution.json"), "completed": failure is None, "cleanup": cleanup, "full_linux_isolation_passed": False}, sort_keys=True))
    return 0 if failure is None and all(cleanup.values()) else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("plan", "run"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--operator-id", required=True)
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--new-host", action="store_true")
    parser.add_argument("--cache-from")
    parser.add_argument("--postgres-prefix", help="Linux: trusted preinstalled PostgreSQL 18.6 prefix, copied without databases")
    parser.add_argument("--port", type=int, default=55591)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args(argv)
    try:
        for value in (args.operator_id, args.host_id):
            if not value or len(value) > 128 or any(ord(c) < 32 for c in value):
                raise ValidationError("operator and host IDs must be short nonempty text")
        if args.mode == "plan":
            print(json.dumps(make_plan(args), ensure_ascii=False, sort_keys=True))
            return 0
        previous = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
        try:
            for value in previous:
                signal.signal(value, interrupt_handler)
            return run(args)
        finally:
            for value, handler in previous.items():
                signal.signal(value, handler)
    except (ValidationError, OSError, ValueError, KeyError, TypeError) as error:
        print("environment validation rejected: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
