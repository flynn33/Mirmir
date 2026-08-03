#!/usr/bin/env python3
"""Tests for exact release-candidate identity derivation."""

from __future__ import annotations

import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "prepare_release_candidate_v4",
    SCRIPT_DIRECTORY / "prepare_release_candidate_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class ReleaseCandidateTests(unittest.TestCase):
    def make_archive(self, path: Path, *, identifier: str = "com.mirmir.app") -> None:
        info = plistlib.dumps(
            {
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": "1.2.0",
                "CFBundleVersion": "2",
            }
        )
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Mirmir.app/Contents/Info.plist", info)
            archive.writestr("Mirmir.app/Contents/MacOS/Mirmir", b"executable")

    def test_application_identity_comes_from_archive_bytes_and_plist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "Mirmir.zip"
            self.make_archive(archive)
            identity = candidate.application_identity(archive)
            self.assertEqual(identity["bundleIdentifier"], "com.mirmir.app")
            self.assertEqual(identity["productVersion"], "1.2.0")
            self.assertEqual(identity["productBuild"], "2")
            self.assertEqual(identity["appBundleSHA256"], candidate.p06.sha256(archive))

    def test_archive_path_escape_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as value:
                value.writestr("../Mirmir.app/Contents/Info.plist", b"invalid")
            with self.assertRaisesRegex(candidate.CandidateError, "unsafe path"):
                candidate.application_identity(archive)

    def test_archive_requires_exactly_one_top_level_application(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "two-apps.zip"
            info = plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.mirmir.app",
                    "CFBundleShortVersionString": "1.2.0",
                    "CFBundleVersion": "2",
                }
            )
            with zipfile.ZipFile(archive, "w") as value:
                value.writestr("First.app/Contents/Info.plist", info)
                value.writestr("Second.app/Contents/Info.plist", info)
            with self.assertRaisesRegex(candidate.CandidateError, "exactly one"):
                candidate.application_identity(archive)


if __name__ == "__main__":
    unittest.main()
