from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

from phase_evidence import validate_json_schema_instance  # noqa: E402
from r03_phase_acceptance import (  # noqa: E402
    ACCEPTANCE_PATH,
    ACCEPTANCE_SCHEMA_PATH,
    EVIDENCE_PATHS,
    R03PhaseAcceptanceVerifier,
)
from r03_product_qualification import (  # noqa: E402
    DECISION_PATH,
    EXECUTION_RECEIPT_PATH,
)
from r02_contracts import CONFORMANCE_PATH as R02_CONFORMANCE_PATH  # noqa: E402


def read_json(relative: Path) -> dict[str, object]:
    value = json.loads((REPOSITORY_ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected object: {relative}")
    return value


class R03PhaseAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = R03PhaseAcceptanceVerifier(REPOSITORY_ROOT)
        self.r02 = read_json(R02_CONFORMANCE_PATH)
        self.decision = read_json(DECISION_PATH)
        self.receipt = read_json(EXECUTION_RECEIPT_PATH)
        self.record = read_json(ACCEPTANCE_PATH)

    def functional_errors(
        self,
        *,
        r02: dict[str, object] | None = None,
        decision: dict[str, object] | None = None,
        receipt: dict[str, object] | None = None,
    ) -> list[str]:
        return self.verifier._functional_evidence_errors(
            copy.deepcopy(r02 if r02 is not None else self.r02),
            copy.deepcopy(decision if decision is not None else self.decision),
            copy.deepcopy(receipt if receipt is not None else self.receipt),
        )

    def test_repository_acceptance_is_valid_and_exactly_derived(self) -> None:
        self.assertEqual(self.verifier.check(), [])
        expected = self.verifier.expected_record(self.decision, self.receipt)
        self.assertEqual(self.record, expected)

    def test_acceptance_schema_is_closed(self) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        self.assertEqual(validate_json_schema_instance(schema, self.record), [])
        fabricated = copy.deepcopy(self.record)
        fabricated["unreviewed_authority"] = True
        self.assertTrue(validate_json_schema_instance(schema, fabricated))

    def test_source_checkpoint_and_evidence_bindings_are_exact(self) -> None:
        self.assertEqual(self.verifier._source_errors(), [])
        bindings = self.record["evidence_bindings"]
        self.assertIsInstance(bindings, list)
        self.assertEqual(
            [binding["id"] for binding in bindings],
            [identifier for identifier, _ in EVIDENCE_PATHS],
        )
        mutated = copy.deepcopy(self.record)
        mutated["evidence_bindings"][0]["sha256"] = "1" * 64
        self.assertNotEqual(
            mutated,
            self.verifier.expected_record(self.decision, self.receipt),
        )

    def test_failed_r02_or_r03_decision_cannot_accept(self) -> None:
        r02 = copy.deepcopy(self.r02)
        r02["result"]["status"] = "blocked"
        self.assertTrue(self.functional_errors(r02=r02))

        decision = copy.deepcopy(self.decision)
        decision["result"]["status"] = "blocked"
        self.assertTrue(self.functional_errors(decision=decision))

        decision = copy.deepcopy(self.decision)
        decision["derived_checks"][0]["status"] = "failed"
        self.assertTrue(self.functional_errors(decision=decision))

    def test_execution_identity_routes_and_lifecycle_fail_closed(self) -> None:
        mutations = []

        receipt = copy.deepcopy(self.receipt)
        receipt["observation_status"]["genuine_mps_execution"] = "not_observed"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["processing_identity"]["backend_id"] = "fabricated"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["route_results"][0]["route_id"] = "fabricated"
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["route_results"][0]["runs"][0]["logical_output_sha256"] = "1" * 64
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["route_results"][0]["runs"][0]["lifecycle_observation"][
            "output_release_count"
        ] = 0
        mutations.append(receipt)

        receipt = copy.deepcopy(self.receipt)
        receipt["route_results"][0]["runs"][0]["fallback_history"] = ["silent"]
        mutations.append(receipt)

        for receipt in mutations:
            with self.subTest(receipt=receipt):
                self.assertTrue(self.functional_errors(receipt=receipt))

    def test_media_and_functional_metrics_fail_closed(self) -> None:
        receipt = copy.deepcopy(self.receipt)
        receipt["media_transaction_result"]["runs"][0]["reopen_succeeded"] = False
        self.assertTrue(self.functional_errors(receipt=receipt))

        receipt = copy.deepcopy(self.receipt)
        receipt["media_transaction_result"]["runs"][0]["frame_observations"][0][
            "sequence_number"
        ] = 7
        self.assertTrue(self.functional_errors(receipt=receipt))

        decision = copy.deepcopy(self.decision)
        measured = next(
            metric
            for metric in decision["metric_evaluations"]
            if metric["status"] == "measured"
        )
        measured["passed"] = False
        self.assertTrue(self.functional_errors(decision=decision))

    def test_acceptance_cannot_expand_product_authority(self) -> None:
        schema = read_json(ACCEPTANCE_SCHEMA_PATH)
        for key in (
            "production_default",
            "perceptual_quality_claims",
            "performance_claims",
            "product_publication",
            "release",
        ):
            with self.subTest(key=key):
                fabricated = copy.deepcopy(self.record)
                fabricated["authorizations"][key] = "authorized"
                self.assertTrue(validate_json_schema_instance(schema, fabricated))
                self.assertNotEqual(
                    fabricated,
                    self.verifier.expected_record(self.decision, self.receipt),
                )


if __name__ == "__main__":
    unittest.main()
