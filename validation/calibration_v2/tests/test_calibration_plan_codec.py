from __future__ import annotations

from collections.abc import Mapping
import copy
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import unittest
from unittest import mock

from validation.calibration_v2.calibration_plan_codec import (
    CalibrationPlanCodecError,
    candidate_vector_sha256_v2,
    materialize_candidate_vector_v2,
    parse_calibration_plan_v2,
    serialized_candidate_vector_v2,
    validate_candidate_constraints_v2,
    validate_materialized_candidate_identity_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
    STRUCTURAL_FACTOR_ORDER,
)
from validation.calibration_v2.release_lock import (
    ReleaseLockError,
    candidate_vector_sha256_for_plan,
    shared_bank_configuration_sha256_for_plan,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
PLAN_V1_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v1.json"
PLAN_V2_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
SCHEMA_V1_PATH = CALIBRATION_ROOT / "schemas/calibration-plan-v1.schema.json"

EXPECTED_PLAN_V1_SHA256 = (
    "128244e8fb1450b74e8c81141af40c5188bac8fc151bf272a348c9faa6f1549e"
)
EXPECTED_SCHEMA_V1_SHA256 = (
    "051a804b32121a99241270c0199e5f3a90034f717ab05e67019b3d8384a7854a"
)
EXPECTED_PLAN_V2_FILE_SHA256 = (
    "1977c85b9a3b7001294a04d33e7654ae20ffb4266ac0c8d2dc76880bdec99fef"
)
EXPECTED_PLAN_V2_SELF_SHA256 = (
    "e6070a7cdd8f3b53231635027055669c8319d311af1790d672723d6e7e048d0f"
)
EXPECTED_V1_INITIAL_CANDIDATE_SHA256 = (
    "8e64bbedbabc74d7f512736092c0e1a60980da65880a43efe3ea65452bde20dd"
)
EXPECTED_V1_INITIAL_SHARED_BANK_SHA256 = (
    "4f348931d7a97fe54400bd126a3aec90a377abcc86c98c25ea92807898e3c66e"
)
EXPECTED_V2_ORDINAL_HASHES = {
    0: "5ef8b175db2a957509037f5a8c48f1a1238de6e08cf57d7511f44552e1dfb1dc",
    255: "177893edce952b45ec4a0c64782bc6bb3832e8dfcc21e518020f5e2cb25f65d2",
}


class TaggedInt(int):
    pass


class TaggedStr(str):
    pass


def load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode_plan(document: dict[str, object]) -> bytes:
    payload = copy.deepcopy(document)
    payload.pop("plan_sha256", None)
    document = copy.deepcopy(document)
    document["plan_sha256"] = canonical_sha256(payload)
    return (
        json.dumps(
            document,
            ensure_ascii=False,
            allow_nan=False,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")


class FlippingMapping(Mapping[str, object]):
    def __init__(
        self,
        source: Mapping[str, object],
        *,
        target: str,
        replacement: object,
        valid_reads: int = 1,
    ) -> None:
        self.source = dict(source)
        self.target = target
        self.replacement = replacement
        self.valid_reads = valid_reads
        self.target_reads = 0

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, key: str) -> object:
        if key == self.target:
            self.target_reads += 1
            if self.target_reads > self.valid_reads:
                return self.replacement
        return self.source[key]


class FlippingPayloadMapping(Mapping[str, bytes]):
    def __init__(
        self,
        source: Mapping[str, bytes],
        replacements: Mapping[str, bytes],
    ) -> None:
        self.source = dict(source)
        self.replacements = dict(replacements)
        self.read_counts = {key: 0 for key in replacements}

    def __iter__(self):
        return iter(self.source)

    def __len__(self) -> int:
        return len(self.source)

    def __getitem__(self, key: str) -> bytes:
        if key in self.replacements:
            self.read_counts[key] += 1
            if self.read_counts[key] > 1:
                return self.replacements[key]
        return self.source[key]


class CalibrationPlanCodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan_v1 = load_object(PLAN_V1_PATH)
        cls.plan_v2 = load_object(PLAN_V2_PATH)
        cls.plan_v2_payload = PLAN_V2_PATH.read_bytes()
        cls.bound_payloads = {
            binding["id"]: (ROOT / binding["path"]).read_bytes()
            for binding in cls.plan_v2["input_bindings"]
        }
        cls.parsed = parse_calibration_plan_v2(
            cls.plan_v2_payload,
            bound_payloads=cls.bound_payloads,
        )

    def logical_vector(self, ordinal: object = 0) -> dict[str, object]:
        return {
            ATOMIC_STRUCTURAL_COORDINATE: ordinal,
            **dict(self.parsed.scalar_initial_values),
        }

    def test_frozen_plan_parses_and_derives_exact_shapes(self) -> None:
        self.assertEqual(
            self.parsed.plan_file_sha256,
            EXPECTED_PLAN_V2_FILE_SHA256,
        )
        self.assertEqual(
            self.parsed.plan_self_sha256,
            EXPECTED_PLAN_V2_SELF_SHA256,
        )
        self.assertEqual(len(self.parsed.logical_parameter_order), 38)
        self.assertEqual(len(self.parsed.physical_candidate_order), 48)
        self.assertEqual(len(self.parsed.scalar_parameter_order), 37)
        self.assertEqual(
            self.parsed.logical_parameter_order,
            (ATOMIC_STRUCTURAL_COORDINATE, *self.parsed.scalar_parameter_order),
        )
        self.assertEqual(
            self.parsed.physical_candidate_order[:11],
            (ATOMIC_STRUCTURAL_COORDINATE, *STRUCTURAL_FACTOR_ORDER),
        )

    def test_parser_rejects_syntax_schema_self_hash_binding_and_derivation_drift(
        self,
    ) -> None:
        duplicate_key = self.plan_v2_payload.replace(
            b'{\n  "schema_version": "2.0.0",',
            b'{\n  "schema_version": "2.0.0",\n  "schema_version": "2.0.0",',
            1,
        )
        nonfinite = self.plan_v2_payload.replace(
            b'"selected_winner": null',
            b'"selected_winner": NaN',
            1,
        )
        wrong_self_hash = self.plan_v2_payload.replace(
            EXPECTED_PLAN_V2_SELF_SHA256.encode("ascii"),
            ("b" * 64).encode("ascii"),
            1,
        )
        unknown_version = copy.deepcopy(self.plan_v2)
        unknown_version["schema_version"] = "3.0.0"
        wrong_inherited_hash = copy.deepcopy(self.plan_v2)
        wrong_inherited_hash["inheritance"][
            "inherited_scalar_domains_sha256"
        ] = "a" * 64
        unsafe_retention = copy.deepcopy(self.plan_v2)
        unsafe_retention["search"]["infeasible_retention_rule"] = (
            "constraint failures and evaluation failures are eligible winners"
        )
        changed_prerequisites = copy.deepcopy(self.plan_v2)
        changed_prerequisites["execution_boundary"]["required_before_execution"] = [
            "skip versioned implementation evidence"
        ]
        float_integer = copy.deepcopy(self.plan_v2)
        float_integer["search"]["maximum_sweeps"] = 8.0
        compact = (
            json.dumps(
                self.plan_v2,
                ensure_ascii=False,
                allow_nan=False,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")

        payload_mutations = (
            duplicate_key,
            nonfinite,
            wrong_self_hash,
            encode_plan(unknown_version),
            encode_plan(wrong_inherited_hash),
            encode_plan(unsafe_retention),
            encode_plan(changed_prerequisites),
            encode_plan(float_integer),
            compact,
            self.plan_v2_payload + b"\n",
        )
        for index, payload in enumerate(payload_mutations):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                parse_calibration_plan_v2(
                    payload,
                    bound_payloads=self.bound_payloads,
                )

    def test_parser_binds_the_executed_reference_source(self) -> None:
        with mock.patch(
            "validation.calibration_v2.calibration_plan_codec._reference_source_payload",
            return_value=b"drifted reference source",
        ), self.assertRaisesRegex(
            CalibrationPlanCodecError,
            "reference source differs",
        ):
            parse_calibration_plan_v2(
                self.plan_v2_payload,
                bound_payloads=self.bound_payloads,
            )

    def test_bound_payload_mapping_is_snapshotted_once_before_authentication(
        self,
    ) -> None:
        stripped_base = (
            json.dumps(
                {
                    "search": self.plan_v1["search"],
                    "ranges": self.plan_v1["ranges"],
                },
                ensure_ascii=False,
                allow_nan=False,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
        permissive_schema = (
            json.dumps(
                {
                    "$schema": "https://json-schema.org/draft/2020-12/schema",
                    "type": "object",
                },
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
        bindings = FlippingPayloadMapping(
            self.bound_payloads,
            {
                "calibration_plan_v1": stripped_base,
                "calibration_plan_v1_schema": permissive_schema,
            },
        )
        parsed = parse_calibration_plan_v2(
            self.plan_v2_payload,
            bound_payloads=bindings,
        )
        self.assertEqual(parsed.plan_file_sha256, EXPECTED_PLAN_V2_FILE_SHA256)
        self.assertEqual(bindings.read_counts["calibration_plan_v1"], 1)
        self.assertEqual(bindings.read_counts["calibration_plan_v1_schema"], 1)

        changed_binding = dict(self.bound_payloads)
        changed_binding["calibration_plan_v1"] += b"\n"
        missing_binding = dict(self.bound_payloads)
        missing_binding.pop("calibration_plan_v1")
        extra_binding = dict(self.bound_payloads)
        extra_binding["undeclared"] = b"{}\n"
        for index, bindings in enumerate(
            (changed_binding, missing_binding, extra_binding)
        ):
            with self.subTest(binding_index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                parse_calibration_plan_v2(
                    self.plan_v2_payload,
                    bound_payloads=bindings,
                )

    def test_ordinal_zero_and_255_match_frozen_physical_hashes(self) -> None:
        for ordinal, expected_hash in EXPECTED_V2_ORDINAL_HASHES.items():
            physical = materialize_candidate_vector_v2(
                self.logical_vector(ordinal),
                self.parsed,
            )
            validate_materialized_candidate_identity_v2(physical, self.parsed)
            validate_candidate_constraints_v2(physical, self.parsed)
            serialized = serialized_candidate_vector_v2(physical, self.parsed)
            decoded = json.loads(serialized)
            with self.subTest(ordinal=ordinal):
                self.assertEqual(tuple(physical), self.parsed.physical_candidate_order)
                self.assertIsInstance(decoded, list)
                self.assertEqual(len(decoded), 48)
                self.assertEqual(
                    decoded,
                    [
                        physical[name]
                        for name in self.parsed.physical_candidate_order
                    ],
                )
                self.assertEqual(
                    candidate_vector_sha256_v2(physical, self.parsed),
                    expected_hash,
                )

    def test_all_structural_ordinals_have_unique_vectors_and_hashes(self) -> None:
        vectors = set()
        hashes = set()
        for ordinal in range(256):
            physical = materialize_candidate_vector_v2(
                self.logical_vector(ordinal),
                self.parsed,
            )
            validate_materialized_candidate_identity_v2(physical, self.parsed)
            vectors.add(
                tuple(
                    physical[name]
                    for name in self.parsed.physical_candidate_order
                )
            )
            hashes.add(candidate_vector_sha256_v2(physical, self.parsed))
        self.assertEqual(len(vectors), 256)
        self.assertEqual(len(hashes), 256)

    def test_logical_vector_rejects_wrong_shape_type_ordinal_and_domain(self) -> None:
        missing = self.logical_vector()
        missing.pop("analysis_epsilon_q0_30")
        extra = self.logical_vector()
        extra["extra"] = 0
        out_of_domain = self.logical_vector()
        out_of_domain["analysis_epsilon_q0_30"] = -1
        boolean_scalar = self.logical_vector()
        boolean_scalar["analysis_epsilon_q0_30"] = True
        tagged_key = {
            TaggedStr(name) if name == "analysis_epsilon_q0_30" else name: value
            for name, value in self.logical_vector().items()
        }
        mutations = (
            missing,
            extra,
            self.logical_vector(True),
            self.logical_vector(-1),
            self.logical_vector(256),
            out_of_domain,
            boolean_scalar,
            tagged_key,
        )
        for index, logical in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                materialize_candidate_vector_v2(logical, self.parsed)

    def test_physical_identity_rejects_shape_domain_and_factor_mismatch(self) -> None:
        physical = dict(
            materialize_candidate_vector_v2(self.logical_vector(), self.parsed)
        )
        missing = dict(physical)
        missing.pop("direct_2x_route_spatial_policy_id")
        extra = dict(physical)
        extra["extra"] = 0
        wrong_domain = dict(physical)
        wrong_domain["analysis_epsilon_q0_30"] = -1
        wrong_factor = dict(physical)
        wrong_factor["direct_2x_route_spatial_policy_id"] = 1
        wrong_ordinal = dict(physical)
        wrong_ordinal[ATOMIC_STRUCTURAL_COORDINATE] = 1
        tagged_key = {
            TaggedStr(name)
            if name == "direct_2x_route_spatial_policy_id"
            else name: value
            for name, value in physical.items()
        }
        for index, mutation in enumerate(
            (
                missing,
                extra,
                wrong_domain,
                wrong_factor,
                wrong_ordinal,
                tagged_key,
            )
        ):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                validate_materialized_candidate_identity_v2(
                    mutation,
                    self.parsed,
                )

    def test_constraint_failure_retains_canonical_physical_identity(self) -> None:
        valid = materialize_candidate_vector_v2(self.logical_vector(), self.parsed)
        invalid_logical = self.logical_vector()
        invalid_logical["edge_present_low_unorm15"] = 9830
        invalid_logical["edge_present_high_unorm15"] = 9830
        invalid = materialize_candidate_vector_v2(invalid_logical, self.parsed)
        validate_materialized_candidate_identity_v2(invalid, self.parsed)
        invalid_serialized = serialized_candidate_vector_v2(invalid, self.parsed)
        invalid_hash = candidate_vector_sha256_v2(invalid, self.parsed)
        self.assertEqual(invalid_hash, hashlib.sha256(invalid_serialized).hexdigest())
        self.assertNotEqual(
            invalid_hash,
            candidate_vector_sha256_v2(valid, self.parsed),
        )
        with self.assertRaisesRegex(
            CalibrationPlanCodecError,
            "threshold pair constraint failed",
        ):
            validate_candidate_constraints_v2(invalid, self.parsed)

    def test_stateful_mappings_are_snapshotted_once_before_use(self) -> None:
        logical = self.logical_vector()
        logical_flipper = FlippingMapping(
            logical,
            target="analysis_epsilon_q0_30",
            replacement=-1,
        )
        physical = materialize_candidate_vector_v2(logical_flipper, self.parsed)
        self.assertEqual(physical["analysis_epsilon_q0_30"], 1)
        validate_materialized_candidate_identity_v2(physical, self.parsed)

        expected_serialized = serialized_candidate_vector_v2(physical, self.parsed)
        physical_flipper = FlippingMapping(
            physical,
            target="analysis_epsilon_q0_30",
            replacement=1.5,
        )
        self.assertEqual(
            serialized_candidate_vector_v2(physical_flipper, self.parsed),
            expected_serialized,
        )
        hash_flipper = FlippingMapping(
            physical,
            target="analysis_epsilon_q0_30",
            replacement=1.5,
        )
        self.assertEqual(
            candidate_vector_sha256_v2(hash_flipper, self.parsed),
            candidate_vector_sha256_v2(physical, self.parsed),
        )

    def test_forged_parsed_models_cannot_change_executable_fields(self) -> None:
        rows = list(self.parsed.structural_vectors)
        first_row = list(rows[0])
        first_row[0] = 1
        rows[0] = tuple(first_row)
        forged_catalog = replace(
            self.parsed,
            structural_vectors=tuple(rows),
        )
        domains = list(self.parsed.scalar_domains)
        first_name, first_values = domains[0]
        domains[0] = (first_name, (*first_values, -1))
        forged_domains = replace(
            self.parsed,
            scalar_domains=tuple(domains),
        )
        forged_order = replace(
            self.parsed,
            logical_parameter_order=tuple(
                reversed(self.parsed.logical_parameter_order)
            ),
        )
        tagged_domains = list(self.parsed.scalar_domains)
        tagged_name, tagged_values = tagged_domains[0]
        tagged_domains[0] = (
            tagged_name,
            (TaggedInt(tagged_values[0]), *tagged_values[1:]),
        )
        tagged_initials = list(self.parsed.scalar_initial_values)
        tagged_initials[0] = (
            tagged_name,
            TaggedInt(tagged_initials[0][1]),
        )
        forged_tagged_scalar = replace(
            self.parsed,
            scalar_domains=tuple(tagged_domains),
            scalar_initial_values=tuple(tagged_initials),
        )
        tagged_rows = list(self.parsed.structural_vectors)
        tagged_first_row = list(tagged_rows[0])
        tagged_first_row[0] = TaggedInt(tagged_first_row[0])
        tagged_rows[0] = tuple(tagged_first_row)
        forged_tagged_catalog = replace(
            self.parsed,
            structural_vectors=tuple(tagged_rows),
        )
        for index, forged in enumerate(
            (
                forged_catalog,
                forged_domains,
                forged_order,
                forged_tagged_scalar,
                forged_tagged_catalog,
            )
        ):
            with self.subTest(index=index), self.assertRaises(
                CalibrationPlanCodecError
            ):
                materialize_candidate_vector_v2(
                    self.logical_vector(),
                    forged,
                )

    def test_v1_candidate_and_shared_bank_bytes_remain_frozen(self) -> None:
        self.assertEqual(file_sha256(PLAN_V1_PATH), EXPECTED_PLAN_V1_SHA256)
        self.assertEqual(file_sha256(SCHEMA_V1_PATH), EXPECTED_SCHEMA_V1_SHA256)
        initial = self.plan_v1["search"]["initial_vector_values"]
        order = self.plan_v1["search"]["parameter_order"]
        serialized = canonical_json_bytes([initial[name] for name in order])
        self.assertEqual(len(serialized), 252)
        self.assertEqual(
            hashlib.sha256(serialized).hexdigest(),
            EXPECTED_V1_INITIAL_CANDIDATE_SHA256,
        )
        self.assertEqual(
            candidate_vector_sha256_for_plan(initial, self.plan_v1),
            EXPECTED_V1_INITIAL_CANDIDATE_SHA256,
        )
        self.assertEqual(
            shared_bank_configuration_sha256_for_plan(initial, self.plan_v1),
            EXPECTED_V1_INITIAL_SHARED_BANK_SHA256,
        )

    def test_v1_release_hash_path_remains_closed_to_v2(self) -> None:
        physical = materialize_candidate_vector_v2(
            self.logical_vector(),
            self.parsed,
        )
        with self.assertRaises(ReleaseLockError):
            candidate_vector_sha256_for_plan(physical, self.plan_v2)
        with self.assertRaises(CalibrationPlanCodecError):
            parse_calibration_plan_v2(
                PLAN_V1_PATH.read_bytes(),
                bound_payloads=self.bound_payloads,
            )


if __name__ == "__main__":
    unittest.main()
