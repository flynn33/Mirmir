#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "recovery_qualification_v4",
    SCRIPT_DIRECTORY / "recovery_qualification_v4.py",
)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

CANDIDATE_TESTS_SPEC = importlib.util.spec_from_file_location(
    "recovery_release_candidate_fixtures_v4",
    SCRIPT_DIRECTORY / "test_prepare_release_candidate_v4.py",
)
assert (
    CANDIDATE_TESTS_SPEC is not None
    and CANDIDATE_TESTS_SPEC.loader is not None
)
candidate_tests = importlib.util.module_from_spec(CANDIDATE_TESTS_SPEC)
CANDIDATE_TESTS_SPEC.loader.exec_module(candidate_tests)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gate.pretty_json(value))


class RecoveryQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.sealed_fixture_index = 0
        self.evidence_root = Path(self.temporary.name) / "evidence"
        self.capture_root = self.evidence_root / "recovery" / "capture"
        self.capture_root.mkdir(parents=True)
        self.contract = json.loads(
            (SCRIPT_DIRECTORY / "recovery-qualification-contract-v1.json").read_text()
        )
        self.contract["capture"] = {
            "archiveProvenanceSourceSHA256": "0" * 64,
            "captureSourceSHA256": "1" * 64,
            "evaluatorSourceSHA256": "2" * 64,
            "packagedEvidenceSourceSHA256": "4" * 64,
            "runnerSourceSHA256": "3" * 64,
        }
        self.contract_path = self.evidence_root / "contract.json"
        write_json(self.contract_path, self.contract)
        self.contract_sha = gate.sha256_file(self.contract_path)
        self.repository = Path(self.temporary.name) / "repository"
        self.repository.mkdir()
        self.runtime = self.repository / "Mirmir/Resources/ASH-P06.bundle"
        self.runtime.mkdir(parents=True)
        self.runtime_manifest = self.runtime / "runtime-manifest.json"
        self.runtime_manifest.write_bytes(b'{"runtime":"fixture"}')
        self.release_configuration = (
            self.repository / "script/v4/release-candidate-v4.xcconfig"
        )
        self.release_configuration.parent.mkdir(parents=True)
        self.release_configuration.write_bytes(b"SWIFT_OPTIMIZATION_LEVEL = -O\n")
        self.application_archive = (
            self.evidence_root / "recovery/bindings/application-archive.zip"
        )
        self.application_archive.parent.mkdir(parents=True)
        self.application_archive.write_bytes(b"sealed-release-application")

        self.candidate = {
            "sourceCommit": "a" * 40,
            "sourceTreeIdentitySHA256": "b" * 64,
            "runtimeManifestSHA256": "c" * 64,
            "runtimeManifestFileSHA256": gate.sha256_file(self.runtime_manifest),
            "runtimeArtifactSetSHA256": "e" * 64,
            "runtimeSourceRevision": "f" * 64,
            "releaseConfigurationSHA256": gate.sha256_file(
                self.release_configuration
            ),
            "appBundleSHA256": gate.sha256_file(self.application_archive),
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        self.candidate_path = self.application_archive.parent / "candidate.json"
        write_json(self.candidate_path, self.candidate)
        self.attestation = {
            "schemaVersion": gate.ATTESTATION_SCHEMA,
            "buildConfiguration": "Release",
            "source": {
                "commit": self.candidate["sourceCommit"],
                "treeIdentitySHA256": self.candidate[
                    "sourceTreeIdentitySHA256"
                ],
            },
            "runtime": {
                "artifactSetSHA256": self.candidate[
                    "runtimeArtifactSetSHA256"
                ],
                "bundleRepositoryRelativePath": "Mirmir/Resources/ASH-P06.bundle",
                "manifestFileSHA256": self.candidate[
                    "runtimeManifestFileSHA256"
                ],
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
            },
            "releaseConfiguration": {
                "repositoryRelativePath": "script/v4/release-candidate-v4.xcconfig",
                "sha256": self.candidate["releaseConfigurationSHA256"],
            },
            "application": {
                "bundleIdentifier": self.candidate["bundleIdentifier"],
                "productVersion": self.candidate["productVersion"],
                "productBuild": self.candidate["productBuild"],
                "codeDirectories": [
                    {"architecture": "arm64", "sha256": "1" * 64},
                    {"architecture": "x86_64", "sha256": "2" * 64},
                ],
            },
            "sourceBuild": {
                "build": {
                    "configuration": "Release",
                    "destination": "generic/platform=macOS",
                    "settings": {
                        "CODE_SIGN_IDENTITY": "-",
                        "ENABLE_TESTABILITY": "NO",
                    },
                    "command": [
                        "xcodebuild",
                        "-configuration",
                        "Release",
                        "ENABLE_TESTABILITY=NO",
                    ],
                }
            },
        }
        attestation_bytes = gate.packaged_evidence.canonical_bytes(
            self.attestation
        )
        self.package_identity = {
            "schemaVersion": gate.PACKAGE_SCHEMA,
            "buildConfiguration": "Release",
            "applicationArchiveSHA256": self.candidate["appBundleSHA256"],
            "applicationPayloadIdentitySHA256": "3" * 64,
            "applicationInfoPlistSHA256": "4" * 64,
            "applicationExecutableSHA256": "5" * 64,
            "codeDirectories": copy.deepcopy(
                self.attestation["application"]["codeDirectories"]
            ),
            "codeDirectorySetSHA256": "6" * 64,
            "designatedRequirementSHA256": "7" * 64,
            "releaseConfigurationSHA256": self.candidate[
                "releaseConfigurationSHA256"
            ],
            "attestationSHA256": gate.sha256_bytes(attestation_bytes),
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate[
                "sourceTreeIdentitySHA256"
            ],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeManifestFileSHA256": self.candidate[
                "runtimeManifestFileSHA256"
            ],
            "runtimeArtifactSetSHA256": self.candidate[
                "runtimeArtifactSetSHA256"
            ],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "bundleIdentifier": self.candidate["bundleIdentifier"],
            "productVersion": self.candidate["productVersion"],
            "productBuild": self.candidate["productBuild"],
        }
        self.package_identity_path = (
            self.application_archive.parent / "package-identity.json"
        )
        self.attestation_path = (
            self.application_archive.parent
            / "MirmirV4ReleaseBuildAttestation.json"
        )
        self.package_identity_path.write_bytes(
            gate.packaged_evidence.canonical_bytes(self.package_identity)
        )
        self.attestation_path.write_bytes(attestation_bytes)
        self.release_configuration_artifact = (
            self.application_archive.parent / "release-candidate-v4.xcconfig"
        )
        self.release_configuration_artifact.write_bytes(
            self.release_configuration.read_bytes()
        )
        self.runtime_manifest_artifact = (
            self.application_archive.parent / "runtime-manifest.json"
        )
        self.runtime_manifest_artifact.write_bytes(
            self.runtime_manifest.read_bytes()
        )
        self.inspected_package = {
            "candidate": copy.deepcopy(self.candidate),
            "identity": copy.deepcopy(self.package_identity),
            "attestation": copy.deepcopy(self.attestation),
        }
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

    def _fake_package_verifier(
        self,
        repository: Path,
        candidate_path: Path,
        application_archive: Path,
        runtime: Path,
        release_configuration: Path,
    ) -> dict[str, object]:
        del repository
        candidate = gate.load_candidate(candidate_path)
        if gate.sha256_file(application_archive) != candidate["appBundleSHA256"]:
            raise gate.RecoveryEvidenceError(
                "fixture archive differs from the exact candidate"
            )
        if (
            gate.sha256_file(runtime / "runtime-manifest.json")
            != candidate["runtimeManifestFileSHA256"]
            or gate.sha256_file(release_configuration)
            != candidate["releaseConfigurationSHA256"]
        ):
            raise gate.RecoveryEvidenceError(
                "fixture runtime or configuration differs"
            )
        return copy.deepcopy(self.inspected_package)

    def _package_report(self) -> dict[str, object]:
        return gate.bind_or_verify_package_evidence(
            repository=self.repository,
            candidate_path=self.candidate_path,
            application_archive=self.application_archive,
            runtime=self.runtime,
            release_configuration=self.release_configuration,
            release_configuration_artifact=(
                self.release_configuration_artifact
            ),
            runtime_manifest_artifact=self.runtime_manifest_artifact,
            package_identity_path=self.package_identity_path,
            attestation_path=self.attestation_path,
            contract=self.contract,
            write_artifacts=False,
            verifier=self._fake_package_verifier,
        )

    def _stage_real_archive_cli_fixture(
        self,
        *,
        archive_variant: str = "primary",
        runtime_variant: str = "primary",
        configuration_variant: str = "primary",
        tamper_attestation: bool = False,
    ) -> dict[str, object]:
        self.sealed_fixture_index += 1
        fixture_root = (
            Path(self.temporary.name)
            / f"sealed-archive-fixture-{self.sealed_fixture_index}"
        )
        fixture_root.mkdir()
        fixture = candidate_tests.Fixture(fixture_root)
        primary_archive = fixture.make_sealed_archive("primary")
        candidate = fixture.prepare(primary_archive)

        selected_archive = primary_archive
        if archive_variant == "alternate":
            selected_archive = fixture.make_sealed_archive(
                "alternate",
                executable_source=fixture.alternate_executable,
                source_build_runner=fixture.self_asserting_build_runner,
            )
        elif archive_variant != "primary":
            raise AssertionError(f"unsupported archive fixture: {archive_variant}")
        if tamper_attestation:
            tampered_archive = fixture_root / "tampered-attestation.zip"
            candidate_tests.rewrite_archive(
                selected_archive,
                tampered_archive,
                {
                    candidate_tests.provenance.ATTESTATION_PATH: b"{}\n",
                },
            )
            selected_archive = tampered_archive

        selected_runtime = (
            fixture.runtime
            if runtime_variant == "primary"
            else fixture.alternate_runtime
        )
        if runtime_variant not in {"primary", "alternate"}:
            raise AssertionError(f"unsupported runtime fixture: {runtime_variant}")
        selected_configuration = (
            fixture.release_configuration
            if configuration_variant == "primary"
            else fixture.alternate_configuration
        )
        if configuration_variant not in {"primary", "alternate"}:
            raise AssertionError(
                f"unsupported configuration fixture: {configuration_variant}"
            )

        binding_root = self.application_archive.parent
        bound_files = (
            "recovery-qualification-contract-v1.json",
            "RecoveryQualificationCaptureTests.swift",
            "release_candidate_archive_v4.py",
            "packaged_candidate_evidence_v4.py",
            "recovery_qualification_v4.py",
            "run_recovery_qualification_v4.sh",
        )
        for name in bound_files:
            shutil.copyfile(SCRIPT_DIRECTORY / name, binding_root / name)
        bound_contract = binding_root / "recovery-qualification-contract-v1.json"
        bound_evaluator = binding_root / "recovery_qualification_v4.py"

        shutil.copyfile(selected_archive, self.application_archive)
        write_json(self.candidate_path, candidate)
        shutil.copyfile(
            fixture.release_configuration,
            self.release_configuration_artifact,
        )
        shutil.copyfile(
            fixture.runtime / "runtime-manifest.json",
            self.runtime_manifest_artifact,
        )
        self.package_identity_path.unlink(missing_ok=True)
        self.attestation_path.unlink(missing_ok=True)

        contract = json.loads(bound_contract.read_text())
        capture = json.loads(self.capture_path.read_text())
        capture.update(
            {
                "contractSHA256": gate.sha256_file(bound_contract),
                "captureSourceSHA256": contract["capture"][
                    "captureSourceSHA256"
                ],
                "sourceCommit": candidate["sourceCommit"],
                "sourceTreeSHA256": candidate[
                    "sourceTreeIdentitySHA256"
                ],
            }
        )
        write_json(self.capture_path, capture)

        role_root = self.evidence_root / "recovery"
        report = role_root / "recovery-report.json"
        capture_manifest = self.capture_root / "artifact-manifest.json"
        sealed_manifest = role_root / "artifact-manifest.json"
        common = [
            "--repository",
            str(fixture.repository),
            "--contract",
            str(bound_contract),
            "--capture",
            str(self.capture_path),
            "--candidate",
            str(self.candidate_path),
            "--application-archive",
            str(self.application_archive),
            "--runtime",
            str(selected_runtime),
            "--runtime-manifest-artifact",
            str(self.runtime_manifest_artifact),
            "--release-configuration",
            str(selected_configuration),
            "--release-configuration-artifact",
            str(self.release_configuration_artifact),
            "--package-identity",
            str(self.package_identity_path),
            "--attestation",
            str(self.attestation_path),
            "--evidence-root",
            str(self.evidence_root),
            "--capture-manifest",
            str(capture_manifest),
            "--sealed-manifest",
            str(sealed_manifest),
        ]
        environment = dict(os.environ)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return {
            "candidate": candidate,
            "fixture": fixture,
            "boundEvaluator": bound_evaluator,
            "common": common,
            "environment": environment,
            "report": report,
            "captureManifest": capture_manifest,
            "sealedManifest": sealed_manifest,
        }

    def _run_real_archive_cli(
        self,
        staged: dict[str, object],
        command: str,
    ) -> subprocess.CompletedProcess[str]:
        output_option = "--output" if command == "evaluate" else "--report"
        arguments = [
            sys.executable,
            str(staged["boundEvaluator"]),
            command,
            *staged["common"],
            output_option,
            str(staged["report"]),
        ]
        return subprocess.run(
            arguments,
            cwd=self.evidence_root,
            env=staged["environment"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def _make_source_export_repository(
        self,
        name: str,
        attribute: str | None = None,
    ) -> tuple[Path, str, dict[str, str]]:
        root = Path(self.temporary.name) / f"source-export-{name}"
        repository = root / "repository"
        home = root / "home"
        repository.mkdir(parents=True)
        home.mkdir()
        environment = {
            **gate.packaged_evidence.archive_provenance.git_environment(),
            "HOME": str(home),
        }

        def run_git(*arguments: str) -> str:
            process = subprocess.run(
                ["/usr/bin/git", *arguments],
                cwd=repository,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            return process.stdout.strip()

        run_git("init", "-q")
        source = "literal source\n"
        if attribute == "export-subst":
            source = "commit:$Format:%H$\n"
        (repository / "source.txt").write_text(source, encoding="utf-8")
        executable = repository / "tool.sh"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        if attribute is not None:
            (repository / ".gitattributes").write_text(
                f"source.txt {attribute}\n",
                encoding="utf-8",
            )
        run_git("add", "--all")
        run_git(
            "-c",
            "user.name=Recovery Fixture",
            "-c",
            "user.email=recovery@example.invalid",
            "commit",
            "-q",
            "-m",
            "source export fixture",
        )
        return repository, run_git("rev-parse", "HEAD"), environment

    def _run_source_export_cli(
        self,
        repository: Path,
        destination: Path,
        environment: dict[str, str],
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT_DIRECTORY / "recovery_qualification_v4.py"),
                "export-source",
                "--repository",
                str(repository),
                "--revision",
                "HEAD",
                "--destination",
                str(destination),
            ],
            cwd=repository,
            env={**environment, "PYTHONDONTWRITEBYTECODE": "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def _evaluate(self):
        return gate.evaluate_capture(
            self.contract_path,
            self.capture_path,
            self.candidate_path,
            self.evidence_root,
            self._package_report(),
            verify_tools=False,
        )

    def testValidCaptureRecomputesEveryCoverageAndIdentity(self) -> None:
        report, manifest = self._evaluate()
        self.assertTrue(report["recoveryGatePass"])
        self.assertEqual(
            report["packagedCandidate"]["identity"],
            self.package_identity,
        )
        self.assertEqual(
            report["packagedCandidate"]["requiredArchitectures"],
            ["arm64", "x86_64"],
        )
        self.assertTrue(
            report["packagedCandidate"][
                "packageIdentityTestabilitySubstitutionRejected"
            ]
        )
        self.assertEqual(
            report["capture"]["execution"],
            {
                "applicationArchiveExecuted": False,
                "kind": "source_bound_xctest_host",
                "sourceBoundToCandidate": True,
            },
        )
        self.assertEqual(len(report["scenarios"]), len(gate.REQUIRED_COVERAGE))
        self.assertEqual(
            [item["coverage"][0] for item in report["scenarios"]],
            list(gate.REQUIRED_COVERAGE),
        )
        self.assertEqual(
            manifest["artifactSetSHA256"],
            gate.artifact_set_sha(manifest["artifacts"]),
        )
        identical = [
            item
            for item in report["scenarios"]
            if item["outcome"] == "identical_resumed_output"
        ]
        self.assertGreater(len(identical), 0)
        for item in identical:
            self.assertEqual(
                item["referenceOutputSHA256"],
                item["resumedOutputSHA256"],
            )
            self.assertEqual(
                item["referenceSemanticSHA256"],
                item["resumedSemanticSHA256"],
            )

    def testVerifiedSourceExportMatchesCommittedBytesAndModes(self) -> None:
        repository, commit, environment = self._make_source_export_repository(
            "valid"
        )
        destination = repository.parent / "exported"
        destination.mkdir()
        process = self._run_source_export_cli(
            repository,
            destination,
            environment,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assertEqual(result["schemaVersion"], gate.SOURCE_EXPORT_SCHEMA)
        self.assertEqual(result["sourceCommit"], commit)
        provenance = gate.packaged_evidence.archive_provenance
        expected = provenance.source_manifest_summary(
            provenance.committed_source_manifest(repository, commit)
        )
        self.assertEqual(result["sourceManifest"], expected)
        self.assertEqual(
            result["sourceManifest"],
            provenance.directory_source_manifest(destination),
        )
        self.assertEqual(
            (destination / "source.txt").read_text(encoding="utf-8"),
            "literal source\n",
        )
        self.assertEqual((destination / "tool.sh").stat().st_mode & 0o777, 0o755)

    def testVerifiedSourceExportRejectsGitAttributeMutation(self) -> None:
        for attribute in ("export-subst", "export-ignore"):
            with self.subTest(attribute=attribute):
                repository, _, environment = self._make_source_export_repository(
                    attribute,
                    attribute,
                )
                destination = repository.parent / "exported"
                destination.mkdir()
                process = self._run_source_export_cli(
                    repository,
                    destination,
                    environment,
                )
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("cannot export verified recovery source", process.stderr)
                self.assertRegex(
                    process.stderr,
                    r"git archive (size|content|file set) differs",
                )

    def testPackageArtifactsAreEmittedAndIncludedInRoleSeal(self) -> None:
        self.package_identity_path.unlink()
        self.attestation_path.unlink()
        observed = gate.bind_or_verify_package_evidence(
            repository=self.repository,
            candidate_path=self.candidate_path,
            application_archive=self.application_archive,
            runtime=self.runtime,
            release_configuration=self.release_configuration,
            release_configuration_artifact=(
                self.release_configuration_artifact
            ),
            runtime_manifest_artifact=self.runtime_manifest_artifact,
            package_identity_path=self.package_identity_path,
            attestation_path=self.attestation_path,
            contract=self.contract,
            write_artifacts=True,
            verifier=self._fake_package_verifier,
        )
        self.assertEqual(
            observed["packageIdentitySHA256"],
            gate.sha256_file(self.package_identity_path),
        )
        role_root = self.evidence_root / "recovery"
        manifest_path = role_root / "artifact-manifest.json"
        manifest = gate.make_suite_manifest(role_root, manifest_path)
        sealed_paths = {row["path"] for row in manifest["artifacts"]}
        self.assertTrue(
            {
                "bindings/MirmirV4ReleaseBuildAttestation.json",
                "bindings/application-archive.zip",
                "bindings/candidate.json",
                "bindings/package-identity.json",
                "bindings/release-candidate-v4.xcconfig",
                "bindings/runtime-manifest.json",
            }.issubset(sealed_paths)
        )

    def testExclusiveArtifactWriteRejectsSymlinkRaceWithoutClobber(self) -> None:
        root = Path(self.temporary.name) / "exclusive-write"
        root.mkdir()
        target = root / "package-identity.json"
        victim = Path(self.temporary.name) / "victim.json"
        victim.write_bytes(b"original")
        original_open = gate.os.open
        raced = False

        def racing_open(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal raced
            if dir_fd is not None and path == target.name and not raced:
                raced = True
                target.symlink_to(victim)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with patch.object(gate.os, "open", side_effect=racing_open):
            with self.assertRaisesRegex(
                gate.RecoveryEvidenceError,
                "refusing to overwrite|cannot create",
            ):
                gate.write_canonical_artifact(
                    target,
                    {"schemaVersion": "race-probe"},
                )
        self.assertTrue(raced)
        self.assertTrue(target.is_symlink())
        self.assertEqual(victim.read_bytes(), b"original")

    def testRuntimeDirectorySymlinkFailsClosed(self) -> None:
        runtime_link = self.repository / "runtime-link.bundle"
        runtime_link.symlink_to(self.runtime, target_is_directory=True)
        with self.assertRaisesRegex(
            gate.packaged_evidence.PackagedEvidenceError,
            "symbolic link or non-directory",
        ):
            gate.bind_or_verify_package_evidence(
                repository=self.repository,
                candidate_path=self.candidate_path,
                application_archive=self.application_archive,
                runtime=runtime_link,
                release_configuration=self.release_configuration,
                release_configuration_artifact=(
                    self.release_configuration_artifact
                ),
                runtime_manifest_artifact=self.runtime_manifest_artifact,
                package_identity_path=self.package_identity_path,
                attestation_path=self.attestation_path,
                contract=self.contract,
                write_artifacts=False,
                verifier=self._fake_package_verifier,
            )

    def testRealSealedArchiveEvaluateAndVerifyThroughCLI(self) -> None:
        staged = self._stage_real_archive_cli_fixture()
        evaluated = self._run_real_archive_cli(staged, "evaluate")
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        verified = self._run_real_archive_cli(staged, "verify")
        self.assertEqual(verified.returncode, 0, verified.stderr)
        report = json.loads(Path(staged["report"]).read_text())
        self.assertTrue(report["releaseEligible"])
        self.assertTrue(report["packagedCandidate"]["releaseAttestationPass"])
        self.assertEqual(
            report["packagedCandidate"]["identity"]["sourceCommit"],
            staged["candidate"]["sourceCommit"],
        )
        role_root = self.evidence_root / "recovery"
        self.assertEqual(list(role_root.rglob("*.pyc")), [])
        self.assertFalse(
            any(
                path.name == "__pycache__"
                for path in role_root.rglob("*")
            )
        )

    def testRealSealedArchiveSwapFailsClosedThroughCLI(self) -> None:
        staged = self._stage_real_archive_cli_fixture(
            archive_variant="alternate"
        )
        evaluated = self._run_real_archive_cli(staged, "evaluate")
        self.assertNotEqual(evaluated.returncode, 0)
        self.assertIn(
            "candidate record differs from the verified application archive",
            evaluated.stderr,
        )

    def testRealSealedArchiveRuntimeAndConfigurationMismatchFailClosed(self) -> None:
        for field in ("runtime_variant", "configuration_variant"):
            with self.subTest(field=field):
                arguments = {field: "alternate"}
                staged = self._stage_real_archive_cli_fixture(**arguments)
                evaluated = self._run_real_archive_cli(staged, "evaluate")
                self.assertNotEqual(evaluated.returncode, 0)
                self.assertIn(
                    "exact packaged candidate verification failed",
                    evaluated.stderr,
                )

    def testRealSealedArchiveAttestationTamperFailsClosedThroughCLI(self) -> None:
        staged = self._stage_real_archive_cli_fixture(tamper_attestation=True)
        evaluated = self._run_real_archive_cli(staged, "evaluate")
        self.assertNotEqual(evaluated.returncode, 0)
        self.assertIn(
            "exact packaged candidate verification failed",
            evaluated.stderr,
        )

    def testRealSealedArchiveBoundAttestationTamperFailsVerify(self) -> None:
        staged = self._stage_real_archive_cli_fixture()
        evaluated = self._run_real_archive_cli(staged, "evaluate")
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        value = json.loads(self.attestation_path.read_text())
        value["source"]["treeIdentitySHA256"] = "0" * 64
        self.attestation_path.write_bytes(
            gate.packaged_evidence.canonical_bytes(value)
        )
        verified = self._run_real_archive_cli(staged, "verify")
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("attestation artifact differs", verified.stderr)

    def testDiskFullIsMandatoryExplicitContainedCoverage(self) -> None:
        locked = next(
            item for item in self.contract["scenarios"]
            if item["coverageID"] == "disk_full"
        )
        self.assertEqual(locked["id"], "disk-full")
        self.assertEqual(locked["outcome"], "explicit_contained_failure")
        self.assertEqual(locked["containedFailureCode"], "disk_full_contained")
        report, _ = self._evaluate()
        observed = next(
            item for item in report["scenarios"]
            if item["coverage"][0] == "disk_full"
        )
        self.assertEqual(observed["outcome"], "explicit_contained_failure")
        self.assertEqual(observed["containedFailureCode"], "disk_full_contained")

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

    def testApplicationArchiveTamperFailsClosed(self) -> None:
        self.application_archive.write_bytes(b"tampered archive")
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "archive differs from the exact candidate",
        ):
            self._evaluate()

    def testReleaseAttestationArtifactTamperFailsClosed(self) -> None:
        value = copy.deepcopy(self.attestation)
        value["source"]["treeIdentitySHA256"] = "0" * 64
        self.attestation_path.write_bytes(
            gate.packaged_evidence.canonical_bytes(value)
        )
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "attestation artifact differs",
        ):
            self._evaluate()

    def testPackageIdentityArtifactTamperFailsClosed(self) -> None:
        value = copy.deepcopy(self.package_identity)
        value["applicationPayloadIdentitySHA256"] = "0" * 64
        self.package_identity_path.write_bytes(
            gate.packaged_evidence.canonical_bytes(value)
        )
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "package identity artifact differs",
        ):
            self._evaluate()

    def testRuntimeAndReleaseConfigurationArtifactsAreExact(self) -> None:
        self.runtime_manifest_artifact.write_bytes(b"another runtime")
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "sealed recovery runtime or Release configuration artifact differs",
        ):
            self._evaluate()

    def testReleaseConfigurationArtifactTamperFailsClosed(self) -> None:
        self.release_configuration_artifact.write_bytes(
            b"ENABLE_TESTABILITY = YES\n"
        )
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "sealed recovery runtime or Release configuration artifact differs",
        ):
            self._evaluate()

    def testRequiredPackageArchitectureSetFailsClosed(self) -> None:
        inspected = copy.deepcopy(self.inspected_package)
        inspected["identity"]["codeDirectories"] = [
            inspected["identity"]["codeDirectories"][0]
        ]
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "packaged candidate architecture set differs",
        ):
            gate.validate_inspected_package(
                inspected,
                self.candidate,
                self.contract,
            )

    def testTestabilityEnabledRebuildCannotSubstituteForPackage(self) -> None:
        inspected = copy.deepcopy(self.inspected_package)
        inspected["attestation"]["sourceBuild"]["build"]["settings"] = {
            "ENABLE_TESTABILITY": "YES"
        }
        inspected["attestation"]["sourceBuild"]["build"]["command"].append(
            "ENABLE_TESTABILITY=YES"
        )
        with self.assertRaisesRegex(
            gate.RecoveryEvidenceError,
            "testability-enabled rebuild cannot satisfy",
        ):
            gate.validate_inspected_package(
                inspected,
                self.candidate,
                self.contract,
            )

    def testTestabilityDisabledMustBePresentExactlyOnce(self) -> None:
        build_variants = (
            (
                "missing setting",
                {},
                [
                    "xcodebuild",
                    "-configuration",
                    "Release",
                    "ENABLE_TESTABILITY=NO",
                ],
            ),
            (
                "case variant",
                {"ENABLE_TESTABILITY": "no"},
                [
                    "xcodebuild",
                    "-configuration",
                    "Release",
                    "ENABLE_TESTABILITY=no",
                ],
            ),
            (
                "missing command argument",
                {"ENABLE_TESTABILITY": "NO"},
                ["xcodebuild", "-configuration", "Release"],
            ),
            (
                "contradictory command arguments",
                {"ENABLE_TESTABILITY": "NO"},
                [
                    "xcodebuild",
                    "-configuration",
                    "Release",
                    "ENABLE_TESTABILITY=NO",
                    "ENABLE_TESTABILITY=YES",
                ],
            ),
            (
                "duplicate command arguments",
                {"ENABLE_TESTABILITY": "NO"},
                [
                    "xcodebuild",
                    "-configuration",
                    "Release",
                    "ENABLE_TESTABILITY=NO",
                    "ENABLE_TESTABILITY=NO",
                ],
            ),
        )
        for name, settings, command in build_variants:
            with self.subTest(name=name):
                inspected = copy.deepcopy(self.inspected_package)
                build = inspected["attestation"]["sourceBuild"]["build"]
                build["settings"] = settings
                build["command"] = command
                with self.assertRaisesRegex(
                    gate.RecoveryEvidenceError,
                    "testability-enabled rebuild cannot satisfy",
                ):
                    gate.validate_inspected_package(
                        inspected,
                        self.candidate,
                        self.contract,
                    )

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
