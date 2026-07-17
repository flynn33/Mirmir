"""Dependency-ordered production coordinator for one authenticated P06 V2 run.

The coordinator owns scheduling and persistence only.  Candidate measurement
and control authorization are supplied by a concrete capability which must
return schema-2 documents; V1 evaluation documents are rejected by the
existing persistence boundary before they can enter the run.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Optional, Protocol, Sequence, Tuple, Union

from validation.calibration_v2.calibration_persistence_v2 import (
    ArtifactBindingV2,
    AttemptLedgerBindingV2,
    CandidateControlProducerCapabilitiesV2,
    CandidateControlProducerRequestV2,
    FileBindingV2,
    authority_bindings_v2,
    authority_input_bindings_v2,
    candidate_evaluation_identity_set_sha256_v2,
    candidate_failure_identity_set_sha256_v2,
    canonical_json_file_bytes_v2,
    finalize_artifact_sha256_v2,
    input_bundle_sha256_v2,
    _parse_canonical_json_file,
    _read_regular_file,
)
from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    DEVELOPMENT_SPLIT,
    VALIDATION_SPLIT,
    AuthenticatedDevelopmentEvaluationFailureV2,
    AuthenticatedDevelopmentEvaluationV2,
    DevelopmentEvaluationV2,
    DevelopmentSearchResultV2,
    EvaluationCacheIdentityV2,
    MAXIMUM_DEVELOPMENT_ATTEMPTS,
    MAXIMUM_VALIDATION_NEIGHBORHOOD,
    STATUS_TERMINATED_FEASIBLE,
    run_development_search_v2,
)
from validation.calibration_v2.calibration_selection_persistence_v2 import (
    ADMISSION_PATH,
    SELECTION_PATH,
    CalibrationSelectionPersistenceAdapterV2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
)


ZERO_SHA256 = "0" * 64
RUN_LEDGER_PATH = "calibration-run-ledger-v2.json"
ATTEMPT_LEDGER_PATH = "attempts-v2.ndjson"
ARTIFACT_MANIFEST_PATH = "artifact-manifest-v2.json"


class P06ProductionCoordinatorV2Error(ValueError):
    """The provider, scheduler, persisted run, or restart closure is invalid."""


@dataclass(frozen=True)
class CandidateEvaluationRequestV2:
    """One split-scoped request carrying the scheduler's exact V2 identity."""

    run_id: str
    split: str
    logical_candidate_items: Tuple[Tuple[str, object], ...]
    physical_candidate_items: Tuple[Tuple[str, object], ...]
    cache_identity: EvaluationCacheIdentityV2
    validation_admission: Optional[FileBindingV2]

    def __post_init__(self) -> None:
        if (
            type(self.run_id) is not str
            or not self.run_id
            or self.split not in {DEVELOPMENT_SPLIT, VALIDATION_SPLIT}
            or type(self.logical_candidate_items) is not tuple
            or type(self.physical_candidate_items) is not tuple
            or type(self.cache_identity) is not EvaluationCacheIdentityV2
            or self.cache_identity.split != self.split
        ):
            raise P06ProductionCoordinatorV2Error(
                "candidate evaluation request identity is invalid"
            )
        if (self.split == VALIDATION_SPLIT) != (
            type(self.validation_admission) is FileBindingV2
        ):
            raise P06ProductionCoordinatorV2Error(
                "candidate evaluation request admission scope differs"
            )


@dataclass(frozen=True)
class CandidateEvaluationSuccessV2:
    document: Mapping[str, object]

    def __post_init__(self) -> None:
        if not isinstance(self.document, Mapping):
            raise P06ProductionCoordinatorV2Error(
                "candidate evaluation success document is absent"
            )


@dataclass(frozen=True)
class CandidateEvaluationFailureV2:
    document: Mapping[str, object]
    failure_reasons: Tuple[str, ...]

    def __post_init__(self) -> None:
        if (
            not isinstance(self.document, Mapping)
            or type(self.failure_reasons) is not tuple
            or not self.failure_reasons
            or any(type(reason) is not str or not reason for reason in self.failure_reasons)
            or len(set(self.failure_reasons)) != len(self.failure_reasons)
        ):
            raise P06ProductionCoordinatorV2Error(
                "candidate evaluation failure is invalid"
            )


