"""Versioned P07 identity and selected-evidence projections for P06 V3.

The P06 schema-2 candidate artifact intentionally does not contain the V1
per-fixture analytic, P00 invocation, or H07 performance records.  This module
therefore projects only fields that are present and independently
recomputable.  Callers must not manufacture V1 compatibility values.
"""

from __future__ import annotations

from collections.abc import Mapping
import math
from typing import Dict, Optional

from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


IDENTITY_FIELD = "p06_v2_identity"
IDENTITY_KEYS = (
    "calibration_plan_v2_file_sha256",
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "input_bundle_sha256",
    "p06_release_bundle_artifact_sha256",
    "selected_evaluation_file_sha256",
    "selected_evaluation_artifact_sha256",
    "selected_evaluation_semantic_sha256",
)
VALIDATION_OBJECTIVE_KEYS = (
    "y_vs_fixed_ci_low",
    "y_vs_non_ash_ci_low",
    "y_vs_conventional_ci_low",
    "mean_ms_ssim_delta_vs_conventional",
    "maximum_ringing_excursion",
    "maximum_alias_ratio",
    "estimated_dispatch_cost",
)


class P07ContractV2Error(ValueError):
    """A P07 schema-2 identity or exact evidence projection is invalid."""


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and value != "0" * 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _require_sha256(value: object, label: str) -> str:
    if not _is_sha256(value):
        raise P07ContractV2Error(f"{label} is not a nonzero lowercase SHA-256")
    return str(value)


def _evaluation_semantic_sha256_v2(evaluation: Mapping[str, object]) -> str:
    return canonical_sha256(evaluation)


def _candidate_evidence_sha256_v2(
    document: Mapping[str, object],
) -> str:
    if "evidence_sha256" not in document or "artifact_sha256" not in document:
        raise P07ContractV2Error("selected evaluation hash members are absent")
    return canonical_sha256(
        {
            key: value
            for key, value in document.items()
            if key not in {"evidence_sha256", "artifact_sha256"}
        }
    )


def _artifact_binding(
    bundle: Mapping[str, object],
    identifier: str,
) -> Mapping[str, object]:
    rows = bundle.get("artifacts")
    matches = [
        row
        for row in rows
        if isinstance(row, dict) and row.get("id") == identifier
    ] if isinstance(rows, list) else []
    if len(matches) != 1:
        raise P07ContractV2Error(
            f"P06 V3 release binding is not singular: {identifier}"
        )
    return matches[0]


