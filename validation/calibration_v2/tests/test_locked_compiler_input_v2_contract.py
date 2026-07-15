from __future__ import annotations

import copy
import hashlib
import itertools
import json
from pathlib import Path
import unittest

from jsonschema import Draft202012Validator, ValidationError

from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
SCHEMA_V1_PATH = CALIBRATION_ROOT / "schemas/locked-compiler-input-v1.schema.json"
SCHEMA_V2_PATH = CALIBRATION_ROOT / "schemas/locked-compiler-input-v2.schema.json"
TEMPLATE_V1_PATH = CALIBRATION_ROOT / "contracts/locked-compiler-input-v1.template.json"
TEMPLATE_V2_PATH = CALIBRATION_ROOT / "contracts/locked-compiler-input-v2.template.json"
FIXTURE_V1_PATH = CALIBRATION_ROOT / "fixtures/locked-compiler-input-shared-v1.json"
PLANE_PREREGISTRATION_PATH = (
    CALIBRATION_ROOT / "contracts/plane-aware-lut-preregistration-v1.json"
)
ADMISSIBILITY_MANIFEST_PATH = (
    CALIBRATION_ROOT / "locks/spatial-policy-admissibility-manifest.json"
)
README_PATH = CALIBRATION_ROOT / "README.md"

EXPECTED_V1_FILE_HASHES = {
    SCHEMA_V1_PATH: "d54b4051fb360d9d04fcf85a5c3ab3d73e13144cc14985aec387e591aa1b2444",
    TEMPLATE_V1_PATH: "7d753b7a2043114cc5ed04115d69954f7c44fc4ba5b8eb75b2942d289554dd14",
    FIXTURE_V1_PATH: "ba5438b47365c92175a6601aa757138648251004f0e4ddeba13969fdaa0428bb",
}
EXPECTED_PLANE_PREREGISTRATION_FILE_SHA256 = (
    "4f2c5aa2ef510e46f51080863056d3aff4b142825318ff20f4a3443197db04f3"
)
EXPECTED_PLANE_PREREGISTRATION_SELF_SHA256 = (
    "8d4f998983d9ebf092fe756d4287580337b9959dc1505cb16b501e94c8d2d8d2"
)
HASH_BINDING_FIELDS = (
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "compiler_inputs_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
)
ROUTES = ("direct_2x", "direct_3_over_2")
MODE_FIELDS = (
    "luma_anisotropy_mode_ordinal",
    "chroma_anisotropy_mode_ordinal",
)
COORDINATE_FIELDS = (
    "luma_coordinate_policy",
    "chroma_coordinate_policy",
)


def load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compiler_input_self_hash(document: dict[str, object]) -> str:
    payload = copy.deepcopy(document)
    hash_bindings = payload["hash_bindings"]
    if not isinstance(hash_bindings, dict):
        raise AssertionError("hash_bindings must be an object")
    hash_bindings.pop("compiler_inputs_sha256")
    return hashlib.sha256(canonical_json_bytes(payload)).hexdigest()


def all_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_keys(child)


