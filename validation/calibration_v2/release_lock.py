"""Fail-closed builders and validators for the immutable P06 release lock.

This module does not select a calibration candidate.  It accepts only artifacts
already selected and produced by the calibrated Swift/reference compiler path,
then cross-binds their exact bytes for the P07 read-only boundary.
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
from typing import Mapping, MutableMapping, Sequence

from validation.calibration_v2.reference.lut_oracle import (
    ROUTES,
    LockedCompilerInput,
    ValidatedLUT,
    canonical_compiler_input_sha256,
    load_locked_compiler_input,
    parse_locked_compiler_input,
    validate_lut,
)
from validation.quality.src.mirmir_quality.json_tools import validate_schema
from validation.quality.src.mirmir_quality.holdout import (
    HashBinding,
    hash_binding_digest,
)
from validation.calibration_v2.release_evidence import (
    IMPLEMENTATION_IDS,
    P00_FAILURE_ID,
    SCHEMA as P06_EVIDENCE_CLOSURE_SCHEMA,
    SELECTED_CONTROL_IDS,
    SUPPORT_TREE_IDS,
    TEST_EVIDENCE_IDS,
    evidence_binding,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"
LUT_CONTRACT_PATH = Path(
    "validation/calibration_v2/contracts/lut-binary-contract-v1.json"
)
LUT_MANIFEST_SCHEMA = SCHEMAS_ROOT / "lut-manifest-v2.schema.json"
NATIVE_PARITY_SCHEMA = SCHEMAS_ROOT / "native-parity-manifest-v1.schema.json"
NATIVE_PARITY_FAILURE_SCHEMA = (
    SCHEMAS_ROOT / "native-parity-failure-v1.schema.json"
)
VIDEO_MAPPING_SCHEMA = SCHEMAS_ROOT / "video-mapping-v1.schema.json"
OPERATOR_BANK_SCHEMA = SCHEMAS_ROOT / "operator-bank-v1.schema.json"
VIDEO_MAPPING_V2_SCHEMA = SCHEMAS_ROOT / "video-mapping-v2.schema.json"
OPERATOR_BANK_V2_SCHEMA = SCHEMAS_ROOT / "operator-bank-v2.schema.json"
LOCKED_COMPILER_INPUT_SCHEMA = (
    SCHEMAS_ROOT / "locked-compiler-input-v1.schema.json"
)
DISPATCH_MEASUREMENT_SCHEMA = (
    SCHEMAS_ROOT / "dispatch-measurement-v1.schema.json"
)
LOCKED_METRIC_POLICY_SCHEMA = (
    SCHEMAS_ROOT / "locked-metric-policy-v2.schema.json"
)
LOCKED_QUALITY_POLICY_SCHEMA = (
    SCHEMAS_ROOT / "locked-quality-policy-v1.schema.json"
)
BASELINE_ABLATION_CONTRACT_SCHEMA = (
    SCHEMAS_ROOT / "baseline-ablation-contract-v1.schema.json"
)
P06_RELEASE_BUNDLE_SCHEMA = (
    SCHEMAS_ROOT / "p06-release-bundle-v2.schema.json"
)
P06_RELEASE_BUNDLE_V3_SCHEMA = (
    SCHEMAS_ROOT / "p06-release-bundle-v3.schema.json"
)
CONFIGURATION_LOCK_V2_SCHEMA = (
    SCHEMAS_ROOT / "p06-configuration-lock-v2.schema.json"
)
ROUTE_SELECTION_SCHEMA = (
    SCHEMAS_ROOT / "route-analysis-grid-selection-v1.schema.json"
)
CONFIGURATION_LOCK_SCHEMA = (
    CALIBRATION_ROOT.parent / "quality" / "schemas" / "configuration-lock.schema.json"
)
CALIBRATION_SELECTION_SCHEMA = (
    SCHEMAS_ROOT / "calibration-selection-v1.schema.json"
)
CALIBRATION_SELECTION_V2_SCHEMA = (
    SCHEMAS_ROOT / "calibration-selection-v2.schema.json"
)
CALIBRATION_RUN_LEDGER_SCHEMA = (
    SCHEMAS_ROOT / "calibration-run-ledger-v1.schema.json"
)
CALIBRATION_RUN_LEDGER_V2_SCHEMA = (
    SCHEMAS_ROOT / "calibration-run-ledger-v2.schema.json"
)
CANDIDATE_EVALUATION_SCHEMA = (
    SCHEMAS_ROOT / "candidate-evaluation-v1.schema.json"
)
CANDIDATE_EVALUATION_V2_SCHEMA = (
    SCHEMAS_ROOT / "candidate-evaluation-v2.schema.json"
)
P06_EVIDENCE_CLOSURE_V2_SCHEMA = (
    SCHEMAS_ROOT / "p06-evidence-closure-v2.schema.json"
)
VALIDATION_ADMISSION_V2_SCHEMA = (
    SCHEMAS_ROOT / "validation-candidate-development-evidence-v2.schema.json"
)
NON_ASH_ATTEMPT_LEDGER_V2_SCHEMA = (
    SCHEMAS_ROOT / "non-ash-selector-attempt-ledger-v2.schema.json"
)
NON_ASH_SELECTION_V2_SCHEMA = (
    SCHEMAS_ROOT / "non-ash-selector-selection-v2.schema.json"
)
NON_ASH_NEIGHBOR_MANIFEST_V2_SCHEMA = (
    SCHEMAS_ROOT / "non-ash-validation-neighbor-manifest-v2.schema.json"
)
BASELINE_ABLATION_BUDGET_V2_SCHEMA = (
    SCHEMAS_ROOT / "baseline-ablation-budget-v2.schema.json"
)
BASELINE_ABLATION_BUDGET_V2_PATH = (
    CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
)
LOCKED_QUALITY_POLICY_V2_SCHEMA = (
    SCHEMAS_ROOT / "p06-locked-quality-policy-v2.schema.json"
)
NATIVE_PARITY_V3_SCHEMA = (
    SCHEMAS_ROOT / "native-parity-manifest-v3.schema.json"
)
LUT_MANIFEST_V3_SCHEMA = SCHEMAS_ROOT / "lut-manifest-v3.schema.json"
RUN_ARTIFACT_MANIFEST_V2_SCHEMA = (
    SCHEMAS_ROOT / "evidence-wrapper-artifact-manifest-v2.schema.json"
)
CONTROL_AUTHORIZATION_BUNDLE_V2_SCHEMA = (
    SCHEMAS_ROOT / "p06-control-authorization-bundle-v2.schema.json"
)
CORPUS_LOCK_PATH = CALIBRATION_ROOT.parent / "quality/locks/corpus-lock.json"
CORPUS_LOCK_SCHEMA = CALIBRATION_ROOT.parent / "quality/schemas/corpus-lock.schema.json"
LOCKED_COMPILER_INPUT_V2_SCHEMA = (
    SCHEMAS_ROOT / "locked-compiler-input-v2.schema.json"
)
CANDIDATE_RUNTIME_MANIFEST_V2_SCHEMA = (
    SCHEMAS_ROOT / "candidate-lut-runtime-manifest-v2.schema.json"
)
LIVE_HOLDOUT_PREOPEN_VERIFICATION_SCHEMA = (
    SCHEMAS_ROOT / "live-holdout-preopen-verification-v1.schema.json"
)

_PARAMETER_ORDER_LENGTH = 42
_THRESHOLD_BANDS = (
    "edge_present",
    "coherent_structure",
    "texture_high_frequency",
    "alias_or_ringing_risk",
    "chroma_luma_structure_aligned",
)
_SHARED_BANK_COORDINATES = (
    "analysis_epsilon_q0_30",
    "risk_laplacian_weight_unorm15",
    "chroma_edge_confidence_unorm15",
    "direct_2x_analysis_grid_source_step",
    "direct_3_over_2_analysis_grid_source_step",
    "direct_2x_luma_coordinate_policy",
    "direct_2x_chroma_coordinate_policy",
    "direct_3_over_2_luma_coordinate_policy",
    "direct_3_over_2_chroma_coordinate_policy",
    "boundary_mode",
    "anisotropy_strength_q12",
    "minimum_anisotropic_magnitude_unorm15",
    "minimum_anisotropic_coherence_unorm15",
    "detail_gain_q12",
    "relaxed_limiter_alpha_q12",
    "risk_detail_suppression_unorm15",
    "low_pass_radius_q8_8",
)
_RELEASE_ARTIFACTS = (
    ("calibration_selection", "calibration-selection.json"),
    ("selected_evaluation", None),
    ("calibration_run_ledger", "calibration-run-ledger.json"),
    (
        "live_holdout_preopen_verification",
        "live-holdout-preopen-verification.json",
    ),
    ("dispatch_measurement", "dispatch-measurement.json"),
    ("locked_mapping", "locked-mapping.json"),
    ("locked_operator_bank", "locked-operator-bank.json"),
    ("locked_quality_policy", "locked-quality-policy.json"),
    ("locked_metric_policy", "locked-metric-policy.json"),
    ("locked_compiler_input", "locked-compiler-input.json"),
    ("route_analysis_grid_selection", "route-analysis-grid-selection.json"),
    ("direct2x_lut", "direct2x.ashlut"),
    ("direct3over2_lut", "direct3over2.ashlut"),
    ("native_parity_manifest", "native-lut-parity-manifest.json"),
    ("lut_manifest", "lut-manifest.json"),
    ("configuration_lock", "configuration-lock.json"),
    ("evidence_closure", "p06-evidence-closure.json"),
)
_RELEASE_ARTIFACTS_V3 = (
    ("calibration_selection", "calibration-selection-v2.json"),
    ("selected_evaluation", None),
    ("calibration_run_ledger", "calibration-run-ledger-v2.json"),
    (
        "validation_candidate_development_evidence",
        "validation-candidate-development-evidence-v2.json",
    ),
    ("calibration_attempt_ledger", "attempts-v2.ndjson"),
    (
        "non_ash_development_attempt_ledger",
        "non-ash-selector-development-attempt-ledger-v2.json",
    ),
    (
        "non_ash_development_selection",
        "non-ash-selector-development-selection-v2.json",
    ),
    (
        "non_ash_validation_neighbor_manifest",
        "non-ash-validation-neighbor-manifest-v2.json",
    ),
    (
        "non_ash_validation_selection",
        "non-ash-selector-validation-selection-v2.json",
    ),
    ("baseline_ablation_budget_v2", "baseline-ablation-budget-v2.json"),
    (
        "live_holdout_preopen_verification",
        "live-holdout-preopen-verification.json",
    ),
    ("locked_mapping", "locked-mapping.json"),
    ("locked_operator_bank", "locked-operator-bank.json"),
    ("locked_quality_policy", "locked-quality-policy.json"),
    ("locked_metric_policy", "locked-metric-policy.json"),
    ("locked_compiler_input_v2", "locked-compiler-input-v2.json"),
    ("direct2x_lut", "direct2x.ashlut"),
    ("direct3over2_lut", "direct3over2.ashlut"),
    ("native_parity_manifest", "native-lut-parity-manifest-v3.json"),
    ("lut_manifest", "lut-manifest-v3.json"),
    ("configuration_lock", "configuration-lock-v2.json"),
    ("evidence_closure", "p06-evidence-closure-v2.json"),
    ("artifact_manifest", "artifact-manifest-v2.json"),
)
_P06_RELEASE_BUNDLE_NAME = "p06-release-bundle.json"
P06_TRANSACTION_TOKEN_NAME = ".p06-release-transaction-token"
_P06_FILESYSTEM_CLOSURE_RULE = "all_entries_except_self_manifest_v1"
P06_RELEASE_SELF_MANIFEST_EXCLUSIONS = frozenset(
    {_P06_RELEASE_BUNDLE_NAME}
)
_SUPPORT_TREE_ROOT_IDS = (
    "open_split",
    "calibration_evidence",
    "native_cache",
    "production_writer",
    "dispatch_measurement",
)
CALIBRATION_RUN_SUPPORT_ROOT_ID = "calibration_run"
P06_SUPPORT_EVIDENCE_ROOT_IDS = frozenset(
    (*_SUPPORT_TREE_ROOT_IDS, CALIBRATION_RUN_SUPPORT_ROOT_ID)
)
_CONFIGURATION_LOCK_HASH_FIELDS = (
    "mapping_sha256",
    "operator_bank_sha256",
    "quality_policy_sha256",
    "metric_policy_sha256",
    "metric_implementation_sha256",
    "metric_conformance_sha256",
    "degradation_policy_sha256",
    "actual_codec_fixture_sha256",
    "actual_codec_evidence_sha256",
    "quality_harness_implementation_manifest_sha256",
    "compiler_inputs_sha256",
    "route_luts_sha256",
    "corpus_manifest_sha256",
)
_DISPATCH_METHOD = {
    "control": (
        "reconstruct identical output from the full run's precomputed immutable "
        "dispatch grid"
    ),
    "full": "form immutable LUT dispatch grid then reconstruct",
    "overhead_percent": (
        "100 * (full_dispatch_milliseconds / "
        "control_reconstruction_milliseconds)"
    ),
    "ordering": (
        "alternate full_then_control and control_then_full by repetition index"
    ),
    "percentile": "ascending values with linear interpolation at (n-1)*0.95",
    "repetitions_per_sample": 10,
    "warmup_repetitions_per_sample": 3,
}
_DISPATCH_INPUT_BINDING_FIELDS = (
    "configuration_id",
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "compiler_inputs_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
    "validation_sample_lock_sha256",
    "degradation_policy_sha256",
    "raw_output_contract_sha256",
    "full_control_configuration_sha256",
)
_SELECTED_CONTROL_NAMES = (
    "best_fixed",
    "conventional",
    "non_ash_selector",
    "state_only",
    "state_plus_branch",
    "h07_direct_3_over_2",
    "nearest_same_writer",
    "current_production_ash",
)


class ReleaseLockError(ValueError):
    """A release input, identity, or publication invariant was rejected."""


class NativeParityMismatch(ReleaseLockError):
    """Two independently produced valid LUTs differed byte-for-byte."""

    def __init__(
        self,
        *,
        route: str,
        first_differing_byte_offset: int,
        failure_path: Path,
    ) -> None:
        self.route = route
        self.first_differing_byte_offset = first_differing_byte_offset
        self.failure_path = failure_path
        super().__init__(
            "native LUT parity mismatch for "
            f"{route} at byte {first_differing_byte_offset}; "
            f"evidence preserved at {failure_path}"
        )


def _reject_duplicate_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseLockError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_strict_json(path: Path) -> Mapping[str, object]:
    payload = _read_regular_file(path)
    try:
        document = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ReleaseLockError(f"non-finite JSON number: {value}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseLockError(f"invalid JSON: {path}") from error
    if not isinstance(document, dict):
        raise ReleaseLockError(f"JSON top level is not an object: {path}")
    return document


def _read_regular_file(path: Path) -> bytes:
    try:
        resolved_parent = path.parent.resolve(strict=True)
    except OSError as error:
        raise ReleaseLockError(f"file parent cannot be resolved: {path}") from error
    absolute = resolved_parent / path.name
    try:
        before = os.stat(absolute, follow_symlinks=False)
    except OSError as error:
        raise ReleaseLockError(f"file cannot be inspected: {path}") from error
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise ReleaseLockError(f"path is symbolic or not a regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(absolute, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino)
            != (before.st_dev, before.st_ino)
        ):
            raise ReleaseLockError(f"file changed while opening: {path}")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = os.stat(absolute, follow_symlinks=False)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or (current.st_dev, current.st_ino)
        != (before.st_dev, before.st_ino)
        or not stat.S_ISREG(current.st_mode)
        or after.st_nlink != 1
        or current.st_nlink != 1
        or after.st_size != before.st_size
        or current.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or current.st_mtime_ns != before.st_mtime_ns
    ):
        raise ReleaseLockError(f"file changed while reading: {path}")
    return b"".join(chunks)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _require_sha256(value: str, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or value == "0" * 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ReleaseLockError(f"{label} is not a nonzero lowercase SHA-256")
    return value


def _require_utc_timestamp(value: str, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) < 20
        or value[4] != "-"
        or value[7] != "-"
        or value[10] != "T"
        or value[13] != ":"
        or value[16] != ":"
        or not value.endswith("Z")
    ):
        raise ReleaseLockError(f"{label} is not a canonical UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ReleaseLockError(
            f"{label} is not a canonical UTC timestamp"
        ) from error
    if parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        raise ReleaseLockError(f"{label} is not UTC")
    return value


def _canonical_bytes(document: object) -> bytes:
    try:
        return json.dumps(
            document,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ReleaseLockError("document is not canonical finite JSON") from error


def _manifest_sha256(document: Mapping[str, object]) -> str:
    unhashed = dict(document)
    unhashed.pop("manifest_sha256", None)
    return _sha256(_canonical_bytes(unhashed))


def _artifact_sha256(document: Mapping[str, object]) -> str:
    unhashed = dict(document)
    unhashed.pop("artifact_sha256", None)
    return _sha256(_canonical_bytes(unhashed))


def p06_release_bundle_sha256(document: Mapping[str, object]) -> str:
    """Return the authenticated self-hash for exactly one supported bundle family."""

    if (
        document.get("schema_version") == "3.0.1"
        and document.get("bundle_id") == "mirmir-p06-spatial-release-lock-v3"
    ):
        value = document.get("artifact_sha256")
        if value != _artifact_sha256(document):
            raise ReleaseLockError("P06 V3 release bundle self-hash mismatch")
        return str(value)
    if (
        document.get("schema_version") == "2.0.0"
        and document.get("bundle_id") == "mirmir-p06-spatial-release-lock-v2"
    ):
        value = document.get("manifest_sha256")
        if value != _manifest_sha256(document):
            raise ReleaseLockError("P06 V2 release bundle self-hash mismatch")
        return str(value)
    raise ReleaseLockError("historical or unknown P06 release bundle version")


def candidate_vector_sha256_for_plan(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> str:
    search = plan.get("search")
    if not isinstance(search, dict):
        raise ReleaseLockError("calibration plan search is absent")
    order = search.get("parameter_order")
    if (
        not isinstance(order, list)
        or len(order) != _PARAMETER_ORDER_LENGTH
        or len(set(order)) != len(order)
        or set(vector) != set(order)
    ):
        raise ReleaseLockError("candidate vector does not exactly match parameter order")
    return _sha256(_canonical_bytes([vector[name] for name in order]))


def shared_bank_configuration_sha256_for_plan(
    vector: Mapping[str, object],
    plan: Mapping[str, object],
) -> str:
    candidate_vector_sha256_for_plan(vector, plan)
    if any(name not in vector for name in _SHARED_BANK_COORDINATES):
        raise ReleaseLockError("candidate vector lacks a shared-bank coordinate")
    return _sha256(
        _canonical_bytes(
            {name: vector[name] for name in _SHARED_BANK_COORDINATES}
        )
    )


def _selection_binding(
    *,
    status: str,
    calibration_selection_sha256: str | None,
    selected_evaluation_sha256: str | None,
) -> Mapping[str, object]:
    if status == "calibration_candidate":
        if calibration_selection_sha256 is not None or selected_evaluation_sha256 is not None:
            raise ReleaseLockError("candidate mapping/operator cannot claim selection hashes")
    elif status == "locked_before_p07":
        if calibration_selection_sha256 is None or selected_evaluation_sha256 is None:
            raise ReleaseLockError("locked mapping/operator require both selection hashes")
        _require_sha256(calibration_selection_sha256, "calibration selection SHA-256")
        _require_sha256(selected_evaluation_sha256, "selected evaluation SHA-256")
    else:
        raise ReleaseLockError("mapping/operator status is invalid")
    return {
        "calibration_selection_sha256": calibration_selection_sha256,
        "selected_evaluation_sha256": selected_evaluation_sha256,
    }


def video_mapping_document(
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    configuration_id: str,
    mapping_seed_sha256: str,
    status: str,
    calibration_selection_sha256: str | None = None,
    selected_evaluation_sha256: str | None = None,
) -> Mapping[str, object]:
    """Project one exact candidate vector into the Swift-consumed mapping bytes."""

    vector_hash = candidate_vector_sha256_for_plan(vector, plan)
    shared_bank_hash = shared_bank_configuration_sha256_for_plan(vector, plan)
    thresholds: dict[str, object] = {
        name: {
            "low": vector[f"{name}_low_unorm15"],
            "high": vector[f"{name}_high_unorm15"],
        }
        for name in _THRESHOLD_BANDS
    }
    thresholds["temporal_support_valid"] = {"low": 32767, "high": 32767}
    for name in _THRESHOLD_BANDS:
        band = thresholds[name]
        assert isinstance(band, dict)
        low = band["low"]
        high = band["high"]
        if (
            not isinstance(low, int)
            or isinstance(low, bool)
            or not isinstance(high, int)
            or isinstance(high, bool)
            or high - low < 3277
        ):
            raise ReleaseLockError(f"mapping threshold pair is invalid: {name}")
    laplacian = vector["risk_laplacian_weight_unorm15"]
    if not isinstance(laplacian, int) or isinstance(laplacian, bool):
        raise ReleaseLockError("risk Laplacian weight is not integral")
    document: Mapping[str, object] = {
        "schema_version": "1.0.0",
        "status": status,
        "mapping_id": "ash-video-mapping-v2",
        "configuration_id": configuration_id,
        "mapping_seed_sha256": _require_sha256(
            mapping_seed_sha256,
            "mapping seed SHA-256",
        ),
        "candidate_vector_sha256": vector_hash,
        "shared_bank_configuration_sha256": shared_bank_hash,
        "selection_binding": _selection_binding(
            status=status,
            calibration_selection_sha256=calibration_selection_sha256,
            selected_evaluation_sha256=selected_evaluation_sha256,
        ),
        "canonical_core_unchanged": True,
        "input_contract": {
            "bit_depth": 8,
            "chroma_siting": "left",
            "matrix": "BT.709",
            "pixel_format": "420v",
            "range": "video",
            "subsampling": "4:2:0",
        },
        "boundary_mode": vector["boundary_mode"],
        "analysis_grid_source_steps": {
            "direct_2x": vector["direct_2x_analysis_grid_source_step"],
            "direct_3_over_2": vector[
                "direct_3_over_2_analysis_grid_source_step"
            ],
        },
        "thresholds_unorm15": thresholds,
        "analysis_epsilon_q0_30": vector["analysis_epsilon_q0_30"],
        "risk_weights_unorm15": {
            "laplacian": laplacian,
            "alternating_difference": 32767 - laplacian,
        },
        "chroma_edge_confidence_unorm15": vector[
            "chroma_edge_confidence_unorm15"
        ],
    }
    validate_schema(document, VIDEO_MAPPING_SCHEMA)
    return document


def operator_bank_document(
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    configuration_id: str,
    operator_bank_seed_sha256: str,
    status: str,
    calibration_selection_sha256: str | None = None,
    selected_evaluation_sha256: str | None = None,
) -> Mapping[str, object]:
    """Project one exact candidate vector into the Swift-consumed bank bytes."""

    vector_hash = candidate_vector_sha256_for_plan(vector, plan)
    shared_bank_hash = shared_bank_configuration_sha256_for_plan(vector, plan)
    document: Mapping[str, object] = {
        "schema_version": "1.0.0",
        "status": status,
        "operator_bank_id": "ash-spatial-operator-bank-v2",
        "configuration_id": configuration_id,
        "operator_bank_seed_sha256": _require_sha256(
            operator_bank_seed_sha256,
            "operator-bank seed SHA-256",
        ),
        "candidate_vector_sha256": vector_hash,
        "shared_bank_configuration_sha256": shared_bank_hash,
        "selection_binding": _selection_binding(
            status=status,
            calibration_selection_sha256=calibration_selection_sha256,
            selected_evaluation_sha256=selected_evaluation_sha256,
        ),
        "boundary_mode": vector["boundary_mode"],
        "coordinate_policies": {
            "direct_2x": {
                "luma_coordinate_policy": vector[
                    "direct_2x_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_2x_chroma_coordinate_policy"
                ],
            },
            "direct_3_over_2": {
                "luma_coordinate_policy": vector[
                    "direct_3_over_2_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_3_over_2_chroma_coordinate_policy"
                ],
            },
        },
        "operator_parameters": {
            "anisotropy_strength_q12": vector["anisotropy_strength_q12"],
            "minimum_anisotropic_magnitude_unorm15": vector[
                "minimum_anisotropic_magnitude_unorm15"
            ],
            "minimum_anisotropic_coherence_unorm15": vector[
                "minimum_anisotropic_coherence_unorm15"
            ],
            "detail_gain_q12": vector["detail_gain_q12"],
            "relaxed_limiter_alpha_q12": vector[
                "relaxed_limiter_alpha_q12"
            ],
            "risk_detail_suppression_unorm15": vector[
                "risk_detail_suppression_unorm15"
            ],
            "low_pass_radius_q8_8": vector["low_pass_radius_q8_8"],
            "weight_epsilon_f32_bits": 730643660,
        },
        "semantic_steps": {
            "orientation_sector_step": 1,
            "support_radius_step_q8_8": vector["support_radius_step_q8_8"],
            "detail_gain_step_q12": vector["detail_gain_step_q12"],
            "regularization_step_q12": vector["regularization_step_q12"],
        },
    }
    validate_schema(document, OPERATOR_BANK_SCHEMA)
    return document


def locked_compiler_input_document(
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    configuration_id: str,
    mapping_sha256: str,
    operator_bank_sha256: str,
    metric_policy_sha256: str,
    calibration_plan_sha256: str,
    corpus_lock_bundle_sha256: str,
) -> Mapping[str, object]:
    """Create the exact self-hashed input consumed by both LUT compilers."""

    candidate_vector_sha256_for_plan(vector, plan)
    denominator = vector["penalty_decay_denominator"]
    if not isinstance(denominator, int) or isinstance(denominator, bool):
        raise ReleaseLockError("penalty decay denominator is not integral")
    penalty_table = [
        ((65535 * denominator) + ((denominator + index) // 2))
        // (denominator + index)
        for index in range(256)
    ]
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "status": "locked",
        "configuration_id": configuration_id,
        "hash_bindings": {
            "mapping_sha256": _require_sha256(
                mapping_sha256,
                "mapping SHA-256",
            ),
            "operator_bank_sha256": _require_sha256(
                operator_bank_sha256,
                "operator-bank SHA-256",
            ),
            "metric_policy_sha256": _require_sha256(
                metric_policy_sha256,
                "metric-policy SHA-256",
            ),
            "compiler_inputs_sha256": "0" * 64,
            "calibration_plan_sha256": _require_sha256(
                calibration_plan_sha256,
                "calibration-plan SHA-256",
            ),
            "corpus_lock_bundle_sha256": _require_sha256(
                corpus_lock_bundle_sha256,
                "corpus-lock bundle SHA-256",
            ),
        },
        "canonicalization": {
            "encoding": "UTF-8",
            "object_key_order": "ascending Unicode scalar value",
            "array_order": "preserved",
            "whitespace": "none",
            "string_escaping": (
                "JSON quotation, reverse-solidus, and control escapes; "
                "non-ASCII encoded directly as UTF-8"
            ),
            "number_domain": "integers only",
            "duplicate_keys": "reject",
            "trailing_newline_in_hash_input": False,
            "hash_algorithm": "SHA-256",
            "hash_scope": (
                "complete canonical document with only "
                "/hash_bindings/compiler_inputs_sha256 omitted"
            ),
        },
        "boundary_mode": vector["boundary_mode"],
        "operator_parameters": {
            "anisotropy_strength_q12": vector["anisotropy_strength_q12"],
            "minimum_anisotropic_magnitude_unorm15": vector[
                "minimum_anisotropic_magnitude_unorm15"
            ],
            "minimum_anisotropic_coherence_unorm15": vector[
                "minimum_anisotropic_coherence_unorm15"
            ],
            "detail_gain_q12": vector["detail_gain_q12"],
            "relaxed_limiter_alpha_q12": vector[
                "relaxed_limiter_alpha_q12"
            ],
            "risk_detail_suppression_unorm15": vector[
                "risk_detail_suppression_unorm15"
            ],
            "low_pass_radius_q8_8": vector["low_pass_radius_q8_8"],
            "weight_epsilon_f32_bits": 730643660,
        },
        "semantic_steps": {
            "orientation_sector_step": 1,
            "support_radius_step_q8_8": vector["support_radius_step_q8_8"],
            "detail_gain_step_q12": vector["detail_gain_step_q12"],
            "regularization_step_q12": vector["regularization_step_q12"],
        },
        "compiler_policy": {
            "penalty_decay_denominator": denominator,
            "penalty_to_weight_unorm16": penalty_table,
            "penalty_orientation_step": vector["penalty_orientation_step"],
            "penalty_support_step": vector["penalty_support_step"],
            "penalty_detail_step": vector["penalty_detail_step"],
            "penalty_regularization_step": vector[
                "penalty_regularization_step"
            ],
            "penalty_unsupported_support_expansion": vector[
                "penalty_unsupported_support_expansion"
            ],
            "penalty_coherent_support_reduction": vector[
                "penalty_coherent_support_reduction"
            ],
            "penalty_unsupported_detail_increase": vector[
                "penalty_unsupported_detail_increase"
            ],
            "penalty_supported_detail_reduction": vector[
                "penalty_supported_detail_reduction"
            ],
            "penalty_relaxation_under_risk": vector[
                "penalty_relaxation_under_risk"
            ],
            "penalty_phase_kernel_mismatch": vector[
                "penalty_phase_kernel_mismatch"
            ],
            "confidence_threshold_unorm16": vector[
                "confidence_threshold_unorm16"
            ],
        },
        "routes": {
            "direct_2x": {
                "luma_coordinate_policy": vector[
                    "direct_2x_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_2x_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": vector[
                    "direct_2x_analysis_grid_source_step"
                ],
            },
            "direct_3_over_2": {
                "luma_coordinate_policy": vector[
                    "direct_3_over_2_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_3_over_2_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": vector[
                    "direct_3_over_2_analysis_grid_source_step"
                ],
            },
        },
        "temporal": {
            "enabled": False,
            "context_count": 4,
            "context_aliases_to_spatial": [1, 2, 3],
            "semantic_state": "clear payload coordinate 7 and recompute coordinate 9 parity",
            "affine_anchor": "original parity-valid source state",
        },
        "source_aligned": {
            "exact": True,
            "predicate": (
                "both luma and chroma coordinate policies are "
                "source_aligned_rational with horizontal phase zero and "
                "vertical phase zero"
            ),
            "primary_message": 0,
            "primary_descriptor": 0,
            "secondary": "inactive",
            "denoising": False,
        },
        "top_two": 2,
    }
    hashes = document["hash_bindings"]
    assert isinstance(hashes, dict)
    hashes["compiler_inputs_sha256"] = canonical_compiler_input_sha256(document)
    validate_schema(document, LOCKED_COMPILER_INPUT_SCHEMA)
    parse_locked_compiler_input(document)
    return document


def _percentile_linear(values: list[float], probability: float) -> float:
    if not values or values != sorted(values):
        raise ReleaseLockError("percentile values are empty or unsorted")
    position = (len(values) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return values[lower]
    fraction = position - lower
    return values[lower] + ((values[upper] - values[lower]) * fraction)


def _same_float(lhs: object, rhs: float) -> bool:
    return (
        isinstance(lhs, (int, float))
        and not isinstance(lhs, bool)
        and math.isfinite(float(lhs))
        and math.isclose(float(lhs), rhs, rel_tol=1.0e-12, abs_tol=1.0e-12)
    )


def dispatch_measurement_document(
    *,
    run_id: str,
    environment: Mapping[str, object],
    input_bindings: Mapping[str, object],
    raw_samples: Sequence[Mapping[str, object]],
    expected_sample_profiles: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    """Build validation dispatch evidence from unaggregated native timings.

    Native timings enter as integer nanoseconds.  The builder owns conversion,
    ordering, overhead arithmetic, percentiles, derivation hashes, and the
    document self-hash.  The expected source/profile matrix is independently
    derived by the caller from the locked validation sample and degradation
    policy documents.
    """

    if not isinstance(run_id, str) or not run_id:
        raise ReleaseLockError("dispatch measurement run ID is absent")
    if set(input_bindings) != set(_DISPATCH_INPUT_BINDING_FIELDS):
        raise ReleaseLockError("dispatch input binding field set differs")
    normalized_bindings: dict[str, object] = dict(input_bindings)
    configuration_id = normalized_bindings.get("configuration_id")
    if not isinstance(configuration_id, str) or not configuration_id:
        raise ReleaseLockError("dispatch configuration ID is absent")
    for field in _DISPATCH_INPUT_BINDING_FIELDS:
        if field != "configuration_id":
            normalized_bindings[field] = _require_sha256(
                normalized_bindings[field],
                f"dispatch {field}",
            )

    expected_fields = {
        "source_asset_id",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
    }
    expected_records = []
    for record in expected_sample_profiles:
        if not isinstance(record, dict) or set(record) != expected_fields:
            raise ReleaseLockError("dispatch expected sample/profile field set differs")
        source = record.get("source_asset_id")
        route = record.get("target_route")
        profile = record.get("degradation_profile_id")
        if (
            not isinstance(source, str)
            or not source
            or route not in {"direct-2x", "direct-3over2"}
            or not isinstance(profile, str)
            or not profile
        ):
            raise ReleaseLockError("dispatch expected sample/profile identity is invalid")
        expected_records.append(
            {
                "source_asset_id": source,
                "target_route": route,
                "degradation_profile_id": profile,
                "degradation_profile_sha256": _require_sha256(
                    record.get("degradation_profile_sha256"),
                    "dispatch degradation profile SHA-256",
                ),
            }
        )
    expected_records.sort(
        key=lambda record: (
            str(record["source_asset_id"]),
            str(record["degradation_profile_id"]),
        )
    )
    expected_keys = [
        (record["source_asset_id"], record["degradation_profile_id"])
        for record in expected_records
    ]
    if len(expected_records) != 9 or len(expected_keys) != len(set(expected_keys)):
        raise ReleaseLockError("dispatch expected matrix is not exactly nine unique rows")
    normalized_bindings["validation_sample_profile_matrix_sha256"] = _sha256(
        _canonical_bytes(expected_records)
    )

    raw_fields = {
        "source_asset_id",
        "target_route",
        "degradation_profile_id",
        "degradation_profile_sha256",
        "input_frame_sha256",
        "full_output_sha256",
        "control_output_sha256",
        "lut_whole_file_sha256",
        "measurement_domain",
        "production_metal_constraint_satisfied",
        "warmup_repetition_count",
        "measured_repetition_count",
        "input_bindings",
        "repetitions",
    }
    raw_by_key: dict[tuple[object, object], Mapping[str, object]] = {}
    for raw in raw_samples:
        if not isinstance(raw, dict) or set(raw) != raw_fields:
            raise ReleaseLockError("native dispatch sample field set differs")
        key = (raw.get("source_asset_id"), raw.get("degradation_profile_id"))
        if key in raw_by_key:
            raise ReleaseLockError("native dispatch sample/profile tuple repeats")
        raw_by_key[key] = raw
    if set(raw_by_key) != set(expected_keys):
        raise ReleaseLockError("native dispatch sample/profile matrix is incomplete")

    repetition_fields = {
        "index",
        "order",
        "full_analysis_nanoseconds",
        "full_dispatch_nanoseconds",
        "full_reconstruction_nanoseconds",
        "control_reconstruction_nanoseconds",
    }
    samples = []
    all_values: list[float] = []
    for expected in expected_records:
        key = (expected["source_asset_id"], expected["degradation_profile_id"])
        raw = raw_by_key[key]
        if (
            any(raw.get(field) != value for field, value in expected.items())
            or raw.get("measurement_domain")
            != "native_cpu_reference_projection_not_metal"
            or raw.get("production_metal_constraint_satisfied") is not False
            or raw.get("warmup_repetition_count") != 3
            or raw.get("measured_repetition_count") != 10
            or raw.get("input_bindings") != dict(input_bindings)
        ):
            raise ReleaseLockError("native dispatch sample identity differs")
        input_frame_sha256 = _require_sha256(
            raw.get("input_frame_sha256"),
            "dispatch input frame SHA-256",
        )
        full_output_sha256 = _require_sha256(
            raw.get("full_output_sha256"),
            "dispatch full output SHA-256",
        )
        control_output_sha256 = _require_sha256(
            raw.get("control_output_sha256"),
            "dispatch control output SHA-256",
        )
        if full_output_sha256 != control_output_sha256:
            raise ReleaseLockError("native dispatch control changed output bytes")
        lut_whole_file_sha256 = _require_sha256(
            raw.get("lut_whole_file_sha256"),
            "dispatch LUT SHA-256",
        )
        raw_repetitions = raw.get("repetitions")
        if not isinstance(raw_repetitions, list) or len(raw_repetitions) != 10:
            raise ReleaseLockError("native dispatch sample lacks ten repetitions")
        repetitions = []
        sample_values = []
        for index, raw_repetition in enumerate(raw_repetitions):
            if (
                not isinstance(raw_repetition, dict)
                or set(raw_repetition) != repetition_fields
            ):
                raise ReleaseLockError("native dispatch repetition field set differs")
            expected_order = (
                "full_then_control" if index % 2 == 0 else "control_then_full"
            )
            if (
                raw_repetition.get("index") != index
                or raw_repetition.get("order") != expected_order
            ):
                raise ReleaseLockError("native dispatch repetition order differs")
            timings = []
            for field in (
                "full_analysis_nanoseconds",
                "full_dispatch_nanoseconds",
                "full_reconstruction_nanoseconds",
                "control_reconstruction_nanoseconds",
            ):
                value = raw_repetition.get(field)
                if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                    raise ReleaseLockError("native dispatch timing is not nanoseconds")
                timings.append(float(value) / 1_000_000.0)
            analysis, dispatch, full_reconstruction, control_reconstruction = timings
            if full_reconstruction <= 0.0 or control_reconstruction <= 0.0:
                raise ReleaseLockError("native reconstruction timing is not positive")
            overhead = 100.0 * (dispatch / control_reconstruction)
            sample_values.append(overhead)
            repetitions.append(
                {
                    "index": index,
                    "order": expected_order,
                    "full_analysis_milliseconds": analysis,
                    "full_dispatch_milliseconds": dispatch,
                    "full_reconstruction_milliseconds": full_reconstruction,
                    "control_reconstruction_milliseconds": control_reconstruction,
                    "overhead_percent": overhead,
                }
            )
        ordered = sorted(sample_values)
        samples.append(
            {
                **expected,
                "input_frame_sha256": input_frame_sha256,
                "full_output_sha256": full_output_sha256,
                "control_output_sha256": control_output_sha256,
                "lut_whole_file_sha256": lut_whole_file_sha256,
                "repetitions": repetitions,
                "ordered_overhead_percent_values": ordered,
                "p95_overhead_percent": _percentile_linear(ordered, 0.95),
            }
        )
        all_values.extend(sample_values)

    ordered_all = sorted(all_values)
    p95 = _percentile_linear(ordered_all, 0.95)
    derivation = {
        "method": _DISPATCH_METHOD,
        "sample_sha256_values": [
            _sha256(_canonical_bytes(sample)) for sample in samples
        ],
        "ordered_overhead_percent_values": ordered_all,
        "measured_validation_p95_percent": p95,
    }
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_dispatch_overhead_measurement",
        "status": "pass",
        "run_id": run_id,
        "split": "validation",
        "measurement_domain": "native_cpu_reference_projection_not_metal",
        "production_metal_constraint_satisfied": False,
        "method": _DISPATCH_METHOD,
        "environment": dict(environment),
        "input_bindings": normalized_bindings,
        "samples": samples,
        "aggregate": {
            "sample_count": len(samples),
            "repetition_count": len(ordered_all),
            "ordered_overhead_percent_values": ordered_all,
            "measured_validation_p95_percent": p95,
            "maximum_admissible_p95_percent": 20.0,
            "derivation_sha256": _sha256(_canonical_bytes(derivation)),
        },
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = _manifest_sha256(document)
    validate_dispatch_measurement_document(document)
    return document


def validate_dispatch_measurement_document(
    document: Mapping[str, object],
) -> Mapping[str, object]:
    """Recompute every timing-derived field without accepting digest placeholders."""

    validate_schema(document, DISPATCH_MEASUREMENT_SCHEMA)
    if document.get("manifest_sha256") != _manifest_sha256(document):
        raise ReleaseLockError("dispatch measurement self-hash mismatch")
    samples = document.get("samples")
    aggregate = document.get("aggregate")
    method = document.get("method")
    if not isinstance(samples, list) or not isinstance(aggregate, dict):
        raise ReleaseLockError("dispatch measurement samples or aggregate are absent")
    sample_keys = [
        (sample.get("source_asset_id"), sample.get("degradation_profile_id"))
        for sample in samples
    ]
    if (
        len(sample_keys) != len(set(sample_keys))
        or sample_keys != sorted(sample_keys)
    ):
        raise ReleaseLockError(
            "dispatch measurement sample/profile tuples repeat or are unsorted"
        )
    matrix = [
        {
            "source_asset_id": sample.get("source_asset_id"),
            "target_route": sample.get("target_route"),
            "degradation_profile_id": sample.get("degradation_profile_id"),
            "degradation_profile_sha256": sample.get(
                "degradation_profile_sha256"
            ),
        }
        for sample in samples
    ]
    input_bindings = document.get("input_bindings")
    if (
        not isinstance(input_bindings, dict)
        or input_bindings.get("validation_sample_profile_matrix_sha256")
        != _sha256(_canonical_bytes(matrix))
    ):
        raise ReleaseLockError("dispatch sample/profile matrix binding differs")
    all_values: list[float] = []
    sample_hashes = []
    for sample in samples:
        if not isinstance(sample, dict):
            raise ReleaseLockError("dispatch sample is not an object")
        if sample.get("full_output_sha256") != sample.get("control_output_sha256"):
            raise ReleaseLockError("dispatch control changed reconstructed output bytes")
        repetitions = sample.get("repetitions")
        if not isinstance(repetitions, list) or len(repetitions) != 10:
            raise ReleaseLockError("dispatch sample lacks ten repetitions")
        sample_values = []
        for index, repetition in enumerate(repetitions):
            if not isinstance(repetition, dict):
                raise ReleaseLockError("dispatch repetition is not an object")
            expected_order = "full_then_control" if index % 2 == 0 else "control_then_full"
            control = repetition.get("control_reconstruction_milliseconds")
            dispatch = repetition.get("full_dispatch_milliseconds")
            if (
                repetition.get("index") != index
                or repetition.get("order") != expected_order
                or not isinstance(control, (int, float))
                or isinstance(control, bool)
                or not isinstance(dispatch, (int, float))
                or isinstance(dispatch, bool)
                or float(control) <= 0.0
                or float(dispatch) < 0.0
            ):
                raise ReleaseLockError("dispatch repetition order or timing is invalid")
            expected_overhead = 100.0 * (float(dispatch) / float(control))
            if not _same_float(repetition.get("overhead_percent"), expected_overhead):
                raise ReleaseLockError("dispatch overhead percentage was not recomputed")
            sample_values.append(expected_overhead)
        ordered = sorted(sample_values)
        declared_ordered = sample.get("ordered_overhead_percent_values")
        if (
            not isinstance(declared_ordered, list)
            or len(declared_ordered) != len(ordered)
            or any(
                not _same_float(declared, expected)
                for declared, expected in zip(declared_ordered, ordered)
            )
            or not _same_float(
                sample.get("p95_overhead_percent"),
                _percentile_linear(ordered, 0.95),
            )
        ):
            raise ReleaseLockError("dispatch sample percentile evidence differs")
        all_values.extend(sample_values)
        sample_hashes.append(_sha256(_canonical_bytes(sample)))
    all_ordered = sorted(all_values)
    declared_all = aggregate.get("ordered_overhead_percent_values")
    if (
        aggregate.get("sample_count") != len(samples)
        or aggregate.get("repetition_count") != len(all_values)
        or not isinstance(declared_all, list)
        or len(declared_all) != len(all_ordered)
        or any(
            not _same_float(declared, expected)
            for declared, expected in zip(declared_all, all_ordered)
        )
    ):
        raise ReleaseLockError("dispatch aggregate cardinality or ordering differs")
    p95 = _percentile_linear(all_ordered, 0.95)
    if not _same_float(aggregate.get("measured_validation_p95_percent"), p95):
        raise ReleaseLockError("dispatch aggregate p95 differs")
    derivation = {
        "method": method,
        "sample_sha256_values": sample_hashes,
        "ordered_overhead_percent_values": all_ordered,
        "measured_validation_p95_percent": p95,
    }
    if aggregate.get("derivation_sha256") != _sha256(_canonical_bytes(derivation)):
        raise ReleaseLockError("dispatch derivation hash differs")
    return document


def locked_metric_policy_document(
    *,
    metric_seed: Mapping[str, object],
    tolerances: Mapping[str, object],
    tolerances_sha256: str,
    dispatch_measurement: Mapping[str, object],
    dispatch_measurement_file_sha256: str,
    dispatch_measurement_size_bytes: int,
) -> Mapping[str, object]:
    """Fill every release metric null from preregistration and measured evidence."""

    seed_without_hash = dict(metric_seed)
    supplied_seed_hash = seed_without_hash.pop("policy_sha256", None)
    if supplied_seed_hash != _sha256(_canonical_bytes(seed_without_hash)):
        raise ReleaseLockError("metric seed self-hash mismatch")
    validate_dispatch_measurement_document(dispatch_measurement)
    _require_sha256(tolerances_sha256, "metric tolerance contract SHA-256")
    _require_sha256(
        dispatch_measurement_file_sha256,
        "dispatch measurement file SHA-256",
    )
    if not isinstance(dispatch_measurement_size_bytes, int) or dispatch_measurement_size_bytes < 1:
        raise ReleaseLockError("dispatch measurement file size is invalid")
    quality = tolerances.get("quality")
    if not isinstance(quality, dict):
        raise ReleaseLockError("metric tolerance quality section is absent")
    performance = tolerances.get("performance")
    if not isinstance(performance, dict):
        raise ReleaseLockError("metric tolerance performance section is absent")
    p95 = float(dispatch_measurement["aggregate"]["measured_validation_p95_percent"])
    budget = max(5, math.ceil(p95 + 5.0))
    if budget > 25:
        raise ReleaseLockError("derived dispatch budget exceeds 25 percent")
    dispatch_budget = {
        "measured_validation_p95_percent": p95,
        "uncertainty_margin_percentage_points": 5.0,
        "derived_budget_percent": budget,
        "measurement_run_ids": [dispatch_measurement["run_id"]],
        "measurement_artifact_sha256_values": [
            dispatch_measurement_file_sha256
        ],
        "derivation_formula": "max(5, ceil(measured_validation_p95_percent + 5))",
        "locked_before_g08": True,
        "post_g08_adjustment_allowed": False,
    }
    y_bounds = quality["y_psnr_paired_delta_lower_bound_db"]
    ringing = quality["ringing"]
    alias = quality["alias"]
    chroma = quality["chroma_displacement"]
    temporal = quality["temporal_future_gate"]
    document: dict[str, object] = {
        "schema_version": "2.0.0",
        "status": "locked",
        "comparison_domains": metric_seed["comparison_domains"],
        "domain_aggregation_forbidden": metric_seed[
            "domain_aggregation_forbidden"
        ],
        "numeric_precision": metric_seed["numeric_precision"],
        "normalization": metric_seed["normalization"],
        "psnr": metric_seed["psnr"],
        "ssim": metric_seed["ssim"],
        "ms_ssim": metric_seed["ms_ssim"],
        "artifact_metrics": metric_seed["artifact_metrics"],
        "independent_oracle": metric_seed["independent_oracle"],
        "analytic_fixture_manifest": metric_seed["analytic_fixture_manifest"],
        "bootstrap": metric_seed["bootstrap"],
        "release_tolerances": {
            "contract_path": (
                "validation/calibration_v2/contracts/"
                "metric-performance-tolerances-v1.json"
            ),
            "contract_sha256": tolerances_sha256,
            "y_psnr_paired_delta_lower_bound_db": y_bounds,
            "ms_ssim_noninferiority_lower_bound_minimum": quality[
                "ms_ssim_noninferiority"
            ]["paired_delta_lower_bound_minimum"],
            "ringing_overshoot_absolute_maximum": ringing[
                "absolute_overshoot_maximum"
            ],
            "ringing_undershoot_magnitude_absolute_maximum": ringing[
                "absolute_undershoot_magnitude_maximum"
            ],
            "ringing_increase_maximum": ringing[
                "increase_over_best_conventional_maximum"
            ],
            "alias_ratio_maximum": alias[
                "forbidden_band_energy_ratio_maximum"
            ],
            "alias_increase_maximum": alias[
                "increase_over_best_conventional_maximum"
            ],
            "chroma_displacement_pixels_maximum": chroma[
                "absolute_pixels_maximum"
            ],
            "chroma_displacement_increase_pixels_maximum": chroma[
                "increase_over_best_conventional_pixels_maximum"
            ],
            "severe_regression": quality["severe_regression"],
            "minimum_source_families_per_category": quality[
                "minimum_source_families_per_category"
            ],
            "temporal_ghosting": {
                "normalized_error_absolute_maximum": temporal[
                    "ghosting_normalized_error_absolute_maximum"
                ],
                "increase_over_spatial_maximum": temporal[
                    "ghosting_increase_over_spatial_maximum"
                ],
                "scene_cut_reset_latency_frames_maximum": temporal[
                    "scene_cut_reset_latency_frames_maximum"
                ],
            },
            "dispatch_overhead_budget": dispatch_budget,
        },
        "dispatch_measurement_evidence": {
            "path": "dispatch-measurement.json",
            "sha256": dispatch_measurement_file_sha256,
            "size_bytes": dispatch_measurement_size_bytes,
            "measurement_domain": "native_cpu_reference_projection_not_metal",
            "production_metal_constraint_satisfied": False,
            "status": "pass",
        },
        "unlocked_release_fields": [],
        "hash_scope": "canonical sorted-key compact UTF-8 JSON excluding /policy_sha256",
        "policy_sha256": "0" * 64,
    }
    unhashed = dict(document)
    unhashed.pop("policy_sha256")
    document["policy_sha256"] = _sha256(_canonical_bytes(unhashed))
    validate_schema(document, LOCKED_METRIC_POLICY_SCHEMA)
    return document


def locked_quality_policy_document(
    *,
    selected_controls: Mapping[str, object],
    quality_policy_seed_sha256: str,
    baseline_ablation_contract: Mapping[str, object],
    baseline_ablation_contract_sha256: str,
    input_bundle_sha256: str,
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    """Freeze the exact validation-selected controls before holdout access.

    The calibration selection carries three policy/bank bindings beside the
    eight control identities.  This projection verifies those bindings and
    emits only the schema-declared control identities, preventing a caller
    from substituting stale or differently selected controls at publication.
    """

    try:
        validate_schema(
            baseline_ablation_contract,
            BASELINE_ABLATION_CONTRACT_SCHEMA,
        )
    except ValueError as error:
        raise ReleaseLockError(
            "baseline/ablation contract schema validation failed"
        ) from error
    quality_hash = _require_sha256(
        quality_policy_seed_sha256,
        "quality-policy seed SHA-256",
    )
    baseline_hash = _require_sha256(
        baseline_ablation_contract_sha256,
        "baseline/ablation contract SHA-256",
    )
    input_hash = _require_sha256(input_bundle_sha256, "input bundle SHA-256")
    bank_hash = _require_sha256(
        shared_bank_configuration_sha256,
        "shared-bank configuration SHA-256",
    )
    expected_selected_keys = {
        "shared_bank_configuration_sha256",
        "quality_policy_seed_sha256",
        "baseline_ablation_contract_sha256",
        *_SELECTED_CONTROL_NAMES,
    }
    if set(selected_controls) != expected_selected_keys:
        missing = sorted(expected_selected_keys - set(selected_controls))
        extra = sorted(set(selected_controls) - expected_selected_keys)
        raise ReleaseLockError(
            "selected-control identities are not exact: "
            f"missing={missing}, extra={extra}"
        )
    if (
        selected_controls["quality_policy_seed_sha256"] != quality_hash
        or selected_controls["baseline_ablation_contract_sha256"]
        != baseline_hash
        or selected_controls["shared_bank_configuration_sha256"] != bank_hash
    ):
        raise ReleaseLockError("selected-control policy or bank binding differs")
    if baseline_ablation_contract.get("contract_id") != (
        "mirmir-p06-baselines-ablations-v1"
    ):
        raise ReleaseLockError("baseline/ablation contract identity differs")
    policy_seed = baseline_ablation_contract.get("quality_policy_seed")
    output_contract = baseline_ablation_contract.get("locked_quality_policy_output")
    if (
        not isinstance(policy_seed, dict)
        or policy_seed.get("sha256") != quality_hash
        or not isinstance(output_contract, dict)
        or output_contract.get("required_selected_controls")
        != list(_SELECTED_CONTROL_NAMES)
    ):
        raise ReleaseLockError(
            "baseline/ablation contract does not bind the selected controls"
        )
    projected_controls: dict[str, object] = {}
    for name in _SELECTED_CONTROL_NAMES:
        identity = selected_controls.get(name)
        if not isinstance(identity, dict):
            raise ReleaseLockError(f"selected control is not an object: {name}")
        if identity.get("shared_bank_configuration_sha256") != bank_hash:
            raise ReleaseLockError(
                f"selected control carries a different shared bank: {name}"
            )
        projected_controls[name] = dict(identity)
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_locked_quality_policy",
        "status": "locked_before_p07",
        "quality_policy_seed_sha256": quality_hash,
        "baseline_ablation_contract_sha256": baseline_hash,
        "baseline_ablation_contract_id": baseline_ablation_contract["contract_id"],
        "input_bundle_sha256": input_hash,
        "shared_bank_configuration_sha256": bank_hash,
        "selected_controls": projected_controls,
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = _manifest_sha256(document)
    try:
        validate_schema(document, LOCKED_QUALITY_POLICY_SCHEMA)
    except ValueError as error:
        raise ReleaseLockError(
            "locked quality-policy schema validation failed"
        ) from error
    return document


def build_locked_quality_policy(
    *,
    output_path: Path,
    selected_controls: Mapping[str, object],
    quality_policy_seed_sha256: str,
    baseline_ablation_contract: Mapping[str, object],
    baseline_ablation_contract_sha256: str,
    input_bundle_sha256: str,
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    """Publish a new locked quality policy and verify its reopened bytes."""

    document = locked_quality_policy_document(
        selected_controls=selected_controls,
        quality_policy_seed_sha256=quality_policy_seed_sha256,
        baseline_ablation_contract=baseline_ablation_contract,
        baseline_ablation_contract_sha256=baseline_ablation_contract_sha256,
        input_bundle_sha256=input_bundle_sha256,
        shared_bank_configuration_sha256=shared_bank_configuration_sha256,
    )
    payload = _canonical_bytes(document) + b"\n"
    _publish_new_file(output_path, payload)
    if _read_regular_file(output_path) != payload:
        raise ReleaseLockError("published locked quality policy changed after reopen")
    if _read_strict_json(output_path) != document:
        raise ReleaseLockError(
            "published locked quality-policy JSON changed after reopen"
        )
    return document


def configuration_lock_document(
    *,
    locked_utc: str,
    hash_bindings: Mapping[str, str],
) -> Mapping[str, object]:
    """Create the fail-closed v1 holdout configuration lock.

    The caller must derive every supplied digest by reopening the bound
    artifact using the same digest mode that will be supplied to
    ``HoldoutAccessGuard``.  This function rejects missing, extra, zero, or
    malformed bindings and locks the unopened state before publication.
    """

    if set(hash_bindings) != set(_CONFIGURATION_LOCK_HASH_FIELDS):
        missing = sorted(set(_CONFIGURATION_LOCK_HASH_FIELDS) - set(hash_bindings))
        extra = sorted(set(hash_bindings) - set(_CONFIGURATION_LOCK_HASH_FIELDS))
        raise ReleaseLockError(
            "configuration-lock bindings are not exact: "
            f"missing={missing}, extra={extra}"
        )
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "locked_utc": _require_utc_timestamp(locked_utc, "lock timestamp"),
        "release_fields_complete": True,
        "configuration_files_modified_after_lock": False,
        **{
            field: _require_sha256(
                hash_bindings[field],
                f"configuration-lock {field}",
            )
            for field in _CONFIGURATION_LOCK_HASH_FIELDS
        },
        "holdout_opened_utc": None,
    }
    try:
        validate_schema(document, CONFIGURATION_LOCK_SCHEMA)
    except ValueError as error:
        raise ReleaseLockError("configuration lock schema validation failed") from error
    return document


def build_configuration_lock(
    *,
    output_path: Path,
    locked_utc: str,
    hash_bindings: Mapping[str, str],
) -> Mapping[str, object]:
    """Publish one new configuration lock and verify its reopened bytes."""

    document = configuration_lock_document(
        locked_utc=locked_utc,
        hash_bindings=hash_bindings,
    )
    payload = _canonical_bytes(document) + b"\n"
    _publish_new_file(output_path, payload)
    if _read_regular_file(output_path) != payload:
        raise ReleaseLockError("published configuration lock changed after reopen")
    if _read_strict_json(output_path) != document:
        raise ReleaseLockError("published configuration lock JSON changed after reopen")
    return document


def configuration_lock_document_from_bindings(
    *,
    locked_utc: str,
    artifact_bindings: Mapping[str, HashBinding],
) -> Mapping[str, object]:
    """Derive every configuration digest from the artifacts P07 will reopen."""

    if set(artifact_bindings) != set(_CONFIGURATION_LOCK_HASH_FIELDS):
        missing = sorted(
            set(_CONFIGURATION_LOCK_HASH_FIELDS) - set(artifact_bindings)
        )
        extra = sorted(
            set(artifact_bindings) - set(_CONFIGURATION_LOCK_HASH_FIELDS)
        )
        raise ReleaseLockError(
            "configuration artifact bindings are not exact: "
            f"missing={missing}, extra={extra}"
        )
    harness = artifact_bindings[
        "quality_harness_implementation_manifest_sha256"
    ]
    if (
        not isinstance(harness, HashBinding)
        or harness.digest_mode != "quality_harness_manifest"
    ):
        raise ReleaseLockError(
            "quality-harness binding must use recursive manifest validation"
        )
    try:
        derived = {
            field: hash_binding_digest(field, artifact_bindings[field])
            for field in _CONFIGURATION_LOCK_HASH_FIELDS
        }
    except (OSError, TypeError, ValueError) as error:
        raise ReleaseLockError(
            "configuration artifact binding could not be derived"
        ) from error
    return configuration_lock_document(
        locked_utc=locked_utc,
        hash_bindings=derived,
    )


def build_configuration_lock_from_bindings(
    *,
    output_path: Path,
    locked_utc: str,
    artifact_bindings: Mapping[str, HashBinding],
) -> Mapping[str, object]:
    """Publish and rederive a transitive configuration lock without digest input."""

    document = configuration_lock_document_from_bindings(
        locked_utc=locked_utc,
        artifact_bindings=artifact_bindings,
    )
    payload = _canonical_bytes(document) + b"\n"
    _publish_new_file(output_path, payload)
    if _read_regular_file(output_path) != payload:
        raise ReleaseLockError("published configuration lock changed after reopen")
    rebound = configuration_lock_document_from_bindings(
        locked_utc=locked_utc,
        artifact_bindings=artifact_bindings,
    )
    if rebound != document:
        raise ReleaseLockError(
            "configuration artifacts changed during lock publication"
        )
    return document


def build_p06_release_bundle_manifest(
    *,
    release_root: Path,
    output_path: Path,
    configuration_id: str,
    locked_utc: str,
    input_bundle_sha256: str,
    corpus_lock_bundle_sha256: str,
    selected_evaluation_path: str,
    transaction_id: str | None = None,
) -> Mapping[str, object]:
    """Publish the exact ordered set of mandatory P06 release artifacts."""

    release = release_root.resolve(strict=True)
    selected_relative = _relative_path(selected_evaluation_path).as_posix()
    if not (
        selected_relative.startswith("evaluations/")
        and selected_relative.endswith(".json")
        and len(PurePosixPath(selected_relative).name) == 69
    ):
        raise ReleaseLockError("selected evaluation path is not content-addressed")
    artifacts = []
    for identifier, fixed_path in _RELEASE_ARTIFACTS:
        relative_path = selected_relative if fixed_path is None else fixed_path
        binding = _binding(
            _path_under_root(release, relative_path),
            relative_path,
        )
        artifacts.append({"id": identifier, **binding})
    transient_exclusions = _authenticated_p06_transaction_token_exclusions(
        release,
        transaction_id=transaction_id,
    )
    document: dict[str, object] = {
        "schema_version": "2.0.0",
        "bundle_id": "mirmir-p06-spatial-release-lock-v2",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "locked_utc": locked_utc,
        "input_bundle_sha256": _require_sha256(
            input_bundle_sha256,
            "calibration input bundle SHA-256",
        ),
        "corpus_lock_bundle_sha256": _require_sha256(
            corpus_lock_bundle_sha256,
            "corpus-lock bundle SHA-256",
        ),
        "release_fields_complete": True,
        "configuration_files_modified_after_lock": False,
        "holdout_accessed": False,
        "holdout_access_count": 0,
        "artifacts": artifacts,
        "filesystem_closure_rule": _P06_FILESYSTEM_CLOSURE_RULE,
        "filesystem_closure": _release_filesystem_closure(
            release,
            excluded_paths=(
                P06_RELEASE_SELF_MANIFEST_EXCLUSIONS
                | transient_exclusions
            ),
        ),
    }
    document["manifest_sha256"] = _manifest_sha256(document)
    validate_schema(document, P06_RELEASE_BUNDLE_SCHEMA)
    _publish_new_file(output_path, _canonical_bytes(document) + b"\n")
    _validate_p06_release_bundle_manifest(
        release_root=release,
        manifest_path=output_path,
        transaction_id=transaction_id,
    )
    return document


def build_p06_release_bundle_v3_manifest(
    *,
    release_root: Path,
    output_path: Path,
    configuration_id: str,
    locked_utc: str,
    shared_bank_configuration_sha256: str,
    input_bundle_sha256: str,
    corpus_lock_bundle_sha256: str,
    selected_evaluation_path: str,
    authorized_execution_bindings_sha256: str,
    artifact_provenance: Mapping[str, Mapping[str, object]],
    support_evidence_roots: Mapping[str, Path] | None = None,
    transaction_id: str | None = None,
) -> Mapping[str, object]:
    """Publish and reopen the authenticated schema-3 P06 release closure.

    All release bytes must already exist.  This builder neither selects a
    candidate nor compiles a LUT; it binds the exact V2 calibration and
    format-1.2 outputs produced before the release transaction.
    """

    release = release_root.resolve(strict=True)
    if (
        output_path.name != _P06_RELEASE_BUNDLE_NAME
        or output_path.parent.resolve(strict=True) != release
    ):
        raise ReleaseLockError("P06 V3 bundle output path differs")
    selected_relative = _relative_path(selected_evaluation_path).as_posix()
    if not (
        selected_relative.startswith("evaluations/")
        and selected_relative.endswith(".json")
        and len(PurePosixPath(selected_relative).name) == 69
    ):
        raise ReleaseLockError(
            "P06 V3 selected evaluation path is not content-addressed"
        )
    expected_ids = tuple(identifier for identifier, _ in _RELEASE_ARTIFACTS_V3)
    if set(artifact_provenance) != set(expected_ids):
        missing = sorted(set(expected_ids) - set(artifact_provenance))
        extra = sorted(set(artifact_provenance) - set(expected_ids))
        raise ReleaseLockError(
            "P06 V3 artifact provenance is not exact: "
            f"missing={missing}, extra={extra}"
        )
    provenance_fields = {"producer", "command", "platform", "gate_bindings"}
    artifacts: list[Mapping[str, object]] = []
    for identifier, fixed_path in _RELEASE_ARTIFACTS_V3:
        relative_path = selected_relative if fixed_path is None else fixed_path
        provenance = artifact_provenance[identifier]
        if not isinstance(provenance, Mapping) or set(provenance) != provenance_fields:
            raise ReleaseLockError(
                f"P06 V3 artifact provenance fields differ: {identifier}"
            )
        gates = provenance.get("gate_bindings")
        if (
            not isinstance(gates, Sequence)
            or isinstance(gates, (str, bytes, bytearray))
            or not gates
            or any(not isinstance(gate, str) for gate in gates)
            or len(set(gates)) != len(gates)
        ):
            raise ReleaseLockError(
                f"P06 V3 artifact gate provenance differs: {identifier}"
            )
        for field in ("producer", "command", "platform"):
            value = provenance.get(field)
            if not isinstance(value, str) or not value:
                raise ReleaseLockError(
                    f"P06 V3 artifact provenance is absent: {identifier}/{field}"
                )
        binding = _binding(
            _path_under_root(release, relative_path),
            relative_path,
        )
        if (
            identifier == "selected_evaluation"
            and PurePosixPath(relative_path).stem != binding["sha256"]
        ):
            raise ReleaseLockError(
                "P06 V3 selected evaluation content address differs"
            )
        artifacts.append(
            {
                "id": identifier,
                **binding,
                "producer": provenance["producer"],
                "command": provenance["command"],
                "platform": provenance["platform"],
                "gate_bindings": list(gates),
            }
        )
    try:
        from validation.calibration_v2.calibration_persistence_v2 import (
            authority_bindings_v2,
        )

        authorities = authority_bindings_v2()
    except (OSError, ValueError) as error:
        raise ReleaseLockError(
            "P06 V3 authority bindings cannot be authenticated"
        ) from error
    transient_exclusions = _authenticated_p06_transaction_token_exclusions(
        release,
        transaction_id=transaction_id,
    )
    document: dict[str, object] = {
        "schema_version": "3.0.1",
        "artifact_kind": "p06_release_bundle_v3",
        "bundle_id": "mirmir-p06-spatial-release-lock-v3",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "locked_utc": _require_utc_timestamp(locked_utc, "P06 V3 lock timestamp"),
        "authority_bindings": authorities,
        "shared_bank_configuration_sha256": _require_sha256(
            shared_bank_configuration_sha256,
            "P06 V3 shared-bank configuration SHA-256",
        ),
        "input_bundle_sha256": _require_sha256(
            input_bundle_sha256,
            "P06 V3 input-bundle SHA-256",
        ),
        "corpus_lock_bundle_sha256": _require_sha256(
            corpus_lock_bundle_sha256,
            "P06 V3 corpus-lock bundle SHA-256",
        ),
        "release_fields_complete": True,
        "configuration_files_modified_after_lock": False,
        "holdout_accessed": False,
        "holdout_access_count": 0,
        "artifact_ids": list(expected_ids),
        "artifacts": artifacts,
        "filesystem_closure_rule": _P06_FILESYSTEM_CLOSURE_RULE,
        "filesystem_closure": _release_filesystem_closure(
            release,
            excluded_paths=(
                P06_RELEASE_SELF_MANIFEST_EXCLUSIONS | transient_exclusions
            ),
        ),
        "authorized_execution_bindings_sha256": _require_sha256(
            authorized_execution_bindings_sha256,
            "P06 V3 authorized-execution bindings SHA-256",
        ),
        "p07_authorization_status": "ready_for_single_locked_holdout_execution",
    }
    document["artifact_sha256"] = _artifact_sha256(document)
    try:
        validate_schema(document, P06_RELEASE_BUNDLE_V3_SCHEMA)
    except ValueError as error:
        raise ReleaseLockError("P06 V3 release bundle schema validation failed") from error
    _publish_new_file(output_path, _canonical_bytes(document) + b"\n")
    reopened = _validate_p06_release_bundle_manifest(
        release_root=release,
        manifest_path=output_path,
        support_evidence_roots=support_evidence_roots,
        transaction_id=transaction_id,
    )
    if reopened != document:
        raise ReleaseLockError("published P06 V3 release bundle changed after reopen")
    return document


def route_analysis_grid_selection_document(
    *,
    vector: Mapping[str, object],
    plan: Mapping[str, object],
    configuration_id: str,
    calibration_selection_sha256: str,
    selected_evaluation_sha256: str,
    mapping_sha256: str,
    operator_bank_sha256: str,
    compiler_inputs_sha256: str,
) -> Mapping[str, object]:
    """Freeze each route's measured coordinate/grid choice before P07."""

    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_route_analysis_grid_selection",
        "status": "locked_before_p07",
        "configuration_id": configuration_id,
        "candidate_vector_sha256": candidate_vector_sha256_for_plan(
            vector,
            plan,
        ),
        "calibration_selection_sha256": _require_sha256(
            calibration_selection_sha256,
            "calibration selection SHA-256",
        ),
        "selected_evaluation_sha256": _require_sha256(
            selected_evaluation_sha256,
            "selected evaluation SHA-256",
        ),
        "mapping_sha256": _require_sha256(mapping_sha256, "mapping SHA-256"),
        "operator_bank_sha256": _require_sha256(
            operator_bank_sha256,
            "operator-bank SHA-256",
        ),
        "compiler_inputs_sha256": _require_sha256(
            compiler_inputs_sha256,
            "compiler-input SHA-256",
        ),
        "analysis_grid_contract_id": "source_lattice_symmetric_cell_center_v1",
        "routes": [
            {
                "route": "direct_2x",
                "scale_numerator": 2,
                "scale_denominator": 1,
                "luma_coordinate_policy": vector[
                    "direct_2x_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_2x_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": vector[
                    "direct_2x_analysis_grid_source_step"
                ],
                "selection_basis": "development_tuning_validation_selection",
            },
            {
                "route": "direct_3_over_2",
                "scale_numerator": 3,
                "scale_denominator": 2,
                "luma_coordinate_policy": vector[
                    "direct_3_over_2_luma_coordinate_policy"
                ],
                "chroma_coordinate_policy": vector[
                    "direct_3_over_2_chroma_coordinate_policy"
                ],
                "analysis_grid_source_step": vector[
                    "direct_3_over_2_analysis_grid_source_step"
                ],
                "selection_basis": "development_tuning_validation_selection",
            },
        ],
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = _manifest_sha256(document)
    validate_schema(document, ROUTE_SELECTION_SCHEMA)
    return document


def _validate_p06_release_bundle_manifest(
    *,
    release_root: Path,
    manifest_path: Path,
    support_evidence_roots: Mapping[str, Path] | None = None,
    transaction_id: str | None,
) -> Mapping[str, object]:
    """Validate a release, optionally inside one authenticated transaction."""

    release = release_root.resolve(strict=True)
    transient_exclusions = _authenticated_p06_transaction_token_exclusions(
        release,
        transaction_id=transaction_id,
    )
    document = _read_strict_json(manifest_path)
    if (
        document.get("schema_version") == "3.0.1"
        and document.get("bundle_id") == "mirmir-p06-spatial-release-lock-v3"
    ):
        return _validate_p06_release_bundle_v3_manifest(
            release_root=release,
            document=document,
            support_evidence_roots=support_evidence_roots,
            transient_exclusions=transient_exclusions,
        )
    if (
        document.get("schema_version") != "2.0.0"
        or document.get("bundle_id") != "mirmir-p06-spatial-release-lock-v2"
    ):
        raise ReleaseLockError("historical or unknown P06 release bundle version")
    validate_schema(document, P06_RELEASE_BUNDLE_SCHEMA)
    if document.get("filesystem_closure_rule") != _P06_FILESYSTEM_CLOSURE_RULE:
        raise ReleaseLockError("P06 release filesystem closure rule differs")
    if document.get("manifest_sha256") != _manifest_sha256(document):
        raise ReleaseLockError("P06 release bundle self-hash mismatch")
    rows = document.get("artifacts")
    if not isinstance(rows, list) or len(rows) != len(_RELEASE_ARTIFACTS):
        raise ReleaseLockError("P06 release bundle artifact count differs")
    for row, (expected_id, fixed_path) in zip(rows, _RELEASE_ARTIFACTS):
        if not isinstance(row, dict) or row.get("id") != expected_id:
            raise ReleaseLockError("P06 release bundle artifact order differs")
        path = str(row.get("path"))
        if fixed_path is not None and path != fixed_path:
            raise ReleaseLockError(f"P06 release artifact path differs: {expected_id}")
        actual = _binding(_path_under_root(release, path), path)
        if row != {"id": expected_id, **actual}:
            raise ReleaseLockError(f"P06 release artifact changed: {expected_id}")
    declared_filesystem_closure = document.get("filesystem_closure")
    observed_filesystem_closure = _release_filesystem_closure(
        release,
        excluded_paths=(
            P06_RELEASE_SELF_MANIFEST_EXCLUSIONS | transient_exclusions
        ),
    )
    if declared_filesystem_closure != observed_filesystem_closure:
        raise ReleaseLockError("P06 release filesystem closure changed")
    _validate_p06_release_cross_bindings(
        release_root=release,
        bundle=document,
        artifacts={str(row["id"]): row for row in rows},
    )
    if support_evidence_roots is not None:
        closure_binding = next(
            row for row in rows if row["id"] == "evidence_closure"
        )
        closure = _read_strict_json(
            _path_under_root(release, str(closure_binding["path"]))
        )
        _validate_support_evidence_trees(
            closure,
            support_evidence_roots=support_evidence_roots,
        )
    return document


def _validate_p06_release_bundle_v3_manifest(
    *,
    release_root: Path,
    document: Mapping[str, object],
    support_evidence_roots: Mapping[str, Path] | None,
    transient_exclusions: frozenset[str],
) -> Mapping[str, object]:
    """Reopen the exact schema-3 release family without accepting V2 aliases."""

    try:
        validate_schema(document, P06_RELEASE_BUNDLE_V3_SCHEMA)
    except ValueError as error:
        raise ReleaseLockError("P06 V3 release bundle schema validation failed") from error
    if document.get("filesystem_closure_rule") != _P06_FILESYSTEM_CLOSURE_RULE:
        raise ReleaseLockError("P06 V3 release filesystem closure rule differs")
    p06_release_bundle_sha256(document)
    rows = document.get("artifacts")
    if not isinstance(rows, list) or len(rows) != len(_RELEASE_ARTIFACTS_V3):
        raise ReleaseLockError("P06 V3 release bundle artifact count differs")
    if document.get("artifact_ids") != [item[0] for item in _RELEASE_ARTIFACTS_V3]:
        raise ReleaseLockError("P06 V3 release artifact ID closure differs")
    artifacts: dict[str, Mapping[str, object]] = {}
    for row, (expected_id, fixed_path) in zip(rows, _RELEASE_ARTIFACTS_V3):
        if not isinstance(row, dict) or row.get("id") != expected_id:
            raise ReleaseLockError("P06 V3 release bundle artifact order differs")
        path = str(row.get("path"))
        if fixed_path is not None and path != fixed_path:
            raise ReleaseLockError(
                f"P06 V3 release artifact path differs: {expected_id}"
            )
        actual = _binding(_path_under_root(release_root, path), path)
        if any(row.get(field) != actual[field] for field in actual):
            raise ReleaseLockError(f"P06 V3 release artifact changed: {expected_id}")
        artifacts[expected_id] = row
    observed_filesystem_closure = _release_filesystem_closure(
        release_root,
        excluded_paths=(
            P06_RELEASE_SELF_MANIFEST_EXCLUSIONS | transient_exclusions
        ),
    )
    if document.get("filesystem_closure") != observed_filesystem_closure:
        raise ReleaseLockError("P06 V3 release filesystem closure changed")
    authority = _validate_p06_release_v3_cross_bindings(
        release_root=release_root,
        bundle=document,
        artifacts=artifacts,
        support_evidence_roots=support_evidence_roots,
    )
    if support_evidence_roots is not None:
        try:
            from validation.calibration_v2.p07.execution_authority_v2 import verify

            verify(
                release_root=release_root,
                repository_root=CALIBRATION_ROOT.parents[1],
                expected_file_sha256=str(
                    document["authorized_execution_bindings_sha256"]
                ),
                expected_configuration_id=str(document["configuration_id"]),
                expected_shared_bank_configuration_sha256=str(
                    document["shared_bank_configuration_sha256"]
                ),
                expected_input_bundle_sha256=str(document["input_bundle_sha256"]),
                expected_corpus_lock_bundle_sha256=str(
                    document["corpus_lock_bundle_sha256"]
                ),
                support_evidence_roots=support_evidence_roots,
            )
        except (OSError, ValueError) as error:
            raise ReleaseLockError(
                "P06 V3 authorized execution closure differs"
            ) from error
    elif authority.get("artifact_sha256") is None:
        raise ReleaseLockError("P06 V3 authorized execution authority is absent")
    return document


def validate_p06_release_bundle_manifest(
    *,
    release_root: Path,
    manifest_path: Path,
    support_evidence_roots: Mapping[str, Path] | None = None,
) -> Mapping[str, object]:
    """Reopen the final release and reject every non-self filesystem entry."""

    return _validate_p06_release_bundle_manifest(
        release_root=release_root,
        manifest_path=manifest_path,
        support_evidence_roots=support_evidence_roots,
        transaction_id=None,
    )


def _validate_support_evidence_trees(
    closure: Mapping[str, object],
    *,
    support_evidence_roots: Mapping[str, Path],
) -> None:
    """Rehash every external support tree, including the complete run tree."""

    if set(support_evidence_roots) != P06_SUPPORT_EVIDENCE_ROOT_IDS:
        raise ReleaseLockError("support evidence roots are not exact")
    ordered_root_ids = (*_SUPPORT_TREE_ROOT_IDS, CALIBRATION_RUN_SUPPORT_ROOT_ID)
    resolved_roots = {
        root_id: _resolve_support_evidence_root(
            root_id=root_id,
            root=support_evidence_roots[root_id],
        )
        for root_id in ordered_root_ids
    }
    support_rows = closure.get("support_evidence_trees")
    if (
        not isinstance(support_rows, list)
        or any(not isinstance(row, dict) for row in support_rows)
        or [row.get("id") for row in support_rows] != list(SUPPORT_TREE_IDS)
    ):
        raise ReleaseLockError("support evidence closure order differs")
    for row, expected_id, expected_root_id in zip(
        support_rows,
        SUPPORT_TREE_IDS,
        _SUPPORT_TREE_ROOT_IDS,
    ):
        _validate_rebound_evidence_tree(
            row,
            expected_id=expected_id,
            expected_root_id=expected_root_id,
            root=resolved_roots[expected_root_id],
            direct_child=False,
        )
    calibration_row = closure.get("calibration_run_tree")
    _validate_rebound_evidence_tree(
        calibration_row,
        expected_id="complete_calibration_run_tree",
        expected_root_id=CALIBRATION_RUN_SUPPORT_ROOT_ID,
        root=resolved_roots[CALIBRATION_RUN_SUPPORT_ROOT_ID],
        direct_child=True,
    )


def _resolve_support_evidence_root(*, root_id: str, root: Path) -> Path:
    """Resolve one explicit directory root without accepting symlink traversal."""

    if not isinstance(root, Path) or not root.is_absolute():
        raise ReleaseLockError(
            f"support evidence root is not an absolute pathlib.Path: {root_id}"
        )
    normalized = Path(os.path.normpath(os.fspath(root)))
    if normalized != root:
        raise ReleaseLockError(f"support evidence root is not normalized: {root_id}")
    cursor = Path(root.anchor)
    components = [cursor]
    for part in root.parts[1:]:
        cursor /= part
        components.append(cursor)
    for index, component in enumerate(components):
        try:
            metadata = os.lstat(component)
        except OSError as error:
            raise ReleaseLockError(
                f"support evidence root is absent or inaccessible: {root_id}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise ReleaseLockError(
                f"support evidence root traverses a symbolic link: {root_id}"
            )
        if not stat.S_ISDIR(metadata.st_mode):
            location = "root" if index == len(components) - 1 else "ancestor"
            raise ReleaseLockError(
                f"support evidence {location} is not a directory: {root_id}"
            )
    try:
        return root.resolve(strict=True)
    except OSError as error:
        raise ReleaseLockError(
            f"support evidence root cannot be resolved: {root_id}"
        ) from error


def _validate_rebound_evidence_tree(
    row: object,
    *,
    expected_id: str,
    expected_root_id: str,
    root: Path,
    direct_child: bool,
) -> None:
    """Recreate one exact directory-tree binding from its authoritative root."""

    if (
        not isinstance(row, dict)
        or row.get("id") != expected_id
        or row.get("root_id") != expected_root_id
        or row.get("kind") != "directory_tree"
    ):
        raise ReleaseLockError(f"support evidence tree contract differs: {expected_id}")
    relative_path = _relative_path(str(row.get("path")))
    if direct_child and len(relative_path.parts) != 1:
        raise ReleaseLockError(
            "calibration run tree is not a direct child of its support root"
        )
    try:
        rebound = evidence_binding(
            identifier=expected_id,
            root_id=expected_root_id,
            path=_path_under_root(root, relative_path.as_posix()),
            root=root,
        )
    except (OSError, ValueError) as error:
        raise ReleaseLockError(
            f"support evidence tree cannot be rebound: {expected_id}"
        ) from error
    if rebound != row:
        raise ReleaseLockError(f"support evidence tree changed: {expected_id}")


def _validated_json_artifact(
    *,
    release_root: Path,
    binding: Mapping[str, object],
    schema_path: Path,
    label: str,
) -> Mapping[str, object]:
    document = _read_strict_json(
        _path_under_root(release_root, str(binding["path"]))
    )
    try:
        validate_schema(document, schema_path)
    except ValueError as error:
        raise ReleaseLockError(f"{label} schema validation failed") from error
    return document


def _validated_canonical_json_artifact(
    *,
    release_root: Path,
    binding: Mapping[str, object],
    schema_path: Path,
    label: str,
    trailing_lf: bool = True,
) -> Mapping[str, object]:
    """Validate one role's schema and exact canonical serialization."""

    document = _validated_json_artifact(
        release_root=release_root,
        binding=binding,
        schema_path=schema_path,
        label=label,
    )
    payload = _read_regular_file(
        _path_under_root(release_root, str(binding["path"]))
    )
    expected = _canonical_bytes(document) + (b"\n" if trailing_lf else b"")
    if payload != expected:
        raise ReleaseLockError(f"{label} is not canonical JSON")
    return document


def _require_manifest_hash(
    document: Mapping[str, object],
    *,
    field: str,
    label: str,
) -> str:
    unhashed = dict(document)
    unhashed.pop(field, None)
    actual = _sha256(_canonical_bytes(unhashed))
    if document.get(field) != actual:
        raise ReleaseLockError(f"{label} self-hash mismatch")
    return actual


def _binding_fields(binding: Mapping[str, object]) -> Mapping[str, object]:
    return {
        "path": binding.get("path"),
        "sha256": binding.get("sha256"),
        "size_bytes": binding.get("size_bytes"),
    }


def validate_p06_configuration_lock_v2(
    *,
    release_root: Path,
    expected_file_sha256: str,
) -> Mapping[str, object]:
    """Reopen the fixed V2 lock, its schema, self-hash, and nine file bytes."""

    path = _path_under_root(release_root, "configuration-lock-v2.json")
    actual_binding = _binding(path, "configuration-lock-v2.json")
    if actual_binding["sha256"] != _require_sha256(
        expected_file_sha256,
        "P06 configuration lock V2 file SHA-256",
    ):
        raise ReleaseLockError("P06 configuration lock V2 file binding differs")
    document = _validated_json_artifact(
        release_root=release_root,
        binding=actual_binding,
        schema_path=CONFIGURATION_LOCK_V2_SCHEMA,
        label="P06 configuration lock V2",
    )
    payload = _read_regular_file(path)
    if payload != _canonical_bytes(document) + b"\n":
        raise ReleaseLockError(
            "P06 configuration lock V2 is not canonical one-LF JSON"
        )
    _require_manifest_hash(
        document,
        field="manifest_sha256",
        label="P06 configuration lock V2",
    )
    rows = document.get("configuration_files")
    if not isinstance(rows, list):
        raise ReleaseLockError("P06 configuration lock V2 file rows are absent")
    for row in rows:
        if not isinstance(row, dict):
            raise ReleaseLockError("P06 configuration lock V2 file row is invalid")
        relative = str(row.get("path"))
        rebound = _binding(_path_under_root(release_root, relative), relative)
        if _binding_fields(row) != rebound:
            raise ReleaseLockError(
                f"P06 configuration lock V2 file changed: {row.get('id')}"
            )
    return document


def _validate_p06_configuration_lock_v2_cross_bindings(
    *,
    release_root: Path,
    binding: Mapping[str, object],
    bundle: Mapping[str, object],
    artifacts: Mapping[str, Mapping[str, object]],
    selection_binding: Mapping[str, object],
    evaluation_binding: Mapping[str, object],
    candidate_vector_sha256: str,
    shared_bank_configuration_sha256: str,
) -> Mapping[str, object]:
    """Schema-validate and independently rebind the nine-file V2 lock."""

    document = validate_p06_configuration_lock_v2(
        release_root=release_root,
        expected_file_sha256=str(binding["sha256"]),
    )
    configuration_ids = (
        "locked_mapping",
        "locked_operator_bank",
        "locked_quality_policy",
        "locked_metric_policy",
        "locked_compiler_input_v2",
        "direct2x_lut",
        "direct3over2_lut",
        "native_parity_manifest",
        "lut_manifest",
    )
    expected_files = [
        {"id": identifier, **_binding_fields(artifacts[identifier])}
        for identifier in configuration_ids
    ]
    if (
        document.get("locked_utc") != bundle.get("locked_utc")
        or document.get("configuration_id") != bundle.get("configuration_id")
        or document.get("candidate_vector_sha256")
        != candidate_vector_sha256
        or document.get("shared_bank_configuration_sha256")
        != shared_bank_configuration_sha256
        or document.get("calibration_selection") != selection_binding
        or document.get("selected_evaluation") != evaluation_binding
        or document.get("configuration_files") != expected_files
        or document.get("candidate_bytes_rewritten_after_selection") is not False
        or document.get("holdout_accessed") is not False
    ):
        raise ReleaseLockError("P06 configuration lock V2 identity differs")
    return document


def _validate_calibration_attempt_ledger_role_v3(
    *,
    release_root: Path,
    artifact_binding: Mapping[str, object],
    run_ledger: Mapping[str, object],
) -> None:
    """Schema-decode and replay attempts without weakening external references."""

    declared = run_ledger.get("attempt_ledger")
    if not isinstance(declared, dict) or _binding_fields(declared) != (
        _binding_fields(artifact_binding)
    ):
        raise ReleaseLockError("P06 V3 attempt-ledger binding differs")
    payload = _read_regular_file(
        _path_under_root(release_root, str(artifact_binding["path"]))
    )
    try:
        from validation.calibration_v2.calibration_persistence_v2 import (
            AttemptLedgerBindingV2,
            CalibrationPersistenceAdapterV2,
        )
        from validation.calibration_v2.calibration_scheduler_v2 import (
            replay_development_attempts_v2,
        )

        adapter = CalibrationPersistenceAdapterV2(release_root)
        binding = AttemptLedgerBindingV2(
            path=str(declared["path"]),
            sha256=str(declared["sha256"]),
            size_bytes=int(declared["size_bytes"]),
            record_count=int(declared["record_count"]),
            last_record_sha256=str(declared["last_record_sha256"]),
        )
        documents = adapter._attempt_documents_from_bytes(payload)
        records = tuple(
            adapter.decode_attempt_record(
                document,
                expected_run_id=str(run_ledger["run_id"]),
                reopen_references=False,
            )
            for document in documents
        )
        if (
            len(records) != binding.record_count
            or records[-1].record_sha256 != binding.last_record_sha256
        ):
            raise ReleaseLockError("P06 V3 attempt-ledger summary differs")
        replay_development_attempts_v2(
            adapter.plan,
            records,
            expected_attempt_count=binding.record_count,
            expected_last_record_sha256=binding.last_record_sha256,
        )
    except ReleaseLockError:
        raise
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise ReleaseLockError(
            "P06 V3 attempt-ledger semantic replay failed"
        ) from error


def _validate_run_artifact_manifest_role_v3(
    *,
    document: Mapping[str, object],
    artifact_binding: Mapping[str, object],
    run_ledger: Mapping[str, object],
    evidence_closure: Mapping[str, object],
) -> None:
    """Validate the run-manifest relation and its exact path closure."""

    if run_ledger.get("artifact_manifest") != _binding_fields(artifact_binding):
        raise ReleaseLockError("P06 V3 run artifact-manifest binding differs")
    rows = document.get("artifacts")
    directories = document.get("directories")
    if not isinstance(rows, list) or not isinstance(directories, list):
        raise ReleaseLockError("P06 V3 run artifact manifest closure is absent")
    paths = [str(row.get("path")) for row in rows if isinstance(row, dict)]
    hashes = [str(row.get("sha256")) for row in rows if isinstance(row, dict)]
    expected_directories = set()
    for path in paths:
        parts = PurePosixPath(path).parts
        for depth in range(1, len(parts)):
            expected_directories.add(PurePosixPath(*parts[:depth]).as_posix())
    components = evidence_closure.get("components")
    commits = {
        component.get("local_green_commit")
        for component in components
        if isinstance(component, dict)
    } if isinstance(components, list) else set()
    if (
        len(paths) != len(rows)
        or paths != sorted(paths)
        or len(paths) != len(set(paths))
        or len(hashes) != len(set(hashes))
        or directories != sorted(directories)
        or len(directories) != len(set(directories))
        or set(directories) != expected_directories
        or document.get("working_tree_clean") is not True
        or commits != {document.get("project_commit")}
    ):
        raise ReleaseLockError("P06 V3 run artifact manifest semantics differ")


def _tracked_corpus_manifest_sha256_v3() -> str:
    document = _read_strict_json(CORPUS_LOCK_PATH)
    try:
        validate_schema(document, CORPUS_LOCK_SCHEMA)
    except ValueError as error:
        raise ReleaseLockError("tracked corpus lock schema validation failed") from error
    return _require_manifest_hash(
        document,
        field="manifest_sha256",
        label="tracked corpus lock",
    )


def _validate_live_preopen_role_v3(
    document: Mapping[str, object],
) -> None:
    """Bind preopen state to the corpus manifest, not the bundle digest."""

    if (
        document.get("verification_status") != "pass"
        or document.get("access_status") != "unopened"
        or document.get("access_count") != 0
        or document.get("open_intent_anchor_present") is not False
        or document.get("pixel_content_included") is not False
        or document.get("corpus_binding_sha256")
        != _tracked_corpus_manifest_sha256_v3()
    ):
        raise ReleaseLockError("P06 V3 live preopen authority differs")


def _require_unmodified_selected_candidate_authority_v3(
    mapping: Mapping[str, object],
    operator_bank: Mapping[str, object],
) -> None:
    """Reject every attempt to add post-selection claims to measured bytes."""

    unselected = {
        "calibration_selection_sha256": None,
        "selected_evaluation_sha256": None,
    }
    if (
        mapping.get("status") != "calibration_candidate"
        or operator_bank.get("status") != "calibration_candidate"
        or mapping.get("selection_binding") != unselected
        or operator_bank.get("selection_binding") != unselected
    ):
        raise ReleaseLockError(
            "P06 V3 selected candidate bytes contain a post-selection mutation"
        )


def _validate_p06_release_v3_cross_bindings(
    *,
    release_root: Path,
    bundle: Mapping[str, object],
    artifacts: Mapping[str, Mapping[str, object]],
    support_evidence_roots: Mapping[str, Path] | None = None,
) -> Mapping[str, object]:
    """Bind the schema-2 identity triple to format-1.2 bytes and P07 authority."""

    selection = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["calibration_selection"],
        schema_path=CALIBRATION_SELECTION_V2_SCHEMA,
        label="calibration selection V2",
    )
    evaluation = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["selected_evaluation"],
        schema_path=CANDIDATE_EVALUATION_V2_SCHEMA,
        label="selected evaluation V2",
    )
    ledger = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["calibration_run_ledger"],
        schema_path=CALIBRATION_RUN_LEDGER_V2_SCHEMA,
        label="calibration run ledger V2",
    )
    closure = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["evidence_closure"],
        schema_path=P06_EVIDENCE_CLOSURE_V2_SCHEMA,
        label="P06 evidence closure V2",
    )
    mapping = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_mapping"],
        schema_path=VIDEO_MAPPING_V2_SCHEMA,
        label="locked mapping V2",
    )
    operator_bank = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_operator_bank"],
        schema_path=OPERATOR_BANK_V2_SCHEMA,
        label="locked operator bank V2",
    )
    _require_unmodified_selected_candidate_authority_v3(
        mapping,
        operator_bank,
    )
    compiler = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_compiler_input_v2"],
        schema_path=LOCKED_COMPILER_INPUT_V2_SCHEMA,
        label="locked compiler input V2",
    )
    admission = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["validation_candidate_development_evidence"],
        schema_path=VALIDATION_ADMISSION_V2_SCHEMA,
        label="validation candidate development evidence V2",
    )
    baseline_budget = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["baseline_ablation_budget_v2"],
        schema_path=BASELINE_ABLATION_BUDGET_V2_SCHEMA,
        label="baseline ablation budget V2",
    )
    live_preopen = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["live_holdout_preopen_verification"],
        schema_path=LIVE_HOLDOUT_PREOPEN_VERIFICATION_SCHEMA,
        label="live holdout preopen verification",
    )
    quality_policy = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_quality_policy"],
        schema_path=LOCKED_QUALITY_POLICY_V2_SCHEMA,
        label="locked quality policy V2",
    )
    metric_policy = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_metric_policy"],
        schema_path=LOCKED_METRIC_POLICY_SCHEMA,
        label="locked metric policy V2",
        trailing_lf=False,
    )
    native_parity = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["native_parity_manifest"],
        schema_path=NATIVE_PARITY_V3_SCHEMA,
        label="native parity manifest V3",
    )
    lut_manifest = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["lut_manifest"],
        schema_path=LUT_MANIFEST_V3_SCHEMA,
        label="LUT manifest V3",
    )
    run_artifact_manifest = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=artifacts["artifact_manifest"],
        schema_path=RUN_ARTIFACT_MANIFEST_V2_SCHEMA,
        label="calibration run artifact manifest V2",
    )
    non_ash_documents = {
        "non_ash_development_attempt_ledger": (
            _validated_canonical_json_artifact(
                release_root=release_root,
                binding=artifacts["non_ash_development_attempt_ledger"],
                schema_path=NON_ASH_ATTEMPT_LEDGER_V2_SCHEMA,
                label="non-ASH development attempt ledger V2",
            )
        ),
        "non_ash_development_selection": (
            _validated_canonical_json_artifact(
                release_root=release_root,
                binding=artifacts["non_ash_development_selection"],
                schema_path=NON_ASH_SELECTION_V2_SCHEMA,
                label="non-ASH development selection V2",
            )
        ),
        "non_ash_validation_neighbor_manifest": (
            _validated_canonical_json_artifact(
                release_root=release_root,
                binding=artifacts["non_ash_validation_neighbor_manifest"],
                schema_path=NON_ASH_NEIGHBOR_MANIFEST_V2_SCHEMA,
                label="non-ASH validation neighbor manifest V2",
            )
        ),
        "non_ash_validation_selection": (
            _validated_canonical_json_artifact(
                release_root=release_root,
                binding=artifacts["non_ash_validation_selection"],
                schema_path=NON_ASH_SELECTION_V2_SCHEMA,
                label="non-ASH validation selection V2",
            )
        ),
    }
    for document, label in (
        (selection, "calibration selection V2"),
        (evaluation, "selected evaluation V2"),
        (ledger, "calibration run ledger V2"),
        (closure, "P06 evidence closure V2"),
        (admission, "validation candidate development evidence V2"),
        (baseline_budget, "baseline ablation budget V2"),
    ):
        _require_manifest_hash(document, field="artifact_sha256", label=label)

    _require_manifest_hash(
        quality_policy,
        field="manifest_sha256",
        label="locked quality policy V2",
    )
    _require_manifest_hash(
        metric_policy,
        field="policy_sha256",
        label="locked metric policy V2",
    )
    _require_manifest_hash(
        native_parity,
        field="manifest_sha256",
        label="native parity manifest V3",
    )
    _require_manifest_hash(
        lut_manifest,
        field="manifest_sha256",
        label="LUT manifest V3",
    )
    for identifier, field in (
        ("non_ash_development_attempt_ledger", "ledger_sha256"),
        ("non_ash_development_selection", "development_selection_sha256"),
        ("non_ash_validation_neighbor_manifest", "manifest_sha256"),
        ("non_ash_validation_selection", "validation_selection_sha256"),
    ):
        _require_manifest_hash(
            non_ash_documents[identifier],
            field=field,
            label=identifier.replace("_", " "),
        )

    selected = selection.get("selected")
    if not isinstance(selected, dict):
        raise ReleaseLockError("P06 V3 selected evaluation binding is absent")
    selected_binding = selected.get("evaluation")
    selected_artifact_binding = _binding_fields(artifacts["selected_evaluation"])
    selected_hash = str(artifacts["selected_evaluation"]["sha256"])
    selection_hash = str(artifacts["calibration_selection"]["sha256"])
    if (
        selected_binding != selected_artifact_binding
        or PurePosixPath(str(selected_artifact_binding["path"])).stem
        != selected_hash
        or selected.get("candidate_vector_sha256")
        != evaluation.get("candidate_vector_sha256")
        or selected.get("evaluation_semantic_sha256")
        != evaluation.get("evaluation_semantic_sha256")
    ):
        raise ReleaseLockError("P06 V3 selected evaluation identity differs")

    admission_binding = _binding_fields(
        artifacts["validation_candidate_development_evidence"]
    )
    attempt_binding = ledger.get("attempt_ledger")
    development_trace = admission.get("development_trace")
    if (
        selection.get("validation_candidate_development_evidence")
        != admission_binding
        or ledger.get("validation_admission") != admission_binding
        or admission.get("run_id") != selection.get("run_id")
        or admission.get("shared_bank_configuration_sha256")
        != selection.get("shared_bank_configuration_sha256")
        or not isinstance(attempt_binding, dict)
        or not isinstance(development_trace, dict)
        or development_trace.get("attempt_ledger")
        != _binding_fields(artifacts["calibration_attempt_ledger"])
        or development_trace.get("attempt_count")
        != attempt_binding.get("record_count")
        or development_trace.get("last_record_sha256")
        != attempt_binding.get("last_record_sha256")
    ):
        raise ReleaseLockError("P06 V3 validation-admission identity differs")
    _validate_calibration_attempt_ledger_role_v3(
        release_root=release_root,
        artifact_binding=artifacts["calibration_attempt_ledger"],
        run_ledger=ledger,
    )
    _validate_run_artifact_manifest_role_v3(
        document=run_artifact_manifest,
        artifact_binding=artifacts["artifact_manifest"],
        run_ledger=ledger,
        evidence_closure=closure,
    )

    baseline_payload = _read_regular_file(BASELINE_ABLATION_BUDGET_V2_PATH)
    released_baseline_payload = _read_regular_file(
        _path_under_root(
            release_root,
            str(artifacts["baseline_ablation_budget_v2"]["path"]),
        )
    )
    if released_baseline_payload != baseline_payload:
        raise ReleaseLockError("P06 V3 baseline ablation budget authority differs")
    _validate_live_preopen_role_v3(live_preopen)

    control_binding = selection.get("selected_control_authorization_bundle")
    if not isinstance(control_binding, dict):
        raise ReleaseLockError("P06 V3 selected control authorization is absent")
    control_actual = _binding(
        _path_under_root(release_root, str(control_binding.get("path"))),
        str(control_binding.get("path")),
    )
    if control_actual != _binding_fields(control_binding):
        raise ReleaseLockError("P06 V3 selected control authorization changed")
    control_bundle = _validated_canonical_json_artifact(
        release_root=release_root,
        binding=control_binding,
        schema_path=CONTROL_AUTHORIZATION_BUNDLE_V2_SCHEMA,
        label="selected control authorization bundle V2",
    )
    _require_manifest_hash(
        control_bundle,
        field="artifact_sha256",
        label="selected control authorization bundle V2",
    )
    if (
        quality_policy.get("run_id") != selection.get("run_id")
        or quality_policy.get("shared_bank_configuration_sha256")
        != selection.get("shared_bank_configuration_sha256")
        or quality_policy.get("selected_control_authorization_bundle")
        != control_binding
        or quality_policy.get("control_selections")
        != control_bundle.get("control_selections")
        or quality_policy.get("holdout_accessed") is not False
        or control_bundle.get("run_id") != selection.get("run_id")
        or control_bundle.get("split") != "validation"
        or control_bundle.get("shared_bank_configuration_sha256")
        != selection.get("shared_bank_configuration_sha256")
    ):
        raise ReleaseLockError("P06 V3 quality/control authority differs")

    dependencies = control_bundle.get("dependency_bindings")
    if not isinstance(dependencies, list):
        raise ReleaseLockError("P06 V3 selected control dependencies are absent")
    expected_non_ash_stage = {
        "non_ash_development_attempt_ledger": (
            "p06_non_ash_selector_attempt_ledger_v2",
            None,
        ),
        "non_ash_development_selection": (
            "p06_non_ash_selector_selection_v2",
            "development_provisional",
        ),
        "non_ash_validation_neighbor_manifest": (
            "p06_non_ash_validation_neighbor_manifest_v2",
            None,
        ),
        "non_ash_validation_selection": (
            "p06_non_ash_selector_selection_v2",
            "validation_final",
        ),
    }
    for identifier, (kind, stage) in expected_non_ash_stage.items():
        artifact = artifacts[identifier]
        document = non_ash_documents[identifier]
        matches = [
            row
            for row in dependencies
            if isinstance(row, dict)
            and row.get("artifact_kind") == kind
            and row.get("sha256") == artifact.get("sha256")
            and row.get("size_bytes") == artifact.get("size_bytes")
        ]
        if (
            len(matches) != 1
            or (stage is not None and document.get("selection_stage") != stage)
            or document.get("shared_bank_configuration_sha256")
            != selection.get("shared_bank_configuration_sha256")
        ):
            raise ReleaseLockError(
                f"P06 V3 projected non-ASH role differs: {identifier}"
            )
    non_ash_ledger = non_ash_documents["non_ash_development_attempt_ledger"]
    non_ash_development = non_ash_documents["non_ash_development_selection"]
    non_ash_neighbor = non_ash_documents[
        "non_ash_validation_neighbor_manifest"
    ]
    non_ash_validation = non_ash_documents["non_ash_validation_selection"]
    if (
        non_ash_development.get("development_attempt_ledger_sha256")
        != non_ash_ledger.get("ledger_sha256")
        or non_ash_neighbor.get("development_attempt_ledger_sha256")
        != non_ash_ledger.get("ledger_sha256")
        or non_ash_neighbor.get("development_selection_sha256")
        != non_ash_development.get("development_selection_sha256")
        or non_ash_validation.get("development_selection_sha256")
        != non_ash_development.get("development_selection_sha256")
        or non_ash_validation.get("validation_neighbor_manifest_sha256")
        != non_ash_neighbor.get("manifest_sha256")
    ):
        raise ReleaseLockError("P06 V3 non-ASH predecessor chain differs")

    physical_items = evaluation.get("physical_candidate_items")
    if (
        not isinstance(physical_items, list)
        or len(physical_items) != 48
        or any(
            not isinstance(item, list)
            or len(item) != 2
            or not isinstance(item[0], str)
            for item in physical_items
        )
        or len({str(item[0]) for item in physical_items}) != 48
    ):
        raise ReleaseLockError("P06 V3 physical candidate identity is invalid")
    physical = {str(item[0]): item[1] for item in physical_items}
    try:
        from validation.calibration_v2.calibration_plan_codec import (
            candidate_vector_sha256_v2,
            shared_bank_configuration_sha256_v2,
            validate_candidate_constraints_v2,
        )
        from validation.calibration_v2.shared_bank_artifacts_v2 import (
            SharedBankArtifactMaterializerV2,
        )

        plan = SharedBankArtifactMaterializerV2(
            CALIBRATION_ROOT.parents[1]
        ).plan
        validate_candidate_constraints_v2(physical, plan)
        candidate_hash = candidate_vector_sha256_v2(physical, plan)
        bank_hash = shared_bank_configuration_sha256_v2(physical, plan)
    except (OSError, ValueError) as error:
        raise ReleaseLockError(
            "P06 V3 selected physical candidate cannot be authenticated"
        ) from error
    if (
        candidate_hash != evaluation.get("candidate_vector_sha256")
        or candidate_hash != selected.get("candidate_vector_sha256")
        or bank_hash != evaluation.get("shared_bank_configuration_sha256")
        or bank_hash != selection.get("shared_bank_configuration_sha256")
        or bank_hash != bundle.get("shared_bank_configuration_sha256")
    ):
        raise ReleaseLockError("P06 V3 candidate/shared-bank identity differs")

    _validate_p06_configuration_lock_v2_cross_bindings(
        release_root=release_root,
        binding=artifacts["configuration_lock"],
        bundle=bundle,
        artifacts=artifacts,
        selection_binding=_binding_fields(artifacts["calibration_selection"]),
        evaluation_binding=selected_artifact_binding,
        candidate_vector_sha256=candidate_hash,
        shared_bank_configuration_sha256=bank_hash,
    )

    run_id = selection.get("run_id")
    if any(
        value != run_id
        for value in (
            evaluation.get("run_id"),
            ledger.get("run_id"),
            closure.get("run_id"),
        )
    ) or any(
        value != bundle.get("input_bundle_sha256")
        for value in (
            selection.get("input_bundle_sha256"),
            ledger.get("input_bundle_sha256"),
            closure.get("input_bundle_sha256"),
        )
    ):
        raise ReleaseLockError("P06 V3 run or input-bundle identity differs")
    if (
        closure.get("corpus_lock_bundle_sha256")
        != bundle.get("corpus_lock_bundle_sha256")
        or closure.get("configuration_id") != bundle.get("configuration_id")
        or closure.get("shared_bank_configuration_sha256") != bank_hash
        or selection.get("calibration_run_ledger")
        != _binding_fields(artifacts["calibration_run_ledger"])
        or closure.get("calibration_run_ledger")
        != _binding_fields(artifacts["calibration_run_ledger"])
        or closure.get("calibration_selection")
        != _binding_fields(artifacts["calibration_selection"])
        or closure.get("selected_evaluation") != selected_artifact_binding
        or closure.get("artifact_manifest")
        != _binding_fields(artifacts["artifact_manifest"])
    ):
        raise ReleaseLockError("P06 V3 ledger/evidence closure identity differs")
    candidate_rows = ledger.get("candidate_evaluations")
    if not isinstance(candidate_rows, list) or not any(
        isinstance(row, dict)
        and row.get("split") == "validation"
        and row.get("candidate_vector_sha256") == candidate_hash
        and row.get("binding") == selected_artifact_binding
        for row in candidate_rows
    ):
        raise ReleaseLockError("P06 V3 run ledger does not bind the selected evaluation")

    expected_candidate_identity = mapping.get("candidate_identity")
    if (
        not isinstance(expected_candidate_identity, dict)
        or expected_candidate_identity != operator_bank.get("candidate_identity")
        or expected_candidate_identity.get("physical_candidate_items")
        != physical_items
        or expected_candidate_identity.get("candidate_vector_sha256")
        != candidate_hash
        or expected_candidate_identity.get("shared_bank_configuration_sha256")
        != bank_hash
        or mapping.get("configuration_id") != bundle.get("configuration_id")
        or operator_bank.get("configuration_id") != bundle.get("configuration_id")
        # The selected evaluation already content-addresses the exact
        # calibration-candidate mapping, operator, compiler input, and LUT
        # bytes.  Rewriting either shared-bank document after selection would
        # change all downstream hashes; embedding ``selected_hash`` in those
        # bytes would additionally introduce a cryptographic cycle.  The V3
        # release manifest and evidence closure provide the later selection
        # authority, while these files must remain the measured candidate
        # bytes without a post-selection claim.
    ):
        raise ReleaseLockError("P06 V3 mapping/operator identity differs")

    compiler_path = _path_under_root(
        release_root,
        str(artifacts["locked_compiler_input_v2"]["path"]),
    )
    try:
        from validation.calibration_v2.reference.lut_oracle_v2 import (
            load_locked_compiler_input_v2,
            validate_lut_v2,
        )

        parsed_compiler = load_locked_compiler_input_v2(compiler_path)
    except (OSError, ValueError) as error:
        raise ReleaseLockError("P06 V3 compiler input is invalid") from error
    compiler_bindings = compiler.get("hash_bindings")
    compiler_payload_hash = (
        compiler_bindings.get("compiler_inputs_sha256")
        if isinstance(compiler_bindings, dict)
        else None
    )
    if (
        compiler.get("configuration_id") != bundle.get("configuration_id")
        or not isinstance(compiler_bindings, dict)
        or compiler_bindings.get("mapping_sha256")
        != artifacts["locked_mapping"]["sha256"]
        or compiler_bindings.get("operator_bank_sha256")
        != artifacts["locked_operator_bank"]["sha256"]
        or compiler_bindings.get("metric_policy_sha256")
        != artifacts["locked_metric_policy"]["sha256"]
        or compiler_bindings.get("corpus_lock_bundle_sha256")
        != bundle.get("corpus_lock_bundle_sha256")
        or evaluation.get("compiler_input")
        != {
            "file_sha256": artifacts["locked_compiler_input_v2"]["sha256"],
            "payload_sha256": compiler_payload_hash,
        }
    ):
        raise ReleaseLockError("P06 V3 compiler input binding differs")

    evaluation_routes = evaluation.get("route_lut_bindings")
    if not isinstance(evaluation_routes, list) or len(evaluation_routes) != 2:
        raise ReleaseLockError("P06 V3 selected route LUT bindings are absent")
    validated_routes: list[Mapping[str, object]] = []
    for evaluation_row, identifier, oracle_route in zip(
        evaluation_routes,
        ("direct2x_lut", "direct3over2_lut"),
        ("direct_2x", "direct_3_over_2"),
    ):
        payload = _read_regular_file(
            _path_under_root(release_root, str(artifacts[identifier]["path"]))
        )
        try:
            validated = validate_lut_v2(
                payload,
                expected_configuration=parsed_compiler,
                expected_route=oracle_route,
            )
        except (OSError, ValueError) as error:
            raise ReleaseLockError(f"P06 V3 released LUT is invalid: {identifier}") from error
        expected_route_name = (
            "direct-2x" if oracle_route == "direct_2x" else "direct-3over2"
        )
        if evaluation_row != {
            "route": expected_route_name,
            "whole_file_sha256": artifacts[identifier]["sha256"],
            "payload_sha256": validated.payload_sha256,
        }:
            raise ReleaseLockError(f"P06 V3 selected LUT identity differs: {identifier}")
        validated_routes.append(
            {
                "identifier": identifier,
                "oracle_route": oracle_route,
                "validated": validated,
            }
        )

    compiler_file_binding = _binding_fields(
        artifacts["locked_compiler_input_v2"]
    )
    parity_rows = native_parity.get("routes")
    lut_rows = lut_manifest.get("routes")
    implementations = native_parity.get("implementations")
    if (
        native_parity.get("configuration_id")
        != bundle.get("configuration_id")
        or native_parity.get("compiler_input") != compiler_file_binding
        or native_parity.get("input_hashes") != compiler_bindings
        or native_parity.get("all_routes_byte_identical") is not True
        or native_parity.get("holdout_accessed") is not False
        or not isinstance(parity_rows, list)
        or not isinstance(implementations, dict)
        or lut_manifest.get("configuration_id")
        != bundle.get("configuration_id")
        or lut_manifest.get("compiler_input") != compiler_file_binding
        or lut_manifest.get("hash_bindings") != compiler_bindings
        or lut_manifest.get("native_parity_manifest")
        != _binding_fields(artifacts["native_parity_manifest"])
        or lut_manifest.get("holdout_accessed") is not False
        or not isinstance(lut_rows, list)
    ):
        raise ReleaseLockError("P06 V3 native parity or LUT manifest identity differs")
    for implementation_id in ("production_swift", "independent_test_python"):
        row = implementations.get(implementation_id)
        if not isinstance(row, dict):
            raise ReleaseLockError(
                f"P06 V3 parity implementation is absent: {implementation_id}"
            )
        rebound = _binding(
            _path_under_root(release_root, str(row.get("path"))),
            str(row.get("path")),
        )
        if row != rebound:
            raise ReleaseLockError(
                f"P06 V3 parity implementation changed: {implementation_id}"
            )
    if len(parity_rows) != 2 or len(lut_rows) != 2:
        raise ReleaseLockError("P06 V3 native parity or LUT route count differs")
    for parity_row, lut_row, validated_row in zip(
        parity_rows,
        lut_rows,
        validated_routes,
    ):
        identifier = str(validated_row["identifier"])
        oracle_route = str(validated_row["oracle_route"])
        validated = validated_row["validated"]
        runtime_route = (
            "direct-2x" if oracle_route == "direct_2x" else "direct-3over2"
        )
        production_binding = _binding_fields(artifacts[identifier])
        independent = parity_row.get("independent_test_python") \
            if isinstance(parity_row, dict) else None
        if not isinstance(independent, dict):
            raise ReleaseLockError(
                f"P06 V3 independent parity output is absent: {identifier}"
            )
        independent_path = _path_under_root(
            release_root,
            str(independent.get("path")),
        )
        independent_binding = _binding(
            independent_path,
            str(independent.get("path")),
        )
        production_payload = _read_regular_file(
            _path_under_root(release_root, str(production_binding["path"]))
        )
        independent_payload = _read_regular_file(independent_path)
        route_contract = ROUTES[oracle_route]
        route_selection = parsed_compiler.routes[oracle_route]
        expected_lut_row = {
            "route": runtime_route,
            "route_id": route_contract.route_id,
            "scale_numerator": route_contract.scale_numerator,
            "scale_denominator": route_contract.scale_denominator,
            "phase_count": route_contract.phase_count,
            "context_count": 4,
            "valid_state_count": 256,
            "plane_count": validated.plane_count,
            "luma_coordinate_policy": route_selection.luma_coordinate_policy,
            "chroma_coordinate_policy": route_selection.chroma_coordinate_policy,
            "analysis_grid_source_step": route_selection.analysis_grid_source_step,
            "entry_count": validated.entry_count,
            "parameter_count": validated.parameter_count,
            "path": route_contract.filename,
            "whole_file_size_bytes": len(production_payload),
            "whole_file_sha256": validated.whole_file_sha256,
            "payload_sha256": validated.payload_sha256,
            "header_crc32": f"0x{validated.header_crc32:08X}",
            "payload_crc32": f"0x{validated.payload_crc32:08X}",
        }
        if (
            not isinstance(parity_row, dict)
            or parity_row.get("route") != runtime_route
            or parity_row.get("production_swift") != production_binding
            or independent != independent_binding
            or parity_row.get("byte_identical") is not True
            or parity_row.get("payload_hash_identical") is not True
            or parity_row.get("first_differing_byte_offset") is not None
            or production_payload != independent_payload
            or lut_row != expected_lut_row
        ):
            raise ReleaseLockError(
                f"P06 V3 parity/LUT route semantics differ: {identifier}"
            )

    try:
        from validation.calibration_v2.p07.execution_authority_v2 import (
            FILENAME as AUTHORITY_FILENAME,
            canonical_file_bytes as canonical_authority_bytes,
        )

        authority_path = _path_under_root(release_root, AUTHORITY_FILENAME)
        authority_payload = _read_regular_file(authority_path)
        authority = _read_strict_json(authority_path)
        if (
            _sha256(authority_payload)
            != bundle.get("authorized_execution_bindings_sha256")
            or authority_payload != canonical_authority_bytes(authority)
        ):
            raise ReleaseLockError("P06 V3 execution authority file differs")
    except (OSError, ValueError) as error:
        raise ReleaseLockError("P06 V3 execution authority is invalid") from error
    if (
        authority.get("configuration_id") != bundle.get("configuration_id")
        or authority.get("candidate_vector_sha256") != candidate_hash
        or authority.get("shared_bank_configuration_sha256") != bank_hash
        or authority.get("input_bundle_sha256") != bundle.get("input_bundle_sha256")
        or authority.get("corpus_lock_bundle_sha256")
        != bundle.get("corpus_lock_bundle_sha256")
    ):
        raise ReleaseLockError("P06 V3 execution authority identity differs")
    release_files = authority.get("release_files")
    if not isinstance(release_files, list):
        raise ReleaseLockError("P06 V3 execution authority release files are absent")
    authority_files = {
        str(row.get("id")): row for row in release_files if isinstance(row, dict)
    }
    runtime_binding = authority_files.get("candidate_runtime_manifest_v2")
    if not isinstance(runtime_binding, dict):
        raise ReleaseLockError("P06 V3 candidate runtime manifest authority is absent")
    runtime = _validated_json_artifact(
        release_root=release_root,
        binding=runtime_binding,
        schema_path=CANDIDATE_RUNTIME_MANIFEST_V2_SCHEMA,
        label="candidate runtime manifest V2",
    )
    _require_manifest_hash(
        runtime,
        field="manifest_sha256",
        label="candidate runtime manifest V2",
    )
    runtime_routes = runtime.get("routes")
    runtime_bindings = runtime.get("hash_bindings")
    if (
        runtime.get("configuration_id") != bundle.get("configuration_id")
        or runtime.get("compiler_input")
        != {
            "path": "locked-compiler-input-v2.json",
            "sha256": artifacts["locked_compiler_input_v2"]["sha256"],
            "size_bytes": artifacts["locked_compiler_input_v2"]["size_bytes"],
        }
        or runtime_bindings != compiler_bindings
        or not isinstance(runtime_routes, list)
        or len(runtime_routes) != 2
    ):
        raise ReleaseLockError("P06 V3 runtime/compiler identity differs")
    for runtime_row, validated_row in zip(runtime_routes, validated_routes):
        validated = validated_row["validated"]
        identifier = str(validated_row["identifier"])
        if (
            not isinstance(runtime_row, dict)
            or runtime_row.get("whole_file_sha256")
            != artifacts[identifier]["sha256"]
            or runtime_row.get("whole_file_size_bytes")
            != artifacts[identifier]["size_bytes"]
            or runtime_row.get("payload_sha256") != validated.payload_sha256
        ):
            raise ReleaseLockError(f"P06 V3 runtime LUT binding differs: {identifier}")
    swift_cli = runtime.get("swift_cli")
    if (
        not isinstance(swift_cli, dict)
        or swift_cli.get("executable_sha256")
        != authority_files.get("production_swift_executable", {}).get("sha256")
        or swift_cli.get("source_manifest_sha256")
        != authority_files.get("production_swift_source_manifest", {}).get("sha256")
    ):
        raise ReleaseLockError("P06 V3 runtime native identity differs")
    if support_evidence_roots is not None:
        if set(support_evidence_roots) != P06_SUPPORT_EVIDENCE_ROOT_IDS:
            raise ReleaseLockError(
                "P06 V3 full semantic replay support roots are not exact"
            )
        support_rows = authority.get("support_evidence_trees")
        calibration_rows = [
            row
            for row in support_rows
            if isinstance(row, dict)
            and row.get("id") == "complete_calibration_run_tree"
            and row.get("root_id") == CALIBRATION_RUN_SUPPORT_ROOT_ID
        ] if isinstance(support_rows, list) else []
        if len(calibration_rows) != 1:
            raise ReleaseLockError(
                "P06 V3 calibration-run semantic authority is absent"
            )
        calibration_root = _path_under_root(
            support_evidence_roots[CALIBRATION_RUN_SUPPORT_ROOT_ID],
            str(calibration_rows[0].get("path")),
        )
        try:
            from validation.calibration_v2.calibration_persistence_v2 import (
                FileBindingV2,
            )
            from validation.calibration_v2.calibration_selection_persistence_v2 import (
                CalibrationSelectionPersistenceAdapterV2,
            )

            semantic = CalibrationSelectionPersistenceAdapterV2(
                calibration_root
            ).reopen_calibration_selection(
                FileBindingV2(
                    path=str(artifacts["calibration_selection"]["path"]),
                    sha256=str(artifacts["calibration_selection"]["sha256"]),
                    size_bytes=int(
                        artifacts["calibration_selection"]["size_bytes"]
                    ),
                )
            )
        except (KeyError, OSError, TypeError, ValueError) as error:
            raise ReleaseLockError(
                "P06 V3 authoritative calibration selection replay failed"
            ) from error
        if semantic.document != selection:
            raise ReleaseLockError(
                "P06 V3 authoritative calibration selection bytes differ"
            )
    return authority


