#!/usr/bin/env python3
"""Validate the frozen R07 temporal, artifact, and governance contracts."""

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
PREREGISTRATION_PATH = Path("docs/roadmaps/evidence/r07/records/preregistration.json")
PREREGISTRATION_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r07-preregistration-v1.json"
)
FIXTURE_CATALOG_PATH = Path(
    "docs/roadmaps/evidence/r07/records/fixtures/fixture-catalog.json"
)
FIXTURE_CATALOG_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r07-fixture-catalog-v1.json"
)
CONFORMANCE_PATH = Path(
    "docs/roadmaps/evidence/r07/records/temporal-artifact-conformance.json"
)
CONFORMANCE_SCHEMA_PATH = Path(
    "docs/roadmaps/evidence/schema/r07-temporal-artifact-conformance-v1.json"
)

PREREGISTRATION_SEMANTIC_SHA256 = (
    "6e04ed7226c1abb5c8d37f1403c01471382751837511ce6e8cb6b3a4e74665a1"
)
FIXTURE_CATALOG_SEMANTIC_SHA256 = (
    "d8337454d90feda5f8fabfde5faa96609ead70068fd60bbe8af4f75032f384e2"
)
PREDECESSOR = {
    "phase_id": "R06",
    "closure_state": "local_unpublished_blocked_closure",
    "closure_commit": "9ed01ea938a933f6406fd67e88edb74e7c84f5f4",
    "closure_tree": "32365e745dbf53d59213fe2294a6b63ba2642df7",
    "predecessor_result": "blocked",
    "accepted_merge_commit": None,
    "acceptance_state": "not_claimed",
    "continuation_scope": "local_implementation_only",
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
    "numeric_contract",
    "temporal_analysis_contract",
    "history_contract",
    "artifact_contract",
    "protected_content_contract",
    "weighted_mae_contract",
    "support_stage_contract",
    "postflight_feedback_contract",
    "product_comparator_contract",
    "product_gate",
    "checks",
    "stop_rules",
    "authorization_boundary",
)
FIXTURE_TOP_LEVEL_KEYS = (
    "schema_version",
    "phase_id",
    "contract_id",
    "source_bindings",
    "fixture_parameters",
    "temporal_fixtures",
    "artifact_fixtures",
    "history_fixtures",
    "protected_content_fixtures",
    "support_stage_fixtures",
    "postflight_fixtures",
    "comparator_fixtures",
)
NUMERIC_CONTRACT = {
    "q16_scale": 65536,
    "q15_maximum": 32767,
    "maximum_vector_or_mask_samples": 4096,
    "normal_luma_sample_domain_q16": {"minimum": 0, "maximum": 65536},
    "ringing_candidate_domain_q16": {"minimum": -65536, "maximum": 131072},
    "ringing_bound_domain_q16": {
        "minimum": 0,
        "maximum": 65536,
        "relation": "lower_less_than_or_equal_upper",
    },
    "accumulator": "checked_Int64",
    "rounding": "toward_zero",
    "overflow_policy": "reject",
    "oversize_policy": "reject_never_clamp",
}
OBSERVATION_POLICY = {
    "hardware_requirement": "waived_not_a_blocker",
    "simulator_requirement": "waived_not_a_blocker",
    "operator_observation_requirement": "waived_not_a_blocker",
    "hardware_capability_observation": "not_observed",
    "simulator_execution": "not_observed",
    "operator_observed_operation": "not_observed",
    "deterministic_software_conformance": "required",
    "product_comparison_execution": "not_observed",
    "product_gate_cause": "upstream_no_product_qualified_primary_backend",
    "hardware_simulator_operator_as_blocked_cause": "forbidden",
    "quality_claims": "forbidden",
    "performance_claims": "forbidden",
}
PRODUCT_GATE = {
    "eligibility_source": "R03_R04_R05_R06_product_qualification_records",
    "qualification_requirement": "explicit_product_qualified_primary_backend",
    "construction_order": "gate_before_support_stage_construction",
    "reason": "upstream_no_product_qualified_primary_backend",
    "eligible_backend_count": 0,
    "selected_route_id": None,
    "selected_plan_id": None,
    "output_identity": None,
    "disposition": "blocked",
}
ARTIFACT_ORDER = (
    "ringing",
    "halo",
    "ghosting",
    "flicker",
    "false_texture",
    "chroma_displacement",
)
ARTIFACT_THRESHOLDS = (3277, 3277, 4096, 4096, 4096, 64)
PROTECTED_KINDS = (
    "ui_capture",
    "subtitle",
    "text",
    "face",
    "line_art",
    "animation",
)
A04_CONFIGURATION_IDENTITY = (
    "r07.videotoolbox.temporal-noise-filter.fixture-only."
    "strength-q16-24576.v1"
)
A13_PROCESSING_IDENTITY = {
    "backend_id": "r03.mps.guided-filter",
    "backend_revision": "1",
    "model_assets_identity": "notRequired",
    "route_id": "guided_support_1x",
    "configuration_identity": (
        "r03.mps.guided-filter.guided_support_1x."
        "r8-to-rgba8-rgba16f.k5-e0p01.v1"
    ),
    "policy_identity": "r03.fixture-only.v1",
    "material_decision_identity": "r03.preregistered-baseline.v1",
    "fallback_history": [],
}
A15_PROCESSING_IDENTITY = {
    "backend_id": "r03.core-image.edge-preserve",
    "backend_revision": "1",
    "model_assets_identity": "notRequired",
    "route_id": "edge_preserve_support_2x",
    "configuration_identity": (
        "r03.core-image.edge-preserve.edge_preserve_support_2x."
        "r8.s3-l0p15.v1"
    ),
    "policy_identity": "r03.fixture-only.v1",
    "material_decision_identity": "r03.preregistered-baseline.v1",
    "fallback_history": [],
}
POSTFLIGHT_REJECTION_PRECEDENCE = ("duplicate", "cross_shot", "stale", "future")
PRODUCT_DIMENSIONS = (
    "temporal_artifact",
    "chroma_displacement",
    "spatial_ms_ssim",
    "protected_integrity",
)
COMPARATOR_DIMENSIONS = (
    {
        "id": "temporal_artifact",
        "metric": (
            "maximum_normalized_risk_q16_over_ringing_halo_ghosting_"
            "flicker_false_texture"
        ),
        "unit": "q16",
        "equation": "baseline_temporal_risk_q16-auto_temporal_risk_q16",
        "pass_operator": "greater_than_or_equal",
        "pass_threshold": 1,
    },
    {
        "id": "chroma_displacement",
        "metric": "raw_chroma_displacement_q8_pixels",
        "unit": "q8_pixels",
        "equation": (
            "baseline_chroma_displacement_q8_pixels-"
            "auto_chroma_displacement_q8_pixels"
        ),
        "pass_operator": "greater_than_or_equal",
        "pass_threshold": 1,
    },
    {
        "id": "spatial_ms_ssim",
        "metric": "delta_ppm",
        "unit": "ppm",
        "equation": "auto_ms_ssim_ppm-baseline_ms_ssim_ppm",
        "pass_operator": "greater_than_or_equal",
        "pass_threshold": -5000,
    },
    {
        "id": "protected_integrity",
        "metric": "weighted_mae_q16",
        "unit": "q16",
        "equation": "auto_weighted_mae_q16-baseline_weighted_mae_q16",
        "pass_operator": "less_than_or_equal",
        "pass_threshold": 0,
    },
)
CHECK_IDS = (
    "predecessor_closure_exact",
    "frozen_bindings_exact",
    "checked_fixed_point_exact",
    "vector_bounds_exact",
    "temporal_contract_exact",
    "history_contract_exact",
    "artifact_contract_exact",
    "protected_content_exact",
    "weighted_mae_exact",
    "support_stage_policy_exact",
    "postflight_governance_exact",
    "product_comparator_exact",
    "product_gate_closed",
    "observation_override_nonblocking",
    "product_comparisons_not_observed",
    "no_quality_or_performance_claim",
    "production_default_disabled",
)
FIXTURE_CHECK_IDS = (
    "source_bindings_exact",
    "temporal_metrics_exact",
    "temporal_threshold_equality_exact",
    "vector_bounds_exact",
    "history_window_churn_reset_exact",
    "artifact_metrics_exact",
    "artifact_normalization_aggregate_exact",
    "protected_masks_exact",
    "weighted_mae_exact",
    "support_stage_admission_exact",
    "product_gate_before_construction",
    "postflight_feedback_exact",
    "comparator_nonvacuity_exact",
)
STOP_RULE_IDS = (
    "predecessor_identity_drift",
    "contract_byte_drift",
    "arithmetic_contract_violation",
    "vector_or_mask_bounds_violation",
    "temporal_or_history_violation",
    "artifact_metric_violation",
    "protected_content_violation",
    "support_stage_admission_violation",
    "postflight_causality_violation",
    "vacuous_or_fabricated_comparison",
    "authorization_boundary",
)