def release_identity_v2(
    *,
    bundle: Mapping[str, object],
    selection: Mapping[str, object],
    evaluation: Mapping[str, object],
    compiler_input: Mapping[str, object],
) -> Mapping[str, str]:
    """Derive the exact non-cyclic P06 V2 identity consumed by P07."""

    if (
        bundle.get("schema_version") != "3.0.1"
        or bundle.get("artifact_kind") != "p06_release_bundle_v3"
        or bundle.get("bundle_id") != "mirmir-p06-spatial-release-lock-v3"
        or selection.get("schema_version") != "2.0.2"
        or evaluation.get("schema_version") != "2.0.3"
        or compiler_input.get("schema_version") != "2.0.0"
    ):
        raise P07ContractV2Error("P06 V3/V2 identity family differs")
    selected = selection.get("selected")
    compiler_bindings = compiler_input.get("hash_bindings")
    if not isinstance(selected, dict) or not isinstance(compiler_bindings, dict):
        raise P07ContractV2Error("P06 V2 selected or compiler identity is absent")
    evaluation_binding = _artifact_binding(bundle, "selected_evaluation")
    release_hash = _require_sha256(
        bundle.get("artifact_sha256"),
        "P06 V3 release artifact",
    )
    if release_hash != canonical_sha256(
        {
            key: value
            for key, value in bundle.items()
            if key != "artifact_sha256"
        }
    ):
        raise P07ContractV2Error("P06 V3 release self-hash differs")
    evaluation_artifact_hash = _require_sha256(
        evaluation.get("artifact_sha256"),
        "selected evaluation artifact",
    )
    if evaluation_artifact_hash != canonical_sha256(
        {
            key: value
            for key, value in evaluation.items()
            if key != "artifact_sha256"
        }
    ):
        raise P07ContractV2Error("selected evaluation self-hash differs")
    semantic_hash = _require_sha256(
        evaluation.get("evaluation_semantic_sha256"),
        "selected evaluation semantic identity",
    )
    evaluation_value = evaluation.get("evaluation")
    if (
        not isinstance(evaluation_value, dict)
        or semantic_hash != _evaluation_semantic_sha256_v2(evaluation_value)
        or evaluation.get("evidence_sha256")
        != _candidate_evidence_sha256_v2(evaluation)
    ):
        raise P07ContractV2Error("selected evaluation semantic evidence differs")
    identity = {
        "calibration_plan_v2_file_sha256": _require_sha256(
            compiler_bindings.get("calibration_plan_sha256"),
            "calibration plan V2 file",
        ),
        "candidate_vector_sha256": _require_sha256(
            evaluation.get("candidate_vector_sha256"),
            "candidate vector",
        ),
        "shared_bank_configuration_sha256": _require_sha256(
            evaluation.get("shared_bank_configuration_sha256"),
            "shared bank",
        ),
        "input_bundle_sha256": _require_sha256(
            bundle.get("input_bundle_sha256"),
            "P06 V2 input bundle",
        ),
        "p06_release_bundle_artifact_sha256": release_hash,
        "selected_evaluation_file_sha256": _require_sha256(
            evaluation_binding.get("sha256"),
            "selected evaluation file",
        ),
        "selected_evaluation_artifact_sha256": evaluation_artifact_hash,
        "selected_evaluation_semantic_sha256": semantic_hash,
    }
    if (
        selected.get("candidate_vector_sha256")
        != identity["candidate_vector_sha256"]
        or selected.get("evaluation_semantic_sha256")
        != identity["selected_evaluation_semantic_sha256"]
        or selection.get("shared_bank_configuration_sha256")
        != identity["shared_bank_configuration_sha256"]
        or bundle.get("shared_bank_configuration_sha256")
        != identity["shared_bank_configuration_sha256"]
    ):
        raise P07ContractV2Error("P06 selected identity cross-link differs")
    return identity


def validate_identity_v2(
    value: object,
    *,
    expected: Optional[Mapping[str, str]] = None,
) -> Mapping[str, str]:
    if not isinstance(value, dict) or set(value) != set(IDENTITY_KEYS):
        raise P07ContractV2Error("P07 V2 identity field set differs")
    identity: Dict[str, str] = {
        key: _require_sha256(value.get(key), f"P07 V2 identity {key}")
        for key in IDENTITY_KEYS
    }
    if expected is not None and dict(identity) != dict(expected):
        raise P07ContractV2Error("P07 V2 identity differs from the release")
    return identity


