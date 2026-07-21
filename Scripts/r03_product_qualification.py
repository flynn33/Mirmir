#!/usr/bin/env python3
"""Validate the additive R03 A11 functional product-qualification contract."""

from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
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
from r02_fixture_generator import nv12_frame_bytes, pcm_s16le_bytes, sha256_hex


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]

PREREGISTRATION_PATH = Path(
    "docs/roadmaps/evidence/r03/records/product-qualification-preregistration-v2.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r03/records/fixtures/"
    "product-qualification-fixture-catalog-v2.json"
)
EXECUTION_RECEIPT_PATH = Path(
    "docs/roadmaps/evidence/r03/records/"
    "product-qualification-execution-receipt-v2.json"
)
DECISION_PATH = Path(
    "docs/roadmaps/evidence/r03/records/product-qualification-decision-v2.json"
)
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r03-product-qualification-preregistration-v2.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r03-product-qualification-fixture-catalog-v2.json"
)
EXECUTION_RECEIPT_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/"
    "r03-product-qualification-execution-receipt-v2.json"
)
DECISION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r03-product-qualification-decision-v2.json"
)
VALIDATOR_PATH = Path("Scripts/r03_product_qualification.py")

HISTORICAL_V1_PATHS = {
    "preregistration": Path("docs/roadmaps/evidence/r03/records/preregistration.json"),
    "fixture_catalog": Path(
        "docs/roadmaps/evidence/r03/records/fixtures/fixture-catalog.json"
    ),
    "baseline_conformance": Path(
        "docs/roadmaps/evidence/r03/records/baseline-conformance.json"
    ),
}
SCHEMA_PATHS = {
    "preregistration": PREREGISTRATION_SCHEMA_PATH,
    "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
    "execution_receipt": EXECUTION_RECEIPT_SCHEMA_PATH,
    "decision": DECISION_SCHEMA_PATH,
}

CANDIDATE_IDENTITY = {
    "backend_id": "r03.mps.lanczos",
    "capability_id": "A11",
    "framework": "MetalPerformanceShaders",
    "framework_symbol": "MPSImageLanczosScale",
    "policy_identity": "r03.a11.product-qualified.no-fallback.v1",
    "material_decision_identity": (
        "r03.a11.genuine-mps-lanczos-product-admission.v1"
    ),
}
CANDIDATE_CONTRACT = {
    **CANDIDATE_IDENTITY,
    "kind": "whole_frame_primary_backend",
    "qualification_scope": "functional_product_eligibility",
    "route_ids": ["scale_3_over_2", "scale_2x"],
}
COLOR_CONTRACT = {
    "pixel_format": "420v",
    "bit_depth": 8,
    "primaries": "ITU_R_709_2",
    "transfer_function": "ITU_R_709_2",
    "matrix": "ITU_R_709_2",
    "range": "video",
    "chroma_location": "left",
}
COLOR_OBSERVATION = {key: value for key, value in COLOR_CONTRACT.items() if key != "bit_depth"}
ROUTE_CONTRACTS = (
    {
        "id": "scale_3_over_2",
        "input_dimensions": {"width": 1280, "height": 720},
        "output_dimensions": {"width": 1920, "height": 1080},
        "scale_numerator": 3,
        "scale_denominator": 2,
        "fixture_binding_id": "r01_scaler_720p",
        "configuration_identity": (
            "r03.mps.lanczos.scale_3_over_2.420v-bt709-video-left.v1"
        ),
    },
    {
        "id": "scale_2x",
        "input_dimensions": {"width": 1920, "height": 1080},
        "output_dimensions": {"width": 3840, "height": 2160},
        "scale_numerator": 2,
        "scale_denominator": 1,
        "fixture_binding_id": "r01_scaler_1080p",
        "configuration_identity": (
            "r03.mps.lanczos.scale_2x.420v-bt709-video-left.v1"
        ),
    },
)

SOURCE_BINDING_REQUIREMENTS = (
    {
        "id": "genuine_mps_scaler_source",
        "path": "Mirmir/Modules/UpscalerEngine/R03MPSScaling.swift",
    },
    {
        "id": "product_admission_source",
        "path": "Mirmir/Modules/UpscalerEngine/R03DeterministicBackend.swift",
    },
    {
        "id": "product_admission_factory_source",
        "path": "Mirmir/Modules/UpscalerEngine/R03A11ProductAdmission.swift",
    },
    {
        "id": "candidate_catalog_source",
        "path": "Mirmir/Modules/UpscalerEngine/R03DeterministicBackendCatalog.swift",
    },
)
TEST_BINDING_REQUIREMENTS = (
    {
        "id": "genuine_native_mps_product_tests",
        "path": "MirmirTests/R03A11NativeMPSProductTests.swift",
    },
    {
        "id": "product_admission_tests",
        "path": "MirmirTests/R03A11ProductAdmissionTests.swift",
    },
    {
        "id": "injected_lifecycle_tests",
        "path": "MirmirTests/R03A11InjectedLifecycleTests.swift",
    },
    {
        "id": "media_test_support",
        "path": "MirmirTests/R03ProductQualificationMediaTestSupport.swift",
    },
    {
        "id": "media_transaction_tests",
        "path": "MirmirTests/R03ProductQualificationMediaTests.swift",
    },
)
ARTIFACT_BINDING_IDS = (
    "xcodebuild_log",
    "xcresult_summary_json",
    "route_observations_json",
    "media_transaction_observations_json",
    "metric_observations_json",
)
TOOLCHAIN_FIELDS = (
    "xcode_version",
    "xcode_build_version",
    "swift_version",
    "sdk_name",
    "sdk_version",
    "destination",
    "command",
    "os_version",
    "architecture",
)

