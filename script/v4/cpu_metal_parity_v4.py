#!/usr/bin/env python3
"""Fail-closed CPU/Metal byte-parity qualification for deterministic ASH v4."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-contract-v1"
CAPTURE_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-capture-v1"
CAPTURE_MANIFEST_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-artifacts-v1"
REPORT_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-report-v1"
EVIDENCE_MANIFEST_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-evidence-v1"
SHA256_LENGTH = 64


class ParityEvidenceError(ValueError):
    """Raised whenever parity evidence is incomplete, stale, or mutable."""


def _duplicate_rejector(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ParityEvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> Any:
    raise ParityEvidenceError(f"non-finite JSON value: {value}")


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_duplicate_rejector,
            parse_constant=_reject_nonfinite,
        )
    except ParityEvidenceError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ParityEvidenceError(f"cannot read JSON {path}: {error}") from error


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
    ).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.write_bytes(canonical_json(value))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ParityEvidenceError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ParityEvidenceError(message)


def require_object(value: Any, label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def require_array(value: Any, label: str) -> list[Any]:
    require(isinstance(value, list), f"{label} must be an array")
    return value


def require_text(value: Any, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be text")
    return value


def require_integer(value: Any, label: str, minimum: int | None = None) -> int:
    require(type(value) is int, f"{label} must be an integer")
    if minimum is not None:
        require(value >= minimum, f"{label} must be at least {minimum}")
    return value


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    require(type(value) is bool, f"{label} must be boolean")
    if expected is not None:
        require(value is expected, f"{label} must be {expected}")
    return value


def require_exact_keys(
    value: Mapping[str, Any], expected: Iterable[str], label: str
) -> None:
    expected_set = set(expected)
    actual = set(value)
    require(
        actual == expected_set,
        f"{label} keys differ; missing={sorted(expected_set-actual)}, "
        f"extra={sorted(actual-expected_set)}",
    )


def require_sha256(value: Any, label: str) -> str:
    text = require_text(value, label)
    require(
        len(text) == SHA256_LENGTH
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a lowercase SHA-256",
    )
    return text


def require_revision(value: Any, label: str) -> str:
    text = require_text(value, label)
    require(
        len(text) == 40
        and text == text.lower()
        and all(character in "0123456789abcdef" for character in text),
        f"{label} must be a full lowercase Git revision",
    )
    return text


def safe_path(root: Path, relative: Any, label: str) -> Path:
    text = require_text(relative, f"{label}.path")
    candidate = Path(text)
    require(
        not candidate.is_absolute()
        and "\\" not in text
        and all(part not in ("", ".", "..") for part in candidate.parts),
        f"{label} has unsafe path: {text}",
    )
    resolved_root = root.resolve()
    resolved = (root / candidate).resolve()
    require(
        resolved != resolved_root and resolved_root in resolved.parents,
        f"{label} escapes evidence root",
    )
    try:
        for parent in [root / Path(*candidate.parts[:index]) for index in range(1, len(candidate.parts) + 1)]:
            require(not parent.is_symlink(), f"{label} traverses a symbolic link")
    except OSError as error:
        raise ParityEvidenceError(f"cannot inspect {label}: {error}") from error
    require(resolved.is_file() and not resolved.is_symlink(), f"{label} is not a regular file")
    return resolved


def validate_descriptor(
    root: Path, value: Any, label: str
) -> tuple[dict[str, Any], Path, bytes]:
    descriptor = require_object(value, label)
    require_exact_keys(descriptor, ("path", "byteCount", "sha256"), label)
    path = safe_path(root, descriptor["path"], label)
    expected_count = require_integer(descriptor["byteCount"], f"{label}.byteCount", 0)
    expected_sha = require_sha256(descriptor["sha256"], f"{label}.sha256")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ParityEvidenceError(f"cannot read {label}: {error}") from error
    require(len(data) == expected_count, f"{label} byte count mismatch")
    require(sha256_bytes(data) == expected_sha, f"{label} SHA-256 mismatch")
    return descriptor, path, data


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve()
    relative = resolved.relative_to(root.resolve()).as_posix()
    return {
        "path": relative,
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_contract(
    path: Path,
    capture_source: Path,
    evaluator: Path,
    runner: Path,
) -> tuple[dict[str, Any], str]:
    contract = require_object(load_json(path), "contract")
    require_exact_keys(
        contract,
        {
            "schemaVersion",
            "gateID",
            "buildConfiguration",
            "captureSchemaVersion",
            "reportSchemaVersion",
            "comparison",
            "repeatExecutionCount",
            "crossProcessCaptureCount",
            "tileSchedules",
            "parityCoverage",
            "releaseRuntime",
            "tools",
            "cases",
        },
        "contract",
    )
    require(contract["schemaVersion"] == CONTRACT_SCHEMA, "unsupported contract schema")
    require(
        contract["gateID"] == "deterministic-engine-v4-cpu-metal-byte-parity",
        "unexpected parity gate ID",
    )
    require(contract["buildConfiguration"] == "Release", "parity must use Release")
    require(contract["captureSchemaVersion"] == CAPTURE_SCHEMA, "capture schema mismatch")
    require(contract["reportSchemaVersion"] == REPORT_SCHEMA, "report schema mismatch")
    require(
        contract["comparison"] == "exact_visible_plane_and_attachment_bytes",
        "comparison is not byte exact",
    )
    require_integer(contract["repeatExecutionCount"], "repeatExecutionCount", 2)
    require(contract["repeatExecutionCount"] == 2, "exactly two repeat executions required")
    require_integer(contract["crossProcessCaptureCount"], "crossProcessCaptureCount", 2)
    require(contract["crossProcessCaptureCount"] == 2, "exactly two processes required")
    schedules = [require_text(value, "tile schedule") for value in require_array(contract["tileSchedules"], "tileSchedules")]
    require(schedules == ["row_major", "reverse", "even_then_odd"], "tile schedule matrix mismatch")
    coverage = [require_text(value, "coverage") for value in require_array(contract["parityCoverage"], "parityCoverage")]
    require(len(coverage) == len(set(coverage)), "parity coverage repeats")
    runtime = require_object(contract["releaseRuntime"], "releaseRuntime")
    require_exact_keys(
        runtime,
        {
            "bundleRepositoryPath",
            "trustRootSourceRepositoryPath",
            "runtimeID",
            "requiredReleaseStatus",
        },
        "releaseRuntime",
    )
    require(runtime["runtimeID"] == "ash-p06-deterministic-v4", "runtime ID is not P06")
    require(runtime["requiredReleaseStatus"] == "release_qualified", "runtime is not release-qualified")
    tools = require_object(contract["tools"], "tools")
    require_exact_keys(
        tools,
        {"captureSourceSHA256", "evaluatorSHA256", "runnerSHA256"},
        "tools",
    )
    actual_tools = {
        "captureSourceSHA256": sha256_file(capture_source),
        "evaluatorSHA256": sha256_file(evaluator),
        "runnerSHA256": sha256_file(runner),
    }
    for key, digest in actual_tools.items():
        require_sha256(tools[key], f"tools.{key}")
        require(tools[key] == digest, f"locked tool identity mismatch: {key}")
    cases = require_array(contract["cases"], "cases")
    require(len(cases) >= 5, "parity case matrix is incomplete")
    identifiers: set[str] = set()
    covered: set[str] = set()
    for index, raw in enumerate(cases):
        case = validate_case_definition(raw, f"contract.cases[{index}]", set(coverage))
        require(case["id"] not in identifiers, f"duplicate parity case: {case['id']}")
        identifiers.add(case["id"])
        covered.update(case["coverage"])
    require(covered == set(coverage), "contract case coverage is not exact")
    return contract, sha256_file(path)


def validate_case_definition(
    value: Any, label: str, allowed_coverage: set[str]
) -> dict[str, Any]:
    case = require_object(value, label)
    require_exact_keys(
        case,
        {
            "id",
            "kind",
            "storage",
            "association",
            "sourceWidth",
            "sourceHeight",
            "targetWidth",
            "targetHeight",
            "framePatterns",
            "coverage",
        },
        label,
    )
    identifier = require_text(case["id"], f"{label}.id")
    require(
        all(character in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in identifier),
        f"{label}.id is not stable",
    )
    require(case["kind"] in {"pixel_spatial", "pixel_temporal", "alpha_spatial"}, f"{label}.kind is unsupported")
    for key in ("sourceWidth", "sourceHeight", "targetWidth", "targetHeight"):
        require_integer(case[key], f"{label}.{key}", 1)
    require(
        case["targetWidth"] >= case["sourceWidth"]
        and case["targetHeight"] >= case["sourceHeight"]
        and (
            case["targetWidth"] > case["sourceWidth"]
            or case["targetHeight"] > case["sourceHeight"]
        ),
        f"{label} is not an upscale",
    )
    patterns = [require_text(item, f"{label}.framePattern") for item in require_array(case["framePatterns"], f"{label}.framePatterns")]
    require(patterns, f"{label} has no frames")
    if case["kind"] == "pixel_temporal":
        require(len(patterns) == 3, f"{label} temporal fixture requires three frames")
    coverage = [require_text(item, f"{label}.coverage") for item in require_array(case["coverage"], f"{label}.coverage")]
    require(coverage and len(coverage) == len(set(coverage)), f"{label} coverage is empty or repeated")
    require(set(coverage).issubset(allowed_coverage), f"{label} coverage is unexpected")
    return case


def validate_capture_manifest(directory: Path) -> tuple[dict[str, Path], str]:
    manifest_path = directory / "artifact-manifest.json"
    manifest = require_object(load_json(manifest_path), "capture artifact manifest")
    require_exact_keys(manifest, ("schemaVersion", "artifacts"), "capture artifact manifest")
    require(manifest["schemaVersion"] == CAPTURE_MANIFEST_SCHEMA, "capture artifact-manifest schema mismatch")
    declared: dict[str, Path] = {}
    for index, raw in enumerate(require_array(manifest["artifacts"], "capture artifacts")):
        item, path, _ = validate_descriptor(directory, raw, f"capture artifact[{index}]")
        relative = item["path"]
        require(relative != "artifact-manifest.json", "capture manifest cannot seal itself")
        require(relative not in declared, f"duplicate capture artifact: {relative}")
        declared[relative] = path
    actual: set[str] = set()
    for path in directory.rglob("*"):
        require(not path.is_symlink(), f"symbolic link in capture: {path}")
        if path.is_file() and path != manifest_path:
            actual.add(path.relative_to(directory).as_posix())
    require(set(declared) == actual, "capture artifact manifest is not complete")
    return declared, sha256_file(manifest_path)


def validate_capture(
    directory: Path,
    contract: dict[str, Any],
    contract_sha: str,
) -> dict[str, Any]:
    require(directory.is_dir() and not directory.is_symlink(), "capture directory is missing or symbolic")
    sealed, manifest_sha = validate_capture_manifest(directory)
    capture_path = directory / "capture.json"
    require(capture_path.resolve() in {path.resolve() for path in sealed.values()}, "capture.json is not sealed")
    capture = require_object(load_json(capture_path), "capture")
    require_exact_keys(
        capture,
        {
            "schemaVersion",
            "contractSHA256",
            "captureSourceSHA256",
            "sourceRevision",
            "buildConfiguration",
            "processRunID",
            "runtime",
            "cases",
        },
        "capture",
    )
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "capture schema mismatch")
    require(capture["contractSHA256"] == contract_sha, "capture contract identity mismatch")
    require(capture["captureSourceSHA256"] == contract["tools"]["captureSourceSHA256"], "capture source identity mismatch")
    require_revision(capture["sourceRevision"], "capture.sourceRevision")
    require(capture["buildConfiguration"] == "Release", "capture is not Release")
    require_text(capture["processRunID"], "capture.processRunID")
    runtime = validate_runtime(capture["runtime"])
    contract_by_id = {case["id"]: case for case in contract["cases"]}
    cases: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(require_array(capture["cases"], "capture.cases")):
        observed = validate_captured_case(
            raw,
            f"capture.cases[{index}]",
            directory,
            sealed,
            contract_by_id,
            contract["tileSchedules"],
        )
        require(observed["id"] not in cases, f"capture repeats case {observed['id']}")
        cases[observed["id"]] = observed
    require(set(cases) == set(contract_by_id), "capture case set mismatch")
    return {
        "directory": directory.resolve(),
        "capture": capture,
        "runtime": runtime,
        "cases": cases,
        "manifestSHA256": manifest_sha,
    }


def validate_runtime(value: Any) -> dict[str, Any]:
    runtime = require_object(value, "capture.runtime")
    require_exact_keys(
        runtime,
        {
            "mode",
            "runtimeID",
            "releaseStatus",
            "manifestSHA256",
            "manifestFileSHA256",
            "sourceRevision",
            "builderSourceSHA256",
            "trustRootConfigured",
            "bindingVerified",
        },
        "capture.runtime",
    )
    require(runtime["mode"] in {"production", "fixture"}, "runtime mode is unsupported")
    require(runtime["runtimeID"] == "ash-p06-deterministic-v4", "capture runtime ID mismatch")
    require(runtime["releaseStatus"] == "release_qualified", "capture runtime is not release-qualified")
    require_sha256(runtime["manifestSHA256"], "runtime.manifestSHA256")
    require_sha256(runtime["manifestFileSHA256"], "runtime.manifestFileSHA256")
    source = require_text(runtime["sourceRevision"], "runtime.sourceRevision")
    require(
        len(source) in (40, 64)
        and all(character in "0123456789abcdef" for character in source),
        "runtime.sourceRevision is invalid",
    )
    require_sha256(runtime["builderSourceSHA256"], "runtime.builderSourceSHA256")
    require_bool(runtime["trustRootConfigured"], "runtime.trustRootConfigured")
    require_bool(runtime["bindingVerified"], "runtime.bindingVerified", True)
    return runtime


BACKEND_KEYS = {
    "visible",
    "attachments",
    "repeatVisible",
    "repeatAttachments",
    "tileSchedules",
}


def validate_backend_artifacts(
    value: Any,
    label: str,
    root: Path,
    sealed: Mapping[str, Path],
    expected_schedules: list[str],
) -> dict[str, Any]:
    backend = require_object(value, label)
    require_exact_keys(backend, BACKEND_KEYS, label)
    loaded: dict[str, Any] = {}
    for key in ("visible", "attachments", "repeatVisible", "repeatAttachments"):
        raw, path, data = validate_descriptor(root, backend[key], f"{label}.{key}")
        require(raw["path"] in sealed and sealed[raw["path"]].resolve() == path.resolve(), f"{label}.{key} is not sealed")
        loaded[key] = {"descriptor": raw, "path": path, "data": data}
    require(loaded["visible"]["data"] == loaded["repeatVisible"]["data"], f"{label} repeat visible pixels differ")
    require(loaded["attachments"]["data"] == loaded["repeatAttachments"]["data"], f"{label} repeat attachments differ")
    schedules: dict[str, dict[str, Any]] = {}
    for index, raw_schedule in enumerate(require_array(backend["tileSchedules"], f"{label}.tileSchedules")):
        schedule = require_object(raw_schedule, f"{label}.tileSchedules[{index}]")
        require_exact_keys(schedule, ("schedule", "artifact"), f"{label}.tileSchedules[{index}]")
        name = require_text(schedule["schedule"], f"{label}.tileSchedules[{index}].schedule")
        require(name not in schedules, f"{label} repeats tile schedule {name}")
        raw, path, data = validate_descriptor(root, schedule["artifact"], f"{label}.tileSchedules[{index}].artifact")
        require(raw["path"] in sealed and sealed[raw["path"]].resolve() == path.resolve(), f"{label} tile artifact is not sealed")
        require(data == loaded["visible"]["data"], f"{label} tile schedule {name} changed pixels")
        schedules[name] = {"descriptor": raw, "path": path, "data": data}
    require(list(schedules) == expected_schedules, f"{label} tile schedule set/order mismatch")
    loaded["tileSchedules"] = schedules
    return loaded


def validate_captured_case(
    value: Any,
    label: str,
    root: Path,
    sealed: Mapping[str, Path],
    contract_by_id: Mapping[str, dict[str, Any]],
    expected_schedules: list[str],
) -> dict[str, Any]:
    case = require_object(value, label)
    require_exact_keys(
        case,
        {
            "id",
            "definition",
            "cpu",
            "metal",
            "metadata",
            "repeatRunIdentityPass",
            "withinProcessCPUAndMetalPass",
            "tileScheduleIdentityPass",
            "temporalHistoryExercised",
            "temporalResetExercised",
            "sceneCutExercised",
            "stridePaddingAdversaryExercised",
            "arbitraryRationalPhaseExercised",
        },
        label,
    )
    identifier = require_text(case["id"], f"{label}.id")
    require(identifier in contract_by_id, f"unexpected captured case {identifier}")
    require(case["definition"] == contract_by_id[identifier], f"captured case definition differs: {identifier}")
    cpu = validate_backend_artifacts(case["cpu"], f"{label}.cpu", root, sealed, expected_schedules)
    metal = validate_backend_artifacts(case["metal"], f"{label}.metal", root, sealed, expected_schedules)
    require(cpu["visible"]["path"] != metal["visible"]["path"], f"{label} aliases CPU/Metal visible artifact")
    require(cpu["attachments"]["path"] != metal["attachments"]["path"], f"{label} aliases CPU/Metal attachment artifact")
    require(cpu["visible"]["data"] == metal["visible"]["data"], f"{label} CPU/Metal visible bytes differ")
    require(cpu["attachments"]["data"] == metal["attachments"]["data"], f"{label} CPU/Metal attachments differ")
    for key in ("repeatRunIdentityPass", "withinProcessCPUAndMetalPass", "tileScheduleIdentityPass"):
        require_bool(case[key], f"{label}.{key}", True)
    metadata_descriptor, metadata_path, _ = validate_descriptor(root, case["metadata"], f"{label}.metadata")
    require(metadata_descriptor["path"] in sealed and sealed[metadata_descriptor["path"]].resolve() == metadata_path.resolve(), f"{label} metadata is not sealed")
    metadata = validate_metadata(load_json(metadata_path), contract_by_id[identifier], label)
    definition = contract_by_id[identifier]
    coverage = set(definition["coverage"])
    expected_checks = {
        "temporalHistoryExercised": "temporal_history" in coverage,
        "temporalResetExercised": "temporal_reset" in coverage,
        "sceneCutExercised": "scene_cut" in coverage,
        "stridePaddingAdversaryExercised": "stride_padding_adversary" in coverage,
        "arbitraryRationalPhaseExercised": "arbitrary_rational_phase" in coverage,
    }
    for key, expected in expected_checks.items():
        observed = require_bool(case[key], f"{label}.{key}")
        if expected:
            require(observed, f"{label}.{key} must be true for declared coverage")
    return {
        "id": identifier,
        "definition": definition,
        "cpu": cpu,
        "metal": metal,
        "metadata": metadata,
        "metadataDescriptor": metadata_descriptor,
    }


def validate_metadata(value: Any, definition: dict[str, Any], label: str) -> dict[str, Any]:
    metadata = require_object(value, f"{label}.metadata document")
    coverage = set(definition["coverage"])
    temporal_required = bool(coverage & {"temporal_history", "temporal_reset", "scene_cut"})
    expected_keys = {
        "id",
        "sourceWidth",
        "sourceHeight",
        "targetWidth",
        "targetHeight",
        "horizontalUniquePhaseCount",
        "verticalUniquePhaseCount",
        "spatialPlanSHA256",
        "kernelIRSHA256",
        "cpuSourcePaddingByteCount",
        "cpuDestinationPaddingByteCount",
        "metalSourcePaddingByteCount",
        "metalDestinationPaddingByteCount",
        "cpuPaddingSentinelPreserved",
        "metalPaddingSentinelPreserved",
    }
    if temporal_required:
        expected_keys.add("temporal")
    require_exact_keys(
        metadata,
        expected_keys,
        f"{label}.metadata document",
    )
    require(metadata["id"] == definition["id"], f"{label} metadata ID mismatch")
    for key in ("sourceWidth", "sourceHeight", "targetWidth", "targetHeight"):
        require(metadata[key] == definition[key], f"{label} metadata geometry mismatch: {key}")
    require_sha256(metadata["spatialPlanSHA256"], f"{label}.spatialPlanSHA256")
    require_sha256(metadata["kernelIRSHA256"], f"{label}.kernelIRSHA256")
    horizontal = require_integer(metadata["horizontalUniquePhaseCount"], f"{label}.horizontalUniquePhaseCount", 1)
    vertical = require_integer(metadata["verticalUniquePhaseCount"], f"{label}.verticalUniquePhaseCount", 1)
    if "arbitrary_rational_phase" in coverage:
        require(horizontal > 1 and vertical > 1, f"{label} did not exercise rational phases")
    padding_fields = (
        "cpuSourcePaddingByteCount",
        "cpuDestinationPaddingByteCount",
        "metalSourcePaddingByteCount",
        "metalDestinationPaddingByteCount",
    )
    for key in padding_fields:
        count = require_integer(metadata[key], f"{label}.{key}", 0)
        if "stride_padding_adversary" in coverage:
            require(count > 0, f"{label} did not exercise padded stride: {key}")
    for key in ("cpuPaddingSentinelPreserved", "metalPaddingSentinelPreserved"):
        require_bool(metadata[key], f"{label}.{key}", True)
    if temporal_required:
        temporal = require_object(metadata["temporal"], f"{label}.temporal")
        require_exact_keys(
            temporal,
            {
                "generations",
                "historyFrameCounts",
                "continuousFrameDiffersFromReset",
                "sceneCutEqualsSpatialReset",
                "checkpointsCanonical",
            },
            f"{label}.temporal",
        )
        generations = [require_integer(item, f"{label}.generation", 0) for item in require_array(temporal["generations"], f"{label}.generations")]
        counts = [require_integer(item, f"{label}.historyFrameCount", 1) for item in require_array(temporal["historyFrameCounts"], f"{label}.historyFrameCounts")]
        require(generations == [1, 1, 2], f"{label} reset/scene generation evidence mismatch")
        require(counts == [1, 2, 1], f"{label} history frame-count evidence mismatch")
        require_bool(temporal["continuousFrameDiffersFromReset"], f"{label}.continuousFrameDiffersFromReset", True)
        require_bool(temporal["sceneCutEqualsSpatialReset"], f"{label}.sceneCutEqualsSpatialReset", True)
        require_bool(temporal["checkpointsCanonical"], f"{label}.checkpointsCanonical", True)
    return metadata


def load_candidate(path: Path) -> dict[str, Any]:
    value = require_object(load_json(path), "candidate identity")
    candidate = require_object(value.get("candidate", value), "candidate")
    required = {
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
    require_exact_keys(candidate, required, "candidate")
    require_revision(candidate["sourceCommit"], "candidate.sourceCommit")
    for key in (
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "releaseConfigurationSHA256",
        "appBundleSHA256",
    ):
        require_sha256(candidate[key], f"candidate.{key}")
    revision = require_text(candidate["runtimeSourceRevision"], "candidate.runtimeSourceRevision")
    require(
        len(revision) in (40, 64)
        and all(character in "0123456789abcdef" for character in revision),
        "candidate.runtimeSourceRevision is invalid",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_text(candidate[key], f"candidate.{key}")
    return candidate


def cross_process_compare(first: dict[str, Any], second: dict[str, Any]) -> None:
    first_capture = first["capture"]
    second_capture = second["capture"]
    require(first_capture["processRunID"] != second_capture["processRunID"], "cross-process run IDs are not distinct")
    for key in (
        "schemaVersion",
        "contractSHA256",
        "captureSourceSHA256",
        "sourceRevision",
        "buildConfiguration",
        "runtime",
    ):
        require(first_capture[key] == second_capture[key], f"cross-process capture identity differs: {key}")
    require(set(first["cases"]) == set(second["cases"]), "cross-process case set differs")
    for identifier in first["cases"]:
        left = first["cases"][identifier]
        right = second["cases"][identifier]
        for backend in ("cpu", "metal"):
            for key in ("visible", "attachments", "repeatVisible", "repeatAttachments"):
                require(left[backend][key]["data"] == right[backend][key]["data"], f"cross-process mismatch: {identifier}/{backend}/{key}")
            for schedule in left[backend]["tileSchedules"]:
                require(
                    left[backend]["tileSchedules"][schedule]["data"]
                    == right[backend]["tileSchedules"][schedule]["data"],
                    f"cross-process tile mismatch: {identifier}/{backend}/{schedule}",
                )
        require(left["metadata"] == right["metadata"], f"cross-process metadata differs: {identifier}")


def evaluate(
    contract_path: Path,
    capture_a_path: Path,
    capture_b_path: Path,
    candidate_path: Path,
    capture_source: Path,
    evaluator: Path,
    runner: Path,
    evidence_root: Path,
    allow_fixture_runtime: bool = False,
) -> dict[str, Any]:
    contract, contract_sha = validate_contract(
        contract_path, capture_source, evaluator, runner
    )
    first = validate_capture(capture_a_path, contract, contract_sha)
    second = validate_capture(capture_b_path, contract, contract_sha)
    cross_process_compare(first, second)
    candidate = load_candidate(candidate_path)
    require(first["capture"]["sourceRevision"] == candidate["sourceCommit"], "capture source revision differs from candidate")
    runtime = first["runtime"]
    require(runtime["manifestSHA256"] == candidate["runtimeManifestSHA256"], "capture runtime manifest identity differs from candidate")
    require(runtime["manifestFileSHA256"] == candidate["runtimeManifestFileSHA256"], "capture raw manifest identity differs from candidate")
    require(runtime["sourceRevision"] == candidate["runtimeSourceRevision"], "capture runtime source revision differs from candidate")
    production = runtime["mode"] == "production"
    if not allow_fixture_runtime:
        require(production, "final parity qualification requires the production runtime")
        require_bool(runtime["trustRootConfigured"], "runtime.trustRootConfigured", True)

    cases: list[dict[str, Any]] = []
    covered: set[str] = set()
    for definition in sorted(contract["cases"], key=lambda item: item["id"]):
        observed = first["cases"][definition["id"]]
        covered.update(definition["coverage"])
        cases.append(
            {
                "id": definition["id"],
                "coverage": definition["coverage"],
                "cpuVisibleArtifact": descriptor(
                    observed["cpu"]["visible"]["path"], evidence_root
                ),
                "metalVisibleArtifact": descriptor(
                    observed["metal"]["visible"]["path"], evidence_root
                ),
                "cpuAttachmentsArtifact": descriptor(
                    observed["cpu"]["attachments"]["path"], evidence_root
                ),
                "metalAttachmentsArtifact": descriptor(
                    observed["metal"]["attachments"]["path"], evidence_root
                ),
                "repeatRunIdentityPass": True,
                "crossProcessIdentityPass": True,
                "tileScheduleIdentityPass": True,
            }
        )
    require(covered == set(contract["parityCoverage"]), "evaluated coverage is not exact")
    return {
        "schemaVersion": contract["reportSchemaVersion"],
        "contractSHA256": contract_sha,
        "candidate": candidate,
        "releaseEligible": production,
        "identities": {
            "captureSourceSHA256": contract["tools"]["captureSourceSHA256"],
            "evaluatorSHA256": contract["tools"]["evaluatorSHA256"],
            "runnerSHA256": contract["tools"]["runnerSHA256"],
        },
        "comparison": contract["comparison"],
        "cases": cases,
        "byteParityGatePass": production,
    }


def make_root_manifest(root: Path, manifest_path: Path) -> dict[str, Any]:
    artifacts: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), f"symbolic link in parity evidence: {path}")
        if path.is_file() and path.resolve() != manifest_path.resolve():
            artifacts.append(descriptor(path, root))
    return {"schemaVersion": EVIDENCE_MANIFEST_SCHEMA, "artifacts": artifacts}


def verify_root_manifest(root: Path, manifest_path: Path) -> None:
    observed = require_object(load_json(manifest_path), "parity evidence manifest")
    expected = make_root_manifest(root, manifest_path)
    require(canonical_json(observed) == canonical_json(expected), "parity root seal differs from recomputed artifacts")
    for index, artifact_value in enumerate(observed["artifacts"]):
        validate_descriptor(root, artifact_value, f"root artifact[{index}]")


def command_evaluate(arguments: argparse.Namespace) -> None:
    root = arguments.evidence_root.resolve()
    require(root.is_dir() and not root.is_symlink(), "evidence root must be a directory")
    output = arguments.output.resolve()
    manifest = arguments.manifest.resolve()
    require(root in output.parents and root in manifest.parents, "report outputs must remain inside evidence root")
    require(not output.exists() and not manifest.exists(), "refusing to overwrite parity report or seal")
    report = evaluate(
        arguments.contract.resolve(),
        arguments.capture_a.resolve(),
        arguments.capture_b.resolve(),
        arguments.candidate.resolve(),
        arguments.capture_source.resolve(),
        arguments.evaluator.resolve(),
        arguments.runner.resolve(),
        root,
        arguments.allow_fixture_runtime,
    )
    write_json(output, report)
    write_json(manifest, make_root_manifest(root, manifest))


def command_verify(arguments: argparse.Namespace) -> None:
    root = arguments.evidence_root.resolve()
    report_path = arguments.report.resolve()
    expected = evaluate(
        arguments.contract.resolve(),
        arguments.capture_a.resolve(),
        arguments.capture_b.resolve(),
        arguments.candidate.resolve(),
        arguments.capture_source.resolve(),
        arguments.evaluator.resolve(),
        arguments.runner.resolve(),
        root,
        arguments.allow_fixture_runtime,
    )
    observed = load_json(report_path)
    require(canonical_json(observed) == canonical_json(expected), "published parity report differs from recomputed evidence")
    verify_root_manifest(root, arguments.manifest.resolve())


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    for name in ("evaluate", "verify"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--contract", type=Path, required=True)
        subparser.add_argument("--capture-a", type=Path, required=True)
        subparser.add_argument("--capture-b", type=Path, required=True)
        subparser.add_argument("--candidate", type=Path, required=True)
        subparser.add_argument("--capture-source", type=Path, required=True)
        subparser.add_argument("--evaluator", type=Path, required=True)
        subparser.add_argument("--runner", type=Path, required=True)
        subparser.add_argument("--evidence-root", type=Path, required=True)
        subparser.add_argument("--manifest", type=Path, required=True)
        subparser.add_argument("--allow-fixture-runtime", action="store_true")
        if name == "evaluate":
            subparser.add_argument("--output", type=Path, required=True)
            subparser.set_defaults(function=command_evaluate)
        else:
            subparser.add_argument("--report", type=Path, required=True)
            subparser.set_defaults(function=command_verify)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        arguments.function(arguments)
        return 0
    except ParityEvidenceError as error:
        print(f"parity qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