def selected_evaluation_projection_v2(
    evaluation: Mapping[str, object],
    *,
    identity: Mapping[str, str],
) -> Mapping[str, object]:
    """Project only exact candidate-evaluation-v2 fields required by P07."""

    validate_identity_v2(identity)
    if (
        evaluation.get("schema_version") != "2.0.3"
        or evaluation.get("split") != "validation"
        or evaluation.get("evaluation_status") != "feasible"
        or evaluation.get("candidate_vector_sha256")
        != identity["candidate_vector_sha256"]
        or evaluation.get("shared_bank_configuration_sha256")
        != identity["shared_bank_configuration_sha256"]
        or evaluation.get("artifact_sha256")
        != identity["selected_evaluation_artifact_sha256"]
        or evaluation.get("evaluation_semantic_sha256")
        != identity["selected_evaluation_semantic_sha256"]
    ):
        raise P07ContractV2Error("selected evaluation is not the feasible V2 release")
    evaluation_value = evaluation.get("evaluation")
    checks = evaluation.get("checks")
    if (
        not isinstance(evaluation_value, dict)
        or evaluation_value.get("feasible") is not True
        or evaluation_value.get("failure_reasons") != []
        or not isinstance(checks, list)
        or not checks
        or any(
            not isinstance(check, dict)
            or set(check) != {"check_id", "status", "evidence_sha256"}
            or not isinstance(check.get("check_id"), str)
            or not check.get("check_id")
            or check.get("status") != "pass"
            or not _is_sha256(check.get("evidence_sha256"))
            for check in checks
        )
    ):
        raise P07ContractV2Error("selected V2 checks or feasibility differ")
    objective = evaluation_value.get("objective")
    if (
        not isinstance(objective, dict)
        or set(objective) != set(VALIDATION_OBJECTIVE_KEYS)
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in objective.values()
        )
    ):
        raise P07ContractV2Error("selected V2 objective is absent")
    return {
        "schema_version": "2.0.0",
        "artifact_kind": "p07_selected_p06_evidence_projection_v2",
        IDENTITY_FIELD: dict(identity),
        "evaluation_status": "feasible",
        "objective": dict(objective),
        "checks": [dict(check) for check in checks],
        "runtime_evidence_sha256": _require_sha256(
            evaluation.get("runtime_evidence_sha256"),
            "selected runtime evidence",
        ),
        "complete_evidence_sha256": _require_sha256(
            evaluation.get("evidence_sha256"),
            "selected complete evidence",
        ),
    }


def validate_selected_evaluation_projection_v2(
    value: object,
    *,
    identity: Mapping[str, str],
) -> Mapping[str, object]:
    """Validate a persisted exact projection without reopening holdout data."""

    expected_fields = {
        "schema_version",
        "artifact_kind",
        IDENTITY_FIELD,
        "evaluation_status",
        "objective",
        "checks",
        "runtime_evidence_sha256",
        "complete_evidence_sha256",
    }
    if not isinstance(value, dict) or set(value) != expected_fields:
        raise P07ContractV2Error("selected P06 projection field set differs")
    if (
        value.get("schema_version") != "2.0.0"
        or value.get("artifact_kind")
        != "p07_selected_p06_evidence_projection_v2"
        or value.get("evaluation_status") != "feasible"
    ):
        raise P07ContractV2Error("selected P06 projection version differs")
    validate_identity_v2(value.get(IDENTITY_FIELD), expected=identity)
    objective = value.get("objective")
    checks = value.get("checks")
    if (
        not isinstance(objective, dict)
        or set(objective) != set(VALIDATION_OBJECTIVE_KEYS)
        or any(
            isinstance(item, bool)
            or not isinstance(item, (int, float))
            or not math.isfinite(float(item))
            for item in objective.values()
        )
        or not isinstance(checks, list)
        or not checks
        or any(
            not isinstance(check, dict)
            or set(check) != {"check_id", "status", "evidence_sha256"}
            or not isinstance(check.get("check_id"), str)
            or not check.get("check_id")
            or check.get("status") != "pass"
            or not _is_sha256(check.get("evidence_sha256"))
            for check in checks
        )
    ):
        raise P07ContractV2Error("selected P06 objective or checks differ")
    _require_sha256(
        value.get("runtime_evidence_sha256"),
        "selected P06 runtime evidence",
    )
    _require_sha256(
        value.get("complete_evidence_sha256"),
        "selected P06 complete evidence",
    )
    return value


__all__ = [
    "IDENTITY_FIELD",
    "IDENTITY_KEYS",
    "P07ContractV2Error",
    "release_identity_v2",
    "selected_evaluation_projection_v2",
    "validate_identity_v2",
    "validate_selected_evaluation_projection_v2",
]