FUNCTIONAL_METRIC_IDS = frozenset(
    {
        "dimension_mismatch_count",
        "pixel_format_mismatch_count",
        "color_identity_mismatch_count",
        "frame_timing_mismatch_count",
        "audio_identity_mismatch_count",
        "metadata_identity_mismatch_count",
        "resource_lifetime_violation_count",
        "silent_fallback_count",
        "incomplete_identity_count",
        "nonfinite_metric_count",
        "distinct_output_hash_count",
        "temporal_repeatability_mismatch_count",
        "peak_in_flight_resources",
    }
)
QUALITY_METRIC_IDS = frozenset(
    {
        "quantized_output_code_maximum_difference",
        "ringing_overshoot_maximum",
        "ringing_undershoot_maximum",
        "chroma_displacement_maximum",
        "edge_profile_measurement_count",
    }
)
PARITY_METRIC_IDS = frozenset(
    {
        "cpu_gpu_normalized_absolute_maximum",
        "cpu_gpu_normalized_rms_maximum",
    }
)
PERFORMANCE_METRIC_IDS = frozenset(
    {
        "throughput_frames_per_second",
        "p95_wall_time_milliseconds",
        "peak_resident_memory_delta_bytes",
    }
)
NOT_APPLICABLE_REASONS = {
    **{
        metric_id: "perceptual_quality_metric_outside_functional_qualification"
        for metric_id in QUALITY_METRIC_IDS
    },
    **{
        metric_id: "non_identical_cpu_gpu_contract_outside_functional_qualification"
        for metric_id in PARITY_METRIC_IDS
    },
    **{
        metric_id: "performance_metric_outside_functional_qualification"
        for metric_id in PERFORMANCE_METRIC_IDS
    },
}
LEGACY_METRIC_CONTRACTS = (
    ("dimension_mismatch_count", "count", "equal", 0),
    ("pixel_format_mismatch_count", "count", "equal", 0),
    ("color_identity_mismatch_count", "count", "equal", 0),
    ("frame_timing_mismatch_count", "count", "equal", 0),
    ("audio_identity_mismatch_count", "count", "equal", 0),
    ("metadata_identity_mismatch_count", "count", "equal", 0),
    ("resource_lifetime_violation_count", "count", "equal", 0),
    ("silent_fallback_count", "count", "equal", 0),
    ("incomplete_identity_count", "count", "equal", 0),
    ("nonfinite_metric_count", "count", "equal", 0),
    ("distinct_output_hash_count", "count_per_three_repeats", "equal", 1),
    (
        "quantized_output_code_maximum_difference",
        "code_value",
        "less_than_or_equal",
        1,
    ),
    (
        "cpu_gpu_normalized_absolute_maximum",
        "normalized",
        "less_than_or_equal",
        "2/65535",
    ),
    (
        "cpu_gpu_normalized_rms_maximum",
        "normalized",
        "less_than_or_equal",
        "1/65535",
    ),
    (
        "ringing_overshoot_maximum",
        "normalized_step_amplitude",
        "less_than_or_equal",
        0.05,
    ),
    (
        "ringing_undershoot_maximum",
        "normalized_step_amplitude",
        "less_than_or_equal",
        0.05,
    ),
    (
        "chroma_displacement_maximum",
        "luma_pixels",
        "less_than_or_equal",
        0.25,
    ),
    (
        "edge_profile_measurement_count",
        "count_per_route",
        "greater_than_or_equal",
        3,
    ),
    ("temporal_repeatability_mismatch_count", "count", "equal", 0),
    ("throughput_frames_per_second", "frames_per_second", "greater_than", 0),
    ("p95_wall_time_milliseconds", "milliseconds", "greater_than", 0),
    (
        "peak_resident_memory_delta_bytes",
        "bytes",
        "finite_nonnegative",
        0,
    ),
    ("peak_in_flight_resources", "count", "less_than_or_equal", 3),
)
METRIC_IDS = tuple(contract[0] for contract in LEGACY_METRIC_CONTRACTS)
METRIC_BY_ID = {contract[0]: contract for contract in LEGACY_METRIC_CONTRACTS}

CHECK_IDS = (
    "historical_v1_preserved",
    "schema_bindings_exact",
    "fixture_catalog_binding_exact",
    "candidate_identity_exact",
    "genuine_mps_execution_observed",
    "both_routes_observed",
    "three_repeat_single_hash",
    "format_and_color_exact",
    "timing_and_metadata_exact",
    "media_transaction_exact",
    "lifecycle_and_lifetime_exact",
    "processing_identity_and_no_fallback_exact",
    "source_test_artifact_bindings_exact",
    "toolchain_complete",
    "metric_matrix_exact",
    "functional_metric_floors_pass",
    "nonapplicable_metric_reasons_exact",
    "observation_status_truthful",
    "decision_derived_from_receipt",
    "authorization_boundary_preserved",
)
STOP_RULE_IDS = (
    "v1_history_drift",
    "v2_contract_drift",
    "candidate_or_identity_drift",
    "nongenuine_framework_path",
    "route_or_repeatability_failure",
    "media_contract_failure",
    "format_lifecycle_or_fallback_failure",
    "binding_or_toolchain_failure",
    "metric_matrix_or_floor_failure",
    "fabricated_observation",
    "noncandidate_qualification",
    "authorization_boundary",
)

