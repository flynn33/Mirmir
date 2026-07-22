from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r07_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    ARTIFACT_PATHS,
    AUTHORIZATIONS,
    DEPENDENCY_ALIGNMENT_OVERRIDE,
    DERIVED_CHECK_IDS,
    EXECUTION_RECEIPT_PATH,
    EXECUTION_RECEIPT_SCHEMA_PATH,
    FUNCTIONAL_CHECK_IDS,
    HISTORICAL_BINDINGS,
    IMPLEMENTATION_PATHS,
    OPERATOR_OVERRIDE,
    R07PhaseAcceptanceVerifier,
    SOURCE,
    SUPERSEDED_GATE,
    XCRESULT_SUMMARY_PATH,
    XCODEBUILD_LOG_PATH,
)


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected object: {relative}")
    return value


class R07PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R07PhaseAcceptanceVerifier(REPOSITORY_ROOT)
        self.summary = read_json(XCRESULT_SUMMARY_PATH)
        self.receipt = read_json(EXECUTION_RECEIPT_PATH)
        self.acceptance = read_json(ACCEPTANCE_PATH)
        self.log = (REPOSITORY_ROOT / XCODEBUILD_LOG_PATH).read_text(
            encoding="utf-8"
        )

    def test_repository_acceptance_is_valid_and_exactly_derived(self) -> None:
        self.assertEqual(self.verifier.check(), [])
        expected_receipt = self.verifier.expected_execution_receipt(self.summary)
        self.assertEqual(self.receipt, expected_receipt)
        self.assertEqual(
            self.acceptance,
            self.verifier.expected_acceptance(self.receipt),
        )

    def test_schemas_are_closed_and_checkpoint_pinned(self) -> None:
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

            fabricated = copy.deepcopy(record)
            fabricated["source"]["commit"] = "1" * 40
            self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_checkpoint_historical_and_implementation_bindings_are_exact(self) -> None:
        self.assertEqual(self.verifier._source_errors(), [])
        self.assertEqual(self.verifier._historical_errors(), [])
        self.assertEqual(self.verifier._implementation_errors(), [])
        self.assertEqual(
            [binding["id"] for binding in self.acceptance["historical_evidence_bindings"]],
            [identifier for identifier, *_ in HISTORICAL_BINDINGS],
        )
        self.assertEqual(
            [binding["id"] for binding in self.receipt["implementation_bindings"]],
            [identifier for identifier, _ in IMPLEMENTATION_PATHS],
        )
        self.assertEqual(
            [binding["id"] for binding in self.receipt["artifact_bindings"]],
            [identifier for identifier, _ in ARTIFACT_PATHS],
        )

    def test_summary_requires_the_exact_98_test_selection(self) -> None:
        self.assertEqual(self.verifier._summary_errors(self.summary), [])
        mutations: list[dict[str, object]] = []

        summary = copy.deepcopy(self.summary)
        summary["passed_test_count"] = 97
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["test_suites"][0]["passed_test_count"] = 9
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["toolchain"]["command"] = summary["toolchain"][
            "command"
        ].replace(
            " -only-testing:MirmirTests/R07FunctionalCoordinatorTransactionTests",
            "",
        )
        mutations.append(summary)

        summary = copy.deepcopy(self.summary)
        summary["toolchain"]["command"] += " -skip-testing:MirmirTests/forged"
        mutations.append(summary)

        for summary in mutations:
            with self.subTest(summary=summary):
                self.assertTrue(self.verifier._summary_errors(summary))

    def test_summary_and_log_reject_failure_or_private_identity(self) -> None:
        self.assertEqual(self.verifier._log_errors(self.log), [])

        failed_log = self.log.replace(
            "** TEST SUCCEEDED **", "** TEST FAILED **"
        )
        self.assertTrue(self.verifier._log_errors(failed_log))

        wrong_count = self.log.replace(
            "Executed 98 tests, with 0 failures (0 unexpected)",
            "Executed 97 tests, with 0 failures (0 unexpected)",
        )
        self.assertTrue(self.verifier._log_errors(wrong_count))

        private_log = self.log + "\n/Users/private/DerivedData\n"
        self.assertTrue(self.verifier._log_errors(private_log))

        private_summary = copy.deepcopy(self.summary)
        private_summary["toolchain"]["command"] += " /Users/private/result"
        self.assertTrue(self.verifier._summary_errors(private_summary))

    def test_fixture_simulation_identity_cannot_be_upgraded_to_native(self) -> None:
        schema = read_json(EXECUTION_RECEIPT_SCHEMA_PATH)
        mutations = []

        receipt = copy.deepcopy(self.receipt)
        receipt["observation_status"]["native_backend_execution"] = "observed"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["observation_status"]["product_qualification"] = "qualified"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["result"]["execution_mode"] = "native_backend_execution"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["functional_checks"][0]["status"] = "failed"
        mutations.append(receipt)

        for receipt in mutations:
            with self.subTest(receipt=receipt):
                self.assertTrue(validate_json_schema_instance(schema, receipt))
                self.assertNotEqual(
                    receipt,
                    self.verifier.expected_execution_receipt(self.summary),
                )

    def test_comparative_gate_is_explicitly_superseded_not_required(self) -> None:
        self.assertEqual(
            self.acceptance["operator_override"], dict(OPERATOR_OVERRIDE)
        )
        self.assertEqual(self.acceptance["superseded_gate"], SUPERSEDED_GATE)
        self.assertEqual(
            self.acceptance["functional_gate"]["comparison_disposition"],
            "superseded_not_required",
        )
        self.assertEqual(
            self.acceptance["result"]["acceptance_scope"],
            "functional_deterministic_software_phase_acceptance",
        )

        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        fabricated = copy.deepcopy(self.acceptance)
        fabricated["operator_override"]["comparative_requirement"] = "required"
        self.assertTrue(validate_json_schema_instance(schema, fabricated))

        fabricated = copy.deepcopy(self.acceptance)
        fabricated["superseded_gate"]["disposition"] = "authorizing"
        self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_r06_alignment_override_preserves_unaccepted_predecessor(self) -> None:
        self.assertEqual(
            self.acceptance["dependency_alignment_override"],
            DEPENDENCY_ALIGNMENT_OVERRIDE,
        )
        self.assertEqual(
            self.acceptance["authorizations"]["r06_phase_status"],
            "in_progress",
        )
        self.assertEqual(
            self.acceptance["authorizations"]["product_qualification"],
            "not_claimed",
        )
        self.assertEqual(
            [binding["id"] for binding in self.acceptance["historical_evidence_bindings"][-2:]],
            ["r06_phase_evidence", "r06_orchestration_conformance"],
        )

    def test_acceptance_cannot_expand_authority(self) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        for key in (
            "production_default",
            "auto_mode",
            "holdout",
            "perceptual_quality_claims",
            "performance_claims",
            "product_publication",
            "release",
            "native_execution_claims",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.acceptance)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))
                self.assertNotEqual(fabricated["authorizations"], AUTHORIZATIONS)

    def test_checks_are_exact_complete_and_ordered(self) -> None:
        self.assertEqual(
            self.receipt["functional_checks"],
            [
                {"id": check_id, "status": "passed"}
                for check_id in FUNCTIONAL_CHECK_IDS
            ],
        )
        self.assertEqual(
            self.acceptance["derived_checks"],
            [
                {"id": check_id, "status": "passed"}
                for check_id in DERIVED_CHECK_IDS
            ],
        )

        mutated = copy.deepcopy(self.acceptance)
        mutated["derived_checks"][0], mutated["derived_checks"][1] = (
            mutated["derived_checks"][1],
            mutated["derived_checks"][0],
        )
        self.assertNotEqual(
            mutated,
            self.verifier.expected_acceptance(self.receipt),
        )

    def test_receipt_binding_detects_any_execution_evidence_mutation(self) -> None:
        mutated = copy.deepcopy(self.acceptance)
        mutated["execution_receipt_binding"]["sha256"] = "1" * 64
        self.assertNotEqual(
            mutated,
            self.verifier.expected_acceptance(self.receipt),
        )
        self.assertEqual(self.acceptance["source"], SOURCE)


if __name__ == "__main__":
    unittest.main()
