"""Authenticated validation-admission and calibration-selection persistence V2."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple

import jsonschema

from validation.calibration_v2.calibration_plan_codec import (
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_persistence_v2 import (
    AttemptLedgerBindingV2,
    CalibrationPersistenceAdapterV2,
    CalibrationPersistenceV2Error,
    CandidateControlProducerCapabilitiesV2,
    CandidateControlProducerRequestV2,
    FileBindingV2,
    VerifiedAttemptLedgerV2,
    VerifiedCandidateEvaluationV2,
    VerifiedRunLedgerV2,
    _AtomicArtifactStoreV2,
    _parse_canonical_json_file,
    _read_regular_file,
    _sha256,
    _snapshot_json,
    _validate_schema_document,
    artifact_semantic_sha256_v2,
    authority_bindings_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    evaluation_semantic_sha256_v2,
    finalize_artifact_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    DEVELOPMENT_SPLIT,
    VALIDATION_SPLIT,
    ArtifactBindingV2,
    CalibrationSchedulerV2Error,
    DevelopmentCandidateEvidenceV2,
    ScoredValidationCandidateV2,
    ValidationAdmissionV2,
    ValidationCandidateV2,
    ValidationEvaluationFailureV2,
    ValidationEvaluationV2,
    ValidationSelectionV2,
    select_validation_candidate_v2,
    validation_admission_v2,
)
from validation.calibration_v2.control_authorization_v2 import (
    TypedArtifactBindingV2,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent

ADMISSION_PATH = "validation-candidate-development-evidence-v2.json"
SELECTION_PATH = "calibration-selection-v2.json"
IDENTITY_SET_CANONICALIZATION = (
    "ascending lowercase SHA-256 values serialized as canonical compact UTF-8 "
    "JSON array without trailing newline"
)
NEIGHBOR_GENERATION = {
    "adaptive_expansion_allowed": False,
    "complete_structural_replacements_including_terminal": 256,
    "constraint_filtering_precedes_admission": True,
    "maximum_candidate_count_before_constraint_filtering": 374,
    "noncurrent_scalar_replacements": 118,
    "terminal_candidate_must_be_admitted": True,
}
PARETO_DIMENSIONS = [
    {"direction": "descending", "field": "y_vs_fixed_ci_low"},
    {"direction": "descending", "field": "y_vs_non_ash_ci_low"},
    {"direction": "descending", "field": "y_vs_conventional_ci_low"},
    {
        "direction": "descending",
        "field": "mean_ms_ssim_delta_vs_conventional",
    },
    {"direction": "ascending", "field": "maximum_ringing_excursion"},
    {"direction": "ascending", "field": "maximum_alias_ratio"},
    {"direction": "ascending", "field": "estimated_dispatch_cost"},
]
SELECTION_TIE_BREAK = (
    "canonical serialized 48-field candidate bytes in ascending lexicographic order"
)
DISPATCH_BUDGET = {
    "maximum_operator_evaluations": 2,
    "loaded_lut_instance_count_per_route": 1,
    "per_frame_lut_load_count": 0,
    "runtime_leaf_tree_generations": 0,
    "runtime_path_generations": 0,
}

_SCHEMA_SPECS = {
    "validation-candidate-development-evidence-v2": (
        "schemas/validation-candidate-development-evidence-v2.schema.json",
        "8ba2c914ba2aa1619a6c6cc7e43f823102c79468b099778447e5e5c9d1981f3f",
    ),
    "calibration-selection-v2": (
        "schemas/calibration-selection-v2.schema.json",
        "76dc8a720356a85d2bd2f56d423de3581bff96d2e1f4202ec835a31fef7dadff",
    ),
}
_ZERO_SHA256 = "0" * 64


class CalibrationSelectionPersistenceV2Error(ValueError):
    """A validation-admission or selection byte relation is invalid."""


def _authenticated_selection_replay(function):
    """Run one pure-read selection replay inside one shared closure."""

    @wraps(function)
    def wrapped(self, *args, **kwargs):
        with self._authenticated_replay():
            return function(self, *args, **kwargs)

    return wrapped


@dataclass(frozen=True)
class VerifiedValidationAdmissionV2:
    binding: Optional[FileBindingV2]
    document: Mapping[str, object]
    semantic: ValidationAdmissionV2
    attempt_ledger: VerifiedAttemptLedgerV2
    candidates_by_sha256: Mapping[str, ValidationCandidateV2]
    development_evaluations_by_sha256: Mapping[
        str, VerifiedCandidateEvaluationV2
    ]


@dataclass(frozen=True)
class VerifiedCalibrationSelectionV2:
    binding: Optional[FileBindingV2]
    document: Mapping[str, object]
    semantic: ValidationSelectionV2
    admission: VerifiedValidationAdmissionV2
    run_ledger: VerifiedRunLedgerV2


@dataclass(frozen=True)
class _AdmissionDerivationV2:
    semantic: ValidationAdmissionV2
    attempt_ledger: VerifiedAttemptLedgerV2
    candidates_by_sha256: Mapping[str, ValidationCandidateV2]
    development_evaluations_by_sha256: Mapping[
        str, VerifiedCandidateEvaluationV2
    ]
    evaluation_bindings_by_sha256: Mapping[str, ArtifactBindingV2]


@dataclass(frozen=True)
class _SelectionContextV2:
    admission: VerifiedValidationAdmissionV2
    run_ledger: VerifiedRunLedgerV2
    candidate_order: Tuple[str, ...]


@dataclass(frozen=True)
class _AdmissionAuthorizationV2:
    payload: bytes
    run_id: str
    admitted_candidate_shared_bank_sha256_values: Tuple[
        Tuple[str, str], ...
    ]
    attempt_ledger_binding: FileBindingV2
    development_evaluation_bindings: Tuple[ArtifactBindingV2, ...]
    source_evidence_bindings: Tuple[FileBindingV2, ...]


class _SelectionFixedArtifactStoreV2(_AtomicArtifactStoreV2):
    """The shared safe store with two additional immutable fixed filenames."""

    _ALLOWED = {ADMISSION_PATH, SELECTION_PATH}

    def publish_named(self, name: str, payload: bytes) -> FileBindingV2:
        if name not in self._ALLOWED:
            raise CalibrationSelectionPersistenceV2Error(
                "selection artifact name is invalid"
            )
        descriptor = self._open_root()
        try:
            self._publish_at(descriptor, name, payload, label=name)
            reopened = self._read_at(descriptor, name, label=name)
        finally:
            os.close(descriptor)
        if reopened != payload:
            raise CalibrationSelectionPersistenceV2Error(
                "selection artifact changed after publication"
            )
        return FileBindingV2(name, _sha256(payload), len(payload))

    def reopen_named(self, binding: FileBindingV2) -> bytes:
        if type(binding) is not FileBindingV2 or binding.path not in self._ALLOWED:
            raise CalibrationSelectionPersistenceV2Error(
                "selection artifact binding is invalid"
            )
        payload, _ = self._reopen_relative_snapshot(
            binding,
            label=binding.path,
        )
        return payload


def identity_set_sha256_v2(values: Sequence[str]) -> str:
    """Hash a unique ascending lowercase SHA-256 array without a final LF."""

    if type(values) not in {list, tuple}:
        raise CalibrationSelectionPersistenceV2Error(
            "identity set is not a concrete sequence"
        )
    snapshot = tuple(values)
    if (
        any(
            type(value) is not str
            or len(value) != 64
            or value == _ZERO_SHA256
            or any(character not in "0123456789abcdef" for character in value)
            for value in snapshot
        )
        or len(set(snapshot)) != len(snapshot)
    ):
        raise CalibrationSelectionPersistenceV2Error(
            "identity set contains an invalid or repeated SHA-256"
        )
    return hashlib.sha256(
        canonical_json_bytes_v2(sorted(snapshot))
    ).hexdigest()


def _artifact_binding(document: object, *, directory: str) -> ArtifactBindingV2:
    if type(document) is not dict or set(document) != {
        "path",
        "sha256",
        "size_bytes",
    }:
        raise CalibrationSelectionPersistenceV2Error(
            "content-addressed binding is invalid"
        )
    try:
        binding = ArtifactBindingV2(
            path=document["path"],
            sha256=document["sha256"],
            size_bytes=document["size_bytes"],
        )
    except CalibrationSchedulerV2Error as error:
        raise CalibrationSelectionPersistenceV2Error(
            "content-addressed binding is invalid"
        ) from error
    if binding.path != f"{directory}/{binding.sha256}.json":
        raise CalibrationSelectionPersistenceV2Error(
            "content-addressed binding directory differs"
        )
    return binding


def _file_binding(document: object, *, expected_path: str) -> FileBindingV2:
    if type(document) is not dict or set(document) != {
        "path",
        "sha256",
        "size_bytes",
    }:
        raise CalibrationSelectionPersistenceV2Error("file binding is invalid")
    try:
        binding = FileBindingV2(
            path=document["path"],
            sha256=document["sha256"],
            size_bytes=document["size_bytes"],
        )
    except CalibrationPersistenceV2Error as error:
        raise CalibrationSelectionPersistenceV2Error(
            "file binding is invalid"
        ) from error
    if binding.path != expected_path:
        raise CalibrationSelectionPersistenceV2Error("file binding path differs")
    return binding


def _binding_document(binding: object) -> Mapping[str, object]:
    if type(binding) not in {ArtifactBindingV2, FileBindingV2}:
        raise CalibrationSelectionPersistenceV2Error("binding has wrong type")
    return {
        "path": binding.path,
        "sha256": binding.sha256,
        "size_bytes": binding.size_bytes,
    }


def _validation_failure_reasons(reasons: Sequence[str]) -> Tuple[str, ...]:
    if (
        type(reasons) not in {list, tuple}
        or not reasons
        or any(type(reason) is not str or not reason for reason in reasons)
        or len(set(reasons)) != len(reasons)
    ):
        raise CalibrationSelectionPersistenceV2Error(
            "validation failure reasons are invalid"
        )
    return tuple(reasons)


class CalibrationSelectionPersistenceAdapterV2:
    """Strict freeze boundary for validation admission and final selection."""

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
    ) -> None:
        self._schemas = self._authenticate_schemas()
        self.calibration = CalibrationPersistenceAdapterV2(
            root,
            _control_authorization_verifier=(
                _control_authorization_verifier
            ),
            _control_producer_capability_provider=(
                _control_producer_capability_provider
            ),
            _validation_admission_semantic_verifier=(
                self._reopen_control_validation_admission
            ),
        )
        self.plan = self.calibration.plan
        self._store = _SelectionFixedArtifactStoreV2(root)
        self.__admission_authorizations: Dict[
            Tuple[str, str, int], _AdmissionAuthorizationV2
        ] = {}
        self.__pending_admission_authorizations: Dict[
            bytes, _AdmissionAuthorizationV2
        ] = {}

    def _reopen_control_validation_admission(
        self,
        binding: TypedArtifactBindingV2,
        supplied_document: Mapping[str, object],
    ) -> Mapping[str, object]:
        """Replay the exact control-bound admission in the shared capture."""

        if type(binding) is not TypedArtifactBindingV2:
            raise CalibrationSelectionPersistenceV2Error(
                "control admission binding has wrong type"
            )
        file_binding = FileBindingV2(
            binding.path,
            binding.sha256,
            binding.size_bytes,
        )
        supplied = self._snapshot(
            supplied_document,
            label="control-supplied validation admission",
        )
        authorization = self.__admission_authorizations.get(
            self._admission_authorization_key(file_binding)
        )
        if authorization is None:
            verified = self.reopen_validation_admission(file_binding)
            verified_document = verified.document
        else:
            self._reopen_admission_authorization(
                file_binding,
                authorization,
                label="control",
            )
            try:
                verified_document = _parse_canonical_json_file(
                    authorization.payload,
                    label="cached control validation admission",
                )
            except CalibrationPersistenceV2Error as error:
                raise CalibrationSelectionPersistenceV2Error(
                    "cached control validation admission is invalid"
                ) from error
        if verified_document != supplied:
            raise CalibrationSelectionPersistenceV2Error(
                "control admission differs from semantic replay"
            )
        return verified_document

    @contextmanager
    def _authenticated_replay(self):
        try:
            with self.calibration._store.authenticated_closure() as capture:
                with self._store.authenticated_closure(
                    shared_capture=capture,
                ):
                    yield
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(str(error)) from error

    @staticmethod
    def _authenticate_schemas() -> Mapping[str, Mapping[str, object]]:
        schemas: Dict[str, Mapping[str, object]] = {}
        for identifier, (relative_path, expected_sha256) in _SCHEMA_SPECS.items():
            payload = _read_regular_file(
                CALIBRATION_ROOT / relative_path,
                label=f"{identifier} schema",
            )
            if _sha256(payload) != expected_sha256:
                raise CalibrationSelectionPersistenceV2Error(
                    f"{identifier} schema bytes differ from the frozen digest"
                )
            try:
                schema = _parse_canonical_json_file(
                    payload,
                    label=f"{identifier} schema",
                )
                jsonschema.Draft202012Validator.check_schema(schema)
            except (CalibrationPersistenceV2Error, jsonschema.SchemaError) as error:
                raise CalibrationSelectionPersistenceV2Error(
                    f"{identifier} schema is invalid"
                ) from error
            schemas[identifier] = schema
        return schemas

    @staticmethod
    def _snapshot(document: Mapping[str, object], *, label: str) -> Mapping[str, object]:
        try:
            snapshot = _snapshot_json(document, label=label)
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(str(error)) from error
        if type(snapshot) is not dict:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} is not a built-in object"
            )
        return snapshot

    def _validate_common(
        self,
        document: Mapping[str, object],
        *,
        schema_name: str,
        label: str,
    ) -> Mapping[str, object]:
        snapshot = self._snapshot(document, label=label)
        try:
            _validate_schema_document(
                snapshot,
                self._schemas[schema_name],
                label=label,
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(str(error)) from error
        if snapshot.get("authority_bindings") != authority_bindings_v2():
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} authority bindings differ"
            )
        if (
            snapshot.get("artifact_sha256") != artifact_semantic_sha256_v2(snapshot)
        ):
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} self-hash differs"
            )
        return snapshot

    @staticmethod
    def _validate_fixed_binding(
        document: Mapping[str, object],
        binding: FileBindingV2,
        *,
        path: str,
    ) -> None:
        payload = canonical_json_file_bytes_v2(document)
        if (
            type(binding) is not FileBindingV2
            or binding.path != path
            or binding.sha256 != _sha256(payload)
            or binding.size_bytes != len(payload)
        ):
            raise CalibrationSelectionPersistenceV2Error(
                "fixed artifact binding differs from canonical bytes"
            )

    @staticmethod
    def _require_exact_admission_document(
        observed: Mapping[str, object],
        expected: Mapping[str, object],
    ) -> None:
        if observed != expected:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission differs from exact replay derivation"
            )

    @staticmethod
    def _require_exact_selection_document(
        observed: Mapping[str, object],
        expected: Mapping[str, object],
    ) -> None:
        if observed != expected:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection differs from exact outcome ranking"
            )

    @staticmethod
    def _admission_authorization_key(
        binding: FileBindingV2,
    ) -> Tuple[str, str, int]:
        if type(binding) is not FileBindingV2 or binding.path != ADMISSION_PATH:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission binding is invalid"
            )
        return binding.path, binding.sha256, binding.size_bytes

    def _admission_authorization(
        self,
        admission: VerifiedValidationAdmissionV2,
        *,
        payload: bytes,
    ) -> _AdmissionAuthorizationV2:
        canonical_payload = canonical_json_file_bytes_v2(admission.document)
        if payload != canonical_payload:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission authorization bytes differ"
            )
        admitted_sha256_values = {
            candidate.candidate_vector_sha256
            for candidate in admission.semantic.admitted_candidates
        }
        if admitted_sha256_values != set(
            admission.document["admitted_candidate_sha256_values"]
        ):
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission authorization membership differs"
            )
        shared_bank_values = tuple(
            sorted(
                (
                    candidate_sha256,
                    shared_bank_configuration_sha256_v2(
                        dict(
                            admission.candidates_by_sha256[
                                candidate_sha256
                            ].physical_candidate_items
                        ),
                        self.plan,
                    ),
                )
                for candidate_sha256 in admitted_sha256_values
            )
        )
        attempt = admission.attempt_ledger.binding
        attempt_binding = FileBindingV2(
            path=attempt.path,
            sha256=attempt.sha256,
            size_bytes=attempt.size_bytes,
        )
        development_evaluation_bindings = tuple(
            sorted(
                {
                    reopened.binding
                    for reopened in (
                        admission.development_evaluations_by_sha256.values()
                    )
                },
                key=lambda binding: (
                    binding.path,
                    binding.sha256,
                    binding.size_bytes,
                ),
            )
        )
        source_evidence_bindings = set()
        try:
            for reopened in (
                admission.development_evaluations_by_sha256.values()
            ):
                sources = reopened.document[
                    "source_evidence_sha256_bindings"
                ]
                if type(sources) is not list:
                    raise CalibrationSelectionPersistenceV2Error(
                        "development source evidence bindings are invalid"
                    )
                for source in sources:
                    if type(source) is not dict or set(source) != {
                        "id",
                        "path",
                        "sha256",
                        "size_bytes",
                    }:
                        raise CalibrationSelectionPersistenceV2Error(
                            "development source evidence binding is invalid"
                        )
                    source_evidence_bindings.add(
                        FileBindingV2(
                            path=source["path"],
                            sha256=source["sha256"],
                            size_bytes=source["size_bytes"],
                        )
                    )
        except (KeyError, CalibrationPersistenceV2Error) as error:
            raise CalibrationSelectionPersistenceV2Error(
                "development source evidence binding is invalid"
            ) from error
        authorization = _AdmissionAuthorizationV2(
            payload=bytes(payload),
            run_id=str(admission.document["run_id"]),
            admitted_candidate_shared_bank_sha256_values=shared_bank_values,
            attempt_ledger_binding=attempt_binding,
            development_evaluation_bindings=(
                development_evaluation_bindings
            ),
            source_evidence_bindings=tuple(
                sorted(
                    source_evidence_bindings,
                    key=lambda binding: (
                        binding.path,
                        binding.sha256,
                        binding.size_bytes,
                    ),
                )
            ),
        )
        return authorization

    @_authenticated_selection_replay
    def _reopen_admission_dependency_closure(
        self,
        authorization: _AdmissionAuthorizationV2,
        *,
        label: str,
    ) -> None:
        try:
            self.calibration._store.reopen_fixed(
                authorization.attempt_ledger_binding
            )
            for binding in authorization.development_evaluation_bindings:
                self.calibration._store.reopen_content_addressed(binding)
            for binding in authorization.source_evidence_bindings:
                self.calibration._store.reopen_relative(
                    binding,
                    label="validation admission source evidence",
                )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} validation admission dependencies changed"
            ) from error

    @_authenticated_selection_replay
    def _reopen_admission_authorization(
        self,
        binding: FileBindingV2,
        authorization: _AdmissionAuthorizationV2,
        *,
        label: str,
    ) -> None:
        try:
            payload = self._store.reopen_named(binding)
        except (CalibrationPersistenceV2Error, CalibrationSelectionPersistenceV2Error) as error:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} validation admission bytes cannot be reopened"
            ) from error
        if payload != authorization.payload:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} validation admission authorization bytes changed"
            )
        self._reopen_admission_dependency_closure(
            authorization,
            label=label,
        )
        try:
            with self._store.live_recheck():
                final_payload = self._store.reopen_named(binding)
        except (
            CalibrationPersistenceV2Error,
            CalibrationSelectionPersistenceV2Error,
        ) as error:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} validation admission bytes changed during dependency replay"
            ) from error
        if final_payload != authorization.payload:
            raise CalibrationSelectionPersistenceV2Error(
                f"{label} validation admission authorization bytes changed "
                "during dependency replay"
            )

    def _remember_admission_authorization(
        self,
        admission: VerifiedValidationAdmissionV2,
        *,
        binding: FileBindingV2,
        payload: bytes,
    ) -> _AdmissionAuthorizationV2:
        self._validate_fixed_binding(
            admission.document,
            binding,
            path=ADMISSION_PATH,
        )
        authorization = self._admission_authorization(
            admission,
            payload=payload,
        )
        self.__admission_authorizations[
            self._admission_authorization_key(binding)
        ] = authorization
        return authorization

    def _remember_pending_admission_authorization(
        self,
        document: Mapping[str, object],
        derivation: _AdmissionDerivationV2,
    ) -> None:
        verified = VerifiedValidationAdmissionV2(
            binding=None,
            document=document,
            semantic=derivation.semantic,
            attempt_ledger=derivation.attempt_ledger,
            candidates_by_sha256=derivation.candidates_by_sha256,
            development_evaluations_by_sha256=(
                derivation.development_evaluations_by_sha256
            ),
        )
        payload = canonical_json_file_bytes_v2(document)
        authorization = self._admission_authorization(
            verified,
            payload=payload,
        )
        self.__pending_admission_authorizations[payload] = authorization

    def _consume_pending_admission_authorization(
        self,
        payload: bytes,
    ) -> Optional[_AdmissionAuthorizationV2]:
        authorization = self.__pending_admission_authorizations.pop(
            payload,
            None,
        )
        if authorization is None:
            return None
        self._reopen_admission_dependency_closure(
            authorization,
            label="prepublication",
        )
        return authorization

    @_authenticated_selection_replay
    def _validation_admission_authorization(
        self,
        binding: FileBindingV2,
    ) -> _AdmissionAuthorizationV2:
        key = self._admission_authorization_key(binding)
        authorization = self.__admission_authorizations.get(key)
        if authorization is None:
            self.reopen_validation_admission(binding)
            authorization = self.__admission_authorizations.get(key)
            if authorization is None:
                raise AssertionError(
                    "verified validation admission authorization was not retained"
                )
        self._reopen_admission_authorization(
            binding,
            authorization,
            label="prepublication",
        )
        return authorization

    def _admission_replay_started(self) -> None:
        """Test instrumentation hook invoked before each complete replay."""

    @_authenticated_selection_replay
    def _derive_admission(
        self,
        *,
        run_id: str,
        attempt_binding: AttemptLedgerBindingV2,
    ) -> _AdmissionDerivationV2:
        if type(run_id) is not str or not run_id:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission run ID is invalid"
            )
        self._admission_replay_started()
        try:
            attempt_ledger = self.calibration.reopen_attempt_ledger(
                attempt_binding,
                expected_run_id=run_id,
            )
            semantic = validation_admission_v2(
                self.plan,
                attempt_ledger.records,
                expected_attempt_count=attempt_binding.record_count,
                expected_last_record_sha256=attempt_binding.last_record_sha256,
            )
        except (CalibrationPersistenceV2Error, CalibrationSchedulerV2Error) as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission cannot be derived from development replay"
            ) from error

        candidates = {
            candidate.candidate_vector_sha256: candidate
            for candidate in semantic.neighborhood.candidates_before_constraint_filtering
        }
        if len(candidates) != 374:
            raise CalibrationSelectionPersistenceV2Error(
                "derived validation neighborhood does not contain 374 identities"
            )

        artifact_by_sha256: Dict[str, ArtifactBindingV2] = {}
        for record in attempt_ledger.records:
            if record.evaluation is None:
                continue
            if record.evaluation_artifact is None:
                raise CalibrationSelectionPersistenceV2Error(
                    "development evaluation lacks a persisted artifact"
                )
            previous = artifact_by_sha256.get(record.candidate_vector_sha256)
            if previous is not None and previous != record.evaluation_artifact:
                raise CalibrationSelectionPersistenceV2Error(
                    "development evaluation artifact changes within one cache identity"
                )
            artifact_by_sha256[record.candidate_vector_sha256] = (
                record.evaluation_artifact
            )

        reopened_by_sha256: Dict[str, VerifiedCandidateEvaluationV2] = {}
        for row in semantic.development_evidence:
            candidate_sha256 = row.candidate.candidate_vector_sha256
            artifact = artifact_by_sha256.get(candidate_sha256)
            if artifact is None:
                raise CalibrationSelectionPersistenceV2Error(
                    "admission neighbor lacks persisted development evidence"
                )
            try:
                reopened = self.calibration.reopen_candidate_evaluation(
                    artifact,
                    expected_run_id=run_id,
                    expected_split=DEVELOPMENT_SPLIT,
                    expected_candidate_vector_sha256=candidate_sha256,
                )
            except CalibrationPersistenceV2Error as error:
                raise CalibrationSelectionPersistenceV2Error(
                    "development evidence cannot be reopened"
                ) from error
            if (
                reopened.development_evaluation != row.evaluation
                or reopened.physical_candidate_items
                != row.candidate.physical_candidate_items
            ):
                raise CalibrationSelectionPersistenceV2Error(
                    "reopened development evidence differs from replay"
                )
            reopened_by_sha256[candidate_sha256] = reopened
        return _AdmissionDerivationV2(
            semantic=semantic,
            attempt_ledger=attempt_ledger,
            candidates_by_sha256=candidates,
            development_evaluations_by_sha256=reopened_by_sha256,
            evaluation_bindings_by_sha256=artifact_by_sha256,
        )

    def _admission_document_from_derivation(
        self,
        *,
        run_id: str,
        attempt_binding: AttemptLedgerBindingV2,
        derivation: _AdmissionDerivationV2,
    ) -> Mapping[str, object]:
        semantic = derivation.semantic
        terminal_sha256 = semantic.neighborhood.terminal_candidate_sha256
        terminal = derivation.candidates_by_sha256[terminal_sha256]
        terminal_evaluation_binding = derivation.evaluation_bindings_by_sha256.get(
            terminal_sha256
        )
        if terminal_evaluation_binding is None:
            raise CalibrationSelectionPersistenceV2Error(
                "terminal candidate lacks development evaluation evidence"
            )

        all_sha256_values = sorted(derivation.candidates_by_sha256)
        constraint_valid_sha256_values = sorted(
            candidate.candidate_vector_sha256
            for candidate in semantic.neighborhood.constraint_valid_candidates
        )
        evidence_by_sha256 = {
            row.candidate.candidate_vector_sha256: row
            for row in semantic.development_evidence
        }
        if sorted(evidence_by_sha256) != constraint_valid_sha256_values:
            raise CalibrationSelectionPersistenceV2Error(
                "development evidence set differs from constraint-valid set"
            )
        admitted_sha256_values = sorted(
            candidate.candidate_vector_sha256
            for candidate in semantic.admitted_candidates
        )
        development_evidence = []
        for candidate_sha256 in constraint_valid_sha256_values:
            row = evidence_by_sha256[candidate_sha256]
            reopened = derivation.development_evaluations_by_sha256[
                candidate_sha256
            ]
            development_evidence.append(
                {
                    "candidate_vector_sha256": candidate_sha256,
                    "feasible": row.evaluation.feasible,
                    "evaluation_semantic_sha256": (
                        reopened.evaluation_semantic_sha256
                    ),
                    "evaluation": _binding_document(reopened.binding),
                }
            )
        document = {
            "schema_version": "2.0.1",
            "artifact_kind": (
                "p06_validation_candidate_development_evidence_v2"
            ),
            "authority_bindings": authority_bindings_v2(),
            "run_id": run_id,
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(
                    dict(terminal.physical_candidate_items),
                    self.plan,
                )
            ),
            "development_trace": {
                "attempt_count": attempt_binding.record_count,
                "last_record_sha256": attempt_binding.last_record_sha256,
                "attempt_ledger": {
                    "path": attempt_binding.path,
                    "sha256": attempt_binding.sha256,
                    "size_bytes": attempt_binding.size_bytes,
                },
            },
            "development_terminal_candidate_vector_sha256": terminal_sha256,
            "development_terminal_evaluation": _binding_document(
                terminal_evaluation_binding
            ),
            "neighbor_generation": dict(NEIGHBOR_GENERATION),
            "candidate_count_before_constraint_filtering": len(
                all_sha256_values
            ),
            "candidates_before_constraint_filtering_sha256_values": (
                all_sha256_values
            ),
            "candidate_set_sha256": identity_set_sha256_v2(all_sha256_values),
            "constraint_valid_candidate_count": len(
                constraint_valid_sha256_values
            ),
            "constraint_valid_candidate_sha256_values": (
                constraint_valid_sha256_values
            ),
            "constraint_valid_candidate_set_sha256": identity_set_sha256_v2(
                constraint_valid_sha256_values
            ),
            "development_evidence_count": len(development_evidence),
            "development_evidence": development_evidence,
            "development_evidence_candidate_set_sha256": identity_set_sha256_v2(
                list(evidence_by_sha256)
            ),
            "admitted_candidate_count": len(admitted_sha256_values),
            "admitted_candidate_sha256_values": admitted_sha256_values,
            "admitted_candidate_set_sha256": identity_set_sha256_v2(
                admitted_sha256_values
            ),
            "identity_set_canonicalization": IDENTITY_SET_CANONICALIZATION,
            "validation_accessed_while_building": False,
            "data_access": {
                "development_accessed": True,
                "validation_accessed": False,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _ZERO_SHA256,
        }
        return finalize_artifact_sha256_v2(document)

    @_authenticated_selection_replay
    def build_validation_admission_document(
        self,
        *,
        run_id: str,
        attempt_binding: AttemptLedgerBindingV2,
    ) -> Mapping[str, object]:
        """Derive the exact development-only validation freeze document."""

        derivation = self._derive_admission(
            run_id=run_id,
            attempt_binding=attempt_binding,
        )
        document = self._admission_document_from_derivation(
            run_id=run_id,
            attempt_binding=attempt_binding,
            derivation=derivation,
        )
        snapshot = self._validate_common(
            document,
            schema_name="validation-candidate-development-evidence-v2",
            label="validation admission",
        )
        self._remember_pending_admission_authorization(snapshot, derivation)
        return snapshot

    @_authenticated_selection_replay
    def verify_validation_admission(
        self,
        document: Mapping[str, object],
        *,
        binding: Optional[FileBindingV2] = None,
    ) -> VerifiedValidationAdmissionV2:
        """Replay development and verify the exact 374-neighbor admission freeze."""

        snapshot = self._validate_common(
            document,
            schema_name="validation-candidate-development-evidence-v2",
            label="validation admission",
        )
        if binding is not None:
            self._validate_fixed_binding(snapshot, binding, path=ADMISSION_PATH)
        trace = snapshot["development_trace"]
        attempt_reference = trace["attempt_ledger"]
        try:
            attempt_binding = AttemptLedgerBindingV2(
                path=attempt_reference["path"],
                sha256=attempt_reference["sha256"],
                size_bytes=attempt_reference["size_bytes"],
                record_count=trace["attempt_count"],
                last_record_sha256=trace["last_record_sha256"],
            )
        except (KeyError, CalibrationPersistenceV2Error) as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission attempt reference is invalid"
            ) from error
        derivation = self._derive_admission(
            run_id=snapshot["run_id"],
            attempt_binding=attempt_binding,
        )
        expected = self._admission_document_from_derivation(
            run_id=snapshot["run_id"],
            attempt_binding=attempt_binding,
            derivation=derivation,
        )
        self._require_exact_admission_document(snapshot, expected)
        return VerifiedValidationAdmissionV2(
            binding=binding,
            document=snapshot,
            semantic=derivation.semantic,
            attempt_ledger=derivation.attempt_ledger,
            candidates_by_sha256=derivation.candidates_by_sha256,
            development_evaluations_by_sha256=(
                derivation.development_evaluations_by_sha256
            ),
        )

    def publish_validation_admission(
        self,
        document: Mapping[str, object],
    ) -> FileBindingV2:
        snapshot = self._validate_common(
            document,
            schema_name="validation-candidate-development-evidence-v2",
            label="validation admission",
        )
        payload = canonical_json_file_bytes_v2(snapshot)
        authorization = self._consume_pending_admission_authorization(payload)
        verified: Optional[VerifiedValidationAdmissionV2] = None
        if authorization is None:
            verified = self.verify_validation_admission(snapshot)
            authorization = self._admission_authorization(
                verified,
                payload=payload,
            )
        binding = self._store.publish_named(ADMISSION_PATH, payload)
        reopened_payload = self._store.reopen_named(binding)
        if reopened_payload != payload:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission changed after publication"
            )
        if verified is not None:
            self._validate_fixed_binding(
                verified.document,
                binding,
                path=ADMISSION_PATH,
            )
        self._reopen_admission_authorization(
            binding,
            authorization,
            label="postpublication",
        )
        self.__admission_authorizations[
            self._admission_authorization_key(binding)
        ] = authorization
        return binding

    @_authenticated_selection_replay
    def reopen_validation_admission(
        self,
        binding: FileBindingV2,
    ) -> VerifiedValidationAdmissionV2:
        if binding.path != ADMISSION_PATH:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission path differs"
            )
        try:
            payload = self._store.reopen_named(binding)
            document = _parse_canonical_json_file(
                payload,
                label="validation admission",
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission bytes are invalid"
            ) from error
        verified = self.verify_validation_admission(document, binding=binding)
        self._remember_admission_authorization(
            verified,
            binding=binding,
            payload=payload,
        )
        try:
            with self._store.live_recheck():
                final_payload = self._store.reopen_named(binding)
        except (
            CalibrationPersistenceV2Error,
            CalibrationSelectionPersistenceV2Error,
        ) as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission changed during semantic replay"
            ) from error
        if final_payload != payload:
            raise CalibrationSelectionPersistenceV2Error(
                "validation admission changed during semantic replay"
            )
        return verified

    def publish_validation_candidate_evaluation(
        self,
        admission_binding: FileBindingV2,
        document: Mapping[str, object],
    ) -> ArtifactBindingV2:
        """Publish validation evidence only after reopening a frozen admission."""

        authorization = self._validation_admission_authorization(
            admission_binding
        )
        try:
            candidate = self.calibration.verify_candidate_evaluation(
                document,
                expected_run_id=authorization.run_id,
                expected_split=VALIDATION_SPLIT,
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation is invalid"
            ) from error
        admitted = dict(
            authorization.admitted_candidate_shared_bank_sha256_values
        )
        admitted_shared_sha256 = admitted.get(
            candidate.candidate_vector_sha256
        )
        if admitted_shared_sha256 is None:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation candidate was not development-admitted"
            )
        if (
            candidate.shared_bank_configuration_sha256
            != admitted_shared_sha256
        ):
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation shared-bank identity differs from admission"
            )
        try:
            binding = self.calibration.publish_candidate_evaluation(
                candidate.document
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation publication failed"
            ) from error
        self._reopen_admission_authorization(
            admission_binding,
            authorization,
            label="postpublication",
        )
        try:
            reopened = self.calibration.reopen_candidate_evaluation(
                binding,
                expected_run_id=authorization.run_id,
                expected_split=VALIDATION_SPLIT,
                expected_candidate_vector_sha256=(
                    candidate.candidate_vector_sha256
                ),
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation changed during postpublication replay"
            ) from error
        if reopened.document != candidate.document:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation changed during postpublication replay"
            )
        self._reopen_admission_authorization(
            admission_binding,
            authorization,
            label="postpublication",
        )
        try:
            final_reopened = self.calibration.reopen_candidate_evaluation(
                binding,
                expected_run_id=authorization.run_id,
                expected_split=VALIDATION_SPLIT,
                expected_candidate_vector_sha256=(
                    candidate.candidate_vector_sha256
                ),
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation changed during postpublication replay"
            ) from error
        if final_reopened.document != candidate.document:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation changed during postpublication replay"
            )
        return binding

    @staticmethod
    def _validation_evaluation(
        document: object,
    ) -> ValidationEvaluationV2:
        if type(document) is not dict or type(document.get("objective")) is not dict:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation object is invalid"
            )
        objective = document["objective"]
        try:
            return ValidationEvaluationV2(
                feasible=document["feasible"],
                failure_reasons=tuple(document["failure_reasons"]),
                y_vs_fixed_ci_low=objective["y_vs_fixed_ci_low"],
                y_vs_non_ash_ci_low=objective["y_vs_non_ash_ci_low"],
                y_vs_conventional_ci_low=objective["y_vs_conventional_ci_low"],
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
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation cannot be decoded"
            ) from error

    def publish_validation_evaluation_failure(
        self,
        admission_binding: FileBindingV2,
        *,
        candidate_vector_sha256: str,
        failure_reasons: Sequence[str],
        document: Mapping[str, object],
    ) -> ArtifactBindingV2:
        """Publish a typed evaluator failure only for a frozen admitted identity."""

        authorization = self._validation_admission_authorization(
            admission_binding
        )
        admitted = dict(
            authorization.admitted_candidate_shared_bank_sha256_values
        )
        shared_sha256 = admitted.get(candidate_vector_sha256)
        if shared_sha256 is None:
            raise CalibrationSelectionPersistenceV2Error(
                "validation failure candidate was not development-admitted"
            )
        reasons = _validation_failure_reasons(failure_reasons)
        try:
            verified = self.calibration.verify_failure_artifact(
                document,
                expected_run_id=authorization.run_id,
                expected_candidate_vector_sha256=candidate_vector_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="evaluation",
                expected_failure_reasons=reasons,
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure is invalid"
            ) from error
        if verified["failure_stage"] != "validation_selection":
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure stage differs"
            )
        if verified["recovery"]["resume_source"] != {
            "applicable": True,
            "binding": _binding_document(admission_binding),
        }:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure resume source differs"
            )
        if verified["data_access"] != {
            "development_accessed": True,
            "validation_accessed": True,
            "holdout_accessed": False,
            "release_locks_written": False,
        }:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure data access differs"
            )
        try:
            binding = self.calibration.publish_failure_artifact(verified)
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure publication failed"
            ) from error
        self._reopen_admission_authorization(
            admission_binding,
            authorization,
            label="postpublication",
        )
        try:
            reopened = self.calibration.reopen_failure_artifact(
                binding,
                expected_run_id=authorization.run_id,
                expected_candidate_vector_sha256=candidate_vector_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="evaluation",
                expected_failure_reasons=reasons,
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure changed during "
                "postpublication replay"
            ) from error
        if reopened != verified:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure changed during "
                "postpublication replay"
            )
        self._reopen_admission_authorization(
            admission_binding,
            authorization,
            label="postpublication",
        )
        try:
            final_reopened = self.calibration.reopen_failure_artifact(
                binding,
                expected_run_id=authorization.run_id,
                expected_candidate_vector_sha256=candidate_vector_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="evaluation",
                expected_failure_reasons=reasons,
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure changed during "
                "postpublication replay"
            ) from error
        if final_reopened != verified:
            raise CalibrationSelectionPersistenceV2Error(
                "validation evaluation failure changed during "
                "postpublication replay"
            )
        return binding

    @_authenticated_selection_replay
    def _selection_context(
        self,
        *,
        run_binding: FileBindingV2,
        admission_binding: FileBindingV2,
    ) -> _SelectionContextV2:
        try:
            run_ledger = self.calibration.reopen_run_ledger(run_binding)
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "selection run ledger cannot be reopened"
            ) from error
        admission = self.reopen_validation_admission(admission_binding)
        run = run_ledger.document
        freeze = admission.document
        if (
            run["run_status"] != "selection_ready"
            or run["run_id"] != freeze["run_id"]
            or run["development_terminal_candidate_vector_sha256"]
            != freeze["development_terminal_candidate_vector_sha256"]
            or run["development_attempt_count"]
            != freeze["development_trace"]["attempt_count"]
            or run["attempt_ledger"]["last_record_sha256"]
            != freeze["development_trace"]["last_record_sha256"]
            or run["validation_admission"] != _binding_document(admission_binding)
        ):
            raise CalibrationSelectionPersistenceV2Error(
                "selection run ledger differs from validation admission"
            )
        candidate_order = tuple(
            sorted(
                candidate.candidate_vector_sha256
                for candidate in admission.semantic.admitted_candidates
            )
        )
        if not candidate_order:
            raise CalibrationSelectionPersistenceV2Error(
                "selection admission is empty"
            )
        if run["validation_attempt_count"] != len(candidate_order):
            raise CalibrationSelectionPersistenceV2Error(
                "run-ledger validation attempt count differs from admission"
            )
        expected_run_payload = canonical_json_file_bytes_v2(run)
        try:
            with self.calibration._store.live_recheck():
                final_run_payload = self.calibration._store.reopen_fixed(
                    run_binding
                )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "selection run ledger changed during admission replay"
            ) from error
        if final_run_payload != expected_run_payload:
            raise CalibrationSelectionPersistenceV2Error(
                "selection run ledger changed during admission replay"
            )
        return _SelectionContextV2(
            admission=admission,
            run_ledger=run_ledger,
            candidate_order=candidate_order,
        )

    @_authenticated_selection_replay
    def _decode_validation_outcomes(
        self,
        outcomes: Sequence[Mapping[str, object]],
        *,
        context: _SelectionContextV2,
    ) -> Tuple[
        Tuple[ScoredValidationCandidateV2, ...],
        Tuple[ValidationEvaluationFailureV2, ...],
        Mapping[str, Mapping[str, object]],
    ]:
        if type(outcomes) not in {list, tuple}:
            raise CalibrationSelectionPersistenceV2Error(
                "validation outcomes are not a concrete sequence"
            )
        snapshot = _snapshot_json(list(outcomes), label="validation outcomes")
        if type(snapshot) is not list or any(type(item) is not dict for item in snapshot):
            raise CalibrationSelectionPersistenceV2Error(
                "validation outcome is not a built-in object"
            )
        observed_order = tuple(
            item.get("candidate_vector_sha256") for item in snapshot
        )
        if observed_order != context.candidate_order:
            raise CalibrationSelectionPersistenceV2Error(
                "validation outcome order or membership differs from admission"
            )
        candidate_by_sha256 = context.admission.candidates_by_sha256
        run_id = context.admission.document["run_id"]
        scored = []
        failures = []
        by_sha256: Dict[str, Mapping[str, object]] = {}
        scored_bindings: Dict[str, ArtifactBindingV2] = {}
        failed_bindings: Dict[str, ArtifactBindingV2] = {}
        used_failure_bindings = set()
        for outcome in snapshot:
            candidate_sha256 = outcome["candidate_vector_sha256"]
            candidate = candidate_by_sha256[candidate_sha256]
            if outcome.get("outcome_kind") == "scored":
                if set(outcome) != {
                    "candidate_vector_sha256",
                    "outcome_kind",
                    "evaluation",
                    "evaluation_semantic_sha256",
                }:
                    raise CalibrationSelectionPersistenceV2Error(
                        "scored validation outcome field set differs"
                    )
                binding = _artifact_binding(
                    outcome["evaluation"],
                    directory="evaluations",
                )
                try:
                    reopened = self.calibration.reopen_candidate_evaluation(
                        binding,
                        expected_run_id=run_id,
                        expected_split=VALIDATION_SPLIT,
                        expected_candidate_vector_sha256=candidate_sha256,
                    )
                except CalibrationPersistenceV2Error as error:
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation evaluation cannot be reopened"
                    ) from error
                if (
                    reopened.evaluation_semantic_sha256
                    != outcome["evaluation_semantic_sha256"]
                    or reopened.physical_candidate_items
                    != candidate.physical_candidate_items
                ):
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation evaluation differs from admitted candidate"
                    )
                evaluation = self._validation_evaluation(
                    reopened.document["evaluation"]
                )
                scored.append(ScoredValidationCandidateV2(candidate, evaluation))
                scored_bindings[candidate_sha256] = binding
            elif outcome.get("outcome_kind") == "failed":
                if set(outcome) != {
                    "candidate_vector_sha256",
                    "outcome_kind",
                    "failure_type",
                    "failure_reasons",
                    "failure",
                }:
                    raise CalibrationSelectionPersistenceV2Error(
                        "failed validation outcome field set differs"
                    )
                if outcome["failure_type"] != "evaluation":
                    raise CalibrationSelectionPersistenceV2Error(
                        "failed validation outcome type differs"
                    )
                binding = _artifact_binding(
                    outcome["failure"],
                    directory="failures",
                )
                if binding in used_failure_bindings:
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation failure binding is reused"
                    )
                used_failure_bindings.add(binding)
                shared_sha256 = shared_bank_configuration_sha256_v2(
                    dict(candidate.physical_candidate_items),
                    self.plan,
                )
                reasons = _validation_failure_reasons(
                    outcome["failure_reasons"]
                )
                try:
                    failure = self.calibration.reopen_failure_artifact(
                        binding,
                        expected_run_id=run_id,
                        expected_candidate_vector_sha256=candidate_sha256,
                        expected_shared_bank_sha256=shared_sha256,
                        expected_failure_type="evaluation",
                        expected_failure_reasons=reasons,
                    )
                except CalibrationPersistenceV2Error as error:
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation failure cannot be reopened"
                    ) from error
                if failure["failure_stage"] != "validation_selection":
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation failure stage differs"
                    )
                admission_binding = context.admission.binding
                if admission_binding is None or failure["recovery"][
                    "resume_source"
                ] != {
                    "applicable": True,
                    "binding": _binding_document(admission_binding),
                }:
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation failure resume source differs"
                    )
                if failure["data_access"] != {
                    "development_accessed": True,
                    "validation_accessed": True,
                    "holdout_accessed": False,
                    "release_locks_written": False,
                }:
                    raise CalibrationSelectionPersistenceV2Error(
                        "validation failure data access differs"
                    )
                failures.append(
                    ValidationEvaluationFailureV2(
                        candidate,
                        reasons,
                    )
                )
                failed_bindings[candidate_sha256] = binding
            else:
                raise CalibrationSelectionPersistenceV2Error(
                    "validation outcome kind is invalid"
                )
            by_sha256[candidate_sha256] = outcome

        run_validation_bindings = {
            entry["candidate_vector_sha256"]: _artifact_binding(
                entry["binding"],
                directory="evaluations",
            )
            for entry in context.run_ledger.document["candidate_evaluations"]
            if entry["split"] == VALIDATION_SPLIT
        }
        if run_validation_bindings != scored_bindings:
            raise CalibrationSelectionPersistenceV2Error(
                "run-ledger validation evaluation set differs from scored outcomes"
            )
        run_validation_failure_bindings = {
            entry["candidate_vector_sha256"]: _artifact_binding(
                entry["binding"],
                directory="failures",
            )
            for entry in context.run_ledger.document["candidate_failures"]
            if entry["split"] == VALIDATION_SPLIT
        }
        if run_validation_failure_bindings != failed_bindings:
            raise CalibrationSelectionPersistenceV2Error(
                "run-ledger validation failure set differs from failed outcomes"
            )
        if set(scored_bindings) & set(failed_bindings):
            raise CalibrationSelectionPersistenceV2Error(
                "validation scored and failed outcome identities overlap"
            )
        if set(scored_bindings) | set(failed_bindings) != set(
            context.candidate_order
        ):
            raise CalibrationSelectionPersistenceV2Error(
                "validation outcome coverage differs from admission"
            )
        return tuple(scored), tuple(failures), by_sha256

    @_authenticated_selection_replay
    def _selection_document_from_context(
        self,
        *,
        run_binding: FileBindingV2,
        admission_binding: FileBindingV2,
        outcomes: Sequence[Mapping[str, object]],
        context: _SelectionContextV2,
    ) -> Tuple[Mapping[str, object], ValidationSelectionV2]:
        scored, failures, outcome_by_sha256 = self._decode_validation_outcomes(
            outcomes,
            context=context,
        )
        try:
            semantic = select_validation_candidate_v2(
                context.admission.semantic,
                scored,
                self.plan,
                evaluation_failures=failures,
            )
        except CalibrationSchedulerV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "validation selection semantic replay failed"
            ) from error
        selected_sha256 = semantic.selected.candidate.candidate_vector_sha256
        selected_outcome = outcome_by_sha256[selected_sha256]
        if selected_outcome["outcome_kind"] != "scored":
            raise CalibrationSelectionPersistenceV2Error(
                "selected validation outcome is not scored"
            )
        selected_evaluations = tuple(
            evaluation
            for evaluation in context.run_ledger.candidate_evaluations
            if evaluation.split == VALIDATION_SPLIT
            and evaluation.candidate_vector_sha256 == selected_sha256
        )
        if len(selected_evaluations) != 1:
            raise CalibrationSelectionPersistenceV2Error(
                "selected validation control authorization is ambiguous"
            )
        selected_control_bundle = selected_evaluations[
            0
        ].control_authorization_bundle_binding.as_document()
        selection_shared_sha256 = shared_bank_configuration_sha256_v2(
            dict(semantic.selected.candidate.physical_candidate_items),
            self.plan,
        )
        normalized_outcomes = _snapshot_json(
            list(outcomes),
            label="validation outcomes",
        )
        if type(normalized_outcomes) is not list:
            raise AssertionError("validation outcome snapshot changed type")
        run = context.run_ledger.document
        document = {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_selection_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": run["run_id"],
            "input_bundle_sha256": run["input_bundle_sha256"],
            "shared_bank_configuration_sha256": selection_shared_sha256,
            "calibration_run_ledger": _binding_document(run_binding),
            "validation_candidate_development_evidence": _binding_document(
                admission_binding
            ),
            "development_terminal_candidate_vector_sha256": (
                context.admission.document[
                    "development_terminal_candidate_vector_sha256"
                ]
            ),
            "validation_candidate_vector_sha256_values": list(
                context.candidate_order
            ),
            "validation_candidate_count": len(context.candidate_order),
            "validation_candidate_identity_set_sha256": identity_set_sha256_v2(
                context.candidate_order
            ),
            "validation_outcomes": normalized_outcomes,
            "validation_outcome_count": len(normalized_outcomes),
            "validation_outcome_identity_set_sha256": identity_set_sha256_v2(
                context.candidate_order
            ),
            "pareto_dimensions": list(PARETO_DIMENSIONS),
            "pareto_frontier_candidate_vector_sha256_values": [
                scored_candidate.candidate.candidate_vector_sha256
                for scored_candidate in semantic.pareto_frontier
            ],
            "selection_tie_break": SELECTION_TIE_BREAK,
            "selected": {
                "candidate_vector_sha256": selected_sha256,
                "evaluation": selected_outcome["evaluation"],
                "evaluation_semantic_sha256": selected_outcome[
                    "evaluation_semantic_sha256"
                ],
            },
            "selected_control_authorization_bundle": (
                selected_control_bundle
            ),
            "dispatch_budget": dict(DISPATCH_BUDGET),
            "selection_status": "selected",
            "data_access": {
                "development_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _ZERO_SHA256,
        }
        return finalize_artifact_sha256_v2(document), semantic

    @_authenticated_selection_replay
    def build_calibration_selection_document(
        self,
        *,
        run_binding: FileBindingV2,
        admission_binding: FileBindingV2,
        outcomes: Sequence[Mapping[str, object]],
    ) -> Mapping[str, object]:
        context = self._selection_context(
            run_binding=run_binding,
            admission_binding=admission_binding,
        )
        document, _ = self._selection_document_from_context(
            run_binding=run_binding,
            admission_binding=admission_binding,
            outcomes=outcomes,
            context=context,
        )
        return self._validate_common(
            document,
            schema_name="calibration-selection-v2",
            label="calibration selection",
        )

    @_authenticated_selection_replay
    def verify_calibration_selection(
        self,
        document: Mapping[str, object],
        *,
        binding: Optional[FileBindingV2] = None,
    ) -> VerifiedCalibrationSelectionV2:
        """Reopen all admitted outcomes and verify the exact Pareto winner."""

        snapshot = self._validate_common(
            document,
            schema_name="calibration-selection-v2",
            label="calibration selection",
        )
        if binding is not None:
            self._validate_fixed_binding(snapshot, binding, path=SELECTION_PATH)
        run_binding = _file_binding(
            snapshot["calibration_run_ledger"],
            expected_path="calibration-run-ledger-v2.json",
        )
        admission_binding = _file_binding(
            snapshot["validation_candidate_development_evidence"],
            expected_path=ADMISSION_PATH,
        )
        context = self._selection_context(
            run_binding=run_binding,
            admission_binding=admission_binding,
        )
        expected, semantic = self._selection_document_from_context(
            run_binding=run_binding,
            admission_binding=admission_binding,
            outcomes=snapshot["validation_outcomes"],
            context=context,
        )
        self._require_exact_selection_document(snapshot, expected)
        return VerifiedCalibrationSelectionV2(
            binding=binding,
            document=snapshot,
            semantic=semantic,
            admission=context.admission,
            run_ledger=context.run_ledger,
        )

    def publish_calibration_selection(
        self,
        document: Mapping[str, object],
    ) -> FileBindingV2:
        verified = self.verify_calibration_selection(document)
        payload = canonical_json_file_bytes_v2(verified.document)
        binding = self._store.publish_named(SELECTION_PATH, payload)
        reopened_payload = self._store.reopen_named(binding)
        if reopened_payload != payload:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection changed after publication"
            )
        reopened = self.reopen_calibration_selection(binding)
        if reopened.document != verified.document:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection dependencies changed after publication"
            )
        return binding

    @_authenticated_selection_replay
    def reopen_calibration_selection(
        self,
        binding: FileBindingV2,
    ) -> VerifiedCalibrationSelectionV2:
        if binding.path != SELECTION_PATH:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection path differs"
            )
        try:
            payload = self._store.reopen_named(binding)
            document = _parse_canonical_json_file(
                payload,
                label="calibration selection",
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection bytes are invalid"
            ) from error
        verified = self.verify_calibration_selection(document, binding=binding)
        try:
            with self._store.live_recheck():
                final_payload = self._store.reopen_named(binding)
        except (
            CalibrationPersistenceV2Error,
            CalibrationSelectionPersistenceV2Error,
        ) as error:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection changed during dependency replay"
            ) from error
        if final_payload != payload:
            raise CalibrationSelectionPersistenceV2Error(
                "calibration selection changed during dependency replay"
            )
        return verified

    @_authenticated_selection_replay
    def verify_validation_terminal_failure(
        self,
        *,
        run_binding: FileBindingV2,
        admission_binding: FileBindingV2,
        outcomes: Sequence[Mapping[str, object]],
        terminal_failure_binding: ArtifactBindingV2,
    ) -> Mapping[str, object]:
        """Verify the typed terminal path when complete outcomes have no winner."""

        context = self._selection_context(
            run_binding=run_binding,
            admission_binding=admission_binding,
        )
        scored, failures, _ = self._decode_validation_outcomes(
            outcomes,
            context=context,
        )
        if any(item.evaluation.feasible for item in scored):
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure has a feasible scored candidate"
            )
        if len(scored) + len(failures) != len(context.candidate_order):
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure lacks complete outcomes"
            )
        terminal_sha256 = context.admission.document[
            "development_terminal_candidate_vector_sha256"
        ]
        terminal = context.admission.candidates_by_sha256[terminal_sha256]
        shared_sha256 = shared_bank_configuration_sha256_v2(
            dict(terminal.physical_candidate_items),
            self.plan,
        )
        try:
            failure = self.calibration.reopen_failure_artifact(
                terminal_failure_binding,
                expected_run_id=context.admission.document["run_id"],
                expected_candidate_vector_sha256=terminal_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="terminal",
                expected_failure_reasons=(),
            )
        except CalibrationPersistenceV2Error as error:
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure cannot be reopened"
            ) from error
        if failure["failure_stage"] != "validation_selection":
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure stage differs"
            )
        expected_failure_bindings = {
            "attempt_ledger": {
                "applicable": True,
                "binding": context.admission.document["development_trace"][
                    "attempt_ledger"
                ],
            },
            "trace_evidence": {
                "applicable": True,
                "binding": _binding_document(run_binding),
            },
            "artifact_manifest": {
                "applicable": True,
                "binding": context.run_ledger.document["artifact_manifest"],
            },
            "cleanup_evidence": {
                "applicable": False,
                "binding": None,
            },
            "recovery_evidence": {
                "applicable": False,
                "binding": None,
            },
        }
        if failure["failure_bindings"] != expected_failure_bindings:
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure evidence bindings differ"
            )
        if failure["data_access"] != {
            "development_accessed": True,
            "validation_accessed": True,
            "holdout_accessed": False,
            "release_locks_written": False,
        }:
            raise CalibrationSelectionPersistenceV2Error(
                "terminal validation failure data access differs"
            )
        return failure