EXECUTION_CONTRACT = {
    "framework_execution": "genuine_MPSImageLanczosScale_required",
    "color_contract": "8_bit_nv12_420v_sdr_bt709_video_range_left_chroma",
    "lifecycle_contract": "apple-upscale-session-v1",
    "media_transaction_fixture_id": "r03-v2-media-transaction-2x",
    "repeat_count": 3,
    "single_logical_hash_per_route": True,
    "no_fallback": True,
    "required_source_bindings": list(SOURCE_BINDING_REQUIREMENTS),
    "required_test_bindings": list(TEST_BINDING_REQUIREMENTS),
    "required_artifact_binding_ids": list(ARTIFACT_BINDING_IDS),
    "toolchain_fields": list(TOOLCHAIN_FIELDS),
}
OBSERVATION_POLICY = {
    "hardware_simulator_operator_requirement": "waived_not_a_blocker",
    "current_hardware_capability_observation": "not_observed",
    "current_simulator_execution": "not_observed",
    "current_operator_observed_operation": "not_observed",
    "deterministic_software_execution": "observed_required_for_qualification",
    "truthful_observation_recording": "required",
    "product_runtime_support": "not_claimed",
}
AUTHORIZATION_BOUNDARY = {
    "phase_status": "in_progress",
    "product_qualification": "only_by_complete_derived_v2_decision",
    "production_default": "not_enabled",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "acceptance": "not_claimed",
    "perceptual_quality_claims": "forbidden",
    "performance_claims": "forbidden",
    "publication": "not_authorized_by_this_record",
    "release": "not_authorized",
}
OPTIONAL_EVIDENCE_PATHS = {
    "execution_receipt": EXECUTION_RECEIPT_PATH.as_posix(),
    "decision": DECISION_PATH.as_posix(),
}
DECISION_RESULT = {
    "status": "passed",
    "phase_status": "in_progress",
    "product_qualification": "product_qualified",
    "product_qualified_backend_id": "r03.mps.lanczos",
    "qualification_scope": "functional_product_eligibility",
    "product_runtime_support": "not_claimed",
    "default_backend_id": None,
    "auto_mode": "blocked",
    "holdout": "blocked",
    "acceptance": "not_claimed",
    "perceptual_quality_claims": "forbidden",
    "performance_claims": "forbidden",
    "publication": "not_authorized_by_this_record",
    "release": "not_authorized",
}
DECISION_LIMITATIONS = (
    "This decision establishes only A11 functional product eligibility under the exact v2 routes, format, policy, material-decision, lifecycle, and no-fallback contract.",
    "R03 remains in_progress; phase acceptance, production default, Auto, holdout, product runtime support, publication, and release are not claimed or authorized.",
    "Hardware capability and operator-observed operation remain not_observed; no perceptual-quality or performance claim follows from this functional qualification.",
)

