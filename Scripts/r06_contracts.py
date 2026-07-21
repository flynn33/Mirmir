#!/usr/bin/env python3
"""Validate the frozen R06 ASH orchestration contracts and closure evidence."""

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
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r06/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r06-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r06/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r06-fixture-catalog-v1.json"
)
CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r06/records/orchestration-conformance.json"
)
CONFORMANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r06-orchestration-conformance-v1.json"
)
R05_CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r05/records/suitability-conformance.json"
)

PREREGISTRATION_COMMIT = "3f0e5558123f582e7a3c6db085c1e58996ff253d"
IMPLEMENTATION_SOURCE = {
    "commit": "9246934c027e97f2b2ae3af35b0c4892154d761c",
    "tree": "1235596387d4eabd2ecb4ea1a29221c44ec425fe",
}

PREDECESSOR = {
    "phase_id": "R05",
    "closure_state": "local_unpublished_diagnostic_only_closure",
    "closure_commit": "b955fc9d0b02dd066c359dfcb99a9ad31aeb817a",
    "closure_tree": "10a97bd3df7f72834f7afcb7fa3b63c598fa4931",
    "predecessor_result": "diagnostic_only",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
}
OBSERVATION_POLICY = {
    "hardware_requirement": "waived_not_a_blocker",
    "simulator_requirement": "waived_not_a_blocker",
    "operator_observation_requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "deterministic_software_conformance": "required",
    "product_ablation_execution": (
        "not_observed_without_product_qualified_primary_backend"
    ),
    "product_gate_cause": "no_product_qualified_primary_backend",
    "hardware_or_simulator_as_blocked_cause": "forbidden",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
}
PRODUCT_GATE = {
    "eligibility_source": "R03_R04_R05_product_qualification_records",
    "qualification_requirement": "explicit_product_qualified_primary_backend",
    "prefilter_order": "before_scoring_routing_plan_construction_and_output",
    "reason": "no_product_qualified_primary_backend",
    "eligible_backend_count": 0,
    "selected_route_id": None,
    "selected_plan_id": None,
    "output_identity": None,
    "disposition": "blocked",
}
AUTHORIZATION_BOUNDARY = {
    "production_default": "not_enabled",
    "product_qualification": "not_claimed",
    "result": "blocked",
    "result_reason": "no_product_qualified_primary_backend",
    "eligible_backend_count": "0",
    "selected_route_id": None,
    "selected_plan_id": None,
    "output_identity": None,
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
    "auto_mode": "blocked",
    "holdout": "blocked",
    "acceptance": "not_claimed",
    "publication": "not_authorized_by_this_record",
    "release": "not_authorized",
    "fixture_execution": "local_deterministic_software_only",
}
PREREGISTRATION_TOP_LEVEL_KEYS = (
    "schema_version",
    "roadmap_version",
    "phase_id",
    "preregistration_state",
    "predecessor_binding",
    "observation_policy",
    "fixture_catalog",
    "schema_bindings",
    "orchestration_contract",
    "ash_state_contract",
    "message_policy_contract",
    "scoring_contract",
    "transition_contract",
    "mask_contract",
    "product_gate",
    "ablations",
    "checks",
    "stop_rules",
    "authorization_boundary",
)
SIDECAR_FIELDS = (
    "frame_id",
    "shot_id",
    "route_id",
    "scale_numerator",
    "scale_denominator",
    "plane_layout",
    "chroma_siting",
    "continuous_feature_values_q16",
    "current_state",
    "previous_state",
    "state_transition",
    "dwell_frames",
    "scene_cut_confidence_q16",
    "motion_confidence_q16",
    "occlusion_confidence_q16",
    "noise_estimate_q16",
    "blur_estimate_q16",
    "compression_estimate_q16",
    "aliasing_estimate_q16",
    "face_occupancy_q15",
    "text_occupancy_q15",
    "line_art_occupancy_q15",
    "animation_occupancy_q15",
    "ui_occupancy_q15",
    "backend_availability",
    "model_readiness",
    "backend_quality_confidence_q16",
    "memory_pressure_q16",
    "thermal_pressure_q16",
    "throughput_pressure_q16",
    "current_backend_id",
    "previous_backend_id",
    "preprocess_strength_q16",
    "postprocess_strength_q16",
    "artifact_risk_q16",
    "postflight_findings",
    "fallback_reason",
    "retry_eligibility",
)
MESSAGE_AXES = {
    "denoise": {"bit_index": 0, "zero_policy": "off", "one_policy": "low"},
    "primary_backend_preference": {
        "bit_index": 1,
        "zero_policy": "spatial",
        "one_policy": "temporal",
    },
    "postprocess": {
        "bit_index": 2,
        "zero_policy": "conservative",
        "one_policy": "detail_oriented",
    },
    "temporal_history": {
        "bit_index": 3,
        "zero_policy": "retain",
        "one_policy": "reset",
    },
}
SCORING_CONTRACT = {
    "arithmetic": "signed_integer_fixed_point",
    "storage": "Int64",
    "scale": 65536,
    "rounding": "toward_zero",
    "overflow_policy": "fail_closed",
    "formula": (
        "quality_confidence_q16*4+message_alignment_q16*2-"
        "artifact_risk_q16*3-transition_cost_q16*2-"
        "resource_cost_q16*1-postflight_penalty_q16*2"
    ),
    "component_order": [
        "quality_confidence_q16",
        "message_alignment_q16",
        "artifact_risk_q16",
        "transition_cost_q16",
        "resource_cost_q16",
        "postflight_penalty_q16",
    ],
    "weights_source": "constructor_bound_fixture_catalog",
    "thresholds_source": "constructor_bound_fixture_catalog",
    "tie_break": "lexical_route_id_ascending",
    "candidate_input_order": "must_not_affect_selection_or_records",
}
TRANSITION_REASON_IDS = (
    "initial_selection",
    "score_winner_selected",
    "hysteresis_hold",
    "minimum_dwell_hold",
    "scene_cut_reset",
    "fatal_backend_failover",
    "no_product_qualified_primary_backend",
)
ABLATION_IDENTITIES = (
    ("best_fixed_eligible_apple_backend", "best fixed eligible Apple backend"),
    (
        "simple_continuous_router_without_ash",
        "simple continuous router without ASH",
    ),
    ("ash_state_only_router", "ASH state-only router"),
    ("ash_plus_continuous_sidecar", "ASH plus continuous sidecar"),
    ("ash_without_hysteresis", "ASH without hysteresis"),
    ("ash_without_postflight_feedback", "ASH without postflight feedback"),
)
ABLATION_IDS = tuple(identifier for identifier, _ in ABLATION_IDENTITIES)
CHECK_IDS = (
    "predecessor_closure_exact",
    "frozen_bindings_exact",
    "canonical_nine_bit_state_unchanged",
    "decision_context_immutable_and_versioned",
    "sixteen_message_profiles_complete",
    "one_bit_one_policy_axis_causality",
    "integer_fixed_point_scoring_exact",
    "constructor_parameters_bound",
    "product_eligibility_prefilter_first",
    "candidate_order_invariance",
    "lexical_route_tie_break",
    "one_whole_frame_route",
    "hysteresis_exact",
    "minimum_dwell_exact",
    "scene_cut_reset_exact",
    "fatal_failover_exact",
    "bounded_masks_exact",
    "ablation_matrix_complete",
    "product_gate_closed",
    "product_ablations_not_observed",
    "observation_override_nonblocking",
    "no_quality_or_performance_claim",
    "no_silent_fallback",
    "production_default_disabled",
)
STOP_RULE_IDS = (
    "predecessor_identity_drift",
    "contract_byte_drift",
    "canonical_state_redefinition",
    "message_policy_causality_violation",
    "floating_or_unbound_scoring",
    "eligibility_order_violation",
    "candidate_order_dependence",
    "multi_route_violation",
    "transition_contract_violation",
    "mask_bounds_violation",
    "ablation_identity_drift",
    "fabricated_observation",
    "authorization_boundary",
)
SOURCE_BINDINGS = {
    "r05_preregistration": (
        "docs/roadmaps/evidence/r05/records/preregistration.json",
        11723,
        "57afe310076c971669fb163298d1c4dba4ae9d19a48c745109d735b889444706",
    ),
    "r05_fixture_catalog": (
        "docs/roadmaps/evidence/r05/records/fixtures/fixture-catalog.json",
        8088,
        "3145262a6daa85eefb106f1c866d9a28b9b6838a6c611086576e7140fbc64302",
    ),
    "r05_suitability_conformance": (
        "docs/roadmaps/evidence/r05/records/suitability-conformance.json",
        4949,
        "b4ff4b54f59c8798991dcf5afdcdcc69f771cba5ec105af3b75d2efb0afed8d2",
    ),
    "canonical_ash_state": (
        "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift",
        6556,
        "c96f0ef0a1e087cc3c7ac0bf821caa88d72a7e959deabae3749a6f1ad5ebdee2",
    ),
    "canonical_ash_code": (
        "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift",
        3389,
        "b0e97c0016ee73979138e5fe5fe585a359044969e5a5df63c7561c09abe58ddc",
    ),
}
CONSTRUCTOR_PARAMETERS = {
    "version": "r06.parameters.v1",
    "fixed_point_scale": 65536,
    "weights": {
        "quality_confidence": 4,
        "message_alignment": 2,
        "artifact_risk_penalty": 3,
        "transition_cost_penalty": 2,
        "resource_cost_penalty": 1,
        "postflight_penalty": 2,
    },
    "thresholds": {
        "hysteresis_margin_q16": 8192,
        "minimum_dwell_frames": 12,
        "scene_cut_confidence_q16": 49152,
        "mask_minimum_q15": 0,
        "mask_maximum_q15": 32767,
        "mask_maximum_width": 64,
        "mask_maximum_height": 64,
    },
    "fatal_backend_error_bypasses_hysteresis_and_dwell": True,
}
BACKEND_IDENTITIES = (
    (
        "fixture.apple.metalfx_spatial",
        "fixture.route.metalfx_spatial",
        True,
        False,
        True,
    ),
    (
        "fixture.apple.mps_lanczos",
        "fixture.route.mps_lanczos",
        True,
        False,
        True,
    ),
    (
        "fixture.apple.videotoolbox_low_latency",
        "fixture.route.videotoolbox_low_latency",
        True,
        False,
        True,
    ),
)
CONTEXT_IDS = (
    "initial",
    "steady_state",
    "minimum_dwell",
    "scene_cut",
    "fatal_failure",
    "postflight_risk",
)
MASK_IDS = ("luma_protection", "chroma_protection", "postprocess_suppression")
TRANSITION_IDENTITIES = (
    (
        "initial_lexical_tie",
        "initial",
        "fixture.route.metalfx_spatial",
        "initial_selection",
    ),
    (
        "hysteresis_retains_current",
        "steady_state",
        "fixture.route.mps_lanczos",
        "hysteresis_hold",
    ),
    (
        "minimum_dwell_retains_current",
        "minimum_dwell",
        "fixture.route.mps_lanczos",
        "minimum_dwell_hold",
    ),
    (
        "scene_cut_bypasses_transition_holds",
        "scene_cut",
        "fixture.route.metalfx_spatial",
        "scene_cut_reset",
    ),
    (
        "fatal_failure_bypasses_transition_holds",
        "fatal_failure",
        "fixture.route.metalfx_spatial",
        "fatal_backend_failover",
    ),
)
PREREGISTRATION_SEMANTIC_SHA256 = (
    "6dbd7131a79bdca33916754cfd099979653e4fd6ee48e36e13b662a552d277d6"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "b3d4b93ad52c63597bb326767b3543db4db9d8ef8905f95ec6747ea053574ca3"
)
AGGREGATE_PROJECT_PATH = Path("Mirmir.xcodeproj/project.pbxproj")
SOURCE_CONTRACT_PATHS = (
    PREREGISTRATION_PATH,
    FIXTURE_CATALOG_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    CONFORMANCE_SCHEMA_PATH,
    AGGREGATE_PROJECT_PATH,
    Path("Mirmir/Modules/UpscalerEngine/R06ASHDecisionContext.swift"),
    Path("Mirmir/Modules/UpscalerEngine/R06ASHMasksAndAblations.swift"),
    Path("Mirmir/Modules/UpscalerEngine/R06ASHOrchestrator.swift"),
    Path("Mirmir/Modules/UpscalerEngine/R06ASHPolicyCatalog.swift"),
    Path("MirmirTests/UpscalerEngine/R06ASHDecisionContextTests.swift"),
    Path("MirmirTests/UpscalerEngine/R06ASHMasksAndAblationsTests.swift"),
    Path("MirmirTests/UpscalerEngine/R06ASHOrchestratorTests.swift"),
    Path("MirmirTests/UpscalerEngine/R06ASHPolicyCatalogTests.swift"),
)
CURRENT_BYTE_SOURCE_CONTRACT_PATHS = frozenset(SOURCE_CONTRACT_PATHS) - {
    AGGREGATE_PROJECT_PATH
}
FIXTURE_CHECK_IDS = (
    "decision_context_invariants",
    "sixteen_message_policy_profiles",
    "checked_integer_fixed_point_scoring",
    "candidate_order_and_lexical_tie_break",
    "whole_frame_transition_controls",
    "bounded_protection_masks",
    "six_ablation_fixture_matrix",
    "product_eligibility_prefilter",
)
CONFORMANCE_OBSERVATION = {
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "product_ablation_execution": "not_observed",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
}
CONFORMANCE_PRODUCT_GATE_RESULT = {
    "reason": "no_product_qualified_primary_backend",
    "eligible_backend_count": 0,
    "selected_route_id": None,
    "selected_plan_id": None,
    "output_identity": None,
    "disposition": "blocked",
}
CONFORMANCE_RESULT = {
    "status": "blocked",
    "reason": "no_product_qualified_primary_backend",
    "default_backend_id": None,
    "selected_route_id": None,
    "selected_plan_id": None,
    "output_identity": None,
    "product_qualification": "not_claimed",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
    "acceptance": "not_claimed",
}
CONFORMANCE_LIMITATIONS = (
    "Focused deterministic R06 software conformance passed; fixture execution "
    "does not establish product qualification, quality, or performance.",
    "No R03-R05 backend has an explicit product-qualification record, so product "
    "routing, plan construction, output, and every product ablation remain not "
    "observed.",
    "Hardware capability, simulator execution, and operator-observed operation "
    "were not observed under the operator override and are not the blocked cause.",
    "R06 remains disabled as the production default and makes no product "
    "qualification, quality, performance, acceptance, publication, or release "
    "claim.",
)


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
                        f"{context} contains forbidden private key at "
                        f"{location}.{key_text}"
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


