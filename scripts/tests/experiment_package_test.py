"""Test distribution boundaries against actual Git objects and mutated ZIPs."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import warnings
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("experiment_package", PROJECT / "scripts/build_experiment_package.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class ExperimentPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asl-package-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Package Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        for name in package.ROOT_FILES:
            (self.repo / name).write_bytes((PROJECT / name).read_bytes())
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/bootstrap_postgres.sh").write_text("#!/bin/sh\npg_version=18.6\n")
        (self.repo / "scripts/run").write_text("#!/bin/sh\nexit 0\n")
        (self.repo / "scripts/run").chmod(0o755)
        (self.repo / "lib").mkdir()
        (self.repo / "lib/example.ex").write_text("# committed fixture\n")
        (self.repo / "website").mkdir()
        (self.repo / "website/index.md").write_text("not in the experiment package\n")
        self.commit = self.commit_all()
        self.committed_readme = (self.repo / "README.md").read_bytes()
        self.output = self.root / "package"
        self.result = package.build(self.repo, self.commit, self.output)
        self.archive = self.output / self.result["archive"]
        self.prefix = "agent-systems-engineering-" + self.commit + "/"

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE).decode().strip()

    def commit_all(self):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def mutate(self, transform, label):
        path = self.root / (label + ".zip")
        with zipfile.ZipFile(self.archive) as archive:
            entries = [(copy.copy(info), archive.read(info)) for info in archive.infolist()]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for info, data in transform(entries):
                    archive.writestr(info, data)
        return path

    def test_byte_reproducibility_ignores_worktree_and_preserves_executable_mode(self):
        (self.repo / "README.md").write_text("uncommitted teaching edit\n")
        (self.repo / "untracked-private.txt").write_text("not source\n")
        second = package.build(self.repo, self.commit, self.root / "second")
        self.assertEqual(self.archive.read_bytes(), (self.root / "second" / second["archive"]).read_bytes())
        result = package.verify(self.archive, repo=self.repo, extract=self.root / "extract", checksum_file=self.output / "SHA256SUMS")
        extracted = Path(result["extracted_to"])
        self.assertEqual((extracted / "scripts/run").stat().st_mode & 0o777, 0o755)
        self.assertEqual((extracted / "README.md").read_bytes(), self.committed_readme)
        self.assertFalse((extracted / "website").exists())
        self.assertFalse((extracted / "untracked-private.txt").exists())
        self.assertTrue(result["git_source_compared"])

    def test_content_missing_extra_duplicate_and_mode_changes_rejected_before_extraction(self):
        def alter(entries):
            return [(info, b"changed\n" if info.filename.endswith("/lib/example.ex") else data) for info, data in entries]
        def missing(entries):
            return [(info, data) for info, data in entries if not info.filename.endswith("/lib/example.ex")]
        def extra(entries):
            return entries + [(package.zip_info(self.prefix + "lib/extra.ex", "100644"), b"extra\n")]
        def duplicate(entries):
            return entries + [entries[0]]
        def mode(entries):
            for info, _ in entries:
                if info.filename.endswith("/lib/example.ex"):
                    info.external_attr = 0o100755 << 16
            return entries
        for label, transform in {"changed": alter, "missing": missing, "extra": extra, "duplicate": duplicate, "mode": mode}.items():
            with self.subTest(label=label):
                archive = self.mutate(transform, label)
                extract = self.root / (label + "-extraction")
                with self.assertRaises(package.PackageError):
                    package.verify(archive, extract=extract)
                self.assertFalse(extract.exists())

    def test_traversal_symlink_and_unexpected_scope_rejected(self):
        for label, name, mode in [
            ("traversal", self.prefix + "../escape", "100644"),
            ("absolute", "/escape", "100644"),
            ("symlink", self.prefix + "lib/linked.ex", "120777"),
            ("runtime", self.prefix + "lib/.runtime/data", "100644"),
            ("website", self.prefix + "website/index.md", "100644"),
        ]:
            with self.subTest(label=label):
                archive = self.mutate(lambda entries: entries + [(package.zip_info(name, mode), b"target")], label)
                with self.assertRaises(package.PackageError):
                    package.verify(archive)

    def test_manifest_keys_and_generated_instructions_are_checked(self):
        for label, filename, content in [
            ("duplicate-json", package.GENERATED_MANIFEST, b'{"source_commit":"x","source_commit":"y"}'),
            ("array-json", package.GENERATED_MANIFEST, b"[]"),
            ("instructions", package.GENERATED_README, b"unreviewed execution instructions\n"),
        ]:
            with self.subTest(label=label):
                archive = self.mutate(lambda entries: [(info, content if info.filename.endswith("/" + filename) else data) for info, data in entries], label)
                with self.assertRaises(package.PackageError):
                    package.verify(archive)

    def test_external_checksum_and_unindexed_bytes_rejected(self):
        (self.root / "wrong-checksum").write_text("0" * 64 + "  " + self.archive.name + "\n")
        with self.assertRaisesRegex(package.PackageError, "external archive checksum"):
            package.verify(self.archive, checksum_file=self.root / "wrong-checksum")
        for label, data in [("prefix", b"unindexed" + self.archive.read_bytes()), ("suffix", self.archive.read_bytes() + b"unindexed")]:
            target = self.root / (label + ".zip")
            target.write_bytes(data)
            with self.subTest(label=label), self.assertRaises(package.PackageError):
                package.verify(target)

    def test_integrity_without_git_does_not_authenticate_claimed_commit(self):
        (self.repo / "lib/example.ex").write_text("# a different committed source\n")
        new_commit = self.commit_all()
        _, new_tree, _ = package.read_commit(self.repo, new_commit)
        _, _, old_files = package.read_commit(self.repo, self.commit)
        false_claim = package.manifest_for(new_commit, new_tree, old_files)
        forged = self.root / "self-consistent-false-claim.zip"
        with zipfile.ZipFile(forged, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
            package.write_archive(archive, "agent-systems-engineering-" + new_commit, old_files, false_claim)
        self.assertFalse(package.verify(forged)["git_source_compared"])
        with self.assertRaisesRegex(package.PackageError, "does not match Git commit"):
            package.verify(forged, repo=self.repo)

    def test_local_git_replace_cannot_change_the_named_source_commit(self):
        (self.repo / "lib/example.ex").write_text("# replacement source\n")
        replacement = self.commit_all()
        self.git("replace", self.commit, replacement)
        self.assertIn("replacement source", self.git("show", self.commit + ":lib/example.ex"))
        result = package.build(self.repo, self.commit, self.root / "with-replace")
        self.assertEqual(result["source_commit"], self.commit)
        self.assertEqual(result["archive_sha256"], self.result["archive_sha256"])
        self.assertTrue(package.verify(self.archive, repo=self.repo)["git_source_compared"])

    def test_git_scope_rejects_unknown_paths_symlinks_and_credential_signatures(self):
        for label in ["unknown", "symlink", "credential"]:
            with self.subTest(label=label):
                self.git("reset", "--hard", self.commit)
                self.git("clean", "-fd")
                if label == "unknown":
                    (self.repo / "unreviewed.txt").write_text("unreviewed scope\n")
                elif label == "symlink":
                    (self.repo / "lib/link.ex").symlink_to("../README.md")
                else:
                    (self.repo / "lib/secret.ex").write_text("gh" + "p_" + "a" * 36)
                target = self.root / (label + "-build")
                with self.assertRaises(package.PackageError):
                    package.build(self.repo, self.commit_all(), target)
                self.assertFalse(target.exists())

    def test_existing_outputs_are_never_overwritten(self):
        with self.assertRaisesRegex(package.PackageError, "output directory must be new"):
            package.build(self.repo, self.commit, self.output)
        destination = self.root / "existing"
        destination.mkdir()
        sentinel = destination / "sentinel"
        sentinel.write_text("retain\n")
        with self.assertRaisesRegex(package.PackageError, "extraction directory must be new"):
            package.verify(self.archive, extract=destination)
        self.assertEqual(sentinel.read_text(), "retain\n")


if __name__ == "__main__":
    unittest.main()
