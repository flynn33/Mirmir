#!/usr/bin/env python3
"""Validate the closed R01 preregistration and deterministic fixture contract."""

from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any, Iterable

from phase_evidence import (
    EMAIL_PATTERN,
    PRIVATE_EVIDENCE_KEYS,
    PRIVATE_PATH_PATTERN,
    decode_json,
    validate_json_schema_instance,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r01/records/preregistration.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r01-fixture-catalog-v1.json"
)
ROADMAP_PATH = Path(
    "docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json"
)

ANCHOR_CONTRACTS = (
    (
        "oldest-supported",
        "oldest-supported Apple Silicon on macOS 15.4",
        "apple_silicon",
    ),
    (
        "m3-air",
        "current M3 MacBook Air class on macOS 26",
        "macbook_air",
    ),
    (
        "pro-max",
        "current Pro/Max performance tier",
        "pro_max_tier",
    ),
    (
        "core-ai",
        "macOS/Xcode 27 host capable of probing Core AI",
        "core_ai_capable",
    ),
)

CAPABILITY_CLASSES = {
    "primary_scaler": (
        "A01",
        "A02",
        "A06",
        "A07",
        "A08",
        "A09",
        "A11",
        "A12",
        "A14",
        "A16",
    ),
    "support_filter": ("A04", "A13", "A15", "A17"),
    "temporal_analyzer": ("A05",),
    "cadence_transform": ("A03", "A10"),
    "analysis_runtime": ("A18",),
}

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

COLOR_CONTRACT = {
    "chroma_siting": "left",
    "color_primaries": "ITU_R_709_2",
    "matrix": "ITU_R_709_2",
    "range": "video",
    "transfer_function": "ITU_R_709_2",
}

COMMON_METRICS = (
    "initialization_time_monotonic",
    "acquisition_time_monotonic",
    "median_wall_time",
    "p95_wall_time",
    "throughput",
    "peak_resident_memory_delta",
    "repeatability_hash_or_tolerance",
)

CLASS_METRICS = {
    "primary_scaler": COMMON_METRICS
    + ("scale", "output_dimensions", "output_format", "frame_rate"),
    "support_filter": COMMON_METRICS
    + ("preserved_dimensions", "preserved_format", "required_guidance"),
    "temporal_analyzer": COMMON_METRICS
    + ("flow_dimensions", "flow_format", "confidence_availability"),
    "cadence_transform": COMMON_METRICS
    + ("generated_frame_count", "output_cadence", "timestamp_contract"),
    "analysis_runtime": COMMON_METRICS
    + (
        "load_time",
        "specialization_time",
        "inference_time",
        "zero_copy_disposition",
        "stateful_execution_disposition",
    ),
}

STOP_RULES = (
    (
        "identity_drift",
        "Stop when the implementation commit, source tree, host identity, or toolchain identity differs from the frozen assignment.",
    ),
    (
        "assignment_change",
        "Invalidate the prior host report and preregister a replacement before any rerun when an assigned host changes.",
    ),
    (
        "fixture_or_model_change",
        "Stop rather than alter a frozen fixture or probe model; an incompatible public contract receives a restricted or unsupported disposition.",
    ),
    (
        "schema_or_catalog_drift",
        "Stop when the preregistration schema, fixture catalog binding, fixture order, or capability assignment does not validate exactly.",
    ),
    (
        "session_failure",
        "Stop a session at 120 seconds and classify timeout, unsupported contract, setup failure, processing failure, and resource failure separately.",
    ),
    (
        "qualification_boundary",
        "Stop any interpretation of R01 runnable evidence as perceptual superiority, product qualification, or backend eligibility.",
    ),
)

HEX_64 = re.compile(r"^[0-9a-f]{64}$")
APPLE_SILICON_CHIP = re.compile(r"^Apple M[1-9][0-9]*(?: (?:Pro|Max|Ultra))?$")
PRO_MAX_CHIP = re.compile(r"^Apple M[1-9][0-9]* (?:Pro|Max)$")
LABELED_PRIVATE_VALUE_PATTERN = re.compile(
    r"(?i)(?:serial(?: number)?|hardware uuid|account(?: id)?|user(?:name)?|user name)\s*[:=]"
)


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = decode_json(path.read_text(encoding="utf-8"))
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    return value


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class HostFactCollectionError(ValueError):
    """Raised without exposing the underlying command output."""