class LockedCompilerInputV2ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema_v1 = load_object(SCHEMA_V1_PATH)
        cls.schema_v2 = load_object(SCHEMA_V2_PATH)
        cls.template_v2 = load_object(TEMPLATE_V2_PATH)
        cls.fixture_v1 = load_object(FIXTURE_V1_PATH)
        cls.preregistration = load_object(PLANE_PREREGISTRATION_PATH)
        cls.admissibility = load_object(ADMISSIBILITY_MANIFEST_PATH)
        cls.validator_v1 = Draft202012Validator(cls.schema_v1)
        cls.validator_v2 = Draft202012Validator(cls.schema_v2)

    def valid_v2_document(self) -> dict[str, object]:
        document = copy.deepcopy(self.fixture_v1)
        document["schema_version"] = "2.0.0"
        operator = document["operator_parameters"]
        assert isinstance(operator, dict)
        operator.pop("anisotropy_strength_q12")
        routes = document["routes"]
        assert isinstance(routes, dict)
        routes["direct_2x"].update(
            {
                "route_spatial_policy_id": 0,
                "luma_anisotropy_mode_ordinal": 1,
                "chroma_anisotropy_mode_ordinal": 0,
            }
        )
        routes["direct_3_over_2"].update(
            {
                "route_spatial_policy_id": 16,
                "luma_anisotropy_mode_ordinal": 0,
                "chroma_anisotropy_mode_ordinal": 1,
            }
        )
        source_aligned = document["source_aligned"]
        assert isinstance(source_aligned, dict)
        source_aligned["predicate"] = self.preregistration["source_exact"][
            "format_1_2_predicate"
        ]
        hashes = document["hash_bindings"]
        assert isinstance(hashes, dict)
        hashes["compiler_inputs_sha256"] = compiler_input_self_hash(document)
        return document

    def validate_v2_document(self, document: dict[str, object]) -> None:
        self.validator_v2.validate(document)
        hashes = document["hash_bindings"]
        if not isinstance(hashes, dict):
            raise AssertionError("hash_bindings must be an object")
        if hashes["compiler_inputs_sha256"] != compiler_input_self_hash(document):
            raise AssertionError("compiler input self-hash mismatch")

    def rehash(self, document: dict[str, object]) -> None:
        hashes = document["hash_bindings"]
        assert isinstance(hashes, dict)
        hashes["compiler_inputs_sha256"] = compiler_input_self_hash(document)

    def test_schema_is_valid_and_cross_version_dispatch_is_closed(self) -> None:
        Draft202012Validator.check_schema(self.schema_v1)
        Draft202012Validator.check_schema(self.schema_v2)
        document = self.valid_v2_document()
        self.validate_v2_document(document)
        with self.assertRaises(ValidationError):
            self.validator_v1.validate(document)
        with self.assertRaises(ValidationError):
            self.validator_v2.validate(self.fixture_v1)
        with self.assertRaises(ValidationError):
            self.validator_v2.validate(self.template_v2)

    def test_v1_schema_template_and_fixture_bytes_remain_frozen(self) -> None:
        for path, expected in EXPECTED_V1_FILE_HASHES.items():
            with self.subTest(path=path.name):
                self.assertEqual(file_sha256(path), expected)
        self.validator_v1.validate(self.fixture_v1)

    def test_plane_preregistration_and_admissibility_domains_are_exact(self) -> None:
        self.assertEqual(
            file_sha256(PLANE_PREREGISTRATION_PATH),
            EXPECTED_PLANE_PREREGISTRATION_FILE_SHA256,
        )
        self.assertEqual(
            self.preregistration["artifact_sha256"],
            EXPECTED_PLANE_PREREGISTRATION_SELF_SHA256,
        )
        route = self.schema_v2["$defs"]["routeSelection"]["properties"]
        self.assertEqual(
            route["route_spatial_policy_id"]["enum"],
            self.preregistration["compiler_semantics"]["admissible_policy_ids"],
        )
        admissible = [
            row["policy_id"]
            for row in self.admissibility["policy_records"]
            if row["g05_semantically_admissible"]
        ]
        self.assertEqual(route["route_spatial_policy_id"]["enum"], admissible)
        expected_ordinals = [
            row["mode_ordinal"]
            for row in self.preregistration["compiler_semantics"]["mode_domain"]
        ]
        self.assertEqual(expected_ordinals, [0, 1, 2, 3, 4, 5])
        for field in MODE_FIELDS:
            self.assertEqual(route[field]["enum"], expected_ordinals)
        self.assertEqual(
            route["luma_coordinate_policy"]["enum"],
            self.preregistration["compiler_semantics"]["coordinate_policy_domain"],
        )
        self.assertEqual(
            route["chroma_coordinate_policy"]["enum"],
            self.preregistration["compiler_semantics"]["coordinate_policy_domain"],
        )
        zero_strength_modes = [
            row
            for row in self.preregistration["compiler_semantics"]["mode_domain"]
            if row["anisotropy_strength_q12"] == 0
        ]
        self.assertEqual(
            [(row["mode_ordinal"], row["use_anisotropy"]) for row in zero_strength_modes],
            [(0, False), (1, True)],
        )

    def test_schema_two_preserves_shared_v1_scope_and_six_hashes(self) -> None:
        properties_v1 = self.schema_v1["properties"]
        properties_v2 = self.schema_v2["properties"]
        self.assertEqual(tuple(properties_v2), tuple(properties_v1))
        for field in (
            "status",
            "configuration_id",
            "hash_bindings",
            "canonicalization",
            "boundary_mode",
            "semantic_steps",
            "compiler_policy",
            "temporal",
            "top_two",
        ):
            with self.subTest(field=field):
                self.assertEqual(properties_v2[field], properties_v1[field])
        operator_v1 = properties_v1["operator_parameters"]
        operator_v2 = properties_v2["operator_parameters"]
        expected_operator_fields = [
            field
            for field in operator_v1["required"]
            if field != "anisotropy_strength_q12"
        ]
        self.assertEqual(operator_v2["required"], expected_operator_fields)
        self.assertEqual(
            operator_v2["properties"],
            {
                key: value
                for key, value in operator_v1["properties"].items()
                if key != "anisotropy_strength_q12"
            },
        )
        hash_bindings = properties_v2["hash_bindings"]
        self.assertEqual(tuple(hash_bindings["required"]), HASH_BINDING_FIELDS)
        self.assertEqual(tuple(hash_bindings["properties"]), HASH_BINDING_FIELDS)
        self.assertNotIn("contract_bindings", properties_v2)
        self.assertNotIn("format", properties_v2)

    def test_source_exactness_is_plane_local_and_confidence_is_not_input(self) -> None:
        source = self.schema_v2["properties"]["source_aligned"]["const"]
        self.assertEqual(
            source["predicate"],
            self.preregistration["source_exact"]["format_1_2_predicate"],
        )
        self.assertNotEqual(
            source["predicate"],
            self.preregistration["source_exact"]["format_1_1_predicate_frozen"],
        )
        schema_keys = set(all_keys(self.schema_v2))
        for prohibited in (
            "chroma_edge_confidence",
            "chroma_edge_confidence_value",
            "selected_winner",
            "winner",
            "default",
        ):
            self.assertNotIn(prohibited, schema_keys)
        self.assertEqual(
            self.preregistration["runtime_confidence"]["header_abi_marker"],
            {"offset": 305, "value": 1},
        )
        self.assertFalse(
            self.preregistration["runtime_confidence"]["lut_value_storage"]
        )

    def test_all_policy_ids_modes_and_coordinate_vectors_are_schema_valid(self) -> None:
        admissible = self.preregistration["compiler_semantics"]["admissible_policy_ids"]
        for route_name in ROUTES:
            for policy_id in admissible:
                document = self.valid_v2_document()
                document["routes"][route_name]["route_spatial_policy_id"] = policy_id
                self.rehash(document)
                with self.subTest(route=route_name, policy_id=policy_id):
                    self.validate_v2_document(document)

        for route_name in ROUTES:
            for field in MODE_FIELDS:
                for ordinal in range(6):
                    document = self.valid_v2_document()
                    document["routes"][route_name][field] = ordinal
                    self.rehash(document)
                    with self.subTest(route=route_name, field=field, ordinal=ordinal):
                        self.validate_v2_document(document)

        positions = tuple((route, field) for route in ROUTES for field in COORDINATE_FIELDS)
        policies = ("half_pixel_center", "source_aligned_rational")
        for vector in itertools.product(policies, repeat=4):
            document = self.valid_v2_document()
            for (route_name, field), value in zip(positions, vector):
                document["routes"][route_name][field] = value
            self.rehash(document)
            with self.subTest(vector=vector):
                self.validate_v2_document(document)

    def test_all_isotropic_vector_is_rejected_but_rotated_zero_is_distinct(self) -> None:
        document = self.valid_v2_document()
        for route_name in ROUTES:
            for field in MODE_FIELDS:
                document["routes"][route_name][field] = 0
        self.rehash(document)
        with self.assertRaises(ValidationError):
            self.validate_v2_document(document)

        document["routes"]["direct_3_over_2"][
            "chroma_anisotropy_mode_ordinal"
        ] = 1
        self.rehash(document)
        self.validate_v2_document(document)

    def test_prohibited_ids_fields_defaults_and_stale_hash_fail_closed(self) -> None:
        for policy_id in (-1, 8, 15, 24, 47, 48):
            document = self.valid_v2_document()
            document["routes"]["direct_2x"]["route_spatial_policy_id"] = policy_id
            self.rehash(document)
            with self.subTest(policy_id=policy_id), self.assertRaises(ValidationError):
                self.validate_v2_document(document)

        for ordinal in (-1, 6):
            document = self.valid_v2_document()
            document["routes"]["direct_2x"]["luma_anisotropy_mode_ordinal"] = ordinal
            self.rehash(document)
            with self.subTest(ordinal=ordinal), self.assertRaises(ValidationError):
                self.validate_v2_document(document)

        mutations = []
        global_anisotropy = self.valid_v2_document()
        global_anisotropy["operator_parameters"]["anisotropy_strength_q12"] = 3072
        mutations.append(global_anisotropy)
        confidence = self.valid_v2_document()
        confidence["chroma_edge_confidence"] = 1
        mutations.append(confidence)
        winner = self.valid_v2_document()
        winner["selected_winner"] = "candidate"
        mutations.append(winner)
        default = self.valid_v2_document()
        default["default_configuration"] = True
        mutations.append(default)
        per_plane_policy = self.valid_v2_document()
        per_plane_policy["routes"]["direct_2x"]["luma_spatial_policy_id"] = 0
        mutations.append(per_plane_policy)
        missing_mode = self.valid_v2_document()
        missing_mode["routes"]["direct_2x"].pop("luma_anisotropy_mode_ordinal")
        mutations.append(missing_mode)

        for mutation in mutations:
            self.rehash(mutation)
            with self.subTest(keys=sorted(mutation)), self.assertRaises(ValidationError):
                self.validate_v2_document(mutation)

        stale = self.valid_v2_document()
        stale["boundary_mode"] = "clamp"
        with self.assertRaises(AssertionError):
            self.validate_v2_document(stale)

    def test_template_and_readme_preserve_the_no_selection_boundary(self) -> None:
        serialized = TEMPLATE_V2_PATH.read_text(encoding="utf-8")
        self.assertIn("<replace after fresh current-source formal selection>", serialized)
        self.assertNotIn('"selected_winner"', serialized)
        self.assertNotIn('"winner"', serialized)
        self.assertNotIn('"default_configuration"', serialized)
        readme = README_PATH.read_text(encoding="utf-8")
        self.assertIn("locked-compiler-input-v2.template.json", readme)
        self.assertIn("mode ordinal is the sole compiler-input authority", readme)
        self.assertIn("consumable schema-2 input may be generated", readme)
        self.assertIn("unchanged `calibration_plan_sha256` field", readme)


if __name__ == "__main__":
    unittest.main()
