from __future__ import annotations

import copy
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
        for requirement in self.policy["phase_evidence_requirements"].values():
            paths.update(requirement["paths"])
        for requirement in self.policy["phase_start_requirements"].values():
            paths.update(requirement["paths"])
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
        return AlignmentVerifier(self.root, history_root=REPOSITORY_ROOT)

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

    def set_phase_status(self, phase_id: str, status: str) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phase = next(value for value in phases if value["id"] == phase_id)
        phase["status"] = status
        self.write_json(path, roadmap)

    def remove_forsetti_project_declarations(self) -> None:
        for relative in (
            self.policy["forsetti"]["project_path"],
            self.policy["forsetti"]["generated_project_path"],
        ):
            (self.root / relative).write_text("// dependency-free\n", encoding="utf-8")

    def add_forsetti_project_declaration(self, revision: str = "") -> None:
        project = self.root / self.policy["forsetti"]["project_path"]
        project.write_text(
            project.read_text(encoding="utf-8")
            + "\npackages:\n"
            + "  ForsettiFramework:\n"
            + f"    url: {self.policy['forsetti']['allowed_dependency_url']}\n"
            + f"    revision: {revision or self.policy['forsetti']['allowed_revision']}\n"
            + "dependencies:\n"
            + "  - package: ForsettiFramework\n"
            + "    product: ForsettiCore\n",
            encoding="utf-8",
        )

    @staticmethod
    def write_json(path: Path, value: dict[str, object]) -> None:
        path.write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def test_repository_fixture_is_aligned(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_passed_r01_requires_every_authorizing_evidence_file(self) -> None:
        evidence_path = self.root / self.policy["phase_evidence_requirements"]["R01"][
            "paths"
        ][0]
        evidence_path.unlink()
        self.assert_error_contains("phase R01 status 'passed' requires a regular evidence file")

    def test_preclosure_r01_does_not_require_runtime_evidence_files(self) -> None:
        self.set_phase_status("R01", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R01"]["paths"]:
            (self.root / relative).unlink()
        self.assertFalse(
            any("phase R01 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r01_rejects_symlinked_authorizing_evidence(self) -> None:
        symlink_path = self.root / self.policy["phase_evidence_requirements"]["R01"][
            "paths"
        ][0]
        target = self.root / "evidence-target.json"
        target.write_text("{}\n", encoding="utf-8")
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains("phase R01 status 'passed' requires a regular evidence file")

    def test_in_progress_r02_requires_every_start_contract_file(self) -> None:
        start_path = self.root / self.policy["phase_start_requirements"]["R02"][
            "paths"
        ][0]
        start_path.unlink()
        self.assert_error_contains(
            "phase R02 status 'in_progress' requires a regular start-contract file"
        )

    def test_prestart_r02_does_not_require_start_contract_files(self) -> None:
        self.set_phase_status("R02", "next")
        for relative in self.policy["phase_start_requirements"]["R02"]["paths"]:
            (self.root / relative).unlink()
        self.assertFalse(
            any("phase R02 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_in_progress_r02_rejects_symlinked_start_contract(self) -> None:
        symlink_path = self.root / self.policy["phase_start_requirements"]["R02"][
            "paths"
        ][0]
        target = self.root / "r02-start-target.json"
        target.write_text("{}\n", encoding="utf-8")
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R02 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r04_requires_every_start_contract_file(self) -> None:
        start_path = self.root / self.policy["phase_start_requirements"]["R04"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R04 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r04_rejects_symlinked_start_contract(self) -> None:
        relative = self.policy["phase_start_requirements"]["R04"]["paths"][1]
        symlink_path = self.root / relative
        target = self.root / "r04-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R04 status 'in_progress' requires a regular start-contract file"
        )

    def test_r04_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_start_requirements"]["R04"]["paths"].pop()
        mutations.append(missing_path)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R04"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R04"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R04 phase_start_requirements differ from the frozen contract"
                )

    def test_in_progress_r05_requires_every_start_contract_file(self) -> None:
        start_path = self.root / self.policy["phase_start_requirements"]["R05"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R05 status 'in_progress' requires a regular start-contract file"
        )

    def test_r05_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_start_requirements"]["R05"]["paths"].pop()
        mutations.append(missing_path)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R05"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R05"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R05 phase_start_requirements differ from the frozen contract"
                )

    def test_in_progress_r03_uses_exact_local_continuation_exception(self) -> None:
        self.assertFalse(
            any("phase R03 is 'in_progress' before dependency R02" in error for error in self.errors()),
            self.errors(),
        )

    def test_r03_exception_never_waives_next_or_closure_statuses(self) -> None:
        for status in ("next", "evidence_ready", "passed"):
            with self.subTest(status=status):
                self.set_phase_status("R03", status)
                self.assert_error_contains(
                    f"phase R03 is {status!r} before dependency R02 is passed"
                )

    def test_in_progress_r04_uses_exact_local_continuation_exception(self) -> None:
        self.assertFalse(
            any("phase R04 is 'in_progress' before dependency R03" in error for error in self.errors()),
            self.errors(),
        )

    def test_r04_exception_never_waives_next_or_closure_statuses(self) -> None:
        for status in ("next", "evidence_ready", "passed"):
            with self.subTest(status=status):
                self.set_phase_status("R04", status)
                self.assert_error_contains(
                    f"phase R04 is {status!r} before dependency R03 is passed"
                )

    def test_in_progress_r05_uses_exact_local_continuation_exception(self) -> None:
        self.assertFalse(
            any(
                "phase R05 is 'in_progress' before dependency R04" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_r05_exception_never_waives_next_or_closure_statuses(self) -> None:
        for status in ("next", "evidence_ready", "passed"):
            with self.subTest(status=status):
                self.set_phase_status("R05", status)
                self.assert_error_contains(
                    f"phase R05 is {status!r} before dependency R04 is passed"
                )

    def test_r05_exception_rejects_predecessor_binding_drift(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R05"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r04_exception_requires_regular_valid_preregistration(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        path.unlink()
        self.assert_error_contains("requires a regular preregistration file")

    def test_r04_exception_rejects_invalid_preregistration(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        path.write_text("{\n", encoding="utf-8")
        self.assert_error_contains("local continuation preregistration is invalid")

    def test_r04_exception_rejects_predecessor_binding_drift(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r04_exception_rejects_symlinked_preregistration(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        target = self.root / "r04-preregistration-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains("requires a regular preregistration file")

    def test_r03_exception_rejects_predecessor_binding_drift(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R03"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r03_exception_rejects_symlinked_preregistration(self) -> None:
        relative = self.policy["local_continuation_exceptions"]["R03"][
            "preregistration_path"
        ]
        path = self.root / relative
        target = self.root / "r03-preregistration-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains("requires a regular preregistration file")

    def test_r03_exception_policy_keys_are_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(path.read_text(encoding="utf-8"))
        policy["local_continuation_exceptions"]["R03"]["unexpected"] = True
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
        )

    def test_r03_exception_identity_keys_are_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(path.read_text(encoding="utf-8"))
        policy["local_continuation_exceptions"]["R03"][
            "preregistration_identity"
        ]["unexpected"] = True
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
        )

    def test_r03_exception_predecessor_keys_are_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(path.read_text(encoding="utf-8"))
        policy["local_continuation_exceptions"]["R03"]["predecessor_binding"][
            "unexpected"
        ] = True
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
        )

    def test_local_exceptions_reject_every_frozen_value_drift(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"

        def leaf_paths(value: object, prefix: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
            paths: list[tuple[object, ...]] = []
            if isinstance(value, dict):
                for key, nested in value.items():
                    paths.extend(leaf_paths(nested, prefix + (key,)))
            elif isinstance(value, list):
                for index, nested in enumerate(value):
                    paths.extend(leaf_paths(nested, prefix + (index,)))
            else:
                paths.append(prefix)
            return paths

        for phase_id in ("R03", "R04", "R05"):
            exception = self.policy["local_continuation_exceptions"][phase_id]
            for value_path in leaf_paths(exception):
                with self.subTest(phase_id=phase_id, value_path=value_path):
                    policy = copy.deepcopy(self.policy)
                    target = policy["local_continuation_exceptions"][phase_id]
                    for component in value_path[:-1]:
                        target = target[component]
                    final = value_path[-1]
                    original = target[final]
                    target[final] = "drift" if original is None else f"{original}-drift"
                    self.write_json(policy_path, policy)
                    self.assert_error_contains(
                        "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
                    )

    def test_local_exceptions_reject_every_missing_field(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"

        def field_paths(value: object, prefix: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
            paths: list[tuple[object, ...]] = []
            if isinstance(value, dict):
                for key, nested in value.items():
                    paths.append(prefix + (key,))
                    paths.extend(field_paths(nested, prefix + (key,)))
            return paths

        for phase_id in ("R03", "R04", "R05"):
            exception = self.policy["local_continuation_exceptions"][phase_id]
            for field_path in field_paths(exception):
                with self.subTest(phase_id=phase_id, field_path=field_path):
                    policy = copy.deepcopy(self.policy)
                    target = policy["local_continuation_exceptions"][phase_id]
                    for component in field_path[:-1]:
                        target = target[component]
                    target.pop(field_path[-1])
                    self.write_json(policy_path, policy)
                    self.assert_error_contains(
                        "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
                    )

    def test_local_exceptions_reject_required_key_order_drift(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        for phase_id in ("R03", "R04", "R05"):
            with self.subTest(phase_id=phase_id):
                policy = copy.deepcopy(self.policy)
                policy["local_continuation_exceptions"][phase_id][
                    "preregistration_required_keys"
                ].reverse()
                self.write_json(path, policy)
                self.assert_error_contains(
                    "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
                )

    def test_local_exceptions_reject_an_additional_r06_phase(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = copy.deepcopy(self.policy)
        policy["local_continuation_exceptions"]["R06"] = copy.deepcopy(
            policy["local_continuation_exceptions"]["R03"]
        )
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05 exceptions"
        )

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
                "**Status:** `passed`", "**Status:** `next`", 1
            ),
            encoding="utf-8",
        )
        self.assert_error_contains("Markdown status differs")

    def test_status_document_drift_fails(self) -> None:
        path = self.root / "local-work-plan.md"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "Roadmap phase `R00`: `passed`",
                "Roadmap phase `R00`: `next`",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_error_contains("phase status text differs")

    def test_progress_drift_fails_and_writer_repairs_it(self) -> None:
        readme = self.root / self.policy["readme"]["path"]
        text = readme.read_text(encoding="utf-8")
        text = text.replace("✅ Passed `2`", "✅ Passed `3`", 1)
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
        phases[2]["status"] = "in_progress"
        self.write_json(path, roadmap)
        self.assert_error_contains("before dependency R01 is passed")

    def test_r00_passed_requires_accepted_inventory(self) -> None:
        inventory_path = self.root / self.policy["r00_inventory"]["json_path"]
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        inventory["status"] = "baseline"
        self.write_json(inventory_path, inventory)
        self.assert_error_contains("expected 'accepted', found 'baseline'")

    def test_forsetti_dependency_expansion_fails(self) -> None:
        project = self.root / self.policy["forsetti"]["project_path"]
        project.write_text(
            project.read_text(encoding="utf-8")
            + "\n# invalid second coordinate\n"
            + "url: https://example.com/Forsetti-Framework-Mac-iOS.git\n",
            encoding="utf-8",
        )
        self.assert_error_contains("repository coordinate remains after R00")

    def test_r00_passed_requires_dependency_removal(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["status"] = "passed"
        self.write_json(path, roadmap)
        self.add_forsetti_project_declaration()
        self.assert_error_contains("dependency remains after R00")

    def test_r00_in_progress_rejects_partial_dependency_migration(self) -> None:
        path, roadmap = self.roadmap_json()
        phases = roadmap["phases"]
        self.assertIsInstance(phases, list)
        phases[0]["status"] = "in_progress"
        self.write_json(path, roadmap)
        self.add_forsetti_project_declaration(revision="0" * 40)
        self.assert_error_contains("neither the exact legacy pin nor complete dependency removal")

    def test_r00_evidence_ready_requires_dependency_removal(self) -> None:
        self.set_r00_status("evidence_ready")
        self.add_forsetti_project_declaration()
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

    def test_r04_contract_commands_are_required_in_ci_and_guardrails(self) -> None:
        common_required = (
            "Scripts/tests/test_r04_contracts.py",
            "python3 Scripts/r04_contracts.py --check-preregistration",
            "python3 Scripts/r04_contracts.py --check-fixtures",
        )
        path_specific_required = {
            ".github/workflows/roadmap-alignment.yml": (
                "python3 Scripts/r04_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r04/records/"
                "integration-conformance.json ]]; then",
            ),
            "Scripts/verify-mirmir-guardrails.sh": (
                "python3 Scripts/r04_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r04/records/"
                "integration-conformance.json ]]; then",
            ),
            "docs/governance/roadmap-alignment.md": (
                "test ! -f docs/roadmaps/evidence/r04/records/"
                "integration-conformance.json || python3 Scripts/r04_contracts.py "
                "--check-conformance",
            ),
        }
        for relative, path_specific in path_specific_required.items():
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            for phrase in common_required + path_specific:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(phrase, "removed-r04-contract-command", 1),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r04_blocked_closure_language_is_required(self) -> None:
        phrase = "local_unpublished_blocked_closure"
        for relative in (
            "docs/governance/roadmap-alignment.md",
            "docs/roadmaps/Mirmir_R01-R13_Execution_Handoff_2026-07-19.md",
        ):
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_text(encoding="utf-8")
                self.assertIn(phrase, original)
                path.write_text(
                    original.replace(phrase, "removed-r04-closure-state", 1),
                    encoding="utf-8",
                )
                self.assert_error_contains(
                    f"required alignment text is missing: {phrase!r}"
                )
                path.write_text(original, encoding="utf-8")

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
