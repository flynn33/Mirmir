#!/usr/bin/env python3
"""Capture a notarized Mirmir candidate without submitting it for notarization.

Apple acceptance is replayed either through an existing notarytool submission
or through the accepted receipt/export retained by an Xcode archive. This
runner records Apple and local system decisions, invokes the shipping app
binary twice in its isolated sandbox qualification mode, and delegates every
release claim to the independent replay evaluator.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any, Mapping, Sequence
import uuid

import notarized_smoke_v4 as evidence


class NotarizedSmokeCaptureError(ValueError):
    """The candidate could not produce admissible notarized smoke evidence."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise NotarizedSmokeCaptureError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def copy_regular(source: Path, destination: Path) -> None:
    source = source.resolve(strict=True)
    metadata = source.stat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and not source.is_symlink(), f"source is not a single-link regular file: {source}")
    require(not destination.exists(), f"refusing to overwrite capture artifact: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(source, destination)
    destination.chmod(0o600)
    require(evidence.sha256_file(source) == evidence.sha256_file(destination), f"copied artifact identity changed: {source}")


def safe_executable(path: Path, label: str) -> Path:
    resolved = path.resolve(strict=True)
    metadata = resolved.stat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and not resolved.is_symlink(), f"{label} is not a safe executable")
    require(os.access(resolved, os.X_OK), f"{label} is not executable")
    return resolved


