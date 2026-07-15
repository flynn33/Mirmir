"""Pure development-search scheduler for the authenticated calibration plan V2.

This module deliberately emits only immutable in-memory semantic records.  The
persisted V2 ledger schema, terminal siblings, and shared-bank hash framing are
separate preregistration work and are not invented here.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import math
import re
from typing import Callable, Dict, Mapping, Sequence, Tuple

from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    ParsedCalibrationPlanV2,
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    serialized_candidate_vector_v2,
    validate_candidate_constraints_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


DEVELOPMENT_SPLIT = "development"
VALIDATION_SPLIT = "validation"
STRUCTURAL_ATTEMPTS_PER_SWEEP = 256
SCALAR_ATTEMPTS_PER_SWEEP = 155
ATTEMPTS_PER_COMPLETE_SWEEP = 411
MAXIMUM_SWEEPS = 8
MAXIMUM_DEVELOPMENT_ATTEMPTS = 3288

STATUS_IN_PROGRESS = "in_progress"
STATUS_TERMINATED_FEASIBLE = "terminated_feasible"
STATUS_FAILED_NO_ELIGIBLE_STRUCTURAL = "failed_no_eligible_structural_candidate"
STATUS_FAILED_INFEASIBLE_FIXED_POINT = "failed_infeasible_fixed_point"
STATUS_FAILED_MAXIMUM_SWEEPS = "failed_maximum_sweeps"

ATTEMPT_STATUS_CONSTRAINT_FAILURE = "constraint_failure"
ATTEMPT_STATUS_EVALUATION_FAILURE = "evaluation_failure"
ATTEMPT_STATUS_FEASIBLE = "feasible"
ATTEMPT_STATUS_INFEASIBLE = "infeasible"

_ATTEMPT_RECORD_DOMAIN = "mirmir-p06-calibration-scheduler-v2-semantic-attempt-v1"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ZERO_SHA256 = "0" * 64
_GLOBAL_DEVELOPMENT_CHECK_FAILURES = frozenset(
    {
        "compiler_invariants",
        "operator_distinctness",
        "state_causality",
        "analysis_grid_route_quality",
        "analysis_grid_occupancy",
        "candidate_count",
    }
)


class CalibrationSchedulerV2Error(ValueError):
    """The V2 schedule, evaluator result, trace, or checkpoint is invalid."""


def _is_sha256(value: object) -> bool:
    return type(value) is str and _SHA256.fullmatch(value) is not None


def _require_finite_number(value: object, *, label: str) -> None:
    if type(value) not in {int, float} or not math.isfinite(float(value)):
        raise CalibrationSchedulerV2Error(f"{label} must be a finite built-in number")


@dataclass(frozen=True)
class EvaluationCacheIdentityV2:
    """Typed cache identity; no persistent composite-key framing is implied."""

    split: str
    candidate_vector_sha256: str
    calibration_plan_file_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.split) is not str
            or self.split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
        ):
            raise CalibrationSchedulerV2Error("cache identity split is invalid")
        if not _is_sha256(self.candidate_vector_sha256):
            raise CalibrationSchedulerV2Error("cache candidate SHA-256 is invalid")
        if not _is_sha256(self.calibration_plan_file_sha256):
            raise CalibrationSchedulerV2Error("cache plan SHA-256 is invalid")


@dataclass(frozen=True)
class DevelopmentEvaluationV2:
    """The inherited development-ranking fields for one successful evaluation."""

    feasible: bool
    failure_reasons: Tuple[str, ...]
    mean_y_psnr_delta_vs_fixed_db: object
    mean_y_psnr_delta_vs_non_ash_db: object
    mean_ms_ssim_delta_vs_conventional: object
    maximum_ringing_excursion: object
    maximum_alias_ratio: object
    estimated_dispatch_cost: object

    def __post_init__(self) -> None:
        _validate_development_evaluation(self)


def _validate_development_evaluation(
    evaluation: DevelopmentEvaluationV2,
) -> None:
    if type(evaluation) is not DevelopmentEvaluationV2:
        raise CalibrationSchedulerV2Error("development evaluation has the wrong type")
    if type(evaluation.feasible) is not bool:
        raise CalibrationSchedulerV2Error("evaluation feasibility must be bool")
    if type(evaluation.failure_reasons) is not tuple or any(
        type(reason) is not str or not reason for reason in evaluation.failure_reasons
    ):
        raise CalibrationSchedulerV2Error(
            "evaluation failure-reason members must be nonempty built-in strings"
        )
    if len(set(evaluation.failure_reasons)) != len(evaluation.failure_reasons):
        raise CalibrationSchedulerV2Error("evaluation failure reasons repeat")
    if evaluation.feasible != (len(evaluation.failure_reasons) == 0):
        raise CalibrationSchedulerV2Error(
            "evaluation feasibility and failure reasons disagree"
        )
    for name in (
        "mean_y_psnr_delta_vs_fixed_db",
        "mean_y_psnr_delta_vs_non_ash_db",
        "mean_ms_ssim_delta_vs_conventional",
        "maximum_ringing_excursion",
        "maximum_alias_ratio",
        "estimated_dispatch_cost",
    ):
        _require_finite_number(getattr(evaluation, name), label=name)


@dataclass(frozen=True)
class AttemptRecordV2:
    """One immutable semantic attempt record for deterministic replay tests."""

    sequence: int
    previous_record_sha256: str
    record_sha256: str
    split: str
    phase: str
    sweep: int
    coordinate: str
    value: object
    physical_candidate_items: Tuple[Tuple[str, object], ...]
    candidate_vector_sha256: str
    cache_identity: EvaluationCacheIdentityV2
    status: str
    cache_hit: bool
    failure_reasons: Tuple[str, ...]
    canonical_failure_reasons: Tuple[str, ...]
    evaluation: DevelopmentEvaluationV2 | None


def _validate_cache_identity(identity: EvaluationCacheIdentityV2) -> None:
    if type(identity) is not EvaluationCacheIdentityV2:
        raise CalibrationSchedulerV2Error("cache identity has the wrong type")
    if (
        type(identity.split) is not str
        or identity.split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
        or not _is_sha256(identity.candidate_vector_sha256)
        or not _is_sha256(identity.calibration_plan_file_sha256)
    ):
        raise CalibrationSchedulerV2Error("cache identity fields are invalid")


def _validate_attempt_record_shape(record: AttemptRecordV2) -> None:
    if type(record) is not AttemptRecordV2:
        raise CalibrationSchedulerV2Error("attempt record has the wrong type")
    if (
        type(record.sequence) is not int
        or record.sequence < 0
        or not _is_sha256(record.previous_record_sha256)
        or not _is_sha256(record.record_sha256)
        or type(record.split) is not str
        or type(record.phase) is not str
        or record.phase not in {"structural_scan", "scalar_scan"}
        or type(record.sweep) is not int
        or record.sweep < 1
        or type(record.coordinate) is not str
        or not record.coordinate
        or type(record.physical_candidate_items) is not tuple
        or not _is_sha256(record.candidate_vector_sha256)
        or type(record.status) is not str
        or record.status
        not in {
            ATTEMPT_STATUS_CONSTRAINT_FAILURE,
            ATTEMPT_STATUS_EVALUATION_FAILURE,
            ATTEMPT_STATUS_FEASIBLE,
            ATTEMPT_STATUS_INFEASIBLE,
        }
        or type(record.cache_hit) is not bool
        or type(record.failure_reasons) is not tuple
        or any(
            type(reason) is not str or not reason
            for reason in record.failure_reasons
        )
        or type(record.canonical_failure_reasons) is not tuple
        or any(
            type(reason) is not str or not reason
            for reason in record.canonical_failure_reasons
        )
    ):
        raise CalibrationSchedulerV2Error("attempt record fields are invalid")
    for item in record.physical_candidate_items:
        if (
            type(item) is not tuple
            or len(item) != 2
            or type(item[0]) is not str
            or type(item[1]) not in {int, str}
        ):
            raise CalibrationSchedulerV2Error(
                "attempt physical candidate items are invalid"
            )
    _validate_cache_identity(record.cache_identity)
    if record.evaluation is not None:
        _validate_development_evaluation(record.evaluation)


def _physical_items_equal(
    left: Tuple[Tuple[str, object], ...],
    right: Tuple[Tuple[str, object], ...],
) -> bool:
    return len(left) == len(right) and all(
        left_name == right_name
        and type(left_name) is type(right_name)
        and left_value == right_value
        and type(left_value) is type(right_value)
        for (left_name, left_value), (right_name, right_value) in zip(left, right)
    )


@dataclass(frozen=True)
class DevelopmentSearchResultV2:
    """A replayable pure-scheduler outcome; it is not a persisted release artifact."""

    status: str
    completed_sweeps: int
    attempt_records: Tuple[AttemptRecordV2, ...]
    incumbent_logical_candidate_items: Tuple[Tuple[str, object], ...] | None
    incumbent_physical_candidate_items: Tuple[Tuple[str, object], ...] | None
    incumbent_candidate_sha256: str | None

    @property
    def attempt_count(self) -> int:
        return len(self.attempt_records)

    @property
    def cache_hit_count(self) -> int:
        return sum(record.cache_hit for record in self.attempt_records)

    @property
    def evaluator_invocation_count(self) -> int:
        return sum(
            not record.cache_hit
            and record.status != ATTEMPT_STATUS_CONSTRAINT_FAILURE
            for record in self.attempt_records
        )

    @property
    def last_record_sha256(self) -> str:
        if not self.attempt_records:
            return _ZERO_SHA256
        return self.attempt_records[-1].record_sha256


DevelopmentEvaluatorV2 = Callable[
    [Mapping[str, object], Mapping[str, object], EvaluationCacheIdentityV2],
    DevelopmentEvaluationV2,
]


def _evaluation_payload(evaluation: DevelopmentEvaluationV2) -> Mapping[str, object]:
    _validate_development_evaluation(evaluation)
    return {
        "feasible": evaluation.feasible,
        "failure_reasons": list(evaluation.failure_reasons),
        "objective": {
            "estimated_dispatch_cost": evaluation.estimated_dispatch_cost,
            "maximum_alias_ratio": evaluation.maximum_alias_ratio,
            "maximum_ringing_excursion": evaluation.maximum_ringing_excursion,
            "mean_ms_ssim_delta_vs_conventional": (
                evaluation.mean_ms_ssim_delta_vs_conventional
            ),
            "mean_y_psnr_delta_vs_fixed_db": (
                evaluation.mean_y_psnr_delta_vs_fixed_db
            ),
            "mean_y_psnr_delta_vs_non_ash_db": (
                evaluation.mean_y_psnr_delta_vs_non_ash_db
            ),
        },
    }


def _evaluation_semantic_sha256(evaluation: DevelopmentEvaluationV2) -> str:
    return canonical_sha256(_evaluation_payload(evaluation))


def _attempt_record_payload(record: AttemptRecordV2) -> Mapping[str, object]:
    return {
        "cache_hit": record.cache_hit,
        "cache_identity": {
            "calibration_plan_file_sha256": (
                record.cache_identity.calibration_plan_file_sha256
            ),
            "candidate_vector_sha256": (
                record.cache_identity.candidate_vector_sha256
            ),
            "split": record.cache_identity.split,
        },
        "candidate_vector_sha256": record.candidate_vector_sha256,
        "canonical_failure_reasons": list(record.canonical_failure_reasons),
        "coordinate": record.coordinate,
        "domain": _ATTEMPT_RECORD_DOMAIN,
        "evaluation": (
            None if record.evaluation is None else _evaluation_payload(record.evaluation)
        ),
        "failure_reasons": list(record.failure_reasons),
        "phase": record.phase,
        "physical_candidate_items": [
            [name, value] for name, value in record.physical_candidate_items
        ],
        "previous_record_sha256": record.previous_record_sha256,
        "sequence": record.sequence,
        "split": record.split,
        "status": record.status,
        "sweep": record.sweep,
        "value": record.value,
    }


def attempt_record_sha256_v2(record: AttemptRecordV2) -> str:
    """Recompute the semantic record digest, excluding its claimed digest."""

    _validate_attempt_record_shape(record)
    return canonical_sha256(_attempt_record_payload(record))


def evaluation_cache_identity_v2(
    split: str,
    physical_candidate: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> EvaluationCacheIdentityV2:
    """Build the frozen semantic cache triple without defining byte framing."""

    candidate_sha256 = candidate_vector_sha256_v2(physical_candidate, plan)
    return EvaluationCacheIdentityV2(
        split=split,
        candidate_vector_sha256=candidate_sha256,
        calibration_plan_file_sha256=plan.plan_file_sha256,
    )


def canonical_development_failure_reasons_v2(
    failures: Sequence[str],
) -> Tuple[str, ...]:
    """Apply the inherited V1 restoration-count normalization exactly."""

    if type(failures) not in {tuple, list}:
        raise CalibrationSchedulerV2Error("development failures are not a sequence")
    canonical = set()
    for failure in failures:
        if type(failure) is not str or not failure:
            raise CalibrationSchedulerV2Error("development failure reason is invalid")
        domain, separator, reason = failure.partition(":")
        if domain not in {"engine_raw", "container_decoded"} or not separator:
            raise CalibrationSchedulerV2Error(
                "development failure reason lacks a comparison domain"
            )
        if reason in _GLOBAL_DEVELOPMENT_CHECK_FAILURES:
            canonical.add(f"check:{reason}")
        elif reason.startswith("occupancy:"):
            canonical.add(f"check:route_{reason}")
        elif reason == "h07_performance":
            canonical.add("performance:h07")
        elif reason.startswith("performance:"):
            canonical.add(reason)
        else:
            canonical.add(failure)
    return tuple(sorted(canonical))


def development_search_key_v2(
    evaluation: DevelopmentEvaluationV2,
    physical_candidate: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> Tuple[object, ...]:
    """Rank with inherited metrics and the complete canonical 48-field tie-break."""

    _validate_development_evaluation(evaluation)
    canonical_failures = canonical_development_failure_reasons_v2(
        evaluation.failure_reasons
    )
    return (
        0 if evaluation.feasible else 1,
        0 if evaluation.feasible else len(canonical_failures),
        -evaluation.mean_y_psnr_delta_vs_fixed_db,
        -evaluation.mean_y_psnr_delta_vs_non_ash_db,
        -evaluation.mean_ms_ssim_delta_vs_conventional,
        evaluation.maximum_ringing_excursion,
        evaluation.maximum_alias_ratio,
        evaluation.estimated_dispatch_cost,
        serialized_candidate_vector_v2(physical_candidate, plan),
    )


@dataclass(frozen=True)
class _EligibleCandidate:
    logical_items: Tuple[Tuple[str, object], ...]
    physical_items: Tuple[Tuple[str, object], ...]
    evaluation: DevelopmentEvaluationV2


@dataclass(frozen=True)
class _CachedEvaluation:
    physical_items: Tuple[Tuple[str, object], ...]
    evaluation: DevelopmentEvaluationV2


class _SearchState:
    def __init__(self, plan: ParsedCalibrationPlanV2) -> None:
        if type(plan) is not ParsedCalibrationPlanV2:
            raise CalibrationSchedulerV2Error("parsed V2 plan has the wrong type")
        self.plan = plan
        self.scalar_order = plan.scalar_parameter_order
        self.scalar_domains = dict(plan.scalar_domains)
        self.current = dict(plan.scalar_initial_values)
        if len(self.scalar_order) != 37 or sum(
            len(self.scalar_domains[name]) for name in self.scalar_order
        ) != SCALAR_ATTEMPTS_PER_SWEEP:
            raise CalibrationSchedulerV2Error("authenticated scalar schedule is invalid")

        probe = {ATOMIC_STRUCTURAL_COORDINATE: 0, **self.current}
        materialize_candidate_vector_v2(probe, plan)

        self.sweep = 1
        self.phase = "structural_scan"
        self.structural_position = 0
        self.scalar_position = 0
        self.scalar_value_position = 0
        self.changed = False
        self.completed_sweeps = 0
        self.status = STATUS_IN_PROGRESS
        self.batch: list[_EligibleCandidate] = []
        self.records: list[AttemptRecordV2] = []
        self.cache: Dict[EvaluationCacheIdentityV2, _CachedEvaluation] = {}

    def _ordered_logical(
        self,
        candidate: Mapping[str, object],
    ) -> Mapping[str, object]:
        return {
            name: candidate[name]
            for name in self.plan.logical_parameter_order
        }

    def expected_attempt(
        self,
    ) -> Tuple[Mapping[str, object], str, str, object]:
        if self.status != STATUS_IN_PROGRESS:
            raise CalibrationSchedulerV2Error("attempt trace continues after terminal state")
        if self.phase == "structural_scan":
            ordinal = self.structural_position
            candidate = {
                **self.current,
                ATOMIC_STRUCTURAL_COORDINATE: ordinal,
            }
            return (
                self._ordered_logical(candidate),
                self.phase,
                ATOMIC_STRUCTURAL_COORDINATE,
                ordinal,
            )
        coordinate = self.scalar_order[self.scalar_position]
        value = self.scalar_domains[coordinate][self.scalar_value_position]
        candidate = dict(self.current)
        candidate[coordinate] = value
        return self._ordered_logical(candidate), self.phase, coordinate, value

    def _select_batch(self) -> _EligibleCandidate:
        if not self.batch:
            raise CalibrationSchedulerV2Error("scheduler batch has no eligible candidate")
        return min(
            self.batch,
            key=lambda item: development_search_key_v2(
                item.evaluation,
                dict(item.physical_items),
                self.plan,
            ),
        )

    def _finish_structural_scan(self) -> None:
        if not self.batch:
            self.status = STATUS_FAILED_NO_ELIGIBLE_STRUCTURAL
            return
        selected = self._select_batch()
        selected_logical = dict(selected.logical_items)
        previous_ordinal = self.current.get(ATOMIC_STRUCTURAL_COORDINATE)
        selected_ordinal = selected_logical[ATOMIC_STRUCTURAL_COORDINATE]
        if previous_ordinal is None or previous_ordinal != selected_ordinal:
            self.changed = True
        self.current = selected_logical
        self.batch = []
        self.phase = "scalar_scan"
        self.scalar_position = 0
        self.scalar_value_position = 0

    def _finish_scalar_coordinate(self) -> None:
        if not self.batch:
            raise CalibrationSchedulerV2Error(
                "scalar coordinate has no eligible retained candidate"
            )
        coordinate = self.scalar_order[self.scalar_position]
        selected = self._select_batch()
        selected_logical = dict(selected.logical_items)
        if selected_logical[coordinate] != self.current[coordinate]:
            self.changed = True
        self.current = selected_logical
        self.batch = []
        self.scalar_position += 1
        self.scalar_value_position = 0
        if self.scalar_position < len(self.scalar_order):
            return

        self.completed_sweeps = self.sweep
        physical = materialize_candidate_vector_v2(self.current, self.plan)
        identity = evaluation_cache_identity_v2(DEVELOPMENT_SPLIT, physical, self.plan)
        cached = self.cache.get(identity)
        if cached is None or not _physical_items_equal(
            cached.physical_items,
            tuple(physical.items()),
        ):
            raise CalibrationSchedulerV2Error(
                "completed sweep incumbent lacks exact cached evaluation"
            )
        if not self.changed:
            self.status = (
                STATUS_TERMINATED_FEASIBLE
                if cached.evaluation.feasible
                else STATUS_FAILED_INFEASIBLE_FIXED_POINT
            )
            return
        if self.sweep == MAXIMUM_SWEEPS:
            self.status = STATUS_FAILED_MAXIMUM_SWEEPS
            return
        self.sweep += 1
        self.phase = "structural_scan"
        self.structural_position = 0
        self.scalar_position = 0
        self.scalar_value_position = 0
        self.changed = False

    def apply(self, record: AttemptRecordV2) -> None:
        logical, phase, coordinate, value = self.expected_attempt()
        physical = materialize_candidate_vector_v2(logical, self.plan)
        physical_items = tuple(physical.items())
        candidate_sha256 = candidate_vector_sha256_v2(physical, self.plan)
        identity = EvaluationCacheIdentityV2(
            split=DEVELOPMENT_SPLIT,
            candidate_vector_sha256=candidate_sha256,
            calibration_plan_file_sha256=self.plan.plan_file_sha256,
        )

        expected_sequence = len(self.records)
        expected_previous = (
            _ZERO_SHA256 if not self.records else self.records[-1].record_sha256
        )
        if (
            type(record) is not AttemptRecordV2
            or type(record.sequence) is not int
            or record.sequence != expected_sequence
            or record.previous_record_sha256 != expected_previous
            or not _is_sha256(record.record_sha256)
            or record.record_sha256 != attempt_record_sha256_v2(record)
        ):
            raise CalibrationSchedulerV2Error("attempt record hash chain is invalid")
        if (
            record.split != DEVELOPMENT_SPLIT
            or record.phase != phase
            or type(record.sweep) is not int
            or record.sweep != self.sweep
            or record.coordinate != coordinate
            or type(record.value) is not type(value)
            or record.value != value
            or not _physical_items_equal(
                record.physical_candidate_items,
                physical_items,
            )
            or record.candidate_vector_sha256 != candidate_sha256
            or record.cache_identity != identity
            or type(record.cache_hit) is not bool
            or type(record.failure_reasons) is not tuple
            or type(record.canonical_failure_reasons) is not tuple
        ):
            raise CalibrationSchedulerV2Error("attempt record differs from the schedule")

        try:
            validate_candidate_constraints_v2(physical, self.plan)
        except CalibrationPlanCodecError as error:
            if (
                record.status != ATTEMPT_STATUS_CONSTRAINT_FAILURE
                or record.cache_hit
                or record.failure_reasons != (str(error),)
                or record.canonical_failure_reasons
                or record.evaluation is not None
            ):
                raise CalibrationSchedulerV2Error(
                    "constraint-failure attempt semantics are invalid"
                ) from error
            eligible = None
            cache_addition = None
        else:
            cached = self.cache.get(identity)
            if cached is not None:
                if (
                    not record.cache_hit
                    or record.status
                    != (
                        ATTEMPT_STATUS_FEASIBLE
                        if cached.evaluation.feasible
                        else ATTEMPT_STATUS_INFEASIBLE
                    )
                    or record.evaluation is None
                    or _evaluation_semantic_sha256(record.evaluation)
                    != _evaluation_semantic_sha256(cached.evaluation)
                    or not _physical_items_equal(
                        record.physical_candidate_items,
                        cached.physical_items,
                    )
                ):
                    raise CalibrationSchedulerV2Error("cache-hit semantics are invalid")
                evaluation = cached.evaluation
                cache_addition = None
            elif record.status == ATTEMPT_STATUS_EVALUATION_FAILURE:
                if (
                    record.cache_hit
                    or len(record.failure_reasons) != 1
                    or type(record.failure_reasons[0]) is not str
                    or not record.failure_reasons[0]
                    or record.canonical_failure_reasons
                    or record.evaluation is not None
                ):
                    raise CalibrationSchedulerV2Error(
                        "evaluation-failure attempt semantics are invalid"
                    )
                evaluation = None
                cache_addition = None
            else:
                if type(record.evaluation) is not DevelopmentEvaluationV2:
                    raise CalibrationSchedulerV2Error(
                        "successful evaluation attempt lacks exact result"
                    )
                evaluation = record.evaluation
                expected_status = (
                    ATTEMPT_STATUS_FEASIBLE
                    if evaluation.feasible
                    else ATTEMPT_STATUS_INFEASIBLE
                )
                expected_canonical = canonical_development_failure_reasons_v2(
                    evaluation.failure_reasons
                )
                if (
                    record.cache_hit
                    or record.status != expected_status
                    or record.failure_reasons != evaluation.failure_reasons
                    or record.canonical_failure_reasons != expected_canonical
                ):
                    raise CalibrationSchedulerV2Error(
                        "evaluation attempt semantics are invalid"
                    )
                cache_addition = _CachedEvaluation(physical_items, evaluation)

            if evaluation is not None:
                expected_canonical = canonical_development_failure_reasons_v2(
                    evaluation.failure_reasons
                )
                if (
                    record.failure_reasons != evaluation.failure_reasons
                    or record.canonical_failure_reasons != expected_canonical
                ):
                    raise CalibrationSchedulerV2Error(
                        "recorded evaluation ranking fields are invalid"
                    )
                eligible = _EligibleCandidate(
                    tuple(logical.items()),
                    physical_items,
                    evaluation,
                )
            else:
                eligible = None

        if cache_addition is not None:
            self.cache[identity] = cache_addition
        if eligible is not None:
            self.batch.append(eligible)
        self.records.append(record)

        if len(self.records) > MAXIMUM_DEVELOPMENT_ATTEMPTS:
            raise CalibrationSchedulerV2Error("development attempt budget exceeded")
        if self.phase == "structural_scan":
            self.structural_position += 1
            if self.structural_position == STRUCTURAL_ATTEMPTS_PER_SWEEP:
                self._finish_structural_scan()
            return

        coordinate_domain = self.scalar_domains[self.scalar_order[self.scalar_position]]
        self.scalar_value_position += 1
        if self.scalar_value_position == len(coordinate_domain):
            self._finish_scalar_coordinate()

    def result(self) -> DevelopmentSearchResultV2:
        if ATOMIC_STRUCTURAL_COORDINATE not in self.current:
            logical_items = None
            physical_items = None
            candidate_sha256 = None
        else:
            logical_items = tuple(self.current.items())
            physical = materialize_candidate_vector_v2(self.current, self.plan)
            physical_items = tuple(physical.items())
            candidate_sha256 = candidate_vector_sha256_v2(physical, self.plan)
        return DevelopmentSearchResultV2(
            status=self.status,
            completed_sweeps=self.completed_sweeps,
            attempt_records=tuple(self.records),
            incumbent_logical_candidate_items=logical_items,
            incumbent_physical_candidate_items=physical_items,
            incumbent_candidate_sha256=candidate_sha256,
        )


def _new_attempt_record(
    state: _SearchState,
    *,
    physical: Mapping[str, object],
    identity: EvaluationCacheIdentityV2,
    phase: str,
    coordinate: str,
    value: object,
    status: str,
    cache_hit: bool,
    failure_reasons: Tuple[str, ...],
    canonical_failure_reasons: Tuple[str, ...],
    evaluation: DevelopmentEvaluationV2 | None,
) -> AttemptRecordV2:
    record = AttemptRecordV2(
        sequence=len(state.records),
        previous_record_sha256=(
            _ZERO_SHA256 if not state.records else state.records[-1].record_sha256
        ),
        record_sha256=_ZERO_SHA256,
        split=DEVELOPMENT_SPLIT,
        phase=phase,
        sweep=state.sweep,
        coordinate=coordinate,
        value=value,
        physical_candidate_items=tuple(physical.items()),
        candidate_vector_sha256=identity.candidate_vector_sha256,
        cache_identity=identity,
        status=status,
        cache_hit=cache_hit,
        failure_reasons=failure_reasons,
        canonical_failure_reasons=canonical_failure_reasons,
        evaluation=evaluation,
    )
    return replace(record, record_sha256=attempt_record_sha256_v2(record))


def _evaluate_next_attempt(
    state: _SearchState,
    evaluator: DevelopmentEvaluatorV2,
) -> AttemptRecordV2:
    logical, phase, coordinate, value = state.expected_attempt()
    physical = materialize_candidate_vector_v2(logical, state.plan)
    identity = evaluation_cache_identity_v2(DEVELOPMENT_SPLIT, physical, state.plan)
    try:
        validate_candidate_constraints_v2(physical, state.plan)
    except CalibrationPlanCodecError as error:
        return _new_attempt_record(
            state,
            physical=physical,
            identity=identity,
            phase=phase,
            coordinate=coordinate,
            value=value,
            status=ATTEMPT_STATUS_CONSTRAINT_FAILURE,
            cache_hit=False,
            failure_reasons=(str(error),),
            canonical_failure_reasons=(),
            evaluation=None,
        )

    cached = state.cache.get(identity)
    if cached is not None:
        evaluation = cached.evaluation
        return _new_attempt_record(
            state,
            physical=physical,
            identity=identity,
            phase=phase,
            coordinate=coordinate,
            value=value,
            status=(
                ATTEMPT_STATUS_FEASIBLE
                if evaluation.feasible
                else ATTEMPT_STATUS_INFEASIBLE
            ),
            cache_hit=True,
            failure_reasons=evaluation.failure_reasons,
            canonical_failure_reasons=canonical_development_failure_reasons_v2(
                evaluation.failure_reasons
            ),
            evaluation=evaluation,
        )

    try:
        evaluation = evaluator(dict(logical), dict(physical), identity)
        if type(evaluation) is not DevelopmentEvaluationV2:
            raise CalibrationSchedulerV2Error(
                "evaluator returned the wrong result type"
            )
    except Exception as error:
        detail = f"{type(error).__module__}.{type(error).__qualname__}: {error}"
        return _new_attempt_record(
            state,
            physical=physical,
            identity=identity,
            phase=phase,
            coordinate=coordinate,
            value=value,
            status=ATTEMPT_STATUS_EVALUATION_FAILURE,
            cache_hit=False,
            failure_reasons=(detail,),
            canonical_failure_reasons=(),
            evaluation=None,
        )

    return _new_attempt_record(
        state,
        physical=physical,
        identity=identity,
        phase=phase,
        coordinate=coordinate,
        value=value,
        status=(
            ATTEMPT_STATUS_FEASIBLE
            if evaluation.feasible
            else ATTEMPT_STATUS_INFEASIBLE
        ),
        cache_hit=False,
        failure_reasons=evaluation.failure_reasons,
        canonical_failure_reasons=canonical_development_failure_reasons_v2(
            evaluation.failure_reasons
        ),
        evaluation=evaluation,
    )


def _replay_state(
    plan: ParsedCalibrationPlanV2,
    records: Sequence[AttemptRecordV2],
    *,
    expected_attempt_count: int | None = None,
    expected_last_record_sha256: str | None = None,
) -> _SearchState:
    if type(records) not in {tuple, list}:
        raise CalibrationSchedulerV2Error("attempt records must be a concrete sequence")
    snapshot = tuple(records)
    if (expected_attempt_count is None) != (expected_last_record_sha256 is None):
        raise CalibrationSchedulerV2Error(
            "checkpoint attempt count and last SHA-256 must be supplied together"
        )
    if expected_attempt_count is not None:
        if (
            type(expected_attempt_count) is not int
            or expected_attempt_count < 0
            or expected_attempt_count != len(snapshot)
            or not _is_sha256(expected_last_record_sha256)
        ):
            raise CalibrationSchedulerV2Error("resume checkpoint binding is invalid")
        actual_last = _ZERO_SHA256 if not snapshot else snapshot[-1].record_sha256
        if actual_last != expected_last_record_sha256:
            raise CalibrationSchedulerV2Error("resume checkpoint last SHA-256 differs")

    state = _SearchState(plan)
    for record in snapshot:
        state.apply(record)
    return state


def replay_development_attempts_v2(
    plan: ParsedCalibrationPlanV2,
    records: Sequence[AttemptRecordV2],
    *,
    expected_attempt_count: int | None = None,
    expected_last_record_sha256: str | None = None,
) -> DevelopmentSearchResultV2:
    """Verify and replay an immutable semantic prefix or complete trace."""

    return _replay_state(
        plan,
        records,
        expected_attempt_count=expected_attempt_count,
        expected_last_record_sha256=expected_last_record_sha256,
    ).result()


def run_development_search_v2(
    plan: ParsedCalibrationPlanV2,
    evaluator: DevelopmentEvaluatorV2,
    *,
    resume_records: Sequence[AttemptRecordV2] = (),
    expected_resume_attempt_count: int | None = None,
    expected_resume_last_record_sha256: str | None = None,
) -> DevelopmentSearchResultV2:
    """Run or resume the exact preregistered V2 development-search schedule."""

    if not callable(evaluator):
        raise CalibrationSchedulerV2Error("development evaluator is not callable")
    if resume_records and (
        expected_resume_attempt_count is None
        or expected_resume_last_record_sha256 is None
    ):
        raise CalibrationSchedulerV2Error(
            "nonempty resume trace requires an exact checkpoint binding"
        )
    state = _replay_state(
        plan,
        resume_records,
        expected_attempt_count=expected_resume_attempt_count,
        expected_last_record_sha256=expected_resume_last_record_sha256,
    )
    while state.status == STATUS_IN_PROGRESS:
        if len(state.records) >= MAXIMUM_DEVELOPMENT_ATTEMPTS:
            raise CalibrationSchedulerV2Error(
                "scheduler requested an attempt beyond the frozen budget"
            )
        state.apply(_evaluate_next_attempt(state, evaluator))
    result = state.result()
    if result.attempt_count > MAXIMUM_DEVELOPMENT_ATTEMPTS:
        raise CalibrationSchedulerV2Error("development attempt budget exceeded")
    if (
        result.status == STATUS_TERMINATED_FEASIBLE
        and result.attempt_count < 2 * ATTEMPTS_PER_COMPLETE_SWEEP
    ):
        raise CalibrationSchedulerV2Error(
            "first structural incumbent terminated without a later sweep"
        )
    return result
