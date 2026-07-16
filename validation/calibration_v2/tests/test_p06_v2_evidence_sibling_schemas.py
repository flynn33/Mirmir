from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2 import calibration_scheduler_v2 as scheduler


ROOT = Path(__file__).resolve().parents[3]
SCHEMA_ROOT = ROOT / "validation/calibration_v2/schemas"

SCHEMA_NAMES = (
    "candidate-evaluation-v2",
    "calibration-attempt-record-v2",
    "calibration-run-ledger-v2",
    "validation-candidate-development-evidence-v2",
    "calibration-selection-v2",
    "p06-calibration-failure-v2",
    "p06-evidence-closure-v2",
    "p06-release-bundle-v3",
)

SCHEMA_IDENTITY_TABLE = {
    "candidate-evaluation-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "candidate-evaluation-v2.schema.json"
        ),
        "schema_version": "2.0.3",
        "artifact_kind": "p06_candidate_evaluation_v2",
        "file_sha256": (
            "5bae29dee2d847ef58a8ccfe749ab69ea0f693c96a81c7cea01061fcdfdf4ec7"
        ),
    },
    "calibration-attempt-record-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "calibration-attempt-record-v2.schema.json"
        ),
        "schema_version": "2.0.1",
        "artifact_kind": "p06_calibration_attempt_record_v2",
        "file_sha256": (
            "7cb1219425a7dee875fe0b04e3877a0dad85ccb7d1a3911c10f7fd1044d1376b"
        ),
    },
    "calibration-run-ledger-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "calibration-run-ledger-v2.schema.json"
        ),
        "schema_version": "2.0.2",
        "artifact_kind": "p06_calibration_run_ledger_v2",
        "file_sha256": (
            "3b1a576c1550a3b83be27550e5494182e76a1ff9daa1e10f2e651da36d618cc8"
        ),
    },
    "validation-candidate-development-evidence-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "validation-candidate-development-evidence-v2.schema.json"
        ),
        "schema_version": "2.0.1",
        "artifact_kind": (
            "p06_validation_candidate_development_evidence_v2"
        ),
        "file_sha256": (
            "8ba2c914ba2aa1619a6c6cc7e43f823102c79468b099778447e5e5c9d1981f3f"
        ),
    },
    "calibration-selection-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "calibration-selection-v2.schema.json"
        ),
        "schema_version": "2.0.2",
        "artifact_kind": "p06_calibration_selection_v2",
        "file_sha256": (
            "76dc8a720356a85d2bd2f56d423de3581bff96d2e1f4202ec835a31fef7dadff"
        ),
    },
    "p06-calibration-failure-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "p06-calibration-failure-v2.schema.json"
        ),
        "schema_version": "2.0.1",
        "artifact_kind": "p06_calibration_failure_v2",
        "file_sha256": (
            "070c4c38464a684effd14ca5747da11ac4ce71ef13ce583fe003d45f6a903cd6"
        ),
    },
    "p06-evidence-closure-v2": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "p06-evidence-closure-v2.schema.json"
        ),
        "schema_version": "2.0.1",
        "artifact_kind": "p06_evidence_closure_v2",
        "file_sha256": (
            "f8f29aa6c46f9ca89bfcfe509e6a14b95102445810e1d0c13ecc0cd97eab3611"
        ),
    },
    "p06-release-bundle-v3": {
        "$id": (
            "https://mirmir.local/validation/calibration-v2/"
            "p06-release-bundle-v3.schema.json"
        ),
        "schema_version": "3.0.1",
        "artifact_kind": "p06_release_bundle_v3",
        "file_sha256": (
            "1ea78e6750fbf062c41aa9bdc101d1ed44a9afca6d4987cc72d6ffebf86c8452"
        ),
    },
}

AUTHORITY_BINDINGS = {
    "baseline_ablation_budget_v2": {
        "file_sha256": "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8",
        "schema_file_sha256": "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b",
        "self_sha256": "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be",
    },
    "calibration_plan_v2": {
        "file_sha256": "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef",
        "schema_file_sha256": "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09",
        "self_sha256": "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f",
    },
    "candidate_evidence_policy_v2": {
        "file_sha256": "d6df835467485f59b253e12d8e80cb8c8fa21dd308566ab3634495ccc8604433",
        "schema_file_sha256": "581a3bb6ba0ec3ea288076685124a9e7fd332aa883ee2165f18a27a4fb1c249e",
        "self_sha256": "70860c19f36efe41401e16381c80d6102b37f683056b2e3210a67e9d0b66dc75",
    },
    "compiler_contract_v2": {
        "file_sha256": "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a",
        "schema_file_sha256": "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897",
        "self_sha256": "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237",
    },
    "shared_bank_configuration_identity_v2": {
        "file_sha256": "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de",
        "schema_file_sha256": "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c",
        "self_sha256": "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37",
    },
}

AUTHORITY_INPUT_BINDINGS = [
    {
        "id": "baseline_ablation_budget_v2",
        "path": (
            "validation/calibration_v2/contracts/"
            "baseline-ablation-budget-v2.json"
        ),
        "sha256": AUTHORITY_BINDINGS["baseline_ablation_budget_v2"][
            "file_sha256"
        ],
        "size_bytes": 8475,
    },
    {
        "id": "calibration_plan_v2",
        "path": "validation/calibration_v2/contracts/calibration-plan-v2.json",
        "sha256": AUTHORITY_BINDINGS["calibration_plan_v2"]["file_sha256"],
        "size_bytes": 21234,
    },
    {
        "id": "candidate_evidence_policy_v2",
        "path": (
            "validation/calibration_v2/contracts/"
            "candidate-evidence-policy-v2.json"
        ),
        "sha256": AUTHORITY_BINDINGS["candidate_evidence_policy_v2"][
            "file_sha256"
        ],
        "size_bytes": 23800,
    },
    {
        "id": "compiler_contract_v2",
        "path": "validation/calibration_v2/contracts/compiler-contract-v2.json",
        "sha256": AUTHORITY_BINDINGS["compiler_contract_v2"]["file_sha256"],
        "size_bytes": 26462,
    },
    {
        "id": "shared_bank_configuration_identity_v2",
        "path": (
            "validation/calibration_v2/contracts/"
            "shared-bank-configuration-identity-v2.json"
        ),
        "sha256": AUTHORITY_BINDINGS[
            "shared_bank_configuration_identity_v2"
        ]["file_sha256"],
        "size_bytes": 13164,
    },
]

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

IDENTITY_SET_CANONICALIZATION = (
    "ascending lowercase SHA-256 values serialized as canonical compact UTF-8 "
    "JSON array without trailing newline"
)


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _canonical_sha(value: object) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _evidence(path: str, label: str | None = None) -> dict[str, object]:
    return {
        "path": path,
        "sha256": _sha(label or path),
        "size_bytes": 1,
    }


def _file(identifier: str, path: str | None = None) -> dict[str, object]:
    actual_path = path or f"evidence/{identifier}.json"
    return {
        "id": identifier,
        **_evidence(actual_path, identifier),
    }


def _control(identifier: str) -> dict[str, object]:
    identities = {
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
            "2c978578e6b7e27c285fe827c9519d4262a79da7040988021158a171ab82c1b8",
        ),
    }
    artifact_kind, schema_sha256 = identities[identifier]
    file_sha256 = _sha(f"control-{identifier}")
    return {
        "id": identifier,
        "artifact_kind": artifact_kind,
        "schema_sha256": schema_sha256,
        "path": f"controls/{file_sha256}.json",
        "sha256": file_sha256,
        "size_bytes": 1,
    }