def expected_policy_profiles() -> list[dict[str, object]]:
    profiles: list[dict[str, object]] = []
    axes = tuple(MESSAGE_AXES)
    for raw_value in range(16):
        bits = [(raw_value >> (3 - index)) & 1 for index in range(4)]
        profile: dict[str, object] = {
            "id": f"policy.message.{raw_value:02d}",
            "raw_value": raw_value,
            "bits": bits,
        }
        for axis in axes:
            mapping = MESSAGE_AXES[axis]
            bit = bits[int(mapping["bit_index"])]
            profile[axis] = mapping["one_policy" if bit else "zero_policy"]
        profiles.append(profile)
    return profiles


class R06ContractVerifier:
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

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            check=False,
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

    def _check_source(
        self, source: object, context: str, errors: list[str]
    ) -> None:
        if not isinstance(source, dict) or set(source) != {"commit", "tree"}:
            errors.append(f"{context} must contain only commit and tree")
            return
        commit = source.get("commit")
        tree = source.get("tree")
        if not isinstance(commit, str) or not isinstance(tree, str):
            errors.append(f"{context} commit and tree must be strings")
            return
        if source != IMPLEMENTATION_SOURCE:
            errors.append(f"{context} differs from the frozen R06 implementation source")
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append(f"{context} commit is unavailable")
            return
        if commit == PREREGISTRATION_COMMIT or self.git(
            "merge-base", "--is-ancestor", PREREGISTRATION_COMMIT, commit
        ).returncode != 0:
            errors.append(
                f"{context} must be a strict descendant of the R06 preregistration"
            )
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != tree:
            errors.append(f"{context} tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append(f"{context} commit must be an ancestor of HEAD")
        for relative in SOURCE_CONTRACT_PATHS:
            historical = self.git_bytes("show", f"{commit}:{relative.as_posix()}")
            current = self.root / relative
            if historical.returncode != 0 or current.is_symlink() or not current.is_file():
                errors.append(
                    f"{context} does not contain the frozen R06 implementation bytes: "
                    f"{relative.as_posix()}"
                )
            elif (
                relative in CURRENT_BYTE_SOURCE_CONTRACT_PATHS
                and historical.stdout != current.read_bytes()
            ):
                errors.append(
                    f"{context} does not contain the frozen R06 implementation bytes: "
                    f"{relative.as_posix()}"
                )

        project = self.root / AGGREGATE_PROJECT_PATH
        if not project.is_symlink() and project.is_file():
            project_payload = project.read_bytes()
            for relative in SOURCE_CONTRACT_PATHS:
                if relative.suffix == ".swift" and relative.name.encode() not in project_payload:
                    errors.append(
                        f"{context} current project omits the frozen R06 source reference: "
                        f"{relative.name}"
                    )

    def _check_predecessor(
        self, preregistration: dict[str, Any], errors: list[str]
    ) -> None:
        if preregistration.get("predecessor_binding") != PREDECESSOR:
            errors.append(
                "R06 predecessor binding differs from the exact diagnostic-only "
                "R05 closure"
            )
            return
        commit = PREDECESSOR["closure_commit"]
        tree = PREDECESSOR["closure_tree"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R06 predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}").stdout.strip()
        if observed_tree != tree:
            errors.append("R06 predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R06 predecessor closure commit is not an ancestor of HEAD")
        closure = self.git("show", f"{commit}:{R05_CONFORMANCE_PATH.as_posix()}")
        if closure.returncode != 0:
            errors.append("R05 conformance is absent at the R06 predecessor closure")
            return
        try:
            record = decode_json(closure.stdout)
        except ValueError as error:
            errors.append(f"R05 closure conformance is invalid: {error}")
            return
        result = record.get("result") if isinstance(record, dict) else None
        expected = {
            "status": "diagnostic_only",
            "disposition": "diagnostic_only",
            "default_backend_id": None,
            "product_qualification": "not_claimed",
            "quality_claims": "forbidden",
            "performance_claims": "forbidden",
            "acceptance": "not_claimed",
        }
        if result != expected:
            errors.append("R05 predecessor result exceeds the diagnostic-only boundary")

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R06 preregistration semantic contract differs")
        errors.extend(_privacy_errors(value, "R06 preregistration"))
        if tuple(value) != PREREGISTRATION_TOP_LEVEL_KEYS:
            errors.append("R06 preregistration top-level keys/order differ")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R06 observation policy differs from the operator override")
        if value.get("product_gate") != PRODUCT_GATE:
            errors.append("R06 product eligibility gate differs")
        if value.get("authorization_boundary") != AUTHORIZATION_BOUNDARY:
            errors.append("R06 authorization boundary differs")

        state = value.get("ash_state_contract")
        if not isinstance(state, dict):
            errors.append("R06 ASH state contract must be an object")
        else:
            expected_core = {
                "packed_state_type": "ASHState",
                "packed_bit_count": 9,
                "payload_bit_count": 8,
                "integrity_coordinate": 9,
                "integrity_relation": (
                    "coordinate_9_equals_xor_of_payload_coordinates_1_through_8"
                ),
                "mutation_policy": "canonical_packed_state_must_not_be_redefined",
                "sidecar_type": "ASHDecisionContext",
                "sidecar_version": "r06.v1",
                "sidecar_mutability": "immutable_value",
            }
            if any(state.get(key) != item for key, item in expected_core.items()):
                errors.append("R06 canonical ASH state/sidecar core differs")
            if state.get("sidecar_fields") != list(SIDECAR_FIELDS):
                errors.append("R06 ASHDecisionContext field set/order differs")

        message = value.get("message_policy_contract")
        if not isinstance(message, dict):
            errors.append("R06 message policy contract must be an object")
        else:
            if message.get("message_bit_count") != 4:
                errors.append("R06 ASHMessage bit count differs")
            if message.get("profile_count") != 16:
                errors.append("R06 ASHMessage profile count differs")
            if message.get("bit_axes") != MESSAGE_AXES:
                errors.append("R06 one-bit-to-one-policy-axis mapping differs")
            if message.get("single_bit_causality") != (
                "exactly_one_mapped_policy_axis_changes"
            ):
                errors.append("R06 ASHMessage causality rule differs")

        if value.get("scoring_contract") != SCORING_CONTRACT:
            errors.append("R06 integer fixed-point scoring contract differs")
        transition = value.get("transition_contract")
        if not isinstance(transition, dict) or transition.get("reason_ids") != list(
            TRANSITION_REASON_IDS
        ):
            errors.append("R06 transition reason IDs/order differ")
        mask = value.get("mask_contract")
        expected_mask = {
            "mask_ids": list(MASK_IDS),
            "sample_storage": "UInt16_q0_15",
            "minimum_sample": 0,
            "maximum_sample": 32767,
            "maximum_width": 64,
            "maximum_height": 64,
            "dimension_policy": (
                "positive_dimensions_sample_count_equals_width_times_height"
            ),
            "out_of_range_policy": "reject_never_clamp",
        }
        if mask != expected_mask:
            errors.append("R06 bounded mask contract differs")

        ablations = value.get("ablations")
        ablation_values = ablations if isinstance(ablations, list) else []
        observed_ablations = [
            (
                item.get("id"),
                item.get("roadmap_label"),
                item.get("product_execution_status"),
                item.get("fixture_contract_status"),
            )
            for item in ablation_values
            if isinstance(item, dict)
        ]
        expected_ablations = [
            (identifier, label, "not_observed", "preregistered")
            for identifier, label in ABLATION_IDENTITIES
        ]
        if observed_ablations != expected_ablations:
            errors.append("R06 ablation identity/status matrix differs")

        checks = value.get("checks")
        check_ids = (
            [item.get("id") for item in checks if isinstance(item, dict)]
            if isinstance(checks, list)
            else []
        )
        if check_ids != list(CHECK_IDS):
            errors.append("R06 check IDs/order differ")
        rules = value.get("stop_rules")
        rule_ids = (
            [item.get("id") for item in rules if isinstance(item, dict)]
            if isinstance(rules, list)
            else []
        )
        if rule_ids != list(STOP_RULE_IDS):
            errors.append("R06 stop-rule IDs/order differ")

        schema_paths = {
            "preregistration": PREREGISTRATION_SCHEMA_PATH,
            "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
            "conformance": CONFORMANCE_SCHEMA_PATH,
        }
        bindings = value.get("schema_bindings")
        if not isinstance(bindings, dict) or set(bindings) != set(schema_paths):
            errors.append("R06 schema binding keys differ")
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

    @staticmethod
    def _state_has_valid_integrity(raw_value: object) -> bool:
        if not isinstance(raw_value, int) or isinstance(raw_value, bool):
            return False
        if raw_value < 0 or raw_value > 0x01FF:
            return False
        return (bin(raw_value >> 1).count("1") & 1) == (raw_value & 1)

    def _check_fixture_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R06 fixture catalog semantic contract differs")
        errors.extend(_privacy_errors(value, "R06 fixture catalog"))

        sources = value.get("source_bindings")
        source_values = sources if isinstance(sources, list) else []
        expected_sources = [
            {"id": identifier, "path": path, "size_bytes": size, "sha256": digest}
            for identifier, (path, size, digest) in SOURCE_BINDINGS.items()
        ]
        if source_values != expected_sources:
            errors.append("R06 source bindings differ from the frozen evidence bytes")
        for index, binding in enumerate(source_values):
            if not isinstance(binding, dict):
                errors.append(f"source_bindings[{index}] must be an object")
                continue
            expected = SOURCE_BINDINGS.get(binding.get("id"))
            if expected is None:
                continue
            self._check_binding(
                {key: binding.get(key) for key in ("path", "size_bytes", "sha256")},
                Path(expected[0]),
                f"source_bindings[{index}]",
                errors,
            )

        if value.get("constructor_parameters") != CONSTRUCTOR_PARAMETERS:
            errors.append("R06 constructor-bound weights/thresholds differ")

        profiles = value.get("policy_profiles")
        profile_values = profiles if isinstance(profiles, list) else []
        expected_profiles = expected_policy_profiles()
        if profile_values != expected_profiles:
            errors.append("R06 sixteen-profile ASHMessage catalog differs")
        if len(profile_values) == 16 and all(
            isinstance(item, dict) for item in profile_values
        ):
            axes = tuple(MESSAGE_AXES)
            by_raw = {item.get("raw_value"): item for item in profile_values}
            for raw_value in range(16):
                base = by_raw.get(raw_value)
                if not isinstance(base, dict):
                    continue
                for bit_index, expected_axis in enumerate(axes):
                    toggled = by_raw.get(raw_value ^ (1 << (3 - bit_index)))
                    if not isinstance(toggled, dict):
                        continue
                    changed = [
                        axis for axis in axes if base.get(axis) != toggled.get(axis)
                    ]
                    if changed != [expected_axis]:
                        errors.append(
                            "R06 ASHMessage single-bit causality differs for "
                            f"raw {raw_value} bit {bit_index}"
                        )

        backends = value.get("backend_fixtures")
        backend_values = backends if isinstance(backends, list) else []
        observed_backends = [
            (
                item.get("backend_id"),
                item.get("route_id"),
                item.get("fixture_eligible"),
                item.get("product_qualified"),
                item.get("whole_frame_only"),
            )
            for item in backend_values
            if isinstance(item, dict)
        ]
        if observed_backends != list(BACKEND_IDENTITIES):
            errors.append("R06 fixture backend identity/eligibility matrix differs")

        contexts = value.get("decision_context_fixtures")
        context_values = contexts if isinstance(contexts, list) else []
        context_ids = [
            item.get("id") for item in context_values if isinstance(item, dict)
        ]
        if context_ids != list(CONTEXT_IDS):
            errors.append("R06 decision-context fixture IDs/order differ")
        for item in context_values:
            if not isinstance(item, dict):
                continue
            if not self._state_has_valid_integrity(item.get("current_state_raw")):
                errors.append(f"R06 context {item.get('id')} current state fails integrity")
            if not self._state_has_valid_integrity(item.get("previous_state_raw")):
                errors.append(f"R06 context {item.get('id')} previous state fails integrity")

        masks = value.get("mask_fixtures")
        mask_values = masks if isinstance(masks, list) else []
        mask_ids = [item.get("id") for item in mask_values if isinstance(item, dict)]
        if mask_ids != list(MASK_IDS):
            errors.append("R06 mask fixture IDs/order differ")
        thresholds = CONSTRUCTOR_PARAMETERS["thresholds"]
        for item in mask_values:
            if not isinstance(item, dict):
                continue
            width = item.get("width")
            height = item.get("height")
            samples = item.get("samples_q15")
            if not isinstance(width, int) or not isinstance(height, int):
                errors.append(f"R06 mask {item.get('id')} dimensions are invalid")
                continue
            if not 1 <= width <= thresholds["mask_maximum_width"]:
                errors.append(f"R06 mask {item.get('id')} width is out of bounds")
            if not 1 <= height <= thresholds["mask_maximum_height"]:
                errors.append(f"R06 mask {item.get('id')} height is out of bounds")
            if not isinstance(samples, list) or len(samples) != width * height:
                errors.append(f"R06 mask {item.get('id')} sample count differs")
                continue
            if any(
                not isinstance(sample, int)
                or isinstance(sample, bool)
                or sample < thresholds["mask_minimum_q15"]
                or sample > thresholds["mask_maximum_q15"]
                for sample in samples
            ):
                errors.append(f"R06 mask {item.get('id')} sample is out of bounds")

        transitions = value.get("transition_fixtures")
        transition_values = transitions if isinstance(transitions, list) else []
        observed_transitions = [
            (
                item.get("id"),
                item.get("context_fixture_id"),
                item.get("expected_selected_route_id"),
                item.get("expected_reason"),
            )
            for item in transition_values
            if isinstance(item, dict)
        ]
        if observed_transitions != list(TRANSITION_IDENTITIES):
            errors.append("R06 transition fixture outcomes differ")
        route_ids = {identity[1] for identity in BACKEND_IDENTITIES}
        for item in transition_values:
            if not isinstance(item, dict):
                continue
            if item.get("context_fixture_id") not in set(CONTEXT_IDS):
                errors.append(f"R06 transition {item.get('id')} has unknown context")
            if not set(item.get("candidate_route_ids", [])) <= route_ids:
                errors.append(f"R06 transition {item.get('id')} has unknown route")

        ablations = value.get("ablation_scenarios")
        ablation_values = ablations if isinstance(ablations, list) else []
        observed_ablations = [
            (
                item.get("id"),
                item.get("fixture_contract_status"),
                item.get("product_execution_status"),
            )
            for item in ablation_values
            if isinstance(item, dict)
        ]
        expected_ablations = [
            (identifier, "deterministic_fixture_only", "not_observed")
            for identifier in ABLATION_IDS
        ]
        if observed_ablations != expected_ablations:
            errors.append("R06 fixture ablation matrix differs")
        for item in ablation_values:
            if not isinstance(item, dict):
                continue
            if not set(item.get("required_context_fixture_ids", [])) <= set(CONTEXT_IDS):
                errors.append(f"R06 ablation {item.get('id')} has unknown context")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH,
            PREREGISTRATION_SCHEMA_PATH,
            "R06 preregistration",
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
            "R06 fixture catalog",
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
            "product_gate_result",
            "fixture_checks",
            "product_ablations",
            "checks",
            "result",
            "limitations",
        }
        if set(value) != expected_keys:
            errors.append("R06 conformance top-level keys differ")
        errors.extend(_privacy_errors(value, "R06 conformance"))
        self._check_source(value.get("source"), "R06 conformance source", errors)
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
        if value.get("observation_status") != CONFORMANCE_OBSERVATION:
            errors.append("R06 conformance observation boundary differs")
        if value.get("product_gate_result") != CONFORMANCE_PRODUCT_GATE_RESULT:
            errors.append("R06 conformance product gate differs")

        expected_fixture_checks = [
            {"id": identifier, "status": "passed"}
            for identifier in FIXTURE_CHECK_IDS
        ]
        if value.get("fixture_checks") != expected_fixture_checks:
            errors.append("R06 conformance fixture checks differ")
        expected_ablations = [
            {
                "id": identifier,
                "status": "not_observed",
                "reason": "no_product_qualified_primary_backend",
            }
            for identifier in ABLATION_IDS
        ]
        if value.get("product_ablations") != expected_ablations:
            errors.append("R06 conformance product ablations differ")
        expected_checks = [
            {"id": identifier, "status": "passed"} for identifier in CHECK_IDS
        ]
        if value.get("checks") != expected_checks:
            errors.append("R06 conformance check results differ")
        if value.get("result") != CONFORMANCE_RESULT:
            errors.append("R06 conformance result exceeds the authorization boundary")
        if value.get("limitations") != list(CONFORMANCE_LIMITATIONS):
            errors.append("R06 conformance limitations differ from the frozen closure")

    def check_conformance(self) -> list[str]:
        errors: list[str] = []
        schema = self._read_json(
            CONFORMANCE_SCHEMA_PATH, "R06 conformance schema", errors
        )
        path = self.root / CONFORMANCE_PATH
        if path.is_symlink() or path.exists() and not path.is_file():
            errors.append("R06 conformance must be a regular non-symlink file")
            return errors
        if not path.exists():
            errors.append(
                "R06 orchestration conformance must be materialized after the "
                "implementation source is frozen"
            )
            return errors
        value = self._read_json(CONFORMANCE_PATH, "R06 conformance", errors)
        if value is not None and schema is not None:
            errors.extend(
                f"R06 conformance schema: {error}"
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
            "select --check-preregistration, --check-fixtures, "
            "--check-conformance, or --all"
        )
    verifier = R06ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if arguments.all or arguments.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if arguments.all or arguments.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if arguments.all or arguments.check_conformance:
        errors.extend(verifier.check_conformance())
    if not errors:
        if arguments.all or arguments.check_preregistration:
            print("R06 preregistration: PASS")
        if arguments.all or arguments.check_fixtures:
            print("R06 fixtures: PASS")
        if arguments.all or arguments.check_conformance:
            print("R06 conformance: PASS")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
