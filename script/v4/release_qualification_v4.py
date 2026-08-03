#!/usr/bin/env python3
"""Fail-closed M7 release qualification for the deterministic ASH v4 engine.

This tool intentionally consumes evidence; it does not manufacture it.  A
report can fail a gate, while malformed, stale, incomplete, or tampered inputs
are rejected before a release decision is produced.
"""

from __future__ import annotations

import argparse
from datetime import datetime
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path, PurePosixPath
import random
import statistics
import sys
from typing import Any, Callable, Iterable, Mapping, Sequence


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIRECTORY / "release-qualification-contract-v1.json"
SCHEMA_CONTRACT = "mirmir-ash-v4-release-qualification-contract-v1"
SCHEMA_CANDIDATE = "mirmir-ash-v4-release-candidate-evidence-v1"
SCHEMA_REPORT = "mirmir-ash-v4-release-qualification-report-v1"
HEX = frozenset("0123456789abcdef")
QUALITY_VARIANTS = (
    "baseline_p05",
    "candidate_v4",
    "uniform_priors",
    "randomized_state_message",
    "temporal_hysteresis_off",
    "motion_history_off",
)
MEDIA_LANE_CONTRACT_SCHEMA = "mirmir-ash-v4-media-preservation-contract-v1"
MEDIA_SIDE_MANIFEST_SCHEMA = "mirmir-ash-v4-media-side-manifest-v1"
MEDIA_SEMANTIC_VERIFIER_SCHEMA = "mirmir-ash-v4-media-semantic-verifier-v1"
MEDIA_TRACK_SCHEMA = "mirmir-ash-v4-track-observation-v1"
MEDIA_TIMING_SCHEMA = "mirmir-ash-v4-timing-observation-v1"
MEDIA_PIXEL_SCHEMA = "mirmir-ash-v4-pixel-observation-v1"
MEDIA_ATTACHMENT_SCHEMA = "mirmir-ash-v4-attachment-observation-v1"
RECOVERY_LANE_CONTRACT_SCHEMA = "mirmir-v4-recovery-qualification-contract-v1"
RECOVERY_CAPTURE_SCHEMA = "mirmir-v4-recovery-capture-v1"
RECOVERY_CAPTURE_MANIFEST_SCHEMA = "mirmir-v4-recovery-capture-artifacts-v1"
RECOVERY_SCENARIO_SCHEMA = "mirmir-v4-recovery-scenario-evidence-v1"
RECOVERY_SEMANTIC_SCHEMA = "mirmir-v4-recovery-semantic-output-v1"
RECOVERY_SUITE_MANIFEST_SCHEMA = "mirmir-v4-recovery-evidence-manifest-v1"
RECOVERY_TRANSCRIPT_SCHEMA = "mirmir-v4-recovery-fault-transcript-v1"

SUPPORT_REPLAY_SPEC = importlib.util.spec_from_file_location(
    "support_matrix_v4_for_release_qualification",
    SCRIPT_DIRECTORY / "support_matrix_v4.py",
)
if SUPPORT_REPLAY_SPEC is None or SUPPORT_REPLAY_SPEC.loader is None:
    raise RuntimeError("support-matrix replay evaluator cannot be loaded")
support_replay = importlib.util.module_from_spec(SUPPORT_REPLAY_SPEC)
SUPPORT_REPLAY_SPEC.loader.exec_module(support_replay)


class QualificationError(ValueError):
    """An input cannot be admitted as release evidence."""


