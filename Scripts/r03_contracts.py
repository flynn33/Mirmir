#!/usr/bin/env python3
"""Validate the frozen R03 deterministic-baseline start contract."""

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
from r02_contracts import R02ContractVerifier


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r03/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r03-preregistration-v1.json")
FIXTURE_CATALOG_PATH = Path("docs/roadmaps/evidence/r03/records/fixtures/fixture-catalog.json")
FIXTURE_CATALOG_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r03-fixture-catalog-v1.json")
CONFORMANCE_PATH = Path("docs/roadmaps/evidence/r03/records/baseline-conformance.json")
CONFORMANCE_SCHEMA_PATH = Path("docs/roadmaps/evidence/schema/r03-baseline-conformance-v1.json")
R02_CONFORMANCE_PATH = Path("docs/roadmaps/evidence/r02/records/conformance.json")
R02_FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r02/records/fixtures/fixture-catalog.json"
)
ROADMAP_PATH = Path("docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json")

PREDECESSOR = {
    "phase_id": "R02",
    "closure_state": "local_unpublished_closure",
    "closure_commit": "673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4",
    "closure_tree": "a5e95d810abacbdb872ddc6e94125103831e6fba",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
}
OBSERVATION_POLICY = {
    "requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "runtime_execution": "observed_or_not_observed_per_subject",
    "deterministic_software_conformance": "required",
    "performance_claims": "forbidden",
}
AUTHORIZATION_BOUNDARY = {
    "production_default": "not_enabled",
    "product_qualification": "not_claimed",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "release": "not_authorized",
    "publication": "not_authorized_by_this_record",
    "performance_claims": "forbidden",
}
CONFORMANCE_OBSERVATION_STATUS_PASSED = {
    "requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "runtime_execution": "observed_or_not_observed_per_subject",
    "deterministic_software_conformance": "passed",
    "performance_claims": "forbidden",
}
CONFORMANCE_OBSERVATION_STATUS_FAILED = {
    **CONFORMANCE_OBSERVATION_STATUS_PASSED,
    "deterministic_software_conformance": "failed",
}
CONFORMANCE_LIMITATIONS = (
    "The exact bound R02 media transaction is 16x8 to 16x8, while the frozen R03 scale_2x route is 1920x1080 to 3840x2160; the contracts cannot be executed together.",
    "The R03 evidence run stopped at contract preflight before subject execution; every subject and metric is not_observed.",
    "Hardware, simulator, and operator observation were not performed; no 2x media-transaction, runtime-support, quality, repeatability, resource, or performance observation is claimed.",
    "No product qualification, production default, publication, acceptance, release, holdout, Auto-mode, or performance claim is authorized.",
)
MEDIA_TRANSACTION_FAILED_CHECK_IDS = frozenset(
    {
        "dimensions_exact",
        "frame_order_pts_duration_exact",
        "audio_identity_exact",
        "metadata_identity_exact",
        "reopen_before_atomic_publication",
    }
)
DISPOSITION_REASONS = {
    "qualified": "complete_observed_matrix_satisfied_frozen_floors",
    "restricted": "observed_matrix_requires_frozen_restriction",
    "diagnostic_only": "observed_reference_or_support_role_only",
    "rejected": "observed_matrix_failed_frozen_floor",
    "not_observed": "runtime_not_observed_under_operator_waiver",
}
BACKEND_IDS = (
    "r03.mps.lanczos",
    "r03.mps.bilinear",
    "r03.core-image.lanczos",
    "r03.core-image.bicubic",
    "r03.vimage.lanczos-3",
    "r03.vimage.lanczos-5",
    "r03.vt-pixel-transfer",
    "r03.ash-custom-metal",
    "r03.mps.guided-filter",
    "r03.core-image.edge-preserve",
)
BACKEND_ROLES = (
    ("r03.mps.lanczos", "A11", "whole_frame_backend", "deterministic_gpu_quality_baseline", "candidate_after_observed_qualification"),
    ("r03.mps.bilinear", "A12", "whole_frame_backend", "diagnostic_fast_lower_bound", "ineligible_reference_role"),
    ("r03.core-image.lanczos", "A14", "whole_frame_backend", "compatibility_reference", "ineligible_reference_role"),
    ("r03.core-image.bicubic", "A14", "whole_frame_backend", "tunable_reference_fallback", "ineligible_reference_role"),
    ("r03.vimage.lanczos-3", "A16", "whole_frame_backend", "cpu_reference", "ineligible_reference_role"),
    ("r03.vimage.lanczos-5", "A16", "whole_frame_backend", "high_quality_cpu_comparator", "ineligible_reference_role"),
    ("r03.vt-pixel-transfer", "A06", "whole_frame_backend", "scaling_conversion_reference", "ineligible_reference_role"),
    ("r03.ash-custom-metal", "A17", "whole_frame_backend", "retained_reference_comparator", "ineligible_reference_role"),
    ("r03.mps.guided-filter", "A13", "support_stage", "mask_and_chroma_support", "ineligible_support_stage"),
    ("r03.core-image.edge-preserve", "A15", "support_stage", "mask_and_chroma_support", "ineligible_support_stage"),
)
FIXTURE_IDS = (
    "route-720p-to-1080p",
    "route-1080p-to-2160p",
    "artifact-direct-3over2",
    "artifact-direct-2x",
    "temporal-repeatability-1080p-to-2160p",
    "guided-filter-support-1x",
    "edge-preserve-support-2x",
    "media-transaction-2x",
)
FIXTURE_MEMBERS = {
    "route-720p-to-1080p": ["scaler-720p"],
    "route-1080p-to-2160p": ["scaler-1080p"],
    "artifact-direct-3over2": [
        "direct-3over2.vertical-step-v2",
        "direct-3over2.horizontal-step-v2",
        "direct-3over2.diagonal-step-v2",
        "direct-3over2.single-impulse-v2",
        "direct-3over2.vertical-thin-line-v2",
        "direct-3over2.near-nyquist-checker-v2",
        "direct-3over2.left-sited-chroma-edge-v2",
    ],
    "artifact-direct-2x": [
        "direct-2x.vertical-step-v2",
        "direct-2x.horizontal-step-v2",
        "direct-2x.diagonal-step-v2",
        "direct-2x.single-impulse-v2",
        "direct-2x.vertical-thin-line-v2",
        "direct-2x.near-nyquist-checker-v2",
        "direct-2x.left-sited-chroma-edge-v2",
    ],
    "temporal-repeatability-1080p-to-2160p": [
        "temporal-frame-0",
        "temporal-frame-1",
        "temporal-frame-0",
    ],
    "guided-filter-support-1x": [
        "direct-2x.vertical-step-v2:target-luma-as-source-and-guidance"
    ],
    "edge-preserve-support-2x": [
        "direct-2x.vertical-step-v2:low-luma-mask-and-target-luma-guidance"
    ],
    "media-transaction-2x": ["fixture-media-transaction"],
}
ROUTE_IDS = (
    "scale_3_over_2",
    "scale_2x",
    "guided_support_1x",
    "edge_preserve_support_2x",
)
SCENARIO_IDS = (
    "full_route_correctness",
    "analytic_artifact_envelope",
    "temporal_repeatability",
    "media_transaction_preservation",
    "guided_filter_support",
    "edge_preserve_support",
    "closed_disposition_matrix",
    "selection_and_authorization_safety",
)
CHECK_IDS = (
    "predecessor_closure_exact",
    "schema_bindings_exact",
    "fixture_bindings_exact",
    "backend_matrix_complete",
    "genuine_framework_path",
    "common_session_contract",
    "dimensions_exact",
    "pixel_format_exact",
    "color_contract_exact",
    "processing_identity_complete",
    "frame_order_pts_duration_exact",
    "audio_identity_exact",
    "metadata_identity_exact",
    "reopen_before_atomic_publication",
    "resource_lifetime_exactly_once",
    "no_silent_fallback",
    "metric_values_finite",
    "repeatability_floor",
    "cpu_gpu_parity_disposition",
    "ringing_floor",
    "edge_measurement_floor",
    "chroma_floor",
    "temporal_repeatability_floor",
    "throughput_floor_or_not_observed",
    "memory_floor_or_not_observed",
    "resource_floor",
    "support_stage_role_preserved",
    "disposition_complete",
    "unavailable_is_not_observed",
    "no_inferred_qualification",
    "dominated_candidate_rule",
    "default_selection_rule",
    "production_default_disabled",
    "performance_claim_forbidden",
    "product_quality_claim_forbidden",
)
METRIC_IDS = (
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
    "quantized_output_code_maximum_difference",
    "cpu_gpu_normalized_absolute_maximum",
    "cpu_gpu_normalized_rms_maximum",
    "ringing_overshoot_maximum",
    "ringing_undershoot_maximum",
    "chroma_displacement_maximum",
    "edge_profile_measurement_count",
    "temporal_repeatability_mismatch_count",
    "throughput_frames_per_second",
    "p95_wall_time_milliseconds",
    "peak_resident_memory_delta_bytes",
    "peak_in_flight_resources",
)
METRIC_CONTRACTS = (
    ("dimension_mismatch_count", "count", "equal", 0, False),
    ("pixel_format_mismatch_count", "count", "equal", 0, False),
    ("color_identity_mismatch_count", "count", "equal", 0, False),
    ("frame_timing_mismatch_count", "count", "equal", 0, False),
    ("audio_identity_mismatch_count", "count", "equal", 0, False),
    ("metadata_identity_mismatch_count", "count", "equal", 0, False),
    ("resource_lifetime_violation_count", "count", "equal", 0, False),
    ("silent_fallback_count", "count", "equal", 0, False),
    ("incomplete_identity_count", "count", "equal", 0, False),
    ("nonfinite_metric_count", "count", "equal", 0, False),
    ("distinct_output_hash_count", "count_per_three_repeats", "equal", 1, True),
    ("quantized_output_code_maximum_difference", "code_value", "less_than_or_equal", 1, True),
    ("cpu_gpu_normalized_absolute_maximum", "normalized", "less_than_or_equal", "2/65535", True),
    ("cpu_gpu_normalized_rms_maximum", "normalized", "less_than_or_equal", "1/65535", True),
    ("ringing_overshoot_maximum", "normalized_step_amplitude", "less_than_or_equal", 0.05, True),
    ("ringing_undershoot_maximum", "normalized_step_amplitude", "less_than_or_equal", 0.05, True),
    ("chroma_displacement_maximum", "luma_pixels", "less_than_or_equal", 0.25, True),
    ("edge_profile_measurement_count", "count_per_route", "greater_than_or_equal", 3, True),
    ("temporal_repeatability_mismatch_count", "count", "equal", 0, True),
    ("throughput_frames_per_second", "frames_per_second", "greater_than", 0, True),
    ("p95_wall_time_milliseconds", "milliseconds", "greater_than", 0, True),
    ("peak_resident_memory_delta_bytes", "bytes", "finite_nonnegative", 0, True),
    ("peak_in_flight_resources", "count", "less_than_or_equal", 3, True),
)
PASSING_METRIC_VALUES = {
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
    "distinct_output_hash_count": 1,
    "quantized_output_code_maximum_difference": 0,
    "cpu_gpu_normalized_absolute_maximum": 0,
    "cpu_gpu_normalized_rms_maximum": 0,
    "ringing_overshoot_maximum": 0,
    "ringing_undershoot_maximum": 0,
    "chroma_displacement_maximum": 0,
    "edge_profile_measurement_count": 3,
    "temporal_repeatability_mismatch_count": 0,
    "throughput_frames_per_second": 1,
    "p95_wall_time_milliseconds": 1,
    "peak_resident_memory_delta_bytes": 0,
    "peak_in_flight_resources": 1,
}
CPU_GPU_PARITY_METRIC_IDS = frozenset(
    {
        "cpu_gpu_normalized_absolute_maximum",
        "cpu_gpu_normalized_rms_maximum",
    }
)
SUPPORT_STAGE_APPLICABLE_METRIC_IDS = frozenset(
    {
        # The frozen support scenarios require dimensions_exact and
        # metric_values_finite; no other metric-bearing check is assigned.
        "dimension_mismatch_count",
        "nonfinite_metric_count",
    }
)
STOP_RULE_IDS = (
    "predecessor_identity_drift",
    "contract_byte_drift",
    "matrix_incomplete",
    "nongenuine_implementation",
    "format_contract_violation",
    "media_contract_violation",
    "identity_or_fallback_violation",
    "measurement_integrity_violation",
    "observed_floor_failure",
    "resource_or_lifecycle_violation",
    "observed_envelope_incomplete",
    "selection_rule_violation",
    "fabricated_observation",
    "authorization_boundary",
)
WHOLE_FRAME_BACKEND_CHECK_IDS = tuple(
    check_id
    for check_id in CHECK_IDS
    if check_id
    in {
        "backend_matrix_complete",
        "genuine_framework_path",
        "common_session_contract",
        "dimensions_exact",
        "pixel_format_exact",
        "color_contract_exact",
        "processing_identity_complete",
        "frame_order_pts_duration_exact",
        "audio_identity_exact",
        "metadata_identity_exact",
        "reopen_before_atomic_publication",
        "metric_values_finite",
        "repeatability_floor",
        "ringing_floor",
        "edge_measurement_floor",
        "chroma_floor",
        "temporal_repeatability_floor",
        "disposition_complete",
        "unavailable_is_not_observed",
        "no_inferred_qualification",
        "dominated_candidate_rule",
        "default_selection_rule",
        "production_default_disabled",
        "performance_claim_forbidden",
        "product_quality_claim_forbidden",
    }
)
SUPPORT_STAGE_CHECK_IDS = tuple(
    check_id
    for check_id in CHECK_IDS
    if check_id
    in {
        "backend_matrix_complete",
        "genuine_framework_path",
        "dimensions_exact",
        "metric_values_finite",
        "support_stage_role_preserved",
        "disposition_complete",
        "unavailable_is_not_observed",
        "no_inferred_qualification",
    }
)
BACKEND_CHECK_IDS = {
    backend_id: (
        SUPPORT_STAGE_CHECK_IDS
        if kind == "support_stage"
        else WHOLE_FRAME_BACKEND_CHECK_IDS
    )
    for backend_id, _capability, kind, _role, _eligibility in BACKEND_ROLES
}
QUALIFIABLE_BACKEND_IDS = frozenset(
    backend_id
    for backend_id, _capability, _kind, _role, eligibility in BACKEND_ROLES
    if eligibility == "candidate_after_observed_qualification"
)
SUPPORT_STAGE_BACKEND_IDS = frozenset(
    backend_id
    for backend_id, _capability, kind, _role, _eligibility in BACKEND_ROLES
    if kind == "support_stage"
)
BACKEND_NOT_APPLICABLE_METRIC_IDS = {
    backend_id: (
        frozenset(METRIC_IDS) - SUPPORT_STAGE_APPLICABLE_METRIC_IDS
        if kind == "support_stage"
        else CPU_GPU_PARITY_METRIC_IDS
    )
    for backend_id, _capability, kind, _role, _eligibility in BACKEND_ROLES
}
SOURCE_BINDINGS = {
    "r01_fixture_catalog": ("docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json", 9656, "ae8241f5d69ce64ed143e8bbb39ab80a996f6923f1ddc83ebfbaec58d9689182"),
    "r02_fixture_catalog": ("docs/roadmaps/evidence/r02/records/fixtures/fixture-catalog.json", 8865, "245d3f73186322503aa1ebfaf5a5865994063997cda240374340427f4a3bebf3"),
    "r02_fixture_generator": ("Scripts/r02_fixture_generator.py", 1849, "6155e72eaeac221bcf88c6fcac48bd45aecaa0043046bf1b6dfd46fb68e53b3e"),
    "r01_scaler_720p": ("project-notes/evidence/r01/fixtures/scaler-720p.bin", 1382400, "77b432c2d459fa662d06f3086b2ac7c051a16e492da8783472917224aa96c73e"),
    "r01_scaler_1080p": ("project-notes/evidence/r01/fixtures/scaler-1080p.bin", 3110400, "44795da53184aca29cb905fa27c4362d7fec0cde1048c3cc5724f17dbb232c15"),
    "r01_temporal_frame_0": ("project-notes/evidence/r01/fixtures/temporal-frame-0.bin", 3110400, "e62159913ef91af0784820cc71edea1d5db6014fe8853ea012f20a461c359bbd"),
    "r01_temporal_frame_1": ("project-notes/evidence/r01/fixtures/temporal-frame-1.bin", 3110400, "503a754a679221dc5a2a29b4a0d3b1382b6084ab7f886cb9760356310335f168"),
    "analytic_fixture_manifest": ("validation/quality/reference/analytic-fixtures-v2.json", 15978, "4bc11e0b0b074be2a6bfcf509a62181220249f4e107e1ee920170c78b0eb47aa"),
    "metric_policy": ("validation/quality/policies/metric-policy.json", 3375, "cf1be5cd4fce0bc81665146b1638f7b80043aed6506f3c9276170ab638648ec1"),
    "metric_tolerances": ("validation/calibration_v2/contracts/metric-performance-tolerances-v1.json", 4337, "45f6c4fe193510ef046826f98ea8ffba8541f64284758c59317e4a6de09cd91a"),
}
ARTIFACT_IDS = tuple(
    f"direct-{route}.{kind}-v2"
    for route in ("2x", "3over2")
    for kind in (
        "vertical-step",
        "horizontal-step",
        "diagonal-step",
        "single-impulse",
        "vertical-thin-line",
        "near-nyquist-checker",
        "left-sited-chroma-edge",
    )
)
PREREGISTRATION_SEMANTIC_SHA256 = (
    "93a984c336ed06b568a8b34dca78aaab3ee1c903734df1172d4c1893ca825914"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "996e7fb93a6bccbb591cbf39b4ade19a33134982ae6a07ff4b1ac3271edd5d2f"
)
SOURCE_CONTRACT_PATHS = (
    PREREGISTRATION_PATH,
    FIXTURE_CATALOG_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    CONFORMANCE_SCHEMA_PATH,
)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _semantic_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return _sha256(payload)


