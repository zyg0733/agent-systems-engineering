#!/usr/bin/env python3
"""Check the bounded, non-ignored working source before its first Git import.

Uses only Python's standard library and never follows symlinks, reads Git history,
or enters ignored directories such as artifacts/, .runtime/, deps/ and _build/.
The root .gitignore is the source of truth. Its supported portable subset is
comments, simple glob components, root anchors, directory rules and negation.
Nested ignore files and advanced Git patterns fail closed rather than silently
changing the scan's scope. This is a check for known high-confidence patterns,
not a guarantee that all possible secrets or personal data have been detected.

python3 scripts/repository_check.py
python3 scripts/repository_check.py --json
python3 scripts/repository_check.py --list-files
"""

from __future__ import annotations

import argparse
from collections import Counter
import fnmatch
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit


MAX_FILES = 20_000
MAX_ENTRIES = 50_000
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_TOTAL_BYTES = 128 * 1024 * 1024
MAX_FINDINGS = 100
REQUIRED_EXCLUSIONS = ("artifacts", ".runtime", "deps", "_build", "cover")
EXAMPLE_ENV_NAMES = {".env.example", ".env.sample", ".env.template"}
PRIVATE_NAMES = {".netrc", ".pgpass", ".git-credentials", "id_rsa", "id_ed25519"}
PRIVATE_SUFFIXES = {".pem", ".key", ".p12", ".pfx"}
PRIVATE_DIRS = {".aws", ".ssh", ".codex", ".agents"}
# These are project-owned materials at exact paths. A dependency's LICENSE or a
# renamed unrelated license must not make the project's dual-license check pass.
PROJECT_LICENSE_PATHS = {"LICENSE", "LICENSE-DOCS", "NOTICE", "docs/licensing.md"}
LICENSE_TEXT_RULES = {
    "LICENSE": (10_000, (
        "apache license", "version 2.0, january 2004",
        "http://www.apache.org/licenses/", "terms and conditions for use, reproduction, and distribution",
        "1. definitions.", "2. grant of copyright license.", "3. grant of patent license.",
        "4. redistribution.", "5. submission of contributions.", "6. trademarks.",
        "7. disclaimer of warranty.", "8. limitation of liability.",
        "9. accepting warranty or additional liability.", "end of terms and conditions",
        "appendix: how to apply the apache license to your work.",
    )),
    "LICENSE-DOCS": (15_000, (
        "creative commons attribution 4.0 international public license",
        "section 1 - definitions.", "section 2 - scope.", "section 3 - license conditions.",
        "section 4 - sui generis database rights.",
        "section 5 - disclaimer of warranties and limitation of liability.",
        "section 6 - term and termination.", "section 7 - other terms and conditions.",
        "section 8 - interpretation.",
    )),
}
PRIVACY_KEYS = {
    "email", "contact_email", "phone", "phone_number", "full_name", "real_name",
    "reader_name", "participant_name", "ip_address", "hostname", "username",
}
PLACEHOLDER = re.compile(
    r"^(?:<.*>|\$\{.*\}|(?:example|sample|dummy|fake|test|redacted|placeholder)"
    r"(?:[-_ .].*)?|none|null|n/?a|localhost)$", re.IGNORECASE
)
CONTENT_RULES = {
    "private_key": re.compile(
        r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"
    ),
    "github_token": re.compile(
        r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|"
        r"github_pat_[A-Za-z0-9_]{50,})(?![A-Za-z0-9_])"
    ),
    "openai_token": re.compile(
        r"(?<![A-Za-z0-9_])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}"
        r"(?![A-Za-z0-9_-])"
    ),
    "aws_access_key": re.compile(
        r"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"
    ),
    "slack_token": re.compile(
        r"(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9-]{20,}(?![A-Za-z0-9-])"
    ),
    "user_home_path": re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+(?=/|\b)"),
}
MARKDOWN_LINK = re.compile(
    r"!?\[[^\]\n]*\]\(\s*(?:<([^>]+)>|([^\s)]+))[^\n)]*\)"
)
MARKDOWN_DEFINITION = re.compile(
    r"^\s*\[(?!\^)[^\]\n]+\]:\s*(?:<([^>]+)>|([^\s]+))", re.MULTILINE
)
PUBLIC_ENTRY_DOCS = {
    "README.md", "docs/github-onboarding.md", "docs/github-ci.md", "docs/evidence-guide.md",
}


class ScopeError(ValueError):
    pass


