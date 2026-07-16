from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path, PurePosixPath
import unittest

from jsonschema import Draft202012Validator

from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = (
    CALIBRATION_ROOT / "contracts/plane-aware-lut-preregistration-v1.json"
)
SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/plane-aware-lut-preregistration-v1.schema.json"
)
README_PATH = CALIBRATION_ROOT / "README.md"

EXPECTED_PACKAGE_MANIFEST_SHA256 = (
    "bac31029e2aa0e9ef89cb25f36c9cfd9ac5ce0920e546bd3dea0edea06520afd"
)
EXPECTED_PACKAGE_FILES = {
    "instructions/00_MASTER_EXECUTION_DIRECTIVE.md": (
        "1a1f75c785f91b764e55f66bdd7880a237b1ae710351474d9dc8a7a4a6018800",
        4469,
    ),
    "instructions/03_ASH_VIDEO_STATE_MAPPING_V2.md": (
        "85782e6ed18aee0bbf4108ac711a9e662b9b03aa796ed6aaa27af2f7c921774e",
        4469,
    ),
    "instructions/04_BRANCH_COMPILER_AND_BITWISE_RUNTIME.md": (
        "f5e4458ae627107172003b397dacefa4b0a7b8bea5468c0d87ab5130f3a93677",
        3986,
    ),
    "instructions/05_DIRECT_RECONSTRUCTION_AND_SELECTION.md": (
        "1253e29cb151bffd4e31762348f0c9c9e5619a762018f402a201e9ae9ad46b56",
        4146,
    ),
    "instructions/08_QUALITY_CALIBRATION_AND_HOLDOUT.md": (
        "803b4d16f4b1f171420bc3602b101eed0080c2e84a7924cdfec3d5f2ba98172f",
        2416,
    ),
    "instructions/09_TEMPORAL_RECONSTRUCTION.md": (
        "f6af6816abf9658777a12dba39c263da99f378da97ec9081e3f8c6268178bab9",
        1829,
    ),
    "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md": (
        "439e908d0d64caf53142927fc804e292c0848de9aecf404d8c4651c03dd17328",
        11524,
    ),
    "instructions/20_COMPONENT_IMPLEMENTATION_CONTRACTS.md": (
        "f091856136c9559462b064a5a2044a3160c105cfd58a4b0741025b896789bedf",
        10800,
    ),
}
EXPECTED_REPOSITORY_BINDING_IDS = (
    "compiler_contract_v1",
    "instruction_conflict_normalization_v1",
    "lut_binary_contract_v1",
    "p06_failure_code_path_map",
    "p06_failure_snapshot",
    "spatial_policy_admissibility_manifest",
    "spatial_semantics_preregistration_v2",
    "coordinate_anisotropy_diagnostic_receipt",
)


def load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def all_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_keys(child)


