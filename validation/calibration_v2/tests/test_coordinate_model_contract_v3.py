from __future__ import annotations

from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = CALIBRATION_ROOT / "contracts" / "coordinate-model-contract-v3.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas" / "coordinate-model-contract-v3.schema.json"
CONTRACT_SHA256 = "283704ffcd267be7d85eb74c3791d466f94ba6aaa5430e7443a37683db0faced"
ORACLE_MATRIX_SHA256 = "3cb5d705a24fd3928496b5ee35e671e5219b6928d1cf5dd6c08cb74c83e226d9"
EXPERIMENT_DIMENSIONS_SHA256 = (
    "a9fcabb4a08d3e43e5dcdcb0b8ef55f13d379f462f6f5db283aa802b757e88f2"
)
POLICIES = ["half_pixel_center", "source_aligned_rational"]
ROUTES = {
    "direct_2x": (2, 1),
    "direct_3_over_2": (3, 2),
}


def canonical_bytes(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def rational(value: Fraction) -> dict[str, int]:
    return {
        "denominator": value.denominator,
        "numerator": value.numerator,
    }


def base_coordinate(
    destination_index: int,
    source_extent: int,
    destination_extent: int,
    policy: str,
) -> Fraction:
    if policy == "half_pixel_center":
        return Fraction(
            ((2 * destination_index) + 1) * source_extent - destination_extent,
            2 * destination_extent,
        )
    if policy == "source_aligned_rational":
        return Fraction(destination_index * source_extent, destination_extent)
    raise AssertionError(f"unexpected policy: {policy}")


def left_sited_chroma_coordinate(
    destination_index: int,
    source_extent: int,
    destination_extent: int,
    policy: str,
    offset_numerator: int,
) -> Fraction:
    reference_offset = 1 if policy == "half_pixel_center" else 0
    correction = Fraction(
        (offset_numerator - reference_offset)
        * (source_extent - destination_extent),
        4 * destination_extent,
    )
    return base_coordinate(
        destination_index,
        source_extent,
        destination_extent,
        policy,
    ) + correction


class CoordinateModelContractV3Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract_bytes = CONTRACT_PATH.read_bytes()
        cls.contract = json.loads(cls.contract_bytes)
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.validator = Draft202012Validator(cls.schema)

    def test_contract_is_canonical_hash_frozen_and_schema_valid(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.assertEqual(
            self.contract_bytes,
            canonical_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            hashlib.sha256(self.contract_bytes).hexdigest(),
            CONTRACT_SHA256,
        )
        self.assertEqual(list(self.validator.iter_errors(self.contract)), [])

    def test_plane_policies_are_unselected_per_route_experiment_dimensions(self) -> None:
        experiment = self.contract["experiment_dimensions"]
        self.assertEqual(experiment["coordinate_policy_values"], POLICIES)
        self.assertEqual(
            experiment["selection_status"],
            "unselected_experiment_dimensions",
        )
        self.assertEqual(
            [row["route"] for row in experiment["routes"]],
            list(ROUTES),
        )
        for row in experiment["routes"]:
            self.assertEqual(row["luma_coordinate_policy_values"], POLICIES)
            self.assertEqual(row["chroma_coordinate_policy_values"], POLICIES)
            self.assertNotIn("selected_value", row)
            self.assertNotIn("winner", row)
        self.assertEqual(
            hashlib.sha256(canonical_bytes(experiment)).hexdigest(),
            EXPERIMENT_DIMENSIONS_SHA256,
        )

    def test_semantic_constants_are_exact(self) -> None:
        self.assertEqual(self.contract["schema_version"], "3.0.0")
        self.assertEqual(
            self.contract["phase_zero_compilation_semantics"],
            "generic_state_phase_v1",
        )
        self.assertEqual(
            self.contract["integral_preservation_semantics"],
            "actual_rational_integrality_v1",
        )

    def test_left_sited_y4_c2_coordinate_oracles_match_exact_fractions(self) -> None:
        oracles = self.contract["coordinate_oracles"]
        self.assertEqual(
            hashlib.sha256(canonical_bytes(oracles)).hexdigest(),
            ORACLE_MATRIX_SHA256,
        )
        self.assertEqual([row["route"] for row in oracles], list(ROUTES))
        for route_oracle in oracles:
            route = route_oracle["route"]
            scale_numerator, scale_denominator = ROUTES[route]
            target_luma_extent = 4 * scale_numerator // scale_denominator
            target_chroma_extent = 2 * scale_numerator // scale_denominator
            self.assertEqual(
                route_oracle["low_resolution_geometry"],
                {
                    "cb": {"height": 2, "width": 2},
                    "cr": {"height": 2, "width": 2},
                    "y": {"height": 4, "width": 4},
                },
            )
            self.assertEqual(
                route_oracle["target_geometry"],
                {
                    "cb": {
                        "height": target_chroma_extent,
                        "width": target_chroma_extent,
                    },
                    "cr": {
                        "height": target_chroma_extent,
                        "width": target_chroma_extent,
                    },
                    "y": {
                        "height": target_luma_extent,
                        "width": target_luma_extent,
                    },
                },
            )
            self.assertEqual(
                route_oracle["phase_ordinal_grid"],
                [
                    [
                        (row * scale_numerator) + column
                        for column in range(scale_numerator)
                    ]
                    for row in range(scale_numerator)
                ],
            )
            policy_oracles = {
                row["policy"]: row
                for row in route_oracle["policy_oracles"]
            }
            self.assertEqual(list(policy_oracles), POLICIES)
            for policy in POLICIES:
                expected_luma = [
                    rational(base_coordinate(index, 4, target_luma_extent, policy))
                    for index in range(target_luma_extent)
                ]
                expected_chroma_horizontal = [
                    rational(
                        left_sited_chroma_coordinate(
                            index,
                            2,
                            target_chroma_extent,
                            policy,
                            0,
                        )
                    )
                    for index in range(target_chroma_extent)
                ]
                expected_chroma_vertical = [
                    rational(
                        left_sited_chroma_coordinate(
                            index,
                            2,
                            target_chroma_extent,
                            policy,
                            1,
                        )
                    )
                    for index in range(target_chroma_extent)
                ]
                policy_oracle = policy_oracles[policy]
                self.assertEqual(policy_oracle["luma"]["horizontal"], expected_luma)
                self.assertEqual(policy_oracle["luma"]["vertical"], expected_luma)
                self.assertEqual(
                    policy_oracle["chroma"]["horizontal"],
                    expected_chroma_horizontal,
                )
                self.assertEqual(
                    policy_oracle["chroma"]["vertical"],
                    expected_chroma_vertical,
                )
                for plane in ("luma", "chroma"):
                    for axis in ("horizontal", "vertical"):
                        for coordinate in policy_oracle[plane][axis]:
                            self.assertGreater(coordinate["denominator"], 0)
                            self.assertEqual(
                                math.gcd(
                                    abs(coordinate["numerator"]),
                                    coordinate["denominator"],
                                ),
                                1,
                            )

    def test_schema_rejects_selection_route_and_phase_mutations(self) -> None:
        selected = json.loads(json.dumps(self.contract))
        selected["experiment_dimensions"]["selection_status"] = "selected"
        wrong_route = json.loads(json.dumps(self.contract))
        wrong_route["coordinate_oracles"][0]["route"] = "direct_3_over_2"
        wrong_phase = json.loads(json.dumps(self.contract))
        wrong_phase["coordinate_oracles"][1]["phase_ordinal_grid"][0][0] = 9
        wrong_rational = json.loads(json.dumps(self.contract))
        wrong_rational["coordinate_oracles"][0]["policy_oracles"][0]["chroma"][
            "horizontal"
        ][0]["numerator"] = 0
        for mutated in (selected, wrong_route, wrong_phase, wrong_rational):
            self.assertTrue(list(self.validator.iter_errors(mutated)))

    def test_any_exact_oracle_mutation_changes_the_frozen_hash(self) -> None:
        mutated = json.loads(json.dumps(self.contract["coordinate_oracles"]))
        mutated[0]["policy_oracles"][0]["chroma"]["horizontal"][0]["numerator"] = 0
        self.assertNotEqual(
            hashlib.sha256(canonical_bytes(mutated)).hexdigest(),
            ORACLE_MATRIX_SHA256,
        )


if __name__ == "__main__":
    unittest.main()
