from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from validation.calibration_v2 import (
    calibration_selection_persistence_v2 as selection_persistence,
)
from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_persistence_v2 import (
    ArtifactBindingV2,
    FileBindingV2,
    authority_bindings_v2,
    authority_input_bindings_v2,
    candidate_evidence_sha256_v2,
    candidate_evaluation_identity_set_sha256_v2,
    candidate_failure_identity_set_sha256_v2,
    canonical_json_file_bytes_v2,
    evaluation_semantic_sha256_v2,
    finalize_artifact_sha256_v2,
    input_bundle_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    AuthenticatedDevelopmentEvaluationV2,
    DevelopmentEvaluationV2,
    EvaluationCacheIdentityV2,
    run_development_search_v2,
)
from validation.calibration_v2.calibration_selection_persistence_v2 import (
    ADMISSION_PATH,
    DISPATCH_BUDGET,
    PARETO_DIMENSIONS,
    SELECTION_PATH,
    SELECTION_TIE_BREAK,
    CalibrationSelectionPersistenceAdapterV2,
    CalibrationSelectionPersistenceV2Error,
    identity_set_sha256_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.tests.test_calibration_persistence_v2 import (
    _trusted_unit_control_verifier,
    _write_unit_control_bundle,
    _write_artifact_manifest,
    _write_control_bindings,
)


RUN_ID = "p06-v2-selection-persistence-test"
ZERO_SHA256 = "0" * 64


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _materialize_evidence(
    root: Path,
    path: str,
    label: str,
) -> dict[str, object]:
    payload = f"{label}\n".encode("utf-8")
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    return {
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _applicable_binding(
    binding: dict[str, object] | None,
) -> dict[str, object]:
    return {
        "applicable": binding is not None,
        "binding": deepcopy(binding),
    }


def _failure_bindings(
    *,
    attempt_ledger: dict[str, object] | None = None,
    trace_evidence: dict[str, object] | None = None,
    artifact_manifest: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "attempt_ledger": _applicable_binding(attempt_ledger),
        "trace_evidence": _applicable_binding(trace_evidence),
        "artifact_manifest": _applicable_binding(artifact_manifest),
        "cleanup_evidence": _applicable_binding(None),
        "recovery_evidence": _applicable_binding(None),
    }


def _failure_document(
    *,
    candidate_vector_sha256: str,
    shared_bank_sha256: str,
    failure_stage: str,
    failure_type: str,
    failure_code: str,
    failure_message: str,
    failure_reasons: tuple[str, ...] = (),
    attempt_ledger: dict[str, object] | None = None,
    trace_evidence: dict[str, object] | None = None,
    artifact_manifest: dict[str, object] | None = None,
    resume_source: dict[str, object] | None = None,
) -> dict[str, object]:
    resumable = failure_type == "evaluation"
    document = {
        "schema_version": "2.0.1",
        "artifact_kind": "p06_calibration_failure_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": RUN_ID,
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "candidate_vector_sha256": candidate_vector_sha256,
        "failure_stage": failure_stage,
        "failure_type": failure_type,
        "failure_code": failure_code,
        "failure_message": failure_message,
        "failure_reasons": list(failure_reasons),
        "failure_bindings": _failure_bindings(
            attempt_ledger=attempt_ledger,
            trace_evidence=trace_evidence,
            artifact_manifest=artifact_manifest,
        ),
        "cleanup": {
            "invoked": False,
            "idempotent": True,
            "completed": False,
            "unrelated_files_deleted": False,
        },
        "recovery": {
            "resume_allowed": resumable,
            "recovery_stage": (
                "rerun_validation_selection" if resumable else "none"
            ),
            "resume_source": _applicable_binding(resume_source),
        },
        "status": "failed_preserved",
        "data_access": {
            "development_accessed": True,
            "validation_accessed": True,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": ZERO_SHA256,
    }
    return dict(finalize_artifact_sha256_v2(document))


def _evaluation_mapping(evaluation: DevelopmentEvaluationV2) -> dict[str, object]:
    return {
        "feasible": evaluation.feasible,
        "failure_reasons": list(evaluation.failure_reasons),
        "objective": {
            "mean_y_psnr_delta_vs_fixed_db": (
                evaluation.mean_y_psnr_delta_vs_fixed_db
            ),
            "mean_y_psnr_delta_vs_non_ash_db": (
                evaluation.mean_y_psnr_delta_vs_non_ash_db
            ),
            "mean_ms_ssim_delta_vs_conventional": (
                evaluation.mean_ms_ssim_delta_vs_conventional
            ),
            "maximum_ringing_excursion": evaluation.maximum_ringing_excursion,
            "maximum_alias_ratio": evaluation.maximum_alias_ratio,
            "estimated_dispatch_cost": evaluation.estimated_dispatch_cost,
        },
    }


def _candidate_document(
    adapter: CalibrationSelectionPersistenceAdapterV2,
    *,
    physical: dict[str, object],
    split: str,
    evaluation: dict[str, object],
) -> dict[str, object]:
    candidate_sha256 = candidate_vector_sha256_v2(physical, adapter.plan)
    shared_bank_sha256 = shared_bank_configuration_sha256_v2(
        physical,
        adapter.plan,
    )
    validation_admission = None
    if split == "validation":
        admission_payload = (
            adapter.calibration._store.root / ADMISSION_PATH
        ).read_bytes()
        validation_admission = {
            "path": ADMISSION_PATH,
            "sha256": hashlib.sha256(admission_payload).hexdigest(),
            "size_bytes": len(admission_payload),
        }
    control_bundle, degradation_sha256, matrix_sha256 = (
        _write_unit_control_bundle(
            adapter.calibration._store.root,
            run_id=RUN_ID,
            split=split,
            shared_bank_sha256=shared_bank_sha256,
            validation_admission=validation_admission,
        )
    )
    document = {
        "schema_version": "2.0.3",
        "artifact_kind": "p06_candidate_evaluation_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": RUN_ID,
        "candidate_id": candidate_sha256,
        "split": split,
        "candidate_vector_sha256": candidate_sha256,
        "adapter_configuration_sha256": _sha(
            f"adapter-configuration-{split}-{candidate_sha256}"
        ),
        "physical_candidate_items": [
            [name, value] for name, value in physical.items()
        ],
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "degradation_policy_sha256": degradation_sha256,
        "source_profile_matrix_sha256": matrix_sha256,
        "evaluation_cache_identity": {
            "split": split,
            "candidate_vector_sha256": candidate_sha256,
            "calibration_plan_v2_file_sha256": adapter.plan.plan_file_sha256,
        },
        "source_evidence_sha256_bindings": [],
        "compiler_input": {
            "file_sha256": _sha(f"compiler-file-{split}-{candidate_sha256}"),
            "payload_sha256": _sha(
                f"compiler-payload-{split}-{candidate_sha256}"
            ),
        },
        "route_lut_bindings": [
            {
                "route": "direct-2x",
                "whole_file_sha256": _sha(f"2x-file-{split}-{candidate_sha256}"),
                "payload_sha256": _sha(
                    f"2x-payload-{split}-{candidate_sha256}"
                ),
            },
            {
                "route": "direct-3over2",
                "whole_file_sha256": _sha(
                    f"3over2-file-{split}-{candidate_sha256}"
                ),
                "payload_sha256": _sha(
                    f"3over2-payload-{split}-{candidate_sha256}"
                ),
            },
        ],
        "runtime_evidence_sha256": _sha(f"runtime-{split}-{candidate_sha256}"),
        "control_authorization_bundle": control_bundle,
        "evaluation": evaluation,
        "evaluation_semantic_sha256": evaluation_semantic_sha256_v2(evaluation),
        "checks": [
            {
                "check_id": "compiler-oracle",
                "status": "pass" if evaluation["feasible"] else "fail",
                "evidence_sha256": _sha(f"check-{split}-{candidate_sha256}"),
            }
        ],
        "evaluation_status": (
            "feasible" if evaluation["feasible"] else "infeasible"
        ),
        "evidence_sha256": ZERO_SHA256,
        "data_access": {
            "development_accessed": split == "development",
            "validation_accessed": split == "validation",
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": ZERO_SHA256,
    }
    root = adapter.calibration._store.root
    for gate in ("G04", "G05", "G06"):
        path = f"gates/{gate.lower()}.json"
        payload = (root / path).read_bytes()
        document["source_evidence_sha256_bindings"].append(
            {
                "id": gate,
                "path": path,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
    return dict(finalize_artifact_sha256_v2(document))


class _CountingSelectionPersistenceAdapterV2(
    CalibrationSelectionPersistenceAdapterV2
):
    def __init__(self, root: Path) -> None:
        self.admission_replay_count = 0
        self.last_admission_derivation = None
        super().__init__(
            root,
            _control_authorization_verifier=(
                _trusted_unit_control_verifier
            ),
        )

    def _admission_replay_started(self) -> None:
        self.admission_replay_count += 1

    def _derive_admission(self, **arguments: object):
        derivation = super()._derive_admission(**arguments)
        self.last_admission_derivation = derivation
        return derivation


class _TargetDevelopmentEvaluator:
    def __init__(self, adapter: CalibrationSelectionPersistenceAdapterV2) -> None:
        self.adapter = adapter
        self.target = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(adapter.plan.scalar_initial_values),
        }
        self.bindings: dict[str, ArtifactBindingV2] = {}

    def __call__(
        self,
        logical: dict[str, object],
        physical: dict[str, object],
        identity: EvaluationCacheIdentityV2,
    ) -> AuthenticatedDevelopmentEvaluationV2:
        feasible = (
            logical[ATOMIC_STRUCTURAL_COORDINATE] in {0, 1}
            and all(
                logical[name] == value
                for name, value in self.target.items()
                if name != ATOMIC_STRUCTURAL_COORDINATE
            )
        )
        failures = () if feasible else ("engine_raw:quality",)
        evaluation = DevelopmentEvaluationV2(
            feasible=feasible,
            failure_reasons=failures,
            mean_y_psnr_delta_vs_fixed_db=1 if feasible else 0,
            mean_y_psnr_delta_vs_non_ash_db=1 if feasible else 0,
            mean_ms_ssim_delta_vs_conventional=1 if feasible else 0,
            maximum_ringing_excursion=0,
            maximum_alias_ratio=0,
            estimated_dispatch_cost=0,
        )
        document = _candidate_document(
            self.adapter,
            physical=physical,
            split="development",
            evaluation=_evaluation_mapping(evaluation),
        )
        binding = self.adapter.calibration.publish_candidate_evaluation(document)
        self.bindings[identity.candidate_vector_sha256] = binding
        return AuthenticatedDevelopmentEvaluationV2(evaluation, binding)


class CalibrationSelectionInitializationV2Tests(unittest.TestCase):
    def test_selection_schema_failure_precedes_artifact_root_creation(self) -> None:
        relative_path, _ = selection_persistence._SCHEMA_SPECS[
            "calibration-selection-v2"
        ]
        schema_path = selection_persistence.CALIBRATION_ROOT / relative_path
        original_reader = selection_persistence._read_regular_file
        schema_payload = original_reader(
            schema_path,
            label="calibration-selection-v2 schema",
        )
        tampered_payload = bytes([schema_payload[0] ^ 1]) + schema_payload[1:]
        self.assertEqual(len(tampered_payload), len(schema_payload))

        def tampered_schema(path: Path, *, label: str) -> bytes:
            if Path(path) == schema_path:
                return tampered_payload
            return original_reader(path, label=label)

        with TemporaryDirectory() as temporary:
            artifact_root = Path(temporary) / "artifacts"
            with patch.object(
                selection_persistence,
                "_read_regular_file",
                side_effect=tampered_schema,
            ), self.assertRaisesRegex(
                CalibrationSelectionPersistenceV2Error,
                "schema bytes differ from the frozen digest",
            ):
                CalibrationSelectionPersistenceAdapterV2(artifact_root)
            self.assertFalse(artifact_root.exists())


class CalibrationSelectionPersistenceV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.adapter = _CountingSelectionPersistenceAdapterV2(cls.root)
        for gate in ("G04", "G05", "G06"):
            _materialize_evidence(
                cls.root,
                f"gates/{gate.lower()}.json",
                f"current-source-{gate}",
            )
        cls.evaluator = _TargetDevelopmentEvaluator(cls.adapter)
        cls.development = run_development_search_v2(
            cls.adapter.plan,
            cls.evaluator,
        )
        if cls.development.status != "terminated_feasible":
            raise AssertionError("development fixture did not terminate feasible")
        terminal_physical = dict(
            cls.development.incumbent_physical_candidate_items
        )
        control_rows = _write_control_bindings(
            cls.root,
            shared_bank_configuration_sha256_v2(
                terminal_physical,
                cls.adapter.plan,
            ),
        )
        cls.control_bindings = {
            row["id"]: deepcopy(row) for row in control_rows
        }
        cls.attempt_binding = cls.adapter.calibration.publish_attempt_records(
            cls.development.attempt_records,
            run_id=RUN_ID,
        )
        cls.admission_document = cls.adapter.build_validation_admission_document(
            run_id=RUN_ID,
            attempt_binding=cls.attempt_binding,
        )
        cls.admission_binding = cls.adapter.publish_validation_admission(
            cls.admission_document
        )
        derivation = cls.adapter.last_admission_derivation
        if derivation is None:
            raise AssertionError("admission derivation callback was not captured")
        cls.admission = SimpleNamespace(
            binding=cls.admission_binding,
            document=cls.admission_document,
            semantic=derivation.semantic,
            attempt_ledger=derivation.attempt_ledger,
            candidates_by_sha256=derivation.candidates_by_sha256,
            development_evaluations_by_sha256=(
                derivation.development_evaluations_by_sha256
            ),
        )
        if cls.admission.document["admitted_candidate_count"] != 2:
            raise AssertionError("development fixture did not admit two candidates")
        cls.admitted_sha256_values = tuple(
            cls.admission.document["admitted_candidate_sha256_values"]
        )
        cls.validation_documents = {}
        cls.validation_bindings = {}
        cls.outcomes = []
        cls.selected_sha256 = None
        cls.validation_publication_replay_count_before = (
            cls.adapter.admission_replay_count
        )
        for candidate_sha256 in cls.admitted_sha256_values:
            candidate = cls.admission.candidates_by_sha256[candidate_sha256]
            physical = dict(candidate.physical_candidate_items)
            ordinal = physical[ATOMIC_STRUCTURAL_COORDINATE]
            score = 4 if ordinal == 0 else 3
            if ordinal == 0:
                cls.selected_sha256 = candidate_sha256
            validation_evaluation = {
                "feasible": True,
                "failure_reasons": [],
                "objective": {
                    "y_vs_fixed_ci_low": score,
                    "y_vs_non_ash_ci_low": score,
                    "y_vs_conventional_ci_low": score,
                    "mean_ms_ssim_delta_vs_conventional": score,
                    "maximum_ringing_excursion": 0,
                    "maximum_alias_ratio": 0,
                    "estimated_dispatch_cost": 0,
                },
            }
            document = _candidate_document(
                cls.adapter,
                physical=physical,
                split="validation",
                evaluation=validation_evaluation,
            )
            binding = cls.adapter.publish_validation_candidate_evaluation(
                cls.admission_binding,
                document,
            )
            cls.validation_documents[candidate_sha256] = document
            cls.validation_bindings[candidate_sha256] = binding
            cls.outcomes.append(
                {
                    "candidate_vector_sha256": candidate_sha256,
                    "outcome_kind": "scored",
                    "evaluation": {
                        "path": binding.path,
                        "sha256": binding.sha256,
                        "size_bytes": binding.size_bytes,
                    },
                    "evaluation_semantic_sha256": document[
                        "evaluation_semantic_sha256"
                    ],
                }
            )
        cls.validation_publication_replay_count_after = (
            cls.adapter.admission_replay_count
        )
        if cls.selected_sha256 is None:
            raise AssertionError("ordinal-zero admitted candidate is absent")
        cls.selected_candidate = cls.admission.candidates_by_sha256[
            cls.selected_sha256
        ]
        cls.run_document = cls._build_run_ledger_document()
        cls.artifact_manifest = deepcopy(cls.run_document["artifact_manifest"])
        cls.run_binding = cls.adapter.calibration.publish_run_ledger(
            cls.run_document
        )
        cls.selection_document = cls._build_selection_document()
        cls.selection_binding = cls.adapter.publish_calibration_selection(
            cls.selection_document
        )
        cls.outcome_relation_context = SimpleNamespace(
            candidate_order=cls.admitted_sha256_values,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    @classmethod
    def _build_run_ledger_document(
        cls,
        *,
        adapter: CalibrationSelectionPersistenceAdapterV2 | None = None,
        admission_binding: FileBindingV2 | None = None,
        validation_bindings: dict[str, ArtifactBindingV2] | None = None,
        validation_failure_bindings: (
            dict[str, ArtifactBindingV2] | None
        ) = None,
        artifact_manifest: dict[str, object] | None = None,
        control_bindings: dict[str, dict[str, object]] | None = None,
    ) -> dict[str, object]:
        selected_adapter = adapter or cls.adapter
        selected_admission = admission_binding or cls.admission_binding
        selected_validation_bindings = (
            cls.validation_bindings
            if validation_bindings is None
            else validation_bindings
        )
        selected_validation_failures = (
            {}
            if validation_failure_bindings is None
            else validation_failure_bindings
        )
        del control_bindings
        inputs = list(authority_input_bindings_v2())
        entries = [
            {
                "split": "development",
                "candidate_vector_sha256": candidate_sha256,
                "binding": {
                    "path": binding.path,
                    "sha256": binding.sha256,
                    "size_bytes": binding.size_bytes,
                },
            }
            for candidate_sha256, binding in sorted(cls.evaluator.bindings.items())
        ]
        entries.extend(
            {
                "split": "validation",
                "candidate_vector_sha256": candidate_sha256,
                "binding": {
                    "path": binding.path,
                    "sha256": binding.sha256,
                    "size_bytes": binding.size_bytes,
                },
            }
            for candidate_sha256, binding in sorted(
                selected_validation_bindings.items()
            )
        )
        failures = [
            {
                "split": "validation",
                "candidate_vector_sha256": candidate_sha256,
                "binding": {
                    "path": binding.path,
                    "sha256": binding.sha256,
                    "size_bytes": binding.size_bytes,
                },
            }
            for candidate_sha256, binding in sorted(
                selected_validation_failures.items()
            )
        ]
        terminal_physical = dict(
            cls.development.incumbent_physical_candidate_items
        )
        manifest_dependencies = [
            {
                "path": cls.attempt_binding.path,
                "sha256": cls.attempt_binding.sha256,
                "size_bytes": cls.attempt_binding.size_bytes,
            },
            {
                "path": selected_admission.path,
                "sha256": selected_admission.sha256,
                "size_bytes": selected_admission.size_bytes,
            },
            *(entry["binding"] for entry in entries),
            *(entry["binding"] for entry in failures),
        ]
        for entry in entries:
            evaluation = json.loads(
                (selected_adapter.calibration._store.root / entry["binding"]["path"])
                .read_bytes()
            )
            manifest_dependencies.extend(
                evaluation["source_evidence_sha256_bindings"]
            )
            bundle_binding = evaluation["control_authorization_bundle"]
            manifest_dependencies.append(bundle_binding)
            bundle = json.loads(
                (
                    selected_adapter.calibration._store.root
                    / bundle_binding["path"]
                ).read_bytes()
            )
            manifest_dependencies.extend(bundle["dependency_bindings"])
        for entry in failures:
            failure = json.loads(
                (selected_adapter.calibration._store.root / entry["binding"]["path"])
                .read_bytes()
            )
            for applicable in failure["failure_bindings"].values():
                if applicable["applicable"]:
                    manifest_dependencies.append(applicable["binding"])
            resume = failure["recovery"]["resume_source"]
            if resume["applicable"]:
                manifest_dependencies.append(resume["binding"])
        selected_manifest = artifact_manifest or _write_artifact_manifest(
            selected_adapter.calibration._store.root,
            manifest_dependencies,
        )
        document = {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_run_ledger_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": RUN_ID,
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "input_bundle_sha256": input_bundle_sha256_v2(inputs),
            "input_bindings": inputs,
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(
                    terminal_physical,
                    selected_adapter.plan,
                )
            ),
            "maximum_development_attempt_count": 3288,
            "maximum_validation_attempt_count": 374,
            "development_attempt_count": cls.development.attempt_count,
            "validation_attempt_count": (
                len(selected_validation_bindings)
                + len(selected_validation_failures)
            ),
            "attempt_count": cls.development.attempt_count,
            "attempt_ledger": {
                "path": cls.attempt_binding.path,
                "sha256": cls.attempt_binding.sha256,
                "size_bytes": cls.attempt_binding.size_bytes,
                "record_count": cls.attempt_binding.record_count,
                "last_record_sha256": cls.attempt_binding.last_record_sha256,
            },
            "completed_sweeps": cls.development.completed_sweeps,
            "development_status": cls.development.status,
            "development_terminal_candidate_vector_sha256": (
                cls.development.incumbent_candidate_sha256
            ),
            "validation_admission": {
                "path": selected_admission.path,
                "sha256": selected_admission.sha256,
                "size_bytes": selected_admission.size_bytes,
            },
            "candidate_evaluations": entries,
            "candidate_evaluation_count": len(entries),
            "candidate_evaluation_identity_set_sha256": (
                candidate_evaluation_identity_set_sha256_v2(entries)
            ),
            "candidate_failures": failures,
            "candidate_failure_count": len(failures),
            "candidate_failure_identity_set_sha256": (
                candidate_failure_identity_set_sha256_v2(failures)
            ),
            "data_separation": {
                "all_development_attempts_precede_validation": True,
                "development_validation_cache_namespaces_distinct": True,
                "validation_opened_after_development_freeze": True,
                "holdout_accessed": False,
            },
            "run_status": "selection_ready",
            "failure": None,
            "artifact_manifest": deepcopy(selected_manifest),
            "data_access": {
                "development_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": ZERO_SHA256,
        }
        return dict(finalize_artifact_sha256_v2(document))

    @classmethod
    def _build_selection_document(cls) -> dict[str, object]:
        selected_outcome = next(
            outcome
            for outcome in cls.outcomes
            if outcome["candidate_vector_sha256"] == cls.selected_sha256
        )
        document = {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_selection_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": RUN_ID,
            "input_bundle_sha256": cls.run_document["input_bundle_sha256"],
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(
                    dict(cls.selected_candidate.physical_candidate_items),
                    cls.adapter.plan,
                )
            ),
            "calibration_run_ledger": {
                "path": cls.run_binding.path,
                "sha256": cls.run_binding.sha256,
                "size_bytes": cls.run_binding.size_bytes,
            },
            "validation_candidate_development_evidence": {
                "path": cls.admission_binding.path,
                "sha256": cls.admission_binding.sha256,
                "size_bytes": cls.admission_binding.size_bytes,
            },
            "development_terminal_candidate_vector_sha256": (
                cls.admission_document[
                    "development_terminal_candidate_vector_sha256"
                ]
            ),
            "validation_candidate_vector_sha256_values": list(
                cls.admitted_sha256_values
            ),
            "validation_candidate_count": len(cls.admitted_sha256_values),
            "validation_candidate_identity_set_sha256": identity_set_sha256_v2(
                cls.admitted_sha256_values
            ),
            "validation_outcomes": deepcopy(cls.outcomes),
            "validation_outcome_count": len(cls.outcomes),
            "validation_outcome_identity_set_sha256": identity_set_sha256_v2(
                cls.admitted_sha256_values
            ),
            "pareto_dimensions": deepcopy(PARETO_DIMENSIONS),
            "pareto_frontier_candidate_vector_sha256_values": [
                cls.selected_sha256
            ],
            "selection_tie_break": SELECTION_TIE_BREAK,
            "selected": {
                "candidate_vector_sha256": cls.selected_sha256,
                "evaluation": deepcopy(selected_outcome["evaluation"]),
                "evaluation_semantic_sha256": selected_outcome[
                    "evaluation_semantic_sha256"
                ],
            },
            "selected_control_authorization_bundle": deepcopy(
                cls.validation_documents[cls.selected_sha256][
                    "control_authorization_bundle"
                ]
            ),
            "dispatch_budget": deepcopy(DISPATCH_BUDGET),
            "selection_status": "selected",
            "data_access": {
                "development_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": ZERO_SHA256,
        }
        return dict(finalize_artifact_sha256_v2(document))

    def _verify_admission_relation_only(
        self,
        document: dict[str, object],
    ) -> None:
        snapshot = self.adapter._validate_common(
            document,
            schema_name="validation-candidate-development-evidence-v2",
            label="validation admission",
        )
        self.adapter._require_exact_admission_document(
            snapshot,
            self.admission_document,
        )

    def _verify_selection_relation_only(
        self,
        document: dict[str, object],
    ) -> None:
        snapshot = self.adapter._validate_common(
            document,
            schema_name="calibration-selection-v2",
            label="calibration selection",
        )
        self.adapter._require_exact_selection_document(
            snapshot,
            self.selection_document,
        )

    def test_admission_is_exact_development_only_374_neighbor_freeze(self) -> None:
        document = self.admission.document
        self.assertEqual(document["candidate_count_before_constraint_filtering"], 374)
        self.assertEqual(
            document["candidates_before_constraint_filtering_sha256_values"],
            sorted(document["candidates_before_constraint_filtering_sha256_values"]),
        )
        self.assertEqual(
            document["candidate_set_sha256"],
            identity_set_sha256_v2(
                document["candidates_before_constraint_filtering_sha256_values"]
            ),
        )
        self.assertEqual(
            document["constraint_valid_candidate_count"],
            document["development_evidence_count"],
        )
        self.assertEqual(document["admitted_candidate_count"], 2)
        self.assertFalse(document["validation_accessed_while_building"])
        self.assertEqual(
            document["data_access"],
            {
                "development_accessed": True,
                "validation_accessed": False,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
        )
        payload = (
            Path(os.path.realpath(self.temporary.name)) / self.admission_binding.path
        ).read_bytes()
        self.assertEqual(payload, canonical_json_file_bytes_v2(document))
        self.assertTrue(payload.endswith(b"\n"))
        self.assertFalse(payload.endswith(b"\n\n"))

    def test_validation_is_unavailable_before_admission_publication(self) -> None:
        with TemporaryDirectory() as temporary:
            adapter = CalibrationSelectionPersistenceAdapterV2(Path(temporary))
            absent = FileBindingV2(
                ADMISSION_PATH,
                _sha("absent-admission"),
                1,
            )
            document = next(iter(self.validation_documents.values()))
            with self.assertRaises(CalibrationSelectionPersistenceV2Error):
                adapter.publish_validation_candidate_evaluation(absent, document)

    def test_admission_rejects_omission_order_membership_and_data_access(self) -> None:
        omitted = deepcopy(self.admission_document)
        omitted["candidates_before_constraint_filtering_sha256_values"].pop()
        omitted["artifact_sha256"] = ZERO_SHA256
        omitted = dict(finalize_artifact_sha256_v2(omitted))
        with self.assertRaises(CalibrationSelectionPersistenceV2Error):
            self._verify_admission_relation_only(omitted)

        reordered = deepcopy(self.admission_document)
        reordered["candidates_before_constraint_filtering_sha256_values"].reverse()
        reordered = dict(finalize_artifact_sha256_v2(reordered))
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "differs from exact replay derivation",
        ):
            self._verify_admission_relation_only(reordered)

        wrong_member = deepcopy(self.admission_document)
        values = wrong_member[
            "candidates_before_constraint_filtering_sha256_values"
        ]
        values[0] = _sha("not-a-neighbor")
        values.sort()
        wrong_member["candidate_set_sha256"] = identity_set_sha256_v2(values)
        wrong_member = dict(finalize_artifact_sha256_v2(wrong_member))
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "differs from exact replay derivation",
        ):
            self._verify_admission_relation_only(wrong_member)

        accessed = deepcopy(self.admission_document)
        accessed["data_access"]["validation_accessed"] = True
        accessed = dict(finalize_artifact_sha256_v2(accessed))
        with self.assertRaises(CalibrationSelectionPersistenceV2Error):
            self._verify_admission_relation_only(accessed)

    def test_selection_persists_complete_outcomes_and_exact_pareto_winner(self) -> None:
        payload = (
            Path(os.path.realpath(self.temporary.name)) / self.selection_binding.path
        ).read_bytes()
        self.assertEqual(
            payload,
            canonical_json_file_bytes_v2(self.selection_document),
        )
        self.assertEqual(
            self.selection_document[
                "pareto_frontier_candidate_vector_sha256_values"
            ],
            [self.selected_sha256],
        )
        self.assertEqual(
            self.selection_document["dispatch_budget"],
            DISPATCH_BUDGET,
        )
        self.assertEqual(
            self.selection_document["pareto_dimensions"],
            PARETO_DIMENSIONS,
        )
        self.assertEqual(
            self.selection_document["validation_candidate_vector_sha256_values"],
            sorted(self.admitted_sha256_values),
        )
        self.assertEqual(
            self.selection_document["validation_candidate_identity_set_sha256"],
            identity_set_sha256_v2(self.admitted_sha256_values),
        )
        self.assertEqual(
            self.selection_document[
                "selected_control_authorization_bundle"
            ],
            self.validation_documents[self.selected_sha256][
                "control_authorization_bundle"
            ],
        )
        self.assertEqual(
            self.selection_document["data_access"],
            {
                "development_accessed": True,
                "validation_accessed": True,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
        )
        substituted = deepcopy(self.selection_document)
        development_binding = next(iter(self.evaluator.bindings.values()))
        development_document = json.loads(
            (self.root / development_binding.path).read_bytes()
        )
        substituted["selected_control_authorization_bundle"] = deepcopy(
            development_document["control_authorization_bundle"]
        )
        substituted = dict(finalize_artifact_sha256_v2(substituted))
        with self.assertRaises(CalibrationSelectionPersistenceV2Error):
            self._verify_selection_relation_only(substituted)

    def test_validation_publications_reuse_one_admission_authorization(self) -> None:
        self.assertEqual(self.validation_publication_replay_count_before, 1)
        self.assertEqual(
            self.validation_publication_replay_count_after,
            self.validation_publication_replay_count_before,
        )

    def test_validation_publications_snapshot_callers_and_recheck_after_delegate(
        self,
    ) -> None:
        candidate_sha256 = self.admitted_sha256_values[0]
        candidate = self.admission.candidates_by_sha256[candidate_sha256]
        candidate_document = deepcopy(
            self.validation_documents[candidate_sha256]
        )
        mutable_candidate = deepcopy(candidate_document)
        original_candidate_publish = (
            self.adapter.calibration.publish_candidate_evaluation
        )

        def publish_candidate_snapshot(
            snapshot: dict[str, object],
        ) -> ArtifactBindingV2:
            self.assertEqual(snapshot, candidate_document)
            self.assertIsNot(snapshot, mutable_candidate)
            mutable_candidate["evaluation"]["objective"][
                "maximum_alias_ratio"
            ] = 999
            return original_candidate_publish(snapshot)

        with patch.object(
            self.adapter.calibration,
            "publish_candidate_evaluation",
            side_effect=publish_candidate_snapshot,
        ):
            candidate_binding = (
                self.adapter.publish_validation_candidate_evaluation(
                    self.admission_binding,
                    mutable_candidate,
                )
            )
        self.assertEqual(
            candidate_binding,
            self.validation_bindings[candidate_sha256],
        )

        trace = _materialize_evidence(
            self.root,
            f"traces/snapshot-{candidate_sha256}.json",
            f"snapshot-failure-{candidate_sha256}",
        )
        reasons = ("engine_raw:snapshot-regression",)
        admission_reference = {
            "path": self.admission_binding.path,
            "sha256": self.admission_binding.sha256,
            "size_bytes": self.admission_binding.size_bytes,
        }
        failure_document = _failure_document(
            candidate_vector_sha256=candidate_sha256,
            shared_bank_sha256=shared_bank_configuration_sha256_v2(
                dict(candidate.physical_candidate_items),
                self.adapter.plan,
            ),
            failure_stage="validation_selection",
            failure_type="evaluation",
            failure_code="validation.evaluation.snapshot-regression",
            failure_message="validation snapshot regression",
            failure_reasons=reasons,
            trace_evidence=trace,
            resume_source=admission_reference,
        )
        mutable_failure = deepcopy(failure_document)
        original_failure_publish = (
            self.adapter.calibration.publish_failure_artifact
        )

        def publish_failure_snapshot(
            snapshot: dict[str, object],
        ) -> ArtifactBindingV2:
            self.assertEqual(snapshot, failure_document)
            self.assertIsNot(snapshot, mutable_failure)
            mutable_failure["failure_reasons"][0] = "engine_raw:mutated"
            return original_failure_publish(snapshot)

        with patch.object(
            self.adapter.calibration,
            "publish_failure_artifact",
            side_effect=publish_failure_snapshot,
        ):
            failure_binding = self.adapter.publish_validation_evaluation_failure(
                self.admission_binding,
                candidate_vector_sha256=candidate_sha256,
                failure_reasons=reasons,
                document=mutable_failure,
            )
        reopened_failure = self.adapter.calibration.reopen_failure_artifact(
            failure_binding,
            expected_run_id=RUN_ID,
            expected_candidate_vector_sha256=candidate_sha256,
            expected_failure_type="evaluation",
            expected_failure_reasons=reasons,
        )
        self.assertEqual(reopened_failure, failure_document)

        attempt_path = self.root / self.attempt_binding.path
        attempt_payload = attempt_path.read_bytes()

        def publish_candidate_then_delete_attempt(
            snapshot: dict[str, object],
        ) -> ArtifactBindingV2:
            binding = original_candidate_publish(snapshot)
            attempt_path.unlink()
            return binding

        try:
            with patch.object(
                self.adapter.calibration,
                "publish_candidate_evaluation",
                side_effect=publish_candidate_then_delete_attempt,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "postpublication validation admission dependencies changed",
                ):
                    self.adapter.publish_validation_candidate_evaluation(
                        self.admission_binding,
                        candidate_document,
                    )
        finally:
            attempt_path.write_bytes(attempt_payload)

        def publish_failure_then_delete_attempt(
            snapshot: dict[str, object],
        ) -> ArtifactBindingV2:
            binding = original_failure_publish(snapshot)
            attempt_path.unlink()
            return binding

        try:
            with patch.object(
                self.adapter.calibration,
                "publish_failure_artifact",
                side_effect=publish_failure_then_delete_attempt,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "postpublication validation admission dependencies changed",
                ):
                    self.adapter.publish_validation_evaluation_failure(
                        self.admission_binding,
                        candidate_vector_sha256=candidate_sha256,
                        failure_reasons=reasons,
                        document=failure_document,
                    )
        finally:
            attempt_path.write_bytes(attempt_payload)

    def test_cached_admission_authorization_reopens_dependency_closure(
        self,
    ) -> None:
        candidate_sha256 = self.admitted_sha256_values[0]
        candidate_document = self.validation_documents[candidate_sha256]
        development_evaluation = next(
            iter(self.admission.development_evaluations_by_sha256.values())
        )
        dependencies = (
            ("attempt-ledger", self.root / self.attempt_binding.path),
            (
                "development-evaluation",
                self.root / development_evaluation.binding.path,
            ),
            ("transitive-source", self.root / "gates/g04.json"),
        )
        replay_count = self.adapter.admission_replay_count
        for dependency_label, path in dependencies:
            for mutation in ("delete", "replace"):
                with self.subTest(
                    dependency=dependency_label,
                    mutation=mutation,
                ):
                    payload = path.read_bytes()
                    try:
                        if mutation == "delete":
                            path.unlink()
                        else:
                            path.write_bytes(payload + b"tampered")
                        with self.assertRaisesRegex(
                            CalibrationSelectionPersistenceV2Error,
                            (
                                "prepublication validation admission "
                                "dependencies changed"
                            ),
                        ):
                            self.adapter.publish_validation_candidate_evaluation(
                                self.admission_binding,
                                candidate_document,
                            )
                    finally:
                        path.write_bytes(payload)
        self.assertEqual(self.adapter.admission_replay_count, replay_count)
        self.assertEqual(
            self.adapter.publish_validation_candidate_evaluation(
                self.admission_binding,
                candidate_document,
            ),
            self.validation_bindings[candidate_sha256],
        )

    def test_publication_outputs_are_reopened_after_dependency_cascades(
        self,
    ) -> None:
        admission_path = self.root / self.admission_binding.path
        admission_payload = admission_path.read_bytes()
        derivation = self.adapter.last_admission_derivation
        if derivation is None:
            raise AssertionError("admission derivation callback was not captured")
        self.adapter._remember_pending_admission_authorization(
            self.admission_document,
            derivation,
        )
        original_dependency_reopen = (
            self.adapter._reopen_admission_dependency_closure
        )

        def reopen_then_mutate_admission(
            authorization: object,
            *,
            label: str,
        ) -> None:
            original_dependency_reopen(authorization, label=label)
            if label == "postpublication":
                admission_path.write_bytes(admission_payload + b"tampered")

        try:
            with patch.object(
                self.adapter,
                "_reopen_admission_dependency_closure",
                side_effect=reopen_then_mutate_admission,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "admission bytes changed during dependency replay",
                ):
                    self.adapter.publish_validation_admission(
                        self.admission_document
                    )
        finally:
            admission_path.write_bytes(admission_payload)

        candidate_sha256 = self.admitted_sha256_values[0]
        candidate_document = self.validation_documents[candidate_sha256]
        candidate_binding = self.validation_bindings[candidate_sha256]
        candidate_path = self.root / candidate_binding.path
        candidate_payload = candidate_path.read_bytes()

        def reopen_then_mutate_candidate(
            authorization: object,
            *,
            label: str,
        ) -> None:
            original_dependency_reopen(authorization, label=label)
            if label == "postpublication":
                candidate_path.write_bytes(candidate_payload + b"tampered")

        try:
            with patch.object(
                self.adapter,
                "_reopen_admission_dependency_closure",
                side_effect=reopen_then_mutate_candidate,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "validation evaluation changed during postpublication replay",
                ):
                    self.adapter.publish_validation_candidate_evaluation(
                        self.admission_binding,
                        candidate_document,
                    )
        finally:
            candidate_path.write_bytes(candidate_payload)

        candidate = self.admission.candidates_by_sha256[candidate_sha256]
        reasons = ("engine_raw:postpublication-output-race",)
        trace = _materialize_evidence(
            self.root,
            f"traces/output-race-{candidate_sha256}.json",
            f"output-race-{candidate_sha256}",
        )
        admission_reference = {
            "path": self.admission_binding.path,
            "sha256": self.admission_binding.sha256,
            "size_bytes": self.admission_binding.size_bytes,
        }
        failure_document = _failure_document(
            candidate_vector_sha256=candidate_sha256,
            shared_bank_sha256=shared_bank_configuration_sha256_v2(
                dict(candidate.physical_candidate_items),
                self.adapter.plan,
            ),
            failure_stage="validation_selection",
            failure_type="evaluation",
            failure_code="validation.evaluation.postpublication-output-race",
            failure_message="validation output changed during dependency replay",
            failure_reasons=reasons,
            trace_evidence=trace,
            resume_source=admission_reference,
        )
        failure_payload = canonical_json_file_bytes_v2(failure_document)
        failure_sha256 = hashlib.sha256(failure_payload).hexdigest()
        failure_path = self.root / "failures" / f"{failure_sha256}.json"

        def reopen_then_mutate_failure(
            authorization: object,
            *,
            label: str,
        ) -> None:
            original_dependency_reopen(authorization, label=label)
            if label == "postpublication":
                failure_path.write_bytes(failure_payload + b"tampered")

        try:
            with patch.object(
                self.adapter,
                "_reopen_admission_dependency_closure",
                side_effect=reopen_then_mutate_failure,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    (
                        "validation evaluation failure changed during "
                        "postpublication replay"
                    ),
                ):
                    self.adapter.publish_validation_evaluation_failure(
                        self.admission_binding,
                        candidate_vector_sha256=candidate_sha256,
                        failure_reasons=reasons,
                        document=failure_document,
                    )
        finally:
            if failure_path.exists():
                failure_path.write_bytes(failure_payload)

    def test_parent_artifacts_are_reopened_after_child_replay(self) -> None:
        run_path = self.root / self.run_binding.path
        run_payload = run_path.read_bytes()
        original_admission_reopen = self.adapter.reopen_validation_admission

        def reopen_admission_then_mutate_run(
            binding: FileBindingV2,
        ):
            reopened = original_admission_reopen(binding)
            run_path.write_bytes(run_payload + b"tampered")
            return reopened

        try:
            with patch.object(
                self.adapter,
                "reopen_validation_admission",
                side_effect=reopen_admission_then_mutate_run,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "run ledger changed during admission replay",
                ):
                    self.adapter._selection_context(
                        run_binding=self.run_binding,
                        admission_binding=self.admission_binding,
                    )
        finally:
            run_path.write_bytes(run_payload)

        selection_path = self.root / self.selection_binding.path
        selection_payload = selection_path.read_bytes()
        original_selection_context = self.adapter._selection_context
        context_count = 0

        def context_then_mutate_selection(**arguments: object):
            nonlocal context_count
            context = original_selection_context(**arguments)
            context_count += 1
            if context_count == 2:
                selection_path.write_bytes(selection_payload + b"tampered")
            return context

        try:
            with patch.object(
                self.adapter,
                "_selection_context",
                side_effect=context_then_mutate_selection,
            ):
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "selection changed during dependency replay",
                ):
                    self.adapter.publish_calibration_selection(
                        self.selection_document
                    )
        finally:
            selection_path.write_bytes(selection_payload)
        self.assertEqual(context_count, 2)

    def test_outcome_order_omission_and_membership_are_rejected(self) -> None:
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "order or membership differs",
        ):
            self.adapter._decode_validation_outcomes(
                list(reversed(self.outcomes)),
                context=self.outcome_relation_context,
            )
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "order or membership differs",
        ):
            self.adapter._decode_validation_outcomes(
                self.outcomes[:-1],
                context=self.outcome_relation_context,
            )
        arbitrary = deepcopy(self.outcomes)
        arbitrary[0]["candidate_vector_sha256"] = _sha("not-admitted")
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "order or membership differs",
        ):
            self.adapter._decode_validation_outcomes(
                arbitrary,
                context=self.outcome_relation_context,
            )

    def test_typed_validation_terminal_failure_paths(self) -> None:
        with TemporaryDirectory() as temporary:
            terminal_root = Path(temporary)
            for name in (
                "attempts-v2.ndjson",
                ADMISSION_PATH,
                "artifact-manifest-v2.json",
            ):
                shutil.copy2(self.root / name, terminal_root / name)
            for directory in (
                "evaluations",
                "failures",
                "gates",
                "controls",
                "control-dependencies",
            ):
                source = self.root / directory
                if source.exists():
                    shutil.copytree(
                        source,
                        terminal_root / directory,
                        dirs_exist_ok=True,
                    )

            adapter = _CountingSelectionPersistenceAdapterV2(terminal_root)
            admission_binding = FileBindingV2(
                path=self.admission_binding.path,
                sha256=self.admission_binding.sha256,
                size_bytes=self.admission_binding.size_bytes,
            )
            admission_document = deepcopy(self.admission_document)
            admission_reference = {
                "path": admission_binding.path,
                "sha256": admission_binding.sha256,
                "size_bytes": admission_binding.size_bytes,
            }
            failure_bindings = {}
            outcome_by_sha256 = {}
            for candidate_sha256 in self.admitted_sha256_values:
                candidate = self.admission.candidates_by_sha256[
                    candidate_sha256
                ]
                reasons = (f"engine_raw:failure-{candidate_sha256[:8]}",)
                trace = _materialize_evidence(
                    terminal_root,
                    f"traces/{candidate_sha256}.json",
                    f"validation-trace-{candidate_sha256}",
                )
                document = _failure_document(
                    candidate_vector_sha256=candidate_sha256,
                    shared_bank_sha256=shared_bank_configuration_sha256_v2(
                        dict(candidate.physical_candidate_items),
                        adapter.plan,
                    ),
                    failure_stage="validation_selection",
                    failure_type="evaluation",
                    failure_code="validation.evaluation.failed",
                    failure_message="validation evaluator failed",
                    failure_reasons=reasons,
                    trace_evidence=trace,
                    resume_source=admission_reference,
                )
                binding = adapter.publish_validation_evaluation_failure(
                    admission_binding,
                    candidate_vector_sha256=candidate_sha256,
                    failure_reasons=reasons,
                    document=document,
                )
                failure_bindings[candidate_sha256] = binding
                outcome_by_sha256[candidate_sha256] = {
                    "candidate_vector_sha256": candidate_sha256,
                    "outcome_kind": "failed",
                    "failure_type": "evaluation",
                    "failure_reasons": list(reasons),
                    "failure": {
                        "path": binding.path,
                        "sha256": binding.sha256,
                        "size_bytes": binding.size_bytes,
                    },
                }
            terminal_outcomes = [
                outcome_by_sha256[candidate_sha256]
                for candidate_sha256 in self.admitted_sha256_values
            ]
            run_document = self._build_run_ledger_document(
                adapter=adapter,
                admission_binding=admission_binding,
                validation_bindings={},
                validation_failure_bindings=failure_bindings,
                control_bindings=deepcopy(self.control_bindings),
            )
            run_payload = canonical_json_file_bytes_v2(run_document)
            run_binding = adapter.calibration._store.publish_fixed(
                "calibration-run-ledger-v2.json",
                run_payload,
            )
            terminal_sha256 = admission_document[
                "development_terminal_candidate_vector_sha256"
            ]
            terminal_candidate = self.admission.candidates_by_sha256[
                terminal_sha256
            ]
            terminal_shared_sha256 = shared_bank_configuration_sha256_v2(
                dict(terminal_candidate.physical_candidate_items),
                adapter.plan,
            )
            attempt_reference = deepcopy(
                admission_document["development_trace"]["attempt_ledger"]
            )
            run_reference = {
                "path": run_binding.path,
                "sha256": run_binding.sha256,
                "size_bytes": run_binding.size_bytes,
            }
            manifest_reference = deepcopy(run_document["artifact_manifest"])

            def terminal_document(
                *,
                stage: str = "validation_selection",
                failure_type: str = "terminal",
                shared_sha256: str = terminal_shared_sha256,
                attempt_reference_value: dict[str, object] = attempt_reference,
                trace_reference: dict[str, object] = run_reference,
                manifest_reference_value: dict[str, object] = (
                    manifest_reference
                ),
                suffix: str,
            ) -> dict[str, object]:
                is_evaluation = failure_type == "evaluation"
                reasons = ("engine_raw:wrong-type",) if is_evaluation else ()
                return _failure_document(
                    candidate_vector_sha256=terminal_sha256,
                    shared_bank_sha256=shared_sha256,
                    failure_stage=stage,
                    failure_type=failure_type,
                    failure_code=f"validation.terminal.{suffix}",
                    failure_message=f"terminal validation {suffix}",
                    failure_reasons=reasons,
                    attempt_ledger=(
                        None if is_evaluation else attempt_reference_value
                    ),
                    trace_evidence=trace_reference,
                    artifact_manifest=(
                        None if is_evaluation else manifest_reference_value
                    ),
                    resume_source=(
                        admission_reference if is_evaluation else None
                    ),
                )

            terminal_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(suffix="complete")
            )
            reopened = adapter.verify_validation_terminal_failure(
                run_binding=run_binding,
                admission_binding=admission_binding,
                outcomes=terminal_outcomes,
                terminal_failure_binding=terminal_binding,
            )
            self.assertEqual(reopened["failure_type"], "terminal")
            self.assertEqual(reopened["failure_stage"], "validation_selection")
            self.assertEqual(adapter.admission_replay_count, 2)

            wrong_trace = _materialize_evidence(
                terminal_root,
                "traces/wrong-terminal-trace.json",
                "wrong-terminal-trace",
            )
            wrong_attempt = _materialize_evidence(
                terminal_root,
                "wrong-terminal-attempts-v2.ndjson",
                "wrong-terminal-attempt-ledger",
            )
            wrong_manifest = _materialize_evidence(
                terminal_root,
                "wrong-terminal-artifact-manifest-v2.json",
                "wrong-terminal-artifact-manifest",
            )
            wrong_stage_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(stage="development_search", suffix="wrong-stage")
            )
            wrong_type_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(failure_type="evaluation", suffix="wrong-type")
            )
            wrong_shared_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(
                    shared_sha256=_sha("wrong-terminal-shared-bank"),
                    suffix="wrong-shared",
                )
            )
            wrong_trace_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(
                    trace_reference=wrong_trace,
                    suffix="wrong-trace",
                )
            )
            wrong_attempt_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(
                    attempt_reference_value=wrong_attempt,
                    suffix="wrong-attempt",
                )
            )
            wrong_manifest_binding = adapter.calibration.publish_failure_artifact(
                terminal_document(
                    manifest_reference_value=wrong_manifest,
                    suffix="wrong-manifest",
                )
            )
            admission_values = vars(self.admission).copy()
            admission_values["binding"] = admission_binding
            terminal_context = SimpleNamespace(
                admission=SimpleNamespace(**admission_values),
                candidate_order=self.admitted_sha256_values,
                run_ledger=SimpleNamespace(document=run_document),
            )
            with patch.object(
                adapter,
                "_selection_context",
                return_value=terminal_context,
            ):
                incomplete = terminal_outcomes[:-1]
                with self.assertRaises(CalibrationSelectionPersistenceV2Error):
                    adapter.verify_validation_terminal_failure(
                        run_binding=run_binding,
                        admission_binding=admission_binding,
                        outcomes=incomplete,
                        terminal_failure_binding=terminal_binding,
                    )

                reused = deepcopy(terminal_outcomes)
                reused[1]["failure"] = deepcopy(reused[0]["failure"])
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "binding is reused",
                ):
                    adapter.verify_validation_terminal_failure(
                        run_binding=run_binding,
                        admission_binding=admission_binding,
                        outcomes=reused,
                        terminal_failure_binding=terminal_binding,
                    )

                wrong_outcome_type = deepcopy(terminal_outcomes)
                wrong_outcome_type[0]["failure_type"] = "terminal"
                with self.assertRaisesRegex(
                    CalibrationSelectionPersistenceV2Error,
                    "outcome type differs",
                ):
                    adapter.verify_validation_terminal_failure(
                        run_binding=run_binding,
                        admission_binding=admission_binding,
                        outcomes=wrong_outcome_type,
                        terminal_failure_binding=terminal_binding,
                    )

                for binding in (
                    wrong_stage_binding,
                    wrong_type_binding,
                    wrong_shared_binding,
                    wrong_trace_binding,
                    wrong_attempt_binding,
                    wrong_manifest_binding,
                ):
                    with self.assertRaises(
                        CalibrationSelectionPersistenceV2Error
                    ):
                        adapter.verify_validation_terminal_failure(
                            run_binding=run_binding,
                            admission_binding=admission_binding,
                            outcomes=terminal_outcomes,
                            terminal_failure_binding=binding,
                        )

    def test_selection_rejects_pareto_winner_and_data_access_tampering(self) -> None:
        loser = next(
            value
            for value in self.admitted_sha256_values
            if value != self.selected_sha256
        )
        pareto = deepcopy(self.selection_document)
        pareto["pareto_frontier_candidate_vector_sha256_values"] = [loser]
        pareto = dict(finalize_artifact_sha256_v2(pareto))
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "differs from exact outcome ranking",
        ):
            self._verify_selection_relation_only(pareto)

        winner = deepcopy(self.selection_document)
        loser_outcome = next(
            outcome
            for outcome in self.outcomes
            if outcome["candidate_vector_sha256"] == loser
        )
        winner["selected"] = {
            "candidate_vector_sha256": loser,
            "evaluation": loser_outcome["evaluation"],
            "evaluation_semantic_sha256": loser_outcome[
                "evaluation_semantic_sha256"
            ],
        }
        winner = dict(finalize_artifact_sha256_v2(winner))
        with self.assertRaisesRegex(
            CalibrationSelectionPersistenceV2Error,
            "differs from exact outcome ranking",
        ):
            self._verify_selection_relation_only(winner)

        accessed = deepcopy(self.selection_document)
        accessed["data_access"]["holdout_accessed"] = True
        accessed = dict(finalize_artifact_sha256_v2(accessed))
        with self.assertRaises(CalibrationSelectionPersistenceV2Error):
            self._verify_selection_relation_only(accessed)

    def test_selection_publication_reopens_complete_dependency_cascade(
        self,
    ) -> None:
        outcome_binding = self.validation_bindings[
            self.admitted_sha256_values[0]
        ]
        dependencies = (
            ("run-ledger", self.root / self.run_binding.path),
            ("admission", self.root / self.admission_binding.path),
            ("validation-outcome", self.root / outcome_binding.path),
        )
        original_publish = self.adapter._store.publish_named
        for dependency_label, dependency_path in dependencies:
            with self.subTest(dependency=dependency_label):
                dependency_payload = dependency_path.read_bytes()
                callback_invoked = False

                def publish_then_mutate_dependency(
                    name: str,
                    payload: bytes,
                ) -> FileBindingV2:
                    nonlocal callback_invoked
                    binding = original_publish(name, payload)
                    dependency_path.write_bytes(dependency_payload + b"tampered")
                    callback_invoked = True
                    return binding

                try:
                    with patch.object(
                        self.adapter._store,
                        "publish_named",
                        side_effect=publish_then_mutate_dependency,
                    ):
                        with self.assertRaises(
                            CalibrationSelectionPersistenceV2Error
                        ):
                            self.adapter.publish_calibration_selection(
                                self.selection_document
                            )
                finally:
                    dependency_path.write_bytes(dependency_payload)
                self.assertTrue(callback_invoked)
        self.assertEqual(
            self.adapter.reopen_calibration_selection(
                self.selection_binding
            ).document,
            self.selection_document,
        )

    def test_selection_fixed_bytes_detect_post_publication_mutation(self) -> None:
        path = Path(os.path.realpath(self.temporary.name)) / SELECTION_PATH
        payload = path.read_bytes()
        path.write_bytes(payload + b" ")
        try:
            with self.assertRaisesRegex(
                CalibrationSelectionPersistenceV2Error,
                "calibration selection bytes are invalid",
            ):
                self.adapter.reopen_calibration_selection(
                    self.selection_binding
                )
        finally:
            path.write_bytes(payload)


if __name__ == "__main__":
    unittest.main()
