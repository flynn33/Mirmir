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
from r08_contracts import (  # noqa: E402
    CHECK_IDS,
    FAMILY_IDS,
    FALLBACK_TRIGGERS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SCHEMA_PATH,
    OUTPUT_HEAD_IDS,
    PREDECESSOR,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SCHEMA_PATH,
    R08ContractVerifier,
    STOP_RULE_IDS,
    main,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def frozen_leaf_paths(
    value: object, prefix: tuple[object, ...] = ()
) -> list[tuple[object, ...]]:
    if isinstance(value, dict):
        if not value:
            return [prefix]
        result: list[tuple[object, ...]] = []
        for key, nested in value.items():
            result.extend(frozen_leaf_paths(nested, prefix + (key,)))
        return result
    if isinstance(value, list):
        if not value:
            return [prefix]
        result = []
        for index, nested in enumerate(value):
            result.extend(frozen_leaf_paths(nested, prefix + (index,)))
        return result
    return [prefix]


def mutate_leaf(value: object) -> object:
    if value is None:
        return "mutated"
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value + 1
    if isinstance(value, str):
        return value + ".mutated"
    raise AssertionError(f"unsupported leaf type: {type(value)!r}")


def set_path(value: object, path: tuple[object, ...]) -> None:
    target = value
    for component in path[:-1]:
        target = target[component]  # type: ignore[index]
    component = path[-1]
    target[component] = mutate_leaf(target[component])  # type: ignore[index]


class R08ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R08ContractVerifier(REPOSITORY_ROOT)
        self.preregistration = read_json(PREREGISTRATION_PATH)
        self.catalog = read_json(FIXTURE_CATALOG_PATH)
        self.preregistration_schema = read_json(PREREGISTRATION_SCHEMA_PATH)
        self.catalog_schema = read_json(FIXTURE_CATALOG_SCHEMA_PATH)

    def preregistration_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_preregistration_semantics(value, errors)
        return errors

    def fixture_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_fixture_semantics(value, errors)
        return errors

    def fixture_map(self, family: str) -> dict[str, dict[str, object]]:
        fixtures = self.catalog[family]
        assert isinstance(fixtures, list)
        return {
            item["id"]: item
            for item in fixtures
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }

    def test_checked_in_contracts_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])

    def test_checked_in_instances_match_schemas(self) -> None:
        self.assertEqual(
            validate_json_schema_instance(
                self.preregistration_schema, self.preregistration
            ),
            [],
        )
        self.assertEqual(
            validate_json_schema_instance(self.catalog_schema, self.catalog), []
        )

    def test_cli_checks_all_contracts(self) -> None:
        stdout = StringIO()
        stderr = StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = main(["--all"])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("R08 preregistration: PASS", stdout.getvalue())
        self.assertIn("R08 fixtures: PASS", stdout.getvalue())

    def test_predecessor_is_exact_accepted_r07_merge(self) -> None:
        self.assertEqual(self.preregistration["predecessor_binding"], PREDECESSOR)
        commit = PREDECESSOR["merge_commit"]
        tree = subprocess.run(
            ["git", "show", "-s", "--format=%T", commit],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            check=True,
            text=True,
        ).stdout.strip()
        self.assertEqual(tree, PREDECESSOR["merge_tree"])
        parents = subprocess.run(
            ["git", "show", "-s", "--format=%P", commit],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            check=True,
            text=True,
        ).stdout.split()
        self.assertEqual(len(parents), 2)
        self.assertEqual(
            subprocess.run(
                ["git", "merge-base", "--is-ancestor", commit, "HEAD"],
                cwd=REPOSITORY_ROOT,
                check=False,
            ).returncode,
            0,
        )

    def test_predecessor_mutation_fails_closed(self) -> None:
        for key in PREDECESSOR:
            with self.subTest(key=key):
                mutated = copy.deepcopy(self.preregistration)
                predecessor = mutated["predecessor_binding"]
                assert isinstance(predecessor, dict)
                predecessor[key] = mutate_leaf(predecessor[key])
                self.assertTrue(
                    any("predecessor binding differs" in error for error in self.preregistration_errors(mutated))
                )

    def test_binding_hashes_match_exact_files(self) -> None:
        fixture_binding = self.preregistration["fixture_catalog"]
        schema_bindings = self.preregistration["schema_bindings"]
        assert isinstance(fixture_binding, dict)
        assert isinstance(schema_bindings, dict)
        cases = [
            (fixture_binding, FIXTURE_CATALOG_PATH),
            (schema_bindings["preregistration"], PREREGISTRATION_SCHEMA_PATH),
            (schema_bindings["fixture_catalog"], FIXTURE_CATALOG_SCHEMA_PATH),
        ]
        for recorded, relative in cases:
            with self.subTest(relative=relative):
                assert isinstance(recorded, dict)
                payload = (REPOSITORY_ROOT / relative).read_bytes()
                self.assertEqual(recorded["path"], relative.as_posix())
                self.assertEqual(recorded["size_bytes"], len(payload))
                self.assertEqual(recorded["sha256"], hashlib.sha256(payload).hexdigest())

    def test_schema_rejects_unexpected_top_level_properties(self) -> None:
        for schema, instance in (
            (self.preregistration_schema, self.preregistration),
            (self.catalog_schema, self.catalog),
        ):
            with self.subTest(title=schema["title"]):
                mutated = copy.deepcopy(instance)
                mutated["unexpected"] = True
                errors = validate_json_schema_instance(schema, mutated)
                self.assertTrue(any("field is not allowed" in error for error in errors))

    def test_every_fixture_leaf_is_semantically_frozen(self) -> None:
        for path in frozen_leaf_paths(self.catalog):
            with self.subTest(path=path):
                mutated = copy.deepcopy(self.catalog)
                set_path(mutated, path)
                self.assertTrue(
                    any("semantic SHA-256 differs" in error for error in self.fixture_errors(mutated))
                )

    def test_each_preregistration_contract_section_is_frozen(self) -> None:
        sections = (
            "observation_policy",
            "operator_acceptance_override",
            "analysis_service_contract",
            "model_io_contract",
            "calibrated_output_contract",
            "scheduling_contract",
            "ash_context_integration_contract",
            "lifecycle_contract",
            "deterministic_fallback_contract",
            "authorization_boundary",
        )
        for section in sections:
            value = self.preregistration[section]
            path = frozen_leaf_paths(value, (section,))[0]
            with self.subTest(section=section, path=path):
                mutated = copy.deepcopy(self.preregistration)
                set_path(mutated, path)
                self.assertTrue(
                    any("semantic SHA-256 differs" in error for error in self.preregistration_errors(mutated))
                )

    def test_comparative_and_blinded_ablation_gates_are_superseded(self) -> None:
        override = self.preregistration["operator_acceptance_override"]
        assert isinstance(override, dict)
        self.assertEqual(override["comparative_requirement"], "superseded_not_required")
        self.assertEqual(override["blinded_ablation_requirement"], "superseded_not_required")
        self.assertEqual(
            override["acceptance_authority"],
            "deterministic_software_function_verification_only",
        )
        fixture = self.fixture_map("authorization_fixtures")[
            "authorization-comparison-superseded"
        ]
        expected = fixture["expected"]
        assert isinstance(expected, dict)
        self.assertTrue(expected["software_verification_may_continue"])

    def test_native_and_model_execution_are_truthfully_not_observed(self) -> None:
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
        self.assertEqual(policy["fabricated_native_or_model_results"], "forbidden")

    def test_all_nine_calibrated_output_heads_are_exact(self) -> None:
        contract = self.preregistration["calibrated_output_contract"]
        assert isinstance(contract, dict)
        heads = contract["output_heads"]
        assert isinstance(heads, list)
        self.assertEqual(tuple(item["id"] for item in heads), OUTPUT_HEAD_IDS)
        self.assertEqual(contract["head_completeness"], "exactly_once_each")
        self.assertEqual(contract["sample_domain"], {"encoding": "unsigned_q15", "minimum": 0, "maximum": 32767})

    def test_no_pixel_output_or_model_decision_authority(self) -> None:
        service = self.preregistration["analysis_service_contract"]
        integration = self.preregistration["ash_context_integration_contract"]
        authorization = self.preregistration["authorization_boundary"]
        assert isinstance(service, dict)
        assert isinstance(integration, dict)
        assert isinstance(authorization, dict)
        self.assertEqual(service["service_role"], "analysis_only")
        self.assertEqual(service["decision_authority"], "none_ash_policy_remains_authoritative")
        self.assertEqual(service["pixel_output"], "forbidden")
        self.assertEqual(service["pixel_control"], "forbidden")
        self.assertEqual(integration["pixel_payload"], "forbidden")
        self.assertEqual(authorization["pixel_output"], "forbidden")
        self.assertEqual(authorization["pixel_control"], "forbidden")

    def test_scheduling_identity_state_cancellation_and_budgets_are_frozen(self) -> None:
        scheduling = self.preregistration["scheduling_contract"]
        lifecycle = self.preregistration["lifecycle_contract"]
        assert isinstance(scheduling, dict)
        assert isinstance(lifecycle, dict)
        self.assertEqual(scheduling["periodic_proxy_interval_frames"], 12)
        self.assertEqual(scheduling["trigger_precedence"], ["ash_requested_frame", "keyframe", "periodic_proxy_frame"])
        self.assertEqual(lifecycle["memory_budget_bytes"], 67108864)
        self.assertEqual(lifecycle["latency_budget_milliseconds"], 20)
        self.assertEqual(lifecycle["cancellation"], "no_result_no_context_mutation_no_state_commit")

    def test_fallback_trigger_set_and_fixtures_are_complete(self) -> None:
        contract = self.preregistration["deterministic_fallback_contract"]
        assert isinstance(contract, dict)
        self.assertEqual(tuple(contract["triggers"]), FALLBACK_TRIGGERS)
        fixtures = self.fixture_map("fallback_fixtures")
        self.assertEqual(tuple(fixtures), FAMILY_IDS["fallback_fixtures"])
        for trigger in FALLBACK_TRIGGERS:
            fixture = fixtures[f"fallback-{trigger.replace('_', '-')}"]
            expected = fixture["expected"]
            assert isinstance(expected, dict)
            self.assertEqual(expected["result"], "deterministic_analyzer_only")
            self.assertEqual(expected["reason_identity"], trigger)
            self.assertEqual(expected["pixel_effect"], "none")

    def test_check_and_stop_rule_ids_are_exact(self) -> None:
        checks = self.preregistration["checks"]
        stop_rules = self.preregistration["stop_rules"]
        assert isinstance(checks, list)
        assert isinstance(stop_rules, list)
        self.assertEqual(tuple(item["id"] for item in checks), CHECK_IDS)
        self.assertEqual(tuple(item["id"] for item in stop_rules), STOP_RULE_IDS)

    def test_production_auto_holdout_claims_and_r09_remain_forbidden(self) -> None:
        authorization = self.preregistration["authorization_boundary"]
        assert isinstance(authorization, dict)
        self.assertEqual(authorization["production_default"], "not_enabled")
        self.assertEqual(authorization["auto_mode"], "blocked")
        self.assertEqual(authorization["holdout"], "blocked")
        self.assertEqual(authorization["quality_claims"], "forbidden")
        self.assertEqual(authorization["performance_claims"], "forbidden")
        self.assertEqual(
            authorization["r09_residual_execution"],
            "forbidden_requires_separate_operator_authorization",
        )

    def test_private_path_and_email_are_rejected(self) -> None:
        for private_value, message in (
            ("/Users/operator/private/model.aimodel", "private path"),
            ("operator@example.com", "email address"),
        ):
            with self.subTest(private_value=private_value):
                mutated = copy.deepcopy(self.catalog)
                fixture = mutated["authorization_fixtures"]
                assert isinstance(fixture, list)
                fixture[0]["inputs"]["private_value"] = private_value
                errors = self.fixture_errors(mutated)
                self.assertTrue(any(message in error for error in errors))

    def test_fixture_family_ids_and_order_are_exact(self) -> None:
        all_ids: list[str] = []
        for family, expected_ids in FAMILY_IDS.items():
            fixtures = self.catalog[family]
            assert isinstance(fixtures, list)
            actual = tuple(item["id"] for item in fixtures)
            self.assertEqual(actual, expected_ids)
            all_ids.extend(actual)
        self.assertEqual(len(all_ids), len(set(all_ids)))


if __name__ == "__main__":
    unittest.main()
