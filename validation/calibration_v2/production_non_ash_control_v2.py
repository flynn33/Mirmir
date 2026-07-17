"""Build and reopen the production V2 non-ASH control-selection closure."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureSnapshotV2,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.baseline_ablation_budget_v2 import (
    NonAshSelectorExecutionProfileV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
    NON_ASH_IMMUTABLE_CONTENT_KIND,
    TypedArtifactBindingV2,
    authority_bindings_v2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_LEDGER_KIND,
    EVALUATION_EVIDENCE_KIND,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
    ArtifactReferenceV2,
    NonAshSelectorArtifactStoreV2,
    canonical_artifact_bytes_v2,
    canonical_evaluation_evidence_bytes_v2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    DEVELOPMENT_SPLIT,
    DEVELOPMENT_STATUS_CONVERGED,
    VALIDATION_SPLIT,
    VALIDATION_STATUS_SELECTED,
    NonAshSelectorDevelopmentResultV2,
    NonAshSelectorEvaluationV2,
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorOutcomeV2,
    NonAshSelectorValidationResultV2,
    canonical_rule_values_v2,
    non_ash_validation_neighborhood_v2,
    rule_mapping_v2,
    rule_sha256_v2,
    run_non_ash_development_search_v2,
    run_non_ash_validation_selection_v2,
)
from validation.calibration_v2.production_control_selection_v2 import (
    NonAshControlSelectionInputV2,
)
from validation.calibration_v2.production_evaluator import (
    ControlAggregateEvidence,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


_SELECTION_OBJECTIVE = {
    "comparison_domain": "engine_raw",
    "row_scope": "natural corpus asset rows only",
    "per_source_aggregation": (
        "unweighted arithmetic mean across that source's locked "
        "degradation-profile rows"
    ),
    "across_source_aggregation": (
        "unweighted arithmetic mean across source assets"
    ),
    "direction": "lexicographically maximize",
    "metric_order": [
        "y_psnr_db",
        "y_ms_ssim",
        "y_ssim",
        "cb_psnr_db",
        "cr_psnr_db",
    ],
}
_DEVELOPMENT_TIE = (
    "lexicographically maximize the development engine_raw corpus-mean tuple, "
    "then choose the lexicographically ascending canonical serialized complete "
    "27-member rule object"
)
_VALIDATION_TIE = (
    "lexicographically maximize the validation engine_raw corpus-mean tuple, "
    "then choose the lexicographically ascending canonical serialized complete "
    "27-member rule object"
)
_CACHED_SCHEMA_SHA256 = hashlib.sha256(
    b"mirmir-p06-cached-16-operator-output-manifest-v2-canonical-json-v1"
).hexdigest()
_IMMUTABLE_SCHEMA_SHA256 = hashlib.sha256(
    b"mirmir-p06-non-ash-immutable-content-v2-opaque-bytes-v1"
).hexdigest()


class ProductionNonAshControlV2Error(ValueError):
    """The native selector result or its reopened V2 closure differs."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _self_hash(document: Mapping[str, object], field: str) -> Dict[str, object]:
    result = dict(document)
    result[field] = "0" * 64
    unhashed = dict(result)
    unhashed.pop(field)
    result[field] = canonical_sha256(unhashed)
    return result


def _serialization(profile: NonAshSelectorExecutionProfileV2) -> Dict[str, object]:
    return {
        "coordinate_order": list(profile.coordinate_order),
        "encoding": "UTF-8",
        "hash_algorithm": "SHA-256",
        "hash_input": (
            "canonical sorted-key compact UTF-8 JSON object with exactly the 27 "
            "coordinate_order names as keys and their signed integer values; no "
            "BOM and no trailing newline"
        ),
        "value_order": list(profile.values),
    }


def _data_access(*, validation: bool) -> Dict[str, object]:
    return {
        "development_metrics_accessed": True,
        "validation_accessed": validation,
        "holdout_accessed": False,
        "media_payloads_accessed": False,
        "release_locks_written": False,
        "winner_claim_made": False,
    }