def _control_authorization_bundle(label: str) -> dict[str, object]:
    digest = _sha(f"control-authorization-{label}")
    return {
        "artifact_kind": "p06_control_authorization_bundle_v2",
        "schema_sha256": (
            "9b6aa34dd923752fa12f4938a948a43665953b34fae23485e99a249ad5ff29a6"
        ),
        "path": f"controls/{digest}.json",
        "sha256": digest,
        "size_bytes": 1,
    }


def _applicable(path: str, label: str) -> dict[str, object]:
    return {
        "applicable": True,
        "binding": _evidence(path, label),
    }


def _access(
    *,
    development: bool,
    validation: bool,
) -> dict[str, bool]:
    return {
        "development_accessed": development,
        "validation_accessed": validation,
        "holdout_accessed": False,
        "release_locks_written": False,
    }


class P06V2EvidenceSiblingSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.paths = {
            name: SCHEMA_ROOT / f"{name}.schema.json"
            for name in SCHEMA_NAMES
        }
        cls.schemas = {
            name: json.loads(path.read_bytes())
            for name, path in cls.paths.items()
        }
        cls.validators = {
            name: Draft202012Validator(schema)
            for name, schema in cls.schemas.items()
        }
        for schema in cls.schemas.values():
            Draft202012Validator.check_schema(schema)

        cls.candidate_sha = _sha("candidate")
        cls.shared_bank_sha = _sha("shared-bank")
        cls.evaluation_sha = _sha("candidate-evaluation")
        cls.candidate_evaluation = cls._candidate_evaluation()
        cls.attempt = cls._attempt()
        cls.run_ledger = cls._run_ledger()
        cls.admission = cls._admission()
        cls.selection = cls._selection()
        cls.failure = cls._failure()
        cls.closure = cls._closure()
        cls.release = cls._release()
        cls.documents = {
            "candidate-evaluation-v2": cls.candidate_evaluation,
            "calibration-attempt-record-v2": cls.attempt,
            "calibration-run-ledger-v2": cls.run_ledger,
            "validation-candidate-development-evidence-v2": cls.admission,
            "calibration-selection-v2": cls.selection,
            "p06-calibration-failure-v2": cls.failure,
            "p06-evidence-closure-v2": cls.closure,
            "p06-release-bundle-v3": cls.release,
        }

    @classmethod
    def _candidate_evaluation(cls) -> dict[str, object]:
        schema = cls.schemas["candidate-evaluation-v2"]
        items = []
        for ordinal, item_schema in enumerate(
            schema["properties"]["physical_candidate_items"]["prefixItems"]
        ):
            name = item_schema["prefixItems"][0]["const"]
            if (
                name.endswith("_policy_id")
                or name.endswith("_coordinate_policy")
                or name == "boundary_mode"
            ):
                value: object = f"value-{ordinal}"
            else:
                value = ordinal
            items.append([name, value])
        evaluation = {
            "feasible": True,
            "failure_reasons": [],
            "objective": {
                "mean_y_psnr_delta_vs_fixed_db": 1,
                "mean_y_psnr_delta_vs_non_ash_db": 1,
                "mean_ms_ssim_delta_vs_conventional": 1,
                "maximum_ringing_excursion": 1,
                "maximum_alias_ratio": 1,
                "estimated_dispatch_cost": 1,
            },
        }
        cls.objective_sha = _canonical_sha(evaluation)
        return {
            "schema_version": "2.0.3",
            "artifact_kind": "p06_candidate_evaluation_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "candidate_id": "candidate-0",
            "split": "development",
            "candidate_vector_sha256": cls.candidate_sha,
            "adapter_configuration_sha256": _sha(
                "candidate-adapter-configuration"
            ),
            "physical_candidate_items": items,
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "degradation_policy_sha256": _sha("degradation-policy"),
            "source_profile_matrix_sha256": _sha("development-matrix"),
            "evaluation_cache_identity": {
                "split": "development",
                "candidate_vector_sha256": cls.candidate_sha,
                "calibration_plan_v2_file_sha256": (
                    AUTHORITY_BINDINGS["calibration_plan_v2"]["file_sha256"]
                ),
            },
            "source_evidence_sha256_bindings": [
                _file("G04", "gates/g04.json"),
                _file("G05", "gates/g05.json"),
                _file("G06", "gates/g06.json"),
            ],
            "compiler_input": {
                "file_sha256": _sha("compiler-input-file"),
                "payload_sha256": _sha("compiler-input-payload"),
            },
            "route_lut_bindings": [
                {
                    "route": "direct-2x",
                    "whole_file_sha256": _sha("direct-2x-file"),
                    "payload_sha256": _sha("direct-2x-payload"),
                },
                {
                    "route": "direct-3over2",
                    "whole_file_sha256": _sha("direct-3over2-file"),
                    "payload_sha256": _sha("direct-3over2-payload"),
                },
            ],
            "runtime_evidence_sha256": _sha("runtime"),
            "control_authorization_bundle": (
                _control_authorization_bundle("development")
            ),
            "evaluation": evaluation,
            "evaluation_semantic_sha256": cls.objective_sha,
            "checks": [
                {
                    "check_id": "compiler-oracle",
                    "status": "pass",
                    "evidence_sha256": _sha("compiler-oracle"),
                }
            ],
            "evaluation_status": "feasible",
            "evidence_sha256": _sha("complete-candidate-evidence"),
            "data_access": _access(development=True, validation=False),
            "artifact_sha256": cls.evaluation_sha,
        }

    @classmethod
    def _attempt(cls) -> dict[str, object]:
        physical_candidate_items = deepcopy(
            cls.candidate_evaluation["physical_candidate_items"]
        )
        return {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_calibration_attempt_record_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "record_hash_domain": (
                "mirmir-p06-calibration-scheduler-v2-semantic-attempt-v1"
            ),
            "sequence": 0,
            "previous_record_sha256": "0" * 64,
            "record_sha256": _sha("attempt-record"),
            "split": "development",
            "phase": "structural_scan",
            "sweep": 1,
            "coordinate": "spatial_structural_vector_ordinal",
            "value": 0,
            "physical_candidate_items": physical_candidate_items,
            "candidate_vector_sha256": cls.candidate_sha,
            "cache_identity": {
                "split": "development",
                "candidate_vector_sha256": cls.candidate_sha,
                "calibration_plan_file_sha256": (
                    AUTHORITY_BINDINGS["calibration_plan_v2"]["file_sha256"]
                ),
            },
            "status": "feasible",
            "cache_hit": False,
            "failure_reasons": [],
            "canonical_failure_reasons": [],
            "evaluation": deepcopy(cls.candidate_evaluation["evaluation"]),
            "evaluation_semantic_sha256": cls.objective_sha,
            "evaluation_artifact": _evidence(
                f"evaluations/{cls.evaluation_sha}.json",
                "candidate-evaluation",
            ),
            "failure_artifact": None,
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "data_access": _access(development=True, validation=False),
        }

    @classmethod
    def _run_ledger(cls) -> dict[str, object]:
        return {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_run_ledger_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "input_bundle_sha256": _sha("input-bundle"),
            "input_bindings": deepcopy(AUTHORITY_INPUT_BINDINGS),
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
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
            "development_terminal_candidate_vector_sha256": cls.candidate_sha,
            "validation_admission": _evidence(
                "validation-candidate-development-evidence-v2.json"
            ),
            "candidate_evaluations": [
                {
                    "split": "development",
                    "candidate_vector_sha256": cls.candidate_sha,
                    "binding": _evidence(
                        f"evaluations/{cls.evaluation_sha}.json",
                        "candidate-evaluation",
                    ),
                },
                {
                    "split": "validation",
                    "candidate_vector_sha256": cls.candidate_sha,
                    "binding": _evidence(
                        f"evaluations/{_sha('validation-evaluation')}.json",
                        "validation-evaluation",
                    ),
                }
            ],
            "candidate_evaluation_count": 2,
            "candidate_evaluation_identity_set_sha256": _sha(
                "candidate-evaluation-set"
            ),
            "candidate_failures": [],
            "candidate_failure_count": 0,
            "candidate_failure_identity_set_sha256": _sha(
                "candidate-failure-set"
            ),
            "data_separation": {
                "all_development_attempts_precede_validation": True,
                "development_validation_cache_namespaces_distinct": True,
                "validation_opened_after_development_freeze": True,
                "holdout_accessed": False,
            },
            "run_status": "selection_ready",
            "failure": None,
            "artifact_manifest": _evidence("artifact-manifest-v2.json"),
            "data_access": _access(development=True, validation=True),
            "artifact_sha256": _sha("run-ledger"),
        }

    @classmethod
    def _admission(cls) -> dict[str, object]:
        identity_set_sha = _sha("candidate-identity-set")
        all_candidate_sha256_values = [cls.candidate_sha] + [
            _sha(f"validation-neighbor-{ordinal}")
            for ordinal in range(1, 374)
        ]
        return {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_validation_candidate_development_evidence_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "plan_id": "mirmir-p06-spatial-calibration-v2",
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "development_trace": {
                "attempt_count": 822,
                "last_record_sha256": _sha("attempt-record"),
                "attempt_ledger": _evidence("attempts-v2.ndjson"),
            },
            "development_terminal_candidate_vector_sha256": cls.candidate_sha,
            "development_terminal_evaluation": _evidence(
                f"evaluations/{cls.evaluation_sha}.json",
                "candidate-evaluation",
            ),
            "neighbor_generation": deepcopy(NEIGHBOR_GENERATION),
            "candidate_count_before_constraint_filtering": 374,
            "candidates_before_constraint_filtering_sha256_values": (
                all_candidate_sha256_values
            ),
            "candidate_set_sha256": _sha("all-candidate-set"),
            "constraint_valid_candidate_count": 1,
            "constraint_valid_candidate_sha256_values": [cls.candidate_sha],
            "constraint_valid_candidate_set_sha256": identity_set_sha,
            "development_evidence_count": 1,
            "development_evidence": [
                {
                    "candidate_vector_sha256": cls.candidate_sha,
                    "feasible": True,
                    "evaluation_semantic_sha256": cls.objective_sha,
                    "evaluation": _evidence(
                        f"evaluations/{cls.evaluation_sha}.json",
                        "candidate-evaluation",
                    ),
                }
            ],
            "development_evidence_candidate_set_sha256": identity_set_sha,
            "admitted_candidate_count": 1,
            "admitted_candidate_sha256_values": [cls.candidate_sha],
            "admitted_candidate_set_sha256": identity_set_sha,
            "identity_set_canonicalization": IDENTITY_SET_CANONICALIZATION,
            "validation_accessed_while_building": False,
            "data_access": _access(development=True, validation=False),
            "artifact_sha256": _sha("validation-admission"),
        }

    @classmethod
    def _selection(cls) -> dict[str, object]:
        validation_evaluation_sha = _sha("validation-evaluation")
        validation_objective_sha = _sha("validation-objective")
        identity_set_sha = _sha("candidate-identity-set")
        evaluation_binding = _evidence(
            f"evaluations/{validation_evaluation_sha}.json",
            "validation-evaluation",
        )
        return {
            "schema_version": "2.0.2",
            "artifact_kind": "p06_calibration_selection_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "input_bundle_sha256": _sha("input-bundle"),
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "calibration_run_ledger": _evidence("calibration-run-ledger-v2.json"),
            "validation_candidate_development_evidence": _evidence(
                "validation-candidate-development-evidence-v2.json"
            ),
            "development_terminal_candidate_vector_sha256": cls.candidate_sha,
            "validation_candidate_vector_sha256_values": [cls.candidate_sha],
            "validation_candidate_count": 1,
            "validation_candidate_identity_set_sha256": identity_set_sha,
            "validation_outcomes": [
                {
                    "candidate_vector_sha256": cls.candidate_sha,
                    "outcome_kind": "scored",
                    "evaluation": evaluation_binding,
                    "evaluation_semantic_sha256": validation_objective_sha,
                }
            ],
            "validation_outcome_count": 1,
            "validation_outcome_identity_set_sha256": identity_set_sha,
            "pareto_dimensions": deepcopy(PARETO_DIMENSIONS),
            "pareto_frontier_candidate_vector_sha256_values": [
                cls.candidate_sha
            ],
            "selection_tie_break": (
                "canonical serialized 48-field candidate bytes in ascending "
                "lexicographic order"
            ),
            "selected": {
                "candidate_vector_sha256": cls.candidate_sha,
                "evaluation": evaluation_binding,
                "evaluation_semantic_sha256": validation_objective_sha,
            },
            "selected_control_authorization_bundle": (
                _control_authorization_bundle("validation")
            ),
            "dispatch_budget": {
                "maximum_operator_evaluations": 2,
                "loaded_lut_instance_count_per_route": 1,
                "per_frame_lut_load_count": 0,
                "runtime_leaf_tree_generations": 0,
                "runtime_path_generations": 0,
            },
            "selection_status": "selected",
            "data_access": _access(development=True, validation=True),
            "artifact_sha256": _sha("selection"),
        }

    @classmethod
    def _failure(cls) -> dict[str, object]:
        not_applicable = {"applicable": False, "binding": None}
        return {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_calibration_failure_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "shared_bank_configuration_sha256": None,
            "candidate_vector_sha256": None,
            "failure_stage": "authority_authentication",
            "failure_type": "evidence_integrity",
            "failure_code": "stale.authority",
            "failure_message": "authenticated authority changed",
            "failure_reasons": [],
            "failure_bindings": {
                "attempt_ledger": deepcopy(not_applicable),
                "trace_evidence": _applicable(
                    "failures/authority-trace.json",
                    "authority-trace",
                ),
                "artifact_manifest": _applicable(
                    "artifact-manifest-v2.json",
                    "failure-artifact-manifest",
                ),
                "cleanup_evidence": _applicable(
                    "failures/cleanup.json",
                    "cleanup",
                ),
                "recovery_evidence": deepcopy(not_applicable),
            },
            "cleanup": {
                "invoked": True,
                "idempotent": True,
                "completed": True,
                "unrelated_files_deleted": False,
            },
            "recovery": {
                "resume_allowed": False,
                "recovery_stage": "none",
                "resume_source": deepcopy(not_applicable),
            },
            "status": "failed_preserved",
            "data_access": _access(development=True, validation=False),
            "artifact_sha256": _sha("failure"),
        }

    @classmethod
    def _closure(cls) -> dict[str, object]:
        return {
            "schema_version": "2.0.1",
            "artifact_kind": "p06_evidence_closure_v2",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "run_id": "run-v2",
            "configuration_id": "configuration-v2",
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "input_bundle_sha256": _sha("input-bundle"),
            "corpus_lock_bundle_sha256": _sha("corpus-lock"),
            "calibration_run_ledger": _evidence("calibration-run-ledger-v2.json"),
            "calibration_selection": _evidence("calibration-selection-v2.json"),
            "selected_evaluation": _evidence(
                f"evaluations/{_sha('validation-evaluation')}.json",
                "validation-evaluation",
            ),
            "gate_evidence": [
                {
                    "gate_id": gate,
                    "binding": _evidence(f"gates/{gate.lower()}.json"),
                }
                for gate in ("G04", "G05", "G06")
            ],
            "component_closures": [
                {
                    "component_id": "quality-calibration-harness",
                    "owning_gate": "G06",
                    "implementation_scope": {
                        "kind": "production",
                        "production_caller": "run_p06_production_calibration",
                    },
                    "focused_and_dependent_tests": [_file("tests")],
                    "telemetry": {
                        "applicable": True,
                        "bindings": [_file("telemetry")],
                    },
                    "fault_injection_evidence": [_file("fault-injection")],
                    "artifact_bindings": [_file("implementation")],
                    "local_green_commit": "a" * 40,
                    "all_six_closure_items_present": True,
                }
            ],
            "compiler_lut_configuration_evidence": [
                _file(f"release-input-{index}")
                for index in range(7)
            ],
            "preserved_failures": [],
            "artifact_manifest": _evidence("artifact-manifest-v2.json"),
            "holdout_accessed": False,
            "status": "closed_before_p07",
            "data_access": _access(development=True, validation=True),
            "artifact_sha256": _sha("evidence-closure"),
        }

    @classmethod
    def _release(cls) -> dict[str, object]:
        schema = cls.schemas["p06-release-bundle-v3"]
        artifacts = []
        for ordinal, item_schema in enumerate(
            schema["properties"]["artifacts"]["prefixItems"]
        ):
            refinements = item_schema["allOf"][1]["properties"]
            identifier = refinements["id"]["const"]
            path_rule = refinements["path"]
            if "const" in path_rule:
                path = path_rule["const"]
            else:
                path = f"evaluations/{_sha('selected-evaluation')}.json"
            artifacts.append(
                {
                    "id": identifier,
                    "path": path,
                    "sha256": _sha(f"release-artifact-{ordinal}"),
                    "size_bytes": 1,
                    "producer": "p06-release-lock",
                    "command": "run-p06-release-lock",
                    "platform": "macOS",
                    "gate_bindings": ["G06"],
                }
            )
        return {
            "schema_version": "3.0.1",
            "artifact_kind": "p06_release_bundle_v3",
            "bundle_id": "mirmir-p06-spatial-release-lock-v3",
            "status": "locked_before_p07",
            "configuration_id": "configuration-v2",
            "locked_utc": "2026-07-15T12:00:00Z",
            "authority_bindings": deepcopy(AUTHORITY_BINDINGS),
            "shared_bank_configuration_sha256": cls.shared_bank_sha,
            "input_bundle_sha256": _sha("input-bundle"),
            "corpus_lock_bundle_sha256": _sha("corpus-lock"),
            "release_fields_complete": True,
            "configuration_files_modified_after_lock": False,
            "holdout_accessed": False,
            "holdout_access_count": 0,
            "artifact_ids": deepcopy(
                schema["properties"]["artifact_ids"]["const"]
            ),
            "artifacts": artifacts,
            "filesystem_closure_rule": "all_entries_except_self_manifest_v1",
            "filesystem_closure": [
                {
                    "path": "calibration-selection-v2.json",
                    "entry_kind": "regular_file",
                    "sha256": _sha("filesystem-entry"),
                    "size_bytes": 1,
                    "executable_mode_bits": 0,
                }
            ],
            "authorized_execution_bindings_sha256": _sha(
                "authorized-execution-bindings"
            ),
            "p07_authorization_status": (
                "ready_for_single_locked_holdout_execution"
            ),
            "artifact_sha256": _sha("release-bundle-v3"),
        }

    def _assert_valid(self, schema_name: str, document: dict[str, object]) -> None:
        errors = sorted(
            self.validators[schema_name].iter_errors(document),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
        self.assertEqual(
            errors,
            [],
            "\n".join(
                f"{list(error.absolute_path)}: {error.message}"
                for error in errors
            ),
        )

    def _assert_invalid(
        self,
        schema_name: str,
        document: dict[str, object],
    ) -> None:
        self.assertTrue(
            list(self.validators[schema_name].iter_errors(document)),
            f"{schema_name} unexpectedly accepted invalid evidence",
        )

    def test_all_schemas_accept_boundary_fixtures(self) -> None:
        for schema_name, document in self.documents.items():
            with self.subTest(schema=schema_name):
                self._assert_valid(schema_name, document)

        typed_failure_attempt = deepcopy(self.attempt)
        typed_failure_attempt["cache_hit"] = False
        typed_failure_attempt["status"] = "evaluation_failure"
        typed_failure_attempt["failure_reasons"] = [
            "native evaluator failed"
        ]
        typed_failure_attempt["canonical_failure_reasons"] = []
        typed_failure_attempt["evaluation"] = None
        typed_failure_attempt["evaluation_semantic_sha256"] = None
        typed_failure_attempt["evaluation_artifact"] = None
        typed_failure_attempt["failure_artifact"] = _evidence(
            f"failures/{_sha('evaluation-failure')}.json",
            "evaluation-failure",
        )
        self._assert_valid(
            "calibration-attempt-record-v2",
            typed_failure_attempt,
        )

        constraint_failure_attempt = deepcopy(self.attempt)
        constraint_failure_attempt["status"] = "constraint_failure"
        constraint_failure_attempt["failure_reasons"] = [
            "candidate constraint failed"
        ]
        constraint_failure_attempt["canonical_failure_reasons"] = []
        constraint_failure_attempt["evaluation"] = None
        constraint_failure_attempt["evaluation_semantic_sha256"] = None
        constraint_failure_attempt["evaluation_artifact"] = None
        constraint_failure_attempt["failure_artifact"] = None
        self._assert_valid(
            "calibration-attempt-record-v2",
            constraint_failure_attempt,
        )

        cache_hit_attempt = deepcopy(self.attempt)
        cache_hit_attempt["cache_hit"] = True
        self._assert_valid(
            "calibration-attempt-record-v2",
            cache_hit_attempt,
        )

    def test_schemas_are_canonical_one_line_draft_2020_12(self) -> None:
        for schema_name, path in self.paths.items():
            with self.subTest(schema=schema_name):
                raw = path.read_bytes()
                parsed = json.loads(raw)
                expected = (
                    json.dumps(
                        parsed,
                        ensure_ascii=False,
                        separators=(",", ":"),
                        sort_keys=True,
                    ).encode("utf-8")
                    + b"\n"
                )
                self.assertEqual(raw, expected)
                self.assertEqual(
                    parsed["$schema"],
                    "https://json-schema.org/draft/2020-12/schema",
                )
                self.assertFalse(parsed["additionalProperties"])

    def test_frozen_schema_identity_table(self) -> None:
        self.assertEqual(set(SCHEMA_IDENTITY_TABLE), set(SCHEMA_NAMES))
        for schema_name, expected in SCHEMA_IDENTITY_TABLE.items():
            with self.subTest(schema=schema_name):
                schema = self.schemas[schema_name]
                actual = {
                    "$id": schema["$id"],
                    "schema_version": schema["properties"][
                        "schema_version"
                    ]["const"],
                    "artifact_kind": schema["properties"]["artifact_kind"][
                        "const"
                    ],
                    "file_sha256": hashlib.sha256(
                        self.paths[schema_name].read_bytes()
                    ).hexdigest(),
                }
                self.assertEqual(actual, expected)

    def test_scheduler_and_policy_constants_match_structural_schema(self) -> None:
        attempt_schema = self.schemas["calibration-attempt-record-v2"]
        self.assertEqual(
            attempt_schema["properties"]["sequence"]["maximum"],
            scheduler.MAXIMUM_DEVELOPMENT_ATTEMPTS - 1,
        )
        self.assertEqual(
            set(attempt_schema["properties"]["status"]["enum"]),
            {
                scheduler.ATTEMPT_STATUS_CONSTRAINT_FAILURE,
                scheduler.ATTEMPT_STATUS_EVALUATION_FAILURE,
                scheduler.ATTEMPT_STATUS_FEASIBLE,
                scheduler.ATTEMPT_STATUS_INFEASIBLE,
            },
        )
        self.assertEqual(
            attempt_schema["properties"]["split"]["const"],
            scheduler.DEVELOPMENT_SPLIT,
        )
        self.assertEqual(
            attempt_schema["properties"]["phase"]["enum"],
            ["structural_scan", "scalar_scan"],
        )
        self.assertEqual(
            attempt_schema["properties"]["sweep"]["maximum"],
            scheduler.MAXIMUM_SWEEPS,
        )

        policy = json.loads(
            (
                ROOT
                / "validation/calibration_v2/contracts/"
                "candidate-evidence-policy-v2.json"
            ).read_bytes()
        )
        expected_names = policy["candidate_identity"][
            "physical_candidate_order"
        ]
        for schema_name in (
            "candidate-evaluation-v2",
            "calibration-attempt-record-v2",
        ):
            prefix_items = self.schemas[schema_name]["properties"][
                "physical_candidate_items"
            ]["prefixItems"]
            self.assertEqual(
                [item["prefixItems"][0]["const"] for item in prefix_items],
                expected_names,
            )

        development_rank_fields = {
            "mean_y_psnr_delta_vs_fixed_db",
            "mean_y_psnr_delta_vs_non_ash_db",
            "mean_ms_ssim_delta_vs_conventional",
            "maximum_ringing_excursion",
            "maximum_alias_ratio",
            "estimated_dispatch_cost",
        }
        validation_rank_fields = {
            "y_vs_fixed_ci_low",
            "y_vs_non_ash_ci_low",
            "y_vs_conventional_ci_low",
            "mean_ms_ssim_delta_vs_conventional",
            "maximum_ringing_excursion",
            "maximum_alias_ratio",
            "estimated_dispatch_cost",
        }
        candidate_schema = self.schemas["candidate-evaluation-v2"]
        self.assertEqual(
            set(
                candidate_schema["$defs"]["developmentRankObjective"][
                    "required"
                ]
            ),
            development_rank_fields,
        )
        self.assertEqual(
            set(
                candidate_schema["$defs"]["validationRankObjective"][
                    "required"
                ]
            ),
            validation_rank_fields,
        )

    def test_exact_authority_triples_and_dynamic_shared_bank_are_required(self) -> None:
        for schema_name, document in self.documents.items():
            with self.subTest(schema=schema_name):
                self.assertEqual(
                    self.schemas[schema_name]["$defs"]["authorityBindings"][
                        "const"
                    ],
                    AUTHORITY_BINDINGS,
                )
                tampered = deepcopy(document)
                tampered["authority_bindings"][
                    "shared_bank_configuration_identity_v2"
                ]["file_sha256"] = _sha("tampered-authority")
                self._assert_invalid(schema_name, tampered)

                missing_dynamic = deepcopy(document)
                del missing_dynamic["shared_bank_configuration_sha256"]
                self._assert_invalid(schema_name, missing_dynamic)

                compiler_tampered = deepcopy(document)
                compiler_tampered["authority_bindings"][
                    "compiler_contract_v2"
                ]["file_sha256"] = _sha("tampered-compiler-authority")
                self._assert_invalid(schema_name, compiler_tampered)

                four_authorities = deepcopy(document)
                del four_authorities["authority_bindings"][
                    "compiler_contract_v2"
                ]
                self._assert_invalid(schema_name, four_authorities)

                old_version = deepcopy(document)
                old_version["schema_version"] = (
                    "3.0.0"
                    if schema_name == "p06-release-bundle-v3"
                    else "2.0.0"
                )
                self._assert_invalid(schema_name, old_version)

        run_schema = self.schemas["calibration-run-ledger-v2"]
        self.assertEqual(
            run_schema["properties"]["input_bindings"]["const"],
            AUTHORITY_INPUT_BINDINGS,
        )
        four_inputs = deepcopy(self.run_ledger)
        four_inputs["input_bindings"] = [
            row
            for row in four_inputs["input_bindings"]
            if row["id"] != "compiler_contract_v2"
        ]
        self._assert_invalid("calibration-run-ledger-v2", four_inputs)

        reordered_inputs = deepcopy(self.run_ledger)
        reordered_inputs["input_bindings"][2], reordered_inputs[
            "input_bindings"
        ][3] = (
            reordered_inputs["input_bindings"][3],
            reordered_inputs["input_bindings"][2],
        )
        self._assert_invalid("calibration-run-ledger-v2", reordered_inputs)

    def test_candidate_evaluation_requires_ordered_48_pairs_and_rank_semantics(
        self,
    ) -> None:
        self.assertEqual(
            len(self.candidate_evaluation["physical_candidate_items"]),
            48,
        )

        missing_pair = deepcopy(self.candidate_evaluation)
        missing_pair["physical_candidate_items"].pop()
        self._assert_invalid("candidate-evaluation-v2", missing_pair)

        swapped = deepcopy(self.candidate_evaluation)
        swapped["physical_candidate_items"][0], swapped[
            "physical_candidate_items"
        ][1] = (
            swapped["physical_candidate_items"][1],
            swapped["physical_candidate_items"][0],
        )
        self._assert_invalid("candidate-evaluation-v2", swapped)

        wrong_split_objective = deepcopy(self.candidate_evaluation)
        wrong_split_objective["evaluation"] = {
            "feasible": True,
            "failure_reasons": [],
            "objective": {
                "y_vs_fixed_ci_low": 1,
                "y_vs_non_ash_ci_low": 1,
                "y_vs_conventional_ci_low": 1,
                "mean_ms_ssim_delta_vs_conventional": 1,
                "maximum_ringing_excursion": 1,
                "maximum_alias_ratio": 1,
                "estimated_dispatch_cost": 1,
            },
        }
        self._assert_invalid("candidate-evaluation-v2", wrong_split_objective)

        infeasible_without_reason = deepcopy(self.candidate_evaluation)
        infeasible_without_reason["evaluation_status"] = "infeasible"
        infeasible_without_reason["evaluation"]["feasible"] = False
        self._assert_invalid(
            "candidate-evaluation-v2",
            infeasible_without_reason,
        )

        bool_numeric_alias = deepcopy(self.candidate_evaluation)
        bool_numeric_alias["evaluation"]["objective"][
            "estimated_dispatch_cost"
        ] = True
        self._assert_invalid("candidate-evaluation-v2", bool_numeric_alias)

        invented_composite_cache_hash = deepcopy(self.candidate_evaluation)
        invented_composite_cache_hash["evaluation_cache_identity"][
            "persistent_composite_sha256"
        ] = _sha("undefined-framing")
        self._assert_invalid(
            "candidate-evaluation-v2",
            invented_composite_cache_hash,
        )

        missing_gate = deepcopy(self.candidate_evaluation)
        missing_gate["source_evidence_sha256_bindings"].pop()
        self._assert_invalid("candidate-evaluation-v2", missing_gate)

        reordered_gates = deepcopy(self.candidate_evaluation)
        reordered_gates["source_evidence_sha256_bindings"].reverse()
        self._assert_invalid("candidate-evaluation-v2", reordered_gates)

        feasible_with_failed_check = deepcopy(self.candidate_evaluation)
        feasible_with_failed_check["checks"][0]["status"] = "fail"
        self._assert_invalid(
            "candidate-evaluation-v2",
            feasible_with_failed_check,
        )

        infeasible_without_failed_check = deepcopy(self.candidate_evaluation)
        infeasible_without_failed_check["evaluation_status"] = "infeasible"
        infeasible_without_failed_check["evaluation"]["feasible"] = False
        infeasible_without_failed_check["evaluation"]["failure_reasons"] = [
            "route quality check failed"
        ]
        self._assert_invalid(
            "candidate-evaluation-v2",
            infeasible_without_failed_check,
        )

        infeasible_with_failed_check = deepcopy(
            infeasible_without_failed_check
        )
        infeasible_with_failed_check["checks"][0]["status"] = "fail"
        self._assert_valid(
            "candidate-evaluation-v2",
            infeasible_with_failed_check,
        )

        repeated_check = deepcopy(self.candidate_evaluation)
        repeated_check["checks"].append(deepcopy(repeated_check["checks"][0]))
        self._assert_invalid("candidate-evaluation-v2", repeated_check)

        check_id_schema = self.schemas["candidate-evaluation-v2"][
            "properties"
        ]["checks"]["items"]["properties"]["check_id"]
        self.assertEqual(check_id_schema, {"minLength": 1, "type": "string"})

    def test_attempts_require_content_addressed_typed_mutually_exclusive_outcomes(
        self,
    ) -> None:
        self.assertEqual(
            self.attempt["evaluation"],
            self.candidate_evaluation["evaluation"],
        )
        self.assertEqual(
            self.attempt["evaluation_semantic_sha256"],
            _canonical_sha(self.candidate_evaluation["evaluation"]),
        )

        cache_hit_failure = deepcopy(self.attempt)
        cache_hit_failure["cache_hit"] = True
        cache_hit_failure["status"] = "evaluation_failure"
        cache_hit_failure["failure_reasons"] = ["failed"]
        cache_hit_failure["evaluation"] = None
        cache_hit_failure["evaluation_semantic_sha256"] = None
        cache_hit_failure["evaluation_artifact"] = None
        cache_hit_failure["failure_artifact"] = _evidence(
            f"failures/{_sha('failed')}.json",
            "failed",
        )
        self._assert_invalid(
            "calibration-attempt-record-v2",
            cache_hit_failure,
        )

        unaddressed_evaluation = deepcopy(self.attempt)
        unaddressed_evaluation["evaluation_artifact"]["path"] = (
            "evaluations/current.json"
        )
        self._assert_invalid(
            "calibration-attempt-record-v2",
            unaddressed_evaluation,
        )

        zero_artifact_sha = deepcopy(self.attempt)
        zero_artifact_sha["evaluation_artifact"]["sha256"] = "0" * 64
        self._assert_invalid(
            "calibration-attempt-record-v2",
            zero_artifact_sha,
        )

        broken_genesis = deepcopy(self.attempt)
        broken_genesis["previous_record_sha256"] = _sha("not-genesis")
        self._assert_invalid("calibration-attempt-record-v2", broken_genesis)

        empty_failure_reasons = deepcopy(self.attempt)
        empty_failure_reasons["status"] = "constraint_failure"
        empty_failure_reasons["failure_reasons"] = []
        empty_failure_reasons["canonical_failure_reasons"] = []
        empty_failure_reasons["evaluation"] = None
        empty_failure_reasons["evaluation_semantic_sha256"] = None
        empty_failure_reasons["evaluation_artifact"] = None
        empty_failure_reasons["failure_artifact"] = None
        self._assert_invalid(
            "calibration-attempt-record-v2",
            empty_failure_reasons,
        )

    def test_admission_selection_and_run_ledger_bind_sets_counts_and_outcomes(
        self,
    ) -> None:
        zero_admitted = deepcopy(self.admission)
        zero_admitted["admitted_candidate_count"] = 0
        self._assert_invalid(
            "validation-candidate-development-evidence-v2",
            zero_admitted,
        )

        duplicate_identity = deepcopy(self.admission)
        duplicate_identity["admitted_candidate_sha256_values"] = [
            self.candidate_sha,
            self.candidate_sha,
        ]
        self._assert_invalid(
            "validation-candidate-development-evidence-v2",
            duplicate_identity,
        )

        incomplete_neighborhood = deepcopy(self.admission)
        incomplete_neighborhood[
            "candidates_before_constraint_filtering_sha256_values"
        ].pop()
        self._assert_invalid(
            "validation-candidate-development-evidence-v2",
            incomplete_neighborhood,
        )

        too_many_development_attempts = deepcopy(self.run_ledger)
        too_many_development_attempts["development_attempt_count"] = 3289
        self._assert_invalid(
            "calibration-run-ledger-v2",
            too_many_development_attempts,
        )

        wrong_control_schema = deepcopy(self.selection)
        wrong_control_schema["selected_control_authorization_bundle"][
            "schema_sha256"
        ] = _sha("wrong-control-schema")
        self._assert_invalid(
            "calibration-selection-v2",
            wrong_control_schema,
        )

        for schema_name, source in (
            ("calibration-run-ledger-v2", self.run_ledger),
            ("calibration-selection-v2", self.selection),
        ):
            legacy_controls = deepcopy(source)
            legacy_controls["control_selection_artifacts"] = [
                _control("best_fixed"),
                _control("conventional"),
                _control("non_ash_selector"),
            ]
            self._assert_invalid(schema_name, legacy_controls)

        no_validation_outcome = deepcopy(self.run_ledger)
        no_validation_outcome["candidate_evaluations"] = [
            no_validation_outcome["candidate_evaluations"][0]
        ]
        no_validation_outcome["candidate_evaluation_count"] = 1
        self._assert_invalid(
            "calibration-run-ledger-v2",
            no_validation_outcome,
        )

        all_validation_evaluators_failed = deepcopy(no_validation_outcome)
        all_validation_evaluators_failed["candidate_failures"] = [
            {
                "split": "validation",
                "candidate_vector_sha256": self.candidate_sha,
                "binding": _evidence(
                    f"failures/{_sha('validation-evaluation-failure')}.json",
                    "validation-evaluation-failure",
                ),
            }
        ]
        all_validation_evaluators_failed["candidate_failure_count"] = 1
        self._assert_valid(
            "calibration-run-ledger-v2",
            all_validation_evaluators_failed,
        )

        failed_development_run = deepcopy(self.run_ledger)
        failed_development_run["run_status"] = "failed"
        failed_development_run["data_access"]["validation_accessed"] = False
        failed_development_run["data_separation"][
            "validation_opened_after_development_freeze"
        ] = False
        failed_development_run["development_status"] = "failed_maximum_sweeps"
        failed_development_run["failure"] = _evidence(
            f"failures/{_sha('terminal-development-failure')}.json",
            "terminal-development-failure",
        )
        failed_development_run["validation_admission"] = None
        failed_development_run["validation_attempt_count"] = 0
        failed_development_run["candidate_evaluations"] = [
            failed_development_run["candidate_evaluations"][0]
        ]
        failed_development_run["candidate_evaluation_count"] = 1
        self._assert_valid(
            "calibration-run-ledger-v2",
            failed_development_run,
        )

        failed_with_validation_evaluation = deepcopy(failed_development_run)
        failed_with_validation_evaluation["candidate_evaluations"].append(
            deepcopy(self.run_ledger["candidate_evaluations"][1])
        )
        failed_with_validation_evaluation["candidate_evaluation_count"] = 2
        self._assert_invalid(
            "calibration-run-ledger-v2",
            failed_with_validation_evaluation,
        )

        failed_with_validation_failure = deepcopy(failed_development_run)
        failed_with_validation_failure["candidate_failures"] = deepcopy(
            all_validation_evaluators_failed["candidate_failures"]
        )
        failed_with_validation_failure["candidate_failure_count"] = 1
        self._assert_invalid(
            "calibration-run-ledger-v2",
            failed_with_validation_failure,
        )

        missing_winner = deepcopy(self.selection)
        missing_winner["selected"] = None
        self._assert_invalid("calibration-selection-v2", missing_winner)

        opaque_selected_digest = deepcopy(self.selection)
        opaque_selected_digest["selected"]["objective_tuple_sha256"] = _sha(
            "unsupported-objective-tuple"
        )
        self._assert_invalid(
            "calibration-selection-v2",
            opaque_selected_digest,
        )

        opaque_outcome_digest = deepcopy(self.selection)
        opaque_outcome_digest["validation_outcomes"][0][
            "objective_tuple_sha256"
        ] = _sha("unsupported-objective-tuple")
        self._assert_invalid(
            "calibration-selection-v2",
            opaque_outcome_digest,
        )

        failed_selection_artifact = deepcopy(self.selection)
        failed_selection_artifact["selection_status"] = (
            "failed_no_feasible_validation_candidate"
        )
        self._assert_invalid(
            "calibration-selection-v2",
            failed_selection_artifact,
        )

        integrity_as_candidate_outcome = deepcopy(self.selection)
        integrity_as_candidate_outcome["validation_outcomes"] = [
            {
                "candidate_vector_sha256": self.candidate_sha,
                "outcome_kind": "failed",
                "failure_type": "evidence_integrity",
                "failure_reasons": ["stale evaluation"],
                "failure": _evidence(
                    f"failures/{_sha('integrity')}.json",
                    "integrity",
                ),
            }
        ]
        self._assert_invalid(
            "calibration-selection-v2",
            integrity_as_candidate_outcome,
        )

    def test_failure_closure_and_release_boundaries_are_closed(self) -> None:
        applicability_mismatch = deepcopy(self.failure)
        applicability_mismatch["failure_bindings"]["attempt_ledger"] = {
            "applicable": True,
            "binding": None,
        }
        self._assert_invalid(
            "p06-calibration-failure-v2",
            applicability_mismatch,
        )

        not_applicable = {"applicable": False, "binding": None}

        def failure_variant(
            failure_type: str,
            failure_stage: str,
        ) -> dict[str, object]:
            failure = deepcopy(self.failure)
            failure["candidate_vector_sha256"] = (
                None
                if failure_stage == "authority_authentication"
                else self.candidate_sha
            )
            failure["shared_bank_configuration_sha256"] = (
                None
                if failure_stage == "authority_authentication"
                else self.shared_bank_sha
            )
            failure["failure_stage"] = failure_stage
            failure["failure_type"] = failure_type
            failure["failure_reasons"] = (
                ["native evaluator failed"]
                if failure_type == "evaluation"
                else []
            )
            failure["failure_bindings"] = {
                name: deepcopy(not_applicable)
                for name in (
                    "attempt_ledger",
                    "trace_evidence",
                    "artifact_manifest",
                    "cleanup_evidence",
                    "recovery_evidence",
                )
            }
            failure["cleanup"] = {
                "invoked": False,
                "idempotent": True,
                "completed": False,
                "unrelated_files_deleted": False,
            }
            failure["recovery"] = {
                "resume_allowed": False,
                "recovery_stage": "none",
                "resume_source": deepcopy(not_applicable),
            }
            if failure_type == "constraint":
                failure["failure_bindings"]["attempt_ledger"] = _applicable(
                    "attempts-v2.ndjson",
                    "constraint-attempt-ledger",
                )
                failure["recovery"] = {
                    "resume_allowed": True,
                    "recovery_stage": "resume_development_search",
                    "resume_source": _applicable(
                        "attempts-v2.ndjson",
                        "constraint-resume-source",
                    ),
                }
            elif failure_type == "evaluation":
                failure["failure_bindings"]["trace_evidence"] = _applicable(
                    "failures/evaluation-trace.json",
                    "evaluation-trace",
                )
                failure["recovery"] = {
                    "resume_allowed": True,
                    "recovery_stage": (
                        "resume_development_search"
                        if failure_stage == "development_search"
                        else "rerun_validation_selection"
                    ),
                    "resume_source": _applicable(
                        "attempts-v2.ndjson",
                        "resume-source",
                    ),
                }
            elif failure_type == "evidence_integrity":
                failure["failure_bindings"]["trace_evidence"] = _applicable(
                    "failures/integrity-trace.json",
                    "integrity-trace",
                )
                failure["failure_bindings"]["artifact_manifest"] = (
                    _applicable(
                        "artifact-manifest-v2.json",
                        "integrity-manifest",
                    )
                )
                if failure_stage != "authority_authentication":
                    failure["failure_bindings"]["attempt_ledger"] = (
                        _applicable("attempts-v2.ndjson", "attempt-ledger")
                    )
            elif failure_type == "terminal":
                failure["failure_bindings"]["attempt_ledger"] = _applicable(
                    "attempts-v2.ndjson",
                    "attempt-ledger",
                )
                failure["failure_bindings"]["trace_evidence"] = _applicable(
                    "failures/terminal-trace.json",
                    "terminal-trace",
                )
                failure["failure_bindings"]["artifact_manifest"] = (
                    _applicable(
                        "artifact-manifest-v2.json",
                        "terminal-manifest",
                    )
                )
            return failure

        constraint_failure = failure_variant(
            "constraint",
            "development_search",
        )
        self._assert_valid("p06-calibration-failure-v2", constraint_failure)
        wrong_constraint_stage = deepcopy(constraint_failure)
        wrong_constraint_stage["failure_stage"] = "validation_selection"
        self._assert_invalid(
            "p06-calibration-failure-v2",
            wrong_constraint_stage,
        )

        for stage in ("development_search", "validation_selection"):
            with self.subTest(evaluation_stage=stage):
                self._assert_valid(
                    "p06-calibration-failure-v2",
                    failure_variant("evaluation", stage),
                )

        wrong_evaluation_stage = failure_variant(
            "evaluation",
            "validation_selection",
        )
        wrong_evaluation_stage["failure_stage"] = "validation_admission"
        self._assert_invalid(
            "p06-calibration-failure-v2",
            wrong_evaluation_stage,
        )

        evaluation_without_resume_source = failure_variant(
            "evaluation",
            "development_search",
        )
        evaluation_without_resume_source["recovery"]["resume_source"] = (
            deepcopy(not_applicable)
        )
        self._assert_invalid(
            "p06-calibration-failure-v2",
            evaluation_without_resume_source,
        )

        evaluation_without_reasons = failure_variant(
            "evaluation",
            "development_search",
        )
        evaluation_without_reasons["failure_reasons"] = []
        self._assert_invalid(
            "p06-calibration-failure-v2",
            evaluation_without_reasons,
        )

        integrity_failure = failure_variant(
            "evidence_integrity",
            "development_search",
        )
        self._assert_valid("p06-calibration-failure-v2", integrity_failure)
        integrity_without_ledger = deepcopy(integrity_failure)
        integrity_without_ledger["failure_bindings"]["attempt_ledger"] = (
            deepcopy(not_applicable)
        )
        self._assert_invalid(
            "p06-calibration-failure-v2",
            integrity_without_ledger,
        )

        terminal_failure = failure_variant(
            "terminal",
            "validation_selection",
        )
        self._assert_valid("p06-calibration-failure-v2", terminal_failure)
        terminal_at_authority = deepcopy(terminal_failure)
        terminal_at_authority["failure_stage"] = "authority_authentication"
        terminal_at_authority["candidate_vector_sha256"] = None
        self._assert_invalid(
            "p06-calibration-failure-v2",
            terminal_at_authority,
        )
        terminal_without_trace = deepcopy(terminal_failure)
        terminal_without_trace["failure_bindings"]["trace_evidence"] = (
            deepcopy(not_applicable)
        )
        self._assert_invalid(
            "p06-calibration-failure-v2",
            terminal_without_trace,
        )

        post_authority_without_candidate = deepcopy(terminal_failure)
        post_authority_without_candidate["candidate_vector_sha256"] = None
        self._assert_invalid(
            "p06-calibration-failure-v2",
            post_authority_without_candidate,
        )
        authority_with_candidate = deepcopy(self.failure)
        authority_with_candidate["candidate_vector_sha256"] = self.candidate_sha
        self._assert_invalid(
            "p06-calibration-failure-v2",
            authority_with_candidate,
        )

        authority_with_fabricated_shared_bank = deepcopy(self.failure)
        authority_with_fabricated_shared_bank[
            "shared_bank_configuration_sha256"
        ] = self.shared_bank_sha
        self._assert_invalid(
            "p06-calibration-failure-v2",
            authority_with_fabricated_shared_bank,
        )

        post_authority_without_shared_bank = deepcopy(terminal_failure)
        post_authority_without_shared_bank[
            "shared_bank_configuration_sha256"
        ] = None
        self._assert_invalid(
            "p06-calibration-failure-v2",
            post_authority_without_shared_bank,
        )

        non_evaluation_with_reasons = deepcopy(terminal_failure)
        non_evaluation_with_reasons["failure_reasons"] = ["not applicable"]
        self._assert_invalid(
            "p06-calibration-failure-v2",
            non_evaluation_with_reasons,
        )

        cleanup_not_invoked_but_completed = deepcopy(constraint_failure)
        cleanup_not_invoked_but_completed["cleanup"]["completed"] = True
        self._assert_invalid(
            "p06-calibration-failure-v2",
            cleanup_not_invoked_but_completed,
        )
        cleanup_invoked_without_evidence = deepcopy(constraint_failure)
        cleanup_invoked_without_evidence["cleanup"]["invoked"] = True
        cleanup_invoked_without_evidence["cleanup"]["completed"] = True
        self._assert_invalid(
            "p06-calibration-failure-v2",
            cleanup_invoked_without_evidence,
        )

        missing_green_commit = deepcopy(self.closure)
        del missing_green_commit["component_closures"][0]["local_green_commit"]
        self._assert_invalid("p06-evidence-closure-v2", missing_green_commit)

        reordered_gates = deepcopy(self.closure)
        reordered_gates["gate_evidence"].reverse()
        self._assert_invalid("p06-evidence-closure-v2", reordered_gates)

        incomplete_release = deepcopy(self.release)
        incomplete_release["artifacts"].pop()
        self._assert_invalid("p06-release-bundle-v3", incomplete_release)

        holdout_opened = deepcopy(self.release)
        holdout_opened["holdout_accessed"] = True
        holdout_opened["holdout_access_count"] = 1
        self._assert_invalid("p06-release-bundle-v3", holdout_opened)

    def test_all_schema_path_bindings_reject_common_unsafe_paths(self) -> None:
        invalid_paths = (
            "evidence/",
            "/evidence/file.json",
            "evidence/../file.json",
            "evidence\\file.json",
            "evidence//file.json",
            "./file.json",
            "evidence/line\nfeed.json",
            "evidence/tab\tfile.json",
            "evidence/carriage\rreturn.json",
            "evidence/space file.json",
            "evidence/unicode-é.json",
        )

        def replace_path(
            schema_name: str,
            document: dict[str, object],
            path: str,
        ) -> None:
            if schema_name == "candidate-evaluation-v2":
                document["source_evidence_sha256_bindings"][0]["path"] = path
            elif schema_name == "calibration-attempt-record-v2":
                document["evaluation_artifact"]["path"] = path
            elif schema_name == "calibration-run-ledger-v2":
                document["input_bindings"][0]["path"] = path
            elif schema_name == (
                "validation-candidate-development-evidence-v2"
            ):
                document["development_trace"]["attempt_ledger"]["path"] = path
            elif schema_name == "calibration-selection-v2":
                document["calibration_run_ledger"]["path"] = path
            elif schema_name == "p06-calibration-failure-v2":
                document["failure_bindings"]["trace_evidence"]["binding"][
                    "path"
                ] = path
            elif schema_name == "p06-evidence-closure-v2":
                document["calibration_run_ledger"]["path"] = path
            elif schema_name == "p06-release-bundle-v3":
                document["filesystem_closure"][0]["path"] = path
            else:
                self.fail(f"missing path mutation for {schema_name}")

        for schema_name, document in self.documents.items():
            for invalid_path in invalid_paths:
                with self.subTest(
                    schema=schema_name,
                    invalid_path=invalid_path,
                ):
                    tampered = deepcopy(document)
                    replace_path(schema_name, tampered, invalid_path)
                    self._assert_invalid(schema_name, tampered)

    def test_all_root_objects_reject_unknown_fields_and_holdout_access(self) -> None:
        for schema_name, document in self.documents.items():
            with self.subTest(schema=schema_name):
                extra = deepcopy(document)
                extra["undeclared"] = True
                self._assert_invalid(schema_name, extra)

                if "data_access" in document:
                    leaked = deepcopy(document)
                    leaked["data_access"]["holdout_accessed"] = True
                    self._assert_invalid(schema_name, leaked)


if __name__ == "__main__":
    unittest.main()