def _validate_p06_release_cross_bindings(
    *,
    release_root: Path,
    bundle: Mapping[str, object],
    artifacts: Mapping[str, Mapping[str, object]],
) -> None:
    """Cross-validate selection, evaluation, locks, compiler, and LUT identities."""

    selection = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["calibration_selection"],
        schema_path=CALIBRATION_SELECTION_SCHEMA,
        label="calibration selection",
    )
    ledger = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["calibration_run_ledger"],
        schema_path=CALIBRATION_RUN_LEDGER_SCHEMA,
        label="calibration run ledger",
    )
    evaluation = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["selected_evaluation"],
        schema_path=CANDIDATE_EVALUATION_SCHEMA,
        label="selected evaluation",
    )
    live = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["live_holdout_preopen_verification"],
        schema_path=LIVE_HOLDOUT_PREOPEN_VERIFICATION_SCHEMA,
        label="live holdout preopen verification",
    )
    mapping = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_mapping"],
        schema_path=VIDEO_MAPPING_SCHEMA,
        label="locked mapping",
    )
    operator_bank = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_operator_bank"],
        schema_path=OPERATOR_BANK_SCHEMA,
        label="locked operator bank",
    )
    quality_policy = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_quality_policy"],
        schema_path=LOCKED_QUALITY_POLICY_SCHEMA,
        label="locked quality policy",
    )
    metric_policy = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["locked_metric_policy"],
        schema_path=LOCKED_METRIC_POLICY_SCHEMA,
        label="locked metric policy",
    )
    route_selection = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["route_analysis_grid_selection"],
        schema_path=ROUTE_SELECTION_SCHEMA,
        label="route analysis-grid selection",
    )
    configuration_lock = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["configuration_lock"],
        schema_path=CONFIGURATION_LOCK_SCHEMA,
        label="configuration lock",
    )
    evidence_closure = _validated_json_artifact(
        release_root=release_root,
        binding=artifacts["evidence_closure"],
        schema_path=P06_EVIDENCE_CLOSURE_SCHEMA,
        label="P06 evidence closure",
    )
    dispatch = _read_strict_json(
        _path_under_root(
            release_root,
            str(artifacts["dispatch_measurement"]["path"]),
        )
    )
    validate_dispatch_measurement_document(dispatch)
    _require_manifest_hash(selection, field="manifest_sha256", label="selection")
    _require_manifest_hash(ledger, field="manifest_sha256", label="run ledger")
    _require_manifest_hash(
        quality_policy,
        field="manifest_sha256",
        label="locked quality policy",
    )
    _require_manifest_hash(
        metric_policy,
        field="policy_sha256",
        label="locked metric policy",
    )
    _require_manifest_hash(
        route_selection,
        field="manifest_sha256",
        label="route analysis-grid selection",
    )
    _require_manifest_hash(
        evidence_closure,
        field="manifest_sha256",
        label="P06 evidence closure",
    )

    selected_hash = str(artifacts["selected_evaluation"]["sha256"])
    selection_hash = str(artifacts["calibration_selection"]["sha256"])
    selected_path = PurePosixPath(
        str(artifacts["selected_evaluation"]["path"])
    )
    if (
        selected_path.stem != selected_hash
        or selection.get("selected_evaluation_sha256") != selected_hash
        or selection.get("selected_vector_sha256")
        != evaluation.get("candidate_vector_sha256")
        or selection.get("selected_controls")
        != evaluation.get("comparison_identities")
    ):
        raise ReleaseLockError("selected evaluation identity differs")
    candidate_rows = ledger.get("candidate_evaluations")
    if not isinstance(candidate_rows, list) or not any(
        isinstance(row, dict)
        and row.get("split") == "validation"
        and row.get("candidate_vector_sha256")
        == selection.get("selected_vector_sha256")
        and row.get("path") == artifacts["selected_evaluation"]["path"]
        and row.get("sha256") == selected_hash
        and row.get("size_bytes")
        == artifacts["selected_evaluation"]["size_bytes"]
        for row in candidate_rows
    ):
        raise ReleaseLockError("run ledger does not bind the selected evaluation")
    if (
        bundle.get("input_bundle_sha256")
        != selection.get("input_bundle_sha256")
        or bundle.get("input_bundle_sha256")
        != ledger.get("input_bundle_sha256")
        or bundle.get("corpus_lock_bundle_sha256")
        != selection.get("corpus_lock_bundle_sha256")
        or selection.get("run_id") != ledger.get("run_id")
        or selection.get("live_holdout_preopen_verification") != live
        or ledger.get("live_holdout_preopen_verification") != live
    ):
        raise ReleaseLockError("calibration run, input, corpus, or holdout binding differs")
    selected_control_rows = selection.get("selected_control_selection_artifacts")
    embedded_controls = evaluation.get("control_selection_artifacts")
    if (
        not isinstance(selected_control_rows, list)
        or len(selected_control_rows) != 3
        or not isinstance(embedded_controls, dict)
    ):
        raise ReleaseLockError("selected control artifact closure is absent")
    for row in selected_control_rows:
        if not isinstance(row, dict):
            raise ReleaseLockError("selected control artifact binding is invalid")
        control = str(row.get("control"))
        embedded = embedded_controls.get(control)
        if not isinstance(embedded, dict):
            raise ReleaseLockError(f"selected control is not embedded: {control}")
        path = str(row.get("path"))
        actual = _binding(_path_under_root(release_root, path), path)
        control_document = _read_strict_json(_path_under_root(release_root, path))
        if (
            row != {"control": control, **actual}
            or embedded.get("sha256") != row.get("sha256")
            or embedded.get("document") != control_document
        ):
            raise ReleaseLockError(f"selected control artifact changed: {control}")

    dispatch_wrapper = evaluation.get("dispatch_measurement")
    if (
        not isinstance(dispatch_wrapper, dict)
        or dispatch_wrapper.get("measurement_records") != [dispatch]
        or dispatch_wrapper.get("measurement_artifact_sha256_values")
        != [artifacts["dispatch_measurement"]["sha256"]]
        or not isinstance(dispatch_wrapper.get("measurement_evidence_bindings"), list)
        or len(dispatch_wrapper["measurement_evidence_bindings"]) != 1
        or dispatch_wrapper["measurement_evidence_bindings"][0].get("sha256")
        != artifacts["dispatch_measurement"]["sha256"]
        or dispatch_wrapper["measurement_evidence_bindings"][0].get("size_bytes")
        != artifacts["dispatch_measurement"]["size_bytes"]
    ):
        raise ReleaseLockError("selected dispatch measurement binding differs")
    selection_budget = selection.get("dispatch_budget")
    if not isinstance(selection_budget, dict) or any(
        selection_budget.get(field) != dispatch_wrapper.get(field)
        for field in (
            "measurement_method",
            "shared_bank_configuration_sha256",
            "full_ash_configuration_sha256",
            "measured_validation_p95_percent",
            "measurement_run_ids",
            "measurement_artifact_sha256_values",
        )
    ):
        raise ReleaseLockError("selection dispatch budget differs from its evidence")
    metric_dispatch = metric_policy.get("dispatch_measurement_evidence")
    if metric_dispatch != {
        "path": "dispatch-measurement.json",
        "sha256": artifacts["dispatch_measurement"]["sha256"],
        "size_bytes": artifacts["dispatch_measurement"]["size_bytes"],
        "measurement_domain": "native_cpu_reference_projection_not_metal",
        "production_metal_constraint_satisfied": False,
        "status": "pass",
    }:
        raise ReleaseLockError("locked metric policy dispatch binding differs")
    metric_budget = metric_policy.get("release_tolerances", {}).get(
        "dispatch_overhead_budget"
    )
    if not isinstance(metric_budget, dict) or any(
        metric_budget.get(field) != selection_budget.get(field)
        for field in (
            "measured_validation_p95_percent",
            "uncertainty_margin_percentage_points",
            "derived_budget_percent",
            "measurement_run_ids",
            "measurement_artifact_sha256_values",
            "derivation_formula",
            "locked_before_g08",
            "post_g08_adjustment_allowed",
        )
    ):
        raise ReleaseLockError("locked metric dispatch budget differs from selection")

    compiler_path = _path_under_root(
        release_root,
        str(artifacts["locked_compiler_input"]["path"]),
    )
    compiler = load_locked_compiler_input(compiler_path)
    compiler_document = _read_strict_json(compiler_path)
    compiler_bindings = compiler_document.get("hash_bindings")
    if not isinstance(compiler_bindings, dict):
        raise ReleaseLockError("compiler hash bindings are absent")
    configuration_id = bundle.get("configuration_id")
    vector_hash = selection.get("selected_vector_sha256")
    bank_hash = selection.get("selected_controls", {}).get(
        "shared_bank_configuration_sha256"
    )
    expected_selection_binding = {
        "calibration_selection_sha256": selection_hash,
        "selected_evaluation_sha256": selected_hash,
    }
    if any(
        value != configuration_id
        for value in (
            mapping.get("configuration_id"),
            operator_bank.get("configuration_id"),
            compiler.configuration_id,
            route_selection.get("configuration_id"),
        )
    ) or any(
        value != vector_hash
        for value in (
            mapping.get("candidate_vector_sha256"),
            operator_bank.get("candidate_vector_sha256"),
            route_selection.get("candidate_vector_sha256"),
        )
    ):
        raise ReleaseLockError("release configuration or candidate identity differs")
    if (
        mapping.get("status") != "locked_before_p07"
        or operator_bank.get("status") != "locked_before_p07"
        or mapping.get("selection_binding") != expected_selection_binding
        or operator_bank.get("selection_binding") != expected_selection_binding
        or any(
            value != bank_hash
            for value in (
                mapping.get("shared_bank_configuration_sha256"),
                operator_bank.get("shared_bank_configuration_sha256"),
                quality_policy.get("shared_bank_configuration_sha256"),
                dispatch.get("input_bindings", {}).get(
                    "shared_bank_configuration_sha256"
                ),
            )
        )
    ):
        raise ReleaseLockError("release shared-bank or selection binding differs")
    if (
        quality_policy.get("input_bundle_sha256")
        != bundle.get("input_bundle_sha256")
        or quality_policy.get("quality_policy_seed_sha256")
        != selection.get("quality_policy_seed_sha256")
        or quality_policy.get("baseline_ablation_contract_sha256")
        != selection.get("baseline_ablation_contract_sha256")
        or quality_policy.get("selected_controls")
        != {
            name: selection["selected_controls"][name]
            for name in _SELECTED_CONTROL_NAMES
        }
    ):
        raise ReleaseLockError("locked quality-policy selection differs")

    expected_release_hashes = {
        "mapping_sha256": artifacts["locked_mapping"]["sha256"],
        "operator_bank_sha256": artifacts["locked_operator_bank"]["sha256"],
        "metric_policy_sha256": artifacts["locked_metric_policy"]["sha256"],
    }
    if any(
        compiler_bindings.get(field) != value
        for field, value in expected_release_hashes.items()
    ) or any(
        route_selection.get(field) != value
        for field, value in {
            **expected_release_hashes,
            "compiler_inputs_sha256": compiler_bindings.get(
                "compiler_inputs_sha256"
            ),
        }.items()
        if field != "metric_policy_sha256"
    ):
        raise ReleaseLockError("compiler, mapping, operator, or route hash differs")
    if (
        route_selection.get("calibration_selection_sha256") != selection_hash
        or route_selection.get("selected_evaluation_sha256") != selected_hash
    ):
        raise ReleaseLockError("route selection does not bind calibration selection")

    lut_manifest = validate_lut_manifest(
        repository_root=CALIBRATION_ROOT.parents[1],
        release_root=release_root,
        manifest_path=_path_under_root(
            release_root,
            str(artifacts["lut_manifest"]["path"]),
        ),
    )
    if (
        lut_manifest.get("configuration_id") != configuration_id
        or lut_manifest.get("hash_bindings") != compiler_bindings
        or configuration_lock.get("locked_utc") != bundle.get("locked_utc")
        or configuration_lock.get("mapping_sha256")
        != artifacts["locked_mapping"]["sha256"]
        or configuration_lock.get("operator_bank_sha256")
        != artifacts["locked_operator_bank"]["sha256"]
        or configuration_lock.get("quality_policy_sha256")
        != artifacts["locked_quality_policy"]["sha256"]
        or configuration_lock.get("metric_policy_sha256")
        != artifacts["locked_metric_policy"]["sha256"]
        or configuration_lock.get("compiler_inputs_sha256")
        != artifacts["locked_compiler_input"]["sha256"]
        or configuration_lock.get("route_luts_sha256")
        != lut_manifest.get("manifest_sha256")
        or configuration_lock.get("corpus_manifest_sha256")
        != live.get("corpus_binding_sha256")
    ):
        raise ReleaseLockError("configuration lock transitive binding differs")

    closure_configuration = evidence_closure.get("configuration_bindings")
    if (
        evidence_closure.get("configuration_id") != configuration_id
        or evidence_closure.get("input_bundle_sha256")
        != bundle.get("input_bundle_sha256")
        or evidence_closure.get("corpus_lock_bundle_sha256")
        != bundle.get("corpus_lock_bundle_sha256")
        or not isinstance(closure_configuration, list)
        or [row.get("id") for row in closure_configuration]
        != list(_CONFIGURATION_LOCK_HASH_FIELDS)
        or any(
            configuration_lock.get(row["id"]) != row.get("digest_sha256")
            for row in closure_configuration
        )
    ):
        raise ReleaseLockError("evidence closure configuration binding differs")
    if (
        tuple(
            row.get("id")
            for row in evidence_closure.get("implementation_artifacts", [])
        )
        != IMPLEMENTATION_IDS
        or tuple(
            row.get("id")
            for row in evidence_closure.get("selected_control_artifacts", [])
        )
        != SELECTED_CONTROL_IDS
        or tuple(
            row.get("id")
            for row in evidence_closure.get("support_evidence_trees", [])
        )
        != SUPPORT_TREE_IDS
        or any(
            row.get("kind") != "directory_tree"
            for row in evidence_closure.get("support_evidence_trees", [])
        )
        or tuple(
            row.get("id")
            for row in evidence_closure.get("test_evidence", [])
        )
        != TEST_EVIDENCE_IDS
        or any(
            row.get("kind") != "directory_tree"
            for row in evidence_closure.get("test_evidence", [])
        )
        or P00_FAILURE_ID
        not in {
            row.get("id")
            for row in evidence_closure.get("preserved_failures", [])
        }
    ):
        raise ReleaseLockError("evidence closure mandatory evidence set differs")
    closure_rows = [
        *evidence_closure.get("implementation_artifacts", []),
        *evidence_closure.get("selected_control_artifacts", []),
        *evidence_closure.get("test_evidence", []),
        *evidence_closure.get("preserved_failures", []),
    ]
    for row in closure_rows:
        if not isinstance(row, dict) or row.get("root_id") != "release":
            continue
        expected = evidence_binding(
            identifier=str(row["id"]),
            root_id="release",
            path=_path_under_root(release_root, str(row["path"])),
            root=release_root,
        )
        if row != expected:
            raise ReleaseLockError(
                f"release-local evidence closure artifact changed: {row['id']}"
            )


