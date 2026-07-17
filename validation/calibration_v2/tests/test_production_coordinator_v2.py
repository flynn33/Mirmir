from __future__ import annotations

import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from validation.calibration_v2.calibration_persistence_v2 import (
    authority_bindings_v2,
    candidate_evidence_sha256_v2,
    canonical_json_file_bytes_v2,
    finalize_artifact_sha256_v2,
)
from validation.calibration_v2.calibration_plan_codec import (
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    ATTEMPT_STATUS_EVALUATION_FAILURE,
    DEVELOPMENT_SPLIT,
    STATUS_TERMINATED_FEASIBLE,
    VALIDATION_SPLIT,
    DevelopmentEvaluationV2,
)
from validation.calibration_v2.production_coordinator_v2 import (
    CandidateEvaluationFailureV2,
    CandidateEvaluationRequestV2,
    CandidateEvaluationSuccessV2,
    P06ProductionCoordinatorV2,
    P06ProductionCoordinatorV2Error,
    RunArtifactProvenanceV2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.tests.test_calibration_persistence_v2 import (
    _trusted_unit_control_verifier,
)
from validation.calibration_v2.tests.test_calibration_selection_persistence_v2 import (
    RUN_ID,
    _candidate_document,
    _evaluation_mapping,
)


ZERO_SHA256 = "0" * 64


def _binding(path: str, payload: bytes) -> dict[str, object]:
    return {
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _write_evidence(root: Path, path: str, payload: bytes) -> dict[str, object]:
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    return _binding(path, payload)


def _applicable(binding: dict[str, object] | None) -> dict[str, object]:
    return {"applicable": binding is not None, "binding": binding}


def _evaluation_failure_document(
    root: Path,
    request: CandidateEvaluationRequestV2,
    *,
    shared_bank_sha256: str,
    reason: str,
) -> dict[str, object]:
    trace = _write_evidence(
        root,
        "failure/development-evaluation-trace.log",
        b"deterministic analytic provider failure\n",
    )
    resume = _write_evidence(
        root,
        "failure/development-resume-source.json",
        b'{"resume":"development_search"}\n',
    )
    document = {
        "schema_version": "2.0.1",
        "artifact_kind": "p06_calibration_failure_v2",
        "authority_bindings": authority_bindings_v2(),
        "run_id": request.run_id,
        "shared_bank_configuration_sha256": shared_bank_sha256,
        "candidate_vector_sha256": (
            request.cache_identity.candidate_vector_sha256
        ),
        "failure_stage": "development_search",
        "failure_type": "evaluation",
        "failure_code": "analytic.evaluation_failure",
        "failure_message": reason,
        "failure_reasons": [reason],
        "failure_bindings": {
            "attempt_ledger": _applicable(None),
            "trace_evidence": _applicable(trace),
            "artifact_manifest": _applicable(None),
            "cleanup_evidence": _applicable(None),
            "recovery_evidence": _applicable(None),
        },
        "cleanup": {
            "invoked": False,
            "idempotent": True,
            "completed": False,
            "unrelated_files_deleted": False,
        },
        "recovery": {
            "resume_allowed": True,
            "recovery_stage": "resume_development_search",
            "resume_source": _applicable(resume),
        },
        "status": "failed_preserved",
        "data_access": {
            "development_accessed": True,
            "validation_accessed": False,
            "holdout_accessed": False,
            "release_locks_written": False,
        },
        "artifact_sha256": ZERO_SHA256,
    }
    return dict(finalize_artifact_sha256_v2(document))


class _AnalyticProviderV2:
    """Test-only provider; production entry points never construct this type."""

    def __init__(self) -> None:
        self.adapter = None
        self.requests: list[CandidateEvaluationRequestV2] = []
        self.injected_failure_candidate_sha256: str | None = None

    def __call__(
        self,
        request: CandidateEvaluationRequestV2,
    ) -> CandidateEvaluationSuccessV2 | CandidateEvaluationFailureV2:
        if self.adapter is None:
            raise AssertionError("test provider lacks the coordinator adapter")
        self.requests.append(request)
        logical = dict(request.logical_candidate_items)
        physical = dict(request.physical_candidate_items)
        ordinal = int(logical[ATOMIC_STRUCTURAL_COORDINATE])
        scalar_initials = dict(self.adapter.plan.scalar_initial_values)
        at_scalar_initials = all(
            logical[name] == value for name, value in scalar_initials.items()
        )

        if (
            request.split == DEVELOPMENT_SPLIT
            and ordinal == 2
            and at_scalar_initials
            and self.injected_failure_candidate_sha256 is None
        ):
            self.injected_failure_candidate_sha256 = (
                request.cache_identity.candidate_vector_sha256
            )
            reason = "engine_raw:quality"
            shared = shared_bank_configuration_sha256_v2(
                physical,
                self.adapter.plan,
            )
            return CandidateEvaluationFailureV2(
                _evaluation_failure_document(
                    self.adapter.calibration._store.root,
                    request,
                    shared_bank_sha256=shared,
                    reason=reason,
                ),
                (reason,),
            )

        if request.split == DEVELOPMENT_SPLIT:
            feasible = ordinal in {0, 1} and at_scalar_initials
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
            evaluation_document = _evaluation_mapping(evaluation)
        else:
            score = 4 if ordinal == 0 else 3
            evaluation_document = {
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
        return CandidateEvaluationSuccessV2(
            _candidate_document(
                self.adapter,
                physical=physical,
                split=request.split,
                evaluation=evaluation_document,
            )
        )


class _UnexpectedProvider:
    def __call__(self, request: CandidateEvaluationRequestV2):
        del request
        raise AssertionError("complete restart invoked the provider")


class _HistoricalEvaluationProvider:
    def __init__(self, outcome_type: type) -> None:
        self.outcome_type = outcome_type

    def __call__(self, request: CandidateEvaluationRequestV2):
        del request
        if self.outcome_type is CandidateEvaluationFailureV2:
            return CandidateEvaluationFailureV2(
                {"schema_version": "1.0.0"},
                ("historical failure",),
            )
        return CandidateEvaluationSuccessV2({"schema_version": "1.1.0"})


class _HistoricalControlProvider:
    def __init__(self) -> None:
        self.adapter = None

    def __call__(self, request: CandidateEvaluationRequestV2):
        if self.adapter is None:
            raise AssertionError("test provider lacks the coordinator adapter")
        physical = dict(request.physical_candidate_items)
        evaluation = DevelopmentEvaluationV2(
            feasible=True,
            failure_reasons=(),
            mean_y_psnr_delta_vs_fixed_db=1,
            mean_y_psnr_delta_vs_non_ash_db=1,
            mean_ms_ssim_delta_vs_conventional=1,
            maximum_ringing_excursion=0,
            maximum_alias_ratio=0,
            estimated_dispatch_cost=0,
        )
        document = _candidate_document(
            self.adapter,
            physical=physical,
            split=request.split,
            evaluation=(
                _evaluation_mapping(evaluation)
                if request.split == DEVELOPMENT_SPLIT
                else {
                    "feasible": True,
                    "failure_reasons": [],
                    "objective": {
                        "y_vs_fixed_ci_low": 1,
                        "y_vs_non_ash_ci_low": 1,
                        "y_vs_conventional_ci_low": 1,
                        "mean_ms_ssim_delta_vs_conventional": 1,
                        "maximum_ringing_excursion": 0,
                        "maximum_alias_ratio": 0,
                        "estimated_dispatch_cost": 0,
                    },
                }
            ),
        )
        root = self.adapter.calibration._store.root
        original = document["control_authorization_bundle"]
        bundle = json.loads((root / original["path"]).read_bytes())
        bundle["schema_version"] = "1.0.0"
        payload = canonical_json_file_bytes_v2(bundle)
        digest = hashlib.sha256(payload).hexdigest()
        path = f"controls/{digest}.json"
        (root / path).write_bytes(payload)
        document["control_authorization_bundle"] = {
            **original,
            "path": path,
            "sha256": digest,
            "size_bytes": len(payload),
        }
        document["evidence_sha256"] = candidate_evidence_sha256_v2(document)
        document["artifact_sha256"] = ZERO_SHA256
        return CandidateEvaluationSuccessV2(
            dict(finalize_artifact_sha256_v2(document))
        )


def _provenance() -> RunArtifactProvenanceV2:
    return RunArtifactProvenanceV2(
        created_utc="2026-07-16T12:00:00Z",
        project_commit="a" * 40,
        producer="p06-production-coordinator-v2-test",
        command="python3 -m unittest production-coordinator-v2",
        platform="macOS",
        machine="local-test",
    )


def _write_gate_evidence(root: Path) -> None:
    for gate in ("G04", "G05", "G06"):
        _write_evidence(
            root,
            f"gates/{gate.lower()}.json",
            f"current-source-{gate}\n".encode("utf-8"),
        )


class P06ProductionCoordinatorV2Tests(unittest.TestCase):
    def test_attempt_resume_selection_restart_and_typed_failure_closure(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_gate_evidence(root)
            provider = _AnalyticProviderV2()
            coordinator = P06ProductionCoordinatorV2(
                artifact_root=root,
                run_id=RUN_ID,
                provider=provider,
                provenance=_provenance(),
                _control_authorization_verifier=(
                    _trusted_unit_control_verifier
                ),
            )
            provider.adapter = coordinator.persistence

            development = coordinator._run_development()
            self.assertEqual(development.status, STATUS_TERMINATED_FEASIBLE)
            self.assertGreater(development.cache_hit_count, 0)
            typed_failures = [
                record
                for record in development.attempt_records
                if record.status == ATTEMPT_STATUS_EVALUATION_FAILURE
            ]
            self.assertTrue(typed_failures)
            self.assertTrue(
                all(record.failure_artifact is not None for record in typed_failures)
            )
            checkpoint = coordinator.persistence.calibration.publish_attempt_records(
                development.attempt_records,
                run_id=RUN_ID,
            )
            provider.requests.clear()

            result = coordinator.run()
            self.assertFalse(result.restarted_from_complete_selection)
            self.assertEqual(result.attempt_ledger_binding, checkpoint)
            self.assertTrue(provider.requests)
            self.assertEqual(
                {request.split for request in provider.requests},
                {VALIDATION_SPLIT},
            )
            self.assertEqual(
                len(result.validation_outcomes),
                result.selection["validation_candidate_count"],
            )
            self.assertEqual(result.selection["selection_status"], "selected")
            self.assertFalse(result.selection["data_access"]["holdout_accessed"])
            run_document = json.loads(
                (root / "calibration-run-ledger-v2.json").read_bytes()
            )
            self.assertGreater(run_document["candidate_failure_count"], 0)
            self.assertEqual(
                run_document["candidate_failure_count"],
                len(run_document["candidate_failures"]),
            )

            restarted = P06ProductionCoordinatorV2(
                artifact_root=root,
                run_id=RUN_ID,
                provider=_UnexpectedProvider(),
                provenance=_provenance(),
                _control_authorization_verifier=(
                    _trusted_unit_control_verifier
                ),
            ).run()
            self.assertTrue(restarted.restarted_from_complete_selection)
            self.assertEqual(restarted.selection_binding, result.selection_binding)
            self.assertEqual(
                restarted.run_ledger_binding,
                result.run_ledger_binding,
            )
            self.assertEqual(
                restarted.attempt_ledger_binding,
                result.attempt_ledger_binding,
            )

    def test_run_rejects_historical_evaluation_schema_families(self) -> None:
        for outcome_type in (
            CandidateEvaluationSuccessV2,
            CandidateEvaluationFailureV2,
        ):
            with self.subTest(outcome_type=outcome_type.__name__):
                with TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    _write_gate_evidence(root)
                    coordinator = P06ProductionCoordinatorV2(
                        artifact_root=root,
                        run_id=RUN_ID,
                        provider=_HistoricalEvaluationProvider(outcome_type),
                        provenance=_provenance(),
                        _control_authorization_verifier=(
                            _trusted_unit_control_verifier
                        ),
                    )
                    with self.assertRaisesRegex(
                        P06ProductionCoordinatorV2Error,
                        "historical schema family",
                    ):
                        coordinator.run()
                    self.assertFalse((root / "attempts-v2.ndjson").exists())

    def test_run_rejects_historical_control_bundle(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_gate_evidence(root)
            provider = _HistoricalControlProvider()
            coordinator = P06ProductionCoordinatorV2(
                artifact_root=root,
                run_id=RUN_ID,
                provider=provider,
                provenance=_provenance(),
                _control_authorization_verifier=(
                    _trusted_unit_control_verifier
                ),
            )
            provider.adapter = coordinator.persistence
            with self.assertRaisesRegex(
                P06ProductionCoordinatorV2Error,
                "historical control schema family",
            ):
                coordinator.run()
            self.assertFalse((root / "attempts-v2.ndjson").exists())


if __name__ == "__main__":
    unittest.main()
