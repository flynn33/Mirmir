from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Mapping

import numpy as np
import pytest

from validation.calibration_v2.production_evaluator import (
    CONVENTIONAL_ALGORITHM_IDS,
    FIXED_DESCRIPTOR_IDS,
    NON_ASH_COORDINATES,
    NON_ASH_SELECTOR_ID,
    NON_ASH_VALUES,
    P00_BACKEND_SHA256,
    P00_COMMIT,
    ControlAggregateEvidence,
    MemoryEvidenceStore,
    ProductionEvaluatorError,
    _invoke_native_control,
    build_expected_source_profile_matrix,
    canonical_sha256,
    degradation_native_input,
    finalize_fixed_and_conventional_controls,
    finalize_non_ash_validation,
    frame_sha256,
    make_control_aggregate,
    make_control_selection_bundle,
    non_ash_control_request,
    search_non_ash_development,
    select_development_provisional_controls,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame
from validation.quality.src.mirmir_quality.json_tools import read_json
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _round_trip_locked_bt709_video_range_nv12,
)


ROOT = Path(__file__).resolve().parents[3]
DEGRADATION_POLICY = read_json(
    ROOT / "validation" / "quality" / "policies" / "degradation-policy.json"
)
BANK = "1" * 64
POLICY = str(DEGRADATION_POLICY["policy_sha256"])
VECTOR = "2" * 64
ADAPTER = "3" * 64
FROZEN_DEVELOPMENT = "4" * 64


def _evidence(
    split: str,
    stable_id: object,
    score: float,
    *,
    bank: str = BANK,
) -> ControlAggregateEvidence:
    return ControlAggregateEvidence(
        split=split,
        stable_id=stable_id,
        shared_bank_configuration_sha256=bank,
        degradation_policy_sha256=POLICY,
        rows=(),
        objective_means=(score, score, score, score, score),
        objective_summary_sha256=canonical_sha256(
            {"split": split, "stable_id": stable_id, "kind": "objective"}
        ),
        output_manifest_sha256=canonical_sha256(
            {"split": split, "stable_id": stable_id, "kind": "outputs"}
        ),
    )


def _fixed_evidence(split: str) -> Mapping[int, ControlAggregateEvidence]:
    return {
        identifier: _evidence(split, identifier, float(identifier))
        for identifier in FIXED_DESCRIPTOR_IDS
    }


def _conventional_evidence(
    split: str,
) -> Mapping[str, ControlAggregateEvidence]:
    return {
        identifier: _evidence(split, identifier, float(index))
        for index, identifier in enumerate(CONVENTIONAL_ALGORITHM_IDS)
    }


def _development_controls(
    store: MemoryEvidenceStore,
) -> Mapping[str, Mapping[str, object]]:
    return select_development_provisional_controls(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        development_fixed=_fixed_evidence("development"),
        development_conventional=_conventional_evidence("development"),
        evidence_store=store,
    )


def _final_controls(
    store: MemoryEvidenceStore,
    development: Mapping[str, Mapping[str, object]],
) -> Mapping[str, Mapping[str, object]]:
    return finalize_fixed_and_conventional_controls(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        development_provisional=development,
        validation_fixed=_fixed_evidence("validation"),
        validation_conventional=_conventional_evidence("validation"),
        full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
        evidence_store=store,
    )


def _selector_contract() -> Mapping[str, object]:
    return {
        "selector_id": NON_ASH_SELECTOR_ID,
        "bank_descriptor_ids": list(FIXED_DESCRIPTOR_IDS),
        "candidate_evaluation_budget": 1513,
        "full_ash_maximum_candidate_evaluation_budget": 1345,
        "coordinates": {
            "order": list(NON_ASH_COORDINATES),
            "values": list(NON_ASH_VALUES),
            "initial_value": 0,
            "maximum_sweeps": 8,
        },
    }


def _rule_evaluator(split: str):
    def evaluate(rule: Mapping[str, object]) -> ControlAggregateEvidence:
        digest = str(
            non_ash_control_request(rule, BANK)["parameters"][
                "selected_rule_sha256"
            ]
        )
        score = float(sum(int(value) for value in rule.values()))
        return _evidence(split, digest, score)

    return evaluate


def _development_non_ash(store: MemoryEvidenceStore) -> Mapping[str, object]:
    return search_non_ash_development(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        selector_contract=_selector_contract(),
        development_evaluator=_rule_evaluator("development"),
        cached_16_operator_output_manifest_sha256="5" * 64,
        evidence_store=store,
    )