def _relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ReleaseLockError(f"unsafe relative path: {value!r}")
    return path


def _path_under_root(root: Path, relative_path: str) -> Path:
    relative = _relative_path(relative_path)
    candidate = root.joinpath(*relative.parts)
    try:
        resolved_parent = candidate.parent.resolve(strict=True)
        resolved_parent.relative_to(root)
    except (OSError, ValueError) as error:
        raise ReleaseLockError(
            f"relative path escapes its locked root: {relative_path!r}"
        ) from error
    return resolved_parent / candidate.name


def _binding(path: Path, relative_path: str) -> Mapping[str, object]:
    payload = _read_regular_file(path)
    return {
        "path": relative_path,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _authenticated_p06_transaction_token_exclusions(
    release_root: Path,
    *,
    transaction_id: str | None,
) -> frozenset[str]:
    if transaction_id is not None and (
        len(transaction_id) != 32
        or any(character not in "0123456789abcdef" for character in transaction_id)
    ):
        raise ReleaseLockError("P06 transaction ID is invalid")
    token_path = release_root / P06_TRANSACTION_TOKEN_NAME
    try:
        metadata = os.stat(token_path, follow_symlinks=False)
    except FileNotFoundError:
        if transaction_id is not None:
            raise ReleaseLockError("authenticated P06 transaction token is absent")
        return frozenset()
    except OSError as error:
        raise ReleaseLockError(
            "P06 transaction token cannot be inspected"
        ) from error
    if transaction_id is None:
        raise ReleaseLockError(
            "P06 transaction token is present outside authenticated validation"
        )
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ReleaseLockError(
            "authenticated P06 transaction token is not a single-link file"
        )
    expected = f"{transaction_id}\n".encode("ascii")
    if _read_regular_file(token_path) != expected:
        raise ReleaseLockError("authenticated P06 transaction token differs")
    return frozenset({P06_TRANSACTION_TOKEN_NAME})


def _raise_release_filesystem_walk_error(error: OSError) -> None:
    raise ReleaseLockError(
        f"P06 release filesystem closure traversal failed: {error}"
    ) from error


def _release_filesystem_closure(
    release_root: Path,
    *,
    excluded_paths: frozenset[str],
) -> list[Mapping[str, object]]:
    root = release_root.resolve(strict=True)
    if release_root.is_symlink() or not root.is_dir():
        raise ReleaseLockError("P06 release filesystem root is symbolic or absent")
    rows: list[Mapping[str, object]] = []
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        onerror=_raise_release_filesystem_walk_error,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            child = current / name
            metadata = os.stat(child, follow_symlinks=False)
            if not stat.S_ISDIR(metadata.st_mode):
                raise ReleaseLockError(
                    "P06 release filesystem closure contains a symbolic directory"
                )
            rows.append(
                {
                    "path": child.relative_to(root).as_posix(),
                    "entry_kind": "directory",
                }
            )
        for name in file_names:
            child = current / name
            relative = child.relative_to(root).as_posix()
            if relative in excluded_paths:
                continue
            before = os.stat(child, follow_symlinks=False)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ReleaseLockError(
                    "P06 release filesystem closure contains a non-regular file"
                )
            payload = _read_regular_file(child)
            current_metadata = os.stat(child, follow_symlinks=False)
            if (
                (current_metadata.st_dev, current_metadata.st_ino)
                != (before.st_dev, before.st_ino)
                or current_metadata.st_nlink != 1
                or current_metadata.st_mode & 0o777 != before.st_mode & 0o777
            ):
                raise ReleaseLockError(
                    "P06 release filesystem closure file changed while binding"
                )
            rows.append(
                {
                    "path": relative,
                    "entry_kind": "regular_file",
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                    "executable_mode_bits": before.st_mode
                    & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH),
                }
            )
    rows.sort(key=lambda row: (str(row["path"]), str(row["entry_kind"])))
    return rows


