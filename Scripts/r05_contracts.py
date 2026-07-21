#!/usr/bin/env python3
"""Validate the frozen R05 MetalFX suitability contract."""

from __future__ import annotations

import argparse
import hashlib
import json
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


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r05/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r05-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r05/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r05-fixture-catalog-v1.json"
)
CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r05/records/suitability-conformance.json"
)
CONFORMANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r05-suitability-conformance-v1.json"
)
R04_CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r04/records/integration-conformance.json"
)

PREDECESSOR = {
    "phase_id": "R04",
    "closure_state": "local_unpublished_diagnostic_only_closure",
    "closure_commit": "88e26f5967f7eb35a54791017ca0c2b888f2fbf5",
    "closure_tree": "4a7cc588b6fa51c21f2293e56cf3dea389acd908",
    "predecessor_result": "diagnostic_only",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
}
TOOLCHAIN_BOUNDARY = {
    "platform": "macOS",
    "spatial_runtime_floor": "macOS 13.0",
    "extended_runtime_floor": "macOS 26.0",
    "sdk_family": "macOS 26",
    "compiler_floor": "Swift 6.2",
    "simulator_availability": "unavailable",
    "simulator_availability_effect": "not_a_blocker",
}
OBSERVATION_POLICY = {
    "hardware_requirement": "waived_not_a_blocker",
    "simulator_requirement": "waived_not_a_blocker",
    "operator_observation_requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "runtime_execution": "observed_or_not_observed_per_subject",
    "deterministic_software_conformance": "required",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
}
AUTHORIZATION_BOUNDARY = {
    "production_default": "not_enabled",
    "product_qualification": "not_claimed",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "acceptance": "not_claimed",
    "release": "not_authorized",
    "publication": "not_authorized_by_this_record",
}
CONTRACT = {
    "color_scope": "8_bit_nv12_sdr_bt709_video_range_left_chroma",
    "color_bridge": (
        "explicit_left_sited_bt709_video_range_nv12_to_linear_rgba16float_and_back"
    ),
    "spatial_routes": "A07_exact_1p5x_and_2x_after_device_support_query_only",
    "temporal_disposition": (
        "A08_rejected_for_decoded_video_missing_renderer_motion_depth_jitter_semantics"
    ),
    "denoised_temporal_disposition": (
        "A09_rejected_for_decoded_video_missing_renderer_gbuffer_motion_depth_camera_semantics"
    ),
    "frame_interpolation_disposition": (
        "A10_rejected_for_decoded_video_missing_renderer_motion_depth_camera_and_output_timing_contract"
    ),
    "auxiliary_input_policy": (
        "renderer_semantics_must_be_independently_evidence_backed_never_fabricated"
    ),
    "identity_contract": (
        "exact_dimensions_format_color_timing_audio_metadata_processing_and_route_identity"
    ),
    "capability_inference": "forbidden",
}
SUBJECT_IDENTITIES = (
    ("r05.metalfx.spatial-1p5x", "A07", "spatial", "spatial_1p5x", "runtime_observation_required", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "candidate_after_observed_qualification"),
    ("r05.metalfx.spatial-2x", "A07", "spatial", "spatial_2x", "runtime_observation_required", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "candidate_after_observed_qualification"),
    ("r05.metalfx.temporal-1p5x", "A08", "temporal", "temporal_1p5x_contract", "typed_decoded_video_rejection", "contract_rejected", "rejected_for_decoded_video", "missing_renderer_motion_depth_jitter_semantics", "ineligible_contract_rejection"),
    ("r05.metalfx.temporal-2x", "A08", "temporal", "temporal_2x_contract", "typed_decoded_video_rejection", "contract_rejected", "rejected_for_decoded_video", "missing_renderer_motion_depth_jitter_semantics", "ineligible_contract_rejection"),
    ("r05.metalfx.denoised-temporal-1p5x", "A09", "temporal_denoised", "denoised_temporal_1p5x_contract", "typed_decoded_video_rejection", "contract_rejected", "rejected_for_decoded_video", "missing_renderer_gbuffer_motion_depth_camera_semantics", "ineligible_contract_rejection"),
    ("r05.metalfx.denoised-temporal-2x", "A09", "temporal_denoised", "denoised_temporal_2x_contract", "typed_decoded_video_rejection", "contract_rejected", "rejected_for_decoded_video", "missing_renderer_gbuffer_motion_depth_camera_semantics", "ineligible_contract_rejection"),
    ("r05.metalfx.frame-interpolation-1080p", "A10", "frame_interpolation", "frame_interpolation_1080p_contract", "typed_decoded_video_rejection", "contract_rejected", "rejected_for_decoded_video", "missing_renderer_motion_depth_camera_and_output_timing_contract", "ineligible_contract_rejection"),
)
SUBJECT_IDS = tuple(item[0] for item in SUBJECT_IDENTITIES)
CHECK_IDS = (
    "predecessor_closure_exact",
    "canonical_dependency_boundary_exact",
    "frozen_bindings_exact",
    "subject_matrix_complete",
    "toolchain_boundary_exact",
    "simulator_unavailable_nonblocking",
    "spatial_exact_routes_and_color_bridge",
    "spatial_support_query_before_construction",
    "spatial_native_execution",
    "temporal_renderer_inputs_not_fabricated",
    "temporal_denoised_auxiliary_evidence_gate",
    "frame_interpolation_separate_cadence_gate",
    "typed_decoded_video_rejections",
    "baseline_records_bound_without_qualification_inference",
    "baseline_quality_performance_comparison",
    "exact_media_identity",
    "no_silent_fallback",
    "unavailable_is_not_observed",
    "no_quality_or_performance_claim",
    "production_default_disabled",
)
STOP_RULE_IDS = (
    "predecessor_identity_drift",
    "contract_byte_drift",
    "r01_fixture_drift",
    "subject_matrix_drift",
    "toolchain_boundary_violation",
    "spatial_route_violation",
    "color_bridge_violation",
    "auxiliary_input_fabrication",
    "media_identity_violation",
    "fabricated_observation",
    "authorization_boundary",
)
ROUTE_IDENTITIES = (
    ("spatial_1p5x", "A07", 1280, 720, 1920, 1080, 3, 2, "runtime_observation_required"),
    ("spatial_2x", "A07", 1920, 1080, 3840, 2160, 2, 1, "runtime_observation_required"),
    ("temporal_1p5x_contract", "A08", 1280, 720, 1920, 1080, 3, 2, "missing_renderer_inputs_rejected"),
    ("temporal_2x_contract", "A08", 1920, 1080, 3840, 2160, 2, 1, "missing_renderer_inputs_rejected"),
    ("denoised_temporal_1p5x_contract", "A09", 1280, 720, 1920, 1080, 3, 2, "missing_renderer_inputs_rejected"),
    ("denoised_temporal_2x_contract", "A09", 1920, 1080, 3840, 2160, 2, 1, "missing_renderer_inputs_rejected"),
    ("frame_interpolation_1080p_contract", "A10", 1920, 1080, 1920, 1080, 1, 1, "missing_renderer_inputs_rejected"),
)
FIXTURE_IDS = (
    "spatial-1p5x",
    "spatial-2x",
    "temporal-1p5x-contract",
    "temporal-2x-contract",
    "denoised-temporal-1p5x-contract",
    "denoised-temporal-2x-contract",
    "frame-interpolation-1080p-contract",
)
SCENARIO_IDS = (
    "spatial_routes",
    "color_bridge",
    "temporal_contract_rejections",
    "frame_interpolation_contract_rejection",
    "toolchain_and_observation_boundary",
    "closed_subject_and_authorization_matrix",
)
SOURCE_BINDINGS = {
    "r01_preregistration": ("docs/roadmaps/evidence/r01/records/preregistration.json", 7256, "8651ce7a52cd2c80a86e42480cbfbf78474e07dfea8685851138583e3760c69f"),
    "r01_fixture_catalog": ("docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json", 9656, "ae8241f5d69ce64ed143e8bbb39ab80a996f6923f1ddc83ebfbaec58d9689182"),
    "r01_scaler_720p": ("project-notes/evidence/r01/fixtures/scaler-720p.bin", 1382400, "77b432c2d459fa662d06f3086b2ac7c051a16e492da8783472917224aa96c73e"),
    "r01_scaler_1080p": ("project-notes/evidence/r01/fixtures/scaler-1080p.bin", 3110400, "44795da53184aca29cb905fa27c4362d7fec0cde1048c3cc5724f17dbb232c15"),
    "r01_temporal_frame_0": ("project-notes/evidence/r01/fixtures/temporal-frame-0.bin", 3110400, "e62159913ef91af0784820cc71edea1d5db6014fe8853ea012f20a461c359bbd"),
    "r01_temporal_frame_1": ("project-notes/evidence/r01/fixtures/temporal-frame-1.bin", 3110400, "503a754a679221dc5a2a29b4a0d3b1382b6084ab7f886cb9760356310335f168"),
    "r03_baseline_conformance": ("docs/roadmaps/evidence/r03/records/baseline-conformance.json", 57826, "9dab73f07b3b4e0d41c9f6ac0056fe7f3a36219754a55e91ef9fc74271ee67bd"),
    "r04_integration_conformance": ("docs/roadmaps/evidence/r04/records/integration-conformance.json", 4383, "49321c85a33837b10f9bbc81bf200d060731ceb7ed701197fe897dc2e3d448bf"),
}
PREREGISTRATION_SEMANTIC_SHA256 = "4c63c48834836546917fce65bb36a2072bd6fa0d58bc1de516b7f79fa2d3f066"
FIXTURE_CATALOG_SEMANTIC_SHA256 = "4610f117f4600235687f5f15ab2ca781db1fce6c1d474aa229b7ff338154b29c"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    payload = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return _sha256(payload)


