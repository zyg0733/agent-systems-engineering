#!/usr/bin/env python3
"""Build and verify a deterministic, source-only teaching package from Git.

Python standard library only. No exported code is executed. This is separate
from the historical lab.reproduce / frozen release contracts.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import unicodedata
import zipfile


ROOT_FILES = frozenset({
    ".gitattributes", ".formatter.exs", ".gitignore", ".tool-versions",
    "README.md", "LICENSE", "LICENSE-DOCS", "NOTICE", "mix.exs", "mix.lock",
    "Agent Systems Engineering 研究与落地计划.md",
})
SOURCE_DIRECTORIES = frozenset({
    ".github", "book", "config", "docs", "fixtures", "labs", "lib", "priv", "scripts", "test",
})
FORBIDDEN_COMPONENTS = frozenset({
    ".git", ".runtime", "artifacts", "node_modules", "deps", "_build", "cover",
    ".aws", ".ssh", ".codex", ".agents", ".venv", "__pycache__",
})
PRIVATE_NAMES = frozenset({".netrc", ".pgpass", ".git-credentials", "id_rsa", "id_ed25519"})
PRIVATE_SUFFIXES = frozenset({".pem", ".key", ".p12", ".pfx", ".local", ".pyc"})
GENERATED_MANIFEST = "EXPERIMENT-PACKAGE.json"
GENERATED_README = "PACKAGE-README.txt"
MAX_FILES = 10_000
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_BYTES = 72 * 1024 * 1024
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
OBJECT_ID = re.compile(r"(?:[a-f0-9]{40}|[a-f0-9]{64})\Z")
SECRET_RULES = {
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "github_token": re.compile(rb"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})(?![A-Za-z0-9_])"),
    "openai_token": re.compile(rb"(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"),
    "aws_access_key": re.compile(rb"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),
}


class PackageError(ValueError):
    pass


def canonical_json(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *arguments, input_data=None):
    result = subprocess.run(
        ["git", "--no-replace-objects", "-C", str(repo), *arguments], input=input_data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise PackageError("git operation failed: " + arguments[0])
    return result.stdout


def safe_relative(name):
    if not isinstance(name, str) or not name or "\\" in name or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise PackageError("invalid package path")
    parts = name.split("/")
    if any(part in {"", ".", ".."} or part.endswith((".", " ")) or ":" in part for part in parts):
        raise PackageError("non-canonical package path")
    if PurePosixPath(name).is_absolute():
        raise PackageError("absolute package path")
    for part in parts:
        if re.fullmatch(r"(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?", part):
            raise PackageError("non-portable package path")
    return parts


def source_path(name):
    parts = safe_relative(name)
    if any(part in FORBIDDEN_COMPONENTS or part in PRIVATE_NAMES for part in parts):
        raise PackageError("forbidden source path: " + name)
    if any(part.startswith(".env") and part not in {".env.example", ".env.sample", ".env.template"} for part in parts):
        raise PackageError("private environment path: " + name)
    if any(Path(part).suffix.lower() in PRIVATE_SUFFIXES for part in parts):
        raise PackageError("private/cache source path: " + name)
    if name in ROOT_FILES or (len(parts) > 1 and parts[0] in SOURCE_DIRECTORIES):
        return True
    if parts[0] == "website":
        return False
    raise PackageError("unreviewed source scope: " + name)


def check_source(files):
    if not ROOT_FILES.issubset(files):
        raise PackageError("required root source/notice files are missing")
    if not 0 < len(files) <= MAX_FILES or sum(len(data) for _, data in files.values()) > MAX_TOTAL_BYTES:
        raise PackageError("source inventory exceeds bounds")
    normalized = set()
    for name, (mode, data) in files.items():
        if not source_path(name):
            raise PackageError("website is outside experiment scope")
        key = unicodedata.normalize("NFC", name).casefold()
        if key in normalized:
            raise PackageError("case/Unicode colliding source paths")
        normalized.add(key)
        if mode not in {"100644", "100755"} or len(data) > MAX_FILE_BYTES:
            raise PackageError("unsupported source file mode or size: " + name)
        for rule, pattern in SECRET_RULES.items():
            if pattern.search(data):
                # Never put matched bytes into an error or output artifact.
                raise PackageError("credential signature " + rule + " in " + name)


def read_commit(repo, revision):
    if not revision or revision.startswith("-") or any(ord(c) < 32 for c in revision):
        raise PackageError("invalid Git revision")
    commit = git(repo, "rev-parse", "--verify", revision + "^{commit}").decode().strip()
    tree = git(repo, "rev-parse", "--verify", commit + "^{tree}").decode().strip()
    if not OBJECT_ID.fullmatch(commit) or not OBJECT_ID.fullmatch(tree):
        raise PackageError("unsupported Git object identity")
    listing = git(repo, "ls-tree", "-rz", "--full-tree", commit)
    entries = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        metadata, name_bytes = record.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split(" ")
        name = name_bytes.decode("utf-8")
        if not source_path(name):
            continue
        if mode not in {"100644", "100755"} or kind != "blob":
            raise PackageError("source symlink/submodule/non-file rejected: " + name)
        entries.append((name, mode, oid))
    if len(entries) > MAX_FILES:
        raise PackageError("too many source entries")
    # Ask Git for sizes first so a large committed blob is not buffered blindly.
    query = "".join(oid + "\n" for _, _, oid in entries).encode("ascii")
    checks = git(repo, "cat-file", "--batch-check", input_data=query).splitlines()
    sizes = []
    for line in checks:
        _, kind, size = line.split()
        if kind != b"blob" or int(size) > MAX_FILE_BYTES:
            raise PackageError("source object exceeds supported size/type")
        sizes.append(int(size))
    if len(sizes) != len(entries) or sum(sizes) > MAX_TOTAL_BYTES:
        raise PackageError("source inventory exceeds supported size")
    packed = git(repo, "cat-file", "--batch", input_data=query)
    cursor = 0
    files = {}
    for (name, mode, oid), size in zip(entries, sizes):
        newline = packed.find(b"\n", cursor)
        if newline < 0 or packed[cursor:newline] != f"{oid} blob {size}".encode():
            raise PackageError("unexpected Git object stream")
        cursor = newline + 1
        data = packed[cursor:cursor + size]
        cursor += size
        if packed[cursor:cursor + 1] != b"\n":
            raise PackageError("truncated Git object stream")
        cursor += 1
        files[name] = (mode, data)
    if cursor != len(packed):
        raise PackageError("unexpected trailing Git objects")
    check_source(files)
    return commit, tree, files


def manifest_for(commit, tree, files):
    versions = dict(line.split(maxsplit=1) for line in files[".tool-versions"][1].decode().splitlines() if line.strip())
    pg = files.get("scripts/bootstrap_postgres.sh", ("", b""))[1]
    match = re.search(rb"^pg_version=([0-9.]+)$", pg, re.MULTILINE)
    version = re.search(rb'version:\s*"([^"]+)"', files["mix.exs"][1])
    if set(versions) != {"erlang", "elixir"} or match is None or version is None:
        raise PackageError("cannot identify pinned teaching toolchain/version")
    rows = [{"path": name, "mode": mode, "size": len(data), "sha256": sha256(data)} for name, (mode, data) in sorted(files.items())]
    return {
        "schema_version": 1,
        "kind": "agent-systems-engineering.experiment-source.v1",
        "source_commit": commit,
        "source_tree": tree,
        "project_version": version.group(1).decode(),
        "release_status": "teaching-draft-source; not a formal software release",
        "scope": {"root_files": sorted(ROOT_FILES), "directories": sorted(SOURCE_DIRECTORIES),
                  "excluded": ["website", ".git", "runtime/dependency caches", "database state", "historical artifacts", "third-party binaries"]},
        "toolchain": {**versions, "postgresql": match.group(1).decode(), "dependencies": "mix.lock"},
        "execution": {"provider": "Scripted/Recorded and controlled tools; no real model credentials",
                      "first_install_requires_network": True,
                      "linux": "core only; Seatbelt cases excluded",
                      "macos": "declared Seatbelt teaching backend; no cold-machine certification"},
        "integrity_scope": "SHA256 detects changes; trust the distributor/checksum channel. --repo additionally binds source bytes to Git commit.",
        "file_count": len(rows), "total_bytes": sum(row["size"] for row in rows),
        "entries_sha256": sha256(canonical_json(rows)), "entries": rows,
    }


def package_readme(manifest):
    return f"""Agent Systems Engineering — 固定版本实验源码包

