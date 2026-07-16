from __future__ import annotations

import asyncio
from dataclasses import replace
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
from tempfile import TemporaryDirectory
import threading
import time
import unittest
from unittest.mock import patch

from validation.calibration_v2 import calibration_persistence_v2 as persistence
from validation.calibration_v2 import calibration_scheduler_v2 as scheduler
from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_persistence_v2 import (
    CalibrationPersistenceAdapterV2,
    CalibrationPersistenceV2Error,
    CandidateControlProducerCapabilitiesV2,
    CandidateControlProducerRequestV2,
    FileBindingV2,
    artifact_semantic_sha256_v2,
    authority_bindings_v2,
    authority_input_bindings_v2,
    candidate_evidence_sha256_v2,
    candidate_evaluation_identity_set_sha256_v2,
    candidate_failure_identity_set_sha256_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    evaluation_semantic_sha256_v2,
    finalize_artifact_sha256_v2,
    input_bundle_sha256_v2,
    publish_authority_authentication_failure_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    ATTEMPT_STATUS_EVALUATION_FAILURE,
    ATTEMPT_STATUS_FEASIBLE,
    AuthenticatedDevelopmentEvaluationFailureV2,
    AuthenticatedDevelopmentEvaluationV2,
    ArtifactBindingV2,
    AttemptRecordV2,
    DevelopmentEvaluationV2,
    EvaluationCacheIdentityV2,
    attempt_record_sha256_v2,
    run_development_search_v2,
)
from validation.calibration_v2.control_authorization_v2 import (
    CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
    CONTROL_AUTHORIZATION_BUNDLE_KIND,
    VALIDATION_ADMISSION_KIND,
    ControlAuthorizationV2Error,
    TypedArtifactBindingV2,
    schema_sha256_for_kind_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.production_evaluator import (
    ControlExecutionProducerIdentityV2,
    ControlWriterProducerIdentityV2,
)


ZERO_SHA256 = "0" * 64
RUN_ID = "p06-v2-persistence-test"


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _binding(path: str, label: str) -> dict[str, object]:
    return {"path": path, "sha256": _sha(label), "size_bytes": 1}


def _write_evidence(
    root: Path,
    path: str,
    label: str,
    *,
    identifier: str | None = None,
) -> dict[str, object]:
    payload = f"{label}\n".encode("utf-8")
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if target.read_bytes() != payload:
            raise AssertionError(f"test evidence path collision: {path}")
    else:
        target.write_bytes(payload)
    binding: dict[str, object] = {
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }
    if identifier is not None:
        binding = {"id": identifier, **binding}
    return binding


def _trusted_unit_control_verifier(
    bundle_binding,
    *,
    evidence_snapshot,
    expected_scope,
    non_ash_profile,
    non_ash_evaluation_scope,
    validation_admission_semantic_verifier,
    control_execution_semantic_verifier,
    control_writer_semantic_verifier,
    control_execution_producer_identity,
    control_writer_producer_identity,
):
    """Narrow unit seam; production adapters use the full control verifier."""

    del (
        non_ash_profile,
        non_ash_evaluation_scope,
        control_execution_semantic_verifier,
        control_writer_semantic_verifier,
        control_execution_producer_identity,
        control_writer_producer_identity,
    )
    evidence_snapshot.payload(bundle_binding.closure_binding())
    if expected_scope.split == "development":
        if validation_admission_semantic_verifier is not None:
            raise AssertionError("development unit control received admission")
        return None
    admission = expected_scope.validation_admission
    if (
        type(admission) is not TypedArtifactBindingV2
        or not callable(validation_admission_semantic_verifier)
    ):
        raise AssertionError("validation unit control lacks trusted admission")
    document = json.loads(
        evidence_snapshot.payload(admission.closure_binding())
    )
    if validation_admission_semantic_verifier(admission, document) != document:
        raise AssertionError("validation unit admission replay differed")
    return None


def _unit_adapter(root: Path) -> CalibrationPersistenceAdapterV2:
    return CalibrationPersistenceAdapterV2(
        root,
        _control_authorization_verifier=_trusted_unit_control_verifier,
        _validation_admission_semantic_verifier=(
            lambda _binding, document: document
        ),
    )


def _write_unit_validation_admission(root: Path) -> dict[str, object]:
    payload = canonical_json_file_bytes_v2(
        {"unit_validation_admission": True}
    )
    path = "validation-candidate-development-evidence-v2.json"
    (root / path).write_bytes(payload)
    return {
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _unit_producer_capabilities(
    request: CandidateControlProducerRequestV2,
    *,
    adapter_configuration_sha256: str,
) -> CandidateControlProducerCapabilitiesV2:
    adapter_identity = canonical_json_bytes_v2(
        {
            "adapter_configuration_sha256": adapter_configuration_sha256,
            "native_executable_sha256": _sha("unit-native-executable"),
            "native_implementation_source_sha256": _sha(
                "unit-native-implementation-source"
            ),
            "native_source_manifest_sha256": _sha(
                "unit-native-source-manifest"
            ),
        }
    )
    writer_settings = canonical_json_bytes_v2(
        {"codec": "unit-codec", "quality": 100}
    )

    def reopen_execution(binding, document, context):
        del binding, context
        return document

    def reopen_writer(binding, document, context):
        del binding, context
        return document

    return CandidateControlProducerCapabilitiesV2(
        request=request,
        control_execution_semantic_verifier=reopen_execution,
        control_execution_producer_identity=(
            ControlExecutionProducerIdentityV2(
                physical_candidate_items_bytes=(
                    request.physical_candidate_items_bytes
                ),
                candidate_vector_sha256=request.candidate_vector_sha256,
                adapter_configuration_sha256=(
                    adapter_configuration_sha256
                ),
                authenticated_adapter_identity_bytes=adapter_identity,
            )
        ),
        control_writer_semantic_verifier=reopen_writer,
        control_writer_producer_identity=ControlWriterProducerIdentityV2(
            writer_settings_bytes=writer_settings,
            writer_settings_sha256=hashlib.sha256(writer_settings).hexdigest(),
            authenticated_writer_identity_bytes=canonical_json_bytes_v2(
                {"writer_binary_sha256": _sha("unit-writer-binary")}
            ),
        ),
    )


def _write_unit_control_bundle(
    root: Path,
    *,
    run_id: str,
    split: str,
    shared_bank_sha256: str,
    validation_admission: dict[str, object] | None = None,
) -> tuple[dict[str, object], str, str]:
    degradation_sha256 = _sha(f"degradation-{split}")
    matrix_sha256 = _sha(f"source-profile-matrix-{split}")
    cached_payload = f"cached operators {split} {shared_bank_sha256}\n".encode()
    cached_path = (
        f"control-dependencies/{hashlib.sha256(cached_payload).hexdigest()}.bin"
    )
    (root / cached_path).parent.mkdir(parents=True, exist_ok=True)
    (root / cached_path).write_bytes(cached_payload)
    cached_binding = {
        "artifact_kind": CACHED_OPERATOR_OUTPUT_MANIFEST_KIND,
        "schema_sha256": _sha("unit-cached-operator-schema"),
        "path": cached_path,
        "sha256": hashlib.sha256(cached_payload).hexdigest(),
        "size_bytes": len(cached_payload),
    }
    non_ash_document = {
        "artifact_kind": "p06_non_ash_selector_selection_v2",
        "split": split,
        "selection_stage": (
            "development_provisional"
            if split == "development"
            else "validation_final"
        ),
        "cached_16_operator_output_manifest_sha256": cached_binding["sha256"],
    }
    non_ash_payload = canonical_json_file_bytes_v2(non_ash_document)
    non_ash_path = (
        f"control-dependencies/{hashlib.sha256(non_ash_payload).hexdigest()}.json"
    )
    (root / non_ash_path).write_bytes(non_ash_payload)
    non_ash_binding = {
        "artifact_kind": "p06_non_ash_selector_selection_v2",
        "schema_sha256": schema_sha256_for_kind_v2(
            "p06_non_ash_selector_selection_v2"
        ),
        "path": non_ash_path,
        "sha256": hashlib.sha256(non_ash_payload).hexdigest(),
        "size_bytes": len(non_ash_payload),
    }
    dependencies = sorted(
        [cached_binding, non_ash_binding],
        key=lambda item: item["path"],
    )
    bundle = {
        "schema_version": "2.0.0",
        "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
        "run_id": run_id,
        "split": split,
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "degradation_policy_sha256": degradation_sha256,
        "source_profile_matrix_sha256": matrix_sha256,
        "control_selections": [
            {"id": "non_ash_selector", "selection": non_ash_binding}
        ],
        "dependency_bindings": dependencies,
    }
    if split == "validation":
        if validation_admission is None:
            raise AssertionError("validation unit bundle lacks admission")
        typed_admission = {
            "artifact_kind": VALIDATION_ADMISSION_KIND,
            "schema_sha256": schema_sha256_for_kind_v2(
                VALIDATION_ADMISSION_KIND
            ),
            **validation_admission,
        }
        bundle["validation_admission"] = typed_admission
        bundle["development_source_profile_matrix_sha256"] = _sha(
            "source-profile-matrix-development"
        )
        dependencies.append(typed_admission)
        dependencies.sort(key=lambda item: item["path"])
    bundle_payload = canonical_json_file_bytes_v2(bundle)
    bundle_path = f"controls/{hashlib.sha256(bundle_payload).hexdigest()}.json"
    (root / bundle_path).parent.mkdir(parents=True, exist_ok=True)
    (root / bundle_path).write_bytes(bundle_payload)
    return (
        {
            "artifact_kind": CONTROL_AUTHORIZATION_BUNDLE_KIND,
            "schema_sha256": schema_sha256_for_kind_v2(
                CONTROL_AUTHORIZATION_BUNDLE_KIND
            ),
            "path": bundle_path,
            "sha256": hashlib.sha256(bundle_payload).hexdigest(),
            "size_bytes": len(bundle_payload),
        },
        degradation_sha256,
        matrix_sha256,
    )


def _replace_unit_control_bundle(
    root: Path,
    candidate: dict[str, object],
    mutate,
) -> dict[str, object]:
    binding = candidate["control_authorization_bundle"]
    bundle = json.loads((root / binding["path"]).read_bytes())
    mutate(bundle)
    payload = canonical_json_file_bytes_v2(bundle)
    digest = hashlib.sha256(payload).hexdigest()
    path = f"controls/{digest}.json"
    (root / path).write_bytes(payload)
    candidate["control_authorization_bundle"] = {
        **binding,
        "path": path,
        "sha256": digest,
        "size_bytes": len(payload),
    }
    return _refinalize_candidate_evidence(candidate)


_CONTROL_SCHEMA_SHA256 = {
    "best_fixed": (
        "p06_fixed_control_selection",
        "646919f448ffd335e3fa168a392944c41e9c9a9403a3b523273f0fceb01439ba",
    ),
    "conventional": (
        "p06_conventional_control_selection",
        "6c299f1c2ed4a9493bd2d5b17958ca59ca1dca20b2195fa2a7fe6aba79d83069",
    ),
    "non_ash_selector": (
        "p06_non_ash_selector_selection_v2",
        "d5cfa23e51a440887c2cc50ef2816eff1e228c1fab6eb86e66ee73a849a85fa9",
    ),
}
_CONTROL_OBJECTIVE = {
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


def _write_canonical_document(
    root: Path,
    directory: str,
    document: dict[str, object],
) -> dict[str, object]:
    payload = canonical_json_file_bytes_v2(document)
    digest = hashlib.sha256(payload).hexdigest()
    path = f"{directory}/{digest}.json"
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    return {"path": path, "sha256": digest, "size_bytes": len(payload)}


def _fixed_control_document(shared_bank_sha256: str) -> dict[str, object]:
    results = [
        {
            "descriptor_id": descriptor,
            "engine_raw_corpus_mean_tuple": [2 if descriptor == 0 else 1] * 5,
            "objective_summary_sha256": _sha(f"fixed-objective-{descriptor}"),
            "output_manifest_sha256": _sha(f"fixed-output-{descriptor}"),
        }
        for descriptor in range(16)
    ]
    return {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_fixed_control_selection",
        "selection_stage": "validation_final",
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "uniform_application": True,
        "candidate_ids": list(range(16)),
        "selection_objective": deepcopy(_CONTROL_OBJECTIVE),
        "development_selection_sha256": _sha("fixed-development-selection"),
        "validation_results": results,
        "chosen_descriptor_id": 0,
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the numerically smallest descriptor ID"
        ),
    }


def _conventional_control_document(
    shared_bank_sha256: str,
) -> dict[str, object]:
    algorithms = [
        "bilinear-separable-v1",
        "keys-cubic-a-minus-0.5-separable-v1",
        "lanczos3-separable-v1",
    ]
    results = [
        {
            "algorithm_id": algorithm,
            "engine_raw_corpus_mean_tuple": [2 if index == 0 else 1] * 5,
            "objective_summary_sha256": _sha(
                f"conventional-objective-{algorithm}"
            ),
            "output_manifest_sha256": _sha(
                f"conventional-output-{algorithm}"
            ),
        }
        for index, algorithm in enumerate(algorithms)
    ]
    return {
        "schema_version": "1.1.0",
        "artifact_kind": "p06_conventional_control_selection",
        "selection_stage": "validation_final",
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "uniform_application": True,
        "candidate_ids": algorithms,
        "selection_objective": deepcopy(_CONTROL_OBJECTIVE),
        "development_selection_sha256": _sha(
            "conventional-development-selection"
        ),
        "validation_results": results,
        "chosen_algorithm_id": algorithms[0],
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending stable "
            "algorithm ID"
        ),
    }


def _non_ash_control_document(shared_bank_sha256: str) -> dict[str, object]:
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "schemas/non-ash-selector-selection-v2.schema.json"
    )
    schema = json.loads(schema_path.read_bytes())
    coordinate_order = schema["$defs"]["coordinateOrder"]["const"]
    selected_values = [0] * 27
    selected_rule_sha256 = hashlib.sha256(
        canonical_json_bytes_v2(dict(zip(coordinate_order, selected_values)))
    ).hexdigest()
    results = []
    for ordinal in range(163):
        rule_sha256 = (
            selected_rule_sha256 if ordinal == 0 else _sha(f"non-ash-rule-{ordinal}")
        )
        results.append(
            {
                "validation_candidate_ordinal": ordinal,
                "neighbor_entry_sha256": _sha(f"non-ash-neighbor-{ordinal}"),
                "rule_sha256": rule_sha256,
                "outcome": {
                    "outcome_type": "scored",
                    "evaluation_sha256": _sha(f"non-ash-evaluation-{ordinal}"),
                    "objective_summary_sha256": _sha(
                        f"non-ash-objective-{ordinal}"
                    ),
                    "engine_raw_corpus_mean_tuple": [
                        2 if ordinal == 0 else 1
                    ] * 5,
                    "output_manifest_sha256": _sha(
                        f"non-ash-output-{ordinal}"
                    ),
                },
            }
        )
    document = {
        "schema_version": "2.0.2",
        "artifact_kind": "p06_non_ash_selector_selection_v2",
        "selector_id": "continuous-linear-bank-selector-q15-v2",
        "authority_bindings": deepcopy(
            schema["$defs"]["authorityBindings"]["const"]
        ),
        "canonical_rule_serialization": {
            "coordinate_order": deepcopy(coordinate_order),
            **{
                key: deepcopy(value["const"])
                for key, value in schema["$defs"]["ruleSerialization"][
                    "properties"
                ].items()
                if key != "coordinate_order"
            },
        },
        "selection_stage": "validation_final",
        "split": "validation",
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "degradation_policy_sha256": _sha("non-ash-degradation-policy"),
        "uniform_application": True,
        "candidate_evaluation_budget": 3403,
        "maximum_validation_candidate_count": 163,
        "selection_objective": deepcopy(schema["$defs"]["objective"]["const"]),
        "cached_16_operator_output_manifest_sha256": _sha(
            "non-ash-cached-output"
        ),
        "data_access": deepcopy(schema["$defs"]["validationDataAccess"]["const"]),
        "tie_break": (
            "lexicographically maximize the validation engine_raw corpus-mean "
            "tuple, then choose the lexicographically ascending canonical "
            "serialized complete 27-member rule object"
        ),
        "development_selection_sha256": _sha("non-ash-development-selection"),
        "development_terminal_rule_sha256": _sha("non-ash-terminal-rule"),
        "validation_neighbor_manifest_sha256": _sha(
            "non-ash-neighbor-manifest"
        ),
        "validation_candidate_count": 163,
        "validation_results": results,
        "validation_status": "selected",
        "selected_control_rule_sha256": selected_rule_sha256,
        "selected_control_rule_values": selected_values,
        "validation_objective_summary_sha256": results[0]["outcome"][
            "objective_summary_sha256"
        ],
        "validation_selection_sha256": _sha("placeholder"),
    }
    document["validation_selection_sha256"] = hashlib.sha256(
        canonical_json_bytes_v2(
            {
                key: value
                for key, value in document.items()
                if key != "validation_selection_sha256"
            }
        )
    ).hexdigest()
    return document


