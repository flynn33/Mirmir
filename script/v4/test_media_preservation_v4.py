#!/usr/bin/env python3
"""Fail-closed tests for deterministic M7 media-preservation evidence."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


media = load_module("media_preservation_v4_for_tests", SCRIPT_DIRECTORY / "media_preservation_v4.py")
release_tests = load_module(
    "release_qualification_fixture_for_media_tests",
    SCRIPT_DIRECTORY / "test_release_qualification_v4.py",
)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class MediaPreservationEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fixture = release_tests.EvidenceFixture(self.root / "source")
        self.role = self.fixture.root / "media_preservation"
        self.raw = self.role / "raw-capture"
        self.candidate_path = self.root / "candidate.json"
        write_json(self.candidate_path, self.fixture.candidate)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def paths(self, output: Path) -> dict[str, Path]:
        return {
            "capture_root": self.raw,
            "candidate_path": self.candidate_path,
            "output_directory": output,
            "contract_path": self.role / "bindings" / "media-preservation-contract-v1.json",
            "release_contract_path": self.role / "suite-contract.json",
            "runtime_manifest_path": self.role / "runtime-manifest.json",
            "release_configuration_path": self.role / "Release.xcconfig",
            "capture_source_path": self.role / "bindings" / "MediaPreservationCaptureTests.swift",
            "fixture_source_path": self.role / "bindings" / "AVFoundationTrackMigrationExecutorV4Tests.swift",
            "evaluator_path": self.role / "bindings" / "media_preservation_v4.py",
            "runner_path": self.role / "bindings" / "run_media_preservation_v4.sh",
        }

    def evaluate(self, name: str = "evidence") -> tuple[Path, dict[str, object]]:
        output = self.root / name / "media_preservation"
        report = media.evaluate_capture(**self.paths(output))
        return output, report

    def update_raw_descriptor(self, capture: dict[str, object], fixture_id: str, side: str, name: str) -> None:
        fixture = next(item for item in capture["fixtures"] if item["id"] == fixture_id)
        item = fixture[side][name]
        path = self.raw / item["path"]
        item["byteCount"] = path.stat().st_size
        item["sha256"] = media.sha256_file(path)

    def testEvaluateAndVerifyRecomputeAllSixLockedFixtures(self) -> None:
        evidence, report = self.evaluate()
        self.assertTrue(report["mediaPreservationGatePass"])
        self.assertEqual(len(report["fixtures"]), 6)
        verified = media.verify_evidence(evidence)
        self.assertEqual(verified, report)

    def testRawPixelArtifactTamperFailsClosed(self) -> None:
        capture = json.loads((self.raw / "capture.json").read_text())
        fixture = capture["fixtures"][0]
        pixel_path = self.raw / fixture["output"]["pixels"]["path"]
        pixel_path.write_bytes(pixel_path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(media.EvidenceError, "byte count mismatch|SHA-256 mismatch"):
            self.evaluate("pixel-tamper")

    def testSemanticForgeryFailsIndependentRecomputation(self) -> None:
        capture_path = self.raw / "capture.json"
        capture = json.loads(capture_path.read_text())
        fixture_id = "combined-p010-hdr-interlaced"
        fixture = next(item for item in capture["fixtures"] if item["id"] == fixture_id)
        observation_path = self.raw / fixture["output"]["pixelObservation"]["path"]
        observation = json.loads(observation_path.read_text())
        observation["tracks"][0]["visibleSHA256"] = media.sha256_bytes(b"forged-output")
        write_json(observation_path, observation)
        self.update_raw_descriptor(capture, fixture_id, "output", "pixelObservation")
        write_json(capture_path, capture)
        with self.assertRaisesRegex(media.EvidenceError, "repeat output pixels differ"):
            self.evaluate("semantic-forgery")

    def testToolAndCandidateIdentitySubstitutionFailClosed(self) -> None:
        substituted_tool = self.root / "substituted-evaluator.py"
        substituted_tool.write_bytes(b"# not the locked evaluator\n")
        arguments = self.paths(self.root / "tool-substitution" / "media_preservation")
        arguments["evaluator_path"] = substituted_tool
        with self.assertRaisesRegex(media.EvidenceError, "locked tool identity differs"):
            media.evaluate_capture(**arguments)

        candidate = json.loads(self.candidate_path.read_text())
        candidate["sourceCommit"] = "c" * 40
        write_json(self.candidate_path, candidate)
        with self.assertRaisesRegex(media.EvidenceError, "capture belongs to another candidate"):
            self.evaluate("candidate-substitution")

    def testPublishedEvidenceTamperFailsByteExactVerification(self) -> None:
        evidence, _ = self.evaluate()
        verifier = evidence / "fixtures" / "combined-alpha-geometry-straight" / "semantic-verifier.json"
        document = json.loads(verifier.read_text())
        document["checks"][0]["id"] = "forged-check"
        write_json(verifier, document)
        with self.assertRaisesRegex(media.EvidenceError, "evidence artifact differs"):
            media.verify_evidence(evidence)


if __name__ == "__main__":
    unittest.main()
