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
MAXIMUM_VALIDATION_NEIGHBORHOOD = 374

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
    if type(value) not in {int, float}:
        raise CalibrationSchedulerV2Error(f"{label} must be a finite built-in number")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
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
    for name in (
        "maximum_ringing_excursion",
        "maximum_alias_ratio",
        "estimated_dispatch_cost",
    ):
        if getattr(evaluation, name) < 0:
            raise CalibrationSchedulerV2Error(f"{name} must be nonnegative")


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


@dataclass(frozen=True)
class ValidationCandidateV2:
    """One complete V2 candidate identity in the validation neighborhood."""

    logical_candidate_items: Tuple[Tuple[str, object], ...]
    physical_candidate_items: Tuple[Tuple[str, object], ...]
    candidate_vector_sha256: str
    development_cache_identity: EvaluationCacheIdentityV2
    validation_cache_identity: EvaluationCacheIdentityV2


@dataclass(frozen=True)
class ValidationNeighborhoodV2:
    """The frozen candidate set; tuple order is not validation-access authority."""

    terminal_candidate_sha256: str
    candidates_before_constraint_filtering: Tuple[ValidationCandidateV2, ...]
    constraint_valid_candidates: Tuple[ValidationCandidateV2, ...]

    @property
    def candidate_count_before_constraint_filtering(self) -> int:
        return len(self.candidates_before_constraint_filtering)

    @property
    def constraint_valid_candidate_count(self) -> int:
        return len(self.constraint_valid_candidates)


@dataclass(frozen=True)
class DevelopmentCandidateEvidenceV2:
    """Exact successful development evidence for one constraint-valid neighbor."""

    candidate: ValidationCandidateV2
    evaluation: DevelopmentEvaluationV2


@dataclass(frozen=True)
class ValidationAdmissionV2:
    """Development-only freeze produced before any validation access."""

    development_attempt_records: Tuple[AttemptRecordV2, ...]
    development_last_record_sha256: str
    neighborhood: ValidationNeighborhoodV2
    development_evidence: Tuple[DevelopmentCandidateEvidenceV2, ...]
    admitted_candidates: Tuple[ValidationCandidateV2, ...]

    @property
    def development_attempt_count(self) -> int:
        return len(self.development_attempt_records)

    @property
    def development_evidence_count(self) -> int:
        return len(self.development_evidence)

    @property
    def admitted_candidate_count(self) -> int:
        return len(self.admitted_candidates)


@dataclass(frozen=True)
class ValidationEvaluationV2:
    """Aggregate feasibility plus inherited engine-raw validation rank fields."""

    feasible: bool
    failure_reasons: Tuple[str, ...]
    y_vs_fixed_ci_low: object
    y_vs_non_ash_ci_low: object
    y_vs_conventional_ci_low: object
    mean_ms_ssim_delta_vs_conventional: object
    maximum_ringing_excursion: object
    maximum_alias_ratio: object
    estimated_dispatch_cost: object

    def __post_init__(self) -> None:
        _validate_validation_evaluation(self)


@dataclass(frozen=True)
class ScoredValidationCandidateV2:
    """One successful validation evaluation tied to its exact candidate."""

    candidate: ValidationCandidateV2
    evaluation: ValidationEvaluationV2


@dataclass(frozen=True)
class ValidationEvaluationFailureV2:
    """One attempted admitted candidate whose validation evaluator failed."""

    candidate: ValidationCandidateV2
    failure_reasons: Tuple[str, ...]


@dataclass(frozen=True)
class ValidationSelectionV2:
    """Pure feasible frontier and winner; not a persisted selection artifact."""

    pareto_frontier: Tuple[ScoredValidationCandidateV2, ...]
    evaluation_failures: Tuple[ValidationEvaluationFailureV2, ...]
    selected: ScoredValidationCandidateV2


