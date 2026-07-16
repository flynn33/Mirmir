from __future__ import annotations

import base64
from collections.abc import Mapping
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from jsonschema import Draft202012Validator

from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    SHARED_BANK_DOMAIN_SEPARATOR_V2,
    SHARED_BANK_SERIALIZATION_ORDER_V2,
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    serialized_shared_bank_configuration_v2,
    shared_bank_configuration_sha256_v2,
    validate_candidate_constraints_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.release_lock import (
    ReleaseLockError,
    shared_bank_configuration_sha256_for_plan,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = (
    CALIBRATION_ROOT
    / "contracts/shared-bank-configuration-identity-v2.json"
)
SCHEMA_PATH = (
    CALIBRATION_ROOT
    / "schemas/shared-bank-configuration-identity-v2.schema.json"
)
COMPILER_INPUT_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/locked-compiler-input-v2.schema.json"
)
COMPILER_INPUT_TEMPLATE_PATH = (
    CALIBRATION_ROOT / "contracts/locked-compiler-input-v2.template.json"
)
PLAN_V1_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v1.json"
PLAN_V2_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
PLAN_V1_SCHEMA_PATH = CALIBRATION_ROOT / "schemas/calibration-plan-v1.schema.json"
SWIFT_CANONICAL_JSON_PATH = (
    ROOT / "Mirmir/Modules/UpscalerEngine/ASH/ASHStrictJSONV2.swift"
)

EXPECTED_CONTRACT_SELF_SHA256 = (
    "e522afa73e8dc01c51303d1d1d99a95fe2ea78f968a2696dc0583f695fce7c37"
)
EXPECTED_CONTRACT_FILE_SHA256 = (
    "48f5eef7cf9f7c513cf8e6568b3eeb4d607845c1e70e6c39b6ca0192a4c297de"
)
EXPECTED_CONTRACT_SCHEMA_FILE_SHA256 = (
    "0cee4c9ed9083d734491d90eaa3f02265b07295d7873733c006cce9df317147c"
)
EXPECTED_PLAN_V1_SHA256 = (
    "128244e8fb1450b74e8c81141af40c5188bac8fc151bf272a348c9faa6f1549e"
)
EXPECTED_PLAN_V1_SCHEMA_SHA256 = (
    "051a804b32121a99241270c0199e5f3a90034f717ab05e67019b3d8384a7854a"
)
EXPECTED_V1_INITIAL_SHARED_BANK_SHA256 = (
    "4f348931d7a97fe54400bd126a3aec90a377abcc86c98c25ea92807898e3c66e"
)
EXPECTED_ALL_STRUCTURAL_BANK_HASHES_SHA256 = (
    "8061356804b08d64aca31d20b8f207f02dbe9fc85de7eb9e21e32f5fcdf28719"
)
EXPECTED_ENDPOINTS = {
    0: {
        "candidate": "5ef8b175db2a957509037f5a8c48f1a1238de6e08cf57d7511f44552e1dfb1dc",
        "frame_size": 1130,
        "bank": "a9e66dd89a6b5efe01dc758c4d9947f75e0bcc9f60cc71c20eaa6259bce03e8f",
    },
    255: {
        "candidate": "177893edce952b45ec4a0c64782bc6bb3832e8dfcc21e518020f5e2cb25f65d2",
        "frame_size": 1146,
        "bank": "2f3688a304998e8a2f434728307b819ce8cfc8a6d026671063646fff2a09b86f",
    },
}
V1_SHARED_BANK_COORDINATES = (
    "analysis_epsilon_q0_30",
    "risk_laplacian_weight_unorm15",
    "chroma_edge_confidence_unorm15",
    "direct_2x_analysis_grid_source_step",
    "direct_3_over_2_analysis_grid_source_step",
    "direct_2x_luma_coordinate_policy",
    "direct_2x_chroma_coordinate_policy",
    "direct_3_over_2_luma_coordinate_policy",
    "direct_3_over_2_chroma_coordinate_policy",
    "boundary_mode",
    "anisotropy_strength_q12",
    "minimum_anisotropic_magnitude_unorm15",
    "minimum_anisotropic_coherence_unorm15",
    "detail_gain_q12",
    "relaxed_limiter_alpha_q12",
    "risk_detail_suppression_unorm15",
    "low_pass_radius_q8_8",
)