def _metric_threshold(value: int | float | str) -> float:
    if isinstance(value, str):
        return float(Fraction(value))
    return float(value)


def _metric_passes(value: object, operator: str, threshold: int | float | str) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    numeric = float(value)
    if not math.isfinite(numeric):
        return False
    floor = _metric_threshold(threshold)
    if operator == "equal":
        return numeric == floor
    if operator == "less_than_or_equal":
        return numeric <= floor
    if operator == "greater_than":
        return numeric > floor
    if operator == "greater_than_or_equal":
        return numeric >= floor
    if operator == "finite_nonnegative":
        return numeric >= 0
    return False


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                key_text = str(key)
                if key_text.lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(f"{context} contains forbidden private key at {location}.{key_text}")
                visit(nested, f"{location}.{key_text}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(f"{context} contains an email address at {location}")
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains a private filesystem path at {location}")

    visit(value, "$")
    return errors


class R03ContractVerifier:
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

    def _safe_path(self, value: object, context: str, errors: list[str]) -> Path | None:
        if not isinstance(value, str) or not value:
            errors.append(f"{context}.path must be a non-empty string")
            return None
        if "\x00" in value:
            errors.append(f"{context}.path contains a NUL byte")
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

    def _read_json(self, relative: Path, context: str, errors: list[str]) -> dict[str, Any] | None:
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

    def _check_binding(self, binding: object, context: str, errors: list[str]) -> None:
        if not isinstance(binding, dict) or set(binding) != {"path", "size_bytes", "sha256"}:
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

    def _check_source(self, source: object, context: str, errors: list[str]) -> None:
        if not isinstance(source, dict) or set(source) != {"commit", "tree"}:
            errors.append(f"{context} must contain only commit and tree")
            return
        commit = source.get("commit")
        tree = source.get("tree")
        if not isinstance(commit, str) or not isinstance(tree, str):
            errors.append(f"{context} commit and tree must be strings")
            return
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append(f"{context} commit is unavailable")
            return
        predecessor = PREDECESSOR["closure_commit"]
        if commit == predecessor or self.git(
            "merge-base", "--is-ancestor", predecessor, commit
        ).returncode != 0:
            errors.append(f"{context} must be a strict descendant of the R02 closure")
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != tree:
            errors.append(f"{context} tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append(f"{context} commit must be an ancestor of HEAD")
        for relative in SOURCE_CONTRACT_PATHS:
            historical = self.git_bytes("show", f"{commit}:{relative.as_posix()}")
            current = self.root / relative
            if (
                historical.returncode != 0
                or current.is_symlink()
                or not current.is_file()
                or historical.stdout != current.read_bytes()
            ):
                errors.append(
                    f"{context} does not contain the frozen R03 contract bytes: "
                    f"{relative.as_posix()}"
                )

    def _check_predecessor(self, preregistration: dict[str, Any], errors: list[str]) -> None:
        if preregistration.get("predecessor_binding") != PREDECESSOR:
            errors.append("R03 predecessor binding differs from the exact local R02 closure")
            return
        commit = PREDECESSOR["closure_commit"]
        tree = PREDECESSOR["closure_tree"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R03 predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}").stdout.strip()
        if observed_tree != tree:
            errors.append("R03 predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R03 predecessor closure commit is not an ancestor of HEAD")
        closure = self.git("show", f"{commit}:{R02_CONFORMANCE_PATH.as_posix()}")
        if closure.returncode != 0:
            errors.append("R02 conformance is absent at the R03 predecessor closure")
            return
        try:
            record = decode_json(closure.stdout)
        except ValueError as error:
            errors.append(f"R02 closure conformance is invalid: {error}")
            return
        if not isinstance(record, dict):
            errors.append("R02 closure conformance must be an object")
            return
        result = record.get("result")
        if not isinstance(result, dict) or result.get("status") != "passed":
            errors.append("R02 closure conformance is not passed")
        authorization = result.get("authorization") if isinstance(result, dict) else None
        if not isinstance(authorization, dict) or authorization.get("phase_acceptance") != "not_claimed":
            errors.append("R02 closure must preserve acceptance not claimed")
        if record.get("observation_status", {}).get("performance_claims") != "forbidden":
            errors.append("R02 closure performance boundary differs")

    def _check_preregistration_semantics(self, value: dict[str, Any], errors: list[str]) -> None:
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R03 preregistration semantic contract differs")
        errors.extend(_privacy_errors(value, "R03 preregistration"))
        expected_keys = {
            "schema_version", "roadmap_version", "phase_id", "preregistration_state",
            "predecessor_binding", "observation_policy", "fixture_catalog",
            "schema_bindings", "contract", "metrics", "checks", "stop_rules",
            "authorization_boundary",
        }
        if set(value) != expected_keys:
            errors.append("R03 preregistration top-level keys differ")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R03 observation policy differs from the operator override")
        if value.get("authorization_boundary") != AUTHORIZATION_BOUNDARY:
            errors.append("R03 authorization boundary differs")
        contract = value.get("contract")
        if not isinstance(contract, dict) or contract.get("backend_ids") != list(BACKEND_IDS):
            errors.append("R03 backend ID order differs")
        expected_contract = {
            "session_contract": "apple-upscale-session-v1",
            "media_transaction_contract": "r02_exact_media_transaction_v1",
            "format_scope": "8_bit_nv12_sdr_bt709_video_range_left_chroma",
            "backend_ids": list(BACKEND_IDS),
            "disposition_vocabulary": ["qualified", "restricted", "diagnostic_only", "rejected", "not_observed"],
            "capability_inference": "forbidden",
            "domination_rule": "eliminate_only_from_complete_observed_comparable_metrics",
            "default_selection": "qualified_primary_candidates_by_wall_time_then_memory_then_backend_id",
        }
        if contract != expected_contract:
            errors.append("R03 implementation contract differs")
        metrics = value.get("metrics")
        observed_metric_ids = [item.get("id") for item in metrics] if isinstance(metrics, list) else []
        if observed_metric_ids != list(METRIC_IDS):
            errors.append("R03 metric IDs/order differ")
        checks = value.get("checks")
        observed_check_ids = [item.get("id") for item in checks] if isinstance(checks, list) else []
        if observed_check_ids != list(CHECK_IDS):
            errors.append("R03 check IDs/order differ")
        rules = value.get("stop_rules")
        observed_rule_ids = [item.get("id") for item in rules] if isinstance(rules, list) else []
        if observed_rule_ids != list(STOP_RULE_IDS):
            errors.append("R03 stop-rule IDs/order differ")
        schemas = value.get("schema_bindings")
        expected_schema_paths = {
            "preregistration": PREREGISTRATION_SCHEMA_PATH,
            "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
            "conformance": CONFORMANCE_SCHEMA_PATH,
        }
        if not isinstance(schemas, dict) or set(schemas) != set(expected_schema_paths):
            errors.append("R03 schema binding keys differ")
        else:
            for identifier, relative in expected_schema_paths.items():
                binding = schemas.get(identifier)
                self._check_binding(binding, f"schema_bindings.{identifier}", errors)
                if isinstance(binding, dict) and binding.get("path") != relative.as_posix():
                    errors.append(f"schema_bindings.{identifier}.path differs")
        self._check_binding(value.get("fixture_catalog"), "fixture_catalog", errors)
        binding = value.get("fixture_catalog")
        if isinstance(binding, dict) and binding.get("path") != FIXTURE_CATALOG_PATH.as_posix():
            errors.append("fixture_catalog.path differs")

    def _check_fixture_semantics(self, catalog: dict[str, Any], errors: list[str]) -> None:
        if _semantic_sha256(catalog) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R03 fixture catalog semantic contract differs")
        errors.extend(_privacy_errors(catalog, "R03 fixture catalog"))
        expected_keys = {
            "schema_version", "phase_id", "contract_id", "color_contract",
            "source_bindings", "routes", "fixtures", "backend_matrix", "scenarios",
        }
        if set(catalog) != expected_keys:
            errors.append("R03 fixture catalog top-level keys differ")
        if catalog.get("color_contract") != {
            "pixel_format": "420v", "bit_depth": 8, "primaries": "ITU_R_709_2",
            "transfer_function": "ITU_R_709_2", "matrix": "ITU_R_709_2",
            "range": "video", "chroma_location": "left",
        }:
            errors.append("R03 color contract differs")
        bindings = catalog.get("source_bindings")
        binding_values = bindings if isinstance(bindings, list) else []
        expected_bindings = [
            {"id": identifier, "path": path, "size_bytes": size, "sha256": digest}
            for identifier, (path, size, digest) in SOURCE_BINDINGS.items()
        ]
        if binding_values != expected_bindings:
            errors.append("R03 source bindings differ from frozen bytes")
        for index, binding in enumerate(binding_values):
            if not isinstance(binding, dict):
                errors.append(f"source_bindings[{index}] must be an object")
                continue
            self._check_binding(
                {key: binding.get(key) for key in ("path", "size_bytes", "sha256")},
                f"source_bindings[{index}]",
                errors,
            )
        routes = catalog.get("routes")
        route_values = routes if isinstance(routes, list) else []
        if [item.get("id") for item in route_values if isinstance(item, dict)] != list(ROUTE_IDS):
            errors.append("R03 route IDs/order differ")
        fixtures = catalog.get("fixtures")
        fixture_values = fixtures if isinstance(fixtures, list) else []
        if [item.get("id") for item in fixture_values if isinstance(item, dict)] != list(FIXTURE_IDS):
            errors.append("R03 fixture IDs/order differ")
        observed_members = {
            item.get("id"): item.get("member_ids")
            for item in fixture_values
            if isinstance(item, dict)
        }
        if observed_members != FIXTURE_MEMBERS:
            errors.append("R03 fixture members differ")
        matrix = catalog.get("backend_matrix")
        matrix_values = matrix if isinstance(matrix, list) else []
        observed_roles = [
            (item.get("id"), item.get("capability_id"), item.get("kind"), item.get("qualification_role"), item.get("product_default_eligibility"))
            for item in matrix_values if isinstance(item, dict)
        ]
        if observed_roles != list(BACKEND_ROLES):
            errors.append("R03 backend role matrix differs")
        if [item.get("id") for item in matrix_values if isinstance(item, dict)] != list(BACKEND_IDS):
            errors.append("R03 backend matrix IDs/order differ")
        scenarios = catalog.get("scenarios")
        scenario_values = scenarios if isinstance(scenarios, list) else []
        if [item.get("id") for item in scenario_values if isinstance(item, dict)] != list(SCENARIO_IDS):
            errors.append("R03 scenario IDs/order differ")
        valid_backend_ids = set(BACKEND_IDS)
        valid_fixture_ids = set(FIXTURE_IDS)
        valid_check_ids = set(CHECK_IDS)
        for scenario in scenario_values:
            if not isinstance(scenario, dict):
                continue
            if not set(scenario.get("backend_ids", [])) <= valid_backend_ids:
                errors.append(f"R03 scenario {scenario.get('id')} has unknown backend")
            if not set(scenario.get("fixture_ids", [])) <= valid_fixture_ids:
                errors.append(f"R03 scenario {scenario.get('id')} has unknown fixture")
            if not set(scenario.get("required_check_ids", [])) <= valid_check_ids:
                errors.append(f"R03 scenario {scenario.get('id')} has unknown check")
        analytic = self._read_json(Path(SOURCE_BINDINGS["analytic_fixture_manifest"][0]), "analytic fixture manifest", errors)
        if analytic is not None:
            values = analytic.get("fixtures")
            observed = {
                item.get("fixture_id") for item in values if isinstance(item, dict)
            } if isinstance(values, list) else set()
            if not set(ARTIFACT_IDS) <= observed:
                errors.append("R03 analytic fixture members are absent from their bound manifest")
        r02_catalog = self._read_json(Path(SOURCE_BINDINGS["r02_fixture_catalog"][0]), "R02 fixture catalog", errors)
        if r02_catalog is not None:
            values = r02_catalog.get("fixtures")
            observed = {item.get("id") for item in values if isinstance(item, dict)} if isinstance(values, list) else set()
            if "fixture-media-transaction" not in observed:
                errors.append("R03 media transaction fixture is absent from the R02 catalog")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R03 preregistration",
            errors,
        )
        catalog = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R03 fixture catalog",
            errors,
        )
        if value is not None:
            self._check_predecessor(value, errors)
            self._check_preregistration_semantics(value, errors)
        if catalog is not None:
            self._check_fixture_semantics(catalog, errors)
        errors.extend(f"R02 predecessor conformance: {error}" for error in R02ContractVerifier(self.root).check_conformance())
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        catalog = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R03 fixture catalog",
            errors,
        )
        if catalog is not None:
            self._check_fixture_semantics(catalog, errors)
        return errors

    def _check_metric_matrix(
        self,
        backend_id: object,
        execution_status: object,
        disposition: object,
        metric_results: object,
        errors: list[str],
    ) -> None:
        context = f"R03 conformance backend {backend_id}"
        values = metric_results if isinstance(metric_results, list) else []
        if not isinstance(metric_results, list):
            errors.append(f"{context} metric_results must be an array")
        observed_ids = [
            item.get("id") for item in values if isinstance(item, dict)
        ]
        if observed_ids != list(METRIC_IDS) or len(values) != len(METRIC_CONTRACTS):
            errors.append(f"{context} metric matrix differs from the frozen matrix")
        measured_results: list[bool] = []
        observed_statuses: list[object] = []
        not_applicable_ids = BACKEND_NOT_APPLICABLE_METRIC_IDS.get(
            backend_id, frozenset()
        )
        for index, contract in enumerate(METRIC_CONTRACTS):
            metric_id, unit, operator, threshold, not_observed_allowed = contract
            if index >= len(values) or not isinstance(values[index], dict):
                continue
            metric = values[index]
            if set(metric) != {"id", "unit", "status", "value", "passed"}:
                errors.append(f"{context} metric result keys differ: {metric_id}")
            if metric.get("id") != metric_id or metric.get("unit") != unit:
                errors.append(f"{context} metric identity differs: {metric_id}")
            status = metric.get("status")
            value = metric.get("value")
            passed = metric.get("passed")
            observed_statuses.append(status)
            if execution_status == "observed":
                if (
                    backend_id in SUPPORT_STAGE_BACKEND_IDS
                    and metric_id in not_applicable_ids
                    and status != "not_applicable"
                ):
                    errors.append(
                        f"{context} out-of-contract support metric must be "
                        f"not_applicable: {metric_id}"
                    )
                if status == "not_applicable" and metric_id not in not_applicable_ids:
                    errors.append(
                        f"{context} metric cannot be not_applicable: {metric_id}"
                    )
            if status == "measured":
                derived = _metric_passes(value, operator, threshold)
                if passed is not derived:
                    errors.append(
                        f"{context} metric pass flag is not derived from the frozen floor: "
                        f"{metric_id}"
                    )
                measured_results.append(derived)
            elif status in {"not_observed", "not_applicable"}:
                if value is not None or passed is not None:
                    errors.append(
                        f"{context} unmeasured metric carries an observation: {metric_id}"
                    )
                if execution_status == "observed" and (
                    status == "not_observed" and not not_observed_allowed
                ):
                    errors.append(
                        f"{context} required software metric is unmeasured: {metric_id}"
                    )
            else:
                errors.append(f"{context} metric status differs: {metric_id}")

        if execution_status == "not_observed":
            if disposition != "not_observed":
                errors.append(f"{context} not-observed execution has an observed disposition")
            if observed_statuses != ["not_observed"] * len(METRIC_CONTRACTS):
                errors.append(f"{context} not-observed execution fabricates metric evidence")
        elif execution_status == "observed":
            if disposition == "not_observed":
                errors.append(f"{context} observed execution has a not-observed disposition")
            if not measured_results:
                errors.append(f"{context} observed execution has no measured metrics")
        else:
            errors.append(f"{context} execution status differs")

        if disposition == "qualified":
            if backend_id not in QUALIFIABLE_BACKEND_IDS:
                errors.append(f"{context} is ineligible for a qualified disposition")
            if observed_statuses != ["measured"] * len(METRIC_CONTRACTS):
                errors.append(f"{context} qualified disposition has an incomplete metric matrix")
            if measured_results != [True] * len(METRIC_CONTRACTS):
                errors.append(f"{context} qualified disposition failed a frozen floor")
        if disposition == "rejected" and measured_results and all(measured_results):
            errors.append(f"{context} rejected disposition has no failed observed floor")

    def _check_conformance_semantics(
        self, conformance: dict[str, Any], errors: list[str]
    ) -> None:
        errors.extend(_privacy_errors(conformance, "R03 baseline conformance"))
        if {
            "schema_version": conformance.get("schema_version"),
            "roadmap_version": conformance.get("roadmap_version"),
            "phase_id": conformance.get("phase_id"),
            "evidence_kind": conformance.get("evidence_kind"),
        } != {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R03",
            "evidence_kind": "r03_deterministic_baseline_matrix",
        }:
            errors.append("R03 conformance identity differs from the frozen contract")
        expected_keys = {
            "schema_version",
            "roadmap_version",
            "phase_id",
            "evidence_kind",
            "source",
            "preregistration_binding",
            "fixture_catalog_binding",
            "observation_status",
            "backend_results",
            "checks",
            "result",
            "limitations",
        }
        if set(conformance) != expected_keys:
            errors.append("R03 conformance top-level keys differ")

        checks = conformance.get("checks")
        check_values = checks if isinstance(checks, list) else []
        if not isinstance(checks, list):
            errors.append("R03 conformance checks must be an array")
        observed_check_ids = [
            item.get("id") for item in check_values if isinstance(item, dict)
        ]
        if observed_check_ids != list(CHECK_IDS) or len(check_values) != len(CHECK_IDS):
            errors.append("R03 conformance check matrix differs from the frozen matrix")
        check_statuses: dict[str, object] = {}
        for index, check_id in enumerate(CHECK_IDS):
            if index >= len(check_values) or not isinstance(check_values[index], dict):
                continue
            item = check_values[index]
            if set(item) != {"id", "status"}:
                errors.append(f"R03 conformance check keys differ: {check_id}")
            status = item.get("status")
            if status not in {"passed", "failed"}:
                errors.append(f"R03 conformance check status differs: {check_id}")
            check_statuses[check_id] = status

        backends = conformance.get("backend_results")
        backend_values = backends if isinstance(backends, list) else []
        if not isinstance(backends, list):
            errors.append("R03 conformance backend_results must be an array")
        observed_backend_ids = [
            item.get("backend_id") for item in backend_values if isinstance(item, dict)
        ]
        if observed_backend_ids != list(BACKEND_IDS) or len(backend_values) != len(BACKEND_IDS):
            errors.append("R03 conformance backend result matrix differs from the frozen matrix")
        for index, backend_id in enumerate(BACKEND_IDS):
            if index >= len(backend_values) or not isinstance(backend_values[index], dict):
                continue
            backend = backend_values[index]
            if set(backend) != {
                "backend_id",
                "execution_status",
                "disposition",
                "reason",
                "check_ids",
                "metric_results",
            }:
                errors.append(f"R03 conformance backend result keys differ: {backend_id}")
            if backend.get("backend_id") != backend_id:
                errors.append(f"R03 conformance backend identity differs: {backend_id}")
            disposition = backend.get("disposition")
            if disposition not in DISPOSITION_REASONS:
                errors.append(f"R03 conformance backend disposition differs: {backend_id}")
            if backend.get("reason") != DISPOSITION_REASONS.get(disposition):
                errors.append(f"R03 conformance backend reason differs: {backend_id}")
            if backend.get("check_ids") != list(BACKEND_CHECK_IDS[backend_id]):
                errors.append(f"R03 conformance backend check coverage differs: {backend_id}")
            self._check_metric_matrix(
                backend_id,
                backend.get("execution_status"),
                disposition,
                backend.get("metric_results"),
                errors,
            )
            if disposition == "qualified" and any(
                check_statuses.get(check_id) != "passed"
                for check_id in BACKEND_CHECK_IDS[backend_id]
            ):
                errors.append(f"R03 conformance qualified backend has a failed check: {backend_id}")

        result = conformance.get("result")
        result_status = result.get("status") if isinstance(result, dict) else None
        if result_status not in {"passed", "diagnostic_only", "blocked"}:
            errors.append("R03 conformance result status differs")
        expected_observation = (
            CONFORMANCE_OBSERVATION_STATUS_PASSED
            if result_status == "passed"
            else CONFORMANCE_OBSERVATION_STATUS_FAILED
        )
        if conformance.get("observation_status") != expected_observation:
            errors.append("R03 conformance observation status contradicts the result")
        all_checks_passed = (
            len(check_statuses) == len(CHECK_IDS)
            and all(check_statuses.get(check_id) == "passed" for check_id in CHECK_IDS)
        )
        if result_status == "passed" and not all_checks_passed:
            errors.append("R03 passed result requires the complete passing frozen check matrix")
        if result_status in {"diagnostic_only", "blocked"} and all_checks_passed:
            errors.append("R03 non-passing result contradicts the complete passing check matrix")
        if not isinstance(result, dict) or result != {
            "status": result_status,
            "default_backend_id": None,
            "product_qualification": "not_claimed",
            "performance_claims": "forbidden",
        }:
            errors.append("R03 conformance result exceeds the authorization boundary")
        if conformance.get("limitations") != list(CONFORMANCE_LIMITATIONS):
            errors.append("R03 conformance limitations differ from the frozen boundary")

    def _media_transaction_route_is_compatible(
        self, errors: list[str]
    ) -> bool:
        r03_catalog = self._read_json(
            FIXTURE_CATALOG_PATH,
            "R03 fixture catalog for media-route preflight",
            errors,
        )
        r02_catalog = self._read_json(
            R02_FIXTURE_CATALOG_PATH,
            "R02 fixture catalog for media-route preflight",
            errors,
        )
        if r03_catalog is None or r02_catalog is None:
            return False

        r03_fixtures = r03_catalog.get("fixtures")
        r03_routes = r03_catalog.get("routes")
        r02_fixtures = r02_catalog.get("fixtures")
        catalog_arrays = (r03_fixtures, r03_routes, r02_fixtures)
        if not all(isinstance(values, list) for values in catalog_arrays):
            errors.append("R03 media-route preflight catalogs have invalid arrays")
            return False

        transaction = next(
            (
                item
                for item in r03_fixtures
                if isinstance(item, dict) and item.get("id") == "media-transaction-2x"
            ),
            None,
        )
        if not isinstance(transaction, dict):
            errors.append("R03 media-route preflight transaction is absent")
            return False
        member_ids = transaction.get("member_ids")
        if not isinstance(member_ids, list) or member_ids != ["fixture-media-transaction"]:
            errors.append("R03 media-route preflight member differs")
            return False
        route = next(
            (
                item
                for item in r03_routes
                if isinstance(item, dict) and item.get("id") == transaction.get("route_id")
            ),
            None,
        )
        member = next(
            (
                item
                for item in r02_fixtures
                if isinstance(item, dict) and item.get("id") == member_ids[0]
            ),
            None,
        )
        if not isinstance(route, dict) or not isinstance(member, dict):
            errors.append("R03 media-route preflight route or exact R02 member is absent")
            return False
        return (
            member.get("source_dimensions") == route.get("input_dimensions")
            and member.get("target_dimensions") == route.get("output_dimensions")
        )

    def _check_media_transaction_closure(
        self, conformance: dict[str, Any], errors: list[str]
    ) -> None:
        if self._media_transaction_route_is_compatible(errors):
            return

        result = conformance.get("result")
        if not isinstance(result, dict) or result.get("status") != "blocked":
            errors.append("R03 incompatible media route requires a blocked result")
        checks = conformance.get("checks")
        failed_checks = {
            item.get("id")
            for item in checks
            if isinstance(item, dict) and item.get("status") == "failed"
        } if isinstance(checks, list) else set()
        if failed_checks != MEDIA_TRANSACTION_FAILED_CHECK_IDS:
            errors.append(
                "R03 incompatible media route requires the exact failed media check set"
            )
        backends = conformance.get("backend_results")
        backend_values = backends if isinstance(backends, list) else []

        def carries_observation(backend: dict[str, Any]) -> bool:
            metrics = backend.get("metric_results")
            if backend.get("execution_status") != "not_observed":
                return True
            if not isinstance(metrics, list):
                return True
            return any(
                not isinstance(metric, dict)
                or metric.get("status") != "not_observed"
                for metric in metrics
            )

        if any(
            carries_observation(backend)
            for backend in backend_values
            if isinstance(backend, dict)
        ):
            errors.append(
                "R03 incompatible media route forbids observed subject or metric evidence"
            )

    def check_conformance(self) -> list[str]:
        errors = self.check_preregistration()
        value = self._read_and_validate(
            CONFORMANCE_PATH,
            CONFORMANCE_SCHEMA_PATH,
            "R03 baseline conformance",
            errors,
        )
        if value is not None:
            self._check_source(value.get("source"), "R03 conformance source", errors)
            self._check_exact_binding(
                value.get("preregistration_binding"),
                PREREGISTRATION_PATH,
                "conformance.preregistration_binding",
                errors,
            )
            self._check_exact_binding(
                value.get("fixture_catalog_binding"),
                FIXTURE_CATALOG_PATH,
                "conformance.fixture_catalog_binding",
                errors,
            )
            self._check_conformance_semantics(value, errors)
            self._check_media_transaction_closure(value, errors)
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
    parser.add_argument("--check-conformance", action="store_true")
    arguments = parser.parse_args(argv)
    if not any((arguments.check_preregistration, arguments.check_fixtures, arguments.check_conformance)):
        parser.error("select --check-preregistration, --check-fixtures, and/or --check-conformance")
    verifier = R03ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if arguments.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if arguments.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if arguments.check_conformance:
        errors.extend(verifier.check_conformance())
    if not errors:
        if arguments.check_preregistration:
            print("R03 preregistration: PASS")
        if arguments.check_fixtures:
            print("R03 fixtures: PASS")
        if arguments.check_conformance:
            print("R03 conformance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
