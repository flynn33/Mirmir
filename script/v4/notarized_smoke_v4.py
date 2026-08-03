#!/usr/bin/env python3
"""Fail-closed evaluator for the notarized Mirmir application smoke lane.

The capture runner only records external work.  This module independently
reopens the exact application archives, command transcripts, app-observer
requests/results, and both sandbox snapshots.  It then emits the ten M7
external-execution attestations and can replay the entire sealed suite without
executing or trusting the runner summary.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import sys
from typing import Any, Iterable, Mapping, Sequence
import uuid
import zipfile


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "notarized-smoke-contract-v1.json"
CAPTURE_SCHEMA = "mirmir-ash-v4-notarized-smoke-capture-v1"
CONTRACT_SCHEMA = "mirmir-ash-v4-notarized-smoke-contract-v1"
PROCESS_SCHEMA = "mirmir-ash-v4-notarized-smoke-process-record-v1"
REQUEST_SCHEMA = "mirmir-ash-v4-notarized-smoke-request-v1"
OBSERVER_RESULT_SCHEMA = "mirmir-ash-v4-notarized-smoke-observer-result-v1"
PHASE_ONE_STATE_SCHEMA = "mirmir-ash-v4-notarized-smoke-phase-one-state-v1"
REPORT_SCHEMA = "mirmir-ash-v4-notarized-smoke-report-v1"
ATTESTATION_SCHEMA = "mirmir-ash-v4-external-execution-evidence-v1"
TRANSCRIPT_SCHEMA = "mirmir-ash-v4-notarized-smoke-action-transcript-v1"
REPLAY_SCHEMA = "mirmir-ash-v4-notarized-smoke-replay-receipt-v1"
SEALED_SCHEMA = "mirmir-ash-v4-notarized-smoke-sealed-manifest-v1"
TOOL_SCHEMA = "mirmir-ash-v4-notarized-smoke-tool-identities-v1"
TREE_DOMAIN = b"mirmir-notarized-smoke-tree-v1\0"
MANIFEST_DOMAIN = b"ash-p06-runtime-manifest-v4\0"
HEX = frozenset("0123456789abcdef")
CANDIDATE_FIELDS = {
    "sourceCommit",
    "sourceTreeIdentitySHA256",
    "runtimeManifestSHA256",
    "runtimeManifestFileSHA256",
    "runtimeArtifactSetSHA256",
    "runtimeSourceRevision",
    "releaseConfigurationSHA256",
    "appBundleSHA256",
    "bundleIdentifier",
    "productVersion",
    "productBuild",
}
PROCESS_KEYS = {
    "schemaVersion",
    "id",
    "command",
    "invocationSHA256",
    "executablePath",
    "executableSHA256",
    "startedAtUTC",
    "finishedAtUTC",
    "exitStatus",
    "stdoutArtifact",
    "stderrArtifact",
}


class NotarizedSmokeError(ValueError):
    """The supplied capture cannot be admitted as release evidence."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise NotarizedSmokeError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(token: str) -> Any:
    raise NotarizedSmokeError(f"non-finite JSON number: {token}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise NotarizedSmokeError(f"cannot read JSON {path}: {error}") from error


def load_json_bytes(value: bytes, label: str) -> Any:
    try:
        return json.loads(
            value.decode("utf-8"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise NotarizedSmokeError(f"cannot decode {label}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def pretty_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(pretty_bytes(value))
    path.chmod(0o600)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise NotarizedSmokeError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise NotarizedSmokeError(message)


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be Boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be integer >= {minimum}")
    return value


def require_number(value: Any, label: str, *, positive: bool = False) -> float:
    require(not isinstance(value, bool) and isinstance(value, (int, float)), f"{label} must be numeric")
    result = float(value)
    require(math.isfinite(result), f"{label} must be finite")
    if positive:
        require(result > 0, f"{label} must be positive")
    return result


def require_hex(value: Any, lengths: int | Sequence[int], label: str) -> str:
    text = require_string(value, label)
    accepted = (lengths,) if isinstance(lengths, int) else tuple(lengths)
    require(len(text) in accepted and all(character in HEX for character in text), f"{label} is not lowercase hexadecimal")
    return text


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, extra={sorted(actual-expected_set)}",
    )


def parse_utc(value: Any, label: str) -> datetime:
    text = require_string(value, label)
    require(text.endswith("Z"), f"{label} must use UTC Z notation")
    try:
        result = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise NotarizedSmokeError(f"{label} is not ISO-8601 UTC") from error
    require(result.tzinfo is not None and result.utcoffset() == timezone.utc.utcoffset(result), f"{label} is not UTC")
    return result


def checked_relative(value: Any, label: str) -> PurePosixPath:
    text = require_string(value, label)
    require("\\" not in text, f"{label} uses a noncanonical separator")
    pure = PurePosixPath(text)
    require(
        not pure.is_absolute()
        and pure.parts
        and all(part not in {"", ".", ".."} for part in pure.parts),
        f"{label} escapes its evidence root",
    )
    return pure


def checked_file(root: Path, relative: Any, label: str) -> Path:
    pure = checked_relative(relative, label)
    root = root.resolve(strict=True)
    lexical = root.joinpath(*pure.parts)
    current = lexical
    while current != root:
        require(not current.is_symlink(), f"{label} traverses a symbolic link")
        current = current.parent
    try:
        resolved = lexical.resolve(strict=True)
    except OSError as error:
        raise NotarizedSmokeError(f"{label} is missing") from error
    require(root in resolved.parents, f"{label} escapes its evidence root")
    metadata = resolved.stat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1, f"{label} is not a single-link regular file")
    return resolved


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    base = root.resolve(strict=True)
    require(base in resolved.parents, f"artifact is outside suite: {resolved}")
    return {
        "path": resolved.relative_to(base).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_artifact(root: Path, value: Any, label: str) -> Path:
    artifact = require_mapping(value, label)
    require_exact_keys(artifact, {"path", "byteCount", "sha256"}, label)
    path = checked_file(root, artifact["path"], f"{label}.path")
    require(path.stat().st_size == require_integer(artifact["byteCount"], f"{label}.byteCount"), f"{label} byte count mismatch")
    require(sha256_file(path) == require_hex(artifact["sha256"], 64, f"{label}.sha256"), f"{label} SHA-256 mismatch")
    return path


def tree_identity(root: Path, maximum_bytes: int) -> tuple[str, int, int]:
    root = root.resolve(strict=True)
    require(root.is_dir() and not root.is_symlink(), "tree root must be a directory")
    digest = hashlib.sha256(TREE_DOMAIN)
    byte_count = 0
    file_count = 0
    entries: list[Path] = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        names.sort()
        files.sort()
        for name in [*names, *files]:
            entries.append(directory_path / name)
    entries.sort(key=lambda path: path.relative_to(root).as_posix())
    seen_inodes: set[tuple[int, int]] = set()
    for path in entries:
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        require(not stat.S_ISLNK(metadata.st_mode), f"tree contains symlink: {relative}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if stat.S_ISDIR(metadata.st_mode):
            digest.update(b"directory\n")
            continue
        require(stat.S_ISREG(metadata.st_mode), f"tree contains special file: {relative}")
        inode = (metadata.st_dev, metadata.st_ino)
        require(metadata.st_nlink == 1 and inode not in seen_inodes, f"tree contains a hard-linked file: {relative}")
        seen_inodes.add(inode)
        byte_count += metadata.st_size
        file_count += 1
        require(byte_count <= maximum_bytes, "tree exceeds capture byte bound")
        digest.update(b"file\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest(), byte_count, file_count


def validate_tree_artifact(root: Path, value: Any, maximum_bytes: int, label: str) -> Path:
    item = require_mapping(value, label)
    require_exact_keys(item, {"path", "byteCount", "fileCount", "treeSHA256"}, label)
    pure = checked_relative(item["path"], f"{label}.path")
    base = root.resolve(strict=True)
    path = base.joinpath(*pure.parts)
    current = path
    while current != base:
        require(not current.is_symlink(), f"{label} traverses a symbolic link")
        current = current.parent
    path = path.resolve(strict=True)
    require(base in path.parents and path.is_dir() and not path.is_symlink(), f"{label} is not a safe directory")
    identity, byte_count, file_count = tree_identity(path, maximum_bytes)
    require(identity == require_hex(item["treeSHA256"], 64, f"{label}.treeSHA256"), f"{label} tree identity mismatch")
    require(byte_count == require_integer(item["byteCount"], f"{label}.byteCount"), f"{label} byte count mismatch")
    require(file_count == require_integer(item["fileCount"], f"{label}.fileCount", 1), f"{label} file count mismatch")
    return path


def validate_candidate(value: Any) -> dict[str, Any]:
    candidate = require_mapping(value, "candidate")
    require_exact_keys(candidate, CANDIDATE_FIELDS, "candidate")
    require_hex(candidate["sourceCommit"], 40, "candidate.sourceCommit")
    require_hex(candidate["runtimeSourceRevision"], (40, 64), "candidate.runtimeSourceRevision")
    for key in CANDIDATE_FIELDS - {
        "sourceCommit",
        "runtimeSourceRevision",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }:
        require_hex(candidate[key], 64, f"candidate.{key}")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate


def inspect_application_archive(path: Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), "application archive is not a regular file")
    try:
        with zipfile.ZipFile(path) as archive:
            names: set[str] = set()
            total = 0
            info_entries: list[zipfile.ZipInfo] = []
            for entry in archive.infolist():
                pure = checked_relative(entry.filename.rstrip("/"), "application archive entry")
                require(entry.filename not in names, f"application archive repeats {entry.filename}")
                names.add(entry.filename)
                require(entry.flag_bits & 0x1 == 0, "application archive contains encrypted data")
                mode = (entry.external_attr >> 16) & 0o177777
                file_type = stat.S_IFMT(mode)
                require(file_type in (0, stat.S_IFREG, stat.S_IFDIR), f"application archive contains a link or special entry: {entry.filename}")
                total += entry.file_size
                require(total <= 4 * 1024 * 1024 * 1024, "application archive expands beyond 4 GiB")
                if len(pure.parts) == 3 and pure.parts[0].endswith(".app") and pure.parts[1:] == ("Contents", "Info.plist"):
                    info_entries.append(entry)
            require(len(info_entries) == 1, "application archive must contain one top-level app")
            info_entry = info_entries[0]
            top = PurePosixPath(info_entry.filename).parts[0]
            plist = plistlib.loads(archive.read(info_entry))
            require(isinstance(plist, dict), "application Info.plist is not a dictionary")
            executable_name = require_string(plist.get("CFBundleExecutable"), "CFBundleExecutable")
            executable_path = f"{top}/Contents/MacOS/{executable_name}"
            require(executable_path in names, "application executable is absent from archive")
            executable_bytes = archive.read(executable_path)
            runtime_path = f"{top}/Contents/Resources/ASH-P06.bundle/runtime-manifest.json"
            require(runtime_path in names, "application archive omits the P06 runtime manifest")
            manifest_bytes = archive.read(runtime_path)
            manifest = require_mapping(load_json_bytes(manifest_bytes, "embedded P06 manifest"), "embedded P06 manifest")
            require(canonical_bytes(manifest) == manifest_bytes, "embedded P06 runtime manifest is not canonical")
    except (OSError, zipfile.BadZipFile, KeyError, plistlib.InvalidFileException) as error:
        raise NotarizedSmokeError(f"cannot inspect application archive: {error}") from error
    return {
        "archiveSHA256": sha256_file(path),
        "topLevelApp": top,
        "bundleIdentifier": require_string(plist.get("CFBundleIdentifier"), "CFBundleIdentifier"),
        "productVersion": require_string(plist.get("CFBundleShortVersionString"), "CFBundleShortVersionString"),
        "productBuild": require_string(plist.get("CFBundleVersion"), "CFBundleVersion"),
        "executableName": executable_name,
        "executableSHA256": sha256_bytes(executable_bytes),
        "runtimeManifestFileSHA256": sha256_bytes(manifest_bytes),
        "runtimeManifestSHA256": sha256_bytes(MANIFEST_DOMAIN + canonical_bytes(manifest)),
        "runtimeID": manifest.get("runtimeID"),
        "releaseStatus": manifest.get("releaseStatus"),
    }


def validate_contract(contract_path: Path, release_contract_path: Path) -> tuple[dict[str, Any], str, str]:
    contract = require_mapping(load_json(contract_path), "notarized smoke contract")
    require(contract.get("schemaVersion") == CONTRACT_SCHEMA, "unsupported notarized smoke contract")
    release_contract = require_mapping(load_json(release_contract_path), "release qualification contract")
    require(release_contract.get("schemaVersion") == "mirmir-ash-v4-release-qualification-contract-v1", "unsupported release contract")
    require(contract.get("suiteID") == "mirmir-ash-v4-notarized-smoke-v1", "unsupported notarized smoke suite")
    actions = require_list(contract.get("actions"), "contract.actions")
    require(len(actions) == 10, "contract must contain exactly ten smoke actions")
    action_ids = [require_string(require_mapping(item, "contract action").get("id"), "contract action.id") for item in actions]
    require(len(action_ids) == len(set(action_ids)), "contract repeats an action")
    require(action_ids == release_contract.get("notarizedSmokeActions"), "lane and release action order differ")
    release_kinds = require_mapping(release_contract.get("notarizedSmokeEvidenceKinds"), "release smoke evidence kinds")
    for item in actions:
        require(release_kinds.get(item["id"]) == item.get("evidenceKind"), f"evidence kind differs for {item['id']}")
    capture = require_mapping(contract.get("capture"), "contract.capture")
    observer = SCRIPT_DIRECTORY.parent.parent / require_string(capture.get("observerSourcePath"), "capture.observerSourcePath")
    expected_sources = {
        "observerSourceSHA256": observer,
        "evaluatorSHA256": Path(__file__).resolve(),
        "runnerSHA256": SCRIPT_DIRECTORY / "run_notarized_smoke_v4.py",
    }
    for key, source in expected_sources.items():
        require(source.is_file() and not source.is_symlink(), f"locked source is missing: {source}")
        require(sha256_file(source) == require_hex(capture.get(key), 64, f"capture.{key}"), f"locked source identity differs: {key}")
    return contract, sha256_file(contract_path), sha256_file(release_contract_path)


def validate_process_record(
    capture_root: Path,
    value: Any,
    expected_id: str,
    capture_start: datetime,
    capture_finish: datetime,
) -> dict[str, Any]:
    record = require_mapping(value, f"process record {expected_id}")
    require_exact_keys(record, PROCESS_KEYS, f"process record {expected_id}")
    require(record["schemaVersion"] == PROCESS_SCHEMA and record["id"] == expected_id, f"process record identity mismatch: {expected_id}")
    command = require_list(record["command"], f"{expected_id}.command")
    require(command and all(isinstance(item, str) and item for item in command), f"{expected_id} command is invalid")
    require(record["invocationSHA256"] == sha256_bytes(canonical_bytes(command)), f"{expected_id} invocation SHA-256 mismatch")
    executable_path = require_string(record["executablePath"], f"{expected_id}.executablePath")
    require(command[0] == executable_path, f"{expected_id} executable differs from command")
    require_hex(record["executableSHA256"], 64, f"{expected_id}.executableSHA256")
    started = parse_utc(record["startedAtUTC"], f"{expected_id}.startedAtUTC")
    finished = parse_utc(record["finishedAtUTC"], f"{expected_id}.finishedAtUTC")
    require(capture_start <= started <= finished <= capture_finish, f"{expected_id} time interval is outside capture")
    require(require_integer(record["exitStatus"], f"{expected_id}.exitStatus") == 0, f"{expected_id} external process failed")
    stdout_path = validate_artifact(capture_root, record["stdoutArtifact"], f"{expected_id}.stdoutArtifact")
    stderr_path = validate_artifact(capture_root, record["stderrArtifact"], f"{expected_id}.stderrArtifact")
    return {**record, "_started": started, "_finished": finished, "_stdout": stdout_path, "_stderr": stderr_path}


def decode_plist_output(value: bytes, label: str) -> dict[str, Any]:
    start = value.find(b"<?xml")
    finish = value.rfind(b"</plist>")
    require(start >= 0 and finish >= start, f"{label} contains no XML property list")
    try:
        result = plistlib.loads(value[start : finish + len(b"</plist>")])
    except plistlib.InvalidFileException as error:
        raise NotarizedSmokeError(f"{label} contains an invalid property list") from error
    return require_mapping(result, label)


def output_bytes(record: Mapping[str, Any]) -> bytes:
    return record["_stdout"].read_bytes() + b"\n" + record["_stderr"].read_bytes()


def parse_notary_evidence(
    records: Mapping[str, Mapping[str, Any]],
    notary_log_path: Path,
    submitted_identity: str,
    submission: Mapping[str, Any],
    maximum_age: int,
    capture_finish: datetime,
) -> dict[str, Any]:
    info = require_mapping(load_json_bytes(records["notary_info"]["_stdout"].read_bytes(), "notarytool info output"), "notarytool info output")
    log = require_mapping(load_json(notary_log_path), "notarytool log")
    submission_id = require_string(submission.get("id"), "notarySubmission.id")
    try:
        require(str(uuid.UUID(submission_id)).lower() == submission_id.lower(), "notary submission ID is noncanonical")
    except ValueError as error:
        raise NotarizedSmokeError("notary submission ID is not a UUID") from error
    require(str(info.get("id", "")).lower() == submission_id.lower(), "notary info belongs to another submission")
    require(str(log.get("jobId", log.get("id", ""))).lower() == submission_id.lower(), "notary log belongs to another submission")
    require(str(info.get("status", "")).lower() == "accepted", "Apple notary submission was not accepted")
    require(str(log.get("status", "")).lower() == "accepted" and log.get("statusCode") == 0, "Apple notary log is not accepted")
    require(log.get("issues") in (None, []), "Apple notary log contains issues")
    log_sha = require_string(log.get("sha256"), "notary log.sha256").lower()
    require(log_sha == submitted_identity, "Apple notary log SHA-256 differs from submitted archive")
    archive_name = require_string(submission.get("submittedArchiveName"), "notarySubmission.submittedArchiveName")
    require(log.get("archiveFilename") == archive_name, "Apple notary log archive filename mismatch")
    date_value = info.get("createdDate", log.get("uploadDate"))
    submitted_at = parse_utc(date_value, "notary submission date")
    age = (capture_finish - submitted_at).total_seconds()
    require(-300 <= age <= maximum_age, "notary acceptance is stale or future-dated")
    return {"submissionID": submission_id.lower(), "submittedAtUTC": date_value, "archiveSHA256": log_sha, "status": "Accepted", "issueCount": 0}


def validate_codesign_evidence(records: Mapping[str, Mapping[str, Any]], contract: Mapping[str, Any], candidate: Mapping[str, Any]) -> dict[str, Any]:
    signing = require_mapping(contract.get("codeSigning"), "contract.codeSigning")
    display = output_bytes(records["code_signature_display"]).decode("utf-8", errors="replace")
    submitted_display = output_bytes(records["submitted_signature_display"]).decode("utf-8", errors="replace")
    requirements = records["code_signature_requirements"]["_stdout"].read_text(encoding="utf-8", errors="replace")
    submitted_requirements = records["submitted_signature_requirements"]["_stdout"].read_text(encoding="utf-8", errors="replace")
    verify = output_bytes(records["code_signature_validation"]).decode("utf-8", errors="replace")
    required_team = require_string(signing.get("requiredTeamIdentifier"), "codeSigning.requiredTeamIdentifier")
    required_certificate = require_string(signing.get("requiredCertificateClass"), "codeSigning.requiredCertificateClass")
    require("invalid" not in verify.lower() and "failed" not in verify.lower(), "codesign verification transcript reports failure")
    require(f"Identifier={candidate['bundleIdentifier']}" in display, "codesign identifier mismatch")
    require(f"TeamIdentifier={required_team}" in display, "codesign team identifier mismatch")
    require(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)", display, re.IGNORECASE) is not None, "hardened runtime flag is absent")
    require(f"Authority={required_certificate}:" in display, "Developer ID certificate class is absent")
    require("Timestamp=" in display and "Timestamp=none" not in display, "secure signing timestamp is absent")
    cdhash = re.search(r"^CDHash=([0-9a-fA-F]+)$", display, re.MULTILINE)
    submitted_cdhash = re.search(r"^CDHash=([0-9a-fA-F]+)$", submitted_display, re.MULTILINE)
    require(cdhash is not None and submitted_cdhash is not None and cdhash.group(1).lower() == submitted_cdhash.group(1).lower(), "submitted and stapled code-directory hashes differ")
    require(f'identifier "{candidate["bundleIdentifier"]}"' in requirements, "designated requirement bundle identifier mismatch")
    require("anchor apple generic" in requirements and required_team in requirements, "designated requirement trust chain/team mismatch")
    require(requirements.strip() == submitted_requirements.strip(), "submitted and stapled designated requirements differ")
    entitlements = decode_plist_output(output_bytes(records["code_signature_entitlements"]), "codesign entitlements")
    required_entitlements = require_list(signing.get("requiredEntitlements"), "codeSigning.requiredEntitlements")
    require(required_entitlements, "code-signing entitlement contract is empty")
    for entitlement in required_entitlements:
        key = require_string(entitlement, "required code-signing entitlement")
        require(entitlements.get(key) is True, f"required entitlement is absent: {key}")
    require(entitlements.get(signing["forbiddenEntitlement"]) in (None, False), "get-task-allow entitlement is forbidden")
    return {"cdHash": cdhash.group(1).lower(), "teamIdentifier": required_team, "certificateClass": required_certificate, "hardenedRuntime": True, "secureTimestamp": True, "sandboxed": True, "applicationScopedBookmarks": True, "getTaskAllow": False}


def validate_system_acceptance(records: Mapping[str, Mapping[str, Any]]) -> dict[str, bool]:
    gatekeeper = output_bytes(records["gatekeeper_assessment"]).decode("utf-8", errors="replace").lower()
    stapler = output_bytes(records["stapled_ticket_validation"]).decode("utf-8", errors="replace").lower()
    require("accepted" in gatekeeper and "notarized developer id" in gatekeeper, "Gatekeeper did not accept a notarized Developer ID application")
    require("validate action worked" in stapler and "ticket" in stapler, "stapler did not validate the ticket")
    return {"gatekeeperAccepted": True, "ticketStapled": True}


def require_canonical_compact_json(path: Path, label: str) -> dict[str, Any]:
    raw = path.read_bytes()
    value = require_mapping(load_json_bytes(raw, label), label)
    require(raw == canonical_bytes(value), f"{label} is not canonical compact JSON")
    return value


def validate_smoke_artifact(snapshot: Path, value: Any, label: str) -> Path:
    artifact = require_mapping(value, label)
    require_exact_keys(artifact, {"path", "byteCount", "sha256"}, label)
    path = checked_file(snapshot, artifact["path"], f"{label}.path")
    require(path.stat().st_size == require_integer(artifact["byteCount"], f"{label}.byteCount"), f"{label} byte count mismatch")
    require(sha256_file(path) == require_hex(artifact["sha256"], 64, f"{label}.sha256"), f"{label} SHA-256 mismatch")
    return path


def validate_process_identity(value: Any, request: Mapping[str, Any], request_id: str) -> dict[str, Any]:
    process = require_mapping(value, "observer process identity")
    keys = {"bundleIdentifier", "productVersion", "productBuild", "bundlePath", "executablePath", "executableSHA256", "processID", "parentProcessID", "sandboxDataPath", "applicationSupportPath", "qualificationRootPath"}
    require_exact_keys(process, keys, "observer process identity")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require(process[key] == request[key], f"observer {key} mismatch")
    require(process["executableSHA256"] == request["expectedExecutableSHA256"], "observer executable identity mismatch")
    require_integer(process["processID"], "observer processID", 1)
    require_integer(process["parentProcessID"], "observer parentProcessID", 1)
    expected_suffix = f"/Library/Containers/{request['bundleIdentifier']}/Data"
    require(process["sandboxDataPath"].endswith(expected_suffix), "observer did not execute in its app sandbox")
    require(process["applicationSupportPath"] == process["sandboxDataPath"] + "/Library/Application Support", "observer application-support path escaped sandbox")
    qualification = process["applicationSupportPath"] + f"/MirmirQualificationV4/notarized-smoke/{request_id}"
    require(process["qualificationRootPath"] == qualification, "observer qualification root is not uniquely isolated")
    require(process["executablePath"].startswith(process["bundlePath"] + "/Contents/MacOS/"), "observer executable escaped application bundle")
    return process


def validate_runtime(value: Any, candidate: Mapping[str, Any], contract: Mapping[str, Any]) -> dict[str, Any]:
    runtime = require_mapping(value, "observer runtime")
    keys = {"runtimeID", "releaseStatus", "manifestSHA256", "manifestFileSHA256", "sourceRevision", "builderSourceSHA256", "artifactCount", "runtimeBundlePath", "trustRootConfigured"}
    require_exact_keys(runtime, keys, "observer runtime")
    candidate_contract = require_mapping(contract.get("candidate"), "contract.candidate")
    require(runtime["runtimeID"] == candidate_contract["requiredRuntimeID"], "observer loaded another runtime ID")
    require(runtime["releaseStatus"] == candidate_contract["requiredRuntimeStatus"], "observer loaded a non-release runtime")
    require(runtime["manifestSHA256"] == candidate["runtimeManifestSHA256"], "observer runtime semantic identity mismatch")
    require(runtime["manifestFileSHA256"] == candidate["runtimeManifestFileSHA256"], "observer runtime file identity mismatch")
    require(runtime["sourceRevision"] == candidate["runtimeSourceRevision"], "observer runtime source revision mismatch")
    require_hex(runtime["builderSourceSHA256"], 64, "runtime.builderSourceSHA256")
    require_integer(runtime["artifactCount"], "runtime.artifactCount", 1)
    require_bool(runtime["trustRootConfigured"], "runtime.trustRootConfigured", True)
    require(runtime["runtimeBundlePath"].endswith("/Contents/Resources/ASH-P06.bundle"), "observer runtime is not the bundled production P06")
    return runtime


def validate_semantic(value: Any, label: str, width: int, height: int, frames: int = 12) -> dict[str, Any]:
    semantic = require_mapping(value, label)
    keys = {"encodedWidth", "encodedHeight", "frameCount", "enabledVideoTrackCount", "durationValue", "durationTimescale", "timingSHA256", "visiblePixelSHA256"}
    require_exact_keys(semantic, keys, label)
    require(semantic["encodedWidth"] == width and semantic["encodedHeight"] == height, f"{label} raster mismatch")
    require(semantic["frameCount"] == frames and semantic["enabledVideoTrackCount"] == 1, f"{label} frame/track count mismatch")
    require_integer(semantic["durationValue"], f"{label}.durationValue")
    require_integer(semantic["durationTimescale"], f"{label}.durationTimescale", 1)
    require_hex(semantic["timingSHA256"], 64, f"{label}.timingSHA256")
    require_hex(semantic["visiblePixelSHA256"], 64, f"{label}.visiblePixelSHA256")
    return semantic


def decode_observer_invocation(
    capture_root: Path,
    invocation: Mapping[str, Any],
    record: Mapping[str, Any],
    snapshot: Path,
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    lane_sha: str,
    release_sha: str,
) -> dict[str, Any]:
    require_exact_keys(invocation, {"phase", "commandRecord", "requestArtifact", "resultArtifact", "sandboxSnapshot"}, "observer invocation")
    phase = require_string(invocation["phase"], "observer invocation.phase")
    require(phase in {"prepare", "recover"}, "observer phase is invalid")
    request_path = validate_artifact(capture_root, invocation["requestArtifact"], f"observer {phase} request")
    result_path = validate_artifact(capture_root, invocation["resultArtifact"], f"observer {phase} result")
    request_bytes = request_path.read_bytes()
    result_bytes = result_path.read_bytes()
    request = require_mapping(load_json_bytes(request_bytes, f"observer {phase} request"), f"observer {phase} request")
    result = require_mapping(load_json_bytes(result_bytes, f"observer {phase} result"), f"observer {phase} result")
    require(request_bytes == canonical_bytes(request), f"observer {phase} request is noncanonical")
    require(result_bytes == canonical_bytes(result), f"observer {phase} result is noncanonical")
    request_keys = {"schemaVersion", "phase", "requestID", "nonce", "generatedAtUTC", "laneContractSHA256", "releaseContractSHA256", "applicationArchiveSHA256", "sourceCommit", "bundleIdentifier", "productVersion", "productBuild", "runtimeManifestSHA256", "runtimeManifestFileSHA256", "expectedExecutableSHA256"}
    if phase == "recover":
        request_keys.add("phaseOneResultSHA256")
    require_exact_keys(request, request_keys, f"observer {phase} request")
    require(request["schemaVersion"] == REQUEST_SCHEMA and request["phase"] == phase, f"observer {phase} request schema/phase mismatch")
    request_id = require_string(request["requestID"], "observer requestID")
    try:
        require(str(uuid.UUID(request_id)) == request_id, "observer requestID is noncanonical")
    except ValueError as error:
        raise NotarizedSmokeError("observer requestID is not a UUID") from error
    require_hex(request["nonce"], 64, "observer nonce")
    require(request["laneContractSHA256"] == lane_sha and request["releaseContractSHA256"] == release_sha, "observer request contract identities mismatch")
    expected = {
        "applicationArchiveSHA256": candidate["appBundleSHA256"],
        "sourceCommit": candidate["sourceCommit"],
        "bundleIdentifier": candidate["bundleIdentifier"],
        "productVersion": candidate["productVersion"],
        "productBuild": candidate["productBuild"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": candidate["runtimeManifestFileSHA256"],
    }
    for key, value in expected.items():
        require(request[key] == value, f"observer request candidate mismatch: {key}")
    require_hex(request["expectedExecutableSHA256"], 64, "observer expected executable")
    command = record["command"]
    require(len(command) == 3 and command[1] == "--mirmir-v4-notarized-smoke", f"observer {phase} command is not the shipping-app observer")
    try:
        command_request = base64.b64decode(command[2], validate=True)
    except ValueError as error:
        raise NotarizedSmokeError(f"observer {phase} command request is invalid base64") from error
    require(command_request == request_bytes, f"observer {phase} command/request mismatch")
    generated = parse_utc(request["generatedAtUTC"], f"observer {phase} generatedAtUTC")
    require(-30 <= (record["_started"] - generated).total_seconds() <= 300, f"observer {phase} request was stale")
    prefix = b"MIRMIR_V4_NOTARIZED_SMOKE_RESULT "
    expected_stdout = prefix + base64.b64encode(result_bytes) + b"\n"
    require(record["_stdout"].read_bytes() == expected_stdout, f"observer {phase} stdout marker/result mismatch")
    result_keys = {
        "schemaVersion", "phase", "requestID", "requestSHA256", "applicationArchiveSHA256", "sourceCommit", "observedAtUTC", "resultFileName", "process", "runtime", "artifacts", "checks", "queue"
    }
    if phase == "prepare":
        result_keys |= {"mediaProbe", "inputSemantic", "deterministicProcess", "directOutputSemantic"}
    else:
        result_keys |= {"phaseOneResultSHA256", "resumedProcess", "referenceSemantic", "recoveredSemantic"}
    require_exact_keys(result, result_keys, f"observer {phase} result")
    require(result["schemaVersion"] == OBSERVER_RESULT_SCHEMA and result["phase"] == phase and result["requestID"] == request_id, f"observer {phase} result identity mismatch")
    require(result["requestSHA256"] == sha256_bytes(request_bytes), f"observer {phase} request seal mismatch")
    require(result["applicationArchiveSHA256"] == candidate["appBundleSHA256"] and result["sourceCommit"] == candidate["sourceCommit"], f"observer {phase} result candidate mismatch")
    require(result["resultFileName"] == f"{phase}-result.json", f"observer {phase} result filename mismatch")
    observed = parse_utc(result["observedAtUTC"], f"observer {phase} observedAtUTC")
    require(record["_started"] <= observed <= record["_finished"] + (record["_finished"] - record["_started"]), f"observer {phase} observed time is implausible")
    process = validate_process_identity(result["process"], request, request_id)
    runtime = validate_runtime(result["runtime"], candidate, contract)
    require(process["executableSHA256"] == record["executableSHA256"], f"observer {phase} process/launcher executable mismatch")
    snapshot_result = checked_file(snapshot, result["resultFileName"], f"observer {phase} sandbox result")
    require(snapshot_result.read_bytes() == result_bytes, f"observer {phase} sandbox result differs from stdout")
    snapshot_request = checked_file(snapshot, f"{phase}-request.json", f"observer {phase} sandbox request")
    require(snapshot_request.read_bytes() == request_bytes, f"observer {phase} sandbox request differs")
    required_checks = set(require_list(require_mapping(contract["requiredObserverChecks"], "requiredObserverChecks")[phase], f"required checks {phase}"))
    checks = require_mapping(result["checks"], f"observer {phase} checks")
    require(set(checks) == required_checks and all(value is True for value in checks.values()), f"observer {phase} checks are incomplete or false")
    return {"phase": phase, "request": request, "requestPath": request_path, "result": result, "resultPath": result_path, "process": process, "runtime": runtime, "snapshot": snapshot}


def validate_prepare_observation(observation: Mapping[str, Any], maximum_bytes: int) -> dict[str, Any]:
    result = observation["result"]
    snapshot = observation["snapshot"]
    probe = require_mapping(result["mediaProbe"], "media probe")
    probe_keys = {"encodedWidth", "encodedHeight", "codecFourCC", "durationValue", "durationTimescale", "estimatedFrameCount", "videoTrackCount", "audioTrackCount", "bitDepth", "bitDepthEvidence", "isFullRange", "rangeEvidence", "dynamicRange", "fieldCount", "fieldCountEvidence", "readable", "playable"}
    require_exact_keys(probe, probe_keys, "media probe")
    locked_probe = {"encodedWidth": 64, "encodedHeight": 48, "codecFourCC": "avc1", "estimatedFrameCount": 12, "videoTrackCount": 1, "audioTrackCount": 0, "bitDepth": 8, "isFullRange": False, "dynamicRange": "SDR", "fieldCount": 1, "readable": True, "playable": True}
    for key, value in locked_probe.items():
        require(probe[key] == value, f"real media probe mismatch: {key}")
    evidence_sources = {"format_description", "locked_h264_writer_contract"}
    for key in ("bitDepthEvidence", "rangeEvidence", "fieldCountEvidence"):
        require(probe[key] in evidence_sources, f"real media probe has unsupported fact provenance: {key}")
    require_integer(probe["durationValue"], "probe.durationValue", 1)
    require_integer(probe["durationTimescale"], "probe.durationTimescale", 1)
    input_semantic = validate_semantic(result["inputSemantic"], "input semantic", 64, 48)
    direct_semantic = validate_semantic(result["directOutputSemantic"], "direct output semantic", 96, 72)
    processing = require_mapping(result["deterministicProcess"], "deterministic process")
    require_exact_keys(processing, {"actualBackendID", "processedFrameCount", "encodedWidth", "encodedHeight", "outputCodec", "processingDurationSeconds"}, "deterministic process")
    require(processing["actualBackendID"] == "mirmirDeterministicCPU", "deterministic process did not use explicit CPU ASH")
    require(processing["processedFrameCount"] == 12 and processing["encodedWidth"] == 96 and processing["encodedHeight"] == 72 and processing["outputCodec"] == "h264", "deterministic process output contract mismatch")
    require_number(processing["processingDurationSeconds"], "deterministic process duration", positive=True)
    artifacts = require_mapping(result["artifacts"], "prepare artifacts")
    require_exact_keys(artifacts, {"input", "directOutput", "phaseOneState"}, "prepare artifacts")
    input_path = validate_smoke_artifact(snapshot, artifacts["input"], "prepare input artifact")
    direct_path = validate_smoke_artifact(snapshot, artifacts["directOutput"], "prepare direct artifact")
    state_path = validate_smoke_artifact(snapshot, artifacts["phaseOneState"], "prepare state artifact")
    require(input_path.suffix == ".mov" and direct_path.suffix == ".mov", "prepare media artifacts are not movies")
    state = require_canonical_compact_json(state_path, "phase-one state")
    state_keys = {"schemaVersion", "requestID", "nonceSHA256", "requestSHA256", "applicationArchiveSHA256", "sourceCommit", "executableSHA256", "runtimeManifestSHA256", "runtimeManifestFileSHA256", "jobID", "inputArtifact", "inputSemantic", "directOutputArtifact", "directOutputSemantic", "queueTreeSHA256"}
    require_exact_keys(state, state_keys, "phase-one state")
    request = observation["request"]
    require(state["schemaVersion"] == PHASE_ONE_STATE_SCHEMA and state["requestID"] == request["requestID"], "phase-one state identity mismatch")
    require(state["nonceSHA256"] == sha256_bytes(request["nonce"].encode("utf-8")), "phase-one nonce seal mismatch")
    require(state["requestSHA256"] == result["requestSHA256"], "phase-one request seal mismatch")
    for key in ("applicationArchiveSHA256", "sourceCommit", "runtimeManifestSHA256", "runtimeManifestFileSHA256"):
        require(state[key] == request[key], f"phase-one state request mismatch: {key}")
    require(state["executableSHA256"] == request["expectedExecutableSHA256"], "phase-one executable mismatch")
    require(state["inputArtifact"] == artifacts["input"] and state["directOutputArtifact"] == artifacts["directOutput"], "phase-one artifact descriptors mismatch")
    require(state["inputSemantic"] == input_semantic and state["directOutputSemantic"] == direct_semantic, "phase-one semantic state mismatch")
    queue = require_mapping(result["queue"], "prepare queue")
    require_exact_keys(queue, {"jobID", "lifecycle", "checkpointRelatedFileCount", "queueTreeSHA256"}, "prepare queue")
    require(queue["lifecycle"] == "paused" and require_integer(queue["checkpointRelatedFileCount"], "checkpoint file count", 1) > 0, "prepare queue has no durable paused checkpoint")
    require(state["jobID"] == queue["jobID"] and state["queueTreeSHA256"] == queue["queueTreeSHA256"], "prepare queue/state identity mismatch")
    queue_root = snapshot / "workflow-queue-v4"
    queue_sha, _, _ = tree_identity(queue_root, maximum_bytes)
    require(queue_sha == queue["queueTreeSHA256"], "prepare queue tree seal mismatch")
    require(not (snapshot / "media" / "recovered.mov").exists(), "prepare phase published a final recovered output")
    return {"inputSemantic": input_semantic, "directSemantic": direct_semantic, "state": state, "queue": queue, "stateSHA256": sha256_file(state_path)}


def validate_recover_observation(observation: Mapping[str, Any], prepare: Mapping[str, Any], maximum_bytes: int) -> dict[str, Any]:
    result = observation["result"]
    snapshot = observation["snapshot"]
    request = observation["request"]
    prepare_request = prepare["observation"]["request"]
    for key in ("requestID", "nonce", "laneContractSHA256", "releaseContractSHA256", "applicationArchiveSHA256", "sourceCommit", "bundleIdentifier", "productVersion", "productBuild", "runtimeManifestSHA256", "runtimeManifestFileSHA256", "expectedExecutableSHA256"):
        require(request[key] == prepare_request[key], f"recover request changed phase-one identity: {key}")
    phase_one_hash = sha256_file(prepare["observation"]["resultPath"])
    require(request["phaseOneResultSHA256"] == phase_one_hash and result["phaseOneResultSHA256"] == phase_one_hash, "recover request/result phase-one seal mismatch")
    require("phaseOneResultSHA256" not in prepare_request, "prepare request unexpectedly binds a prior result")
    reference = validate_semantic(result["referenceSemantic"], "recover reference semantic", 96, 72)
    recovered = validate_semantic(result["recoveredSemantic"], "recover output semantic", 96, 72)
    require(reference == recovered == prepare["directSemantic"], "recovered decoded pixels/timing differ from uninterrupted output")
    resumed = require_mapping(result["resumedProcess"], "resumed deterministic process")
    require_exact_keys(resumed, {"actualBackendID", "processedFrameCount", "encodedWidth", "encodedHeight", "outputCodec", "processingDurationSeconds"}, "resumed deterministic process")
    require(resumed["actualBackendID"] == "mirmirDeterministicCPU" and resumed["processedFrameCount"] == 12 and resumed["encodedWidth"] == 96 and resumed["encodedHeight"] == 72 and resumed["outputCodec"] == "h264", "resumed processing contract mismatch")
    require_number(resumed["processingDurationSeconds"], "resumed processing duration", positive=True)
    artifacts = require_mapping(result["artifacts"], "recover artifacts")
    require_exact_keys(artifacts, {"directOutput", "recoveredOutput", "phaseOneState"}, "recover artifacts")
    direct = validate_smoke_artifact(snapshot, artifacts["directOutput"], "recover direct artifact")
    recovered_path = validate_smoke_artifact(snapshot, artifacts["recoveredOutput"], "recover output artifact")
    state_path = validate_smoke_artifact(snapshot, artifacts["phaseOneState"], "recover phase-one state")
    require(artifacts["directOutput"] == prepare["state"]["directOutputArtifact"], "recover direct artifact descriptor changed")
    require(sha256_file(state_path) == prepare["stateSHA256"], "phase-one state changed across relaunch")
    require(direct != recovered_path and recovered_path.suffix == ".mov", "recover output artifact is invalid")
    queue = require_mapping(result["queue"], "recover queue")
    require_exact_keys(queue, {"jobID", "launchLifecycle", "finalLifecycle", "launchRecoveryItemCount", "launchRecoveryStatus", "launchRecoveryObservedLifecycle", "launchRecoveryPresentedLifecycle", "launchRecoveryResumable", "launchRecoveryContainedFailureCount", "phaseOneQueueTreeSHA256", "finalQueueTreeSHA256"}, "recover queue")
    require(queue["jobID"] == prepare["queue"]["jobID"] and queue["launchLifecycle"] == "paused" and queue["finalLifecycle"] == "completed" and queue["launchRecoveryItemCount"] == 1 and queue["launchRecoveryStatus"] == "idle" and queue["launchRecoveryObservedLifecycle"] == "paused" and queue["launchRecoveryPresentedLifecycle"] == "paused" and queue["launchRecoveryResumable"] is True and queue["launchRecoveryContainedFailureCount"] == 0, "queue did not present, reopen, and complete the paused job")
    require(queue["phaseOneQueueTreeSHA256"] == prepare["queue"]["queueTreeSHA256"], "recover phase-one queue seal mismatch")
    final_sha, _, _ = tree_identity(snapshot / "workflow-queue-v4", maximum_bytes)
    require(final_sha == queue["finalQueueTreeSHA256"], "recover final queue tree seal mismatch")
    require(observation["process"]["processID"] != prepare["observation"]["process"]["processID"], "prepare and recover were not separate app processes")
    return {"referenceSemantic": reference, "recoveredSemantic": recovered, "queue": queue}


def validate_capture(capture_path: Path, contract_path: Path, release_contract_path: Path, *, now: datetime | None = None) -> dict[str, Any]:
    capture_path = capture_path.resolve(strict=True)
    capture_root = capture_path.parent
    contract, lane_sha, release_sha = validate_contract(contract_path.resolve(strict=True), release_contract_path.resolve(strict=True))
    capture = require_mapping(load_json(capture_path), "notarized smoke capture")
    expected_keys = {"schemaVersion", "suiteID", "createdAtUTC", "finishedAtUTC", "laneContractSHA256", "releaseContractSHA256", "candidate", "identities", "notarySubmission", "artifacts", "commandRecords", "observerInvocations"}
    require_exact_keys(capture, expected_keys, "notarized smoke capture")
    require(capture["schemaVersion"] == CAPTURE_SCHEMA and capture["suiteID"] == contract["suiteID"], "unsupported notarized smoke capture")
    require(capture["laneContractSHA256"] == lane_sha and capture["releaseContractSHA256"] == release_sha, "capture contract identities mismatch")
    created = parse_utc(capture["createdAtUTC"], "capture.createdAtUTC")
    finished = parse_utc(capture["finishedAtUTC"], "capture.finishedAtUTC")
    require(created <= finished, "capture interval is inverted")
    current = now or datetime.now(timezone.utc)
    maximum_age = require_integer(contract["capture"]["maximumCaptureAgeSeconds"], "maximum capture age", 1)
    require(-300 <= (current - finished).total_seconds() <= maximum_age, "capture is stale or future-dated")
    candidate = validate_candidate(capture["candidate"])
    artifacts = require_mapping(capture["artifacts"], "capture.artifacts")
    artifact_keys = {"candidateJSON", "laneContract", "releaseContract", "observerSource", "evaluator", "runner", "candidateArchive", "submittedArchive", "candidateExecutable", "toolManifest", "notaryLog"}
    require_exact_keys(artifacts, artifact_keys, "capture.artifacts")
    paths = {key: validate_artifact(capture_root, artifacts[key], f"capture.artifacts.{key}") for key in artifact_keys}
    require(load_json(paths["candidateJSON"]) == candidate, "captured candidate JSON differs from embedded candidate")
    require(sha256_file(paths["laneContract"]) == lane_sha and sha256_file(paths["releaseContract"]) == release_sha, "captured contracts differ")
    identities = require_mapping(capture["identities"], "capture.identities")
    identity_keys = {"observerSourceSHA256", "evaluatorSHA256", "runnerSHA256", "applicationExecutableSHA256", "submittedArchiveSHA256", "candidateArchiveSHA256", "toolManifestSHA256"}
    require_exact_keys(identities, identity_keys, "capture.identities")
    for key in identity_keys:
        require_hex(identities[key], 64, f"capture.identities.{key}")
    source_mapping = {"observerSourceSHA256": "observerSource", "evaluatorSHA256": "evaluator", "runnerSHA256": "runner", "applicationExecutableSHA256": "candidateExecutable", "submittedArchiveSHA256": "submittedArchive", "candidateArchiveSHA256": "candidateArchive", "toolManifestSHA256": "toolManifest"}
    for identity_key, artifact_key in source_mapping.items():
        require(identities[identity_key] == sha256_file(paths[artifact_key]), f"capture identity/artifact mismatch: {identity_key}")
    for key in ("observerSourceSHA256", "evaluatorSHA256", "runnerSHA256"):
        require(identities[key] == contract["capture"][key], f"capture used unlocked source: {key}")
    require(identities["candidateArchiveSHA256"] == candidate["appBundleSHA256"], "capture used another candidate archive")
    candidate_archive = inspect_application_archive(paths["candidateArchive"])
    submitted_archive = inspect_application_archive(paths["submittedArchive"])
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require(candidate_archive[key] == candidate[key] and submitted_archive[key] == candidate[key], f"archive bundle mismatch: {key}")
    for archive in (candidate_archive, submitted_archive):
        require(archive["executableSHA256"] == identities["applicationExecutableSHA256"], "submitted/stapled executable identity mismatch")
        require(archive["runtimeManifestSHA256"] == candidate["runtimeManifestSHA256"], "archive P06 semantic identity mismatch")
        require(archive["runtimeManifestFileSHA256"] == candidate["runtimeManifestFileSHA256"], "archive P06 file identity mismatch")
        require(archive["runtimeID"] == contract["candidate"]["requiredRuntimeID"] and archive["releaseStatus"] == contract["candidate"]["requiredRuntimeStatus"], "archive embeds another P06 release")
    require(sha256_file(paths["candidateExecutable"]) == candidate_archive["executableSHA256"], "captured executable bytes differ from archive")
    tools = require_mapping(load_json(paths["toolManifest"]), "tool identity manifest")
    require(tools.get("schemaVersion") == TOOL_SCHEMA, "unsupported tool identity manifest")
    tool_rows = require_mapping(tools.get("tools"), "tool identity manifest.tools")
    required_tools = {"app", "codesign", "ditto", "notarytool", "python3", "spctl", "stapler", "xcrun"}
    require(set(tool_rows) == required_tools, "tool identity set is incomplete")
    for name, raw in tool_rows.items():
        row = require_mapping(raw, f"tool {name}")
        require_exact_keys(row, {"path", "sha256"}, f"tool {name}")
        require_string(row["path"], f"tool {name}.path")
        require_hex(row["sha256"], 64, f"tool {name}.sha256")
    require(tool_rows["app"]["sha256"] == identities["applicationExecutableSHA256"], "app tool identity mismatch")
    for name, required_path in contract["tools"].items():
        require(tool_rows[name]["path"] == required_path, f"locked system tool path differs: {name}")
    record_descriptors = require_mapping(capture["commandRecords"], "capture.commandRecords")
    required_record_ids = require_list(contract["requiredCommandRecords"], "contract.requiredCommandRecords")
    require(set(record_descriptors) == set(required_record_ids), "capture command record set is incomplete")
    records: dict[str, dict[str, Any]] = {}
    command_record_paths: dict[str, Path] = {}
    for record_id in required_record_ids:
        record_path = validate_artifact(capture_root, record_descriptors[record_id], f"command record {record_id}")
        command_record_paths[record_id] = record_path
        records[record_id] = validate_process_record(capture_root, load_json(record_path), record_id, created, finished)
    tool_for_record = {
        "notary_info": "notarytool", "notary_log": "notarytool",
        "gatekeeper_assessment": "spctl", "stapled_ticket_validation": "stapler",
        "code_signature_validation": "codesign", "code_signature_display": "codesign",
        "code_signature_entitlements": "codesign", "code_signature_requirements": "codesign",
        "submitted_signature_display": "codesign", "submitted_signature_requirements": "codesign",
        "observer_prepare": "app", "observer_recover": "app",
    }
    for record_id, tool_name in tool_for_record.items():
        require(records[record_id]["executableSHA256"] == tool_rows[tool_name]["sha256"], f"{record_id} used another executable")
        require(records[record_id]["executablePath"] == tool_rows[tool_name]["path"], f"{record_id} used another executable path")
    submission = require_mapping(capture["notarySubmission"], "notarySubmission")
    require_exact_keys(submission, {"id", "submittedArchiveName"}, "notarySubmission")
    notary = parse_notary_evidence(records, paths["notaryLog"], identities["submittedArchiveSHA256"], submission, contract["capture"]["maximumNotarySubmissionAgeSeconds"], finished)
    signing = validate_codesign_evidence(records, contract, candidate)
    system = validate_system_acceptance(records)
    invocations = require_list(capture["observerInvocations"], "observerInvocations")
    require(len(invocations) == 2, "capture must contain exactly two app invocations")
    maximum_tree = require_integer(contract["capture"]["maximumSandboxEvidenceBytes"], "maximum sandbox evidence bytes", 1)
    observations: dict[str, dict[str, Any]] = {}
    for raw in invocations:
        invocation = require_mapping(raw, "observer invocation")
        phase = require_string(invocation.get("phase"), "observer invocation.phase")
        expected_record = f"observer_{phase}"
        require(invocation.get("commandRecord") == record_descriptors.get(expected_record), f"observer {phase} command record descriptor mismatch")
        snapshot = validate_tree_artifact(capture_root, invocation.get("sandboxSnapshot"), maximum_tree, f"observer {phase} snapshot")
        require(phase not in observations, f"duplicate observer phase: {phase}")
        observations[phase] = decode_observer_invocation(capture_root, invocation, records[expected_record], snapshot, candidate, contract, lane_sha, release_sha)
    require(set(observations) == {"prepare", "recover"}, "observer phase set is incomplete")
    require(observations["prepare"]["request"]["expectedExecutableSHA256"] == identities["applicationExecutableSHA256"], "prepare request executable mismatch")
    require(observations["recover"]["request"]["expectedExecutableSHA256"] == identities["applicationExecutableSHA256"], "recover request executable mismatch")
    prepare_facts = validate_prepare_observation(observations["prepare"], maximum_tree)
    prepare_facts["observation"] = observations["prepare"]
    recover_facts = validate_recover_observation(observations["recover"], prepare_facts, maximum_tree)
    action_specs = {item["id"]: item for item in contract["actions"]}
    return {
        "capture": capture,
        "capturePath": capture_path,
        "captureRoot": capture_root,
        "contract": contract,
        "laneContractSHA256": lane_sha,
        "releaseContractSHA256": release_sha,
        "candidate": candidate,
        "identities": identities,
        "paths": paths,
        "records": records,
        "recordDescriptors": record_descriptors,
        "recordPaths": command_record_paths,
        "notary": notary,
        "signing": signing,
        "system": system,
        "observations": observations,
        "prepare": prepare_facts,
        "recover": recover_facts,
        "actionSpecs": action_specs,
        "createdAtUTC": capture["createdAtUTC"],
        "finishedAtUTC": capture["finishedAtUTC"],
    }


ACTION_RECORDS = {
    "notarization_ticket_acceptance": ("notary_info", "notary_log"),
    "gatekeeper_assessment": ("gatekeeper_assessment",),
    "stapled_ticket_validation": ("stapled_ticket_validation",),
    "code_signature_validation": ("code_signature_validation", "code_signature_display", "code_signature_entitlements", "code_signature_requirements", "submitted_signature_display", "submitted_signature_requirements"),
    "launch": ("observer_prepare",),
    "p06_runtime_load": ("observer_prepare",),
    "media_probe": ("observer_prepare",),
    "deterministic_process": ("observer_prepare",),
    "semantic_output_verify": ("observer_recover",),
    "queue_relaunch_recovery": ("observer_recover",),
}


def action_claims(evaluation: Mapping[str, Any], action_id: str) -> dict[str, Any]:
    prepare = evaluation["prepare"]
    recover = evaluation["recover"]
    observations = evaluation["observations"]
    claims: dict[str, Any] = {
        "candidateArchiveSHA256": evaluation["candidate"]["appBundleSHA256"],
        "runtimeManifestSHA256": evaluation["candidate"]["runtimeManifestSHA256"],
    }
    if action_id == "notarization_ticket_acceptance":
        claims.update(evaluation["notary"])
    elif action_id == "gatekeeper_assessment":
        claims.update(evaluation["system"])
    elif action_id == "stapled_ticket_validation":
        claims["ticketStapled"] = True
    elif action_id == "code_signature_validation":
        claims.update(evaluation["signing"])
    elif action_id == "launch":
        claims.update({"prepareProcessID": observations["prepare"]["process"]["processID"], "recoverProcessID": observations["recover"]["process"]["processID"], "separateShippingAppProcesses": True})
    elif action_id == "p06_runtime_load":
        claims.update(observations["recover"]["runtime"])
    elif action_id == "media_probe":
        claims.update(observations["prepare"]["result"]["mediaProbe"])
    elif action_id == "deterministic_process":
        claims.update(observations["prepare"]["result"]["deterministicProcess"])
    elif action_id == "semantic_output_verify":
        claims.update({"referenceSemantic": recover["referenceSemantic"], "recoveredSemantic": recover["recoveredSemantic"], "exactDecodedEquality": True})
    elif action_id == "queue_relaunch_recovery":
        claims.update(recover["queue"])
        claims["phaseOneStateSHA256"] = prepare["stateSHA256"]
    return claims


def expected_transcript(evaluation: Mapping[str, Any], action_id: str, suite_root: Path) -> dict[str, Any]:
    record_ids = ACTION_RECORDS[action_id]
    raw_artifacts: list[dict[str, Any]] = []
    for record_id in record_ids:
        raw_artifacts.append(descriptor(evaluation["recordPaths"][record_id], suite_root))
        record = evaluation["records"][record_id]
        raw_artifacts.append(descriptor(record["_stdout"], suite_root))
        raw_artifacts.append(descriptor(record["_stderr"], suite_root))
    if action_id == "notarization_ticket_acceptance":
        raw_artifacts.append(descriptor(evaluation["paths"]["notaryLog"], suite_root))
        raw_artifacts.append(descriptor(evaluation["paths"]["submittedArchive"], suite_root))
    return {
        "schemaVersion": TRANSCRIPT_SCHEMA,
        "actionID": action_id,
        "evidenceKind": evaluation["actionSpecs"][action_id]["evidenceKind"],
        "sourceRecordIDs": list(record_ids),
        "claims": action_claims(evaluation, action_id),
        "rawArtifacts": raw_artifacts,
    }


def expected_attestation(evaluation: Mapping[str, Any], action_id: str, transcript_path: Path, suite_root: Path) -> dict[str, Any]:
    primary = evaluation["records"][ACTION_RECORDS[action_id][0]]
    records = [evaluation["records"][item] for item in ACTION_RECORDS[action_id]]
    return {
        "schemaVersion": ATTESTATION_SCHEMA,
        "actionID": action_id,
        "evidenceKind": evaluation["actionSpecs"][action_id]["evidenceKind"],
        "command": primary["command"],
        "invocationSHA256": primary["invocationSHA256"],
        "exitStatus": 0,
        "startedAtUTC": min(item["startedAtUTC"] for item in records),
        "finishedAtUTC": max(item["finishedAtUTC"] for item in records),
        "observedAppBundleSHA256": evaluation["candidate"]["appBundleSHA256"],
        "observedRuntimeManifestSHA256": evaluation["candidate"]["runtimeManifestSHA256"],
        "transcriptArtifact": descriptor(transcript_path, suite_root),
    }


def replay_receipt(evaluation: Mapping[str, Any]) -> dict[str, Any]:
    identity_payload = {
        "candidate": evaluation["candidate"],
        "identities": evaluation["identities"],
        "notary": evaluation["notary"],
        "signing": evaluation["signing"],
        "prepareQueue": evaluation["prepare"]["queue"],
        "recoverQueue": evaluation["recover"]["queue"],
        "recoveredSemantic": evaluation["recover"]["recoveredSemantic"],
    }
    return {
        "schemaVersion": REPLAY_SCHEMA,
        "captureSHA256": sha256_file(evaluation["capturePath"]),
        "evaluationSHA256": sha256_bytes(canonical_bytes(identity_payload)),
        "verifiedActionIDs": list(evaluation["actionSpecs"]),
        "verifiedAtUTC": evaluation["finishedAtUTC"],
        "nestedEvidenceReplayPass": True,
    }


def expected_report(evaluation: Mapping[str, Any], suite_root: Path, receipt_path: Path) -> dict[str, Any]:
    action_rows = []
    for action_id in evaluation["actionSpecs"]:
        attestation_path = suite_root / "attestations" / f"{action_id}.json"
        action_rows.append({"id": action_id, "pass": True, "externalEvidenceArtifact": descriptor(attestation_path, suite_root)})
    identities = evaluation["identities"]
    return {
        "schemaVersion": REPORT_SCHEMA,
        "contractSHA256": evaluation["releaseContractSHA256"],
        "candidate": evaluation["candidate"],
        "releaseEligible": True,
        "identities": {
            "laneContractSHA256": evaluation["laneContractSHA256"],
            "observerSourceSHA256": identities["observerSourceSHA256"],
            "evaluatorSHA256": identities["evaluatorSHA256"],
            "runnerSHA256": identities["runnerSHA256"],
            "rawCaptureSHA256": sha256_file(evaluation["capturePath"]),
            "applicationExecutableSHA256": identities["applicationExecutableSHA256"],
            "submittedArchiveSHA256": identities["submittedArchiveSHA256"],
            "toolManifestSHA256": identities["toolManifestSHA256"],
            "replayReceiptSHA256": sha256_file(receipt_path),
        },
        "appBundleSHA256": evaluation["candidate"]["appBundleSHA256"],
        "bundleIdentifier": evaluation["candidate"]["bundleIdentifier"],
        "productVersion": evaluation["candidate"]["productVersion"],
        "productBuild": evaluation["candidate"]["productBuild"],
        "notarizationAccepted": True,
        "ticketStapled": True,
        "gatekeeperAccepted": True,
        "codeSignatureValid": True,
        "hardenedRuntimeEnabled": True,
        "productionP06Loaded": True,
        "actions": action_rows,
        "capture": {
            "createdAtUTC": evaluation["createdAtUTC"],
            "finishedAtUTC": evaluation["finishedAtUTC"],
            "rawCaptureArtifact": descriptor(evaluation["capturePath"], suite_root),
            "replayReceiptArtifact": descriptor(receipt_path, suite_root),
            "nestedEvidenceReplayPass": True,
        },
        "notarizedSmokeGatePass": True,
    }


def verify_generated_suite(evaluation: Mapping[str, Any], suite_root: Path) -> dict[str, Any]:
    for action_id in evaluation["actionSpecs"]:
        transcript_path = suite_root / "transcripts" / f"{action_id}.json"
        attestation_path = suite_root / "attestations" / f"{action_id}.json"
        require(transcript_path.read_bytes() == pretty_bytes(expected_transcript(evaluation, action_id, suite_root)), f"generated transcript replay mismatch: {action_id}")
        require(attestation_path.read_bytes() == pretty_bytes(expected_attestation(evaluation, action_id, transcript_path, suite_root)), f"generated attestation replay mismatch: {action_id}")
    receipt_path = suite_root / "replay-receipt.json"
    require(receipt_path.read_bytes() == pretty_bytes(replay_receipt(evaluation)), "replay receipt mismatch")
    report_path = suite_root / "report.json"
    expected = expected_report(evaluation, suite_root, receipt_path)
    require(report_path.read_bytes() == pretty_bytes(expected), "notarized smoke report replay mismatch")
    return expected


def seal_suite(suite_root: Path) -> Path:
    manifest_path = suite_root / "sealed-manifest.json"
    require(not manifest_path.exists(), "sealed manifest already exists")
    files = sorted(
        (path for path in suite_root.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(suite_root).as_posix(),
    )
    artifacts = [descriptor(path, suite_root) for path in files]
    manifest = {
        "schemaVersion": SEALED_SCHEMA,
        "artifactCount": len(artifacts),
        "artifactSetSHA256": sha256_bytes(canonical_bytes(artifacts)),
        "artifacts": artifacts,
    }
    write_json(manifest_path, manifest)
    return manifest_path


def verify_sealed_suite(suite_root: Path, manifest_path: Path) -> None:
    manifest = require_mapping(load_json(manifest_path), "sealed manifest")
    require_exact_keys(manifest, {"schemaVersion", "artifactCount", "artifactSetSHA256", "artifacts"}, "sealed manifest")
    require(manifest["schemaVersion"] == SEALED_SCHEMA, "unsupported sealed manifest")
    artifacts = require_list(manifest["artifacts"], "sealed manifest artifacts")
    require(len(artifacts) == require_integer(manifest["artifactCount"], "sealed artifact count", 1), "sealed artifact count mismatch")
    normalized = []
    sealed_paths: set[Path] = set()
    for index, item in enumerate(artifacts):
        path = validate_artifact(suite_root, item, f"sealed artifact[{index}]")
        require(path not in sealed_paths, "sealed manifest repeats an artifact")
        sealed_paths.add(path)
        normalized.append(item)
    require(manifest["artifactSetSHA256"] == sha256_bytes(canonical_bytes(normalized)), "sealed artifact-set identity mismatch")
    actual = {path.resolve() for path in suite_root.rglob("*") if path.is_file() and path.resolve() != manifest_path.resolve()}
    require(actual == sealed_paths, f"sealed file set mismatch; missing={sorted(str(x) for x in sealed_paths-actual)}, unsealed={sorted(str(x) for x in actual-sealed_paths)}")


def evaluate(capture_path: Path, output_root: Path, contract_path: Path, release_contract_path: Path, *, now: datetime | None = None) -> dict[str, Any]:
    output_root = output_root.resolve()
    require(output_root.is_dir() and not output_root.is_symlink(), "output suite root must already be a safe directory")
    require(capture_path.resolve(strict=True).is_relative_to(output_root), "capture must be inside the suite root")
    for name in ("transcripts", "attestations", "report.json", "replay-receipt.json", "sealed-manifest.json"):
        require(not (output_root / name).exists(), f"refusing to overwrite suite output: {name}")
    evaluation = validate_capture(capture_path, contract_path, release_contract_path, now=now)
    (output_root / "transcripts").mkdir(mode=0o700)
    (output_root / "attestations").mkdir(mode=0o700)
    for action_id in evaluation["actionSpecs"]:
        transcript_path = output_root / "transcripts" / f"{action_id}.json"
        write_json(transcript_path, expected_transcript(evaluation, action_id, output_root))
        write_json(
            output_root / "attestations" / f"{action_id}.json",
            expected_attestation(evaluation, action_id, transcript_path, output_root),
        )
    receipt_path = output_root / "replay-receipt.json"
    write_json(receipt_path, replay_receipt(evaluation))
    report = expected_report(evaluation, output_root, receipt_path)
    write_json(output_root / "report.json", report)
    verify_generated_suite(evaluation, output_root)
    manifest_path = seal_suite(output_root)
    verify_sealed_suite(output_root, manifest_path)
    return report


def verify(report_path: Path, capture_path: Path, contract_path: Path, release_contract_path: Path, *, now: datetime | None = None) -> None:
    report_path = report_path.resolve(strict=True)
    suite_root = report_path.parent
    evaluation = validate_capture(capture_path, contract_path, release_contract_path, now=now)
    require(load_json(report_path).get("schemaVersion") == REPORT_SCHEMA, "unsupported smoke report")
    verify_generated_suite(evaluation, suite_root)
    verify_sealed_suite(suite_root, suite_root / "sealed-manifest.json")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("evaluate", "verify"):
        child = subparsers.add_parser(name)
        child.add_argument("--capture", type=Path, required=True)
        child.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
        child.add_argument("--release-contract", type=Path, required=True)
        if name == "evaluate":
            child.add_argument("--output", type=Path, required=True)
        else:
            child.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "evaluate":
        report = evaluate(arguments.capture, arguments.output, arguments.contract, arguments.release_contract)
        print(json.dumps(report, sort_keys=True))
    else:
        verify(arguments.report, arguments.capture, arguments.contract, arguments.release_contract)
        print(arguments.report)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (NotarizedSmokeError, OSError, ValueError) as error:
        print(f"notarized smoke qualification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
