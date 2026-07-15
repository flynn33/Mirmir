from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = CALIBRATION_ROOT / "contracts/baseline-ablation-budget-v2.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas/baseline-ablation-budget-v2.schema.json"
BASE_CONTRACT_PATH = CALIBRATION_ROOT / "contracts/baseline-ablation-contract-v1.json"
BASE_SCHEMA_PATH = CALIBRATION_ROOT / "schemas/baseline-ablation-contract-v1.schema.json"
QUALITY_POLICY_PATH = CALIBRATION_ROOT / "contracts/quality-gate-policy-v1.seed.json"

EXPECTED_SELF_SHA256 = (
    "405d9ca4413e7e291315257682f206d951a081f052d5ecee6f3a36ac72cd22be"
)
EXPECTED_FILE_SHA256 = (
    "1885aa30b46f72ed1de0570a3de5f615cf788ec0d494ed5396731279763da4c8"
)
EXPECTED_SCHEMA_SHA256 = (
    "080cc48a86569d68aecb0ca9384c89300df57dbeaa995e0651cf6082c969416b"
)
EXPECTED_MATERIALIZED_SELECTOR_SHA256 = (
    "b032e9169f7224e2eb44dfe0bb908c26cd4819ddd6138e97cf3b58962a1e950c"
)


def _load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _materialize_selector(
    base_selector: dict[str, object],
    replacements: dict[str, object],
) -> dict[str, object]:
    result = copy.deepcopy(base_selector)
    result["selector_id"] = replacements["/selector_id"]
    coordinates = result["coordinates"]
    if not isinstance(coordinates, dict):
        raise AssertionError("base selector coordinates are absent")
    coordinates["maximum_sweeps"] = replacements[
        "/coordinates/maximum_sweeps"
    ]
    result["candidate_evaluation_budget"] = replacements[
        "/candidate_evaluation_budget"
    ]
    result["full_ash_maximum_candidate_evaluation_budget"] = replacements[
        "/full_ash_maximum_candidate_evaluation_budget"
    ]
    result["budget_formula"] = replacements["/budget_formula"]
    return result


