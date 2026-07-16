from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from validation.calibration_v2 import runner
from validation.calibration_v2.production_evidence import (
    PolicyEvaluationEvidenceProvider,
)
from validation.calibration_v2.production_evaluator import (
    MemoryEvidenceStore,
    ProductionEvaluatorError,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)
from validation.quality.src.mirmir_quality.production_dry_run import CandidateAdapter


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
ROUTES = ("direct-2x", "direct-3over2")


def _hash(label: str) -> str:
    return canonical_sha256({"label": label})


def _analytic_metrics(kind: str, candidate: bool) -> dict[str, object]:
    values: dict[str, object] = {
        "edge_location_error_pixels": None,
        "ringing_overshoot": None,
        "ringing_undershoot": None,
        "alias_forbidden_band_ratio": None,
        "thin_line_retention_ratio": None,
        "thin_line_false_side_lobe_energy": None,
        "chroma_displacement_pixels": None,
    }
    if kind == "ringing":
        values["ringing_overshoot"] = 0.04 if candidate else 0.035
        values["ringing_undershoot"] = 0.03 if candidate else 0.025
    elif kind == "alias":
        values["alias_forbidden_band_ratio"] = 0.04 if candidate else 0.035
    else:
        values["chroma_displacement_pixels"] = 0.20 if candidate else 0.15
    return values


def _runtime_summary(route: str) -> dict[str, object]:
    states = [
        state
        for state in range(512)
        if not state & (1 << 2)
        and (state & 1) == (bin(state >> 1).count("1") & 1)
    ]
    phase_pair_count = {"direct-2x": 4, "direct-3over2": 9}[route]
    dispatch_count = len(states) * phase_pair_count
    return {
        "state_histogram": [
            {"state_raw_value": state, "count": 1} for state in states
        ],
        "operator_histogram": [
            {"descriptor_id": 0, "count": dispatch_count}
        ],
        "maximum_operator_evaluations": 2,
        "analysis_cell_count": len(states),
        "occupied_analysis_cell_count": len(states),
        "dispatch_record_count": dispatch_count,
        "exact_decode_count": dispatch_count,
        "corrected_decode_count": 0,
        "rejected_decode_count": 0,
    }


def _control_record(**values: object) -> dict[str, object]:
    record = dict(values)
    if record.get("control_mode") == "fixed_descriptor_uniform":
        cache_identity = {
            "control_key": record.get("control_key"),
            "input_frame_sha256": record.get("input_frame_sha256"),
            "target_route": record.get("target_route"),
        }
        record.update(
            {
                "control_cache_reused": True,
                "control_cache_origin_manifest_sha256": canonical_sha256(
                    {"manifest": cache_identity}
                ),
                "control_cache_origin_proof_sha256": canonical_sha256(
                    {"proof": cache_identity}
                ),
                "current_call_analysis_grid_invocation_count": 0,
                "current_call_spatial_operator_evaluation_count": 0,
            }
        )
    record["record_sha256"] = canonical_sha256(record)
    return record


class _Callable:
    def __init__(self, compiler_evidence: dict[str, object]) -> None:
        self._compiler_evidence = compiler_evidence
        self._preparation_records: tuple[object, ...] = ()
        self._control_records: tuple[object, ...] = ()

    def __call__(self, *_args: object, **_kwargs: object) -> object:
        raise AssertionError("the evidence-only test must not reconstruct pixels")

    def candidate_compiler_evidence(self) -> dict[str, object]:
        return json.loads(canonical_json_bytes(self._compiler_evidence))

    def non_ash_cache_preparation_records(self) -> tuple[object, ...]:
        return self._preparation_records

    def set_preparation_records(
        self,
        records: list[dict[str, object]],
    ) -> None:
        self._preparation_records = tuple(
            json.loads(canonical_json_bytes(record)) for record in records
        )

    def fixed_cache_records(self) -> tuple[object, ...]:
        return ()

    def non_ash_cache_records(self) -> tuple[object, ...]:
        return ()

    def control_runtime_records(self) -> tuple[object, ...]:
        return self._control_records

    def set_control_records(
        self,
        records: list[dict[str, object]],
    ) -> None:
        self._control_records = tuple(
            json.loads(canonical_json_bytes(record)) for record in records
        )


class _Bound:
    def __init__(
        self,
        policy: dict[str, object],
        tolerances: dict[str, object],
        policy_sha256: str,
        source_hashes: dict[str, str],
    ) -> None:
        self.documents = {
            "candidate_evidence_policy": policy,
            "metric_performance_tolerances": tolerances,
        }
        self._records = {
            "candidate_evidence_policy": policy_sha256,
            **{
                f"candidate_evidence_source_{identifier}": digest
                for identifier, digest in source_hashes.items()
            },
        }

    def record(self, identifier: str) -> dict[str, str]:
        return {"sha256": self._records[identifier]}


