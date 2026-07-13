"""Strict contracts for open-development P06 corrective diagnostics.

The contracts in this module describe evidence.  They do not execute native
diagnostics, select a winner, or authorize validation or holdout access.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
from typing import Mapping, Sequence

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"

ROUTES = ("direct_2x", "direct_3_over_2")
EVALUATOR_ROUTE_BY_CONTRACT_ROUTE = {
    "direct_2x": "direct-2x",
    "direct_3_over_2": "direct-3over2",
}
CONTRACT_ROUTE_BY_EVALUATOR_ROUTE = {
    value: key for key, value in EVALUATOR_ROUTE_BY_CONTRACT_ROUTE.items()
}
_FRAME_FIELDS = {
    "request_id",
    "route",
    "input_path",
    "input_sha256",
    "input_width",
    "input_height",
    "output_path",
    "output_width",
    "output_height",
    "pixel_format",
    "matrix",
    "range",
    "chroma_siting",
}
_DIAGNOSTIC_FIELDS = {
    "schema_version",
    "status",
    "split",
    "validation_accessed",
    "holdout_accessed",
    "selected_winner",
    "request_id",
    "target_route",
    "configuration_id",
    "compiler_inputs_sha256",
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
    "candidate_lut_runtime_manifest_sha256",
    "native_invocation_proof",
    "input_sha256",
    "coordinate_model_contract_file_sha256",
    "coordinate_oracle_matrix_sha256",
    "coordinate_experiment_dimensions_sha256",
    "analysis_grid_source_step",
    "analysis_cell_count",
    "output_plane_hash_contract",
    "normalized_plane_hash_contract",
    "analysis_grid_hash_contract",
    "analysis_grid_sha256",
    "generic_lut",
    "session_counters",
    "production_v2_reference",
    "cells",
    "risk_state",
}
_NATIVE_PROVENANCE_FIELDS = (
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
    "candidate_lut_runtime_manifest_sha256",
)
_CORRECTIVE_JOURNAL_GENESIS_SHA256 = hashlib.sha256(
    b"MIRMIR-P06-CORRECTIVE-DIAGNOSTIC-JOURNAL-V1\0"
).hexdigest()
COORDINATE_CELLS = (
    {
        "cell_id": "HH",
        "luma_coordinate_policy": "half_pixel_center",
        "chroma_coordinate_policy": "half_pixel_center",
    },
    {
        "cell_id": "HS",
        "luma_coordinate_policy": "half_pixel_center",
        "chroma_coordinate_policy": "source_aligned_rational",
    },
    {
        "cell_id": "SH",
        "luma_coordinate_policy": "source_aligned_rational",
        "chroma_coordinate_policy": "half_pixel_center",
    },
    {
        "cell_id": "SS",
        "luma_coordinate_policy": "source_aligned_rational",
        "chroma_coordinate_policy": "source_aligned_rational",
    },
)
ANISOTROPY_CELLS = (
    {
        "cell_id": "00",
        "luma_anisotropy_strength_q12": 0,
        "chroma_anisotropy_strength_q12": 0,
    },
    {
        "cell_id": "03",
        "luma_anisotropy_strength_q12": 0,
        "chroma_anisotropy_strength_q12": 3_072,
    },
    {
        "cell_id": "30",
        "luma_anisotropy_strength_q12": 3_072,
        "chroma_anisotropy_strength_q12": 0,
    },
    {
        "cell_id": "33",
        "luma_anisotropy_strength_q12": 3_072,
        "chroma_anisotropy_strength_q12": 3_072,
    },
)
RISK_WEIGHT_PAIRS = (
    {
        "laplacian_unorm15": 8_192,
        "alternating_difference_unorm15": 24_575,
    },
    {
        "laplacian_unorm15": 16_384,
        "alternating_difference_unorm15": 16_383,
    },
    {
        "laplacian_unorm15": 24_575,
        "alternating_difference_unorm15": 8_192,
    },
)
RISK_THRESHOLD_BANDS = (
    {"low_unorm15": 0, "high_unorm15": 256},
    {"low_unorm15": 0, "high_unorm15": 512},
    {"low_unorm15": 0, "high_unorm15": 1_024},
    {"low_unorm15": 0, "high_unorm15": 1_638},
    {"low_unorm15": 0, "high_unorm15": 3_277},
    {"low_unorm15": 819, "high_unorm15": 4_096},
    {"low_unorm15": 1_638, "high_unorm15": 4_915},
    {"low_unorm15": 2_458, "high_unorm15": 5_735},
    {"low_unorm15": 3_277, "high_unorm15": 6_554},
    {"low_unorm15": 4_915, "high_unorm15": 8_192},
)

_COORDINATE_SCHEMA = "coordinate-anisotropy-diagnostic-v1.schema.json"
_RISK_SCHEMA = "risk-state-diagnostic-v1.schema.json"
_ENVELOPE_SCHEMA = "corrective-diagnostic-envelope-v1.schema.json"
_SELF_HASH_FIELDS = {
    "plane_evidence_sha256",
    "metric_row_sha256",
    "observation_sha256",
    "block_sha256",
    "composition_sha256",
    "cell_sha256",
    "frame_route_record_sha256",
    "native_record_sha256",
    "receipt_sha256",
    "prepublication_closure_sha256",
    "artifact_sha256",
    "envelope_sha256",
}


class CorrectiveDiagnosticContractError(ValueError):
    """One corrective-diagnostic schema or semantic invariant failed."""


def _route_block_specs() -> tuple[tuple[str, str, str], ...]:
    return tuple(
        (route, coordinate["cell_id"], anisotropy["cell_id"])
        for route in ROUTES
        for coordinate in COORDINATE_CELLS
        for anisotropy in ANISOTROPY_CELLS
    )


ROUTE_BLOCK_SPECS = _route_block_specs()


def _block_id(route: str, coordinate: str, anisotropy: str) -> str:
    return f"{route}-{coordinate}-{anisotropy}"


def _composition_specs() -> tuple[tuple[str, str, str], ...]:
    direct2_baseline = _block_id("direct_2x", "SS", "33")
    direct3_baseline = _block_id("direct_3_over_2", "SS", "33")
    result = [("baseline", direct2_baseline, direct3_baseline)]
    for route, coordinate, anisotropy in ROUTE_BLOCK_SPECS:
        block = _block_id(route, coordinate, anisotropy)
        if block in {direct2_baseline, direct3_baseline}:
            continue
        if route == "direct_2x":
            result.append((f"direct_2x-substitute-{coordinate}-{anisotropy}", block, direct3_baseline))
    for route, coordinate, anisotropy in ROUTE_BLOCK_SPECS:
        block = _block_id(route, coordinate, anisotropy)
        if block in {direct2_baseline, direct3_baseline}:
            continue
        if route == "direct_3_over_2":
            result.append((f"direct_3_over_2-substitute-{coordinate}-{anisotropy}", direct2_baseline, block))
    return tuple(result)


COMPOSITION_SPECS = _composition_specs()


def coordinate_anisotropy_dimension_contract() -> Mapping[str, object]:
    """Return the immutable ordered 4x4-per-route diagnostic dimensions."""

    return {
        "routes": list(ROUTES),
        "coordinate_cells": [dict(value) for value in COORDINATE_CELLS],
        "anisotropy_cells": [dict(value) for value in ANISOTROPY_CELLS],
        "generic_baseline": {
            "direct_2x_block_id": _block_id("direct_2x", "SS", "33"),
            "direct_3_over_2_block_id": _block_id("direct_3_over_2", "SS", "33"),
        },
    }


def evaluator_route_for_contract_route(route: str) -> str:
    """Map one contract route to the existing evaluator transport spelling."""

    try:
        return EVALUATOR_ROUTE_BY_CONTRACT_ROUTE[route]
    except (KeyError, TypeError) as error:
        raise CorrectiveDiagnosticContractError("coordinate contract route is invalid") from error


def contract_route_for_evaluator_route(route: str) -> str:
    """Map one existing evaluator route to the coordinate-contract spelling."""

    try:
        return CONTRACT_ROUTE_BY_EVALUATOR_ROUTE[route]
    except (KeyError, TypeError) as error:
        raise CorrectiveDiagnosticContractError("evaluator route is invalid") from error


def risk_state_dimension_contract() -> Mapping[str, object]:
    """Return the immutable ordered 3x10 risk-state diagnostic dimensions."""

    return {
        "routes": list(ROUTES),
        "risk_weight_pairs": [dict(value) for value in RISK_WEIGHT_PAIRS],
        "risk_threshold_bands": [dict(value) for value in RISK_THRESHOLD_BANDS],
    }


def canonical_artifact_file_bytes(document: Mapping[str, object]) -> bytes:
    """Encode one evidence file as compact sorted canonical JSON plus LF."""

    return canonical_json_bytes(document) + b"\n"


def artifact_file_binding(document: Mapping[str, object]) -> Mapping[str, object]:
    """Return the byte-level binding used by the sibling envelope."""

    payload = canonical_artifact_file_bytes(document)
    artifact_sha256 = document.get("artifact_sha256")
    if not _is_sha256(artifact_sha256):
        raise CorrectiveDiagnosticContractError("artifact self-hash is absent")
    return {
        "artifact_sha256": artifact_sha256,
        "file_sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _is_configuration_id(value: object) -> bool:
    if not isinstance(value, str) or not 3 <= len(value) <= 128:
        return False
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789._-"
    return value[0] in allowed[:36] and all(
        character in allowed for character in value
    )


def _semantic(condition: bool, message: str) -> None:
    if not condition:
        raise CorrectiveDiagnosticContractError(message)


def _schema(document: Mapping[str, object], filename: str) -> None:
    try:
        validate_schema(document, SCHEMAS_ROOT / filename)
    except (TypeError, ValueError) as error:
        raise CorrectiveDiagnosticContractError(str(error)) from error


def _self_hash(document: Mapping[str, object], field: str) -> None:
    _semantic(field in _SELF_HASH_FIELDS, "unrecognized self-hash field")
    unhashed = dict(document)
    declared = unhashed.pop(field, None)
    try:
        calculated = canonical_sha256(unhashed)
    except (TypeError, ValueError) as error:
        raise CorrectiveDiagnosticContractError(
            f"{field} payload is not canonical-JSON encodable"
        ) from error
    _semantic(
        _is_sha256(declared) and declared == calculated,
        f"{field} is invalid",
    )


def _coordinate_lookup() -> Mapping[str, Mapping[str, object]]:
    return {str(value["cell_id"]): value for value in COORDINATE_CELLS}


def _anisotropy_lookup() -> Mapping[str, Mapping[str, object]]:
    return {str(value["cell_id"]): value for value in ANISOTROPY_CELLS}


def _serialization_rebind_sha256(row: Mapping[str, object]) -> str:
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    if "original_luma_coordinate_policy" in row:
        fields = (
            "route",
            "original_luma_coordinate_policy",
            "original_chroma_coordinate_policy",
            "serialized_luma_coordinate_policy",
            "serialized_chroma_coordinate_policy",
        )
    else:
        fields = (
            "route",
            "original_coordinate_policy",
            "serialized_coordinate_policy",
        )
    for field in fields:
        value = row.get(field)
        _semantic(isinstance(value, str), "serialization rebind field is invalid")
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    applied = row.get("serialization_rebind_applied")
    _semantic(isinstance(applied, bool), "serialization rebind flag is invalid")
    payload.append(1 if applied else 0)
    return hashlib.sha256(payload).hexdigest()


def _validate_plane(
    plane: Mapping[str, object],
    *,
    expected_policy: str,
    expected_anisotropy: int,
) -> None:
    _semantic(plane.get("coordinate_policy") == expected_policy, "plane coordinate policy differs")
    _semantic(
        plane.get("anisotropy_strength_q12") == expected_anisotropy,
        "plane anisotropy strength differs",
    )
    sample_count = plane.get("sample_count")
    _semantic(
        isinstance(sample_count, int) and not isinstance(sample_count, bool) and sample_count > 0,
        "plane sample count is invalid",
    )
    for field in (
        "source_aligned_entry_flag_sample_count",
        "source_aligned_sample_preservation_count",
        "numerical_fallback_count",
    ):
        count = plane.get(field)
        _semantic(
            isinstance(count, int)
            and not isinstance(count, bool)
            and 0 <= count <= sample_count,
            f"plane {field} is invalid",
        )
    _semantic(
        plane.get("source_aligned_entry_flag_sample_count") == 0,
        "generic phase diagnostic contains a source-aligned entry flag",
    )
    _semantic(
        _is_sha256(plane.get("output_plane_sha256"))
        and _is_sha256(plane.get("normalized_plane_sha256")),
        "plane hash evidence is invalid",
    )
    _self_hash(plane, "plane_evidence_sha256")


def _observation_identity(observation: Mapping[str, object]) -> tuple[object, ...]:
    return (
        observation.get("source_asset_id"),
        observation.get("source_family_id"),
        tuple(observation.get("categories", [])),
        observation.get("degradation_profile_id"),
        observation.get("degradation_profile_sha256"),
        observation.get("input_frame_sha256"),
    )


def _validate_metric_rows(observation: Mapping[str, object]) -> None:
    rows = observation.get("metric_rows")
    _semantic(isinstance(rows, list) and len(rows) == 2, "observation metric rows differ")
    _semantic(
        [row.get("comparison_domain") for row in rows if isinstance(row, dict)]
        == ["engine_raw", "container_decoded"],
        "metric domain order differs",
    )
    for row in rows:
        _semantic(isinstance(row, dict), "metric row is not an object")
        _semantic(row.get("block_id") == observation.get("block_id"), "metric row block differs")
        _semantic(row.get("target_route") == observation.get("target_route"), "metric row route differs")
        _semantic(
            row.get("input_frame_sha256") == observation.get("input_frame_sha256"),
            "metric row input differs",
        )
        if row["comparison_domain"] == "engine_raw":
            _semantic(
                row.get("candidate_output_frame_sha256")
                == observation.get("candidate_output_frame_sha256"),
                "engine-raw metric output differs",
            )
            _semantic(row.get("writer_evidence_sha256") is None, "engine-raw writer evidence is present")
            _semantic(
                row.get("metrics", {}).get("writer_y_psnr_contribution_db") is None,
                "engine-raw writer contribution is present",
            )
        else:
            _semantic(_is_sha256(row.get("writer_evidence_sha256")), "decoded writer evidence is absent")
            contribution = row.get("metrics", {}).get("writer_y_psnr_contribution_db")
            _semantic(
                isinstance(contribution, (int, float)) and not isinstance(contribution, bool),
                "decoded writer contribution is absent",
            )
        _self_hash(row, "metric_row_sha256")


def _validate_production_reference_metric_rows(
    observation: Mapping[str, object],
) -> None:
    rows = observation.get("metric_rows")
    _semantic(
        isinstance(rows, list) and len(rows) == 2,
        "production-reference metric rows differ",
    )
    _semantic(
        [row.get("comparison_domain") for row in rows if isinstance(row, dict)]
        == ["engine_raw", "container_decoded"],
        "production-reference metric domain order differs",
    )
    for row in rows:
        _semantic(isinstance(row, dict), "production-reference metric row is not an object")
        _semantic(
            row.get("target_route") == observation.get("target_route")
            and row.get("input_frame_sha256")
            == observation.get("input_frame_sha256"),
            "production-reference metric identity differs",
        )
        if row["comparison_domain"] == "engine_raw":
            _semantic(
                row.get("candidate_output_frame_sha256")
                == observation.get("candidate_output_frame_sha256")
                and row.get("writer_evidence_sha256") is None
                and row.get("metrics", {}).get(
                    "writer_y_psnr_contribution_db"
                )
                is None,
                "production-reference raw metric binding differs",
            )
        else:
            _semantic(
                _is_sha256(row.get("writer_evidence_sha256"))
                and isinstance(
                    row.get("metrics", {}).get(
                        "writer_y_psnr_contribution_db"
                    ),
                    (int, float),
                )
                and not isinstance(
                    row.get("metrics", {}).get(
                        "writer_y_psnr_contribution_db"
                    ),
                    bool,
                ),
                "production-reference decoded metric binding differs",
            )
        _self_hash(row, "metric_row_sha256")


def _validate_native_records(
    document: Mapping[str, object],
) -> tuple[
    Mapping[str, Mapping[str, object]],
    Mapping[str, Mapping[str, object]],
]:
    records = document.get("native_records")
    _semantic(isinstance(records, list) and records, "native records are absent")
    bindings = document.get("input_bindings")
    _semantic(
        isinstance(bindings, dict),
        "native record input bindings are absent",
    )
    provenance = bindings.get("native_configuration_provenance")
    _semantic(
        isinstance(provenance, dict)
        and set(provenance) == set(_NATIVE_PROVENANCE_FIELDS)
        and all(_is_sha256(provenance.get(field)) for field in provenance),
        "native configuration provenance binding differs",
    )
    by_hash: dict[str, Mapping[str, object]] = {}
    diagnostics_by_hash: dict[str, Mapping[str, object]] = {}
    identities: set[tuple[object, ...]] = set()
    for ordinal, record in enumerate(records):
        _semantic(isinstance(record, dict), "native record is not an object")
        request = record.get("request")
        response = record.get("response")
        _semantic(
            isinstance(request, dict) and isinstance(response, dict),
            "native request or response is not an object",
        )
        _semantic(
            set(record)
            == {
                "ordinal",
                "source_asset_id",
                "degradation_profile_id",
                "target_route",
                "input_frame_sha256",
                "input_nv12_sha256",
                "request",
                "response",
                "request_sha256",
                "response_sha256",
                "native_diagnostic_sha256",
                "native_record_sha256",
            },
            "native record field set differs",
        )
        request_hash = canonical_sha256(request)
        response_hash = canonical_sha256(response)
        _semantic(
            record.get("ordinal") == ordinal
            and record.get("request_sha256") == request_hash
            and record.get("response_sha256") == response_hash,
            "native record ordinal or request/response hash differs",
        )
        _semantic(
            set(request)
            == {
                "schema_version",
                "operation",
                "configuration_id",
                "compiler_inputs_sha256",
                "coordinate_model_contract_path",
                "coordinate_model_contract_sha256",
                "analysis_grid_source_step",
                "output_descriptors",
                "production_v2_reference_output_path",
                "frame",
            }
            and request.get("schema_version") == "1.0.0"
            and request.get("operation") == "diagnose_corrective_frame",
            "embedded native request identity differs",
        )
        frame = request.get("frame")
        _semantic(
            isinstance(frame, dict) and set(frame) == _FRAME_FIELDS,
            "embedded native frame field set differs",
        )
        route = record.get("target_route")
        input_width = frame.get("input_width")
        input_height = frame.get("input_height")
        output_width = frame.get("output_width")
        output_height = frame.get("output_height")
        geometry_matches = (
            isinstance(input_width, int)
            and not isinstance(input_width, bool)
            and input_width > 0
            and isinstance(input_height, int)
            and not isinstance(input_height, bool)
            and input_height > 0
            and isinstance(output_width, int)
            and not isinstance(output_width, bool)
            and output_width > 0
            and isinstance(output_height, int)
            and not isinstance(output_height, bool)
            and output_height > 0
            and (
                (
                    route == "direct_2x"
                    and output_width == input_width * 2
                    and output_height == input_height * 2
                )
                or (
                    route == "direct_3_over_2"
                    and output_width * 2 == input_width * 3
                    and output_height * 2 == input_height * 3
                )
            )
        )
        _semantic(
            route in ROUTES
            and frame.get("route") == evaluator_route_for_contract_route(str(route))
            and frame.get("input_sha256") == record.get("input_nv12_sha256")
            and _is_sha256(record.get("input_frame_sha256"))
            and _is_sha256(record.get("input_nv12_sha256"))
            and isinstance(frame.get("request_id"), str)
            and bool(frame["request_id"])
            and frame.get("pixel_format") == "420v"
            and frame.get("matrix") == "BT.709"
            and frame.get("range") == "video"
            and frame.get("chroma_siting") == "left"
            and geometry_matches
            and isinstance(request.get("output_descriptors"), list)
            and len(request["output_descriptors"]) == 16,
            "embedded native frame, route, geometry, or descriptor count differs",
        )
        descriptor_axes = [
            (str(coordinate["cell_id"]), str(anisotropy["cell_id"]))
            for coordinate in COORDINATE_CELLS
            for anisotropy in ANISOTROPY_CELLS
        ]
        descriptor_paths: list[object] = []
        for descriptor_ordinal, (descriptor, expected_axes) in enumerate(
            zip(request["output_descriptors"], descriptor_axes)
        ):
            _semantic(
                isinstance(descriptor, dict)
                and set(descriptor)
                == {
                    "ordinal",
                    "coordinate_cell_id",
                    "anisotropy_cell_id",
                    "output_path",
                }
                and descriptor.get("ordinal") == descriptor_ordinal
                and (
                    descriptor.get("coordinate_cell_id"),
                    descriptor.get("anisotropy_cell_id"),
                )
                == expected_axes
                and isinstance(descriptor.get("output_path"), str)
                and os.path.isabs(str(descriptor["output_path"]))
                and os.path.normpath(str(descriptor["output_path"]))
                == descriptor["output_path"],
                "embedded native output descriptor axis, order, or path differs",
            )
            descriptor_paths.append(descriptor["output_path"])
        production_output_path = request.get(
            "production_v2_reference_output_path"
        )
        _semantic(
            len(set(descriptor_paths)) == 16
            and isinstance(production_output_path, str)
            and os.path.isabs(production_output_path)
            and os.path.normpath(production_output_path)
            == production_output_path
            and production_output_path not in descriptor_paths
            and frame.get("output_path") == production_output_path
            and isinstance(frame.get("input_path"), str)
            and os.path.isabs(str(frame["input_path"]))
            and os.path.normpath(str(frame["input_path"]))
            == frame["input_path"]
            and Path(str(frame["input_path"])).name
            == f"{record.get('input_nv12_sha256')}.nv12"
            and frame["input_path"] not in set(descriptor_paths)
            | {production_output_path},
            "embedded native output paths repeat or production path differs",
        )
        _semantic(
            set(response)
            == {
                "schema_version",
                "status",
                "request_sha256",
                "corrective_diagnostic",
            }
            and response.get("schema_version") == "1.0.0"
            and response.get("status") == "ok"
            and response.get("request_sha256") == request_hash,
            "embedded native outer response differs",
        )
        diagnostic = response.get("corrective_diagnostic")
        _semantic(
            isinstance(diagnostic, dict)
            and set(diagnostic) == _DIAGNOSTIC_FIELDS,
            "embedded native diagnostic field set differs",
        )
        _semantic(
            diagnostic.get("status") == "development_diagnostic_no_selection"
            and diagnostic.get("split") == "development"
            and diagnostic.get("validation_accessed") is False
            and diagnostic.get("holdout_accessed") is False
            and diagnostic.get("selected_winner") is None
            and diagnostic.get("request_id") == frame.get("request_id")
            and diagnostic.get("target_route") == route
            and diagnostic.get("configuration_id")
            == request.get("configuration_id")
            and _is_configuration_id(diagnostic.get("configuration_id"))
            and diagnostic.get("compiler_inputs_sha256")
            == request.get("compiler_inputs_sha256")
            == bindings.get("compiler_inputs_sha256")
            and diagnostic.get("input_sha256")
            == frame.get("input_sha256")
            and diagnostic.get("coordinate_model_contract_file_sha256")
            == request.get("coordinate_model_contract_sha256")
            == bindings.get("coordinate_model_contract_file_sha256")
            and diagnostic.get("coordinate_oracle_matrix_sha256")
            == bindings.get("coordinate_oracle_matrix_sha256")
            and diagnostic.get("coordinate_experiment_dimensions_sha256")
            == bindings.get("coordinate_experiment_dimensions_sha256")
            and diagnostic.get("analysis_grid_source_step")
            == request.get("analysis_grid_source_step")
            and diagnostic.get("output_plane_hash_contract")
            == "active-nv12-code-bytes-sha256-v1"
            and diagnostic.get("normalized_plane_hash_contract")
            == "mirmir-ash-normalized-plane-f64-be-v1"
            and diagnostic.get("analysis_grid_hash_contract")
            == "mirmir-ash-analysis-grid-v3-be-v1",
            "embedded native diagnostic access, route, or hash contract differs",
        )
        invocation = diagnostic.get("native_invocation_proof")
        _semantic(
            isinstance(invocation, dict)
            and set(invocation)
            == {
                "protocol",
                "process_id",
                "executable_sha256",
                "source_manifest_sha256",
            }
            and invocation.get("protocol")
            == "serve-candidate/diagnose_corrective_frame-v1"
            and isinstance(invocation.get("process_id"), int)
            and not isinstance(invocation["process_id"], bool)
            and invocation["process_id"] > 0
            and invocation.get("executable_sha256")
            == bindings.get("native_executable_sha256")
            and invocation.get("source_manifest_sha256")
            == bindings.get("native_source_manifest_sha256"),
            "embedded native invocation proof differs",
        )
        _semantic(
            all(
                diagnostic.get(field) == provenance.get(field)
                for field in _NATIVE_PROVENANCE_FIELDS
            )
            and provenance.get("candidate_vector_sha256")
            == bindings.get("base_candidate_vector_sha256")
            and provenance.get("mapping_sha256")
            == bindings.get("mapping_sha256")
            and provenance.get("corpus_lock_bundle_sha256")
            == bindings.get("corpus_lock_bundle_sha256"),
            "embedded native configuration provenance differs",
        )
        native_cells = diagnostic.get("cells")
        _semantic(
            isinstance(native_cells, list) and len(native_cells) == 16,
            "embedded native cell count differs",
        )
        for cell_ordinal, (cell, expected_axes, descriptor_path) in enumerate(
            zip(native_cells, descriptor_axes, descriptor_paths)
        ):
            coordinate_id, anisotropy_id = expected_axes
            _semantic(
                isinstance(cell, dict)
                and cell.get("ordinal") == cell_ordinal
                and cell.get("block_id")
                == _block_id(str(route), coordinate_id, anisotropy_id)
                and cell.get("coordinate_cell_id") == coordinate_id
                and cell.get("anisotropy_cell_id") == anisotropy_id
                and cell.get("output_path") == descriptor_path,
                "embedded native cell axis, order, block, or path differs",
            )
        production_reference = diagnostic.get("production_v2_reference")
        _semantic(
            isinstance(production_reference, dict)
            and production_reference.get("output_path")
            == production_output_path,
            "embedded native production reference path differs",
        )
        _semantic(
            diagnostic.get("session_counters")
            == {
                "input_decode_count": 1,
                "analysis_grid_build_count": 1,
                "generic_compile_count_for_route": 1,
                "generic_dispatch_count": 1,
                "plane_diagnostic_count": 4,
                "risk_diagnostic_count": 1,
                "production_v2_dispatch_count": 1,
                "output_write_count": 17,
                "output_reopen_count": 17,
            },
            "embedded native session counters differ",
        )
        diagnostic_hash = canonical_sha256(diagnostic)
        _semantic(
            record.get("native_diagnostic_sha256") == diagnostic_hash,
            "embedded native diagnostic hash differs",
        )
        identity = (
            record.get("source_asset_id"),
            record.get("degradation_profile_id"),
            route,
            record.get("input_frame_sha256"),
        )
        _semantic(identity not in identities, "native record identity repeats")
        identities.add(identity)
        _self_hash(record, "native_record_sha256")
        record_hash = str(record["native_record_sha256"])
        _semantic(record_hash not in by_hash, "native record hash repeats")
        by_hash[record_hash] = record
        diagnostics_by_hash[record_hash] = diagnostic
    return by_hash, diagnostics_by_hash


def _native_record_for_observation(
    observation: Mapping[str, object],
    *,
    records: Mapping[str, Mapping[str, object]],
) -> Mapping[str, object]:
    record = records.get(str(observation.get("native_record_sha256")))
    _semantic(record is not None, "observation native record is absent")
    assert record is not None
    _semantic(
        record.get("source_asset_id") == observation.get("source_asset_id")
        and record.get("degradation_profile_id")
        == observation.get("degradation_profile_id")
        and record.get("target_route") == observation.get("target_route")
        and record.get("input_frame_sha256")
        == observation.get("input_frame_sha256"),
        "observation native-record identity differs",
    )
    return record


def _native_original_output_manifest(
    record: Mapping[str, object],
) -> list[dict[str, object]]:
    """Derive the exact 17-file native output manifest from one ordered record."""

    request = record.get("request")
    response = record.get("response")
    _semantic(
        isinstance(request, dict) and isinstance(response, dict),
        "native output manifest request or response is absent",
    )
    frame = request.get("frame")
    descriptors = request.get("output_descriptors")
    diagnostic = response.get("corrective_diagnostic")
    _semantic(
        isinstance(frame, dict)
        and frame.get("pixel_format") == "420v"
        and isinstance(descriptors, list)
        and len(descriptors) == 16
        and isinstance(diagnostic, dict),
        "native output manifest contract evidence differs",
    )
    width = frame.get("output_width")
    height = frame.get("output_height")
    _semantic(
        isinstance(width, int)
        and not isinstance(width, bool)
        and width > 0
        and width % 2 == 0
        and isinstance(height, int)
        and not isinstance(height, bool)
        and height > 0
        and height % 2 == 0,
        "native 420v output geometry is not positive and even",
    )
    output_size_bytes = (
        width * height
        + (width // 2) * (height // 2) * 2
    )
    cells = diagnostic.get("cells")
    production = diagnostic.get("production_v2_reference")
    _semantic(
        isinstance(cells, list)
        and len(cells) == 16
        and isinstance(production, dict),
        "native output manifest response evidence differs",
    )
    rows: list[dict[str, object]] = []
    for descriptor, cell in zip(descriptors, cells):
        _semantic(
            isinstance(descriptor, dict)
            and isinstance(cell, dict)
            and descriptor.get("output_path") == cell.get("output_path")
            and isinstance(cell.get("output_nv12_sha256"), str)
            and _is_sha256(cell["output_nv12_sha256"]),
            "native output manifest cell binding differs",
        )
        output_path = str(descriptor["output_path"])
        rows.append(
            {
                "original_name": Path(output_path).name,
                "sha256": cell["output_nv12_sha256"],
                "size_bytes": output_size_bytes,
            }
        )
    production_path = request.get("production_v2_reference_output_path")
    _semantic(
        isinstance(production_path, str)
        and production.get("output_path") == production_path
        and _is_sha256(production.get("output_nv12_sha256")),
        "native output manifest production binding differs",
    )
    rows.append(
        {
            "original_name": Path(production_path).name,
            "sha256": production["output_nv12_sha256"],
            "size_bytes": output_size_bytes,
        }
    )
    rows.sort(key=lambda row: str(row["original_name"]))
    _semantic(
        len(rows) == 17
        and len({str(row["original_name"]) for row in rows}) == 17,
        "native output manifest names repeat",
    )
    return rows


def _validate_completed_execution_evidence(
    bindings: Mapping[str, object],
    *,
    expected_input_stub_names: set[str],
    native_record_sequence: Sequence[Mapping[str, object]],
) -> None:
    closure = bindings.get("completed_execution_evidence")
    expected_fields = {
        "schema_version",
        "artifact_kind",
        "status",
        "work_root_path",
        "work_root_identity",
        "journal",
        "journal_entry_bindings",
        "journal_entry_binding_manifest_sha256",
        "input_sanitation_receipt",
        "input_sanitation_receipt_file_sha256",
        "native_sanitation_receipt_count",
        "native_retained_stub_count",
        "native_sanitation_receipts",
        "native_sanitation_receipt_manifest_sha256",
        "recursive_entry_count",
        "recursive_entries",
        "recursive_manifest_sha256",
        "expected_executor_publication_receipt_name",
        "prepublication_closure_sha256",
    }
    _semantic(
        isinstance(closure, dict)
        and set(closure) == expected_fields
        and closure.get("schema_version") == "1.0.0"
        and closure.get("artifact_kind")
        == "p06_corrective_prepublication_execution_closure"
        and closure.get("status")
        == "sanitation_and_journal_closed_pending_publication"
        and isinstance(closure.get("work_root_path"), str)
        and os.path.isabs(str(closure["work_root_path"]))
        and os.path.normpath(str(closure["work_root_path"]))
        == closure["work_root_path"]
        and re.fullmatch(
            r"\.mirmir-corrective-execution-[0-9a-f]{32}",
            Path(str(closure["work_root_path"])).name,
        )
        is not None
        and closure.get("expected_executor_publication_receipt_name")
        == "executor-publication-receipt.json",
        "completed execution prepublication closure header differs",
    )
    work_identity = closure.get("work_root_identity")
    journal = closure.get("journal")
    _semantic(
        isinstance(work_identity, dict)
        and set(work_identity) == {"device", "inode"}
        and all(
            isinstance(work_identity[field], int)
            and not isinstance(work_identity[field], bool)
            and work_identity[field] >= 0
            for field in ("device", "inode")
        )
        and journal
        == {
            "entry_count": 36,
            "evidence_count": 18,
            "completed_call_count": 18,
            "tail_sha256": journal.get("tail_sha256")
            if isinstance(journal, dict)
            else None,
        }
        and _is_sha256(journal.get("tail_sha256")),
        "completed execution root identity or journal closure differs",
    )
    journal_bindings = closure.get("journal_entry_bindings")
    _semantic(
        isinstance(journal_bindings, list)
        and len(journal_bindings) == 36
        and closure.get("journal_entry_binding_manifest_sha256")
        == canonical_sha256(journal_bindings),
        "completed execution journal entry binding manifest differs",
    )
    previous_entry_sha256 = _CORRECTIVE_JOURNAL_GENESIS_SHA256
    for sequence_ordinal, entry in enumerate(journal_bindings):
        expected_kind = (
            "call-evidence"
            if sequence_ordinal % 2 == 0
            else "output-cleanup"
        )
        _semantic(
            isinstance(entry, dict)
            and set(entry)
            == {
                "name",
                "sequence_ordinal",
                "request_ordinal",
                "entry_kind",
                "previous_entry_sha256",
                "entry_sha256",
                "file_sha256",
                "size_bytes",
            }
            and entry.get("name")
            == f"{sequence_ordinal:06d}-{expected_kind}.json"
            and entry.get("sequence_ordinal") == sequence_ordinal
            and entry.get("request_ordinal") == sequence_ordinal // 2
            and entry.get("entry_kind") == expected_kind
            and entry.get("previous_entry_sha256")
            == previous_entry_sha256
            and _is_sha256(entry.get("entry_sha256"))
            and _is_sha256(entry.get("file_sha256"))
            and isinstance(entry.get("size_bytes"), int)
            and not isinstance(entry["size_bytes"], bool)
            and entry["size_bytes"] > 0,
            "completed execution journal entry binding differs",
        )
        previous_entry_sha256 = str(entry["entry_sha256"])
    _semantic(
        previous_entry_sha256 == journal["tail_sha256"],
        "completed execution journal binding tail differs",
    )
    empty_sha256 = hashlib.sha256(b"").hexdigest()
    input_receipt = closure.get("input_sanitation_receipt")
    _semantic(
        isinstance(input_receipt, dict)
        and set(input_receipt)
        == {
            "schema_version",
            "artifact_kind",
            "status",
            "retained_directory_identity",
            "retained_stub_count",
            "retained_stubs",
            "retained_stub_manifest_sha256",
            "original_input_manifest_sha256",
            "receipt_sha256",
        }
        and input_receipt.get("schema_version") == "1.0.0"
        and input_receipt.get("artifact_kind")
        == "p06_corrective_development_input_sanitation_receipt"
        and input_receipt.get("status") == "sanitized_retained"
        and isinstance(input_receipt.get("retained_stubs"), list)
        and input_receipt.get("retained_stub_count")
        == len(input_receipt["retained_stubs"])
        and input_receipt["retained_stub_count"] > 0
        and input_receipt.get("retained_stub_manifest_sha256")
        == canonical_sha256(input_receipt["retained_stubs"])
        and _is_sha256(input_receipt.get("original_input_manifest_sha256"))
        and _is_sha256(
            closure.get("input_sanitation_receipt_file_sha256")
        )
        and closure.get("input_sanitation_receipt_file_sha256")
        == hashlib.sha256(
            canonical_artifact_file_bytes(input_receipt)
        ).hexdigest(),
        "completed execution input sanitation receipt differs",
    )
    input_directory_identity = input_receipt.get(
        "retained_directory_identity"
    )
    _semantic(
        isinstance(input_directory_identity, dict)
        and set(input_directory_identity) == {"device", "inode"}
        and all(
            isinstance(input_directory_identity[field], int)
            and not isinstance(input_directory_identity[field], bool)
            and input_directory_identity[field] >= 0
            for field in ("device", "inode")
        ),
        "completed execution input sanitation directory identity differs",
    )
    input_stub_names: set[str] = set()
    input_stub_identities: set[tuple[int, int]] = set()
    for stub in input_receipt["retained_stubs"]:
        _semantic(
            isinstance(stub, dict)
            and set(stub)
            == {"name", "device", "inode", "size_bytes", "sha256"}
            and isinstance(stub.get("name"), str)
            and bool(stub["name"])
            and Path(str(stub["name"])).name == stub["name"]
            and stub["name"] not in input_stub_names
            and isinstance(stub.get("device"), int)
            and not isinstance(stub["device"], bool)
            and stub["device"] >= 0
            and isinstance(stub.get("inode"), int)
            and not isinstance(stub["inode"], bool)
            and stub["inode"] >= 0
            and (stub["device"], stub["inode"])
            not in input_stub_identities
            and stub.get("size_bytes") == 0
            and stub.get("sha256") == empty_sha256,
            "completed execution input sanitation stub differs",
        )
        input_stub_names.add(str(stub["name"]))
        input_stub_identities.add((int(stub["device"]), int(stub["inode"])))
    _semantic(
        input_stub_names == expected_input_stub_names,
        "completed execution input sanitation stubs differ from native inputs",
    )
    _self_hash(input_receipt, "receipt_sha256")
    input_receipt_payload = canonical_artifact_file_bytes(input_receipt)
    native_receipts = closure.get("native_sanitation_receipts")
    _semantic(
        isinstance(native_receipts, list)
        and len(native_receipts)
        == closure.get("native_sanitation_receipt_count")
        == 18
        and closure.get("native_retained_stub_count") == 306
        and closure.get("native_sanitation_receipt_manifest_sha256")
        == canonical_sha256(native_receipts),
        "completed execution native sanitation receipt manifest differs",
    )
    retained_paths: set[str] = set()
    retained_directory_identities: set[tuple[int, int]] = set()
    retained_stub_identities: set[tuple[int, int]] = set()
    retained_stub_count = 0
    _semantic(
        len(native_record_sequence) == 18,
        "completed execution native record sequence differs",
    )
    for receipt_ordinal, (receipt, native_record) in enumerate(
        zip(native_receipts, native_record_sequence)
    ):
        expected_output_manifest = _native_original_output_manifest(
            native_record
        )
        expected_original_names = [
            str(row["original_name"]) for row in expected_output_manifest
        ]
        _semantic(
            isinstance(receipt, dict)
            and set(receipt)
            == {
                "status",
                "retained_transaction_path",
                "retained_transaction_identity",
                "retained_stub_count",
                "retained_stubs",
                "retained_stub_manifest_sha256",
                "original_output_manifest_sha256",
            }
            and receipt.get("status") == "sanitized_retained"
            and isinstance(receipt.get("retained_transaction_path"), str)
            and os.path.isabs(str(receipt["retained_transaction_path"]))
            and os.path.normpath(str(receipt["retained_transaction_path"]))
            == receipt["retained_transaction_path"]
            and receipt["retained_transaction_path"] not in retained_paths
            and Path(str(receipt["retained_transaction_path"])).parent
            == Path(str(closure["work_root_path"]))
            and isinstance(receipt.get("retained_transaction_identity"), dict)
            and set(receipt["retained_transaction_identity"])
            == {"device", "inode"}
            and all(
                isinstance(receipt["retained_transaction_identity"][field], int)
                and not isinstance(
                    receipt["retained_transaction_identity"][field], bool
                )
                and receipt["retained_transaction_identity"][field] >= 0
                for field in ("device", "inode")
            )
            and (
                receipt["retained_transaction_identity"]["device"],
                receipt["retained_transaction_identity"]["inode"],
            )
            not in retained_directory_identities
            and isinstance(receipt.get("retained_stubs"), list)
            and receipt.get("retained_stub_count")
            == len(receipt["retained_stubs"])
            == 17
            and receipt.get("retained_stub_manifest_sha256")
            == canonical_sha256(receipt["retained_stubs"])
            and receipt.get("original_output_manifest_sha256")
            == canonical_sha256(expected_output_manifest),
            "completed execution native sanitation receipt differs",
        )
        retained_paths.add(str(receipt["retained_transaction_path"]))
        retained_directory_identities.add(
            (
                int(receipt["retained_transaction_identity"]["device"]),
                int(receipt["retained_transaction_identity"]["inode"]),
            )
        )
        retained_names: set[str] = set()
        for stub in receipt["retained_stubs"]:
            _semantic(
                isinstance(stub, dict)
                and set(stub)
                == {
                    "original_name",
                    "retained_name",
                    "device",
                    "inode",
                    "size_bytes",
                    "sha256",
                }
                and isinstance(stub.get("original_name"), str)
                and bool(stub["original_name"])
                and Path(str(stub["original_name"])).name
                == stub["original_name"]
                and isinstance(stub.get("retained_name"), str)
                and bool(stub["retained_name"])
                and Path(str(stub["retained_name"])).name
                == stub["retained_name"]
                and stub.get("retained_name") not in retained_names
                and isinstance(stub.get("device"), int)
                and not isinstance(stub["device"], bool)
                and stub["device"] >= 0
                and isinstance(stub.get("inode"), int)
                and not isinstance(stub["inode"], bool)
                and stub["inode"] >= 0
                and (stub["device"], stub["inode"])
                not in retained_stub_identities
                and stub.get("size_bytes") == 0
                and stub.get("sha256") == empty_sha256,
                "completed execution native sanitation stub differs",
            )
            retained_names.add(str(stub["retained_name"]))
            retained_stub_identities.add(
                (int(stub["device"]), int(stub["inode"]))
            )
            retained_stub_count += 1
        _semantic(
            [
                str(stub["original_name"])
                for stub in receipt["retained_stubs"]
            ]
            == expected_original_names,
            "completed execution native sanitation original-name order differs",
        )
        cleanup_binding = journal_bindings[receipt_ordinal * 2 + 1]
        cleanup_unsealed = {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_corrective_diagnostic_call_journal_entry"
            ),
            "sequence_ordinal": receipt_ordinal * 2 + 1,
            "request_ordinal": receipt_ordinal,
            "entry_kind": "output-cleanup",
            "previous_entry_sha256": cleanup_binding[
                "previous_entry_sha256"
            ],
            "evidence": {
                "native_record_sha256": native_record[
                    "native_record_sha256"
                ],
                "output_cleanup_status": "sanitized_retained",
                "native_cleanup_receipt": receipt,
            },
        }
        cleanup_entry_sha256 = canonical_sha256(cleanup_unsealed)
        cleanup_document = {
            **cleanup_unsealed,
            "entry_sha256": cleanup_entry_sha256,
        }
        cleanup_payload = canonical_artifact_file_bytes(cleanup_document)
        _semantic(
            cleanup_binding["entry_sha256"] == cleanup_entry_sha256
            and cleanup_binding["file_sha256"]
            == hashlib.sha256(cleanup_payload).hexdigest()
            and cleanup_binding["size_bytes"] == len(cleanup_payload),
            "completed execution native sanitation journal binding differs",
        )
    _semantic(
        retained_stub_count == 306,
        "completed execution native sanitation aggregate differs",
    )
    recursive_entries = closure.get("recursive_entries")
    _semantic(
        isinstance(recursive_entries, list)
        and len(recursive_entries) == closure.get("recursive_entry_count")
        and closure.get("recursive_manifest_sha256")
        == canonical_sha256(recursive_entries),
        "completed execution recursive manifest differs",
    )
    relative_paths: set[str] = set()
    recursive_by_path: dict[str, Mapping[str, object]] = {}
    for entry in recursive_entries:
        relative_path = entry.get("relative_path") if isinstance(entry, dict) else None
        entry_kind = entry.get("entry_kind") if isinstance(entry, dict) else None
        _semantic(
            isinstance(entry, dict)
            and isinstance(relative_path, str)
            and bool(relative_path)
            and not os.path.isabs(relative_path)
            and Path(relative_path).parts
            and all(part not in {"", ".", ".."} for part in Path(relative_path).parts)
            and relative_path not in relative_paths
            and (
                (entry_kind == "directory" and set(entry) == {"relative_path", "entry_kind"})
                or (
                    entry_kind == "regular_file"
                    and set(entry)
                    == {"relative_path", "entry_kind", "size_bytes", "file_sha256"}
                    and isinstance(entry.get("size_bytes"), int)
                    and entry["size_bytes"] >= 0
                    and _is_sha256(entry.get("file_sha256"))
                )
            ),
            "completed execution recursive entry differs",
        )
        relative_paths.add(relative_path)
        recursive_by_path[relative_path] = entry
    _semantic(
        [entry["relative_path"] for entry in recursive_entries]
        == sorted(relative_paths)
        and "executor-publication-receipt.json" not in relative_paths,
        "completed execution recursive order or prepublication boundary differs",
    )
    expected_relative_paths = {
        "inputs",
        "journal",
        "input-sanitation-receipt.json",
    }
    expected_relative_paths.update(
        f"inputs/{stub['name']}"
        for stub in input_receipt["retained_stubs"]
    )
    expected_relative_paths.update(
        f"journal/{entry['name']}" for entry in journal_bindings
    )
    for receipt in native_receipts:
        directory_name = Path(
            str(receipt["retained_transaction_path"])
        ).name
        expected_relative_paths.add(directory_name)
        expected_relative_paths.update(
            f"{directory_name}/{stub['retained_name']}"
            for stub in receipt["retained_stubs"]
        )
    _semantic(
        relative_paths == expected_relative_paths
        and recursive_by_path.get("inputs")
        == {"relative_path": "inputs", "entry_kind": "directory"}
        and recursive_by_path.get("journal")
        == {"relative_path": "journal", "entry_kind": "directory"},
        "completed execution recursive leaf set differs from its receipts",
    )
    _semantic(
        all(
            recursive_by_path.get(f"journal/{entry['name']}")
            == {
                "relative_path": f"journal/{entry['name']}",
                "entry_kind": "regular_file",
                "size_bytes": entry["size_bytes"],
                "file_sha256": entry["file_sha256"],
            }
            for entry in journal_bindings
        ),
        "completed execution recursive journal linkage differs",
    )
    input_receipt_row = recursive_by_path.get(
        "input-sanitation-receipt.json"
    )
    _semantic(
        input_receipt_row
        == {
            "relative_path": "input-sanitation-receipt.json",
            "entry_kind": "regular_file",
            "size_bytes": len(input_receipt_payload),
            "file_sha256": closure[
                "input_sanitation_receipt_file_sha256"
            ],
        }
        and all(
            recursive_by_path.get(f"inputs/{stub['name']}")
            == {
                "relative_path": f"inputs/{stub['name']}",
                "entry_kind": "regular_file",
                "size_bytes": 0,
                "file_sha256": empty_sha256,
            }
            for stub in input_receipt["retained_stubs"]
        ),
        "completed execution input receipt or stub manifest linkage differs",
    )
    _semantic(
        all(
            recursive_by_path.get(
                Path(str(receipt["retained_transaction_path"])).name
            )
            == {
                "relative_path": Path(
                    str(receipt["retained_transaction_path"])
                ).name,
                "entry_kind": "directory",
            }
            and all(
                recursive_by_path.get(
                    f"{Path(str(receipt['retained_transaction_path'])).name}/"
                    f"{stub['retained_name']}"
                )
                == {
                    "relative_path": (
                        f"{Path(str(receipt['retained_transaction_path'])).name}/"
                        f"{stub['retained_name']}"
                    ),
                    "entry_kind": "regular_file",
                    "size_bytes": 0,
                    "file_sha256": empty_sha256,
                }
                for stub in receipt["retained_stubs"]
            )
            for receipt in native_receipts
        ),
        "completed execution native receipt recursive linkage differs",
    )
    _self_hash(closure, "prepublication_closure_sha256")


def _validate_live_holdout_guard_binding(
    bindings: Mapping[str, object],
) -> None:
    guard = bindings.get("live_holdout_preopen_verification")
    _semantic(
        isinstance(guard, dict)
        and guard.get("verification_status") == "pass"
        and guard.get("access_status") == "unopened"
        and guard.get("access_count") == 0
        and guard.get("open_intent_anchor_present") is False
        and guard.get("pixel_content_included") is False
        and bindings.get("live_holdout_preopen_verification_sha256")
        == canonical_sha256(guard),
        "live holdout preopen verification binding differs",
    )


def validate_coordinate_anisotropy_artifact(
    document: Mapping[str, object],
) -> Mapping[str, object]:
    """Validate one complete, unselected, open-development 4x4 diagnostic."""

    _schema(document, _COORDINATE_SCHEMA)
    _semantic(
        document.get("dimension_contract") == coordinate_anisotropy_dimension_contract(),
        "coordinate-anisotropy dimension contract differs",
    )
    bindings = document["input_bindings"]
    assert isinstance(bindings, dict)
    _validate_live_holdout_guard_binding(bindings)
    native_records, native_diagnostics = _validate_native_records(document)
    native_record_sequence = document["native_records"]
    assert isinstance(native_record_sequence, list)
    _validate_completed_execution_evidence(
        bindings,
        expected_input_stub_names={
            f"{record['input_nv12_sha256']}.nv12"
            for record in native_records.values()
        },
        native_record_sequence=native_record_sequence,
    )
    expected_counts = {"direct_2x": 12, "direct_3_over_2": 6}
    _semantic(
        bindings.get("expected_observation_count_by_route") == expected_counts,
        "coordinate expected route observation counts differ",
    )
    native_hashes_by_route = {
        route: [
            row["native_record_sha256"]
            for row in native_record_sequence
            if isinstance(row, dict) and row.get("target_route") == route
        ]
        for route in ROUTES
    }
    _semantic(
        len(native_record_sequence) == 18
        and all(
            len(native_hashes_by_route[route]) == expected_counts[route]
            for route in ROUTES
        ),
        "coordinate native record route counts differ",
    )
    _semantic(
        bindings.get("output_plane_hash_contract")
        == "active-nv12-code-bytes-sha256-v1"
        and bindings.get("normalized_plane_hash_contract")
        == "mirmir-ash-normalized-plane-f64-be-v1"
        and bindings.get("analysis_grid_hash_contract")
        == "mirmir-ash-analysis-grid-v3-be-v1",
        "coordinate diagnostic hash contracts differ",
    )
    route_luts = bindings["generic_route_luts"]
    assert isinstance(route_luts, list)
    _semantic(
        [row.get("route") for row in route_luts if isinstance(row, dict)] == list(ROUTES),
        "generic route LUT order differs",
    )
    for row in route_luts:
        assert isinstance(row, dict)
        if "original_luma_coordinate_policy" in row:
            expected_applied = (
                row.get("original_luma_coordinate_policy")
                != row.get("serialized_luma_coordinate_policy")
                or row.get("original_chroma_coordinate_policy")
                != row.get("serialized_chroma_coordinate_policy")
            )
            policy_binding_valid = (
                row.get("serialized_luma_coordinate_policy")
                == "half_pixel_center"
                and row.get("serialized_chroma_coordinate_policy")
                == "half_pixel_center"
            )
        else:
            expected_applied = (
                row.get("original_coordinate_policy")
                != row.get("serialized_coordinate_policy")
            )
            policy_binding_valid = (
                row.get("serialized_coordinate_policy")
                == "half_pixel_center"
            )
        _semantic(
            row.get("serialization_rebind_contract")
            == "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
            and policy_binding_valid
            and row.get("serialization_rebind_applied") is expected_applied
            and row.get("serialization_rebind_sha256")
            == _serialization_rebind_sha256(row),
            "generic route serialization-rebind evidence differs",
        )
    route_lut_by_name = {str(row["route"]): row for row in route_luts}
    _semantic(
        bindings.get("generic_phase_compilation_manifest_sha256")
        == canonical_sha256(route_luts),
        "generic phase compilation manifest hash differs",
    )

    reference = document["production_v2_reference"]
    assert isinstance(reference, dict)
    _semantic(
        reference.get("candidate_vector_sha256") == bindings.get("base_candidate_vector_sha256")
        and reference.get("adapter_configuration_sha256")
        == bindings.get("base_adapter_configuration_sha256")
        and reference.get("compiler_inputs_sha256") == bindings.get("compiler_inputs_sha256"),
        "production-V2 reference is not bound to the base candidate",
    )
    _semantic(
        [row.get("route") for row in reference.get("route_luts", []) if isinstance(row, dict)]
        == list(ROUTES),
        "production-V2 reference route order differs",
    )
    reference_observations = reference.get("observations")
    assert isinstance(reference_observations, list)
    _semantic(bool(reference_observations), "production-V2 reference has no observations")
    reference_identities_by_route: dict[str, list[tuple[object, ...]]] = {
        route: [] for route in ROUTES
    }
    reference_native_hashes_by_route: dict[str, list[object]] = {
        route: [] for route in ROUTES
    }
    seen_reference_identities: set[tuple[object, ...]] = set()
    for observation in reference_observations:
        assert isinstance(observation, dict)
        route = str(observation["target_route"])
        identity = _observation_identity(observation)
        _semantic(
            identity not in seen_reference_identities,
            "production-V2 reference observation identity repeats",
        )
        seen_reference_identities.add(identity)
        reference_identities_by_route[route].append(identity)
        reference_native_hashes_by_route[route].append(
            observation.get("native_record_sha256")
        )
        planes = observation["planes"]
        assert isinstance(planes, dict)
        for channel in ("y", "cb", "cr"):
            plane = planes[channel]
            assert isinstance(plane, dict)
            _semantic(
                _is_sha256(plane.get("output_plane_sha256"))
                and _is_sha256(plane.get("normalized_plane_sha256")),
                "production-V2 reference plane hash is invalid",
            )
        _validate_production_reference_metric_rows(observation)
        native_record = _native_record_for_observation(
            observation,
            records=native_records,
        )
        native_diagnostic = native_diagnostics[
            str(native_record["native_record_sha256"])
        ]
        production_evidence = native_diagnostic.get(
            "production_v2_reference"
        )
        _semantic(
            isinstance(production_evidence, dict)
            and observation.get("candidate_output_nv12_sha256")
            == production_evidence.get("output_nv12_sha256")
            and observation.get("candidate_output_frame_sha256")
            == production_evidence.get("output_frame_sha256")
            and observation.get("planes") == production_evidence.get("planes"),
            "production-V2 observation differs from its embedded native record",
        )
        _self_hash(observation, "observation_sha256")
    _semantic(
        len(reference_observations) == 18
        and all(
            reference_native_hashes_by_route[route]
            == native_hashes_by_route[route]
            for route in ROUTES
        ),
        "production-V2 native identity set or order differs",
    )
    reference_manifest = {
        "candidate_vector_sha256": reference["candidate_vector_sha256"],
        "adapter_configuration_sha256": reference[
            "adapter_configuration_sha256"
        ],
        "compiler_inputs_sha256": reference["compiler_inputs_sha256"],
        "route_luts": reference["route_luts"],
    }
    _semantic(
        reference.get("reference_manifest_sha256")
        == canonical_sha256(reference_manifest)
        and reference.get("reference_evaluation_sha256")
        == canonical_sha256(reference_observations)
        and reference.get("reference_output_manifest_sha256")
        == canonical_sha256(
            [
                {
                    "target_route": row["target_route"],
                    "source_asset_id": row["source_asset_id"],
                    "degradation_profile_id": row[
                        "degradation_profile_id"
                    ],
                    "input_frame_sha256": row["input_frame_sha256"],
                    "candidate_output_nv12_sha256": row[
                        "candidate_output_nv12_sha256"
                    ],
                    "candidate_output_frame_sha256": row[
                        "candidate_output_frame_sha256"
                    ],
                    "planes": row["planes"],
                }
                for row in reference_observations
            ]
        ),
        "production-V2 reference manifest or evaluation hash differs",
    )

    blocks = document["route_cell_blocks"]
    assert isinstance(blocks, list)
    _semantic(len(blocks) == len(ROUTE_BLOCK_SPECS) == 32, "route-cell block count differs")
    coordinate = _coordinate_lookup()
    anisotropy = _anisotropy_lookup()
    block_by_id: dict[str, Mapping[str, object]] = {}
    identities_by_route: dict[str, tuple[tuple[object, ...], ...]] = {}
    for ordinal, (block, spec) in enumerate(zip(blocks, ROUTE_BLOCK_SPECS)):
        assert isinstance(block, dict)
        route, coordinate_id, anisotropy_id = spec
        expected_id = _block_id(route, coordinate_id, anisotropy_id)
        _semantic(
            block.get("ordinal") == ordinal
            and block.get("block_id") == expected_id
            and block.get("target_route") == route
            and block.get("coordinate_cell_id") == coordinate_id
            and block.get("anisotropy_cell_id") == anisotropy_id,
            "route-cell block identity or order differs",
        )
        lut = route_lut_by_name[route]
        _semantic(
            block.get("generic_lut_whole_file_sha256") == lut.get("whole_file_sha256")
            and block.get("generic_lut_payload_sha256") == lut.get("payload_sha256"),
            "route-cell generic LUT binding differs",
        )
        observations = block["observations"]
        assert isinstance(observations, list)
        _semantic(
            len(observations) == expected_counts[route],
            "route-cell block observation count differs",
        )
        observed_identities: list[tuple[object, ...]] = []
        for observation in observations:
            assert isinstance(observation, dict)
            _semantic(
                observation.get("block_id") == expected_id
                and observation.get("target_route") == route,
                "observation route-cell identity differs",
            )
            observed_identities.append(_observation_identity(observation))
            planes = observation["planes"]
            assert isinstance(planes, dict)
            coordinate_spec = coordinate[coordinate_id]
            anisotropy_spec = anisotropy[anisotropy_id]
            _validate_plane(
                planes["y"],
                expected_policy=str(coordinate_spec["luma_coordinate_policy"]),
                expected_anisotropy=int(anisotropy_spec["luma_anisotropy_strength_q12"]),
            )
            for channel in ("cb", "cr"):
                _validate_plane(
                    planes[channel],
                    expected_policy=str(coordinate_spec["chroma_coordinate_policy"]),
                    expected_anisotropy=int(anisotropy_spec["chroma_anisotropy_strength_q12"]),
                )
            _semantic(
                planes["cb"]["sample_count"] == planes["cr"]["sample_count"],
                "chroma plane sample counts differ",
            )
            _validate_metric_rows(observation)
            native_record = _native_record_for_observation(
                observation,
                records=native_records,
            )
            native_diagnostic = native_diagnostics[
                str(native_record["native_record_sha256"])
            ]
            native_cells = native_diagnostic.get("cells")
            _semantic(isinstance(native_cells, list), "embedded native cells are absent")
            native_cell = next(
                (
                    row
                    for row in native_cells
                    if isinstance(row, dict)
                    and row.get("block_id") == expected_id
                ),
                None,
            )
            _semantic(
                isinstance(native_cell, dict)
                and observation.get("candidate_output_nv12_sha256")
                == native_cell.get("output_nv12_sha256")
                and observation.get("candidate_output_frame_sha256")
                == native_cell.get("output_frame_sha256")
                and {
                    channel: {
                        key: value
                        for key, value in observation["planes"][channel].items()
                        if key != "plane_evidence_sha256"
                    }
                    for channel in ("y", "cb", "cr")
                }
                == native_cell.get("planes"),
                "coordinate observation differs from its embedded native cell",
            )
            _self_hash(observation, "observation_sha256")
        _semantic(
            len(observed_identities) == len(set(observed_identities)),
            "route-cell observation identity repeats",
        )
        _semantic(
            [row.get("native_record_sha256") for row in observations]
            == native_hashes_by_route[route],
            "route-cell native identity set or order differs",
        )
        frozen = tuple(observed_identities)
        if route in identities_by_route:
            _semantic(
                frozen == identities_by_route[route],
                "route observation order differs between cells",
            )
        else:
            identities_by_route[route] = frozen
        _self_hash(block, "block_sha256")
        _semantic(
            block.get("native_execution_sha256")
            == canonical_sha256(
                [row["native_record_sha256"] for row in observations]
            ),
            "route-cell native execution manifest hash differs",
        )
        block_by_id[expected_id] = block
    _semantic(len(block_by_id) == 32, "route-cell block IDs repeat")
    _semantic(
        all(
            tuple(reference_identities_by_route[route])
            == identities_by_route.get(route)
            for route in ROUTES
        ),
        "production-V2 reference observation order differs from cell blocks",
    )

    compositions = document["full_corpus_compositions"]
    assert isinstance(compositions, list)
    _semantic(len(compositions) == len(COMPOSITION_SPECS) == 31, "composition count differs")
    for ordinal, (composition, spec) in enumerate(zip(compositions, COMPOSITION_SPECS)):
        assert isinstance(composition, dict)
        composition_id, direct2_id, direct3_id = spec
        _semantic(
            composition.get("ordinal") == ordinal
            and composition.get("composition_id") == composition_id
            and composition.get("direct_2x_block_id") == direct2_id
            and composition.get("direct_3_over_2_block_id") == direct3_id,
            "full-corpus composition identity or order differs",
        )
        _semantic(
            composition.get("direct_2x_block_sha256") == block_by_id[direct2_id]["block_sha256"]
            and composition.get("direct_3_over_2_block_sha256") == block_by_id[direct3_id]["block_sha256"],
            "composition route-block hash differs",
        )
        _self_hash(composition, "composition_sha256")
    _semantic(
        len({row["composition_id"] for row in compositions}) == 31,
        "composition identity repeats",
    )
    _self_hash(document, "artifact_sha256")
    return json.loads(canonical_json_bytes(document))


def _risk_cell_id(weight_index: int, band_index: int) -> str:
    return f"weight-{weight_index:02d}-band-{band_index:02d}"


def validate_risk_state_artifact(
    document: Mapping[str, object],
) -> Mapping[str, object]:
    """Validate one complete, unselected, open-development risk diagnostic."""

    _schema(document, _RISK_SCHEMA)
    bindings = document["input_bindings"]
    assert isinstance(bindings, dict)
    _validate_live_holdout_guard_binding(bindings)
    native_records, native_diagnostics = _validate_native_records(document)
    native_record_sequence = document["native_records"]
    assert isinstance(native_record_sequence, list)
    _validate_completed_execution_evidence(
        bindings,
        expected_input_stub_names={
            f"{record['input_nv12_sha256']}.nv12"
            for record in native_records.values()
        },
        native_record_sequence=native_record_sequence,
    )
    expected_counts = {"direct_2x": 12, "direct_3_over_2": 6}
    _semantic(
        bindings.get("expected_observation_count_by_route") == expected_counts,
        "risk expected route observation counts differ",
    )
    native_hash_sequence = [
        row["native_record_sha256"]
        for row in native_record_sequence
        if isinstance(row, dict)
    ]
    _semantic(
        len(native_hash_sequence) == 18
        and all(
            sum(
                1
                for row in native_record_sequence
                if isinstance(row, dict) and row.get("target_route") == route
            )
            == expected_counts[route]
            for route in ROUTES
        ),
        "risk native record route counts differ",
    )
    _semantic(
        bindings.get("analysis_grid_hash_contract")
        == "mirmir-ash-analysis-grid-v3-be-v1",
        "risk-state analysis-grid hash contract differs",
    )
    _semantic(
        document.get("dimension_contract") == risk_state_dimension_contract(),
        "risk-state dimension contract differs",
    )
    records = document["frame_route_records"]
    assert isinstance(records, list)
    _semantic(bool(records), "risk-state artifact has no frame-route records")
    observed_record_identities: set[tuple[object, ...]] = set()
    observed_routes: set[str] = set()
    for record_ordinal, record in enumerate(records):
        assert isinstance(record, dict)
        route = str(record["target_route"])
        _semantic(record.get("ordinal") == record_ordinal, "risk frame-route order differs")
        identity = (
            record.get("source_asset_id"),
            record.get("degradation_profile_id"),
            route,
            record.get("input_frame_sha256"),
        )
        _semantic(identity not in observed_record_identities, "risk frame-route identity repeats")
        observed_record_identities.add(identity)
        observed_routes.add(route)
        native_record = native_records.get(
            str(record.get("native_execution_sha256"))
        )
        _semantic(
            native_record is not None
            and native_record.get("source_asset_id")
            == record.get("source_asset_id")
            and native_record.get("degradation_profile_id")
            == record.get("degradation_profile_id")
            and native_record.get("target_route") == route
            and native_record.get("input_frame_sha256")
            == record.get("input_frame_sha256"),
            "risk frame-route native record differs",
        )
        assert native_record is not None
        native_diagnostic = native_diagnostics[
            str(native_record["native_record_sha256"])
        ]
        native_risk = native_diagnostic.get("risk_state")
        _semantic(
            isinstance(native_risk, dict)
            and record.get("analysis_grid_source_step")
            == native_risk.get("analysis_grid_source_step")
            and record.get("analysis_cell_count")
            == native_risk.get("analysis_cell_count")
            and record.get("baseline_analysis_grid_sha256")
            == native_risk.get("baseline_analysis_grid_sha256"),
            "risk frame-route grid differs from embedded native record",
        )
        analysis_count = record["analysis_cell_count"]
        cells = record["cells"]
        assert isinstance(analysis_count, int) and isinstance(cells, list)
        _semantic(len(cells) == 30, "risk cell count differs")
        for ordinal, cell in enumerate(cells):
            assert isinstance(cell, dict)
            weight_index = ordinal // len(RISK_THRESHOLD_BANDS)
            band_index = ordinal % len(RISK_THRESHOLD_BANDS)
            weight = RISK_WEIGHT_PAIRS[weight_index]
            band = RISK_THRESHOLD_BANDS[band_index]
            _semantic(
                cell.get("ordinal") == ordinal
                and cell.get("cell_id") == _risk_cell_id(weight_index, band_index)
                and cell.get("risk_weight_pair") == weight
                and cell.get("risk_threshold_band") == band,
                "risk cell identity or order differs",
            )
            zero = cell["risk_zero_count"]
            one = cell["risk_one_count"]
            _semantic(zero + one == analysis_count, "risk activation counts do not cover the grid")
            _semantic(
                cell["risk_proxy_value_count"] == analysis_count,
                "risk proxy value count differs from the grid",
            )
            _semantic(
                cell["risk_proxy_minimum_unorm15"]
                <= cell["risk_proxy_maximum_unorm15"],
                "risk proxy extrema are reversed",
            )
            _self_hash(cell, "cell_sha256")
        _semantic(
            [
                {
                    key: value
                    for key, value in cell.items()
                    if key != "cell_sha256"
                }
                for cell in cells
            ]
            == native_risk.get("cells"),
            "risk cells differ from embedded native record",
        )
        _self_hash(record, "frame_route_record_sha256")
    _semantic(observed_routes == set(ROUTES), "risk records do not cover both routes")
    _semantic(
        len(records) == 18
        and [row.get("native_execution_sha256") for row in records]
        == native_hash_sequence,
        "risk native identity set or order differs",
    )
    _self_hash(document, "artifact_sha256")
    return json.loads(canonical_json_bytes(document))


def _strict_artifact_payload(payload: bytes, label: str) -> Mapping[str, object]:
    duplicate = False

    def object_pairs(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
        nonlocal duplicate
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                duplicate = True
            result[key] = value
        return result

    def reject_nonstandard_constant(value: str) -> object:
        raise ValueError(f"nonstandard JSON constant: {value}")

    try:
        document = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_nonstandard_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise CorrectiveDiagnosticContractError(f"{label} file is not strict JSON") from error
    _semantic(not duplicate, f"{label} file repeats a JSON key")
    _semantic(isinstance(document, dict), f"{label} file root is not an object")
    _semantic(
        payload == canonical_artifact_file_bytes(document),
        f"{label} file is not canonical compact sorted JSON plus LF",
    )
    return document


def validate_corrective_diagnostic_envelope(
    document: Mapping[str, object],
    *,
    coordinate_artifact_payload: bytes,
    risk_state_artifact_payload: bytes,
) -> Mapping[str, object]:
    """Validate an envelope and reopen both canonical sibling artifact files."""

    _schema(document, _ENVELOPE_SCHEMA)
    coordinate = _strict_artifact_payload(
        coordinate_artifact_payload,
        "coordinate-anisotropy artifact",
    )
    risk = _strict_artifact_payload(risk_state_artifact_payload, "risk-state artifact")
    validate_coordinate_anisotropy_artifact(coordinate)
    validate_risk_state_artifact(risk)
    coordinate_bindings = coordinate["input_bindings"]
    risk_bindings = risk["input_bindings"]
    assert isinstance(coordinate_bindings, dict) and isinstance(risk_bindings, dict)
    shared_binding_fields = (
        "base_candidate_vector_sha256",
        "base_adapter_configuration_sha256",
        "compiler_inputs_sha256",
        "native_configuration_provenance",
        "mapping_sha256",
        "coordinate_model_contract_file_sha256",
        "coordinate_oracle_matrix_sha256",
        "coordinate_experiment_dimensions_sha256",
        "video_profile_contract_file_sha256",
        "video_profile_contract_sha256",
        "quality_harness_implementation_manifest_file_sha256",
        "quality_harness_implementation_manifest_sha256",
        "g04_lock_file_sha256",
        "g05_lock_file_sha256",
        "corrective_preregistration_file_sha256",
        "corrective_preregistration_sha256",
        "native_executable_sha256",
        "native_source_manifest_sha256",
        "development_sample_lock_file_sha256",
        "development_sample_lock_manifest_sha256",
        "expected_observation_count_by_route",
        "development_sample_dimension_sha256",
        "degradation_profile_dimension_sha256",
        "corpus_lock_bundle_sha256",
        "live_holdout_preopen_verification",
        "live_holdout_preopen_verification_sha256",
        "degradation_policy_sha256",
        "analysis_grid_hash_contract",
        "completed_execution_evidence",
    )
    _semantic(
        all(
            coordinate_bindings.get(field) == risk_bindings.get(field)
            for field in shared_binding_fields
        ),
        "corrective diagnostic sibling input bindings differ",
    )
    _semantic(
        coordinate.get("native_records") == risk.get("native_records"),
        "corrective diagnostic sibling native records differ",
    )
    _semantic(
        document.get("coordinate_anisotropy_artifact")
        == artifact_file_binding(coordinate),
        "coordinate-anisotropy sibling binding differs",
    )
    _semantic(
        document.get("risk_state_artifact") == artifact_file_binding(risk),
        "risk-state sibling binding differs",
    )
    _self_hash(document, "envelope_sha256")
    return json.loads(canonical_json_bytes(document))


__all__ = [
    "ANISOTROPY_CELLS",
    "COMPOSITION_SPECS",
    "COORDINATE_CELLS",
    "CONTRACT_ROUTE_BY_EVALUATOR_ROUTE",
    "CorrectiveDiagnosticContractError",
    "EVALUATOR_ROUTE_BY_CONTRACT_ROUTE",
    "RISK_THRESHOLD_BANDS",
    "RISK_WEIGHT_PAIRS",
    "ROUTES",
    "ROUTE_BLOCK_SPECS",
    "artifact_file_binding",
    "canonical_artifact_file_bytes",
    "coordinate_anisotropy_dimension_contract",
    "contract_route_for_evaluator_route",
    "evaluator_route_for_contract_route",
    "risk_state_dimension_contract",
    "validate_coordinate_anisotropy_artifact",
    "validate_corrective_diagnostic_envelope",
    "validate_risk_state_artifact",
]
