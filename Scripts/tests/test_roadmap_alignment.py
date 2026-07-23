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
    render_progress,
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
        for override in self.policy.get("phase_acceptance_overrides", {}).values():
            for key in (
                "dependency_phase_evidence_binding",
                "dependency_conformance_binding",
                "acceptance_record_binding",
            ):
                binding = override.get(key)
                if isinstance(binding, dict):
                    paths.add(binding["path"])
        workflow_root = REPOSITORY_ROOT / self.policy["workflows"]["root"]
        paths.update(
            path.relative_to(REPOSITORY_ROOT).as_posix()
            for path in workflow_root.rglob("*")
            if path.is_file()
        )
        dormant_r11_passed_evidence = set(
            self.policy["phase_evidence_requirements"]["R11"]["paths"]
        )
        for relative in sorted(paths):
            source = REPOSITORY_ROOT / relative
            if not source.exists():
                self.assertIn(
                    relative,
                    dormant_r11_passed_evidence,
                    "only dormant R11 passed-evidence paths may be absent",
                )
                continue
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
        self.set_phase_status("R02", "in_progress")
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
        self.set_phase_status("R02", "in_progress")
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

    def test_passed_r02_requires_every_functional_acceptance_file(self) -> None:
        self.set_phase_status("R02", "passed")
        for relative in self.policy["phase_evidence_requirements"]["R02"]["paths"]:
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.unlink()
                self.assert_error_contains(
                    "phase R02 status 'passed' requires a regular evidence file"
                )
                path.write_bytes(original)

    def test_preclosure_r02_does_not_require_functional_acceptance_files(
        self,
    ) -> None:
        self.set_phase_status("R02", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R02"]["paths"]:
            (self.root / relative).unlink()
        self.assertFalse(
            any(
                "phase R02 status 'passed' requires a regular evidence file" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_passed_r02_rejects_symlinked_functional_acceptance_file(self) -> None:
        self.set_phase_status("R02", "passed")
        relative = self.policy["phase_evidence_requirements"]["R02"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r02-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R02 status 'passed' requires a regular evidence file"
        )

    def test_passed_r04_requires_every_functional_acceptance_file(self) -> None:
        self.set_phase_status("R04", "passed")
        for relative in self.policy["phase_evidence_requirements"]["R04"]["paths"]:
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.unlink()
                self.assert_error_contains(
                    "phase R04 status 'passed' requires a regular evidence file"
                )
                path.write_bytes(original)

    def test_passed_r04_rejects_symlinked_functional_acceptance_file(self) -> None:
        self.set_phase_status("R04", "passed")
        relative = self.policy["phase_evidence_requirements"]["R04"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r04-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R04 status 'passed' requires a regular evidence file"
        )

    def test_passed_r05_requires_every_functional_acceptance_file(self) -> None:
        self.set_phase_status("R05", "passed")
        for relative in self.policy["phase_evidence_requirements"]["R05"]["paths"]:
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.unlink()
                self.assert_error_contains(
                    "phase R05 status 'passed' requires a regular evidence file"
                )
                path.write_bytes(original)

    def test_passed_r05_rejects_symlinked_functional_acceptance_file(self) -> None:
        self.set_phase_status("R05", "passed")
        relative = self.policy["phase_evidence_requirements"]["R05"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r05-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R05 status 'passed' requires a regular evidence file"
        )

    def test_passed_r06_requires_every_functional_acceptance_file(self) -> None:
        self.set_phase_status("R06", "passed")
        for relative in self.policy["phase_evidence_requirements"]["R06"]["paths"]:
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.unlink()
                self.assert_error_contains(
                    "phase R06 status 'passed' requires a regular evidence file"
                )
                path.write_bytes(original)

    def test_passed_r06_rejects_symlinked_functional_acceptance_file(self) -> None:
        self.set_phase_status("R06", "passed")
        relative = self.policy["phase_evidence_requirements"]["R06"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r06-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R06 status 'passed' requires a regular evidence file"
        )

    def test_in_progress_r04_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R04", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R04"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R04 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r04_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R04", "in_progress")
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
        self.set_phase_status("R05", "in_progress")
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

    def test_in_progress_r06_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R06", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R06"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R06 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r06_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R06", "in_progress")
        relative = self.policy["phase_start_requirements"]["R06"]["paths"][1]
        symlink_path = self.root / relative
        target = self.root / "r06-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R06 status 'in_progress' requires a regular start-contract file"
        )

    def test_r06_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_start_requirements"]["R06"]["paths"].pop()
        mutations.append(missing_path)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R06"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R06"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R06 phase_start_requirements differ from the frozen contract"
                )

    def test_in_progress_r07_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R07", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R07"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R07 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r07_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R07", "in_progress")
        relative = self.policy["phase_start_requirements"]["R07"]["paths"][1]
        symlink_path = self.root / relative
        target = self.root / "r07-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R07 status 'in_progress' requires a regular start-contract file"
        )

    def test_r07_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_start_requirements"]["R07"]["paths"].pop()
        mutations.append(missing_path)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R07"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R07"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R07 phase_start_requirements differ from the frozen contract"
                )

    def test_in_progress_r08_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R08", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R08"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R08 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r08_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R08", "in_progress")
        relative = self.policy["phase_start_requirements"]["R08"]["paths"][1]
        symlink_path = self.root / relative
        target = self.root / "r08-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R08 status 'in_progress' requires a regular start-contract file"
        )

    def test_r08_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_start_requirements"]["R08"]["paths"].pop()
        mutations.append(missing_path)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R08"]["statuses"].append(
            "planned"
        )
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R08"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R08 phase_start_requirements differ from the frozen contract"
                )

    def test_in_progress_r10_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R10", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R10"][
            "paths"
        ][3]
        start_path.unlink()
        self.assert_error_contains(
            "phase R10 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r10_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R10", "in_progress")
        relative = self.policy["phase_start_requirements"]["R10"]["paths"][2]
        symlink_path = self.root / relative
        target = self.root / "r10-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R10 status 'in_progress' requires a regular start-contract file"
        )

    def test_r10_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_catalog = copy.deepcopy(self.policy)
        missing_catalog["phase_start_requirements"]["R10"]["paths"].pop()
        mutations.append(missing_catalog)

        missing_predecessor = copy.deepcopy(self.policy)
        missing_predecessor["phase_start_requirements"]["R10"][
            "predecessors"
        ].pop()
        mutations.append(missing_predecessor)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R10"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R10"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R10 phase_start_requirements differ from the frozen contract"
                )

    def test_r10_canonical_predecessors_match_start_contract(self) -> None:
        path, roadmap = self.roadmap_json()
        phase = next(value for value in roadmap["phases"] if value["id"] == "R10")
        phase["depends_on"] = ["R07"]
        self.write_json(path, roadmap)
        self.assert_error_contains(
            "phase R10 canonical predecessors differ from its start contract"
        )

    def test_in_progress_r11_requires_every_start_contract_file(self) -> None:
        self.set_phase_status("R11", "in_progress")
        start_path = self.root / self.policy["phase_start_requirements"]["R11"][
            "paths"
        ][1]
        start_path.unlink()
        self.assert_error_contains(
            "phase R11 status 'in_progress' requires a regular start-contract file"
        )

    def test_in_progress_r11_rejects_symlinked_start_contract(self) -> None:
        self.set_phase_status("R11", "in_progress")
        relative = self.policy["phase_start_requirements"]["R11"]["paths"][0]
        symlink_path = self.root / relative
        target = self.root / "r11-start-target.json"
        target.write_bytes(symlink_path.read_bytes())
        symlink_path.unlink()
        symlink_path.symlink_to(target)
        self.assert_error_contains(
            "phase R11 status 'in_progress' requires a regular start-contract file"
        )

    def test_r11_phase_start_requirement_is_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_catalog = copy.deepcopy(self.policy)
        missing_catalog["phase_start_requirements"]["R11"]["paths"].pop()
        mutations.append(missing_catalog)

        missing_predecessor = copy.deepcopy(self.policy)
        missing_predecessor["phase_start_requirements"]["R11"][
            "predecessors"
        ].pop()
        mutations.append(missing_predecessor)

        extra_status = copy.deepcopy(self.policy)
        extra_status["phase_start_requirements"]["R11"]["statuses"].append("planned")
        mutations.append(extra_status)

        for mutation in mutations:
            with self.subTest(mutation=mutation["phase_start_requirements"]["R11"]):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "R11 phase_start_requirements differ from the frozen contract"
                )

    def test_r11_canonical_predecessors_match_start_contract(self) -> None:
        path, roadmap = self.roadmap_json()
        phase = next(value for value in roadmap["phases"] if value["id"] == "R11")
        phase["depends_on"] = []
        self.write_json(path, roadmap)
        self.assert_error_contains(
            "phase R11 canonical predecessors differ from its start contract"
        )

    def test_in_progress_r11_requires_passed_r10(self) -> None:
        self.set_phase_status("R10", "in_progress")
        self.set_phase_status("R11", "in_progress")
        self.assert_error_contains(
            "phase R11 is 'in_progress' before dependency R10 is passed"
        )

    def test_in_progress_r03_uses_exact_local_continuation_exception(self) -> None:
        self.set_phase_status("R02", "in_progress")
        self.set_phase_status("R03", "in_progress")
        self.assertFalse(
            any("phase R03 is 'in_progress' before dependency R02" in error for error in self.errors()),
            self.errors(),
        )

    def test_r03_exception_never_waives_next_or_evidence_ready(self) -> None:
        self.set_phase_status("R02", "in_progress")
        for status in ("next", "evidence_ready"):
            with self.subTest(status=status):
                self.set_phase_status("R03", status)
                self.assert_error_contains(
                    f"phase R03 is {status!r} before dependency R02 is passed"
                )

    def test_passed_r03_uses_exact_functional_acceptance_override(self) -> None:
        self.set_phase_status("R02", "in_progress")
        self.set_phase_status("R03", "passed")
        self.assertFalse(
            any(
                "phase R03 is 'passed' before dependency R02" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_r03_acceptance_override_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        policy = copy.deepcopy(self.policy)
        policy["phase_acceptance_overrides"]["R03"]["acceptance_identity"][
            "override_id"
        ] = "drift"
        self.write_json(policy_path, policy)
        self.assert_error_contains(
            "phase_acceptance_overrides differ from the exact R03 functional contract"
        )

    def test_passed_r03_requires_exact_acceptance_record(self) -> None:
        self.set_phase_status("R02", "in_progress")
        self.set_phase_status("R03", "passed")
        path = self.root / self.policy["phase_acceptance_overrides"]["R03"][
            "acceptance_record_binding"
        ]["path"]
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.assert_error_contains("acceptance_record_binding bytes differ")

    def test_in_progress_r04_uses_exact_local_continuation_exception(self) -> None:
        self.set_phase_status("R03", "in_progress")
        self.set_phase_status("R04", "in_progress")
        self.assertFalse(
            any("phase R04 is 'in_progress' before dependency R03" in error for error in self.errors()),
            self.errors(),
        )

    def test_r04_exception_never_waives_next_or_closure_statuses(self) -> None:
        for status in ("next", "evidence_ready", "passed"):
            with self.subTest(status=status):
                self.set_phase_status("R03", "in_progress")
                self.set_phase_status("R04", status)
                self.assert_error_contains(
                    f"phase R04 is {status!r} before dependency R03 is passed"
                )

    def test_in_progress_r05_uses_exact_local_continuation_exception(self) -> None:
        self.set_phase_status("R04", "in_progress")
        self.set_phase_status("R05", "in_progress")
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
                self.set_phase_status("R04", "in_progress")
                self.set_phase_status("R05", status)
                self.assert_error_contains(
                    f"phase R05 is {status!r} before dependency R04 is passed"
                )

    def test_r05_exception_rejects_predecessor_binding_drift(self) -> None:
        self.set_phase_status("R04", "in_progress")
        self.set_phase_status("R05", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R05"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_in_progress_r06_uses_exact_local_continuation_exception(self) -> None:
        self.set_phase_status("R05", "in_progress")
        self.set_phase_status("R06", "in_progress")
        self.assertFalse(
            any(
                "phase R06 is 'in_progress' before dependency R05" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_r06_exception_never_waives_next_or_closure_statuses(self) -> None:
        for status in ("next", "evidence_ready", "passed"):
            with self.subTest(status=status):
                self.set_phase_status("R05", "in_progress")
                self.set_phase_status("R06", status)
                self.assert_error_contains(
                    f"phase R06 is {status!r} before dependency R05 is passed"
                )

    def test_r06_exception_requires_regular_valid_preregistration(self) -> None:
        self.set_phase_status("R05", "in_progress")
        self.set_phase_status("R06", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R06"][
            "preregistration_path"
        ]
        (self.root / relative).unlink()
        self.assert_error_contains("requires a regular preregistration file")

    def test_r06_exception_rejects_predecessor_binding_drift(self) -> None:
        self.set_phase_status("R05", "in_progress")
        self.set_phase_status("R06", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R06"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r06_exception_rejects_symlinked_preregistration(self) -> None:
        self.set_phase_status("R05", "in_progress")
        self.set_phase_status("R06", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R06"][
            "preregistration_path"
        ]
        path = self.root / relative
        target = self.root / "r06-preregistration-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains("requires a regular preregistration file")

    def test_in_progress_r07_uses_exact_local_continuation_exception(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "in_progress")
        self.assertFalse(
            any(
                "phase R07 is 'in_progress' before dependency R06" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_r07_exception_never_waives_next_or_evidence_ready(self) -> None:
        self.set_phase_status("R06", "in_progress")
        for status in ("next", "evidence_ready"):
            with self.subTest(status=status):
                self.set_phase_status("R07", status)
                self.assert_error_contains(
                    f"phase R07 is {status!r} before dependency R06 is passed"
                )

    def test_r07_exception_requires_regular_valid_preregistration(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R07"][
            "preregistration_path"
        ]
        (self.root / relative).unlink()
        self.assert_error_contains("requires a regular preregistration file")

    def test_r07_exception_rejects_predecessor_binding_drift(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R07"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r07_exception_rejects_preregistration_key_drift(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R07"][
            "preregistration_path"
        ]
        path = self.root / relative
        original = json.loads(path.read_text(encoding="utf-8"))
        mutations = []

        missing_key = copy.deepcopy(original)
        missing_key.pop("authorization_boundary")
        mutations.append(missing_key)

        additional_key = copy.deepcopy(original)
        additional_key["unexpected"] = True
        mutations.append(additional_key)

        for mutation in mutations:
            with self.subTest(keys=list(mutation)):
                self.write_json(path, mutation)
                self.assert_error_contains(
                    "local continuation preregistration keys differ"
                )

    def test_r07_exception_rejects_symlinked_preregistration(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R07"][
            "preregistration_path"
        ]
        path = self.root / relative
        target = self.root / "r07-preregistration-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains("requires a regular preregistration file")

    def test_passed_r07_uses_exact_functional_acceptance_override(self) -> None:
        self.set_phase_status("R06", "in_progress")
        self.set_phase_status("R07", "passed")
        self.assertFalse(
            any(
                "phase R07 is 'passed' before dependency R06" in error
                for error in self.errors()
            ),
            self.errors(),
        )

    def test_r07_acceptance_override_is_exact(self) -> None:
        self.set_phase_status("R06", "in_progress")
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        policy = copy.deepcopy(self.policy)
        policy["phase_acceptance_overrides"]["R07"]["acceptance_identity"][
            "comparative_requirement"
        ] = "required"
        self.write_json(policy_path, policy)
        self.assert_error_contains("exact R07 functional contract")

    def test_passed_r07_requires_exact_acceptance_record(self) -> None:
        self.set_phase_status("R06", "in_progress")
        path = self.root / self.policy["phase_acceptance_overrides"]["R07"][
            "acceptance_record_binding"
        ]["path"]
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.assert_error_contains("acceptance_record_binding bytes differ")

    def test_passed_r07_requires_exact_r06_phase_evidence(self) -> None:
        self.set_phase_status("R06", "in_progress")
        path = self.root / self.policy["phase_acceptance_overrides"]["R07"][
            "dependency_phase_evidence_binding"
        ]["path"]
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.assert_error_contains("dependency_phase_evidence_binding bytes differ")

    def test_passed_r07_requires_exact_r06_conformance(self) -> None:
        self.set_phase_status("R06", "in_progress")
        path = self.root / self.policy["phase_acceptance_overrides"]["R07"][
            "dependency_conformance_binding"
        ]["path"]
        path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.assert_error_contains("dependency_conformance_binding bytes differ")

    def test_passed_r07_requires_regular_authorizing_evidence(self) -> None:
        path = self.root / self.policy["phase_evidence_requirements"]["R07"][
            "paths"
        ][0]
        path.unlink()
        self.assert_error_contains(
            "phase R07 status 'passed' requires a regular evidence file"
        )

    def test_passed_r07_rejects_symlinked_acceptance_record(self) -> None:
        self.set_phase_status("R06", "in_progress")
        relative = self.policy["phase_acceptance_overrides"]["R07"][
            "acceptance_record_binding"
        ]["path"]
        path = self.root / relative
        target = self.root / "r07-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "acceptance_record_binding is not a regular file"
        )

    def test_passed_r08_requires_functional_acceptance_evidence(self) -> None:
        self.set_phase_status("R08", "passed")
        relative = self.policy["phase_evidence_requirements"]["R08"]["paths"][-1]
        (self.root / relative).unlink()
        self.assert_error_contains(
            "phase R08 status 'passed' requires a regular evidence file"
        )

    def test_preclosure_r08_does_not_require_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R08", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R08"]["paths"]:
            (self.root / relative).unlink()
        self.assertFalse(
            any("phase R08 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r08_rejects_symlinked_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R08", "passed")
        relative = self.policy["phase_evidence_requirements"]["R08"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r08-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R08 status 'passed' requires a regular evidence file"
        )

    def test_r08_functional_evidence_requirement_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_evidence_requirements"]["R08"]["paths"].pop()
        mutations.append(missing_path)

        wrong_status = copy.deepcopy(self.policy)
        wrong_status["phase_evidence_requirements"]["R08"][
            "required_status"
        ] = "evidence_ready"
        mutations.append(wrong_status)

        for mutation in mutations:
            with self.subTest(
                mutation=mutation["phase_evidence_requirements"]["R08"]
            ):
                self.write_json(policy_path, mutation)
                self.assert_error_contains(
                    "R08 phase_evidence_requirements differ from the frozen "
                    "software-function acceptance contract"
                )

    def test_passed_r09_requires_functional_acceptance_evidence(self) -> None:
        self.set_phase_status("R09", "passed")
        relative = self.policy["phase_evidence_requirements"]["R09"]["paths"][-1]
        (self.root / relative).unlink()
        self.assert_error_contains(
            "phase R09 status 'passed' requires a regular evidence file"
        )

    def test_preclosure_r09_does_not_require_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R09", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R09"]["paths"]:
            (self.root / relative).unlink()
        self.assertFalse(
            any("phase R09 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r09_rejects_symlinked_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R09", "passed")
        relative = self.policy["phase_evidence_requirements"]["R09"]["paths"][-1]
        path = self.root / relative
        target = self.root / "r09-functional-acceptance-target.json"
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R09 status 'passed' requires a regular evidence file"
        )

    def test_r09_functional_evidence_requirement_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_evidence_requirements"]["R09"]["paths"].pop()
        mutations.append(missing_path)

        wrong_status = copy.deepcopy(self.policy)
        wrong_status["phase_evidence_requirements"]["R09"][
            "required_status"
        ] = "evidence_ready"
        mutations.append(wrong_status)

        for mutation in mutations:
            with self.subTest(
                mutation=mutation["phase_evidence_requirements"]["R09"]
            ):
                self.write_json(policy_path, mutation)
                self.assert_error_contains(
                    "R09 phase_evidence_requirements differ from the frozen "
                    "software-function acceptance contract"
                )

    def test_passed_r10_requires_functional_acceptance_evidence(self) -> None:
        self.set_phase_status("R10", "passed")
        relative = self.policy["phase_evidence_requirements"]["R10"]["paths"][-1]
        (self.root / relative).unlink(missing_ok=True)
        self.assert_error_contains(
            "phase R10 status 'passed' requires a regular evidence file"
        )

    def test_in_progress_r10_does_not_require_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R10", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R10"]["paths"]:
            (self.root / relative).unlink(missing_ok=True)
        self.assertFalse(
            any("phase R10 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r10_rejects_symlinked_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R10", "passed")
        relative = self.policy["phase_evidence_requirements"]["R10"]["paths"][-1]
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        target = self.root / "r10-functional-acceptance-target.json"
        target.write_text("{}\n", encoding="utf-8")
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R10 status 'passed' requires a regular evidence file"
        )

    def test_r10_functional_evidence_requirement_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_evidence_requirements"]["R10"]["paths"].pop()
        mutations.append(missing_path)

        wrong_status = copy.deepcopy(self.policy)
        wrong_status["phase_evidence_requirements"]["R10"][
            "required_status"
        ] = "in_progress"
        mutations.append(wrong_status)

        for mutation in mutations:
            with self.subTest(
                mutation=mutation["phase_evidence_requirements"]["R10"]
            ):
                self.write_json(policy_path, mutation)
                self.assert_error_contains(
                    "R10 phase_evidence_requirements differ from the prospective "
                    "software-function acceptance contract"
                )

    def test_passed_r11_requires_functional_acceptance_evidence(self) -> None:
        self.set_phase_status("R11", "passed")
        relative = self.policy["phase_evidence_requirements"]["R11"]["paths"][-1]
        (self.root / relative).unlink(missing_ok=True)
        self.assert_error_contains(
            "phase R11 status 'passed' requires a regular evidence file"
        )

    def test_in_progress_r11_does_not_require_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R11", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R11"]["paths"]:
            (self.root / relative).unlink(missing_ok=True)
        self.assertFalse(
            any("phase R11 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r11_rejects_symlinked_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R11", "passed")
        relative = self.policy["phase_evidence_requirements"]["R11"]["paths"][-1]
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        target = self.root / "r11-functional-acceptance-target.json"
        target.write_text("{}\n", encoding="utf-8")
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R11 status 'passed' requires a regular evidence file"
        )

    def test_r11_functional_evidence_requirement_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_evidence_requirements"]["R11"]["paths"].pop()
        mutations.append(missing_path)

        wrong_status = copy.deepcopy(self.policy)
        wrong_status["phase_evidence_requirements"]["R11"][
            "required_status"
        ] = "in_progress"
        mutations.append(wrong_status)

        for mutation in mutations:
            with self.subTest(
                mutation=mutation["phase_evidence_requirements"]["R11"]
            ):
                self.write_json(policy_path, mutation)
                self.assert_error_contains(
                    "R11 phase_evidence_requirements differ from the prospective "
                    "software-function acceptance contract"
                )

    def test_passed_r12_requires_functional_acceptance_evidence(self) -> None:
        self.set_phase_status("R12", "passed")
        relative = self.policy["phase_evidence_requirements"]["R12"]["paths"][-1]
        (self.root / relative).unlink(missing_ok=True)
        self.assert_error_contains(
            "phase R12 status 'passed' requires a regular evidence file"
        )

    def test_in_progress_r12_does_not_require_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R12", "in_progress")
        for relative in self.policy["phase_evidence_requirements"]["R12"]["paths"]:
            (self.root / relative).unlink(missing_ok=True)
        self.assertFalse(
            any("phase R12 status" in error for error in self.errors()),
            self.errors(),
        )

    def test_passed_r12_rejects_symlinked_functional_acceptance_evidence(
        self,
    ) -> None:
        self.set_phase_status("R12", "passed")
        relative = self.policy["phase_evidence_requirements"]["R12"]["paths"][-1]
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        target = self.root / "r12-functional-acceptance-target.json"
        target.write_text("{}\n", encoding="utf-8")
        path.symlink_to(target)
        self.assert_error_contains(
            "phase R12 status 'passed' requires a regular evidence file"
        )

    def test_r12_functional_evidence_requirement_is_exact(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutations = []

        missing_path = copy.deepcopy(self.policy)
        missing_path["phase_evidence_requirements"]["R12"]["paths"].pop()
        mutations.append(missing_path)

        wrong_status = copy.deepcopy(self.policy)
        wrong_status["phase_evidence_requirements"]["R12"][
            "required_status"
        ] = "in_progress"
        mutations.append(wrong_status)

        for mutation in mutations:
            with self.subTest(
                mutation=mutation["phase_evidence_requirements"]["R12"]
            ):
                self.write_json(policy_path, mutation)
                self.assert_error_contains(
                    "R12 phase_evidence_requirements differ from the frozen "
                    "software-function acceptance contract"
                )

    def test_r13_does_not_require_nonexistent_acceptance_evidence(self) -> None:
        policy_path = self.root / ".github/roadmap-alignment-policy.json"
        mutation = copy.deepcopy(self.policy)
        mutation["phase_evidence_requirements"]["R13"] = {
            "required_status": "in_progress",
            "paths": ["docs/roadmaps/evidence/r13/records/nonexistent.json"],
        }
        self.write_json(policy_path, mutation)
        self.assert_error_contains(
            "R13 phase_evidence_requirements must remain absent before "
            "R13 acceptance evidence exists"
        )

    def test_r04_exception_requires_regular_valid_preregistration(self) -> None:
        self.set_phase_status("R03", "in_progress")
        self.set_phase_status("R04", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        path.unlink()
        self.assert_error_contains("requires a regular preregistration file")

    def test_r04_exception_rejects_invalid_preregistration(self) -> None:
        self.set_phase_status("R03", "in_progress")
        self.set_phase_status("R04", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        path.write_text("{\n", encoding="utf-8")
        self.assert_error_contains("local continuation preregistration is invalid")

    def test_r04_exception_rejects_predecessor_binding_drift(self) -> None:
        self.set_phase_status("R03", "in_progress")
        self.set_phase_status("R04", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R04"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["predecessor_result"] = "passed"
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r04_exception_rejects_symlinked_preregistration(self) -> None:
        self.set_phase_status("R03", "in_progress")
        self.set_phase_status("R04", "in_progress")
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
        self.set_phase_status("R02", "in_progress")
        self.set_phase_status("R03", "in_progress")
        relative = self.policy["local_continuation_exceptions"]["R03"][
            "preregistration_path"
        ]
        path = self.root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        self.write_json(path, value)
        self.assert_error_contains("local continuation predecessor binding differs")

    def test_r03_exception_rejects_symlinked_preregistration(self) -> None:
        self.set_phase_status("R02", "in_progress")
        self.set_phase_status("R03", "in_progress")
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
            "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
        )

    def test_r03_exception_identity_keys_are_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(path.read_text(encoding="utf-8"))
        policy["local_continuation_exceptions"]["R03"][
            "preregistration_identity"
        ]["unexpected"] = True
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
        )

    def test_r03_exception_predecessor_keys_are_exact(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = json.loads(path.read_text(encoding="utf-8"))
        policy["local_continuation_exceptions"]["R03"]["predecessor_binding"][
            "unexpected"
        ] = True
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
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

        for phase_id in ("R03", "R04", "R05", "R06", "R07"):
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
                        "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
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

        for phase_id in ("R03", "R04", "R05", "R06", "R07"):
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
                        "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
                    )

    def test_local_exceptions_reject_required_key_order_drift(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        for phase_id in ("R03", "R04", "R05", "R06", "R07"):
            with self.subTest(phase_id=phase_id):
                policy = copy.deepcopy(self.policy)
                policy["local_continuation_exceptions"][phase_id][
                    "preregistration_required_keys"
                ].reverse()
                self.write_json(path, policy)
                self.assert_error_contains(
                    "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
                )

    def test_local_exceptions_reject_an_additional_r08_phase(self) -> None:
        path = self.root / ".github/roadmap-alignment-policy.json"
        policy = copy.deepcopy(self.policy)
        policy["local_continuation_exceptions"]["R08"] = copy.deepcopy(
            policy["local_continuation_exceptions"]["R03"]
        )
        self.write_json(path, policy)
        self.assert_error_contains(
            "local_continuation_exceptions differ from the frozen R03/R04/R05/R06/R07 exceptions"
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
        text = text.replace("✅ Passed", "❌ Passed", 1)
        readme.write_text(text, encoding="utf-8")
        self.assert_error_contains("Roadmap Progress block is stale")
        self.verifier().write_progress()
        self.assertEqual(self.errors(), [])

    def test_progress_percentage_uses_deterministic_half_up_rounding(
        self,
    ) -> None:
        _path, roadmap = self.roadmap_json()
        rendered = render_progress(roadmap, self.policy)
        self.assertIn(
            "**Overall:** `13 / 14` roadmap phases passed (`93%`)",
            rendered,
        )

        half_up_roadmap = copy.deepcopy(roadmap)
        phase_order = self.policy["progress"]["phase_order"][:8]
        for phase in half_up_roadmap["phases"]:
            if phase["id"] in phase_order:
                phase["status"] = "planned"
        first_phase = next(
            phase
            for phase in half_up_roadmap["phases"]
            if phase["id"] == phase_order[0]
        )
        first_phase["status"] = "passed"
        half_up_policy = copy.deepcopy(self.policy)
        half_up_policy["progress"]["phase_order"] = phase_order
        half_up_rendered = render_progress(
            half_up_roadmap,
            half_up_policy,
        )
        self.assertIn(
            "**Overall:** `1 / 8` roadmap phases passed (`13%`)",
            half_up_rendered,
        )

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

    def test_r02_phase_acceptance_commands_are_required_in_ci_and_guardrails(
        self,
    ) -> None:
        common_required = (
            "Scripts/tests/test_r02_phase_acceptance.py",
            "python3 Scripts/r02_phase_acceptance.py --check",
        )
        workflow_required = (
            "r02-functional-acceptance:",
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            "if: ${{ always() }}",
            (
                'test "${{ needs.r02-functional-acceptance.result }}" '
                '= "success"'
            ),
            (
                'test "${{ needs.r04-functional-acceptance.result }}" '
                '= "success"'
            ),
            "runs-on: macos-26",
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r02-eeabc422-source "
                "eeabc4224100bc8ed86ae1208189bee508844210"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r02-eeabc422-source"
            ),
            (
                "xcodebuild -quiet -project Mirmir.xcodeproj -scheme Mirmir "
                "-configuration Debug -destination platform=macOS,arch=arm64 "
                "-derivedDataPath /private/tmp/mirmir-r02-eeabc422-v2-derived "
                "-resultBundlePath /private/tmp/"
                "mirmir-r02-eeabc422-v2.xcresult "
                "-disableAutomaticPackageResolution test "
                "-only-testing:MirmirTests/AppleUpscaleContractsTests "
                "-only-testing:MirmirTests/EnhancementPipelineContractsTests "
                "-only-testing:MirmirTests/AppleUpscaleFIFOSessionTests "
                "-only-testing:MirmirTests/R02FixtureConformanceTests "
                "-only-testing:MirmirTests/ArchitectureGuardrailTests/"
                "test_productionCompositionUsesNoRetainedReferenceBackendOr"
                "VTStager "
                "-only-testing:MirmirTests/UpscalerEngineAvailabilityTests/"
                "test_unavailableServiceRejectsSubmissionWithTypedReason "
                "CODE_SIGNING_ALLOWED=NO"
            ),
            (
                "python3 Scripts/r02_phase_acceptance.py --check-xcresult "
                "/private/tmp/mirmir-r02-eeabc422-v2.xcresult"
            ),
            "- name: Verify checked-in R02 acceptance",
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            "name: r02-functional-acceptance-xcresult",
        )
        for relative in (
            ".github/workflows/roadmap-alignment.yml",
            "Scripts/verify-mirmir-guardrails.sh",
        ):
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            required = common_required + (
                workflow_required
                if relative == ".github/workflows/roadmap-alignment.yml"
                else ()
            )
            for phrase in required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r02-phase-acceptance-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r02_xcode_run_uses_exact_checkpoint_worktree(self) -> None:
        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        materialize = (
            "- name: Materialize exact R02 source checkpoint\n"
            "        run: git worktree add --detach "
            "/private/tmp/mirmir-r02-eeabc422-source "
            "eeabc4224100bc8ed86ae1208189bee508844210"
        )
        run = (
            "- name: Run exact R02 selected tests\n"
            "        working-directory: "
            "/private/tmp/mirmir-r02-eeabc422-source"
        )
        validate = "- name: Validate raw R02 xcresult"
        self.assertIn(materialize, workflow)
        self.assertIn(run, workflow)
        self.assertLess(workflow.index(materialize), workflow.index(run))
        self.assertLess(workflow.index(run), workflow.index(validate))

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

    def test_r04_phase_acceptance_commands_are_required_in_ci_and_guardrails(
        self,
    ) -> None:
        common_required = (
            "Scripts/tests/test_r04_phase_acceptance.py",
            "python3 Scripts/r04_phase_acceptance.py --check",
        )
        workflow_required = (
            "r04-functional-acceptance:",
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r04-functional-acceptance.result }}" '
                '= "success"'
            ),
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r04-ab77e978-source "
                "ab77e97867d51168e90c0190f6430d4acd769e68"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r04-ab77e978-source"
            ),
            (
                "xcodebuild -quiet -project Mirmir.xcodeproj -scheme Mirmir "
                "-configuration Debug -destination platform=macOS,arch=arm64 "
                "-derivedDataPath /private/tmp/mirmir-r04-ab77e978-derived "
                "-resultBundlePath /private/tmp/mirmir-r04-ab77e978.xcresult "
                "-disableAutomaticPackageResolution test "
                "-only-testing:MirmirTests/R04VideoToolboxContractsTests "
                "-only-testing:MirmirTests/"
                "R04VideoToolboxSessionAdapterTests "
                "-only-testing:MirmirTests/UpscalerEngineAvailabilityTests "
                "-only-testing:MirmirTests/"
                "R04FunctionalPhaseAcceptanceTests "
                "'EXCLUDED_SOURCE_FILE_NAMES=*.metal' "
                "CODE_SIGNING_ALLOWED=NO"
            ),
            (
                "python3 Scripts/r04_phase_acceptance.py --check-xcresult "
                "/private/tmp/mirmir-r04-ab77e978.xcresult"
            ),
            "- name: Verify checked-in R04 acceptance",
            "name: r04-functional-acceptance-xcresult",
        )
        for relative in (
            ".github/workflows/roadmap-alignment.yml",
            "Scripts/verify-mirmir-guardrails.sh",
        ):
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            required = common_required + (
                workflow_required
                if relative == ".github/workflows/roadmap-alignment.yml"
                else ()
            )
            for phrase in required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r04-phase-acceptance-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r04_xcode_run_uses_exact_checkpoint_worktree(self) -> None:
        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        materialize = (
            "- name: Materialize exact R04 source checkpoint\n"
            "        run: git worktree add --detach "
            "/private/tmp/mirmir-r04-ab77e978-source "
            "ab77e97867d51168e90c0190f6430d4acd769e68"
        )
        run = (
            "- name: Run exact R04 selected tests\n"
            "        working-directory: "
            "/private/tmp/mirmir-r04-ab77e978-source"
        )
        validate = "- name: Validate raw R04 xcresult"
        self.assertIn(materialize, workflow)
        self.assertIn(run, workflow)
        self.assertLess(workflow.index(materialize), workflow.index(run))
        self.assertLess(workflow.index(run), workflow.index(validate))

    def test_r05_phase_acceptance_commands_are_required_in_ci_and_guardrails(
        self,
    ) -> None:
        common_required = (
            "Scripts/tests/test_r05_phase_acceptance.py",
            "python3 Scripts/r05_phase_acceptance.py --check",
        )
        workflow_required = (
            "r05-functional-acceptance:",
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r05-functional-acceptance.result }}" '
                '= "success"'
            ),
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r05-7e1ab673-source "
                "7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r05-7e1ab673-source"
            ),
            (
                "xcodebuild -quiet -project Mirmir.xcodeproj -scheme Mirmir "
                "-configuration Debug -destination platform=macOS,arch=arm64 "
                "-derivedDataPath /private/tmp/mirmir-r05-7e1ab673-derived "
                "-resultBundlePath /private/tmp/mirmir-r05-7e1ab673.xcresult "
                "-disableAutomaticPackageResolution test "
                "-only-testing:MirmirTests/R05MetalFXContractsTests "
                "-only-testing:MirmirTests/R05MetalFXColorBridgeTests "
                "-only-testing:MirmirTests/R05MetalFXSpatialDriverTests "
                "-only-testing:MirmirTests/R05MetalFXSpatialBackendTests "
                "-only-testing:MirmirTests/"
                "R05FunctionalPhaseAcceptanceTests "
                "'EXCLUDED_SOURCE_FILE_NAMES=*.metal' "
                "CODE_SIGNING_ALLOWED=NO"
            ),
            (
                "python3 Scripts/r05_phase_acceptance.py --check-xcresult "
                "/private/tmp/mirmir-r05-7e1ab673.xcresult"
            ),
            "- name: Verify checked-in R05 acceptance",
            "name: r05-functional-acceptance-xcresult",
        )
        for relative in (
            ".github/workflows/roadmap-alignment.yml",
            "Scripts/verify-mirmir-guardrails.sh",
        ):
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            required = common_required + (
                workflow_required
                if relative == ".github/workflows/roadmap-alignment.yml"
                else ()
            )
            for phrase in required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r05-phase-acceptance-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r05_xcode_run_uses_exact_checkpoint_worktree(self) -> None:
        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        materialize = (
            "- name: Materialize exact R05 source checkpoint\n"
            "        run: git worktree add --detach "
            "/private/tmp/mirmir-r05-7e1ab673-source "
            "7e1ab67340e4d6d95a3d92e8a48bc6cd356005b8"
        )
        run = (
            "- name: Run exact R05 selected tests\n"
            "        working-directory: "
            "/private/tmp/mirmir-r05-7e1ab673-source"
        )
        validate = "- name: Validate raw R05 xcresult"
        self.assertIn(materialize, workflow)
        self.assertIn(run, workflow)
        self.assertLess(workflow.index(materialize), workflow.index(run))
        self.assertLess(workflow.index(run), workflow.index(validate))

    def test_r06_contract_commands_are_required_in_ci_and_guardrails(self) -> None:
        common_required = (
            "Scripts/tests/test_r06_contracts.py",
            "python3 Scripts/r06_contracts.py --check-preregistration",
            "python3 Scripts/r06_contracts.py --check-fixtures",
        )
        path_specific_required = {
            ".github/workflows/roadmap-alignment.yml": (
                "python3 Scripts/r06_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r06/records/"
                "orchestration-conformance.json ]]; then",
            ),
            "Scripts/verify-mirmir-guardrails.sh": (
                "python3 Scripts/r06_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r06/records/"
                "orchestration-conformance.json ]]; then",
            ),
            "docs/governance/roadmap-alignment.md": (
                "test ! -f docs/roadmaps/evidence/r06/records/"
                "orchestration-conformance.json || python3 Scripts/r06_contracts.py "
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
                        original.replace(phrase, "removed-r06-contract-command", 1),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r06_phase_acceptance_commands_are_required_in_ci_and_guardrails(
        self,
    ) -> None:
        common_required = (
            "Scripts/tests/test_r06_phase_acceptance.py",
            "python3 Scripts/r06_phase_acceptance.py --check",
            "./Scripts/verify-r06-layered-evidence.sh",
        )
        workflow_required = (
            "r06-functional-acceptance:",
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r06-functional-acceptance.result }}" '
                '= "success"'
            ),
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r06-6c4a6d3d-source "
                "6c4a6d3d5f8a59c553b10c23783c148ccb3388a5"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r06-6c4a6d3d-source"
            ),
            (
                "xcodebuild -quiet -project Mirmir.xcodeproj -scheme Mirmir "
                "-configuration Debug -destination platform=macOS,arch=arm64 "
                "-derivedDataPath /private/tmp/mirmir-r06-6c4a6d3d-derived "
                "-resultBundlePath /private/tmp/mirmir-r06-6c4a6d3d.xcresult "
                "-disableAutomaticPackageResolution test "
                "-only-testing:MirmirTests/R06ASHDecisionContextTests "
                "-only-testing:MirmirTests/R06ASHMasksAndAblationsTests "
                "-only-testing:MirmirTests/R06ASHOrchestratorTests "
                "-only-testing:MirmirTests/R06ASHPolicyCatalogTests "
                "-only-testing:MirmirTests/R06FunctionalPhaseAcceptanceTests "
                "-only-testing:MirmirTests/R07FunctionalCoordinatorTests "
                "-only-testing:MirmirTests/"
                "R07FunctionalCoordinatorTransactionTests "
                "'EXCLUDED_SOURCE_FILE_NAMES=*.metal' "
                "CODE_SIGNING_ALLOWED=NO"
            ),
            (
                "python3 Scripts/r06_phase_acceptance.py --check-xcresult "
                "/private/tmp/mirmir-r06-6c4a6d3d.xcresult"
            ),
            "- name: Verify checked-in R06 acceptance",
            "name: r06-functional-acceptance-xcresult",
        )
        for relative in (
            ".github/workflows/roadmap-alignment.yml",
            "Scripts/verify-mirmir-guardrails.sh",
        ):
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            required = common_required + (
                workflow_required
                if relative == ".github/workflows/roadmap-alignment.yml"
                else ()
            )
            for phrase in required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r06-phase-acceptance-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r06_xcode_run_uses_exact_checkpoint_worktree(self) -> None:
        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        materialize = (
            "- name: Materialize exact R06 source checkpoint\n"
            "        run: git worktree add --detach "
            "/private/tmp/mirmir-r06-6c4a6d3d-source "
            "6c4a6d3d5f8a59c553b10c23783c148ccb3388a5"
        )
        run = (
            "- name: Run exact R06 selected tests\n"
            "        working-directory: "
            "/private/tmp/mirmir-r06-6c4a6d3d-source"
        )
        validate = (
            "- name: Validate raw R06 xcresult\n"
            "        if: ${{ always() }}\n"
            "        run: python3 Scripts/r06_phase_acceptance.py "
            "--check-xcresult /private/tmp/mirmir-r06-6c4a6d3d.xcresult"
        )
        verify = (
            "- name: Verify checked-in R06 acceptance\n"
            "        if: ${{ always() }}\n"
            "        run: python3 Scripts/r06_phase_acceptance.py --check"
        )
        upload = (
            "- name: Upload raw R06 xcresult\n"
            "        if: ${{ always() }}\n"
            "        uses: actions/upload-artifact@"
            "ea165f8d65b6e75b540449e92b4886f43607fa02"
        )
        artifact_path = "path: /private/tmp/mirmir-r06-6c4a6d3d.xcresult"
        for phrase in (materialize, run, validate, verify, upload, artifact_path):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, workflow)
        self.assertLess(workflow.index(materialize), workflow.index(run))
        self.assertLess(workflow.index(run), workflow.index(validate))
        self.assertLess(workflow.index(validate), workflow.index(verify))
        self.assertLess(workflow.index(verify), workflow.index(upload))

    def test_r07_contract_commands_are_required_in_ci_and_guardrails(self) -> None:
        common_required = (
            "Scripts/tests/test_r07_contracts.py",
            "python3 Scripts/r07_contracts.py --check-preregistration",
            "python3 Scripts/r07_contracts.py --check-fixtures",
        )
        path_specific_required = {
            ".github/workflows/roadmap-alignment.yml": (
                "python3 Scripts/r07_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r07/records/"
                "temporal-artifact-conformance.json ]]; then",
            ),
            "Scripts/verify-mirmir-guardrails.sh": (
                "python3 Scripts/r07_contracts.py --check-conformance",
                "if [[ -f docs/roadmaps/evidence/r07/records/"
                "temporal-artifact-conformance.json ]]; then",
            ),
            "docs/governance/roadmap-alignment.md": (
                "test ! -f docs/roadmaps/evidence/r07/records/"
                "temporal-artifact-conformance.json || python3 Scripts/r07_contracts.py "
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
                        original.replace(phrase, "removed-r07-contract-command", 1),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

        acceptance_required = (
            "Scripts/tests/test_r07_phase_acceptance.py",
            "python3 Scripts/r07_phase_acceptance.py --check",
        )
        for relative in (
            ".github/workflows/roadmap-alignment.yml",
            "Scripts/verify-mirmir-guardrails.sh",
        ):
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            for phrase in acceptance_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r07-phase-acceptance-command",
                            1,
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

    def test_r10_closure_checks_are_present_in_ci_and_guardrails(
        self,
    ) -> None:
        common_required = (
            "validation/calibration_v2/tests/test_r10_optimizer.py",
            "validation/calibration_v2/tests/test_r10_persistence.py",
            "validation/calibration_v2/tests/test_run_r10_fixture_calibration.py",
            "Scripts/tests/test_r10_contracts.py",
            "Scripts/tests/test_r10_phase_acceptance.py",
            "python3 Scripts/r10_phase_acceptance.py --check-generated",
            "python3 Scripts/r10_phase_acceptance.py --check",
            "python3 Scripts/r10_contracts.py --all",
        )
        workflow_required = (
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r10-functional-acceptance.result }}" '
                '= "success"'
            ),
            "r10-functional-acceptance:",
            "name: R10 functional acceptance",
            "runs-on: ubuntu-latest",
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r10-3a76c6a-source "
                "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r10-3a76c6a-source"
            ),
            (
                "git rev-parse HEAD | grep -Fx "
                "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b"
            ),
            (
                "git rev-parse HEAD^{tree} | grep -Fx "
                "37951da694ab4fbca6f8c663bb2883e5084b861c"
            ),
            (
                "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v "
                "validation.calibration_v2.tests.test_r10_optimizer "
                "validation.calibration_v2.tests.test_r10_persistence"
            ),
            (
                "PYTHONDONTWRITEBYTECODE=1 python3 "
                "validation/calibration_v2/tools/"
                "run_r10_fixture_calibration.py --source-commit "
                "3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b --output-root "
                "/private/tmp/mirmir-r10-3a76c6a-calibration-run"
            ),
            (
                "diff --recursive --no-dereference "
                "/private/tmp/mirmir-r10-3a76c6a-calibration-run/checkpoints "
                "docs/roadmaps/evidence/r10/records/artifacts/"
                "functional-phase-acceptance/calibration-run/checkpoints"
            ),
            (
                "diff --recursive --no-dereference "
                "/private/tmp/mirmir-r10-3a76c6a-calibration-run/"
                "frozen-policies docs/roadmaps/evidence/r10/records/artifacts/"
                "functional-phase-acceptance/calibration-run/frozen-policies"
            ),
            (
                "cmp /private/tmp/mirmir-r10-3a76c6a-calibration-run/"
                "run-receipt.json docs/roadmaps/evidence/r10/records/artifacts/"
                "functional-phase-acceptance/calibration-run/run-receipt.json"
            ),
            "test -d /private/tmp/mirmir-r10-3a76c6a-calibration-run/terminals",
            "grep -Fx 39",
        )
        guardrail_required = (
            (
                'r10_source_commit='
                '"3a76c6a03ea0f52f2a2395925badd5d5d1c03c6b"'
            ),
            (
                'r10_source_tree='
                '"37951da694ab4fbca6f8c663bb2883e5084b861c"'
            ),
            (
                'git worktree add --detach "$r10_source_worktree" '
                '"$r10_source_commit"'
            ),
            'git rev-parse HEAD | grep -Fx "$r10_source_commit"',
            'git rev-parse HEAD^{tree} | grep -Fx "$r10_source_tree"',
            'grep -c \' \\.\\.\\. ok$\' "$r10_test_log" | grep -Fx 39',
            "diff --recursive --no-dereference",
            "cleanup_r10_validation",
            "trap cleanup_r10_validation EXIT",
        )
        requirements = {
            ".github/workflows/roadmap-alignment.yml": workflow_required,
            "Scripts/verify-mirmir-guardrails.sh": guardrail_required,
        }
        for relative, specific_required in requirements.items():
            text = (self.root / relative).read_text(encoding="utf-8")
            for phrase in common_required + specific_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, text)

        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        ordered_steps = (
            "- name: Materialize exact R10 source checkpoint",
            "- name: Verify exact R10 source identity",
            "- name: Run exact R10 selected tests",
            "- name: Run exact R10 fixture calibration",
            "- name: Compare exact R10 fixture calibration closure",
            "- name: Validate generated R10 acceptance evidence",
            "- name: Verify checked-in R10 acceptance",
            "- name: Verify deep R10 contracts",
        )
        positions = [workflow.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(workflow.count("  r10-functional-acceptance:"), 1)

    def test_r11_closure_checks_are_required_in_ci_and_guardrails(self) -> None:
        test_modules = (
            "validation/calibration_v2/tests/test_r11_traceability.py",
            "validation/calibration_v2/tests/"
            "test_run_r11_fixture_traceability.py",
            "Scripts/tests/test_r11_contracts.py",
            "Scripts/tests/test_r11_phase_acceptance.py",
        )
        common_required = (
            "python3 Scripts/r11_phase_acceptance.py --check-generated",
            "python3 Scripts/r11_phase_acceptance.py --check",
            "python3 Scripts/r11_contracts.py --all",
        )
        workflow_required = (
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r11-functional-acceptance.result }}" '
                '= "success"'
            ),
            "r11-functional-acceptance:",
            "name: R11 functional acceptance",
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r11-75479b9-source "
                "75479b9f30511330f2a18b656151dc551292cb1e"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r11-75479b9-source"
            ),
            (
                "git rev-parse HEAD | grep -Fx "
                "75479b9f30511330f2a18b656151dc551292cb1e"
            ),
            (
                "git rev-parse HEAD^{tree} | grep -Fx "
                "0dd42ec30b212456223ee582b549de30a0e3416f"
            ),
            (
                "grep -c ' \\.\\.\\. ok$' "
                "/private/tmp/mirmir-r11-75479b9-unittest.log | grep -Fx 76"
            ),
            (
                "validation/calibration_v2/tools/"
                "run_r11_fixture_traceability.py"
            ),
            (
                "docs/roadmaps/evidence/r11/records/"
                "traceability-run-receipt.json"
            ),
            (
                "docs/roadmaps/evidence/r11/records/artifacts/"
                "functional-phase-acceptance/traceability-run-receipt.json"
            ),
        )
        guardrail_required = (
            'guardrail_temp_base_requested="${TMPDIR:-/tmp}"',
            '"$guardrail_temp_base_requested" != /*',
            'cd -- "$guardrail_temp_base_requested"',
            "pwd -P",
            '"$guardrail_temp_base" != /*',
            "readonly guardrail_temp_base",
            (
                'mktemp -d "$guardrail_temp_base/'
                'mirmir-r10-acceptance.XXXXXX"'
            ),
            (
                'mktemp -d "$guardrail_temp_base/'
                'mirmir-r11-acceptance.XXXXXX"'
            ),
            (
                'mktemp -d "$guardrail_temp_base/'
                'mirmir-r12-acceptance.XXXXXX"'
            ),
            (
                'r11_source_commit='
                '"75479b9f30511330f2a18b656151dc551292cb1e"'
            ),
            (
                'r11_source_tree='
                '"0dd42ec30b212456223ee582b549de30a0e3416f"'
            ),
            (
                'git worktree add --detach "$r11_source_worktree" '
                '"$r11_source_commit"'
            ),
            'git rev-parse HEAD | grep -Fx "$r11_source_commit"',
            'git rev-parse HEAD^{tree} | grep -Fx "$r11_source_tree"',
            'grep -c \' \\.\\.\\. ok$\' "$r11_test_log" | grep -Fx 76',
            "cleanup_r11_validation",
            "trap cleanup_r11_validation EXIT",
        )
        requirements = {
            ".github/workflows/roadmap-alignment.yml": workflow_required,
            "Scripts/verify-mirmir-guardrails.sh": guardrail_required,
        }
        for relative, specific_required in requirements.items():
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            aggregate_start = original.index("python3 -m unittest")
            aggregate_end = original.index(
                "python3 Scripts/roadmap_alignment.py --check",
                aggregate_start,
            )
            aggregate = original[aggregate_start:aggregate_end]

            for module in test_modules:
                with self.subTest(relative=relative, module=module):
                    self.assertIn(module, aggregate)
            for phrase in common_required + specific_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)
            if relative == "Scripts/verify-mirmir-guardrails.sh":
                self.assertEqual(
                    original.count(
                        'guardrail_temp_base_requested="${TMPDIR:-/tmp}"'
                    ),
                    1,
                )
                self.assertNotIn(
                    'mktemp -d "${TMPDIR:-/tmp}/mirmir-r1',
                    original,
                )

            for phrase in test_modules + common_required + specific_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(
                        phrase,
                        self.policy["required_phrases"][relative],
                    )
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r11-closure-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        ordered_steps = (
            "- name: Materialize exact R11 source checkpoint",
            "- name: Verify exact R11 source identity",
            "- name: Run exact R11 selected tests",
            "- name: Run exact R11 traceability fixture",
            "- name: Compare exact R11 traceability closure",
            "- name: Validate generated R11 acceptance evidence",
            "- name: Verify checked-in R11 acceptance",
            "- name: Verify deep R11 contracts",
        )
        positions = [workflow.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(workflow.count("  r11-functional-acceptance:"), 1)

    def test_r12_closure_checks_are_required_in_ci_and_guardrails(self) -> None:
        test_module = "Scripts/tests/test_r12_phase_acceptance.py"
        common_required = (
            "python3 Scripts/r12_phase_acceptance.py --check-generated",
            "python3 Scripts/r12_phase_acceptance.py --check",
        )
        workflow_required = (
            (
                "needs: [r02-functional-acceptance, "
                "r04-functional-acceptance, r05-functional-acceptance, "
                "r06-functional-acceptance, r10-functional-acceptance, "
                "r11-functional-acceptance, r12-functional-acceptance]"
            ),
            (
                'test "${{ needs.r12-functional-acceptance.result }}" '
                '= "success"'
            ),
            "r12-functional-acceptance:",
            "name: R12 functional acceptance",
            "runs-on: macos-26",
            (
                "git worktree add --detach "
                "/private/tmp/mirmir-r12-2f5e298-source "
                "2f5e2987fe6a0e88d39790f177c717b62d29d6e4"
            ),
            (
                "working-directory: "
                "/private/tmp/mirmir-r12-2f5e298-source"
            ),
            (
                "git rev-parse HEAD | grep -Fx "
                "2f5e2987fe6a0e88d39790f177c717b62d29d6e4"
            ),
            (
                "git rev-parse HEAD^{tree} | grep -Fx "
                "4971b4d38f92ea5edffe925e507f058e9ffc13d8"
            ),
            (
                "git merge-base --is-ancestor "
                "3f31f7aa5bfc9e01eb1124f0f9db7b8ea6e17ff6 HEAD"
            ),
            (
                "xcodebuild build-for-testing -project Mirmir.xcodeproj "
                "-scheme Mirmir"
            ),
            (
                "xcodebuild test-without-building -xctestrun "
                '"$r12_xctestrun"'
            ),
            "-only-testing:MirmirTests/R12MediaFormatContractV2Tests",
            "-only-testing:MirmirTests/R12RouteAndHardwareResolverTests",
            "-only-testing:MirmirTests/R12ChunkCheckpointLedgerTests",
            (
                "R12_ACCEPTANCE_SOURCE_COMMIT="
                "2f5e2987fe6a0e88d39790f177c717b62d29d6e4"
            ),
            (
                "R12_ACCEPTANCE_SOURCE_TREE="
                "4971b4d38f92ea5edffe925e507f058e9ffc13d8"
            ),
            "67a175f14ab43688022ca72f84b956cd7081ed1972e3fb52bf9cef57af831080",
            "09c6e370dcba37e39141477b254005a40aedc9e79a9d9e83c7667b7b7bf1af27",
        )
        guardrail_required = (
            (
                'r12_source_commit='
                '"2f5e2987fe6a0e88d39790f177c717b62d29d6e4"'
            ),
            (
                'r12_source_tree='
                '"4971b4d38f92ea5edffe925e507f058e9ffc13d8"'
            ),
            (
                'git worktree add --detach "$r12_source_worktree" '
                '"$r12_source_commit"'
            ),
            'git rev-parse HEAD | grep -Fx "$r12_source_commit"',
            'git rev-parse HEAD^{tree} | grep -Fx "$r12_source_tree"',
            "-only-testing:MirmirTests/R12MediaFormatContractV2Tests",
            "-only-testing:MirmirTests/R12RouteAndHardwareResolverTests",
            "-only-testing:MirmirTests/R12ChunkCheckpointLedgerTests",
            "grep -Fx 85",
            "cleanup_r12_validation",
            "trap cleanup_r12_validation EXIT",
            "3f31f7aa5bfc9e01eb1124f0f9db7b8ea6e17ff6",
            "67a175f14ab43688022ca72f84b956cd7081ed1972e3fb52bf9cef57af831080",
            "09c6e370dcba37e39141477b254005a40aedc9e79a9d9e83c7667b7b7bf1af27",
        )
        requirements = {
            ".github/workflows/roadmap-alignment.yml": workflow_required,
            "Scripts/verify-mirmir-guardrails.sh": guardrail_required,
        }
        for relative, specific_required in requirements.items():
            path = self.root / relative
            original = path.read_text(encoding="utf-8")
            aggregate_start = original.index("python3 -m unittest")
            aggregate_end = original.index(
                "python3 Scripts/roadmap_alignment.py --check",
                aggregate_start,
            )
            aggregate = original[aggregate_start:aggregate_end]
            self.assertIn(test_module, aggregate)
            for phrase in common_required + specific_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(phrase, original)

            for phrase in (test_module,) + common_required + specific_required:
                with self.subTest(relative=relative, phrase=phrase):
                    self.assertIn(
                        phrase,
                        self.policy["required_phrases"][relative],
                    )
                    path.write_text(
                        original.replace(
                            phrase,
                            "removed-r12-closure-command",
                        ),
                        encoding="utf-8",
                    )
                    self.assert_error_contains(
                        f"required alignment text is missing: {phrase!r}"
                    )
                    path.write_text(original, encoding="utf-8")

        workflow = (
            self.root / ".github/workflows/roadmap-alignment.yml"
        ).read_text(encoding="utf-8")
        ordered_steps = (
            "- name: Materialize exact R12 source checkpoint",
            "- name: Verify exact R12 source identity",
            "- name: Verify R12 evidence checkpoint ancestry",
            "- name: Build exact R12 selected-test product",
            "- name: Run exact R12 selected tests",
            "- name: Validate generated R12 acceptance evidence",
            "- name: Verify checked-in R12 acceptance",
        )
        positions = [workflow.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(workflow.count("  r12-functional-acceptance:"), 1)

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
                    original.replace(phrase, "removed-r04-closure-state"),
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