源码 commit：{manifest['source_commit']}
源码 tree：{manifest['source_tree']}
软件版本：{manifest['project_version']}（教学草稿；不是正式软件发行）

本目录为项目根目录，不含 Git 历史、website/、运行时、第三方依赖、缓存、
数据库或作者历史 artifacts。EXPERIMENT-PACKAGE.json 逐项记录源码 SHA256、
字节数和 Git 文件权限；PACKAGE-README.txt 与清单为打包器生成的附加说明。
源码 commit 字段本身不是签名；先从可信渠道核对包外 SHA256SUMS。
包内文件校验也不证明程序安全。使用取得授权的材料及自己的实验资源。

工具链以 .tool-versions、scripts/bootstrap_postgres.sh 和 mix.lock 为准：
Elixir {manifest['toolchain']['elixir']} / OTP {manifest['toolchain']['erlang']} / PostgreSQL {manifest['toolchain']['postgresql']}。
第一次安装运行时、Hex 和锁定依赖需要联网；安装后适用实验使用固定
Scripted/Recorded Provider、Mock 与受控工具，不需要真实模型密钥。

macOS：先读 README.md 和 docs/cross-environment-validation.md，在本目录运行：
  sh scripts/bootstrap_runtime.sh
  MIX_ENV=dev ./scripts/mix local.hex --force
  MIX_ENV=dev ./scripts/mix deps.get --check-locked
  MIX_ENV=dev LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.demo
