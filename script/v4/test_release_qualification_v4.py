#!/usr/bin/env python3
"""Fail-closed tests for the M7 release-qualification evidence aggregator."""

from __future__ import annotations

import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "release_qualification_v4", SCRIPT_DIRECTORY / "release_qualification_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
qualification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualification)

P05_SPEC = importlib.util.spec_from_file_location(
    "p05_baseline_v4", SCRIPT_DIRECTORY / "p05_baseline_v4.py"
)
assert P05_SPEC is not None and P05_SPEC.loader is not None
p05_replay = importlib.util.module_from_spec(P05_SPEC)
sys.modules["p05_baseline_v4"] = p05_replay
P05_SPEC.loader.exec_module(p05_replay)

QUALITY_SPEC = importlib.util.spec_from_file_location(
    "quality_gate_v4_for_release_tests",
    SCRIPT_DIRECTORY / "quality_gate_v4.py",
)
assert QUALITY_SPEC is not None and QUALITY_SPEC.loader is not None
quality_replay = importlib.util.module_from_spec(QUALITY_SPEC)
QUALITY_SPEC.loader.exec_module(quality_replay)

TRUST_SPEC = importlib.util.spec_from_file_location(
    "release_qualification_trust_v4_for_tests",
    SCRIPT_DIRECTORY / "release_qualification_trust_v4.py",
)
assert TRUST_SPEC is not None and TRUST_SPEC.loader is not None
trust_builder = importlib.util.module_from_spec(TRUST_SPEC)
TRUST_SPEC.loader.exec_module(trust_builder)

PERFORMANCE_SPEC = importlib.util.spec_from_file_location(
    "performance_gate_v4_for_release_tests",
    SCRIPT_DIRECTORY / "performance_gate_v4.py",
)
assert PERFORMANCE_SPEC is not None and PERFORMANCE_SPEC.loader is not None
performance_gate = importlib.util.module_from_spec(PERFORMANCE_SPEC)
PERFORMANCE_SPEC.loader.exec_module(performance_gate)

SUPPORT_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "support_matrix_fixture_for_release_tests",
    SCRIPT_DIRECTORY / "test_support_matrix_v4.py",
)
assert SUPPORT_FIXTURE_SPEC is not None and SUPPORT_FIXTURE_SPEC.loader is not None
support_fixture_module = importlib.util.module_from_spec(SUPPORT_FIXTURE_SPEC)
SUPPORT_FIXTURE_SPEC.loader.exec_module(support_fixture_module)

PARITY_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "cpu_metal_parity_fixture_for_release_tests",
    SCRIPT_DIRECTORY / "test_cpu_metal_parity_v4.py",
)
assert PARITY_FIXTURE_SPEC is not None and PARITY_FIXTURE_SPEC.loader is not None
parity_fixture_module = importlib.util.module_from_spec(PARITY_FIXTURE_SPEC)
PARITY_FIXTURE_SPEC.loader.exec_module(parity_fixture_module)

MEDIA_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "media_preservation_fixture_for_release_tests",
    SCRIPT_DIRECTORY / "test_media_preservation_v4.py",
)
assert MEDIA_FIXTURE_SPEC is not None and MEDIA_FIXTURE_SPEC.loader is not None
media_fixture_module = importlib.util.module_from_spec(MEDIA_FIXTURE_SPEC)
MEDIA_FIXTURE_SPEC.loader.exec_module(media_fixture_module)

RECOVERY_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "recovery_fixture_for_release_tests",
    SCRIPT_DIRECTORY / "test_recovery_qualification_v4.py",
)
assert RECOVERY_FIXTURE_SPEC is not None and RECOVERY_FIXTURE_SPEC.loader is not None
recovery_fixture_module = importlib.util.module_from_spec(RECOVERY_FIXTURE_SPEC)
RECOVERY_FIXTURE_SPEC.loader.exec_module(recovery_fixture_module)


def identity(label: str) -> str:
    return qualification.sha256_bytes(label.encode("utf-8"))


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def descriptor(path: Path, root: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(root).as_posix(),
        "byteCount": path.stat().st_size,
        "sha256": qualification.sha256(path),
    }


