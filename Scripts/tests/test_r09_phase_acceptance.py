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
from r09_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_SCHEMA_PATH,
    AUTHORIZATIONS,
    COMPARISON_POLICY,
    CONTRACT_INTERPRETATIONS,
    CONTRACT_PATHS,
    DERIVED_CHECK_IDS,
    EXECUTION_RECEIPT_SCHEMA_PATH,
    EXPECTED_SELECTED_TEST_COUNT,
    EXPECTED_SUITE_COUNTS,
    FUNCTIONAL_TEST_METHODS,
    IMPLEMENTATION_PATHS,
    OBSERVATION_STATUS,
    OPERATOR_OVERRIDE,
    R09PhaseAcceptanceVerifier,
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


class DerivedRecordHarness(R09PhaseAcceptanceVerifier):
    def contract_bindings(self, source):  # type: ignore[no-untyped-def]
        del source
        return bindings("contract", len(CONTRACT_PATHS))

    def implementation_bindings(self, source):  # type: ignore[no-untyped-def]
        del source
        return bindings("implementation", len(IMPLEMENTATION_PATHS))


class R09PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = DerivedRecordHarness(REPOSITORY_ROOT)
        self.source = {"commit": "1" * 40, "tree": "2" * 40}
        command = " ".join([
            "xcodebuild",
            "-project Mirmir.xcodeproj",
            "-scheme Mirmir",
            "-configuration Debug",
            "-destination platform=macOS,arch=arm64",
            "test",
            *(
                f"-only-testing:MirmirTests/{identifier}"
                for identifier, _ in TEST_SUITES
            ),
            "CODE_SIGNING_ALLOWED=NO",
        ])
        self.summary = {
            "schema_version": "1.0.0",
            "phase_id": "R09",
            "evidence_kind": "r09_functional_selected_test_summary_v1",
            "source": dict(self.source),
            "execution_mode": "deterministic_fixture_simulation",
            "expected_selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
            "selected_test_count": EXPECTED_SELECTED_TEST_COUNT,
            "passed_test_count": EXPECTED_SELECTED_TEST_COUNT,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "test_suites": [
                {
                    "id": identifier,
                    "expected_test_count": EXPECTED_SUITE_COUNTS[identifier],
                    "passed_test_count": EXPECTED_SUITE_COUNTS[identifier],
                    "failed_test_count": 0,
                    "skipped_test_count": 0,
                }
                for identifier, _ in TEST_SUITES
            ],
            "test_identifiers": [
                f"MirmirTests/{identifier}/{method}"
                for identifier, relative in TEST_SUITES
                for method in self.verifier._test_suite_methods(
                    (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
                )[0][identifier]
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

    def test_checkpoint_contract_and_implementation_inventory_is_complete(self) -> None:
        contract_paths = {relative.as_posix() for _, relative in CONTRACT_PATHS}
        implementation_paths = {
            relative.as_posix() for _, relative in IMPLEMENTATION_PATHS
        }
        self.assertEqual(len(CONTRACT_PATHS), 13)
        self.assertEqual(len(contract_paths), 13)
        self.assertEqual(len(IMPLEMENTATION_PATHS), 20)
        self.assertEqual(len(implementation_paths), 20)
        for relative in (
            "Scripts/r09_phase_acceptance.py",
            "Scripts/tests/test_r09_phase_acceptance.py",
            "Scripts/phase_evidence.py",
            "docs/roadmaps/evidence/schema/"
            "r09-functional-execution-receipt-v1.json",
            "docs/roadmaps/evidence/schema/"
            "r09-functional-phase-acceptance-v1.json",
        ):
            self.assertIn(relative, contract_paths)
        for relative in (
            "project.yml",
            "Mirmir.xcodeproj/project.pbxproj",
            "Mirmir/Modules/UpscalerEngine/R09BoundedResidualStage.swift",
            "MirmirTests/UpscalerEngine/R09ResidualTestSupport.swift",
            "MirmirTests/UpscalerEngine/R09BoundedResidualStageTestSupport.swift",
            "MirmirTests/UpscalerEngine/R07FunctionalTestSupport.swift",
        ):
            self.assertIn(relative, implementation_paths)

    def test_exact_26_test_inventory_and_functional_map_resolve(self) -> None:
        self.assertEqual(sum(EXPECTED_SUITE_COUNTS.values()), 26)
        self.assertEqual(
            tuple(EXPECTED_SUITE_COUNTS.values()),
            (7, 8, 6, 5),
        )
        observed: set[str] = set()
        for suite, relative in TEST_SUITES:
            source = (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")
            inventory, errors = self.verifier._test_suite_methods(source)
            self.assertEqual(errors, [])
            methods = inventory.get(suite)
            self.assertIsNotNone(methods, suite)
            self.assertEqual(len(methods or ()), EXPECTED_SUITE_COUNTS[suite])
            observed.update(
                f"MirmirTests/{suite}/{method}" for method in methods or ()
            )
        mapped = {
            test_id
            for _, evidence_tests in FUNCTIONAL_TEST_METHODS
            for test_id in evidence_tests
        }
        self.assertEqual(len(observed), 26)
        self.assertEqual(mapped, observed)
        self.assertEqual(
            len(FUNCTIONAL_TEST_METHODS),
            len({identifier for identifier, _ in FUNCTIONAL_TEST_METHODS}),
        )

    def test_comparative_methods_are_not_run_required_or_gating(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        acceptance_schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        expected = {
            "comparative_testing": "not_run_not_required",
            "a_b_testing": "not_run_not_required",
            "blinded_testing": "not_run_not_required",
            "ablation_testing": "not_run_not_required",
            "superiority_requirement": "not_run_not_required",
            "acceptance_dependency": "none",
        }
        self.assertEqual(COMPARISON_POLICY, expected)
        self.assertEqual(self.receipt["comparison_policy"], expected)
        self.assertEqual(self.acceptance["comparison_policy"], expected)
        self.assertEqual(
            self.receipt["contract_interpretations"], CONTRACT_INTERPRETATIONS
        )
        self.assertEqual(
            self.acceptance["contract_interpretations"], CONTRACT_INTERPRETATIONS
        )
        self.assertEqual(
            self.verifier._comparison_errors(expected, "comparison policy"), []
        )
        for key in expected:
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.receipt)
                fabricated["comparison_policy"][key] = "required"
                self.assertTrue(
                    validate_json_schema_instance(receipt_schema, fabricated)
                )
                fabricated_acceptance = copy.deepcopy(self.acceptance)
                fabricated_acceptance["comparison_policy"][key] = "required"
                self.assertTrue(
                    validate_json_schema_instance(
                        acceptance_schema, fabricated_acceptance
                    )
                )

    def test_operator_gate_and_unobserved_native_boundaries_are_exact(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        acceptance_schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(
            self.acceptance["operator_override"], OPERATOR_OVERRIDE
        )
        self.assertEqual(
            self.acceptance["functional_gate"]["acceptance_basis"],
            "software_does_what_it_says_it_does",
        )
        self.assertEqual(
            self.acceptance["functional_gate"]["acceptance_scope"],
            "declared_software_function_only",
        )
        self.assertEqual(self.receipt["observation_status"], OBSERVATION_STATUS)
        for key in (
            "native_core_ai_execution",
            "core_ai_framework_availability",
            "model_asset_availability",
            "model_asset_execution",
            "physical_hardware_execution",
            "apple_simulator_execution",
            "operator_observed_operation",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.receipt)
                fabricated["observation_status"][key] = "observed"
                self.assertTrue(
                    validate_json_schema_instance(receipt_schema, fabricated)
                )
        fabricated = copy.deepcopy(self.acceptance)
        fabricated["operator_override"]["acceptance_basis"] = "comparative_result"
        self.assertTrue(
            validate_json_schema_instance(acceptance_schema, fabricated)
        )

    def test_production_auto_holdout_claims_publication_and_release_are_unauthorized(
        self,
    ) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(self.acceptance["authorizations"], AUTHORIZATIONS)
        for key in (
            "production_default",
            "auto_mode",
            "holdout",
            "quality_claims",
            "performance_claims",
            "product_publication",
            "release",
            "native_core_ai_claims",
        ):
            with self.subTest(key=key):
                self.assertEqual(AUTHORIZATIONS[key], "not_authorized")
                fabricated = copy.deepcopy(self.acceptance)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_test_command_and_log_require_exact_selected_execution(self) -> None:
        command = self.summary["toolchain"]["command"]
        self.assertEqual(self.verifier._command_errors(command), [])
        self.assertTrue(self.verifier._command_errors(
            command.replace(
                " -only-testing:MirmirTests/R09BoundedResidualStageTests", ""
            )
        ))
        self.assertTrue(self.verifier._command_errors(
            command + " -skip-testing:MirmirTests/forged"
        ))
        self.assertTrue(self.verifier._command_errors(
            command.replace("xcodebuild", "swift")
        ))
        self.assertTrue(self.verifier._command_errors(
            command.replace(" test ", " test-without-building ")
        ))
        log = (
            "Executed 26 tests, with 0 failures (0 unexpected) in 1.0 seconds\n"
            "** TEST SUCCEEDED **\n"
        )
        self.assertEqual(self.verifier._log_errors(log, 26), [])
        self.assertTrue(self.verifier._log_errors(
            log.replace("0 failures", "1 failure"), 26
        ))
        self.assertTrue(self.verifier._log_errors(
            log.replace("TEST SUCCEEDED", "TEST FAILED"), 26
        ))

    def test_derived_checks_are_exact_ordered_and_test_backed(self) -> None:
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

    def test_historical_checkpoint_survives_current_file_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            test_path = Path("Tests/R09FixtureTests.swift")
            contract_path = Path("Evidence/contract.json")
            (root / test_path).parent.mkdir(parents=True)
            (root / contract_path).parent.mkdir(parents=True)
            (root / test_path).write_text(
                "final class R09FixtureTests: XCTestCase {\n"
                "    func testDeclaredFunction() {}\n"
                "    func testBoundary() {}\n"
                "}\n",
                encoding="utf-8",
            )
            (root / contract_path).write_text("{}\n", encoding="utf-8")
            for arguments in (
                ("init", "-q"),
                ("config", "user.email", "tests@example.invalid"),
                ("config", "user.name", "R09 Tests"),
                ("add", "."),
                ("commit", "-qm", "fixture"),
            ):
                subprocess.run(
                    ["git", *arguments], cwd=root, check=True, capture_output=True
                )
            verifier = R09PhaseAcceptanceVerifier(
                root,
                contract_paths=(("contract", contract_path),),
                implementation_paths=(("test", test_path),),
                test_suites=(("R09FixtureTests", test_path),),
                expected_suite_counts={"R09FixtureTests": 2},
                functional_test_methods=((
                    "declared_function",
                    (
                        "MirmirTests/R09FixtureTests/testDeclaredFunction",
                        "MirmirTests/R09FixtureTests/testBoundary",
                    ),
                ),),
                artifact_paths=(),
            )
            source = verifier.resolve_source("HEAD")
            self.assertEqual(verifier._write_source_errors(source), [])
            initial_binding = verifier._checkpoint_binding(
                source, "contract", contract_path
            )
            suites, test_identifiers, errors = verifier._checkpoint_test_inventory(source)
            self.assertEqual(errors, [])
            self.assertEqual(suites[0]["expected_test_count"], 2)
            self.assertEqual(
                test_identifiers,
                [
                    "MirmirTests/R09FixtureTests/testDeclaredFunction",
                    "MirmirTests/R09FixtureTests/testBoundary",
                ],
            )

            (root / contract_path).write_text(
                '{"post_checkpoint":true}\n', encoding="utf-8"
            )
            (root / test_path).write_text(
                "final class R09FixtureTests: XCTestCase {\n"
                "    func testCurrentUncommittedChange() {}\n"
                "}\n",
                encoding="utf-8",
            )
            self.assertTrue(verifier._write_source_errors(source))
            self.assertEqual(
                verifier._checkpoint_binding(source, "contract", contract_path),
                initial_binding,
            )
            historical_suites, historical_test_ids, historical_errors = (
                verifier._checkpoint_test_inventory(source)
            )
            self.assertEqual(historical_errors, [])
            self.assertEqual(historical_suites, suites)
            self.assertEqual(historical_test_ids, test_identifiers)
            self.assertEqual(verifier._source_errors(source), [])

    def test_production_boundary_rejects_runtime_wiring_outside_r09_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = Path("Mirmir/Modules/R09BoundedResidualStage.swift")
            app = Path("Mirmir/App.swift")
            test_path = Path("Tests/R09FixtureTests.swift")
            for relative, payload in (
                (runtime, "actor R09BoundedResidualStage {}\n"),
                (app, "let stage = R09BoundedResidualStage()\n"),
                (test_path, "final class R09FixtureTests: XCTestCase {\n"
                 "    func testDeclaredFunction() {}\n"
                 "}\n"),
            ):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text(payload, encoding="utf-8")
            for arguments in (
                ("init", "-q"),
                ("config", "user.email", "tests@example.invalid"),
                ("config", "user.name", "R09 Tests"),
                ("add", "."),
                ("commit", "-qm", "fixture"),
            ):
                subprocess.run(
                    ["git", *arguments], cwd=root, check=True, capture_output=True
                )
            verifier = R09PhaseAcceptanceVerifier(
                root,
                contract_paths=(),
                implementation_paths=(("runtime", runtime), ("test", test_path)),
                test_suites=(("R09FixtureTests", test_path),),
                expected_suite_counts={"R09FixtureTests": 1},
                functional_test_methods=((
                    "declared_function",
                    ("MirmirTests/R09FixtureTests/testDeclaredFunction",),
                ),),
                artifact_paths=(),
            )
            source = verifier.resolve_source("HEAD")
            self.assertEqual(
                verifier._production_boundary_errors(source),
                ["R09 runtime is wired outside its experiment boundary: Mirmir/App.swift"],
            )

    def test_source_and_binding_hashes_reject_placeholders(self) -> None:
        receipt_schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        fabricated = copy.deepcopy(self.receipt)
        fabricated["source"]["commit"] = "0" * 40
        self.assertTrue(validate_json_schema_instance(receipt_schema, fabricated))
        fabricated = copy.deepcopy(self.receipt)
        fabricated["implementation_bindings"][0]["sha256"] = "0" * 64
        self.assertTrue(validate_json_schema_instance(receipt_schema, fabricated))


if __name__ == "__main__":
    unittest.main()