def _base(
    kind: str,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
) -> Dict[str, object]:
    versions = {
        ATTEMPT_LEDGER_KIND: "2.0.1",
        SELECTION_KIND: "2.0.2",
        NEIGHBOR_MANIFEST_KIND: "2.0.1",
    }
    return {
        "schema_version": versions[kind],
        "artifact_kind": kind,
        "selector_id": profile.selector_id,
        "authority_bindings": authority_bindings_v2(),
        "canonical_rule_serialization": _serialization(profile),
        "shared_bank_configuration_sha256": (
            scope.shared_bank_configuration_sha256
        ),
        "degradation_policy_sha256": scope.degradation_policy_sha256,
        "cached_16_operator_output_manifest_sha256": (
            scope.cached_16_operator_output_manifest_sha256
        ),
    }


def _outcome_row(outcome: NonAshSelectorOutcomeV2) -> Dict[str, object]:
    if type(outcome) is not NonAshSelectorEvaluationV2:
        raise ProductionNonAshControlV2Error(
            "production non-ASH evaluation returned a typed failure"
        )
    return {
        "outcome_type": "evaluated",
        "evaluation_sha256": outcome.evaluation_sha256,
        "objective_summary_sha256": outcome.objective_summary_sha256,
        "engine_raw_corpus_mean_tuple": list(outcome.objective_means),
        "output_manifest_sha256": outcome.output_manifest_sha256,
    }


def _ledger_document(
    *,
    run_id: str,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
    result: NonAshSelectorDevelopmentResultV2,
) -> Dict[str, object]:
    if (
        result.status != DEVELOPMENT_STATUS_CONVERGED
        or result.terminal_rule_values is None
        or result.terminal_rule_sha256 is None
        or result.incumbent_evaluation is None
        or result.last_record_sha256 is None
    ):
        raise ProductionNonAshControlV2Error(
            "production non-ASH development search did not converge"
        )
    terminal = result.incumbent_evaluation
    provenance = [
        record
        for record in result.attempt_records
        if not record.cache_hit
        and type(record.outcome) is NonAshSelectorEvaluationV2
        and record.rule_sha256 == result.terminal_rule_sha256
        and record.outcome == terminal
    ]
    if not provenance:
        raise ProductionNonAshControlV2Error(
            "non-ASH terminal rule lacks fresh development provenance"
        )
    records = [
        {
            "attempt_ordinal": record.attempt_ordinal,
            "phase": record.phase,
            "sweep": record.sweep,
            "coordinate_ordinal": record.coordinate_ordinal,
            "coordinate_name": record.coordinate_name,
            "coordinate_value": record.coordinate_value,
            "rule_sha256": record.rule_sha256,
            "canonical_rule_values": list(record.canonical_rule_values),
            "cache_hit": record.cache_hit,
            "outcome": _outcome_row(record.outcome),
            "previous_record_sha256": record.previous_record_sha256,
            "record_sha256": record.record_sha256,
        }
        for record in result.attempt_records
    ]
    document = _base(ATTEMPT_LEDGER_KIND, profile, scope)
    document.update(
        {
            "attempt_schedule": {
                "initial_attempt_ordinal": 0,
                "maximum_sweeps": profile.maximum_sweeps,
                "coordinate_count": len(profile.coordinate_order),
                "values_per_coordinate": len(profile.values),
                "attempts_per_complete_sweep": (
                    len(profile.coordinate_order) * len(profile.values)
                ),
                "maximum_attempt_count": profile.maximum_development_attempts,
                "coordinate_order": list(profile.coordinate_order),
                "value_order": list(profile.values),
                "coordinate_scan_attempt_ordinal_formula": (
                    "1 + (sweep - 1) * 189 + coordinate_ordinal * 7 + "
                    "value_ordinal"
                ),
                "cache_hits_must_be_recorded": True,
            },
            "split": DEVELOPMENT_SPLIT,
            "run_id": run_id,
            "maximum_attempt_count": profile.maximum_development_attempts,
            "attempt_count": result.attempt_count,
            "unique_evaluation_count": result.unique_evaluation_count,
            "cache_hit_count": sum(
                1 for record in result.attempt_records if record.cache_hit
            ),
            "first_attempt_ordinal": 0,
            "last_attempt_ordinal": result.attempt_count - 1,
            "records": records,
            "last_record_sha256": result.last_record_sha256,
            "completed_sweep_count": result.completed_sweeps,
            "terminal_status": result.status,
            "termination_reason": "unchanged_complete_sweep",
            "terminal_attempt_ordinal": provenance[0].attempt_ordinal,
            "terminal_rule_sha256": result.terminal_rule_sha256,
            "terminal_rule_values": list(result.terminal_rule_values),
            "terminal_objective_summary_sha256": (
                terminal.objective_summary_sha256
            ),
            "terminal_engine_raw_corpus_mean_tuple": list(
                terminal.objective_means
            ),
            "data_access": _data_access(validation=False),
            "ledger_sha256": "0" * 64,
        }
    )
    return _self_hash(document, "ledger_sha256")


