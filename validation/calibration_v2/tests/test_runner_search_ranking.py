from __future__ import annotations

import json
from pathlib import Path

from validation.calibration_v2 import runner


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]


def _plan() -> dict[str, object]:
    return json.loads(
        (CALIBRATION_ROOT / "contracts/calibration-plan-v1.json").read_text(
            encoding="utf-8"
        )
    )


def _summary(score: float) -> dict[str, object]:
    return {
        "engine_raw": {
            "mean_y_psnr_delta_vs_fixed_db": score,
            "mean_y_psnr_delta_vs_non_ash_db": score,
            "mean_ms_ssim_delta_vs_conventional": score / 1_000.0,
            "maximum_ringing_excursion": 0.0,
            "maximum_alias_ratio": 0.0,
            "estimated_dispatch_cost": 1.0,
        }
    }


def _result(
    score: float,
    *,
    feasible: bool,
    failures: tuple[str, ...],
) -> tuple[dict[str, object], dict[str, object], bool, tuple[str, ...]]:
    return ({}, _summary(score), feasible, failures)


def test_canonical_failure_count_collapses_global_checks_only() -> None:
    failures = (
        "engine_raw:state_causality",
        "container_decoded:state_causality",
        "engine_raw:analysis_grid_route_quality",
        "container_decoded:analysis_grid_route_quality",
        "engine_raw:analysis_grid_occupancy",
        "container_decoded:analysis_grid_occupancy",
        "engine_raw:bootstrap:y_vs_fixed",
        "container_decoded:bootstrap:y_vs_fixed",
    )
    canonical = runner.canonical_development_failure_reasons(failures)
    assert canonical == (
        "check:analysis_grid_occupancy",
        "check:analysis_grid_route_quality",
        "check:state_causality",
        "container_decoded:bootstrap:y_vs_fixed",
        "engine_raw:bootstrap:y_vs_fixed",
    )


def test_feasible_candidate_dominates_better_scoring_infeasible_candidate() -> None:
    plan = _plan()
    vector = dict(plan["search"]["initial_vector_values"])
    feasible = _result(-10.0, feasible=True, failures=())
    infeasible = _result(
        10.0,
        feasible=False,
        failures=("engine_raw:state_causality",),
    )
    assert runner.development_search_key(feasible, vector, plan) < (
        runner.development_search_key(infeasible, vector, plan)
    )


def test_restoration_prefers_fewer_failures_then_existing_objective() -> None:
    plan = _plan()
    vector = dict(plan["search"]["initial_vector_values"])
    fewer_failures = _result(
        -10.0,
        feasible=False,
        failures=("engine_raw:state_causality",),
    )
    more_failures = _result(
        10.0,
        feasible=False,
        failures=(
            "engine_raw:state_causality",
            "engine_raw:chroma_displacement",
        ),
    )
    assert runner.development_search_key(fewer_failures, vector, plan) < (
        runner.development_search_key(more_failures, vector, plan)
    )

    same_failures_better_objective = _result(
        -9.0,
        feasible=False,
        failures=("engine_raw:state_causality",),
    )
    assert runner.development_search_key(
        same_failures_better_objective,
        vector,
        plan,
    ) < runner.development_search_key(fewer_failures, vector, plan)


def test_restoration_accumulates_two_coordinate_changes() -> None:
    plan = _plan()
    initial = dict(plan["search"]["initial_vector_values"])
    failures = ("engine_raw:state_causality",)
    initial_result = _result(-2.0, feasible=False, failures=failures)

    first = dict(initial)
    first["coherent_structure_low_unorm15"] = 9830
    first_result = _result(-1.0, feasible=False, failures=failures)
    current, _ = min(
        ((initial, initial_result), (first, first_result)),
        key=lambda item: runner.development_search_key(
            item[1], item[0], plan
        ),
    )
    assert current == first

    second = dict(current)
    second["detail_gain_q12"] = 1152
    second_result = _result(0.0, feasible=False, failures=failures)
    current, _ = min(
        ((current, first_result), (second, second_result)),
        key=lambda item: runner.development_search_key(
            item[1], item[0], plan
        ),
    )
    assert sum(current[name] != initial[name] for name in current) == 2


def test_exact_rank_tie_uses_complete_serialized_vector() -> None:
    plan = _plan()
    first = dict(plan["search"]["initial_vector_values"])
    second = dict(first)
    first["detail_gain_q12"] = 384
    second["detail_gain_q12"] = 768
    result = _result(
        0.0,
        feasible=False,
        failures=("engine_raw:state_causality",),
    )
    selected, _ = min(
        ((second, result), (first, result)),
        key=lambda item: runner.development_search_key(
            item[1], item[0], plan
        ),
    )
    assert selected == first
    assert runner.development_search_rank_sha256(
        result, first, plan
    ) == runner.development_search_rank_sha256(result, first, plan)
    assert runner.development_search_rank_sha256(
        result, first, plan
    ) != runner.development_search_rank_sha256(result, second, plan)