# Updated only after the two additive records are finalized. These hashes cover
# semantic JSON (sorted keys, compact separators), not whitespace.
PREREGISTRATION_SEMANTIC_SHA256 = "TO_BE_FROZEN"
FIXTURE_CATALOG_SEMANTIC_SHA256 = "TO_BE_FROZEN"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return _sha256(payload)


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                child_location = f"{location}.{key}"
                if key.lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context} contains private key at {child_location}")
                visit(child, child_location)
        elif isinstance(item, list):
            for index, child in enumerate(item):
                visit(child, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(f"{context} contains an email address at {location}")
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains a private filesystem path at {location}")

    visit(value, "$")
    return errors


def _metric_preregistration_records() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for metric_id, unit, operator, threshold in LEGACY_METRIC_CONTRACTS:
        measured = metric_id in FUNCTIONAL_METRIC_IDS
        records.append(
            {
                "id": metric_id,
                "unit": unit,
                "operator": operator,
                "threshold": threshold,
                "claim_scope": (
                    "functional_qualification" if measured else "no_claim_not_applicable"
                ),
                "receipt_status": "measured" if measured else "not_applicable",
                "not_applicable_reason": (
                    None if measured else NOT_APPLICABLE_REASONS[metric_id]
                ),
            }
        )
    return records


def _fraction(value: object) -> Fraction | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return Fraction(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return Fraction(str(value))
    if isinstance(value, str):
        try:
            return Fraction(value)
        except (ValueError, ZeroDivisionError):
            return None
    return None


def _metric_passes(metric_id: str, value: object) -> bool:
    contract = METRIC_BY_ID.get(metric_id)
    if contract is None:
        return False
    _identifier, _unit, operator, threshold = contract
    observed = _fraction(value)
    expected = _fraction(threshold)
    if observed is None or expected is None:
        return False
    if operator == "equal":
        return observed == expected
    if operator == "less_than_or_equal":
        return observed <= expected
    if operator == "greater_than":
        return observed > expected
    if operator == "greater_than_or_equal":
        return observed >= expected
    if operator == "finite_nonnegative":
        return observed >= 0
    return False


class R03ProductQualificationVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
        )

    def _read_json(
        self, relative: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        path = self.root / relative
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return None
        return value

    def _read_and_validate(
        self,
        relative: Path,
        schema_relative: Path,
        context: str,
        errors: list[str],
    ) -> dict[str, Any] | None:
        value = self._read_json(relative, context, errors)
        schema = self._read_json(schema_relative, f"{context} schema", errors)
        if value is not None and schema is not None:
            errors.extend(
                f"{context} schema: {error}"
                for error in validate_json_schema_instance(schema, value)
            )
        return value

    def _safe_path(
        self, value: object, context: str, errors: list[str]
    ) -> Path | None:
        if not isinstance(value, str) or not value or "\x00" in value:
            errors.append(f"{context}.path must be a non-empty safe string")
            return None
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != value:
            errors.append(f"{context}.path must be normalized and repository-relative")
            return None
        path = self.root / value
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context}.path must name a regular non-symlink file")
            return None
        try:
            path.resolve().relative_to(self.root)
        except ValueError:
            errors.append(f"{context}.path escapes the repository")
            return None
        return path

    def _check_binding(
        self, binding: object, context: str, errors: list[str]
    ) -> None:
        if not isinstance(binding, dict) or set(binding) != {
            "path",
            "size_bytes",
            "sha256",
        }:
            errors.append(f"{context} keys differ")
            return
        path = self._safe_path(binding.get("path"), context, errors)
        if path is None:
            return
        payload = path.read_bytes()
        if binding.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if binding.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    def _check_exact_binding(
        self,
        binding: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        if not isinstance(binding, dict) or binding.get("path") != expected_path.as_posix():
            errors.append(f"{context}.path differs from the frozen path")
        self._check_binding(binding, context, errors)

    def _check_named_bindings(
        self,
        bindings: object,
        required: tuple[dict[str, str], ...] | tuple[str, ...],
        context: str,
        errors: list[str],
        *,
        verify_files: bool,
        artifact_mode: bool = False,
    ) -> None:
        values = bindings if isinstance(bindings, list) else []
        if not isinstance(bindings, list):
            errors.append(f"{context} must be an array")
            return
        ids = [item.get("id") for item in values if isinstance(item, dict)]
        if len(ids) != len(values) or len(ids) != len(set(ids)):
            errors.append(f"{context} IDs must be present and unique")
        paths = [item.get("path") for item in values if isinstance(item, dict)]
        if len(paths) != len(set(paths)):
            errors.append(f"{context} paths must be unique")
        if artifact_mode:
            required_ids = list(required)
            if any(identifier not in ids for identifier in required_ids):
                errors.append(f"{context} omits a required raw artifact binding")
        else:
            expected_by_id = {item["id"]: item["path"] for item in required}
            for identifier, expected_path in expected_by_id.items():
                matching = [
                    item
                    for item in values
                    if isinstance(item, dict) and item.get("id") == identifier
                ]
                if len(matching) != 1 or matching[0].get("path") != expected_path:
                    errors.append(f"{context} required binding differs: {identifier}")
        for index, item in enumerate(values):
            if not isinstance(item, dict) or set(item) != {
                "id",
                "path",
                "size_bytes",
                "sha256",
            }:
                errors.append(f"{context}[{index}] keys differ")
                continue
            if verify_files:
                self._check_binding(
                    {key: item[key] for key in ("path", "size_bytes", "sha256")},
                    f"{context}[{index}]",
                    errors,
                )

    def _check_source_provenance(
        self,
        source: object,
        bindings: list[dict[str, Any]],
        errors: list[str],
    ) -> None:
        if not isinstance(source, dict) or set(source) != {"commit", "tree"}:
            errors.append("R03 v2 receipt source must contain only commit and tree")
            return
        commit = source.get("commit")
        tree = source.get("tree")
        if not isinstance(commit, str) or not isinstance(tree, str):
            errors.append("R03 v2 receipt source commit/tree must be strings")
            return
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R03 v2 receipt source commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != tree:
            errors.append("R03 v2 receipt source tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R03 v2 receipt source commit must be an ancestor of HEAD")
        for binding in bindings:
            if not isinstance(binding, dict):
                continue
            path = binding.get("path")
            if not isinstance(path, str):
                continue
            historical = self.git_bytes("show", f"{commit}:{path}")
            if historical.returncode != 0 or _sha256(historical.stdout) != binding.get(
                "sha256"
            ):
                errors.append(f"R03 v2 receipt source commit does not bind {path}")

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 preregistration"))
        if (
            PREREGISTRATION_SEMANTIC_SHA256 != "TO_BE_FROZEN"
            and _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256
        ):
            errors.append("R03 v2 preregistration semantic contract differs")
        if value.get("candidate_contract") != CANDIDATE_CONTRACT:
            errors.append("R03 v2 candidate contract differs")
        if value.get("execution_contract") != EXECUTION_CONTRACT:
            errors.append("R03 v2 execution contract differs")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R03 v2 observation policy differs")
        if value.get("authorization_boundary") != AUTHORIZATION_BOUNDARY:
            errors.append("R03 v2 authorization boundary differs")
        if value.get("optional_evidence_paths") != OPTIONAL_EVIDENCE_PATHS:
            errors.append("R03 v2 optional evidence paths differ")
        if value.get("metrics") != _metric_preregistration_records():
            errors.append("R03 v2 metric contracts differ from the 23 legacy identities")
        checks = value.get("checks")
        check_ids = [item.get("id") for item in checks] if isinstance(checks, list) else []
        if check_ids != list(CHECK_IDS) or len(check_ids) != len(set(check_ids)):
            errors.append("R03 v2 check IDs/order differ")
        rules = value.get("stop_rules")
        rule_ids = [item.get("id") for item in rules] if isinstance(rules, list) else []
        if rule_ids != list(STOP_RULE_IDS) or len(rule_ids) != len(set(rule_ids)):
            errors.append("R03 v2 stop-rule IDs/order differ")
        historical = value.get("historical_v1_bindings")
        if not isinstance(historical, dict) or set(historical) != set(HISTORICAL_V1_PATHS):
            errors.append("R03 v2 historical bindings differ")
        else:
            for identifier, path in HISTORICAL_V1_PATHS.items():
                self._check_exact_binding(
                    historical.get(identifier),
                    path,
                    f"R03 v2 historical binding {identifier}",
                    errors,
                )
        schemas = value.get("schema_bindings")
        if not isinstance(schemas, dict) or set(schemas) != set(SCHEMA_PATHS):
            errors.append("R03 v2 schema bindings differ")
        else:
            for identifier, path in SCHEMA_PATHS.items():
                self._check_exact_binding(
                    schemas.get(identifier),
                    path,
                    f"R03 v2 schema binding {identifier}",
                    errors,
                )
        self._check_exact_binding(
            value.get("fixture_catalog_binding"),
            FIXTURE_CATALOG_PATH,
            "R03 v2 fixture catalog binding",
            errors,
        )

    def _expected_media_transaction(self) -> dict[str, object]:
        frame_hashes = [
            sha256_hex(
                nv12_frame_bytes(
                    width=1920,
                    height=1080,
                    seed=303,
                    sequence_number=sequence_number,
                )
            )
            for sequence_number in range(3)
        ]
        return {
            "id": "r03-v2-media-transaction-2x",
            "ownership": "r03_owned_dimension_corrective_fixture",
            "route_id": "scale_2x",
            "generator_contract": "r02-deterministic-contract-fixtures-v1",
            "generator_id": "r02-deterministic-nv12-v1",
            "materialization": "runtime_ephemeral",
            "seed": 303,
            "pixel_format": "420v",
            "source_dimensions": {"width": 1920, "height": 1080},
            "target_dimensions": {"width": 3840, "height": 2160},
            "container_contract": {
                "file_type": "mp4",
                "video_codec": "h264",
                "reopen_required": True,
                "atomic_publication_required": True,
            },
            "audio_contract": {
                "codec": "aac",
                "track_count": 1,
                "sample_rate": 48000,
                "channel_count": 2,
                "source_sample_frames": 480,
                "source_generator_id": "r02-deterministic-pcm-s16le-v1",
                "source_pcm_sha256": sha256_hex(
                    pcm_s16le_bytes(sample_frames=480, channel_count=2, seed=303)
                ),
                "semantic_sha256": (
                    "db9e6e337c0359715f730a6ef39eb44269290390a42a1044b4e481fb61092cef"
                ),
            },
            "frames": [
                {
                    "sequence_number": sequence_number,
                    "pts": {"value": sequence_number * 1001, "timescale": 30000},
                    "duration": {"value": 1001, "timescale": 30000},
                    "metadata_identity": (
                        f"r03-v2-media-transaction.frame-{sequence_number}"
                    ),
                    "resource_token_id": (
                        f"r03-v2-media-transaction.token-{sequence_number}"
                    ),
                    "generated_content_sha256": frame_hashes[sequence_number],
                }
                for sequence_number in range(3)
            ],
            "preserved_r02_semantics": [
                "three_frame_fifo_order",
                "exact_pts",
                "exact_duration",
                "aac_audio_identity",
                "timed_metadata_identity",
                "resource_lifetime_exactly_once",
                "reopen_before_publication",
                "atomic_publication",
                "h264_mp4_container",
            ],
        }

    def _check_fixture_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 fixture catalog"))
        if (
            FIXTURE_CATALOG_SEMANTIC_SHA256 != "TO_BE_FROZEN"
            and _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256
        ):
            errors.append("R03 v2 fixture catalog semantic contract differs")
        if value.get("candidate_identity") != CANDIDATE_IDENTITY:
            errors.append("R03 v2 catalog candidate identity differs")
        if value.get("color_contract") != COLOR_CONTRACT:
            errors.append("R03 v2 catalog color contract differs")
        if value.get("routes") != list(ROUTE_CONTRACTS):
            errors.append("R03 v2 route contracts differ")
        media = value.get("media_transaction")
        expected_media = self._expected_media_transaction()
        if media != expected_media:
            errors.append("R03 v2 media transaction differs")
        if isinstance(media, dict):
            scale_2x = ROUTE_CONTRACTS[1]
            if (
                media.get("source_dimensions") != scale_2x["input_dimensions"]
                or media.get("target_dimensions") != scale_2x["output_dimensions"]
            ):
                errors.append("R03 v2 media transaction is incompatible with scale_2x")
        bindings = value.get("source_bindings")
        values = bindings if isinstance(bindings, list) else []
        ids = [item.get("id") for item in values if isinstance(item, dict)]
        expected_ids = [
            "r03_v1_preregistration",
            "r03_v1_fixture_catalog",
            "r03_v1_blocked_conformance",
            "r02_fixture_catalog",
            "r02_fixture_generator",
            "r01_scaler_720p",
            "r01_scaler_1080p",
            "analytic_fixture_manifest",
            "metric_policy",
            "metric_tolerances",
        ]
        if ids != expected_ids or len(ids) != len(set(ids)):
            errors.append("R03 v2 catalog source binding IDs/order differ")
        for index, binding in enumerate(values):
            if not isinstance(binding, dict) or set(binding) != {
                "id",
                "path",
                "size_bytes",
                "sha256",
            }:
                errors.append(f"R03 v2 catalog source binding {index} keys differ")
                continue
            self._check_binding(
                {key: binding[key] for key in ("path", "size_bytes", "sha256")},
                f"R03 v2 catalog source binding {binding.get('id')}",
                errors,
            )

    def _check_route_results(self, value: object, errors: list[str]) -> None:
        results = value if isinstance(value, list) else []
        if not isinstance(value, list) or len(results) != len(ROUTE_CONTRACTS):
            errors.append("R03 v2 receipt route result count differs")
            return
        for index, route in enumerate(ROUTE_CONTRACTS):
            result = results[index]
            if not isinstance(result, dict):
                errors.append(f"R03 v2 receipt route result is invalid: {route['id']}")
                continue
            if result.get("route_id") != route["id"]:
                errors.append(f"R03 v2 receipt route order differs: {route['id']}")
            if result.get("configuration_identity") != route["configuration_identity"]:
                errors.append(
                    f"R03 v2 receipt configuration identity differs: {route['id']}"
                )
            if (
                result.get("input_dimensions") != route["input_dimensions"]
                or result.get("output_dimensions") != route["output_dimensions"]
            ):
                errors.append(f"R03 v2 receipt route dimensions differ: {route['id']}")
            runs = result.get("runs")
            run_values = runs if isinstance(runs, list) else []
            ordinals = [run.get("run_ordinal") for run in run_values if isinstance(run, dict)]
            if ordinals != [1, 2, 3]:
                errors.append(f"R03 v2 receipt run ordinals differ: {route['id']}")
            hashes: list[object] = []
            for run in run_values:
                if not isinstance(run, dict):
                    continue
                hashes.append(run.get("logical_output_sha256"))
                if run.get("output_dimensions") != route["output_dimensions"]:
                    errors.append(
                        f"R03 v2 receipt run dimensions differ: {route['id']}"
                    )
                if run.get("color_observation") != COLOR_OBSERVATION:
                    errors.append(f"R03 v2 receipt color differs: {route['id']}")
                if run.get("fallback_history") != []:
                    errors.append(f"R03 v2 receipt fallback is nonempty: {route['id']}")
            if len(hashes) != 3 or len(set(hashes)) != 1:
                errors.append(
                    f"R03 v2 receipt requires one logical hash per three runs: {route['id']}"
                )

    def _check_media_result(self, value: object, errors: list[str]) -> None:
        if not isinstance(value, dict) or value.get("fixture_id") != (
            "r03-v2-media-transaction-2x"
        ):
            errors.append("R03 v2 receipt media transaction identity differs")
            return
        runs = value.get("runs")
        run_values = runs if isinstance(runs, list) else []
        ordinals = [run.get("run_ordinal") for run in run_values if isinstance(run, dict)]
        if ordinals != [1, 2, 3]:
            errors.append("R03 v2 receipt media run ordinals differ")
        repeated_hashes: list[object] = []
        for run in run_values:
            if not isinstance(run, dict):
                continue
            if run.get("output_dimensions") != ROUTE_CONTRACTS[1]["output_dimensions"]:
                errors.append("R03 v2 receipt media output dimensions differ")
            if run.get("audio_semantic_sha256") != (
                "db9e6e337c0359715f730a6ef39eb44269290390a42a1044b4e481fb61092cef"
            ):
                errors.append("R03 v2 receipt media audio identity differs")
            if run.get("fallback_history") != []:
                errors.append("R03 v2 receipt media fallback is nonempty")
            repeated_hashes.append(run.get("logical_frame_sha256s"))
            frames = run.get("frame_observations")
            frame_values = frames if isinstance(frames, list) else []
            expected_frames = [
                {
                    "sequence_number": sequence,
                    "pts_value": sequence * 1001,
                    "pts_timescale": 30000,
                    "duration_value": 1001,
                    "duration_timescale": 30000,
                    "metadata_identity": f"r03-v2-media-transaction.frame-{sequence}",
                    "resource_release_count": 1,
                }
                for sequence in range(3)
            ]
            if frame_values != expected_frames:
                errors.append("R03 v2 receipt media frame semantics differ")
        tokens = [json.dumps(item, sort_keys=True) for item in repeated_hashes]
        if len(tokens) != 3 or len(set(tokens)) != 1:
            errors.append("R03 v2 receipt media repeats do not have one logical hash set")

    def _check_metric_results(self, value: object, errors: list[str]) -> None:
        results = value if isinstance(value, list) else []
        ids = [item.get("id") for item in results if isinstance(item, dict)]
        if ids != list(METRIC_IDS) or len(ids) != len(set(ids)):
            errors.append("R03 v2 receipt metric IDs/order differ")
            return
        for result, contract in zip(results, LEGACY_METRIC_CONTRACTS):
            metric_id, unit, _operator, _threshold = contract
            if not isinstance(result, dict) or result.get("unit") != unit:
                errors.append(f"R03 v2 receipt metric unit differs: {metric_id}")
                continue
            if metric_id in FUNCTIONAL_METRIC_IDS:
                if result.get("status") != "measured" or result.get("reason") is not None:
                    errors.append(
                        f"R03 v2 receipt functional metric is not measured: {metric_id}"
                    )
                if not _metric_passes(metric_id, result.get("value")):
                    errors.append(f"R03 v2 receipt functional floor failed: {metric_id}")
            else:
                if (
                    result.get("status") != "not_applicable"
                    or result.get("value") is not None
                    or result.get("reason") != NOT_APPLICABLE_REASONS[metric_id]
                ):
                    errors.append(
                        f"R03 v2 receipt not-applicable disposition differs: {metric_id}"
                    )

    def _check_receipt_semantics(
        self,
        value: dict[str, Any],
        errors: list[str],
        *,
        verify_files: bool = True,
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 execution receipt"))
        self._check_exact_binding(
            value.get("preregistration_binding"),
            PREREGISTRATION_PATH,
            "R03 v2 receipt preregistration binding",
            errors,
        ) if verify_files else None
        self._check_exact_binding(
            value.get("fixture_catalog_binding"),
            FIXTURE_CATALOG_PATH,
            "R03 v2 receipt fixture binding",
            errors,
        ) if verify_files else None
        self._check_named_bindings(
            value.get("source_bindings"),
            SOURCE_BINDING_REQUIREMENTS,
            "R03 v2 receipt source bindings",
            errors,
            verify_files=verify_files,
        )
        self._check_named_bindings(
            value.get("test_bindings"),
            TEST_BINDING_REQUIREMENTS,
            "R03 v2 receipt test bindings",
            errors,
            verify_files=verify_files,
        )
        self._check_named_bindings(
            value.get("artifact_bindings"),
            ARTIFACT_BINDING_IDS,
            "R03 v2 receipt artifact bindings",
            errors,
            verify_files=verify_files,
            artifact_mode=True,
        )
        if verify_files:
            bound_values = []
            for key in ("source_bindings", "test_bindings", "artifact_bindings"):
                candidate = value.get(key)
                if isinstance(candidate, list):
                    bound_values.extend(item for item in candidate if isinstance(item, dict))
            self._check_source_provenance(value.get("source"), bound_values, errors)
        toolchain = value.get("toolchain")
        if not isinstance(toolchain, dict) or tuple(toolchain) != TOOLCHAIN_FIELDS:
            errors.append("R03 v2 receipt toolchain fields/order differ")
        observation = value.get("observation_status")
        if not isinstance(observation, dict):
            errors.append("R03 v2 receipt observation status is absent")
        else:
            expected_simulator = (
                "observed" if observation.get("platform") == "ios_simulator" else "not_observed"
            )
            expected_observation = {
                "platform": observation.get("platform"),
                "deterministic_software_execution": "observed",
                "genuine_mps_execution": "observed",
                "hardware_capability_observation": "not_observed",
                "simulator_execution": expected_simulator,
                "operator_observed_operation": "not_observed",
                "product_runtime_support": "not_claimed",
            }
            if observation != expected_observation or observation.get("platform") not in {
                "macos_host",
                "ios_simulator",
            }:
                errors.append("R03 v2 receipt observation status is contradictory")
        processing = value.get("processing_identity")
        if not isinstance(processing, dict):
            errors.append("R03 v2 receipt processing identity is absent")
        else:
            expected_processing = {
                **CANDIDATE_IDENTITY,
                "backend_revision": processing.get("backend_revision"),
                "model_assets_identity": "notRequired",
                "fallback_history": [],
            }
            if (
                not isinstance(processing.get("backend_revision"), str)
                or not processing.get("backend_revision")
                or processing != expected_processing
            ):
                errors.append("R03 v2 receipt processing identity differs")
        self._check_route_results(value.get("route_results"), errors)
        self._check_media_result(value.get("media_transaction_result"), errors)
        self._check_metric_results(value.get("metric_results"), errors)

    @staticmethod
    def _metric_evaluations(receipt: dict[str, Any]) -> list[dict[str, object]]:
        values = receipt.get("metric_results")
        results = values if isinstance(values, list) else []
        evaluations: list[dict[str, object]] = []
        for item in results:
            if not isinstance(item, dict):
                continue
            metric_id = item.get("id")
            status = item.get("status")
            evaluations.append(
                {
                    "id": metric_id,
                    "status": status,
                    "passed": (
                        _metric_passes(metric_id, item.get("value"))
                        if status == "measured" and isinstance(metric_id, str)
                        else None
                    ),
                    "reason": item.get("reason"),
                }
            )
        return evaluations

    @staticmethod
    def expected_decision(
        receipt: dict[str, Any],
        *,
        preregistration_binding: dict[str, object],
        fixture_catalog_binding: dict[str, object],
        receipt_binding: dict[str, object],
        validator_binding: dict[str, object],
    ) -> dict[str, object]:
        return {
            "schema_version": "2.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R03",
            "evidence_kind": "r03_a11_functional_product_qualification_decision_v2",
            "preregistration_binding": preregistration_binding,
            "fixture_catalog_binding": fixture_catalog_binding,
            "execution_receipt_binding": receipt_binding,
            "validator_binding": validator_binding,
            "candidate_identity": {
                "backend_id": "r03.mps.lanczos",
                "capability_id": "A11",
                "qualification_scope": "functional_product_eligibility",
                "policy_identity": CANDIDATE_IDENTITY["policy_identity"],
                "material_decision_identity": CANDIDATE_IDENTITY[
                    "material_decision_identity"
                ],
            },
            "derived_checks": [
                {"id": check_id, "status": "passed"} for check_id in CHECK_IDS
            ],
            "metric_evaluations": R03ProductQualificationVerifier._metric_evaluations(
                receipt
            ),
            "result": dict(DECISION_RESULT),
            "limitations": list(DECISION_LIMITATIONS),
        }

    def _file_binding(self, relative: Path) -> dict[str, object]:
        payload = (self.root / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }

    def _check_decision_semantics(
        self,
        value: dict[str, Any],
        receipt: dict[str, Any],
        errors: list[str],
        *,
        preregistration_binding: dict[str, object],
        fixture_catalog_binding: dict[str, object],
        receipt_binding: dict[str, object],
        validator_binding: dict[str, object],
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 qualification decision"))
        expected = self.expected_decision(
            receipt,
            preregistration_binding=preregistration_binding,
            fixture_catalog_binding=fixture_catalog_binding,
            receipt_binding=receipt_binding,
            validator_binding=validator_binding,
        )
        if value != expected:
            errors.append(
                "R03 v2 qualification decision is not exactly derived from the bound receipt"
            )

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R03 v2 preregistration",
            errors,
        )
        if value is not None:
            self._check_preregistration_semantics(value, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors = self.check_preregistration()
        value = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R03 v2 fixture catalog",
            errors,
        )
        if value is not None:
            self._check_fixture_semantics(value, errors)
        return errors

    def check_receipt(self) -> list[str]:
        errors = self.check_fixtures()
        value = self._read_and_validate(
            EXECUTION_RECEIPT_PATH,
            EXECUTION_RECEIPT_SCHEMA_PATH,
            "R03 v2 execution receipt",
            errors,
        )
        if value is not None:
            self._check_receipt_semantics(value, errors)
        return errors

    def check_decision(self) -> list[str]:
        errors = self.check_receipt()
        receipt = self._read_json(
            EXECUTION_RECEIPT_PATH, "R03 v2 execution receipt", errors
        )
        decision = self._read_and_validate(
            DECISION_PATH,
            DECISION_SCHEMA_PATH,
            "R03 v2 qualification decision",
            errors,
        )
        if receipt is not None and decision is not None:
            self._check_decision_semantics(
                decision,
                receipt,
                errors,
                preregistration_binding=self._file_binding(PREREGISTRATION_PATH),
                fixture_catalog_binding=self._file_binding(FIXTURE_CATALOG_PATH),
                receipt_binding=self._file_binding(EXECUTION_RECEIPT_PATH),
                validator_binding=self._file_binding(VALIDATOR_PATH),
            )
        return errors

    def check_preimplementation(self) -> list[str]:
        errors = self.check_fixtures()
        receipt = self.root / EXECUTION_RECEIPT_PATH
        decision = self.root / DECISION_PATH
        if decision.exists() and not receipt.exists():
            errors.append("R03 v2 decision exists without its required execution receipt")
        if receipt.exists():
            errors.extend(self.check_receipt())
        if decision.exists():
            errors.extend(self.check_decision())
        return errors


def emit_errors(errors: Iterable[str]) -> int:
    values = sorted(set(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--check-receipt", action="store_true")
    parser.add_argument("--check-decision", action="store_true")
    parser.add_argument("--check-preimplementation", action="store_true")
    arguments = parser.parse_args(argv)
    selected = (
        arguments.check_preregistration,
        arguments.check_fixtures,
        arguments.check_receipt,
        arguments.check_decision,
        arguments.check_preimplementation,
    )
    if not any(selected):
        parser.error("select at least one check")
    verifier = R03ProductQualificationVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    checks = (
        (arguments.check_preregistration, "R03 v2 preregistration", verifier.check_preregistration),
        (arguments.check_fixtures, "R03 v2 fixtures", verifier.check_fixtures),
        (arguments.check_receipt, "R03 v2 execution receipt", verifier.check_receipt),
        (arguments.check_decision, "R03 v2 qualification decision", verifier.check_decision),
        (
            arguments.check_preimplementation,
            "R03 v2 preimplementation contract",
            verifier.check_preimplementation,
        ),
    )
    passed_labels: list[str] = []
    for enabled, label, check in checks:
        if not enabled:
            continue
        observed_errors = check()
        errors.extend(observed_errors)
        if not observed_errors:
            passed_labels.append(label)
    if not errors:
        for label in passed_labels:
            print(f"{label}: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
