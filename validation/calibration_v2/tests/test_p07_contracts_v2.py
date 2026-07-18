from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.p07.contracts_v2 import (
    IDENTITY_KEYS,
    P07ContractV2Error,
    release_identity_v2,
    selected_evaluation_projection_v2,
    validate_selected_evaluation_projection_v2,
)
from validation.calibration_v2.p07.production import (
    P07ProductionError,
    _locked_p06_v2_identity,
)
from validation.calibration_v2.p07.execution import (
    P07ExecutionError,
    P07Preflight,
    _transaction_intent_document,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


SCHEMA_ROOT = Path(__file__).resolve().parents[1] / "schemas"


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _fixture() -> tuple[dict[str, object], ...]:
    objective = {
        "y_vs_fixed_ci_low": 0.1,
        "y_vs_non_ash_ci_low": 0.2,
        "y_vs_conventional_ci_low": 0.3,
        "mean_ms_ssim_delta_vs_conventional": 0.01,
        "maximum_ringing_excursion": 0.02,
        "maximum_alias_ratio": 0.03,
        "estimated_dispatch_cost": 2.0,
    }
    evaluation = {
        "schema_version": "2.0.3",
        "artifact_kind": "p06_candidate_evaluation_v2",
        "split": "validation",
        "candidate_vector_sha256": _sha("candidate"),
        "shared_bank_configuration_sha256": _sha("shared-bank"),
        "runtime_evidence_sha256": _sha("runtime"),
        "evaluation": {
            "feasible": True,
            "failure_reasons": [],
            "objective": objective,
        },
        "checks": [
            {
                "check_id": "generated-only-check",
                "status": "pass",
                "evidence_sha256": _sha("check"),
            }
        ],
        "evaluation_status": "feasible",
        "evaluation_semantic_sha256": "0" * 64,
        "evidence_sha256": "0" * 64,
        "artifact_sha256": "0" * 64,
    }
    evaluation["evaluation_semantic_sha256"] = canonical_sha256(
        evaluation["evaluation"]
    )
    evaluation["evidence_sha256"] = canonical_sha256(
        {
            key: value
            for key, value in evaluation.items()
            if key not in {"evidence_sha256", "artifact_sha256"}
        }
    )
    evaluation["artifact_sha256"] = canonical_sha256(
        {
            key: value
            for key, value in evaluation.items()
            if key != "artifact_sha256"
        }
    )
    selection = {
        "schema_version": "2.0.2",
        "shared_bank_configuration_sha256": evaluation[
            "shared_bank_configuration_sha256"
        ],
        "selected": {
            "candidate_vector_sha256": evaluation[
                "candidate_vector_sha256"
            ],
            "evaluation_semantic_sha256": evaluation[
                "evaluation_semantic_sha256"
            ],
        },
    }
    compiler = {
        "schema_version": "2.0.0",
        "hash_bindings": {
            "calibration_plan_sha256": _sha("calibration-plan-v2-file")
        },
    }
    bundle = {
        "schema_version": "3.0.1",
        "artifact_kind": "p06_release_bundle_v3",
        "bundle_id": "mirmir-p06-spatial-release-lock-v3",
        "configuration_id": "ash-p06-0123456789abcdef01234567",
        "shared_bank_configuration_sha256": evaluation[
            "shared_bank_configuration_sha256"
        ],
        "input_bundle_sha256": _sha("input-bundle"),
        "artifacts": [
            {
                "id": "selected_evaluation",
                "path": "selected-evaluation.json",
                "sha256": _sha("selected-evaluation-file"),
                "size_bytes": 1,
            }
        ],
    }
    bundle["artifact_sha256"] = canonical_sha256(bundle)
    return bundle, selection, evaluation, compiler


class P07ContractsV2Tests(unittest.TestCase):
    def test_exact_release_identity_and_projection_round_trip(self) -> None:
        bundle, selection, evaluation, compiler = _fixture()
        identity = release_identity_v2(
            bundle=bundle,
            selection=selection,
            evaluation=evaluation,
            compiler_input=compiler,
        )
        self.assertEqual(set(identity), set(IDENTITY_KEYS))
        projection = selected_evaluation_projection_v2(
            evaluation,
            identity=identity,
        )
        self.assertEqual(
            validate_selected_evaluation_projection_v2(
                projection,
                identity=identity,
            ),
            projection,
        )
        self.assertNotIn("performance", projection)
        self.assertNotIn("analytic_fixture_results", projection)
        self.assertNotIn("control_runtime_invocations", projection)

    def test_release_cross_link_and_failed_check_are_rejected(self) -> None:
        bundle, selection, evaluation, compiler = _fixture()
        changed_selection = deepcopy(selection)
        changed_selection["selected"]["candidate_vector_sha256"] = _sha(
            "another-candidate"
        )
        with self.assertRaises(P07ContractV2Error):
            release_identity_v2(
                bundle=bundle,
                selection=changed_selection,
                evaluation=evaluation,
                compiler_input=compiler,
            )
        identity = release_identity_v2(
            bundle=bundle,
            selection=selection,
            evaluation=evaluation,
            compiler_input=compiler,
        )
        failed = deepcopy(evaluation)
        failed["checks"][0]["status"] = "fail"
        with self.assertRaises(P07ContractV2Error):
            selected_evaluation_projection_v2(failed, identity=identity)

    def test_all_identity_schemas_close_the_exact_field_set(self) -> None:
        paths = sorted(SCHEMA_ROOT.glob("p07-*-v2.schema.json"))
        checked = 0
        for path in paths:
            schema = json.loads(path.read_text(encoding="utf-8"))
            identity_schema = schema.get("$defs", {}).get("p06Identity")
            if identity_schema is None:
                continue
            checked += 1
            self.assertEqual(
                set(identity_schema["required"]),
                set(IDENTITY_KEYS),
                path.name,
            )
            self.assertEqual(
                set(identity_schema["properties"]),
                set(IDENTITY_KEYS),
                path.name,
            )
            self.assertIs(identity_schema["additionalProperties"], False)
        self.assertEqual(checked, 11)

    def test_publication_schema_rejects_extra_identity_field(self) -> None:
        bundle, selection, evaluation, compiler = _fixture()
        identity = dict(
            release_identity_v2(
                bundle=bundle,
                selection=selection,
                evaluation=evaluation,
                compiler_input=compiler,
            )
        )
        schema = json.loads(
            (SCHEMA_ROOT / "p07-g07-publication-v2.schema.json").read_text(
                encoding="utf-8"
            )
        )
        document = {
            "schema_version": "2.0.0",
            "artifact_kind": "p07_g07_publication_v2",
            "p06_v2_identity": identity,
            "status": "pass",
            "gate_pass": True,
            "artifact_file_sha256": {"g07-decision.json": _sha("gate")},
            "holdout_accessed": True,
            "configuration_files_modified_after_holdout": False,
            "manifest_sha256": _sha("publication"),
        }
        validator = Draft202012Validator(schema)
        self.assertEqual(list(validator.iter_errors(document)), [])
        document["p06_v2_identity"]["unexpected_sha256"] = _sha("extra")
        errors = list(validator.iter_errors(document))
        self.assertTrue(
            any("Additional properties" in error.message for error in errors)
        )

    def test_v3_release_cannot_fall_back_to_v1_dispatch(self) -> None:
        locked = SimpleNamespace(
            release_bundle={
                "schema_version": "3.0.1",
                "bundle_id": "mirmir-p06-spatial-release-lock-v3",
            }
        )
        with self.assertRaisesRegex(
            P07ProductionError,
            "no authenticated P07 V2 identity",
        ):
            _locked_p06_v2_identity(locked)

    def test_v3_transaction_intent_requires_and_emits_v2_identity(self) -> None:
        bundle, selection, evaluation, compiler = _fixture()
        identity = release_identity_v2(
            bundle=bundle,
            selection=selection,
            evaluation=evaluation,
            compiler_input=compiler,
        )
        source_gate_semantics = {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_current_source_gate_semantics_v2",
            "status": "pass",
            "source_commit": "a" * 40,
            "working_tree_clean": True,
            "holdout_accessed": False,
            "gates": [{"gate_id": gate_id} for gate_id in ("G04", "G05", "G06")],
        }
        source_gate_semantics["manifest_sha256"] = canonical_sha256(
            source_gate_semantics
        )
        preflight = P07Preflight(
            plan={"manifest_sha256": _sha("sampling-plan")},
            plan_file_sha256=_sha("sampling-plan-file"),
            attestation={
                "inner_inventory": {"sha256": _sha("inventory")},
                "read_only_provisioning_workflow": {
                    "unmount_script_sha256": _sha("unmount")
                },
            },
            attestation_file_sha256=_sha("attestation"),
            corpus_lock={"manifest_sha256": _sha("corpus-manifest")},
            corpus_lock_file_sha256=_sha("corpus-file"),
            degradation_policy={},
            analytic_fixture_manifest={},
            outer_wrapper={"manifest_sha256": _sha("outer")},
            outer_wrapper_file_sha256=_sha("outer-file"),
            release_bundle=bundle,
            workflow_paths={"unmount_script_path": Path("/tmp/unmount")},
            mount_root=Path("/tmp/mount"),
            loader_sha256=_sha("loader"),
            p07_cache_tree_sha256=_sha("cache"),
            input_bundle_sha256=str(identity["input_bundle_sha256"]),
            corpus_lock_bundle_sha256=_sha("corpus-lock-bundle"),
            input_records=(),
            p06_v2_identity=identity,
            authorized_execution_bindings={
                "production_execution_binding_fragment": {
                    "source_gate_semantics": source_gate_semantics,
                }
            },
        )
        live = SimpleNamespace(
            live_ledger_path=Path("/tmp/ledger"),
            live_anchor_path=Path("/tmp/anchor"),
            live_preopen_receipt_path=Path("/tmp/receipt"),
            expected_live_ledger_root_identity_sha256=_sha("ledger-root"),
            expected_live_anchor_root_identity_sha256=_sha("anchor-root"),
            expected_live_preopen_receipt_sha256=_sha("receipt"),
        )
        document = _transaction_intent_document(
            output_directory=Path("/tmp/p07-output"),
            configuration_lock={"locked": True},
            preflight=preflight,
            live_binding=live,
            command="generated-only-test",
            platform="test-platform",
        )
        self.assertEqual(document["schema_version"], "2.0.0")
        self.assertEqual(document["p06_v2_identity"], identity)
        self.assertEqual(document["source_gate_semantics"], source_gate_semantics)
        missing = P07Preflight(
            **{
                **preflight.__dict__,
                "p06_v2_identity": None,
            }
        )
        with self.assertRaisesRegex(
            P07ExecutionError,
            "no authenticated P07 V2 identity",
        ):
            _transaction_intent_document(
                output_directory=Path("/tmp/p07-output"),
                configuration_lock={"locked": True},
                preflight=missing,
                live_binding=live,
                command="generated-only-test",
                platform="test-platform",
            )


if __name__ == "__main__":
    unittest.main()
