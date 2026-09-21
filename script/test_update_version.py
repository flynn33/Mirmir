#!/usr/bin/env python3
"""Tests for repository version synchronization."""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

from update_version import (
    VersionError,
    check_repository,
    increment_version,
    parse_build_number,
    parse_version,
    set_repository_build,
    set_repository_version,
)


class IncrementVersionTests(unittest.TestCase):
    def test_increment_rules(self) -> None:
        expectations = {
            "release": "2.0.0",
            "feature-release": "1.3.0",
            "patch/hotfix": "1.2.4",
            "none": "1.2.3",
        }
        for bump, expected in expectations.items():
            with self.subTest(bump=bump):
                self.assertEqual(increment_version("1.2.3", bump), expected)

    def test_rejects_malformed_versions(self) -> None:
        for value in ("1", "1.2", "1.2.3.4", "v1.2.3", "01.2.3", "1.-2.3"):
            with self.subTest(value=value), self.assertRaises(VersionError):
                parse_version(value)

    def test_rejects_unknown_increment(self) -> None:
        with self.assertRaises(VersionError):
            increment_version("1.2.3", "other")

    def test_build_number_rules(self) -> None:
        self.assertEqual(parse_build_number("3"), 3)
        for value in ("", "0", "-1", "01", "1.0", "build-3"):
            with self.subTest(value=value), self.assertRaises(VersionError):
                parse_build_number(value)


class RepositoryVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "Mirmir.xcodeproj").mkdir()
        (self.root / "Mirmir").mkdir()
        (self.root / "VERSION").write_text("1.2.3\n", encoding="utf-8")
        (self.root / "BUILD_NUMBER").write_text("7\n", encoding="utf-8")
        (self.root / "Mirmir.xcodeproj" / "project.pbxproj").write_text(
            "\t\tCURRENT_PROJECT_VERSION = 7;\n"
            "    CURRENT_PROJECT_VERSION = 7;\n"
            "\t\tMARKETING_VERSION = 1.2.3;\n"
            "    MARKETING_VERSION = 1.2.3;\n",
            encoding="utf-8",
        )
        with (self.root / "Mirmir" / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                },
                stream,
            )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_updates_every_version_location(self) -> None:
        self.assertEqual(set_repository_version(self.root, "2.0.0"), "2.0.0")
        self.assertEqual(
            (self.root / "VERSION").read_text(encoding="utf-8"), "2.0.0\n"
        )
        project = (
            self.root / "Mirmir.xcodeproj" / "project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertEqual(project.count("MARKETING_VERSION = 2.0.0;"), 2)
        self.assertEqual(project.count("CURRENT_PROJECT_VERSION = 7;"), 2)

    def test_updates_every_build_location(self) -> None:
        self.assertEqual(set_repository_build(self.root, "8"), "8")
        self.assertEqual(
            (self.root / "BUILD_NUMBER").read_text(encoding="utf-8"), "8\n"
        )
        project = (
            self.root / "Mirmir.xcodeproj" / "project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertEqual(project.count("CURRENT_PROJECT_VERSION = 8;"), 2)

    def test_check_rejects_project_drift(self) -> None:
        project_path = self.root / "Mirmir.xcodeproj" / "project.pbxproj"
        project_path.write_text(
            project_path.read_text(encoding="utf-8").replace("1.2.3", "1.2.4", 1),
            encoding="utf-8",
        )
        with self.assertRaises(VersionError):
            check_repository(self.root)

    def test_check_rejects_build_drift(self) -> None:
        project_path = self.root / "Mirmir.xcodeproj" / "project.pbxproj"
        project_path.write_text(
            project_path.read_text(encoding="utf-8").replace(
                "CURRENT_PROJECT_VERSION = 7;",
                "CURRENT_PROJECT_VERSION = 8;",
                1,
            ),
            encoding="utf-8",
        )
        with self.assertRaises(VersionError):
            check_repository(self.root)

    def test_check_rejects_literal_bundle_version(self) -> None:
        info_path = self.root / "Mirmir" / "Info.plist"
        with info_path.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                },
                stream,
            )
        with self.assertRaises(VersionError):
            check_repository(self.root)


if __name__ == "__main__":
    unittest.main()