def _development_selection_document(
    *,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
    ledger: Mapping[str, object],
) -> Dict[str, object]:
    document = _base(SELECTION_KIND, profile, scope)
    document.update(
        {
            "selection_stage": "development_provisional",
            "split": DEVELOPMENT_SPLIT,
            "uniform_application": True,
            "candidate_evaluation_budget": profile.maximum_development_attempts,
            "maximum_validation_candidate_count": (
                profile.maximum_validation_candidates
            ),
            "selection_objective": dict(_SELECTION_OBJECTIVE),
            "development_attempt_count": ledger["attempt_count"],
            "development_last_attempt_ordinal": ledger["last_attempt_ordinal"],
            "development_attempt_ledger_sha256": ledger["ledger_sha256"],
            "development_attempt_ledger_tip_sha256": ledger[
                "last_record_sha256"
            ],
            "development_terminal_attempt_ordinal": ledger[
                "terminal_attempt_ordinal"
            ],
            "development_terminal_rule_sha256": ledger[
                "terminal_rule_sha256"
            ],
            "development_terminal_rule_values": list(
                ledger["terminal_rule_values"]
            ),
            "development_objective_summary_sha256": ledger[
                "terminal_objective_summary_sha256"
            ],
            "development_engine_raw_corpus_mean_tuple": list(
                ledger["terminal_engine_raw_corpus_mean_tuple"]
            ),
            "data_access": _data_access(validation=False),
            "tie_break": _DEVELOPMENT_TIE,
            "development_selection_sha256": "0" * 64,
        }
    )
    return _self_hash(document, "development_selection_sha256")