def _privacy_errors(value: object, context: str) -> list[str]:
    errors: list[str] = []

    def visit(item: object, location: str) -> None:
        if isinstance(item, dict):
            for key, nested in item.items():
                key_text = str(key)
                if key_text.lower() in PRIVATE_EVIDENCE_KEYS:
                    errors.append(
                        f"{context} contains forbidden private key at {location}.{key_text}"
                    )
                visit(nested, f"{location}.{key_text}")
        elif isinstance(item, list):
            for index, nested in enumerate(item):
                visit(nested, f"{location}[{index}]")
        elif isinstance(item, str):
            if EMAIL_PATTERN.search(item):
                errors.append(f"{context} contains an email address at {location}")
            if PRIVATE_PATH_PATTERN.search(item):
                errors.append(f"{context} contains a private path at {location}")

    visit(value, "$")
    return errors


class R05ContractVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            check=False,
            text=True,
        )

    def _safe_path(
        self, value: object, context: str, errors: list[str]
    ) -> Path | None:
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

    def _check_binding(
        self,
        binding: object,
        expected_path: Path,
        context: str,
        errors: list[str],
    ) -> None:
        if not isinstance(binding, dict) or set(binding) != {
            "path",
            "size_bytes",
            "sha256",
        }:
            errors.append(f"{context} keys differ")
            return
        if binding.get("path") != expected_path.as_posix():
            errors.append(f"{context}.path differs from the frozen path")
        path = self._safe_path(binding.get("path"), context, errors)
        if path is None:
            return
        payload = path.read_bytes()
        if binding.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if binding.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    def _check_predecessor(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        if preregistration.get("predecessor_binding") != PREDECESSOR:
            errors.append(
                "R05 predecessor binding differs from the exact diagnostic-only R04 closure"
            )
            return
        commit = PREDECESSOR["closure_commit"]
        tree = PREDECESSOR["closure_tree"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R05 predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}").stdout.strip()
        if observed_tree != tree:
            errors.append("R05 predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R05 predecessor closure commit is not an ancestor of HEAD")
        closure = self.git("show", f"{commit}:{R04_CONFORMANCE_PATH.as_posix()}")
        if closure.returncode != 0:
            errors.append("R04 conformance is absent at the R05 predecessor closure")
            return
        try:
            record = decode_json(closure.stdout)
        except ValueError as error:
            errors.append(f"R04 closure conformance is invalid: {error}")
            return
        result = record.get("result") if isinstance(record, dict) else None
        expected = {
            "status": "diagnostic_only",
            "default_backend_id": None,
            "product_qualification": "not_claimed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
            "acceptance": "not_claimed",
        }
        if result != expected:
            errors.append("R04 predecessor result exceeds the diagnostic-only boundary")

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R05 preregistration semantic contract differs")
        errors.extend(_privacy_errors(value, "R05 preregistration"))
        expected_keys = {
            "schema_version",
            "roadmap_version",
            "phase_id",
            "preregistration_state",
            "predecessor_binding",
            "toolchain_boundary",
            "observation_policy",
            "fixture_catalog",
            "schema_bindings",
            "contract",
            "subjects",
            "checks",
            "stop_rules",
            "authorization_boundary",
        }
        if set(value) != expected_keys:
            errors.append("R05 preregistration top-level keys differ")
        if value.get("toolchain_boundary") != TOOLCHAIN_BOUNDARY:
            errors.append("R05 toolchain boundary differs")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R05 observation policy differs from the operator override")
        if value.get("authorization_boundary") != AUTHORIZATION_BOUNDARY:
            errors.append("R05 authorization boundary differs")
        if value.get("contract") != CONTRACT:
            errors.append("R05 MetalFX suitability contract differs")
        subjects = value.get("subjects")
        subject_values = subjects if isinstance(subjects, list) else []
        observed = [
            (
                item.get("id"),
                item.get("capability_id"),
                item.get("backend_identity"),
                item.get("route_id"),
                item.get("route_policy"),
                item.get("initial_status"),
                item.get("initial_disposition"),
                item.get("reason"),
                item.get("product_default_eligibility"),
            )
            for item in subject_values
            if isinstance(item, dict)
        ]
        if observed != list(SUBJECT_IDENTITIES):
            errors.append("R05 subject identity and route matrix differs")
        checks = value.get("checks")
        check_ids = (
            [item.get("id") for item in checks if isinstance(item, dict)]
            if isinstance(checks, list)
            else []
        )
        if check_ids != list(CHECK_IDS):
            errors.append("R05 check IDs/order differ")
        rules = value.get("stop_rules")
        rule_ids = (
            [item.get("id") for item in rules if isinstance(item, dict)]
            if isinstance(rules, list)
            else []
        )
        if rule_ids != list(STOP_RULE_IDS):
            errors.append("R05 stop-rule IDs/order differ")
        schema_paths = {
            "preregistration": PREREGISTRATION_SCHEMA_PATH,
            "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
            "conformance": CONFORMANCE_SCHEMA_PATH,
        }
        bindings = value.get("schema_bindings")
        if not isinstance(bindings, dict) or set(bindings) != set(schema_paths):
            errors.append("R05 schema binding keys differ")
        else:
            for identifier, relative in schema_paths.items():
                self._check_binding(
                    bindings.get(identifier),
                    relative,
                    f"schema_bindings.{identifier}",
                    errors,
                )
        self._check_binding(
            value.get("fixture_catalog"),
            FIXTURE_CATALOG_PATH,
            "fixture_catalog",
            errors,
        )

    def _check_fixture_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R05 fixture catalog semantic contract differs")
        errors.extend(_privacy_errors(value, "R05 fixture catalog"))
        source_values = value.get("source_bindings")
        observed_sources = source_values if isinstance(source_values, list) else []
        expected_sources = [
            {"id": identifier, "path": path, "size_bytes": size, "sha256": digest}
            for identifier, (path, size, digest) in SOURCE_BINDINGS.items()
        ]
        if observed_sources != expected_sources:
            errors.append("R05 source bindings differ from the frozen evidence bytes")
        for index, binding in enumerate(observed_sources):
            if not isinstance(binding, dict):
                errors.append(f"source_bindings[{index}] must be an object")
                continue
            identifier = binding.get("id")
            expected = SOURCE_BINDINGS.get(identifier)
            if expected is None:
                continue
            self._check_binding(
                {key: binding.get(key) for key in ("path", "size_bytes", "sha256")},
                Path(expected[0]),
                f"source_bindings[{index}]",
                errors,
            )
        routes = value.get("routes")
        route_values = routes if isinstance(routes, list) else []
        observed_routes = [
            (
                item.get("id"),
                item.get("capability_id"),
                item.get("input_dimensions", {}).get("width"),
                item.get("input_dimensions", {}).get("height"),
                item.get("output_dimensions", {}).get("width"),
                item.get("output_dimensions", {}).get("height"),
                item.get("scale_numerator"),
                item.get("scale_denominator"),
                item.get("gate"),
            )
            for item in route_values
            if isinstance(item, dict)
        ]
        if observed_routes != list(ROUTE_IDENTITIES):
            errors.append("R05 route dimensions, scale, capability, or gate differs")
        fixtures = value.get("fixtures")
        fixture_ids = (
            [item.get("id") for item in fixtures if isinstance(item, dict)]
            if isinstance(fixtures, list)
            else []
        )
        if fixture_ids != list(FIXTURE_IDS):
            errors.append("R05 fixture IDs/order differ")
        scenarios = value.get("scenarios")
        scenario_values = scenarios if isinstance(scenarios, list) else []
        scenario_ids = [
            item.get("id") for item in scenario_values if isinstance(item, dict)
        ]
        if scenario_ids != list(SCENARIO_IDS):
            errors.append("R05 scenario IDs/order differ")
        for scenario in scenario_values:
            if not isinstance(scenario, dict):
                continue
            if not set(scenario.get("subject_ids", [])) <= set(SUBJECT_IDS):
                errors.append(f"R05 scenario {scenario.get('id')} has an unknown subject")
            if not set(scenario.get("fixture_ids", [])) <= set(FIXTURE_IDS):
                errors.append(f"R05 scenario {scenario.get('id')} has an unknown fixture")
            if not set(scenario.get("required_check_ids", [])) <= set(CHECK_IDS):
                errors.append(f"R05 scenario {scenario.get('id')} has an unknown check")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R05 preregistration",
            errors,
        )
        if value is not None:
            self._check_predecessor(value, errors)
            self._check_preregistration_semantics(value, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R05 fixture catalog",
            errors,
        )
        if value is not None:
            self._check_fixture_semantics(value, errors)
        return errors

    def _check_conformance_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        expected_keys = {
            "schema_version",
            "roadmap_version",
            "phase_id",
            "evidence_kind",
            "source",
            "preregistration_binding",
            "fixture_catalog_binding",
            "observation_status",
            "subject_results",
            "checks",
            "result",
            "limitations",
        }
        if set(value) != expected_keys:
            errors.append("R05 conformance top-level keys differ")
        errors.extend(_privacy_errors(value, "R05 conformance"))
        self._check_binding(
            value.get("preregistration_binding"),
            PREREGISTRATION_PATH,
            "preregistration_binding",
            errors,
        )
        self._check_binding(
            value.get("fixture_catalog_binding"),
            FIXTURE_CATALOG_PATH,
            "fixture_catalog_binding",
            errors,
        )
        subjects = value.get("subject_results")
        ids = (
            [item.get("subject_id") for item in subjects if isinstance(item, dict)]
            if isinstance(subjects, list)
            else []
        )
        if ids != list(SUBJECT_IDS):
            errors.append("R05 conformance subject matrix differs")
        checks = value.get("checks")
        check_ids = (
            [item.get("id") for item in checks if isinstance(item, dict)]
            if isinstance(checks, list)
            else []
        )
        if check_ids != list(CHECK_IDS):
            errors.append("R05 conformance check matrix differs")
        expected_observation = {
            "hardware_capability_observation": "not_observed",
            "simulator_execution": "not_observed",
            "operator_observed_operation": "not_observed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
        }
        if value.get("observation_status") != expected_observation:
            errors.append("R05 conformance observation boundary differs")
        result = value.get("result")
        if not isinstance(result, dict) or any(
            (
                result.get("default_backend_id") is not None,
                result.get("product_qualification") != "not_claimed",
                result.get("quality_claims") != "forbidden",
                result.get("performance_claims") != "forbidden",
                result.get("acceptance") != "not_claimed",
            )
        ):
            errors.append("R05 conformance result exceeds the authorization boundary")

    def check_conformance(self) -> list[str]:
        errors: list[str] = []
        schema = self._read_json(
            CONFORMANCE_SCHEMA_PATH, "R05 conformance schema", errors
        )
        path = self.root / CONFORMANCE_PATH
        if path.is_symlink() or path.exists() and not path.is_file():
            errors.append("R05 conformance must be absent or a regular non-symlink file")
            return errors
        if not path.exists():
            return errors
        value = self._read_json(CONFORMANCE_PATH, "R05 conformance", errors)
        if value is not None and schema is not None:
            errors.extend(
                f"R05 conformance schema: {error}"
                for error in validate_json_schema_instance(schema, value)
            )
            self._check_conformance_semantics(value, errors)
        return errors


