#!/usr/bin/env python3
"""Tests for the closed P06 production-source provenance identity."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY = SCRIPT_DIRECTORY.parent.parent
CONTRACT = SCRIPT_DIRECTORY / "p06-source-provenance-v1.json"
SPEC = importlib.util.spec_from_file_location(
    "p06_source_identity_v4", SCRIPT_DIRECTORY / "p06_source_identity_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
source_identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source_identity)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class P06SourceIdentityTests(unittest.TestCase):
    def test_repository_contract_is_closed_and_reproducible(self) -> None:
        first = source_identity.build_manifest(REPOSITORY, CONTRACT)
        second = source_identity.build_manifest(REPOSITORY, CONTRACT)
        self.assertEqual(first, second)
        self.assertEqual(first["sourceCount"], 53)
        self.assertRegex(first["sourceRevision"], r"^[0-9a-f]{64}$")
        paths = [entry["path"] for entry in first["sources"]]
        for required in (
            "Mirmir/Domain/MediaTrackGraphPlannerV4.swift",
            "Mirmir/MediaIO/AVFoundationTrackGraphAdapterV4.swift",
            "Mirmir/Modules/UpscalerEngine/AlphaProcessingV4.swift",
            "Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift",
            "Mirmir/Persistence/WorkflowSegmentCheckpointStoreV4.swift",
            "Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift",
        ):
            self.assertIn(required, paths)

    def test_deployment_trust_root_values_do_not_create_a_circular_identity(self) -> None:
        zero = b'''enum ASHProductionP06TrustRootV4 {
    static let manifestSHA256 = try! ASHSHA256V4(String(repeating: "0", count: 64))
    static let sourceRevision = String(repeating: "0", count: 40)
    static let builderSourceSHA256 = try! ASHSHA256V4(String(repeating: "0", count: 64))
}\n'''
        configured = f'''enum ASHProductionP06TrustRootV4 {{
    static let manifestSHA256 = try! ASHSHA256V4("{'1' * 64}")
    static let sourceRevision = "{'2' * 64}"
    static let builderSourceSHA256 = try! ASHSHA256V4("{'3' * 64}")
}}\n'''.encode()
        normalized_zero, assignments_zero = source_identity.normalize_trust_roots(zero)
        normalized_configured, assignments_configured = source_identity.normalize_trust_roots(configured)
        self.assertEqual(normalized_zero, normalized_configured)
        self.assertEqual(assignments_zero, assignments_configured)

    def test_new_unlisted_v4_source_fails_the_closed_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            root = repository / "Sources"
            root.mkdir()
            trust = root / "TrustV4.swift"
            trust.write_text(
                '''static let manifestSHA256 = try! ASHSHA256V4(String(repeating: "0", count: 64))
static let sourceRevision = String(repeating: "0", count: 40)
static let builderSourceSHA256 = try! ASHSHA256V4(String(repeating: "0", count: 64))
''',
                encoding="utf-8",
            )
            contract = {
                "schemaVersion": source_identity.CONTRACT_SCHEMA,
                "identityDomain": "ash-p06-production-source-v1",
                "coverage": {
                    "roots": ["Sources"],
                    "fileExtensions": [".swift"],
                    "fileNameToken": "V4",
                },
                "requiredAdditionalSources": [],
                "normalizedDeploymentTrustRoot": {
                    "path": "Sources/TrustV4.swift",
                    "assignments": [
                        "builderSourceSHA256",
                        "manifestSHA256",
                        "sourceRevision",
                    ],
                },
                "sources": ["Sources/TrustV4.swift"],
            }
            contract_path = repository / "contract.json"
            write_json(contract_path, contract)
            source_identity.build_manifest(repository, contract_path)
            (root / "NewKernelV4.swift").write_text("let value = 1\n", encoding="utf-8")
            with self.assertRaisesRegex(source_identity.SourceIdentityError, "source closure mismatch"):
                source_identity.build_manifest(repository, contract_path)

    def test_manifest_replay_rejects_stale_source_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest_path = Path(temporary) / "manifest.json"
            manifest_path.write_bytes(
                source_identity.canonical_bytes(
                    source_identity.build_manifest(REPOSITORY, CONTRACT)
                )
            )
            verified = source_identity.validate_manifest(manifest_path, REPOSITORY, CONTRACT)
            self.assertEqual(verified["sourceCount"], 53)
            document = json.loads(manifest_path.read_text())
            document["sourceRevision"] = "0" * 64
            manifest_path.write_bytes(source_identity.canonical_bytes(document))
            with self.assertRaisesRegex(source_identity.SourceIdentityError, "does not reproduce"):
                source_identity.validate_manifest(manifest_path, REPOSITORY, CONTRACT)


if __name__ == "__main__":
    unittest.main()
