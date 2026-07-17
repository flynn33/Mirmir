"""Authenticated byte persistence for the P06 calibration scheduler V2.

The scheduler owns search semantics.  This adapter owns the byte boundary:
schema and authority authentication, strict JSON decoding, immutable artifact
publication, candidate reconstruction, evaluation reopening, NDJSON decoding,
and run-ledger cross-reference verification.
"""

from __future__ import annotations

import asyncio
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
from functools import wraps
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import secrets
import stat
import threading
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple
import weakref

import jsonschema

from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureCaptureV2,
    AuthenticatedClosureSnapshotV2,
    AuthenticatedClosureSnapshotV2Error,
    ClosureFileBindingV2,
    ClosureFileSnapshotV2,
)
from validation.calibration_v2.baseline_ablation_budget_v2 import (
    BaselineAblationBudgetV2Error,
    NonAshSelectorExecutionProfileV2,
    parse_baseline_ablation_budget_v2,
)
from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    ParsedCalibrationPlanV2,
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    shared_bank_configuration_sha256_v2,
    validate_materialized_candidate_identity_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    ATTEMPT_STATUS_CONSTRAINT_FAILURE,
    ATTEMPT_STATUS_EVALUATION_FAILURE,
    ATTEMPT_STATUS_FEASIBLE,
    ATTEMPT_STATUS_INFEASIBLE,
    DEVELOPMENT_SPLIT,
    STATUS_TERMINATED_FEASIBLE,
    ArtifactBindingV2,
    AttemptRecordV2,
    CalibrationSchedulerV2Error,
    DevelopmentEvaluationV2,
    DevelopmentSearchResultV2,
    EvaluationCacheIdentityV2,
    attempt_record_sha256_v2,
    canonical_development_failure_reasons_v2,
    replay_development_attempts_v2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    ControlAuthorizationScopeV2,
    ControlAuthorizationV2Error,
    TypedArtifactBindingV2,
    authenticate_control_execution_producer_identity_authority_v2,
    schema_sha256_for_kind_v2,
    verify_control_authorization_bundle_v2,
)
from validation.calibration_v2.non_ash_selector_artifacts_v2 import (
    SELECTION_KIND as NON_ASH_SELECTION_KIND,
)
from validation.calibration_v2.non_ash_selector_v2 import (
    NonAshSelectorEvaluationScopeV2,
    NonAshSelectorV2Error,
)
from validation.calibration_v2.production_evaluator import (
    ControlExecutionProducerIdentityV2,
    ControlExecutionSemanticContextV2,
    ControlWriterProducerIdentityV2,
    ControlWriterSemanticContextV2,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]

_ZERO_SHA256 = "0" * 64
_PLAN_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
_ATTEMPT_RECORD_DOMAIN = (
    "mirmir-p06-calibration-scheduler-v2-semantic-attempt-v1"
)

_SCHEMA_SPECS = {
    "candidate-evaluation-v2": (
        "schemas/candidate-evaluation-v2.schema.json",
        "f05c6a084a3b994edeb38a0097f052e0dcf6e7c09e3af025cc185a74d1ee772b",
    ),
    "calibration-attempt-record-v2": (
        "schemas/calibration-attempt-record-v2.schema.json",
        "06e329fbbaedbb73afa5ba9649c2b8748a55b196d9dfa1a8bc709a156a86d51e",
    ),
    "calibration-run-ledger-v2": (
        "schemas/calibration-run-ledger-v2.schema.json",
        "aedee1f38d0b894353594414949fb33a428d4e9d8d64405b9656f1e62377d29b",
    ),
    "p06-calibration-failure-v2": (
        "schemas/p06-calibration-failure-v2.schema.json",
        "db99e3fef12167c63c271049f6c9ea6abc1834df4289700e27d9653bf12d284b",
    ),
    "fixed-control-selection-v1": (
        "schemas/fixed-control-selection-v1.schema.json",
        "646919f448ffd335e3fa168a392944c41e9c9a9403a3b523273f0fceb01439ba",
    ),
    "conventional-control-selection-v1": (
        "schemas/conventional-control-selection-v1.schema.json",
        "6c299f1c2ed4a9493bd2d5b17958ca59ca1dca20b2195fa2a7fe6aba79d83069",
    ),
    "non-ash-selector-selection-v2": (
        "schemas/non-ash-selector-selection-v2.schema.json",
        "d5cfa23e51a440887c2cc50ef2816eff1e228c1fab6eb86e66ee73a849a85fa9",
    ),
    "evidence-wrapper-artifact-manifest-v2": (
        "schemas/evidence-wrapper-artifact-manifest-v2.schema.json",
        "5f269b4df8c0872f5ab4132478feb5464d56348929df55cc27fabe3e4520af5f",
    ),
}

_CONTROL_SELECTION_SPECS = (
    (
        "best_fixed",
        "p06_fixed_control_selection",
        "fixed-control-selection-v1",
    ),
    (
        "conventional",
        "p06_conventional_control_selection",
        "conventional-control-selection-v1",
    ),
    (
        "non_ash_selector",
        "p06_non_ash_selector_selection_v2",
        "non-ash-selector-selection-v2",
    ),
)
_EXACT_FORMATTED_SCHEMA_NAMES = frozenset(
    {
        "fixed-control-selection-v1",
        "conventional-control-selection-v1",
        "non-ash-selector-selection-v2",
        "evidence-wrapper-artifact-manifest-v2",
    }
)

_AUTHORITY_SPECS = {
    "baseline_ablation_budget_v2": {
        "path": "validation/calibration_v2/contracts/baseline-ablation-budget-v2.json",
        "schema_path": "validation/calibration_v2/schemas/baseline-ablation-budget-v2.schema.json",
        "file_sha256": "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8",
        "schema_file_sha256": "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b",
        "self_field": "artifact_sha256",
        "self_sha256": "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be",
    },
    "calibration_plan_v2": {
        "path": "validation/calibration_v2/contracts/calibration-plan-v2.json",
        "schema_path": "validation/calibration_v2/schemas/calibration-plan-v2.schema.json",
        "file_sha256": "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef",
        "schema_file_sha256": "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09",
        "self_field": "plan_sha256",
        "self_sha256": "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f",
    },
    "candidate_evidence_policy_v2": {
        "path": "validation/calibration_v2/contracts/candidate-evidence-policy-v2.json",
        "schema_path": "validation/calibration_v2/schemas/candidate-evidence-policy-v2.schema.json",
        "file_sha256": "d6df835467485f59b253e12d8e80cb8c8fa21dd308566ab3634495ccc8604433",
        "schema_file_sha256": "581a3bb6ba0ec3ea288076685124a9e7fd332aa883ee2165f18a27a4fb1c249e",
        "self_field": "artifact_sha256",
        "self_sha256": "70860c19f36efe41401e16381c80d6102b37f683056b2e3210a67e9d0b66dc75",
    },
    "compiler_contract_v2": {
        "path": "validation/calibration_v2/contracts/compiler-contract-v2.json",
        "schema_path": "validation/calibration_v2/schemas/compiler-contract-v2.schema.json",
        "file_sha256": "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a",
        "schema_file_sha256": "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897",
        "self_field": "artifact_sha256",
        "self_sha256": "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237",
    },
    "control_execution_producer_identity_v2": {
        "path": "validation/calibration_v2/contracts/control-execution-producer-identity-v2.json",
        "schema_path": "validation/calibration_v2/schemas/control-execution-producer-identity-v2.schema.json",
        "file_sha256": "9de7970c089e3ef6627a81c5e8a23c29e3ca7567b8d868058de52108b53a5363",
        "schema_file_sha256": "99032fc9490d5b41f2e9793ab99fb8d9cda2b5d6cd0ff7f9b367c6f4b2d96c46",
        "self_field": "artifact_sha256",
        "self_sha256": "dc76d231d0b90a663153678b5651da9eead185eee622897c89e30951603f40f5",
    },
    "shared_bank_configuration_identity_v2": {
        "path": "validation/calibration_v2/contracts/shared-bank-configuration-identity-v2.json",
        "schema_path": "validation/calibration_v2/schemas/shared-bank-configuration-identity-v2.schema.json",
        "file_sha256": "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de",
        "schema_file_sha256": "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c",
        "self_field": "artifact_sha256",
        "self_sha256": "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37",
    },
}

_SAFE_RELATIVE_PATH_CHARACTERS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-"
)
_ARTIFACT_STORE_LOCK_REGISTRY_GUARD = threading.Lock()
_ARTIFACT_STORE_LOCK_REGISTRY = weakref.WeakValueDictionary()


class CalibrationPersistenceV2Error(ValueError):
    """A persisted P06 V2 byte, reference, or semantic relation is invalid."""


def _authenticated_calibration_replay(function):
    """Run one pure-read replay inside a shared authenticated closure."""

    @wraps(function)
    def wrapped(self, *args, **kwargs):
        with self._store.authenticated_closure():
            return function(self, *args, **kwargs)

    return wrapped


@dataclass(frozen=True)
class AttemptLedgerBindingV2:
    path: str
    sha256: str
    size_bytes: int
    record_count: int
    last_record_sha256: str

    def __post_init__(self) -> None:
        if (
            type(self.path) is not str
            or self.path != "attempts-v2.ndjson"
            or not _is_sha256(self.sha256, nonzero=True)
            or type(self.size_bytes) is not int
            or self.size_bytes < 1
            or type(self.record_count) is not int
            or not 1 <= self.record_count <= 3288
            or not _is_sha256(self.last_record_sha256, nonzero=True)
        ):
            raise CalibrationPersistenceV2Error(
                "attempt-ledger binding is invalid"
            )


@dataclass(frozen=True)
class FileBindingV2:
    path: str
    sha256: str
    size_bytes: int

    def __post_init__(self) -> None:
        if (
            type(self.path) is not str
            or not self.path
            or self.path.startswith("/")
            or "\\" in self.path
            or any(
                character not in _SAFE_RELATIVE_PATH_CHARACTERS
                for character in self.path
            )
            or any(part in {"", ".", ".."} for part in self.path.split("/"))
            or not _is_sha256(self.sha256, nonzero=True)
            or type(self.size_bytes) is not int
            or self.size_bytes < 1
        ):
            raise CalibrationPersistenceV2Error("file binding is invalid")


@dataclass(frozen=True)
class VerifiedCandidateEvaluationV2:
    binding: ArtifactBindingV2
    document: Mapping[str, object]
    run_id: str
    split: str
    candidate_vector_sha256: str
    adapter_configuration_sha256: str
    physical_candidate_items: Tuple[Tuple[str, object], ...]
    shared_bank_configuration_sha256: str
    evaluation_semantic_sha256: str
    control_authorization_bundle_binding: TypedArtifactBindingV2
    control_dependency_bindings: Tuple[TypedArtifactBindingV2, ...]
    development_evaluation: Optional[DevelopmentEvaluationV2]


@dataclass(frozen=True)
class _VerifiedCandidateControlClosureV2:
    bundle_binding: TypedArtifactBindingV2
    dependency_bindings: Tuple[TypedArtifactBindingV2, ...]


@dataclass(frozen=True)
class CandidateControlProducerRequestV2:
    """One candidate's immutable control-replay producer request."""

    evidence_snapshot: AuthenticatedClosureSnapshotV2
    bundle_binding: TypedArtifactBindingV2
    dependency_bindings: Tuple[TypedArtifactBindingV2, ...]
    physical_candidate_items_bytes: bytes
    candidate_vector_sha256: str
    authorization_scope: ControlAuthorizationScopeV2
    non_ash_evaluation_scope: NonAshSelectorEvaluationScopeV2


@dataclass(frozen=True)
class CandidateControlProducerCapabilitiesV2:
    """Trusted producer capabilities bound to one exact request object."""

    request: CandidateControlProducerRequestV2
    control_execution_semantic_verifier: Callable[
        [
            TypedArtifactBindingV2,
            Mapping[str, object],
            ControlExecutionSemanticContextV2,
        ],
        Mapping[str, object],
    ]
    control_execution_producer_identity: ControlExecutionProducerIdentityV2
    control_writer_semantic_verifier: Optional[
        Callable[
            [
                TypedArtifactBindingV2,
                Mapping[str, object],
                ControlWriterSemanticContextV2,
            ],
            Mapping[str, object],
        ]
    ] = None
    control_writer_producer_identity: Optional[
        ControlWriterProducerIdentityV2
    ] = None

    def __post_init__(self) -> None:
        if (
            type(self.request) is not CandidateControlProducerRequestV2
            or not callable(self.control_execution_semantic_verifier)
            or type(self.control_execution_producer_identity)
            is not ControlExecutionProducerIdentityV2
            or (
                self.control_writer_semantic_verifier is None
                and self.control_writer_producer_identity is not None
            )
            or (
                self.control_writer_semantic_verifier is not None
                and (
                    not callable(self.control_writer_semantic_verifier)
                    or type(self.control_writer_producer_identity)
                    is not ControlWriterProducerIdentityV2
                )
            )
        ):
            raise CalibrationPersistenceV2Error(
                "candidate control producer capabilities are invalid"
            )


@dataclass(frozen=True)
class VerifiedAttemptLedgerV2:
    binding: AttemptLedgerBindingV2
    documents: Tuple[Mapping[str, object], ...]
    records: Tuple[AttemptRecordV2, ...]
    replay: DevelopmentSearchResultV2


@dataclass(frozen=True)
class VerifiedRunLedgerV2:
    binding: Optional[FileBindingV2]
    document: Mapping[str, object]
    attempt_ledger: VerifiedAttemptLedgerV2
    candidate_evaluations: Tuple[VerifiedCandidateEvaluationV2, ...]
    candidate_failures: Tuple[Mapping[str, object], ...]


