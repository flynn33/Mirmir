from __future__ import annotations

import copy
from typing import Any

from validation.calibration_v2.reference import lut_oracle_v2 as oracle


def locked_compiler_input_v2_document() -> dict[str, Any]:
    denominator = 16
    penalty_table = [
        ((65535 * denominator) + ((denominator + index) // 2))
        // (denominator + index)
        for index in range(256)
    ]
    document: dict[str, Any] = {
        "schema_version": "2.0.0",
        "status": "locked",
        "configuration_id": "format-1.2-cross-language-parity-001",
        "hash_bindings": {
            "mapping_sha256": "1" * 64,
            "operator_bank_sha256": "2" * 64,
            "metric_policy_sha256": "3" * 64,
            "compiler_inputs_sha256": "4" * 64,
            "calibration_plan_sha256": "5" * 64,
            "corpus_lock_bundle_sha256": "6" * 64,
        },
        "canonicalization": copy.deepcopy(oracle.CANONICALIZATION),
        "boundary_mode": "mirror_reflect101",
        "operator_parameters": {
            "minimum_anisotropic_magnitude_unorm15": 1638,
            "minimum_anisotropic_coherence_unorm15": 4915,
            "detail_gain_q12": 768,
            "relaxed_limiter_alpha_q12": 256,
            "risk_detail_suppression_unorm15": 21299,
            "low_pass_radius_q8_8": 512,
            "weight_epsilon_f32_bits": 730643660,
        },
        "semantic_steps": {
            "orientation_sector_step": 1,
            "support_radius_step_q8_8": 64,
            "detail_gain_step_q12": 128,
            "regularization_step_q12": 64,
        },
        "compiler_policy": {
            "penalty_decay_denominator": denominator,
            "penalty_to_weight_unorm16": penalty_table,
            "penalty_orientation_step": 4,
            "penalty_support_step": 8,
            "penalty_detail_step": 8,
            "penalty_regularization_step": 8,
            "penalty_unsupported_support_expansion": 32,
            "penalty_coherent_support_reduction": 16,
            "penalty_unsupported_detail_increase": 32,
            "penalty_supported_detail_reduction": 16,
            "penalty_relaxation_under_risk": 64,
            "penalty_phase_kernel_mismatch": 8,
            "confidence_threshold_unorm16": 16384,
        },
        "routes": {
            "direct_2x": {
                "route_spatial_policy_id": 7,
                "luma_anisotropy_mode_ordinal": 1,
                "chroma_anisotropy_mode_ordinal": 4,
                "luma_coordinate_policy": "source_aligned_rational",
                "chroma_coordinate_policy": "half_pixel_center",
                "analysis_grid_source_step": 1,
            },
            "direct_3_over_2": {
                "route_spatial_policy_id": 16,
                "luma_anisotropy_mode_ordinal": 0,
                "chroma_anisotropy_mode_ordinal": 5,
                "luma_coordinate_policy": "half_pixel_center",
                "chroma_coordinate_policy": "source_aligned_rational",
                "analysis_grid_source_step": 2,
            },
        },
        "temporal": copy.deepcopy(oracle.TEMPORAL_CONTRACT),
        "source_aligned": copy.deepcopy(oracle.SOURCE_ALIGNED_CONTRACT),
        "top_two": 2,
    }
    document["hash_bindings"]["compiler_inputs_sha256"] = (
        oracle.canonical_compiler_input_sha256_v2(document)
    )
    return document


def rehash(document: dict[str, Any]) -> None:
    document["hash_bindings"]["compiler_inputs_sha256"] = (
        oracle.canonical_compiler_input_sha256_v2(document)
    )