def _neighbor_document(
    *,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
    development: NonAshSelectorDevelopmentResultV2,
    ledger: Mapping[str, object],
    development_selection: Mapping[str, object],
    immutable_manifest_sha256: str,
) -> Dict[str, object]:
    assert development.terminal_rule_values is not None
    expected = non_ash_validation_neighborhood_v2(
        profile,
        rule_mapping_v2(development.terminal_rule_values, profile),
    )
    latest = {
        record.rule_sha256: record.outcome
        for record in development.attempt_records
    }
    candidates = []
    for candidate in expected:
        evidence = latest.get(candidate.rule_sha256)
        if type(evidence) is not NonAshSelectorEvaluationV2:
            raise ProductionNonAshControlV2Error(
                "validation neighbor lacks development evidence"
            )
        entry: Dict[str, object] = {
            "validation_candidate_ordinal": candidate.candidate_ordinal,
            "candidate_kind": (
                "terminal" if candidate.terminal else "one_coordinate_neighbor"
            ),
            "rule_sha256": candidate.rule_sha256,
            "canonical_rule_values": list(candidate.canonical_rule_values),
            "development_evidence_sha256": evidence.evaluation_sha256,
            "neighbor_entry_sha256": "0" * 64,
        }
        if not candidate.terminal:
            entry.update(
                {
                    "coordinate_ordinal": candidate.coordinate_ordinal,
                    "coordinate_name": candidate.coordinate_name,
                    "terminal_value": candidate.from_value,
                    "replacement_value": candidate.to_value,
                }
            )
        candidates.append(_self_hash(entry, "neighbor_entry_sha256"))
    document = _base(NEIGHBOR_MANIFEST_KIND, profile, scope)
    document.update(
        {
            "neighbor_generation": {
                "terminal_candidate_count": 1,
                "coordinate_count": len(profile.coordinate_order),
                "noncurrent_values_per_coordinate": len(profile.values) - 1,
                "validation_candidate_count": profile.maximum_validation_candidates,
                "candidate_order": (
                    "terminal rule first, then coordinate_order, then ascending "
                    "noncurrent value_order"
                ),
                "neighbor_ordinal_formula": (
                    "1 + coordinate_ordinal * 6 + noncurrent_value_ordinal"
                ),
                "adaptive_expansion_allowed": False,
            },
            "source_split": DEVELOPMENT_SPLIT,
            "target_split": VALIDATION_SPLIT,
            "development_attempt_count": ledger["attempt_count"],
            "development_last_attempt_ordinal": ledger["last_attempt_ordinal"],
            "development_attempt_ledger_sha256": ledger["ledger_sha256"],
            "development_attempt_ledger_tip_sha256": ledger[
                "last_record_sha256"
            ],
            "development_selection_sha256": development_selection[
                "development_selection_sha256"
            ],
            "development_candidate_evidence_manifest_sha256": (
                immutable_manifest_sha256
            ),
            "terminal_rule_sha256": development.terminal_rule_sha256,
            "terminal_rule_values": list(development.terminal_rule_values),
            "maximum_validation_candidate_count": (
                profile.maximum_validation_candidates
            ),
            "validation_candidate_count": len(candidates),
            "candidate_rule_sha256_values": [
                candidate["rule_sha256"] for candidate in candidates
            ],
            "candidates": candidates,
            "data_access": _data_access(validation=False),
            "manifest_sha256": "0" * 64,
        }
    )
    return _self_hash(document, "manifest_sha256")


def _validation_selection_document(
    *,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
    result: NonAshSelectorValidationResultV2,
    development_selection: Mapping[str, object],
    neighbor: Mapping[str, object],
) -> Dict[str, object]:
    if (
        result.status != VALIDATION_STATUS_SELECTED
        or result.selected_candidate is None
        or result.selected_evaluation is None
        or len(result.outcomes) != len(result.candidates)
    ):
        raise ProductionNonAshControlV2Error(
            "production non-ASH validation did not select a control"
        )
    neighbor_rows = neighbor["candidates"]
    results = []
    for candidate, outcome, neighbor_row in zip(
        result.candidates,
        result.outcomes,
        neighbor_rows,
    ):
        if type(outcome) is not NonAshSelectorEvaluationV2:
            raise ProductionNonAshControlV2Error(
                "production non-ASH validation returned a typed failure"
            )
        results.append(
            {
                "validation_candidate_ordinal": candidate.candidate_ordinal,
                "neighbor_entry_sha256": neighbor_row["neighbor_entry_sha256"],
                "rule_sha256": candidate.rule_sha256,
                "outcome": {
                    "outcome_type": "scored",
                    "evaluation_sha256": outcome.evaluation_sha256,
                    "objective_summary_sha256": (
                        outcome.objective_summary_sha256
                    ),
                    "engine_raw_corpus_mean_tuple": list(
                        outcome.objective_means
                    ),
                    "output_manifest_sha256": outcome.output_manifest_sha256,
                },
            }
        )
    selected = result.selected_evaluation
    candidate = result.selected_candidate
    document = _base(SELECTION_KIND, profile, scope)
    document.update(
        {
            "selection_stage": "validation_final",
            "split": VALIDATION_SPLIT,
            "uniform_application": True,
            "candidate_evaluation_budget": profile.maximum_development_attempts,
            "maximum_validation_candidate_count": (
                profile.maximum_validation_candidates
            ),
            "selection_objective": dict(_SELECTION_OBJECTIVE),
            "development_selection_sha256": development_selection[
                "development_selection_sha256"
            ],
            "development_terminal_rule_sha256": development_selection[
                "development_terminal_rule_sha256"
            ],
            "validation_neighbor_manifest_sha256": neighbor["manifest_sha256"],
            "validation_candidate_count": len(results),
            "validation_results": results,
            "validation_status": "selected",
            "selected_control_rule_sha256": candidate.rule_sha256,
            "selected_control_rule_values": list(candidate.canonical_rule_values),
            "validation_objective_summary_sha256": (
                selected.objective_summary_sha256
            ),
            "data_access": _data_access(validation=True),
            "tie_break": _VALIDATION_TIE,
            "validation_selection_sha256": "0" * 64,
        }
    )
    return _self_hash(document, "validation_selection_sha256")


