from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r03_contracts import (  # noqa: E402
    BACKEND_CHECK_IDS,
    BACKEND_IDS,
    CHECK_IDS,
    CONFORMANCE_LIMITATIONS,
    CONFORMANCE_OBSERVATION_STATUS_FAILED,
    CONFORMANCE_OBSERVATION_STATUS_PASSED,
    CONFORMANCE_SCHEMA_PATH,
    DISPOSITION_REASONS,
    FIXTURE_CATALOG_PATH,
    FIXTURE_CATALOG_SEMANTIC_SHA256,
    METRIC_CONTRACTS,
    MEDIA_TRANSACTION_FAILED_CHECK_IDS,
    PASSING_METRIC_VALUES,
    PREDECESSOR,
    PREREGISTRATION_PATH,
    PREREGISTRATION_SEMANTIC_SHA256,
    PREREGISTRATION_SCHEMA_PATH,
    R03ContractVerifier,
    SOURCE_CONTRACT_PATHS,
    SUPPORT_STAGE_APPLICABLE_METRIC_IDS,
    _semantic_sha256,
)


class R03SourceGitStubVerifier(R03ContractVerifier):
    source_commit = "a" * 40
    source_tree = "b" * 40
    contains_contract_bytes = True

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        if arguments[0] == "cat-file" and self.source_commit in arguments[-1]:
            return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")
        if arguments[0] == "rev-parse" and self.source_commit in arguments[-1]:
            return subprocess.CompletedProcess(
                arguments, 0, stdout=f"{self.source_tree}\n", stderr=""
            )
        if arguments[0] == "merge-base" and self.source_commit in arguments:
            return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")
        return super().git(*arguments)

    def git_bytes(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        prefix = f"{self.source_commit}:"
        if arguments[0] == "show" and arguments[1].startswith(prefix):
            relative = Path(arguments[1][len(prefix) :])
            if not self.contains_contract_bytes and relative == SOURCE_CONTRACT_PATHS[0]:
                return subprocess.CompletedProcess(arguments, 1, stdout=b"", stderr=b"")
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout=(REPOSITORY_ROOT / relative).read_bytes(),
                stderr=b"",
            )
        return super().git_bytes(*arguments)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


