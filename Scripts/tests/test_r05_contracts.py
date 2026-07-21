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
from r05_contracts import (  # noqa: E402
    AUTHORIZATION_BOUNDARY,
    CHECK_IDS,
    CONFORMANCE_PATH,
    CONFORMANCE_SCHEMA_PATH,
    CONTRACT,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    PREDECESSOR,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R05ContractVerifier,
    SOURCE_BINDINGS,
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

    def valid_future_conformance(self) -> dict[str, object]:
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
            "source": {"commit": "a" * 40, "tree": "b" * 40},
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
                {"id": identifier, "status": "not_observed"}
                for identifier in CHECK_IDS
            ],
            "result": {
                "status": "diagnostic_only",
                "disposition": "diagnostic_only",
                "default_backend_id": None,
                "product_qualification": "not_claimed",
                "quality_claims": "forbidden",
                "performance_claims": "forbidden",
                "acceptance": "not_claimed",
            },
            "limitations": [
                "Native MetalFX execution, quality, and performance are not observed."
            ],
        }

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
            validate_json_schema_instance(schema, self.valid_future_conformance()),
            [],
        )

    def test_conformance_is_not_materialized_at_preregistration(self) -> None:
        self.assertFalse((REPOSITORY_ROOT / CONFORMANCE_PATH).exists())

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

    def test_conformance_cannot_name_a_default(self) -> None:
        value = self.valid_future_conformance()
        value["result"]["default_backend_id"] = SUBJECT_IDS[0]
        errors: list[str] = []
        self.verifier._check_conformance_semantics(value, errors)
        self.assertIn(
            "R05 conformance result exceeds the authorization boundary",
            errors,
        )

    def test_nul_and_traversal_paths_are_rejected(self) -> None:
        errors: list[str] = []
        self.assertIsNone(self.verifier._safe_path("bad\x00path", "test", errors))
        self.assertIsNone(self.verifier._safe_path("../escape", "test", errors))
        self.assertTrue(any("NUL" in error for error in errors))
        self.assertTrue(any("repository-relative" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