def _crc32_hex(value: int) -> str:
    if not 0 <= value <= 0xFFFF_FFFF:
        raise ReleaseLockError("CRC-32 is outside UInt32")
    return f"0x{value:08X}"


def _validated_output_record(
    *,
    release_root: Path,
    relative_path: str,
    configuration: LockedCompilerInput,
    route_name: str,
) -> tuple[Mapping[str, object], bytes]:
    path = _path_under_root(release_root, relative_path)
    payload = _read_regular_file(path)
    validated = validate_lut(
        payload,
        expected_configuration=configuration,
        expected_route=ROUTES[route_name],
    )
    return (
        {
            "path": relative_path,
            "whole_file_size_bytes": len(payload),
            "whole_file_sha256": validated.whole_file_sha256,
            "payload_sha256": validated.payload_sha256,
            "header_crc32": _crc32_hex(validated.header_crc32),
            "payload_crc32": _crc32_hex(validated.payload_crc32),
            "entry_count": validated.entry_count,
            "parameter_count": validated.parameter_count,
        },
        payload,
    )


def _source_implementation(
    *,
    release_root: Path,
    relative_path: str,
    implementation_id: str,
    implementation_version: str,
) -> tuple[Mapping[str, object], bytes]:
    payload = _read_regular_file(_path_under_root(release_root, relative_path))
    return (
        {
            "implementation_id": implementation_id,
            "implementation_version": implementation_version,
            "source_manifest_path": relative_path,
            "source_manifest_sha256": _sha256(payload),
            "source_manifest_size_bytes": len(payload),
            "independence_attested": True,
        },
        payload,
    )