def _p00_identity() -> Mapping[str, object]:
    configuration = {
        "tile_size": 32,
        "top_k": 1,
        "luma_input_normalization": "raw_byte_divided_by_255",
        "luma_output_quantization": "rounded_times_255",
        "chroma_reconstruction": "nearest",
        "direct_3_over_2_postprocess": (
            "baseline_MPSImageLanczosScale_after_exact_2x"
        ),
    }
    return {
        "commit": P00_COMMIT,
        "backend_source_sha256": P00_BACKEND_SHA256,
        "source_manifest_sha256": "6" * 64,
        "executable_sha256": "7" * 64,
        "configuration_sha256": canonical_sha256(configuration),
        "compatibility_boundary_normalization": {
            "scope": (
                "reopened P00 helper NV12 output before PlanarFrame "
                "conversion, control-output caching, engine-raw metrics, "
                "and container encoding"
            ),
            "method": "p00_compatibility_nominal_video_range_clip_v1",
            "nominal_y_code_range": [16, 235],
            "nominal_chroma_code_range": [16, 240],
            "evidence": (
                "bind raw and normalized payload SHA-256 values and sizes, "
                "raw and normalized per-plane code ranges, and exact "
                "six-direction clip counts in every P00 native control "
                "record"
            ),
            "already_legal_payload_no_op_required": True,
            "direct_2x_postprocess_behavior": (
                "unchanged exact 2x; compatibility normalization only "
                "clips nominal-range excursions"
            ),
            "uniform_application": (
                "apply identically to every P00 control invocation before "
                "any comparison domain is derived"
            ),
        },
        **configuration,
    }


def test_fixed_and_conventional_lifecycle_is_exhaustive_and_stage_clean() -> None:
    store = MemoryEvidenceStore()
    development = _development_controls(store)
    fixed = development["best_fixed"]["document"]
    conventional = development["conventional"]["document"]
    assert fixed["schema_version"] == "1.1.0"
    assert fixed["selection_stage"] == "development_provisional"
    assert fixed["provisional_descriptor_id"] == 15
    assert [row["descriptor_id"] for row in fixed["development_results"]] == list(
        FIXED_DESCRIPTOR_IDS
    )
    assert "chosen_descriptor_id" not in fixed
    assert "validation_results" not in fixed
    assert conventional["provisional_algorithm_id"] == CONVENTIONAL_ALGORITHM_IDS[-1]

    final = _final_controls(store, development)
    fixed_final = final["best_fixed"]["document"]
    conventional_final = final["conventional"]["document"]
    assert fixed_final["selection_stage"] == "validation_final"
    assert fixed_final["chosen_descriptor_id"] == 15
    assert fixed_final["development_selection_sha256"] == development[
        "best_fixed"
    ]["sha256"]
    assert "development_results" not in fixed_final
    assert "provisional_descriptor_id" not in fixed_final
    assert conventional_final["chosen_algorithm_id"] == CONVENTIONAL_ALGORITHM_IDS[-1]


def test_fixed_selection_rejects_missing_candidate_and_cross_stage_leak() -> None:
    store = MemoryEvidenceStore()
    incomplete = dict(_fixed_evidence("development"))
    incomplete.pop(15)
    with pytest.raises(ProductionEvaluatorError, match="coverage or order"):
        select_development_provisional_controls(
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            development_fixed=incomplete,
            development_conventional=_conventional_evidence("development"),
            evidence_store=store,
        )

    development = copy.deepcopy(_development_controls(store))
    development["best_fixed"]["document"]["validation_results"] = []
    development["best_fixed"]["sha256"] = canonical_sha256(
        development["best_fixed"]["document"]
    )
    with pytest.raises(ProductionEvaluatorError, match="violates its schema"):
        _final_controls(store, development)


@pytest.mark.parametrize("mutation", ["missing", "renamed", "extra"])
def test_non_ash_rule_schema_rejects_coordinate_drift(mutation: str) -> None:
    store = MemoryEvidenceStore()
    development = copy.deepcopy(_development_non_ash(store))
    rule = development["document"]["development_terminal_rule_configuration"]
    first = NON_ASH_COORDINATES[0]
    if mutation == "missing":
        rule.pop(first)
    elif mutation == "renamed":
        rule["renamed_coordinate_q8_8"] = rule.pop(first)
    else:
        rule["extra_coordinate_q8_8"] = 0
    development["sha256"] = canonical_sha256(development["document"])
    with pytest.raises(ProductionEvaluatorError, match="violates its schema"):
        finalize_non_ash_validation(
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            development_provisional=development,
            validation_evaluator=_rule_evaluator("validation"),
            full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
            evidence_store=store,
        )


