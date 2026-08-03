#!/usr/bin/env python3
"""Tests for deterministic v4 repository identity enforcement."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY = SCRIPT_DIRECTORY.parent.parent
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

    def testP05EvidenceManifestVerifiesItsArtifactSet(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p05-evidence-identity-") as temporary:
            root = Path(temporary)
            first = root / "first.bin"
            second = root / "second.bin"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            artifacts = [
                {
                    "path": path.name,
                    "byteCount": path.stat().st_size,
                    "sha256": sha256(path),
                }
                for path in (first, second)
            ]
            manifest = root / "evidence-manifest.json"
            write_json(
                manifest,
                {
                    "schemaVersion": "mirmir-v4-p05-evidence-manifest-v3",
                    "artifactCount": len(artifacts),
                    "artifactSetSHA256": identity.artifact_set_identity(
                        (artifact["path"], artifact["sha256"])
                        for artifact in artifacts
                    ),
                    "artifacts": artifacts,
                },
            )
            self.assertEqual(identity.verify_evidence_manifest(manifest), 2)
            document = json.loads(manifest.read_text())
            document["artifactSetSHA256"] = "0" * 64
            write_json(manifest, document)
            with self.assertRaisesRegex(
                identity.RepositoryIdentityError,
                "artifact-set mismatch",
            ):
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
                    "sourceCommit": "a" * 40,
                    "sourceDescribe": "fixture",
                    "artifactCount": 1,
                    "artifacts": [
                        {"path": "../escape", "byteCount": 1, "sha256": "0" * 64}
                    ],
                    "tools": [],
                },
            )
            with self.assertRaisesRegex(identity.RepositoryIdentityError, "safe relative path"):
                identity.verify_evidence_manifest(manifest)

    def testShippingEntryPointMutationsInvalidateCheckedInP06Runtime(self) -> None:
        targets = (
            "Mirmir/Upscaling/FrameUpscaler.swift",
            "Mirmir/MediaIO/OutputMediaValidator.swift",
            "Mirmir/MediaIO/VideoProbe.swift",
            "Mirmir/Upscaling/UpscaleBackendCatalog.swift",
        )
        with tempfile.TemporaryDirectory(prefix="mirmir-p06-runtime-identity-") as temporary:
            repository = Path(temporary)
            shutil.copytree(REPOSITORY / "Mirmir", repository / "Mirmir")
            scripts = repository / "script/v4"
            scripts.mkdir(parents=True)
            shutil.copyfile(
                SCRIPT_DIRECTORY / "p06-source-provenance-v1.json",
                scripts / "p06-source-provenance-v1.json",
            )
            source_revision = identity.source_identity_module().build_manifest(
                repository,
                scripts / "p06-source-provenance-v1.json",
            )["sourceRevision"]
            runtime_manifest_path = (
                repository / "Mirmir/Resources/ASH-P06.bundle/runtime-manifest.json"
            )
            runtime_manifest = json.loads(runtime_manifest_path.read_text())
            runtime_manifest["provenance"]["sourceRevision"] = source_revision
            runtime_manifest_path.write_bytes(identity.canonical_bytes(runtime_manifest))
            runtime_manifest_identity = identity.manifest_identity(runtime_manifest)
            trust_path = (
                repository
                / "Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift"
            )
            trust = trust_path.read_text()
            replacements = {
                "manifestSHA256": runtime_manifest_identity,
                "sourceRevision": source_revision,
            }
            for name, value in replacements.items():
                if name == "sourceRevision":
                    pattern = re.compile(
                        r'(static let sourceRevision\s*=\s*)"[0-9a-f]{40,64}"',
                        re.MULTILINE,
                    )
                    replacement = lambda match, value=value: match.group(1) + f'"{value}"'
                else:
                    pattern = re.compile(
                        rf'(static let {name}\s*=\s*try!\s*ASHSHA256V4\(\s*)'
                        r'"[0-9a-f]{64}"',
                        re.MULTILINE,
                    )
                    replacement = lambda match, value=value: match.group(1) + f'"{value}"'
                trust, count = pattern.subn(replacement, trust)
                self.assertEqual(count, 1)
            trust_path.write_text(trust)
            identity.verify_runtime_bundle(repository)
            for relative in targets:
                with self.subTest(relative=relative):
                    path = repository / relative
                    original = path.read_bytes()
                    path.write_bytes(original + b"\n// stale-P06 mutation\n")
                    with self.assertRaisesRegex(
                        identity.RepositoryIdentityError,
                        "runtime source revision does not match production source closure",
                    ):
                        identity.verify_runtime_bundle(repository)
                    path.write_bytes(original)


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
