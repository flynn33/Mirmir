from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.calibration_plan_codec import (
    SHARED_BANK_DOMAIN_SEPARATOR_V2,
    SHARED_BANK_SERIALIZATION_ORDER_V2,
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.calibration_scheduler_v2 import (
    ATTEMPTS_PER_COMPLETE_SWEEP,
    DEVELOPMENT_SPLIT,
    MAXIMUM_DEVELOPMENT_ATTEMPTS,
    MAXIMUM_SWEEPS,
    MAXIMUM_VALIDATION_NEIGHBORHOOD,
    SCALAR_ATTEMPTS_PER_SWEEP,
    STRUCTURAL_ATTEMPTS_PER_SWEEP,
    VALIDATION_SPLIT,
    DevelopmentEvaluationV2,
    ScoredValidationCandidateV2,
    ValidationEvaluationV2,
    evaluation_cache_identity_v2,
    run_development_search_v2,
    select_validation_candidate_v2,
    validation_admission_v2,
    validation_neighborhood_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = CALIBRATION_ROOT / "contracts/candidate-evidence-policy-v2.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas/candidate-evidence-policy-v2.schema.json"
PLAN_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
V1_POLICY_PATH = CALIBRATION_ROOT / "contracts/candidate-evidence-policy-v1.json"
SHARED_BANK_PATH = (
    CALIBRATION_ROOT
    / "contracts/shared-bank-configuration-identity-v2.json"
)
BASELINE_PATH = CALIBRATION_ROOT / "contracts/baseline-ablation-contract-v1.json"
BASELINE_BUDGET_PATH = (
    CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
)
BASELINE_BUDGET_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/baseline-ablation-budget-v2.schema.json"
)

EXPECTED_CONTRACT_SELF_SHA256 = (
    "aa1770aa05761ef22e2bc174c43bcefa23a9743d2ccbfe9c6dc7876229a3798d"
)
EXPECTED_CONTRACT_FILE_SHA256 = (
    "2e7d281ca1959d0eafe42aa6bbf57e34cf48d7dde39c4767a1b83f413fb5fb9c"
)
EXPECTED_SCHEMA_FILE_SHA256 = (
    "1bbe2402851fe584eb86b589553b9fb2f3ddb3c809a5ef37ba18a5ce34cf2129"
)
EXPECTED_V1_POLICY_FILE_SHA256 = (
    "97c6d898b247cc960535ad393b053d723782c398df18d6dd9472d6226d933190"
)
EXPECTED_V1_POLICY_SCHEMA_FILE_SHA256 = (
    "2e59187816340fe9d7c88495a5bdd6e26fd33258df6ed521814900464cca024a"
)
EXPECTED_PLAN_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
EXPECTED_PLAN_SELF_SHA256 = (
    "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
)
EXPECTED_PLAN_SCHEMA_FILE_SHA256 = (
    "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09"
)
EXPECTED_SHARED_BANK_FILE_SHA256 = (
    "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de"
)
EXPECTED_SHARED_BANK_SELF_SHA256 = (
    "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37"
)
EXPECTED_SHARED_BANK_SCHEMA_FILE_SHA256 = (
    "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c"
)
EXPECTED_BASELINE_BUDGET_FILE_SHA256 = (
    "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8"
)
EXPECTED_BASELINE_BUDGET_SELF_SHA256 = (
    "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be"
)
EXPECTED_BASELINE_BUDGET_SCHEMA_FILE_SHA256 = (
    "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b"
)


def _load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CandidateEvidencePolicyV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = _load_object(CONTRACT_PATH)
        cls.schema = _load_object(SCHEMA_PATH)
        cls.plan_document = _load_object(PLAN_PATH)
        cls.v1_policy = _load_object(V1_POLICY_PATH)
        cls.shared_bank_contract = _load_object(SHARED_BANK_PATH)
        cls.baseline_contract = _load_object(BASELINE_PATH)
        cls.baseline_budget_contract = _load_object(BASELINE_BUDGET_PATH)
        cls.baseline_budget_schema = _load_object(BASELINE_BUDGET_SCHEMA_PATH)
        bound_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in cls.plan_document["input_bindings"]
        }
        cls.plan = parse_calibration_plan_v2(
            PLAN_PATH.read_bytes(),
            bound_payloads=bound_payloads,
        )
        cls.initial_logical = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(cls.plan.scalar_initial_values),
        }
        cls.initial_physical = dict(
            materialize_candidate_vector_v2(cls.initial_logical, cls.plan)
        )

    def test_contract_schema_self_hash_and_authority_bindings_are_exact(
        self,
    ) -> None:
        Draft202012Validator.check_schema(self.schema)
        validator = Draft202012Validator(self.schema)
        self.assertEqual(list(validator.iter_errors(self.contract)), [])
        self.assertEqual(self.schema["const"], self.contract)
        self.assertFalse(self.schema["additionalProperties"])
        self.assertEqual(set(self.schema["required"]), set(self.contract))
        self.assertEqual(set(self.schema["properties"]), set(self.contract))

        self.assertEqual(
            self.contract["artifact_sha256"],
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(_file_sha256(CONTRACT_PATH), EXPECTED_CONTRACT_FILE_SHA256)
        self.assertEqual(_file_sha256(SCHEMA_PATH), EXPECTED_SCHEMA_FILE_SHA256)
        self.assertEqual(
            CONTRACT_PATH.read_bytes(),
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            SCHEMA_PATH.read_bytes(),
            canonical_json_bytes(self.schema) + b"\n",
        )

        expected_ids = [
            "candidate_evidence_policy_v1",
            "candidate_evidence_policy_v1_schema",
            "calibration_plan_v2",
            "calibration_plan_v2_schema",
            "shared_bank_configuration_identity_v2",
            "shared_bank_configuration_identity_v2_schema",
            "baseline_ablation_contract_v1",
            "baseline_ablation_contract_v1_schema",
            "baseline_ablation_budget_v2",
            "baseline_ablation_budget_v2_schema",
        ]
        self.assertEqual(
            [binding["id"] for binding in self.contract["authority_bindings"]],
            expected_ids,
        )
        for binding in self.contract["authority_bindings"]:
            with self.subTest(binding=binding["id"]):
                path = ROOT / binding["path"]
                payload = path.read_bytes()
                self.assertEqual(len(payload), binding["size_bytes"])
                self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])
                self_hash = binding["self_hash"]
                if self_hash is not None:
                    document = json.loads(payload)
                    self.assertEqual(
                        document[self_hash["field"]],
                        self_hash["sha256"],
                    )
                    self.assertEqual(
                        manifest_sha256(document, field=self_hash["field"]),
                        self_hash["sha256"],
                    )

    def test_frozen_v1_plan_and_shared_bank_triples_are_exact(self) -> None:
        bindings = {
            binding["id"]: binding
            for binding in self.contract["authority_bindings"]
        }
        self.assertEqual(
            bindings["candidate_evidence_policy_v1"]["sha256"],
            EXPECTED_V1_POLICY_FILE_SHA256,
        )
        self.assertEqual(
            bindings["candidate_evidence_policy_v1_schema"]["sha256"],
            EXPECTED_V1_POLICY_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            bindings["calibration_plan_v2"]["sha256"],
            EXPECTED_PLAN_FILE_SHA256,
        )
        self.assertEqual(
            bindings["calibration_plan_v2"]["self_hash"]["sha256"],
            EXPECTED_PLAN_SELF_SHA256,
        )
        self.assertEqual(
            bindings["calibration_plan_v2_schema"]["sha256"],
            EXPECTED_PLAN_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            bindings["shared_bank_configuration_identity_v2"]["sha256"],
            EXPECTED_SHARED_BANK_FILE_SHA256,
        )
        self.assertEqual(
            bindings["shared_bank_configuration_identity_v2"]["self_hash"][
                "sha256"
            ],
            EXPECTED_SHARED_BANK_SELF_SHA256,
        )
        self.assertEqual(
            bindings["shared_bank_configuration_identity_v2_schema"]["sha256"],
            EXPECTED_SHARED_BANK_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            bindings["baseline_ablation_budget_v2"]["sha256"],
            EXPECTED_BASELINE_BUDGET_FILE_SHA256,
        )
        self.assertEqual(
            bindings["baseline_ablation_budget_v2"]["self_hash"]["sha256"],
            EXPECTED_BASELINE_BUDGET_SELF_SHA256,
        )
        self.assertEqual(
            bindings["baseline_ablation_budget_v2_schema"]["sha256"],
            EXPECTED_BASELINE_BUDGET_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            list(
                Draft202012Validator(self.baseline_budget_schema).iter_errors(
                    self.baseline_budget_contract
                )
            ),
            [],
        )

        inheritance = self.contract["inheritance"]
        self.assertEqual(
            inheritance["frozen_v1_top_level_fields"],
            list(self.v1_policy),
        )
        self.assertEqual(
            inheritance["frozen_v1_source_evidence_order"],
            list(self.v1_policy["source_evidence"]),
        )
        self.assertEqual(inheritance["frozen_v1_field_scope"], "/")
        self.assertTrue(inheritance["frozen_v1_byte_identity_required"])
        self.assertFalse(inheritance["v1_field_mutation_allowed"])

    def test_schema_rejects_root_nested_identity_budget_and_boundary_mutations(
        self,
    ) -> None:
        invalid_documents = []

        invalid = deepcopy(self.contract)
        invalid["unexpected"] = True
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        del invalid["hash_topology"]
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["artifact_sha256"] = "0" * 64
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["candidate_identity"]["physical_candidate_order"] = invalid[
            "candidate_identity"
        ]["physical_candidate_order"][:-1]
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["search_budget"]["maximum_development_attempt_count"] = 3289
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["baseline_comparison_budget"]["execution_blocked"] = True
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["data_access"]["validation_accessed"] = True
        invalid_documents.append(invalid)

        invalid = deepcopy(self.contract)
        invalid["execution_boundary"][
            "production_execution_authorized_by_this_contract_alone"
        ] = True
        invalid_documents.append(invalid)

        validator = Draft202012Validator(self.schema)
        for index, invalid in enumerate(invalid_documents):
            with self.subTest(index=index):
                self.assertNotEqual(list(validator.iter_errors(invalid)), [])

    def test_live_codec_candidate_and_shared_bank_identity_match_contract(
        self,
    ) -> None:
        identity = self.contract["candidate_identity"]
        self.assertEqual(identity["logical_candidate_field_count"], 38)
        self.assertEqual(identity["physical_candidate_field_count"], 48)
        self.assertEqual(
            identity["logical_candidate_order"],
            list(self.plan.logical_parameter_order),
        )
        self.assertEqual(
            identity["physical_candidate_order"],
            list(self.plan.physical_candidate_order),
        )
        self.assertEqual(len(self.initial_physical), 48)
        self.assertEqual(
            list(self.initial_physical),
            identity["physical_candidate_order"],
        )
        self.assertEqual(
            candidate_vector_sha256_v2(self.initial_physical, self.plan),
            self.shared_bank_contract["goldens"]["ordinal_0"][
                "candidate_vector_sha256"
            ],
        )

        cache_and_bank = self.contract["cache_and_shared_bank_identity"]
        self.assertEqual(
            cache_and_bank["shared_bank_configuration_domain_separator"],
            SHARED_BANK_DOMAIN_SEPARATOR_V2,
        )
        self.assertEqual(
            cache_and_bank["shared_bank_configuration_order"],
            list(SHARED_BANK_SERIALIZATION_ORDER_V2),
        )
        self.assertEqual(
            shared_bank_configuration_sha256_v2(
                self.initial_physical,
                self.plan,
            ),
            self.shared_bank_contract["goldens"]["ordinal_0"][
                "shared_bank_configuration_sha256"
            ],
        )

    def test_live_cache_and_scheduler_budgets_match_contract(self) -> None:
        cache_policy = self.contract["cache_and_shared_bank_identity"]
        development_identity = evaluation_cache_identity_v2(
            DEVELOPMENT_SPLIT,
            self.initial_physical,
            self.plan,
        )
        validation_identity = evaluation_cache_identity_v2(
            VALIDATION_SPLIT,
            self.initial_physical,
            self.plan,
        )
        self.assertEqual(
            list(development_identity.__dataclass_fields__),
            cache_policy["evaluation_cache_identity_fields"],
        )
        self.assertEqual(
            development_identity.calibration_plan_file_sha256,
            EXPECTED_PLAN_FILE_SHA256,
        )
        self.assertNotEqual(development_identity, validation_identity)
        self.assertEqual(development_identity.split, DEVELOPMENT_SPLIT)
        self.assertEqual(validation_identity.split, VALIDATION_SPLIT)

        budget = self.contract["search_budget"]
        self.assertEqual(budget["structural_attempts_per_sweep"], STRUCTURAL_ATTEMPTS_PER_SWEEP)
        self.assertEqual(budget["scalar_attempts_per_sweep"], SCALAR_ATTEMPTS_PER_SWEEP)
        self.assertEqual(budget["attempts_per_complete_sweep"], ATTEMPTS_PER_COMPLETE_SWEEP)
        self.assertEqual(budget["maximum_sweeps"], MAXIMUM_SWEEPS)
        self.assertEqual(
            budget["maximum_development_attempt_count"],
            MAXIMUM_DEVELOPMENT_ATTEMPTS,
        )
        self.assertEqual(
            budget["minimum_terminated_feasible_attempt_count"],
            2 * ATTEMPTS_PER_COMPLETE_SWEEP,
        )
        self.assertEqual(
            ATTEMPTS_PER_COMPLETE_SWEEP,
            STRUCTURAL_ATTEMPTS_PER_SWEEP + SCALAR_ATTEMPTS_PER_SWEEP,
        )
        self.assertEqual(
            MAXIMUM_DEVELOPMENT_ATTEMPTS,
            MAXIMUM_SWEEPS * ATTEMPTS_PER_COMPLETE_SWEEP,
        )

        comparison = self.contract["baseline_comparison_budget"]
        selector = self.baseline_contract["non_ash_selector"]
        self.assertEqual(
            comparison["non_ash_v1_candidate_evaluation_budget"],
            selector["candidate_evaluation_budget"],
        )
        self.assertEqual(
            comparison["full_ash_v1_maximum_candidate_evaluation_budget"],
            selector["full_ash_maximum_candidate_evaluation_budget"],
        )
        self.assertLess(
            comparison["non_ash_v1_candidate_evaluation_budget"],
            comparison["full_ash_v2_maximum_development_attempt_count"],
        )
        v2_budget = self.baseline_budget_contract["budget"]
        self.assertEqual(
            comparison["non_ash_v2_maximum_development_attempt_count"],
            v2_budget["non_ash_maximum_development_attempt_count"],
        )
        self.assertGreaterEqual(
            comparison["non_ash_v2_maximum_development_attempt_count"],
            comparison["full_ash_v2_maximum_development_attempt_count"],
        )
        self.assertEqual(comparison["historical_v1_inequality"], "1513 < 3288")
        self.assertEqual(comparison["inequality"], "3403 >= 3288")
        self.assertFalse(comparison["execution_blocked"])
        self.assertFalse(comparison["silent_v1_budget_carry_forward_allowed"])

    def test_live_validation_neighborhood_and_selection_match_contract(
        self,
    ) -> None:
        policy = self.contract["validation_selection"]
        neighborhood = validation_neighborhood_v2(self.initial_logical, self.plan)
        self.assertEqual(
            neighborhood.candidate_count_before_constraint_filtering,
            MAXIMUM_VALIDATION_NEIGHBORHOOD,
        )
        self.assertEqual(
            policy["maximum_candidate_count_before_constraint_filtering"],
            MAXIMUM_VALIDATION_NEIGHBORHOOD,
        )
        terminal_scalars = dict(self.plan.scalar_initial_values)
        structural_count = 0
        scalar_count = 0
        for candidate in neighborhood.candidates_before_constraint_filtering:
            logical = dict(candidate.logical_candidate_items)
            self.assertEqual(len(candidate.physical_candidate_items), 48)
            if all(
                logical[name] == value
                for name, value in terminal_scalars.items()
            ):
                structural_count += 1
            else:
                scalar_count += 1
            self.assertEqual(candidate.development_cache_identity.split, DEVELOPMENT_SPLIT)
            self.assertEqual(candidate.validation_cache_identity.split, VALIDATION_SPLIT)
        self.assertEqual(structural_count, 256)
        self.assertEqual(scalar_count, 118)
        self.assertEqual(
            structural_count + scalar_count,
            policy["maximum_candidate_count_before_constraint_filtering"],
        )

        initial_scalars = dict(self.plan.scalar_initial_values)

        def development_evaluator(logical, physical, identity):
            del physical, identity
            deviations = sum(
                logical[name] != value
                for name, value in initial_scalars.items()
            )
            score = -(1000 * int(logical[ATOMIC_STRUCTURAL_COORDINATE]) + deviations)
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

        development = run_development_search_v2(self.plan, development_evaluator)
        admission = validation_admission_v2(
            self.plan,
            development.attempt_records,
            expected_attempt_count=development.attempt_count,
            expected_last_record_sha256=development.last_record_sha256,
        )
        terminal_sha256 = admission.neighborhood.terminal_candidate_sha256
        scored = tuple(
            ScoredValidationCandidateV2(
                candidate=candidate,
                evaluation=ValidationEvaluationV2(
                    feasible=True,
                    failure_reasons=(),
                    y_vs_fixed_ci_low=(
                        10 if candidate.candidate_vector_sha256 == terminal_sha256 else 0
                    ),
                    y_vs_non_ash_ci_low=(
                        10 if candidate.candidate_vector_sha256 == terminal_sha256 else 0
                    ),
                    y_vs_conventional_ci_low=(
                        10 if candidate.candidate_vector_sha256 == terminal_sha256 else 0
                    ),
                    mean_ms_ssim_delta_vs_conventional=(
                        10 if candidate.candidate_vector_sha256 == terminal_sha256 else 0
                    ),
                    maximum_ringing_excursion=(
                        0 if candidate.candidate_vector_sha256 == terminal_sha256 else 1
                    ),
                    maximum_alias_ratio=(
                        0 if candidate.candidate_vector_sha256 == terminal_sha256 else 1
                    ),
                    estimated_dispatch_cost=(
                        0 if candidate.candidate_vector_sha256 == terminal_sha256 else 1
                    ),
                ),
            )
            for candidate in admission.admitted_candidates
        )
        selection = select_validation_candidate_v2(
            admission,
            scored,
            self.plan,
            evaluation_failures=(),
        )
        reversed_selection = select_validation_candidate_v2(
            admission,
            tuple(reversed(scored)),
            self.plan,
            evaluation_failures=(),
        )
        self.assertEqual(
            selection.selected.candidate.candidate_vector_sha256,
            terminal_sha256,
        )
        self.assertEqual(
            reversed_selection.selected.candidate.candidate_vector_sha256,
            terminal_sha256,
        )
        self.assertEqual(len(selection.pareto_frontier), 1)
        self.assertEqual(
            len(scored),
            admission.admitted_candidate_count,
        )

    def test_required_siblings_hash_propagation_and_no_execution_boundary(
        self,
    ) -> None:
        siblings = self.contract["persisted_evidence_siblings"]
        self.assertEqual(
            siblings["required_before_execution"],
            [
                "candidate-evaluation-v2.schema.json",
                "calibration-attempt-record-v2.schema.json",
                "calibration-run-ledger-v2.schema.json",
                "validation-candidate-development-evidence-v2.schema.json",
                "calibration-selection-v2.schema.json",
                "p06-calibration-failure-v2.schema.json",
                "baseline-ablation-budget-v2.json",
                "baseline-ablation-budget-v2.schema.json",
                "p06-evidence-closure-v2.schema.json",
                "p06-release-bundle-v3.schema.json",
                "P07 authorized-execution, result, gate, failure, and publication schemas accepting the V2 identity triple",
            ],
        )
        self.assertTrue(
            siblings["shared_bank_identity_triple_required_in_every_consumer"]
        )
        self.assertIn("cache", siblings["hash_propagation_consumers"])
        self.assertIn("P07_results_or_failure", siblings["hash_propagation_consumers"])
        self.assertIn(
            "failure only",
            siblings["failed_version_archive_rule"],
        )

        self.assertTrue(all(value is False for value in self.contract["data_access"].values()))
        boundary = self.contract["execution_boundary"]
        self.assertTrue(boundary["baseline_budget_blocker_resolved"])
        for field in (
            "candidate_evaluation_performed",
            "candidate_selection_performed",
            "current_v1_p06_run_affected",
            "fresh_current_source_gate_evidence_present",
            "gate_claim_made",
            "persisted_v2_evidence_siblings_present",
            "production_execution_authorized_by_this_contract_alone",
            "winner_claim_made",
        ):
            with self.subTest(field=field):
                self.assertFalse(boundary[field])
        self.assertEqual(
            self.contract["candidate_checks"][
                "fresh_current_source_gate_evidence_required"
            ],
            ["G04", "G05", "G06"],
        )
        self.assertEqual(
            [row["stage"] for row in self.contract["hash_topology"]],
            [
                "authority_binding",
                "candidate_identity",
                "shared_bank_identity",
                "evaluation_cache_identity",
                "candidate_evaluation",
                "attempt_ledger",
                "validation_admission",
                "run_ledger",
                "selection",
                "release",
                "p07",
            ],
        )


if __name__ == "__main__":
    unittest.main()
