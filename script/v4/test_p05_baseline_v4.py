#!/usr/bin/env python3
"""Clean-archive and substitution negatives for the frozen P05 baseline."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY = SCRIPT_DIRECTORY.parents[1]
SPEC = importlib.util.spec_from_file_location(
    "p05_baseline_v4", SCRIPT_DIRECTORY / "p05_baseline_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
p05 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p05)
sys.modules["p05_baseline_v4"] = p05

QUALITY_SPEC = importlib.util.spec_from_file_location(
    "quality_gate_v4_p05_tests", SCRIPT_DIRECTORY / "quality_gate_v4.py"
)
assert QUALITY_SPEC is not None and QUALITY_SPEC.loader is not None
quality = importlib.util.module_from_spec(QUALITY_SPEC)
QUALITY_SPEC.loader.exec_module(quality)

CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "capture_baseline_p05_tests", SCRIPT_DIRECTORY / "capture_baseline.py"
)
assert CAPTURE_SPEC is not None and CAPTURE_SPEC.loader is not None
capture = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(capture)


class P05BaselineV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest_path = (
            SCRIPT_DIRECTORY / "p05-baseline-source-manifest-v1.json"
        )
        self.contract_path = SCRIPT_DIRECTORY / "quality-gate-contract-v1.json"
        self.evidence_path = (
            REPOSITORY / "docs/v4/evidence/v3-p05-baseline-2026-08-02"
        )

    def extractFrozenArchive(self, destination: Path) -> None:
        destination.mkdir(parents=True)
        archive = destination.parent / f"{destination.name}.tar"
        with archive.open("wb") as stream:
            completed = subprocess.run(
                [
                    "git",
                    "-C",
                    str(REPOSITORY),
                    "archive",
                    "--format=tar",
                    p05.FROZEN_SOURCE_REVISION,
                ],
                stdout=stream,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr.decode("utf-8", errors="replace"),
        )
        subprocess.run(
            ["tar", "-xf", str(archive), "-C", str(destination)], check=True
        )

    def testCheckedManifestReproducesFromTwoCleanGitArchives(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p05-source-") as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            self.extractFrozenArchive(first)
            self.extractFrozenArchive(second)
            first_manifest = p05.validate_source_manifest(
                REPOSITORY, self.manifest_path, first
            )
            second_manifest = p05.validate_source_manifest(
                REPOSITORY, self.manifest_path, second
            )
            self.assertEqual(first_manifest, second_manifest)
            self.assertEqual(first_manifest["fileCount"], 397)
            self.assertEqual(
                first_manifest["sourceTreeIdentitySHA256"],
                "d9b89f1ca31c0d076826651b250459773bea0de11d7b0ffd12ac40451af7b69c",
            )
            checked_capture = json.loads(
                (self.evidence_path / "capture-manifest.json").read_text()
            )
            self.assertEqual(
                checked_capture["sourceIdentity"]["sourceTreeIdentitySHA256"],
                first_manifest["sourceTreeIdentitySHA256"],
            )

    def testCheckedM0EvidenceVerifiesAgainstFrozenGitTree(self) -> None:
        verified = capture.verify_baseline_evidence(
            self.evidence_path,
            REPOSITORY,
        )
        self.assertEqual(
            verified["sourceIdentity"]["sourceRevision"],
            p05.FROZEN_SOURCE_REVISION,
        )

    def testFullyResealedDirtyM0SourceClaimFails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p05-evidence-") as temporary:
            evidence = Path(temporary) / "evidence"
            shutil.copytree(self.evidence_path, evidence)
            environment_path = evidence / "environment.json"
            environment = json.loads(environment_path.read_text())
            environment["workingTreeStatus"] = ["M candidate-tree-source.swift"]
            capture.write_json(environment_path, environment)

            capture_path = evidence / "capture-manifest.json"
            capture_manifest = json.loads(capture_path.read_text())
            artifacts = capture.artifact_manifest(evidence)
            capture_manifest["artifacts"] = artifacts
            capture_manifest["artifactCount"] = len(artifacts)
            capture_manifest["artifactSetSHA256"] = capture.artifact_set_identity(
                artifacts
            )
            capture.write_json(capture_path, capture_manifest)
            capture.write_json(
                evidence / "evidence-manifest.json",
                capture.evidence_manifest(evidence),
            )

            with self.assertRaisesRegex(
                ValueError,
                "frozen clean archive",
            ):
                capture.verify_baseline_evidence(evidence, REPOSITORY)

    def testMutatingOnlyP05SourceFailsCleanArchiveIdentity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-p05-source-") as temporary:
            archive = Path(temporary) / "archive"
            self.extractFrozenArchive(archive)
            p05_source = (
                archive
                / "Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift"
            )
            p05_source.write_bytes(p05_source.read_bytes() + b"\n// mutation\n")
            with self.assertRaisesRegex(ValueError, "P05 archive (size|hash) mismatch"):
                p05.validate_source_manifest(
                    REPOSITORY, self.manifest_path, archive
                )

    def testCandidateCaptureCannotSupplyBaselineVariant(self) -> None:
        contract = json.loads(self.contract_path.read_text())
        identity = p05.frozen_identity(contract)
        digest = "a" * 64
        with tempfile.TemporaryDirectory(prefix="mirmir-p05-merge-") as temporary:
            root = Path(temporary)
            corpus = root / "corpus.json"
            corpus.write_text("{}\n")
            p05_capture = root / "p05.json"
            candidate_capture = root / "candidate.json"
            p05_payload = {
                "schemaVersion": "mirmir-ash-v4-quality-p05-capture-v1",
                "contractSHA256": quality.sha256(self.contract_path),
                "corpusManifestSHA256": quality.sha256(corpus),
                "baselineIdentity": identity,
                "warmupCount": 1,
                "cases": [
                    {
                        "id": "case",
                        "output": "artifacts/p05.nv12",
                        "milliseconds": 1.0,
                    }
                ],
            }
            candidate_outputs = {
                variant: f"artifacts/{variant}.nv12"
                for variant in quality.CANDIDATE_VARIANTS
            }
            candidate_outputs["baseline_p05"] = "artifacts/substitute.nv12"
            candidate_payload = {
                "schemaVersion": "mirmir-ash-v4-quality-candidate-capture-v1",
                "contractSHA256": quality.sha256(self.contract_path),
                "corpusManifestSHA256": quality.sha256(corpus),
                "sourceCommit": "b" * 40,
                "sourceTreeIdentitySHA256": digest,
                "candidateBackendID": "mirmir_deterministic_cpu",
                "candidateImplementationVersion": "candidate",
                "runtimeManifestSHA256": digest,
                "runtimeSourceRevision": "c" * 40,
                "productionRuntimeLocked": False,
                "fullMirrorIdentityPass": True,
                "warmupCount": 1,
                "cases": [
                    {
                        "id": "case",
                        "outputs": candidate_outputs,
                        "milliseconds": {
                            variant: 1.0 for variant in candidate_outputs
                        },
                    }
                ],
            }
            quality.write_json(p05_capture, p05_payload)
            quality.write_json(candidate_capture, candidate_payload)
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, "candidate capture variant set"):
                    quality.merge_captures(
                        self.contract_path,
                        corpus,
                        p05_capture,
                        candidate_capture,
                        root / "merged.json",
                    )


if __name__ == "__main__":
    unittest.main()