class _ClosureBuilder:
    def __init__(self) -> None:
        self._files: Dict[str, Tuple[TypedArtifactBindingV2, bytes]] = {}

    def add(
        self,
        *,
        kind: str,
        payload: bytes,
        schema_sha256: str,
        suffix: str = "json",
    ) -> TypedArtifactBindingV2:
        digest = _sha256(payload)
        path = f"non-ash-v2/{kind}/{digest}.{suffix}"
        binding = TypedArtifactBindingV2(
            artifact_kind=kind,
            schema_sha256=schema_sha256,
            path=path,
            sha256=digest,
            size_bytes=len(payload),
        )
        prior = self._files.get(path)
        if prior is not None and prior != (binding, payload):
            raise ProductionNonAshControlV2Error(
                "non-ASH closure path aliases different bytes"
            )
        self._files[path] = (binding, payload)
        return binding

    def snapshot(self) -> AuthenticatedClosureSnapshotV2:
        return AuthenticatedClosureSnapshotV2(
            tuple(
                ClosureFileSnapshotV2(
                    ClosureFileBindingV2(
                        binding.path,
                        binding.sha256,
                        binding.size_bytes,
                    ),
                    payload,
                )
                for binding, payload in self._files.values()
            )
        )

    def bindings(self) -> Tuple[TypedArtifactBindingV2, ...]:
        return tuple(
            sorted(
                (binding for binding, _ in self._files.values()),
                key=lambda binding: (
                    binding.path,
                    binding.artifact_kind,
                    binding.schema_sha256,
                    binding.sha256,
                    binding.size_bytes,
                ),
            )
        )


@dataclass(frozen=True)
class ProductionNonAshSelectionClosureV2:
    selection_input: NonAshControlSelectionInputV2
    current_publications: Tuple[Mapping[str, object], ...]
    development_publications: Tuple[Mapping[str, object], ...]


ControlEvaluatorV2 = Callable[
    [str, Mapping[str, int]], ControlAggregateEvidence
]