def _first_differing_byte(lhs: bytes, rhs: bytes) -> int | None:
    for index, (left, right) in enumerate(zip(lhs, rhs)):
        if left != right:
            return index
    if len(lhs) != len(rhs):
        return min(len(lhs), len(rhs))
    return None


def build_native_parity_manifest(
    *,
    release_root: Path,
    compiler_input_path: Path,
    production_source_manifest_path: str,
    independent_source_manifest_path: str,
    output_path: Path,
    failure_output_path: Path,
    conflict_record: str,
    production_paths: Mapping[str, str] | None = None,
    independent_paths: Mapping[str, str] | None = None,
) -> Mapping[str, object]:
    """Reopen independent outputs and publish pass or preserved failure evidence."""

    release = release_root.resolve(strict=True)
    configuration = load_locked_compiler_input(compiler_input_path)
    production_paths = production_paths or {
        name: f"swift/{route.filename}" for name, route in ROUTES.items()
    }
    independent_paths = independent_paths or {
        name: f"python/{route.filename}" for name, route in ROUTES.items()
    }
    if set(production_paths) != set(ROUTES) or set(independent_paths) != set(ROUTES):
        raise ReleaseLockError("native parity paths do not exactly cover both routes")
    production_source, production_source_bytes = _source_implementation(
        release_root=release,
        relative_path=production_source_manifest_path,
        implementation_id="mirmir-swift-lut-compiler-v2",
        implementation_version="1.0.0",
    )
    independent_source, independent_source_bytes = _source_implementation(
        release_root=release,
        relative_path=independent_source_manifest_path,
        implementation_id="mirmir-python-lut-oracle-v2",
        implementation_version="1.0.0",
    )
    if (
        production_source_manifest_path == independent_source_manifest_path
        or production_source_bytes == independent_source_bytes
    ):
        raise ReleaseLockError("native parity source manifests are not independent")

    route_comparisons = []
    for route_name, route in ROUTES.items():
        production, production_bytes = _validated_output_record(
            release_root=release,
            relative_path=production_paths[route_name],
            configuration=configuration,
            route_name=route_name,
        )
        independent, independent_bytes = _validated_output_record(
            release_root=release,
            relative_path=independent_paths[route_name],
            configuration=configuration,
            route_name=route_name,
        )
        if production["path"] == independent["path"]:
            raise ReleaseLockError("native parity outputs share a path")
        first_difference = _first_differing_byte(
            production_bytes,
            independent_bytes,
        )
        if first_difference is not None:
            failure: dict[str, object] = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_native_lut_parity_failure",
                "status": "failed_preserved",
                "configuration_id": configuration.configuration_id,
                "input_hashes": dict(configuration.hash_bindings),
                "route": route.name,
                "production_swift": {
                    "path": production["path"],
                    "sha256": production["whole_file_sha256"],
                    "size_bytes": production["whole_file_size_bytes"],
                },
                "independent_test_python": {
                    "path": independent["path"],
                    "sha256": independent["whole_file_sha256"],
                    "size_bytes": independent["whole_file_size_bytes"],
                },
                "first_differing_byte_offset": first_difference,
                "holdout_accessed": False,
            }
            failure["manifest_sha256"] = _manifest_sha256(failure)
            validate_schema(failure, NATIVE_PARITY_FAILURE_SCHEMA)
            _publish_new_file(
                failure_output_path,
                _canonical_bytes(failure) + b"\n",
            )
            raise NativeParityMismatch(
                route=route.name,
                first_differing_byte_offset=first_difference,
                failure_path=failure_output_path,
            )
        route_comparisons.append(
            {
                "route": route.name,
                "route_id": route.route_id,
                "expected_entry_count": route.entry_count,
                "production_swift": production,
                "independent_test_python": independent,
                "byte_identical": True,
                "payload_hash_identical": True,
                "first_differing_byte_offset": None,
            }
        )

    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "manifest_id": "mirmir-native-lut-parity-v1",
        "status": "pass",
        "conflict_record": conflict_record,
        "input_hashes": dict(configuration.hash_bindings),
        "implementations": {
            "production_swift": production_source,
            "independent_test_python": independent_source,
        },
        "routes": route_comparisons,
        "all_routes_byte_identical": True,
        "canonicalization": "sorted-key compact UTF-8 JSON with a trailing newline",
    }
    validate_schema(document, NATIVE_PARITY_SCHEMA)
    _publish_new_file(output_path, _canonical_bytes(document) + b"\n")
    return document