预期末两行为：
  status=succeeded turns=2 requests=1 effects=1
  rebuild_matches=true (in-memory history; no durable storage)

Linux：按 docs/linux-core-start.md 准备固定工具链，再执行同一内存演示。
Linux core 不包含完整 Seatbelt 隔离；macOS 脚本不要作为 Linux 安装器。
接着按 labs/L01-state-machine.md 学习，再进入对应平台适用的后续实验。
持久化实验需专属 PostgreSQL，详见 README.md；本包不启动或修改数据库。

README 中阅读站/Node 构建段落适用于完整 Git 克隆，本实验包不包含该工具链。
文档中的历史结果保留原来身份，不是本包本次执行结果；源码链接和反馈
按 docs/material-access.md 与当前提供材料的维护者说明使用。
代码/教材许可范围见 LICENSE、LICENSE-DOCS、NOTICE 和 docs/licensing.md。
""".encode("utf-8")


def zip_info(name, mode):
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.create_system = 3
    info.external_attr = int(mode, 8) << 16
    info.compress_type = zipfile.ZIP_STORED
    return info


def write_archive(stream, folder, files, manifest):
    for name, (mode, data) in sorted(files.items()):
        stream.writestr(zip_info(folder + "/" + name, mode), data)
    stream.writestr(zip_info(folder + "/" + GENERATED_MANIFEST, "100644"), canonical_json(manifest))
    stream.writestr(zip_info(folder + "/" + GENERATED_README, "100644"), package_readme(manifest))


def build(repo, revision, output):
    commit, tree, files = read_commit(repo, revision)
    manifest = manifest_for(commit, tree, files)
    folder = "agent-systems-engineering-" + commit
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise PackageError("output directory must be new")
    output.mkdir(parents=True, mode=0o700)
    archive = output / (folder + ".zip")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_STORED, allowZip64=False) as stream:
        write_archive(stream, folder, files, manifest)
    checksum = sha256(archive.read_bytes())
    (output / "SHA256SUMS").write_text(checksum + "  " + archive.name + "\n", encoding="utf-8")
    result = {"status": "built", "source_commit": commit, "source_tree": tree,
              "archive": archive.name, "archive_sha256": checksum,
              "source_file_count": len(files), "source_entries_sha256": manifest["entries_sha256"],
              "scope": "source-only teaching draft; fixed Git commit; excludes website tooling and installed dependencies"}
    (output / "package-summary.json").write_bytes(canonical_json(result))
    verify(archive, repo=repo)
    return result


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PackageError("duplicate manifest key")
        result[key] = value
    return result


def verify(archive, repo=None, extract=None, checksum_file=None):
    archive = Path(archive).resolve(strict=True)
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise PackageError("archive exceeds size limit")
    archive_sha = sha256(archive.read_bytes())
    if checksum_file is not None:
        expected = Path(checksum_file).read_text(encoding="utf-8")
        if expected != archive_sha + "  " + archive.name + "\n":
            raise PackageError("external archive checksum mismatch")
    contents = {}
    with zipfile.ZipFile(archive) as stream:
        infos = stream.infolist()
        if not 2 < len(infos) <= MAX_FILES + 2 or stream.comment or sum(info.file_size for info in infos) > MAX_TOTAL_BYTES + 8 * 1024 * 1024:
            raise PackageError("archive inventory exceeds bounds or has a comment")
        folder = None
        for info in infos:
            parts = safe_relative(info.filename)
            if len(parts) < 2 or info.filename in contents:
                raise PackageError("duplicate or rootless ZIP entry")
            if folder is None:
                folder = parts[0]
            if parts[0] != folder:
                raise PackageError("multiple archive roots")
            mode = info.external_attr >> 16
            if (mode not in {0o100644, 0o100755} or info.create_system != 3 or info.is_dir()
                    or info.flag_bits & 1 or info.compress_type != zipfile.ZIP_STORED
                    or info.file_size > MAX_FILE_BYTES or info.date_time != FIXED_ZIP_TIME
                    or info.extra or info.comment):
                raise PackageError("unsupported ZIP entry mode/encoding/size")
            contents[info.filename] = (format(mode, "06o"), stream.read(info))
    manifest_key = folder + "/" + GENERATED_MANIFEST
    readme_key = folder + "/" + GENERATED_README
    if manifest_key not in contents or readme_key not in contents:
        raise PackageError("package metadata missing")
    manifest = json.loads(contents[manifest_key][1], object_pairs_hook=unique_object)
    if not isinstance(manifest, dict):
        raise PackageError("manifest must be an object")
    commit, tree = manifest.get("source_commit", ""), manifest.get("source_tree", "")
    if not isinstance(commit, str) or not isinstance(tree, str) or not OBJECT_ID.fullmatch(commit) or not OBJECT_ID.fullmatch(tree):
        raise PackageError("invalid source identity")
    if folder != "agent-systems-engineering-" + commit:
        raise PackageError("archive root does not match commit")
    files = {name[len(folder) + 1:]: item for name, item in contents.items() if name not in {manifest_key, readme_key}}
    check_source(files)
    expected_manifest = manifest_for(commit, tree, files)
    if contents[manifest_key] != ("100644", canonical_json(expected_manifest)):
        raise PackageError("source manifest mismatch")
    if contents[readme_key] != ("100644", package_readme(expected_manifest)):
        raise PackageError("package usage instructions mismatch")
    # Reject unindexed prefixes, appended ZIPs and other hidden bytes as well as
    # visible entries. ZIP_STORED and fixed metadata make this portable.
    canonical = io.BytesIO()
    with zipfile.ZipFile(canonical, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as stream:
        write_archive(stream, folder, files, expected_manifest)
    if sha256(canonical.getvalue()) != archive_sha:
        raise PackageError("non-canonical ZIP encoding or unindexed bytes")
    if repo is not None:
        actual_commit, actual_tree, actual_files = read_commit(repo, commit)
        if actual_commit != commit or actual_tree != tree or actual_files != files:
            raise PackageError("package does not match Git commit")
    if extract is not None:
        destination = Path(extract).absolute()
        if destination.exists() or destination.is_symlink():
            raise PackageError("extraction directory must be new")
        # Validate the entire package before making any extraction directory.
        destination.mkdir(parents=True, mode=0o700)
        for name, (mode, data) in sorted(contents.items()):
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                os.fchmod(stream.fileno(), int(mode, 8) & 0o777)
    return {"status": "verified", "source_commit": commit, "source_tree": tree,
            "archive_sha256": archive_sha, "source_file_count": len(files),
            "source_entries_sha256": manifest["entries_sha256"], "git_source_compared": repo is not None,
            "external_checksum_compared": checksum_file is not None,
            "extracted_to": str(Path(extract).absolute() / folder) if extract is not None else None}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build", help="read committed source and create a new package directory")
    builder.add_argument("--repo", default=".")
    builder.add_argument("--commit", required=True)
    builder.add_argument("--output", required=True)
    checker = commands.add_parser("verify", help="validate all entries before optional safe extraction")
    checker.add_argument("--archive", required=True)
    checker.add_argument("--repo", help="also compare with the claimed source commit")
    checker.add_argument("--checksum-file", help="compare the exact single-entry SHA256SUMS")
    checker.add_argument("--extract", help="new owned directory; no concurrent writers")
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            result = build(args.repo, args.commit, args.output)
        else:
            result = verify(args.archive, repo=args.repo, extract=args.extract, checksum_file=args.checksum_file)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (PackageError, OSError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile, ValueError, KeyError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
