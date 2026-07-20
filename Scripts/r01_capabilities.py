#!/usr/bin/env python3
"""Validate and deterministically aggregate closed R01 capability reports."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable

from phase_evidence import validate_json_schema_instance
from r01_preregistration import PreregistrationVerifier, check_materialized_fixtures


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HOST_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r01-host-report-v1.json")
AGGREGATE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-capability-aggregate-v1.json"
)
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r01/records/preregistration.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-preregistration-v1.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-fixture-catalog-v1.json"
)
AGGREGATE_JSON_PATH = Path("project-notes/apple-upscale-capabilities.json")
AGGREGATE_MARKDOWN_PATH = Path("project-notes/apple-upscale-capability-report.md")

SCHEMA_VERSION = "1.0"
ROADMAP_VERSION = "1.0.1"
PHASE_ID = "R01"
HOST_SCHEMA_SHA256 = "4e771a00bf0d4eeeb3a6e26299338d47d386c6f55a1746d6ac25c49030b57866"
AGGREGATE_SCHEMA_SHA256 = (
    "50a09e443970f8c9dd830c09b86743ebd4adeaad3db2e5c1ea46cee3dc842eb2"
)
MAX_EVIDENCE_FILE_BYTES = 25 * 1024 * 1024
MAX_PHASE_EVIDENCE_BYTES = 100 * 1024 * 1024

ANCHORS = ("oldest-supported", "m3-air", "pro-max", "core-ai")
RAW_REPORT_PATHS = {
    anchor: Path(f"project-notes/evidence/r01/hosts/anchor-{anchor}.json")
    for anchor in ANCHORS
}
REQUIRED_IMPLEMENTATION_PATHS = (
    Path("Scripts/r01_capabilities.py"),
    Path("Scripts/r01_preregistration.py"),
    Path("Scripts/phase_evidence.py"),
    Path("Scripts/run-r01-capability-probe.sh"),
    Path("R01CapabilityWorker/main.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityProbe.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilitySupportProbe.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityCompileProbe.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityExecutor.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityFixtureContract.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveContext.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveErrors.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityNativeAdapters.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityRawReport.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportModels.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLegacyAdapters.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportWriter.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveProducer.swift"),
    Path("Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityWorker.swift"),
    Path("MirmirTests/AppleUpscaleCapabilityProbeTests.swift"),
    Path("MirmirTests/AppleUpscaleCapabilityLiveProbeTests.swift"),
    Path("project.yml"),
    Path("Mirmir.xcodeproj/project.pbxproj"),
    HOST_SCHEMA_PATH,
    AGGREGATE_SCHEMA_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
)
CAPABILITY_IDENTITIES = (
    ("A01", "VideoToolbox", "VTSuperResolutionScaler", "primary_scaler"),
    ("A02", "VideoToolbox", "VTLowLatencySuperResolutionScaler", "primary_scaler"),
    (
        "A03",
        "VideoToolbox",
        "VTLowLatencyFrameInterpolation spatial scaling",
        "cadence_transform",
    ),
    ("A04", "VideoToolbox", "VTTemporalNoiseFilter", "support_filter"),
    ("A05", "VideoToolbox", "VTOpticalFlow", "temporal_analyzer"),
    ("A06", "VideoToolbox", "VTPixelTransferSession", "primary_scaler"),
    ("A07", "MetalFX", "Spatial scaler", "primary_scaler"),
    ("A08", "MetalFX", "Temporal scaler", "primary_scaler"),
    ("A09", "MetalFX", "Temporal denoised scaler", "primary_scaler"),
    ("A10", "MetalFX", "Frame interpolator", "cadence_transform"),
    ("A11", "MPS", "MPSImageLanczosScale", "primary_scaler"),
    ("A12", "MPS", "MPSImageBilinearScale", "primary_scaler"),
    ("A13", "MPS", "Guided/detail/artifact filters", "support_filter"),
    ("A14", "CoreImage", "Lanczos/Bicubic scale", "primary_scaler"),
    ("A15", "CoreImage", "EdgePreserveUpsample", "support_filter"),
    ("A16", "Accelerate", "vImage Lanczos-3/Lanczos-5/custom", "primary_scaler"),
    ("A17", "Metal", "Custom compute", "support_filter"),
    ("A18", "CoreAI", "Custom model runtime", "analysis_runtime"),
)
CAPABILITY_IDS = tuple(value[0] for value in CAPABILITY_IDENTITIES)
FIXTURE_IDS = (
    "scaler-720p",
    "scaler-1080p",
    "support-frame",
    "support-guidance",
    "support-history",
    "temporal-frame-0",
    "temporal-frame-1",
    "cadence-frame-0",
    "cadence-frame-1",
    "analysis-proxy",
    "analysis-probe-model",
)
CLASS_FIXTURES = {
    "primary_scaler": ("scaler-720p", "scaler-1080p"),
    "support_filter": ("support-frame", "support-guidance", "support-history"),
    "temporal_analyzer": ("temporal-frame-0", "temporal-frame-1"),
    "cadence_transform": ("cadence-frame-0", "cadence-frame-1"),
    "analysis_runtime": ("analysis-proxy", "analysis-probe-model"),
}
SUPPORT_FILTER_FIXTURES = {
    "A04": ("support-frame", "support-history"),
    "A13": ("support-frame", "support-guidance", "support-history"),
    "A15": ("support-frame", "support-guidance"),
    "A17": ("support-frame", "support-guidance", "support-history"),
}
COMPILE_STATES = frozenset({"available", "conditional", "unavailable"})
RUNTIME_DISPOSITIONS = frozenset(
    {
        "runnable",
        "restricted",
        "diagnostic_only",
        "unsupported",
        "unavailable",
        "rejected",
    }
)
REASON_CODES = frozenset(
    {
        "api_absent",
        "os_too_old",
        "sdk_too_old",
        "hardware_unsupported",
        "model_unavailable",
        "model_acquisition_failed",
        "input_contract_unsatisfied",
        "runtime_probe_failed",
        "resource_limit",
        "not_public_api",
        "not_applicable",
    }
)
FAILURE_CLASSES = frozenset(
    {
        "timeout",
        "unsupported_contract",
        "setup_failure",
        "processing_failure",
        "resource_failure",
    }
)
COMMON_METRICS = (
    "initialization_seconds",
    "acquisition_seconds",
    "median_wall_seconds",
    "p95_wall_seconds",
    "throughput_units_per_second",
    "peak_resident_memory_delta_bytes",
)
CLASS_METRICS = {
    "primary_scaler": ("frame_rate",),
    "support_filter": (
        "preserved_dimensions",
        "preserved_format",
        "required_guidance",
    ),
    "temporal_analyzer": (
        "flow_dimensions",
        "flow_format",
        "confidence_available",
    ),
    "cadence_transform": (
        "generated_frame_count",
        "output_cadence",
        "timestamp_contract",
    ),
    "analysis_runtime": (
        "load_seconds",
        "specialization_seconds",
        "inference_seconds",
        "zero_copy_disposition",
        "stateful_execution_disposition",
    ),
}
PRIMARY_SCALER_OBSERVATIONS = (
    {
        "fixture_id": "scaler-720p",
        "input_dimensions": "1280x720",
        "output_dimensions": "1920x1080",
        "scale": 1.5,
        "output_format": "420v",
    },
    {
        "fixture_id": "scaler-1080p",
        "input_dimensions": "1920x1080",
        "output_dimensions": "3840x2160",
        "scale": 2.0,
        "output_format": "420v",
    },
)
ALL_CLASS_METRICS = tuple(
    metric for probe_class in CLASS_METRICS.values() for metric in probe_class
)
ALL_METRICS = COMMON_METRICS + ALL_CLASS_METRICS
METRIC_UNITS = {
    "initialization_seconds": "seconds",
    "acquisition_seconds": "seconds",
    "median_wall_seconds": "seconds",
    "p95_wall_seconds": "seconds",
    "throughput_units_per_second": "units_per_second",
    "peak_resident_memory_delta_bytes": "bytes",
    "frame_rate": "frames_per_second",
    "preserved_dimensions": "pixels",
    "preserved_format": "pixel_format",
    "required_guidance": "boolean",
    "flow_dimensions": "pixels",
    "flow_format": "pixel_format",
    "confidence_available": "boolean",
    "generated_frame_count": "frames",
    "output_cadence": "frames_per_second",
    "timestamp_contract": "timestamp_contract",
    "load_seconds": "seconds",
    "specialization_seconds": "seconds",
    "inference_seconds": "seconds",
    "zero_copy_disposition": "disposition",
    "stateful_execution_disposition": "disposition",
}
QUALIFICATION_VALUE = "not_evaluated_in_r01"

HOST_REPORT_KEYS = (
    "schema_version",
    "roadmap_version",
    "phase_id",
    "source_commit",
    "source_tree",
    "generated_at",
    "anchor",
    "host",
    "implementation_bindings",
    "preregistration_binding",
    "fixture_bindings",
    "capabilities",
    "limitations",
)
HOST_KEYS = (
    "host_id",
    "model_identifier",
    "chip",
    "memory_bytes",
    "os_version",
    "os_build",
    "xcode_version",
    "xcode_build",
    "sdk_version",
    "sdk_build",
    "hardware_classes",
)
CAPABILITY_KEYS = (
    "id",
    "family",
    "method",
    "probe_class",
    "compile_state",
    "runtime_disposition",
    "reason_code",
    "failure_class",
    "public_api_status",
    "hardware_eligibility",
    "platform_requirements",
    "support_query",
    "input_contract",
    "state_history",
    "model_readiness",
    "offline_suitability",
    "primary_scaler_observations",
    "measurements",
    "product_qualification",
    "backend_eligibility",
    "quality_evaluation",
    "limitations",
)
MEASUREMENT_KEYS = (
    "session_count",
    "warmup_units_per_session",
    "measured_units_per_session",
    "timeout_seconds_per_session",
    "sessions",
    "metrics",
    "repeatability",
)
PREREGISTRATION_KEYS = (
    "anchor_assignments",
    "capabilities",
    "class_metrics",
    "execution_controls",
    "failure_classes",
    "fixture_catalog",
    "live_controls",
    "measurement_boundary",
    "nonapplicable_metric_policy",
    "phase_id",
    "preregistration_state",
    "roadmap_version",
    "schema_version",
    "stop_rules",
)
ANCHOR_ASSIGNMENT_KEYS = ("anchor", "assignment_state", "contract", "host_profile")
ASSIGNED_HOST_PROFILE_KEYS = (
    "host_id",
    "model_identifier",
    "hardware_class",
    "chip",
    "memory_bytes",
    "os_version",
    "os_build",
    "xcode_version",
    "xcode_build",
    "sdk_version",
    "sdk_build",
)
FIXTURE_CATALOG_KEYS = ("fixture_sets", "fixtures", "generator_contract", "phase_id", "schema_version")
FIXTURE_CATALOG_RECORD_KEYS = (
    "byte_count",
    "color_contract",
    "content_sha256",
    "dimensions",
    "frame_index",
    "generator",
    "id",
    "materialization_path",
    "media_kind",
    "model_identity",
    "pixel_format",
    "role",
    "scale_output",
    "status",
    "timing",
)

GIT_OBJECT_PATTERN = re.compile(r"^(?!0{40}$)[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RFC3339_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)
PRIVATE_KEYS = frozenset(
    {
        "account",
        "account_id",
        "hardware_uuid",
        "home_directory",
        "hostname",
        "ip_address",
        "mac_address",
        "serial",
        "serial_number",
        "user_name",
        "username",
    }
)
EMAIL_PATTERN = re.compile(
    r"(?i)(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
)
PRIVATE_PATH_PATTERN = re.compile(r"(?i)(?:file://|/Users/|/home/)")
LABELED_PRIVATE_PATTERN = re.compile(
    r"(?i)(?:serial(?: number)?|hardware uuid|account(?: id)?|username)\s*[:=]"
)


class DuplicateKeyError(ValueError):
    """Raised when JSON contains an ambiguous duplicate member."""


def decode_json_bytes(payload: bytes, context: str) -> dict[str, Any]:
    def closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise DuplicateKeyError(f"{context}: duplicate JSON key {key!r}")
            value[key] = item
        return value

    def reject_nonfinite(token: str) -> object:
        raise ValueError(f"{context}: non-finite JSON number {token!r} is prohibited")

    try:
        decoded = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=closed_object,
            parse_constant=reject_nonfinite,
        )
    except UnicodeDecodeError as error:
        raise ValueError(f"{context}: JSON is not UTF-8") from error
    if not isinstance(decoded, dict):
        raise ValueError(f"{context}: top-level JSON value must be an object")
    return decoded


def read_json(path: Path, context: str | None = None) -> dict[str, Any]:
    return decode_json_bytes(path.read_bytes(), context or str(path))


def canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def require_exact_keys(
    value: object, expected: Iterable[str], context: str, errors: list[str]
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        errors.append(f"{context} must be an object")
        return None
    actual = set(value)
    required = set(expected)
    if actual != required:
        errors.append(
            f"{context} keys differ from the closed schema; "
            f"missing={sorted(required - actual)!r}, extra={sorted(actual - required)!r}"
        )
    return value


def safe_relative_path(value: object, context: str, errors: list[str]) -> Path | None:
    if not isinstance(value, str) or not value:
        errors.append(f"{context} must be a non-empty repository-relative path")
        return None
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts or value != pure.as_posix() or "\\" in value:
        errors.append(f"{context} must be a normalized repository-relative path")
        return None
    return Path(*pure.parts)


def symlink_component(root: Path, relative: Path) -> Path | None:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return current
    return None


def validate_local_model_path(
    root: Path, value: object, context: str, errors: list[str]
) -> Path | None:
    if not isinstance(value, str) or not value:
        errors.append(f"{context} must be a non-empty path under .r01-local-assets/")
        return None
    if "\\" in value or "\x00" in value or "//" in value:
        errors.append(f"{context} must be a normalized POSIX path")
        return None
    pure = PurePosixPath(value)
    if (
        pure.is_absolute()
        or value != pure.as_posix()
        or any(part in {"", ".", ".."} for part in pure.parts)
        or len(pure.parts) < 2
        or pure.parts[0] != ".r01-local-assets"
    ):
        errors.append(f"{context} must be normalized within .r01-local-assets/")
        return None
    relative = Path(*pure.parts)
    link = symlink_component(root, relative)
    if link is not None:
        errors.append(f"{context} contains symbolic-link component {link}")
        return None
    local_root = (root / ".r01-local-assets").resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(local_root)
    except ValueError:
        errors.append(f"{context} escapes .r01-local-assets/")
        return None
    return relative


def check_privacy(value: object, context: str, errors: list[str]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key.casefold() in PRIVATE_KEYS:
                errors.append(f"{context}.{key} is a prohibited private field")
            check_privacy(item, f"{context}.{key}", errors)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            check_privacy(item, f"{context}[{index}]", errors)
    elif isinstance(value, str):
        if any(ord(character) < 0x20 for character in value):
            errors.append(f"{context} contains a control character")
        if EMAIL_PATTERN.search(value):
            errors.append(f"{context} contains an email address")
        if PRIVATE_PATH_PATTERN.search(value):
            errors.append(f"{context} contains a private absolute path")
        if LABELED_PRIVATE_PATTERN.search(value):
            errors.append(f"{context} contains a labeled private identifier")


def parse_rfc3339(value: object, context: str, errors: list[str]) -> datetime | None:
    if not isinstance(value, str) or RFC3339_PATTERN.fullmatch(value) is None:
        errors.append(f"{context} must be an RFC3339 timestamp with an explicit offset")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"{context} is not a valid calendar timestamp")
        return None
    if parsed.tzinfo is None:
        errors.append(f"{context} must include an offset")
        return None
    return parsed


def git_bytes(root: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=False,
        capture_output=True,
    )


def resolve_schema_pointer(document: object, pointer: str) -> bool:
    if pointer == "":
        return True
    if not pointer.startswith("/"):
        return False
    current = document
    for encoded in pointer[1:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and token in current:
            current = current[token]
        else:
            return False
    return True


def iter_schema_references(value: object) -> Iterable[str]:
    if isinstance(value, dict):
        reference = value.get("$ref")
        if isinstance(reference, str):
            yield reference
        for item in value.values():
            yield from iter_schema_references(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_schema_references(item)


def validate_schema_bundle(root: Path, verify_hashes: bool = True) -> list[str]:
    errors: list[str] = []
    documents: dict[str, dict[str, Any]] = {}
    for relative, expected_hash in (
        (HOST_SCHEMA_PATH, HOST_SCHEMA_SHA256),
        (AGGREGATE_SCHEMA_PATH, AGGREGATE_SCHEMA_SHA256),
    ):
        path = root / relative
        try:
            payload = path.read_bytes()
            document = decode_json_bytes(payload, relative.as_posix())
        except (OSError, ValueError, json.JSONDecodeError) as error:
            errors.append(str(error))
            continue
        if verify_hashes and sha256_bytes(payload) != expected_hash:
            errors.append(f"{relative.as_posix()} differs from its pinned schema digest")
        documents[relative.name] = document
    for name, document in documents.items():
        for reference in iter_schema_references(document):
            target_name, marker, pointer = reference.partition("#")
            if target_name == "":
                target_name = name
            if target_name not in documents:
                errors.append(f"{name}: unresolved external schema reference {reference!r}")
                continue
            if marker and not resolve_schema_pointer(documents[target_name], pointer):
                errors.append(f"{name}: unresolved schema pointer {reference!r}")
    return sorted(set(errors))


def _rewrite_schema_references(value: object, prefix: str) -> object:
    if isinstance(value, dict):
        rewritten: dict[str, object] = {}
        for key, item in value.items():
            if key == "$ref" and isinstance(item, str) and item.startswith("#/$defs/"):
                rewritten[key] = f"#/$defs/{prefix}{item.removeprefix('#/$defs/')}"
            else:
                rewritten[key] = _rewrite_schema_references(item, prefix)
        return rewritten
    if isinstance(value, list):
        return [_rewrite_schema_references(item, prefix) for item in value]
    return value


def bundle_aggregate_schema(
    host_schema: dict[str, Any], aggregate_schema: dict[str, Any]
) -> dict[str, Any]:
    bundled = json.loads(json.dumps(aggregate_schema))
    definitions = bundled.setdefault("$defs", {})
    host_definitions = host_schema.get("$defs")
    if not isinstance(definitions, dict) or not isinstance(host_definitions, dict):
        raise ValueError("schema definitions must be objects")
    for name, definition in host_definitions.items():
        definitions[f"host__{name}"] = _rewrite_schema_references(
            definition, "host__"
        )

    def rewrite_external(value: object) -> None:
        if isinstance(value, dict):
            reference = value.get("$ref")
            prefix = "r01-host-report-v1.json#/$defs/"
            if isinstance(reference, str) and reference.startswith(prefix):
                value["$ref"] = f"#/$defs/host__{reference.removeprefix(prefix)}"
            for item in value.values():
                rewrite_external(item)
        elif isinstance(value, list):
            for item in value:
                rewrite_external(item)

    rewrite_external(bundled)
    return bundled


def validate_instances_against_schemas(
    root: Path,
    reports: list[dict[str, Any]],
    aggregate: dict[str, Any] | None = None,
) -> list[str]:
    errors: list[str] = []
    try:
        host_schema = read_json(root / HOST_SCHEMA_PATH, HOST_SCHEMA_PATH.as_posix())
        aggregate_schema = read_json(
            root / AGGREGATE_SCHEMA_PATH, AGGREGATE_SCHEMA_PATH.as_posix()
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return [str(error)]
    for anchor, report in zip(ANCHORS, reports):
        errors.extend(
            f"raw report {anchor} schema: {error}"
            for error in validate_json_schema_instance(host_schema, report)
        )
    if aggregate is not None:
        try:
            bundled = bundle_aggregate_schema(host_schema, aggregate_schema)
        except ValueError as error:
            errors.append(str(error))
        else:
            errors.extend(
                f"aggregate schema: {error}"
                for error in validate_json_schema_instance(bundled, aggregate)
            )
    return sorted(set(errors))


class R01CapabilityVerifier:
    def __init__(self, repository_root: Path) -> None:
        self.root = repository_root.resolve()

    def _read_required_json(
        self, relative: Path, errors: list[str]
    ) -> dict[str, Any] | None:
        try:
            path = self.root / relative
            link = symlink_component(self.root, relative)
            if link is not None:
                errors.append(f"{relative.as_posix()} contains symbolic-link component {link}")
            size = path.stat().st_size
            if size > MAX_EVIDENCE_FILE_BYTES:
                errors.append(
                    f"{relative.as_posix()} exceeds the {MAX_EVIDENCE_FILE_BYTES}-byte evidence-file limit"
                )
            value = read_json(path, relative.as_posix())
        except (OSError, ValueError, json.JSONDecodeError) as error:
            errors.append(str(error))
            return None
        return value

    def _published_source_errors(self, commit: object, tree: object) -> list[str]:
        errors: list[str] = []
        if not isinstance(commit, str) or GIT_OBJECT_PATTERN.fullmatch(commit) is None:
            return ["source_commit must be a nonzero 40-character Git object ID"]
        if not isinstance(tree, str) or GIT_OBJECT_PATTERN.fullmatch(tree) is None:
            return ["source_tree must be a nonzero 40-character Git object ID"]
        commit_check = git_bytes(self.root, "cat-file", "-e", f"{commit}^{{commit}}")
        if commit_check.returncode != 0:
            return [f"source commit {commit} is unavailable"]
        tree_result = git_bytes(self.root, "rev-parse", f"{commit}^{{tree}}")
        observed_tree = tree_result.stdout.decode("ascii", errors="replace").strip()
        if tree_result.returncode != 0 or observed_tree != tree:
            errors.append("source_tree does not match source_commit^{tree}")
        published = git_bytes(
            self.root,
            "for-each-ref",
            "--format=%(refname)",
            "--contains",
            commit,
            "refs/remotes/origin",
        )
        published_refs = published.stdout.decode("utf-8", errors="replace").splitlines()
        if published.returncode != 0 or not any(
            value.startswith("refs/remotes/origin/") for value in published_refs
        ):
            errors.append(
                "source_commit is not contained by a local origin remote-tracking ref"
            )
        return errors

    def _git_file_bytes(
        self, commit: str, relative: Path, context: str, errors: list[str]
    ) -> bytes | None:
        result = git_bytes(self.root, "show", f"{commit}:{relative.as_posix()}")
        if result.returncode != 0:
            errors.append(f"{context} is absent at source_commit")
            return None
        return result.stdout

    def _repository_binding(
        self,
        value: object,
        expected_path: Path,
        source_commit: str,
        context: str,
        errors: list[str],
    ) -> bytes | None:
        binding = require_exact_keys(
            value, ("path", "size_bytes", "sha256"), context, errors
        )
        if binding is None:
            return None
        path = safe_relative_path(binding.get("path"), f"{context}.path", errors)
        if path != expected_path:
            errors.append(
                f"{context}.path must be exactly {expected_path.as_posix()!r}"
            )
        size = binding.get("size_bytes")
        digest = binding.get("sha256")
        if isinstance(size, bool) or not isinstance(size, int) or not (
            1 <= size <= MAX_EVIDENCE_FILE_BYTES
        ):
            errors.append(f"{context}.size_bytes must be 1..{MAX_EVIDENCE_FILE_BYTES}")
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            errors.append(f"{context}.sha256 must be a nonzero lowercase SHA-256")
        if path != expected_path:
            return None
        source_payload = self._git_file_bytes(
            source_commit, expected_path, context, errors
        )
        if source_payload is not None and (
            size != len(source_payload) or digest != sha256_bytes(source_payload)
        ):
            errors.append(f"{context} does not bind the source_commit bytes")
        working_path = self.root / expected_path
        link = symlink_component(self.root, expected_path)
        if link is not None:
            errors.append(f"{context} path contains symbolic-link component {link}")
        try:
            working_payload = working_path.read_bytes()
        except OSError as error:
            errors.append(str(error))
        else:
            if source_payload is not None and working_payload != source_payload:
                errors.append(f"{context} working bytes differ from source_commit")
        return source_payload

    def _preregistration_context(
        self,
        preregistration: dict[str, Any] | None,
        catalog: dict[str, Any] | None,
        errors: list[str],
    ) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
        assignments_by_anchor: dict[str, dict[str, Any]] = {}
        fixtures_by_id: dict[str, dict[str, Any]] = {}
        if preregistration is None or catalog is None:
            return assignments_by_anchor, fixtures_by_id
        errors.extend(
            f"preregistration semantic validation: {error}"
            for error in PreregistrationVerifier(self.root).check()
        )
        errors.extend(
            f"materialized fixture validation: {error}"
            for error in check_materialized_fixtures(self.root, catalog)
        )
        require_exact_keys(
            preregistration,
            PREREGISTRATION_KEYS,
            "preregistration",
            errors,
        )
        require_exact_keys(catalog, FIXTURE_CATALOG_KEYS, "fixture catalog", errors)
        if preregistration.get("schema_version") != "1.0.0":
            errors.append("preregistration schema_version must be 1.0.0")
        if preregistration.get("roadmap_version") != ROADMAP_VERSION:
            errors.append("preregistration roadmap_version differs")
        if preregistration.get("phase_id") != PHASE_ID:
            errors.append("preregistration phase_id differs")
        if preregistration.get("preregistration_state") != "live_assignments_frozen":
            errors.append("all R01 live assignments must be frozen before aggregation")
        if preregistration.get("measurement_boundary") != (
            "capability_and_repeatability_only_not_perceptual_superiority_or_product_qualification"
        ):
            errors.append("preregistration measurement boundary differs")
        if preregistration.get("capabilities") != [
            {
                "id": identifier,
                "family": family,
                "method": method,
                "probe_class": probe_class,
            }
            for identifier, family, method, probe_class in CAPABILITY_IDENTITIES
        ]:
            errors.append("preregistration capabilities differ from A01-A18")
        controls = preregistration.get("execution_controls")
        expected_controls = {
            "clock": "monotonic",
            "measured_units_per_session": 30,
            "repeatability_observations": 3,
            "sessions": 3,
            "timeout_seconds_per_session": 120,
            "warm_up_units_per_session": 5,
        }
        if controls != expected_controls:
            errors.append("preregistration execution controls differ")
        assignments = preregistration.get("anchor_assignments")
        if not isinstance(assignments, list) or [
            value.get("anchor") if isinstance(value, dict) else None
            for value in assignments
        ] != list(ANCHORS):
            errors.append("preregistration anchor assignments differ from the closed order")
        else:
            for value in assignments:
                anchor = value["anchor"]
                require_exact_keys(
                    value,
                    ANCHOR_ASSIGNMENT_KEYS,
                    f"preregistration anchor {anchor}",
                    errors,
                )
                if value.get("assignment_state") != "assigned" or not isinstance(
                    value.get("host_profile"), dict
                ):
                    errors.append(f"anchor {anchor} is not frozen to a host profile")
                else:
                    require_exact_keys(
                        value["host_profile"],
                        ASSIGNED_HOST_PROFILE_KEYS,
                        f"preregistration anchor {anchor}.host_profile",
                        errors,
                    )
                    assignments_by_anchor[anchor] = value["host_profile"]
        catalog_binding = preregistration.get("fixture_catalog")
        expected_catalog_payload = canonical_json_bytes(catalog)
        actual_catalog_payload = (self.root / FIXTURE_CATALOG_PATH).read_bytes()
        if expected_catalog_payload != actual_catalog_payload:
            errors.append("fixture catalog is not canonical JSON")
        if catalog_binding != {
            "path": FIXTURE_CATALOG_PATH.as_posix(),
            "sha256": sha256_bytes(actual_catalog_payload),
        }:
            errors.append("preregistration fixture catalog binding differs")
        fixtures = catalog.get("fixtures")
        if not isinstance(fixtures, list) or [
            value.get("id") if isinstance(value, dict) else None for value in fixtures
        ] != list(FIXTURE_IDS):
            errors.append("fixture catalog IDs/order differ from the closed eleven fixtures")
        else:
            fixtures_by_id = {value["id"]: value for value in fixtures}
            for index, fixture in enumerate(fixtures):
                require_exact_keys(
                    fixture,
                    FIXTURE_CATALOG_RECORD_KEYS,
                    f"fixture catalog fixtures[{index}]",
                    errors,
                )
            model = fixtures_by_id["analysis-probe-model"]
            if model.get("status") != "frozen":
                errors.append("analysis-probe-model must be frozen before aggregation")
            for key in ("model_identity", "content_sha256"):
                if not isinstance(model.get(key), str) or not model[key]:
                    errors.append(f"analysis-probe-model {key} must be frozen")
            digest = model.get("content_sha256")
            if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
                errors.append("analysis-probe-model content_sha256 is not a nonzero SHA-256")
            validate_local_model_path(
                self.root,
                model.get("materialization_path"),
                "analysis-probe-model.materialization_path",
                errors,
            )
        return assignments_by_anchor, fixtures_by_id

    def _validate_host(
        self,
        value: object,
        anchor: str,
        assignment: dict[str, Any] | None,
        context: str,
        errors: list[str],
    ) -> None:
        host = require_exact_keys(value, HOST_KEYS, context, errors)
        if host is None:
            return
        host_id = host.get("host_id")
        if not isinstance(host_id, str) or IDENTIFIER_PATTERN.fullmatch(host_id) is None:
            errors.append(f"{context}.host_id is not a closed identifier")
        for key in (
            "model_identifier",
            "chip",
            "os_version",
            "os_build",
            "xcode_version",
            "xcode_build",
            "sdk_version",
            "sdk_build",
        ):
            if not isinstance(host.get(key), str) or not host[key]:
                errors.append(f"{context}.{key} must be non-empty")
        memory = host.get("memory_bytes")
        if isinstance(memory, bool) or not isinstance(memory, int) or memory < 1:
            errors.append(f"{context}.memory_bytes must be positive")
        classes = host.get("hardware_classes")
        allowed_classes = {
            "apple_silicon",
            "macbook_air",
            "pro_max_tier",
            "core_ai_capable",
        }
        if not isinstance(classes, list) or not classes or len(classes) != len(set(classes)):
            errors.append(f"{context}.hardware_classes must be a non-empty unique array")
            classes = []
        elif any(value not in allowed_classes for value in classes):
            errors.append(f"{context}.hardware_classes contains an unknown value")
        if assignment is None:
            errors.append(f"{context} has no frozen preregistration assignment")
        else:
            for key in (
                "host_id",
                "model_identifier",
                "chip",
                "memory_bytes",
                "os_version",
                "os_build",
                "xcode_version",
                "xcode_build",
                "sdk_version",
                "sdk_build",
            ):
                if host.get(key) != assignment.get(key):
                    errors.append(f"{context}.{key} differs from preregistration")
            required_class = assignment.get("hardware_class")
            if required_class not in classes:
                errors.append(f"{context} lacks assigned hardware class {required_class!r}")
        chip = host.get("chip")
        os_version = host.get("os_version")
        if anchor == "oldest-supported":
            if not isinstance(chip, str) or not chip.startswith("Apple M"):
                errors.append("oldest-supported host must be Apple Silicon")
            if not isinstance(os_version, str) or not re.fullmatch(r"15\.4(?:\.[0-9]+)*", os_version):
                errors.append("oldest-supported host must run macOS 15.4")
        elif anchor == "m3-air":
            if chip != "Apple M3" or "macbook_air" not in classes:
                errors.append("m3-air host must be an Apple M3 MacBook Air")
            if not isinstance(os_version, str) or not re.fullmatch(r"26(?:\.[0-9]+)*", os_version):
                errors.append("m3-air host must run macOS 26")
            model = host.get("model_identifier")
            if model not in {"Mac15,12", "Mac15,13"}:
                errors.append("m3-air model_identifier must be Mac15,12 or Mac15,13")
        elif anchor == "pro-max":
            if not isinstance(chip, str) or re.fullmatch(
                r"Apple M[0-9]+ (?:Pro|Max)", chip
            ) is None:
                errors.append("pro-max host must record an Apple Pro/Max chip")
        elif anchor == "core-ai":
            for key in ("os_version", "xcode_version", "sdk_version"):
                value = host.get(key)
                try:
                    major = int(str(value).split(".", 1)[0])
                except ValueError:
                    major = -1
                if major < 27:
                    errors.append(f"core-ai host {key} must have major version 27 or newer")
            if "core_ai_capable" not in classes:
                errors.append("core-ai host lacks core_ai_capable hardware class")

    def _validate_fixture_bindings(
        self,
        value: object,
        source_commit: str,
        fixtures_by_id: dict[str, dict[str, Any]],
        context: str,
        errors: list[str],
    ) -> None:
        if not isinstance(value, list) or len(value) != len(FIXTURE_IDS):
            errors.append(f"{context} must contain exactly eleven bindings")
            return
        observed_ids = [
            item.get("id") if isinstance(item, dict) else None for item in value
        ]
        if observed_ids != list(FIXTURE_IDS):
            errors.append(f"{context} IDs/order differ from the fixture catalog")
        for index, fixture_id in enumerate(FIXTURE_IDS):
            binding = value[index]
            catalog = fixtures_by_id.get(fixture_id)
            item_context = f"{context}[{index}]"
            if fixture_id == "analysis-probe-model":
                record = require_exact_keys(
                    binding,
                    ("id", "kind", "identity", "path", "size_bytes", "sha256"),
                    item_context,
                    errors,
                )
                if record is None:
                    continue
                if record.get("id") != fixture_id or record.get("kind") != "system_asset":
                    errors.append(f"{item_context} must be the system model binding")
                if record.get("path") is not None or record.get("size_bytes") is not None:
                    errors.append(f"{item_context} must not expose a system-asset path or size")
                if catalog is None:
                    errors.append(f"{item_context} has no catalog record")
                else:
                    if record.get("identity") != catalog.get("model_identity"):
                        errors.append(f"{item_context}.identity differs from preregistration")
                    if record.get("sha256") != catalog.get("content_sha256"):
                        errors.append(f"{item_context}.sha256 differs from preregistration")
                continue
            record = require_exact_keys(
                binding,
                ("id", "kind", "identity", "path", "size_bytes", "sha256"),
                item_context,
                errors,
            )
            if record is None:
                continue
            if record.get("id") != fixture_id or record.get("kind") != "repository_fixture":
                errors.append(f"{item_context} identity/kind differs")
            if catalog is None:
                errors.append(f"{item_context} has no catalog record")
                continue
            expected_path_value = catalog.get("materialization_path")
            expected_path = safe_relative_path(
                expected_path_value, f"catalog.{fixture_id}.materialization_path", errors
            )
            if record.get("identity") != catalog.get("role"):
                errors.append(f"{item_context}.identity differs from the catalog role")
            if record.get("path") != expected_path_value:
                errors.append(f"{item_context}.path differs from the catalog")
            if record.get("size_bytes") != catalog.get("byte_count"):
                errors.append(f"{item_context}.size_bytes differs from the catalog")
            if record.get("sha256") != catalog.get("content_sha256"):
                errors.append(f"{item_context}.sha256 differs from the catalog")
            if expected_path is not None:
                link = symlink_component(self.root, expected_path)
                if link is not None:
                    errors.append(
                        f"{item_context} path contains symbolic-link component {link}"
                    )
                source_payload = self._git_file_bytes(
                    source_commit, expected_path, item_context, errors
                )
                if source_payload is not None and (
                    len(source_payload) != record.get("size_bytes")
                    or sha256_bytes(source_payload) != record.get("sha256")
                ):
                    errors.append(f"{item_context} does not bind source fixture bytes")
                try:
                    working_payload = (self.root / expected_path).read_bytes()
                except OSError as error:
                    errors.append(str(error))
                else:
                    if source_payload is not None and working_payload != source_payload:
                        errors.append(f"{item_context} working fixture differs from source")

    def _validate_implementation_bindings(
        self,
        value: object,
        source_commit: str,
        context: str,
        errors: list[str],
    ) -> None:
        if not isinstance(value, list) or len(value) != len(
            REQUIRED_IMPLEMENTATION_PATHS
        ):
            errors.append(
                f"{context} must contain exactly {len(REQUIRED_IMPLEMENTATION_PATHS)} bindings"
            )
            return
        observed_paths = [
            item.get("path") if isinstance(item, dict) else None for item in value
        ]
        if observed_paths != [path.as_posix() for path in REQUIRED_IMPLEMENTATION_PATHS]:
            errors.append(
                f"{context} paths/order differ from the closed implementation source set"
            )
        for index, expected_path in enumerate(REQUIRED_IMPLEMENTATION_PATHS):
            self._repository_binding(
                value[index],
                expected_path,
                source_commit,
                f"{context}[{index}]",
                errors,
            )

    @staticmethod
    def _expected_input_contract(
        identifier: str,
        probe_class: str,
        fixtures_by_id: dict[str, dict[str, Any]],
    ) -> dict[str, Any]:
        fixture_ids = list(CLASS_FIXTURES[probe_class])
        if probe_class == "primary_scaler":
            return {
                "fixture_ids": fixture_ids,
                "input_dimensions": ["1280x720", "1920x1080"],
                "output_dimensions": ["1920x1080", "3840x2160"],
                "formats": ["420v"],
                "color_expectations": [
                    "SDR BT.709 video-range left-sited 8-bit NV12"
                ],
                "scales": [1.5, 2.0],
                "guidance_inputs": [],
                "history_inputs": [],
                "timestamp_contract": None,
                "model_identity": None,
                "model_sha256": None,
            }
        if probe_class == "support_filter":
            fixture_ids = list(SUPPORT_FILTER_FIXTURES[identifier])
            requires_guidance = "support-guidance" in fixture_ids
            requires_history = "support-history" in fixture_ids
            return {
                "fixture_ids": fixture_ids,
                "input_dimensions": ["1920x1080"],
                "output_dimensions": ["1920x1080"],
                "formats": ["420v", "L008"] if requires_guidance else ["420v"],
                "color_expectations": [
                    "SDR BT.709 video-range left-sited 8-bit NV12"
                ],
                "scales": [],
                "guidance_inputs": ["support-guidance"] if requires_guidance else [],
                "history_inputs": ["support-history"] if requires_history else [],
                "timestamp_contract": None,
                "model_identity": None,
                "model_sha256": None,
            }
        if probe_class == "temporal_analyzer":
            return {
                "fixture_ids": fixture_ids,
                "input_dimensions": ["1920x1080"],
                "output_dimensions": [],
                "formats": ["420v"],
                "color_expectations": [
                    "SDR BT.709 video-range left-sited 8-bit NV12"
                ],
                "scales": [],
                "guidance_inputs": [],
                "history_inputs": ["temporal-frame-0"],
                "timestamp_contract": None,
                "model_identity": None,
                "model_sha256": None,
            }
        if probe_class == "cadence_transform":
            return {
                "fixture_ids": fixture_ids,
                "input_dimensions": ["1920x1080"],
                "output_dimensions": ["1920x1080"],
                "formats": ["420v"],
                "color_expectations": [
                    "SDR BT.709 video-range left-sited 8-bit NV12"
                ],
                "scales": [],
                "guidance_inputs": [],
                "history_inputs": [],
                "timestamp_contract": "PTS 0/600 and 20/600; duration 20/600",
                "model_identity": None,
                "model_sha256": None,
            }
        model = fixtures_by_id.get("analysis-probe-model", {})
        return {
            "fixture_ids": fixture_ids,
            "input_dimensions": ["512x288"],
            "output_dimensions": [],
            "formats": ["BGRA"],
            "color_expectations": ["deterministic 8-bit BGRA proxy"],
            "scales": [],
            "guidance_inputs": [],
            "history_inputs": [],
            "timestamp_contract": None,
            "model_identity": model.get("model_identity"),
            "model_sha256": model.get("content_sha256"),
        }

    def _validate_observation(
        self,
        value: object,
        metric: str,
        probe_class: str,
        runtime: str,
        reason_code: str,
        applicable: bool,
        context: str,
        errors: list[str],
    ) -> None:
        observation = require_exact_keys(
            value, ("status", "value", "unit", "reason"), context, errors
        )
        if observation is None:
            return
        status = observation.get("status")
        metric_value = observation.get("value")
        reason = observation.get("reason")
        if observation.get("unit") != METRIC_UNITS[metric]:
            errors.append(
                f"{context}.unit must be exactly {METRIC_UNITS[metric]!r}"
            )
        if not applicable:
            expected_reason = f"not_applicable_for_{probe_class}"
            if (
                status != "not_applicable"
                or metric_value is not None
                or reason != expected_reason
            ):
                errors.append(
                    f"{context} must be not_applicable with reason {expected_reason!r}"
                )
            return
        if runtime == "runnable":
            if status != "measured" or metric_value is None or reason is not None:
                errors.append(f"{context} must be measured for a runnable capability")
        elif status == "not_measured":
            if metric_value is not None or reason != reason_code:
                errors.append(f"{context} not_measured reason must equal reason_code")
        elif status == "measured":
            if metric_value is None or reason is not None:
                errors.append(f"{context} measured observation has invalid value/reason")
        else:
            errors.append(f"{context} has an invalid applicable metric status")
        if status == "measured":
            numeric_metrics = {
                "initialization_seconds",
                "acquisition_seconds",
                "median_wall_seconds",
                "p95_wall_seconds",
                "throughput_units_per_second",
                "peak_resident_memory_delta_bytes",
                "frame_rate",
                "output_cadence",
                "load_seconds",
                "specialization_seconds",
                "inference_seconds",
            }
            boolean_metrics = {"required_guidance", "confidence_available"}
            if metric in numeric_metrics and (
                isinstance(metric_value, bool)
                or not isinstance(metric_value, (int, float))
                or metric_value < 0
            ):
                errors.append(f"{context}.value must be a nonnegative number")
            if metric in boolean_metrics and not isinstance(metric_value, bool):
                errors.append(f"{context}.value must be boolean")
            if metric == "generated_frame_count" and (
                isinstance(metric_value, bool)
                or not isinstance(metric_value, int)
                or metric_value < 0
            ):
                errors.append(f"{context}.value must be a nonnegative integer")
            if metric not in numeric_metrics | boolean_metrics | {"generated_frame_count"}:
                if not isinstance(metric_value, str) or not metric_value:
                    errors.append(f"{context}.value must be a non-empty string")

    def _validate_repeatability(
        self,
        value: object,
        runtime: str,
        reason_code: str,
        context: str,
        errors: list[str],
    ) -> None:
        repeatability = require_exact_keys(
            value,
            ("status", "mode", "observations", "tolerance", "reason"),
            context,
            errors,
        )
        if repeatability is None:
            return
        status = repeatability.get("status")
        mode = repeatability.get("mode")
        observations = repeatability.get("observations")
        tolerance = repeatability.get("tolerance")
        reason = repeatability.get("reason")
        if status == "measured":
            if runtime != "runnable":
                errors.append(f"{context} may be measured only for runnable evidence")
            if not isinstance(observations, list) or len(observations) != 3:
                errors.append(f"{context}.observations must contain three values")
                return
            if mode == "hash":
                if any(
                    not isinstance(item, str)
                    or SHA256_PATTERN.fullmatch(item) is None
                    for item in observations
                ):
                    errors.append(f"{context} hash observations must be nonzero SHA-256")
                if tolerance is not None:
                    errors.append(f"{context}.tolerance must be null in hash mode")
            elif mode == "tolerance":
                if any(
                    isinstance(item, bool) or not isinstance(item, (int, float))
                    for item in observations
                ):
                    errors.append(f"{context} tolerance observations must be numeric")
                if (
                    isinstance(tolerance, bool)
                    or not isinstance(tolerance, (int, float))
                    or tolerance < 0
                ):
                    errors.append(f"{context}.tolerance must be nonnegative")
            else:
                errors.append(f"{context}.mode must be hash or tolerance when measured")
            if reason is not None:
                errors.append(f"{context}.reason must be null when measured")
        elif status == "not_measured":
            if (
                mode != "not_applicable"
                or observations != []
                or tolerance is not None
                or reason != reason_code
            ):
                errors.append(f"{context} not_measured closure differs")
        else:
            errors.append(f"{context}.status is invalid")

    def _validate_measurements(
        self,
        value: object,
        probe_class: str,
        runtime: str,
        reason_code: str,
        failure_class: str,
        context: str,
        errors: list[str],
    ) -> None:
        measurements = require_exact_keys(value, MEASUREMENT_KEYS, context, errors)
        if measurements is None:
            return
        for key, expected in (
            ("warmup_units_per_session", 5),
            ("measured_units_per_session", 30),
            ("timeout_seconds_per_session", 120),
        ):
            if measurements.get(key) != expected:
                errors.append(f"{context}.{key} must be exactly {expected}")
        sessions = measurements.get("sessions")
        if not isinstance(sessions, list) or len(sessions) > 3:
            errors.append(f"{context}.sessions must contain zero to three records")
            sessions = []
        if measurements.get("session_count") != len(sessions):
            errors.append(f"{context}.session_count must equal the session record count")
        for index, session_value in enumerate(sessions, start=1):
            session = require_exact_keys(
                session_value,
                (
                    "session_index",
                    "completed_warmup_units",
                    "completed_measured_units",
                    "elapsed_seconds",
                    "timed_out",
                    "outcome",
                    "failure_detail",
                ),
                f"{context}.sessions[{index - 1}]",
                errors,
            )
            if session is None:
                continue
            session_context = f"{context}.sessions[{index - 1}]"
            if session.get("session_index") != index:
                errors.append(f"{session_context}.session_index must be {index}")
            warmups = session.get("completed_warmup_units")
            measured = session.get("completed_measured_units")
            elapsed = session.get("elapsed_seconds")
            if isinstance(warmups, bool) or not isinstance(warmups, int) or not 0 <= warmups <= 5:
                errors.append(f"{session_context}.completed_warmup_units is invalid")
            if isinstance(measured, bool) or not isinstance(measured, int) or not 0 <= measured <= 30:
                errors.append(f"{session_context}.completed_measured_units is invalid")
            if (
                isinstance(elapsed, bool)
                or not isinstance(elapsed, (int, float))
                or not 0 <= elapsed <= 120
            ):
                errors.append(f"{session_context}.elapsed_seconds is invalid")
            outcome = session.get("outcome")
            timed_out = session.get("timed_out")
            detail = session.get("failure_detail")
            if outcome == "completed":
                if warmups != 5 or measured != 30 or timed_out is not False or detail is not None:
                    errors.append(f"{session_context} completed-session closure differs")
            elif outcome in FAILURE_CLASSES:
                if not isinstance(detail, str) or not detail:
                    errors.append(f"{session_context} failure_detail must be non-empty")
                if (outcome == "timeout") != (timed_out is True):
                    errors.append(f"{session_context} timed_out does not match outcome")
                if outcome == "timeout" and elapsed != 120:
                    errors.append(f"{session_context} timeout must stop at 120 seconds")
                if runtime != "runnable" and outcome != failure_class:
                    errors.append(
                        f"{session_context}.outcome must match capability failure_class"
                    )
            else:
                errors.append(f"{session_context}.outcome is not a closed failure class")
        if runtime == "runnable":
            if len(sessions) != 3 or any(
                not isinstance(session, dict) or session.get("outcome") != "completed"
                for session in sessions
            ):
                errors.append(
                    f"{context} runnable evidence requires three completed sessions"
                )
        metrics = require_exact_keys(
            measurements.get("metrics"), ALL_METRICS, f"{context}.metrics", errors
        )
        if metrics is not None:
            applicable_metrics = set(COMMON_METRICS + CLASS_METRICS[probe_class])
            for metric in ALL_METRICS:
                self._validate_observation(
                    metrics.get(metric),
                    metric,
                    probe_class,
                    runtime,
                    reason_code,
                    metric in applicable_metrics,
                    f"{context}.metrics.{metric}",
                    errors,
                )
            median = metrics.get("median_wall_seconds")
            p95 = metrics.get("p95_wall_seconds")
            if isinstance(median, dict) and isinstance(p95, dict):
                if median.get("status") == p95.get("status") == "measured":
                    median_value = median.get("value")
                    p95_value = p95.get("value")
                    if (
                        isinstance(median_value, (int, float))
                        and not isinstance(median_value, bool)
                        and isinstance(p95_value, (int, float))
                        and not isinstance(p95_value, bool)
                        and p95_value < median_value
                    ):
                        errors.append(f"{context} p95 wall time is below median")
        self._validate_repeatability(
            measurements.get("repeatability"),
            runtime,
            reason_code,
            f"{context}.repeatability",
            errors,
        )

    def _validate_capability(
        self,
        value: object,
        expected: tuple[str, str, str, str],
        fixtures_by_id: dict[str, dict[str, Any]],
        anchor: str,
        context: str,
        errors: list[str],
    ) -> None:
        capability = require_exact_keys(value, CAPABILITY_KEYS, context, errors)
        if capability is None:
            return
        identifier, family, method, probe_class = expected
        for key, expected_value in (
            ("id", identifier),
            ("family", family),
            ("method", method),
            ("probe_class", probe_class),
        ):
            if capability.get(key) != expected_value:
                errors.append(f"{context}.{key} differs from the closed capability catalog")
        compile_state = capability.get("compile_state")
        runtime = capability.get("runtime_disposition")
        reason_code = capability.get("reason_code")
        failure_class = capability.get("failure_class")
        if compile_state not in COMPILE_STATES:
            errors.append(f"{context}.compile_state is invalid")
        if runtime not in RUNTIME_DISPOSITIONS:
            errors.append(f"{context}.runtime_disposition is invalid")
        if runtime == "runnable":
            if reason_code != "none":
                errors.append(f"{context} runnable evidence must use reason_code none")
            if failure_class != "none":
                errors.append(f"{context} runnable evidence must use failure_class none")
        elif reason_code not in REASON_CODES:
            errors.append(f"{context} non-runnable evidence requires a closed reason_code")
        if runtime != "runnable":
            if failure_class not in FAILURE_CLASSES:
                errors.append(f"{context} non-runnable evidence requires a failure_class")
            reason_classes = {
                "api_absent": {"unsupported_contract"},
                "os_too_old": {"unsupported_contract"},
                "sdk_too_old": {"unsupported_contract"},
                "hardware_unsupported": {"unsupported_contract"},
                "model_unavailable": {"unsupported_contract"},
                "model_acquisition_failed": {"setup_failure"},
                "input_contract_unsatisfied": {"unsupported_contract"},
                "runtime_probe_failed": {
                    "timeout",
                    "setup_failure",
                    "processing_failure",
                    "resource_failure",
                },
                "resource_limit": {"resource_failure"},
                "not_public_api": {"unsupported_contract"},
                "not_applicable": {"unsupported_contract"},
            }
            if reason_code in reason_classes and failure_class not in reason_classes[reason_code]:
                errors.append(f"{context} failure_class is incompatible with reason_code")
        if compile_state == "unavailable" and runtime == "runnable":
            errors.append(f"{context} cannot be runnable when compile state is unavailable")
        public_status = capability.get("public_api_status")
        if public_status not in {"public", "not_public", "absent"}:
            errors.append(f"{context}.public_api_status is invalid")
        if public_status == "not_public" and reason_code != "not_public_api":
            errors.append(f"{context} non-public API must use reason not_public_api")
        if public_status == "absent" and reason_code not in {
            "api_absent",
            "os_too_old",
            "sdk_too_old",
        }:
            errors.append(f"{context} absent API has an incompatible reason")
        eligibility = capability.get("hardware_eligibility")
        if eligibility not in {"eligible", "ineligible", "unknown"}:
            errors.append(f"{context}.hardware_eligibility is invalid")
        if eligibility == "ineligible" and reason_code != "hardware_unsupported":
            errors.append(f"{context} ineligible hardware must use hardware_unsupported")
        requirements = require_exact_keys(
            capability.get("platform_requirements"),
            ("minimum_os_version", "minimum_sdk_version", "unavailable_reason"),
            f"{context}.platform_requirements",
            errors,
        )
        if requirements is not None:
            minima = (
                requirements.get("minimum_os_version"),
                requirements.get("minimum_sdk_version"),
            )
            if all(isinstance(item, str) and item for item in minima):
                if requirements.get("unavailable_reason") is not None:
                    errors.append(f"{context} known platform minima require null reason")
            elif requirements.get("unavailable_reason") not in REASON_CODES:
                errors.append(f"{context} unknown platform minima require a closed reason")
        support = require_exact_keys(
            capability.get("support_query"),
            ("api_or_equivalent_name", "observed", "reason_code"),
            f"{context}.support_query",
            errors,
        )
        if support is not None:
            if not isinstance(support.get("api_or_equivalent_name"), str) or not support[
                "api_or_equivalent_name"
            ]:
                errors.append(f"{context}.support_query name must be non-empty")
            observed = support.get("observed")
            if observed is True:
                if support.get("reason_code") is not None:
                    errors.append(f"{context} observed support query requires null reason")
            elif observed is False or observed == "not_available":
                if support.get("reason_code") not in REASON_CODES:
                    errors.append(f"{context} negative support query requires a closed reason")
            else:
                errors.append(f"{context}.support_query observed value is invalid")
        input_contract = capability.get("input_contract")
        expected_input = self._expected_input_contract(
            identifier, probe_class, fixtures_by_id
        )
        if input_contract != expected_input:
            errors.append(f"{context}.input_contract differs from the frozen fixture contract")
        if capability.get("state_history") not in {
            "stateless",
            "stateful",
            "requires_history",
            "unavailable",
        }:
            errors.append(f"{context}.state_history is invalid")
        if capability.get("model_readiness") not in {
            "not_required",
            "ready",
            "unavailable",
            "acquisition_failed",
        }:
            errors.append(f"{context}.model_readiness is invalid")
        if capability.get("offline_suitability") not in {
            "suitable",
            "requires_acquisition",
            "unavailable",
            "unknown",
        }:
            errors.append(f"{context}.offline_suitability is invalid")
        model_readiness = capability.get("model_readiness")
        offline_suitability = capability.get("offline_suitability")
        reason_contracts: dict[str, dict[str, set[object]]] = {
            "api_absent": {
                "compile_state": {"unavailable"},
                "runtime_disposition": {"unavailable", "unsupported"},
                "public_api_status": {"absent"},
                "support_observed": {"not_available"},
                "offline_suitability": {"unavailable"},
            },
            "not_public_api": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"unsupported", "diagnostic_only", "rejected"},
                "public_api_status": {"not_public"},
                "support_observed": {"not_available"},
                "offline_suitability": {"unavailable"},
            },
            "os_too_old": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"unavailable", "unsupported", "restricted"},
                "public_api_status": {"public"},
                "support_observed": {False},
                "offline_suitability": {"unavailable"},
            },
            "sdk_too_old": {
                "compile_state": {"unavailable", "conditional"},
                "runtime_disposition": {"unavailable", "unsupported"},
                "public_api_status": {"public"},
                "support_observed": {"not_available"},
                "offline_suitability": {"unavailable"},
            },
            "hardware_unsupported": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"unavailable", "unsupported", "restricted"},
                "public_api_status": {"public"},
                "support_observed": {False},
                "hardware_eligibility": {"ineligible"},
                "offline_suitability": {"unavailable"},
            },
            "model_unavailable": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"unavailable", "unsupported", "restricted"},
                "public_api_status": {"public"},
                "support_observed": {True},
                "model_readiness": {"unavailable"},
                "offline_suitability": {"requires_acquisition", "unavailable"},
            },
            "model_acquisition_failed": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"unavailable", "rejected"},
                "public_api_status": {"public"},
                "support_observed": {True},
                "model_readiness": {"acquisition_failed"},
                "offline_suitability": {"unavailable"},
            },
            "input_contract_unsatisfied": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"restricted", "unsupported", "rejected"},
                "public_api_status": {"public"},
                "support_observed": {True},
            },
            "runtime_probe_failed": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"rejected", "unavailable", "diagnostic_only"},
                "public_api_status": {"public"},
                "support_observed": {True},
            },
            "resource_limit": {
                "compile_state": {"available", "conditional"},
                "runtime_disposition": {"restricted", "rejected", "unavailable"},
                "public_api_status": {"public"},
                "support_observed": {True},
            },
            "not_applicable": {
                "compile_state": {"available", "conditional", "unavailable"},
                "runtime_disposition": {"unsupported", "diagnostic_only"},
                "support_observed": {"not_available"},
                "offline_suitability": {"unavailable"},
            },
        }
        support_observed = support.get("observed") if support is not None else None
        if reason_code in reason_contracts:
            observed_states = {
                "compile_state": compile_state,
                "runtime_disposition": runtime,
                "public_api_status": public_status,
                "support_observed": support_observed,
                "hardware_eligibility": eligibility,
                "model_readiness": model_readiness,
                "offline_suitability": offline_suitability,
            }
            for state_name, allowed_values in reason_contracts[reason_code].items():
                if observed_states[state_name] not in allowed_values:
                    errors.append(
                        f"{context}.{state_name} is incompatible with reason_code {reason_code!r}"
                    )
            if support is not None and support_observed is not True and support.get(
                "reason_code"
            ) != reason_code:
                errors.append(f"{context}.support_query reason must equal reason_code")
        if public_status == "absent" and reason_code != "api_absent":
            errors.append(f"{context} public_api_status absent requires api_absent")
        if public_status == "not_public" and reason_code != "not_public_api":
            errors.append(f"{context} public_api_status not_public requires not_public_api")
        if eligibility == "ineligible" and reason_code != "hardware_unsupported":
            errors.append(f"{context} ineligible hardware requires hardware_unsupported")
        if model_readiness == "unavailable" and reason_code != "model_unavailable":
            errors.append(f"{context} unavailable model readiness requires model_unavailable")
        if model_readiness == "acquisition_failed" and reason_code != "model_acquisition_failed":
            errors.append(
                f"{context} acquisition_failed model readiness requires model_acquisition_failed"
            )
        if offline_suitability == "requires_acquisition" and not (
            reason_code == "model_unavailable" and model_readiness == "unavailable"
        ):
            errors.append(
                f"{context} requires_acquisition offline state requires model_unavailable"
            )
        if runtime == "runnable" and (
            model_readiness not in {"not_required", "ready"}
            or offline_suitability != "suitable"
            or support_observed is not True
        ):
            errors.append(f"{context} runnable model/offline/support state is inconsistent")
        if anchor == "core-ai" and identifier == "A18":
            if compile_state not in {"available", "conditional"}:
                errors.append("core-ai A18 compile surface must be available or conditional")
            if public_status != "public":
                errors.append("core-ai A18 must record a public API surface")
        expected_primary_observations: object = (
            [dict(value) for value in PRIMARY_SCALER_OBSERVATIONS]
            if probe_class == "primary_scaler" and runtime == "runnable"
            else []
        )
        if capability.get("primary_scaler_observations") != expected_primary_observations:
            errors.append(
                f"{context}.primary_scaler_observations differs from the closed two-fixture contract"
            )
        for key in (
            "product_qualification",
            "backend_eligibility",
            "quality_evaluation",
        ):
            if capability.get(key) != QUALIFICATION_VALUE:
                errors.append(f"{context}.{key} exceeds the R01 measurement boundary")
        limitations = capability.get("limitations")
        if not isinstance(limitations, list) or len(limitations) != len(set(limitations)) or any(
            not isinstance(item, str) or not item for item in limitations
        ):
            errors.append(f"{context}.limitations must be unique non-empty strings")
        self._validate_measurements(
            capability.get("measurements"),
            probe_class,
            runtime if isinstance(runtime, str) else "",
            reason_code if isinstance(reason_code, str) else "",
            failure_class if isinstance(failure_class, str) else "",
            f"{context}.measurements",
            errors,
        )

    def _validate_raw_report(
        self,
        report: dict[str, Any],
        anchor: str,
        assignments: dict[str, dict[str, Any]],
        fixtures_by_id: dict[str, dict[str, Any]],
        errors: list[str],
    ) -> None:
        context = f"raw report {anchor}"
        require_exact_keys(report, HOST_REPORT_KEYS, context, errors)
        check_privacy(report, context, errors)
        for key, expected in (
            ("schema_version", SCHEMA_VERSION),
            ("roadmap_version", ROADMAP_VERSION),
            ("phase_id", PHASE_ID),
            ("anchor", anchor),
        ):
            if report.get(key) != expected:
                errors.append(f"{context}.{key} must be exactly {expected!r}")
        parse_rfc3339(report.get("generated_at"), f"{context}.generated_at", errors)
        commit = report.get("source_commit")
        tree = report.get("source_tree")
        errors.extend(self._published_source_errors(commit, tree))
        if not isinstance(commit, str) or GIT_OBJECT_PATTERN.fullmatch(commit) is None:
            return
        self._validate_host(
            report.get("host"),
            anchor,
            assignments.get(anchor),
            f"{context}.host",
            errors,
        )
        self._validate_implementation_bindings(
            report.get("implementation_bindings"),
            commit,
            f"{context}.implementation_bindings",
            errors,
        )
        prereg_payload = self._repository_binding(
            report.get("preregistration_binding"),
            PREREGISTRATION_PATH,
            commit,
            f"{context}.preregistration_binding",
            errors,
        )
        if prereg_payload is not None:
            try:
                bound_preregistration = decode_json_bytes(
                    prereg_payload, f"{context} bound preregistration"
                )
            except ValueError as error:
                errors.append(str(error))
            else:
                current_preregistration = read_json(
                    self.root / PREREGISTRATION_PATH,
                    PREREGISTRATION_PATH.as_posix(),
                )
                if bound_preregistration != current_preregistration:
                    errors.append(f"{context} is bound to a different preregistration")
        for relative in (
            FIXTURE_CATALOG_PATH,
            HOST_SCHEMA_PATH,
            AGGREGATE_SCHEMA_PATH,
        ):
            source_payload = self._git_file_bytes(
                commit, relative, f"{context} {relative.as_posix()}", errors
            )
            if source_payload is not None:
                try:
                    working_payload = (self.root / relative).read_bytes()
                except OSError as error:
                    errors.append(str(error))
                else:
                    if source_payload != working_payload:
                        errors.append(
                            f"{context} {relative.as_posix()} differs from source_commit"
                        )
        self._validate_fixture_bindings(
            report.get("fixture_bindings"),
            commit,
            fixtures_by_id,
            f"{context}.fixture_bindings",
            errors,
        )
        capabilities = report.get("capabilities")
        if not isinstance(capabilities, list) or len(capabilities) != len(
            CAPABILITY_IDENTITIES
        ):
            errors.append(f"{context}.capabilities must contain exactly A01-A18")
        else:
            for index, expected in enumerate(CAPABILITY_IDENTITIES):
                self._validate_capability(
                    capabilities[index],
                    expected,
                    fixtures_by_id,
                    anchor,
                    f"{context}.capabilities[{index}]",
                    errors,
                )
        limitations = report.get("limitations")
        if not isinstance(limitations, list) or len(limitations) != len(set(limitations)) or any(
            not isinstance(item, str) or not item for item in limitations
        ):
            errors.append(f"{context}.limitations must be unique non-empty strings")

    def load_and_validate_raw_reports(
        self,
    ) -> tuple[list[dict[str, Any]], list[str]]:
        errors = validate_schema_bundle(self.root)
        preregistration = self._read_required_json(PREREGISTRATION_PATH, errors)
        catalog = self._read_required_json(FIXTURE_CATALOG_PATH, errors)
        assignments, fixtures = self._preregistration_context(
            preregistration, catalog, errors
        )
        reports: list[dict[str, Any]] = []
        for anchor in ANCHORS:
            report = self._read_required_json(RAW_REPORT_PATHS[anchor], errors)
            if report is None:
                continue
            raw_payload = (self.root / RAW_REPORT_PATHS[anchor]).read_bytes()
            if raw_payload != canonical_json_bytes(report):
                errors.append(
                    f"{RAW_REPORT_PATHS[anchor].as_posix()} is not canonical deterministic JSON"
                )
            reports.append(report)
            self._validate_raw_report(report, anchor, assignments, fixtures, errors)
        if len(reports) == len(ANCHORS):
            sources = {
                (report.get("source_commit"), report.get("source_tree"))
                for report in reports
            }
            if len(sources) != 1:
                errors.append(
                    "all four raw reports must bind one identical published source commit/tree"
                )
            preregistration_bindings = {
                canonical_json_bytes(report.get("preregistration_binding"))
                for report in reports
            }
            if len(preregistration_bindings) != 1:
                errors.append("all four reports must bind one identical preregistration")
            fixture_bindings = {
                canonical_json_bytes(report.get("fixture_bindings")) for report in reports
            }
            if len(fixture_bindings) != 1:
                errors.append("all four reports must bind identical fixtures/model identity")
            implementation_bindings = {
                canonical_json_bytes(report.get("implementation_bindings"))
                for report in reports
            }
            if len(implementation_bindings) != 1:
                errors.append("all four reports must bind identical implementation sources")
            host_ids: dict[str, dict[str, Any]] = {}
            for report in reports:
                host = report.get("host")
                if not isinstance(host, dict) or not isinstance(host.get("host_id"), str):
                    continue
                host_id = host["host_id"]
                prior = host_ids.get(host_id)
                profile = {key: value for key, value in host.items() if key != "hardware_classes"}
                if prior is not None and prior != profile:
                    errors.append(
                        f"host_id {host_id!r} identifies different host/toolchain profiles"
                    )
                host_ids[host_id] = profile
            errors.extend(validate_instances_against_schemas(self.root, reports))
        return reports, sorted(set(errors))

    @staticmethod
    def _aggregate_generated_at(reports: list[dict[str, Any]]) -> str:
        parsed = [
            datetime.fromisoformat(report["generated_at"].replace("Z", "+00:00"))
            for report in reports
        ]
        latest = max(parsed).astimezone(timezone.utc)
        timespec = "microseconds" if latest.microsecond else "seconds"
        return latest.isoformat(timespec=timespec).replace("+00:00", "Z")

    def build_aggregate(
        self, reports: list[dict[str, Any]]
    ) -> dict[str, Any]:
        source_commit = reports[0]["source_commit"]
        source_tree = reports[0]["source_tree"]
        anchors: list[dict[str, Any]] = []
        for anchor, report in zip(ANCHORS, reports):
            raw_path = RAW_REPORT_PATHS[anchor]
            raw_payload = (self.root / raw_path).read_bytes()
            anchors.append(
                {
                    "anchor": anchor,
                    "generated_at": report["generated_at"],
                    "host": report["host"],
                    "source_report_binding": {
                        "path": raw_path.as_posix(),
                        "size_bytes": len(raw_payload),
                        "sha256": sha256_bytes(raw_payload),
                    },
                    "limitations": report["limitations"],
                }
            )
        capabilities: list[dict[str, Any]] = []
        for index, (identifier, family, method, probe_class) in enumerate(
            CAPABILITY_IDENTITIES
        ):
            capabilities.append(
                {
                    "id": identifier,
                    "family": family,
                    "method": method,
                    "probe_class": probe_class,
                    "anchor_records": [
                        {
                            "anchor": anchor,
                            "report": report["capabilities"][index],
                        }
                        for anchor, report in zip(ANCHORS, reports)
                    ],
                }
            )
        return {
            "schema_version": SCHEMA_VERSION,
            "roadmap_version": ROADMAP_VERSION,
            "phase_id": PHASE_ID,
            "source_commit": source_commit,
            "source_tree": source_tree,
            "generated_at": self._aggregate_generated_at(reports),
            "anchors": anchors,
            "capabilities": capabilities,
        }

    @staticmethod
    def render_markdown(aggregate: dict[str, Any]) -> str:
        lines = [
            "# Apple Upscale Capability Report",
            "",
            f"- **Schema version:** `{aggregate['schema_version']}`",
            f"- **Roadmap version:** `{aggregate['roadmap_version']}`",
            f"- **Phase:** `{aggregate['phase_id']}`",
            f"- **Source commit:** `{aggregate['source_commit']}`",
            f"- **Source tree:** `{aggregate['source_tree']}`",
            f"- **Evidence generation time:** `{aggregate['generated_at']}`",
            "",
            "R01 measures capability and repeatability only. It does not evaluate "
            "perceptual superiority, product qualification, or backend eligibility.",
            "",
            "## Anchor Hosts",
            "",
            "| Anchor | Host ID | Model | Chip | macOS | Xcode | SDK | Raw SHA-256 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for anchor in aggregate["anchors"]:
            host = anchor["host"]
            lines.append(
                f"| `{markdown_cell(anchor['anchor'])}` | `{markdown_cell(host['host_id'])}` | "
                f"`{markdown_cell(host['model_identifier'])}` | {markdown_cell(host['chip'])} | "
                f"`{markdown_cell(host['os_version'])} ({markdown_cell(host['os_build'])})` | "
                f"`{markdown_cell(host['xcode_version'])} ({markdown_cell(host['xcode_build'])})` | "
                f"`{markdown_cell(host['sdk_version'])} ({markdown_cell(host['sdk_build'])})` | "
                f"`{anchor['source_report_binding']['sha256']}` |"
            )
        lines.extend(
            [
                "",
                "## Capability Matrix",
                "",
                "| ID | Family / method | Probe class | Anchor | Compile | Runtime | Reason |",
                "| --- | --- | --- | --- | --- | --- | --- |",
            ]
        )
        for capability in aggregate["capabilities"]:
            for anchor_record in capability["anchor_records"]:
                report = anchor_record["report"]
                lines.append(
                    f"| `{markdown_cell(capability['id'])}` | "
                    f"{markdown_cell(capability['family'])} / "
                    f"{markdown_cell(capability['method'])} | "
                    f"`{markdown_cell(capability['probe_class'])}` | "
                    f"`{markdown_cell(anchor_record['anchor'])}` | "
                    f"`{markdown_cell(report['compile_state'])}` | "
                    f"`{markdown_cell(report['runtime_disposition'])}` | "
                    f"`{markdown_cell(report['reason_code'])}` |"
                )
        lines.extend(
            [
                "",
                "Every matrix entry preserves `not_evaluated_in_r01` for product "
                "qualification, backend eligibility, and quality evaluation.",
                "",
            ]
        )
        return "\n".join(lines)

    def expected_outputs(
        self,
    ) -> tuple[bytes | None, bytes | None, list[str]]:
        reports, errors = self.load_and_validate_raw_reports()
        if errors or len(reports) != len(ANCHORS):
            return None, None, errors
        aggregate = self.build_aggregate(reports)
        errors.extend(
            validate_instances_against_schemas(self.root, reports, aggregate)
        )
        check_privacy(aggregate, "aggregate", errors)
        json_payload = canonical_json_bytes(aggregate)
        markdown_payload = self.render_markdown(aggregate).encode("utf-8")
        for relative, payload in (
            (AGGREGATE_JSON_PATH, json_payload),
            (AGGREGATE_MARKDOWN_PATH, markdown_payload),
        ):
            if len(payload) > MAX_EVIDENCE_FILE_BYTES:
                errors.append(f"{relative.as_posix()} exceeds the evidence-file limit")
        raw_size = sum((self.root / path).stat().st_size for path in RAW_REPORT_PATHS.values())
        fixture_size = sum(
            binding["size_bytes"]
            for binding in reports[0]["fixture_bindings"]
            if isinstance(binding.get("size_bytes"), int)
        )
        if (
            raw_size + fixture_size + len(json_payload) + len(markdown_payload)
            > MAX_PHASE_EVIDENCE_BYTES
        ):
            errors.append("R01 capability evidence exceeds the 100 MiB phase limit")
        return (json_payload, markdown_payload, sorted(set(errors)))

    def check_outputs(self) -> list[str]:
        expected_json, expected_markdown, errors = self.expected_outputs()
        if expected_json is None or expected_markdown is None:
            return errors
        for relative, expected in (
            (AGGREGATE_JSON_PATH, expected_json),
            (AGGREGATE_MARKDOWN_PATH, expected_markdown),
        ):
            link = symlink_component(self.root, relative)
            if link is not None:
                errors.append(
                    f"{relative.as_posix()} contains symbolic-link component {link}"
                )
            try:
                observed = (self.root / relative).read_bytes()
            except OSError as error:
                errors.append(str(error))
                continue
            if observed != expected:
                errors.append(f"{relative.as_posix()} differs from deterministic output")
        return sorted(set(errors))


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(payload)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--aggregate", action="store_true")
    action.add_argument("--check", action="store_true")
    parser.add_argument(
        "--root",
        type=Path,
        default=REPOSITORY_ROOT,
        help=argparse.SUPPRESS,
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    verifier = R01CapabilityVerifier(arguments.root)
    if arguments.check:
        errors = verifier.check_outputs()
    else:
        expected_json, expected_markdown, errors = verifier.expected_outputs()
        if not errors and expected_json is not None and expected_markdown is not None:
            output_payloads = (
                (AGGREGATE_JSON_PATH, expected_json),
                (AGGREGATE_MARKDOWN_PATH, expected_markdown),
            )
            for relative, _ in output_payloads:
                link = symlink_component(arguments.root.resolve(), relative.parent)
                if link is not None:
                    errors.append(
                        f"{relative.as_posix()} parent contains symbolic-link component {link}"
                    )
            if not errors:
                for relative, payload in output_payloads:
                    atomic_write(arguments.root / relative, payload)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    action = "check" if arguments.check else "aggregate"
    print(f"R01 capability {action}: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