def _route_record(
    *,
    route_name: str,
    path: Path,
    validated: ValidatedLUT,
    configuration: LockedCompilerInput,
) -> Mapping[str, object]:
    route = ROUTES[route_name]
    payload = _read_regular_file(path)
    if validated.route != route or validated.whole_file_sha256 != _sha256(payload):
        raise ReleaseLockError(f"validated route identity changed: {route_name}")
    return {
        "route": route.name,
        "route_id": route.route_id,
        "scale_numerator": route.scale_numerator,
        "scale_denominator": route.scale_denominator,
        "phase_count": route.phase_count,
        "context_count": 4,
        "valid_state_count": 256,
        "luma_coordinate_policy": configuration.routes[
            route_name
        ].luma_coordinate_policy,
        "chroma_coordinate_policy": configuration.routes[
            route_name
        ].chroma_coordinate_policy,
        "analysis_grid_source_step": configuration.routes[
            route_name
        ].analysis_grid_source_step,
        "entry_count": validated.entry_count,
        "parameter_count": validated.parameter_count,
        "path": route.filename,
        "whole_file_size_bytes": len(payload),
        "whole_file_sha256": validated.whole_file_sha256,
        "payload_sha256": validated.payload_sha256,
        "header_crc32": _crc32_hex(validated.header_crc32),
        "payload_crc32": _crc32_hex(validated.payload_crc32),
    }