def reject_constant(value: str) -> None:
    raise QualificationError(f"non-finite JSON number is forbidden: {value}")


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise QualificationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=reject_constant,
            object_pairs_hook=reject_duplicate_pairs,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise QualificationError(f"cannot read canonical JSON {path}: {error}") from error


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_set_sha(entries: Iterable[tuple[str, str]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"mirmir-artifact-set-v1\0")
    for path, identity in sorted(entries):
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(identity.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def recovery_artifact_set_sha(artifacts: Iterable[Mapping[str, Any]]) -> str:
    """Recompute the recovery lane's canonical descriptor-set identity."""
    normalized = [
        {
            "path": item["path"],
            "byteCount": item["byteCount"],
            "sha256": item["sha256"],
        }
        for item in artifacts
    ]
    normalized.sort(key=lambda item: item["path"])
    return sha256_bytes(canonical_bytes(normalized) + b"\n")


def ash_canonical_identity(domain: str, value: Any) -> str:
    return sha256_bytes(domain.encode("ascii") + b"\0" + canonical_bytes(value))


def require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise QualificationError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise QualificationError(f"{label} must be an array")
    return value


def require_exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise QualificationError(
            f"{label} key set mismatch; missing={missing}, unexpected={unexpected}"
        )


def require_bool(value: Any, label: str, expected: bool | None = None) -> bool:
    if not isinstance(value, bool):
        raise QualificationError(f"{label} must be Boolean")
    if expected is not None and value is not expected:
        raise QualificationError(f"{label} must be {str(expected).lower()}")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise QualificationError(f"{label} must be a nonempty string")
    return value


def require_hex(value: Any, length: int | tuple[int, ...], label: str) -> str:
    text = require_string(value, label)
    lengths = (length,) if isinstance(length, int) else length
    if len(text) not in lengths or any(character not in HEX for character in text):
        raise QualificationError(f"{label} is not a lowercase hexadecimal identity")
    return text


def require_number(
    value: Any,
    label: str,
    *,
    minimum: float | None = None,
    positive: bool = False,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QualificationError(f"{label} must be numeric")
    number = float(value)
    if not math.isfinite(number):
        raise QualificationError(f"{label} must be finite")
    if positive and number <= 0:
        raise QualificationError(f"{label} must be positive")
    if minimum is not None and number < minimum:
        raise QualificationError(f"{label} must be at least {minimum}")
    return number


def require_integer(value: Any, label: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise QualificationError(f"{label} must be an integer >= {minimum}")
    return value


def require_close(actual: Any, expected: float, label: str) -> None:
    number = require_number(actual, label)
    if not math.isclose(number, expected, rel_tol=1e-12, abs_tol=1e-12):
        raise QualificationError(f"{label} does not match recomputed value")


def checked_path(root: Path, relative: Any, label: str) -> Path:
    text = require_string(relative, label)
    if "\\" in text:
        raise QualificationError(f"{label} uses a non-canonical path separator")
    pure = PurePosixPath(text)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise QualificationError(f"{label} escapes or is not canonical: {text}")
    candidate = root.joinpath(*pure.parts)
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise QualificationError(f"{label} is missing: {text}") from error
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise QualificationError(f"{label} escapes evidence root: {text}") from error
    current = candidate
    while current != root:
        if current.is_symlink():
            raise QualificationError(f"{label} contains a symlink: {text}")
        current = current.parent
    if not resolved.is_file():
        raise QualificationError(f"{label} is not a regular file: {text}")
    return resolved


def validate_artifact(
    root: Path,
    value: Any,
    label: str,
    *,
    allowed_extra_keys: set[str] | None = None,
) -> tuple[Path, str]:
    artifact = require_mapping(value, label)
    expected = {"path", "byteCount", "sha256"} | (allowed_extra_keys or set())
    require_exact_keys(artifact, expected, label)
    path = checked_path(root, artifact["path"], f"{label}.path")
    byte_count = require_integer(artifact["byteCount"], f"{label}.byteCount")
    identity = require_hex(artifact["sha256"], 64, f"{label}.sha256")
    if path.stat().st_size != byte_count:
        raise QualificationError(f"{label} byte count mismatch")
    if sha256(path) != identity:
        raise QualificationError(f"{label} SHA-256 mismatch")
    return path, identity


def json_pointer(document: Any, pointer: Any, label: str) -> Any:
    text = require_string(pointer, label)
    if not text.startswith("/"):
        raise QualificationError(f"{label} must be an absolute JSON pointer")
    current = document
    for raw in text[1:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and token in current:
            current = current[token]
        elif isinstance(current, list) and token.isdigit() and int(token) < len(current):
            current = current[int(token)]
        else:
            raise QualificationError(f"{label} does not resolve: {text}")
    return current


class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & 0xFFFFFFFFFFFFFFFF

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return value ^ (value >> 31)

    def index(self, count: int) -> int:
        if count <= 0:
            raise QualificationError("cannot sample an empty population")
        limit = (1 << 64) - ((1 << 64) % count)
        while True:
            value = self.next()
            if value < limit:
                return value % count


def percentile95(values: Sequence[float]) -> float:
    if not values:
        raise QualificationError("cannot calculate p95 of an empty sample")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = 0.95 * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def sample_values(value: Any, label: str, minimum_count: int) -> list[float]:
    items = require_list(value, label)
    if len(items) < minimum_count:
        raise QualificationError(f"{label} has fewer than {minimum_count} samples")
    return [require_number(item, f"{label}[{index}]", positive=True) for index, item in enumerate(items)]


def paired_ratio_interval(
    baseline: Sequence[float],
    candidate: Sequence[float],
    statistic: Callable[[Sequence[float]], float],
    seed: int,
    replicate_count: int,
) -> tuple[float, float, float]:
    if len(baseline) != len(candidate):
        raise QualificationError("paired performance sample counts differ")
    point = statistic(candidate) / statistic(baseline)
    if len(set(baseline)) == 1 and len(set(candidate)) == 1:
        return point, point, point
    generator = SplitMix64(seed)
    ratios: list[float] = []
    for _ in range(replicate_count):
        indices = [generator.index(len(baseline)) for _ in baseline]
        selected_baseline = [baseline[index] for index in indices]
        selected_candidate = [candidate[index] for index in indices]
        ratios.append(statistic(selected_candidate) / statistic(selected_baseline))
    ratios.sort()
    lower_index = math.floor(0.025 * len(ratios))
    return point, ratios[lower_index], ratios[len(ratios) - 1 - lower_index]


def validate_candidate(value: Any, contract: Mapping[str, Any]) -> dict[str, Any]:
    candidate = require_mapping(value, "candidate")
    expected = set(require_list(contract["candidateIdentityFields"], "candidateIdentityFields"))
    require_exact_keys(candidate, expected, "candidate")
    require_hex(candidate["sourceCommit"], 40, "candidate.sourceCommit")
    require_hex(candidate["sourceTreeIdentitySHA256"], 64, "candidate.sourceTreeIdentitySHA256")
    require_hex(candidate["runtimeManifestSHA256"], 64, "candidate.runtimeManifestSHA256")
    require_hex(
        candidate["runtimeManifestFileSHA256"],
        64,
        "candidate.runtimeManifestFileSHA256",
    )
    require_hex(candidate["runtimeArtifactSetSHA256"], 64, "candidate.runtimeArtifactSetSHA256")
    require_hex(candidate["runtimeSourceRevision"], (40, 64), "candidate.runtimeSourceRevision")
    require_hex(candidate["releaseConfigurationSHA256"], 64, "candidate.releaseConfigurationSHA256")
    require_hex(candidate["appBundleSHA256"], 64, "candidate.appBundleSHA256")
    for key in ("bundleIdentifier", "productVersion", "productBuild"):
        require_string(candidate[key], f"candidate.{key}")
    return candidate


def validate_sealed_manifest(
    evidence_root: Path,
    descriptor: Any,
    report_path: Path,
    label: str,
) -> tuple[list[dict[str, Any]], set[Path]]:
    manifest_path, _ = validate_artifact(evidence_root, descriptor, label)
    manifest = require_mapping(load_json(manifest_path), f"{label}.document")
    require_string(manifest.get("schemaVersion"), f"{label}.schemaVersion")
    artifacts = require_list(manifest.get("artifacts"), f"{label}.artifacts")
    if not artifacts:
        raise QualificationError(f"{label} is empty")
    base = manifest_path.parent.resolve()
    seen: set[str] = set()
    resolved: set[Path] = set()
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(artifacts):
        artifact = require_mapping(item, f"{label}.artifacts[{index}]")
        require_exact_keys(artifact, {"path", "byteCount", "sha256"}, f"{label}.artifacts[{index}]")
        relative = require_string(artifact["path"], f"{label}.artifacts[{index}].path")
        if relative in seen:
            raise QualificationError(f"{label} repeats artifact path: {relative}")
        seen.add(relative)
        path, identity = validate_artifact(base, artifact, f"{label}.artifacts[{index}]")
        resolved.add(path)
        normalized.append(
            {"path": relative, "byteCount": path.stat().st_size, "sha256": identity}
        )
    if report_path not in resolved:
        raise QualificationError(f"{label} does not seal its evidence report")
    actual_files = {
        path.resolve()
        for path in manifest_path.parent.rglob("*")
        if path.is_file() and path.resolve() != manifest_path
    }
    if actual_files != resolved:
        missing = sorted(path.as_posix() for path in resolved - actual_files)
        unsealed = sorted(path.as_posix() for path in actual_files - resolved)
        raise QualificationError(
            f"{label} sealed file set mismatch; missing={missing}, unsealed={unsealed}"
        )
    return normalized, resolved


def validate_bindings(
    evidence_root: Path,
    report: Mapping[str, Any],
    entry: Mapping[str, Any],
    required_pointers: set[str],
    label: str,
) -> list[dict[str, Any]]:
    bindings = require_list(entry["identityBindings"], f"{label}.identityBindings")
    pointers: set[str] = set()
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(bindings):
        binding = require_mapping(item, f"{label}.identityBindings[{index}]")
        require_exact_keys(
            binding,
            {"jsonPointer", "path", "byteCount", "sha256"},
            f"{label}.identityBindings[{index}]",
        )
        pointer = require_string(binding["jsonPointer"], f"{label}.identityBindings[{index}].jsonPointer")
        if pointer in pointers:
            raise QualificationError(f"{label} repeats identity binding: {pointer}")
        pointers.add(pointer)
        path, identity = validate_artifact(
            evidence_root,
            binding,
            f"{label}.identityBindings[{index}]",
            allowed_extra_keys={"jsonPointer"},
        )
        report_identity = json_pointer(report, pointer, f"{label}.identityBindings[{index}].jsonPointer")
        if report_identity != identity:
            raise QualificationError(f"{label} binding does not match report at {pointer}")
        normalized.append(
            {
                "jsonPointer": pointer,
                "path": path.relative_to(evidence_root).as_posix(),
                "byteCount": path.stat().st_size,
                "sha256": identity,
            }
        )
    if pointers != required_pointers:
        raise QualificationError(
            f"{label} identity binding set mismatch; missing={sorted(required_pointers-pointers)}, "
            f"unexpected={sorted(pointers-required_pointers)}"
        )
    return sorted(normalized, key=lambda item: item["jsonPointer"])


def validate_sealed_artifact(
    evidence_root: Path,
    value: Any,
    sealed_paths: set[Path],
    label: str,
) -> tuple[Path, str]:
    path, artifact_identity = validate_artifact(evidence_root, value, label)
    if path not in sealed_paths:
        raise QualificationError(f"{label} is outside the sealed evidence suite")
    return path, artifact_identity


def validate_common_report(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    schema: str,
    contract_sha: str,
    label: str,
) -> None:
    if report.get("schemaVersion") != schema:
        raise QualificationError(f"{label} has unsupported schema")
    if report.get("contractSHA256") != contract_sha:
        raise QualificationError(f"{label} contract identity mismatch")
    if report.get("candidate") != candidate:
        raise QualificationError(f"{label} is stale or belongs to another candidate")
    require_bool(report.get("releaseEligible"), f"{label}.releaseEligible", True)


def mean(values: Sequence[float]) -> float:
    if not values:
        raise QualificationError("cannot average an empty sequence")
    return math.fsum(values) / len(values)


def quality_aggregate(
    metrics: Mapping[str, Mapping[str, Mapping[str, float]]],
    clips_by_cohort: Mapping[str, list[str]],
    variant: str,
    weights: Mapping[str, float],
) -> tuple[dict[str, float], dict[str, dict[str, float]], float, float]:
    by_cohort: dict[str, dict[str, float]] = {}
    for cohort, clip_ids in clips_by_cohort.items():
        values: dict[str, float] = {}
        for component in weights:
            baseline = mean([float(metrics[clip]["baseline_p05"][component]) for clip in clip_ids])
            observed = mean([float(metrics[clip][variant][component]) for clip in clip_ids])
            if baseline <= 0:
                raise QualificationError(f"quality baseline normalizer is not positive: {cohort}/{component}")
            values[component] = observed / baseline
        by_cohort[cohort] = values
    aggregate = {
        component: mean([by_cohort[cohort][component] for cohort in sorted(by_cohort)])
        for component in weights
    }
    error = math.fsum(aggregate[component] * weight for component, weight in weights.items())
    return aggregate, by_cohort, error, 100.0 * (2.0 - error)


def validate_quality(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "quality"
    schema = require_mapping(contract["evidenceSchemas"], "evidenceSchemas")[label]
    if report.get("schemaVersion") != schema:
        raise QualificationError("quality has unsupported schema")
    identities = require_mapping(report.get("identities"), "quality.identities")
    expected_identity_keys = {
        "contractSHA256",
        "metricToolSHA256",
        "captureTestSourceSHA256",
        "corpusManifestSHA256",
        "corpusArtifactSetSHA256",
        "runtimeManifestSHA256",
        "runtimeSourceRevision",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "cropRuleSHA256",
        "metricModelSHA256",
        "outputSetSHA256",
    }
    require_exact_keys(identities, expected_identity_keys, "quality.identities")
    for key in expected_identity_keys - {"runtimeSourceRevision", "sourceCommit", "outputSetSHA256"}:
        require_hex(identities[key], 64, f"quality.identities.{key}")
    require_hex(
        identities["runtimeSourceRevision"],
        (40, 64),
        "quality.identities.runtimeSourceRevision",
    )
    require_hex(identities["sourceCommit"], 40, "quality.identities.sourceCommit")
    output_identities = require_mapping(identities["outputSetSHA256"], "quality output identities")
    if set(output_identities) != set(QUALITY_VARIANTS):
        raise QualificationError("quality output-set identity variants mismatch")
    for variant, value in output_identities.items():
        require_hex(value, 64, f"quality output identity {variant}")
    if identities.get("sourceCommit") != candidate["sourceCommit"]:
        raise QualificationError("quality source commit is stale")
    if identities.get("sourceTreeIdentitySHA256") != candidate["sourceTreeIdentitySHA256"]:
        raise QualificationError("quality source tree is stale")
    if identities.get("runtimeManifestSHA256") != candidate["runtimeManifestSHA256"]:
        raise QualificationError("quality runtime manifest is stale")
    if identities.get("runtimeSourceRevision") != candidate["runtimeSourceRevision"]:
        raise QualificationError("quality runtime source revision is stale")
    if identities.get("contractSHA256") != entry["contractSHA256"]:
        raise QualificationError("quality contract identity mismatch")
    runtime = require_mapping(report.get("runtime"), "quality.runtime")
    settings = require_mapping(contract["quality"], "quality contract")
    if runtime.get("candidateBackendID") != settings["requiredBackendID"]:
        raise QualificationError("quality used an undeclared backend")
    if runtime.get("candidateImplementationVersion") != settings["requiredCandidateImplementationVersion"]:
        raise QualificationError("quality candidate implementation identity mismatch")
    require_bool(runtime.get("productionRuntimeLocked"), "quality.runtime.productionRuntimeLocked", True)
    require_bool(runtime.get("fullMirrorIdentityPass"), "quality.runtime.fullMirrorIdentityPass", True)
    corpus = require_mapping(report.get("corpus"), "quality.corpus")
    require_bool(corpus.get("releaseEligible"), "quality.corpus.releaseEligible", True)
    if corpus.get("corpusKind") != "locked_natural":
        raise QualificationError("quality corpus is not locked natural media")
    embedded = require_mapping(report.get("contract"), "quality.contract")
    quality_contract_binding = next(
        item for item in entry["identityBindings"] if item["jsonPointer"] == "/identities/contractSHA256"
    )
    quality_contract_path = checked_path(
        evidence_root, quality_contract_binding["path"], "quality contract binding"
    )
    if embedded != load_json(quality_contract_path):
        raise QualificationError("quality embedded contract differs from its bound contract file")
    components = require_list(embedded.get("components"), "quality.contract.components")
    weights: dict[str, float] = {}
    for index, item in enumerate(components):
        component = require_mapping(item, f"quality.contract.components[{index}]")
        identifier = require_string(component.get("id"), f"quality.contract.components[{index}].id")
        if identifier in weights:
            raise QualificationError(f"quality repeats component: {identifier}")
        weights[identifier] = require_number(component.get("weight"), f"quality weight {identifier}", minimum=0)
    if not math.isclose(math.fsum(weights.values()), 1.0, rel_tol=0, abs_tol=1e-15):
        raise QualificationError("quality component weights do not sum to one")
    expected_crop_identity = sha256_bytes(
        canonical_bytes([{item["id"]: item["crop"]} for item in components])
    )
    if identities["cropRuleSHA256"] != expected_crop_identity:
        raise QualificationError("quality crop-rule identity mismatch")
    metric_tool_binding = next(
        item for item in entry["identityBindings"] if item["jsonPointer"] == "/identities/metricToolSHA256"
    )
    metric_model_identity = sha256_bytes(
        b"mirmir-analytic-quality-model-v1\0"
        + canonical_bytes(components)
        + bytes.fromhex(metric_tool_binding["sha256"])
    )
    if identities["metricModelSHA256"] != metric_model_identity:
        raise QualificationError("quality metric-model identity mismatch")
    constraints = require_mapping(embedded.get("cohortConstraints"), "quality.contract.cohortConstraints")
    cohorts = [require_string(value, "quality cohort") for value in require_list(constraints.get("contentCohorts"), "quality cohorts")]
    per_clip = require_list(report.get("perClip"), "quality.perClip")
    clips_by_cohort = {cohort: [] for cohort in cohorts}
    metrics: dict[str, dict[str, dict[str, float]]] = {}
    minimum_frames = require_integer(constraints.get("minimumFramesPerClip"), "quality minimum frames", 1)
    minimum_clips = require_integer(constraints.get("minimumClipsPerCohort"), "quality minimum clips", 1)
    for index, item in enumerate(per_clip):
        clip = require_mapping(item, f"quality.perClip[{index}]")
        clip_id = require_string(clip.get("clipID"), f"quality.perClip[{index}].clipID")
        cohort = require_string(clip.get("cohort"), f"quality.perClip[{index}].cohort")
        if clip_id in metrics or cohort not in clips_by_cohort:
            raise QualificationError(f"quality duplicate clip or unexpected cohort: {clip_id}")
        if clip.get("pixelFormat") not in {"420v", "420f"}:
            raise QualificationError(f"quality clip is outside common SDR population: {clip_id}")
        require_integer(clip.get("frameCount"), f"quality frame count {clip_id}", minimum_frames)
        values = require_mapping(clip.get("components"), f"quality components {clip_id}")
        if set(values) != set(QUALITY_VARIANTS):
            raise QualificationError(f"quality variant set mismatch: {clip_id}")
        normalized: dict[str, dict[str, float]] = {}
        for variant in QUALITY_VARIANTS:
            variant_values = require_mapping(values[variant], f"quality {clip_id}/{variant}")
            if set(variant_values) != set(weights):
                raise QualificationError(f"quality component set mismatch: {clip_id}/{variant}")
            normalized[variant] = {
                component: require_number(value, f"quality {clip_id}/{variant}/{component}", minimum=0)
                for component, value in variant_values.items()
            }
        metrics[clip_id] = normalized
        clips_by_cohort[cohort].append(clip_id)
    if corpus.get("clipCount") != len(per_clip):
        raise QualificationError("quality clip count mismatch")
    if corpus.get("caseCount") != sum(int(item["frameCount"]) for item in per_clip):
        raise QualificationError("quality case count mismatch")
    for cohort, clips in clips_by_cohort.items():
        if len(clips) < minimum_clips:
            raise QualificationError(f"quality cohort has too few clips: {cohort}")
    if set(corpus.get("cohorts", [])) != set(cohorts):
        raise QualificationError("quality corpus cohort set mismatch")
    quality = require_mapping(report.get("quality"), "quality.quality")
    summaries = require_mapping(quality.get("summaries"), "quality.summaries")
    if set(summaries) != set(QUALITY_VARIANTS):
        raise QualificationError("quality summary variant set mismatch")
    recomputed: dict[str, dict[str, Any]] = {}
    for variant in QUALITY_VARIANTS:
        aggregate, by_cohort, error, index = quality_aggregate(metrics, clips_by_cohort, variant, weights)
        claimed = require_mapping(summaries[variant], f"quality.summaries.{variant}")
        claimed_components = require_mapping(claimed.get("normalizedComponents"), f"quality normalized {variant}")
        if set(claimed_components) != set(aggregate):
            raise QualificationError(f"quality normalized component set mismatch: {variant}")
        for component, value in aggregate.items():
            require_close(claimed_components[component], value, f"quality {variant}/{component}")
        claimed_cohorts = require_mapping(claimed.get("normalizedComponentsByCohort"), f"quality cohorts {variant}")
        if set(claimed_cohorts) != set(by_cohort):
            raise QualificationError(f"quality normalized cohort set mismatch: {variant}")
        for cohort, cohort_values in by_cohort.items():
            actual = require_mapping(claimed_cohorts[cohort], f"quality {variant}/{cohort}")
            if set(actual) != set(cohort_values):
                raise QualificationError(f"quality cohort component mismatch: {variant}/{cohort}")
            for component, value in cohort_values.items():
                require_close(actual[component], value, f"quality {variant}/{cohort}/{component}")
        require_close(claimed.get("weightedError"), error, f"quality {variant}.weightedError")
        require_close(claimed.get("qualityIndex"), index, f"quality {variant}.qualityIndex")
        recomputed[variant] = {"weightedError": error, "qualityIndex": index, "byCohort": by_cohort}
    candidate_summary = require_mapping(summaries["candidate_v4"], "quality candidate summary")
    interval = require_mapping(candidate_summary.get("pairedBootstrap95PercentCI"), "quality confidence interval")
    require_exact_keys(
        interval,
        {"lower", "upper", "replicateCount", "lowerOrderStatisticIndex"},
        "quality confidence interval",
    )
    bootstrap = require_mapping(embedded.get("bootstrap"), "quality.contract.bootstrap")
    replicates = require_integer(
        bootstrap.get("replicateCount"),
        "quality bootstrap replicates",
        settings["minimumBootstrapReplicates"],
    )
    seed = require_integer(bootstrap.get("seedUnsignedDecimal"), "quality bootstrap seed")
    generator = SplitMix64(seed)
    ratios_by_clip: set[tuple[float, ...]] = set()
    shortcut_safe = True
    for clip in metrics:
        ratios: list[float] = []
        for component in weights:
            baseline_value = float(metrics[clip]["baseline_p05"][component])
            if baseline_value <= 0:
                shortcut_safe = False
                break
            ratios.append(float(metrics[clip]["candidate_v4"][component]) / baseline_value)
        if shortcut_safe:
            ratios_by_clip.add(tuple(ratios))
    if shortcut_safe and len(ratios_by_clip) == 1:
        expected_lower = recomputed["candidate_v4"]["qualityIndex"]
        expected_upper = expected_lower
    else:
        bootstrap_values: list[float] = []
        for _ in range(replicates):
            sampled = {
                cohort: [clips[generator.index(len(clips))] for _ in clips]
                for cohort, clips in sorted(clips_by_cohort.items())
            }
            _, _, _, bootstrap_quality = quality_aggregate(
                metrics, sampled, "candidate_v4", weights
            )
            bootstrap_values.append(bootstrap_quality)
        bootstrap_values.sort()
        lower_index = math.floor(0.025 * len(bootstrap_values))
        expected_lower = bootstrap_values[lower_index]
        expected_upper = bootstrap_values[len(bootstrap_values) - 1 - lower_index]
    lower = require_number(interval.get("lower"), "quality confidence lower")
    upper = require_number(interval.get("upper"), "quality confidence upper")
    require_close(lower, expected_lower, "quality confidence lower")
    require_close(upper, expected_upper, "quality confidence upper")
    if interval.get("replicateCount") != replicates:
        raise QualificationError("quality confidence replicate count mismatch")
    if interval.get("lowerOrderStatisticIndex") != math.floor(0.025 * replicates):
        raise QualificationError("quality confidence lower order statistic mismatch")
    point = recomputed["candidate_v4"]["qualityIndex"]
    if not lower <= point <= upper:
        raise QualificationError("quality confidence interval excludes its point estimate")
    minimum_quality = float(settings["minimumQualityIndex"])
    if point < minimum_quality or lower < minimum_quality:
        raise QualificationError("quality improvement gate did not pass")
    required_ablations = set(settings["requiredAblations"])
    if not required_ablations.issubset(summaries):
        raise QualificationError("quality report omits required ablations")
    luma_id = "luma_multiscale_structural_error"
    temporal_id = "motion_compensated_temporal_flicker_error"
    luma_limit = require_number(constraints.get("lumaStructuralMaximumCandidateToBaselineRatio"), "quality luma limit")
    temporal_limit = require_number(constraints.get("temporalStructuralMaximumCandidateToBaselineRatio"), "quality temporal limit")
    by_cohort = recomputed["candidate_v4"]["byCohort"]
    if any(by_cohort[cohort][luma_id] > luma_limit for cohort in cohorts):
        raise QualificationError("quality luma cohort non-regression gate failed")
    temporal_cohorts = require_list(constraints.get("temporalNonRegressionCohorts"), "quality temporal cohorts")
    if any(by_cohort[cohort][temporal_id] > temporal_limit for cohort in temporal_cohorts):
        raise QualificationError("quality temporal cohort non-regression gate failed")
    gates = require_mapping(quality.get("gates"), "quality.gates")
    required_gates = {
        "identityPass",
        "naturalCorpusEligibilityPass",
        "productionRuntimeLockPass",
        "requiredAblationsPresentPass",
        "qualityPointEstimatePass",
        "qualityLowerConfidenceBoundPass",
        "allCohortLumaNonRegressionPass",
        "temporalCohortNonRegressionPass",
        "candidateBackendIdentityPass",
        "fullMirrorIdentityPass",
        "releaseQualityGatePass",
    }
    if set(gates) != required_gates or any(gates.get(key) is not True for key in required_gates):
        raise QualificationError("quality report does not pass every release quality gate")
    if report.get("timingDiagnostic", {}).get("releasePerformanceGateEligible") is not False:
        raise QualificationError("quality diagnostic timing was promoted to release performance evidence")
    corpus_binding = next(
        item for item in entry["identityBindings"] if item["jsonPointer"] == "/identities/corpusManifestSHA256"
    )
    corpus_path = checked_path(evidence_root, corpus_binding["path"], "quality corpus manifest")
    if corpus_path not in sealed_paths:
        raise QualificationError("quality corpus manifest is outside the sealed suite")
    corpus_manifest = require_mapping(load_json(corpus_path), "quality corpus manifest")
    artifacts = require_list(corpus_manifest.get("artifacts"), "quality corpus artifacts")
    corpus_entries: list[tuple[str, str]] = []
    for index, artifact in enumerate(artifacts):
        path, identity = validate_artifact(corpus_path.parent, artifact, f"quality corpus artifact[{index}]")
        if path not in sealed_paths:
            raise QualificationError(f"quality corpus artifact is outside the sealed suite: {path.name}")
        corpus_entries.append((path.relative_to(corpus_path.parent).as_posix(), identity))
    computed_corpus_set = artifact_set_sha(corpus_entries)
    if corpus_manifest.get("artifactSetSHA256") != computed_corpus_set:
        raise QualificationError("quality corpus artifact-set identity mismatch")
    if identities.get("corpusArtifactSetSHA256") != computed_corpus_set:
        raise QualificationError("quality report corpus artifact-set identity mismatch")
    report_path = checked_path(evidence_root, entry["path"], "quality report path")
    capture_path = report_path.parent / "capture-manifest.json"
    if not capture_path.is_file() or capture_path.resolve() not in sealed_paths:
        raise QualificationError("quality capture manifest is absent from the sealed suite")
    capture = require_mapping(load_json(capture_path), "quality capture manifest")
    for key, expected in (
        ("contractSHA256", identities["contractSHA256"]),
        ("corpusManifestSHA256", identities["corpusManifestSHA256"]),
        ("runtimeManifestSHA256", identities["runtimeManifestSHA256"]),
        ("runtimeSourceRevision", identities["runtimeSourceRevision"]),
        ("sourceCommit", identities["sourceCommit"]),
        ("sourceTreeIdentitySHA256", identities["sourceTreeIdentitySHA256"]),
    ):
        if capture.get(key) != expected:
            raise QualificationError(f"quality capture manifest identity mismatch: {key}")
    capture_cases = require_list(capture.get("cases"), "quality capture cases")
    if len(capture_cases) != corpus.get("caseCount"):
        raise QualificationError("quality capture case count mismatch")
    output_entries: dict[str, list[tuple[str, str]]] = {variant: [] for variant in QUALITY_VARIANTS}
    capture_ids: set[str] = set()
    for index, item in enumerate(capture_cases):
        case = require_mapping(item, f"quality capture cases[{index}]")
        identifier = require_string(case.get("id"), f"quality capture cases[{index}].id")
        if identifier in capture_ids:
            raise QualificationError(f"quality capture repeats case: {identifier}")
        capture_ids.add(identifier)
        outputs = require_mapping(case.get("outputs"), f"quality capture outputs {identifier}")
        if set(outputs) != set(QUALITY_VARIANTS):
            raise QualificationError(f"quality capture output variant mismatch: {identifier}")
        for variant, relative in outputs.items():
            output_path = checked_path(report_path.parent, relative, f"quality output {identifier}/{variant}")
            if output_path not in sealed_paths:
                raise QualificationError(f"quality output is outside the sealed suite: {identifier}/{variant}")
            output_entries[variant].append((relative, sha256(output_path)))
    output_sets = {variant: artifact_set_sha(entries) for variant, entries in output_entries.items()}
    if identities.get("outputSetSHA256") != output_sets:
        raise QualificationError("quality raw output artifact-set identity mismatch")
    return {
        "qualityIndex": point,
        "lower95PercentConfidenceBound": lower,
        "upper95PercentConfidenceBound": upper,
        "bootstrapReplicateCount": replicates,
        "corpusArtifactSetSHA256": computed_corpus_set,
    }


def validate_claimed_interval(
    value: Any,
    point: float,
    lower: float,
    upper: float,
    replicates: int,
    label: str,
) -> None:
    interval = require_mapping(value, label)
    require_exact_keys(interval, {"pointRatio", "lower", "upper", "replicateCount"}, label)
    require_close(interval["pointRatio"], point, f"{label}.pointRatio")
    require_close(interval["lower"], lower, f"{label}.lower")
    require_close(interval["upper"], upper, f"{label}.upper")
    if interval["replicateCount"] != replicates:
        raise QualificationError(f"{label}.replicateCount mismatch")


def validate_performance(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "same_scope_performance"
    if report.get("schemaVersion") != contract["evidenceSchemas"][label]:
        raise QualificationError("performance has unsupported schema")
    if report.get("contractSHA256") != contract_sha:
        raise QualificationError("performance contract identity mismatch")
    supplied_report_identity = require_hex(
        report.get("reportSHA256"), 64, "performance.reportSHA256"
    )
    unsigned_report = dict(report)
    del unsigned_report["reportSHA256"]
    performance_report_identity = sha256_bytes(
        canonical_bytes(unsigned_report) + b"\n"
    )
    if supplied_report_identity != performance_report_identity:
        raise QualificationError("performance report self-seal mismatch")

    binding_paths = {
        binding["jsonPointer"]: checked_path(
            evidence_root,
            binding["path"],
            f"performance binding {binding['jsonPointer']}",
        )
        for binding in entry["identityBindings"]
    }
    suite_contract_path = binding_paths["/contractSHA256"]
    suite_contract = require_mapping(load_json(suite_contract_path), "performance suite contract")
    if suite_contract.get("schemaVersion") != "mirmir-v4-performance-gate-contract-v1":
        raise QualificationError("performance suite contract schema mismatch")
    if report.get("gateID") != suite_contract.get("gateID"):
        raise QualificationError("performance gate identity mismatch")
    settings = require_mapping(contract["performance"], "performance release settings")
    suite_measurement = require_mapping(
        suite_contract.get("measurement"), "performance suite measurement contract"
    )
    suite_thresholds = require_mapping(
        suite_contract.get("thresholds"), "performance suite thresholds"
    )
    maximum = require_number(
        suite_thresholds.get("maximumProcessingTimeRatio"),
        "performance maximum ratio",
        positive=True,
    )
    if not math.isclose(maximum, float(settings["maximumRatio"]), rel_tol=0, abs_tol=0):
        raise QualificationError("performance suite changes the 20% release threshold")
    iterations = require_integer(
        suite_measurement.get("bootstrapIterations"),
        "performance bootstrap iterations",
        settings["minimumBootstrapReplicates"],
    )
    confidence = require_number(
        suite_measurement.get("confidenceLevel"), "performance confidence level"
    )
    if not math.isclose(
        confidence, float(settings["bootstrapConfidenceLevel"]), rel_tol=0, abs_tol=0
    ):
        raise QualificationError("performance confidence level is not release-locked")
    require_bool(
        suite_measurement.get("requireUpperConfidenceBoundAtOrBelowThreshold"),
        "performance upper-confidence requirement",
        True,
    )
    seed = require_integer(suite_measurement.get("bootstrapSeed"), "performance bootstrap seed")
    environment_policy = require_mapping(
        suite_contract.get("environment"), "performance environment policy"
    )
    for key in (
        "requireIdenticalHardwareAndSoftwareImage",
        "requireIdenticalPowerState",
        "rejectThermalWarnings",
    ):
        require_bool(environment_policy.get(key), f"performance environment policy.{key}", True)

    def validate_nested_manifest(manifest_path: Path, nested_label: str) -> None:
        manifest = require_mapping(load_json(manifest_path), nested_label)
        if manifest.get("schemaVersion") != "mirmir-v4-performance-capture-artifacts-v1":
            raise QualificationError(f"{nested_label} schema mismatch")
        artifacts = require_list(manifest.get("artifacts"), f"{nested_label}.artifacts")
        resolved: set[Path] = set()
        for artifact_index, artifact in enumerate(artifacts):
            path, _ = validate_artifact(
                manifest_path.parent,
                artifact,
                f"{nested_label}.artifacts[{artifact_index}]",
            )
            if path not in sealed_paths:
                raise QualificationError(f"{nested_label} artifact is outside root seal")
            if path in resolved:
                raise QualificationError(f"{nested_label} repeats an artifact")
            resolved.add(path)
        actual = {
            path.resolve()
            for path in manifest_path.parent.iterdir()
            if path.is_file() and path.resolve() != manifest_path
        }
        if actual != resolved:
            raise QualificationError(f"{nested_label} file set is incomplete or unsealed")

    baseline_source_path = binding_paths["/baseline/sourceIdentitySHA256"]
    candidate_source_path = binding_paths["/candidate/sourceIdentitySHA256"]
    baseline_manifest_path = binding_paths["/baseline/artifactManifestSHA256"]
    candidate_manifest_path = binding_paths["/candidate/artifactManifestSHA256"]
    for expected_name, path in (
        ("baseline", baseline_source_path),
        ("candidate", candidate_source_path),
    ):
        if path.name != "source-identity.json" or path.parent.name != expected_name:
            raise QualificationError(f"performance {expected_name} source path is non-canonical")
    validate_nested_manifest(baseline_manifest_path, "performance baseline artifact manifest")
    validate_nested_manifest(candidate_manifest_path, "performance candidate artifact manifest")

    def load_environment(path: Path, environment_label: str) -> dict[str, Any]:
        environment = require_mapping(load_json(path), environment_label)
        if environment.get("schemaVersion") != "mirmir-v4-performance-environment-v1":
            raise QualificationError(f"{environment_label} schema mismatch")
        stable = require_mapping(environment.get("stableIdentity"), f"{environment_label}.stableIdentity")
        for field in (
            "hardwareModel",
            "memoryBytes",
            "processor",
            "gpuIdentity",
            "macOSBuild",
            "xcodeBuild",
            "swiftCompiler",
        ):
            if field not in stable:
                raise QualificationError(f"{environment_label} lacks {field}")
        require_bool(
            require_mapping(environment.get("thermal"), f"{environment_label}.thermal").get("accepted"),
            f"{environment_label}.thermal.accepted",
            True,
        )
        require_string(
            require_mapping(environment.get("power"), f"{environment_label}.power").get("identity"),
            f"{environment_label}.power.identity",
        )
        return environment

    def validate_capture(
        directory: Path,
        variant: str,
        source_path: Path,
    ) -> dict[str, Any]:
        source = require_mapping(load_json(source_path), f"performance {variant} source identity")
        if source.get("schemaVersion") != "mirmir-v4-performance-source-identity-v1":
            raise QualificationError(f"performance {variant} source schema mismatch")
        if source.get("variant") != variant:
            raise QualificationError(f"performance {variant} source variant mismatch")
        source_revision = require_hex(
            source.get("sourceRevision"), 40, f"performance {variant} source revision"
        )
        source_tree = require_hex(
            source.get("sourceTreeSHA256"), 64, f"performance {variant} source tree"
        )
        runtime = require_mapping(source.get("runtime"), f"performance {variant} runtime")
        require_bool(runtime.get("artifactsVerified"), f"performance {variant} artifactsVerified", True)
        if variant == "baseline_p05":
            baseline_contract = require_mapping(
                suite_contract.get("baseline"), "performance baseline contract"
            )
            if source_revision != baseline_contract.get("sourceRevision"):
                raise QualificationError("performance baseline revision is not frozen")
            if runtime.get("status") != baseline_contract.get("runtimeStatus"):
                raise QualificationError("performance baseline runtime status mismatch")
            if runtime.get("implementationVersions") != baseline_contract.get("implementationVersions"):
                raise QualificationError("performance baseline implementation identity mismatch")
            if runtime.get("releaseQualified") is not False or runtime.get("manifestSHA256") is not None:
                raise QualificationError("performance P05 baseline invents release qualification")
        else:
            if source_revision != candidate["sourceCommit"] or source_tree != candidate["sourceTreeIdentitySHA256"]:
                raise QualificationError("performance candidate source is stale")
            candidate_contract = require_mapping(
                suite_contract.get("candidate"), "performance candidate contract"
            )
            if runtime.get("status") != candidate_contract.get("requiredRuntimeStatus"):
                raise QualificationError("performance candidate runtime is not release-qualified")
            if runtime.get("runtimeID") != candidate_contract.get("requiredRuntimeID"):
                raise QualificationError("performance candidate runtime identity mismatch")
            if runtime.get("implementationVersions") != ["ash-p06-deterministic-v4"]:
                raise QualificationError("performance candidate implementation identity mismatch")
            for key in ("releaseQualified", "trustRootConfigured", "artifactsVerified"):
                require_bool(runtime.get(key), f"performance candidate runtime.{key}", True)
            if runtime.get("manifestSHA256") != candidate["runtimeManifestSHA256"]:
                raise QualificationError("performance candidate P06 manifest is stale")
            if runtime.get("manifestSourceRevision") != candidate["runtimeSourceRevision"]:
                raise QualificationError("performance candidate P06 source is stale")
            require_hex(
                runtime.get("builderSourceSHA256"),
                64,
                "performance candidate builder source",
            )
            folded_runtime = json.dumps(runtime, sort_keys=True).lower()
            if "p05" in folded_runtime or "preview" in folded_runtime:
                raise QualificationError("performance candidate retains a preview runtime identity")
        before = load_environment(
            directory / "environment-before.json", f"performance {variant} environment before"
        )
        after = load_environment(
            directory / "environment-after.json", f"performance {variant} environment after"
        )
        capture_path = directory / "capture.json"
        if capture_path.resolve() not in sealed_paths:
            raise QualificationError(f"performance {variant} capture is outside root seal")
        capture = require_mapping(load_json(capture_path), f"performance {variant} capture")
        if capture.get("schemaVersion") != "mirmir-v4-performance-capture-v1":
            raise QualificationError(f"performance {variant} capture schema mismatch")
        if capture.get("variant") != variant or capture.get("contractSHA256") != contract_sha:
            raise QualificationError(f"performance {variant} capture identity mismatch")
        if capture.get("sourceIdentitySHA256") != sha256(source_path):
            raise QualificationError(f"performance {variant} capture/source binding mismatch")
        if capture.get("sourceRevision") != source_revision or capture.get("sourceTreeSHA256") != source_tree:
            raise QualificationError(f"performance {variant} capture source is stale")
        if capture.get("buildConfiguration") != "Release":
            raise QualificationError(f"performance {variant} was not captured in Release")
        warmups = require_integer(
            capture.get("warmupCount"),
            f"performance {variant} warmups",
            settings["minimumWarmups"],
        )
        samples = require_integer(
            capture.get("sampleCount"),
            f"performance {variant} samples",
            settings["minimumMeasuredRuns"],
        )
        input_contract = require_mapping(
            require_mapping(suite_contract.get("workload"), "performance workload").get("input"),
            "performance input contract",
        )
        observed_input = require_mapping(capture.get("input"), f"performance {variant} input")
        for field in (
            "sha256",
            "byteCount",
            "width",
            "height",
            "codecFourCC",
            "frameCount",
            "trackCount",
            "enabledVideoTrackCount",
            "durationNumerator",
            "durationTimescale",
        ):
            if observed_input.get(field) != input_contract.get(field):
                raise QualificationError(f"performance {variant} input {field} mismatch")
        require_bool(
            observed_input.get("allRequiredChecksPassed"),
            f"performance {variant} input checks",
            True,
        )
        requested_cases = require_list(
            require_mapping(suite_contract["workload"], "performance workload").get("cases"),
            "performance mandatory cases",
        )
        requested = {item["id"]: item for item in requested_cases}
        cases = require_list(capture.get("cases"), f"performance {variant} cases")
        if len(cases) != len(requested):
            raise QualificationError(f"performance {variant} mandatory case count mismatch")
        case_map: dict[str, dict[str, Any]] = {}
        verification_flags = {
            "requestedBackendExecutedWithoutFallback",
            "allInputTracksAccounted",
            "exactEnabledVideoTrackCount",
            "exactEncodedDimensions",
            "exactCodec",
            "exactFrameCount",
            "exactPresentationTimestamps",
            "exactDuration",
            "bt709ColorContract",
            "allRequiredChecksPassed",
        }
        for case_index, item in enumerate(cases):
            case = require_mapping(item, f"performance {variant} case[{case_index}]")
            identifier = require_string(case.get("id"), f"performance {variant} case ID")
            if identifier not in requested or identifier in case_map:
                raise QualificationError(f"performance {variant} unexpected/duplicate case: {identifier}")
            expected = requested[identifier]
            for field in ("backendID", "targetWidth", "targetHeight"):
                if case.get(field) != expected.get(field):
                    raise QualificationError(f"performance {variant} case {identifier} {field} mismatch")
            engine_runs = require_list(case.get("engineRuns"), f"performance {identifier} engine runs")
            wall_runs = require_list(case.get("endToEndRuns"), f"performance {identifier} wall runs")
            if len(engine_runs) != samples or len(wall_runs) != samples:
                raise QualificationError(f"performance {variant} case {identifier} sample count mismatch")
            expected_indices = list(range(samples))
            if [run.get("sampleIndex") for run in engine_runs] != expected_indices:
                raise QualificationError(f"performance {variant} engine sample order mismatch")
            if [run.get("sampleIndex") for run in wall_runs] != expected_indices:
                raise QualificationError(f"performance {variant} wall sample order mismatch")
            pixel_hashes: set[str] = set()
            track_hashes: set[str] = set()
            for run_index, run_value in enumerate(engine_runs):
                run = require_mapping(run_value, f"performance {identifier} engine run[{run_index}]")
                frames = sample_values(
                    run.get("frameMilliseconds"),
                    f"performance {identifier} engine frames[{run_index}]",
                    input_contract["frameCount"],
                )
                if len(frames) != input_contract["frameCount"]:
                    raise QualificationError(f"performance {identifier} frame sample count mismatch")
                if run.get("processedFrameCount") != input_contract["frameCount"]:
                    raise QualificationError(f"performance {identifier} processed frame count mismatch")
            for run_index, run_value in enumerate(wall_runs):
                run = require_mapping(run_value, f"performance {identifier} wall run[{run_index}]")
                require_number(run.get("wallMilliseconds"), f"performance {identifier} wall", positive=True)
                require_integer(run.get("peakResidentBytes"), f"performance {identifier} peak memory")
                if run.get("processedFrameCount") != input_contract["frameCount"]:
                    raise QualificationError(f"performance {identifier} output frame count mismatch")
                verification = require_mapping(
                    run.get("verification"), f"performance {identifier} verification[{run_index}]"
                )
                for flag in verification_flags:
                    require_bool(
                        verification.get(flag),
                        f"performance {identifier} verification {flag}",
                        True,
                    )
                pixel_hashes.add(
                    require_hex(
                        verification.get("decodedVisiblePixelSHA256"),
                        64,
                        f"performance {identifier} decoded pixels",
                    )
                )
                track_hashes.add(
                    require_hex(
                        verification.get("semanticTrackManifestSHA256"),
                        64,
                        f"performance {identifier} track manifest",
                    )
                )
            if len(pixel_hashes) != 1 or len(track_hashes) != 1:
                raise QualificationError(f"performance {identifier} semantic output changed across runs")
            case_map[identifier] = case
        return {
            "capture": capture,
            "source": source,
            "runtime": runtime,
            "before": before,
            "after": after,
            "cases": case_map,
            "warmups": warmups,
            "samples": samples,
        }

    baseline = validate_capture(baseline_source_path.parent, "baseline_p05", baseline_source_path)
    observed = validate_capture(candidate_source_path.parent, "candidate_p06", candidate_source_path)
    if baseline["warmups"] != observed["warmups"] or baseline["samples"] != observed["samples"]:
        raise QualificationError("performance paired warmup/sample counts differ")
    report_measurement = require_mapping(
        report.get("measurement"), "performance report measurement"
    )
    expected_measurement = {
        "buildConfiguration": "Release",
        "warmupCount": baseline["warmups"],
        "measuredRunCount": baseline["samples"],
        "engineFrameSampleCount": sum(
            len(run["frameMilliseconds"])
            for case in baseline["cases"].values()
            for run in case["engineRuns"]
        ),
        "mandatoryCaseCount": len(baseline["cases"]),
        "bootstrapIterations": iterations,
        "confidenceLevel": confidence,
        "thresholdRatio": maximum,
        "upperConfidenceBoundRequired": True,
    }
    if set(report_measurement) != set(expected_measurement):
        raise QualificationError("performance report measurement field set mismatch")
    for key, expected in expected_measurement.items():
        if isinstance(expected, float):
            require_close(
                report_measurement.get(key), expected, f"performance measurement.{key}"
            )
        elif report_measurement.get(key) != expected:
            raise QualificationError(f"performance measurement.{key} mismatch")
    baseline_report = require_mapping(report.get("baseline"), "performance baseline report identity")
    candidate_report = require_mapping(report.get("candidate"), "performance candidate report identity")
    expected_report_identities = (
        (baseline_report, baseline, baseline_source_path, baseline_manifest_path),
        (candidate_report, observed, candidate_source_path, candidate_manifest_path),
    )
    for report_identity, capture, source_path, manifest_path in expected_report_identities:
        if report_identity.get("sourceRevision") != capture["source"]["sourceRevision"]:
            raise QualificationError("performance report source revision mismatch")
        if report_identity.get("sourceTreeSHA256") != capture["source"]["sourceTreeSHA256"]:
            raise QualificationError("performance report source tree mismatch")
        if report_identity.get("sourceIdentitySHA256") != sha256(source_path):
            raise QualificationError("performance report source identity mismatch")
        if report_identity.get("artifactManifestSHA256") != sha256(manifest_path):
            raise QualificationError("performance report artifact manifest mismatch")
    if candidate_report.get("runtimeManifestSHA256") != candidate["runtimeManifestSHA256"]:
        raise QualificationError("performance report P06 identity mismatch")

    def wall_samples(capture: Mapping[str, Any]) -> list[float]:
        return [
            math.fsum(
                capture["cases"][case_id]["endToEndRuns"][sample_index]["wallMilliseconds"]
                for case_id in sorted(capture["cases"])
            )
            for sample_index in range(capture["samples"])
        ]

    def engine_samples(capture: Mapping[str, Any]) -> list[float]:
        return [
            float(value)
            for case_id in sorted(capture["cases"])
            for run in capture["cases"][case_id]["engineRuns"]
            for value in run["frameMilliseconds"]
        ]

    def percentile(values: Sequence[float], quantile: float) -> float:
        ordered = sorted(values)
        position = (len(ordered) - 1) * quantile
        lower_index = math.floor(position)
        upper_index = math.ceil(position)
        fraction = position - lower_index
        return ordered[lower_index] * (1.0 - fraction) + ordered[upper_index] * fraction

    def bootstrap_interval(
        before: Sequence[float],
        after: Sequence[float],
        statistic: Callable[[Sequence[float]], float],
        bootstrap_seed: int,
    ) -> dict[str, float]:
        if len(before) != len(after) or len(before) <= 1:
            raise QualificationError("performance paired bootstrap population differs")
        generator = random.Random(bootstrap_seed)
        ratios: list[float] = []
        for _ in range(iterations):
            indices = [generator.randrange(len(before)) for _ in before]
            before_value = statistic([before[index] for index in indices])
            after_value = statistic([after[index] for index in indices])
            if before_value <= 0:
                raise QualificationError("performance bootstrap baseline is not positive")
            ratios.append(after_value / before_value)
        tail = (1.0 - confidence) / 2.0
        return {
            "confidenceLevel": confidence,
            "lower": percentile(ratios, tail),
            "upper": percentile(ratios, 1.0 - tail),
        }

    baseline_wall = wall_samples(baseline)
    candidate_wall = wall_samples(observed)
    baseline_engine = engine_samples(baseline)
    candidate_engine = engine_samples(observed)
    metric_inputs = {
        "aggregateCorpusWall": (
            statistics.median(candidate_wall) / statistics.median(baseline_wall),
            bootstrap_interval(baseline_wall, candidate_wall, statistics.median, seed),
        ),
        "engineFrameMedian": (
            statistics.median(candidate_engine) / statistics.median(baseline_engine),
            bootstrap_interval(
                baseline_engine,
                candidate_engine,
                statistics.median,
                seed ^ 0x4D454449414E,
            ),
        ),
        "engineFrameP95": (
            percentile(candidate_engine, 0.95) / percentile(baseline_engine, 0.95),
            bootstrap_interval(
                baseline_engine,
                candidate_engine,
                lambda values: percentile(values, 0.95),
                seed ^ 0x503935,
            ),
        ),
    }
    metric_gates = require_mapping(report.get("metricGates"), "performance metric gates")
    if set(metric_gates) != set(metric_inputs):
        raise QualificationError("performance metric gate set mismatch")
    ratios: dict[str, float] = {}
    upper_bounds: dict[str, float] = {}
    for metric, (ratio, interval) in metric_inputs.items():
        gate = require_mapping(metric_gates[metric], f"performance metric {metric}")
        require_close(gate.get("ratio"), ratio, f"performance metric {metric}.ratio")
        claimed_interval = require_mapping(
            gate.get("confidenceInterval"), f"performance metric {metric}.confidenceInterval"
        )
        for field, expected in interval.items():
            require_close(
                claimed_interval.get(field), expected, f"performance metric {metric}.{field}"
            )
        expected_point = ratio <= maximum
        expected_upper = interval["upper"] <= maximum
        require_bool(gate.get("pointEstimatePass"), f"performance {metric}.point pass", expected_point)
        require_bool(
            gate.get("upperConfidenceBoundPass"),
            f"performance {metric}.upper confidence pass",
            expected_upper,
        )
        require_bool(gate.get("pass"), f"performance {metric}.pass", expected_point and expected_upper)
        if not expected_point or not expected_upper:
            raise QualificationError(f"performance {metric} misses the 20% confidence gate")
        ratios[metric] = ratio
        upper_bounds[metric] = interval["upper"]

    absolute = require_mapping(report.get("absoluteMilliseconds"), "performance absolute times")
    absolute_expected = {
        "baseline": {
            "aggregateCorpusWallMedian": statistics.median(baseline_wall),
            "engineFrameMedian": statistics.median(baseline_engine),
            "engineFrameP95": percentile(baseline_engine, 0.95),
        },
        "candidate": {
            "aggregateCorpusWallMedian": statistics.median(candidate_wall),
            "engineFrameMedian": statistics.median(candidate_engine),
            "engineFrameP95": percentile(candidate_engine, 0.95),
        },
    }
    for variant, values in absolute_expected.items():
        observed_values = require_mapping(absolute.get(variant), f"performance absolute {variant}")
        for metric, expected in values.items():
            require_close(observed_values.get(metric), expected, f"performance absolute {variant}.{metric}")

    case_ratios = require_list(report.get("mandatoryCaseRatios"), "performance case ratios")
    reported_cases = {item.get("id"): item for item in case_ratios if isinstance(item, dict)}
    if set(reported_cases) != set(baseline["cases"]):
        raise QualificationError("performance mandatory case ratio coverage mismatch")
    worst_case_ratio = 0.0
    for case_id in sorted(baseline["cases"]):
        before_case = baseline["cases"][case_id]
        after_case = observed["cases"][case_id]
        before_wall = [run["wallMilliseconds"] for run in before_case["endToEndRuns"]]
        after_wall = [run["wallMilliseconds"] for run in after_case["endToEndRuns"]]
        before_engine = [value for run in before_case["engineRuns"] for value in run["frameMilliseconds"]]
        after_engine = [value for run in after_case["engineRuns"] for value in run["frameMilliseconds"]]
        expected = {
            "wallMedianRatio": statistics.median(after_wall) / statistics.median(before_wall),
            "engineMedianRatio": statistics.median(after_engine) / statistics.median(before_engine),
            "engineP95Ratio": percentile(after_engine, 0.95) / percentile(before_engine, 0.95),
        }
        row = reported_cases[case_id]
        for metric, value in expected.items():
            require_close(row.get(metric), value, f"performance case {case_id}.{metric}")
            worst_case_ratio = max(worst_case_ratio, value)

    baseline_peak = max(
        run["peakResidentBytes"]
        for case in baseline["cases"].values()
        for run in case["endToEndRuns"]
    )
    candidate_peak = max(
        run["peakResidentBytes"]
        for case in observed["cases"].values()
        for run in case["endToEndRuns"]
    )
    memory = require_mapping(report.get("memoryGate"), "performance memory gate")
    budget = require_integer(
        suite_thresholds.get("temporalHistoryResidentBudgetBytes"),
        "performance temporal history budget",
    )
    expected_memory = {
        "baselinePeakResidentBytes": baseline_peak,
        "candidatePeakResidentBytes": candidate_peak,
        "temporalHistoryBudgetBytes": budget,
        "maximumCandidateResidentBytes": baseline_peak + budget,
        "pass": candidate_peak <= baseline_peak + budget,
    }
    if memory != expected_memory or not expected_memory["pass"]:
        raise QualificationError("performance memory gate mismatch/failure")

    environments = [baseline["before"], baseline["after"], observed["before"], observed["after"]]
    stable_match = len({canonical_bytes(value["stableIdentity"]) for value in environments}) == 1
    power_match = len({value["power"]["identity"] for value in environments}) == 1
    thermal_pass = all(value["thermal"]["accepted"] is True for value in environments)
    expected_environment = {
        "stableHardwareAndSoftwareImageMatch": stable_match,
        "powerStateMatch": power_match,
        "thermalEnvelopeAccepted": thermal_pass,
        "pass": stable_match and power_match and thermal_pass,
    }
    if report.get("environmentGate") != expected_environment or not expected_environment["pass"]:
        raise QualificationError("performance environment gate mismatch/failure")
    require_bool(
        report.get("semanticVerificationPass"), "performance semantic verification", True
    )
    require_bool(report.get("gatePass"), "performance gatePass", True)
    return {
        "aggregateRatios": ratios,
        "upper95PercentConfidenceBounds": upper_bounds,
        "worstMandatoryClassRatio": worst_case_ratio,
        "warmupCount": baseline["warmups"],
        "measuredRunCount": baseline["samples"],
        "engineFrameSampleCount": len(baseline_engine),
        "runtimeBuilderSHA256": observed["runtime"]["builderSourceSHA256"],
    }


def validate_parity(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "cpu_metal_parity"
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    identities = require_mapping(report.get("identities"), "parity.identities")
    parity_identity_keys = {
        "captureSourceSHA256",
        "evaluatorSHA256",
        "runnerSHA256",
    }
    require_exact_keys(identities, parity_identity_keys, "parity.identities")
    for key in parity_identity_keys:
        require_hex(identities[key], 64, f"parity.identities.{key}")
    if report.get("comparison") != "exact_visible_plane_and_attachment_bytes":
        raise QualificationError("parity comparison is not byte exact")
    cases = require_list(report.get("cases"), "parity.cases")
    required = set(contract["parityCoverage"])
    covered: set[str] = set()
    identities: set[str] = set()
    for index, item in enumerate(cases):
        case = require_mapping(item, f"parity.cases[{index}]")
        require_exact_keys(
            case,
            {
                "id",
                "coverage",
                "cpuVisibleArtifact",
                "metalVisibleArtifact",
                "cpuAttachmentsArtifact",
                "metalAttachmentsArtifact",
                "repeatRunIdentityPass",
                "crossProcessIdentityPass",
                "tileScheduleIdentityPass",
            },
            f"parity.cases[{index}]",
        )
        identifier = require_string(case["id"], f"parity case[{index}].id")
        if identifier in identities:
            raise QualificationError(f"parity repeats case: {identifier}")
        identities.add(identifier)
        coverage = set(require_list(case["coverage"], f"parity {identifier}.coverage"))
        if not coverage or not coverage.issubset(required):
            raise QualificationError(f"parity case has unexpected/empty coverage: {identifier}")
        covered.update(coverage)
        cpu_path, cpu = validate_sealed_artifact(
            evidence_root, case["cpuVisibleArtifact"], sealed_paths, f"parity {identifier}.cpuVisibleArtifact"
        )
        metal_path, metal = validate_sealed_artifact(
            evidence_root, case["metalVisibleArtifact"], sealed_paths, f"parity {identifier}.metalVisibleArtifact"
        )
        cpu_attachment_path, cpu_attachments = validate_sealed_artifact(
            evidence_root,
            case["cpuAttachmentsArtifact"],
            sealed_paths,
            f"parity {identifier}.cpuAttachmentsArtifact",
        )
        metal_attachment_path, metal_attachments = validate_sealed_artifact(
            evidence_root,
            case["metalAttachmentsArtifact"],
            sealed_paths,
            f"parity {identifier}.metalAttachmentsArtifact",
        )
        if (
            cpu_path == metal_path
            or cpu_attachment_path == metal_attachment_path
            or cpu != metal
            or cpu_path.stat().st_size != metal_path.stat().st_size
            or cpu_attachments != metal_attachments
            or cpu_attachment_path.stat().st_size != metal_attachment_path.stat().st_size
        ):
            raise QualificationError(f"CPU/Metal parity mismatch: {identifier}")
        for key in ("repeatRunIdentityPass", "crossProcessIdentityPass", "tileScheduleIdentityPass"):
            require_bool(case[key], f"parity {identifier}.{key}", True)
    if covered != required:
        raise QualificationError(f"parity coverage mismatch; missing={sorted(required-covered)}")
    require_bool(report.get("byteParityGatePass"), "parity.byteParityGatePass", True)
    return {"caseCount": len(cases), "coverage": sorted(covered), "maximumByteDifference": 0}


def media_fraction(value: Any, label: str) -> Fraction:
    text = require_string(value, label)
    try:
        result = Fraction(text)
    except (ValueError, ZeroDivisionError) as error:
        raise QualificationError(f"{label} is not an exact rational") from error
    if str(result) != text and not (result.denominator == 1 and text == f"{result.numerator}/1"):
        raise QualificationError(f"{label} is not a reduced exact rational")
    return result


def media_track_index(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    rows = require_list(value.get("tracks"), f"{label}.tracks")
    indexed: dict[int, dict[str, Any]] = {}
    for index, raw in enumerate(rows):
        row = require_mapping(raw, f"{label}.tracks[{index}]")
        ordinal = require_integer(row.get("ordinal"), f"{label}.tracks[{index}].ordinal")
        if ordinal in indexed:
            raise QualificationError(f"{label} repeats track ordinal {ordinal}")
        indexed[ordinal] = row
    if list(indexed) != sorted(indexed):
        raise QualificationError(f"{label} track order is not canonical")
    return indexed


def validate_media_track_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(
        value,
        {
            "schemaVersion", "fixtureID", "side", "enabledTrackCount", "tracks",
            "groups", "associations", "assetMetadataSHA256", "chapterMetadataSHA256",
        },
        label,
    )
    if value["schemaVersion"] != MEDIA_TRACK_SCHEMA:
        raise QualificationError(f"{label} schema mismatch")
    require_hex(value["assetMetadataSHA256"], 64, f"{label}.assetMetadataSHA256")
    require_hex(value["chapterMetadataSHA256"], 64, f"{label}.chapterMetadataSHA256")
    tracks = media_track_index(value, label)
    enabled = 0
    for ordinal, track in tracks.items():
        track_label = f"{label}.track[{ordinal}]"
        require_exact_keys(
            track,
            {
                "ordinal", "kind", "enabled", "mediaTypeID", "codecID", "languageCode",
                "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256",
                "editsSHA256", "formatSHA256", "metadataSHA256",
            },
            track_label,
        )
        require_string(track["kind"], f"{track_label}.kind")
        enabled += int(require_bool(track["enabled"], f"{track_label}.enabled"))
        for key in ("mediaTypeID", "codecID", "timebase"):
            require_string(track[key], f"{track_label}.{key}")
        for key in ("timeRangeSHA256", "editsSHA256", "formatSHA256", "metadataSHA256"):
            require_hex(track[key], 64, f"{track_label}.{key}")
        for key in ("languageCode", "extendedLanguageTag"):
            if track[key] is not None and not isinstance(track[key], str):
                raise QualificationError(f"{track_label}.{key} is invalid")
        roles = require_list(track["roleIDs"], f"{track_label}.roleIDs")
        if roles != sorted(set(roles)) or any(not isinstance(role, str) or not role for role in roles):
            raise QualificationError(f"{track_label}.roleIDs is noncanonical")
    if require_integer(value["enabledTrackCount"], f"{label}.enabledTrackCount") != enabled:
        raise QualificationError(f"{label} enabled-track count mismatch")
    require_list(value["groups"], f"{label}.groups")
    require_list(value["associations"], f"{label}.associations")
    return tracks


def validate_media_timing_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, {"schemaVersion", "fixtureID", "side", "tracks"}, label)
    if value["schemaVersion"] != MEDIA_TIMING_SCHEMA:
        raise QualificationError(f"{label} schema mismatch")
    tracks = media_track_index(value, label)
    for ordinal, track in tracks.items():
        track_label = f"{label}.track[{ordinal}]"
        require_exact_keys(
            track,
            {"ordinal", "sampleCount", "timingSHA256", "encodedPayloadSHA256", "samples"},
            track_label,
        )
        samples = require_list(track["samples"], f"{track_label}.samples")
        if require_integer(track["sampleCount"], f"{track_label}.sampleCount") != len(samples):
            raise QualificationError(f"{track_label} sample count mismatch")
        timings: list[dict[str, Any]] = []
        payloads: list[str] = []
        for sample_index, raw_sample in enumerate(samples):
            sample = require_mapping(raw_sample, f"{track_label}.samples[{sample_index}]")
            require_exact_keys(
                sample,
                {"pts", "dts", "duration", "byteCount", "payloadSHA256"},
                f"{track_label}.samples[{sample_index}]",
            )
            media_fraction(sample["pts"], f"{track_label}.samples[{sample_index}].pts")
            if sample["dts"] != "invalid":
                media_fraction(sample["dts"], f"{track_label}.samples[{sample_index}].dts")
            media_fraction(sample["duration"], f"{track_label}.samples[{sample_index}].duration")
            require_integer(sample["byteCount"], f"{track_label}.samples[{sample_index}].byteCount")
            payloads.append(require_hex(sample["payloadSHA256"], 64, f"{track_label}.samples[{sample_index}].payloadSHA256"))
            timings.append({key: sample[key] for key in ("pts", "dts", "duration")})
        if require_hex(track["timingSHA256"], 64, f"{track_label}.timingSHA256") != sha256_bytes(canonical_bytes(timings)):
            raise QualificationError(f"{track_label} timing identity mismatch")
        if require_hex(track["encodedPayloadSHA256"], 64, f"{track_label}.encodedPayloadSHA256") != sha256_bytes(canonical_bytes(payloads)):
            raise QualificationError(f"{track_label} payload-set identity mismatch")
    return tracks


def validate_media_pixel_observation(
    value: Mapping[str, Any], pixel_path: Path, label: str
) -> dict[int, dict[str, Any]]:
    require_exact_keys(
        value,
        {"schemaVersion", "fixtureID", "side", "pixelArtifactSHA256", "pixelArtifactByteCount", "tracks"},
        label,
    )
    if value["schemaVersion"] != MEDIA_PIXEL_SCHEMA:
        raise QualificationError(f"{label} schema mismatch")
    if require_hex(value["pixelArtifactSHA256"], 64, f"{label}.pixelArtifactSHA256") != sha256(pixel_path):
        raise QualificationError(f"{label} pixel artifact identity mismatch")
    if require_integer(value["pixelArtifactByteCount"], f"{label}.pixelArtifactByteCount") != pixel_path.stat().st_size:
        raise QualificationError(f"{label} pixel artifact byte count mismatch")
    tracks = media_track_index(value, label)
    for ordinal, track in tracks.items():
        track_label = f"{label}.track[{ordinal}]"
        require_exact_keys(
            track,
            {
                "ordinal", "kind", "pixelFormat", "bitDepth", "width", "height", "frameCount",
                "visibleSHA256", "repeatVisibleSHA256", "alphaSHA256", "preEncodeAlphaSHA256",
                "decodedAlphaSHA256", "uniqueSignalCodeCount", "lowPaddingBitViolationCount",
            },
            track_label,
        )
        require_string(track["kind"], f"{track_label}.kind")
        require_string(track["pixelFormat"], f"{track_label}.pixelFormat")
        for key in ("bitDepth", "width", "height", "frameCount", "uniqueSignalCodeCount", "lowPaddingBitViolationCount"):
            require_integer(track[key], f"{track_label}.{key}")
        for key in ("visibleSHA256", "repeatVisibleSHA256"):
            require_hex(track[key], 64, f"{track_label}.{key}")
        for key in ("alphaSHA256", "preEncodeAlphaSHA256", "decodedAlphaSHA256"):
            if track[key] is not None:
                require_hex(track[key], 64, f"{track_label}.{key}")
    return tracks


def validate_media_attachment_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, {"schemaVersion", "fixtureID", "side", "tracks"}, label)
    if value["schemaVersion"] != MEDIA_ATTACHMENT_SCHEMA:
        raise QualificationError(f"{label} schema mismatch")
    tracks = media_track_index(value, label)
    keys = {
        "ordinal", "kind", "fieldCount", "fieldDetail", "cadence", "pixelAspectRatio",
        "cleanAperture", "preferredTransform", "colorPrimaries", "transferFunction",
        "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256", "dynamicHDRSamples",
        "alphaAssociation",
    }
    for ordinal, track in tracks.items():
        track_label = f"{label}.track[{ordinal}]"
        require_exact_keys(track, keys, track_label)
        require_integer(track["fieldCount"], f"{track_label}.fieldCount", 1)
        for key in ("kind", "fieldDetail", "cadence"):
            require_string(track[key], f"{track_label}.{key}")
        aspect = require_mapping(track["pixelAspectRatio"], f"{track_label}.pixelAspectRatio")
        require_exact_keys(aspect, {"horizontal", "vertical"}, f"{track_label}.pixelAspectRatio")
        require_integer(aspect["horizontal"], f"{track_label}.pixelAspectRatio.horizontal", 1)
        require_integer(aspect["vertical"], f"{track_label}.pixelAspectRatio.vertical", 1)
        aperture = require_mapping(track["cleanAperture"], f"{track_label}.cleanAperture")
        require_exact_keys(aperture, {"width", "height", "horizontalOffset", "verticalOffset"}, f"{track_label}.cleanAperture")
        for key in aperture:
            media_fraction(aperture[key], f"{track_label}.cleanAperture.{key}")
        transform = require_list(track["preferredTransform"], f"{track_label}.preferredTransform")
        if len(transform) != 6:
            raise QualificationError(f"{track_label}.preferredTransform must contain six rationals")
        for index, element in enumerate(transform):
            media_fraction(element, f"{track_label}.preferredTransform[{index}]")
        for key in ("colorPrimaries", "transferFunction", "yCbCrMatrix", "alphaAssociation"):
            if track[key] is not None:
                require_string(track[key], f"{track_label}.{key}")
        for key in ("masteringDisplaySHA256", "contentLightSHA256"):
            if track[key] is not None:
                require_hex(track[key], 64, f"{track_label}.{key}")
        dynamic = require_list(track["dynamicHDRSamples"], f"{track_label}.dynamicHDRSamples")
        for sample_index, raw_sample in enumerate(dynamic):
            sample = require_mapping(raw_sample, f"{track_label}.dynamicHDRSamples[{sample_index}]")
            require_exact_keys(sample, {"sampleOrdinal", "pts", "hdr10PlusSHA256", "postDecodeSHA256"}, f"{track_label}.dynamicHDRSamples[{sample_index}]")
            require_integer(sample["sampleOrdinal"], f"{track_label}.dynamicHDRSamples[{sample_index}].sampleOrdinal")
            media_fraction(sample["pts"], f"{track_label}.dynamicHDRSamples[{sample_index}].pts")
            for key in ("hdr10PlusSHA256", "postDecodeSHA256"):
                if sample[key] is not None:
                    require_hex(sample[key], 64, f"{track_label}.dynamicHDRSamples[{sample_index}].{key}")
    return tracks


def validate_media_side_manifest(
    evidence_root: Path,
    descriptor_value: Any,
    sealed_paths: set[Path],
    fixture_id: str,
    side: str,
) -> dict[str, Any]:
    label = f"preservation {fixture_id}.{side}"
    manifest_path, _ = validate_sealed_artifact(evidence_root, descriptor_value, sealed_paths, f"{label}.manifest")
    manifest = require_mapping(load_json(manifest_path), f"{label}.manifest.document")
    require_exact_keys(
        manifest,
        {"schemaVersion", "fixtureID", "side", "enabledTrackCount", "artifacts", "semanticIdentities"},
        f"{label}.manifest.document",
    )
    if manifest["schemaVersion"] != MEDIA_SIDE_MANIFEST_SCHEMA or manifest["fixtureID"] != fixture_id or manifest["side"] != side:
        raise QualificationError(f"{label} manifest provenance mismatch")
    artifacts = require_mapping(manifest["artifacts"], f"{label}.manifest.artifacts")
    canonical_names = {
        "media": "media.mov",
        "trackObservation": "track-observation.json",
        "timingObservation": "timing-observation.json",
        "pixels": "pixels.bin",
        "pixelObservation": "pixel-observation.json",
        "attachmentObservation": "attachment-observation.json",
    }
    require_exact_keys(artifacts, set(canonical_names), f"{label}.manifest.artifacts")
    paths: dict[str, Path] = {}
    for name, canonical_name in canonical_names.items():
        path, _ = validate_sealed_artifact(evidence_root, artifacts[name], sealed_paths, f"{label}.manifest.artifacts.{name}")
        expected_path = (manifest_path.parent / side / canonical_name).resolve()
        if path != expected_path:
            raise QualificationError(f"{label} artifact is not at its canonical nested path: {name}")
        paths[name] = path
    documents: dict[str, dict[str, Any]] = {}
    for name in ("trackObservation", "timingObservation", "pixelObservation", "attachmentObservation"):
        document = require_mapping(load_json(paths[name]), f"{label}.{name}")
        if document.get("fixtureID") != fixture_id or document.get("side") != side:
            raise QualificationError(f"{label}.{name} provenance mismatch")
        documents[name] = document
    tracks = validate_media_track_observation(documents["trackObservation"], f"{label}.track")
    timing = validate_media_timing_observation(documents["timingObservation"], f"{label}.timing")
    pixels = validate_media_pixel_observation(documents["pixelObservation"], paths["pixels"], f"{label}.pixel")
    attachments = validate_media_attachment_observation(documents["attachmentObservation"], f"{label}.attachment")
    if set(timing) != set(tracks) or not set(pixels).issubset(tracks) or not set(attachments).issubset(tracks):
        raise QualificationError(f"{label} observation inventories disagree")
    if require_integer(manifest["enabledTrackCount"], f"{label}.enabledTrackCount") != documents["trackObservation"]["enabledTrackCount"]:
        raise QualificationError(f"{label} enabled-track count differs")
    semantic = require_mapping(manifest["semanticIdentities"], f"{label}.semanticIdentities")
    require_exact_keys(semantic, {"trackSHA256", "timingSHA256", "pixelSHA256", "attachmentSHA256"}, f"{label}.semanticIdentities")
    expected_semantic = {
        "trackSHA256": sha256_bytes(canonical_bytes(documents["trackObservation"])),
        "timingSHA256": sha256_bytes(canonical_bytes(documents["timingObservation"])),
        "pixelSHA256": sha256_bytes(canonical_bytes(documents["pixelObservation"])),
        "attachmentSHA256": sha256_bytes(canonical_bytes(documents["attachmentObservation"])),
    }
    if semantic != expected_semantic:
        raise QualificationError(f"{label} semantic identities differ from raw observations")
    return {
        "manifestPath": manifest_path,
        "manifest": manifest,
        "paths": paths,
        "trackObservation": documents["trackObservation"],
        "tracks": tracks,
        "timing": timing,
        "pixels": pixels,
        "attachments": attachments,
    }


def media_first_video(tracks: Mapping[int, Mapping[str, Any]], label: str) -> tuple[int, Mapping[str, Any]]:
    videos = [(ordinal, track) for ordinal, track in tracks.items() if track.get("kind") == "video"]
    if not videos:
        raise QualificationError(f"{label} has no video track")
    return videos[0]


def recompute_media_fixture(
    fixture_id: str,
    policy: str,
    coverage_values: list[Any],
    input_side: Mapping[str, Any],
    output_side: Mapping[str, Any],
) -> list[dict[str, Any]]:
    coverage = set(coverage_values)
    input_tracks = input_side["tracks"]
    output_tracks = output_side["tracks"]
    input_timing = input_side["timing"]
    output_timing = output_side["timing"]
    input_pixels = input_side["pixels"]
    output_pixels = output_side["pixels"]
    input_attachments = input_side["attachments"]
    output_attachments = output_side["attachments"]
    checks: list[dict[str, Any]] = []

    if policy == "exact_pass_through":
        normalized_input = {**input_side["trackObservation"], "side": "normalized"}
        normalized_output = {**output_side["trackObservation"], "side": "normalized"}
        if canonical_bytes(normalized_input) != canonical_bytes(normalized_output):
            raise QualificationError(f"preservation {fixture_id} track semantics differ")
        if set(input_timing) != set(output_timing) or set(input_pixels) != set(output_pixels) or set(input_attachments) != set(output_attachments):
            raise QualificationError(f"preservation {fixture_id} exact observation inventory differs")
        for ordinal in input_timing:
            if input_timing[ordinal]["timingSHA256"] != output_timing[ordinal]["timingSHA256"] or input_timing[ordinal]["encodedPayloadSHA256"] != output_timing[ordinal]["encodedPayloadSHA256"]:
                raise QualificationError(f"preservation {fixture_id} track {ordinal} timing/payload differs")
        for ordinal in input_attachments:
            if canonical_bytes(input_attachments[ordinal]) != canonical_bytes(output_attachments[ordinal]):
                raise QualificationError(f"preservation {fixture_id} track {ordinal} attachments differ")
        for ordinal in input_pixels:
            if input_pixels[ordinal]["visibleSHA256"] != output_pixels[ordinal]["visibleSHA256"]:
                raise QualificationError(f"preservation {fixture_id} track {ordinal} decoded pixels differ")
        checks.append({"id": "exact-track-timing-pixel-attachment-pass-through", "pass": True})
    elif policy in {"p010_field_normalization", "alpha_geometry"}:
        input_ordinal, _ = media_first_video(input_tracks, f"preservation {fixture_id} input")
        output_ordinal, _ = media_first_video(output_tracks, f"preservation {fixture_id} output")
        if input_ordinal not in input_pixels or output_ordinal not in output_pixels or input_ordinal not in input_attachments or output_ordinal not in output_attachments:
            raise QualificationError(f"preservation {fixture_id} lacks video evidence")
        source_pixel = input_pixels[input_ordinal]
        target_pixel = output_pixels[output_ordinal]
        source_attachment = input_attachments[input_ordinal]
        target_attachment = output_attachments[output_ordinal]
        x_scale = Fraction(target_pixel["width"], source_pixel["width"])
        y_scale = Fraction(target_pixel["height"], source_pixel["height"])
        if x_scale <= 0 or y_scale <= 0 or source_attachment["pixelAspectRatio"] != target_attachment["pixelAspectRatio"]:
            raise QualificationError(f"preservation {fixture_id} pixel geometry differs")
        for key, scale in (("width", x_scale), ("height", y_scale), ("horizontalOffset", x_scale), ("verticalOffset", y_scale)):
            if media_fraction(target_attachment["cleanAperture"][key], f"preservation {fixture_id}.output.clean.{key}") != media_fraction(source_attachment["cleanAperture"][key], f"preservation {fixture_id}.input.clean.{key}") * scale:
                raise QualificationError(f"preservation {fixture_id} clean aperture {key} differs")
        source_transform = [media_fraction(value, f"preservation {fixture_id}.input.transform") for value in source_attachment["preferredTransform"]]
        target_transform = [media_fraction(value, f"preservation {fixture_id}.output.transform") for value in target_attachment["preferredTransform"]]
        if target_transform[:4] != source_transform[:4] or target_transform[4] != source_transform[4] * x_scale or target_transform[5] != source_transform[5] * y_scale:
            raise QualificationError(f"preservation {fixture_id} transform differs")
        checks.append({"id": "exact-rational-geometry-transform", "pass": True})
        if target_pixel["visibleSHA256"] != target_pixel["repeatVisibleSHA256"]:
            raise QualificationError(f"preservation {fixture_id} repeat output pixels differ")
        checks.append({"id": "repeat-output-visible-pixel-identity", "pass": True})
    else:
        raise QualificationError(f"preservation {fixture_id} policy is unsupported")

    if "p010_hdr_static_dynamic" in coverage:
        input_ordinal, _ = media_first_video(input_tracks, f"preservation {fixture_id} input")
        output_ordinal, _ = media_first_video(output_tracks, f"preservation {fixture_id} output")
        for side_label, pixel in (("input", input_pixels[input_ordinal]), ("output", output_pixels[output_ordinal])):
            if pixel["pixelFormat"] not in {"x420", "xf20"} or pixel["bitDepth"] != 10 or pixel["lowPaddingBitViolationCount"] != 0 or pixel["uniqueSignalCodeCount"] <= 256:
                raise QualificationError(f"preservation {fixture_id} {side_label} does not prove exact P010 precision")
        source = input_attachments[input_ordinal]
        target = output_attachments[output_ordinal]
        if source["colorPrimaries"] != target["colorPrimaries"] or source["colorPrimaries"] != "ITU_R_2020" or source["transferFunction"] != target["transferFunction"] or source["transferFunction"] != "SMPTE_ST_2084_PQ" or source["yCbCrMatrix"] != target["yCbCrMatrix"] or source["yCbCrMatrix"] != "ITU_R_2020":
            raise QualificationError(f"preservation {fixture_id} HDR signal metadata differs")
        for key in ("masteringDisplaySHA256", "contentLightSHA256"):
            if source[key] is None or source[key] != target[key]:
                raise QualificationError(f"preservation {fixture_id} static HDR metadata differs: {key}")
        source_dynamic = source["dynamicHDRSamples"]
        target_dynamic = target["dynamicHDRSamples"]
        if not source_dynamic or len(target_dynamic) != 2 * len(source_dynamic):
            raise QualificationError(f"preservation {fixture_id} dynamic HDR replication count differs")
        for index, sample in enumerate(source_dynamic):
            for duplicate in target_dynamic[2 * index : 2 * index + 2]:
                if duplicate["hdr10PlusSHA256"] != sample["hdr10PlusSHA256"] or duplicate["postDecodeSHA256"] != sample["postDecodeSHA256"]:
                    raise QualificationError(f"preservation {fixture_id} dynamic HDR payload differs")
        checks.append({"id": "p010-static-and-frame-bound-dynamic-hdr-identity", "pass": True})

    if "interlaced_field_order_cadence" in coverage:
        input_ordinal, _ = media_first_video(input_tracks, f"preservation {fixture_id} input")
        output_ordinal, _ = media_first_video(output_tracks, f"preservation {fixture_id} output")
        source = input_attachments[input_ordinal]
        target = output_attachments[output_ordinal]
        if (source["fieldCount"], source["fieldDetail"], source["cadence"]) != (2, "temporal_top_first", "interlaced_tff_2_fields_per_sample") or (target["fieldCount"], target["fieldDetail"], target["cadence"]) != (1, "progressive", "progressive_double_rate"):
            raise QualificationError(f"preservation {fixture_id} field order/cadence differs")
        source_samples = input_timing[input_ordinal]["samples"]
        target_samples = output_timing[output_ordinal]["samples"]
        if len(target_samples) != 2 * len(source_samples):
            raise QualificationError(f"preservation {fixture_id} double-rate sample count differs")
        for index, source_sample in enumerate(source_samples):
            duration = media_fraction(source_sample["duration"], f"preservation {fixture_id}.source.duration")
            pts = media_fraction(source_sample["pts"], f"preservation {fixture_id}.source.pts")
            first, second = target_samples[2 * index : 2 * index + 2]
            if media_fraction(first["pts"], f"preservation {fixture_id}.first.pts") != pts or media_fraction(second["pts"], f"preservation {fixture_id}.second.pts") != pts + duration / 2 or media_fraction(first["duration"], f"preservation {fixture_id}.first.duration") != duration / 2 or media_fraction(second["duration"], f"preservation {fixture_id}.second.duration") != duration / 2:
                raise QualificationError(f"preservation {fixture_id} field timing differs")
        checks.append({"id": "tff-field-order-and-double-rate-cadence", "pass": True})

    if "straight_alpha" in coverage or "premultiplied_alpha" in coverage:
        expected = "straight" if "straight_alpha" in coverage else "premultiplied"
        input_ordinal, _ = media_first_video(input_tracks, f"preservation {fixture_id} input")
        output_ordinal, _ = media_first_video(output_tracks, f"preservation {fixture_id} output")
        pixel = output_pixels[output_ordinal]
        if input_attachments[input_ordinal]["alphaAssociation"] != expected or output_attachments[output_ordinal]["alphaAssociation"] != expected or pixel["preEncodeAlphaSHA256"] is None or pixel["preEncodeAlphaSHA256"] != pixel["decodedAlphaSHA256"] or pixel["preEncodeAlphaSHA256"] != pixel["alphaSHA256"]:
            raise QualificationError(f"preservation {fixture_id} {expected} alpha bytes/association differ")
        checks.append({"id": f"exact-prores4444-{expected}-alpha", "pass": True})

    input_kinds = [track["kind"] for track in input_tracks.values()]
    output_kinds = [track["kind"] for track in output_tracks.values()]
    for coverage_id, kind in (("subtitles", "subtitle"), ("captions", "caption"), ("chapters", "chapter"), ("timecode_tracks", "timecode"), ("timed_metadata", "timed_metadata"), ("auxiliary_tracks", "auxiliary")):
        if coverage_id in coverage:
            if kind not in input_kinds or kind not in output_kinds:
                raise QualificationError(f"preservation {fixture_id} lacks {kind} track")
            checks.append({"id": f"{coverage_id}-present-and-accounted", "pass": True})
    if "multiple_enabled_video_tracks" in coverage:
        if sum(track["kind"] == "video" and track["enabled"] for track in input_tracks.values()) < 2 or sum(track["kind"] == "video" and track["enabled"] for track in output_tracks.values()) < 2:
            raise QualificationError(f"preservation {fixture_id} lacks multiple enabled video tracks")
        checks.append({"id": "multiple-enabled-video-tracks-accounted", "pass": True})
    if "alternate_audio_tracks" in coverage:
        audio = {ordinal for ordinal, track in input_tracks.items() if track["kind"] == "audio"}
        groups = input_side["trackObservation"]["groups"]
        if len(audio) < 2 or not any(set(group.get("memberOrdinals", [])) <= audio and len(group.get("memberOrdinals", [])) >= 2 for group in groups if isinstance(group, dict)):
            raise QualificationError(f"preservation {fixture_id} lacks alternate-audio selection group")
        checks.append({"id": "alternate-audio-selection-group-accounted", "pass": True})
    return checks


def preservation_binding_path(
    evidence_root: Path,
    entry: Mapping[str, Any],
    sealed_paths: set[Path],
    pointer: str,
) -> Path:
    bindings = require_list(entry["identityBindings"], "preservation.identityBindings")
    matches = [binding for binding in bindings if isinstance(binding, dict) and binding.get("jsonPointer") == pointer]
    if len(matches) != 1:
        raise QualificationError(f"preservation binding is absent or repeated: {pointer}")
    path, _ = validate_artifact(evidence_root, matches[0], f"preservation binding {pointer}", allowed_extra_keys={"jsonPointer"})
    if path not in sealed_paths:
        raise QualificationError(f"preservation binding is not sealed: {pointer}")
    return path


def validate_preservation(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "media_preservation"
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    require_exact_keys(
        report,
        {
            "schemaVersion", "contractSHA256", "candidate", "releaseEligible", "identities",
            "fixtures", "accountedEnabledTrackCount", "mediaPreservationGatePass",
        },
        "preservation report",
    )
    report_identities = require_mapping(report["identities"], "preservation.identities")
    require_exact_keys(
        report_identities,
        {
            "laneContractSHA256", "captureSourceSHA256", "fixtureSourceSHA256",
            "evaluatorSHA256", "runnerSHA256", "captureSHA256",
        },
        "preservation.identities",
    )
    for key, value in report_identities.items():
        require_hex(value, 64, f"preservation.identities.{key}")

    lane_contract_path = preservation_binding_path(
        evidence_root, entry, sealed_paths, "/identities/laneContractSHA256"
    )
    lane_contract = require_mapping(load_json(lane_contract_path), "preservation lane contract")
    if lane_contract.get("schemaVersion") != MEDIA_LANE_CONTRACT_SCHEMA:
        raise QualificationError("preservation lane contract schema mismatch")
    if sha256(lane_contract_path) != report_identities["laneContractSHA256"]:
        raise QualificationError("preservation lane contract identity mismatch")
    lane_capture = require_mapping(lane_contract.get("capture"), "preservation lane contract.capture")
    for identity_key in (
        "captureSourceSHA256", "fixtureSourceSHA256", "evaluatorSHA256", "runnerSHA256"
    ):
        if require_hex(lane_capture.get(identity_key), 64, f"preservation lane contract.capture.{identity_key}") != report_identities[identity_key]:
            raise QualificationError(f"preservation lane tool identity mismatch: {identity_key}")
        tool_path = preservation_binding_path(
            evidence_root, entry, sealed_paths, f"/identities/{identity_key}"
        )
        if sha256(tool_path) != report_identities[identity_key]:
            raise QualificationError(f"preservation bound tool differs: {identity_key}")

    lane_fixtures = require_list(lane_contract.get("fixtures"), "preservation lane contract.fixtures")
    expected_fixtures: dict[str, dict[str, Any]] = {}
    for index, raw_lane_fixture in enumerate(lane_fixtures):
        lane_fixture = require_mapping(raw_lane_fixture, f"preservation lane contract.fixtures[{index}]")
        require_exact_keys(lane_fixture, {"id", "coverage", "policy"}, f"preservation lane contract.fixtures[{index}]")
        identifier = require_string(lane_fixture["id"], f"preservation lane contract.fixtures[{index}].id")
        if identifier in expected_fixtures:
            raise QualificationError(f"preservation lane contract repeats fixture: {identifier}")
        coverage = require_list(lane_fixture["coverage"], f"preservation lane contract {identifier}.coverage")
        if not coverage or len(coverage) != len(set(coverage)):
            raise QualificationError(f"preservation lane contract coverage is empty/repeated: {identifier}")
        policy = require_string(lane_fixture["policy"], f"preservation lane contract {identifier}.policy")
        if policy not in {"p010_field_normalization", "alpha_geometry", "exact_pass_through"}:
            raise QualificationError(f"preservation lane contract policy is invalid: {identifier}")
        expected_fixtures[identifier] = lane_fixture

    capture_path = preservation_binding_path(
        evidence_root, entry, sealed_paths, "/identities/captureSHA256"
    )
    capture = require_mapping(load_json(capture_path), "preservation raw capture")
    require_exact_keys(
        capture,
        {
            "schemaVersion", "suiteID", "laneContractSHA256", "releaseContractSHA256",
            "candidate", "identities", "buildConfiguration", "fixtures",
        },
        "preservation raw capture",
    )
    if capture["schemaVersion"] != "mirmir-ash-v4-media-preservation-capture-v1" or capture["suiteID"] != lane_contract.get("suiteID"):
        raise QualificationError("preservation raw capture schema/suite mismatch")
    if capture["laneContractSHA256"] != report_identities["laneContractSHA256"] or capture["releaseContractSHA256"] != contract_sha:
        raise QualificationError("preservation raw capture contract identities differ")
    if capture["candidate"] != candidate or capture["buildConfiguration"] != "Release":
        raise QualificationError("preservation raw capture belongs to another candidate/configuration")
    expected_capture_identities = {
        "captureSourceSHA256": report_identities["captureSourceSHA256"],
        "fixtureSourceSHA256": report_identities["fixtureSourceSHA256"],
        "evaluatorSHA256": report_identities["evaluatorSHA256"],
        "runnerSHA256": report_identities["runnerSHA256"],
        "sourceCommit": candidate["sourceCommit"],
        "sourceTreeIdentitySHA256": candidate["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": candidate["runtimeManifestSHA256"],
        "runtimeManifestFileSHA256": candidate["runtimeManifestFileSHA256"],
        "runtimeArtifactSetSHA256": candidate["runtimeArtifactSetSHA256"],
        "runtimeSourceRevision": candidate["runtimeSourceRevision"],
        "releaseConfigurationSHA256": candidate["releaseConfigurationSHA256"],
    }
    if capture["identities"] != expected_capture_identities:
        raise QualificationError("preservation raw capture candidate/tool identities differ")
    raw_fixtures_list = require_list(capture["fixtures"], "preservation raw capture.fixtures")
    raw_fixtures: dict[str, dict[str, Any]] = {}
    for index, raw_value in enumerate(raw_fixtures_list):
        raw_fixture = require_mapping(raw_value, f"preservation raw capture.fixtures[{index}]")
        require_exact_keys(
            raw_fixture,
            {"id", "coverage", "policy", "enabledInputTrackCount", "accountedOutputTrackCount", "production", "input", "output"},
            f"preservation raw capture.fixtures[{index}]",
        )
        identifier = require_string(raw_fixture["id"], f"preservation raw capture.fixtures[{index}].id")
        if identifier in raw_fixtures:
            raise QualificationError(f"preservation raw capture repeats fixture: {identifier}")
        raw_fixtures[identifier] = raw_fixture
    if set(raw_fixtures) != set(expected_fixtures):
        raise QualificationError("preservation raw capture fixture set differs from lane contract")

    fixtures = require_list(report.get("fixtures"), "preservation.fixtures")
    required = set(contract["mediaPreservationCoverage"])
    covered: set[str] = set()
    identities: set[str] = set()
    accounted_tracks = 0
    for index, item in enumerate(fixtures):
        fixture = require_mapping(item, f"preservation.fixtures[{index}]")
        require_exact_keys(
            fixture,
            {
                "id",
                "coverage",
                "enabledInputTrackCount",
                "accountedOutputTrackCount",
                "unconsentedDropCount",
                "silentToneMapCount",
                "precisionReductionCount",
                "alphaLossCount",
                "geometryMismatchCount",
                "metadataMismatchCount",
                "exactSemanticVerifierPass",
                "inputManifestArtifact",
                "outputManifestArtifact",
                "semanticVerifierArtifact",
            },
            f"preservation.fixtures[{index}]",
        )
        identifier = require_string(fixture["id"], f"preservation fixture[{index}].id")
        if identifier in identities:
            raise QualificationError(f"preservation repeats fixture: {identifier}")
        identities.add(identifier)
        if identifier not in expected_fixtures:
            raise QualificationError(f"preservation fixture is not lane-locked: {identifier}")
        lane_fixture = expected_fixtures[identifier]
        raw_fixture = raw_fixtures[identifier]
        coverage_values = require_list(fixture["coverage"], f"preservation {identifier}.coverage")
        if coverage_values != lane_fixture["coverage"] or raw_fixture["coverage"] != lane_fixture["coverage"] or raw_fixture["policy"] != lane_fixture["policy"]:
            raise QualificationError(f"preservation fixture changed locked coverage/policy: {identifier}")
        coverage = set(coverage_values)
        if not coverage or not coverage.issubset(required):
            raise QualificationError(f"preservation fixture has unexpected coverage: {identifier}")
        covered.update(coverage)
        inputs = require_integer(fixture["enabledInputTrackCount"], f"preservation {identifier}.enabled tracks", 1)
        outputs = require_integer(fixture["accountedOutputTrackCount"], f"preservation {identifier}.accounted tracks", 1)
        if inputs != outputs:
            raise QualificationError(f"preservation does not account for every enabled track: {identifier}")
        if raw_fixture["enabledInputTrackCount"] != inputs or raw_fixture["accountedOutputTrackCount"] != outputs:
            raise QualificationError(f"preservation raw/report track counts differ: {identifier}")
        accounted_tracks += inputs
        for key in (
            "unconsentedDropCount",
            "silentToneMapCount",
            "precisionReductionCount",
            "alphaLossCount",
            "geometryMismatchCount",
            "metadataMismatchCount",
        ):
            if require_integer(fixture[key], f"preservation {identifier}.{key}") != 0:
                raise QualificationError(f"preservation violation {key}: {identifier}")
        require_bool(fixture["exactSemanticVerifierPass"], f"preservation {identifier}.verifier", True)

        production = require_mapping(raw_fixture["production"], f"preservation raw {identifier}.production")
        require_exact_keys(
            production,
            {"releaseQualifiedRuntimeLoaded", "runtimeManifestSHA256", "trustRootConfigured", "requestedRouteExecutedWithoutFallback", "migrationConformant", "repeatedOutputIdentityPass"},
            f"preservation raw {identifier}.production",
        )
        for key in ("releaseQualifiedRuntimeLoaded", "trustRootConfigured", "requestedRouteExecutedWithoutFallback", "migrationConformant", "repeatedOutputIdentityPass"):
            require_bool(production[key], f"preservation raw {identifier}.production.{key}", True)
        if production["runtimeManifestSHA256"] != candidate["runtimeManifestSHA256"]:
            raise QualificationError(f"preservation raw fixture used another runtime: {identifier}")

        input_side = validate_media_side_manifest(
            evidence_root, fixture["inputManifestArtifact"], sealed_paths, identifier, "input"
        )
        output_side = validate_media_side_manifest(
            evidence_root, fixture["outputManifestArtifact"], sealed_paths, identifier, "output"
        )
        if input_side["manifest"]["enabledTrackCount"] != inputs or output_side["manifest"]["enabledTrackCount"] != outputs:
            raise QualificationError(f"preservation nested manifest track count differs: {identifier}")

        capture_root = capture_path.parent
        for side_name, side_value in (("input", input_side), ("output", output_side)):
            raw_side = require_mapping(raw_fixture[side_name], f"preservation raw {identifier}.{side_name}")
            require_exact_keys(raw_side, {"media", "trackObservation", "timingObservation", "pixels", "pixelObservation", "attachmentObservation"}, f"preservation raw {identifier}.{side_name}")
            for artifact_name, raw_descriptor in raw_side.items():
                raw_path, raw_identity = validate_artifact(capture_root, raw_descriptor, f"preservation raw {identifier}.{side_name}.{artifact_name}")
                if raw_path not in sealed_paths:
                    raise QualificationError(f"preservation raw artifact is not sealed: {identifier}.{side_name}.{artifact_name}")
                copied_descriptor = side_value["manifest"]["artifacts"][artifact_name]
                if raw_identity != copied_descriptor["sha256"] or raw_path.stat().st_size != copied_descriptor["byteCount"]:
                    raise QualificationError(f"preservation raw/copied artifact identity differs: {identifier}.{side_name}.{artifact_name}")

        recomputed_checks = recompute_media_fixture(
            identifier, lane_fixture["policy"], coverage_values, input_side, output_side
        )
        verifier_path, _ = validate_sealed_artifact(
            evidence_root, fixture["semanticVerifierArtifact"], sealed_paths, f"preservation {identifier}.semanticVerifierArtifact"
        )
        if verifier_path != (input_side["manifestPath"].parent / "semantic-verifier.json").resolve():
            raise QualificationError(f"preservation semantic verifier is not at its canonical nested path: {identifier}")
        verifier = require_mapping(load_json(verifier_path), f"preservation {identifier}.semanticVerifier")
        require_exact_keys(
            verifier,
            {"schemaVersion", "fixtureID", "policy", "coverage", "candidateRuntimeManifestSHA256", "inputManifestSHA256", "outputManifestSHA256", "checks", "violationCounts", "exactSemanticVerifierPass"},
            f"preservation {identifier}.semanticVerifier",
        )
        if verifier["schemaVersion"] != MEDIA_SEMANTIC_VERIFIER_SCHEMA or verifier["fixtureID"] != identifier or verifier["policy"] != lane_fixture["policy"] or verifier["coverage"] != coverage_values:
            raise QualificationError(f"preservation semantic verifier provenance differs: {identifier}")
        if verifier["candidateRuntimeManifestSHA256"] != candidate["runtimeManifestSHA256"] or verifier["inputManifestSHA256"] != sha256(input_side["manifestPath"]) or verifier["outputManifestSHA256"] != sha256(output_side["manifestPath"]):
            raise QualificationError(f"preservation semantic verifier bindings differ: {identifier}")
        if verifier["checks"] != recomputed_checks:
            raise QualificationError(f"preservation semantic verifier checks differ from independent recomputation: {identifier}")
        violations = require_mapping(verifier["violationCounts"], f"preservation {identifier}.violationCounts")
        violation_keys = {"unconsentedDropCount", "silentToneMapCount", "precisionReductionCount", "alphaLossCount", "geometryMismatchCount", "metadataMismatchCount"}
        require_exact_keys(violations, violation_keys, f"preservation {identifier}.violationCounts")
        for key in violation_keys:
            if require_integer(violations[key], f"preservation {identifier}.violationCounts.{key}") != 0 or fixture[key] != violations[key]:
                raise QualificationError(f"preservation nested violation differs: {identifier}.{key}")
        require_bool(verifier["exactSemanticVerifierPass"], f"preservation {identifier}.semanticVerifier.pass", True)

    if identities != set(expected_fixtures):
        raise QualificationError(f"media preservation fixture mismatch; missing={sorted(set(expected_fixtures)-identities)}")
    if covered != required:
        raise QualificationError(f"media preservation coverage mismatch; missing={sorted(required-covered)}")
    if require_integer(report["accountedEnabledTrackCount"], "preservation.accountedEnabledTrackCount", 1) != accounted_tracks:
        raise QualificationError("preservation total accounted-track count differs")
    require_bool(report.get("mediaPreservationGatePass"), "preservation.mediaPreservationGatePass", True)
    return {"fixtureCount": len(fixtures), "accountedTrackCount": accounted_tracks, "coverage": sorted(covered)}


def recovery_binding_path(
    evidence_root: Path,
    entry: Mapping[str, Any],
    sealed_paths: set[Path],
    pointer: str,
) -> Path:
    bindings = require_list(entry["identityBindings"], "recovery.identityBindings")
    matches = [
        binding
        for binding in bindings
        if isinstance(binding, dict) and binding.get("jsonPointer") == pointer
    ]
    if len(matches) != 1:
        raise QualificationError(f"recovery binding is absent or repeated: {pointer}")
    path, _ = validate_artifact(
        evidence_root,
        matches[0],
        f"recovery binding {pointer}",
        allowed_extra_keys={"jsonPointer"},
    )
    if path not in sealed_paths:
        raise QualificationError(f"recovery binding is not sealed: {pointer}")
    return path


def validate_recovery_semantic(path: Path, label: str) -> dict[str, Any]:
    semantic = require_mapping(load_json(path), label)
    require_exact_keys(
        semantic,
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
    if semantic["schemaVersion"] != RECOVERY_SEMANTIC_SCHEMA:
        raise QualificationError(f"{label} schema differs")
    require_bool(
        semantic["allRequiredChecksPassed"],
        f"{label}.allRequiredChecksPassed",
        True,
    )
    for key in (
        "decodedVisiblePixelSHA256",
        "presentationTimelineSHA256",
        "trackGraphSHA256",
    ):
        require_hex(semantic[key], 64, f"{label}.{key}")
    require_integer(semantic["sampleCount"], f"{label}.sampleCount", 1)
    duration = require_mapping(semantic["duration"], f"{label}.duration")
    require_exact_keys(duration, {"value", "timescale"}, f"{label}.duration")
    if isinstance(duration["value"], bool) or not isinstance(duration["value"], int):
        raise QualificationError(f"{label}.duration.value must be an integer")
    require_integer(duration["timescale"], f"{label}.duration.timescale", 1)
    return semantic


def validate_recovery_transcript(
    path: Path,
    expected: Mapping[str, Any],
    label: str,
) -> None:
    transcript = require_mapping(load_json(path), label)
    require_exact_keys(
        transcript,
        {
            "coverageID",
            "events",
            "faultObserved",
            "id",
            "injectionPoint",
            "reopenedDurableState",
            "schemaVersion",
            "terminalDisposition",
        },
        label,
    )
    if transcript["schemaVersion"] != RECOVERY_TRANSCRIPT_SCHEMA:
        raise QualificationError(f"{label} schema differs")
    for key in ("id", "coverageID", "injectionPoint"):
        if transcript[key] != expected[key]:
            raise QualificationError(f"{label}.{key} differs")
    require_bool(transcript["faultObserved"], f"{label}.faultObserved", True)
    require_bool(
        transcript["reopenedDurableState"],
        f"{label}.reopenedDurableState",
        True,
    )
    expected_terminal = (
        "completed"
        if expected["outcome"] == "identical_resumed_output"
        else "contained"
    )
    if transcript["terminalDisposition"] != expected_terminal:
        raise QualificationError(f"{label}.terminalDisposition differs")
    events = require_list(transcript["events"], f"{label}.events")
    expected_operations = [
        "prepare_durable_state",
        "inject_fault",
        "reopen_durable_state",
    ]
    if len(events) != len(expected_operations):
        raise QualificationError(f"{label} must contain the exact fault/reopen event sequence")
    for index, expected_operation in enumerate(expected_operations):
        event = require_mapping(events[index], f"{label}.events[{index}]")
        require_exact_keys(
            event,
            {"durableStateSHA256", "operation", "sequence"},
            f"{label}.events[{index}]",
        )
        if event["sequence"] != index or event["operation"] != expected_operation:
            raise QualificationError(f"{label} event sequence differs")
        require_hex(
            event["durableStateSHA256"],
            64,
            f"{label}.events[{index}].durableStateSHA256",
        )


def validate_recovery(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "recovery"
    validate_common_report(
        report,
        candidate,
        contract["evidenceSchemas"][label],
        contract_sha,
        label,
    )
    require_exact_keys(
        report,
        {
            "candidate",
            "capture",
            "contractSHA256",
            "identities",
            "recoveryGatePass",
            "releaseEligible",
            "scenarios",
            "schemaVersion",
        },
        "recovery report",
    )

    identities = require_mapping(report["identities"], "recovery.identities")
    require_exact_keys(
        identities,
        {"captureSourceSHA256", "evaluatorSHA256", "runnerSHA256"},
        "recovery.identities",
    )
    for key, value in identities.items():
        require_hex(value, 64, f"recovery.identities.{key}")

    suite_manifest_path, _ = validate_artifact(
        evidence_root,
        entry["sealedManifest"],
        "recovery sealed manifest",
    )
    suite_manifest = require_mapping(
        load_json(suite_manifest_path), "recovery sealed manifest document"
    )
    require_exact_keys(
        suite_manifest,
        {"artifactSetSHA256", "artifacts", "schemaVersion"},
        "recovery sealed manifest document",
    )
    if suite_manifest["schemaVersion"] != RECOVERY_SUITE_MANIFEST_SCHEMA:
        raise QualificationError("recovery sealed manifest schema differs")
    suite_artifacts = require_list(
        suite_manifest["artifacts"], "recovery sealed manifest artifacts"
    )
    suite_paths = [
        require_string(item.get("path") if isinstance(item, dict) else None, f"recovery sealed manifest artifacts[{index}].path")
        for index, item in enumerate(suite_artifacts)
    ]
    if suite_paths != sorted(suite_paths):
        raise QualificationError("recovery sealed manifest artifacts are not sorted")
    if require_hex(
        suite_manifest["artifactSetSHA256"],
        64,
        "recovery sealed manifest artifactSetSHA256",
    ) != recovery_artifact_set_sha(suite_artifacts):
        raise QualificationError("recovery sealed manifest artifact set differs")

    for pointer in (
        "/contractSHA256",
        "/candidate/runtimeManifestFileSHA256",
        "/candidate/releaseConfigurationSHA256",
    ):
        recovery_binding_path(evidence_root, entry, sealed_paths, pointer)
    lane_contract_path = recovery_binding_path(
        evidence_root, entry, sealed_paths, "/contractSHA256"
    )
    lane_contract = require_mapping(
        load_json(lane_contract_path), "recovery lane contract"
    )
    require_exact_keys(
        lane_contract,
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
        "recovery lane contract",
    )
    if lane_contract["schemaVersion"] != RECOVERY_LANE_CONTRACT_SCHEMA:
        raise QualificationError("recovery lane contract schema differs")
    if lane_contract["hashAlgorithm"] != "sha256":
        raise QualificationError("recovery lane contract hash algorithm differs")
    if lane_contract["buildConfiguration"] != "Release":
        raise QualificationError("recovery lane contract is not Release")
    require_string(lane_contract["suiteID"], "recovery lane contract.suiteID")
    expected_artifact_schemas = {
        "capture": RECOVERY_CAPTURE_SCHEMA,
        "captureManifest": RECOVERY_CAPTURE_MANIFEST_SCHEMA,
        "report": contract["evidenceSchemas"][label],
        "scenarioEvidence": RECOVERY_SCENARIO_SCHEMA,
        "semanticManifest": RECOVERY_SEMANTIC_SCHEMA,
        "suiteManifest": RECOVERY_SUITE_MANIFEST_SCHEMA,
        "transcript": RECOVERY_TRANSCRIPT_SCHEMA,
    }
    artifact_schemas = require_mapping(
        lane_contract["artifactSchemas"], "recovery lane contract.artifactSchemas"
    )
    require_exact_keys(
        artifact_schemas,
        set(expected_artifact_schemas),
        "recovery lane contract.artifactSchemas",
    )
    if artifact_schemas != expected_artifact_schemas:
        raise QualificationError("recovery lane contract artifact schemas differ")
    semantic_requirements = require_mapping(
        lane_contract["semanticVerification"],
        "recovery lane contract.semanticVerification",
    )
    require_exact_keys(
        semantic_requirements,
        {
            "requireByteIdentity",
            "requireDecodedVisiblePixelIdentity",
            "requireExactPresentationTimeline",
            "requireTrackGraphIdentity",
        },
        "recovery lane contract.semanticVerification",
    )
    for key, value in semantic_requirements.items():
        require_bool(value, f"recovery lane contract.semanticVerification.{key}", True)

    required_coverage = require_list(
        contract["recoveryCoverage"], "release contract.recoveryCoverage"
    )
    lane_scenarios = require_list(
        lane_contract["scenarios"], "recovery lane contract.scenarios"
    )
    if len(lane_scenarios) != len(required_coverage):
        raise QualificationError("recovery lane contract scenario count differs")
    expected_scenarios: list[dict[str, Any]] = []
    scenario_ids: set[str] = set()
    lane_coverage: list[str] = []
    for index, item in enumerate(lane_scenarios):
        scenario = require_mapping(
            item, f"recovery lane contract.scenarios[{index}]"
        )
        require_exact_keys(
            scenario,
            {"containedFailureCode", "coverageID", "id", "injectionPoint", "outcome"},
            f"recovery lane contract.scenarios[{index}]",
        )
        identifier = require_string(
            scenario["id"], f"recovery lane contract.scenarios[{index}].id"
        )
        if (
            identifier in scenario_ids
            or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in identifier)
        ):
            raise QualificationError(f"recovery lane scenario identifier is unsafe/repeated: {identifier}")
        scenario_ids.add(identifier)
        coverage_id = require_string(
            scenario["coverageID"],
            f"recovery lane contract.scenarios[{index}].coverageID",
        )
        lane_coverage.append(coverage_id)
        require_string(
            scenario["injectionPoint"],
            f"recovery lane contract.scenarios[{index}].injectionPoint",
        )
        outcome = scenario["outcome"]
        if outcome == "identical_resumed_output":
            if scenario["containedFailureCode"] is not None:
                raise QualificationError(
                    f"recovery identical scenario has a failure code: {identifier}"
                )
        elif outcome == "explicit_contained_failure":
            require_string(
                scenario["containedFailureCode"],
                f"recovery lane contract.scenarios[{index}].containedFailureCode",
            )
        else:
            raise QualificationError(f"recovery scenario has unsupported outcome: {identifier}")
        expected_scenarios.append(scenario)
    if lane_coverage != required_coverage or len(set(required_coverage)) != len(required_coverage):
        raise QualificationError("recovery lane contract coverage/order differs")

    lane_capture = require_mapping(
        lane_contract["capture"], "recovery lane contract.capture"
    )
    require_exact_keys(
        lane_capture,
        {"captureSourceSHA256", "evaluatorSourceSHA256", "runnerSourceSHA256"},
        "recovery lane contract.capture",
    )
    tool_fields = (
        ("captureSourceSHA256", "captureSourceSHA256"),
        ("evaluatorSourceSHA256", "evaluatorSHA256"),
        ("runnerSourceSHA256", "runnerSHA256"),
    )
    for lane_key, report_key in tool_fields:
        lane_identity = require_hex(
            lane_capture[lane_key], 64, f"recovery lane contract.capture.{lane_key}"
        )
        if lane_identity != identities[report_key]:
            raise QualificationError(f"recovery lane tool identity differs: {report_key}")
        tool_path = recovery_binding_path(
            evidence_root,
            entry,
            sealed_paths,
            f"/identities/{report_key}",
        )
        if sha256(tool_path) != lane_identity:
            raise QualificationError(f"recovery bound tool differs: {report_key}")

    capture_summary = require_mapping(report["capture"], "recovery.capture")
    require_exact_keys(
        capture_summary,
        {
            "artifactManifestSHA256",
            "artifactSetSHA256",
            "buildConfiguration",
            "sourceCommit",
            "sourceTreeSHA256",
        },
        "recovery.capture",
    )
    for key in ("artifactManifestSHA256", "artifactSetSHA256", "sourceTreeSHA256"):
        require_hex(capture_summary[key], 64, f"recovery.capture.{key}")
    require_hex(capture_summary["sourceCommit"], 40, "recovery.capture.sourceCommit")
    if (
        capture_summary["buildConfiguration"] != "Release"
        or capture_summary["sourceCommit"] != candidate["sourceCommit"]
        or capture_summary["sourceTreeSHA256"] != candidate["sourceTreeIdentitySHA256"]
    ):
        raise QualificationError("recovery capture summary belongs to another candidate/configuration")

    capture_manifest_path = recovery_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/capture/artifactManifestSHA256",
    )
    if capture_manifest_path.name != "artifact-manifest.json":
        raise QualificationError("recovery capture manifest is not at its canonical path")
    capture_root = capture_manifest_path.parent.resolve()
    capture_manifest = require_mapping(
        load_json(capture_manifest_path), "recovery capture artifact manifest"
    )
    require_exact_keys(
        capture_manifest,
        {"artifactSetSHA256", "artifacts", "schemaVersion"},
        "recovery capture artifact manifest",
    )
    if capture_manifest["schemaVersion"] != RECOVERY_CAPTURE_MANIFEST_SCHEMA:
        raise QualificationError("recovery capture manifest schema differs")
    raw_descriptors = require_list(
        capture_manifest["artifacts"], "recovery capture artifact manifest.artifacts"
    )
    if not raw_descriptors:
        raise QualificationError("recovery capture artifact manifest is empty")
    captured: dict[Path, dict[str, Any]] = {}
    descriptor_paths: list[str] = []
    for index, item in enumerate(raw_descriptors):
        descriptor_value = require_mapping(
            item, f"recovery capture artifact manifest.artifacts[{index}]"
        )
        path, _ = validate_artifact(
            evidence_root,
            descriptor_value,
            f"recovery capture artifact manifest.artifacts[{index}]",
        )
        if path == capture_root or capture_root not in path.parents:
            raise QualificationError("recovery capture artifact escapes capture root")
        if path == capture_manifest_path or path not in sealed_paths:
            raise QualificationError("recovery capture artifact is unsealed or self-referential")
        if descriptor_value["byteCount"] < 1:
            raise QualificationError("recovery capture artifact must be nonempty")
        if path in captured:
            raise QualificationError("recovery capture manifest repeats an artifact")
        captured[path] = descriptor_value
        descriptor_paths.append(descriptor_value["path"])
    if descriptor_paths != sorted(descriptor_paths):
        raise QualificationError("recovery capture artifacts are not sorted")
    actual_capture_files = {
        path.resolve()
        for path in capture_root.rglob("*")
        if path.is_file() and path.resolve() != capture_manifest_path
    }
    if set(captured) != actual_capture_files:
        raise QualificationError("recovery capture file set differs from its manifest")
    capture_artifact_set = recovery_artifact_set_sha(raw_descriptors)
    if require_hex(
        capture_manifest["artifactSetSHA256"],
        64,
        "recovery capture artifact manifest.artifactSetSHA256",
    ) != capture_artifact_set:
        raise QualificationError("recovery capture artifact set differs")
    if (
        capture_summary["artifactManifestSHA256"] != sha256(capture_manifest_path)
        or capture_summary["artifactSetSHA256"] != capture_artifact_set
    ):
        raise QualificationError("recovery report capture manifest identity differs")

    def capture_artifact(
        value: Any,
        artifact_label: str,
        canonical_path: Path,
    ) -> tuple[Path, str]:
        path, artifact_identity = validate_sealed_artifact(
            evidence_root, value, sealed_paths, artifact_label
        )
        if path != canonical_path.resolve() or path not in captured:
            raise QualificationError(f"{artifact_label} is not at its canonical captured path")
        if require_mapping(value, artifact_label) != captured[path]:
            raise QualificationError(f"{artifact_label} differs from the capture manifest")
        return path, artifact_identity

    capture_path = (capture_root / "capture.json").resolve()
    if capture_path not in captured:
        raise QualificationError("recovery capture.json is absent from the capture manifest")
    capture_document = require_mapping(load_json(capture_path), "recovery raw capture")
    require_exact_keys(
        capture_document,
        {
            "buildConfiguration",
            "captureSourceSHA256",
            "contractSHA256",
            "scenarios",
            "schemaVersion",
            "sourceCommit",
            "sourceTreeSHA256",
        },
        "recovery raw capture",
    )
    if (
        capture_document["schemaVersion"] != RECOVERY_CAPTURE_SCHEMA
        or capture_document["contractSHA256"] != contract_sha
        or capture_document["captureSourceSHA256"] != identities["captureSourceSHA256"]
        or capture_document["buildConfiguration"] != "Release"
        or capture_document["sourceCommit"] != candidate["sourceCommit"]
        or capture_document["sourceTreeSHA256"] != candidate["sourceTreeIdentitySHA256"]
    ):
        raise QualificationError("recovery raw capture provenance differs")

    environment_path = (capture_root / "environment.json").resolve()
    execution_log_path = (capture_root / "xcodebuild.log").resolve()
    if environment_path not in captured or execution_log_path not in captured:
        raise QualificationError("recovery capture environment or execution log is missing")
    environment = require_mapping(
        load_json(environment_path), "recovery capture environment"
    )
    require_exact_keys(
        environment,
        {
            "buildConfiguration",
            "hardwareModel",
            "macOSVersion",
            "schemaVersion",
            "xcodeVersion",
        },
        "recovery capture environment",
    )
    if (
        environment["schemaVersion"] != "mirmir-v4-recovery-environment-v1"
        or environment["buildConfiguration"] != "Release"
    ):
        raise QualificationError("recovery capture environment is not qualified Release evidence")
    for key in ("hardwareModel", "macOSVersion", "xcodeVersion"):
        require_string(environment[key], f"recovery capture environment.{key}")
    try:
        execution_log = execution_log_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise QualificationError(f"cannot read recovery execution log: {error}") from error
    if "** TEST SUCCEEDED **" not in execution_log:
        raise QualificationError("recovery execution log does not prove test success")

    report_scenarios = require_list(report["scenarios"], "recovery.scenarios")
    captured_scenarios = require_list(
        capture_document["scenarios"], "recovery raw capture.scenarios"
    )
    if len(report_scenarios) != len(expected_scenarios) or len(captured_scenarios) != len(expected_scenarios):
        raise QualificationError("recovery scenario count differs")
    referenced_paths: set[Path] = {capture_path, environment_path, execution_log_path}
    identical = 0
    contained = 0
    for index, expected in enumerate(expected_scenarios):
        identifier = expected["id"]
        scenario_label = f"recovery scenario {identifier}"
        report_scenario = require_mapping(
            report_scenarios[index], f"recovery.scenarios[{index}]"
        )
        require_exact_keys(
            report_scenario,
            {
                "containedFailureCode",
                "coverage",
                "externalEvidenceArtifact",
                "id",
                "outcome",
                "ownedArtifactReconciled",
                "referenceOutputArtifact",
                "referenceOutputSHA256",
                "referenceSemanticArtifact",
                "referenceSemanticSHA256",
                "resumedOutputArtifact",
                "resumedOutputSHA256",
                "resumedSemanticArtifact",
                "resumedSemanticSHA256",
                "unownedArtifactCount",
            },
            f"recovery.scenarios[{index}]",
        )
        if (
            report_scenario["id"] != identifier
            or report_scenario["coverage"] != [expected["coverageID"]]
            or report_scenario["outcome"] != expected["outcome"]
            or report_scenario["containedFailureCode"] != expected["containedFailureCode"]
        ):
            raise QualificationError(f"{scenario_label} differs from the locked contract")
        if require_integer(
            report_scenario["unownedArtifactCount"],
            f"{scenario_label}.unownedArtifactCount",
        ) != 0:
            raise QualificationError(f"recovery left unowned artifacts: {identifier}")
        require_bool(
            report_scenario["ownedArtifactReconciled"],
            f"{scenario_label}.ownedArtifactReconciled",
            True,
        )

        captured_scenario = require_mapping(
            captured_scenarios[index], f"recovery raw capture.scenarios[{index}]"
        )
        require_exact_keys(
            captured_scenario,
            {"externalEvidenceArtifact", "id"},
            f"recovery raw capture.scenarios[{index}]",
        )
        if (
            captured_scenario["id"] != identifier
            or captured_scenario["externalEvidenceArtifact"]
            != report_scenario["externalEvidenceArtifact"]
        ):
            raise QualificationError(f"{scenario_label} capture/report binding differs")
        scenario_root = (capture_root / "scenarios" / identifier).resolve()
        external_path, _ = capture_artifact(
            report_scenario["externalEvidenceArtifact"],
            f"{scenario_label}.externalEvidenceArtifact",
            scenario_root / "evidence.json",
        )
        referenced_paths.add(external_path)
        external = require_mapping(load_json(external_path), f"{scenario_label}.evidence")
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
            f"{scenario_label}.evidence",
        )
        if external["schemaVersion"] != RECOVERY_SCENARIO_SCHEMA:
            raise QualificationError(f"{scenario_label} evidence schema differs")
        for key in ("id", "coverageID", "injectionPoint", "outcome", "containedFailureCode"):
            if external[key] != expected[key]:
                raise QualificationError(f"{scenario_label}.{key} differs from the contract")
        require_bool(external["faultInjected"], f"{scenario_label}.faultInjected", True)
        require_bool(
            external["ownedArtifactReconciled"],
            f"{scenario_label}.evidence.ownedArtifactReconciled",
            True,
        )
        if require_integer(
            external["unownedArtifactCount"],
            f"{scenario_label}.evidence.unownedArtifactCount",
        ) != 0:
            raise QualificationError(f"recovery evidence left an unowned artifact: {identifier}")
        transcript_path, _ = capture_artifact(
            external["transcriptArtifact"],
            f"{scenario_label}.transcriptArtifact",
            scenario_root / "transcript.json",
        )
        referenced_paths.add(transcript_path)
        validate_recovery_transcript(
            transcript_path, expected, f"{scenario_label}.transcript"
        )

        artifact_keys = (
            "referenceOutputArtifact",
            "resumedOutputArtifact",
            "referenceSemanticArtifact",
            "resumedSemanticArtifact",
        )
        identity_keys = (
            "referenceOutputSHA256",
            "resumedOutputSHA256",
            "referenceSemanticSHA256",
            "resumedSemanticSHA256",
        )
        if expected["outcome"] == "identical_resumed_output":
            for key in artifact_keys:
                if report_scenario[key] != external[key]:
                    raise QualificationError(f"{scenario_label}.{key} report/evidence differs")
            reference_path, reference_identity = capture_artifact(
                external["referenceOutputArtifact"],
                f"{scenario_label}.referenceOutputArtifact",
                scenario_root / "reference-output.mov",
            )
            resumed_path, resumed_identity = capture_artifact(
                external["resumedOutputArtifact"],
                f"{scenario_label}.resumedOutputArtifact",
                scenario_root / "resumed-output.mov",
            )
            reference_semantic_path, reference_semantic_identity = capture_artifact(
                external["referenceSemanticArtifact"],
                f"{scenario_label}.referenceSemanticArtifact",
                scenario_root / "reference-semantic.json",
            )
            resumed_semantic_path, resumed_semantic_identity = capture_artifact(
                external["resumedSemanticArtifact"],
                f"{scenario_label}.resumedSemanticArtifact",
                scenario_root / "resumed-semantic.json",
            )
            referenced_paths.update(
                {
                    reference_path,
                    resumed_path,
                    reference_semantic_path,
                    resumed_semantic_path,
                }
            )
            claimed_identities = (
                require_hex(
                    report_scenario["referenceOutputSHA256"],
                    64,
                    f"{scenario_label}.referenceOutputSHA256",
                ),
                require_hex(
                    report_scenario["resumedOutputSHA256"],
                    64,
                    f"{scenario_label}.resumedOutputSHA256",
                ),
                require_hex(
                    report_scenario["referenceSemanticSHA256"],
                    64,
                    f"{scenario_label}.referenceSemanticSHA256",
                ),
                require_hex(
                    report_scenario["resumedSemanticSHA256"],
                    64,
                    f"{scenario_label}.resumedSemanticSHA256",
                ),
            )
            actual_identities = (
                reference_identity,
                resumed_identity,
                reference_semantic_identity,
                resumed_semantic_identity,
            )
            if claimed_identities != actual_identities:
                raise QualificationError(f"{scenario_label} artifact identity claims differ")
            if (
                reference_identity != resumed_identity
                or reference_path.stat().st_size != resumed_path.stat().st_size
            ):
                raise QualificationError(f"recovery resumed output is not byte-identical: {identifier}")
            reference_semantic = validate_recovery_semantic(
                reference_semantic_path, f"{scenario_label}.referenceSemantic"
            )
            resumed_semantic = validate_recovery_semantic(
                resumed_semantic_path, f"{scenario_label}.resumedSemantic"
            )
            if (
                reference_semantic != resumed_semantic
                or reference_semantic_identity != resumed_semantic_identity
            ):
                raise QualificationError(f"recovery resumed semantics differ: {identifier}")
            identical += 1
        else:
            for key in (*artifact_keys, *identity_keys):
                if report_scenario[key] is not None:
                    raise QualificationError(
                        f"recovery contained failure supplies output evidence: {identifier}"
                    )
            for key in artifact_keys:
                if external[key] is not None:
                    raise QualificationError(
                        f"recovery contained failure supplies captured output: {identifier}"
                    )
            require_string(
                report_scenario["containedFailureCode"],
                f"{scenario_label}.containedFailureCode",
            )
            contained += 1

    if referenced_paths != set(captured):
        raise QualificationError("recovery capture contains unreferenced or missing evidence")
    require_bool(report["recoveryGatePass"], "recovery.recoveryGatePass", True)
    return {
        "scenarioCount": len(report_scenarios),
        "identicalResumptionCount": identical,
        "containedFailureCount": contained,
        "coverage": required_coverage,
    }


def validate_p06(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "p06_reproduction"
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    require_exact_keys(
        report,
        {
            "schemaVersion",
            "contractSHA256",
            "candidate",
            "releaseEligible",
            "identities",
            "buildConfiguration",
            "sourceCheckoutState",
            "builds",
            "productionLoaderAcceptancePass",
            "tamperRejectionPass",
            "p06ReproductionGatePass",
        },
        "p06 report",
    )
    report_path = checked_path(evidence_root, entry["path"], "p06 report path")
    lane_root = report_path.parent
    lane_contract_path = checked_path(
        lane_root, "suite-contract.json", "p06 suite contract"
    )
    if lane_contract_path not in sealed_paths or sha256(lane_contract_path) != contract_sha:
        raise QualificationError("P06 suite contract is absent, unsealed, or stale")
    lane_contract = require_mapping(load_json(lane_contract_path), "p06 suite contract")
    if lane_contract.get("schemaVersion") != "mirmir-ash-v4-p06-reproduction-contract-v1":
        raise QualificationError("P06 suite contract schema mismatch")
    if lane_contract.get("suiteID") != "mirmir-ash-v4-p06-reproduction-v1":
        raise QualificationError("P06 suite identity mismatch")
    if lane_contract.get("buildConfiguration") != "Release" or lane_contract.get("sourceCheckoutState") != "clean":
        raise QualificationError("P06 suite does not require clean Release builds")
    clean_build_count = require_integer(
        lane_contract.get("cleanBuildCount"), "p06 suite cleanBuildCount"
    )
    if clean_build_count < 2:
        raise QualificationError("P06 suite requires fewer than two clean builds")
    clean_build_ids = require_list(
        lane_contract.get("cleanBuildIDs"), "p06 suite cleanBuildIDs"
    )
    if (
        len(clean_build_ids) != clean_build_count
        or len(set(clean_build_ids)) != len(clean_build_ids)
        or any(not isinstance(value, str) or not value for value in clean_build_ids)
    ):
        raise QualificationError("P06 clean-build identities are incomplete or repeated")
    production_source_count = require_integer(
        lane_contract.get("productionSourceCount"),
        "p06 suite productionSourceCount",
    )
    if production_source_count < 1:
        raise QualificationError("P06 production source inventory is empty")
    lane_roles = require_list(
        lane_contract.get("requiredRuntimeArtifactRoles"),
        "p06 suite requiredRuntimeArtifactRoles",
    )
    if lane_roles != contract["p06RuntimeArtifactRoles"]:
        raise QualificationError("P06 lane and release runtime artifact roles differ")

    identity_artifacts = {
        "captureSourceSHA256": "capture-tool.py",
        "evaluatorSHA256": "evaluator.py",
        "runnerSHA256": "runner.sh",
        "runtimeLoadCheckRunnerSHA256": "runtime-load-check-runner.sh",
        "runtimeLoadCheckSourceSHA256": "runtime-load-check.swift",
        "sourceIdentityToolSHA256": "source-identity-tool.py",
        "sourceProvenanceContractSHA256": "source-provenance-contract.json",
    }
    report_identities = require_mapping(report.get("identities"), "p06 identities")
    require_exact_keys(report_identities, set(identity_artifacts), "p06 identities")
    lane_capture = require_mapping(lane_contract.get("capture"), "p06 suite capture")
    require_exact_keys(lane_capture, set(identity_artifacts), "p06 suite capture")
    for identity_name, relative in identity_artifacts.items():
        artifact_path = checked_path(lane_root, relative, f"p06 {identity_name} artifact")
        if artifact_path not in sealed_paths:
            raise QualificationError(f"P06 identity artifact is unsealed: {relative}")
        actual_identity = sha256(artifact_path)
        if (
            require_hex(report_identities[identity_name], 64, f"p06 {identity_name}")
            != actual_identity
            or lane_capture.get(identity_name) != actual_identity
        ):
            raise QualificationError(f"P06 qualification identity mismatch: {identity_name}")
    source_contract_path = checked_path(
        lane_root,
        "source-provenance-contract.json",
        "p06 source provenance contract",
    )
    source_contract = require_mapping(
        load_json(source_contract_path), "p06 source provenance contract"
    )
    if (
        source_contract.get("schemaVersion")
        != "mirmir-ash-v4-p06-source-provenance-contract-v1"
        or source_contract.get("identityDomain")
        != "ash-p06-production-source-v1"
    ):
        raise QualificationError("P06 source provenance contract is unsupported")
    source_contract_paths = require_list(
        source_contract.get("sources"), "p06 source provenance sources"
    )
    if (
        len(source_contract_paths) != production_source_count
        or source_contract_paths != sorted(set(source_contract_paths))
    ):
        raise QualificationError("P06 source provenance contract is not a closed ordered inventory")
    if report.get("buildConfiguration") != "Release" or report.get("sourceCheckoutState") != "clean":
        raise QualificationError("P06 reproduction was not built cleanly in Release")
    builds = require_list(report.get("builds"), "p06.builds")
    if len(builds) != clean_build_count:
        raise QualificationError("P06 reproduction clean-build count differs from its contract")
    artifact_sets: set[str] = set()
    manifests: set[str] = set()
    builders: set[str] = set()
    source_manifests: set[str] = set()
    toolchains: set[str] = set()
    build_ids: set[str] = set()
    for index, item in enumerate(builds):
        build = require_mapping(item, f"p06.builds[{index}]")
        require_exact_keys(
            build,
            {
                "id",
                "runtimeArtifactSetSHA256",
                "runtimeManifestSHA256",
                "builderSHA256",
                "productionSourceRevision",
                "productionSourceManifestSHA256",
                "toolchainImageSHA256",
                "artifactManifest",
                "runtimeManifestArtifact",
                "builderArtifact",
                "productionSourceArtifact",
                "toolchainImageArtifact",
                "loaderEvidenceArtifact",
                "releaseQualifiedStatus",
                "developmentArtifactDependencyCount",
                "p05ProductionDependencyCount",
            },
            f"p06.builds[{index}]",
        )
        build_id = require_string(build["id"], f"p06 build[{index}].id")
        if build_id in build_ids:
            raise QualificationError(f"P06 reproduction repeats build identity: {build_id}")
        if build_id != clean_build_ids[index]:
            raise QualificationError(f"P06 reproduction build identity/order mismatch: {build_id}")
        build_ids.add(build_id)
        claimed_artifact_set = require_hex(
            build["runtimeArtifactSetSHA256"], 64, f"p06 build[{index}].artifact set"
        )
        claimed_manifest = require_hex(
            build["runtimeManifestSHA256"], 64, f"p06 build[{index}].manifest"
        )
        claimed_builder = require_hex(build["builderSHA256"], 64, f"p06 build[{index}].builder")
        claimed_source_revision = require_hex(
            build["productionSourceRevision"],
            64,
            f"p06 build[{index}].production source revision",
        )
        claimed_source_manifest = require_hex(
            build["productionSourceManifestSHA256"],
            64,
            f"p06 build[{index}].production source manifest",
        )
        claimed_toolchain = require_hex(
            build["toolchainImageSHA256"], 64, f"p06 build[{index}].toolchain"
        )
        artifact_manifest_path, _ = validate_sealed_artifact(
            evidence_root,
            build["artifactManifest"],
            sealed_paths,
            f"p06 build[{index}].artifactManifest",
        )
        artifact_manifest = require_mapping(
            load_json(artifact_manifest_path), f"p06 build[{index}] artifact manifest"
        )
        build_artifacts = require_list(
            artifact_manifest.get("artifacts"), f"p06 build[{index}] artifact manifest artifacts"
        )
        computed_entries: list[tuple[str, str]] = []
        for artifact_index, artifact in enumerate(build_artifacts):
            path, artifact_identity = validate_artifact(
                artifact_manifest_path.parent,
                artifact,
                f"p06 build[{index}] artifact[{artifact_index}]",
            )
            if path not in sealed_paths:
                raise QualificationError(f"p06 build[{index}] artifact is outside sealed evidence")
            computed_entries.append(
                (path.relative_to(artifact_manifest_path.parent).as_posix(), artifact_identity)
            )
        computed_artifact_set = artifact_set_sha(computed_entries)
        if claimed_artifact_set != computed_artifact_set:
            raise QualificationError(f"p06 build[{index}] artifact-set identity mismatch")
        runtime_manifest_path, runtime_manifest_file_identity = validate_sealed_artifact(
            evidence_root,
            build["runtimeManifestArtifact"],
            sealed_paths,
            f"p06 build[{index}].runtimeManifestArtifact",
        )
        if runtime_manifest_file_identity != candidate["runtimeManifestFileSHA256"]:
            raise QualificationError(f"p06 build[{index}] runtime manifest file identity mismatch")
        if runtime_manifest_path not in {
            (artifact_manifest_path.parent / relative).resolve()
            for relative, _ in computed_entries
        }:
            raise QualificationError(f"p06 build[{index}] artifact manifest omits runtime manifest")
        runtime_manifest = require_mapping(
            load_json(runtime_manifest_path), f"p06 build[{index}] runtime manifest"
        )
        if runtime_manifest_path.read_bytes() != canonical_bytes(runtime_manifest):
            raise QualificationError(f"p06 build[{index}] runtime manifest is not canonical JSON")
        if runtime_manifest.get("schemaID") != "ash.p06.runtime-manifest.v1":
            raise QualificationError(f"p06 build[{index}] runtime manifest schema mismatch")
        if runtime_manifest.get("runtimeID") != "ash-p06-deterministic-v4":
            raise QualificationError(f"p06 build[{index}] runtime identity mismatch")
        if runtime_manifest.get("releaseStatus") != "release_qualified":
            raise QualificationError(f"p06 build[{index}] is not release-qualified")
        semantic_manifest_identity = ash_canonical_identity(
            "ash-p06-runtime-manifest-v4", runtime_manifest
        )
        if claimed_manifest != semantic_manifest_identity:
            raise QualificationError(f"p06 build[{index}] semantic runtime identity mismatch")
        provenance = require_mapping(
            runtime_manifest.get("provenance"), f"p06 build[{index}] runtime provenance"
        )
        if provenance.get("sourceRevision") != candidate["runtimeSourceRevision"]:
            raise QualificationError(f"p06 build[{index}] runtime source revision mismatch")
        builder_path, builder_identity = validate_sealed_artifact(
            evidence_root,
            build["builderArtifact"],
            sealed_paths,
            f"p06 build[{index}].builderArtifact",
        )
        source_manifest_path, source_manifest_identity = validate_sealed_artifact(
            evidence_root,
            build["productionSourceArtifact"],
            sealed_paths,
            f"p06 build[{index}].productionSourceArtifact",
        )
        toolchain_path, toolchain_identity = validate_sealed_artifact(
            evidence_root,
            build["toolchainImageArtifact"],
            sealed_paths,
            f"p06 build[{index}].toolchainImageArtifact",
        )
        if claimed_builder != builder_identity or claimed_toolchain != toolchain_identity:
            raise QualificationError(f"p06 build[{index}] builder/toolchain identity mismatch")
        if provenance.get("builderSourceSHA256") != builder_identity:
            raise QualificationError(f"p06 build[{index}] provenance builder identity mismatch")
        if builder_path.stat().st_size == 0:
            raise QualificationError(f"p06 build[{index}] builder source manifest is empty")
        if claimed_source_manifest != source_manifest_identity:
            raise QualificationError(f"p06 build[{index}] production source manifest identity mismatch")
        production_source_manifest = require_mapping(
            load_json(source_manifest_path),
            f"p06 build[{index}] production source manifest",
        )
        require_exact_keys(
            production_source_manifest,
            {
                "schemaVersion",
                "contractSemanticSHA256",
                "identityDomain",
                "sourceCount",
                "sourceRevision",
                "sources",
            },
            f"p06 build[{index}] production source manifest",
        )
        if source_manifest_path.read_bytes() != canonical_bytes(production_source_manifest):
            raise QualificationError(f"p06 build[{index}] production source manifest is not canonical JSON")
        if (
            production_source_manifest.get("schemaVersion")
            != "mirmir-ash-v4-p06-production-source-manifest-v1"
            or production_source_manifest.get("identityDomain")
            != "ash-p06-production-source-v1"
            or production_source_manifest.get("contractSemanticSHA256")
            != sha256_bytes(canonical_bytes(source_contract))
        ):
            raise QualificationError(f"p06 build[{index}] production source provenance binding mismatch")
        if (
            require_integer(
                production_source_manifest.get("sourceCount"),
                f"p06 build[{index}] production source count",
            )
            != production_source_count
            or production_source_manifest.get("sourceRevision")
            != claimed_source_revision
            or claimed_source_revision != candidate["runtimeSourceRevision"]
        ):
            raise QualificationError(f"p06 build[{index}] production source revision/count mismatch")
        production_sources = require_list(
            production_source_manifest.get("sources"),
            f"p06 build[{index}] production sources",
        )
        if len(production_sources) != production_source_count:
            raise QualificationError(f"p06 build[{index}] production source entries are incomplete")
        observed_source_paths: list[str] = []
        normalized_trust_root = require_mapping(
            source_contract.get("normalizedDeploymentTrustRoot"),
            "p06 normalized deployment trust root",
        ).get("path")
        for source_index, source_value in enumerate(production_sources):
            source = require_mapping(
                source_value,
                f"p06 build[{index}] production source[{source_index}]",
            )
            require_exact_keys(
                source,
                {
                    "path",
                    "byteCount",
                    "sha256",
                    "normalizedByteCount",
                    "normalizedSHA256",
                    "normalizations",
                },
                f"p06 build[{index}] production source[{source_index}]",
            )
            source_path_label = (
                f"p06 build[{index}] production source[{source_index}].path"
            )
            relative_source = require_string(source["path"], source_path_label)
            parsed_source_path = PurePosixPath(relative_source)
            if (
                parsed_source_path.is_absolute()
                or ".." in parsed_source_path.parts
                or parsed_source_path.as_posix() != relative_source
            ):
                raise QualificationError(
                    f"{source_path_label} is not a safe canonical relative path"
                )
            observed_source_paths.append(relative_source)
            byte_count = require_integer(
                source["byteCount"],
                f"p06 build[{index}] production source[{source_index}].byteCount",
            )
            normalized_count = require_integer(
                source["normalizedByteCount"],
                f"p06 build[{index}] production source[{source_index}].normalizedByteCount",
            )
            source_identity = require_hex(
                source["sha256"],
                64,
                f"p06 build[{index}] production source[{source_index}].sha256",
            )
            normalized_identity = require_hex(
                source["normalizedSHA256"],
                64,
                f"p06 build[{index}] production source[{source_index}].normalizedSHA256",
            )
            normalizations = require_list(
                source["normalizations"],
                f"p06 build[{index}] production source[{source_index}].normalizations",
            )
            if relative_source == normalized_trust_root:
                if normalizations != [
                    "builderSourceSHA256",
                    "manifestSHA256",
                    "sourceRevision",
                ]:
                    raise QualificationError("P06 deployment trust-root normalization is incomplete")
            elif (
                normalizations
                or byte_count != normalized_count
                or source_identity != normalized_identity
            ):
                raise QualificationError(f"P06 source was unexpectedly normalized: {relative_source}")
        if observed_source_paths != source_contract_paths:
            raise QualificationError(f"p06 build[{index}] production source inventory differs from contract")
        toolchain_document = require_mapping(
            load_json(toolchain_path), f"p06 build[{index}] toolchain image"
        )
        if toolchain_path.read_bytes() != canonical_bytes(toolchain_document):
            raise QualificationError(f"p06 build[{index}] toolchain image is not canonical JSON")
        if toolchain_document != provenance.get("toolchain"):
            raise QualificationError(f"p06 build[{index}] toolchain artifact differs from runtime provenance")
        declared_runtime_artifacts = require_list(
            runtime_manifest.get("artifacts"), f"p06 build[{index}] runtime artifacts"
        )
        required_roles = set(contract["p06RuntimeArtifactRoles"])
        observed_roles: set[str] = set()
        observed_role_order: list[str] = []
        for artifact_index, artifact in enumerate(declared_runtime_artifacts):
            declaration = require_mapping(
                artifact, f"p06 build[{index}] runtime artifact[{artifact_index}]"
            )
            require_exact_keys(
                declaration,
                {"role", "relativePath", "schemaID", "contentSHA256", "byteCount"},
                f"p06 build[{index}] runtime artifact[{artifact_index}]",
            )
            role = require_string(
                declaration.get("role"), f"p06 build[{index}] runtime artifact[{artifact_index}].role"
            )
            if role in observed_roles or role not in required_roles:
                raise QualificationError(f"p06 build[{index}] duplicate/unexpected runtime role: {role}")
            observed_roles.add(role)
            observed_role_order.append(role)
            require_string(
                declaration.get("schemaID"),
                f"p06 build[{index}] runtime artifact {role}.schemaID",
            )
            relative = declaration.get("relativePath")
            expected_relative = (
                "artifacts/ash-p06.metallib"
                if role == "metal_library"
                else f"artifacts/{role}.json"
            )
            if relative != expected_relative:
                raise QualificationError(f"p06 build[{index}] runtime artifact path mismatch: {role}")
            content_path = checked_path(
                runtime_manifest_path.parent,
                relative,
                f"p06 build[{index}] runtime artifact {role}.relativePath",
            )
            if content_path not in sealed_paths:
                raise QualificationError(f"p06 build[{index}] runtime artifact is outside sealed evidence: {role}")
            if declaration.get("contentSHA256") != sha256(content_path):
                raise QualificationError(f"p06 build[{index}] runtime artifact hash mismatch: {role}")
            if declaration.get("byteCount") != content_path.stat().st_size:
                raise QualificationError(f"p06 build[{index}] runtime artifact size mismatch: {role}")
        if observed_roles != required_roles:
            raise QualificationError(
                f"p06 build[{index}] runtime artifact roles incomplete: {sorted(required_roles-observed_roles)}"
            )
        if observed_role_order != sorted(observed_role_order):
            raise QualificationError(f"p06 build[{index}] runtime artifact order is non-canonical")
        metal_declaration = next(
            artifact for artifact in declared_runtime_artifacts if artifact["role"] == "metal_library"
        )
        if provenance.get("metalLibrarySHA256") != metal_declaration["contentSHA256"]:
            raise QualificationError(f"p06 build[{index}] Metal provenance identity mismatch")
        forbidden_runtime_text = json.dumps(runtime_manifest, sort_keys=True).lower()
        if any(token in forbidden_runtime_text for token in ("p05", "preview", "development", "dev-runtime")):
            raise QualificationError(f"p06 build[{index}] retains a forbidden preview identity")
        loader_path, _ = validate_sealed_artifact(
            evidence_root,
            build["loaderEvidenceArtifact"],
            sealed_paths,
            f"p06 build[{index}].loaderEvidenceArtifact",
        )
        try:
            loader_lines = loader_path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as error:
            raise QualificationError(
                f"cannot read p06 build[{index}] loader transcript: {error}"
            ) from error
        loader_values: dict[str, str] = {}
        for line in loader_lines:
            if "=" not in line:
                raise QualificationError(
                    f"p06 build[{index}] loader transcript contains an unstructured line"
                )
            key, value = line.split("=", 1)
            if not key or not value or key in loader_values:
                raise QualificationError(
                    f"p06 build[{index}] loader transcript repeats or empties {key!r}"
                )
            loader_values[key] = value
        require_exact_keys(
            loader_values,
            {
                "runtime_id",
                "manifest_sha256",
                "source_revision",
                "builder_source_sha256",
                "artifact_count",
                "production_loader_acceptance",
                "same_length_artifact_tamper_rejection",
            },
            f"p06 build[{index}] loader transcript",
        )
        expected_loader_values = {
            "runtime_id": "ash-p06-deterministic-v4",
            "manifest_sha256": semantic_manifest_identity,
            "source_revision": claimed_source_revision,
            "builder_source_sha256": builder_identity,
            "artifact_count": str(len(declared_runtime_artifacts)),
            "production_loader_acceptance": "pass",
            "same_length_artifact_tamper_rejection": "pass",
        }
        if loader_values != expected_loader_values:
            raise QualificationError(
                f"p06 build[{index}] production loader/tamper transcript differs"
            )
        artifact_sets.add(computed_artifact_set)
        manifests.add(semantic_manifest_identity)
        builders.add(builder_identity)
        source_manifests.add(source_manifest_identity)
        toolchains.add(toolchain_identity)
        require_bool(build["releaseQualifiedStatus"], f"p06 build[{index}].releaseQualifiedStatus", True)
        if require_integer(build["developmentArtifactDependencyCount"], f"p06 build[{index}].development deps") != 0:
            raise QualificationError("P06 reproduction depends on a development artifact")
        if require_integer(build["p05ProductionDependencyCount"], f"p06 build[{index}].P05 deps") != 0:
            raise QualificationError("P06 reproduction retains a P05 production dependency")
    if artifact_sets != {candidate["runtimeArtifactSetSHA256"]}:
        raise QualificationError("P06 clean builds are not byte-identical to the candidate artifact set")
    if manifests != {candidate["runtimeManifestSHA256"]}:
        raise QualificationError("P06 clean builds do not reproduce the candidate manifest")
    if len(builders) != 1 or len(source_manifests) != 1 or len(toolchains) != 1:
        raise QualificationError(
            "P06 clean reproduction changed builder, production source manifest, or toolchain image"
        )
    require_bool(report.get("productionLoaderAcceptancePass"), "p06.productionLoaderAcceptancePass", True)
    require_bool(report.get("tamperRejectionPass"), "p06.tamperRejectionPass", True)
    require_bool(report.get("p06ReproductionGatePass"), "p06.p06ReproductionGatePass", True)
    return {
        "cleanBuildCount": len(builds),
        "runtimeArtifactSetSHA256": next(iter(artifact_sets)),
        "runtimeManifestSHA256": next(iter(manifests)),
        "builderSHA256": next(iter(builders)),
        "productionSourceManifestSHA256": next(iter(source_manifests)),
        "productionSourceCount": production_source_count,
        "toolchainImageSHA256": next(iter(toolchains)),
    }


def validate_support(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "support_matrix"
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    report_path = checked_path(evidence_root, entry["path"], "support report path")
    try:
        replayed_report = support_replay.replay_evidence(report_path.parent)
    except support_replay.SupportEvidenceError as error:
        raise QualificationError(
            f"support matrix independent replay failed: {error}"
        ) from error
    if canonical_bytes(replayed_report) != canonical_bytes(report):
        raise QualificationError("support matrix report differs from independent replay")
    declared = set(require_list(report.get("declaredSupportedMachineClassIDs"), "support declared classes"))
    rows = require_list(report.get("rows"), "support.rows")
    seen: set[str] = set()
    classes: set[str] = set()
    for index, item in enumerate(rows):
        row = require_mapping(item, f"support.rows[{index}]")
        require_exact_keys(
            row,
            {
                "id",
                "machineClass",
                "hardwareIdentitySHA256",
                "softwareImageSHA256",
                "appBundleSHA256",
                "runtimeManifestSHA256",
                "fullQualificationMatrixPass",
                "unexpectedSkipCount",
                "externalEvidenceArtifact",
            },
            f"support.rows[{index}]",
        )
        identifier = require_string(row["id"], f"support row[{index}].id")
        if identifier in seen:
            raise QualificationError(f"support matrix repeats row: {identifier}")
        seen.add(identifier)
        machine_class = require_string(row["machineClass"], f"support row[{index}].machineClass")
        classes.add(machine_class)
        require_hex(row["hardwareIdentitySHA256"], 64, f"support row[{index}].hardware")
        require_hex(row["softwareImageSHA256"], 64, f"support row[{index}].software")
        if row["appBundleSHA256"] != candidate["appBundleSHA256"]:
            raise QualificationError(f"support row used another application candidate: {identifier}")
        if row["runtimeManifestSHA256"] != candidate["runtimeManifestSHA256"]:
            raise QualificationError(f"support row used another P06 runtime: {identifier}")
        require_bool(row["fullQualificationMatrixPass"], f"support row[{index}].fullQualificationMatrixPass", True)
        if require_integer(row["unexpectedSkipCount"], f"support row[{index}].unexpectedSkipCount") != 0:
            raise QualificationError(f"support row contains unexpected skips: {identifier}")
        external_path, _ = validate_artifact(
            report_path.parent,
            row["externalEvidenceArtifact"],
            f"support row[{index}].externalEvidenceArtifact",
        )
        if external_path not in sealed_paths:
            raise QualificationError(
                f"support row[{index}] external evidence is outside the lane seal"
            )
    if classes != declared:
        raise QualificationError("support matrix does not cover every declared supported machine class")
    required_classes = set(contract["supportMatrixRequiredClasses"])
    if not required_classes.issubset(classes):
        raise QualificationError(f"support matrix misses required classes: {sorted(required_classes-classes)}")
    require_bool(report.get("supportMatrixGatePass"), "support.supportMatrixGatePass", True)
    return {
        "rowCount": len(rows),
        "machineClasses": sorted(classes),
        "replayedRows": replayed_report["rows"],
    }


def validate_smoke(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    label = "notarized_smoke"
    require_exact_keys(
        report,
        {
            "schemaVersion",
            "contractSHA256",
            "candidate",
            "releaseEligible",
            "identities",
            "appBundleSHA256",
            "bundleIdentifier",
            "productVersion",
            "productBuild",
            "notarizationAccepted",
            "ticketStapled",
            "gatekeeperAccepted",
            "codeSignatureValid",
            "hardenedRuntimeEnabled",
            "productionP06Loaded",
            "actions",
            "capture",
            "notarizedSmokeGatePass",
        },
        "notarized smoke report",
    )
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    report_path = checked_path(evidence_root, entry["path"], "notarized smoke report path")
    suite_root = report_path.parent.resolve()

    def suite_artifact(value: Any, artifact_label: str) -> tuple[Path, str]:
        path, artifact_identity = validate_artifact(suite_root, value, artifact_label)
        if path not in sealed_paths:
            raise QualificationError(f"{artifact_label} is outside the notarized smoke seal")
        return path, artifact_identity

    def bound_path(pointer: str, *, sealed: bool = True) -> Path:
        matches = [
            item
            for item in require_list(entry["identityBindings"], "notarized smoke identity bindings")
            if isinstance(item, dict) and item.get("jsonPointer") == pointer
        ]
        if len(matches) != 1:
            raise QualificationError(f"notarized smoke binding is absent or repeated: {pointer}")
        path, _ = validate_artifact(
            evidence_root,
            matches[0],
            f"notarized smoke binding {pointer}",
            allowed_extra_keys={"jsonPointer"},
        )
        if sealed and path not in sealed_paths:
            raise QualificationError(f"notarized smoke binding is outside the lane seal: {pointer}")
        return path

    if report.get("appBundleSHA256") != candidate["appBundleSHA256"]:
        raise QualificationError("notarized smoke used another app bundle")
    if report.get("bundleIdentifier") != candidate["bundleIdentifier"]:
        raise QualificationError("notarized smoke bundle identifier mismatch")
    if report.get("productVersion") != candidate["productVersion"] or report.get("productBuild") != candidate["productBuild"]:
        raise QualificationError("notarized smoke product version/build mismatch")
    for key in (
        "notarizationAccepted",
        "ticketStapled",
        "gatekeeperAccepted",
        "codeSignatureValid",
        "hardenedRuntimeEnabled",
        "productionP06Loaded",
    ):
        require_bool(report.get(key), f"notarized smoke.{key}", True)

    identities = require_mapping(report["identities"], "notarized smoke.identities")
    identity_keys = {
        "laneContractSHA256",
        "observerSourceSHA256",
        "evaluatorSHA256",
        "runnerSHA256",
        "rawCaptureSHA256",
        "applicationExecutableSHA256",
        "submittedArchiveSHA256",
        "toolManifestSHA256",
        "replayReceiptSHA256",
    }
    require_exact_keys(identities, identity_keys, "notarized smoke.identities")
    for key in identity_keys:
        require_hex(identities[key], 64, f"notarized smoke.identities.{key}")

    lane_contract_path = bound_path("/identities/laneContractSHA256")
    lane_contract = require_mapping(load_json(lane_contract_path), "notarized smoke lane contract")
    require_exact_keys(
        lane_contract,
        {
            "schemaVersion",
            "suiteID",
            "releaseQualificationContractPath",
            "candidate",
            "codeSigning",
            "tools",
            "capture",
            "requiredCommandRecords",
            "requiredObserverChecks",
            "actions",
        },
        "notarized smoke lane contract",
    )
    if lane_contract["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-contract-v1":
        raise QualificationError("notarized smoke lane contract schema differs")
    if lane_contract["suiteID"] != "mirmir-ash-v4-notarized-smoke-v1":
        raise QualificationError("notarized smoke lane suite identity differs")
    if identities["laneContractSHA256"] != require_hex(
        contract.get("notarizedSmokeLaneContractSHA256"),
        64,
        "release contract.notarizedSmokeLaneContractSHA256",
    ):
        raise QualificationError("notarized smoke lane contract is not the release-locked contract")
    locked_sources = require_mapping(
        contract.get("notarizedSmokeLockedSources"),
        "release contract.notarizedSmokeLockedSources",
    )
    require_exact_keys(
        locked_sources,
        {"observerSourceSHA256", "evaluatorSHA256", "runnerSHA256"},
        "release contract.notarizedSmokeLockedSources",
    )
    for key, expected in locked_sources.items():
        if identities.get(key) != require_hex(
            expected,
            64,
            f"release contract.notarizedSmokeLockedSources.{key}",
        ):
            raise QualificationError(f"notarized smoke source is not release-locked: {key}")

    if lane_contract["releaseQualificationContractPath"] != "script/v4/release-qualification-contract-v1.json":
        raise QualificationError("notarized smoke release-contract path differs")
    lane_candidate = require_mapping(lane_contract["candidate"], "notarized smoke lane candidate")
    require_exact_keys(
        lane_candidate,
        {"requiredBundleIdentifier", "requiredRuntimeID", "requiredRuntimeStatus"},
        "notarized smoke lane candidate",
    )
    if (
        lane_candidate["requiredBundleIdentifier"] != candidate["bundleIdentifier"]
        or lane_candidate["requiredRuntimeID"] != "ash-p06-deterministic-v4"
        or lane_candidate["requiredRuntimeStatus"] != "release_qualified"
    ):
        raise QualificationError("notarized smoke lane candidate policy differs")
    lane_signing = require_mapping(lane_contract["codeSigning"], "notarized smoke lane signing")
    require_exact_keys(
        lane_signing,
        {
            "requiredCertificateClass",
            "requiredTeamIdentifier",
            "requiredHardenedRuntimeFlag",
            "secureTimestampRequired",
            "requiredEntitlements",
            "forbiddenEntitlement",
        },
        "notarized smoke lane signing",
    )
    if (
        lane_signing["requiredCertificateClass"] != "Developer ID Application"
        or lane_signing["requiredTeamIdentifier"] != "9AQ2C2838M"
        or lane_signing["requiredHardenedRuntimeFlag"] != "runtime"
        or lane_signing["forbiddenEntitlement"] != "com.apple.security.get-task-allow"
    ):
        raise QualificationError("notarized smoke lane signing identity policy differs")
    require_bool(
        lane_signing["secureTimestampRequired"],
        "notarized smoke lane signing.secureTimestampRequired",
        True,
    )
    if lane_signing["requiredEntitlements"] != [
        "com.apple.security.app-sandbox",
        "com.apple.security.files.bookmarks.app-scope",
    ]:
        raise QualificationError("notarized smoke lane required entitlements differ")
    lane_tools = require_mapping(lane_contract["tools"], "notarized smoke lane tools")
    if lane_tools != {
        "codesign": "/usr/bin/codesign",
        "ditto": "/usr/bin/ditto",
        "spctl": "/usr/sbin/spctl",
        "xcrun": "/usr/bin/xcrun",
    }:
        raise QualificationError("notarized smoke lane tool paths differ")
    lane_actions = require_list(lane_contract["actions"], "notarized smoke lane actions")
    lane_action_ids = [
        require_string(require_mapping(item, f"notarized smoke lane action[{index}]").get("id"), f"notarized smoke lane action[{index}].id")
        for index, item in enumerate(lane_actions)
    ]
    if lane_action_ids != contract["notarizedSmokeActions"]:
        raise QualificationError("notarized smoke lane action order differs from release contract")
    for index, item in enumerate(lane_actions):
        action = require_mapping(item, f"notarized smoke lane action[{index}]")
        require_exact_keys(
            action,
            {"id", "evidenceKind", "producer"},
            f"notarized smoke lane action[{index}]",
        )
        identifier = lane_action_ids[index]
        if action["evidenceKind"] != contract["notarizedSmokeEvidenceKinds"][identifier]:
            raise QualificationError(f"notarized smoke lane evidence kind differs: {identifier}")
    expected_producers = {
        "notarization_ticket_acceptance": "notarytool",
        "gatekeeper_assessment": "spctl",
        "stapled_ticket_validation": "stapler",
        "code_signature_validation": "codesign",
        "launch": "shipping_app",
        "p06_runtime_load": "shipping_app",
        "media_probe": "shipping_app",
        "deterministic_process": "shipping_app",
        "semantic_output_verify": "shipping_app",
        "queue_relaunch_recovery": "shipping_app",
    }
    if {
        lane_action_ids[index]: require_string(
            require_mapping(item, f"notarized smoke lane action[{index}]")["producer"],
            f"notarized smoke lane action[{index}].producer",
        )
        for index, item in enumerate(lane_actions)
    } != expected_producers:
        raise QualificationError("notarized smoke lane action producers differ")
    lane_capture = require_mapping(lane_contract["capture"], "notarized smoke lane capture")
    require_exact_keys(
        lane_capture,
        {
            "buildConfiguration",
            "observerSourcePath",
            "observerSourceSHA256",
            "evaluatorSHA256",
            "runnerSHA256",
            "qualificationNamespace",
            "maximumCaptureAgeSeconds",
            "maximumNotarySubmissionAgeSeconds",
            "maximumSandboxEvidenceBytes",
            "appInvocationTimeoutSeconds",
        },
        "notarized smoke lane capture",
    )
    if (
        lane_capture["buildConfiguration"] != "Release"
        or lane_capture["observerSourcePath"] != "Mirmir/App/MirmirApp.swift"
        or lane_capture["qualificationNamespace"] != "MirmirQualificationV4/notarized-smoke"
        or lane_capture["maximumCaptureAgeSeconds"] != 3600
        or lane_capture["maximumNotarySubmissionAgeSeconds"] != 604800
        or lane_capture["maximumSandboxEvidenceBytes"] != 536870912
        or lane_capture["appInvocationTimeoutSeconds"] != 900
    ):
        raise QualificationError("notarized smoke lane capture policy differs")
    for report_key, lane_key in (
        ("observerSourceSHA256", "observerSourceSHA256"),
        ("evaluatorSHA256", "evaluatorSHA256"),
        ("runnerSHA256", "runnerSHA256"),
    ):
        if lane_capture.get(lane_key) != identities[report_key]:
            raise QualificationError(f"notarized smoke lane source lock differs: {report_key}")
        bound_path(f"/identities/{report_key}")

    for pointer in (
        "/identities/rawCaptureSHA256",
        "/identities/applicationExecutableSHA256",
        "/identities/submittedArchiveSHA256",
        "/identities/toolManifestSHA256",
        "/identities/replayReceiptSHA256",
        "/candidate/appBundleSHA256",
        "/contractSHA256",
    ):
        bound_path(pointer)

    capture_summary = require_mapping(report["capture"], "notarized smoke.capture")
    require_exact_keys(
        capture_summary,
        {
            "createdAtUTC",
            "finishedAtUTC",
            "rawCaptureArtifact",
            "replayReceiptArtifact",
            "nestedEvidenceReplayPass",
        },
        "notarized smoke.capture",
    )
    require_bool(
        capture_summary["nestedEvidenceReplayPass"],
        "notarized smoke.capture.nestedEvidenceReplayPass",
        True,
    )
    raw_capture_path, raw_capture_identity = suite_artifact(
        capture_summary["rawCaptureArtifact"],
        "notarized smoke.capture.rawCaptureArtifact",
    )
    if raw_capture_identity != identities["rawCaptureSHA256"]:
        raise QualificationError("notarized smoke raw capture identity differs")
    raw_capture = require_mapping(load_json(raw_capture_path), "notarized smoke raw capture")
    require_exact_keys(
        raw_capture,
        {
            "schemaVersion",
            "suiteID",
            "createdAtUTC",
            "finishedAtUTC",
            "laneContractSHA256",
            "releaseContractSHA256",
            "candidate",
            "identities",
            "notarySubmission",
            "artifacts",
            "commandRecords",
            "observerInvocations",
        },
        "notarized smoke raw capture",
    )
    if raw_capture["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-capture-v1":
        raise QualificationError("notarized smoke raw capture schema differs")
    if raw_capture["suiteID"] != lane_contract["suiteID"]:
        raise QualificationError("notarized smoke raw capture suite differs")
    if raw_capture["candidate"] != candidate:
        raise QualificationError("notarized smoke raw capture belongs to another candidate")
    if raw_capture["laneContractSHA256"] != identities["laneContractSHA256"]:
        raise QualificationError("notarized smoke raw lane contract identity differs")
    if raw_capture["releaseContractSHA256"] != contract_sha:
        raise QualificationError("notarized smoke raw release contract identity differs")
    if (
        raw_capture["createdAtUTC"] != capture_summary["createdAtUTC"]
        or raw_capture["finishedAtUTC"] != capture_summary["finishedAtUTC"]
    ):
        raise QualificationError("notarized smoke capture interval summary differs")

    raw_identities = require_mapping(raw_capture["identities"], "notarized smoke raw identities")
    raw_identity_keys = {
        "observerSourceSHA256",
        "evaluatorSHA256",
        "runnerSHA256",
        "applicationExecutableSHA256",
        "submittedArchiveSHA256",
        "candidateArchiveSHA256",
        "toolManifestSHA256",
    }
    require_exact_keys(raw_identities, raw_identity_keys, "notarized smoke raw identities")
    for key in raw_identity_keys:
        require_hex(raw_identities[key], 64, f"notarized smoke raw identities.{key}")
    for key in raw_identity_keys - {"candidateArchiveSHA256"}:
        if raw_identities[key] != identities[key]:
            raise QualificationError(f"notarized smoke raw identity differs: {key}")
    if raw_identities["candidateArchiveSHA256"] != candidate["appBundleSHA256"]:
        raise QualificationError("notarized smoke raw candidate archive identity differs")

    raw_root = raw_capture_path.parent.resolve()
    raw_artifacts = require_mapping(raw_capture["artifacts"], "notarized smoke raw artifacts")
    expected_raw_artifacts = {
        "candidateJSON",
        "laneContract",
        "releaseContract",
        "observerSource",
        "evaluator",
        "runner",
        "candidateArchive",
        "submittedArchive",
        "candidateExecutable",
        "toolManifest",
        "notaryLog",
    }
    require_exact_keys(raw_artifacts, expected_raw_artifacts, "notarized smoke raw artifacts")
    raw_artifact_paths: dict[str, Path] = {}
    raw_artifact_identities: dict[str, str] = {}
    for artifact_name in sorted(expected_raw_artifacts):
        path, artifact_identity = validate_artifact(
            raw_root,
            raw_artifacts[artifact_name],
            f"notarized smoke raw artifact {artifact_name}",
        )
        if path not in sealed_paths:
            raise QualificationError(f"notarized smoke raw artifact is outside the lane seal: {artifact_name}")
        raw_artifact_paths[artifact_name] = path
        raw_artifact_identities[artifact_name] = artifact_identity
    expected_artifact_identities = {
        "laneContract": identities["laneContractSHA256"],
        "releaseContract": contract_sha,
        "observerSource": identities["observerSourceSHA256"],
        "evaluator": identities["evaluatorSHA256"],
        "runner": identities["runnerSHA256"],
        "candidateArchive": candidate["appBundleSHA256"],
        "submittedArchive": identities["submittedArchiveSHA256"],
        "candidateExecutable": identities["applicationExecutableSHA256"],
        "toolManifest": identities["toolManifestSHA256"],
    }
    for artifact_name, expected_identity in expected_artifact_identities.items():
        if raw_artifact_identities[artifact_name] != expected_identity:
            raise QualificationError(f"notarized smoke raw artifact identity differs: {artifact_name}")
    if require_mapping(load_json(raw_artifact_paths["candidateJSON"]), "notarized smoke candidate artifact") != candidate:
        raise QualificationError("notarized smoke candidate artifact differs")

    required_record_ids = [
        require_string(value, "notarized smoke required command record")
        for value in require_list(lane_contract["requiredCommandRecords"], "notarized smoke required command records")
    ]
    expected_record_ids = [
        "notary_info",
        "notary_log",
        "gatekeeper_assessment",
        "stapled_ticket_validation",
        "code_signature_validation",
        "code_signature_display",
        "code_signature_entitlements",
        "code_signature_requirements",
        "submitted_signature_display",
        "submitted_signature_requirements",
        "observer_prepare",
        "observer_recover",
    ]
    if required_record_ids != expected_record_ids:
        raise QualificationError("notarized smoke required command record order differs")
    observer_checks = require_mapping(
        lane_contract["requiredObserverChecks"],
        "notarized smoke required observer checks",
    )
    if observer_checks != {
        "prepare": [
            "shippingExecutableIdentity",
            "sandboxIsolation",
            "productionP06Load",
            "realMediaProbe",
            "deterministicCPUProcess",
            "durableCheckpointPause",
            "userQueueUntouched",
        ],
        "recover": [
            "shippingExecutableIdentity",
            "sandboxIsolation",
            "productionP06Load",
            "phaseOneSealReplayVerified",
            "durableQueueReopened",
            "checkpointResumeCompleted",
            "decodedSemanticEquality",
            "userQueueUntouched",
        ],
    }:
        raise QualificationError("notarized smoke required observer checks differ")
    command_records = require_mapping(raw_capture["commandRecords"], "notarized smoke command records")
    if (
        len(required_record_ids) != len(set(required_record_ids))
        or set(command_records) != set(required_record_ids)
    ):
        raise QualificationError("notarized smoke command record set differs")
    for record_id in required_record_ids:
        record_path, _ = validate_artifact(
            raw_root,
            command_records[record_id],
            f"notarized smoke command record {record_id}",
        )
        if record_path not in sealed_paths:
            raise QualificationError(f"notarized smoke command record is outside the lane seal: {record_id}")

    observer_invocations = require_list(raw_capture["observerInvocations"], "notarized smoke observer invocations")
    if [
        require_mapping(item, f"notarized smoke observer invocation[{index}]").get("phase")
        for index, item in enumerate(observer_invocations)
    ] != ["prepare", "recover"]:
        raise QualificationError("notarized smoke observer phase order differs")

    replay_path, replay_identity = suite_artifact(
        capture_summary["replayReceiptArtifact"],
        "notarized smoke.capture.replayReceiptArtifact",
    )
    if replay_identity != identities["replayReceiptSHA256"]:
        raise QualificationError("notarized smoke replay receipt identity differs")
    receipt = require_mapping(load_json(replay_path), "notarized smoke replay receipt")
    require_exact_keys(
        receipt,
        {
            "schemaVersion",
            "captureSHA256",
            "evaluationSHA256",
            "verifiedActionIDs",
            "verifiedAtUTC",
            "nestedEvidenceReplayPass",
        },
        "notarized smoke replay receipt",
    )
    if receipt["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-replay-v1":
        raise QualificationError("notarized smoke replay receipt schema differs")
    if receipt["captureSHA256"] != raw_capture_identity:
        raise QualificationError("notarized smoke replay receipt captures another input")
    require_hex(receipt["evaluationSHA256"], 64, "notarized smoke replay evaluation identity")
    if receipt["verifiedActionIDs"] != contract["notarizedSmokeActions"]:
        raise QualificationError("notarized smoke replay action order differs")
    if receipt["verifiedAtUTC"] != raw_capture["finishedAtUTC"]:
        raise QualificationError("notarized smoke replay time differs")
    require_bool(
        receipt["nestedEvidenceReplayPass"],
        "notarized smoke replay nestedEvidenceReplayPass",
        True,
    )

    actions = require_list(report.get("actions"), "notarized smoke.actions")
    required_order = contract["notarizedSmokeActions"]
    required = set(required_order)
    evidence_kinds = require_mapping(
        contract.get("notarizedSmokeEvidenceKinds"), "notarized smoke evidence-kind contract"
    )
    if set(evidence_kinds) != required:
        raise QualificationError("notarized smoke evidence-kind contract is incomplete")
    seen: set[str] = set()
    if len(actions) != len(required_order):
        raise QualificationError("notarized smoke action count differs")
    for index, item in enumerate(actions):
        action = require_mapping(item, f"notarized smoke.actions[{index}]")
        require_exact_keys(
            action,
            {"id", "pass", "externalEvidenceArtifact"},
            f"notarized smoke.actions[{index}]",
        )
        identifier = require_string(action["id"], f"notarized smoke action[{index}].id")
        if identifier in seen or identifier not in required:
            raise QualificationError(f"notarized smoke unexpected/duplicate action: {identifier}")
        seen.add(identifier)
        require_bool(action["pass"], f"notarized smoke action {identifier}", True)
        if identifier != required_order[index]:
            raise QualificationError("notarized smoke action order differs")
        evidence_path, _ = suite_artifact(
            action["externalEvidenceArtifact"],
            f"notarized smoke action {identifier}.externalEvidenceArtifact",
        )
        if evidence_path.stat().st_size == 0:
            raise QualificationError(f"notarized smoke action has empty external evidence: {identifier}")
        attestation = require_mapping(
            load_json(evidence_path), f"notarized smoke action {identifier} attestation"
        )
        require_exact_keys(
            attestation,
            {
                "schemaVersion",
                "actionID",
                "evidenceKind",
                "command",
                "invocationSHA256",
                "exitStatus",
                "startedAtUTC",
                "finishedAtUTC",
                "observedAppBundleSHA256",
                "observedRuntimeManifestSHA256",
                "transcriptArtifact",
            },
            f"notarized smoke action {identifier} attestation",
        )
        if attestation["schemaVersion"] != "mirmir-ash-v4-external-execution-evidence-v1":
            raise QualificationError(f"notarized smoke action has unsupported attestation: {identifier}")
        if attestation["actionID"] != identifier or attestation["evidenceKind"] != evidence_kinds[identifier]:
            raise QualificationError(f"notarized smoke action attestation identity mismatch: {identifier}")
        command = require_list(attestation["command"], f"notarized smoke action {identifier}.command")
        if not command or any(not isinstance(argument, str) or not argument for argument in command):
            raise QualificationError(f"notarized smoke action command is empty/invalid: {identifier}")
        invocation_identity = sha256_bytes(canonical_bytes(command))
        if attestation["invocationSHA256"] != invocation_identity:
            raise QualificationError(f"notarized smoke action invocation identity mismatch: {identifier}")
        if attestation["exitStatus"] != 0:
            raise QualificationError(f"notarized smoke external process failed: {identifier}")
        if attestation["observedAppBundleSHA256"] != candidate["appBundleSHA256"]:
            raise QualificationError(f"notarized smoke action observed another app: {identifier}")
        if attestation["observedRuntimeManifestSHA256"] != candidate["runtimeManifestSHA256"]:
            raise QualificationError(f"notarized smoke action observed another runtime: {identifier}")
        try:
            started = datetime.fromisoformat(
                require_string(attestation["startedAtUTC"], f"notarized smoke {identifier}.startedAtUTC").replace("Z", "+00:00")
            )
            finished = datetime.fromisoformat(
                require_string(attestation["finishedAtUTC"], f"notarized smoke {identifier}.finishedAtUTC").replace("Z", "+00:00")
            )
        except ValueError as error:
            raise QualificationError(f"notarized smoke action has invalid UTC timestamps: {identifier}") from error
        if started.tzinfo is None or finished.tzinfo is None or finished < started:
            raise QualificationError(f"notarized smoke action time interval is invalid: {identifier}")
        transcript_path, _ = suite_artifact(
            attestation["transcriptArtifact"],
            f"notarized smoke action {identifier}.transcriptArtifact",
        )
        if transcript_path.stat().st_size == 0:
            raise QualificationError(f"notarized smoke action transcript is empty: {identifier}")
        transcript = require_mapping(
            load_json(transcript_path),
            f"notarized smoke action {identifier} transcript",
        )
        require_exact_keys(
            transcript,
            {
                "schemaVersion",
                "actionID",
                "evidenceKind",
                "sourceRecordIDs",
                "claims",
                "rawArtifacts",
            },
            f"notarized smoke action {identifier} transcript",
        )
        if transcript["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-transcript-v1":
            raise QualificationError(f"notarized smoke action transcript schema differs: {identifier}")
        if transcript["actionID"] != identifier or transcript["evidenceKind"] != evidence_kinds[identifier]:
            raise QualificationError(f"notarized smoke action transcript identity differs: {identifier}")
        source_record_ids = require_list(
            transcript["sourceRecordIDs"],
            f"notarized smoke action {identifier}.sourceRecordIDs",
        )
        if not source_record_ids or any(
            not isinstance(record_id, str) or record_id not in command_records
            for record_id in source_record_ids
        ):
            raise QualificationError(f"notarized smoke action has invalid source records: {identifier}")
        claims = require_mapping(transcript["claims"], f"notarized smoke action {identifier}.claims")
        if claims.get("candidateArchiveSHA256") != candidate["appBundleSHA256"]:
            raise QualificationError(f"notarized smoke transcript observed another app: {identifier}")
        if claims.get("runtimeManifestSHA256") != candidate["runtimeManifestSHA256"]:
            raise QualificationError(f"notarized smoke transcript observed another runtime: {identifier}")
        transcript_artifacts = require_list(
            transcript["rawArtifacts"],
            f"notarized smoke action {identifier}.rawArtifacts",
        )
        if not transcript_artifacts:
            raise QualificationError(f"notarized smoke action has no raw artifacts: {identifier}")
        for artifact_index, artifact in enumerate(transcript_artifacts):
            suite_artifact(
                artifact,
                f"notarized smoke action {identifier}.rawArtifacts[{artifact_index}]",
            )
    if seen != required:
        raise QualificationError(f"notarized smoke misses actions: {sorted(required-seen)}")
    require_bool(report.get("notarizedSmokeGatePass"), "notarized smoke.notarizedSmokeGatePass", True)
    return {"actionCount": len(actions), "actions": sorted(seen)}


VALIDATORS: dict[str, Callable[..., dict[str, Any]]] = {
    "quality": validate_quality,
    "same_scope_performance": validate_performance,
    "cpu_metal_parity": validate_parity,
    "media_preservation": validate_preservation,
    "recovery": validate_recovery,
    "p06_reproduction": validate_p06,
    "support_matrix": validate_support,
    "notarized_smoke": validate_smoke,
}


def validate_contract(value: Any) -> dict[str, Any]:
    contract = require_mapping(value, "release contract")
    if contract.get("schemaVersion") != SCHEMA_CONTRACT:
        raise QualificationError("unsupported release-qualification contract")
    if contract.get("hashAlgorithm") != "sha256":
        raise QualificationError("unsupported release-qualification hash algorithm")
    roles = require_list(contract.get("requiredEvidenceRoles"), "requiredEvidenceRoles")
    if len(roles) != len(set(roles)) or set(roles) != set(VALIDATORS):
        raise QualificationError("release contract evidence role set is incomplete or unexpected")
    if not set(contract.get("nonWaivableRoles", [])).issubset(roles):
        raise QualificationError("release contract names an unknown non-waivable role")
    return contract


def evaluate_candidate(candidate_path: Path, evidence_root: Path, contract_path: Path = DEFAULT_CONTRACT) -> dict[str, Any]:
    evidence_root = evidence_root.expanduser().resolve(strict=True)
    if not evidence_root.is_dir():
        raise QualificationError("evidence root is not a directory")
    contract_path = contract_path.expanduser().resolve(strict=True)
    contract = validate_contract(load_json(contract_path))
    contract_identity = sha256(contract_path)
    index_path = candidate_path.expanduser().resolve(strict=True)
    index = require_mapping(load_json(index_path), "candidate evidence index")
    require_exact_keys(index, {"schemaVersion", "candidate", "waivers", "evidence"}, "candidate evidence index")
    if index["schemaVersion"] != SCHEMA_CANDIDATE:
        raise QualificationError("unsupported candidate evidence index")
    if require_list(index["waivers"], "candidate waivers"):
        raise QualificationError("release qualification does not admit waivers")
    candidate = validate_candidate(index["candidate"], contract)
    entries = require_list(index["evidence"], "candidate evidence")
    roles: dict[str, Mapping[str, Any]] = {}
    for index_value, value in enumerate(entries):
        entry = require_mapping(value, f"candidate evidence[{index_value}]")
        require_exact_keys(
            entry,
            {"role", "path", "byteCount", "sha256", "contractSHA256", "sealedManifest", "identityBindings"},
            f"candidate evidence[{index_value}]",
        )
        role = require_string(entry["role"], f"candidate evidence[{index_value}].role")
        if role not in VALIDATORS or role in roles:
            raise QualificationError(f"candidate evidence role is unexpected or duplicate: {role}")
        require_hex(entry["contractSHA256"], 64, f"candidate evidence[{index_value}].contractSHA256")
        roles[role] = entry
    expected_roles = set(contract["requiredEvidenceRoles"])
    if set(roles) != expected_roles:
        raise QualificationError(
            f"candidate evidence role mismatch; missing={sorted(expected_roles-set(roles))}, "
            f"unexpected={sorted(set(roles)-expected_roles)}"
        )
    summaries: dict[str, Any] = {}
    evidence_identities: list[dict[str, Any]] = []
    for role in contract["requiredEvidenceRoles"]:
        entry = roles[role]
        report_path, report_identity = validate_artifact(evidence_root, entry, f"evidence.{role}", allowed_extra_keys={"role", "contractSHA256", "sealedManifest", "identityBindings"})
        report = require_mapping(load_json(report_path), f"evidence.{role}.report")
        sealed, sealed_paths = validate_sealed_manifest(
            evidence_root, entry["sealedManifest"], report_path, f"evidence.{role}.sealedManifest"
        )
        binding_contract = contract["identityBindings"]
        required_pointers = set(
            binding_contract["quality"]
            if role == "quality"
            else binding_contract.get(role, binding_contract["common"])
        )
        bindings = validate_bindings(evidence_root, report, entry, required_pointers, f"evidence.{role}")
        report_contract = (
            json_pointer(report, "/identities/contractSHA256", f"evidence.{role}.contract")
            if role == "quality"
            else report.get("contractSHA256")
        )
        if report_contract != entry["contractSHA256"]:
            raise QualificationError(f"evidence.{role} report contract is stale")
        validator = VALIDATORS[role]
        if role == "quality":
            summary = validator(report, candidate, contract, entry, evidence_root, sealed_paths)
        else:
            summary = validator(
                report,
                candidate,
                contract,
                entry["contractSHA256"],
                entry,
                evidence_root,
                sealed_paths,
            )
        summaries[role] = summary
        evidence_identities.append(
            {
                "role": role,
                "path": report_path.relative_to(evidence_root).as_posix(),
                "byteCount": report_path.stat().st_size,
                "sha256": report_identity,
                "contractSHA256": entry["contractSHA256"],
                "sealedManifestSHA256": entry["sealedManifest"]["sha256"],
                "sealedArtifactSetSHA256": artifact_set_sha((item["path"], item["sha256"]) for item in sealed),
                "identityBindings": bindings,
            }
        )
    if (
        summaries["same_scope_performance"]["runtimeBuilderSHA256"]
        != summaries["p06_reproduction"]["builderSHA256"]
    ):
        raise QualificationError(
            "performance evidence and clean P06 reproduction use different builders"
        )
    candidate_identity = sha256_bytes(canonical_bytes(candidate))
    evidence_set_identity = sha256_bytes(canonical_bytes(evidence_identities))
    qualification_identity = sha256_bytes(
        canonical_bytes(
            {
                "candidateIdentitySHA256": candidate_identity,
                "contractSHA256": contract_identity,
                "evidenceSetSHA256": evidence_set_identity,
                "summaries": summaries,
            }
        )
    )
    return {
        "schemaVersion": SCHEMA_REPORT,
        "releaseQualified": True,
        "candidate": candidate,
        "identities": {
            "contractSHA256": contract_identity,
            "candidateIndexSHA256": sha256(index_path),
            "candidateIdentitySHA256": candidate_identity,
            "evidenceSetSHA256": evidence_set_identity,
            "qualificationSHA256": qualification_identity,
        },
        "evidence": evidence_identities,
        "gates": {role: True for role in contract["requiredEvidenceRoles"]},
        "summaries": summaries,
        "waiversApplied": [],
    }


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")


def verify_report(
    report_path: Path,
    candidate_path: Path,
    evidence_root: Path,
    contract_path: Path = DEFAULT_CONTRACT,
) -> dict[str, Any]:
    actual = require_mapping(load_json(report_path.expanduser().resolve(strict=True)), "qualification report")
    recomputed = evaluate_candidate(candidate_path, evidence_root, contract_path)
    if canonical_bytes(actual) != canonical_bytes(recomputed):
        raise QualificationError("qualification report differs from recomputed evidence decision")
    return recomputed


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("evaluate", "verify"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--candidate", type=Path, required=True)
        subparser.add_argument("--evidence-root", type=Path, required=True)
        subparser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
        if name == "evaluate":
            subparser.add_argument("--output", type=Path, required=True)
        else:
            subparser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "evaluate":
        report = evaluate_candidate(arguments.candidate, arguments.evidence_root, arguments.contract)
        write_json(arguments.output.expanduser().resolve(), report)
        print(arguments.output.expanduser().resolve())
        return 0
    if arguments.command == "verify":
        verify_report(arguments.report, arguments.candidate, arguments.evidence_root, arguments.contract)
        print(arguments.report.expanduser().resolve())
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QualificationError, KeyError, TypeError, OSError) as error:
        print(f"release qualification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
