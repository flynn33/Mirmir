from __future__ import annotations

import binascii
import copy
import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path

from validation.calibration_v2.reference import lut_oracle as oracle_v1
from validation.calibration_v2.reference import lut_oracle_v2 as oracle
from validation.calibration_v2.tests.format_1_2_parity_fixture import (
    locked_compiler_input_v2_document,
    rehash,
)


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
PARITY_INPUT_PATH = (
    CALIBRATION_ROOT
    / "tests/fixtures/locked-compiler-input-format-1.2-parity-v2.json"
)
PARITY_MANIFEST_PATH = (
    CALIBRATION_ROOT
    / "tests/fixtures/format-1.2-python-parity-manifest-v2.json"
)
PARITY_INPUT_FILE_SHA256 = (
    "1c6f1076c994a257c25e8583cd12a3ce853b7cfb659734ba3e74020b53c13610"
)
PARITY_MANIFEST_FILE_SHA256 = (
    "39c01cd6fce21c052cd39181c689c161b0501936b980dcb5f3a441db337a13c7"
)
EXPECTED_COMPILER_INPUT_SHA256 = (
    "d2afbb3027bb9812aad2687f0f7dc1a6171f932a908c4053ee19cedf23548319"
)
EXPECTED_ROUTE_FACTS = {
    "direct_2x": {
        "file_size": 200064,
        "whole_file_sha256": (
            "992d9b409c32d862b73d29ce7e6819b88ddbadbb7e59dd4cb3da9d8299f30b39"
        ),
        "payload_sha256": (
            "e389e0644685fee07ebf5b297ea4817d9c86ff708d5ba3c47b847be1d87b5109"
        ),
        "payload_crc32": 4189404205,
        "header_crc32": 2918521225,
        "parameter_count": 49,
        "header_extension_hex": "0701040100010000000000000000000000000000",
    },
    "direct_3_over_2": {
        "file_size": 445312,
        "whole_file_sha256": (
            "dc1a506d2f5914c9fc5982be2cdb6a36279d65988f1833133672f3b3e36398ab"
        ),
        "payload_sha256": (
            "5064d2d0a13cd82c0f807c88a3c6465784a9e7d0066f5e69c82517ccabf0b612"
        ),
        "payload_crc32": 3832117350,
        "header_crc32": 3597619339,
        "parameter_count": 41,
        "header_extension_hex": "1000050001010000000000000000000000000000",
    },
}


def repair_header_crc(mutated: bytearray) -> None:
    mutated[288:292] = b"\x00" * 4
    struct.pack_into(
        "<I",
        mutated,
        288,
        binascii.crc32(bytes(mutated[: oracle.HEADER_SIZE])) & 0xFFFFFFFF,
    )


def repair_global_integrity(mutated: bytearray) -> None:
    payload_offset, payload_bytes = struct.unpack_from("<II", mutated, 56)
    payload = bytes(mutated[payload_offset : payload_offset + payload_bytes])
    mutated[256:288] = hashlib.sha256(payload).digest()
    struct.pack_into(
        "<I",
        mutated,
        292,
        binascii.crc32(payload) & 0xFFFFFFFF,
    )
    repair_header_crc(mutated)


def repair_entry_crc(mutated: bytearray, logical_index: int) -> None:
    route_id = struct.unpack_from("<H", mutated, 16)[0]
    parameter_offset = struct.unpack_from("<I", mutated, 40)[0]
    entry_offset = struct.unpack_from("<I", mutated, 44)[0]
    record_offset = entry_offset + logical_index * oracle.ENTRY_STRIDE
    parameter_index = struct.unpack_from("<I", mutated, record_offset + 16)[0]
    parameter_record = bytes(
        mutated[
            parameter_offset + parameter_index * oracle.PARAMETER_STRIDE :
            parameter_offset + (parameter_index + 1) * oracle.PARAMETER_STRIDE
        ]
    )
    provenance = (
        struct.pack("<HI", route_id, logical_index)
        + bytes(mutated[record_offset : record_offset + 20])
        + parameter_record
    )
    struct.pack_into(
        "<I",
        mutated,
        record_offset + 20,
        binascii.crc32(provenance) & 0xFFFFFFFF,
    )