def _compiler_evidence(configuration: dict[str, object]) -> dict[str, object]:
    routes = []
    for route, entry_count in (("direct-2x", 4096), ("direct-3over2", 9216)):
        sensitivity = []
        for coordinate in (1, 2, 3, 4, 5, 6, 8):
            sensitivity.append(
                {
                    "coordinate": coordinate,
                    "parity_valid_pair_count": 1,
                    "differing_dispatch_pair_count": 1,
                    "first_witness": {
                        "phase_index": 0,
                        "first_state_raw": 0,
                        "second_state_raw": 257,
                        "first_logical_index": 0,
                        "second_logical_index": 1,
                        "first_signature_sha256": _hash(
                            f"{route}-{coordinate}-first"
                        ),
                        "second_signature_sha256": _hash(
                            f"{route}-{coordinate}-second"
                        ),
                    },
                }
            )
        route_binding = configuration["route_luts"][route]
        conditioning = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_lut_state_conditioning_evidence",
            "target_route": route,
            "whole_file_sha256": route_binding["whole_file_sha256"],
            "payload_sha256": route_binding["payload_sha256"],
            "entry_count": entry_count,
            "parameter_count": 1,
            "maximum_operator_evaluations": 2,
            "context_zero_non_source_exact_entry_count": 1,
            "active_spatial_coordinates": [1, 2, 3, 4, 5, 6, 8],
            "coordinate_sensitivity": sensitivity,
            "state_conditioned": True,
            "oracle_validation_passed": True,
        }
        routes.append(
            {
                "target_route": route,
                "lut_size_bytes": 1,
                "lut_whole_file_sha256": route_binding["whole_file_sha256"],
                "lut_payload_sha256": route_binding["payload_sha256"],
                "state_conditioning_evidence": conditioning,
                "state_conditioning_evidence_sha256": canonical_sha256(
                    conditioning
                ),
            }
        )
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_native_candidate_compiler_evidence",
        "implementation_role": "production_swift",
        "configuration_id": configuration["configuration_id"],
        "candidate_vector_sha256": configuration[
            "serialized_candidate_vector_sha256"
        ],
        "compiler_inputs_sha256": configuration["compiler_inputs_sha256"],
        "compiler_input_document_file_sha256": canonical_sha256({}),
        "candidate_lut_runtime_manifest_sha256": configuration[
            "candidate_lut_runtime_manifest_sha256"
        ],
        "native_executable_sha256": configuration["swift_cli"][
            "executable_sha256"
        ],
        "native_source_manifest_sha256": configuration["swift_cli"][
            "source_manifest_sha256"
        ],
        "routes": routes,
        "maximum_operator_evaluations": 2,
        "holdout_accessed": False,
    }
    document["evidence_sha256"] = canonical_sha256(document)
    return document


