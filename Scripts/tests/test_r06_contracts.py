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
    AGGREGATE_PROJECT_PATH,
    ABLATION_IDS,
    AUTHORIZATION_BOUNDARY,
    CHECK_IDS,
    CONFORMANCE_LIMITATIONS,
    CONFORMANCE_OBSERVATION,
    CONFORMANCE_PATH,
    CONFORMANCE_PRODUCT_GATE_RESULT,
    CONFORMANCE_RESULT,
    CONFORMANCE_SCHEMA_PATH,
    CONSTRUCTOR_PARAMETERS,
    CURRENT_BYTE_SOURCE_CONTRACT_PATHS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    FIXTURE_CHECK_IDS,
    IMPLEMENTATION_SOURCE,
    MESSAGE_AXES,
    OBSERVATION_POLICY,
    PREDECESSOR,
    PREREGISTRATION_COMMIT,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    PRODUCT_GATE,
    R06ContractVerifier,
    SCORING_CONTRACT,
    SIDECAR_FIELDS,
    SOURCE_BINDINGS,
    SOURCE_CONTRACT_PATHS,
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
        self.conformance = read_json(CONFORMANCE_PATH)

    def preregistration_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(value, errors)
        return errors

    def fixture_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_fixture_semantics(value, errors)
        return errors

    def conformance_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_conformance_semantics(value, errors)
        return errors

    @staticmethod
    def file_binding(relative: Path) -> dict[str, object]:
        payload = (REPOSITORY_ROOT / relative).read_bytes()
        return {
            "path": relative.as_posix(),
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def valid_conformance(self) -> dict[str, object]:
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R06",
            "evidence_kind": "r06_ash_orchestration_contract",
            "source": dict(IMPLEMENTATION_SOURCE),
            "preregistration_binding": self.file_binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": self.file_binding(FIXTURE_CATALOG_PATH),
            "observation_status": dict(CONFORMANCE_OBSERVATION),
            "product_gate_result": dict(CONFORMANCE_PRODUCT_GATE_RESULT),
            "fixture_checks": [
                {"id": identifier, "status": "passed"}
                for identifier in FIXTURE_CHECK_IDS
            ],
            "product_ablations": [
                {
                    "id": identifier,
                    "status": "not_observed",
                    "reason": "no_product_qualified_primary_backend",
                }
                for identifier in ABLATION_IDS
            ],
            "checks": [
                {"id": identifier, "status": "passed"}
                for identifier in CHECK_IDS
            ],
            "result": dict(CONFORMANCE_RESULT),
            "limitations": list(CONFORMANCE_LIMITATIONS),
        }

    def test_repository_preregistration_fixtures_and_conformance_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_conformance(), [])

    def test_records_and_future_conformance_validate_against_schemas(self) -> None:
        cases = (
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.catalog),
            (CONFORMANCE_SCHEMA_PATH, self.conformance),
        )
        for schema_path, value in cases:
            with self.subTest(schema=schema_path.as_posix()):
                self.assertEqual(
                    validate_json_schema_instance(read_json(schema_path), value),
                    [],
                )

    def test_conformance_is_materialized_after_implementation(self) -> None:
        self.assertTrue((REPOSITORY_ROOT / CONFORMANCE_PATH).is_file())
        self.assertEqual(self.conformance, self.valid_conformance())
        self.assertEqual(self.verifier.check_conformance(), [])

    def test_conformance_source_is_exact_and_git_bound(self) -> None:
        errors: list[str] = []
        self.verifier._check_source(
            dict(IMPLEMENTATION_SOURCE), "R06 conformance source", errors
        )
        self.assertEqual(errors, [])

        errors = []
        self.verifier._check_source(
            {"commit": IMPLEMENTATION_SOURCE["commit"], "tree": "1" * 40},
            "R06 conformance source",
            errors,
        )
        self.assertTrue(any("tree differs" in error for error in errors))

        errors = []
        self.verifier._check_source(
            {
                "commit": PREREGISTRATION_COMMIT,
                "tree": IMPLEMENTATION_SOURCE["tree"],
            },
            "R06 conformance source",
            errors,
        )
        self.assertTrue(any("strict descendant" in error for error in errors))

    def test_immutable_source_test_and_docs_current_byte_drift_fails_closed(self) -> None:
        targets = (
            PREREGISTRATION_PATH,
            Path("Mirmir/Modules/UpscalerEngine/R06ASHDecisionContext.swift"),
            Path("MirmirTests/UpscalerEngine/R06ASHDecisionContextTests.swift"),
        )
        for target in targets:
            with self.subTest(target=target.as_posix()):
                original_git_bytes = self.verifier.git_bytes

                def drift_target(*arguments: str) -> object:
                    result = original_git_bytes(*arguments)
                    if arguments == (
                        "show",
                        f"{IMPLEMENTATION_SOURCE['commit']}:{target.as_posix()}",
                    ):
                        return mock.Mock(returncode=0, stdout=b"drift")
                    return result

                errors: list[str] = []
                with mock.patch.object(
                    self.verifier,
                    "git_bytes",
                    side_effect=drift_target,
                ):
                    self.verifier._check_source(
                        dict(IMPLEMENTATION_SOURCE),
                        "R06 conformance source",
                        errors,
                    )
                self.assertTrue(
                    any(target.as_posix() in error for error in errors)
                )

    def test_bound_commit_must_contain_exact_project_bytes(self) -> None:
        original_git_bytes = self.verifier.git_bytes

        def omit_project(*arguments: str) -> object:
            if arguments == (
                "show",
                f"{IMPLEMENTATION_SOURCE['commit']}:{AGGREGATE_PROJECT_PATH.as_posix()}",
            ):
                return mock.Mock(returncode=1, stdout=b"")
            return original_git_bytes(*arguments)

        errors: list[str] = []
        with mock.patch.object(
            self.verifier,
            "git_bytes",
            side_effect=omit_project,
        ):
            self.verifier._check_source(
                dict(IMPLEMENTATION_SOURCE), "R06 conformance source", errors
            )
        self.assertTrue(
            any(AGGREGATE_PROJECT_PATH.as_posix() in error for error in errors)
        )

    def test_generated_project_is_the_only_current_byte_exception(self) -> None:
        self.assertIn(AGGREGATE_PROJECT_PATH, SOURCE_CONTRACT_PATHS)
        self.assertNotIn(
            AGGREGATE_PROJECT_PATH,
            CURRENT_BYTE_SOURCE_CONTRACT_PATHS,
        )
        self.assertTrue(
            all(
                path in CURRENT_BYTE_SOURCE_CONTRACT_PATHS
                for path in SOURCE_CONTRACT_PATHS
                if path != AGGREGATE_PROJECT_PATH
            )
        )

    def test_current_project_references_every_bound_swift_file(self) -> None:
        project_payload = (REPOSITORY_ROOT / AGGREGATE_PROJECT_PATH).read_bytes()
        for path in SOURCE_CONTRACT_PATHS:
            if path.suffix == ".swift":
                self.assertIn(path.name.encode(), project_payload)

    def test_current_project_reference_drift_fails_closed(self) -> None:
        project_path = (REPOSITORY_ROOT / AGGREGATE_PROJECT_PATH).resolve()
        omitted_name = b"R06ASHDecisionContext.swift"
        original_read_bytes = Path.read_bytes

        def omit_reference(path: Path) -> bytes:
            payload = original_read_bytes(path)
            if path.resolve() == project_path:
                return payload.replace(omitted_name, b"R06ASHDecisionContext.missing")
            return payload

        errors: list[str] = []
        with mock.patch.object(Path, "read_bytes", new=omit_reference):
            self.verifier._check_source(
                dict(IMPLEMENTATION_SOURCE), "R06 conformance source", errors
            )
        self.assertTrue(
            any(
                "current project omits" in error
                and omitted_name.decode() in error
                for error in errors
            )
        )

    def test_source_path_set_includes_all_r06_sources_and_tests(self) -> None:
        expected_swift_paths = {
            Path("Mirmir/Modules/UpscalerEngine/R06ASHDecisionContext.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R06ASHMasksAndAblations.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R06ASHOrchestrator.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R06ASHPolicyCatalog.swift"),
            Path("MirmirTests/UpscalerEngine/R06ASHDecisionContextTests.swift"),
            Path("MirmirTests/UpscalerEngine/R06ASHMasksAndAblationsTests.swift"),
            Path("MirmirTests/UpscalerEngine/R06ASHOrchestratorTests.swift"),
            Path("MirmirTests/UpscalerEngine/R06ASHPolicyCatalogTests.swift"),
        }
        self.assertEqual(
            {path for path in SOURCE_CONTRACT_PATHS if path.suffix == ".swift"},
            expected_swift_paths,
        )

    def test_conformance_binding_paths_are_not_self_selected(self) -> None:
        value = self.valid_conformance()
        value["preregistration_binding"] = self.file_binding(FIXTURE_CATALOG_PATH)
        self.assertTrue(
            any("frozen path" in error for error in self.conformance_errors(value))
        )

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

    def test_valid_conformance_is_exactly_blocked_by_product_gate(self) -> None:
        self.assertEqual(self.conformance_errors(self.valid_conformance()), [])
        self.assertEqual(self.conformance["result"], CONFORMANCE_RESULT)
        self.assertEqual(
            self.conformance["product_gate_result"],
            CONFORMANCE_PRODUCT_GATE_RESULT,
        )
        self.assertEqual(
            CONFORMANCE_RESULT["reason"],
            "no_product_qualified_primary_backend",
        )

    def test_deterministic_fixture_checks_and_contract_checks_all_passed(self) -> None:
        self.assertEqual(
            self.conformance["fixture_checks"],
            [
                {"id": identifier, "status": "passed"}
                for identifier in FIXTURE_CHECK_IDS
            ],
        )
        self.assertEqual(
            self.conformance["checks"],
            [{"id": identifier, "status": "passed"} for identifier in CHECK_IDS],
        )
        value = self.valid_conformance()
        value["fixture_checks"][0]["status"] = "not_observed"
        self.assertIn(
            "R06 conformance fixture checks differ",
            self.conformance_errors(value),
        )
        value = self.valid_conformance()
        value["checks"][0]["status"] = "blocked"
        self.assertIn(
            "R06 conformance check results differ",
            self.conformance_errors(value),
        )

    def test_all_six_product_ablations_are_not_observed_for_exact_reason(self) -> None:
        ablations = self.conformance["product_ablations"]
        self.assertEqual([item["id"] for item in ablations], list(ABLATION_IDS))
        self.assertTrue(all(item["status"] == "not_observed" for item in ablations))
        self.assertTrue(
            all(
                item["reason"] == "no_product_qualified_primary_backend"
                for item in ablations
            )
        )
        value = self.valid_conformance()
        value["product_ablations"][0]["reason"] = "simulator_unavailable"
        self.assertIn(
            "R06 conformance product ablations differ",
            self.conformance_errors(value),
        )

    def test_observations_remain_not_observed_and_are_not_blocked_causes(self) -> None:
        self.assertEqual(
            self.conformance["observation_status"],
            CONFORMANCE_OBSERVATION,
        )
        value = self.valid_conformance()
        value["observation_status"]["simulator_execution"] = "observed"
        self.assertIn(
            "R06 conformance observation boundary differs",
            self.conformance_errors(value),
        )
        value = self.valid_conformance()
        value["product_gate_result"]["reason"] = "hardware_not_observed"
        self.assertIn(
            "R06 conformance product gate differs",
            self.conformance_errors(value),
        )

    def test_conformance_cannot_claim_product_default_quality_or_acceptance(self) -> None:
        mutations = (
            ("status", "passed"),
            ("reason", "simulator_unavailable"),
            ("default_backend_id", "fixture.apple.mps_lanczos"),
            ("product_qualification", "claimed"),
            ("quality_claims", "claimed"),
            ("performance_claims", "claimed"),
            ("acceptance", "claimed"),
        )
        for field, replacement in mutations:
            with self.subTest(field=field):
                value = self.valid_conformance()
                value["result"][field] = replacement
                self.assertIn(
                    "R06 conformance result exceeds the authorization boundary",
                    self.conformance_errors(value),
                )

    def test_conformance_limitations_and_top_level_keys_are_closed(self) -> None:
        self.assertEqual(
            self.conformance["limitations"],
            list(CONFORMANCE_LIMITATIONS),
        )
        value = self.valid_conformance()
        value["limitations"].pop()
        self.assertIn(
            "R06 conformance limitations differ from the frozen closure",
            self.conformance_errors(value),
        )
        value = self.valid_conformance()
        value["publication"] = "authorized"
        self.assertIn(
            "R06 conformance top-level keys differ",
            self.conformance_errors(value),
        )

    def test_privacy_fields_and_private_paths_fail_closed(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["account_id"] = "private"
        errors = self.preregistration_errors(value)
        self.assertTrue(any("forbidden private key" in item for item in errors))
        value = copy.deepcopy(self.catalog)
        value["contract_id"] = "/Users/private/fixture"
        errors = self.fixture_errors(value)
        self.assertTrue(any("private path" in item for item in errors))

    def test_nul_and_traversal_paths_are_rejected(self) -> None:
        errors: list[str] = []
        self.assertIsNone(self.verifier._safe_path("bad\x00path", "test", errors))
        self.assertIsNone(self.verifier._safe_path("../escape", "test", errors))
        self.assertTrue(any("NUL" in error for error in errors))
        self.assertTrue(any("repository-relative" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