class IgnoreRules:
    def __init__(self, path: Path):
        self.rules = []
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not raw or raw.startswith("#"):
                continue
            if raw != raw.strip() or "\\" in raw or "**" in raw or "[" in raw:
                raise ScopeError(f"unsupported_ignore_pattern:{number}")
            negated = raw.startswith("!")
            pattern = raw[1:] if negated else raw
            anchored = pattern.startswith("/")
            directory = pattern.endswith("/")
            pattern = pattern.strip("/")
            if not pattern or any(part in {"", ".", ".."} for part in pattern.split("/")):
                raise ScopeError(f"unsupported_ignore_pattern:{number}")
            self.rules.append((pattern, anchored, directory, negated))

    def ignores(self, relative: str, directory: bool = False) -> bool:
        parts = relative.split("/")
        ignored = False
        for pattern, anchored, only_directory, negated in self.rules:
            expected = pattern.split("/")
            if anchored or len(expected) > 1:
                match = len(parts) >= len(expected) and all(
                    fnmatch.fnmatchcase(actual, wanted)
                    for actual, wanted in zip(parts, expected)
                )
                if only_directory and len(parts) == len(expected) and not directory:
                    match = False
            else:
                match = any(
                    fnmatch.fnmatchcase(part, pattern)
                    and (not only_directory or index < len(parts) - 1 or directory)
                    for index, part in enumerate(parts)
                )
            if match:
                ignored = not negated
        return ignored


def privacy_rules(value):
    """Report only field rules, never values from a possible evidence record."""
    if isinstance(value, dict):
        if value.get("reader_type") == "external_human" and value.get("completed") is True:
            yield "completed_human_feedback"
        for key, child in value.items():
            if key.lower() in PRIVACY_KEYS and isinstance(child, str) and child.strip():
                # Reserved domains and symbolic placeholders are suitable examples.
                example = PLACEHOLDER.fullmatch(child.strip()) or re.search(
                    r"@(?:example\.(?:com|org|net)|[^@]+\.invalid)$", child, re.IGNORECASE
                )
                if not example:
                    yield "private_json_field:" + key.lower()
            yield from privacy_rules(child)
    elif isinstance(value, list):
        for child in value:
            yield from privacy_rules(child)


def check_project_licenses(materials, fail):
    """Check declared materials, not legal meaning or third-party ownership.

    Inputs come only from the bounded source walk. Never open a missing, ignored,
    symlinked or unscannable license as a separate fallback.
    """
    for relative in sorted(PROJECT_LICENSE_PATHS):
        if relative not in materials:
            fail(relative, "required_project_license_missing_or_unscanned")
    for relative, (minimum_bytes, markers) in LICENSE_TEXT_RULES.items():
        if relative not in materials:
            continue
        text = materials[relative]
        normalized = " ".join(text.translate(str.maketrans({"–": "-", "—": "-"})).lower().split())
        normalized = re.sub(r"\s-+\s", " - ", normalized)
        if len(text.encode("utf-8")) < minimum_bytes or any(marker not in normalized for marker in markers):
            fail(relative, "project_license_text_incomplete_or_unexpected")

    notice = materials.get("NOTICE")
    if notice is not None:
        if not (
            "Agent Systems Lab" in notice
            and re.search(r"\bcopyright\s+(?:\(c\)\s*)?\d{4}\b|版权[^\n]*\d{4}", notice, re.IGNORECASE)
            and "Apache-2.0" in notice
            and re.search(r"CC[- ]BY[- ]4\.0", notice)
        ):
            fail("NOTICE", "project_notice_missing_identity_or_license_declaration")

    scope = materials.get("docs/licensing.md")
    if scope is not None:
        # Keep this a small completeness contract for our own scope document.
        # It deliberately does not attempt to infer license grants from prose.
        paragraphs = re.split(r"\n\s*\n", scope)
        declared = "Apache-2.0" in scope and re.search(r"CC[- ]BY[- ]4\.0", scope)
        linked = all(
            re.search(r"\]\(\s*\.\./" + re.escape(name) + r"\s*\)", scope)
            for name in ("LICENSE", "LICENSE-DOCS", "NOTICE")
        )
        code_exception = any(
            re.search(r"教材中的原创代码示例|original code examples", paragraph, re.IGNORECASE)
            and "Apache-2.0" in paragraph
            for paragraph in paragraphs
        )
        third_party = any(
            re.search(r"第三方|third.party", paragraph, re.IGNORECASE)
            and re.search(r"原有许可|原许可|original licen[cs]e", paragraph, re.IGNORECASE)
            for paragraph in paragraphs
        )
        if not (declared and linked and code_exception and third_party):
            fail("docs/licensing.md", "project_license_scope_missing_declaration_or_boundary")