def xcrun_find(xcrun: Path, name: str) -> Path:
    process = subprocess.run(
        [str(xcrun), "--find", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    require(process.returncode == 0, f"xcrun could not locate {name}: {process.stderr.decode(errors='replace').strip()}")
    lines = process.stdout.decode("utf-8", errors="strict").splitlines()
    require(len(lines) == 1 and lines[0].startswith("/"), f"xcrun returned a noncanonical {name} path")
    return safe_executable(Path(lines[0]), name)


def write_compact(path: Path, value: Any) -> None:
    require(not path.exists(), f"refusing to overwrite {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(evidence.canonical_bytes(value))
    path.chmod(0o600)


def run_recorded(
    capture_root: Path,
    record_id: str,
    command: Sequence[str],
    timeout_seconds: int,
    *,
    environment: Mapping[str, str] | None = None,
) -> tuple[dict[str, Any], Path]:
    require(command and all(isinstance(item, str) and item for item in command), f"invalid command for {record_id}")
    executable = safe_executable(Path(command[0]), f"{record_id} executable")
    executable_sha = evidence.sha256_file(executable)
    command_directory = capture_root / "commands"
    stdout_path = command_directory / f"{record_id}.stdout"
    stderr_path = command_directory / f"{record_id}.stderr"
    record_path = command_directory / f"{record_id}.json"
    require(not stdout_path.exists() and not stderr_path.exists() and not record_path.exists(), f"duplicate command record: {record_id}")
    command_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    started = utc_now()
    try:
        process = subprocess.run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout_seconds,
            env=dict(environment) if environment is not None else None,
        )
    except subprocess.TimeoutExpired as error:
        stdout_path.write_bytes(error.stdout or b"")
        stderr_path.write_bytes(error.stderr or b"")
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        raise NotarizedSmokeCaptureError(f"{record_id} exceeded {timeout_seconds} seconds") from error
    finished = utc_now()
    stdout_path.write_bytes(process.stdout)
    stderr_path.write_bytes(process.stderr)
    stdout_path.chmod(0o600)
    stderr_path.chmod(0o600)
    require(evidence.sha256_file(executable) == executable_sha, f"{record_id} executable changed during invocation")
    record = {
        "schemaVersion": evidence.PROCESS_SCHEMA,
        "id": record_id,
        "command": list(command),
        "invocationSHA256": evidence.sha256_bytes(evidence.canonical_bytes(list(command))),
        "executablePath": str(executable),
        "executableSHA256": executable_sha,
        "startedAtUTC": started,
        "finishedAtUTC": finished,
        "exitStatus": process.returncode,
        "stdoutArtifact": evidence.descriptor(stdout_path, capture_root),
        "stderrArtifact": evidence.descriptor(stderr_path, capture_root),
    }
    evidence.write_json(record_path, record)
    require(process.returncode == 0, f"{record_id} exited {process.returncode}: {process.stderr.decode('utf-8', errors='replace').strip()}")
    return record, record_path


def validate_extracted_app(root: Path) -> tuple[Path, Path, dict[str, Any]]:
    apps = [path for path in root.iterdir() if path.is_dir() and path.suffix == ".app" and not path.is_symlink()]
    require(len(apps) == 1 and len(list(root.iterdir())) == 1, "archive extraction must contain exactly one top-level app")
    app = apps[0].resolve(strict=True)
    info_path = app / "Contents" / "Info.plist"
    require(info_path.is_file() and not info_path.is_symlink(), "extracted app omits Info.plist")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except plistlib.InvalidFileException as error:
        raise NotarizedSmokeCaptureError("extracted app Info.plist is invalid") from error
    require(isinstance(info, dict), "extracted app Info.plist is not a dictionary")
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and executable_name, "extracted app omits CFBundleExecutable")
    executable = safe_executable(app / "Contents" / "MacOS" / executable_name, "shipping app")
    return app, executable, info


def extract_archive(ditto: Path, archive: Path, destination: Path) -> tuple[Path, Path, dict[str, Any]]:
    require(not destination.exists(), f"archive destination exists: {destination}")
    destination.mkdir(mode=0o700)
    process = subprocess.run(
        [str(ditto), "-x", "-k", "--sequesterRsrc", "--rsrc", str(archive), str(destination)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=300,
    )
    require(process.returncode == 0, f"ditto could not extract {archive.name}: {process.stderr.decode(errors='replace').strip()}")
    return validate_extracted_app(destination)


def snapshot_tree(source: Path, destination: Path, maximum_bytes: int) -> dict[str, Any]:
    source = source.resolve(strict=True)
    require(source.is_dir() and not source.is_symlink(), "qualification root is not a safe directory")
    require(not destination.exists(), f"snapshot destination exists: {destination}")
    destination.mkdir(parents=True, mode=0o700)
    total = 0
    seen_inodes: set[tuple[int, int]] = set()
    for directory, names, files in os.walk(source, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        source_directory = Path(directory)
        relative_directory = source_directory.relative_to(source)
        target_directory = destination / relative_directory
        target_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        for name in names:
            child = source_directory / name
            metadata = child.lstat()
            require(stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode), f"qualification tree contains unsafe directory: {child}")
            (target_directory / name).mkdir(mode=0o700)
        for name in files:
            child = source_directory / name
            metadata = child.lstat()
            inode = (metadata.st_dev, metadata.st_ino)
            require(stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode) and metadata.st_nlink == 1 and inode not in seen_inodes, f"qualification tree contains unsafe file: {child}")
            seen_inodes.add(inode)
            total += metadata.st_size
            require(total <= maximum_bytes, "qualification tree exceeds its evidence byte bound")
            copy_regular(child, target_directory / name)
    identity, byte_count, file_count = evidence.tree_identity(destination, maximum_bytes)
    return {
        "path": destination.relative_to(destination.parents[1]).as_posix(),
        "byteCount": byte_count,
        "fileCount": file_count,
        "treeSHA256": identity,
    }


def observer_result(stdout: bytes, phase: str) -> bytes:
    prefix = b"MIRMIR_V4_NOTARIZED_SMOKE_RESULT "
    error_prefix = b"MIRMIR_V4_NOTARIZED_SMOKE_ERROR "
    require(not stdout.startswith(error_prefix), f"shipping app reported an observer error during {phase}")
    require(stdout.startswith(prefix) and stdout.endswith(b"\n") and stdout.count(b"\n") == 1, f"shipping app emitted an invalid {phase} result marker")
    try:
        result = base64.b64decode(stdout[len(prefix) : -1], validate=True)
    except ValueError as error:
        raise NotarizedSmokeCaptureError(f"shipping app emitted invalid {phase} result base64") from error
    require(bool(result), f"shipping app emitted an empty {phase} result")
    # Decode for structural validity, then require Foundation-canonical wire bytes.
    evidence.load_json_bytes(result, f"{phase} observer result")
    try:
        evidence.require_foundation_canonical(result, f"shipping app {phase} result")
    except evidence.NotarizedSmokeError as error:
        raise NotarizedSmokeCaptureError(str(error)) from error
    return result


def request_value(
    phase: str,
    request_id: str,
    nonce: str,
    lane_sha: str,
    release_sha: str,
    candidate: Mapping[str, Any],
    executable_sha: str,
    phase_one_sha: str | None,
) -> dict[str, Any]:
    result = {
        "schemaVersion": evidence.REQUEST_SCHEMA,
        "phase": phase,
        "requestID": request_id,
        "nonce": nonce,
        "generatedAtUTC": utc_now(),
        "laneContractSHA256": lane_sha,
        "releaseContractSHA256": release_sha,
        "applicationArchiveSHA256": candidate["appBundleSHA256"],
        "sourceCommit": candidate["sourceCommit"],
        "bundleIdentifier": candidate["bundleIdentifier"],
        "productVersion": candidate["productVersion"],
        "productBuild": candidate["productBuild"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": candidate["runtimeManifestFileSHA256"],
        "expectedExecutableSHA256": executable_sha,
    }
    # Swift's synthesized Codable representation uses encodeIfPresent for the
    # optional phase-one seal. The prepare envelope therefore omits the key;
    # recover includes it with the exact non-nil identity.
    if phase_one_sha is not None:
        result["phaseOneResultSHA256"] = phase_one_sha
    return result


def safe_remove_qualification_root(path: Path, bundle_identifier: str, request_id: str) -> None:
    expected_suffix = f"/Library/Containers/{bundle_identifier}/Data/Library/Application Support/MirmirQualificationV4/notarized-smoke/{request_id}"
    require(str(path).endswith(expected_suffix), "refusing to remove a non-qualification path")
    if not path.exists():
        return
    require(path.is_dir() and not path.is_symlink(), "qualification cleanup root is unsafe")
    # The snapshots were already fail-closed over links, special files, hard
    # links, and total size. This removal is limited to the exact random UUID.
    shutil.rmtree(path)


def load_candidate(path: Path) -> dict[str, Any]:
    candidate = evidence.validate_candidate(evidence.load_json(path.resolve(strict=True)))
    return candidate


def tool_manifest(
    app: Path,
    contract: Mapping[str, Any],
    stapler: Path,
    provider_tools: Mapping[str, Path],
) -> dict[str, Any]:
    fixed = {name: safe_executable(Path(path), name) for name, path in contract["tools"].items()}
    python = safe_executable(Path(sys.executable), "python3")
    paths = {
        "app": app,
        "codesign": fixed["codesign"],
        "ditto": fixed["ditto"],
        "python3": python,
        "spctl": fixed["spctl"],
        "stapler": stapler,
        "xcrun": fixed["xcrun"],
        **provider_tools,
    }
    return {
        "schemaVersion": evidence.TOOL_SCHEMA,
        "tools": {
            name: {"path": str(path), "sha256": evidence.sha256_file(path)}
            for name, path in sorted(paths.items())
        },
    }


def locate_xcode_submission(
    archive: Path,
    requested_submission_id: str | None,
) -> tuple[Path, Path, Path, str]:
    archive = archive.expanduser().resolve(strict=True)
    require(archive.is_dir() and not archive.is_symlink() and archive.suffix == ".xcarchive", "Xcode archive is not a safe .xcarchive directory")
    info_path = archive / "Info.plist"
    require(info_path.is_file() and not info_path.is_symlink(), "Xcode archive omits Info.plist")
    submissions_root = archive / "Submissions"
    require(submissions_root.is_dir() and not submissions_root.is_symlink(), "Xcode archive omits its Submissions directory")
    rows: list[tuple[Path, Path, str]] = []
    for child in sorted(submissions_root.iterdir(), key=lambda item: item.name):
        require(child.is_dir() and not child.is_symlink(), "Xcode Submissions contains an unsafe entry")
        try:
            submission_id = str(uuid.UUID(child.name)).lower()
        except ValueError as error:
            raise NotarizedSmokeCaptureError("Xcode Submissions contains a non-UUID directory") from error
        if requested_submission_id is not None and submission_id != str(uuid.UUID(requested_submission_id)).lower():
            continue
        log_path = child / "notarization-log.json"
        app_paths = [item for item in child.iterdir() if item.is_dir() and item.suffix == ".app" and not item.is_symlink()]
        require(log_path.is_file() and not log_path.is_symlink(), "Xcode submission omits notarization-log.json")
        require(len(app_paths) == 1, "Xcode submission must contain exactly one application")
        rows.append((child, log_path, submission_id))
    require(len(rows) == 1, "Xcode archive must resolve to exactly one notarized submission")
    submission_root, log_path, submission_id = rows[0]
    return archive, info_path, log_path, submission_id


def capture(arguments: argparse.Namespace) -> Path:
    output = arguments.output.expanduser().resolve()
    require(not output.exists(), f"output already exists: {output}")
    require(output.parent.is_dir() and not output.parent.is_symlink(), "output parent must be a safe existing directory")
    contract_path = arguments.contract.expanduser().resolve(strict=True)
    release_contract_path = arguments.release_contract.expanduser().resolve(strict=True)
    contract, lane_sha, release_sha = evidence.validate_contract(contract_path, release_contract_path)
    candidate = load_candidate(arguments.candidate)
    candidate_archive = arguments.application_archive.expanduser().resolve(strict=True)
    candidate_archive_info = evidence.inspect_application_archive(candidate_archive)
    require(candidate_archive_info["archiveSHA256"] == candidate["appBundleSHA256"], "application archive differs from release candidate")

    xcode_mode = arguments.xcode_archive is not None
    if xcode_mode:
        require(arguments.submitted_archive is None, "--submitted-archive cannot be combined with --xcode-archive")
        require(arguments.notary_submission_id is None and arguments.notary_keychain_profile is None, "notarytool credentials cannot be combined with --xcode-archive")
        xcode_archive, xcode_info, xcode_log, submission_id = locate_xcode_submission(
            arguments.xcode_archive,
            arguments.xcode_submission_id,
        )
        submitted_source: Path | None = None
    else:
        require(arguments.submitted_archive is not None, "--submitted-archive is required for the notarytool provider")
        require(arguments.notary_submission_id is not None and arguments.notary_keychain_profile is not None, "notarytool submission ID and Keychain profile are required")
        require(arguments.xcode_submission_id is None, "--xcode-submission-id requires --xcode-archive")
        submitted_source = arguments.submitted_archive.expanduser().resolve(strict=True)
        submission_id = str(uuid.UUID(arguments.notary_submission_id)).lower()
        xcode_archive = xcode_info = xcode_log = None

    staging = output.parent / f".{output.name}.staging.{uuid.uuid4()}"
    failed = output.parent / f"{output.name}.failed.{uuid.uuid4()}"
    require(not staging.exists() and not failed.exists(), "capture staging collision")
    staging.mkdir(mode=0o700)
    capture_root = staging / "raw"
    capture_root.mkdir(mode=0o700)
    qualification_root: Path | None = None
    completed = False
    try:
        submitted_archive_name = "Mirmir-xcode-export.zip" if xcode_mode else submitted_source.name
        copied: dict[str, Path] = {
            "candidateJSON": capture_root / "bindings" / "candidate.json",
            "laneContract": capture_root / "bindings" / "notarized-smoke-contract-v1.json",
            "releaseContract": capture_root / "bindings" / "release-qualification-contract-v1.json",
            "observerSource": capture_root / "bindings" / "MirmirApp.swift",
            "evaluator": capture_root / "bindings" / "notarized_smoke_v4.py",
            "runner": capture_root / "bindings" / "run_notarized_smoke_v4.py",
            "candidateArchive": capture_root / "archives" / candidate_archive.name,
            "submittedArchive": capture_root / "archives" / submitted_archive_name,
            "candidateExecutable": capture_root / "bindings" / "Mirmir-executable",
            "toolManifest": capture_root / "bindings" / "tool-identities.json",
            "notaryLog": capture_root / "apple" / "notary-log.json",
        }
        if xcode_mode:
            copied["xcodeArchiveInfo"] = capture_root / "apple" / "xcode-archive-Info.plist"
        copy_regular(arguments.candidate, copied["candidateJSON"])
        copy_regular(contract_path, copied["laneContract"])
        copy_regular(release_contract_path, copied["releaseContract"])
        observer_source = SCRIPT_DIRECTORY.parent.parent / contract["capture"]["observerSourcePath"]
        copy_regular(observer_source, copied["observerSource"])
        copy_regular(Path(evidence.__file__), copied["evaluator"])
        copy_regular(Path(__file__), copied["runner"])
        copy_regular(candidate_archive, copied["candidateArchive"])
        if xcode_mode:
            copy_regular(xcode_info, copied["xcodeArchiveInfo"])
            copy_regular(xcode_log, copied["notaryLog"])
        else:
            copy_regular(submitted_source, copied["submittedArchive"])

        fixed_xcrun = safe_executable(Path(contract["tools"]["xcrun"]), "xcrun")
        fixed_ditto = safe_executable(Path(contract["tools"]["ditto"]), "ditto")
        stapler = xcrun_find(fixed_xcrun, "stapler")
        with tempfile.TemporaryDirectory(prefix=".mirmir-v4-notarized-smoke-apps-", dir=output.parent) as extraction_value:
            extraction = Path(extraction_value)
            candidate_app, app_executable, info = extract_archive(fixed_ditto, copied["candidateArchive"], extraction / "candidate")
            require(info.get("CFBundleIdentifier") == candidate["bundleIdentifier"], "extracted app bundle identifier mismatch")
            copy_regular(app_executable, copied["candidateExecutable"])
            created = utc_now()
            records: dict[str, Path] = {}
            def invoke(record_id: str, command: Sequence[str], timeout: int = 300, *, environment: Mapping[str, str] | None = None) -> dict[str, Any]:
                record, path = run_recorded(capture_root, record_id, command, timeout, environment=environment)
                records[record_id] = path
                return record

            if xcode_mode:
                xcodebuild = xcrun_find(fixed_xcrun, "xcodebuild")
                tools = tool_manifest(app_executable, contract, stapler, {"xcodebuild": xcodebuild})
                evidence.write_json(copied["toolManifest"], tools)
                export_root = extraction / "xcode-export"
                invoke(
                    "xcode_export_notarized_app",
                    [str(xcodebuild), "-exportNotarizedApp", "-archivePath", str(xcode_archive), "-exportPath", str(export_root)],
                )
                require(evidence.sha256_file(xcode_info) == evidence.sha256_file(copied["xcodeArchiveInfo"]), "Xcode archive receipt changed during export")
                require(evidence.sha256_file(xcode_log) == evidence.sha256_file(copied["notaryLog"]), "Xcode notarization log changed during export")
                submitted_app, submitted_executable, _ = validate_extracted_app(export_root)
                copied["submittedArchive"].parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                invoke(
                    "xcode_export_archive",
                    [str(fixed_ditto), "-c", "-k", "--sequesterRsrc", "--rsrc", "--keepParent", str(submitted_app), str(copied["submittedArchive"])],
                )
                require(copied["submittedArchive"].is_file() and not copied["submittedArchive"].is_symlink(), "ditto did not publish the Xcode exported-app archive")
                copied["submittedArchive"].chmod(0o600)
                submitted_archive_info = evidence.inspect_application_archive(copied["submittedArchive"])
                submission_record = {
                    "provider": "xcode_archive",
                    "id": submission_id,
                    "submittedArchiveName": evidence.load_json(copied["notaryLog"])["archiveFilename"],
                    "sourceArchivePath": str(xcode_archive),
                    "submissionRelativePath": f"Submissions/{submission_id.upper()}",
                }
            else:
                notarytool = xcrun_find(fixed_xcrun, "notarytool")
                tools = tool_manifest(app_executable, contract, stapler, {"notarytool": notarytool})
                evidence.write_json(copied["toolManifest"], tools)
                submitted_app, submitted_executable, _ = extract_archive(fixed_ditto, copied["submittedArchive"], extraction / "submitted")
                submitted_archive_info = evidence.inspect_application_archive(copied["submittedArchive"])
                profile = arguments.notary_keychain_profile
                invoke("notary_info", [str(notarytool), "info", submission_id, "--keychain-profile", profile, "--output-format", "json"])
                copied["notaryLog"].parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                invoke("notary_log", [str(notarytool), "log", submission_id, str(copied["notaryLog"]), "--keychain-profile", profile])
                require(copied["notaryLog"].is_file() and not copied["notaryLog"].is_symlink(), "notarytool did not publish its JSON log")
                copied["notaryLog"].chmod(0o600)
                submission_record = {
                    "provider": "notarytool",
                    "id": submission_id,
                    "submittedArchiveName": submitted_source.name,
                }
            require(candidate_archive_info["executableSHA256"] == submitted_archive_info["executableSHA256"], "submitted and stapled executables differ")
            require(evidence.sha256_file(submitted_executable) == candidate_archive_info["executableSHA256"], "exported app executable differs from candidate")

            codesign = tools["tools"]["codesign"]["path"]
            spctl = tools["tools"]["spctl"]["path"]
            invoke("gatekeeper_assessment", [spctl, "--assess", "--type", "execute", "--verbose=4", str(candidate_app)])
            invoke("stapled_ticket_validation", [str(stapler), "validate", "-v", str(candidate_app)])
            invoke("code_signature_validation", [codesign, "--verify", "--deep", "--strict", "--verbose=4", str(candidate_app)])
            invoke("code_signature_display", [codesign, "--display", "--verbose=4", str(candidate_app)])
            for architecture in contract["codeSigning"]["requiredArchitectures"]:
                invoke(f"code_signature_display_{architecture}", [codesign, "--display", "--verbose=4", "--arch", architecture, str(candidate_app)])
            invoke("code_signature_entitlements", [codesign, "--display", "--entitlements", "-", "--xml", str(candidate_app)])
            invoke("code_signature_requirements", [codesign, "--display", "--requirements", "-", str(candidate_app)])
            invoke("submitted_signature_display", [codesign, "--display", "--verbose=4", str(submitted_app)])
            for architecture in contract["codeSigning"]["requiredArchitectures"]:
                invoke(f"submitted_signature_display_{architecture}", [codesign, "--display", "--verbose=4", "--arch", architecture, str(submitted_app)])
            invoke("submitted_signature_requirements", [codesign, "--display", "--requirements", "-", str(submitted_app)])

            request_id = str(uuid.uuid4())
            nonce = secrets.token_hex(32)
            qualification_root = (
                Path.home()
                / "Library"
                / "Containers"
                / candidate["bundleIdentifier"]
                / "Data"
                / "Library"
                / "Application Support"
                / contract["capture"]["qualificationNamespace"]
                / request_id
            )
            require(not qualification_root.exists(), "qualification UUID root already exists")
            prepare_request = request_value("prepare", request_id, nonce, lane_sha, release_sha, candidate, candidate_archive_info["executableSHA256"], None)
            prepare_request_path = capture_root / "observer" / "prepare-request.json"
            write_compact(prepare_request_path, prepare_request)
            app_environment = dict(os.environ)
            app_environment["NSUnbufferedIO"] = "YES"
            prepare_record = invoke(
                "observer_prepare",
                [str(app_executable), "--mirmir-v4-notarized-smoke", base64.b64encode(prepare_request_path.read_bytes()).decode("ascii")],
                contract["capture"]["appInvocationTimeoutSeconds"],
                environment=app_environment,
            )
            prepare_result_bytes = observer_result(validate_path(capture_root, prepare_record["stdoutArtifact"]).read_bytes(), "prepare")
            prepare_result_path = capture_root / "observer" / "prepare-result.json"
            write_compact(prepare_result_path, evidence.load_json_bytes(prepare_result_bytes, "prepare observer result"))
            live_prepare_result = qualification_root / "prepare-result.json"
            require(live_prepare_result.is_file() and live_prepare_result.read_bytes() == prepare_result_bytes, "live prepare result differs from shipping-app stdout")
            phase_one_snapshot = snapshot_tree(qualification_root, capture_root / "observer" / "phase-one-sandbox", contract["capture"]["maximumSandboxEvidenceBytes"])

            phase_one_sha = evidence.sha256_file(live_prepare_result)
            recover_request = request_value("recover", request_id, nonce, lane_sha, release_sha, candidate, candidate_archive_info["executableSHA256"], phase_one_sha)
            recover_request_path = capture_root / "observer" / "recover-request.json"
            write_compact(recover_request_path, recover_request)
            recover_record = invoke(
                "observer_recover",
                [str(app_executable), "--mirmir-v4-notarized-smoke", base64.b64encode(recover_request_path.read_bytes()).decode("ascii")],
                contract["capture"]["appInvocationTimeoutSeconds"],
                environment=app_environment,
            )
            recover_result_bytes = observer_result(validate_path(capture_root, recover_record["stdoutArtifact"]).read_bytes(), "recover")
            recover_result_path = capture_root / "observer" / "recover-result.json"
            write_compact(recover_result_path, evidence.load_json_bytes(recover_result_bytes, "recover observer result"))
            live_recover_result = qualification_root / "recover-result.json"
            require(live_recover_result.is_file() and live_recover_result.read_bytes() == recover_result_bytes, "live recover result differs from shipping-app stdout")
            final_snapshot = snapshot_tree(qualification_root, capture_root / "observer" / "final-sandbox", contract["capture"]["maximumSandboxEvidenceBytes"])
            finished = utc_now()

            artifact_descriptors = {name: evidence.descriptor(path, capture_root) for name, path in copied.items()}
            record_descriptors = {record_id: evidence.descriptor(path, capture_root) for record_id, path in records.items()}
            raw_capture = {
                "schemaVersion": evidence.CAPTURE_SCHEMA,
                "suiteID": contract["suiteID"],
                "createdAtUTC": created,
                "finishedAtUTC": finished,
                "laneContractSHA256": lane_sha,
                "releaseContractSHA256": release_sha,
                "candidate": candidate,
                "identities": {
                    "observerSourceSHA256": evidence.sha256_file(copied["observerSource"]),
                    "evaluatorSHA256": evidence.sha256_file(copied["evaluator"]),
                    "runnerSHA256": evidence.sha256_file(copied["runner"]),
                    "applicationExecutableSHA256": evidence.sha256_file(copied["candidateExecutable"]),
                    "submittedArchiveSHA256": evidence.sha256_file(copied["submittedArchive"]),
                    "candidateArchiveSHA256": evidence.sha256_file(copied["candidateArchive"]),
                    "toolManifestSHA256": evidence.sha256_file(copied["toolManifest"]),
                },
                "notarySubmission": submission_record,
                "artifacts": artifact_descriptors,
                "commandRecords": record_descriptors,
                "observerInvocations": [
                    {
                        "phase": "prepare",
                        "commandRecord": record_descriptors["observer_prepare"],
                        "requestArtifact": evidence.descriptor(prepare_request_path, capture_root),
                        "resultArtifact": evidence.descriptor(prepare_result_path, capture_root),
                        "sandboxSnapshot": phase_one_snapshot,
                    },
                    {
                        "phase": "recover",
                        "commandRecord": record_descriptors["observer_recover"],
                        "requestArtifact": evidence.descriptor(recover_request_path, capture_root),
                        "resultArtifact": evidence.descriptor(recover_result_path, capture_root),
                        "sandboxSnapshot": final_snapshot,
                    },
                ],
            }
            capture_path = capture_root / "capture.json"
            evidence.write_json(capture_path, raw_capture)
            evidence.evaluate(capture_path, staging, contract_path, release_contract_path)
            evidence.verify(staging / "report.json", capture_path, contract_path, release_contract_path)
            safe_remove_qualification_root(qualification_root, candidate["bundleIdentifier"], request_id)
            qualification_root = None
        staging.rename(output)
        completed = True
        return output / "report.json"
    finally:
        if qualification_root is not None:
            try:
                safe_remove_qualification_root(qualification_root, candidate["bundleIdentifier"], qualification_root.name)
            except (OSError, ValueError):
                pass
        if not completed and staging.exists():
            staging.rename(failed)
            print(f"incomplete fail-closed capture retained at {failed}", file=sys.stderr)


def validate_path(root: Path, artifact: Any) -> Path:
    return evidence.validate_artifact(root, artifact, "runner command output")


SCRIPT_DIRECTORY = Path(__file__).resolve().parent


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--application-archive", type=Path, required=True, help="exact stapled archive identified by candidate.appBundleSHA256")
    parser.add_argument("--submitted-archive", type=Path, help="exact pre-staple archive accepted by Apple (notarytool provider)")
    parser.add_argument("--notary-submission-id", help="accepted notarytool submission UUID")
    parser.add_argument("--notary-keychain-profile", help="notarytool Keychain profile")
    parser.add_argument("--xcode-archive", type=Path, help="Xcode archive containing an accepted Developer ID submission receipt")
    parser.add_argument("--xcode-submission-id", help="optional submission UUID when the Xcode archive contains more than one submission")
    parser.add_argument("--release-contract", type=Path, required=True)
    parser.add_argument("--contract", type=Path, default=SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    report = capture(parse_arguments())
    print(report)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (NotarizedSmokeCaptureError, evidence.NotarizedSmokeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"notarized smoke capture failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
