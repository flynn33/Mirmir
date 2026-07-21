from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r06_contracts import (  # noqa: E402
    ABLATION_IDS,
    AUTHORIZATION_BOUNDARY,
    CHECK_IDS,
    CONFORMANCE_PATH,
    CONFORMANCE_SCHEMA_PATH,
    CONSTRUCTOR_PARAMETERS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    MESSAGE_AXES,
    OBSERVATION_POLICY,
    PREDECESSOR,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    PRODUCT_GATE,
    R06ContractVerifier,
    SCORING_CONTRACT,
    SIDECAR_FIELDS,
    SOURCE_BINDINGS,
    STOP_RULE_IDS,
    TRANSITION_REASON_IDS,
    expected_policy_profiles,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


class R06ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R06ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)

    def preregistration_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(value, errors)
        return errors

    def fixture_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_fixture_semantics(value, errors)
        return errors

    @staticmethod
    def file_binding(relative: Path) -> dict[str, object]:
        payload = (REPOSITORY_ROOT / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def future_conformance(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R06",
            "evidence_kind": "r06_ash_orchestration_contract",
            "source": {"commit": "1" * 40, "tree": "2" * 40},
            "preregistration_binding": self.file_binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": self.file_binding(FIXTURE_CATALOG_PATH),
            "observation_status": {
                "hardware_capability_observation": "not_observed",
                "simulator_execution": "not_observed",
                "operator_observed_operation": "not_observed",
                "product_ablation_execution": "not_observed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
            },
            "product_gate_result": {
                "reason": "no_product_qualified_primary_backend",
                "eligible_backend_count": 0,
                "selected_route_id": None,
                "selected_plan_id": None,
                "output_identity": None,
                "disposition": "blocked",
            },
            "fixture_checks": [{"id": "deterministic_fixture_contract", "status": "passed"}],
            "product_ablations": [
                {
                    "id": identifier,
                    "status": "not_observed",
                    "reason": "no_product_qualified_primary_backend",
                }
                for identifier in ABLATION_IDS
            ],
            "checks": [{"id": "product_gate_closed", "status": "blocked"}],
            "result": {
                "status": "blocked",
                "reason": "no_product_qualified_primary_backend",
                "default_backend_id": None,
                "selected_route_id": None,
                "selected_plan_id": None,
                "output_identity": None,
                "product_qualification": "not_claimed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
                "acceptance": "not_claimed",
            },
            "limitations": [
                "No R03-R05 backend has an explicit product-qualification record."
            ],
        }

    def test_repository_preregistration_fixtures_and_absence_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_conformance_absent(), [])

    def test_records_and_future_conformance_validate_against_schemas(self) -> None:
        cases = (
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.catalog),
            (CONFORMANCE_SCHEMA_PATH, self.future_conformance()),
        )
        for schema_path, value in cases:
            with self.subTest(schema=schema_path.as_posix()):
                self.assertEqual(
                    validate_json_schema_instance(read_json(schema_path), value),
                    [],
                )

    def test_conformance_must_remain_absent_during_preregistration(self) -> None:
        with mock.patch.object(Path, "is_symlink", return_value=False), mock.patch.object(
            Path, "exists", return_value=True
        ):
            self.assertEqual(
                self.verifier.check_conformance_absent(),
                [
                    "R06 orchestration conformance must be absent before the "
                    "implementation source is frozen"
                ],
            )
        self.assertFalse((REPOSITORY_ROOT / CONFORMANCE_PATH).exists())

    def test_predecessor_identity_result_and_acceptance_are_exact(self) -> None:
        self.assertEqual(self.preregistration["predecessor_binding"], PREDECESSOR)
        self.assertEqual(PREDECESSOR["predecessor_result"], "diagnostic_only")
        self.assertIsNone(PREDECESSOR["accepted_merge_commit"])
        value = copy.deepcopy(self.preregistration)
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        errors: list[str] = []
        self.verifier._check_predecessor(value, errors)
        self.assertTrue(any("exact diagnostic-only R05 closure" in item for item in errors))

    def test_operator_observation_policy_is_frozen_and_nonblocking(self) -> None:
        self.assertEqual(self.preregistration["observation_policy"], OBSERVATION_POLICY)
        value = copy.deepcopy(self.preregistration)
        value["observation_policy"]["simulator_requirement"] = "required"
        self.assertIn(
            "R06 observation policy differs from the operator override",
            self.preregistration_errors(value),
        )

    def test_product_gate_is_zero_eligible_and_has_no_route_plan_or_output(self) -> None:
        self.assertEqual(self.preregistration["product_gate"], PRODUCT_GATE)
        self.assertEqual(PRODUCT_GATE["eligible_backend_count"], 0)
        for key in ("selected_route_id", "selected_plan_id", "output_identity"):
            self.assertIsNone(PRODUCT_GATE[key])
        value = copy.deepcopy(self.preregistration)
        value["product_gate"]["selected_route_id"] = "fixture.route.metalfx_spatial"
        self.assertIn("R06 product eligibility gate differs", self.preregistration_errors(value))

    def test_authorization_boundary_is_blocked_without_hardware_cause(self) -> None:
        self.assertEqual(
            self.preregistration["authorization_boundary"], AUTHORIZATION_BOUNDARY
        )
        self.assertEqual(
            AUTHORIZATION_BOUNDARY["result_reason"],
            "no_product_qualified_primary_backend",
        )
        value = copy.deepcopy(self.preregistration)
        value["authorization_boundary"]["production_default"] = "enabled"
        self.assertIn("R06 authorization boundary differs", self.preregistration_errors(value))

    def test_top_level_key_order_is_closed(self) -> None:
        value = {"roadmap_version": self.preregistration["roadmap_version"]}
        value.update(
            (key, item)
            for key, item in self.preregistration.items()
            if key != "roadmap_version"
        )
        self.assertIn(
            "R06 preregistration top-level keys/order differ",
            self.preregistration_errors(value),
        )

    def test_canonical_nine_bit_state_and_sidecar_fields_are_frozen(self) -> None:
        state = self.preregistration["ash_state_contract"]
        self.assertEqual(state["packed_bit_count"], 9)
        self.assertEqual(state["sidecar_fields"], list(SIDECAR_FIELDS))
        value = copy.deepcopy(self.preregistration)
        value["ash_state_contract"]["packed_bit_count"] = 10
        errors = self.preregistration_errors(value)
        self.assertIn("R06 canonical ASH state/sidecar core differs", errors)

    def test_message_axis_mapping_and_all_sixteen_profiles_are_exact(self) -> None:
        self.assertEqual(
            self.preregistration["message_policy_contract"]["bit_axes"], MESSAGE_AXES
        )
        self.assertEqual(self.catalog["policy_profiles"], expected_policy_profiles())
        value = copy.deepcopy(self.catalog)
        value["policy_profiles"][15]["id"] = "policy.message.14"
        self.assertIn(
            "R06 sixteen-profile ASHMessage catalog differs",
            self.fixture_errors(value),
        )

    def test_single_message_bit_changes_only_its_mapped_axis(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["policy_profiles"][1]["denoise"] = "low"
        errors = self.fixture_errors(value)
        self.assertTrue(any("single-bit causality differs" in item for item in errors))

    def test_integer_scoring_formula_order_and_tie_break_are_frozen(self) -> None:
        self.assertEqual(self.preregistration["scoring_contract"], SCORING_CONTRACT)
        value = copy.deepcopy(self.preregistration)
        value["scoring_contract"]["tie_break"] = "candidate_input_order"
        self.assertIn(
            "R06 integer fixed-point scoring contract differs",
            self.preregistration_errors(value),
        )

    def test_constructor_bound_weights_and_thresholds_are_exact(self) -> None:
        self.assertEqual(self.catalog["constructor_parameters"], CONSTRUCTOR_PARAMETERS)
        value = copy.deepcopy(self.catalog)
        value["constructor_parameters"]["weights"]["quality_confidence"] = 5
        self.assertIn(
            "R06 constructor-bound weights/thresholds differ",
            self.fixture_errors(value),
        )

    def test_fixture_backends_are_whole_frame_and_not_product_qualified(self) -> None:
        backends = self.catalog["backend_fixtures"]
        self.assertTrue(all(item["whole_frame_only"] for item in backends))
        self.assertTrue(all(not item["product_qualified"] for item in backends))
        value = copy.deepcopy(self.catalog)
        value["backend_fixtures"][0]["product_qualified"] = True
        self.assertIn(
            "R06 fixture backend identity/eligibility matrix differs",
            self.fixture_errors(value),
        )

    def test_context_states_must_preserve_coordinate_nine_integrity(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["decision_context_fixtures"][0]["current_state_raw"] = 1
        errors = self.fixture_errors(value)
        self.assertTrue(any("current state fails integrity" in item for item in errors))

    def test_masks_reject_out_of_range_and_sample_count_mismatch(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["mask_fixtures"][0]["samples_q15"][0] = 32768
        self.assertTrue(
            any("sample is out of bounds" in item for item in self.fixture_errors(value))
        )
        value = copy.deepcopy(self.catalog)
        value["mask_fixtures"][0]["samples_q15"].pop()
        self.assertTrue(
            any("sample count differs" in item for item in self.fixture_errors(value))
        )

    def test_transition_outcomes_reasons_and_route_references_are_closed(self) -> None:
        reasons = {
            item["expected_reason"] for item in self.catalog["transition_fixtures"]
        }
        self.assertTrue(reasons < set(TRANSITION_REASON_IDS))
        value = copy.deepcopy(self.catalog)
        value["transition_fixtures"][0]["candidate_route_ids"][0] = "unknown"
        errors = self.fixture_errors(value)
        self.assertTrue(any("unknown route" in item for item in errors))

    def test_all_six_roadmap_ablations_are_fixture_only_and_product_not_observed(self) -> None:
        scenarios = self.catalog["ablation_scenarios"]
        self.assertEqual([item["id"] for item in scenarios], list(ABLATION_IDS))
        self.assertTrue(
            all(item["product_execution_status"] == "not_observed" for item in scenarios)
        )
        value = copy.deepcopy(self.catalog)
        value["ablation_scenarios"][0]["product_execution_status"] = "passed"
        self.assertIn("R06 fixture ablation matrix differs", self.fixture_errors(value))

    def test_check_and_stop_rule_order_is_closed(self) -> None:
        self.assertEqual(
            [item["id"] for item in self.preregistration["checks"]], list(CHECK_IDS)
        )
        self.assertEqual(
            [item["id"] for item in self.preregistration["stop_rules"]],
            list(STOP_RULE_IDS),
        )
        value = copy.deepcopy(self.preregistration)
        value["checks"].reverse()
        self.assertIn("R06 check IDs/order differ", self.preregistration_errors(value))
        value = copy.deepcopy(self.preregistration)
        value["stop_rules"].reverse()
        self.assertIn("R06 stop-rule IDs/order differ", self.preregistration_errors(value))

    def test_source_binding_hash_and_path_drift_fail_closed(self) -> None:
        self.assertEqual(
            [item["id"] for item in self.catalog["source_bindings"]],
            list(SOURCE_BINDINGS),
        )
        value = copy.deepcopy(self.catalog)
        value["source_bindings"][0]["sha256"] = "0" * 64
        self.assertIn(
            "R06 source bindings differ from the frozen evidence bytes",
            self.fixture_errors(value),
        )
        value = copy.deepcopy(self.catalog)
        value["source_bindings"][0]["path"] = "../escape"
        self.assertTrue(
            any("normalized and repository-relative" in item for item in self.fixture_errors(value))
        )

    def test_schema_and_fixture_bindings_are_not_self_selected(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["fixture_catalog"] = self.file_binding(PREREGISTRATION_PATH)
        errors = self.preregistration_errors(value)
        self.assertTrue(any("frozen path" in item for item in errors))

    def test_privacy_fields_and_private_paths_fail_closed(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["account_id"] = "private"
        errors = self.preregistration_errors(value)
        self.assertTrue(any("forbidden private key" in item for item in errors))
        value = copy.deepcopy(self.catalog)
        value["contract_id"] = "/Users/private/fixture"
        errors = self.fixture_errors(value)
        self.assertTrue(any("private path" in item for item in errors))


if __name__ == "__main__":
    unittest.main()
