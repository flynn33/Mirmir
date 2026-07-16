from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator

from validation.calibration_v2.calibration_plan_codec import (
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    shared_bank_configuration_sha256_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.release_lock import (
    operator_bank_document,
    video_mapping_document,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = (
    CALIBRATION_ROOT
    / "contracts/shared-bank-artifact-materialization-v2.json"
)
CONTRACT_SCHEMA_PATH = (
    CALIBRATION_ROOT
    / "schemas/shared-bank-artifact-materialization-v2.schema.json"
)
MAPPING_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/video-mapping-v2.schema.json"
)
OPERATOR_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/operator-bank-v2.schema.json"
)
MAPPING_V1_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/video-mapping-v1.schema.json"
)
OPERATOR_V1_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/operator-bank-v1.schema.json"
)
PLAN_V1_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v1.json"
PLAN_V2_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"

EXPECTED_CONTRACT_SELF_SHA256 = (
    "c78271a10dad47327f45b35dc6a7016fe5795cc8d964aca679e922e3c3d52de3"
)
EXPECTED_CONTRACT_FILE_SHA256 = (
    "478e35dcbd6217659680a401cfb2c7a7babc0127d8a0ef37c20b755dfbc80112"
)
EXPECTED_CONTRACT_SCHEMA_FILE_SHA256 = (
    "8cfbf68bedcf70afa71f73cbc00526b31e3bf53c857c734f7e9b1a6b0b29267c"
)
EXPECTED_MAPPING_SCHEMA_FILE_SHA256 = (
    "af5302bb26bee4c7ba0944749657a96865c0ce0fbacfe8f2175fbd2c4d499e28"
)
EXPECTED_OPERATOR_SCHEMA_FILE_SHA256 = (
    "5d7d14e912bfa29d90959f9d368f50a784b40e4f603fc8b8146da216eac3c8fd"
)
MAPPING_SEED_SHA256 = (
    "2ebdffa39909012e3284888fd23ede66a68a8a2e270fdfc278b287d109a60e88"
)
OPERATOR_SEED_SHA256 = (
    "7909a226c80fae86a4f38a4f0e52bfb99205f47e1dcecb7c121d1eb62801b137"
)
AUTHORITY = {
    "shared_bank_artifact_materialization_v2_file_sha256": (
        EXPECTED_CONTRACT_FILE_SHA256
    ),
    "shared_bank_artifact_materialization_v2_self_sha256": (
        EXPECTED_CONTRACT_SELF_SHA256
    ),
    "shared_bank_artifact_materialization_v2_schema_file_sha256": (
        EXPECTED_CONTRACT_SCHEMA_FILE_SHA256
    ),
}
MODE_RESOLUTION = {
    0: (0, False),
    1: (0, True),
    2: (1024, True),
    3: (2048, True),
    4: (3072, True),
    5: (4096, True),
}


def _load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _all_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from _all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _all_keys(child)


