#!/usr/bin/env python3
"""Tamper tests for the fail-closed v4 support-matrix replay."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "support_matrix_v4_for_tests", SCRIPT_DIRECTORY / "support_matrix_v4.py"
)
assert SPEC is not None and SPEC.loader is not None
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)


def write_json(path: Path, value: object) -> None:
    path.write_bytes(support.pretty_bytes(value))


class SupportEvidenceFixture:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True)
        shutil.copy2(
            SCRIPT_DIRECTORY / "support-matrix-contract-v1.json",
            root / "suite-contract.json",
        )
        shutil.copy2(
            SCRIPT_DIRECTORY / "capture_support_matrix_v4.py",
            root / "capture-tool.py",
        )
        shutil.copy2(
            SCRIPT_DIRECTORY / "support_matrix_v4.py",
            root / "support-matrix-evaluator.py",
        )
        shutil.copy2(
            SCRIPT_DIRECTORY / "run_support_matrix_v4.sh",
            root / "support-matrix-runner.sh",
        )
        self.contract = support.load_json(root / "suite-contract.json")
        self.runtime_manifest = {
            "provenance": {
                "builderSourceSHA256": support.sha256_bytes(b"builder"),
                "sourceRevision": "2" * 40,
                "toolchain": {
                    "macOSBuild": "25A1",
                    "sdkBuild": "25A1",
                    "swift": "Swift 6.2",
                    "xcode": "Xcode 17.0",
                },
            },
            "releaseStatus": support.RUNTIME_STATUS,
            "runtimeID": support.RUNTIME_ID,
            "schemaID": support.RUNTIME_SCHEMA,
        }
        runtime_bytes = support.canonical_bytes(self.runtime_manifest)
        (root / "runtime-manifest.json").write_bytes(runtime_bytes)
        release_bytes = b"SWIFT_OPTIMIZATION_LEVEL = -O\n"
        archive_bytes = b"fixture-notarized-application-archive"
        (root / "Release.xcconfig").write_bytes(release_bytes)
        (root / "application-archive.zip").write_bytes(archive_bytes)
        self.candidate = {
            "sourceCommit": "1" * 40,
            "sourceTreeIdentitySHA256": support.sha256_bytes(b"source-tree"),
            "runtimeManifestSHA256": support.sha256_bytes(
                support.MANIFEST_DOMAIN + runtime_bytes
            ),
            "runtimeManifestFileSHA256": support.sha256_bytes(runtime_bytes),
            "runtimeArtifactSetSHA256": support.sha256_bytes(b"runtime-artifacts"),
            "runtimeSourceRevision": "2" * 40,
            "releaseConfigurationSHA256": support.sha256_bytes(release_bytes),
            "appBundleSHA256": support.sha256_bytes(archive_bytes),
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "4.0",
            "productBuild": "400",
        }
        write_json(root / "candidate.json", self.candidate)
        self.runtime_summary = {
            "runtimeID": support.RUNTIME_ID,
            "releaseStatus": support.RUNTIME_STATUS,
            "semanticManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "manifestFileSHA256": self.candidate["runtimeManifestFileSHA256"],
            "sourceRevision": self.candidate["runtimeSourceRevision"],
        }
        self.rows = [self._build_row(row) for row in self.contract["machineClasses"]]
        self._write_report()
        self.reseal()

    def _signature(self, identifier: str, architecture: str) -> str:
        team = self.contract["developmentTeam"]
        return "\n".join(
            (
                f"Identifier={identifier}",
                f"Format=app bundle with Mach-O thin ({architecture})",
                "CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+7 location=embedded",
                f"Authority=Apple Development: Qualification Operator ({team})",
                "Authority=Apple Worldwide Developer Relations Certification Authority",
                "Authority=Apple Root CA",
                f"TeamIdentifier={team}",
                "",
            )
        )

    def _command(self, row: dict[str, object]) -> list[str]:
        identifier = row["id"]
        architecture = row["destinationArchitecture"]
        return [
            "xcodebuild",
            "test",
            "-project",
            self.contract["project"],
            "-scheme",
            self.contract["scheme"],
            "-configuration",
            "Release",
            "-destination",
            f"platform=macOS,arch={architecture}",
            "-derivedDataPath",
            f"/tmp/support/DerivedData-{identifier}",
            "-resultBundlePath",
            f"/tmp/support/{identifier}.xcresult",
            "-xcconfig",
            f"/tmp/support/worktree/{self.contract['releaseConfigurationPath']}",
            f"DEVELOPMENT_TEAM={self.contract['developmentTeam']}",
            "CODE_SIGN_STYLE=Automatic",
            "CODE_SIGN_IDENTITY=Apple Development",
            "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=YES",
            "ONLY_ACTIVE_ARCH=YES",
            f"ARCHS={architecture}",
            "ENABLE_TESTABILITY=YES",
        ]

    def _build_row(self, row: dict[str, object]) -> dict[str, object]:
        machine_class = str(row["id"])
        architecture = str(row["destinationArchitecture"])
        row_id = f"{machine_class}-{architecture}"
        directory = self.root / machine_class
        directory.mkdir()
        summary = {
            "devicesAndConfigurations": [
                {
                    "device": {
                        "architecture": architecture,
                        "deviceName": "Qualification Mac",
                    }
                }
            ],
            "failedTests": 0,
            "passedTests": self.contract["minimumPassingTestCount"] + 17,
            "result": "Passed",
            "skippedTests": len(self.contract["expectedSkippedTests"]),
        }
        test_tree = {
            "children": [
                {"nodeIdentifier": identifier, "result": "Skipped"}
                for identifier in self.contract["expectedSkippedTests"]
            ]
        }
        hardware = {
            "schemaVersion": support.HARDWARE_SCHEMA,
            "machineClass": machine_class,
            "executionArchitecture": architecture,
            "hardwareModel": "Mac15,7",
            "physicalMemoryBytes": 34359738368,
            "processorBrand": "Apple M3 Pro",
        }
        software = {
            "schemaVersion": support.SOFTWARE_SCHEMA,
            "machineClass": machine_class,
            "executionArchitecture": architecture,
            "macOSProductVersion": "26.0",
            "macOSBuildVersion": "25A1",
            "xcode": ["Xcode 17.0", "Build version 17A1"],
            "swift": "Apple Swift version 6.2",
            "metal": "Apple metal version 32000.1",
            "sdkVersion": "26.0",
            "sdkBuildVersion": "25A1",
        }
        write_json(directory / "test-summary.json", summary)
        write_json(directory / "test-tree.json", test_tree)
        write_json(directory / "hardware.json", hardware)
        write_json(directory / "software.json", software)
        (directory / "xcodebuild.log").write_text(
            "Test Suite 'All tests' passed\n** TEST SUCCEEDED **\n",
            encoding="utf-8",
        )
        (directory / "codesign-verification.log").write_text(
            "/tmp/Mirmir.app: valid on disk\n"
            "/tmp/Mirmir.app: satisfies its Designated Requirement\n",
            encoding="utf-8",
        )
        app_signature = self._signature("com.mirmir.app", architecture)
        test_signature = self._signature("com.mirmir.app.tests", architecture)
        (directory / "app-signature.txt").write_text(app_signature, encoding="utf-8")
        (directory / "test-signature.txt").write_text(test_signature, encoding="utf-8")
        app_identity = support.signature_identity(
            app_signature,
            expected_identifier="com.mirmir.app",
            expected_team=self.contract["developmentTeam"],
            expected_architecture=architecture,
            label="fixture app",
        )
        test_identity = support.signature_identity(
            test_signature,
            expected_identifier="com.mirmir.app.tests",
            expected_team=self.contract["developmentTeam"],
            expected_architecture=architecture,
            label="fixture tests",
        )
        signing = {
            "schemaVersion": support.SIGNING_SCHEMA,
            "developmentTeam": self.contract["developmentTeam"],
            "app": app_identity,
            "testBundle": test_identity,
            "sameTeamIdentity": True,
            "codeSignatureVerificationPass": True,
        }
        write_json(directory / "signing-summary.json", signing)
        command = self._command(row)
        invocation = support.sha256_bytes(support.canonical_bytes(command))
        semantic = {
            "schemaVersion": support.SUMMARY_SCHEMA,
            "row": {
                "id": row_id,
                "machineClass": machine_class,
                "runtimeMode": row["runtimeMode"],
                "executionArchitecture": architecture,
            },
            "candidate": {
                "sourceCommit": self.candidate["sourceCommit"],
                "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
                "appBundleSHA256": self.candidate["appBundleSHA256"],
                "releaseConfigurationSHA256": self.candidate["releaseConfigurationSHA256"],
            },
            "runtime": self.runtime_summary,
            "build": {
                "buildConfiguration": "Release",
                "command": command,
                "invocationSHA256": invocation,
                "transcriptSHA256": support.sha256_file(directory / "xcodebuild.log"),
            },
            "signing": {
                "developmentTeam": self.contract["developmentTeam"],
                "app": app_identity,
                "testBundle": test_identity,
                "sameTeamIdentity": True,
                "codeSignatureVerificationSHA256": support.sha256_file(
                    directory / "codesign-verification.log"
                ),
                "codeSignatureVerificationPass": True,
            },
            "tests": {
                "result": "Passed",
                "passedTestCount": summary["passedTests"],
                "failedTestCount": 0,
                "skippedTestCount": summary["skippedTests"],
                "minimumPassingTestCount": self.contract["minimumPassingTestCount"],
                "expectedSkippedTests": self.contract["expectedSkippedTests"],
                "observedSkippedTests": self.contract["expectedSkippedTests"],
                "unexpectedSkippedTests": [],
                "summarySHA256": support.sha256_file(directory / "test-summary.json"),
                "testTreeSHA256": support.sha256_file(directory / "test-tree.json"),
            },
            "environment": {
                "hardwareSHA256": support.sha256_file(directory / "hardware.json"),
                "softwareSHA256": support.sha256_file(directory / "software.json"),
            },
            "allRequiredChecksPassed": True,
        }
        write_json(directory / "semantic-summary.json", semantic)
        descriptors = {
            "hardwareArtifact": "hardware.json",
            "softwareArtifact": "software.json",
            "summaryArtifact": "test-summary.json",
            "testTreeArtifact": "test-tree.json",
            "transcriptArtifact": "xcodebuild.log",
            "codeSignatureVerificationArtifact": "codesign-verification.log",
            "appSignatureArtifact": "app-signature.txt",
            "testSignatureArtifact": "test-signature.txt",
            "signingSummaryArtifact": "signing-summary.json",
            "semanticSummaryArtifact": "semantic-summary.json",
        }
        attestation: dict[str, object] = {
            "schemaVersion": support.ROW_SCHEMA,
            "id": row_id,
            "machineClass": machine_class,
            "runtimeMode": row["runtimeMode"],
            "executionArchitecture": architecture,
            "sourceCommit": self.candidate["sourceCommit"],
            "sourceTreeIdentitySHA256": self.candidate["sourceTreeIdentitySHA256"],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "releaseConfigurationSHA256": self.candidate["releaseConfigurationSHA256"],
            "appBundleSHA256": self.candidate["appBundleSHA256"],
            "command": command,
            "invocationSHA256": invocation,
            "exitStatus": 0,
            "passedTestCount": summary["passedTests"],
            "failedTestCount": 0,
            "skippedTestCount": summary["skippedTests"],
            "expectedSkippedTests": self.contract["expectedSkippedTests"],
            "unexpectedSkippedTests": [],
            "fullQualificationMatrixPass": True,
        }
        attestation.update(
            {
                field: support.descriptor(directory / filename, self.root)
                for field, filename in descriptors.items()
            }
        )
        write_json(directory / "attestation.json", attestation)
        return {
            "id": row_id,
            "machineClass": machine_class,
            "hardwareIdentitySHA256": support.sha256_file(directory / "hardware.json"),
            "softwareImageSHA256": support.sha256_file(directory / "software.json"),
            "appBundleSHA256": self.candidate["appBundleSHA256"],
            "runtimeManifestSHA256": self.candidate["runtimeManifestSHA256"],
            "fullQualificationMatrixPass": True,
            "unexpectedSkipCount": 0,
            "externalEvidenceArtifact": support.descriptor(
                directory / "attestation.json", self.root
            ),
        }

    def _write_report(self) -> None:
        write_json(
            self.root / "report.json",
            {
                "schemaVersion": support.REPORT_SCHEMA,
                "contractSHA256": support.sha256_file(self.root / "suite-contract.json"),
                "candidate": self.candidate,
                "releaseEligible": True,
                "identities": self.contract["tools"],
                "declaredSupportedMachineClassIDs": [
                    row["id"] for row in self.contract["machineClasses"]
                ],
                "rows": self.rows,
                "supportMatrixGatePass": True,
            },
        )

    def reseal(self) -> None:
        manifest_path = self.root / "sealed-manifest.json"
        artifacts = [
            support.descriptor(path, self.root)
            for path in support.regular_files(self.root, {manifest_path})
        ]
        write_json(
            manifest_path,
            {"schemaVersion": support.EVIDENCE_SCHEMA, "artifacts": artifacts},
        )

    def row_path(self, machine_class: str, filename: str) -> Path:
        return self.root / machine_class / filename

    def rebind_row(self, machine_class: str) -> None:
        directory = self.root / machine_class
        attestation_path = directory / "attestation.json"
        attestation = support.load_json(attestation_path)
        descriptors = {
            "hardwareArtifact": "hardware.json",
            "softwareArtifact": "software.json",
            "summaryArtifact": "test-summary.json",
            "testTreeArtifact": "test-tree.json",
            "transcriptArtifact": "xcodebuild.log",
            "codeSignatureVerificationArtifact": "codesign-verification.log",
            "appSignatureArtifact": "app-signature.txt",
            "testSignatureArtifact": "test-signature.txt",
            "signingSummaryArtifact": "signing-summary.json",
            "semanticSummaryArtifact": "semantic-summary.json",
        }
        for field, filename in descriptors.items():
            attestation[field] = support.descriptor(directory / filename, self.root)
        write_json(attestation_path, attestation)
        row = next(item for item in self.rows if item["machineClass"] == machine_class)
        row["hardwareIdentitySHA256"] = support.sha256_file(directory / "hardware.json")
        row["softwareImageSHA256"] = support.sha256_file(directory / "software.json")
        row["externalEvidenceArtifact"] = support.descriptor(attestation_path, self.root)
        self._write_report()
        self.reseal()


class SupportMatrixReplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = SupportEvidenceFixture(Path(self.temporary.name) / "support_matrix")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_valid_evidence_replays_every_nested_row(self) -> None:
        report = support.replay_evidence(self.fixture.root)
        self.assertTrue(report["supportMatrixGatePass"])
        self.assertEqual(
            [row["id"] for row in report["rows"]],
            ["reference-arm64", "supported-x86_64"],
        )
        self.assertEqual(
            report["identities"], self.fixture.contract["tools"]
        )

    def test_exact_expected_skip_set_is_recomputed(self) -> None:
        path = self.fixture.row_path("reference", "test-tree.json")
        tree = support.load_json(path)
        tree["children"][0]["nodeIdentifier"] = "ForgedTests/testSkipped()"
        write_json(path, tree)
        self.fixture.rebind_row("reference")
        with self.assertRaisesRegex(support.SupportEvidenceError, "exact expected-skip set"):
            support.replay_evidence(self.fixture.root)

    def test_xcresult_architecture_is_recomputed(self) -> None:
        path = self.fixture.row_path("reference", "test-summary.json")
        summary = support.load_json(path)
        summary["devicesAndConfigurations"][0]["device"]["architecture"] = "x86_64"
        write_json(path, summary)
        self.fixture.rebind_row("reference")
        with self.assertRaisesRegex(support.SupportEvidenceError, "executed on another architecture"):
            support.replay_evidence(self.fixture.root)

    def test_signing_summary_cannot_forge_raw_signature_evidence(self) -> None:
        path = self.fixture.row_path("reference", "signing-summary.json")
        signing = support.load_json(path)
        signing["app"]["identifier"] = "com.attacker.substitute"
        write_json(path, signing)
        self.fixture.rebind_row("reference")
        with self.assertRaisesRegex(support.SupportEvidenceError, "signing summary differs"):
            support.replay_evidence(self.fixture.root)

    def test_signature_architecture_is_read_from_codesign_detail(self) -> None:
        path = self.fixture.row_path("reference", "app-signature.txt")
        path.write_text(
            path.read_text().replace("(arm64)", "(x86_64)"), encoding="utf-8"
        )
        self.fixture.rebind_row("reference")
        with self.assertRaisesRegex(support.SupportEvidenceError, "signing architecture differs"):
            support.replay_evidence(self.fixture.root)

    def test_xcode_command_is_locked_not_boolean_attested(self) -> None:
        path = self.fixture.row_path("supported", "attestation.json")
        attestation = support.load_json(path)
        attestation["command"][18] = "CODE_SIGN_IDENTITY=-"
        attestation["invocationSHA256"] = support.sha256_bytes(
            support.canonical_bytes(attestation["command"])
        )
        write_json(path, attestation)
        self.fixture.rebind_row("supported")
        with self.assertRaisesRegex(support.SupportEvidenceError, "xcode command differs"):
            support.replay_evidence(self.fixture.root)

    def test_candidate_identity_is_replayed_inside_each_attestation(self) -> None:
        path = self.fixture.row_path("supported", "attestation.json")
        attestation = support.load_json(path)
        attestation["sourceCommit"] = "f" * 40
        write_json(path, attestation)
        self.fixture.rebind_row("supported")
        with self.assertRaisesRegex(support.SupportEvidenceError, "sourceCommit differs"):
            support.replay_evidence(self.fixture.root)

    def test_runtime_manifest_is_semantically_recomputed(self) -> None:
        path = self.fixture.root / "runtime-manifest.json"
        manifest = support.load_json(path)
        manifest["releaseStatus"] = "preview"
        path.write_bytes(support.canonical_bytes(manifest))
        self.fixture.reseal()
        with self.assertRaisesRegex(
            support.SupportEvidenceError,
            "runtime manifest file identity differs|not release-qualified",
        ):
            support.replay_evidence(self.fixture.root)

    def test_semantic_summary_is_independently_reconstructed(self) -> None:
        path = self.fixture.row_path("reference", "semantic-summary.json")
        semantic = support.load_json(path)
        semantic["allRequiredChecksPassed"] = False
        write_json(path, semantic)
        self.fixture.rebind_row("reference")
        with self.assertRaisesRegex(support.SupportEvidenceError, "semantic summary differs"):
            support.replay_evidence(self.fixture.root)

    def test_hardware_hash_in_report_is_recomputed(self) -> None:
        self.fixture.rows[0]["hardwareIdentitySHA256"] = "f" * 64
        self.fixture._write_report()
        self.fixture.reseal()
        with self.assertRaisesRegex(support.SupportEvidenceError, "published support row"):
            support.replay_evidence(self.fixture.root)

    def test_unexpected_sealed_artifact_fails_closed(self) -> None:
        (self.fixture.root / "unscoped.txt").write_text("not part of the contract")
        self.fixture.reseal()
        with self.assertRaisesRegex(support.SupportEvidenceError, "unexpected or missing artifact"):
            support.replay_evidence(self.fixture.root)

    def test_tool_substitution_and_duplicate_json_fail_closed(self) -> None:
        (self.fixture.root / "capture-tool.py").write_text("# substituted\n")
        self.fixture.reseal()
        with self.assertRaisesRegex(support.SupportEvidenceError, "tool identity differs"):
            support.replay_evidence(self.fixture.root)

        self.fixture = SupportEvidenceFixture(Path(self.temporary.name) / "duplicate")
        (self.fixture.root / "candidate.json").write_text(
            '{"sourceCommit":"a","sourceCommit":"b"}\n', encoding="utf-8"
        )
        self.fixture.reseal()
        with self.assertRaisesRegex(support.SupportEvidenceError, "duplicate JSON key"):
            support.replay_evidence(self.fixture.root)


if __name__ == "__main__":
    unittest.main()
