#!/usr/bin/env python3
"""Fail-closed M7 release qualification for the deterministic ASH v4 engine.

This tool intentionally consumes evidence; it does not manufacture it.  A
report can fail a gate, while malformed, stale, incomplete, or tampered inputs
are rejected before a release decision is produced.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path, PurePosixPath
import random
import stat
import statistics
import sys
import types
from typing import Any, Callable, Iterable, Mapping, Sequence
import uuid


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
MEDIA_TRACK_SCHEMA = "mirmir-ash-v4-track-observation-v2"
MEDIA_TIMING_SCHEMA = "mirmir-ash-v4-timing-observation-v1"
MEDIA_PIXEL_SCHEMA = "mirmir-ash-v4-pixel-observation-v2"
MEDIA_ATTACHMENT_SCHEMA = "mirmir-ash-v4-attachment-observation-v1"
MEDIA_CAPTURE_SCHEMA = "mirmir-ash-v4-media-preservation-capture-v2"
MEDIA_ROUTE_SCHEMA = "mirmir-ash-v4-media-production-route-receipt-v2"
MEDIA_PREFLIGHT_SCHEMA = "mirmir-ash-v4-media-independent-preflight-v2"
MEDIA_EXECUTION_RECEIPT_SCHEMA = "ash.deterministic-media-execution-receipt.v4.1"
MEDIA_EXPECTED_PREPARED_BACKEND = {
    "combined-p010-hdr-interlaced": "Mirmir.PreparedDeterministicV4Upscaler",
    "combined-alpha-geometry-straight":
        "Mirmir.PreparedDeterministicAlphaPlanningBackendV4",
    "combined-alpha-geometry-premultiplied":
        "Mirmir.PreparedDeterministicAlphaPlanningBackendV4",
    "rich-track-graph": "Mirmir.PreparedDeterministicV4Upscaler",
    "legible-track-graph": "Mirmir.PreparedDeterministicV4Upscaler",
    "auxiliary-picture-track": "Mirmir.PreparedDeterministicV4Upscaler",
}
RECOVERY_LANE_CONTRACT_SCHEMA = "mirmir-v4-recovery-qualification-contract-v2"
RECOVERY_CAPTURE_SCHEMA = "mirmir-v4-recovery-capture-v2"
RECOVERY_CAPTURE_MANIFEST_SCHEMA = "mirmir-v4-recovery-capture-artifacts-v2"
RECOVERY_REPORT_SCHEMA = "mirmir-ash-v4-recovery-report-v2"
RECOVERY_SUITE_MANIFEST_SCHEMA = "mirmir-v4-recovery-evidence-manifest-v2"
PARITY_REPORT_SCHEMA = "mirmir-ash-v4-cpu-metal-parity-report-v2"
PARITY_COMPARISON = (
    "exact_visible_plane_attachment_timeline_checkpoint_and_resume_bytes"
)
PARITY_REQUIRED_COVERAGE = (
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
TRUST_ROOT_SCHEMA = "mirmir-ash-v4-release-qualification-trust-root-v1"
TRUSTED_HELPER_CONTRACT: tuple[tuple[str, str, str], ...] = (
    (
        "support_matrix_replay",
        "support_matrix_v4.py",
        "support_matrix_v4_for_release_qualification",
    ),
    (
        "cpu_metal_parity_replay",
        "cpu_metal_parity_v4.py",
        "cpu_metal_parity_v4_for_release_qualification",
    ),
    (
        "p05_baseline_replay",
        "p05_baseline_v4.py",
        "p05_baseline_v4",
    ),
    (
        "quality_raw_plane_replay",
        "quality_gate_v4.py",
        "quality_gate_v4_for_release_qualification",
    ),
)
ROLE_VALIDATOR_NAMES: Mapping[str, str] = {
    "quality": "validate_quality",
    "same_scope_performance": "validate_performance",
    "cpu_metal_parity": "validate_parity",
    "media_preservation": "validate_preservation",
    "recovery": "validate_recovery",
    "p06_reproduction": "validate_p06",
    "support_matrix": "validate_support",
    "notarized_smoke": "validate_smoke",
}
ROLE_REPLAY_HELPERS: Mapping[str, tuple[str, ...]] = {
    "quality": ("p05_baseline_replay", "quality_raw_plane_replay"),
    "same_scope_performance": (),
    "cpu_metal_parity": ("cpu_metal_parity_replay",),
    "media_preservation": (),
    "recovery": (),
    "p06_reproduction": (),
    "support_matrix": ("support_matrix_replay",),
    "notarized_smoke": (),
}

# These modules are deliberately absent until the externally pinned trust root
# authenticates every byte. Importing a live working-tree helper before that
# check would let the verifier execute the very evidence it is meant to judge.
support_replay: types.ModuleType | None = None
parity_replay: types.ModuleType | None = None
p05_replay: types.ModuleType | None = None
quality_replay: types.ModuleType | None = None


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


def trusted_tool_set_sha(entries: Sequence[Mapping[str, Any]]) -> str:
    return sha256_bytes(
        b"mirmir-release-qualification-tool-set-v1\0"
        + canonical_bytes(list(entries))
    )


def trusted_file_descriptor(
    value: Any,
    label: str,
    *,
    expected_repository_path: str,
    actual_path: Path,
    extra_keys: set[str] | None = None,
) -> dict[str, Any]:
    descriptor = require_mapping(value, label)
    require_exact_keys(
        descriptor,
        {"repositoryRelativePath", "byteCount", "sha256"}
        | (extra_keys or set()),
        label,
    )
    if descriptor["repositoryRelativePath"] != expected_repository_path:
        raise QualificationError(f"{label} repository path differs")
    try:
        resolved = actual_path.expanduser().resolve(strict=True)
    except OSError as error:
        raise QualificationError(f"{label} file is missing") from error
    if actual_path.is_symlink() or not resolved.is_file():
        raise QualificationError(f"{label} must be a regular non-symlink file")
    expected_count = require_integer(
        descriptor["byteCount"], f"{label}.byteCount", 1
    )
    expected_identity = require_hex(
        descriptor["sha256"], 64, f"{label}.sha256"
    )
    if resolved.stat().st_size != expected_count or sha256(resolved) != expected_identity:
        raise QualificationError(f"{label} bytes differ from the external trust root")
    return descriptor


def expected_role_dispatch(
    contract: Mapping[str, Any],
) -> list[dict[str, Any]]:
    schemas = require_mapping(contract.get("evidenceSchemas"), "evidenceSchemas")
    roles = require_list(contract.get("requiredEvidenceRoles"), "requiredEvidenceRoles")
    return [
        {
            "role": role,
            "validator": ROLE_VALIDATOR_NAMES[role],
            "evidenceSchema": schemas[role],
            "replayHelperRoles": list(ROLE_REPLAY_HELPERS[role]),
        }
        for role in roles
    ]


def load_trusted_replay_module(
    path: Path,
    module_name: str,
    label: str,
) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise QualificationError(f"{label} cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    previous = sys.modules.get(module_name)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as error:
        if previous is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = previous
        raise QualificationError(f"{label} failed to load: {error}") from error
    return module


def establish_external_trust(
    trust_root_path: Path,
    expected_trust_root_sha256: str,
    contract_path: Path,
) -> dict[str, str]:
    expected_identity = require_hex(
        expected_trust_root_sha256,
        64,
        "expected external trust-root SHA-256",
    )
    try:
        root_path = trust_root_path.expanduser().resolve(strict=True)
    except OSError as error:
        raise QualificationError("external trust root is missing") from error
    if trust_root_path.is_symlink() or not root_path.is_file():
        raise QualificationError("external trust root must be a regular non-symlink file")
    actual_identity = sha256(root_path)
    if actual_identity != expected_identity:
        raise QualificationError("external trust-root SHA-256 mismatch")
    trust_root = require_mapping(load_json(root_path), "external trust root")
    require_exact_keys(
        trust_root,
        {
            "schemaVersion",
            "hashAlgorithm",
            "evaluator",
            "contract",
            "helpers",
            "roleDispatch",
            "trustedToolSetSHA256",
        },
        "external trust root",
    )
    if trust_root["schemaVersion"] != TRUST_ROOT_SCHEMA:
        raise QualificationError("external trust-root schema differs")
    if trust_root["hashAlgorithm"] != "sha256":
        raise QualificationError("external trust-root hash algorithm differs")

    evaluator = trusted_file_descriptor(
        trust_root["evaluator"],
        "external trust root evaluator",
        expected_repository_path="script/v4/release_qualification_v4.py",
        actual_path=Path(__file__),
    )
    contract_descriptor = trusted_file_descriptor(
        trust_root["contract"],
        "external trust root contract",
        expected_repository_path="script/v4/release-qualification-contract-v1.json",
        actual_path=contract_path,
    )
    contract = validate_contract(load_json(contract_path))

    helper_rows = require_list(trust_root["helpers"], "external trust root helpers")
    if len(helper_rows) != len(TRUSTED_HELPER_CONTRACT):
        raise QualificationError("external trust-root helper set is incomplete")
    normalized_helpers: list[dict[str, Any]] = []
    loaded: dict[str, types.ModuleType] = {}
    for index, (expected_role, filename, module_name) in enumerate(
        TRUSTED_HELPER_CONTRACT
    ):
        label = f"external trust root helpers[{index}]"
        row = trusted_file_descriptor(
            helper_rows[index],
            label,
            expected_repository_path=f"script/v4/{filename}",
            actual_path=SCRIPT_DIRECTORY / filename,
            extra_keys={"role", "moduleName"},
        )
        if row["role"] != expected_role or row["moduleName"] != module_name:
            raise QualificationError(f"{label} role/module differs")
        normalized_helpers.append(row)

    dispatch = require_list(
        trust_root["roleDispatch"], "external trust root roleDispatch"
    )
    if dispatch != expected_role_dispatch(contract):
        raise QualificationError(
            "external trust-root role dispatch differs from exhaustive handlers"
        )
    for row in dispatch:
        role = row["role"]
        validator = VALIDATORS.get(role)
        if validator is None or validator.__name__ != row["validator"]:
            raise QualificationError(
                f"external trust-root handler is not callable: {role}"
            )

    tool_entries = [
        {"role": "qualification_evaluator", **evaluator},
        {"role": "release_contract", **contract_descriptor},
        *normalized_helpers,
    ]
    tool_set_identity = require_hex(
        trust_root["trustedToolSetSHA256"],
        64,
        "external trust root trustedToolSetSHA256",
    )
    if tool_set_identity != trusted_tool_set_sha(tool_entries):
        raise QualificationError("external trust-root tool-set identity differs")

    # Loading happens only after every descriptor, dispatch row, and the
    # operator-supplied root identity has passed. p05 is installed first under
    # its canonical import name because the quality evaluator imports it.
    for (role, filename, module_name), row in zip(
        TRUSTED_HELPER_CONTRACT, normalized_helpers
    ):
        loaded[role] = load_trusted_replay_module(
            SCRIPT_DIRECTORY / filename,
            module_name,
            f"trusted helper {row['repositoryRelativePath']}",
        )

    global support_replay, parity_replay, p05_replay, quality_replay
    support_replay = loaded["support_matrix_replay"]
    parity_replay = loaded["cpu_metal_parity_replay"]
    p05_replay = loaded["p05_baseline_replay"]
    quality_replay = loaded["quality_raw_plane_replay"]
    return {
        "trustRootSHA256": actual_identity,
        "qualificationEvaluatorSHA256": evaluator["sha256"],
        "trustedToolSetSHA256": tool_set_identity,
    }


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


def packaged_capture_tree(root: Path) -> dict[str, Any]:
    """Independently reproduce the shipping observer's capture-tree seal."""

    root = root.resolve(strict=True)
    if not root.is_dir() or root.is_symlink():
        raise QualificationError("quality packaged capture root is unsafe")
    rows: list[tuple[str, str, Path | None]] = []
    for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
        metadata = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(metadata.st_mode):
            raise QualificationError("quality packaged capture contains a symbolic link")
        if stat.S_ISDIR(metadata.st_mode):
            rows.append((relative, "directory", None))
        elif stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1:
            rows.append((relative, "file", path))
        else:
            raise QualificationError("quality packaged capture contains a special file")
    digest = hashlib.sha256()
    digest.update(b"mirmir-packaged-capture-tree-v1\0")
    byte_count = 0
    file_count = 0
    for relative, kind, path in rows:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if kind == "directory":
            digest.update(b"directory\n")
            continue
        assert path is not None
        byte_count += path.stat().st_size
        file_count += 1
        if byte_count > 8 * 1_024 * 1_024 * 1_024:
            raise QualificationError("quality packaged capture exceeds 8 GiB")
        digest.update(b"file\0")
        digest.update(sha256(path).encode("ascii"))
        digest.update(b"\n")
    return {
        "byteCount": byte_count,
        "fileCount": file_count,
        "sha256": digest.hexdigest(),
    }


def validate_quality_package_identity(
    value: Any,
    candidate: Mapping[str, Any],
) -> dict[str, Any]:
    package = require_mapping(value, "quality packaged candidate identity")
    expected_keys = {
        "schemaVersion",
        "buildConfiguration",
        "applicationArchiveSHA256",
        "applicationPayloadIdentitySHA256",
        "applicationInfoPlistSHA256",
        "applicationExecutableSHA256",
        "codeDirectories",
        "codeDirectorySetSHA256",
        "designatedRequirementSHA256",
        "releaseConfigurationSHA256",
        "attestationSHA256",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
        "runtimeSourceRevision",
        "bundleIdentifier",
        "productVersion",
        "productBuild",
    }
    require_exact_keys(package, expected_keys, "quality packaged candidate identity")
    if (
        package["schemaVersion"] != "mirmir-v4-packaged-candidate-identity-v1"
        or package["buildConfiguration"] != "Release"
    ):
        raise QualificationError("quality packaged candidate header differs")
    scalar_sha_keys = {
        "applicationArchiveSHA256",
        "applicationPayloadIdentitySHA256",
        "applicationInfoPlistSHA256",
        "applicationExecutableSHA256",
        "codeDirectorySetSHA256",
        "designatedRequirementSHA256",
        "releaseConfigurationSHA256",
        "attestationSHA256",
        "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256",
        "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256",
    }
    for key in scalar_sha_keys:
        require_hex(package[key], 64, f"quality packaged candidate.{key}")
    require_hex(package["sourceCommit"], 40, "quality packaged candidate.sourceCommit")
    require_hex(
        package["runtimeSourceRevision"],
        (40, 64),
        "quality packaged candidate.runtimeSourceRevision",
    )
    code_directories = require_list(
        package["codeDirectories"], "quality packaged candidate code directories"
    )
    architectures: list[str] = []
    for index, raw in enumerate(code_directories):
        row = require_mapping(raw, f"quality CodeDirectory[{index}]")
        require_exact_keys(row, {"architecture", "sha256"}, f"quality CodeDirectory[{index}]")
        architecture = require_string(row["architecture"], f"quality CodeDirectory[{index}].architecture")
        require_hex(row["sha256"], 64, f"quality CodeDirectory[{index}].sha256")
        architectures.append(architecture)
    if architectures != ["arm64", "x86_64"]:
        raise QualificationError("quality packaged candidate architecture set differs")
    candidate_mapping = {
        "applicationArchiveSHA256": "appBundleSHA256",
        "releaseConfigurationSHA256": "releaseConfigurationSHA256",
        "sourceCommit": "sourceCommit",
        "sourceTreeIdentitySHA256": "sourceTreeIdentitySHA256",
        "runtimeManifestSHA256": "runtimeManifestSHA256",
        "runtimeManifestFileSHA256": "runtimeManifestFileSHA256",
        "runtimeArtifactSetSHA256": "runtimeArtifactSetSHA256",
        "runtimeSourceRevision": "runtimeSourceRevision",
        "bundleIdentifier": "bundleIdentifier",
        "productVersion": "productVersion",
        "productBuild": "productBuild",
    }
    for package_key, candidate_key in candidate_mapping.items():
        if package[package_key] != candidate[candidate_key]:
            raise QualificationError(
                f"quality packaged candidate differs from release candidate: {package_key}"
            )
    return dict(package)


