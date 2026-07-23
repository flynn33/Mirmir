from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
from io import StringIO
import json
from pathlib import Path
import subprocess
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r09_contracts import (  # noqa: E402
    AUTHORIZATION_PATH,
    AUTHORIZATION_SCHEMA_PATH,
    CHECK_IDS,
    FAMILY_IDS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    POLICY_AUTHORIZATION,
    PREREGISTRATION_PATH,
    PREREGISTRATION_RAW_SHA256,
    PREREGISTRATION_SCHEMA_PATH,
    PREREGISTRATION_SIZE_BYTES,
    R08_ACCEPTANCE_PATH,
    R08_BINDING,
    R08_IMPLEMENTATION_COMMIT,
    R08_IMPLEMENTATION_TREE,
    R08_RAW_SHA256,
    R09ContractVerifier,
    STOP_RULE_IDS,
    main,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


class R09ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R09ContractVerifier(REPOSITORY_ROOT)
        self.authorization = read_json(AUTHORIZATION_PATH)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)

    def test_checked_in_contracts_pass(self) -> None:
        self.assertEqual(self.verifier.check_authorization(), [])
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])
        self.assertEqual(self.verifier.check_roadmap_policy(), [])

    def test_checked_in_instances_match_schemas(self) -> None:
        for schema_path, instance in (
            (AUTHORIZATION_SCHEMA_PATH, self.authorization),
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.catalog),
        ):
            with self.subTest(schema=schema_path):
                self.assertEqual(
                    validate_json_schema_instance(read_json(schema_path), instance), []
                )

    def test_cli_checks_all_contracts(self) -> None:
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = main(["--all"])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        for label in (
            "R09 authorization: PASS",
            "R09 preregistration: PASS",
            "R09 fixtures: PASS",
            "R09 roadmap policy: PASS",
        ):
            self.assertIn(label, stdout.getvalue())

    def test_r08_raw_record_commit_and_tree_are_exact(self) -> None:
        payload = (REPOSITORY_ROOT / R08_ACCEPTANCE_PATH).read_bytes()
        self.assertEqual(len(payload), R08_BINDING["size_bytes"])
        self.assertEqual(hashlib.sha256(payload).hexdigest(), R08_RAW_SHA256)
        self.assertEqual(
            subprocess.run(
                ["git", "show", "-s", "--format=%T", R08_IMPLEMENTATION_COMMIT],
                cwd=REPOSITORY_ROOT,
                capture_output=True,
                check=True,
                text=True,
            ).stdout.strip(),
            R08_IMPLEMENTATION_TREE,
        )

    def test_operator_authorization_binds_accepted_r08(self) -> None:
        self.assertEqual(self.authorization["accepted_r08_binding"], R08_BINDING)
        authorization = self.authorization["authorization"]
        assert isinstance(authorization, dict)
        self.assertEqual(
            authorization["core_ai_pixel_residual"],
            "authorized_for_r09_bounded_experiment",
        )
        self.assertEqual(authorization["phase_status"], "in_progress")

    def test_policy_binding_is_exact(self) -> None:
        policy = read_json(Path(".github/roadmap-alignment-policy.json"))
        self.assertEqual(policy["r09_authorization"], POLICY_AUTHORIZATION)
        roadmap = read_json(
            Path("docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.json")
        )
        authorizations = roadmap["authorizations"]
        assert isinstance(authorizations, dict)
        self.assertEqual(
            authorizations["core_ai_pixel_residual"],
            "authorized_for_r09_bounded_experiment",
        )
        phases = roadmap["phases"]
        assert isinstance(phases, list)
        r09 = next(item for item in phases if isinstance(item, dict) and item.get("id") == "R09")
        self.assertEqual(r09["status"], "in_progress")

    def test_bindings_match_exact_files(self) -> None:
        preregistration_payload = (REPOSITORY_ROOT / PREREGISTRATION_PATH).read_bytes()
        self.assertEqual(len(preregistration_payload), PREREGISTRATION_SIZE_BYTES)
        self.assertEqual(
            hashlib.sha256(preregistration_payload).hexdigest(),
            PREREGISTRATION_RAW_SHA256,
        )
        bindings = [
            (self.preregistration["operator_authorization"], AUTHORIZATION_PATH),
            (self.preregistration["fixture_catalog"], FIXTURE_CATALOG_PATH),
        ]
        schema_bindings = self.preregistration["schema_bindings"]
        assert isinstance(schema_bindings, dict)
        bindings.extend(
            (
                (schema_bindings["operator_authorization"], AUTHORIZATION_SCHEMA_PATH),
                (schema_bindings["preregistration"], PREREGISTRATION_SCHEMA_PATH),
                (schema_bindings["fixture_catalog"], FIXTURE_CATALOG_SCHEMA_PATH),
            )
        )
        for binding, relative in bindings:
            with self.subTest(relative=relative):
                assert isinstance(binding, dict)
                payload = (REPOSITORY_ROOT / relative).read_bytes()
                self.assertEqual(binding["path"], relative.as_posix())
                self.assertEqual(binding["size_bytes"], len(payload))
                self.assertEqual(binding["sha256"], hashlib.sha256(payload).hexdigest())

    def test_fixture_and_rule_ids_are_exact(self) -> None:
        all_ids: list[str] = []
        for family, expected in FAMILY_IDS.items():
            fixtures = self.catalog[family]
            assert isinstance(fixtures, list)
            ids = tuple(item["id"] for item in fixtures if isinstance(item, dict))
            self.assertEqual(ids, expected)
            all_ids.extend(ids)
        self.assertEqual(len(all_ids), len(set(all_ids)))
        checks = self.preregistration["checks"]
        stop_rules = self.preregistration["stop_rules"]
        assert isinstance(checks, list)
        assert isinstance(stop_rules, list)
        self.assertEqual(tuple(item["id"] for item in checks), CHECK_IDS)
        self.assertEqual(tuple(item["id"] for item in stop_rules), STOP_RULE_IDS)

    def test_fixture_numbers_are_non_product_software_inputs(self) -> None:
        parameters = self.catalog["fixture_parameters"]
        assert isinstance(parameters, dict)
        self.assertEqual(
            parameters["fixture_value_scope"],
            "software_test_inputs_not_product_or_quality_thresholds",
        )
        self.assertEqual(parameters["residual_minimum"], -4096)
        self.assertEqual(parameters["residual_maximum"], 4096)
        self.assertEqual(parameters["spatial_width"], 2)
        self.assertEqual(parameters["spatial_height"], 2)

    def test_comparison_methods_are_excluded_and_non_authorizing(self) -> None:
        policy = self.preregistration["acceptance_policy"]
        assert isinstance(policy, dict)
        for key in (
            "comparative_testing",
            "a_b_testing",
            "blinded_testing",
            "ablation_testing",
            "superiority_requirement",
        ):
            self.assertEqual(policy[key], "excluded_not_required_non_authorizing")
        self.assertEqual(policy["acceptance_dependency"], "none")

    def test_native_observations_are_truthfully_not_observed(self) -> None:
        policy = self.preregistration["observation_policy"]
        assert isinstance(policy, dict)
        for key in (
            "xcode27_environment",
            "core_ai_framework_availability",
            "model_asset_availability",
            "native_model_execution",
        ):
            self.assertEqual(policy[key], "not_observed")
        self.assertFalse(policy["unavailable_native_execution_blocks_phase"])

    def test_production_auto_holdout_claims_and_release_remain_unauthorized(self) -> None:
        boundary = self.preregistration["authorization_boundary"]
        assert isinstance(boundary, dict)
        for key in (
            "production_default",
            "auto_mode",
            "holdout",
            "quality_claims",
            "performance_claims",
            "publication",
            "release",
        ):
            self.assertEqual(boundary[key], "not_authorized")

    def test_schema_rejects_unexpected_top_level_properties(self) -> None:
        for schema_path, instance in (
            (AUTHORIZATION_SCHEMA_PATH, self.authorization),
            (PREREGISTRATION_SCHEMA_PATH, self.preregistration),
            (FIXTURE_CATALOG_SCHEMA_PATH, self.catalog),
        ):
            with self.subTest(schema=schema_path):
                mutated = copy.deepcopy(instance)
                mutated["unexpected"] = True
                errors = validate_json_schema_instance(read_json(schema_path), mutated)
                self.assertTrue(any("field is not allowed" in error for error in errors))

    def test_semantic_mutation_fails_closed(self) -> None:
        mutated = copy.deepcopy(self.catalog)
        parameters = mutated["fixture_parameters"]
        assert isinstance(parameters, dict)
        parameters["residual_maximum"] = 4095
        errors: list[str] = []
        from r09_contracts import _semantic_sha256, FIXTURE_CATALOG_SEMANTIC_SHA256

        if _semantic_sha256(mutated) != FIXTURE_CATALOG_SEMANTIC_SHA256:
            errors.append("R09 fixture catalog semantic SHA-256 differs")
        self.assertIn("R09 fixture catalog semantic SHA-256 differs", errors)


if __name__ == "__main__":
    unittest.main()
