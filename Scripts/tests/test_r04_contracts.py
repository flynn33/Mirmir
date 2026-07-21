from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r04_contracts import (  # noqa: E402
    AUTHORIZATION_BOUNDARY,
    CHECK_IDS,
    CONFORMANCE_LIMITATIONS,
    CONFORMANCE_PATH,
    CONFORMANCE_RESULT,
    CONFORMANCE_SCHEMA_PATH,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    IMPLEMENTATION_SOURCE,
    NOT_OBSERVED_CHECK_IDS,
    PREDECESSOR,
    PREREGISTRATION_COMMIT,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R04ContractVerifier,
    SOURCE_CONTRACT_PATHS,
    STOP_RULE_IDS,
    SUBJECT_IDS,
    _semantic_sha256,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


class R04ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R04ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)

    @staticmethod
    def file_binding(relative: Path) -> dict[str, object]:
        payload = (REPOSITORY_ROOT / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def preregistration_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(value, errors)
        return errors

    def fixture_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_fixture_semantics(value, errors)
        return errors

    def valid_conformance(self) -> dict[str, object]:
        subject_results = []
        for subject in self.preregistration["subjects"]:
            subject_results.append(
                {
                    "subject_id": subject["id"],
                    "execution_status": subject["initial_status"],
                    "disposition": subject["initial_disposition"],
                    "reason": subject["reason"],
                }
            )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R04",
            "evidence_kind": "r04_videotoolbox_integration_contract",
            "source": dict(IMPLEMENTATION_SOURCE),
            "preregistration_binding": self.file_binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": self.file_binding(FIXTURE_CATALOG_PATH),
            "observation_status": {
                "hardware_capability_observation": "not_observed",
                "simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
            },
            "subject_results": subject_results,
            "checks": [
                {
                    "id": check_id,
                    "status": (
                        "not_observed"
                        if check_id in NOT_OBSERVED_CHECK_IDS
                        else "passed"
                    ),
                }
                for check_id in CHECK_IDS
            ],
            "result": dict(CONFORMANCE_RESULT),
            "limitations": list(CONFORMANCE_LIMITATIONS),
        }

    def conformance_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_conformance_semantics(value, errors)
        return errors

    def test_repository_preregistration_fixtures_and_start_conformance_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_conformance(), [])

    def test_preregistration_validates_against_schema(self) -> None:
        schema = read_json(PREREGISTRATION_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, self.preregistration), [])

    def test_fixture_catalog_validates_against_schema(self) -> None:
        schema = read_json(FIXTURE_CATALOG_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, self.catalog), [])

    def test_future_conformance_shape_validates_against_schema(self) -> None:
        schema = read_json(CONFORMANCE_SCHEMA_PATH)
        self.assertEqual(
            validate_json_schema_instance(schema, self.valid_conformance()), []
        )

    def test_conformance_record_is_materialized_after_implementation(self) -> None:
        self.assertTrue((REPOSITORY_ROOT / CONFORMANCE_PATH).is_file())
        self.assertEqual(self.verifier.check_conformance(), [])

    def test_conformance_source_is_exact_and_git_bound(self) -> None:
        errors: list[str] = []
        self.verifier._check_source(
            dict(IMPLEMENTATION_SOURCE), "R04 conformance source", errors
        )
        self.assertEqual(errors, [])

        errors = []
        self.verifier._check_source(
            {"commit": IMPLEMENTATION_SOURCE["commit"], "tree": "1" * 40},
            "R04 conformance source",
            errors,
        )
        self.assertTrue(any("tree differs" in error for error in errors))

        errors = []
        self.verifier._check_source(
            {
                "commit": PREREGISTRATION_COMMIT,
                "tree": IMPLEMENTATION_SOURCE["tree"],
            },
            "R04 conformance source",
            errors,
        )
        self.assertTrue(any("strict descendant" in error for error in errors))

    def test_conformance_source_path_set_includes_implementation(self) -> None:
        self.assertIn(
            Path("Mirmir/Modules/UpscalerEngine/R04VideoToolboxContracts.swift"),
            SOURCE_CONTRACT_PATHS,
        )
        self.assertIn(
            Path("MirmirTests/R04VideoToolboxSessionAdapterTests.swift"),
            SOURCE_CONTRACT_PATHS,
        )

    def test_conformance_binding_path_is_not_self_selected(self) -> None:
        value = self.valid_conformance()
        value["preregistration_binding"] = self.file_binding(FIXTURE_CATALOG_PATH)
        self.assertTrue(
            any(
                "frozen path" in error
                for error in self.conformance_errors(value)
            )
        )

    def test_predecessor_binding_is_exact(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        errors: list[str] = []
        self.verifier._check_predecessor(value, errors)
        self.assertTrue(any("exact blocked R03 closure" in error for error in errors))

    def test_predecessor_result_remains_blocked_and_acceptance_unclaimed(self) -> None:
        self.assertEqual(PREDECESSOR["predecessor_result"], "blocked")
        self.assertEqual(PREDECESSOR["acceptance_state"], "not_claimed")
        self.assertIsNone(PREDECESSOR["accepted_merge_commit"])

    def test_toolchain_boundary_is_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["toolchain_boundary"]["runtime_floor"] = "macOS 25.0"
        self.assertIn(
            "R04 macOS 26 / Swift 6.2 / simulator boundary differs",
            self.preregistration_errors(value),
        )

    def test_simulator_unavailable_is_nonblocking_and_not_observed(self) -> None:
        boundary = self.preregistration["toolchain_boundary"]
        policy = self.preregistration["observation_policy"]
        self.assertEqual(boundary["simulator_availability"], "unavailable")
        self.assertEqual(boundary["simulator_availability_effect"], "not_a_blocker")
        self.assertEqual(policy["simulator_requirement"], "waived_not_a_blocker")
        self.assertEqual(policy["simulator_execution"], "not_observed")

    def test_hardware_and_operator_observation_are_nonblocking(self) -> None:
        policy = self.preregistration["observation_policy"]
        self.assertEqual(policy["hardware_requirement"], "waived_not_a_blocker")
        self.assertEqual(
            policy["operator_observation_requirement"], "waived_not_a_blocker"
        )
        self.assertEqual(policy["hardware_capability_observation"], "not_observed")
        self.assertEqual(policy["operator_observed_operation"], "not_observed")

    def test_quality_and_performance_claims_are_forbidden(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["observation_policy"]["quality_claims"] = "allowed"
        self.assertIn(
            "R04 observation policy differs from the operator override",
            self.preregistration_errors(value),
        )

    def test_authorization_boundary_is_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["authorization_boundary"]["production_default"] = "enabled"
        self.assertIn(
            "R04 authorization boundary differs", self.preregistration_errors(value)
        )
        self.assertEqual(
            self.preregistration["authorization_boundary"], AUTHORIZATION_BOUNDARY
        )

    def test_subject_order_and_identities_are_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["subjects"].reverse()
        self.assertIn(
            "R04 subject identity and route matrix differs",
            self.preregistration_errors(value),
        )

    def test_a01_quality_1p5x_is_a_typed_contract_rejection(self) -> None:
        subject = self.preregistration["subjects"][1]
        self.assertEqual(subject["capability_id"], "A01")
        self.assertEqual(subject["route_policy"], "typed_rejection")
        self.assertEqual(subject["initial_status"], "contract_rejected")
        self.assertEqual(subject["initial_disposition"], "rejected")
        self.assertEqual(subject["reason"], "public_contract_unrepresentable")

    def test_a02_routes_require_exact_dimension_query(self) -> None:
        for subject in self.preregistration["subjects"][2:4]:
            self.assertEqual(subject["capability_id"], "A02")
            self.assertEqual(subject["route_policy"], "exact_dimension_query_required")

    def test_a05_is_optional_and_ineligible_for_default(self) -> None:
        subject = self.preregistration["subjects"][4]
        self.assertEqual(subject["capability_id"], "A05")
        self.assertEqual(subject["route_policy"], "optional_runtime_support")
        self.assertEqual(
            subject["product_default_eligibility"], "ineligible_optional_support"
        )

    def test_check_ids_and_order_are_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["checks"][0]["id"] = "mutated"
        self.assertIn("R04 check IDs/order differ", self.preregistration_errors(value))
        self.assertEqual(len(CHECK_IDS), 22)

    def test_stop_rule_ids_and_order_are_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["stop_rules"].reverse()
        self.assertIn(
            "R04 stop-rule IDs/order differ", self.preregistration_errors(value)
        )
        self.assertEqual(len(STOP_RULE_IDS), 11)

    def test_source_binding_hash_drift_fails_closed(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["source_bindings"][0]["sha256"] = "1" * 64
        errors = self.fixture_errors(value)
        self.assertTrue(any("exact frozen R01 bytes" in error for error in errors))
        self.assertTrue(any("sha256 differs" in error for error in errors))

    def test_route_dimensions_and_gates_are_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["routes"][2]["input_dimensions"]["width"] = 1279
        self.assertIn(
            "R04 route dimensions, scale, capability, or gate differs",
            self.fixture_errors(value),
        )

    def test_a01_executable_route_is_2x_only(self) -> None:
        routes = self.catalog["routes"]
        a01_routes = [route for route in routes if route["capability_id"] == "A01"]
        self.assertEqual(a01_routes[0]["gate"], "runtime_support_required")
        self.assertEqual(a01_routes[0]["scale_numerator"], 2)
        self.assertEqual(a01_routes[0]["scale_denominator"], 1)
        self.assertEqual(a01_routes[1]["gate"], "public_contract_unrepresentable")

    def test_fixture_members_are_exact_r01_identities(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["fixtures"][4]["member_ids"].reverse()
        self.assertIn("R04 fixture member bindings differ", self.fixture_errors(value))

    def test_unknown_scenario_reference_fails(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["scenarios"][0]["subject_ids"][0] = "r04.unknown"
        self.assertTrue(
            any("unknown subject" in error for error in self.fixture_errors(value))
        )

    def test_valid_unobserved_conformance_is_contract_only(self) -> None:
        value = self.valid_conformance()
        self.assertEqual(self.conformance_errors(value), [])

    def test_conformance_quality_1p5x_rejection_cannot_change(self) -> None:
        value = self.valid_conformance()
        value["subject_results"][1]["reason"] = (
            "runtime_not_observed_under_operator_override"
        )
        self.assertIn(
            "R04 quality 1.5x requires the typed public_contract_unrepresentable rejection",
            self.conformance_errors(value),
        )

    def test_not_observed_conformance_cannot_carry_observed_disposition(self) -> None:
        value = self.valid_conformance()
        value["subject_results"][0]["disposition"] = "restricted"
        self.assertTrue(
            any("carries an observed claim" in error for error in self.conformance_errors(value))
        )

    def test_optional_a05_observation_cannot_be_primary(self) -> None:
        value = self.valid_conformance()
        item = value["subject_results"][4]
        item.update(
            execution_status="observed",
            disposition="restricted",
            reason="observed_contract_only_no_quality_or_performance_claim",
        )
        self.assertIn(
            "R04 optional A05 support cannot become a primary disposition",
            self.conformance_errors(value),
        )

    def test_conformance_cannot_name_a_default(self) -> None:
        value = self.valid_conformance()
        value["result"]["default_backend_id"] = SUBJECT_IDS[0]
        self.assertIn(
            "R04 conformance result exceeds the authorization boundary",
            self.conformance_errors(value),
        )

    def test_conformance_result_cannot_claim_passed(self) -> None:
        value = self.valid_conformance()
        value["result"]["status"] = "passed"
        self.assertIn(
            "R04 conformance result exceeds the authorization boundary",
            self.conformance_errors(value),
        )

    def test_conformance_check_results_are_frozen(self) -> None:
        value = self.valid_conformance()
        value["checks"][0]["status"] = "not_observed"
        self.assertIn(
            "R04 conformance check results differ from the frozen closure",
            self.conformance_errors(value),
        )

    def test_conformance_limitations_are_frozen(self) -> None:
        value = self.valid_conformance()
        value["limitations"].pop()
        self.assertIn(
            "R04 conformance limitations differ from the frozen closure",
            self.conformance_errors(value),
        )

    def test_conformance_observation_boundary_is_frozen(self) -> None:
        value = self.valid_conformance()
        value["observation_status"]["simulator_execution"] = "observed"
        self.assertIn(
            "R04 conformance observation boundary differs",
            self.conformance_errors(value),
        )

    def test_semantic_hash_detects_description_drift(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["checks"][0]["description"] = "mutated"
        self.assertNotEqual(_semantic_sha256(value), _semantic_sha256(self.preregistration))
        self.assertIn(
            "R04 preregistration semantic contract differs",
            self.preregistration_errors(value),
        )

    def test_nul_path_is_rejected_without_exception(self) -> None:
        errors: list[str] = []
        self.assertIsNone(self.verifier._safe_path("bad\x00path", "test", errors))
        self.assertTrue(any("NUL" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
