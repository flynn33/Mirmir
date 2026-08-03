#!/usr/bin/env python3
"""Unit tests for P06 clean-build evidence helpers."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "capture_p06_reproduction_v4",
    SCRIPT_DIRECTORY / "capture_p06_reproduction_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class P06ReproductionCaptureTests(unittest.TestCase):
    def test_artifact_set_is_order_independent_and_path_sensitive(self) -> None:
        first = capture.artifact_set_sha([("b", "2" * 64), ("a", "1" * 64)])
        second = capture.artifact_set_sha([("a", "1" * 64), ("b", "2" * 64)])
        moved = capture.artifact_set_sha([("a", "1" * 64), ("c", "2" * 64)])
        self.assertEqual(first, second)
        self.assertNotEqual(first, moved)

    def test_source_tree_identity_changes_with_committed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.name", "P06 Test"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.email", "p06-test@example.invalid"],
                cwd=repository,
                check=True,
            )
            source = repository / "source.txt"
            source.write_text("first\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.txt"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "first"], cwd=repository, check=True)
            first_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()
            first = capture.source_tree_identity(repository, first_commit)
            source.write_text("second\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "second"], cwd=repository, check=True)
            second_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()
            second = capture.source_tree_identity(repository, second_commit)
            self.assertRegex(first, r"^[0-9a-f]{64}$")
            self.assertNotEqual(first, second)

    def test_candidate_parser_rejects_missing_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.json"
            path.write_text(json.dumps({"sourceCommit": "a" * 40}), encoding="utf-8")
            with self.assertRaisesRegex(capture.CaptureError, "field set mismatch"):
                capture.parse_candidate(path)


if __name__ == "__main__":
    unittest.main()
