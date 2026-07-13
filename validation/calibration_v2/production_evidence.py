"""Formula-derived P06 candidate checks, performance, and dispatch evidence."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
from typing import Dict, List, Mapping, Sequence, Tuple

import numpy as np

from validation.calibration_v2.production_evaluator import (
    EvidenceStore,
    FIXED_DESCRIPTOR_IDS,
    ROUTES,
    SCHEMAS_ROOT,
    ControlSelectionBundle,
    ProductionEvaluatorError,
)
from validation.calibration_v2.release_lock import (
    dispatch_measurement_document,
    validate_dispatch_measurement_document,
)
from validation.quality.src.mirmir_quality.arrays import frame_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.production_dry_run import CandidateAdapter


ROUTE_PHASE_PAIR_COUNTS = {
    "direct-2x": 4,
    "direct-3over2": 9,
}


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _finite(value: object, label: str) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
    ):
        raise ProductionEvaluatorError(f"{label} is not finite")
    return float(value)


def _validated_control_records(
    records: Sequence[Mapping[str, object]],
) -> List[Mapping[str, object]]:
    validated = []
    for record in records:
        copied = dict(record)
        declared = copied.pop("record_sha256", None)
        if declared != canonical_sha256(copied):
            raise ProductionEvaluatorError(
                "native control record self-hash is invalid"
            )
        validated.append(record)
    return validated


def _candidate_cases(
    corpus_rows: Sequence[Mapping[str, object]],
    fixture_rows: Sequence[Mapping[str, object]],
) -> List[Mapping[str, object]]:
    natural = [
        {
            "witness_scope": "natural",
            "source_or_fixture_id": row["source_asset_id"],
            "degradation_profile_id": row["degradation_profile_id"],
            "target_route": row["target_route"],
            "input_frame_sha256": row["degraded_input_frame_sha256"],
        }
        for row in corpus_rows
        if row.get("comparison_domain") == "engine_raw"
    ]
    analytic = [
        {
            "witness_scope": "analytic",
            "source_or_fixture_id": row["fixture_id"],
            "degradation_profile_id": None,
            "target_route": row["target_route"],
            "input_frame_sha256": row["input_frame_sha256"],
        }
        for row in fixture_rows
        if row.get("comparison_domain") == "engine_raw"
    ]
    cases = natural + analytic
    identities = [
        (
            case["witness_scope"],
            case["source_or_fixture_id"],
            case["degradation_profile_id"],
            case["target_route"],
            case["input_frame_sha256"],
        )
        for case in cases
    ]
    if not cases or len(identities) != len(set(identities)):
        raise ProductionEvaluatorError(
            "candidate check scope is empty or repeats a case"
        )
    return cases


def _operator_distinctness(
    *,
    cases: Sequence[Mapping[str, object]],
    control_records: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    outputs: Dict[Tuple[str, str, int], str] = {}
    for record in control_records:
        if record.get("control_mode") != "fixed_descriptor_uniform":
            continue
        parameters = record.get("parameters")
        descriptor = (
            parameters.get("descriptor_id")
            if isinstance(parameters, dict)
            else None
        )
        if (
            not isinstance(descriptor, int)
            or isinstance(descriptor, bool)
            or descriptor not in FIXED_DESCRIPTOR_IDS
        ):
            raise ProductionEvaluatorError(
                "fixed control record has an invalid descriptor"
            )
        key = (
            str(record["input_frame_sha256"]),
            str(record["target_route"]),
            descriptor,
        )
        output = str(record["output_frame_sha256"])
        if key in outputs and outputs[key] != output:
            raise ProductionEvaluatorError(
                "fixed descriptor changed for identical input bytes"
            )
        outputs[key] = output

    for case in cases:
        missing = [
            descriptor
            for descriptor in FIXED_DESCRIPTOR_IDS
            if (
                str(case["input_frame_sha256"]),
                str(case["target_route"]),
                descriptor,
            )
            not in outputs
        ]
        if missing:
            raise ProductionEvaluatorError(
                "operator witness scope lacks exhaustive fixed outputs"
            )

    witnesses = []
    for first in FIXED_DESCRIPTOR_IDS:
        for second in range(first + 1, 16):
            witness = None
            for case in cases:
                prefix = (
                    str(case["input_frame_sha256"]),
                    str(case["target_route"]),
                )
                first_output = outputs[(*prefix, first)]
                second_output = outputs[(*prefix, second)]
                if first_output != second_output:
                    witness = {
                        "first_descriptor_id": first,
                        "second_descriptor_id": second,
                        **dict(case),
                        "first_output_frame_sha256": first_output,
                        "second_output_frame_sha256": second_output,
                    }
                    break
            if witness is None:
                raise ProductionEvaluatorError(
                    "one fixed-descriptor pair has no locked-scope witness"
                )
            witnesses.append(witness)
    if len(witnesses) != 120:
        raise ProductionEvaluatorError(
            "fixed-descriptor witness count differs from 120"
        )
    return {
        "descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
        "witness_scope_case_count": len(cases),
        "pair_witnesses": witnesses,
    }


def _route_quality(
    *,
    corpus_rows: Sequence[Mapping[str, object]],
    fixture_rows: Sequence[Mapping[str, object]],
    tolerances: Mapping[str, object],
) -> Tuple[Mapping[str, object], bool]:
    quality = tolerances["quality"]
    routes = []
    route_pass = True
    for route in ROUTES:
        raw_natural = [
            row
            for row in corpus_rows
            if row.get("target_route") == route
            and row.get("comparison_domain") == "engine_raw"
        ]
        per_source_values: Dict[str, List[float]] = {}
        for row in raw_natural:
            metrics = row["metrics_by_control"]
            candidate = _finite(
                metrics["full_ash"]["y_psnr_db"],
                "candidate route Y PSNR",
            )
            conventional = _finite(
                metrics["conventional"]["y_psnr_db"],
                "conventional route Y PSNR",
            )
            per_source_values.setdefault(str(row["source_asset_id"]), []).append(
                candidate - conventional
            )
        if not per_source_values or any(
            len(values) != 3 for values in per_source_values.values()
        ):
            raise ProductionEvaluatorError(
                "route quality lacks three profiles per source"
            )
        per_source = [
            {
                "source_asset_id": source_id,
                "delta_db": float(np.mean(values, dtype=np.float64)),
            }
            for source_id, values in per_source_values.items()
        ]
        raw_fixtures = [
            row
            for row in fixture_rows
            if row.get("target_route") == route
            and row.get("comparison_domain") == "engine_raw"
        ]
        ringing: List[float] = []
        ringing_increase: List[float] = []
        alias: List[float] = []
        alias_increase: List[float] = []
        chroma: List[float] = []
        chroma_increase: List[float] = []
        for row in raw_fixtures:
            candidate = row["metrics_by_control"]["full_ash"]
            conventional = row["metrics_by_control"]["conventional"]
            if row["fixture_kind"] == "ringing":
                candidate_value = max(
                    _finite(candidate["ringing_overshoot"], "ringing overshoot"),
                    _finite(candidate["ringing_undershoot"], "ringing undershoot"),
                )
                conventional_value = max(
                    _finite(
                        conventional["ringing_overshoot"],
                        "conventional ringing overshoot",
                    ),
                    _finite(
                        conventional["ringing_undershoot"],
                        "conventional ringing undershoot",
                    ),
                )
                ringing.append(candidate_value)
                ringing_increase.append(candidate_value - conventional_value)
            elif row["fixture_kind"] == "alias":
                candidate_value = _finite(
                    candidate["alias_forbidden_band_ratio"],
                    "alias ratio",
                )
                conventional_value = _finite(
                    conventional["alias_forbidden_band_ratio"],
                    "conventional alias ratio",
                )
                alias.append(candidate_value)
                alias_increase.append(candidate_value - conventional_value)
            elif row["fixture_kind"] == "chroma_displacement":
                candidate_value = _finite(
                    candidate["chroma_displacement_pixels"],
                    "chroma displacement",
                )
                conventional_value = _finite(
                    conventional["chroma_displacement_pixels"],
                    "conventional chroma displacement",
                )
                chroma.append(candidate_value)
                chroma_increase.append(candidate_value - conventional_value)
        if not all(
            (
                ringing,
                ringing_increase,
                alias,
                alias_increase,
                chroma,
                chroma_increase,
            )
        ):
            raise ProductionEvaluatorError(
                "route quality analytic coverage is incomplete"
            )
        record = {
            "target_route": route,
            "natural_domain_row_counts": {
                domain: sum(
                    1
                    for row in corpus_rows
                    if row.get("target_route") == route
                    and row.get("comparison_domain") == domain
                )
                for domain in ("engine_raw", "container_decoded")
            },
            "analytic_domain_row_counts": {
                domain: sum(
                    1
                    for row in fixture_rows
                    if row.get("target_route") == route
                    and row.get("comparison_domain") == domain
                )
                for domain in ("engine_raw", "container_decoded")
            },
            "per_source_engine_raw_y_psnr_delta_vs_conventional": per_source,
            "maximum_ringing_excursion": max(ringing),
            "maximum_ringing_increase": max(ringing_increase),
            "maximum_alias_ratio": max(alias),
            "maximum_alias_increase": max(alias_increase),
            "maximum_chroma_displacement_pixels": max(chroma),
            "maximum_chroma_displacement_increase_pixels": max(chroma_increase),
        }
        routes.append(record)
        route_pass = route_pass and (
            all(value > 0 for value in record["natural_domain_row_counts"].values())
            and all(value > 0 for value in record["analytic_domain_row_counts"].values())
            and all(
                row["delta_db"]
                >= quality["severe_regression"][
                    "per_asset_y_psnr_delta_db_minimum"
                ]
                for row in per_source
            )
            and record["maximum_ringing_excursion"]
            <= quality["ringing"]["absolute_overshoot_maximum"]
            and record["maximum_ringing_excursion"]
            <= quality["ringing"]["absolute_undershoot_magnitude_maximum"]
            and record["maximum_ringing_increase"]
            <= quality["ringing"]["increase_over_best_conventional_maximum"]
            and record["maximum_alias_ratio"]
            <= quality["alias"]["forbidden_band_energy_ratio_maximum"]
            and record["maximum_alias_increase"]
            <= quality["alias"]["increase_over_best_conventional_maximum"]
            and record["maximum_chroma_displacement_pixels"]
            <= quality["chroma_displacement"]["absolute_pixels_maximum"]
            and record["maximum_chroma_displacement_increase_pixels"]
            <= quality["chroma_displacement"][
                "increase_over_best_conventional_pixels_maximum"
            ]
        )
    return {"routes": routes}, route_pass


class PolicyEvaluationEvidenceProvider:
    """Derive every candidate predicate from native and metric evidence."""

    def __init__(
        self,
        *,
        metric_performance_tolerances: Mapping[str, object],
        measurement_evidence_root: Path,
        evidence_store: EvidenceStore,
    ) -> None:
        validate_schema(
            metric_performance_tolerances,
            SCHEMAS_ROOT / "metric-performance-tolerances-v1.schema.json",
        )
        self._tolerances = json.loads(
            canonical_json_bytes(metric_performance_tolerances)
        )
        self._measurement_root = measurement_evidence_root.resolve()
        self._measurement_root.mkdir(parents=True, exist_ok=True)
        self._evidence_store = evidence_store

    def _cache_proof_binding(
        self,
        *,
        proof_kind: str,
        records: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        if proof_kind not in {"fixed", "non_ash", "control"}:
            raise ProductionEvaluatorError("native cache proof kind is invalid")
        if not isinstance(records, (list, tuple)) or any(
            not isinstance(record, dict) for record in records
        ):
            raise ProductionEvaluatorError(
                f"native {proof_kind} cache proof stream is invalid"
            )
        copied = [dict(record) for record in records]
        hashes = []
        for record in copied:
            unhashed = dict(record)
            declared = unhashed.pop("record_sha256", None)
            if declared != canonical_sha256(unhashed):
                raise ProductionEvaluatorError(
                    f"native {proof_kind} cache proof self-hash is invalid"
                )
            hashes.append(str(declared))
        document = {
            "schema_version": "1.0.0",
            "artifact_kind": (
                "p06_native_cache_reconstruction_proof_manifest"
            ),
            "proof_kind": proof_kind,
            "records": copied,
        }
        binding = self._evidence_store.publish(document)
        digest = str(binding.get("sha256"))
        size_bytes = binding.get("size_bytes")
        if (
            digest != canonical_sha256(document)
            or not isinstance(size_bytes, int)
            or isinstance(size_bytes, bool)
            or size_bytes != len(canonical_json_bytes(document))
            or self._evidence_store.reopen(digest) != document
        ):
            raise ProductionEvaluatorError(
                f"native {proof_kind} cache proof failed content-address reopen"
            )
        return {
            "artifact_sha256": digest,
            "size_bytes": size_bytes,
            "record_count": len(copied),
            "ordered_record_sha256_values": hashes,
        }

    def _output_cache_evidence(
        self,
        *,
        adapter: CandidateAdapter,
        native_control_records: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        provider = getattr(
            adapter.callable,
            "non_ash_cache_preparation_records",
            None,
        )
        if not callable(provider):
            raise ProductionEvaluatorError(
                "native cache preparation evidence provider is absent"
            )
        records = provider()
        if not isinstance(records, (list, tuple)) or any(
            not isinstance(record, dict) for record in records
        ):
            raise ProductionEvaluatorError(
                "native cache preparation evidence stream is invalid"
            )
        preparation = [dict(record) for record in records]
        for record in preparation:
            unhashed = dict(record)
            declared = unhashed.pop("record_sha256", None)
            if declared != canonical_sha256(unhashed):
                raise ProductionEvaluatorError(
                    "native cache preparation evidence self-hash is invalid"
                )
        fixed_provider = getattr(adapter.callable, "fixed_cache_records", None)
        non_ash_provider = getattr(
            adapter.callable,
            "non_ash_cache_records",
            None,
        )
        if not callable(fixed_provider) or not callable(non_ash_provider):
            raise ProductionEvaluatorError(
                "native cache reconstruction evidence provider is absent"
            )
        fixed_records = fixed_provider()
        non_ash_records = non_ash_provider()
        cache_decoration_fields = {
            "control_cache_reused",
            "control_cache_origin_manifest_sha256",
            "control_cache_origin_proof_sha256",
            "current_call_analysis_grid_invocation_count",
            "current_call_spatial_operator_evaluation_count",
        }
        decorated_control_records = []
        for record in native_control_records:
            present = cache_decoration_fields.intersection(record)
            if present and present != cache_decoration_fields:
                raise ProductionEvaluatorError(
                    "native control cache evidence decoration is incomplete"
                )
            if present:
                decorated_control_records.append(record)
        return {
            "preparation_records": preparation,
            "preparation_records_sha256": canonical_sha256(preparation),
            "fixed_reconstruction_proof": self._cache_proof_binding(
                proof_kind="fixed",
                records=fixed_records,
            ),
            "non_ash_reconstruction_proof": self._cache_proof_binding(
                proof_kind="non_ash",
                records=non_ash_records,
            ),
            "control_reconstruction_proof": self._cache_proof_binding(
                proof_kind="control",
                records=decorated_control_records,
            ),
        }

    @staticmethod
    def _source_bindings(
        policy: Mapping[str, object],
        bindings: Sequence[Tuple[str, str]],
    ) -> List[Mapping[str, object]]:
        sources = policy.get("source_evidence")
        if not isinstance(sources, dict):
            raise ProductionEvaluatorError(
                "candidate evidence policy source table is absent"
            )
        expected_ids = list(sources)
        observed = list(bindings)
        if (
            [identifier for identifier, _ in observed] != expected_ids
            or any(not _is_sha256(digest) for _, digest in observed)
        ):
            raise ProductionEvaluatorError(
                "candidate evidence source bindings are incomplete or reordered"
            )
        return [
            {"id": identifier, "sha256": digest}
            for identifier, digest in observed
        ]

    @staticmethod
    def _compiler_evidence(adapter: CandidateAdapter) -> Mapping[str, object]:
        provider = getattr(adapter.callable, "candidate_compiler_evidence", None)
        if not callable(provider):
            raise ProductionEvaluatorError(
                "native candidate compiler evidence provider is absent"
            )
        evidence = provider()
        if not isinstance(evidence, dict):
            raise ProductionEvaluatorError(
                "native candidate compiler evidence is invalid"
            )
        unhashed = dict(evidence)
        declared = unhashed.pop("evidence_sha256", None)
        if (
            declared != canonical_sha256(unhashed)
            or evidence.get("candidate_vector_sha256")
            != adapter.configuration.get("serialized_candidate_vector_sha256")
            or evidence.get("candidate_lut_runtime_manifest_sha256")
            != adapter.configuration.get("candidate_lut_runtime_manifest_sha256")
            or evidence.get("maximum_operator_evaluations") not in {1, 2}
            or evidence.get("holdout_accessed") is not False
        ):
            raise ProductionEvaluatorError(
                "native candidate compiler evidence is stale or incomplete"
            )
        routes = evidence.get("routes")
        if (
            not isinstance(routes, list)
            or [record.get("target_route") for record in routes] != list(ROUTES)
        ):
            raise ProductionEvaluatorError(
                "native compiler route evidence order differs"
            )
        return evidence

    def _state_and_grid(
        self,
        *,
        cases: Sequence[Mapping[str, object]],
        corpus_rows: Sequence[Mapping[str, object]],
        fixture_rows: Sequence[Mapping[str, object]],
        compiler_evidence: Mapping[str, object],
        control_records: Sequence[Mapping[str, object]],
    ) -> Tuple[
        Mapping[str, object],
        Mapping[str, object],
        int,
        bool,
        bool,
        bool,
        Mapping[str, object],
    ]:
        full_records: Dict[Tuple[str, str], List[Mapping[str, object]]] = {}
        control_maximum = 0
        for record in control_records:
            if record.get("control_mode") not in {"full_ash", "state_only"}:
                continue
            summary = record.get("locked_runtime_summary")
            if not isinstance(summary, dict):
                raise ProductionEvaluatorError(
                    "full/state native record lacks a runtime summary"
                )
            maximum = int(summary.get("maximum_operator_evaluations", 0))
            if maximum not in {1, 2}:
                raise ProductionEvaluatorError(
                    "control maximum operator evaluations is invalid"
                )
            control_maximum = max(control_maximum, maximum)
            if record.get("control_mode") == "full_ash":
                key = (
                    str(record["input_frame_sha256"]),
                    str(record["target_route"]),
                )
                full_records.setdefault(key, []).append(record)

        invocations = []
        route_histograms: Dict[str, Dict[int, int]] = {
            route: {} for route in ROUTES
        }
        for case in cases:
            key = (
                str(case["input_frame_sha256"]),
                str(case["target_route"]),
            )
            matches = full_records.get(key)
            if not matches:
                raise ProductionEvaluatorError(
                    "candidate checks lack one full-ASH record"
                )
            record = matches.pop(0)
            summary = record["locked_runtime_summary"]
            analysis_count = int(summary.get("analysis_cell_count", 0))
            occupied_count = int(
                summary.get("occupied_analysis_cell_count", -1)
            )
            dispatch_count = int(summary.get("dispatch_record_count", 0))
            route = str(case["target_route"])
            phase_pair_count = ROUTE_PHASE_PAIR_COUNTS[route]
            if (
                analysis_count <= 0
                or not 0 <= occupied_count <= analysis_count
                or dispatch_count != analysis_count * phase_pair_count
            ):
                raise ProductionEvaluatorError(
                    "analysis-grid occupancy or phase cardinality is invalid"
                )
            invocations.append(
                {
                    "scope": case["witness_scope"],
                    "source_or_fixture_id": case["source_or_fixture_id"],
                    "degradation_profile_id": case["degradation_profile_id"],
                    "target_route": case["target_route"],
                    "input_frame_sha256": case["input_frame_sha256"],
                    "analysis_cell_count": analysis_count,
                    "occupied_analysis_cell_count": occupied_count,
                    "dispatch_record_count": dispatch_count,
                }
            )
            histogram = route_histograms[str(case["target_route"])]
            rows = summary.get("state_histogram")
            if not isinstance(rows, list) or not rows:
                raise ProductionEvaluatorError("native state histogram is absent")
            for row in rows:
                state = int(row["state_raw_value"])
                count = int(row["count"])
                if not 0 <= state <= 511 or count <= 0:
                    raise ProductionEvaluatorError(
                        "native state histogram row is invalid"
                    )
                histogram[state] = histogram.get(state, 0) + count
        if any(records for records in full_records.values()):
            raise ProductionEvaluatorError(
                "full-ASH records exist outside the locked check scope"
            )

        compiler_routes = {
            str(record["target_route"]): record
            for record in compiler_evidence["routes"]
        }
        raw_fixture_rows = [
            row
            for row in fixture_rows
            if row.get("comparison_domain") == "engine_raw"
        ]
        state_routes = []
        state_pass = True
        for route in ROUTES:
            histogram = route_histograms[route]
            histogram_rows = [
                {"state_raw_value": state, "count": histogram[state]}
                for state in sorted(histogram)
            ]
            observations = []
            for coordinate in (1, 2, 3, 4, 5, 6, 8):
                mask = 1 << (9 - coordinate)
                one_count = sum(
                    count for state, count in histogram.items() if state & mask
                )
                observations.append(
                    {
                        "coordinate": coordinate,
                        "zero_count": sum(histogram.values()) - one_count,
                        "one_count": one_count,
                    }
                )
            inactive_one_count = sum(
                count for state, count in histogram.items() if state & (1 << 2)
            )
            invalid_parity_count = sum(
                count
                for state, count in histogram.items()
                if (state & 1) != (bin(state >> 1).count("1") & 1)
            )
            ablation = next(
                (
                    {
                        "fixture_id": row["fixture_id"],
                        "full_output_frame_sha256": row[
                            "control_output_sha256_values"
                        ]["full_ash"],
                        "state_only_output_frame_sha256": row[
                            "control_output_sha256_values"
                        ]["state_only"],
                    }
                    for row in raw_fixture_rows
                    if row["target_route"] == route
                    and row["control_output_sha256_values"]["full_ash"]
                    != row["control_output_sha256_values"]["state_only"]
                ),
                None,
            )
            if ablation is None:
                raise ProductionEvaluatorError(
                    "state causality lacks an analytic ablation witness"
                )
            conditioning = compiler_routes[route].get(
                "state_conditioning_evidence"
            )
            if not isinstance(conditioning, dict):
                raise ProductionEvaluatorError(
                    "compiler state-conditioning evidence is absent"
                )
            sensitivity = conditioning.get("coordinate_sensitivity")
            if not isinstance(sensitivity, list):
                raise ProductionEvaluatorError(
                    "compiler coordinate sensitivity is absent"
                )
            state_routes.append(
                {
                    "target_route": route,
                    "aggregated_state_histogram": histogram_rows,
                    "active_coordinate_observations": observations,
                    "inactive_coordinate_7_one_count": inactive_one_count,
                    "invalid_coordinate_9_parity_count": invalid_parity_count,
                    "compiler_coordinate_sensitivity": sensitivity,
                    "analytic_ablation_witness": ablation,
                }
            )
            state_pass = state_pass and (
                all(
                    row["zero_count"] > 0 and row["one_count"] > 0
                    for row in observations
                )
                and inactive_one_count == 0
                and invalid_parity_count == 0
                and all(
                    int(row["differing_dispatch_pair_count"]) > 0
                    for row in sensitivity
                )
            )

        route_occupancy = {}
        for route in ROUTES:
            route_rows = [
                row for row in invocations if row["target_route"] == route
            ]
            route_occupancy[route] = {
                "occupied_cells": sum(
                    int(row["occupied_analysis_cell_count"])
                    for row in route_rows
                ),
                "total_cells": sum(
                    int(row["analysis_cell_count"]) for row in route_rows
                ),
            }
        occupancy_pass = all(
            record["occupied_cells"] > 0
            and record["occupied_cells"] == record["total_cells"]
            for record in route_occupancy.values()
        )
        route_quality, route_quality_pass = _route_quality(
            corpus_rows=corpus_rows,
            fixture_rows=fixture_rows,
            tolerances=self._tolerances,
        )
        grid = {
            "invocations": invocations,
            "route_occupancy": route_occupancy,
            "route_quality": route_quality,
        }
        return (
            {"routes": state_routes},
            grid,
            control_maximum,
            state_pass,
            occupancy_pass,
            route_quality_pass,
            route_occupancy,
        )

    @staticmethod
    def _performance(
        *,
        policy: Mapping[str, object],
        policy_sha256: str,
        source_bindings: Sequence[Mapping[str, object]],
        corpus_rows: Sequence[Mapping[str, object]],
        native_records: Sequence[Mapping[str, object]],
        control_records: Sequence[Mapping[str, object]],
    ) -> Tuple[Mapping[str, object], int]:
        raw_rows = [
            row
            for row in corpus_rows
            if row.get("comparison_domain") == "engine_raw"
        ]
        if len(raw_rows) != len(native_records) or not raw_rows:
            raise ProductionEvaluatorError(
                "performance natural/native row count differs"
            )
        natural = []
        maximum = 0
        for row, native in zip(raw_rows, native_records):
            width = int(native.get("output_width", 0))
            height = int(native.get("output_height", 0))
            pixels = width * height
            cells = int(native.get("analysis_cell_count", 0))
            candidates = int(native.get("maximum_operator_evaluations", 0))
            if (
                row["degraded_input_frame_sha256"]
                != native.get("input_frame_sha256")
                or row["target_route"] != native.get("target_route")
                or pixels <= 0
                or cells <= 0
                or candidates not in {1, 2}
            ):
                raise ProductionEvaluatorError(
                    "natural performance evidence differs from native runtime"
                )
            work = (cells + candidates * pixels) / pixels
            natural.append(
                {
                    "source_asset_id": row["source_asset_id"],
                    "degradation_profile_id": row["degradation_profile_id"],
                    "degradation_profile_sha256": row[
                        "degradation_profile_sha256"
                    ],
                    "target_route": row["target_route"],
                    "input_frame_sha256": row["degraded_input_frame_sha256"],
                    "target_luma_width": width,
                    "target_luma_height": height,
                    "target_luma_pixel_count": pixels,
                    "analysis_cell_count": cells,
                    "maximum_operator_evaluations": candidates,
                    "dispatch_work": work,
                }
            )
            maximum = max(maximum, candidates)

        h07_by_key: Dict[Tuple[str, str], List[Mapping[str, object]]] = {}
        for record in control_records:
            if record.get("control_mode") == "h07_direct2x_then_lanczos3":
                key = (
                    str(record["input_frame_sha256"]),
                    str(record["target_route"]),
                )
                h07_by_key.setdefault(key, []).append(record)
        h07 = []
        for row, native in zip(raw_rows, native_records):
            if row["target_route"] != "direct-3over2":
                continue
            key = (str(row["degraded_input_frame_sha256"]), "direct-3over2")
            matches = h07_by_key.get(key)
            if not matches:
                raise ProductionEvaluatorError(
                    "H07 performance evidence lacks a native control"
                )
            record = matches.pop(0)
            summary = record.get("h07_direct2_runtime_summary")
            if not isinstance(summary, dict):
                raise ProductionEvaluatorError(
                    "H07 native control lacks its direct-2x summary"
                )
            low_width = int(native.get("input_width", 0))
            low_height = int(native.get("input_height", 0))
            intermediate_width = low_width * 2
            intermediate_height = low_height * 2
            target_pixels = int(native.get("output_width", 0)) * int(
                native.get("output_height", 0)
            )
            analysis_cells = int(summary.get("analysis_cell_count", 0))
            intermediate_pixels = intermediate_width * intermediate_height
            if min(low_width, low_height, target_pixels, analysis_cells) <= 0:
                raise ProductionEvaluatorError(
                    "H07 performance dimensions are invalid"
                )
            work = (
                analysis_cells + 2 * intermediate_pixels + 12 * target_pixels
            ) / target_pixels
            h07.append(
                {
                    "source_asset_id": row["source_asset_id"],
                    "degradation_profile_id": row["degradation_profile_id"],
                    "input_frame_sha256": row["degraded_input_frame_sha256"],
                    "low_resolution_luma_width": low_width,
                    "low_resolution_luma_height": low_height,
                    "direct2_analysis_cell_count": analysis_cells,
                    "direct2_intermediate_luma_width": intermediate_width,
                    "direct2_intermediate_luma_height": intermediate_height,
                    "target_luma_pixel_count": target_pixels,
                    "h07_dispatch_work": work,
                }
            )
        if not h07:
            raise ProductionEvaluatorError("H07 performance scope is empty")

        natural_sum = sum(float(row["dispatch_work"]) for row in natural)
        h07_sum = sum(float(row["h07_dispatch_work"]) for row in h07)
        evidence = {
            "candidate_evidence_policy_sha256": policy_sha256,
            "source_sha256_bindings": list(source_bindings),
            "natural_invocations": natural,
            "h07_invocations": h07,
            "arithmetic": {
                "natural_dispatch_work_sum": natural_sum,
                "natural_invocation_count": len(natural),
                "h07_dispatch_work_sum": h07_sum,
                "h07_invocation_count": len(h07),
            },
        }
        estimate = policy.get("performance_estimate")
        if not isinstance(estimate, dict):
            raise ProductionEvaluatorError(
                "candidate performance policy is absent"
            )
        dispatch_cost = natural_sum / len(natural)
        h07_cost = h07_sum / len(h07)
        production_fps = _finite(
            estimate["production_frames_per_second"],
            "production estimate FPS",
        )
        result = {
            "estimate_kind": estimate["estimate_kind"],
            "estimate_method": estimate["estimate_method"],
            "estimate_model": estimate["estimate_model"],
            "estimate_source_artifact_sha256_values": [
                policy_sha256,
                *[record["sha256"] for record in source_bindings],
            ],
            "preregistered_production_estimate_same_machine_speedup": estimate[
                "same_machine_speedup"
            ],
            "preregistered_production_estimate_frames_per_second": production_fps,
            "preregistered_production_estimate_dispatch_cost": dispatch_cost,
            "preregistered_production_estimate_full_frame_cpu_reconstruction_loops": estimate[
                "full_frame_cpu_reconstruction_loops"
            ],
            "preregistered_production_estimate_runtime_leaf_tree_generations_per_frame": estimate[
                "runtime_leaf_tree_generations_per_frame"
            ],
            "preregistered_production_estimate_candidate_evaluations_per_output_cell": estimate[
                "candidate_evaluations_per_output_cell"
            ],
            "preregistered_production_estimate_wait_until_completed_calls": estimate[
                "production_wait_until_completed_calls"
            ],
            "preregistered_production_estimate_avoidable_full_frame_gpu_readbacks_per_frame": estimate[
                "avoidable_full_frame_gpu_readbacks_per_frame"
            ],
            "preregistered_production_estimate_default_in_flight_frames": estimate[
                "default_in_flight_frames"
            ],
            "h07_control_estimate_frames_per_second": (
                production_fps * dispatch_cost / h07_cost
            ),
            "h07_control_estimate_dispatch_cost": h07_cost,
            "calibration_estimate_relative_error": estimate[
                "calibration_estimate_relative_error_bound"
            ],
            "evidence": evidence,
            "evidence_sha256": canonical_sha256(evidence),
        }
        return result, maximum

    def _dispatch(
        self,
        *,
        adapter: CandidateAdapter,
        split: str,
        prepared_cases: Sequence[object],
        dispatch_cost: float,
        selection_bundle: ControlSelectionBundle,
    ) -> Mapping[str, object]:
        if split == "development":
            cost_model_id = "mirmir-p06-static-dispatch-work-v1"
            model_input = {
                "cost_model_id": cost_model_id,
                "candidate_vector_sha256": adapter.configuration[
                    "serialized_candidate_vector_sha256"
                ],
                "shared_bank_configuration_sha256": (
                    selection_bundle.shared_bank_configuration_sha256
                ),
                "estimated_dispatch_cost": dispatch_cost,
            }
            return {
                "evidence_stage": "development_static_model",
                "measurement_method": "deterministic-static-dispatch-cost-model-v1",
                "validation_accessed": False,
                "cost_model_id": cost_model_id,
                "cost_model_input_sha256": canonical_sha256(model_input),
                "estimated_dispatch_cost": dispatch_cost,
            }
        if split != "validation" or len(prepared_cases) != 9:
            raise ProductionEvaluatorError(
                "validation dispatch scope is not exactly nine cases"
            )
        measure = getattr(adapter.callable, "measure_dispatch_projection", None)
        environment_provider = getattr(
            adapter.callable,
            "dispatch_environment",
            None,
        )
        if not callable(measure) or not callable(environment_provider):
            raise ProductionEvaluatorError(
                "native validation dispatch capability is absent"
            )
        raw_samples = []
        expected = []
        for item in prepared_cases:
            public = item.public_evidence()
            low_resolution = item.low_resolution
            context = item.context
            if frame_sha256(low_resolution) != public["input_frame_sha256"]:
                raise ProductionEvaluatorError(
                    "dispatch input differs from prepared evidence"
                )
            raw = measure(
                low_resolution,
                context,
                source_asset_id=str(public["source_asset_id"]),
                degradation_profile_id=str(public["degradation_profile_id"]),
                degradation_profile_sha256=str(
                    public["degradation_profile_sha256"]
                ),
            )
            if not isinstance(raw, dict):
                raise ProductionEvaluatorError(
                    "native dispatch measurement is not an object"
                )
            raw_samples.append(raw)
            expected.append(
                {
                    "source_asset_id": public["source_asset_id"],
                    "target_route": public["target_route"],
                    "degradation_profile_id": public[
                        "degradation_profile_id"
                    ],
                    "degradation_profile_sha256": public[
                        "degradation_profile_sha256"
                    ],
                }
            )
        input_bindings = raw_samples[0].get("input_bindings")
        if not isinstance(input_bindings, dict) or any(
            sample.get("input_bindings") != input_bindings
            for sample in raw_samples
        ):
            raise ProductionEvaluatorError(
                "dispatch input bindings are absent or inconsistent"
            )
        run_id = "p06-dispatch-" + canonical_sha256(
            {
                "candidate_vector_sha256": adapter.configuration[
                    "serialized_candidate_vector_sha256"
                ],
                "input_frame_sha256_values": [
                    sample["input_frame_sha256"] for sample in raw_samples
                ],
            }
        )[:32]
        document = dispatch_measurement_document(
            run_id=run_id,
            environment=environment_provider(),
            input_bindings=input_bindings,
            raw_samples=raw_samples,
            expected_sample_profiles=expected,
        )
        validate_dispatch_measurement_document(document)
        payload = canonical_json_bytes(document)
        file_sha256 = hashlib.sha256(payload).hexdigest()
        artifact_id = f"{file_sha256}.json"
        path = self._measurement_root / artifact_id
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            if path.is_symlink() or path.read_bytes() != payload:
                raise ProductionEvaluatorError(
                    "dispatch measurement artifact changed"
                )
        else:
            try:
                offset = 0
                while offset < len(payload):
                    written = os.write(descriptor, payload[offset:])
                    if written <= 0:
                        raise ProductionEvaluatorError(
                            "dispatch measurement write made no progress"
                        )
                    offset += written
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        if (
            hashlib.sha256(path.read_bytes()).hexdigest() != file_sha256
            or json.loads(path.read_bytes()) != document
        ):
            raise ProductionEvaluatorError(
                "dispatch measurement failed reopen verification"
            )
        binding = {
            "artifact_id": artifact_id,
            "sha256": file_sha256,
            "size_bytes": len(payload),
        }
        return {
            "evidence_stage": "validation_native_measurement",
            "measurement_method": (
                "native-cpu-reference-precomputed-dispatch-control-p95-v1"
            ),
            "shared_bank_configuration_sha256": (
                selection_bundle.shared_bank_configuration_sha256
            ),
            "full_ash_configuration_sha256": adapter.configuration_sha256,
            "measured_validation_p95_percent": document["aggregate"][
                "measured_validation_p95_percent"
            ],
            "measurement_run_ids": [document["run_id"]],
            "measurement_artifact_sha256_values": [file_sha256],
            "measurement_evidence_bindings": [binding],
            "measurement_records": [document],
        }

    def evaluation_evidence(
        self,
        *,
        adapter: CandidateAdapter,
        vector: Mapping[str, object],
        split: str,
        prepared_cases: Sequence[object],
        corpus_asset_results: Sequence[Mapping[str, object]],
        analytic_fixture_results: Sequence[Mapping[str, object]],
        selection_bundle: ControlSelectionBundle,
        comparison_identities: Mapping[str, object],
        candidate_evidence_policy: Mapping[str, object],
        candidate_evidence_policy_sha256: str,
        candidate_evidence_source_sha256_bindings: Sequence[Tuple[str, str]],
        native_runtime_records: Sequence[Mapping[str, object]],
        native_control_records: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        del vector, comparison_identities
        if split not in {"development", "validation"}:
            raise ProductionEvaluatorError(
                "candidate evidence provider received a sealed split"
            )
        if not _is_sha256(candidate_evidence_policy_sha256):
            raise ProductionEvaluatorError(
                "candidate evidence policy hash is invalid"
            )
        sources = self._source_bindings(
            candidate_evidence_policy,
            candidate_evidence_source_sha256_bindings,
        )
        control_records = _validated_control_records(native_control_records)
        compiler = self._compiler_evidence(adapter)
        cases = _candidate_cases(
            corpus_asset_results,
            analytic_fixture_results,
        )
        distinctness = _operator_distinctness(
            cases=cases,
            control_records=control_records,
        )
        (
            state,
            grid,
            control_maximum,
            state_pass,
            occupancy_pass,
            route_quality_pass,
            route_occupancy,
        ) = self._state_and_grid(
            cases=cases,
            corpus_rows=corpus_asset_results,
            fixture_rows=analytic_fixture_results,
            compiler_evidence=compiler,
            control_records=control_records,
        )
        performance, performance_maximum = self._performance(
            policy=candidate_evidence_policy,
            policy_sha256=candidate_evidence_policy_sha256,
            source_bindings=sources,
            corpus_rows=corpus_asset_results,
            native_records=native_runtime_records,
            control_records=control_records,
        )
        compiler_maximum = int(compiler["maximum_operator_evaluations"])
        ordinary_maximum = max(
            (
                int(record.get("maximum_operator_evaluations", 0))
                for record in native_runtime_records
            ),
            default=0,
        )
        estimated_maximum = max(
            compiler_maximum,
            control_maximum,
            performance_maximum,
            ordinary_maximum,
        )
        checks_evidence = {
            "candidate_evidence_policy_sha256": (
                candidate_evidence_policy_sha256
            ),
            "source_sha256_bindings": sources,
            "candidate_compiler_evidence": compiler,
            "operator_distinctness": distinctness,
            "state_causality": state,
            "analysis_grid": grid,
            "output_cache": self._output_cache_evidence(
                adapter=adapter,
                native_control_records=control_records,
            ),
        }
        compiler_invariants = all(
            record.get("runtime_leaf_tree_generations") == 0
            and record.get("runtime_path_generations") == 0
            and record.get("per_frame_lut_load_count") == 0
            and record.get("loaded_lut_instance_count") == 1
            and record.get("route_lut_whole_file_sha256")
            == adapter.configuration["route_luts"][record["target_route"]][
                "whole_file_sha256"
            ]
            for record in native_runtime_records
        ) and estimated_maximum <= 2
        checks = {
            "compiler_invariants": compiler_invariants,
            "operator_distinctness": True,
            "state_causality": state_pass,
            "analysis_grid_route_quality": route_quality_pass,
            "analysis_grid_occupancy": occupancy_pass,
            "estimated_candidate_count_maximum": estimated_maximum,
            "route_occupancy": route_occupancy,
            "evidence": checks_evidence,
            "evidence_sha256": canonical_sha256(checks_evidence),
        }
        dispatch = self._dispatch(
            adapter=adapter,
            split=split,
            prepared_cases=prepared_cases,
            dispatch_cost=float(
                performance[
                    "preregistered_production_estimate_dispatch_cost"
                ]
            ),
            selection_bundle=selection_bundle,
        )
        return {
            "checks": checks,
            "performance": performance,
            "dispatch_measurement": dispatch,
        }


def policy_evaluation_evidence_provider(
    *,
    metric_performance_tolerances: Mapping[str, object],
    measurement_evidence_root: Path,
    evidence_store: EvidenceStore,
) -> PolicyEvaluationEvidenceProvider:
    """Build the formula-derived production evidence provider."""

    return PolicyEvaluationEvidenceProvider(
        metric_performance_tolerances=metric_performance_tolerances,
        measurement_evidence_root=measurement_evidence_root,
        evidence_store=evidence_store,
    )
