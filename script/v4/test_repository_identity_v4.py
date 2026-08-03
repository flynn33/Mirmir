#!/usr/bin/env python3
"""Tests for deterministic v4 repository identity enforcement."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "repository_identity_v4",
    SCRIPT_DIRECTORY / "repository_identity_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identity)


class RepositoryIdentityTests(unittest.TestCase):
    def testManifestIdentityUsesCanonicalDomainSeparation(self) -> None:
        document = {"z": 2, "a": 1}
        expected = hashlib.sha256(
            b"ash-p06-runtime-manifest-v4\0{\"a\":1,\"z\":2}"
        ).hexdigest()
        self.assertEqual(identity.manifest_identity(document), expected)

    def testEvidenceManifestDetectsTamperAndMissingArtifact(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-evidence-identity-") as temporary:
            root = Path(temporary)
            artifact = root / "capture.json"
            artifact.write_bytes(b"verified")
            manifest = root / "evidence-manifest.json"
            write_json(
                manifest,
                {
                    "schemaVersion": "mirmir-v4-evidence-manifest-v1",
                    "sourceCommit": "a" * 40,
                    "sourceDescribe": "fixture",
                    "artifactCount": 1,
                    "artifacts": [
                        {
                            "path": "capture.json",
                            "byteCount": 8,
                            "sha256": sha256(artifact),
                        }
                    ],
                    "tools": [],
                },
            )
            self.assertEqual(identity.verify_evidence_manifest(manifest), 1)
            artifact.write_bytes(b"tampered")
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "SHA-256 mismatch"):
                identity.verify_evidence_manifest(manifest)
            artifact.unlink()
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "missing evidence artifact"):
                identity.verify_evidence_manifest(manifest)

    def testCorpusLockBindsSelectionContractAndBuilder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-corpus-identity-") as temporary:
            repository = Path(temporary)
            scripts = repository / "script/v4"
            scripts.mkdir(parents=True)
            bindings = {
                "sourceSelectionSHA256": scripts / "natural-quality-sources-v1.json",
                "qualityContractSHA256": scripts / "quality-gate-release-contract-v1.json",
                "builderSourceSHA256": scripts / "build_natural_quality_corpus.py",
            }
            for index, path in enumerate(bindings.values()):
                path.write_bytes(f"binding-{index}".encode())
            lock = {
                "schemaVersion": "mirmir-ash-v4-natural-quality-corpus-lock-v1",
                "releaseEligible": True,
                "corpusID": "fixture-corpus",
                "clipCount": 1,
                "caseCount": 1,
                "manifestSHA256": "1" * 64,
                "artifactSetSHA256": "2" * 64,
                "sourceAssetSetSHA256": "3" * 64,
                "sourceLicenseSetSHA256": "4" * 64,
            }
            lock.update({field: sha256(path) for field, path in bindings.items()})
            write_json(scripts / "natural-quality-corpus-lock-v1.json", lock)
            report = identity.verify_corpus_lock(repository)
            self.assertEqual(report["corpusID"], "fixture-corpus")
            bindings["qualityContractSHA256"].write_bytes(b"changed")
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "binding is stale"):
                identity.verify_corpus_lock(repository)

    def testTrustRootParserRejectsMissingOrDuplicateAssignments(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-trust-root-") as temporary:
            path = Path(temporary) / "Trust.swift"
            path.write_text(trust_source("1" * 64, "2" * 64, "3" * 64))
            self.assertEqual(identity.parse_deployment_trust_roots(path)["sourceRevision"], "2" * 64)
            path.write_text(path.read_text() + '\nstatic let sourceRevision = "4' + "4" * 63 + '"\n')
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "absent or repeated"):
                identity.parse_deployment_trust_roots(path)

    def testUnsafeEvidencePathIsRejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-unsafe-evidence-") as temporary:
            root = Path(temporary)
            manifest = root / "evidence-manifest.json"
            write_json(
                manifest,
                {
                    "schemaVersion": "mirmir-v4-evidence-manifest-v1",
                    "artifactCount": 1,
                    "artifacts": [
                        {"path": "../escape", "byteCount": 1, "sha256": "0" * 64}
                    ],
                },
            )
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "safe relative path"):
                identity.verify_evidence_manifest(manifest)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def trust_source(manifest: str, source: str, builder: str) -> str:
    return f'''enum Trust {{
    static let manifestSHA256 = try! ASHSHA256V4(
        "{manifest}"
    )
    static let sourceRevision =
        "{source}"
    static let builderSourceSHA256 = try! ASHSHA256V4(
        "{builder}"
    )
}}
'''


if __name__ == "__main__":
    unittest.main()
