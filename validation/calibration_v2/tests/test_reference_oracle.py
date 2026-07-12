import binascii
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import validation.calibration_v2.reference.lut_oracle as oracle


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]
CLI_PATH = CALIBRATION_ROOT / "tools" / "compile_reference_luts.py"
SHARED_FIXTURE_PATH = (
    CALIBRATION_ROOT / "fixtures" / "locked-compiler-input-shared-v1.json"
)
SHARED_FIXTURE_FILE_SHA256 = (
    "75293d2c18998df82131305fa33e4805f555246632137c3f7ae393a7d700ee7f"
)


def canonical_self_hash(document):
    canonical = json.loads(json.dumps(document))
    del canonical["hash_bindings"]["compiler_inputs_sha256"]
    encoded = json.dumps(
        canonical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def locked_input_fixture():
    denominator = 16
    penalty_table = [
        ((65535 * denominator) + ((denominator + index) // 2))
        // (denominator + index)
        for index in range(256)
    ]
    document = {
        "schema_version": "1.0.0",
        "status": "locked",
        "configuration_id": "p06-reference-fixture-001",
        "hash_bindings": {
            "mapping_sha256": "1" * 64,
            "operator_bank_sha256": "2" * 64,
            "metric_policy_sha256": "3" * 64,
            "compiler_inputs_sha256": "4" * 64,
            "calibration_plan_sha256": "5" * 64,
            "corpus_lock_bundle_sha256": "6" * 64,
        },
        "canonicalization": {
            "encoding": "UTF-8",
            "object_key_order": "ascending Unicode scalar value",
            "array_order": "preserved",
            "whitespace": "none",
            "string_escaping": (
                "JSON quotation, reverse-solidus, and control escapes; "
                "non-ASCII encoded directly as UTF-8"
            ),
            "number_domain": "integers only",
            "duplicate_keys": "reject",
            "trailing_newline_in_hash_input": False,
            "hash_algorithm": "SHA-256",
            "hash_scope": (
                "complete canonical document with only "
                "/hash_bindings/compiler_inputs_sha256 omitted"
            ),
        },
        "boundary_mode": "mirror_reflect101",
        "operator_parameters": {
            "anisotropy_strength_q12": 3072,
            "minimum_anisotropic_magnitude_unorm15": 1638,
            "minimum_anisotropic_coherence_unorm15": 4915,
            "detail_gain_q12": 768,
            "relaxed_limiter_alpha_q12": 256,
            "risk_detail_suppression_unorm15": 21299,
            "low_pass_radius_q8_8": 512,
            "weight_epsilon_f32_bits": 730643660,
        },
        "semantic_steps": {
            "orientation_sector_step": 1,
            "support_radius_step_q8_8": 64,
            "detail_gain_step_q12": 128,
            "regularization_step_q12": 64,
        },
        "compiler_policy": {
            "penalty_decay_denominator": denominator,
            "penalty_to_weight_unorm16": penalty_table,
            "penalty_orientation_step": 4,
            "penalty_support_step": 8,
            "penalty_detail_step": 8,
            "penalty_regularization_step": 8,
            "penalty_unsupported_support_expansion": 32,
            "penalty_coherent_support_reduction": 16,
            "penalty_unsupported_detail_increase": 32,
            "penalty_supported_detail_reduction": 16,
            "penalty_relaxation_under_risk": 64,
            "penalty_phase_kernel_mismatch": 8,
            "confidence_threshold_unorm16": 16384,
        },
        "routes": {
            "direct_2x": {
                "coordinate_policy": "source_aligned_rational",
                "analysis_grid_source_step": 1,
            },
            "direct_3_over_2": {
                "coordinate_policy": "half_pixel_center",
                "analysis_grid_source_step": 2,
            },
        },
        "temporal": {
            "enabled": False,
            "context_count": 4,
            "context_aliases_to_spatial": [1, 2, 3],
            "semantic_state": "clear payload coordinate 7 and recompute coordinate 9 parity",
            "affine_anchor": "original parity-valid source state",
        },
        "source_aligned": {
            "exact": True,
            "predicate": (
                "source_aligned_rational with horizontal phase zero and vertical phase zero"
            ),
            "primary_message": 0,
            "primary_descriptor": 0,
            "secondary": "inactive",
            "denoising": False,
        },
        "top_two": 2,
    }
    document["hash_bindings"]["compiler_inputs_sha256"] = canonical_self_hash(document)
    return document


def state_from_payload(payload_bits):
    raw = 0
    for coordinate, bit in enumerate(payload_bits, start=1):
        raw |= bit << (9 - coordinate)
    parity = sum(payload_bits) & 1
    return raw | parity


def repair_global_integrity(mutated):
    payload = bytes(mutated[oracle.HEADER_SIZE :])
    mutated[256:288] = hashlib.sha256(payload).digest()
    struct.pack_into("<I", mutated, 292, binascii.crc32(payload) & 0xFFFFFFFF)
    mutated[288:292] = b"\x00" * 4
    header_crc = binascii.crc32(bytes(mutated[: oracle.HEADER_SIZE])) & 0xFFFFFFFF
    struct.pack_into("<I", mutated, 288, header_crc)


class CanonicalReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(SHARED_FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.configuration = oracle.parse_locked_compiler_input(cls.document)

    def test_shared_fixture_is_the_independently_frozen_contract_input(self):
        self.assertEqual(self.document, locked_input_fixture())
        self.assertEqual(
            hashlib.sha256(SHARED_FIXTURE_PATH.read_bytes()).hexdigest(),
            SHARED_FIXTURE_FILE_SHA256,
        )
        self.assertEqual(
            self.document["hash_bindings"]["compiler_inputs_sha256"],
            "63fd1b11387d72e9209e6d833233512b5ddc34315865edfdd30696001de41f9f",
        )

    def test_locked_input_self_hash_and_mutation_are_checked(self):
        self.assertEqual(
            self.document["hash_bindings"]["compiler_inputs_sha256"],
            canonical_self_hash(self.document),
        )
        mutated = json.loads(json.dumps(self.document))
        mutated["routes"]["direct_3_over_2"]["analysis_grid_source_step"] = 4
        with self.assertRaisesRegex(oracle.OracleError, "compiler input self-hash mismatch"):
            oracle.parse_locked_compiler_input(mutated)

    def test_state_code_and_strict_decoder_are_canonical(self):
        self.assertEqual(len(oracle.VALID_STATES), 256)
        self.assertEqual(oracle.VALID_STATES, tuple(sorted(oracle.VALID_STATES)))
        self.assertEqual(oracle.encode_message(0b1000), 0b111100000)
        self.assertEqual(oracle.encode_message(0b0100), 0b110011000)
        self.assertEqual(oracle.encode_message(0b0010), 0b101010100)
        self.assertEqual(oracle.encode_message(0b0001), 0b100110001)
        anchor = oracle.VALID_STATES[73]
        message = 0b1011
        affine = anchor ^ oracle.encode_message(message)
        self.assertEqual(oracle.strict_affine_decode(affine, anchor), ("exact", message))
        self.assertEqual(
            oracle.strict_affine_decode(affine ^ (1 << 8), anchor),
            ("corrected", message),
        )
        self.assertEqual(
            oracle.strict_affine_decode(affine ^ (1 << 8) ^ (1 << 7), anchor),
            ("rejected", None),
        )

    def test_canonical_paths_have_exact_order_messages_and_mass(self):
        paths = oracle.CANONICAL_PATHS
        self.assertEqual(len(paths), 81)
        self.assertEqual([path.ordinal for path in paths], list(range(81)))
        self.assertEqual(paths[0].actions, (0, 0, 0, 0))
        self.assertEqual(paths[0].branch_mass_numerator, 16)
        self.assertEqual(paths[-1].actions, (2, 2, 2, 2))
        self.assertEqual(sum(path.branch_mass_numerator for path in paths), 256)
        anchor = oracle.VALID_STATES[17]
        for path in paths:
            affine = anchor ^ oracle.encode_message(path.message)
            self.assertEqual(
                oracle.strict_affine_decode(affine, anchor),
                ("exact", path.message),
            )

    def test_resolved_axes_and_hard_constraints_match_frozen_semantics(self):
        raw = 83
        route = oracle.ROUTES["direct_2x"]
        base = oracle.base_descriptor(raw, route, 0)
        self.assertEqual(base, 0b1101)
        zero = oracle.CANONICAL_PATHS[0]
        orientation_plus = oracle.CANONICAL_PATHS[27]
        support_minus = oracle.CANONICAL_PATHS[18]
        resolved_zero = oracle.resolve_path_parameters(base, zero, self.configuration)
        resolved_orientation = oracle.resolve_path_parameters(
            base,
            orientation_plus,
            self.configuration,
        )
        resolved_support = oracle.resolve_path_parameters(
            base,
            support_minus,
            self.configuration,
        )
        self.assertEqual(resolved_zero, (0b1101, 768, 256, 768))
        self.assertEqual(resolved_orientation, resolved_zero)
        self.assertEqual(resolved_support, (0b1101, 768, 256, 704))
        semantic = oracle.spatial_semantic_state(raw)
        self.assertTrue(oracle.hard_compatible(0b1101, 768, 256, semantic))
        risk_state = state_from_payload([0, 0, 1, 0, 1, 1, 0, 1])
        self.assertFalse(oracle.hard_compatible(0b1101, 768, 256, risk_state))
        contradicted_chroma = state_from_payload([0, 0, 1, 0, 1, 0, 0, 0])
        self.assertFalse(
            oracle.hard_compatible(0b1001, 0, 256, contradicted_chroma)
        )
        edge_only = state_from_payload([0, 0, 1, 0, 0, 0, 0, 0])
        self.assertTrue(oracle.hard_compatible(0b0010, 0, 0, edge_only))
        empty = state_from_payload([0] * 8)
        self.assertFalse(oracle.hard_compatible(0b0010, 0, 0, empty))

    def test_cell_vector_ranking_temporal_alias_and_source_override(self):
        route = oracle.ROUTES["direct_2x"]
        state = 83
        ordinal = oracle.RAW_TO_VALID_ORDINAL[state]
        entry = oracle.compile_cell(route, self.configuration, 1, 0, ordinal)
        self.assertEqual(
            (
                entry.primary.message,
                entry.primary.descriptor,
                entry.primary.message_weight_q16_16,
                entry.primary.representative_penalty,
                entry.primary.representative_path_ordinal,
                entry.secondary.message,
                entry.secondary.descriptor,
                entry.primary_weight_unorm16,
                entry.secondary_weight_unorm16,
                entry.margin_unorm16,
            ),
            (0, 12, 4249, 8, 0, 8, 12, 39531, 26004, 13527),
        )
        temporal_variant = state ^ (1 << (9 - 7)) ^ 1
        self.assertEqual(oracle.spatial_semantic_state(state), oracle.spatial_semantic_state(temporal_variant))
        temporal_entry = oracle.compile_cell(
            route,
            self.configuration,
            1,
            0,
            oracle.RAW_TO_VALID_ORDINAL[temporal_variant],
        )
        self.assertEqual(entry.primary.message, temporal_entry.primary.message)
        self.assertEqual(entry.primary.descriptor, temporal_entry.primary.descriptor)
        self.assertEqual(entry.primary_weight_unorm16, temporal_entry.primary_weight_unorm16)
        self.assertEqual(entry.primary_slot, temporal_entry.primary_slot)
        self.assertNotEqual(entry.primary.affine_state, temporal_entry.primary.affine_state)
        for context_id in (1, 2, 3):
            alias = oracle.compile_cell(route, self.configuration, 1, context_id, ordinal)
            self.assertEqual(entry.primary, alias.primary)
            self.assertEqual(entry.secondary, alias.secondary)
            self.assertEqual(entry.primary_slot, alias.primary_slot)
        exact = oracle.compile_cell(route, self.configuration, 0, 0, ordinal)
        self.assertTrue(exact.source_aligned_exact)
        self.assertEqual(
            (
                exact.primary.message,
                exact.primary.descriptor,
                exact.primary.affine_state,
                exact.primary.message_weight_q16_16,
                exact.margin_unorm16,
                exact.primary_slot.support_radius_q8_8,
            ),
            (0, 0, state, 65536, 65535, 512),
        )
        half_pixel = oracle.compile_cell(
            oracle.ROUTES["direct_3_over_2"],
            self.configuration,
            0,
            0,
            ordinal,
        )
        self.assertFalse(half_pixel.source_aligned_exact)


class BinaryReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(SHARED_FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.configuration = oracle.parse_locked_compiler_input(cls.document)
        cls.route = oracle.ROUTES["direct_2x"]
        cls.data = oracle.compile_route_bytes(cls.route, cls.configuration)

    def assert_validation_error(self, data, expected_code):
        with self.assertRaises(oracle.OracleError) as caught:
            oracle.validate_lut(bytes(data), expected_route=self.route)
        self.assertEqual(caught.exception.code, expected_code)

    def test_route_serialization_is_deterministic_sorted_and_self_validating(self):
        repeated = oracle.compile_route_bytes(self.route, self.configuration)
        self.assertEqual(self.data, repeated)
        validated = oracle.validate_lut(
            self.data,
            expected_configuration=self.configuration,
            expected_route=self.route,
        )
        self.assertEqual(validated.entry_count, 4096)
        self.assertGreater(validated.parameter_count, 0)
        parameter_count = struct.unpack_from("<I", self.data, 36)[0]
        prefixes = [
            self.data[320 + (index * 64) : 380 + (index * 64)]
            for index in range(parameter_count)
        ]
        self.assertEqual(prefixes, sorted(set(prefixes)))
        self.assertEqual(hashlib.sha256(self.data).hexdigest(), validated.whole_file_sha256)

    def test_state_conditioning_evidence_excludes_anchor_only_changes(self):
        for route in oracle.ROUTES.values():
            payload = oracle.compile_route_bytes(route, self.configuration)
            evidence = oracle.state_conditioning_evidence(
                payload,
                expected_configuration=self.configuration,
                expected_route=route,
            )
            self.assertTrue(evidence["oracle_validation_passed"])
            self.assertTrue(evidence["state_conditioned"])
            self.assertEqual(
                evidence["whole_file_sha256"],
                hashlib.sha256(payload).hexdigest(),
            )
            self.assertEqual(evidence["entry_count"], route.entry_count)
            self.assertEqual(evidence["maximum_operator_evaluations"], 2)
            self.assertEqual(
                [row["coordinate"] for row in evidence["coordinate_sensitivity"]],
                list(oracle.ACTIVE_SPATIAL_STATE_COORDINATES),
            )
            for row in evidence["coordinate_sensitivity"]:
                self.assertGreater(row["parity_valid_pair_count"], 0)
                self.assertGreater(row["differing_dispatch_pair_count"], 0)
                self.assertIsNotNone(row["first_witness"])

    def test_cli_compiles_and_validates_both_routes_from_locked_json(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output_directory = root / "outputs"
            process = subprocess.run(
                [
                    sys.executable,
                    str(CLI_PATH),
                    str(SHARED_FIXTURE_PATH),
                    str(output_directory),
                ],
                cwd=REPOSITORY_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            summary = json.loads(process.stdout)
            self.assertEqual(summary["status"], "compiled_and_validated")
            self.assertEqual(
                [item["route"] for item in summary["routes"]],
                ["direct_2x", "direct_3_over_2"],
            )
            self.assertEqual((output_directory / "direct2x.ashlut").read_bytes(), self.data)
            for route in oracle.ROUTES.values():
                output = (output_directory / route.filename).read_bytes()
                validated = oracle.validate_lut(
                    output,
                    expected_configuration=self.configuration,
                    expected_route=route,
                )
                self.assertEqual(validated.entry_count, route.entry_count)

    def test_global_header_and_payload_mutations_are_rejected(self):
        header_mutation = bytearray(self.data)
        header_mutation[64] ^= 1
        self.assert_validation_error(header_mutation, "header_crc_mismatch")

        payload_mutation = bytearray(self.data)
        payload_mutation[oracle.HEADER_SIZE] ^= 1
        self.assert_validation_error(payload_mutation, "payload_crc_mismatch")

    def test_parameter_and_entry_crc_mutations_are_rejected_after_global_repair(self):
        parameter_mutation = bytearray(self.data)
        parameter_mutation[oracle.HEADER_SIZE] ^= 1
        repair_global_integrity(parameter_mutation)
        self.assert_validation_error(parameter_mutation, "parameter_crc_mismatch")

        entry_mutation = bytearray(self.data)
        entry_offset = struct.unpack_from("<I", entry_mutation, 44)[0]
        entry_mutation[entry_offset + 6] ^= 1
        repair_global_integrity(entry_mutation)
        self.assert_validation_error(entry_mutation, "entry_crc_mismatch")

    def test_affine_message_mutation_is_rejected_after_all_crc_repairs(self):
        mutated = bytearray(self.data)
        route_id = struct.unpack_from("<H", mutated, 16)[0]
        parameter_offset = struct.unpack_from("<I", mutated, 40)[0]
        entry_offset = struct.unpack_from("<I", mutated, 44)[0]
        parameter_index = struct.unpack_from("<I", mutated, entry_offset + 16)[0]
        mutated[entry_offset + 6] = 1
        parameter_record = bytes(
            mutated[
                parameter_offset + (parameter_index * 64) :
                parameter_offset + ((parameter_index + 1) * 64)
            ]
        )
        provenance = (
            struct.pack("<HI", route_id, 0)
            + bytes(mutated[entry_offset : entry_offset + 20])
            + parameter_record
        )
        struct.pack_into(
            "<I",
            mutated,
            entry_offset + 20,
            binascii.crc32(provenance) & 0xFFFFFFFF,
        )
        repair_global_integrity(mutated)
        self.assert_validation_error(mutated, "decoded_message_mismatch")


if __name__ == "__main__":
    unittest.main()