def _write_control_bindings(
    root: Path,
    shared_bank_sha256: str,
) -> list[dict[str, object]]:
    documents = {
        "best_fixed": _fixed_control_document(shared_bank_sha256),
        "conventional": _conventional_control_document(shared_bank_sha256),
        "non_ash_selector": _non_ash_control_document(shared_bank_sha256),
    }
    controls = []
    for identifier, document in documents.items():
        artifact_kind, schema_sha256 = _CONTROL_SCHEMA_SHA256[identifier]
        controls.append(
            {
                "id": identifier,
                "artifact_kind": artifact_kind,
                "schema_sha256": schema_sha256,
                **_write_canonical_document(root, "controls", document),
            }
        )
    return controls


def _write_artifact_manifest(
    root: Path,
    bindings: list[dict[str, object]],
) -> dict[str, object]:
    by_path: dict[str, dict[str, object]] = {}
    for binding in bindings:
        projected = {
            "path": binding["path"],
            "sha256": binding["sha256"],
            "size_bytes": binding["size_bytes"],
        }
        prior = by_path.get(projected["path"])
        if prior is not None and prior != projected:
            raise AssertionError("fixture path identifies different bytes")
        by_path[projected["path"]] = projected
    rows = [
        {
            **by_path[path],
            "producer": "p06-test-fixture",
            "gate_ids": ["G06"],
            "command": "run-p06-test-fixture",
            "platform": "macOS",
            "machine": "local-test",
        }
        for path in sorted(by_path)
    ]
    directories = set()
    for path in by_path:
        parts = Path(path).parts
        for depth in range(1, len(parts)):
            directories.add("/".join(parts[:depth]))
    document = {
        "schema_version": "2.0.0",
        "created_utc": "2026-07-15T12:00:00Z",
        "project_commit": "a" * 40,
        "working_tree_clean": True,
        "directories": sorted(directories),
        "artifacts": rows,
    }
    payload = canonical_json_file_bytes_v2(document)
    target = root / "artifact-manifest-v2.json"
    target.write_bytes(payload)
    return {
        "path": "artifact-manifest-v2.json",
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _binding_document(binding: object) -> dict[str, object]:
    return {
        "path": binding.path,
        "sha256": binding.sha256,
        "size_bytes": binding.size_bytes,
    }


def _failure_bindings() -> dict[str, object]:
    return {
        name: {"applicable": False, "binding": None}
        for name in (
            "attempt_ledger",
            "trace_evidence",
            "artifact_manifest",
            "cleanup_evidence",
            "recovery_evidence",
        )
    }


def _failure_document(
    *,
    root: Path,
    candidate_vector_sha256: str | None,
    shared_bank_sha256: str | None,
    failure_type: str,
    message: str,
    code: str,
    failure_stage: str = "development_search",
    attempt_binding: object | None = None,
    artifact_manifest_binding: dict[str, object] | None = None,
) -> dict[str, object]:
    bindings = _failure_bindings()
    trace = _write_evidence(root, "failure/trace.log", "failure trace")
    manifest = _write_evidence(
        root,
        "failure/artifact-manifest.json",
        "failure artifact manifest",
    )
    recovery_stage = "none"
    resume_allowed = False
    resume_source: dict[str, object] = {
        "applicable": False,
        "binding": None,
    }
    failure_reasons: list[str] = []
    if failure_type == "evaluation":
        bindings["trace_evidence"] = {
            "applicable": True,
            "binding": trace,
        }
        recovery_stage = {
            "development_search": "resume_development_search",
            "validation_selection": "rerun_validation_selection",
        }[failure_stage]
        resume_allowed = True
        resume_source = {
            "applicable": True,
            "binding": _write_evidence(
                root,
                "failure/resume-source.json",
                "failure resume source",
            ),
        }
        failure_reasons = [message]
    elif failure_type == "constraint":
        if attempt_binding is None:
            raise AssertionError("constraint fixture needs an attempt binding")
        attempt = _binding_document(attempt_binding)
        bindings["attempt_ledger"] = {
            "applicable": True,
            "binding": attempt,
        }
        recovery_stage = "resume_development_search"
        resume_allowed = True
        resume_source = {"applicable": True, "binding": attempt}
    elif failure_type == "evidence_integrity":
        bindings["trace_evidence"] = {
            "applicable": True,
            "binding": trace,
        }
        bindings["artifact_manifest"] = {
            "applicable": True,
            "binding": manifest,
        }
        if failure_stage != "authority_authentication":
            if attempt_binding is None:
                raise AssertionError(
                    "post-authority integrity fixture needs an attempt binding"
                )
            bindings["attempt_ledger"] = {
                "applicable": True,
                "binding": _binding_document(attempt_binding),
            }
    elif failure_type == "terminal":
        if attempt_binding is None:
            raise AssertionError("terminal fixture needs an attempt binding")
        bindings["attempt_ledger"] = {
            "applicable": True,
            "binding": _binding_document(attempt_binding),
        }
        bindings["trace_evidence"] = {
            "applicable": True,
            "binding": trace,
        }
        bindings["artifact_manifest"] = {
            "applicable": True,
            "binding": (
                manifest
                if artifact_manifest_binding is None
                else deepcopy(artifact_manifest_binding)
            ),
        }
    document = {
        "schema_version": "2.0.1",
        "artifact_kind": "p06_calibration_failure_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": RUN_ID,
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "candidate_vector_sha256": candidate_vector_sha256,
        "failure_stage": failure_stage,
        "failure_type": failure_type,
        "failure_code": code,
        "failure_message": message,
        "failure_reasons": failure_reasons,
        "failure_bindings": bindings,
        "cleanup": {
            "invoked": False,
            "idempotent": True,
            "completed": False,
            "unrelated_files_deleted": False,
        },
        "recovery": {
            "resume_allowed": resume_allowed,
            "recovery_stage": recovery_stage,
            "resume_source": resume_source,
        },
        "status": "failed_preserved",
        "data_access": {
            "development_accessed": True,
            "validation_accessed": False,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": _sha("placeholder"),
    }
    return dict(finalize_artifact_sha256_v2(document))


def _development_evaluation(score: int) -> DevelopmentEvaluationV2:
    return DevelopmentEvaluationV2(
        feasible=True,
        failure_reasons=(),
        mean_y_psnr_delta_vs_fixed_db=score,
        mean_y_psnr_delta_vs_non_ash_db=score,
        mean_ms_ssim_delta_vs_conventional=score,
        maximum_ringing_excursion=0,
        maximum_alias_ratio=0,
        estimated_dispatch_cost=0,
    )


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


def _candidate_evaluation_document(
    adapter: CalibrationPersistenceAdapterV2,
    root: Path,
    physical: dict[str, object],
    evaluation: DevelopmentEvaluationV2,
) -> dict[str, object]:
    candidate_sha256 = candidate_vector_sha256_v2(physical, adapter.plan)
    evaluation_mapping = _evaluation_mapping(evaluation)
    shared_bank_sha256 = shared_bank_configuration_sha256_v2(
        physical,
        adapter.plan,
    )
    control_bundle, degradation_sha256, matrix_sha256 = (
        _write_unit_control_bundle(
            root,
            run_id=RUN_ID,
            split="development",
            shared_bank_sha256=shared_bank_sha256,
        )
    )
    document = {
        "schema_version": "2.0.3",
        "artifact_kind": "p06_candidate_evaluation_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": RUN_ID,
        "candidate_id": candidate_sha256,
        "split": "development",
        "candidate_vector_sha256": candidate_sha256,
        "adapter_configuration_sha256": _sha(
            f"adapter-configuration-{candidate_sha256}"
        ),
        "physical_candidate_items": [
            [name, value] for name, value in physical.items()
        ],
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "degradation_policy_sha256": degradation_sha256,
        "source_profile_matrix_sha256": matrix_sha256,
        "evaluation_cache_identity": {
            "split": "development",
            "candidate_vector_sha256": candidate_sha256,
            "calibration_plan_v2_file_sha256": adapter.plan.plan_file_sha256,
        },
        "source_evidence_sha256_bindings": [
            _write_evidence(
                root,
                f"gates/{gate.lower()}.json",
                f"current-source {gate}",
                identifier=gate,
            )
            for gate in ("G04", "G05", "G06")
        ],
        "compiler_input": {
            "file_sha256": _sha(f"compiler-file-{candidate_sha256}"),
            "payload_sha256": _sha(f"compiler-payload-{candidate_sha256}"),
        },
        "route_lut_bindings": [
            {
                "route": "direct-2x",
                "whole_file_sha256": _sha(f"2x-file-{candidate_sha256}"),
                "payload_sha256": _sha(f"2x-payload-{candidate_sha256}"),
            },
            {
                "route": "direct-3over2",
                "whole_file_sha256": _sha(f"3over2-file-{candidate_sha256}"),
                "payload_sha256": _sha(f"3over2-payload-{candidate_sha256}"),
            },
        ],
        "runtime_evidence_sha256": _sha(f"runtime-{candidate_sha256}"),
        "control_authorization_bundle": control_bundle,
        "evaluation": evaluation_mapping,
        "evaluation_semantic_sha256": evaluation_semantic_sha256_v2(
            evaluation_mapping
        ),
        "checks": [
            {
                "check_id": "compiler-oracle",
                "status": "pass" if evaluation.feasible else "fail",
                "evidence_sha256": _sha(f"check-{candidate_sha256}"),
            }
        ],
        "evaluation_status": "feasible" if evaluation.feasible else "infeasible",
        "evidence_sha256": _sha("placeholder-evidence"),
        "data_access": {
            "development_accessed": True,
            "validation_accessed": False,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": _sha("placeholder"),
    }
    document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
    return dict(finalize_artifact_sha256_v2(document))


def _validation_evaluation_document(
    adapter: CalibrationPersistenceAdapterV2,
    root: Path,
    physical: dict[str, object],
    *,
    validation_admission: dict[str, object],
) -> dict[str, object]:
    document = _candidate_evaluation_document(
        adapter,
        root,
        physical,
        _development_evaluation(1),
    )
    objective = {
        "y_vs_fixed_ci_low": 1,
        "y_vs_non_ash_ci_low": 1,
        "y_vs_conventional_ci_low": 1,
        "mean_ms_ssim_delta_vs_conventional": 1,
        "maximum_ringing_excursion": 0,
        "maximum_alias_ratio": 0,
        "estimated_dispatch_cost": 0,
    }
    document["split"] = "validation"
    document["evaluation_cache_identity"]["split"] = "validation"
    (
        document["control_authorization_bundle"],
        document["degradation_policy_sha256"],
        document["source_profile_matrix_sha256"],
    ) = _write_unit_control_bundle(
        root,
        run_id=RUN_ID,
        split="validation",
        shared_bank_sha256=document["shared_bank_configuration_sha256"],
        validation_admission=validation_admission,
    )
    document["evaluation"] = {
        "feasible": True,
        "failure_reasons": [],
        "objective": objective,
    }
    document["evaluation_semantic_sha256"] = evaluation_semantic_sha256_v2(
        document["evaluation"]
    )
    document["data_access"] = {
        "development_accessed": False,
        "validation_accessed": True,
        "holdout_accessed": False,
        "release_locks_written": False,
    }
    document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
    return dict(finalize_artifact_sha256_v2(document))


def _refinalize_candidate_evidence(
    document: dict[str, object],
) -> dict[str, object]:
    document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
    return dict(finalize_artifact_sha256_v2(document))


def _initial_physical(adapter: CalibrationPersistenceAdapterV2) -> dict[str, object]:
    logical = {
        ATOMIC_STRUCTURAL_COORDINATE: 0,
        **dict(adapter.plan.scalar_initial_values),
    }
    return dict(materialize_candidate_vector_v2(logical, adapter.plan))


def _first_record(
    adapter: CalibrationPersistenceAdapterV2,
    evaluation: DevelopmentEvaluationV2,
    artifact: ArtifactBindingV2,
) -> AttemptRecordV2:
    physical = _initial_physical(adapter)
    candidate_sha256 = candidate_vector_sha256_v2(physical, adapter.plan)
    draft = AttemptRecordV2(
        sequence=0,
        previous_record_sha256=ZERO_SHA256,
        record_sha256=ZERO_SHA256,
        split="development",
        phase="structural_scan",
        sweep=1,
        coordinate=ATOMIC_STRUCTURAL_COORDINATE,
        value=0,
        physical_candidate_items=tuple(physical.items()),
        candidate_vector_sha256=candidate_sha256,
        cache_identity=EvaluationCacheIdentityV2(
            split="development",
            candidate_vector_sha256=candidate_sha256,
            calibration_plan_file_sha256=adapter.plan.plan_file_sha256,
        ),
        status=ATTEMPT_STATUS_FEASIBLE,
        cache_hit=False,
        failure_reasons=(),
        canonical_failure_reasons=(),
        evaluation=evaluation,
        evaluation_artifact=artifact,
        failure_artifact=None,
    )
    return replace(draft, record_sha256=attempt_record_sha256_v2(draft))


class CalibrationPersistenceV2Tests(unittest.TestCase):
    def test_nested_closure_and_live_recheck_restore_same_owner(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            payload = b"nested-owner\n"
            (root / "nested.bin").write_bytes(payload)
            binding = FileBindingV2(
                "nested.bin",
                hashlib.sha256(payload).hexdigest(),
                len(payload),
            )
            with store.authenticated_closure() as outer:
                self.assertIs(store._active_closure_capture, outer)
                with store.authenticated_closure() as nested:
                    self.assertIs(nested, outer)
                    self.assertEqual(
                        store.reopen_relative(binding, label="nested evidence"),
                        payload,
                    )
                self.assertIs(store._active_closure_capture, outer)
                with self.assertRaisesRegex(RuntimeError, "live recheck body"):
                    with store.live_recheck():
                        self.assertIsNone(store._active_closure_capture)
                        raise RuntimeError("live recheck body")
                self.assertIs(store._active_closure_capture, outer)
            self.assertTrue(outer.closed)
            self.assertIsNone(store._active_closure_capture)

    def test_untyped_shared_capture_rejects_in_store_error_domain(self) -> None:
        with TemporaryDirectory() as temporary:
            store = persistence._AtomicArtifactStoreV2(Path(temporary))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "wrong type",
            ):
                with store.authenticated_closure(shared_capture=object()):
                    self.fail("untyped shared capture entered its body")

    def test_two_stores_share_only_the_explicit_same_owner_capture(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            owner_store = persistence._AtomicArtifactStoreV2(root)
            borrowing_store = persistence._AtomicArtifactStoreV2(root)
            payload = b"cross-store\n"
            (root / "cross-store.bin").write_bytes(payload)
            binding = FileBindingV2(
                "cross-store.bin",
                hashlib.sha256(payload).hexdigest(),
                len(payload),
            )
            with owner_store.authenticated_closure() as outer:
                with borrowing_store.authenticated_closure(
                    shared_capture=outer
                ) as borrowed:
                    self.assertIs(borrowed, outer)
                    self.assertIs(
                        borrowing_store._active_closure_capture,
                        outer,
                    )
                    self.assertEqual(
                        borrowing_store.reopen_relative(
                            binding,
                            label="cross-store evidence",
                        ),
                        payload,
                    )
                self.assertIsNone(
                    borrowing_store._active_closure_capture
                )
                self.assertIs(owner_store._active_closure_capture, outer)
                with self.assertRaisesRegex(RuntimeError, "borrower body"):
                    with borrowing_store.authenticated_closure(
                        shared_capture=outer
                    ):
                        raise RuntimeError("borrower body")
                self.assertIsNone(
                    borrowing_store._active_closure_capture
                )
                self.assertIs(owner_store._active_closure_capture, outer)
            self.assertTrue(outer.closed)

    def test_async_cancellation_closes_and_clears_owner_capture(self) -> None:
        with TemporaryDirectory() as temporary:
            store = persistence._AtomicArtifactStoreV2(Path(temporary))
            captures: list[object] = []

            async def exercise() -> None:
                entered = asyncio.Event()

                async def cancellable() -> None:
                    with store.authenticated_closure() as capture:
                        captures.append(capture)
                        entered.set()
                        await asyncio.Event().wait()

                task = asyncio.create_task(cancellable())
                await asyncio.wait_for(entered.wait(), 10.0)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
                self.assertIsNone(store._active_closure_capture)

            asyncio.run(exercise())
            self.assertEqual(len(captures), 1)
            self.assertTrue(captures[0].closed)
            self.assertEqual(store._active_closure_captures, {})

    def test_authenticated_closures_are_isolated_across_threads(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            first_payload = b"first-thread\n"
            second_payload = b"second-thread\n"
            (root / "first.bin").write_bytes(first_payload)
            (root / "second.bin").write_bytes(second_payload)
            first = FileBindingV2(
                "first.bin",
                hashlib.sha256(first_payload).hexdigest(),
                len(first_payload),
            )
            second = FileBindingV2(
                "second.bin",
                hashlib.sha256(second_payload).hexdigest(),
                len(second_payload),
            )
            first_captured = threading.Event()
            second_captured = threading.Event()
            first_exited = threading.Event()
            captures: dict[str, object] = {}
            errors: list[BaseException] = []

            def first_worker() -> None:
                try:
                    with store.authenticated_closure() as capture:
                        captures["first"] = capture
                        self.assertEqual(
                            store.reopen_relative(first, label="first thread"),
                            first_payload,
                        )
                        first_captured.set()
                        self.assertTrue(second_captured.wait(10.0))
                except BaseException as error:
                    errors.append(error)
                    first_captured.set()
                    second_captured.set()
                finally:
                    first_exited.set()

            def second_worker() -> None:
                try:
                    self.assertTrue(first_captured.wait(10.0))
                    with store.authenticated_closure() as capture:
                        captures["second"] = capture
                        self.assertIsNot(capture, captures.get("first"))
                        self.assertEqual(
                            store.reopen_relative(second, label="second thread"),
                            second_payload,
                        )
                        second_captured.set()
                        self.assertTrue(first_exited.wait(10.0))
                        self.assertFalse(capture.closed)
                        self.assertIs(store._active_closure_capture, capture)
                        self.assertEqual(
                            store.reopen_relative(second, label="second thread"),
                            second_payload,
                        )
                except BaseException as error:
                    errors.append(error)
                    second_captured.set()

            first_thread = threading.Thread(target=first_worker)
            second_thread = threading.Thread(target=second_worker)
            first_thread.start()
            second_thread.start()
            first_thread.join(15.0)
            second_thread.join(15.0)
            self.assertFalse(first_thread.is_alive())
            self.assertFalse(second_thread.is_alive())
            self.assertEqual(errors, [])
            self.assertIsNot(captures["first"], captures["second"])
            self.assertTrue(captures["first"].closed)
            self.assertTrue(captures["second"].closed)

    def test_foreign_shared_capture_is_rejected_in_store_error_domain(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            payload = b"owner-bound\n"
            (root / "owner.bin").write_bytes(payload)
            binding = FileBindingV2(
                "owner.bin",
                hashlib.sha256(payload).hexdigest(),
                len(payload),
            )
            captured = threading.Event()
            release = threading.Event()
            captures: list[object] = []
            errors: list[BaseException] = []

            def owner_worker() -> None:
                try:
                    with store.authenticated_closure() as capture:
                        captures.append(capture)
                        store.reopen_relative(binding, label="owner evidence")
                        captured.set()
                        self.assertTrue(release.wait(10.0))
                except BaseException as error:
                    errors.append(error)
                    captured.set()

            owner = threading.Thread(target=owner_worker)
            owner.start()
            self.assertTrue(captured.wait(10.0))
            try:
                self.assertEqual(len(captures), 1)
                with self.assertRaisesRegex(
                    CalibrationPersistenceV2Error,
                    "owner execution boundary",
                ):
                    with store.authenticated_closure(
                        shared_capture=captures[0]
                    ):
                        self.fail("foreign shared capture entered its body")
            finally:
                release.set()
                owner.join(15.0)
            self.assertFalse(owner.is_alive())
            self.assertEqual(errors, [])

    def test_authenticated_closures_are_isolated_across_async_tasks(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            first_payload = b"first-task\n"
            second_payload = b"second-task\n"
            (root / "first-task.bin").write_bytes(first_payload)
            (root / "second-task.bin").write_bytes(second_payload)
            first = FileBindingV2(
                "first-task.bin",
                hashlib.sha256(first_payload).hexdigest(),
                len(first_payload),
            )
            second = FileBindingV2(
                "second-task.bin",
                hashlib.sha256(second_payload).hexdigest(),
                len(second_payload),
            )
            captures: dict[str, object] = {}

            async def exercise() -> None:
                first_captured = asyncio.Event()
                second_captured = asyncio.Event()

                async def first_task() -> None:
                    with store.authenticated_closure() as capture:
                        captures["first"] = capture
                        self.assertEqual(
                            store.reopen_relative(first, label="first task"),
                            first_payload,
                        )
                        first_captured.set()
                        await asyncio.wait_for(second_captured.wait(), 10.0)

                async def second_task() -> None:
                    await asyncio.wait_for(first_captured.wait(), 10.0)
                    with store.authenticated_closure() as capture:
                        captures["second"] = capture
                        self.assertIsNot(capture, captures["first"])
                        self.assertEqual(
                            store.reopen_relative(second, label="second task"),
                            second_payload,
                        )
                        second_captured.set()

                await asyncio.gather(first_task(), second_task())

            asyncio.run(exercise())
            self.assertIsNot(captures["first"], captures["second"])
            self.assertTrue(captures["first"].closed)
            self.assertTrue(captures["second"].closed)

    def test_atomic_publication_retry_synchronizes_existing_name(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            payload = b"directory-fsync-retry\n"
            digest = hashlib.sha256(payload).hexdigest()
            expected_path = store.root / "evaluations" / f"{digest}.json"
            directory_identity = store._directory_identities["evaluations"]
            real_fsync = persistence.os.fsync
            failed_directory_fsyncs = []

            def fail_directory_fsync(descriptor: int) -> None:
                status = os.fstat(descriptor)
                if stat.S_ISDIR(status.st_mode):
                    failed_directory_fsyncs.append(
                        (status.st_dev, status.st_ino)
                    )
                    raise OSError("injected directory fsync failure")
                real_fsync(descriptor)

            with patch.object(
                persistence.os,
                "fsync",
                side_effect=fail_directory_fsync,
            ), self.assertRaises(CalibrationPersistenceV2Error):
                store.publish_content_addressed("evaluations", payload)

            self.assertEqual(expected_path.read_bytes(), payload)
            self.assertIn(directory_identity, failed_directory_fsyncs)

            retry_directory_fsyncs = []

            def observe_retry_fsync(descriptor: int) -> None:
                status = os.fstat(descriptor)
                if stat.S_ISDIR(status.st_mode):
                    retry_directory_fsyncs.append(
                        (status.st_dev, status.st_ino)
                    )
                real_fsync(descriptor)

            with patch.object(
                persistence.os,
                "fsync",
                side_effect=observe_retry_fsync,
            ):
                binding = store.publish_content_addressed(
                    "evaluations",
                    payload,
                )

            self.assertEqual(binding.path, f"evaluations/{digest}.json")
            self.assertIn(directory_identity, retry_directory_fsyncs)

    def test_restart_cleanup_covers_root_and_artifact_directories(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = persistence._AtomicArtifactStoreV2(root)
            descriptors = {
                "root": store._open_root(),
                "evaluations": store._open_directory("evaluations"),
                "failures": store._open_directory("failures"),
            }
            stale_names = {}
            try:
                for index, (label, descriptor) in enumerate(descriptors.items()):
                    stale = (
                        f"{store._TEMP_PREFIX}999999-{index}"
                        f"{store._TEMP_SUFFIX}"
                    )
                    retained = f"retained-{label}.bin"
                    stale_descriptor = os.open(
                        stale,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=descriptor,
                    )
                    retained_descriptor = os.open(
                        retained,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=descriptor,
                    )
                    os.close(stale_descriptor)
                    os.close(retained_descriptor)
                    stale_names[label] = (stale, retained)
            finally:
                for descriptor in descriptors.values():
                    os.close(descriptor)

            restarted = persistence._AtomicArtifactStoreV2(root)
            reopened_descriptors = {
                "root": restarted._open_root(),
                "evaluations": restarted._open_directory("evaluations"),
                "failures": restarted._open_directory("failures"),
            }
            try:
                for label, descriptor in reopened_descriptors.items():
                    stale, retained = stale_names[label]
                    names = set(os.listdir(descriptor))
                    self.assertNotIn(stale, names)
                    self.assertIn(retained, names)
            finally:
                for descriptor in reopened_descriptors.values():
                    os.close(descriptor)

    def test_in_process_initialization_cannot_clean_a_live_publisher(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            publisher_store = persistence._AtomicArtifactStoreV2(root)
            publisher_entered_link = threading.Event()
            release_publisher = threading.Event()
            initializer_started = threading.Event()
            cleanup_entered = threading.Event()
            initializer_completed = threading.Event()
            initialized_stores = []
            errors: list[BaseException] = []
            real_link = persistence.os.link
            original_clean = (
                persistence._AtomicArtifactStoreV2._clean_temporary_files
            )

            def pause_before_link(*args, **kwargs) -> None:
                publisher_entered_link.set()
                if not release_publisher.wait(10.0):
                    raise AssertionError("publisher release timed out")
                real_link(*args, **kwargs)

            def observe_cleanup(descriptor: int) -> None:
                cleanup_entered.set()
                original_clean(descriptor)

            def publish() -> None:
                try:
                    publisher_store.publish_content_addressed(
                        "evaluations",
                        b"serialized-in-process\n",
                    )
                except BaseException as error:
                    errors.append(error)
                    publisher_entered_link.set()

            def initialize() -> None:
                initializer_started.set()
                try:
                    initialized_stores.append(
                        persistence._AtomicArtifactStoreV2(root)
                    )
                except BaseException as error:
                    errors.append(error)
                finally:
                    initializer_completed.set()

            with patch.object(
                persistence.os,
                "link",
                side_effect=pause_before_link,
            ), patch.object(
                persistence._AtomicArtifactStoreV2,
                "_clean_temporary_files",
                side_effect=observe_cleanup,
            ):
                publisher = threading.Thread(target=publish)
                initializer = threading.Thread(target=initialize)
                publisher.start()
                try:
                    self.assertTrue(publisher_entered_link.wait(10.0))
                    initializer.start()
                    self.assertTrue(initializer_started.wait(10.0))
                    self.assertFalse(cleanup_entered.wait(0.25))
                    self.assertFalse(initializer_completed.is_set())
                finally:
                    release_publisher.set()
                publisher.join(10.0)
                initializer.join(10.0)

            self.assertFalse(publisher.is_alive())
            self.assertFalse(initializer.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(cleanup_entered.is_set())
            self.assertEqual(len(initialized_stores), 1)
            self.assertIs(
                publisher_store._publication_thread_lock,
                initialized_stores[0]._publication_thread_lock,
            )

    def test_cross_process_initialization_cannot_clean_a_live_publisher(self) -> None:
        if not hasattr(os, "fork"):
            self.skipTest("cross-process publication test requires fork")
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent_store = persistence._AtomicArtifactStoreV2(root)
            ready_read, ready_write = os.pipe()
            release_read, release_write = os.pipe()
            child_pid = os.fork()
            if child_pid == 0:
                try:
                    os.close(ready_read)
                    os.close(release_write)
                    child_store = persistence._AtomicArtifactStoreV2(root)
                    real_link = persistence.os.link

                    def pause_before_link(*args, **kwargs) -> None:
                        os.write(ready_write, b"1")
                        if os.read(release_read, 1) != b"1":
                            raise AssertionError("publisher release was invalid")
                        real_link(*args, **kwargs)

                    persistence.os.link = pause_before_link
                    child_store.publish_content_addressed(
                        "evaluations",
                        b"serialized-cross-process\n",
                    )
                    os._exit(0)
                except BaseException:
                    os._exit(2)

            os.close(ready_write)
            os.close(release_read)
            initializer_started = threading.Event()
            cleanup_entered = threading.Event()
            initializer_completed = threading.Event()
            errors: list[BaseException] = []
            original_clean = (
                persistence._AtomicArtifactStoreV2._clean_temporary_files
            )

            def observe_cleanup(descriptor: int) -> None:
                cleanup_entered.set()
                original_clean(descriptor)

            def initialize() -> None:
                initializer_started.set()
                try:
                    persistence._AtomicArtifactStoreV2(root)
                except BaseException as error:
                    errors.append(error)
                finally:
                    initializer_completed.set()

            readable, _, _ = select.select([ready_read], [], [], 10.0)
            self.assertEqual(readable, [ready_read])
            self.assertEqual(os.read(ready_read, 1), b"1")
            initializer = threading.Thread(target=initialize)
            with patch.object(
                persistence._AtomicArtifactStoreV2,
                "_clean_temporary_files",
                side_effect=observe_cleanup,
            ):
                initializer.start()
                try:
                    self.assertTrue(initializer_started.wait(10.0))
                    self.assertFalse(cleanup_entered.wait(0.25))
                    self.assertFalse(initializer_completed.is_set())
                    descriptor = parent_store._open_directory("evaluations")
                    try:
                        live_temporaries = [
                            name
                            for name in os.listdir(descriptor)
                            if name.startswith(parent_store._TEMP_PREFIX)
                            and name.endswith(parent_store._TEMP_SUFFIX)
                        ]
                    finally:
                        os.close(descriptor)
                    self.assertEqual(len(live_temporaries), 1)
                finally:
                    os.write(release_write, b"1")
                initializer.join(10.0)

            os.close(ready_read)
            os.close(release_write)
            self.assertFalse(initializer.is_alive())
            self.assertEqual(errors, [])
            self.assertTrue(cleanup_entered.is_set())

            child_status = None
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
                if waited_pid == child_pid:
                    child_status = status
                    break
                time.sleep(0.01)
            if child_status is None:
                os.kill(child_pid, signal.SIGKILL)
                os.waitpid(child_pid, 0)
                self.fail("cross-process publisher did not exit")
            self.assertTrue(os.WIFEXITED(child_status))
            self.assertEqual(os.WEXITSTATUS(child_status), 0)

    def test_store_rejects_symlink_root_and_root_identity_replacement(self) -> None:
        with TemporaryDirectory() as temporary:
            parent = Path(os.path.realpath(temporary))
            real = parent / "real"
            real.mkdir()
            linked = parent / "linked"
            linked.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "root itself must not be a symlink",
            ):
                CalibrationPersistenceAdapterV2(linked)

            root = parent / "store"
            adapter = _unit_adapter(root)
            displaced = parent / "displaced"
            root.rename(displaced)
            root.mkdir()
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "closure artifact root differs from its pinned identity",
            ):
                adapter.publish_candidate_evaluation(
                    _candidate_evaluation_document(
                        adapter,
                        root,
                        _initial_physical(adapter),
                        _development_evaluation(1),
                    )
                )

    def test_candidate_publication_reopens_exact_lf_bytes(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            physical = _initial_physical(adapter)
            evaluation = _development_evaluation(7)
            document = _candidate_evaluation_document(
                adapter,
                root,
                physical,
                evaluation,
            )
            binding = adapter.publish_candidate_evaluation(document)
            actual_root = Path(os.path.realpath(temporary))
            payload = (actual_root / binding.path).read_bytes()

            self.assertEqual(payload, canonical_json_file_bytes_v2(document))
            self.assertTrue(payload.endswith(b"\n"))
            self.assertFalse(payload.endswith(b"\n\n"))
            self.assertEqual(hashlib.sha256(payload).hexdigest(), binding.sha256)
            self.assertNotEqual(binding.sha256, document["artifact_sha256"])
            self.assertEqual(
                artifact_semantic_sha256_v2(document),
                document["artifact_sha256"],
            )
            reopened = adapter.reopen_candidate_evaluation(binding)
            self.assertEqual(reopened.document, document)
            self.assertEqual(reopened.physical_candidate_items, tuple(physical.items()))
            self.assertEqual(reopened.development_evaluation, evaluation)

            wrong_digest = _sha("wrong-candidate-binding")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "binding differs from canonical document bytes",
            ):
                adapter.verify_candidate_evaluation(
                    document,
                    binding=ArtifactBindingV2(
                        path=f"evaluations/{wrong_digest}.json",
                        sha256=wrong_digest,
                        size_bytes=len(payload),
                    ),
                )

    def test_candidate_semantic_and_authority_tampering_is_rejected(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            document = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            tampered = deepcopy(document)
            tampered["evaluation_semantic_sha256"] = _sha("wrong")
            tampered = dict(finalize_artifact_sha256_v2(tampered))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "evaluation identities differ",
            ):
                adapter.publish_candidate_evaluation(tampered)

            tampered = deepcopy(document)
            tampered["authority_bindings"]["calibration_plan_v2"][
                "file_sha256"
            ] = _sha("wrong-plan")
            tampered = dict(finalize_artifact_sha256_v2(tampered))
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter.publish_candidate_evaluation(tampered)

            tampered = deepcopy(document)
            tampered["physical_candidate_items"][1][1] = "wrong-policy"
            tampered = dict(finalize_artifact_sha256_v2(tampered))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "reconstruct",
            ):
                adapter.publish_candidate_evaluation(tampered)

    def test_candidate_complete_evidence_and_check_relations_are_recomputed(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            physical = _initial_physical(adapter)
            document = _candidate_evaluation_document(
                adapter,
                root,
                physical,
                _development_evaluation(1),
            )
            projection = deepcopy(document)
            del projection["evidence_sha256"]
            del projection["artifact_sha256"]
            self.assertEqual(
                document["evidence_sha256"],
                hashlib.sha256(canonical_json_bytes_v2(projection)).hexdigest(),
            )

            arbitrary = deepcopy(document)
            arbitrary["evidence_sha256"] = _sha("arbitrary-evidence")
            arbitrary = dict(finalize_artifact_sha256_v2(arbitrary))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "complete-evidence SHA-256 differs",
            ):
                adapter.verify_candidate_evaluation(arbitrary)

            failed_check = deepcopy(document)
            failed_check["checks"][0]["status"] = "fail"
            failed_check = _refinalize_candidate_evidence(failed_check)
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter.verify_candidate_evaluation(failed_check)

            infeasible = DevelopmentEvaluationV2(
                feasible=False,
                failure_reasons=("engine_raw:compiler_invariants",),
                mean_y_psnr_delta_vs_fixed_db=0,
                mean_y_psnr_delta_vs_non_ash_db=0,
                mean_ms_ssim_delta_vs_conventional=0,
                maximum_ringing_excursion=0,
                maximum_alias_ratio=0,
                estimated_dispatch_cost=0,
            )
            infeasible_document = _candidate_evaluation_document(
                adapter,
                root,
                physical,
                infeasible,
            )
            adapter.verify_candidate_evaluation(infeasible_document)
            missing_failed_check = deepcopy(infeasible_document)
            missing_failed_check["checks"][0]["status"] = "pass"
            missing_failed_check = _refinalize_candidate_evidence(
                missing_failed_check
            )
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter.verify_candidate_evaluation(missing_failed_check)

            uncanonicalizable = DevelopmentEvaluationV2(
                feasible=False,
                failure_reasons=("unscoped-failure",),
                mean_y_psnr_delta_vs_fixed_db=0,
                mean_y_psnr_delta_vs_non_ash_db=0,
                mean_ms_ssim_delta_vs_conventional=0,
                maximum_ringing_excursion=0,
                maximum_alias_ratio=0,
                estimated_dispatch_cost=0,
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure reasons are not canonicalizable",
            ):
                adapter.verify_candidate_evaluation(
                    _candidate_evaluation_document(
                        adapter,
                        root,
                        physical,
                        uncanonicalizable,
                    )
                )

    def test_candidate_control_bundle_type_scope_and_dependencies_fail_closed(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)

            def candidate() -> dict[str, object]:
                return _candidate_evaluation_document(
                    adapter,
                    root,
                    _initial_physical(adapter),
                    _development_evaluation(1),
                )

            scalar = candidate()
            scalar.pop("control_authorization_bundle")
            scalar["control_evidence_sha256"] = _sha("legacy-controls")
            scalar = _refinalize_candidate_evidence(scalar)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "schema validation failed",
            ):
                adapter.verify_candidate_evaluation(scalar)

            wrong_schema = candidate()
            wrong_schema["control_authorization_bundle"][
                "schema_sha256"
            ] = _sha("wrong-control-bundle-schema")
            wrong_schema = _refinalize_candidate_evidence(wrong_schema)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "schema validation failed",
            ):
                adapter.verify_candidate_evaluation(wrong_schema)

            for field, value in (
                ("run_id", "different-run"),
                ("split", "validation"),
                ("shared_bank_configuration_sha256", _sha("wrong-bank")),
                ("source_profile_matrix_sha256", _sha("wrong-matrix")),
            ):
                with self.subTest(bundle_field=field):
                    mismatched = _replace_unit_control_bundle(
                        root,
                        candidate(),
                        lambda bundle, field=field, value=value: bundle.__setitem__(
                            field,
                            value,
                        ),
                    )
                    with self.assertRaisesRegex(
                        CalibrationPersistenceV2Error,
                        "control bundle scope differs",
                    ):
                        adapter.verify_candidate_evaluation(mismatched)

            matrix = candidate()
            matrix["source_profile_matrix_sha256"] = _sha(
                "caller-substituted-matrix"
            )
            matrix = _refinalize_candidate_evidence(matrix)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "control bundle scope differs",
            ):
                adapter.verify_candidate_evaluation(matrix)

            omitted = _replace_unit_control_bundle(
                root,
                candidate(),
                lambda bundle: bundle.__setitem__(
                    "dependency_bindings",
                    [
                        dependency
                        for dependency in bundle["dependency_bindings"]
                        if dependency["artifact_kind"]
                        != CACHED_OPERATOR_OUTPUT_MANIFEST_KIND
                    ],
                ),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "non-ASH selection scope differs",
            ):
                adapter.verify_candidate_evaluation(omitted)

            mutated = candidate()
            bundle = json.loads(
                (
                    root
                    / mutated["control_authorization_bundle"]["path"]
                ).read_bytes()
            )
            dependency = next(
                value
                for value in bundle["dependency_bindings"]
                if value["artifact_kind"]
                == CACHED_OPERATOR_OUTPUT_MANIFEST_KIND
            )
            (root / dependency["path"]).write_bytes(b"mutated dependency\n")
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter.verify_candidate_evaluation(mutated)

    def test_candidate_control_replay_requires_production_seams_and_is_closure_local(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)

            def execution_required(*args, **kwargs):
                del args
                if any(
                    kwargs[name] is None
                    for name in (
                        "control_execution_semantic_verifier",
                        "control_writer_semantic_verifier",
                        "control_execution_producer_identity",
                        "control_writer_producer_identity",
                    )
                ):
                    raise ControlAuthorizationV2Error(
                        "trusted control producer capabilities are absent"
                    )

            production_adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=execution_required,
            )
            production_document = _candidate_evaluation_document(
                production_adapter,
                root,
                _initial_physical(production_adapter),
                _development_evaluation(1),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "control authorization replay failed",
            ):
                production_adapter.verify_candidate_evaluation(
                    production_document
                )

        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = []

            def counting_verifier(*args, **kwargs):
                calls.append(kwargs["expected_scope"])
                return _trusted_unit_control_verifier(*args, **kwargs)

            adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=counting_verifier,
            )
            document = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            with adapter._store.authenticated_closure():
                adapter.verify_candidate_evaluation(document)
                adapter.verify_candidate_evaluation(document)
            self.assertEqual(len(calls), 1)
            adapter.verify_candidate_evaluation(document)
            self.assertEqual(len(calls), 2)

    def test_candidate_control_producer_capabilities_reject_config_and_request_substitution(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            omitted = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            omitted.pop("adapter_configuration_sha256")
            omitted = _refinalize_candidate_evidence(omitted)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "schema validation failed",
            ):
                adapter.verify_candidate_evaluation(omitted)

        def checked_verifier(*args, **kwargs):
            self.assertTrue(
                callable(kwargs["control_execution_semantic_verifier"])
            )
            self.assertTrue(
                callable(kwargs["control_writer_semantic_verifier"])
            )
            self.assertIsInstance(
                kwargs["control_execution_producer_identity"],
                ControlExecutionProducerIdentityV2,
            )
            self.assertIsInstance(
                kwargs["control_writer_producer_identity"],
                ControlWriterProducerIdentityV2,
            )
            return _trusted_unit_control_verifier(*args, **kwargs)

        with TemporaryDirectory() as temporary:
            root = Path(temporary)

            def mutated_provider(request):
                return _unit_producer_capabilities(
                    request,
                    adapter_configuration_sha256=_sha(
                        "provider-returned-wrong-configuration"
                    ),
                )

            adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=checked_verifier,
                _control_producer_capability_provider=mutated_provider,
            )
            document = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "producer identity differs",
            ):
                adapter.verify_candidate_evaluation(document)

        with TemporaryDirectory() as temporary:
            root = Path(temporary)

            def reconstructed_provider(request):
                return _unit_producer_capabilities(
                    request,
                    adapter_configuration_sha256=_sha(
                        "adapter-configuration-"
                        f"{request.candidate_vector_sha256}"
                    ),
                )

            adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=checked_verifier,
                _control_producer_capability_provider=(
                    reconstructed_provider
                ),
            )
            substituted = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            substituted["adapter_configuration_sha256"] = _sha(
                "same-vector-substituted-configuration"
            )
            substituted = _refinalize_candidate_evidence(substituted)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "producer identity differs",
            ):
                adapter.verify_candidate_evaluation(substituted)

        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            saved_capabilities = []

            def cached_provider(request):
                if saved_capabilities:
                    return saved_capabilities[0]
                capabilities = _unit_producer_capabilities(
                    request,
                    adapter_configuration_sha256=_sha(
                        "adapter-configuration-"
                        f"{request.candidate_vector_sha256}"
                    ),
                )
                saved_capabilities.append(capabilities)
                return capabilities

            adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=checked_verifier,
                _control_producer_capability_provider=cached_provider,
            )
            first = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            logical = {
                ATOMIC_STRUCTURAL_COORDINATE: 1,
                **dict(adapter.plan.scalar_initial_values),
            }
            second_physical = dict(
                materialize_candidate_vector_v2(logical, adapter.plan)
            )
            second = _candidate_evaluation_document(
                adapter,
                root,
                second_physical,
                _development_evaluation(2),
            )
            adapter.verify_candidate_evaluation(first)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "producer capabilities differ",
            ):
                adapter.verify_candidate_evaluation(second)

    def test_persistence_reauthenticates_before_accepting_provider_identity(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            verifier_calls = []

            def provider(request):
                return _unit_producer_capabilities(
                    request,
                    adapter_configuration_sha256=_sha(
                        "adapter-configuration-"
                        f"{request.candidate_vector_sha256}"
                    ),
                )

            adapter = CalibrationPersistenceAdapterV2(
                root,
                _control_authorization_verifier=(
                    lambda *args, **kwargs: verifier_calls.append(
                        (args, kwargs)
                    )
                ),
                _control_producer_capability_provider=provider,
            )
            document = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            with patch.object(
                persistence,
                "authenticate_control_execution_producer_identity_authority_v2",
                side_effect=ControlAuthorizationV2Error(
                    "injected producer authority drift"
                ),
            ), self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "control authorization replay failed",
            ):
                adapter.verify_candidate_evaluation(document)
            self.assertEqual(verifier_calls, [])

    def test_candidate_source_bindings_are_reopened_from_the_pinned_root(
        self,
    ) -> None:
        for mode in ("missing", "wrong-bytes", "stale-hash", "stale-size"):
            with self.subTest(mode=mode), TemporaryDirectory() as temporary:
                root = Path(temporary)
                adapter = _unit_adapter(root)
                document = _candidate_evaluation_document(
                    adapter,
                    root,
                    _initial_physical(adapter),
                    _development_evaluation(1),
                )
                source = document["source_evidence_sha256_bindings"][0]
                target = root / source["path"]
                if mode == "missing":
                    target.unlink()
                elif mode == "wrong-bytes":
                    target.write_bytes(b"replaced source evidence\n")
                elif mode == "stale-hash":
                    source["sha256"] = _sha("stale-source-hash")
                    document = _refinalize_candidate_evidence(document)
                else:
                    source["size_bytes"] += 1
                    document = _refinalize_candidate_evidence(document)
                with self.assertRaises(CalibrationPersistenceV2Error):
                    adapter.verify_candidate_evaluation(document)

        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            document = _candidate_evaluation_document(
                adapter,
                root,
                _initial_physical(adapter),
                _development_evaluation(1),
            )
            real_gates = root / "real-gates"
            (root / "gates").rename(real_gates)
            (root / "gates").symlink_to(real_gates, target_is_directory=True)
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "closure directory gates cannot be safely opened",
            ):
                adapter.verify_candidate_evaluation(document)

    def test_relative_file_binding_rejects_control_characters(self) -> None:
        for path in (
            "gates/g04\n.json",
            "gates/g04\t.json",
            "gates/é.json",
            "../outside.json",
            "/absolute.json",
        ):
            with self.subTest(path=path), self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "file binding is invalid",
            ):
                FileBindingV2(path, _sha("binding"), 1)

    def test_authority_input_binding_rejects_same_size_byte_mutation(
        self,
    ) -> None:
        target = (
            persistence.REPOSITORY_ROOT
            / "validation/calibration_v2/contracts/calibration-plan-v2.json"
        )
        original_reader = persistence._read_regular_file
        original_payload = original_reader(
            target,
            label="calibration_plan_v2 authority",
        )
        mutated_payload = bytes([original_payload[0] ^ 1]) + original_payload[1:]
        self.assertEqual(len(mutated_payload), len(original_payload))

        def same_size_mutation(path, *, label):
            payload = original_reader(path, label=label)
            if Path(path) == target:
                return mutated_payload
            return payload

        with patch.object(
            persistence,
            "_read_regular_file",
            side_effect=same_size_mutation,
        ), self.assertRaisesRegex(
            CalibrationPersistenceV2Error,
            "authority bytes differ from the frozen digest",
        ):
            authority_input_bindings_v2()

    def test_producer_authority_is_fifth_of_six_and_changes_bundle_identity(
        self,
    ) -> None:
        inputs = list(authority_input_bindings_v2())
        self.assertEqual(
            [row["id"] for row in inputs],
            [
                "baseline_ablation_budget_v2",
                "calibration_plan_v2",
                "candidate_evidence_policy_v2",
                "compiler_contract_v2",
                "control_execution_producer_identity_v2",
                "shared_bank_configuration_identity_v2",
            ],
        )
        self.assertEqual(
            list(authority_bindings_v2()),
            [row["id"] for row in inputs],
        )
        self.assertEqual(
            input_bundle_sha256_v2(inputs),
            "64faa8aab6a9147ba446e34caef9a5f9a314dd75cd45c8ef862628ca2c2cb468",
        )
        old_five_inputs = [
            row
            for row in inputs
            if row["id"] != "control_execution_producer_identity_v2"
        ]
        self.assertNotEqual(
            input_bundle_sha256_v2(inputs),
            input_bundle_sha256_v2(old_five_inputs),
        )

    def test_producer_authority_failure_precedes_artifact_root_creation(
        self,
    ) -> None:
        authority_id = "control_execution_producer_identity_v2"
        authority_spec = persistence._AUTHORITY_SPECS[authority_id]
        original_reader = persistence._read_regular_file
        for target_key in ("path", "schema_path"):
            target = persistence.REPOSITORY_ROOT / str(
                authority_spec[target_key]
            )
            payload = original_reader(
                target,
                label=f"{authority_id} {target_key}",
            )
            tampered_payload = bytes([payload[0] ^ 1]) + payload[1:]

            def missing(path, *, label, target=target):
                if Path(path) == target:
                    raise CalibrationPersistenceV2Error(
                        "producer identity authority is missing"
                    )
                return original_reader(path, label=label)

            def tampered(path, *, label, target=target):
                if Path(path) == target:
                    return tampered_payload
                return original_reader(path, label=label)

            for mode, reader in (("missing", missing), ("tampered", tampered)):
                with self.subTest(
                    target=target_key,
                    mode=mode,
                ), TemporaryDirectory() as temporary:
                    artifact_root = Path(temporary) / "artifacts"
                    with patch.object(
                        persistence,
                        "_read_regular_file",
                        side_effect=reader,
                    ), patch.object(
                        persistence,
                        "_AtomicArtifactStoreV2",
                    ) as store, self.assertRaises(
                        CalibrationPersistenceV2Error
                    ):
                        CalibrationPersistenceAdapterV2(artifact_root)
                    store.assert_not_called()
                    self.assertFalse(artifact_root.exists())

        with TemporaryDirectory() as temporary:
            artifact_root = Path(temporary) / "artifacts"
            with patch.dict(
                authority_spec,
                {"file_sha256": _sha("stale-producer-authority")},
            ), patch.object(
                persistence,
                "_AtomicArtifactStoreV2",
            ) as store, self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "authority triple differs",
            ):
                CalibrationPersistenceAdapterV2(artifact_root)
            store.assert_not_called()
            self.assertFalse(artifact_root.exists())

        contract_path = persistence.REPOSITORY_ROOT / str(
            authority_spec["path"]
        )
        contract = json.loads(
            original_reader(
                contract_path,
                label=f"{authority_id} authority",
            )
        )
        contract["artifact_sha256"] = _sha("stale-producer-self")
        self_drift_payload = canonical_json_file_bytes_v2(contract)
        schema_path = persistence.REPOSITORY_ROOT / str(
            authority_spec["schema_path"]
        )
        self_drift_schema = json.loads(
            original_reader(
                schema_path,
                label=f"{authority_id} authority schema",
            )
        )
        self_drift_schema["const"] = contract
        self_drift_schema_payload = canonical_json_file_bytes_v2(
            self_drift_schema
        )

        def self_drift(path, *, label):
            if Path(path) == contract_path:
                return self_drift_payload
            if Path(path) == schema_path:
                return self_drift_schema_payload
            return original_reader(path, label=label)

        with TemporaryDirectory() as temporary:
            artifact_root = Path(temporary) / "artifacts"
            with patch.dict(
                authority_spec,
                {
                    "file_sha256": hashlib.sha256(
                        self_drift_payload
                    ).hexdigest(),
                    "schema_file_sha256": hashlib.sha256(
                        self_drift_schema_payload
                    ).hexdigest(),
                },
            ), patch.object(
                persistence,
                "_read_regular_file",
                side_effect=self_drift,
            ), patch.object(
                persistence,
                "_AtomicArtifactStoreV2",
            ) as store, self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "self-hash differs",
            ):
                CalibrationPersistenceAdapterV2(artifact_root)
            store.assert_not_called()
            self.assertFalse(artifact_root.exists())

    def test_strict_reopen_rejects_duplicate_and_nonfinite_json(self) -> None:
        for payload in (
            b'{"artifact_kind":"x","artifact_kind":"y"}\n',
            b'{"artifact_kind":"x","value":NaN}\n',
        ):
            with self.subTest(payload=payload):
                with TemporaryDirectory() as temporary:
                    adapter = CalibrationPersistenceAdapterV2(Path(temporary))
                    digest = hashlib.sha256(payload).hexdigest()
                    binding = ArtifactBindingV2(
                        path=f"evaluations/{digest}.json",
                        sha256=digest,
                        size_bytes=len(payload),
                    )
                    path = Path(os.path.realpath(temporary)) / binding.path
                    path.write_bytes(payload)
                    with self.assertRaises(CalibrationPersistenceV2Error):
                        adapter.reopen_candidate_evaluation(binding)

    def test_controls_and_run_manifest_are_typed_exact_and_race_stable(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            shared_bank_sha256 = _sha("control-manifest-shared-bank")
            controls = _write_control_bindings(root, shared_bank_sha256)
            self.assertEqual(
                len(
                    adapter._verify_control_selection_artifacts(
                        controls,
                        expected_shared_bank_sha256=shared_bank_sha256,
                    )
                ),
                3,
            )

            plain_payload = b"arbitrary plain-text control\n"
            plain_sha256 = hashlib.sha256(plain_payload).hexdigest()
            plain_path = root / "controls" / f"{plain_sha256}.json"
            plain_path.write_bytes(plain_payload)
            untyped_controls = deepcopy(controls)
            untyped_controls[0] = {
                "id": "best_fixed",
                "artifact_kind": "p06_fixed_control_selection",
                "schema_sha256": _CONTROL_SCHEMA_SHA256["best_fixed"][1],
                "path": f"controls/{plain_sha256}.json",
                "sha256": plain_sha256,
                "size_bytes": len(plain_payload),
            }
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter._verify_control_selection_artifacts(
                    untyped_controls,
                    expected_shared_bank_sha256=shared_bank_sha256,
                )

            wrong_fixed = _fixed_control_document(shared_bank_sha256)
            wrong_fixed["chosen_descriptor_id"] = 1
            wrong_fixed_binding = _write_canonical_document(
                root,
                "controls",
                wrong_fixed,
            )
            wrong_fixed_controls = deepcopy(controls)
            wrong_fixed_controls[0] = {
                "id": "best_fixed",
                "artifact_kind": "p06_fixed_control_selection",
                "schema_sha256": _CONTROL_SCHEMA_SHA256["best_fixed"][1],
                **wrong_fixed_binding,
            }
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "best-fixed control chosen validation winner differs",
            ):
                adapter._verify_control_selection_artifacts(
                    wrong_fixed_controls,
                    expected_shared_bank_sha256=shared_bank_sha256,
                )

            wrong_non_ash = _non_ash_control_document(shared_bank_sha256)
            wrong_non_ash["validation_results"][0]["outcome"][
                "engine_raw_corpus_mean_tuple"
            ] = [0] * 5
            wrong_non_ash["validation_selection_sha256"] = hashlib.sha256(
                canonical_json_bytes_v2(
                    {
                        key: value
                        for key, value in wrong_non_ash.items()
                        if key != "validation_selection_sha256"
                    }
                )
            ).hexdigest()
            wrong_non_ash_binding = _write_canonical_document(
                root,
                "controls",
                wrong_non_ash,
            )
            wrong_non_ash_controls = deepcopy(controls)
            wrong_non_ash_controls[2] = {
                "id": "non_ash_selector",
                "artifact_kind": "p06_non_ash_selector_selection_v2",
                "schema_sha256": _CONTROL_SCHEMA_SHA256[
                    "non_ash_selector"
                ][1],
                **wrong_non_ash_binding,
            }
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "non-ASH selected validation winner differs",
            ):
                adapter._verify_control_selection_artifacts(
                    wrong_non_ash_controls,
                    expected_shared_bank_sha256=shared_bank_sha256,
                )

            first = _write_evidence(root, "deps/first.txt", "first")
            second = _write_evidence(root, "deps/second.txt", "second")

            def file_binding(document: dict[str, object]) -> FileBindingV2:
                return FileBindingV2(
                    document["path"],
                    document["sha256"],
                    document["size_bytes"],
                )

            required = [file_binding(first), file_binding(second)]
            manifest_document = _write_artifact_manifest(root, [first, second])
            manifest_binding = file_binding(manifest_document)
            adapter._verify_run_artifact_manifest(
                manifest_binding,
                required_bindings=required,
                cycle_excluded_failure_paths=(),
            )

            extra = _write_evidence(root, "deps/extra.txt", "extra")
            extra_manifest = file_binding(
                _write_artifact_manifest(root, [first, second, extra])
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "dependency closure differs",
            ):
                adapter._verify_run_artifact_manifest(
                    extra_manifest,
                    required_bindings=required,
                    cycle_excluded_failure_paths=(),
                )

            manifest_document = _write_artifact_manifest(root, [first, second])
            manifest_path = root / manifest_document["path"]
            decoded_manifest = json.loads(manifest_path.read_bytes())
            decoded_manifest["directories"].append("unused")
            extra_directory_payload = canonical_json_file_bytes_v2(decoded_manifest)
            manifest_path.write_bytes(extra_directory_payload)
            extra_directory_binding = FileBindingV2(
                manifest_document["path"],
                hashlib.sha256(extra_directory_payload).hexdigest(),
                len(extra_directory_payload),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "directory closure differs",
            ):
                adapter._verify_run_artifact_manifest(
                    extra_directory_binding,
                    required_bindings=required,
                    cycle_excluded_failure_paths=(),
                )

            missing_manifest = file_binding(
                _write_artifact_manifest(root, [second])
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "dependency closure differs",
            ):
                adapter._verify_run_artifact_manifest(
                    missing_manifest,
                    required_bindings=required,
                    cycle_excluded_failure_paths=(first["path"],),
                )

            race_manifest = file_binding(
                _write_artifact_manifest(root, [first, second])
            )
            first_path = root / first["path"]
            first_payload = first_path.read_bytes()
            replacement = b"other\n"
            self.assertEqual(len(first_payload), len(replacement))
            original_reopen = adapter._store._reopen_relative_snapshot
            mutated = False

            def mutate_earlier_row(binding, *, label):
                nonlocal mutated
                result = original_reopen(binding, label=label)
                if binding.path == second["path"] and not mutated:
                    first_path.write_bytes(replacement)
                    mutated = True
                return result

            with patch.object(
                adapter._store,
                "_reopen_relative_snapshot",
                side_effect=mutate_earlier_row,
            ), self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "manifest artifact deps/first.txt",
            ):
                adapter._verify_run_artifact_manifest(
                    race_manifest,
                    required_bindings=required,
                    cycle_excluded_failure_paths=(),
                )

    def test_fixed_and_content_addressed_reopen_reject_path_swap(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            evaluation = _development_evaluation(3)
            physical = _initial_physical(adapter)
            artifact = adapter.publish_candidate_evaluation(
                _candidate_evaluation_document(
                    adapter,
                    root,
                    physical,
                    evaluation,
                )
            )
            record = _first_record(adapter, evaluation, artifact)
            attempt_binding = adapter.publish_attempt_records(
                (record,),
                run_id=RUN_ID,
            )
            actual_root = Path(os.path.realpath(temporary))

            cases = (
                (
                    "content-addressed",
                    actual_root / artifact.path,
                    lambda: adapter.reopen_candidate_evaluation(artifact),
                ),
                (
                    "fixed",
                    actual_root / attempt_binding.path,
                    lambda: adapter.reopen_attempt_ledger(
                        attempt_binding,
                        expected_run_id=RUN_ID,
                    ),
                ),
            )
            original_read = os.read
            for label, target, reopen in cases:
                with self.subTest(kind=label):
                    payload = target.read_bytes()
                    displaced = target.with_name(f"{target.name}.displaced")
                    swapped = False

                    def swap_after_first_read(descriptor, count):
                        nonlocal swapped
                        chunk = original_read(descriptor, count)
                        if not swapped:
                            target.rename(displaced)
                            target.write_bytes(payload)
                            swapped = True
                        return chunk

                    try:
                        with patch.object(
                            os,
                            "read",
                            side_effect=swap_after_first_read,
                        ), self.assertRaisesRegex(
                            CalibrationPersistenceV2Error,
                            "changed while read",
                        ):
                            reopen()
                    finally:
                        if displaced.exists():
                            target.unlink(missing_ok=True)
                            displaced.rename(target)

    def test_candidate_and_failure_parent_paths_remain_stable_across_dependencies(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            physical = _initial_physical(adapter)
            candidate_sha256 = candidate_vector_sha256_v2(
                physical,
                adapter.plan,
            )
            shared_sha256 = shared_bank_configuration_sha256_v2(
                physical,
                adapter.plan,
            )
            candidate_binding = adapter.publish_candidate_evaluation(
                _candidate_evaluation_document(
                    adapter,
                    root,
                    physical,
                    _development_evaluation(1),
                )
            )
            failure_binding = adapter.publish_failure_artifact(
                _failure_document(
                    root=root,
                    candidate_vector_sha256=candidate_sha256,
                    shared_bank_sha256=shared_sha256,
                    failure_type="evaluation",
                    message="transient evaluator failure",
                    code="evaluation.transient",
                )
            )
            actual_root = Path(os.path.realpath(temporary))

            for label, binding, reopen in (
                (
                    "candidate evaluation",
                    candidate_binding,
                    lambda: adapter.reopen_candidate_evaluation(
                        candidate_binding
                    ),
                ),
                (
                    "P06 failure artifact",
                    failure_binding,
                    lambda: adapter.reopen_failure_artifact(failure_binding),
                ),
            ):
                with self.subTest(parent=label):
                    target = actual_root / binding.path
                    payload = target.read_bytes()
                    displaced = target.with_name(f"{target.name}.displaced")
                    original_reopen = adapter._reopen_relative_file_binding
                    swapped = False

                    def swap_after_dependency(*args, **kwargs):
                        nonlocal swapped
                        reopened = original_reopen(*args, **kwargs)
                        if not swapped:
                            target.rename(displaced)
                            target.write_bytes(payload)
                            swapped = True
                        return reopened

                    try:
                        with patch.object(
                            adapter,
                            "_reopen_relative_file_binding",
                            side_effect=swap_after_dependency,
                        ), self.assertRaisesRegex(
                            CalibrationPersistenceV2Error,
                            "changed during final validation",
                        ):
                            reopen()
                    finally:
                        if displaced.exists():
                            target.unlink(missing_ok=True)
                            displaced.rename(target)

    def test_attempt_codec_reopens_evaluation_before_replay(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            evaluation = _development_evaluation(3)
            physical = _initial_physical(adapter)
            artifact = adapter.publish_candidate_evaluation(
                _candidate_evaluation_document(adapter, root, physical, evaluation)
            )
            record = _first_record(adapter, evaluation, artifact)
            binding = adapter.publish_attempt_records((record,), run_id=RUN_ID)
            reopened = adapter.reopen_attempt_ledger(
                binding,
                expected_run_id=RUN_ID,
            )
            self.assertEqual(reopened.records, (record,))
            self.assertEqual(reopened.replay.status, "in_progress")

            actual_root = Path(os.path.realpath(temporary))
            attempt_path = actual_root / binding.path
            attempt_payload = attempt_path.read_bytes()
            attempt_path.write_bytes(attempt_payload + b" ")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "bytes differ from the closure binding",
            ):
                adapter.reopen_attempt_ledger(binding, expected_run_id=RUN_ID)
            attempt_path.write_bytes(attempt_payload)

            path = actual_root / artifact.path
            path.write_bytes(path.read_bytes() + b" ")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "bytes differ from the closure binding",
            ):
                adapter.reopen_attempt_ledger(binding, expected_run_id=RUN_ID)

    def test_cache_hit_requires_prior_reopened_cache_identity(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            evaluation = _development_evaluation(3)
            physical = _initial_physical(adapter)
            artifact = adapter.publish_candidate_evaluation(
                _candidate_evaluation_document(adapter, root, physical, evaluation)
            )
            source = _first_record(adapter, evaluation, artifact)
            draft = replace(
                source,
                cache_hit=True,
                record_sha256=ZERO_SHA256,
            )
            cache_hit = replace(
                draft,
                record_sha256=attempt_record_sha256_v2(draft),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "semantic replay failed",
            ):
                adapter.publish_attempt_records((cache_hit,), run_id=RUN_ID)

    def test_failure_reference_type_and_shared_bank_are_authenticated(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            physical = _initial_physical(adapter)
            candidate_sha256 = candidate_vector_sha256_v2(
                physical,
                adapter.plan,
            )
            shared_sha256 = shared_bank_configuration_sha256_v2(
                physical,
                adapter.plan,
            )
            binding = adapter.publish_failure_artifact(
                _failure_document(
                    root=root,
                    candidate_vector_sha256=candidate_sha256,
                    shared_bank_sha256=shared_sha256,
                    failure_type="evaluation",
                    message="provider failed",
                    code="evaluation.provider",
                )
            )
            adapter.reopen_failure_artifact(
                binding,
                expected_run_id=RUN_ID,
                expected_candidate_vector_sha256=candidate_sha256,
                expected_shared_bank_sha256=shared_sha256,
                expected_failure_type="evaluation",
                expected_failure_reasons=("provider failed",),
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure type differs",
            ):
                adapter.reopen_failure_artifact(
                    binding,
                    expected_failure_type="terminal",
                )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "shared-bank identity differs",
            ):
                adapter.reopen_failure_artifact(
                    binding,
                    expected_shared_bank_sha256=_sha("other-shared-bank"),
                )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "candidate identity differs",
            ):
                adapter.reopen_failure_artifact(
                    binding,
                    expected_candidate_vector_sha256=_sha("other-candidate"),
                )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure reasons differ",
            ):
                adapter.reopen_failure_artifact(
                    binding,
                    expected_failure_reasons=("different failure",),
                )
            wrong_digest = _sha("wrong-failure-binding")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "binding differs from canonical document bytes",
            ):
                adapter.verify_failure_artifact(
                    adapter.reopen_failure_artifact(binding),
                    binding=ArtifactBindingV2(
                        path=f"failures/{wrong_digest}.json",
                        sha256=wrong_digest,
                        size_bytes=binding.size_bytes,
                    ),
                )

    def test_failure_type_relations_and_applicable_evidence_are_enforced(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            physical = _initial_physical(adapter)
            candidate_sha256 = candidate_vector_sha256_v2(
                physical,
                adapter.plan,
            )
            shared_sha256 = shared_bank_configuration_sha256_v2(
                physical,
                adapter.plan,
            )
            evaluation = _development_evaluation(1)
            evaluation_binding = adapter.publish_candidate_evaluation(
                _candidate_evaluation_document(
                    adapter,
                    root,
                    physical,
                    evaluation,
                )
            )
            attempt_binding = adapter.publish_attempt_records(
                (_first_record(adapter, evaluation, evaluation_binding),),
                run_id=RUN_ID,
            )

            integrity = _failure_document(
                root=root,
                candidate_vector_sha256=candidate_sha256,
                shared_bank_sha256=shared_sha256,
                failure_type="evidence_integrity",
                message="stale evidence",
                code="integrity.stale-evidence",
                attempt_binding=attempt_binding,
            )
            adapter.verify_failure_artifact(
                integrity,
                expected_candidate_vector_sha256=candidate_sha256,
                expected_failure_reasons=(),
            )
            trace_binding = integrity["failure_bindings"]["trace_evidence"][
                "binding"
            ]
            trace_path = root / trace_binding["path"]
            trace_payload = trace_path.read_bytes()
            trace_path.unlink()
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure trace evidence",
            ):
                adapter.verify_failure_artifact(integrity)
            trace_path.write_bytes(trace_payload)

            manifest_binding = integrity["failure_bindings"][
                "artifact_manifest"
            ]["binding"]
            manifest_path = root / manifest_binding["path"]
            manifest_payload = manifest_path.read_bytes()
            manifest_path.write_bytes(b"stale manifest bytes\n")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure artifact manifest bytes differ from the closure binding",
            ):
                adapter.verify_failure_artifact(integrity)
            manifest_path.write_bytes(manifest_payload)

            terminal = _failure_document(
                root=root,
                candidate_vector_sha256=candidate_sha256,
                shared_bank_sha256=shared_sha256,
                failure_type="terminal",
                message="development stopped",
                code="terminal.development-stopped",
                attempt_binding=attempt_binding,
            )
            adapter.verify_failure_artifact(terminal)
            missing_terminal_trace = deepcopy(terminal)
            missing_terminal_trace["failure_bindings"]["trace_evidence"] = {
                "applicable": False,
                "binding": None,
            }
            missing_terminal_trace = dict(
                finalize_artifact_sha256_v2(missing_terminal_trace)
            )
            with self.assertRaises(CalibrationPersistenceV2Error):
                adapter.verify_failure_artifact(missing_terminal_trace)

            evaluation_failure = _failure_document(
                root=root,
                candidate_vector_sha256=candidate_sha256,
                shared_bank_sha256=shared_sha256,
                failure_type="evaluation",
                message="provider stopped",
                code="evaluation.provider-stopped",
            )
            adapter.verify_failure_artifact(
                evaluation_failure,
                expected_failure_reasons=("provider stopped",),
            )
            resume_binding = evaluation_failure["recovery"]["resume_source"][
                "binding"
            ]
            resume_path = root / resume_binding["path"]
            resume_payload = resume_path.read_bytes()
            resume_path.unlink()
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "failure resume source",
            ):
                adapter.verify_failure_artifact(evaluation_failure)
            resume_path.write_bytes(resume_payload)

            constraint = _failure_document(
                root=root,
                candidate_vector_sha256=candidate_sha256,
                shared_bank_sha256=shared_sha256,
                failure_type="constraint",
                message="constraint failed",
                code="constraint.failed",
                attempt_binding=attempt_binding,
            )
            adapter.verify_failure_artifact(constraint)
            wrong_constraint_lineage = deepcopy(constraint)
            wrong_constraint_lineage["recovery"]["resume_source"][
                "binding"
            ] = _write_evidence(
                root,
                "failure/other-resume-source.json",
                "other resume source",
            )
            wrong_constraint_lineage = dict(
                finalize_artifact_sha256_v2(wrong_constraint_lineage)
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "constraint failure resume lineage differs",
            ):
                adapter.verify_failure_artifact(wrong_constraint_lineage)

            authority_integrity = _failure_document(
                root=root,
                candidate_vector_sha256=None,
                shared_bank_sha256=None,
                failure_type="evidence_integrity",
                failure_stage="authority_authentication",
                message="authority changed",
                code="integrity.authority-changed",
            )
            adapter.verify_failure_artifact(authority_integrity)

    def test_authority_authentication_failure_publishes_without_instance_identity(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority_failure = _failure_document(
                root=root,
                candidate_vector_sha256=None,
                shared_bank_sha256=None,
                failure_type="evidence_integrity",
                failure_stage="authority_authentication",
                message="authority authentication failed",
                code="integrity.authority-authentication-failed",
            )

            with patch.object(
                CalibrationPersistenceAdapterV2,
                "_authenticate_authorities",
                side_effect=CalibrationPersistenceV2Error(
                    "injected authority authentication failure"
                ),
            ):
                with self.assertRaisesRegex(
                    CalibrationPersistenceV2Error,
                    "injected authority authentication failure",
                ):
                    CalibrationPersistenceAdapterV2(root)
                binding = publish_authority_authentication_failure_v2(
                    root,
                    authority_failure,
                )

            self.assertEqual(binding.path, f"failures/{binding.sha256}.json")
            adapter = _unit_adapter(root)
            self.assertEqual(
                adapter.reopen_failure_artifact(
                    binding,
                    expected_run_id=RUN_ID,
                    expected_failure_type="evidence_integrity",
                    expected_failure_reasons=(),
                ),
                authority_failure,
            )

            fabricated_shared_bank = deepcopy(authority_failure)
            fabricated_shared_bank["shared_bank_configuration_sha256"] = _sha(
                "fabricated-pre-auth-shared-bank"
            )
            fabricated_shared_bank = dict(
                finalize_artifact_sha256_v2(fabricated_shared_bank)
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "schema validation failed",
            ):
                publish_authority_authentication_failure_v2(
                    root,
                    fabricated_shared_bank,
                )

            attempt_source = _write_evidence(
                root,
                "attempts-v2.ndjson",
                "post-authority attempt source",
            )
            later_stage = deepcopy(authority_failure)
            later_stage["failure_stage"] = "development_search"
            later_stage["candidate_vector_sha256"] = _sha(
                "post-authority-candidate"
            )
            later_stage["shared_bank_configuration_sha256"] = _sha(
                "post-authority-shared-bank"
            )
            later_stage["failure_bindings"]["attempt_ledger"] = {
                "applicable": True,
                "binding": attempt_source,
            }
            later_stage = dict(finalize_artifact_sha256_v2(later_stage))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "accepts only authority-authentication",
            ):
                publish_authority_authentication_failure_v2(root, later_stage)

            missing_post_authority_shared_bank = deepcopy(later_stage)
            missing_post_authority_shared_bank[
                "shared_bank_configuration_sha256"
            ] = None
            missing_post_authority_shared_bank = dict(
                finalize_artifact_sha256_v2(
                    missing_post_authority_shared_bank
                )
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "schema validation failed",
            ):
                adapter.verify_failure_artifact(
                    missing_post_authority_shared_bank
                )

    def test_selection_ready_declared_counts_sets_and_separation(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            candidate_sha256 = _sha("validation-candidate")
            evaluation_sha256 = _sha("validation-evaluation")
            entries = [
                {
                    "split": "validation",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": {
                        "path": f"evaluations/{evaluation_sha256}.json",
                        "sha256": evaluation_sha256,
                        "size_bytes": 1,
                    },
                }
            ]
            inputs = list(authority_input_bindings_v2())
            document = {
                "schema_version": "2.0.2",
                "artifact_kind": "p06_calibration_run_ledger_v2",
                "authority_bindings": authority_bindings_v2(),
                "run_id": RUN_ID,
                "plan_id": "mirmir-p06-spatial-calibration-v2",
                "input_bundle_sha256": input_bundle_sha256_v2(inputs),
                "input_bindings": inputs,
                "shared_bank_configuration_sha256": _sha("terminal-shared-bank"),
                "maximum_development_attempt_count": 3288,
                "maximum_validation_attempt_count": 374,
                "development_attempt_count": 822,
                "validation_attempt_count": 1,
                "attempt_count": 822,
                "attempt_ledger": {
                    "path": "attempts-v2.ndjson",
                    "sha256": _sha("attempt-ledger"),
                    "size_bytes": 1,
                    "record_count": 822,
                    "last_record_sha256": _sha("attempt-tail"),
                },
                "completed_sweeps": 2,
                "development_status": "terminated_feasible",
                "development_terminal_candidate_vector_sha256": _sha(
                    "development-terminal"
                ),
                "validation_admission": _binding(
                    "validation-candidate-development-evidence-v2.json",
                    "validation-admission",
                ),
                "candidate_evaluations": entries,
                "candidate_evaluation_count": len(entries),
                "candidate_evaluation_identity_set_sha256": (
                    candidate_evaluation_identity_set_sha256_v2(entries)
                ),
                "candidate_failures": [],
                "candidate_failure_count": 0,
                "candidate_failure_identity_set_sha256": (
                    candidate_failure_identity_set_sha256_v2([])
                ),
                "data_separation": {
                    "all_development_attempts_precede_validation": True,
                    "development_validation_cache_namespaces_distinct": True,
                    "validation_opened_after_development_freeze": True,
                    "holdout_accessed": False,
                },
                "run_status": "selection_ready",
                "failure": None,
                "artifact_manifest": _binding(
                    "artifact-manifest-v2.json",
                    "artifact-manifest",
                ),
                "data_access": {
                    "development_accessed": True,
                    "validation_accessed": True,
                    "holdout_accessed": False,
                    "release_locks_written": False,
                },
                "artifact_sha256": _sha("placeholder"),
            }
            document = dict(finalize_artifact_sha256_v2(document))
            self.assertEqual(
                adapter.verify_run_ledger_declared_relations(document),
                document,
            )

            duplicate = deepcopy(document)
            other_evaluation_sha256 = _sha("other-validation-evaluation")
            duplicate["candidate_evaluations"].append(
                {
                    "split": "validation",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": {
                        "path": f"evaluations/{other_evaluation_sha256}.json",
                        "sha256": other_evaluation_sha256,
                        "size_bytes": 1,
                    },
                }
            )
            duplicate["validation_attempt_count"] = 2
            duplicate["candidate_evaluation_count"] = 2
            duplicate["candidate_evaluation_identity_set_sha256"] = (
                candidate_evaluation_identity_set_sha256_v2(
                    duplicate["candidate_evaluations"]
                )
            )
            duplicate = dict(finalize_artifact_sha256_v2(duplicate))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "cache identity repeats",
            ):
                adapter.verify_run_ledger_declared_relations(duplicate)

            count_mismatch = deepcopy(document)
            count_mismatch["candidate_evaluation_count"] = 0
            count_mismatch = dict(finalize_artifact_sha256_v2(count_mismatch))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "count or set identity differs",
            ):
                adapter.verify_run_ledger_declared_relations(count_mismatch)

            all_validation_failed = deepcopy(document)
            failure_sha256 = _sha("all-validation-failed")
            failure_entries = [
                {
                    "split": "validation",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": {
                        "path": f"failures/{failure_sha256}.json",
                        "sha256": failure_sha256,
                        "size_bytes": 1,
                    },
                }
            ]
            all_validation_failed["candidate_evaluations"] = []
            all_validation_failed["candidate_evaluation_count"] = 0
            all_validation_failed[
                "candidate_evaluation_identity_set_sha256"
            ] = candidate_evaluation_identity_set_sha256_v2([])
            all_validation_failed["candidate_failures"] = failure_entries
            all_validation_failed["candidate_failure_count"] = 1
            all_validation_failed[
                "candidate_failure_identity_set_sha256"
            ] = candidate_failure_identity_set_sha256_v2(failure_entries)
            all_validation_failed = dict(
                finalize_artifact_sha256_v2(all_validation_failed)
            )
            self.assertEqual(
                adapter.verify_run_ledger_declared_relations(
                    all_validation_failed
                ),
                all_validation_failed,
            )

            overlapping_outcome = deepcopy(document)
            overlapping_outcome["candidate_failures"] = failure_entries
            overlapping_outcome["candidate_failure_count"] = 1
            overlapping_outcome[
                "candidate_failure_identity_set_sha256"
            ] = candidate_failure_identity_set_sha256_v2(failure_entries)
            overlapping_outcome["validation_attempt_count"] = 2
            overlapping_outcome = dict(
                finalize_artifact_sha256_v2(overlapping_outcome)
            )
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "identities overlap",
            ):
                adapter.verify_run_ledger_declared_relations(
                    overlapping_outcome
                )

            recovered_development_candidate = _sha(
                "recovered-development-candidate"
            )
            development_history = deepcopy(document)
            development_evaluation_sha256 = _sha(
                "recovered-development-evaluation"
            )
            development_history["candidate_evaluations"].append(
                {
                    "split": "development",
                    "candidate_vector_sha256": recovered_development_candidate,
                    "binding": {
                        "path": (
                            "evaluations/"
                            f"{development_evaluation_sha256}.json"
                        ),
                        "sha256": development_evaluation_sha256,
                        "size_bytes": 1,
                    },
                }
            )
            development_failure_entries = []
            for suffix in ("first", "second"):
                failure_digest = _sha(
                    f"recovered-development-failure-{suffix}"
                )
                development_failure_entries.append(
                    {
                        "split": "development",
                        "candidate_vector_sha256": (
                            recovered_development_candidate
                        ),
                        "binding": {
                            "path": f"failures/{failure_digest}.json",
                            "sha256": failure_digest,
                            "size_bytes": 1,
                        },
                    }
                )
            development_history["candidate_failures"] = (
                development_failure_entries
            )
            development_history["candidate_evaluation_count"] = len(
                development_history["candidate_evaluations"]
            )
            development_history[
                "candidate_evaluation_identity_set_sha256"
            ] = candidate_evaluation_identity_set_sha256_v2(
                development_history["candidate_evaluations"]
            )
            development_history["candidate_failure_count"] = len(
                development_failure_entries
            )
            development_history[
                "candidate_failure_identity_set_sha256"
            ] = candidate_failure_identity_set_sha256_v2(
                development_failure_entries
            )
            development_history = dict(
                finalize_artifact_sha256_v2(development_history)
            )
            self.assertEqual(
                adapter.verify_run_ledger_declared_relations(
                    development_history
                ),
                development_history,
            )

            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "candidate-failure identities repeat",
            ):
                candidate_failure_identity_set_sha256_v2(
                    [
                        development_failure_entries[0],
                        deepcopy(development_failure_entries[0]),
                    ]
                )

            dependencies = deepcopy(document)
            dependencies["artifact_manifest"] = _write_evidence(
                root,
                "artifact-manifest-v2.json",
                "run artifact manifest",
            )
            dependencies["validation_admission"] = _write_evidence(
                root,
                "validation-candidate-development-evidence-v2.json",
                "validation admission",
            )
            dependencies = dict(finalize_artifact_sha256_v2(dependencies))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "attempts-v2.ndjson cannot be safely opened or inspected",
            ):
                adapter.verify_run_ledger(dependencies)

    def test_run_ledger_represents_transient_development_failure_then_evaluation(
        self,
    ) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            evaluation = _development_evaluation(1)
            failed_once: set[str] = set()
            evaluation_bindings: dict[str, ArtifactBindingV2] = {}
            failure_bindings: dict[str, set[ArtifactBindingV2]] = {}

            def evaluator(logical, physical, identity):
                del logical
                candidate_sha256 = identity.candidate_vector_sha256
                if candidate_sha256.startswith("f") and candidate_sha256 not in failed_once:
                    failed_once.add(candidate_sha256)
                    reason = "transient development evaluator failure"
                    failure = _failure_document(
                        root=root,
                        candidate_vector_sha256=candidate_sha256,
                        shared_bank_sha256=(
                            shared_bank_configuration_sha256_v2(
                                physical,
                                adapter.plan,
                            )
                        ),
                        failure_type="evaluation",
                        message=reason,
                        code="evaluation.transient",
                    )
                    binding = adapter.publish_failure_artifact(failure)
                    failure_bindings.setdefault(candidate_sha256, set()).add(
                        binding
                    )
                    return AuthenticatedDevelopmentEvaluationFailureV2(
                        failure_reasons=(reason,),
                        artifact=binding,
                    )
                binding = adapter.publish_candidate_evaluation(
                    _candidate_evaluation_document(
                        adapter,
                        root,
                        dict(physical),
                        evaluation,
                    )
                )
                evaluation_bindings[candidate_sha256] = binding
                return AuthenticatedDevelopmentEvaluationV2(
                    evaluation=evaluation,
                    artifact=binding,
                )

            result = run_development_search_v2(adapter.plan, evaluator)
            self.assertEqual(result.status, "terminated_feasible")
            self.assertEqual(result.attempt_count, 1233)
            statuses_by_candidate: dict[str, set[str]] = {}
            for record in result.attempt_records:
                statuses_by_candidate.setdefault(
                    record.candidate_vector_sha256,
                    set(),
                ).add(record.status)
            recovered_candidates = {
                candidate_sha256
                for candidate_sha256, statuses in statuses_by_candidate.items()
                if ATTEMPT_STATUS_EVALUATION_FAILURE in statuses
                and ATTEMPT_STATUS_FEASIBLE in statuses
            }
            self.assertTrue(recovered_candidates)

            attempt_binding = adapter.publish_attempt_records(
                result.attempt_records,
                run_id=RUN_ID,
            )
            incumbent_physical = dict(
                result.incumbent_physical_candidate_items or ()
            )
            incumbent_sha256 = result.incumbent_candidate_sha256
            self.assertIsNotNone(incumbent_sha256)
            validation_admission = _write_unit_validation_admission(root)
            validation_binding = adapter.publish_candidate_evaluation(
                _validation_evaluation_document(
                    adapter,
                    root,
                    incumbent_physical,
                    validation_admission=validation_admission,
                )
            )
            entries = [
                {
                    "split": "development",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": _binding_document(binding),
                }
                for candidate_sha256, binding in sorted(
                    evaluation_bindings.items()
                )
            ]
            entries.append(
                {
                    "split": "validation",
                    "candidate_vector_sha256": incumbent_sha256,
                    "binding": _binding_document(validation_binding),
                }
            )
            failure_entries = [
                {
                    "split": "development",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": _binding_document(binding),
                }
                for candidate_sha256, bindings in sorted(
                    failure_bindings.items()
                )
                for binding in sorted(bindings, key=lambda item: item.sha256)
            ]
            self.assertTrue(
                recovered_candidates
                <= {
                    entry["candidate_vector_sha256"]
                    for entry in entries
                    if entry["split"] == "development"
                }
            )
            self.assertTrue(
                recovered_candidates
                <= {
                    entry["candidate_vector_sha256"]
                    for entry in failure_entries
                }
            )

            inputs = list(authority_input_bindings_v2())
            run_shared_sha256 = shared_bank_configuration_sha256_v2(
                incumbent_physical,
                adapter.plan,
            )
            control_closure_bindings = []
            for entry in entries:
                evaluation_document = json.loads(
                    (root / entry["binding"]["path"]).read_bytes()
                )
                bundle_binding = evaluation_document[
                    "control_authorization_bundle"
                ]
                bundle_document = json.loads(
                    (root / bundle_binding["path"]).read_bytes()
                )
                control_closure_bindings.extend(
                    [
                        bundle_binding,
                        *bundle_document["dependency_bindings"],
                    ]
                )
            manifest_bindings = [
                _binding_document(attempt_binding),
                validation_admission,
                *control_closure_bindings,
                *(entry["binding"] for entry in entries),
                *(entry["binding"] for entry in failure_entries),
                *(
                    _write_evidence(
                        root,
                        f"gates/{gate.lower()}.json",
                        f"current-source {gate}",
                    )
                    for gate in ("G04", "G05", "G06")
                ),
                _write_evidence(root, "failure/trace.log", "failure trace"),
                _write_evidence(
                    root,
                    "failure/resume-source.json",
                    "failure resume source",
                ),
            ]
            run_manifest = _write_artifact_manifest(root, manifest_bindings)
            ledger = {
                "schema_version": "2.0.2",
                "artifact_kind": "p06_calibration_run_ledger_v2",
                "authority_bindings": authority_bindings_v2(),
                "run_id": RUN_ID,
                "plan_id": "mirmir-p06-spatial-calibration-v2",
                "input_bundle_sha256": input_bundle_sha256_v2(inputs),
                "input_bindings": inputs,
                "shared_bank_configuration_sha256": run_shared_sha256,
                "maximum_development_attempt_count": 3288,
                "maximum_validation_attempt_count": 374,
                "development_attempt_count": result.attempt_count,
                "validation_attempt_count": 1,
                "attempt_count": result.attempt_count,
                "attempt_ledger": {
                    "path": attempt_binding.path,
                    "sha256": attempt_binding.sha256,
                    "size_bytes": attempt_binding.size_bytes,
                    "record_count": attempt_binding.record_count,
                    "last_record_sha256": attempt_binding.last_record_sha256,
                },
                "completed_sweeps": result.completed_sweeps,
                "development_status": result.status,
                "development_terminal_candidate_vector_sha256": (
                    incumbent_sha256
                ),
                "validation_admission": validation_admission,
                "candidate_evaluations": entries,
                "candidate_evaluation_count": len(entries),
                "candidate_evaluation_identity_set_sha256": (
                    candidate_evaluation_identity_set_sha256_v2(entries)
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
                "artifact_manifest": run_manifest,
                "data_access": {
                    "development_accessed": True,
                    "validation_accessed": True,
                    "holdout_accessed": False,
                    "release_locks_written": False,
                },
                "artifact_sha256": _sha("placeholder"),
            }
            ledger = dict(finalize_artifact_sha256_v2(ledger))
            verified = adapter.verify_run_ledger(ledger)
            self.assertEqual(
                verified.attempt_ledger.replay.attempt_count,
                1233,
            )
            self.assertEqual(
                len(verified.candidate_failures),
                len(failure_entries),
            )

    def test_failed_run_ledger_counts_sets_and_data_separation(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter = _unit_adapter(root)
            reason = "development evaluator unavailable"
            evaluation_failure_bindings: dict[str, ArtifactBindingV2] = {}

            def evaluator(logical, physical, identity):
                del logical
                shared_sha256 = shared_bank_configuration_sha256_v2(
                    physical,
                    adapter.plan,
                )
                failure = _failure_document(
                    root=root,
                    candidate_vector_sha256=identity.candidate_vector_sha256,
                    shared_bank_sha256=shared_sha256,
                    failure_type="evaluation",
                    message=reason,
                    code="evaluation.unavailable",
                )
                artifact = adapter.publish_failure_artifact(failure)
                evaluation_failure_bindings[
                    identity.candidate_vector_sha256
                ] = artifact
                return AuthenticatedDevelopmentEvaluationFailureV2(
                    failure_reasons=(reason,),
                    artifact=artifact,
                )

            result = run_development_search_v2(adapter.plan, evaluator)
            self.assertEqual(
                result.status,
                "failed_no_eligible_structural_candidate",
            )
            self.assertEqual(result.attempt_count, 256)
            attempt_binding = adapter.publish_attempt_records(
                result.attempt_records,
                run_id=RUN_ID,
            )
            run_shared_sha256 = shared_bank_configuration_sha256_v2(
                dict(result.attempt_records[-1].physical_candidate_items),
                adapter.plan,
            )
            run_manifest = _write_artifact_manifest(
                root,
                [
                    _binding_document(attempt_binding),
                    *(
                        _binding_document(binding)
                        for binding in evaluation_failure_bindings.values()
                    ),
                    _write_evidence(
                        root,
                        "failure/trace.log",
                        "failure trace",
                    ),
                    _write_evidence(
                        root,
                        "failure/resume-source.json",
                        "failure resume source",
                    ),
                ],
            )
            terminal_binding = adapter.publish_failure_artifact(
                _failure_document(
                    root=root,
                    candidate_vector_sha256=(
                        result.attempt_records[-1].candidate_vector_sha256
                    ),
                    shared_bank_sha256=run_shared_sha256,
                    failure_type="terminal",
                    message="no eligible structural candidate",
                    code="terminal.no-eligible-structural",
                    attempt_binding=attempt_binding,
                    artifact_manifest_binding=run_manifest,
                )
            )
            inputs = list(authority_input_bindings_v2())
            entries: list[dict[str, object]] = []
            failure_entries = [
                {
                    "split": "development",
                    "candidate_vector_sha256": candidate_sha256,
                    "binding": _binding_document(binding),
                }
                for candidate_sha256, binding in sorted(
                    evaluation_failure_bindings.items()
                )
            ]
            ledger = {
                "schema_version": "2.0.2",
                "artifact_kind": "p06_calibration_run_ledger_v2",
                "authority_bindings": authority_bindings_v2(),
                "run_id": RUN_ID,
                "plan_id": "mirmir-p06-spatial-calibration-v2",
                "input_bundle_sha256": input_bundle_sha256_v2(inputs),
                "input_bindings": inputs,
                "shared_bank_configuration_sha256": run_shared_sha256,
                "maximum_development_attempt_count": 3288,
                "maximum_validation_attempt_count": 374,
                "development_attempt_count": 256,
                "validation_attempt_count": 0,
                "attempt_count": 256,
                "attempt_ledger": {
                    "path": attempt_binding.path,
                    "sha256": attempt_binding.sha256,
                    "size_bytes": attempt_binding.size_bytes,
                    "record_count": attempt_binding.record_count,
                    "last_record_sha256": attempt_binding.last_record_sha256,
                },
                "completed_sweeps": 0,
                "development_status": result.status,
                "development_terminal_candidate_vector_sha256": None,
                "validation_admission": None,
                "candidate_evaluations": entries,
                "candidate_evaluation_count": 0,
                "candidate_evaluation_identity_set_sha256": (
                    candidate_evaluation_identity_set_sha256_v2(entries)
                ),
                "candidate_failures": failure_entries,
                "candidate_failure_count": len(failure_entries),
                "candidate_failure_identity_set_sha256": (
                    candidate_failure_identity_set_sha256_v2(failure_entries)
                ),
                "data_separation": {
                    "all_development_attempts_precede_validation": True,
                    "development_validation_cache_namespaces_distinct": True,
                    "validation_opened_after_development_freeze": False,
                    "holdout_accessed": False,
                },
                "run_status": "failed",
                "failure": {
                    "path": terminal_binding.path,
                    "sha256": terminal_binding.sha256,
                    "size_bytes": terminal_binding.size_bytes,
                },
                "artifact_manifest": run_manifest,
                "data_access": {
                    "development_accessed": True,
                    "validation_accessed": False,
                    "holdout_accessed": False,
                    "release_locks_written": False,
                },
                "artifact_sha256": _sha("placeholder"),
            }
            ledger = dict(finalize_artifact_sha256_v2(ledger))
            wrong_digest = _sha("wrong-run-ledger-binding")
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "fixed binding differs from canonical document bytes",
            ):
                adapter.verify_run_ledger(
                    ledger,
                    binding=FileBindingV2(
                        path="calibration-run-ledger-v2.json",
                        sha256=wrong_digest,
                        size_bytes=len(canonical_json_file_bytes_v2(ledger)),
                    ),
                )
            verified = adapter.verify_run_ledger(ledger)
            self.assertEqual(verified.attempt_ledger.replay.status, result.status)

            unrelated_attempt = _write_evidence(
                root,
                "unrelated/not-attempts.bin",
                "unrelated existing attempt bytes",
            )
            unrelated_manifest = _write_evidence(
                root,
                "unrelated/not-run-manifest.json",
                "unrelated existing manifest bytes",
            )
            for field, unrelated, expected_message in (
                (
                    "attempt_ledger",
                    unrelated_attempt,
                    "failure attempt-ledger binding differs from enclosing run",
                ),
                (
                    "artifact_manifest",
                    unrelated_manifest,
                    "failure artifact-manifest binding differs from enclosing run",
                ),
            ):
                with self.subTest(terminal_binding=field):
                    wrong_terminal = _failure_document(
                        root=root,
                        candidate_vector_sha256=(
                            result.attempt_records[-1].candidate_vector_sha256
                        ),
                        shared_bank_sha256=run_shared_sha256,
                        failure_type="terminal",
                        message="no eligible structural candidate",
                        code="terminal.no-eligible-structural",
                        attempt_binding=attempt_binding,
                        artifact_manifest_binding=run_manifest,
                    )
                    wrong_terminal["failure_bindings"][field][
                        "binding"
                    ] = unrelated
                    wrong_terminal = dict(
                        finalize_artifact_sha256_v2(wrong_terminal)
                    )
                    wrong_terminal_binding = adapter.publish_failure_artifact(
                        wrong_terminal
                    )
                    wrong_terminal_ledger = deepcopy(ledger)
                    wrong_terminal_ledger["failure"] = _binding_document(
                        wrong_terminal_binding
                    )
                    wrong_terminal_ledger = dict(
                        finalize_artifact_sha256_v2(wrong_terminal_ledger)
                    )
                    with self.assertRaisesRegex(
                        CalibrationPersistenceV2Error,
                        expected_message,
                    ):
                        adapter.verify_run_ledger(wrong_terminal_ledger)

            binding = adapter.publish_run_ledger(ledger)
            self.assertEqual(
                adapter.reopen_run_ledger(binding).document,
                ledger,
            )
            run_path = root / binding.path
            run_payload = run_path.read_bytes()
            displaced_run = run_path.with_name(f"{run_path.name}.displaced")
            original_reopen_attempt = adapter.reopen_attempt_ledger

            def swap_run_after_attempt(*args, **kwargs):
                reopened_attempt = original_reopen_attempt(*args, **kwargs)
                run_path.rename(displaced_run)
                run_path.write_bytes(run_payload)
                return reopened_attempt

            try:
                with patch.object(
                    adapter,
                    "reopen_attempt_ledger",
                    side_effect=swap_run_after_attempt,
                ), self.assertRaisesRegex(
                    CalibrationPersistenceV2Error,
                    "closure artifact root changed during verification",
                ):
                    adapter.reopen_run_ledger(binding)
            finally:
                if displaced_run.exists():
                    run_path.unlink(missing_ok=True)
                    displaced_run.rename(run_path)

            manifest_path = root / ledger["artifact_manifest"]["path"]
            manifest_payload = manifest_path.read_bytes()
            for mode in ("missing", "replaced"):
                with self.subTest(reopen_manifest=mode):
                    if mode == "missing":
                        manifest_path.unlink()
                    else:
                        manifest_path.write_bytes(b"replaced run manifest\n")
                    with self.assertRaisesRegex(
                        CalibrationPersistenceV2Error,
                        "artifact manifest",
                    ):
                        adapter.reopen_run_ledger(binding)
                    manifest_path.write_bytes(manifest_payload)

            tampered = deepcopy(ledger)
            tampered["candidate_evaluation_identity_set_sha256"] = _sha(
                "wrong-set"
            )
            tampered = dict(finalize_artifact_sha256_v2(tampered))
            with self.assertRaisesRegex(
                CalibrationPersistenceV2Error,
                "count or set identity differs",
            ):
                adapter.verify_run_ledger(tampered)


if __name__ == "__main__":
    unittest.main()
