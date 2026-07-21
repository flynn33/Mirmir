#!/usr/bin/env python3
"""Validate the frozen R04 VideoToolbox integration start contract."""

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
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r04/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r04-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r04/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r04-fixture-catalog-v1.json"
)
CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r04/records/integration-conformance.json"
)
CONFORMANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r04-integration-conformance-v1.json"
)
R03_CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r03/records/baseline-conformance.json"
)

PREDECESSOR = {
    "phase_id": "R03",
    "closure_state": "local_unpublished_blocked_closure",
    "closure_commit": "947983a8414c60e4f5f4246e6cb658792fc7c357",
    "closure_tree": "d1a89e5b9edf8d42b1da9ba06a3b6a0c139f08f3",
    "predecessor_result": "blocked",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
}
TOOLCHAIN_BOUNDARY = {
    "platform": "macOS",
    "runtime_floor": "macOS 26.0",
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
    "session_contract": "VTFrameProcessor",
    "color_scope": "8_bit_nv12_sdr_bt709_video_range_left_chroma",
    "quality_route": "A01_2x_only",
    "quality_1p5x_disposition": "rejected_public_contract_unrepresentable",
    "low_latency_routes": "A02_1p5x_and_2x_after_exact_dimension_query_only",
    "flow_support": "A05_optional_support_only",
    "history_contract": "presentation_order_previous_source_and_previous_output",
    "reset_contract": "first_frame_scene_cut_cancellation_and_end_session",
    "submission_contract": "explicit_sequential_or_random",
    "identity_contract": "exact_dimensions_format_color_timing_audio_metadata_and_processing_identity",
    "capability_inference": "forbidden",
}
SUBJECT_IDS = (
    "r04.videotoolbox.quality-2x",
    "r04.videotoolbox.quality-1p5x-contract",
    "r04.videotoolbox.low-latency-1p5x",
    "r04.videotoolbox.low-latency-2x",
    "r04.videotoolbox.optical-flow-support",
)
SUBJECT_IDENTITIES = (
    ("r04.videotoolbox.quality-2x", "A01", "quality", "quality_2x", "runtime_observation_required", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "candidate_after_observed_qualification"),
    ("r04.videotoolbox.quality-1p5x-contract", "A01", "quality", "quality_1p5x_contract", "typed_rejection", "contract_rejected", "rejected", "public_contract_unrepresentable", "ineligible_contract_rejection"),
    ("r04.videotoolbox.low-latency-1p5x", "A02", "low_latency", "low_latency_1p5x", "exact_dimension_query_required", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "candidate_after_observed_qualification"),
    ("r04.videotoolbox.low-latency-2x", "A02", "low_latency", "low_latency_2x", "exact_dimension_query_required", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "candidate_after_observed_qualification"),
    ("r04.videotoolbox.optical-flow-support", "A05", "optional_flow_support", "optical_flow_1080p", "optional_runtime_support", "not_observed", "not_observed", "runtime_not_observed_under_operator_override", "ineligible_optional_support"),
)
CHECK_IDS = (
    "predecessor_closure_exact",
    "schema_bindings_exact",
    "r01_fixture_bindings_exact",
    "subject_matrix_complete",
    "macos26_runtime_boundary",
    "swift62_compiler_boundary",
    "simulator_unavailable_nonblocking",
    "quality_2x_only",
    "quality_1p5x_public_contract_unrepresentable",
    "low_latency_exact_dimension_query",
    "quality_low_latency_separate_identities",
    "configuration_revision_scale_priority_recorded",
    "declared_buffer_attributes_used",
    "model_readiness_lifecycle",
    "presentation_order_history",
    "first_frame_scene_cut_reset",
    "explicit_submission_mode",
    "optional_optical_flow_contract",
    "exact_media_identity",
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
    "quality_route_violation",
    "dimension_query_bypass",
    "history_or_lifecycle_violation",
    "media_identity_violation",
    "fabricated_observation",
    "authorization_boundary",
)
ROUTE_IDS = (
    "quality_2x",
    "quality_1p5x_contract",
    "low_latency_1p5x",
    "low_latency_2x",
    "optical_flow_1080p",
)
ROUTE_IDENTITIES = (
    ("quality_2x", "A01", 1920, 1080, 3840, 2160, 2, 1, "runtime_support_required"),
    ("quality_1p5x_contract", "A01", 1280, 720, 1920, 1080, 3, 2, "public_contract_unrepresentable"),
    ("low_latency_1p5x", "A02", 1280, 720, 1920, 1080, 3, 2, "exact_dimension_query_required"),
    ("low_latency_2x", "A02", 1920, 1080, 3840, 2160, 2, 1, "exact_dimension_query_required"),
    ("optical_flow_1080p", "A05", 1920, 1080, 1920, 1080, 1, 1, "optional_runtime_support"),
)
FIXTURE_IDS = (
    "quality-2x-single",
    "quality-1p5x-contract",
    "low-latency-1p5x",
    "low-latency-2x",
    "quality-2x-history",
    "optical-flow-pair",
)
FIXTURE_MEMBERS = {
    "quality-2x-single": ["scaler-1080p"],
    "quality-1p5x-contract": ["scaler-720p"],
    "low-latency-1p5x": ["scaler-720p"],
    "low-latency-2x": ["scaler-1080p"],
    "quality-2x-history": ["temporal-frame-0", "temporal-frame-1"],
    "optical-flow-pair": ["temporal-frame-0", "temporal-frame-1"],
}
SCENARIO_IDS = (
    "quality_2x_session",
    "quality_1p5x_typed_rejection",
    "low_latency_dimension_queries",
    "optional_flow_support",
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
}
PREREGISTRATION_SEMANTIC_SHA256 = "7a804c718010b7d2764ced62c400b505ad217bbaec821f080e811dd2019dd0fc"
FIXTURE_CATALOG_SEMANTIC_SHA256 = "4025538c3ca61d087d8ef3a03019c2f8f3c4bcc1178acdff4af54128ccba2196"


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


