#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "recovery_qualification_v4",
    SCRIPT_DIRECTORY / "recovery_qualification_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gate.pretty_json(value))


class RecoveryQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.evidence_root = Path(self.temporary.name) / "evidence"
        self.capture_root = self.evidence_root / "recovery" / "capture"
        self.capture_root.mkdir(parents=True)
        self.contract = json.loads(
            (SCRIPT_DIRECTORY / "recovery-qualification-contract-v1.json").read_text()
        )
        self.contract["capture"] = {
            "captureSourceSHA256": "1" * 64,
            "evaluatorSourceSHA256": "2" * 64,
            "runnerSourceSHA256": "3" * 64,
        }
        self.contract_path = self.evidence_root / "contract.json"
        write_json(self.contract_path, self.contract)
        self.contract_sha = gate.sha256_file(self.contract_path)
        self.candidate = {
            "sourceCommit": "a" * 40,
            "sourceTreeIdentitySHA256": "b" * 64,
            "runtimeManifestSHA256": "c" * 64,
            "runtimeManifestFileSHA256": "d" * 64,
            "runtimeArtifactSetSHA256": "e" * 64,
            "runtimeSourceRevision": "f" * 64,
            "releaseConfigurationSHA256": "0" * 64,
            "appBundleSHA256": "1" * 64,
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        self.candidate_path = self.evidence_root / "candidate.json"
        write_json(self.candidate_path, self.candidate)
        write_json(
            self.capture_root / "environment.json",
            {
                "schemaVersion": "mirmir-v4-recovery-environment-v1",
                "buildConfiguration": "Release",
                "hardwareModel": "Mac-Test",
                "macOSVersion": "26.0",
                "xcodeVersion": "17.0",
            },
        )
        (self.capture_root / "xcodebuild.log").write_text(
            "Recovery capture\n** TEST SUCCEEDED **\n"
        )
        self._build_capture()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _descriptor(self, path: Path) -> dict[str, object]:
        return gate.descriptor(path, self.evidence_root)

    def _semantic(self) -> dict[str, object]:
        return {
            "schemaVersion": gate.SEMANTIC_SCHEMA,
            "trackGraphSHA256": "4" * 64,
            "decodedVisiblePixelSHA256": "5" * 64,
            "presentationTimelineSHA256": "6" * 64,
            "sampleCount": 4,
            "duration": {"value": 4, "timescale": 30},
            "allRequiredChecksPassed": True,
        }

    def _transcript(self, scenario: dict[str, object]) -> dict[str, object]:
        return {
            "schemaVersion": gate.TRANSCRIPT_SCHEMA,
            "id": scenario["id"],
            "coverageID": scenario["coverageID"],
            "injectionPoint": scenario["injectionPoint"],
            "faultObserved": True,
            "reopenedDurableState": True,
            "terminalDisposition": (
                "completed"
                if scenario["outcome"] == "identical_resumed_output"
                else "contained"
            ),
            "events": [
                {
                    "sequence": 0,
                    "operation": "prepare_durable_state",
                    "durableStateSHA256": "7" * 64,
                },
                {
                    "sequence": 1,
                    "operation": "inject_fault",
                    "durableStateSHA256": "8" * 64,
                },
                {
                    "sequence": 2,
                    "operation": "reopen_durable_state",
                    "durableStateSHA256": "9" * 64,
                },
            ],
        }

    def _build_capture(self) -> None:
        capture_scenarios = []
        for scenario in self.contract["scenarios"]:
            scenario_directory = self.capture_root / "scenarios" / scenario["id"]
            scenario_directory.mkdir(parents=True)
            transcript_path = scenario_directory / "transcript.json"
            write_json(transcript_path, self._transcript(scenario))
            external: dict[str, object] = {
                "schemaVersion": gate.SCENARIO_SCHEMA,
                "id": scenario["id"],
                "coverageID": scenario["coverageID"],
                "injectionPoint": scenario["injectionPoint"],
                "outcome": scenario["outcome"],
                "containedFailureCode": scenario["containedFailureCode"],
                "faultInjected": True,
                "unownedArtifactCount": 0,
                "ownedArtifactReconciled": True,
                "referenceOutputArtifact": None,
                "resumedOutputArtifact": None,
                "referenceSemanticArtifact": None,
                "resumedSemanticArtifact": None,
                "transcriptArtifact": self._descriptor(transcript_path),
            }
            if scenario["outcome"] == "identical_resumed_output":
                reference = scenario_directory / "reference-output.mov"
                resumed = scenario_directory / "resumed-output.mov"
                reference.write_bytes(("deterministic-output:" + scenario["id"]).encode())
                resumed.write_bytes(reference.read_bytes())
                reference_semantic = scenario_directory / "reference-semantic.json"
                resumed_semantic = scenario_directory / "resumed-semantic.json"
                write_json(reference_semantic, self._semantic())
                write_json(resumed_semantic, self._semantic())
                external.update(
                    {
                        "referenceOutputArtifact": self._descriptor(reference),
                        "resumedOutputArtifact": self._descriptor(resumed),
                        "referenceSemanticArtifact": self._descriptor(reference_semantic),
                        "resumedSemanticArtifact": self._descriptor(resumed_semantic),
                    }
                )
            external_path = scenario_directory / "evidence.json"
            write_json(external_path, external)
            capture_scenarios.append(
                {
                    "id": scenario["id"],
                    "externalEvidenceArtifact": self._descriptor(external_path),
                }
            )
        self.capture = {
            "schemaVersion": gate.CAPTURE_SCHEMA,
            "contractSHA256": self.contract_sha,
            "captureSourceSHA256": self.contract["capture"]["captureSourceSHA256"],
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeSHA256": self.candidate["sourceTreeIdentitySHA256"],
            "buildConfiguration": "Release",
            "scenarios": capture_scenarios,
        }
        self.capture_path = self.capture_root / "capture.json"
        write_json(self.capture_path, self.capture)

    def _scenario_paths(self, identifier: str) -> tuple[Path, Path]:
        evidence = self.capture_root / "scenarios" / identifier / "evidence.json"
        return evidence, self.capture_path

    def _rewrite_external(self, identifier: str, mutate) -> None:
        external_path, _ = self._scenario_paths(identifier)
        value = json.loads(external_path.read_text())
        mutate(value)
        write_json(external_path, value)
        capture = json.loads(self.capture_path.read_text())
        for scenario in capture["scenarios"]:
            if scenario["id"] == identifier:
                scenario["externalEvidenceArtifact"] = self._descriptor(external_path)
        write_json(self.capture_path, capture)

    def _evaluate(self):
        return gate.evaluate_capture(
            self.contract_path,
            self.capture_path,
            self.candidate_path,
            self.evidence_root,
            verify_tools=False,
        )

    def testValidCaptureRecomputesEveryCoverageAndIdentity(self) -> None:
        report, manifest = self._evaluate()
        self.assertTrue(report["recoveryGatePass"])
        self.assertEqual(len(report["scenarios"]), len(gate.REQUIRED_COVERAGE))
        self.assertEqual(
            [item["coverage"][0] for item in report["scenarios"]],
            list(gate.REQUIRED_COVERAGE),
        )
        self.assertEqual(
            manifest["artifactSetSHA256"],
            gate.artifact_set_sha(manifest["artifacts"]),
        )
        identical = [item for item in report["scenarios"] if item["outcome"] == "identical_resumed_output"]
        self.assertGreater(len(identical), 0)
        for item in identical:
            self.assertEqual(item["referenceOutputSHA256"], item["resumedOutputSHA256"])
            self.assertEqual(item["referenceSemanticSHA256"], item["resumedSemanticSHA256"])

    def testMissingScenarioFailsClosed(self) -> None:
        capture = json.loads(self.capture_path.read_text())
        capture["scenarios"].pop()
        write_json(self.capture_path, capture)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "scenario count"):
            self._evaluate()

    def testResumedByteMismatchFailsClosed(self) -> None:
        identifier = "pause-resume"
        resumed = self.capture_root / "scenarios" / identifier / "resumed-output.mov"
        resumed.write_bytes(b"changed")
        self._rewrite_external(
            identifier,
            lambda value: value.__setitem__("resumedOutputArtifact", self._descriptor(resumed)),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "bytes differ"):
            self._evaluate()

    def testSemanticMismatchFailsClosed(self) -> None:
        identifier = "forced-termination-restart"
        semantic = self.capture_root / "scenarios" / identifier / "resumed-semantic.json"
        value = json.loads(semantic.read_text())
        value["trackGraphSHA256"] = "a" * 64
        write_json(semantic, value)
        self._rewrite_external(
            identifier,
            lambda external: external.__setitem__("resumedSemanticArtifact", self._descriptor(semantic)),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "semantics differ"):
            self._evaluate()

    def testFaultAndReopenMustBeObserved(self) -> None:
        identifier = "append-only-event-boundary"
        transcript = self.capture_root / "scenarios" / identifier / "transcript.json"
        value = json.loads(transcript.read_text())
        value["reopenedDurableState"] = False
        write_json(transcript, value)
        self._rewrite_external(
            identifier,
            lambda external: external.__setitem__("transcriptArtifact", self._descriptor(transcript)),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "must be true"):
            self._evaluate()

    def testContainedFailureCannotClaimOutput(self) -> None:
        source = self.capture_root / "scenarios" / "pause-resume" / "reference-output.mov"
        self._rewrite_external(
            "corrupt-journal",
            lambda external: external.__setitem__("referenceOutputArtifact", self._descriptor(source)),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "supplies referenceOutputArtifact"):
            self._evaluate()

    def testWrongContainedFailureCodeFailsClosed(self) -> None:
        self._rewrite_external(
            "corrupt-checkpoint",
            lambda external: external.__setitem__("containedFailureCode", "generic_error"),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "containedFailureCode differs"):
            self._evaluate()

    def testUnownedArtifactCountMustBeZero(self) -> None:
        self._rewrite_external(
            "unowned-artifact-rejection",
            lambda external: external.__setitem__("unownedArtifactCount", 1),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "left an unowned artifact"):
            self._evaluate()

    def testExtraRawFileFailsClosed(self) -> None:
        (self.capture_root / "unsealed.bin").write_bytes(b"unsealed")
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "capture file set differs"):
            self._evaluate()

    def testCandidateIdentityMismatchFailsClosed(self) -> None:
        capture = json.loads(self.capture_path.read_text())
        capture["sourceCommit"] = "f" * 40
        write_json(self.capture_path, capture)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "source commit is stale"):
            self._evaluate()

    def testPathEscapeFailsClosed(self) -> None:
        outside = Path(self.temporary.name) / "outside.json"
        outside.write_text("{}")
        self._rewrite_external(
            "corrupt-journal",
            lambda external: external["transcriptArtifact"].__setitem__(
                "path", "../../outside.json"
            ),
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "escapes evidence root"):
            self._evaluate()

    def testSymlinkFailsClosed(self) -> None:
        identifier = "corrupt-journal"
        link = self.capture_root / "scenarios" / identifier / "transcript-link.json"
        link.symlink_to(self.capture_root / "scenarios" / identifier / "transcript.json")
        self._rewrite_external(
            identifier,
            lambda external: external.__setitem__(
                "transcriptArtifact",
                {
                    "path": link.relative_to(self.evidence_root).as_posix(),
                    "byteCount": link.stat().st_size,
                    "sha256": gate.sha256_file(link),
                },
            ),
        )
        with self.assertRaises(gate.RecoveryEvidenceError):
            self._evaluate()

    def testDuplicateJSONKeyFailsClosed(self) -> None:
        self.capture_path.write_text(
            '{"schemaVersion":"x","schemaVersion":"y"}\n'
        )
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "duplicate JSON key"):
            self._evaluate()


if __name__ == "__main__":
    unittest.main()
