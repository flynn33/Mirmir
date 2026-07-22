from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r08_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_SCHEMA_PATH,
    AUTHORIZATIONS,
    COMPARISON_POLICY,
    CONTRACT_PATHS,
    DERIVED_CHECK_IDS,
    EXECUTION_RECEIPT_SCHEMA_PATH,
    FUNCTIONAL_TEST_METHODS,
    IMPLEMENTATION_PATHS,
    OBSERVATION_STATUS,
    OPERATOR_OVERRIDE,
    R08PhaseAcceptanceVerifier,
    TEST_SUITES,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected object: {relative}")
    return value


def bindings(prefix: str, count: int) -> list[dict[str, object]]:
    return [
        {
            "id": f"{prefix}_{index}",
            "path": f"evidence/{prefix}-{index}.json",
            "size_bytes": index + 1,
            "sha256": f"{index + 1:064x}",
        }
        for index in range(count)
    ]


class DerivedRecordHarness(R08PhaseAcceptanceVerifier):
    def contract_bindings(self, source):  # type: ignore[no-untyped-def]
        del source
        return bindings("contract", len(CONTRACT_PATHS))

    def implementation_bindings(self, source):  # type: ignore[no-untyped-def]
        del source
        return bindings("implementation", len(IMPLEMENTATION_PATHS))