class TaggedInt(int):
    pass


class TaggedStr(str):
    pass


class FlippingMapping(Mapping[str, object]):
    def __init__(
        self,
        source: Mapping[str, object],
        *,
        target: str,
        replacement: object,
    ) -> None:
        self.source = dict(source)
        self.target = target
        self.replacement = replacement
        self.target_reads = 0

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, key: str) -> object:
        if key == self.target:
            self.target_reads += 1
            if self.target_reads > 1:
                return self.replacement
        return self.source[key]


def _load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _independent_frame(
    domain_separator: str,
    ordered_fields: tuple[str, ...],
    physical: Mapping[str, object],
) -> bytes:
    return json.dumps(
        {
            "domain_separator": domain_separator,
            "ordered_fields": [
                [name, physical[name]] for name in ordered_fields
            ],
        },
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


class SharedBankConfigurationIdentityV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = _load_object(CONTRACT_PATH)
        cls.schema = _load_object(SCHEMA_PATH)
        cls.compiler_input_schema = _load_object(COMPILER_INPUT_SCHEMA_PATH)
        cls.compiler_input_template = _load_object(COMPILER_INPUT_TEMPLATE_PATH)
        cls.plan_v1 = _load_object(PLAN_V1_PATH)
        cls.plan_v2 = _load_object(PLAN_V2_PATH)
        cls.plan_v2_payload = PLAN_V2_PATH.read_bytes()
        cls.bound_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in cls.plan_v2["input_bindings"]
        }
        cls.parsed = parse_calibration_plan_v2(
            cls.plan_v2_payload,
            bound_payloads=cls.bound_payloads,
        )

    def logical_vector(
        self,
        ordinal: int = 0,
        **overrides: object,
    ) -> dict[str, object]:
        vector = {
            ATOMIC_STRUCTURAL_COORDINATE: ordinal,
            **dict(self.parsed.scalar_initial_values),
        }
        vector.update(overrides)
        return vector

    def physical_vector(
        self,
        ordinal: int = 0,
        **overrides: object,
    ) -> dict[str, object]:
        return dict(
            materialize_candidate_vector_v2(
                self.logical_vector(ordinal, **overrides),
                self.parsed,
            )
        )

    def alternate(self, name: str, current: object) -> object:
        domain = dict(self.parsed.scalar_domains)[name]
        return next(
            value
            for value in domain
            if type(value) is type(current) and value != current
        )

    def test_contract_schema_self_hash_serialization_and_bindings_are_exact(
        self,
    ) -> None:
        Draft202012Validator.check_schema(self.schema)
        validator = Draft202012Validator(self.schema)
        self.assertEqual(list(validator.iter_errors(self.contract)), [])
        self.assertEqual(
            self.contract["artifact_sha256"],
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            _file_sha256(CONTRACT_PATH),
            EXPECTED_CONTRACT_FILE_SHA256,
        )
        self.assertEqual(
            _file_sha256(SCHEMA_PATH),
            EXPECTED_CONTRACT_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            CONTRACT_PATH.read_bytes(),
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            SCHEMA_PATH.read_bytes(),
            canonical_json_bytes(self.schema) + b"\n",
        )

        for binding in self.contract["authority_bindings"]:
            with self.subTest(binding=binding["id"]):
                path = ROOT / binding["path"]
                payload = path.read_bytes()
                self.assertEqual(len(payload), binding["size_bytes"])
                self.assertEqual(
                    hashlib.sha256(payload).hexdigest(),
                    binding["sha256"],
                )
                self_hash = binding["self_hash"]
                if self_hash is not None:
                    document = json.loads(payload)
                    self.assertEqual(
                        document[self_hash["field"]],
                        self_hash["sha256"],
                    )
                    self.assertEqual(
                        manifest_sha256(document, field=self_hash["field"]),
                        self_hash["sha256"],
                    )

    def test_parser_exposes_exact_domain_order_indexes_and_types(self) -> None:
        identity = self.contract["identity"]
        order = self.parsed.shared_bank_serialization_order
        self.assertEqual(
            self.parsed.shared_bank_domain_separator,
            SHARED_BANK_DOMAIN_SEPARATOR_V2,
        )
        self.assertEqual(order, SHARED_BANK_SERIALIZATION_ORDER_V2)
        self.assertEqual(identity["domain_separator"], SHARED_BANK_DOMAIN_SEPARATOR_V2)
        self.assertEqual(len(SHARED_BANK_DOMAIN_SEPARATOR_V2.encode("utf-8")), 63)
        self.assertEqual(identity["ordered_fields"], list(order))
        self.assertEqual(len(order), 23)
        self.assertEqual(len(set(order)), 23)
        self.assertTrue(SHARED_BANK_DOMAIN_SEPARATOR_V2.isascii())
        self.assertEqual(
            [self.parsed.physical_candidate_order.index(name) for name in order],
            identity["physical_candidate_indices"],
        )
        self.assertEqual(
            set(order),
            set(identity["integer_fields"]) | set(identity["string_fields"]),
        )
        self.assertEqual(
            set(self.parsed.physical_candidate_order),
            set(order) | set(identity["excluded_physical_fields"]),
        )
        physical = self.physical_vector()
        self.assertEqual(
            [name for name in order if type(physical[name]) is int],
            identity["integer_fields"],
        )
        self.assertEqual(
            [name for name in order if type(physical[name]) is str],
            identity["string_fields"],
        )

    def test_endpoint_frames_match_independent_oracle_and_frozen_goldens(
        self,
    ) -> None:
        for ordinal, expected in EXPECTED_ENDPOINTS.items():
            physical = self.physical_vector(ordinal)
            frame = serialized_shared_bank_configuration_v2(
                physical,
                self.parsed,
            )
            oracle = _independent_frame(
                SHARED_BANK_DOMAIN_SEPARATOR_V2,
                SHARED_BANK_SERIALIZATION_ORDER_V2,
                physical,
            )
            with self.subTest(ordinal=ordinal):
                self.assertEqual(frame, oracle)
                self.assertEqual(len(frame), expected["frame_size"])
                self.assertEqual(
                    hashlib.sha256(frame).hexdigest(),
                    expected["bank"],
                )
                self.assertEqual(
                    shared_bank_configuration_sha256_v2(physical, self.parsed),
                    expected["bank"],
                )
                self.assertEqual(
                    candidate_vector_sha256_v2(physical, self.parsed),
                    expected["candidate"],
                )
                decoded = json.loads(frame)
                self.assertEqual(
                    set(decoded),
                    {"domain_separator", "ordered_fields"},
                )
                self.assertEqual(
                    [pair[0] for pair in decoded["ordered_fields"]],
                    list(SHARED_BANK_SERIALIZATION_ORDER_V2),
                )
                self.assertTrue(
                    all(
                        type(pair) is list and len(pair) == 2
                        for pair in decoded["ordered_fields"]
                    )
                )
                self.assertEqual(canonical_json_bytes(decoded), frame)
                self.assertFalse(frame.startswith(b"\xef\xbb\xbf"))
                self.assertNotIn(b"\r", frame)
                self.assertNotIn(b"\n", frame)
                self.assertNotIn(b"\\/", frame)
                self.assertIn(b"shared-bank-v2/gf16", frame)

    def test_all_structural_rows_have_unique_frozen_bank_hashes(self) -> None:
        bank_hashes = [
            shared_bank_configuration_sha256_v2(
                self.physical_vector(ordinal),
                self.parsed,
            )
            for ordinal in range(256)
        ]
        encoded = canonical_json_bytes(bank_hashes)
        self.assertEqual(len(set(bank_hashes)), 256)
        self.assertEqual(len(encoded), 17153)
        self.assertEqual(
            hashlib.sha256(encoded).hexdigest(),
            EXPECTED_ALL_STRUCTURAL_BANK_HASHES_SHA256,
        )

    def test_included_and_excluded_scalar_coverage_is_exact(self) -> None:
        identity = self.contract["identity"]
        base = self.physical_vector()
        base_bank = shared_bank_configuration_sha256_v2(base, self.parsed)
        base_candidate = candidate_vector_sha256_v2(base, self.parsed)
        included_scalars = SHARED_BANK_SERIALIZATION_ORDER_V2[11:]
        self.assertEqual(len(included_scalars), 12)
        self.assertEqual(len(identity["excluded_physical_fields"]), 25)

        for name in included_scalars:
            changed = dict(base)
            changed[name] = self.alternate(name, changed[name])
            with self.subTest(included=name):
                self.assertNotEqual(
                    shared_bank_configuration_sha256_v2(changed, self.parsed),
                    base_bank,
                )
                self.assertNotEqual(
                    candidate_vector_sha256_v2(changed, self.parsed),
                    base_candidate,
                )

        for name in identity["excluded_physical_fields"]:
            changed = dict(base)
            changed[name] = self.alternate(name, changed[name])
            with self.subTest(excluded=name):
                self.assertEqual(
                    shared_bank_configuration_sha256_v2(changed, self.parsed),
                    base_bank,
                )
                self.assertNotEqual(
                    candidate_vector_sha256_v2(changed, self.parsed),
                    base_candidate,
                )

        infeasible = dict(base)
        infeasible["edge_present_low_unorm15"] = max(
            dict(self.parsed.scalar_domains)["edge_present_low_unorm15"]
        )
        infeasible["edge_present_high_unorm15"] = min(
            dict(self.parsed.scalar_domains)["edge_present_high_unorm15"]
        )
        with self.assertRaises(CalibrationPlanCodecError):
            validate_candidate_constraints_v2(infeasible, self.parsed)
        self.assertEqual(
            shared_bank_configuration_sha256_v2(infeasible, self.parsed),
            base_bank,
        )

    def test_forged_shared_bank_plan_authority_is_rejected(self) -> None:
        order = list(self.parsed.shared_bank_serialization_order)
        swapped = list(order)
        swapped[11], swapped[12] = swapped[12], swapped[11]
        duplicate = list(order)
        duplicate[-1] = duplicate[-2]
        tagged = list(order)
        tagged[0] = TaggedStr(tagged[0])
        forged_catalog = list(self.parsed.structural_vectors)
        forged_first_row = list(forged_catalog[0])
        forged_first_row[0] += 1
        forged_catalog[0] = tuple(forged_first_row)
        forged_models = (
            replace(self.parsed, shared_bank_domain_separator="changed"),
            replace(
                self.parsed,
                shared_bank_domain_separator=TaggedStr(
                    SHARED_BANK_DOMAIN_SEPARATOR_V2
                ),
            ),
            replace(
                self.parsed,
                shared_bank_domain_separator=(
                    SHARED_BANK_DOMAIN_SEPARATOR_V2 + "\x00"
                ),
            ),
            replace(
                self.parsed,
                shared_bank_domain_separator=(
                    SHARED_BANK_DOMAIN_SEPARATOR_V2.encode("utf-8")
                ),
            ),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple(reversed(order)),
            ),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple(swapped),
            ),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple(duplicate),
            ),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple(order[:-1]),
            ),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple((*order, "extra")),
            ),
            replace(self.parsed, shared_bank_serialization_order=order),
            replace(
                self.parsed,
                shared_bank_serialization_order=tuple(tagged),
            ),
            replace(
                self.parsed,
                structural_vectors=tuple(forged_catalog),
            ),
        )
        physical = self.physical_vector()
        for index, forged in enumerate(forged_models):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                shared_bank_configuration_sha256_v2(physical, forged)

    def test_candidate_type_materialization_and_snapshot_guards_are_closed(
        self,
    ) -> None:
        base = self.physical_vector()
        expected = serialized_shared_bank_configuration_v2(base, self.parsed)
        reversed_mapping = dict(reversed(tuple(base.items())))
        self.assertEqual(
            serialized_shared_bank_configuration_v2(
                reversed_mapping,
                self.parsed,
            ),
            expected,
        )

        target = "analysis_epsilon_q0_30"
        flipping = FlippingMapping(
            base,
            target=target,
            replacement=self.alternate(target, base[target]),
        )
        self.assertEqual(
            serialized_shared_bank_configuration_v2(flipping, self.parsed),
            expected,
        )
        self.assertEqual(flipping.target_reads, 1)

        mutations = []
        missing = dict(base)
        missing.pop(target)
        mutations.append(missing)
        extra = dict(base)
        extra["extra"] = 0
        mutations.append(extra)
        wrong_factor = dict(base)
        wrong_factor["direct_2x_route_spatial_policy_id"] += 1
        mutations.append(wrong_factor)
        for replacement in (
            True,
            float(base[target]),
            float("nan"),
            float("inf"),
            TaggedInt(base[target]),
            max(dict(self.parsed.scalar_domains)[target]) + 1,
        ):
            changed = dict(base)
            changed[target] = replacement
            mutations.append(changed)
        tagged_string = dict(base)
        tagged_string["boundary_mode"] = TaggedStr(tagged_string["boundary_mode"])
        mutations.append(tagged_string)
        invalid_string = dict(base)
        invalid_string["boundary_mode"] = "invalid"
        mutations.append(invalid_string)
        tagged_key = {
            (TaggedStr(name) if name == target else name): value
            for name, value in base.items()
        }
        mutations.append(tagged_key)

        for index, mutation in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                serialized_shared_bank_configuration_v2(mutation, self.parsed)

    def test_named_pair_framing_has_no_concatenation_ambiguity(self) -> None:
        domain = SHARED_BANK_DOMAIN_SEPARATOR_V2
        examples = (
            (
                {"domain_separator": domain, "ordered_fields": [["a", 1], ["b", 23]]},
                {"domain_separator": domain, "ordered_fields": [["a", 12], ["b", 3]]},
            ),
            (
                {
                    "domain_separator": domain,
                    "ordered_fields": [["a", "ab"], ["b", "c"]],
                },
                {
                    "domain_separator": domain,
                    "ordered_fields": [["a", "a"], ["b", "bc"]],
                },
            ),
            (
                {"domain_separator": domain, "ordered_fields": [["a", 0], ["b", 0]]},
                {"domain_separator": domain, "ordered_fields": [["b", 0], ["a", 0]]},
            ),
            (
                {"domain_separator": domain, "ordered_fields": [["a", 0]]},
                {"domain_separator": domain + "-changed", "ordered_fields": [["a", 0]]},
            ),
        )
        for index, (left, right) in enumerate(examples):
            with self.subTest(index=index):
                self.assertNotEqual(
                    canonical_json_bytes(left),
                    canonical_json_bytes(right),
                )
                self.assertNotEqual(
                    hashlib.sha256(canonical_json_bytes(left)).hexdigest(),
                    hashlib.sha256(canonical_json_bytes(right)).hexdigest(),
                )

    def test_compiler_projection_is_not_the_shared_bank_identity(self) -> None:
        boundary = self.contract["compiler_projection_boundary"]
        omitted = tuple(
            boundary["shared_bank_candidate_minus_compiler_candidate_fields"]
        )
        self.assertEqual(
            omitted,
            (
                ATOMIC_STRUCTURAL_COORDINATE,
                "analysis_epsilon_q0_30",
                "risk_laplacian_weight_unorm15",
                "chroma_edge_confidence_unorm15",
            ),
        )
        projection_fields = tuple(
            name
            for name in SHARED_BANK_SERIALIZATION_ORDER_V2
            if name not in omitted
        )
        compiler_fields = tuple(boundary["compiler_candidate_fields"])
        compiler_only = tuple(
            boundary["compiler_candidate_minus_shared_bank_candidate_fields"]
        )
        intersection = tuple(
            boundary["shared_bank_and_compiler_candidate_fields"]
        )
        physical_order = self.parsed.physical_candidate_order
        self.assertEqual(boundary["shared_bank_candidate_field_count"], 23)
        self.assertEqual(boundary["compiler_candidate_field_count"], 34)
        self.assertEqual(intersection, projection_fields)
        self.assertEqual(
            set(SHARED_BANK_SERIALIZATION_ORDER_V2) - set(compiler_fields),
            set(omitted),
        )
        self.assertEqual(
            set(compiler_fields) - set(SHARED_BANK_SERIALIZATION_ORDER_V2),
            set(compiler_only),
        )
        self.assertEqual(
            set(compiler_fields) & set(SHARED_BANK_SERIALIZATION_ORDER_V2),
            set(intersection),
        )
        self.assertEqual(
            compiler_fields,
            tuple(name for name in physical_order if name in set(compiler_fields)),
        )

        schema_properties = self.compiler_input_schema["properties"]
        schema_required = set(self.compiler_input_schema["required"])
        route_schema = self.compiler_input_schema["$defs"]["routeSelection"]
        route_required = set(route_schema["required"])
        operator_schema = schema_properties["operator_parameters"]
        semantic_schema = schema_properties["semantic_steps"]
        policy_schema = schema_properties["compiler_policy"]
        compiler_field_to_schema_property = {
            **{
                f"{route}_{name}": (
                    route_schema,
                    self.compiler_input_template["routes"][route],
                    name,
                )
                for route in ("direct_2x", "direct_3_over_2")
                for name in (
                    "route_spatial_policy_id",
                    "luma_anisotropy_mode_ordinal",
                    "chroma_anisotropy_mode_ordinal",
                    "luma_coordinate_policy",
                    "chroma_coordinate_policy",
                    "analysis_grid_source_step",
                )
            },
            "boundary_mode": (
                self.compiler_input_schema,
                self.compiler_input_template,
                "boundary_mode",
            ),
            **{
                name: (
                    operator_schema,
                    self.compiler_input_template["operator_parameters"],
                    name,
                )
                for name in (
                    "minimum_anisotropic_magnitude_unorm15",
                    "minimum_anisotropic_coherence_unorm15",
                    "detail_gain_q12",
                    "relaxed_limiter_alpha_q12",
                    "risk_detail_suppression_unorm15",
                    "low_pass_radius_q8_8",
                )
            },
            **{
                name: (
                    semantic_schema,
                    self.compiler_input_template["semantic_steps"],
                    name,
                )
                for name in (
                    "support_radius_step_q8_8",
                    "detail_gain_step_q12",
                    "regularization_step_q12",
                )
            },
            **{
                name: (
                    policy_schema,
                    self.compiler_input_template["compiler_policy"],
                    name,
                )
                for name in (
                    "penalty_decay_denominator",
                    "penalty_orientation_step",
                    "penalty_support_step",
                    "penalty_detail_step",
                    "penalty_regularization_step",
                    "penalty_unsupported_support_expansion",
                    "penalty_coherent_support_reduction",
                    "penalty_unsupported_detail_increase",
                    "penalty_supported_detail_reduction",
                    "penalty_relaxation_under_risk",
                    "penalty_phase_kernel_mismatch",
                    "confidence_threshold_unorm16",
                )
            },
        }
        self.assertEqual(set(compiler_field_to_schema_property), set(compiler_fields))
        for candidate_field, (schema_node, template_node, property_name) in (
            compiler_field_to_schema_property.items()
        ):
            with self.subTest(compiler_candidate_field=candidate_field):
                self.assertIn(property_name, schema_node["properties"])
                self.assertIn(property_name, schema_node["required"])
                self.assertIn(property_name, template_node)
        self.assertEqual(route_required, set(route_schema["properties"]))
        self.assertIn("routes", schema_required)
        self.assertEqual(
            schema_properties["routes"]["required"],
            ["direct_2x", "direct_3_over_2"],
        )
        self.assertEqual(
            schema_properties["routes"]["properties"],
            {
                "direct_2x": {"$ref": "#/$defs/routeSelection"},
                "direct_3_over_2": {"$ref": "#/$defs/routeSelection"},
            },
        )

        def property_names(value: object) -> set[str]:
            if isinstance(value, dict):
                names = set(value.get("properties", {}))
                for child in value.values():
                    names.update(property_names(child))
                return names
            if isinstance(value, list):
                names: set[str] = set()
                for child in value:
                    names.update(property_names(child))
                return names
            return set()

        self.assertTrue(
            set(omitted).isdisjoint(property_names(self.compiler_input_schema))
        )
        for route in ("direct_2x", "direct_3_over_2"):
            self.assertEqual(
                set(self.compiler_input_template["routes"][route]),
                set(route_schema["properties"]),
            )
        self.assertEqual(
            set(self.compiler_input_template["operator_parameters"])
            - {
                "minimum_anisotropic_magnitude_unorm15",
                "minimum_anisotropic_coherence_unorm15",
                "detail_gain_q12",
                "relaxed_limiter_alpha_q12",
                "risk_detail_suppression_unorm15",
                "low_pass_radius_q8_8",
            },
            {"weight_epsilon_f32_bits"},
        )
        self.assertEqual(
            set(self.compiler_input_template["semantic_steps"])
            - {
                "support_radius_step_q8_8",
                "detail_gain_step_q12",
                "regularization_step_q12",
            },
            {"orientation_sector_step"},
        )
        self.assertEqual(
            set(self.compiler_input_template["compiler_policy"])
            - {
                "penalty_decay_denominator",
                "penalty_orientation_step",
                "penalty_support_step",
                "penalty_detail_step",
                "penalty_regularization_step",
                "penalty_unsupported_support_expansion",
                "penalty_coherent_support_reduction",
                "penalty_unsupported_detail_increase",
                "penalty_supported_detail_reduction",
                "penalty_relaxation_under_risk",
                "penalty_phase_kernel_mismatch",
                "confidence_threshold_unorm16",
            },
            {"penalty_to_weight_unorm16"},
        )
        base = self.physical_vector()
        base_projection = tuple(base[name] for name in projection_fields)
        base_bank = shared_bank_configuration_sha256_v2(base, self.parsed)
        for name in omitted[1:]:
            changed = dict(base)
            changed[name] = self.alternate(name, changed[name])
            with self.subTest(noncompiler_field=name):
                self.assertEqual(
                    tuple(changed[field] for field in projection_fields),
                    base_projection,
                )
                self.assertNotEqual(
                    shared_bank_configuration_sha256_v2(changed, self.parsed),
                    base_bank,
                )

        structural_projections = {
            tuple(self.physical_vector(ordinal)[name] for name in projection_fields)
            for ordinal in range(256)
        }
        self.assertNotIn(ATOMIC_STRUCTURAL_COORDINATE, projection_fields)
        self.assertEqual(len(structural_projections), 256)

    def test_v1_hash_bytes_and_helper_boundary_remain_immutable(self) -> None:
        self.assertEqual(_file_sha256(PLAN_V1_PATH), EXPECTED_PLAN_V1_SHA256)
        self.assertEqual(
            _file_sha256(PLAN_V1_SCHEMA_PATH),
            EXPECTED_PLAN_V1_SCHEMA_SHA256,
        )
        initial = self.plan_v1["search"]["initial_vector_values"]
        v1_frame = json.dumps(
            {name: initial[name] for name in V1_SHARED_BANK_COORDINATES},
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        self.assertEqual(len(v1_frame), 712)
        self.assertEqual(
            hashlib.sha256(v1_frame).hexdigest(),
            EXPECTED_V1_INITIAL_SHARED_BANK_SHA256,
        )
        self.assertEqual(
            shared_bank_configuration_sha256_for_plan(initial, self.plan_v1),
            EXPECTED_V1_INITIAL_SHARED_BANK_SHA256,
        )
        physical = self.physical_vector()
        with self.assertRaises(ReleaseLockError):
            shared_bank_configuration_sha256_for_plan(physical, self.plan_v2)
        with self.assertRaises(CalibrationPlanCodecError):
            shared_bank_configuration_sha256_v2(initial, self.plan_v1)
        with mock.patch(
            "validation.calibration_v2.release_lock."
            "shared_bank_configuration_sha256_for_plan",
            side_effect=AssertionError("V1 helper was called"),
        ):
            self.assertEqual(
                shared_bank_configuration_sha256_v2(physical, self.parsed),
                EXPECTED_ENDPOINTS[0]["bank"],
            )

    @unittest.skipUnless(
        shutil.which("xcrun") is not None,
        "native Swift compiler is unavailable",
    )
    def test_native_swift_canonical_encoder_matches_endpoint_bytes(self) -> None:
        frames = []
        swift_documents = []
        for ordinal in EXPECTED_ENDPOINTS:
            physical = self.physical_vector(ordinal)
            frames.append(
                serialized_shared_bank_configuration_v2(physical, self.parsed)
            )
            pairs = []
            for name in SHARED_BANK_SERIALIZATION_ORDER_V2:
                value = physical[name]
                if type(value) is int:
                    encoded_value = f".integer({value})"
                elif type(value) is str:
                    encoded_value = f".string({json.dumps(value)})"
                else:
                    raise AssertionError(f"unsupported golden type: {type(value)}")
                pairs.append(
                    ".array([.string("
                    + json.dumps(name)
                    + f"), {encoded_value}])"
                )
            swift_documents.append(
                ".object(["
                + '"domain_separator": .string('
                + json.dumps(SHARED_BANK_DOMAIN_SEPARATOR_V2)
                + '), "ordered_fields": .array(['
                + ",".join(pairs)
                + "])])"
            )

        stub = """
import Foundation
enum ASHLUTLockedConfigurationJSONErrorV2: Error {
    case invalidSyntax
    case duplicateKey
    case invalidValue
}
"""
        probe = """
import Foundation
@main enum SharedBankCanonicalJSONProbe {
    static func main() {
        let documents: [ASHLUTStrictJSONValueV2] = [
            %s
        ]
        for document in documents {
            print(ASHLUTCanonicalJSONV2.encode(document).base64EncodedString())
        }
    }
}
""" % ",\n".join(swift_documents)

        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            stub_path = directory / "ErrorStub.swift"
            probe_path = directory / "Probe.swift"
            executable = directory / "probe"
            stub_path.write_text(stub, encoding="utf-8")
            probe_path.write_text(probe, encoding="utf-8")
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    str(stub_path),
                    str(SWIFT_CANONICAL_JSON_PATH),
                    str(probe_path),
                    "-o",
                    str(executable),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                [str(executable)],
                check=True,
                capture_output=True,
                text=True,
            )
        native_frames = [
            base64.b64decode(line, validate=True)
            for line in result.stdout.splitlines()
        ]
        self.assertEqual(native_frames, frames)


if __name__ == "__main__":
    unittest.main()