CandidateEvaluationOutcomeV2 = Union[
    CandidateEvaluationSuccessV2,
    CandidateEvaluationFailureV2,
]


class CandidateEvaluationProviderV2(Protocol):
    """Concrete producer of complete schema-2 evaluation or failure documents."""

    def __call__(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> CandidateEvaluationOutcomeV2:
        ...


@dataclass(frozen=True)
class RunArtifactProvenanceV2:
    created_utc: str
    project_commit: str
    producer: str
    command: str
    platform: str
    machine: str
    gate_ids: Tuple[str, ...] = ("G04", "G05", "G06")

    def __post_init__(self) -> None:
        parsed = None
        if type(self.created_utc) is str and self.created_utc.endswith("Z"):
            try:
                parsed = datetime.fromisoformat(
                    self.created_utc[:-1] + "+00:00"
                )
            except ValueError:
                pass
        if (
            type(self.created_utc) is not str
            or not self.created_utc.endswith("Z")
            or parsed is None
            or type(self.project_commit) is not str
            or len(self.project_commit) != 40
            or any(character not in "0123456789abcdef" for character in self.project_commit)
            or any(
                type(value) is not str or not value
                for value in (
                    self.producer,
                    self.command,
                    self.platform,
                    self.machine,
                )
            )
            or type(self.gate_ids) is not tuple
            or not self.gate_ids
            or len(set(self.gate_ids)) != len(self.gate_ids)
        ):
            raise P06ProductionCoordinatorV2Error(
                "run artifact provenance is invalid"
            )


@dataclass(frozen=True)
class P06ProductionRunResultV2:
    development: DevelopmentSearchResultV2
    attempt_ledger_binding: AttemptLedgerBindingV2
    admission_binding: FileBindingV2
    run_ledger_binding: FileBindingV2
    selection_binding: FileBindingV2
    artifact_manifest_binding: FileBindingV2
    validation_outcomes: Tuple[Mapping[str, object], ...]
    selection: Mapping[str, object]
    restarted_from_complete_selection: bool


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _binding_document(binding: object) -> Mapping[str, object]:
    if type(binding) not in {
        ArtifactBindingV2,
        AttemptLedgerBindingV2,
        FileBindingV2,
    }:
        raise P06ProductionCoordinatorV2Error("artifact binding has wrong type")
    return {
        "path": binding.path,
        "sha256": binding.sha256,
        "size_bytes": binding.size_bytes,
    }


def _existing_file_binding(root: Path, relative: str) -> FileBindingV2:
    payload = _read_regular_file(root / relative, label=relative)
    return FileBindingV2(relative, _sha256(payload), len(payload))


def _development_evaluation(document: Mapping[str, object]) -> DevelopmentEvaluationV2:
    evaluation = document.get("evaluation")
    if not isinstance(evaluation, Mapping) or not isinstance(
        evaluation.get("objective"), Mapping
    ):
        raise P06ProductionCoordinatorV2Error(
            "development evaluation ranking fields are absent"
        )
    objective = evaluation["objective"]
    try:
        return DevelopmentEvaluationV2(
            feasible=evaluation["feasible"],
            failure_reasons=tuple(evaluation["failure_reasons"]),
            mean_y_psnr_delta_vs_fixed_db=objective[
                "mean_y_psnr_delta_vs_fixed_db"
            ],
            mean_y_psnr_delta_vs_non_ash_db=objective[
                "mean_y_psnr_delta_vs_non_ash_db"
            ],
            mean_ms_ssim_delta_vs_conventional=objective[
                "mean_ms_ssim_delta_vs_conventional"
            ],
            maximum_ringing_excursion=objective["maximum_ringing_excursion"],
            maximum_alias_ratio=objective["maximum_alias_ratio"],
            estimated_dispatch_cost=objective["estimated_dispatch_cost"],
        )
    except (KeyError, TypeError, ValueError) as error:
        raise P06ProductionCoordinatorV2Error(
            "development evaluation ranking fields are invalid"
        ) from error


class P06ProductionCoordinatorV2:
    """Run, persist, reopen, and restart one complete schema-2 calibration."""

    def __init__(
        self,
        *,
        artifact_root: Path,
        run_id: str,
        provider: CandidateEvaluationProviderV2,
        provenance: RunArtifactProvenanceV2,
        _control_authorization_verifier: Optional[Callable[..., object]] = None,
        _control_producer_capability_provider: Optional[
            Callable[
                [CandidateControlProducerRequestV2],
                CandidateControlProducerCapabilitiesV2,
            ]
        ] = None,
    ) -> None:
        if type(run_id) is not str or not run_id or not callable(provider):
            raise P06ProductionCoordinatorV2Error(
                "production coordinator inputs are invalid"
            )
        self.root = artifact_root
        self.run_id = run_id
        self.provider = provider
        self.provenance = provenance
        self.persistence = CalibrationSelectionPersistenceAdapterV2(
            artifact_root,
            _control_authorization_verifier=_control_authorization_verifier,
            _control_producer_capability_provider=(
                _control_producer_capability_provider
            ),
        )

    def _request(
        self,
        *,
        split: str,
        logical: Mapping[str, object],
        physical: Mapping[str, object],
        identity: EvaluationCacheIdentityV2,
        admission: Optional[FileBindingV2],
    ) -> CandidateEvaluationRequestV2:
        if (
            candidate_vector_sha256_v2(physical, self.persistence.plan)
            != identity.candidate_vector_sha256
            or identity.calibration_plan_file_sha256
            != self.persistence.plan.plan_file_sha256
        ):
            raise P06ProductionCoordinatorV2Error(
                "scheduler/provider candidate identity differs"
            )
        return CandidateEvaluationRequestV2(
            run_id=self.run_id,
            split=split,
            logical_candidate_items=tuple(logical.items()),
            physical_candidate_items=tuple(physical.items()),
            cache_identity=identity,
            validation_admission=admission,
        )

    def _provider_outcome(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> CandidateEvaluationOutcomeV2:
        try:
            outcome = self.provider(request)
        except P06ProductionCoordinatorV2Error:
            raise
        except Exception as error:
            raise P06ProductionCoordinatorV2Error(
                "candidate provider raised instead of returning a typed V2 failure"
            ) from error
        if type(outcome) not in {
            CandidateEvaluationSuccessV2,
            CandidateEvaluationFailureV2,
        }:
            raise P06ProductionCoordinatorV2Error(
                "candidate provider returned an unauthorized result type"
            )
        document = outcome.document
        expected_schema = (
            "2.0.3"
            if type(outcome) is CandidateEvaluationSuccessV2
            else "2.0.1"
        )
        if document.get("schema_version") != expected_schema:
            raise P06ProductionCoordinatorV2Error(
                "candidate provider returned a historical schema family"
            )
        if type(outcome) is CandidateEvaluationSuccessV2:
            self._require_v2_control_authorization_bundle(document)
        return outcome

    def _require_v2_control_authorization_bundle(
        self,
        document: Mapping[str, object],
    ) -> None:
        supplied = document.get("control_authorization_bundle")
        if not isinstance(supplied, Mapping):
            raise P06ProductionCoordinatorV2Error(
                "candidate provider omitted its V2 control authorization bundle"
            )
        try:
            binding = ArtifactBindingV2(
                path=supplied["path"],
                sha256=supplied["sha256"],
                size_bytes=supplied["size_bytes"],
            )
        except (KeyError, TypeError, ValueError) as error:
            raise P06ProductionCoordinatorV2Error(
                "candidate control authorization binding is invalid"
            ) from error
        payload = _read_regular_file(
            self.root / binding.path,
            label="candidate control authorization bundle",
        )
        if len(payload) != binding.size_bytes or _sha256(payload) != binding.sha256:
            raise P06ProductionCoordinatorV2Error(
                "candidate control authorization bytes differ from their binding"
            )
        bundle = _parse_canonical_json_file(
            payload,
            label="candidate control authorization bundle",
        )
        if (
            supplied.get("artifact_kind") != CONTROL_AUTHORIZATION_BUNDLE_KIND
            or bundle.get("artifact_kind") != CONTROL_AUTHORIZATION_BUNDLE_KIND
            or bundle.get("schema_version") != "2.0.1"
        ):
            raise P06ProductionCoordinatorV2Error(
                "candidate provider returned a historical control schema family"
            )

    def _development_callback(
        self,
        logical: Mapping[str, object],
        physical: Mapping[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> Union[
        AuthenticatedDevelopmentEvaluationV2,
        AuthenticatedDevelopmentEvaluationFailureV2,
    ]:
        try:
            return self._authenticated_development_callback(
                logical,
                physical,
                identity,
            )
        except P06ProductionCoordinatorV2Error:
            raise
        except Exception as error:
            raise P06ProductionCoordinatorV2Error(
                "development evaluation authentication or publication failed"
            ) from error

    def _authenticated_development_callback(
        self,
        logical: Mapping[str, object],
        physical: Mapping[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> Union[
        AuthenticatedDevelopmentEvaluationV2,
        AuthenticatedDevelopmentEvaluationFailureV2,
    ]:
        request = self._request(
            split=DEVELOPMENT_SPLIT,
            logical=logical,
            physical=physical,
            identity=identity,
            admission=None,
        )
        outcome = self._provider_outcome(request)
        if type(outcome) is CandidateEvaluationSuccessV2:
            binding = self.persistence.calibration.publish_candidate_evaluation(
                outcome.document
            )
            reopened = self.persistence.calibration.reopen_candidate_evaluation(
                binding,
                expected_run_id=self.run_id,
                expected_split=DEVELOPMENT_SPLIT,
                expected_candidate_vector_sha256=identity.candidate_vector_sha256,
            )
            return AuthenticatedDevelopmentEvaluationV2(
                _development_evaluation(reopened.document),
                binding,
            )
        assert type(outcome) is CandidateEvaluationFailureV2
        shared = shared_bank_configuration_sha256_v2(
            physical,
            self.persistence.plan,
        )
        verified = self.persistence.calibration.verify_failure_artifact(
            outcome.document,
            expected_run_id=self.run_id,
            expected_candidate_vector_sha256=identity.candidate_vector_sha256,
            expected_shared_bank_sha256=shared,
            expected_failure_type="evaluation",
            expected_failure_reasons=outcome.failure_reasons,
        )
        binding = self.persistence.calibration.publish_failure_artifact(verified)
        return AuthenticatedDevelopmentEvaluationFailureV2(
            outcome.failure_reasons,
            binding,
        )

    def _complete_restart(self) -> Optional[P06ProductionRunResultV2]:
        selection_path = self.root / SELECTION_PATH
        if not selection_path.exists():
            return None
        selection_binding = _existing_file_binding(self.root, SELECTION_PATH)
        verified = self.persistence.reopen_calibration_selection(selection_binding)
        if verified.document.get("run_id") != self.run_id:
            raise P06ProductionCoordinatorV2Error(
                "complete restart belongs to another run"
            )
        run_binding = _existing_file_binding(self.root, RUN_LEDGER_PATH)
        admission_binding = _existing_file_binding(self.root, ADMISSION_PATH)
        manifest_binding = _existing_file_binding(self.root, ARTIFACT_MANIFEST_PATH)
        attempt = verified.run_ledger.attempt_ledger
        return P06ProductionRunResultV2(
            development=attempt.replay,
            attempt_ledger_binding=attempt.binding,
            admission_binding=admission_binding,
            run_ledger_binding=run_binding,
            selection_binding=selection_binding,
            artifact_manifest_binding=manifest_binding,
            validation_outcomes=tuple(verified.document["validation_outcomes"]),
            selection=verified.document,
            restarted_from_complete_selection=True,
        )

    def _run_development(self) -> DevelopmentSearchResultV2:
        attempt_path = self.root / ATTEMPT_LEDGER_PATH
        if not attempt_path.exists():
            return run_development_search_v2(
                self.persistence.plan,
                self._development_callback,
                fatal_evaluator_exceptions=(P06ProductionCoordinatorV2Error,),
            )
        binding = _existing_file_binding(self.root, ATTEMPT_LEDGER_PATH)
        payload = _read_regular_file(attempt_path, label=ATTEMPT_LEDGER_PATH)
        lines = payload.splitlines(keepends=True)
        if not lines:
            raise P06ProductionCoordinatorV2Error(
                "existing development attempt ledger is empty"
            )
        documents = tuple(
            _parse_canonical_json_file(
                line,
                label=f"attempt ledger record {index}",
            )
            for index, line in enumerate(lines)
        )
        record_count = len(documents)
        last = documents[-1].get("record_sha256")
        reopened = self.persistence.calibration.reopen_attempt_ledger(
            AttemptLedgerBindingV2(
                path=binding.path,
                sha256=binding.sha256,
                size_bytes=binding.size_bytes,
                record_count=record_count,
                last_record_sha256=last,
            ),
            expected_run_id=self.run_id,
        )
        return run_development_search_v2(
            self.persistence.plan,
            self._development_callback,
            resume_records=reopened.records,
            expected_resume_attempt_count=len(reopened.records),
            expected_resume_last_record_sha256=reopened.binding.last_record_sha256,
            fatal_evaluator_exceptions=(P06ProductionCoordinatorV2Error,),
        )

    @staticmethod
    def _entry(
        *,
        split: str,
        candidate_sha256: str,
        binding: ArtifactBindingV2,
    ) -> Mapping[str, object]:
        return {
            "split": split,
            "candidate_vector_sha256": candidate_sha256,
            "binding": _binding_document(binding),
        }

    def _development_entries(
        self,
        development: DevelopmentSearchResultV2,
    ) -> tuple[list[Mapping[str, object]], list[Mapping[str, object]]]:
        evaluations: dict[str, Mapping[str, object]] = {}
        failures: dict[tuple[str, str], Mapping[str, object]] = {}
        for record in development.attempt_records:
            if record.evaluation_artifact is not None:
                entry = self._entry(
                    split=DEVELOPMENT_SPLIT,
                    candidate_sha256=record.candidate_vector_sha256,
                    binding=record.evaluation_artifact,
                )
                prior = evaluations.get(record.candidate_vector_sha256)
                if prior is not None and prior != entry:
                    raise P06ProductionCoordinatorV2Error(
                        "development cache identity names different evaluations"
                    )
                evaluations[record.candidate_vector_sha256] = entry
            if record.failure_artifact is not None:
                key = (
                    record.candidate_vector_sha256,
                    record.failure_artifact.sha256,
                )
                failures[key] = self._entry(
                    split=DEVELOPMENT_SPLIT,
                    candidate_sha256=record.candidate_vector_sha256,
                    binding=record.failure_artifact,
                )
        return (
            [evaluations[key] for key in sorted(evaluations)],
            [failures[key] for key in sorted(failures)],
        )

    def _manifest_dependencies(
        self,
        *,
        attempt_binding: AttemptLedgerBindingV2,
        admission_binding: FileBindingV2,
        evaluation_entries: Sequence[Mapping[str, object]],
        failure_entries: Sequence[Mapping[str, object]],
    ) -> list[Mapping[str, object]]:
        by_path: dict[str, Mapping[str, object]] = {}

        def add(value: Mapping[str, object]) -> None:
            projected = {
                "path": value["path"],
                "sha256": value["sha256"],
                "size_bytes": value["size_bytes"],
            }
            prior = by_path.get(str(projected["path"]))
            if prior is not None and prior != projected:
                raise P06ProductionCoordinatorV2Error(
                    "run dependency path identifies different bytes"
                )
            by_path[str(projected["path"])] = projected

        add(_binding_document(attempt_binding))
        add(_binding_document(admission_binding))
        for entry in evaluation_entries:
            binding = ArtifactBindingV2(**entry["binding"])
            add(entry["binding"])
            verified = self.persistence.calibration.reopen_candidate_evaluation(
                binding,
                expected_run_id=self.run_id,
                expected_split=str(entry["split"]),
                expected_candidate_vector_sha256=str(
                    entry["candidate_vector_sha256"]
                ),
            )
            for source in verified.document["source_evidence_sha256_bindings"]:
                add(source)
            bundle = verified.document["control_authorization_bundle"]
            add(bundle)
            bundle_payload = _read_regular_file(
                self.root / str(bundle["path"]),
                label="control authorization bundle",
            )
            bundle_document = _parse_canonical_json_file(
                bundle_payload,
                label="control authorization bundle",
            )
            for dependency in bundle_document["dependency_bindings"]:
                add(dependency)
        for entry in failure_entries:
            binding = ArtifactBindingV2(**entry["binding"])
            add(entry["binding"])
            failure = self.persistence.calibration.reopen_failure_artifact(
                binding,
                expected_run_id=self.run_id,
                expected_candidate_vector_sha256=str(
                    entry["candidate_vector_sha256"]
                ),
                expected_failure_type="evaluation",
            )
            for applicable in failure["failure_bindings"].values():
                if applicable["applicable"]:
                    add(applicable["binding"])
            resume = failure["recovery"]["resume_source"]
            if resume["applicable"]:
                add(resume["binding"])
        values = [by_path[path] for path in sorted(by_path)]
        hashes = [str(value["sha256"]) for value in values]
        if len(set(hashes)) != len(hashes):
            raise P06ProductionCoordinatorV2Error(
                "run dependency bytes are aliased by different paths"
            )
        return values

    def _publish_artifact_manifest(
        self,
        dependencies: Sequence[Mapping[str, object]],
    ) -> FileBindingV2:
        directories = set()
        rows = []
        for binding in dependencies:
            parts = PurePosixPath(str(binding["path"])).parts
            for depth in range(1, len(parts)):
                directories.add(PurePosixPath(*parts[:depth]).as_posix())
            rows.append(
                {
                    **binding,
                    "producer": self.provenance.producer,
                    "gate_ids": list(self.provenance.gate_ids),
                    "command": self.provenance.command,
                    "platform": self.provenance.platform,
                    "machine": self.provenance.machine,
                }
            )
        document = {
            "schema_version": "2.0.0",
            "created_utc": self.provenance.created_utc,
            "project_commit": self.provenance.project_commit,
            "working_tree_clean": True,
            "directories": sorted(directories),
            "artifacts": rows,
        }
        return self.persistence.calibration.publish_run_artifact_manifest(document)

    def run(self) -> P06ProductionRunResultV2:
        restarted = self._complete_restart()
        if restarted is not None:
            return restarted
        development = self._run_development()
        if development.status != STATUS_TERMINATED_FEASIBLE:
            raise P06ProductionCoordinatorV2Error(
                f"development did not terminate feasible: {development.status}"
            )
        attempt_binding = self.persistence.calibration.publish_attempt_records(
            development.attempt_records,
            run_id=self.run_id,
        )
        admission_document = self.persistence.build_validation_admission_document(
            run_id=self.run_id,
            attempt_binding=attempt_binding,
        )
        admission_binding = self.persistence.publish_validation_admission(
            admission_document
        )
        admission = self.persistence.reopen_validation_admission(admission_binding)
        development_entries, development_failures = self._development_entries(
            development
        )
        validation_entries: list[Mapping[str, object]] = []
        validation_failures: list[Mapping[str, object]] = []
        outcomes: list[Mapping[str, object]] = []
        for candidate_sha256 in admission.document[
            "admitted_candidate_sha256_values"
        ]:
            candidate = admission.candidates_by_sha256[candidate_sha256]
            logical = dict(candidate.logical_candidate_items)
            physical = dict(candidate.physical_candidate_items)
            request = self._request(
                split=VALIDATION_SPLIT,
                logical=logical,
                physical=physical,
                identity=candidate.validation_cache_identity,
                admission=admission_binding,
            )
            outcome = self._provider_outcome(request)
            if type(outcome) is CandidateEvaluationSuccessV2:
                binding = self.persistence.publish_validation_candidate_evaluation(
                    admission_binding,
                    outcome.document,
                )
                verified = self.persistence.calibration.reopen_candidate_evaluation(
                    binding,
                    expected_run_id=self.run_id,
                    expected_split=VALIDATION_SPLIT,
                    expected_candidate_vector_sha256=candidate_sha256,
                )
                entry = self._entry(
                    split=VALIDATION_SPLIT,
                    candidate_sha256=candidate_sha256,
                    binding=binding,
                )
                validation_entries.append(entry)
                outcomes.append(
                    {
                        "candidate_vector_sha256": candidate_sha256,
                        "outcome_kind": "scored",
                        "evaluation": _binding_document(binding),
                        "evaluation_semantic_sha256": verified.document[
                            "evaluation_semantic_sha256"
                        ],
                    }
                )
                continue
            assert type(outcome) is CandidateEvaluationFailureV2
            binding = self.persistence.publish_validation_evaluation_failure(
                admission_binding,
                candidate_vector_sha256=candidate_sha256,
                failure_reasons=outcome.failure_reasons,
                document=outcome.document,
            )
            validation_failures.append(
                self._entry(
                    split=VALIDATION_SPLIT,
                    candidate_sha256=candidate_sha256,
                    binding=binding,
                )
            )
            outcomes.append(
                {
                    "candidate_vector_sha256": candidate_sha256,
                    "outcome_kind": "failed",
                    "failure_type": "evaluation",
                    "failure_reasons": list(outcome.failure_reasons),
                    "failure": _binding_document(binding),
                }
            )
        evaluation_entries = [*development_entries, *validation_entries]
        failure_entries = [*development_failures, *validation_failures]
        evaluation_entries.sort(
            key=lambda entry: (
                str(entry["split"]),
                str(entry["candidate_vector_sha256"]),
            )
        )
        failure_entries.sort(
            key=lambda entry: (
                str(entry["split"]),
                str(entry["candidate_vector_sha256"]),
                str(entry["binding"]["sha256"]),
            )
        )
        dependencies = self._manifest_dependencies(
            attempt_binding=attempt_binding,
            admission_binding=admission_binding,
            evaluation_entries=evaluation_entries,
            failure_entries=failure_entries,
        )
        manifest_binding = self._publish_artifact_manifest(dependencies)
        terminal_physical = dict(
            development.incumbent_physical_candidate_items or ()
        )
        input_bindings = list(authority_input_bindings_v2())
        run_document = {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_run_ledger_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": self.run_id,
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "input_bundle_sha256": input_bundle_sha256_v2(input_bindings),
            "input_bindings": input_bindings,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(
                    terminal_physical,
                    self.persistence.plan,
                )
            ),
            "maximum_development_attempt_count": MAXIMUM_DEVELOPMENT_ATTEMPTS,
            "maximum_validation_attempt_count": MAXIMUM_VALIDATION_NEIGHBORHOOD,
            "development_attempt_count": development.attempt_count,
            "validation_attempt_count": len(outcomes),
            "attempt_count": development.attempt_count,
            "attempt_ledger": {
                **_binding_document(attempt_binding),
                "record_count": attempt_binding.record_count,
                "last_record_sha256": attempt_binding.last_record_sha256,
            },
            "completed_sweeps": development.completed_sweeps,
            "development_status": development.status,
            "development_terminal_candidate_vector_sha256": (
                development.incumbent_candidate_sha256
            ),
            "validation_admission": _binding_document(admission_binding),
            "candidate_evaluations": evaluation_entries,
            "candidate_evaluation_count": len(evaluation_entries),
            "candidate_evaluation_identity_set_sha256": (
                candidate_evaluation_identity_set_sha256_v2(
                    evaluation_entries
                )
            ),
            "candidate_failures": failure_entries,
            "candidate_failure_count": len(failure_entries),
            "candidate_failure_identity_set_sha256": (
                candidate_failure_identity_set_sha256_v2(failure_entries)
            ),
            "data_separation": {
                "all_development_attempts_precede_validation": True,
                "development_validation_cache_namespaces_distinct": True,
                "validation_opened_after_development_freeze": True,
                "holdout_accessed": False,
            },
            "run_status": "selection_ready",
            "failure": None,
            "artifact_manifest": _binding_document(manifest_binding),
            "data_access": {
                "development_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": ZERO_SHA256,
        }
        run_document = dict(finalize_artifact_sha256_v2(run_document))
        run_binding = self.persistence.calibration.publish_run_ledger(run_document)
        selection_document = self.persistence.build_calibration_selection_document(
            run_binding=run_binding,
            admission_binding=admission_binding,
            outcomes=outcomes,
        )
        selection_binding = self.persistence.publish_calibration_selection(
            selection_document
        )
        verified = self.persistence.reopen_calibration_selection(
            selection_binding
        )
        return P06ProductionRunResultV2(
            development=development,
            attempt_ledger_binding=attempt_binding,
            admission_binding=admission_binding,
            run_ledger_binding=run_binding,
            selection_binding=selection_binding,
            artifact_manifest_binding=manifest_binding,
            validation_outcomes=tuple(outcomes),
            selection=verified.document,
            restarted_from_complete_selection=False,
        )
__all__ = [
    "CandidateEvaluationFailureV2",
    "CandidateEvaluationProviderV2",
    "CandidateEvaluationRequestV2",
    "CandidateEvaluationSuccessV2",
    "P06ProductionCoordinatorV2",
    "P06ProductionCoordinatorV2Error",
    "P06ProductionRunResultV2",
    "RunArtifactProvenanceV2",
]
