#!/usr/bin/env python3
"""Fail-closed CPU/Metal byte-parity qualification for deterministic ASH v4."""

from __future__ import annotations

import argparse
import base64
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Iterable, Mapping


CONTRACT_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-contract-v2"
CAPTURE_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-capture-v2"
CAPTURE_MANIFEST_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-artifacts-v2"
REPORT_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-report-v2"
EVIDENCE_MANIFEST_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-evidence-v2"
RUN_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-run-v2"
SEMANTICS_SCHEMA = "mirmir-ash-v4-canonical-semantics-v2"
CHECKPOINT_SET_SCHEMA = "mirmir-ash-v4-checkpoint-set-v2"
RESUME_SET_SCHEMA = "mirmir-ash-v4-resume-set-v2"
EXECUTION_SCHEMA = "mirmir-ash-v4-bounded-temporal-execution-v1"
CONTIGUOUS_CHECKPOINT_SCHEMA = "ash.prepared-temporal-checkpoint.v4.5"
TILED_CHECKPOINT_SCHEMA = "ash.prepared-tiled-temporal-checkpoint.v4.1"
FIELD_COUNT_ATTACHMENT = "CVFieldCount"
FIELD_DETAIL_ATTACHMENT = "CVFieldDetail"
BOTTOM_FIELD_CHROMA_ATTACHMENT = "CVImageBufferChromaLocationBottomField"
SHA256_LENGTH = 64

# This list is intentionally evaluator-owned. Editing a contract and its cases
# together cannot silently weaken the non-waivable M7 parity surface.
REQUIRED_PARITY_COVERAGE = (
    "nv12_video_range",
    "nv12_full_range",
    "p010_video_range",
    "p010_full_range",
    "alpha_straight",
    "alpha_premultiplied",
    "hdr_attachment_semantics",
    "odd_legal_dimensions",
    "stride_padding_adversary",
    "arbitrary_rational_phase",
    "temporal_history",
    "temporal_reset",
    "scene_cut",
    "interlaced_tff",
    "interlaced_bff",
    "double_rate_field_timing",
    "combing_reconstruction",
    "telecine_3_2",
    "cadence_transition",
    "dominance_transition",
    "interlaced_scene_cut",
    "checkpoint_resume",
    "exact_timing_semantics",
    "exact_attachment_semantics",
    "progressive_attachment_normalization",
    "repeat_execution",
    "cross_process",
    "bounded_tiled_temporal_path",
    "tiled_allocation_contract",
    "tiled_checkpoint_schema",
    "temporal_tile_schedule",
    "tile_schedule",
)
EXPECTED_SCHEDULES = ("row_major", "reverse", "even_then_odd")
EXPECTED_SCHEDULE_PAIRS = (
    ("row_major", "raster"),
    ("reverse", "reverse_raster"),
    ("even_then_odd", "even_then_odd"),
)
EXPECTED_TILE_POLICY = {
    "policyID": "ash.release.parity.tiles.8x8-halo5-max64-v1",
    "tileWidth": 8,
    "tileHeight": 8,
    "searchHalo": 5,
    "maximumFrameWidth": 64,
    "maximumFrameHeight": 64,
}
EXPECTED_BOUNDED_CASE_ID = "nv12-video-forced-tiled-temporal-16x12-to-32x24"
PACKAGED_CAPTURE_FIELDS = (
    "evidenceRequestSHA256",
    "packagedCandidateIdentity",
)


def packaged_evidence_module():
    path = Path(__file__).resolve().with_name("packaged_candidate_evidence_v4.py")
    spec = importlib.util.spec_from_file_location(
        "parity_packaged_candidate_evidence_v4", path
    )
    if spec is None or spec.loader is None:
        raise ParityEvidenceError(
            "cannot load packaged-candidate evidence verifier"
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


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


def parse_json_bytes(data: bytes, label: str) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_duplicate_rejector,
            parse_constant=_reject_nonfinite,
        )
    except ParityEvidenceError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ParityEvidenceError(f"cannot parse JSON {label}: {error}") from error


def load_json(path: Path) -> Any:
    try:
        return parse_json_bytes(path.read_bytes(), str(path))
    except OSError as error:
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


def compact_canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
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
        for index in range(1, len(candidate.parts) + 1):
            require(
                not (root / Path(*candidate.parts[:index])).is_symlink(),
                f"{label} traverses a symbolic link",
            )
    except OSError as error:
        raise ParityEvidenceError(f"cannot inspect {label}: {error}") from error
    require(
        resolved.is_file() and not resolved.is_symlink(),
        f"{label} is not a regular file",
    )
    return resolved


def validate_descriptor(
    root: Path, value: Any, label: str
) -> tuple[dict[str, Any], Path, bytes]:
    item = require_object(value, label)
    require_exact_keys(item, ("path", "byteCount", "sha256"), label)
    path = safe_path(root, item["path"], label)
    expected_count = require_integer(item["byteCount"], f"{label}.byteCount", 0)
    expected_sha = require_sha256(item["sha256"], f"{label}.sha256")
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ParityEvidenceError(f"cannot read {label}: {error}") from error
    require(len(data) == expected_count, f"{label} byte count mismatch")
    require(sha256_bytes(data) == expected_sha, f"{label} SHA-256 mismatch")
    return item, path, data


def descriptor(path: Path, root: Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(root.resolve()).as_posix(),
        "byteCount": resolved.stat().st_size,
        "sha256": sha256_file(resolved),
    }


def validate_time_definition(value: Any, label: str) -> dict[str, int]:
    time = require_object(value, label)
    require_exact_keys(time, ("value", "timescale"), label)
    require_integer(time["value"], f"{label}.value")
    require_integer(time["timescale"], f"{label}.timescale", 1)
    return time


def validate_state_expectation(value: Any, label: str) -> dict[str, Any]:
    expectation = require_object(value, label)
    require_exact_keys(
        expectation,
        (
            "inputOrdinal",
            "dominance",
            "classification",
            "cadenceID",
            "historyGeneration",
        ),
        label,
    )
    require_integer(expectation["inputOrdinal"], f"{label}.inputOrdinal", 0)
    require_integer(
        expectation["historyGeneration"], f"{label}.historyGeneration", 1
    )
    require_text(expectation["cadenceID"], f"{label}.cadenceID")
    if expectation["dominance"] is not None:
        require(
            expectation["dominance"] in {"top_field_first", "bottom_field_first"},
            f"{label}.dominance is invalid",
        )
    if expectation["classification"] is not None:
        require(
            expectation["classification"] in {"interlaced", "telecine_3_2", "mixed"},
            f"{label}.classification is invalid",
        )
    return expectation


def validate_frame_definition(value: Any, label: str) -> dict[str, Any]:
    frame = require_object(value, label)
    require_exact_keys(
        frame,
        (
            "pattern",
            "topToken",
            "bottomToken",
            "presentationTime",
            "duration",
            "fieldDetail",
            "hdrProfile",
        ),
        label,
    )
    pattern = require_text(frame["pattern"], f"{label}.pattern")
    require(
        pattern
        in {
            "moving_edge_0",
            "moving_edge_1",
            "moving_edge_2",
            "scene_cut_white",
            "rational_detail",
            "transparent_edge",
            "field_pair",
        },
        f"{label}.pattern is unsupported",
    )
    if pattern == "field_pair":
        require_integer(frame["topToken"], f"{label}.topToken", 0)
        require_integer(frame["bottomToken"], f"{label}.bottomToken", 0)
    else:
        require(
            frame["topToken"] is None and frame["bottomToken"] is None,
            f"{label} non-field pattern has field tokens",
        )
    validate_time_definition(frame["presentationTime"], f"{label}.presentationTime")
    duration = validate_time_definition(frame["duration"], f"{label}.duration")
    require(duration["value"] > 0, f"{label}.duration must be positive")
    require(
        frame["fieldDetail"]
        in {"none", "temporal_top_first", "temporal_bottom_first"},
        f"{label}.fieldDetail is unsupported",
    )
    require(
        frame["hdrProfile"]
        in {"none", "pq_static", "pq_static_dynamic", "hlg_static_dynamic"},
        f"{label}.hdrProfile is unsupported",
    )
    return frame


CASE_KEYS = {
    "id",
    "kind",
    "storage",
    "association",
    "scanMode",
    "sourceWidth",
    "sourceHeight",
    "targetWidth",
    "targetHeight",
    "frames",
    "checkpointBoundaries",
    "stateExpectations",
    "coverage",
}