def validate_packaged_quality_evidence(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    report_path: Path,
    contract_path: Path,
    sealed_paths: set[Path],
    merged_capture: Mapping[str, Any],
) -> dict[str, Any]:
    """Replay the self-contained exact-executable package evidence without a checkout."""

    identities = require_mapping(report["identities"], "quality.identities")
    package = validate_quality_package_identity(
        identities["packagedCandidateIdentity"], candidate
    )
    package_root = report_path.parent / "packaged-candidate"
    if not package_root.is_dir() or package_root.is_symlink():
        raise QualificationError("quality packaged candidate evidence is absent")
    record_path = package_root / "capture-record.json"
    if not record_path.is_file() or record_path.resolve() not in sealed_paths:
        raise QualificationError("quality packaged capture record is outside the suite seal")
    record = require_mapping(load_json(record_path), "quality packaged capture record")
    require_exact_keys(
        record,
        {
            "schemaVersion",
            "lane",
            "startedAtUTC",
            "finishedAtUTC",
            "requestSHA256",
            "observerSourceSHA256",
            "contractSHA256",
            "packageIdentity",
            "captureTree",
            "process",
            "artifacts",
        },
        "quality packaged capture record",
    )
    if record["schemaVersion"] != "mirmir-v4-packaged-evidence-capture-record-v1" or record["lane"] != "quality":
        raise QualificationError("quality packaged capture record header differs")
    if (
        record["requestSHA256"] != identities["evidenceRequestSHA256"]
        or record["observerSourceSHA256"] != identities["observerSourceSHA256"]
        or record["contractSHA256"] != identities["contractSHA256"]
        or record["packageIdentity"] != package
    ):
        raise QualificationError("quality packaged capture record binding differs")
    artifacts = require_mapping(record["artifacts"], "quality packaged artifacts")
    artifact_keys = {
        "request",
        "result",
        "stdout",
        "stderr",
        "candidate",
        "packageIdentity",
        "attestation",
        "observerSource",
        "contract",
        "releaseConfiguration",
        "applicationArchive",
    }
    require_exact_keys(artifacts, artifact_keys, "quality packaged artifacts")
    artifact_paths: dict[str, Path] = {}
    for name in sorted(artifact_keys):
        path, _ = validate_artifact(
            package_root, artifacts[name], f"quality packaged artifact {name}"
        )
        if path not in sealed_paths:
            raise QualificationError(
                f"quality packaged artifact is outside the suite seal: {name}"
            )
        artifact_paths[name] = path
    if load_json(artifact_paths["candidate"]) != candidate:
        raise QualificationError("quality packaged candidate artifact differs")
    if load_json(artifact_paths["packageIdentity"]) != package:
        raise QualificationError("quality packaged identity artifact differs")
    artifact_expectations = {
        "observerSource": identities["observerSourceSHA256"],
        "contract": identities["contractSHA256"],
        "releaseConfiguration": package["releaseConfigurationSHA256"],
        "applicationArchive": package["applicationArchiveSHA256"],
        "attestation": package["attestationSHA256"],
    }
    for name, expected in artifact_expectations.items():
        if sha256(artifact_paths[name]) != expected:
            raise QualificationError(f"quality packaged artifact identity differs: {name}")
    if sha256(contract_path) != identities["contractSHA256"]:
        raise QualificationError("quality packaged contract binding differs")
    request_bytes = artifact_paths["request"].read_bytes()
    request = require_mapping(load_json(artifact_paths["request"]), "quality packaged request")
    if request_bytes != canonical_bytes(request):
        raise QualificationError("quality packaged request is not canonical JSON")
    require_exact_keys(
        request,
        {
            "schemaVersion",
            "lane",
            "requestID",
            "nonce",
            "generatedAtUTC",
            "observerSourceSHA256",
            "contractSHA256",
            "packageIdentity",
            "captureEnvironment",
        },
        "quality packaged request",
    )
    if (
        request["schemaVersion"] != "mirmir-v4-packaged-evidence-request-v1"
        or request["lane"] != "quality"
        or request["observerSourceSHA256"] != identities["observerSourceSHA256"]
        or request["contractSHA256"] != identities["contractSHA256"]
        or request["packageIdentity"] != package
        or sha256_bytes(request_bytes) != identities["evidenceRequestSHA256"]
    ):
        raise QualificationError("quality packaged request binding differs")
    capture_root = package_root / "capture"
    observed_tree = packaged_capture_tree(capture_root)
    if (
        observed_tree != require_mapping(record["captureTree"], "quality packaged capture tree")
        or observed_tree["sha256"] != identities["packagedCaptureTreeSHA256"]
    ):
        raise QualificationError("quality packaged capture tree differs")
    process = require_mapping(record["process"], "quality packaged process")
    require_exact_keys(process, {"executableSHA256", "exitStatus"}, "quality packaged process")
    if process["executableSHA256"] != package["applicationExecutableSHA256"] or process["exitStatus"] != 0:
        raise QualificationError("quality packaged observer process differs")
    result = require_mapping(load_json(artifact_paths["result"]), "quality packaged result")
    for key, expected in (
        ("schemaVersion", "mirmir-v4-packaged-evidence-result-v1"),
        ("lane", "quality"),
        ("requestSHA256", identities["evidenceRequestSHA256"]),
        ("observerSourceSHA256", identities["observerSourceSHA256"]),
        ("contractSHA256", identities["contractSHA256"]),
        ("packageIdentity", package),
        ("captureTree", observed_tree),
    ):
        if result.get(key) != expected:
            raise QualificationError(f"quality packaged observer result differs: {key}")
    exact_manifest_path = capture_root / "candidate-capture-manifest.json"
    if not exact_manifest_path.is_file() or exact_manifest_path.resolve() not in sealed_paths:
        raise QualificationError("quality exact capture manifest is outside the suite seal")
    exact_manifest = require_mapping(
        load_json(exact_manifest_path), "quality exact capture manifest"
    )
    if (
        exact_manifest.get("schemaVersion")
        != "mirmir-ash-v4-quality-candidate-capture-v1"
        or exact_manifest.get("evidenceRequestSHA256")
        != identities["evidenceRequestSHA256"]
        or exact_manifest.get("observerSourceSHA256")
        != identities["observerSourceSHA256"]
        or exact_manifest.get("packagedCandidateIdentity") != package
        or exact_manifest.get("productionRuntimeLocked") is not True
        or exact_manifest.get("fullMirrorIdentityPass") is not True
    ):
        raise QualificationError("quality exact capture identity differs")
    exact_cases = require_list(exact_manifest.get("cases"), "quality exact capture cases")
    merged_cases = require_list(merged_capture.get("cases"), "quality merged capture cases")
    exact_by_id = {
        require_string(item.get("id"), "quality exact case.id"): require_mapping(
            item, "quality exact case"
        )
        for item in exact_cases
    }
    merged_by_id = {
        require_string(item.get("id"), "quality merged case.id"): require_mapping(
            item, "quality merged case"
        )
        for item in merged_cases
    }
    if len(exact_by_id) != len(exact_cases) or set(exact_by_id) != set(merged_by_id):
        raise QualificationError("quality exact and merged case sets differ")
    candidate_variants = set(QUALITY_VARIANTS) - {"baseline_p05"}
    for case_id in sorted(exact_by_id):
        exact_outputs = require_mapping(
            exact_by_id[case_id].get("outputs"), f"quality exact outputs {case_id}"
        )
        merged_outputs = require_mapping(
            merged_by_id[case_id].get("outputs"), f"quality merged outputs {case_id}"
        )
        if set(exact_outputs) != candidate_variants:
            raise QualificationError(f"quality exact output variants differ: {case_id}")
        for variant, relative in exact_outputs.items():
            exact_path = checked_path(capture_root, relative, f"quality exact output {case_id}/{variant}")
            merged_path = checked_path(
                report_path.parent,
                merged_outputs.get(variant),
                f"quality merged output {case_id}/{variant}",
            )
            if exact_path not in sealed_paths or merged_path not in sealed_paths or sha256(exact_path) != sha256(merged_path):
                raise QualificationError(
                    f"quality scored plane differs from exact executable: {case_id}/{variant}"
                )
    return package


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
        "corpusManifestSHA256",
        "corpusArtifactSetSHA256",
        "runtimeManifestSHA256",
        "runtimeSourceRevision",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
        "cropRuleSHA256",
        "metricModelSHA256",
        "outputSetSHA256",
        "evidenceRequestSHA256",
        "observerSourceSHA256",
        "packagedCaptureTreeSHA256",
        "packagedCandidateIdentity",
    }
    require_exact_keys(identities, expected_identity_keys, "quality.identities")
    for key in expected_identity_keys - {
        "runtimeSourceRevision",
        "sourceCommit",
        "outputSetSHA256",
        "packagedCandidateIdentity",
    }:
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
    report_path = checked_path(
        evidence_root, entry["path"], "quality report path"
    )
    capture_path = report_path.parent / "capture-manifest.json"
    if not capture_path.is_file() or capture_path.resolve() not in sealed_paths:
        raise QualificationError("quality capture manifest is absent from the sealed suite")
    capture = require_mapping(load_json(capture_path), "quality capture manifest")
    package = validate_packaged_quality_evidence(
        report,
        candidate,
        report_path,
        quality_contract_path,
        sealed_paths,
        capture,
    )
    try:
        replayed_per_clip = quality_replay.replay_sealed_evidence(
            report_path,
            quality_contract_path,
            embedded,
            identities,
        )
    except (SystemExit, ValueError) as error:
        raise QualificationError(
            f"quality raw-plane replay failed: {error}"
        ) from error
    if report.get("perClip") != replayed_per_clip:
        raise QualificationError(
            "perClip metrics differ from sealed raw-plane replay"
        )
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
        quality_replay.canonical_bytes(
            [{item["id"]: item["crop"]} for item in components]
        )
    )
    if identities["cropRuleSHA256"] != expected_crop_identity:
        raise QualificationError("quality crop-rule identity mismatch")
    metric_tool_binding = next(
        item for item in entry["identityBindings"] if item["jsonPointer"] == "/identities/metricToolSHA256"
    )
    metric_model_identity = sha256_bytes(
        b"mirmir-analytic-quality-model-v1\0"
        + quality_replay.canonical_bytes(components)
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
        "exactPackagedCandidatePass",
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
        "applicationArchiveSHA256": package["applicationArchiveSHA256"],
        "applicationExecutableSHA256": package["applicationExecutableSHA256"],
        "packagedCaptureTreeSHA256": identities["packagedCaptureTreeSHA256"],
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
    require_exact_keys(
        report,
        {
            "schemaVersion",
            "gateID",
            "contractSHA256",
            "baseline",
            "candidate",
            "measurement",
            "absoluteMilliseconds",
            "metricGates",
            "mandatoryCaseRatios",
            "memoryGate",
            "environmentGate",
            "semanticVerificationPass",
            "exactPackagedCandidatePass",
            "qualificationMode",
            "releaseEligible",
            "gatePass",
            "reportSHA256",
        },
        "performance report",
    )
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
    candidate_capture = observed["capture"]
    package = validate_quality_package_identity(
        candidate_capture.get("packagedCandidateIdentity"), candidate
    )
    request_identity = require_hex(
        candidate_capture.get("evidenceRequestSHA256"),
        64,
        "performance packaged request",
    )
    observer_identity = require_hex(
        candidate_capture.get("observerSourceSHA256"),
        64,
        "performance packaged observer source",
    )
    package_root = candidate_source_path.parent.parent / "packaged-candidate"
    record_path = package_root / "capture-record.json"
    if not record_path.is_file() or record_path.resolve() not in sealed_paths:
        raise QualificationError("performance packaged capture record is missing or unsealed")
    record = require_mapping(load_json(record_path), "performance packaged capture record")
    require_exact_keys(
        record,
        {
            "schemaVersion",
            "lane",
            "startedAtUTC",
            "finishedAtUTC",
            "requestSHA256",
            "observerSourceSHA256",
            "contractSHA256",
            "packageIdentity",
            "captureTree",
            "process",
            "artifacts",
        },
        "performance packaged capture record",
    )
    if (
        record["schemaVersion"]
        != "mirmir-v4-packaged-evidence-capture-record-v1"
        or record["lane"] != "performance"
        or record["requestSHA256"] != request_identity
        or record["observerSourceSHA256"] != observer_identity
        or record["contractSHA256"] != contract_sha
        or record["packageIdentity"] != package
    ):
        raise QualificationError("performance packaged capture binding differs")
    artifacts = require_mapping(record["artifacts"], "performance packaged artifacts")
    artifact_keys = {
        "request",
        "result",
        "stdout",
        "stderr",
        "candidate",
        "packageIdentity",
        "attestation",
        "observerSource",
        "contract",
        "releaseConfiguration",
        "applicationArchive",
    }
    require_exact_keys(artifacts, artifact_keys, "performance packaged artifacts")
    package_paths: dict[str, Path] = {}
    for name in sorted(artifact_keys):
        path, _ = validate_artifact(
            package_root,
            artifacts[name],
            f"performance packaged artifact {name}",
        )
        if path not in sealed_paths:
            raise QualificationError(
                f"performance packaged artifact is outside the suite seal: {name}"
            )
        package_paths[name] = path
    if load_json(package_paths["candidate"]) != candidate or load_json(
        package_paths["packageIdentity"]
    ) != package:
        raise QualificationError("performance packaged candidate binding differs")
    for name, expected in {
        "contract": contract_sha,
        "observerSource": observer_identity,
        "releaseConfiguration": package["releaseConfigurationSHA256"],
        "applicationArchive": package["applicationArchiveSHA256"],
        "attestation": package["attestationSHA256"],
    }.items():
        if sha256(package_paths[name]) != expected:
            raise QualificationError(
                f"performance packaged artifact identity differs: {name}"
            )
    request_bytes = package_paths["request"].read_bytes()
    request = require_mapping(
        load_json(package_paths["request"]), "performance packaged request"
    )
    if request_bytes != canonical_bytes(request) or (
        request.get("schemaVersion") != "mirmir-v4-packaged-evidence-request-v1"
        or request.get("lane") != "performance"
        or request.get("contractSHA256") != contract_sha
        or request.get("observerSourceSHA256") != observer_identity
        or request.get("packageIdentity") != package
        or sha256_bytes(request_bytes) != request_identity
    ):
        raise QualificationError("performance packaged request binding differs")
    package_capture_root = package_root / "capture"
    observed_tree = packaged_capture_tree(package_capture_root)
    if observed_tree != record["captureTree"]:
        raise QualificationError("performance packaged capture tree differs")
    process = require_mapping(record["process"], "performance packaged process")
    if (
        process.get("executableSHA256") != package["applicationExecutableSHA256"]
        or process.get("exitStatus") != 0
    ):
        raise QualificationError("performance packaged process differs")
    result = require_mapping(
        load_json(package_paths["result"]), "performance packaged result"
    )
    for key, expected in (
        ("schemaVersion", "mirmir-v4-packaged-evidence-result-v1"),
        ("lane", "performance"),
        ("requestSHA256", request_identity),
        ("observerSourceSHA256", observer_identity),
        ("contractSHA256", contract_sha),
        ("packageIdentity", package),
        ("captureTree", observed_tree),
    ):
        if result.get(key) != expected:
            raise QualificationError(f"performance packaged result differs: {key}")
    exact_capture = require_mapping(
        load_json(package_capture_root / "capture.json"),
        "performance exact packaged capture",
    )
    if exact_capture != candidate_capture:
        raise QualificationError(
            "performance evaluated capture differs from exact packaged observer output"
        )
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
    require_exact_keys(
        baseline_report,
        {
            "sourceRevision",
            "sourceTreeSHA256",
            "sourceIdentitySHA256",
            "artifactManifestSHA256",
        },
        "performance baseline report identity",
    )
    require_exact_keys(
        candidate_report,
        {
            "sourceRevision",
            "sourceTreeSHA256",
            "sourceIdentitySHA256",
            "runtimeManifestSHA256",
            "artifactManifestSHA256",
            "evidenceRequestSHA256",
            "observerSourceSHA256",
            "packagedCaptureTreeSHA256",
            "packagedCandidateIdentity",
        },
        "performance candidate report identity",
    )
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
    if (
        candidate_report["evidenceRequestSHA256"] != request_identity
        or candidate_report["observerSourceSHA256"] != observer_identity
        or candidate_report["packagedCaptureTreeSHA256"]
        != observed_tree["sha256"]
        or candidate_report["packagedCandidateIdentity"] != package
    ):
        raise QualificationError("performance report packaged identity differs")

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
    require_bool(
        report.get("exactPackagedCandidatePass"),
        "performance exact packaged candidate",
        True,
    )
    require_bool(report.get("releaseEligible"), "performance releaseEligible", True)
    if report.get("qualificationMode") != "release":
        raise QualificationError("performance qualification mode is not release")
    require_bool(report.get("gatePass"), "performance gatePass", True)
    return {
        "aggregateRatios": ratios,
        "upper95PercentConfidenceBounds": upper_bounds,
        "worstMandatoryClassRatio": worst_case_ratio,
        "warmupCount": baseline["warmups"],
        "measuredRunCount": baseline["samples"],
        "engineFrameSampleCount": len(baseline_engine),
        "runtimeBuilderSHA256": observed["runtime"]["builderSourceSHA256"],
        "applicationArchiveSHA256": package["applicationArchiveSHA256"],
        "applicationExecutableSHA256": package["applicationExecutableSHA256"],
        "packagedCaptureTreeSHA256": observed_tree["sha256"],
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
            "schemaVersion",
            "contractSHA256",
            "candidate",
            "releaseEligible",
            "identities",
            "comparison",
            "coverage",
            "cases",
            "exactPackagedCandidatePass",
            "byteParityGatePass",
        },
        "parity report",
    )
    if contract["evidenceSchemas"][label] != PARITY_REPORT_SCHEMA:
        raise QualificationError("release contract does not require parity-v2")
    if tuple(contract["parityCoverage"]) != PARITY_REQUIRED_COVERAGE:
        raise QualificationError("release contract parity coverage is weakened or reordered")
    lane_contract_sha = require_hex(
        contract.get("parityLaneContractSHA256"),
        64,
        "parityLaneContractSHA256",
    )
    if lane_contract_sha != contract_sha:
        raise QualificationError("parity lane contract identity is not release-locked")
    locked_sources = require_mapping(
        contract.get("parityLockedSources"), "parityLockedSources"
    )
    source_identity_keys = {
        "captureSourceSHA256",
        "evaluatorSHA256",
        "runnerSHA256",
    }
    require_exact_keys(locked_sources, source_identity_keys, "parityLockedSources")
    for key in source_identity_keys:
        require_hex(locked_sources[key], 64, f"parityLockedSources.{key}")
    local_sources = {
        "captureSourceSHA256": SCRIPT_DIRECTORY.parent.parent
        / "Mirmir/App/MirmirApp.swift",
        "evaluatorSHA256": SCRIPT_DIRECTORY / "cpu_metal_parity_v4.py",
        "runnerSHA256": SCRIPT_DIRECTORY / "run_cpu_metal_parity_v4.sh",
    }
    for key, path in local_sources.items():
        if sha256(path) != locked_sources[key]:
            raise QualificationError(f"release-locked parity source is stale: {key}")
    identities = require_mapping(report.get("identities"), "parity.identities")
    require_exact_keys(
        identities,
        {
            *source_identity_keys,
            "packagedCandidateIdentity",
            "evidenceRequestSHA256",
            "packagedCaptureTreeSHA256",
        },
        "parity.identities",
    )
    for key in source_identity_keys:
        require_hex(identities[key], 64, f"parity.identities.{key}")
        if identities[key] != locked_sources[key]:
            raise QualificationError(f"parity source differs from release lock: {key}")
    package = validate_quality_package_identity(
        identities["packagedCandidateIdentity"], candidate
    )
    request_identities = require_list(
        identities["evidenceRequestSHA256"], "parity packaged request identities"
    )
    tree_identities = require_list(
        identities["packagedCaptureTreeSHA256"],
        "parity packaged capture-tree identities",
    )
    if len(request_identities) != 2 or len(tree_identities) != 2:
        raise QualificationError("parity packaged identity pair differs")
    for index, value in enumerate(request_identities):
        require_hex(value, 64, f"parity packaged request[{index}]")
    for index, value in enumerate(tree_identities):
        require_hex(value, 64, f"parity packaged capture tree[{index}]")
    if request_identities[0] == request_identities[1]:
        raise QualificationError("parity packaged requests are not independently fresh")
    if report.get("comparison") != PARITY_COMPARISON:
        raise QualificationError("parity comparison omits required v2 semantics")
    report_coverage = require_list(report.get("coverage"), "parity.coverage")
    if tuple(report_coverage) != PARITY_REQUIRED_COVERAGE:
        raise QualificationError("parity report coverage is incomplete or reordered")

    report_path = checked_path(evidence_root, entry["path"], "parity report path")
    if report_path not in sealed_paths:
        raise QualificationError("parity report is outside the sealed evidence suite")
    if report_path.name != "cpu-metal-parity-report.json":
        raise QualificationError("parity report does not use the locked runner layout")
    parity_root = report_path.parent.resolve()

    def bound_path(pointer: str, expected_name: str) -> Path:
        matches = [
            require_mapping(item, "parity identity binding")
            for item in require_list(
                entry["identityBindings"], "parity.identityBindings"
            )
            if isinstance(item, dict) and item.get("jsonPointer") == pointer
        ]
        if len(matches) != 1:
            raise QualificationError(f"parity binding is missing or repeated: {pointer}")
        path, _ = validate_artifact(
            evidence_root,
            matches[0],
            f"parity binding {pointer}",
            allowed_extra_keys={"jsonPointer"},
        )
        if path not in sealed_paths or path.name != expected_name:
            raise QualificationError(f"parity binding layout differs: {pointer}")
        try:
            path.relative_to(parity_root)
        except ValueError as error:
            raise QualificationError(
                f"parity binding lies outside the nested parity suite: {pointer}"
            ) from error
        return path

    lane_contract_path = bound_path(
        "/contractSHA256", "cpu-metal-parity-contract-v2.json"
    )
    capture_source_path = bound_path(
        "/identities/captureSourceSHA256",
        "MirmirApp.swift",
    )
    evaluator_path = bound_path(
        "/identities/evaluatorSHA256", "cpu_metal_parity_v4.py"
    )
    runner_path = bound_path(
        "/identities/runnerSHA256", "run_cpu_metal_parity_v4.sh"
    )
    if sha256(lane_contract_path) != lane_contract_sha:
        raise QualificationError("nested parity contract differs from release lock")

    cases = require_list(report.get("cases"), "parity.cases")
    required = set(PARITY_REQUIRED_COVERAGE)
    covered: set[str] = set()
    case_ids: set[str] = set()
    for index, item in enumerate(cases):
        case = require_mapping(item, f"parity.cases[{index}]")
        require_exact_keys(
            case,
            {
                "id",
                "coverage",
                "cpuVisibleArtifact",
                "metalVisibleArtifact",
                "cpuSemanticsArtifact",
                "metalSemanticsArtifact",
                "cpuCheckpointSetArtifact",
                "metalCheckpointSetArtifact",
                "cpuResumeSetArtifact",
                "metalResumeSetArtifact",
                "cpuExecutionArtifact",
                "metalExecutionArtifact",
                "repeatRunIdentityPass",
                "crossProcessIdentityPass",
                "tileScheduleIdentityPass",
                "boundedTiledTemporalPathPass",
                "checkpointResumeIdentityPass",
                "timingAndAttachmentSemanticsPass",
            },
            f"parity.cases[{index}]",
        )
        identifier = require_string(case["id"], f"parity case[{index}].id")
        if identifier in case_ids:
            raise QualificationError(f"parity repeats case: {identifier}")
        case_ids.add(identifier)
        coverage_values = require_list(
            case["coverage"], f"parity {identifier}.coverage"
        )
        coverage = set(coverage_values)
        if (
            not coverage
            or len(coverage) != len(coverage_values)
            or not coverage.issubset(required)
        ):
            raise QualificationError(f"parity case has unexpected/empty coverage: {identifier}")
        covered.update(coverage)
        for artifact_kind in (
            "Visible",
            "Semantics",
            "CheckpointSet",
            "ResumeSet",
        ):
            cpu_key = f"cpu{artifact_kind}Artifact"
            metal_key = f"metal{artifact_kind}Artifact"
            cpu_path, cpu_identity = validate_sealed_artifact(
                parity_root,
                case[cpu_key],
                sealed_paths,
                f"parity {identifier}.{cpu_key}",
            )
            metal_path, metal_identity = validate_sealed_artifact(
                parity_root,
                case[metal_key],
                sealed_paths,
                f"parity {identifier}.{metal_key}",
            )
            if (
                cpu_path == metal_path
                or cpu_identity != metal_identity
                or cpu_path.stat().st_size != metal_path.stat().st_size
            ):
                raise QualificationError(
                    f"CPU/Metal parity mismatch: {identifier}/{artifact_kind}"
                )
        cpu_execution_path, _ = validate_sealed_artifact(
            parity_root,
            case["cpuExecutionArtifact"],
            sealed_paths,
            f"parity {identifier}.cpuExecutionArtifact",
        )
        metal_execution_path, _ = validate_sealed_artifact(
            parity_root,
            case["metalExecutionArtifact"],
            sealed_paths,
            f"parity {identifier}.metalExecutionArtifact",
        )
        if cpu_execution_path == metal_execution_path:
            raise QualificationError(
                f"CPU/Metal parity execution evidence aliases: {identifier}"
            )
        for key in (
            "repeatRunIdentityPass",
            "crossProcessIdentityPass",
            "tileScheduleIdentityPass",
            "boundedTiledTemporalPathPass",
            "checkpointResumeIdentityPass",
            "timingAndAttachmentSemanticsPass",
        ):
            require_bool(case[key], f"parity {identifier}.{key}", True)
    if covered != required:
        raise QualificationError(f"parity coverage mismatch; missing={sorted(required-covered)}")
    require_bool(report.get("byteParityGatePass"), "parity.byteParityGatePass", True)

    candidate_path = parity_root / "candidate-identity.json"
    packaged_roots = [
        parity_root / "packaged-process-a",
        parity_root / "packaged-process-b",
    ]
    capture_a = packaged_roots[0] / "capture"
    capture_b = packaged_roots[1] / "capture"
    manifest_path = parity_root / "artifact-manifest.json"
    for path, path_label in (
        (candidate_path, "candidate identity"),
        (manifest_path, "root manifest"),
    ):
        if not path.is_file() or path.is_symlink() or path.resolve() not in sealed_paths:
            raise QualificationError(f"nested parity {path_label} is missing or unsealed")
    for path, path_label in ((capture_a, "capture-a"), (capture_b, "capture-b")):
        if not path.is_dir() or path.is_symlink():
            raise QualificationError(f"nested parity {path_label} is missing or symbolic")
    for index, (package_root, capture_path) in enumerate(
        zip(packaged_roots, (capture_a, capture_b))
    ):
        record_path = package_root / "capture-record.json"
        if not record_path.is_file() or record_path.resolve() not in sealed_paths:
            raise QualificationError(
                f"parity packaged capture record[{index}] is missing or unsealed"
            )
        record = require_mapping(
            load_json(record_path), f"parity packaged capture record[{index}]"
        )
        require_exact_keys(
            record,
            {
                "schemaVersion",
                "lane",
                "startedAtUTC",
                "finishedAtUTC",
                "requestSHA256",
                "observerSourceSHA256",
                "contractSHA256",
                "packageIdentity",
                "captureTree",
                "process",
                "artifacts",
            },
            f"parity packaged capture record[{index}]",
        )
        if (
            record["schemaVersion"]
            != "mirmir-v4-packaged-evidence-capture-record-v1"
            or record["lane"] != "parity"
            or record["requestSHA256"] != request_identities[index]
            or record["contractSHA256"] != contract_sha
            or record["packageIdentity"] != package
        ):
            raise QualificationError(f"parity packaged record[{index}] binding differs")
        artifacts = require_mapping(
            record["artifacts"], f"parity packaged artifacts[{index}]"
        )
        artifact_keys = {
            "request",
            "result",
            "stdout",
            "stderr",
            "candidate",
            "packageIdentity",
            "attestation",
            "observerSource",
            "contract",
            "releaseConfiguration",
            "applicationArchive",
        }
        require_exact_keys(
            artifacts, artifact_keys, f"parity packaged artifacts[{index}]"
        )
        paths: dict[str, Path] = {}
        for name in sorted(artifact_keys):
            path, _ = validate_artifact(
                package_root,
                artifacts[name],
                f"parity packaged artifact[{index}].{name}",
            )
            if path not in sealed_paths:
                raise QualificationError(
                    f"parity packaged artifact[{index}].{name} is unsealed"
                )
            paths[name] = path
        if load_json(paths["candidate"]) != candidate or load_json(
            paths["packageIdentity"]
        ) != package:
            raise QualificationError(f"parity packaged binding[{index}] differs")
        for name, expected in {
            "contract": contract_sha,
            "observerSource": record["observerSourceSHA256"],
            "releaseConfiguration": package["releaseConfigurationSHA256"],
            "applicationArchive": package["applicationArchiveSHA256"],
            "attestation": package["attestationSHA256"],
        }.items():
            if sha256(paths[name]) != expected:
                raise QualificationError(
                    f"parity packaged artifact[{index}].{name} differs"
                )
        request_bytes = paths["request"].read_bytes()
        request = require_mapping(
            load_json(paths["request"]), f"parity packaged request[{index}]"
        )
        if request_bytes != canonical_bytes(request) or (
            request.get("schemaVersion")
            != "mirmir-v4-packaged-evidence-request-v1"
            or request.get("lane") != "parity"
            or request.get("contractSHA256") != contract_sha
            or request.get("observerSourceSHA256")
            != record["observerSourceSHA256"]
            or request.get("packageIdentity") != package
            or sha256_bytes(request_bytes) != request_identities[index]
        ):
            raise QualificationError(f"parity packaged request[{index}] differs")
        observed_tree = packaged_capture_tree(capture_path)
        if (
            observed_tree != record["captureTree"]
            or observed_tree["sha256"] != tree_identities[index]
        ):
            raise QualificationError(f"parity packaged capture tree[{index}] differs")
        process = require_mapping(
            record["process"], f"parity packaged process[{index}]"
        )
        if (
            process.get("executableSHA256")
            != package["applicationExecutableSHA256"]
            or process.get("exitStatus") != 0
        ):
            raise QualificationError(f"parity packaged process[{index}] differs")
        result = require_mapping(
            load_json(paths["result"]), f"parity packaged result[{index}]"
        )
        for key, expected in (
            ("schemaVersion", "mirmir-v4-packaged-evidence-result-v1"),
            ("lane", "parity"),
            ("requestSHA256", request_identities[index]),
            ("observerSourceSHA256", record["observerSourceSHA256"]),
            ("contractSHA256", contract_sha),
            ("packageIdentity", package),
            ("captureTree", observed_tree),
        ):
            if result.get(key) != expected:
                raise QualificationError(
                    f"parity packaged result[{index}].{key} differs"
                )
        observed_capture = require_mapping(
            load_json(capture_path / "capture.json"),
            f"parity exact capture[{index}]",
        )
        if (
            observed_capture.get("evidenceRequestSHA256")
            != request_identities[index]
            or observed_capture.get("packagedCandidateIdentity") != package
        ):
            raise QualificationError(f"parity exact capture[{index}] binding differs")
    try:
        parity_replay.verify_root_manifest(parity_root, manifest_path)
        replayed = parity_replay.evaluate(
            lane_contract_path,
            capture_a,
            capture_b,
            candidate_path,
            capture_source_path,
            evaluator_path,
            runner_path,
            parity_root,
            allow_fixture_runtime=True,
        )
    except parity_replay.ParityEvidenceError as error:
        raise QualificationError(f"nested parity replay failed: {error}") from error
    normalized_report = dict(report)
    normalized_report["releaseEligible"] = False
    normalized_report["exactPackagedCandidatePass"] = False
    normalized_report["byteParityGatePass"] = False
    normalized_identities = dict(identities)
    normalized_identities["packagedCandidateIdentity"] = None
    normalized_identities["evidenceRequestSHA256"] = None
    normalized_identities["packagedCaptureTreeSHA256"] = None
    normalized_report["identities"] = normalized_identities
    if canonical_bytes(replayed) != canonical_bytes(normalized_report):
        raise QualificationError("parity report differs from independent nested replay")
    require_bool(
        report.get("exactPackagedCandidatePass"),
        "parity.exactPackagedCandidatePass",
        True,
    )
    return {
        "caseCount": len(cases),
        "coverage": list(PARITY_REQUIRED_COVERAGE),
        "maximumByteDifference": 0,
        "nestedReplayPass": True,
        "applicationArchiveSHA256": package["applicationArchiveSHA256"],
        "applicationExecutableSHA256": package["applicationExecutableSHA256"],
    }


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
                "ordinal", "stableID", "kind", "enabled", "mediaTypeID", "codecID", "languageCode",
                "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256",
                "editsSHA256", "formatSHA256", "metadataSHA256",
            },
            track_label,
        )
        require_string(track["stableID"], f"{track_label}.stableID")
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
                "visibleSHA256", "repeatVisibleSHA256", "alphaSHA256",
                "alphaFrameSHA256", "preEncodeAlphaFrameSHA256",
                "repeatPreEncodeAlphaFrameSHA256", "decodedAlphaSHA256",
                "uniqueSignalCodeCount", "lowPaddingBitViolationCount",
            },
            track_label,
        )
        require_string(track["kind"], f"{track_label}.kind")
        require_string(track["pixelFormat"], f"{track_label}.pixelFormat")
        for key in ("bitDepth", "width", "height", "frameCount", "uniqueSignalCodeCount", "lowPaddingBitViolationCount"):
            require_integer(track[key], f"{track_label}.{key}")
        for key in ("visibleSHA256", "repeatVisibleSHA256"):
            require_hex(track[key], 64, f"{track_label}.{key}")
        for key in ("alphaSHA256", "decodedAlphaSHA256"):
            if track[key] is not None:
                require_hex(track[key], 64, f"{track_label}.{key}")
        for key in (
            "alphaFrameSHA256", "preEncodeAlphaFrameSHA256",
            "repeatPreEncodeAlphaFrameSHA256",
        ):
            frames = require_list(track[key], f"{track_label}.{key}")
            if len(frames) not in {0, track["frameCount"]}:
                raise QualificationError(f"{track_label}.{key} frame count differs")
            for index, identity in enumerate(frames):
                require_hex(identity, 64, f"{track_label}.{key}[{index}]")
    return tracks