def _validate_parity_cross_bindings(
    parity: Mapping[str, object],
    configuration: LockedCompilerInput,
    route_records: Mapping[str, Mapping[str, object]],
    release_root: Path,
) -> None:
    validate_schema(parity, NATIVE_PARITY_SCHEMA)
    if parity.get("input_hashes") != dict(configuration.hash_bindings):
        raise ReleaseLockError("native parity input hashes differ from compiler input")
    implementations = parity.get("implementations")
    if not isinstance(implementations, dict):
        raise ReleaseLockError("native parity implementation identities are absent")
    source_bindings = []
    for role in ("production_swift", "independent_test_python"):
        implementation = implementations.get(role)
        if not isinstance(implementation, dict):
            raise ReleaseLockError(f"native parity implementation is absent: {role}")
        source_path = str(implementation.get("source_manifest_path"))
        source_payload = _read_regular_file(
            _path_under_root(release_root, source_path)
        )
        source_binding = (
            source_path,
            _sha256(source_payload),
            len(source_payload),
        )
        if source_binding != (
            implementation.get("source_manifest_path"),
            implementation.get("source_manifest_sha256"),
            implementation.get("source_manifest_size_bytes"),
        ):
            raise ReleaseLockError(f"native parity source manifest changed: {role}")
        source_bindings.append(source_binding)
    if (
        source_bindings[0][0] == source_bindings[1][0]
        or source_bindings[0][1] == source_bindings[1][1]
    ):
        raise ReleaseLockError("native parity implementations share one source manifest")

    parity_routes = parity.get("routes")
    if not isinstance(parity_routes, list) or len(parity_routes) != 2:
        raise ReleaseLockError("native parity route count differs")
    for parity_route, route_name in zip(parity_routes, ROUTES):
        if not isinstance(parity_route, dict):
            raise ReleaseLockError("native parity route is not an object")
        production = parity_route.get("production_swift")
        independent = parity_route.get("independent_test_python")
        expected = route_records[route_name]
        if not isinstance(production, dict) or not isinstance(independent, dict):
            raise ReleaseLockError("native parity implementation output is absent")
        output_payloads = []
        for output in (production, independent):
            output_path = str(output.get("path"))
            output_payload = _read_regular_file(
                _path_under_root(release_root, output_path)
            )
            output_validated = validate_lut(
                output_payload,
                expected_configuration=configuration,
                expected_route=ROUTES[route_name],
            )
            comparisons = {
                "whole_file_size_bytes": len(output_payload),
                "whole_file_sha256": output_validated.whole_file_sha256,
                "payload_sha256": output_validated.payload_sha256,
                "header_crc32": _crc32_hex(output_validated.header_crc32),
                "payload_crc32": _crc32_hex(output_validated.payload_crc32),
                "entry_count": output_validated.entry_count,
                "parameter_count": output_validated.parameter_count,
            }
            if any(output.get(key) != value for key, value in comparisons.items()):
                raise ReleaseLockError(
                    f"native parity output metadata changed: {route_name}"
                )
            if any(expected.get(key) != value for key, value in comparisons.items()):
                raise ReleaseLockError(
                    f"native parity output differs from locked LUT: {route_name}"
                )
            output_payloads.append(output_payload)
        if production.get("path") == independent.get("path"):
            raise ReleaseLockError(
                f"native parity implementations share one output path: {route_name}"
            )
        if output_payloads[0] != output_payloads[1]:
            raise ReleaseLockError(
                f"native parity outputs are not byte-identical: {route_name}"
            )