class BaselineAblationBudgetV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = _load(CONTRACT_PATH)
        cls.schema = _load(SCHEMA_PATH)
        cls.base_contract = _load(BASE_CONTRACT_PATH)
        cls.base_schema = _load(BASE_SCHEMA_PATH)
        cls.quality_policy = _load(QUALITY_POLICY_PATH)

    def test_contract_schema_self_hash_and_serialization_are_exact(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        errors = list(
            Draft202012Validator(self.schema).iter_errors(self.contract)
        )
        self.assertEqual(errors, [])
        self.assertEqual(self.contract["artifact_sha256"], EXPECTED_SELF_SHA256)
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_SELF_SHA256,
        )
        self.assertEqual(_file_sha256(CONTRACT_PATH), EXPECTED_FILE_SHA256)
        self.assertEqual(_file_sha256(SCHEMA_PATH), EXPECTED_SCHEMA_SHA256)
        self.assertEqual(
            CONTRACT_PATH.read_bytes(),
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            SCHEMA_PATH.read_bytes(),
            canonical_json_bytes(self.schema) + b"\n",
        )

    def test_authority_bindings_verify_exact_bytes_and_self_hashes(self) -> None:
        bindings = self.contract["authority_bindings"]
        self.assertIsInstance(bindings, list)
        for raw_binding in bindings:
            self.assertIsInstance(raw_binding, dict)
            binding = raw_binding
            path = ROOT / str(binding["path"])
            payload = path.read_bytes()
            self.assertEqual(len(payload), binding["size_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])
            self_hash = binding["self_hash"]
            if self_hash is not None:
                self.assertIsInstance(self_hash, dict)
                document = _load(path)
                self.assertEqual(
                    manifest_sha256(document, field=str(self_hash["field"])),
                    self_hash["sha256"],
                )

        Draft202012Validator.check_schema(self.base_schema)
        self.assertEqual(
            list(
                Draft202012Validator(self.base_schema).iter_errors(
                    self.base_contract
                )
            ),
            [],
        )

    def test_materialized_selector_diff_is_exact_and_hash_bound(self) -> None:
        base_selector = self.base_contract["non_ash_selector"]
        self.assertIsInstance(base_selector, dict)
        materialization = self.contract["selector_materialization"]
        self.assertIsInstance(materialization, dict)
        replacements = materialization["replacements"]
        self.assertIsInstance(replacements, dict)
        materialized = _materialize_selector(base_selector, replacements)
        payload = canonical_json_bytes(materialized)

        self.assertEqual(list(materialized), materialization["result_root_fields"])
        self.assertEqual(len(payload), materialization["result_canonical_size_bytes"])
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            EXPECTED_MATERIALIZED_SELECTOR_SHA256,
        )
        self.assertEqual(
            hashlib.sha256(payload).hexdigest(),
            materialization["result_canonical_sha256"],
        )

        unchanged_top_level = set(base_selector) - {
            "selector_id",
            "coordinates",
            "candidate_evaluation_budget",
            "full_ash_maximum_candidate_evaluation_budget",
            "budget_formula",
        }
        for field in unchanged_top_level:
            self.assertEqual(materialized[field], base_selector[field])
        base_coordinates = base_selector["coordinates"]
        materialized_coordinates = materialized["coordinates"]
        self.assertIsInstance(base_coordinates, dict)
        self.assertIsInstance(materialized_coordinates, dict)
        for field in set(base_coordinates) - {"maximum_sweeps"}:
            self.assertEqual(
                materialized_coordinates[field],
                base_coordinates[field],
            )

    def test_flattened_selector_authority_matches_materialized_selector(self) -> None:
        selector = self.contract["non_ash_selector_v2"]
        materialization = self.contract["selector_materialization"]
        self.assertIsInstance(selector, dict)
        self.assertIsInstance(materialization, dict)
        base_selector = self.base_contract["non_ash_selector"]
        self.assertIsInstance(base_selector, dict)
        materialized = _materialize_selector(
            base_selector,
            materialization["replacements"],
        )
        coordinates = materialized["coordinates"]
        self.assertIsInstance(coordinates, dict)

        self.assertEqual(selector["selector_id"], materialized["selector_id"])
        self.assertEqual(
            selector["bank_descriptor_ids"], materialized["bank_descriptor_ids"]
        )
        for field in (
            "order",
            "values",
            "initial_value",
            "candidate_order",
            "sweep_rule",
            "termination",
            "maximum_sweeps",
            "tie_break",
        ):
            flattened = "coordinate_order" if field == "order" else field
            self.assertEqual(selector[flattened], coordinates[field])
        self.assertEqual(selector["data_separation"], materialized["data_separation"])
        self.assertEqual(selector["output_cache"], materialized["output_cache"])

    def test_smallest_sufficient_whole_sweep_budget_is_proven(self) -> None:
        budget = self.contract["budget"]
        self.assertIsInstance(budget, dict)
        attempts_per_sweep = (
            budget["non_ash_coordinate_count"]
            * budget["non_ash_values_per_coordinate"]
        )
        self.assertEqual(attempts_per_sweep, 189)
        self.assertEqual(
            1 + budget["largest_insufficient_whole_sweep_count"] * attempts_per_sweep,
            budget["largest_insufficient_whole_sweep_budget"],
        )
        self.assertLess(
            budget["largest_insufficient_whole_sweep_budget"],
            budget["full_ash_v2_maximum_development_attempt_count"],
        )
        self.assertEqual(
            1 + budget["minimum_sufficient_whole_sweep_count"] * attempts_per_sweep,
            budget["non_ash_maximum_development_attempt_count"],
        )
        self.assertGreaterEqual(
            budget["non_ash_maximum_development_attempt_count"],
            budget["full_ash_v2_maximum_development_attempt_count"],
        )
        self.assertEqual(
            budget["non_ash_maximum_development_attempt_count"]
            - budget["full_ash_v2_maximum_development_attempt_count"],
            budget["non_ash_budget_excess_attempt_count"],
        )
        self.assertEqual(
            self.quality_policy["non_ash_selector_definition"],
            "A deterministic selector over the identical 16-operator bank using the same continuous features but no ASH state bits, codewords, affine recovery, ternary branch messages, or ASH priors. Its rule family and calibration budget must be predeclared and no smaller than the ASH selector budget.",
        )

    def test_validation_neighborhood_and_execution_boundary_are_closed(self) -> None:
        validation = self.contract["validation_selection"]
        self.assertIsInstance(validation, dict)
        self.assertEqual(
            validation["terminal_candidate_count"]
            + self.contract["budget"]["non_ash_coordinate_count"]
            * validation["noncurrent_value_neighbors_per_coordinate"],
            validation["maximum_validation_candidate_count"],
        )
        self.assertEqual(validation["maximum_validation_candidate_count"], 163)
        self.assertEqual(validation["adaptive_expansion"], "forbidden")
        self.assertEqual(validation["holdout_access"], "forbidden during P06")

        boundary = self.contract["execution_boundary"]
        self.assertIsInstance(boundary, dict)
        for field in (
            "production_execution_authorized_by_this_contract_alone",
            "selector_search_implemented",
            "candidate_evaluation_performed",
            "candidate_selection_performed",
        ):
            self.assertIs(boundary[field], False)
        self.assertTrue(all(value is False for value in self.contract["data_access"].values()))
        self.assertIs(self.contract["v1_compatibility"]["v1_run_affected"], False)

    def test_root_const_schema_rejects_every_material_change(self) -> None:
        validator = Draft202012Validator(self.schema)
        mutations = []
        changed_budget = copy.deepcopy(self.contract)
        changed_budget["budget"]["non_ash_maximum_development_attempt_count"] = 3402
        mutations.append(changed_budget)
        changed_sweeps = copy.deepcopy(self.contract)
        changed_sweeps["non_ash_selector_v2"]["maximum_sweeps"] = 17
        mutations.append(changed_sweeps)
        changed_status = copy.deepcopy(self.contract)
        changed_status["status"] = "executed"
        mutations.append(changed_status)
        added_field = copy.deepcopy(self.contract)
        added_field["winner"] = "unregistered"
        mutations.append(added_field)
        for document in mutations:
            with self.subTest(document=document):
                self.assertNotEqual(list(validator.iter_errors(document)), [])


if __name__ == "__main__":
    unittest.main()
