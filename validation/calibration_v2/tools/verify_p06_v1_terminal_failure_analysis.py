#!/usr/bin/env python3
"""Verify the additive V1 P06 terminal-failure preservation artifacts.

The default mode reads only tracked JSON artifacts.  Passing ``--failed-root``
adds an explicit full verification of the preserved development-only ``.failed``
tree using the P06 release-evidence closure digest implementation.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import sys
from typing import Mapping, Sequence

from jsonschema import Draft202012Validator


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.release_evidence import (
    P06EvidenceClosureError,
    _directory_tree,
    _read_file,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes

RECEIPT_RELATIVE = Path(
    "analysis/ash-failure-patterns/evidence/"
    "p06-v1-terminal-failure-analysis-receipt-v1.json"
)
SCHEMA_RELATIVE = Path(
    "validation/calibration_v2/schemas/"
    "p06-v1-terminal-failure-analysis-receipt-v1.schema.json"
)
TERMINAL_ANALYSIS_RELATIVE = Path(
    "analysis/ash-failure-patterns/evidence/"
    "p06-current-source-terminal-failure-v1.json"
)
BOUNDED_PREDECESSOR_RELATIVE = Path(
    "analysis/ash-failure-patterns/evidence/"
    "p06-current-source-snapshot-final.json"
)

TERMINAL_ROOT_ID = (
    "Artifacts/ASH/20260714-current-source-de4feb30-9c90-4706-aaa7-c6dd82cac1fb/"
    "p06-current-source-r1/support-calibration-run/p06-current-source-r1.failed"
)
ZERO_SHA256 = "0" * 64

EXPECTED_TERMINAL_ANALYSIS = {
    "path": TERMINAL_ANALYSIS_RELATIVE.as_posix(),
    "file_sha256": "4f148700ca265eab6097dbf58322aa319cfbefe4926ecffb3b1905d667ac14df",
    "size_bytes": 919_950,
    "self_hash": {
        "field": "analysis_sha256",
        "sha256": "5033764c4532704af6a6cd8ff6c9d87100780066662eb7f28efd0e29500f134e",
    },
    "schema_version": "1.0.0",
    "artifact_kind": "p06_failure_pattern_analysis",
    "analysis_repository_head": "f02fc74e97c0ba6f68b79110e15e8a5bd621ea48",
    "bound_repository_head": "30d9456b4464965bf38c624b89a234bd07f303fc",
    "cutoff_sequence": 1008,
    "cutoff_record_sha256": "ec6af3a1a9dc476809cf0e645ec605f7eb6c9afc5cda5b5172aa79f92f4a2683",
}

EXPECTED_BOUNDED_PREDECESSOR = {
    "path": BOUNDED_PREDECESSOR_RELATIVE.as_posix(),
    "file_sha256": "4816f2af0672d08e6d05f359dbdcce1c8f091d114c50756c63853044c6888e4d",
    "size_bytes": 270_485,
    "self_hash": {
        "field": "analysis_sha256",
        "sha256": "efde38c5c17c7291b15e093b8ae342c6f5df0d62b2bbfc6f9ca6a25eb75b9799",
    },
    "cutoff_sequence": 240,
    "ledger_prefix_size_bytes": 919_520,
    "ledger_prefix_sha256": "c7e169968023980111f454e6f0da780a9e1e5b77d942681c0bb29d7519999127",
    "cutoff_record_sha256": "a3017fb8c4cf4d8dcfe072baa785187496878bcdc52e664ec6838f5607560197",
    "terminal_prefix_match_verified": True,
}

EXPECTED_CORE_ARTIFACTS = [
    {
        "role": "transaction_marker",
        "path": ".calibration-transaction.json",
        "sha256": "bd2783ed78ae2040fe328159c1df864087c74fe52e03b9b95d7c711ab651267f",
        "size_bytes": 308,
        "self_hash": {
            "field": "record_sha256",
            "sha256": "490cf8ed78589b92a019cfdb26aa7acda8c6d36ba0bdcca33806716900f91d30",
        },
    },
    {
        "role": "attempt_ledger",
        "path": "attempts.ndjson",
        "sha256": "b8741071aab173dd6bc33d8f6b2e06eebad2efd27d8398598fdff982f47d4591",
        "size_bytes": 3_875_164,
        "self_hash": None,
    },
    {
        "role": "failure_envelope",
        "path": "failure.json",
        "sha256": "77e0641b1973433ac6de7b919a56c2786e06cb00dfac7739177bef0ba647155a",
        "size_bytes": 415,
        "self_hash": None,
    },
    {
        "role": "input_bindings",
        "path": "input-bindings.json",
        "sha256": "1e8b96a0d8a3b95782c6eaf3f4de13fed596f050ea6e068a2029d11f2f0b412b",
        "size_bytes": 7_796,
        "self_hash": {
            "field": "bundle_sha256",
            "sha256": "d25ec3616eb67b3308144472906b2d7b692f1c6471ddf24cc2afa5fc20ac2b63",
        },
    },
    {
        "role": "stale_transaction_recovery",
        "path": (
            "stale-transaction-recoveries/"
            "f64e8a96-2b9c-48a3-9e41-4408480d4181.json"
        ),
        "sha256": "17270582a77cc82469b905a1b23782f3aed333a612295a958043055e6eb3e4ad",
        "size_bytes": 612,
        "self_hash": {
            "field": "record_sha256",
            "sha256": "df9318e772db3b5b25602c0911047b470054b8d0dbecf270f18adfa943583a11",
        },
    },
]

EXPECTED_FAILURE_ENVELOPE = {
    "schema_version": "1.0.0",
    "artifact_kind": "p06_calibration_failure",
    "run_id": "p06-current-source-r1",
    "error_type": "CalibrationError",
    "error": "coordinate search produced no development-feasible terminal vector",
    "attempt_count": 1009,
    "attempt_ledger_sha256": "b8741071aab173dd6bc33d8f6b2e06eebad2efd27d8398598fdff982f47d4591",
    "holdout_accessed": False,
    "release_locks_written": False,
}

EXPECTED_ARCHIVE = {
    "root_path": TERMINAL_ROOT_ID,
    "digest_contract": {
        "implementation": "validation.calibration_v2.release_evidence._directory_tree",
        "walk_order": (
            "top_down; sorted directories and files; directory rows precede file rows "
            "at each visited directory"
        ),
        "row_encoding": (
            "relative POSIX path, entry kind, byte size, and SHA-256 for regular files"
        ),
        "hash_input": (
            "canonical sorted-key compact UTF-8 JSON row array with preserved array order "
            "and no trailing LF"
        ),
    },
    "tree": {
        "digest_mode": "p06_release_evidence_directory_tree_v1",
        "sha256": "5d1f22b2467a5caa83b5b7b499389e6577d244721af466c57989d23513b22d76",
        "size_bytes": 3_340_628_824,
        "file_count": 818,
        "directory_count": 3,
    },
    "evaluation_tree": {
        "digest_mode": "p06_release_evidence_directory_tree_v1",
        "sha256": "e80e3965797ff3c16aad7e1d9addc7cded70402b9f1b6bf91046168f86205952",
        "size_bytes": 3_335_878_925,
        "file_count": 570,
        "directory_count": 0,
    },
    "control_selection_tree": {
        "digest_mode": "p06_release_evidence_directory_tree_v1",
        "sha256": "54f8540651990d8e5e9a181f0b48aac1a898711f654258069fb905ac93db1b31",
        "size_bytes": 865_604,
        "file_count": 243,
        "directory_count": 0,
    },
    "core_artifacts": EXPECTED_CORE_ARTIFACTS,
    "failure_envelope": EXPECTED_FAILURE_ENVELOPE,
    "transaction_marker": {
        "artifact_kind": "p06_calibration_run_transaction",
        "transaction_state": "in_progress",
        "record_sha256": "490cf8ed78589b92a019cfdb26aa7acda8c6d36ba0bdcca33806716900f91d30",
    },
    "input_bundle_sha256": "d25ec3616eb67b3308144472906b2d7b692f1c6471ddf24cc2afa5fc20ac2b63",
    "ledger_closure": {
        "canonical_ndjson": True,
        "sequence_continuous": True,
        "record_hash_chain_valid": True,
        "first_sequence": 0,
        "last_sequence": 1008,
        "genesis_previous_record_sha256": ZERO_SHA256,
        "tail_previous_record_sha256": "80f03c50cbec4537556c1353fb45955d6acc9470074d841368a40b3e2a48df18",
        "tail_record_sha256": "ec6af3a1a9dc476809cf0e645ec605f7eb6c9afc5cda5b5172aa79f92f4a2683",
        "attempt_count": 1009,
    },
}

EXPECTED_TERMINAL_FINDINGS = {
    "status_counts": {
        "infeasible": 923,
        "constraint_failure": 74,
        "evaluation_failure": 12,
        "feasible": 0,
    },
    "search": {
        "fresh_evaluation_count": 570,
        "cache_hit_count": 353,
        "sweep_count": 6,
        "neighbors_per_sweep": 168,
        "selected_moves_by_sweep": [23, 11, 5, 3, 2, 0],
        "selected_move_count": 44,
        "selected_moves_changing_canonical_failures": 0,
        "selected_moves_changing_summary": 39,
        "selected_moves_without_summary_change": 5,
    },
    "final_incumbent": {
        "candidate_vector_sha256": "1a48ce003892adfb6c7ec019a72e59766734585b400ee9a169b9ccc56bb4abda",
        "ledger_observation_count": 81,
        "tail_candidate_vector_sha256": "058fbcc5403beefeef8f2e7a0e584a629f2cc4aac1420798f93b139e32666e81",
        "tail_candidate_is_incumbent": False,
    },
    "failure_pattern_counts": {
        "attempt_weighted": [864, 30, 12, 11, 6],
        "unique_evaluation": [521, 25, 10, 9, 5],
    },
    "route_failure_equivalence": {
        "criterion": (
            "aggregate route failure equals absolute chroma failure or severe per-route "
            "asset Y failure within this run"
        ),
        "attempt_weighted": {
            "observation_count": 923,
            "composite_failure_count": 923,
            "chroma_or_route_y_failure_count": 923,
            "equivalence_disagreement_count": 0,
            "direct_2x": {
                "pass": 6,
                "chroma_only": 899,
                "route_y_only": 13,
                "both": 5,
            },
            "direct_3_over_2": {
                "pass": 0,
                "chroma_only": 911,
                "route_y_only": 12,
                "both": 0,
            },
        },
        "unique_evaluation": {
            "observation_count": 570,
            "composite_failure_count": 570,
            "chroma_or_route_y_failure_count": 570,
            "equivalence_disagreement_count": 0,
            "direct_2x": {
                "pass": 5,
                "chroma_only": 550,
                "route_y_only": 11,
                "both": 4,
            },
            "direct_3_over_2": {
                "pass": 0,
                "chroma_only": 560,
                "route_y_only": 10,
                "both": 0,
            },
        },
    },
    "raw_decoded_indicator_equivalence": {
        "paired_criterion_count": 6,
        "attempt_weighted_observation_count": 923,
        "unique_evaluation_observation_count": 570,
        "attempt_weighted_disagreement_count": 0,
        "unique_evaluation_disagreement_count": 0,
    },
    "binary_associations": {
        "method": "Pearson phi coefficient for binary failure indicators",
        "causal_interpretation_allowed": False,
        "attempt_weighted": {
            "observation_count": 923,
            "values": [
                {
                    "left": "severe_category_regression",
                    "right": "severe_asset_regression",
                    "contingency_00_01_10_11": [894, 0, 11, 18],
                    "phi": 0.7830359896078513,
                },
                {
                    "left": "chroma_displacement",
                    "right": "severe_asset_regression",
                    "contingency_00_01_10_11": [0, 12, 905, 6],
                    "phi": -0.8138033468248516,
                },
                {
                    "left": "chroma_displacement",
                    "right": "severe_category_regression",
                    "contingency_00_01_10_11": [0, 12, 894, 17],
                    "phi": -0.637237309027179,
                },
            ],
        },
        "unique_evaluation": {
            "observation_count": 570,
            "values": [
                {
                    "left": "severe_category_regression",
                    "right": "severe_asset_regression",
                    "contingency_00_01_10_11": [546, 0, 9, 15],
                    "phi": 0.7841331933191357,
                },
                {
                    "left": "chroma_displacement",
                    "right": "severe_asset_regression",
                    "contingency_00_01_10_11": [0, 10, 555, 5],
                    "phi": -0.8128433340529315,
                },
                {
                    "left": "chroma_displacement",
                    "right": "severe_category_regression",
                    "contingency_00_01_10_11": [0, 10, 546, 14],
                    "phi": -0.6373774391990982,
                },
            ],
        },
    },
    "controlled_coordinates": {
        "coordinate_count": 42,
        "canonical_failure_changing_count": 3,
        "canonical_failure_changing_coordinates": [
            "alias_or_ringing_risk_high_unorm15",
            "anisotropy_strength_q12",
            "direct_2x_luma_coordinate_policy",
        ],
        "summary_inert_count": 7,
        "summary_inert_coordinates": [
            "chroma_edge_confidence_unorm15",
            "confidence_threshold_unorm16",
            "edge_present_high_unorm15",
            "edge_present_low_unorm15",
            "minimum_anisotropic_magnitude_unorm15",
            "regularization_step_q12",
            "support_radius_step_q8_8",
        ],
    },
    "improvement_targets": [
        "plane_specific_luma_chroma_decoupling",
        "adaptive_uplift_against_fixed_and_non_ash_controls",
        "risk_threshold_state_causality_decoupling",
        "invalid_search_domain_preflight",
    ],
}

EXPECTED_SOURCE_SCOPE = {
    "phase": "P06",
    "configuration_generation": "v1_shared_bank",
    "split": "development",
    "run_id": "p06-current-source-r1",
    "validation_accessed": False,
    "holdout_accessed": False,
    "media_payload_accessed": False,
}

EXPECTED_CAUSAL_BOUNDARY = {
    "predicate_equivalence": "run_bounded_logical_equivalence_not_root_cause",
    "correlations": "descriptive_association_only",
    "controlled_coordinates": (
        "conditional_within_sweep_effect_not_general_causal_estimate"
    ),
    "code_path_mapping": "implementation_hypothesis_only",
}

EXPECTED_CLAIMS = {
    "terminal_v1_failure_preserved": True,
    "full_development_replay_verified": True,
    "bounded_predecessor_is_exact_terminal_prefix": True,
    "winner_selected": False,
    "formal_g06_result_established": False,
    "release_authorized": False,
    "v2_fix_validated": False,
    "implementation_root_cause_established": False,
    "writer_root_cause_established": False,
}

EXPECTED_ANALYSIS_CORRELATIONS = {
    "causal_interpretation_allowed": False,
    "method": "Pearson product-moment correlation",
    "observation_grains": {
        "attempt_weighted": "candidate attempt",
        "unique_evaluation": "unique evaluation artifact",
    },
    "values": {
        "attempt_weighted": {
            "raw_conventional_ci_low_vs_chroma_displacement": 0.8872962692984727,
            "raw_vs_container_chroma_displacement": 0.9961616394816838,
            "raw_vs_container_conventional_ci_low": 0.9998347999663962,
        },
        "unique_evaluation": {
            "raw_conventional_ci_low_vs_chroma_displacement": 0.8877816043863597,
            "raw_vs_container_chroma_displacement": 0.9964756624926615,
            "raw_vs_container_conventional_ci_low": 0.999838632249215,
        },
    },
}


class TerminalFailureVerificationError(ValueError):
    """Raised when terminal preservation evidence differs from its binding."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise TerminalFailureVerificationError(message)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _reject_duplicate_pairs(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise TerminalFailureVerificationError(f"duplicate JSON member: {key}")
        value[key] = item
    return value


