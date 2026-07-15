from __future__ import annotations

from collections import Counter
import copy
import hashlib
import json
from itertools import combinations
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, ValidationError

from validation.calibration_v2.reference.calibration_plan_v2 import (
    ADMISSIBLE_POLICY_IDS,
    ATOMIC_STRUCTURAL_COORDINATE,
    COORDINATE_COLUMN_MULTIPLIERS,
    COORDINATE_POLICIES,
    MODE_COLUMN_MULTIPLIERS,
    MODE_COLUMN_XOR_OFFSETS,
    MODE_ORDINALS,
    REMOVED_V1_COORDINATES,
    STRUCTURAL_FACTOR_ORDER,
    base_parameter_domains,
    inherited_scalar_initial_values,
    inherited_scalar_parameter_order,
    scalar_domain_cardinality_sum,
    structural_factor_domains,
    structural_vectors,
    validate_structural_design,
)
from validation.calibration_v2.runner import parameter_domains
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
PLAN_V1_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v1.json"
PLAN_V2_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
SCHEMA_V1_PATH = CALIBRATION_ROOT / "schemas/calibration-plan-v1.schema.json"
SCHEMA_V2_PATH = CALIBRATION_ROOT / "schemas/calibration-plan-v2.schema.json"
COMPILER_SCHEMA_V2_PATH = (
    CALIBRATION_ROOT / "schemas/locked-compiler-input-v2.schema.json"
)
COMPILER_FIXTURE_V1_PATH = (
    CALIBRATION_ROOT / "fixtures/locked-compiler-input-shared-v1.json"
)
PLANE_PREREGISTRATION_PATH = (
    CALIBRATION_ROOT / "contracts/plane-aware-lut-preregistration-v1.json"
)
README_PATH = CALIBRATION_ROOT / "README.md"

EXPECTED_PLAN_V1_SHA256 = (
    "128244e8fb1450b74e8c81141af40c5188bac8fc151bf272a348c9faa6f1549e"
)
EXPECTED_SCHEMA_V1_SHA256 = (
    "051a804b32121a99241270c0199e5f3a90034f717ab05e67019b3d8384a7854a"
)
EXPECTED_CATALOG_SHA256 = (
    "8f9eda0eb6de5f6a43787eaea80ebbea0d2f5b80ca8db836666b92207879370c"
)
SHARED_BANK_SCALAR_ORDER = (
    "analysis_epsilon_q0_30",
    "risk_laplacian_weight_unorm15",
    "chroma_edge_confidence_unorm15",
    "direct_2x_analysis_grid_source_step",
    "direct_3_over_2_analysis_grid_source_step",
    "boundary_mode",
    "minimum_anisotropic_magnitude_unorm15",
    "minimum_anisotropic_coherence_unorm15",
    "detail_gain_q12",
    "relaxed_limiter_alpha_q12",
    "risk_detail_suppression_unorm15",
    "low_pass_radius_q8_8",
)
EXPECTED_INPUT_BINDING_PATHS = {
    "calibration_plan_v1": "validation/calibration_v2/contracts/calibration-plan-v1.json",
    "calibration_plan_v1_schema": "validation/calibration_v2/schemas/calibration-plan-v1.schema.json",
    "plane_aware_lut_preregistration": "validation/calibration_v2/contracts/plane-aware-lut-preregistration-v1.json",
    "plane_aware_lut_preregistration_schema": "validation/calibration_v2/schemas/plane-aware-lut-preregistration-v1.schema.json",
    "spatial_semantics_preregistration": "validation/calibration_v2/contracts/spatial-semantics-preregistration-v2.json",
    "spatial_semantics_preregistration_schema": "validation/calibration_v2/schemas/spatial-semantics-preregistration-v2.schema.json",
    "spatial_policy_admissibility_manifest": "validation/calibration_v2/locks/spatial-policy-admissibility-manifest.json",
    "locked_compiler_input_v2_schema": "validation/calibration_v2/schemas/locked-compiler-input-v2.schema.json",
    "calibration_plan_v2_reference": "validation/calibration_v2/reference/calibration_plan_v2.py",
}


def load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha256(value: object) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def plan_self_sha256(plan: dict[str, object]) -> str:
    payload = copy.deepcopy(plan)
    payload.pop("plan_sha256")
    return canonical_sha256(payload)


def compiler_input_self_sha256(document: dict[str, object]) -> str:
    payload = copy.deepcopy(document)
    bindings = payload["hash_bindings"]
    if not isinstance(bindings, dict):
        raise AssertionError("compiler input hash bindings must be an object")
    bindings.pop("compiler_inputs_sha256")
    return canonical_sha256(payload)