class R03ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R03ContractVerifier(REPOSITORY_ROOT)
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

    def valid_conformance(self) -> dict[str, object]:
        backend_results = []
        for backend_id in BACKEND_IDS:
            backend_results.append(
                {
                    "backend_id": backend_id,
                    "execution_status": "not_observed",
                    "disposition": "not_observed",
                    "reason": DISPOSITION_REASONS["not_observed"],
                    "check_ids": list(BACKEND_CHECK_IDS[backend_id]),
                    "metric_results": [
                        {
                            "id": metric_id,
                            "unit": unit,
                            "status": "not_observed",
                            "value": None,
                            "passed": None,
                        }
                        for metric_id, unit, _operator, _threshold, _allowed in METRIC_CONTRACTS
                    ],
                }
            )
        return {
            "schema_version": "1.0.0",
            "roadmap_version": "1.0.1",
            "phase_id": "R03",
            "evidence_kind": "r03_deterministic_baseline_matrix",
            "source": {
                "commit": R03SourceGitStubVerifier.source_commit,
                "tree": R03SourceGitStubVerifier.source_tree,
            },
            "preregistration_binding": self.file_binding(PREREGISTRATION_PATH),
            "fixture_catalog_binding": self.file_binding(FIXTURE_CATALOG_PATH),
            "observation_status": dict(CONFORMANCE_OBSERVATION_STATUS_PASSED),
            "backend_results": backend_results,
            "checks": [{"id": check_id, "status": "passed"} for check_id in CHECK_IDS],
            "result": {
                "status": "passed",
                "default_backend_id": None,
                "product_qualification": "not_claimed",
                "performance_claims": "forbidden",
            },
            "limitations": list(CONFORMANCE_LIMITATIONS),
        }

    def blocked_conformance(self) -> dict[str, object]:
        record = self.valid_conformance()
        record["observation_status"] = dict(CONFORMANCE_OBSERVATION_STATUS_FAILED)
        record["result"]["status"] = "blocked"
        for check in record["checks"]:
            if check["id"] in MEDIA_TRANSACTION_FAILED_CHECK_IDS:
                check["status"] = "failed"
        return record

    @staticmethod
    def make_observed(backend: dict[str, object], disposition: str) -> None:
        backend["execution_status"] = "observed"
        backend["disposition"] = disposition
        backend["reason"] = DISPOSITION_REASONS[disposition]
        backend["metric_results"] = [
            {
                "id": metric_id,
                "unit": unit,
                "status": "measured",
                "value": PASSING_METRIC_VALUES[metric_id],
                "passed": True,
            }
            for metric_id, unit, _operator, _threshold, _allowed in METRIC_CONTRACTS
        ]

    @classmethod
    def make_observed_support(cls, backend: dict[str, object]) -> None:
        cls.make_observed(backend, "diagnostic_only")
        for metric in backend["metric_results"]:
            if metric["id"] not in SUPPORT_STAGE_APPLICABLE_METRIC_IDS:
                metric.update(status="not_applicable", value=None, passed=None)

    def conformance_errors(self, value: dict[str, object]) -> list[str]:
        errors: list[str] = []
        self.verifier._check_conformance_semantics(value, errors)
        return errors

    def test_repository_preregistration_and_fixtures_pass(self) -> None:
        self.assertEqual(self.verifier.check_preregistration(), [])
        self.assertEqual(self.verifier.check_fixtures(), [])

    def test_predecessor_binding_is_exact(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["predecessor_binding"]["closure_tree"] = "1" * 40
        errors: list[str] = []
        self.verifier._check_predecessor(value, errors)
        self.assertTrue(any("exact local R02 closure" in error for error in errors))

    def test_predecessor_merge_acceptance_cannot_be_inferred(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["predecessor_binding"]["accepted_merge_commit"] = "1" * 40
        errors: list[str] = []
        self.verifier._check_predecessor(value, errors)
        self.assertTrue(errors)

    def test_observation_override_cannot_skip_software_conformance(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["observation_policy"]["deterministic_software_conformance"] = "not_observed"
        self.assertIn(
            "R03 observation policy differs from the operator override",
            self.preregistration_errors(value),
        )

    def test_performance_claims_remain_forbidden(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["authorization_boundary"]["performance_claims"] = "allowed"
        self.assertIn("R03 authorization boundary differs", self.preregistration_errors(value))

    def test_backend_order_and_roles_are_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["backend_matrix"][0]["qualification_role"] = "production_default"
        self.assertIn("R03 backend role matrix differs", self.fixture_errors(value))

    def test_support_stage_cannot_enter_default_pool(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["backend_matrix"][-1]["product_default_eligibility"] = (
            "candidate_after_observed_qualification"
        )
        self.assertIn("R03 backend role matrix differs", self.fixture_errors(value))

    def test_source_hash_drift_fails(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["source_bindings"][0]["sha256"] = "1" * 64
        errors = self.fixture_errors(value)
        self.assertTrue(any("source bindings differ" in error for error in errors))
        self.assertTrue(any("sha256 differs" in error for error in errors))

    def test_fixture_order_is_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["fixtures"].reverse()
        self.assertIn("R03 fixture IDs/order differ", self.fixture_errors(value))

    def test_analytic_member_must_exist_in_bound_manifest(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["fixtures"][2]["member_ids"][0] = "missing-analytic-fixture"
        self.assertIn("R03 fixture members differ", self.fixture_errors(value))

    def test_metric_ids_and_order_are_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["metrics"][0]["id"] = "mutated_metric"
        self.assertIn("R03 metric IDs/order differ", self.preregistration_errors(value))

    def test_metric_threshold_is_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["metrics"][14]["threshold"] = 0.5
        self.assertIn(
            "R03 preregistration semantic contract differs",
            self.preregistration_errors(value),
        )

    def test_check_ids_and_order_are_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["checks"][0]["id"] = "mutated_check"
        self.assertIn("R03 check IDs/order differ", self.preregistration_errors(value))

    def test_check_description_is_frozen(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["checks"][0]["description"] = "mutated"
        self.assertIn(
            "R03 preregistration semantic contract differs",
            self.preregistration_errors(value),
        )

    def test_route_definition_is_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["routes"][0]["output_dimensions"]["width"] = 1918
        self.assertIn(
            "R03 fixture catalog semantic contract differs",
            self.fixture_errors(value),
        )

    def test_backend_framework_and_fixture_coverage_are_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["backend_matrix"][0]["framework"] = "copy"
        value["backend_matrix"][0]["fixture_ids"].pop()
        self.assertIn(
            "R03 fixture catalog semantic contract differs",
            self.fixture_errors(value),
        )

    def test_scenario_arrays_are_frozen(self) -> None:
        value = copy.deepcopy(self.catalog)
        value["scenarios"][0]["required_check_ids"].pop()
        self.assertIn(
            "R03 fixture catalog semantic contract differs",
            self.fixture_errors(value),
        )

    def test_nul_path_is_rejected_without_exception(self) -> None:
        errors: list[str] = []
        self.assertIsNone(self.verifier._safe_path("bad\x00path", "test", errors))
        self.assertTrue(any("NUL" in error for error in errors))

    def test_preregistration_schema_rejects_extra_fields(self) -> None:
        value = copy.deepcopy(self.preregistration)
        value["unexpected"] = True
        schema = read_json(PREREGISTRATION_SCHEMA_PATH)
        self.assertTrue(validate_json_schema_instance(schema, value))

    def test_conformance_schema_closes_observation_status(self) -> None:
        schema = read_json(CONFORMANCE_SCHEMA_PATH)
        observation = schema["properties"]["observation_status"]
        self.assertIs(observation["additionalProperties"], False)

    def test_conformance_schema_closes_metric_results(self) -> None:
        schema = read_json(CONFORMANCE_SCHEMA_PATH)
        metric_result = schema["$defs"]["metricResult"]
        self.assertIs(metric_result["additionalProperties"], False)

    def test_incompatible_media_route_requires_fail_closed_record(self) -> None:
        record = self.valid_conformance()
        schema = read_json(CONFORMANCE_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, record), [])
        self.assertEqual(self.conformance_errors(record), [])
        errors: list[str] = []
        self.verifier._check_media_transaction_closure(record, errors)
        self.assertTrue(any("requires a blocked result" in error for error in errors))

        blocked = self.blocked_conformance()
        self.assertEqual(validate_json_schema_instance(schema, blocked), [])
        self.assertEqual(self.conformance_errors(blocked), [])
        errors = []
        self.verifier._check_media_transaction_closure(blocked, errors)
        self.assertEqual(errors, [])

    def test_media_route_preflight_rejects_observation_and_check_drift(self) -> None:
        mutations = []

        passed = self.blocked_conformance()
        passed["result"]["status"] = "passed"
        mutations.append(("passed_result", passed))

        missing_check = self.blocked_conformance()
        failed = next(
            check
            for check in missing_check["checks"]
            if check["id"] in MEDIA_TRANSACTION_FAILED_CHECK_IDS
        )
        failed["status"] = "passed"
        mutations.append(("missing_failed_check", missing_check))

        observed = self.blocked_conformance()
        observed["backend_results"][0]["execution_status"] = "observed"
        mutations.append(("observed_subject", observed))

        measured = self.blocked_conformance()
        measured["backend_results"][0]["metric_results"][0].update(
            status="measured", value=0, passed=True
        )
        mutations.append(("measured_metric", measured))

        for name, mutation in mutations:
            with self.subTest(name=name):
                errors: list[str] = []
                self.verifier._check_media_transaction_closure(mutation, errors)
                self.assertTrue(errors)

    def test_conformance_binding_path_is_not_self_selected(self) -> None:
        binding = self.file_binding(FIXTURE_CATALOG_PATH)
        errors: list[str] = []
        self.verifier._check_exact_binding(
            binding,
            PREREGISTRATION_PATH,
            "conformance.preregistration_binding",
            errors,
        )
        self.assertTrue(any("frozen path" in error for error in errors))

    def test_conformance_source_is_git_bound_and_contains_frozen_contract(self) -> None:
        verifier = R03SourceGitStubVerifier(REPOSITORY_ROOT)
        source = {
            "commit": verifier.source_commit,
            "tree": verifier.source_tree,
        }
        errors: list[str] = []
        verifier._check_source(source, "R03 conformance source", errors)
        self.assertEqual(errors, [])
        verifier.contains_contract_bytes = False
        errors = []
        verifier._check_source(source, "R03 conformance source", errors)
        self.assertTrue(any("frozen R03 contract bytes" in error for error in errors))
        errors = []
        verifier._check_source(
            {"commit": PREDECESSOR["closure_commit"], "tree": verifier.source_tree},
            "R03 conformance source",
            errors,
        )
        self.assertTrue(any("strict descendant" in error for error in errors))

    def test_conformance_exact_check_and_metric_matrices_are_required(self) -> None:
        mutations = (
            ("missing_check", lambda value: value["checks"].pop()),
            ("unknown_check", lambda value: value["checks"][0].update(id="unknown")),
            (
                "missing_metric",
                lambda value: value["backend_results"][0]["metric_results"].pop(),
            ),
            (
                "unknown_metric",
                lambda value: value["backend_results"][0]["metric_results"][0].update(
                    id="unknown"
                ),
            ),
            (
                "missing_backend_check",
                lambda value: value["backend_results"][0]["check_ids"].pop(),
            ),
        )
        for name, mutate in mutations:
            with self.subTest(name=name):
                record = self.valid_conformance()
                mutate(record)
                self.assertTrue(self.conformance_errors(record))

    def test_conformance_contradictions_are_rejected(self) -> None:
        mutations = (
            (
                "fabricated_metric",
                lambda value: value["backend_results"][0]["metric_results"][0].update(
                    status="measured", value=0, passed=True
                ),
            ),
            (
                "observed_disposition",
                lambda value: value["backend_results"][0].update(
                    disposition="diagnostic_only",
                    reason=DISPOSITION_REASONS["diagnostic_only"],
                ),
            ),
            (
                "passed_with_failed_check",
                lambda value: value["checks"][0].update(status="failed"),
            ),
            (
                "result_observation_mismatch",
                lambda value: value["observation_status"].update(
                    deterministic_software_conformance="failed"
                ),
            ),
            (
                "production_default",
                lambda value: value["result"].update(
                    default_backend_id="r03.mps.lanczos"
                ),
            ),
            (
                "product_claim",
                lambda value: value["result"].update(product_qualification="claimed"),
            ),
            (
                "performance_claim",
                lambda value: value["result"].update(performance_claims="allowed"),
            ),
        )
        for name, mutate in mutations:
            with self.subTest(name=name):
                record = self.valid_conformance()
                mutate(record)
                self.assertTrue(self.conformance_errors(record))

    def test_metric_pass_flag_is_derived_and_qualification_is_closed(self) -> None:
        record = self.valid_conformance()
        first = record["backend_results"][0]
        self.make_observed(first, "qualified")
        self.assertEqual(self.conformance_errors(record), [])

        failed_floor = copy.deepcopy(record)
        failed_floor["backend_results"][0]["metric_results"][0]["value"] = 1
        self.assertTrue(self.conformance_errors(failed_floor))

        ineligible = self.valid_conformance()
        self.make_observed(ineligible["backend_results"][1], "qualified")
        self.assertTrue(self.conformance_errors(ineligible))

    def test_observed_support_stage_has_exact_metric_applicability(self) -> None:
        record = self.valid_conformance()
        support = record["backend_results"][8]
        self.make_observed_support(support)
        self.assertEqual(self.conformance_errors(record), [])
        statuses = {
            metric["id"]: metric["status"] for metric in support["metric_results"]
        }
        self.assertEqual(statuses["dimension_mismatch_count"], "measured")
        self.assertEqual(statuses["nonfinite_metric_count"], "measured")
        self.assertEqual(statuses["audio_identity_mismatch_count"], "not_applicable")

    def test_metric_not_applicable_is_rejected_outside_frozen_map(self) -> None:
        mutations = []

        whole_ringing = self.valid_conformance()
        self.make_observed(whole_ringing["backend_results"][0], "qualified")
        ringing = whole_ringing["backend_results"][0]["metric_results"][14]
        ringing.update(status="not_applicable", value=None, passed=None)
        mutations.append(("whole_frame_ringing", whole_ringing))

        support_dimension = self.valid_conformance()
        self.make_observed_support(support_dimension["backend_results"][8])
        dimension = support_dimension["backend_results"][8]["metric_results"][0]
        dimension.update(status="not_applicable", value=None, passed=None)
        mutations.append(("support_dimension", support_dimension))

        support_out_of_contract = self.valid_conformance()
        self.make_observed_support(support_out_of_contract["backend_results"][8])
        audio = support_out_of_contract["backend_results"][8]["metric_results"][4]
        audio.update(status="measured", value=0, passed=True)
        mutations.append(("support_out_of_contract_observation", support_out_of_contract))

        for name, record in mutations:
            with self.subTest(name=name):
                self.assertTrue(self.conformance_errors(record))

    def test_whole_frame_parity_not_applicable_and_optional_not_observed_are_valid(self) -> None:
        record = self.valid_conformance()
        backend = record["backend_results"][0]
        self.make_observed(backend, "diagnostic_only")
        for index in (12, 13):
            backend["metric_results"][index].update(
                status="not_applicable", value=None, passed=None
            )
        backend["metric_results"][14].update(
            status="not_observed", value=None, passed=None
        )
        self.assertEqual(self.conformance_errors(record), [])

        mandatory_missing = copy.deepcopy(record)
        mandatory_missing["backend_results"][0]["metric_results"][0].update(
            status="not_observed", value=None, passed=None
        )
        self.assertTrue(self.conformance_errors(mandatory_missing))

    def test_every_frozen_preregistration_and_catalog_scalar_changes_hash(self) -> None:
        def scalar_paths(value: object, path: tuple[object, ...] = ()):
            if isinstance(value, dict):
                for key, nested in value.items():
                    yield from scalar_paths(nested, (*path, key))
            elif isinstance(value, list):
                for index, nested in enumerate(value):
                    yield from scalar_paths(nested, (*path, index))
            else:
                yield path

        def mutate(value: object, path: tuple[object, ...]) -> object:
            result = copy.deepcopy(value)
            cursor = result
            for part in path[:-1]:
                cursor = cursor[part]
            leaf = cursor[path[-1]]
            if leaf is None:
                replacement = "mutated"
            elif isinstance(leaf, bool):
                replacement = not leaf
            elif isinstance(leaf, (int, float)):
                replacement = leaf + 1
            else:
                replacement = f"{leaf}-mutated"
            cursor[path[-1]] = replacement
            return result

        for label, value, frozen_hash in (
            ("preregistration", self.preregistration, PREREGISTRATION_SEMANTIC_SHA256),
            ("catalog", self.catalog, FIXTURE_CATALOG_SEMANTIC_SHA256),
        ):
            for path in scalar_paths(value):
                with self.subTest(contract=label, path=path):
                    self.assertNotEqual(_semantic_sha256(mutate(value, path)), frozen_hash)


if __name__ == "__main__":
    unittest.main()