def _validate_validation_evaluation(evaluation: ValidationEvaluationV2) -> None:
    if type(evaluation) is not ValidationEvaluationV2:
        raise CalibrationSchedulerV2Error("validation evaluation has the wrong type")
    if type(evaluation.feasible) is not bool:
        raise CalibrationSchedulerV2Error("validation feasibility must be bool")
    if type(evaluation.failure_reasons) is not tuple or any(
        type(reason) is not str or not reason for reason in evaluation.failure_reasons
    ):
        raise CalibrationSchedulerV2Error(
            "validation failure-reason members must be nonempty built-in strings"
        )
    if len(set(evaluation.failure_reasons)) != len(evaluation.failure_reasons):
        raise CalibrationSchedulerV2Error("validation failure reasons repeat")
    if evaluation.feasible != (len(evaluation.failure_reasons) == 0):
        raise CalibrationSchedulerV2Error(
            "validation feasibility and failure reasons disagree"
        )
    for name in (
        "y_vs_fixed_ci_low",
        "y_vs_non_ash_ci_low",
        "y_vs_conventional_ci_low",
        "mean_ms_ssim_delta_vs_conventional",
        "maximum_ringing_excursion",
        "maximum_alias_ratio",
        "estimated_dispatch_cost",
    ):
        _require_finite_number(getattr(evaluation, name), label=name)
    for name in (
        "maximum_ringing_excursion",
        "maximum_alias_ratio",
        "estimated_dispatch_cost",
    ):
        if getattr(evaluation, name) < 0:
            raise CalibrationSchedulerV2Error(f"{name} must be nonnegative")