class SharedBankArtifactMaterializationV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = _load(CONTRACT_PATH)
        cls.contract_schema = _load(CONTRACT_SCHEMA_PATH)
        cls.mapping_schema = _load(MAPPING_SCHEMA_PATH)
        cls.operator_schema = _load(OPERATOR_SCHEMA_PATH)
        cls.mapping_v1_schema = _load(MAPPING_V1_SCHEMA_PATH)
        cls.operator_v1_schema = _load(OPERATOR_V1_SCHEMA_PATH)
        cls.plan_v1 = _load(PLAN_V1_PATH)
        cls.plan_v2_document = _load(PLAN_V2_PATH)
        bound_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in cls.plan_v2_document["input_bindings"]
        }
        cls.plan_v2 = parse_calibration_plan_v2(
            PLAN_V2_PATH.read_bytes(),
            bound_payloads=bound_payloads,
        )
        logical = {
            ATOMIC_STRUCTURAL_COORDINATE: 0,
            **dict(cls.plan_v2.scalar_initial_values),
        }
        cls.physical = dict(
            materialize_candidate_vector_v2(logical, cls.plan_v2)
        )
        cls.candidate_identity = cls._candidate_identity()
        cls.mapping = cls._mapping_document()
        cls.operator = cls._operator_document()

    @classmethod
    def _candidate_identity(cls) -> dict[str, object]:
        physical_items = [
            [name, cls.physical[name]]
            for name in cls.plan_v2.physical_candidate_order
        ]
        return {
            "calibration_plan_v2_file_sha256": (
                "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
            ),
            "calibration_plan_v2_self_sha256": (
                "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
            ),
            "calibration_plan_v2_schema_file_sha256": (
                "09a21861104bd1b03667d1207a79d523386ad4431e710ba44e4d298180753c09"
            ),
            "shared_bank_configuration_v2_file_sha256": (
                "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de"
            ),
            "shared_bank_configuration_v2_self_sha256": (
                "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37"
            ),
            "shared_bank_configuration_v2_schema_file_sha256": (
                "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c"
            ),
            "physical_candidate_field_count": 48,
            "physical_candidate_items": physical_items,
            "candidate_vector_sha256": candidate_vector_sha256_v2(
                cls.physical,
                cls.plan_v2,
            ),
            "shared_bank_configuration_sha256": (
                shared_bank_configuration_sha256_v2(
                    cls.physical,
                    cls.plan_v2,
                )
            ),
        }

    @classmethod
    def _mapping_document(cls) -> dict[str, object]:
        physical = cls.physical
        return {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_video_mapping_v2",
            "status": "calibration_candidate",
            "mapping_id": "ash-video-mapping-v2",
            "configuration_id": "schema-v2-fixture-001",
            "mapping_seed_sha256": MAPPING_SEED_SHA256,
            "materialization_authority": dict(AUTHORITY),
            "candidate_identity": deepcopy(cls.candidate_identity),
            "selection_binding": {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            },
            "canonical_core_unchanged": True,
            "input_contract": {
                "bit_depth": 8,
                "chroma_siting": "left",
                "matrix": "BT.709",
                "pixel_format": "420v",
                "range": "video",
                "subsampling": "4:2:0",
            },
            "boundary_mode": physical["boundary_mode"],
            "analysis_grid_source_steps": {
                "direct_2x": physical[
                    "direct_2x_analysis_grid_source_step"
                ],
                "direct_3_over_2": physical[
                    "direct_3_over_2_analysis_grid_source_step"
                ],
            },
            "thresholds_unorm15": {
                name: {
                    "low": physical[f"{name}_low_unorm15"],
                    "high": physical[f"{name}_high_unorm15"],
                }
                for name in (
                    "edge_present",
                    "coherent_structure",
                    "texture_high_frequency",
                    "alias_or_ringing_risk",
                    "chroma_luma_structure_aligned",
                )
            }
            | {"temporal_support_valid": {"low": 32767, "high": 32767}},
            "analysis_epsilon_q0_30": physical["analysis_epsilon_q0_30"],
            "risk_weights_unorm15": {
                "laplacian": physical["risk_laplacian_weight_unorm15"],
                "alternating_difference": (
                    32767 - physical["risk_laplacian_weight_unorm15"]
                ),
            },
            "chroma_edge_confidence_unorm15": physical[
                "chroma_edge_confidence_unorm15"
            ],
        }

    @classmethod
    def _operator_document(cls) -> dict[str, object]:
        physical = cls.physical

        def route_plane(prefix: str) -> dict[str, object]:
            ordinal = physical[f"{prefix}_anisotropy_mode_ordinal"]
            strength, use = MODE_RESOLUTION[ordinal]
            return {
                "anisotropy_mode_ordinal": ordinal,
                "resolved_anisotropy_strength_q12": strength,
                "resolved_use_anisotropy": use,
                "coordinate_policy": physical[f"{prefix}_coordinate_policy"],
            }

        return {
            "schema_version": "2.0.0",
            "artifact_kind": "p06_operator_bank_v2",
            "status": "calibration_candidate",
            "operator_bank_id": "ash-spatial-operator-bank-v2",
            "configuration_id": "schema-v2-fixture-001",
            "operator_bank_seed_sha256": OPERATOR_SEED_SHA256,
            "materialization_authority": dict(AUTHORITY),
            "candidate_identity": deepcopy(cls.candidate_identity),
            "selection_binding": {
                "calibration_selection_sha256": None,
                "selected_evaluation_sha256": None,
            },
            "boundary_mode": physical["boundary_mode"],
            "routes": {
                "direct_2x": {
                    "route_spatial_policy_id": physical[
                        "direct_2x_route_spatial_policy_id"
                    ],
                    "luma": route_plane("direct_2x_luma"),
                    "chroma": route_plane("direct_2x_chroma"),
                },
                "direct_3_over_2": {
                    "route_spatial_policy_id": physical[
                        "direct_3_over_2_route_spatial_policy_id"
                    ],
                    "luma": route_plane("direct_3_over_2_luma"),
                    "chroma": route_plane("direct_3_over_2_chroma"),
                },
            },
            "operator_parameters": {
                "minimum_anisotropic_magnitude_unorm15": physical[
                    "minimum_anisotropic_magnitude_unorm15"
                ],
                "minimum_anisotropic_coherence_unorm15": physical[
                    "minimum_anisotropic_coherence_unorm15"
                ],
                "detail_gain_q12": physical["detail_gain_q12"],
                "relaxed_limiter_alpha_q12": physical[
                    "relaxed_limiter_alpha_q12"
                ],
                "risk_detail_suppression_unorm15": physical[
                    "risk_detail_suppression_unorm15"
                ],
                "low_pass_radius_q8_8": physical["low_pass_radius_q8_8"],
                "weight_epsilon_f32_bits": 730643660,
            },
            "semantic_steps": {
                "orientation_sector_step": 1,
                "support_radius_step_q8_8": physical[
                    "support_radius_step_q8_8"
                ],
                "detail_gain_step_q12": physical["detail_gain_step_q12"],
                "regularization_step_q12": physical[
                    "regularization_step_q12"
                ],
            },
        }

    def assert_valid(
        self,
        document: dict[str, object],
        schema: dict[str, object],
    ) -> None:
        self.assertEqual(
            list(Draft202012Validator(schema).iter_errors(document)),
            [],
        )

    def assert_invalid(
        self,
        document: dict[str, object],
        schema: dict[str, object],
    ) -> None:
        self.assertNotEqual(
            list(Draft202012Validator(schema).iter_errors(document)),
            [],
        )

    def test_authority_schema_self_hash_canonical_bytes_and_bindings(self) -> None:
        for schema in (
            self.contract_schema,
            self.mapping_schema,
            self.operator_schema,
        ):
            Draft202012Validator.check_schema(schema)

        self.assert_valid(self.contract, self.contract_schema)
        self.assertEqual(self.contract_schema["const"], self.contract)
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            self.contract["artifact_sha256"],
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(_file_sha256(CONTRACT_PATH), EXPECTED_CONTRACT_FILE_SHA256)
        self.assertEqual(
            _file_sha256(CONTRACT_SCHEMA_PATH),
            EXPECTED_CONTRACT_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            _file_sha256(MAPPING_SCHEMA_PATH),
            EXPECTED_MAPPING_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            _file_sha256(OPERATOR_SCHEMA_PATH),
            EXPECTED_OPERATOR_SCHEMA_FILE_SHA256,
        )
        for path in (
            CONTRACT_PATH,
            CONTRACT_SCHEMA_PATH,
            MAPPING_SCHEMA_PATH,
            OPERATOR_SCHEMA_PATH,
        ):
            document = _load(path)
            self.assertEqual(path.read_bytes(), canonical_json_bytes(document) + b"\n")

        for binding in self.contract["authority_bindings"]:
            path = ROOT / binding["path"]
            payload = path.read_bytes()
            self.assertEqual(len(payload), binding["size_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])
            if binding["self_hash"] is not None:
                field = binding["self_hash"]["field"]
                document = json.loads(payload)
                self.assertEqual(document[field], binding["self_hash"]["sha256"])
                self.assertEqual(
                    manifest_sha256(document, field=field),
                    binding["self_hash"]["sha256"],
                )

        for schema in (self.mapping_schema, self.operator_schema):
            self.assertEqual(
                schema["$defs"]["materializationAuthority"]["const"],
                AUTHORITY,
            )

    def test_schema_dispatch_is_exact_and_v1_bytes_are_immutable(self) -> None:
        dispatch = self.contract["schema_dispatch"]
        self.assertEqual(dispatch["discriminator_json_pointer"], "/schema_version")
        self.assertTrue(dispatch["dispatch_before_artifact_decode"])
        self.assertTrue(dispatch["unknown_version_rejected"])
        self.assertTrue(dispatch["cross_version_pairing_rejected"])
        self.assertTrue(dispatch["cross_version_projection_rejected"])
        self.assertFalse(dispatch["v1_to_v2_projection_defined"])
        self.assertFalse(dispatch["v2_to_v1_projection_defined"])
        self.assertEqual(
            [
                (
                    family["candidate_plan_schema_version"],
                    family["mapping_schema_version"],
                    family["operator_bank_schema_version"],
                    family["compiler_input_schema_version"],
                    family["swift_type_family"],
                )
                for family in dispatch["families"]
            ],
            [
                ("1.0.0", "1.0.0", "1.0.0", "1.0.0", "V2"),
                ("2.0.0", "2.0.0", "2.0.0", "2.0.0", "V3"),
            ],
        )
        self.assertEqual(
            _file_sha256(MAPPING_V1_SCHEMA_PATH),
            "307a61418e2cf4441c86167e4af48c59ce149a65b186455fe3194d9b18841b28",
        )
        self.assertEqual(
            _file_sha256(OPERATOR_V1_SCHEMA_PATH),
            "157f4d3fa02af88e50a1daba3664aa442aae76b6378566a485b9c4d8a5c6ef07",
        )

        initial_v1 = self.plan_v1["search"]["initial_vector_values"]
        mapping_v1 = video_mapping_document(
            vector=initial_v1,
            plan=self.plan_v1,
            configuration_id="schema-v1-fixture-001",
            mapping_seed_sha256=MAPPING_SEED_SHA256,
            status="calibration_candidate",
        )
        operator_v1 = operator_bank_document(
            vector=initial_v1,
            plan=self.plan_v1,
            configuration_id="schema-v1-fixture-001",
            operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
            status="calibration_candidate",
        )
        self.assert_valid(mapping_v1, self.mapping_v1_schema)
        self.assert_valid(operator_v1, self.operator_v1_schema)
        self.assert_invalid(mapping_v1, self.mapping_schema)
        self.assert_invalid(operator_v1, self.operator_schema)
        self.assert_invalid(self.mapping, self.mapping_v1_schema)
        self.assert_invalid(self.operator, self.operator_v1_schema)

    def test_exact_48_field_candidate_identity_and_v2_artifacts_validate(self) -> None:
        self.assert_valid(self.mapping, self.mapping_schema)
        self.assert_valid(self.operator, self.operator_schema)
        expected_order = self.contract["candidate_ownership"][
            "physical_candidate_order"
        ]
        items = self.candidate_identity["physical_candidate_items"]
        self.assertEqual(len(items), 48)
        self.assertEqual([item[0] for item in items], expected_order)
        self.assertEqual(expected_order, list(self.plan_v2.physical_candidate_order))
        self.assertEqual(
            self.candidate_identity["candidate_vector_sha256"],
            candidate_vector_sha256_v2(self.physical, self.plan_v2),
        )
        self.assertEqual(
            self.candidate_identity["shared_bank_configuration_sha256"],
            shared_bank_configuration_sha256_v2(self.physical, self.plan_v2),
        )
        self.assertEqual(
            self.mapping["candidate_identity"],
            self.operator["candidate_identity"],
        )

        wrong_count = deepcopy(self.mapping)
        wrong_count["candidate_identity"]["physical_candidate_field_count"] = 47
        self.assert_invalid(wrong_count, self.mapping_schema)
        missing = deepcopy(self.mapping)
        missing["candidate_identity"]["physical_candidate_items"].pop()
        self.assert_invalid(missing, self.mapping_schema)
        swapped = deepcopy(self.operator)
        items = swapped["candidate_identity"]["physical_candidate_items"]
        items[0], items[1] = items[1], items[0]
        self.assert_invalid(swapped, self.operator_schema)
        out_of_domain = deepcopy(self.operator)
        out_of_domain["candidate_identity"]["physical_candidate_items"][3][1] = 6
        self.assert_invalid(out_of_domain, self.operator_schema)

    def test_all_48_candidate_item_schemas_match_bound_plan_domains(self) -> None:
        mapping_items = self.mapping_schema["$defs"]["physicalCandidateItems"]
        operator_items = self.operator_schema["$defs"]["physicalCandidateItems"]
        self.assertEqual(mapping_items, operator_items)
        prefix_items = mapping_items["prefixItems"]
        expected_order = list(self.plan_v2.physical_candidate_order)
        self.assertEqual(len(prefix_items), 48)
        self.assertEqual(
            [item["prefixItems"][0]["const"] for item in prefix_items],
            expected_order,
        )

        structural_domains = self.plan_v2_document["joint_structural_domain"][
            "factor_domains"
        ]
        scalar_domains = dict(self.plan_v2.scalar_domains)
        for index, name in enumerate(expected_order):
            value_schema = prefix_items[index]["prefixItems"][1]
            with self.subTest(field=name):
                if name == "spatial_structural_vector_ordinal":
                    self.assertEqual(
                        value_schema,
                        {"maximum": 255, "minimum": 0, "type": "integer"},
                    )
                elif name.endswith("route_spatial_policy_id"):
                    self.assertEqual(
                        value_schema,
                        {
                            "enum": structural_domains[
                                "route_spatial_policy_id"
                            ],
                            "type": "integer",
                        },
                    )
                elif name.endswith("anisotropy_mode_ordinal"):
                    self.assertEqual(
                        value_schema,
                        {
                            "enum": structural_domains[
                                "anisotropy_mode_ordinal"
                            ],
                            "type": "integer",
                        },
                    )
                elif name.endswith("coordinate_policy"):
                    self.assertEqual(
                        value_schema,
                        {
                            "enum": structural_domains["coordinate_policy"],
                            "type": "string",
                        },
                    )
                else:
                    domain = list(scalar_domains[name])
                    expected_type = (
                        "integer" if type(domain[0]) is int else "string"
                    )
                    self.assertEqual(
                        value_schema,
                        {"enum": domain, "type": expected_type},
                    )

    def test_route_plane_mode_resolution_is_validation_only_and_exact(self) -> None:
        self.assertNotIn("anisotropy_strength_q12", set(_all_keys(self.operator)))
        for ordinal, (strength, use) in MODE_RESOLUTION.items():
            candidate = deepcopy(self.operator)
            plane = candidate["routes"]["direct_2x"]["luma"]
            plane["anisotropy_mode_ordinal"] = ordinal
            plane["resolved_anisotropy_strength_q12"] = strength
            plane["resolved_use_anisotropy"] = use
            with self.subTest(ordinal=ordinal):
                self.assert_valid(candidate, self.operator_schema)

        wrong_strength = deepcopy(self.operator)
        wrong_strength["routes"]["direct_3_over_2"]["chroma"][
            "resolved_anisotropy_strength_q12"
        ] = 0
        self.assert_invalid(wrong_strength, self.operator_schema)
        wrong_use = deepcopy(self.operator)
        wrong_use["routes"]["direct_3_over_2"]["chroma"][
            "resolved_use_anisotropy"
        ] = False
        self.assert_invalid(wrong_use, self.operator_schema)
        global_strength = deepcopy(self.operator)
        global_strength["operator_parameters"]["anisotropy_strength_q12"] = 3072
        self.assert_invalid(global_strength, self.operator_schema)
        all_isotropic = deepcopy(self.operator)
        for route in all_isotropic["routes"].values():
            for plane in (route["luma"], route["chroma"]):
                plane["anisotropy_mode_ordinal"] = 0
                plane["resolved_anisotropy_strength_q12"] = 0
                plane["resolved_use_anisotropy"] = False
        self.assert_invalid(all_isotropic, self.operator_schema)

        materialization = self.contract["operator_bank_materialization"]
        self.assertTrue(
            materialization[
                "route_plane_mode_ordinal_is_sole_anisotropy_authority"
            ]
        )
        self.assertFalse(
            materialization["global_anisotropy_strength_q12_field_authorized"]
        )
        self.assertEqual(
            materialization["resolved_fields_are_validation_only"],
            [
                "resolved_anisotropy_strength_q12",
                "resolved_use_anisotropy",
            ],
        )

    def test_candidate_and_locked_selection_states_are_non_ambiguous(self) -> None:
        for document, schema in (
            (self.mapping, self.mapping_schema),
            (self.operator, self.operator_schema),
        ):
            candidate_with_selection = deepcopy(document)
            candidate_with_selection["selection_binding"] = {
                "calibration_selection_sha256": "a" * 64,
                "selected_evaluation_sha256": "b" * 64,
            }
            self.assert_invalid(candidate_with_selection, schema)

            locked = deepcopy(document)
            locked["status"] = "locked_before_p07"
            self.assert_invalid(locked, schema)
            locked["selection_binding"] = {
                "calibration_selection_sha256": "a" * 64,
                "selected_evaluation_sha256": "b" * 64,
            }
            self.assert_valid(locked, schema)

        self.assertEqual(self.contract["status"], "preregistered_not_executed")
        self.assertEqual(
            self.contract["selection_state"],
            {
                "candidate_selection_performed": False,
                "default_configuration_selected": False,
                "selected_winner": None,
                "selection_results_present": False,
            },
        )
        self.assertTrue(self.contract["execution_boundary"]["authority_only"])
        self.assertFalse(
            self.contract["execution_boundary"][
                "production_execution_authorized_by_this_contract_alone"
            ]
        )

    def test_digest_names_bind_complete_canonical_file_bytes(self) -> None:
        digest = self.contract["digest_semantics"]
        self.assertEqual(
            digest["field_names_unchanged"],
            ["mapping_sha256", "operator_bank_sha256"],
        )
        self.assertEqual(digest["file_trailing_lf_count"], 1)
        self.assertTrue(digest["digest_recomputed_from_reopened_published_bytes"])
        self.assertTrue(digest["semantic_projection_digest_forbidden"])
        for document in (self.mapping, self.operator):
            payload = canonical_json_bytes(document) + b"\n"
            digest_value = hashlib.sha256(payload).hexdigest()
            changed = deepcopy(document)
            changed["configuration_id"] = "schema-v2-fixture-002"
            changed_payload = canonical_json_bytes(changed) + b"\n"
            self.assertNotEqual(payload, changed_payload)
            self.assertNotEqual(
                digest_value,
                hashlib.sha256(changed_payload).hexdigest(),
            )
            self.assertNotEqual(
                digest_value,
                hashlib.sha256(payload[:-1]).hexdigest(),
            )


if __name__ == "__main__":
    unittest.main()