def validate_case_definition(
    value: Any, label: str, allowed_coverage: set[str]
) -> dict[str, Any]:
    case = require_object(value, label)
    require_exact_keys(case, CASE_KEYS, label)
    identifier = require_text(case["id"], f"{label}.id")
    require(
        re.fullmatch(r"[a-z0-9][a-z0-9-]*", identifier) is not None,
        f"{label}.id is not stable",
    )
    kind = case["kind"]
    require(
        kind
        in {
            "pixel_spatial",
            "pixel_temporal",
            "pixel_interlaced_temporal",
            "alpha_spatial",
        },
        f"{label}.kind is unsupported",
    )
    scan_mode = case["scanMode"]
    require(
        scan_mode in {"progressive", "interlaced_tff", "interlaced_bff"},
        f"{label}.scanMode is unsupported",
    )
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
    frames = [
        validate_frame_definition(raw, f"{label}.frames[{index}]")
        for index, raw in enumerate(require_array(case["frames"], f"{label}.frames"))
    ]
    require(frames, f"{label} has no frames")
    previous_time: Fraction | None = None
    for index, frame in enumerate(frames):
        pts = frame["presentationTime"]
        current = Fraction(pts["value"], pts["timescale"])
        if previous_time is not None:
            require(current > previous_time, f"{label} frame PTS is not increasing")
        previous_time = current
        if scan_mode == "progressive":
            require(frame["fieldDetail"] == "none", f"{label} progressive field detail")
        else:
            require(
                frame["fieldDetail"] != "none",
                f"{label}.frames[{index}] lacks field dominance",
            )
    if kind == "pixel_interlaced_temporal":
        require(scan_mode != "progressive", f"{label} interlaced case is progressive")
    else:
        require(scan_mode == "progressive", f"{label} non-interlaced scan mode")
    storage = require_text(case["storage"], f"{label}.storage")
    if kind == "alpha_spatial":
        require(storage in {"bgra8", "argb16_big_endian"}, f"{label} alpha storage")
        require(
            case["association"] in {"straight", "premultiplied"},
            f"{label} alpha association",
        )
    else:
        require(
            storage
            in {
                "nv12_video_range_8",
                "nv12_full_range_8",
                "p010_video_range_10",
                "p010_full_range_10",
            },
            f"{label} pixel storage",
        )
        require(case["association"] == "none", f"{label} pixel association")
    boundaries = [
        require_integer(item, f"{label}.checkpointBoundary", 0)
        for item in require_array(case["checkpointBoundaries"], f"{label}.checkpointBoundaries")
    ]
    require(
        boundaries == sorted(set(boundaries))
        and all(boundary < len(frames) - 1 for boundary in boundaries),
        f"{label} checkpoint boundaries are invalid",
    )
    expectations = [
        validate_state_expectation(raw, f"{label}.stateExpectations[{index}]")
        for index, raw in enumerate(
            require_array(case["stateExpectations"], f"{label}.stateExpectations")
        )
    ]
    expectation_ordinals = [item["inputOrdinal"] for item in expectations]
    require(
        expectation_ordinals == sorted(set(expectation_ordinals))
        and all(ordinal < len(frames) for ordinal in expectation_ordinals),
        f"{label} state expectations are invalid",
    )
    coverage = [
        require_text(item, f"{label}.coverage")
        for item in require_array(case["coverage"], f"{label}.coverage")
    ]
    require(
        coverage
        and len(coverage) == len(set(coverage))
        and set(coverage).issubset(allowed_coverage),
        f"{label} coverage is empty, repeated, or unexpected",
    )
    if "checkpoint_resume" in coverage:
        require(boundaries, f"{label} claims checkpoint resume without a boundary")
    return case


CONTRACT_KEYS = {
    "schemaVersion",
    "gateID",
    "buildConfiguration",
    "captureSchemaVersion",
    "reportSchemaVersion",
    "runArtifactSchemaVersion",
    "attachmentSchemaVersion",
    "comparison",
    "repeatExecutionCount",
    "crossProcessCaptureCount",
    "boundedTemporalCaseID",
    "temporalTilePolicy",
    "schedulePairs",
    "tileSchedules",
    "parityCoverage",
    "releaseRuntime",
    "tools",
    "cases",
}