def validate_media_attachment_observation(value: Mapping[str, Any], label: str) -> dict[int, dict[str, Any]]:
    require_exact_keys(value, {"schemaVersion", "fixtureID", "side", "tracks"}, label)
    if value["schemaVersion"] != MEDIA_ATTACHMENT_SCHEMA:
        raise QualificationError(f"{label} schema mismatch")
    tracks = media_track_index(value, label)
    keys = {
        "ordinal", "kind", "fieldCount", "fieldDetail", "cadence", "pixelAspectRatio",
        "cleanAperture", "preferredTransform", "colorPrimaries", "transferFunction",
        "yCbCrMatrix", "masteringDisplaySHA256", "contentLightSHA256",
        "ambientViewingEnvironmentSHA256", "dynamicHDRSamples", "alphaAssociation",
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
        for key in ("masteringDisplaySHA256", "contentLightSHA256", "ambientViewingEnvironmentSHA256"):
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

    if policy == "process_primary_preserve_auxiliary":
        input_primary, _ = media_first_video(
            input_tracks, f"preservation {fixture_id} input"
        )
        output_primary, _ = media_first_video(
            output_tracks, f"preservation {fixture_id} output"
        )
        if input_primary != output_primary or set(input_tracks) != set(output_tracks):
            raise QualificationError(
                f"preservation {fixture_id} primary/inventory differs"
            )
        for key in (
            "groups", "associations", "assetMetadataSHA256",
            "chapterMetadataSHA256",
        ):
            if canonical_bytes(input_side["trackObservation"][key]) != canonical_bytes(output_side["trackObservation"][key]):
                raise QualificationError(
                    f"preservation {fixture_id} protected asset semantics differ: {key}"
                )
        protected = {
            "ordinal", "kind", "enabled", "mediaTypeID", "languageCode",
            "extendedLanguageTag", "roleIDs", "timebase", "timeRangeSHA256",
            "editsSHA256", "metadataSHA256",
        }
        if (
            {key: input_tracks[input_primary][key] for key in protected}
            != {key: output_tracks[output_primary][key] for key in protected}
        ):
            raise QualificationError(
                f"preservation {fixture_id} primary protected semantics differ"
            )
        if set(input_timing) != set(output_timing) or set(input_pixels) != set(output_pixels) or set(input_attachments) != set(output_attachments):
            raise QualificationError(
                f"preservation {fixture_id} auxiliary observation inventory differs"
            )
        for ordinal in input_tracks:
            if ordinal == input_primary:
                continue
            if canonical_bytes({
                key: value for key, value in input_tracks[ordinal].items()
                if key != "stableID"
            }) != canonical_bytes({
                key: value for key, value in output_tracks[ordinal].items()
                if key != "stableID"
            }):
                raise QualificationError(
                    f"preservation {fixture_id} auxiliary track {ordinal} semantics differ"
                )
            if (
                input_timing[ordinal]["timingSHA256"]
                != output_timing[ordinal]["timingSHA256"]
                or input_timing[ordinal]["encodedPayloadSHA256"]
                != output_timing[ordinal]["encodedPayloadSHA256"]
            ):
                raise QualificationError(
                    f"preservation {fixture_id} auxiliary track {ordinal} timing/payload differs"
                )
            if ordinal in input_attachments and canonical_bytes(input_attachments[ordinal]) != canonical_bytes(output_attachments[ordinal]):
                raise QualificationError(
                    f"preservation {fixture_id} auxiliary track {ordinal} attachments differ"
                )
            if ordinal in input_pixels and input_pixels[ordinal]["visibleSHA256"] != output_pixels[ordinal]["visibleSHA256"]:
                raise QualificationError(
                    f"preservation {fixture_id} auxiliary track {ordinal} pixels differ"
                )
        source_presentation = [
            (sample["pts"], sample["duration"])
            for sample in input_timing[input_primary]["samples"]
        ]
        output_presentation = [
            (sample["pts"], sample["duration"])
            for sample in output_timing[output_primary]["samples"]
        ]
        if source_presentation != output_presentation:
            raise QualificationError(
                f"preservation {fixture_id} primary presentation timing differs"
            )
        checks.append({
            "id": "processed-primary-exact-auxiliary-preservation",
            "pass": True,
        })

    if policy in {
        "p010_field_normalization",
        "alpha_geometry",
        "process_primary_preserve_auxiliary",
    }:
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
        for key in ("masteringDisplaySHA256", "contentLightSHA256", "ambientViewingEnvironmentSHA256"):
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
        if (
            input_attachments[input_ordinal]["alphaAssociation"] != expected
            or output_attachments[output_ordinal]["alphaAssociation"] != expected
            or not pixel["preEncodeAlphaFrameSHA256"]
            or not (
                pixel["preEncodeAlphaFrameSHA256"]
                == pixel["repeatPreEncodeAlphaFrameSHA256"]
                == pixel["alphaFrameSHA256"]
            )
        ):
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


def preservation_alpha_axis_samples(
    source: int, target: int
) -> list[tuple[list[int], list[int]]]:
    if source <= 0 or target < source:
        raise QualificationError("preservation alpha oracle geometry is invalid")
    result: list[tuple[list[int], list[int]]] = []
    for destination in range(target):
        numerator = (2 * destination + 1) * source - target
        denominator = 2 * target
        base, remainder = divmod(numerator, denominator)
        phase = Fraction(remainder, denominator)
        n, d = phase.numerator, phase.denominator
        d2, d3 = d * d, d * d * d
        n2, n3 = n * n, n * n * n
        numerators = [
            -n * d2 + 2 * n2 * d - n3,
            2 * d3 - 5 * n2 * d + 3 * n3,
            n * d2 + 4 * n2 * d - 3 * n3,
            -n2 * d + n3,
        ]
        common = 2 * d3
        if sum(numerators) != common:
            raise QualificationError("preservation alpha cubic sum differs")
        coefficients: list[int] = []
        fractions: list[int] = []
        for value in numerators:
            quotient, fractional = divmod(value * (1 << 14), common)
            coefficients.append(quotient)
            fractions.append(fractional)
        residual = (1 << 14) - sum(coefficients)
        if not 0 <= residual <= 3:
            raise QualificationError("preservation alpha residual differs")
        preferred = [1, 2, 0, 3] if phase <= Fraction(1, 2) else [2, 1, 3, 0]
        rank = {tap: index for index, tap in enumerate(preferred)}
        order = sorted(range(4), key=lambda tap: (-fractions[tap], rank[tap]))
        for tap in order[:residual]:
            coefficients[tap] += 1

        def reflect101(index: int) -> int:
            if source == 1:
                return 0
            period = 2 * (source - 1)
            reflected = index % period
            return reflected if reflected < source else period - reflected

        result.append((
            [reflect101(base + offset) for offset in (-1, 0, 1, 2)],
            coefficients,
        ))
    return result


def preservation_round_ties_to_even(value: int, fractional_bits: int) -> int:
    denominator = 1 << fractional_bits
    quotient, remainder = divmod(value, denominator)
    doubled = remainder * 2
    if doubled < denominator:
        return quotient
    if doubled > denominator:
        return quotient + 1
    return quotient if quotient % 2 == 0 else quotient + 1


def preservation_independent_alpha_oracle(
    source: bytes,
    source_width: int,
    source_height: int,
    target_width: int,
    target_height: int,
) -> bytes:
    if len(source) != source_width * source_height:
        raise QualificationError("preservation alpha source length differs")
    horizontal = preservation_alpha_axis_samples(source_width, target_width)
    vertical = preservation_alpha_axis_samples(source_height, target_height)
    intermediate: list[list[int]] = []
    for source_y in range(source_height):
        row: list[int] = []
        offset = source_y * source_width
        for indices, coefficients in horizontal:
            row.append(sum(
                source[offset + index] * coefficient
                for index, coefficient in zip(indices, coefficients)
            ))
        intermediate.append(row)
    output = bytearray()
    for indices, coefficients in vertical:
        for target_x in range(target_width):
            accumulator = sum(
                intermediate[index][target_x] * coefficient
                for index, coefficient in zip(indices, coefficients)
            )
            output.append(min(255, max(
                0, preservation_round_ties_to_even(accumulator, 28)
            )))
    return bytes(output)


def validate_preservation_alpha_oracle(
    fixture_id: str,
    value: Any,
    capture_root: Path,
    sealed_paths: set[Path],
    input_side: Mapping[str, Any],
    output_side: Mapping[str, Any],
) -> list[str]:
    input_primary, _ = media_first_video(
        input_side["tracks"], f"preservation {fixture_id} input"
    )
    output_primary, _ = media_first_video(
        output_side["tracks"], f"preservation {fixture_id} output"
    )
    input_pixel = input_side["pixels"][input_primary]
    output_pixel = output_side["pixels"][output_primary]
    if not output_pixel["preEncodeAlphaFrameSHA256"]:
        if value is not None:
            raise QualificationError(
                f"preservation {fixture_id} has unexpected alpha oracle input"
            )
        return []
    oracle = require_mapping(value, f"preservation {fixture_id}.alphaOracleInput")
    require_exact_keys(oracle, {
        "schemaVersion", "artifact", "frameSHA256", "frameCount",
        "width", "height", "association",
    }, f"preservation {fixture_id}.alphaOracleInput")
    if oracle["schemaVersion"] != "mirmir-ash-v4-alpha-oracle-input-v1":
        raise QualificationError(
            f"preservation {fixture_id} alpha oracle schema differs"
        )
    artifact_path, _ = validate_artifact(
        capture_root,
        oracle["artifact"],
        f"preservation {fixture_id}.alphaOracleInput.artifact",
    )
    if artifact_path not in sealed_paths:
        raise QualificationError(
            f"preservation {fixture_id} alpha oracle artifact is unsealed"
        )
    raw = artifact_path.read_bytes()
    width = require_integer(oracle["width"], f"preservation {fixture_id}.alpha.width", 1)
    height = require_integer(oracle["height"], f"preservation {fixture_id}.alpha.height", 1)
    frame_count = require_integer(
        oracle["frameCount"], f"preservation {fixture_id}.alpha.frames", 1
    )
    frame_size = width * height
    if len(raw) != frame_size * frame_count:
        raise QualificationError(
            f"preservation {fixture_id} alpha oracle length differs"
        )
    source_hashes = require_list(
        oracle["frameSHA256"], f"preservation {fixture_id}.alpha.frameSHA256"
    )
    if len(source_hashes) != frame_count:
        raise QualificationError(
            f"preservation {fixture_id} alpha source frame count differs"
        )
    for index in range(frame_count):
        if require_hex(
            source_hashes[index], 64,
            f"preservation {fixture_id}.alpha.source[{index}]",
        ) != sha256_bytes(raw[index * frame_size:(index + 1) * frame_size]):
            raise QualificationError(
                f"preservation {fixture_id} alpha source frame differs"
            )
    if source_hashes != input_pixel["alphaFrameSHA256"]:
        raise QualificationError(
            f"preservation {fixture_id} alpha source observation differs"
        )
    target_width = output_pixel["width"]
    target_height = output_pixel["height"]
    expected = [
        sha256_bytes(preservation_independent_alpha_oracle(
            raw[index * frame_size:(index + 1) * frame_size],
            width,
            height,
            target_width,
            target_height,
        ))
        for index in range(frame_count)
    ]
    if not (
        expected == output_pixel["preEncodeAlphaFrameSHA256"]
        == output_pixel["repeatPreEncodeAlphaFrameSHA256"]
        == output_pixel["alphaFrameSHA256"]
    ):
        raise QualificationError(
            f"preservation {fixture_id} independent scalar alpha oracle differs"
        )
    return expected


def validate_preservation_production_route(
    fixture_id: str,
    production_value: Any,
    candidate: Mapping[str, Any],
    capture_binding: Mapping[str, Any],
    runtime_provenance_sha256: str,
    input_side: Mapping[str, Any],
    output_side: Mapping[str, Any],
) -> str:
    label = f"preservation raw {fixture_id}.production"
    production = require_mapping(production_value, label)
    require_exact_keys(
        production, {"runtimeManifestSHA256", "routeReceipt"}, label
    )
    if production["runtimeManifestSHA256"] != candidate["runtimeManifestSHA256"]:
        raise QualificationError(
            f"preservation raw fixture used another runtime: {fixture_id}"
        )
    route = require_mapping(production["routeReceipt"], f"{label}.routeReceipt")
    require_exact_keys(route, {
        "schemaVersion", "entryPoint", "executionProducer",
        "dispatchRequirement", "planEvidenceBoundary",
        "evidenceRequestSHA256", "evidenceNonceSHA256",
        "applicationArchiveSHA256", "applicationExecutableSHA256",
        "sourceTreeIdentitySHA256", "independentPreflight",
        "repeatIndependentPreflight", "executionReceipt",
        "repeatExecutionReceipt", "independentPreflightSHA256",
        "repeatIndependentPreflightSHA256", "executionReceiptSHA256",
        "repeatExecutionReceiptSHA256", "inputEnabledTrackCount",
        "outputEnabledTrackCount", "routeProofSHA256",
    }, f"{label}.routeReceipt")
    if (
        route["schemaVersion"] != MEDIA_ROUTE_SCHEMA
        or route["entryPoint"]
        != "VideoProcessingSession.processWithDeterministicV4ExecutionReceipt"
        or route["executionProducer"] != "exact_archived_mirmir_executable"
        or route["dispatchRequirement"]
        != "PreparedDeterministicV4RuntimePlanningBackend"
        or route["planEvidenceBoundary"]
        != "actual_session_receipt_matched_independent_preflight"
    ):
        raise QualificationError(
            f"preservation {fixture_id} production evidence boundary differs"
        )
    package = require_mapping(
        capture_binding["packagedCandidateIdentity"],
        "preservation capture packaged candidate",
    )
    for key, expected in (
        ("evidenceRequestSHA256", capture_binding["evidenceRequestSHA256"]),
        ("evidenceNonceSHA256", capture_binding["evidenceNonceSHA256"]),
        ("applicationArchiveSHA256", package["applicationArchiveSHA256"]),
        ("applicationExecutableSHA256", package["applicationExecutableSHA256"]),
        ("sourceTreeIdentitySHA256", candidate["sourceTreeIdentitySHA256"]),
    ):
        if require_hex(route[key], 64, f"{label}.{key}") != expected:
            raise QualificationError(
                f"preservation {fixture_id} route binding differs: {key}"
            )

    preflight_keys = {
        "schemaVersion", "preparedBackendType", "executor",
        "requestedBackendID", "ashPlanSHA256", "runtimeManifestSHA256",
        "runtimeProvenanceSHA256", "trackPlanSHA256",
        "sourceGraphSHA256", "migrationBlueprintSHA256",
        "primaryTrackOrdinal", "plannedTracks", "targetWidth",
        "targetHeight", "sourceVideoTrackCount", "sourceAudioTrackCount",
        "plannedEnabledTrackCount",
    }
    receipt_keys = {
        "schemaID", "preparedBackendType", "executor", "requestedBackendID",
        "actualBackendID", "ashPlanSHA256", "runtimeManifestSHA256",
        "runtimeProvenanceSHA256", "trackPlanSHA256", "sourceGraphSHA256",
        "migrationSourceGraphSHA256", "migrationPlanSHA256",
        "migrationBlueprintSHA256", "sourceAssetMetadataSHA256",
        "outputAssetMetadataSHA256", "sourceChapterMetadataSHA256",
        "outputChapterMetadataSHA256", "outputGraphSHA256",
        "semanticVerificationSHA256", "primaryTrackOrdinal", "plannedTracks",
        "migratedTracks", "targetWidth", "targetHeight", "encodedWidth",
        "encodedHeight", "processedFrameCount", "sourceVideoTrackCount",
        "sourceAudioTrackCount", "plannedEnabledTrackCount",
        "alphaVerification",
    }
    first_preflight = require_mapping(
        route["independentPreflight"], f"{label}.independentPreflight"
    )
    repeat_preflight = require_mapping(
        route["repeatIndependentPreflight"],
        f"{label}.repeatIndependentPreflight",
    )
    for name, preflight in (
        ("independentPreflight", first_preflight),
        ("repeatIndependentPreflight", repeat_preflight),
    ):
        require_exact_keys(preflight, preflight_keys, f"{label}.{name}")
        if preflight["schemaVersion"] != MEDIA_PREFLIGHT_SCHEMA:
            raise QualificationError(
                f"preservation {fixture_id} {name} schema differs"
            )
    if first_preflight != repeat_preflight:
        raise QualificationError(
            f"preservation {fixture_id} independent preflight is not repeatable"
        )
    expected_backend = MEDIA_EXPECTED_PREPARED_BACKEND[fixture_id]
    if first_preflight["preparedBackendType"] != expected_backend:
        raise QualificationError(
            f"preservation {fixture_id} prepared backend does not match fixture"
        )
    if (
        require_hex(
            first_preflight["runtimeManifestSHA256"], 64,
            f"{label}.runtimeManifestSHA256",
        ) != candidate["runtimeManifestSHA256"]
        or require_hex(
            first_preflight["runtimeProvenanceSHA256"], 64,
            f"{label}.runtimeProvenanceSHA256",
        ) != runtime_provenance_sha256
    ):
        raise QualificationError(
            f"preservation {fixture_id} runtime preflight differs"
        )

    input_tracks = input_side["tracks"]
    output_tracks = output_side["tracks"]
    input_primary, _ = media_first_video(
        input_tracks, f"preservation {fixture_id} input"
    )
    output_primary, _ = media_first_video(
        output_tracks, f"preservation {fixture_id} output"
    )
    if (
        input_primary != output_primary
        or require_integer(
            first_preflight["primaryTrackOrdinal"], f"{label}.primaryTrackOrdinal"
        ) != input_primary
    ):
        raise QualificationError(
            f"preservation {fixture_id} route primary differs"
        )
    planned_rows = require_list(
        first_preflight["plannedTracks"], f"{label}.plannedTracks"
    )
    expected_actions = [
        {
            "ordinal": ordinal,
            "stableID": input_tracks[ordinal]["stableID"],
            "kind": track["kind"],
            "action": "process" if ordinal == input_primary else "pass_through",
        }
        for ordinal in sorted(input_tracks)
        for track in (input_tracks[ordinal],)
    ]
    projected_actions: list[dict[str, Any]] = []
    for index, raw in enumerate(planned_rows):
        row = require_mapping(raw, f"{label}.trackActions[{index}]")
        require_exact_keys(
            row, {"ordinal", "stableID", "kind", "action"},
            f"{label}.trackActions[{index}]",
        )
        require_string(row["stableID"], f"{label}.trackActions[{index}].stableID")
        projected_actions.append(dict(row))
    if projected_actions != expected_actions:
        raise QualificationError(
            f"preservation {fixture_id} whole-asset plan actions differ"
        )
    output_pixels = output_side["pixels"]
    output_timing = output_side["timing"]
    output_attachments = output_side["attachments"]
    if output_primary not in output_pixels:
        raise QualificationError(
            f"preservation {fixture_id} lacks processed output pixels"
        )
    pixel = output_pixels[output_primary]
    input_enabled = input_side["trackObservation"]["enabledTrackCount"]
    output_enabled = output_side["trackObservation"]["enabledTrackCount"]
    expected_receipt_counts = {
        "plannedEnabledTrackCount": input_enabled,
        "sourceVideoTrackCount": sum(
            track["kind"] == "video" and track["enabled"]
            for track in input_tracks.values()
        ),
        "sourceAudioTrackCount": sum(
            track["kind"] == "audio" and track["enabled"]
            for track in input_tracks.values()
        ),
    }
    def validate_receipt(value: Any, name: str) -> Mapping[str, Any]:
        execution = require_mapping(value, f"{label}.{name}")
        require_exact_keys(execution, receipt_keys, f"{label}.{name}")
        if (
            execution["schemaID"] != MEDIA_EXECUTION_RECEIPT_SCHEMA
            or execution["preparedBackendType"] != expected_backend
            or execution["executor"] != "cpu_fixed_point"
            or execution["requestedBackendID"] != "mirmirDeterministicCPU"
            or execution["actualBackendID"] != "mirmirDeterministicCPU"
        ):
            raise QualificationError(
                f"preservation {fixture_id} {name} backend route differs"
            )
        for receipt_key, preflight_key in (
            ("preparedBackendType", "preparedBackendType"),
            ("executor", "executor"),
            ("requestedBackendID", "requestedBackendID"),
            ("ashPlanSHA256", "ashPlanSHA256"),
            ("runtimeManifestSHA256", "runtimeManifestSHA256"),
            ("runtimeProvenanceSHA256", "runtimeProvenanceSHA256"),
            ("trackPlanSHA256", "trackPlanSHA256"),
            ("sourceGraphSHA256", "sourceGraphSHA256"),
            ("migrationBlueprintSHA256", "migrationBlueprintSHA256"),
            ("primaryTrackOrdinal", "primaryTrackOrdinal"),
            ("plannedTracks", "plannedTracks"),
            ("targetWidth", "targetWidth"),
            ("targetHeight", "targetHeight"),
            ("sourceVideoTrackCount", "sourceVideoTrackCount"),
            ("sourceAudioTrackCount", "sourceAudioTrackCount"),
            ("plannedEnabledTrackCount", "plannedEnabledTrackCount"),
        ):
            if execution[receipt_key] != first_preflight[preflight_key]:
                raise QualificationError(
                    f"preservation {fixture_id} {name} differs from preflight: {receipt_key}"
                )
        if (
            execution["migrationSourceGraphSHA256"]
                != execution["sourceGraphSHA256"]
            or execution["migrationPlanSHA256"]
                != execution["trackPlanSHA256"]
        ):
            raise QualificationError(
                f"preservation {fixture_id} {name} internal plan differs"
            )
        for key in (
            "ashPlanSHA256", "runtimeManifestSHA256",
            "runtimeProvenanceSHA256", "trackPlanSHA256",
            "sourceGraphSHA256", "migrationSourceGraphSHA256",
            "migrationPlanSHA256", "migrationBlueprintSHA256",
            "sourceAssetMetadataSHA256", "outputAssetMetadataSHA256",
            "sourceChapterMetadataSHA256", "outputChapterMetadataSHA256",
            "outputGraphSHA256", "semanticVerificationSHA256",
        ):
            require_hex(execution[key], 64, f"{label}.{name}.{key}")
        if (
            execution["sourceAssetMetadataSHA256"]
                != input_side["trackObservation"]["assetMetadataSHA256"]
            or execution["outputAssetMetadataSHA256"]
                != output_side["trackObservation"]["assetMetadataSHA256"]
            or execution["sourceChapterMetadataSHA256"]
                != input_side["trackObservation"]["chapterMetadataSHA256"]
            or execution["outputChapterMetadataSHA256"]
                != output_side["trackObservation"]["chapterMetadataSHA256"]
        ):
            raise QualificationError(
                f"preservation {fixture_id} {name} metadata receipt differs"
            )
        if (
            require_integer(execution["targetWidth"], f"{label}.{name}.width", 1)
                != require_integer(execution["encodedWidth"], f"{label}.{name}.encodedWidth", 1)
            or execution["encodedWidth"] != pixel["width"]
            or require_integer(execution["targetHeight"], f"{label}.{name}.height", 1)
                != require_integer(execution["encodedHeight"], f"{label}.{name}.encodedHeight", 1)
            or execution["encodedHeight"] != pixel["height"]
            or require_integer(execution["processedFrameCount"], f"{label}.{name}.frames", 1)
                != output_timing[output_primary]["sampleCount"]
        ):
            raise QualificationError(
                f"preservation {fixture_id} {name} output receipt differs"
            )
        for key, expected in expected_receipt_counts.items():
            if require_integer(execution[key], f"{label}.{name}.{key}") != expected:
                raise QualificationError(
                    f"preservation {fixture_id} {name} {key} differs"
                )
        migrated = require_list(
            execution["migratedTracks"], f"{label}.{name}.migratedTracks"
        )
        expected_migrated = [
            row for row in planned_rows if row["action"] != "drop_with_consent"
        ]
        if len(migrated) != len(expected_migrated):
            raise QualificationError(
                f"preservation {fixture_id} {name} migrated inventory count differs"
            )
        for index, (raw_migrated, planned) in enumerate(
            zip(migrated, expected_migrated)
        ):
            row = require_mapping(
                raw_migrated, f"{label}.{name}.migratedTracks[{index}]"
            )
            require_exact_keys(row, {
                "stableID", "action", "migratedSampleCount",
                "sourceSampleStreamSHA256", "outputSampleStreamSHA256",
            }, f"{label}.{name}.migratedTracks[{index}]")
            if row["stableID"] != planned["stableID"] or row["action"] != planned["action"]:
                raise QualificationError(
                    f"preservation {fixture_id} {name} migrated stable-ID/action differs"
                )
            ordinal = planned["ordinal"]
            if require_integer(
                row["migratedSampleCount"],
                f"{label}.{name}.migratedTracks[{index}].sampleCount",
            ) != output_timing[ordinal]["sampleCount"]:
                raise QualificationError(
                    f"preservation {fixture_id} {name} migrated sample count differs"
                )
            if planned["action"] == "pass_through":
                source_stream = require_hex(
                    row["sourceSampleStreamSHA256"], 64,
                    f"{label}.{name}.migratedTracks[{index}].sourceStream",
                )
                output_stream = require_hex(
                    row["outputSampleStreamSHA256"], 64,
                    f"{label}.{name}.migratedTracks[{index}].outputStream",
                )
                if source_stream != output_stream:
                    raise QualificationError(
                        f"preservation {fixture_id} {name} pass-through stream differs"
                    )
            elif row["sourceSampleStreamSHA256"] is not None or row["outputSampleStreamSHA256"] is not None:
                raise QualificationError(
                    f"preservation {fixture_id} {name} processed stream hashes are invalid"
                )
        expected_alpha = pixel["preEncodeAlphaFrameSHA256"]
        alpha = execution["alphaVerification"]
        if expected_alpha:
            alpha = require_mapping(alpha, f"{label}.{name}.alphaVerification")
            require_exact_keys(alpha, {
                "schemaID", "codec", "association", "inputLayout",
                "width", "height", "encodedFormat", "frames",
            }, f"{label}.{name}.alphaVerification")
            if (
                alpha["schemaID"] != "ash.alpha-video-writer-verification.v4.1"
                or alpha["codec"] != "proRes4444"
                or alpha["association"]
                    != output_attachments[output_primary]["alphaAssociation"]
                or alpha["inputLayout"] != "bgra8"
                or alpha["width"] != pixel["width"]
                or alpha["height"] != pixel["height"]
            ):
                raise QualificationError(
                    f"preservation {fixture_id} {name} alpha header differs"
                )
            frames = require_list(alpha["frames"], f"{label}.{name}.alpha.frames")
            expected_samples = output_timing[output_primary]["samples"]
            if not (
                len(frames) == len(expected_alpha) == len(expected_samples)
            ):
                raise QualificationError(
                    f"preservation {fixture_id} {name} alpha frame inventory differs"
                )
            source_frames: list[str] = []
            for index, raw_frame in enumerate(frames):
                frame = require_mapping(raw_frame, f"{label}.{name}.alpha.frames[{index}]")
                require_exact_keys(frame, {
                    "ordinal", "presentationTime", "alphaByteCount",
                    "sourceAlphaSHA256", "decodedAlphaSHA256",
                }, f"{label}.{name}.alpha.frames[{index}]")
                if require_integer(
                    frame["ordinal"],
                    f"{label}.{name}.alpha.frames[{index}].ordinal",
                ) != index:
                    raise QualificationError(
                        f"preservation {fixture_id} {name} alpha frame ordinal differs"
                    )
                if require_integer(
                    frame["alphaByteCount"],
                    f"{label}.{name}.alpha.frames[{index}].byteCount",
                    1,
                ) != pixel["width"] * pixel["height"]:
                    raise QualificationError(
                        f"preservation {fixture_id} {name} alpha byte count differs"
                    )
                presentation = require_mapping(
                    frame["presentationTime"],
                    f"{label}.{name}.alpha.frames[{index}].presentationTime",
                )
                require_exact_keys(
                    presentation,
                    {"numerator", "denominator"},
                    f"{label}.{name}.alpha.frames[{index}].presentationTime",
                )
                numerator = presentation["numerator"]
                denominator = presentation["denominator"]
                if (
                    isinstance(numerator, bool)
                    or not isinstance(numerator, int)
                    or isinstance(denominator, bool)
                    or not isinstance(denominator, int)
                    or denominator <= 0
                ):
                    raise QualificationError(
                        f"preservation {fixture_id} {name} alpha presentation rational is invalid"
                    )
                presentation_value = Fraction(numerator, denominator)
                if (
                    presentation_value.numerator != numerator
                    or presentation_value.denominator != denominator
                    or presentation_value != media_fraction(
                        expected_samples[index]["pts"],
                        f"{label}.{name}.alpha.expectedPTS[{index}]",
                    )
                ):
                    raise QualificationError(
                        f"preservation {fixture_id} {name} alpha presentation time differs"
                    )
                source_sha = require_hex(
                    frame["sourceAlphaSHA256"], 64,
                    f"{label}.{name}.alpha.frames[{index}].source",
                )
                decoded_sha = require_hex(
                    frame["decodedAlphaSHA256"], 64,
                    f"{label}.{name}.alpha.frames[{index}].decoded",
                )
                if source_sha != decoded_sha:
                    raise QualificationError(
                        f"preservation {fixture_id} {name} alpha frame differs"
                    )
                source_frames.append(source_sha)
            if source_frames != expected_alpha:
                raise QualificationError(
                    f"preservation {fixture_id} {name} pre-encode alpha differs"
                )
        elif alpha is not None:
            raise QualificationError(
                f"preservation {fixture_id} {name} has unexpected alpha receipt"
            )
        return execution

    first_receipt = validate_receipt(route["executionReceipt"], "executionReceipt")
    repeat_receipt = validate_receipt(
        route["repeatExecutionReceipt"], "repeatExecutionReceipt"
    )
    if first_receipt != repeat_receipt:
        raise QualificationError(
            f"preservation {fixture_id} execution receipt is not repeatable"
        )
    for key, value in (
        ("independentPreflightSHA256", first_preflight),
        ("repeatIndependentPreflightSHA256", repeat_preflight),
        ("executionReceiptSHA256", first_receipt),
        ("repeatExecutionReceiptSHA256", repeat_receipt),
    ):
        if require_hex(route[key], 64, f"{label}.{key}") != sha256_bytes(canonical_bytes(value)):
            raise QualificationError(
                f"preservation {fixture_id} rehashed receipt differs: {key}"
            )
    if (
        route["independentPreflightSHA256"]
            != route["repeatIndependentPreflightSHA256"]
        or route["executionReceiptSHA256"]
            != route["repeatExecutionReceiptSHA256"]
    ):
        raise QualificationError(
            f"preservation {fixture_id} receipt identities differ"
        )
    if (
        require_integer(route["inputEnabledTrackCount"], f"{label}.inputEnabled", 1)
            != input_enabled
        or require_integer(route["outputEnabledTrackCount"], f"{label}.outputEnabled", 1)
            != output_enabled
    ):
        raise QualificationError(
            f"preservation {fixture_id} route track accounting differs"
        )
    route_sha = require_hex(route["routeProofSHA256"], 64, f"{label}.routeProof")
    proof = dict(route)
    del proof["routeProofSHA256"]
    if route_sha != sha256_bytes(canonical_bytes(proof)):
        raise QualificationError(
            f"preservation {fixture_id} route proof identity differs"
        )
    return route_sha


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
            "evidenceBoundary", "fixtures", "accountedEnabledTrackCount",
            "mediaPreservationGatePass",
        },
        "preservation report",
    )
    evidence_boundary = require_mapping(
        report["evidenceBoundary"], "preservation.evidenceBoundary"
    )
    require_exact_keys(
        evidence_boundary,
        {
            "mediaExecutionProducer", "packagedCandidateBindingRole",
            "candidatePreparationReplayRole", "mediaArchiveInspectionScope",
            "archivedExecutableExecutionClaimed", "fixtureHostRole",
            "actualSessionReceiptRequired", "independentAlphaOracleRequired",
        },
        "preservation.evidenceBoundary",
    )
    if (
        evidence_boundary["mediaExecutionProducer"]
        != "exact_verified_archived_mirmir_executable"
        or evidence_boundary["packagedCandidateBindingRole"]
        != "normative_output_execution_and_observation"
        or evidence_boundary["candidatePreparationReplayRole"]
        != "separate_release_candidate_preparation_replay_required"
        or evidence_boundary["mediaArchiveInspectionScope"]
        != "archive_extraction_executable_execution_and_tree_seal"
        or evidence_boundary["fixtureHostRole"]
        != "source_fixture_generation_and_source_alpha_observation_only"
    ):
        raise QualificationError("preservation evidence boundary differs")
    require_bool(
        evidence_boundary["archivedExecutableExecutionClaimed"],
        "preservation.evidenceBoundary.archivedExecutableExecutionClaimed",
        True,
    )
    require_bool(
        evidence_boundary["actualSessionReceiptRequired"],
        "preservation.evidenceBoundary.actualSessionReceiptRequired",
        True,
    )
    require_bool(
        evidence_boundary["independentAlphaOracleRequired"],
        "preservation.evidenceBoundary.independentAlphaOracleRequired",
        True,
    )
    report_identities = require_mapping(report["identities"], "preservation.identities")
    require_exact_keys(
        report_identities,
        {
            "laneContractSHA256", "captureSourceSHA256", "fixtureSourceSHA256",
            "evaluatorSHA256", "runnerSHA256", "packagedEvidenceToolSHA256",
            "releaseCandidateArchiveToolSHA256", "observerSourceSHA256",
            "packagedEvidenceRequestSHA256", "packagedEvidenceCaptureTree",
            "captureSHA256", "packagedCandidateIdentity",
        },
        "preservation.identities",
    )
    for key, value in report_identities.items():
        if key not in {"packagedCandidateIdentity", "packagedEvidenceCaptureTree"}:
            require_hex(value, 64, f"preservation.identities.{key}")
    claimed_packaged_capture_tree = require_mapping(
        report_identities["packagedEvidenceCaptureTree"],
        "preservation.identities.packagedEvidenceCaptureTree",
    )
    require_exact_keys(
        claimed_packaged_capture_tree, {"byteCount", "fileCount", "sha256"},
        "preservation.identities.packagedEvidenceCaptureTree",
    )
    require_integer(claimed_packaged_capture_tree["byteCount"], "preservation packaged capture bytes", 1)
    require_integer(claimed_packaged_capture_tree["fileCount"], "preservation packaged capture files", 1)
    require_hex(claimed_packaged_capture_tree["sha256"], 64, "preservation packaged capture SHA")
    packaged_candidate = validate_quality_package_identity(
        report_identities["packagedCandidateIdentity"], candidate
    )

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
        "captureSourceSHA256", "fixtureSourceSHA256", "evaluatorSHA256",
        "runnerSHA256", "packagedEvidenceToolSHA256",
        "releaseCandidateArchiveToolSHA256", "observerSourceSHA256",
    ):
        if require_hex(lane_capture.get(identity_key), 64, f"preservation lane contract.capture.{identity_key}") != report_identities[identity_key]:
            raise QualificationError(f"preservation lane tool identity mismatch: {identity_key}")
        tool_path = preservation_binding_path(
            evidence_root, entry, sealed_paths, f"/identities/{identity_key}"
        )
        if sha256(tool_path) != report_identities[identity_key]:
            raise QualificationError(f"preservation bound tool differs: {identity_key}")

    archive_path = preservation_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/identities/packagedCandidateIdentity/applicationArchiveSHA256",
    )
    attestation_path = preservation_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/identities/packagedCandidateIdentity/attestationSHA256",
    )
    if sha256(archive_path) != packaged_candidate["applicationArchiveSHA256"]:
        raise QualificationError("preservation packaged archive identity differs")
    attestation_bytes = attestation_path.read_bytes()
    if sha256_bytes(attestation_bytes) != packaged_candidate["attestationSHA256"]:
        raise QualificationError("preservation packaged attestation identity differs")
    attestation = require_mapping(
        load_json(attestation_path), "preservation packaged attestation"
    )
    if canonical_bytes(attestation) != attestation_bytes:
        raise QualificationError("preservation packaged attestation is noncanonical")
    application = require_mapping(
        attestation.get("application"), "preservation attested application"
    )
    source = require_mapping(
        attestation.get("source"), "preservation attested source"
    )
    runtime = require_mapping(
        attestation.get("runtime"), "preservation attested runtime"
    )
    release = require_mapping(
        attestation.get("releaseConfiguration"),
        "preservation attested release configuration",
    )
    if (
        attestation.get("schemaVersion")
        != "mirmir-v4-release-build-attestation-v1"
        or attestation.get("buildConfiguration") != "Release"
        or attestation.get("hashAlgorithm") != "sha256"
        or source.get("commit") != candidate["sourceCommit"]
        or source.get("treeIdentitySHA256")
        != candidate["sourceTreeIdentitySHA256"]
        or runtime.get("manifestSHA256")
        != candidate["runtimeManifestSHA256"]
        or runtime.get("manifestFileSHA256")
        != candidate["runtimeManifestFileSHA256"]
        or runtime.get("artifactSetSHA256")
        != candidate["runtimeArtifactSetSHA256"]
        or runtime.get("sourceRevision")
        != candidate["runtimeSourceRevision"]
        or release.get("sha256")
        != candidate["releaseConfigurationSHA256"]
        or application.get("bundleIdentifier") != candidate["bundleIdentifier"]
        or application.get("productVersion") != candidate["productVersion"]
        or application.get("productBuild") != candidate["productBuild"]
    ):
        raise QualificationError(
            "preservation packaged attestation differs from candidate"
        )

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
        if policy not in {
            "p010_field_normalization",
            "alpha_geometry",
            "process_primary_preserve_auxiliary",
        }:
            raise QualificationError(f"preservation lane contract policy is invalid: {identifier}")
        expected_fixtures[identifier] = lane_fixture

    runtime_manifest_path = preservation_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/candidate/runtimeManifestFileSHA256",
    )
    runtime_manifest = require_mapping(
        load_json(runtime_manifest_path), "preservation runtime manifest"
    )
    runtime_provenance = require_mapping(
        runtime_manifest.get("provenance"),
        "preservation runtime manifest provenance",
    )
    if (
        sha256(runtime_manifest_path) != candidate["runtimeManifestFileSHA256"]
        or sha256_bytes(
            b"ash-p06-runtime-manifest-v4\0" + canonical_bytes(runtime_manifest)
        ) != candidate["runtimeManifestSHA256"]
    ):
        raise QualificationError("preservation runtime manifest binding differs")
    runtime_provenance_sha256 = sha256_bytes(
        b"ash-p06-runtime-provenance-v4\0" + canonical_bytes(runtime_provenance)
    )

    capture_path = preservation_binding_path(
        evidence_root, entry, sealed_paths, "/identities/captureSHA256"
    )
    capture = require_mapping(load_json(capture_path), "preservation raw capture")
    require_exact_keys(
        capture,
        {
            "schemaVersion", "suiteID", "evidenceRequestSHA256",
            "evidenceNonceSHA256", "observerSourceSHA256",
            "laneContractSHA256", "fixtureManifestSHA256",
            "fixtureTreeSHA256", "fixtureSourceSHA256",
            "generatorSourceSHA256", "packagedCandidateIdentity",
            "buildConfiguration", "fixtures",
        },
        "preservation raw capture",
    )
    if capture["schemaVersion"] != MEDIA_CAPTURE_SCHEMA or capture["suiteID"] != lane_contract.get("suiteID"):
        raise QualificationError("preservation raw capture schema/suite mismatch")
    if (
        capture["laneContractSHA256"] != report_identities["laneContractSHA256"]
        or capture["packagedCandidateIdentity"] != packaged_candidate
        or capture["buildConfiguration"] != "Release"
        or capture["observerSourceSHA256"]
            != report_identities["observerSourceSHA256"]
        or capture["fixtureSourceSHA256"]
            != report_identities["fixtureSourceSHA256"]
        or capture["generatorSourceSHA256"]
            != report_identities["captureSourceSHA256"]
    ):
        raise QualificationError("preservation raw capture belongs to another candidate/configuration")
    packaged_root = capture_path.parent.parent
    if capture_path.parent.name != "capture" or packaged_root.name != "raw-capture":
        raise QualificationError("preservation packaged capture path differs")
    observed_capture_tree = packaged_capture_tree(capture_path.parent)
    if observed_capture_tree != claimed_packaged_capture_tree:
        raise QualificationError("preservation packaged capture tree differs")
    request_path = packaged_root / "observer" / "request.json"
    result_path = packaged_root / "observer" / "result.json"
    record_path = packaged_root / "capture-record.json"
    for path, name in (
        (request_path, "request"), (result_path, "result"),
        (record_path, "capture record"),
    ):
        if not path.is_file() or path.resolve() not in sealed_paths:
            raise QualificationError(f"preservation packaged {name} is absent/unsealed")
    request = require_mapping(load_json(request_path), "preservation packaged request")
    require_exact_keys(request, {
        "schemaVersion", "lane", "requestID", "nonce", "generatedAtUTC",
        "observerSourceSHA256", "contractSHA256", "packageIdentity",
        "captureEnvironment",
    }, "preservation packaged request")
    request_sha256 = sha256(request_path)
    if (
        request["schemaVersion"] != "mirmir-v4-packaged-evidence-request-v1"
        or request["lane"] != "media"
        or request["observerSourceSHA256"]
            != report_identities["observerSourceSHA256"]
        or request["contractSHA256"] != report_identities["laneContractSHA256"]
        or request["packageIdentity"] != packaged_candidate
        or request_sha256 != report_identities["packagedEvidenceRequestSHA256"]
        or request_sha256 != capture["evidenceRequestSHA256"]
        or sha256_bytes(
            require_string(request["nonce"], "preservation request nonce").encode()
        ) != capture["evidenceNonceSHA256"]
    ):
        raise QualificationError("preservation packaged request binding differs")
    environment = require_mapping(
        request["captureEnvironment"], "preservation packaged request environment"
    )
    for key, expected in (
        ("MIRMIR_V4_MEDIA_CONTRACT_SHA256", capture["laneContractSHA256"]),
        ("MIRMIR_V4_MEDIA_FIXTURE_MANIFEST_SHA256", capture["fixtureManifestSHA256"]),
        ("MIRMIR_V4_MEDIA_FIXTURE_TREE_SHA256", capture["fixtureTreeSHA256"]),
        ("MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256", capture["fixtureSourceSHA256"]),
        ("MIRMIR_V4_MEDIA_GENERATOR_SOURCE_SHA256", capture["generatorSourceSHA256"]),
        ("MIRMIR_V4_MEDIA_SOURCE_COMMIT", candidate["sourceCommit"]),
        ("MIRMIR_V4_MEDIA_SOURCE_TREE_SHA256", candidate["sourceTreeIdentitySHA256"]),
    ):
        if environment.get(key) != expected:
            raise QualificationError(
                f"preservation packaged request environment differs: {key}"
            )
    result = require_mapping(load_json(result_path), "preservation packaged result")
    record = require_mapping(load_json(record_path), "preservation packaged capture record")
    if (
        result.get("schemaVersion") != "mirmir-v4-packaged-evidence-result-v1"
        or result.get("lane") != "media"
        or result.get("requestSHA256") != request_sha256
        or result.get("observerSourceSHA256")
            != report_identities["observerSourceSHA256"]
        or result.get("contractSHA256") != report_identities["laneContractSHA256"]
        or result.get("packageIdentity") != packaged_candidate
        or result.get("captureTree") != observed_capture_tree
        or record.get("lane") != "media"
        or record.get("requestSHA256") != request_sha256
        or record.get("captureTree") != observed_capture_tree
        or require_mapping(record.get("process"), "preservation record process").get("executableSHA256")
            != packaged_candidate["applicationExecutableSHA256"]
        or record["process"].get("exitStatus") != 0
    ):
        raise QualificationError("preservation packaged result/record differs")
    raw_fixtures_list = require_list(capture["fixtures"], "preservation raw capture.fixtures")
    raw_fixtures: dict[str, dict[str, Any]] = {}
    for index, raw_value in enumerate(raw_fixtures_list):
        raw_fixture = require_mapping(raw_value, f"preservation raw capture.fixtures[{index}]")
        require_exact_keys(
            raw_fixture,
            {
                "id", "coverage", "policy", "enabledInputTrackCount",
                "accountedOutputTrackCount", "alphaOracleInput",
                "production", "input", "output",
            },
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
                "productionRouteProofSHA256",
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
        require_hex(
            fixture["productionRouteProofSHA256"],
            64,
            f"preservation {identifier}.productionRouteProofSHA256",
        )

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

        validate_preservation_alpha_oracle(
            identifier,
            raw_fixture["alphaOracleInput"],
            capture_root,
            sealed_paths,
            input_side,
            output_side,
        )
        production_route_sha = validate_preservation_production_route(
            identifier,
            raw_fixture["production"],
            candidate,
            capture,
            runtime_provenance_sha256,
            input_side,
            output_side,
        )
        if fixture["productionRouteProofSHA256"] != production_route_sha:
            raise QualificationError(
                f"preservation {identifier} report/route proof differs"
            )
        recomputed_checks = [{
            "id": "video-processing-session-deterministic-v4-route",
            "pass": True,
        }] + recompute_media_fixture(
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
            {"schemaVersion", "fixtureID", "policy", "coverage", "candidateRuntimeManifestSHA256", "inputManifestSHA256", "outputManifestSHA256", "productionRouteProofSHA256", "checks", "violationCounts", "exactSemanticVerifierPass"},
            f"preservation {identifier}.semanticVerifier",
        )
        if verifier["schemaVersion"] != MEDIA_SEMANTIC_VERIFIER_SCHEMA or verifier["fixtureID"] != identifier or verifier["policy"] != lane_fixture["policy"] or verifier["coverage"] != coverage_values:
            raise QualificationError(f"preservation semantic verifier provenance differs: {identifier}")
        if verifier["candidateRuntimeManifestSHA256"] != candidate["runtimeManifestSHA256"] or verifier["inputManifestSHA256"] != sha256(input_side["manifestPath"]) or verifier["outputManifestSHA256"] != sha256(output_side["manifestPath"]):
            raise QualificationError(f"preservation semantic verifier bindings differ: {identifier}")
        if verifier["productionRouteProofSHA256"] != production_route_sha:
            raise QualificationError(
                f"preservation semantic verifier route binding differs: {identifier}"
            )
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


def load_locked_recovery_evaluator(path: Path) -> types.ModuleType:
    """Load the evaluator only after its trusted hash binding is established."""

    module_name = (
        "recovery_qualification_v4_for_release_qualification_" + sha256(path)
    )
    specification = importlib.util.spec_from_file_location(module_name, path)
    if specification is None or specification.loader is None:
        raise QualificationError("cannot load the locked recovery evaluator")
    module = importlib.util.module_from_spec(specification)
    sys.modules[module_name] = module
    try:
        specification.loader.exec_module(module)
    except Exception as error:
        sys.modules.pop(module_name, None)
        raise QualificationError(
            f"locked recovery evaluator could not load: {error}"
        ) from error
    return module


def validate_recovery(
    report: Mapping[str, Any],
    candidate: Mapping[str, Any],
    contract: Mapping[str, Any],
    contract_sha: str,
    entry: Mapping[str, Any],
    evidence_root: Path,
    sealed_paths: set[Path],
) -> dict[str, Any]:
    """Recompute the two archived-executable recovery captures for M7."""

    label = "recovery"
    require_exact_keys(
        report,
        {
            "captureManifestSHA256",
            "captures",
            "contractSHA256",
            "execution",
            "identities",
            "recoveryGatePass",
            "releaseEligible",
            "scenarios",
            "schemaVersion",
        },
        "recovery report",
    )
    if (
        report["schemaVersion"] != contract["evidenceSchemas"][label]
        or report["schemaVersion"] != RECOVERY_REPORT_SCHEMA
        or report["contractSHA256"] != contract_sha
    ):
        raise QualificationError("recovery report schema or contract differs")
    require_bool(report["releaseEligible"], "recovery.releaseEligible", True)
    require_bool(
        report["recoveryGatePass"], "recovery.recoveryGatePass", True
    )

    report_path = checked_path(evidence_root, entry["path"], "recovery report")
    role_root = report_path.parent
    identities = require_mapping(report["identities"], "recovery.identities")
    expected_identity_keys = {
        "archiveProvenanceSHA256",
        "evaluatorSHA256",
        "observerSourceSHA256",
        "packagedEvidenceSHA256",
        "producerSourceSHA256",
        "runnerSHA256",
    }
    require_exact_keys(
        identities, expected_identity_keys, "recovery.identities"
    )
    locked_contract_sha = require_hex(
        contract.get("recoveryLaneContractSHA256"),
        64,
        "recoveryLaneContractSHA256",
    )
    if locked_contract_sha != contract_sha:
        raise QualificationError(
            "recovery lane contract identity is not release-locked"
        )
    locked_sources = require_mapping(
        contract.get("recoveryLockedSources"), "recoveryLockedSources"
    )
    require_exact_keys(
        locked_sources,
        expected_identity_keys,
        "recoveryLockedSources",
    )
    tool_paths: dict[str, Path] = {}
    for report_key in expected_identity_keys:
        require_hex(identities[report_key], 64, f"recovery.{report_key}")
        require_hex(
            locked_sources[report_key],
            64,
            f"recoveryLockedSources.{report_key}",
        )
        if identities[report_key] != locked_sources[report_key]:
            raise QualificationError(
                f"recovery source is not release-locked: {report_key}"
            )
        bound_tool = recovery_binding_path(
            evidence_root,
            entry,
            sealed_paths,
            f"/identities/{report_key}",
        )
        if sha256(bound_tool) != identities[report_key]:
            raise QualificationError(
                f"recovery sealed tool differs: {report_key}"
            )
        tool_paths[report_key] = bound_tool

    recovery_evaluator = load_locked_recovery_evaluator(
        tool_paths["evaluatorSHA256"]
    )
    lane_contract_path = recovery_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/contractSHA256",
    )
    try:
        lane_contract, lane_contract_sha = recovery_evaluator.load_contract(
            lane_contract_path,
            verify_tools=False,
        )
    except recovery_evaluator.RecoveryEvidenceError as error:
        raise QualificationError(
            f"recovery lane contract failed closed: {error}"
        ) from error
    if lane_contract_sha != contract_sha:
        raise QualificationError("recovery lane contract identity differs")

    contract_identity_fields = {
        "archiveProvenanceSHA256": "archiveProvenanceSourceSHA256",
        "evaluatorSHA256": "evaluatorSourceSHA256",
        "observerSourceSHA256": "observerSourceSHA256",
        "packagedEvidenceSHA256": "packagedEvidenceSourceSHA256",
        "producerSourceSHA256": "producerSourceSHA256",
        "runnerSHA256": "runnerSourceSHA256",
    }
    lane_capture = require_mapping(
        lane_contract["capture"], "recovery lane capture identities"
    )
    for report_key, contract_key in contract_identity_fields.items():
        if identities[report_key] != lane_capture[contract_key]:
            raise QualificationError(
                f"recovery tool identity differs: {report_key}"
            )

    execution = require_mapping(report["execution"], "recovery.execution")
    require_exact_keys(
        execution,
        {
            "applicationArchiveExecuted",
            "applicationArchiveSHA256",
            "applicationExecutableSHA256",
            "independentProcessCaptureCount",
            "kind",
            "runtimeManifestSHA256",
            "sourceCommit",
            "sourceTreeIdentitySHA256",
        },
        "recovery.execution",
    )
    if (
        execution["kind"] != "archived_application_executable"
        or execution["applicationArchiveExecuted"] is not True
        or execution["independentProcessCaptureCount"] != 2
        or execution["applicationArchiveSHA256"]
        != candidate["appBundleSHA256"]
        or execution["sourceCommit"] != candidate["sourceCommit"]
        or execution["sourceTreeIdentitySHA256"]
        != candidate["sourceTreeIdentitySHA256"]
        or execution["runtimeManifestSHA256"]
        != candidate["runtimeManifestSHA256"]
    ):
        raise QualificationError(
            "recovery archived-executable candidate binding differs"
        )
    archive_path = recovery_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/execution/applicationArchiveSHA256",
    )
    if sha256(archive_path) != candidate["appBundleSHA256"]:
        raise QualificationError("recovery application archive differs")

    capture_manifest_path = recovery_binding_path(
        evidence_root,
        entry,
        sealed_paths,
        "/captureManifestSHA256",
    )
    if sha256(capture_manifest_path) != report["captureManifestSHA256"]:
        raise QualificationError("recovery capture manifest identity differs")

    def sealed_record_artifact(
        process_root: Path,
        value: Any,
        artifact_label: str,
    ) -> Path:
        path, _ = validate_artifact(
            process_root,
            value,
            artifact_label,
        )
        if path not in sealed_paths:
            raise QualificationError(
                f"{artifact_label} is outside the sealed recovery suite"
            )
        return path

    def process_capture(
        process_root: Path,
        index: int,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        if (
            not process_root.is_dir()
            or process_root.is_symlink()
            or role_root not in process_root.parents
        ):
            raise QualificationError("recovery process root is unsafe")
        record_path = process_root / "capture-record.json"
        if record_path.resolve(strict=True) not in sealed_paths:
            raise QualificationError("recovery capture record is not sealed")
        record = require_mapping(
            load_json(record_path), f"recovery process {index} record"
        )
        if record_path.read_bytes() != canonical_bytes(record):
            raise QualificationError("recovery capture record is not canonical")
        require_exact_keys(
            record,
            {
                "artifacts",
                "captureTree",
                "contractSHA256",
                "finishedAtUTC",
                "lane",
                "observerSourceSHA256",
                "packageIdentity",
                "process",
                "requestSHA256",
                "schemaVersion",
                "startedAtUTC",
            },
            f"recovery process {index} record",
        )
        if (
            record["schemaVersion"]
            != "mirmir-v4-packaged-evidence-capture-record-v1"
            or record["lane"] != "recovery"
            or record["contractSHA256"] != contract_sha
            or record["observerSourceSHA256"]
            != identities["observerSourceSHA256"]
        ):
            raise QualificationError(
                f"recovery process {index} record binding differs"
            )
        require_string(
            record["startedAtUTC"], f"recovery process {index}.startedAtUTC"
        )
        require_string(
            record["finishedAtUTC"], f"recovery process {index}.finishedAtUTC"
        )
        artifacts = require_mapping(
            record["artifacts"], f"recovery process {index} artifacts"
        )
        artifact_names = {
            "applicationArchive",
            "attestation",
            "candidate",
            "contract",
            "observerSource",
            "packageIdentity",
            "producerSource",
            "releaseConfiguration",
            "request",
            "result",
            "stderr",
            "stdout",
        }
        require_exact_keys(
            artifacts,
            artifact_names,
            f"recovery process {index} artifacts",
        )
        paths = {
            name: sealed_record_artifact(
                process_root,
                artifacts[name],
                f"recovery process {index} {name}",
            )
            for name in artifact_names
        }
        package = validate_quality_package_identity(
            record["packageIdentity"], candidate
        )
        if (
            paths["candidate"].read_bytes() != canonical_bytes(candidate)
            or load_json(paths["candidate"]) != candidate
            or paths["packageIdentity"].read_bytes()
            != canonical_bytes(package)
            or load_json(paths["packageIdentity"]) != package
            or sha256(paths["applicationArchive"])
            != package["applicationArchiveSHA256"]
            or sha256(paths["releaseConfiguration"])
            != package["releaseConfigurationSHA256"]
            or sha256(paths["attestation"])
            != package["attestationSHA256"]
            or sha256(paths["observerSource"])
            != identities["observerSourceSHA256"]
            or sha256(paths["producerSource"])
            != identities["producerSourceSHA256"]
            or sha256(paths["contract"]) != contract_sha
        ):
            raise QualificationError(
                f"recovery process {index} packaged artifact differs"
            )

        request = require_mapping(
            load_json(paths["request"]), f"recovery process {index} request"
        )
        result = require_mapping(
            load_json(paths["result"]), f"recovery process {index} result"
        )
        if (
            paths["request"].read_bytes() != canonical_bytes(request)
            or paths["result"].read_bytes() != canonical_bytes(result)
        ):
            raise QualificationError(
                f"recovery process {index} request/result is not canonical"
            )
        require_exact_keys(
            request,
            {
                "captureEnvironment",
                "contractSHA256",
                "generatedAtUTC",
                "lane",
                "nonce",
                "observerSourceSHA256",
                "packageIdentity",
                "requestID",
                "schemaVersion",
            },
            f"recovery process {index} request",
        )
        request_sha = sha256(paths["request"])
        nonce = require_string(
            request["nonce"], f"recovery process {index} nonce"
        )
        require_hex(nonce, 64, f"recovery process {index} nonce")
        require_mapping(
            request["captureEnvironment"],
            f"recovery process {index} captureEnvironment",
        )
        require_string(
            request["requestID"], f"recovery process {index} requestID"
        )
        require_string(
            request["generatedAtUTC"],
            f"recovery process {index} generatedAtUTC",
        )
        if (
            request["schemaVersion"]
            != "mirmir-v4-packaged-evidence-request-v1"
            or request["lane"] != "recovery"
            or request["contractSHA256"] != contract_sha
            or request["observerSourceSHA256"]
            != identities["observerSourceSHA256"]
            or request["packageIdentity"] != package
            or record["requestSHA256"] != request_sha
        ):
            raise QualificationError(
                f"recovery process {index} request binding differs"
            )
        bound_request = recovery_binding_path(
            evidence_root,
            entry,
            sealed_paths,
            f"/captures/{index}/requestSHA256",
        )
        if bound_request != paths["request"] or sha256(bound_request) != request_sha:
            raise QualificationError(
                f"recovery process {index} bound request differs"
            )

        require_exact_keys(
            result,
            {
                "captureManifest",
                "captureTree",
                "checks",
                "contractSHA256",
                "lane",
                "observerSourceSHA256",
                "packageIdentity",
                "process",
                "requestID",
                "requestSHA256",
                "runtime",
                "schemaVersion",
            },
            f"recovery process {index} result",
        )
        if (
            result["schemaVersion"]
            != "mirmir-v4-packaged-evidence-result-v1"
            or result["lane"] != "recovery"
            or result["requestID"] != request["requestID"]
            or result["requestSHA256"] != request_sha
            or result["contractSHA256"] != contract_sha
            or result["observerSourceSHA256"]
            != identities["observerSourceSHA256"]
            or result["packageIdentity"] != package
        ):
            raise QualificationError(
                f"recovery process {index} result binding differs"
            )
        expected_stdout = (
            recovery_evaluator.packaged_evidence.RESULT_PREFIX
            + base64.b64encode(paths["result"].read_bytes())
            + b"\n"
        )
        if paths["stdout"].read_bytes() != expected_stdout:
            raise QualificationError(
                f"recovery process {index} stdout/result differs"
            )
        process_receipt = require_mapping(
            record["process"], f"recovery process {index} receipt"
        )
        require_exact_keys(
            process_receipt,
            {"executableSHA256", "exitStatus"},
            f"recovery process {index} receipt",
        )
        if (
            process_receipt["executableSHA256"]
            != package["applicationExecutableSHA256"]
            or process_receipt["exitStatus"] != 0
        ):
            raise QualificationError(
                f"recovery process {index} archived executable failed"
            )
        observer_process = require_mapping(
            result["process"], f"recovery process {index} observer process"
        )
        require_exact_keys(
            observer_process,
            {
                "bundlePath",
                "executablePath",
                "executableSHA256",
                "parentProcessID",
                "processID",
            },
            f"recovery process {index} observer process",
        )
        if (
            observer_process["executableSHA256"]
            != package["applicationExecutableSHA256"]
            or require_integer(
                observer_process["processID"],
                f"recovery process {index}.processID",
                1,
            )
            < 1
            or require_integer(
                observer_process["parentProcessID"],
                f"recovery process {index}.parentProcessID",
                1,
            )
            < 1
        ):
            raise QualificationError(
                f"recovery process {index} observer identity differs"
            )
        runtime = require_mapping(
            result["runtime"], f"recovery process {index} runtime"
        )
        require_exact_keys(
            runtime,
            {
                "manifestSHA256",
                "releaseStatus",
                "runtimeID",
                "sourceRevision",
                "trustRootConfigured",
            },
            f"recovery process {index} runtime",
        )
        if (
            runtime["runtimeID"] != "ash-p06-deterministic-v4"
            or runtime["releaseStatus"] != "release_qualified"
            or runtime["manifestSHA256"] != package["runtimeManifestSHA256"]
            or runtime["sourceRevision"] != package["runtimeSourceRevision"]
            or runtime["trustRootConfigured"] is not True
        ):
            raise QualificationError(
                f"recovery process {index} runtime differs"
            )
        checks = require_mapping(
            result["checks"], f"recovery process {index} checks"
        )
        require_exact_keys(
            checks,
            {
                "exactExecutableIdentity",
                "normativePixelCapture",
                "productionP06Load",
                "signedBuildClaims",
            },
            f"recovery process {index} checks",
        )
        if any(value is not True for value in checks.values()):
            raise QualificationError(
                f"recovery process {index} checks failed"
            )
        capture_root = process_root / "capture"
        capture_path = capture_root / "capture.json"
        if capture_path.resolve(strict=True) not in sealed_paths:
            raise QualificationError(
                f"recovery process {index} capture is not sealed"
            )
        observed_tree = packaged_capture_tree(capture_root)
        if observed_tree != record["captureTree"] or observed_tree != result["captureTree"]:
            raise QualificationError(
                f"recovery process {index} capture tree differs"
            )
        manifest_descriptor = require_mapping(
            result["captureManifest"],
            f"recovery process {index} capture descriptor",
        )
        require_exact_keys(
            manifest_descriptor,
            {"byteCount", "fileName", "sha256"},
            f"recovery process {index} capture descriptor",
        )
        if (
            manifest_descriptor["fileName"] != "capture.json"
            or manifest_descriptor["byteCount"] != capture_path.stat().st_size
            or manifest_descriptor["sha256"] != sha256(capture_path)
        ):
            raise QualificationError(
                f"recovery process {index} capture descriptor differs"
            )
        context = {
            "root": process_root,
            "captureRoot": capture_root,
            "capturePath": capture_path,
            "capture": load_json(capture_path),
            "record": record,
            "request": request,
            "result": result,
            "package": package,
            "producerSourceSHA256": identities["producerSourceSHA256"],
            "nonceSHA256": sha256_bytes(nonce.encode("ascii")),
        }
        try:
            return recovery_evaluator.evaluate_packaged_capture(
                context,
                lane_contract,
                contract_sha,
            )
        except recovery_evaluator.RecoveryEvidenceError as error:
            raise QualificationError(
                f"recovery process {index} causal replay failed: {error}"
            ) from error

    captures = require_list(report["captures"], "recovery.captures")
    if len(captures) != 2:
        raise QualificationError("recovery requires exactly two captures")
    evaluated: list[dict[str, Any]] = []
    descriptor_sets: list[list[dict[str, Any]]] = []
    for index, process_name in enumerate(("process-a", "process-b")):
        summary, descriptors = process_capture(
            role_root / "captures" / process_name,
            index,
        )
        evaluated.append(summary)
        descriptor_sets.append(descriptors)
        if captures[index] != summary:
            raise QualificationError(
                f"recovery process {index} summary differs from raw replay"
            )
    first, second = evaluated
    if not (
        first["requestID"] != second["requestID"]
        and first["requestSHA256"] != second["requestSHA256"]
        and first["nonceSHA256"] != second["nonceSHA256"]
        and first["processID"] != second["processID"]
    ):
        raise QualificationError(
            "recovery captures are not independent processes and requests"
        )
    for key in (
        "applicationArchiveSHA256",
        "applicationExecutableSHA256",
        "observerSourceSHA256",
        "producerSourceSHA256",
        "runtimeManifestSHA256",
        "sourceCommit",
        "sourceTreeIdentitySHA256",
    ):
        if first[key] != second[key]:
            raise QualificationError(f"cross-process recovery {key} differs")

    cross_process_rows: list[dict[str, Any]] = []
    for left, right in zip(first["scenarios"], second["scenarios"]):
        common_keys = (
            "containedFailureCode",
            "coverageID",
            "evidenceKind",
            "id",
            "outcome",
        )
        if any(left[key] != right[key] for key in common_keys):
            raise QualificationError(
                "cross-process recovery scenario contract differs"
            )
        if left["evidenceKind"] == "durable_state_derivation":
            output_keys = (
                "referenceDerivationSHA256",
                "resumedDerivationSHA256",
            )
        elif left["evidenceKind"] == "scenario_media_output":
            output_keys = (
                "referenceOutputSHA256",
                "resumedOutputSHA256",
                "referenceSemanticSHA256",
                "resumedSemanticSHA256",
            )
        else:
            output_keys = ()
        if any(left[key] != right[key] for key in output_keys):
            raise QualificationError(
                f"cross-process recovery output differs: {left['id']}"
            )
        cross_process_rows.append(
            {
                "id": left["id"],
                "evidenceKind": left["evidenceKind"],
                "repeatIdentityPass": True,
                "crossProcessIdentityPass": True,
            }
        )
    if report["scenarios"] != cross_process_rows:
        raise QualificationError(
            "recovery cross-process claims differ from raw replay"
        )

    manifest_artifacts: list[dict[str, Any]] = []
    for process_name, descriptors in zip(
        ("process-a", "process-b"), descriptor_sets
    ):
        for item in descriptors:
            manifest_artifacts.append(
                {
                    "path": (
                        f"captures/{process_name}/capture/{item['path']}"
                    ),
                    "byteCount": item["byteCount"],
                    "sha256": item["sha256"],
                }
            )
    manifest_artifacts.sort(key=lambda item: item["path"])
    expected_manifest = {
        "schemaVersion": RECOVERY_CAPTURE_MANIFEST_SCHEMA,
        "artifacts": manifest_artifacts,
        "artifactSetSHA256": recovery_artifact_set_sha(manifest_artifacts),
    }
    if load_json(capture_manifest_path) != expected_manifest:
        raise QualificationError(
            "recovery capture artifact manifest differs from raw replay"
        )
    for artifact_index, artifact in enumerate(manifest_artifacts):
        path, _ = validate_artifact(
            role_root,
            artifact,
            f"recovery capture manifest[{artifact_index}]",
        )
        if path not in sealed_paths:
            raise QualificationError(
                "recovery capture manifest references an unsealed artifact"
            )
    if execution != {
        "kind": "archived_application_executable",
        "applicationArchiveExecuted": True,
        "independentProcessCaptureCount": 2,
        "applicationArchiveSHA256": first["applicationArchiveSHA256"],
        "applicationExecutableSHA256": first[
            "applicationExecutableSHA256"
        ],
        "sourceCommit": first["sourceCommit"],
        "sourceTreeIdentitySHA256": first["sourceTreeIdentitySHA256"],
        "runtimeManifestSHA256": first["runtimeManifestSHA256"],
    }:
        raise QualificationError(
            "recovery execution summary differs from raw captures"
        )
    identical = sum(
        row["outcome"] == "identical_resumed_output"
        for row in first["scenarios"]
    )
    return {
        "scenarioCount": len(first["scenarios"]),
        "identicalResumptionCount": identical,
        "containedFailureCount": len(first["scenarios"]) - identical,
        "coverage": [row["coverageID"] for row in first["scenarios"]],
        "applicationArchiveSHA256": first["applicationArchiveSHA256"],
        "applicationExecutableSHA256": first[
            "applicationExecutableSHA256"
        ],
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
            "acceptanceProviders",
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
    acceptance_providers = require_mapping(
        lane_contract["acceptanceProviders"],
        "notarized smoke lane acceptance providers",
    )
    if acceptance_providers != {
        "notarytool": {
            "requiredArtifacts": [],
            "requiredCommandRecords": ["notary_info", "notary_log"],
            "requiredTools": ["notarytool"],
        },
        "xcode_archive": {
            "requiredArtifacts": ["xcodeArchiveInfo"],
            "requiredCommandRecords": ["xcode_export_notarized_app", "xcode_export_archive"],
            "requiredTools": ["xcodebuild"],
        },
    }:
        raise QualificationError("notarized smoke acceptance-provider policy differs")
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
            "requiredArchitectures",
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
        or lane_signing["requiredArchitectures"] != ["arm64", "x86_64"]
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
        "notarization_ticket_acceptance": "apple_notary_service",
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

    notary_submission = require_mapping(
        raw_capture["notarySubmission"],
        "notarized smoke notary submission",
    )
    acceptance_provider = require_string(
        notary_submission.get("provider"),
        "notarized smoke notary submission.provider",
    )
    if acceptance_provider not in acceptance_providers:
        raise QualificationError("notarized smoke acceptance provider is unsupported")
    if acceptance_provider == "notarytool":
        require_exact_keys(
            notary_submission,
            {"provider", "id", "submittedArchiveName"},
            "notarized smoke notary submission",
        )
    else:
        require_exact_keys(
            notary_submission,
            {
                "provider",
                "id",
                "submittedArchiveName",
                "sourceArchivePath",
                "submissionRelativePath",
            },
            "notarized smoke notary submission",
        )
        source_archive = Path(
            require_string(
                notary_submission["sourceArchivePath"],
                "notarized smoke Xcode source archive path",
            )
        )
        if not source_archive.is_absolute() or source_archive.suffix != ".xcarchive":
            raise QualificationError("notarized smoke Xcode source archive path differs")
    submission_id = require_string(
        notary_submission.get("id"),
        "notarized smoke notary submission.id",
    ).lower()
    try:
        if str(uuid.UUID(submission_id)) != submission_id:
            raise QualificationError("notarized smoke submission UUID is noncanonical")
    except ValueError as error:
        raise QualificationError("notarized smoke submission ID is not a UUID") from error
    require_string(
        notary_submission.get("submittedArchiveName"),
        "notarized smoke submitted archive name",
    )
    if acceptance_provider == "xcode_archive" and require_string(
        notary_submission["submissionRelativePath"],
        "notarized smoke Xcode submission relative path",
    ).upper() != f"SUBMISSIONS/{submission_id.upper()}":
        raise QualificationError("notarized smoke Xcode submission receipt path differs")

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
        *acceptance_providers[acceptance_provider]["requiredArtifacts"],
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

    tool_manifest = require_mapping(
        load_json(raw_artifact_paths["toolManifest"]),
        "notarized smoke tool identity manifest",
    )
    if tool_manifest.get("schemaVersion") != "mirmir-ash-v4-notarized-smoke-tool-identities-v1":
        raise QualificationError("notarized smoke tool identity schema differs")
    tool_rows = require_mapping(
        tool_manifest.get("tools"),
        "notarized smoke tool identities",
    )
    expected_tool_names = {
        "app",
        "codesign",
        "ditto",
        "python3",
        "spctl",
        "stapler",
        "xcrun",
        *acceptance_providers[acceptance_provider]["requiredTools"],
    }
    if set(tool_rows) != expected_tool_names:
        raise QualificationError("notarized smoke tool identity set differs")
    for tool_name, raw_tool in tool_rows.items():
        tool = require_mapping(raw_tool, f"notarized smoke tool {tool_name}")
        require_exact_keys(tool, {"path", "sha256"}, f"notarized smoke tool {tool_name}")
        require_string(tool["path"], f"notarized smoke tool {tool_name}.path")
        require_hex(tool["sha256"], 64, f"notarized smoke tool {tool_name}.sha256")
    if tool_rows["app"]["sha256"] != identities["applicationExecutableSHA256"]:
        raise QualificationError("notarized smoke app tool identity differs")
    for tool_name, expected_path in lane_tools.items():
        if tool_rows[tool_name]["path"] != expected_path:
            raise QualificationError(f"notarized smoke locked tool path differs: {tool_name}")

    common_record_ids = [
        require_string(value, "notarized smoke required command record")
        for value in require_list(lane_contract["requiredCommandRecords"], "notarized smoke required command records")
    ]
    expected_common_record_ids = [
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
    if common_record_ids != expected_common_record_ids:
        raise QualificationError("notarized smoke required command record order differs")
    provider_record_ids = [
        require_string(value, "notarized smoke provider command record")
        for value in require_list(
            acceptance_providers[acceptance_provider]["requiredCommandRecords"],
            "notarized smoke provider command records",
        )
    ]
    required_record_ids = [*common_record_ids, *provider_record_ids]
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
    if receipt["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-replay-receipt-v1":
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
    expected_action_records = {
        "notarization_ticket_acceptance": provider_record_ids,
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
        if transcript["schemaVersion"] != "mirmir-ash-v4-notarized-smoke-action-transcript-v1":
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
        if source_record_ids != expected_action_records[identifier]:
            raise QualificationError(f"notarized smoke action source records differ: {identifier}")
        claims = require_mapping(transcript["claims"], f"notarized smoke action {identifier}.claims")
        if claims.get("candidateArchiveSHA256") != candidate["appBundleSHA256"]:
            raise QualificationError(f"notarized smoke transcript observed another app: {identifier}")
        if claims.get("runtimeManifestSHA256") != candidate["runtimeManifestSHA256"]:
            raise QualificationError(f"notarized smoke transcript observed another runtime: {identifier}")
        if identifier == "notarization_ticket_acceptance":
            if claims.get("acceptanceProvider") != acceptance_provider:
                raise QualificationError("notarized smoke acceptance-provider claim differs")
            if str(claims.get("submissionID", "")).lower() != submission_id:
                raise QualificationError("notarized smoke submission claim differs")
            if claims.get("status") != "Accepted" or claims.get("issueCount") != 0:
                raise QualificationError("notarized smoke Apple acceptance claim differs")
            require_hex(
                claims.get("archiveSHA256"),
                64,
                "notarized smoke Apple submission archive SHA-256",
            )
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
    return {
        "actionCount": len(actions),
        "actions": sorted(seen),
        "acceptanceProvider": acceptance_provider,
        "applicationArchiveSHA256": candidate["appBundleSHA256"],
        "applicationExecutableSHA256": identities[
            "applicationExecutableSHA256"
        ],
    }


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


def evaluate_candidate(
    candidate_path: Path,
    evidence_root: Path,
    contract_path: Path = DEFAULT_CONTRACT,
    *,
    trust_root_path: Path,
    expected_trust_root_sha256: str,
) -> dict[str, Any]:
    evidence_root = evidence_root.expanduser().resolve(strict=True)
    if not evidence_root.is_dir():
        raise QualificationError("evidence root is not a directory")
    contract_path = contract_path.expanduser().resolve(strict=True)
    trust = establish_external_trust(
        trust_root_path,
        expected_trust_root_sha256,
        contract_path,
    )
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
    for key in ("applicationArchiveSHA256", "applicationExecutableSHA256"):
        observed = {
            role: summaries[role][key]
            for role in (
                "quality",
                "same_scope_performance",
                "cpu_metal_parity",
                "recovery",
                "notarized_smoke",
            )
        }
        if len(set(observed.values())) != 1:
            raise QualificationError(
                "quality, performance, parity, recovery, and notarized-smoke evidence "
                f"use different {key}"
            )
    candidate_identity = sha256_bytes(canonical_bytes(candidate))
    evidence_set_identity = sha256_bytes(canonical_bytes(evidence_identities))
    qualification_identity = sha256_bytes(
        canonical_bytes(
            {
                "candidateIdentitySHA256": candidate_identity,
                "contractSHA256": contract_identity,
                "evidenceSetSHA256": evidence_set_identity,
                "externalTrust": trust,
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
            **trust,
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
    *,
    trust_root_path: Path,
    expected_trust_root_sha256: str,
) -> dict[str, Any]:
    actual = require_mapping(load_json(report_path.expanduser().resolve(strict=True)), "qualification report")
    recomputed = evaluate_candidate(
        candidate_path,
        evidence_root,
        contract_path,
        trust_root_path=trust_root_path,
        expected_trust_root_sha256=expected_trust_root_sha256,
    )
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
        subparser.add_argument("--trust-root", type=Path, required=True)
        subparser.add_argument("--trust-root-sha256", required=True)
        if name == "evaluate":
            subparser.add_argument("--output", type=Path, required=True)
        else:
            subparser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "evaluate":
        report = evaluate_candidate(
            arguments.candidate,
            arguments.evidence_root,
            arguments.contract,
            trust_root_path=arguments.trust_root,
            expected_trust_root_sha256=arguments.trust_root_sha256,
        )
        write_json(arguments.output.expanduser().resolve(), report)
        print(arguments.output.expanduser().resolve())
        return 0
    if arguments.command == "verify":
        verify_report(
            arguments.report,
            arguments.candidate,
            arguments.evidence_root,
            arguments.contract,
            trust_root_path=arguments.trust_root,
            expected_trust_root_sha256=arguments.trust_root_sha256,
        )
        print(arguments.report.expanduser().resolve())
        return 0
    raise AssertionError(arguments.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (QualificationError, KeyError, TypeError, OSError) as error:
        print(f"release qualification failed closed: {error}", file=sys.stderr)
        raise SystemExit(2)