def _is_sha256(value: object, *, nonzero: bool = False) -> bool:
    return (
        type(value) is str
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
        and (not nonzero or value != _ZERO_SHA256)
    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CalibrationPersistenceV2Error(
                f"duplicate JSON member: {key}"
            )
        result[key] = value
    return result


def _reject_nonfinite(token: str) -> object:
    raise CalibrationPersistenceV2Error(f"non-finite JSON value: {token}")


def _snapshot_json(value: object, *, label: str) -> object:
    active: set[int] = set()

    def visit(item: object, location: str) -> object:
        item_type = type(item)
        if item is None or item_type in {str, bool, int}:
            return item
        if item_type is float:
            if not math.isfinite(item):
                raise CalibrationPersistenceV2Error(
                    f"{label} contains a non-finite value at {location}"
                )
            return item
        if item_type not in {dict, list}:
            raise CalibrationPersistenceV2Error(
                f"{label} contains a non-built-in JSON value at {location}"
            )
        identity = id(item)
        if identity in active:
            raise CalibrationPersistenceV2Error(
                f"{label} contains a JSON cycle at {location}"
            )
        active.add(identity)
        try:
            if item_type is list:
                return [
                    visit(member, f"{location}/{index}")
                    for index, member in enumerate(item)
                ]
            result: Dict[str, object] = {}
            for key, member in item.items():
                if type(key) is not str:
                    raise CalibrationPersistenceV2Error(
                        f"{label} contains a non-string key at {location}"
                    )
                result[key] = visit(member, f"{location}/{key}")
            return result
        finally:
            active.remove(identity)

    return visit(value, "<root>")


def canonical_json_bytes_v2(value: object) -> bytes:
    """Return canonical compact UTF-8 JSON bytes without a trailing newline."""

    snapshot = _snapshot_json(value, label="canonical JSON value")
    try:
        return json.dumps(
            snapshot,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise CalibrationPersistenceV2Error(
            "canonical JSON serialization failed"
        ) from error


def canonical_json_file_bytes_v2(document: Mapping[str, object]) -> bytes:
    """Serialize one exact built-in JSON object with exactly one final LF."""

    if type(document) is not dict:
        raise CalibrationPersistenceV2Error(
            "artifact serialization requires a built-in object"
        )
    return canonical_json_bytes_v2(document) + b"\n"


def artifact_semantic_sha256_v2(document: Mapping[str, object]) -> str:
    """Hash an artifact object after excluding its self-hash member."""

    snapshot = _snapshot_json(document, label="artifact self-hash input")
    if type(snapshot) is not dict:
        raise CalibrationPersistenceV2Error(
            "artifact self-hash input is not an object"
        )
    snapshot.pop("artifact_sha256", None)
    return _sha256(canonical_json_bytes_v2(snapshot))


def _self_sha256_excluding(
    document: Mapping[str, object],
    *,
    field: str,
) -> str:
    snapshot = _snapshot_json(document, label="self-hash input")
    if type(snapshot) is not dict:
        raise CalibrationPersistenceV2Error("self-hash input is not an object")
    snapshot.pop(field, None)
    return _sha256(canonical_json_bytes_v2(snapshot))


def finalize_artifact_sha256_v2(
    document: Mapping[str, object],
) -> Mapping[str, object]:
    """Return an isolated artifact snapshot with its self-hash recomputed."""

    snapshot = _snapshot_json(document, label="artifact finalization input")
    if type(snapshot) is not dict:
        raise CalibrationPersistenceV2Error(
            "artifact finalization input is not an object"
        )
    snapshot["artifact_sha256"] = artifact_semantic_sha256_v2(snapshot)
    return snapshot


def evaluation_semantic_sha256_v2(evaluation: Mapping[str, object]) -> str:
    """Hash the complete split-discriminated ranking evaluation object."""

    if type(evaluation) is not dict:
        raise CalibrationPersistenceV2Error("evaluation is not a built-in object")
    return _sha256(canonical_json_bytes_v2(evaluation))


def candidate_evidence_sha256_v2(document: Mapping[str, object]) -> str:
    """Hash the complete candidate evidence projection.

    The authenticated V1 evidence rule requires sorted-key compact UTF-8 JSON
    for the complete evidence object.  The V2 artifact has two hashes, so this
    projection removes only ``evidence_sha256`` and ``artifact_sha256`` before
    applying that canonical serialization.  Every other schema-validated
    member, including source bindings, checks, evaluation, and data access,
    remains in the digest input.
    """

    snapshot = _snapshot_json(document, label="candidate evidence hash input")
    if type(snapshot) is not dict:
        raise CalibrationPersistenceV2Error(
            "candidate evidence hash input is not an object"
        )
    if "evidence_sha256" not in snapshot or "artifact_sha256" not in snapshot:
        raise CalibrationPersistenceV2Error(
            "candidate evidence hash input lacks its hash members"
        )
    del snapshot["evidence_sha256"]
    del snapshot["artifact_sha256"]
    return _sha256(canonical_json_bytes_v2(snapshot))


def _parse_json(payload: bytes, *, label: str) -> Mapping[str, object]:
    if type(payload) is not bytes:
        raise CalibrationPersistenceV2Error(f"{label} payload is not bytes")
    if payload.startswith(b"\xef\xbb\xbf"):
        raise CalibrationPersistenceV2Error(f"{label} contains a UTF-8 BOM")
    try:
        document = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_nonfinite,
        )
    except CalibrationPersistenceV2Error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CalibrationPersistenceV2Error(
            f"{label} is not valid UTF-8 JSON"
        ) from error
    if type(document) is not dict:
        raise CalibrationPersistenceV2Error(f"{label} is not a JSON object")
    return document


def _parse_canonical_json_file(
    payload: bytes,
    *,
    label: str,
) -> Mapping[str, object]:
    if not payload or not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
        raise CalibrationPersistenceV2Error(
            f"{label} must end with exactly one LF"
        )
    if b"\r" in payload:
        raise CalibrationPersistenceV2Error(f"{label} contains CR bytes")
    document = _parse_json(payload, label=label)
    if canonical_json_file_bytes_v2(document) != payload:
        raise CalibrationPersistenceV2Error(
            f"{label} is not canonical compact JSON plus one LF"
        )
    return document


def _parse_exact_json_file(payload: bytes, *, label: str) -> Mapping[str, object]:
    if not payload or not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
        raise CalibrationPersistenceV2Error(
            f"{label} must end with exactly one LF"
        )
    if b"\r" in payload:
        raise CalibrationPersistenceV2Error(f"{label} contains CR bytes")
    return _parse_json(payload, label=label)


def _read_regular_file(path: Path, *, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise CalibrationPersistenceV2Error(f"{label} cannot be opened") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise CalibrationPersistenceV2Error(f"{label} is not a regular file")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    if (
        (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or len(payload) != after.st_size
    ):
        raise CalibrationPersistenceV2Error(
            f"{label} changed while it was read"
        )
    return payload


def _validate_schema_document(
    document: Mapping[str, object],
    schema: Mapping[str, object],
    *,
    label: str,
) -> None:
    try:
        validator = jsonschema.Draft202012Validator(schema)
        errors = sorted(
            validator.iter_errors(document),
            key=lambda error: tuple(str(item) for item in error.absolute_path),
        )
    except (TypeError, ValueError, jsonschema.SchemaError) as error:
        raise CalibrationPersistenceV2Error(f"{label} schema is invalid") from error
    if errors:
        descriptions = []
        for error in errors:
            location = "/".join(
                str(item) for item in error.absolute_path
            ) or "<root>"
            descriptions.append(f"{location}: {error.message}")
        raise CalibrationPersistenceV2Error(
            f"{label} schema validation failed: " + "; ".join(descriptions)
        )


def _authenticate_schema_v2(identifier: str) -> Mapping[str, object]:
    try:
        relative_path, expected_sha256 = _SCHEMA_SPECS[identifier]
    except KeyError as error:
        raise CalibrationPersistenceV2Error(
            "requested persistence schema is not registered"
        ) from error
    path = CALIBRATION_ROOT / relative_path
    payload = _read_regular_file(path, label=f"{identifier} schema")
    if _sha256(payload) != expected_sha256:
        raise CalibrationPersistenceV2Error(
            f"{identifier} schema bytes differ from the frozen digest"
        )
    schema = (
        _parse_exact_json_file(payload, label=f"{identifier} schema")
        if identifier in _EXACT_FORMATTED_SCHEMA_NAMES
        else _parse_canonical_json_file(
            payload,
            label=f"{identifier} schema",
        )
    )
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.SchemaError as error:
        raise CalibrationPersistenceV2Error(
            f"{identifier} schema is invalid"
        ) from error
    return schema


def authority_bindings_v2() -> Mapping[str, object]:
    """Return the exact six authenticated authority triples."""

    return {
        identifier: {
            "file_sha256": spec["file_sha256"],
            "schema_file_sha256": spec["schema_file_sha256"],
            "self_sha256": spec["self_sha256"],
        }
        for identifier, spec in _AUTHORITY_SPECS.items()
    }


def authority_input_bindings_v2() -> Tuple[Mapping[str, object], ...]:
    """Return exact file bindings for the six authority contract payloads."""

    result = []
    for identifier in sorted(_AUTHORITY_SPECS):
        spec = _AUTHORITY_SPECS[identifier]
        path = REPOSITORY_ROOT / str(spec["path"])
        payload = _read_regular_file(path, label=f"{identifier} authority")
        if _sha256(payload) != spec["file_sha256"]:
            raise CalibrationPersistenceV2Error(
                f"{identifier} authority bytes differ from the frozen digest"
            )
        result.append(
            {
                "id": identifier,
                "path": spec["path"],
                "sha256": spec["file_sha256"],
                "size_bytes": len(payload),
            }
        )
    return tuple(result)


def input_bundle_sha256_v2(
    bindings: Sequence[Mapping[str, object]],
) -> str:
    """Hash the sorted exact file-binding set for one run input bundle."""

    if type(bindings) not in {list, tuple}:
        raise CalibrationPersistenceV2Error("input bindings are not concrete")
    snapshots = []
    for binding in bindings:
        snapshot = _snapshot_json(binding, label="input binding")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error("input binding is not an object")
        if set(snapshot) != {"id", "path", "sha256", "size_bytes"}:
            raise CalibrationPersistenceV2Error(
                "input binding field set is invalid"
            )
        if type(snapshot["id"]) is not str or not snapshot["id"]:
            raise CalibrationPersistenceV2Error("input binding ID is invalid")
        snapshots.append(snapshot)
    identifiers = [str(binding["id"]) for binding in snapshots]
    if len(set(identifiers)) != len(identifiers):
        raise CalibrationPersistenceV2Error("input binding IDs repeat")
    ordered = sorted(snapshots, key=lambda binding: str(binding["id"]))
    return _sha256(canonical_json_bytes_v2(ordered))


def candidate_evaluation_identity_set_sha256_v2(
    entries: Sequence[Mapping[str, object]],
) -> str:
    """Hash the unique sorted split/candidate/content-address identity set."""

    if type(entries) not in {list, tuple}:
        raise CalibrationPersistenceV2Error(
            "candidate-evaluation entries are not concrete"
        )
    identities = []
    for entry in entries:
        snapshot = _snapshot_json(entry, label="candidate-evaluation entry")
        if type(snapshot) is not dict or set(snapshot) != {
            "split",
            "candidate_vector_sha256",
            "binding",
        }:
            raise CalibrationPersistenceV2Error(
                "candidate-evaluation entry field set is invalid"
            )
        binding = snapshot["binding"]
        if (
            snapshot["split"] not in {"development", "validation"}
            or not _is_sha256(
                snapshot["candidate_vector_sha256"],
                nonzero=True,
            )
            or type(binding) is not dict
            or set(binding) != {"path", "sha256", "size_bytes"}
            or not _is_sha256(binding.get("sha256"), nonzero=True)
        ):
            raise CalibrationPersistenceV2Error(
                "candidate-evaluation identity is invalid"
            )
        identities.append(
            [
                snapshot["split"],
                snapshot["candidate_vector_sha256"],
                binding.get("sha256"),
            ]
        )
    keys = [tuple(identity) for identity in identities]
    if len(set(keys)) != len(keys):
        raise CalibrationPersistenceV2Error(
            "candidate-evaluation identities repeat"
        )
    identities.sort(key=lambda identity: tuple(str(value) for value in identity))
    return _sha256(canonical_json_bytes_v2(identities))


def candidate_failure_identity_set_sha256_v2(
    entries: Sequence[Mapping[str, object]],
) -> str:
    """Hash the unique sorted split/candidate/failure identity set."""

    if type(entries) not in {list, tuple}:
        raise CalibrationPersistenceV2Error(
            "candidate-failure entries are not concrete"
        )
    identities = []
    for entry in entries:
        snapshot = _snapshot_json(entry, label="candidate-failure entry")
        if type(snapshot) is not dict or set(snapshot) != {
            "split",
            "candidate_vector_sha256",
            "binding",
        }:
            raise CalibrationPersistenceV2Error(
                "candidate-failure entry field set is invalid"
            )
        binding = snapshot["binding"]
        if (
            snapshot["split"] not in {"development", "validation"}
            or not _is_sha256(
                snapshot["candidate_vector_sha256"],
                nonzero=True,
            )
            or type(binding) is not dict
            or set(binding) != {"path", "sha256", "size_bytes"}
            or not _is_sha256(binding.get("sha256"), nonzero=True)
        ):
            raise CalibrationPersistenceV2Error(
                "candidate-failure identity is invalid"
            )
        identities.append(
            [
                snapshot["split"],
                snapshot["candidate_vector_sha256"],
                binding.get("sha256"),
            ]
        )
    keys = [tuple(identity) for identity in identities]
    if len(set(keys)) != len(keys):
        raise CalibrationPersistenceV2Error(
            "candidate-failure identities repeat"
        )
    identities.sort(key=lambda identity: tuple(str(value) for value in identity))
    return _sha256(canonical_json_bytes_v2(identities))


class _AtomicArtifactStoreV2:
    _TEMP_PREFIX = ".mirmir-v2-write-"
    _TEMP_SUFFIX = ".tmp"

    def __init__(self, root: Path) -> None:
        supplied_root = Path(os.path.abspath(os.fspath(root)))
        if supplied_root.is_symlink():
            raise CalibrationPersistenceV2Error(
                "artifact root itself must not be a symlink"
            )
        self.root = Path(os.path.realpath(os.fspath(supplied_root)))
        self._active_closure_captures: Dict[
            Tuple[int, object], AuthenticatedClosureCaptureV2
        ] = {}
        self._closure_state_lock = threading.RLock()
        root_descriptor, root_components = self._create_and_pin_root(self.root)
        self._root_components = root_components
        self._root_identity = None
        self._directory_identities: Dict[str, Tuple[int, int]] = {}
        self._publication_thread_lock = None
        try:
            root_status = os.fstat(root_descriptor)
            self._root_identity = (root_status.st_dev, root_status.st_ino)
            self._publication_thread_lock = self._publication_lock_for_root(
                self._root_identity
            )
            with self._serialized_publication(
                root_descriptor=root_descriptor,
            ):
                self._clean_temporary_files(root_descriptor)
                for name in ("evaluations", "failures"):
                    created = False
                    try:
                        os.mkdir(name, 0o700, dir_fd=root_descriptor)
                        created = True
                    except FileExistsError:
                        pass
                    except OSError as error:
                        raise CalibrationPersistenceV2Error(
                            f"{name} directory cannot be created"
                        ) from error
                    descriptor = self._open_directory_at(root_descriptor, name)
                    try:
                        status = os.fstat(descriptor)
                        self._directory_identities[name] = (
                            status.st_dev,
                            status.st_ino,
                        )
                        self._clean_temporary_files(descriptor)
                    finally:
                        os.close(descriptor)
                    if created:
                        os.fsync(root_descriptor)
        finally:
            os.close(root_descriptor)

    @property
    def _active_closure_capture(
        self,
    ) -> Optional[AuthenticatedClosureCaptureV2]:
        """Return only the capture owned by this thread/task execution."""

        owner = self._closure_owner_key()
        with self._closure_state_lock:
            return self._active_closure_captures.get(owner)

    @_active_closure_capture.setter
    def _active_closure_capture(
        self,
        capture: Optional[AuthenticatedClosureCaptureV2],
    ) -> None:
        owner = self._closure_owner_key()
        with self._closure_state_lock:
            if capture is None:
                self._active_closure_captures.pop(owner, None)
            else:
                self._active_closure_captures[owner] = capture

    @staticmethod
    def _closure_owner_key() -> Tuple[int, object]:
        try:
            task: object = asyncio.current_task()
        except RuntimeError:
            task = None
        return threading.get_ident(), task

    @staticmethod
    def _captured_identity_token(
        binding: FileBindingV2,
    ) -> Tuple[int, int, int, int, int, int]:
        """Return an opaque stable token for a capture-authenticated binding."""

        return (
            -1,
            -1,
            stat.S_IFREG,
            binding.size_bytes,
            int(binding.sha256[:16], 16),
            int(binding.sha256[16:32], 16),
        )

    def _capture_active_binding(
        self,
        binding: FileBindingV2,
        *,
        label: str,
    ) -> Optional[
        Tuple[bytes, Tuple[int, int, int, int, int, int]]
    ]:
        capture = self._active_closure_capture
        if capture is None:
            return None
        try:
            payload = capture.capture(
                ClosureFileBindingV2(
                    path=binding.path,
                    sha256=binding.sha256,
                    size_bytes=binding.size_bytes,
                ),
                label=label,
            )
        except AuthenticatedClosureSnapshotV2Error as error:
            raise CalibrationPersistenceV2Error(str(error)) from error
        return payload, self._captured_identity_token(binding)

    @contextmanager
    def authenticated_closure(
        self,
        *,
        shared_capture: Optional[AuthenticatedClosureCaptureV2] = None,
    ):
        """Share one retained-descriptor capture across nested pure reads."""

        if (
            shared_capture is not None
            and type(shared_capture) is not AuthenticatedClosureCaptureV2
        ):
            raise CalibrationPersistenceV2Error(
                "shared authenticated closure capture has wrong type"
            )
        active = self._active_closure_capture
        if active is not None:
            if shared_capture is not None and shared_capture is not active:
                raise CalibrationPersistenceV2Error(
                    "conflicting authenticated closure capture is active"
                )
            yield active
            return

        if shared_capture is not None:
            try:
                shared_root_identity = shared_capture.root_identity
            except AuthenticatedClosureSnapshotV2Error as error:
                raise CalibrationPersistenceV2Error(str(error)) from error
            if (
                shared_capture.root != self.root
                or shared_root_identity != self._root_identity
            ):
                raise CalibrationPersistenceV2Error(
                    "shared authenticated closure root identity differs"
                )
            self._active_closure_capture = shared_capture
            try:
                yield shared_capture
            finally:
                self._active_closure_capture = None
            return

        try:
            with AuthenticatedClosureCaptureV2(
                self.root,
                expected_root_identity=self._root_identity,
            ) as capture:
                self._active_closure_capture = capture
                try:
                    yield capture
                    if capture.captured_file_count:
                        capture.snapshot()
                    else:
                        capture.cancel_empty()
                finally:
                    self._active_closure_capture = None
        except AuthenticatedClosureSnapshotV2Error as error:
            raise CalibrationPersistenceV2Error(str(error)) from error

    @contextmanager
    def live_recheck(self):
        """Temporarily bypass snapshot reuse for a final equality check."""

        capture = self._active_closure_capture
        self._active_closure_capture = None
        try:
            yield
        finally:
            self._active_closure_capture = capture

    @staticmethod
    def _publication_lock_for_root(
        root_identity: Tuple[int, int],
    ):
        with _ARTIFACT_STORE_LOCK_REGISTRY_GUARD:
            lock = _ARTIFACT_STORE_LOCK_REGISTRY.get(root_identity)
            if lock is None:
                lock = threading.RLock()
                _ARTIFACT_STORE_LOCK_REGISTRY[root_identity] = lock
            return lock

    def _require_serialization_root(self, descriptor: int) -> None:
        if self._root_identity is None:
            raise CalibrationPersistenceV2Error(
                "artifact root identity is unavailable"
            )
        try:
            status = os.fstat(descriptor)
        except OSError as error:
            raise CalibrationPersistenceV2Error(
                "artifact root serialization descriptor cannot be inspected"
            ) from error
        if (
            not stat.S_ISDIR(status.st_mode)
            or (status.st_dev, status.st_ino) != self._root_identity
        ):
            raise CalibrationPersistenceV2Error(
                "artifact root serialization identity changed"
            )
        reopened = self._open_root()
        try:
            reopened_status = os.fstat(reopened)
        finally:
            os.close(reopened)
        if (reopened_status.st_dev, reopened_status.st_ino) != self._root_identity:
            raise CalibrationPersistenceV2Error(
                "artifact root serialization path changed"
            )

    @contextmanager
    def _serialized_publication(
        self,
        *,
        root_descriptor: Optional[int] = None,
    ):
        """Serialize recovery and publication across threads and processes."""

        if self._publication_thread_lock is None:
            raise CalibrationPersistenceV2Error(
                "artifact publication serialization is unavailable"
            )
        owns_descriptor = root_descriptor is None
        descriptor = self._open_root() if owns_descriptor else root_descriptor
        if descriptor is None:
            raise AssertionError("artifact root descriptor was not supplied")
        try:
            with self._publication_thread_lock:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX)
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        "artifact root cannot be locked for publication"
                    ) from error
                try:
                    self._require_serialization_root(descriptor)
                    yield
                    self._require_serialization_root(descriptor)
                finally:
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_UN)
                    except OSError as error:
                        raise CalibrationPersistenceV2Error(
                            "artifact root publication lock cannot be released"
                        ) from error
        finally:
            if owns_descriptor:
                os.close(descriptor)

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )

    @classmethod
    def _create_and_pin_root(
        cls,
        root: Path,
    ) -> Tuple[int, Tuple[Tuple[str, int, int], ...]]:
        if not root.is_absolute():
            raise CalibrationPersistenceV2Error("artifact root is not absolute")
        descriptor = os.open(os.sep, cls._directory_flags())
        identities = []
        try:
            for component in root.parts[1:]:
                created = False
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    created = True
                except FileExistsError:
                    pass
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        "artifact-root component cannot be created"
                    ) from error
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened = os.open(
                        component,
                        cls._directory_flags(),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        "artifact-root component is unsafe"
                    ) from error
                after = os.fstat(opened)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(after.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (after.st_dev, after.st_ino)
                ):
                    os.close(opened)
                    raise CalibrationPersistenceV2Error(
                        "artifact-root component identity changed"
                    )
                if created:
                    os.fsync(descriptor)
                identities.append((component, after.st_dev, after.st_ino))
                os.close(descriptor)
                descriptor = opened
            return descriptor, tuple(identities)
        except BaseException:
            os.close(descriptor)
            raise

    def _open_root(self) -> int:
        descriptor = os.open(os.sep, self._directory_flags())
        try:
            for component, device, inode in self._root_components:
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened = os.open(
                        component,
                        self._directory_flags(),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        "artifact root cannot be reopened"
                    ) from error
                after = os.fstat(opened)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or (before.st_dev, before.st_ino) != (device, inode)
                    or (after.st_dev, after.st_ino) != (device, inode)
                ):
                    os.close(opened)
                    raise CalibrationPersistenceV2Error(
                        "artifact root identity changed"
                    )
                os.close(descriptor)
                descriptor = opened
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @classmethod
    def _open_directory_at(cls, parent_descriptor: int, name: str) -> int:
        try:
            before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            descriptor = os.open(
                name,
                cls._directory_flags(),
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            raise CalibrationPersistenceV2Error(
                f"{name} directory cannot be opened"
            ) from error
        after = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(after.st_mode)
            or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        ):
            os.close(descriptor)
            raise CalibrationPersistenceV2Error(
                f"{name} directory identity changed"
            )
        return descriptor

    def _open_directory(self, name: str) -> int:
        expected = self._directory_identities.get(name)
        if expected is None:
            raise CalibrationPersistenceV2Error(
                "artifact directory is not pinned"
            )
        root_descriptor = self._open_root()
        try:
            descriptor = self._open_directory_at(root_descriptor, name)
        finally:
            os.close(root_descriptor)
        status = os.fstat(descriptor)
        if (status.st_dev, status.st_ino) != expected:
            os.close(descriptor)
            raise CalibrationPersistenceV2Error(
                "artifact directory identity changed"
            )
        return descriptor

    @classmethod
    def _clean_temporary_files(cls, descriptor: int) -> None:
        removed = False
        for name in os.listdir(descriptor):
            if not (name.startswith(cls._TEMP_PREFIX) and name.endswith(cls._TEMP_SUFFIX)):
                continue
            try:
                status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISDIR(status.st_mode):
                raise CalibrationPersistenceV2Error(
                    "temporary artifact path is a directory"
                )
            os.unlink(name, dir_fd=descriptor)
            removed = True
        if removed:
            os.fsync(descriptor)

    @staticmethod
    def _read_at_with_identity(
        descriptor: int,
        name: str,
        *,
        label: str,
    ) -> Tuple[bytes, Tuple[int, int, int, int, int, int]]:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        file_descriptor = None
        try:
            before_path = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            file_descriptor = os.open(name, flags, dir_fd=descriptor)
            before = os.fstat(file_descriptor)
        except OSError as error:
            if file_descriptor is not None:
                os.close(file_descriptor)
            raise CalibrationPersistenceV2Error(f"{label} cannot be opened") from error
        try:
            if (
                not stat.S_ISREG(before_path.st_mode)
                or not stat.S_ISREG(before.st_mode)
                or (before_path.st_dev, before_path.st_ino)
                != (before.st_dev, before.st_ino)
            ):
                raise CalibrationPersistenceV2Error(
                    f"{label} is not a stable regular file"
                )
            chunks = []
            try:
                while True:
                    chunk = os.read(file_descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    chunks.append(chunk)
                after = os.fstat(file_descriptor)
                after_path = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise CalibrationPersistenceV2Error(
                    f"{label} changed while read"
                ) from error
        finally:
            os.close(file_descriptor)
        payload = b"".join(chunks)
        stable_fields_before_path = (
            before_path.st_dev,
            before_path.st_ino,
            before_path.st_mode,
            before_path.st_size,
            before_path.st_mtime_ns,
            before_path.st_ctime_ns,
        )
        stable_fields_before = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        stable_fields_after = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        stable_fields_after_path = (
            after_path.st_dev,
            after_path.st_ino,
            after_path.st_mode,
            after_path.st_size,
            after_path.st_mtime_ns,
            after_path.st_ctime_ns,
        )
        if (
            stable_fields_before_path != stable_fields_before
            or stable_fields_before != stable_fields_after
            or stable_fields_after != stable_fields_after_path
            or len(payload) != after.st_size
        ):
            raise CalibrationPersistenceV2Error(f"{label} changed while read")
        return payload, stable_fields_after

    @staticmethod
    def _read_at(descriptor: int, name: str, *, label: str) -> bytes:
        payload, _ = _AtomicArtifactStoreV2._read_at_with_identity(
            descriptor,
            name,
            label=label,
        )
        return payload

    def _publish_at(
        self,
        descriptor: int,
        name: str,
        payload: bytes,
        *,
        label: str,
    ) -> None:
        with self._serialized_publication():
            self._publish_at_serialized(
                descriptor,
                name,
                payload,
                label=label,
            )

    @classmethod
    def _publish_at_serialized(
        cls,
        descriptor: int,
        name: str,
        payload: bytes,
        *,
        label: str,
    ) -> None:
        try:
            existing = cls._read_at(descriptor, name, label=label)
        except CalibrationPersistenceV2Error:
            try:
                os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise
        else:
            if existing != payload:
                raise CalibrationPersistenceV2Error(f"{label} changed")
            try:
                os.fsync(descriptor)
            except OSError as error:
                raise CalibrationPersistenceV2Error(
                    f"{label} cannot be durably reopened"
                ) from error
            return

        temporary = (
            f"{cls._TEMP_PREFIX}{os.getpid()}-{secrets.token_hex(16)}"
            f"{cls._TEMP_SUFFIX}"
        )
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        file_descriptor = None
        try:
            file_descriptor = os.open(
                temporary,
                flags,
                0o600,
                dir_fd=descriptor,
            )
            offset = 0
            while offset < len(payload):
                written = os.write(file_descriptor, payload[offset:])
                if written <= 0:
                    raise CalibrationPersistenceV2Error(
                        f"{label} write made no progress"
                    )
                offset += written
            os.fsync(file_descriptor)
            try:
                os.link(
                    temporary,
                    name,
                    src_dir_fd=descriptor,
                    dst_dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError:
                existing = cls._read_at(descriptor, name, label=label)
                if existing != payload:
                    raise CalibrationPersistenceV2Error(f"{label} changed")
            os.fsync(descriptor)
        except OSError as error:
            raise CalibrationPersistenceV2Error(
                f"{label} cannot be atomically published"
            ) from error
        finally:
            if file_descriptor is not None:
                os.close(file_descriptor)
            try:
                os.unlink(temporary, dir_fd=descriptor)
            except FileNotFoundError:
                pass
            except OSError as error:
                raise CalibrationPersistenceV2Error(
                    f"{label} temporary file cannot be removed"
                ) from error
            else:
                try:
                    os.fsync(descriptor)
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        f"{label} temporary cleanup cannot be synchronized"
                    ) from error

    def publish_content_addressed(
        self,
        directory: str,
        payload: bytes,
    ) -> ArtifactBindingV2:
        digest = _sha256(payload)
        name = f"{digest}.json"
        descriptor = self._open_directory(directory)
        try:
            self._publish_at(
                descriptor,
                name,
                payload,
                label=f"{directory} artifact",
            )
            reopened = self._read_at(
                descriptor,
                name,
                label=f"{directory} artifact",
            )
        finally:
            os.close(descriptor)
        if reopened != payload:
            raise CalibrationPersistenceV2Error(
                "content-addressed publication changed on reopen"
            )
        return ArtifactBindingV2(
            path=f"{directory}/{name}",
            sha256=digest,
            size_bytes=len(payload),
        )

    def _reopen_content_addressed_snapshot(
        self,
        binding: ArtifactBindingV2,
    ) -> Tuple[bytes, Tuple[int, int, int, int, int, int]]:
        if type(binding) is not ArtifactBindingV2:
            raise CalibrationPersistenceV2Error("artifact binding has wrong type")
        parts = binding.path.split("/")
        if (
            len(parts) != 2
            or parts[0] not in {"evaluations", "failures"}
            or parts[1] != f"{binding.sha256}.json"
        ):
            raise CalibrationPersistenceV2Error("artifact path is invalid")
        captured = self._capture_active_binding(
            FileBindingV2(
                binding.path,
                binding.sha256,
                binding.size_bytes,
            ),
            label=f"{parts[0]} artifact",
        )
        if captured is not None:
            return captured
        descriptor = self._open_directory(parts[0])
        try:
            payload, identity = self._read_at_with_identity(
                descriptor,
                parts[1],
                label=f"{parts[0]} artifact",
            )
        finally:
            os.close(descriptor)
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise CalibrationPersistenceV2Error("artifact binding differs from bytes")
        return payload, identity

    def reopen_content_addressed(self, binding: ArtifactBindingV2) -> bytes:
        payload, _ = self._reopen_content_addressed_snapshot(binding)
        return payload

    def require_content_addressed_snapshot_stable(
        self,
        binding: ArtifactBindingV2,
        *,
        payload: bytes,
        identity: Tuple[int, int, int, int, int, int],
        label: str,
    ) -> None:
        with self.live_recheck():
            reopened, reopened_identity = self._reopen_content_addressed_snapshot(
                binding
            )
        if reopened != payload or (
            identity[0] != -1 and reopened_identity != identity
        ):
            raise CalibrationPersistenceV2Error(
                f"{label} changed while dependencies were reopened"
            )

    def publish_fixed(self, name: str, payload: bytes) -> FileBindingV2:
        if name not in {"attempts-v2.ndjson", "calibration-run-ledger-v2.json"}:
            raise CalibrationPersistenceV2Error("fixed artifact name is invalid")
        descriptor = self._open_root()
        try:
            self._publish_at(descriptor, name, payload, label=name)
            reopened = self._read_at(descriptor, name, label=name)
        finally:
            os.close(descriptor)
        if reopened != payload:
            raise CalibrationPersistenceV2Error("fixed artifact changed on reopen")
        return FileBindingV2(name, _sha256(payload), len(payload))

    def _reopen_fixed_snapshot(
        self,
        binding: FileBindingV2,
    ) -> Tuple[bytes, Tuple[int, int, int, int, int, int]]:
        if type(binding) is not FileBindingV2:
            raise CalibrationPersistenceV2Error("fixed binding has wrong type")
        captured = self._capture_active_binding(
            binding,
            label=binding.path,
        )
        if captured is not None:
            return captured
        descriptor = self._open_root()
        try:
            payload, identity = self._read_at_with_identity(
                descriptor,
                binding.path,
                label=binding.path,
            )
        finally:
            os.close(descriptor)
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise CalibrationPersistenceV2Error("fixed binding differs from bytes")
        return payload, identity

    def reopen_fixed(self, binding: FileBindingV2) -> bytes:
        payload, _ = self._reopen_fixed_snapshot(binding)
        return payload

    def require_fixed_snapshot_stable(
        self,
        binding: FileBindingV2,
        *,
        payload: bytes,
        identity: Tuple[int, int, int, int, int, int],
        label: str,
    ) -> None:
        with self.live_recheck():
            reopened, reopened_identity = self._reopen_fixed_snapshot(binding)
        if reopened != payload or (
            identity[0] != -1 and reopened_identity != identity
        ):
            raise CalibrationPersistenceV2Error(
                f"{label} changed while dependencies were reopened"
            )

    def _reopen_relative_snapshot(
        self,
        binding: FileBindingV2,
        *,
        label: str,
    ) -> Tuple[bytes, Tuple[int, int, int, int, int, int]]:
        """Reopen one exact relative binding beneath the pinned artifact root."""

        if type(binding) is not FileBindingV2:
            raise CalibrationPersistenceV2Error(
                f"{label} binding has wrong type"
            )
        captured = self._capture_active_binding(binding, label=label)
        if captured is not None:
            return captured
        parts = binding.path.split("/")
        descriptors = []
        directory_entries = []
        file_descriptor = None
        try:
            root_descriptor = self._open_root()
            descriptors.append(root_descriptor)
            parent_descriptor = root_descriptor
            for component in parts[:-1]:
                descriptor = None
                try:
                    before = os.stat(
                        component,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    descriptor = os.open(
                        component,
                        self._directory_flags(),
                        dir_fd=parent_descriptor,
                    )
                    opened = os.fstat(descriptor)
                    after = os.stat(
                        component,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    if descriptor is not None:
                        os.close(descriptor)
                    raise CalibrationPersistenceV2Error(
                        f"{label} directory component cannot be opened"
                    ) from error
                identity = (opened.st_dev, opened.st_ino)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or not stat.S_ISDIR(after.st_mode)
                    or (before.st_dev, before.st_ino) != identity
                    or (after.st_dev, after.st_ino) != identity
                ):
                    os.close(descriptor)
                    raise CalibrationPersistenceV2Error(
                        f"{label} directory component identity changed"
                    )
                directory_entries.append(
                    (parent_descriptor, component, identity)
                )
                descriptors.append(descriptor)
                parent_descriptor = descriptor

            name = parts[-1]
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            try:
                before_path = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                file_descriptor = os.open(
                    name,
                    flags,
                    dir_fd=parent_descriptor,
                )
                before = os.fstat(file_descriptor)
            except OSError as error:
                raise CalibrationPersistenceV2Error(
                    f"{label} cannot be opened"
                ) from error
            identity = (before.st_dev, before.st_ino)
            if (
                not stat.S_ISREG(before_path.st_mode)
                or not stat.S_ISREG(before.st_mode)
                or (before_path.st_dev, before_path.st_ino) != identity
            ):
                raise CalibrationPersistenceV2Error(
                    f"{label} is not a stable regular file"
                )
            chunks = []
            try:
                while True:
                    chunk = os.read(file_descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    chunks.append(chunk)
                after = os.fstat(file_descriptor)
                after_path = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise CalibrationPersistenceV2Error(
                    f"{label} changed while read"
                ) from error
            payload = b"".join(chunks)
            stable_fields_before = (
                before.st_dev,
                before.st_ino,
                before.st_mode,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            )
            stable_fields_after = (
                after.st_dev,
                after.st_ino,
                after.st_mode,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            stable_fields_path = (
                after_path.st_dev,
                after_path.st_ino,
                after_path.st_mode,
                after_path.st_size,
                after_path.st_mtime_ns,
                after_path.st_ctime_ns,
            )
            if (
                stable_fields_before != stable_fields_after
                or stable_fields_after != stable_fields_path
                or len(payload) != after.st_size
            ):
                raise CalibrationPersistenceV2Error(
                    f"{label} changed while read"
                )
            for parent, component, expected_identity in directory_entries:
                try:
                    current = os.stat(
                        component,
                        dir_fd=parent,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise CalibrationPersistenceV2Error(
                        f"{label} directory path changed while read"
                    ) from error
                if (
                    not stat.S_ISDIR(current.st_mode)
                    or (current.st_dev, current.st_ino) != expected_identity
                ):
                    raise CalibrationPersistenceV2Error(
                        f"{label} directory path changed while read"
                    )
            reopened_root = self._open_root()
            os.close(reopened_root)
        finally:
            if file_descriptor is not None:
                os.close(file_descriptor)
            for descriptor in reversed(descriptors):
                os.close(descriptor)
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise CalibrationPersistenceV2Error(
                f"{label} binding differs from bytes"
            )
        return payload, stable_fields_after

    def reopen_relative(self, binding: FileBindingV2, *, label: str) -> bytes:
        payload, _ = self._reopen_relative_snapshot(binding, label=label)
        return payload

    def require_relative_snapshot_stable(
        self,
        binding: FileBindingV2,
        *,
        payload: bytes,
        identity: Tuple[int, int, int, int, int, int],
        label: str,
    ) -> None:
        with self.live_recheck():
            reopened, reopened_identity = self._reopen_relative_snapshot(
                binding,
                label=label,
            )
        if reopened != payload or (
            identity[0] != -1 and reopened_identity != identity
        ):
            raise CalibrationPersistenceV2Error(
                f"{label} changed while manifest dependencies were reopened"
            )


class CalibrationPersistenceAdapterV2:
    """Strict persistence and replay boundary for one P06 V2 artifact root."""

    def __init__(
        self,
        root: Path,
        *,
        _control_authorization_verifier: Optional[Callable[..., object]] = None,
        _control_producer_capability_provider: Optional[
            Callable[
                [CandidateControlProducerRequestV2],
                CandidateControlProducerCapabilitiesV2,
            ]
        ] = None,
        _validation_admission_semantic_verifier: Optional[
            Callable[
                [TypedArtifactBindingV2, Mapping[str, object]],
                Mapping[str, object],
            ]
        ] = None,
    ) -> None:
        self._schemas = self._authenticate_schemas()
        self._authority_documents = self._authenticate_authorities()
        self.plan = self._authenticate_plan()
        self.non_ash_profile = self._authenticate_non_ash_profile()
        if (
            _control_authorization_verifier is not None
            and not callable(_control_authorization_verifier)
        ):
            raise CalibrationPersistenceV2Error(
                "control authorization verifier seam is not callable"
            )
        self._control_authorization_verifier = (
            verify_control_authorization_bundle_v2
            if _control_authorization_verifier is None
            else _control_authorization_verifier
        )
        if (
            _control_producer_capability_provider is not None
            and not callable(_control_producer_capability_provider)
        ):
            raise CalibrationPersistenceV2Error(
                "control producer capability provider is not callable"
            )
        self.__control_producer_capability_provider = (
            _control_producer_capability_provider
        )
        if (
            _validation_admission_semantic_verifier is not None
            and not callable(_validation_admission_semantic_verifier)
        ):
            raise CalibrationPersistenceV2Error(
                "validation admission semantic verifier is not callable"
            )
        self.__validation_admission_semantic_verifier = (
            _validation_admission_semantic_verifier
        )
        self._store = _AtomicArtifactStoreV2(root)

    @staticmethod
    def _authenticate_schemas() -> Mapping[str, Mapping[str, object]]:
        return {
            identifier: _authenticate_schema_v2(identifier)
            for identifier in _SCHEMA_SPECS
        }

    def _authenticate_authorities(self) -> Mapping[str, Mapping[str, object]]:
        documents: Dict[str, Mapping[str, object]] = {}
        for identifier, spec in _AUTHORITY_SPECS.items():
            contract_payload = _read_regular_file(
                REPOSITORY_ROOT / str(spec["path"]),
                label=f"{identifier} authority",
            )
            schema_payload = _read_regular_file(
                REPOSITORY_ROOT / str(spec["schema_path"]),
                label=f"{identifier} authority schema",
            )
            if (
                _sha256(contract_payload) != spec["file_sha256"]
                or _sha256(schema_payload) != spec["schema_file_sha256"]
            ):
                raise CalibrationPersistenceV2Error(
                    f"{identifier} authority triple differs"
                )
            contract = _parse_exact_json_file(
                contract_payload,
                label=f"{identifier} authority",
            )
            schema = _parse_exact_json_file(
                schema_payload,
                label=f"{identifier} authority schema",
            )
            try:
                jsonschema.Draft202012Validator.check_schema(schema)
            except jsonschema.SchemaError as error:
                raise CalibrationPersistenceV2Error(
                    f"{identifier} authority schema is invalid"
                ) from error
            _validate_schema_document(
                contract,
                schema,
                label=f"{identifier} authority",
            )
            if (
                contract.get(spec["self_field"]) != spec["self_sha256"]
                or _self_sha256_excluding(
                    contract,
                    field=str(spec["self_field"]),
                )
                != spec["self_sha256"]
            ):
                raise CalibrationPersistenceV2Error(
                    f"{identifier} authority self-hash differs"
                )
            documents[identifier] = contract
        return documents

    def _authenticate_plan(self) -> ParsedCalibrationPlanV2:
        plan_document = self._authority_documents["calibration_plan_v2"]
        input_bindings = plan_document.get("input_bindings")
        if type(input_bindings) is not list:
            raise CalibrationPersistenceV2Error(
                "calibration plan input bindings are invalid"
            )
        bound_payloads = {}
        for binding in input_bindings:
            if type(binding) is not dict or type(binding.get("id")) is not str:
                raise CalibrationPersistenceV2Error(
                    "calibration plan input binding is invalid"
                )
            path = REPOSITORY_ROOT / str(binding.get("path"))
            bound_payloads[str(binding["id"])] = _read_regular_file(
                path,
                label=f"calibration plan input {binding['id']}",
            )
        try:
            return parse_calibration_plan_v2(
                _read_regular_file(
                    REPOSITORY_ROOT
                    / str(_AUTHORITY_SPECS["calibration_plan_v2"]["path"]),
                    label="calibration plan V2",
                ),
                bound_payloads=bound_payloads,
            )
        except CalibrationPlanCodecError as error:
            raise CalibrationPersistenceV2Error(
                "calibration plan V2 authentication failed"
            ) from error

    def _authenticate_non_ash_profile(
        self,
    ) -> NonAshSelectorExecutionProfileV2:
        """Derive the executable selector only from the authenticated overlay."""

        identifier = "baseline_ablation_budget_v2"
        spec = _AUTHORITY_SPECS[identifier]
        overlay = self._authority_documents[identifier]
        bindings = overlay.get("authority_bindings")
        if type(bindings) is not list or not bindings:
            raise CalibrationPersistenceV2Error(
                "baseline-ablation authority bindings are invalid"
            )
        authority_payloads: Dict[str, bytes] = {}
        for binding in bindings:
            if (
                type(binding) is not dict
                or type(binding.get("id")) is not str
                or type(binding.get("path")) is not str
                or binding["id"] in authority_payloads
            ):
                raise CalibrationPersistenceV2Error(
                    "baseline-ablation authority binding is invalid"
                )
            path = PurePosixPath(binding["path"])
            if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
                raise CalibrationPersistenceV2Error(
                    "baseline-ablation authority path is invalid"
                )
            authority_payloads[binding["id"]] = _read_regular_file(
                REPOSITORY_ROOT / path,
                label=f"baseline-ablation input {binding['id']}",
            )
        try:
            return parse_baseline_ablation_budget_v2(
                _read_regular_file(
                    REPOSITORY_ROOT / str(spec["path"]),
                    label="baseline-ablation budget V2",
                ),
                schema_payload=_read_regular_file(
                    REPOSITORY_ROOT / str(spec["schema_path"]),
                    label="baseline-ablation budget V2 schema",
                ),
                authority_payloads=authority_payloads,
            )
        except BaselineAblationBudgetV2Error as error:
            raise CalibrationPersistenceV2Error(
                "baseline-ablation execution profile authentication failed"
            ) from error

    def _validate_authority_bindings(self, document: Mapping[str, object]) -> None:
        if document.get("authority_bindings") != authority_bindings_v2():
            raise CalibrationPersistenceV2Error(
                "artifact authority bindings differ from authenticated triples"
            )

    def _validate_artifact_self_hash(self, document: Mapping[str, object]) -> None:
        if (
            not _is_sha256(document.get("artifact_sha256"), nonzero=True)
            or artifact_semantic_sha256_v2(document)
            != document.get("artifact_sha256")
        ):
            raise CalibrationPersistenceV2Error("artifact self-hash differs")

    @staticmethod
    def _validate_content_addressed_document_binding(
        document: Mapping[str, object],
        binding: ArtifactBindingV2,
        *,
        directory: str,
    ) -> None:
        if type(binding) is not ArtifactBindingV2:
            raise CalibrationPersistenceV2Error("artifact binding has wrong type")
        payload = canonical_json_file_bytes_v2(document)
        digest = _sha256(payload)
        if (
            binding.path != f"{directory}/{digest}.json"
            or binding.sha256 != digest
            or binding.size_bytes != len(payload)
        ):
            raise CalibrationPersistenceV2Error(
                "artifact binding differs from canonical document bytes"
            )

    @staticmethod
    def _validate_fixed_document_binding(
        document: Mapping[str, object],
        binding: FileBindingV2,
        *,
        path: str,
    ) -> None:
        if type(binding) is not FileBindingV2:
            raise CalibrationPersistenceV2Error("fixed binding has wrong type")
        payload = canonical_json_file_bytes_v2(document)
        if (
            binding.path != path
            or binding.sha256 != _sha256(payload)
            or binding.size_bytes != len(payload)
        ):
            raise CalibrationPersistenceV2Error(
                "fixed binding differs from canonical document bytes"
            )

    @staticmethod
    def _relative_file_binding(
        document: object,
        *,
        label: str,
        includes_id: bool = False,
    ) -> FileBindingV2:
        expected_fields = {"path", "sha256", "size_bytes"}
        if includes_id:
            expected_fields.add("id")
        if type(document) is not dict or set(document) != expected_fields:
            raise CalibrationPersistenceV2Error(
                f"{label} binding object is invalid"
            )
        if includes_id and (
            type(document["id"]) is not str or not document["id"]
        ):
            raise CalibrationPersistenceV2Error(f"{label} ID is invalid")
        try:
            return FileBindingV2(
                path=document["path"],
                sha256=document["sha256"],
                size_bytes=document["size_bytes"],
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationPersistenceV2Error(
                f"{label} binding is invalid"
            ) from error

    def _reopen_relative_file_binding(
        self,
        document: object,
        *,
        label: str,
        includes_id: bool = False,
    ) -> FileBindingV2:
        binding = self._relative_file_binding(
            document,
            label=label,
            includes_id=includes_id,
        )
        self._store.reopen_relative(binding, label=label)
        return binding

    def _physical_candidate(
        self,
        items: object,
    ) -> Mapping[str, object]:
        if type(items) is not list or len(items) != 48:
            raise CalibrationPersistenceV2Error(
                "physical candidate does not contain 48 pairs"
            )
        candidate: Dict[str, object] = {}
        for item in items:
            if (
                type(item) is not list
                or len(item) != 2
                or type(item[0]) is not str
                or type(item[1]) not in {int, str}
                or item[0] in candidate
            ):
                raise CalibrationPersistenceV2Error(
                    "physical candidate pair is invalid"
                )
            candidate[item[0]] = item[1]
        try:
            validate_materialized_candidate_identity_v2(candidate, self.plan)
        except CalibrationPlanCodecError as error:
            raise CalibrationPersistenceV2Error(
                "physical candidate does not reconstruct from the plan"
            ) from error
        if list(candidate) != list(self.plan.physical_candidate_order):
            raise CalibrationPersistenceV2Error(
                "physical candidate pair order differs from the plan"
            )
        logical = {
            name: candidate[name] for name in self.plan.logical_parameter_order
        }
        expected = materialize_candidate_vector_v2(logical, self.plan)
        if any(
            type(candidate[name]) is not type(expected[name])
            or candidate[name] != expected[name]
            for name in self.plan.physical_candidate_order
        ):
            raise CalibrationPersistenceV2Error(
                "physical candidate differs from exact materialization"
            )
        return candidate

    @staticmethod
    def _development_evaluation(document: object) -> DevelopmentEvaluationV2:
        if type(document) is not dict or type(document.get("objective")) is not dict:
            raise CalibrationPersistenceV2Error(
                "development evaluation object is invalid"
            )
        objective = document["objective"]
        try:
            return DevelopmentEvaluationV2(
                feasible=document.get("feasible"),
                failure_reasons=tuple(document.get("failure_reasons", ())),
                mean_y_psnr_delta_vs_fixed_db=objective[
                    "mean_y_psnr_delta_vs_fixed_db"
                ],
                mean_y_psnr_delta_vs_non_ash_db=objective[
                    "mean_y_psnr_delta_vs_non_ash_db"
                ],
                mean_ms_ssim_delta_vs_conventional=objective[
                    "mean_ms_ssim_delta_vs_conventional"
                ],
                maximum_ringing_excursion=objective[
                    "maximum_ringing_excursion"
                ],
                maximum_alias_ratio=objective["maximum_alias_ratio"],
                estimated_dispatch_cost=objective["estimated_dispatch_cost"],
            )
        except (KeyError, TypeError, CalibrationSchedulerV2Error) as error:
            raise CalibrationPersistenceV2Error(
                "development evaluation cannot be decoded"
            ) from error

    def _required_source_gate_ids(self) -> Tuple[str, ...]:
        policy = self._authority_documents["candidate_evidence_policy_v2"]
        candidate_checks = policy.get("candidate_checks")
        if type(candidate_checks) is not dict:
            raise CalibrationPersistenceV2Error(
                "candidate-evidence policy checks are invalid"
            )
        required = candidate_checks.get(
            "fresh_current_source_gate_evidence_required"
        )
        if (
            type(required) is not list
            or not required
            or any(type(identifier) is not str or not identifier for identifier in required)
            or len(set(required)) != len(required)
        ):
            raise CalibrationPersistenceV2Error(
                "candidate-evidence policy source gates are invalid"
            )
        return tuple(required)

    @staticmethod
    def _typed_control_binding(value: object) -> TypedArtifactBindingV2:
        try:
            return TypedArtifactBindingV2.from_document(value)
        except ControlAuthorizationV2Error as error:
            raise CalibrationPersistenceV2Error(
                "candidate control authorization binding is invalid"
            ) from error

    def _verify_candidate_control_authorization(
        self,
        candidate: Mapping[str, object],
        *,
        shared_bank_sha256: str,
    ) -> _VerifiedCandidateControlClosureV2:
        """Capture and replay the candidate's exact typed control closure."""

        bundle_binding = self._typed_control_binding(
            candidate.get("control_authorization_bundle")
        )
        if (
            bundle_binding.artifact_kind != CONTROL_AUTHORIZATION_BUNDLE_KIND
            or bundle_binding.schema_sha256
            != schema_sha256_for_kind_v2(CONTROL_AUTHORIZATION_BUNDLE_KIND)
        ):
            raise CalibrationPersistenceV2Error(
                "candidate control authorization bundle type differs"
            )
        try:
            with self._store.authenticated_closure() as capture:
                bundle_payload = capture.capture(
                    bundle_binding.closure_binding(),
                    label="candidate control authorization bundle",
                )
                bundle = _parse_canonical_json_file(
                    bundle_payload,
                    label="candidate control authorization bundle",
                )
                raw_dependencies = bundle.get("dependency_bindings")
                if type(raw_dependencies) is not list:
                    raise CalibrationPersistenceV2Error(
                        "candidate control dependency bindings are absent"
                    )
                dependencies = tuple(
                    self._typed_control_binding(value)
                    for value in raw_dependencies
                )
                file_snapshots = [
                    ClosureFileSnapshotV2(
                        bundle_binding.closure_binding(),
                        bundle_payload,
                    )
                ]
                dependency_payloads: Dict[TypedArtifactBindingV2, bytes] = {}
                for dependency in dependencies:
                    payload = capture.capture(
                        dependency.closure_binding(),
                        label=(
                            "candidate control dependency "
                            f"{dependency.artifact_kind}"
                        ),
                    )
                    dependency_payloads[dependency] = payload
                    file_snapshots.append(
                        ClosureFileSnapshotV2(
                            dependency.closure_binding(),
                            payload,
                        )
                    )
                evidence_snapshot = AuthenticatedClosureSnapshotV2(
                    tuple(file_snapshots)
                )
        except (
            AuthenticatedClosureSnapshotV2Error,
            ControlAuthorizationV2Error,
        ) as error:
            raise CalibrationPersistenceV2Error(
                "candidate control closure capture failed"
            ) from error

        controls = bundle.get("control_selections")
        if any(
            bundle.get(field) != expected
            for field, expected in (
                ("artifact_kind", CONTROL_AUTHORIZATION_BUNDLE_KIND),
                ("run_id", candidate["run_id"]),
                ("split", candidate["split"]),
                (
                    "shared_bank_configuration_sha256",
                    shared_bank_sha256,
                ),
                (
                    "degradation_policy_sha256",
                    candidate["degradation_policy_sha256"],
                ),
                (
                    "source_profile_matrix_sha256",
                    candidate["source_profile_matrix_sha256"],
                ),
            )
        ):
            raise CalibrationPersistenceV2Error(
                "candidate control bundle scope differs"
            )
        non_ash_entries = (
            [
                entry
                for entry in controls
                if type(entry) is dict
                and entry.get("id") == "non_ash_selector"
            ]
            if type(controls) is list
            else []
        )
        if len(non_ash_entries) != 1 or set(non_ash_entries[0]) != {
            "id",
            "selection",
        }:
            raise CalibrationPersistenceV2Error(
                "candidate control bundle lacks one exact non-ASH selection"
            )
        non_ash_binding = self._typed_control_binding(
            non_ash_entries[0]["selection"]
        )
        if (
            non_ash_binding.artifact_kind != NON_ASH_SELECTION_KIND
            or non_ash_binding.schema_sha256
            != schema_sha256_for_kind_v2(NON_ASH_SELECTION_KIND)
            or non_ash_binding not in dependency_payloads
        ):
            raise CalibrationPersistenceV2Error(
                "candidate non-ASH selection binding differs"
            )
        non_ash_selection = _parse_json(
            dependency_payloads[non_ash_binding],
            label="candidate non-ASH control selection",
        )
        split = candidate["split"]
        expected_stage = (
            "development_provisional"
            if split == DEVELOPMENT_SPLIT
            else "validation_final"
        )
        cached_manifest_sha256 = non_ash_selection.get(
            "cached_16_operator_output_manifest_sha256"
        )
        cached_manifest_bindings = tuple(
            dependency
            for dependency in dependencies
            if dependency.artifact_kind == CACHED_OPERATOR_OUTPUT_MANIFEST_KIND
            and dependency.sha256 == cached_manifest_sha256
        )
        if (
            non_ash_selection.get("artifact_kind") != NON_ASH_SELECTION_KIND
            or non_ash_selection.get("split") != split
            or non_ash_selection.get("selection_stage") != expected_stage
            or len(cached_manifest_bindings) != 1
        ):
            raise CalibrationPersistenceV2Error(
                "candidate non-ASH selection scope differs"
            )

        validation_admission = None
        development_matrix_sha256 = None
        semantic_verifier = None
        if split == "validation":
            validation_admission = self._typed_control_binding(
                bundle.get("validation_admission")
            )
            development_matrix_sha256 = bundle.get(
                "development_source_profile_matrix_sha256"
            )
            semantic_verifier = (
                self.__validation_admission_semantic_verifier
            )
            if semantic_verifier is None:
                raise CalibrationPersistenceV2Error(
                    "validation candidate lacks the trusted admission reopener"
                )
        try:
            scope = ControlAuthorizationScopeV2(
                run_id=candidate["run_id"],
                split=split,
                shared_bank_configuration_sha256=shared_bank_sha256,
                degradation_policy_sha256=candidate[
                    "degradation_policy_sha256"
                ],
                source_profile_matrix_sha256=candidate[
                    "source_profile_matrix_sha256"
                ],
                development_source_profile_matrix_sha256=(
                    development_matrix_sha256
                ),
                validation_admission=validation_admission,
            )
            evaluation_scope = NonAshSelectorEvaluationScopeV2(
                shared_bank_configuration_sha256=shared_bank_sha256,
                degradation_policy_sha256=candidate[
                    "degradation_policy_sha256"
                ],
                calibration_plan_file_sha256=_PLAN_FILE_SHA256,
                cached_16_operator_output_manifest_sha256=(
                    cached_manifest_sha256
                ),
            )
            physical_candidate_items_bytes = canonical_json_bytes_v2(
                candidate["physical_candidate_items"]
            )
            if (
                _sha256(
                    canonical_json_bytes_v2(
                        [
                            item[1]
                            for item in candidate[
                                "physical_candidate_items"
                            ]
                        ]
                    )
                )
                != candidate["candidate_vector_sha256"]
            ):
                raise CalibrationPersistenceV2Error(
                    "candidate producer vector identity differs"
                )
            cache = getattr(
                capture,
                "_mirmir_candidate_control_authorization_cache_v2",
                None,
            )
            if cache is None:
                cache = {}
                setattr(
                    capture,
                    "_mirmir_candidate_control_authorization_cache_v2",
                    cache,
                )
            if type(cache) is not dict:
                raise CalibrationPersistenceV2Error(
                    "candidate control closure cache is invalid"
                )
            cache_key = (
                id(self),
                bundle_binding,
                dependencies,
                scope,
                evaluation_scope,
                physical_candidate_items_bytes,
                candidate["candidate_vector_sha256"],
                candidate["adapter_configuration_sha256"],
            )
            if cache_key not in cache:
                execution_semantic_verifier = None
                execution_producer_identity = None
                writer_semantic_verifier = None
                writer_producer_identity = None
                provider = self.__control_producer_capability_provider
                if provider is not None:
                    request = CandidateControlProducerRequestV2(
                        evidence_snapshot=evidence_snapshot,
                        bundle_binding=bundle_binding,
                        dependency_bindings=dependencies,
                        physical_candidate_items_bytes=(
                            physical_candidate_items_bytes
                        ),
                        candidate_vector_sha256=candidate[
                            "candidate_vector_sha256"
                        ],
                        authorization_scope=scope,
                        non_ash_evaluation_scope=evaluation_scope,
                    )
                    capabilities = provider(request)
                    authenticate_control_execution_producer_identity_authority_v2()
                    if (
                        type(capabilities)
                        is not CandidateControlProducerCapabilitiesV2
                        or capabilities.request is not request
                    ):
                        raise CalibrationPersistenceV2Error(
                            "candidate control producer capabilities differ"
                        )
                    execution_producer_identity = (
                        capabilities.control_execution_producer_identity
                    )
                    if (
                        execution_producer_identity.physical_candidate_items_bytes
                        != physical_candidate_items_bytes
                        or execution_producer_identity.candidate_vector_sha256
                        != candidate["candidate_vector_sha256"]
                        or execution_producer_identity.adapter_configuration_sha256
                        != candidate["adapter_configuration_sha256"]
                    ):
                        raise CalibrationPersistenceV2Error(
                            "candidate control producer identity differs"
                        )
                    execution_semantic_verifier = (
                        capabilities.control_execution_semantic_verifier
                    )
                    writer_semantic_verifier = (
                        capabilities.control_writer_semantic_verifier
                    )
                    writer_producer_identity = (
                        capabilities.control_writer_producer_identity
                    )
                self._control_authorization_verifier(
                    bundle_binding,
                    evidence_snapshot=evidence_snapshot,
                    expected_scope=scope,
                    non_ash_profile=self.non_ash_profile,
                    non_ash_evaluation_scope=evaluation_scope,
                    validation_admission_semantic_verifier=(
                        semantic_verifier
                    ),
                    control_execution_semantic_verifier=(
                        execution_semantic_verifier
                    ),
                    control_writer_semantic_verifier=(
                        writer_semantic_verifier
                    ),
                    control_execution_producer_identity=(
                        execution_producer_identity
                    ),
                    control_writer_producer_identity=(
                        writer_producer_identity
                    ),
                )
                cache[cache_key] = True
        except (
            ControlAuthorizationV2Error,
            NonAshSelectorV2Error,
            TypeError,
        ) as error:
            raise CalibrationPersistenceV2Error(
                "candidate control authorization replay failed"
            ) from error
        return _VerifiedCandidateControlClosureV2(
            bundle_binding=bundle_binding,
            dependency_bindings=dependencies,
        )

    @_authenticated_calibration_replay
    def verify_candidate_evaluation(
        self,
        document: Mapping[str, object],
        *,
        binding: Optional[ArtifactBindingV2] = None,
        expected_run_id: Optional[str] = None,
        expected_split: Optional[str] = None,
        expected_candidate_vector_sha256: Optional[str] = None,
    ) -> VerifiedCandidateEvaluationV2:
        """Validate one candidate-evaluation artifact and derive its identities."""

        snapshot = _snapshot_json(document, label="candidate evaluation")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error(
                "candidate evaluation is not an object"
            )
        _validate_schema_document(
            snapshot,
            self._schemas["candidate-evaluation-v2"],
            label="candidate evaluation",
        )
        self._validate_authority_bindings(snapshot)
        self._validate_artifact_self_hash(snapshot)
        candidate = self._physical_candidate(snapshot["physical_candidate_items"])
        candidate_sha256 = candidate_vector_sha256_v2(candidate, self.plan)
        shared_sha256 = shared_bank_configuration_sha256_v2(candidate, self.plan)
        split = snapshot["split"]
        evaluation = snapshot["evaluation"]
        semantic_sha256 = evaluation_semantic_sha256_v2(evaluation)
        cache_identity = snapshot["evaluation_cache_identity"]
        if (
            snapshot["candidate_vector_sha256"] != candidate_sha256
            or snapshot["shared_bank_configuration_sha256"] != shared_sha256
            or cache_identity
            != {
                "split": split,
                "candidate_vector_sha256": candidate_sha256,
                "calibration_plan_v2_file_sha256": _PLAN_FILE_SHA256,
            }
            or snapshot["evaluation_semantic_sha256"] != semantic_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "candidate evaluation identities differ from recomputation"
            )
        control_closure = self._verify_candidate_control_authorization(
            snapshot,
            shared_bank_sha256=shared_sha256,
        )
        check_ids = [check["check_id"] for check in snapshot["checks"]]
        if len(set(check_ids)) != len(check_ids):
            raise CalibrationPersistenceV2Error(
                "candidate evaluation check IDs repeat"
            )
        failed_check_ids = tuple(
            check["check_id"]
            for check in snapshot["checks"]
            if check["status"] == "fail"
        )
        feasible = evaluation["feasible"]
        evaluation_status = snapshot["evaluation_status"]
        if feasible or evaluation_status == "feasible":
            if (
                feasible is not True
                or evaluation_status != "feasible"
                or failed_check_ids
            ):
                raise CalibrationPersistenceV2Error(
                    "feasible candidate evaluation contains a failed check"
                )
        elif not failed_check_ids:
            raise CalibrationPersistenceV2Error(
                "infeasible candidate evaluation lacks a failed check"
            )
        if evaluation_status == "infeasible" and not evaluation["failure_reasons"]:
            raise CalibrationPersistenceV2Error(
                "infeasible candidate evaluation lacks failure reasons"
            )
        if split == DEVELOPMENT_SPLIT and evaluation_status == "infeasible":
            try:
                canonical_failures = canonical_development_failure_reasons_v2(
                    tuple(evaluation["failure_reasons"])
                )
            except CalibrationSchedulerV2Error as error:
                raise CalibrationPersistenceV2Error(
                    "development evaluation failure reasons are not canonicalizable"
                ) from error
            if not canonical_failures:
                raise CalibrationPersistenceV2Error(
                    "development evaluation canonical failure reasons are empty"
                )
        source_ids = [
            source["id"] for source in snapshot["source_evidence_sha256_bindings"]
        ]
        if tuple(source_ids) != self._required_source_gate_ids():
            raise CalibrationPersistenceV2Error(
                "candidate source evidence IDs differ from the authenticated policy"
            )
        for source in snapshot["source_evidence_sha256_bindings"]:
            self._reopen_relative_file_binding(
                source,
                label=f"candidate source evidence {source['id']}",
                includes_id=True,
            )
        if snapshot["evidence_sha256"] != candidate_evidence_sha256_v2(snapshot):
            raise CalibrationPersistenceV2Error(
                "candidate complete-evidence SHA-256 differs"
            )
        if expected_run_id is not None and snapshot["run_id"] != expected_run_id:
            raise CalibrationPersistenceV2Error(
                "candidate evaluation run identity differs"
            )
        if expected_split is not None and split != expected_split:
            raise CalibrationPersistenceV2Error(
                "candidate evaluation split differs"
            )
        if (
            expected_candidate_vector_sha256 is not None
            and candidate_sha256 != expected_candidate_vector_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "candidate evaluation candidate identity differs"
            )
        development_evaluation = (
            self._development_evaluation(evaluation)
            if split == DEVELOPMENT_SPLIT
            else None
        )
        if binding is None:
            payload = canonical_json_file_bytes_v2(snapshot)
            digest = _sha256(payload)
            binding = ArtifactBindingV2(
                path=f"evaluations/{digest}.json",
                sha256=digest,
                size_bytes=len(payload),
            )
        else:
            self._validate_content_addressed_document_binding(
                snapshot,
                binding,
                directory="evaluations",
            )
        return VerifiedCandidateEvaluationV2(
            binding=binding,
            document=snapshot,
            run_id=snapshot["run_id"],
            split=split,
            candidate_vector_sha256=candidate_sha256,
            adapter_configuration_sha256=snapshot[
                "adapter_configuration_sha256"
            ],
            physical_candidate_items=tuple(candidate.items()),
            shared_bank_configuration_sha256=shared_sha256,
            evaluation_semantic_sha256=semantic_sha256,
            control_authorization_bundle_binding=(
                control_closure.bundle_binding
            ),
            control_dependency_bindings=(
                control_closure.dependency_bindings
            ),
            development_evaluation=development_evaluation,
        )

    def publish_candidate_evaluation(
        self,
        document: Mapping[str, object],
    ) -> ArtifactBindingV2:
        verified = self.verify_candidate_evaluation(document)
        payload = canonical_json_file_bytes_v2(verified.document)
        binding = self._store.publish_content_addressed("evaluations", payload)
        reopened = self.reopen_candidate_evaluation(binding)
        if reopened.document != verified.document:
            raise CalibrationPersistenceV2Error(
                "candidate evaluation changed after publication"
            )
        return binding

    @_authenticated_calibration_replay
    def reopen_candidate_evaluation(
        self,
        binding: ArtifactBindingV2,
        *,
        expected_run_id: Optional[str] = None,
        expected_split: Optional[str] = None,
        expected_candidate_vector_sha256: Optional[str] = None,
    ) -> VerifiedCandidateEvaluationV2:
        payload, identity = self._store._reopen_content_addressed_snapshot(
            binding
        )
        document = _parse_canonical_json_file(
            payload,
            label="candidate evaluation",
        )
        verified = self.verify_candidate_evaluation(
            document,
            binding=binding,
            expected_run_id=expected_run_id,
            expected_split=expected_split,
            expected_candidate_vector_sha256=expected_candidate_vector_sha256,
        )
        if verified.binding != binding:
            raise CalibrationPersistenceV2Error(
                "candidate evaluation binding changed"
            )
        self._store.require_content_addressed_snapshot_stable(
            binding,
            payload=payload,
            identity=identity,
            label="candidate evaluation",
        )
        return verified

    def _reopen_applicable_failure_binding(
        self,
        document: object,
        *,
        label: str,
    ) -> Optional[FileBindingV2]:
        if type(document) is not dict or set(document) != {
            "applicable",
            "binding",
        }:
            raise CalibrationPersistenceV2Error(
                f"{label} applicability object is invalid"
            )
        applicable = document["applicable"]
        if type(applicable) is not bool:
            raise CalibrationPersistenceV2Error(
                f"{label} applicability flag is invalid"
            )
        if not applicable:
            if document["binding"] is not None:
                raise CalibrationPersistenceV2Error(
                    f"{label} has a non-null inapplicable binding"
                )
            return None
        if document["binding"] is None:
            raise CalibrationPersistenceV2Error(
                f"{label} lacks its applicable binding"
            )
        return self._reopen_relative_file_binding(
            document["binding"],
            label=label,
        )

    def _validate_failure_relations_and_reopen(
        self,
        snapshot: Mapping[str, object],
        *,
        expected_attempt_ledger_binding: Optional[FileBindingV2] = None,
        expected_artifact_manifest_binding: Optional[FileBindingV2] = None,
    ) -> None:
        stage = snapshot["failure_stage"]
        failure_type = snapshot["failure_type"]
        candidate_sha256 = snapshot["candidate_vector_sha256"]
        shared_bank_sha256 = snapshot["shared_bank_configuration_sha256"]
        reasons = snapshot["failure_reasons"]
        if stage == "authority_authentication":
            if candidate_sha256 is not None or shared_bank_sha256 is not None:
                raise CalibrationPersistenceV2Error(
                    "authority-authentication failure has an instance identity"
                )
        elif (
            not _is_sha256(candidate_sha256, nonzero=True)
            or not _is_sha256(shared_bank_sha256, nonzero=True)
        ):
            raise CalibrationPersistenceV2Error(
                "post-authority failure lacks an instance identity"
            )
        if failure_type == "evaluation":
            if (
                type(reasons) is not list
                or not reasons
                or any(type(reason) is not str or not reason for reason in reasons)
                or len(set(reasons)) != len(reasons)
            ):
                raise CalibrationPersistenceV2Error(
                    "evaluation failure reasons are invalid"
                )
        elif reasons != []:
            raise CalibrationPersistenceV2Error(
                "non-evaluation failure contains failure reasons"
            )

        failure_bindings = snapshot["failure_bindings"]
        reopened_bindings = {
            name: self._reopen_applicable_failure_binding(
                failure_bindings[name],
                label=f"failure {name.replace('_', ' ')}",
            )
            for name in (
                "attempt_ledger",
                "trace_evidence",
                "artifact_manifest",
                "cleanup_evidence",
                "recovery_evidence",
            )
        }
        if (
            expected_attempt_ledger_binding is not None
            and reopened_bindings["attempt_ledger"]
            != expected_attempt_ledger_binding
        ):
            raise CalibrationPersistenceV2Error(
                "failure attempt-ledger binding differs from enclosing run"
            )
        if (
            expected_artifact_manifest_binding is not None
            and reopened_bindings["artifact_manifest"]
            != expected_artifact_manifest_binding
        ):
            raise CalibrationPersistenceV2Error(
                "failure artifact-manifest binding differs from enclosing run"
            )
        recovery = snapshot["recovery"]
        resume_source = self._reopen_applicable_failure_binding(
            recovery["resume_source"],
            label="failure resume source",
        )
        cleanup = snapshot["cleanup"]
        cleanup_applicable = reopened_bindings["cleanup_evidence"] is not None
        if cleanup["invoked"] != cleanup_applicable:
            raise CalibrationPersistenceV2Error(
                "failure cleanup invocation and evidence applicability differ"
            )
        if cleanup["invoked"] and not cleanup["completed"]:
            raise CalibrationPersistenceV2Error(
                "invoked failure cleanup is incomplete"
            )

        nonresumable = (
            not recovery["resume_allowed"]
            and recovery["recovery_stage"] == "none"
            and resume_source is None
        )
        if failure_type == "constraint":
            if stage != "development_search":
                raise CalibrationPersistenceV2Error(
                    "constraint failure stage differs"
                )
            attempt_binding = reopened_bindings["attempt_ledger"]
            if (
                not recovery["resume_allowed"]
                or recovery["recovery_stage"] != "resume_development_search"
                or resume_source is None
                or attempt_binding is None
                or resume_source != attempt_binding
            ):
                raise CalibrationPersistenceV2Error(
                    "constraint failure resume lineage differs"
                )
        elif failure_type == "evaluation":
            expected_recovery_stage = {
                "development_search": "resume_development_search",
                "validation_selection": "rerun_validation_selection",
            }.get(stage)
            if (
                expected_recovery_stage is None
                or not recovery["resume_allowed"]
                or recovery["recovery_stage"] != expected_recovery_stage
                or resume_source is None
                or reopened_bindings["trace_evidence"] is None
            ):
                raise CalibrationPersistenceV2Error(
                    "evaluation failure recovery relation differs"
                )
        elif failure_type == "evidence_integrity":
            if not nonresumable:
                raise CalibrationPersistenceV2Error(
                    "evidence-integrity failure is resumable"
                )
            if (
                reopened_bindings["trace_evidence"] is None
                or reopened_bindings["artifact_manifest"] is None
                or (
                    stage != "authority_authentication"
                    and reopened_bindings["attempt_ledger"] is None
                )
            ):
                raise CalibrationPersistenceV2Error(
                    "evidence-integrity failure lacks required evidence"
                )
        elif failure_type == "terminal":
            if stage not in {
                "development_search",
                "validation_admission",
                "validation_selection",
                "evidence_closure",
                "release_lock",
            }:
                raise CalibrationPersistenceV2Error(
                    "terminal failure stage differs"
                )
            if not nonresumable:
                raise CalibrationPersistenceV2Error(
                    "terminal failure is resumable"
                )
            if any(
                reopened_bindings[name] is None
                for name in (
                    "attempt_ledger",
                    "trace_evidence",
                    "artifact_manifest",
                )
            ):
                raise CalibrationPersistenceV2Error(
                    "terminal failure lacks required evidence"
                )
        else:
            raise CalibrationPersistenceV2Error("failure type is invalid")

    @_authenticated_calibration_replay
    def verify_failure_artifact(
        self,
        document: Mapping[str, object],
        *,
        binding: Optional[ArtifactBindingV2] = None,
        expected_run_id: Optional[str] = None,
        expected_candidate_vector_sha256: Optional[str] = None,
        expected_shared_bank_sha256: Optional[str] = None,
        expected_failure_type: Optional[str] = None,
        expected_failure_reasons: Optional[Sequence[str]] = None,
        expected_attempt_ledger_binding: Optional[FileBindingV2] = None,
        expected_artifact_manifest_binding: Optional[FileBindingV2] = None,
    ) -> Mapping[str, object]:
        snapshot = _snapshot_json(document, label="P06 failure artifact")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error(
                "P06 failure artifact is not an object"
            )
        _validate_schema_document(
            snapshot,
            self._schemas["p06-calibration-failure-v2"],
            label="P06 failure artifact",
        )
        self._validate_authority_bindings(snapshot)
        self._validate_artifact_self_hash(snapshot)
        self._validate_failure_relations_and_reopen(
            snapshot,
            expected_attempt_ledger_binding=expected_attempt_ledger_binding,
            expected_artifact_manifest_binding=(
                expected_artifact_manifest_binding
            ),
        )
        if expected_run_id is not None and snapshot["run_id"] != expected_run_id:
            raise CalibrationPersistenceV2Error("failure run identity differs")
        if (
            expected_candidate_vector_sha256 is not None
            and snapshot["candidate_vector_sha256"]
            != expected_candidate_vector_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "failure candidate identity differs"
            )
        if (
            expected_shared_bank_sha256 is not None
            and snapshot["shared_bank_configuration_sha256"]
            != expected_shared_bank_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "failure shared-bank identity differs"
            )
        if (
            expected_failure_type is not None
            and snapshot["failure_type"] != expected_failure_type
        ):
            raise CalibrationPersistenceV2Error("failure type differs")
        if expected_failure_reasons is not None:
            if type(expected_failure_reasons) not in {list, tuple}:
                raise CalibrationPersistenceV2Error(
                    "expected failure reasons are not concrete"
                )
            if snapshot["failure_reasons"] != list(expected_failure_reasons):
                raise CalibrationPersistenceV2Error(
                    "failure reasons differ"
                )
        if binding is not None:
            self._validate_content_addressed_document_binding(
                snapshot,
                binding,
                directory="failures",
            )
        return snapshot

    def publish_failure_artifact(
        self,
        document: Mapping[str, object],
    ) -> ArtifactBindingV2:
        verified = self.verify_failure_artifact(document)
        payload = canonical_json_file_bytes_v2(verified)
        binding = self._store.publish_content_addressed("failures", payload)
        reopened = self.reopen_failure_artifact(binding)
        if reopened != verified:
            raise CalibrationPersistenceV2Error(
                "failure artifact changed after publication"
            )
        return binding

    @_authenticated_calibration_replay
    def reopen_failure_artifact(
        self,
        binding: ArtifactBindingV2,
        *,
        expected_run_id: Optional[str] = None,
        expected_candidate_vector_sha256: Optional[str] = None,
        expected_shared_bank_sha256: Optional[str] = None,
        expected_failure_type: Optional[str] = None,
        expected_failure_reasons: Optional[Sequence[str]] = None,
        expected_attempt_ledger_binding: Optional[FileBindingV2] = None,
        expected_artifact_manifest_binding: Optional[FileBindingV2] = None,
    ) -> Mapping[str, object]:
        payload, identity = self._store._reopen_content_addressed_snapshot(
            binding
        )
        document = _parse_canonical_json_file(payload, label="P06 failure artifact")
        verified = self.verify_failure_artifact(
            document,
            binding=binding,
            expected_run_id=expected_run_id,
            expected_candidate_vector_sha256=expected_candidate_vector_sha256,
            expected_shared_bank_sha256=expected_shared_bank_sha256,
            expected_failure_type=expected_failure_type,
            expected_failure_reasons=expected_failure_reasons,
            expected_attempt_ledger_binding=expected_attempt_ledger_binding,
            expected_artifact_manifest_binding=(
                expected_artifact_manifest_binding
            ),
        )
        self._store.require_content_addressed_snapshot_stable(
            binding,
            payload=payload,
            identity=identity,
            label="P06 failure artifact",
        )
        return verified

    @staticmethod
    def _artifact_binding(document: object) -> Optional[ArtifactBindingV2]:
        if document is None:
            return None
        if type(document) is not dict or set(document) != {
            "path",
            "sha256",
            "size_bytes",
        }:
            raise CalibrationPersistenceV2Error("artifact binding object is invalid")
        try:
            return ArtifactBindingV2(
                path=document["path"],
                sha256=document["sha256"],
                size_bytes=document["size_bytes"],
            )
        except CalibrationSchedulerV2Error as error:
            raise CalibrationPersistenceV2Error("artifact binding is invalid") from error

    def encode_attempt_record(
        self,
        record: AttemptRecordV2,
        *,
        run_id: str,
    ) -> Mapping[str, object]:
        """Encode one scheduler record into the exact attempt-record schema."""

        if type(run_id) is not str or not run_id:
            raise CalibrationPersistenceV2Error("attempt run ID is invalid")
        try:
            if attempt_record_sha256_v2(record) != record.record_sha256:
                raise CalibrationPersistenceV2Error(
                    "attempt semantic record hash differs"
                )
        except CalibrationSchedulerV2Error as error:
            raise CalibrationPersistenceV2Error(
                "attempt semantic record is invalid"
            ) from error
        physical = dict(record.physical_candidate_items)
        self._physical_candidate(
            [[name, value] for name, value in record.physical_candidate_items]
        )
        evaluation = None
        evaluation_semantic = None
        if record.evaluation is not None:
            evaluation = {
                "feasible": record.evaluation.feasible,
                "failure_reasons": list(record.evaluation.failure_reasons),
                "objective": {
                    "estimated_dispatch_cost": record.evaluation.estimated_dispatch_cost,
                    "maximum_alias_ratio": record.evaluation.maximum_alias_ratio,
                    "maximum_ringing_excursion": record.evaluation.maximum_ringing_excursion,
                    "mean_ms_ssim_delta_vs_conventional": (
                        record.evaluation.mean_ms_ssim_delta_vs_conventional
                    ),
                    "mean_y_psnr_delta_vs_fixed_db": (
                        record.evaluation.mean_y_psnr_delta_vs_fixed_db
                    ),
                    "mean_y_psnr_delta_vs_non_ash_db": (
                        record.evaluation.mean_y_psnr_delta_vs_non_ash_db
                    ),
                },
            }
            evaluation_semantic = evaluation_semantic_sha256_v2(evaluation)
        document = {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_calibration_attempt_record_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": run_id,
            "record_hash_domain": _ATTEMPT_RECORD_DOMAIN,
            "sequence": record.sequence,
            "previous_record_sha256": record.previous_record_sha256,
            "record_sha256": record.record_sha256,
            "split": record.split,
            "phase": record.phase,
            "sweep": record.sweep,
            "coordinate": record.coordinate,
            "value": record.value,
            "physical_candidate_items": [
                [name, value] for name, value in record.physical_candidate_items
            ],
            "candidate_vector_sha256": record.candidate_vector_sha256,
            "cache_identity": {
                "split": record.cache_identity.split,
                "candidate_vector_sha256": (
                    record.cache_identity.candidate_vector_sha256
                ),
                "calibration_plan_file_sha256": (
                    record.cache_identity.calibration_plan_file_sha256
                ),
            },
            "status": record.status,
            "cache_hit": record.cache_hit,
            "failure_reasons": list(record.failure_reasons),
            "canonical_failure_reasons": list(record.canonical_failure_reasons),
            "evaluation": evaluation,
            "evaluation_semantic_sha256": evaluation_semantic,
            "evaluation_artifact": (
                None
                if record.evaluation_artifact is None
                else {
                    "path": record.evaluation_artifact.path,
                    "sha256": record.evaluation_artifact.sha256,
                    "size_bytes": record.evaluation_artifact.size_bytes,
                }
            ),
            "failure_artifact": (
                None
                if record.failure_artifact is None
                else {
                    "path": record.failure_artifact.path,
                    "sha256": record.failure_artifact.sha256,
                    "size_bytes": record.failure_artifact.size_bytes,
                }
            ),
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(physical, self.plan)
            ),
            "data_access": {
                "development_accessed": True,
                "validation_accessed": False,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
        }
        self.decode_attempt_record(document, reopen_references=False)
        return document

    def decode_attempt_record(
        self,
        document: Mapping[str, object],
        *,
        expected_run_id: Optional[str] = None,
        reopen_references: bool = True,
    ) -> AttemptRecordV2:
        """Decode one schema-valid attempt into its scheduler semantic record."""

        snapshot = _snapshot_json(document, label="calibration attempt record")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error(
                "calibration attempt record is not an object"
            )
        _validate_schema_document(
            snapshot,
            self._schemas["calibration-attempt-record-v2"],
            label="calibration attempt record",
        )
        self._validate_authority_bindings(snapshot)
        if expected_run_id is not None and snapshot["run_id"] != expected_run_id:
            raise CalibrationPersistenceV2Error("attempt run identity differs")
        physical = self._physical_candidate(snapshot["physical_candidate_items"])
        candidate_sha256 = candidate_vector_sha256_v2(physical, self.plan)
        shared_sha256 = shared_bank_configuration_sha256_v2(physical, self.plan)
        if (
            snapshot["candidate_vector_sha256"] != candidate_sha256
            or snapshot["shared_bank_configuration_sha256"] != shared_sha256
            or snapshot["cache_identity"]
            != {
                "split": DEVELOPMENT_SPLIT,
                "candidate_vector_sha256": candidate_sha256,
                "calibration_plan_file_sha256": _PLAN_FILE_SHA256,
            }
        ):
            raise CalibrationPersistenceV2Error(
                "attempt candidate, cache, or shared-bank identity differs"
            )
        evaluation = (
            None
            if snapshot["evaluation"] is None
            else self._development_evaluation(snapshot["evaluation"])
        )
        if evaluation is None:
            if snapshot["evaluation_semantic_sha256"] is not None:
                raise CalibrationPersistenceV2Error(
                    "attempt has an orphan evaluation semantic hash"
                )
        elif snapshot["evaluation_semantic_sha256"] != (
            evaluation_semantic_sha256_v2(snapshot["evaluation"])
        ):
            raise CalibrationPersistenceV2Error(
                "attempt evaluation semantic hash differs"
            )
        evaluation_artifact = self._artifact_binding(
            snapshot["evaluation_artifact"]
        )
        failure_artifact = self._artifact_binding(snapshot["failure_artifact"])
        try:
            record = AttemptRecordV2(
                sequence=snapshot["sequence"],
                previous_record_sha256=snapshot["previous_record_sha256"],
                record_sha256=snapshot["record_sha256"],
                split=snapshot["split"],
                phase=snapshot["phase"],
                sweep=snapshot["sweep"],
                coordinate=snapshot["coordinate"],
                value=snapshot["value"],
                physical_candidate_items=tuple(physical.items()),
                candidate_vector_sha256=candidate_sha256,
                cache_identity=EvaluationCacheIdentityV2(
                    split=DEVELOPMENT_SPLIT,
                    candidate_vector_sha256=candidate_sha256,
                    calibration_plan_file_sha256=_PLAN_FILE_SHA256,
                ),
                status=snapshot["status"],
                cache_hit=snapshot["cache_hit"],
                failure_reasons=tuple(snapshot["failure_reasons"]),
                canonical_failure_reasons=tuple(
                    snapshot["canonical_failure_reasons"]
                ),
                evaluation=evaluation,
                evaluation_artifact=evaluation_artifact,
                failure_artifact=failure_artifact,
            )
            if attempt_record_sha256_v2(record) != record.record_sha256:
                raise CalibrationPersistenceV2Error(
                    "attempt semantic hash differs"
                )
        except CalibrationSchedulerV2Error as error:
            raise CalibrationPersistenceV2Error(
                "attempt cannot be reconstructed"
            ) from error
        if reopen_references and evaluation_artifact is not None:
            reopened = self.reopen_candidate_evaluation(
                evaluation_artifact,
                expected_run_id=snapshot["run_id"],
                expected_split=DEVELOPMENT_SPLIT,
                expected_candidate_vector_sha256=candidate_sha256,
            )
            if (
                reopened.physical_candidate_items != tuple(physical.items())
                or reopened.shared_bank_configuration_sha256 != shared_sha256
                or reopened.evaluation_semantic_sha256
                != snapshot["evaluation_semantic_sha256"]
                or reopened.document["evaluation"] != snapshot["evaluation"]
            ):
                raise CalibrationPersistenceV2Error(
                    "attempt evaluation reference differs from reopened evidence"
                )
        if reopen_references and failure_artifact is not None:
            if snapshot["status"] != ATTEMPT_STATUS_EVALUATION_FAILURE:
                raise CalibrationPersistenceV2Error(
                    "non-evaluation failure carries a failure artifact"
                )
            self.reopen_failure_artifact(
                failure_artifact,
                expected_run_id=snapshot["run_id"],
                expected_candidate_vector_sha256=candidate_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="evaluation",
                expected_failure_reasons=snapshot["failure_reasons"],
            )
        return record

    def _attempt_documents_from_bytes(
        self,
        payload: bytes,
    ) -> Tuple[Mapping[str, object], ...]:
        if not payload or not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
            raise CalibrationPersistenceV2Error(
                "attempt ledger must end with exactly one LF"
            )
        if b"\r" in payload:
            raise CalibrationPersistenceV2Error("attempt ledger contains CR bytes")
        lines = payload.splitlines(keepends=True)
        if not lines or any(not line.endswith(b"\n") for line in lines):
            raise CalibrationPersistenceV2Error(
                "attempt ledger line termination is invalid"
            )
        documents = []
        for index, line in enumerate(lines):
            document = _parse_canonical_json_file(
                line,
                label=f"attempt ledger record {index}",
            )
            documents.append(document)
        return tuple(documents)

    @_authenticated_calibration_replay
    def verify_attempt_ledger_bytes(
        self,
        payload: bytes,
        *,
        binding: AttemptLedgerBindingV2,
        expected_run_id: str,
    ) -> VerifiedAttemptLedgerV2:
        if type(binding) is not AttemptLedgerBindingV2:
            raise CalibrationPersistenceV2Error(
                "attempt-ledger binding has wrong type"
            )
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise CalibrationPersistenceV2Error(
                "attempt-ledger bytes differ from binding"
            )
        documents = self._attempt_documents_from_bytes(payload)
        if len(documents) != binding.record_count:
            raise CalibrationPersistenceV2Error(
                "attempt-ledger record count differs"
            )
        records = tuple(
            self.decode_attempt_record(
                document,
                expected_run_id=expected_run_id,
                reopen_references=True,
            )
            for document in documents
        )
        if records[-1].record_sha256 != binding.last_record_sha256:
            raise CalibrationPersistenceV2Error(
                "attempt-ledger tail hash differs"
            )
        try:
            replay = replay_development_attempts_v2(
                self.plan,
                records,
                expected_attempt_count=binding.record_count,
                expected_last_record_sha256=binding.last_record_sha256,
            )
        except CalibrationSchedulerV2Error as error:
            raise CalibrationPersistenceV2Error(
                "attempt-ledger semantic replay failed"
            ) from error
        return VerifiedAttemptLedgerV2(
            binding=binding,
            documents=documents,
            records=records,
            replay=replay,
        )

    def publish_attempt_records(
        self,
        records: Sequence[AttemptRecordV2],
        *,
        run_id: str,
    ) -> AttemptLedgerBindingV2:
        if type(records) not in {list, tuple} or not records:
            raise CalibrationPersistenceV2Error(
                "attempt records are not a nonempty concrete sequence"
            )
        documents = tuple(
            self.encode_attempt_record(record, run_id=run_id)
            for record in records
        )
        payload = b"".join(canonical_json_file_bytes_v2(item) for item in documents)
        binding = AttemptLedgerBindingV2(
            path="attempts-v2.ndjson",
            sha256=_sha256(payload),
            size_bytes=len(payload),
            record_count=len(documents),
            last_record_sha256=records[-1].record_sha256,
        )
        self.verify_attempt_ledger_bytes(
            payload,
            binding=binding,
            expected_run_id=run_id,
        )
        published = self._store.publish_fixed("attempts-v2.ndjson", payload)
        if (
            published.sha256 != binding.sha256
            or published.size_bytes != binding.size_bytes
        ):
            raise CalibrationPersistenceV2Error(
                "published attempt-ledger binding differs"
            )
        self.reopen_attempt_ledger(binding, expected_run_id=run_id)
        return binding

    @_authenticated_calibration_replay
    def reopen_attempt_ledger(
        self,
        binding: AttemptLedgerBindingV2,
        *,
        expected_run_id: str,
    ) -> VerifiedAttemptLedgerV2:
        payload = self._store.reopen_fixed(
            FileBindingV2(binding.path, binding.sha256, binding.size_bytes)
        )
        return self.verify_attempt_ledger_bytes(
            payload,
            binding=binding,
            expected_run_id=expected_run_id,
        )

    @staticmethod
    def _attempt_binding_from_document(document: object) -> AttemptLedgerBindingV2:
        if type(document) is not dict:
            raise CalibrationPersistenceV2Error(
                "run-ledger attempt binding is invalid"
            )
        try:
            return AttemptLedgerBindingV2(
                path=document["path"],
                sha256=document["sha256"],
                size_bytes=document["size_bytes"],
                record_count=document["record_count"],
                last_record_sha256=document["last_record_sha256"],
            )
        except (KeyError, CalibrationPersistenceV2Error) as error:
            raise CalibrationPersistenceV2Error(
                "run-ledger attempt binding is invalid"
            ) from error

    def _verify_input_bindings(self, document: Mapping[str, object]) -> None:
        actual = document["input_bindings"]
        expected = list(authority_input_bindings_v2())
        if actual != expected:
            raise CalibrationPersistenceV2Error(
                "run-ledger input bindings differ from exact authorities"
            )
        if document["input_bundle_sha256"] != input_bundle_sha256_v2(actual):
            raise CalibrationPersistenceV2Error(
                "run-ledger input-bundle identity differs"
            )

    @staticmethod
    def _control_file_binding(
        document: object,
        *,
        expected_id: str,
        expected_kind: str,
        expected_schema_sha256: str,
    ) -> FileBindingV2:
        expected_fields = {
            "id",
            "artifact_kind",
            "schema_sha256",
            "path",
            "sha256",
            "size_bytes",
        }
        if (
            type(document) is not dict
            or set(document) != expected_fields
            or document["id"] != expected_id
            or document["artifact_kind"] != expected_kind
            or document["schema_sha256"] != expected_schema_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "control-selection binding identity differs"
            )
        try:
            binding = FileBindingV2(
                path=document["path"],
                sha256=document["sha256"],
                size_bytes=document["size_bytes"],
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationPersistenceV2Error(
                "control-selection binding is invalid"
            ) from error
        if binding.path != f"controls/{binding.sha256}.json":
            raise CalibrationPersistenceV2Error(
                "control-selection path is not content addressed"
            )
        return binding

    @staticmethod
    def _verify_ranked_control_winner(
        document: Mapping[str, object],
        *,
        identity_field: str,
        chosen_field: str,
        expected_identities: Sequence[object],
        label: str,
    ) -> None:
        results = document.get("validation_results")
        if type(results) is not list:
            raise CalibrationPersistenceV2Error(
                f"{label} validation results are invalid"
            )
        identities = [row[identity_field] for row in results]
        if (
            len(identities) != len(expected_identities)
            or set(identities) != set(expected_identities)
            or len(set(identities)) != len(identities)
        ):
            raise CalibrationPersistenceV2Error(
                f"{label} validation candidate identities differ"
            )
        best_objective = max(
            tuple(row["engine_raw_corpus_mean_tuple"]) for row in results
        )
        expected_winner = min(
            row[identity_field]
            for row in results
            if tuple(row["engine_raw_corpus_mean_tuple"]) == best_objective
        )
        if document.get(chosen_field) != expected_winner:
            raise CalibrationPersistenceV2Error(
                f"{label} chosen validation winner differs"
            )

    @staticmethod
    def _verify_non_ash_control_winner(
        document: Mapping[str, object],
    ) -> None:
        if (
            document.get("selection_stage") != "validation_final"
            or document.get("split") != "validation"
            or document.get("validation_status") != "selected"
            or document.get("validation_selection_sha256")
            != _self_sha256_excluding(
                document,
                field="validation_selection_sha256",
            )
        ):
            raise CalibrationPersistenceV2Error(
                "non-ASH control final selection or self-hash differs"
            )
        results = document.get("validation_results")
        if type(results) is not list or len(results) != 163:
            raise CalibrationPersistenceV2Error(
                "non-ASH control validation coverage differs"
            )
        ordinals = [row["validation_candidate_ordinal"] for row in results]
        neighbor_sha256_values = [row["neighbor_entry_sha256"] for row in results]
        rule_sha256_values = [row["rule_sha256"] for row in results]
        if (
            ordinals != list(range(163))
            or len(set(neighbor_sha256_values)) != 163
            or len(set(rule_sha256_values)) != 163
        ):
            raise CalibrationPersistenceV2Error(
                "non-ASH control validation result identities differ"
            )
        coordinate_order = document["canonical_rule_serialization"][
            "coordinate_order"
        ]
        selected_values = document["selected_control_rule_values"]
        selected_rule_sha256 = _sha256(
            canonical_json_bytes_v2(
                dict(zip(coordinate_order, selected_values))
            )
        )
        if document["selected_control_rule_sha256"] != selected_rule_sha256:
            raise CalibrationPersistenceV2Error(
                "non-ASH selected control rule self-hash differs"
            )
        scored = [
            (row, row["outcome"])
            for row in results
            if row["outcome"]["outcome_type"] == "scored"
        ]
        selected_rows = [
            outcome
            for row, outcome in scored
            if row["rule_sha256"] == selected_rule_sha256
        ]
        if len(selected_rows) != 1 or not scored:
            raise CalibrationPersistenceV2Error(
                "non-ASH selected control does not identify one scored result"
            )
        best_objective = max(
            tuple(outcome["engine_raw_corpus_mean_tuple"])
            for _, outcome in scored
        )
        selected_outcome = selected_rows[0]
        if (
            tuple(selected_outcome["engine_raw_corpus_mean_tuple"])
            != best_objective
            or document["validation_objective_summary_sha256"]
            != selected_outcome["objective_summary_sha256"]
        ):
            raise CalibrationPersistenceV2Error(
                "non-ASH selected validation winner differs"
            )

    @_authenticated_calibration_replay
    def _verify_control_selection_artifacts(
        self,
        controls: object,
        *,
        expected_shared_bank_sha256: str,
    ) -> Tuple[FileBindingV2, ...]:
        if type(controls) is not list or len(controls) != 3:
            raise CalibrationPersistenceV2Error(
                "selection-ready run lacks exactly three controls"
            )
        bindings = []
        for entry, (identifier, kind, schema_name) in zip(
            controls,
            _CONTROL_SELECTION_SPECS,
        ):
            schema_sha256 = _SCHEMA_SPECS[schema_name][1]
            binding = self._control_file_binding(
                entry,
                expected_id=identifier,
                expected_kind=kind,
                expected_schema_sha256=schema_sha256,
            )
            payload = self._store.reopen_relative(
                binding,
                label=f"run-ledger control selection {identifier}",
            )
            document = _parse_canonical_json_file(
                payload,
                label=f"run-ledger control selection {identifier}",
            )
            _validate_schema_document(
                document,
                self._schemas[schema_name],
                label=f"run-ledger control selection {identifier}",
            )
            if (
                document.get("artifact_kind") != kind
                or document.get("selection_stage") != "validation_final"
                or document.get("shared_bank_configuration_sha256")
                != expected_shared_bank_sha256
            ):
                raise CalibrationPersistenceV2Error(
                    f"run-ledger control selection {identifier} scope differs"
                )
            if identifier == "best_fixed":
                self._verify_ranked_control_winner(
                    document,
                    identity_field="descriptor_id",
                    chosen_field="chosen_descriptor_id",
                    expected_identities=tuple(range(16)),
                    label="best-fixed control",
                )
            elif identifier == "conventional":
                self._verify_ranked_control_winner(
                    document,
                    identity_field="algorithm_id",
                    chosen_field="chosen_algorithm_id",
                    expected_identities=(
                        "bilinear-separable-v1",
                        "keys-cubic-a-minus-0.5-separable-v1",
                        "lanczos3-separable-v1",
                    ),
                    label="conventional control",
                )
            else:
                self._verify_non_ash_control_winner(document)
            bindings.append(binding)
        if (
            len(set(bindings)) != 3
            or len({binding.path for binding in bindings}) != 3
            or len({binding.sha256 for binding in bindings}) != 3
        ):
            raise CalibrationPersistenceV2Error(
                "control-selection bindings are aliased"
            )
        return tuple(bindings)

    @staticmethod
    def _failure_dependency_bindings(
        failure_binding: ArtifactBindingV2,
        failure: Mapping[str, object],
        *,
        run_manifest_binding: FileBindingV2,
    ) -> Tuple[Tuple[FileBindingV2, ...], bool]:
        dependencies = []
        binds_run_manifest = False
        for name, applicable in failure["failure_bindings"].items():
            if not applicable["applicable"]:
                continue
            binding = CalibrationPersistenceAdapterV2._relative_file_binding(
                applicable["binding"],
                label=f"failure {name.replace('_', ' ')}",
            )
            if name == "artifact_manifest" and binding == run_manifest_binding:
                binds_run_manifest = True
                continue
            dependencies.append(binding)
        resume_source = failure["recovery"]["resume_source"]
        if resume_source["applicable"]:
            binding = CalibrationPersistenceAdapterV2._relative_file_binding(
                resume_source["binding"],
                label="failure resume source",
            )
            if binding != run_manifest_binding:
                dependencies.append(binding)
        if not binds_run_manifest:
            dependencies.append(
                FileBindingV2(
                    failure_binding.path,
                    failure_binding.sha256,
                    failure_binding.size_bytes,
                )
            )
        return tuple(dependencies), binds_run_manifest

    @_authenticated_calibration_replay
    def _verify_run_artifact_manifest(
        self,
        manifest_binding: FileBindingV2,
        *,
        required_bindings: Sequence[FileBindingV2],
        cycle_excluded_failure_paths: Sequence[str],
    ) -> Mapping[str, object]:
        payload, manifest_identity = self._store._reopen_relative_snapshot(
            manifest_binding,
            label="run-ledger artifact manifest",
        )
        document = _parse_canonical_json_file(
            payload,
            label="run-ledger artifact manifest",
        )
        _validate_schema_document(
            document,
            self._schemas["evidence-wrapper-artifact-manifest-v2"],
            label="run-ledger artifact manifest",
        )
        rows = document["artifacts"]
        row_paths = [row["path"] for row in rows]
        row_sha256_values = [row["sha256"] for row in rows]
        forbidden_paths = {
            manifest_binding.path,
            "calibration-run-ledger-v2.json",
            *cycle_excluded_failure_paths,
        }
        if (
            row_paths != sorted(row_paths)
            or len(set(row_paths)) != len(row_paths)
            or len(set(row_sha256_values)) != len(row_sha256_values)
            or set(row_paths) & forbidden_paths
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest rows are duplicated, aliased, "
                "unordered, or contain a circular record"
            )
        directories = document["directories"]
        if directories != sorted(directories):
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest directories are unordered"
            )
        expected_directories = set()
        for path in row_paths:
            parts = PurePosixPath(path).parts
            for depth in range(1, len(parts)):
                expected_directories.add(
                    PurePosixPath(*parts[:depth]).as_posix()
                )
        if expected_directories != set(directories):
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest directory closure differs"
            )
        row_by_path: Dict[str, FileBindingV2] = {}
        row_snapshots = []
        for row in rows:
            try:
                binding = FileBindingV2(
                    row["path"],
                    row["sha256"],
                    row["size_bytes"],
                )
            except CalibrationPersistenceV2Error as error:
                raise CalibrationPersistenceV2Error(
                    "run-ledger artifact manifest row is invalid"
                ) from error
            row_payload, row_identity = self._store._reopen_relative_snapshot(
                binding,
                label=f"run-ledger manifest artifact {binding.path}",
            )
            row_snapshots.append((binding, row_payload, row_identity))
            row_by_path[binding.path] = binding
        required_by_path: Dict[str, FileBindingV2] = {}
        for binding in required_bindings:
            prior = required_by_path.get(binding.path)
            if prior is not None and prior != binding:
                raise CalibrationPersistenceV2Error(
                    "run dependency path identifies different bytes"
                )
            required_by_path[binding.path] = binding
        if row_by_path != required_by_path:
            missing = sorted(set(required_by_path) - set(row_by_path))
            extra = sorted(set(row_by_path) - set(required_by_path))
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest dependency closure differs: "
                f"missing={missing}, extra={extra}"
            )
        for row_binding, row_payload, row_identity in row_snapshots:
            self._store.require_relative_snapshot_stable(
                row_binding,
                payload=row_payload,
                identity=row_identity,
                label=f"run-ledger manifest artifact {row_binding.path}",
            )
        self._store.require_relative_snapshot_stable(
            manifest_binding,
            payload=payload,
            identity=manifest_identity,
            label="run-ledger artifact manifest",
        )
        return document

    def publish_run_artifact_manifest(
        self,
        document: Mapping[str, object],
    ) -> FileBindingV2:
        """Publish or exactly reopen the dependency-only run manifest.

        The run ledger deliberately excludes itself and this manifest from the
        manifest's artifact rows to avoid a self-reference cycle.  Complete
        dependency closure is enforced when ``publish_run_ledger`` reopens it.
        """

        snapshot = _snapshot_json(document, label="run-ledger artifact manifest")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest is not an object"
            )
        _validate_schema_document(
            snapshot,
            self._schemas["evidence-wrapper-artifact-manifest-v2"],
            label="run-ledger artifact manifest",
        )
        payload = canonical_json_file_bytes_v2(snapshot)
        binding = FileBindingV2(
            "artifact-manifest-v2.json",
            _sha256(payload),
            len(payload),
        )
        descriptor = self._store._open_root()
        try:
            self._store._publish_at(
                descriptor,
                binding.path,
                payload,
                label="run-ledger artifact manifest",
            )
            reopened = self._store._read_at(
                descriptor,
                binding.path,
                label="run-ledger artifact manifest",
            )
        finally:
            os.close(descriptor)
        if reopened != payload:
            raise CalibrationPersistenceV2Error(
                "run-ledger artifact manifest changed after publication"
            )
        return binding

    @_authenticated_calibration_replay
    def verify_run_ledger_declared_relations(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        """Verify schema-owned counts, identity sets, and access separation."""

        snapshot = _snapshot_json(document, label="calibration run ledger")
        if type(snapshot) is not dict:
            raise CalibrationPersistenceV2Error(
                "calibration run ledger is not an object"
            )
        _validate_schema_document(
            snapshot,
            self._schemas["calibration-run-ledger-v2"],
            label="calibration run ledger",
        )
        self._validate_authority_bindings(snapshot)
        self._validate_artifact_self_hash(snapshot)
        self._verify_input_bindings(snapshot)
        entries = snapshot["candidate_evaluations"]
        if (
            snapshot["candidate_evaluation_count"] != len(entries)
            or snapshot["candidate_evaluation_identity_set_sha256"]
            != candidate_evaluation_identity_set_sha256_v2(entries)
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger candidate-evaluation count or set identity differs"
            )
        failure_entries = snapshot["candidate_failures"]
        if (
            snapshot["candidate_failure_count"] != len(failure_entries)
            or snapshot["candidate_failure_identity_set_sha256"]
            != candidate_failure_identity_set_sha256_v2(failure_entries)
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger candidate-failure count or set identity differs"
            )
        cache_identities = [
            (entry["split"], entry["candidate_vector_sha256"])
            for entry in entries
        ]
        if len(set(cache_identities)) != len(cache_identities):
            raise CalibrationPersistenceV2Error(
                "candidate-evaluation cache identity repeats"
            )
        failure_identities = [
            (
                entry["split"],
                entry["candidate_vector_sha256"],
                entry["binding"]["sha256"],
            )
            for entry in failure_entries
        ]
        if len(set(failure_identities)) != len(failure_identities):
            raise CalibrationPersistenceV2Error(
                "candidate-failure artifact identity repeats"
            )
        validation_failure_cache_identities = [
            (split, candidate_sha256)
            for split, candidate_sha256, _ in failure_identities
            if split == "validation"
        ]
        if len(set(validation_failure_cache_identities)) != len(
            validation_failure_cache_identities
        ):
            raise CalibrationPersistenceV2Error(
                "validation candidate-failure cache identity repeats"
            )
        validation_evaluation_cache_identities = {
            identity
            for identity in cache_identities
            if identity[0] == "validation"
        }
        if validation_evaluation_cache_identities & set(
            validation_failure_cache_identities
        ):
            raise CalibrationPersistenceV2Error(
                "validation candidate evaluation and failure identities overlap"
            )
        validation_entry_count = sum(
            split == "validation" for split, _ in cache_identities
        )
        validation_failure_count = sum(
            split == "validation" for split, _, _ in failure_identities
        )
        if (
            validation_entry_count + validation_failure_count
            != snapshot["validation_attempt_count"]
        ):
            raise CalibrationPersistenceV2Error(
                "validation outcome count differs from validation attempts"
            )
        terminal_failure_binding = None
        terminal_failure = None
        if snapshot["run_status"] == "failed":
            if (
                snapshot["validation_attempt_count"] != 0
                or validation_entry_count != 0
                or validation_failure_count != 0
                or snapshot["data_access"]["validation_accessed"]
                or snapshot["data_separation"][
                    "validation_opened_after_development_freeze"
                ]
            ):
                raise CalibrationPersistenceV2Error(
                    "failed run violates development/validation separation"
                )
        elif (
            snapshot["validation_attempt_count"] < 1
            or validation_entry_count + validation_failure_count < 1
            or not snapshot["data_access"]["validation_accessed"]
            or not snapshot["data_separation"][
                "validation_opened_after_development_freeze"
            ]
        ):
            raise CalibrationPersistenceV2Error(
                "selection-ready run violates development/validation separation"
            )
        return snapshot

    @_authenticated_calibration_replay
    def verify_run_ledger(
        self,
        document: Mapping[str, object],
        *,
        binding: Optional[FileBindingV2] = None,
    ) -> VerifiedRunLedgerV2:
        """Verify a complete run ledger against all reopened development bytes."""

        snapshot = self.verify_run_ledger_declared_relations(document)
        if binding is not None:
            self._validate_fixed_document_binding(
                snapshot,
                binding,
                path="calibration-run-ledger-v2.json",
            )
        artifact_manifest_binding = self._relative_file_binding(
            snapshot["artifact_manifest"],
            label="run-ledger artifact manifest",
        )
        validation_admission_binding = None
        if snapshot["validation_admission"] is not None:
            validation_admission_binding = self._reopen_relative_file_binding(
                snapshot["validation_admission"],
                label="run-ledger validation admission",
            )
        attempt_binding = self._attempt_binding_from_document(
            snapshot["attempt_ledger"]
        )
        attempt_ledger = self.reopen_attempt_ledger(
            attempt_binding,
            expected_run_id=snapshot["run_id"],
        )
        replay = attempt_ledger.replay
        if (
            snapshot["attempt_count"] != len(attempt_ledger.records)
            or snapshot["development_attempt_count"]
            != len(attempt_ledger.records)
            or snapshot["completed_sweeps"] != replay.completed_sweeps
            or snapshot["development_status"] != replay.status
            or snapshot["development_terminal_candidate_vector_sha256"]
            != replay.incumbent_candidate_sha256
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger development trace summary differs from replay"
            )
        if replay.incumbent_physical_candidate_items is not None:
            run_shared = shared_bank_configuration_sha256_v2(
                dict(replay.incumbent_physical_candidate_items),
                self.plan,
            )
        else:
            run_shared = shared_bank_configuration_sha256_v2(
                dict(attempt_ledger.records[-1].physical_candidate_items),
                self.plan,
            )
        if snapshot["shared_bank_configuration_sha256"] != run_shared:
            raise CalibrationPersistenceV2Error(
                "run-ledger shared-bank identity differs from replay"
            )
        entries = snapshot["candidate_evaluations"]
        if (
            snapshot["candidate_evaluation_count"] != len(entries)
            or snapshot["candidate_evaluation_identity_set_sha256"]
            != candidate_evaluation_identity_set_sha256_v2(entries)
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger candidate-evaluation count or set identity differs"
            )
        reopened_evaluations = []
        entry_by_identity: Dict[Tuple[str, str], ArtifactBindingV2] = {}
        for entry in entries:
            artifact = self._artifact_binding(entry["binding"])
            if artifact is None:
                raise CalibrationPersistenceV2Error(
                    "candidate-evaluation entry binding is null"
                )
            key = (entry["split"], entry["candidate_vector_sha256"])
            if key in entry_by_identity:
                raise CalibrationPersistenceV2Error(
                    "candidate-evaluation cache identity repeats"
                )
            entry_by_identity[key] = artifact
            reopened_evaluations.append(
                self.reopen_candidate_evaluation(
                    artifact,
                    expected_run_id=snapshot["run_id"],
                    expected_split=entry["split"],
                    expected_candidate_vector_sha256=(
                        entry["candidate_vector_sha256"]
                    ),
                )
            )
        candidate_shared_by_sha256: Dict[str, str] = {}
        development_failure_references: Dict[
            str, Dict[ArtifactBindingV2, Tuple[str, ...]]
        ] = {}
        for record in attempt_ledger.records:
            record_shared = shared_bank_configuration_sha256_v2(
                dict(record.physical_candidate_items),
                self.plan,
            )
            previous_shared = candidate_shared_by_sha256.get(
                record.candidate_vector_sha256
            )
            if previous_shared is not None and previous_shared != record_shared:
                raise CalibrationPersistenceV2Error(
                    "attempt candidate shared-bank identity changed"
                )
            candidate_shared_by_sha256[record.candidate_vector_sha256] = (
                record_shared
            )
            if record.status != ATTEMPT_STATUS_EVALUATION_FAILURE:
                continue
            if record.failure_artifact is None:
                raise CalibrationPersistenceV2Error(
                    "evaluation-failure attempt lacks its failure artifact"
                )
            references = development_failure_references.setdefault(
                record.candidate_vector_sha256,
                {},
            )
            reasons = tuple(record.failure_reasons)
            previous_reasons = references.get(record.failure_artifact)
            if previous_reasons is not None and previous_reasons != reasons:
                raise CalibrationPersistenceV2Error(
                    "development failure reasons changed for one artifact"
                )
            references[record.failure_artifact] = reasons

        failure_entries = snapshot["candidate_failures"]
        if (
            snapshot["candidate_failure_count"] != len(failure_entries)
            or snapshot["candidate_failure_identity_set_sha256"]
            != candidate_failure_identity_set_sha256_v2(failure_entries)
        ):
            raise CalibrationPersistenceV2Error(
                "run-ledger candidate-failure count or set identity differs"
            )
        reopened_failures = []
        failure_entry_by_identity: Dict[
            Tuple[str, str], set[ArtifactBindingV2]
        ] = {}
        failure_artifact_identities: set[
            Tuple[str, str, ArtifactBindingV2]
        ] = set()
        for entry in failure_entries:
            artifact = self._artifact_binding(entry["binding"])
            if artifact is None:
                raise CalibrationPersistenceV2Error(
                    "candidate-failure entry binding is null"
                )
            key = (entry["split"], entry["candidate_vector_sha256"])
            artifact_identity = (*key, artifact)
            if artifact_identity in failure_artifact_identities:
                raise CalibrationPersistenceV2Error(
                    "candidate-failure artifact identity repeats"
                )
            if entry["split"] == "validation" and key in failure_entry_by_identity:
                raise CalibrationPersistenceV2Error(
                    "validation candidate-failure cache identity repeats"
                )
            if entry["split"] == "validation" and key in entry_by_identity:
                raise CalibrationPersistenceV2Error(
                    "validation candidate evaluation and failure identities overlap"
                )
            expected_reasons = None
            if entry["split"] == DEVELOPMENT_SPLIT:
                references = development_failure_references.get(
                    entry["candidate_vector_sha256"]
                )
                if references is None:
                    raise CalibrationPersistenceV2Error(
                        "run-ledger development failure set differs from attempts"
                    )
                expected_reasons = references.get(artifact)
                if expected_reasons is None:
                    raise CalibrationPersistenceV2Error(
                        "run-ledger development failure set differs from attempts"
                    )
            failure_artifact_identities.add(artifact_identity)
            failure_entry_by_identity.setdefault(key, set()).add(artifact)
            failure = self.reopen_failure_artifact(
                artifact,
                expected_run_id=snapshot["run_id"],
                expected_candidate_vector_sha256=entry[
                    "candidate_vector_sha256"
                ],
                expected_shared_bank_sha256=candidate_shared_by_sha256.get(
                    entry["candidate_vector_sha256"]
                ),
                expected_failure_type="evaluation",
                expected_failure_reasons=expected_reasons,
            )
            expected_stage = (
                "development_search"
                if entry["split"] == DEVELOPMENT_SPLIT
                else "validation_selection"
            )
            if failure["failure_stage"] != expected_stage:
                raise CalibrationPersistenceV2Error(
                    "candidate-failure stage differs from split"
                )
            reopened_failures.append(failure)
        development_references: Dict[str, ArtifactBindingV2] = {}
        for record in attempt_ledger.records:
            if record.evaluation_artifact is None:
                continue
            previous = development_references.get(record.candidate_vector_sha256)
            if previous is not None and previous != record.evaluation_artifact:
                raise CalibrationPersistenceV2Error(
                    "development evaluation reference changed for one cache identity"
                )
            development_references[record.candidate_vector_sha256] = (
                record.evaluation_artifact
            )
        ledger_development = {
            candidate_sha: artifact
            for (split, candidate_sha), artifact in entry_by_identity.items()
            if split == DEVELOPMENT_SPLIT
        }
        if ledger_development != development_references:
            raise CalibrationPersistenceV2Error(
                "run-ledger development evaluation set differs from attempts"
            )
        ledger_development_failures = {
            candidate_sha: frozenset(artifacts)
            for (split, candidate_sha), artifacts in failure_entry_by_identity.items()
            if split == DEVELOPMENT_SPLIT
        }
        expected_development_failures = {
            candidate_sha: frozenset(references)
            for candidate_sha, references in development_failure_references.items()
        }
        if ledger_development_failures != expected_development_failures:
            raise CalibrationPersistenceV2Error(
                "run-ledger development failure set differs from attempts"
            )
        validation_entry_count = sum(
            split == "validation" for split, _ in entry_by_identity
        )
        validation_failure_count = sum(
            entry["split"] == "validation" for entry in failure_entries
        )
        if (
            validation_entry_count + validation_failure_count
            != snapshot["validation_attempt_count"]
        ):
            raise CalibrationPersistenceV2Error(
                "validation outcome count differs from validation attempts"
            )
        terminal_failure_binding = None
        terminal_failure = None
        if snapshot["run_status"] == "failed":
            if (
                snapshot["validation_attempt_count"] != 0
                or validation_entry_count != 0
                or validation_failure_count != 0
                or snapshot["data_access"]["validation_accessed"]
                or snapshot["data_separation"][
                    "validation_opened_after_development_freeze"
                ]
            ):
                raise CalibrationPersistenceV2Error(
                    "failed run violates development/validation separation"
                )
            if snapshot["failure"] is None:
                raise CalibrationPersistenceV2Error(
                    "failed run lacks typed terminal failure"
                )
            terminal_failure_binding = self._artifact_binding(snapshot["failure"])
            if terminal_failure_binding is None:
                raise CalibrationPersistenceV2Error(
                    "failed run failure binding is null"
                )
            terminal_failure = self.reopen_failure_artifact(
                terminal_failure_binding,
                expected_run_id=snapshot["run_id"],
                expected_candidate_vector_sha256=(
                    replay.incumbent_candidate_sha256
                    or attempt_ledger.records[-1].candidate_vector_sha256
                ),
                expected_shared_bank_sha256=run_shared,
                expected_failure_type="terminal",
                expected_failure_reasons=(),
                expected_attempt_ledger_binding=FileBindingV2(
                    attempt_binding.path,
                    attempt_binding.sha256,
                    attempt_binding.size_bytes,
                ),
                expected_artifact_manifest_binding=(
                    artifact_manifest_binding
                ),
            )
            if terminal_failure["failure_stage"] != "development_search":
                raise CalibrationPersistenceV2Error(
                    "failed run terminal failure stage differs"
                )
        else:
            if replay.status != STATUS_TERMINATED_FEASIBLE:
                raise CalibrationPersistenceV2Error(
                    "selection-ready run lacks a feasible development replay"
                )
            if (
                snapshot["validation_attempt_count"] < 1
                or validation_entry_count + validation_failure_count < 1
                or not snapshot["data_access"]["validation_accessed"]
                or not snapshot["data_separation"][
                    "validation_opened_after_development_freeze"
                ]
                or snapshot["failure"] is not None
            ):
                raise CalibrationPersistenceV2Error(
                    "selection-ready run violates development/validation separation"
                )
        required_manifest_bindings = [
            FileBindingV2(
                attempt_binding.path,
                attempt_binding.sha256,
                attempt_binding.size_bytes,
            ),
        ]
        if validation_admission_binding is not None:
            required_manifest_bindings.append(validation_admission_binding)
        for evaluation in reopened_evaluations:
            required_manifest_bindings.append(
                FileBindingV2(
                    evaluation.binding.path,
                    evaluation.binding.sha256,
                    evaluation.binding.size_bytes,
                )
            )
            required_manifest_bindings.append(
                FileBindingV2(
                    evaluation.control_authorization_bundle_binding.path,
                    evaluation.control_authorization_bundle_binding.sha256,
                    evaluation.control_authorization_bundle_binding.size_bytes,
                )
            )
            for dependency in evaluation.control_dependency_bindings:
                required_manifest_bindings.append(
                    FileBindingV2(
                        dependency.path,
                        dependency.sha256,
                        dependency.size_bytes,
                    )
                )
            for source in evaluation.document[
                "source_evidence_sha256_bindings"
            ]:
                required_manifest_bindings.append(
                    self._relative_file_binding(
                        source,
                        label=f"candidate source evidence {source['id']}",
                        includes_id=True,
                    )
                )
        cycle_excluded_failure_paths = []
        for entry, failure in zip(
            failure_entries,
            reopened_failures,
        ):
            artifact = self._artifact_binding(entry["binding"])
            if artifact is None:
                raise AssertionError("verified failure binding became null")
            dependencies, binds_manifest = self._failure_dependency_bindings(
                artifact,
                failure,
                run_manifest_binding=artifact_manifest_binding,
            )
            required_manifest_bindings.extend(dependencies)
            if binds_manifest:
                cycle_excluded_failure_paths.append(artifact.path)
        if terminal_failure_binding is not None and terminal_failure is not None:
            dependencies, binds_manifest = self._failure_dependency_bindings(
                terminal_failure_binding,
                terminal_failure,
                run_manifest_binding=artifact_manifest_binding,
            )
            required_manifest_bindings.extend(dependencies)
            if binds_manifest:
                cycle_excluded_failure_paths.append(
                    terminal_failure_binding.path
                )
        self._verify_run_artifact_manifest(
            artifact_manifest_binding,
            required_bindings=required_manifest_bindings,
            cycle_excluded_failure_paths=cycle_excluded_failure_paths,
        )
        return VerifiedRunLedgerV2(
            binding=binding,
            document=snapshot,
            attempt_ledger=attempt_ledger,
            candidate_evaluations=tuple(reopened_evaluations),
            candidate_failures=tuple(reopened_failures),
        )

    def publish_run_ledger(
        self,
        document: Mapping[str, object],
    ) -> FileBindingV2:
        verified = self.verify_run_ledger(document)
        payload = canonical_json_file_bytes_v2(verified.document)
        binding = self._store.publish_fixed(
            "calibration-run-ledger-v2.json",
            payload,
        )
        self.reopen_run_ledger(binding)
        return binding

    @_authenticated_calibration_replay
    def reopen_run_ledger(
        self,
        binding: FileBindingV2,
    ) -> VerifiedRunLedgerV2:
        if binding.path != "calibration-run-ledger-v2.json":
            raise CalibrationPersistenceV2Error(
                "run-ledger binding path differs"
            )
        payload, identity = self._store._reopen_fixed_snapshot(binding)
        document = _parse_canonical_json_file(
            payload,
            label="calibration run ledger",
        )
        verified = self.verify_run_ledger(document, binding=binding)
        self._store.require_fixed_snapshot_stable(
            binding,
            payload=payload,
            identity=identity,
            label="calibration run ledger",
        )
        return verified


def publish_authority_authentication_failure_v2(
    root: Path,
    document: Mapping[str, object],
) -> ArtifactBindingV2:
    """Publish one failure without constructing an authenticated adapter.

    This restricted boundary exists only for the point at which authority
    authentication itself failed.  It authenticates the frozen failure schema,
    requires the exact preregistered authority triples, validates and reopens
    every applicable failure-evidence byte, and cannot publish a later-stage
    failure.
    """

    snapshot = _snapshot_json(
        document,
        label="authority-authentication failure artifact",
    )
    if type(snapshot) is not dict:
        raise CalibrationPersistenceV2Error(
            "authority-authentication failure artifact is not an object"
        )
    if (
        snapshot.get("failure_stage") != "authority_authentication"
        or snapshot.get("failure_type") != "evidence_integrity"
    ):
        raise CalibrationPersistenceV2Error(
            "pre-auth publication accepts only authority-authentication "
            "evidence-integrity failures"
        )

    verifier = object.__new__(CalibrationPersistenceAdapterV2)
    verifier._schemas = {
        "p06-calibration-failure-v2": _authenticate_schema_v2(
            "p06-calibration-failure-v2"
        )
    }
    verifier._store = _AtomicArtifactStoreV2(root)
    verified = verifier.verify_failure_artifact(snapshot)
    payload = canonical_json_file_bytes_v2(verified)
    binding = verifier._store.publish_content_addressed("failures", payload)
    reopened = verifier.reopen_failure_artifact(
        binding,
        expected_run_id=verified["run_id"],
        expected_failure_type="evidence_integrity",
        expected_failure_reasons=(),
    )
    if reopened != verified:
        raise CalibrationPersistenceV2Error(
            "authority-authentication failure changed after publication"
        )
    return binding
