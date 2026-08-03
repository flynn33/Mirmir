#!/usr/bin/env python3
"""Fail-closed M7 release qualification for the deterministic ASH v4 engine.

This tool intentionally consumes evidence; it does not manufacture it.  A
report can fail a gate, while malformed, stale, incomplete, or tampered inputs
are rejected before a release decision is produced.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
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
        coverage = set(require_list(fixture["coverage"], f"preservation {identifier}.coverage"))
        if not coverage or not coverage.issubset(required):
            raise QualificationError(f"preservation fixture has unexpected coverage: {identifier}")
        covered.update(coverage)
        inputs = require_integer(fixture["enabledInputTrackCount"], f"preservation {identifier}.enabled tracks", 1)
        outputs = require_integer(fixture["accountedOutputTrackCount"], f"preservation {identifier}.accounted tracks", 1)
        if inputs != outputs:
            raise QualificationError(f"preservation does not account for every enabled track: {identifier}")
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
        for artifact_key in (
            "inputManifestArtifact",
            "outputManifestArtifact",
            "semanticVerifierArtifact",
        ):
            validate_sealed_artifact(
                evidence_root,
                fixture[artifact_key],
                sealed_paths,
                f"preservation {identifier}.{artifact_key}",
            )
    if covered != required:
        raise QualificationError(f"media preservation coverage mismatch; missing={sorted(required-covered)}")
    require_bool(report.get("mediaPreservationGatePass"), "preservation.mediaPreservationGatePass", True)
    return {"fixtureCount": len(fixtures), "accountedTrackCount": accounted_tracks, "coverage": sorted(covered)}


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
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
    scenarios = require_list(report.get("scenarios"), "recovery.scenarios")
    required = set(contract["recoveryCoverage"])
    covered: set[str] = set()
    identities: set[str] = set()
    identical = 0
    contained = 0
    for index, item in enumerate(scenarios):
        scenario = require_mapping(item, f"recovery.scenarios[{index}]")
        require_exact_keys(
            scenario,
            {
                "id",
                "coverage",
                "outcome",
                "referenceOutputSHA256",
                "resumedOutputSHA256",
                "containedFailureCode",
                "unownedArtifactCount",
                "ownedArtifactReconciled",
                "referenceOutputArtifact",
                "resumedOutputArtifact",
                "externalEvidenceArtifact",
            },
            f"recovery.scenarios[{index}]",
        )
        identifier = require_string(scenario["id"], f"recovery scenario[{index}].id")
        if identifier in identities:
            raise QualificationError(f"recovery repeats scenario: {identifier}")
        identities.add(identifier)
        coverage = set(require_list(scenario["coverage"], f"recovery {identifier}.coverage"))
        if not coverage or not coverage.issubset(required):
            raise QualificationError(f"recovery scenario has unexpected coverage: {identifier}")
        covered.update(coverage)
        if require_integer(scenario["unownedArtifactCount"], f"recovery {identifier}.unowned artifacts") != 0:
            raise QualificationError(f"recovery left unowned artifacts: {identifier}")
        require_bool(scenario["ownedArtifactReconciled"], f"recovery {identifier}.ownedArtifactReconciled", True)
        validate_sealed_artifact(
            evidence_root,
            scenario["externalEvidenceArtifact"],
            sealed_paths,
            f"recovery {identifier}.externalEvidenceArtifact",
        )
        outcome = scenario["outcome"]
        if outcome == "identical_resumed_output":
            reference = require_hex(scenario["referenceOutputSHA256"], 64, f"recovery {identifier}.reference")
            resumed = require_hex(scenario["resumedOutputSHA256"], 64, f"recovery {identifier}.resumed")
            if reference != resumed or scenario["containedFailureCode"] is not None:
                raise QualificationError(f"recovery resumed output is not identical: {identifier}")
            reference_path, reference_artifact_identity = validate_sealed_artifact(
                evidence_root,
                scenario["referenceOutputArtifact"],
                sealed_paths,
                f"recovery {identifier}.referenceOutputArtifact",
            )
            resumed_path, resumed_artifact_identity = validate_sealed_artifact(
                evidence_root,
                scenario["resumedOutputArtifact"],
                sealed_paths,
                f"recovery {identifier}.resumedOutputArtifact",
            )
            if (
                reference_artifact_identity != reference
                or resumed_artifact_identity != resumed
                or reference_path.stat().st_size != resumed_path.stat().st_size
            ):
                raise QualificationError(f"recovery output artifact identity mismatch: {identifier}")
            identical += 1
        elif outcome == "explicit_contained_failure":
            require_string(scenario["containedFailureCode"], f"recovery {identifier}.failure code")
            if scenario["referenceOutputSHA256"] is not None or scenario["resumedOutputSHA256"] is not None:
                raise QualificationError(f"recovery contained failure claims output identity: {identifier}")
            if scenario["referenceOutputArtifact"] is not None or scenario["resumedOutputArtifact"] is not None:
                raise QualificationError(f"recovery contained failure supplies output artifacts: {identifier}")
            contained += 1
        else:
            raise QualificationError(f"recovery has unsupported outcome: {identifier}")
    if covered != required:
        raise QualificationError(f"recovery coverage mismatch; missing={sorted(required-covered)}")
    require_bool(report.get("recoveryGatePass"), "recovery.recoveryGatePass", True)
    return {
        "scenarioCount": len(scenarios),
        "identicalResumptionCount": identical,
        "containedFailureCount": contained,
        "coverage": sorted(covered),
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
    if report.get("buildConfiguration") != "Release" or report.get("sourceCheckoutState") != "clean":
        raise QualificationError("P06 reproduction was not built cleanly in Release")
    builds = require_list(report.get("builds"), "p06.builds")
    if len(builds) < 2:
        raise QualificationError("P06 reproduction requires at least two clean builds")
    artifact_sets: set[str] = set()
    manifests: set[str] = set()
    builders: set[str] = set()
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
                "toolchainImageSHA256",
                "artifactManifest",
                "runtimeManifestArtifact",
                "builderArtifact",
                "toolchainImageArtifact",
                "releaseQualifiedStatus",
                "developmentArtifactDependencyCount",
                "p05ProductionDependencyCount",
            },
            f"p06.builds[{index}]",
        )
        build_id = require_string(build["id"], f"p06 build[{index}].id")
        if build_id in build_ids:
            raise QualificationError(f"P06 reproduction repeats build identity: {build_id}")
        build_ids.add(build_id)
        claimed_artifact_set = require_hex(
            build["runtimeArtifactSetSHA256"], 64, f"p06 build[{index}].artifact set"
        )
        claimed_manifest = require_hex(
            build["runtimeManifestSHA256"], 64, f"p06 build[{index}].manifest"
        )
        claimed_builder = require_hex(build["builderSHA256"], 64, f"p06 build[{index}].builder")
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
        _, builder_identity = validate_sealed_artifact(
            evidence_root,
            build["builderArtifact"],
            sealed_paths,
            f"p06 build[{index}].builderArtifact",
        )
        _, toolchain_identity = validate_sealed_artifact(
            evidence_root,
            build["toolchainImageArtifact"],
            sealed_paths,
            f"p06 build[{index}].toolchainImageArtifact",
        )
        if claimed_builder != builder_identity or claimed_toolchain != toolchain_identity:
            raise QualificationError(f"p06 build[{index}] builder/toolchain identity mismatch")
        if provenance.get("builderSourceSHA256") != builder_identity:
            raise QualificationError(f"p06 build[{index}] provenance builder identity mismatch")
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
        artifact_sets.add(computed_artifact_set)
        manifests.add(semantic_manifest_identity)
        builders.add(builder_identity)
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
    if len(builders) != 1 or len(toolchains) != 1:
        raise QualificationError("P06 clean reproduction changed builder or toolchain image")
    require_bool(report.get("productionLoaderAcceptancePass"), "p06.productionLoaderAcceptancePass", True)
    require_bool(report.get("tamperRejectionPass"), "p06.tamperRejectionPass", True)
    require_bool(report.get("p06ReproductionGatePass"), "p06.p06ReproductionGatePass", True)
    return {
        "cleanBuildCount": len(builds),
        "runtimeArtifactSetSHA256": next(iter(artifact_sets)),
        "runtimeManifestSHA256": next(iter(manifests)),
        "builderSHA256": next(iter(builders)),
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
        validate_sealed_artifact(
            evidence_root,
            row["externalEvidenceArtifact"],
            sealed_paths,
            f"support row[{index}].externalEvidenceArtifact",
        )
    if classes != declared:
        raise QualificationError("support matrix does not cover every declared supported machine class")
    required_classes = set(contract["supportMatrixRequiredClasses"])
    if not required_classes.issubset(classes):
        raise QualificationError(f"support matrix misses required classes: {sorted(required_classes-classes)}")
    require_bool(report.get("supportMatrixGatePass"), "support.supportMatrixGatePass", True)
    return {"rowCount": len(rows), "machineClasses": sorted(classes)}


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
    validate_common_report(report, candidate, contract["evidenceSchemas"][label], contract_sha, label)
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
    actions = require_list(report.get("actions"), "notarized smoke.actions")
    required = set(contract["notarizedSmokeActions"])
    evidence_kinds = require_mapping(
        contract.get("notarizedSmokeEvidenceKinds"), "notarized smoke evidence-kind contract"
    )
    if set(evidence_kinds) != required:
        raise QualificationError("notarized smoke evidence-kind contract is incomplete")
    seen: set[str] = set()
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
        evidence_path, _ = validate_sealed_artifact(
            evidence_root,
            action["externalEvidenceArtifact"],
            sealed_paths,
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
        transcript_path, _ = validate_sealed_artifact(
            evidence_root,
            attestation["transcriptArtifact"],
            sealed_paths,
            f"notarized smoke action {identifier}.transcriptArtifact",
        )
        if transcript_path.stat().st_size == 0:
            raise QualificationError(f"notarized smoke action transcript is empty: {identifier}")
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