def test_non_ash_search_is_staged_exhaustive_and_deterministic() -> None:
    first_store = MemoryEvidenceStore()
    development = _development_non_ash(first_store)
    development_document = development["document"]
    assert development_document["selection_stage"] == "development_provisional"
    assert "validation_results" not in development_document
    assert "selected_rule_sha256" not in development_document
    assert development_document["development_attempt_count"] <= 1513

    validation_calls: list[str] = []

    def validation(rule: Mapping[str, object]) -> ControlAggregateEvidence:
        evidence = _rule_evaluator("validation")(rule)
        validation_calls.append(str(evidence.stable_id))
        return evidence

    final = finalize_non_ash_validation(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        development_provisional=development,
        validation_evaluator=validation,
        full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
        evidence_store=first_store,
    )
    document = final["document"]
    assert document["selection_stage"] == "validation_final"
    assert document["validation_candidate_count"] == 163
    assert len(validation_calls) == len(set(validation_calls)) == 163
    assert len(document["validation_results"]) == 163
    assert "development_attempt_ledger_sha256" not in document
    assert "development_terminal_rule_configuration" not in document

    second_store = MemoryEvidenceStore()
    second_development = _development_non_ash(second_store)
    second_final = finalize_non_ash_validation(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        development_provisional=second_development,
        validation_evaluator=_rule_evaluator("validation"),
        full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
        evidence_store=second_store,
    )
    assert second_development == development
    assert second_final == final


def _metric_bundle(value: float, domain: str) -> Mapping[str, object]:
    return {
        "y_psnr_db": value,
        "cb_psnr_db": value - 1.0,
        "cr_psnr_db": value - 2.0,
        "y_ssim": 0.9,
        "cb_ssim": 0.8,
        "cr_ssim": 0.7,
        "y_ms_ssim": 0.95,
        "cb_ms_ssim": 0.85,
        "cr_ms_ssim": 0.75,
        "writer_y_psnr_contribution_db": (
            None if domain == "engine_raw" else -0.1
        ),
    }


def _aggregate_rows(
    matrix: tuple[Mapping[str, object], ...],
    control_configuration_sha256: str,
) -> list[Mapping[str, object]]:
    rows: list[Mapping[str, object]] = []
    for domain in ("engine_raw", "container_decoded"):
        for index, identity in enumerate(matrix):
            writer_hash = (
                None
                if domain == "engine_raw"
                else canonical_sha256(
                    {"domain": domain, "index": index, "kind": "writer"}
                )
            )
            rows.append(
                {
                    **dict(identity),
                    "degradation_policy_sha256": POLICY,
                    "comparison_domain": domain,
                    "output_sha256": canonical_sha256(
                        {"domain": domain, "index": index, "kind": "output"}
                    ),
                    "metrics": _metric_bundle(30.0 + index, domain),
                    "writer_evidence_sha256": writer_hash,
                    "control_configuration_sha256": (
                        control_configuration_sha256
                    ),
                    "shared_bank_configuration_sha256": BANK,
                }
            )
    return rows


def test_control_aggregate_requires_exact_three_profile_matrix() -> None:
    cases = (
        {
            "source_asset_id": "asset-2x",
            "source_family_id": "family-2x",
            "categories": ["natural_texture"],
            "target_route": "direct-2x",
        },
        {
            "source_asset_id": "asset-3over2",
            "source_family_id": "family-3over2",
            "categories": ["diagonal_geometry"],
            "target_route": "direct-3over2",
        },
    )
    matrix = build_expected_source_profile_matrix(
        cases=cases,
        degradation_policy=DEGRADATION_POLICY,
    )
    assert len(matrix) == 6
    configuration = "8" * 64
    rows = _aggregate_rows(matrix, configuration)
    result = make_control_aggregate(
        split="development",
        stable_id=0,
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        control_configuration_sha256=configuration,
        expected_source_profile_matrix=matrix,
        rows=rows,
        evidence_store=MemoryEvidenceStore(),
    )
    assert len(result.rows) == 12

    with pytest.raises(ProductionEvaluatorError, match="exactly cover"):
        make_control_aggregate(
            split="development",
            stable_id=0,
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            control_configuration_sha256=configuration,
            expected_source_profile_matrix=matrix,
            rows=rows[:-1],
            evidence_store=MemoryEvidenceStore(),
        )
    substituted = copy.deepcopy(rows)
    substituted[0]["degradation_profile_sha256"] = "9" * 64
    with pytest.raises(ProductionEvaluatorError, match="substitutes"):
        make_control_aggregate(
            split="development",
            stable_id=0,
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            control_configuration_sha256=configuration,
            expected_source_profile_matrix=matrix,
            rows=substituted,
            evidence_store=MemoryEvidenceStore(),
        )