def validate_contract(
    path: Path, capture_source: Path, evaluator: Path, runner: Path
) -> tuple[dict[str, Any], str]:
    contract = require_object(load_json(path), "contract")
    require_exact_keys(contract, CONTRACT_KEYS, "contract")
    require(contract["schemaVersion"] == CONTRACT_SCHEMA, "unsupported contract schema")
    require(
        contract["gateID"] == "deterministic-engine-v4-cpu-metal-byte-parity",
        "unexpected parity gate ID",
    )
    require(contract["buildConfiguration"] == "Release", "parity must use Release")
    require(contract["captureSchemaVersion"] == CAPTURE_SCHEMA, "capture schema mismatch")
    require(contract["reportSchemaVersion"] == REPORT_SCHEMA, "report schema mismatch")
    require(contract["runArtifactSchemaVersion"] == RUN_SCHEMA, "run schema mismatch")
    require(contract["attachmentSchemaVersion"] == SEMANTICS_SCHEMA, "semantics schema mismatch")
    require(
        contract["comparison"]
        == "exact_visible_plane_attachment_timeline_checkpoint_and_resume_bytes",
        "comparison is not complete byte-exact parity",
    )
    require_integer(contract["repeatExecutionCount"], "repeatExecutionCount", 2)
    require(contract["repeatExecutionCount"] == 2, "exactly two repeats required")
    require_integer(contract["crossProcessCaptureCount"], "crossProcessCaptureCount", 2)
    require(contract["crossProcessCaptureCount"] == 2, "exactly two processes required")
    schedules = tuple(
        require_text(value, "tile schedule")
        for value in require_array(contract["tileSchedules"], "tileSchedules")
    )
    require(schedules == EXPECTED_SCHEDULES, "tile schedule matrix mismatch")
    require(
        contract["boundedTemporalCaseID"] == EXPECTED_BOUNDED_CASE_ID,
        "bounded temporal case identity mismatch",
    )
    policy = require_object(contract["temporalTilePolicy"], "temporalTilePolicy")
    require_exact_keys(policy, EXPECTED_TILE_POLICY, "temporalTilePolicy")
    for key, expected in EXPECTED_TILE_POLICY.items():
        require(policy[key] == expected, f"temporal tile policy differs: {key}")
    schedule_pairs: list[tuple[str, str]] = []
    for index, raw in enumerate(
        require_array(contract["schedulePairs"], "schedulePairs")
    ):
        pair = require_object(raw, f"schedulePairs[{index}]")
        require_exact_keys(
            pair, ("spatialSchedule", "temporalSchedule"),
            f"schedulePairs[{index}]",
        )
        schedule_pairs.append((
            require_text(pair["spatialSchedule"], f"schedulePairs[{index}].spatialSchedule"),
            require_text(pair["temporalSchedule"], f"schedulePairs[{index}].temporalSchedule"),
        ))
    require(
        tuple(schedule_pairs) == EXPECTED_SCHEDULE_PAIRS,
        "spatial/temporal schedule pairing differs",
    )
    coverage = tuple(
        require_text(value, "coverage")
        for value in require_array(contract["parityCoverage"], "parityCoverage")
    )
    require(
        coverage == REQUIRED_PARITY_COVERAGE,
        "parity coverage differs from evaluator-owned M7 coverage",
    )
    runtime = require_object(contract["releaseRuntime"], "releaseRuntime")
    require_exact_keys(
        runtime,
        (
            "bundleRepositoryPath",
            "trustRootSourceRepositoryPath",
            "runtimeID",
            "requiredReleaseStatus",
        ),
        "releaseRuntime",
    )
    require(runtime["runtimeID"] == "ash-p06-deterministic-v4", "runtime ID is not P06")
    require(runtime["requiredReleaseStatus"] == "release_qualified", "runtime is not qualified")
    tools = require_object(contract["tools"], "tools")
    require_exact_keys(
        tools, ("captureSourceSHA256", "evaluatorSHA256", "runnerSHA256"), "tools"
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
    require(len(cases) >= 10, "parity case matrix is incomplete")
    identifiers: set[str] = set()
    covered: set[str] = set()
    for index, raw in enumerate(cases):
        case = validate_case_definition(raw, f"contract.cases[{index}]", set(coverage))
        require(case["id"] not in identifiers, f"duplicate parity case: {case['id']}")
        identifiers.add(case["id"])
        covered.update(case["coverage"])
    require(covered == set(coverage), "contract case coverage is not exact")
    bounded = next(
        (case for case in cases if case["id"] == contract["boundedTemporalCaseID"]),
        None,
    )
    require(bounded is not None, "bounded temporal case is absent")
    require(
        bounded["kind"] == "pixel_temporal"
        and bounded["scanMode"] == "progressive"
        and bounded["sourceWidth"] == 16
        and bounded["sourceHeight"] == 12
        and bounded["targetWidth"] == 32
        and bounded["targetHeight"] == 24
        and bounded["checkpointBoundaries"] == [1]
        and len(bounded["frames"]) >= 3,
        "bounded temporal case geometry or temporal range differs",
    )
    bounded_coverage = {
        "bounded_tiled_temporal_path",
        "tiled_allocation_contract",
        "tiled_checkpoint_schema",
        "temporal_tile_schedule",
        "tile_schedule",
    }
    require(
        bounded_coverage.issubset(set(bounded["coverage"])),
        "bounded temporal case omits evaluator-owned coverage",
    )
    for case in cases:
        if case["id"] != contract["boundedTemporalCaseID"]:
            require(
                not bounded_coverage.intersection(case["coverage"]),
                "bounded temporal coverage is claimed by an unforced case",
            )
    return contract, sha256_file(path)


def validate_capture_manifest(directory: Path) -> tuple[dict[str, Path], str]:
    manifest_path = directory / "artifact-manifest.json"
    manifest = require_object(load_json(manifest_path), "capture artifact manifest")
    require_exact_keys(manifest, ("schemaVersion", "artifacts"), "capture artifact manifest")
    require(
        manifest["schemaVersion"] == CAPTURE_MANIFEST_SCHEMA,
        "capture artifact-manifest schema mismatch",
    )
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


def validate_runtime(value: Any) -> dict[str, Any]:
    runtime = require_object(value, "capture.runtime")
    require_exact_keys(
        runtime,
        (
            "mode",
            "runtimeID",
            "releaseStatus",
            "manifestSHA256",
            "manifestFileSHA256",
            "sourceRevision",
            "builderSourceSHA256",
            "trustRootConfigured",
            "bindingVerified",
        ),
        "capture.runtime",
    )
    require(runtime["mode"] in {"production", "fixture"}, "runtime mode unsupported")
    require(runtime["runtimeID"] == "ash-p06-deterministic-v4", "runtime ID mismatch")
    require(runtime["releaseStatus"] == "release_qualified", "runtime not qualified")
    require_sha256(runtime["manifestSHA256"], "runtime.manifestSHA256")
    require_sha256(runtime["manifestFileSHA256"], "runtime.manifestFileSHA256")
    revision = require_text(runtime["sourceRevision"], "runtime.sourceRevision")
    require(
        len(revision) in (40, 64)
        and all(character in "0123456789abcdef" for character in revision),
        "runtime source revision is invalid",
    )
    require_sha256(runtime["builderSourceSHA256"], "runtime.builderSourceSHA256")
    require_bool(runtime["trustRootConfigured"], "runtime.trustRootConfigured")
    require_bool(runtime["bindingVerified"], "runtime.bindingVerified", True)
    return runtime


def validate_attachment_value(value: Any, label: str) -> None:
    item = require_object(value, label)
    require_exact_keys(item, ("kind", "value"), label)
    kind = require_text(item["kind"], f"{label}.kind")
    raw = item["value"]
    if kind == "null":
        require(raw is None, f"{label}.value must be null")
    elif kind == "boolean":
        require(type(raw) is bool, f"{label}.value must be boolean")
    elif kind in {"signed_integer", "unsigned_integer"}:
        text = require_text(raw, f"{label}.value")
        require(re.fullmatch(r"0|-?[1-9][0-9]*", text) is not None, f"{label} integer is noncanonical")
        if kind == "unsigned_integer":
            require(not text.startswith("-"), f"{label} unsigned integer is negative")
    elif kind == "real_ieee754_binary64":
        text = require_text(raw, f"{label}.value")
        require(re.fullmatch(r"[0-9a-f]{16}", text) is not None, f"{label} real bits invalid")
    elif kind in {"string", "date_iso8601"}:
        require(isinstance(raw, str), f"{label}.value must be string")
    elif kind == "data":
        decode_base64(raw, f"{label}.value")
    elif kind == "array":
        for index, nested in enumerate(require_array(raw, f"{label}.value")):
            validate_attachment_value(nested, f"{label}.value[{index}]")
    elif kind == "dictionary":
        entries = require_array(raw, f"{label}.value")
        keys: list[str] = []
        for index, nested in enumerate(entries):
            entry = require_object(nested, f"{label}.value[{index}]")
            require_exact_keys(entry, ("key", "value"), f"{label}.value[{index}]")
            keys.append(require_text(entry["key"], f"{label}.value[{index}].key"))
            validate_attachment_value(entry["value"], f"{label}.value[{index}].value")
        require(keys == sorted(set(keys)), f"{label} dictionary keys are not canonical")
    else:
        raise ParityEvidenceError(f"{label}.kind is unsupported: {kind}")


def validate_attachments(value: Any, label: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    keys: list[str] = []
    for index, raw in enumerate(require_array(value, label)):
        item = require_object(raw, f"{label}[{index}]")
        require_exact_keys(item, ("key", "mode", "value"), f"{label}[{index}]")
        key = require_text(item["key"], f"{label}[{index}].key")
        require(
            item["mode"] in {"should_propagate", "should_not_propagate"},
            f"{label}[{index}].mode is invalid",
        )
        validate_attachment_value(item["value"], f"{label}[{index}].value")
        keys.append(key)
        result.append(item)
    require(keys == sorted(set(keys)), f"{label} keys are not canonical")
    return result


def validate_time_record(
    value: Any, label: str, expected_value: int | None = None, expected_scale: int | None = None
) -> dict[str, int]:
    time = require_object(value, label)
    require_exact_keys(time, ("value", "timescale", "flags", "epoch"), label)
    observed_value = require_integer(time["value"], f"{label}.value")
    observed_scale = require_integer(time["timescale"], f"{label}.timescale", 1)
    require_integer(time["flags"], f"{label}.flags", 1)
    require_integer(time["epoch"], f"{label}.epoch")
    require(time["flags"] == 1 and time["epoch"] == 0, f"{label} is not numeric epoch zero")
    if expected_value is not None:
        require(observed_value == expected_value, f"{label}.value differs")
    if expected_scale is not None:
        require(observed_scale == expected_scale, f"{label}.timescale differs")
    return time


def decode_base64(value: Any, label: str) -> bytes:
    text = require_text(value, label)
    try:
        data = base64.b64decode(text, validate=True)
    except (ValueError, TypeError) as error:
        raise ParityEvidenceError(f"{label} is not canonical base64") from error
    require(base64.b64encode(data).decode("ascii") == text, f"{label} base64 differs")
    return data


def expected_interlaced_times(frame: Mapping[str, Any]) -> list[tuple[int, int, int, int]]:
    pts = frame["presentationTime"]
    duration = frame["duration"]
    common = math.lcm(pts["timescale"], duration["timescale"])
    require(common <= (2**31 - 1) // 2, "interlaced time scale overflows")
    output_scale = common * 2
    first = pts["value"] * (common // pts["timescale"]) * 2
    half_duration = duration["value"] * (common // duration["timescale"])
    return [
        (first, output_scale, half_duration, output_scale),
        (first + half_duration, output_scale, half_duration, output_scale),
    ]


def attachment_by_key(values: list[dict[str, Any]], key: str) -> dict[str, Any] | None:
    return next((item for item in values if item["key"] == key), None)


def integer_attachment(values: list[dict[str, Any]], key: str) -> int | None:
    item = attachment_by_key(values, key)
    if item is None:
        return None
    value = item["value"]
    require(value["kind"] in {"signed_integer", "unsigned_integer"}, f"{key} is not integer")
    return int(value["value"])


def expected_tile_grid(width: int, height: int) -> dict[str, int]:
    tile_width = EXPECTED_TILE_POLICY["tileWidth"]
    tile_height = EXPECTED_TILE_POLICY["tileHeight"]
    columns = (width + tile_width - 1) // tile_width
    rows = (height + tile_height - 1) // tile_height
    return {
        "frameWidth": width,
        "frameHeight": height,
        "columns": columns,
        "rows": rows,
        "tileCount": columns * rows,
        "fullFrameSampleCount": width * height,
    }


def expected_tile_descriptor(
    tile_index: int, width: int, height: int
) -> dict[str, Any]:
    grid = expected_tile_grid(width, height)
    tile_width = EXPECTED_TILE_POLICY["tileWidth"]
    tile_height = EXPECTED_TILE_POLICY["tileHeight"]
    halo = EXPECTED_TILE_POLICY["searchHalo"]
    column = tile_index % grid["columns"]
    row = tile_index // grid["columns"]
    x = column * tile_width
    y = row * tile_height
    active_width = min(tile_width, width - x)
    active_height = min(tile_height, height - y)
    retained_x = max(0, x - halo)
    retained_y = max(0, y - halo)
    retained_max_x = min(width, x + active_width + halo)
    retained_max_y = min(height, y + active_height + halo)
    return {
        "tileIndex": tile_index,
        "column": column,
        "row": row,
        "active": {
            "x": x, "y": y, "width": active_width, "height": active_height,
        },
        "retained": {
            "x": retained_x,
            "y": retained_y,
            "width": retained_max_x - retained_x,
            "height": retained_max_y - retained_y,
        },
    }


def validate_tile_grid(
    value: Any, width: int, height: int, label: str
) -> dict[str, Any]:
    grid = require_object(value, label)
    require_exact_keys(
        grid, ("frameWidth", "frameHeight", "policy", "columns", "rows"), label
    )
    expected = expected_tile_grid(width, height)
    require(
        grid["frameWidth"] == width
        and grid["frameHeight"] == height
        and grid["columns"] == expected["columns"]
        and grid["rows"] == expected["rows"],
        f"{label} geometry differs",
    )
    policy = require_object(grid["policy"], f"{label}.policy")
    require_exact_keys(policy, EXPECTED_TILE_POLICY, f"{label}.policy")
    require(policy == EXPECTED_TILE_POLICY, f"{label} tile policy differs")
    return grid


def validate_tiled_frame(
    value: Any,
    width: int,
    height: int,
    expected_ordinal: int,
    expected_frame_id: str,
    expected_stream_id: str,
    expected_format_identity: str,
    expected_state_raw: int,
    label: str,
) -> dict[str, Any]:
    frame = require_object(value, label)
    require_exact_keys(
        frame,
        (
            "frameID", "streamID", "formatIdentity", "ordinal",
            "presentationTime", "cadenceID", "grid", "tiles",
        ),
        label,
    )
    require(
        frame["frameID"] == expected_frame_id
        and frame["streamID"] == expected_stream_id
        and frame["ordinal"] == expected_ordinal
        and frame["cadenceID"] == "progressive",
        f"{label} identity or cadence differs",
    )
    require(
        require_sha256(frame["formatIdentity"], f"{label}.formatIdentity")
        == expected_format_identity,
        f"{label} format identity differs",
    )
    presentation = require_object(frame["presentationTime"], f"{label}.presentationTime")
    require_exact_keys(presentation, ("numerator", "denominator"), f"{label}.presentationTime")
    require_integer(presentation["numerator"], f"{label}.presentationTime.numerator", 0)
    require_integer(presentation["denominator"], f"{label}.presentationTime.denominator", 1)
    validate_tile_grid(frame["grid"], width, height, f"{label}.grid")
    tiles = require_array(frame["tiles"], f"{label}.tiles")
    grid = expected_tile_grid(width, height)
    require(len(tiles) == grid["tileCount"], f"{label} tile count differs")
    maximum_retained = (
        (EXPECTED_TILE_POLICY["tileWidth"] + 2 * EXPECTED_TILE_POLICY["searchHalo"])
        * (EXPECTED_TILE_POLICY["tileHeight"] + 2 * EXPECTED_TILE_POLICY["searchHalo"])
    )
    for index, raw in enumerate(tiles):
        tile_label = f"{label}.tiles[{index}]"
        tile = require_object(raw, tile_label)
        require_exact_keys(
            tile,
            (
                "descriptor", "minimumCode", "maximumCode",
                "retainedSamples", "ashStateRawValue",
            ),
            tile_label,
        )
        expected_descriptor = expected_tile_descriptor(index, width, height)
        require(tile["descriptor"] == expected_descriptor, f"{tile_label} descriptor differs")
        minimum = require_integer(tile["minimumCode"], f"{tile_label}.minimumCode", 0)
        maximum = require_integer(tile["maximumCode"], f"{tile_label}.maximumCode", 1)
        require(minimum < maximum <= 65_535, f"{tile_label} code range differs")
        samples = require_array(tile["retainedSamples"], f"{tile_label}.retainedSamples")
        retained = expected_descriptor["retained"]
        expected_count = retained["width"] * retained["height"]
        require(
            len(samples) == expected_count <= maximum_retained,
            f"{tile_label} retained allocation differs",
        )
        require(
            all(type(sample) is int and minimum <= sample <= maximum for sample in samples),
            f"{tile_label} retained samples differ",
        )
        require(
            require_integer(tile["ashStateRawValue"], f"{tile_label}.ashStateRawValue", 0)
            == expected_state_raw,
            f"{tile_label} ASH state differs",
        )
    return frame


def validate_tiled_checkpoint(
    checkpoint: Mapping[str, Any],
    definition: Mapping[str, Any],
    ordinal: int,
    label: str,
    previous_generation: int | None = None,
) -> dict[str, Any]:
    require_exact_keys(
        checkpoint,
        (
            "schemaID", "planSHA256", "runtimeManifestSHA256", "formatIdentity",
            "sourceStorage", "sourceWidth", "sourceHeight", "targetWidth",
            "targetHeight", "scanModeID", "tilePolicy",
            "lastCompletedInputOrdinal", "nextOutputOrdinal",
            "lastCompletedOutputPresentationTime", "history",
            "previousMeasurementHistory", "previousSourceTiledFrame",
            "previousMeasurementStateRawValue",
        ),
        label,
    )
    require(checkpoint["schemaID"] == TILED_CHECKPOINT_SCHEMA, f"{label} tiled checkpoint schema differs")
    for identity_key in ("planSHA256", "runtimeManifestSHA256", "formatIdentity"):
        require_sha256(checkpoint[identity_key], f"{label}.{identity_key}")
    require(
        checkpoint["sourceStorage"] == "nv12_video_range_8_bit"
        and checkpoint["sourceWidth"] == definition["sourceWidth"]
        and checkpoint["sourceHeight"] == definition["sourceHeight"]
        and checkpoint["targetWidth"] == definition["targetWidth"]
        and checkpoint["targetHeight"] == definition["targetHeight"]
        and checkpoint["scanModeID"] == "progressive"
        and checkpoint["tilePolicy"] == EXPECTED_TILE_POLICY,
        f"{label} tiled route identity differs",
    )
    require(
        checkpoint["lastCompletedInputOrdinal"] == ordinal
        and checkpoint["nextOutputOrdinal"] == ordinal + 1,
        f"{label} tiled checkpoint ordinal differs",
    )
    state_raw = require_integer(
        checkpoint["previousMeasurementStateRawValue"],
        f"{label}.previousMeasurementStateRawValue", 0,
    )
    history = require_object(checkpoint["history"], f"{label}.history")
    require_exact_keys(history, ("generation", "capacity", "entries"), f"{label}.history")
    generation = require_integer(history["generation"], f"{label}.history.generation", 1)
    if previous_generation is not None:
        require(
            previous_generation <= generation <= previous_generation + 1,
            f"{label} checkpoint generation progression differs",
        )
    require(history["capacity"] == 1, f"{label} tiled history capacity differs")
    entries = require_array(history["entries"], f"{label}.history.entries")
    require(len(entries) == 1, f"{label} tiled history entry count differs")
    entry = require_object(entries[0], f"{label}.history.entries[0]")
    require_exact_keys(entry, ("frame",), f"{label}.history.entries[0]")
    target_frame = validate_tiled_frame(
        entry["frame"], definition["targetWidth"], definition["targetHeight"],
        ordinal, f"v4-frame-{ordinal}", "primary-video",
        checkpoint["formatIdentity"], state_raw, f"{label}.history.entries[0].frame",
    )
    source_frame = validate_tiled_frame(
        checkpoint["previousSourceTiledFrame"],
        definition["sourceWidth"], definition["sourceHeight"], ordinal,
        f"v4-measurement-{ordinal}", "primary-video-measurement",
        checkpoint["formatIdentity"], state_raw, f"{label}.previousSourceTiledFrame",
    )
    require(
        target_frame["presentationTime"] == source_frame["presentationTime"]
        == checkpoint["lastCompletedOutputPresentationTime"],
        f"{label} tiled presentation time differs",
    )
    measurement = require_object(
        checkpoint["previousMeasurementHistory"], f"{label}.previousMeasurementHistory"
    )
    require_exact_keys(
        measurement,
        (
            "storage", "sourceWidth", "sourceHeight", "windowWidth",
            "windowHeight", "normalizedLumaWindowQ16",
        ),
        f"{label}.previousMeasurementHistory",
    )
    require(
        measurement["storage"] == checkpoint["sourceStorage"]
        and measurement["sourceWidth"] == definition["sourceWidth"]
        and measurement["sourceHeight"] == definition["sourceHeight"]
        and measurement["windowWidth"] == 32
        and measurement["windowHeight"] == 32,
        f"{label} tiled measurement identity differs",
    )
    window = require_array(
        measurement["normalizedLumaWindowQ16"],
        f"{label}.previousMeasurementHistory.normalizedLumaWindowQ16",
    )
    require(
        len(window) == 1024
        and all(type(sample) is int and 0 <= sample <= 65_536 for sample in window),
        f"{label} tiled measurement window differs",
    )
    return {
        "cadenceID": "progressive",
        "classification": None,
        "dominance": None,
        "historyGeneration": generation,
        "canonicalData": compact_canonical_json(checkpoint),
    }


def validate_checkpoint_set(
    data: bytes, definition: Mapping[str, Any], label: str
) -> dict[int, dict[str, Any]]:
    document = require_object(parse_json_bytes(data, label), label)
    require(canonical_json(document) == data, f"{label} is not canonical JSON")
    require_exact_keys(document, ("schemaVersion", "caseID", "entries"), label)
    require(document["schemaVersion"] == CHECKPOINT_SET_SCHEMA, f"{label} schema differs")
    require(document["caseID"] == definition["id"], f"{label} case ID differs")
    entries = require_array(document["entries"], f"{label}.entries")
    expected_count = 0 if definition["kind"] == "alpha_spatial" else len(definition["frames"])
    require(len(entries) == expected_count, f"{label} checkpoint count differs")
    states: dict[int, dict[str, Any]] = {}
    previous_generation = 0
    for index, raw in enumerate(entries):
        entry = require_object(raw, f"{label}.entries[{index}]")
        require_exact_keys(
            entry, ("inputOrdinal", "canonicalDataBase64", "canonicalSHA256"), f"{label}.entries[{index}]"
        )
        ordinal = require_integer(entry["inputOrdinal"], f"{label}.entries[{index}].inputOrdinal", 0)
        require(ordinal == index, f"{label} checkpoint order differs")
        checkpoint_data = decode_base64(entry["canonicalDataBase64"], f"{label}.entries[{index}].canonicalDataBase64")
        require(
            require_sha256(entry["canonicalSHA256"], f"{label}.entries[{index}].canonicalSHA256")
            == sha256_bytes(checkpoint_data),
            f"{label} checkpoint SHA differs",
        )
        checkpoint = require_object(
            parse_json_bytes(checkpoint_data, f"{label}.checkpoint[{index}]"),
            f"{label}.checkpoint[{index}]",
        )
        require(
            compact_canonical_json(checkpoint) == checkpoint_data,
            f"{label} checkpoint {index} is not canonical",
        )
        if definition["id"] == EXPECTED_BOUNDED_CASE_ID:
            state = validate_tiled_checkpoint(
                checkpoint,
                definition,
                index,
                f"{label}.checkpoint[{index}]",
                previous_generation,
            )
            previous_generation = state["historyGeneration"]
            states[index] = state
            continue
        checkpoint_keys = (
            "schemaID",
            "planSHA256",
            "runtimeManifestSHA256",
            "formatIdentity",
            "sourceStorage",
            "sourceWidth",
            "sourceHeight",
            "scanModeID",
            "lastCompletedInputOrdinal",
            "nextOutputOrdinal",
            "lastCompletedOutputPresentationTime",
            "history",
            "previousMeasurementHistory",
            "previousSourceLumaFrame",
            "previousMeasurementStateRawValue",
        )
        if definition["scanMode"] != "progressive":
            checkpoint_keys += (
                "previousInterlacedFrame",
                "fieldCadenceState",
            )
        require_exact_keys(
            checkpoint,
            checkpoint_keys,
            f"{label}.checkpoint[{index}]",
        )
        require(
            checkpoint["schemaID"] == CONTIGUOUS_CHECKPOINT_SCHEMA,
            f"{label} checkpoint schema differs",
        )
        for identity_key in (
            "planSHA256",
            "runtimeManifestSHA256",
            "formatIdentity",
        ):
            require_sha256(
                checkpoint[identity_key],
                f"{label}.checkpoint[{index}].{identity_key}",
            )
        storage = {
            "nv12_video_range_8": "nv12_video_range_8_bit",
            "nv12_full_range_8": "nv12_full_range_8_bit",
            "p010_video_range_10": "p010_video_range_10_bit",
            "p010_full_range_10": "p010_full_range_10_bit",
        }[definition["storage"]]
        require(
            checkpoint["sourceStorage"] == storage
            and checkpoint["sourceWidth"] == definition["sourceWidth"]
            and checkpoint["sourceHeight"] == definition["sourceHeight"],
            f"{label} checkpoint source identity differs",
        )
        require(
            checkpoint.get("lastCompletedInputOrdinal") == index,
            f"{label} checkpoint input ordinal differs",
        )
        outputs_per_input = 2 if definition["kind"] == "pixel_interlaced_temporal" else 1
        require(
            checkpoint.get("nextOutputOrdinal") == (index + 1) * outputs_per_input,
            f"{label} checkpoint output ordinal differs",
        )
        expected_scan = {
            "progressive": "progressive",
            "interlaced_tff": "interlaced_tff_double_rate",
            "interlaced_bff": "interlaced_bff_double_rate",
        }[definition["scanMode"]]
        require(checkpoint.get("scanModeID") == expected_scan, f"{label} checkpoint scan mode differs")
        history = require_object(checkpoint.get("history"), f"{label}.checkpoint[{index}].history")
        require_exact_keys(
            history,
            ("generation", "capacity", "frames"),
            f"{label}.checkpoint[{index}].history",
        )
        require(history["capacity"] == 1, f"{label} checkpoint history capacity differs")
        generation = require_integer(history.get("generation"), f"{label}.checkpoint[{index}].generation", 1)
        require(
            previous_generation <= generation
            <= previous_generation + outputs_per_input,
            f"{label} checkpoint generation progression differs",
        )
        previous_generation = generation
        frames = require_array(history.get("frames"), f"{label}.checkpoint[{index}].history.frames")
        require(frames, f"{label} checkpoint has empty history")
        latest = require_object(frames[-1], f"{label}.checkpoint[{index}].history.latest")
        require(
            latest.get("ordinal") == (index + 1) * outputs_per_input - 1,
            f"{label} checkpoint latest output ordinal differs",
        )
        cadence_id = require_text(latest.get("cadenceID"), f"{label}.checkpoint[{index}].cadenceID")
        cadence_state_raw = checkpoint.get("fieldCadenceState")
        dominance: str | None = None
        classification: str | None = None
        if cadence_state_raw is not None:
            cadence_state = require_object(cadence_state_raw, f"{label}.checkpoint[{index}].fieldCadenceState")
            dominance = require_text(cadence_state.get("dominance"), f"{label}.checkpoint[{index}].dominance")
            classification = require_text(cadence_state.get("classification"), f"{label}.checkpoint[{index}].classification")
        if definition["scanMode"] == "progressive":
            require(
                dominance is None
                and classification is None
                and cadence_id == "progressive"
                and checkpoint.get("previousInterlacedFrame") is None,
                f"{label} progressive cadence state differs",
            )
        else:
            require(
                dominance is not None
                and classification is not None
                and checkpoint["previousInterlacedFrame"] is not None,
                f"{label} lacks interlaced cadence state",
            )
        require(
            checkpoint["previousMeasurementHistory"] is not None
            and checkpoint["previousSourceLumaFrame"] is not None
            and type(checkpoint["previousMeasurementStateRawValue"]) is int,
            f"{label} checkpoint omits temporal reconstruction state",
        )
        states[index] = {
            "cadenceID": cadence_id,
            "classification": classification,
            "dominance": dominance,
            "historyGeneration": generation,
            "canonicalData": checkpoint_data,
        }
    for expected in definition["stateExpectations"]:
        observed = states[expected["inputOrdinal"]]
        for key in ("cadenceID", "classification", "dominance", "historyGeneration"):
            require(observed[key] == expected[key], f"{label} state expectation differs: {expected['inputOrdinal']}/{key}")
    return states


def validate_semantics(
    data: bytes,
    definition: Mapping[str, Any],
    checkpoint_states: Mapping[int, Mapping[str, Any]],
    label: str,
) -> dict[str, Any]:
    document = require_object(parse_json_bytes(data, label), label)
    require(canonical_json(document) == data, f"{label} is not canonical JSON")
    require_exact_keys(document, ("schemaVersion", "caseID", "inputs"), label)
    require(document["schemaVersion"] == SEMANTICS_SCHEMA, f"{label} schema differs")
    require(document["caseID"] == definition["id"], f"{label} case ID differs")
    inputs = require_array(document["inputs"], f"{label}.inputs")
    require(len(inputs) == len(definition["frames"]), f"{label} input count differs")
    next_output = 0
    previous_generation = 0
    for input_index, (raw, frame) in enumerate(zip(inputs, definition["frames"])):
        item = require_object(raw, f"{label}.inputs[{input_index}]")
        require_exact_keys(
            item,
            ("inputOrdinal", "timing", "effectiveDominance", "sourceAttachments", "outputs"),
            f"{label}.inputs[{input_index}]",
        )
        require(item["inputOrdinal"] == input_index, f"{label} input ordinal differs")
        timing = require_object(item["timing"], f"{label}.inputs[{input_index}].timing")
        require_exact_keys(timing, ("presentationTime", "duration"), f"{label}.inputs[{input_index}].timing")
        validate_time_record(
            timing["presentationTime"],
            f"{label}.inputs[{input_index}].presentationTime",
            frame["presentationTime"]["value"],
            frame["presentationTime"]["timescale"],
        )
        validate_time_record(
            timing["duration"],
            f"{label}.inputs[{input_index}].duration",
            frame["duration"]["value"],
            frame["duration"]["timescale"],
        )
        source_attachments = validate_attachments(
            item["sourceAttachments"], f"{label}.inputs[{input_index}].sourceAttachments"
        )
        if frame["fieldDetail"] == "none":
            expected_dominance = None
        elif frame["fieldDetail"] == "temporal_top_first":
            expected_dominance = "top_field_first"
        else:
            expected_dominance = "bottom_field_first"
        require(item["effectiveDominance"] == expected_dominance, f"{label} effective dominance differs")
        if expected_dominance is not None:
            require(
                integer_attachment(source_attachments, FIELD_COUNT_ATTACHMENT)
                == 2,
                f"{label} source FieldCount differs",
            )
            require(
                attachment_by_key(source_attachments, FIELD_DETAIL_ATTACHMENT)
                is not None,
                f"{label} source FieldDetail missing",
            )
        outputs = require_array(item["outputs"], f"{label}.inputs[{input_index}].outputs")
        expected_count = 2 if expected_dominance is not None else 1
        require(len(outputs) == expected_count, f"{label} output count differs")
        if expected_dominance is None:
            expected_times = [
                (
                    frame["presentationTime"]["value"],
                    frame["presentationTime"]["timescale"],
                    frame["duration"]["value"],
                    frame["duration"]["timescale"],
                )
            ]
            expected_fields: list[str] = ["progressive"]
        else:
            expected_times = expected_interlaced_times(frame)
            expected_fields = (
                ["top", "bottom"]
                if expected_dominance == "top_field_first"
                else ["bottom", "top"]
            )
        state = checkpoint_states.get(input_index)
        if state is not None:
            require(
                state["dominance"] == expected_dominance,
                f"{label} checkpoint dominance differs from input",
            )
        for output_index, (output_raw, expected_time, expected_field) in enumerate(
            zip(outputs, expected_times, expected_fields)
        ):
            output = require_object(output_raw, f"{label}.inputs[{input_index}].outputs[{output_index}]")
            require_exact_keys(
                output,
                (
                    "outputOrdinal",
                    "presentationTime",
                    "duration",
                    "sourceField",
                    "cadenceID",
                    "classification",
                    "historyGeneration",
                    "attachments",
                ),
                f"{label}.inputs[{input_index}].outputs[{output_index}]",
            )
            require(output["outputOrdinal"] == next_output, f"{label} output ordinal differs")
            next_output += 1
            validate_time_record(
                output["presentationTime"],
                f"{label}.outputs[{next_output-1}].presentationTime",
                expected_time[0],
                expected_time[1],
            )
            validate_time_record(
                output["duration"],
                f"{label}.outputs[{next_output-1}].duration",
                expected_time[2],
                expected_time[3],
            )
            require(output["sourceField"] == expected_field, f"{label} source field order differs")
            generation = require_integer(
                output["historyGeneration"],
                f"{label}.outputs[{next_output-1}].historyGeneration",
                1,
            )
            require(
                previous_generation <= generation
                <= previous_generation + 1,
                f"{label} output history generation progression differs",
            )
            previous_generation = generation
            if state is not None:
                for key in ("cadenceID", "classification"):
                    require(output[key] == state[key], f"{label} output {key} differs from checkpoint")
                remaining_outputs = len(outputs) - output_index - 1
                require(
                    generation <= state["historyGeneration"]
                    and state["historyGeneration"] - generation
                    <= remaining_outputs,
                    f"{label} output history generation differs from checkpoint",
                )
            attachments = validate_attachments(output["attachments"], f"{label}.outputs[{next_output-1}].attachments")
            expected_attachments = [
                item
                for item in source_attachments
                if item["key"] not in {
                    FIELD_DETAIL_ATTACHMENT,
                    BOTTOM_FIELD_CHROMA_ATTACHMENT,
                }
            ]
            if expected_dominance is not None:
                require(
                    integer_attachment(attachments, FIELD_COUNT_ATTACHMENT)
                    == 1,
                    f"{label} output FieldCount differs",
                )
                require(
                    attachment_by_key(attachments, FIELD_DETAIL_ATTACHMENT)
                    is None,
                    f"{label} output retains FieldDetail",
                )
                require(
                    attachment_by_key(
                        attachments, BOTTOM_FIELD_CHROMA_ATTACHMENT
                    ) is None,
                    f"{label} progressive output retains bottom-field chroma",
                )
                expected_attachments = [
                    {
                        **item,
                        "value": {
                            "kind": "signed_integer",
                            "value": "1",
                        },
                    }
                    if item["key"] == FIELD_COUNT_ATTACHMENT
                    else item
                    for item in expected_attachments
                ]
            else:
                require(
                    attachment_by_key(
                        attachments, FIELD_DETAIL_ATTACHMENT
                    ) is None
                    and attachment_by_key(
                        attachments, BOTTOM_FIELD_CHROMA_ATTACHMENT
                    )
                    is None,
                    f"{label} progressive output has stale field attachments",
                )
            require(
                attachments == expected_attachments,
                f"{label} output attachment semantics differ",
            )
    return document


def validate_resume_set(data: bytes, definition: Mapping[str, Any], label: str) -> dict[str, Any]:
    document = require_object(parse_json_bytes(data, label), label)
    require(canonical_json(document) == data, f"{label} is not canonical JSON")
    require_exact_keys(document, ("schemaVersion", "caseID", "entries"), label)
    require(document["schemaVersion"] == RESUME_SET_SCHEMA, f"{label} schema differs")
    require(document["caseID"] == definition["id"], f"{label} case ID differs")
    entries = require_array(document["entries"], f"{label}.entries")
    require(len(entries) == len(definition["checkpointBoundaries"]), f"{label} resume count differs")
    for index, (raw, boundary) in enumerate(zip(entries, definition["checkpointBoundaries"])):
        entry = require_object(raw, f"{label}.entries[{index}]")
        require_exact_keys(
            entry,
            (
                "boundaryInputOrdinal",
                "uninterruptedVisibleBase64",
                "resumedVisibleBase64",
                "uninterruptedSemanticsBase64",
                "resumedSemanticsBase64",
                "uninterruptedFinalCheckpointBase64",
                "resumedFinalCheckpointBase64",
            ),
            f"{label}.entries[{index}]",
        )
        require(entry["boundaryInputOrdinal"] == boundary, f"{label} boundary differs")
        pairs = (
            ("uninterruptedVisibleBase64", "resumedVisibleBase64"),
            ("uninterruptedSemanticsBase64", "resumedSemanticsBase64"),
            ("uninterruptedFinalCheckpointBase64", "resumedFinalCheckpointBase64"),
        )
        for left_key, right_key in pairs:
            left = decode_base64(entry[left_key], f"{label}.{left_key}")
            right = decode_base64(entry[right_key], f"{label}.{right_key}")
            require(left and left == right, f"{label} resumed identity differs: {boundary}/{right_key}")
        final_checkpoint = decode_base64(
            entry["resumedFinalCheckpointBase64"], f"{label}.resumedFinalCheckpointBase64"
        )
        parsed = parse_json_bytes(final_checkpoint, f"{label}.finalCheckpoint")
        require(compact_canonical_json(parsed) == final_checkpoint, f"{label} final checkpoint is not canonical")
        parsed_object = require_object(parsed, f"{label}.finalCheckpoint")
        require(
            parsed_object.get("lastCompletedInputOrdinal")
            == len(definition["frames"]) - 1,
            f"{label} final checkpoint ordinal differs",
        )
        if definition["id"] == EXPECTED_BOUNDED_CASE_ID:
            validate_tiled_checkpoint(
                parsed_object,
                definition,
                len(definition["frames"]) - 1,
                f"{label}.finalCheckpoint",
            )
        else:
            require(
                parsed_object.get("schemaID") == CONTIGUOUS_CHECKPOINT_SCHEMA,
                f"{label} final checkpoint schema differs",
            )
    return document


RUN_KEYS = {"visible", "semantics", "checkpoints", "resume", "execution"}
IDENTITY_RUN_KEYS = ("visible", "semantics", "checkpoints", "resume")


def validate_execution_evidence(
    data: bytes,
    definition: Mapping[str, Any],
    checkpoint_states: Mapping[int, Mapping[str, Any]],
    backend: str,
    spatial_schedule: str,
    temporal_schedule: str,
    label: str,
) -> dict[str, Any]:
    document = require_object(parse_json_bytes(data, label), label)
    require(canonical_json(document) == data, f"{label} is not canonical JSON")
    require_exact_keys(
        document,
        (
            "schemaVersion", "caseID", "backend", "spatialSchedule",
            "temporalSchedule", "checkpointSchemaID", "checkpointSHA256s",
            "boundedRoute",
        ),
        label,
    )
    require(document["schemaVersion"] == EXECUTION_SCHEMA, f"{label} schema differs")
    require(document["caseID"] == definition["id"], f"{label} case ID differs")
    require(document["backend"] == backend, f"{label} backend differs")
    require(document["spatialSchedule"] == spatial_schedule, f"{label} spatial schedule differs")
    require(document["temporalSchedule"] == temporal_schedule, f"{label} temporal schedule differs")
    observed_shas = [
        require_sha256(value, f"{label}.checkpointSHA256s[{index}]")
        for index, value in enumerate(
            require_array(document["checkpointSHA256s"], f"{label}.checkpointSHA256s")
        )
    ]
    expected_shas = [
        sha256_bytes(checkpoint_states[index]["canonicalData"])
        for index in sorted(checkpoint_states)
    ]
    require(observed_shas == expected_shas, f"{label} checkpoint identities differ")
    bounded = definition["id"] == EXPECTED_BOUNDED_CASE_ID
    expected_checkpoint_schema = (
        "none" if definition["kind"] == "alpha_spatial"
        else TILED_CHECKPOINT_SCHEMA if bounded
        else CONTIGUOUS_CHECKPOINT_SCHEMA
    )
    require(
        document["checkpointSchemaID"] == expected_checkpoint_schema,
        f"{label} checkpoint schema claim differs",
    )
    if not bounded:
        require(document["boundedRoute"] is None, f"{label} falsely claims bounded route")
        return document
    route = require_object(document["boundedRoute"], f"{label}.boundedRoute")
    require_exact_keys(
        route,
        (
            "usesBoundedTiledTemporalPath", "tilePolicy", "sourceGrid",
            "targetGrid", "allocationContract",
        ),
        f"{label}.boundedRoute",
    )
    require_bool(
        route["usesBoundedTiledTemporalPath"],
        f"{label}.boundedRoute.usesBoundedTiledTemporalPath",
        True,
    )
    require(route["tilePolicy"] == EXPECTED_TILE_POLICY, f"{label} bounded policy differs")
    for name, width_key, height_key in (
        ("sourceGrid", "sourceWidth", "sourceHeight"),
        ("targetGrid", "targetWidth", "targetHeight"),
    ):
        grid = require_object(route[name], f"{label}.boundedRoute.{name}")
        require_exact_keys(
            grid,
            (
                "frameWidth", "frameHeight", "columns", "rows",
                "tileCount", "fullFrameSampleCount",
            ),
            f"{label}.boundedRoute.{name}",
        )
        expected = expected_tile_grid(definition[width_key], definition[height_key])
        require(grid == expected, f"{label} {name} diagnostics differ")
        require(grid["tileCount"] > 1, f"{label} {name} did not force multiple tiles")
    allocation = require_object(
        route["allocationContract"], f"{label}.boundedRoute.allocationContract"
    )
    require_exact_keys(
        allocation,
        (
            "policyID", "sourceFullFrameSampleCount", "sourceTileCount",
            "targetFullFrameSampleCount", "targetTileCount",
            "maximumRetainedTileSampleCount", "maximumOutputTileSampleCount",
            "fullFrameSampleArrayAllocationCap",
        ),
        f"{label}.boundedRoute.allocationContract",
    )
    source_grid = expected_tile_grid(definition["sourceWidth"], definition["sourceHeight"])
    target_grid = expected_tile_grid(definition["targetWidth"], definition["targetHeight"])
    expected_allocation = {
        "policyID": EXPECTED_TILE_POLICY["policyID"],
        "sourceFullFrameSampleCount": source_grid["fullFrameSampleCount"],
        "sourceTileCount": source_grid["tileCount"],
        "targetFullFrameSampleCount": target_grid["fullFrameSampleCount"],
        "targetTileCount": target_grid["tileCount"],
        "maximumRetainedTileSampleCount": (
            (EXPECTED_TILE_POLICY["tileWidth"] + 2 * EXPECTED_TILE_POLICY["searchHalo"])
            * (EXPECTED_TILE_POLICY["tileHeight"] + 2 * EXPECTED_TILE_POLICY["searchHalo"])
        ),
        "maximumOutputTileSampleCount": (
            EXPECTED_TILE_POLICY["tileWidth"] * EXPECTED_TILE_POLICY["tileHeight"]
        ),
        "fullFrameSampleArrayAllocationCap": 0,
    }
    require(allocation == expected_allocation, f"{label} allocation contract differs")
    return document


def validate_run(
    value: Any,
    label: str,
    root: Path,
    sealed: Mapping[str, Path],
    definition: Mapping[str, Any],
    backend: str,
    spatial_schedule: str,
    temporal_schedule: str,
) -> dict[str, Any]:
    run = require_object(value, label)
    require_exact_keys(run, RUN_KEYS, label)
    loaded: dict[str, Any] = {}
    for key in ("visible", "semantics", "checkpoints", "resume", "execution"):
        raw, path, data = validate_descriptor(root, run[key], f"{label}.{key}")
        require(
            raw["path"] in sealed and sealed[raw["path"]].resolve() == path.resolve(),
            f"{label}.{key} is not sealed",
        )
        loaded[key] = {"descriptor": raw, "path": path, "data": data}
    states = validate_checkpoint_set(loaded["checkpoints"]["data"], definition, f"{label}.checkpoints")
    validate_semantics(loaded["semantics"]["data"], definition, states, f"{label}.semantics")
    validate_resume_set(loaded["resume"]["data"], definition, f"{label}.resume")
    validate_execution_evidence(
        loaded["execution"]["data"], definition, states, backend,
        spatial_schedule, temporal_schedule, f"{label}.execution",
    )
    return loaded


def require_distinct_paths(left: Mapping[str, Any], right: Mapping[str, Any], label: str) -> None:
    for key in RUN_KEYS:
        require(left[key]["path"] != right[key]["path"], f"{label} aliases {key}")


def require_run_equal(
    left: Mapping[str, Any], right: Mapping[str, Any], label: str,
    include_execution: bool = False,
) -> None:
    keys = IDENTITY_RUN_KEYS + (("execution",) if include_execution else ())
    for key in keys:
        require(left[key]["data"] == right[key]["data"], f"{label} differs: {key}")


def validate_backend_run_set(
    value: Any,
    label: str,
    root: Path,
    sealed: Mapping[str, Path],
    definition: Mapping[str, Any],
    backend_name: str,
) -> dict[str, Any]:
    backend = require_object(value, label)
    require_exact_keys(backend, ("canonical", "repeat", "schedules"), label)
    canonical = validate_run(
        backend["canonical"], f"{label}.canonical", root, sealed, definition,
        backend_name, "production_full_frame", "raster",
    )
    repeat = validate_run(
        backend["repeat"], f"{label}.repeat", root, sealed, definition,
        backend_name, "production_full_frame", "raster",
    )
    require_distinct_paths(canonical, repeat, f"{label} repeat")
    require_run_equal(canonical, repeat, f"{label} repeat", include_execution=True)
    schedules: dict[str, dict[str, Any]] = {}
    raw_schedules = require_array(backend["schedules"], f"{label}.schedules")
    require(
        len(raw_schedules) == len(EXPECTED_SCHEDULE_PAIRS),
        f"{label} schedule set/order differs",
    )
    for index, (raw, expected_pair) in enumerate(zip(
        raw_schedules,
        EXPECTED_SCHEDULE_PAIRS,
    )):
        item = require_object(raw, f"{label}.schedules[{index}]")
        require_exact_keys(
            item, ("spatialSchedule", "temporalSchedule", "run"),
            f"{label}.schedules[{index}]",
        )
        name = require_text(
            item["spatialSchedule"], f"{label}.schedules[{index}].spatialSchedule"
        )
        temporal_name = require_text(
            item["temporalSchedule"], f"{label}.schedules[{index}].temporalSchedule"
        )
        require(
            (name, temporal_name) == expected_pair,
            f"{label} schedule set/order differs",
        )
        require(name not in schedules, f"{label} repeats schedule {name}")
        run = validate_run(
            item["run"], f"{label}.schedules[{index}].run", root, sealed,
            definition, backend_name, name, temporal_name,
        )
        require_distinct_paths(canonical, run, f"{label} schedule {name}")
        require_run_equal(canonical, run, f"{label} schedule {name}")
        schedules[name] = run
    require(tuple(schedules) == EXPECTED_SCHEDULES, f"{label} schedule set/order differs")
    return {"canonical": canonical, "repeat": repeat, "schedules": schedules}


METADATA_KEYS = {
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


def validate_metadata(value: Any, definition: Mapping[str, Any], label: str) -> dict[str, Any]:
    metadata = require_object(value, label)
    require_exact_keys(metadata, METADATA_KEYS, label)
    require(metadata["id"] == definition["id"], f"{label} ID differs")
    for key in ("sourceWidth", "sourceHeight", "targetWidth", "targetHeight"):
        require(metadata[key] == definition[key], f"{label} geometry differs: {key}")
    require_sha256(metadata["spatialPlanSHA256"], f"{label}.spatialPlanSHA256")
    require_sha256(metadata["kernelIRSHA256"], f"{label}.kernelIRSHA256")
    horizontal = require_integer(metadata["horizontalUniquePhaseCount"], f"{label}.horizontalUniquePhaseCount", 1)
    vertical = require_integer(metadata["verticalUniquePhaseCount"], f"{label}.verticalUniquePhaseCount", 1)
    if "arbitrary_rational_phase" in definition["coverage"]:
        require(horizontal > 1 and vertical > 1, f"{label} did not exercise rational phases")
    for key in (
        "cpuSourcePaddingByteCount",
        "cpuDestinationPaddingByteCount",
        "metalSourcePaddingByteCount",
        "metalDestinationPaddingByteCount",
    ):
        count = require_integer(metadata[key], f"{label}.{key}", 0)
        if "stride_padding_adversary" in definition["coverage"]:
            require(count > 0, f"{label} did not exercise padded stride: {key}")
    require_bool(metadata["cpuPaddingSentinelPreserved"], f"{label}.cpuPaddingSentinelPreserved", True)
    require_bool(metadata["metalPaddingSentinelPreserved"], f"{label}.metalPaddingSentinelPreserved", True)
    return metadata


def validate_captured_case(
    value: Any,
    label: str,
    root: Path,
    sealed: Mapping[str, Path],
    contract_by_id: Mapping[str, dict[str, Any]],
) -> dict[str, Any]:
    case = require_object(value, label)
    require_exact_keys(case, ("id", "definition", "cpu", "metal", "metadata"), label)
    identifier = require_text(case["id"], f"{label}.id")
    require(identifier in contract_by_id, f"unexpected captured case {identifier}")
    definition = contract_by_id[identifier]
    require(case["definition"] == definition, f"captured definition differs: {identifier}")
    cpu = validate_backend_run_set(
        case["cpu"], f"{label}.cpu", root, sealed, definition, "cpu"
    )
    metal = validate_backend_run_set(
        case["metal"], f"{label}.metal", root, sealed, definition, "metal"
    )
    require_distinct_paths(cpu["canonical"], metal["canonical"], f"{label} CPU/Metal")
    require_run_equal(cpu["canonical"], metal["canonical"], f"{label} CPU/Metal")
    metadata_descriptor, metadata_path, metadata_data = validate_descriptor(
        root, case["metadata"], f"{label}.metadata"
    )
    require(
        metadata_descriptor["path"] in sealed
        and sealed[metadata_descriptor["path"]].resolve() == metadata_path.resolve(),
        f"{label} metadata is not sealed",
    )
    metadata = validate_metadata(parse_json_bytes(metadata_data, f"{label}.metadata"), definition, f"{label}.metadata")
    require(canonical_json(metadata) == metadata_data, f"{label} metadata is not canonical")
    return {
        "id": identifier,
        "definition": definition,
        "cpu": cpu,
        "metal": metal,
        "metadata": metadata,
        "metadataDescriptor": metadata_descriptor,
    }


def validate_capture(
    directory: Path,
    contract: dict[str, Any],
    contract_sha: str,
    allow_unbound_fixture: bool = False,
) -> dict[str, Any]:
    require(directory.is_dir() and not directory.is_symlink(), "capture directory missing/symbolic")
    sealed, manifest_sha = validate_capture_manifest(directory)
    capture_path = directory / "capture.json"
    require(
        capture_path.resolve() in {path.resolve() for path in sealed.values()},
        "capture.json is not sealed",
    )
    capture = require_object(load_json(capture_path), "capture")
    base_fields = {
        "schemaVersion",
        "contractSHA256",
        "captureSourceSHA256",
        "sourceRevision",
        "buildConfiguration",
        "processRunID",
        "runtime",
        "cases",
    }
    observed_fields = set(capture)
    packaged_fields = set(PACKAGED_CAPTURE_FIELDS)
    require(
        observed_fields in (base_fields, base_fields | packaged_fields),
        "capture field set differs",
    )
    require(capture["schemaVersion"] == CAPTURE_SCHEMA, "capture schema mismatch")
    require(capture["contractSHA256"] == contract_sha, "capture contract identity mismatch")
    require(capture["captureSourceSHA256"] == contract["tools"]["captureSourceSHA256"], "capture source identity mismatch")
    require_revision(capture["sourceRevision"], "capture.sourceRevision")
    require(capture["buildConfiguration"] == "Release", "capture is not Release")
    require_text(capture["processRunID"], "capture.processRunID")
    runtime = validate_runtime(capture["runtime"])
    if observed_fields == base_fields | packaged_fields:
        require_sha256(
            capture["evidenceRequestSHA256"], "capture.evidenceRequestSHA256"
        )
        require_object(
            capture["packagedCandidateIdentity"],
            "capture.packagedCandidateIdentity",
        )
    else:
        require(
            runtime["mode"] == "fixture" or allow_unbound_fixture,
            "production capture omits exact packaged-candidate identities",
        )
        capture["evidenceRequestSHA256"] = None
        capture["packagedCandidateIdentity"] = None
    contract_by_id = {case["id"]: case for case in contract["cases"]}
    cases: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(require_array(capture["cases"], "capture.cases")):
        observed = validate_captured_case(
            raw, f"capture.cases[{index}]", directory, sealed, contract_by_id
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
        "candidate runtime source revision is invalid",
    )
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_text(candidate[key], f"candidate.{key}")
    return candidate


def cross_process_compare(first: dict[str, Any], second: dict[str, Any]) -> None:
    left_capture = first["capture"]
    right_capture = second["capture"]
    require(left_capture["processRunID"] != right_capture["processRunID"], "cross-process run IDs not distinct")
    left_request = left_capture["evidenceRequestSHA256"]
    right_request = right_capture["evidenceRequestSHA256"]
    require(
        (left_request is None and right_request is None)
        or (
            isinstance(left_request, str)
            and isinstance(right_request, str)
            and left_request != right_request
        ),
        "cross-process packaged evidence request IDs are not distinct",
    )
    for key in (
        "schemaVersion",
        "contractSHA256",
        "captureSourceSHA256",
        "sourceRevision",
        "buildConfiguration",
        "runtime",
        "packagedCandidateIdentity",
    ):
        require(left_capture[key] == right_capture[key], f"cross-process capture identity differs: {key}")
    require(set(first["cases"]) == set(second["cases"]), "cross-process case set differs")
    for identifier in first["cases"]:
        left = first["cases"][identifier]
        right = second["cases"][identifier]
        for backend in ("cpu", "metal"):
            for run_name in ("canonical", "repeat"):
                require_run_equal(
                    left[backend][run_name], right[backend][run_name],
                    f"cross-process {identifier}/{backend}/{run_name}",
                    include_execution=True,
                )
            for schedule in EXPECTED_SCHEDULES:
                require_run_equal(
                    left[backend]["schedules"][schedule],
                    right[backend]["schedules"][schedule],
                    f"cross-process {identifier}/{backend}/{schedule}",
                    include_execution=True,
                )
        require(left["metadata"] == right["metadata"], f"cross-process metadata differs: {identifier}")


def validate_packaged_parity_captures(
    packaged_evidence_a: Path | None,
    packaged_evidence_b: Path | None,
    repository: Path | None,
    runtime_path: Path | None,
    first: Mapping[str, Any],
    second: Mapping[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]] | None:
    supplied = (
        packaged_evidence_a is not None,
        packaged_evidence_b is not None,
        repository is not None,
        runtime_path is not None,
    )
    require(
        not any(supplied) or all(supplied),
        "packaged parity evidence requires both captures, repository, and runtime",
    )
    if not all(supplied):
        return None
    assert packaged_evidence_a is not None
    assert packaged_evidence_b is not None
    assert repository is not None
    assert runtime_path is not None
    verifier = packaged_evidence_module()
    try:
        first_binding = verifier.validate_capture_binding(
            packaged_evidence_a, repository, runtime_path
        )
        second_binding = verifier.validate_capture_binding(
            packaged_evidence_b, repository, runtime_path
        )
    except (ValueError, OSError) as error:
        raise ParityEvidenceError(
            f"packaged parity evidence failed: {error}"
        ) from error
    require(
        first_binding.get("lane") == second_binding.get("lane") == "parity",
        "packaged evidence is not parity evidence",
    )
    require(
        first_binding["packageIdentity"] == second_binding["packageIdentity"],
        "packaged parity application identities differ",
    )
    require(
        first_binding["requestSHA256"] != second_binding["requestSHA256"],
        "packaged parity requests are not independently fresh",
    )
    require(
        first_binding["captureManifest"] == first["capture"]
        and second_binding["captureManifest"] == second["capture"],
        "evaluated parity capture differs from exact packaged observer output",
    )
    return first_binding, second_binding


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
    packaged_evidence_a: Path | None = None,
    packaged_evidence_b: Path | None = None,
    repository: Path | None = None,
    packaged_runtime: Path | None = None,
) -> dict[str, Any]:
    contract, contract_sha = validate_contract(contract_path, capture_source, evaluator, runner)
    first = validate_capture(
        capture_a_path, contract, contract_sha, allow_fixture_runtime
    )
    second = validate_capture(
        capture_b_path, contract, contract_sha, allow_fixture_runtime
    )
    cross_process_compare(first, second)
    packaged_bindings = validate_packaged_parity_captures(
        packaged_evidence_a,
        packaged_evidence_b,
        repository,
        packaged_runtime,
        first,
        second,
    )
    candidate = load_candidate(candidate_path)
    require(first["capture"]["sourceRevision"] == candidate["sourceCommit"], "capture source revision differs from candidate")
    runtime = first["runtime"]
    require(runtime["manifestSHA256"] == candidate["runtimeManifestSHA256"], "capture runtime manifest differs from candidate")
    require(runtime["manifestFileSHA256"] == candidate["runtimeManifestFileSHA256"], "capture raw runtime manifest differs")
    require(runtime["sourceRevision"] == candidate["runtimeSourceRevision"], "capture runtime source revision differs")
    production = runtime["mode"] == "production"
    if not allow_fixture_runtime:
        require(production, "final parity qualification requires the production runtime")
        require_bool(runtime["trustRootConfigured"], "runtime.trustRootConfigured", True)
        require(
            packaged_bindings is not None,
            "final parity qualification requires exact packaged-candidate evidence",
        )
    cases: list[dict[str, Any]] = []
    covered: set[str] = set()
    for definition in sorted(contract["cases"], key=lambda item: item["id"]):
        observed = first["cases"][definition["id"]]
        covered.update(definition["coverage"])
        cpu = observed["cpu"]["canonical"]
        metal = observed["metal"]["canonical"]
        cases.append(
            {
                "id": definition["id"],
                "coverage": definition["coverage"],
                "cpuVisibleArtifact": descriptor(cpu["visible"]["path"], evidence_root),
                "metalVisibleArtifact": descriptor(metal["visible"]["path"], evidence_root),
                "cpuSemanticsArtifact": descriptor(cpu["semantics"]["path"], evidence_root),
                "metalSemanticsArtifact": descriptor(metal["semantics"]["path"], evidence_root),
                "cpuCheckpointSetArtifact": descriptor(cpu["checkpoints"]["path"], evidence_root),
                "metalCheckpointSetArtifact": descriptor(metal["checkpoints"]["path"], evidence_root),
                "cpuResumeSetArtifact": descriptor(cpu["resume"]["path"], evidence_root),
                "metalResumeSetArtifact": descriptor(metal["resume"]["path"], evidence_root),
                "cpuExecutionArtifact": descriptor(cpu["execution"]["path"], evidence_root),
                "metalExecutionArtifact": descriptor(metal["execution"]["path"], evidence_root),
                "repeatRunIdentityPass": True,
                "crossProcessIdentityPass": True,
                "tileScheduleIdentityPass": True,
                "boundedTiledTemporalPathPass": True,
                "checkpointResumeIdentityPass": True,
                "timingAndAttachmentSemanticsPass": True,
            }
        )
    require(covered == set(REQUIRED_PARITY_COVERAGE), "evaluated coverage is not exact")
    exact_packaged = packaged_bindings is not None
    packaged_identity = (
        packaged_bindings[0]["packageIdentity"] if packaged_bindings else None
    )
    if exact_packaged:
        require(
            packaged_identity == first["capture"]["packagedCandidateIdentity"],
            "capture packaged identity differs from verified archive",
        )
        require(
            packaged_identity["applicationArchiveSHA256"]
            == candidate["appBundleSHA256"],
            "packaged parity archive differs from candidate",
        )
    return {
        "schemaVersion": contract["reportSchemaVersion"],
        "contractSHA256": contract_sha,
        "candidate": candidate,
        "releaseEligible": production and exact_packaged,
        "identities": {
            "captureSourceSHA256": contract["tools"]["captureSourceSHA256"],
            "evaluatorSHA256": contract["tools"]["evaluatorSHA256"],
            "runnerSHA256": contract["tools"]["runnerSHA256"],
            "packagedCandidateIdentity": packaged_identity,
            "evidenceRequestSHA256": [
                packaged_bindings[0]["requestSHA256"],
                packaged_bindings[1]["requestSHA256"],
            ] if packaged_bindings else None,
            "packagedCaptureTreeSHA256": [
                packaged_bindings[0]["captureTree"]["sha256"],
                packaged_bindings[1]["captureTree"]["sha256"],
            ] if packaged_bindings else None,
        },
        "comparison": contract["comparison"],
        "coverage": list(REQUIRED_PARITY_COVERAGE),
        "cases": cases,
        "exactPackagedCandidatePass": exact_packaged,
        "byteParityGatePass": production and exact_packaged,
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
        False,
        getattr(arguments, "packaged_evidence_a", None).resolve()
        if getattr(arguments, "packaged_evidence_a", None) is not None
        else None,
        getattr(arguments, "packaged_evidence_b", None).resolve()
        if getattr(arguments, "packaged_evidence_b", None) is not None
        else None,
        getattr(arguments, "repository", None).resolve()
        if getattr(arguments, "repository", None) is not None
        else None,
        getattr(arguments, "runtime", None).resolve()
        if getattr(arguments, "runtime", None) is not None
        else None,
    )
    write_json(output, report)
    write_json(manifest, make_root_manifest(root, manifest))


def command_verify(arguments: argparse.Namespace) -> None:
    root = arguments.evidence_root.resolve()
    expected = evaluate(
        arguments.contract.resolve(),
        arguments.capture_a.resolve(),
        arguments.capture_b.resolve(),
        arguments.candidate.resolve(),
        arguments.capture_source.resolve(),
        arguments.evaluator.resolve(),
        arguments.runner.resolve(),
        root,
        False,
        getattr(arguments, "packaged_evidence_a", None).resolve()
        if getattr(arguments, "packaged_evidence_a", None) is not None
        else None,
        getattr(arguments, "packaged_evidence_b", None).resolve()
        if getattr(arguments, "packaged_evidence_b", None) is not None
        else None,
        getattr(arguments, "repository", None).resolve()
        if getattr(arguments, "repository", None) is not None
        else None,
        getattr(arguments, "runtime", None).resolve()
        if getattr(arguments, "runtime", None) is not None
        else None,
    )
    observed = load_json(arguments.report.resolve())
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
        subparser.add_argument("--packaged-evidence-a", type=Path)
        subparser.add_argument("--packaged-evidence-b", type=Path)
        subparser.add_argument("--repository", type=Path)
        subparser.add_argument("--runtime", type=Path)
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
