import binascii
import copy
import hashlib
import itertools
import json
import math
import unittest
from fractions import Fraction
from pathlib import Path

from jsonschema import Draft202012Validator

from validation.calibration_v2.native_adapter.factory import (
    _P00_COMPATIBILITY_BOUNDARY,
)
from validation.calibration_v2.production_providers import (
    _CONTAINER_DECODED_LEGAL_RANGE_NORMALIZATION,
)
from validation.calibration_v2.production_evaluator import (
    FULL_ASH_MAXIMUM_CANDIDATE_EVALUATION_BUDGET,
)
from validation.calibration_v2.runner import parameter_domains


CALIBRATION_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = CALIBRATION_ROOT.parents[1]


def load(relative_path: str) -> dict:
    return json.loads((CALIBRATION_ROOT / relative_path).read_text(encoding="utf-8"))


def errors(document: dict, schema: dict):
    return sorted(Draft202012Validator(schema).iter_errors(document), key=lambda error: list(error.path))


def field_map(fields: list[dict]) -> dict[str, dict]:
    return {field["name"]: field for field in fields}


def dictionary_keys(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from dictionary_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from dictionary_keys(child)


def canonical_compiler_input_bytes(document: dict) -> bytes:
    canonical = copy.deepcopy(document)
    del canonical["hash_bindings"]["compiler_inputs_sha256"]
    return json.dumps(
        canonical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def canonical_compiler_input_sha256(document: dict) -> str:
    return hashlib.sha256(canonical_compiler_input_bytes(document)).hexdigest()


class CalibrationContractSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = load("contracts/calibration-plan-v1.json")
        cls.compiler = load("contracts/compiler-contract-v1.json")
        cls.lut = load("contracts/lut-binary-contract-v1.json")
        cls.tolerances = load("contracts/metric-performance-tolerances-v1.json")
        cls.parity_preregistration = load("contracts/native-parity-manifest-v1.preregistered.json")
        cls.shared_compiler_fixture = load(
            "fixtures/locked-compiler-input-shared-v1.json"
        )
        cls.schemas = {
            path.name: json.loads(path.read_text(encoding="utf-8"))
            for path in sorted((CALIBRATION_ROOT / "schemas").glob("*.json"))
        }

    def test_all_schemas_are_valid_draft_2020_12(self):
        for name, schema in self.schemas.items():
            with self.subTest(schema=name):
                Draft202012Validator.check_schema(schema)

    def test_preregistered_documents_validate(self):
        pairs = [
            (self.plan, "calibration-plan-v1.schema.json"),
            (self.compiler, "compiler-contract-v1.schema.json"),
            (self.lut, "lut-binary-contract-v1.schema.json"),
            (self.tolerances, "metric-performance-tolerances-v1.schema.json"),
            (self.parity_preregistration, "native-parity-preregistration-v1.schema.json"),
            (self.shared_compiler_fixture, "locked-compiler-input-v1.schema.json"),
        ]
        for document, schema_name in pairs:
            with self.subTest(schema=schema_name):
                self.assertEqual(errors(document, self.schemas[schema_name]), [])

    def test_shared_compiler_fixture_self_hash_and_plane_policy_independence(self):
        fixture = self.shared_compiler_fixture
        self.assertEqual(
            fixture["hash_bindings"]["compiler_inputs_sha256"],
            canonical_compiler_input_sha256(fixture),
        )
        for route in fixture["routes"].values():
            self.assertNotEqual(
                route["luma_coordinate_policy"],
                route["chroma_coordinate_policy"],
            )

    def test_route_contracts_require_independent_luma_and_chroma_policies(self):
        definitions = [
            ("candidate-evaluation-v1.schema.json", "routeBinding"),
            ("route-analysis-grid-selection-v1.schema.json", "route"),
            ("locked-compiler-input-v1.schema.json", "routeSelection"),
            ("operator-bank-v1.schema.json", "routeCoordinatePolicies"),
            ("candidate-lut-runtime-manifest-v1.schema.json", "routeBase"),
            ("lut-manifest-v2.schema.json", "routeBase"),
        ]
        for schema_name, definition_name in definitions:
            with self.subTest(schema=schema_name, definition=definition_name):
                definition = self.schemas[schema_name]["$defs"][definition_name]
                self.assertIn("luma_coordinate_policy", definition["required"])
                self.assertIn("chroma_coordinate_policy", definition["required"])
                self.assertNotIn("coordinate_policy", definition["properties"])

        execution = self.schemas[
            "control-aggregate-cache-native-benchmark-v1.schema.json"
        ]["$defs"]["executionContract"]
        self.assertIn("luma_coordinate_policy_by_route", execution["required"])
        self.assertIn("chroma_coordinate_policy_by_route", execution["required"])
        self.assertNotIn("coordinate_policy_by_route", execution["properties"])

    def test_video_mapping_uses_the_alias_specific_threshold_domain(self):
        definitions = self.schemas["video-mapping-v1.schema.json"]["$defs"]
        generic = definitions["spatialBand"]["properties"]
        alias = definitions["aliasRiskBand"]["properties"]
        self.assertEqual(generic["low"]["enum"], [3277, 4915, 6553, 8192, 9830])
        self.assertEqual(generic["high"]["enum"], [9830, 11468, 13107, 14745, 16384])
        self.assertEqual(alias["low"]["enum"], [0, 3277, 4915, 6553, 8192, 9830])
        self.assertEqual(
            alias["high"]["enum"],
            [3277, 9830, 11468, 13107, 14745, 16384],
        )

    def test_runtime_normalization_constants_exactly_match_preregistration(self):
        fixed = self.plan["fixed_choices"]
        self.assertEqual(
            _P00_COMPATIBILITY_BOUNDARY,
            fixed["p00_compatibility_legal_range_normalization"],
        )
        self.assertEqual(
            _CONTAINER_DECODED_LEGAL_RANGE_NORMALIZATION,
            fixed["container_decoded_legal_range_normalization"],
        )

    def test_preregistration_cannot_claim_execution(self):
        self.assertEqual(self.plan["status"], "preregistered_not_executed")
        self.assertTrue(all(value is False for value in self.plan["execution_state"].values()))
        self.assertEqual(self.tolerances["status"], "preregistered_not_measured")
        self.assertEqual(self.parity_preregistration["status"], "preregistered_not_executed")
        self.assertFalse(self.parity_preregistration["execution_results_present"])
        self.assertFalse(self.plan["data_separation"]["holdout_may_be_opened_in_p06"])

    def test_input_bindings_include_future_validation_lock(self):
        bindings = {binding["id"]: binding for binding in self.plan["input_bindings"]}
        validation = bindings["validation_sample_lock"]
        self.assertEqual(validation["path"], "validation/quality/locks/validation-sample-lock.json")
        self.assertIn("required_to_exist_before_search", validation["binding"])

    def test_input_bindings_preregister_holdout_sampling_without_pixels(self):
        bindings = {binding["id"]: binding for binding in self.plan["input_bindings"]}
        sampling = bindings["holdout_sampling_plan"]
        self.assertEqual(
            sampling["path"],
            "validation/calibration_v2/contracts/holdout-sampling-plan-v1.json",
        )
        self.assertIn("without_opening_media_payloads", sampling["binding"])
        self.assertEqual(
            self.plan["corpus_lock_bundle_contract"]["ordered_fields"][2:5],
            [
                "holdout_sampling_plan_file_sha256",
                "holdout_sampling_plan_manifest_sha256",
                "holdout_sampling_target_pixel_hashes_known_before_p07",
            ],
        )

    def test_container_decoded_nominal_range_policy_is_fixed_before_search(self):
        policy = self.plan["fixed_choices"][
            "container_decoded_legal_range_normalization"
        ]
        self.assertEqual(policy["method"], "nominal_video_range_clip_v1")
        self.assertEqual(policy["nominal_y_code_range"], [16, 235])
        self.assertEqual(policy["nominal_chroma_code_range"], [16, 240])
        self.assertFalse(policy["engine_raw_affected"])


class LUTBinaryLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = load("contracts/lut-binary-contract-v1.json")

    def assert_contiguous(self, fields: list[dict], start: int, end: int):
        cursor = start
        for field in fields:
            self.assertEqual(field["offset"], cursor, field["name"])
            cursor += field["size"]
        self.assertEqual(cursor, end)

    def test_header_offsets_are_contiguous_and_complete(self):
        header = self.contract["header"]
        self.assertEqual(header["size_bytes"], 320)
        self.assert_contiguous(header["fields"], 0, 320)
        fields = field_map(header["fields"])
        self.assertEqual(self.contract["format_version"], {"major": 1, "minor": 1})
        self.assertEqual(fields["format_major"]["value"], 1)
        self.assertEqual(fields["format_minor"]["value"], 1)
        self.assertEqual(fields["endianness_tag"]["value"], 0x4C45)
        self.assertEqual(fields["entry_stride"]["value"], 24)
        self.assertEqual(fields["parameter_stride"]["value"], 64)
        self.assertEqual(fields["header_crc32"]["offset"], 288)
        self.assertEqual(fields["payload_crc32"]["offset"], 292)

    def test_entry_offsets_are_contiguous_and_complete(self):
        entry = self.contract["entry_record"]
        self.assertEqual(entry["size_bytes"], 24)
        self.assert_contiguous(entry["fields"], 0, 24)
        fields = field_map(entry["fields"])
        self.assertEqual(fields["parameter_index"]["offset"], 16)
        self.assertEqual(fields["provenance_crc32"]["offset"], 20)

    def test_parameter_pair_offsets_are_complete(self):
        parameter = self.contract["parameter_record"]
        self.assertEqual(parameter["size_bytes"], 64)
        self.assertEqual(parameter["candidate_slot_size_bytes"], 24)
        self.assertEqual(parameter["primary_slot_offset"], 0)
        self.assertEqual(parameter["secondary_slot_offset"], 24)
        self.assert_contiguous(parameter["candidate_slot_fields"], 0, 24)
        self.assert_contiguous(parameter["tail_fields"], 48, 64)
        tail = field_map(parameter["tail_fields"])
        self.assertEqual(
            [(field["name"], field["offset"], field["size"]) for field in parameter["tail_fields"]],
            [
                ("confidence_threshold_unorm16", 48, 2),
                ("luma_coordinate_policy", 50, 1),
                ("boundary_mode", 51, 1),
                ("source_aligned_policy", 52, 1),
                ("temporal_mode", 53, 1),
                ("chroma_coordinate_policy", 54, 1),
                ("reserved_tail", 55, 5),
                ("record_crc32", 60, 4),
            ],
        )
        self.assertEqual(
            tail["luma_coordinate_policy"]["values"],
            tail["chroma_coordinate_policy"]["values"],
        )
        self.assertEqual(parameter["record_crc_scope"], "bytes 0...59")

    def test_every_flag_bit_is_declared_or_reserved(self):
        groups = [
            (self.contract["header"]["flags"], self.contract["header"]["reserved_flag_bits"]),
            (self.contract["entry_record"]["flags"], self.contract["entry_record"]["reserved_flag_bits"]),
            (
                self.contract["parameter_record"]["candidate_flags"],
                self.contract["parameter_record"]["reserved_candidate_flag_bits"],
            ),
        ]
        for flags, reserved in groups:
            with self.subTest(flags=[flag["name"] for flag in flags]):
                declared = {flag["bit"] for flag in flags}
                self.assertEqual(declared | set(reserved), set(range(16)))
                self.assertEqual(declared & set(reserved), set())

    def test_route_entry_cardinalities_follow_index_contract(self):
        for route in self.contract["routes"]:
            with self.subTest(route=route["name"]):
                self.assertEqual(route["phase_count"], route["scale_numerator"] ** 2)
                self.assertEqual(route["entry_count"], route["phase_count"] * 4 * 256)

    def test_derived_section_sizes_are_unambiguous(self):
        for route in self.contract["routes"]:
            for parameter_count in (1, 17, 65535):
                parameter_bytes = parameter_count * 64
                entry_offset = 320 + parameter_bytes
                entry_bytes = route["entry_count"] * 24
                payload_bytes = parameter_bytes + entry_bytes
                file_size = 320 + payload_bytes
                self.assertEqual(entry_offset + entry_bytes, file_size)
                self.assertLessEqual(file_size, 0xFFFFFFFF)

    def test_integrity_scopes_cover_header_payload_entry_and_parameter(self):
        integrity = self.contract["integrity"]
        self.assertEqual(binascii.crc32(b"123456789"), 0xCBF43926)
        self.assertIn("all 320 header bytes", integrity["header_crc_scope"])
        self.assertIn("parameter table followed by the entry table", integrity["payload_scope"])
        self.assertIn("entry bytes 0...19", integrity["entry_crc_scope"])
        self.assertIn("parameter bytes 0...63", integrity["entry_crc_scope"])
        self.assertIn("external", integrity["whole_file_sha256"])

    def test_spatial_lut_cannot_enable_temporal_or_denoising(self):
        header_flags = {flag["name"]: flag for flag in self.contract["header"]["flags"]}
        candidate_flags = {
            flag["name"]: flag for flag in self.contract["parameter_record"]["candidate_flags"]
        }
        tail = field_map(self.contract["parameter_record"]["tail_fields"])
        self.assertEqual(header_flags["temporal_enabled"]["required"], 0)
        self.assertEqual(candidate_flags["temporal_contribution_enabled"]["required"], 0)
        self.assertEqual(candidate_flags["denoising_enabled"]["required"], 0)
        self.assertEqual(tail["temporal_mode"]["value"], 0)

    def test_inactive_secondary_uses_exact_sentinels_and_zero_slot(self):
        inactive = self.contract["entry_record"]["inactive_secondary"]
        self.assertEqual(inactive["secondary_affine_state"], 0xFFFF)
        self.assertEqual(inactive["secondary_descriptor"], 0xFF)
        self.assertEqual(inactive["secondary_message"], 0xFF)
        self.assertEqual(inactive["primary_weight_unorm16"], 0xFFFF)
        self.assertEqual(inactive["secondary_weight_unorm16"], 0)
        self.assertIn("24 zero bytes", inactive["secondary_parameter_slot"])
        self.assertIn("retain provisional top-two margin", inactive["ordinary_margin"])
        self.assertEqual(inactive["source_exact_margin"], 0xFFFF)

    def test_cross_field_invariants_close_source_and_secondary_semantics(self):
        invariants = "\n".join(self.contract["cross_field_invariants"])
        self.assertIn(
            "both luma_coordinate_policy and chroma_coordinate_policy are source_aligned_rational",
            invariants,
        )
        self.assertIn("primary message and descriptor zero", invariants)
        self.assertIn(
            "source_aligned_exact is zero when either luma_coordinate_policy or chroma_coordinate_policy is half_pixel_center",
            invariants,
        )
        self.assertIn("secondary candidate active flag equals has_secondary", invariants)
        self.assertIn("retains the provisional top-two margin", invariants)
        self.assertIn("all six header input digests", invariants)


class CompilerAndRangeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = load("contracts/calibration-plan-v1.json")
        cls.compiler = load("contracts/compiler-contract-v1.json")
        cls.baseline = load("contracts/baseline-ablation-contract-v1.json")

    def test_every_numeric_range_is_sorted_unique_and_nonempty(self):
        for group_name, group in self.plan["ranges"].items():
            for name, values in group.items():
                if isinstance(values, list) and values and all(isinstance(value, int) for value in values):
                    with self.subTest(group=group_name, parameter=name):
                        self.assertEqual(values, sorted(set(values)))

    def test_parameter_order_covers_every_search_coordinate_exactly_once(self):
        mapping = self.plan["ranges"]["mapping"]
        expected = set()
        for band in mapping["spatial_threshold_bands"]:
            expected.add(f"{band}_low_unorm15")
            expected.add(f"{band}_high_unorm15")
        expected.update(
            {
                "analysis_epsilon_q0_30",
                "risk_laplacian_weight_unorm15",
                "chroma_edge_confidence_unorm15",
                "direct_2x_analysis_grid_source_step",
                "direct_3_over_2_analysis_grid_source_step",
            }
        )
        expected.update(
            {
                "direct_2x_luma_coordinate_policy",
                "direct_2x_chroma_coordinate_policy",
                "direct_3_over_2_luma_coordinate_policy",
                "direct_3_over_2_chroma_coordinate_policy",
                "boundary_mode",
            }
        )
        expected.update(
            name
            for name in self.plan["ranges"]["operator"]
            if name not in {"coordinate_policy_by_route", "boundary_mode"}
        )
        expected.update(self.plan["ranges"]["compiler"])
        order = self.plan["search"]["parameter_order"]
        self.assertEqual(len(order), len(set(order)))
        self.assertEqual(set(order), expected)
        initial = self.plan["search"]["initial_vector_values"]
        self.assertEqual(set(initial), set(order))

    def test_full_ash_attempt_budget_is_derived_from_every_declared_domain(self):
        domains = parameter_domains(self.plan)
        maximum_sweeps = self.plan["search"]["maximum_sweeps"]
        declared_value_count = sum(len(values) for values in domains.values())
        maximum_attempt_count = 1 + maximum_sweeps * declared_value_count
        selector = self.baseline["non_ash_selector"]

        self.assertEqual(len(domains), 42)
        self.assertEqual(declared_value_count, 168)
        self.assertEqual(maximum_attempt_count, 1345)
        self.assertEqual(
            FULL_ASH_MAXIMUM_CANDIDATE_EVALUATION_BUDGET,
            maximum_attempt_count,
        )
        self.assertEqual(
            selector["full_ash_maximum_candidate_evaluation_budget"],
            maximum_attempt_count,
        )
        self.assertEqual(selector["candidate_evaluation_budget"], 1513)
        self.assertIn(
            "sum(42 declared domain cardinalities)",
            selector["budget_formula"],
        )

    def test_initial_vector_uses_only_declared_candidates(self):
        ranges = self.plan["ranges"]
        initial = self.plan["search"]["initial_vector_values"]
        for name, value in initial.items():
            if name == "alias_or_ringing_risk_low_unorm15":
                candidates = ranges["mapping"][name]
            elif name == "alias_or_ringing_risk_high_unorm15":
                candidates = ranges["mapping"][name]
            elif name.endswith("_low_unorm15"):
                candidates = ranges["mapping"]["low_unorm15"]
            elif name.endswith("_high_unorm15"):
                candidates = ranges["mapping"]["high_unorm15"]
            elif name in {
                "direct_2x_luma_coordinate_policy",
                "direct_2x_chroma_coordinate_policy",
                "direct_3_over_2_luma_coordinate_policy",
                "direct_3_over_2_chroma_coordinate_policy",
            }:
                candidates = ranges["operator"]["coordinate_policy_by_route"]
            elif name == "boundary_mode":
                candidates = ranges["operator"]["boundary_mode"]
            elif name in ranges["mapping"]:
                candidates = ranges["mapping"][name]
            elif name in ranges["operator"]:
                candidates = ranges["operator"][name]
            else:
                candidates = ranges["compiler"][name]
            with self.subTest(parameter=name):
                self.assertIn(value, candidates)
        self.assertEqual(initial["confidence_threshold_unorm16"], 36044)

    def test_initial_vector_is_the_declared_sequence_86_incumbent_correction(self):
        self.assertEqual(
            self.plan["search"]["initial_vector_values"],
            {
                "edge_present_low_unorm15": 3277,
                "edge_present_high_unorm15": 11468,
                "coherent_structure_low_unorm15": 9830,
                "coherent_structure_high_unorm15": 16384,
                "texture_high_frequency_low_unorm15": 3277,
                "texture_high_frequency_high_unorm15": 9830,
                "alias_or_ringing_risk_low_unorm15": 0,
                "alias_or_ringing_risk_high_unorm15": 3277,
                "chroma_luma_structure_aligned_low_unorm15": 3277,
                "chroma_luma_structure_aligned_high_unorm15": 9830,
                "analysis_epsilon_q0_30": 1,
                "risk_laplacian_weight_unorm15": 8192,
                "chroma_edge_confidence_unorm15": 1638,
                "direct_2x_analysis_grid_source_step": 1,
                "direct_3_over_2_analysis_grid_source_step": 1,
                "direct_2x_luma_coordinate_policy": "half_pixel_center",
                "direct_2x_chroma_coordinate_policy": "half_pixel_center",
                "direct_3_over_2_luma_coordinate_policy": "source_aligned_rational",
                "direct_3_over_2_chroma_coordinate_policy": "source_aligned_rational",
                "boundary_mode": "mirror_reflect101",
                "anisotropy_strength_q12": 0,
                "minimum_anisotropic_magnitude_unorm15": 1638,
                "minimum_anisotropic_coherence_unorm15": 8192,
                "detail_gain_q12": 768,
                "relaxed_limiter_alpha_q12": 384,
                "risk_detail_suppression_unorm15": 21299,
                "low_pass_radius_q8_8": 512,
                "support_radius_step_q8_8": 64,
                "detail_gain_step_q12": 128,
                "regularization_step_q12": 64,
                "confidence_threshold_unorm16": 36044,
                "penalty_decay_denominator": 32,
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
            },
        )

    def test_search_preregisters_fail_closed_infeasible_restoration(self):
        search = self.plan["search"]
        self.assertEqual(search["protocol_version"], "1.2.0")
        self.assertIn("including the current value", search["sweep_rule"])
        self.assertIn(
            "minimum canonical development-feasibility failure count",
            search["sweep_rule"],
        )
        self.assertIn(
            "evaluation failures are never eligible",
            search["sweep_rule"],
        )
        self.assertIn(
            "once current is feasible",
            search["infeasible_retention_rule"],
        )

    def test_analysis_grid_is_independent_per_route(self):
        mapping = self.plan["ranges"]["mapping"]
        self.assertEqual(mapping["direct_2x_analysis_grid_source_step"], [1, 2, 4])
        self.assertEqual(mapping["direct_3_over_2_analysis_grid_source_step"], [1, 2, 4])
        self.assertNotIn("analysis_grid_source_step", self.plan["search"]["parameter_order"])

    def test_threshold_pair_space_has_only_declared_valid_pairs(self):
        mapping = self.plan["ranges"]["mapping"]
        self.assertEqual(
            mapping["spatial_threshold_bands"],
            [
                "edge_present",
                "coherent_structure",
                "texture_high_frequency",
                "alias_or_ringing_risk",
                "chroma_luma_structure_aligned",
            ],
        )
        self.assertEqual(mapping["low_unorm15"], [3277, 4915, 6553, 8192, 9830])
        self.assertEqual(mapping["high_unorm15"], [9830, 11468, 13107, 14745, 16384])
        self.assertEqual(
            mapping["alias_or_ringing_risk_low_unorm15"],
            [0, 3277, 4915, 6553, 8192, 9830],
        )
        self.assertEqual(
            mapping["alias_or_ringing_risk_high_unorm15"],
            [3277, 9830, 11468, 13107, 14745, 16384],
        )
        domains = [
            (mapping["low_unorm15"], mapping["high_unorm15"]),
            (
                mapping["alias_or_ringing_risk_low_unorm15"],
                mapping["alias_or_ringing_risk_high_unorm15"],
            ),
        ]
        for low_domain, high_domain in domains:
            pairs = [
                (low, high)
                for low in low_domain
                for high in high_domain
                if low <= high and high - low >= 3277
            ]
            self.assertGreater(len(pairs), 0)
            self.assertTrue(
                all(0 <= low <= high <= 32767 and high - low >= 3277 for low, high in pairs)
            )

    def test_canonical_path_order_is_base_three_not_character_order(self):
        branch = self.compiler["canonical_branch"]
        digits = branch["action_digit"]
        paths = list(itertools.product(branch["action_alphabet"], repeat=branch["depth"]))

        def ordinal(path):
            result = 0
            for action in path:
                result = result * 3 + digits[action]
            return result

        ordered = sorted(paths, key=ordinal)
        self.assertEqual([ordinal(path) for path in ordered], list(range(81)))
        self.assertEqual(ordered[0], ("0", "0", "0", "0"))
        self.assertEqual(ordered[-1], ("-", "-", "-", "-"))
        self.assertNotEqual(ordered, sorted(paths))

    def test_branch_mass_is_exact_and_enumerates_81_leaves(self):
        branch = self.compiler["canonical_branch"]
        masses = branch["action_mass_numerator_over_4"]
        paths = itertools.product(branch["action_alphabet"], repeat=branch["depth"])
        leaf_masses = [math.prod(masses[action] for action in path) for path in paths]
        self.assertEqual(len(leaf_masses), 81)
        self.assertEqual(sum(leaf_masses), branch["leaf_mass_denominator"])

    def test_index_cardinality_uses_256_parity_valid_states(self):
        valid = [raw for raw in range(512) if (raw & 1) == (bin(raw >> 1).count("1") & 1)]
        self.assertEqual(len(valid), 256)
        for route in self.compiler["index_domain"]["routes"]:
            expected = route["phase_count"] * 4 * len(valid)
            self.assertEqual(self.compiler["index_domain"]["entry_counts"][route["name"]], expected)

    def test_semantic_levels_and_base_descriptor_are_fully_declared(self):
        steps = self.compiler["semantic_steps"]
        self.assertEqual([step["level"] for step in steps], [0, 1, 2, 3])
        self.assertEqual(
            [step["axis"] for step in steps],
            [
                "orientation_sector_delta",
                "support_radius_delta",
                "detail_gain_delta",
                "regularization_delta",
            ],
        )
        base = self.compiler["base_descriptor"]
        self.assertEqual(base["state_coordinates"]["temporal_support_valid"], 7)
        self.assertEqual(base["temporal_coordinate_use"], "none")
        for key in ("kernel_bit", "support_bit", "detail_bit", "limiter_bit", "descriptor_id"):
            self.assertIn(key, base)
        application = self.compiler["descriptor_application"]
        self.assertIn("never changes the kernel", application["kernel_bit"])
        self.assertIn("modulo 4", application["orientation_sector"])
        self.assertIn("retain the base descriptor", application["support_bit"])
        self.assertIn("Keys base 512", application["support_radius_q8_8"])
        self.assertIn("final detail_gain_q12 is positive", application["detail_bit"])
        self.assertIn("final relaxed_limiter_alpha_q12 is positive", application["limiter_bit"])

    def test_message_mass_converts_once_after_uint64_accumulation(self):
        mass = self.compiler["mass_and_ranking"]
        self.assertIn("sum UInt64", mass["raw_message_mass"])
        self.assertIn("complete raw sum", mass["message_weight_q16_16"])
        self.assertIn("denominator = 256 * 65535", mass["message_weight_q16_16"])
        self.assertIn("round_half_up", mass["message_weight_q16_16"])
        self.assertIn("exactly once", mass["message_weight_q16_16"])
        self.assertNotIn("candidate_weight_q16_16", mass)
        self.assertEqual(mass["message_rank"][0], "descending message_weight_q16_16")
        denominator = 256 * 65535

        def encode(raw):
            return ((raw * 65536) + (denominator // 2)) // denominator

        self.assertEqual(encode(256 * 65535), 65536)
        self.assertEqual(encode(128 * 65535), 32768)
        provisional_primary = 50000
        provisional_secondary = 65535 - provisional_primary
        provisional_margin = provisional_primary - provisional_secondary
        self.assertGreaterEqual(provisional_margin, 32768)
        stored_primary, stored_secondary = 65535, 0
        self.assertNotEqual(provisional_margin, stored_primary - stored_secondary)

    def test_detail_and_limiter_bits_derive_from_final_parameters(self):
        selected_gain = self.plan["search"]["initial_vector_values"]["detail_gain_q12"]
        selected_alpha = self.plan["search"]["initial_vector_values"]["relaxed_limiter_alpha_q12"]
        detail_step = self.plan["search"]["initial_vector_values"]["detail_gain_step_q12"]
        regularization_step = self.plan["search"]["initial_vector_values"]["regularization_step_q12"]

        def apply(base_detail_bit, detail_delta, base_limiter_bit, regularization_delta):
            base_gain = selected_gain if base_detail_bit else 0
            gain = min(2048, max(0, base_gain + (detail_delta * detail_step)))
            base_alpha = selected_alpha if base_limiter_bit else 0
            alpha = min(1024, max(0, base_alpha - (regularization_delta * regularization_step)))
            return gain, int(gain > 0), alpha, int(alpha > 0)

        self.assertEqual(apply(0, 1, 0, 0), (128, 1, 0, 0))
        self.assertEqual(apply(1, -1, 1, 1), (640, 1, 320, 1))
        hard = "\n".join(self.compiler["hard_compatibility"])
        self.assertNotIn("detail gain greater than zero unless final relaxed limiter alpha is zero", hard)
        self.assertIn("alpha greater than zero when chroma_luma_structure_aligned is zero", hard)
        self.assertIn("anisotropic descriptor only when", hard)

        def compatible(gain, alpha, risk, chroma_aligned, anisotropic, edge, coherent):
            if gain > 0 and risk == 1:
                return False
            if alpha > 0 and chroma_aligned == 0:
                return False
            if anisotropic and edge == 0 and coherent == 0:
                return False
            return True

        self.assertTrue(compatible(640, 320, 0, 1, True, 1, 1))
        self.assertFalse(compatible(640, 320, 1, 1, True, 1, 1))
        self.assertFalse(compatible(0, 320, 0, 0, False, 0, 0))
        penalty = self.compiler["penalty"]
        self.assertIn("before path deltas", penalty["operand_binding"])
        self.assertTrue(any("base detail bit" in term for term in penalty["terms"]))

    def test_temporal_states_alias_spatial_semantics_but_keep_original_anchor(self):
        temporal = self.compiler["temporal_disabled_semantics"]
        self.assertFalse(temporal["enabled"])
        self.assertIn("clear payload coordinate 7", temporal["semantic_state"])
        self.assertIn("original parity-valid raw source state", temporal["affine_anchor"])
        self.assertIn("same messages, descriptors, weights, and parameter bytes", temporal["context_rule"])

    def test_source_aligned_override_occurs_after_all_leaf_checks(self):
        source = self.compiler["source_aligned_exact_semantics"]
        self.assertIn("all 81 canonical leaves", source["compiler_order"])
        self.assertEqual(source["primary_message"], 0)
        self.assertEqual(source["primary_descriptor"], 0)
        self.assertEqual(source["primary_affine_state"], "original source anchor")
        self.assertEqual(source["primary_weight_unorm16"], 65535)
        self.assertEqual(source["margin_unorm16"], 65535)
        self.assertIn("forbidden", source["half_pixel_rule"])


class AnalysisGridContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = load("contracts/calibration-plan-v1.json")["analysis_grid_contract"]

    @staticmethod
    def axis_cells(extent: int, step: int):
        count = (extent + step - 1) // step
        cells = []
        for index in range(count):
            origin = index * step
            actual = min(step, extent - origin)
            center = Fraction(origin, 1) + Fraction(actual - 1, 2)
            cells.append((origin, actual, center))
        return cells

    @staticmethod
    def assigned_cell(coordinate: Fraction, extent: int, step: int) -> int:
        count = (extent + step - 1) // step
        proposed = math.floor((coordinate + Fraction(1, 2)) / step)
        return min(count - 1, max(0, proposed))

    def test_contract_locks_symmetric_continuous_cell_geometry(self):
        self.assertEqual(self.contract["step_domain"], [1, 2, 4])
        geometry = self.contract["cell_geometry"]
        self.assertTrue(geometry["partial_high_edge_cells"])
        self.assertIn("(actual_width - 1) / 2", geometry["center"])
        self.assertIn("ceil(source_width / s)", geometry["cell_count"])
        analysis = self.contract["feature_analysis"]
        self.assertIn("bilinearly", analysis["sampling"])
        self.assertIn("selected locked boundary mode", analysis["boundary"])
        self.assertIn("exactly the P05 integer-site feature math", analysis["step_one_reduction"])

    def test_cell_counts_and_partial_high_edge_centers(self):
        self.assertEqual(
            self.axis_cells(5, 2),
            [
                (0, 2, Fraction(1, 2)),
                (2, 2, Fraction(5, 2)),
                (4, 1, Fraction(4, 1)),
            ],
        )
        self.assertEqual(
            self.axis_cells(6, 4),
            [
                (0, 4, Fraction(3, 2)),
                (4, 2, Fraction(9, 2)),
            ],
        )
        width_cells = self.axis_cells(7, 4)
        height_cells = self.axis_cells(5, 4)
        self.assertEqual((len(width_cells), len(height_cells)), (2, 2))
        self.assertEqual(len(width_cells) * len(height_cells), 4)
        self.assertEqual(width_cells[-1], (4, 3, Fraction(5, 1)))

    def test_dispatch_assignment_clamps_floor_of_shifted_exact_coordinate(self):
        coordinates = [
            Fraction(-3, 1),
            Fraction(-1, 2),
            Fraction(0, 1),
            Fraction(149, 100),
            Fraction(3, 2),
            Fraction(7, 2),
            Fraction(9, 2),
            Fraction(10, 1),
        ]
        observed = [self.assigned_cell(coordinate, extent=5, step=2) for coordinate in coordinates]
        self.assertEqual(observed, [0, 0, 0, 0, 1, 2, 2, 2])
        for source_index in range(5):
            self.assertEqual(
                self.assigned_cell(Fraction(source_index, 1), extent=5, step=1),
                source_index,
            )

    def test_step_one_bilinear_sampling_reduces_to_integer_site_math(self):
        plane = ((0, 1, 2), (10, 11, 12), (20, 21, 22))

        def sample(x: Fraction, y: Fraction) -> Fraction:
            x0 = math.floor(x)
            y0 = math.floor(y)
            tx = x - x0
            ty = y - y0

            def code(column, row):
                bounded_x = min(2, max(0, column))
                bounded_y = min(2, max(0, row))
                return Fraction(plane[bounded_y][bounded_x], 1)

            top = code(x0, y0) * (1 - tx) + code(x0 + 1, y0) * tx
            bottom = code(x0, y0 + 1) * (1 - tx) + code(x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bottom * ty

        for row in range(3):
            for column in range(3):
                self.assertEqual(sample(Fraction(column), Fraction(row)), plane[row][column])
        self.assertEqual(sample(Fraction(1, 2), Fraction(1, 2)), Fraction(11, 2))

    def test_cell_assignment_never_quantizes_exact_phase_or_chroma_siting(self):
        exact_route_coordinates = [Fraction(0, 1), Fraction(2, 3), Fraction(4, 3)]
        exact_phases = [coordinate - math.floor(coordinate) for coordinate in exact_route_coordinates]
        assignments = [
            self.assigned_cell(coordinate, extent=5, step=2)
            for coordinate in exact_route_coordinates
        ]
        self.assertEqual(assignments, [0, 0, 0])
        self.assertEqual(exact_phases, [Fraction(0), Fraction(2, 3), Fraction(1, 3)])

        exact_chroma_coordinate = Fraction(1, 3)
        locked_siting_correction = Fraction(1, 2)
        luma_lattice_coordinate = (2 * exact_chroma_coordinate) + locked_siting_correction
        self.assertEqual(luma_lattice_coordinate, Fraction(7, 6))
        self.assertEqual(
            luma_lattice_coordinate - math.floor(luma_lattice_coordinate),
            Fraction(1, 6),
        )
        chroma = self.contract["chroma_siting"]
        self.assertIn("no intermediate rounding", chroma["rounding"])


class MetricAndParityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tolerances = load("contracts/metric-performance-tolerances-v1.json")
        cls.locked_schema = load("schemas/locked-metric-policy-v2.schema.json")
        cls.parity_schema = load("schemas/native-parity-manifest-v1.schema.json")
        cls.parity_preregistration = load("contracts/native-parity-manifest-v1.preregistered.json")

    def locked_policy_fixture(self) -> dict:
        seed_path = REPOSITORY_ROOT / "validation/quality/policies/metric-policy.json"
        policy = json.loads(seed_path.read_text(encoding="utf-8"))
        policy["schema_version"] = "2.0.0"
        policy["status"] = "locked"
        policy["unlocked_release_fields"] = []
        policy["release_tolerances"] = {
            "contract_path": "validation/calibration_v2/contracts/metric-performance-tolerances-v1.json",
            "contract_sha256": "a" * 64,
            "y_psnr_paired_delta_lower_bound_db": {
                "full_spatial_ash_vs_best_fixed_same_bank": 0.0,
                "full_spatial_ash_vs_non_ash_same_bank_selector": 0.0,
                "full_spatial_ash_vs_best_conventional_baseline": 0.0,
                "comparison": "strictly_greater_than",
            },
            "ms_ssim_noninferiority_lower_bound_minimum": -0.002,
            "ringing_overshoot_absolute_maximum": 0.05,
            "ringing_undershoot_magnitude_absolute_maximum": 0.05,
            "ringing_increase_maximum": 0.01,
            "alias_ratio_maximum": 0.05,
            "alias_increase_maximum": 0.01,
            "chroma_displacement_pixels_maximum": 0.25,
            "chroma_displacement_increase_pixels_maximum": 0.1,
            "severe_regression": {
                "per_asset_y_psnr_delta_db_minimum": -0.25,
                "per_category_mean_y_psnr_delta_db_minimum": -0.1,
                "allowed_asset_failure_fraction": 0.0,
            },
            "minimum_source_families_per_category": {
                "development": 1,
                "validation": 1,
                "holdout": 1,
            },
            "temporal_ghosting": {
                "normalized_error_absolute_maximum": 0.02,
                "increase_over_spatial_maximum": 0.005,
                "scene_cut_reset_latency_frames_maximum": 1,
            },
            "dispatch_overhead_budget": {
                "measured_validation_p95_percent": 12.2,
                "uncertainty_margin_percentage_points": 5.0,
                "derived_budget_percent": 18,
                "measurement_run_ids": ["validation-dispatch-001"],
                "measurement_artifact_sha256_values": ["b" * 64],
                "derivation_formula": "max(5, ceil(measured_validation_p95_percent + 5))",
                "locked_before_g08": True,
                "post_g08_adjustment_allowed": False,
            },
        }
        policy["dispatch_measurement_evidence"] = {
            "path": "dispatch-measurement.json",
            "sha256": "d" * 64,
            "size_bytes": 4096,
            "measurement_domain": "native_cpu_reference_projection_not_metal",
            "production_metal_constraint_satisfied": False,
            "status": "pass",
        }
        policy["hash_scope"] = "canonical sorted-key compact UTF-8 JSON excluding /policy_sha256"
        policy["policy_sha256"] = "c" * 64
        return policy

    def test_corrected_locked_metric_policy_accepts_only_complete_lock(self):
        policy = self.locked_policy_fixture()
        self.assertEqual(errors(policy, self.locked_schema), [])

        invalid = copy.deepcopy(policy)
        invalid["unlocked_release_fields"] = ["ringing tolerance"]
        self.assertNotEqual(errors(invalid, self.locked_schema), [])

        invalid = copy.deepcopy(policy)
        del invalid["ms_ssim"]["scale_combination"]
        self.assertNotEqual(errors(invalid, self.locked_schema), [])

        invalid = copy.deepcopy(policy)
        invalid["release_tolerances"]["dispatch_overhead_budget"]["derived_budget_percent"] = 26
        self.assertNotEqual(errors(invalid, self.locked_schema), [])

        invalid = copy.deepcopy(policy)
        invalid["status"] = "development_seed"
        self.assertNotEqual(errors(invalid, self.locked_schema), [])

    def test_dispatch_budget_derivation_is_preregistered_and_bounded(self):
        budget = self.tolerances["performance"]["ash_dispatch_overhead_budget"]
        self.assertEqual(budget["status"], "pending_validation_derivation")
        self.assertEqual(budget["uncertainty_margin_percentage_points"], 5.0)
        self.assertEqual(budget["minimum_budget_percent"], 5.0)
        self.assertEqual(budget["maximum_admissible_budget_percent"], 25.0)
        self.assertFalse(budget["post_g08_adjustment_allowed"])

        def derive(measured_p95):
            return max(5, math.ceil(measured_p95 + 5))

        self.assertEqual(derive(0.0), 5)
        self.assertEqual(derive(12.2), 18)
        self.assertEqual(derive(20.0), 25)
        self.assertGreater(derive(20.01), 25)

    def parity_fixture(self) -> dict:
        def output(path, entry_count):
            return {
                "path": path,
                "whole_file_size_bytes": 123456,
                "whole_file_sha256": "d" * 64,
                "payload_sha256": "e" * 64,
                "header_crc32": "0x1234ABCD",
                "payload_crc32": "0x5678EF90",
                "entry_count": entry_count,
                "parameter_count": 17,
            }

        return {
            "schema_version": "1.0.0",
            "manifest_id": "mirmir-native-lut-parity-v1",
            "status": "pass",
            "conflict_record": self.parity_preregistration["conflict_record"],
            "input_hashes": {
                name: "a" * 64 for name in self.parity_preregistration["required_input_hashes"]
            },
            "implementations": {
                "production_swift": {
                    "implementation_id": "project-compiler",
                    "implementation_version": "1",
                    "source_manifest_path": "sources/production-swift.json",
                    "source_manifest_sha256": "b" * 64,
                    "source_manifest_size_bytes": 1234,
                    "independence_attested": True,
                },
                "independent_test_python": {
                    "implementation_id": "independent-oracle",
                    "implementation_version": "1",
                    "source_manifest_path": "sources/independent-python.json",
                    "source_manifest_sha256": "c" * 64,
                    "source_manifest_size_bytes": 5678,
                    "independence_attested": True,
                },
            },
            "routes": [
                {
                    "route": "direct_2x",
                    "route_id": 1,
                    "expected_entry_count": 4096,
                    "production_swift": output("production/direct2x.ashlut", 4096),
                    "independent_test_python": output("independent/direct2x.ashlut", 4096),
                    "byte_identical": True,
                    "payload_hash_identical": True,
                    "first_differing_byte_offset": None,
                },
                {
                    "route": "direct_3_over_2",
                    "route_id": 2,
                    "expected_entry_count": 9216,
                    "production_swift": output("production/direct3over2.ashlut", 9216),
                    "independent_test_python": output("independent/direct3over2.ashlut", 9216),
                    "byte_identical": True,
                    "payload_hash_identical": True,
                    "first_differing_byte_offset": None,
                },
            ],
            "all_routes_byte_identical": True,
            "canonicalization": "sorted-key compact UTF-8 JSON with a trailing newline",
        }

    def test_normalized_native_parity_manifest_has_only_native_roles(self):
        roles = [item["role"] for item in self.parity_preregistration["implementations"]]
        self.assertEqual(roles, ["production_swift", "independent_test_python"])
        forbidden_keys = {
            "swift_sha256",
            "csharp_sha256",
            "windows_lut_parity_trx",
            "platform_a_sha256",
            "platform_b_sha256",
        }
        self.assertTrue(forbidden_keys.isdisjoint(set(dictionary_keys(self.parity_preregistration))))

        manifest = self.parity_fixture()
        self.assertEqual(errors(manifest, self.parity_schema), [])
        self.assertTrue(forbidden_keys.isdisjoint(set(dictionary_keys(manifest))))

        invalid = copy.deepcopy(manifest)
        invalid["csharp_sha256"] = "f" * 64
        self.assertNotEqual(errors(invalid, self.parity_schema), [])

    def test_parity_fixture_values_are_equal_not_only_boolean_claims(self):
        manifest = self.parity_fixture()
        for route in manifest["routes"]:
            production = route["production_swift"]
            independent = route["independent_test_python"]
            for key in (
                "whole_file_size_bytes",
                "whole_file_sha256",
                "payload_sha256",
                "header_crc32",
                "payload_crc32",
                "entry_count",
                "parameter_count",
            ):
                self.assertEqual(production[key], independent[key], (route["route"], key))
            self.assertEqual(production["entry_count"], route["expected_entry_count"])


class LockedCompilerInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = load("schemas/locked-compiler-input-v1.schema.json")
        cls.template = load("contracts/locked-compiler-input-v1.template.json")

    def fixture(self) -> dict:
        denominator = 16
        table = [
            ((65535 * denominator) + ((denominator + index) // 2)) // (denominator + index)
            for index in range(256)
        ]
        document = {
            "schema_version": "1.0.0",
            "status": "locked",
            "configuration_id": "p06-validation-selection-001",
            "hash_bindings": {
                "mapping_sha256": "a" * 64,
                "operator_bank_sha256": "b" * 64,
                "metric_policy_sha256": "c" * 64,
                "compiler_inputs_sha256": "f" * 64,
                "calibration_plan_sha256": "d" * 64,
                "corpus_lock_bundle_sha256": "e" * 64,
            },
            "canonicalization": {
                "encoding": "UTF-8",
                "object_key_order": "ascending Unicode scalar value",
                "array_order": "preserved",
                "whitespace": "none",
                "string_escaping": "JSON quotation, reverse-solidus, and control escapes; non-ASCII encoded directly as UTF-8",
                "number_domain": "integers only",
                "duplicate_keys": "reject",
                "trailing_newline_in_hash_input": False,
                "hash_algorithm": "SHA-256",
                "hash_scope": "complete canonical document with only /hash_bindings/compiler_inputs_sha256 omitted",
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
                "penalty_to_weight_unorm16": table,
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
                    "luma_coordinate_policy": "source_aligned_rational",
                    "chroma_coordinate_policy": "half_pixel_center",
                    "analysis_grid_source_step": 1,
                },
                "direct_3_over_2": {
                    "luma_coordinate_policy": "half_pixel_center",
                    "chroma_coordinate_policy": "source_aligned_rational",
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
                "predicate": "both luma and chroma coordinate policies are source_aligned_rational with horizontal phase zero and vertical phase zero",
                "primary_message": 0,
                "primary_descriptor": 0,
                "secondary": "inactive",
                "denoising": False,
            },
            "top_two": 2,
        }
        document["hash_bindings"]["compiler_inputs_sha256"] = canonical_compiler_input_sha256(document)
        return document

    def test_template_is_deliberately_not_a_locked_input(self):
        self.assertNotEqual(errors(self.template, self.schema), [])
        self.assertIn("<replace", self.template["configuration_id"])

    def test_complete_locked_input_validates_and_self_hash_recomputes(self):
        document = self.fixture()
        self.assertEqual(errors(document, self.schema), [])
        self.assertEqual(
            document["hash_bindings"]["compiler_inputs_sha256"],
            canonical_compiler_input_sha256(document),
        )
        canonical_text = canonical_compiler_input_bytes(document).decode("utf-8")
        self.assertNotIn(document["hash_bindings"]["compiler_inputs_sha256"], canonical_text)
        self.assertFalse(canonical_text.endswith("\n"))

    def test_self_hash_binds_every_field_except_itself(self):
        document = self.fixture()
        original = canonical_compiler_input_sha256(document)
        document["routes"]["direct_3_over_2"]["analysis_grid_source_step"] = 4
        self.assertNotEqual(canonical_compiler_input_sha256(document), original)
        document["hash_bindings"]["compiler_inputs_sha256"] = "1" * 64
        self.assertNotEqual(document["hash_bindings"]["compiler_inputs_sha256"], canonical_compiler_input_sha256(document))

    def test_penalty_table_is_exact_formula_and_monotone(self):
        document = self.fixture()
        policy = document["compiler_policy"]
        denominator = policy["penalty_decay_denominator"]
        expected = [
            ((65535 * denominator) + ((denominator + index) // 2)) // (denominator + index)
            for index in range(256)
        ]
        self.assertEqual(policy["penalty_to_weight_unorm16"], expected)
        self.assertEqual(expected[0], 65535)
        self.assertTrue(all(first >= second for first, second in zip(expected, expected[1:])))

    def test_locked_routes_can_select_coordinate_and_grid_independently(self):
        routes = self.fixture()["routes"]
        self.assertNotEqual(
            routes["direct_2x"]["luma_coordinate_policy"],
            routes["direct_2x"]["chroma_coordinate_policy"],
        )
        self.assertNotEqual(
            routes["direct_3_over_2"]["luma_coordinate_policy"],
            routes["direct_3_over_2"]["chroma_coordinate_policy"],
        )
        self.assertNotEqual(
            routes["direct_2x"]["analysis_grid_source_step"],
            routes["direct_3_over_2"]["analysis_grid_source_step"],
        )

    def test_detail_low_pass_and_candidate_support_are_not_conflated(self):
        document = self.fixture()
        operator = document["operator_parameters"]
        self.assertIn("low_pass_radius_q8_8", operator)
        self.assertNotIn("support_radius_q8_8", operator)
        step = document["semantic_steps"]["support_radius_step_q8_8"]

        def support(kernel_bit, delta):
            base = 768 if kernel_bit else 512
            return min(768, max(256, base + (delta * step)))

        self.assertEqual(support(0, 0), 512)
        self.assertEqual(support(0, 1), 576)
        self.assertEqual(support(0, -1), 448)
        self.assertEqual(support(1, 1), 768)
        self.assertEqual(support(1, -1), 704)


if __name__ == "__main__":
    unittest.main()
