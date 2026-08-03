#!/usr/bin/env python3

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "performance_gate_v4",
    SCRIPT_DIRECTORY / "performance_gate_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PerformanceGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.contract_path = self.root / "contract.json"
        contract = json.loads(
            (SCRIPT_DIRECTORY / "performance-gate-contract-v1.json").read_text()
        )
        contract["measurement"]["bootstrapIterations"] = 1200
        contract["capture"]["captureSourceSHA256"] = "1" * 64
        contract["capture"]["evaluatorSourceSHA256"] = "2" * 64
        contract["capture"]["runnerSourceSHA256"] = "3" * 64
        write_json(self.contract_path, contract)
        self.contract = contract
        self.contract_sha = sha256(self.contract_path)
        self.baseline = self._make_capture("baseline_p05", wall=100.0, engine=10.0)
        self.candidate = self._make_capture("candidate_p06", wall=50.0, engine=5.0)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _environment(self) -> dict[str, object]:
        return {
            "schemaVersion": gate.ENVIRONMENT_SCHEMA,
            "stableIdentity": {
                "hardwareModel": "Mac-Test",
                "memoryBytes": 48 * 1024**3,
                "processor": "Apple Test",
                "gpuIdentity": ["Apple Test"],
                "macOSBuild": "25G72",
                "xcodeBuild": "17C52",
                "swiftCompiler": "6.2.3",
            },
            "power": {"identity": "power-identity", "source": "AC Power"},
            "thermal": {"accepted": True, "observationSHA256": "4" * 64},
        }

    def _source_identity(self, variant: str) -> dict[str, object]:
        if variant == "baseline_p05":
            runtime = {
                "status": self.contract["baseline"]["runtimeStatus"],
                "runtimeID": None,
                "implementationVersions": self.contract["baseline"][
                    "implementationVersions"
                ],
                "manifestSHA256": None,
                "releaseQualified": False,
                "trustRootConfigured": False,
                "artifactsVerified": True,
            }
            revision = self.contract["baseline"]["sourceRevision"]
        else:
            runtime = {
                "status": "release_qualified",
                "runtimeID": "ash-p06-deterministic-v4",
                "implementationVersions": ["ash-p06-deterministic-v4"],
                "manifestSHA256": "5" * 64,
                "manifestSourceRevision": "b" * 64,
                "builderSourceSHA256": "6" * 64,
                "releaseQualified": True,
                "trustRootConfigured": True,
                "artifactsVerified": True,
            }
            revision = "a" * 40
        return {
            "schemaVersion": gate.SOURCE_IDENTITY_SCHEMA,
            "variant": variant,
            "sourceRevision": revision,
            "sourceTreeSHA256": "7" * 64,
            "runtime": runtime,
        }

    def _make_capture(
        self,
        variant: str,
        wall: float,
        engine: float,
    ) -> Path:
        directory = self.root / variant
        directory.mkdir()
        source_identity = self._source_identity(variant)
        write_json(directory / "source-identity.json", source_identity)
        environment = self._environment()
        write_json(directory / "environment-before.json", environment)
        write_json(directory / "environment-after.json", environment)
        (directory / "xcodebuild.log").write_text("Release test succeeded\n")
        cases = []
        for case_index, case in enumerate(self.contract["workload"]["cases"]):
            verification = {
                "requestedBackendExecutedWithoutFallback": True,
                "allInputTracksAccounted": True,
                "exactEnabledVideoTrackCount": True,
                "exactEncodedDimensions": True,
                "exactCodec": True,
                "exactFrameCount": True,
                "exactPresentationTimestamps": True,
                "exactDuration": True,
                "bt709ColorContract": True,
                "decodedVisiblePixelSHA256": format(case_index + 8, "064x"),
                "semanticTrackManifestSHA256": format(case_index + 16, "064x"),
                "allRequiredChecksPassed": True,
            }
            engine_runs = []
            wall_runs = []
            for sample_index in range(10):
                jitter = sample_index * 0.001
                engine_runs.append(
                    {
                        "sampleIndex": sample_index,
                        "frameMilliseconds": [
                            engine + jitter,
                            engine + 0.01 + jitter,
                            engine + 0.02 + jitter,
                        ],
                        "processedFrameCount": 3,
                    }
                )
                wall_runs.append(
                    {
                        "sampleIndex": sample_index,
                        "wallMilliseconds": wall + case_index * 0.1 + jitter,
                        "peakResidentBytes": (
                            100 * 1024**2
                            if variant == "baseline_p05"
                            else 110 * 1024**2
                        ),
                        "processedFrameCount": 3,
                        "verification": verification,
                    }
                )
            cases.append(
                {
                    **case,
                    "request": copy.deepcopy(self.contract["workload"]["output"]),
                    "engineRuns": engine_runs,
                    "endToEndRuns": wall_runs,
                }
            )
        source_revision = source_identity["sourceRevision"]
        capture = {
            "schemaVersion": gate.CAPTURE_SCHEMA,
            "variant": variant,
            "contractSHA256": self.contract_sha,
            "captureSourceSHA256": self.contract["capture"][
                "captureSourceSHA256"
            ],
            "sourceIdentitySHA256": sha256(directory / "source-identity.json"),
            "sourceRevision": source_revision,
            "sourceTreeSHA256": source_identity["sourceTreeSHA256"],
            "buildConfiguration": "Release",
            "warmupCount": 5,
            "sampleCount": 10,
            "input": {
                **copy.deepcopy(self.contract["workload"]["input"]),
                "allRequiredChecksPassed": True,
            },
            "cases": cases,
        }
        capture["input"].pop("repositoryPath")
        write_json(directory / "capture.json", capture)
        write_json(
            directory / "artifact-manifest.json",
            gate.make_evidence_manifest(directory)
            | {"schemaVersion": gate.ARTIFACT_MANIFEST_SCHEMA},
        )
        return directory

    def _rewrite_and_reseal(self, directory: Path, filename: str, value: object) -> None:
        write_json(directory / filename, value)
        write_json(
            directory / "artifact-manifest.json",
            gate.make_evidence_manifest(directory)
            | {"schemaVersion": gate.ARTIFACT_MANIFEST_SCHEMA},
        )

    def test_paired_release_evidence_passes_and_verifies(self) -> None:
        report = gate.evaluate(self.contract_path, self.baseline, self.candidate)
        self.assertTrue(report["gatePass"])
        self.assertLess(report["metricGates"]["aggregateCorpusWall"]["ratio"], 0.51)
        self.assertLess(report["metricGates"]["engineFrameMedian"]["ratio"], 0.51)
        self.assertLess(report["metricGates"]["engineFrameP95"]["ratio"], 0.51)
        self.assertEqual(
            gate.verify_report(report, self.contract_path)["reportSHA256"],
            report["reportSHA256"],
        )

    def test_artifact_tamper_is_rejected(self) -> None:
        with (self.candidate / "capture.json").open("a") as stream:
            stream.write(" ")
        with self.assertRaisesRegex(
            gate.EvidenceError,
            "byte count changed|SHA-256 changed",
        ):
            gate.evaluate(self.contract_path, self.baseline, self.candidate)

    def test_capture_seal_uses_the_only_accepted_manifest_schema(self) -> None:
        manifest_path = self.candidate / "artifact-manifest.json"
        manifest_path.unlink()
        manifest = gate.seal_capture_directory(self.candidate)
        self.assertEqual(manifest["schemaVersion"], gate.ARTIFACT_MANIFEST_SCHEMA)
        gate.verify_artifact_manifest(self.candidate)

    def test_capture_fails_closed_on_scope_identity_and_verification(self) -> None:
        mutations = (
            ("warmupCount", 4, "too few warmups"),
            ("sampleCount", 9, "too few measured runs"),
        )
        for field, replacement, message in mutations:
            with self.subTest(field=field):
                candidate = json.loads((self.candidate / "capture.json").read_text())
                original = candidate[field]
                candidate[field] = replacement
                self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
                with self.assertRaisesRegex(gate.EvidenceError, message):
                    gate.evaluate(self.contract_path, self.baseline, self.candidate)
                candidate[field] = original
                self._rewrite_and_reseal(self.candidate, "capture.json", candidate)

        candidate = json.loads((self.candidate / "capture.json").read_text())
        candidate["cases"][0]["endToEndRuns"][0]["verification"][
            "allInputTracksAccounted"
        ] = False
        self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
        with self.assertRaisesRegex(gate.EvidenceError, "allInputTracksAccounted failed"):
            gate.evaluate(self.contract_path, self.baseline, self.candidate)

    def test_unlocked_runtime_and_environment_mismatch_are_rejected(self) -> None:
        source = json.loads((self.candidate / "source-identity.json").read_text())
        source["runtime"]["releaseQualified"] = False
        self._rewrite_and_reseal(self.candidate, "source-identity.json", source)
        capture = json.loads((self.candidate / "capture.json").read_text())
        capture["sourceIdentitySHA256"] = sha256(
            self.candidate / "source-identity.json"
        )
        self._rewrite_and_reseal(self.candidate, "capture.json", capture)
        with self.assertRaisesRegex(gate.EvidenceError, "candidate release qualification"):
            gate.evaluate(self.contract_path, self.baseline, self.candidate)

        self.candidate = self._fresh_candidate()
        environment = json.loads(
            (self.candidate / "environment-after.json").read_text()
        )
        environment["stableIdentity"]["macOSBuild"] = "different"
        self._rewrite_and_reseal(
            self.candidate, "environment-after.json", environment
        )
        report = gate.evaluate(self.contract_path, self.baseline, self.candidate)
        self.assertFalse(report["environmentGate"]["pass"])
        self.assertFalse(report["gatePass"])
        with self.assertRaisesRegex(gate.EvidenceError, "did not pass"):
            gate.verify_report(report, self.contract_path)

    def test_candidate_provenance_revision_requires_40_or_64_hex(self) -> None:
        source = json.loads((self.candidate / "source-identity.json").read_text())
        self.assertEqual(len(source["runtime"]["manifestSourceRevision"]), 64)
        gate.validate_source_identity(source, "candidate_p06", self.contract)

        for invalid in ("b" * 39, "b" * 41, "B" * 40, "g" * 64):
            with self.subTest(value=invalid):
                mutated = copy.deepcopy(source)
                mutated["runtime"]["manifestSourceRevision"] = invalid
                with self.assertRaisesRegex(
                    gate.EvidenceError,
                    "40- or 64-character lowercase hexadecimal identity",
                ):
                    gate.validate_source_identity(
                        mutated,
                        "candidate_p06",
                        self.contract,
                    )

    def test_slow_candidate_and_report_tamper_fail_verification(self) -> None:
        candidate = json.loads((self.candidate / "capture.json").read_text())
        for case in candidate["cases"]:
            for run in case["engineRuns"]:
                run["frameMilliseconds"] = [12.0, 12.1, 12.2]
            for run in case["endToEndRuns"]:
                run["wallMilliseconds"] = 120.0
        self._rewrite_and_reseal(self.candidate, "capture.json", candidate)
        report = gate.evaluate(self.contract_path, self.baseline, self.candidate)
        self.assertFalse(report["gatePass"])
        with self.assertRaisesRegex(gate.EvidenceError, "did not pass"):
            gate.verify_report(report, self.contract_path)

        report = gate.evaluate(
            self.contract_path,
            self.baseline,
            self._fresh_candidate(),
        )
        report["metricGates"]["engineFrameMedian"]["ratio"] = 0.1
        with self.assertRaisesRegex(gate.EvidenceError, "report seal differs"):
            gate.verify_report(report, self.contract_path)

    def _fresh_candidate(self) -> Path:
        candidate = self.root / "candidate_p06"
        if candidate.exists():
            for child in candidate.iterdir():
                child.unlink()
            candidate.rmdir()
        return self._make_capture("candidate_p06", wall=50.0, engine=5.0)


if __name__ == "__main__":
    unittest.main()