class EvidenceFixture:
    def __init__(self, root: Path):
        self.root = root
        self.contract_path = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
        self.contract = json.loads(self.contract_path.read_text())
        runtime_revision = "b" * 64
        self.builder_bytes = b"#!/bin/sh\n# locked production P06 builder\n"
        self.toolchain_bytes = qualification.canonical_bytes(
            {"xcode": "locked-release", "metal": "locked-release"}
        )
        self.runtime_artifacts: dict[str, bytes] = {}
        runtime_declarations = []
        for role in self.contract["p06RuntimeArtifactRoles"]:
            relative = (
                "artifacts/ash-p06.metallib"
                if role == "metal_library"
                else f"artifacts/{role}.json"
            )
            content = f"locked-production-p06-{role}".encode("utf-8")
            self.runtime_artifacts[relative] = content
            runtime_declarations.append(
                {
                    "role": role,
                    "relativePath": relative,
                    "schemaID": f"ash.p06.{role.replace('_', '-')}.v1",
                    "contentSHA256": qualification.sha256_bytes(content),
                    "byteCount": len(content),
                }
            )
        runtime_manifest = {
            "schemaID": "ash.p06.runtime-manifest.v1",
            "runtimeID": "ash-p06-deterministic-v4",
            "releaseStatus": "release_qualified",
            "provenance": {
                "sourceRevision": runtime_revision,
                "builderID": "mirmir-p06-release-builder-v1",
                "builderSourceSHA256": qualification.sha256_bytes(self.builder_bytes),
                "buildParametersSHA256": identity("p06-build-parameters"),
                "inputSetSHA256": identity("p06-input-set"),
                "metalLibrarySHA256": qualification.sha256_bytes(
                    self.runtime_artifacts["artifacts/ash-p06.metallib"]
                ),
                "toolchain": {
                    "swiftCompilerIdentity": "Apple Swift release toolchain",
                    "metalCompilerIdentity": "Apple Metal release toolchain",
                    "metalLanguageVersion": "4.0",
                    "sdkBuildIdentity": "macOS release SDK",
                    "deploymentTarget": "15.0",
                    "targetTriple": "arm64-apple-macos15.0",
                },
            },
            "artifacts": runtime_declarations,
        }
        self.toolchain_bytes = qualification.canonical_bytes(
            runtime_manifest["provenance"]["toolchain"]
        )
        self.runtime_provenance_sha256 = qualification.sha256_bytes(
            b"ash-p06-runtime-provenance-v4\0"
            + qualification.canonical_bytes(runtime_manifest["provenance"])
        )
        runtime_bytes = qualification.canonical_bytes(runtime_manifest)
        release_bytes = b'CONFIGURATION=Release\nSWIFT_OPTIMIZATION_LEVEL=-O\n'
        app_bytes = b"notarized-and-stapled-mirmir-app-archive"
        runtime_set_entries = [
            (relative, qualification.sha256_bytes(content))
            for relative, content in self.runtime_artifacts.items()
        ] + [("runtime-manifest.json", qualification.sha256_bytes(runtime_bytes))]
        self.candidate = {
            "sourceCommit": "a" * 40,
            "sourceTreeIdentitySHA256": identity("source-tree"),
            "runtimeManifestSHA256": qualification.sha256_bytes(runtime_bytes),
            "runtimeManifestFileSHA256": qualification.sha256_bytes(runtime_bytes),
            "runtimeArtifactSetSHA256": qualification.artifact_set_sha(
                runtime_set_entries
            ),
            "runtimeSourceRevision": runtime_revision,
            "releaseConfigurationSHA256": qualification.sha256_bytes(release_bytes),
            "appBundleSHA256": qualification.sha256_bytes(app_bytes),
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        self.runtime_bytes = runtime_bytes
        self.candidate["runtimeManifestSHA256"] = qualification.ash_canonical_identity(
            "ash-p06-runtime-manifest-v4", runtime_manifest
        )
        self.release_bytes = release_bytes
        self.app_bytes = app_bytes
        self.entries: list[dict[str, object]] = []
        self._build_quality()
        self._build_common_reports()
        self.index = {
            "schemaVersion": qualification.SCHEMA_CANDIDATE,
            "candidate": self.candidate,
            "waivers": [],
            "evidence": self.entries,
        }
        self.index_path = root / "release-candidate-evidence.json"
        self.save_index()

    def save_index(self) -> None:
        write_json(self.index_path, self.index)

    def _write_bound_files(self, role_dir: Path, role: str, contract_value: object) -> tuple[Path, Path, Path]:
        contract_path = role_dir / "suite-contract.json"
        runtime_path = role_dir / "runtime-manifest.json"
        release_path = role_dir / "Release.xcconfig"
        write_json(contract_path, contract_value)
        runtime_path.write_bytes(self.runtime_bytes)
        release_path.write_bytes(self.release_bytes)
        return contract_path, runtime_path, release_path

    def _seal_and_add(
        self,
        role: str,
        report: dict[str, object],
        contract_path: Path,
        runtime_path: Path,
        release_path: Path | None,
        extra_bindings: list[tuple[str, Path]],
        existing_report_path: Path | None = None,
    ) -> None:
        role_dir = self.root / role
        role_dir.mkdir(parents=True, exist_ok=True)
        if existing_report_path is None:
            report_path = role_dir / "report.json"
            write_json(report_path, report)
        else:
            report_path = existing_report_path
            if json.loads(report_path.read_text()) != report:
                raise AssertionError("existing evidence report differs")
        bindings = [
            {
                "jsonPointer": pointer,
                **descriptor(path, self.root),
            }
            for pointer, path in extra_bindings
        ]
        if release_path is not None:
            bindings = [
                {"jsonPointer": "/contractSHA256", **descriptor(contract_path, self.root)},
                {
                    "jsonPointer": "/candidate/runtimeManifestFileSHA256",
                    **descriptor(runtime_path, self.root),
                },
                {"jsonPointer": "/candidate/releaseConfigurationSHA256", **descriptor(release_path, self.root)},
            ] + bindings
        sealed_paths = sorted(
            path
            for path in role_dir.rglob("*")
            if path.is_file() and path.name != "sealed-manifest.json"
        )
        sealed_artifacts = [descriptor(path, role_dir) for path in sealed_paths]
        sealed = {
            "schemaVersion": (
                qualification.RECOVERY_SUITE_MANIFEST_SCHEMA
                if role == "recovery"
                else (
                    support_fixture_module.support.EVIDENCE_SCHEMA
                    if role == "support_matrix"
                    else "mirmir-test-sealed-evidence-v1"
                )
            ),
            "artifacts": sealed_artifacts,
        }
        if role == "recovery":
            sealed["artifactSetSHA256"] = qualification.recovery_artifact_set_sha(
                sealed_artifacts
            )
        sealed_path = role_dir / "sealed-manifest.json"
        write_json(sealed_path, sealed)
        self.entries.append(
            {
                "role": role,
                **descriptor(report_path, self.root),
                "contractSHA256": qualification.sha256(contract_path),
                "sealedManifest": descriptor(sealed_path, self.root),
                "identityBindings": bindings,
            }
        )

    def _build_quality(self) -> None:
        role = "quality"
        role_dir = self.root / role
        quality_gate = quality_replay
        quality_contract = copy.deepcopy(
            json.loads(
                (SCRIPT_DIRECTORY / "quality-gate-contract-v1.json").read_text()
            )
        )
        # Keep the release contract's 10,000 bootstrap replicates while making
        # the unit-test corpus small enough for repeated fail-closed cases.
        quality_contract["cohortConstraints"]["minimumClipsPerCohort"] = 1
        quality_contract["cohortConstraints"]["minimumFramesPerClip"] = 2
        quality_contract["corpusConstruction"][
            "syntheticDiagnosticClipCountPerCohort"
        ] = 1
        quality_contract["corpusConstruction"][
            "syntheticDiagnosticFramesPerClip"
        ] = 2
        contract_path, runtime_path, _ = self._write_bound_files(role_dir, role, quality_contract)

        copied_sources = (
            "quality_gate_v4.py",
            "p05_baseline_v4.py",
            "P05QualityBaselineCaptureTests.swift",
            "p05-baseline-source-manifest-v1.json",
        )
        for filename in copied_sources:
            shutil.copy2(SCRIPT_DIRECTORY / filename, role_dir / filename)
        metric_path = role_dir / "quality_gate_v4.py"
        observer_source_path = role_dir / "MirmirApp.swift"
        observer_source_path.write_bytes(
            (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
            .read_bytes()
        )

        corpus_stage = role_dir / "corpus-stage"
        with contextlib.redirect_stdout(io.StringIO()):
            quality_gate.generate_corpus(contract_path, corpus_stage)
        shutil.move(str(corpus_stage / "artifacts"), str(role_dir / "artifacts"))
        shutil.move(
            str(corpus_stage / "corpus-manifest.json"),
            str(role_dir / "corpus-manifest.json"),
        )
        corpus_stage.rmdir()
        corpus_path = role_dir / "corpus-manifest.json"
        corpus_manifest = json.loads(corpus_path.read_text())
        # This is a release-eligible fixture for verifier tests, not claimed
        # project evidence.  Its raw planes still pass the production replay.
        corpus_manifest["corpusKind"] = "locked_natural"
        corpus_manifest["releaseEligible"] = True
        write_json(corpus_path, corpus_manifest)

        capture_cases = []
        for case_index, case in enumerate(corpus_manifest["cases"]):
            reference_path = role_dir / case["referenceFile"]
            reference_bytes = reference_path.read_bytes()
            shift = 1 + case_index % 3
            baseline_bytes = reference_bytes[-shift:] + reference_bytes[:-shift]
            outputs: dict[str, str] = {}
            milliseconds: dict[str, float] = {}
            for variant_index, variant in enumerate(quality_gate.VARIANTS):
                relative = f"artifacts/{case['id']}-{variant}.nv12"
                output_path = role_dir / relative
                output_path.write_bytes(
                    reference_bytes if variant == "candidate_v4" else baseline_bytes
                )
                outputs[variant] = relative
                milliseconds[variant] = float(variant_index + 1)
            capture_cases.append(
                {
                    "id": case["id"],
                    "outputs": outputs,
                    "milliseconds": milliseconds,
                }
            )

        contract_sha = quality_gate.sha256(contract_path)
        corpus_sha = quality_gate.sha256(corpus_path)
        baseline_identity = quality_gate.p05.frozen_identity(quality_contract)
        package_fixture = self._build_packaged_quality_fixture(
            role_dir,
            contract_path,
            corpus_path,
            capture_cases,
            observer_source_path,
        )
        capture_manifest = {
            "schemaVersion": quality_gate.SCHEMA_CAPTURE,
            "contractSHA256": contract_sha,
            "corpusManifestSHA256": corpus_sha,
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            "candidateBackendID": self.contract["quality"]["requiredBackendID"],
            "candidateImplementationVersion": self.contract["quality"][
                "requiredCandidateImplementationVersion"
            ],
            "productionRuntimeLocked": True,
            "fullMirrorIdentityPass": True,
            "warmupCount": 1,
            "baselineIdentity": baseline_identity,
            "baselineImplementationVersion": baseline_identity[
                "implementationVersion"
            ],
            "baselineWarmupCount": 1,
            "evidenceRequestSHA256": package_fixture["requestSHA256"],
            "observerSourceSHA256": package_fixture["observerSourceSHA256"],
            "packagedCandidateIdentity": package_fixture["packageIdentity"],
            "cases": capture_cases,
        }
        capture_path = role_dir / "capture-manifest.json"
        write_json(capture_path, capture_manifest)
        report_path = role_dir / "report.json"
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(
            quality_gate,
            "validate_packaged_quality_capture",
            return_value={
                "packageIdentity": package_fixture["packageIdentity"],
                "requestSHA256": package_fixture["requestSHA256"],
                "observerSourceSHA256": package_fixture["observerSourceSHA256"],
                "captureTree": package_fixture["captureTree"],
            },
        ):
            quality_gate.evaluate(
                contract_path,
                corpus_path,
                capture_path,
                report_path,
                package_fixture["root"],
                self.root,
                runtime_path,
            )
        report = json.loads(report_path.read_text())
        self._write_quality_evidence_manifest()
        bindings = [
            ("/identities/contractSHA256", contract_path),
            ("/identities/metricToolSHA256", metric_path),
            ("/identities/corpusManifestSHA256", corpus_path),
            ("/identities/evidenceRequestSHA256", package_fixture["request"]),
            ("/identities/observerSourceSHA256", package_fixture["observerSource"]),
            (
                "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
                package_fixture["applicationArchive"],
            ),
            (
                "/identities/packagedCandidateIdentity/attestationSHA256",
                package_fixture["attestation"],
            ),
            (
                "/identities/packagedCandidateIdentity/releaseConfigurationSHA256",
                package_fixture["releaseConfiguration"],
            ),
        ]
        self._seal_and_add(
            role,
            report,
            contract_path,
            runtime_path,
            None,
            bindings,
            existing_report_path=report_path,
        )

    def _build_packaged_quality_fixture(
        self,
        role_dir: Path,
        contract_path: Path,
        corpus_path: Path,
        capture_cases: list[dict[str, object]],
        observer_source_path: Path,
    ) -> dict[str, object]:
        """Build a package-shaped unit fixture; production CLI has no such adapter."""

        package_root = role_dir / "packaged-candidate"
        observer_root = package_root / "observer"
        capture_root = package_root / "capture"
        bindings_root = package_root / "bindings"
        for directory in (observer_root, capture_root / "artifacts", bindings_root):
            directory.mkdir(parents=True, exist_ok=True)

        def write_canonical(path: Path, value: object) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(qualification.canonical_bytes(value))

        candidate_path = bindings_root / "candidate.json"
        write_canonical(candidate_path, self.candidate)
        observer_path = bindings_root / "observer-source.swift"
        observer_path.write_bytes(observer_source_path.read_bytes())
        lane_contract_path = bindings_root / "lane-contract.json"
        lane_contract_path.write_bytes(contract_path.read_bytes())
        release_configuration = bindings_root / "release-candidate-v4.xcconfig"
        release_configuration.write_bytes(self.release_bytes)
        application_archive = bindings_root / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        attestation = bindings_root / "application-archive-attestation-v1.json"
        write_canonical(
            attestation,
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            },
        )
        package = {
            "schemaVersion": "mirmir-v4-packaged-candidate-identity-v1",
            "buildConfiguration": "Release",
            "applicationArchiveSHA256": qualification.sha256(application_archive),
            "applicationPayloadIdentitySHA256": identity("quality-package-payload"),
            "applicationInfoPlistSHA256": identity("quality-package-info"),
            "applicationExecutableSHA256": qualification.sha256_bytes(
                b"shipping-app-executable"
            ),
            "codeDirectories": [
                {"architecture": "arm64", "sha256": identity("quality-cd-arm64")},
                {"architecture": "x86_64", "sha256": identity("quality-cd-x86_64")},
            ],
            "codeDirectorySetSHA256": identity("quality-cd-set"),
            "designatedRequirementSHA256": identity("quality-requirement"),
            "releaseConfigurationSHA256": qualification.sha256(
                release_configuration
            ),
            "attestationSHA256": qualification.sha256(attestation),
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
        package_path = bindings_root / "package-identity.json"
        write_canonical(package_path, package)
        exact_cases = []
        for case in capture_cases:
            outputs = {
                variant: case["outputs"][variant]
                for variant in quality_replay.CANDIDATE_VARIANTS
            }
            milliseconds = {
                variant: case["milliseconds"][variant]
                for variant in quality_replay.CANDIDATE_VARIANTS
            }
            for relative in outputs.values():
                destination = capture_root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(role_dir / relative, destination)
            exact_cases.append(
                {"id": case["id"], "outputs": outputs, "milliseconds": milliseconds}
            )
        observer_sha = qualification.sha256(observer_path)
        request = {
            "schemaVersion": "mirmir-v4-packaged-evidence-request-v1",
            "lane": "quality",
            "requestID": "11111111-1111-4111-8111-111111111111",
            "nonce": identity("quality-request-nonce"),
            "generatedAtUTC": "2026-08-02T12:00:00Z",
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureEnvironment": {
                "MIRMIR_V4_QUALITY_CAPTURE_DIR": "/fixture/capture",
                "MIRMIR_V4_QUALITY_CORPUS_MANIFEST": "/fixture/inputs/corpus-manifest.json",
                "MIRMIR_V4_QUALITY_CONTRACT_SHA256": qualification.sha256(
                    contract_path
                ),
                "MIRMIR_V4_QUALITY_SOURCE_COMMIT": self.candidate[
                    "sourceCommit"
                ],
                "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256": self.candidate[
                    "sourceTreeIdentitySHA256"
                ],
            },
        }
        request_path = observer_root / "request.json"
        write_canonical(request_path, request)
        request_sha = qualification.sha256(request_path)
        exact_manifest = {
            "schemaVersion": "mirmir-ash-v4-quality-candidate-capture-v1",
            "contractSHA256": qualification.sha256(contract_path),
            "corpusManifestSHA256": qualification.sha256(corpus_path),
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate[
                "sourceTreeIdentitySHA256"
            ],
            "candidateBackendID": self.contract["quality"]["requiredBackendID"],
            "candidateImplementationVersion": self.contract["quality"][
                "requiredCandidateImplementationVersion"
            ],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "productionRuntimeLocked": True,
            "fullMirrorIdentityPass": True,
            "warmupCount": 1,
            "evidenceRequestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "packagedCandidateIdentity": package,
            "cases": exact_cases,
        }
        exact_manifest_path = capture_root / "candidate-capture-manifest.json"
        write_json(exact_manifest_path, exact_manifest)
        capture_tree = qualification.packaged_capture_tree(capture_root)
        result = {
            "schemaVersion": "mirmir-v4-packaged-evidence-result-v1",
            "lane": "quality",
            "requestID": request["requestID"],
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "process": {
                "bundlePath": "/fixture/Mirmir.app",
                "executablePath": "/fixture/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": package["applicationExecutableSHA256"],
                "processID": 101,
                "parentProcessID": 100,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": exact_manifest_path.name,
                "byteCount": exact_manifest_path.stat().st_size,
                "sha256": qualification.sha256(exact_manifest_path),
            },
            "captureTree": capture_tree,
            "checks": {
                "exactExecutableIdentity": True,
                "signedBuildClaims": True,
                "productionP06Load": True,
                "normativePixelCapture": True,
            },
        }
        result_path = observer_root / "result.json"
        write_canonical(result_path, result)
        stdout_path = observer_root / "stdout.bin"
        stderr_path = observer_root / "stderr.bin"
        stdout_path.write_bytes(b"fixture packaged observer result\n")
        stderr_path.write_bytes(b"")
        record = {
            "schemaVersion": "mirmir-v4-packaged-evidence-capture-record-v1",
            "lane": "quality",
            "startedAtUTC": "2026-08-02T12:00:00Z",
            "finishedAtUTC": "2026-08-02T12:00:01Z",
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureTree": capture_tree,
            "process": {
                "executableSHA256": package["applicationExecutableSHA256"],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": descriptor(request_path, package_root),
                "result": descriptor(result_path, package_root),
                "stdout": descriptor(stdout_path, package_root),
                "stderr": descriptor(stderr_path, package_root),
                "candidate": descriptor(candidate_path, package_root),
                "packageIdentity": descriptor(package_path, package_root),
                "attestation": descriptor(attestation, package_root),
                "observerSource": descriptor(observer_path, package_root),
                "contract": descriptor(lane_contract_path, package_root),
                "releaseConfiguration": descriptor(
                    release_configuration, package_root
                ),
                "applicationArchive": descriptor(application_archive, package_root),
            },
        }
        write_canonical(package_root / "capture-record.json", record)
        self.packaged_candidate_identity = copy.deepcopy(package)
        return {
            "root": package_root,
            "packageIdentity": package,
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "captureTree": capture_tree,
            "request": request_path,
            "observerSource": observer_path,
            "applicationArchive": application_archive,
            "attestation": attestation,
            "releaseConfiguration": release_configuration,
        }

    def _write_quality_evidence_manifest(self) -> None:
        role_dir = self.root / "quality"
        manifest_path = role_dir / "artifact-manifest.json"
        artifacts = [
            descriptor(path, role_dir)
            for path in sorted(
                role_dir.rglob("*"),
                key=lambda value: value.relative_to(role_dir).as_posix(),
            )
            if path.is_file()
            and path != manifest_path
            and path != role_dir / "sealed-manifest.json"
        ]
        write_json(
            manifest_path,
            {
                "schemaVersion": "mirmir-ash-v4-quality-evidence-manifest-v1",
                "artifacts": artifacts,
            },
        )

    def _base(self, role: str, contract_sha: str) -> dict[str, object]:
        return {
            "schemaVersion": self.contract["evidenceSchemas"][role],
            "contractSHA256": contract_sha,
            "candidate": self.candidate,
            "releaseEligible": True,
        }

    def _build_performance_package_fixture(
        self,
        role_dir: Path,
        contract_path: Path,
        candidate_directory: Path,
    ) -> dict[str, object]:
        package_root = role_dir / "packaged-candidate"
        capture_root = package_root / "capture"
        observer_root = package_root / "observer"
        bindings_root = package_root / "bindings"
        for directory in (capture_root, observer_root, bindings_root):
            directory.mkdir(parents=True, exist_ok=True)

        def write_canonical(path: Path, value: object) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(qualification.canonical_bytes(value))

        package = copy.deepcopy(self.packaged_candidate_identity)
        observer_source = bindings_root / "observer-source.swift"
        observer_source.write_bytes(
            (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
            .read_bytes()
        )
        observer_sha = qualification.sha256(observer_source)
        source_path = candidate_directory / "source-identity.json"
        request = {
            "schemaVersion": "mirmir-v4-packaged-evidence-request-v1",
            "lane": "performance",
            "requestID": "33333333-3333-4333-8333-333333333333",
            "nonce": identity("performance-request-nonce"),
            "generatedAtUTC": "2026-08-02T12:00:00Z",
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureEnvironment": {
                "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR": "/fixture/capture",
                "MIRMIR_V4_PERFORMANCE_INPUT": "/fixture/inputs/performance.mov",
                "MIRMIR_V4_PERFORMANCE_VARIANT": "candidate_p06",
                "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256": qualification.sha256(
                    contract_path
                ),
                "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256": identity(
                    "performance capture source"
                ),
                "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256": qualification.sha256(
                    source_path
                ),
                "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION": self.candidate[
                    "sourceCommit"
                ],
                "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256": self.candidate[
                    "sourceTreeIdentitySHA256"
                ],
                "MIRMIR_V4_PERFORMANCE_WARMUPS": "5",
                "MIRMIR_V4_PERFORMANCE_SAMPLES": "10",
            },
        }
        request_path = observer_root / "request.json"
        write_canonical(request_path, request)
        request_sha = qualification.sha256(request_path)
        capture_path = candidate_directory / "capture.json"
        capture = json.loads(capture_path.read_text())
        capture.update(
            {
                "evidenceRequestSHA256": request_sha,
                "observerSourceSHA256": observer_sha,
                "packagedCandidateIdentity": package,
            }
        )
        write_json(capture_path, capture)
        candidate_manifest = performance_gate.make_evidence_manifest(
            candidate_directory
        )
        candidate_manifest["schemaVersion"] = (
            "mirmir-v4-performance-capture-artifacts-v1"
        )
        write_json(candidate_directory / "artifact-manifest.json", candidate_manifest)
        shutil.copyfile(capture_path, capture_root / "capture.json")

        candidate_path = bindings_root / "candidate.json"
        package_path = bindings_root / "package-identity.json"
        write_canonical(candidate_path, self.candidate)
        write_canonical(package_path, package)
        attestation = bindings_root / "application-archive-attestation-v1.json"
        write_canonical(
            attestation,
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            },
        )
        lane_contract = bindings_root / "lane-contract.json"
        lane_contract.write_bytes(contract_path.read_bytes())
        release_configuration = bindings_root / "release-candidate-v4.xcconfig"
        release_configuration.write_bytes(self.release_bytes)
        application_archive = bindings_root / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        package_identity_path = bindings_root / "package-identity.json"
        capture_tree = qualification.packaged_capture_tree(capture_root)
        result = {
            "schemaVersion": "mirmir-v4-packaged-evidence-result-v1",
            "lane": "performance",
            "requestID": request["requestID"],
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "process": {
                "bundlePath": "/fixture/Mirmir.app",
                "executablePath": "/fixture/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": package["applicationExecutableSHA256"],
                "processID": 301,
                "parentProcessID": 300,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": "capture.json",
                "byteCount": (capture_root / "capture.json").stat().st_size,
                "sha256": qualification.sha256(capture_root / "capture.json"),
            },
            "captureTree": capture_tree,
            "checks": {
                "exactExecutableIdentity": True,
                "signedBuildClaims": True,
                "productionP06Load": True,
                "normativePixelCapture": True,
            },
        }
        result_path = observer_root / "result.json"
        write_canonical(result_path, result)
        stdout_path = observer_root / "stdout.bin"
        stderr_path = observer_root / "stderr.bin"
        stdout_path.write_bytes(b"fixture packaged performance observer result\n")
        stderr_path.write_bytes(b"")
        record = {
            "schemaVersion": "mirmir-v4-packaged-evidence-capture-record-v1",
            "lane": "performance",
            "startedAtUTC": "2026-08-02T12:00:00Z",
            "finishedAtUTC": "2026-08-02T12:00:01Z",
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "contractSHA256": qualification.sha256(contract_path),
            "packageIdentity": package,
            "captureTree": capture_tree,
            "process": {
                "executableSHA256": package["applicationExecutableSHA256"],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": descriptor(request_path, package_root),
                "result": descriptor(result_path, package_root),
                "stdout": descriptor(stdout_path, package_root),
                "stderr": descriptor(stderr_path, package_root),
                "candidate": descriptor(candidate_path, package_root),
                "packageIdentity": descriptor(package_identity_path, package_root),
                "attestation": descriptor(attestation, package_root),
                "observerSource": descriptor(observer_source, package_root),
                "contract": descriptor(lane_contract, package_root),
                "releaseConfiguration": descriptor(
                    release_configuration, package_root
                ),
                "applicationArchive": descriptor(application_archive, package_root),
            },
        }
        write_canonical(package_root / "capture-record.json", record)
        return {
            "root": package_root,
            "packageIdentity": package,
            "requestSHA256": request_sha,
            "observerSourceSHA256": observer_sha,
            "captureTree": capture_tree,
            "request": request_path,
            "observerSource": observer_source,
            "applicationArchive": application_archive,
            "attestation": attestation,
        }

    def _build_performance_actual(self) -> None:
        role = "same_scope_performance"
        role_dir = self.root / role
        role_dir.mkdir(parents=True, exist_ok=True)
        suite_contract = json.loads(
            (SCRIPT_DIRECTORY / "performance-gate-contract-v1.json").read_text()
        )
        suite_contract["capture"]["captureSourceSHA256"] = identity("performance capture source")
        suite_contract["capture"]["evaluatorSourceSHA256"] = identity("performance evaluator")
        suite_contract["capture"]["runnerSourceSHA256"] = identity("performance runner")
        contract_path = role_dir / "performance-gate-contract-v1.json"
        write_json(contract_path, suite_contract)
        contract_sha = qualification.sha256(contract_path)

        def environment() -> dict[str, object]:
            return {
                "schemaVersion": "mirmir-v4-performance-environment-v1",
                "stableIdentity": {
                    "hardwareModel": "Mac-Qualification",
                    "memoryBytes": 48 * 1024**3,
                    "processor": "Apple Qualification",
                    "gpuIdentity": ["Apple Qualification"],
                    "macOSBuild": "locked",
                    "xcodeBuild": "locked",
                    "swiftCompiler": "locked",
                },
                "power": {"identity": "locked-ac-power", "source": "AC Power"},
                "thermal": {"accepted": True, "observationSHA256": identity("thermal")},
            }

        def make_capture(variant: str, wall: float, engine: float) -> Path:
            directory = role_dir / ("baseline" if variant == "baseline_p05" else "candidate")
            directory.mkdir(parents=True)
            if variant == "baseline_p05":
                revision = suite_contract["baseline"]["sourceRevision"]
                source_tree = identity("baseline tree")
                runtime = {
                    "status": suite_contract["baseline"]["runtimeStatus"],
                    "runtimeID": None,
                    "implementationVersions": suite_contract["baseline"]["implementationVersions"],
                    "manifestSHA256": None,
                    "releaseQualified": False,
                    "trustRootConfigured": False,
                    "artifactsVerified": True,
                }
            else:
                revision = self.candidate["sourceCommit"]
                source_tree = self.candidate["sourceTreeIdentitySHA256"]
                runtime = {
                    "status": "release_qualified",
                    "runtimeID": "ash-p06-deterministic-v4",
                    "implementationVersions": ["ash-p06-deterministic-v4"],
                    "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                    "manifestSourceRevision": self.candidate["runtimeSourceRevision"],
                    "builderSourceSHA256": qualification.sha256_bytes(self.builder_bytes),
                    "releaseQualified": True,
                    "trustRootConfigured": True,
                    "artifactsVerified": True,
                }
            source = {
                "schemaVersion": "mirmir-v4-performance-source-identity-v1",
                "variant": variant,
                "sourceRevision": revision,
                "sourceTreeSHA256": source_tree,
                "runtime": runtime,
            }
            source_path = directory / "source-identity.json"
            write_json(source_path, source)
            write_json(directory / "environment-before.json", environment())
            write_json(directory / "environment-after.json", environment())
            producer_log = (
                "xcodebuild.log"
                if variant == "baseline_p05"
                else "packaged-observer.log"
            )
            (directory / producer_log).write_text(
                "Release qualification test process completed successfully\n",
                encoding="utf-8",
            )
            cases = []
            for case_index, case_contract in enumerate(suite_contract["workload"]["cases"]):
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
                        **case_contract,
                        "request": copy.deepcopy(suite_contract["workload"]["output"]),
                        "engineRuns": engine_runs,
                        "endToEndRuns": wall_runs,
                    }
                )
            capture = {
                "schemaVersion": "mirmir-v4-performance-capture-v1",
                "variant": variant,
                "contractSHA256": contract_sha,
                "captureSourceSHA256": suite_contract["capture"]["captureSourceSHA256"],
                "sourceIdentitySHA256": qualification.sha256(source_path),
                "sourceRevision": revision,
                "sourceTreeSHA256": source_tree,
                "buildConfiguration": "Release",
                "warmupCount": 5,
                "sampleCount": 10,
                "input": {
                    key: value
                    for key, value in suite_contract["workload"]["input"].items()
                    if key != "repositoryPath"
                }
                | {"allRequiredChecksPassed": True},
                "cases": cases,
            }
            write_json(directory / "capture.json", capture)
            nested = performance_gate.make_evidence_manifest(directory)
            nested["schemaVersion"] = "mirmir-v4-performance-capture-artifacts-v1"
            write_json(directory / "artifact-manifest.json", nested)
            return directory

        baseline = make_capture("baseline_p05", wall=100.0, engine=10.0)
        observed = make_capture("candidate_p06", wall=50.0, engine=5.0)
        package_fixture = self._build_performance_package_fixture(
            role_dir, contract_path, observed
        )
        with mock.patch.object(
            performance_gate,
            "validate_packaged_performance_capture",
            return_value={
                "packageIdentity": package_fixture["packageIdentity"],
                "requestSHA256": package_fixture["requestSHA256"],
                "observerSourceSHA256": package_fixture["observerSourceSHA256"],
                "captureTree": package_fixture["captureTree"],
            },
        ):
            report = performance_gate.evaluate(
                contract_path,
                baseline,
                observed,
                package_fixture["root"],
                self.root,
                role_dir / "runtime-manifest.json",
                allow_fixture_runtime=False,
            )
        report_path = role_dir / "performance-gate-report.json"
        write_json(report_path, report)
        root_manifest_path = role_dir / "artifact-manifest.json"
        root_artifacts = [
            descriptor(path, role_dir)
            for path in sorted(
                role_dir.rglob("*"),
                key=lambda value: value.relative_to(role_dir).as_posix(),
            )
            if path.is_file() and path != root_manifest_path
        ]
        write_json(
            root_manifest_path,
            {
                "schemaVersion": "mirmir-v4-performance-evidence-manifest-v1",
                "artifacts": root_artifacts,
            },
        )
        binding_sources = [
            ("/contractSHA256", contract_path),
            ("/baseline/sourceIdentitySHA256", baseline / "source-identity.json"),
            ("/baseline/artifactManifestSHA256", baseline / "artifact-manifest.json"),
            ("/candidate/sourceIdentitySHA256", observed / "source-identity.json"),
            ("/candidate/artifactManifestSHA256", observed / "artifact-manifest.json"),
            ("/candidate/evidenceRequestSHA256", package_fixture["request"]),
            ("/candidate/observerSourceSHA256", package_fixture["observerSource"]),
            (
                "/candidate/packagedCandidateIdentity/applicationArchiveSHA256",
                package_fixture["applicationArchive"],
            ),
            (
                "/candidate/packagedCandidateIdentity/attestationSHA256",
                package_fixture["attestation"],
            ),
        ]
        self.entries.append(
            {
                "role": role,
                **descriptor(report_path, self.root),
                "contractSHA256": contract_sha,
                "sealedManifest": descriptor(root_manifest_path, self.root),
                "identityBindings": [
                    {"jsonPointer": pointer, **descriptor(path, self.root)}
                    for pointer, path in binding_sources
                ],
            }
        )

    def _build_support_actual(self) -> None:
        role = "support_matrix"
        role_dir = self.root / role
        support_fixture_module.SupportEvidenceFixture(
            role_dir,
            runtime_manifest=json.loads(self.runtime_bytes),
            candidate=self.candidate,
            release_bytes=self.release_bytes,
            archive_bytes=self.app_bytes,
        )
        report = json.loads((role_dir / "report.json").read_text())
        self._seal_and_add(
            role,
            report,
            role_dir / "suite-contract.json",
            role_dir / "runtime-manifest.json",
            role_dir / "Release.xcconfig",
            [
                ("/candidate/appBundleSHA256", role_dir / "application-archive.zip"),
                ("/identities/captureSourceSHA256", role_dir / "capture-tool.py"),
                (
                    "/identities/evaluatorSHA256",
                    role_dir / "support-matrix-evaluator.py",
                ),
                (
                    "/identities/runnerSHA256",
                    role_dir / "support-matrix-runner.sh",
                ),
            ],
        )

    def _build_media_preservation(
        self,
        role_dir: Path,
        report: dict[str, object],
        contract_sha: str,
        extra_bindings: list[tuple[str, Path]],
    ) -> None:
        capture_source = role_dir / "bindings" / "MediaPreservationCaptureTests.swift"
        fixture_source = role_dir / "bindings" / "AVFoundationTrackMigrationExecutorV4Tests.swift"
        evaluator_source = role_dir / "bindings" / "media_preservation_v4.py"
        runner_source = role_dir / "bindings" / "run_media_preservation_v4.sh"
        packaged_source = (
            role_dir / "bindings" / "packaged_candidate_evidence_v4.py"
        )
        archive_tool_source = (
            role_dir / "bindings" / "release_candidate_archive_v4.py"
        )
        observer_source = role_dir / "bindings" / "MirmirApp.swift"
        capture_source.parent.mkdir(parents=True, exist_ok=True)
        capture_source.write_bytes(b"// locked media preservation capture\n")
        fixture_source.write_bytes(b"// locked AVFoundation fixture factory\n")
        evaluator_source.write_bytes(b"# locked media preservation evaluator\n")
        runner_source.write_bytes(b"#!/bin/sh\n# locked media preservation runner\n")
        packaged_source.write_bytes(b"# locked packaged candidate evidence tool\n")
        archive_tool_source.write_bytes(b"# locked release archive dependency\n")
        observer_source.write_bytes(b"// locked shipping media observer\n")
        application_archive = role_dir / "bindings" / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        attestation = {
            "schemaVersion": "mirmir-v4-release-build-attestation-v1",
            "buildConfiguration": "Release",
            "hashAlgorithm": "sha256",
            "application": {
                "bundleIdentifier": self.candidate["bundleIdentifier"],
                "productVersion": self.candidate["productVersion"],
                "productBuild": self.candidate["productBuild"],
                "infoPlistSHA256": identity("media-package-info-plist"),
                "executableSHA256": identity("media-package-executable"),
                "codeDirectories": [
                    {"architecture": "arm64", "sha256": identity("media-package-arm64")},
                    {"architecture": "x86_64", "sha256": identity("media-package-x86_64")},
                ],
                "codeDirectorySetSHA256": identity("media-package-code-directory-set"),
                "designatedRequirementSHA256": identity("media-package-designated-requirement"),
            },
            "archivePayload": {
                "identitySHA256": identity("media-package-payload")
            },
            "source": {
                "commit": self.candidate["sourceCommit"],
                "treeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            },
            "runtime": {
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "manifestFileSHA256": self.candidate["runtimeManifestFileSHA256"],
                "artifactSetSHA256": self.candidate["runtimeArtifactSetSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
            },
            "releaseConfiguration": {
                "sha256": self.candidate["releaseConfigurationSHA256"]
            },
        }
        attestation_path = role_dir / "bindings" / "MirmirV4BuildAttestation.json"
        attestation_path.write_bytes(qualification.canonical_bytes(attestation))
        packaged_candidate = {
            "schemaVersion": "mirmir-v4-packaged-candidate-identity-v1",
            "buildConfiguration": "Release",
            "applicationArchiveSHA256": self.candidate["appBundleSHA256"],
            "applicationPayloadIdentitySHA256": attestation["archivePayload"]["identitySHA256"],
            "applicationInfoPlistSHA256": attestation["application"]["infoPlistSHA256"],
            "applicationExecutableSHA256": attestation["application"]["executableSHA256"],
            "codeDirectories": attestation["application"]["codeDirectories"],
            "codeDirectorySetSHA256": attestation["application"]["codeDirectorySetSHA256"],
            "designatedRequirementSHA256": attestation["application"]["designatedRequirementSHA256"],
            "releaseConfigurationSHA256": self.candidate["releaseConfigurationSHA256"],
            "attestationSHA256": qualification.sha256(attestation_path),
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "runtimeManifestFileSHA256": self.candidate["runtimeManifestFileSHA256"],
            "runtimeArtifactSetSHA256": self.candidate["runtimeArtifactSetSHA256"],
            "runtimeSourceRevision": self.candidate["runtimeSourceRevision"],
            "bundleIdentifier": self.candidate["bundleIdentifier"],
            "productVersion": self.candidate["productVersion"],
            "productBuild": self.candidate["productBuild"],
        }
        tool_identities = {
            "captureSourceSHA256": qualification.sha256(capture_source),
            "fixtureSourceSHA256": qualification.sha256(fixture_source),
            "evaluatorSHA256": qualification.sha256(evaluator_source),
            "runnerSHA256": qualification.sha256(runner_source),
            "packagedEvidenceToolSHA256": qualification.sha256(packaged_source),
            "releaseCandidateArchiveToolSHA256": qualification.sha256(
                archive_tool_source
            ),
            "observerSourceSHA256": qualification.sha256(observer_source),
        }
        fixture_specs = [
            {
                "id": "combined-p010-hdr-interlaced",
                "policy": "p010_field_normalization",
                "coverage": [
                    "p010_hdr_static_dynamic", "interlaced_field_order_cadence",
                    "non_square_pixel_aspect_ratio", "clean_aperture", "preferred_transform",
                    "combined_p010_hdr_interlaced",
                ],
            },
            {
                "id": "combined-alpha-geometry-straight",
                "policy": "alpha_geometry",
                "coverage": [
                    "non_square_pixel_aspect_ratio", "clean_aperture", "preferred_transform",
                    "straight_alpha", "combined_alpha_geometry",
                ],
            },
            {
                "id": "combined-alpha-geometry-premultiplied",
                "policy": "alpha_geometry",
                "coverage": [
                    "non_square_pixel_aspect_ratio", "clean_aperture", "preferred_transform",
                    "premultiplied_alpha", "combined_alpha_geometry",
                ],
            },
            {
                "id": "rich-track-graph",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": [
                    "multiple_enabled_video_tracks", "alternate_audio_tracks", "chapters",
                    "timecode_tracks", "timed_metadata",
                ],
            },
            {
                "id": "legible-track-graph",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": ["subtitles", "captions"],
            },
            {
                "id": "auxiliary-picture-track",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": ["auxiliary_tracks"],
            },
        ]
        lane_contract = {
            "schemaVersion": qualification.MEDIA_LANE_CONTRACT_SCHEMA,
            "suiteID": "mirmir-ash-v4-media-preservation-v1",
            "capture": {"buildConfiguration": "Release", **tool_identities},
            "fixtures": fixture_specs,
        }
        lane_contract_path = role_dir / "bindings" / "media-preservation-contract-v1.json"
        write_json(lane_contract_path, lane_contract)
        lane_contract_sha = qualification.sha256(lane_contract_path)

        def track_row(fixture_id: str, ordinal: int, kind: str) -> dict[str, object]:
            return {
                "ordinal": ordinal,
                "stableID": f"ash.media.track.{kind}.{ordinal:08d}.{fixture_id}",
                "kind": kind,
                "enabled": True,
                "mediaTypeID": f"test.{kind}",
                "codecID": f"test.codec.{kind}",
                "languageCode": "en" if kind in {"audio", "subtitle", "caption"} else None,
                "extendedLanguageTag": None,
                "roleIDs": [],
                "timebase": "1/30",
                "timeRangeSHA256": identity(f"{fixture_id}-{ordinal}-range"),
                "editsSHA256": identity(f"{fixture_id}-{ordinal}-edits"),
                "formatSHA256": identity(f"{fixture_id}-{ordinal}-format"),
                "metadataSHA256": identity(f"{fixture_id}-{ordinal}-metadata"),
            }

        def sample(fixture_id: str, ordinal: int, sample_index: int, pts: str, duration: str) -> dict[str, object]:
            return {
                "pts": pts,
                "dts": "invalid",
                "duration": duration,
                "byteCount": 1,
                "payloadSHA256": identity(f"{fixture_id}-{ordinal}-payload-{sample_index}"),
            }

        def timing_track(ordinal: int, samples: list[dict[str, object]]) -> dict[str, object]:
            timings = [{key: item[key] for key in ("pts", "dts", "duration")} for item in samples]
            payloads = [item["payloadSHA256"] for item in samples]
            return {
                "ordinal": ordinal,
                "sampleCount": len(samples),
                "timingSHA256": qualification.sha256_bytes(qualification.canonical_bytes(timings)),
                "encodedPayloadSHA256": qualification.sha256_bytes(qualification.canonical_bytes(payloads)),
                "samples": samples,
            }

        def attachment_row(
            ordinal: int,
            *,
            field_count: int = 1,
            detail: str = "progressive",
            cadence: str = "progressive",
            aspect: tuple[int, int] = (1, 1),
            aperture: tuple[str, str, str, str] = ("16", "16", "0", "0"),
            transform: list[str] | None = None,
            hdr: bool = False,
            dynamic: list[dict[str, object]] | None = None,
            alpha: str | None = None,
        ) -> dict[str, object]:
            return {
                "ordinal": ordinal,
                "kind": "video",
                "fieldCount": field_count,
                "fieldDetail": detail,
                "cadence": cadence,
                "pixelAspectRatio": {"horizontal": aspect[0], "vertical": aspect[1]},
                "cleanAperture": {
                    "width": aperture[0], "height": aperture[1],
                    "horizontalOffset": aperture[2], "verticalOffset": aperture[3],
                },
                "preferredTransform": transform or ["1", "0", "0", "1", "0", "0"],
                "colorPrimaries": "ITU_R_2020" if hdr else None,
                "transferFunction": "SMPTE_ST_2084_PQ" if hdr else None,
                "yCbCrMatrix": "ITU_R_2020" if hdr else None,
                "masteringDisplaySHA256": identity("mastering-display") if hdr else None,
                "contentLightSHA256": identity("content-light") if hdr else None,
                "ambientViewingEnvironmentSHA256":
                    identity("ambient-viewing-environment") if hdr else None,
                "dynamicHDRSamples": dynamic or [],
                "alphaAssociation": alpha,
            }

        raw_root = role_dir / "raw-capture"
        capture_root = raw_root / "capture"
        capture_root.mkdir(parents=True, exist_ok=True)
        fixture_manifest_sha256 = identity("media-fixture-package")
        fixture_tree_sha256 = identity("media-fixture-tree")
        nonce = "locked-media-evidence-nonce"
        nonce_sha256 = qualification.sha256_bytes(nonce.encode("utf-8"))
        observer_dir = raw_root / "observer"
        observer_dir.mkdir(parents=True, exist_ok=True)
        request = {
            "schemaVersion": "mirmir-v4-packaged-evidence-request-v1",
            "lane": "media",
            "requestID": "locked-media-request",
            "nonce": nonce,
            "generatedAtUTC": "2026-08-14T00:00:00Z",
            "observerSourceSHA256": tool_identities["observerSourceSHA256"],
            "contractSHA256": lane_contract_sha,
            "packageIdentity": packaged_candidate,
            "captureEnvironment": {
                "MIRMIR_V4_MEDIA_CAPTURE_DIR": "capture",
                "MIRMIR_V4_MEDIA_CONTRACT_PATH": "lane-contract.json",
                "MIRMIR_V4_MEDIA_CONTRACT_SHA256": lane_contract_sha,
                "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST": "fixture-package.json",
                "MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256":
                    fixture_manifest_sha256,
                "MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256": fixture_tree_sha256,
                "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256":
                    tool_identities["fixtureSourceSHA256"],
                "MIRMIR_V4_MEDIA_GENERATOR_SOURCE_SHA256":
                    tool_identities["captureSourceSHA256"],
                "MIRMIR_V4_MEDIA_SOURCE_COMMIT":
                    self.candidate["sourceCommit"],
                "MIRMIR_V4_MEDIA_SOURCE_TREE_SHA256":
                    self.candidate["sourceTreeIdentitySHA256"],
            },
        }
        request_path = observer_dir / "request.json"
        write_json(request_path, request)
        request_sha256 = qualification.sha256(request_path)
        report_fixtures: list[dict[str, object]] = []
        capture_fixtures: list[dict[str, object]] = []
        total_enabled = 0
        for spec in fixture_specs:
            fixture_id = spec["id"]
            policy = spec["policy"]
            if fixture_id == "rich-track-graph":
                kinds = ["video", "video", "audio", "audio", "chapter", "timecode", "timed_metadata"]
            elif fixture_id == "legible-track-graph":
                kinds = ["video", "subtitle", "caption"]
            elif fixture_id == "auxiliary-picture-track":
                kinds = ["video", "auxiliary"]
            else:
                kinds = ["video"]
            track_rows = [track_row(fixture_id, ordinal, kind) for ordinal, kind in enumerate(kinds)]
            groups = [{"memberOrdinals": [2, 3]}] if fixture_id == "rich-track-graph" else []
            alpha_oracle_input: dict[str, object] | None = None
            alpha_source_hash: str | None = None
            alpha_output_hash: str | None = None
            if policy == "alpha_geometry":
                association = (
                    "straight"
                    if "straight_alpha" in spec["coverage"]
                    else "premultiplied"
                )
                alpha_source = bytes([37]) * (16 * 16)
                alpha_output = qualification.preservation_independent_alpha_oracle(
                    alpha_source, 16, 16, 24, 24
                )
                alpha_source_hash = qualification.sha256_bytes(alpha_source)
                alpha_output_hash = qualification.sha256_bytes(alpha_output)
                alpha_path = (
                    capture_root / "fixtures" / fixture_id / "input"
                    / "alpha-source.bin"
                )
                alpha_path.parent.mkdir(parents=True, exist_ok=True)
                alpha_path.write_bytes(alpha_source)
                alpha_oracle_input = {
                    "schemaVersion": "mirmir-ash-v4-alpha-oracle-input-v1",
                    "artifact": descriptor(alpha_path, capture_root),
                    "frameSHA256": [alpha_source_hash],
                    "frameCount": 1,
                    "width": 16,
                    "height": 16,
                    "association": association,
                }
            side_results: dict[str, dict[str, object]] = {}
            raw_descriptors: dict[str, dict[str, object]] = {}
            for side in ("input", "output"):
                side_dir = role_dir / "fixtures" / fixture_id / side
                raw_side_dir = capture_root / "fixtures" / fixture_id / side
                side_dir.mkdir(parents=True, exist_ok=True)
                raw_side_dir.mkdir(parents=True, exist_ok=True)
                media_path = side_dir / "media.mov"
                media_path.write_bytes(f"{fixture_id}-{side}-media".encode())
                pixel_path = side_dir / "pixels.bin"
                pixel_path.write_bytes(f"{fixture_id}-{side}-pixels".encode())
                observed_track_rows = copy.deepcopy(track_rows)
                if (
                    policy == "process_primary_preserve_auxiliary"
                    and side == "output"
                ):
                    observed_track_rows[0]["codecID"] = "test.codec.processed-video"
                    observed_track_rows[0]["formatSHA256"] = identity(
                        f"{fixture_id}-processed-primary-format"
                    )
                track_observation = {
                    "schemaVersion": qualification.MEDIA_TRACK_SCHEMA,
                    "fixtureID": fixture_id,
                    "side": side,
                    "enabledTrackCount": len(track_rows),
                    "tracks": observed_track_rows,
                    "groups": groups,
                    "associations": [],
                    "assetMetadataSHA256": identity(f"{fixture_id}-asset-metadata"),
                    "chapterMetadataSHA256": identity(f"{fixture_id}-chapter-metadata"),
                }
                timing_rows = []
                for ordinal, _ in enumerate(kinds):
                    if policy == "p010_field_normalization" and ordinal == 0:
                        timing_samples = (
                            [sample(fixture_id, ordinal, 0, "0", "1/30")]
                            if side == "input"
                            else [
                                sample(fixture_id, ordinal, 0, "0", "1/60"),
                                sample(fixture_id, ordinal, 1, "1/60", "1/60"),
                            ]
                        )
                    else:
                        timing_samples = [sample(fixture_id, ordinal, 0, "0", "1/30")]
                    timing_rows.append(timing_track(ordinal, timing_samples))
                timing_observation = {
                    "schemaVersion": qualification.MEDIA_TIMING_SCHEMA,
                    "fixtureID": fixture_id,
                    "side": side,
                    "tracks": timing_rows,
                }
                pixels: list[dict[str, object]] = []
                attachments: list[dict[str, object]] = []
                if policy == "p010_field_normalization":
                    visible = identity(f"{fixture_id}-{side}-visible")
                    pixels = [{
                        "ordinal": 0, "kind": "video", "pixelFormat": "x420", "bitDepth": 10,
                        "width": 64 if side == "input" else 96,
                        "height": 48 if side == "input" else 72,
                        "frameCount": 1 if side == "input" else 2,
                        "visibleSHA256": visible,
                        "repeatVisibleSHA256": visible if side == "output" else identity(f"{fixture_id}-input-repeat"),
                        "alphaSHA256": None,
                        "alphaFrameSHA256": [],
                        "preEncodeAlphaFrameSHA256": [],
                        "repeatPreEncodeAlphaFrameSHA256": [],
                        "decodedAlphaSHA256": None,
                        "uniqueSignalCodeCount": 512, "lowPaddingBitViolationCount": 0,
                    }]
                    dynamic_hash = identity("hdr10-plus")
                    post_hash = identity("post-decode")
                    dynamic = [{"sampleOrdinal": 0, "pts": "0", "hdr10PlusSHA256": dynamic_hash, "postDecodeSHA256": post_hash}]
                    if side == "output":
                        dynamic = [
                            dynamic[0],
                            {"sampleOrdinal": 1, "pts": "1/60", "hdr10PlusSHA256": dynamic_hash, "postDecodeSHA256": post_hash},
                        ]
                    attachments = [attachment_row(
                        0,
                        field_count=2 if side == "input" else 1,
                        detail="temporal_top_first" if side == "input" else "progressive",
                        cadence="interlaced_tff_2_fields_per_sample" if side == "input" else "progressive_double_rate",
                        aspect=(4, 3),
                        aperture=("60", "44", "0", "0") if side == "input" else ("90", "66", "0", "0"),
                        transform=["0", "1", "-1", "0", "48", "0"] if side == "input" else ["0", "1", "-1", "0", "72", "0"],
                        hdr=True,
                        dynamic=dynamic,
                    )]
                elif policy == "alpha_geometry":
                    association = "straight" if "straight_alpha" in spec["coverage"] else "premultiplied"
                    visible = identity(f"{fixture_id}-{side}-visible")
                    assert alpha_source_hash is not None
                    assert alpha_output_hash is not None
                    alpha_hash = (
                        alpha_source_hash if side == "input" else alpha_output_hash
                    )
                    pixels = [{
                        "ordinal": 0, "kind": "video", "pixelFormat": "BGRA", "bitDepth": 8,
                        "width": 16 if side == "input" else 24,
                        "height": 16 if side == "input" else 24,
                        "frameCount": 1,
                        "visibleSHA256": visible,
                        "repeatVisibleSHA256": visible if side == "output" else identity(f"{fixture_id}-input-repeat"),
                        "alphaSHA256": alpha_hash,
                        "alphaFrameSHA256": [alpha_hash],
                        "preEncodeAlphaFrameSHA256": (
                            [alpha_output_hash] if side == "output" else []
                        ),
                        "repeatPreEncodeAlphaFrameSHA256": (
                            [alpha_output_hash] if side == "output" else []
                        ),
                        "decodedAlphaSHA256": alpha_hash,
                        "uniqueSignalCodeCount": 0, "lowPaddingBitViolationCount": 0,
                    }]
                    attachments = [attachment_row(
                        0,
                        aspect=(4, 3),
                        aperture=("14", "14", "1", "1") if side == "input" else ("21", "21", "3/2", "3/2"),
                        transform=["1", "0", "0", "1", "2", "2"] if side == "input" else ["1", "0", "0", "1", "3", "3"],
                        alpha=association,
                    )]
                elif policy == "process_primary_preserve_auxiliary":
                    for ordinal, kind in enumerate(kinds):
                        if kind not in {"video", "auxiliary"}:
                            continue
                        is_primary = ordinal == 0
                        width = 96 if is_primary and side == "output" else 64
                        height = 72 if is_primary and side == "output" else 48
                        signal_label = (
                            f"{fixture_id}-primary-{side}-visible"
                            if is_primary
                            else f"{fixture_id}-{ordinal}-preserved-visible"
                        )
                        visible = identity(signal_label)
                        pixels.append({
                            "ordinal": ordinal,
                            "kind": "video",
                            "pixelFormat": "BGRA",
                            "bitDepth": 8,
                            "width": width,
                            "height": height,
                            "frameCount": 1,
                            "visibleSHA256": visible,
                            "repeatVisibleSHA256": visible,
                            "alphaSHA256": None,
                            "alphaFrameSHA256": [],
                            "preEncodeAlphaFrameSHA256": [],
                            "repeatPreEncodeAlphaFrameSHA256": [],
                            "decodedAlphaSHA256": None,
                            "uniqueSignalCodeCount": 0,
                            "lowPaddingBitViolationCount": 0,
                        })
                        attachments.append(attachment_row(
                            ordinal,
                            aperture=(
                                str(width), str(height), "0", "0"
                            ),
                        ))
                pixel_observation = {
                    "schemaVersion": qualification.MEDIA_PIXEL_SCHEMA,
                    "fixtureID": fixture_id,
                    "side": side,
                    "pixelArtifactSHA256": qualification.sha256(pixel_path),
                    "pixelArtifactByteCount": pixel_path.stat().st_size,
                    "tracks": pixels,
                }
                attachment_observation = {
                    "schemaVersion": qualification.MEDIA_ATTACHMENT_SCHEMA,
                    "fixtureID": fixture_id,
                    "side": side,
                    "tracks": attachments,
                }
                documents = {
                    "trackObservation": track_observation,
                    "timingObservation": timing_observation,
                    "pixelObservation": pixel_observation,
                    "attachmentObservation": attachment_observation,
                }
                file_paths = {"media": media_path, "pixels": pixel_path}
                for name, document in documents.items():
                    path = side_dir / {
                        "trackObservation": "track-observation.json",
                        "timingObservation": "timing-observation.json",
                        "pixelObservation": "pixel-observation.json",
                        "attachmentObservation": "attachment-observation.json",
                    }[name]
                    write_json(path, document)
                    file_paths[name] = path
                manifest = {
                    "schemaVersion": qualification.MEDIA_SIDE_MANIFEST_SCHEMA,
                    "fixtureID": fixture_id,
                    "side": side,
                    "enabledTrackCount": len(track_rows),
                    "artifacts": {name: descriptor(path, self.root) for name, path in sorted(file_paths.items())},
                    "semanticIdentities": {
                        "trackSHA256": qualification.sha256_bytes(qualification.canonical_bytes(track_observation)),
                        "timingSHA256": qualification.sha256_bytes(qualification.canonical_bytes(timing_observation)),
                        "pixelSHA256": qualification.sha256_bytes(qualification.canonical_bytes(pixel_observation)),
                        "attachmentSHA256": qualification.sha256_bytes(qualification.canonical_bytes(attachment_observation)),
                    },
                }
                manifest_path = role_dir / "fixtures" / fixture_id / f"{side}-manifest.json"
                write_json(manifest_path, manifest)
                raw_side: dict[str, object] = {}
                for name, path in file_paths.items():
                    raw_path = raw_side_dir / path.name
                    raw_path.write_bytes(path.read_bytes())
                    raw_side[name] = descriptor(raw_path, capture_root)
                side_results[side] = {"manifest": manifest, "manifestPath": manifest_path}
                raw_descriptors[side] = raw_side

            if policy == "p010_field_normalization":
                checks = [
                    {"id": "exact-rational-geometry-transform", "pass": True},
                    {"id": "repeat-output-visible-pixel-identity", "pass": True},
                    {"id": "p010-static-and-frame-bound-dynamic-hdr-identity", "pass": True},
                    {"id": "tff-field-order-and-double-rate-cadence", "pass": True},
                ]
            elif policy == "alpha_geometry":
                association = "straight" if "straight_alpha" in spec["coverage"] else "premultiplied"
                checks = [
                    {"id": "exact-rational-geometry-transform", "pass": True},
                    {"id": "repeat-output-visible-pixel-identity", "pass": True},
                    {"id": f"exact-prores4444-{association}-alpha", "pass": True},
                ]
            else:
                checks = [
                    {
                        "id": "processed-primary-exact-auxiliary-preservation",
                        "pass": True,
                    },
                    {"id": "exact-rational-geometry-transform", "pass": True},
                    {"id": "repeat-output-visible-pixel-identity", "pass": True},
                ]
                for coverage_id in ("subtitles", "captions", "chapters", "timecode_tracks", "timed_metadata", "auxiliary_tracks"):
                    if coverage_id in spec["coverage"]:
                        checks.append({"id": f"{coverage_id}-present-and-accounted", "pass": True})
                if "multiple_enabled_video_tracks" in spec["coverage"]:
                    checks.append({"id": "multiple-enabled-video-tracks-accounted", "pass": True})
                if "alternate_audio_tracks" in spec["coverage"]:
                    checks.append({"id": "alternate-audio-selection-group-accounted", "pass": True})
            checks.insert(0, {
                "id": "video-processing-session-deterministic-v4-route",
                "pass": True,
            })
            target_width = 24 if policy == "alpha_geometry" else 96
            target_height = 24 if policy == "alpha_geometry" else 72
            processed_frames = 2 if policy == "p010_field_normalization" else 1
            prepared_backend = (
                "Mirmir.PreparedDeterministicAlphaPlanningBackendV4"
                if policy == "alpha_geometry"
                else "Mirmir.PreparedDeterministicV4Upscaler"
            )
            planned_tracks = [
                {
                    "ordinal": ordinal,
                    "stableID": track_rows[ordinal]["stableID"],
                    "kind": kind,
                    "action": (
                        "process" if ordinal == 0 else "pass_through"
                    ),
                }
                for ordinal, kind in enumerate(kinds)
            ]
            ash_plan_sha256 = identity(f"{fixture_id}-ash-plan")
            track_plan_sha256 = identity(f"{fixture_id}-track-plan")
            source_graph_sha256 = identity(f"{fixture_id}-source-graph")
            migration_blueprint_sha256 = identity(
                f"{fixture_id}-migration-blueprint"
            )
            preflight = {
                "schemaVersion": qualification.MEDIA_PREFLIGHT_SCHEMA,
                "preparedBackendType": prepared_backend,
                "executor": "cpu_fixed_point",
                "requestedBackendID": "mirmirDeterministicCPU",
                "ashPlanSHA256": ash_plan_sha256,
                "runtimeManifestSHA256":
                    self.candidate["runtimeManifestSHA256"],
                "runtimeProvenanceSHA256": self.runtime_provenance_sha256,
                "trackPlanSHA256": track_plan_sha256,
                "sourceGraphSHA256": source_graph_sha256,
                "migrationBlueprintSHA256": migration_blueprint_sha256,
                "primaryTrackOrdinal": 0,
                "plannedTracks": copy.deepcopy(planned_tracks),
                "targetWidth": target_width,
                "targetHeight": target_height,
                "sourceVideoTrackCount": sum(
                    kind == "video" for kind in kinds
                ),
                "sourceAudioTrackCount": sum(
                    kind == "audio" for kind in kinds
                ),
                "plannedEnabledTrackCount": len(kinds),
            }
            migrated_tracks: list[dict[str, object]] = []
            for planned in planned_tracks:
                is_pass_through = planned["action"] == "pass_through"
                stream_sha = (
                    identity(f"{fixture_id}-{planned['ordinal']}-sample-stream")
                    if is_pass_through else None
                )
                migrated_tracks.append({
                    "stableID": planned["stableID"],
                    "action": planned["action"],
                    "migratedSampleCount": (
                        processed_frames if planned["ordinal"] == 0 else 1
                    ),
                    "sourceSampleStreamSHA256": stream_sha,
                    "outputSampleStreamSHA256": stream_sha,
                })
            alpha_verification: dict[str, object] | None = None
            if policy == "alpha_geometry":
                assert alpha_output_hash is not None
                association = (
                    "straight"
                    if "straight_alpha" in spec["coverage"]
                    else "premultiplied"
                )
                alpha_verification = {
                    "schemaID": "ash.alpha-video-writer-verification.v4.1",
                    "codec": "proRes4444",
                    "association": association,
                    "inputLayout": "bgra8",
                    "width": target_width,
                    "height": target_height,
                    "encodedFormat": {
                        "canonicalFingerprint": identity(
                            f"{fixture_id}-encoded-format"
                        )
                    },
                    "frames": [{
                        "ordinal": 0,
                        "presentationTime": {
                            "numerator": 0,
                            "denominator": 1,
                        },
                        "alphaByteCount": target_width * target_height,
                        "sourceAlphaSHA256": alpha_output_hash,
                        "decodedAlphaSHA256": alpha_output_hash,
                    }],
                }
            receipt = {
                "schemaID": qualification.MEDIA_EXECUTION_RECEIPT_SCHEMA,
                "preparedBackendType": prepared_backend,
                "executor": "cpu_fixed_point",
                "requestedBackendID": "mirmirDeterministicCPU",
                "actualBackendID": "mirmirDeterministicCPU",
                "ashPlanSHA256": ash_plan_sha256,
                "runtimeManifestSHA256":
                    self.candidate["runtimeManifestSHA256"],
                "runtimeProvenanceSHA256": self.runtime_provenance_sha256,
                "trackPlanSHA256": track_plan_sha256,
                "sourceGraphSHA256": source_graph_sha256,
                "migrationSourceGraphSHA256": source_graph_sha256,
                "migrationPlanSHA256": track_plan_sha256,
                "migrationBlueprintSHA256": migration_blueprint_sha256,
                "sourceAssetMetadataSHA256": identity(
                    f"{fixture_id}-asset-metadata"
                ),
                "outputAssetMetadataSHA256": identity(
                    f"{fixture_id}-asset-metadata"
                ),
                "sourceChapterMetadataSHA256": identity(
                    f"{fixture_id}-chapter-metadata"
                ),
                "outputChapterMetadataSHA256": identity(
                    f"{fixture_id}-chapter-metadata"
                ),
                "outputGraphSHA256": identity(f"{fixture_id}-output-graph"),
                "semanticVerificationSHA256": identity(
                    f"{fixture_id}-semantic-verification"
                ),
                "primaryTrackOrdinal": 0,
                "plannedTracks": copy.deepcopy(planned_tracks),
                "migratedTracks": migrated_tracks,
                "targetWidth": target_width,
                "targetHeight": target_height,
                "encodedWidth": target_width,
                "encodedHeight": target_height,
                "processedFrameCount": processed_frames,
                "sourceVideoTrackCount": sum(
                    kind == "video" for kind in kinds
                ),
                "sourceAudioTrackCount": sum(
                    kind == "audio" for kind in kinds
                ),
                "plannedEnabledTrackCount": len(kinds),
                "alphaVerification": alpha_verification,
            }
            route_receipt = {
                "schemaVersion": qualification.MEDIA_ROUTE_SCHEMA,
                "entryPoint":
                    "VideoProcessingSession.processWithDeterministicV4ExecutionReceipt",
                "executionProducer": "exact_archived_mirmir_executable",
                "dispatchRequirement":
                    "PreparedDeterministicV4RuntimePlanningBackend",
                "planEvidenceBoundary":
                    "actual_session_receipt_matched_independent_preflight",
                "evidenceRequestSHA256": request_sha256,
                "evidenceNonceSHA256": nonce_sha256,
                "applicationArchiveSHA256": packaged_candidate[
                    "applicationArchiveSHA256"
                ],
                "applicationExecutableSHA256": packaged_candidate[
                    "applicationExecutableSHA256"
                ],
                "sourceTreeIdentitySHA256": self.candidate[
                    "sourceTreeIdentitySHA256"
                ],
                "independentPreflight": copy.deepcopy(preflight),
                "repeatIndependentPreflight": copy.deepcopy(preflight),
                "executionReceipt": copy.deepcopy(receipt),
                "repeatExecutionReceipt": copy.deepcopy(receipt),
                "independentPreflightSHA256": qualification.sha256_bytes(
                    qualification.canonical_bytes(preflight)
                ),
                "repeatIndependentPreflightSHA256": qualification.sha256_bytes(
                    qualification.canonical_bytes(preflight)
                ),
                "executionReceiptSHA256": qualification.sha256_bytes(
                    qualification.canonical_bytes(receipt)
                ),
                "repeatExecutionReceiptSHA256": qualification.sha256_bytes(
                    qualification.canonical_bytes(receipt)
                ),
                "inputEnabledTrackCount": len(kinds),
                "outputEnabledTrackCount": len(kinds),
            }
            route_receipt["routeProofSHA256"] = qualification.sha256_bytes(
                qualification.canonical_bytes(route_receipt)
            )
            violations = {
                "unconsentedDropCount": 0, "silentToneMapCount": 0,
                "precisionReductionCount": 0, "alphaLossCount": 0,
                "geometryMismatchCount": 0, "metadataMismatchCount": 0,
            }
            verifier = {
                "schemaVersion": qualification.MEDIA_SEMANTIC_VERIFIER_SCHEMA,
                "fixtureID": fixture_id,
                "policy": policy,
                "coverage": spec["coverage"],
                "candidateRuntimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                "inputManifestSHA256": qualification.sha256(side_results["input"]["manifestPath"]),
                "outputManifestSHA256": qualification.sha256(side_results["output"]["manifestPath"]),
                "productionRouteProofSHA256": route_receipt[
                    "routeProofSHA256"
                ],
                "checks": checks,
                "violationCounts": violations,
                "exactSemanticVerifierPass": True,
            }
            verifier_path = role_dir / "fixtures" / fixture_id / "semantic-verifier.json"
            write_json(verifier_path, verifier)
            report_fixtures.append({
                "id": fixture_id,
                "coverage": spec["coverage"],
                "enabledInputTrackCount": len(track_rows),
                "accountedOutputTrackCount": len(track_rows),
                **violations,
                "exactSemanticVerifierPass": True,
                "productionRouteProofSHA256": route_receipt[
                    "routeProofSHA256"
                ],
                "inputManifestArtifact": descriptor(side_results["input"]["manifestPath"], self.root),
                "outputManifestArtifact": descriptor(side_results["output"]["manifestPath"], self.root),
                "semanticVerifierArtifact": descriptor(verifier_path, self.root),
            })
            capture_fixtures.append({
                "id": fixture_id,
                "coverage": spec["coverage"],
                "policy": policy,
                "enabledInputTrackCount": len(track_rows),
                "accountedOutputTrackCount": len(track_rows),
                "alphaOracleInput": alpha_oracle_input,
                "production": {
                    "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                    "routeReceipt": route_receipt,
                },
                "input": raw_descriptors["input"],
                "output": raw_descriptors["output"],
            })
            total_enabled += len(track_rows)

        capture = {
            "schemaVersion": qualification.MEDIA_CAPTURE_SCHEMA,
            "suiteID": lane_contract["suiteID"],
            "evidenceRequestSHA256": request_sha256,
            "evidenceNonceSHA256": nonce_sha256,
            "observerSourceSHA256": tool_identities[
                "observerSourceSHA256"
            ],
            "laneContractSHA256": lane_contract_sha,
            "fixtureManifestSHA256": fixture_manifest_sha256,
            "fixtureTreeSHA256": fixture_tree_sha256,
            "fixtureSourceSHA256": tool_identities["fixtureSourceSHA256"],
            "generatorSourceSHA256": tool_identities["captureSourceSHA256"],
            "packagedCandidateIdentity": packaged_candidate,
            "buildConfiguration": "Release",
            "fixtures": capture_fixtures,
        }
        capture_path = capture_root / "capture.json"
        write_json(capture_path, capture)
        capture_tree = qualification.packaged_capture_tree(capture_root)
        result = {
            "schemaVersion": "mirmir-v4-packaged-evidence-result-v1",
            "lane": "media",
            "requestID": request["requestID"],
            "requestSHA256": request_sha256,
            "observerSourceSHA256": tool_identities[
                "observerSourceSHA256"
            ],
            "contractSHA256": lane_contract_sha,
            "packageIdentity": packaged_candidate,
            "process": {
                "bundlePath": "/Applications/Mirmir.app",
                "executablePath": "/Applications/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": packaged_candidate[
                    "applicationExecutableSHA256"
                ],
                "processID": 100,
                "parentProcessID": 99,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": "capture.json",
                "byteCount": capture_path.stat().st_size,
                "sha256": qualification.sha256(capture_path),
            },
            "captureTree": capture_tree,
            "checks": {
                "exactExecutableIdentity": True,
                "signedBuildClaims": True,
                "productionP06Load": True,
                "normativePixelCapture": True,
            },
        }
        result_path = observer_dir / "result.json"
        write_json(result_path, result)
        record = {
            "schemaVersion":
                "mirmir-v4-packaged-evidence-capture-record-v1",
            "lane": "media",
            "startedAtUTC": "2026-08-14T00:00:00Z",
            "finishedAtUTC": "2026-08-14T00:00:01Z",
            "requestSHA256": request_sha256,
            "observerSourceSHA256": tool_identities[
                "observerSourceSHA256"
            ],
            "contractSHA256": lane_contract_sha,
            "packageIdentity": packaged_candidate,
            "captureTree": capture_tree,
            "process": {
                "executableSHA256": packaged_candidate[
                    "applicationExecutableSHA256"
                ],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": descriptor(request_path, raw_root),
                "result": descriptor(result_path, raw_root),
            },
        }
        record_path = raw_root / "capture-record.json"
        write_json(record_path, record)
        report.update({
            "evidenceBoundary": {
                "mediaExecutionProducer":
                    "exact_verified_archived_mirmir_executable",
                "packagedCandidateBindingRole":
                    "normative_output_execution_and_observation",
                "candidatePreparationReplayRole":
                    "separate_release_candidate_preparation_replay_required",
                "mediaArchiveInspectionScope":
                    "archive_extraction_executable_execution_and_tree_seal",
                "archivedExecutableExecutionClaimed": True,
                "fixtureHostRole":
                    "source_fixture_generation_and_source_alpha_observation_only",
                "actualSessionReceiptRequired": True,
                "independentAlphaOracleRequired": True,
            },
            "identities": {
                "laneContractSHA256": lane_contract_sha,
                **tool_identities,
                "packagedEvidenceRequestSHA256": request_sha256,
                "packagedEvidenceCaptureTree": capture_tree,
                "captureSHA256": qualification.sha256(capture_path),
                "packagedCandidateIdentity": packaged_candidate,
            },
            "fixtures": report_fixtures,
            "accountedEnabledTrackCount": total_enabled,
            "mediaPreservationGatePass": True,
        })
        extra_bindings.extend([
            ("/identities/laneContractSHA256", lane_contract_path),
            ("/identities/captureSourceSHA256", capture_source),
            ("/identities/fixtureSourceSHA256", fixture_source),
            ("/identities/evaluatorSHA256", evaluator_source),
            ("/identities/runnerSHA256", runner_source),
            ("/identities/packagedEvidenceToolSHA256", packaged_source),
            (
                "/identities/releaseCandidateArchiveToolSHA256",
                archive_tool_source,
            ),
            ("/identities/observerSourceSHA256", observer_source),
            ("/identities/packagedEvidenceRequestSHA256", request_path),
            ("/identities/captureSHA256", capture_path),
            (
                "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
                application_archive,
            ),
            (
                "/identities/packagedCandidateIdentity/attestationSHA256",
                attestation_path,
            ),
        ])

    def _build_recovery_v2(
        self,
        role_dir: Path,
        report: dict[str, object],
        lane_contract: dict[str, object],
        contract_sha: str,
        extra_bindings: list[tuple[str, Path]],
    ) -> None:
        observer_bytes = (
            SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift"
        ).read_bytes()
        attestation_bytes = qualification.canonical_bytes(
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            }
        )
        package = copy.deepcopy(self.packaged_candidate_identity)
        if (
            package["applicationArchiveSHA256"]
            != qualification.sha256_bytes(self.app_bytes)
            or package["releaseConfigurationSHA256"]
            != qualification.sha256_bytes(self.release_bytes)
            or package["attestationSHA256"]
            != qualification.sha256_bytes(attestation_bytes)
        ):
            raise AssertionError("recovery package fixture differs from candidate")

        fixture = recovery_fixture_module.PackagedRecoveryFixture(
            role_dir / "captures",
            contract=lane_contract,
            contract_bytes=(role_dir / "suite-contract.json").read_bytes(),
            candidate=self.candidate,
            package=package,
            observer_bytes=observer_bytes,
            release_configuration_bytes=self.release_bytes,
            application_archive_bytes=self.app_bytes,
            attestation_bytes=attestation_bytes,
        )
        if fixture.contract_sha != contract_sha:
            raise AssertionError("recovery lane contract serialization differs")
        evaluated_report, capture_manifest = fixture.evaluate()
        capture_manifest_path = role_dir / "capture-artifact-manifest.json"
        write_json(capture_manifest_path, capture_manifest)
        evaluated_report["captureManifestSHA256"] = qualification.sha256(
            capture_manifest_path
        )
        report.clear()
        report.update(evaluated_report)

        tool_paths = {
            "archiveProvenanceSHA256": role_dir
            / "release_candidate_archive_v4.py",
            "evaluatorSHA256": role_dir / "recovery_qualification_v4.py",
            "observerSourceSHA256": role_dir / "MirmirApp.swift",
            "packagedEvidenceSHA256": role_dir
            / "packaged_candidate_evidence_v4.py",
            "producerSourceSHA256": role_dir
            / "WorkflowApplicationCoordinatorV4.swift",
            "runnerSHA256": role_dir / "run_recovery_qualification_v4.sh",
        }
        source_paths = {
            "archiveProvenanceSHA256": SCRIPT_DIRECTORY
            / "release_candidate_archive_v4.py",
            "evaluatorSHA256": SCRIPT_DIRECTORY
            / "recovery_qualification_v4.py",
            "observerSourceSHA256": SCRIPT_DIRECTORY.parent.parent
            / "Mirmir/App/MirmirApp.swift",
            "packagedEvidenceSHA256": SCRIPT_DIRECTORY
            / "packaged_candidate_evidence_v4.py",
            "producerSourceSHA256": SCRIPT_DIRECTORY.parent.parent
            / "Mirmir/App/WorkflowApplicationCoordinatorV4.swift",
            "runnerSHA256": SCRIPT_DIRECTORY
            / "run_recovery_qualification_v4.sh",
        }
        for identity_name, destination in tool_paths.items():
            destination.write_bytes(source_paths[identity_name].read_bytes())
            if qualification.sha256(destination) != report["identities"][identity_name]:
                raise AssertionError(
                    f"committed recovery tool identity is stale: {identity_name}"
                )

        application_archive = role_dir / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        extra_bindings.extend(
            [
                ("/contractSHA256", role_dir / "suite-contract.json"),
                *[
                    (f"/identities/{identity_name}", path)
                    for identity_name, path in tool_paths.items()
                ],
                (
                    "/execution/applicationArchiveSHA256",
                    application_archive,
                ),
                ("/captureManifestSHA256", capture_manifest_path),
                (
                    "/captures/0/requestSHA256",
                    fixture.first_root / "observer/request.json",
                ),
                (
                    "/captures/1/requestSHA256",
                    fixture.second_root / "observer/request.json",
                ),
            ]
        )
        self.recovery_fixture = fixture
        self.recovery_capture_manifest_path = capture_manifest_path

    def _build_notarized_smoke(
        self,
        role_dir: Path,
        report: dict[str, object],
        contract_path: Path,
        extra_bindings: list[tuple[str, Path]],
    ) -> None:
        raw_root = role_dir / "raw"
        bindings_root = raw_root / "bindings"
        archives_root = raw_root / "archives"
        commands_root = raw_root / "commands"
        observer_source = bindings_root / "MirmirApp.swift"
        evaluator_source = bindings_root / "notarized_smoke_v4.py"
        runner_source = bindings_root / "run_notarized_smoke_v4.py"
        observer_source.parent.mkdir(parents=True, exist_ok=True)
        observer_source.write_bytes(
            (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
            .read_bytes()
        )
        evaluator_source.write_bytes(
            (SCRIPT_DIRECTORY / "notarized_smoke_v4.py").read_bytes()
        )
        runner_source.write_bytes(
            (SCRIPT_DIRECTORY / "run_notarized_smoke_v4.py").read_bytes()
        )

        action_records = {
            "notarization_ticket_acceptance": ["notary_info", "notary_log"],
            "gatekeeper_assessment": ["gatekeeper_assessment"],
            "stapled_ticket_validation": ["stapled_ticket_validation"],
            "code_signature_validation": [
                "code_signature_validation",
                "code_signature_display",
                "code_signature_display_arm64",
                "code_signature_display_x86_64",
                "code_signature_entitlements",
                "code_signature_requirements",
                "submitted_signature_display",
                "submitted_signature_display_arm64",
                "submitted_signature_display_x86_64",
                "submitted_signature_requirements",
            ],
            "launch": ["observer_prepare"],
            "p06_runtime_load": ["observer_prepare"],
            "media_probe": ["observer_prepare"],
            "deterministic_process": ["observer_prepare"],
            "semantic_output_verify": ["observer_recover"],
            "queue_relaunch_recovery": ["observer_recover"],
        }
        common_records = [
            "gatekeeper_assessment",
            "stapled_ticket_validation",
            "code_signature_validation",
            "code_signature_display",
            "code_signature_display_arm64",
            "code_signature_display_x86_64",
            "code_signature_entitlements",
            "code_signature_requirements",
            "submitted_signature_display",
            "submitted_signature_display_arm64",
            "submitted_signature_display_x86_64",
            "submitted_signature_requirements",
            "observer_prepare",
            "observer_recover",
        ]
        lane_contract_source = SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json"
        lane_contract = json.loads(lane_contract_source.read_text())
        if lane_contract["requiredCommandRecords"] != common_records:
            raise AssertionError("committed notarized smoke command contract changed")
        expected_providers = {
            "notarytool": {
                "requiredArtifacts": [],
                "requiredCommandRecords": ["notary_info", "notary_log"],
                "requiredTools": ["notarytool"],
            },
            "xcode_archive": {
                "requiredArtifacts": ["xcodeArchiveInfo"],
                "requiredCommandRecords": [
                    "xcode_export_notarized_app",
                    "xcode_export_archive",
                ],
                "requiredTools": ["xcodebuild"],
            },
        }
        if lane_contract["acceptanceProviders"] != expected_providers:
            raise AssertionError("committed notarized smoke provider contract changed")
        acceptance_provider = "notarytool"
        provider_records = expected_providers[acceptance_provider][
            "requiredCommandRecords"
        ]
        required_records = [*common_records, *provider_records]
        lane_contract_path = bindings_root / "notarized-smoke-contract-v1.json"
        lane_contract_path.write_bytes(lane_contract_source.read_bytes())
        release_contract_path = bindings_root / "release-qualification-contract-v1.json"
        release_contract_path.write_bytes(contract_path.read_bytes())
        candidate_path = bindings_root / "candidate.json"
        write_json(candidate_path, self.candidate)

        candidate_archive = archives_root / "Mirmir-notarized.zip"
        submitted_archive = archives_root / "Mirmir-submitted.zip"
        candidate_archive.parent.mkdir(parents=True, exist_ok=True)
        candidate_archive.write_bytes(self.app_bytes)
        submitted_archive.write_bytes(b"accepted-pre-staple-archive")
        executable = bindings_root / "Mirmir-executable"
        executable.write_bytes(b"shipping-app-executable")
        tool_manifest = bindings_root / "tool-identities.json"
        tool_paths = {
            "app": str(executable),
            "codesign": "/usr/bin/codesign",
            "ditto": "/usr/bin/ditto",
            "notarytool": "/usr/bin/xcrun",
            "python3": "/usr/bin/python3",
            "spctl": "/usr/sbin/spctl",
            "stapler": "/usr/bin/xcrun",
            "xcrun": "/usr/bin/xcrun",
        }
        tool_rows = {
            name: {
                "path": path,
                "sha256": qualification.sha256(executable)
                if name == "app"
                else identity(f"notarized-smoke-tool-{name}"),
            }
            for name, path in sorted(tool_paths.items())
        }
        write_json(
            tool_manifest,
            {
                "schemaVersion": (
                    "mirmir-ash-v4-notarized-smoke-tool-identities-v1"
                ),
                "tools": tool_rows,
            },
        )
        notary_log = raw_root / "apple" / "notary-log.json"
        write_json(notary_log, {"status": "Accepted", "statusCode": 0})

        command_records: dict[str, dict[str, object]] = {}
        record_paths: dict[str, Path] = {}
        for record_id in required_records:
            record_path = commands_root / f"{record_id}.json"
            write_json(record_path, {"id": record_id, "exitStatus": 0})
            record_paths[record_id] = record_path
            command_records[record_id] = descriptor(record_path, raw_root)

        created = "2026-08-02T12:00:00Z"
        finished = "2026-08-02T12:00:02Z"
        raw_identities = {
            "observerSourceSHA256": qualification.sha256(observer_source),
            "evaluatorSHA256": qualification.sha256(evaluator_source),
            "runnerSHA256": qualification.sha256(runner_source),
            "applicationExecutableSHA256": qualification.sha256(executable),
            "submittedArchiveSHA256": qualification.sha256(submitted_archive),
            "candidateArchiveSHA256": qualification.sha256(candidate_archive),
            "toolManifestSHA256": qualification.sha256(tool_manifest),
        }
        raw_artifacts = {
            "candidateJSON": descriptor(candidate_path, raw_root),
            "laneContract": descriptor(lane_contract_path, raw_root),
            "releaseContract": descriptor(release_contract_path, raw_root),
            "observerSource": descriptor(observer_source, raw_root),
            "evaluator": descriptor(evaluator_source, raw_root),
            "runner": descriptor(runner_source, raw_root),
            "candidateArchive": descriptor(candidate_archive, raw_root),
            "submittedArchive": descriptor(submitted_archive, raw_root),
            "candidateExecutable": descriptor(executable, raw_root),
            "toolManifest": descriptor(tool_manifest, raw_root),
            "notaryLog": descriptor(notary_log, raw_root),
        }
        raw_capture = {
            "schemaVersion": "mirmir-ash-v4-notarized-smoke-capture-v1",
            "suiteID": lane_contract["suiteID"],
            "createdAtUTC": created,
            "finishedAtUTC": finished,
            "laneContractSHA256": qualification.sha256(lane_contract_path),
            "releaseContractSHA256": qualification.sha256(contract_path),
            "candidate": self.candidate,
            "identities": raw_identities,
            "notarySubmission": {
                "provider": acceptance_provider,
                "id": "11111111-1111-4111-8111-111111111111",
                "submittedArchiveName": submitted_archive.name,
            },
            "artifacts": raw_artifacts,
            "commandRecords": command_records,
            "observerInvocations": [{"phase": "prepare"}, {"phase": "recover"}],
        }
        raw_capture_path = raw_root / "capture.json"
        write_json(raw_capture_path, raw_capture)
        receipt = {
            "schemaVersion": (
                "mirmir-ash-v4-notarized-smoke-replay-receipt-v1"
            ),
            "captureSHA256": qualification.sha256(raw_capture_path),
            "evaluationSHA256": identity("notarized-smoke-evaluation"),
            "verifiedActionIDs": self.contract["notarizedSmokeActions"],
            "verifiedAtUTC": finished,
            "nestedEvidenceReplayPass": True,
        }
        receipt_path = role_dir / "replay-receipt.json"
        write_json(receipt_path, receipt)

        action_rows = []
        for action in self.contract["notarizedSmokeActions"]:
            transcript_path = role_dir / "transcripts" / f"{action}.json"
            claims = {
                "candidateArchiveSHA256": self.candidate["appBundleSHA256"],
                "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            }
            if action == "notarization_ticket_acceptance":
                claims.update(
                    {
                        "acceptanceProvider": acceptance_provider,
                        "submissionID": raw_capture["notarySubmission"]["id"],
                        "status": "Accepted",
                        "issueCount": 0,
                        "archiveSHA256": raw_identities[
                            "submittedArchiveSHA256"
                        ],
                    }
                )
            write_json(
                transcript_path,
                {
                    "schemaVersion": (
                        "mirmir-ash-v4-notarized-smoke-action-transcript-v1"
                    ),
                    "actionID": action,
                    "evidenceKind": self.contract["notarizedSmokeEvidenceKinds"][action],
                    "sourceRecordIDs": action_records[action],
                    "claims": claims,
                    "rawArtifacts": [
                        descriptor(record_paths[record_id], role_dir)
                        for record_id in action_records[action]
                    ],
                },
            )
            command = ["mirmir-v4-external-observer", "--action", action]
            attestation_path = role_dir / "attestations" / f"{action}.json"
            write_json(
                attestation_path,
                {
                    "schemaVersion": "mirmir-ash-v4-external-execution-evidence-v1",
                    "actionID": action,
                    "evidenceKind": self.contract["notarizedSmokeEvidenceKinds"][action],
                    "command": command,
                    "invocationSHA256": qualification.sha256_bytes(qualification.canonical_bytes(command)),
                    "exitStatus": 0,
                    "startedAtUTC": created,
                    "finishedAtUTC": finished,
                    "observedAppBundleSHA256": self.candidate["appBundleSHA256"],
                    "observedRuntimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                    "transcriptArtifact": descriptor(transcript_path, role_dir),
                },
            )
            action_rows.append(
                {
                    "id": action,
                    "pass": True,
                    "externalEvidenceArtifact": descriptor(attestation_path, role_dir),
                }
            )

        report.update(
            {
                "identities": {
                    "laneContractSHA256": qualification.sha256(lane_contract_path),
                    "observerSourceSHA256": qualification.sha256(observer_source),
                    "evaluatorSHA256": qualification.sha256(evaluator_source),
                    "runnerSHA256": qualification.sha256(runner_source),
                    "rawCaptureSHA256": qualification.sha256(raw_capture_path),
                    "applicationExecutableSHA256": qualification.sha256(executable),
                    "submittedArchiveSHA256": qualification.sha256(submitted_archive),
                    "toolManifestSHA256": qualification.sha256(tool_manifest),
                    "replayReceiptSHA256": qualification.sha256(receipt_path),
                },
                "appBundleSHA256": self.candidate["appBundleSHA256"],
                "bundleIdentifier": self.candidate["bundleIdentifier"],
                "productVersion": self.candidate["productVersion"],
                "productBuild": self.candidate["productBuild"],
                "notarizationAccepted": True,
                "ticketStapled": True,
                "gatekeeperAccepted": True,
                "codeSignatureValid": True,
                "hardenedRuntimeEnabled": True,
                "productionP06Loaded": True,
                "actions": action_rows,
                "capture": {
                    "createdAtUTC": created,
                    "finishedAtUTC": finished,
                    "rawCaptureArtifact": descriptor(raw_capture_path, role_dir),
                    "replayReceiptArtifact": descriptor(receipt_path, role_dir),
                    "nestedEvidenceReplayPass": True,
                },
                "notarizedSmokeGatePass": True,
            }
        )
        extra_bindings.extend(
            [
                ("/candidate/appBundleSHA256", candidate_archive),
                ("/identities/laneContractSHA256", lane_contract_path),
                ("/identities/observerSourceSHA256", observer_source),
                ("/identities/evaluatorSHA256", evaluator_source),
                ("/identities/runnerSHA256", runner_source),
                ("/identities/rawCaptureSHA256", raw_capture_path),
                ("/identities/applicationExecutableSHA256", executable),
                ("/identities/submittedArchiveSHA256", submitted_archive),
                ("/identities/toolManifestSHA256", tool_manifest),
                ("/identities/replayReceiptSHA256", receipt_path),
            ]
        )

    def _build_parity_package_fixture(
        self,
        fixture: object,
        capture_source: Path,
        package_root: Path,
        process_id: str,
        request_ordinal: int,
    ) -> dict[str, object]:
        package = copy.deepcopy(self.packaged_candidate_identity)
        bindings = package_root / "bindings"
        observer = package_root / "observer"
        bindings.mkdir(parents=True, exist_ok=True)
        observer.mkdir(parents=True, exist_ok=True)

        def write_canonical(path: Path, value: object) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(qualification.canonical_bytes(value))

        destination_capture = package_root / "capture"
        capture = parity_fixture_module.parity.load_json(capture_source / "capture.json")
        request_id = (
            "22222222-2222-4222-8222-22222222222"
            + str(request_ordinal)
        )
        request = {
            "schemaVersion": "mirmir-v4-packaged-evidence-request-v1",
            "lane": "parity",
            "requestID": request_id,
            "nonce": identity(f"parity-request-nonce-{request_ordinal}"),
            "generatedAtUTC": "2026-08-02T12:00:00Z",
            "observerSourceSHA256": qualification.sha256_bytes(
                (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
                .read_bytes()
            ),
            "contractSHA256": qualification.sha256(fixture.contract_path),
            "packageIdentity": package,
            "captureEnvironment": {
                "MIRMIR_PARITY_CAPTURE_DIRECTORY": "/fixture/capture",
                "MIRMIR_PARITY_CONTRACT_PATH": "/fixture/inputs/contract.json",
                "MIRMIR_PARITY_CONTRACT_SHA256": qualification.sha256(
                    fixture.contract_path
                ),
                "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256": qualification.sha256(
                    fixture.capture_source
                ),
                "MIRMIR_PARITY_SOURCE_REVISION": self.candidate["sourceCommit"],
                "MIRMIR_PARITY_BUILD_CONFIGURATION": "Release",
                "MIRMIR_PARITY_PROCESS_RUN_ID": process_id,
                "MIRMIR_PARITY_RUNTIME_MODE": "production",
            },
        }
        request_path = observer / "request.json"
        write_canonical(request_path, request)
        request_sha = qualification.sha256(request_path)
        capture["evidenceRequestSHA256"] = request_sha
        capture["packagedCandidateIdentity"] = package
        parity_fixture_module.parity.write_json(capture_source / "capture.json", capture)
        fixture.reseal(capture_source)
        shutil.move(str(capture_source), str(destination_capture))

        candidate_path = bindings / "candidate.json"
        package_path = bindings / "package-identity.json"
        write_canonical(candidate_path, self.candidate)
        write_canonical(package_path, package)
        attestation = bindings / "application-archive-attestation-v1.json"
        write_canonical(
            attestation,
            {
                "schemaVersion": "mirmir-v4-release-archive-attestation-v1",
                "fixtureOnly": True,
            },
        )
        observer_source = bindings / "observer-source.swift"
        observer_source.write_bytes(
            (SCRIPT_DIRECTORY.parent.parent / "Mirmir/App/MirmirApp.swift")
            .read_bytes()
        )
        lane_contract = bindings / "lane-contract.json"
        lane_contract.write_bytes(fixture.contract_path.read_bytes())
        release_configuration = bindings / "release-candidate-v4.xcconfig"
        release_configuration.write_bytes(self.release_bytes)
        application_archive = bindings / "application-archive.zip"
        application_archive.write_bytes(self.app_bytes)
        capture_tree = qualification.packaged_capture_tree(destination_capture)
        result = {
            "schemaVersion": "mirmir-v4-packaged-evidence-result-v1",
            "lane": "parity",
            "requestID": request_id,
            "requestSHA256": request_sha,
            "observerSourceSHA256": request["observerSourceSHA256"],
            "contractSHA256": qualification.sha256(fixture.contract_path),
            "packageIdentity": package,
            "process": {
                "bundlePath": "/fixture/Mirmir.app",
                "executablePath": "/fixture/Mirmir.app/Contents/MacOS/Mirmir",
                "executableSHA256": package["applicationExecutableSHA256"],
                "processID": 200 + request_ordinal,
                "parentProcessID": 199,
            },
            "runtime": {
                "runtimeID": "ash-p06-deterministic-v4",
                "releaseStatus": "release_qualified",
                "manifestSHA256": self.candidate["runtimeManifestSHA256"],
                "sourceRevision": self.candidate["runtimeSourceRevision"],
                "trustRootConfigured": True,
            },
            "captureManifest": {
                "fileName": "capture.json",
                "byteCount": (destination_capture / "capture.json").stat().st_size,
                "sha256": qualification.sha256(destination_capture / "capture.json"),
            },
            "captureTree": capture_tree,
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
        stderr_path = observer / "stderr.bin"
        stdout_path.write_bytes(b"fixture packaged parity observer result\n")
        stderr_path.write_bytes(b"")
        record = {
            "schemaVersion": "mirmir-v4-packaged-evidence-capture-record-v1",
            "lane": "parity",
            "startedAtUTC": "2026-08-02T12:00:00Z",
            "finishedAtUTC": "2026-08-02T12:00:01Z",
            "requestSHA256": request_sha,
            "observerSourceSHA256": request["observerSourceSHA256"],
            "contractSHA256": qualification.sha256(fixture.contract_path),
            "packageIdentity": package,
            "captureTree": capture_tree,
            "process": {
                "executableSHA256": package["applicationExecutableSHA256"],
                "exitStatus": 0,
            },
            "artifacts": {
                "request": descriptor(request_path, package_root),
                "result": descriptor(result_path, package_root),
                "stdout": descriptor(stdout_path, package_root),
                "stderr": descriptor(stderr_path, package_root),
                "candidate": descriptor(candidate_path, package_root),
                "packageIdentity": descriptor(package_path, package_root),
                "attestation": descriptor(attestation, package_root),
                "observerSource": descriptor(observer_source, package_root),
                "contract": descriptor(lane_contract, package_root),
                "releaseConfiguration": descriptor(
                    release_configuration, package_root
                ),
                "applicationArchive": descriptor(application_archive, package_root),
            },
        }
        write_canonical(package_root / "capture-record.json", record)
        return {
            "root": package_root,
            "requestSHA256": request_sha,
            "captureTree": capture_tree,
            "request": request_path,
            "applicationArchive": application_archive,
            "attestation": attestation,
        }

    def _build_parity_actual(self, role_dir: Path) -> None:
        parity_root = role_dir / "parity-evidence"
        fixture = parity_fixture_module.ParityEvidenceFixture(
            parity_root,
            candidate=self.candidate,
            production_runtime=True,
        )
        packaged = [
            self._build_parity_package_fixture(
                fixture,
                fixture.capture_a,
                parity_root / "packaged-process-a",
                "process-a",
                1,
            ),
            self._build_parity_package_fixture(
                fixture,
                fixture.capture_b,
                parity_root / "packaged-process-b",
                "process-b",
                2,
            ),
        ]
        fixture.capture_a = packaged[0]["root"] / "capture"
        fixture.capture_b = packaged[1]["root"] / "capture"
        report = fixture.evaluate(allow_fixture_runtime=True)
        report["releaseEligible"] = True
        report["identities"]["packagedCandidateIdentity"] = copy.deepcopy(
            self.packaged_candidate_identity
        )
        report["identities"]["evidenceRequestSHA256"] = [
            item["requestSHA256"] for item in packaged
        ]
        report["identities"]["packagedCaptureTreeSHA256"] = [
            item["captureTree"]["sha256"] for item in packaged
        ]
        report["exactPackagedCandidatePass"] = True
        report["byteParityGatePass"] = True
        report_path = parity_root / "cpu-metal-parity-report.json"
        parity_fixture_module.parity.write_json(report_path, report)
        manifest_path = parity_root / "artifact-manifest.json"
        parity_fixture_module.parity.write_json(
            manifest_path,
            parity_fixture_module.parity.make_root_manifest(
                parity_root, manifest_path
            ),
        )
        runtime_path = role_dir / "runtime-manifest.json"
        release_path = role_dir / "Release.xcconfig"
        runtime_path.write_bytes(self.runtime_bytes)
        release_path.write_bytes(self.release_bytes)
        self.parity_fixture = fixture
        self._seal_and_add(
            "cpu_metal_parity",
            report,
            fixture.contract_path,
            runtime_path,
            release_path,
            [
                (
                    "/identities/captureSourceSHA256",
                    fixture.capture_source,
                ),
                ("/identities/evaluatorSHA256", fixture.evaluator),
                ("/identities/runnerSHA256", fixture.runner),
                (
                    "/identities/evidenceRequestSHA256/0",
                    packaged[0]["request"],
                ),
                (
                    "/identities/evidenceRequestSHA256/1",
                    packaged[1]["request"],
                ),
                (
                    "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
                    packaged[0]["applicationArchive"],
                ),
                (
                    "/identities/packagedCandidateIdentity/attestationSHA256",
                    packaged[0]["attestation"],
                ),
            ],
            existing_report_path=report_path,
        )

    def _build_common_reports(self) -> None:
        for role in self.contract["requiredEvidenceRoles"]:
            if role == "quality":
                continue
            if role == "same_scope_performance":
                self._build_performance_actual()
                continue
            if role == "support_matrix":
                self._build_support_actual()
                continue
            role_dir = self.root / role
            if role == "cpu_metal_parity":
                self._build_parity_actual(role_dir)
                continue
            if role == "media_preservation":
                suite_contract = {"schemaVersion": qualification.SCHEMA_CONTRACT}
            elif role == "recovery":
                suite_contract = json.loads(
                    (SCRIPT_DIRECTORY / "recovery-qualification-contract-v1.json").read_text()
                )
            elif role == "notarized_smoke":
                suite_contract = self.contract
            elif role == "p06_reproduction":
                role_dir.mkdir(parents=True, exist_ok=True)
                source_contract = {
                    "schemaVersion": "mirmir-ash-v4-p06-source-provenance-contract-v1",
                    "identityDomain": "ash-p06-production-source-v1",
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
                p06_tool_bytes = {
                    "captureSourceSHA256": ("capture-tool.py", b"capture\n"),
                    "evaluatorSHA256": ("evaluator.py", b"evaluator\n"),
                    "runnerSHA256": ("runner.sh", b"runner\n"),
                    "runtimeLoadCheckRunnerSHA256": (
                        "runtime-load-check-runner.sh",
                        b"load runner\n",
                    ),
                    "runtimeLoadCheckSourceSHA256": (
                        "runtime-load-check.swift",
                        b"load source\n",
                    ),
                    "sourceIdentityToolSHA256": (
                        "source-identity-tool.py",
                        b"source identity\n",
                    ),
                    "sourceProvenanceContractSHA256": (
                        "source-provenance-contract.json",
                        qualification.canonical_bytes(source_contract),
                    ),
                }
                p06_capture: dict[str, str] = {}
                for key, (relative, contents) in p06_tool_bytes.items():
                    path = role_dir / relative
                    path.write_bytes(contents)
                    p06_capture[key] = qualification.sha256(path)
                suite_contract = {
                    "schemaVersion": "mirmir-ash-v4-p06-reproduction-contract-v1",
                    "suiteID": "mirmir-ash-v4-p06-reproduction-v1",
                    "buildConfiguration": "Release",
                    "sourceCheckoutState": "clean",
                    "cleanBuildCount": 2,
                    "cleanBuildIDs": ["clean-build-a", "clean-build-b"],
                    "productionSourceCount": 1,
                    "requiredRuntimeArtifactRoles": self.contract[
                        "p06RuntimeArtifactRoles"
                    ],
                    "runtimeID": "ash-p06-deterministic-v4",
                    "runtimeReleaseStatus": "release_qualified",
                    "canonicalManifestIdentityDomain": "ash-p06-runtime-manifest-v4",
                    "developmentArtifactDependencyCount": 0,
                    "p05ProductionDependencyCount": 0,
                    "capture": p06_capture,
                    "verification": {
                        "byteIdenticalToShippingBundle": True,
                        "productionLoaderAcceptanceRequired": True,
                        "sameLengthArtifactTamperRejectionRequired": True,
                        "sealedClosureRequired": True,
                        "toolchainProvenanceEqualityRequired": True,
                    },
                }
            else:
                suite_contract = {
                    "schemaVersion": f"mirmir-{role}-contract-v1",
                    "coverageLocked": True,
                }
            contract_path, runtime_path, release_path = self._write_bound_files(role_dir, role, suite_contract)
            if role == "recovery":
                contract_path.write_bytes(
                    (
                        SCRIPT_DIRECTORY
                        / "recovery-qualification-contract-v1.json"
                    ).read_bytes()
                )
            contract_sha = qualification.sha256(contract_path)
            report = self._base(role, contract_sha)
            extra_bindings: list[tuple[str, Path]] = []
            if role == "same_scope_performance":
                environment_path = role_dir / "environment.json"
                scope_path = role_dir / "scope.json"
                write_json(environment_path, {"machine": "locked", "software": "locked"})
                write_json(scope_path, {"inputs": "locked", "work": "same"})
                environment_sha = qualification.sha256(environment_path)
                scope_sha = qualification.sha256(scope_path)
                extra_bindings.extend(
                    [
                        ("/measurement/baselineEnvironmentSHA256", environment_path),
                        ("/measurement/candidateEnvironmentSHA256", environment_path),
                        ("/measurement/baselineScopeSHA256", scope_path),
                        ("/measurement/candidateScopeSHA256", scope_path),
                    ]
                )
                baseline = [100.0] * 10
                observed = [70.0] * 10
                intervals = {}
                for offset, metric in enumerate(self.contract["performance"]["requiredMetrics"]):
                    statistic = qualification.percentile95 if metric == "engineP95" else __import__("statistics").median
                    point, lower, upper = qualification.paired_ratio_interval(
                        baseline, observed, statistic, 7 + offset, 10000
                    )
                    intervals[metric] = {
                        "pointRatio": point,
                        "lower": lower,
                        "upper": upper,
                        "replicateCount": 10000,
                    }
                report.update(
                    {
                        "measurement": {
                            "buildConfiguration": "Release",
                            "warmupCount": 5,
                            "measuredRunCount": 10,
                            "bootstrapReplicateCount": 10000,
                            "bootstrapSeed": 7,
                            "thermalEnvelopeAccepted": True,
                            "loggingExcludedFromTimedLoops": True,
                            "diagnosticSerializationExcludedFromTimedLoops": True,
                            "baselineEnvironmentSHA256": environment_sha,
                            "candidateEnvironmentSHA256": environment_sha,
                            "baselineScopeSHA256": scope_sha,
                            "candidateScopeSHA256": scope_sha,
                            "sameHardware": True,
                            "sameSoftwareImage": True,
                            "identicalInputs": True,
                            "identicalTargets": True,
                            "identicalCodecSettings": True,
                            "identicalTrackSet": True,
                            "identicalPrecision": True,
                            "identicalTemporalWork": True,
                            "identicalVerification": True,
                            "identicalOutputQuality": True,
                        },
                        "mandatoryClassIDs": ["locked-common-sdr"],
                        "mandatoryClasses": [
                            {
                                "id": "locked-common-sdr",
                                "scopeSHA256": scope_sha,
                                "baseline": {metric: 100.0 for metric in self.contract["performance"]["requiredMetrics"]},
                                "candidate": {metric: 70.0 for metric in self.contract["performance"]["requiredMetrics"]},
                                "ratios": {metric: 0.7 for metric in self.contract["performance"]["requiredMetrics"]},
                            }
                        ],
                        "rawPairedSamplesMilliseconds": {
                            metric: {"baseline": baseline, "candidate": observed}
                            for metric in self.contract["performance"]["requiredMetrics"]
                        },
                        "aggregateRatio95PercentCI": intervals,
                        "memory": {
                            "baselinePeakBytes": 1000,
                            "candidatePeakBytes": 1100,
                            "approvedTemporalHistoryBudgetBytes": 100,
                        },
                        "releasePerformanceGatePass": True,
                    }
                )
            elif role == "media_preservation":
                self._build_media_preservation(
                    role_dir, report, contract_sha, extra_bindings
                )
            elif role == "recovery":
                assert isinstance(suite_contract, dict)
                self._build_recovery_v2(
                    role_dir,
                    report,
                    suite_contract,
                    contract_sha,
                    extra_bindings,
                )
            elif role == "p06_reproduction":
                assert isinstance(suite_contract, dict)
                source_contract = json.loads(
                    (role_dir / "source-provenance-contract.json").read_text()
                )
                source_bytes = b"normalized deployment trust source\n"
                builds = []
                for build_id in suite_contract["cleanBuildIDs"]:
                    build_dir = role_dir / build_id
                    build_dir.mkdir(parents=True, exist_ok=True)
                    build_runtime = build_dir / "runtime-manifest.json"
                    builder = build_dir / "builder.sh"
                    toolchain = build_dir / "toolchain-image.json"
                    build_runtime.write_bytes(self.runtime_bytes)
                    runtime_artifact_paths = []
                    for relative, content in self.runtime_artifacts.items():
                        artifact_path = build_dir / relative
                        artifact_path.parent.mkdir(parents=True, exist_ok=True)
                        artifact_path.write_bytes(content)
                        runtime_artifact_paths.append(artifact_path)
                    builder.write_bytes(self.builder_bytes)
                    toolchain.write_bytes(self.toolchain_bytes)
                    production_source = build_dir / "production-source-manifest.json"
                    production_source.write_bytes(
                        qualification.canonical_bytes(
                            {
                                "schemaVersion": "mirmir-ash-v4-p06-production-source-manifest-v1",
                                "contractSemanticSHA256": qualification.sha256_bytes(
                                    qualification.canonical_bytes(source_contract)
                                ),
                                "identityDomain": "ash-p06-production-source-v1",
                                "sourceCount": 1,
                                "sourceRevision": self.candidate[
                                    "runtimeSourceRevision"
                                ],
                                "sources": [
                                    {
                                        "path": "Sources/TrustV4.swift",
                                        "byteCount": len(source_bytes),
                                        "sha256": qualification.sha256_bytes(
                                            source_bytes
                                        ),
                                        "normalizedByteCount": len(source_bytes),
                                        "normalizedSHA256": qualification.sha256_bytes(
                                            source_bytes
                                        ),
                                        "normalizations": [
                                            "builderSourceSHA256",
                                            "manifestSHA256",
                                            "sourceRevision",
                                        ],
                                    }
                                ],
                            }
                        )
                    )
                    loader = build_dir / "runtime-load-and-tamper-check.log"
                    loader.write_text(
                        "\n".join(
                            (
                                "runtime_id=ash-p06-deterministic-v4",
                                "manifest_sha256="
                                + self.candidate["runtimeManifestSHA256"],
                                "source_revision="
                                + self.candidate["runtimeSourceRevision"],
                                "builder_source_sha256="
                                + qualification.sha256(builder),
                                "artifact_count="
                                + str(len(self.contract["p06RuntimeArtifactRoles"])),
                                "production_loader_acceptance=pass",
                                "same_length_artifact_tamper_rejection=pass",
                            )
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                    artifact_manifest = build_dir / "artifact-manifest.json"
                    write_json(
                        artifact_manifest,
                        {
                            "schemaVersion": "mirmir-p06-artifact-manifest-v1",
                            "artifacts": [
                                *[
                                    descriptor(path, build_dir)
                                    for path in sorted(runtime_artifact_paths)
                                ],
                                descriptor(build_runtime, build_dir),
                            ],
                        },
                    )
                    builds.append(
                        {
                            "id": build_id,
                            "runtimeArtifactSetSHA256": self.candidate["runtimeArtifactSetSHA256"],
                            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                            "builderSHA256": qualification.sha256(builder),
                            "productionSourceRevision": self.candidate[
                                "runtimeSourceRevision"
                            ],
                            "productionSourceManifestSHA256": qualification.sha256(
                                production_source
                            ),
                            "toolchainImageSHA256": qualification.sha256(toolchain),
                            "artifactManifest": descriptor(artifact_manifest, self.root),
                            "runtimeManifestArtifact": descriptor(build_runtime, self.root),
                            "builderArtifact": descriptor(builder, self.root),
                            "productionSourceArtifact": descriptor(
                                production_source, self.root
                            ),
                            "toolchainImageArtifact": descriptor(toolchain, self.root),
                            "loaderEvidenceArtifact": descriptor(loader, self.root),
                            "releaseQualifiedStatus": True,
                            "developmentArtifactDependencyCount": 0,
                            "p05ProductionDependencyCount": 0,
                        }
                    )
                report.update(
                    {
                        "identities": suite_contract["capture"],
                        "buildConfiguration": "Release",
                        "sourceCheckoutState": "clean",
                        "builds": builds,
                        "productionLoaderAcceptancePass": True,
                        "tamperRejectionPass": True,
                        "p06ReproductionGatePass": True,
                    }
                )
                for identity_name, relative in {
                    "captureSourceSHA256": "capture-tool.py",
                    "evaluatorSHA256": "evaluator.py",
                    "runnerSHA256": "runner.sh",
                    "runtimeLoadCheckRunnerSHA256": "runtime-load-check-runner.sh",
                    "runtimeLoadCheckSourceSHA256": "runtime-load-check.swift",
                    "sourceIdentityToolSHA256": "source-identity-tool.py",
                    "sourceProvenanceContractSHA256": "source-provenance-contract.json",
                }.items():
                    extra_bindings.append(
                        (f"/identities/{identity_name}", role_dir / relative)
                    )
            elif role == "support_matrix":
                app_archive = role_dir / "Mirmir-notarized.zip"
                app_archive.write_bytes(self.app_bytes)
                extra_bindings.append(("/candidate/appBundleSHA256", app_archive))
                support_evidence = {}
                for machine_class in ("reference", "supported"):
                    path = role_dir / f"{machine_class}-matrix.json"
                    write_json(path, {"machineClass": machine_class, "fullMatrixPass": True})
                    support_evidence[machine_class] = path
                report.update(
                    {
                        "declaredSupportedMachineClassIDs": ["reference", "supported"],
                        "rows": [
                            {
                                "id": f"{machine_class}-row",
                                "machineClass": machine_class,
                                "hardwareIdentitySHA256": identity(f"hardware-{machine_class}"),
                                "softwareImageSHA256": identity("supported-software"),
                                "appBundleSHA256": self.candidate["appBundleSHA256"],
                                "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
                                "fullQualificationMatrixPass": True,
                                "unexpectedSkipCount": 0,
                                "externalEvidenceArtifact": descriptor(
                                    support_evidence[machine_class], self.root
                                ),
                            }
                            for machine_class in ("reference", "supported")
                        ],
                        "supportMatrixGatePass": True,
                    }
                )
            elif role == "notarized_smoke":
                self._build_notarized_smoke(
                    role_dir,
                    report,
                    contract_path,
                    extra_bindings,
                )
            else:
                raise AssertionError(role)
            self._seal_and_add(
                role,
                report,
                contract_path,
                runtime_path,
                None if role == "recovery" else release_path,
                extra_bindings,
            )

    def entry(self, role: str) -> dict[str, object]:
        return next(entry for entry in self.index["evidence"] if entry["role"] == role)

    def mutate_report(self, role: str, mutation) -> None:
        entry = self.entry(role)
        report_path = self.root / entry["path"]
        report = json.loads(report_path.read_text())
        mutation(report)
        if role == "same_scope_performance" and "reportSHA256" in report:
            unsigned = dict(report)
            del unsigned["reportSHA256"]
            report["reportSHA256"] = qualification.sha256_bytes(
                qualification.canonical_bytes(unsigned) + b"\n"
            )
        write_json(report_path, report)
        if role == "quality":
            self.reseal_quality_evidence()
            return
        entry["byteCount"] = report_path.stat().st_size
        entry["sha256"] = qualification.sha256(report_path)
        sealed_descriptor = entry["sealedManifest"]
        sealed_path = self.root / sealed_descriptor["path"]
        sealed = json.loads(sealed_path.read_text())
        report_relative = report_path.relative_to(sealed_path.parent).as_posix()
        artifact = next(item for item in sealed["artifacts"] if item["path"] == report_relative)
        artifact.update(descriptor(report_path, sealed_path.parent))
        if role == "recovery":
            sealed["artifactSetSHA256"] = qualification.recovery_artifact_set_sha(
                sealed["artifacts"]
            )
        write_json(sealed_path, sealed)
        sealed_descriptor.update(descriptor(sealed_path, self.root))
        self.save_index()

    def refresh_notarized_smoke_nested_bindings(self) -> None:
        role = "notarized_smoke"
        role_dir = self.root / role
        raw_capture_path = role_dir / "raw" / "capture.json"
        receipt_path = role_dir / "replay-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["captureSHA256"] = qualification.sha256(raw_capture_path)
        write_json(receipt_path, receipt)

        report_path = role_dir / "report.json"
        report = json.loads(report_path.read_text())
        report["identities"]["rawCaptureSHA256"] = qualification.sha256(
            raw_capture_path
        )
        report["identities"]["replayReceiptSHA256"] = qualification.sha256(
            receipt_path
        )
        report["capture"]["rawCaptureArtifact"] = descriptor(
            raw_capture_path, role_dir
        )
        report["capture"]["replayReceiptArtifact"] = descriptor(
            receipt_path, role_dir
        )
        write_json(report_path, report)

        entry = self.entry(role)
        for pointer, path in (
            ("/identities/rawCaptureSHA256", raw_capture_path),
            ("/identities/replayReceiptSHA256", receipt_path),
        ):
            binding = next(
                item
                for item in entry["identityBindings"]
                if item["jsonPointer"] == pointer
            )
            binding.update(descriptor(path, self.root))
        self.reseal_role(role)

    def refresh_recovery_evidence(self) -> None:
        role_dir = self.root / "recovery"
        for process_root in (
            self.recovery_fixture.first_root,
            self.recovery_fixture.second_root,
        ):
            self.recovery_fixture.reseal(process_root)
        artifacts = []
        for process_name, process_root in (
            ("process-a", self.recovery_fixture.first_root),
            ("process-b", self.recovery_fixture.second_root),
        ):
            capture_root = process_root / "capture"
            for path in sorted(
                capture_root.rglob("*"),
                key=lambda value: value.relative_to(capture_root).as_posix(),
            ):
                if path.is_file():
                    item = descriptor(path, capture_root)
                    item["path"] = (
                        f"captures/{process_name}/capture/{item['path']}"
                    )
                    artifacts.append(item)
        artifacts.sort(key=lambda item: item["path"])
        capture_manifest = {
            "schemaVersion": qualification.RECOVERY_CAPTURE_MANIFEST_SCHEMA,
            "artifacts": artifacts,
            "artifactSetSHA256": qualification.recovery_artifact_set_sha(
                artifacts
            ),
        }
        write_json(self.recovery_capture_manifest_path, capture_manifest)
        report_path = role_dir / "report.json"
        report = json.loads(report_path.read_text())
        report["captureManifestSHA256"] = qualification.sha256(
            self.recovery_capture_manifest_path
        )
        write_json(report_path, report)
        entry = self.entry("recovery")
        binding = next(
            item
            for item in entry["identityBindings"]
            if item["jsonPointer"] == "/captureManifestSHA256"
        )
        binding.update(descriptor(self.recovery_capture_manifest_path, self.root))
        self.reseal_role("recovery")
        return

    def reseal_role(self, role: str) -> None:
        entry = self.entry(role)
        role_dir = self.root / role
        report_path = self.root / entry["path"]
        entry.update({key: value for key, value in descriptor(report_path, self.root).items()})
        sealed_path = self.root / entry["sealedManifest"]["path"]
        sealed_artifacts = [
            descriptor(path, role_dir)
            for path in sorted(role_dir.rglob("*"))
            if path.is_file() and path != sealed_path
        ]
        sealed = {
            "schemaVersion": (
                qualification.RECOVERY_SUITE_MANIFEST_SCHEMA
                if role == "recovery"
                else (
                    support_fixture_module.support.EVIDENCE_SCHEMA
                    if role == "support_matrix"
                    else "mirmir-test-sealed-evidence-v1"
                )
            ),
            "artifacts": sealed_artifacts,
        }
        if role == "recovery":
            sealed["artifactSetSHA256"] = qualification.recovery_artifact_set_sha(
                sealed_artifacts
            )
        write_json(sealed_path, sealed)
        entry["sealedManifest"].update(descriptor(sealed_path, self.root))
        self.save_index()

    def reseal_parity_evidence(self) -> None:
        parity_root = self.parity_fixture.root
        manifest_path = parity_root / "artifact-manifest.json"
        parity_fixture_module.parity.write_json(
            manifest_path,
            parity_fixture_module.parity.make_root_manifest(
                parity_root, manifest_path
            ),
        )
        self.reseal_role("cpu_metal_parity")

    def reseal_parity_package(self, ordinal: int) -> None:
        parity_root = self.parity_fixture.root
        package_root = parity_root / f"packaged-process-{'ab'[ordinal]}"
        capture_root = package_root / "capture"
        capture_tree = qualification.packaged_capture_tree(capture_root)

        result_path = package_root / "observer/result.json"
        result = qualification.load_json(result_path)
        result["captureTree"] = capture_tree
        capture_path = capture_root / "capture.json"
        result["captureManifest"] = {
            "fileName": "capture.json",
            "byteCount": capture_path.stat().st_size,
            "sha256": qualification.sha256(capture_path),
        }
        result_path.write_bytes(qualification.canonical_bytes(result))

        record_path = package_root / "capture-record.json"
        record = qualification.load_json(record_path)
        record["captureTree"] = capture_tree
        record["artifacts"]["result"] = descriptor(result_path, package_root)
        record_path.write_bytes(qualification.canonical_bytes(record))

        report_path = parity_root / "cpu-metal-parity-report.json"
        report = qualification.load_json(report_path)
        report["identities"]["packagedCaptureTreeSHA256"][ordinal] = capture_tree[
            "sha256"
        ]
        parity_fixture_module.parity.write_json(report_path, report)
        self.reseal_parity_evidence()

    def reseal_quality_evidence(self) -> None:
        self._write_quality_evidence_manifest()
        self.reseal_role("quality")


class ReleaseQualificationV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="mirmir-release-qualification-")
        self.root = Path(self.temporary.name)
        self.fixture = EvidenceFixture(self.root)
        self.trust_temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-release-trust-"
        )
        self.trust_root_path, self.trust_root_sha256 = self.make_trust_root(
            self.fixture.contract_path,
            "release-trust-root.json",
        )

    def tearDown(self) -> None:
        self.trust_temporary.cleanup()
        self.temporary.cleanup()

    def make_trust_root(
        self,
        contract_path: Path,
        name: str,
    ) -> tuple[Path, str]:
        path = Path(self.trust_temporary.name) / name
        trust_builder.write_json(
            path,
            trust_builder.build_trust_root(SCRIPT_DIRECTORY, contract_path),
        )
        return path, trust_builder.sha256(path)

    def evaluate(self) -> dict[str, object]:
        return qualification.evaluate_candidate(
            self.fixture.index_path,
            self.root,
            self.fixture.contract_path,
            trust_root_path=self.trust_root_path,
            expected_trust_root_sha256=self.trust_root_sha256,
        )

    def evaluate_recovery(self) -> dict[str, object]:
        evidence_root = self.root.resolve()
        entry = self.fixture.entry("recovery")
        report_path, _ = qualification.validate_artifact(
            evidence_root,
            entry,
            "recovery",
            allowed_extra_keys={
                "role",
                "contractSHA256",
                "sealedManifest",
                "identityBindings",
            },
        )
        report = qualification.require_mapping(
            qualification.load_json(report_path), "recovery report"
        )
        _, sealed_paths = qualification.validate_sealed_manifest(
            evidence_root,
            entry["sealedManifest"],
            report_path,
            "recovery sealed manifest",
        )
        qualification.validate_bindings(
            evidence_root,
            report,
            entry,
            set(self.fixture.contract["identityBindings"]["recovery"]),
            "recovery",
        )
        return qualification.validate_recovery(
            report,
            self.fixture.candidate,
            self.fixture.contract,
            entry["contractSHA256"],
            entry,
            evidence_root,
            sealed_paths,
        )

    def evaluate_role(self, role: str) -> dict[str, object]:
        evidence_root = self.root.resolve()
        entry = self.fixture.entry(role)
        report_path, _ = qualification.validate_artifact(
            evidence_root,
            entry,
            role,
            allowed_extra_keys={
                "role",
                "contractSHA256",
                "sealedManifest",
                "identityBindings",
            },
        )
        report = qualification.require_mapping(
            qualification.load_json(report_path), f"{role} report"
        )
        _, sealed_paths = qualification.validate_sealed_manifest(
            evidence_root,
            entry["sealedManifest"],
            report_path,
            f"{role} sealed manifest",
        )
        qualification.validate_bindings(
            evidence_root,
            report,
            entry,
            set(self.fixture.contract["identityBindings"].get(
                role,
                self.fixture.contract["identityBindings"]["common"],
            )),
            role,
        )
        return qualification.VALIDATORS[role](
            report,
            self.fixture.candidate,
            self.fixture.contract,
            entry["contractSHA256"],
            entry,
            evidence_root,
            sealed_paths,
        )

    def mutate_and_reseal_media_route(self, fixture_index: int, mutation) -> None:
        role_root = self.root / "media_preservation"
        capture_root = role_root / "raw-capture" / "capture"
        capture_path = capture_root / "capture.json"
        capture = json.loads(capture_path.read_text())
        route = capture["fixtures"][fixture_index]["production"][
            "routeReceipt"
        ]
        mutation(route)
        for value_key, hash_key in (
            ("independentPreflight", "independentPreflightSHA256"),
            (
                "repeatIndependentPreflight",
                "repeatIndependentPreflightSHA256",
            ),
            ("executionReceipt", "executionReceiptSHA256"),
            ("repeatExecutionReceipt", "repeatExecutionReceiptSHA256"),
        ):
            route[hash_key] = qualification.sha256_bytes(
                qualification.canonical_bytes(route[value_key])
            )
        proof = dict(route)
        proof.pop("routeProofSHA256", None)
        route["routeProofSHA256"] = qualification.sha256_bytes(
            qualification.canonical_bytes(proof)
        )
        write_json(capture_path, capture)
        capture_tree = qualification.packaged_capture_tree(capture_root)
        result_path = role_root / "raw-capture" / "observer" / "result.json"
        result = json.loads(result_path.read_text())
        result["captureTree"] = capture_tree
        result["captureManifest"].update({
            "byteCount": capture_path.stat().st_size,
            "sha256": qualification.sha256(capture_path),
        })
        write_json(result_path, result)
        record_path = role_root / "raw-capture" / "capture-record.json"
        record = json.loads(record_path.read_text())
        record["captureTree"] = capture_tree
        write_json(record_path, record)

        def refresh_report(report: dict[str, object]) -> None:
            report["identities"]["captureSHA256"] = qualification.sha256(
                capture_path
            )
            report["identities"][
                "packagedEvidenceCaptureTree"
            ] = capture_tree
            report["fixtures"][fixture_index][
                "productionRouteProofSHA256"
            ] = route["routeProofSHA256"]

        self.fixture.mutate_report("media_preservation", refresh_report)
        entry = self.fixture.entry("media_preservation")
        binding = next(
            item for item in entry["identityBindings"]
            if item["jsonPointer"] == "/identities/captureSHA256"
        )
        binding.update(descriptor(capture_path, self.root))
        self.fixture.reseal_role("media_preservation")

    def testCompleteCandidateEvaluatesAndVerifiesDeterministically(self) -> None:
        first = self.evaluate()
        second = self.evaluate()
        self.assertEqual(first, second)
        self.assertTrue(first["releaseQualified"])
        self.assertTrue(all(first["gates"].values()))
        report_path = self.root / "qualification-report.json"
        write_json(report_path, first)
        self.assertEqual(
            first,
            qualification.verify_report(
                report_path,
                self.fixture.index_path,
                self.root,
                self.fixture.contract_path,
                trust_root_path=self.trust_root_path,
                expected_trust_root_sha256=self.trust_root_sha256,
            ),
        )

    def testExternalTrustRootFailsClosedBeforeReplayHelperExecution(self) -> None:
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "external trust-root SHA-256 mismatch",
        ):
            qualification.evaluate_candidate(
                self.fixture.index_path,
                self.root,
                self.fixture.contract_path,
                trust_root_path=self.trust_root_path,
                expected_trust_root_sha256="0" * 64,
            )

        original = json.loads(self.trust_root_path.read_text())
        mutations = {
            "evaluator": lambda root: root["evaluator"].__setitem__(
                "sha256", "1" * 64
            ),
            "helper": lambda root: root["helpers"][0].__setitem__(
                "sha256", "2" * 64
            ),
            "dispatch": lambda root: root["roleDispatch"][0].__setitem__(
                "validator", "accept_everything"
            ),
            "tool-set": lambda root: root.__setitem__(
                "trustedToolSetSHA256", "3" * 64
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                root = copy.deepcopy(original)
                mutate(root)
                path = Path(self.trust_temporary.name) / f"forged-{name}.json"
                trust_builder.write_json(path, root)
                with self.assertRaises(qualification.QualificationError):
                    qualification.evaluate_candidate(
                        self.fixture.index_path,
                        self.root,
                        self.fixture.contract_path,
                        trust_root_path=path,
                        expected_trust_root_sha256=trust_builder.sha256(path),
                    )

    def testP06NestedLoaderToolchainAndSourceTamperAreRecomputed(self) -> None:
        for mutation in ("loader", "toolchain", "source"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(
                prefix=f"mirmir-p06-{mutation}-"
            ) as temporary:
                root = Path(temporary)
                fixture = EvidenceFixture(root)
                report_path = root / "p06_reproduction/report.json"
                report = json.loads(report_path.read_text())
                build = report["builds"][0]
                if mutation == "loader":
                    path = root / build["loaderEvidenceArtifact"]["path"]
                    path.write_text(
                        path.read_text().replace(
                            "same_length_artifact_tamper_rejection=pass",
                            "same_length_artifact_tamper_rejection=fail",
                        ),
                        encoding="utf-8",
                    )
                    build["loaderEvidenceArtifact"] = descriptor(path, root)
                elif mutation == "toolchain":
                    path = root / build["toolchainImageArtifact"]["path"]
                    path.write_bytes(
                        qualification.canonical_bytes(
                            {"sdk": "resealed-but-not-runtime-provenance"}
                        )
                    )
                    build["toolchainImageSHA256"] = qualification.sha256(path)
                    build["toolchainImageArtifact"] = descriptor(path, root)
                else:
                    path = root / build["productionSourceArtifact"]["path"]
                    document = json.loads(path.read_text())
                    document["sourceRevision"] = "f" * 64
                    path.write_bytes(qualification.canonical_bytes(document))
                    build["productionSourceRevision"] = "f" * 64
                    build["productionSourceManifestSHA256"] = qualification.sha256(
                        path
                    )
                    build["productionSourceArtifact"] = descriptor(path, root)
                write_json(report_path, report)
                fixture.reseal_role("p06_reproduction")
                with self.assertRaisesRegex(
                    qualification.QualificationError,
                    "loader/tamper|toolchain artifact differs|source revision/count",
                ):
                    qualification.evaluate_candidate(
                        fixture.index_path,
                        root,
                        fixture.contract_path,
                        trust_root_path=self.trust_root_path,
                        expected_trust_root_sha256=self.trust_root_sha256,
                    )

    def testPublishedJSONSchemaAcceptsBindingAndRejectsExtraProperty(self) -> None:
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        schema = json.loads(
            (SCRIPT_DIRECTORY / "release-qualification-evidence-schema-v1.json").read_text()
        )
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.validate(self.fixture.index, schema)
        binding = self.fixture.index["evidence"][0]["identityBindings"][0]
        binding["unexpected"] = True
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(self.fixture.index, schema)

    def testMissingRoleAndWaiverFailClosed(self) -> None:
        self.fixture.index["evidence"].pop()
        self.fixture.save_index()
        with self.assertRaisesRegex(qualification.QualificationError, "role mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "second")
        self.root = self.root / "second"
        self.fixture.index["waivers"] = [{"role": "quality"}]
        self.fixture.save_index()
        with self.assertRaisesRegex(qualification.QualificationError, "does not admit waivers"):
            self.evaluate()

    def testArtifactTamperAndStaleCandidateFailClosed(self) -> None:
        entry = self.fixture.entry("cpu_metal_parity")
        path = self.root / entry["path"]
        path.write_bytes(path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(qualification.QualificationError, "byte count mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "stale")
        self.root = self.root / "stale"
        self.fixture.mutate_report(
            "same_scope_performance",
            lambda report: report["candidate"].update({"sourceRevision": "c" * 40}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "source revision mismatch"):
            self.evaluate()

    def testQualityIneligibilityAndSemanticTamperFailClosed(self) -> None:
        self.fixture.mutate_report(
            "quality", lambda report: report["corpus"].update({"releaseEligible": False})
        )
        with self.assertRaisesRegex(qualification.QualificationError, "releaseEligible"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "semantic")
        self.root = self.root / "semantic"
        self.fixture.mutate_report(
            "quality",
            lambda report: report["perClip"][0]["components"]["candidate_v4"].update(
                {"luma_multiscale_structural_error": 1.7}
            ),
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "perClip metrics differ from sealed raw-plane replay",
        ):
            self.evaluate()

    def testPerformanceScopeAndConfidenceGateFailClosed(self) -> None:
        self.fixture.mutate_report(
            "same_scope_performance",
            lambda report: report["environmentGate"].update(
                {"stableHardwareAndSoftwareImageMatch": False, "pass": False}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "environment gate"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "slow")
        self.root = self.root / "slow"
        def slow(report):
            report["metricGates"]["aggregateCorpusWall"]["ratio"] = 0.9
        self.fixture.mutate_report("same_scope_performance", slow)
        with self.assertRaisesRegex(qualification.QualificationError, "does not match recomputed"):
            self.evaluate()

    def testParityAndPreservationFailuresCannotBeClaimedAway(self) -> None:
        self.fixture.mutate_report(
            "cpu_metal_parity",
            lambda report: report["cases"][0]["metalVisibleArtifact"].update(
                {"sha256": identity("different-visible")}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "SHA-256 mismatch"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "identity")
        self.root = self.root / "identity"
        self.fixture.mutate_report(
            "cpu_metal_parity",
            lambda report: report["identities"].update(
                {"captureSourceSHA256": identity("different-capture-source")}
            ),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "binding does not match report"):
            self.evaluate()
        loss_root = self.root.parent / "loss"
        self.fixture = EvidenceFixture(loss_root)
        self.root = loss_root
        self.fixture.mutate_report(
            "media_preservation",
            lambda report: report["fixtures"][0].update({"unconsentedDropCount": 1}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "unconsentedDropCount"):
            self.evaluate()

    def testParityV2ScheduleTamperIsCaughtByIndependentNestedReplay(self) -> None:
        definition = self.fixture.parity_fixture.contract["cases"][0]
        case_id = definition["id"]
        relative = self.fixture.parity_fixture.artifact_relative(
            case_id,
            "cpu",
            "schedule-reverse",
            "visible",
        )
        self.fixture.parity_fixture.replace_and_rebind(
            self.fixture.parity_fixture.capture_a,
            {relative: b"resealed-schedule-dependent-output"},
        )
        self.fixture.reseal_parity_package(0)
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "nested parity replay failed:.*schedule reverse.*visible",
        ):
            self.evaluate()

    def testParityV2CoverageCannotBeWeakenedInReportOrReleaseContract(self) -> None:
        self.fixture.mutate_report(
            "cpu_metal_parity",
            lambda report: report["coverage"].pop(),
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "report coverage is incomplete",
        ):
            self.evaluate()

        second_root = self.root / "weakened-contract"
        self.fixture = EvidenceFixture(second_root)
        self.root = second_root
        weakened = copy.deepcopy(self.fixture.contract)
        weakened["parityCoverage"].pop()
        weakened_path = self.root / "weakened-release-contract.json"
        write_json(weakened_path, weakened)
        weakened_trust_path, weakened_trust_sha256 = self.make_trust_root(
            weakened_path,
            "weakened-release-trust-root.json",
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "release contract parity coverage is weakened",
        ):
            qualification.evaluate_candidate(
                self.fixture.index_path,
                self.root,
                weakened_path,
                trust_root_path=weakened_trust_path,
                expected_trust_root_sha256=weakened_trust_sha256,
            )

    def testPreservationNestedVerifierIsIndependentlyRecomputed(self) -> None:
        verifier_path = (
            self.root
            / "media_preservation"
            / "fixtures"
            / "combined-p010-hdr-interlaced"
            / "semantic-verifier.json"
        )
        verifier = json.loads(verifier_path.read_text())
        verifier["checks"][0]["id"] = "forged-semantic-check"
        write_json(verifier_path, verifier)
        self.fixture.mutate_report(
            "media_preservation",
            lambda report: report["fixtures"][0]["semanticVerifierArtifact"].update(
                descriptor(verifier_path, self.root)
            ),
        )
        self.fixture.reseal_role("media_preservation")
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "checks differ from independent recomputation",
        ):
            self.evaluate()

    def testPreservationRehashedProductionRouteForgeryFailsClosed(self) -> None:
        def mutate(route: dict[str, object]) -> None:
            route["executionReceipt"]["actualBackendID"] = (
                "mirmirDeterministicMetal"
            )
            route["repeatExecutionReceipt"]["actualBackendID"] = (
                "mirmirDeterministicMetal"
            )

        self.mutate_and_reseal_media_route(3, mutate)
        with self.assertRaisesRegex(
            qualification.QualificationError, "backend route differs"
        ):
            self.evaluate()

    def testPreservationRehashedNearMatchBackendTypeFailsClosed(self) -> None:
        def mutate(route: dict[str, object]) -> None:
            backend = "Mirmir.FakePreparedDeterministicV4Upscaler"
            for key in (
                "independentPreflight",
                "repeatIndependentPreflight",
                "executionReceipt",
                "repeatExecutionReceipt",
            ):
                route[key]["preparedBackendType"] = backend

        self.mutate_and_reseal_media_route(3, mutate)
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "prepared backend does not match fixture",
        ):
            self.evaluate()

    def testRecoveryAndP06FailuresCannotBeWaived(self) -> None:
        self.fixture.mutate_report(
            "recovery",
            lambda report: report["execution"].update(
                {"applicationArchiveExecuted": False}
            ),
        )
        with self.assertRaisesRegex(
            qualification.QualificationError, "archived-executable"
        ):
            self.evaluate_recovery()
        self.fixture = EvidenceFixture(self.root / "p05")
        self.root = self.root / "p05"
        self.fixture.mutate_report(
            "p06_reproduction",
            lambda report: report["builds"][1].update({"p05ProductionDependencyCount": 1}),
        )
        with self.assertRaisesRegex(qualification.QualificationError, "P05 production dependency"):
            self.evaluate_role("p06_reproduction")

    def testRecoveryV2ExactArchivedExecutableEvidencePassesCentralEvaluator(
        self,
    ) -> None:
        summary = self.evaluate_recovery()
        self.assertEqual(summary["scenarioCount"], 15)
        self.assertEqual(summary["identicalResumptionCount"], 10)
        self.assertEqual(summary["containedFailureCount"], 5)
        self.assertEqual(
            summary["applicationArchiveSHA256"],
            self.fixture.candidate["appBundleSHA256"],
        )
        self.assertEqual(
            summary["applicationExecutableSHA256"],
            self.fixture.packaged_candidate_identity[
                "applicationExecutableSHA256"
            ],
        )

    def testRecoveryNestedTranscriptIsIndependentlyRecomputed(self) -> None:
        transcript_path = (
            self.root
            / "recovery"
            / "captures"
            / "process-a"
            / "capture"
            / "scenarios"
            / "append-only-event-boundary"
            / "transcript.json"
        )
        transcript = json.loads(transcript_path.read_text())
        transcript["events"][1]["operation"] = "claim_fault_without_injection"
        write_json(transcript_path, transcript)
        external_path, external = self.fixture.recovery_fixture.external(
            self.fixture.recovery_fixture.first_root,
            "append-only-event-boundary",
        )
        external["transcriptArtifact"] = recovery_fixture_module.gate.descriptor(
            transcript_path,
            self.fixture.recovery_fixture.first_root / "capture",
        )
        self.fixture.recovery_fixture.rewrite_external(
            self.fixture.recovery_fixture.first_root,
            "append-only-event-boundary",
            external,
        )
        self.fixture.refresh_recovery_evidence()
        with self.assertRaisesRegex(
            qualification.QualificationError, "fault/reopen operations"
        ):
            self.evaluate_recovery()

    def testRecoveryNestedSemanticAndArtifactSetClaimsFailClosed(self) -> None:
        scenario_root = (
            self.root
            / "recovery"
            / "captures"
            / "process-a"
            / "capture"
            / "scenarios"
            / "pause-resume"
        )
        for name in ("reference-semantic.json", "resumed-semantic.json"):
            path = scenario_root / name
            semantic = json.loads(path.read_text())
            semantic["allRequiredChecksPassed"] = False
            write_json(path, semantic)
        _, external = self.fixture.recovery_fixture.external(
            self.fixture.recovery_fixture.first_root,
            "pause-resume",
        )
        capture_root = self.fixture.recovery_fixture.first_root / "capture"
        external["referenceSemanticArtifact"] = (
            recovery_fixture_module.gate.descriptor(
                scenario_root / "reference-semantic.json", capture_root
            )
        )
        external["resumedSemanticArtifact"] = (
            recovery_fixture_module.gate.descriptor(
                scenario_root / "resumed-semantic.json", capture_root
            )
        )
        self.fixture.recovery_fixture.rewrite_external(
            self.fixture.recovery_fixture.first_root,
            "pause-resume",
            external,
        )
        self.fixture.refresh_recovery_evidence()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "allRequiredChecksPassed.*true",
        ):
            self.evaluate_recovery()

        replacement_root = self.root / "manifest-forgery"
        self.fixture = EvidenceFixture(replacement_root)
        self.root = replacement_root
        manifest_path = self.fixture.recovery_capture_manifest_path
        manifest = json.loads(manifest_path.read_text())
        manifest["artifactSetSHA256"] = identity("forged-recovery-artifact-set")
        write_json(manifest_path, manifest)
        report_path = self.root / "recovery" / "report.json"
        report = json.loads(report_path.read_text())
        report["captureManifestSHA256"] = qualification.sha256(
            manifest_path
        )
        write_json(report_path, report)
        entry = self.fixture.entry("recovery")
        binding = next(
            item
            for item in entry["identityBindings"]
            if item["jsonPointer"] == "/captureManifestSHA256"
        )
        binding.update(descriptor(manifest_path, self.root))
        self.fixture.reseal_role("recovery")
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "manifest differs from raw replay",
        ):
            self.evaluate_recovery()

    def testRecoveryRehashedProducerSubstitutionFailsCentralReplay(self) -> None:
        process_root = self.fixture.recovery_fixture.first_root
        producer_path = process_root / "bindings" / "producer-source.swift"
        producer_path.write_bytes(b"substituted recovery producer\n")
        record_path = process_root / "capture-record.json"
        record = recovery_fixture_module.gate.load_json(record_path)
        record["artifacts"]["producerSource"] = (
            recovery_fixture_module.gate.packaged_evidence.descriptor(
                producer_path,
                process_root,
            )
        )
        record_path.write_bytes(
            recovery_fixture_module.gate.packaged_evidence.canonical_bytes(
                record
            )
        )
        self.fixture.refresh_recovery_evidence()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "packaged artifact differs",
        ):
            self.evaluate_recovery()

    def testSupportMatrixAndNotarizedSmokeMustCoverExactCandidate(self) -> None:
        self.fixture.mutate_report(
            "support_matrix", lambda report: report["rows"].pop()
        )
        with self.assertRaisesRegex(
            qualification.QualificationError, "row count differs|does not cover"
        ):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "smoke")
        self.root = self.root / "smoke"
        self.fixture.mutate_report(
            "notarized_smoke", lambda report: report.update({"ticketStapled": False})
        )
        with self.assertRaisesRegex(qualification.QualificationError, "ticketStapled"):
            self.evaluate()
        self.fixture = EvidenceFixture(self.root / "placeholder")
        self.root = self.root / "placeholder"
        contract_artifact = descriptor(
            self.root / "notarized_smoke" / "suite-contract.json",
            self.root / "notarized_smoke",
        )
        self.fixture.mutate_report(
            "notarized_smoke",
            lambda report: report["actions"][0].update(
                {"externalEvidenceArtifact": contract_artifact}
            ),
        )
        with self.assertRaisesRegex(
            qualification.QualificationError, "attestation.*key set mismatch"
        ):
            self.evaluate()

    def testNotarizedSmokeNestedCaptureAndReplayAreRecomputed(self) -> None:
        raw_root = self.root / "raw-capture-forgery"
        self.fixture = EvidenceFixture(raw_root)
        self.root = raw_root
        raw_capture_path = (
            self.root / "notarized_smoke" / "raw" / "capture.json"
        )
        raw_capture = json.loads(raw_capture_path.read_text())
        raw_capture["candidate"]["bundleIdentifier"] = "forged.mirmir.app"
        write_json(raw_capture_path, raw_capture)
        self.fixture.refresh_notarized_smoke_nested_bindings()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "raw capture belongs to another candidate",
        ):
            self.evaluate()

        receipt_root = self.root / "replay-forgery"
        self.fixture = EvidenceFixture(receipt_root)
        self.root = receipt_root
        receipt_path = self.root / "notarized_smoke" / "replay-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["nestedEvidenceReplayPass"] = False
        write_json(receipt_path, receipt)
        self.fixture.refresh_notarized_smoke_nested_bindings()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "replay nestedEvidenceReplayPass",
        ):
            self.evaluate()

    def testQualificationReportTamperIsRejectedOnVerify(self) -> None:
        report = self.evaluate()
        report["releaseQualified"] = False
        path = self.root / "tampered-qualification-report.json"
        write_json(path, report)
        with self.assertRaisesRegex(qualification.QualificationError, "differs from recomputed"):
            qualification.verify_report(
                path,
                self.fixture.index_path,
                self.root,
                self.fixture.contract_path,
                trust_root_path=self.trust_root_path,
                expected_trust_root_sha256=self.trust_root_sha256,
            )


class CentralMediaRouteV2Tests(unittest.TestCase):
    """Direct central-route tests isolated from unrelated shared evidence pins."""

    def validate(self, fixture: object) -> str:
        observations = fixture.observations
        return qualification.validate_preservation_production_route(
            fixture.fixture_id,
            fixture.production,
            fixture.candidate,
            fixture.capture,
            fixture.runtime_provenance,
            {
                "tracks": observations["inputTracks"],
                "trackObservation": observations["inputTrackObservation"],
            },
            {
                "tracks": observations["outputTracks"],
                "trackObservation": observations["outputTrackObservation"],
                "pixels": observations["outputPixels"],
                "timing": observations["outputTiming"],
                "attachments": observations["outputAttachments"],
            },
        )

    @staticmethod
    def mutate_backend(fixture: object, backend: str) -> None:
        for key in ("independentPreflight", "repeatIndependentPreflight"):
            fixture.route[key]["preparedBackendType"] = backend
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["preparedBackendType"] = backend
        fixture.reseal()

    def testExactOpaqueFixtureRoutePasses(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture()
        self.assertEqual(self.validate(fixture), fixture.route["routeProofSHA256"])

    def testExactAlphaFixtureRoutePasses(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        self.assertEqual(self.validate(fixture), fixture.route["routeProofSHA256"])

    def testSyntheticSixFixtureEvidencePassesCentralEvaluator(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-central-media-v2-"
        ) as temporary:
            root = Path(temporary).resolve()
            with mock.patch.object(
                EvidenceFixture, "_build_parity_actual", return_value=None
            ), mock.patch.object(
                EvidenceFixture, "_build_recovery_v2", return_value=None
            ):
                fixture = EvidenceFixture(root)
            entry = fixture.entry("media_preservation")
            report = qualification.load_json(root / entry["path"])
            sealed_paths = {
                path.resolve()
                for path in (root / "media_preservation").rglob("*")
                if path.is_file()
            }
            summary = qualification.validate_preservation(
                report,
                fixture.candidate,
                fixture.contract,
                entry["contractSHA256"],
                entry,
                root,
                sealed_paths,
            )
            self.assertEqual(summary["fixtureCount"], 6)
            self.assertEqual(summary["accountedTrackCount"], 15)

    def testNearMatchPreparedBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture()
        self.mutate_backend(
            fixture, "Mirmir.FakePreparedDeterministicV4Upscaler"
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "prepared backend does not match fixture",
        ):
            self.validate(fixture)

    def testRealButWrongOpaqueBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture()
        self.mutate_backend(
            fixture, "Mirmir.PreparedDeterministicAlphaPlanningBackendV4"
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "prepared backend does not match fixture",
        ):
            self.validate(fixture)

    def testRealButWrongAlphaBackendFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        self.mutate_backend(fixture, "Mirmir.PreparedDeterministicV4Upscaler")
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "prepared backend does not match fixture",
        ):
            self.validate(fixture)

    def testMigratedStableIDForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture()
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["migratedTracks"][0]["stableID"] = "forged.track"
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "migrated stable-ID/action differs",
        ):
            self.validate(fixture)

    def testRepeatOnlyReceiptForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture()
        fixture.route["repeatExecutionReceipt"]["outputGraphSHA256"] = identity(
            "repeat-only-forgery"
        )
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "execution receipt is not repeatable",
        ):
            self.validate(fixture)

    def testAlphaAssociationForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["association"] = (
                "premultiplied"
            )
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError, "alpha header differs"
        ):
            self.validate(fixture)

    def testAlphaByteCountForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0][
                "alphaByteCount"
            ] += 1
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError, "alpha byte count differs"
        ):
            self.validate(fixture)

    def testAlphaOrdinalForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0]["ordinal"] = 1
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError, "alpha frame ordinal differs"
        ):
            self.validate(fixture)

    def testAlphaPresentationForgeryFailsAfterAllHashesAreRefreshed(self) -> None:
        fixture = media_fixture_module.MediaRouteFixture(
            "combined-alpha-geometry-straight"
        )
        for key in ("executionReceipt", "repeatExecutionReceipt"):
            fixture.route[key]["alphaVerification"]["frames"][0][
                "presentationTime"
            ] = {"numerator": 1, "denominator": 1}
        fixture.reseal()
        with self.assertRaisesRegex(
            qualification.QualificationError, "alpha presentation time differs"
        ):
            self.validate(fixture)


if __name__ == "__main__":
    unittest.main()