class R04ContractVerifier:
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

    def _check_predecessor(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        if preregistration.get("predecessor_binding") != PREDECESSOR:
            errors.append("R04 predecessor binding differs from the exact blocked R03 closure")
            return
        commit = PREDECESSOR["closure_commit"]
        tree = PREDECESSOR["closure_tree"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R04 predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}").stdout.strip()
        if observed_tree != tree:
            errors.append("R04 predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R04 predecessor closure commit is not an ancestor of HEAD")
        closure = self.git("show", f"{commit}:{R03_CONFORMANCE_PATH.as_posix()}")
        if closure.returncode != 0:
            errors.append("R03 conformance is absent at the R04 predecessor closure")
            return
        try:
            record = decode_json(closure.stdout)
        except ValueError as error:
            errors.append(f"R03 closure conformance is invalid: {error}")
            return
        result = record.get("result") if isinstance(record, dict) else None
        if not isinstance(result, dict) or result.get("status") != "blocked":
            errors.append("R03 predecessor result must remain blocked")
        if not isinstance(result, dict) or result.get("product_qualification") != "not_claimed":
            errors.append("R03 predecessor product qualification must remain not claimed")
        if not isinstance(result, dict) or result.get("performance_claims") != "forbidden":
            errors.append("R03 predecessor performance boundary differs")

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R04 preregistration semantic contract differs")
        errors.extend(_privacy_errors(value, "R04 preregistration"))
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
            errors.append("R04 preregistration top-level keys differ")
        if value.get("toolchain_boundary") != TOOLCHAIN_BOUNDARY:
            errors.append("R04 macOS 26 / Swift 6.2 / simulator boundary differs")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R04 observation policy differs from the operator override")
        if value.get("authorization_boundary") != AUTHORIZATION_BOUNDARY:
            errors.append("R04 authorization boundary differs")
        if value.get("contract") != CONTRACT:
            errors.append("R04 VideoToolbox route contract differs")
        subjects = value.get("subjects")
        subject_values = subjects if isinstance(subjects, list) else []
        observed = [
            (
                item.get("id"), item.get("capability_id"), item.get("backend_identity"),
                item.get("route_id"), item.get("route_policy"), item.get("initial_status"),
                item.get("initial_disposition"), item.get("reason"),
                item.get("product_default_eligibility"),
            )
            for item in subject_values if isinstance(item, dict)
        ]
        if observed != list(SUBJECT_IDENTITIES):
            errors.append("R04 subject identity and route matrix differs")
        checks = value.get("checks")
        check_ids = [item.get("id") for item in checks if isinstance(item, dict)] if isinstance(checks, list) else []
        if check_ids != list(CHECK_IDS):
            errors.append("R04 check IDs/order differ")
        rules = value.get("stop_rules")
        rule_ids = [item.get("id") for item in rules if isinstance(item, dict)] if isinstance(rules, list) else []
        if rule_ids != list(STOP_RULE_IDS):
            errors.append("R04 stop-rule IDs/order differ")
        schema_paths = {
            "preregistration": PREREGISTRATION_SCHEMA_PATH,
            "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
            "conformance": CONFORMANCE_SCHEMA_PATH,
        }
        bindings = value.get("schema_bindings")
        if not isinstance(bindings, dict) or set(bindings) != set(schema_paths):
            errors.append("R04 schema binding keys differ")
        else:
            for identifier, relative in schema_paths.items():
                binding = bindings.get(identifier)
                self._check_binding(binding, f"schema_bindings.{identifier}", errors)
                if isinstance(binding, dict) and binding.get("path") != relative.as_posix():
                    errors.append(f"schema_bindings.{identifier}.path differs")
        catalog_binding = value.get("fixture_catalog")
        self._check_binding(catalog_binding, "fixture_catalog", errors)
        if isinstance(catalog_binding, dict) and catalog_binding.get("path") != FIXTURE_CATALOG_PATH.as_posix():
            errors.append("fixture_catalog.path differs")

    def _check_fixture_semantics(
        self, catalog: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(catalog) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R04 fixture catalog semantic contract differs")
        errors.extend(_privacy_errors(catalog, "R04 fixture catalog"))
        bindings = catalog.get("source_bindings")
        binding_values = bindings if isinstance(bindings, list) else []
        expected_bindings = [
            {"id": identifier, "path": path, "size_bytes": size, "sha256": digest}
            for identifier, (path, size, digest) in SOURCE_BINDINGS.items()
        ]
        if binding_values != expected_bindings:
            errors.append("R04 source bindings differ from exact frozen R01 bytes")
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
        observed_routes = [
            (
                item.get("id"), item.get("capability_id"),
                item.get("input_dimensions", {}).get("width"),
                item.get("input_dimensions", {}).get("height"),
                item.get("output_dimensions", {}).get("width"),
                item.get("output_dimensions", {}).get("height"),
                item.get("scale_numerator"), item.get("scale_denominator"), item.get("gate"),
            )
            for item in route_values if isinstance(item, dict)
        ]
        if observed_routes != list(ROUTE_IDENTITIES):
            errors.append("R04 route dimensions, scale, capability, or gate differs")
        fixtures = catalog.get("fixtures")
        fixture_values = fixtures if isinstance(fixtures, list) else []
        fixture_ids = [item.get("id") for item in fixture_values if isinstance(item, dict)]
        if fixture_ids != list(FIXTURE_IDS):
            errors.append("R04 fixture IDs/order differ")
        members = {item.get("id"): item.get("member_ids") for item in fixture_values if isinstance(item, dict)}
        if members != FIXTURE_MEMBERS:
            errors.append("R04 fixture member bindings differ")
        scenarios = catalog.get("scenarios")
        scenario_values = scenarios if isinstance(scenarios, list) else []
        scenario_ids = [item.get("id") for item in scenario_values if isinstance(item, dict)]
        if scenario_ids != list(SCENARIO_IDS):
            errors.append("R04 scenario IDs/order differ")
        for scenario in scenario_values:
            if not isinstance(scenario, dict):
                continue
            if not set(scenario.get("subject_ids", [])) <= set(SUBJECT_IDS):
                errors.append(f"R04 scenario {scenario.get('id')} has an unknown subject")
            if not set(scenario.get("fixture_ids", [])) <= set(FIXTURE_IDS):
                errors.append(f"R04 scenario {scenario.get('id')} has an unknown fixture")
            if not set(scenario.get("required_check_ids", [])) <= set(CHECK_IDS):
                errors.append(f"R04 scenario {scenario.get('id')} has an unknown check")
        self._check_r01_identities(errors)

    def _check_r01_identities(self, errors: list[str]) -> None:
        prereg = self._read_json(
            Path(SOURCE_BINDINGS["r01_preregistration"][0]),
            "R01 preregistration",
            errors,
        )
        if prereg is not None:
            capabilities = prereg.get("capabilities")
            observed = {
                item.get("id"): (item.get("family"), item.get("method"), item.get("probe_class"))
                for item in capabilities if isinstance(item, dict)
            } if isinstance(capabilities, list) else {}
            expected = {
                "A01": ("VideoToolbox", "VTSuperResolutionScaler", "primary_scaler"),
                "A02": ("VideoToolbox", "VTLowLatencySuperResolutionScaler", "primary_scaler"),
                "A05": ("VideoToolbox", "VTOpticalFlow", "temporal_analyzer"),
            }
            if any(observed.get(identifier) != identity for identifier, identity in expected.items()):
                errors.append("R04 A01/A02/A05 identities differ from bound R01 preregistration")
        catalog = self._read_json(
            Path(SOURCE_BINDINGS["r01_fixture_catalog"][0]),
            "R01 fixture catalog",
            errors,
        )
        if catalog is None:
            return
        fixtures = catalog.get("fixtures")
        by_id = {item.get("id"): item for item in fixtures if isinstance(item, dict)} if isinstance(fixtures, list) else {}
        expected = {
            "scaler-720p": (1280, 720, 1920, 1080, "r01_scaler_720p"),
            "scaler-1080p": (1920, 1080, 3840, 2160, "r01_scaler_1080p"),
            "temporal-frame-0": (1920, 1080, None, None, "r01_temporal_frame_0"),
            "temporal-frame-1": (1920, 1080, None, None, "r01_temporal_frame_1"),
        }
        for fixture_id, (width, height, out_width, out_height, binding_id) in expected.items():
            item = by_id.get(fixture_id)
            if not isinstance(item, dict):
                errors.append(f"R04 bound R01 fixture is absent: {fixture_id}")
                continue
            dimensions = item.get("dimensions")
            output = item.get("scale_output")
            binding = SOURCE_BINDINGS[binding_id]
            if dimensions != {"width": width, "height": height}:
                errors.append(f"R04 bound R01 fixture dimensions differ: {fixture_id}")
            expected_output = None if out_width is None else {"width": out_width, "height": out_height}
            if output != expected_output:
                errors.append(f"R04 bound R01 fixture output differs: {fixture_id}")
            if item.get("materialization_path") != binding[0] or item.get("byte_count") != binding[1] or item.get("content_sha256") != binding[2]:
                errors.append(f"R04 bound R01 fixture byte identity differs: {fixture_id}")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R04 preregistration",
            errors,
        )
        if value is not None:
            self._check_predecessor(value, errors)
            self._check_preregistration_semantics(value, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        catalog = self._read_and_validate(
            FIXTURE_CATALOG_PATH,
            FIXTURE_CATALOG_SCHEMA_PATH,
            "R04 fixture catalog",
            errors,
        )
        if catalog is not None:
            self._check_fixture_semantics(catalog, errors)
        return errors

    def _check_conformance_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        expected_keys = {
            "schema_version", "roadmap_version", "phase_id", "evidence_kind",
            "source", "preregistration_binding", "fixture_catalog_binding",
            "observation_status", "subject_results", "checks", "result", "limitations",
        }
        if set(value) != expected_keys:
            errors.append("R04 conformance top-level keys differ")
        self._check_binding(value.get("preregistration_binding"), "preregistration_binding", errors)
        self._check_binding(value.get("fixture_catalog_binding"), "fixture_catalog_binding", errors)
        subject_results = value.get("subject_results")
        subject_values = subject_results if isinstance(subject_results, list) else []
        ids = [item.get("subject_id") for item in subject_values if isinstance(item, dict)]
        if ids != list(SUBJECT_IDS):
            errors.append("R04 conformance subject matrix differs")
        for item in subject_values:
            if not isinstance(item, dict):
                continue
            subject_id = item.get("subject_id")
            status = item.get("execution_status")
            disposition = item.get("disposition")
            reason = item.get("reason")
            if subject_id == "r04.videotoolbox.quality-1p5x-contract":
                if (status, disposition, reason) != ("contract_rejected", "rejected", "public_contract_unrepresentable"):
                    errors.append("R04 quality 1.5x requires the typed public_contract_unrepresentable rejection")
            elif status == "not_observed":
                if (disposition, reason) != ("not_observed", "runtime_not_observed_under_operator_override"):
                    errors.append(f"R04 not-observed subject carries an observed claim: {subject_id}")
            elif status == "observed":
                allowed = {
                    ("restricted", "observed_contract_only_no_quality_or_performance_claim"),
                    ("diagnostic_only", "optional_support_observed_no_product_claim"),
                    ("rejected", "exact_dimension_query_rejected_route"),
                }
                if (disposition, reason) not in allowed:
                    errors.append(f"R04 observed subject exceeds the contract-only boundary: {subject_id}")
            else:
                errors.append(f"R04 subject execution status differs: {subject_id}")
            if subject_id == "r04.videotoolbox.optical-flow-support" and status == "observed" and disposition != "diagnostic_only":
                errors.append("R04 optional A05 support cannot become a primary disposition")
        checks = value.get("checks")
        check_ids = [item.get("id") for item in checks if isinstance(item, dict)] if isinstance(checks, list) else []
        if check_ids != list(CHECK_IDS):
            errors.append("R04 conformance check matrix differs")
        expected_observation = {
            "hardware_capability_observation": "not_observed",
            "simulator_execution": "not_observed",
            "operator_observed_operation": "not_observed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
        }
        if value.get("observation_status") != expected_observation:
            errors.append("R04 conformance observation boundary differs")
        result = value.get("result")
        if not isinstance(result, dict) or result != {
            "status": result.get("status") if isinstance(result, dict) else None,
            "default_backend_id": None,
            "product_qualification": "not_claimed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
            "acceptance": "not_claimed",
        }:
            errors.append("R04 conformance result exceeds the authorization boundary")

    def check_conformance(self) -> list[str]:
        errors: list[str] = []
        schema = self._read_json(
            CONFORMANCE_SCHEMA_PATH, "R04 conformance schema", errors
        )
        path = self.root / CONFORMANCE_PATH
        if path.is_symlink() or path.exists() and not path.is_file():
            errors.append("R04 conformance must be absent or a regular non-symlink file")
            return errors
        if not path.exists():
            return errors
        value = self._read_json(CONFORMANCE_PATH, "R04 conformance", errors)
        if value is not None and schema is not None:
            errors.extend(
                f"R04 conformance schema: {error}"
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
    check_preregistration = arguments.all or arguments.check_preregistration
    check_fixtures = arguments.all or arguments.check_fixtures
    check_conformance = arguments.all or arguments.check_conformance
    verifier = R04ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if check_preregistration:
        errors.extend(verifier.check_preregistration())
    if check_fixtures:
        errors.extend(verifier.check_fixtures())
    if check_conformance:
        errors.extend(verifier.check_conformance())
    if not errors:
        if check_preregistration:
            print("R04 preregistration: PASS")
        if check_fixtures:
            print("R04 fixtures: PASS")
        if check_conformance:
            state = "NOT MATERIALIZED (allowed by frozen preregistration)" if not (REPOSITORY_ROOT / CONFORMANCE_PATH).exists() else "PASS"
            print(f"R04 conformance: {state}")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