def independent_policy_descriptor(
    raw_state: int,
    route: oracle.Route,
    phase_index: int,
    policy_id: int,
) -> int:
    state = oracle_v1.spatial_semantic_state(raw_state)
    bit = lambda coordinate: oracle_v1.state_coordinate(state, coordinate)
    orientation = bit(1) ^ bit(2)
    edge = bit(3)
    coherent = bit(4)
    texture = bit(5)
    risk = bit(6)
    chroma_aligned = bit(8)
    horizontal = phase_index % route.scale_numerator
    vertical = phase_index // route.scale_numerator
    phase = int(2 * horizontal >= route.scale_numerator) ^ int(
        2 * vertical >= route.scale_numerator
    )
    kernel_rules = (
        texture ^ (edge & orientation) ^ phase,
        texture ^ (edge & orientation),
        texture | (edge & orientation),
    )
    support_rules = (
        edge & coherent,
        edge & coherent & (1 - risk),
        edge & coherent & (1 - texture),
        edge & coherent & (1 - risk) & (1 - texture),
    )
    detail_rules = (
        edge & texture & (1 - risk),
        texture & (1 - risk),
    )
    limiter_rules = (
        chroma_aligned & (1 - risk),
        chroma_aligned,
    )
    kernel = kernel_rules[policy_id // 16]
    support = support_rules[(policy_id % 16) // 4]
    detail = detail_rules[(policy_id % 4) // 2]
    limiter = limiter_rules[policy_id % 2]
    return kernel | (support << 1) | (detail << 2) | (limiter << 3)


class LockedInputV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = locked_compiler_input_v2_document()

    def test_canonical_self_hash_and_native_v2_shape_are_exact(self) -> None:
        self.assertEqual(
            self.document["hash_bindings"]["compiler_inputs_sha256"],
            EXPECTED_COMPILER_INPUT_SHA256,
        )
        self.assertEqual(
            oracle.canonical_compiler_input_sha256_v2(self.document),
            EXPECTED_COMPILER_INPUT_SHA256,
        )
        configuration = oracle.parse_locked_compiler_input_v2(self.document)
        self.assertIsInstance(configuration, oracle.LockedCompilerInputV2)
        self.assertNotIn("anisotropy_strength_q12", self.document["operator_parameters"])
        with self.assertRaises(oracle.OracleError):
            oracle_v1.parse_locked_compiler_input(self.document)

    def test_shared_parity_input_is_canonical_and_hash_locked(self) -> None:
        serialized = json.dumps(
            self.document,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        self.assertEqual(PARITY_INPUT_PATH.read_bytes(), serialized)
        self.assertEqual(
            hashlib.sha256(PARITY_INPUT_PATH.read_bytes()).hexdigest(),
            PARITY_INPUT_FILE_SHA256,
        )
        loaded = oracle.load_locked_compiler_input_v2(PARITY_INPUT_PATH)
        self.assertEqual(loaded.canonical_document, self.document)

    def test_parser_accepts_exact_domains_and_rejects_projections(self) -> None:
        for route_name in oracle.ROUTES:
            for policy_id in oracle.ADMISSIBLE_POLICY_IDS:
                document = copy.deepcopy(self.document)
                document["routes"][route_name]["route_spatial_policy_id"] = policy_id
                rehash(document)
                oracle.parse_locked_compiler_input_v2(document)

        mutations = []
        for policy_id in (-1, 8, 15, 24, 47, 48, True):
            document = copy.deepcopy(self.document)
            document["routes"]["direct_2x"]["route_spatial_policy_id"] = policy_id
            rehash(document)
            mutations.append(document)
        for ordinal in (-1, 6, True):
            document = copy.deepcopy(self.document)
            document["routes"]["direct_2x"]["luma_anisotropy_mode_ordinal"] = ordinal
            rehash(document)
            mutations.append(document)
        global_anisotropy = copy.deepcopy(self.document)
        global_anisotropy["operator_parameters"]["anisotropy_strength_q12"] = 3072
        rehash(global_anisotropy)
        mutations.append(global_anisotropy)
        per_plane_policy = copy.deepcopy(self.document)
        per_plane_policy["routes"]["direct_2x"]["luma_spatial_policy_id"] = 0
        rehash(per_plane_policy)
        mutations.append(per_plane_policy)
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(oracle.OracleError):
                oracle.parse_locked_compiler_input_v2(mutation)

    def test_all_isotropic_vector_fails_but_rotated_zero_remains_distinct(self) -> None:
        document = copy.deepcopy(self.document)
        for selection in document["routes"].values():
            selection["luma_anisotropy_mode_ordinal"] = 0
            selection["chroma_anisotropy_mode_ordinal"] = 0
        rehash(document)
        with self.assertRaisesRegex(oracle.OracleError, "all-isotropic"):
            oracle.parse_locked_compiler_input_v2(document)

        document["routes"]["direct_3_over_2"][
            "chroma_anisotropy_mode_ordinal"
        ] = 1
        rehash(document)
        configuration = oracle.parse_locked_compiler_input_v2(document)
        mode_zero = oracle.ANISOTROPY_MODES_BY_ORDINAL[0]
        rotated_zero = oracle.ANISOTROPY_MODES_BY_ORDINAL[1]
        self.assertEqual(mode_zero.anisotropy_strength_q12, 0)
        self.assertEqual(rotated_zero.anisotropy_strength_q12, 0)
        self.assertFalse(mode_zero.use_anisotropy)
        self.assertTrue(rotated_zero.use_anisotropy)
        self.assertEqual(
            configuration.routes["direct_3_over_2"].chroma_anisotropy_mode_ordinal,
            1,
        )

    def test_stale_hash_duplicate_key_and_noninteger_fail_closed(self) -> None:
        stale = copy.deepcopy(self.document)
        stale["boundary_mode"] = "clamp"
        with self.assertRaisesRegex(oracle.OracleError, "self-hash mismatch"):
            oracle.parse_locked_compiler_input_v2(stale)

        noninteger = copy.deepcopy(self.document)
        noninteger["semantic_steps"]["support_radius_step_q8_8"] = 64.0
        rehash(noninteger)
        with self.assertRaisesRegex(oracle.OracleError, "must be an integer"):
            oracle.parse_locked_compiler_input_v2(noninteger)

        serialized = json.dumps(self.document)
        duplicate = serialized[:-1] + ',"top_two":2}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text(duplicate, encoding="utf-8")
            with self.assertRaisesRegex(oracle.OracleError, "duplicate JSON key"):
                oracle.load_locked_compiler_input_v2(path)


class CompilerSemanticsV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = locked_compiler_input_v2_document()
        cls.configuration = oracle.parse_locked_compiler_input_v2(cls.document)
        cls.route = oracle.ROUTES["direct_2x"]
        cls.compilation = oracle.compile_route_v2(cls.route, cls.configuration)

    def test_every_policy_state_and_phase_matches_independent_program_evaluation(
        self,
    ) -> None:
        for route in oracle.ROUTES.values():
            for policy_id in oracle.ADMISSIBLE_POLICY_IDS:
                for phase_index in range(route.phase_count):
                    for raw_state in oracle.VALID_STATES:
                        actual = oracle.spatial_policy_descriptor(
                            raw_state,
                            route,
                            phase_index,
                            policy_id,
                        )
                        expected = independent_policy_descriptor(
                            raw_state,
                            route,
                            phase_index,
                            policy_id,
                        )
                        self.assertEqual(actual, expected)
                        if policy_id == 0:
                            self.assertEqual(
                                actual,
                                oracle_v1.base_descriptor(
                                    raw_state,
                                    route,
                                    phase_index,
                                ),
                            )

    def test_plane_major_bijection_and_context_aliases_are_exhaustive(self) -> None:
        self.assertEqual(len(self.compilation.entries), self.route.entry_count)
        observed = set()
        for entry in self.compilation.entries:
            index = oracle.logical_index_v2(
                self.route,
                entry.plane.plane_id,
                entry.phase_index,
                entry.context_id,
                entry.valid_state_ordinal,
            )
            self.assertEqual(entry.logical_index, index)
            observed.add(index)
        self.assertEqual(observed, set(range(self.route.entry_count)))

        by_cell = {
            (
                entry.plane.plane_id,
                entry.phase_index,
                entry.context_id,
                entry.valid_state_ordinal,
            ): entry
            for entry in self.compilation.entries
        }
        for plane in oracle.PLANES:
            for phase_index in range(self.route.phase_count):
                for state_ordinal in range(oracle.VALID_STATE_COUNT):
                    spatial = by_cell[(plane.plane_id, phase_index, 0, state_ordinal)]
                    for context_id in (1, 2, 3):
                        alias = by_cell[
                            (plane.plane_id, phase_index, context_id, state_ordinal)
                        ]
                        self.assertEqual(alias.primary, spatial.primary)
                        self.assertEqual(alias.secondary, spatial.secondary)
                        self.assertEqual(alias.primary_slot, spatial.primary_slot)
                        self.assertEqual(alias.secondary_slot, spatial.secondary_slot)

    def test_source_exactness_is_plane_local_for_every_state_and_context(self) -> None:
        luma_exact = 0
        chroma_exact = 0
        for entry in self.compilation.entries:
            expected = entry.plane.name == "luma" and entry.phase_index == 0
            self.assertEqual(entry.source_aligned_exact, expected)
            if entry.source_aligned_exact and entry.plane.name == "luma":
                luma_exact += 1
            if entry.source_aligned_exact and entry.plane.name == "chroma":
                chroma_exact += 1
        self.assertEqual(luma_exact, 4 * 256)
        self.assertEqual(chroma_exact, 0)

        document = copy.deepcopy(self.document)
        document["routes"]["direct_2x"].update(
            luma_coordinate_policy="half_pixel_center",
            chroma_coordinate_policy="source_aligned_rational",
        )
        rehash(document)
        configuration = oracle.parse_locked_compiler_input_v2(document)
        state_ordinal = oracle_v1.RAW_TO_VALID_ORDINAL[83]
        luma = oracle.compile_cell_v2(
            self.route,
            configuration,
            oracle.PLANES[0],
            0,
            0,
            state_ordinal,
        )
        chroma = oracle.compile_cell_v2(
            self.route,
            configuration,
            oracle.PLANES[1],
            0,
            0,
            state_ordinal,
        )
        self.assertFalse(luma.source_aligned_exact)
        self.assertTrue(chroma.source_aligned_exact)

    def test_other_plane_mode_and_coordinate_mutations_do_not_change_current_plane(
        self,
    ) -> None:
        luma_mutation = copy.deepcopy(self.document)
        luma_mutation["routes"]["direct_2x"].update(
            luma_anisotropy_mode_ordinal=5,
            luma_coordinate_policy="half_pixel_center",
        )
        rehash(luma_mutation)
        luma_changed = oracle.compile_route_v2(
            self.route,
            oracle.parse_locked_compiler_input_v2(luma_mutation),
        )
        boundary = self.route.plane_entry_count
        self.assertNotEqual(
            self.compilation.entries[:boundary],
            luma_changed.entries[:boundary],
        )
        self.assertEqual(
            self.compilation.entries[boundary:],
            luma_changed.entries[boundary:],
        )

        chroma_mutation = copy.deepcopy(self.document)
        chroma_mutation["routes"]["direct_2x"].update(
            chroma_anisotropy_mode_ordinal=5,
            chroma_coordinate_policy="source_aligned_rational",
        )
        rehash(chroma_mutation)
        chroma_changed = oracle.compile_route_v2(
            self.route,
            oracle.parse_locked_compiler_input_v2(chroma_mutation),
        )
        self.assertEqual(
            self.compilation.entries[:boundary],
            chroma_changed.entries[:boundary],
        )
        self.assertNotEqual(
            self.compilation.entries[boundary:],
            chroma_changed.entries[boundary:],
        )

    def test_plane_modes_control_slot_strength_and_zero_modes_do_not_collapse(self) -> None:
        luma = self.compilation.entries[0]
        chroma = self.compilation.entries[self.route.plane_entry_count]
        self.assertEqual(luma.primary_slot.anisotropy_strength_q12, 0)
        self.assertEqual(chroma.primary_slot.anisotropy_strength_q12, 3072)
        self.assertTrue(
            oracle.ANISOTROPY_MODES_BY_ORDINAL[1].use_anisotropy
        )
        self.assertFalse(
            oracle.ANISOTROPY_MODES_BY_ORDINAL[0].use_anisotropy
        )


class BinaryFormatV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = locked_compiler_input_v2_document()
        cls.configuration = oracle.parse_locked_compiler_input_v2(cls.document)
        cls.data = {
            name: oracle.compile_route_bytes_v2(route, cls.configuration)
            for name, route in oracle.ROUTES.items()
        }

    def assert_validation_error(
        self,
        data: bytes | bytearray,
        expected_code: str,
        route_name: str = "direct_2x",
        *,
        expected_configuration: bool = False,
    ) -> None:
        with self.assertRaises(oracle.OracleError) as caught:
            oracle.validate_lut_v2(
                bytes(data),
                expected_configuration=(
                    self.configuration if expected_configuration else None
                ),
                expected_route=route_name,
            )
        self.assertEqual(caught.exception.code, expected_code)

    def test_both_route_bytes_match_locked_cross_language_facts(self) -> None:
        for name, route in oracle.ROUTES.items():
            data = self.data[name]
            facts = EXPECTED_ROUTE_FACTS[name]
            validated = oracle.validate_lut_v2(
                data,
                expected_configuration=self.configuration,
                expected_route=route,
            )
            self.assertEqual(len(data), facts["file_size"])
            self.assertEqual(validated.whole_file_sha256, facts["whole_file_sha256"])
            self.assertEqual(validated.payload_sha256, facts["payload_sha256"])
            self.assertEqual(validated.payload_crc32, facts["payload_crc32"])
            self.assertEqual(validated.header_crc32, facts["header_crc32"])
            self.assertEqual(validated.parameter_count, facts["parameter_count"])
            self.assertEqual(data[300:320].hex(), facts["header_extension_hex"])
            self.assertEqual(struct.unpack_from("<HH", data, 8), (1, 2))
            self.assertEqual(struct.unpack_from("<H", data, 30)[0], 2)
            self.assertEqual(struct.unpack_from("<I", data, 32)[0], route.entry_count)
            self.assertEqual(
                route.entry_count,
                2 * route.phase_count * 4 * 256,
            )

    def test_compact_parity_manifest_matches_complete_bytes_and_entry_facts(self) -> None:
        manifest_bytes = PARITY_MANIFEST_PATH.read_bytes()
        self.assertEqual(
            hashlib.sha256(manifest_bytes).hexdigest(),
            PARITY_MANIFEST_FILE_SHA256,
        )
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["schema_version"], "2.0.0")
        self.assertEqual(
            manifest["compiler_input"],
            {
                "compiler_inputs_sha256": EXPECTED_COMPILER_INPUT_SHA256,
                "file_sha256": PARITY_INPUT_FILE_SHA256,
                "path": (
                    "validation/calibration_v2/tests/fixtures/"
                    "locked-compiler-input-format-1.2-parity-v2.json"
                ),
                "size_bytes": len(PARITY_INPUT_PATH.read_bytes()),
            },
        )
        self.assertEqual(
            [row["route_name"] for row in manifest["routes"]],
            list(oracle.ROUTES),
        )
        for row in manifest["routes"]:
            name = row["route_name"]
            route = oracle.ROUTES[name]
            data = self.data[name]
            entry_offset = struct.unpack_from("<I", data, 44)[0]
            self.assertEqual(row["entry_count"], route.entry_count)
            self.assertEqual(row["file_size_bytes"], len(data))
            self.assertEqual(
                row["whole_file_sha256"],
                hashlib.sha256(data).hexdigest(),
            )
            self.assertEqual(row["header_extension"]["plane_count"], 2)
            self.assertEqual(
                row["header_extension"]["route_spatial_policy_id"],
                data[300],
            )
            self.assertEqual(
                row["header_extension"]["reserved_tail_hex"],
                data[306:320].hex(),
            )
            for fact in row["representative_entries"]:
                logical_index = fact["logical_index"]
                record = data[
                    entry_offset + logical_index * oracle.ENTRY_STRIDE :
                    entry_offset + (logical_index + 1) * oracle.ENTRY_STRIDE
                ]
                self.assertEqual(record.hex(), fact["entry_record_hex"])
                self.assertEqual(
                    logical_index,
                    oracle.logical_index_v2(
                        route,
                        fact["plane_id"],
                        fact["phase_index"],
                        fact["context_id"],
                        fact["valid_state_ordinal"],
                    ),
                )
                flags = struct.unpack_from("<H", record, 14)[0]
                self.assertEqual(
                    bool(flags & (1 << 1)),
                    fact["entry_source_aligned_exact"],
                )

    def test_serialization_is_repeatedly_deterministic(self) -> None:
        for name, route in oracle.ROUTES.items():
            self.assertEqual(
                oracle.compile_route_bytes_v2(route, self.configuration),
                self.data[name],
            )

    def test_parameter_layout_and_plane_specific_strengths_are_exhaustive(self) -> None:
        for name, route in oracle.ROUTES.items():
            data = self.data[name]
            selection = self.configuration.routes[name]
            parameter_count = struct.unpack_from("<I", data, 36)[0]
            parameter_offset, entry_offset = struct.unpack_from("<II", data, 40)
            prefixes = [
                data[
                    parameter_offset + index * oracle.PARAMETER_STRIDE :
                    parameter_offset + index * oracle.PARAMETER_STRIDE
                    + oracle.PARAMETER_PREFIX_SIZE
                ]
                for index in range(parameter_count)
            ]
            self.assertEqual(prefixes, sorted(set(prefixes)))
            for prefix in prefixes:
                self.assertEqual(
                    prefix[50],
                    1 if selection.luma_coordinate_policy == "source_aligned_rational" else 0,
                )
                self.assertEqual(prefix[53], 0)
                self.assertEqual(
                    prefix[54],
                    1 if selection.chroma_coordinate_policy == "source_aligned_rational" else 0,
                )
                self.assertEqual(prefix[55:60], b"\x00" * 5)

            for logical_index in range(route.entry_count):
                plane_id = logical_index // route.plane_entry_count
                mode = selection.mode_for_plane(oracle.PLANES_BY_ID[plane_id])
                record_offset = entry_offset + logical_index * oracle.ENTRY_STRIDE
                parameter_index = struct.unpack_from("<I", data, record_offset + 16)[0]
                parameter_record_offset = (
                    parameter_offset + parameter_index * oracle.PARAMETER_STRIDE
                )
                primary_strength = struct.unpack_from(
                    "<H", data, parameter_record_offset
                )[0]
                self.assertEqual(primary_strength, mode.anisotropy_strength_q12)
                flags = struct.unpack_from("<H", data, record_offset + 14)[0]
                if flags & 1:
                    secondary_strength = struct.unpack_from(
                        "<H", data, parameter_record_offset + 24
                    )[0]
                    self.assertEqual(
                        secondary_strength,
                        mode.anisotropy_strength_q12,
                    )

    def test_version_dispatch_precedes_format_extension_decode(self) -> None:
        mutated = bytearray(self.data["direct_2x"])
        struct.pack_into("<HH", mutated, 8, 1, 1)
        mutated[300] = 255
        self.assert_validation_error(mutated, "unsupported_version")

    def test_header_extension_corruptions_fail_closed(self) -> None:
        cases = (
            (30, 0, "dimension_mismatch"),
            (300, 8, "invalid_locked_input"),
            (301, 6, "parameter_out_of_range"),
            (302, 6, "parameter_out_of_range"),
            (303, 2, "parameter_out_of_range"),
            (304, 2, "parameter_out_of_range"),
            (305, 0, "invalid_entry_flags"),
            (306, 1, "reserved_nonzero"),
            (319, 1, "reserved_nonzero"),
        )
        for offset, value, expected_code in cases:
            mutated = bytearray(self.data["direct_2x"])
            mutated[offset] = value
            repair_header_crc(mutated)
            with self.subTest(offset=offset):
                self.assert_validation_error(mutated, expected_code)

    def test_header_coordinate_policy_and_mode_bind_payload_semantics(self) -> None:
        coordinate = bytearray(self.data["direct_2x"])
        coordinate[303] = 0
        repair_header_crc(coordinate)
        self.assert_validation_error(coordinate, "input_hash_mismatch")

        strength_mode = bytearray(self.data["direct_2x"])
        strength_mode[301] = 2
        repair_header_crc(strength_mode)
        self.assert_validation_error(strength_mode, "input_hash_mismatch")

        rotated_zero = bytearray(self.data["direct_3_over_2"])
        rotated_zero[301] = 1
        repair_header_crc(rotated_zero)
        validated = oracle.validate_lut_v2(
            bytes(rotated_zero),
            expected_route="direct_3_over_2",
        )
        self.assertEqual(validated.luma_anisotropy_mode_ordinal, 1)
        self.assertTrue(validated.luma_anisotropy_mode.use_anisotropy)
        self.assertNotEqual(
            hashlib.sha256(rotated_zero).hexdigest(),
            hashlib.sha256(self.data["direct_3_over_2"]).hexdigest(),
        )
        self.assert_validation_error(
            rotated_zero,
            "input_hash_mismatch",
            route_name="direct_3_over_2",
            expected_configuration=True,
        )

    def test_policy_header_cannot_reinterpret_compiled_entries(self) -> None:
        mutated = bytearray(self.data["direct_2x"])
        mutated[300] = 6
        repair_header_crc(mutated)
        self.assert_validation_error(
            mutated,
            "input_hash_mismatch",
            expected_configuration=True,
        )

    def test_global_parameter_entry_and_plane_major_crc_corruption(self) -> None:
        header = bytearray(self.data["direct_2x"])
        header[64] ^= 1
        self.assert_validation_error(header, "header_crc_mismatch")

        payload = bytearray(self.data["direct_2x"])
        payload[oracle.HEADER_SIZE] ^= 1
        self.assert_validation_error(payload, "payload_crc_mismatch")

        parameter = bytearray(self.data["direct_2x"])
        parameter[oracle.HEADER_SIZE] ^= 1
        repair_global_integrity(parameter)
        self.assert_validation_error(parameter, "parameter_crc_mismatch")

        entry = bytearray(self.data["direct_2x"])
        entry_offset = struct.unpack_from("<I", entry, 44)[0]
        entry[entry_offset + 6] ^= 1
        repair_global_integrity(entry)
        self.assert_validation_error(entry, "entry_crc_mismatch")

        plane_major = bytearray(self.data["direct_2x"])
        chroma_index = oracle.ROUTES["direct_2x"].plane_entry_count
        chroma_offset = entry_offset + chroma_index * oracle.ENTRY_STRIDE
        plane_major[chroma_offset + 20] ^= 1
        repair_global_integrity(plane_major)
        self.assert_validation_error(plane_major, "entry_crc_mismatch")

    def test_affine_message_corruption_fails_after_all_integrity_repairs(self) -> None:
        mutated = bytearray(self.data["direct_2x"])
        entry_offset = struct.unpack_from("<I", mutated, 44)[0]
        mutated[entry_offset + 6] = 1
        repair_entry_crc(mutated, 0)
        repair_global_integrity(mutated)
        self.assert_validation_error(mutated, "decoded_message_mismatch")

    def test_truncation_file_size_and_cross_version_rejection(self) -> None:
        self.assert_validation_error(b"", "truncated_file")
        self.assert_validation_error(self.data["direct_2x"][:-1], "file_size_mismatch")
        v1_document = json.loads(
            (
                Path(__file__).resolve().parents[1]
                / "fixtures/locked-compiler-input-shared-v1.json"
            ).read_text(encoding="utf-8")
        )
        v1_configuration = oracle_v1.parse_locked_compiler_input(v1_document)
        v1_bytes = oracle_v1.compile_route_bytes(
            oracle_v1.ROUTES["direct_2x"],
            v1_configuration,
        )
        self.assert_validation_error(v1_bytes, "unsupported_version")


if __name__ == "__main__":
    unittest.main()