def check(root: Path):
    findings = []
    warnings = []
    inventory = []
    excluded = Counter()
    local_links = Counter()
    artifact_links = Counter()
    markdown = []
    license_materials = {}
    total = 0
    visited = 0

    def fail(path, rule):
        if len(findings) < MAX_FINDINGS:
            findings.append({"path": path, "rule": rule})

    try:
        rules = IgnoreRules(root / ".gitignore")
    except (OSError, UnicodeError, ScopeError) as error:
        rule = str(error) if isinstance(error, ScopeError) else "unreadable_root_ignore"
        return {"status": "failed", "findings": [{"path": ".gitignore", "rule": rule}]}

    for name in REQUIRED_EXCLUSIONS:
        if not rules.ignores(name, directory=True):
            fail(".gitignore", "required_directory_not_ignored:" + name)

    def walk(directory):
        nonlocal total, visited
        try:
            with os.scandir(directory) as scan:
                entries = list(itertools.islice(scan, MAX_ENTRIES - visited + 1))
            visited += len(entries)
            if visited > MAX_ENTRIES:
                raise ScopeError("source_entry_count_limit")
            entries.sort(key=lambda entry: entry.name)
        except OSError:
            fail(Path(directory).relative_to(root).as_posix(), "unreadable_directory")
            return
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if relative == ".git":
                excluded[".git"] += 1
                continue
            if entry.name == ".git":
                fail(relative, "nested_git_metadata_requires_source_review")
                continue
            try:
                mode = entry.stat(follow_symlinks=False).st_mode
            except OSError:
                fail(relative, "unreadable_metadata")
                continue
            directory_entry = stat.S_ISDIR(mode)
            if rules.ignores(relative, directory_entry):
                excluded[relative.split("/")[0]] += 1
                continue
            if stat.S_ISLNK(mode):
                try:
                    target = path.resolve(strict=True)
                    target.relative_to(root)
                except (OSError, RuntimeError, ValueError):
                    fail(relative, "symlink_missing_or_outside_source")
                else:
                    fail(relative, "symlink_requires_explicit_source_review")
                continue
            if directory_entry:
                if entry.name in PRIVATE_DIRS:
                    fail(relative, "local_private_directory")
                    continue
                walk(path)
                continue
            if not stat.S_ISREG(mode):
                fail(relative, "non_regular_file")
                continue
            if entry.name == ".gitignore" and relative != ".gitignore":
                fail(relative, "nested_ignore_requires_scope_review")
            if (
                (entry.name.startswith(".env") and entry.name not in EXAMPLE_ENV_NAMES)
                or entry.name in PRIVATE_NAMES
                or path.suffix.lower() in PRIVATE_SUFFIXES
            ):
                fail(relative, "credential_filename")
            size = entry.stat(follow_symlinks=False).st_size
            total += size
            if len(inventory) >= MAX_FILES:
                raise ScopeError("source_file_count_limit")
            if total > MAX_TOTAL_BYTES:
                raise ScopeError("source_total_byte_limit")
            if size > MAX_FILE_BYTES:
                fail(relative, "file_exceeds_10_mib_scan_limit")
                inventory.append({"path": relative, "bytes": size, "sha256": None})
                continue
            try:
                # Read one extra byte to detect a file that grew after the stat.
                with path.open("rb") as stream:
                    data = stream.read(MAX_FILE_BYTES + 1)
            except OSError:
                fail(relative, "unreadable_file")
                continue
            if len(data) != size:
                fail(relative, "source_changed_during_scan")
            inventory.append({
                "path": relative, "bytes": size, "sha256": hashlib.sha256(data).hexdigest()
            })
            if len(data) > MAX_FILE_BYTES:
                fail(relative, "file_exceeds_10_mib_scan_limit")
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeError:
                fail(relative, "binary_requires_explicit_source_review")
                continue
            for name, pattern in CONTENT_RULES.items():
                if pattern.search(text):
                    fail(relative, name)
            if relative in PROJECT_LICENSE_PATHS:
                license_materials[relative] = text
            if path.suffix.lower() == ".md":
                markdown.append((path, relative, text))
            if path.suffix.lower() == ".json":
                try:
                    parsed = json.loads(text)
                    for rule in sorted(set(privacy_rules(parsed))):
                        fail(relative, rule)
                except (json.JSONDecodeError, RecursionError):
                    fail(relative, "invalid_or_excessively_nested_json")

    try:
        walk(root)
    except (ScopeError, RecursionError) as error:
        fail(".", str(error) if isinstance(error, ScopeError) else "directory_depth_limit")
    for path, relative, text in markdown:
        # Code examples deliberately contain non-links and placeholder paths.
        prose = re.sub(r"(?ms)^\s*(`{3,}|~{3,})[^\n]*\n.*?^\s*\1\s*$", "", text)
        for pattern in (MARKDOWN_LINK, MARKDOWN_DEFINITION):
            for match in pattern.finditer(prose):
                target = match[1] or match[2]
                try:
                    uri = urlsplit(target)
                except ValueError:
                    fail(relative, "invalid_markdown_link")
                    continue
                if uri.scheme or uri.netloc or not uri.path:
                    continue
                local_links["checked_local_links"] += 1
                target_path = path.parent / unquote(uri.path)
                try:
                    target_relative = target_path.resolve(strict=False).relative_to(root).as_posix()
                except (OSError, RuntimeError, ValueError):
                    fail(relative, "source_link_outside_repository")
                    continue
                if target_relative.split("/")[0] == "artifacts":
                    local_links["historical_artifact_references"] += 1
                    artifact_links[relative] += 1
                    if relative in PUBLIC_ENTRY_DOCS:
                        fail(relative, "entry_document_links_to_excluded_artifact")
                    continue
                if rules.ignores(target_relative, target_path.is_dir()):
                    local_links["other_ignored_references"] += 1
                    fail(relative, "source_link_to_ignored_path:" + target_relative)
                elif not target_path.exists():
                    local_links["missing_source_links"] += 1
                    fail(relative, "missing_source_link:" + target_relative)
    if artifact_links:
        warnings.append({"path": "docs/evidence-guide.md", "rule":
                         "historical_artifact_references_excluded:" + str(sum(artifact_links.values()))})

    # Existing index entries can override .gitignore (for example, git add -f).
    # Check their names without opening an ignored tree or reading Git history.
    git_index_count = None
    if (root / ".git").exists():
        try:
            index = subprocess.run(
                ["git", "-C", str(root), "ls-files", "--cached", "-z"],
                capture_output=True, check=True, timeout=15,
            )
            index_paths = [os.fsdecode(item) for item in index.stdout.split(b"\0") if item]
            git_index_count = len(index_paths)
            if git_index_count > MAX_FILES:
                fail(".git", "git_index_file_count_limit")
            for relative in index_paths[:MAX_FILES]:
                if rules.ignores(relative):
                    fail(relative, "ignored_path_already_in_git_index")
        except (OSError, subprocess.SubprocessError):
            fail(".git", "git_index_unreadable")
    inventory.sort(key=lambda row: row["path"])
    manifest = "".join(
        f"{row['sha256']} {row['bytes']} {row['path']}\n" for row in inventory
    )
    check_project_licenses(license_materials, fail)
    if not (root / "mix.lock").is_file() or rules.ignores("mix.lock"):
        fail("mix.lock", "required_dependency_lock_missing_or_ignored")
    return {
        "status": "failed" if findings else "passed",
        "scope": "working_source_using_root_gitignore; git_history_and_ignored_trees_not_scanned",
        "file_count": len(inventory),
        "total_bytes": total,
        "largest_file_bytes": max((row["bytes"] for row in inventory), default=0),
        "inventory_sha256": hashlib.sha256(manifest.encode("utf-8")).hexdigest(),
        "git_index_file_count": git_index_count,
        "markdown_links": dict(sorted(local_links.items())),
        "artifact_references_by_file": dict(sorted(artifact_links.items())),
        "files_by_top_level": dict(sorted(Counter(
            row["path"].split("/")[0] for row in inventory
        ).items())),
        "excluded_entries_by_top_level": dict(sorted(excluded.items())),
        "limits": {"files": MAX_FILES, "entries": MAX_ENTRIES, "file_bytes": MAX_FILE_BYTES,
                   "total_bytes": MAX_TOTAL_BYTES, "reported_findings": MAX_FINDINGS},
        "findings": findings,
        "warnings": warnings,
        "inventory": inventory,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="print a machine-readable summary")
    output.add_argument("--list-files", action="store_true", help="print paths, sizes and hashes")
    args = parser.parse_args()
    result = check(args.root.resolve())
    inventory = result.pop("inventory", [])
    if args.list_files:
        for row in inventory:
            print(json.dumps(row, ensure_ascii=False, sort_keys=True))
    elif args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print("Repository source check:", result["status"])
        print(f"Candidate files: {result.get('file_count', 0)}; bytes: {result.get('total_bytes', 0)}")
        if "inventory_sha256" in result:
            print("Inventory SHA-256:", result["inventory_sha256"])
        for kind in ("findings", "warnings"):
            for item in result.get(kind, []):
                print(f"{kind[:-1].upper()} {item['path']}: {item['rule']}")
    return 1 if result["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
