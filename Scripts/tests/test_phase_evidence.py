from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import (  # noqa: E402
    COMMON_REQUIRED_VERIFICATION_CATEGORIES,
    MAX_EVIDENCE_FILE_BYTES,
    PHASE_CLOSURE_PREDECESSORS,
    PHASE_OUTCOME_DISPOSITIONS,
    PhaseEvidenceVerifier,
    R01_CAPABILITY_DISPOSITIONS,
    R01_CAPABILITY_IDS,
    R01_REQUIRED_SOURCE_PATHS,
    R01_WAIVER_LIMITATION,
    R01_WAIVER_REQUIRED_SOURCE_PATHS,
    VERIFICATION_CATEGORY_OUTPUT_KINDS,
    main,
    render_phase_evidence,
)
from r01_observation_waiver import (  # noqa: E402
    build_matrix as build_waiver_matrix,
    render_markdown as render_waiver_markdown,
)
from r01_preregistration import FIXTURE_CATALOG_PATH  # noqa: E402


AUTHORIZATIONS = {
    "capability_lab": "authorized_after_current_source_inventory",
    "core_ai_pixel_residual": "authorized_for_r09_bounded_experiment",
    "holdout": "blocked",
    "market_leading_claim": "blocked",
    "observation_gates": "hardware_unavailable_simulator_and_operator_observation_waived_not_a_blocker",
    "production_auto_mode": "blocked",
    "strategic_reset": "authorized",
    "unified_backend_architecture": "authorized_after_capability_contracts",
}


class PhaseEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.schema_path = (
            self.root
            / "docs/roadmaps/evidence/schema/phase-evidence-manifest-v1.json"
        )
        self.manifest_path = (
            self.root / "docs/roadmaps/evidence/r01/phase-evidence.json"
        )
        self.summary_path = (
            self.root / "docs/roadmaps/evidence/r01/phase-evidence.md"
        )
        self.preregistration_path = (
            self.root
            / "docs/roadmaps/evidence/r01/records/preregistration.json"
        )
        self.fixture_path = (
            self.root / "docs/roadmaps/evidence/r01/records/fixture.bin"
        )
        self.fixture_catalog_path = self.root / FIXTURE_CATALOG_PATH
        self.output_paths = {
            "anchor-oldest-supported": self.root
            / "project-notes/evidence/r01/hosts/anchor-oldest-supported.json",
            "anchor-m3-air": self.root
            / "project-notes/evidence/r01/hosts/anchor-m3-air.json",
            "anchor-pro-max": self.root
            / "project-notes/evidence/r01/hosts/anchor-pro-max.json",
            "anchor-core-ai": self.root
            / "project-notes/evidence/r01/hosts/anchor-core-ai.json",
            "capability-report": self.root
            / "project-notes/apple-upscale-capability-report.md",
            "capability-json": self.root
            / "project-notes/apple-upscale-capabilities.json",
        }
        self.output_path = self.output_paths["capability-json"]
        self.lfs_pointer_path = self.root / "project-notes/lfs-pointer.txt"
        self.private_record_path = (
            self.root / "project-notes/private-host-record.json"
        )
        self.consent_receipt_path = (
            self.root / "project-notes/model-acquisition-consent.json"
        )
        self.swift_probe_test_path = (
            self.root / "MirmirTests/AppleUpscaleCapabilityProbeTests.swift"
        )
        self.required_r01_source_paths = tuple(
            self.root / relative
            for relative in dict.fromkeys(
                (*R01_REQUIRED_SOURCE_PATHS, *R01_WAIVER_REQUIRED_SOURCE_PATHS)
            )
        )
        self.command_source_paths = (
            self.root / "Scripts/phase_evidence.py",
            self.root / "Scripts/r01_capabilities.py",
            self.root / "Scripts/r01_observation_waiver.py",
            self.root / "Scripts/run-r01-capability-probe.sh",
            self.root / "Scripts/verify-mirmir-guardrails.sh",
        )
        self.verification_output_paths = {
            category: self.root
            / f"project-notes/verification/{category}-result.json"
            for category in COMMON_REQUIRED_VERIFICATION_CATEGORIES
        }
        self.verification_command_ids = {
            "json": ["guardrail"],
            "lint": ["swiftlint"],
            "unit_test": ["unit-tests"],
            "mutation_test": ["mutation-tests"],
            "repository": ["diff-check"],
            "dependency_scan": ["guardrail"],
            "project_generation": ["project-generation"],
            "build": ["debug-build", "release-build"],
            "hosted_test": ["guardrail"],
            "evidence_integrity": ["phase-evidence-check"],
        }
        for path in (
            self.schema_path,
            self.manifest_path,
            self.preregistration_path,
            self.fixture_catalog_path,
            self.fixture_path,
            self.lfs_pointer_path,
            self.private_record_path,
            self.consent_receipt_path,
            *self.required_r01_source_paths,
            *self.command_source_paths,
            *self.output_paths.values(),
            *self.verification_output_paths.values(),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(
            REPOSITORY_ROOT
            / "docs/roadmaps/evidence/schema/phase-evidence-manifest-v1.json",
            self.schema_path,
        )
        waiver_schema_path = (
            self.root
            / "docs/roadmaps/evidence/schema/r01-observation-waiver-v1.json"
        )
        waiver_schema_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(
            REPOSITORY_ROOT
            / "docs/roadmaps/evidence/schema/r01-observation-waiver-v1.json",
            waiver_schema_path,
        )
        shutil.copy2(
            REPOSITORY_ROOT
            / "docs/roadmaps/evidence/r01/records/preregistration.json",
            self.preregistration_path,
        )
        shutil.copy2(
            REPOSITORY_ROOT / FIXTURE_CATALOG_PATH,
            self.fixture_catalog_path,
        )
        self.fixture_path.write_bytes(b"\x00\xffdeterministic-fixture\x80")
        for identifier, path in self.output_paths.items():
            if path.suffix == ".md":
                path.write_text("# Deterministic capability report\n", encoding="utf-8")
            else:
                path.write_text(
                    json.dumps({"id": identifier}, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
        self.lfs_pointer_path.write_text(
            "version https://git-lfs.github.com/spec/v1\n"
            "oid sha256:0000000000000000000000000000000000000000000000000000000000000000\n"
            "size 1\n",
            encoding="utf-8",
        )
        self.private_record_path.write_text(
            '{"serial_number":"PRIVATE","source":"/Users/operator/private"}\n',
            encoding="utf-8",
        )
        self.consent_receipt_path.write_text(
            '{"consent":"recorded"}\n', encoding="utf-8"
        )
        self.swift_probe_test_path.write_text(
            "import XCTest\nfinal class AppleUpscaleCapabilityProbeTests: XCTestCase {}\n",
            encoding="utf-8",
        )
        for path in self.command_source_paths:
            path.write_text("#!/usr/bin/env sh\nexit 0\n", encoding="utf-8")
            path.chmod(0o755)
        for path in self.required_r01_source_paths:
            if not path.exists():
                path.write_text("// deterministic R01 source fixture\n", encoding="utf-8")
        for category, path in self.verification_output_paths.items():
            path.write_text(
                json.dumps(
                    {
                        "schema_version": "1.0",
                        "category": category,
                        "command_ids": self.verification_command_ids[category],
                        "status": "passed",
                        "exit_status": 0,
                        "summary": f"Deterministic {category} test evidence.",
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
        roadmap_path = (
            self.root
            / "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
        )
        roadmap_path.parent.mkdir(parents=True, exist_ok=True)
        roadmap_path.write_text(
            json.dumps(
                {
                    "roadmap_version": "1.0.1",
                    "authorizations": AUTHORIZATIONS,
                    "apple_methods": json.loads(
                        (
                            REPOSITORY_ROOT
                            / "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
                        ).read_text(encoding="utf-8")
                    )["apple_methods"],
                    "phases": [
                        {"id": "R00", "status": "passed"},
                        {"id": "R01", "status": "in_progress"},
                    ],
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        self.git("init", "-q")
        self.git("config", "user.name", "Mirmir Tests")
        self.git("config", "user.email", "mirmir-tests@example.invalid")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "source evidence")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.manifest = self.valid_manifest()
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            self.fail(
                f"git {' '.join(arguments)} failed: {result.stderr or result.stdout}"
            )
        return result

    def binding(self, path: Path) -> dict[str, object]:
        payload = path.read_bytes()
        return {
            "path": path.relative_to(self.root).as_posix(),
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    @staticmethod
    def authorization_records() -> list[dict[str, str]]:
        return [
            {"id": identifier, "value": value}
            for identifier, value in AUTHORIZATIONS.items()
        ]

    def valid_manifest(self) -> dict[str, object]:
        hosts = [
            {
                "host_id": "oldest-supported-host",
                "roles": ["oldest-supported"],
                "hardware_classes": ["apple_silicon"],
                "model_identifier": "Mac14,2",
                "chip": "Apple M2",
                "memory_bytes": 16 * 1024 * 1024 * 1024,
                "os_version": "15.4",
                "os_build": "24E248",
                "xcode_version": "16.3",
                "xcode_build": "16E140",
                "sdk_version": "15.4",
                "source_commit": self.commit,
            },
            {
                "host_id": "m3-air-host",
                "roles": ["m3-air"],
                "hardware_classes": ["apple_silicon", "macbook_air"],
                "model_identifier": "Mac15,12",
                "chip": "Apple M3",
                "memory_bytes": 16 * 1024 * 1024 * 1024,
                "os_version": "26.5.2",
                "os_build": "25F84",
                "xcode_version": "26.2",
                "xcode_build": "17C52",
                "sdk_version": "26.2",
                "source_commit": self.commit,
            },
            {
                "host_id": "pro-max-host",
                "roles": ["pro-max"],
                "hardware_classes": ["apple_silicon", "pro_max_tier"],
                "model_identifier": "Mac16,7",
                "chip": "Apple M4 Pro",
                "memory_bytes": 48 * 1024 * 1024 * 1024,
                "os_version": "26.5.2",
                "os_build": "25F84",
                "xcode_version": "26.2",
                "xcode_build": "17C52",
                "sdk_version": "26.2",
                "source_commit": self.commit,
            },
            {
                "host_id": "core-ai-host",
                "roles": ["core-ai"],
                "hardware_classes": ["apple_silicon", "core_ai_capable"],
                "model_identifier": "Mac16,1",
                "chip": "Apple M4 Max",
                "memory_bytes": 64 * 1024 * 1024 * 1024,
                "os_version": "27.0",
                "os_build": "26A1",
                "xcode_version": "27.0",
                "xcode_build": "18A1",
                "sdk_version": "27.0",
                "source_commit": self.commit,
            },
        ]
        output_kinds = {
            "anchor-oldest-supported": "host_record",
            "anchor-m3-air": "host_record",
            "anchor-pro-max": "host_record",
            "anchor-core-ai": "host_record",
            "capability-report": "report",
            "capability-json": "report",
        }
        outputs = [
            {
                "id": identifier,
                "kind": output_kinds[identifier],
                "binding": self.binding(path),
                "generated_summary": False,
                "redistributable": True,
                "contains_holdout_pixels": False,
                "system_asset": False,
            }
            for identifier, path in self.output_paths.items()
        ]
        for category, path in self.verification_output_paths.items():
            output_kind = next(iter(VERIFICATION_CATEGORY_OUTPUT_KINDS[category]))
            outputs.append(
                {
                    "id": f"{category}-result",
                    "kind": output_kind,
                    "binding": self.binding(path),
                    "generated_summary": False,
                    "redistributable": True,
                    "contains_holdout_pixels": False,
                    "system_asset": False,
                }
            )
        verification_checks = [
            {
                "id": f"{category}-check",
                "category": category,
                "required": True,
                "status": "passed",
                "command_ids": self.verification_command_ids[category],
                "output_ids": [f"{category}-result"],
                "reason": None,
            }
            for category in sorted(COMMON_REQUIRED_VERIFICATION_CATEGORIES)
        ]

        def gate_command(command_id: str, argv: list[str]) -> dict[str, object]:
            return {
                "command_id": command_id,
                "host_id": "pro-max-host",
                "argv": argv,
                "environment_flags": [],
                "started_at": "2026-07-19T12:00:04-05:00",
                "ended_at": "2026-07-19T12:00:05-05:00",
                "exit_status": 0,
                "result": "passed",
                "skip_reason": None,
                "consent_receipt": None,
            }

        gate_commands = [
            gate_command("guardrail", ["Scripts/verify-mirmir-guardrails.sh"]),
            gate_command(
                "swiftlint",
                ["swiftlint", "lint", "--strict", "--config", ".swiftlint.yml"],
            ),
            gate_command(
                "unit-tests",
                [
                    "python3",
                    "-m",
                    "unittest",
                    "Scripts/tests/test_roadmap_alignment.py",
                ],
            ),
            gate_command(
                "mutation-tests",
                [
                    "python3",
                    "-m",
                    "unittest",
                    "Scripts/tests/test_phase_evidence.py",
                ],
            ),
            gate_command("diff-check", ["git", "diff", "--check"]),
            gate_command("project-generation", ["xcodegen", "generate"]),
            gate_command(
                "debug-build",
                [
                    "xcodebuild",
                    "-project",
                    "Mirmir.xcodeproj",
                    "-scheme",
                    "Mirmir",
                    "-configuration",
                    "Debug",
                    "-disableAutomaticPackageResolution",
                    "build",
                ],
            ),
            gate_command(
                "release-build",
                [
                    "xcodebuild",
                    "-project",
                    "Mirmir.xcodeproj",
                    "-scheme",
                    "Mirmir",
                    "-configuration",
                    "Release",
                    "-disableAutomaticPackageResolution",
                    "build",
                ],
            ),
            gate_command(
                "phase-evidence-check",
                [
                    "python3",
                    "Scripts/phase_evidence.py",
                    "--phase",
                    "R01",
                    "--check",
                ],
            ),
        ]
        return {
            "schema_version": "1.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R01",
            "source": {"commit": self.commit, "tree": self.tree},
            "hosts": hosts,
            "preregistration": {
                "record": self.binding(self.preregistration_path),
                "inputs": [
                    {
                        "id": "fixture-input",
                        "kind": "repository_fixture",
                        "identity": "deterministic test fixture",
                        "binding": self.binding(self.fixture_path),
                        "limitations": [],
                    },
                    {
                        "id": "fixture-catalog-input",
                        "kind": "repository_fixture",
                        "identity": "R01 fixture and model catalog",
                        "binding": self.binding(self.fixture_catalog_path),
                        "limitations": [
                            "The analysis probe model may remain unassigned."
                        ],
                    },
                ],
                "fixtures": [
                    {
                        "id": "fixture",
                        "role": "deterministic test fixture",
                        "binding": self.binding(self.fixture_path),
                        "redistributable": True,
                    }
                ],
                "parameters": [
                    {"id": "session-count", "value": 3, "unit": "sessions"}
                ],
                "metrics": [
                    {
                        "id": "wall-time",
                        "unit": "seconds",
                        "direction": "observation_only",
                        "applicability": "all probes",
                    }
                ],
                "floors": [
                    {
                        "metric_id": "wall-time",
                        "comparison": "not_applicable",
                        "value": None,
                        "scope": "capability measurement only",
                    }
                ],
                "stop_rules": [
                    {"id": "identity-drift", "description": "Stop on identity drift."}
                ],
                "disposition_subjects": [
                    {
                        "subject_id": subject_id,
                        "allowed_values": list(R01_CAPABILITY_DISPOSITIONS),
                    }
                    for subject_id in R01_CAPABILITY_IDS
                ],
            },
            "commands": [
                *[
                    {
                        "command_id": f"{anchor}-probe",
                        "host_id": host_id,
                        "argv": [
                            "Scripts/run-r01-capability-probe.sh",
                            "--anchor",
                            anchor,
                            "--output",
                            self.output_paths[f"anchor-{anchor}"]
                            .relative_to(self.root)
                            .as_posix(),
                        ],
                        "environment_flags": [
                            {"name": "MIRMIR_R01_LIVE_PROBES", "value": "1"}
                        ],
                        "started_at": "2026-07-19T12:00:00-05:00",
                        "ended_at": "2026-07-19T12:00:01-05:00",
                        "exit_status": 0,
                        "result": "passed",
                        "skip_reason": None,
                        "consent_receipt": None,
                    }
                    for anchor, host_id in (
                        ("oldest-supported", "oldest-supported-host"),
                        ("m3-air", "m3-air-host"),
                        ("pro-max", "pro-max-host"),
                        ("core-ai", "core-ai-host"),
                    )
                ],
                {
                    "command_id": "capability-check",
                    "host_id": "pro-max-host",
                    "argv": ["python3", "Scripts/r01_capabilities.py", "--check"],
                    "environment_flags": [],
                    "started_at": "2026-07-19T12:00:02-05:00",
                    "ended_at": "2026-07-19T12:00:03-05:00",
                    "exit_status": 0,
                    "result": "passed",
                    "skip_reason": None,
                    "consent_receipt": None,
                },
                *gate_commands,
            ],
            "outputs": outputs,
            "verification": {"checks": verification_checks},
            "result": {
                "status": "passed",
                "disposition": "passed",
                "phase_status_before": "in_progress",
                "phase_status_after": "passed",
                "summary": "The deterministic test evidence is complete.",
                "dispositions": [
                    {
                        "subject_id": subject_id,
                        "value": "runnable",
                        "reason": "The deterministic contract fixture is runnable.",
                    }
                    for subject_id in R01_CAPABILITY_IDS
                ],
            },
            "authorizations": {
                "before": self.authorization_records(),
                "after": self.authorization_records(),
                "proposed_decisions": [],
            },
            "limitations": [],
        }

    def convert_to_observation_waiver(self) -> None:
        implementation_commit = self.commit
        matrix = build_waiver_matrix(
            self.root,
            implementation_commit,
            "2026-07-20T12:00:00Z",
        )
        self.output_paths["capability-json"].write_text(
            json.dumps(matrix, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.output_paths["capability-report"].write_text(
            render_waiver_markdown(matrix),
            encoding="utf-8",
        )
        for identifier, path in self.output_paths.items():
            if identifier.startswith("anchor-"):
                path.unlink()
        self.git(
            "add",
            "-A",
            self.output_paths["capability-json"].relative_to(self.root).as_posix(),
            self.output_paths["capability-report"].relative_to(self.root).as_posix(),
            "project-notes/evidence/r01/hosts",
        )
        self.git("commit", "-q", "-m", "R01 waiver outputs")
        evidence_commit = self.git("rev-parse", "HEAD").stdout.strip()
        evidence_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        executor = copy.deepcopy(self.manifest["hosts"][2])
        executor["roles"] = ["verification-executor"]
        executor["source_commit"] = implementation_commit
        self.manifest["hosts"] = [executor]
        self.manifest["source"] = {
            "commit": evidence_commit,
            "tree": evidence_tree,
        }
        self.manifest["commands"] = [
            command
            for command in self.manifest["commands"]
            if not (
                command["argv"][0] == "Scripts/run-r01-capability-probe.sh"
                or command["argv"]
                == ["python3", "Scripts/r01_capabilities.py", "--check"]
            )
        ]
        for command in self.manifest["commands"]:
            command["host_id"] = executor["host_id"]
        self.manifest["commands"].insert(
            0,
            {
                "command_id": "capability-waiver-check",
                "host_id": executor["host_id"],
                "argv": [
                    "python3",
                    "Scripts/r01_observation_waiver.py",
                    "--check",
                ],
                "environment_flags": [],
                "started_at": "2026-07-20T12:00:00Z",
                "ended_at": "2026-07-20T12:00:01Z",
                "exit_status": 0,
                "result": "passed",
                "skip_reason": None,
                "consent_receipt": None,
            },
        )
        retained_output_ids = {
            "capability-json",
            "capability-report",
            *{
                f"{category}-result"
                for category in COMMON_REQUIRED_VERIFICATION_CATEGORIES
            },
        }
        self.manifest["outputs"] = [
            output
            for output in self.manifest["outputs"]
            if output["id"] in retained_output_ids
        ]
        for output in self.manifest["outputs"]:
            if output["id"] == "capability-json":
                output["binding"] = self.binding(
                    self.output_paths["capability-json"]
                )
            elif output["id"] == "capability-report":
                output["binding"] = self.binding(
                    self.output_paths["capability-report"]
                )
        for disposition in self.manifest["result"]["dispositions"]:
            disposition["value"] = "diagnostic_only"
            disposition["reason"] = "Operation was not observed under the operator waiver."
        self.manifest["result"]["summary"] = (
            "Inventory coverage is closed with every capability explicitly not observed."
        )
        self.manifest["limitations"] = [R01_WAIVER_LIMITATION]
        self.commit = evidence_commit
        self.tree = evidence_tree
        self.write_manifest()

    def write_manifest(self, *, write_summary: bool = True) -> None:
        self.manifest_path.write_text(
            json.dumps(self.manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        if write_summary:
            self.summary_path.write_text(
                render_phase_evidence(self.manifest), encoding="utf-8"
            )

    def verifier(self) -> PhaseEvidenceVerifier:
        return PhaseEvidenceVerifier(self.root, "R01")

    def assert_error_contains(self, fragment: str) -> None:
        self.write_manifest(write_summary=False)
        errors = self.verifier().check()
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected error containing {fragment!r}; found {errors!r}",
        )

    def test_valid_manifest_passes_with_binary_binding(self) -> None:
        self.assertEqual(self.verifier().check(), [])

    def test_invalid_requested_phase_fails_closed(self) -> None:
        verifier = PhaseEvidenceVerifier(
            self.root,
            "R99",
            manifest_path=self.manifest_path,
            summary_path=self.summary_path,
            schema_path=self.schema_path,
        )
        errors = verifier.check()
        self.assertTrue(
            any("requested phase must be one of" in error for error in errors),
            errors,
        )

    def test_extra_top_level_field_fails(self) -> None:
        self.manifest["quality_claim"] = True
        self.assert_error_contains("manifest fields differ from the closed schema")

    def test_missing_top_level_field_fails(self) -> None:
        del self.manifest["limitations"]
        self.assert_error_contains("manifest fields differ from the closed schema")

    def test_duplicate_json_key_fails(self) -> None:
        text = self.manifest_path.read_text(encoding="utf-8")
        self.manifest_path.write_text(
            text.replace(
                '"schema_version": "1.0",',
                '"schema_version": "1.0",\n  "schema_version": "1.0",',
                1,
            ),
            encoding="utf-8",
        )
        errors = self.verifier().check()
        self.assertTrue(any("duplicate JSON key" in error for error in errors), errors)

    def test_nonfinite_json_number_fails(self) -> None:
        text = self.manifest_path.read_text(encoding="utf-8")
        self.manifest_path.write_text(
            text.replace('"memory_bytes": 51539607552', '"memory_bytes": NaN'),
            encoding="utf-8",
        )
        errors = self.verifier().check()
        self.assertTrue(any("non-finite JSON number" in error for error in errors), errors)

    def test_tree_mismatch_fails(self) -> None:
        self.manifest["source"]["tree"] = "1" * 40
        self.assert_error_contains("source.tree does not match source.commit")

    def test_private_absolute_path_fails(self) -> None:
        self.manifest["limitations"] = ["Read /Users/operator/private/input.mov"]
        self.assert_error_contains("contains a private absolute path")

    def test_extra_host_identifier_fails(self) -> None:
        self.manifest["hosts"][0]["serial_number"] = "REDACTED"
        self.assert_error_contains("serial_number: field is not allowed")

    def test_malformed_host_role_fails_closed(self) -> None:
        self.manifest["hosts"][0]["roles"] = [{"unexpected": "object"}]
        self.assert_error_contains("$.hosts[0].roles[0]: value has the wrong JSON type")

    def test_host_source_mismatch_fails(self) -> None:
        self.manifest["hosts"][0]["source_commit"] = "1" * 40
        self.assert_error_contains("source_commit is not an available commit")

    def test_host_implementation_commit_can_precede_evidence_commit(self) -> None:
        implementation_commit = self.commit
        self.git("commit", "--allow-empty", "-q", "-m", "evidence checkpoint")
        evidence_commit = self.git("rev-parse", "HEAD").stdout.strip()
        evidence_tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.manifest["source"] = {
            "commit": evidence_commit,
            "tree": evidence_tree,
        }
        self.assertTrue(
            all(
                host["source_commit"] == implementation_commit
                for host in self.manifest["hosts"]
            )
        )
        self.write_manifest()
        self.assertEqual(self.verifier().check(), [])

    def test_r01_hosts_must_share_implementation_commit(self) -> None:
        self.git("commit", "--allow-empty", "-q", "-m", "alternate host source")
        alternate_commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.manifest["source"] = {
            "commit": alternate_commit,
            "tree": self.git("rev-parse", "HEAD^{tree}").stdout.strip(),
        }
        self.manifest["hosts"][0]["source_commit"] = alternate_commit
        self.assert_error_contains("must share one published implementation commit")

    def test_path_traversal_fails(self) -> None:
        self.manifest["outputs"][0]["binding"]["path"] = "../outside.json"
        self.assert_error_contains("binding.path: string does not match")

    def test_nul_path_fails_closed(self) -> None:
        self.manifest["outputs"][0]["binding"]["path"] = "record\u0000.json"
        self.assert_error_contains("binding.path: string does not match")

    def test_canonicalized_duplicate_output_path_fails(self) -> None:
        duplicate = copy.deepcopy(self.manifest["outputs"][0]["binding"])
        duplicate["path"] = duplicate["path"].replace("/hosts/", "/hosts//")
        self.manifest["outputs"][1]["binding"] = duplicate
        self.assert_error_contains("output paths must be unique")

    def test_binding_hash_mismatch_fails(self) -> None:
        self.manifest["outputs"][0]["binding"]["sha256"] = "1" * 64
        self.assert_error_contains("sha256 differs from repository file")

    def test_binding_size_mismatch_fails(self) -> None:
        self.manifest["outputs"][0]["binding"]["size_bytes"] += 1
        self.assert_error_contains("size_bytes differs")

    def test_git_lfs_pointer_binding_fails(self) -> None:
        self.manifest["outputs"][0]["binding"] = self.binding(
            self.lfs_pointer_path
        )
        self.assert_error_contains("prohibited Git LFS pointer")

    def test_file_limit_fails(self) -> None:
        self.manifest["outputs"][0]["binding"]["size_bytes"] = (
            MAX_EVIDENCE_FILE_BYTES + 1
        )
        self.assert_error_contains("binding.size_bytes: number exceeds the maximum")

    def test_unbound_phase_evidence_file_fails(self) -> None:
        unbound_path = (
            self.root / "docs/roadmaps/evidence/r01/records/unbound.json"
        )
        unbound_path.write_text('{"unbound":true}\n', encoding="utf-8")
        self.assert_error_contains("phase evidence file is not manifest-bound")

    def test_bound_private_record_fails(self) -> None:
        self.manifest["outputs"][0]["binding"] = self.binding(
            self.private_record_path
        )
        self.assert_error_contains("serial_number is a prohibited private field")

    def test_external_receipt_requires_binding(self) -> None:
        item = self.manifest["preregistration"]["inputs"][0]
        item["kind"] = "external_receipt"
        item["binding"] = None
        self.assert_error_contains("binding is required for external_receipt")

    def test_system_asset_rejects_repository_binding(self) -> None:
        self.manifest["preregistration"]["inputs"][0]["kind"] = "system_asset"
        self.assert_error_contains("binding must be null for system_asset")

    def test_fixture_must_be_redistributable(self) -> None:
        self.manifest["preregistration"]["fixtures"][0][
            "redistributable"
        ] = False
        self.assert_error_contains("redistributable: value differs from the required constant")

    def test_output_must_be_redistributable(self) -> None:
        self.manifest["outputs"][0]["redistributable"] = False
        self.assert_error_contains("redistributable: value differs from the required constant")

    def test_output_must_not_contain_holdout_pixels(self) -> None:
        self.manifest["outputs"][0]["contains_holdout_pixels"] = True
        self.assert_error_contains(
            "contains_holdout_pixels: value differs from the required constant"
        )

    def test_output_must_not_be_a_system_asset(self) -> None:
        self.manifest["outputs"][0]["system_asset"] = True
        self.assert_error_contains("system_asset: value differs from the required constant")

    def test_unknown_result_disposition_fails(self) -> None:
        self.manifest["result"]["disposition"] = "product-qualified"
        self.assert_error_contains("result.disposition: value is outside the closed enumeration")

    def test_phase_status_before_must_match_source_roadmap(self) -> None:
        self.manifest["result"]["phase_status_before"] = "next"
        self.assert_error_contains("differs from source roadmap")

    def test_nonblocked_result_must_propose_passed(self) -> None:
        self.manifest["result"]["phase_status_after"] = "in_progress"
        self.assert_error_contains("must propose phase passed")

    def test_direct_next_to_passed_closure_fails(self) -> None:
        self.manifest["result"]["phase_status_before"] = "next"
        self.assert_error_contains("accepted closure requires source phase status in_progress")

    def test_phase_closure_requires_passed_predecessor(self) -> None:
        roadmap_path = (
            self.root
            / "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
        )
        roadmap = json.loads(roadmap_path.read_text(encoding="utf-8"))
        roadmap["phases"][0]["status"] = "next"
        roadmap_path.write_text(
            json.dumps(roadmap, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.git("add", str(roadmap_path.relative_to(self.root)))
        self.git("commit", "-q", "-m", "make predecessor incomplete")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.manifest["source"] = {"commit": commit, "tree": tree}
        for host in self.manifest["hosts"]:
            host["source_commit"] = commit
        self.assert_error_contains("phase closure predecessors are not passed")

    def test_r06_closure_has_only_r05_as_direct_predecessor(self) -> None:
        self.assertEqual(PHASE_CLOSURE_PREDECESSORS["R06"], ("R05",))

    def test_r10_closure_combines_direct_and_practical_predecessors(self) -> None:
        self.assertEqual(
            PHASE_CLOSURE_PREDECESSORS["R10"],
            ("R07", "R09"),
        )

    def test_r06_result_vocabulary_remains_passed_or_blocked(self) -> None:
        self.assertEqual(
            PHASE_OUTCOME_DISPOSITIONS["R06"],
            {
                "passed": frozenset({"passed"}),
                "blocked": frozenset({"blocked"}),
            },
        )

    def test_r09_rejection_vocabulary_matches_comparison_free_roadmap(self) -> None:
        self.assertEqual(
            PHASE_OUTCOME_DISPOSITIONS["R09"]["rejected"],
            frozenset(
                {
                    "rejected_no_safe_residual_path",
                    "rejected_hallucination_risk",
                    "rejected_resource_cost",
                }
            ),
        )

    def test_r01_preregistration_requires_every_capability(self) -> None:
        self.manifest["preregistration"]["disposition_subjects"].pop()
        self.assert_error_contains("disposition subjects must be exactly A01-A18")

    def test_r01_capability_vocabulary_is_frozen(self) -> None:
        subject = self.manifest["preregistration"]["disposition_subjects"][0]
        subject["allowed_values"].remove("rejected")
        self.assert_error_contains("disposition vocabulary differs from the handoff")

    def test_malformed_metric_identifier_fails_closed(self) -> None:
        self.manifest["preregistration"]["metrics"][0]["id"] = ["wall-time"]
        self.assert_error_contains("metrics[0].id: value has the wrong JSON type")

    def test_floor_value_must_match_schema(self) -> None:
        self.manifest["preregistration"]["floors"][0]["value"] = {
            "unexpected": "object"
        }
        self.assert_error_contains("floors[0].value: value has the wrong JSON type")

    def test_nonblocked_result_dispositions_every_capability(self) -> None:
        self.manifest["result"]["dispositions"].pop()
        self.assert_error_contains("must disposition every preregistered subject")

    def test_result_disposition_value_uses_frozen_vocabulary(self) -> None:
        self.manifest["result"]["dispositions"][0]["value"] = "accepted"
        self.assert_error_contains("value is outside the frozen vocabulary")

    def test_malformed_result_disposition_fails_closed(self) -> None:
        self.manifest["result"]["dispositions"][0]["value"] = ["runnable"]
        self.assert_error_contains("dispositions[0].value: value has the wrong JSON type")

    def test_r01_requires_every_anchor_role(self) -> None:
        self.manifest["hosts"].pop(0)
        self.assert_error_contains("R01 is missing required anchor roles")

    def test_r01_not_observed_waiver_closure_passes_without_anchor_hosts(self) -> None:
        self.convert_to_observation_waiver()
        self.assertEqual(self.verifier().check(), [])

    def test_r01_not_observed_waiver_rejects_observed_anchor_role(self) -> None:
        self.convert_to_observation_waiver()
        self.manifest["hosts"][0]["roles"] = ["pro-max"]
        self.assert_error_contains("must not represent an executor as an observed anchor")

    def test_r01_not_observed_waiver_requires_exact_limitation(self) -> None:
        self.convert_to_observation_waiver()
        self.manifest["limitations"] = []
        self.assert_error_contains("missing the exact no-observation limitation")

    def test_r01_not_observed_waiver_rejects_live_flag(self) -> None:
        self.convert_to_observation_waiver()
        self.manifest["commands"][0]["environment_flags"] = [
            {"name": "MIRMIR_R01_LIVE_PROBES", "value": "1"}
        ]
        self.assert_error_contains("must not enable live or acquisition flags")

    def test_r01_not_observed_waiver_requires_diagnostic_dispositions(self) -> None:
        self.convert_to_observation_waiver()
        self.manifest["result"]["dispositions"][0]["value"] = "runnable"
        self.assert_error_contains("must disposition every capability diagnostic_only")

    def test_r01_not_observed_waiver_requires_exact_check_command(self) -> None:
        self.convert_to_observation_waiver()
        self.manifest["commands"][0]["argv"] = ["true"]
        self.assert_error_contains("exactly one passing observation-waiver check")

    def test_r01_not_observed_waiver_rejects_compile_claim(self) -> None:
        self.convert_to_observation_waiver()
        matrix_path = self.output_paths["capability-json"]
        matrix = json.loads(matrix_path.read_text(encoding="utf-8"))
        matrix["capabilities"][0]["anchor_records"][0][
            "compile_state"
        ] = "available"
        matrix_path.write_text(
            json.dumps(matrix, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.assert_error_contains("R01 waiver output validation")

    def test_r01_rejects_duplicate_anchor_roles(self) -> None:
        self.manifest["hosts"][1]["roles"].append("oldest-supported")
        self.assert_error_contains("R01 anchor roles are assigned more than once")

    def test_m3_anchor_requires_macbook_air_class(self) -> None:
        self.manifest["hosts"][1]["hardware_classes"] = ["apple_silicon"]
        self.assert_error_contains("m3-air anchor must record macbook_air hardware")

    def test_r01_requires_all_declared_outputs(self) -> None:
        self.manifest["outputs"] = [
            output
            for output in self.manifest["outputs"]
            if output["id"] != "capability-report"
        ]
        self.assert_error_contains("R01 required outputs are missing")

    def test_r01_requires_every_verification_category(self) -> None:
        self.manifest["verification"]["checks"].pop(0)
        self.assert_error_contains("required verification categories are missing")

    def test_r01_requires_each_exact_live_runner_command(self) -> None:
        self.manifest["commands"].pop(0)
        self.assert_error_contains("exactly one passing live-runner command")

    def test_r01_live_flag_rejects_other_commands(self) -> None:
        self.manifest["commands"][-1]["environment_flags"] = [
            {"name": "MIRMIR_R01_LIVE_PROBES", "value": "1"}
        ]
        self.assert_error_contains("does not use the sole live runner")

    def test_r01_runner_requires_live_flag(self) -> None:
        self.manifest["commands"][0]["environment_flags"] = []
        self.assert_error_contains("lacks the live-probe flag")

    def test_r01_runner_rejects_invalid_anchor(self) -> None:
        self.manifest["commands"][0]["argv"][2] = "unknown-anchor"
        self.assert_error_contains("uses an invalid anchor")

    def test_r01_runner_rejects_wrong_output(self) -> None:
        self.manifest["commands"][0]["argv"][4] = (
            "project-notes/evidence/r01/hosts/wrong.json"
        )
        self.assert_error_contains("uses the wrong output path")

    def test_r01_required_swift_deliverable_must_exist_at_source(self) -> None:
        self.swift_probe_test_path.unlink()
        self.git("add", "-u")
        self.git("commit", "-q", "-m", "remove required probe test")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.manifest["source"] = {"commit": commit, "tree": tree}
        for host in self.manifest["hosts"]:
            host["source_commit"] = commit
        self.assert_error_contains("required source deliverable is absent")

    def test_r01_required_runner_must_exist_at_source(self) -> None:
        runner_path = self.root / "Scripts/run-r01-capability-probe.sh"
        runner_path.unlink()
        self.git("add", "-u")
        self.git("commit", "-q", "-m", "remove required runner")
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.manifest["source"] = {"commit": commit, "tree": tree}
        for host in self.manifest["hosts"]:
            host["source_commit"] = commit
        self.assert_error_contains("required source deliverable is absent")

    def test_r01_authorization_change_fails(self) -> None:
        self.manifest["authorizations"]["after"][0]["value"] = "changed"
        self.assert_error_contains("does not authorize roadmap authorization changes")

    def test_authorization_before_drift_fails(self) -> None:
        self.manifest["authorizations"]["before"][0]["value"] = "changed"
        self.assert_error_contains("authorizations.before differs from source roadmap")

    def test_unbound_authorization_proposal_fails(self) -> None:
        self.manifest["authorizations"]["proposed_decisions"] = [
            "Change an authorization without its phase-specific binding."
        ]
        self.assert_error_contains("require a bound phase-specific authorization contract")

    def test_malformed_authorization_array_fails_closed(self) -> None:
        self.manifest["authorizations"]["before"] = None
        self.assert_error_contains("authorizations.before: value has the wrong JSON type")

    def test_unknown_command_host_fails(self) -> None:
        self.manifest["commands"][0]["host_id"] = "unknown-host"
        self.assert_error_contains("host_id does not reference a host")

    def test_malformed_command_host_fails_closed(self) -> None:
        self.manifest["commands"][0]["host_id"] = ["pro-max-host"]
        self.assert_error_contains("commands[0].host_id: value has the wrong JSON type")

    def test_non_array_commands_fail_closed(self) -> None:
        self.manifest["commands"] = None
        self.assert_error_contains("$.commands: value has the wrong JSON type")

    def test_repository_command_must_exist_at_source_commit(self) -> None:
        command = next(
            item
            for item in self.manifest["commands"]
            if item["command_id"] == "capability-check"
        )
        command["argv"] = ["python3", "Scripts/missing-r01-checker.py", "--check"]
        self.assert_error_contains("repository command is absent at source.commit")

    def test_passed_command_requires_zero_exit(self) -> None:
        self.manifest["commands"][0]["exit_status"] = 1
        self.assert_error_contains("passed with a nonzero exit_status")

    def test_skipped_command_requires_reason_and_null_exit(self) -> None:
        self.manifest["commands"][0]["result"] = "skipped"
        self.assert_error_contains("exit_status must be null when skipped")

    def test_model_acquisition_requires_live_probe_flag(self) -> None:
        self.manifest["commands"][0]["environment_flags"] = [
            {"name": "MIRMIR_R01_ALLOW_MODEL_ACQUISITION", "value": "1"}
        ]
        self.manifest["commands"][0]["consent_receipt"] = self.binding(
            self.consent_receipt_path
        )
        self.assert_error_contains("enables R01 model acquisition without live probes")

    def test_model_acquisition_requires_consent_receipt(self) -> None:
        self.manifest["commands"][0]["environment_flags"].append(
            {"name": "MIRMIR_R01_ALLOW_MODEL_ACQUISITION", "value": "1"}
        )
        self.assert_error_contains("consent_receipt is required for model acquisition")

    def test_environment_flag_value_must_equal_one(self) -> None:
        self.manifest["commands"][0]["environment_flags"][0]["value"] = "0"
        self.assert_error_contains("environment_flags[0].value: value differs")

    def test_space_separated_timestamp_is_not_rfc3339(self) -> None:
        self.manifest["commands"][0]["started_at"] = "2026-07-19 12:00:00-05:00"
        self.assert_error_contains("started_at: string is not an RFC 3339 timestamp")

    def test_unknown_verification_command_fails(self) -> None:
        self.manifest["verification"]["checks"][0]["command_ids"] = ["missing"]
        self.assert_error_contains("command_ids are unknown")

    def test_required_passed_check_requires_command_reference(self) -> None:
        self.manifest["verification"]["checks"][0]["command_ids"] = []
        self.assert_error_contains("has no command evidence")

    def test_required_passed_check_requires_output_reference(self) -> None:
        self.manifest["verification"]["checks"][0]["output_ids"] = []
        self.assert_error_contains("has no bound output evidence")

    def test_required_passed_check_rejects_failed_command(self) -> None:
        command = self.manifest["commands"][-1]
        command["result"] = "failed"
        command["exit_status"] = 1
        self.assert_error_contains("references commands that did not pass")

    def test_required_passed_check_requires_typed_output(self) -> None:
        check = self.manifest["verification"]["checks"][0]
        output_id = check["output_ids"][0]
        output = next(
            item for item in self.manifest["outputs"] if item["id"] == output_id
        )
        output["kind"] = "report"
        self.assert_error_contains("lacks category-appropriate output evidence")

    def test_required_check_rejects_unrelated_command(self) -> None:
        check = self.manifest["verification"]["checks"][0]
        check["command_ids"] = ["capability-check"]
        self.assert_error_contains("has no category-appropriate command")

    def test_build_check_requires_debug_and_release_commands(self) -> None:
        check = next(
            item
            for item in self.manifest["verification"]["checks"]
            if item["category"] == "build"
        )
        check["command_ids"] = ["debug-build"]
        self.assert_error_contains("must bind Debug and Release build commands")

    def test_verification_artifact_uses_closed_record(self) -> None:
        check = self.manifest["verification"]["checks"][0]
        output_id = check["output_ids"][0]
        output = next(
            item for item in self.manifest["outputs"] if item["id"] == output_id
        )
        artifact_path = self.root / output["binding"]["path"]
        artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
        del artifact["summary"]
        artifact_path.write_text(
            json.dumps(artifact, sort_keys=True) + "\n", encoding="utf-8"
        )
        output["binding"] = self.binding(artifact_path)
        self.assert_error_contains("artifact fields differ from the closed schema")

    def test_malformed_verification_category_fails_closed(self) -> None:
        self.manifest["verification"]["checks"][0]["category"] = []
        self.assert_error_contains("category: value is outside the closed enumeration")

    def test_passed_check_rejects_reason(self) -> None:
        self.manifest["verification"]["checks"][0]["reason"] = "unexpected"
        self.assert_error_contains("reason must be null when passed")

    def test_passed_result_requires_passing_checks(self) -> None:
        check = self.manifest["verification"]["checks"][0]
        check["status"] = "skipped"
        check["reason"] = "host unavailable"
        self.assert_error_contains("requires every required check to pass")

    def test_stale_summary_fails(self) -> None:
        self.summary_path.write_text("stale\n", encoding="utf-8")
        errors = self.verifier().check()
        self.assertTrue(any("summary is stale" in error for error in errors), errors)

    def test_blocked_manifest_can_record_no_live_execution(self) -> None:
        for identifier, path in self.output_paths.items():
            if identifier.startswith("anchor-"):
                path.unlink()
        self.manifest["hosts"] = []
        self.manifest["commands"] = []
        self.manifest["outputs"] = []
        self.manifest["verification"]["checks"] = [
            {
                "id": "anchor-availability",
                "category": "hosted_test",
                "required": True,
                "status": "skipped",
                "command_ids": [],
                "output_ids": [],
                "reason": "A required anchor is unavailable.",
            }
        ]
        self.manifest["result"] = {
            "status": "blocked",
            "disposition": "blocked",
            "phase_status_before": "in_progress",
            "phase_status_after": "in_progress",
            "summary": "Live execution is blocked before host access.",
            "dispositions": [],
        }
        self.manifest["limitations"] = ["A required anchor is unavailable."]
        self.write_manifest()
        self.assertEqual(self.verifier().check(), [])

    def test_blocked_manifest_cannot_invent_blocked_phase_status(self) -> None:
        self.manifest["result"]["status"] = "blocked"
        self.manifest["result"]["disposition"] = "blocked"
        self.manifest["result"]["phase_status_after"] = "blocked"
        self.assert_error_contains("cannot invent an unspecified roadmap status transition")

    def test_write_summary_is_idempotent_and_preserves_manifest(self) -> None:
        self.summary_path.write_text("stale\n", encoding="utf-8")
        original_manifest = self.manifest_path.read_bytes()
        arguments = ["--phase", "R01", "--root", str(self.root), "--write-summary"]
        self.assertEqual(main(arguments), 0)
        first_summary = self.summary_path.read_bytes()
        self.assertEqual(main(arguments), 0)
        self.assertEqual(self.summary_path.read_bytes(), first_summary)
        self.assertEqual(self.manifest_path.read_bytes(), original_manifest)

    def test_schema_contract_drift_fails(self) -> None:
        schema = json.loads(self.schema_path.read_text(encoding="utf-8"))
        schema["additionalProperties"] = True
        self.schema_path.write_text(
            json.dumps(schema, indent=2) + "\n", encoding="utf-8"
        )
        self.assert_error_contains("schema SHA-256 differs from version 1.0")


if __name__ == "__main__":
    unittest.main()
