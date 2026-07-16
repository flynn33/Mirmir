from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.p07.gate import build_g07_artifacts
from validation.calibration_v2.tests.test_p07_gate import (
    _measurement,
    _psnr,
    _rehash,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = (
    CALIBRATION_ROOT / "contracts/instruction-conflict-normalization-v1.json"
)
SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/instruction-conflict-normalization-v1.schema.json"
)

EXPECTED_IDS = (
    "p07_failed_version_archive_failure_only",
    "p08_canonical_metal_parity_artifact",
    "p08_media_plan_interface_boundary",
    "p11_macos_xcode_targets_and_swift_oracle",
    "p11_visual_studio_evidence_normalization",
    "p11_macos_conformance_destination_normalization",
)
EXPECTED_PACKAGE_MANIFEST_SHA256 = (
    "bac31029e2aa0e9ef89cb25f36c9cfd9ac5ce0920e546bd3dea0edea06520afd"
)
EXPECTED_SOURCE_HASHES = {
    "config/audit_gates.json": (
        "29e39a673a899e5f4a7ade676de685c5aed8f04b2e0807f06eebc62595e455dc"
    ),
    "config/execution_phases.json": (
        "cd09a5757b84c349df31e13080f6818672404a64c784f3068d492bbd6decdb36"
    ),
    "config/implementation_components.json": (
        "fa60e4625a328cd071ca66e8bce3937659a39fe8eff72b26c344ada7115da334"
    ),
    "instructions/00_MASTER_EXECUTION_DIRECTIVE.md": (
        "1a1f75c785f91b764e55f66bdd7880a237b1ae710351474d9dc8a7a4a6018800"
    ),
    "instructions/11_XCODE_MACOS_CONFORMANCE_AND_REPRODUCIBILITY.md": (
        "f427e11d18807aaac352e1e33402a41d49f041465c93e6ebf789412f5f10001a"
    ),
    "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md": (
        "439e908d0d64caf53142927fc804e292c0848de9aecf404d8c4651c03dd17328"
    ),
}
EXPECTED_REFERENCES = {
    "p07_failed_version_archive_failure_only": (
        ("config/execution_phases.json", 105, 116, "conflicting"),
        (
            "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md",
            169,
            180,
            "controlling",
        ),
    ),
    "p08_canonical_metal_parity_artifact": (
        ("config/execution_phases.json", 119, 131, "controlling"),
        ("config/implementation_components.json", 379, 424, "conflicting"),
    ),
    "p08_media_plan_interface_boundary": (
        ("config/implementation_components.json", 292, 359, "conflicting"),
        ("config/execution_phases.json", 119, 144, "controlling"),
        (
            "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md",
            182,
            205,
            "controlling",
        ),
    ),
    "p11_macos_xcode_targets_and_swift_oracle": (
        (
            "instructions/11_XCODE_MACOS_CONFORMANCE_AND_REPRODUCIBILITY.md",
            3,
            27,
            "conflicting",
        ),
        (
            "instructions/00_MASTER_EXECUTION_DIRECTIVE.md",
            64,
            79,
            "controlling",
        ),
    ),
    "p11_visual_studio_evidence_normalization": (
        ("config/execution_phases.json", 162, 174, "conflicting"),
        (
            "instructions/11_XCODE_MACOS_CONFORMANCE_AND_REPRODUCIBILITY.md",
            41,
            56,
            "controlling",
        ),
        (
            "instructions/00_MASTER_EXECUTION_DIRECTIVE.md",
            64,
            79,
            "controlling",
        ),
    ),
    "p11_macos_conformance_destination_normalization": (
        (
            "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md",
            213,
            217,
            "conflicting",
        ),
        ("config/audit_gates.json", 167, 180, "conflicting"),
        (
            "instructions/11_XCODE_MACOS_CONFORMANCE_AND_REPRODUCIBILITY.md",
            41,
            56,
            "controlling",
        ),
    ),
}


class InstructionConflictNormalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw_contract = CONTRACT_PATH.read_bytes()
        cls.contract = json.loads(cls.raw_contract)
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def test_schema_canonical_bytes_and_self_hash(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        Draft202012Validator(self.schema).validate(self.contract)
        self.assertEqual(
            self.raw_contract,
            canonical_json_bytes(self.contract) + b"\n",
        )
        payload = dict(self.contract)
        observed = payload.pop("manifest_sha256")
        self.assertEqual(
            observed,
            hashlib.sha256(canonical_json_bytes(payload)).hexdigest(),
        )

    def test_exact_unique_resolutions_and_source_bindings(self) -> None:
        self.assertEqual(
            self.contract["source_package_manifest_sha256"],
            EXPECTED_PACKAGE_MANIFEST_SHA256,
        )
        resolutions = self.contract["resolutions"]
        ids = tuple(row["id"] for row in resolutions)
        self.assertEqual(ids, EXPECTED_IDS)
        self.assertEqual(len(ids), len(set(ids)))
        decisions = [canonical_json_bytes(row["decision"]) for row in resolutions]
        self.assertEqual(len(decisions), len(set(decisions)))

        authority = self.contract["authority"]
        self.assertEqual(
            (
                authority["path"],
                authority["line_start"],
                authority["line_end"],
                authority["role"],
            ),
            (
                "instructions/00_MASTER_EXECUTION_DIRECTIVE.md",
                9,
                20,
                "authority",
            ),
        )
        self.assertEqual(
            authority["sha256"],
            EXPECTED_SOURCE_HASHES[authority["path"]],
        )

        observed_paths = {authority["path"]}
        for row in resolutions:
            observed = tuple(
                (
                    reference["path"],
                    reference["line_start"],
                    reference["line_end"],
                    reference["role"],
                )
                for reference in row["source_references"]
            )
            self.assertEqual(observed, EXPECTED_REFERENCES[row["id"]])
            for reference in row["source_references"]:
                path = PurePosixPath(reference["path"])
                self.assertFalse(path.is_absolute())
                self.assertNotIn("..", path.parts)
                self.assertLessEqual(reference["line_start"], reference["line_end"])
                self.assertEqual(
                    reference["sha256"],
                    EXPECTED_SOURCE_HASHES[reference["path"]],
                )
                observed_paths.add(reference["path"])
        self.assertEqual(observed_paths, set(EXPECTED_SOURCE_HASHES))

    def test_p07_resolution_matches_existing_success_and_failure_semantics(self) -> None:
        resolution = self.contract["resolutions"][0]
        self.assertEqual(resolution["decision"]["emission"], "failure_only")

        measurement, policy = _measurement()
        success = build_g07_artifacts(
            measurements=measurement,
            locked_metric_policy=policy,
        )
        self.assertTrue(success["g07-decision.json"]["evidence"]["pass"])
        self.assertNotIn("failed-version-archive.json", success)

        failure_measurement = copy.deepcopy(measurement)
        for row in failure_measurement["corpus_rows"]:
            row["metrics_by_control"]["full_ash"]["y_psnr_db"] = _psnr(28.0)
            row["metrics_by_control"]["full_ash"][
                "writer_y_psnr_contribution_db"
            ] = None if row["comparison_domain"] == "engine_raw" else 0.0
            row["metrics_by_control"]["state_plus_branch"] = copy.deepcopy(
                row["metrics_by_control"]["full_ash"]
            )
        _rehash(failure_measurement)
        failure = build_g07_artifacts(
            measurements=failure_measurement,
            locked_metric_policy=policy,
        )
        self.assertFalse(failure["g07-decision.json"]["evidence"]["pass"])
        self.assertIn("failed-version-archive.json", failure)
        self.assertFalse(
            failure["failed-version-archive.json"]["evidence"][
                "same_version_reuse_permitted"
            ]
        )


if __name__ == "__main__":
    unittest.main()