class PlaneAwareLUTPreregistrationV1Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw_contract = CONTRACT_PATH.read_bytes()
        cls.contract = load_object(CONTRACT_PATH)
        cls.raw_schema = SCHEMA_PATH.read_bytes()
        cls.schema = load_object(SCHEMA_PATH)
        cls.validator = Draft202012Validator(cls.schema)

    def test_schema_canonical_contract_and_self_hash(self) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.assertEqual(list(self.validator.iter_errors(self.contract)), [])
        self.assertEqual(
            self.raw_contract,
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            self.raw_schema,
            canonical_json_bytes(self.schema) + b"\n",
        )
        unhashed = dict(self.contract)
        observed = unhashed.pop("artifact_sha256")
        self.assertEqual(
            observed,
            hashlib.sha256(canonical_json_bytes(unhashed)).hexdigest(),
        )
        self.assertEqual(self.contract["status"], "preregistered_not_executed")

    def test_complete_repository_file_and_self_hash_bindings(self) -> None:
        bindings = self.contract["input_bindings"]["repository"]
        self.assertEqual(
            tuple(row["id"] for row in bindings),
            EXPECTED_REPOSITORY_BINDING_IDS,
        )
        self.assertEqual(len(bindings), len({row["id"] for row in bindings}))
        for binding in bindings:
            with self.subTest(binding=binding["id"]):
                relative = PurePosixPath(binding["path"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                payload = ROOT.joinpath(*relative.parts).read_bytes()
                self.assertEqual(len(payload), binding["size_bytes"])
                self.assertEqual(
                    hashlib.sha256(payload).hexdigest(),
                    binding["sha256"],
                )
                self_hash = binding["self_hash"]
                if self_hash is None:
                    continue
                document = json.loads(payload)
                self.assertEqual(
                    document[self_hash["field"]],
                    self_hash["sha256"],
                )
                unhashed = dict(document)
                unhashed.pop(self_hash["field"])
                self.assertEqual(
                    hashlib.sha256(canonical_json_bytes(unhashed)).hexdigest(),
                    self_hash["sha256"],
                )

    def test_instruction_package_manifest_and_file_bindings_are_exact(self) -> None:
        package = self.contract["input_bindings"]["instruction_package"]
        self.assertEqual(package["package_id"], "mirmr-iA.1.0.1.0")
        self.assertEqual(
            package["package_manifest"],
            {
                "path": "package_manifest.json",
                "sha256": EXPECTED_PACKAGE_MANIFEST_SHA256,
                "size_bytes": 14059,
            },
        )
        self.assertEqual(
            package["checksum_index"],
            {
                "path": "SHA256SUMS.txt",
                "sha256": (
                    "176580ebabf5be861a1008dd7180bc1e9ba2c9602864b39af1a3e959aa159651"
                ),
                "size_bytes": 8327,
            },
        )
        observed = {
            row["path"]: (row["sha256"], row["size_bytes"])
            for row in package["files"]
        }
        self.assertEqual(observed, EXPECTED_PACKAGE_FILES)
        normalization = load_object(
            CALIBRATION_ROOT
            / "contracts/instruction-conflict-normalization-v1.json"
        )
        self.assertEqual(
            normalization["source_package_manifest_sha256"],
            EXPECTED_PACKAGE_MANIFEST_SHA256,
        )

    def test_format_1_1_is_hash_bound_and_behaviorally_frozen(self) -> None:
        binary = self.contract["binary_format"]
        legacy = binary["format_1_1"]
        self.assertEqual(legacy["version"], {"major": 1, "minor": 1})
        self.assertTrue(legacy["bytes_frozen"])
        self.assertTrue(legacy["behaviorally_frozen"])
        self.assertTrue(legacy["contracts_frozen"])
        self.assertTrue(legacy["codec_frozen"])
        self.assertTrue(legacy["loader_frozen"])
        self.assertTrue(legacy["runtime_frozen"])
        self.assertTrue(legacy["decoded_behavior_frozen"])
        self.assertTrue(legacy["selected_by_schema_1_only"])
        self.assertEqual(legacy["swift_codec_family"], "V2")
        self.assertEqual(
            legacy["reserved_header_regions_zero"],
            [{"offset": 30, "size": 2}, {"offset": 300, "size": 20}],
        )

        contract = load_object(
            CALIBRATION_ROOT / "contracts/lut-binary-contract-v1.json"
        )
        self.assertEqual(contract["format_version"], {"major": 1, "minor": 1})
        fields = {row["name"]: row for row in contract["header"]["fields"]}
        self.assertEqual(fields["reserved0"], {
            "name": "reserved0", "offset": 30, "size": 2, "encoding": "zero"
        })
        self.assertEqual(fields["reserved_tail"], {
            "name": "reserved_tail", "offset": 300, "size": 20, "encoding": "zero"
        })

    def test_format_1_2_header_geometry_and_counts_are_exact(self) -> None:
        current = self.contract["binary_format"]["format_1_2"]
        self.assertEqual(current["version"], {"major": 1, "minor": 2})
        self.assertEqual(current["swift_type_family"], "V3")
        self.assertTrue(current["selected_by_schema_2_only"])
        self.assertTrue(current["version_dispatch_before_extension_decode"])
        self.assertEqual(current["plane_count"], 2)
        self.assertEqual(
            current["plane_order"],
            [{"id": 0, "name": "luma"}, {"id": 1, "name": "chroma"}],
        )

        occupied: set[int] = set()
        for field in current["header_extension"]:
            byte_range = set(range(field["offset"], field["offset"] + field["size"]))
            self.assertTrue(occupied.isdisjoint(byte_range))
            occupied.update(byte_range)
        self.assertEqual(occupied, {30, 31, *range(300, 320)})
        self.assertEqual(
            [(row["name"], row["offset"], row["size"]) for row in current["header_extension"]],
            [
                ("plane_count", 30, 2),
                ("route_spatial_policy_id", 300, 1),
                ("luma_anisotropy_mode_ordinal", 301, 1),
                ("chroma_anisotropy_mode_ordinal", 302, 1),
                ("luma_coordinate_policy", 303, 1),
                ("chroma_coordinate_policy", 304, 1),
                ("chroma_edge_confidence_encoding", 305, 1),
                ("reserved_tail", 306, 14),
            ],
        )
        policy_field = current["header_extension"][1]
        self.assertEqual(
            policy_field["admissibility"],
            "must be a member of compiler_semantics.admissible_policy_ids",
        )
        confidence_field = current["header_extension"][6]
        self.assertTrue(confidence_field["abi_marker_only"])
        self.assertFalse(confidence_field["stores_runtime_value"])

        for route in current["routes"]:
            phase_count = route["phase_count"]
            expected_count = 2 * phase_count * 4 * 256
            self.assertEqual(route["entry_count"], expected_count)
            indices = {
                plane * (phase_count * 4 * 256)
                + (((phase * 4) + context) * 256)
                + state
                for plane in range(2)
                for phase in range(phase_count)
                for context in range(4)
                for state in range(256)
            }
            self.assertEqual(indices, set(range(expected_count)))

    def test_policy_mode_coordinate_domains_and_joint_selection_are_bound(self) -> None:
        compiler = self.contract["compiler_semantics"]
        manifest = load_object(
            CALIBRATION_ROOT
            / "locks/spatial-policy-admissibility-manifest.json"
        )
        admissible = [
            row["policy_id"]
            for row in manifest["policy_records"]
            if row["g05_semantically_admissible"]
        ]
        self.assertEqual(compiler["admissible_policy_ids"], admissible)

        preregistration = load_object(
            CALIBRATION_ROOT
            / "contracts/spatial-semantics-preregistration-v2.json"
        )
        expected_modes = [
            {
                "anisotropy_strength_q12": mode["anisotropy_strength_q12"],
                "mode_id": mode["mode_id"],
                "mode_ordinal": mode["mode_ordinal"],
                "use_anisotropy": mode["use_anisotropy"],
            }
            for mode in preregistration["anisotropy_modes"]["modes"]
        ]
        self.assertEqual(compiler["mode_domain"], expected_modes)
        self.assertTrue(compiler["all_isotropic_route_plane_vector_forbidden"])
        self.assertEqual(
            compiler["selection_cardinality"],
            {
                "coordinate_policy_per_route_plane": 1,
                "mode_per_route_plane": 1,
                "plane_count": 2,
                "policy_id_per_route": 1,
                "route_count": 2,
            },
        )
        independent = compiler["independent_plane_compilation"]
        self.assertTrue(independent["existing_fixed_point_compatibility_invoked_per_plane"])
        self.assertTrue(independent["existing_fixed_point_ranking_invoked_per_plane"])
        self.assertFalse(independent["new_plane_specific_ranking_formula_authorized"])
        self.assertTrue(independent["route_policy_shared_by_luma_and_chroma"])

        joint = compiler["joint_vector_selection"]
        self.assertTrue(joint["coordinate_and_mode_choices_evaluated_jointly"])
        self.assertFalse(joint["marginal_coordinate_effect_authorizes_selection"])
        self.assertEqual(
            joint["selection_unit"],
            "complete_route_plane_coordinate_and_mode_vector",
        )
        self.assertEqual(
            compiler["selection_state"],
            {
                "default_configuration_selected": False,
                "execution_results_present": False,
                "selected_winner": None,
                "selection_performed": False,
            },
        )

    def test_plane_local_source_exact_confidence_and_temporal_boundaries(self) -> None:
        source_exact = self.contract["source_exact"]
        self.assertTrue(source_exact["format_1_2_plane_local"])
        self.assertIn("current plane coordinate policy", source_exact["format_1_2_predicate"])
        self.assertIn("both route coordinate policies", source_exact["format_1_1_predicate_frozen"])

        confidence = self.contract["runtime_confidence"]
        self.assertEqual(confidence["header_abi_marker"], {"offset": 305, "value": 1})
        self.assertFalse(confidence["lut_value_storage"])
        self.assertFalse(confidence["consumer_rule_authorized"])
        self.assertFalse(confidence["selection_use_authorized"])
        self.assertFalse(confidence["operator_use_authorized"])
        self.assertEqual(confidence["range"], [0, 1])
        self.assertIn("IEEE-754 binary64 bit pattern", confidence["exact_transport"])
        self.assertNotIn("confidence_value", set(all_keys(self.contract)))

        temporal = self.contract["temporal_contexts"]
        self.assertEqual(temporal["context_count"], 4)
        self.assertTrue(temporal["context_1_through_3_mirror_context_0_per_plane"])
        self.assertEqual(temporal["context_1_through_3_temporal_forced_spatial_flag_value"], 1)
        self.assertEqual(temporal["header_temporal_enabled_flag_value_through_g07"], 0)
        self.assertEqual(temporal["candidate_temporal_contribution_value_through_g07"], 0)
        self.assertEqual(temporal["parameter_temporal_mode_value_through_g07"], 0)
        self.assertFalse(temporal["temporal_pixels_authorized_through_g07"])

        post_g07 = self.contract["post_g07_temporal_boundary"]
        self.assertTrue(post_g07["spatial_format_1_2_complete_bytes_immutable"])
        self.assertTrue(post_g07["spatial_format_1_2_whole_file_sha256_immutable"])
        self.assertFalse(post_g07["p10_may_mutate_spatial_lut"])
        self.assertTrue(post_g07["p10_requires_separate_temporal_overlay"])
        self.assertTrue(post_g07["temporal_overlay_must_reference_exact_spatial_lut_sha256"])

    def test_authenticated_diagnostic_receipt_enforces_claim_boundary(self) -> None:
        receipt_binding = next(
            row
            for row in self.contract["input_bindings"]["repository"]
            if row["id"] == "coordinate_anisotropy_diagnostic_receipt"
        )
        receipt = load_object(ROOT / receipt_binding["path"])
        boundary = self.contract["diagnostic_evidence_boundary"]
        self.assertEqual(receipt["source_scope"]["source_status"], boundary["source_status"])
        self.assertEqual(receipt["source_scope"]["split"], boundary["source_split"])
        self.assertEqual(receipt["source_scope"]["selected_winner"], boundary["selected_winner"])
        self.assertEqual(
            receipt["claims"]["route_and_plane_coordinate_policy_effect_evidenced"],
            boundary["route_and_plane_coordinate_policy_effect_evidenced"],
        )
        self.assertEqual(
            receipt["claims"]["required_next_evidence"],
            boundary["required_next_evidence"],
        )
        self.assertFalse(
            receipt["claims"]["fixed_anisotropy_strength_q12_3072_authorized"]
        )
        self.assertFalse(receipt["claims"]["formal_gate_result_established"])
        self.assertFalse(receipt["claims"]["winner_selected"])
        self.assertFalse(
            receipt["claims"]["current_source_equivalence_established"]
        )
        self.assertFalse(boundary["fixed_anisotropy_default_authorized"])
        self.assertFalse(boundary["q12_3072_default_authorized"])
        self.assertFalse(boundary["g05_or_g06_gate_claim_authorized"])
        self.assertFalse(boundary["winner_claim_authorized"])
        self.assertFalse(boundary["current_source_equivalence_established"])
        source_manifest = receipt["current_source_comparison"]["native_source_manifest"]
        self.assertEqual(
            boundary["bound_source_manifest"],
            {
                "matching_current_source_file_count": source_manifest[
                    "matching_current_source_file_count"
                ],
                "mismatching_current_source_file_count": source_manifest[
                    "mismatching_current_source_file_count"
                ],
                "source_commit_binding_present": source_manifest[
                    "source_commit_binding_present"
                ],
                "source_file_count": source_manifest["source_file_count"],
            },
        )
        self.assertFalse(self.contract["data_access"]["live_p06_ledger_bound"])

    def test_strict_schema_rejects_layout_selection_and_scope_mutations(self) -> None:
        mutations = []
        moved_header = deepcopy(self.contract)
        moved_header["binary_format"]["format_1_2"]["header_extension"][0]["offset"] = 31
        mutations.append(moved_header)

        selected_default = deepcopy(self.contract)
        selected_default["compiler_semantics"]["selection_state"][
            "default_configuration_selected"
        ] = True
        mutations.append(selected_default)

        confidence_consumer = deepcopy(self.contract)
        confidence_consumer["runtime_confidence"]["consumer_rule_authorized"] = True
        mutations.append(confidence_consumer)

        temporal_mutation = deepcopy(self.contract)
        temporal_mutation["post_g07_temporal_boundary"]["p10_may_mutate_spatial_lut"] = True
        mutations.append(temporal_mutation)

        gate_claim = deepcopy(self.contract)
        gate_claim["diagnostic_evidence_boundary"]["g05_or_g06_gate_claim_authorized"] = True
        mutations.append(gate_claim)

        extra = deepcopy(self.contract)
        extra["unregistered_extension"] = True
        mutations.append(extra)

        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertTrue(list(self.validator.iter_errors(mutation)))

    def test_calibration_readme_binds_the_preregistration(self) -> None:
        text = README_PATH.read_text(encoding="utf-8")
        self.assertIn("contracts/plane-aware-lut-preregistration-v1.json", text)
        self.assertIn("schemas/plane-aware-lut-preregistration-v1.schema.json", text)
        self.assertIn("separately preregistered temporal overlay", text)
        self.assertIn("selects no policy, mode, coordinate vector, or anisotropy default", text)


if __name__ == "__main__":
    unittest.main()