def test_provider_matches_independent_runner_recomputation(tmp_path: Path) -> None:
    tolerances = json.loads(
        (
            CALIBRATION_ROOT
            / "contracts/metric-performance-tolerances-v1.json"
        ).read_text(encoding="utf-8")
    )
    policy = json.loads(
        (CALIBRATION_ROOT / "contracts/candidate-evidence-policy-v1.json").read_text(
            encoding="utf-8"
        )
    )
    policy_sha256 = _hash("candidate-evidence-policy-file")
    source_hashes = {
        identifier: _hash(identifier) for identifier in policy["source_evidence"]
    }
    bank = _hash("bank")
    configuration: dict[str, object] = {
        "configuration_id": "test-configuration",
        "serialized_candidate_vector_sha256": _hash("vector"),
        "compiler_inputs_sha256": _hash("compiler-inputs"),
        "compiler_input_document": {},
        "candidate_lut_runtime_manifest_sha256": _hash("runtime-manifest"),
        "swift_cli": {
            "executable_sha256": _hash("executable"),
            "source_manifest_sha256": _hash("source-manifest"),
        },
        "route_luts": {
            route: {
                "whole_file_sha256": _hash(f"{route}-whole"),
                "payload_sha256": _hash(f"{route}-payload"),
            }
            for route in ROUTES
        },
        "shared_bank_configuration_sha256": bank,
    }
    compiler = _compiler_evidence(configuration)
    callable_ = _Callable(compiler)
    adapter = CandidateAdapter(
        candidate_id="evidence-test",
        configuration=configuration,
        configuration_sha256=canonical_sha256(configuration),
        callable=callable_,
    )

    corpus_rows = []
    native_records = []
    natural_cases = []
    for route_index, route in enumerate(ROUTES):
        source_id = f"source-{route_index}"
        for profile_index in range(3):
            profile_id = f"profile-{profile_index}"
            input_sha256 = _hash(f"{source_id}-{profile_id}-input")
            profile_sha256 = _hash(f"{route}-{profile_id}")
            natural_cases.append((source_id, profile_id, route, input_sha256))
            metrics = {
                "full_ash": {"y_psnr_db": 10.1},
                "conventional": {"y_psnr_db": 10.0},
            }
            for domain in ("engine_raw", "container_decoded"):
                corpus_rows.append(
                    {
                        "source_asset_id": source_id,
                        "target_route": route,
                        "degradation_profile_id": profile_id,
                        "degradation_profile_sha256": profile_sha256,
                        "degraded_input_frame_sha256": input_sha256,
                        "comparison_domain": domain,
                        "metrics_by_control": metrics,
                    }
                )
            native_records.append(
                {
                    "input_frame_sha256": input_sha256,
                    "target_route": route,
                    "input_width": 4,
                    "input_height": 4,
                    "output_width": 8 if route == "direct-2x" else 6,
                    "output_height": 8 if route == "direct-2x" else 6,
                    "analysis_cell_count": 4,
                    "maximum_operator_evaluations": 2,
                    "runtime_leaf_tree_generations": 0,
                    "runtime_path_generations": 0,
                    "per_frame_lut_load_count": 0,
                    "loaded_lut_instance_count": 1,
                    "route_lut_whole_file_sha256": configuration["route_luts"][
                        route
                    ]["whole_file_sha256"],
                }
            )

    fixture_rows = []
    analytic_cases = []
    for route in ROUTES:
        for kind in ("ringing", "alias", "chroma_displacement"):
            fixture_id = f"{route}-{kind}"
            input_sha256 = _hash(f"{fixture_id}-input")
            analytic_cases.append((fixture_id, route, input_sha256))
            output_hashes = {
                "full_ash": _hash(f"{fixture_id}-full"),
                "state_only": _hash(f"{fixture_id}-state"),
            }
            metrics = {
                "full_ash": _analytic_metrics(kind, True),
                "conventional": _analytic_metrics(kind, False),
            }
            for domain in ("engine_raw", "container_decoded"):
                fixture_rows.append(
                    {
                        "fixture_id": fixture_id,
                        "fixture_kind": kind,
                        "target_route": route,
                        "input_frame_sha256": input_sha256,
                        "comparison_domain": domain,
                        "control_output_sha256_values": output_hashes,
                        "metrics_by_control": metrics,
                    }
                )

    control_records = []
    tracked_control_calls = []
    all_cases = [
        (source_id, route, input_sha256)
        for source_id, _, route, input_sha256 in natural_cases
    ] + analytic_cases
    preparation_records = []
    for case_id, route, input_sha256 in all_cases:
        cache_token = _hash(f"{case_id}-{route}-{input_sha256}-cache")
        record = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_non_ash_cache_preparation_evidence",
            "identity_sha256": _hash(
                f"{case_id}-{route}-{input_sha256}-identity"
            ),
            "cache_token": cache_token,
            "cache_origin_manifest_sha256": cache_token,
            "requesting_configuration_id": configuration["configuration_id"],
            "shared_bank_configuration_sha256": bank,
            "cache_reused": False,
            "preparation_analysis_grid_invocation_count": 1,
            "preparation_spatial_operator_evaluation_count": 16,
            "cache_artifact_sha256": _hash(
                f"{case_id}-{route}-{input_sha256}-artifact"
            ),
            "cache_artifact_size_bytes": 1,
            "feature_tensor_q15_sha256": _hash(
                f"{case_id}-{route}-{input_sha256}-features"
            ),
            "descriptor_output_frame_sha256_values": [
                _hash(f"{case_id}-{route}-{input_sha256}-descriptor-{index}")
                for index in range(16)
            ],
        }
        record["record_sha256"] = canonical_sha256(record)
        preparation_records.append(record)
    callable_.set_preparation_records(preparation_records)
    for case_id, route, input_sha256 in all_cases:
        control_records.append(
            _control_record(
                control_key="full_ash",
                control_mode="full_ash",
                input_frame_sha256=input_sha256,
                output_frame_sha256=_hash(f"{case_id}-full-control"),
                target_route=route,
                locked_runtime_summary=_runtime_summary(route),
            )
        )
        for descriptor_id in range(16):
            output_sha256 = _hash(f"{case_id}-{route}-fixed-{descriptor_id}")
            request = {
                "control_mode": "fixed_descriptor_uniform",
                "parameters": {"descriptor_id": descriptor_id},
            }
            tracked_control_calls.append(
                {
                    "request": request,
                    "input_frame_sha256": input_sha256,
                    "output_frame_sha256": output_sha256,
                    "target_route": route,
                }
            )
            control_records.append(
                _control_record(
                    control_key=f"fixed_descriptor_{descriptor_id:02d}",
                    control_mode="fixed_descriptor_uniform",
                    parameters={"descriptor_id": descriptor_id},
                    input_frame_sha256=input_sha256,
                    output_frame_sha256=output_sha256,
                    target_route=route,
                )
            )
    for source_id, profile_id, route, input_sha256 in natural_cases:
        if route != "direct-3over2":
            continue
        control_records.append(
            _control_record(
                control_key="h07_direct_3_over_2",
                control_mode="h07_direct2x_then_lanczos3",
                input_frame_sha256=input_sha256,
                output_frame_sha256=_hash(f"{source_id}-{profile_id}-h07"),
                target_route=route,
                h07_direct2_runtime_summary=_runtime_summary("direct-2x"),
                )
            )
    callable_.set_control_records(control_records)

    provider = PolicyEvaluationEvidenceProvider(
        metric_performance_tolerances=tolerances,
        measurement_evidence_root=tmp_path,
        evidence_store=MemoryEvidenceStore(),
    )
    result = provider.evaluation_evidence(
        adapter=adapter,
        vector={},
        split="development",
        prepared_cases=(),
        corpus_asset_results=corpus_rows,
        analytic_fixture_results=fixture_rows,
        selection_bundle=SimpleNamespace(
            shared_bank_configuration_sha256=bank
        ),
        comparison_identities={},
        candidate_evidence_policy=policy,
        candidate_evidence_policy_sha256=policy_sha256,
        candidate_evidence_source_sha256_bindings=tuple(source_hashes.items()),
        native_runtime_records=native_records,
        native_control_records=control_records,
    )
    evaluation = {
        "corpus_asset_results": corpus_rows,
        "analytic_fixture_results": fixture_rows,
        **result,
    }
    bound = _Bound(policy, tolerances, policy_sha256, source_hashes)
    runner._validate_candidate_checks_and_performance(
        evaluation,
        adapter=adapter,
        bound=bound,
        native_records=native_records,
        tracked_control_calls=tracked_control_calls,
        control_native_records=control_records,
    )
    assert result["dispatch_measurement"]["validation_accessed"] is False
    assert result["checks"]["operator_distinctness"] is True
    assert result["checks"]["analysis_grid_occupancy"] is True
    for route in ROUTES:
        occupancy = result["checks"]["route_occupancy"][route]
        assert occupancy["occupied_cells"] == occupancy["total_cells"]
    assert len(
        result["checks"]["evidence"]["operator_distinctness"][
            "pair_witnesses"
        ]
    ) == 120

    cases = [
        {
            "witness_scope": "natural",
            "source_or_fixture_id": source_id,
            "degradation_profile_id": profile_id,
            "target_route": route,
            "input_frame_sha256": input_sha256,
        }
        for source_id, profile_id, route, input_sha256 in natural_cases
    ] + [
        {
            "witness_scope": "analytic",
            "source_or_fixture_id": fixture_id,
            "degradation_profile_id": None,
            "target_route": route,
            "input_frame_sha256": input_sha256,
        }
        for fixture_id, route, input_sha256 in analytic_cases
    ]
    incomplete_controls = json.loads(canonical_json_bytes(control_records))
    incomplete_record = next(
        record
        for record in incomplete_controls
        if record["control_mode"] == "full_ash"
    )
    incomplete_record["locked_runtime_summary"][
        "occupied_analysis_cell_count"
    ] -= 1
    state_and_grid = provider._state_and_grid(
        cases=cases,
        corpus_rows=corpus_rows,
        fixture_rows=fixture_rows,
        compiler_evidence=compiler,
        control_records=incomplete_controls,
    )
    assert state_and_grid[4] is False

    wrong_phase_controls = json.loads(canonical_json_bytes(control_records))
    wrong_phase_record = next(
        record
        for record in wrong_phase_controls
        if record["control_mode"] == "full_ash"
    )
    wrong_phase_record["locked_runtime_summary"][
        "dispatch_record_count"
    ] -= 1
    with pytest.raises(
        ProductionEvaluatorError,
        match="phase cardinality is invalid",
    ):
        provider._state_and_grid(
            cases=cases,
            corpus_rows=corpus_rows,
            fixture_rows=fixture_rows,
            compiler_evidence=compiler,
            control_records=wrong_phase_controls,
        )
