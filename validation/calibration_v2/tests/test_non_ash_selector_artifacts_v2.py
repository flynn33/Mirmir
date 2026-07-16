from __future__ import annotations

from copy import deepcopy
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from validation.calibration_v2.baseline_ablation_budget_v2 import (
    parse_baseline_ablation_budget_v2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    ATTEMPT_FAILURE_KIND,
    ATTEMPT_LEDGER_KIND,
    NEIGHBOR_MANIFEST_KIND,
    SELECTION_KIND,
    ArtifactReferenceV2,
    NonAshSelectorArtifactStoreV2,
    NonAshSelectorArtifactV2Error,
    canonical_artifact_bytes_v2,
    canonical_evaluation_evidence_bytes_v2,
    verify_attempt_failure_v2,
    verify_development_ledger_v2,
    verify_validation_neighbor_manifest_v2,
    verify_validation_selection_v2,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    CALIBRATION_PLAN_V2_FILE_SHA256,
    DEVELOPMENT_SPLIT,
    FAILURE_TYPE_CONSTRAINT,
    FAILURE_TYPE_EVALUATION,
    FAILURE_TYPE_EVIDENCE_INTEGRITY,
    VALIDATION_SPLIT,
    NonAshSelectorEvaluationFailureV2,
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorEvaluationV2,
    canonical_rule_values_v2,
    non_ash_validation_neighborhood_v2,
    rule_mapping_v2,
    rule_sha256_v2,
    run_non_ash_development_search_v2,
)
from validation.calibration_v2.production_providers import (
    ContentAddressedEvidenceStore,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
SCHEMA_ROOT = CALIBRATION_ROOT / "schemas"


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _self_hash(document: dict[str, object], field: str) -> dict[str, object]:
    result = deepcopy(document)
    result[field] = "1" * 64
    unhashed = dict(result)
    unhashed.pop(field)
    result[field] = hashlib.sha256(
        canonical_artifact_bytes_v2(unhashed)
    ).hexdigest()
    return result


class DictSubclass(dict):
    pass


class ListSubclass(list):
    pass


class IntSubclass(int):
    pass


class NonAshSelectorArtifactV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        overlay_path = (
            CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
        )
        overlay_payload = overlay_path.read_bytes()
        overlay = json.loads(overlay_payload)
        cls.profile = parse_baseline_ablation_budget_v2(
            overlay_payload,
            schema_payload=(
                SCHEMA_ROOT / "baseline-ablation-budget-v2.schema.json"
            ).read_bytes(),
            authority_payloads={
                binding["id"]: (ROOT / binding["path"]).read_bytes()
                for binding in overlay["authority_bindings"]
            },
        )
        cls.scope = NonAshSelectorEvaluationScopeV2(
            shared_bank_configuration_sha256=_digest("shared-bank"),
            degradation_policy_sha256=_digest("degradation-policy"),
            calibration_plan_file_sha256=CALIBRATION_PLAN_V2_FILE_SHA256,
            cached_16_operator_output_manifest_sha256=_digest(
                "cached-16-operator-output-manifest"
            ),
        )
        ledger_schema = json.loads(
            (
                SCHEMA_ROOT / "non-ash-selector-attempt-ledger-v2.schema.json"
            ).read_bytes()
        )
        cls.authority_bindings = deepcopy(
            ledger_schema["$defs"]["authorityBindings"]["const"]
        )
        cls.serialization = {
            "coordinate_order": list(cls.profile.coordinate_order),
            "encoding": "UTF-8",
            "hash_algorithm": "SHA-256",
            "hash_input": (
                "canonical sorted-key compact UTF-8 JSON object with exactly "
                "the 27 coordinate_order names as keys and their signed integer "
                "values; no BOM and no trailing newline"
            ),
            "value_order": list(cls.profile.values),
        }
        cls.selection_objective = {
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
        (
            cls.development_result,
            cls.development_evidence,
            cls.development_outcomes,
        ) = (
            cls._run_development_search()
        )
        development_manifest_payload = (
            b"development candidate evidence manifest fixture\n"
        )
        cls.immutable_content = {
            hashlib.sha256(development_manifest_payload).hexdigest(): (
                development_manifest_payload
            )
        }
        cls.ledger = cls._ledger_document()
        cls.development_selection = cls._development_selection_document()
        cls.neighbors = cls._neighbor_document()
        cls.validation_evidence: dict[str, bytes] = {}
        cls.validation_selection = cls._validation_selection_document()

    @classmethod
    def _base(cls, artifact_kind: str) -> dict[str, object]:
        schema_version = {
            ATTEMPT_FAILURE_KIND: "2.0.2",
            ATTEMPT_LEDGER_KIND: "2.0.1",
            SELECTION_KIND: "2.0.2",
            NEIGHBOR_MANIFEST_KIND: "2.0.1",
        }[artifact_kind]
        return {
            "schema_version": schema_version,
            "artifact_kind": artifact_kind,
            "selector_id": cls.profile.selector_id,
            "authority_bindings": deepcopy(cls.authority_bindings),
            "canonical_rule_serialization": deepcopy(cls.serialization),
            "shared_bank_configuration_sha256": (
                cls.scope.shared_bank_configuration_sha256
            ),
            "degradation_policy_sha256": cls.scope.degradation_policy_sha256,
            "cached_16_operator_output_manifest_sha256": (
                cls.scope.cached_16_operator_output_manifest_sha256
            ),
        }

    @staticmethod
    def _data_access(*, validation: bool, development: bool = True):
        return {
            "development_metrics_accessed": development,
            "validation_accessed": validation,
            "holdout_accessed": False,
            "media_payloads_accessed": False,
            "release_locks_written": False,
            "winner_claim_made": False,
        }

    @classmethod
    def _evaluation_evidence_payload(
        cls,
        *,
        split: str,
        rule_sha256: str,
        objective_summary_sha256: str,
        output_manifest_sha256: str,
        objective_means: tuple[object, ...],
    ) -> bytes:
        return canonical_evaluation_evidence_bytes_v2(
            selector_id=cls.profile.selector_id,
            split=split,
            evaluation_scope=cls.scope,
            rule_sha256=rule_sha256,
            objective_summary_sha256=objective_summary_sha256,
            output_manifest_sha256=output_manifest_sha256,
            objective_means=objective_means,
        )

    @classmethod
    def _run_development_search(cls):
        evidence: dict[str, bytes] = {}
        outcomes: dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule):
            values = canonical_rule_values_v2(rule, cls.profile)
            rule_sha256 = rule_sha256_v2(values, cls.profile)
            objective = (-sum(abs(value) for value in values), 4, 3, 2, 1)
            objective_summary_sha256 = _digest(
                f"development-objective:{rule_sha256}"
            )
            output_manifest_sha256 = _digest(
                f"development-output:{rule_sha256}"
            )
            payload = cls._evaluation_evidence_payload(
                split=DEVELOPMENT_SPLIT,
                rule_sha256=rule_sha256,
                objective_summary_sha256=objective_summary_sha256,
                output_manifest_sha256=output_manifest_sha256,
                objective_means=objective,
            )
            evaluation_sha256 = hashlib.sha256(payload).hexdigest()
            result = NonAshSelectorEvaluationV2(
                split=DEVELOPMENT_SPLIT,
                scope=cls.scope,
                rule_sha256=rule_sha256,
                evaluation_sha256=evaluation_sha256,
                objective_summary_sha256=objective_summary_sha256,
                output_manifest_sha256=output_manifest_sha256,
                objective_means=objective,
            )
            evidence[evaluation_sha256] = payload
            outcomes[evaluation_sha256] = result
            return result

        def reopen(digest):
            return outcomes[digest]

        return (
            run_non_ash_development_search_v2(
                cls.profile,
                cls.scope,
                evaluator,
                reopen,
            ),
            evidence,
            outcomes,
        )

    @classmethod
    def _outcome_row(cls, outcome):
        if type(outcome) is NonAshSelectorEvaluationV2:
            return {
                "outcome_type": "evaluated",
                "evaluation_sha256": outcome.evaluation_sha256,
                "objective_summary_sha256": outcome.objective_summary_sha256,
                "engine_raw_corpus_mean_tuple": list(outcome.objective_means),
                "output_manifest_sha256": outcome.output_manifest_sha256,
            }
        if type(outcome) is NonAshSelectorEvaluationFailureV2:
            return {
                "outcome_type": "failed",
                "failure_type": outcome.failure_type,
                "attempt_failure_sha256": outcome.attempt_failure_sha256,
            }
        raise AssertionError("fixture development trace unexpectedly failed")

    @classmethod
    def _ledger_document(cls) -> dict[str, object]:
        result = cls.development_result
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
                "outcome": cls._outcome_row(record.outcome),
                "previous_record_sha256": record.previous_record_sha256,
                "record_sha256": record.record_sha256,
            }
            for record in result.attempt_records
        ]
        terminal = result.incumbent_evaluation
        if terminal is None or result.terminal_rule_values is None:
            raise AssertionError("fixture development did not converge")
        document = cls._base(ATTEMPT_LEDGER_KIND)
        document.update(
            {
                "attempt_schedule": {
                    "initial_attempt_ordinal": 0,
                    "maximum_sweeps": 18,
                    "coordinate_count": 27,
                    "values_per_coordinate": 7,
                    "attempts_per_complete_sweep": 189,
                    "maximum_attempt_count": 3403,
                    "coordinate_order": list(cls.profile.coordinate_order),
                    "value_order": list(cls.profile.values),
                    "coordinate_scan_attempt_ordinal_formula": (
                        "1 + (sweep - 1) * 189 + coordinate_ordinal * 7 + "
                        "value_ordinal"
                    ),
                    "cache_hits_must_be_recorded": True,
                },
                "split": DEVELOPMENT_SPLIT,
                "run_id": "semantic-persistence-fixture",
                "maximum_attempt_count": 3403,
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
                "terminal_attempt_ordinal": 0,
                "terminal_rule_sha256": result.terminal_rule_sha256,
                "terminal_rule_values": list(result.terminal_rule_values),
                "terminal_objective_summary_sha256": (
                    terminal.objective_summary_sha256
                ),
                "terminal_engine_raw_corpus_mean_tuple": list(
                    terminal.objective_means
                ),
                "data_access": cls._data_access(validation=False),
                "ledger_sha256": "1" * 64,
            }
        )
        return _self_hash(document, "ledger_sha256")

    @classmethod
    def _development_selection_document(cls) -> dict[str, object]:
        ledger = cls.ledger
        document = cls._base(SELECTION_KIND)
        document.update(
            {
                "selection_stage": "development_provisional",
                "split": DEVELOPMENT_SPLIT,
                "uniform_application": True,
                "candidate_evaluation_budget": 3403,
                "maximum_validation_candidate_count": 163,
                "selection_objective": deepcopy(cls.selection_objective),
                "development_attempt_count": ledger["attempt_count"],
                "development_last_attempt_ordinal": ledger[
                    "last_attempt_ordinal"
                ],
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
                "development_terminal_rule_values": deepcopy(
                    ledger["terminal_rule_values"]
                ),
                "development_objective_summary_sha256": ledger[
                    "terminal_objective_summary_sha256"
                ],
                "development_engine_raw_corpus_mean_tuple": deepcopy(
                    ledger["terminal_engine_raw_corpus_mean_tuple"]
                ),
                "data_access": cls._data_access(validation=False),
                "tie_break": (
                    "lexicographically maximize the development engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending canonical serialized complete 27-member rule object"
                ),
                "development_selection_sha256": "1" * 64,
            }
        )
        return _self_hash(document, "development_selection_sha256")

    @classmethod
    def _neighbor_document(cls) -> dict[str, object]:
        result = cls.development_result
        if result.terminal_rule_values is None:
            raise AssertionError("fixture has no terminal rule")
        expected = non_ash_validation_neighborhood_v2(
            cls.profile,
            rule_mapping_v2(result.terminal_rule_values, cls.profile),
        )
        latest = {
            record.rule_sha256: record.outcome
            for record in result.attempt_records
        }
        candidates = []
        for candidate in expected:
            evidence = latest[candidate.rule_sha256]
            entry: dict[str, object] = {
                "validation_candidate_ordinal": candidate.candidate_ordinal,
                "candidate_kind": (
                    "terminal" if candidate.terminal else "one_coordinate_neighbor"
                ),
                "rule_sha256": candidate.rule_sha256,
                "canonical_rule_values": list(candidate.canonical_rule_values),
                "development_evidence_sha256": evidence.evaluation_sha256,
                "neighbor_entry_sha256": "1" * 64,
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
            entry = _self_hash(entry, "neighbor_entry_sha256")
            candidates.append(entry)
        document = cls._base(NEIGHBOR_MANIFEST_KIND)
        document.update(
            {
                "neighbor_generation": {
                    "terminal_candidate_count": 1,
                    "coordinate_count": 27,
                    "noncurrent_values_per_coordinate": 6,
                    "validation_candidate_count": 163,
                    "candidate_order": (
                        "terminal rule first, then coordinate_order, then "
                        "ascending noncurrent value_order"
                    ),
                    "neighbor_ordinal_formula": (
                        "1 + coordinate_ordinal * 6 + noncurrent_value_ordinal"
                    ),
                    "adaptive_expansion_allowed": False,
                },
                "source_split": DEVELOPMENT_SPLIT,
                "target_split": VALIDATION_SPLIT,
                "development_attempt_count": cls.ledger["attempt_count"],
                "development_last_attempt_ordinal": cls.ledger[
                    "last_attempt_ordinal"
                ],
                "development_attempt_ledger_sha256": cls.ledger[
                    "ledger_sha256"
                ],
                "development_attempt_ledger_tip_sha256": cls.ledger[
                    "last_record_sha256"
                ],
                "development_selection_sha256": cls.development_selection[
                    "development_selection_sha256"
                ],
                "development_candidate_evidence_manifest_sha256": next(
                    iter(cls.immutable_content)
                ),
                "terminal_rule_sha256": result.terminal_rule_sha256,
                "terminal_rule_values": list(result.terminal_rule_values),
                "maximum_validation_candidate_count": 163,
                "validation_candidate_count": 163,
                "candidate_rule_sha256_values": [
                    candidate["rule_sha256"] for candidate in candidates
                ],
                "candidates": candidates,
                "data_access": cls._data_access(validation=False),
                "manifest_sha256": "1" * 64,
            }
        )
        return _self_hash(document, "manifest_sha256")

    @classmethod
    def _validation_selection_document(
        cls,
        *,
        failure_reference: ArtifactReferenceV2 | None = None,
    ) -> dict[str, object]:
        results = []
        scored = []
        for candidate in cls.neighbors["candidates"]:
            ordinal = candidate["validation_candidate_ordinal"]
            values = tuple(candidate["canonical_rule_values"])
            if failure_reference is not None and ordinal == 162:
                outcome = {
                    "outcome_type": "failed",
                    "failure_type": FAILURE_TYPE_EVALUATION,
                    "attempt_failure_sha256": failure_reference.sha256,
                }
            else:
                objective = (-sum(abs(value) for value in values), 4, 3, 2, 1)
                objective_summary_sha256 = _digest(
                    f"validation-objective:{candidate['rule_sha256']}"
                )
                output_manifest_sha256 = _digest(
                    f"validation-output:{candidate['rule_sha256']}"
                )
                payload = cls._evaluation_evidence_payload(
                    split=VALIDATION_SPLIT,
                    rule_sha256=candidate["rule_sha256"],
                    objective_summary_sha256=objective_summary_sha256,
                    output_manifest_sha256=output_manifest_sha256,
                    objective_means=objective,
                )
                evaluation_sha256 = hashlib.sha256(payload).hexdigest()
                outcome = {
                    "outcome_type": "scored",
                    "evaluation_sha256": evaluation_sha256,
                    "objective_summary_sha256": objective_summary_sha256,
                    "engine_raw_corpus_mean_tuple": list(objective),
                    "output_manifest_sha256": output_manifest_sha256,
                }
                cls.validation_evidence[evaluation_sha256] = payload
                scored.append((objective, candidate, outcome))
            results.append(
                {
                    "validation_candidate_ordinal": ordinal,
                    "neighbor_entry_sha256": candidate["neighbor_entry_sha256"],
                    "rule_sha256": candidate["rule_sha256"],
                    "outcome": outcome,
                }
            )
        winner = max(
            scored,
            key=lambda item: (
                item[0],
                bytes(
                    255 - member
                    for member in canonical_artifact_bytes_v2(
                        rule_mapping_v2(
                            tuple(item[1]["canonical_rule_values"]),
                            cls.profile,
                        )
                    )
                ),
            ),
        )
        document = cls._base(SELECTION_KIND)
        document.update(
            {
                "selection_stage": "validation_final",
                "split": VALIDATION_SPLIT,
                "uniform_application": True,
                "candidate_evaluation_budget": 3403,
                "maximum_validation_candidate_count": 163,
                "selection_objective": deepcopy(cls.selection_objective),
                "development_selection_sha256": cls.development_selection[
                    "development_selection_sha256"
                ],
                "development_terminal_rule_sha256": cls.development_selection[
                    "development_terminal_rule_sha256"
                ],
                "validation_neighbor_manifest_sha256": cls.neighbors[
                    "manifest_sha256"
                ],
                "validation_candidate_count": 163,
                "validation_results": results,
                "validation_status": "selected",
                "selected_control_rule_sha256": winner[1]["rule_sha256"],
                "selected_control_rule_values": deepcopy(
                    winner[1]["canonical_rule_values"]
                ),
                "validation_objective_summary_sha256": winner[2][
                    "objective_summary_sha256"
                ],
                "data_access": cls._data_access(validation=True),
                "tie_break": (
                    "lexicographically maximize the validation engine_raw "
                    "corpus-mean tuple, then choose the lexicographically "
                    "ascending canonical serialized complete 27-member rule object"
                ),
                "validation_selection_sha256": "1" * 64,
            }
        )
        return _self_hash(document, "validation_selection_sha256")

    @classmethod
    def _failure_document(
        cls,
        *,
        ordinal: int,
        candidate: dict[str, object],
        evidence_binding: dict[str, object] | None = None,
    ) -> dict[str, object]:
        document = cls._base(ATTEMPT_FAILURE_KIND)
        document.update(
            {
                "split": VALIDATION_SPLIT,
                "attempt_ordinal": ordinal,
                "rule_sha256": candidate["rule_sha256"],
                "canonical_rule_values": deepcopy(
                    candidate["canonical_rule_values"]
                ),
                "failure_type": FAILURE_TYPE_EVALUATION,
                "failure_code": "selector.fixture_evaluator",
                "failure_message": "fixture evaluation failed",
                "failure_details": {
                    "evaluator_error_type": "FixtureEvaluationError",
                    "evaluation_request_sha256": _digest(
                        f"validation-request:{ordinal}"
                    ),
                },
                "evidence_bindings": (
                    [] if evidence_binding is None else [evidence_binding]
                ),
                "data_access": cls._data_access(validation=True),
                "failure_sha256": "1" * 64,
            }
        )
        return _self_hash(document, "failure_sha256")

    @classmethod
    def _aborted_development_fixture(cls, failure_type: str):
        values = tuple(
            cls.profile.initial_value for _ in cls.profile.coordinate_order
        )
        rule_sha256 = rule_sha256_v2(values, cls.profile)
        binding_payload = (
            f"{failure_type} development diagnostic\n".encode("utf-8")
        )
        binding = {
            "id": f"{failure_type}_diagnostic",
            "path": f"logs/{failure_type}.log",
            "sha256": hashlib.sha256(binding_payload).hexdigest(),
            "size_bytes": len(binding_payload),
        }
        details_by_type = {
            FAILURE_TYPE_CONSTRAINT: {
                "constraint_codes": ["fixture_constraint"],
            },
            FAILURE_TYPE_EVALUATION: {
                "evaluator_error_type": "FixtureEvaluationError",
                "evaluation_request_sha256": _digest(
                    "development-evaluation-request"
                ),
            },
            FAILURE_TYPE_EVIDENCE_INTEGRITY: {
                "binding_id": "source_manifest",
                "expected_sha256": _digest("expected-source-manifest"),
                "observed_sha256": _digest("observed-source-manifest"),
            },
        }
        if failure_type not in details_by_type:
            raise AssertionError("unsupported fixture failure type")
        failure = cls._base(ATTEMPT_FAILURE_KIND)
        failure.update(
            {
                "split": DEVELOPMENT_SPLIT,
                "attempt_ordinal": 0,
                "rule_sha256": rule_sha256,
                "canonical_rule_values": list(values),
                "failure_type": failure_type,
                "failure_code": f"selector.fixture_{failure_type}",
                "failure_message": f"fixture {failure_type}",
                "failure_details": details_by_type[failure_type],
                "evidence_bindings": [binding],
                "data_access": cls._data_access(validation=False),
                "failure_sha256": "1" * 64,
            }
        )
        failure = _self_hash(failure, "failure_sha256")
        failure_content_sha256 = hashlib.sha256(
            canonical_artifact_bytes_v2(failure)
        ).hexdigest()
        outcome = NonAshSelectorEvaluationFailureV2(
            split=DEVELOPMENT_SPLIT,
            scope=cls.scope,
            rule_sha256=rule_sha256,
            failure_type=failure_type,
            attempt_failure_sha256=failure_content_sha256,
        )
        result = run_non_ash_development_search_v2(
            cls.profile,
            cls.scope,
            lambda rule: outcome,
            lambda digest: (_ for _ in ()).throw(AssertionError(digest)),
        )
        record = result.attempt_records[0]
        ledger = cls._base(ATTEMPT_LEDGER_KIND)
        ledger.update(
            {
                "attempt_schedule": deepcopy(cls.ledger["attempt_schedule"]),
                "split": DEVELOPMENT_SPLIT,
                "run_id": f"aborted-{failure_type}-fixture",
                "maximum_attempt_count": 3403,
                "attempt_count": 1,
                "unique_evaluation_count": 0,
                "cache_hit_count": 0,
                "first_attempt_ordinal": 0,
                "last_attempt_ordinal": 0,
                "records": [
                    {
                        "attempt_ordinal": record.attempt_ordinal,
                        "phase": record.phase,
                        "sweep": record.sweep,
                        "coordinate_ordinal": record.coordinate_ordinal,
                        "coordinate_name": record.coordinate_name,
                        "coordinate_value": record.coordinate_value,
                        "rule_sha256": record.rule_sha256,
                        "canonical_rule_values": list(
                            record.canonical_rule_values
                        ),
                        "cache_hit": record.cache_hit,
                        "outcome": cls._outcome_row(record.outcome),
                        "previous_record_sha256": (
                            record.previous_record_sha256
                        ),
                        "record_sha256": record.record_sha256,
                    }
                ],
                "last_record_sha256": record.record_sha256,
                "completed_sweep_count": 0,
                "terminal_status": "aborted",
                "termination_reason": "attempt_failure_abort",
                "terminal_failure_type": "attempt_failure_abort",
                "terminal_failure_sha256": failure_content_sha256,
                "data_access": cls._data_access(validation=False),
                "ledger_sha256": "1" * 64,
            }
        )
        return (
            _self_hash(ledger, "ledger_sha256"),
            failure,
            binding_payload,
            result,
        )

    @classmethod
    def _failed_all_validation_selection_document(cls):
        selection = deepcopy(cls.validation_selection)
        failures: dict[str, dict[str, object]] = {}
        for candidate, row in zip(
            cls.neighbors["candidates"],
            selection["validation_results"],
        ):
            ordinal = candidate["validation_candidate_ordinal"]
            failure = cls._failure_document(
                ordinal=ordinal,
                candidate=candidate,
            )
            digest = hashlib.sha256(
                canonical_artifact_bytes_v2(failure)
            ).hexdigest()
            failures[digest] = failure
            row["outcome"] = {
                "outcome_type": "failed",
                "failure_type": FAILURE_TYPE_EVALUATION,
                "attempt_failure_sha256": digest,
            }
        terminal_payload = b"failed-all validation terminal failure fixture\n"
        selection["validation_status"] = "failed_all_candidates"
        selection["validation_terminal_failure_sha256"] = hashlib.sha256(
            terminal_payload
        ).hexdigest()
        selection.pop("selected_control_rule_sha256")
        selection.pop("selected_control_rule_values")
        selection.pop("validation_objective_summary_sha256")
        return (
            _self_hash(selection, "validation_selection_sha256"),
            failures,
            terminal_payload,
        )

    @classmethod
    def _maximum_sweeps_ledger_document(cls):
        evidence: dict[str, bytes] = {}
        outcomes: dict[str, NonAshSelectorEvaluationV2] = {}

        def evaluator(rule):
            values = canonical_rule_values_v2(rule, cls.profile)
            rule_sha256 = rule_sha256_v2(values, cls.profile)
            wave = values[-18:]
            bits = tuple(value == 128 for value in wave)
            penalty = sum(abs(value) for value in values[:-18])
            score = (
                (1 << 19) * int(bits[-1])
                + sum(
                    (1 << index) * int(bits[index] == bits[index + 1])
                    for index in range(17)
                )
                - 1_000_000_000 * penalty
            )
            objective_summary_sha256 = _digest(
                f"maximum-sweeps-objective:{rule_sha256}"
            )
            output_manifest_sha256 = _digest(
                f"maximum-sweeps-output:{rule_sha256}"
            )
            objective_means = (score, 0, 0, 0, 0)
            payload = cls._evaluation_evidence_payload(
                split=DEVELOPMENT_SPLIT,
                rule_sha256=rule_sha256,
                objective_summary_sha256=objective_summary_sha256,
                output_manifest_sha256=output_manifest_sha256,
                objective_means=objective_means,
            )
            evaluation_sha256 = hashlib.sha256(payload).hexdigest()
            result = NonAshSelectorEvaluationV2(
                split=DEVELOPMENT_SPLIT,
                scope=cls.scope,
                rule_sha256=rule_sha256,
                evaluation_sha256=evaluation_sha256,
                objective_summary_sha256=objective_summary_sha256,
                output_manifest_sha256=output_manifest_sha256,
                objective_means=objective_means,
            )
            evidence[evaluation_sha256] = payload
            outcomes[evaluation_sha256] = result
            return result

        result = run_non_ash_development_search_v2(
            cls.profile,
            cls.scope,
            evaluator,
            lambda digest: outcomes[digest],
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
                "outcome": cls._outcome_row(record.outcome),
                "previous_record_sha256": record.previous_record_sha256,
                "record_sha256": record.record_sha256,
            }
            for record in result.attempt_records
        ]
        terminal_payload = b"maximum sweeps terminal failure fixture\n"
        document = cls._base(ATTEMPT_LEDGER_KIND)
        document.update(
            {
                "attempt_schedule": deepcopy(cls.ledger["attempt_schedule"]),
                "split": DEVELOPMENT_SPLIT,
                "run_id": "maximum-sweeps-semantic-persistence-fixture",
                "maximum_attempt_count": 3403,
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
                "termination_reason": "maximum_sweeps_exhausted",
                "terminal_failure_type": "maximum_sweeps_exhausted",
                "terminal_failure_sha256": hashlib.sha256(
                    terminal_payload
                ).hexdigest(),
                "data_access": cls._data_access(validation=False),
                "ledger_sha256": "1" * 64,
            }
        )
        return (
            _self_hash(document, "ledger_sha256"),
            evidence,
            terminal_payload,
        )

    @classmethod
    def _development_reopener(cls, digest: str):
        return cls.development_evidence[digest]

    @classmethod
    def _validation_reopener(cls, digest: str):
        return cls.validation_evidence[digest]

    @classmethod
    def _immutable_reopener(cls, digest: str):
        return cls.immutable_content[digest]

    def test_canonical_codec_rejects_aliases_nonfinite_and_duplicate_bytes(self) -> None:
        document = {"b": [1, True, None], "a": "value"}
        self.assertEqual(
            canonical_artifact_bytes_v2(document),
            b'{"a":"value","b":[1,true,null]}',
        )
        invalid_values = (
            DictSubclass(document),
            {"value": ListSubclass([1])},
            {"value": IntSubclass(1)},
            {"value": float("nan")},
            {"value": float("inf")},
        )
        for value in invalid_values:
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(NonAshSelectorArtifactV2Error):
                    canonical_artifact_bytes_v2(value)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "store"
            store = NonAshSelectorArtifactStoreV2(root)
            payload = b'{"a":1,"a":1}'
            digest = hashlib.sha256(payload).hexdigest()
            (root / "documents" / f"{digest}.json").write_bytes(payload)
            with self.assertRaises(NonAshSelectorArtifactV2Error):
                store.reopen_content_address(digest)

    def test_full_family_atomically_round_trips_with_exact_references(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "store"
            store = NonAshSelectorArtifactStoreV2(root)
            ledger_ref = store.publish(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )
            self.assertEqual(
                ledger_ref.sha256,
                hashlib.sha256(canonical_artifact_bytes_v2(self.ledger)).hexdigest(),
            )
            self.assertEqual(
                ledger_ref.size_bytes,
                len(canonical_artifact_bytes_v2(self.ledger)),
            )
            development_ref = store.publish(
                self.development_selection,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_evidence_reopener=self._development_reopener,
            )
            neighbor_ref = store.publish(
                self.neighbors,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_selection_reference=development_ref,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )
            validation_ref = store.publish(
                self.validation_selection,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_selection_reference=development_ref,
                validation_neighbor_manifest_reference=neighbor_ref,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )
            self.assertEqual(
                store.reopen(
                    ledger_ref,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                ),
                self.ledger,
            )
            self.assertEqual(
                store.reopen(
                    development_ref,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_ref,
                    development_evidence_reopener=self._development_reopener,
                ),
                self.development_selection,
            )
            self.assertEqual(
                store.reopen(
                    neighbor_ref,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_ref,
                    development_selection_reference=development_ref,
                    development_evidence_reopener=self._development_reopener,
                    immutable_content_reopener=self._immutable_reopener,
                ),
                self.neighbors,
            )
            self.assertEqual(
                store.reopen(
                    validation_ref,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_ref,
                    development_selection_reference=development_ref,
                    validation_neighbor_manifest_reference=neighbor_ref,
                    development_evidence_reopener=self._development_reopener,
                    validation_evidence_reopener=self._validation_reopener,
                    immutable_content_reopener=self._immutable_reopener,
                ),
                self.validation_selection,
            )
            self.assertEqual(
                store.publish(
                    self.ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                ),
                ledger_ref,
            )
            self.assertTrue((root / "documents" / f"{ledger_ref.sha256}.json").is_file())

    def test_semantic_replay_rejects_chain_terminal_neighbor_and_winner_tamper(self) -> None:
        broken_chain = deepcopy(self.ledger)
        broken_chain["records"][1]["record_sha256"] = _digest("wrong-record")
        broken_chain = _self_hash(broken_chain, "ledger_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "semantic replay",
        ):
            verify_development_ledger_v2(
                broken_chain,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )

        wrong_terminal = deepcopy(self.ledger)
        wrong_terminal["terminal_attempt_ordinal"] = 1
        wrong_terminal = _self_hash(wrong_terminal, "ledger_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "terminal provenance",
        ):
            verify_development_ledger_v2(
                wrong_terminal,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )

        wrong_neighbor = deepcopy(self.neighbors)
        wrong_neighbor["candidates"][1]["development_evidence_sha256"] = _digest(
            "wrong-development-evidence"
        )
        wrong_neighbor["candidates"][1] = _self_hash(
            wrong_neighbor["candidates"][1],
            "neighbor_entry_sha256",
        )
        wrong_neighbor = _self_hash(wrong_neighbor, "manifest_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "neighbor entry semantics",
        ):
            verify_validation_neighbor_manifest_v2(
                wrong_neighbor,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

        wrong_winner = deepcopy(self.validation_selection)
        wrong_winner["selected_control_rule_sha256"] = self.neighbors[
            "candidates"
        ][1]["rule_sha256"]
        wrong_winner["selected_control_rule_values"] = deepcopy(
            self.neighbors["candidates"][1]["canonical_rule_values"]
        )
        wrong_winner["validation_objective_summary_sha256"] = wrong_winner[
            "validation_results"
        ][1]["outcome"]["objective_summary_sha256"]
        wrong_winner = _self_hash(wrong_winner, "validation_selection_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "selected rule",
        ):
            verify_validation_selection_v2(
                wrong_winner,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

    def test_typed_failure_reopens_content_and_every_declared_byte_binding(self) -> None:
        candidate = self.neighbors["candidates"][162]
        bound_payload = b"typed evaluator failure evidence\n"
        binding = {
            "id": "fixture_evaluator_log",
            "path": "logs/fixture-evaluator.log",
            "sha256": hashlib.sha256(bound_payload).hexdigest(),
            "size_bytes": len(bound_payload),
        }
        failure = self._failure_document(
            ordinal=162,
            candidate=candidate,
            evidence_binding=binding,
        )
        with tempfile.TemporaryDirectory() as temporary:
            store = NonAshSelectorArtifactStoreV2(
                Path(temporary).resolve() / "store"
            )
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "byte reopener",
            ):
                store.publish(failure, self.profile, self.scope)
            failure_ref = store.publish(
                failure,
                self.profile,
                self.scope,
                evidence_binding_reopener=lambda row: bound_payload,
            )
            ledger_ref = store.publish(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )
            development_ref = store.publish(
                self.development_selection,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_evidence_reopener=self._development_reopener,
            )
            neighbor_ref = store.publish(
                self.neighbors,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_selection_reference=development_ref,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )
            selection = self._validation_selection_document(
                failure_reference=failure_ref,
            )
            selection_ref = store.publish(
                selection,
                self.profile,
                self.scope,
                development_ledger_reference=ledger_ref,
                development_selection_reference=development_ref,
                validation_neighbor_manifest_reference=neighbor_ref,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
                failure_reopener=store.reopen_content_address,
                evidence_binding_reopener=lambda row: bound_payload,
            )
            self.assertEqual(
                store.reopen(
                    selection_ref,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_ref,
                    development_selection_reference=development_ref,
                    validation_neighbor_manifest_reference=neighbor_ref,
                    development_evidence_reopener=self._development_reopener,
                    validation_evidence_reopener=self._validation_reopener,
                    immutable_content_reopener=self._immutable_reopener,
                    failure_reopener=store.reopen_content_address,
                    evidence_binding_reopener=lambda row: bound_payload,
                ),
                selection,
            )
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "typed failure content reopener",
            ):
                verify_validation_selection_v2(
                    selection,
                    self.profile,
                    self.scope,
                    development_ledger=self.ledger,
                    development_selection=self.development_selection,
                    validation_neighbor_manifest=self.neighbors,
                    development_evidence_reopener=self._development_reopener,
                    validation_evidence_reopener=self._validation_reopener,
                    immutable_content_reopener=self._immutable_reopener,
                )

    def test_aborted_development_ledgers_preserve_all_typed_failures(self) -> None:
        failure_types = (
            FAILURE_TYPE_CONSTRAINT,
            FAILURE_TYPE_EVALUATION,
            FAILURE_TYPE_EVIDENCE_INTEGRITY,
        )
        for failure_type in failure_types:
            with self.subTest(failure_type=failure_type):
                ledger, failure, bound_payload, expected_result = (
                    self._aborted_development_fixture(failure_type)
                )
                failure_digest = hashlib.sha256(
                    canonical_artifact_bytes_v2(failure)
                ).hexdigest()
                reopened_bindings = []

                def reopen_binding(row):
                    reopened_bindings.append(deepcopy(row))
                    return bound_payload

                def reject_evaluation_reopen(digest: str) -> bytes:
                    raise AssertionError(
                        f"failure-only ledger reopened evaluation {digest}"
                    )

                verified = verify_development_ledger_v2(
                    ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=reject_evaluation_reopen,
                    failure_reopener=lambda digest: failure,
                    evidence_binding_reopener=reopen_binding,
                )
                self.assertEqual(verified.status, "aborted")
                self.assertEqual(verified.attempt_count, 1)
                self.assertEqual(verified.unique_evaluation_count, 0)
                self.assertEqual(
                    ledger["terminal_failure_sha256"],
                    failure_digest,
                )
                self.assertEqual(len(reopened_bindings), 1)
                self.assertEqual(
                    reopened_bindings[0]["sha256"],
                    hashlib.sha256(bound_payload).hexdigest(),
                )

                with tempfile.TemporaryDirectory() as temporary:
                    store = NonAshSelectorArtifactStoreV2(
                        Path(temporary).resolve() / "store"
                    )
                    failure_reference = store.publish(
                        failure,
                        self.profile,
                        self.scope,
                        evidence_binding_reopener=reopen_binding,
                    )
                    self.assertEqual(failure_reference.sha256, failure_digest)
                    ledger_reference = store.publish(
                        ledger,
                        self.profile,
                        self.scope,
                        development_evidence_reopener=reject_evaluation_reopen,
                        failure_reopener=store.reopen_content_address,
                        evidence_binding_reopener=reopen_binding,
                    )
                    self.assertEqual(
                        store.reopen(
                            ledger_reference,
                            self.profile,
                            self.scope,
                            development_evidence_reopener=(
                                reject_evaluation_reopen
                            ),
                            failure_reopener=store.reopen_content_address,
                            evidence_binding_reopener=reopen_binding,
                        ),
                        ledger,
                    )

                with self.assertRaisesRegex(
                    NonAshSelectorArtifactV2Error,
                    "failure evidence binding bytes differ",
                ):
                    verify_development_ledger_v2(
                        ledger,
                        self.profile,
                        self.scope,
                        development_evidence_reopener=reject_evaluation_reopen,
                        failure_reopener=lambda digest: failure,
                        evidence_binding_reopener=lambda row: b"wrong",
                    )

                wrong_terminal = deepcopy(ledger)
                wrong_terminal["terminal_failure_sha256"] = _digest(
                    f"wrong-terminal:{failure_type}"
                )
                wrong_terminal = _self_hash(
                    wrong_terminal,
                    "ledger_sha256",
                )
                with self.assertRaisesRegex(
                    NonAshSelectorArtifactV2Error,
                    "aborted ledger failure differs",
                ):
                    verify_development_ledger_v2(
                        wrong_terminal,
                        self.profile,
                        self.scope,
                        development_evidence_reopener=reject_evaluation_reopen,
                        failure_reopener=lambda digest: failure,
                        evidence_binding_reopener=reopen_binding,
                    )

    def test_existing_different_bytes_and_reference_size_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "store"
            store = NonAshSelectorArtifactStoreV2(root)
            reference = store.publish(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )
            path = root / "documents" / f"{reference.sha256}.json"
            path.write_bytes(b"{}")
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "publication failed",
            ):
                store.publish(
                    self.ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                )
            changed_size = ArtifactReferenceV2(
                artifact_kind=reference.artifact_kind,
                sha256=reference.sha256,
                size_bytes=reference.size_bytes + 1,
                schema_sha256=reference.schema_sha256,
            )
            with self.assertRaises(NonAshSelectorArtifactV2Error):
                store.reopen(
                    changed_size,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                )

    def test_development_evidence_reopening_requires_content_addressed_bytes(self) -> None:
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "development evidence reopener is required",
        ):
            verify_development_ledger_v2(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=None,
            )

        first = self.development_result.attempt_records[0].outcome
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "returned non-bytes",
        ):
            verify_development_ledger_v2(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=lambda digest: (
                    self.development_outcomes[digest]
                ),
            )

        tampered = json.loads(
            self.development_evidence[first.evaluation_sha256]
        )
        tampered["engine_raw_corpus_mean_tuple"][0] = 999
        tampered_payload = canonical_artifact_bytes_v2(tampered)
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "content address differs",
        ):
            verify_development_ledger_v2(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=lambda digest: (
                    tampered_payload
                    if digest == first.evaluation_sha256
                    else self.development_evidence[digest]
                ),
            )

        cache_hit = next(
            record
            for record in self.development_result.attempt_records
            if record.cache_hit
        )
        calls: dict[str, int] = {}

        def cache_hit_tamper(digest: str):
            calls[digest] = calls.get(digest, 0) + 1
            expected = self.development_evidence[digest]
            if (
                digest == cache_hit.outcome.evaluation_sha256
                and calls[digest] > 1
            ):
                changed = json.loads(expected)
                changed["engine_raw_corpus_mean_tuple"][0] = 998
                return canonical_artifact_bytes_v2(changed)
            return expected

        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "content address differs",
        ):
            verify_development_ledger_v2(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=cache_hit_tamper,
            )
        self.assertGreater(calls[cache_hit.outcome.evaluation_sha256], 1)

    def test_development_evidence_round_trips_through_persistent_content_store(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence_root = root / "evaluation-evidence"
            evidence_store = ContentAddressedEvidenceStore(evidence_root)
            for digest, payload in self.development_evidence.items():
                binding = evidence_store.publish(json.loads(payload))
                self.assertEqual(binding["sha256"], digest)
                self.assertEqual(binding["size_bytes"], len(payload))

            def reopen_persisted(digest: str) -> bytes:
                return canonical_artifact_bytes_v2(
                    evidence_store.reopen(digest)
                )

            verified = verify_development_ledger_v2(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=reopen_persisted,
            )
            self.assertEqual(
                verified.attempt_count,
                self.development_result.attempt_count,
            )

            artifact_store = NonAshSelectorArtifactStoreV2(root / "artifacts")
            reference = artifact_store.publish(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=reopen_persisted,
            )
            self.assertEqual(
                artifact_store.reopen(
                    reference,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=reopen_persisted,
                ),
                self.ledger,
            )

            missing_digest = next(iter(self.development_evidence))
            (
                evidence_root / "documents" / f"{missing_digest}.json"
            ).unlink()
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "could not be reopened",
            ):
                verify_development_ledger_v2(
                    self.ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=reopen_persisted,
                )

    def test_validation_evidence_reopening_blocks_score_and_digest_forgery(self) -> None:
        forged_score = deepcopy(self.validation_selection)
        forged_score["validation_results"][0]["outcome"][
            "engine_raw_corpus_mean_tuple"
        ] = [999999, 999999, 999999, 999999, 999999]
        forged_score = _self_hash(
            forged_score,
            "validation_selection_sha256",
        )
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "differs from its recorded result",
        ):
            verify_validation_selection_v2(
                forged_score,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "validation evidence reopener is required",
        ):
            verify_validation_selection_v2(
                self.validation_selection,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

        forged_digest = deepcopy(self.validation_selection)
        forged_digest["validation_results"][0]["outcome"][
            "evaluation_sha256"
        ] = _digest("forged-validation-evaluation")
        forged_digest = _self_hash(
            forged_digest,
            "validation_selection_sha256",
        )
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "could not be reopened",
        ):
            verify_validation_selection_v2(
                forged_digest,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

        duplicate_digest = deepcopy(self.validation_selection)
        first_outcome = duplicate_digest["validation_results"][0]["outcome"]
        second_outcome = duplicate_digest["validation_results"][1]["outcome"]
        first_digest = first_outcome["evaluation_sha256"]
        second_outcome["evaluation_sha256"] = first_digest
        duplicate_digest = _self_hash(
            duplicate_digest,
            "validation_selection_sha256",
        )
        duplicate_calls = 0

        def stateful_validation_reopener(digest: str):
            nonlocal duplicate_calls
            if digest != first_digest:
                return self.validation_evidence[digest]
            duplicate_calls += 1
            return self.validation_evidence[first_digest]

        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "differs from its result",
        ):
            verify_validation_selection_v2(
                duplicate_digest,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=stateful_validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )
        self.assertEqual(duplicate_calls, 1)

        cross_split = deepcopy(self.validation_selection)
        development_digest = next(iter(self.development_evidence))
        cross_split["validation_results"][0]["outcome"][
            "evaluation_sha256"
        ] = development_digest
        cross_split = _self_hash(cross_split, "validation_selection_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "overlaps development",
        ):
            verify_validation_selection_v2(
                cross_split,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                validation_evidence_reopener=self._validation_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

    def test_external_neighbor_manifest_hash_requires_exact_bytes(self) -> None:
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "candidate-evidence manifest byte reopener is required",
        ):
            verify_validation_neighbor_manifest_v2(
                self.neighbors,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=None,
            )

        forged = deepcopy(self.neighbors)
        forged["development_candidate_evidence_manifest_sha256"] = _digest(
            "forged-development-candidate-evidence-manifest"
        )
        forged = _self_hash(forged, "manifest_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "could not be reopened",
        ):
            verify_validation_neighbor_manifest_v2(
                forged,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                development_evidence_reopener=self._development_reopener,
                immutable_content_reopener=self._immutable_reopener,
            )

    def test_store_requires_same_store_persisted_predecessor_references(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            first = NonAshSelectorArtifactStoreV2(root / "first")
            second = NonAshSelectorArtifactStoreV2(root / "second")
            ledger_ref = first.publish(
                self.ledger,
                self.profile,
                self.scope,
                development_evidence_reopener=self._development_reopener,
            )
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "could not be reopened",
            ):
                second.publish(
                    self.development_selection,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_ref,
                    development_evidence_reopener=self._development_reopener,
                )
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "unknown or raw predecessor",
            ):
                second.publish(
                    self.development_selection,
                    self.profile,
                    self.scope,
                    development_ledger=self.ledger,
                    development_evidence_reopener=self._development_reopener,
                )

    def test_publish_rejects_deleted_or_replaced_predecessor_after_callback(
        self,
    ) -> None:
        for operation in ("delete", "replace"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve() / "store"
                store = NonAshSelectorArtifactStoreV2(root)
                ledger_reference = store.publish(
                    self.ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                )
                predecessor_path = (
                    root
                    / "documents"
                    / f"{ledger_reference.sha256}.json"
                )
                mutated = False

                def mutating_reopener(digest: str) -> bytes:
                    nonlocal mutated
                    if not mutated:
                        mutated = True
                        if operation == "delete":
                            predecessor_path.unlink()
                        else:
                            predecessor_path.write_bytes(b"{}")
                    return self.development_evidence[digest]

                with self.assertRaisesRegex(
                    NonAshSelectorArtifactV2Error,
                    "predecessor changed during post-callback reopening",
                ):
                    store.publish(
                        self.development_selection,
                        self.profile,
                        self.scope,
                        development_ledger_reference=ledger_reference,
                        development_evidence_reopener=mutating_reopener,
                    )
                self.assertTrue(mutated)

    def test_reopen_rejects_deleted_or_replaced_predecessor_after_callback(
        self,
    ) -> None:
        for operation in ("delete", "replace"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve() / "store"
                store = NonAshSelectorArtifactStoreV2(root)
                ledger_reference = store.publish(
                    self.ledger,
                    self.profile,
                    self.scope,
                    development_evidence_reopener=self._development_reopener,
                )
                selection_reference = store.publish(
                    self.development_selection,
                    self.profile,
                    self.scope,
                    development_ledger_reference=ledger_reference,
                    development_evidence_reopener=self._development_reopener,
                )
                predecessor_path = (
                    root
                    / "documents"
                    / f"{ledger_reference.sha256}.json"
                )
                mutated = False

                def mutating_reopener(digest: str) -> bytes:
                    nonlocal mutated
                    if not mutated:
                        mutated = True
                        if operation == "delete":
                            predecessor_path.unlink()
                        else:
                            predecessor_path.write_bytes(b"{}")
                    return self.development_evidence[digest]

                with self.assertRaisesRegex(
                    NonAshSelectorArtifactV2Error,
                    "predecessor changed during post-callback reopening",
                ):
                    store.reopen(
                        selection_reference,
                        self.profile,
                        self.scope,
                        development_ledger_reference=ledger_reference,
                        development_evidence_reopener=mutating_reopener,
                    )
                self.assertTrue(mutated)
    def test_callback_mutation_cannot_change_profile_scope_or_published_bytes(self) -> None:
        development_profile = replace(
            self.profile,
            authority_identity=replace(self.profile.authority_identity),
        )
        development_scope = replace(self.scope)
        development_calls = 0

        def mutating_development_reopener(digest: str):
            nonlocal development_calls
            development_calls += 1
            object.__setattr__(
                development_scope,
                "shared_bank_configuration_sha256",
                _digest("mutated-development-scope"),
            )
            object.__setattr__(
                development_profile,
                "selector_id",
                "mutated-development-selector",
            )
            object.__setattr__(
                development_profile.authority_identity,
                "overlay_file_sha256",
                _digest("mutated-development-authority"),
            )
            return self.development_evidence[digest]

        result = verify_development_ledger_v2(
            self.ledger,
            development_profile,
            development_scope,
            development_evidence_reopener=mutating_development_reopener,
        )
        self.assertEqual(result.attempt_count, self.development_result.attempt_count)
        self.assertGreater(development_calls, 0)

        validation_profile = replace(
            self.profile,
            authority_identity=replace(self.profile.authority_identity),
        )
        validation_scope = replace(self.scope)
        validation_calls = 0

        def mutating_validation_reopener(digest: str):
            nonlocal validation_calls
            validation_calls += 1
            object.__setattr__(
                validation_scope,
                "degradation_policy_sha256",
                _digest("mutated-validation-scope"),
            )
            object.__setattr__(
                validation_profile,
                "maximum_sweeps",
                1,
            )
            object.__setattr__(
                validation_profile.authority_identity,
                "overlay_self_sha256",
                _digest("mutated-validation-authority"),
            )
            return self.validation_evidence[digest]

        verified = verify_validation_selection_v2(
            self.validation_selection,
            validation_profile,
            validation_scope,
            development_ledger=self.ledger,
            development_selection=self.development_selection,
            validation_neighbor_manifest=self.neighbors,
            development_evidence_reopener=self._development_reopener,
            validation_evidence_reopener=mutating_validation_reopener,
            immutable_content_reopener=self._immutable_reopener,
        )
        self.assertEqual(verified, self.validation_selection)
        self.assertEqual(validation_calls, 163)

        adversarial_scope = replace(self.scope)

        def scope_aliasing_validation_reopener(digest: str):
            object.__setattr__(
                adversarial_scope,
                "shared_bank_configuration_sha256",
                _digest("callback-substituted-validation-scope"),
            )
            return self.validation_evidence[digest]

        verified_alias = verify_validation_selection_v2(
            self.validation_selection,
            self.profile,
            adversarial_scope,
            development_ledger=self.ledger,
            development_selection=self.development_selection,
            validation_neighbor_manifest=self.neighbors,
            development_evidence_reopener=self._development_reopener,
            validation_evidence_reopener=scope_aliasing_validation_reopener,
            immutable_content_reopener=self._immutable_reopener,
        )
        self.assertEqual(verified_alias, self.validation_selection)

        candidate = self.neighbors["candidates"][0]
        bound_payload = b"callback mutation publication evidence\n"
        binding = {
            "id": "callback_mutation_log",
            "path": "logs/callback-mutation.log",
            "sha256": hashlib.sha256(bound_payload).hexdigest(),
            "size_bytes": len(bound_payload),
        }
        failure = self._failure_document(
            ordinal=0,
            candidate=candidate,
            evidence_binding=binding,
        )
        expected_failure = deepcopy(failure)
        binding_calls = 0

        def mutating_binding_reopener(row):
            nonlocal binding_calls
            binding_calls += 1
            failure["failure_message"] = "mutated after publication snapshot"
            row["sha256"] = _digest("mutated-callback-copy")
            return bound_payload

        with tempfile.TemporaryDirectory() as temporary:
            store = NonAshSelectorArtifactStoreV2(
                Path(temporary).resolve() / "store"
            )
            reference = store.publish(
                failure,
                self.profile,
                self.scope,
                evidence_binding_reopener=mutating_binding_reopener,
            )
            self.assertEqual(binding_calls, 1)
            self.assertEqual(
                store.reopen_content_address(reference.sha256),
                expected_failure,
            )

    def test_opaque_terminal_hashes_require_exact_reopened_bytes(self) -> None:
        exhausted, evidence, exhausted_terminal = (
            self._maximum_sweeps_ledger_document()
        )
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "maximum-sweeps terminal failure byte reopener is required",
        ):
            verify_development_ledger_v2(
                exhausted,
                self.profile,
                self.scope,
                development_evidence_reopener=lambda digest: evidence[digest],
            )
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "content address differs",
        ):
            verify_development_ledger_v2(
                exhausted,
                self.profile,
                self.scope,
                development_evidence_reopener=lambda digest: evidence[digest],
                immutable_content_reopener=lambda digest: b"wrong bytes",
            )
        exhausted_result = verify_development_ledger_v2(
            exhausted,
            self.profile,
            self.scope,
            development_evidence_reopener=lambda digest: evidence[digest],
            immutable_content_reopener=lambda digest: exhausted_terminal,
        )
        self.assertEqual(exhausted_result.status, "maximum_sweeps_exhausted")

        failed_all, failures, validation_terminal = (
            self._failed_all_validation_selection_document()
        )
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "failed-all validation terminal failure could not be reopened",
        ):
            verify_validation_selection_v2(
                failed_all,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                failure_reopener=lambda digest: failures[digest],
                immutable_content_reopener=self._immutable_reopener,
            )
        immutable = dict(self.immutable_content)
        immutable[hashlib.sha256(validation_terminal).hexdigest()] = (
            validation_terminal
        )
        verified = verify_validation_selection_v2(
            failed_all,
            self.profile,
            self.scope,
            development_ledger=self.ledger,
            development_selection=self.development_selection,
            validation_neighbor_manifest=self.neighbors,
            development_evidence_reopener=self._development_reopener,
            failure_reopener=lambda digest: failures[digest],
            immutable_content_reopener=lambda digest: immutable[digest],
        )
        self.assertEqual(verified, failed_all)

        shared_generic = deepcopy(failed_all)
        shared_digest = self.neighbors[
            "development_candidate_evidence_manifest_sha256"
        ]
        shared_generic["validation_terminal_failure_sha256"] = shared_digest
        shared_generic = _self_hash(
            shared_generic,
            "validation_selection_sha256",
        )
        generic_calls = 0

        def counting_immutable_reopener(digest: str):
            nonlocal generic_calls
            if digest == shared_digest:
                generic_calls += 1
            return self.immutable_content[digest]

        verify_validation_selection_v2(
            shared_generic,
            self.profile,
            self.scope,
            development_ledger=self.ledger,
            development_selection=self.development_selection,
            validation_neighbor_manifest=self.neighbors,
            development_evidence_reopener=self._development_reopener,
            failure_reopener=lambda digest: failures[digest],
            immutable_content_reopener=counting_immutable_reopener,
        )
        self.assertEqual(generic_calls, 1)

        duplicate_failure = deepcopy(failed_all)
        first_failure_digest = duplicate_failure["validation_results"][0][
            "outcome"
        ]["attempt_failure_sha256"]
        duplicate_failure["validation_results"][1]["outcome"][
            "attempt_failure_sha256"
        ] = first_failure_digest
        duplicate_failure = _self_hash(
            duplicate_failure,
            "validation_selection_sha256",
        )
        failure_calls = 0

        def stateful_failure_reopener(digest: str):
            nonlocal failure_calls
            if digest == first_failure_digest:
                failure_calls += 1
            return failures[digest]

        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "differs from its attempt",
        ):
            verify_validation_selection_v2(
                duplicate_failure,
                self.profile,
                self.scope,
                development_ledger=self.ledger,
                development_selection=self.development_selection,
                validation_neighbor_manifest=self.neighbors,
                development_evidence_reopener=self._development_reopener,
                failure_reopener=stateful_failure_reopener,
                immutable_content_reopener=lambda digest: immutable[digest],
            )
        self.assertEqual(failure_calls, 1)

    def test_symlinked_store_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            real = root / "real"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(
                NonAshSelectorArtifactV2Error,
                "store root is unsafe",
            ):
                NonAshSelectorArtifactStoreV2(alias / "store")

    def test_failure_binding_paths_are_portable_and_alias_free(self) -> None:
        candidate = self.neighbors["candidates"][0]
        payload = b"portable failure evidence\n"
        base_binding = {
            "id": "portable_evidence",
            "path": "logs/evidence.txt",
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size_bytes": len(payload),
        }
        unsafe_paths = (
            "logs/",
            "logs\\evil.log",
            "logs/evil\x00.log",
            "logs/evil\n.log",
            "logs/evil\r.log",
            "logs/evil\t.log",
            "logs/evil\x1f.log",
            "logs/trailing /evidence.txt",
            "logs/trailing./evidence.txt",
            "logs/evil\u202e.log",
            "logs/evil\u200b.log",
            "logs/evil\u2066.log",
            "logs/e\u0301.txt",
        )
        for path in unsafe_paths:
            binding = dict(base_binding)
            binding["path"] = path
            failure = self._failure_document(
                ordinal=0,
                candidate=candidate,
                evidence_binding=binding,
            )
            with self.subTest(path=ascii(path)):
                with self.assertRaises(NonAshSelectorArtifactV2Error):
                    verify_attempt_failure_v2(
                        failure,
                        self.profile,
                        self.scope,
                        evidence_binding_reopener=lambda row: payload,
                    )

        aliases = []
        for identifier, path in (
            ("uppercase_path", "Logs/evidence.txt"),
            ("lowercase_path", "logs/evidence.txt"),
        ):
            binding = dict(base_binding)
            binding.update({"id": identifier, "path": path})
            aliases.append(binding)
        aliased_failure = self._failure_document(
            ordinal=0,
            candidate=candidate,
        )
        aliased_failure["evidence_bindings"] = aliases
        aliased_failure = _self_hash(aliased_failure, "failure_sha256")
        with self.assertRaisesRegex(
            NonAshSelectorArtifactV2Error,
            "bindings repeat",
        ):
            verify_attempt_failure_v2(
                aliased_failure,
                self.profile,
                self.scope,
                evidence_binding_reopener=lambda row: payload,
            )


if __name__ == "__main__":
    unittest.main()
