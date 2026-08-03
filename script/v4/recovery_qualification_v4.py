#!/usr/bin/env python3
"""Fail-closed evidence evaluator for deterministic-engine v4 recovery.

The XCTest capture performs the faults.  This evaluator distrusts its summary:
it reopens every sealed artifact, recomputes byte and semantic identities,
checks the locked scenario matrix, and emits the recovery role consumed by the
final release-qualification aggregator.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-v4-recovery-qualification-contract-v1"
CAPTURE_SCHEMA = "mirmir-v4-recovery-capture-v1"
CAPTURE_MANIFEST_SCHEMA = "mirmir-v4-recovery-capture-artifacts-v1"
REPORT_SCHEMA = "mirmir-ash-v4-recovery-report-v1"
SCENARIO_SCHEMA = "mirmir-v4-recovery-scenario-evidence-v1"
SEMANTIC_SCHEMA = "mirmir-v4-recovery-semantic-output-v1"
SUITE_MANIFEST_SCHEMA = "mirmir-v4-recovery-evidence-manifest-v1"
TRANSCRIPT_SCHEMA = "mirmir-v4-recovery-fault-transcript-v1"

REQUIRED_COVERAGE = (
    "append_only_event_boundary",
    "snapshot_publish_boundary",
    "bookmark_resolution_and_toctou",
    "segment_commit_boundary",
    "checkpoint_publish_boundary",
    "prepared_decision_boundary",
    "final_assembly_boundary",
    "atomic_output_publish_boundary",
    "pause_resume",
    "forced_termination_restart",
    "corrupt_journal",
    "corrupt_checkpoint",
    "orphan_partial_reconciliation",
    "unowned_artifact_rejection",
)

SCRIPT_DIRECTORY = Path(__file__).resolve().parent


class RecoveryEvidenceError(ValueError):
    """Raised when recovery evidence is incomplete, stale, or contradictory."""


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise RecoveryEvidenceError(f"duplicate JSON key: {key}")
        value[key] = child
    return value


def reject_nonfinite(token: str) -> Any:
    raise RecoveryEvidenceError(f"non-finite JSON number: {token}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RecoveryEvidenceError(f"cannot read JSON {path}: {error}") from error


def pretty_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode()


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(pretty_json(value))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise RecoveryEvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RecoveryEvidenceError(message)


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
    require(type(value) is bool, f"{label} must be boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {str(expected).lower()}")
    return value


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    require(type(value) is int and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def require_sha256(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == 64
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a lowercase SHA-256",
    )
    return text


def require_revision(value: Any, label: str) -> str:
    text = require_string(value, label)
    require(
        len(text) == 40
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a full lowercase Git revision",
    )
    return text


def require_exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, extra={sorted(actual-expected_set)}",
    )


def checked_path(root: Path, relative_value: Any, label: str) -> Path:
    relative = Path(require_string(relative_value, f"{label}.path"))
    require(not relative.is_absolute() and ".." not in relative.parts, f"{label} path escapes evidence root")
    root = root.resolve(strict=True)
    lexical = root
    for component in relative.parts:
        lexical = lexical / component
        require(not lexical.is_symlink(), f"{label} traverses a symbolic link")
    candidate = lexical.resolve(strict=True)
    require(candidate != root and root in candidate.parents, f"{label} path escapes evidence root")
    require(candidate.is_file() and not candidate.is_symlink(), f"{label} is not a regular file")
    return candidate


def descriptor(path: Path, evidence_root: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    root = evidence_root.resolve(strict=True)
    require(root in resolved.parents, f"artifact is outside evidence root: {resolved}")
    return {
        "path": resolved.relative_to(root).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_artifact(
    evidence_root: Path,
    value: Any,
    label: str,
    allowed_root: Path | None = None,
) -> tuple[Path, str]:
    artifact = require_mapping(value, label)
    require_exact_keys(artifact, {"path", "byteCount", "sha256"}, label)
    path = checked_path(evidence_root, artifact["path"], label)
    if allowed_root is not None:
        allowed = allowed_root.resolve(strict=True)
        require(path == allowed or allowed in path.parents, f"{label} is outside capture root")
    byte_count = require_integer(artifact["byteCount"], f"{label}.byteCount", 1)
    require(path.stat().st_size == byte_count, f"{label} byte count mismatch")
    expected = require_sha256(artifact["sha256"], f"{label}.sha256")
    actual = sha256_file(path)
    require(actual == expected, f"{label} SHA-256 mismatch")
    return path, actual


def validate_candidate(value: Any) -> dict[str, Any]:
    candidate = require_mapping(value, "candidate")
    expected = {
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
    require_exact_keys(candidate, expected, "candidate")
    require_revision(candidate["sourceCommit"], "candidate.sourceCommit")
    for key in expected - {
        "sourceCommit",
        "runtimeSourceRevision",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }:
        require_sha256(candidate[key], f"candidate.{key}")
    runtime_revision = require_string(candidate["runtimeSourceRevision"], "candidate.runtimeSourceRevision")
    require(
        len(runtime_revision) in (40, 64)
        and all(character in "0123456789abcdef" for character in runtime_revision),
        "candidate.runtimeSourceRevision must be hexadecimal",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate


def load_candidate(path: Path) -> dict[str, Any]:
    value = require_mapping(load_json(path), "candidate input")
    if value.get("schemaVersion") == "mirmir-ash-v4-release-candidate-evidence-v1":
        return validate_candidate(value.get("candidate"))
    return validate_candidate(value)


def load_contract(path: Path, verify_tools: bool = True) -> tuple[dict[str, Any], str]:
    contract = require_mapping(load_json(path), "contract")
    require_exact_keys(
        contract,
        {
            "artifactSchemas",
            "buildConfiguration",
            "capture",
            "hashAlgorithm",
            "scenarios",
            "schemaVersion",
            "semanticVerification",
            "suiteID",
        },
        "contract",
    )
    require(contract["schemaVersion"] == CONTRACT_SCHEMA, "unsupported recovery contract")
    require(contract["hashAlgorithm"] == "sha256", "unsupported recovery hash algorithm")
    require(contract["buildConfiguration"] == "Release", "recovery capture must use Release")
    require_string(contract["suiteID"], "contract.suiteID")
    schemas = require_mapping(contract["artifactSchemas"], "contract.artifactSchemas")
    require_exact_keys(
        schemas,
        {"capture", "captureManifest", "report", "scenarioEvidence", "semanticManifest", "suiteManifest", "transcript"},
        "contract.artifactSchemas",
    )
    expected_schemas = {
        "capture": CAPTURE_SCHEMA,
        "captureManifest": CAPTURE_MANIFEST_SCHEMA,
        "report": REPORT_SCHEMA,
        "scenarioEvidence": SCENARIO_SCHEMA,
        "semanticManifest": SEMANTIC_SCHEMA,
        "suiteManifest": SUITE_MANIFEST_SCHEMA,
        "transcript": TRANSCRIPT_SCHEMA,
    }
    require(schemas == expected_schemas, "contract artifact schemas differ")
    semantic = require_mapping(contract["semanticVerification"], "contract.semanticVerification")
    require_exact_keys(
        semantic,
        {"requireByteIdentity", "requireDecodedVisiblePixelIdentity", "requireExactPresentationTimeline", "requireTrackGraphIdentity"},
        "contract.semanticVerification",
    )
    for key in semantic:
        require_bool(semantic[key], f"contract.semanticVerification.{key}", True)
    scenarios = require_list(contract["scenarios"], "contract.scenarios")
    require(len(scenarios) == len(REQUIRED_COVERAGE), "contract recovery scenario count differs")
    seen_ids: set[str] = set()
    seen_coverage: list[str] = []
    for index, value in enumerate(scenarios):
        scenario = require_mapping(value, f"contract.scenarios[{index}]")
        require_exact_keys(
            scenario,
            {"containedFailureCode", "coverageID", "id", "injectionPoint", "outcome"},
            f"contract.scenarios[{index}]",
        )
        identifier = require_string(scenario["id"], f"contract scenario {index}.id")
        require(identifier not in seen_ids, f"contract repeats scenario: {identifier}")
        seen_ids.add(identifier)
        coverage = require_string(scenario["coverageID"], f"contract scenario {index}.coverageID")
        seen_coverage.append(coverage)
        require_string(scenario["injectionPoint"], f"contract scenario {index}.injectionPoint")
        outcome = scenario["outcome"]
        require(outcome in {"identical_resumed_output", "explicit_contained_failure"}, f"unsupported outcome: {identifier}")
        if outcome == "identical_resumed_output":
            require(scenario["containedFailureCode"] is None, f"identical scenario has failure code: {identifier}")
        else:
            require_string(scenario["containedFailureCode"], f"contract scenario {index}.containedFailureCode")
    require(tuple(seen_coverage) == REQUIRED_COVERAGE, "contract recovery coverage/order differs")
    capture = require_mapping(contract["capture"], "contract.capture")
    require_exact_keys(
        capture,
        {"captureSourceSHA256", "evaluatorSourceSHA256", "runnerSourceSHA256"},
        "contract.capture",
    )
    for key in capture:
        require_sha256(capture[key], f"contract.capture.{key}")
    if verify_tools:
        tool_paths = {
            "captureSourceSHA256": SCRIPT_DIRECTORY / "RecoveryQualificationCaptureTests.swift",
            "evaluatorSourceSHA256": SCRIPT_DIRECTORY / "recovery_qualification_v4.py",
            "runnerSourceSHA256": SCRIPT_DIRECTORY / "run_recovery_qualification_v4.sh",
        }
        for field, tool_path in tool_paths.items():
            require(tool_path.is_file() and not tool_path.is_symlink(), f"recovery tool is missing: {tool_path.name}")
            require(
                sha256_file(tool_path) == capture[field],
                f"recovery tool identity mismatch for {field}",
            )
    return contract, sha256_file(path)


def validate_semantic(path: Path, label: str) -> dict[str, Any]:
    value = require_mapping(load_json(path), label)
    require_exact_keys(
        value,
        {
            "allRequiredChecksPassed",
            "decodedVisiblePixelSHA256",
            "duration",
            "presentationTimelineSHA256",
            "sampleCount",
            "schemaVersion",
            "trackGraphSHA256",
        },
        label,
    )
    require(value["schemaVersion"] == SEMANTIC_SCHEMA, f"{label} schema differs")
    require_bool(value["allRequiredChecksPassed"], f"{label}.allRequiredChecksPassed", True)
    for key in ("decodedVisiblePixelSHA256", "presentationTimelineSHA256", "trackGraphSHA256"):
        require_sha256(value[key], f"{label}.{key}")
    require_integer(value["sampleCount"], f"{label}.sampleCount", 1)
    duration = require_mapping(value["duration"], f"{label}.duration")
    require_exact_keys(duration, {"value", "timescale"}, f"{label}.duration")
    require(type(duration["value"]) is int, f"{label}.duration.value must be an integer")
    require_integer(duration["timescale"], f"{label}.duration.timescale", 1)
    return value


def validate_transcript(path: Path, expected: Mapping[str, Any], label: str) -> dict[str, Any]:
    value = require_mapping(load_json(path), label)
    require_exact_keys(
        value,
        {"coverageID", "events", "faultObserved", "id", "injectionPoint", "reopenedDurableState", "schemaVersion", "terminalDisposition"},
        label,
    )
    require(value["schemaVersion"] == TRANSCRIPT_SCHEMA, f"{label} schema differs")
    for key in ("id", "coverageID", "injectionPoint"):
        require(value[key] == expected[key], f"{label}.{key} differs")
    require_bool(value["faultObserved"], f"{label}.faultObserved", True)
    require_bool(value["reopenedDurableState"], f"{label}.reopenedDurableState", True)
    terminal = "completed" if expected["outcome"] == "identical_resumed_output" else "contained"
    require(value["terminalDisposition"] == terminal, f"{label}.terminalDisposition differs")
    events = require_list(value["events"], f"{label}.events")
    require(len(events) >= 3, f"{label} must record pre-fault, fault, and reopen events")
    operations: list[str] = []
    for index, item in enumerate(events):
        event = require_mapping(item, f"{label}.events[{index}]")
        require_exact_keys(event, {"durableStateSHA256", "operation", "sequence"}, f"{label}.events[{index}]")
        require(event["sequence"] == index, f"{label} event sequence differs")
        operations.append(require_string(event["operation"], f"{label}.events[{index}].operation"))
        require_sha256(event["durableStateSHA256"], f"{label}.events[{index}].durableStateSHA256")
    require("inject_fault" in operations and "reopen_durable_state" in operations, f"{label} omits fault/reopen operations")
    return value


def artifact_set_sha(artifacts: Iterable[Mapping[str, Any]]) -> str:
    normalized = [
        {"path": item["path"], "byteCount": item["byteCount"], "sha256": item["sha256"]}
        for item in artifacts
    ]
    normalized.sort(key=lambda item: item["path"])
    return sha256_bytes(canonical_json(normalized))


def evaluate_capture(
    contract_path: Path,
    capture_path: Path,
    candidate_path: Path,
    evidence_root: Path,
    verify_tools: bool = True,
) -> tuple[dict[str, Any], dict[str, Any]]:
    evidence_root = evidence_root.resolve(strict=True)
    capture_path = capture_path.resolve(strict=True)
    capture_root = capture_path.parent
    require(evidence_root == capture_root or evidence_root in capture_root.parents, "capture is outside evidence root")
    contract, contract_sha = load_contract(contract_path, verify_tools=verify_tools)
    candidate = load_candidate(candidate_path)
    capture = require_mapping(load_json(capture_path), "capture")
    require_exact_keys(
        capture,
        {"buildConfiguration", "captureSourceSHA256", "contractSHA256", "scenarios", "schemaVersion", "sourceCommit", "sourceTreeSHA256"},
        "capture",
    )
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "unsupported recovery capture schema")
    require(capture["contractSHA256"] == contract_sha, "capture contract identity mismatch")
    require(capture["captureSourceSHA256"] == contract["capture"]["captureSourceSHA256"], "capture source identity mismatch")
    require(capture["buildConfiguration"] == contract["buildConfiguration"], "capture build configuration differs")
    require_revision(capture["sourceCommit"], "capture.sourceCommit")
    require_sha256(capture["sourceTreeSHA256"], "capture.sourceTreeSHA256")
    require(capture["sourceCommit"] == candidate["sourceCommit"], "capture source commit is stale")
    require(capture["sourceTreeSHA256"] == candidate["sourceTreeIdentitySHA256"], "capture source tree is stale")

    expected_scenarios = {item["id"]: item for item in contract["scenarios"]}
    observed = require_list(capture["scenarios"], "capture.scenarios")
    require(len(observed) == len(expected_scenarios), "capture scenario count differs")
    report_scenarios: list[dict[str, Any]] = []
    referenced_paths: set[Path] = {capture_path}
    seen: set[str] = set()
    for index, item in enumerate(observed):
        scenario = require_mapping(item, f"capture.scenarios[{index}]")
        require_exact_keys(scenario, {"externalEvidenceArtifact", "id"}, f"capture.scenarios[{index}]")
        identifier = require_string(scenario["id"], f"capture.scenarios[{index}].id")
        require(identifier in expected_scenarios and identifier not in seen, f"capture has unexpected/duplicate scenario: {identifier}")
        seen.add(identifier)
        expected = expected_scenarios[identifier]
        external_path, _ = validate_artifact(
            evidence_root,
            scenario["externalEvidenceArtifact"],
            f"capture scenario {identifier}.externalEvidenceArtifact",
            capture_root,
        )
        referenced_paths.add(external_path)
        external = require_mapping(load_json(external_path), f"scenario evidence {identifier}")
        require_exact_keys(
            external,
            {
                "containedFailureCode",
                "coverageID",
                "faultInjected",
                "id",
                "injectionPoint",
                "outcome",
                "ownedArtifactReconciled",
                "referenceOutputArtifact",
                "referenceSemanticArtifact",
                "resumedOutputArtifact",
                "resumedSemanticArtifact",
                "schemaVersion",
                "transcriptArtifact",
                "unownedArtifactCount",
            },
            f"scenario evidence {identifier}",
        )
        require(external["schemaVersion"] == SCENARIO_SCHEMA, f"scenario evidence schema differs: {identifier}")
        for key in ("id", "coverageID", "injectionPoint", "outcome", "containedFailureCode"):
            require(external[key] == expected[key], f"scenario {identifier}.{key} differs from contract")
        require_bool(external["faultInjected"], f"scenario {identifier}.faultInjected", True)
        require_bool(external["ownedArtifactReconciled"], f"scenario {identifier}.ownedArtifactReconciled", True)
        require_integer(external["unownedArtifactCount"], f"scenario {identifier}.unownedArtifactCount", 0)
        require(external["unownedArtifactCount"] == 0, f"scenario left an unowned artifact: {identifier}")
        transcript_path, _ = validate_artifact(
            evidence_root,
            external["transcriptArtifact"],
            f"scenario {identifier}.transcriptArtifact",
            capture_root,
        )
        referenced_paths.add(transcript_path)
        validate_transcript(transcript_path, expected, f"scenario transcript {identifier}")

        report_item: dict[str, Any] = {
            "id": identifier,
            "coverage": [expected["coverageID"]],
            "outcome": expected["outcome"],
            "referenceOutputSHA256": None,
            "resumedOutputSHA256": None,
            "referenceSemanticSHA256": None,
            "resumedSemanticSHA256": None,
            "containedFailureCode": expected["containedFailureCode"],
            "unownedArtifactCount": 0,
            "ownedArtifactReconciled": True,
            "referenceOutputArtifact": None,
            "resumedOutputArtifact": None,
            "referenceSemanticArtifact": None,
            "resumedSemanticArtifact": None,
            "externalEvidenceArtifact": scenario["externalEvidenceArtifact"],
        }
        if expected["outcome"] == "identical_resumed_output":
            require(external["containedFailureCode"] is None, f"identical scenario has failure code: {identifier}")
            reference_path, reference_sha = validate_artifact(
                evidence_root,
                external["referenceOutputArtifact"],
                f"scenario {identifier}.referenceOutputArtifact",
                capture_root,
            )
            resumed_path, resumed_sha = validate_artifact(
                evidence_root,
                external["resumedOutputArtifact"],
                f"scenario {identifier}.resumedOutputArtifact",
                capture_root,
            )
            reference_semantic_path, reference_semantic_sha = validate_artifact(
                evidence_root,
                external["referenceSemanticArtifact"],
                f"scenario {identifier}.referenceSemanticArtifact",
                capture_root,
            )
            resumed_semantic_path, resumed_semantic_sha = validate_artifact(
                evidence_root,
                external["resumedSemanticArtifact"],
                f"scenario {identifier}.resumedSemanticArtifact",
                capture_root,
            )
            referenced_paths.update({reference_path, resumed_path, reference_semantic_path, resumed_semantic_path})
            require(reference_sha == resumed_sha, f"resumed output bytes differ: {identifier}")
            reference_semantic = validate_semantic(reference_semantic_path, f"reference semantic {identifier}")
            resumed_semantic = validate_semantic(resumed_semantic_path, f"resumed semantic {identifier}")
            require(reference_semantic == resumed_semantic, f"resumed output semantics differ: {identifier}")
            require(reference_semantic_sha == resumed_semantic_sha, f"semantic manifest bytes differ: {identifier}")
            report_item.update(
                {
                    "referenceOutputSHA256": reference_sha,
                    "resumedOutputSHA256": resumed_sha,
                    "referenceSemanticSHA256": reference_semantic_sha,
                    "resumedSemanticSHA256": resumed_semantic_sha,
                    "referenceOutputArtifact": external["referenceOutputArtifact"],
                    "resumedOutputArtifact": external["resumedOutputArtifact"],
                    "referenceSemanticArtifact": external["referenceSemanticArtifact"],
                    "resumedSemanticArtifact": external["resumedSemanticArtifact"],
                }
            )
        else:
            for key in ("referenceOutputArtifact", "resumedOutputArtifact", "referenceSemanticArtifact", "resumedSemanticArtifact"):
                require(external[key] is None, f"contained scenario supplies {key}: {identifier}")
            require_string(external["containedFailureCode"], f"scenario {identifier}.containedFailureCode")
        report_scenarios.append(report_item)

    require(seen == set(expected_scenarios), "capture recovery coverage differs")
    environment_path = capture_root / "environment.json"
    execution_log_path = capture_root / "xcodebuild.log"
    require(environment_path.is_file() and not environment_path.is_symlink(), "capture environment is missing")
    require(execution_log_path.is_file() and not execution_log_path.is_symlink(), "capture xcodebuild log is missing")
    referenced_paths.update({environment_path.resolve(), execution_log_path.resolve()})
    environment = require_mapping(load_json(environment_path), "capture environment")
    require_exact_keys(environment, {"buildConfiguration", "hardwareModel", "macOSVersion", "schemaVersion", "xcodeVersion"}, "capture environment")
    require(environment["schemaVersion"] == "mirmir-v4-recovery-environment-v1", "capture environment schema differs")
    require(environment["buildConfiguration"] == "Release", "capture environment is not Release")
    for key in ("hardwareModel", "macOSVersion", "xcodeVersion"):
        require_string(environment[key], f"capture environment.{key}")
    try:
        log = execution_log_path.read_text()
    except (OSError, UnicodeError) as error:
        raise RecoveryEvidenceError(f"cannot read capture log: {error}") from error
    require("** TEST SUCCEEDED **" in log, "capture xcodebuild log does not prove success")

    actual_raw_files = {
        path.resolve()
        for path in capture_root.rglob("*")
        if path.is_file() and path.name != "artifact-manifest.json"
    }
    require(
        actual_raw_files == referenced_paths,
        "capture file set differs; "
        f"unreferenced={sorted(path.as_posix() for path in actual_raw_files-referenced_paths)}, "
        f"missing={sorted(path.as_posix() for path in referenced_paths-actual_raw_files)}",
    )
    raw_descriptors = [descriptor(path, evidence_root) for path in sorted(referenced_paths)]
    capture_manifest = {
        "schemaVersion": CAPTURE_MANIFEST_SCHEMA,
        "artifacts": raw_descriptors,
        "artifactSetSHA256": artifact_set_sha(raw_descriptors),
    }
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "contractSHA256": contract_sha,
        "candidate": candidate,
        "releaseEligible": True,
        "identities": {
            "captureSourceSHA256": contract["capture"]["captureSourceSHA256"],
            "evaluatorSHA256": contract["capture"]["evaluatorSourceSHA256"],
            "runnerSHA256": contract["capture"]["runnerSourceSHA256"],
        },
        "capture": {
            "artifactManifestSHA256": "__CAPTURE_MANIFEST_SHA256__",
            "artifactSetSHA256": capture_manifest["artifactSetSHA256"],
            "buildConfiguration": capture["buildConfiguration"],
            "sourceCommit": capture["sourceCommit"],
            "sourceTreeSHA256": capture["sourceTreeSHA256"],
        },
        "scenarios": report_scenarios,
        "recoveryGatePass": True,
    }
    return report, capture_manifest


def make_suite_manifest(role_root: Path, manifest_path: Path) -> dict[str, Any]:
    files = sorted(
        path.resolve()
        for path in role_root.rglob("*")
        if path.is_file() and path.resolve() != manifest_path.resolve()
    )
    # The release aggregator resolves a role's sealed-manifest descriptors
    # relative to the directory containing that manifest. Nested capture and
    # scenario descriptors remain relative to the global evidence root.
    artifacts = [descriptor(path, role_root) for path in files]
    return {
        "schemaVersion": SUITE_MANIFEST_SCHEMA,
        "artifacts": artifacts,
        "artifactSetSHA256": artifact_set_sha(artifacts),
    }


def evaluate_command(arguments: argparse.Namespace) -> None:
    evidence_root = Path(arguments.evidence_root).expanduser().resolve(strict=True)
    capture_path = Path(arguments.capture).expanduser().resolve(strict=True)
    report_path = Path(arguments.output).expanduser().resolve()
    capture_manifest_path = Path(arguments.capture_manifest).expanduser().resolve()
    suite_manifest_path = Path(arguments.sealed_manifest).expanduser().resolve()
    report, capture_manifest = evaluate_capture(
        Path(arguments.contract),
        capture_path,
        Path(arguments.candidate),
        evidence_root,
    )
    write_json(capture_manifest_path, capture_manifest)
    report["capture"]["artifactManifestSHA256"] = sha256_file(capture_manifest_path)
    write_json(report_path, report)
    role_root = report_path.parent.resolve(strict=True)
    write_json(
        suite_manifest_path,
        make_suite_manifest(role_root, suite_manifest_path),
    )


def verify_command(arguments: argparse.Namespace) -> None:
    evidence_root = Path(arguments.evidence_root).expanduser().resolve(strict=True)
    capture_manifest_path = Path(arguments.capture_manifest).expanduser().resolve(strict=True)
    report_path = Path(arguments.report).expanduser().resolve(strict=True)
    suite_manifest_path = Path(arguments.sealed_manifest).expanduser().resolve(strict=True)
    expected_report, expected_capture_manifest = evaluate_capture(
        Path(arguments.contract),
        Path(arguments.capture),
        Path(arguments.candidate),
        evidence_root,
    )
    require(
        load_json(capture_manifest_path) == expected_capture_manifest
        and capture_manifest_path.read_bytes() == pretty_json(expected_capture_manifest),
        "capture artifact manifest is stale or noncanonical",
    )
    expected_report["capture"]["artifactManifestSHA256"] = sha256_file(capture_manifest_path)
    require(
        load_json(report_path) == expected_report
        and report_path.read_bytes() == pretty_json(expected_report),
        "recovery report is stale or noncanonical",
    )
    expected_suite_manifest = make_suite_manifest(
        report_path.parent.resolve(strict=True),
        suite_manifest_path,
    )
    require(
        load_json(suite_manifest_path) == expected_suite_manifest
        and suite_manifest_path.read_bytes() == pretty_json(expected_suite_manifest),
        "recovery sealed manifest is stale or noncanonical",
    )


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    subparsers = value.add_subparsers(dest="command", required=True)
    evaluate = subparsers.add_parser("evaluate", help="validate capture and write sealed recovery evidence")
    verify = subparsers.add_parser("verify", help="recompute and verify existing recovery evidence")
    for command in (evaluate, verify):
        command.add_argument("--contract", required=True)
        command.add_argument("--capture", required=True)
        command.add_argument("--candidate", required=True)
        command.add_argument("--evidence-root", required=True)
        command.add_argument("--capture-manifest", required=True)
        command.add_argument("--sealed-manifest", required=True)
    evaluate.add_argument("--output", required=True)
    verify.add_argument("--report", required=True)
    return value


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "evaluate":
            evaluate_command(arguments)
        else:
            verify_command(arguments)
    except RecoveryEvidenceError as error:
        print(f"recovery qualification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
