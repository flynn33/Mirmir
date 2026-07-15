#!/usr/bin/env python3
"""Build the canonical report artifact for one verified P06 analysis snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
from typing import Mapping, Sequence


TITLE = "ASH P06 Failure Patterns Through Attempt 240"
EVIDENCE_PATH = (
    "analysis/ash-failure-patterns/evidence/p06-current-source-snapshot-final.json"
)
REQUIRED_VALIDATION_FLAGS = (
    "canonical_ndjson",
    "sequence_continuous",
    "record_hash_chain_valid",
    "candidate_vector_bindings_valid",
    "evaluation_artifact_bindings_valid",
    "summary_bindings_valid",
    "development_search_rank_bindings_valid",
    "input_bundle_internal_consistency_valid",
    "policy_source_bindings_valid",
    "repository_input_files_match_bundle",
    "evaluator_source_import_match_valid",
    "source_snapshot_stable",
)


class ReportBuildError(ValueError):
    """Raised when report source evidence is absent or inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ReportBuildError(message)


def _canonical_json_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _analysis_self_hash(document: Mapping[str, object]) -> str:
    unhashed = dict(document)
    declared = unhashed.pop("analysis_sha256", None)
    computed = hashlib.sha256(_canonical_json_bytes(unhashed)).hexdigest()
    _require(declared == computed, "analysis self-hash differs")
    return computed


def resolve_analysis_source(path: Path) -> tuple[Path, str]:
    """Bind the CLI input to the one repository-relative source cited by the report."""

    repository_root = Path(__file__).resolve().parents[2]
    expected = (repository_root / EVIDENCE_PATH).resolve(strict=True)
    actual = path.resolve(strict=True)
    _require(actual == expected, "analysis source path differs from report citation")
    return actual, EVIDENCE_PATH


def _percent(value: float, digits: int = 1) -> str:
    return f"{100.0 * value:.{digits}f}%"


def _format_db(value: float) -> str:
    return f"{value:+.4f} dB"


def _source(
    *,
    source_id: str,
    label: str,
    path: str,
    query: str | None = None,
    executed_at: str | None = None,
    tables_used: Sequence[str] = (),
    filters: Sequence[str] = (),
    metric_definitions: Sequence[str] = (),
) -> dict[str, object]:
    result: dict[str, object] = {"id": source_id, "label": label, "path": path}
    if query is not None:
        result["query"] = {
            "engine": "SQLite",
            "language": "SQL",
            "id": source_id,
            "description": f"Bounded P06 diagnostic query for {label.lower()}.",
            "executed_at": executed_at,
            "sql": query,
            "tables_used": list(tables_used),
            "filters": list(filters),
            "metric_definitions": list(metric_definitions),
        }
    return result