def emit_errors(errors: Iterable[str]) -> int:
    values = list(dict.fromkeys(errors))
    for error in values:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if values else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-preregistration", action="store_true")
    parser.add_argument("--check-fixtures", action="store_true")
    parser.add_argument("--check-conformance", action="store_true")
    parser.add_argument("--all", action="store_true")
    arguments = parser.parse_args(argv)
    selected = any(
        (
            arguments.check_preregistration,
            arguments.check_fixtures,
            arguments.check_conformance,
            arguments.all,
        )
    )
    if not selected:
        parser.error(
            "select --check-preregistration, --check-fixtures, --check-conformance, or --all"
        )
    verifier = R05ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if arguments.all or arguments.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if arguments.all or arguments.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if arguments.all or arguments.check_conformance:
        errors.extend(verifier.check_conformance())
    if not errors:
        if arguments.all or arguments.check_preregistration:
            print("R05 preregistration: PASS")
        if arguments.all or arguments.check_fixtures:
            print("R05 fixtures: PASS")
        if arguments.all or arguments.check_conformance:
            state = (
                "NOT MATERIALIZED (allowed by frozen preregistration)"
                if not (REPOSITORY_ROOT / CONFORMANCE_PATH).exists()
                else "PASS"
            )
            print(f"R05 conformance: {state}")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