def test_degradation_cache_payload_is_post_420v_boundary() -> None:
    y = np.linspace(0.03, 0.97, 64 * 64, dtype=np.float64).reshape(64, 64)
    cb = np.linspace(-0.4, 0.4, 32 * 32, dtype=np.float64).reshape(32, 32)
    cr = np.flipud(cb)
    target = PlanarFrame(y=y, cb=cb, cr=cr)
    profile = DEGRADATION_POLICY["profiles"][0]
    raw = degradation_native_input(target, profile)
    _, reopened = _round_trip_locked_bt709_video_range_nv12(raw)
    assert frame_sha256(raw) == frame_sha256(reopened)
    assert not raw.y.flags.writeable
    assert not raw.cb.flags.writeable
    assert not raw.cr.flags.writeable


def _selection_bundles():
    store = MemoryEvidenceStore()
    development_fixed = _development_controls(store)
    development_non_ash = _development_non_ash(store)
    development = make_control_selection_bundle(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        candidate_vector_sha256=VECTOR,
        adapter_configuration_sha256=ADAPTER,
        fixed_selection=development_fixed["best_fixed"],
        conventional_selection=development_fixed["conventional"],
        non_ash_selection=development_non_ash,
        p00_identity=_p00_identity(),
    )
    final_fixed = _final_controls(store, development_fixed)
    final_non_ash = finalize_non_ash_validation(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        development_provisional=development_non_ash,
        validation_evaluator=_rule_evaluator("validation"),
        full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
        evidence_store=store,
    )
    final = make_control_selection_bundle(
        shared_bank_configuration_sha256=BANK,
        degradation_policy_sha256=POLICY,
        candidate_vector_sha256=VECTOR,
        adapter_configuration_sha256=ADAPTER,
        fixed_selection=final_fixed["best_fixed"],
        conventional_selection=final_fixed["conventional"],
        non_ash_selection=final_non_ash,
        p00_identity=_p00_identity(),
        full_ash_development_candidates_frozen_sha256=FROZEN_DEVELOPMENT,
    )
    return development, final


def test_control_bundle_rejects_mixed_stage_and_stale_bank() -> None:
    development, final = _selection_bundles()
    with pytest.raises(ProductionEvaluatorError, match="mix lifecycle stages"):
        make_control_selection_bundle(
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            candidate_vector_sha256=VECTOR,
            adapter_configuration_sha256=ADAPTER,
            fixed_selection=development.fixed_selection,
            conventional_selection=final.conventional_selection,
            non_ash_selection=development.non_ash_selection,
            p00_identity=_p00_identity(),
        )
    stale = copy.deepcopy(development.fixed_selection)
    stale["document"]["shared_bank_configuration_sha256"] = "a" * 64
    stale["sha256"] = canonical_sha256(stale["document"])
    with pytest.raises(ProductionEvaluatorError, match="stale or nonuniform"):
        make_control_selection_bundle(
            shared_bank_configuration_sha256=BANK,
            degradation_policy_sha256=POLICY,
            candidate_vector_sha256=VECTOR,
            adapter_configuration_sha256=ADAPTER,
            fixed_selection=stale,
            conventional_selection=development.conventional_selection,
            non_ash_selection=development.non_ash_selection,
            p00_identity=_p00_identity(),
        )


def test_selected_control_requests_use_native_keys_and_exact_state_identity() -> None:
    development, _ = _selection_bundles()
    descriptor_id = development.fixed_selection["document"][
        "provisional_descriptor_id"
    ]
    algorithm_id = development.conventional_selection["document"][
        "provisional_algorithm_id"
    ]
    assert development.request("best_fixed")["control_key"] == (
        f"fixed_descriptor_{descriptor_id:02d}"
    )
    assert development.request("conventional")["control_key"] == (
        f"conventional_{CONVENTIONAL_ALGORITHM_IDS.index(algorithm_id)}"
    )
    assert development.request("state_only")["parameters"] == {
        "control_id": "ash-state-only-base-descriptor-v1",
        "candidate_vector_sha256": VECTOR,
    }
    for key in ("best_fixed", "conventional", "state_only"):
        request = dict(development.request(key))
        declared = request.pop("request_sha256")
        assert declared == canonical_sha256(request)


