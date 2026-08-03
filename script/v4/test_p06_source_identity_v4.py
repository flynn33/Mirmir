#!/usr/bin/env python3
"""Tests for the closed P06 production-source provenance identity."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
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
        expected = sorted(
            path.relative_to(REPOSITORY).as_posix()
            for path in (REPOSITORY / "Mirmir").rglob("*")
            if path.is_file() and path.suffix in {".swift", ".metal"}
        )
        self.assertEqual(first["sourceCount"], len(expected))
        self.assertRegex(first["sourceRevision"], r"^[0-9a-f]{64}$")
        paths = [entry["path"] for entry in first["sources"]]
        self.assertEqual(paths, expected)
        for required in (
            "Mirmir/MediaIO/OutputMediaValidator.swift",
            "Mirmir/MediaIO/VideoProbe.swift",
            "Mirmir/Upscaling/FrameUpscaler.swift",
            "Mirmir/Upscaling/UpscaleBackendCatalog.swift",
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

    def test_new_unlisted_shipping_source_fails_the_closed_inventory(self) -> None:
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
            (root / "NewKernel.swift").write_text("let value = 1\n", encoding="utf-8")
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
            self.assertEqual(
                verified["sourceCount"],
                len(source_identity.build_manifest(REPOSITORY, CONTRACT)["sources"]),
            )
            document = json.loads(manifest_path.read_text())
            document["sourceRevision"] = "0" * 64
            manifest_path.write_bytes(source_identity.canonical_bytes(document))
            with self.assertRaisesRegex(source_identity.SourceIdentityError, "does not reproduce"):
                source_identity.validate_manifest(manifest_path, REPOSITORY, CONTRACT)

    def test_shipping_entry_point_mutations_change_identity_and_stale_manifest_fails(
        self,
    ) -> None:
        targets = (
            "Mirmir/Upscaling/FrameUpscaler.swift",
            "Mirmir/MediaIO/OutputMediaValidator.swift",
            "Mirmir/MediaIO/VideoProbe.swift",
            "Mirmir/Upscaling/UpscaleBackendCatalog.swift",
        )
        with tempfile.TemporaryDirectory(prefix="mirmir-p06-source-closure-") as temporary:
            repository = Path(temporary)
            shutil.copytree(REPOSITORY / "Mirmir", repository / "Mirmir")
            baseline = source_identity.build_manifest(repository, CONTRACT)
            manifest_path = repository / "production-source-manifest.json"
            manifest_path.write_bytes(source_identity.canonical_bytes(baseline))
            for relative in targets:
                with self.subTest(relative=relative):
                    path = repository / relative
                    original = path.read_bytes()
                    path.write_bytes(original + b"\n// source-identity mutation\n")
                    changed = source_identity.build_manifest(repository, CONTRACT)
                    self.assertNotEqual(
                        changed["sourceRevision"], baseline["sourceRevision"]
                    )
                    with self.assertRaisesRegex(
                        source_identity.SourceIdentityError, "does not reproduce"
                    ):
                        source_identity.validate_manifest(
                            manifest_path, repository, CONTRACT
                        )
                    path.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
