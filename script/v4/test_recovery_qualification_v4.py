#!/usr/bin/env python3

from __future__ import annotations

import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY = SCRIPT_DIRECTORY.parent.parent
SPEC = importlib.util.spec_from_file_location(
    "recovery_qualification_v4",
    SCRIPT_DIRECTORY / "recovery_qualification_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def write_pretty(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gate.pretty_json(value))


def write_canonical(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gate.packaged_evidence.canonical_bytes(value))


def fixture_sha(label: str) -> str:
    return gate.sha256_bytes(label.encode())


class PackagedRecoveryFixture:
    def __init__(
        self,
        root: Path,
        *,
        contract: dict[str, object] | None = None,
        contract_bytes: bytes | None = None,
        candidate: dict[str, object] | None = None,
        package: dict[str, object] | None = None,
        observer_bytes: bytes | None = None,
        release_configuration_bytes: bytes | None = None,
        application_archive_bytes: bytes | None = None,
        attestation_bytes: bytes | None = None,
    ) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.repository = root / "repository"
        self.repository.mkdir()
        self.runtime = root / "runtime.bundle"
        self.runtime.mkdir()
        self.producer_bytes = (REPOSITORY / gate.PRODUCER_SOURCE_PATH).read_bytes()
        self.observer_bytes = observer_bytes or b"sealed observer fixture\n"
        self.release_configuration_bytes = (
            release_configuration_bytes
            or b"CONFIGURATION=Release\nENABLE_TESTABILITY=NO\n"
        )
        self.application_archive_bytes = (
            application_archive_bytes or b"sealed application archive fixture\n"
        )
        self.attestation_bytes = attestation_bytes or gate.packaged_evidence.canonical_bytes(
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            }
        )
        if contract is None:
            self.contract = json.loads(
                (SCRIPT_DIRECTORY / "recovery-qualification-contract-v1.json").read_text()
            )
            self.contract["capture"] = {
                "archiveProvenanceSourceSHA256": fixture_sha("archive"),
                "evaluatorSourceSHA256": fixture_sha("evaluator"),
                "observerSourceSHA256": gate.sha256_bytes(self.observer_bytes),
                "packagedEvidenceSourceSHA256": fixture_sha("packaged"),
                "producerSourceSHA256": gate.sha256_bytes(self.producer_bytes),
                "runnerSourceSHA256": fixture_sha("runner"),
            }
        else:
            self.contract = copy.deepcopy(contract)
        self.contract_path = root / "contract.json"
        if contract_bytes is None:
            write_pretty(self.contract_path, self.contract)
        else:
            self.contract_path.write_bytes(contract_bytes)
            if json.loads(contract_bytes) != self.contract:
                raise AssertionError("recovery contract bytes differ from value")
        self.contract_sha = gate.sha256_file(self.contract_path)
        self.package = copy.deepcopy(package) if package is not None else self._package()
        self.candidate = (
            copy.deepcopy(candidate)
            if candidate is not None
            else self._candidate_from_package(self.package)
        )
        self.first_root = self._make_process("process-a", 4101, "1" * 64)
        self.second_root = self._make_process("process-b", 4102, "2" * 64)

    def _package(self) -> dict[str, object]:
        return {
            "schemaVersion": gate.PACKAGE_SCHEMA,
            "buildConfiguration": "Release",
            "applicationArchiveSHA256": gate.sha256_bytes(
                self.application_archive_bytes
            ),
            "applicationPayloadIdentitySHA256": fixture_sha("payload"),
            "applicationInfoPlistSHA256": fixture_sha("plist"),
            "applicationExecutableSHA256": fixture_sha("executable"),
            "codeDirectories": [
                {"architecture": "arm64", "sha256": fixture_sha("arm64")},
                {"architecture": "x86_64", "sha256": fixture_sha("x86_64")},
            ],
            "codeDirectorySetSHA256": fixture_sha("code-set"),
            "designatedRequirementSHA256": fixture_sha("requirement"),
            "releaseConfigurationSHA256": gate.sha256_bytes(
                self.release_configuration_bytes
            ),
            "attestationSHA256": gate.sha256_bytes(self.attestation_bytes),
            "sourceCommit": "a" * 40,
            "sourceTreeIdentitySHA256": fixture_sha("source-tree"),
            "runtimeManifestSHA256": fixture_sha("runtime-manifest"),
            "runtimeManifestFileSHA256": fixture_sha("runtime-file"),
            "runtimeArtifactSetSHA256": fixture_sha("runtime-set"),
            "runtimeSourceRevision": "b" * 40,
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "4.0",
            "productBuild": "400",
        }

    @staticmethod
    def _candidate_from_package(
        package: dict[str, object],
    ) -> dict[str, object]:
        return {
            "sourceCommit": package["sourceCommit"],
            "sourceTreeIdentitySHA256": package["sourceTreeIdentitySHA256"],
            "runtimeManifestSHA256": package["runtimeManifestSHA256"],
            "runtimeManifestFileSHA256": package["runtimeManifestFileSHA256"],
            "runtimeArtifactSetSHA256": package["runtimeArtifactSetSHA256"],
            "runtimeSourceRevision": package["runtimeSourceRevision"],
            "releaseConfigurationSHA256": package[
                "releaseConfigurationSHA256"
            ],
            "appBundleSHA256": package["applicationArchiveSHA256"],
            "bundleIdentifier": package["bundleIdentifier"],
            "productVersion": package["productVersion"],
            "productBuild": package["productBuild"],
        }

    @staticmethod
    def _state(
        directory: Path,
        scenario: dict[str, object],
        role: str,
        process_label: str,
    ) -> tuple[Path, dict[str, object]]:
        state_root = directory / (
            "recovered-state" if role == "recovered" else "uninterrupted-state"
        )
        state_root.mkdir()
        state_file = state_root / "state.bin"
        state_file.write_bytes(
            f"{process_label}:{scenario['id']}:{role}:durable".encode()
        )
        files = [{
            "path": "state.bin",
            "byteCount": state_file.stat().st_size,
            "sha256": gate.sha256_file(state_file),
        }]
        state_sha = gate.state_artifact_set(files)
        value = {
            "schemaVersion": gate.STATE_MANIFEST_SCHEMA,
            "id": scenario["id"],
            "coverageID": scenario["coverageID"],
            "role": role,
            "durableStateSHA256": state_sha,
            "artifactSetSHA256": state_sha,
            "files": files,
        }
        path = directory / f"{role}-state-manifest.json"
        write_pretty(path, value)
        return path, value

    @staticmethod
    def _semantic(identifier: str) -> dict[str, object]:
        return {
            "schemaVersion": gate.SEMANTIC_SCHEMA,
            "trackGraphSHA256": fixture_sha(identifier + ":track"),
            "decodedVisiblePixelSHA256": fixture_sha(identifier + ":pixels"),
            "presentationTimelineSHA256": fixture_sha(identifier + ":timeline"),
            "sampleCount": 4,
            "duration": {"value": 4, "timescale": 30},
            "allRequiredChecksPassed": True,
        }

    def _make_scenario(
        self,
        capture_root: Path,
        process_label: str,
        scenario: dict[str, object],
    ) -> dict[str, object]:
        identifier = str(scenario["id"])
        directory = capture_root / "scenarios" / identifier
        directory.mkdir(parents=True)
        recovered_path, recovered = self._state(
            directory, scenario, "recovered", process_label
        )
        identical = scenario["outcome"] == "identical_resumed_output"
        uninterrupted_path = None
        uninterrupted = None
        if identical:
            uninterrupted_path, uninterrupted = self._state(
                directory, scenario, "uninterrupted", process_label
            )
        transcript = {
            "schemaVersion": gate.TRANSCRIPT_SCHEMA,
            "id": identifier,
            "coverageID": scenario["coverageID"],
            "injectionPoint": scenario["injectionPoint"],
            "faultObserved": True,
            "reopenedDurableState": True,
            "terminalDisposition": "completed" if identical else "contained",
            "events": [
                {"sequence": 0, "operation": "prepare_durable_state",
                 "durableStateSHA256": fixture_sha(process_label + identifier + "prepared")},
                {"sequence": 1, "operation": "inject_fault",
                 "durableStateSHA256": fixture_sha(process_label + identifier + "fault")},
                {"sequence": 2, "operation": "reopen_durable_state",
                 "durableStateSHA256": recovered["durableStateSHA256"]},
            ],
        }
        transcript_path = directory / "transcript.json"
        write_pretty(transcript_path, transcript)
        causal: dict[str, object | None] = {
            "schemaVersion": gate.CAUSAL_BINDING_SCHEMA,
            "id": identifier,
            "coverageID": scenario["coverageID"],
            "injectionPoint": scenario["injectionPoint"],
            "outcome": scenario["outcome"],
            "evidenceKind": scenario["evidenceKind"],
            "transcriptSHA256": gate.sha256_file(transcript_path),
            "reopenedStateSHA256": recovered["durableStateSHA256"],
            "recoveredStateManifestSHA256": gate.sha256_file(recovered_path),
            "recoveredStateArtifactSetSHA256": recovered["artifactSetSHA256"],
            "uninterruptedStateManifestSHA256": (
                gate.sha256_file(uninterrupted_path) if uninterrupted_path else None
            ),
            "uninterruptedStateArtifactSetSHA256": (
                uninterrupted["artifactSetSHA256"] if uninterrupted else None
            ),
            "referenceOutputSHA256": None,
            "resumedOutputSHA256": None,
            "referenceSemanticSHA256": None,
            "resumedSemanticSHA256": None,
            "referenceDerivationSHA256": None,
            "resumedDerivationSHA256": None,
        }
        evidence: dict[str, object | None] = {
            "schemaVersion": gate.SCENARIO_SCHEMA,
            "id": identifier,
            "coverageID": scenario["coverageID"],
            "injectionPoint": scenario["injectionPoint"],
            "outcome": scenario["outcome"],
            "evidenceKind": scenario["evidenceKind"],
            "containedFailureCode": scenario["containedFailureCode"],
            "faultInjected": True,
            "unownedArtifactCount": 0,
            "ownedArtifactReconciled": True,
            "referenceOutputArtifact": None,
            "resumedOutputArtifact": None,
            "referenceSemanticArtifact": None,
            "resumedSemanticArtifact": None,
            "referenceDerivationArtifact": None,
            "resumedDerivationArtifact": None,
            "uninterruptedStateManifestArtifact": (
                gate.descriptor(uninterrupted_path, capture_root)
                if uninterrupted_path else None
            ),
            "recoveredStateManifestArtifact": gate.descriptor(recovered_path, capture_root),
            "transcriptArtifact": gate.descriptor(transcript_path, capture_root),
        }
        if scenario["evidenceKind"] == "durable_state_derivation":
            derivation = {
                "schemaVersion": gate.STATE_DERIVATION_SCHEMA,
                "id": identifier,
                "coverageID": scenario["coverageID"],
                "injectionPoint": scenario["injectionPoint"],
                "terminalDisposition": "completed",
                "values": gate.EXPECTED_DERIVATION_VALUES[str(scenario["coverageID"])],
            }
            reference_path = directory / "uninterrupted-derivation.json"
            resumed_path = directory / "recovered-derivation.json"
            reference_path.write_bytes(gate.compact_json(derivation))
            resumed_path.write_bytes(gate.compact_json(derivation))
            evidence["referenceDerivationArtifact"] = gate.descriptor(reference_path, capture_root)
            evidence["resumedDerivationArtifact"] = gate.descriptor(resumed_path, capture_root)
            causal["referenceDerivationSHA256"] = gate.sha256_file(reference_path)
            causal["resumedDerivationSHA256"] = gate.sha256_file(resumed_path)
        elif scenario["evidenceKind"] == "scenario_media_output":
            media = ("scenario-media:" + identifier).encode()
            reference_path = directory / "reference-output.mov"
            resumed_path = directory / "resumed-output.mov"
            reference_path.write_bytes(media)
            resumed_path.write_bytes(media)
            reference_semantic = directory / "reference-semantic.json"
            resumed_semantic = directory / "resumed-semantic.json"
            write_pretty(reference_semantic, self._semantic(identifier))
            write_pretty(resumed_semantic, self._semantic(identifier))
            evidence.update({
                "referenceOutputArtifact": gate.descriptor(reference_path, capture_root),
                "resumedOutputArtifact": gate.descriptor(resumed_path, capture_root),
                "referenceSemanticArtifact": gate.descriptor(reference_semantic, capture_root),
                "resumedSemanticArtifact": gate.descriptor(resumed_semantic, capture_root),
            })
            causal.update({
                "referenceOutputSHA256": gate.sha256_file(reference_path),
                "resumedOutputSHA256": gate.sha256_file(resumed_path),
                "referenceSemanticSHA256": gate.sha256_file(reference_semantic),
                "resumedSemanticSHA256": gate.sha256_file(resumed_semantic),
            })
        causal_path = directory / "causal-binding.json"
        write_pretty(causal_path, causal)
        evidence["causalBindingArtifact"] = gate.descriptor(causal_path, capture_root)
        evidence_path = directory / "evidence.json"
        write_pretty(evidence_path, evidence)
        return {
            "id": identifier,
            "externalEvidenceArtifact": gate.descriptor(evidence_path, capture_root),
        }

    def _make_process(self, label: str, process_id: int, nonce: str) -> Path:
        root = self.root / label
        observer = root / "observer"
        bindings = root / "bindings"
        capture_root = root / "capture"
        observer.mkdir(parents=True)
        bindings.mkdir()
        capture_root.mkdir()
        request = {
            "schemaVersion": gate.PACKAGED_REQUEST_SCHEMA,
            "lane": "recovery",
            "requestID": label + "-request",
            "nonce": nonce,
            "generatedAtUTC": "2026-08-14T12:00:00Z",
            "observerSourceSHA256": self.contract["capture"]["observerSourceSHA256"],
            "contractSHA256": self.contract_sha,
            "packageIdentity": self.package,
            "captureEnvironment": {"fixture": label},
        }
        request_path = observer / "request.json"
        write_canonical(request_path, request)
        request_sha = gate.sha256_file(request_path)
        nonce_sha = gate.sha256_bytes(nonce.encode())
        rows = [
            self._make_scenario(capture_root, label, scenario)
            for scenario in self.contract["scenarios"]
        ]
        write_pretty(capture_root / "environment.json", {
            "schemaVersion": "mirmir-v4-recovery-environment-v2",
            "buildConfiguration": "Release",
            "executionMode": "archived_application_executable",
            "hardwareModel": "Mac-Test",
            "macOSVersion": "26.0",
        })
        execution = {
            "schemaVersion": gate.EXECUTION_SCHEMA,
            "kind": "archived_application_executable",
            "applicationArchiveExecuted": True,
            "applicationArchiveSHA256": self.package["applicationArchiveSHA256"],
            "applicationExecutableSHA256": self.package["applicationExecutableSHA256"],
            "applicationPayloadIdentitySHA256": self.package["applicationPayloadIdentitySHA256"],
            "nonceSHA256": nonce_sha,
            "observerSourceSHA256": self.contract["capture"]["observerSourceSHA256"],
            "producerSourceSHA256": self.contract["capture"]["producerSourceSHA256"],
            "requestID": request["requestID"],
            "requestSHA256": request_sha,
            "runtimeArtifactSetSHA256": self.package["runtimeArtifactSetSHA256"],
            "runtimeManifestFileSHA256": self.package["runtimeManifestFileSHA256"],
            "runtimeManifestSHA256": self.package["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.package["runtimeSourceRevision"],
            "sourceCommit": self.package["sourceCommit"],
            "sourceTreeIdentitySHA256": self.package["sourceTreeIdentitySHA256"],
        }
        capture_path = capture_root / "capture.json"
        write_pretty(capture_path, {
            "schemaVersion": gate.CAPTURE_SCHEMA,
            "contractSHA256": self.contract_sha,
            "producerSourceSHA256": self.contract["capture"]["producerSourceSHA256"],
            "evidenceRequestSHA256": request_sha,
            "evidenceNonceSHA256": nonce_sha,
            "observerSourceSHA256": self.contract["capture"]["observerSourceSHA256"],
            "packagedCandidateIdentity": self.package,
            "sourceCommit": self.package["sourceCommit"],
            "sourceTreeIdentitySHA256": self.package["sourceTreeIdentitySHA256"],
            "buildConfiguration": "Release",
            "execution": execution,
            "scenarios": rows,
        })
        producer_path = bindings / "producer-source.swift"
        producer_path.write_bytes(self.producer_bytes)
        candidate_path = bindings / "candidate.json"
        package_path = bindings / "package-identity.json"
        attestation_path = bindings / "application-archive-attestation-v1.json"
        observer_source_path = bindings / "observer-source.swift"
        contract_path = bindings / "lane-contract.json"
        release_configuration_path = (
            bindings / "release-candidate-v4.xcconfig"
        )
        application_archive_path = bindings / "application-archive.zip"
        write_canonical(candidate_path, self.candidate)
        write_canonical(package_path, self.package)
        attestation_path.write_bytes(self.attestation_bytes)
        observer_source_path.write_bytes(self.observer_bytes)
        contract_path.write_bytes(self.contract_path.read_bytes())
        release_configuration_path.write_bytes(
            self.release_configuration_bytes
        )
        application_archive_path.write_bytes(self.application_archive_bytes)
        tree = gate.packaged_evidence.capture_tree(capture_root)
        result = {
            "schemaVersion": gate.PACKAGED_RESULT_SCHEMA,
            "lane": "recovery",
            "requestID": request["requestID"],
            "requestSHA256": request_sha,
            "observerSourceSHA256": self.contract["capture"]["observerSourceSHA256"],
            "contractSHA256": self.contract_sha,
            "packageIdentity": self.package,
            "process": {
                "bundlePath": "/fixture/Mirmir.app",
                "executablePath": "/fixture/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": self.package["applicationExecutableSHA256"],
                "processID": process_id,
                "parentProcessID": 4000,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.package["runtimeManifestSHA256"],
                "sourceRevision": self.package["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": "capture.json",
                "byteCount": capture_path.stat().st_size,
                "sha256": gate.sha256_file(capture_path),
            },
            "captureTree": tree,
            "checks": {
                "exactExecutableIdentity": True,
                "signedBuildClaims": True,
                "productionP06Load": True,
                "normativePixelCapture": True,
            },
        }
        result_path = observer / "result.json"
        write_canonical(result_path, result)
        stdout_path = observer / "stdout.bin"
        stdout_path.write_bytes(
            gate.packaged_evidence.RESULT_PREFIX
            + base64.b64encode(result_path.read_bytes()) + b"\n"
        )
        stderr_path = observer / "stderr.bin"
        stderr_path.write_bytes(b"")
        record = {
            "schemaVersion": gate.packaged_evidence.CAPTURE_RECORD_SCHEMA,
            "lane": "recovery",
            "startedAtUTC": "2026-08-14T12:00:00Z",
            "finishedAtUTC": "2026-08-14T12:00:01Z",
            "requestSHA256": request_sha,
            "observerSourceSHA256": self.contract["capture"]["observerSourceSHA256"],
            "contractSHA256": self.contract_sha,
            "packageIdentity": self.package,
            "captureTree": tree,
            "process": {
                "executableSHA256": self.package[
                    "applicationExecutableSHA256"
                ],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": gate.packaged_evidence.descriptor(request_path, root),
                "result": gate.packaged_evidence.descriptor(result_path, root),
                "stdout": gate.packaged_evidence.descriptor(stdout_path, root),
                "stderr": gate.packaged_evidence.descriptor(stderr_path, root),
                "candidate": gate.packaged_evidence.descriptor(
                    candidate_path, root
                ),
                "packageIdentity": gate.packaged_evidence.descriptor(
                    package_path, root
                ),
                "attestation": gate.packaged_evidence.descriptor(
                    attestation_path, root
                ),
                "observerSource": gate.packaged_evidence.descriptor(
                    observer_source_path, root
                ),
                "contract": gate.packaged_evidence.descriptor(
                    contract_path, root
                ),
                "releaseConfiguration": gate.packaged_evidence.descriptor(
                    release_configuration_path, root
                ),
                "applicationArchive": gate.packaged_evidence.descriptor(
                    application_archive_path, root
                ),
                "producerSource": gate.packaged_evidence.descriptor(producer_path, root),
            },
        }
        write_canonical(root / "capture-record.json", record)
        return root

    def validate_binding(self, root: Path, repository: Path, runtime: Path) -> dict[str, object]:
        del repository, runtime
        record_path = root / "capture-record.json"
        record = gate.load_json(record_path)
        if record_path.read_bytes() != gate.packaged_evidence.canonical_bytes(record):
            raise gate.packaged_evidence.PackagedEvidenceError("record is noncanonical")
        paths = {
            key: gate.packaged_evidence.checked_artifact(root, value, key)
            for key, value in record["artifacts"].items()
        }
        request = gate.load_json(paths["request"])
        result = gate.load_json(paths["result"])
        tree = gate.packaged_evidence.capture_tree(root / "capture")
        valid = (
            paths["request"].read_bytes() == gate.packaged_evidence.canonical_bytes(request)
            and paths["result"].read_bytes() == gate.packaged_evidence.canonical_bytes(result)
            and gate.sha256_file(paths["request"])
            == record["requestSHA256"] == result["requestSHA256"]
            and request["packageIdentity"] == result["packageIdentity"]
            == record["packageIdentity"] == self.package
            and request["contractSHA256"] == result["contractSHA256"]
            == record["contractSHA256"] == self.contract_sha
            and result["captureTree"] == record["captureTree"] == tree
        )
        if not valid:
            raise gate.packaged_evidence.PackagedEvidenceError(
                "generic packaged binding differs"
            )
        return {
            "lane": "recovery",
            "contractSHA256": self.contract_sha,
            "packageIdentity": self.package,
        }

    def evaluate(self) -> tuple[dict[str, object], dict[str, object]]:
        with patch.object(
            gate.packaged_evidence, "validate_capture_binding",
            side_effect=self.validate_binding,
        ), patch.object(
            gate.packaged_evidence, "committed_bytes",
            return_value=self.producer_bytes,
        ):
            return gate.evaluate_packaged_pair(
                self.contract_path, self.first_root, self.second_root,
                self.repository, self.runtime, verify_tools=False,
            )

    @staticmethod
    def external(root: Path, identifier: str) -> tuple[Path, dict[str, object]]:
        path = root / "capture" / "scenarios" / identifier / "evidence.json"
        return path, gate.load_json(path)

    def rewrite_external(self, root: Path, identifier: str, value: dict[str, object]) -> None:
        capture_root = root / "capture"
        path = capture_root / "scenarios" / identifier / "evidence.json"
        write_pretty(path, value)
        capture_path = capture_root / "capture.json"
        capture = gate.load_json(capture_path)
        row = next(item for item in capture["scenarios"] if item["id"] == identifier)
        row["externalEvidenceArtifact"] = gate.descriptor(path, capture_root)
        write_pretty(capture_path, capture)
        self.reseal(root)

    @staticmethod
    def reseal(root: Path) -> None:
        capture_root = root / "capture"
        capture_path = capture_root / "capture.json"
        result_path = root / "observer" / "result.json"
        result = gate.load_json(result_path)
        result["captureManifest"] = {
            "fileName": "capture.json",
            "byteCount": capture_path.stat().st_size,
            "sha256": gate.sha256_file(capture_path),
        }
        result["captureTree"] = gate.packaged_evidence.capture_tree(capture_root)
        write_canonical(result_path, result)
        stdout_path = root / "observer" / "stdout.bin"
        stdout_path.write_bytes(
            gate.packaged_evidence.RESULT_PREFIX
            + base64.b64encode(result_path.read_bytes()) + b"\n"
        )
        record_path = root / "capture-record.json"
        record = gate.load_json(record_path)
        record["captureTree"] = result["captureTree"]
        record["artifacts"]["result"] = gate.packaged_evidence.descriptor(result_path, root)
        record["artifacts"]["stdout"] = gate.packaged_evidence.descriptor(stdout_path, root)
        write_canonical(record_path, record)


class RecoveryQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = PackagedRecoveryFixture(Path(self.temporary.name))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def testDualArchivedExecutableCapturesPassAllLockedScenarios(self) -> None:
        report, manifest = self.fixture.evaluate()
        self.assertTrue(report["releaseEligible"] and report["recoveryGatePass"])
        self.assertEqual(report["execution"]["kind"], "archived_application_executable")
        self.assertTrue(report["execution"]["applicationArchiveExecuted"])
        self.assertEqual(report["execution"]["independentProcessCaptureCount"], 2)
        self.assertEqual(len(report["captures"]), 2)
        self.assertEqual(len(report["scenarios"]), 15)
        self.assertTrue(all(row["repeatIdentityPass"] for row in report["scenarios"]))
        self.assertEqual(manifest["artifactSetSHA256"], gate.artifact_set_sha(manifest["artifacts"]))

    def testRawRecoveredStateTamperFailsAfterReseal(self) -> None:
        state = self.fixture.first_root / "capture/scenarios/append-only-event-boundary/recovered-state/state.bin"
        state.write_bytes(b"substituted durable state")
        self.fixture.reseal(self.fixture.first_root)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "state artifact differs"):
            self.fixture.evaluate()

    def testRehashedCrossScenarioOutputForgeryFailsOwnership(self) -> None:
        source_id = "final-assembly-boundary"
        _, source = self.fixture.external(self.fixture.first_root, source_id)
        _, target = self.fixture.external(self.fixture.first_root, "pause-resume")
        source["referenceOutputArtifact"] = copy.deepcopy(target["referenceOutputArtifact"])
        source["resumedOutputArtifact"] = copy.deepcopy(target["resumedOutputArtifact"])
        capture_root = self.fixture.first_root / "capture"
        causal_path = capture_root / "scenarios" / source_id / "causal-binding.json"
        causal = gate.load_json(causal_path)
        causal["referenceOutputSHA256"] = target["referenceOutputArtifact"]["sha256"]
        causal["resumedOutputSHA256"] = target["resumedOutputArtifact"]["sha256"]
        write_pretty(causal_path, causal)
        source["causalBindingArtifact"] = gate.descriptor(causal_path, capture_root)
        self.fixture.rewrite_external(self.fixture.first_root, source_id, source)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "not owned by its scenario"):
            self.fixture.evaluate()

    def testRehashedDerivationRelabelFailsRecomputation(self) -> None:
        identifier = "append-only-event-boundary"
        root = self.fixture.first_root
        capture_root = root / "capture"
        _, external = self.fixture.external(root, identifier)
        reference = gate.checked_path(capture_root, external["referenceDerivationArtifact"]["path"], "reference")
        resumed = gate.checked_path(capture_root, external["resumedDerivationArtifact"]["path"], "resumed")
        forged = gate.load_json(reference)
        forged["values"]["appliedEventCount"] = 99
        reference.write_bytes(gate.compact_json(forged))
        resumed.write_bytes(gate.compact_json(forged))
        external["referenceDerivationArtifact"] = gate.descriptor(reference, capture_root)
        external["resumedDerivationArtifact"] = gate.descriptor(resumed, capture_root)
        causal_path = capture_root / "scenarios" / identifier / "causal-binding.json"
        causal = gate.load_json(causal_path)
        causal["referenceDerivationSHA256"] = gate.sha256_file(reference)
        causal["resumedDerivationSHA256"] = gate.sha256_file(resumed)
        write_pretty(causal_path, causal)
        external["causalBindingArtifact"] = gate.descriptor(causal_path, capture_root)
        self.fixture.rewrite_external(root, identifier, external)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "derivation is not independently identical"):
            self.fixture.evaluate()

    def testRehashedTranscriptStateSubstitutionFailsCausalBinding(self) -> None:
        identifier = "checkpoint-publish-boundary"
        root = self.fixture.first_root
        capture_root = root / "capture"
        _, external = self.fixture.external(root, identifier)
        transcript = gate.checked_path(capture_root, external["transcriptArtifact"]["path"], "transcript")
        value = gate.load_json(transcript)
        value["events"][-1]["durableStateSHA256"] = fixture_sha("foreign-state")
        write_pretty(transcript, value)
        external["transcriptArtifact"] = gate.descriptor(transcript, capture_root)
        causal_path = capture_root / "scenarios" / identifier / "causal-binding.json"
        causal = gate.load_json(causal_path)
        causal["transcriptSHA256"] = gate.sha256_file(transcript)
        write_pretty(causal_path, causal)
        external["causalBindingArtifact"] = gate.descriptor(causal_path, capture_root)
        self.fixture.rewrite_external(root, identifier, external)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "transcript is not bound to recovered state"):
            self.fixture.evaluate()

    def testIndividuallyValidCrossProcessOutputSubstitutionFails(self) -> None:
        identifier = "atomic-output-publish-boundary"
        root = self.fixture.second_root
        capture_root = root / "capture"
        _, external = self.fixture.external(root, identifier)
        reference = gate.checked_path(capture_root, external["referenceOutputArtifact"]["path"], "reference")
        resumed = gate.checked_path(capture_root, external["resumedOutputArtifact"]["path"], "resumed")
        reference.write_bytes(b"second-process-substitution")
        resumed.write_bytes(b"second-process-substitution")
        external["referenceOutputArtifact"] = gate.descriptor(reference, capture_root)
        external["resumedOutputArtifact"] = gate.descriptor(resumed, capture_root)
        causal_path = capture_root / "scenarios" / identifier / "causal-binding.json"
        causal = gate.load_json(causal_path)
        causal["referenceOutputSHA256"] = gate.sha256_file(reference)
        causal["resumedOutputSHA256"] = gate.sha256_file(resumed)
        write_pretty(causal_path, causal)
        external["causalBindingArtifact"] = gate.descriptor(causal_path, capture_root)
        self.fixture.rewrite_external(root, identifier, external)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "cross-process recovery output differs"):
            self.fixture.evaluate()

    def testArchivedExecutableClaimCannotBeRelabeled(self) -> None:
        root = self.fixture.first_root
        capture_path = root / "capture/capture.json"
        capture = gate.load_json(capture_path)
        capture["execution"]["applicationArchiveExecuted"] = False
        write_pretty(capture_path, capture)
        self.fixture.reseal(root)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "did not execute inside the exact archived application"):
            self.fixture.evaluate()

    def testProcessesMustBeIndependent(self) -> None:
        first = gate.load_json(self.fixture.first_root / "observer/result.json")
        second_path = self.fixture.second_root / "observer/result.json"
        second = gate.load_json(second_path)
        second["process"]["processID"] = first["process"]["processID"]
        write_canonical(second_path, second)
        self.fixture.reseal(self.fixture.second_root)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "not independent processes and requests"):
            self.fixture.evaluate()

    def testExtraRawCaptureFileFailsAfterReseal(self) -> None:
        (self.fixture.first_root / "capture/unclaimed.bin").write_bytes(b"unclaimed")
        self.fixture.reseal(self.fixture.first_root)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "capture file set differs from causal evidence"):
            self.fixture.evaluate()

    def testScenarioStateArtifactCannotEscapeItsScenario(self) -> None:
        root = self.fixture.first_root
        _, source = self.fixture.external(root, "segment-commit-boundary")
        _, target = self.fixture.external(root, "checkpoint-publish-boundary")
        source["recoveredStateManifestArtifact"] = copy.deepcopy(target["recoveredStateManifestArtifact"])
        self.fixture.rewrite_external(root, "segment-commit-boundary", source)
        with self.assertRaisesRegex(gate.RecoveryEvidenceError, "not owned by its scenario"):
            self.fixture.evaluate()

    def testCheckedInContractPinsEveryNormativeRecoveryTool(self) -> None:
        contract_path = SCRIPT_DIRECTORY / "recovery-qualification-contract-v1.json"
        contract, digest = gate.load_contract(contract_path)
        self.assertEqual(contract["schemaVersion"], gate.CONTRACT_SCHEMA)
        self.assertEqual(digest, gate.sha256_file(contract_path))


if __name__ == "__main__":
    unittest.main()
