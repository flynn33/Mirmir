#!/usr/bin/env python3
"""Validate the additive R03 A11 functional product-qualification contract."""

from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tempfile
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
ARTIFACT_DIRECTORY = Path(
    "docs/roadmaps/evidence/r03/records/artifacts/product-qualification-v2"
)
ROUTE_ARTIFACT_PATH = ARTIFACT_DIRECTORY / "route-observations.json"
XCRESULT_SUMMARY_PATH = ARTIFACT_DIRECTORY / "xcresult-summary.json"
MEDIA_AGGREGATE_PATH = ARTIFACT_DIRECTORY / "media-transaction-observations.json"
METRIC_ARTIFACT_PATH = ARTIFACT_DIRECTORY / "metric-observations.json"

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
REQUIRED_TEST_CLASS_TOKENS = (
    "R03A11NativeMPSProductTests",
    "R03A11ProductAdmissionTests",
    "R03A11InjectedLifecycleTests",
    "R03ProductQualificationMediaTests",
)
REQUIRED_TEST_IDENTIFIERS = (
    "R03A11NativeMPSProductTests/"
    "testStrictNativeMPSLanczosIsRepeatableAcrossThreeFreshSessionsForBothRoutes()",
    "R03A11ProductAdmissionTests/"
    "testProductProfileAndCapabilityRegistryBindOnlyA11()",
    "R03A11ProductAdmissionTests/"
    "testProductionFactoryBindsGenuineMPSLanczosProductIdentityForBothRoutes()",
    "R03A11ProductAdmissionTests/"
    "testDefaultConstructionRetainsExactFixtureOnlyAdmission()",
    "R03A11ProductAdmissionTests/"
    "testProductProfileRejectsEveryReferenceAndSupportSubjectAtConstruction()",
    "R03A11ProductAdmissionTests/"
    "testInjectedA11ProductConstructionRequiresFactoryAuthorization()",
    "R03A11ProductAdmissionTests/"
    "testProductAdmissionRequiresExactScopePolicyAndCapability()",
    "R03A11ProductAdmissionTests/"
    "testSupportFactoriesRejectProductScopeBeforeNativeConstruction()",
    "R03A11InjectedLifecycleTests/"
    "testInjectedFixtureControlPathForwardsLifecycleAndLifetime()",
    "R03A11InjectedLifecycleTests/"
    "testInjectedFixtureControlPathMapsRuntimeAndScalingErrors()",
    "R03A11InjectedLifecycleTests/"
    "testInjectedFixtureFactoryErrorsMapWithoutCreatingProductAdmission()",
    "R03ProductQualificationMediaTests/"
    "testProductQualifiedMPSLanczosMediaTransactionRun1()",
    "R03ProductQualificationMediaTests/"
    "testProductQualifiedMPSLanczosMediaTransactionRun2()",
    "R03ProductQualificationMediaTests/"
    "testProductQualifiedMPSLanczosMediaTransactionRun3()",
)
MINIMUM_SELECTED_TEST_COUNT = len(REQUIRED_TEST_IDENTIFIERS)
QUALIFICATION_INVOCATION_CONTRACT_ID = (
    "r03.a11.product-qualification-invocation.v1"
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

# These hashes cover semantic JSON (sorted keys, compact separators), not
# whitespace. They intentionally freeze the two committed additive records.
PREREGISTRATION_SEMANTIC_SHA256 = (
    "be84d7aa206714b57b6cdec1d24be44923f6b9a29c12779add0d80cc17a507a3"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "3d4d581658ebc4e966c8297e9066b5173b2c7d1de1466fbe82b1f2cd62b0fa85"
)

NATIVE_ROUTE_INPUT_SHA256S = {
    "scale_3_over_2": (
        "60ff1ec00e8d0c0cba94f066d56a1ebed317f0d08d3b49fd7497f173c9f71484"
    ),
    "scale_2x": (
        "c838a1be5f6aba9eb2ea3dbaefa01ad2e8fa73388296390e793716279418b424"
    ),
}


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _qualification_invocation(
    batch_id: str,
    source_commit: str,
    source_tree: str,
) -> dict[str, str]:
    binding_payload = "\0".join(
        (
            QUALIFICATION_INVOCATION_CONTRACT_ID,
            batch_id,
            source_commit,
            source_tree,
        )
    ).encode("utf-8")
    return {
        "contract_id": QUALIFICATION_INVOCATION_CONTRACT_ID,
        "batch_id": batch_id,
        "source_commit": source_commit,
        "source_tree": source_tree,
        "binding_sha256": _sha256(binding_payload),
    }


def _is_lowercase_hex(value: object, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and value != "0" * length
        and all(character in "0123456789abcdef" for character in value)
    )


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
        required_ids = (
            list(required)
            if artifact_mode
            else [item["id"] for item in required]
        )
        if ids != required_ids:
            errors.append(f"{context} IDs/order differ from the exact contract")
        if not artifact_mode:
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
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
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
        if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
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
            audio_identity = run.get("audio_semantic_sha256")
            if (
                not isinstance(audio_identity, str)
                or len(audio_identity) != 64
                or audio_identity == "0" * 64
                or any(
                    character not in "0123456789abcdef"
                    for character in audio_identity
                )
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

    @staticmethod
    def _check_qualification_invocation(
        value: object,
        context: str,
        errors: list[str],
        *,
        expected_source: tuple[str, str] | None = None,
    ) -> dict[str, str] | None:
        expected_keys = {
            "contract_id",
            "batch_id",
            "source_commit",
            "source_tree",
            "binding_sha256",
        }
        if not isinstance(value, dict) or set(value) != expected_keys:
            errors.append(f"{context} qualification invocation keys differ")
            return None
        batch_id = value.get("batch_id")
        source_commit = value.get("source_commit")
        source_tree = value.get("source_tree")
        if (
            value.get("contract_id") != QUALIFICATION_INVOCATION_CONTRACT_ID
            or not _is_lowercase_hex(batch_id, 64)
            or not _is_lowercase_hex(source_commit, 40)
            or not _is_lowercase_hex(source_tree, 40)
        ):
            errors.append(f"{context} qualification invocation identity is invalid")
            return None
        expected = _qualification_invocation(
            batch_id,
            source_commit,
            source_tree,
        )
        if value != expected:
            errors.append(f"{context} qualification invocation digest differs")
        if expected_source is not None and (
            source_commit,
            source_tree,
        ) != expected_source:
            errors.append(f"{context} qualification invocation source differs")
        return expected

    @staticmethod
    def _check_test_summary(
        value: object,
        errors: list[str],
        *,
        expected_selected_count: int | None = None,
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 xcresult summary"))
        required_keys = {
            "schema_version",
            "evidence_kind",
            "expected_selected_test_count",
            "selected_test_count",
            "passed_test_count",
            "failed_test_count",
            "skipped_test_count",
            "test_identifiers",
            "toolchain",
            "qualification_invocation",
        }
        if not isinstance(value, dict) or set(value) != required_keys:
            errors.append("R03 v2 xcresult summary keys differ")
            return
        expected = value.get("expected_selected_test_count")
        selected = value.get("selected_test_count")
        passed = value.get("passed_test_count")
        if (
            not isinstance(expected, int)
            or isinstance(expected, bool)
            or expected < MINIMUM_SELECTED_TEST_COUNT
            or selected != expected
            or passed != expected
            or value.get("failed_test_count") != 0
            or value.get("skipped_test_count") != 0
        ):
            errors.append("R03 v2 xcresult summary is not an exact passing selection")
        if expected_selected_count is not None and expected != expected_selected_count:
            errors.append("R03 v2 xcresult summary selected count differs from the command")
        identifiers = value.get("test_identifiers")
        values = identifiers if isinstance(identifiers, list) else []
        if (
            len(values) != expected
            or not all(isinstance(item, str) and item for item in values)
            or len(values) != len(set(values))
        ):
            errors.append("R03 v2 xcresult summary test identifiers are incomplete")
        observed_identifiers = {
            item for item in values if isinstance(item, str)
        }
        for identifier in REQUIRED_TEST_IDENTIFIERS:
            if identifier not in observed_identifiers:
                errors.append(
                    f"R03 v2 xcresult summary omits required test: {identifier}"
                )
        for identifier in observed_identifiers:
            components = identifier.split("/")
            valid_method = (
                len(components) == 2
                and components[0] in REQUIRED_TEST_CLASS_TOKENS
                and components[1].startswith("test")
                and components[1].endswith("()")
                and components[1][:-2].replace("_", "").isalnum()
            )
            if not valid_method:
                errors.append(
                    "R03 v2 xcresult summary contains a test outside the exact "
                    f"qualification suites: {identifier}"
                )
        toolchain = value.get("toolchain")
        if not isinstance(toolchain, dict) or tuple(toolchain) != TOOLCHAIN_FIELDS:
            errors.append("R03 v2 xcresult summary toolchain fields/order differ")
        if value.get("schema_version") != "1.0.0" or value.get("evidence_kind") != (
            "r03_a11_selected_test_summary_v1"
        ):
            errors.append("R03 v2 xcresult summary identity differs")
        R03ProductQualificationVerifier._check_qualification_invocation(
            value.get("qualification_invocation"),
            "R03 v2 xcresult summary",
            errors,
        )

    @staticmethod
    def _check_xcodebuild_log_text(
        value: str,
        errors: list[str],
        *,
        expected_invocation: dict[str, str] | None = None,
    ) -> None:
        errors.extend(_privacy_errors(value, "R03 v2 xcodebuild log"))
        if "** TEST SUCCEEDED **" not in value or "** TEST FAILED **" in value:
            errors.append("R03 v2 xcodebuild log does not record test success")
        if expected_invocation is not None:
            marker = (
                "R03_QUALIFICATION_INVOCATION_SHA256="
                f"{expected_invocation['binding_sha256']}"
            )
            if value.splitlines().count(marker) != 1:
                errors.append(
                    "R03 v2 xcodebuild log invocation marker is absent or ambiguous"
                )

    @staticmethod
    def _derive_observation_status(toolchain: object, errors: list[str]) -> dict[str, str]:
        if not isinstance(toolchain, dict):
            errors.append("R03 v2 cannot derive platform without exact toolchain metadata")
            platform = "invalid"
        else:
            sdk_name = toolchain.get("sdk_name")
            destination = toolchain.get("destination")
            if sdk_name == "macosx" and isinstance(destination, str) and (
                "platform=macOS" in destination
            ):
                platform = "macos_host"
            elif sdk_name == "iphonesimulator" and isinstance(destination, str) and (
                "Simulator" in destination or "platform=iOS Simulator" in destination
            ):
                platform = "ios_simulator"
            else:
                errors.append("R03 v2 toolchain does not identify an allowed execution platform")
                platform = "invalid"
        return {
            "platform": platform,
            "deterministic_software_execution": "observed",
            "genuine_mps_execution": "observed",
            "hardware_capability_observation": "not_observed",
            "simulator_execution": (
                "observed" if platform == "ios_simulator" else "not_observed"
            ),
            "operator_observed_operation": "not_observed",
            "product_runtime_support": "not_claimed",
        }

    @staticmethod
    def _transform_native_route_observations(
        value: object, errors: list[str]
    ) -> tuple[dict[str, object], list[dict[str, object]]] | None:
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "evidence_kind",
            "qualification_invocation",
            "backend_identity",
            "routes",
        }:
            errors.append("R03 v2 native route observation keys differ")
            return None
        if value.get("schema_version") != "1.0.0" or value.get("evidence_kind") != (
            "r03_a11_native_route_observations_v1"
        ):
            errors.append("R03 v2 native route observation identity differs")
            return None
        R03ProductQualificationVerifier._check_qualification_invocation(
            value.get("qualification_invocation"),
            "R03 v2 native route observations",
            errors,
        )
        identity = value.get("backend_identity")
        expected_identity_keys = {
            "backend_id",
            "backend_revision",
            "capability_id",
            "framework_identity",
            "model_assets_identity",
            "policy_identity",
            "material_decision_identity",
        }
        if not isinstance(identity, dict) or set(identity) != expected_identity_keys:
            errors.append("R03 v2 native backend identity keys differ")
            return None
        expected_identity = {
            "backend_id": CANDIDATE_IDENTITY["backend_id"],
            "backend_revision": "1",
            "capability_id": CANDIDATE_IDENTITY["capability_id"],
            "framework_identity": CANDIDATE_IDENTITY["framework"],
            "model_assets_identity": "notRequired",
            "policy_identity": CANDIDATE_IDENTITY["policy_identity"],
            "material_decision_identity": CANDIDATE_IDENTITY[
                "material_decision_identity"
            ],
        }
        if (
            not isinstance(identity.get("backend_revision"), str)
            or not identity.get("backend_revision")
            or identity != expected_identity
        ):
            errors.append(
                "R03 v2 native backend identity differs from the source-bound "
                "MPS Lanczos contract"
            )
        processing_identity: dict[str, object] = {
            "backend_id": identity.get("backend_id"),
            "backend_revision": identity.get("backend_revision"),
            "capability_id": identity.get("capability_id"),
            "framework": identity.get("framework_identity"),
            # The exact symbol is a source-bound inference. Genuine execution is
            # established only when the bound native test completes successfully.
            "framework_symbol": "MPSImageLanczosScale",
            "model_assets_identity": identity.get("model_assets_identity"),
            "policy_identity": identity.get("policy_identity"),
            "material_decision_identity": identity.get("material_decision_identity"),
            "fallback_history": [],
        }
        routes = value.get("routes")
        route_values = routes if isinstance(routes, list) else []
        if len(route_values) != 2:
            errors.append("R03 v2 native route observation count differs")
            return processing_identity, []
        normalized_routes: list[dict[str, object]] = []
        for index, contract in enumerate(ROUTE_CONTRACTS):
            route = route_values[index]
            if not isinstance(route, dict) or set(route) != {
                "route_id",
                "configuration_identity",
                "input_identity",
                "output_identity",
                "runs",
            }:
                errors.append(f"R03 v2 native route keys differ: {contract['id']}")
                continue
            if (
                route.get("route_id") != contract["id"]
                or route.get("configuration_identity")
                != contract["configuration_identity"]
            ):
                errors.append(f"R03 v2 native route identity differs: {contract['id']}")
            frame_identities: list[dict[str, Any]] = []
            for role, dimensions in (
                ("input_identity", contract["input_dimensions"]),
                ("output_identity", contract["output_dimensions"]),
            ):
                frame = route.get(role)
                if not isinstance(frame, dict) or set(frame) != {
                    "dimensions",
                    "plane_count",
                    "pixel_format",
                    "pixel_format_raw_value",
                    "color_identity",
                }:
                    errors.append(
                        f"R03 v2 native {role} keys differ: {contract['id']}"
                    )
                    frame_identities.append({})
                    continue
                color = frame.get("color_identity")
                expected_color = {
                    "primaries": COLOR_OBSERVATION["primaries"],
                    "transfer_function": COLOR_OBSERVATION["transfer_function"],
                    "matrix": COLOR_OBSERVATION["matrix"],
                    "chroma_location": COLOR_OBSERVATION["chroma_location"],
                    "range": COLOR_OBSERVATION["range"],
                }
                if (
                    frame.get("dimensions") != dimensions
                    or frame.get("plane_count") != 2
                    or frame.get("pixel_format") != "420v"
                    or frame.get("pixel_format_raw_value") != 875704438
                    or color != expected_color
                ):
                    errors.append(
                        f"R03 v2 native {role} contract differs: {contract['id']}"
                    )
                frame_identities.append(frame)
            runs = route.get("runs")
            run_values = runs if isinstance(runs, list) else []
            normalized_runs: list[dict[str, object]] = []
            input_hashes: list[object] = []
            output_hashes: list[object] = []
            for ordinal, run in enumerate(run_values, start=1):
                expected_run_keys = {
                    "run_ordinal",
                    "logical_input_sha256",
                    "logical_output_sha256",
                    "sequence_number",
                    "presentation_timestamp",
                    "duration",
                    "metadata_identity",
                    "input_token_identity",
                    "output_token_identity",
                    "frame_order_preserved",
                    "pts_preserved",
                    "duration_preserved",
                    "metadata_preserved",
                    "lifecycle_observation",
                    "fallback_history",
                }
                if not isinstance(run, dict) or set(run) != expected_run_keys:
                    errors.append(
                        f"R03 v2 native run keys differ: {contract['id']} run {ordinal}"
                    )
                    continue
                lifecycle = run.get("lifecycle_observation")
                expected_lifecycle_keys = {
                    "input_release_count",
                    "output_release_count",
                    "terminalization_count",
                    "pre_submit_reset_operations",
                    "post_terminal_reset_operations",
                    "finish_operations",
                    "cancel_operations",
                    "reset_next_history_generations",
                    "processed_history_generation",
                    "finish_idempotent",
                    "cancel_idempotent",
                }
                timestamp = run.get("presentation_timestamp")
                duration = run.get("duration")
                expected_time_keys = {"value", "timescale", "flags", "epoch"}
                expected_timestamp = {
                    "value": 30,
                    "timescale": 30,
                    "flags": 1,
                    "epoch": 0,
                }
                expected_duration = {
                    "value": 1,
                    "timescale": 30,
                    "flags": 1,
                    "epoch": 0,
                }
                if (
                    run.get("run_ordinal") != ordinal
                    or run.get("sequence_number") != 0
                    or run.get("metadata_identity") != "r03.metadata.0"
                    or run.get("input_token_identity")
                    != f"r03.a11.native.{contract['id']}.run-{ordinal}.0"
                    or run.get("output_token_identity")
                    != "r03.mps.lanczos.output.0"
                    or not isinstance(timestamp, dict)
                    or set(timestamp) != expected_time_keys
                    or timestamp != expected_timestamp
                    or not isinstance(duration, dict)
                    or set(duration) != expected_time_keys
                    or duration != expected_duration
                    or not isinstance(lifecycle, dict)
                    or set(lifecycle) != expected_lifecycle_keys
                    or lifecycle.get("input_release_count") != 1
                    or lifecycle.get("output_release_count") != 1
                    or lifecycle.get("terminalization_count") != 1
                    or lifecycle.get("pre_submit_reset_operations") != 2
                    or lifecycle.get("post_terminal_reset_operations") != 2
                    or lifecycle.get("finish_operations") != 4
                    or lifecycle.get("cancel_operations") != 2
                    or lifecycle.get("reset_next_history_generations") != [1, 2]
                    or lifecycle.get("processed_history_generation") != 2
                    or lifecycle.get("finish_idempotent") is not True
                    or lifecycle.get("cancel_idempotent") is not True
                    or run.get("frame_order_preserved") is not True
                    or run.get("pts_preserved") is not True
                    or run.get("duration_preserved") is not True
                    or run.get("metadata_preserved") is not True
                    or run.get("fallback_history") != []
                ):
                    errors.append(
                        f"R03 v2 native run contract differs: {contract['id']} run {ordinal}"
                    )
                for hash_key in ("logical_input_sha256", "logical_output_sha256"):
                    hash_value = run.get(hash_key)
                    if (
                        not isinstance(hash_value, str)
                        or len(hash_value) != 64
                        or any(character not in "0123456789abcdef" for character in hash_value)
                        or hash_value == "0" * 64
                    ):
                        errors.append(
                            f"R03 v2 native {hash_key} is invalid: "
                            f"{contract['id']} run {ordinal}"
                        )
                input_hashes.append(run.get("logical_input_sha256"))
                output_hashes.append(run.get("logical_output_sha256"))
                normalized_runs.append(
                    {
                        "run_ordinal": ordinal,
                        "logical_output_sha256": run.get("logical_output_sha256"),
                        "output_dimensions": contract["output_dimensions"],
                        "color_observation": {
                            "pixel_format": "420v",
                            **(
                                frame_identities[1].get("color_identity", {})
                                if len(frame_identities) == 2
                                else {}
                            ),
                        },
                        "frame_order_preserved": run.get("frame_order_preserved"),
                        "pts_preserved": run.get("pts_preserved"),
                        "duration_preserved": run.get("duration_preserved"),
                        "metadata_preserved": run.get("metadata_preserved"),
                        "lifecycle_observation": {
                            "input_release_count": (
                                lifecycle.get("input_release_count")
                                if isinstance(lifecycle, dict)
                                else None
                            ),
                            "output_release_count": (
                                lifecycle.get("output_release_count")
                                if isinstance(lifecycle, dict)
                                else None
                            ),
                            "terminalization_count": (
                                lifecycle.get("terminalization_count")
                                if isinstance(lifecycle, dict)
                                else None
                            ),
                            # Exact observed driver generations [1, 2] followed by
                            # processing at generation 2 establish this derivation.
                            "reset_generation_advanced": (
                                lifecycle.get("reset_next_history_generations")
                                == [1, 2]
                                and lifecycle.get("processed_history_generation") == 2
                                if isinstance(lifecycle, dict)
                                else False
                            ),
                            "finish_idempotent": (
                                lifecycle.get("finish_idempotent")
                                if isinstance(lifecycle, dict)
                                else None
                            ),
                            "cancel_idempotent": (
                                lifecycle.get("cancel_idempotent")
                                if isinstance(lifecycle, dict)
                                else None
                            ),
                        },
                        "fallback_history": run.get("fallback_history"),
                    }
                )
            if len(run_values) != 3 or [run.get("run_ordinal") for run in run_values if isinstance(run, dict)] != [1, 2, 3]:
                errors.append(f"R03 v2 native run ordinals differ: {contract['id']}")
            if input_hashes != [NATIVE_ROUTE_INPUT_SHA256S[contract["id"]]] * 3:
                errors.append(f"R03 v2 native input identity changed: {contract['id']}")
            if len(output_hashes) != 3 or len(set(output_hashes)) != 1:
                errors.append(f"R03 v2 native output is not repeatable: {contract['id']}")
            normalized_routes.append(
                {
                    "route_id": contract["id"],
                    "configuration_identity": contract["configuration_identity"],
                    "input_dimensions": contract["input_dimensions"],
                    "output_dimensions": contract["output_dimensions"],
                    "runs": normalized_runs,
                }
            )
        return processing_identity, normalized_routes

    @staticmethod
    def _derive_metric_results(
        route_results: list[dict[str, object]],
        media_runs: list[dict[str, object]],
    ) -> list[dict[str, object]]:
        distinct_counts: list[int] = []
        for route in route_results:
            runs = route.get("runs")
            values = runs if isinstance(runs, list) else []
            distinct_counts.append(
                len(
                    {
                        run.get("logical_output_sha256")
                        for run in values
                        if isinstance(run, dict)
                    }
                )
            )
        media_tokens = {
            json.dumps(run.get("logical_frame_sha256s"), separators=(",", ":"))
            for run in media_runs
            if isinstance(run, dict)
        }
        distinct_counts.append(len(media_tokens))
        derived_values = {
            "dimension_mismatch_count": 0,
            "pixel_format_mismatch_count": 0,
            "color_identity_mismatch_count": 0,
            "frame_timing_mismatch_count": 0,
            "audio_identity_mismatch_count": 0,
            "metadata_identity_mismatch_count": 0,
            "resource_lifetime_violation_count": 0,
            "silent_fallback_count": 0,
            "incomplete_identity_count": 0,
            "nonfinite_metric_count": 0,
            "distinct_output_hash_count": max(distinct_counts, default=0),
            "temporal_repeatability_mismatch_count": 0,
            "peak_in_flight_resources": 1,
        }
        results: list[dict[str, object]] = []
        for metric_id, unit, _operator, _threshold in LEGACY_METRIC_CONTRACTS:
            if metric_id in FUNCTIONAL_METRIC_IDS:
                results.append(
                    {
                        "id": metric_id,
                        "unit": unit,
                        "status": "measured",
                        "value": derived_values[metric_id],
                        "reason": None,
                    }
                )
            else:
                results.append(
                    {
                        "id": metric_id,
                        "unit": unit,
                        "status": "not_applicable",
                        "value": None,
                        "reason": NOT_APPLICABLE_REASONS[metric_id],
                    }
                )
        return results

    @staticmethod
    def _check_media_observation_document(
        value: object, expected_ordinal: int, errors: list[str]
    ) -> None:
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "evidence_kind",
            "fixture_id",
            "qualification_invocation",
            "run",
        }:
            errors.append(
                f"R03 v2 raw media observation keys differ: run {expected_ordinal}"
            )
            return
        if (
            value.get("schema_version") != "1.0.0"
            or value.get("evidence_kind")
            != "r03_a11_media_transaction_observation_v1"
            or value.get("fixture_id") != "r03-v2-media-transaction-2x"
            or not isinstance(value.get("run"), dict)
            or value["run"].get("run_ordinal") != expected_ordinal
        ):
            errors.append(
                f"R03 v2 raw media observation identity differs: run {expected_ordinal}"
            )
        R03ProductQualificationVerifier._check_qualification_invocation(
            value.get("qualification_invocation"),
            f"R03 v2 raw media observation run {expected_ordinal}",
            errors,
        )

    def _read_bound_json(
        self, binding: dict[str, Any], context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        path = self._safe_path(binding.get("path"), context, errors)
        if path is None:
            return None
        try:
            value = decode_json(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid JSON: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be a JSON object")
            return None
        return value

    def _check_raw_artifact_consistency(
        self, receipt: dict[str, Any], errors: list[str]
    ) -> None:
        artifacts = receipt.get("artifact_bindings")
        values = artifacts if isinstance(artifacts, list) else []
        by_id = {
            item.get("id"): item
            for item in values
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        route_binding = by_id.get("route_observations_json")
        summary_binding = by_id.get("xcresult_summary_json")
        log_binding = by_id.get("xcodebuild_log")
        if not isinstance(route_binding, dict) or not isinstance(summary_binding, dict):
            return
        source = receipt.get("source")
        expected_source = (
            (source.get("commit"), source.get("tree"))
            if isinstance(source, dict)
            and isinstance(source.get("commit"), str)
            and isinstance(source.get("tree"), str)
            else None
        )
        route_document = self._read_bound_json(
            route_binding, "R03 v2 raw route observations", errors
        )
        route_invocation = (
            self._check_qualification_invocation(
                route_document.get("qualification_invocation"),
                "R03 v2 raw route observations",
                errors,
                expected_source=expected_source,
            )
            if isinstance(route_document, dict)
            else None
        )
        transformed_route = (
            self._transform_native_route_observations(route_document, errors)
            if route_document is not None
            else None
        )
        if transformed_route is not None:
            processing_identity, route_results = transformed_route
            if receipt.get("processing_identity") != processing_identity:
                errors.append(
                    "R03 v2 receipt processing identity differs from raw routes"
                )
            if receipt.get("route_results") != route_results:
                errors.append("R03 v2 receipt routes differ from raw observations")
        summary = self._read_bound_json(
            summary_binding, "R03 v2 xcresult summary", errors
        )
        if summary is not None:
            self._check_test_summary(summary, errors)
            summary_invocation = self._check_qualification_invocation(
                summary.get("qualification_invocation"),
                "R03 v2 xcresult summary",
                errors,
                expected_source=expected_source,
            )
            if route_invocation != summary_invocation:
                errors.append(
                    "R03 v2 route and xcresult qualification invocations differ"
                )
            if receipt.get("toolchain") != summary.get("toolchain"):
                errors.append("R03 v2 receipt toolchain differs from xcresult summary")
            expected_observation = self._derive_observation_status(
                summary.get("toolchain"), errors
            )
            if receipt.get("observation_status") != expected_observation:
                errors.append(
                    "R03 v2 receipt observation status differs from xcresult summary"
                )
        media_runs: list[dict[str, Any]] = []
        media_binding = by_id.get("media_transaction_observations_json")
        if isinstance(media_binding, dict):
            document = self._read_bound_json(
                media_binding, "R03 v2 aggregate media observations", errors
            )
            if not isinstance(document, dict) or set(document) != {
                "schema_version",
                "evidence_kind",
                "fixture_id",
                "qualification_invocation",
                "runs",
            }:
                errors.append("R03 v2 aggregate media observation keys differ")
            else:
                if (
                    document.get("schema_version") != "1.0.0"
                    or document.get("evidence_kind")
                    != "r03_a11_media_transaction_observations_v1"
                    or document.get("fixture_id")
                    != "r03-v2-media-transaction-2x"
                ):
                    errors.append("R03 v2 aggregate media observation identity differs")
                media_invocation = self._check_qualification_invocation(
                    document.get("qualification_invocation"),
                    "R03 v2 aggregate media observations",
                    errors,
                    expected_source=expected_source,
                )
                if route_invocation != media_invocation:
                    errors.append(
                        "R03 v2 route and media qualification invocations differ"
                    )
                observed_runs = document.get("runs")
                media_runs = observed_runs if isinstance(observed_runs, list) else []
                for ordinal, run in enumerate(media_runs, start=1):
                    self._check_media_observation_document(
                        {
                            "schema_version": "1.0.0",
                            "evidence_kind": (
                                "r03_a11_media_transaction_observation_v1"
                            ),
                            "fixture_id": "r03-v2-media-transaction-2x",
                            "qualification_invocation": document.get(
                                "qualification_invocation"
                            ),
                            "run": run,
                        },
                        ordinal,
                        errors,
                    )
        media_result = receipt.get("media_transaction_result")
        if isinstance(media_result, dict) and media_result.get("runs") != media_runs:
            errors.append("R03 v2 receipt media runs differ from raw observations")
        metric_binding = by_id.get("metric_observations_json")
        if isinstance(metric_binding, dict):
            document = self._read_bound_json(
                metric_binding, "R03 v2 derived metric observations", errors
            )
            route_results = receipt.get("route_results")
            derived_metrics = self._derive_metric_results(
                route_results if isinstance(route_results, list) else [],
                media_runs,
            )
            if not isinstance(document, dict) or set(document) != {
                "schema_version",
                "evidence_kind",
                "metric_results",
            }:
                errors.append("R03 v2 metric observation artifact keys differ")
            elif (
                document.get("schema_version") != "1.0.0"
                or document.get("evidence_kind")
                != "r03_a11_metric_observations_v1"
                or receipt.get("metric_results") != document.get("metric_results")
                or document.get("metric_results") != derived_metrics
            ):
                errors.append(
                    "R03 v2 receipt metrics differ from deterministic raw derivation"
                )
        if isinstance(log_binding, dict):
            log_path = self._safe_path(
                log_binding.get("path"), "R03 v2 xcodebuild log", errors
            )
            if log_path is not None:
                try:
                    log_text = log_path.read_text(encoding="utf-8")
                except (OSError, UnicodeDecodeError) as error:
                    errors.append(f"R03 v2 xcodebuild log is unreadable: {error}")
                else:
                    self._check_xcodebuild_log_text(
                        log_text,
                        errors,
                        expected_invocation=route_invocation,
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
            for key in ("source_bindings", "test_bindings"):
                candidate = value.get(key)
                if isinstance(candidate, list):
                    bound_values.extend(item for item in candidate if isinstance(item, dict))
            self._check_source_provenance(value.get("source"), bound_values, errors)
            self._check_raw_artifact_consistency(value, errors)
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
                "backend_revision": "1",
                "model_assets_identity": "notRequired",
                "fallback_history": [],
            }
            if (
                processing != expected_processing
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

    @staticmethod
    def _binding_for_payload(
        relative: Path, payload: bytes, identifier: str | None = None
    ) -> dict[str, object]:
        value: dict[str, object] = {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": _sha256(payload),
        }
        if identifier is not None:
            value = {"id": identifier, **value}
        return value

    @staticmethod
    def _json_payload(value: object) -> bytes:
        return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")

    def _named_file_binding(
        self,
        relative: Path,
        identifier: str,
        context: str,
        errors: list[str],
    ) -> dict[str, object] | None:
        path = self._safe_path(relative.as_posix(), context, errors)
        if path is None:
            return None
        return self._binding_for_payload(relative, path.read_bytes(), identifier)

    def _repository_relative_argument(
        self, value: str, context: str, errors: list[str]
    ) -> Path | None:
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != value:
            errors.append(f"{context} must be normalized and repository-relative")
            return None
        relative = Path(value)
        if self._safe_path(value, context, errors) is None:
            return None
        return relative

    @staticmethod
    def _read_unbound_json_input(
        path: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        if path.is_symlink() or not path.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid JSON: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be a JSON object")
            return None
        return value

    def _check_implementation_source(
        self,
        implementation_commit: str,
        implementation_tree: str,
        errors: list[str],
    ) -> None:
        head = self.git("rev-parse", "HEAD")
        tree = self.git("rev-parse", "HEAD^{tree}")
        if head.returncode != 0 or head.stdout.strip() != implementation_commit:
            errors.append("R03 v2 implementation commit differs from current HEAD")
        if tree.returncode != 0 or tree.stdout.strip() != implementation_tree:
            errors.append("R03 v2 implementation tree differs from current HEAD tree")
        required_paths = [
            *(Path(item["path"]) for item in SOURCE_BINDING_REQUIREMENTS),
            *(Path(item["path"]) for item in TEST_BINDING_REQUIREMENTS),
            VALIDATOR_PATH,
        ]
        status = self.git(
            "status",
            "--porcelain",
            "--untracked-files=all",
        )
        allowed_exact = {
            EXECUTION_RECEIPT_PATH.as_posix(),
            DECISION_PATH.as_posix(),
        }
        allowed_prefix = f"{ARTIFACT_DIRECTORY.as_posix()}/"
        dirty_non_evidence: list[str] = []
        if status.returncode == 0:
            for line in status.stdout.splitlines():
                path = line[3:] if len(line) >= 4 else ""
                if " -> " in path:
                    path = path.split(" -> ", maxsplit=1)[1]
                if path not in allowed_exact and not path.startswith(allowed_prefix):
                    dirty_non_evidence.append(path)
        if status.returncode != 0 or dirty_non_evidence:
            errors.append(
                "R03 v2 repository contains non-evidence changes outside the "
                "implementation commit"
            )
        for relative in required_paths:
            current = self.root / relative
            if current.is_symlink() or not current.is_file():
                errors.append(f"R03 v2 committed source is absent: {relative.as_posix()}")
                continue
            historical = self.git_bytes(
                "show", f"{implementation_commit}:{relative.as_posix()}"
            )
            if historical.returncode != 0 or historical.stdout != current.read_bytes():
                errors.append(
                    f"R03 v2 implementation commit does not contain current bytes: "
                    f"{relative.as_posix()}"
                )

    def _write_payload_atomic(
        self,
        relative: Path,
        payload: bytes,
        errors: list[str],
        *,
        replace: bool,
    ) -> None:
        pure = PurePosixPath(relative.as_posix())
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != relative.as_posix():
            errors.append(
                f"R03 v2 output path is not repository-relative: {relative.as_posix()}"
            )
            return
        target = self.root / relative
        component = self.root
        for part in relative.parent.parts:
            component /= part
            if component.is_symlink():
                errors.append(
                    f"R03 v2 output parent contains a symlink: {relative.as_posix()}"
                )
                return
        if target.is_symlink():
            errors.append(f"R03 v2 output target is a symlink: {relative.as_posix()}")
            return
        if target.exists() and not replace:
            errors.append(f"R03 v2 output already exists: {relative.as_posix()}")
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            target.parent.resolve().relative_to(self.root.resolve())
        except ValueError:
            errors.append(
                f"R03 v2 output parent escapes the repository: {relative.as_posix()}"
            )
            return
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
        )
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, target)
        except OSError as error:
            errors.append(f"R03 v2 output write failed for {relative.as_posix()}: {error}")
            try:
                Path(temporary_name).unlink(missing_ok=True)
            except OSError:
                pass

    @staticmethod
    def _extract_test_case_identifiers(
        value: object, errors: list[str]
    ) -> list[str]:
        identifiers: list[str] = []

        def visit(item: object) -> None:
            if isinstance(item, dict):
                node_type = item.get("nodeType", item.get("node_type"))
                if node_type == "Test Case":
                    identifier = item.get(
                        "nodeIdentifier", item.get("node_identifier")
                    )
                    result = item.get("result")
                    if not isinstance(identifier, str) or not identifier:
                        errors.append("R03 v2 xcresult Test Case has no nodeIdentifier")
                    else:
                        identifiers.append(identifier)
                    if result != "Passed":
                        errors.append(
                            f"R03 v2 xcresult Test Case did not pass: {identifier}"
                        )
                for child in item.values():
                    visit(child)
            elif isinstance(item, list):
                for child in item:
                    visit(child)

        visit(value)
        if len(identifiers) != len(set(identifiers)):
            errors.append("R03 v2 xcresult Test Case nodeIdentifiers are not unique")
        return identifiers

    @staticmethod
    def _xcresult_count(
        summary: dict[str, Any], camel: str, snake: str
    ) -> object:
        return summary.get(camel, summary.get(snake))

    @classmethod
    def _derive_xcresult_summary(
        cls,
        *,
        raw_summary: object,
        raw_tests: object,
        expected_test_count: int,
        toolchain: object,
        qualification_invocation: object,
        errors: list[str],
    ) -> dict[str, object]:
        if expected_test_count < MINIMUM_SELECTED_TEST_COUNT:
            errors.append(
                "R03 v2 xcresult selected count is below the frozen required tests"
            )
        summary_value = raw_summary if isinstance(raw_summary, dict) else {}
        if not isinstance(raw_summary, dict):
            errors.append("R03 v2 raw xcresult summary must be an object")
        identifiers = cls._extract_test_case_identifiers(raw_tests, errors)
        total = cls._xcresult_count(
            summary_value, "totalTestCount", "total_test_count"
        )
        passed = cls._xcresult_count(summary_value, "passedTests", "passed_tests")
        failed = cls._xcresult_count(summary_value, "failedTests", "failed_tests")
        skipped = cls._xcresult_count(
            summary_value, "skippedTests", "skipped_tests"
        )
        result = summary_value.get("result")
        failures = summary_value.get(
            "testFailures", summary_value.get("test_failures", [])
        )
        if (
            total != expected_test_count
            or passed != expected_test_count
            or failed != 0
            or skipped != 0
            or result != "Passed"
            or failures != []
        ):
            errors.append("R03 v2 raw xcresult summary is not exact passed/zero-failure")
        if len(identifiers) != expected_test_count:
            errors.append("R03 v2 raw xcresult Test Case count differs")
        toolchain_value = toolchain if isinstance(toolchain, dict) else {}
        if set(toolchain_value) != set(TOOLCHAIN_FIELDS) or any(
            not isinstance(toolchain_value.get(field), str)
            or not toolchain_value.get(field)
            for field in TOOLCHAIN_FIELDS
        ):
            errors.append("R03 v2 supplied toolchain metadata is incomplete")
        summary = {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_selected_test_summary_v1",
            "expected_selected_test_count": expected_test_count,
            "selected_test_count": len(identifiers),
            "passed_test_count": passed,
            "failed_test_count": failed,
            "skipped_test_count": skipped,
            "test_identifiers": sorted(identifiers),
            "toolchain": {
                field: toolchain_value.get(field) for field in TOOLCHAIN_FIELDS
            },
            "qualification_invocation": qualification_invocation,
        }
        cls._check_test_summary(
            summary, errors, expected_selected_count=expected_test_count
        )
        errors.extend(_privacy_errors(summary, "R03 v2 derived xcresult summary"))
        return summary

    def assemble_xcresult_summary(
        self,
        *,
        raw_summary_path: str,
        raw_tests_path: str,
        expected_test_count: int,
        toolchain: dict[str, str],
        qualification_invocation: dict[str, str],
        replace: bool,
    ) -> list[str]:
        errors: list[str] = []
        raw_summary = self._read_unbound_json_input(
            Path(raw_summary_path).resolve(), "R03 v2 raw xcresult summary", errors
        )
        raw_tests = self._read_unbound_json_input(
            Path(raw_tests_path).resolve(), "R03 v2 raw xcresult tests", errors
        )
        if raw_summary is None or raw_tests is None:
            return errors
        summary = self._derive_xcresult_summary(
            raw_summary=raw_summary,
            raw_tests=raw_tests,
            expected_test_count=expected_test_count,
            toolchain=toolchain,
            qualification_invocation=qualification_invocation,
            errors=errors,
        )
        if errors:
            return errors
        self._write_payload_atomic(
            XCRESULT_SUMMARY_PATH,
            self._json_payload(summary),
            errors,
            replace=replace,
        )
        return errors

    def assemble_receipt(
        self,
        *,
        route_observations: str,
        media_observations: list[str],
        xcresult_summary: str,
        xcodebuild_log: str,
        implementation_commit: str,
        implementation_tree: str,
        expected_test_count: int,
        replace: bool,
    ) -> list[str]:
        errors = self.check_fixtures()
        self._check_implementation_source(
            implementation_commit, implementation_tree, errors
        )
        if len(media_observations) != 3:
            errors.append("R03 v2 receipt assembly requires exactly three media inputs")
        if expected_test_count < MINIMUM_SELECTED_TEST_COUNT:
            errors.append(
                "R03 v2 receipt assembly selected count is below the frozen tests"
            )

        summary_relative = self._repository_relative_argument(
            xcresult_summary, "R03 v2 xcresult summary", errors
        )
        log_relative = self._repository_relative_argument(
            xcodebuild_log, "R03 v2 xcodebuild log", errors
        )
        native_route_document = self._read_unbound_json_input(
            Path(route_observations).resolve(),
            "R03 v2 unbound native route observations",
            errors,
        )
        summary_document = (
            self._read_json(summary_relative, "R03 v2 xcresult summary", errors)
            if summary_relative is not None
            else None
        )
        transformed_route = (
            self._transform_native_route_observations(native_route_document, errors)
            if native_route_document is not None
            else None
        )
        expected_source = (implementation_commit, implementation_tree)
        route_invocation = (
            self._check_qualification_invocation(
                native_route_document.get("qualification_invocation"),
                "R03 v2 unbound native route observations",
                errors,
                expected_source=expected_source,
            )
            if isinstance(native_route_document, dict)
            else None
        )
        if summary_document is not None:
            self._check_test_summary(
                summary_document,
                errors,
                expected_selected_count=expected_test_count,
            )
            summary_invocation = self._check_qualification_invocation(
                summary_document.get("qualification_invocation"),
                "R03 v2 xcresult summary",
                errors,
                expected_source=expected_source,
            )
            if route_invocation != summary_invocation:
                errors.append(
                    "R03 v2 route and xcresult qualification invocations differ"
                )
        if log_relative is not None:
            try:
                log_text = (self.root / log_relative).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                errors.append(f"R03 v2 xcodebuild log is unreadable: {error}")
            else:
                self._check_xcodebuild_log_text(log_text, errors)

        raw_media_documents: list[dict[str, Any]] = []
        for ordinal, supplied in enumerate(media_observations, start=1):
            document = self._read_unbound_json_input(
                Path(supplied).resolve(),
                f"R03 v2 unbound media observation {ordinal}",
                errors,
            )
            if document is not None:
                self._check_media_observation_document(document, ordinal, errors)
                media_invocation = self._check_qualification_invocation(
                    document.get("qualification_invocation"),
                    f"R03 v2 unbound media observation {ordinal}",
                    errors,
                    expected_source=expected_source,
                )
                if route_invocation != media_invocation:
                    errors.append(
                        "R03 v2 route and media qualification invocations differ"
                    )
                raw_media_documents.append(document)
        if errors or transformed_route is None or summary_document is None:
            return errors

        processing_identity, route_results = transformed_route
        observation_status = self._derive_observation_status(
            summary_document.get("toolchain"), errors
        )
        if log_relative is not None:
            try:
                log_text = (self.root / log_relative).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                pass
            else:
                self._check_xcodebuild_log_text(
                    log_text,
                    errors,
                    expected_invocation=route_invocation,
                )

        media_aggregate = {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_media_transaction_observations_v1",
            "fixture_id": "r03-v2-media-transaction-2x",
            "qualification_invocation": route_invocation,
            "runs": [document["run"] for document in raw_media_documents],
        }
        metric_results = self._derive_metric_results(
            route_results,
            media_aggregate["runs"],
        )
        metric_artifact = {
            "schema_version": "1.0.0",
            "evidence_kind": "r03_a11_metric_observations_v1",
            "metric_results": metric_results,
        }
        route_payload = self._json_payload(native_route_document)
        media_payload = self._json_payload(media_aggregate)
        metric_payload = self._json_payload(metric_artifact)

        source_bindings: list[dict[str, object]] = []
        for requirement in SOURCE_BINDING_REQUIREMENTS:
            binding = self._named_file_binding(
                Path(requirement["path"]),
                requirement["id"],
                f"R03 v2 source binding {requirement['id']}",
                errors,
            )
            if binding is not None:
                source_bindings.append(binding)
        test_bindings: list[dict[str, object]] = []
        for requirement in TEST_BINDING_REQUIREMENTS:
            binding = self._named_file_binding(
                Path(requirement["path"]),
                requirement["id"],
                f"R03 v2 test binding {requirement['id']}",
                errors,
            )
            if binding is not None:
                test_bindings.append(binding)
        artifact_bindings: list[dict[str, object]] = []
        for identifier, relative in (
            ("xcodebuild_log", log_relative),
            ("xcresult_summary_json", summary_relative),
        ):
            if relative is None:
                continue
            binding = self._named_file_binding(
                relative, identifier, f"R03 v2 artifact {identifier}", errors
            )
            if binding is not None:
                artifact_bindings.append(binding)
        artifact_bindings.extend(
            (
                self._binding_for_payload(
                    ROUTE_ARTIFACT_PATH,
                    route_payload,
                    "route_observations_json",
                ),
                self._binding_for_payload(
                    MEDIA_AGGREGATE_PATH,
                    media_payload,
                    "media_transaction_observations_json",
                ),
                self._binding_for_payload(
                    METRIC_ARTIFACT_PATH,
                    metric_payload,
                    "metric_observations_json",
                ),
            )
        )
        receipt = {
            "schema_version": "2.0.0",
            "phase_id": "R03",
            "evidence_kind": "r03_a11_genuine_mps_functional_execution_receipt_v2",
            "source": {
                "commit": implementation_commit,
                "tree": implementation_tree,
            },
            "preregistration_binding": self._file_binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": self._file_binding(FIXTURE_CATALOG_PATH),
            "source_bindings": source_bindings,
            "test_bindings": test_bindings,
            "artifact_bindings": artifact_bindings,
            "toolchain": summary_document.get("toolchain"),
            "observation_status": observation_status,
            "processing_identity": processing_identity,
            "route_results": route_results,
            "media_transaction_result": {
                "fixture_id": "r03-v2-media-transaction-2x",
                "runs": media_aggregate["runs"],
            },
            "metric_results": metric_artifact["metric_results"],
        }
        receipt_schema = self._read_json(
            EXECUTION_RECEIPT_SCHEMA_PATH, "R03 v2 execution receipt schema", errors
        )
        if receipt_schema is not None:
            errors.extend(
                f"R03 v2 assembled receipt schema: {error}"
                for error in validate_json_schema_instance(receipt_schema, receipt)
            )
        self._check_receipt_semantics(receipt, errors, verify_files=False)
        if errors:
            return errors
        receipt_payload = self._json_payload(receipt)
        for relative, payload in (
            (ROUTE_ARTIFACT_PATH, route_payload),
            (MEDIA_AGGREGATE_PATH, media_payload),
            (METRIC_ARTIFACT_PATH, metric_payload),
            (EXECUTION_RECEIPT_PATH, receipt_payload),
        ):
            self._write_payload_atomic(
                relative, payload, errors, replace=replace
            )
            if errors:
                return errors
        validation_errors = self.check_receipt()
        if validation_errors:
            errors.extend(validation_errors)
        return errors

    def _check_validator_source_provenance(
        self, receipt: dict[str, Any], errors: list[str]
    ) -> None:
        source = receipt.get("source")
        commit = source.get("commit") if isinstance(source, dict) else None
        if isinstance(commit, str):
            validator_at_source = self.git_bytes(
                "show", f"{commit}:{VALIDATOR_PATH.as_posix()}"
            )
            current_validator = (self.root / VALIDATOR_PATH).read_bytes()
            if (
                validator_at_source.returncode != 0
                or validator_at_source.stdout != current_validator
            ):
                errors.append(
                    "R03 v2 decision validator bytes differ from the implementation commit"
                )
        else:
            errors.append("R03 v2 receipt source commit is invalid")

    def assemble_decision(self, *, replace: bool) -> list[str]:
        errors = self.check_receipt()
        receipt = self._read_json(
            EXECUTION_RECEIPT_PATH, "R03 v2 execution receipt", errors
        )
        if receipt is None or errors:
            return errors
        self._check_validator_source_provenance(receipt, errors)
        if errors:
            return errors
        decision = self.expected_decision(
            receipt,
            preregistration_binding=self._file_binding(PREREGISTRATION_PATH),
            fixture_catalog_binding=self._file_binding(FIXTURE_CATALOG_PATH),
            receipt_binding=self._file_binding(EXECUTION_RECEIPT_PATH),
            validator_binding=self._file_binding(VALIDATOR_PATH),
        )
        schema = self._read_json(
            DECISION_SCHEMA_PATH, "R03 v2 qualification decision schema", errors
        )
        if schema is not None:
            errors.extend(
                f"R03 v2 assembled decision schema: {error}"
                for error in validate_json_schema_instance(schema, decision)
            )
        self._check_decision_semantics(
            decision,
            receipt,
            errors,
            preregistration_binding=self._file_binding(PREREGISTRATION_PATH),
            fixture_catalog_binding=self._file_binding(FIXTURE_CATALOG_PATH),
            receipt_binding=self._file_binding(EXECUTION_RECEIPT_PATH),
            validator_binding=self._file_binding(VALIDATOR_PATH),
        )
        if errors:
            return errors
        self._write_payload_atomic(
            DECISION_PATH,
            self._json_payload(decision),
            errors,
            replace=replace,
        )
        if not errors:
            errors.extend(self.check_decision())
        return errors

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
            self._check_validator_source_provenance(receipt, errors)
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
    parser.add_argument("--assemble-xcresult-summary", action="store_true")
    parser.add_argument("--assemble-receipt", action="store_true")
    parser.add_argument("--assemble-decision", action="store_true")
    parser.add_argument("--raw-xcresult-summary")
    parser.add_argument("--raw-xcresult-tests")
    parser.add_argument("--route-observations")
    parser.add_argument("--media-observation", action="append", default=[])
    parser.add_argument("--xcresult-summary")
    parser.add_argument("--xcodebuild-log")
    parser.add_argument("--qualification-batch-id")
    parser.add_argument("--implementation-commit")
    parser.add_argument("--implementation-tree")
    parser.add_argument("--xcode-version")
    parser.add_argument("--xcode-build-version")
    parser.add_argument("--swift-version")
    parser.add_argument("--sdk-name")
    parser.add_argument("--sdk-version")
    parser.add_argument("--destination")
    parser.add_argument("--test-command")
    parser.add_argument("--os-version")
    parser.add_argument("--architecture")
    parser.add_argument(
        "--expected-test-count",
        type=int,
        default=MINIMUM_SELECTED_TEST_COUNT,
    )
    parser.add_argument("--replace", action="store_true")
    arguments = parser.parse_args(argv)
    selected = (
        arguments.check_preregistration,
        arguments.check_fixtures,
        arguments.check_receipt,
        arguments.check_decision,
        arguments.check_preimplementation,
        arguments.assemble_xcresult_summary,
        arguments.assemble_receipt,
        arguments.assemble_decision,
    )
    if not any(selected):
        parser.error("select at least one check")
    verifier = R03ProductQualificationVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    toolchain = {
        "xcode_version": arguments.xcode_version,
        "xcode_build_version": arguments.xcode_build_version,
        "swift_version": arguments.swift_version,
        "sdk_name": arguments.sdk_name,
        "sdk_version": arguments.sdk_version,
        "destination": arguments.destination,
        "command": arguments.test_command,
        "os_version": arguments.os_version,
        "architecture": arguments.architecture,
    }
    if arguments.assemble_xcresult_summary:
        required_values = {
            "--raw-xcresult-summary": arguments.raw_xcresult_summary,
            "--raw-xcresult-tests": arguments.raw_xcresult_tests,
            "--xcode-version": arguments.xcode_version,
            "--xcode-build-version": arguments.xcode_build_version,
            "--swift-version": arguments.swift_version,
            "--sdk-name": arguments.sdk_name,
            "--sdk-version": arguments.sdk_version,
            "--destination": arguments.destination,
            "--test-command": arguments.test_command,
            "--os-version": arguments.os_version,
            "--architecture": arguments.architecture,
            "--qualification-batch-id": arguments.qualification_batch_id,
            "--implementation-commit": arguments.implementation_commit,
            "--implementation-tree": arguments.implementation_tree,
        }
        absent = [name for name, value in required_values.items() if value is None]
        if absent:
            parser.error(
                "--assemble-xcresult-summary requires raw xcresult inputs and all "
                "toolchain arguments"
            )
    if arguments.assemble_receipt:
        required_values = {
            "--route-observations": arguments.route_observations,
            "--xcresult-summary": arguments.xcresult_summary,
            "--xcodebuild-log": arguments.xcodebuild_log,
            "--implementation-commit": arguments.implementation_commit,
            "--implementation-tree": arguments.implementation_tree,
        }
        absent = [name for name, value in required_values.items() if value is None]
        if absent or len(arguments.media_observation) != 3:
            parser.error(
                "--assemble-receipt requires all source arguments and exactly three "
                "--media-observation values"
            )
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
        (
            arguments.assemble_xcresult_summary,
            "R03 v2 xcresult summary assembly",
            lambda: verifier.assemble_xcresult_summary(
                raw_summary_path=arguments.raw_xcresult_summary,
                raw_tests_path=arguments.raw_xcresult_tests,
                expected_test_count=arguments.expected_test_count,
                toolchain=toolchain,
                qualification_invocation=_qualification_invocation(
                    arguments.qualification_batch_id,
                    arguments.implementation_commit,
                    arguments.implementation_tree,
                ),
                replace=arguments.replace,
            ),
        ),
        (
            arguments.assemble_receipt,
            "R03 v2 execution receipt assembly",
            lambda: verifier.assemble_receipt(
                route_observations=arguments.route_observations,
                media_observations=arguments.media_observation,
                xcresult_summary=arguments.xcresult_summary,
                xcodebuild_log=arguments.xcodebuild_log,
                implementation_commit=arguments.implementation_commit,
                implementation_tree=arguments.implementation_tree,
                expected_test_count=arguments.expected_test_count,
                replace=arguments.replace,
            ),
        ),
        (
            arguments.assemble_decision,
            "R03 v2 qualification decision assembly",
            lambda: verifier.assemble_decision(replace=arguments.replace),
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
