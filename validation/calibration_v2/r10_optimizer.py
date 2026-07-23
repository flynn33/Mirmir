"""Deterministic bounded optimizer contracts for the R10 fixture-policy slice.

This module is deliberately data- and product-authority-free. Callers supply one
finite tuple of candidates, one declared processing identity, and one immutable
canonical evaluation catalog. This module verifies the catalog bytes against the
declared evaluator hash. A later closure validator remains responsible for
proving that the Git, contract, fixture, and policy-catalog claims correspond to
repository files. Hard constraints are checked before catalog observation. The
resulting checkpoints contain no timestamps or host state, so exact resume can
reproduce the same terminal bytes as uninterrupted execution.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import hashlib
import json
import math
import re
from typing import Callable, Mapping, Sequence, Tuple, Union


_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_GIT_OBJECT_PATTERN = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_ZERO_SHA256 = "0" * 64
_SCORE_MAXIMUM = 65_536


class R10OptimizerError(ValueError):
    """An R10 contract, candidate set, score, or checkpoint is invalid."""


class R10EvaluationMissingError(R10OptimizerError):
    """The bound catalog has no evaluation for a requested candidate."""


class R10EvaluationMismatchError(R10OptimizerError):
    """The bound catalog identifies a different candidate or catalog."""


class R10ConstraintName(str, Enum):
    """The six independently enforced R10 hard-constraint domains."""

    ROUTE = "route"
    PLANE = "plane"
    TEMPORAL = "temporal"
    PROTECTED_REGION = "protected_region"
    RESOURCE = "resource"
    SAFETY = "safety"


R10_CONSTRAINT_ORDER = (
    R10ConstraintName.ROUTE,
    R10ConstraintName.PLANE,
    R10ConstraintName.TEMPORAL,
    R10ConstraintName.PROTECTED_REGION,
    R10ConstraintName.RESOURCE,
    R10ConstraintName.SAFETY,
)


class R10AttemptDisposition(str, Enum):
    REJECTED = "rejected"
    SCORED = "scored"


class R10CheckpointStatus(str, Enum):
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


class R10RunStatus(str, Enum):
    SUCCEEDED = "succeeded"
    CANCELLED = "cancelled"
    FAILED = "failed"


R10Scalar = Union[bool, int, float, str]
R10CancellationCheck = Callable[[], bool]
R10CheckpointSink = Callable[["R10Checkpoint"], object]


def canonical_json_bytes_r10(value: object) -> bytes:
    """Encode deterministic compact JSON while rejecting non-finite numbers."""

    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise R10OptimizerError("R10 value is not canonical-JSON encodable") from error


def canonical_json_file_bytes_r10(value: object) -> bytes:
    return canonical_json_bytes_r10(value) + b"\n"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    return _sha256(canonical_json_bytes_r10(value))


def _require_sha256(value: object, field: str) -> str:
    if type(value) is not str or _SHA256_PATTERN.fullmatch(value) is None:
        raise R10OptimizerError(f"{field} must be one lowercase SHA-256")
    return value


def _require_git_object(value: object, field: str) -> str:
    if type(value) is not str or _GIT_OBJECT_PATTERN.fullmatch(value) is None:
        raise R10OptimizerError(
            f"{field} must be one lowercase 40- or 64-character Git object ID"
        )
    return value


def _require_identity(value: object, field: str) -> str:
    if (
        type(value) is not str
        or not value
        or value != value.strip()
        or any(ord(character) < 0x20 for character in value)
    ):
        raise R10OptimizerError(f"{field} must be a nonempty normalized identity")
    return value


def _require_number(value: object, field: str) -> int | float:
    if type(value) is int:
        return value
    if type(value) is not float or not math.isfinite(value):
        raise R10OptimizerError(f"{field} must be one finite built-in number")
    return value


def _require_scalar(value: object, field: str) -> R10Scalar:
    if type(value) not in {bool, int, float, str}:
        raise R10OptimizerError(f"{field} must be one JSON scalar")
    if type(value) is float and not math.isfinite(value):
        raise R10OptimizerError(f"{field} must be finite")
    if type(value) is str:
        _require_identity(value, field)
    return value


def _require_exact_keys(
    value: object,
    expected: frozenset[str],
    field: str,
) -> Mapping[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        raise R10OptimizerError(f"{field} keys are invalid")
    return value


def _qualified_exception_code(prefix: str, error: Exception) -> str:
    return (
        f"{prefix}:"
        f"{type(error).__module__}.{type(error).__qualname__}"
    )


@dataclass(frozen=True)
class R10ProcessingIdentity:
    """Declared identities; only evaluator bytes are bound in this module.

    A later closure validator must prove the Git/source, independent optimizer
    and persistence contracts, fixture, and policy-catalog fields correspond to
    repository files.
    """

    source_commit: str
    source_tree: str
    optimizer_contract_sha256: str
    persistence_contract_sha256: str
    fixture_catalog_sha256: str
    evaluator_sha256: str
    policy_catalog_sha256: str

    def __post_init__(self) -> None:
        _require_git_object(self.source_commit, "source_commit")
        _require_git_object(self.source_tree, "source_tree")
        _require_sha256(
            self.optimizer_contract_sha256,
            "optimizer_contract_sha256",
        )
        _require_sha256(
            self.persistence_contract_sha256,
            "persistence_contract_sha256",
        )
        _require_sha256(self.fixture_catalog_sha256, "fixture_catalog_sha256")
        _require_sha256(self.evaluator_sha256, "evaluator_sha256")
        _require_sha256(self.policy_catalog_sha256, "policy_catalog_sha256")

    def to_document(self) -> dict[str, object]:
        return {
            "source_commit": self.source_commit,
            "source_tree": self.source_tree,
            "optimizer_contract_sha256": self.optimizer_contract_sha256,
            "persistence_contract_sha256": (
                self.persistence_contract_sha256
            ),
            "fixture_catalog_sha256": self.fixture_catalog_sha256,
            "evaluator_sha256": self.evaluator_sha256,
            "policy_catalog_sha256": self.policy_catalog_sha256,
        }

    @property
    def identity_sha256(self) -> str:
        return _semantic_sha256(self.to_document())


@dataclass(frozen=True)
class R10HardConstraint:
    """One absolute measured value and its independently declared bounds."""

    name: R10ConstraintName
    observed: int | float
    minimum: int | float | None
    maximum: int | float | None

    def __post_init__(self) -> None:
        if type(self.name) is not R10ConstraintName:
            raise R10OptimizerError("constraint name has the wrong type")
        observed = _require_number(self.observed, f"{self.name.value}.observed")
        if self.minimum is None and self.maximum is None:
            raise R10OptimizerError(
                f"{self.name.value} constraint has no declared bound"
            )
        minimum = (
            None
            if self.minimum is None
            else _require_number(self.minimum, f"{self.name.value}.minimum")
        )
        maximum = (
            None
            if self.maximum is None
            else _require_number(self.maximum, f"{self.name.value}.maximum")
        )
        if minimum is not None and maximum is not None and minimum > maximum:
            raise R10OptimizerError(
                f"{self.name.value} constraint bounds are inverted"
            )
        # Preserve exact built-in numeric types after validation.
        object.__setattr__(self, "observed", observed)
        object.__setattr__(self, "minimum", minimum)
        object.__setattr__(self, "maximum", maximum)

    @property
    def satisfied(self) -> bool:
        if self.minimum is not None and self.observed < self.minimum:
            return False
        if self.maximum is not None and self.observed > self.maximum:
            return False
        return True

    def to_document(self) -> dict[str, object]:
        return {
            "name": self.name.value,
            "observed": self.observed,
            "minimum": self.minimum,
            "maximum": self.maximum,
            "satisfied": self.satisfied,
        }


@dataclass(frozen=True)
class R10Candidate:
    """One finite policy candidate over explicitly named causal variables."""

    candidate_id: str
    causal_variables: Tuple[Tuple[str, R10Scalar], ...]
    constraints: Tuple[R10HardConstraint, ...]

    def __post_init__(self) -> None:
        _require_identity(self.candidate_id, "candidate_id")
        if type(self.causal_variables) is not tuple or not self.causal_variables:
            raise R10OptimizerError(
                "candidate causal_variables must be one nonempty tuple"
            )
        normalized_variables: list[tuple[str, R10Scalar]] = []
        names = set()
        for item in self.causal_variables:
            if type(item) is not tuple or len(item) != 2:
                raise R10OptimizerError("candidate causal-variable item is invalid")
            name = _require_identity(item[0], "causal_variable.name")
            if name in names:
                raise R10OptimizerError("candidate causal-variable name repeats")
            names.add(name)
            normalized_variables.append(
                (name, _require_scalar(item[1], f"causal_variable.{name}"))
            )
        normalized_variables.sort(key=lambda item: item[0])
        object.__setattr__(self, "causal_variables", tuple(normalized_variables))

        if type(self.constraints) is not tuple:
            raise R10OptimizerError("candidate constraints must be one tuple")
        by_name: dict[R10ConstraintName, R10HardConstraint] = {}
        for constraint in self.constraints:
            if type(constraint) is not R10HardConstraint:
                raise R10OptimizerError("candidate constraint has the wrong type")
            if constraint.name in by_name:
                raise R10OptimizerError("candidate constraint name repeats")
            by_name[constraint.name] = constraint
        if set(by_name) != set(R10_CONSTRAINT_ORDER):
            raise R10OptimizerError(
                "candidate must contain exactly the six R10 hard constraints"
            )
        object.__setattr__(
            self,
            "constraints",
            tuple(by_name[name] for name in R10_CONSTRAINT_ORDER),
        )

    @property
    def failed_constraints(self) -> Tuple[R10ConstraintName, ...]:
        return tuple(
            constraint.name
            for constraint in self.constraints
            if not constraint.satisfied
        )

    def to_document(self) -> dict[str, object]:
        return {
            "candidate_id": self.candidate_id,
            "causal_variables": {
                name: value for name, value in self.causal_variables
            },
            "constraints": [
                constraint.to_document() for constraint in self.constraints
            ],
        }

    @property
    def canonical_bytes(self) -> bytes:
        return canonical_json_bytes_r10(self.to_document())

    @property
    def candidate_sha256(self) -> str:
        return _sha256(self.canonical_bytes)


@dataclass(frozen=True)
class R10AbsoluteScore:
    """Separate absolute ranking dimensions; no comparison baseline is present."""

    quality_q16: int | float
    temporal_stability_q16: int | float
    protected_region_fidelity_q16: int | float
    resource_efficiency_q16: int | float
    safety_margin_q16: int | float

    def __post_init__(self) -> None:
        for name in (
            "quality_q16",
            "temporal_stability_q16",
            "protected_region_fidelity_q16",
            "resource_efficiency_q16",
            "safety_margin_q16",
        ):
            value = _require_number(getattr(self, name), name)
            if not 0 <= value <= _SCORE_MAXIMUM:
                raise R10OptimizerError(f"{name} is outside the absolute Q16 range")
            object.__setattr__(self, name, value)

    def to_document(self) -> dict[str, object]:
        return {
            "quality_q16": self.quality_q16,
            "temporal_stability_q16": self.temporal_stability_q16,
            "protected_region_fidelity_q16": (
                self.protected_region_fidelity_q16
            ),
            "resource_efficiency_q16": self.resource_efficiency_q16,
            "safety_margin_q16": self.safety_margin_q16,
        }

    def ranking_key(self) -> tuple[object, ...]:
        # Higher is better for every independently named absolute dimension.
        return (
            -self.quality_q16,
            -self.temporal_stability_q16,
            -self.protected_region_fidelity_q16,
            -self.safety_margin_q16,
            -self.resource_efficiency_q16,
        )


@dataclass(frozen=True)
class R10Evaluation:
    """One immutable absolute score bound to one exact candidate identity."""

    candidate_id: str
    candidate_sha256: str
    score: R10AbsoluteScore

    def __post_init__(self) -> None:
        _require_identity(self.candidate_id, "evaluation.candidate_id")
        _require_sha256(
            self.candidate_sha256,
            "evaluation.candidate_sha256",
        )
        if type(self.score) is not R10AbsoluteScore:
            raise R10OptimizerError("evaluation score has the wrong type")

    @classmethod
    def create(
        cls,
        *,
        candidate: R10Candidate,
        score: R10AbsoluteScore,
    ) -> "R10Evaluation":
        if type(candidate) is not R10Candidate:
            raise R10OptimizerError("evaluation candidate has the wrong type")
        return cls(
            candidate_id=candidate.candidate_id,
            candidate_sha256=candidate.candidate_sha256,
            score=score,
        )

    def to_document(self) -> dict[str, object]:
        return {
            "candidate_id": self.candidate_id,
            "candidate_sha256": self.candidate_sha256,
            "score": self.score.to_document(),
        }

    @property
    def canonical_bytes(self) -> bytes:
        return canonical_json_bytes_r10(self.to_document())


def _evaluation_catalog_document(
    evaluations: Tuple[R10Evaluation, ...],
) -> dict[str, object]:
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "r10_absolute_evaluation_catalog",
        "evaluations": [
            evaluation.to_document() for evaluation in evaluations
        ],
    }


@dataclass(frozen=True)
class R10EvaluationCatalog:
    """Canonical score authority; catalog contents cannot execute caller code."""

    evaluations: Tuple[R10Evaluation, ...]

    def __post_init__(self) -> None:
        if type(self.evaluations) is not tuple:
            raise R10OptimizerError("evaluation catalog must be one finite tuple")
        for evaluation in self.evaluations:
            if type(evaluation) is not R10Evaluation:
                raise R10OptimizerError(
                    "evaluation catalog member has the wrong type"
                )
        ordered = tuple(
            sorted(
                self.evaluations,
                key=lambda evaluation: evaluation.canonical_bytes,
            )
        )
        candidate_ids = [
            evaluation.candidate_id for evaluation in ordered
        ]
        candidate_sha256_values = [
            evaluation.candidate_sha256 for evaluation in ordered
        ]
        if len(set(candidate_ids)) != len(candidate_ids):
            raise R10OptimizerError("evaluation candidate ID repeats")
        if len(set(candidate_sha256_values)) != len(
            candidate_sha256_values
        ):
            raise R10OptimizerError("evaluation candidate identity repeats")
        object.__setattr__(self, "evaluations", ordered)

    def to_document(self) -> dict[str, object]:
        return _evaluation_catalog_document(self.evaluations)

    @property
    def canonical_bytes(self) -> bytes:
        return canonical_json_bytes_r10(self.to_document())

    @property
    def evaluator_sha256(self) -> str:
        return _sha256(self.canonical_bytes)

    def score_for(self, candidate: R10Candidate) -> R10AbsoluteScore:
        """Return only a predeclared score for the exact candidate identity."""

        if type(candidate) is not R10Candidate:
            raise R10OptimizerError(
                "evaluation observation candidate has the wrong type"
            )
        for evaluation in self.evaluations:
            if evaluation.candidate_id != candidate.candidate_id:
                continue
            if evaluation.candidate_sha256 != candidate.candidate_sha256:
                raise R10EvaluationMismatchError(
                    "evaluation_candidate_identity_mismatch"
                )
            return evaluation.score
        raise R10EvaluationMissingError("evaluation_missing_for_candidate")


def _attempt_document(
    *,
    ordinal: int,
    previous_attempt_sha256: str,
    candidate: R10Candidate,
    disposition: R10AttemptDisposition,
    rejected_constraints: Tuple[R10ConstraintName, ...],
    score: R10AbsoluteScore | None,
    attempt_sha256: str | None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "ordinal": ordinal,
        "previous_attempt_sha256": previous_attempt_sha256,
        "candidate_sha256": candidate.candidate_sha256,
        "candidate": candidate.to_document(),
        "disposition": disposition.value,
        "rejected_constraints": [
            constraint.value for constraint in rejected_constraints
        ],
        "score": None if score is None else score.to_document(),
    }
    if attempt_sha256 is not None:
        document["attempt_sha256"] = attempt_sha256
    return document


@dataclass(frozen=True)
class R10Attempt:
    ordinal: int
    previous_attempt_sha256: str
    candidate: R10Candidate
    disposition: R10AttemptDisposition
    rejected_constraints: Tuple[R10ConstraintName, ...]
    score: R10AbsoluteScore | None
    attempt_sha256: str

    def __post_init__(self) -> None:
        if type(self.ordinal) is not int or self.ordinal < 0:
            raise R10OptimizerError("attempt ordinal is invalid")
        _require_sha256(
            self.previous_attempt_sha256,
            "previous_attempt_sha256",
        )
        if type(self.candidate) is not R10Candidate:
            raise R10OptimizerError("attempt candidate has the wrong type")
        if type(self.disposition) is not R10AttemptDisposition:
            raise R10OptimizerError("attempt disposition has the wrong type")
        if type(self.rejected_constraints) is not tuple:
            raise R10OptimizerError("attempt rejected_constraints must be one tuple")
        expected_rejections = self.candidate.failed_constraints
        if self.disposition is R10AttemptDisposition.REJECTED:
            if (
                not expected_rejections
                or self.rejected_constraints != expected_rejections
                or self.score is not None
            ):
                raise R10OptimizerError("rejected attempt semantics are invalid")
        elif (
            expected_rejections
            or self.rejected_constraints
            or type(self.score) is not R10AbsoluteScore
        ):
            raise R10OptimizerError("scored attempt semantics are invalid")
        _require_sha256(self.attempt_sha256, "attempt_sha256")
        expected_sha256 = _semantic_sha256(
            _attempt_document(
                ordinal=self.ordinal,
                previous_attempt_sha256=self.previous_attempt_sha256,
                candidate=self.candidate,
                disposition=self.disposition,
                rejected_constraints=self.rejected_constraints,
                score=self.score,
                attempt_sha256=None,
            )
        )
        if self.attempt_sha256 != expected_sha256:
            raise R10OptimizerError("attempt semantic SHA-256 differs")

    @classmethod
    def create(
        cls,
        *,
        ordinal: int,
        previous_attempt_sha256: str,
        candidate: R10Candidate,
        score: R10AbsoluteScore | None,
    ) -> "R10Attempt":
        rejections = candidate.failed_constraints
        disposition = (
            R10AttemptDisposition.REJECTED
            if rejections
            else R10AttemptDisposition.SCORED
        )
        digest = _semantic_sha256(
            _attempt_document(
                ordinal=ordinal,
                previous_attempt_sha256=previous_attempt_sha256,
                candidate=candidate,
                disposition=disposition,
                rejected_constraints=rejections,
                score=score,
                attempt_sha256=None,
            )
        )
        return cls(
            ordinal=ordinal,
            previous_attempt_sha256=previous_attempt_sha256,
            candidate=candidate,
            disposition=disposition,
            rejected_constraints=rejections,
            score=score,
            attempt_sha256=digest,
        )

    def to_document(self) -> dict[str, object]:
        return _attempt_document(
            ordinal=self.ordinal,
            previous_attempt_sha256=self.previous_attempt_sha256,
            candidate=self.candidate,
            disposition=self.disposition,
            rejected_constraints=self.rejected_constraints,
            score=self.score,
            attempt_sha256=self.attempt_sha256,
        )


def _checkpoint_document(
    *,
    processing_identity: R10ProcessingIdentity,
    candidate_set_sha256: str,
    candidate_count: int,
    maximum_candidates: int,
    attempts: Tuple[R10Attempt, ...],
    next_candidate_index: int,
    tail_attempt_sha256: str,
    status: R10CheckpointStatus,
    terminal_code: str | None,
    checkpoint_sha256: str | None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "r10_optimizer_checkpoint",
        "processing_identity": processing_identity.to_document(),
        "processing_identity_sha256": processing_identity.identity_sha256,
        "candidate_set_sha256": candidate_set_sha256,
        "candidate_count": candidate_count,
        "maximum_candidates": maximum_candidates,
        "attempts": [attempt.to_document() for attempt in attempts],
        "next_candidate_index": next_candidate_index,
        "tail_attempt_sha256": tail_attempt_sha256,
        "status": status.value,
        "terminal_code": terminal_code,
    }
    if checkpoint_sha256 is not None:
        document["checkpoint_sha256"] = checkpoint_sha256
    return document


@dataclass(frozen=True)
class R10Checkpoint:
    processing_identity: R10ProcessingIdentity
    candidate_set_sha256: str
    candidate_count: int
    maximum_candidates: int
    attempts: Tuple[R10Attempt, ...]
    next_candidate_index: int
    tail_attempt_sha256: str
    status: R10CheckpointStatus
    terminal_code: str | None
    checkpoint_sha256: str

    def __post_init__(self) -> None:
        if type(self.processing_identity) is not R10ProcessingIdentity:
            raise R10OptimizerError("checkpoint processing identity is invalid")
        _require_sha256(self.candidate_set_sha256, "candidate_set_sha256")
        if (
            type(self.candidate_count) is not int
            or self.candidate_count < 1
            or type(self.maximum_candidates) is not int
            or self.maximum_candidates < self.candidate_count
        ):
            raise R10OptimizerError("checkpoint candidate bounds are invalid")
        if type(self.attempts) is not tuple:
            raise R10OptimizerError("checkpoint attempts must be one tuple")
        if (
            type(self.next_candidate_index) is not int
            or self.next_candidate_index != len(self.attempts)
            or self.next_candidate_index > self.candidate_count
        ):
            raise R10OptimizerError("checkpoint next candidate index is invalid")
        previous = _ZERO_SHA256
        for ordinal, attempt in enumerate(self.attempts):
            if (
                type(attempt) is not R10Attempt
                or attempt.ordinal != ordinal
                or attempt.previous_attempt_sha256 != previous
            ):
                raise R10OptimizerError("checkpoint attempt chain is invalid")
            previous = attempt.attempt_sha256
        attempted_candidates = tuple(
            attempt.candidate for attempt in self.attempts
        )
        ordered_attempted_candidates = tuple(
            sorted(
                attempted_candidates,
                key=lambda candidate: candidate.canonical_bytes,
            )
        )
        if attempted_candidates != ordered_attempted_candidates:
            raise R10OptimizerError(
                "checkpoint attempts differ from canonical candidate order"
            )
        attempted_ids = [
            candidate.candidate_id for candidate in attempted_candidates
        ]
        attempted_sha256_values = [
            candidate.candidate_sha256 for candidate in attempted_candidates
        ]
        if len(set(attempted_ids)) != len(attempted_ids):
            raise R10OptimizerError("checkpoint candidate ID repeats")
        if len(set(attempted_sha256_values)) != len(
            attempted_sha256_values
        ):
            raise R10OptimizerError("checkpoint candidate identity repeats")
        _require_sha256(self.tail_attempt_sha256, "tail_attempt_sha256")
        if self.tail_attempt_sha256 != previous:
            raise R10OptimizerError("checkpoint attempt tail differs")
        if type(self.status) is not R10CheckpointStatus:
            raise R10OptimizerError("checkpoint status has the wrong type")
        if self.status is R10CheckpointStatus.IN_PROGRESS:
            if (
                self.next_candidate_index >= self.candidate_count
                or self.terminal_code is not None
            ):
                raise R10OptimizerError("in-progress checkpoint semantics are invalid")
        elif self.status is R10CheckpointStatus.COMPLETED:
            if (
                self.next_candidate_index != self.candidate_count
                or self.terminal_code is not None
            ):
                raise R10OptimizerError("completed checkpoint semantics are invalid")
            if not any(
                attempt.disposition is R10AttemptDisposition.SCORED
                for attempt in self.attempts
            ):
                raise R10OptimizerError(
                    "completed checkpoint has no scored candidate"
                )
            reconstructed_candidate_set_sha256 = _semantic_sha256(
                [
                    candidate.to_document()
                    for candidate in attempted_candidates
                ]
            )
            if (
                self.candidate_set_sha256
                != reconstructed_candidate_set_sha256
            ):
                raise R10OptimizerError(
                    "completed checkpoint candidate-set SHA-256 differs"
                )
        else:
            _require_identity(self.terminal_code, "terminal_code")
        _require_sha256(self.checkpoint_sha256, "checkpoint_sha256")
        expected = _semantic_sha256(
            _checkpoint_document(
                processing_identity=self.processing_identity,
                candidate_set_sha256=self.candidate_set_sha256,
                candidate_count=self.candidate_count,
                maximum_candidates=self.maximum_candidates,
                attempts=self.attempts,
                next_candidate_index=self.next_candidate_index,
                tail_attempt_sha256=self.tail_attempt_sha256,
                status=self.status,
                terminal_code=self.terminal_code,
                checkpoint_sha256=None,
            )
        )
        if self.checkpoint_sha256 != expected:
            raise R10OptimizerError("checkpoint semantic SHA-256 differs")

    @classmethod
    def create(
        cls,
        *,
        processing_identity: R10ProcessingIdentity,
        candidate_set_sha256: str,
        candidate_count: int,
        maximum_candidates: int,
        attempts: Tuple[R10Attempt, ...],
        status: R10CheckpointStatus,
        terminal_code: str | None = None,
    ) -> "R10Checkpoint":
        tail = _ZERO_SHA256 if not attempts else attempts[-1].attempt_sha256
        document = _checkpoint_document(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            candidate_count=candidate_count,
            maximum_candidates=maximum_candidates,
            attempts=attempts,
            next_candidate_index=len(attempts),
            tail_attempt_sha256=tail,
            status=status,
            terminal_code=terminal_code,
            checkpoint_sha256=None,
        )
        return cls(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            candidate_count=candidate_count,
            maximum_candidates=maximum_candidates,
            attempts=attempts,
            next_candidate_index=len(attempts),
            tail_attempt_sha256=tail,
            status=status,
            terminal_code=terminal_code,
            checkpoint_sha256=_semantic_sha256(document),
        )

    def to_document(self) -> dict[str, object]:
        return _checkpoint_document(
            processing_identity=self.processing_identity,
            candidate_set_sha256=self.candidate_set_sha256,
            candidate_count=self.candidate_count,
            maximum_candidates=self.maximum_candidates,
            attempts=self.attempts,
            next_candidate_index=self.next_candidate_index,
            tail_attempt_sha256=self.tail_attempt_sha256,
            status=self.status,
            terminal_code=self.terminal_code,
            checkpoint_sha256=self.checkpoint_sha256,
        )

    @property
    def canonical_file_bytes(self) -> bytes:
        return canonical_json_file_bytes_r10(self.to_document())


def _selection_document(
    *,
    ranked_candidate_sha256_values: Tuple[str, ...],
    selected_candidate: R10Candidate,
    selected_score: R10AbsoluteScore,
    selection_sha256: str | None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "ranked_candidate_sha256_values": list(
            ranked_candidate_sha256_values
        ),
        "selected_candidate_sha256": selected_candidate.candidate_sha256,
        "selected_candidate": selected_candidate.to_document(),
        "selected_score": selected_score.to_document(),
    }
    if selection_sha256 is not None:
        document["selection_sha256"] = selection_sha256
    return document


@dataclass(frozen=True)
class R10Selection:
    ranked_candidate_sha256_values: Tuple[str, ...]
    selected_candidate: R10Candidate
    selected_score: R10AbsoluteScore
    selection_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.ranked_candidate_sha256_values) is not tuple
            or not self.ranked_candidate_sha256_values
        ):
            raise R10OptimizerError("selection ranking is empty or invalid")
        for value in self.ranked_candidate_sha256_values:
            _require_sha256(value, "ranked_candidate_sha256")
        if len(set(self.ranked_candidate_sha256_values)) != len(
            self.ranked_candidate_sha256_values
        ):
            raise R10OptimizerError("selection ranking repeats a candidate")
        if (
            type(self.selected_candidate) is not R10Candidate
            or type(self.selected_score) is not R10AbsoluteScore
            or self.ranked_candidate_sha256_values[0]
            != self.selected_candidate.candidate_sha256
        ):
            raise R10OptimizerError("selection winner differs from ranking")
        _require_sha256(self.selection_sha256, "selection_sha256")
        expected = _semantic_sha256(
            _selection_document(
                ranked_candidate_sha256_values=(
                    self.ranked_candidate_sha256_values
                ),
                selected_candidate=self.selected_candidate,
                selected_score=self.selected_score,
                selection_sha256=None,
            )
        )
        if self.selection_sha256 != expected:
            raise R10OptimizerError("selection semantic SHA-256 differs")

    @classmethod
    def create(
        cls,
        ranked_attempts: Sequence[R10Attempt],
    ) -> "R10Selection":
        snapshot = tuple(ranked_attempts)
        if not snapshot or any(
            attempt.disposition is not R10AttemptDisposition.SCORED
            or attempt.score is None
            for attempt in snapshot
        ):
            raise R10OptimizerError("selection requires scored attempts")
        winner = snapshot[0]
        assert winner.score is not None
        ranked = tuple(
            attempt.candidate.candidate_sha256 for attempt in snapshot
        )
        document = _selection_document(
            ranked_candidate_sha256_values=ranked,
            selected_candidate=winner.candidate,
            selected_score=winner.score,
            selection_sha256=None,
        )
        return cls(
            ranked_candidate_sha256_values=ranked,
            selected_candidate=winner.candidate,
            selected_score=winner.score,
            selection_sha256=_semantic_sha256(document),
        )

    def to_document(self) -> dict[str, object]:
        return _selection_document(
            ranked_candidate_sha256_values=self.ranked_candidate_sha256_values,
            selected_candidate=self.selected_candidate,
            selected_score=self.selected_score,
            selection_sha256=self.selection_sha256,
        )


@dataclass(frozen=True)
class R10CheckpointReference:
    path: str
    sha256: str
    size_bytes: int
    checkpoint_sha256: str

    def __post_init__(self) -> None:
        _require_identity(self.path, "checkpoint_reference.path")
        if (
            self.path.startswith("/")
            or "\\" in self.path
            or ".." in self.path.split("/")
        ):
            raise R10OptimizerError("checkpoint reference path is unsafe")
        _require_sha256(self.sha256, "checkpoint_reference.sha256")
        _require_sha256(
            self.checkpoint_sha256,
            "checkpoint_reference.checkpoint_sha256",
        )
        if type(self.size_bytes) is not int or self.size_bytes < 1:
            raise R10OptimizerError("checkpoint reference size is invalid")

    def to_document(self) -> dict[str, object]:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "checkpoint_sha256": self.checkpoint_sha256,
        }


def _frozen_policy_document(
    *,
    processing_identity: R10ProcessingIdentity,
    candidate_set_sha256: str,
    selection: R10Selection,
    final_checkpoint: R10CheckpointReference,
    policy_sha256: str | None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "r10_frozen_fixture_policy",
        "processing_identity": processing_identity.to_document(),
        "processing_identity_sha256": processing_identity.identity_sha256,
        "candidate_set_sha256": candidate_set_sha256,
        "selection": selection.to_document(),
        "final_checkpoint": final_checkpoint.to_document(),
        "publication_scope": "deterministic_fixture_policy_only",
        "production_auto_authorized": False,
        "comparative_metrics_used": False,
    }
    if policy_sha256 is not None:
        document["policy_sha256"] = policy_sha256
    return document


@dataclass(frozen=True)
class R10FrozenPolicy:
    processing_identity: R10ProcessingIdentity
    candidate_set_sha256: str
    selection: R10Selection
    final_checkpoint: R10CheckpointReference
    policy_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.processing_identity) is not R10ProcessingIdentity
            or type(self.selection) is not R10Selection
            or type(self.final_checkpoint) is not R10CheckpointReference
        ):
            raise R10OptimizerError("frozen policy typed dependencies are invalid")
        _require_sha256(self.candidate_set_sha256, "candidate_set_sha256")
        _require_sha256(self.policy_sha256, "policy_sha256")
        expected = _semantic_sha256(
            _frozen_policy_document(
                processing_identity=self.processing_identity,
                candidate_set_sha256=self.candidate_set_sha256,
                selection=self.selection,
                final_checkpoint=self.final_checkpoint,
                policy_sha256=None,
            )
        )
        if self.policy_sha256 != expected:
            raise R10OptimizerError("frozen policy semantic SHA-256 differs")

    @classmethod
    def create(
        cls,
        *,
        processing_identity: R10ProcessingIdentity,
        candidate_set_sha256: str,
        selection: R10Selection,
        final_checkpoint: R10CheckpointReference,
    ) -> "R10FrozenPolicy":
        document = _frozen_policy_document(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            selection=selection,
            final_checkpoint=final_checkpoint,
            policy_sha256=None,
        )
        return cls(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            selection=selection,
            final_checkpoint=final_checkpoint,
            policy_sha256=_semantic_sha256(document),
        )

    def to_document(self) -> dict[str, object]:
        return _frozen_policy_document(
            processing_identity=self.processing_identity,
            candidate_set_sha256=self.candidate_set_sha256,
            selection=self.selection,
            final_checkpoint=self.final_checkpoint,
            policy_sha256=self.policy_sha256,
        )

    @property
    def canonical_file_bytes(self) -> bytes:
        return canonical_json_file_bytes_r10(self.to_document())


def _terminal_record_document(
    *,
    processing_identity: R10ProcessingIdentity,
    candidate_set_sha256: str,
    status: R10RunStatus,
    terminal_code: str,
    checkpoint: R10CheckpointReference,
    terminal_record_sha256: str | None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "r10_optimizer_terminal_record",
        "processing_identity": processing_identity.to_document(),
        "processing_identity_sha256": processing_identity.identity_sha256,
        "candidate_set_sha256": candidate_set_sha256,
        "status": status.value,
        "terminal_code": terminal_code,
        "checkpoint": checkpoint.to_document(),
        "frozen_policy_published": False,
    }
    if terminal_record_sha256 is not None:
        document["terminal_record_sha256"] = terminal_record_sha256
    return document


@dataclass(frozen=True)
class R10TerminalRecord:
    processing_identity: R10ProcessingIdentity
    candidate_set_sha256: str
    status: R10RunStatus
    terminal_code: str
    checkpoint: R10CheckpointReference
    terminal_record_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.processing_identity) is not R10ProcessingIdentity
            or type(self.checkpoint) is not R10CheckpointReference
            or self.status not in {R10RunStatus.CANCELLED, R10RunStatus.FAILED}
        ):
            raise R10OptimizerError("terminal record typed fields are invalid")
        _require_sha256(self.candidate_set_sha256, "candidate_set_sha256")
        _require_identity(self.terminal_code, "terminal_code")
        _require_sha256(
            self.terminal_record_sha256,
            "terminal_record_sha256",
        )
        expected = _semantic_sha256(
            _terminal_record_document(
                processing_identity=self.processing_identity,
                candidate_set_sha256=self.candidate_set_sha256,
                status=self.status,
                terminal_code=self.terminal_code,
                checkpoint=self.checkpoint,
                terminal_record_sha256=None,
            )
        )
        if self.terminal_record_sha256 != expected:
            raise R10OptimizerError("terminal record semantic SHA-256 differs")

    @classmethod
    def create(
        cls,
        *,
        processing_identity: R10ProcessingIdentity,
        candidate_set_sha256: str,
        status: R10RunStatus,
        terminal_code: str,
        checkpoint: R10CheckpointReference,
    ) -> "R10TerminalRecord":
        document = _terminal_record_document(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            status=status,
            terminal_code=terminal_code,
            checkpoint=checkpoint,
            terminal_record_sha256=None,
        )
        return cls(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            status=status,
            terminal_code=terminal_code,
            checkpoint=checkpoint,
            terminal_record_sha256=_semantic_sha256(document),
        )

    def to_document(self) -> dict[str, object]:
        return _terminal_record_document(
            processing_identity=self.processing_identity,
            candidate_set_sha256=self.candidate_set_sha256,
            status=self.status,
            terminal_code=self.terminal_code,
            checkpoint=self.checkpoint,
            terminal_record_sha256=self.terminal_record_sha256,
        )

    @property
    def canonical_file_bytes(self) -> bytes:
        return canonical_json_file_bytes_r10(self.to_document())


@dataclass(frozen=True)
class R10RunResult:
    """One terminal run result and its deterministic catalog observations.

    The observation count includes every catalog lookup performed by this
    invocation, including replay of prior scored attempts during resume.
    Structurally rejected attempts never observe the catalog.
    """

    status: R10RunStatus
    checkpoint: R10Checkpoint
    selection: R10Selection | None
    terminal_code: str | None
    evaluation_observation_count: int

    def __post_init__(self) -> None:
        if (
            type(self.status) is not R10RunStatus
            or type(self.checkpoint) is not R10Checkpoint
        ):
            raise R10OptimizerError("run result typed fields are invalid")
        if (
            type(self.evaluation_observation_count) is not int
            or self.evaluation_observation_count < 0
            or self.evaluation_observation_count > self.checkpoint.candidate_count
        ):
            raise R10OptimizerError(
                "run result evaluation observation count is invalid"
            )
        if self.status is R10RunStatus.SUCCEEDED:
            if (
                self.checkpoint.status is not R10CheckpointStatus.COMPLETED
                or type(self.selection) is not R10Selection
                or self.terminal_code is not None
            ):
                raise R10OptimizerError("successful run result is inconsistent")
        else:
            expected_checkpoint_status = (
                R10CheckpointStatus.CANCELLED
                if self.status is R10RunStatus.CANCELLED
                else R10CheckpointStatus.FAILED
            )
            if (
                self.checkpoint.status is not expected_checkpoint_status
                or self.selection is not None
                or self.terminal_code != self.checkpoint.terminal_code
            ):
                raise R10OptimizerError("terminal run result is inconsistent")


def _candidate_set(
    candidates: object,
    maximum_candidates: object,
) -> tuple[Tuple[R10Candidate, ...], str]:
    if type(candidates) is not tuple or not candidates:
        raise R10OptimizerError("candidates must be one nonempty finite tuple")
    if (
        type(maximum_candidates) is not int
        or maximum_candidates < 1
        or len(candidates) > maximum_candidates
    ):
        raise R10OptimizerError("candidate count exceeds its declared finite bound")
    for candidate in candidates:
        if type(candidate) is not R10Candidate:
            raise R10OptimizerError("candidate tuple member has the wrong type")
    ordered = tuple(sorted(candidates, key=lambda candidate: candidate.canonical_bytes))
    candidate_ids = [candidate.candidate_id for candidate in ordered]
    candidate_sha256_values = [
        candidate.candidate_sha256 for candidate in ordered
    ]
    if len(set(candidate_ids)) != len(candidate_ids):
        raise R10OptimizerError("candidate ID repeats")
    if len(set(candidate_sha256_values)) != len(candidate_sha256_values):
        raise R10OptimizerError("candidate identity repeats")
    candidate_set_sha256 = _semantic_sha256(
        [candidate.to_document() for candidate in ordered]
    )
    return ordered, candidate_set_sha256


def _ranked_scored_attempts(
    attempts: Sequence[R10Attempt],
) -> Tuple[R10Attempt, ...]:
    scored = tuple(
        attempt
        for attempt in attempts
        if attempt.disposition is R10AttemptDisposition.SCORED
    )
    return tuple(
        sorted(
            scored,
            key=lambda attempt: (
                attempt.score.ranking_key() if attempt.score is not None else (),
                attempt.candidate.canonical_bytes,
            ),
        )
    )


def _selection_from_attempts(
    attempts: Sequence[R10Attempt],
) -> R10Selection | None:
    ranked = _ranked_scored_attempts(attempts)
    return None if not ranked else R10Selection.create(ranked)


def _validate_resume(
    checkpoint: R10Checkpoint,
    *,
    processing_identity: R10ProcessingIdentity,
    candidates: Tuple[R10Candidate, ...],
    candidate_set_sha256: str,
    maximum_candidates: int,
) -> None:
    if type(checkpoint) is not R10Checkpoint:
        raise R10OptimizerError("resume checkpoint has the wrong type")
    if checkpoint.processing_identity != processing_identity:
        raise R10OptimizerError("resume processing identity differs")
    if (
        checkpoint.candidate_set_sha256 != candidate_set_sha256
        or checkpoint.candidate_count != len(candidates)
        or checkpoint.maximum_candidates != maximum_candidates
    ):
        raise R10OptimizerError("resume candidate-set binding differs")
    if checkpoint.next_candidate_index > len(candidates):
        raise R10OptimizerError("resume candidate index exceeds candidate set")
    for ordinal, attempt in enumerate(checkpoint.attempts):
        if attempt.candidate != candidates[ordinal]:
            raise R10OptimizerError("resume attempt prefix differs from candidate order")
    expected_selection = _selection_from_attempts(checkpoint.attempts)
    if (
        checkpoint.status is R10CheckpointStatus.COMPLETED
        and expected_selection is None
    ):
        raise R10OptimizerError("completed checkpoint has no scored candidate")


def optimize_r10(
    *,
    processing_identity: R10ProcessingIdentity,
    candidates: Tuple[R10Candidate, ...],
    maximum_candidates: int,
    evaluation_catalog: R10EvaluationCatalog,
    resume_checkpoint: R10Checkpoint | None = None,
    cancellation_requested: R10CancellationCheck | None = None,
    checkpoint_sink: R10CheckpointSink | None = None,
) -> R10RunResult:
    """Run or exactly resume one finite, catalog-bound R10 screening pass.

    This verifies the evaluation catalog hash. Repository correspondence for the
    other processing-identity fields remains a later closure-validation duty.
    """

    if type(processing_identity) is not R10ProcessingIdentity:
        raise R10OptimizerError("processing_identity has the wrong type")
    if type(evaluation_catalog) is not R10EvaluationCatalog:
        raise R10OptimizerError("evaluation_catalog has the wrong type")
    if cancellation_requested is not None and not callable(cancellation_requested):
        raise R10OptimizerError("cancellation_requested is not callable")
    if checkpoint_sink is not None and not callable(checkpoint_sink):
        raise R10OptimizerError("checkpoint_sink is not callable")

    ordered_candidates, candidate_set_sha256 = _candidate_set(
        candidates,
        maximum_candidates,
    )
    if resume_checkpoint is None:
        attempts: Tuple[R10Attempt, ...] = ()
    else:
        _validate_resume(
            resume_checkpoint,
            processing_identity=processing_identity,
            candidates=ordered_candidates,
            candidate_set_sha256=candidate_set_sha256,
            maximum_candidates=maximum_candidates,
        )
        attempts = resume_checkpoint.attempts

    def publish(checkpoint: R10Checkpoint) -> None:
        if checkpoint_sink is not None:
            checkpoint_sink(checkpoint)

    evaluation_observation_count = 0

    def fail(terminal_code: str) -> R10RunResult:
        failed_checkpoint = R10Checkpoint.create(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            candidate_count=len(ordered_candidates),
            maximum_candidates=maximum_candidates,
            attempts=attempts,
            status=R10CheckpointStatus.FAILED,
            terminal_code=terminal_code,
        )
        publish(failed_checkpoint)
        return R10RunResult(
            status=R10RunStatus.FAILED,
            checkpoint=failed_checkpoint,
            selection=None,
            terminal_code=terminal_code,
            evaluation_observation_count=evaluation_observation_count,
        )

    if evaluation_catalog.evaluator_sha256 != processing_identity.evaluator_sha256:
        return fail("evaluation_catalog_identity_mismatch")

    def observe_catalog(candidate: R10Candidate) -> R10AbsoluteScore:
        nonlocal evaluation_observation_count
        evaluation_observation_count += 1
        return evaluation_catalog.score_for(candidate)

    if resume_checkpoint is not None:
        for attempt in attempts:
            if attempt.disposition is R10AttemptDisposition.REJECTED:
                continue
            try:
                replayed_score = observe_catalog(attempt.candidate)
            except (
                R10EvaluationMissingError,
                R10EvaluationMismatchError,
            ) as error:
                return fail(str(error))
            assert attempt.score is not None
            if canonical_json_bytes_r10(
                replayed_score.to_document()
            ) != canonical_json_bytes_r10(attempt.score.to_document()):
                return fail("evaluation_score_mismatch")

    if (
        resume_checkpoint is not None
        and resume_checkpoint.status is R10CheckpointStatus.COMPLETED
    ):
        selection = _selection_from_attempts(resume_checkpoint.attempts)
        assert selection is not None
        return R10RunResult(
            status=R10RunStatus.SUCCEEDED,
            checkpoint=resume_checkpoint,
            selection=selection,
            terminal_code=None,
            evaluation_observation_count=evaluation_observation_count,
        )

    if len(attempts) == len(ordered_candidates):
        if (
            resume_checkpoint is not None
            and resume_checkpoint.status is R10CheckpointStatus.FAILED
        ):
            return R10RunResult(
                status=R10RunStatus.FAILED,
                checkpoint=resume_checkpoint,
                selection=None,
                terminal_code=resume_checkpoint.terminal_code,
                evaluation_observation_count=evaluation_observation_count,
            )
        raise R10OptimizerError(
            "terminal resume has no remaining candidate"
        )

    checkpoint = R10Checkpoint.create(
        processing_identity=processing_identity,
        candidate_set_sha256=candidate_set_sha256,
        candidate_count=len(ordered_candidates),
        maximum_candidates=maximum_candidates,
        attempts=attempts,
        status=R10CheckpointStatus.IN_PROGRESS,
    )
    publish(checkpoint)

    for candidate in ordered_candidates[len(attempts) :]:
        cancellation = False
        if cancellation_requested is not None:
            try:
                cancellation_value = cancellation_requested()
            except Exception as error:
                return fail(
                    _qualified_exception_code(
                        "cancellation_check_failure",
                        error,
                    )
                )
            if type(cancellation_value) is not bool:
                return fail("cancellation_check_invalid_result")
            cancellation = cancellation_value
        if cancellation:
            checkpoint = R10Checkpoint.create(
                processing_identity=processing_identity,
                candidate_set_sha256=candidate_set_sha256,
                candidate_count=len(ordered_candidates),
                maximum_candidates=maximum_candidates,
                attempts=attempts,
                status=R10CheckpointStatus.CANCELLED,
                terminal_code="cancellation_requested_between_candidates",
            )
            publish(checkpoint)
            return R10RunResult(
                status=R10RunStatus.CANCELLED,
                checkpoint=checkpoint,
                selection=None,
                terminal_code=checkpoint.terminal_code,
                evaluation_observation_count=evaluation_observation_count,
            )

        failed_constraints = candidate.failed_constraints
        if failed_constraints:
            score = None
        else:
            try:
                score = observe_catalog(candidate)
            except (
                R10EvaluationMissingError,
                R10EvaluationMismatchError,
            ) as error:
                return fail(str(error))

        previous = _ZERO_SHA256 if not attempts else attempts[-1].attempt_sha256
        attempt = R10Attempt.create(
            ordinal=len(attempts),
            previous_attempt_sha256=previous,
            candidate=candidate,
            score=score,
        )
        attempts = (*attempts, attempt)
        if len(attempts) < len(ordered_candidates):
            checkpoint = R10Checkpoint.create(
                processing_identity=processing_identity,
                candidate_set_sha256=candidate_set_sha256,
                candidate_count=len(ordered_candidates),
                maximum_candidates=maximum_candidates,
                attempts=attempts,
                status=R10CheckpointStatus.IN_PROGRESS,
            )
            publish(checkpoint)

    selection = _selection_from_attempts(attempts)
    if selection is None:
        checkpoint = R10Checkpoint.create(
            processing_identity=processing_identity,
            candidate_set_sha256=candidate_set_sha256,
            candidate_count=len(ordered_candidates),
            maximum_candidates=maximum_candidates,
            attempts=attempts,
            status=R10CheckpointStatus.FAILED,
            terminal_code="no_constraint_valid_scored_candidate",
        )
        publish(checkpoint)
        return R10RunResult(
            status=R10RunStatus.FAILED,
            checkpoint=checkpoint,
            selection=None,
            terminal_code=checkpoint.terminal_code,
            evaluation_observation_count=evaluation_observation_count,
        )

    checkpoint = R10Checkpoint.create(
        processing_identity=processing_identity,
        candidate_set_sha256=candidate_set_sha256,
        candidate_count=len(ordered_candidates),
        maximum_candidates=maximum_candidates,
        attempts=attempts,
        status=R10CheckpointStatus.COMPLETED,
    )
    publish(checkpoint)
    return R10RunResult(
        status=R10RunStatus.SUCCEEDED,
        checkpoint=checkpoint,
        selection=selection,
        terminal_code=None,
        evaluation_observation_count=evaluation_observation_count,
    )


def _processing_identity_from_document(
    value: object,
) -> R10ProcessingIdentity:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "source_commit",
                "source_tree",
                "optimizer_contract_sha256",
                "persistence_contract_sha256",
                "fixture_catalog_sha256",
                "evaluator_sha256",
                "policy_catalog_sha256",
            }
        ),
        "processing_identity",
    )
    return R10ProcessingIdentity(
        source_commit=document["source_commit"],
        source_tree=document["source_tree"],
        optimizer_contract_sha256=document["optimizer_contract_sha256"],
        persistence_contract_sha256=document[
            "persistence_contract_sha256"
        ],
        fixture_catalog_sha256=document["fixture_catalog_sha256"],
        evaluator_sha256=document["evaluator_sha256"],
        policy_catalog_sha256=document["policy_catalog_sha256"],
    )


def _constraint_from_document(value: object) -> R10HardConstraint:
    document = _require_exact_keys(
        value,
        frozenset({"name", "observed", "minimum", "maximum", "satisfied"}),
        "constraint",
    )
    try:
        name = R10ConstraintName(document["name"])
    except (TypeError, ValueError) as error:
        raise R10OptimizerError("constraint name is invalid") from error
    constraint = R10HardConstraint(
        name=name,
        observed=document["observed"],
        minimum=document["minimum"],
        maximum=document["maximum"],
    )
    if type(document["satisfied"]) is not bool or (
        document["satisfied"] != constraint.satisfied
    ):
        raise R10OptimizerError("constraint satisfaction field differs")
    return constraint


def _candidate_from_document(value: object) -> R10Candidate:
    document = _require_exact_keys(
        value,
        frozenset({"candidate_id", "causal_variables", "constraints"}),
        "candidate",
    )
    variables = document["causal_variables"]
    constraints = document["constraints"]
    if not isinstance(variables, dict) or not isinstance(constraints, list):
        raise R10OptimizerError("candidate document collections are invalid")
    return R10Candidate(
        candidate_id=document["candidate_id"],
        causal_variables=tuple(variables.items()),
        constraints=tuple(
            _constraint_from_document(constraint) for constraint in constraints
        ),
    )


def _score_from_document(value: object) -> R10AbsoluteScore:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "quality_q16",
                "temporal_stability_q16",
                "protected_region_fidelity_q16",
                "resource_efficiency_q16",
                "safety_margin_q16",
            }
        ),
        "score",
    )
    return R10AbsoluteScore(
        quality_q16=document["quality_q16"],
        temporal_stability_q16=document["temporal_stability_q16"],
        protected_region_fidelity_q16=document[
            "protected_region_fidelity_q16"
        ],
        resource_efficiency_q16=document["resource_efficiency_q16"],
        safety_margin_q16=document["safety_margin_q16"],
    )


def _attempt_from_document(value: object) -> R10Attempt:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "ordinal",
                "previous_attempt_sha256",
                "candidate_sha256",
                "candidate",
                "disposition",
                "rejected_constraints",
                "score",
                "attempt_sha256",
            }
        ),
        "attempt",
    )
    candidate = _candidate_from_document(document["candidate"])
    if document["candidate_sha256"] != candidate.candidate_sha256:
        raise R10OptimizerError("attempt candidate SHA-256 differs")
    try:
        disposition = R10AttemptDisposition(document["disposition"])
        rejected_constraints = tuple(
            R10ConstraintName(name)
            for name in document["rejected_constraints"]
        )
    except (TypeError, ValueError) as error:
        raise R10OptimizerError("attempt enum fields are invalid") from error
    score_value = document["score"]
    return R10Attempt(
        ordinal=document["ordinal"],
        previous_attempt_sha256=document["previous_attempt_sha256"],
        candidate=candidate,
        disposition=disposition,
        rejected_constraints=rejected_constraints,
        score=None if score_value is None else _score_from_document(score_value),
        attempt_sha256=document["attempt_sha256"],
    )


def checkpoint_from_document_r10(value: object) -> R10Checkpoint:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "schema_version",
                "artifact_kind",
                "processing_identity",
                "processing_identity_sha256",
                "candidate_set_sha256",
                "candidate_count",
                "maximum_candidates",
                "attempts",
                "next_candidate_index",
                "tail_attempt_sha256",
                "status",
                "terminal_code",
                "checkpoint_sha256",
            }
        ),
        "checkpoint",
    )
    if (
        document["schema_version"] != "1.0.0"
        or document["artifact_kind"] != "r10_optimizer_checkpoint"
        or not isinstance(document["attempts"], list)
    ):
        raise R10OptimizerError("checkpoint document header is invalid")
    identity = _processing_identity_from_document(
        document["processing_identity"]
    )
    if document["processing_identity_sha256"] != identity.identity_sha256:
        raise R10OptimizerError("checkpoint processing identity SHA-256 differs")
    try:
        status = R10CheckpointStatus(document["status"])
    except (TypeError, ValueError) as error:
        raise R10OptimizerError("checkpoint status is invalid") from error
    return R10Checkpoint(
        processing_identity=identity,
        candidate_set_sha256=document["candidate_set_sha256"],
        candidate_count=document["candidate_count"],
        maximum_candidates=document["maximum_candidates"],
        attempts=tuple(
            _attempt_from_document(attempt)
            for attempt in document["attempts"]
        ),
        next_candidate_index=document["next_candidate_index"],
        tail_attempt_sha256=document["tail_attempt_sha256"],
        status=status,
        terminal_code=document["terminal_code"],
        checkpoint_sha256=document["checkpoint_sha256"],
    )


def _selection_from_document(value: object) -> R10Selection:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "ranked_candidate_sha256_values",
                "selected_candidate_sha256",
                "selected_candidate",
                "selected_score",
                "selection_sha256",
            }
        ),
        "selection",
    )
    ranked = document["ranked_candidate_sha256_values"]
    if not isinstance(ranked, list):
        raise R10OptimizerError("selection ranking document is invalid")
    candidate = _candidate_from_document(document["selected_candidate"])
    if document["selected_candidate_sha256"] != candidate.candidate_sha256:
        raise R10OptimizerError("selection candidate SHA-256 differs")
    return R10Selection(
        ranked_candidate_sha256_values=tuple(ranked),
        selected_candidate=candidate,
        selected_score=_score_from_document(document["selected_score"]),
        selection_sha256=document["selection_sha256"],
    )


def _checkpoint_reference_from_document(
    value: object,
) -> R10CheckpointReference:
    document = _require_exact_keys(
        value,
        frozenset({"path", "sha256", "size_bytes", "checkpoint_sha256"}),
        "checkpoint_reference",
    )
    return R10CheckpointReference(
        path=document["path"],
        sha256=document["sha256"],
        size_bytes=document["size_bytes"],
        checkpoint_sha256=document["checkpoint_sha256"],
    )


def frozen_policy_from_document_r10(value: object) -> R10FrozenPolicy:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "schema_version",
                "artifact_kind",
                "processing_identity",
                "processing_identity_sha256",
                "candidate_set_sha256",
                "selection",
                "final_checkpoint",
                "publication_scope",
                "production_auto_authorized",
                "comparative_metrics_used",
                "policy_sha256",
            }
        ),
        "frozen_policy",
    )
    if (
        document["schema_version"] != "1.0.0"
        or document["artifact_kind"] != "r10_frozen_fixture_policy"
        or document["publication_scope"]
        != "deterministic_fixture_policy_only"
        or document["production_auto_authorized"] is not False
        or document["comparative_metrics_used"] is not False
    ):
        raise R10OptimizerError("frozen policy boundary fields are invalid")
    identity = _processing_identity_from_document(
        document["processing_identity"]
    )
    if document["processing_identity_sha256"] != identity.identity_sha256:
        raise R10OptimizerError("policy processing identity SHA-256 differs")
    return R10FrozenPolicy(
        processing_identity=identity,
        candidate_set_sha256=document["candidate_set_sha256"],
        selection=_selection_from_document(document["selection"]),
        final_checkpoint=_checkpoint_reference_from_document(
            document["final_checkpoint"]
        ),
        policy_sha256=document["policy_sha256"],
    )


def terminal_record_from_document_r10(value: object) -> R10TerminalRecord:
    document = _require_exact_keys(
        value,
        frozenset(
            {
                "schema_version",
                "artifact_kind",
                "processing_identity",
                "processing_identity_sha256",
                "candidate_set_sha256",
                "status",
                "terminal_code",
                "checkpoint",
                "frozen_policy_published",
                "terminal_record_sha256",
            }
        ),
        "terminal_record",
    )
    if (
        document["schema_version"] != "1.0.0"
        or document["artifact_kind"] != "r10_optimizer_terminal_record"
        or document["frozen_policy_published"] is not False
    ):
        raise R10OptimizerError("terminal record boundary fields are invalid")
    identity = _processing_identity_from_document(
        document["processing_identity"]
    )
    if document["processing_identity_sha256"] != identity.identity_sha256:
        raise R10OptimizerError(
            "terminal processing identity SHA-256 differs"
        )
    try:
        status = R10RunStatus(document["status"])
    except (TypeError, ValueError) as error:
        raise R10OptimizerError("terminal record status is invalid") from error
    return R10TerminalRecord(
        processing_identity=identity,
        candidate_set_sha256=document["candidate_set_sha256"],
        status=status,
        terminal_code=document["terminal_code"],
        checkpoint=_checkpoint_reference_from_document(document["checkpoint"]),
        terminal_record_sha256=document["terminal_record_sha256"],
    )
