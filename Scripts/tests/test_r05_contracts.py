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
from r05_contracts import (  # noqa: E402
    AGGREGATE_PROJECT_PATH,
    AUTHORIZATION_BOUNDARY,
    CHECK_IDS,
    CONFORMANCE_LIMITATIONS,
    CONFORMANCE_PATH,
    CONFORMANCE_RESULT,
    CONFORMANCE_SCHEMA_PATH,
    CONTRACT,
    CURRENT_BYTE_SOURCE_CONTRACT_PATHS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    IMPLEMENTATION_SOURCE,
    NOT_OBSERVED_CHECK_IDS,
    PREDECESSOR,
    PREREGISTRATION_COMMIT,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R05ContractVerifier,
    SOURCE_BINDINGS,
    SOURCE_CONTRACT_PATHS,
    STOP_RULE_IDS,
    SUBJECT_IDS,
    SUBJECT_IDENTITIES,
    TOOLCHAIN_BOUNDARY,
    _semantic_sha256,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


class R05ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R05ContractVerifier(REPOSITORY_ROOT)
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
        subjects = [
            {
                "subject_id": identity[0],
                "execution_status": identity[5],
                "disposition": identity[6],
                "reason": identity[7],
            }
            for identity in SUBJECT_IDENTITIES
        ]
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R05",
            "evidence_kind": "r05_metalfx_suitability_contract",
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
            "subject_results": subjects,
            "checks": [
                {
                    "id": identifier,
                    "status": (
                        "not_observed"
                        if identifier in NOT_OBSERVED_CHECK_IDS
                        else "passed"
                    ),
                }
                for identifier in CHECK_IDS
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
            validate_json_schema_instance(schema, self.valid_conformance()),
            [],
        )

    def test_conformance_record_is_materialized_after_implementation(self) -> None:
        self.assertTrue((REPOSITORY_ROOT / CONFORMANCE_PATH).is_file())
        self.assertEqual(self.verifier.check_conformance(), [])

    def test_conformance_source_is_exact_and_git_bound(self) -> None:
        errors: list[str] = []
        self.verifier._check_source(
            dict(IMPLEMENTATION_SOURCE), "R05 conformance source", errors
        )
        self.assertEqual(errors, [])

        errors = []
        self.verifier._check_source(
            {"commit": IMPLEMENTATION_SOURCE["commit"], "tree": "1" * 40},
            "R05 conformance source",
            errors,
        )
        self.assertTrue(any("tree differs" in error for error in errors))

        errors = []
        self.verifier._check_source(
            {
                "commit": PREREGISTRATION_COMMIT,
                "tree": IMPLEMENTATION_SOURCE["tree"],
            },
            "R05 conformance source",
            errors,
        )
        self.assertTrue(any("strict descendant" in error for error in errors))

    def test_immutable_source_current_byte_drift_fails_closed(self) -> None:
        target = PREREGISTRATION_PATH
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
                dict(IMPLEMENTATION_SOURCE), "R05 conformance source", errors
            )
        self.assertTrue(
            any(target.as_posix() in error for error in errors),
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

    def test_conformance_source_path_set_includes_full_r05_implementation(self) -> None:
        expected_swift_paths = {
            Path("Mirmir/Modules/UpscalerEngine/R05MetalFXContracts.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R05MetalFXColorBridge.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R05MetalFXSpatialDriver.swift"),
            Path("Mirmir/Modules/UpscalerEngine/R05MetalFXSpatialBackend.swift"),
            Path("MirmirTests/R05MetalFXContractsTests.swift"),
            Path("MirmirTests/R05MetalFXColorBridgeTests.swift"),
            Path("MirmirTests/R05MetalFXSpatialDriverTests.swift"),
            Path("MirmirTests/R05MetalFXSpatialBackendTests.swift"),
        }
        self.assertTrue(expected_swift_paths <= set(SOURCE_CONTRACT_PATHS))

    def test_conformance_binding_paths_are_not_self_selected(self) -> None:
        value = self.valid_conformance()
        value["preregistration_binding"] = self.file_binding(FIXTURE_CATALOG_PATH)
        self.assertTrue(
            any("frozen path" in error for error in self.conformance_errors(value))
        )

    def test_predecessor_binding_is_exact(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        errors: list[str] = []
        self.verifier._check_predecessor(value, errors)
        self.assertTrue(any("exact diagnostic-only R04 closure" in error for error in errors))

    def test_predecessor_result_and_acceptance_boundary_are_frozen(self) -> None:
        self.assertEqual(PREDECESSOR["predecessor_result"], "diagnostic_only")
        self.assertEqual(PREDECESSOR["acceptance_state"], "not_claimed")
        self.assertIsNone(PREDECESSOR["accepted_merge_commit"])

    def test_toolchain_boundary_is_frozen(self) -> None:
        self.assertEqual(self.preregistration["toolchain_boundary"], TOOLCHAIN_BOUNDARY)
        value = copy.deepcopy(self.preregistration)
        value["toolchain_boundary"]["spatial_runtime_floor"] = "macOS 12.0"
        self.assertIn("R05 toolchain boundary differs", self.preregistration_errors(value))

    def test_authorization_boundary_is_frozen(self) -> None:
        self.assertEqual(
            self.preregistration["authorization_boundary"],
            AUTHORIZATION_BOUNDARY,
        )
        value = copy.deepcopy(self.preregistration)
        value["authorization_boundary"]["production_default"] = "enabled"
        self.assertIn(
            "R05 authorization boundary differs",
            self.preregistration_errors(value),
        )

    def test_metalfx_contract_is_frozen(self) -> None:
        self.assertEqual(self.preregistration["contract"], CONTRACT)
        value = copy.deepcopy(self.preregistration)
        value["contract"]["color_bridge"] = "nv12_direct"
        self.assertIn(
            "R05 MetalFX suitability contract differs",
            self.preregistration_errors(value),
        )

    def test_subject_matrix_contains_exact_routes_and_rejections(self) -> None:
        subjects = self.preregistration["subjects"]
        self.assertEqual([item["id"] for item in subjects], list(SUBJECT_IDS))
        self.assertEqual(
            [item["initial_status"] for item in subjects],
            ["not_observed", "not_observed"] + ["contract_rejected"] * 5,
        )
        self.assertEqual(
            [item["initial_disposition"] for item in subjects[2:]],
            ["rejected_for_decoded_video"] * 5,
        )

    def test_check_and_stop_rule_order_is_closed(self) -> None:
        self.assertEqual(
            [item["id"] for item in self.preregistration["checks"]],
            list(CHECK_IDS),
        )
        self.assertEqual(
            [item["id"] for item in self.preregistration["stop_rules"]],
            list(STOP_RULE_IDS),
        )

    def test_source_binding_hash_drift_fails_closed(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["source_bindings"][0]["sha256"] = "1" * 64
        self.assertTrue(
            any("frozen evidence bytes" in error for error in self.fixture_errors(value))
        )

    def test_source_binding_matrix_includes_negative_predecessor_records(self) -> None:
        observed = {
            item["id"]: (item["path"], item["size_bytes"], item["sha256"])
            for item in self.catalog["source_bindings"]
        }
        self.assertEqual(observed, SOURCE_BINDINGS)
        self.assertIn("r03_baseline_conformance", observed)
        self.assertIn("r04_integration_conformance", observed)

    def test_route_matrix_is_exact(self) -> None:
        routes = self.catalog["routes"]
        self.assertEqual(len(routes), 7)
        self.assertEqual(routes[0]["scale_numerator"], 3)
        self.assertEqual(routes[0]["scale_denominator"], 2)
        self.assertEqual(routes[1]["scale_numerator"], 2)
        self.assertEqual(routes[-1]["scale_numerator"], 1)
        self.assertEqual(routes[-1]["gate"], "missing_renderer_inputs_rejected")

    def test_color_bridge_contract_is_explicit_and_left_sited(self) -> None:
        color = self.catalog["color_contract"]
        self.assertEqual(color["pixel_format"], "420v")
        self.assertEqual(color["processing_space"], "linear_bt709")
        self.assertEqual(color["bridge_texture_format"], "rgba16Float")
        self.assertEqual(color["chroma_location"], "left")
        self.assertIn("left_cosited", color["chroma_upsampling"])
        self.assertIn("left_cosited", color["chroma_downsampling"])

    def test_unknown_scenario_reference_fails(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["scenarios"][0]["subject_ids"][0] = "r05.unknown"
        self.assertTrue(
            any("unknown subject" in error for error in self.fixture_errors(value))
        )

    def test_semantic_hash_detects_description_drift(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["checks"][0]["description"] = "mutated"
        self.assertNotEqual(
            _semantic_sha256(value),
            _semantic_sha256(self.preregistration),
        )
        self.assertIn(
            "R05 preregistration semantic contract differs",
            self.preregistration_errors(value),
        )

    def test_valid_conformance_is_exactly_contract_only(self) -> None:
        self.assertEqual(self.conformance_errors(self.valid_conformance()), [])

    def test_conformance_subject_results_are_frozen(self) -> None:
        value = self.valid_conformance()
        value["subject_results"][0]["reason"] = (
            "observed_contract_only_no_quality_or_performance_claim"
        )
        self.assertIn(
            "R05 conformance subject results differ from the frozen closure",
            self.conformance_errors(value),
        )

    def test_conformance_check_results_are_frozen(self) -> None:
        value = self.valid_conformance()
        value["checks"][0]["status"] = "not_observed"
        self.assertIn(
            "R05 conformance check results differ from the frozen closure",
            self.conformance_errors(value),
        )

    def test_only_runtime_quality_and_identity_checks_are_not_observed(self) -> None:
        checks = self.valid_conformance()["checks"]
        observed_not_observed = {
            item["id"] for item in checks if item["status"] == "not_observed"
        }
        self.assertEqual(observed_not_observed, set(NOT_OBSERVED_CHECK_IDS))
        self.assertEqual(len(checks), 20)

    def test_conformance_cannot_name_a_default(self) -> None:
        value = self.valid_conformance()
        value["result"]["default_backend_id"] = SUBJECT_IDS[0]
        self.assertIn(
            "R05 conformance result exceeds the authorization boundary",
            self.conformance_errors(value),
        )

    def test_conformance_result_cannot_claim_passed(self) -> None:
        value = self.valid_conformance()
        value["result"]["status"] = "passed"
        self.assertIn(
            "R05 conformance result exceeds the authorization boundary",
            self.conformance_errors(value),
        )

    def test_conformance_observation_boundary_is_frozen(self) -> None:
        value = self.valid_conformance()
        value["observation_status"]["simulator_execution"] = "observed"
        self.assertIn(
            "R05 conformance observation boundary differs",
            self.conformance_errors(value),
        )

    def test_conformance_limitations_are_frozen(self) -> None:
        value = self.valid_conformance()
        value["limitations"].pop()
        self.assertIn(
            "R05 conformance limitations differ from the frozen closure",
            self.conformance_errors(value),
        )

    def test_nul_and_traversal_paths_are_rejected(self) -> None:
        errors: list[str] = []
        self.assertIsNone(self.verifier._safe_path("bad\x00path", "test", errors))
        self.assertIsNone(self.verifier._safe_path("../escape", "test", errors))
        self.assertTrue(any("NUL" in error for error in errors))
        self.assertTrue(any("repository-relative" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