def _labeled_failure_rows(rows: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    return [
        {
            **dict(row),
            "criterion": str(row["reason"])
            .replace("container_decoded", "Decoded")
            .replace("engine_raw", "Raw")
            .replace("check:", "Check · ")
            .replace(":bootstrap:y_vs_", " · Y vs ")
            .replace(":chroma_displacement", " · chroma displacement")
            .replace("conventional", "conventional")
            .replace("non_ash", "non-ASH")
            .replace("fixed", "fixed")
            .replace("analysis_grid_route_quality", "route quality")
            .replace("state_causality", "state causality")
            .replace("severe_category_regression", "severe category regression")
            .replace("severe_asset_regression", "severe asset regression"),
        }
        for row in rows
    ]


def _bootstrap_rows(rows: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    comparison_labels = {
        "bootstrap_ci_low:y_vs_conventional": "conventional",
        "bootstrap_ci_low:y_vs_fixed": "best fixed",
        "bootstrap_ci_low:y_vs_non_ash": "non-ASH selector",
    }
    domain_labels = {"engine_raw": "Raw", "container_decoded": "Decoded"}
    return [
        {
            **dict(row),
            "comparison": comparison_labels[str(row["metric"])],
            "domain_label": domain_labels[str(row["domain"])],
            "label": (
                f"{domain_labels[str(row['domain'])]} · "
                f"{comparison_labels[str(row['metric'])]}"
            ),
        }
        for row in rows
    ]


def _route_failure_rows(rows: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    labels = {
        "maximum_chroma_displacement_pixels": "absolute chroma",
        "minimum_per_source_y_psnr_delta_db": "per-source Y floor",
    }
    return [
        {
            **dict(row),
            "label": f"{row['route']} · {labels.get(str(row['predicate']), row['predicate'])}",
        }
        for row in rows
        if int(row["failed_attempt_count"]) > 0
    ]


def _coordinate_rows(rows: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    ordered = sorted(
        (dict(row) for row in rows),
        key=lambda row: (
            -(
                float(row["engine_raw_conventional_ci_span_db"])
                if row["engine_raw_conventional_ci_span_db"] is not None
                else -math.inf
            ),
            str(row["coordinate"]),
        ),
    )
    for index, row in enumerate(ordered, start=1):
        row["response_rank"] = index
    return ordered


def build_artifact(
    analysis: Mapping[str, object],
    *,
    analysis_path: str,
) -> Mapping[str, object]:
    analysis_hash = _analysis_self_hash(analysis)
    _require(analysis_path == EVIDENCE_PATH, "analysis source path differs from report citation")
    _require(
        analysis.get("artifact_kind") == "p06_failure_pattern_analysis",
        "analysis artifact kind differs",
    )
    scope = analysis["scope"]
    validation = analysis["validation"]
    headline = analysis["headline"]
    datasets = analysis["datasets"]
    queries = analysis["queries"]
    captured = str(analysis["captured_utc"])
    cutoff = int(scope["cutoff_sequence"])
    _require(cutoff == 240, "report title and verified cutoff differ")
    _require(scope.get("split") == "development", "analysis split differs")
    _require(
        all(
            isinstance(scope.get(field), str)
            and len(scope[field]) == 40
            and all(character in "0123456789abcdef" for character in scope[field])
            for field in ("analysis_repository_head", "bound_repository_head")
        ),
        "analysis repository head bindings are invalid",
    )
    _require(scope.get("holdout_accessed") is False, "analysis accessed holdout payload")
    _require(scope.get("media_payload_accessed") is False, "analysis accessed media payload")
    _require(
        all(validation.get(flag) is True for flag in REQUIRED_VALIDATION_FLAGS),
        "analysis validation contract is not fully passing",
    )
    evaluated = int(headline["evaluated_attempt_count"])
    total = int(headline["attempt_count"])
    feasible = int(headline["feasible_attempt_count"])
    core_count = int(headline["core_nine_attempt_count"])
    core_fraction = float(headline["core_nine_evaluated_fraction"])
    constraint_failures = int(headline["constraint_failure_count"])
    evaluation_failures = int(headline["evaluation_failure_count"])
    pre_stops = constraint_failures + evaluation_failures
    unique_evaluations = int(validation["unique_evaluation_file_count"])
    repository_input_count = int(validation["repository_input_file_count"])
    _require(feasible == 0, "bounded failure report requires zero feasible attempts")
    _require(
        total == int(validation["attempt_count"])
        and evaluated == int(validation["evaluation_attempt_count"])
        and evaluated == int(validation["summary_verification_count"])
        and total == evaluated + pre_stops,
        "analysis attempt counts are inconsistent",
    )
    _require(
        0 < unique_evaluations <= evaluated and repository_input_count > 0,
        "analysis verified-input counts are inconsistent",
    )
    _require(
        0 <= core_count <= evaluated
        and math.isclose(
            core_fraction,
            core_count / evaluated,
            rel_tol=0.0,
            abs_tol=1e-15,
        ),
        "analysis core-nine count and fraction are inconsistent",
    )
    headline_rows = datasets["headline_summary"]
    _require(len(headline_rows) == 1, "headline SQL dataset row count differs")
    headline_row = headline_rows[0]
    _require(
        int(headline_row["attempt_count"]) == total
        and int(headline_row["evaluated_attempt_count"]) == evaluated
        and int(headline_row["feasible_attempt_count"]) == feasible
        and int(headline_row["core_nine_attempt_count"]) == core_count
        and int(headline_row["pre_evaluation_stop_count"]) == pre_stops
        and math.isclose(
            float(headline_row["core_nine_evaluated_fraction"]),
            core_fraction,
            rel_tol=0.0,
            abs_tol=1e-15,
        ),
        "headline fields differ from the SQL-derived headline dataset",
    )
    correlations = analysis["correlations"]["values"]
    attempt_correlations = correlations["attempt_weighted"]
    unique_correlations = correlations["unique_evaluation"]
    chroma_tradeoff = datasets["chroma_passing_tradeoff"]
    _require(len(chroma_tradeoff) == 2, "verified chroma-passing candidate count differs")
    coordinate_response = datasets["coordinate_response"]
    qualified_coordinate_rows = [
        row for row in coordinate_response if int(row["qualified_sweep_count"]) > 0
    ]
    flat_chroma_count = sum(
        float(row["engine_raw_chroma_span_pixels"]) == 0.0
        and float(row["container_chroma_span_pixels"]) == 0.0
        for row in qualified_coordinate_rows
    )
    flat_conventional_y_count = sum(
        float(row["engine_raw_conventional_ci_span_db"]) == 0.0
        and float(row["container_conventional_ci_span_db"]) == 0.0
        for row in qualified_coordinate_rows
    )
    bootstrap_by_key = {
        (str(row["domain"]), str(row["metric"])): float(row["best_margin_db"])
        for row in datasets["bootstrap_best_margin"]
    }
    raw_conventional_best = bootstrap_by_key[
        ("engine_raw", "bootstrap_ci_low:y_vs_conventional")
    ]
    decoded_conventional_best = bootstrap_by_key[
        ("container_decoded", "bootstrap_ci_low:y_vs_conventional")
    ]
    adaptive_best_deficit = min(
        abs(value)
        for (domain, metric), value in bootstrap_by_key.items()
        if domain in {"engine_raw", "container_decoded"}
        and metric in {
            "bootstrap_ci_low:y_vs_fixed",
            "bootstrap_ci_low:y_vs_non_ash",
        }
    )
    failure_count_by_reason = {
        str(row["reason"]): int(row["failed_attempt_count"])
        for row in datasets["failure_frequency"]
    }
    persistent_core = {
        "check:analysis_grid_route_quality",
        "container_decoded:bootstrap:y_vs_conventional",
        "container_decoded:bootstrap:y_vs_fixed",
        "container_decoded:bootstrap:y_vs_non_ash",
        "engine_raw:bootstrap:y_vs_conventional",
        "engine_raw:bootstrap:y_vs_fixed",
        "engine_raw:bootstrap:y_vs_non_ash",
    }
    _require(
        all(failure_count_by_reason.get(reason) == evaluated for reason in persistent_core),
        "persistent core failure counts differ",
    )
    raw_chroma_failure_count = failure_count_by_reason[
        "engine_raw:chroma_displacement"
    ]
    decoded_chroma_failure_count = failure_count_by_reason[
        "container_decoded:chroma_displacement"
    ]
    _require(
        raw_chroma_failure_count == decoded_chroma_failure_count,
        "raw and decoded chroma failure counts differ",
    )
    route_by_key = {
        (str(row["route"]), str(row["predicate"])): row
        for row in datasets["route_predicate_failure_frequency"]
    }
    route_nonzero_count = sum(
        int(row["failed_attempt_count"]) > 0 for row in route_by_key.values()
    )
    route_zero_count = len(route_by_key) - route_nonzero_count
    direct_three_chroma_percent = float(
        route_by_key[("direct-3over2", "maximum_chroma_displacement_pixels")][
            "failed_attempt_percent"
        ]
    )
    direct_two_chroma_percent = float(
        route_by_key[("direct-2x", "maximum_chroma_displacement_pixels")][
            "failed_attempt_percent"
        ]
    )
    risk_rows = datasets["state_coordinate6_risk_response"]
    _require(bool(risk_rows), "risk-state response rows are absent")
    _require(
        any(
            math.isclose(
                float(row["engine_raw_conventional_ci_low_db"]),
                float(row["global_best_engine_raw_conventional_ci_low_db"]),
                rel_tol=0.0,
                abs_tol=1e-15,
            )
            for row in risk_rows
        ),
        "risk-threshold block does not contain the global best raw conventional result",
    )
    high_risk_rows = [row for row in risk_rows if int(row["value_text"]) >= 9830]
    _require(
        bool(high_risk_rows)
        and all(int(row["state_causality_failed"]) == 1 for row in high_risk_rows),
        "high risk-threshold rows do not all carry state-causality failure",
    )
    _require(
        all(
            int(row["one_count"]) == 0
            for row in high_risk_rows
            if str(row["route"]) == "direct-3over2"
        ),
        "direct-3/2 high risk-threshold one-population differs",
    )
    tradeoff_sequence_text = " and ".join(
        str(int(row["sequence"])) for row in chroma_tradeoff
    )
    tradeoff_raw_y_text = " and ".join(
        f"{float(row['engine_raw_conventional_ci_low_db']):.2f} dB"
        for row in chroma_tradeoff
    )
    high_risk_minimum = min(int(row["value_text"]) for row in high_risk_rows)
    high_risk_maximum = max(int(row["value_text"]) for row in high_risk_rows)

    query_path = "analysis/ash-failure-patterns/queries/p06_failure_analysis.sql"
    source_specs = [
        _source(
            source_id="analysis_snapshot",
            label=f"Verified P06 failure-pattern snapshot · SHA-256 {analysis_hash}",
            path=analysis_path,
        ),
        _source(
            source_id="headline_sql",
            label="P06 headline counts",
            path=query_path,
            query=str(queries["headline_summary"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts",),
            filters=(f"ledger sequence <= {cutoff}", "development split only"),
            metric_definitions=(
                "Evaluated attempts have a complete feasible or infeasible candidate evaluation.",
                "Core-nine rate divides exact core-nine attempts by evaluated attempts.",
            ),
        ),
        _source(
            source_id="failure_sql",
            label="Canonical failure frequency",
            path=query_path,
            query=str(queries["failure_frequency"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts", "p06_analysis.failures"),
            filters=(
                f"ledger sequence <= {cutoff}",
                "evaluated attempts; feasible attempts contribute only to the denominator",
            ),
            metric_definitions=(
                "Failure frequency is failed evaluated attempts divided by all evaluated attempts.",
            ),
        ),
        _source(
            source_id="candidate_sql",
            label="Unique-evaluation luma-chroma metric matrix",
            path=query_path,
            query=str(queries["unique_evaluation_metric_matrix"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts", "p06_analysis.metrics"),
            filters=(
                f"ledger sequence <= {cutoff}",
                "complete evaluated attempts",
                "one earliest attempt per unique evaluation SHA-256",
            ),
            metric_definitions=(
                "Y values are 95% paired-bootstrap lower bounds in dB.",
                "Chroma values are maximum absolute luma-pixel displacement.",
            ),
        ),
        _source(
            source_id="tradeoff_sql",
            label="Chroma-passing candidate counterexamples",
            path=query_path,
            query=str(queries["chroma_passing_tradeoff"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts", "p06_analysis.metrics"),
            filters=(
                f"ledger sequence <= {cutoff}",
                "complete evaluated attempts",
                "raw and decoded absolute chroma displacement <= 0.25 pixels",
            ),
            metric_definitions=(
                "Y values are 95% paired-bootstrap lower bounds in dB.",
                "Chroma values are maximum absolute luma-pixel displacement.",
            ),
        ),
        _source(
            source_id="bootstrap_sql",
            label="Best observed bootstrap margins",
            path=query_path,
            query=str(queries["bootstrap_best_margin"]),
            executed_at=captured,
            tables_used=("p06_analysis.metrics",),
            filters=(f"ledger sequence <= {cutoff}", "bootstrap lower-bound metrics only"),
            metric_definitions=(
                "Best margin is the largest observed 95% CI lower bound minus the strict 0 dB threshold.",
            ),
        ),
        _source(
            source_id="route_sql",
            label="Route-quality predicate failures",
            path=query_path,
            query=str(queries["route_predicate_failure_frequency"]),
            executed_at=captured,
            tables_used=("p06_analysis.route_predicates",),
            filters=(f"ledger sequence <= {cutoff}", "development evaluations only"),
            metric_definitions=(
                "Each reported route metric predicate is re-evaluated against its preregistered threshold.",
            ),
        ),
        _source(
            source_id="coordinate_sql",
            label="Coordinate response spans",
            path=query_path,
            query=str(queries["coordinate_response"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts", "p06_analysis.metrics"),
            filters=(f"ledger sequence <= {cutoff}", "one-coordinate search blocks"),
            metric_definitions=(
                "Response span is the maximum within-sweep metric range for one coordinate block.",
                "Evaluated-attempt counts cover every sweep for the named coordinate.",
            ),
        ),
        _source(
            source_id="state_sql",
            label="Risk-threshold state-coordinate response",
            path=query_path,
            query=str(queries["state_coordinate6_risk_response"]),
            executed_at=captured,
            tables_used=(
                "p06_analysis.attempts",
                "p06_analysis.state_observations",
                "p06_analysis.metrics",
                "p06_analysis.failures",
            ),
            filters=(
                f"ledger sequence <= {cutoff}",
                "alias_or_ringing_risk_high_unorm15 coordinate block",
                "active state coordinate 6",
            ),
            metric_definitions=(
                "one_count is the number of observed dispatch samples where active state coordinate 6 equals one.",
                "state_causality_failed is derived from the canonical failure set for the same attempt.",
                "Raw conventional-Y values are the attempt lower bound and the bounded global maximum.",
            ),
        ),
        _source(
            source_id="pre_error_sql",
            label="Pre-evaluation rejection frequency",
            path=query_path,
            query=str(queries["pre_evaluation_error_frequency"]),
            executed_at=captured,
            tables_used=("p06_analysis.attempts", "p06_analysis.attempt_errors"),
            filters=(
                f"ledger sequence <= {cutoff}",
                "constraint_failure or evaluation_failure status",
            ),
            metric_definitions=(
                "Pre-evaluation stops are attempts without a complete candidate evaluation.",
            ),
        ),
        _source(
            source_id="code_map",
            label="ASH failure-to-code map",
            path="analysis/ash-failure-patterns/code-path-map.md",
        ),
        _source(
            source_id="tolerance_contract",
            label="P06 metric and performance tolerances",
            path="validation/calibration_v2/contracts/metric-performance-tolerances-v1.json",
        ),
        _source(
            source_id="live_ledger",
            label="Bounded live P06 attempt ledger",
            path=str(scope["ledger_path"]),
        ),
    ]

    report_datasets = {
        "headline": [
            {
                "attempt_count": total,
                "evaluated_attempt_count": evaluated,
                "feasible_attempt_count": feasible,
                "core_nine_evaluated_fraction": core_fraction,
                "pre_evaluation_stop_count": pre_stops,
            }
        ],
        "failure_frequency": _labeled_failure_rows(datasets["failure_frequency"]),
        "candidate_metric_matrix": [
            dict(row) for row in datasets["unique_evaluation_metric_matrix"]
        ],
        "bootstrap_margin": _bootstrap_rows(datasets["bootstrap_best_margin"]),
        "route_failures": _route_failure_rows(
            datasets["route_predicate_failure_frequency"]
        ),
        "chroma_tradeoff": [dict(row) for row in chroma_tradeoff],
        "coordinate_response": _coordinate_rows(coordinate_response),
        "risk_state_response": [
            dict(row) for row in datasets["state_coordinate6_risk_response"]
        ],
        "pre_evaluation_errors": [
            dict(row) for row in datasets["pre_evaluation_error_frequency"]
        ],
    }

    summary_body = (
        "## Current tuning cannot jointly satisfy luma and chroma\n\n"
        f"Through ledger sequence **{cutoff}**, the run recorded **{total} attempts**; "
        f"**{evaluated}** completed evaluation and **none was feasible**. The exact same "
        f"nine-condition blocker set occurred in **{core_count} evaluated attempts "
        f"({_percent(core_fraction)})**. Seven conditions failed in every completed "
        "evaluation: the composite route-quality check plus raw and decoded Y lower-bound "
        "tests against fixed, non-ASH, and conventional controls.\n\n"
        "The evidence identifies a structural tradeoff rather than normal coordinate-search "
        "convergence. Only two candidates satisfy the absolute chroma limit in both domains, "
        "and both create severe luma regressions. Raw and decoded metrics move almost "
        "one-for-one, so codec writing is a secondary effect rather than the primary root."
    )

    blocks = [
        {"id": "title", "type": "markdown", "layout": "full", "body": f"# {TITLE}"},
        {
            "id": "technical_summary",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": summary_body,
        },
        {
            "id": "headline_metrics",
            "type": "metric-strip",
            "layout": "full",
            "cardIds": ["evaluated", "feasible", "core_nine", "pre_stops"],
        },
        {
            "id": "persistence_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Seven gates stayed closed across every complete evaluation\n\n"
                f"All **{evaluated}** evaluated candidates fail six Y-bootstrap criteria and "
                "route quality. Both chroma-domain criteria fail in "
                f"{raw_chroma_failure_count} evaluations "
                f"({_percent(raw_chroma_failure_count / evaluated)}). "
                "The smaller state-causality and severe-regression counts are excursions added "
                "by particular parameter values; they do not replace the persistent core. The "
                "bar uses completed evaluations as its denominator, keeping "
                f"{pre_stops} pre-evaluation stops separate."
            ),
        },
        {"id": "failure_chart", "type": "chart", "layout": "full", "chartId": "failure_frequency"},
        {
            "id": "tradeoff_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## The only chroma-passing candidates collapse luma quality\n\n"
                "The scatter compares raw maximum chroma displacement with the raw 95% Y-PSNR "
                "lower bound versus conventional for every unique evaluation artifact. Passing "
                "requires "
                "being left of 0.25 pixels and above 0 dB. Only sequences "
                f"{tradeoff_sequence_text} enter the chroma-passing region; their Y lower bounds "
                f"are {tradeoff_raw_y_text}. Across "
                "unique evaluations, Y lower bound and chroma displacement have a descriptive Pearson "
                "correlation of **"
                f"{float(unique_correlations['raw_conventional_ci_low_vs_chroma_displacement']):.3f}** "
                "across unique evaluation artifacts; the attempt-weighted value is **"
                f"{float(attempt_correlations['raw_conventional_ci_low_vs_chroma_displacement']):.3f}**. "
                "This association does not establish causality, but it demonstrates that the "
                "current shared parameterization has not produced a joint passing region."
            ),
        },
        {"id": "tradeoff_chart", "type": "chart", "layout": "full", "chartId": "luma_chroma_tradeoff"},
        {
            "id": "tradeoff_table_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "The exact two chroma-passing rows are both global anisotropy settings. Their "
                "11-condition failure sets include severe luma regressions, so they are diagnostic "
                "counterexamples rather than candidate solutions."
            ),
        },
        {"id": "tradeoff_table", "type": "table", "layout": "full", "tableId": "chroma_tradeoff"},
        {
            "id": "bootstrap_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Conventional is close at one setting; adaptive uplift is not\n\n"
                "The best observed decoded and raw lower bounds versus conventional are "
                f"{_format_db(decoded_conventional_best)} and "
                f"{_format_db(raw_conventional_best)}, "
                "still below the strict pass line. The best lower bounds versus fixed and non-ASH "
                f"remain at least {adaptive_best_deficit:.3f} dB below zero. This separates three improvement needs: "
                "operator/reconstruction ceiling versus conventional, adaptive uplift versus the "
                "best fixed descriptor, and information retention versus the continuous non-ASH selector."
            ),
        },
        {"id": "bootstrap_chart", "type": "chart", "layout": "full", "chartId": "bootstrap_margins"},
        {
            "id": "domain_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Raw and decoded domains are the same primary movement\n\n"
                "Corresponding raw and decoded conventional lower bounds correlate at "
                f"**{float(unique_correlations['raw_vs_container_conventional_ci_low']):.4f}**; chroma "
                "displacements correlate at "
                f"**{float(unique_correlations['raw_vs_container_chroma_displacement']):.4f}**. "
                "Every decoded core failure has a matching raw failure. Writer and codec behavior "
                "still require regression testing after a fix, but this snapshot does not support "
                "a writer-first intervention."
            ),
        },
        {
            "id": "route_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Route quality is a composite symptom, not a ninth independent root\n\n"
                "Recomputing the reported route metric subpredicates shows no ringing or alias failures. Absolute "
                f"chroma fails on {direct_three_chroma_percent:.1f}% of direct-3/2 and "
                f"{direct_two_chroma_percent:.1f}% of direct-2x evaluations. Per-source "
                "Y floors fail only on the chroma-passing/severe-regression edge cases. Among the "
                "reported route metric predicates, those two families are the only failures in the "
                "bounded window. The complete evaluator still incorporates route coverage when "
                "deriving the canonical route-quality outcome."
            ),
        },
        {"id": "route_chart", "type": "chart", "layout": "full", "chartId": "route_failures"},
        {
            "id": "risk_state_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "state_sql",
            "body": (
                "## The best conventional settings erase a required risk-state branch\n\n"
                "The high alias/ringing-risk threshold block contains the best observed raw Y "
                "lower bound versus conventional, but every tested value from "
                f"{high_risk_minimum:,} through {high_risk_maximum:,} carries the canonical "
                "state-causality failure. Active state coordinate 6 "
                "has zero one-population "
                "on direct-3/2 throughout that range; direct-2x also reaches zero at the upper "
                "settings. This is a threshold-to-state coupling defect: preserving the required "
                "branch and improving Y cannot be treated as independent tuning objectives."
            ),
        },
        {"id": "risk_state_table", "type": "table", "layout": "full", "tableId": "risk_state_response"},
        {
            "id": "coordinate_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Coordinate response is concentrated in global anisotropy\n\n"
                "Within-sweep response spans are local sensitivity measures, not causal estimates. "
                "Global anisotropy produces by far the largest Y and chroma movement, but its "
                "chroma improvement crosses into severe luma loss. Among coordinate groups with at "
                f"least two distinct evaluated values in a sweep, {flat_chroma_count} show zero raw "
                f"and decoded chroma response, and {flat_conventional_y_count} show zero "
                "conventional-Y response. "
                "This flatness explains why additional threshold sweeps cannot supply missing "
                "plane-specific degrees of freedom."
            ),
        },
        {"id": "coordinate_table", "type": "table", "layout": "full", "tableId": "coordinate_response"},
        {
            "id": "search_domain_text",
            "type": "markdown",
            "layout": "full",
            "sourceId": "pre_error_sql",
            "body": (
                "## Known-illegal values consume search budget but do not explain quality\n\n"
                f"{constraint_failures} attempts repeat deterministic threshold-pair violations "
                f"across the two sweeps. {evaluation_failures} more values reach evaluation before "
                "failing fixed-bank or native "
                "control preconditions. These domains can be pruned before expensive evaluation. "
                "Doing so improves search efficiency and evidence clarity; it does not address the "
                "seven universal quality blockers."
            ),
        },
        {"id": "search_domain_table", "type": "table", "layout": "full", "tableId": "pre_evaluation_errors"},
        {
            "id": "scope_definitions",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Scope and metric definitions\n\n"
                f"This report covers development-ledger records 0–{cutoff} only. An evaluated "
                "attempt has a complete candidate evaluation and either feasible or infeasible "
                "status; constraint and evaluator failures are excluded from metric denominators. "
                "Y gates use the "
                "preregistered 95% paired source-asset bootstrap with 10,000 replicates and fixed "
                "seed 20260710; all six lower bounds must be strictly greater than 0 dB. Chroma "
                "passes at no more than 0.25 luma pixels absolute and no more than 0.1 pixels "
                "increase over conventional. No media or holdout payload was accessed."
            ),
        },
        {
            "id": "methodology",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## Every row was rederived from bound evidence\n\n"
                "The analyzer captured one unchanged complete ledger prefix, verified canonical "
                "NDJSON bytes and the complete record hash chain, reopened every unique evaluation "
                f"by declared size and SHA-256, recomputed {unique_evaluations} unique evaluation "
                f"summaries, and verified summary bindings plus feasibility results across {evaluated} "
                "evaluated attempts with the repository evaluator. Candidate-vector, summary, "
                "canonical-failure, and "
                "development-search-rank hashes were checked before SQL aggregation. Raw and "
                f"decoded domains remained separate throughout. All {repository_input_count} "
                "metadata-only repository input records match the recomputed run bundle; the "
                "consumed plan and tolerances match their captured source bytes."
            ),
        },
        {
            "id": "limitations",
            "type": "markdown",
            "layout": "full",
            "sourceId": "analysis_snapshot",
            "body": (
                "## The live run and causal boundary remain open\n\n"
                "The run was still active when this prefix was captured. Later sequences and the "
                "formal terminal artifact are outside this report. Correlations summarize jointly "
                "observed candidate movements and do not prove which code change causes them. "
                "Coordinate spans are conditional on each sweep's incumbent, so they do not rank "
                "a future structural search globally. The two chroma-passing observations are too "
                "few for a distributional claim; they are exact counterexamples only. The input-"
                "bundle hash is internally canonical and every bound metadata file matches, but "
                "the attempt ledger does not separately anchor that bundle hash; this is a "
                "consistency proof, not an independent bundle attestation."
            ),
        },
        {
            "id": "recommendations",
            "type": "markdown",
            "layout": "full",
            "sourceId": "code_map",
            "body": (
                "## Freeze plane-aware contracts before more calibration\n\n"
                "1. Define compiler-contract v2, locked-input v2, and binary format 1.2 while "
                "preserving exact 1.1 decode and serialization behavior.\n"
                "2. Carry one selected policy per route and explicit luma/chroma modes through "
                "compiler, independent validator, oracle, loader, and runtime.\n"
                "3. Decouple plane descriptor/weight/parameter decisions and preserve measured "
                "chroma edge confidence instead of reducing chroma state to one alignment bit.\n"
                "4. Re-test adaptive uplift versus fixed and non-ASH controls; then address any "
                "remaining operator-bank ceiling versus conventional.\n"
                "5. Reject known-illegal threshold pairs and control values in binding-only "
                "preflight before any expensive evaluation.\n"
                "6. Keep the preregistered thresholds unchanged. Preserve the live P06 terminal "
                "result, then rerun and close the complete G06 evidence transaction before P07."
            ),
        },
        {
            "id": "further_questions",
            "type": "markdown",
            "layout": "full",
            "body": (
                "## Questions the next evidence slice must answer\n\n"
                "- Can per-plane policy and mode choices enter the chroma-passing region without "
                "moving either raw Y lower bound below its current best?\n"
                "- Does carrying chroma edge confidence remove the displacement failure, or is a "
                "separate chroma operator subset required?\n"
                "- Which source/route cases keep fixed and non-ASH lower bounds negative after "
                "plane decoupling?\n"
                "- Can 1.1 compatibility fixtures remain byte-identical while 1.2 adds explicit "
                "route-policy and plane-mode metadata?"
            ),
        },
    ]

    manifest_sources = [
        {key: source[key] for key in ("id", "label", "path")}
        for source in source_specs
    ]
    artifact = {
        "surface": "report",
        "manifest": {
            "version": 1,
            "surface": "report",
            "title": TITLE,
            "description": "Bounded technical diagnostic of the open-development P06 calibration ledger.",
            "generatedAt": captured,
            "cards": [
                {
                    "id": "evaluated",
                    "description": f"Complete candidate evaluations through sequence {cutoff}.",
                    "dataset": "headline",
                    "sourceId": "headline_sql",
                    "metrics": [
                        {"label": "Evaluated candidates", "field": "evaluated_attempt_count", "format": "number"}
                    ],
                },
                {
                    "id": "feasible",
                    "description": "Candidates satisfying every development predicate.",
                    "dataset": "headline",
                    "sourceId": "headline_sql",
                    "metrics": [
                        {"label": "Feasible candidates", "field": "feasible_attempt_count", "format": "number"}
                    ],
                },
                {
                    "id": "core_nine",
                    "description": "Exact core-nine set among completed evaluations.",
                    "dataset": "headline",
                    "sourceId": "headline_sql",
                    "metrics": [
                        {"label": "Exact core-nine rate", "field": "core_nine_evaluated_fraction", "format": "percent"}
                    ],
                },
                {
                    "id": "pre_stops",
                    "description": "Constraint and evaluator failures before complete metrics.",
                    "dataset": "headline",
                    "sourceId": "headline_sql",
                    "metrics": [
                        {"label": "Pre-evaluation stops", "field": "pre_evaluation_stop_count", "format": "number"}
                    ],
                },
            ],
            "charts": [
                {
                    "id": "failure_frequency",
                    "title": "Canonical failure frequency",
                    "subtitle": f"Completed development evaluations through attempt {cutoff}; n={evaluated}",
                    "type": "horizontalBar",
                    "intent": "comparison",
                    "question": "Which canonical predicates persist across completed evaluations?",
                    "rationale": "Horizontal bars preserve long criterion labels and make persistent versus occasional failures immediately comparable.",
                    "comparisonContext": {"denominator": "completed evaluations", "grain": "canonical criterion", "unit": "%"},
                    "dataset": "failure_frequency",
                    "sourceId": "failure_sql",
                    "encodings": {
                        "x": {"field": "criterion", "type": "nominal", "label": "Criterion"},
                        "y": {"field": "evaluated_attempt_percent", "type": "quantitative", "label": "Failed evaluations", "unit": "%"},
                        "tooltip": [
                            {"field": "failed_attempt_count", "type": "quantitative", "label": "Failed attempts"},
                            {"field": "evaluated_attempt_count", "type": "quantitative", "label": "Evaluated attempts"},
                        ],
                    },
                    "valueFormat": "number",
                    "unit": "%",
                    "layout": "full",
                    "labels": {"values": "auto"},
                    "palette": {"kind": "sequential", "name": "blue"},
                    "settings": {"sort": "descending", "categoryLabelPolicy": "wrap"},
                    "surface": {"surface": "export", "viewMode": "both"},
                },
                {
                    "id": "luma_chroma_tradeoff",
                    "title": "Raw luma lower bound and chroma displacement",
                    "subtitle": (
                        "One point per unique evaluation artifact; repeated cache outcomes omitted"
                    ),
                    "type": "scatter",
                    "intent": "relationship",
                    "question": "Do evaluated candidates jointly approach the luma and chroma pass region?",
                    "rationale": "A scatter preserves candidate-level variation and exposes the sparse chroma-passing counterexamples without averaging away their luma deficit.",
                    "comparisonContext": {"grain": "unique evaluation artifact", "baseline": "conventional Y and 0.25-pixel chroma threshold"},
                    "dataset": "candidate_metric_matrix",
                    "sourceId": "candidate_sql",
                    "encodings": {
                        "x": {"field": "engine_raw_chroma_pixels", "type": "quantitative", "label": "Raw maximum chroma displacement", "unit": "pixels"},
                        "y": {"field": "engine_raw_conventional_ci_low_db", "type": "quantitative", "label": "Raw Y 95% CI lower bound vs conventional", "unit": "dB"},
                        "label": {"field": "sequence", "type": "nominal", "label": "Attempt"},
                        "tooltip": [
                            {"field": "coordinate", "type": "nominal", "label": "Coordinate"},
                            {"field": "value_text", "type": "nominal", "label": "Value"},
                            {"field": "canonical_failure_count", "type": "quantitative", "label": "Failure count"},
                        ],
                    },
                    "layout": "full",
                    "palette": {"kind": "sequential", "name": "blue"},
                    "referenceLines": [
                        {"axis": "x", "value": 0.25, "label": "Chroma limit", "color": "neutral", "lineStyle": "dashed"},
                        {"axis": "y", "value": 0.0, "label": "Y pass line", "color": "neutral", "lineStyle": "dashed"},
                    ],
                    "surface": {"surface": "export", "viewMode": "both"},
                },
                {
                    "id": "bootstrap_margins",
                    "title": "Best observed Y-bootstrap lower-bound margins",
                    "subtitle": "Best result across completed candidates; pass requires a value above 0 dB",
                    "type": "horizontalBar",
                    "intent": "comparison",
                    "question": "How far does the best candidate remain from each strict Y pass threshold?",
                    "rationale": "Signed horizontal bars compare six same-unit lower-bound deficits against a shared zero reference without mixing scales.",
                    "comparisonContext": {"baseline": "strict 0 dB lower-bound threshold", "grain": "domain and control comparison", "unit": "dB"},
                    "dataset": "bootstrap_margin",
                    "sourceId": "bootstrap_sql",
                    "encodings": {
                        "x": {"field": "label", "type": "nominal", "label": "Domain and baseline"},
                        "y": {"field": "best_margin_db", "type": "quantitative", "label": "Best margin", "unit": "dB"},
                        "tooltip": [
                            {"field": "evaluated_attempt_count", "type": "quantitative", "label": "Evaluated attempts"}
                        ],
                    },
                    "valueFormat": "number",
                    "unit": "dB",
                    "layout": "full",
                    "labels": {"values": "all"},
                    "palette": {"kind": "sequential", "name": "orange"},
                    "referenceLines": [
                        {"axis": "y", "value": 0.0, "label": "Pass line", "color": "neutral", "lineStyle": "solid"}
                    ],
                    "settings": {"sort": "descending", "categoryLabelPolicy": "wrap"},
                    "surface": {"surface": "export", "viewMode": "both"},
                },
                {
                    "id": "route_failures",
                    "title": "Nonzero route-quality predicate failure rates",
                    "subtitle": f"Completed evaluations through attempt {cutoff}; predicates with zero failures omitted",
                    "type": "horizontalBar",
                    "intent": "comparison",
                    "question": "Which route-level subpredicates account for the composite route-quality failure?",
                    "rationale": (
                        f"{route_nonzero_count} nonzero categories expose the dominant chroma "
                        "predicate and rare per-source Y floor without clutter from "
                        f"{route_zero_count} all-pass categories."
                    ),
                    "comparisonContext": {"denominator": "completed evaluations per route", "grain": "route predicate", "unit": "%"},
                    "dataset": "route_failures",
                    "sourceId": "route_sql",
                    "encodings": {
                        "x": {"field": "label", "type": "nominal", "label": "Route predicate"},
                        "y": {"field": "failed_attempt_percent", "type": "quantitative", "label": "Failed evaluations", "unit": "%"},
                        "tooltip": [
                            {"field": "failed_attempt_count", "type": "quantitative", "label": "Failed attempts"},
                            {"field": "evaluated_attempt_count", "type": "quantitative", "label": "Evaluated attempts"},
                        ],
                    },
                    "valueFormat": "number",
                    "unit": "%",
                    "layout": "full",
                    "labels": {"values": "all"},
                    "palette": {"kind": "sequential", "name": "blue"},
                    "settings": {"sort": "descending", "categoryLabelPolicy": "wrap"},
                    "surface": {"surface": "export", "viewMode": "both"},
                },
            ],
            "tables": [
                {
                    "id": "chroma_tradeoff",
                    "title": "Chroma-passing candidate counterexamples",
                    "subtitle": "Both domains at or below 0.25 pixels; exact audit values",
                    "dataset": "chroma_tradeoff",
                    "sourceId": "tradeoff_sql",
                    "defaultSort": {"field": "sequence", "direction": "asc"},
                    "density": "spacious",
                    "layout": "full",
                    "columns": [
                        {"field": "sequence", "label": "Attempt", "format": "number"},
                        {"field": "value_text", "label": "Anisotropy q12", "type": "text"},
                        {"field": "engine_raw_chroma_pixels", "label": "Raw chroma px", "format": "number"},
                        {"field": "engine_raw_conventional_ci_low_db", "label": "Raw Y CI low dB", "format": "number"},
                        {"field": "canonical_failure_count", "label": "Failures", "format": "number"},
                    ],
                },
                {
                    "id": "coordinate_response",
                    "title": "Coordinate response audit",
                    "subtitle": "Maximum within-sweep spans; descriptive local sensitivity",
                    "dataset": "coordinate_response",
                    "sourceId": "coordinate_sql",
                    "defaultSort": {"field": "response_rank", "direction": "asc"},
                    "density": "dense",
                    "layout": "full",
                    "columns": [
                        {"field": "response_rank", "label": "Rank", "format": "number"},
                        {"field": "coordinate", "label": "Coordinate", "type": "text"},
                        {
                            "field": "evaluated_attempt_count",
                            "label": "Evaluated, all sweeps",
                            "format": "number",
                        },
                        {
                            "field": "qualified_sweep_count",
                            "label": "Sweeps with 2+ values",
                            "format": "number",
                        },
                        {"field": "minimum_failure_count", "label": "Min failures", "format": "number"},
                        {"field": "core_nine_percent", "label": "Core-nine %", "format": "number"},
                        {"field": "engine_raw_conventional_ci_span_db", "label": "Raw Y span dB", "format": "number"},
                        {"field": "engine_raw_chroma_span_pixels", "label": "Raw chroma span px", "format": "number"},
                    ],
                },
                {
                    "id": "risk_state_response",
                    "title": "Risk threshold and active state coordinate 6",
                    "subtitle": "Exact route populations within the high-risk-threshold coordinate blocks",
                    "dataset": "risk_state_response",
                    "sourceId": "state_sql",
                    "defaultSort": {"field": "sequence", "direction": "asc"},
                    "density": "dense",
                    "layout": "full",
                    "columns": [
                        {"field": "sequence", "label": "Attempt", "format": "number"},
                        {"field": "sweep", "label": "Sweep", "format": "number"},
                        {"field": "value_text", "label": "High-risk threshold", "type": "text"},
                        {"field": "route", "label": "Route", "type": "text"},
                        {"field": "one_count", "label": "Coordinate-6 one count", "format": "number"},
                        {"field": "zero_count", "label": "Coordinate-6 zero count", "format": "number"},
                        {
                            "field": "engine_raw_conventional_ci_low_db",
                            "label": "Raw Y CI low dB",
                            "format": "number",
                        },
                        {
                            "field": "state_causality_failed",
                            "label": "State causality failed",
                            "format": "number",
                        },
                    ],
                },
                {
                    "id": "pre_evaluation_errors",
                    "title": "Pre-evaluation rejection groups",
                    "subtitle": "Constraint and evaluator failures through the bounded cutoff",
                    "dataset": "pre_evaluation_errors",
                    "sourceId": "pre_error_sql",
                    "defaultSort": {"field": "attempt_count", "direction": "desc"},
                    "density": "spacious",
                    "layout": "full",
                    "columns": [
                        {"field": "status", "label": "Status", "type": "text"},
                        {"field": "error", "label": "Recorded reason", "type": "text"},
                        {"field": "attempt_count", "label": "Attempts", "format": "number"},
                    ],
                },
            ],
            "sources": manifest_sources,
            "blocks": blocks,
        },
        "snapshot": {
            "version": 1,
            "generatedAt": captured,
            "status": "partial",
            "datasets": report_datasets,
            "accessIssues": [
                {
                    "id": "live_run_incomplete",
                    "scope": "report",
                    "sourceId": "live_ledger",
                    "message": (
                        f"P06 was still active at capture. Sequences after {cutoff} and the "
                        "formal terminal result are outside this bounded snapshot."
                    ),
                }
            ],
        },
        "sources": source_specs,
    }
    _require(
        artifact["manifest"]["blocks"][0]["body"] == f"# {TITLE}",
        "visible and manifest titles differ",
    )
    return artifact


def _parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    analysis_file, analysis_path = resolve_analysis_source(arguments.analysis)
    analysis = json.loads(analysis_file.read_text(encoding="utf-8"))
    artifact = build_artifact(analysis, analysis_path=analysis_path)
    payload = _canonical_json_bytes(artifact) + b"\n"
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        arguments.output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o644,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            _require(written > 0, "artifact output write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    print(
        json.dumps(
            {
                "artifact_sha256": hashlib.sha256(payload).hexdigest(),
                "output": str(arguments.output),
                "status": "pass",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