def collect_host_facts(
    run: Any = subprocess.run,
) -> dict[str, object]:
    """Collect only the allowlisted host/toolchain facts accepted by R01."""

    def one_line(command: tuple[str, ...], label: str) -> str:
        try:
            completed = run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise HostFactCollectionError(
                f"unable to collect allowlisted {label} fact"
            ) from error
        value = completed.stdout.strip()
        if not value or "\n" in value or "\r" in value:
            raise HostFactCollectionError(
                f"allowlisted {label} fact did not have the closed one-line shape"
            )
        return value

    model_identifier = one_line(("/usr/sbin/sysctl", "-n", "hw.model"), "model")
    chip = one_line(
        ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"), "chip"
    )
    memory = one_line(("/usr/sbin/sysctl", "-n", "hw.memsize"), "memory")
    if not memory.isdigit() or int(memory) < 1:
        raise HostFactCollectionError("allowlisted memory fact was not a positive integer")
    os_version = one_line(("/usr/bin/sw_vers", "-productVersion"), "OS version")
    os_build = one_line(("/usr/bin/sw_vers", "-buildVersion"), "OS build")
    try:
        xcode = run(
            ("/usr/bin/xcodebuild", "-version"),
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise HostFactCollectionError(
            "unable to collect allowlisted Xcode version facts"
        ) from error
    xcode_match = re.fullmatch(
        r"Xcode ([^\r\n]+)\r?\nBuild version ([^\r\n]+)\r?\n?",
        xcode.stdout,
    )
    if xcode_match is None:
        raise HostFactCollectionError(
            "allowlisted Xcode version facts did not have the closed shape"
        )
    sdk_version = one_line(
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "SDK version",
    )
    sdk_build = one_line(
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "SDK build",
    )
    return {
        "model_identifier": model_identifier,
        "chip": chip,
        "memory_bytes": int(memory),
        "os_version": os_version,
        "os_build": os_build,
        "xcode_version": xcode_match.group(1),
        "xcode_build": xcode_match.group(2),
        "sdk_version": sdk_version,
        "sdk_build": sdk_build,
    }


def _nv12_rows(width: int, height: int, frame_index: int) -> Iterable[bytes]:
    if width % 2 != 0 or height % 2 != 0:
        raise ValueError("NV12 dimensions must be even")
    for y in range(height):
        yield bytes(
            16 + ((13 * x + 17 * y + 19 * frame_index + ((x * y) % 31)) % 220)
            for x in range(width)
        )
    for chroma_y in range(height // 2):
        row = bytearray(width)
        for chroma_x in range(width // 2):
            row[chroma_x * 2] = 16 + (
                (
                    7 * chroma_x
                    + 11 * chroma_y
                    + 23 * frame_index
                    + ((chroma_x * chroma_y) % 29)
                )
                % 225
            )
            row[chroma_x * 2 + 1] = 16 + (
                (
                    5 * chroma_x
                    + 19 * chroma_y
                    + 31 * frame_index
                    + ((chroma_x + chroma_y) % 37)
                )
                % 225
            )
        yield bytes(row)


def _gray8_rows(width: int, height: int, frame_index: int) -> Iterable[bytes]:
    for y in range(height):
        yield bytes(
            (3 * x + 5 * y + 7 * frame_index + ((x * y) % 251)) % 256
            for x in range(width)
        )


def _bgra_rows(width: int, height: int, frame_index: int) -> Iterable[bytes]:
    for y in range(height):
        row = bytearray(width * 4)
        for x in range(width):
            offset = x * 4
            row[offset] = (3 * x + 5 * y + 11 * frame_index) % 256
            row[offset + 1] = (7 * x + 2 * y + 13 * frame_index) % 256
            row[offset + 2] = (x + 9 * y + 17 * frame_index) % 256
            row[offset + 3] = 255
        yield bytes(row)


@lru_cache(maxsize=None)
def _fixture_digest(
    media_kind: str, width: int, height: int, frame_index: int
) -> tuple[int, str]:
    if media_kind == "nv12_frame":
        rows = _nv12_rows(width, height, frame_index)
        byte_count = width * height * 3 // 2
    elif media_kind == "gray8_plane":
        rows = _gray8_rows(width, height, frame_index)
        byte_count = width * height
    elif media_kind == "bgra_frame":
        rows = _bgra_rows(width, height, frame_index)
        byte_count = width * height * 4
    else:
        raise ValueError(f"unsupported deterministic media kind: {media_kind}")
    digest = hashlib.sha256()
    observed = 0
    for row in rows:
        digest.update(row)
        observed += len(row)
    if observed != byte_count:
        raise ValueError(
            f"generated {observed} bytes for {media_kind}; expected {byte_count}"
        )
    return byte_count, digest.hexdigest()


def _frozen_fixture(
    fixture_id: str,
    role: str,
    media_kind: str,
    width: int,
    height: int,
    frame_index: int,
    *,
    scale_output: tuple[int, int] | None = None,
    timing: dict[str, int] | None = None,
) -> dict[str, Any]:
    byte_count, content_sha256 = _fixture_digest(
        media_kind, width, height, frame_index
    )
    pixel_formats = {
        "nv12_frame": "420v",
        "gray8_plane": "L008",
        "bgra_frame": "BGRA",
    }
    return {
        "id": fixture_id,
        "status": "frozen",
        "role": role,
        "media_kind": media_kind,
        "dimensions": {"width": width, "height": height},
        "pixel_format": pixel_formats[media_kind],
        "color_contract": COLOR_CONTRACT if media_kind == "nv12_frame" else None,
        "frame_index": frame_index,
        "scale_output": (
            {"width": scale_output[0], "height": scale_output[1]}
            if scale_output is not None
            else None
        ),
        "timing": timing,
        "generator": "r01-analytic-pixel-v1",
        "materialization_path": (
            f"project-notes/evidence/r01/fixtures/{fixture_id}.bin"
        ),
        "byte_count": byte_count,
        "content_sha256": content_sha256,
        "model_identity": None,
    }


def build_fixture_catalog() -> dict[str, Any]:
    frame_duration = {"duration": 20, "timescale": 600}
    fixtures = [
        _frozen_fixture(
            "scaler-720p",
            "primary_scaler_input_1280x720_to_1920x1080",
            "nv12_frame",
            1280,
            720,
            0,
            scale_output=(1920, 1080),
        ),
        _frozen_fixture(
            "scaler-1080p",
            "primary_scaler_input_1920x1080_to_3840x2160",
            "nv12_frame",
            1920,
            1080,
            1,
            scale_output=(3840, 2160),
        ),
        _frozen_fixture(
            "support-frame",
            "support_filter_current_frame",
            "nv12_frame",
            1920,
            1080,
            2,
        ),
        _frozen_fixture(
            "support-guidance",
            "support_filter_canonical_guidance",
            "gray8_plane",
            1920,
            1080,
            2,
        ),
        _frozen_fixture(
            "support-history",
            "support_filter_canonical_history",
            "nv12_frame",
            1920,
            1080,
            1,
        ),
        _frozen_fixture(
            "temporal-frame-0",
            "temporal_analyzer_ordered_frame_0",
            "nv12_frame",
            1920,
            1080,
            3,
        ),
        _frozen_fixture(
            "temporal-frame-1",
            "temporal_analyzer_ordered_frame_1",
            "nv12_frame",
            1920,
            1080,
            4,
        ),
        _frozen_fixture(
            "cadence-frame-0",
            "cadence_transform_ordered_frame_0",
            "nv12_frame",
            1920,
            1080,
            5,
            timing={"pts": 0, **frame_duration},
        ),
        _frozen_fixture(
            "cadence-frame-1",
            "cadence_transform_ordered_frame_1",
            "nv12_frame",
            1920,
            1080,
            6,
            timing={"pts": 20, **frame_duration},
        ),
        _frozen_fixture(
            "analysis-proxy",
            "analysis_runtime_bgra_proxy",
            "bgra_frame",
            512,
            288,
            7,
        ),
        {
            "id": "analysis-probe-model",
            "status": "unassigned",
            "role": "analysis_runtime_probe_model",
            "media_kind": "model_artifact",
            "dimensions": None,
            "pixel_format": None,
            "color_contract": None,
            "frame_index": None,
            "scale_output": None,
            "timing": None,
            "generator": None,
            "materialization_path": None,
            "byte_count": None,
            "content_sha256": None,
            "model_identity": None,
        },
    ]
    return {
        "schema_version": "1.0.0",
        "phase_id": "R01",
        "generator_contract": {
            "id": "r01-analytic-pixel-v1",
            "byte_order": "row_major_planes_in_declared_pixel_format_order",
            "nv12_luma_formula": "16+((13*x+17*y+19*i+((x*y)%31))%220)",
            "nv12_cb_formula": "16+((7*cx+11*cy+23*i+((cx*cy)%29))%225)",
            "nv12_cr_formula": "16+((5*cx+19*cy+31*i+((cx+cy)%37))%225)",
            "gray8_formula": "(3*x+5*y+7*i+((x*y)%251))%256",
            "bgra_formula": "B=(3*x+5*y+11*i)%256;G=(7*x+2*y+13*i)%256;R=(x+9*y+17*i)%256;A=255",
        },
        "fixture_sets": {
            "primary_scaler": ["scaler-720p", "scaler-1080p"],
            "support_filter": [
                "support-frame",
                "support-guidance",
                "support-history",
            ],
            "temporal_analyzer": ["temporal-frame-0", "temporal-frame-1"],
            "cadence_transform": ["cadence-frame-0", "cadence-frame-1"],
            "analysis_runtime": ["analysis-proxy", "analysis-probe-model"],
        },
        "fixtures": fixtures,
    }


def build_capabilities(roadmap: dict[str, Any]) -> list[dict[str, str]]:
    class_by_id = {
        capability_id: probe_class
        for probe_class, capability_ids in CAPABILITY_CLASSES.items()
        for capability_id in capability_ids
    }
    methods = roadmap.get("apple_methods")
    if not isinstance(methods, list):
        raise ValueError("roadmap apple_methods must be an array")
    capabilities: list[dict[str, str]] = []
    for value in methods:
        if not isinstance(value, dict):
            raise ValueError("roadmap apple_methods entries must be objects")
        capability_id = value.get("id")
        family = value.get("family")
        method = value.get("method")
        if not all(isinstance(item, str) for item in (capability_id, family, method)):
            raise ValueError("roadmap capability identity fields must be strings")
        if capability_id not in class_by_id:
            raise ValueError(f"unknown R01 capability ID: {capability_id}")
        capabilities.append(
            {
                "id": capability_id,
                "family": family,
                "method": method,
                "probe_class": class_by_id[capability_id],
            }
        )
    expected_ids = [f"A{index:02d}" for index in range(1, 19)]
    if [item["id"] for item in capabilities] != expected_ids:
        raise ValueError("roadmap capability IDs/order must be exactly A01-A18")
    return capabilities


def build_offline_preregistration(
    roadmap: dict[str, Any], fixture_catalog_sha256: str
) -> dict[str, Any]:
    return {
        "schema_version": "1.0.0",
        "roadmap_version": "1.0.1",
        "phase_id": "R01",
        "preregistration_state": "offline_contract_frozen_live_blocked",
        "anchor_assignments": [
            {
                "anchor": anchor,
                "contract": contract,
                "assignment_state": "unassigned",
                "host_profile": None,
            }
            for anchor, contract, _ in ANCHOR_CONTRACTS
        ],
        "capabilities": build_capabilities(roadmap),
        "fixture_catalog": {
            "path": FIXTURE_CATALOG_PATH.as_posix(),
            "sha256": fixture_catalog_sha256,
        },
        "execution_controls": {
            "sessions": 3,
            "warm_up_units_per_session": 5,
            "measured_units_per_session": 30,
            "timeout_seconds_per_session": 120,
            "repeatability_observations": 3,
            "clock": "monotonic",
        },
        "class_metrics": {
            probe_class: list(metrics)
            for probe_class, metrics in CLASS_METRICS.items()
        },
        "failure_classes": [
            "timeout",
            "unsupported_contract",
            "setup_failure",
            "processing_failure",
            "resource_failure",
        ],
        "stop_rules": [
            {"id": rule_id, "description": description}
            for rule_id, description in STOP_RULES
        ],
        "nonapplicable_metric_policy": (
            "present_with_not_applicable_and_class_derived_reason"
        ),
        "measurement_boundary": (
            "capability_and_repeatability_only_not_perceptual_superiority_or_product_qualification"
        ),
        "live_controls": {
            "runner": (
                "Scripts/run-r01-capability-probe.sh --anchor <anchor> --output <path>"
            ),
            "live_environment": "MIRMIR_R01_LIVE_PROBES=1",
            "acquisition_environment": (
                "MIRMIR_R01_ALLOW_MODEL_ACQUISITION=1"
            ),
        },
    }


def _catalog_model_errors(model: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(model, dict):
        return ["analysis-probe-model fixture entry must be an object"]
    expected_keys = set(build_fixture_catalog()["fixtures"][-1])
    if set(model) != expected_keys:
        errors.append("analysis-probe-model fields differ from the closed catalog")
        return errors
    if model["id"] != "analysis-probe-model":
        errors.append("analysis-probe-model fixture ID differs")
    if model["role"] != "analysis_runtime_probe_model":
        errors.append("analysis-probe-model role differs")
    for key in (
        "media_kind",
        "dimensions",
        "pixel_format",
        "color_contract",
        "frame_index",
        "scale_output",
        "timing",
        "generator",
    ):
        expected = build_fixture_catalog()["fixtures"][-1][key]
        if model[key] != expected:
            errors.append(f"analysis-probe-model {key} differs from policy")
    if model["status"] == "unassigned":
        for key in (
            "materialization_path",
            "byte_count",
            "content_sha256",
            "model_identity",
        ):
            if model[key] is not None:
                errors.append(f"unassigned analysis-probe-model {key} must be null")
    elif model["status"] == "frozen":
        if not isinstance(model["materialization_path"], str):
            errors.append("frozen analysis-probe-model path must be a string")
        if not isinstance(model["byte_count"], int) or model["byte_count"] < 1:
            errors.append("frozen analysis-probe-model byte_count must be positive")
        if not isinstance(model["content_sha256"], str) or not HEX_64.fullmatch(
            model["content_sha256"]
        ):
            errors.append("frozen analysis-probe-model SHA-256 is invalid")
        if not isinstance(model["model_identity"], str) or not model[
            "model_identity"
        ]:
            errors.append("frozen analysis-probe-model identity must be non-empty")
    else:
        errors.append("analysis-probe-model status must be unassigned or frozen")
    return errors


class PreregistrationVerifier:
    def __init__(
        self,
        repository_root: Path,
        preregistration_path: Path = PREREGISTRATION_PATH,
        schema_path: Path = PREREGISTRATION_SCHEMA_PATH,
        fixture_schema_path: Path = FIXTURE_CATALOG_SCHEMA_PATH,
        roadmap_path: Path = ROADMAP_PATH,
    ) -> None:
        self.repository_root = repository_root.resolve()
        self.preregistration_path = self._resolve(preregistration_path)
        self.schema_path = self._resolve(schema_path)
        self.fixture_schema_path = self._resolve(fixture_schema_path)
        self.roadmap_path = self._resolve(roadmap_path)

    def _resolve(self, path: Path) -> Path:
        return path if path.is_absolute() else self.repository_root / path

    def _safe_repository_path(
        self,
        value: object,
        context: str,
        *,
        require_regular_file: bool = False,
    ) -> tuple[Path | None, str | None]:
        if not isinstance(value, str) or not value:
            return None, f"{context} must be a non-empty repository-relative path"
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or value != pure.as_posix():
            return None, f"{context} must be a normalized repository-relative path"
        candidate = self.repository_root / pure
        component = self.repository_root
        for part in pure.parts:
            component = component / part
            if component.is_symlink():
                return None, f"{context} must not contain a symbolic-link component"
        resolved = candidate.resolve()
        try:
            resolved.relative_to(self.repository_root)
        except ValueError:
            return None, f"{context} escapes the repository root"
        if require_regular_file and not resolved.is_file():
            return None, f"{context} must resolve to a regular file"
        return resolved, None

    @staticmethod
    def _privacy_errors(value: object, context: str) -> list[str]:
        errors: list[str] = []
        if isinstance(value, dict):
            for key, item in value.items():
                normalized_key = str(key).strip().lower().replace("-", "_")
                if normalized_key in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context}.{key} is a prohibited private field")
                errors.extend(
                    PreregistrationVerifier._privacy_errors(
                        item, f"{context}.{key}"
                    )
                )
        elif isinstance(value, list):
            for index, item in enumerate(value):
                errors.extend(
                    PreregistrationVerifier._privacy_errors(
                        item, f"{context}[{index}]"
                    )
                )
        elif isinstance(value, str):
            if EMAIL_PATTERN.search(value):
                errors.append(f"{context} contains an email address")
            if PRIVATE_PATH_PATTERN.search(value):
                errors.append(f"{context} contains a private filesystem path")
            if LABELED_PRIVATE_VALUE_PATTERN.search(value):
                errors.append(f"{context} contains a labeled private identifier")
        return errors

    def check(self) -> list[str]:
        errors: list[str] = []
        try:
            preregistration = read_json(self.preregistration_path)
            schema = read_json(self.schema_path)
            fixture_schema = read_json(self.fixture_schema_path)
            roadmap = read_json(self.roadmap_path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return [str(error)]

        errors.extend(validate_json_schema_instance(schema, preregistration))

        catalog_binding = preregistration.get("fixture_catalog")
        catalog: dict[str, Any] | None = None
        if isinstance(catalog_binding, dict):
            catalog_path, path_error = self._safe_repository_path(
                catalog_binding.get("path"),
                "fixture_catalog.path",
                require_regular_file=True,
            )
            if path_error is not None:
                errors.append(path_error)
            elif catalog_path is not None:
                try:
                    catalog = read_json(catalog_path)
                except (OSError, ValueError, json.JSONDecodeError) as error:
                    errors.append(str(error))
                else:
                    observed_hash = sha256_file(catalog_path)
                    if catalog_binding.get("sha256") != observed_hash:
                        errors.append("fixture catalog SHA-256 differs from its binding")
        if catalog is not None:
            errors.extend(validate_json_schema_instance(fixture_schema, catalog))
            errors.extend(self._check_catalog(catalog))

        try:
            expected_capabilities = build_capabilities(roadmap)
        except ValueError as error:
            errors.append(str(error))
        else:
            if preregistration.get("capabilities") != expected_capabilities:
                errors.append(
                    "capability identities/classes must match roadmap A01-A18 exactly"
                )

        expected_static = build_offline_preregistration(roadmap, "0" * 64)
        for key in (
            "schema_version",
            "roadmap_version",
            "phase_id",
            "execution_controls",
            "class_metrics",
            "failure_classes",
            "stop_rules",
            "nonapplicable_metric_policy",
            "measurement_boundary",
            "live_controls",
        ):
            if preregistration.get(key) != expected_static[key]:
                errors.append(f"{key} differs from the closed R01 policy")
        errors.extend(self._check_assignments(preregistration))
        return sorted(set(errors))

    def _check_catalog(self, catalog: dict[str, Any]) -> list[str]:
        errors: list[str] = []
        expected = build_fixture_catalog()
        if set(catalog) != set(expected):
            errors.append("fixture catalog top-level fields differ from the closed schema")
            return errors
        for key in ("schema_version", "phase_id", "generator_contract", "fixture_sets"):
            if catalog.get(key) != expected[key]:
                errors.append(f"fixture catalog {key} differs from policy")
        fixtures = catalog.get("fixtures")
        if not isinstance(fixtures, list) or len(fixtures) != len(FIXTURE_IDS):
            errors.append("fixture catalog entries must be exactly the eleven R01 fixtures")
            return errors
        if [item.get("id") if isinstance(item, dict) else None for item in fixtures] != list(
            FIXTURE_IDS
        ):
            errors.append("fixture IDs/order differ from the closed R01 contract")
            return errors
        for index, expected_fixture in enumerate(expected["fixtures"][:-1]):
            if fixtures[index] != expected_fixture:
                errors.append(
                    f"fixture {expected_fixture['id']} differs from its deterministic contract"
                )
        errors.extend(_catalog_model_errors(fixtures[-1]))
        return errors

    def _check_assignments(self, preregistration: dict[str, Any]) -> list[str]:
        errors: list[str] = []
        assignments = preregistration.get("anchor_assignments")
        if not isinstance(assignments, list):
            return ["anchor_assignments must be an array"]
        expected_anchors = [anchor for anchor, _, _ in ANCHOR_CONTRACTS]
        observed_anchors = [
            value.get("anchor") if isinstance(value, dict) else None
            for value in assignments
        ]
        if observed_anchors != expected_anchors:
            errors.append("anchor IDs/order differ from the four closed R01 anchors")
            return errors
        assigned_count = 0
        for value, (anchor, contract, hardware_class) in zip(
            assignments, ANCHOR_CONTRACTS
        ):
            if not isinstance(value, dict):
                errors.append(f"anchor {anchor} assignment must be an object")
                continue
            if value.get("contract") != contract:
                errors.append(f"anchor {anchor} contract differs from policy")
            state = value.get("assignment_state")
            profile = value.get("host_profile")
            if state == "unassigned":
                if profile is not None:
                    errors.append(f"unassigned anchor {anchor} host_profile must be null")
                continue
            if state != "assigned" or not isinstance(profile, dict):
                errors.append(f"anchor {anchor} assignment state/profile is invalid")
                continue
            assigned_count += 1
            errors.extend(self._privacy_errors(profile, f"anchor {anchor} host_profile"))
            if profile.get("hardware_class") != hardware_class:
                errors.append(f"anchor {anchor} hardware class differs from its role")
            chip = profile.get("chip")
            os_version = profile.get("os_version")
            xcode_version = profile.get("xcode_version")
            sdk_version = profile.get("sdk_version")
            if anchor == "oldest-supported":
                if not isinstance(chip, str) or APPLE_SILICON_CHIP.fullmatch(chip) is None:
                    errors.append("oldest-supported anchor requires an Apple M-series chip")
                if not (
                    isinstance(os_version, str)
                    and (os_version == "15.4" or os_version.startswith("15.4."))
                ):
                    errors.append("oldest-supported anchor requires macOS 15.4")
            if anchor == "m3-air":
                if chip != "Apple M3":
                    errors.append("m3-air anchor requires chip exactly Apple M3")
                if not (
                    isinstance(os_version, str)
                    and (os_version == "26" or os_version.startswith("26."))
                ):
                    errors.append("m3-air anchor requires macOS 26")
            if anchor == "pro-max" and (
                not isinstance(chip, str) or PRO_MAX_CHIP.fullmatch(chip) is None
            ):
                errors.append("pro-max anchor requires an Apple Pro or Max chip")
            if anchor == "core-ai":
                for value_name, value in (
                    ("macOS", os_version),
                    ("Xcode", xcode_version),
                    ("SDK", sdk_version),
                ):
                    try:
                        major = int(str(value).split(".", 1)[0])
                    except ValueError:
                        major = -1
                    if major < 27:
                        errors.append(f"core-ai anchor requires {value_name} major 27 or newer")
        state = preregistration.get("preregistration_state")
        if state == "offline_contract_frozen_live_blocked" and assigned_count != 0:
            errors.append("offline preregistration state requires all anchors unassigned")
        if state == "live_assignments_frozen" and assigned_count != len(ANCHOR_CONTRACTS):
            errors.append("live preregistration state requires all four anchors assigned")
        return errors

    def check_live_readiness(
        self, anchor: str, host_facts: dict[str, object] | None = None
    ) -> list[str]:
        errors = self.check()
        if anchor not in {value[0] for value in ANCHOR_CONTRACTS}:
            errors.append(f"invalid anchor: {anchor}")
            return sorted(set(errors))
        try:
            preregistration = read_json(self.preregistration_path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return sorted(set(errors + [str(error)]))
        if preregistration.get("preregistration_state") != "live_assignments_frozen":
            errors.append("live probes are blocked until all four assignments are frozen")
        assignments = preregistration.get("anchor_assignments", [])
        assignment = next(
            (
                item
                for item in assignments
                if isinstance(item, dict) and item.get("anchor") == anchor
            ),
            None,
        )
        if not isinstance(assignment, dict) or assignment.get("assignment_state") != "assigned":
            errors.append(f"anchor {anchor} is not assigned")
        else:
            profile = assignment.get("host_profile")
            if isinstance(profile, dict):
                if host_facts is None:
                    try:
                        host_facts = collect_host_facts()
                    except HostFactCollectionError as error:
                        errors.append(str(error))
                if host_facts is not None:
                    for key in (
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
                        if host_facts.get(key) != profile.get(key):
                            errors.append(
                                f"current host/toolchain {key} differs from anchor {anchor} assignment"
                            )
        catalog_binding = preregistration.get("fixture_catalog")
        if isinstance(catalog_binding, dict):
            catalog_path, path_error = self._safe_repository_path(
                catalog_binding.get("path"),
                "fixture_catalog.path",
                require_regular_file=True,
            )
            if path_error is None and catalog_path is not None and catalog_path.is_file():
                try:
                    catalog = read_json(catalog_path)
                except (OSError, ValueError) as error:
                    errors.append(str(error))
                    return sorted(set(errors))
                fixtures = catalog.get("fixtures", [])
                model = next(
                    (
                        item
                        for item in fixtures
                        if isinstance(item, dict)
                        and item.get("id") == "analysis-probe-model"
                    ),
                    None,
                )
                if anchor == "core-ai":
                    if not isinstance(model, dict) or model.get("status") != "frozen":
                        errors.append(
                            "core-ai live probe requires a frozen analysis-probe-model identity/hash"
                        )
                    elif isinstance(model.get("materialization_path"), str):
                        model_path, model_path_error = self._safe_repository_path(
                            model["materialization_path"],
                            "analysis-probe-model.materialization_path",
                            require_regular_file=True,
                        )
                        if model_path_error is not None:
                            errors.append(model_path_error)
                        elif model_path is not None:
                            if model_path.stat().st_size != model.get("byte_count"):
                                errors.append(
                                    "analysis-probe-model byte count differs from preregistration"
                                )
                            if sha256_file(model_path) != model.get("content_sha256"):
                                errors.append(
                                    "analysis-probe-model SHA-256 differs from preregistration"
                                )
        return sorted(set(errors))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--check-live-readiness", action="store_true")
    action.add_argument("--emit-fixture-catalog", action="store_true")
    parser.add_argument(
        "--anchor",
        choices=[value[0] for value in ANCHOR_CONTRACTS],
        help="Anchor checked by --check-live-readiness.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    if arguments.emit_fixture_catalog:
        print(json.dumps(build_fixture_catalog(), indent=2, sort_keys=True))
        return 0
    if arguments.check_live_readiness and arguments.anchor is None:
        print("ERROR: --check-live-readiness requires --anchor", file=sys.stderr)
        return 2
    verifier = PreregistrationVerifier(REPOSITORY_ROOT)
    errors = (
        verifier.check_live_readiness(arguments.anchor)
        if arguments.check_live_readiness
        else verifier.check()
    )
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("R01 preregistration: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