def _validation_candidate_from_logical(
    logical_candidate: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> ValidationCandidateV2:
    physical = materialize_candidate_vector_v2(logical_candidate, plan)
    logical = {
        name: physical[name]
        for name in plan.logical_parameter_order
    }
    candidate_sha256 = candidate_vector_sha256_v2(physical, plan)
    return ValidationCandidateV2(
        logical_candidate_items=tuple(logical.items()),
        physical_candidate_items=tuple(physical.items()),
        candidate_vector_sha256=candidate_sha256,
        development_cache_identity=EvaluationCacheIdentityV2(
            split=DEVELOPMENT_SPLIT,
            candidate_vector_sha256=candidate_sha256,
            calibration_plan_file_sha256=plan.plan_file_sha256,
        ),
        validation_cache_identity=EvaluationCacheIdentityV2(
            split=VALIDATION_SPLIT,
            candidate_vector_sha256=candidate_sha256,
            calibration_plan_file_sha256=plan.plan_file_sha256,
        ),
    )


def _validate_validation_candidate(
    candidate: ValidationCandidateV2,
    plan: ParsedCalibrationPlanV2,
) -> None:
    if type(candidate) is not ValidationCandidateV2:
        raise CalibrationSchedulerV2Error("validation candidate has the wrong type")
    if (
        type(candidate.logical_candidate_items) is not tuple
        or type(candidate.physical_candidate_items) is not tuple
        or len(candidate.logical_candidate_items) != len(plan.logical_parameter_order)
        or len(candidate.physical_candidate_items) != len(plan.physical_candidate_order)
        or not _is_sha256(candidate.candidate_vector_sha256)
    ):
        raise CalibrationSchedulerV2Error("validation candidate fields are invalid")
    for items in (
        candidate.logical_candidate_items,
        candidate.physical_candidate_items,
    ):
        for item in items:
            if (
                type(item) is not tuple
                or len(item) != 2
                or type(item[0]) is not str
                or type(item[1]) not in {int, str}
            ):
                raise CalibrationSchedulerV2Error(
                    "validation candidate item is invalid"
                )
    logical_names = tuple(name for name, _ in candidate.logical_candidate_items)
    physical_names = tuple(name for name, _ in candidate.physical_candidate_items)
    if (
        logical_names != plan.logical_parameter_order
        or physical_names != plan.physical_candidate_order
    ):
        raise CalibrationSchedulerV2Error("validation candidate order is invalid")
    _validate_cache_identity(candidate.development_cache_identity)
    _validate_cache_identity(candidate.validation_cache_identity)
    expected = _validation_candidate_from_logical(
        dict(candidate.logical_candidate_items),
        plan,
    )
    if (
        not _physical_items_equal(
            candidate.physical_candidate_items,
            expected.physical_candidate_items,
        )
        or candidate.candidate_vector_sha256 != expected.candidate_vector_sha256
        or candidate.development_cache_identity
        != expected.development_cache_identity
        or candidate.validation_cache_identity != expected.validation_cache_identity
    ):
        raise CalibrationSchedulerV2Error(
            "validation candidate identity differs from materialization"
        )


def validation_neighborhood_v2(
    terminal_logical_candidate: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> ValidationNeighborhoodV2:
    """Build the exact unique 374-candidate set before relational filtering.

    Canonical serialization is used only to normalize this in-memory tuple.  It
    does not define or authorize a validation evaluation order.
    """

    terminal_physical = materialize_candidate_vector_v2(
        terminal_logical_candidate,
        plan,
    )
    validate_candidate_constraints_v2(terminal_physical, plan)
    terminal = {
        name: terminal_physical[name]
        for name in plan.logical_parameter_order
    }
    generated = []
    for ordinal in range(STRUCTURAL_ATTEMPTS_PER_SWEEP):
        logical = dict(terminal)
        logical[ATOMIC_STRUCTURAL_COORDINATE] = ordinal
        generated.append(_validation_candidate_from_logical(logical, plan))
    domains = dict(plan.scalar_domains)
    for coordinate in plan.scalar_parameter_order:
        for value in domains[coordinate]:
            if (
                type(value) is type(terminal[coordinate])
                and value == terminal[coordinate]
            ):
                continue
            logical = dict(terminal)
            logical[coordinate] = value
            generated.append(_validation_candidate_from_logical(logical, plan))

    if len(generated) != MAXIMUM_VALIDATION_NEIGHBORHOOD:
        raise CalibrationSchedulerV2Error(
            "validation neighborhood does not contain 374 generated candidates"
        )
    by_sha256: Dict[str, ValidationCandidateV2] = {}
    for candidate in generated:
        existing = by_sha256.get(candidate.candidate_vector_sha256)
        if existing is not None:
            if not _physical_items_equal(
                existing.physical_candidate_items,
                candidate.physical_candidate_items,
            ):
                raise CalibrationSchedulerV2Error(
                    "validation candidate SHA-256 collision"
                )
            raise CalibrationSchedulerV2Error(
                "validation neighborhood contains a duplicate candidate"
            )
        by_sha256[candidate.candidate_vector_sha256] = candidate

    normalized = tuple(
        sorted(
            by_sha256.values(),
            key=lambda candidate: serialized_candidate_vector_v2(
                dict(candidate.physical_candidate_items),
                plan,
            ),
        )
    )
    constraint_valid = []
    for candidate in normalized:
        try:
            validate_candidate_constraints_v2(
                dict(candidate.physical_candidate_items),
                plan,
            )
        except CalibrationPlanCodecError:
            continue
        constraint_valid.append(candidate)

    terminal_sha256 = candidate_vector_sha256_v2(terminal_physical, plan)
    if terminal_sha256 not in by_sha256:
        raise CalibrationSchedulerV2Error(
            "terminal candidate is absent from its validation neighborhood"
        )
    return ValidationNeighborhoodV2(
        terminal_candidate_sha256=terminal_sha256,
        candidates_before_constraint_filtering=normalized,
        constraint_valid_candidates=tuple(constraint_valid),
    )


def _derive_validation_admission_from_replay(
    plan: ParsedCalibrationPlanV2,
    replay: DevelopmentSearchResultV2,
) -> ValidationAdmissionV2:
    """Derive admission only from an already replay-verified terminal trace."""

    if (
        replay.status != STATUS_TERMINATED_FEASIBLE
        or replay.incumbent_logical_candidate_items is None
        or replay.incumbent_candidate_sha256 is None
    ):
        raise CalibrationSchedulerV2Error(
            "validation admission requires a feasible development terminal"
        )
    neighborhood = validation_neighborhood_v2(
        dict(replay.incumbent_logical_candidate_items),
        plan,
    )
    if neighborhood.terminal_candidate_sha256 != replay.incumbent_candidate_sha256:
        raise CalibrationSchedulerV2Error(
            "validation neighborhood terminal differs from development replay"
        )

    evaluation_index: Dict[str, Tuple[Tuple[Tuple[str, object], ...], DevelopmentEvaluationV2]] = {}
    for record in replay.attempt_records:
        if record.evaluation is None:
            continue
        existing = evaluation_index.get(record.candidate_vector_sha256)
        if existing is not None:
            if (
                not _physical_items_equal(existing[0], record.physical_candidate_items)
                or _evaluation_semantic_sha256(existing[1])
                != _evaluation_semantic_sha256(record.evaluation)
            ):
                raise CalibrationSchedulerV2Error(
                    "development evidence index contains inconsistent duplicates"
                )
            continue
        evaluation_index[record.candidate_vector_sha256] = (
            record.physical_candidate_items,
            record.evaluation,
        )

    evidence = []
    admitted = []
    for candidate in neighborhood.constraint_valid_candidates:
        indexed = evaluation_index.get(candidate.candidate_vector_sha256)
        if indexed is None:
            raise CalibrationSchedulerV2Error(
                "constraint-valid validation neighbor lacks development evidence"
            )
        physical_items, evaluation = indexed
        if not _physical_items_equal(
            physical_items,
            candidate.physical_candidate_items,
        ):
            raise CalibrationSchedulerV2Error(
                "development evidence candidate bytes differ from neighborhood"
            )
        row = DevelopmentCandidateEvidenceV2(candidate, evaluation)
        evidence.append(row)
        if evaluation.feasible:
            admitted.append(candidate)
    if not admitted or not any(
        candidate.candidate_vector_sha256
        == neighborhood.terminal_candidate_sha256
        for candidate in admitted
    ):
        raise CalibrationSchedulerV2Error(
            "development-feasible terminal is absent from validation admission"
        )
    return ValidationAdmissionV2(
        development_attempt_records=replay.attempt_records,
        development_last_record_sha256=replay.last_record_sha256,
        neighborhood=neighborhood,
        development_evidence=tuple(evidence),
        admitted_candidates=tuple(admitted),
    )


def validation_admission_v2(
    plan: ParsedCalibrationPlanV2,
    development_records: Sequence[AttemptRecordV2],
    *,
    expected_attempt_count: int,
    expected_last_record_sha256: str,
) -> ValidationAdmissionV2:
    """Freeze development-complete validation admission without validation access."""

    replay = replay_development_attempts_v2(
        plan,
        development_records,
        expected_attempt_count=expected_attempt_count,
        expected_last_record_sha256=expected_last_record_sha256,
    )
    return _derive_validation_admission_from_replay(plan, replay)


def validation_objective_key_v2(
    evaluation: ValidationEvaluationV2,
    physical_candidate: Mapping[str, object],
    plan: ParsedCalibrationPlanV2,
) -> Tuple[object, ...]:
    """Apply the inherited validation tuple and complete 48-field tie-break."""

    _validate_validation_evaluation(evaluation)
    return (
        -evaluation.y_vs_fixed_ci_low,
        -evaluation.y_vs_non_ash_ci_low,
        -evaluation.y_vs_conventional_ci_low,
        -evaluation.mean_ms_ssim_delta_vs_conventional,
        evaluation.maximum_ringing_excursion,
        evaluation.maximum_alias_ratio,
        evaluation.estimated_dispatch_cost,
        serialized_candidate_vector_v2(physical_candidate, plan),
    )


def _validation_pareto_dimensions(
    evaluation: ValidationEvaluationV2,
) -> Tuple[object, ...]:
    _validate_validation_evaluation(evaluation)
    return (
        -evaluation.y_vs_fixed_ci_low,
        -evaluation.y_vs_non_ash_ci_low,
        -evaluation.y_vs_conventional_ci_low,
        -evaluation.mean_ms_ssim_delta_vs_conventional,
        evaluation.maximum_ringing_excursion,
        evaluation.maximum_alias_ratio,
        evaluation.estimated_dispatch_cost,
    )


def _validate_scored_validation_candidate(
    scored: ScoredValidationCandidateV2,
    plan: ParsedCalibrationPlanV2,
) -> None:
    if type(scored) is not ScoredValidationCandidateV2:
        raise CalibrationSchedulerV2Error(
            "scored validation candidate has the wrong type"
        )
    _validate_validation_candidate(scored.candidate, plan)
    _validate_validation_evaluation(scored.evaluation)


def _validate_validation_evaluation_failure(
    failure: ValidationEvaluationFailureV2,
    plan: ParsedCalibrationPlanV2,
) -> None:
    if type(failure) is not ValidationEvaluationFailureV2:
        raise CalibrationSchedulerV2Error(
            "validation evaluation failure has the wrong type"
        )
    _validate_validation_candidate(failure.candidate, plan)
    if (
        type(failure.failure_reasons) is not tuple
        or not failure.failure_reasons
        or any(
            type(reason) is not str or not reason
            for reason in failure.failure_reasons
        )
        or len(set(failure.failure_reasons)) != len(failure.failure_reasons)
    ):
        raise CalibrationSchedulerV2Error(
            "validation evaluator failure reasons are invalid"
        )


def _validate_validation_admission(
    admission: ValidationAdmissionV2,
    plan: ParsedCalibrationPlanV2,
) -> None:
    if (
        type(admission) is not ValidationAdmissionV2
        or type(admission.development_attempt_records) is not tuple
        or not admission.development_attempt_records
        or not _is_sha256(admission.development_last_record_sha256)
        or type(admission.neighborhood) is not ValidationNeighborhoodV2
        or type(admission.development_evidence) is not tuple
        or type(admission.admitted_candidates) is not tuple
    ):
        raise CalibrationSchedulerV2Error("validation admission fields are invalid")
    replay = replay_development_attempts_v2(
        plan,
        admission.development_attempt_records,
        expected_attempt_count=len(admission.development_attempt_records),
        expected_last_record_sha256=admission.development_last_record_sha256,
    )
    replay_admission = _derive_validation_admission_from_replay(plan, replay)
    neighborhood = admission.neighborhood
    if (
        not _is_sha256(neighborhood.terminal_candidate_sha256)
        or type(neighborhood.candidates_before_constraint_filtering) is not tuple
        or type(neighborhood.constraint_valid_candidates) is not tuple
        or len(neighborhood.candidates_before_constraint_filtering)
        != MAXIMUM_VALIDATION_NEIGHBORHOOD
    ):
        raise CalibrationSchedulerV2Error("validation neighborhood fields are invalid")

    all_candidates: Dict[str, ValidationCandidateV2] = {}
    derived_constraint_valid = set()
    for candidate in neighborhood.candidates_before_constraint_filtering:
        _validate_validation_candidate(candidate, plan)
        candidate_sha256 = candidate.candidate_vector_sha256
        if candidate_sha256 in all_candidates:
            raise CalibrationSchedulerV2Error(
                "validation neighborhood candidate repeats"
            )
        all_candidates[candidate_sha256] = candidate
        try:
            validate_candidate_constraints_v2(
                dict(candidate.physical_candidate_items),
                plan,
            )
        except CalibrationPlanCodecError:
            continue
        derived_constraint_valid.add(candidate_sha256)
    if neighborhood.terminal_candidate_sha256 not in all_candidates:
        raise CalibrationSchedulerV2Error(
            "validation neighborhood terminal is absent"
        )
    terminal_candidate = all_candidates[neighborhood.terminal_candidate_sha256]
    expected_neighborhood = validation_neighborhood_v2(
        dict(terminal_candidate.logical_candidate_items),
        plan,
    )
    expected_candidates = {
        candidate.candidate_vector_sha256: candidate
        for candidate in expected_neighborhood.candidates_before_constraint_filtering
    }
    if (
        expected_neighborhood.terminal_candidate_sha256
        != neighborhood.terminal_candidate_sha256
        or set(expected_candidates) != set(all_candidates)
        or any(
            not _physical_items_equal(
                candidate.physical_candidate_items,
                all_candidates[candidate_sha256].physical_candidate_items,
            )
            for candidate_sha256, candidate in expected_candidates.items()
        )
    ):
        raise CalibrationSchedulerV2Error(
            "validation neighborhood differs from exact terminal replacements"
        )

    declared_constraint_valid = set()
    for candidate in neighborhood.constraint_valid_candidates:
        _validate_validation_candidate(candidate, plan)
        candidate_sha256 = candidate.candidate_vector_sha256
        if (
            candidate_sha256 in declared_constraint_valid
            or candidate_sha256 not in all_candidates
            or not _physical_items_equal(
                candidate.physical_candidate_items,
                all_candidates[candidate_sha256].physical_candidate_items,
            )
        ):
            raise CalibrationSchedulerV2Error(
                "constraint-valid validation neighborhood is inconsistent"
            )
        declared_constraint_valid.add(candidate_sha256)
    if declared_constraint_valid != derived_constraint_valid:
        raise CalibrationSchedulerV2Error(
            "constraint-valid validation neighborhood set differs"
        )

    evidence_by_sha256 = {}
    for row in admission.development_evidence:
        if type(row) is not DevelopmentCandidateEvidenceV2:
            raise CalibrationSchedulerV2Error(
                "development candidate evidence has the wrong type"
            )
        _validate_validation_candidate(row.candidate, plan)
        _validate_development_evaluation(row.evaluation)
        candidate_sha256 = row.candidate.candidate_vector_sha256
        if (
            candidate_sha256 in evidence_by_sha256
            or candidate_sha256 not in declared_constraint_valid
            or not _physical_items_equal(
                row.candidate.physical_candidate_items,
                all_candidates[candidate_sha256].physical_candidate_items,
            )
        ):
            raise CalibrationSchedulerV2Error(
                "development candidate evidence is inconsistent"
            )
        evidence_by_sha256[candidate_sha256] = row
    if set(evidence_by_sha256) != declared_constraint_valid:
        raise CalibrationSchedulerV2Error(
            "development evidence does not cover the valid neighborhood"
        )

    admitted_by_sha256 = {}
    for candidate in admission.admitted_candidates:
        _validate_validation_candidate(candidate, plan)
        candidate_sha256 = candidate.candidate_vector_sha256
        if (
            candidate_sha256 in admitted_by_sha256
            or candidate_sha256 not in evidence_by_sha256
            or not evidence_by_sha256[candidate_sha256].evaluation.feasible
            or not _physical_items_equal(
                candidate.physical_candidate_items,
                all_candidates[candidate_sha256].physical_candidate_items,
            )
        ):
            raise CalibrationSchedulerV2Error(
                "admitted validation candidate is inconsistent"
            )
        admitted_by_sha256[candidate_sha256] = candidate
    expected_admitted = {
        candidate_sha256
        for candidate_sha256, row in evidence_by_sha256.items()
        if row.evaluation.feasible
    }
    if (
        set(admitted_by_sha256) != expected_admitted
        or neighborhood.terminal_candidate_sha256 not in admitted_by_sha256
    ):
        raise CalibrationSchedulerV2Error(
            "validation admission differs from feasible development evidence"
        )

    replay_evidence_by_sha256 = {
        row.candidate.candidate_vector_sha256: row
        for row in replay_admission.development_evidence
    }
    replay_admitted_sha256 = {
        candidate.candidate_vector_sha256
        for candidate in replay_admission.admitted_candidates
    }
    if (
        replay_admission.neighborhood.terminal_candidate_sha256
        != neighborhood.terminal_candidate_sha256
        or set(replay_evidence_by_sha256) != set(evidence_by_sha256)
        or replay_admitted_sha256 != set(admitted_by_sha256)
        or any(
            not _physical_items_equal(
                row.candidate.physical_candidate_items,
                evidence_by_sha256[
                    candidate_sha256
                ].candidate.physical_candidate_items,
            )
            or _evaluation_semantic_sha256(row.evaluation)
            != _evaluation_semantic_sha256(
                evidence_by_sha256[candidate_sha256].evaluation
            )
            for candidate_sha256, row in replay_evidence_by_sha256.items()
        )
    ):
        raise CalibrationSchedulerV2Error(
            "validation admission differs from replayed development evidence"
        )


def validation_pareto_frontier_v2(
    scored_candidates: Sequence[ScoredValidationCandidateV2],
    plan: ParsedCalibrationPlanV2,
) -> Tuple[ScoredValidationCandidateV2, ...]:
    """Return the feasible, non-dominated frontier in deterministic rank order."""

    if type(scored_candidates) not in {tuple, list}:
        raise CalibrationSchedulerV2Error(
            "scored validation candidates must be a concrete sequence"
        )
    snapshot = tuple(scored_candidates)
    seen = set()
    feasible = []
    for scored in snapshot:
        _validate_scored_validation_candidate(scored, plan)
        candidate_sha256 = scored.candidate.candidate_vector_sha256
        if candidate_sha256 in seen:
            raise CalibrationSchedulerV2Error(
                "scored validation candidate identity repeats"
            )
        seen.add(candidate_sha256)
        if scored.evaluation.feasible:
            feasible.append(scored)
    if not feasible:
        raise CalibrationSchedulerV2Error(
            "validation selection contains no feasible candidate"
        )

    frontier = []
    for index, scored in enumerate(feasible):
        observed = _validation_pareto_dimensions(scored.evaluation)
        dominated = False
        for other_index, other in enumerate(feasible):
            if index == other_index:
                continue
            comparison = _validation_pareto_dimensions(other.evaluation)
            if all(
                left <= right
                for left, right in zip(comparison, observed)
            ) and any(
                left < right
                for left, right in zip(comparison, observed)
            ):
                dominated = True
                break
        if not dominated:
            frontier.append(scored)
    return tuple(
        sorted(
            frontier,
            key=lambda scored: validation_objective_key_v2(
                scored.evaluation,
                dict(scored.candidate.physical_candidate_items),
                plan,
            ),
        )
    )


def select_validation_candidate_v2(
    admission: ValidationAdmissionV2,
    scored_candidates: Sequence[ScoredValidationCandidateV2],
    plan: ParsedCalibrationPlanV2,
    *,
    evaluation_failures: Sequence[ValidationEvaluationFailureV2],
) -> ValidationSelectionV2:
    """Require and rank one explicit validation outcome per admitted candidate."""

    _validate_validation_admission(admission, plan)
    admitted_by_sha256 = {
        candidate.candidate_vector_sha256: candidate
        for candidate in admission.admitted_candidates
    }
    if not admitted_by_sha256:
        raise CalibrationSchedulerV2Error("validation admission is empty")
    if type(scored_candidates) not in {tuple, list}:
        raise CalibrationSchedulerV2Error(
            "scored validation candidates must be a concrete sequence"
        )
    if type(evaluation_failures) not in {tuple, list}:
        raise CalibrationSchedulerV2Error(
            "validation evaluation failures must be a concrete sequence"
        )
    snapshot = tuple(scored_candidates)
    scored_sha256 = set()
    for scored in snapshot:
        _validate_scored_validation_candidate(scored, plan)
        candidate_sha256 = scored.candidate.candidate_vector_sha256
        admitted = admitted_by_sha256.get(candidate_sha256)
        if (
            candidate_sha256 in scored_sha256
            or admitted is None
            or not _physical_items_equal(
                scored.candidate.physical_candidate_items,
                admitted.physical_candidate_items,
            )
        ):
            raise CalibrationSchedulerV2Error(
                "scored validation result is duplicated or not development-admitted"
            )
        scored_sha256.add(candidate_sha256)

    failure_snapshot = tuple(evaluation_failures)
    failure_sha256 = set()
    for failure in failure_snapshot:
        _validate_validation_evaluation_failure(failure, plan)
        candidate_sha256 = failure.candidate.candidate_vector_sha256
        admitted = admitted_by_sha256.get(candidate_sha256)
        if (
            candidate_sha256 in failure_sha256
            or candidate_sha256 in scored_sha256
            or admitted is None
            or not _physical_items_equal(
                failure.candidate.physical_candidate_items,
                admitted.physical_candidate_items,
            )
        ):
            raise CalibrationSchedulerV2Error(
                "validation evaluator failure is duplicated, scored, or not admitted"
            )
        failure_sha256.add(candidate_sha256)
    if scored_sha256 | failure_sha256 != set(admitted_by_sha256):
        raise CalibrationSchedulerV2Error(
            "validation outcomes do not exactly cover admitted candidates"
        )

    frontier = validation_pareto_frontier_v2(snapshot, plan)
    selected = min(
        frontier,
        key=lambda scored: validation_objective_key_v2(
            scored.evaluation,
            dict(scored.candidate.physical_candidate_items),
            plan,
        ),
    )
    return ValidationSelectionV2(
        pareto_frontier=frontier,
        evaluation_failures=tuple(
            sorted(
                failure_snapshot,
                key=lambda failure: serialized_candidate_vector_v2(
                    dict(failure.candidate.physical_candidate_items),
                    plan,
                ),
            )
        ),
        selected=selected,
    )