class _FakeNativeControl:
    def __init__(self, *, prior_frame_count: int = 0) -> None:
        self.records: list[Mapping[str, object]] = []
        self.prior_frame_count = prior_frame_count

    def __call__(
        self,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        return frame

    def control_runtime_records(self):
        return tuple(self.records)

    def reconstruct_control(
        self,
        request: Mapping[str, object],
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> PlanarFrame:
        output = PlanarFrame(
            y=np.array(frame.y, copy=True),
            cb=np.array(frame.cb, copy=True),
            cr=np.array(frame.cr, copy=True),
        )
        parameters = request["parameters"]
        record = {
            "control_key": request["control_key"],
            "control_mode": request["control_mode"],
            "request_sha256": request["request_sha256"],
            "configuration_sha256": request["configuration_sha256"],
            "shared_bank_configuration_sha256": request[
                "shared_bank_configuration_sha256"
            ],
            "input_frame_sha256": frame_sha256(frame),
            "output_frame_sha256": frame_sha256(output),
            "target_route": context.target_route,
            "parameters": dict(parameters),
            "parameters_sha256": canonical_sha256(parameters),
            "p00_commit": parameters["commit"],
            "p00_backend_source_sha256": parameters[
                "backend_source_sha256"
            ],
            "p00_source_manifest_sha256": parameters["source_manifest_sha256"],
            "p00_executable_sha256": parameters["executable_sha256"],
            "p00_configuration_sha256": parameters["configuration_sha256"],
            "p00_backend_reset_before_frame": True,
            "p00_prior_frame_count": self.prior_frame_count,
        }
        record["record_sha256"] = canonical_sha256(record)
        self.records.append(record)
        return output


def test_p00_requires_per_asset_backend_reset_and_zero_prior_frames() -> None:
    _, final = _selection_bundles()
    request = final.request("current_production_ash")
    frame = PlanarFrame(
        y=np.full((16, 16), 0.4, dtype=np.float64),
        cb=np.full((8, 8), 0.1, dtype=np.float64),
        cr=np.full((8, 8), -0.1, dtype=np.float64),
    )
    context = CandidateContext(
        y_shape=frame.y.shape,
        cb_shape=frame.cb.shape,
        cr_shape=frame.cr.shape,
        target_route="direct-2x",
    )
    native = _FakeNativeControl()
    adapter_configuration = {"shared_bank_configuration_sha256": BANK}
    adapter = CandidateAdapter(
        candidate_id="candidate",
        configuration=adapter_configuration,
        configuration_sha256=canonical_sha256(adapter_configuration),
        callable=native,
    )
    output, record = _invoke_native_control(
        adapter=adapter,
        request=request,
        low_resolution=frame,
        context=context,
    )
    assert frame_sha256(output) == frame_sha256(frame)
    assert record["p00_backend_reset_before_frame"] is True
    assert record["p00_prior_frame_count"] == 0

    stale_native = _FakeNativeControl(prior_frame_count=1)
    stale_adapter = CandidateAdapter(
        candidate_id="candidate",
        configuration=adapter_configuration,
        configuration_sha256=canonical_sha256(adapter_configuration),
        callable=stale_native,
    )
    with pytest.raises(ProductionEvaluatorError, match="P00 native control identity"):
        _invoke_native_control(
            adapter=stale_adapter,
            request=request,
            low_resolution=frame,
            context=context,
        )


def test_lifecycle_evidence_contains_no_path_or_holdout_reference() -> None:
    development, final = _selection_bundles()
    payload = json.dumps(
        {
            "development": {
                "fixed": development.fixed_selection,
                "conventional": development.conventional_selection,
                "non_ash": development.non_ash_selection,
            },
            "final": {
                "fixed": final.fixed_selection,
                "conventional": final.conventional_selection,
                "non_ash": final.non_ash_selection,
            },
        },
        sort_keys=True,
    ).lower()
    assert "holdout" not in payload
    assert '"path"' not in payload
    assert "_path" not in payload
    assert "_root" not in payload
