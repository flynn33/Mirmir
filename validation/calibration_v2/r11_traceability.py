"""Deterministic R11 evidence traceability and claim-boundary contracts.

The module accepts only content identities and closed typed records.  It stores
no timestamps, host paths, or self-referential receipt digest.  Aggregation is a
state-preserving count and hash operation; it never computes an average or a
comparative result.  Product, production-Auto, and market authority remain
blocked independently of any caller-supplied authorization assertion.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import hashlib
import json
import math
import re
from typing import Mapping, Sequence


_SHA256_PATTERN = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")
_GIT_OBJECT_PATTERN = re.compile(
    r"^(?!0{40}$)(?!0{64}$)(?:[0-9a-f]{40}|[0-9a-f]{64})$"
)
_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_MAX_OBSERVATIONS = 1024
_MAX_RECEIPT_BYTES = 8 * 1024 * 1024


class R11TraceabilityError(ValueError):
    """An R11 identity, observation, aggregate, receipt, or claim is invalid."""


class R11IdentityComponent(str, Enum):
    SOURCE = "source"
    SOFTWARE = "software"
    SUBJECT = "subject"
    INPUT = "input"
    PREPROCESSING = "preprocessing"
    TOOLCHAIN = "toolchain"
    EXECUTION = "execution"


R11_IDENTITY_COMPONENT_ORDER = (
    R11IdentityComponent.SOURCE,
    R11IdentityComponent.SOFTWARE,
    R11IdentityComponent.SUBJECT,
    R11IdentityComponent.INPUT,
    R11IdentityComponent.PREPROCESSING,
    R11IdentityComponent.TOOLCHAIN,
    R11IdentityComponent.EXECUTION,
)


class R11ObservationState(str, Enum):
    OBSERVED = "observed"
    NOT_APPLICABLE = "not_applicable"
    NOT_OBSERVED = "not_observed"
    FAILED = "failed"
    ABSENT = "absent"


class R11ObservationReason(str, Enum):
    DECLARED_NOT_APPLICABLE = "declared_not_applicable"
    ENVIRONMENT_UNAVAILABLE = "environment_unavailable"
    HARDWARE_NOT_OBSERVED = "hardware_not_observed"
    SIMULATOR_NOT_OBSERVED = "simulator_not_observed"
    OPERATOR_OBSERVATION_NOT_OBSERVED = (
        "operator_observation_not_observed"
    )
    EXECUTION_FAILED = "execution_failed"
    SOURCE_DATA_ABSENT = "source_data_absent"


R11_NOT_OBSERVED_REASONS = frozenset(
    {
        R11ObservationReason.ENVIRONMENT_UNAVAILABLE,
        R11ObservationReason.HARDWARE_NOT_OBSERVED,
        R11ObservationReason.SIMULATOR_NOT_OBSERVED,
        R11ObservationReason.OPERATOR_OBSERVATION_NOT_OBSERVED,
    }
)


R11_OBSERVATION_STATE_ORDER = (
    R11ObservationState.OBSERVED,
    R11ObservationState.NOT_APPLICABLE,
    R11ObservationState.NOT_OBSERVED,
    R11ObservationState.FAILED,
    R11ObservationState.ABSENT,
)


class R11AggregateState(str, Enum):
    OBSERVED = "observed"
    NOT_APPLICABLE = "not_applicable"
    NOT_OBSERVED = "not_observed"
    FAILED = "failed"
    ABSENT = "absent"
    MIXED = "mixed"


class R11ClaimToken(str, Enum):
    SOFTWARE_BEHAVIOR_REPORT = "software_behavior_report"


class R11ClaimDisposition(str, Enum):
    NO_MARKET_CLAIM = "no_market_claim"


class R11BoundaryState(str, Enum):
    BLOCKED = "blocked"


def canonical_json_bytes_r11(value: object) -> bytes:
    """Return compact canonical JSON and reject non-finite/non-JSON values."""

    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise R11TraceabilityError(
            "value_is_not_canonical_json_encodable"
        ) from error


def canonical_json_file_bytes_r11(value: object) -> bytes:
    return canonical_json_bytes_r11(value) + b"\n"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _semantic_sha256(value: object) -> str:
    return _sha256(canonical_json_bytes_r11(value))


def _require_sha256(value: object, field: str) -> str:
    if type(value) is not str or _SHA256_PATTERN.fullmatch(value) is None:
        raise R11TraceabilityError(f"{field}_must_be_nonzero_lowercase_sha256")
    return value


def _require_git_object(value: object, field: str) -> str:
    if type(value) is not str or _GIT_OBJECT_PATTERN.fullmatch(value) is None:
        raise R11TraceabilityError(
            f"{field}_must_be_nonzero_lowercase_git_object"
        )
    return value


def _require_token(value: object, field: str) -> str:
    if type(value) is not str or _TOKEN_PATTERN.fullmatch(value) is None:
        raise R11TraceabilityError(f"{field}_must_be_one_normalized_token")
    return value


def _require_observed_value(value: object) -> bool | int | float | str:
    if type(value) is bool:
        return value
    if type(value) is int:
        if value < -(2**63) or value > 2**63 - 1:
            raise R11TraceabilityError(
                "observed_integer_value_is_outside_bounds"
            )
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise R11TraceabilityError(
                "observed_value_must_be_finite"
            )
        return value
    if type(value) is str:
        if (
            not value
            or len(value.encode("utf-8")) > 4096
            or value != value.strip()
            or any(ord(character) < 0x20 for character in value)
            or value.startswith("/")
            or re.match(r"^[A-Za-z]:[\\/]", value) is not None
        ):
            raise R11TraceabilityError(
                "observed_string_value_is_outside_boundary"
            )
        return value
    raise R11TraceabilityError(
        "observed_value_must_be_one_canonical_scalar"
    )


def _require_exact_keys(
    value: object,
    expected: frozenset[str],
    field: str,
) -> Mapping[str, object]:
    if type(value) is not dict or set(value) != expected:
        raise R11TraceabilityError(f"{field}_keys_are_not_exact")
    return value


def _require_builtin_count(value: object, field: str) -> int:
    if type(value) is not int or value < 0 or value > _MAX_OBSERVATIONS:
        raise R11TraceabilityError(f"{field}_count_is_outside_bounds")
    return value


def _normalized_field_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")


def _field_is_forbidden(value: str) -> bool:
    normalized = _normalized_field_name(value)
    parts = frozenset(normalized.split("_"))
    if parts.intersection(
        {"comparative", "comparison", "baseline", "winner", "delta", "superiority"}
    ):
        return True
    if normalized in {"ab", "a_b", "ab_test", "a_b_test"}:
        return True
    if "timestamp" in parts or "path" in parts:
        return True
    return normalized in {
        "receipt_sha256",
        "execution_receipt_sha256",
    }


def _reject_forbidden_fields(value: object) -> None:
    pending: list[tuple[object, int]] = [(value, 0)]
    visited = 0
    while pending:
        item, depth = pending.pop()
        visited += 1
        if visited > 16_384 or depth > 64:
            raise R11TraceabilityError("document_structure_exceeds_bound")
        if type(item) is dict:
            for key, child in item.items():
                if type(key) is not str:
                    raise R11TraceabilityError(
                        "document_field_name_has_wrong_type"
                    )
                if _field_is_forbidden(key):
                    raise R11TraceabilityError(
                        f"forbidden_field:{key}"
                    )
                pending.append((child, depth + 1))
        elif type(item) is list:
            pending.extend((child, depth + 1) for child in item)


@dataclass(frozen=True)
class R11SourceIdentity:
    commit: str
    tree: str

    def __post_init__(self) -> None:
        _require_git_object(self.commit, "source_commit")
        _require_git_object(self.tree, "source_tree")

    def to_document(self) -> dict[str, object]:
        return {"commit": self.commit, "tree": self.tree}

    @classmethod
    def from_document(cls, value: object) -> "R11SourceIdentity":
        document = _require_exact_keys(
            value,
            frozenset({"commit", "tree"}),
            "source_identity",
        )
        return cls(commit=document["commit"], tree=document["tree"])


@dataclass(frozen=True)
class R11SoftwareIdentity:
    component_id: str
    implementation_manifest_sha256: str
    contract_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.component_id, "software_component_id")
        _require_sha256(
            self.implementation_manifest_sha256,
            "software_implementation_manifest",
        )
        _require_sha256(self.contract_sha256, "software_contract")

    def to_document(self) -> dict[str, object]:
        return {
            "component_id": self.component_id,
            "implementation_manifest_sha256": (
                self.implementation_manifest_sha256
            ),
            "contract_sha256": self.contract_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11SoftwareIdentity":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "component_id",
                    "implementation_manifest_sha256",
                    "contract_sha256",
                }
            ),
            "software_identity",
        )
        return cls(
            component_id=document["component_id"],
            implementation_manifest_sha256=document[
                "implementation_manifest_sha256"
            ],
            contract_sha256=document["contract_sha256"],
        )


@dataclass(frozen=True)
class R11SubjectIdentity:
    subject_id: str
    subject_kind: str
    behavior_contract_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.subject_id, "subject_id")
        _require_token(self.subject_kind, "subject_kind")
        _require_sha256(
            self.behavior_contract_sha256,
            "subject_behavior_contract",
        )

    def to_document(self) -> dict[str, object]:
        return {
            "subject_id": self.subject_id,
            "subject_kind": self.subject_kind,
            "behavior_contract_sha256": self.behavior_contract_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11SubjectIdentity":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "subject_id",
                    "subject_kind",
                    "behavior_contract_sha256",
                }
            ),
            "subject_identity",
        )
        return cls(
            subject_id=document["subject_id"],
            subject_kind=document["subject_kind"],
            behavior_contract_sha256=document[
                "behavior_contract_sha256"
            ],
        )


@dataclass(frozen=True)
class R11InputIdentity:
    input_id: str
    input_kind: str
    payload_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.input_id, "input_id")
        _require_token(self.input_kind, "input_kind")
        _require_sha256(self.payload_sha256, "input_payload")

    def to_document(self) -> dict[str, object]:
        return {
            "input_id": self.input_id,
            "input_kind": self.input_kind,
            "payload_sha256": self.payload_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11InputIdentity":
        document = _require_exact_keys(
            value,
            frozenset({"input_id", "input_kind", "payload_sha256"}),
            "input_identity",
        )
        return cls(
            input_id=document["input_id"],
            input_kind=document["input_kind"],
            payload_sha256=document["payload_sha256"],
        )


@dataclass(frozen=True)
class R11PreprocessingIdentity:
    pipeline_id: str
    configuration_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.pipeline_id, "preprocessing_pipeline_id")
        _require_sha256(
            self.configuration_sha256,
            "preprocessing_configuration",
        )

    def to_document(self) -> dict[str, object]:
        return {
            "pipeline_id": self.pipeline_id,
            "configuration_sha256": self.configuration_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11PreprocessingIdentity":
        document = _require_exact_keys(
            value,
            frozenset({"pipeline_id", "configuration_sha256"}),
            "preprocessing_identity",
        )
        return cls(
            pipeline_id=document["pipeline_id"],
            configuration_sha256=document["configuration_sha256"],
        )


@dataclass(frozen=True)
class R11ToolchainIdentity:
    platform: str
    architecture: str
    runtime_id: str
    runtime_version: str
    command_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.platform, "toolchain_platform")
        _require_token(self.architecture, "toolchain_architecture")
        _require_token(self.runtime_id, "toolchain_runtime_id")
        _require_token(self.runtime_version, "toolchain_runtime_version")
        _require_sha256(self.command_sha256, "toolchain_command")

    def to_document(self) -> dict[str, object]:
        return {
            "platform": self.platform,
            "architecture": self.architecture,
            "runtime_id": self.runtime_id,
            "runtime_version": self.runtime_version,
            "command_sha256": self.command_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ToolchainIdentity":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "platform",
                    "architecture",
                    "runtime_id",
                    "runtime_version",
                    "command_sha256",
                }
            ),
            "toolchain_identity",
        )
        return cls(
            platform=document["platform"],
            architecture=document["architecture"],
            runtime_id=document["runtime_id"],
            runtime_version=document["runtime_version"],
            command_sha256=document["command_sha256"],
        )


@dataclass(frozen=True)
class R11ExecutionIdentity:
    execution_id: str
    execution_mode: str
    invocation_sha256: str

    def __post_init__(self) -> None:
        _require_token(self.execution_id, "execution_id")
        _require_token(self.execution_mode, "execution_mode")
        _require_sha256(self.invocation_sha256, "execution_invocation")

    def to_document(self) -> dict[str, object]:
        return {
            "execution_id": self.execution_id,
            "execution_mode": self.execution_mode,
            "invocation_sha256": self.invocation_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ExecutionIdentity":
        document = _require_exact_keys(
            value,
            frozenset(
                {"execution_id", "execution_mode", "invocation_sha256"}
            ),
            "execution_identity",
        )
        return cls(
            execution_id=document["execution_id"],
            execution_mode=document["execution_mode"],
            invocation_sha256=document["invocation_sha256"],
        )


@dataclass(frozen=True)
class R11EvidenceIdentity:
    """The exact seven structured identity components and derived root."""

    source: R11SourceIdentity
    software: R11SoftwareIdentity
    subject: R11SubjectIdentity
    input: R11InputIdentity
    preprocessing: R11PreprocessingIdentity
    toolchain: R11ToolchainIdentity
    execution: R11ExecutionIdentity

    def __post_init__(self) -> None:
        expected_types = {
            R11IdentityComponent.SOURCE: R11SourceIdentity,
            R11IdentityComponent.SOFTWARE: R11SoftwareIdentity,
            R11IdentityComponent.SUBJECT: R11SubjectIdentity,
            R11IdentityComponent.INPUT: R11InputIdentity,
            R11IdentityComponent.PREPROCESSING: R11PreprocessingIdentity,
            R11IdentityComponent.TOOLCHAIN: R11ToolchainIdentity,
            R11IdentityComponent.EXECUTION: R11ExecutionIdentity,
        }
        for component in R11_IDENTITY_COMPONENT_ORDER:
            if type(getattr(self, component.value)) is not expected_types[
                component
            ]:
                raise R11TraceabilityError(
                    f"identity_{component.value}_has_wrong_type"
                )

    def _component_document(self) -> dict[str, object]:
        return {
            component.value: getattr(self, component.value).to_document()
            for component in R11_IDENTITY_COMPONENT_ORDER
        }

    def to_document(self) -> dict[str, object]:
        return {
            **self._component_document(),
            "derived_digest_sha256": self.identity_sha256,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11EvidenceIdentity":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    *(
                        component.value
                        for component in R11_IDENTITY_COMPONENT_ORDER
                    ),
                    "derived_digest_sha256",
                }
            ),
            "evidence_identity",
        )
        identity = cls(
            source=R11SourceIdentity.from_document(document["source"]),
            software=R11SoftwareIdentity.from_document(
                document["software"]
            ),
            subject=R11SubjectIdentity.from_document(document["subject"]),
            input=R11InputIdentity.from_document(document["input"]),
            preprocessing=R11PreprocessingIdentity.from_document(
                document["preprocessing"]
            ),
            toolchain=R11ToolchainIdentity.from_document(
                document["toolchain"]
            ),
            execution=R11ExecutionIdentity.from_document(
                document["execution"]
            ),
        )
        _require_sha256(
            document["derived_digest_sha256"],
            "evidence_identity_derived_digest",
        )
        if document["derived_digest_sha256"] != identity.identity_sha256:
            raise R11TraceabilityError(
                "evidence_identity_derived_digest_differs"
            )
        return identity

    @property
    def identity_sha256(self) -> str:
        return _semantic_sha256(self._component_document())


@dataclass(frozen=True)
class R11Observation:
    """One explicit observation or one explicit non-observation state."""

    observation_id: str
    identity: R11EvidenceIdentity
    state: R11ObservationState
    value: bool | int | float | str | None
    reason_code: R11ObservationReason | None
    failure_code: str | None

    def __post_init__(self) -> None:
        _require_token(self.observation_id, "observation_id")
        if type(self.identity) is not R11EvidenceIdentity:
            raise R11TraceabilityError("observation_identity_has_wrong_type")
        if type(self.state) is not R11ObservationState:
            raise R11TraceabilityError("observation_state_has_wrong_type")
        if self.state is R11ObservationState.OBSERVED:
            _require_observed_value(self.value)
            if self.reason_code is not None or self.failure_code is not None:
                raise R11TraceabilityError(
                    "observed_state_forbids_reason_and_failure_codes"
                )
        elif self.state is R11ObservationState.FAILED:
            if (
                self.value is not None
                or self.reason_code
                is not R11ObservationReason.EXECUTION_FAILED
            ):
                raise R11TraceabilityError(
                    "failed_state_requires_exact_reason_and_no_value"
                )
            _require_token(self.failure_code, "observation_failure_code")
        else:
            if self.value is not None or self.failure_code is not None:
                raise R11TraceabilityError(
                    "nonobserved_state_forbids_value_and_failure_code"
                )
            if self.state is R11ObservationState.NOT_APPLICABLE:
                expected_reasons = frozenset(
                    {R11ObservationReason.DECLARED_NOT_APPLICABLE}
                )
            elif self.state is R11ObservationState.ABSENT:
                expected_reasons = frozenset(
                    {R11ObservationReason.SOURCE_DATA_ABSENT}
                )
            else:
                expected_reasons = R11_NOT_OBSERVED_REASONS
            if self.reason_code not in expected_reasons:
                raise R11TraceabilityError(
                    "nonobserved_state_reason_is_not_exact"
                )

    def to_document(self) -> dict[str, object]:
        return {
            "observation_id": self.observation_id,
            "identity": self.identity.to_document(),
            "state": self.state.value,
            "value": self.value,
            "reason_code": (
                None if self.reason_code is None else self.reason_code.value
            ),
            "failure_code": self.failure_code,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11Observation":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "observation_id",
                    "identity",
                    "state",
                    "value",
                    "reason_code",
                    "failure_code",
                }
            ),
            "observation",
        )
        try:
            state = R11ObservationState(document["state"])
            reason = (
                None
                if document["reason_code"] is None
                else R11ObservationReason(document["reason_code"])
            )
        except (TypeError, ValueError) as error:
            raise R11TraceabilityError(
                "observation_state_or_reason_is_not_closed"
            ) from error
        return cls(
            observation_id=document["observation_id"],
            identity=R11EvidenceIdentity.from_document(document["identity"]),
            state=state,
            value=document["value"],
            reason_code=reason,
            failure_code=document["failure_code"],
        )

    @property
    def observation_sha256(self) -> str:
        return _semantic_sha256(self.to_document())


@dataclass(frozen=True)
class R11StateCounts:
    observed: int
    not_applicable: int
    not_observed: int
    failed: int
    absent: int

    def __post_init__(self) -> None:
        for state in R11_OBSERVATION_STATE_ORDER:
            _require_builtin_count(
                getattr(self, state.value),
                f"state_{state.value}",
            )

    @property
    def total(self) -> int:
        return sum(getattr(self, state.value) for state in R11_OBSERVATION_STATE_ORDER)

    def to_document(self) -> dict[str, object]:
        return {
            state.value: getattr(self, state.value)
            for state in R11_OBSERVATION_STATE_ORDER
        }

    @classmethod
    def from_document(cls, value: object) -> "R11StateCounts":
        document = _require_exact_keys(
            value,
            frozenset(state.value for state in R11_OBSERVATION_STATE_ORDER),
            "state_counts",
        )
        return cls(
            **{
                state.value: document[state.value]
                for state in R11_OBSERVATION_STATE_ORDER
            }
        )


@dataclass(frozen=True)
class R11ObservedValue:
    observation_id: str
    value: bool | int | float | str

    def __post_init__(self) -> None:
        _require_token(self.observation_id, "observed_value_observation_id")
        _require_observed_value(self.value)

    def to_document(self) -> dict[str, object]:
        return {
            "observation_id": self.observation_id,
            "value": self.value,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ObservedValue":
        document = _require_exact_keys(
            value,
            frozenset({"observation_id", "value"}),
            "observed_value",
        )
        return cls(
            observation_id=document["observation_id"],
            value=document["value"],
        )


@dataclass(frozen=True)
class R11ObservationAggregate:
    """A deterministic state histogram and ordered observation-hash closure."""

    identity: R11EvidenceIdentity
    expected_observation_ids: tuple[str, ...]
    observation_sha256_values: tuple[str, ...]
    observed_values: tuple[R11ObservedValue, ...]
    state_counts: R11StateCounts
    aggregate_state: R11AggregateState

    def __post_init__(self) -> None:
        if type(self.identity) is not R11EvidenceIdentity:
            raise R11TraceabilityError("aggregate_identity_has_wrong_type")
        if (
            type(self.expected_observation_ids) is not tuple
            or not self.expected_observation_ids
            or len(self.expected_observation_ids) > _MAX_OBSERVATIONS
        ):
            raise R11TraceabilityError(
                "expected_observation_ids_are_outside_bounds"
            )
        for value in self.expected_observation_ids:
            _require_token(value, "expected_observation_id")
        if (
            tuple(sorted(self.expected_observation_ids))
            != self.expected_observation_ids
            or len(set(self.expected_observation_ids))
            != len(self.expected_observation_ids)
        ):
            raise R11TraceabilityError(
                "expected_observation_ids_are_not_unique_canonical_order"
            )
        if (
            type(self.observation_sha256_values) is not tuple
            or len(self.observation_sha256_values)
            != len(self.expected_observation_ids)
        ):
            raise R11TraceabilityError(
                "observation_hash_cardinality_differs"
            )
        for value in self.observation_sha256_values:
            _require_sha256(value, "observation_sha256")
        if (
            type(self.observed_values) is not tuple
            or any(
                type(item) is not R11ObservedValue
                for item in self.observed_values
            )
            or tuple(item.observation_id for item in self.observed_values)
            != tuple(
                sorted(
                    item.observation_id for item in self.observed_values
                )
            )
            or len(
                {
                    item.observation_id
                    for item in self.observed_values
                }
            )
            != len(self.observed_values)
            or any(
                item.observation_id not in self.expected_observation_ids
                for item in self.observed_values
            )
        ):
            raise R11TraceabilityError(
                "observed_values_are_not_one_canonical_subset"
            )
        if type(self.state_counts) is not R11StateCounts:
            raise R11TraceabilityError("state_counts_have_wrong_type")
        if self.state_counts.total != len(self.expected_observation_ids):
            raise R11TraceabilityError("state_counts_cardinality_differs")
        if self.state_counts.observed != len(self.observed_values):
            raise R11TraceabilityError(
                "observed_value_count_differs_from_state_count"
            )
        if type(self.aggregate_state) is not R11AggregateState:
            raise R11TraceabilityError("aggregate_state_has_wrong_type")
        nonzero = [
            state
            for state in R11_OBSERVATION_STATE_ORDER
            if getattr(self.state_counts, state.value) > 0
        ]
        expected_state = (
            R11AggregateState(nonzero[0].value)
            if len(nonzero) == 1
            else R11AggregateState.MIXED
        )
        if self.aggregate_state is not expected_state:
            raise R11TraceabilityError("aggregate_state_differs_from_counts")

    def to_document(self) -> dict[str, object]:
        return {
            "identity": self.identity.to_document(),
            "expected_observation_ids": list(self.expected_observation_ids),
            "observation_sha256_values": list(
                self.observation_sha256_values
            ),
            "observed_values": [
                item.to_document() for item in self.observed_values
            ],
            "state_counts": self.state_counts.to_document(),
            "aggregate_state": self.aggregate_state.value,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ObservationAggregate":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "identity",
                    "expected_observation_ids",
                    "observation_sha256_values",
                    "observed_values",
                    "state_counts",
                    "aggregate_state",
                }
            ),
            "observation_aggregate",
        )
        if (
            type(document["expected_observation_ids"]) is not list
            or type(document["observation_sha256_values"]) is not list
            or type(document["observed_values"]) is not list
        ):
            raise R11TraceabilityError(
                "aggregate_array_fields_have_wrong_type"
            )
        try:
            aggregate_state = R11AggregateState(document["aggregate_state"])
        except (TypeError, ValueError) as error:
            raise R11TraceabilityError(
                "aggregate_state_is_not_closed"
            ) from error
        return cls(
            identity=R11EvidenceIdentity.from_document(document["identity"]),
            expected_observation_ids=tuple(
                document["expected_observation_ids"]
            ),
            observation_sha256_values=tuple(
                document["observation_sha256_values"]
            ),
            observed_values=tuple(
                R11ObservedValue.from_document(item)
                for item in document["observed_values"]
            ),
            state_counts=R11StateCounts.from_document(
                document["state_counts"]
            ),
            aggregate_state=aggregate_state,
        )

    @property
    def aggregate_sha256(self) -> str:
        return _semantic_sha256(self.to_document())


def aggregate_observations_r11(
    *,
    identity: R11EvidenceIdentity,
    expected_observation_ids: tuple[str, ...],
    observations: Sequence[R11Observation],
) -> R11ObservationAggregate:
    """Aggregate an exact declared set without loss, averages, or comparison."""

    if type(identity) is not R11EvidenceIdentity:
        raise R11TraceabilityError("aggregate_identity_has_wrong_type")
    if type(expected_observation_ids) is not tuple:
        raise R11TraceabilityError(
            "expected_observation_ids_must_be_one_tuple"
        )
    if (
        not expected_observation_ids
        or len(expected_observation_ids) > _MAX_OBSERVATIONS
    ):
        raise R11TraceabilityError(
            "expected_observation_ids_are_outside_bounds"
        )
    for value in expected_observation_ids:
        _require_token(value, "expected_observation_id")
    if (
        tuple(sorted(expected_observation_ids)) != expected_observation_ids
        or len(set(expected_observation_ids)) != len(expected_observation_ids)
    ):
        raise R11TraceabilityError(
            "expected_observation_ids_are_not_unique_canonical_order"
        )
    if type(observations) not in {tuple, list}:
        raise R11TraceabilityError("observations_must_be_one_bounded_sequence")
    supplied = tuple(observations)
    if len(supplied) > _MAX_OBSERVATIONS:
        raise R11TraceabilityError("observation_count_exceeds_bound")
    if any(type(item) is not R11Observation for item in supplied):
        raise R11TraceabilityError("observation_has_wrong_type")
    supplied_ids = tuple(item.observation_id for item in supplied)
    if len(set(supplied_ids)) != len(supplied_ids):
        raise R11TraceabilityError("duplicate_observation_id")
    expected_set = set(expected_observation_ids)
    supplied_set = set(supplied_ids)
    if supplied_set - expected_set:
        raise R11TraceabilityError("unexpected_observation_id")
    if expected_set - supplied_set:
        raise R11TraceabilityError("missing_observation_id")
    if any(item.identity != identity for item in supplied):
        raise R11TraceabilityError("observation_identity_mismatch")

    ordered = tuple(sorted(supplied, key=lambda item: item.observation_id))
    counts = {
        state: sum(item.state is state for item in ordered)
        for state in R11_OBSERVATION_STATE_ORDER
    }
    state_counts = R11StateCounts(
        **{state.value: counts[state] for state in R11_OBSERVATION_STATE_ORDER}
    )
    nonzero = [state for state in R11_OBSERVATION_STATE_ORDER if counts[state]]
    aggregate_state = (
        R11AggregateState(nonzero[0].value)
        if len(nonzero) == 1
        else R11AggregateState.MIXED
    )
    return R11ObservationAggregate(
        identity=identity,
        expected_observation_ids=expected_observation_ids,
        observation_sha256_values=tuple(
            item.observation_sha256 for item in ordered
        ),
        observed_values=tuple(
            R11ObservedValue(
                observation_id=item.observation_id,
                value=item.value,
            )
            for item in ordered
            if item.state is R11ObservationState.OBSERVED
        ),
        state_counts=state_counts,
        aggregate_state=aggregate_state,
    )


@dataclass(frozen=True)
class R11AuthorizationAssertion:
    """An untrusted syntactic assertion; it grants no R11 product authority."""

    assertion_id: str
    claimed_scope: str
    claimed_authorized: bool

    def __post_init__(self) -> None:
        _require_token(self.assertion_id, "authorization_assertion_id")
        _require_token(self.claimed_scope, "authorization_claimed_scope")
        if type(self.claimed_authorized) is not bool:
            raise R11TraceabilityError(
                "authorization_claimed_authorized_has_wrong_type"
            )

    def to_document(self) -> dict[str, object]:
        return {
            "assertion_id": self.assertion_id,
            "claimed_scope": self.claimed_scope,
            "claimed_authorized": self.claimed_authorized,
        }


@dataclass(frozen=True)
class R11ClaimDecision:
    requested_claim: str
    permitted_claim: R11ClaimToken | None
    disposition: R11ClaimDisposition
    reason_code: str
    evidence_identity_sha256: str
    aggregate_sha256: str
    product_qualification: R11BoundaryState
    production_auto_mode: R11BoundaryState
    market_position: R11BoundaryState
    market_leading_claim: R11BoundaryState

    def __post_init__(self) -> None:
        _require_token(self.requested_claim, "requested_claim")
        if self.permitted_claim is not None and type(
            self.permitted_claim
        ) is not R11ClaimToken:
            raise R11TraceabilityError("permitted_claim_has_wrong_type")
        if type(self.disposition) is not R11ClaimDisposition:
            raise R11TraceabilityError("claim_disposition_has_wrong_type")
        _require_token(self.reason_code, "claim_reason_code")
        _require_sha256(
            self.evidence_identity_sha256,
            "claim_evidence_identity",
        )
        _require_sha256(self.aggregate_sha256, "claim_aggregate")
        for field in (
            "product_qualification",
            "production_auto_mode",
            "market_position",
            "market_leading_claim",
        ):
            if getattr(self, field) is not R11BoundaryState.BLOCKED:
                raise R11TraceabilityError(f"{field}_must_remain_blocked")
        supported = (
            self.requested_claim
            == R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT.value
        )
        if supported:
            if (
                self.permitted_claim
                is not R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT
                or self.reason_code != "declared_software_behavior_only"
            ):
                raise R11TraceabilityError(
                    "software_behavior_claim_decision_differs"
                )
        elif (
            self.permitted_claim is not None
            or self.reason_code != "unsupported_claim_scope"
        ):
            raise R11TraceabilityError(
                "unsupported_claim_must_fail_closed"
            )
        if self.disposition is not R11ClaimDisposition.NO_MARKET_CLAIM:
            raise R11TraceabilityError(
                "claim_disposition_must_be_no_market_claim"
            )

    def to_document(self) -> dict[str, object]:
        return {
            "requested_claim": self.requested_claim,
            "permitted_claim": (
                None
                if self.permitted_claim is None
                else self.permitted_claim.value
            ),
            "disposition": self.disposition.value,
            "reason_code": self.reason_code,
            "evidence_identity_sha256": self.evidence_identity_sha256,
            "aggregate_sha256": self.aggregate_sha256,
            "product_qualification": self.product_qualification.value,
            "production_auto_mode": self.production_auto_mode.value,
            "market_position": self.market_position.value,
            "market_leading_claim": self.market_leading_claim.value,
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ClaimDecision":
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "requested_claim",
                    "permitted_claim",
                    "disposition",
                    "reason_code",
                    "evidence_identity_sha256",
                    "aggregate_sha256",
                    "product_qualification",
                    "production_auto_mode",
                    "market_position",
                    "market_leading_claim",
                }
            ),
            "claim_decision",
        )
        permitted_value = document["permitted_claim"]
        try:
            permitted = (
                None
                if permitted_value is None
                else R11ClaimToken(permitted_value)
            )
            disposition = R11ClaimDisposition(document["disposition"])
            boundaries = {
                field: R11BoundaryState(document[field])
                for field in (
                    "product_qualification",
                    "production_auto_mode",
                    "market_position",
                    "market_leading_claim",
                )
            }
        except (TypeError, ValueError) as error:
            raise R11TraceabilityError(
                "claim_decision_enum_is_not_closed"
            ) from error
        return cls(
            requested_claim=document["requested_claim"],
            permitted_claim=permitted,
            disposition=disposition,
            reason_code=document["reason_code"],
            evidence_identity_sha256=document["evidence_identity_sha256"],
            aggregate_sha256=document["aggregate_sha256"],
            **boundaries,
        )


def decide_claim_r11(
    *,
    requested_claim: str | R11ClaimToken,
    aggregate: R11ObservationAggregate,
    authorization_assertion: R11AuthorizationAssertion | None = None,
) -> R11ClaimDecision:
    """Permit only a software-behavior report and always deny market authority."""

    if type(aggregate) is not R11ObservationAggregate:
        raise R11TraceabilityError("claim_aggregate_has_wrong_type")
    if authorization_assertion is not None and type(
        authorization_assertion
    ) is not R11AuthorizationAssertion:
        raise R11TraceabilityError(
            "authorization_assertion_has_wrong_type"
        )
    if type(requested_claim) is R11ClaimToken:
        requested = requested_claim.value
    else:
        requested = _require_token(requested_claim, "requested_claim")
    supported = requested == R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT.value
    return R11ClaimDecision(
        requested_claim=requested,
        permitted_claim=(
            R11ClaimToken.SOFTWARE_BEHAVIOR_REPORT if supported else None
        ),
        disposition=R11ClaimDisposition.NO_MARKET_CLAIM,
        reason_code=(
            "declared_software_behavior_only"
            if supported
            else "unsupported_claim_scope"
        ),
        evidence_identity_sha256=aggregate.identity.identity_sha256,
        aggregate_sha256=aggregate.aggregate_sha256,
        product_qualification=R11BoundaryState.BLOCKED,
        production_auto_mode=R11BoundaryState.BLOCKED,
        market_position=R11BoundaryState.BLOCKED,
        market_leading_claim=R11BoundaryState.BLOCKED,
    )


@dataclass(frozen=True)
class R11ExecutionReceipt:
    """A fully recomputable typed receipt with no embedded receipt digest."""

    identity: R11EvidenceIdentity
    observations: tuple[R11Observation, ...]
    aggregate: R11ObservationAggregate
    claim_decision: R11ClaimDecision

    def __post_init__(self) -> None:
        if type(self.identity) is not R11EvidenceIdentity:
            raise R11TraceabilityError("receipt_identity_has_wrong_type")
        if (
            type(self.observations) is not tuple
            or not self.observations
            or len(self.observations) > _MAX_OBSERVATIONS
            or any(type(item) is not R11Observation for item in self.observations)
        ):
            raise R11TraceabilityError(
                "receipt_observations_are_outside_closed_boundary"
            )
        object.__setattr__(
            self,
            "observations",
            tuple(
                sorted(
                    self.observations,
                    key=lambda item: item.observation_id,
                )
            ),
        )
        if type(self.aggregate) is not R11ObservationAggregate:
            raise R11TraceabilityError("receipt_aggregate_has_wrong_type")
        recomputed = aggregate_observations_r11(
            identity=self.identity,
            expected_observation_ids=self.aggregate.expected_observation_ids,
            observations=self.observations,
        )
        if recomputed != self.aggregate:
            raise R11TraceabilityError("receipt_aggregate_recompute_differs")
        if type(self.claim_decision) is not R11ClaimDecision:
            raise R11TraceabilityError("receipt_claim_decision_has_wrong_type")
        expected_decision = decide_claim_r11(
            requested_claim=self.claim_decision.requested_claim,
            aggregate=self.aggregate,
        )
        if expected_decision != self.claim_decision:
            raise R11TraceabilityError(
                "receipt_claim_decision_recompute_differs"
            )

    def to_document(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "phase_id": "R11",
            "artifact_kind": "r11_traceability_execution_receipt",
            "identity": self.identity.to_document(),
            "observations": [
                observation.to_document()
                for observation in sorted(
                    self.observations,
                    key=lambda item: item.observation_id,
                )
            ],
            "aggregate": self.aggregate.to_document(),
            "claim_decision": self.claim_decision.to_document(),
        }

    @classmethod
    def from_document(cls, value: object) -> "R11ExecutionReceipt":
        _reject_forbidden_fields(value)
        document = _require_exact_keys(
            value,
            frozenset(
                {
                    "schema_version",
                    "phase_id",
                    "artifact_kind",
                    "identity",
                    "observations",
                    "aggregate",
                    "claim_decision",
                }
            ),
            "execution_receipt",
        )
        if (
            document["schema_version"] != "1.0.0"
            or document["phase_id"] != "R11"
            or document["artifact_kind"]
            != "r11_traceability_execution_receipt"
            or type(document["observations"]) is not list
        ):
            raise R11TraceabilityError(
                "execution_receipt_header_or_observations_differ"
            )
        return cls(
            identity=R11EvidenceIdentity.from_document(document["identity"]),
            observations=tuple(
                R11Observation.from_document(item)
                for item in document["observations"]
            ),
            aggregate=R11ObservationAggregate.from_document(
                document["aggregate"]
            ),
            claim_decision=R11ClaimDecision.from_document(
                document["claim_decision"]
            ),
        )

    @property
    def receipt_sha256(self) -> str:
        return _sha256(canonical_json_file_bytes_r11(self.to_document()))


def _reject_json_constant(value: str) -> object:
    raise R11TraceabilityError(f"nonfinite_json_constant:{value}")


def _unique_json_object(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise R11TraceabilityError(f"duplicate_json_key:{key}")
        result[key] = value
    return result


def reopen_execution_receipt_r11(
    payload: bytes,
    *,
    expected_sha256: str | None = None,
) -> R11ExecutionReceipt:
    """Boundedly decode canonical bytes and recompute the complete typed receipt."""

    if (
        type(payload) is not bytes
        or not payload
        or len(payload) > _MAX_RECEIPT_BYTES
        or not payload.endswith(b"\n")
        or b"\x00" in payload
        or b"\r" in payload
    ):
        raise R11TraceabilityError(
            "execution_receipt_bytes_are_outside_closed_boundary"
        )
    if expected_sha256 is not None:
        _require_sha256(expected_sha256, "expected_receipt")
        if _sha256(payload) != expected_sha256:
            raise R11TraceabilityError("execution_receipt_sha256_differs")
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise R11TraceabilityError(
            "execution_receipt_json_is_invalid"
        ) from error
    receipt = R11ExecutionReceipt.from_document(value)
    if canonical_json_file_bytes_r11(receipt.to_document()) != payload:
        raise R11TraceabilityError(
            "execution_receipt_bytes_are_not_canonical"
        )
    return receipt
