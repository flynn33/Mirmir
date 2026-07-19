from __future__ import annotations

import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock
from urllib import error as urlerror


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from roadmap_alignment import (  # noqa: E402
    AlignmentVerifier,
    compare_github_metadata,
    fetch_github_metadata,
)


class RoadmapAlignmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.policy = json.loads(
            (REPOSITORY_ROOT / ".github/roadmap-alignment-policy.json").read_text(
                encoding="utf-8"
            )
        )
        paths = {
            ".github/roadmap-alignment-policy.json",
            self.policy["canonical"]["markdown_path"],
            self.policy["canonical"]["json_path"],
            self.policy["canonical"]["index_path"],
            self.policy["readme"]["path"],
            self.policy["forsetti"]["project_path"],
            self.policy["forsetti"]["generated_project_path"],
            self.policy["r00_inventory"]["json_path"],
        }
        paths.update(self.policy["required_phrases"])
        workflow_root = REPOSITORY_ROOT / self.policy["workflows"]["root"]
        paths.update(
            path.relative_to(REPOSITORY_ROOT).as_posix()
            for path in workflow_root.rglob("*")
            if path.is_file()
        )
        for relative in sorted(paths):
            source = REPOSITORY_ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def verifier(self) -> AlignmentVerifier:
        return AlignmentVerifier(self.root)

    def errors(self) -> list[str]:
        return self.verifier().check()

    def assert_error_contains(self, fragment: str) -> None:
        errors = self.errors()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    def roadmap_json(self) -> tuple[Path, dict[str, object]]:
        path = self.root / self.policy["canonical"]["json_path"]
        return path, json.loads(path.read_text(encoding="utf-8"))

    def set_r00_status(self, status: str) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["status"] = status
        self.write_json(path, roadmap)

    def remove_forsetti_project_declarations(self) -> None:
        for relative in (
            self.policy["forsetti"]["project_path"],
            self.policy["forsetti"]["generated_project_path"],
        ):
            (self.root / relative).write_text("// dependency-free\n", encoding="utf-8")

    @staticmethod
    def write_json(path: Path, value: dict[str, object]) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def test_repository_fixture_is_aligned(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_canonical_markdown_hash_drift_fails(self) -> None:
        path = self.root / self.policy["canonical"]["markdown_path"]
        path.write_text(path.read_text(encoding="utf-8") + "drift\n", encoding="utf-8")
        self.assert_error_contains("SHA-256 differs")

    def test_stale_policy_hash_fails(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        policy["canonical"]["json_sha256"] = "0" * 64
        self.write_json(policy_path, policy)
        self.assert_error_contains("SHA-256 differs")

    def test_canonical_markdown_status_drift_fails(self) -> None:
        path = self.root / self.policy["canonical"]["markdown_path"]
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "**Status:** `in_progress`", "**Status:** `next`", 1
            ),
            encoding="utf-8",
        )
        self.assert_error_contains("Markdown status differs")

    def test_status_document_drift_fails(self) -> None:
        path = self.root / "local-work-plan.md"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Roadmap phase `R00`: `in_progress`",
                "Roadmap phase `R00`: `next`",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_error_contains("phase status text differs")

    def test_progress_drift_fails_and_writer_repairs_it(self) -> None:
        readme = self.root / self.policy["readme"]["path"]
        text = readme.read_text(encoding="utf-8")
        text = text.replace("🔄 In progress `1`", "🔄 In progress `2`", 1)
        readme.write_text(text, encoding="utf-8")
        self.assert_error_contains("Roadmap Progress block is stale")
        self.verifier().write_progress()
        self.assertEqual(self.errors(), [])

    def test_authorization_drift_fails(self) -> None:
        path, roadmap = self.roadmap_json()
        authorizations = roadmap["authorizations"]
        self.assertIsInstance(authorizations, dict)
        authorizations["holdout"] = "authorized"
        self.write_json(path, roadmap)
        self.assert_error_contains("authorizations differ")

    def test_dependency_cycle_fails(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["depends_on"] = ["R01"]
        self.write_json(path, roadmap)
        self.assert_error_contains("dependency cycle detected")

    def test_active_phase_requires_passed_dependencies(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[1]["status"] = "in_progress"
        self.write_json(path, roadmap)
        self.assert_error_contains("before dependency R00 is passed")

    def test_forsetti_dependency_expansion_fails(self) -> None:
        project = self.root / self.policy["forsetti"]["project_path"]
        project.write_text(
            project.read_text(encoding="utf-8")
            + "\n# invalid second coordinate\n"
            + "url: https://example.com/Forsetti-Framework-Mac-iOS.git\n",
            encoding="utf-8",
        )
        self.assert_error_contains("additional or alternate Forsetti URL")

    def test_r00_passed_requires_dependency_removal(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["status"] = "passed"
        self.write_json(path, roadmap)
        self.assert_error_contains("dependency remains after R00")

    def test_r00_in_progress_rejects_partial_dependency_migration(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["status"] = "in_progress"
        self.write_json(path, roadmap)
        project = self.root / self.policy["forsetti"]["project_path"]
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                self.policy["forsetti"]["allowed_revision"],
                "0" * 40,
                1,
            ),
            encoding="utf-8",
        )
        self.assert_error_contains("neither the exact legacy pin nor complete dependency removal")

    def test_r00_evidence_ready_requires_dependency_removal(self) -> None:
        self.set_r00_status("evidence_ready")
        self.assert_error_contains("dependency remains after R00")

    def test_alternate_package_swift_declaration_fails(self) -> None:
        self.set_r00_status("passed")
        self.remove_forsetti_project_declarations()
        package = self.root / "Package.swift"
        package.write_text(
            '.package(url: "https://example.com/forsetti.git", branch: "main")\n',
            encoding="utf-8",
        )
        self.assert_error_contains("repository coordinate remains")

    def test_package_resolved_identity_fails(self) -> None:
        self.set_r00_status("passed")
        self.remove_forsetti_project_declarations()
        resolved = self.root / "Package.resolved"
        resolved.write_text(
            '{"pins":[{"identity":"forsetti-framework-mac-ios"}]}\n',
            encoding="utf-8",
        )
        self.assert_error_contains("dependency declaration remains")

    def test_decorated_forsetti_import_fails(self) -> None:
        self.set_r00_status("passed")
        self.remove_forsetti_project_declarations()
        source = self.root / "Mirmir/DecoratedImport.swift"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(
            "@_implementationOnly import ForsettiCore\n",
            encoding="utf-8",
        )
        self.assert_error_contains("package import remains")

    def test_vendored_forsetti_path_fails(self) -> None:
        vendored = self.root / "ForsettiFramework/Source.swift"
        vendored.parent.mkdir(parents=True)
        vendored.write_text("struct Source {}\n", encoding="utf-8")
        self.assert_error_contains("tracked Forsetti repository/framework path is forbidden")

    def test_forbidden_workflow_command_fails(self) -> None:
        workflow = self.root / ".github/workflows/forbidden.yml"
        workflow.write_text(
            "name: Forbidden\non: workflow_dispatch\njobs:\n"
            "  example:\n    runs-on: ubuntu-latest\n"
            "    steps:\n      - run: gh release create demo\n",
            encoding="utf-8",
        )
        self.assert_error_contains("forbidden legacy/release workflow command")

    def test_required_workflow_network_metadata_command_fails(self) -> None:
        workflow = self.root / ".github/workflows/roadmap-alignment.yml"
        workflow.write_text(
            workflow.read_text(encoding="utf-8")
            + "\n# python3 Scripts/roadmap_alignment.py --check-github-metadata\n",
            encoding="utf-8",
        )
        self.assert_error_contains("deterministic required workflow contains")

    def test_github_metadata_comparison_is_exact(self) -> None:
        expected = self.policy["github_repository"]
        payload = {
            "full_name": expected["name_with_owner"],
            "description": expected["description"],
            "topics": list(reversed(expected["topics"])),
        }
        self.assertEqual(compare_github_metadata(payload, expected), [])
        payload["topics"] = payload["topics"][:-1]
        errors = compare_github_metadata(payload, expected)
        self.assertTrue(any("topics differ" in error for error in errors))

    def test_github_metadata_retries_are_bounded(self) -> None:
        expected = self.policy["github_repository"]
        with mock.patch(
            "roadmap_alignment.urlrequest.urlopen",
            side_effect=urlerror.URLError("offline"),
        ) as urlopen, mock.patch("roadmap_alignment.time.sleep") as sleep:
            with self.assertRaises(urlerror.URLError):
                fetch_github_metadata(expected, attempts=3)
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(sleep.call_count, 2)


if __name__ == "__main__":
    unittest.main()