def _reject_nonfinite(token: str) -> object:
    raise TerminalFailureVerificationError(f"non-finite JSON number: {token}")


def _strict_json(payload: bytes, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TerminalFailureVerificationError(f"{label} is not strict JSON") from error
    _require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def _read_regular(path: Path, label: str) -> bytes:
    try:
        return _read_file(path)
    except (OSError, P06EvidenceClosureError) as error:
        raise TerminalFailureVerificationError(f"{label} is not a stable regular file") from error


def _canonical_document(path: Path, label: str) -> tuple[bytes, Mapping[str, object]]:
    payload = _read_regular(path, label)
    document = _strict_json(payload, label)
    _require(
        payload == canonical_json_bytes(document) + b"\n",
        f"{label} is not canonical JSON followed by one LF",
    )
    return payload, document


def _verify_self_hash(
    document: Mapping[str, object],
    *,
    field: str,
    expected: str,
    label: str,
) -> None:
    body = dict(document)
    observed = body.pop(field, None)
    _require(observed == expected, f"{label} embedded self-hash differs")
    _require(_sha256(canonical_json_bytes(body)) == expected, f"{label} self-hash is invalid")


def _safe_repository_path(repository_root: Path, relative: str) -> Path:
    parsed = PurePosixPath(relative)
    _require(
        bool(relative)
        and not parsed.is_absolute()
        and parsed.as_posix() == relative
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"unsafe repository-relative path: {relative!r}",
    )
    return repository_root.joinpath(*parsed.parts)


def _verify_file_binding(
    repository_root: Path,
    binding: Mapping[str, object],
    *,
    label: str,
) -> tuple[bytes, Mapping[str, object]]:
    path = _safe_repository_path(repository_root, str(binding["path"]))
    payload, document = _canonical_document(path, label)
    _require(len(payload) == binding["size_bytes"], f"{label} size differs")
    _require(_sha256(payload) == binding["file_sha256"], f"{label} file hash differs")
    self_hash = binding["self_hash"]
    _require(isinstance(self_hash, dict), f"{label} self-hash binding is absent")
    _verify_self_hash(
        document,
        field=str(self_hash["field"]),
        expected=str(self_hash["sha256"]),
        label=label,
    )
    return payload, document


def _verify_fast_semantics(
    receipt: Mapping[str, object],
    terminal_analysis: Mapping[str, object],
    predecessor: Mapping[str, object],
) -> None:
    _require(receipt["source_scope"] == EXPECTED_SOURCE_SCOPE, "source scope differs")
    _require(receipt["terminal_analysis"] == EXPECTED_TERMINAL_ANALYSIS, "terminal analysis binding differs")
    _require(receipt["terminal_archive"] == EXPECTED_ARCHIVE, "terminal archive binding differs")
    _require(receipt["bounded_predecessor"] == EXPECTED_BOUNDED_PREDECESSOR, "bounded predecessor binding differs")
    _require(receipt["terminal_findings"] == EXPECTED_TERMINAL_FINDINGS, "terminal findings differ")
    _require(receipt["causal_boundary"] == EXPECTED_CAUSAL_BOUNDARY, "causal boundary differs")
    _require(receipt["claims"] == EXPECTED_CLAIMS, "terminal claims differ")

    scope = terminal_analysis.get("scope")
    validation = terminal_analysis.get("validation")
    headline = terminal_analysis.get("headline")
    datasets = terminal_analysis.get("datasets")
    _require(isinstance(scope, dict), "terminal analysis scope is absent")
    _require(isinstance(validation, dict), "terminal analysis validation is absent")
    _require(isinstance(headline, dict), "terminal analysis headline is absent")
    _require(isinstance(datasets, dict), "terminal analysis datasets are absent")
    _require(
        terminal_analysis.get("schema_version") == EXPECTED_TERMINAL_ANALYSIS["schema_version"]
        and terminal_analysis.get("artifact_kind") == EXPECTED_TERMINAL_ANALYSIS["artifact_kind"],
        "terminal analysis identity differs",
    )
    _require(
        scope.get("analysis_repository_head") == EXPECTED_TERMINAL_ANALYSIS["analysis_repository_head"]
        and scope.get("bound_repository_head") == EXPECTED_TERMINAL_ANALYSIS["bound_repository_head"]
        and scope.get("cutoff_sequence") == 1008
        and scope.get("cutoff_record_sha256") == EXPECTED_TERMINAL_ANALYSIS["cutoff_record_sha256"]
        and scope.get("ledger_prefix_sha256") == EXPECTED_FAILURE_ENVELOPE["attempt_ledger_sha256"]
        and scope.get("input_bundle_sha256") == EXPECTED_ARCHIVE["input_bundle_sha256"]
        and scope.get("split") == "development"
        and scope.get("holdout_accessed") is False
        and scope.get("media_payload_accessed") is False,
        "terminal analysis scope differs",
    )
    _require(
        validation.get("attempt_count") == 1009
        and validation.get("evaluation_attempt_count") == 923
        and validation.get("unique_evaluation_file_count") == 570
        and validation.get("summary_verification_count") == 923
        and all(
            validation.get(field) is True
            for field in (
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
        ),
        "terminal analysis verification summary differs",
    )
    _require(
        headline.get("attempt_count") == 1009
        and headline.get("evaluated_attempt_count") == 923
        and headline.get("feasible_attempt_count") == 0
        and headline.get("constraint_failure_count") == 74
        and headline.get("evaluation_failure_count") == 12
        and headline.get("cache_hit_count") == 353,
        "terminal analysis headline differs",
    )
    _require(
        terminal_analysis.get("correlations") == EXPECTED_ANALYSIS_CORRELATIONS,
        "terminal analysis correlations differ",
    )
    failure_rows = datasets.get("failure_set_frequency")
    _require(isinstance(failure_rows, list), "terminal failure-frequency dataset is absent")
    _require(
        [row.get("attempt_count") for row in failure_rows]
        == EXPECTED_TERMINAL_FINDINGS["failure_pattern_counts"]["attempt_weighted"],
        "terminal attempt-weighted failure patterns differ",
    )

    predecessor_scope = predecessor.get("scope")
    _require(isinstance(predecessor_scope, dict), "bounded predecessor scope is absent")
    _require(
        predecessor_scope.get("cutoff_sequence") == 240
        and predecessor_scope.get("ledger_size_bytes") == 919_520
        and predecessor_scope.get("ledger_prefix_sha256")
        == EXPECTED_BOUNDED_PREDECESSOR["ledger_prefix_sha256"]
        and predecessor_scope.get("cutoff_record_sha256")
        == EXPECTED_BOUNDED_PREDECESSOR["cutoff_record_sha256"]
        and predecessor_scope.get("holdout_accessed") is False
        and predecessor_scope.get("media_payload_accessed") is False,
        "bounded predecessor scope differs",
    )


def verify_fast(
    repository_root: Path = REPOSITORY_ROOT,
    receipt_path: Path | None = None,
) -> Mapping[str, object]:
    """Verify only the checked-in terminal receipt and its tracked JSON sources."""

    repository_root = repository_root.resolve(strict=True)
    receipt_path = receipt_path or repository_root / RECEIPT_RELATIVE
    receipt_payload, receipt = _canonical_document(receipt_path, "terminal receipt")
    schema_payload = _read_regular(repository_root / SCHEMA_RELATIVE, "terminal receipt schema")
    schema = _strict_json(schema_payload, "terminal receipt schema")
    Draft202012Validator.check_schema(schema)
    errors = sorted(
        Draft202012Validator(schema).iter_errors(receipt),
        key=lambda error: list(error.absolute_path),
    )
    _require(
        not errors,
        "terminal receipt schema validation failed: "
        + "; ".join(error.message for error in errors),
    )
    receipt_hash = receipt.get("receipt_sha256")
    _require(isinstance(receipt_hash, str), "terminal receipt self-hash is absent")
    _verify_self_hash(
        receipt,
        field="receipt_sha256",
        expected=receipt_hash,
        label="terminal receipt",
    )
    _require(b"/Users/" not in receipt_payload, "terminal receipt contains an absolute user path")

    terminal_payload, terminal_analysis = _verify_file_binding(
        repository_root,
        receipt["terminal_analysis"],
        label="terminal analysis",
    )
    predecessor_payload, predecessor = _verify_file_binding(
        repository_root,
        receipt["bounded_predecessor"],
        label="bounded predecessor",
    )
    _verify_fast_semantics(receipt, terminal_analysis, predecessor)
    return {
        "mode": "fast_tracked_artifacts",
        "status": "pass",
        "receipt_sha256": receipt_hash,
        "receipt_file_sha256": _sha256(receipt_payload),
        "terminal_analysis_file_sha256": _sha256(terminal_payload),
        "bounded_predecessor_file_sha256": _sha256(predecessor_payload),
    }


def _strict_ndjson(payload: bytes) -> list[Mapping[str, object]]:
    _require(payload.endswith(b"\n"), "attempt ledger lacks its terminal LF")
    lines = payload.splitlines(keepends=True)
    records: list[Mapping[str, object]] = []
    previous = ZERO_SHA256
    for sequence, encoded in enumerate(lines):
        _require(encoded.endswith(b"\n"), "attempt ledger contains a partial line")
        line = encoded[:-1]
        record = _strict_json(line, f"attempt ledger record {sequence}")
        _require(
            encoded == canonical_json_bytes(record) + b"\n",
            f"attempt ledger record {sequence} is not canonical",
        )
        body = dict(record)
        claimed = body.pop("record_sha256", None)
        _require(
            record.get("sequence") == sequence
            and record.get("previous_record_sha256") == previous
            and claimed == _sha256(canonical_json_bytes(body)),
            f"attempt ledger hash chain differs at sequence {sequence}",
        )
        previous = str(claimed)
        records.append(record)
    return records


def _directory_count(path: Path) -> int:
    count = 0
    for current_name, directory_names, file_names in os.walk(
        path,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            child = current / name
            before = os.stat(child, follow_symlinks=False)
            _require(
                not stat.S_ISLNK(before.st_mode) and stat.S_ISDIR(before.st_mode),
                "failed tree contains a symbolic or non-directory child",
            )
            count += 1
        for name in file_names:
            before = os.stat(current / name, follow_symlinks=False)
            _require(
                not stat.S_ISLNK(before.st_mode) and stat.S_ISREG(before.st_mode),
                "failed tree contains a symbolic or non-regular file",
            )
    return count


def _observed_tree_binding(path: Path) -> Mapping[str, object]:
    try:
        file_count, size_bytes, digest = _directory_tree(path)
    except (OSError, P06EvidenceClosureError) as error:
        raise TerminalFailureVerificationError("failed tree digest could not be derived") from error
    return {
        "digest_mode": "p06_release_evidence_directory_tree_v1",
        "sha256": digest,
        "size_bytes": size_bytes,
        "file_count": file_count,
        "directory_count": _directory_count(path),
    }


def _core_artifact_path(failed_root: Path, binding: Mapping[str, object]) -> Path:
    relative = str(binding["path"])
    parsed = PurePosixPath(relative)
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == relative
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"unsafe core artifact path: {relative!r}",
    )
    return failed_root.joinpath(*parsed.parts)


def _verify_core_artifacts(
    failed_root: Path,
) -> Mapping[str, tuple[bytes, Mapping[str, object] | None]]:
    observed: dict[str, tuple[bytes, Mapping[str, object] | None]] = {}
    for binding in EXPECTED_CORE_ARTIFACTS:
        role = str(binding["role"])
        path = _core_artifact_path(failed_root, binding)
        payload = _read_regular(path, role)
        _require(len(payload) == binding["size_bytes"], f"{role} size differs")
        _require(_sha256(payload) == binding["sha256"], f"{role} hash differs")
        if role == "attempt_ledger":
            observed[role] = (payload, None)
            continue
        document = _strict_json(payload, role)
        self_hash = binding["self_hash"]
        if isinstance(self_hash, dict):
            field = str(self_hash["field"])
            if field == "bundle_sha256":
                _require(document.get(field) == self_hash["sha256"], f"{role} bundle hash differs")
            else:
                _verify_self_hash(
                    document,
                    field=field,
                    expected=str(self_hash["sha256"]),
                    label=role,
                )
        observed[role] = (payload, document)
    return observed


def _verify_input_bundle(document: Mapping[str, object]) -> None:
    records = document.get("records")
    live = document.get("live_holdout_preopen_verification")
    _require(isinstance(records, list) and isinstance(live, dict), "input bundle fields are absent")
    computed = _sha256(
        canonical_json_bytes(
            {
                "repository_file_bindings": records,
                "live_holdout_preopen_verification": live,
            }
        )
    )
    _require(computed == EXPECTED_ARCHIVE["input_bundle_sha256"], "input bundle self-hash differs")
    _require(
        live.get("verification_status") == "pass"
        and live.get("access_status") == "unopened"
        and live.get("access_count") == 0
        and live.get("open_intent_anchor_present") is False
        and live.get("pixel_content_included") is False,
        "input bundle does not preserve an unopened metadata-only boundary",
    )


def _evaluated_records(records: Sequence[Mapping[str, object]]) -> list[Mapping[str, object]]:
    return [record for record in records if record.get("status") in {"feasible", "infeasible"}]


def _unique_evaluation_records(
    records: Sequence[Mapping[str, object]],
) -> list[Mapping[str, object]]:
    unique: dict[str, Mapping[str, object]] = {}
    for record in _evaluated_records(records):
        binding = record.get("evaluation")
        _require(isinstance(binding, dict), "evaluated attempt lacks an evaluation binding")
        digest = binding.get("sha256")
        _require(isinstance(digest, str), "evaluation binding hash is absent")
        unique.setdefault(digest, record)
    return list(unique.values())


def _failure_set(record: Mapping[str, object]) -> tuple[str, ...]:
    value = record.get("canonical_failure_reasons")
    _require(isinstance(value, list), "evaluated attempt lacks canonical failure reasons")
    return tuple(str(item) for item in value)


def _failure_pattern_counts(records: Sequence[Mapping[str, object]]) -> list[int]:
    counts = Counter(_failure_set(record) for record in records)
    return sorted(counts.values(), reverse=True)


def _indicator_disagreements(records: Sequence[Mapping[str, object]]) -> int:
    suffixes = (
        "bootstrap:y_vs_conventional",
        "bootstrap:y_vs_fixed",
        "bootstrap:y_vs_non_ash",
        "chroma_displacement",
        "severe_category_regression",
        "severe_asset_regression",
    )
    disagreements = 0
    for record in records:
        failures = set(_failure_set(record))
        for suffix in suffixes:
            disagreements += int(
                (f"engine_raw:{suffix}" in failures)
                != (f"container_decoded:{suffix}" in failures)
            )
    return disagreements


def _phi_association(
    records: Sequence[Mapping[str, object]],
    *,
    left_name: str,
    left_failure: str,
    right_name: str,
    right_failure: str,
) -> Mapping[str, object]:
    counts = {(left, right): 0 for left in (0, 1) for right in (0, 1)}
    for record in records:
        failures = set(_failure_set(record))
        counts[(int(left_failure in failures), int(right_failure in failures))] += 1
    n00, n01, n10, n11 = (
        counts[(0, 0)],
        counts[(0, 1)],
        counts[(1, 0)],
        counts[(1, 1)],
    )
    denominator = math.sqrt(
        (n11 + n10) * (n01 + n00) * (n11 + n01) * (n10 + n00)
    )
    _require(denominator > 0.0, "binary association denominator is zero")
    return {
        "left": left_name,
        "right": right_name,
        "contingency_00_01_10_11": [n00, n01, n10, n11],
        "phi": (n11 * n00 - n10 * n01) / denominator,
    }


def _binary_associations(
    records: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    return {
        "observation_count": len(records),
        "values": [
            _phi_association(
                records,
                left_name="severe_category_regression",
                left_failure="engine_raw:severe_category_regression",
                right_name="severe_asset_regression",
                right_failure="engine_raw:severe_asset_regression",
            ),
            _phi_association(
                records,
                left_name="chroma_displacement",
                left_failure="engine_raw:chroma_displacement",
                right_name="severe_asset_regression",
                right_failure="engine_raw:severe_asset_regression",
            ),
            _phi_association(
                records,
                left_name="chroma_displacement",
                left_failure="engine_raw:chroma_displacement",
                right_name="severe_category_regression",
                right_failure="engine_raw:severe_category_regression",
            ),
        ],
    }


def _artifact_binding_path(
    failed_root: Path,
    binding: Mapping[str, object],
    *,
    required_parent: str,
) -> Path:
    value = binding.get("path")
    _require(isinstance(value, str), "artifact binding path is absent")
    parsed = PurePosixPath(value)
    _require(
        not parsed.is_absolute()
        and parsed.as_posix() == value
        and len(parsed.parts) == 2
        and parsed.parts[0] == required_parent
        and all(part not in {"", ".", ".."} for part in parsed.parts),
        f"artifact binding is outside {required_parent}",
    )
    return failed_root.joinpath(*parsed.parts)


def _load_evaluations(
    failed_root: Path,
    records: Sequence[Mapping[str, object]],
) -> Mapping[str, Mapping[str, object]]:
    documents: dict[str, Mapping[str, object]] = {}
    bindings: dict[str, tuple[str, int]] = {}
    for record in _evaluated_records(records):
        binding = record.get("evaluation")
        _require(isinstance(binding, dict), "evaluated attempt lacks evaluation binding")
        digest = binding.get("sha256")
        size = binding.get("size_bytes")
        _require(isinstance(digest, str) and isinstance(size, int), "evaluation binding is invalid")
        path = _artifact_binding_path(failed_root, binding, required_parent="evaluations")
        identity = (str(binding["path"]), size)
        previous = bindings.setdefault(digest, identity)
        _require(previous == identity, "reused evaluation binding differs")
        if digest in documents:
            continue
        payload = _read_regular(path, "evaluation artifact")
        _require(len(payload) == size and _sha256(payload) == digest, "evaluation artifact binding differs")
        _require(path.stem == digest, "evaluation filename differs from its hash")
        document = _strict_json(payload, "evaluation artifact")
        _require(document.get("split") == "development", "evaluation crossed the development boundary")
        documents[digest] = document
    actual = {
        child.name
        for child in (failed_root / "evaluations").iterdir()
        if child.is_file() and not child.is_symlink()
    }
    expected = {f"{digest}.json" for digest in documents}
    _require(actual == expected, "evaluation tree contains missing or unreferenced files")
    return documents


def _verify_control_artifacts(
    failed_root: Path,
    records: Sequence[Mapping[str, object]],
) -> None:
    bindings: dict[str, tuple[str, int]] = {}
    for record in _evaluated_records(records):
        rows = record.get("control_selection_artifacts")
        _require(isinstance(rows, list) and len(rows) == 3, "control selection binding set differs")
        for binding in rows:
            _require(isinstance(binding, dict), "control selection binding is invalid")
            digest = binding.get("sha256")
            size = binding.get("size_bytes")
            _require(isinstance(digest, str) and isinstance(size, int), "control binding is invalid")
            path = _artifact_binding_path(
                failed_root,
                binding,
                required_parent="control-selections",
            )
            identity = (str(binding["path"]), size)
            previous = bindings.setdefault(digest, identity)
            _require(previous == identity, "reused control selection binding differs")
            _require(path.stem == digest, "control selection filename differs from its hash")
    actual = {
        child.name
        for child in (failed_root / "control-selections").iterdir()
        if child.is_file() and not child.is_symlink()
    }
    expected = {f"{digest}.json" for digest in bindings}
    _require(actual == expected, "control tree contains missing or unreferenced files")


def _route_class(route: Mapping[str, object]) -> str:
    chroma_value = route.get("maximum_chroma_displacement_pixels")
    source_rows = route.get("per_source_engine_raw_y_psnr_delta_vs_conventional")
    _require(isinstance(chroma_value, (int, float)), "route chroma value is absent")
    _require(isinstance(source_rows, list) and source_rows, "route source-Y evidence is absent")
    chroma = float(chroma_value) > 0.25
    route_y = any(
        isinstance(row, dict)
        and isinstance(row.get("delta_db"), (int, float))
        and float(row["delta_db"]) < -0.25
        for row in source_rows
    )
    if chroma and route_y:
        return "both"
    if chroma:
        return "chroma_only"
    if route_y:
        return "route_y_only"
    return "pass"


def _route_cohort(
    records: Sequence[Mapping[str, object]],
    evaluations: Mapping[str, Mapping[str, object]],
) -> Mapping[str, object]:
    route_counts = {
        "direct_2x": Counter(),
        "direct_3_over_2": Counter(),
    }
    composite_count = 0
    union_count = 0
    disagreement_count = 0
    for record in records:
        binding = record["evaluation"]
        evaluation = evaluations[str(binding["sha256"])]
        route_rows = evaluation.get("checks", {}).get("evidence", {}).get(
            "analysis_grid", {}
        ).get("route_quality", {}).get("routes")
        _require(isinstance(route_rows, list) and len(route_rows) == 2, "route evidence differs")
        observed_classes: dict[str, str] = {}
        for route in route_rows:
            _require(isinstance(route, dict), "route evidence row is invalid")
            route_name = route.get("target_route")
            if route_name == "direct-2x":
                key = "direct_2x"
            elif route_name == "direct-3over2":
                key = "direct_3_over_2"
            else:
                raise TerminalFailureVerificationError("route evidence target differs")
            observed_classes[key] = _route_class(route)
            route_counts[key][observed_classes[key]] += 1
        composite = "check:analysis_grid_route_quality" in set(_failure_set(record))
        route_union = any(value != "pass" for value in observed_classes.values())
        composite_count += int(composite)
        union_count += int(route_union)
        disagreement_count += int(composite != route_union)
    def packed(counter: Counter[str]) -> Mapping[str, int]:
        return {
            "pass": counter["pass"],
            "chroma_only": counter["chroma_only"],
            "route_y_only": counter["route_y_only"],
            "both": counter["both"],
        }
    return {
        "observation_count": len(records),
        "composite_failure_count": composite_count,
        "chroma_or_route_y_failure_count": union_count,
        "equivalence_disagreement_count": disagreement_count,
        "direct_2x": packed(route_counts["direct_2x"]),
        "direct_3_over_2": packed(route_counts["direct_3_over_2"]),
    }


def _coordinate_groups(
    records: Sequence[Mapping[str, object]],
) -> list[tuple[tuple[int, str], list[Mapping[str, object]]]]:
    groups: list[tuple[tuple[int, str], list[Mapping[str, object]]]] = []
    for record in records:
        if record.get("phase") != "coordinate_search":
            continue
        sweep = record.get("sweep")
        coordinate = record.get("coordinate")
        _require(isinstance(sweep, int) and isinstance(coordinate, str), "coordinate attempt identity differs")
        key = (sweep, coordinate)
        if not groups or groups[-1][0] != key:
            groups.append((key, []))
        groups[-1][1].append(record)
    return groups


def _search_findings(records: Sequence[Mapping[str, object]]) -> tuple[Mapping[str, object], Mapping[str, object]]:
    _require(records and records[0].get("phase") == "initial", "initial attempt is absent")
    groups = _coordinate_groups(records)
    current_vector = records[0].get("candidate_vector")
    _require(isinstance(current_vector, dict), "initial candidate vector is absent")
    current_record = records[0]
    moves = {sweep: 0 for sweep in range(1, 7)}
    summary_changes = 0
    failure_changes = 0
    no_summary_change = 0
    selected_record = current_record
    for index, ((sweep, coordinate), group) in enumerate(groups):
        successful = [
            record
            for record in group
            if record.get("status") in {"feasible", "infeasible"}
        ]
        _require(successful, "coordinate group has no evaluated candidate")
        if index + 1 < len(groups):
            next_coordinate = groups[index + 1][0][1]
            target_vector = groups[index + 1][1][0].get("candidate_vector")
            _require(isinstance(target_vector, dict), "next coordinate baseline is absent")
            matches = [
                record
                for record in successful
                if all(
                    record["candidate_vector"][key] == value
                    for key, value in target_vector.items()
                    if key != next_coordinate
                )
            ]
        else:
            matches = [
                record for record in successful if record.get("candidate_vector") == current_vector
            ]
        _require(len(matches) == 1, "coordinate selection cannot be reconstructed uniquely")
        selected_record = matches[0]
        selected_vector = selected_record.get("candidate_vector")
        _require(isinstance(selected_vector, dict), "selected candidate vector is absent")
        changed = selected_vector[coordinate] != current_vector[coordinate]
        if changed:
            moves[sweep] += 1
            if selected_record.get("summary_sha256") == current_record.get("summary_sha256"):
                no_summary_change += 1
            else:
                summary_changes += 1
            if _failure_set(selected_record) != _failure_set(current_record):
                failure_changes += 1
        current_vector = dict(selected_vector)
        current_record = selected_record

    selected_hash = selected_record.get("candidate_vector_sha256")
    _require(isinstance(selected_hash, str), "final incumbent hash is absent")
    tail_hash = records[-1].get("candidate_vector_sha256")
    _require(isinstance(tail_hash, str), "tail candidate hash is absent")
    evaluated = _evaluated_records(records)
    search = {
        "fresh_evaluation_count": sum(record.get("cache_hit") is False for record in evaluated),
        "cache_hit_count": sum(record.get("cache_hit") is True for record in evaluated),
        "sweep_count": 6,
        "neighbors_per_sweep": 168,
        "selected_moves_by_sweep": [moves[sweep] for sweep in range(1, 7)],
        "selected_move_count": sum(moves.values()),
        "selected_moves_changing_canonical_failures": failure_changes,
        "selected_moves_changing_summary": summary_changes,
        "selected_moves_without_summary_change": no_summary_change,
    }
    incumbent = {
        "candidate_vector_sha256": selected_hash,
        "ledger_observation_count": sum(
            record.get("candidate_vector_sha256") == selected_hash for record in records
        ),
        "tail_candidate_vector_sha256": tail_hash,
        "tail_candidate_is_incumbent": tail_hash == selected_hash,
    }
    for sweep in range(1, 7):
        _require(
            sum(record.get("sweep") == sweep for record in records) == 168,
            f"sweep {sweep} attempt count differs",
        )
    return search, incumbent


def _controlled_coordinates(records: Sequence[Mapping[str, object]]) -> Mapping[str, object]:
    grouped: dict[tuple[int, str], list[Mapping[str, object]]] = defaultdict(list)
    for record in records:
        if (
            record.get("phase") == "coordinate_search"
            and record.get("status") in {"feasible", "infeasible"}
        ):
            grouped[(int(record["sweep"]), str(record["coordinate"]))].append(record)
    coordinates = sorted({coordinate for _, coordinate in grouped})
    failure_changing: list[str] = []
    summary_inert: list[str] = []
    for coordinate in coordinates:
        groups = [rows for (sweep, name), rows in grouped.items() if name == coordinate]
        if any(len({_failure_set(record) for record in rows}) > 1 for rows in groups):
            failure_changing.append(coordinate)
        qualified = [
            rows
            for rows in groups
            if len(
                {
                    json.dumps(record.get("value"), sort_keys=True, separators=(",", ":"))
                    for record in rows
                }
            )
            >= 2
        ]
        if qualified and all(
            len({record.get("summary_sha256") for record in rows}) == 1
            for rows in qualified
        ):
            summary_inert.append(coordinate)
    return {
        "coordinate_count": len(coordinates),
        "canonical_failure_changing_count": len(failure_changing),
        "canonical_failure_changing_coordinates": failure_changing,
        "summary_inert_count": len(summary_inert),
        "summary_inert_coordinates": summary_inert,
    }


def _recompute_terminal_findings(
    records: Sequence[Mapping[str, object]],
    evaluations: Mapping[str, Mapping[str, object]],
) -> Mapping[str, object]:
    status_counts = Counter(str(record.get("status")) for record in records)
    evaluated = _evaluated_records(records)
    unique = _unique_evaluation_records(records)
    search, incumbent = _search_findings(records)
    return {
        "status_counts": {
            "infeasible": status_counts["infeasible"],
            "constraint_failure": status_counts["constraint_failure"],
            "evaluation_failure": status_counts["evaluation_failure"],
            "feasible": status_counts["feasible"],
        },
        "search": search,
        "final_incumbent": incumbent,
        "failure_pattern_counts": {
            "attempt_weighted": _failure_pattern_counts(evaluated),
            "unique_evaluation": _failure_pattern_counts(unique),
        },
        "route_failure_equivalence": {
            "criterion": EXPECTED_TERMINAL_FINDINGS["route_failure_equivalence"]["criterion"],
            "attempt_weighted": _route_cohort(evaluated, evaluations),
            "unique_evaluation": _route_cohort(unique, evaluations),
        },
        "raw_decoded_indicator_equivalence": {
            "paired_criterion_count": 6,
            "attempt_weighted_observation_count": len(evaluated),
            "unique_evaluation_observation_count": len(unique),
            "attempt_weighted_disagreement_count": _indicator_disagreements(evaluated),
            "unique_evaluation_disagreement_count": _indicator_disagreements(unique),
        },
        "binary_associations": {
            "method": "Pearson phi coefficient for binary failure indicators",
            "causal_interpretation_allowed": False,
            "attempt_weighted": _binary_associations(evaluated),
            "unique_evaluation": _binary_associations(unique),
        },
        "controlled_coordinates": _controlled_coordinates(records),
        "improvement_targets": EXPECTED_TERMINAL_FINDINGS["improvement_targets"],
    }


def verify_full(
    failed_root: Path,
    *,
    repository_root: Path = REPOSITORY_ROOT,
    receipt_path: Path | None = None,
) -> Mapping[str, object]:
    """Verify tracked artifacts and the complete local terminal ``.failed`` tree."""

    fast = verify_fast(repository_root, receipt_path)
    failed_root = failed_root.resolve(strict=True)
    _require(failed_root.name == "p06-current-source-r1.failed", "failed-root name differs")
    _require(
        not failed_root.is_symlink() and failed_root.is_dir(),
        "failed-root is symbolic or not a directory",
    )
    observed_tree = _observed_tree_binding(failed_root)
    observed_evaluations = _observed_tree_binding(failed_root / "evaluations")
    observed_controls = _observed_tree_binding(failed_root / "control-selections")
    _require(observed_tree == EXPECTED_ARCHIVE["tree"], "complete failed-tree binding differs")
    _require(observed_evaluations == EXPECTED_ARCHIVE["evaluation_tree"], "evaluation-tree binding differs")
    _require(observed_controls == EXPECTED_ARCHIVE["control_selection_tree"], "control-tree binding differs")

    core = _verify_core_artifacts(failed_root)
    failure = core["failure_envelope"][1]
    marker = core["transaction_marker"][1]
    input_bindings = core["input_bindings"][1]
    _require(failure == EXPECTED_FAILURE_ENVELOPE, "failure envelope semantics differ")
    _require(isinstance(marker, dict), "transaction marker is absent")
    _require(
        {key: marker[key] for key in ("artifact_kind", "transaction_state", "record_sha256")}
        == EXPECTED_ARCHIVE["transaction_marker"],
        "transaction marker semantics differ",
    )
    _require(isinstance(input_bindings, dict), "input bindings are absent")
    _verify_input_bundle(input_bindings)

    ledger_payload = core["attempt_ledger"][0]
    records = _strict_ndjson(ledger_payload)
    _require(len(records) == 1009, "attempt ledger count differs")
    _require(all(record.get("split") == "development" for record in records), "attempt ledger crossed split boundary")
    _require(records[-1].get("record_sha256") == EXPECTED_ARCHIVE["ledger_closure"]["tail_record_sha256"], "attempt ledger tail differs")
    lines = ledger_payload.splitlines(keepends=True)
    prefix = b"".join(lines[:241])
    _require(len(prefix) == 919_520, "bounded predecessor prefix size differs")
    _require(_sha256(prefix) == EXPECTED_BOUNDED_PREDECESSOR["ledger_prefix_sha256"], "bounded predecessor prefix hash differs")
    _require(records[240].get("record_sha256") == EXPECTED_BOUNDED_PREDECESSOR["cutoff_record_sha256"], "bounded predecessor cutoff record differs")

    evaluations = _load_evaluations(failed_root, records)
    _verify_control_artifacts(failed_root, records)
    recomputed = _recompute_terminal_findings(records, evaluations)
    _require(recomputed == EXPECTED_TERMINAL_FINDINGS, "recomputed terminal findings differ")
    return {
        **fast,
        "mode": "full_failed_root",
        "failed_tree_sha256": observed_tree["sha256"],
        "failed_tree_file_count": observed_tree["file_count"],
        "failed_tree_size_bytes": observed_tree["size_bytes"],
        "evaluated_attempt_count": len(_evaluated_records(records)),
        "unique_evaluation_count": len(evaluations),
        "control_selection_file_count": observed_controls["file_count"],
    }


def _arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=REPOSITORY_ROOT)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument(
        "--failed-root",
        type=Path,
        help="explicitly enable complete local failed-tree verification",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _arguments(argv)
    if arguments.failed_root is None:
        result = verify_fast(arguments.repository_root, arguments.receipt)
    else:
        result = verify_full(
            arguments.failed_root,
            repository_root=arguments.repository_root,
            receipt_path=arguments.receipt,
        )
    print(canonical_json_bytes(result).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