def build_lut_manifest(
    *,
    repository_root: Path,
    release_root: Path,
    output_path: Path,
) -> Mapping[str, object]:
    """Build and atomically publish a locked two-route LUT manifest.

    ``release_root`` must already contain ``locked-compiler-input.json``, both
    final route LUTs, and the passing native parity manifest.  Existing output
    is never overwritten.
    """

    repository = repository_root.resolve(strict=True)
    release = release_root.resolve(strict=True)
    compiler_path = release / "locked-compiler-input.json"
    parity_path = release / "native-lut-parity-manifest.json"
    contract_path = repository.joinpath(*LUT_CONTRACT_PATH.parts)
    configuration = load_locked_compiler_input(compiler_path)
    parity = _read_strict_json(parity_path)

    route_records: MutableMapping[str, Mapping[str, object]] = {}
    for route_name, route in ROUTES.items():
        lut_path = release / route.filename
        payload = _read_regular_file(lut_path)
        validated = validate_lut(
            payload,
            expected_configuration=configuration,
            expected_route=route,
        )
        route_records[route_name] = _route_record(
            route_name=route_name,
            path=lut_path,
            validated=validated,
            configuration=configuration,
        )
    _validate_parity_cross_bindings(
        parity,
        configuration,
        route_records,
        release,
    )

    document: dict[str, object] = {
        "schema_version": "2.0.0",
        "manifest_id": "mirmir-ash-route-luts-v2",
        "status": "locked_before_p07",
        "configuration_id": configuration.configuration_id,
        "compiler_input": _binding(
            compiler_path,
            "locked-compiler-input.json",
        ),
        "lut_binary_contract": _binding(
            contract_path,
            LUT_CONTRACT_PATH.as_posix(),
        ),
        "hash_bindings": dict(configuration.hash_bindings),
        "routes": [route_records[name] for name in ROUTES],
        "runtime_load_policy": {
            "immutability": "validate complete bytes before publication and retain immutable bytes",
            "load_frequency": "once_per_route_per_configuration",
            "per_frame_load_count": 0,
            "runtime_tree_generation_count": 0,
            "maximum_operator_evaluations_per_output_cell": 2,
        },
        "native_parity_manifest": _binding(
            parity_path,
            "native-lut-parity-manifest.json",
        ),
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = _manifest_sha256(document)
    validate_schema(document, LUT_MANIFEST_SCHEMA)
    encoded = _canonical_bytes(document) + b"\n"
    _publish_new_file(output_path, encoded)
    validate_lut_manifest(
        repository_root=repository,
        release_root=release,
        manifest_path=output_path,
    )
    return document


def _publish_new_file(path: Path, payload: bytes) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    if parent.is_symlink():
        raise ReleaseLockError("publication parent is symbolic")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("manifest publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_lut_manifest(
    *,
    repository_root: Path,
    release_root: Path,
    manifest_path: Path,
) -> Mapping[str, object]:
    """Reopen and cross-validate every byte referenced by a LUT manifest."""

    repository = repository_root.resolve(strict=True)
    release = release_root.resolve(strict=True)
    document = _read_strict_json(manifest_path)
    validate_schema(document, LUT_MANIFEST_SCHEMA)
    if document.get("manifest_sha256") != _manifest_sha256(document):
        raise ReleaseLockError("LUT manifest self-hash mismatch")

    compiler_binding = document["compiler_input"]
    parity_binding = document["native_parity_manifest"]
    contract_binding = document["lut_binary_contract"]
    assert isinstance(compiler_binding, dict)
    assert isinstance(parity_binding, dict)
    assert isinstance(contract_binding, dict)
    actual_bindings = (
        _binding(
            release.joinpath(*_relative_path(str(compiler_binding["path"])).parts),
            str(compiler_binding["path"]),
        ),
        _binding(
            release.joinpath(*_relative_path(str(parity_binding["path"])).parts),
            str(parity_binding["path"]),
        ),
        _binding(
            repository.joinpath(*_relative_path(str(contract_binding["path"])).parts),
            str(contract_binding["path"]),
        ),
    )
    if actual_bindings != (compiler_binding, parity_binding, contract_binding):
        raise ReleaseLockError("LUT manifest file binding changed")

    configuration = load_locked_compiler_input(
        release.joinpath(*_relative_path(str(compiler_binding["path"])).parts)
    )
    if (
        document.get("configuration_id") != configuration.configuration_id
        or document.get("hash_bindings") != dict(configuration.hash_bindings)
    ):
        raise ReleaseLockError("LUT manifest compiler identity mismatch")
    rows = document.get("routes")
    if not isinstance(rows, list) or len(rows) != 2:
        raise ReleaseLockError("LUT manifest route count mismatch")
    validated_rows: dict[str, Mapping[str, object]] = {}
    for row, (route_name, route) in zip(rows, ROUTES.items()):
        if not isinstance(row, dict):
            raise ReleaseLockError("LUT manifest route row is not an object")
        path = release.joinpath(*_relative_path(str(row["path"])).parts)
        payload = _read_regular_file(path)
        validated = validate_lut(
            payload,
            expected_configuration=configuration,
            expected_route=route,
        )
        expected = _route_record(
            route_name=route_name,
            path=path,
            validated=validated,
            configuration=configuration,
        )
        if row != expected:
            raise ReleaseLockError(f"LUT route row changed: {route_name}")
        validated_rows[route_name] = expected
    parity = _read_strict_json(
        release.joinpath(*_relative_path(str(parity_binding["path"])).parts)
    )
    _validate_parity_cross_bindings(
        parity,
        configuration,
        validated_rows,
        release,
    )
    return document


__all__ = [
    "CALIBRATION_RUN_SUPPORT_ROOT_ID",
    "CONFIGURATION_LOCK_V2_SCHEMA",
    "NativeParityMismatch",
    "P06_SUPPORT_EVIDENCE_ROOT_IDS",
    "ReleaseLockError",
    "build_configuration_lock_from_bindings",
    "build_locked_quality_policy",
    "build_native_parity_manifest",
    "build_lut_manifest",
    "build_p06_release_bundle_manifest",
    "build_p06_release_bundle_v3_manifest",
    "candidate_vector_sha256_for_plan",
    "configuration_lock_document_from_bindings",
    "locked_compiler_input_document",
    "locked_metric_policy_document",
    "locked_quality_policy_document",
    "operator_bank_document",
    "route_analysis_grid_selection_document",
    "shared_bank_configuration_sha256_for_plan",
    "validate_lut_manifest",
    "validate_p06_configuration_lock_v2",
    "validate_p06_release_bundle_manifest",
    "validate_dispatch_measurement_document",
    "video_mapping_document",
]