class R08PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = DerivedRecordHarness(REPOSITORY_ROOT)
        self.source = {"commit": "1" * 40, "tree": "2" * 40}
        suite_counts = {
            "R08CoreAIAnalysisContractsTests": 10,
            "R08AnalysisBudgetContractTests": 2,
            "R08AnalysisIdentityContractTests": 1,
            "R08AnalysisOutputDecoderTests": 5,
            "R08DeterministicAnalysisServiceTests": 8,
            "R08DeterministicAnalysisLifecycleTests": 5,
            "R08AnalysisResourceBudgetTests": 3,
            "R08ForbiddenOutputServiceTests": 1,
            "R08InputTransferFallbackTests": 1,
            "R08ASHAnalysisBridgeTests": 6,
        }
        expected_count = sum(suite_counts.values())
        command = " ".join([
            "xcodebuild",
            "-project Mirmir.xcodeproj",
            "-scheme Mirmir",
            "-destination platform=macOS",
            "test",
            *(
                f"-only-testing:MirmirTests/{identifier}"
                for identifier, _ in TEST_SUITES
            ),
            "CODE_SIGNING_ALLOWED=NO",
        ])
        self.summary = {
            "schema_version": "1.0.0",
            "phase_id": "R08",
            "evidence_kind": "r08_functional_selected_test_summary_v1",
            "source": dict(self.source),
            "execution_mode": "deterministic_fixture_simulation",
            "expected_selected_test_count": expected_count,
            "selected_test_count": expected_count,
            "passed_test_count": expected_count,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_suites": [
                {
                    "id": identifier,
                    "expected_test_count": suite_counts[identifier],
                    "passed_test_count": suite_counts[identifier],
                    "failed_test_count": 0,
                    "skipped_test_count": 0,
                }
                for identifier, _ in TEST_SUITES
            ],
            "toolchain": {
                "platform": "macos_host",
                "architecture": "arm64",
                "os_version": "26.5.2",
                "xcode_version": "26.2",
                "xcode_build_version": "17C52",
                "command": command,
            },
        }
        self.receipt = self.verifier.expected_execution_receipt(
            self.summary,
            self.source,
            artifact_bindings=bindings("artifact", 2),
        )
        self.acceptance = self.verifier.expected_acceptance(
            self.receipt,
            receipt_binding=bindings("receipt", 1)[0],
        )

    def test_derived_records_validate_against_closed_schemas(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        acceptance_schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(
            validate_json_schema_instance(receipt_schema, self.receipt), []
        )
        self.assertEqual(
            validate_json_schema_instance(acceptance_schema, self.acceptance), []
        )
        for schema, record in (
            (receipt_schema, self.receipt),
            (acceptance_schema, self.acceptance),
        ):
            fabricated = copy.deepcopy(record)
            fabricated["unreviewed_authority"] = True
            self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_comparative_methods_are_explicitly_absent_and_non_gating(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        acceptance_schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(self.receipt["comparison_policy"], COMPARISON_POLICY)
        self.assertEqual(self.acceptance["comparison_policy"], COMPARISON_POLICY)
        self.assertEqual(
            self.verifier._comparison_errors(
                COMPARISON_POLICY, "comparison policy"
            ),
            [],
        )

        mutations = {
            "comparative_testing": "required",
            "a_b_testing": "required",
            "blinded_testing": "required",
            "ablation_testing": "required",
            "superiority_requirement": "required",
            "acceptance_dependency": "comparison_results",
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                receipt = copy.deepcopy(self.receipt)
                receipt["comparison_policy"][key] = value
                self.assertTrue(
                    validate_json_schema_instance(receipt_schema, receipt)
                )
                self.assertTrue(
                    self.verifier._comparison_errors(
                        receipt["comparison_policy"], "comparison policy"
                    )
                )

                acceptance = copy.deepcopy(self.acceptance)
                acceptance["comparison_policy"][key] = value
                self.assertTrue(
                    validate_json_schema_instance(acceptance_schema, acceptance)
                )

    def test_operator_override_rejects_reintroduced_comparison_gates(self) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(self.acceptance["operator_override"], OPERATOR_OVERRIDE)
        for key in (
            "comparative_requirement",
            "a_b_requirement",
            "blinded_requirement",
            "ablation_requirement",
            "superiority_requirement",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.acceptance)
                fabricated["operator_override"][key] = "required"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_unobserved_native_environment_cannot_be_fabricated(self) -> None:
        schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        self.assertEqual(self.receipt["observation_status"], OBSERVATION_STATUS)
        self.assertEqual(
            self.receipt["result"]["declared_software_behavior"],
            "conformant",
        )
        self.assertNotIn("declared_task_performance", self.receipt["result"])
        for key in (
            "hardware_execution",
            "apple_simulator_execution",
            "operator_observed_operation",
            "xcode27_environment",
            "core_ai_framework_availability",
            "model_asset_availability",
            "native_core_ai_execution",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.receipt)
                fabricated["observation_status"][key] = "observed"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_acceptance_does_not_authorize_product_auto_r09_claims_or_release(self) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(self.acceptance["authorizations"], AUTHORIZATIONS)
        for key in (
            "r09_phase_progression",
            "r09_residual_execution",
            "production_default",
            "auto_mode",
            "pixel_output",
            "pixel_control",
            "holdout",
            "quality_claims",
            "performance_claims",
            "product_publication",
            "release",
            "native_core_ai_claims",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.acceptance)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_functional_checks_are_exact_ordered_and_test_backed(self) -> None:
        self.assertEqual(
            self.receipt["functional_checks"],
            [
                {
                    "id": check_id,
                    "status": "passed",
                    "evidence_tests": list(evidence_tests),
                }
                for check_id, evidence_tests in FUNCTIONAL_TEST_METHODS
            ],
        )
        self.assertEqual(
            self.acceptance["derived_checks"],
            [
                {"id": check_id, "status": "passed"}
                for check_id in DERIVED_CHECK_IDS
            ],
        )
        mutated = copy.deepcopy(self.receipt)
        mutated["functional_checks"][0]["status"] = "failed"
        self.assertTrue(validate_json_schema_instance(
            read_json(EXECUTION_RECEIPT_SCHEMA_PATH), mutated
        ))
        self.assertNotEqual(mutated, self.receipt)

    def test_functional_test_map_resolves_in_current_sources(self) -> None:
        observed: set[str] = set()
        inventories: dict[Path, dict[str, tuple[str, ...]]] = {}
        for suite, relative in TEST_SUITES:
            if relative not in inventories:
                source = (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
                inventory, errors = self.verifier._test_suite_methods(source)
                self.assertEqual(errors, [])
                inventories[relative] = inventory
            methods = inventories[relative].get(suite)
            self.assertIsNotNone(methods, suite)
            observed.update(
                f"MirmirTests/{suite}/{method}"
                for method in methods or ()
            )
        required = {
            test_id
            for _, evidence_tests in FUNCTIONAL_TEST_METHODS
            for test_id in evidence_tests
        }
        self.assertEqual(required, observed)
        self.assertEqual(
            len(FUNCTIONAL_TEST_METHODS),
            len({identifier for identifier, _ in FUNCTIONAL_TEST_METHODS}),
        )

    def test_test_command_is_exact_and_cannot_skip_or_add_suites(self) -> None:
        command = self.summary["toolchain"]["command"]
        self.assertEqual(self.verifier._command_errors(command), [])
        self.assertTrue(self.verifier._command_errors(
            command.replace(
                " -only-testing:MirmirTests/R08ASHAnalysisBridgeTests", ""
            )
        ))
        self.assertTrue(self.verifier._command_errors(
            command + " -skip-testing:MirmirTests/forged"
        ))
        self.assertTrue(self.verifier._command_errors(
            command.replace("xcodebuild", "swift")
        ))

    def test_log_requires_exact_passing_test_count_and_no_failure(self) -> None:
        count = self.summary["expected_selected_test_count"]
        log = (
            f"Executed {count} tests, with 0 failures (0 unexpected) in 1.0 seconds\n"
            "** TEST SUCCEEDED **\n"
        )
        self.assertEqual(self.verifier._log_errors(log, count), [])
        self.assertTrue(self.verifier._log_errors(
            log.replace("0 failures", "1 failure"), count
        ))
        self.assertTrue(self.verifier._log_errors(
            log.replace("TEST SUCCEEDED", "TEST FAILED"), count
        ))
        self.assertTrue(self.verifier._log_errors(
            log + "/Users/private/DerivedData\n", count
        ))

    def test_source_checkpoint_and_inventory_are_git_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            test_path = Path("Tests/R08FixtureTests.swift")
            contract_path = Path("Evidence/contract.json")
            (root / test_path).parent.mkdir(parents=True)
            (root / contract_path).parent.mkdir(parents=True)
            (root / test_path).write_text(
                "final class R08FixtureTests: XCTestCase {\n"
                "    func testDeclaredFunction() {}\n"
                "    func testBoundary() {}\n"
                "}\n",
                encoding="utf-8",
            )
            (root / contract_path).write_text("{}\n", encoding="utf-8")
            for arguments in (
                ("init", "-q"),
                ("config", "user.email", "tests@example.invalid"),
                ("config", "user.name", "R08 Tests"),
                ("add", "."),
                ("commit", "-qm", "fixture"),
            ):
                subprocess.run(
                    ["git", *arguments], cwd=root, check=True, capture_output=True
                )

            verifier = R08PhaseAcceptanceVerifier(
                root,
                contract_paths=(("contract", contract_path),),
                implementation_paths=(),
                test_suites=(("R08FixtureTests", test_path),),
                functional_test_methods=((
                    "declared_function",
                    (
                        "MirmirTests/R08FixtureTests/testDeclaredFunction",
                        "MirmirTests/R08FixtureTests/testBoundary",
                    ),
                ),),
                artifact_paths=(),
            )
            source = verifier.resolve_source("HEAD")
            self.assertEqual(verifier._source_errors(source), [])
            suites, errors = verifier._checkpoint_test_inventory(source)
            self.assertEqual(errors, [])
            self.assertEqual(suites[0]["expected_test_count"], 2)
            self.assertEqual(
                verifier._checkpoint_file_errors(
                    source, verifier.contract_paths, "contract evidence"
                ),
                [],
            )

            wrong_tree = dict(source)
            wrong_tree["tree"] = "3" * 40
            self.assertTrue(verifier._source_errors(wrong_tree))
            (root / contract_path).write_text('{"changed":true}\n', encoding="utf-8")
            self.assertTrue(verifier._checkpoint_file_errors(
                source, verifier.contract_paths, "contract evidence"
            ))

            (root / test_path).write_text(
                "final class R08FixtureTests: XCTestCase {\n"
                "    func testDeclaredFunction() {}\n"
                "    func testABComparison() {}\n"
                "}\n",
                encoding="utf-8",
            )
            subprocess.run(
                ["git", "add", test_path.as_posix()],
                cwd=root,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "commit", "-qm", "forbidden comparison"],
                cwd=root,
                check=True,
                capture_output=True,
            )
            comparative_source = verifier.resolve_source("HEAD")
            _, comparative_errors = verifier._checkpoint_test_inventory(
                comparative_source
            )
            self.assertTrue(any(
                "comparative methods" in error for error in comparative_errors
            ))

    def test_source_and_artifact_hashes_cannot_be_placeholder_zeroes(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        fabricated = copy.deepcopy(self.receipt)
        fabricated["source"]["commit"] = "0" * 40
        self.assertTrue(validate_json_schema_instance(receipt_schema, fabricated))

        fabricated = copy.deepcopy(self.receipt)
        fabricated["artifact_bindings"][0]["sha256"] = "0" * 64
        self.assertTrue(validate_json_schema_instance(receipt_schema, fabricated))


if __name__ == "__main__":
    unittest.main()