SOURCE_BINDINGS = {
    "r01_preregistration": ("docs/roadmaps/evidence/r01/records/preregistration.json", 7256, "8651ce7a52cd2c80a86e42480cbfbf78474e07dfea8685851138583e3760c69f"),
    "r01_fixture_catalog": ("docs/roadmaps/evidence/r01/records/fixtures/fixture-catalog.json", 9656, "ae8241f5d69ce64ed143e8bbb39ab80a996f6923f1ddc83ebfbaec58d9689182"),
    "r01_support_frame": ("project-notes/evidence/r01/fixtures/support-frame.bin", 3110400, "b0a20a11875a4b977bf20db4d34367404b907a50374b99faa545a70c7c01eb6e"),
    "r01_support_guidance": ("project-notes/evidence/r01/fixtures/support-guidance.bin", 2073600, "fc181d1538aefa5f635b334f778ed4210aca5bb799b249931ced024551a2ec91"),
    "r01_support_history": ("project-notes/evidence/r01/fixtures/support-history.bin", 3110400, "44795da53184aca29cb905fa27c4362d7fec0cde1048c3cc5724f17dbb232c15"),
    "r01_temporal_frame_0": ("project-notes/evidence/r01/fixtures/temporal-frame-0.bin", 3110400, "e62159913ef91af0784820cc71edea1d5db6014fe8853ea012f20a461c359bbd"),
    "r01_temporal_frame_1": ("project-notes/evidence/r01/fixtures/temporal-frame-1.bin", 3110400, "503a754a679221dc5a2a29b4a0d3b1382b6084ab7f886cb9760356310335f168"),
    "r03_preregistration": ("docs/roadmaps/evidence/r03/records/preregistration.json", 14779, "bf883a6324de160381dc426af85f5dc1dcadcbc0bd3115df3bfc190c4d01eb1c"),
    "r03_fixture_catalog": ("docs/roadmaps/evidence/r03/records/fixtures/fixture-catalog.json", 13705, "ce44164b23f7fba765fe5c37c24d55dfb7d796043011d02e945704dff10c5602"),
    "r03_baseline_conformance": ("docs/roadmaps/evidence/r03/records/baseline-conformance.json", 57826, "9dab73f07b3b4e0d41c9f6ac0056fe7f3a36219754a55e91ef9fc74271ee67bd"),
    "r04_preregistration": ("docs/roadmaps/evidence/r04/records/preregistration.json", 10650, "238d70794695c8527175211d77caed4192eb774511cf99aacb8640ed49cd6ea0"),
    "r04_fixture_catalog": ("docs/roadmaps/evidence/r04/records/fixtures/fixture-catalog.json", 7144, "7ca46591d6d73f3c8f0875f8d5b966e30a708b8c300cef85253973459031a579"),
    "r04_integration_conformance": ("docs/roadmaps/evidence/r04/records/integration-conformance.json", 4383, "49321c85a33837b10f9bbc81bf200d060731ceb7ed701197fe897dc2e3d448bf"),
    "r06_preregistration": ("docs/roadmaps/evidence/r06/records/preregistration.json", 15319, "2b430d75ae1692067a4c1d6e3f6def8bc553c171f30396e0896ae0a3be49beaf"),
    "r06_fixture_catalog": ("docs/roadmaps/evidence/r06/records/fixtures/fixture-catalog.json", 10786, "2f06fff3a214019ba5f871c918a2ceba9e1019a89342988cf7e8866d929e11a1"),
    "r06_orchestration_conformance": ("docs/roadmaps/evidence/r06/records/orchestration-conformance.json", 5800, "19f25269e9cb62ba162e2c53d716a79a392fef740a0be0c7d981cbdac3bfeccc"),
    "r03_guided_support_stages_swift": ("Mirmir/Modules/UpscalerEngine/R03GuidedSupportStages.swift", 26562, "7e9956f5a470e18b98f99952875476e054c16e36a534f1b320bce0b0944a59fb"),
    "r03_deterministic_backend_catalog_swift": ("Mirmir/Modules/UpscalerEngine/R03DeterministicBackendCatalog.swift", 10085, "ac57436aff9315ac83d1c7c0849d4e2ac2545a5ee4aa576839984dafdba7e477"),
    "r04_video_toolbox_contracts_swift": ("Mirmir/Modules/UpscalerEngine/R04VideoToolboxContracts.swift", 24961, "591dadd402c0e601a5548018476ae5cf93cba5c2b5b89522c373bef6a6168af1"),
    "r04_video_toolbox_session_adapter_swift": ("Mirmir/Modules/UpscalerEngine/R04VideoToolboxSessionAdapter.swift", 39514, "c10f5d366837afcd9e4a777c202fa11d00957ec1c1373ed50469b64fd08e4d14"),
    "apple_upscale_fifo_session_swift": ("Mirmir/Modules/UpscalerEngine/AppleUpscaleFIFOSession.swift", 14989, "d6000c7b5d41f1b666487941cb96e436049e2f3f572c36d881c4be7b6f8ec1c8"),
    "apple_upscale_contracts_swift": ("Mirmir/Modules/UpscalerEngine/AppleUpscaleContracts.swift", 21360, "dabebc008d44dd588b6e8d95ae84899b4f383d03e81c994f060f9e318213ee0f"),
    "r06_ash_decision_context_swift": ("Mirmir/Modules/UpscalerEngine/R06ASHDecisionContext.swift", 13965, "962790b0c79d77dafba4134d0ba58f221125a038f388581c7ff0526a1729047b"),
    "r06_ash_masks_swift": ("Mirmir/Modules/UpscalerEngine/R06ASHMasksAndAblations.swift", 7529, "274c0ae5fc31eb9f07c1cc345f2ec0174c53b2daf5fc564f4b227ce74f797864"),
    "r06_ash_orchestrator_swift": ("Mirmir/Modules/UpscalerEngine/R06ASHOrchestrator.swift", 22953, "a55502f19fd827b416379212c749b3bcffdb8136f6185d2b28f21576ad9821e4"),
    "r06_ash_policy_swift": ("Mirmir/Modules/UpscalerEngine/R06ASHPolicyCatalog.swift", 3836, "00ddacea5bcfe1fe87d0af35650f38636e431bdb31c3bef6fe30d802135fe27b"),
}

