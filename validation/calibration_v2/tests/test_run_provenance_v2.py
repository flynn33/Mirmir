from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from validation.calibration_v2.run_provenance_v2 import (
    FAILURE_INTEGRATION_REQUIREMENTS_V2,
    FIXED_EXCLUSIONS,
    PROVENANCE_SCHEMA_SHA256,
    RUN_INPUT_MANIFEST_SCHEMA_SHA256,
    FailureCycleExclusionV2,
    RunProvenanceV2Error,
    TypedArtifactBindingV2,
    VerifiedCommandPlanV2,
    VerifiedGateReceiptV2,
    authenticate_authorities_v2,
    authority_bindings_v2,
    authority_closure_bindings_v2,
    authority_input_bindings_v2,
    build_failure_cycle_exclusion_v2,
    build_run_input_manifest_v2,
    build_run_provenance_receipt_v2,
    canonical_json_bytes_v2,
    canonical_json_file_bytes_v2,
    failure_identity_sha256_v2,
    reopen_run_input_manifest_v2,
    reopen_run_provenance_receipt_v2,
    verify_run_input_manifest_v2,
    verify_run_provenance_receipt_v2,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SOURCE_COMMIT = "a" * 40
RUN_ID = "p06-provenance-test-run"


def _sha(value: str | bytes) -> str:
    payload = value.encode("utf-8") if isinstance(value, str) else value
    return hashlib.sha256(payload).hexdigest()


def _semantic_hash(document: dict[str, object], field: str) -> str:
    material = deepcopy(document)
    material.pop(field, None)
    return _sha(canonical_json_bytes_v2(material))


def _typed_binding(
    *,
    identifier: str,
    artifact_kind: str,
    content_type: str,
    schema_sha256: str | None,
    path: str,
    payload: bytes,
) -> dict[str, object]:
    return {
        "id": identifier,
        "artifact_kind": artifact_kind,
        "content_type": content_type,
        "schema_sha256": schema_sha256,
        "path": path,
        "sha256": _sha(payload),
        "size_bytes": len(payload),
    }


def _content_binding(path: str, seed: str) -> dict[str, object]:
    return {
        "path": path,
        "sha256": _sha(seed),
        "size_bytes": 1,
    }


class _Harness:
    def __init__(self) -> None:
        self.payloads: dict[str, bytes] = {}
        for binding in authority_closure_bindings_v2():
            self.payloads[binding.path] = (REPOSITORY_ROOT / binding.path).read_bytes()
        for path in (
            "validation/calibration_v2/schemas/p06-run-provenance-receipt-v2.schema.json",
            "validation/calibration_v2/schemas/p06-run-input-manifest-v2.schema.json",
        ):
            self.payloads[path] = (REPOSITORY_ROOT / path).read_bytes()

        additional_payload = canonical_json_file_bytes_v2(
            {"artifact_kind": "fixture_locked_input", "run_id": RUN_ID}
        )
        self.additional_binding = _typed_binding(
            identifier="fixture_locked_input",
            artifact_kind="fixture_locked_input",
            content_type="canonical_json",
            schema_sha256=_sha("fixture-locked-input-schema"),
            path="inputs/fixture-locked-input.json",
            payload=additional_payload,
        )
        self.payloads[str(self.additional_binding["path"])] = additional_payload

        self.failure_schema_binding = self._schema_binding(
            identifier="p06_calibration_failure_v2_schema",
            path=(
                "validation/calibration_v2/schemas/"
                "p06-calibration-failure-v2.schema.json"
            ),
        )
        self.run_ledger_schema_binding = self._schema_binding(
            identifier="p06_calibration_run_ledger_v2_schema",
            path=(
                "validation/calibration_v2/schemas/"
                "calibration-run-ledger-v2.schema.json"
            ),
        )
        command_closure_mappings = sorted(
            (
                self.additional_binding,
                self.failure_schema_binding,
                self.run_ledger_schema_binding,
            ),
            key=lambda value: str(value["path"]),
        )
        self.command_closure = tuple(
            TypedArtifactBindingV2.from_mapping(
                value,
                label=f"fixture command closure {index}",
            )
            for index, value in enumerate(command_closure_mappings)
        )

        self.gate_bindings: list[dict[str, object]] = []
        self.gate_claim_overrides: dict[str, VerifiedGateReceiptV2] = {}
        for gate_id in ("G04", "G05", "G06"):
            wrapper_payload = canonical_json_file_bytes_v2(
                {
                    "artifact_kind": f"{gate_id.lower()}_wrapper_manifest",
                    "gate_id": gate_id,
                    "source_commit": SOURCE_COMMIT,
                }
            )
            wrapper_binding = _typed_binding(
                identifier=f"{gate_id}_wrapper_manifest",
                artifact_kind=f"{gate_id.lower()}_wrapper_manifest",
                content_type="canonical_json",
                schema_sha256=_sha(f"{gate_id}-wrapper-schema"),
                path=f"inputs/{gate_id.lower()}/wrapper-manifest.json",
                payload=wrapper_payload,
            )
            self.payloads[str(wrapper_binding["path"])] = wrapper_payload
            receipt_kind = f"{gate_id.lower()}_verified_wrapper_receipt"
            receipt_schema_sha256 = _sha(f"{gate_id}-receipt-schema")
            receipt_payload = canonical_json_file_bytes_v2(
                {
                    "artifact_kind": receipt_kind,
                    "closure_bindings": [wrapper_binding],
                    "current_source": True,
                    "gate_id": gate_id,
                    "holdout_accessed": False,
                    "schema_sha256": receipt_schema_sha256,
                    "source_commit": SOURCE_COMMIT,
                    "status": "pass",
                    "working_tree_clean": True,
                }
            )
            receipt_binding = _typed_binding(
                identifier=gate_id,
                artifact_kind=receipt_kind,
                content_type="canonical_json",
                schema_sha256=receipt_schema_sha256,
                path=f"inputs/{gate_id.lower()}/receipt.json",
                payload=receipt_payload,
            )
            self.payloads[str(receipt_binding["path"])] = receipt_payload
            self.gate_bindings.append(receipt_binding)

        producer_payload = (
            REPOSITORY_ROOT / "validation/calibration_v2/run_provenance_v2.py"
        ).read_bytes()
        self.producer_binding = _typed_binding(
            identifier="run_provenance_v2_producer",
            artifact_kind="python_source",
            content_type="opaque_bytes",
            schema_sha256=None,
            path="validation/calibration_v2/run_provenance_v2.py",
            payload=producer_payload,
        )
        self.payloads[str(self.producer_binding["path"])] = producer_payload

        command_kind = "p06_fixture_command_plan_v2"
        command_schema_sha256 = _sha("command-plan-schema")
        command_payload = canonical_json_file_bytes_v2(
            {
                "artifact_kind": command_kind,
                "holdout_accessed": False,
                "plan_id": "mirmir-p06-spatial-calibration-v2",
                "required_input_closure": [
                    dict(binding.document()) for binding in self.command_closure
                ],
                "run_id": RUN_ID,
                "schema_sha256": command_schema_sha256,
                "source_commit": SOURCE_COMMIT,
                "status": "pass",
            }
        )
        self.command_binding = _typed_binding(
            identifier="p06_command_plan",
            artifact_kind=command_kind,
            content_type="canonical_json",
            schema_sha256=command_schema_sha256,
            path="inputs/p06-command-plan.json",
            payload=command_payload,
        )
        self.payloads[str(self.command_binding["path"])] = command_payload
        self.command_claim_override: VerifiedCommandPlanV2 | None = None
        self.run_ledger_binding: dict[str, object] | None = None

    def _schema_binding(self, *, identifier: str, path: str) -> dict[str, object]:
        payload = (REPOSITORY_ROOT / path).read_bytes()
        binding = _typed_binding(
            identifier=identifier,
            artifact_kind="json_schema_2020_12",
            content_type="json_schema",
            schema_sha256=None,
            path=path,
            payload=payload,
        )
        self.payloads[path] = payload
        return binding

    def reopen(self, binding: dict[str, object]) -> bytes:
        return self.payloads[str(binding["path"])]

    def gate_verifiers(self):
        def verifier(
            binding: TypedArtifactBindingV2,
            payload: bytes,
        ) -> VerifiedGateReceiptV2:
            document = json.loads(payload)
            if canonical_json_file_bytes_v2(document) != payload:
                raise ValueError("gate receipt is not canonical")
            if (
                document["gate_id"] != binding.id
                or document["artifact_kind"] != binding.artifact_kind
                or document["schema_sha256"] != binding.schema_sha256
            ):
                raise ValueError("gate receipt type differs")
            closure = tuple(
                TypedArtifactBindingV2.from_mapping(
                    value,
                    label=f"{binding.id} parsed closure {index}",
                )
                for index, value in enumerate(document["closure_bindings"])
            )
            claim = VerifiedGateReceiptV2(
                gate_id=str(document["gate_id"]),
                artifact_kind=str(document["artifact_kind"]),
                schema_sha256=str(document["schema_sha256"]),
                source_commit=str(document["source_commit"]),
                working_tree_clean=bool(document["working_tree_clean"]),
                current_source=bool(document["current_source"]),
                status=str(document["status"]),
                holdout_accessed=bool(document["holdout_accessed"]),
                closure_bindings=closure,
            )
            return self.gate_claim_overrides.get(binding.id, claim)

        return {gate_id: verifier for gate_id in ("G04", "G05", "G06")}

    def command_verifier(
        self,
        binding: TypedArtifactBindingV2,
        payload: bytes,
    ) -> VerifiedCommandPlanV2:
        document = json.loads(payload)
        if canonical_json_file_bytes_v2(document) != payload:
            raise ValueError("command plan is not canonical")
        if (
            document["artifact_kind"] != binding.artifact_kind
            or document["schema_sha256"] != binding.schema_sha256
        ):
            raise ValueError("command plan type differs")
        closure = tuple(
            TypedArtifactBindingV2.from_mapping(
                value,
                label=f"parsed command closure {index}",
            )
            for index, value in enumerate(document["required_input_closure"])
        )
        claim = VerifiedCommandPlanV2(
            artifact_kind=str(document["artifact_kind"]),
            schema_sha256=str(document["schema_sha256"]),
            run_id=str(document["run_id"]),
            plan_id=str(document["plan_id"]),
            source_commit=str(document["source_commit"]),
            status=str(document["status"]),
            holdout_accessed=bool(document["holdout_accessed"]),
            required_input_closure=closure,
        )
        return self.command_claim_override or claim

    def build_receipt(self) -> tuple[dict[str, object], dict[str, object]]:
        receipt = dict(
            build_run_provenance_receipt_v2(
                run_id=RUN_ID,
                gate_receipt_bindings=self.gate_bindings,
                producer_source_binding=self.producer_binding,
                command_plan_binding=self.command_binding,
                authority_payload_reopener=self.reopen,
                payload_reopener=self.reopen,
                gate_receipt_verifiers=self.gate_verifiers(),
                command_plan_verifier=self.command_verifier,
            )
        )
        payload = canonical_json_file_bytes_v2(receipt)
        binding = _typed_binding(
            identifier="p06_run_provenance_receipt_v2",
            artifact_kind="p06_run_provenance_receipt_v2",
            content_type="canonical_json",
            schema_sha256=PROVENANCE_SCHEMA_SHA256,
            path="p06-run-provenance-receipt-v2.json",
            payload=payload,
        )
        self.payloads[str(binding["path"])] = payload
        return receipt, binding

    def build_manifest(
        self,
        exclusions: list[FailureCycleExclusionV2] | None = None,
    ) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
        _, receipt_binding = self.build_receipt()
        normalized_exclusions = [] if exclusions is None else exclusions
        manifest = dict(
            build_run_input_manifest_v2(
                provenance_receipt_binding=receipt_binding,
                failure_cycle_exclusions=normalized_exclusions,
                authority_payload_reopener=self.reopen,
                payload_reopener=self.reopen,
                gate_receipt_verifiers=self.gate_verifiers(),
                command_plan_verifier=self.command_verifier,
                expected_run_id=RUN_ID,
            )
        )
        payload = canonical_json_file_bytes_v2(manifest)
        binding = _typed_binding(
            identifier="p06_run_input_manifest_v2",
            artifact_kind="p06_run_input_manifest_v2",
            content_type="canonical_json",
            schema_sha256=RUN_INPUT_MANIFEST_SCHEMA_SHA256,
            path="p06-run-input-manifest-v2.json",
            payload=payload,
        )
        self.payloads[str(binding["path"])] = payload
        if not normalized_exclusions:
            self.finalize_run_ledger(binding, failure_binding=None)
        else:
            self.run_ledger_binding = None
        return manifest, binding, receipt_binding

    @staticmethod
    def provisional_failure() -> dict[str, object]:
        return {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_calibration_failure_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": RUN_ID,
            "shared_bank_configuration_sha256": _sha("shared-bank"),
            "candidate_vector_sha256": _sha("candidate"),
            "failure_stage": "development_search",
            "failure_type": "terminal",
            "failure_code": "terminal.fixture",
            "failure_message": "fixture terminal failure",
            "failure_reasons": [],
            "failure_bindings": {
                "attempt_ledger": {
                    "applicable": True,
                    "binding": _content_binding(
                        "attempts-v2.ndjson",
                        "attempt-ledger",
                    ),
                },
                "trace_evidence": {
                    "applicable": True,
                    "binding": _content_binding("failure/trace.log", "trace"),
                },
                "artifact_manifest": {
                    "applicable": True,
                    "binding": {
                        "path": "p06-run-input-manifest-v2.json",
                        "sha256": _sha("unpublished-manifest-placeholder"),
                        "size_bytes": 1,
                    },
                },
                "cleanup_evidence": {"applicable": False, "binding": None},
                "recovery_evidence": {"applicable": False, "binding": None},
            },
            "cleanup": {
                "invoked": False,
                "idempotent": True,
                "completed": False,
                "unrelated_files_deleted": False,
            },
            "recovery": {
                "resume_allowed": False,
                "recovery_stage": "none",
                "resume_source": {"applicable": False, "binding": None},
            },
            "status": "failed_preserved",
            "data_access": {
                "development_accessed": True,
                "validation_accessed": False,
                "holdout_accessed": False,
                "release_locks_written": False,
            },
            "artifact_sha256": _sha("unfinalized-failure"),
        }

    @staticmethod
    def provisional_evaluation_failure() -> dict[str, object]:
        failure = _Harness.provisional_failure()
        failure["failure_type"] = "evaluation"
        failure["failure_code"] = "evaluation.fixture"
        failure["failure_message"] = "fixture evaluator failure"
        failure["failure_reasons"] = ["fixture evaluator rejected input"]
        failure["recovery"] = {
            "resume_allowed": True,
            "recovery_stage": "resume_development_search",
            "resume_source": {
                "applicable": True,
                "binding": _content_binding(
                    "failure/resume-source.json",
                    "resume-source",
                ),
            },
        }
        return failure

    def finalize_failure(
        self,
        provisional: dict[str, object],
        manifest_binding: dict[str, object],
    ) -> tuple[dict[str, object], dict[str, object]]:
        failure = deepcopy(provisional)
        failure["failure_bindings"]["artifact_manifest"]["binding"] = {
            "path": manifest_binding["path"],
            "sha256": manifest_binding["sha256"],
            "size_bytes": manifest_binding["size_bytes"],
        }
        failure["artifact_sha256"] = _semantic_hash(failure, "artifact_sha256")
        payload = canonical_json_file_bytes_v2(failure)
        digest = _sha(payload)
        binding = {
            "path": f"failures/{digest}.json",
            "sha256": digest,
            "size_bytes": len(payload),
        }
        self.payloads[str(binding["path"])] = payload
        return failure, binding

    def finalize_run_ledger(
        self,
        manifest_binding: dict[str, object],
        *,
        failure_binding: dict[str, object] | None,
        candidate_failure_bindings: list[dict[str, object]] | None = None,
    ) -> dict[str, object]:
        inputs = list(authority_input_bindings_v2())
        candidate_failure_entries = [
            {
                "split": "development",
                "candidate_vector_sha256": json.loads(
                    self.payloads[str(binding["path"])]
                )["candidate_vector_sha256"],
                "binding": dict(binding),
            }
            for binding in candidate_failure_bindings or ()
        ]
        candidate_failure_identities = sorted(
            [
                [
                    entry["split"],
                    entry["candidate_vector_sha256"],
                    entry["binding"]["sha256"],
                ]
                for entry in candidate_failure_entries
            ]
        )
        ledger: dict[str, object] = {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_run_ledger_v2",
            "authority_bindings": authority_bindings_v2(),
            "run_id": RUN_ID,
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "input_bundle_sha256": (
                "ad46b6ec3d3629c3a29f17898c6a9b4eec1bca731276ff626dfe58f87bcadd20"
            ),
            "input_bindings": inputs,
            "shared_bank_configuration_sha256": _sha("shared-bank"),
            "maximum_development_attempt_count": 3288,
            "maximum_validation_attempt_count": 374,
            "attempt_ledger": {
                "path": "attempts-v2.ndjson",
                "sha256": _sha("attempt-ledger"),
                "size_bytes": 1,
                "record_count": 822 if failure_binding is None else 256,
                "last_record_sha256": _sha("attempt-tail"),
            },
            "completed_sweeps": 0,
            "candidate_failures": candidate_failure_entries,
            "candidate_failure_count": len(candidate_failure_entries),
            "candidate_failure_identity_set_sha256": _sha(
                canonical_json_bytes_v2(candidate_failure_identities)
            ),
            "artifact_manifest": {
                "path": manifest_binding["path"],
                "sha256": manifest_binding["sha256"],
                "size_bytes": manifest_binding["size_bytes"],
            },
            "artifact_sha256": _sha("unfinalized-ledger"),
        }
        if failure_binding is None:
            evaluation_sha256 = _sha("validation-evaluation")
            validation_candidate_sha256 = _sha("validation-candidate")
            evaluation_identities = [
                ["validation", validation_candidate_sha256, evaluation_sha256]
            ]
            ledger.update(
                {
                    "development_attempt_count": 822,
                    "validation_attempt_count": 1,
                    "attempt_count": 822,
                    "development_status": "terminated_feasible",
                    "development_terminal_candidate_vector_sha256": _sha(
                        "development-terminal"
                    ),
                    "validation_admission": _content_binding(
                        "validation-candidate-development-evidence-v2.json",
                        "validation-admission",
                    ),
                    "candidate_evaluations": [
                        {
                            "split": "validation",
                            "candidate_vector_sha256": validation_candidate_sha256,
                            "binding": {
                                "path": f"evaluations/{evaluation_sha256}.json",
                                "sha256": evaluation_sha256,
                                "size_bytes": 1,
                            },
                        }
                    ],
                    "candidate_evaluation_count": 1,
                    "candidate_evaluation_identity_set_sha256": _sha(
                        canonical_json_bytes_v2(evaluation_identities)
                    ),
                    "data_separation": {
                        "all_development_attempts_precede_validation": True,
                        "development_validation_cache_namespaces_distinct": True,
                        "validation_opened_after_development_freeze": True,
                        "holdout_accessed": False,
                    },
                    "run_status": "selection_ready",
                    "failure": None,
                    "data_access": {
                        "development_accessed": True,
                        "validation_accessed": True,
                        "holdout_accessed": False,
                        "release_locks_written": False,
                    },
                }
            )
        else:
            ledger.update(
                {
                    "development_attempt_count": 256,
                    "validation_attempt_count": 0,
                    "attempt_count": 256,
                    "development_status": "failed_no_eligible_structural_candidate",
                    "development_terminal_candidate_vector_sha256": None,
                    "validation_admission": None,
                    "candidate_evaluations": [],
                    "candidate_evaluation_count": 0,
                    "candidate_evaluation_identity_set_sha256": _sha(
                        canonical_json_bytes_v2([])
                    ),
                    "data_separation": {
                        "all_development_attempts_precede_validation": True,
                        "development_validation_cache_namespaces_distinct": True,
                        "validation_opened_after_development_freeze": False,
                        "holdout_accessed": False,
                    },
                    "run_status": "failed",
                    "failure": dict(failure_binding),
                    "data_access": {
                        "development_accessed": True,
                        "validation_accessed": False,
                        "holdout_accessed": False,
                        "release_locks_written": False,
                    },
                }
            )
        ledger["artifact_sha256"] = _semantic_hash(ledger, "artifact_sha256")
        payload = canonical_json_file_bytes_v2(ledger)
        binding = _typed_binding(
            identifier="p06_calibration_run_ledger_v2",
            artifact_kind="p06_calibration_run_ledger_v2",
            content_type="canonical_json",
            schema_sha256=str(self.run_ledger_schema_binding["sha256"]),
            path="calibration-run-ledger-v2.json",
            payload=payload,
        )
        self.payloads[str(binding["path"])] = payload
        self.run_ledger_binding = binding
        return binding

    @staticmethod
    def failure_verifier(
        binding: dict[str, object],
        payload: bytes,
    ) -> dict[str, object]:
        document = json.loads(payload)
        if canonical_json_file_bytes_v2(document) != payload:
            raise ValueError("failure is not canonical")
        if binding["sha256"] != _sha(payload):
            raise ValueError("failure binding differs")
        return document

    @staticmethod
    def run_ledger_verifier(
        binding: TypedArtifactBindingV2,
        payload: bytes,
    ) -> dict[str, object]:
        document = json.loads(payload)
        if canonical_json_file_bytes_v2(document) != payload:
            raise ValueError("run ledger is not canonical")
        if binding.sha256 != _sha(payload):
            raise ValueError("run-ledger binding differs")
        return document


class RunProvenanceV2Tests(unittest.TestCase):
    def test_authorities_receipt_and_manifest_reopen(self) -> None:
        harness = _Harness()
        authenticated = authenticate_authorities_v2(harness.reopen)
        self.assertEqual(len(authenticated.documents), 5)
        self.assertEqual(
            [binding.artifact_kind for binding in authority_closure_bindings_v2()[::2]],
            [document["artifact_kind"] for _, document in authenticated.documents],
        )

        receipt, receipt_binding = harness.build_receipt()
        verified_receipt = reopen_run_provenance_receipt_v2(
            receipt_binding,
            authority_payload_reopener=harness.reopen,
            payload_reopener=harness.reopen,
            gate_receipt_verifiers=harness.gate_verifiers(),
            command_plan_verifier=harness.command_verifier,
            expected_run_id=RUN_ID,
        )
        self.assertEqual(verified_receipt.document, receipt)
        self.assertEqual(verified_receipt.source_commit, SOURCE_COMMIT)
        self.assertEqual(
            [row["id"] for row in receipt["gate_receipts"]],
            ["G04", "G05", "G06"],
        )
        self.assertTrue(all(row["closure_bindings"] for row in receipt["gate_receipts"]))
        self.assertNotEqual(receipt["platform"]["release"], "fixture")
        self.assertNotEqual(
            receipt["toolchain"][0]["executable_sha256"],
            _sha("python-executable"),
        )

        manifest, manifest_binding, _ = harness.build_manifest()
        self.assertIsNotNone(harness.run_ledger_binding)
        verified_manifest = reopen_run_input_manifest_v2(
            manifest_binding,
            run_ledger_binding=harness.run_ledger_binding,
            authority_payload_reopener=harness.reopen,
            payload_reopener=harness.reopen,
            gate_receipt_verifiers=harness.gate_verifiers(),
            command_plan_verifier=harness.command_verifier,
            run_ledger_semantic_verifier=harness.run_ledger_verifier,
            failure_semantic_verifier=None,
            expected_run_id=RUN_ID,
        )
        self.assertEqual(verified_manifest.document, manifest)
        self.assertEqual(manifest["artifact_count"], 24)
        self.assertEqual(manifest["fixed_exclusions"], list(FIXED_EXCLUSIONS))
        artifact_ids = {row["id"] for row in manifest["artifacts"]}
        self.assertIn("p06_run_provenance_receipt_v2_schema", artifact_ids)
        self.assertIn("p06_run_input_manifest_v2_schema", artifact_ids)
        self.assertIn("p06_calibration_failure_v2_schema", artifact_ids)

    def test_failure_cycle_identity_is_schema_valid_and_ledger_derived(self) -> None:
        harness = _Harness()
        provisional = harness.provisional_failure()
        exclusion = build_failure_cycle_exclusion_v2(provisional)
        manifest, manifest_binding, _ = harness.build_manifest([exclusion])
        failure, failure_binding = harness.finalize_failure(
            provisional,
            manifest_binding,
        )
        harness.finalize_run_ledger(
            manifest_binding,
            failure_binding=failure_binding,
        )
        self.assertEqual(
            exclusion.failure_identity_sha256,
            failure_identity_sha256_v2(failure),
        )
        verified = reopen_run_input_manifest_v2(
            manifest_binding,
            run_ledger_binding=harness.run_ledger_binding,
            authority_payload_reopener=harness.reopen,
            payload_reopener=harness.reopen,
            gate_receipt_verifiers=harness.gate_verifiers(),
            command_plan_verifier=harness.command_verifier,
            run_ledger_semantic_verifier=harness.run_ledger_verifier,
            failure_semantic_verifier=harness.failure_verifier,
            expected_run_id=RUN_ID,
        )
        self.assertEqual(
            verified.failure_identities,
            (exclusion.failure_identity_sha256,),
        )
        self.assertNotIn("path", manifest["failure_cycle_exclusions"][0])
        self.assertTrue(
            any("bidirectional" in item for item in FAILURE_INTEGRATION_REQUIREMENTS_V2)
        )

    def test_candidate_and_terminal_failure_union_is_exact(self) -> None:
        harness = _Harness()
        terminal = harness.provisional_failure()
        candidate = harness.provisional_evaluation_failure()
        exclusions = [
            build_failure_cycle_exclusion_v2(terminal),
            build_failure_cycle_exclusion_v2(candidate),
        ]
        manifest, manifest_binding, _ = harness.build_manifest(exclusions)
        _, terminal_binding = harness.finalize_failure(terminal, manifest_binding)
        _, candidate_binding = harness.finalize_failure(candidate, manifest_binding)
        harness.finalize_run_ledger(
            manifest_binding,
            failure_binding=terminal_binding,
            candidate_failure_bindings=[candidate_binding],
        )
        verified = reopen_run_input_manifest_v2(
            manifest_binding,
            run_ledger_binding=harness.run_ledger_binding,
            authority_payload_reopener=harness.reopen,
            payload_reopener=harness.reopen,
            gate_receipt_verifiers=harness.gate_verifiers(),
            command_plan_verifier=harness.command_verifier,
            run_ledger_semantic_verifier=harness.run_ledger_verifier,
            failure_semantic_verifier=harness.failure_verifier,
            expected_run_id=RUN_ID,
        )
        self.assertEqual(
            set(verified.failure_identities),
            {exclusion.failure_identity_sha256 for exclusion in exclusions},
        )

        ledger = json.loads(harness.reopen(harness.run_ledger_binding))

        def publish_ledger(document: dict[str, object]) -> dict[str, object]:
            document["artifact_sha256"] = _semantic_hash(
                document, "artifact_sha256"
            )
            payload = canonical_json_file_bytes_v2(document)
            binding = deepcopy(harness.run_ledger_binding)
            binding["sha256"] = _sha(payload)
            binding["size_bytes"] = len(payload)
            harness.payloads[str(binding["path"])] = payload
            return binding

        wrong_count = deepcopy(ledger)
        wrong_count["candidate_failure_count"] = 0
        bad_binding = publish_ledger(wrong_count)
        with self.assertRaisesRegex(
            RunProvenanceV2Error,
            "candidate-failure count or set identity differs",
        ):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=bad_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

        wrong_candidate = deepcopy(ledger)
        wrong_candidate["candidate_failures"][0][
            "candidate_vector_sha256"
        ] = _sha("different-candidate")
        identities = sorted(
            [
                [
                    entry["split"],
                    entry["candidate_vector_sha256"],
                    entry["binding"]["sha256"],
                ]
                for entry in wrong_candidate["candidate_failures"]
            ]
        )
        wrong_candidate["candidate_failure_identity_set_sha256"] = _sha(
            canonical_json_bytes_v2(identities)
        )
        bad_binding = publish_ledger(wrong_candidate)
        with self.assertRaisesRegex(RunProvenanceV2Error, "candidate relation differs"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=bad_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

        swapped_roles = deepcopy(ledger)
        swapped_roles["candidate_failures"][0]["binding"] = dict(terminal_binding)
        swapped_roles["candidate_failures"][0][
            "candidate_vector_sha256"
        ] = terminal["candidate_vector_sha256"]
        swapped_roles["failure"] = dict(candidate_binding)
        identities = sorted(
            [
                [
                    entry["split"],
                    entry["candidate_vector_sha256"],
                    entry["binding"]["sha256"],
                ]
                for entry in swapped_roles["candidate_failures"]
            ]
        )
        swapped_roles["candidate_failure_identity_set_sha256"] = _sha(
            canonical_json_bytes_v2(identities)
        )
        bad_binding = publish_ledger(swapped_roles)
        with self.assertRaisesRegex(
            RunProvenanceV2Error,
            "candidate relation differs|terminal relation differs",
        ):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=bad_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

    def test_gate_order_clean_commit_and_holdout_are_mandatory(self) -> None:
        harness = _Harness()
        with self.assertRaisesRegex(RunProvenanceV2Error, "gate receipt order"):
            build_run_provenance_receipt_v2(
                run_id=RUN_ID,
                gate_receipt_bindings=list(reversed(harness.gate_bindings)),
                producer_source_binding=harness.producer_binding,
                command_plan_binding=harness.command_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
            )

        base = harness.gate_verifiers()["G05"](
            TypedArtifactBindingV2.from_mapping(
                harness.gate_bindings[1], label="G05 fixture"
            ),
            harness.reopen(harness.gate_bindings[1]),
        )
        harness.gate_claim_overrides["G05"] = VerifiedGateReceiptV2(
            gate_id=base.gate_id,
            artifact_kind=base.artifact_kind,
            schema_sha256=base.schema_sha256,
            source_commit=base.source_commit,
            working_tree_clean=False,
            current_source=True,
            status="pass",
            holdout_accessed=False,
            closure_bindings=base.closure_bindings,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "clean current-source pass"):
            harness.build_receipt()

        harness = _Harness()
        base = harness.gate_verifiers()["G04"](
            TypedArtifactBindingV2.from_mapping(
                harness.gate_bindings[0], label="G04 fixture"
            ),
            harness.reopen(harness.gate_bindings[0]),
        )
        harness.gate_claim_overrides["G04"] = VerifiedGateReceiptV2(
            gate_id=base.gate_id,
            artifact_kind=base.artifact_kind,
            schema_sha256=base.schema_sha256,
            source_commit=base.source_commit,
            working_tree_clean=True,
            current_source=True,
            status="pass",
            holdout_accessed=True,
            closure_bindings=base.closure_bindings,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "clean current-source pass"):
            harness.build_receipt()

        harness = _Harness()
        base = harness.gate_verifiers()["G06"](
            TypedArtifactBindingV2.from_mapping(
                harness.gate_bindings[2], label="G06 fixture"
            ),
            harness.reopen(harness.gate_bindings[2]),
        )
        harness.gate_claim_overrides["G06"] = VerifiedGateReceiptV2(
            gate_id=base.gate_id,
            artifact_kind=base.artifact_kind,
            schema_sha256=base.schema_sha256,
            source_commit="b" * 40,
            working_tree_clean=True,
            current_source=True,
            status="pass",
            holdout_accessed=False,
            closure_bindings=base.closure_bindings,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "source commits differ"):
            harness.build_receipt()

    def test_authority_tamper_and_wrong_command_semantics_are_rejected(self) -> None:
        harness = _Harness()
        target = "validation/calibration_v2/contracts/candidate-evidence-policy-v2.json"

        def tampered(binding: dict[str, object]) -> bytes:
            payload = harness.reopen(binding)
            return payload + b"x" if binding["path"] == target else payload

        with self.assertRaisesRegex(RunProvenanceV2Error, "bytes differ"):
            authenticate_authorities_v2(tampered)

        claim = harness.command_verifier(
            TypedArtifactBindingV2.from_mapping(
                harness.command_binding, label="command fixture"
            ),
            harness.reopen(harness.command_binding),
        )
        harness.command_claim_override = VerifiedCommandPlanV2(
            artifact_kind=claim.artifact_kind,
            schema_sha256=claim.schema_sha256,
            run_id=claim.run_id,
            plan_id=claim.plan_id,
            source_commit="b" * 40,
            status=claim.status,
            holdout_accessed=claim.holdout_accessed,
            required_input_closure=claim.required_input_closure,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "command-plan semantic identity"):
            harness.build_receipt()

    def test_all_callback_dependencies_are_finally_reopened(self) -> None:
        harness = _Harness()

        def mutating_command(binding, payload):
            claim = harness.command_verifier(binding, payload)
            harness.payloads[binding.path] = b"changed command bytes\n"
            return claim

        with self.assertRaisesRegex(RunProvenanceV2Error, "P06 command plan bytes differ"):
            build_run_provenance_receipt_v2(
                run_id=RUN_ID,
                gate_receipt_bindings=harness.gate_bindings,
                producer_source_binding=harness.producer_binding,
                command_plan_binding=harness.command_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=mutating_command,
            )

        harness = _Harness()
        g04_path = str(harness.gate_bindings[0]["path"])

        def mutating_gate_dependency(binding, payload):
            claim = harness.command_verifier(binding, payload)
            harness.payloads[g04_path] = b"changed G04 receipt bytes\n"
            return claim

        with self.assertRaisesRegex(RunProvenanceV2Error, "G04 receipt bytes differ"):
            build_run_provenance_receipt_v2(
                run_id=RUN_ID,
                gate_receipt_bindings=harness.gate_bindings,
                producer_source_binding=harness.producer_binding,
                command_plan_binding=harness.command_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=mutating_gate_dependency,
            )

        harness = _Harness()
        authority_path = (
            "validation/calibration_v2/contracts/baseline-ablation-budget-v2.json"
        )

        def mutating_authority_dependency(binding, payload):
            claim = harness.command_verifier(binding, payload)
            harness.payloads[authority_path] = b"changed authority bytes\n"
            return claim

        with self.assertRaisesRegex(RunProvenanceV2Error, "authority bytes differ"):
            build_run_provenance_receipt_v2(
                run_id=RUN_ID,
                gate_receipt_bindings=harness.gate_bindings,
                producer_source_binding=harness.producer_binding,
                command_plan_binding=harness.command_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=mutating_authority_dependency,
            )

    def test_bound_types_and_manifest_binding_are_mandatory(self) -> None:
        harness = _Harness()
        _, receipt_binding = harness.build_receipt()
        wrong_receipt_binding = deepcopy(receipt_binding)
        wrong_receipt_binding["schema_sha256"] = _sha("wrong-receipt-schema")
        with self.assertRaisesRegex(RunProvenanceV2Error, "receipt binding type"):
            reopen_run_provenance_receipt_v2(
                wrong_receipt_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
            )

        manifest, manifest_binding, _ = harness.build_manifest()
        wrong_manifest_binding = deepcopy(manifest_binding)
        wrong_manifest_binding["sha256"] = _sha("wrong-manifest-binding")
        with self.assertRaisesRegex(RunProvenanceV2Error, "canonical document"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=wrong_manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

    def test_receipt_commit_clean_and_environment_cannot_be_substituted(self) -> None:
        harness = _Harness()
        receipt, _ = harness.build_receipt()
        wrong_commit = deepcopy(receipt)
        wrong_commit["source_commit"] = "b" * 40
        wrong_commit["receipt_sha256"] = _semantic_hash(wrong_commit, "receipt_sha256")
        with self.assertRaisesRegex(RunProvenanceV2Error, "semantic re-derivation"):
            verify_run_provenance_receipt_v2(
                wrong_commit,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
            )

        dirty = deepcopy(receipt)
        dirty["working_tree_clean"] = False
        dirty["receipt_sha256"] = _semantic_hash(dirty, "receipt_sha256")
        with self.assertRaisesRegex(RunProvenanceV2Error, "schema validation"):
            verify_run_provenance_receipt_v2(
                dirty,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
            )

        fake_environment = deepcopy(receipt)
        fake_environment["platform"]["release"] = "fixture"
        fake_environment["toolchain"][0]["executable_sha256"] = _sha(
            "python-executable"
        )
        fake_environment["receipt_sha256"] = _semantic_hash(
            fake_environment, "receipt_sha256"
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "semantic re-derivation"):
            verify_run_provenance_receipt_v2(
                fake_environment,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
            )

    def test_command_derived_closure_and_generic_manifest_are_rejected(self) -> None:
        harness = _Harness()
        manifest, manifest_binding, _ = harness.build_manifest()
        generic = deepcopy(manifest)
        generic["artifact_kind"] = "generic_artifact_manifest"
        generic["manifest_sha256"] = _semantic_hash(generic, "manifest_sha256")
        generic_payload = canonical_json_file_bytes_v2(generic)
        generic_binding = deepcopy(manifest_binding)
        generic_binding["sha256"] = _sha(generic_payload)
        generic_binding["size_bytes"] = len(generic_payload)
        with self.assertRaisesRegex(RunProvenanceV2Error, "schema validation"):
            verify_run_input_manifest_v2(
                generic,
                manifest_binding=generic_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

        claim = harness.command_verifier(
            TypedArtifactBindingV2.from_mapping(
                harness.command_binding, label="command fixture"
            ),
            harness.reopen(harness.command_binding),
        )
        replacement_payload = b"different required input\n"
        replacement_mapping = _typed_binding(
            identifier="different_required_input",
            artifact_kind="opaque_fixture",
            content_type="opaque_bytes",
            schema_sha256=None,
            path="inputs/different-required-input.bin",
            payload=replacement_payload,
        )
        harness.payloads[str(replacement_mapping["path"])] = replacement_payload
        replacement = TypedArtifactBindingV2.from_mapping(
            replacement_mapping, label="replacement command input"
        )
        changed_closure = tuple(
            sorted(
                (
                    replacement,
                    *(
                        binding
                        for binding in claim.required_input_closure
                        if binding.id != "fixture_locked_input"
                    ),
                ),
                key=lambda binding: binding.path,
            )
        )
        harness.command_claim_override = VerifiedCommandPlanV2(
            artifact_kind=claim.artifact_kind,
            schema_sha256=claim.schema_sha256,
            run_id=claim.run_id,
            plan_id=claim.plan_id,
            source_commit=claim.source_commit,
            status=claim.status,
            holdout_accessed=claim.holdout_accessed,
            required_input_closure=changed_closure,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "semantic re-derivation"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

    def test_fixed_exclusions_and_artifact_order_are_exact(self) -> None:
        harness = _Harness()
        manifest, manifest_binding, _ = harness.build_manifest()
        wrong_fixed = deepcopy(manifest)
        wrong_fixed["fixed_exclusions"] = list(reversed(wrong_fixed["fixed_exclusions"]))
        wrong_fixed["manifest_sha256"] = _semantic_hash(wrong_fixed, "manifest_sha256")
        with self.assertRaisesRegex(RunProvenanceV2Error, "schema validation"):
            verify_run_input_manifest_v2(
                wrong_fixed,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

        wrong_order = deepcopy(manifest)
        wrong_order["artifacts"] = list(reversed(wrong_order["artifacts"]))
        wrong_order["closure_sha256"] = _sha(
            canonical_json_bytes_v2(
                {
                    "artifacts": wrong_order["artifacts"],
                    "directories": wrong_order["directories"],
                    "failure_cycle_exclusions": wrong_order[
                        "failure_cycle_exclusions"
                    ],
                    "fixed_exclusions": wrong_order["fixed_exclusions"],
                }
            )
        )
        wrong_order["manifest_sha256"] = _semantic_hash(
            wrong_order, "manifest_sha256"
        )
        wrong_order_payload = canonical_json_file_bytes_v2(wrong_order)
        wrong_order_binding = deepcopy(manifest_binding)
        wrong_order_binding["sha256"] = _sha(wrong_order_payload)
        wrong_order_binding["size_bytes"] = len(wrong_order_payload)
        harness.payloads[str(wrong_order_binding["path"])] = wrong_order_payload
        with self.assertRaisesRegex(RunProvenanceV2Error, "noncyclic closure differs"):
            verify_run_input_manifest_v2(
                wrong_order,
                manifest_binding=wrong_order_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

    def test_failure_cycle_claims_cannot_be_missing_or_misdirected(self) -> None:
        harness = _Harness()
        provisional = harness.provisional_failure()
        exclusion = build_failure_cycle_exclusion_v2(provisional)
        manifest, manifest_binding, _ = harness.build_manifest([exclusion])
        _, failure_binding = harness.finalize_failure(provisional, manifest_binding)

        harness.finalize_run_ledger(manifest_binding, failure_binding=None)
        with self.assertRaisesRegex(RunProvenanceV2Error, "bidirectionally"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

        wrong_manifest_binding = deepcopy(manifest_binding)
        wrong_manifest_binding["sha256"] = _sha("wrong-manifest")
        wrong_failure, wrong_failure_binding = harness.finalize_failure(
            provisional,
            wrong_manifest_binding,
        )
        self.assertEqual(
            failure_identity_sha256_v2(wrong_failure),
            exclusion.failure_identity_sha256,
        )
        harness.finalize_run_ledger(
            manifest_binding,
            failure_binding=wrong_failure_binding,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "does not bind this exact manifest"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

    def test_undeclared_and_schema_invalid_failures_are_rejected(self) -> None:
        harness = _Harness()
        manifest, manifest_binding, _ = harness.build_manifest()
        provisional = harness.provisional_failure()
        _, failure_binding = harness.finalize_failure(provisional, manifest_binding)
        harness.finalize_run_ledger(
            manifest_binding,
            failure_binding=failure_binding,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "bidirectionally"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

        harness = _Harness()
        invalid = harness.provisional_failure()
        invalid.pop("cleanup")
        exclusion = build_failure_cycle_exclusion_v2(invalid)
        manifest, manifest_binding, _ = harness.build_manifest([exclusion])
        _, invalid_binding = harness.finalize_failure(invalid, manifest_binding)
        harness.finalize_run_ledger(
            manifest_binding,
            failure_binding=invalid_binding,
        )
        with self.assertRaisesRegex(RunProvenanceV2Error, "schema validation failed"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=harness.failure_verifier,
            )

    def test_secondary_failure_bindings_cannot_create_cycles(self) -> None:
        harness = _Harness()
        provisional = harness.provisional_failure()
        cyclic_bindings = (
            {
                "path": "calibration-run-ledger-v2.json",
                "sha256": _sha("ledger"),
                "size_bytes": 1,
            },
            {
                "path": f"failures/{_sha('peer-failure')}.json",
                "sha256": _sha("peer-failure"),
                "size_bytes": 1,
            },
            {
                "path": "failure/manifest-alias.json",
                "sha256": provisional["failure_bindings"]["artifact_manifest"][
                    "binding"
                ]["sha256"],
                "size_bytes": 1,
            },
        )
        for binding in cyclic_bindings:
            candidate = deepcopy(provisional)
            candidate["failure_bindings"]["trace_evidence"]["binding"] = binding
            with self.subTest(path=binding["path"]):
                with self.assertRaisesRegex(
                    RunProvenanceV2Error,
                    "unsupported cycle",
                ):
                    build_failure_cycle_exclusion_v2(candidate)

        evaluation = harness.provisional_evaluation_failure()
        evaluation["recovery"]["resume_source"]["binding"] = {
            "path": "calibration-run-ledger-v2.json",
            "sha256": _sha("ledger"),
            "size_bytes": 1,
        }
        with self.assertRaisesRegex(RunProvenanceV2Error, "unsupported cycle"):
            build_failure_cycle_exclusion_v2(evaluation)

    def test_run_ledger_is_required_and_must_bind_the_manifest(self) -> None:
        harness = _Harness()
        manifest, manifest_binding, _ = harness.build_manifest()
        with self.assertRaisesRegex(RunProvenanceV2Error, "semantic verifier is required"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=None,
                failure_semantic_verifier=None,
            )

        def substituting_ledger(binding, payload):
            document = harness.run_ledger_verifier(binding, payload)
            document["run_id"] = "substituted-run"
            return document

        with self.assertRaisesRegex(RunProvenanceV2Error, "substituted content"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=substituting_ledger,
                failure_semantic_verifier=None,
            )

        with self.assertRaisesRegex(RunProvenanceV2Error, "run ledger binding"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding={},
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )

        wrong_manifest = deepcopy(manifest_binding)
        wrong_manifest["sha256"] = _sha("different-manifest")
        harness.finalize_run_ledger(wrong_manifest, failure_binding=None)
        with self.assertRaisesRegex(RunProvenanceV2Error, "authenticated run and manifest"):
            verify_run_input_manifest_v2(
                manifest,
                manifest_binding=manifest_binding,
                run_ledger_binding=harness.run_ledger_binding,
                authority_payload_reopener=harness.reopen,
                payload_reopener=harness.reopen,
                gate_receipt_verifiers=harness.gate_verifiers(),
                command_plan_verifier=harness.command_verifier,
                run_ledger_semantic_verifier=harness.run_ledger_verifier,
                failure_semantic_verifier=None,
            )


if __name__ == "__main__":
    unittest.main()