def build_production_non_ash_selection_v2(
    *,
    artifact_root: Path,
    run_id: str,
    split: str,
    profile: NonAshSelectorExecutionProfileV2,
    scope: NonAshSelectorEvaluationScopeV2,
    cached_manifest_payload: bytes,
    evaluator: ControlEvaluatorV2,
    validation_admission_payload: Optional[bytes] = None,
) -> ProductionNonAshSelectionClosureV2:
    """Execute, persist, reopen, and snapshot one exact selector closure."""

    if (
        split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
        or type(cached_manifest_payload) is not bytes
        or not cached_manifest_payload
        or not callable(evaluator)
        or (split == VALIDATION_SPLIT)
        != (type(validation_admission_payload) is bytes)
    ):
        raise ProductionNonAshControlV2Error(
            "production non-ASH selection inputs are invalid"
        )
    evidence_payloads: Dict[str, bytes] = {}
    outcomes: Dict[str, NonAshSelectorEvaluationV2] = {}
    publications: Dict[str, list[Mapping[str, object]]] = {
        DEVELOPMENT_SPLIT: [],
        VALIDATION_SPLIT: [],
    }

    def evaluate(target_split: str, rule: Mapping[str, int]):
        values = canonical_rule_values_v2(rule, profile)
        rule_sha256 = rule_sha256_v2(values, profile)
        aggregate = evaluator(target_split, rule)
        publication = aggregate.authorization_v2
        if not isinstance(publication, Mapping):
            raise ProductionNonAshControlV2Error(
                "non-ASH native aggregate lacks its raw V2 publication"
            )
        if publication.get("stable_id") != rule_sha256:
            raise ProductionNonAshControlV2Error(
                "non-ASH raw publication rule identity differs"
            )
        objective_binding = publication.get("objective_summary")
        output_binding = publication.get("output_manifest")
        if not isinstance(objective_binding, Mapping) or not isinstance(
            output_binding, Mapping
        ):
            raise ProductionNonAshControlV2Error(
                "non-ASH raw publication aggregate bindings are absent"
            )
        payload = canonical_evaluation_evidence_bytes_v2(
            selector_id=profile.selector_id,
            split=target_split,
            evaluation_scope=scope,
            rule_sha256=rule_sha256,
            objective_summary_sha256=str(objective_binding["sha256"]),
            output_manifest_sha256=str(output_binding["sha256"]),
            objective_means=tuple(aggregate.objective_means),
        )
        evaluation_sha256 = _sha256(payload)
        outcome = NonAshSelectorEvaluationV2(
            split=target_split,
            scope=scope,
            rule_sha256=rule_sha256,
            evaluation_sha256=evaluation_sha256,
            objective_summary_sha256=str(objective_binding["sha256"]),
            output_manifest_sha256=str(output_binding["sha256"]),
            objective_means=tuple(aggregate.objective_means),
        )
        evidence_payloads[evaluation_sha256] = payload
        outcomes[evaluation_sha256] = outcome
        publications[target_split].append(dict(publication))
        return outcome

    development = run_non_ash_development_search_v2(
        profile,
        scope,
        lambda rule: evaluate(DEVELOPMENT_SPLIT, rule),
        lambda digest: outcomes[digest],
    )
    ledger = _ledger_document(
        run_id=run_id,
        profile=profile,
        scope=scope,
        result=development,
    )
    development_selection = _development_selection_document(
        profile=profile,
        scope=scope,
        ledger=ledger,
    )
    store = NonAshSelectorArtifactStoreV2(
        Path(artifact_root) / "non-ash-selector-store-v2"
    )

    def reopen_evaluation(digest: str) -> bytes:
        return evidence_payloads[digest]

    ledger_reference = store.publish(
        ledger,
        profile,
        scope,
        development_evidence_reopener=reopen_evaluation,
    )
    development_reference = store.publish(
        development_selection,
        profile,
        scope,
        development_ledger_reference=ledger_reference,
        development_evidence_reopener=reopen_evaluation,
    )
    selection = development_selection
    selection_reference = development_reference
    predecessor_references: Dict[str, ArtifactReferenceV2] = {
        "development_ledger": ledger_reference,
    }
    extra_documents: list[Tuple[str, Mapping[str, object], ArtifactReferenceV2]] = [
        (ATTEMPT_LEDGER_KIND, ledger, ledger_reference),
    ]
    immutable_payloads: Dict[str, bytes] = {}

    if split == VALIDATION_SPLIT:
        assert validation_admission_payload is not None
        immutable_sha256 = _sha256(validation_admission_payload)
        immutable_payloads[immutable_sha256] = validation_admission_payload
        neighbor = _neighbor_document(
            profile=profile,
            scope=scope,
            development=development,
            ledger=ledger,
            development_selection=development_selection,
            immutable_manifest_sha256=immutable_sha256,
        )
        neighbor_reference = store.publish(
            neighbor,
            profile,
            scope,
            development_ledger_reference=ledger_reference,
            development_selection_reference=development_reference,
            development_evidence_reopener=reopen_evaluation,
            immutable_content_reopener=lambda digest: immutable_payloads[digest],
        )
        validation = run_non_ash_validation_selection_v2(
            profile,
            scope,
            development.attempt_records,
            lambda digest: outcomes[digest],
            lambda rule: evaluate(VALIDATION_SPLIT, rule),
        )
        validation_selection = _validation_selection_document(
            profile=profile,
            scope=scope,
            result=validation,
            development_selection=development_selection,
            neighbor=neighbor,
        )
        selection_reference = store.publish(
            validation_selection,
            profile,
            scope,
            development_ledger_reference=ledger_reference,
            development_selection_reference=development_reference,
            validation_neighbor_manifest_reference=neighbor_reference,
            development_evidence_reopener=reopen_evaluation,
            validation_evidence_reopener=reopen_evaluation,
            immutable_content_reopener=lambda digest: immutable_payloads[digest],
        )
        selection = validation_selection
        predecessor_references.update(
            {
                "development_selection": development_reference,
                "validation_neighbor_manifest": neighbor_reference,
            }
        )
        extra_documents.extend(
            [
                (SELECTION_KIND, development_selection, development_reference),
                (NEIGHBOR_MANIFEST_KIND, neighbor, neighbor_reference),
            ]
        )

    closure = _ClosureBuilder()
    typed_by_digest: Dict[str, TypedArtifactBindingV2] = {}
    for kind, document, reference in extra_documents:
        payload = canonical_artifact_bytes_v2(document)
        if _sha256(payload) != reference.sha256:
            raise ProductionNonAshControlV2Error(
                "reopened non-ASH document reference differs"
            )
        typed_by_digest[reference.sha256] = closure.add(
            kind=kind,
            payload=payload,
            schema_sha256=reference.schema_sha256,
        )
    selection_payload = canonical_artifact_bytes_v2(selection)
    typed_selection = closure.add(
        kind=SELECTION_KIND,
        payload=selection_payload,
        schema_sha256=selection_reference.schema_sha256,
    )
    typed_by_digest[selection_reference.sha256] = typed_selection
    for digest, payload in evidence_payloads.items():
        if _sha256(payload) != digest:
            raise ProductionNonAshControlV2Error(
                "non-ASH evaluation envelope content address differs"
            )
        closure.add(
            kind=EVALUATION_EVIDENCE_KIND,
            payload=payload,
            schema_sha256=schema_sha256_for_kind_v2(
                EVALUATION_EVIDENCE_KIND
            ),
        )
    closure.add(
        kind=CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
        payload=cached_manifest_payload,
        schema_sha256=_CACHED_SCHEMA_SHA256,
    )
    for payload in immutable_payloads.values():
        closure.add(
            kind=NON_ASH_IMMUTABLE_CONTENT_KIND,
            payload=payload,
            schema_sha256=_IMMUTABLE_SCHEMA_SHA256,
            suffix="bin",
        )
    predecessor_bindings = {
        name: typed_by_digest[reference.sha256]
        for name, reference in predecessor_references.items()
    }
    bindings = closure.bindings()
    selection_input = NonAshControlSelectionInputV2(
        selection_binding=typed_selection,
        predecessor_bindings=predecessor_bindings,
        dependency_bindings=bindings,
        evidence_snapshot=closure.snapshot(),
    )
    return ProductionNonAshSelectionClosureV2(
        selection_input=selection_input,
        current_publications=tuple(publications[split]),
        development_publications=(
            tuple(publications[DEVELOPMENT_SPLIT])
            if split == VALIDATION_SPLIT
            else ()
        ),
    )


__all__ = [
    "ProductionNonAshControlV2Error",
    "ProductionNonAshSelectionClosureV2",
    "build_production_non_ash_selection_v2",
]