FAMILY_IDS = {
    "temporal_fixtures": (
        "temporal-identical", "temporal-hard-cut", "temporal-translation",
        "temporal-occlusion", "temporal-out-of-order",
        "temporal-scene-cut-threshold-equality",
        "temporal-motion-threshold-equality",
        "temporal-occlusion-threshold-equality",
        "temporal-vector-boundary-4096",
        "temporal-empty-vector-rejection",
        "temporal-sample-count-mismatch-rejection",
        "temporal-all-occluded-motion-rejection",
    ),
    "artifact_fixtures": (
        "artifact-step-ringing", "artifact-impulse-halo",
        "artifact-checker-false-texture", "artifact-thin-line-control",
        "artifact-chroma-edge", "artifact-a-b-a-b-flicker",
        "artifact-trailing-ghost", "artifact-threshold-equality",
        "artifact-risk-aggregate-order", "artifact-vector-oversize-rejection",
        "artifact-all-occluded-ghosting-rejection",
        "artifact-zero-halo-support-rejection",
        "artifact-false-texture-insufficient-samples-rejection",
    ),
    "history_fixtures": (
        "history-a-a-b", "history-strength-changes",
        "history-artifact-persistence", "history-reset-causes",
        "history-duplicate-stale", "history-capacity-eviction",
        "history-zero-transitions", "history-empty-artifact-persistence",
        "history-single-artifact-persistence",
    ),
    "protected_content_fixtures": (
        "protected-ui-capture", "protected-subtitle", "protected-text",
        "protected-face", "protected-line-art", "protected-animation",
        "protected-empty-regions", "protected-overlap-precedence",
        "protected-invalid-matrix", "protected-weighted-mae",
        "protected-mask-boundary-4096", "protected-zero-weight-rejection",
    ),
    "support_stage_fixtures": (
        "support-a04-not-observed", "support-a04-unsupported",
        "support-a04-fixture-admitted", "support-a05-temporal-analyzer",
        "support-a13-guided-filter", "support-a15-edge-preserve",
        "support-product-gate-first",
    ),
    "postflight_fixtures": (
        "postflight-completed-n", "postflight-n-plus-1", "postflight-stale",
        "postflight-future", "postflight-duplicate", "postflight-cross-shot",
        "postflight-rejection-precedence-overlap",
    ),
    "comparator_fixtures": (
        "temporal-artifact-comparison", "chroma-displacement-comparison",
        "spatial-ms-ssim-comparison", "protected-integrity-comparison",
        "comparator-temporal-equality",
        "comparator-temporal-one-unit-failure",
        "comparator-chroma-equality",
        "comparator-chroma-one-unit-failure",
        "comparator-spatial-equality",
        "comparator-spatial-one-unit-failure",
        "comparator-protected-equality",
        "comparator-protected-one-unit-failure",
    ),
}


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


