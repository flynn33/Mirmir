"""Pure V2 non-ASH selector search over an authenticated execution profile.

This module has no filesystem, evidence-store, validation-corpus, or holdout
capability.  It emits immutable semantic records that versioned persistence
adapters can validate and publish later.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import math
import re
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple, Union

from validation.calibration_v2.baseline_ablation_budget_v2 import (
    COORDINATE_ORDER_V2,
    EXPECTED_OVERLAY_FILE_SHA256,
    EXPECTED_OVERLAY_SCHEMA_SHA256,
    EXPECTED_OVERLAY_SELF_SHA256,
    INITIAL_VALUE_V2,
    MAXIMUM_DEVELOPMENT_ATTEMPTS_V2,
    MAXIMUM_SWEEPS_V2,
    MAXIMUM_VALIDATION_CANDIDATES_V2,
    SELECTOR_ID_V2,
    VALUES_V2,
    NonAshSelectorAuthorityIdentityV2,
    NonAshSelectorExecutionProfileV2,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


DEVELOPMENT_SPLIT = "development"
VALIDATION_SPLIT = "validation"
DEVELOPMENT_STATUS_IN_PROGRESS = "in_progress"
DEVELOPMENT_STATUS_CONVERGED = "converged"
DEVELOPMENT_STATUS_ABORTED = "aborted"
DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED = "maximum_sweeps_exhausted"
VALIDATION_STATUS_SELECTED = "selected"
VALIDATION_STATUS_FAILED_ALL_CANDIDATES = "failed_all_candidates"
VALIDATION_STATUS_ABORTED_EVIDENCE_INTEGRITY = "aborted_evidence_integrity"
FAILURE_TYPE_CONSTRAINT = "constraint_failure"
FAILURE_TYPE_EVALUATION = "evaluation_failure"
FAILURE_TYPE_EVIDENCE_INTEGRITY = "evidence_integrity_failure"
FAILURE_TYPES = (
    FAILURE_TYPE_CONSTRAINT,
    FAILURE_TYPE_EVALUATION,
    FAILURE_TYPE_EVIDENCE_INTEGRITY,
)

_ATTEMPT_RECORD_DOMAIN = (
    "mirmir-p06-non-ash-selector-v2-semantic-attempt-record-v1"
)
CALIBRATION_PLAN_V2_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
_SHA256 = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")


class NonAshSelectorV2Error(ValueError):
    """The V2 selector profile, rule, result, schedule, or trace is invalid."""


def _is_sha256(value: object) -> bool:
    return type(value) is str and _SHA256.fullmatch(value) is not None


def _require_profile(
    profile: NonAshSelectorExecutionProfileV2,
) -> NonAshSelectorExecutionProfileV2:
    if type(profile) is not NonAshSelectorExecutionProfileV2:
        raise NonAshSelectorV2Error("selector execution profile has the wrong type")
    selector_id = getattr(profile, "selector_id", None)
    coordinate_order = getattr(profile, "coordinate_order", None)
    values = getattr(profile, "values", None)
    initial_value = getattr(profile, "initial_value", None)
    maximum_sweeps = getattr(profile, "maximum_sweeps", None)
    maximum_development_attempts = getattr(
        profile,
        "maximum_development_attempts",
        None,
    )
    maximum_validation_candidates = getattr(
        profile,
        "maximum_validation_candidates",
        None,
    )
    authority_identity = getattr(profile, "authority_identity", None)
    if (
        type(selector_id) is not str
        or selector_id != SELECTOR_ID_V2
        or type(coordinate_order) is not tuple
        or any(type(name) is not str for name in coordinate_order)
        or coordinate_order != COORDINATE_ORDER_V2
        or type(values) is not tuple
        or any(type(value) is not int for value in values)
        or values != VALUES_V2
        or type(initial_value) is not int
        or initial_value != INITIAL_VALUE_V2
        or type(maximum_sweeps) is not int
        or maximum_sweeps != MAXIMUM_SWEEPS_V2
        or type(maximum_development_attempts) is not int
        or maximum_development_attempts != MAXIMUM_DEVELOPMENT_ATTEMPTS_V2
        or type(maximum_validation_candidates) is not int
        or maximum_validation_candidates != MAXIMUM_VALIDATION_CANDIDATES_V2
        or type(authority_identity) is not NonAshSelectorAuthorityIdentityV2
        or type(getattr(authority_identity, "overlay_file_sha256", None)) is not str
        or authority_identity.overlay_file_sha256
        != EXPECTED_OVERLAY_FILE_SHA256
        or type(getattr(authority_identity, "overlay_self_sha256", None)) is not str
        or authority_identity.overlay_self_sha256
        != EXPECTED_OVERLAY_SELF_SHA256
        or type(getattr(authority_identity, "overlay_schema_sha256", None)) is not str
        or authority_identity.overlay_schema_sha256
        != EXPECTED_OVERLAY_SCHEMA_SHA256
    ):
        raise NonAshSelectorV2Error("selector execution profile is not exact")
    return profile


def _snapshot_profile(
    profile: NonAshSelectorExecutionProfileV2,
) -> NonAshSelectorExecutionProfileV2:
    exact = _require_profile(profile)
    authority = NonAshSelectorAuthorityIdentityV2(
        overlay_file_sha256=exact.authority_identity.overlay_file_sha256,
        overlay_self_sha256=exact.authority_identity.overlay_self_sha256,
        overlay_schema_sha256=exact.authority_identity.overlay_schema_sha256,
    )
    return NonAshSelectorExecutionProfileV2(
        selector_id=exact.selector_id,
        coordinate_order=tuple(exact.coordinate_order),
        values=tuple(exact.values),
        initial_value=exact.initial_value,
        maximum_sweeps=exact.maximum_sweeps,
        maximum_development_attempts=exact.maximum_development_attempts,
        maximum_validation_candidates=exact.maximum_validation_candidates,
        authority_identity=authority,
    )


def _require_finite_objective(values: object) -> Tuple[object, ...]:
    if type(values) is not tuple or len(values) != 5:
        raise NonAshSelectorV2Error("selector objective must be an exact 5-tuple")
    for value in values:
        if type(value) is int:
            continue
        if type(value) is not float or not math.isfinite(value):
            raise NonAshSelectorV2Error(
                "selector objective members must be built-in finite numbers"
            )
    return values


def _require_rule_values(
    values: object,
    profile: NonAshSelectorExecutionProfileV2,
) -> Tuple[int, ...]:
    _require_profile(profile)
    if (
        type(values) is not tuple
        or len(values) != len(profile.coordinate_order)
        or any(type(value) is not int or value not in profile.values for value in values)
    ):
        raise NonAshSelectorV2Error(
            "canonical rule values differ from the authenticated domain"
        )
    return values


def canonical_rule_values_v2(
    rule: Mapping[str, object],
    profile: NonAshSelectorExecutionProfileV2,
) -> Tuple[int, ...]:
    """Snapshot and validate a complete rule in authenticated coordinate order."""

    _require_profile(profile)
    if not isinstance(rule, Mapping):
        raise NonAshSelectorV2Error("selector rule is not a mapping")
    try:
        items = tuple(rule.items())
    except Exception as error:
        raise NonAshSelectorV2Error("selector rule could not be snapshotted") from error
    snapshot: Dict[str, object] = {}
    for item in items:
        if type(item) is not tuple or len(item) != 2:
            raise NonAshSelectorV2Error("selector rule item is invalid")
        name, value = item
        if type(name) is not str or name in snapshot:
            raise NonAshSelectorV2Error("selector rule contains an invalid field")
        snapshot[name] = value
    if set(snapshot) != set(profile.coordinate_order) or len(snapshot) != 27:
        raise NonAshSelectorV2Error("selector rule field set differs")
    values = tuple(snapshot[name] for name in profile.coordinate_order)
    return _require_rule_values(values, profile)


def rule_mapping_v2(
    values: Tuple[int, ...],
    profile: NonAshSelectorExecutionProfileV2,
) -> dict[str, int]:
    """Materialize a fresh built-in rule dictionary in declared order."""

    exact = _require_rule_values(values, profile)
    return {
        name: exact[index]
        for index, name in enumerate(profile.coordinate_order)
    }


def rule_sha256_v2(
    values: Tuple[int, ...],
    profile: NonAshSelectorExecutionProfileV2,
) -> str:
    """Hash the same canonical ordered rule object used by the frozen V1 path."""

    return canonical_sha256(rule_mapping_v2(values, profile))


@dataclass(frozen=True)
class NonAshSelectorEvaluationScopeV2:
    """Dynamic same-bank and degradation boundary for one selector search."""

    shared_bank_configuration_sha256: str
    degradation_policy_sha256: str
    calibration_plan_file_sha256: str
    cached_16_operator_output_manifest_sha256: str

    def __post_init__(self) -> None:
        _require_evaluation_scope(self)


def _require_evaluation_scope(
    scope: NonAshSelectorEvaluationScopeV2,
) -> NonAshSelectorEvaluationScopeV2:
    if (
        type(scope) is not NonAshSelectorEvaluationScopeV2
        or not _is_sha256(getattr(scope, "shared_bank_configuration_sha256", None))
        or not _is_sha256(getattr(scope, "degradation_policy_sha256", None))
        or type(getattr(scope, "calibration_plan_file_sha256", None)) is not str
        or scope.calibration_plan_file_sha256
        != CALIBRATION_PLAN_V2_FILE_SHA256
        or not _is_sha256(
            getattr(
                scope,
                "cached_16_operator_output_manifest_sha256",
                None,
            )
        )
    ):
        raise NonAshSelectorV2Error("selector evaluation scope is invalid")
    return scope


def _snapshot_evaluation_scope(
    scope: NonAshSelectorEvaluationScopeV2,
) -> NonAshSelectorEvaluationScopeV2:
    exact = _require_evaluation_scope(scope)
    return NonAshSelectorEvaluationScopeV2(
        shared_bank_configuration_sha256=(
            exact.shared_bank_configuration_sha256
        ),
        degradation_policy_sha256=exact.degradation_policy_sha256,
        calibration_plan_file_sha256=exact.calibration_plan_file_sha256,
        cached_16_operator_output_manifest_sha256=(
            exact.cached_16_operator_output_manifest_sha256
        ),
    )


@dataclass(frozen=True)
class NonAshSelectorEvaluationV2:
    """One authenticated successful aggregate evaluation."""

    split: str
    scope: NonAshSelectorEvaluationScopeV2
    rule_sha256: str
    evaluation_sha256: str
    objective_summary_sha256: str
    output_manifest_sha256: str
    objective_means: Tuple[object, ...]

    def __post_init__(self) -> None:
        _require_outcome(self)


@dataclass(frozen=True)
class NonAshSelectorEvaluationFailureV2:
    """One schema-backed typed evaluator failure binding."""

    split: str
    scope: NonAshSelectorEvaluationScopeV2
    rule_sha256: str
    failure_type: str
    attempt_failure_sha256: str

    def __post_init__(self) -> None:
        _require_outcome(self)


NonAshSelectorOutcomeV2 = Union[
    NonAshSelectorEvaluationV2,
    NonAshSelectorEvaluationFailureV2,
]
SelectorEvaluatorV2 = Callable[[Mapping[str, int]], NonAshSelectorOutcomeV2]
SelectorCacheReopenerV2 = Callable[[str], NonAshSelectorOutcomeV2]


def _require_outcome(
    outcome: NonAshSelectorOutcomeV2,
) -> NonAshSelectorOutcomeV2:
    if type(outcome) is NonAshSelectorEvaluationV2:
        if (
            type(getattr(outcome, "split", None)) is not str
            or outcome.split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
            or not _is_sha256(getattr(outcome, "rule_sha256", None))
            or not _is_sha256(getattr(outcome, "evaluation_sha256", None))
            or not _is_sha256(getattr(outcome, "objective_summary_sha256", None))
            or not _is_sha256(getattr(outcome, "output_manifest_sha256", None))
        ):
            raise NonAshSelectorV2Error("selector evaluation identity is invalid")
        _require_evaluation_scope(getattr(outcome, "scope", None))
        _require_finite_objective(getattr(outcome, "objective_means", None))
        return outcome
    if type(outcome) is NonAshSelectorEvaluationFailureV2:
        if (
            type(getattr(outcome, "split", None)) is not str
            or outcome.split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
            or not _is_sha256(getattr(outcome, "rule_sha256", None))
            or type(getattr(outcome, "failure_type", None)) is not str
            or outcome.failure_type not in FAILURE_TYPES
            or not _is_sha256(getattr(outcome, "attempt_failure_sha256", None))
        ):
            raise NonAshSelectorV2Error("selector failure identity is invalid")
        _require_evaluation_scope(getattr(outcome, "scope", None))
        return outcome
    raise NonAshSelectorV2Error("selector attempt outcome has the wrong type")


def _snapshot_outcome(
    outcome: NonAshSelectorOutcomeV2,
) -> NonAshSelectorOutcomeV2:
    exact = _require_outcome(outcome)
    scope = _snapshot_evaluation_scope(exact.scope)
    if type(exact) is NonAshSelectorEvaluationV2:
        return NonAshSelectorEvaluationV2(
            split=exact.split,
            scope=scope,
            rule_sha256=exact.rule_sha256,
            evaluation_sha256=exact.evaluation_sha256,
            objective_summary_sha256=exact.objective_summary_sha256,
            output_manifest_sha256=exact.output_manifest_sha256,
            objective_means=tuple(exact.objective_means),
        )
    return NonAshSelectorEvaluationFailureV2(
        split=exact.split,
        scope=scope,
        rule_sha256=exact.rule_sha256,
        failure_type=exact.failure_type,
        attempt_failure_sha256=exact.attempt_failure_sha256,
    )


@dataclass(frozen=True)
class NonAshSelectorAttemptRecordV2:
    """One chained semantic development attempt, including cache hits."""

    attempt_ordinal: int
    previous_record_sha256: Optional[str]
    record_sha256: str
    split: str
    phase: str
    sweep: int
    coordinate_ordinal: Optional[int]
    coordinate_name: Optional[str]
    coordinate_value: Optional[int]
    rule_sha256: str
    canonical_rule_values: Tuple[int, ...]
    cache_hit: bool
    outcome: NonAshSelectorOutcomeV2


def _outcome_payload(outcome: NonAshSelectorOutcomeV2) -> Mapping[str, object]:
    _require_outcome(outcome)
    scope = {
        "shared_bank_configuration_sha256": (
            outcome.scope.shared_bank_configuration_sha256
        ),
        "degradation_policy_sha256": outcome.scope.degradation_policy_sha256,
        "calibration_plan_file_sha256": (
            outcome.scope.calibration_plan_file_sha256
        ),
        "cached_16_operator_output_manifest_sha256": (
            outcome.scope.cached_16_operator_output_manifest_sha256
        ),
    }
    if type(outcome) is NonAshSelectorEvaluationV2:
        return {
            "kind": "evaluation",
            "split": outcome.split,
            "scope": scope,
            "rule_sha256": outcome.rule_sha256,
            "evaluation_sha256": outcome.evaluation_sha256,
            "objective_summary_sha256": outcome.objective_summary_sha256,
            "output_manifest_sha256": outcome.output_manifest_sha256,
            "objective_means": list(outcome.objective_means),
        }
    if type(outcome) is NonAshSelectorEvaluationFailureV2:
        return {
            "kind": "attempt_failure",
            "split": outcome.split,
            "scope": scope,
            "rule_sha256": outcome.rule_sha256,
            "failure_type": outcome.failure_type,
            "attempt_failure_sha256": outcome.attempt_failure_sha256,
        }
    raise AssertionError("unreachable selector outcome type")


def _outcomes_identical(
    left: NonAshSelectorOutcomeV2,
    right: NonAshSelectorOutcomeV2,
) -> bool:
    _require_outcome(left)
    _require_outcome(right)
    return canonical_json_bytes(_outcome_payload(left)) == canonical_json_bytes(
        _outcome_payload(right)
    )


def development_attempt_record_sha256_v2(
    record: NonAshSelectorAttemptRecordV2,
) -> str:
    """Hash one record without its self-hash field."""

    snapshot = _snapshot_attempt_record(record)
    return _development_attempt_record_sha256_from_snapshot(snapshot)


_ATTEMPT_RECORD_FIELDS = (
    "attempt_ordinal",
    "previous_record_sha256",
    "record_sha256",
    "split",
    "phase",
    "sweep",
    "coordinate_ordinal",
    "coordinate_name",
    "coordinate_value",
    "rule_sha256",
    "canonical_rule_values",
    "cache_hit",
    "outcome",
)
_MISSING = object()


def _snapshot_attempt_record(
    record: NonAshSelectorAttemptRecordV2,
) -> Dict[str, object]:
    if type(record) is not NonAshSelectorAttemptRecordV2:
        raise NonAshSelectorV2Error("selector attempt record has the wrong type")
    snapshot = {
        name: getattr(record, name, _MISSING)
        for name in _ATTEMPT_RECORD_FIELDS
    }
    if any(value is _MISSING for value in snapshot.values()):
        raise NonAshSelectorV2Error("selector attempt record is incomplete")
    previous = snapshot["previous_record_sha256"]
    coordinate_ordinal = snapshot["coordinate_ordinal"]
    coordinate_name = snapshot["coordinate_name"]
    coordinate_value = snapshot["coordinate_value"]
    canonical_values = snapshot["canonical_rule_values"]
    if (
        type(snapshot["attempt_ordinal"]) is not int
        or (previous is not None and not _is_sha256(previous))
        or type(snapshot["record_sha256"]) is not str
        or type(snapshot["split"]) is not str
        or type(snapshot["phase"]) is not str
        or type(snapshot["sweep"]) is not int
        or (
            coordinate_ordinal is not None
            and type(coordinate_ordinal) is not int
        )
        or (coordinate_name is not None and type(coordinate_name) is not str)
        or (
            coordinate_value is not None
            and (
                type(coordinate_value) is not int
                or coordinate_value not in VALUES_V2
            )
        )
        or not _is_sha256(snapshot["rule_sha256"])
        or type(canonical_values) is not tuple
        or len(canonical_values) != len(COORDINATE_ORDER_V2)
        or any(
            type(value) is not int or value not in VALUES_V2
            for value in canonical_values
        )
        or type(snapshot["cache_hit"]) is not bool
    ):
        raise NonAshSelectorV2Error("selector attempt record fields are invalid")
    outcome = _snapshot_outcome(snapshot["outcome"])
    snapshot["outcome"] = outcome
    snapshot["outcome_payload"] = _outcome_payload(outcome)
    return snapshot


def _development_attempt_record_sha256_from_snapshot(
    snapshot: Mapping[str, object],
) -> str:
    return canonical_sha256(
        {
            "domain": _ATTEMPT_RECORD_DOMAIN,
            "attempt_ordinal": snapshot["attempt_ordinal"],
            "previous_record_sha256": snapshot["previous_record_sha256"],
            "split": snapshot["split"],
            "phase": snapshot["phase"],
            "sweep": snapshot["sweep"],
            "coordinate_ordinal": snapshot["coordinate_ordinal"],
            "coordinate_name": snapshot["coordinate_name"],
            "coordinate_value": snapshot["coordinate_value"],
            "rule_sha256": snapshot["rule_sha256"],
            "canonical_rule_values": list(snapshot["canonical_rule_values"]),
            "cache_hit": snapshot["cache_hit"],
            "outcome": snapshot["outcome_payload"],
        }
    )


@dataclass(frozen=True)
class NonAshSelectorDevelopmentResultV2:
    """Terminal result of one isolated development-only selector search."""

    status: str
    completed_sweeps: int
    attempt_records: Tuple[NonAshSelectorAttemptRecordV2, ...]
    unique_evaluation_count: int
    incumbent_rule_values: Optional[Tuple[int, ...]]
    incumbent_evaluation: Optional[NonAshSelectorEvaluationV2]
    terminal_rule_values: Optional[Tuple[int, ...]]
    terminal_rule_sha256: Optional[str]

    @property
    def attempt_count(self) -> int:
        return len(self.attempt_records)

    @property
    def last_record_sha256(self) -> Optional[str]:
        if not self.attempt_records:
            return None
        return self.attempt_records[-1].record_sha256


@dataclass(frozen=True)
class NonAshValidationAdmissionV2:
    """Development-frozen semantic boundary required before validation access."""

    authority_identity: NonAshSelectorAuthorityIdentityV2
    evaluation_scope: NonAshSelectorEvaluationScopeV2
    development_attempt_count: int
    development_last_record_sha256: str
    terminal_rule_values: Tuple[int, ...]
    terminal_rule_sha256: str
    development_evaluation_sha256s: Tuple[str, ...]
    reopened_unique_evaluation_count: int


def _freeze_validation_admission(
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    records: Sequence[NonAshSelectorAttemptRecordV2],
    development_evidence_reopener: SelectorCacheReopenerV2,
) -> NonAshValidationAdmissionV2:
    if not callable(development_evidence_reopener):
        raise NonAshSelectorV2Error(
            "development evidence reopener is not callable"
        )
    development = replay_non_ash_development_search_v2(
        profile,
        evaluation_scope,
        records,
    )
    if (
        development.status != DEVELOPMENT_STATUS_CONVERGED
        or development.attempt_count < 1
        or development.last_record_sha256 is None
        or development.terminal_rule_values is None
        or development.terminal_rule_sha256 is None
    ):
        raise NonAshSelectorV2Error(
            "validation admission requires a converged development trace"
        )
    expected_by_evaluation: Dict[str, NonAshSelectorEvaluationV2] = {}
    latest_by_rule: Dict[str, NonAshSelectorEvaluationV2] = {}
    for record in records:
        snapshot = _snapshot_attempt_record(record)
        outcome = _require_outcome(snapshot["outcome"])
        if type(outcome) is not NonAshSelectorEvaluationV2:
            raise NonAshSelectorV2Error(
                "converged development trace contains a failed outcome"
            )
        existing = expected_by_evaluation.get(outcome.evaluation_sha256)
        if existing is not None and not _outcomes_identical(existing, outcome):
            raise NonAshSelectorV2Error(
                "development content address identifies different evidence"
            )
        expected_by_evaluation[outcome.evaluation_sha256] = outcome
        latest_by_rule[outcome.rule_sha256] = outcome
    for evaluation_sha256, expected in expected_by_evaluation.items():
        try:
            reopened = development_evidence_reopener(evaluation_sha256)
        except Exception as error:
            raise NonAshSelectorV2Error(
                "development evidence could not be reopened for validation admission"
            ) from error
        if (
            type(reopened) is not NonAshSelectorEvaluationV2
            or not _outcomes_identical(reopened, expected)
        ):
            raise NonAshSelectorV2Error(
                "development evidence reopening differs from the frozen trace"
            )
    neighborhood = non_ash_validation_neighborhood_v2(
        profile,
        rule_mapping_v2(development.terminal_rule_values, profile),
    )
    neighborhood_evaluation_sha256s = []
    for candidate in neighborhood:
        evidence = latest_by_rule.get(candidate.rule_sha256)
        if evidence is None:
            raise NonAshSelectorV2Error(
                "development trace does not cover the validation neighborhood"
            )
        neighborhood_evaluation_sha256s.append(evidence.evaluation_sha256)
    return NonAshValidationAdmissionV2(
        authority_identity=profile.authority_identity,
        evaluation_scope=evaluation_scope,
        development_attempt_count=development.attempt_count,
        development_last_record_sha256=development.last_record_sha256,
        terminal_rule_values=development.terminal_rule_values,
        terminal_rule_sha256=development.terminal_rule_sha256,
        development_evaluation_sha256s=tuple(
            neighborhood_evaluation_sha256s
        ),
        reopened_unique_evaluation_count=len(expected_by_evaluation),
    )


def _selection_key(
    values: Tuple[int, ...],
    evaluation: NonAshSelectorEvaluationV2,
    profile: NonAshSelectorExecutionProfileV2,
) -> Tuple[object, ...]:
    _require_profile(profile)
    _require_outcome(evaluation)
    return tuple(-value for value in evaluation.objective_means) + (
        canonical_json_bytes(rule_mapping_v2(values, profile)),
    )


class _DevelopmentState:
    def __init__(
        self,
        profile: NonAshSelectorExecutionProfileV2,
        evaluation_scope: NonAshSelectorEvaluationScopeV2,
    ) -> None:
        self.profile = _snapshot_profile(profile)
        self.evaluation_scope = _snapshot_evaluation_scope(evaluation_scope)
        self.current = tuple(
            profile.initial_value for _ in profile.coordinate_order
        )
        self.current_evaluation: Optional[NonAshSelectorEvaluationV2] = None
        self.status = DEVELOPMENT_STATUS_IN_PROGRESS
        self.phase = "initial"
        self.sweep = 0
        self.coordinate_ordinal = 0
        self.value_ordinal = 0
        self.changed = False
        self.completed_sweeps = 0
        self.batch: list[
            tuple[Tuple[int, ...], NonAshSelectorEvaluationV2]
        ] = []
        self.records: list[NonAshSelectorAttemptRecordV2] = []
        self.record_hashes: list[str] = []
        self.cache: Dict[str, NonAshSelectorEvaluationV2] = {}

    def expected_attempt(
        self,
    ) -> Tuple[
        str,
        int,
        Optional[int],
        Optional[str],
        Optional[int],
        Tuple[int, ...],
    ]:
        if self.status != DEVELOPMENT_STATUS_IN_PROGRESS:
            raise NonAshSelectorV2Error("selector trace continues after terminal state")
        if self.phase == "initial":
            return "initial", 0, None, None, None, self.current
        coordinate_name = self.profile.coordinate_order[self.coordinate_ordinal]
        coordinate_value = self.profile.values[self.value_ordinal]
        candidate = list(self.current)
        candidate[self.coordinate_ordinal] = coordinate_value
        return (
            "coordinate_scan",
            self.sweep,
            self.coordinate_ordinal,
            coordinate_name,
            coordinate_value,
            tuple(candidate),
        )

    def _validate_record(
        self,
        record: NonAshSelectorAttemptRecordV2,
    ) -> Tuple[
        Tuple[int, ...],
        NonAshSelectorOutcomeV2,
        bool,
        str,
        str,
    ]:
        snapshot = _snapshot_attempt_record(record)
        phase, sweep, coordinate_ordinal, coordinate_name, coordinate_value, values = (
            self.expected_attempt()
        )
        expected_previous = (
            None if not self.record_hashes else self.record_hashes[-1]
        )
        expected_rule_sha256 = rule_sha256_v2(values, self.profile)
        record_values = _require_rule_values(
            snapshot["canonical_rule_values"],
            self.profile,
        )
        outcome = _require_outcome(snapshot["outcome"])
        previous = snapshot["previous_record_sha256"]
        previous_matches = (
            previous is None
            if expected_previous is None
            else _is_sha256(previous) and previous == expected_previous
        )
        actual_coordinate_ordinal = snapshot["coordinate_ordinal"]
        coordinate_ordinal_matches = (
            actual_coordinate_ordinal is None
            if coordinate_ordinal is None
            else type(actual_coordinate_ordinal) is int
            and actual_coordinate_ordinal == coordinate_ordinal
        )
        actual_coordinate_name = snapshot["coordinate_name"]
        coordinate_name_matches = (
            actual_coordinate_name is None
            if coordinate_name is None
            else type(actual_coordinate_name) is str
            and actual_coordinate_name == coordinate_name
        )
        actual_coordinate_value = snapshot["coordinate_value"]
        coordinate_value_matches = (
            actual_coordinate_value is None
            if coordinate_value is None
            else type(actual_coordinate_value) is int
            and actual_coordinate_value == coordinate_value
        )
        if (
            snapshot["attempt_ordinal"] != len(self.records)
            or not previous_matches
            or not _is_sha256(snapshot["record_sha256"])
            or snapshot["record_sha256"]
            != _development_attempt_record_sha256_from_snapshot(snapshot)
            or snapshot["split"] != DEVELOPMENT_SPLIT
            or snapshot["phase"] != phase
            or snapshot["sweep"] != sweep
            or not coordinate_ordinal_matches
            or not coordinate_name_matches
            or not coordinate_value_matches
            or record_values != values
            or snapshot["rule_sha256"] != expected_rule_sha256
            or outcome.split != DEVELOPMENT_SPLIT
            or outcome.scope != self.evaluation_scope
            or outcome.rule_sha256 != expected_rule_sha256
        ):
            raise NonAshSelectorV2Error("selector attempt differs from the schedule")
        cached = self.cache.get(expected_rule_sha256)
        cache_hit = snapshot["cache_hit"]
        if cache_hit:
            if (
                type(outcome) is not NonAshSelectorEvaluationV2
                or cached is None
                or not _outcomes_identical(outcome, cached)
            ):
                raise NonAshSelectorV2Error("selector cache-hit semantics differ")
        elif (
            cached is not None
            and (
                type(outcome) is not NonAshSelectorEvaluationFailureV2
                or outcome.failure_type != FAILURE_TYPE_EVIDENCE_INTEGRITY
            )
        ):
            raise NonAshSelectorV2Error("selector cache miss duplicates cached evidence")
        return (
            values,
            outcome,
            cache_hit,
            expected_rule_sha256,
            snapshot["record_sha256"],
        )

    def apply(self, record: NonAshSelectorAttemptRecordV2) -> None:
        values, outcome, cache_hit, rule_sha256, record_sha256 = self._validate_record(
            record
        )
        if not cache_hit and type(outcome) is NonAshSelectorEvaluationV2:
            self.cache[rule_sha256] = outcome
        self.records.append(record)
        self.record_hashes.append(record_sha256)
        if len(self.records) > self.profile.maximum_development_attempts:
            raise NonAshSelectorV2Error("selector development budget was exceeded")

        if type(outcome) is NonAshSelectorEvaluationFailureV2:
            self.status = DEVELOPMENT_STATUS_ABORTED
            return
        if self.phase == "initial":
            self.current_evaluation = outcome
            self.phase = "coordinate_scan"
            self.sweep = 1
            return

        self.batch.append((values, outcome))
        self.value_ordinal += 1
        if self.value_ordinal < len(self.profile.values):
            return

        selected_values, selected_evaluation = min(
            self.batch,
            key=lambda item: _selection_key(item[0], item[1], self.profile),
        )
        if selected_values != self.current:
            self.changed = True
        self.current = selected_values
        self.current_evaluation = selected_evaluation
        self.batch = []
        self.value_ordinal = 0
        self.coordinate_ordinal += 1
        if self.coordinate_ordinal < len(self.profile.coordinate_order):
            return

        self.completed_sweeps = self.sweep
        if not self.changed:
            self.status = DEVELOPMENT_STATUS_CONVERGED
            return
        if self.sweep == self.profile.maximum_sweeps:
            self.status = DEVELOPMENT_STATUS_MAXIMUM_SWEEPS_EXHAUSTED
            return
        self.sweep += 1
        self.coordinate_ordinal = 0
        self.changed = False

    def result(self) -> NonAshSelectorDevelopmentResultV2:
        incumbent = self.current if self.current_evaluation is not None else None
        terminal_values = (
            self.current if self.status == DEVELOPMENT_STATUS_CONVERGED else None
        )
        terminal_sha256 = (
            rule_sha256_v2(self.current, self.profile)
            if terminal_values is not None
            else None
        )
        return NonAshSelectorDevelopmentResultV2(
            status=self.status,
            completed_sweeps=self.completed_sweeps,
            attempt_records=tuple(self.records),
            unique_evaluation_count=len(self.cache),
            incumbent_rule_values=incumbent,
            incumbent_evaluation=self.current_evaluation,
            terminal_rule_values=terminal_values,
            terminal_rule_sha256=terminal_sha256,
        )


def _new_attempt_record(
    state: _DevelopmentState,
    *,
    phase: str,
    sweep: int,
    coordinate_ordinal: Optional[int],
    coordinate_name: Optional[str],
    coordinate_value: Optional[int],
    values: Tuple[int, ...],
    cache_hit: bool,
    outcome: NonAshSelectorOutcomeV2,
) -> NonAshSelectorAttemptRecordV2:
    record = NonAshSelectorAttemptRecordV2(
        attempt_ordinal=len(state.records),
        previous_record_sha256=(
            None if not state.record_hashes else state.record_hashes[-1]
        ),
        record_sha256="0" * 64,
        split=DEVELOPMENT_SPLIT,
        phase=phase,
        sweep=sweep,
        coordinate_ordinal=coordinate_ordinal,
        coordinate_name=coordinate_name,
        coordinate_value=coordinate_value,
        rule_sha256=rule_sha256_v2(values, state.profile),
        canonical_rule_values=values,
        cache_hit=cache_hit,
        outcome=outcome,
    )
    return replace(
        record,
        record_sha256=development_attempt_record_sha256_v2(record),
    )


def run_non_ash_development_search_v2(
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    development_evaluator: SelectorEvaluatorV2,
    development_cache_reopener: SelectorCacheReopenerV2,
) -> NonAshSelectorDevelopmentResultV2:
    """Run only the development search; no validation capability is accepted."""

    state = _DevelopmentState(profile, evaluation_scope)
    if not callable(development_evaluator):
        raise NonAshSelectorV2Error("development evaluator is not callable")
    if not callable(development_cache_reopener):
        raise NonAshSelectorV2Error("development cache reopener is not callable")
    while state.status == DEVELOPMENT_STATUS_IN_PROGRESS:
        phase, sweep, coordinate_ordinal, coordinate_name, coordinate_value, values = (
            state.expected_attempt()
        )
        rule_sha256 = rule_sha256_v2(values, state.profile)
        cached = state.cache.get(rule_sha256)
        if cached is not None:
            try:
                outcome = _snapshot_outcome(
                    development_cache_reopener(cached.evaluation_sha256)
                )
            except Exception as error:
                raise NonAshSelectorV2Error(
                    "development cache exception was not converted to a typed failure"
                ) from error
            _require_outcome(outcome)
            if (
                outcome.split != DEVELOPMENT_SPLIT
                or outcome.scope != state.evaluation_scope
                or outcome.rule_sha256 != rule_sha256
            ):
                raise NonAshSelectorV2Error(
                    "development cache reopener returned mixed or stale evidence"
                )
            if type(outcome) is NonAshSelectorEvaluationV2:
                if not _outcomes_identical(outcome, cached):
                    raise NonAshSelectorV2Error(
                        "development cache reopened different evidence"
                    )
                cache_hit = True
            else:
                if outcome.failure_type != FAILURE_TYPE_EVIDENCE_INTEGRITY:
                    raise NonAshSelectorV2Error(
                        "development cache reopen failure is not an evidence-integrity failure"
                    )
                cache_hit = False
        else:
            try:
                outcome = _snapshot_outcome(
                    development_evaluator(
                        rule_mapping_v2(values, state.profile)
                    )
                )
            except Exception as error:
                raise NonAshSelectorV2Error(
                    "development evaluator exception was not converted to a typed failure"
                ) from error
            cache_hit = False
            _require_outcome(outcome)
            if (
                outcome.split != DEVELOPMENT_SPLIT
                or outcome.scope != state.evaluation_scope
                or outcome.rule_sha256 != rule_sha256
            ):
                raise NonAshSelectorV2Error(
                    "development evaluator returned mixed or stale evidence"
                )
        state.apply(
            _new_attempt_record(
                state,
                phase=phase,
                sweep=sweep,
                coordinate_ordinal=coordinate_ordinal,
                coordinate_name=coordinate_name,
                coordinate_value=coordinate_value,
                values=values,
                cache_hit=cache_hit,
                outcome=outcome,
            )
        )
    return state.result()


def replay_non_ash_development_search_v2(
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    records: Sequence[NonAshSelectorAttemptRecordV2],
) -> NonAshSelectorDevelopmentResultV2:
    """Reopen and semantically replay a complete terminal development trace."""

    state = _DevelopmentState(profile, evaluation_scope)
    if type(records) not in {tuple, list}:
        raise NonAshSelectorV2Error("selector trace must be a built-in sequence")
    for record in records:
        state.apply(record)
    if state.status == DEVELOPMENT_STATUS_IN_PROGRESS:
        raise NonAshSelectorV2Error("selector trace ends before a terminal state")
    return state.result()


@dataclass(frozen=True)
class NonAshValidationCandidateV2:
    """One deterministic member of the terminal one-coordinate neighborhood."""

    candidate_ordinal: int
    terminal: bool
    coordinate_ordinal: Optional[int]
    coordinate_name: Optional[str]
    from_value: Optional[int]
    to_value: Optional[int]
    rule_sha256: str
    canonical_rule_values: Tuple[int, ...]


def non_ash_validation_neighborhood_v2(
    profile: NonAshSelectorExecutionProfileV2,
    terminal_rule: Mapping[str, object],
) -> Tuple[NonAshValidationCandidateV2, ...]:
    """Freeze terminal first, then coordinate order and ascending noncurrent value."""

    exact_profile = _require_profile(profile)
    terminal_values = canonical_rule_values_v2(terminal_rule, exact_profile)
    candidates = [
        NonAshValidationCandidateV2(
            candidate_ordinal=0,
            terminal=True,
            coordinate_ordinal=None,
            coordinate_name=None,
            from_value=None,
            to_value=None,
            rule_sha256=rule_sha256_v2(terminal_values, exact_profile),
            canonical_rule_values=terminal_values,
        )
    ]
    for coordinate_ordinal, coordinate_name in enumerate(
        exact_profile.coordinate_order
    ):
        from_value = terminal_values[coordinate_ordinal]
        for value in exact_profile.values:
            if value == from_value:
                continue
            candidate_values = list(terminal_values)
            candidate_values[coordinate_ordinal] = value
            exact_values = tuple(candidate_values)
            candidates.append(
                NonAshValidationCandidateV2(
                    candidate_ordinal=len(candidates),
                    terminal=False,
                    coordinate_ordinal=coordinate_ordinal,
                    coordinate_name=coordinate_name,
                    from_value=from_value,
                    to_value=value,
                    rule_sha256=rule_sha256_v2(exact_values, exact_profile),
                    canonical_rule_values=exact_values,
                )
            )
    if (
        len(candidates) != exact_profile.maximum_validation_candidates
        or len({candidate.rule_sha256 for candidate in candidates})
        != len(candidates)
    ):
        raise NonAshSelectorV2Error(
            "selector validation neighborhood is incomplete or duplicated"
        )
    return tuple(candidates)


@dataclass(frozen=True)
class NonAshSelectorValidationResultV2:
    """Complete validation outcomes and deterministic selected comparator rule."""

    status: str
    development_admission: NonAshValidationAdmissionV2
    candidates: Tuple[NonAshValidationCandidateV2, ...]
    outcomes: Tuple[NonAshSelectorOutcomeV2, ...]
    selected_candidate: Optional[NonAshValidationCandidateV2]
    selected_evaluation: Optional[NonAshSelectorEvaluationV2]


def run_non_ash_validation_selection_v2(
    profile: NonAshSelectorExecutionProfileV2,
    evaluation_scope: NonAshSelectorEvaluationScopeV2,
    development_records: Sequence[NonAshSelectorAttemptRecordV2],
    development_evidence_reopener: SelectorCacheReopenerV2,
    validation_evaluator: SelectorEvaluatorV2,
) -> NonAshSelectorValidationResultV2:
    """Replay development, freeze admission, then evaluate its 163-rule neighborhood."""

    exact_profile = _snapshot_profile(profile)
    exact_scope = _snapshot_evaluation_scope(evaluation_scope)
    if not callable(validation_evaluator):
        raise NonAshSelectorV2Error("validation evaluator is not callable")
    admission = _freeze_validation_admission(
        exact_profile,
        exact_scope,
        development_records,
        development_evidence_reopener,
    )
    candidates = non_ash_validation_neighborhood_v2(
        exact_profile,
        rule_mapping_v2(admission.terminal_rule_values, exact_profile),
    )
    outcomes: list[NonAshSelectorOutcomeV2] = []
    successful: list[
        tuple[NonAshValidationCandidateV2, NonAshSelectorEvaluationV2]
    ] = []
    for candidate in candidates:
        try:
            outcome = _snapshot_outcome(
                validation_evaluator(
                    rule_mapping_v2(candidate.canonical_rule_values, exact_profile)
                )
            )
        except Exception as error:
            raise NonAshSelectorV2Error(
                "validation evaluator exception was not converted to a typed failure"
            ) from error
        _require_outcome(outcome)
        if (
            outcome.split != VALIDATION_SPLIT
            or outcome.scope != exact_scope
            or outcome.rule_sha256 != candidate.rule_sha256
        ):
            raise NonAshSelectorV2Error(
                "validation evaluator returned mixed or stale evidence"
            )
        outcomes.append(outcome)
        if (
            type(outcome) is NonAshSelectorEvaluationFailureV2
            and outcome.failure_type == FAILURE_TYPE_EVIDENCE_INTEGRITY
        ):
            return NonAshSelectorValidationResultV2(
                status=VALIDATION_STATUS_ABORTED_EVIDENCE_INTEGRITY,
                development_admission=admission,
                candidates=candidates,
                outcomes=tuple(outcomes),
                selected_candidate=None,
                selected_evaluation=None,
            )
        if type(outcome) is NonAshSelectorEvaluationV2:
            successful.append((candidate, outcome))
    if not successful:
        return NonAshSelectorValidationResultV2(
            status=VALIDATION_STATUS_FAILED_ALL_CANDIDATES,
            development_admission=admission,
            candidates=candidates,
            outcomes=tuple(outcomes),
            selected_candidate=None,
            selected_evaluation=None,
        )
    selected_candidate, selected_evaluation = min(
        successful,
        key=lambda item: _selection_key(
            item[0].canonical_rule_values,
            item[1],
            exact_profile,
        ),
    )
    return NonAshSelectorValidationResultV2(
        status=VALIDATION_STATUS_SELECTED,
        development_admission=admission,
        candidates=candidates,
        outcomes=tuple(outcomes),
        selected_candidate=selected_candidate,
        selected_evaluation=selected_evaluation,
    )