class CalibrationPlanV2ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan_v1 = load_object(PLAN_V1_PATH)
        cls.plan_v2 = load_object(PLAN_V2_PATH)
        cls.schema_v1 = load_object(SCHEMA_V1_PATH)
        cls.schema_v2 = load_object(SCHEMA_V2_PATH)
        cls.compiler_schema_v2 = load_object(COMPILER_SCHEMA_V2_PATH)
        cls.compiler_fixture_v1 = load_object(COMPILER_FIXTURE_V1_PATH)
        cls.plane_preregistration = load_object(PLANE_PREREGISTRATION_PATH)
        cls.validator_v1 = Draft202012Validator(cls.schema_v1)
        cls.validator_v2 = Draft202012Validator(cls.schema_v2)
        cls.compiler_validator_v2 = Draft202012Validator(cls.compiler_schema_v2)

    def test_schema_and_plan_self_hash_are_exact(self) -> None:
        Draft202012Validator.check_schema(self.schema_v2)
        self.validator_v2.validate(self.plan_v2)
        self.assertEqual(
            self.plan_v2["plan_sha256"],
            plan_self_sha256(self.plan_v2),
        )
        self.assertTrue(PLAN_V2_PATH.read_bytes().endswith(b"\n"))
        self.assertFalse(PLAN_V2_PATH.read_bytes().endswith(b"\n\n"))

    def test_all_input_bindings_match_exact_files_and_self_hashes(self) -> None:
        bindings = self.plan_v2["input_bindings"]
        self.assertIsInstance(bindings, list)
        expected_ids = {
            "calibration_plan_v1",
            "calibration_plan_v1_schema",
            "plane_aware_lut_preregistration",
            "plane_aware_lut_preregistration_schema",
            "spatial_semantics_preregistration",
            "spatial_semantics_preregistration_schema",
            "spatial_policy_admissibility_manifest",
            "locked_compiler_input_v2_schema",
            "calibration_plan_v2_reference",
        }
        self.assertEqual({binding["id"] for binding in bindings}, expected_ids)
        self.assertEqual(len(bindings), len(expected_ids))
        self.assertEqual(
            {binding["id"]: binding["path"] for binding in bindings},
            EXPECTED_INPUT_BINDING_PATHS,
        )
        for binding in bindings:
            with self.subTest(binding=binding["id"]):
                path = ROOT / binding["path"]
                self.assertTrue(path.is_file())
                self.assertEqual(path.stat().st_size, binding["size_bytes"])
                self.assertEqual(file_sha256(path), binding["sha256"])
                if "self_hash_field" in binding:
                    document = load_object(path)
                    self.assertEqual(
                        document[binding["self_hash_field"]],
                        binding["self_sha256"],
                    )

    def test_v1_plan_and_schema_remain_frozen_and_cross_version_closed(self) -> None:
        self.assertEqual(file_sha256(PLAN_V1_PATH), EXPECTED_PLAN_V1_SHA256)
        self.assertEqual(file_sha256(SCHEMA_V1_PATH), EXPECTED_SCHEMA_V1_SHA256)
        self.validator_v1.validate(self.plan_v1)
        with self.assertRaises(ValidationError):
            self.validator_v1.validate(self.plan_v2)
        with self.assertRaises(ValidationError):
            self.validator_v2.validate(self.plan_v1)

    def test_overlay_preserves_exact_v1_scalar_domains_and_initials(self) -> None:
        reference_domains = base_parameter_domains(self.plan_v1)
        self.assertEqual(reference_domains, parameter_domains(self.plan_v1))
        scalar_order = inherited_scalar_parameter_order(self.plan_v1)
        scalar_initial = inherited_scalar_initial_values(self.plan_v1)
        scalar_domains = {
            name: list(reference_domains[name])
            for name in scalar_order
        }
        inheritance = self.plan_v2["inheritance"]
        self.assertEqual(tuple(inheritance["removed_v1_coordinates"]), REMOVED_V1_COORDINATES)
        self.assertEqual(len(scalar_order), 37)
        self.assertEqual(
            scalar_domain_cardinality_sum(reference_domains, self.plan_v1),
            155,
        )
        self.assertEqual(
            canonical_sha256(list(scalar_order)),
            inheritance["inherited_scalar_parameter_order_sha256"],
        )
        self.assertEqual(
            canonical_sha256(scalar_initial),
            inheritance["inherited_scalar_initial_values_sha256"],
        )
        self.assertEqual(
            canonical_sha256(scalar_domains),
            inheritance["inherited_scalar_domains_sha256"],
        )
        search = self.plan_v2["search"]
        self.assertEqual(
            search["logical_parameter_order"],
            [ATOMIC_STRUCTURAL_COORDINATE, *scalar_order],
        )
        self.assertEqual(search["structural_incumbent_before_first_scan"], None)
        self.assertNotIn("initial_vector_values", search)

    def test_structural_catalog_is_exact_minimum_strength_two_design(self) -> None:
        summary = validate_structural_design()
        self.assertEqual(
            summary,
            {
                "row_count": 256,
                "unique_row_count": 256,
                "pairwise_requirement_count": 1712,
                "covered_pairwise_requirement_count": 1712,
            },
        )
        vectors = structural_vectors()
        catalog = [
            [vector[name] for name in STRUCTURAL_FACTOR_ORDER]
            for vector in vectors
        ]
        design = self.plan_v2["joint_structural_domain"]["screening_design"]
        row_generation = design["row_generation"]
        self.assertEqual(
            row_generation["mode_columns"],
            [
                {
                    "factor": factor,
                    "multiplier": multiplier,
                    "xor_offset": xor_offset,
                }
                for factor, multiplier, xor_offset in zip(
                    STRUCTURAL_FACTOR_ORDER[2:6],
                    MODE_COLUMN_MULTIPLIERS,
                    MODE_COLUMN_XOR_OFFSETS,
                )
            ],
        )
        self.assertEqual(
            row_generation["coordinate_columns"],
            [
                {"factor": factor, "multiplier": multiplier}
                for factor, multiplier in zip(
                    STRUCTURAL_FACTOR_ORDER[6:10],
                    COORDINATE_COLUMN_MULTIPLIERS,
                )
            ],
        )
        self.assertEqual(canonical_sha256(catalog), EXPECTED_CATALOG_SHA256)
        self.assertEqual(design["catalog_sha256"], EXPECTED_CATALOG_SHA256)
        self.assertEqual(
            Counter(
                (vector[STRUCTURAL_FACTOR_ORDER[0]], vector[STRUCTURAL_FACTOR_ORDER[1]])
                for vector in vectors
            ),
            Counter(
                (first, second)
                for first in ADMISSIBLE_POLICY_IDS
                for second in ADMISSIBLE_POLICY_IDS
            ),
        )
        self.assertEqual(
            len(
                {
                    tuple(vector[name] for name in STRUCTURAL_FACTOR_ORDER[6:10])
                    for vector in vectors
                }
            ),
            design["complete_coordinate_vector_count"],
        )
        coordinate_counts = Counter(
            tuple(vector[name] for name in STRUCTURAL_FACTOR_ORDER[6:10])
            for vector in vectors
        )
        self.assertEqual(set(coordinate_counts.values()), {16})
        mode_vectors = {
            tuple(vector[name] for name in STRUCTURAL_FACTOR_ORDER[2:6])
            for vector in vectors
        }
        self.assertEqual(len(mode_vectors), design["unique_mode_vector_count"])
        self.assertNotIn((0, 0, 0, 0), mode_vectors)

    def test_factor_levels_histograms_and_pair_coverage_match_disclosure(self) -> None:
        vectors = structural_vectors()
        domains = structural_factor_domains()
        design = self.plan_v2["joint_structural_domain"]["screening_design"]
        for name in STRUCTURAL_FACTOR_ORDER[2:6]:
            self.assertEqual(
                [sum(vector[name] == value for vector in vectors) for value in MODE_ORDINALS],
                design["mode_level_row_counts_per_factor"],
            )
        for name in STRUCTURAL_FACTOR_ORDER[6:10]:
            self.assertEqual(
                [
                    sum(vector[name] == value for vector in vectors)
                    for value in COORDINATE_POLICIES
                ],
                [128, 128],
            )
        covered_count = 0
        for first, second in combinations(STRUCTURAL_FACTOR_ORDER, 2):
            observed = {(vector[first], vector[second]) for vector in vectors}
            expected = {
                (first_value, second_value)
                for first_value in domains[first]
                for second_value in domains[second]
            }
            self.assertEqual(observed, expected, (first, second))
            covered_count += len(observed)
        self.assertEqual(covered_count, 1712)
        self.assertIn("strength three or greater", design["coverage_claim_limit"])
        self.assertIn("cannot claim exhaustive optimality", design["selection_claim_limit"])

    def test_every_structural_row_materializes_valid_schema_two_compiler_input(self) -> None:
        plan_file_sha256 = file_sha256(PLAN_V2_PATH)
        source_predicate = self.plane_preregistration["source_exact"][
            "format_1_2_predicate"
        ]
        for ordinal, vector in enumerate(structural_vectors()):
            document = copy.deepcopy(self.compiler_fixture_v1)
            document["schema_version"] = "2.0.0"
            operator = document["operator_parameters"]
            self.assertIsInstance(operator, dict)
            operator.pop("anisotropy_strength_q12")
            routes = document["routes"]
            self.assertIsInstance(routes, dict)
            routes["direct_2x"].update(
                {
                    "route_spatial_policy_id": vector[
                        "direct_2x_route_spatial_policy_id"
                    ],
                    "luma_anisotropy_mode_ordinal": vector[
                        "direct_2x_luma_anisotropy_mode_ordinal"
                    ],
                    "chroma_anisotropy_mode_ordinal": vector[
                        "direct_2x_chroma_anisotropy_mode_ordinal"
                    ],
                    "luma_coordinate_policy": vector[
                        "direct_2x_luma_coordinate_policy"
                    ],
                    "chroma_coordinate_policy": vector[
                        "direct_2x_chroma_coordinate_policy"
                    ],
                }
            )
            routes["direct_3_over_2"].update(
                {
                    "route_spatial_policy_id": vector[
                        "direct_3_over_2_route_spatial_policy_id"
                    ],
                    "luma_anisotropy_mode_ordinal": vector[
                        "direct_3_over_2_luma_anisotropy_mode_ordinal"
                    ],
                    "chroma_anisotropy_mode_ordinal": vector[
                        "direct_3_over_2_chroma_anisotropy_mode_ordinal"
                    ],
                    "luma_coordinate_policy": vector[
                        "direct_3_over_2_luma_coordinate_policy"
                    ],
                    "chroma_coordinate_policy": vector[
                        "direct_3_over_2_chroma_coordinate_policy"
                    ],
                }
            )
            document["source_aligned"]["predicate"] = source_predicate
            document["hash_bindings"]["calibration_plan_sha256"] = plan_file_sha256
            document["hash_bindings"]["compiler_inputs_sha256"] = (
                compiler_input_self_sha256(document)
            )
            with self.subTest(ordinal=ordinal):
                self.compiler_validator_v2.validate(document)

    def test_logical_physical_cache_and_budget_contracts_are_exact(self) -> None:
        search = self.plan_v2["search"]
        scalar_order = inherited_scalar_parameter_order(self.plan_v1)
        self.assertEqual(search["logical_parameter_count"], 38)
        self.assertEqual(len(search["logical_parameter_order"]), 38)
        self.assertEqual(search["physical_candidate_field_count"], 48)
        self.assertEqual(
            search["physical_candidate_order"],
            [ATOMIC_STRUCTURAL_COORDINATE, *STRUCTURAL_FACTOR_ORDER, *scalar_order],
        )
        self.assertEqual(
            search["shared_bank_serialization_order"],
            [
                ATOMIC_STRUCTURAL_COORDINATE,
                *STRUCTURAL_FACTOR_ORDER,
                *SHARED_BANK_SCALAR_ORDER,
            ],
        )
        self.assertEqual(
            self.plan_v2["compiler_input_materialization"]["route_mapping"],
            {
                "direct_2x": {
                    name: f"direct_2x_{name}"
                    for name in (
                        "route_spatial_policy_id",
                        "luma_anisotropy_mode_ordinal",
                        "chroma_anisotropy_mode_ordinal",
                        "luma_coordinate_policy",
                        "chroma_coordinate_policy",
                    )
                },
                "direct_3_over_2": {
                    name: f"direct_3_over_2_{name}"
                    for name in (
                        "route_spatial_policy_id",
                        "luma_anisotropy_mode_ordinal",
                        "chroma_anisotropy_mode_ordinal",
                        "luma_coordinate_policy",
                        "chroma_coordinate_policy",
                    )
                },
            },
        )
        budget = search["attempt_budget"]
        self.assertEqual(budget["attempts_per_complete_sweep"], 256 + 155)
        self.assertEqual(budget["maximum_attempt_count"], 8 * (256 + 155))
        self.assertEqual(
            256 + (155 - 37),
            search["maximum_validation_candidate_count_before_constraint_filtering"],
        )
        self.assertIn("counts as a change", search["first_scan_rule"])
        self.assertIn("complete atomic structural replacement", search["validation_neighborhood"])
        self.assertIn("newly preregistered plan version", search["adaptive_expansion"])

    def test_contract_contains_no_execution_winner_or_default(self) -> None:
        self.assertTrue(all(value is False for value in self.plan_v2["execution_state"].values()))
        selection = self.plan_v2["selection_state"]
        self.assertFalse(selection["selection_performed"])
        self.assertFalse(selection["default_configuration_selected"])
        self.assertIsNone(selection["selected_winner"])
        boundary = self.plan_v2["execution_boundary"]
        self.assertFalse(boundary["production_execution_authorized_by_this_contract_alone"])
        self.assertFalse(boundary["gate_claim_made"])
        self.assertFalse(boundary["winner_claim_made"])

    def test_readme_states_the_pairwise_and_execution_boundaries(self) -> None:
        readme = " ".join(README_PATH.read_text(encoding="utf-8").split())
        self.assertIn("Plane-aware joint calibration plan", readme)
        self.assertIn("226 of the 1,295 admissible complete mode vectors", readme)
        self.assertIn("makes no exhaustive claim", readme)
        self.assertIn("38 logical search units from 48 physical candidate fields", readme)
        self.assertIn("at most 3,288 attempts", readme)
        self.assertIn("does not authorize execution", readme)

    def test_schema_rejects_open_or_marginalized_plan_mutations(self) -> None:
        mutations = []
        selected = copy.deepcopy(self.plan_v2)
        selected["selected_configuration"] = "candidate"
        mutations.append(selected)
        initialized = copy.deepcopy(self.plan_v2)
        initialized["search"]["structural_incumbent_before_first_scan"] = 0
        mutations.append(initialized)
        marginal = copy.deepcopy(self.plan_v2)
        marginal["joint_structural_domain"]["marginal_component_selection_authorized"] = True
        mutations.append(marginal)
        all_isotropic = copy.deepcopy(self.plan_v2)
        all_isotropic["joint_structural_domain"]["screening_design"]["all_isotropic_row_count"] = 1
        mutations.append(all_isotropic)
        extra_attempt = copy.deepcopy(self.plan_v2)
        extra_attempt["search"]["attempt_budget"]["maximum_attempt_count"] = 3289
        mutations.append(extra_attempt)
        wrong_physical_count = copy.deepcopy(self.plan_v2)
        wrong_physical_count["search"]["physical_candidate_field_count"] = 47
        mutations.append(wrong_physical_count)
        duplicate_mode_columns = copy.deepcopy(self.plan_v2)
        mode_columns = duplicate_mode_columns["joint_structural_domain"][
            "screening_design"
        ]["row_generation"]["mode_columns"]
        mode_columns[:] = [copy.deepcopy(mode_columns[0]) for _ in range(4)]
        mutations.append(duplicate_mode_columns)
        duplicate_coordinate_columns = copy.deepcopy(self.plan_v2)
        coordinate_columns = duplicate_coordinate_columns["joint_structural_domain"][
            "screening_design"
        ]["row_generation"]["coordinate_columns"]
        coordinate_columns[:] = [
            copy.deepcopy(coordinate_columns[0]) for _ in range(4)
        ]
        mutations.append(duplicate_coordinate_columns)
        wrong_route_mapping = copy.deepcopy(self.plan_v2)
        wrong_route_mapping["compiler_input_materialization"]["route_mapping"][
            "direct_2x"
        ]["route_spatial_policy_id"] = "direct_3_over_2_route_spatial_policy_id"
        mutations.append(wrong_route_mapping)
        arbitrary_shared_bank_field = copy.deepcopy(self.plan_v2)
        arbitrary_shared_bank_field["search"]["shared_bank_serialization_order"][
            -1
        ] = "arbitrary_field"
        mutations.append(arbitrary_shared_bank_field)
        reordered_logical = copy.deepcopy(self.plan_v2)
        logical_order = reordered_logical["search"]["logical_parameter_order"]
        logical_order[1], logical_order[2] = logical_order[2], logical_order[1]
        mutations.append(reordered_logical)
        reordered_physical = copy.deepcopy(self.plan_v2)
        physical_order = reordered_physical["search"]["physical_candidate_order"]
        physical_order[11], physical_order[12] = physical_order[12], physical_order[11]
        mutations.append(reordered_physical)
        wrong_binding_path = copy.deepcopy(self.plan_v2)
        wrong_binding_path["input_bindings"][0]["path"] = (
            "validation/calibration_v2/schemas/calibration-plan-v1.schema.json"
        )
        mutations.append(wrong_binding_path)
        zero_digest = copy.deepcopy(self.plan_v2)
        zero_digest["plan_sha256"] = "0" * 64
        mutations.append(zero_digest)

        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(ValidationError):
                self.validator_v2.validate(mutation)


if __name__ == "__main__":
    unittest.main()
