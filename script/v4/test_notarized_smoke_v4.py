#!/usr/bin/env python3

from __future__ import annotations

import copy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tempfile
import unittest
import uuid
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))
import notarized_smoke_v4 as smoke  # noqa: E402
import run_notarized_smoke_v4 as runner  # noqa: E402


def utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def compact(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(smoke.canonical_bytes(value))


def artifact(path: Path, root: Path) -> dict[str, object]:
    return {
        "path": path.relative_to(root).as_posix(),
        "byteCount": path.stat().st_size,
        "sha256": smoke.sha256_file(path),
    }


class NotarizedSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_record(self, identifier: str = "probe") -> dict[str, object]:
        stdout = self.root / f"{identifier}.stdout"
        stderr = self.root / f"{identifier}.stderr"
        stdout.write_bytes(b"accepted\n")
        stderr.write_bytes(b"")
        command = ["/usr/bin/true", "--fixture"]
        return {
            "schemaVersion": smoke.PROCESS_SCHEMA,
            "id": identifier,
            "command": command,
            "invocationSHA256": smoke.sha256_bytes(smoke.canonical_bytes(command)),
            "executablePath": command[0],
            "executableSHA256": "a" * 64,
            "startedAtUTC": utc(self.now),
            "finishedAtUTC": utc(self.now + timedelta(seconds=1)),
            "exitStatus": 0,
            "stdoutArtifact": artifact(stdout, self.root),
            "stderrArtifact": artifact(stderr, self.root),
        }

    def test_duplicate_and_nonfinite_json_are_rejected(self) -> None:
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "duplicate JSON key"):
            smoke.load_json_bytes(b'{"a":1,"a":2}', "fixture")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "non-finite"):
            smoke.load_json_bytes(b'{"a":NaN}', "fixture")

    def test_process_record_recomputes_invocation_and_outputs(self) -> None:
        record = self.make_record()
        observed = smoke.validate_process_record(
            self.root,
            record,
            "probe",
            self.now - timedelta(seconds=1),
            self.now + timedelta(seconds=2),
        )
        self.assertEqual(observed["exitStatus"], 0)
        forged = copy.deepcopy(record)
        forged["command"].append("--forged")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "invocation SHA-256"):
            smoke.validate_process_record(
                self.root,
                forged,
                "probe",
                self.now - timedelta(seconds=1),
                self.now + timedelta(seconds=2),
            )

    def test_nonzero_and_stale_process_records_fail_closed(self) -> None:
        nonzero = self.make_record()
        nonzero["exitStatus"] = 1
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "external process failed"):
            smoke.validate_process_record(
                self.root,
                nonzero,
                "probe",
                self.now - timedelta(seconds=1),
                self.now + timedelta(seconds=2),
            )
        stale = self.make_record()
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "outside capture"):
            smoke.validate_process_record(
                self.root,
                stale,
                "probe",
                self.now + timedelta(minutes=1),
                self.now + timedelta(minutes=2),
            )

    def test_tree_identity_rejects_links_and_detects_byte_tamper(self) -> None:
        tree = self.root / "tree"
        tree.mkdir()
        (tree / "file").write_bytes(b"one")
        first, _, _ = smoke.tree_identity(tree, 1024)
        (tree / "file").write_bytes(b"two")
        second, _, _ = smoke.tree_identity(tree, 1024)
        self.assertNotEqual(first, second)
        (tree / "link").symlink_to("file")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "symlink"):
            smoke.tree_identity(tree, 1024)

    def make_archive(self, path: Path, *, symlink: bool = False) -> dict[str, str]:
        manifest = {
            "artifacts": [],
            "provenance": {"sourceRevision": "b" * 40},
            "releaseStatus": "release_qualified",
            "runtimeID": "ash-p06-deterministic-v4",
            "schemaVersion": "fixture",
        }
        plist = {
            "CFBundleExecutable": "Mirmir",
            "CFBundleIdentifier": "com.mirmir.app",
            "CFBundleShortVersionString": "1.2.0",
            "CFBundleVersion": "2",
        }
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Mirmir.app/Contents/Info.plist", plistlib.dumps(plist))
            archive.writestr("Mirmir.app/Contents/MacOS/Mirmir", b"shipping-executable")
            archive.writestr(
                "Mirmir.app/Contents/Resources/ASH-P06.bundle/runtime-manifest.json",
                smoke.canonical_bytes(manifest),
            )
            if symlink:
                entry = zipfile.ZipInfo("Mirmir.app/Contents/unsafe-link")
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, "target")
        return {
            "runtime": smoke.sha256_bytes(smoke.MANIFEST_DOMAIN + smoke.canonical_bytes(manifest)),
            "runtimeFile": smoke.sha256_bytes(smoke.canonical_bytes(manifest)),
            "executable": smoke.sha256_bytes(b"shipping-executable"),
        }

    def test_archive_inspection_binds_embedded_executable_and_p06(self) -> None:
        archive = self.root / "Mirmir.zip"
        expected = self.make_archive(archive)
        observed = smoke.inspect_application_archive(archive)
        self.assertEqual(observed["executableSHA256"], expected["executable"])
        self.assertEqual(observed["runtimeManifestSHA256"], expected["runtime"])
        self.assertEqual(observed["runtimeManifestFileSHA256"], expected["runtimeFile"])

    def test_archive_symlink_is_rejected(self) -> None:
        archive = self.root / "unsafe.zip"
        self.make_archive(archive, symlink=True)
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "link or special"):
            smoke.inspect_application_archive(archive)

    def make_external_record(self, name: str, stdout: bytes = b"", stderr: bytes = b"") -> dict[str, Path]:
        out = self.root / f"{name}.out"
        err = self.root / f"{name}.err"
        out.write_bytes(stdout)
        err.write_bytes(stderr)
        return {"_stdout": out, "_stderr": err}

    def signing_records(
        self,
        *,
        get_task_allow: bool = False,
        application_bookmarks: bool = True,
    ) -> dict[str, dict[str, Path]]:
        display = (
            "Identifier=com.mirmir.app\n"
            "CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+7 location=embedded\n"
            "Authority=Developer ID Application: Example (9AQ2C2838M)\n"
            "Timestamp=Aug 3, 2026 at 12:00:00 PM\n"
            "TeamIdentifier=9AQ2C2838M\n"
            "CDHash=0123456789abcdef0123456789abcdef01234567\n"
        ).encode()
        requirement = b'designated => identifier "com.mirmir.app" and anchor apple generic and certificate leaf[subject.OU] = "9AQ2C2838M"\n'
        entitlements: dict[str, object] = {
            "com.apple.security.app-sandbox": True,
        }
        if application_bookmarks:
            entitlements["com.apple.security.files.bookmarks.app-scope"] = True
        if get_task_allow:
            entitlements["com.apple.security.get-task-allow"] = True
        return {
            "code_signature_validation": self.make_external_record("verify", stderr=b"valid on disk\n"),
            "code_signature_display": self.make_external_record("display", stderr=display),
            "code_signature_entitlements": self.make_external_record("entitlements", stdout=plistlib.dumps(entitlements)),
            "code_signature_requirements": self.make_external_record("requirements", stdout=requirement),
            "submitted_signature_display": self.make_external_record("submitted-display", stderr=display),
            "submitted_signature_requirements": self.make_external_record("submitted-requirements", stdout=requirement),
        }

    def test_codesign_semantics_require_runtime_sandbox_and_developer_id(self) -> None:
        contract = smoke.load_json(SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json")
        result = smoke.validate_codesign_evidence(
            self.signing_records(),
            contract,
            {"bundleIdentifier": "com.mirmir.app"},
        )
        self.assertTrue(result["hardenedRuntime"])
        self.assertTrue(result["sandboxed"])

    def test_get_task_allow_entitlement_is_rejected(self) -> None:
        contract = smoke.load_json(SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "get-task-allow"):
            smoke.validate_codesign_evidence(
                self.signing_records(get_task_allow=True),
                contract,
                {"bundleIdentifier": "com.mirmir.app"},
            )

    def test_application_scoped_bookmark_entitlement_is_required(self) -> None:
        contract = smoke.load_json(SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "bookmarks.app-scope"):
            smoke.validate_codesign_evidence(
                self.signing_records(application_bookmarks=False),
                contract,
                {"bundleIdentifier": "com.mirmir.app"},
            )

    def test_gatekeeper_and_stapler_transcripts_are_semantic(self) -> None:
        records = {
            "gatekeeper_assessment": self.make_external_record(
                "spctl", stderr=b"Mirmir.app: accepted\nsource=Notarized Developer ID\n"
            ),
            "stapled_ticket_validation": self.make_external_record(
                "stapler", stdout=b"The ticket is valid. The validate action worked!\n"
            ),
        }
        self.assertTrue(smoke.validate_system_acceptance(records)["ticketStapled"])
        records["gatekeeper_assessment"]["_stderr"].write_bytes(b"accepted\n")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "Gatekeeper"):
            smoke.validate_system_acceptance(records)

    def test_notary_log_binds_submission_archive_and_freshness(self) -> None:
        submission_id = str(uuid.uuid4())
        submitted_at = utc(self.now - timedelta(hours=1))
        archive_sha = "d" * 64
        info = self.make_external_record(
            "notary-info",
            stdout=smoke.pretty_bytes(
                {"id": submission_id, "status": "Accepted", "createdDate": submitted_at}
            ),
        )
        log_path = self.root / "notary-log.json"
        smoke.write_json(
            log_path,
            {
                "jobId": submission_id,
                "status": "Accepted",
                "statusCode": 0,
                "issues": None,
                "sha256": archive_sha,
                "archiveFilename": "submitted.zip",
                "uploadDate": submitted_at,
            },
        )
        result = smoke.parse_notary_evidence(
            {"notary_info": info},
            log_path,
            archive_sha,
            {"id": submission_id, "submittedArchiveName": "submitted.zip"},
            86_400,
            self.now,
        )
        self.assertEqual(result["status"], "Accepted")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "SHA-256"):
            smoke.parse_notary_evidence(
                {"notary_info": info},
                log_path,
                "e" * 64,
                {"id": submission_id, "submittedArchiveName": "submitted.zip"},
                86_400,
                self.now,
            )

    def semantic(self, width: int, height: int) -> dict[str, object]:
        return {
            "encodedWidth": width,
            "encodedHeight": height,
            "frameCount": 12,
            "enabledVideoTrackCount": 1,
            "durationValue": 240000,
            "durationTimescale": 600000,
            "timingSHA256": "1" * 64,
            "visiblePixelSHA256": "2" * 64,
        }

    def prepare_fixture(self) -> tuple[dict[str, object], dict[str, object]]:
        snapshot = self.root / "phase-one"
        (snapshot / "media").mkdir(parents=True)
        (snapshot / "workflow-queue-v4").mkdir()
        (snapshot / "media" / "source.mov").write_bytes(b"source")
        (snapshot / "media" / "uninterrupted.mov").write_bytes(b"direct")
        (snapshot / "workflow-queue-v4" / "checkpoint-1").write_bytes(b"checkpoint")
        input_artifact = artifact(snapshot / "media" / "source.mov", snapshot)
        direct_artifact = artifact(snapshot / "media" / "uninterrupted.mov", snapshot)
        queue_sha, _, _ = smoke.tree_identity(snapshot / "workflow-queue-v4", 1024 * 1024)
        request = {
            "requestID": str(uuid.uuid4()),
            "nonce": "3" * 64,
            "laneContractSHA256": "a" * 64,
            "releaseContractSHA256": "b" * 64,
            "applicationArchiveSHA256": "4" * 64,
            "sourceCommit": "5" * 40,
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "1.2.0",
            "productBuild": "2",
            "runtimeManifestSHA256": "6" * 64,
            "runtimeManifestFileSHA256": "7" * 64,
            "expectedExecutableSHA256": "8" * 64,
        }
        state = {
            "schemaVersion": smoke.PHASE_ONE_STATE_SCHEMA,
            "requestID": request["requestID"],
            "nonceSHA256": smoke.sha256_bytes(request["nonce"].encode()),
            "requestSHA256": "9" * 64,
            "applicationArchiveSHA256": request["applicationArchiveSHA256"],
            "sourceCommit": request["sourceCommit"],
            "executableSHA256": request["expectedExecutableSHA256"],
            "runtimeManifestSHA256": request["runtimeManifestSHA256"],
            "runtimeManifestFileSHA256": request["runtimeManifestFileSHA256"],
            "jobID": str(uuid.uuid4()),
            "inputArtifact": input_artifact,
            "inputSemantic": self.semantic(64, 48),
            "directOutputArtifact": direct_artifact,
            "directOutputSemantic": self.semantic(96, 72),
            "queueTreeSHA256": queue_sha,
        }
        state_path = snapshot / "phase-one-state.json"
        compact(state_path, state)
        result = {
            "requestSHA256": state["requestSHA256"],
            "mediaProbe": {
                "encodedWidth": 64, "encodedHeight": 48, "codecFourCC": "avc1",
                "durationValue": 240000, "durationTimescale": 600000,
                "estimatedFrameCount": 12, "videoTrackCount": 1, "audioTrackCount": 0,
                "bitDepth": 8, "bitDepthEvidence": "locked_h264_writer_contract",
                "isFullRange": False, "rangeEvidence": "locked_h264_writer_contract",
                "dynamicRange": "SDR", "fieldCount": 1,
                "fieldCountEvidence": "locked_h264_writer_contract",
                "readable": True, "playable": True,
            },
            "inputSemantic": state["inputSemantic"],
            "directOutputSemantic": state["directOutputSemantic"],
            "deterministicProcess": {
                "actualBackendID": "mirmirDeterministicCPU", "processedFrameCount": 12,
                "encodedWidth": 96, "encodedHeight": 72, "outputCodec": "h264",
                "processingDurationSeconds": 1.0,
            },
            "artifacts": {
                "input": input_artifact,
                "directOutput": direct_artifact,
                "phaseOneState": artifact(state_path, snapshot),
            },
            "queue": {
                "jobID": state["jobID"], "lifecycle": "paused",
                "checkpointRelatedFileCount": 1, "queueTreeSHA256": queue_sha,
            },
        }
        prepare_result_path = self.root / "captured-prepare-result.json"
        compact(prepare_result_path, result)
        observation = {
            "request": request,
            "result": result,
            "resultPath": prepare_result_path,
            "snapshot": snapshot,
            "process": {"processID": 101},
        }
        facts = smoke.validate_prepare_observation(observation, 1024 * 1024)
        facts["observation"] = observation
        return observation, facts

    def test_paused_queue_and_phase_one_state_are_recomputed(self) -> None:
        _, facts = self.prepare_fixture()
        self.assertEqual(facts["queue"]["lifecycle"], "paused")
        checkpoint = self.root / "phase-one" / "workflow-queue-v4" / "checkpoint-1"
        checkpoint.write_bytes(b"tampered")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "queue tree seal"):
            smoke.validate_prepare_observation(facts["observation"], 1024 * 1024)

    def test_recovery_requires_exact_decoded_equality_and_new_process(self) -> None:
        prepare_observation, prepare = self.prepare_fixture()
        final = self.root / "final"
        shutil.copytree(prepare_observation["snapshot"], final)
        (final / "media" / "recovered.mov").write_bytes(b"recovered-container")
        (final / "workflow-queue-v4" / "checkpoint-1").write_bytes(b"completed")
        final_sha, _, _ = smoke.tree_identity(final / "workflow-queue-v4", 1024 * 1024)
        phase_one_sha = smoke.sha256_file(prepare_observation["resultPath"])
        recover_request = dict(prepare_observation["request"])
        recover_request["phaseOneResultSHA256"] = phase_one_sha
        result = {
            "phaseOneResultSHA256": phase_one_sha,
            "referenceSemantic": prepare["directSemantic"],
            "recoveredSemantic": prepare["directSemantic"],
            "resumedProcess": {
                "actualBackendID": "mirmirDeterministicCPU", "processedFrameCount": 12,
                "encodedWidth": 96, "encodedHeight": 72, "outputCodec": "h264",
                "processingDurationSeconds": 1.0,
            },
            "artifacts": {
                "directOutput": prepare["state"]["directOutputArtifact"],
                "recoveredOutput": artifact(final / "media" / "recovered.mov", final),
                "phaseOneState": artifact(final / "phase-one-state.json", final),
            },
            "queue": {
                "jobID": prepare["queue"]["jobID"], "launchLifecycle": "paused",
                "finalLifecycle": "completed", "launchRecoveryItemCount": 1,
                "launchRecoveryStatus": "idle",
                "launchRecoveryObservedLifecycle": "paused",
                "launchRecoveryPresentedLifecycle": "paused",
                "launchRecoveryResumable": True,
                "launchRecoveryContainedFailureCount": 0,
                "phaseOneQueueTreeSHA256": prepare["queue"]["queueTreeSHA256"],
                "finalQueueTreeSHA256": final_sha,
            },
        }
        observation = {
            "request": recover_request,
            "result": result,
            "snapshot": final,
            "process": {"processID": 202},
        }
        recovered = smoke.validate_recover_observation(observation, prepare, 1024 * 1024)
        self.assertEqual(recovered["referenceSemantic"], recovered["recoveredSemantic"])
        forged = copy.deepcopy(observation)
        forged["result"]["recoveredSemantic"]["visiblePixelSHA256"] = "f" * 64
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "decoded pixels/timing"):
            smoke.validate_recover_observation(forged, prepare, 1024 * 1024)

    def test_runner_rejects_error_marker_and_extra_stdout(self) -> None:
        with self.assertRaisesRegex(runner.NotarizedSmokeCaptureError, "observer error"):
            runner.observer_result(b"MIRMIR_V4_NOTARIZED_SMOKE_ERROR e30=\n", "prepare")
        valid = smoke.canonical_bytes({"ok": True})
        line = b"MIRMIR_V4_NOTARIZED_SMOKE_RESULT " + __import__("base64").b64encode(valid) + b"\nextra\n"
        with self.assertRaisesRegex(runner.NotarizedSmokeCaptureError, "invalid prepare result marker"):
            runner.observer_result(line, "prepare")

    def test_runner_uses_phase_specific_canonical_optional_key(self) -> None:
        candidate = {
            "appBundleSHA256": "a" * 64,
            "sourceCommit": "b" * 40,
            "bundleIdentifier": "com.mirmir.app",
            "productVersion": "1.2.0",
            "productBuild": "2",
            "runtimeManifestSHA256": "c" * 64,
            "runtimeManifestFileSHA256": "d" * 64,
        }
        prepare = runner.request_value(
            "prepare", str(uuid.uuid4()), "e" * 64, "f" * 64,
            "1" * 64, candidate, "2" * 64, None,
        )
        self.assertNotIn("phaseOneResultSHA256", prepare)
        recover = runner.request_value(
            "recover", prepare["requestID"], "e" * 64, "f" * 64,
            "1" * 64, candidate, "2" * 64, "3" * 64,
        )
        self.assertEqual(recover["phaseOneResultSHA256"], "3" * 64)

    def test_sealed_manifest_rejects_tamper_and_unsealed_file(self) -> None:
        suite = self.root / "suite"
        suite.mkdir()
        (suite / "report.json").write_bytes(b"report")
        manifest = smoke.seal_suite(suite)
        smoke.verify_sealed_suite(suite, manifest)
        (suite / "report.json").write_bytes(b"tampered")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "byte count|SHA-256"):
            smoke.verify_sealed_suite(suite, manifest)
        (suite / "report.json").write_bytes(b"report")
        (suite / "unsealed").write_bytes(b"unexpected")
        with self.assertRaisesRegex(smoke.NotarizedSmokeError, "sealed file set mismatch"):
            smoke.verify_sealed_suite(suite, manifest)


if __name__ == "__main__":
    unittest.main()