class R07ContractVerifier:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.conformance_materialized = False

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments], cwd=self.root, capture_output=True,
            check=False, text=True
        )

    def _safe_path(
        self, value: object, context: str, errors: list[str]
    ) -> Path | None:
        if not isinstance(value, str) or not value or "\x00" in value:
            errors.append(f"{context}.path must be a non-empty normalized path")
            return None
        pure = PurePosixPath(value)
        if pure.is_absolute() or ".." in pure.parts or pure.as_posix() != value:
            errors.append(f"{context}.path must be normalized and repository-relative")
            return None
        resolved = self.root / value
        if resolved.is_symlink() or not resolved.is_file():
            errors.append(f"{context}.path must name a regular non-symlink file")
            return None
        try:
            resolved.resolve().relative_to(self.root)
        except ValueError:
            errors.append(f"{context}.path escapes the repository")
            return None
        return resolved

    def _read_json(
        self, relative: Path, context: str, errors: list[str]
    ) -> dict[str, Any] | None:
        target = self.root / relative
        if target.is_symlink() or not target.is_file():
            errors.append(f"{context} must be a regular non-symlink file")
            return None
        try:
            value = decode_json(target.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            errors.append(f"{context} is invalid: {error}")
            return None
        if not isinstance(value, dict):
            errors.append(f"{context} must be an object")
            return None
        return value

    def _read_and_validate(
        self, relative: Path, schema_relative: Path, context: str,
        errors: list[str]
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
        self, binding: object, expected_path: Path, context: str,
        errors: list[str]
    ) -> None:
        if not isinstance(binding, dict) or set(binding) != {
            "path", "size_bytes", "sha256"
        }:
            errors.append(f"{context} keys differ")
            return
        if binding.get("path") != expected_path.as_posix():
            errors.append(f"{context}.path differs")
        target = self._safe_path(binding.get("path"), context, errors)
        if target is None:
            return
        payload = target.read_bytes()
        if binding.get("size_bytes") != len(payload):
            errors.append(f"{context}.size_bytes differs")
        if binding.get("sha256") != _sha256(payload):
            errors.append(f"{context}.sha256 differs")

    def _check_predecessor(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if value.get("predecessor_binding") != PREDECESSOR:
            errors.append("R07 predecessor binding differs from the frozen R06 closure")
            return
        commit = PREDECESSOR["closure_commit"]
        if self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
            errors.append("R07 predecessor closure commit is unavailable")
            return
        observed_tree = self.git("rev-parse", f"{commit}^{{tree}}")
        if observed_tree.returncode != 0 or observed_tree.stdout.strip() != PREDECESSOR["closure_tree"]:
            errors.append("R07 predecessor closure tree differs from its commit")
        if self.git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
            errors.append("R07 predecessor closure commit is not an ancestor of HEAD")

    def _check_preregistration_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != PREREGISTRATION_SEMANTIC_SHA256:
            errors.append("R07 preregistration semantic contract differs")
        errors.extend(_privacy_errors(value, "R07 preregistration"))
        if tuple(value) != PREREGISTRATION_TOP_LEVEL_KEYS:
            errors.append("R07 preregistration top-level keys/order differ")
        if value.get("observation_policy") != OBSERVATION_POLICY:
            errors.append("R07 observation policy differs")
        if value.get("numeric_contract") != NUMERIC_CONTRACT:
            errors.append("R07 numeric contract differs")
        if value.get("product_gate") != PRODUCT_GATE:
            errors.append("R07 product gate differs")

        temporal = value.get("temporal_analysis_contract")
        if not isinstance(temporal, dict):
            errors.append("R07 temporal contract must be an object")
        else:
            samples = temporal.get("samples")
            if not isinstance(samples, dict) or any(
                samples.get(key) != expected
                for key, expected in (
                    ("minimum_count", 1),
                    ("maximum_count", 4096),
                    ("boundary_fixture_representation", "declared_sample_count_and_constant_fill_generator"),
                    ("empty_policy", "empty_vector_rejected"),
                    ("unequal_length_policy", "sample_count_mismatch_rejected"),
                    ("oversize_policy", "reject_never_clamp"),
                )
            ):
                errors.append("R07 temporal sample boundary/rejection semantics differ")
            expected = (("scene_cut", 49152), ("motion_confidence", 49152), ("occlusion", 16384))
            for key, threshold in expected:
                item = temporal.get(key)
                threshold_key = "validity_threshold_q16" if key == "motion_confidence" else "threshold_q16"
                operator_key = "validity_operator" if key == "motion_confidence" else "detection_operator"
                if not isinstance(item, dict) or item.get(threshold_key) != threshold or item.get(operator_key) != "greater_than_or_equal":
                    errors.append(f"R07 {key} threshold/equality semantics differ")
            motion = temporal.get("motion_confidence")
            if not isinstance(motion, dict) or motion.get("no_valid_samples_policy") != "no_valid_motion_samples_rejected":
                errors.append("R07 no-valid-motion rejection semantics differ")

        history = value.get("history_contract")
        if not isinstance(history, dict) or history.get("capacity_entries") != 8:
            errors.append("R07 history capacity differs")
        else:
            if history.get("churn_window") != {"maximum_transitions": 4, "maximum_entries": 5, "selection": "most_recent_entries"}:
                errors.append("R07 history churn window differs")
            for key, threshold in (("backend_churn", 32768), ("strength_churn", 8192), ("artifact_persistence", 8192)):
                item = history.get(key)
                if not isinstance(item, dict) or item.get("threshold_q16") != threshold or item.get("within_bound_operator") != "less_than_or_equal" or item.get("excessive_operator") != "greater_than":
                    errors.append(f"R07 {key} threshold/equality semantics differ")
            if history.get("initial_values") != {
                "zero_transitions_backend_churn_q16": 0,
                "zero_transitions_strength_churn_q16": 0,
                "zero_transition_metrics_excessive": False,
                "empty_artifact_persistence_q16": 0,
                "empty_artifact_persistence_excessive": False,
                "single_entry_artifact_persistence": "entry_artifact_risk_q16",
            }:
                errors.append("R07 history initial-value semantics differ")

        artifact = value.get("artifact_contract")
        metrics = artifact.get("metrics") if isinstance(artifact, dict) else None
        if not isinstance(artifact, dict) or artifact.get("artifact_order") != list(ARTIFACT_ORDER):
            errors.append("R07 artifact order differs")
        elif not isinstance(metrics, list) or [item.get("threshold") for item in metrics if isinstance(item, dict)] != list(ARTIFACT_THRESHOLDS):
            errors.append("R07 artifact thresholds differ")
        elif artifact.get("detection") != {"operator": "raw_greater_than_threshold", "threshold_equality_detected": False, "threshold_equality_normalized_risk_q16": 65536}:
            errors.append("R07 artifact detection equality semantics differ")
        elif {
            item.get("id"): item.get("invalid_policy")
            for item in metrics if isinstance(item, dict) and "invalid_policy" in item
        } != {
            "halo": "zero_support_rejected",
            "ghosting": "no_valid_ghosting_samples_rejected",
            "false_texture": "insufficient_samples_rejected",
        }:
            errors.append("R07 artifact invalid-input semantics differ")

        protected = value.get("protected_content_contract")
        if not isinstance(protected, dict) or protected.get("kinds") != list(PROTECTED_KINDS) or protected.get("precedence") != list(PROTECTED_KINDS):
            errors.append("R07 protected kind/precedence order differs")
        elif protected.get("composition", {}).get("zero_owner") is not None or protected.get("composition", {}).get("empty_region_list") != "accepted_all_zero_masks_nil_owners":
            errors.append("R07 protected zero-owner/empty-region semantics differ")
        elif protected.get("mask", {}).get("boundary_fixture_representation") != "declared_sample_count_and_constant_fill_generator":
            errors.append("R07 protected compact 4096-mask boundary differs")
        weighted = value.get("weighted_mae_contract")
        if not isinstance(weighted, dict) or weighted.get("zero_weight_policy") != "zero_weight_rejected":
            errors.append("R07 weighted-MAE zero-weight rejection differs")

        support = value.get("support_stage_contract")
        a04 = support.get("a04") if isinstance(support, dict) else None
        if not isinstance(a04, dict) or a04.get("configuration_identity") != A04_CONFIGURATION_IDENTITY or a04.get("strength_q16") != 24576:
            errors.append("R07 A04 configuration differs")
        a13 = support.get("a13") if isinstance(support, dict) else None
        if not isinstance(a13, dict) or any(
            a13.get(key) != "R8"
            for key in (
                "source_pixel_format", "guidance_pixel_format",
                "output_pixel_format",
            )
        ):
            errors.append("R07 A13 source/guidance/output R8 contract differs")
        elif a13.get("processing_identity") != A13_PROCESSING_IDENTITY or any(
            a13.get(key) != expected
            for key, expected in (
                ("conformance_scope", "descriptor_and_admission_only"),
                ("reconstruction_execution", "not_observed"),
                ("output_claims", "forbidden"),
            )
        ):
            errors.append("R07 A13 identity/conformance scope differs")
        a15 = support.get("a15") if isinstance(support, dict) else None
        if not isinstance(a15, dict) or any(
            a15.get(key) != "R8"
            for key in (
                "mask_pixel_format", "guidance_pixel_format",
                "output_pixel_format",
            )
        ):
            errors.append("R07 A15 mask/guidance/output R8 contract differs")
        elif a15.get("processing_identity") != A15_PROCESSING_IDENTITY or any(
            a15.get(key) != expected
            for key, expected in (
                ("conformance_scope", "descriptor_and_admission_only"),
                ("reconstruction_execution", "not_observed"),
                ("output_claims", "forbidden"),
            )
        ):
            errors.append("R07 A15 identity/conformance scope differs")
        postflight = value.get("postflight_feedback_contract")
        if not isinstance(postflight, dict) or postflight.get("report_binding") != "completed_R06_decision_N_same_shot" or postflight.get("rejection_precedence") != list(POSTFLIGHT_REJECTION_PRECEDENCE):
            errors.append("R07 postflight R06 binding/rejection precedence differs")
        comparator = value.get("product_comparator_contract")
        dimensions = comparator.get("dimensions") if isinstance(comparator, dict) else None
        if not isinstance(comparator, dict) or dimensions != list(COMPARATOR_DIMENSIONS) or comparator.get("nonvacuity") != "exactly_one_complete_comparison_per_unique_fixture_backend_per_dimension" or comparator.get("empty_backend_set_passes") is not False or comparator.get("current_product_status") != "not_observed":
            errors.append("R07 product comparator dimensions/nonvacuity differ")

        checks = value.get("checks")
        check_ids = [item.get("id") for item in checks if isinstance(item, dict)] if isinstance(checks, list) else []
        if check_ids != list(CHECK_IDS):
            errors.append("R07 check IDs/order differ")
        rules = value.get("stop_rules")
        rule_ids = [item.get("id") for item in rules if isinstance(item, dict)] if isinstance(rules, list) else []
        if rule_ids != list(STOP_RULE_IDS):
            errors.append("R07 stop-rule IDs/order differ")

        schemas = {
            "preregistration": PREREGISTRATION_SCHEMA_PATH,
            "fixture_catalog": FIXTURE_CATALOG_SCHEMA_PATH,
            "conformance": CONFORMANCE_SCHEMA_PATH,
        }
        bindings = value.get("schema_bindings")
        if not isinstance(bindings, dict) or tuple(bindings) != tuple(schemas):
            errors.append("R07 schema binding keys/order differ")
        else:
            for key, relative in schemas.items():
                self._check_binding(bindings.get(key), relative, f"schema_bindings.{key}", errors)
        self._check_binding(value.get("fixture_catalog"), FIXTURE_CATALOG_PATH, "fixture_catalog", errors)

    @staticmethod
    def _fixture_map(value: dict[str, Any], family: str) -> dict[str, dict[str, Any]]:
        fixtures = value.get(family)
        if not isinstance(fixtures, list):
            return {}
        return {item.get("id"): item for item in fixtures if isinstance(item, dict) and isinstance(item.get("id"), str)}

    def _check_vector_bounds(self, value: object, location: str, errors: list[str]) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                self._check_vector_bounds(nested, f"{location}.{key}", errors)
        elif isinstance(value, list):
            if len(value) > 4096:
                errors.append(f"{location} exceeds the frozen 4096-sample bound")
            for index, nested in enumerate(value):
                if isinstance(nested, (dict, list)):
                    self._check_vector_bounds(nested, f"{location}[{index}]", errors)

    def _check_fixture_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        if _semantic_sha256(value) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R07 fixture catalog semantic contract differs")
        errors.extend(_privacy_errors(value, "R07 fixture catalog"))
        if tuple(value) != FIXTURE_TOP_LEVEL_KEYS:
            errors.append("R07 fixture catalog top-level keys/order differ")
        if value.get("fixture_parameters") != {
            "maximum_vector_or_mask_samples": 4096,
            "normal_luma_sample_minimum_q16": 0,
            "normal_luma_sample_maximum_q16": 65536,
            "ringing_candidate_minimum_q16": -65536,
            "ringing_candidate_maximum_q16": 131072,
            "ringing_bound_minimum_q16": 0,
            "ringing_bound_maximum_q16": 65536,
            "oversize_policy": "reject_never_clamp",
        }:
            errors.append("R07 fixture parameters differ")

        sources = value.get("source_bindings")
        source_values = sources if isinstance(sources, list) else []
        expected_sources = [
            {"id": key, "path": item[0], "size_bytes": item[1], "sha256": item[2]}
            for key, item in SOURCE_BINDINGS.items()
        ]
        if source_values != expected_sources:
            errors.append("R07 source bindings differ from frozen bytes")
        for index, binding in enumerate(source_values):
            if not isinstance(binding, dict):
                errors.append(f"source_bindings[{index}] must be an object")
                continue
            expected = SOURCE_BINDINGS.get(binding.get("id"))
            if expected is not None:
                self._check_binding(
                    {key: binding.get(key) for key in ("path", "size_bytes", "sha256")},
                    Path(expected[0]), f"source_bindings[{index}]", errors
                )

        for family, expected_ids in FAMILY_IDS.items():
            fixtures = value.get(family)
            ids = [item.get("id") for item in fixtures if isinstance(item, dict)] if isinstance(fixtures, list) else []
            if ids != list(expected_ids):
                errors.append(f"R07 {family} IDs/order differ")
            if isinstance(fixtures, list):
                self._check_vector_bounds(fixtures, family, errors)

        temporal = self._fixture_map(value, "temporal_fixtures")
        temporal_boundary = temporal.get("temporal-vector-boundary-4096", {})
        boundary_inputs = temporal_boundary.get("inputs") if isinstance(temporal_boundary, dict) else None
        boundary_expected = temporal_boundary.get("expected") if isinstance(temporal_boundary, dict) else None
        if not isinstance(boundary_inputs, dict) or boundary_inputs.get("generator") != "constant_fill" or boundary_inputs.get("declared_sample_count") != 4096 or not isinstance(boundary_expected, dict) or boundary_expected.get("accepted") is not True or boundary_expected.get("materialized_sample_count") != 4096:
            errors.append("R07 compact temporal 4096-sample boundary differs")
        for identifier, reason in (
            ("temporal-empty-vector-rejection", "empty_vector_rejected"),
            ("temporal-sample-count-mismatch-rejection", "sample_count_mismatch_rejected"),
            ("temporal-all-occluded-motion-rejection", "no_valid_motion_samples_rejected"),
        ):
            expected = temporal.get(identifier, {}).get("expected", {})
            if not isinstance(expected, dict) or expected.get("accepted") is not False or expected.get("reason") != reason:
                errors.append(f"R07 {identifier} outcome differs")

        artifact = self._fixture_map(value, "artifact_fixtures")
        ringing = artifact.get("artifact-step-ringing", {}).get("inputs", {})
        candidate = ringing.get("candidate") if isinstance(ringing, dict) else None
        lower = ringing.get("lower_bounds") if isinstance(ringing, dict) else None
        upper = ringing.get("upper_bounds") if isinstance(ringing, dict) else None
        if not isinstance(candidate, list) or any(not isinstance(item, int) or item < -65536 or item > 131072 for item in candidate):
            errors.append("R07 ringing candidate signed Q16 domain differs")
        if not isinstance(lower, list) or not isinstance(upper, list) or len(lower) != len(upper) or any(not isinstance(item, int) or item < 0 or item > 65536 for item in lower + upper) or any(low > high for low, high in zip(lower, upper)):
            errors.append("R07 ringing bounds/domain relation differs")
        for identifier, reason in (
            ("artifact-all-occluded-ghosting-rejection", "no_valid_ghosting_samples_rejected"),
            ("artifact-zero-halo-support-rejection", "zero_support_rejected"),
            ("artifact-false-texture-insufficient-samples-rejection", "insufficient_samples_rejected"),
        ):
            expected = artifact.get(identifier, {}).get("expected", {})
            if not isinstance(expected, dict) or expected.get("accepted") is not False or expected.get("reason") != reason:
                errors.append(f"R07 {identifier} outcome differs")

        normal_luma_keys = {
            "current", "previous", "before_previous", "aligned_previous",
            "candidate", "reference", "source",
        }
        for family in ("temporal_fixtures", "artifact_fixtures"):
            for fixture in self._fixture_map(value, family).values():
                if fixture.get("id") == "artifact-step-ringing":
                    continue
                inputs = fixture.get("inputs")
                if not isinstance(inputs, dict):
                    continue
                for key in normal_luma_keys:
                    samples = inputs.get(key)
                    if samples is None:
                        continue
                    if not isinstance(samples, list) or any(
                        not isinstance(item, int) or isinstance(item, bool)
                        or item < 0 or item > 65536
                        for item in samples
                    ):
                        errors.append(
                            f"R07 {fixture.get('id')} {key} normal Q16 domain differs"
                        )
                mask = inputs.get("occlusion_mask")
                if mask is not None and (
                    not isinstance(mask, list)
                    or any(item not in (0, 1) or isinstance(item, bool) for item in mask)
                ):
                    errors.append(
                        f"R07 {fixture.get('id')} occlusion mask domain differs"
                    )

        protected = self._fixture_map(value, "protected_content_fixtures")
        for identifier in tuple(PROTECTED_KINDS):
            fixture = protected.get(f"protected-{identifier.replace('_', '-')}")
            inputs = fixture.get("inputs") if isinstance(fixture, dict) else None
            if not isinstance(inputs, dict):
                errors.append(f"R07 protected {identifier} fixture is absent")
                continue
            width, height, samples = inputs.get("width"), inputs.get("height"), inputs.get("mask_q15")
            if not isinstance(width, int) or not isinstance(height, int) or not 1 <= width <= 64 or not 1 <= height <= 64 or not isinstance(samples, list) or len(samples) != width * height or len(samples) > 4096 or any(not isinstance(item, int) or item < 0 or item > 32767 for item in samples):
                errors.append(f"R07 protected {identifier} mask bounds differ")
        mask_boundary = protected.get("protected-mask-boundary-4096", {})
        mask_inputs = mask_boundary.get("inputs") if isinstance(mask_boundary, dict) else None
        mask_expected = mask_boundary.get("expected") if isinstance(mask_boundary, dict) else None
        if not isinstance(mask_inputs, dict) or (mask_inputs.get("width"), mask_inputs.get("height"), mask_inputs.get("generator"), mask_inputs.get("declared_sample_count"), mask_inputs.get("fill_q15")) != (64, 64, "constant_fill", 4096, 32767) or not isinstance(mask_expected, dict) or mask_expected.get("accepted") is not True or mask_expected.get("materialized_sample_count") != 4096:
            errors.append("R07 compact protected 4096-mask boundary differs")
        zero_weight = protected.get("protected-zero-weight-rejection", {}).get("expected", {})
        if not isinstance(zero_weight, dict) or zero_weight.get("accepted") is not False or zero_weight.get("reason") != "zero_weight_rejected":
            errors.append("R07 zero weighted-MAE mask rejection differs")

        history = self._fixture_map(value, "history_fixtures")
        zero_transitions = history.get("history-zero-transitions", {}).get("expected", {})
        if not isinstance(zero_transitions, dict) or any(
            zero_transitions.get(key) != expected
            for key, expected in (
                ("transition_count", 0),
                ("backend_churn_q16", 0),
                ("strength_churn_q16", 0),
                ("backend_churn_excessive", False),
                ("strength_churn_excessive", False),
            )
        ):
            errors.append("R07 zero-transition history metrics differ")
        empty_persistence = history.get("history-empty-artifact-persistence", {}).get("expected", {})
        if not isinstance(empty_persistence, dict) or (empty_persistence.get("window_entry_count"), empty_persistence.get("mean_risk_q16"), empty_persistence.get("excessive")) != (0, 0, False):
            errors.append("R07 empty artifact-persistence semantics differ")
        single_persistence = history.get("history-single-artifact-persistence", {}).get("expected", {})
        if not isinstance(single_persistence, dict) or (single_persistence.get("window_entry_count"), single_persistence.get("mean_risk_q16"), single_persistence.get("uses_entry_artifact_risk"), single_persistence.get("excessive")) != (1, 4096, True, False):
            errors.append("R07 single-entry artifact-persistence semantics differ")

        support = self._fixture_map(value, "support_stage_fixtures")
        admitted = support.get("support-a04-fixture-admitted", {})
        expected = admitted.get("expected") if isinstance(admitted, dict) else None
        if not isinstance(expected, dict) or expected.get("configuration_identity") != A04_CONFIGURATION_IDENTITY or expected.get("strength_q16") != 24576:
            errors.append("R07 admitted A04 fixture descriptor differs")
        for identifier, identity, format_keys in (
            (
                "support-a13-guided-filter", A13_PROCESSING_IDENTITY,
                ("source_pixel_format", "guidance_pixel_format", "output_pixel_format"),
            ),
            (
                "support-a15-edge-preserve", A15_PROCESSING_IDENTITY,
                ("mask_pixel_format", "guidance_pixel_format", "output_pixel_format"),
            ),
        ):
            fixture = support.get(identifier, {})
            inputs = fixture.get("inputs") if isinstance(fixture, dict) else None
            expected = fixture.get("expected") if isinstance(fixture, dict) else None
            if not isinstance(inputs, dict) or inputs.get("processing_identity") != identity or any(inputs.get(key) != "R8" for key in format_keys) or not isinstance(expected, dict) or (expected.get("conformance_scope"), expected.get("reconstruction_execution"), expected.get("output_claims")) != ("descriptor_and_admission_only", "not_observed", "forbidden"):
                errors.append(f"R07 {identifier} identity/scope differs")
        postflight = self._fixture_map(value, "postflight_fixtures")
        overlap = postflight.get("postflight-rejection-precedence-overlap", {})
        overlap_expected = overlap.get("expected") if isinstance(overlap, dict) else None
        if not isinstance(overlap_expected, dict) or overlap_expected.get("precedence") != list(POSTFLIGHT_REJECTION_PRECEDENCE) or overlap_expected.get("selected_rejection") != "duplicate":
            errors.append("R07 postflight overlap precedence differs")
        comparators = self._fixture_map(value, "comparator_fixtures")
        blocked_ids = FAMILY_IDS["comparator_fixtures"][:4]
        for identifier, dimension in zip(blocked_ids, COMPARATOR_DIMENSIONS):
            fixture = comparators.get(identifier, {})
            inputs = fixture.get("inputs") if isinstance(fixture, dict) else None
            expected = fixture.get("expected") if isinstance(fixture, dict) else None
            if not isinstance(inputs, dict) or inputs.get("dimension") != dimension["id"] or inputs.get("equation") != dimension["equation"] or inputs.get("unit") != dimension["unit"] or inputs.get("pass_operator") != dimension["pass_operator"] or inputs.get("pass_threshold") != dimension["pass_threshold"] or inputs.get("used_backend_ids") != [] or not isinstance(expected, dict) or expected.get("status") != "not_observed" or expected.get("reason") != "upstream_no_product_qualified_primary_backend" or expected.get("nonvacuous_requirement_satisfied") is not False or expected.get("fixture_comparison_executed") is not False or expected.get("product_comparison_execution") != "not_observed" or expected.get("product_qualification") != "not_claimed" or expected.get("claim") != "forbidden":
                errors.append(f"R07 comparator {identifier} blocked boundary differs")

        synthetic_ids = FAMILY_IDS["comparator_fixtures"][4:]
        observed_backend_ids: list[str] = []
        dimension_counts = {identifier: 0 for identifier in PRODUCT_DIMENSIONS}
        for identifier in synthetic_ids:
            fixture = comparators.get(identifier, {})
            inputs = fixture.get("inputs") if isinstance(fixture, dict) else None
            expected = fixture.get("expected") if isinstance(fixture, dict) else None
            if not isinstance(inputs, dict) or not isinstance(expected, dict):
                errors.append(f"R07 synthetic comparator {identifier} must be complete")
                continue
            backend_ids = inputs.get("fixture_backend_ids")
            if not isinstance(backend_ids, list) or len(backend_ids) != 1 or not isinstance(backend_ids[0], str) or not backend_ids[0]:
                errors.append(f"R07 synthetic comparator {identifier} backend nonvacuity differs")
                continue
            observed_backend_ids.extend(backend_ids)
            dimension = inputs.get("dimension")
            if dimension in dimension_counts:
                dimension_counts[dimension] += 1
            if dimension == "temporal_artifact":
                delta = inputs.get("baseline_temporal_risk_q16") - inputs.get("auto_temporal_risk_q16")
                passed = delta >= 1
            elif dimension == "chroma_displacement":
                delta = inputs.get("baseline_chroma_displacement_q8_pixels") - inputs.get("auto_chroma_displacement_q8_pixels")
                passed = delta >= 1
            elif dimension == "spatial_ms_ssim":
                delta = inputs.get("auto_ms_ssim_ppm") - inputs.get("baseline_ms_ssim_ppm")
                passed = delta >= -5000
            elif dimension == "protected_integrity":
                delta = inputs.get("auto_weighted_mae_q16") - inputs.get("baseline_weighted_mae_q16")
                passed = delta <= 0
            else:
                errors.append(f"R07 synthetic comparator {identifier} dimension differs")
                continue
            if inputs.get("backend_scope") != "synthetic_fixture_only" or inputs.get("comparison_record_count") != 1 or inputs.get("comparison_complete") is not True or expected.get("computed_delta") != delta or expected.get("passed") is not passed or expected.get("nonvacuous_requirement_satisfied") is not True or expected.get("fixture_comparison_executed") is not True or expected.get("product_comparison_execution") != "not_observed" or expected.get("product_qualification") != "not_claimed" or expected.get("claim") != "forbidden":
                errors.append(f"R07 synthetic comparator {identifier} equation/scope differs")
        if len(observed_backend_ids) != len(set(observed_backend_ids)) or any(
            count != 2 for count in dimension_counts.values()
        ):
            errors.append("R07 synthetic comparator backend uniqueness/dimension matrix differs")

    def check_preregistration(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            PREREGISTRATION_PATH, PREREGISTRATION_SCHEMA_PATH,
            "R07 preregistration", errors
        )
        if value is not None:
            self._check_predecessor(value, errors)
            self._check_preregistration_semantics(value, errors)
        return errors

    def check_fixtures(self) -> list[str]:
        errors: list[str] = []
        value = self._read_and_validate(
            FIXTURE_CATALOG_PATH, FIXTURE_CATALOG_SCHEMA_PATH,
            "R07 fixture catalog", errors
        )
        if value is not None:
            self._check_fixture_semantics(value, errors)
        return errors

    def _check_conformance_semantics(
        self, value: dict[str, Any], errors: list[str]
    ) -> None:
        errors.extend(_privacy_errors(value, "R07 conformance"))
        self._check_binding(value.get("preregistration_binding"), PREREGISTRATION_PATH, "preregistration_binding", errors)
        self._check_binding(value.get("fixture_catalog_binding"), FIXTURE_CATALOG_PATH, "fixture_catalog_binding", errors)
        source = value.get("source")
        if not isinstance(source, dict) or set(source) != {"commit", "tree"}:
            errors.append("R07 conformance source keys differ")
        else:
            commit, tree = source.get("commit"), source.get("tree")
            if not isinstance(commit, str) or not isinstance(tree, str) or self.git("cat-file", "-e", f"{commit}^{{commit}}").returncode != 0:
                errors.append("R07 conformance source commit is unavailable")
            else:
                observed = self.git("rev-parse", f"{commit}^{{tree}}")
                if observed.returncode != 0 or observed.stdout.strip() != tree:
                    errors.append("R07 conformance source tree differs")

    def check_conformance(self) -> list[str]:
        errors: list[str] = []
        schema = self._read_json(CONFORMANCE_SCHEMA_PATH, "R07 conformance schema", errors)
        target = self.root / CONFORMANCE_PATH
        if target.is_symlink() or target.exists() and not target.is_file():
            errors.append("R07 conformance must be a regular non-symlink file")
            return errors
        if not target.exists():
            self.conformance_materialized = False
            return errors
        self.conformance_materialized = True
        value = self._read_json(CONFORMANCE_PATH, "R07 conformance", errors)
        if value is not None and schema is not None:
            errors.extend(
                f"R07 conformance schema: {error}"
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
    explicit = any((arguments.check_preregistration, arguments.check_fixtures, arguments.check_conformance, arguments.all))
    check_all = arguments.all or not explicit
    verifier = R07ContractVerifier(REPOSITORY_ROOT)
    errors: list[str] = []
    if check_all or arguments.check_preregistration:
        errors.extend(verifier.check_preregistration())
    if check_all or arguments.check_fixtures:
        errors.extend(verifier.check_fixtures())
    if check_all or arguments.check_conformance:
        errors.extend(verifier.check_conformance())
    if not errors:
        if check_all or arguments.check_preregistration:
            print("R07 preregistration: PASS")
        if check_all or arguments.check_fixtures:
            print("R07 fixtures: PASS")
        if check_all or arguments.check_conformance:
            suffix = "" if verifier.conformance_materialized else " (not materialized; accepted preimplementation)"
            print(f"R07 conformance: PASS{suffix}")
    return emit_errors(errors)


if __name__ == "__main__":
    raise SystemExit(main())
