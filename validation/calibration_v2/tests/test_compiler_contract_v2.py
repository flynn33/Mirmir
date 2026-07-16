from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import unittest

from jsonschema import Draft202012Validator

from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
CONTRACT_PATH = CALIBRATION_ROOT / "contracts/compiler-contract-v2.json"
SCHEMA_PATH = CALIBRATION_ROOT / "schemas/compiler-contract-v2.schema.json"
COMPILER_V1_PATH = CALIBRATION_ROOT / "contracts/compiler-contract-v1.json"
PLANE_PATH = (
    CALIBRATION_ROOT / "contracts/plane-aware-lut-preregistration-v1.json"
)
INPUT_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/locked-compiler-input-v2.schema.json"
)
INPUT_TEMPLATE_PATH = (
    CALIBRATION_ROOT / "contracts/locked-compiler-input-v2.template.json"
)
IDENTITY_PATH = (
    CALIBRATION_ROOT
    / "contracts/shared-bank-configuration-identity-v2.json"
)
NORMALIZATION_PATH = (
    CALIBRATION_ROOT
    / "contracts/instruction-conflict-normalization-v1.json"
)
INSTRUCTION_ROOT_ENV = os.environ.get("MIRMIR_INSTRUCTION_PACKAGE_ROOT")
INSTRUCTION_ROOT = (
    Path(INSTRUCTION_ROOT_ENV)
    if INSTRUCTION_ROOT_ENV is not None
    else None
)

EXPECTED_CONTRACT_SELF_SHA256 = (
    "797d6fda359a6bfaca9487a31b0078a5eba8e41fdb6fd0985390e20c25df8237"
)
EXPECTED_CONTRACT_FILE_SHA256 = (
    "8c2f532ff126fd5517040a05c9f8669d2a83d1d7220f61fed5933d5fa470470a"
)
EXPECTED_SCHEMA_FILE_SHA256 = (
    "5f7a49e1f585e4f0e108e733ae3c6f28b47869b3cc2909419688714e76f57897"
)
EXPECTED_AUTHORITY_BINDING_IDS = (
    "compiler_contract_v1",
    "compiler_contract_v1_schema",
    "locked_compiler_input_v1_schema",
    "locked_compiler_input_v1_template",
    "locked_compiler_input_v1_fixture",
    "lut_binary_contract_v1",
    "lut_binary_contract_v1_schema",
    "plane_aware_lut_preregistration",
    "plane_aware_lut_preregistration_schema",
    "locked_compiler_input_v2_schema",
    "locked_compiler_input_v2_template",
    "calibration_plan_v2",
    "calibration_plan_v2_schema",
    "calibration_plan_v2_reference",
    "shared_bank_configuration_identity_v2",
    "shared_bank_configuration_identity_v2_schema",
    "spatial_semantics_preregistration_v2",
    "spatial_semantics_preregistration_v2_schema",
    "spatial_policy_admissibility_manifest",
    "spatial_policy_admissibility_manifest_schema",
    "instruction_conflict_normalization_v1",
    "instruction_conflict_normalization_v1_schema",
)
EXPECTED_V1_FILE_HASHES = {
    "validation/calibration_v2/contracts/compiler-contract-v1.json": (
        "3e55885471aacd3e1468ab6d8d967d8335d5d322c77859b94a5321391cabf798"
    ),
    "validation/calibration_v2/schemas/compiler-contract-v1.schema.json": (
        "46e55413adde5f0195a20c9a1ddb73d33684cd36ccae59139157f2165f9fe379"
    ),
    "validation/calibration_v2/schemas/locked-compiler-input-v1.schema.json": (
        "d54b4051fb360d9d04fcf85a5c3ab3d73e13144cc14985aec387e591aa1b2444"
    ),
    "validation/calibration_v2/contracts/locked-compiler-input-v1.template.json": (
        "7d753b7a2043114cc5ed04115d69954f7c44fc4ba5b8eb75b2942d289554dd14"
    ),
    "validation/calibration_v2/fixtures/locked-compiler-input-shared-v1.json": (
        "ba5438b47365c92175a6601aa757138648251004f0e4ddeba13969fdaa0428bb"
    ),
    "validation/calibration_v2/contracts/lut-binary-contract-v1.json": (
        "8deddf58ba06a4eece17c34afc37ac464b2e618679c6217904dc67fa4439a56d"
    ),
    "validation/calibration_v2/schemas/lut-binary-contract-v1.schema.json": (
        "5c213f302916923eea0c3789bf10b65cb7cb34a436aa7ab351512a2eaf2cf348"
    ),
}
EXPECTED_INSTRUCTION_BINDINGS = {
    "package_manifest.json": (
        "bac31029e2aa0e9ef89cb25f36c9cfd9ac5ce0920e546bd3dea0edea06520afd",
        14059,
    ),
    "SHA256SUMS.txt": (
        "176580ebabf5be861a1008dd7180bc1e9ba2c9602864b39af1a3e959aa159651",
        8327,
    ),
    "instructions/00_MASTER_EXECUTION_DIRECTIVE.md": (
        "1a1f75c785f91b764e55f66bdd7880a237b1ae710351474d9dc8a7a4a6018800",
        4469,
    ),
    "config/branch_compiler_spec.json": (
        "fc5ab40aa5e83b9780c9875f309fe02f74541e5b514d443c6fefbc1ee8704626",
        6801,
    ),
    "instructions/04_BRANCH_COMPILER_AND_BITWISE_RUNTIME.md": (
        "f5e4458ae627107172003b397dacefa4b0a7b8bea5468c0d87ab5130f3a93677",
        3986,
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


def load_object(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha256(value: object) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def all_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_keys(child)


class CompilerContractV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = load_object(CONTRACT_PATH)
        cls.schema = load_object(SCHEMA_PATH)
        cls.compiler_v1 = load_object(COMPILER_V1_PATH)
        cls.plane = load_object(PLANE_PATH)
        cls.input_schema = load_object(INPUT_SCHEMA_PATH)
        cls.input_template = load_object(INPUT_TEMPLATE_PATH)
        cls.identity = load_object(IDENTITY_PATH)
        cls.normalization = load_object(NORMALIZATION_PATH)
        cls.validator = Draft202012Validator(cls.schema)

    def test_contract_schema_canonical_self_hash_and_file_hashes_are_exact(
        self,
    ) -> None:
        Draft202012Validator.check_schema(self.schema)
        self.assertEqual(list(self.validator.iter_errors(self.contract)), [])
        self.assertEqual(
            CONTRACT_PATH.read_bytes(),
            canonical_json_bytes(self.contract) + b"\n",
        )
        self.assertEqual(
            SCHEMA_PATH.read_bytes(),
            canonical_json_bytes(self.schema) + b"\n",
        )
        self.assertEqual(
            self.contract["artifact_sha256"],
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(
            manifest_sha256(self.contract, field="artifact_sha256"),
            EXPECTED_CONTRACT_SELF_SHA256,
        )
        self.assertEqual(file_sha256(CONTRACT_PATH), EXPECTED_CONTRACT_FILE_SHA256)
        self.assertEqual(file_sha256(SCHEMA_PATH), EXPECTED_SCHEMA_FILE_SHA256)

        self.assertFalse(self.schema["additionalProperties"])
        self.assertEqual(set(self.schema["required"]), set(self.contract))
        self.assertEqual(set(self.schema["properties"]), set(self.contract))
        for key, value in self.contract.items():
            if key == "artifact_sha256":
                self.assertEqual(
                    self.schema["properties"][key]["allOf"][1],
                    {"const": value},
                )
            else:
                self.assertEqual(
                    self.schema["properties"][key],
                    {"const": value},
                )

    def test_every_repository_authority_binding_is_exact_and_current(self) -> None:
        bindings = self.contract["authority_bindings"]
        self.assertEqual(
            tuple(binding["id"] for binding in bindings),
            EXPECTED_AUTHORITY_BINDING_IDS,
        )
        self.assertEqual(len(bindings), len({binding["id"] for binding in bindings}))
        for binding in bindings:
            with self.subTest(binding=binding["id"]):
                relative = PurePosixPath(binding["path"])
                self.assertFalse(relative.is_absolute())
                self.assertNotIn("..", relative.parts)
                path = ROOT.joinpath(*relative.parts)
                payload = path.read_bytes()
                self.assertEqual(len(payload), binding["size_bytes"])
                self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])
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

    def test_instruction_bindings_and_normalized_oracle_roles_are_exact(self) -> None:
        instruction = self.contract["instruction_bindings"]
        self.assertEqual(instruction["package_id"], "mirmr-iA.1.0.1.0")
        self.assertEqual(
            instruction["package_manifest"]["sha256"],
            self.normalization["source_package_manifest_sha256"],
        )
        expected_paths = (
            "instructions/00_MASTER_EXECUTION_DIRECTIVE.md",
            "config/branch_compiler_spec.json",
            "instructions/04_BRANCH_COMPILER_AND_BITWISE_RUNTIME.md",
            "instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md",
            "instructions/20_COMPONENT_IMPLEMENTATION_CONTRACTS.md",
        )
        self.assertEqual(
            tuple(record["path"] for record in instruction["files"]),
            expected_paths,
        )

        package_paths = (
            instruction["package_manifest"],
            instruction["checksum_index"],
            *instruction["files"],
        )
        self.assertEqual(
            {record["path"] for record in package_paths},
            set(EXPECTED_INSTRUCTION_BINDINGS),
        )
        for record in package_paths:
            with self.subTest(instruction_binding=record["path"]):
                expected_sha256, expected_size = EXPECTED_INSTRUCTION_BINDINGS[
                    record["path"]
                ]
                self.assertEqual(record["sha256"], expected_sha256)
                self.assertEqual(record["size_bytes"], expected_size)

        if INSTRUCTION_ROOT is not None and INSTRUCTION_ROOT.is_dir():
            for record in package_paths:
                with self.subTest(instruction_path=record["path"]):
                    payload = (INSTRUCTION_ROOT / record["path"]).read_bytes()
                    self.assertEqual(len(payload), record["size_bytes"])
                    self.assertEqual(
                        hashlib.sha256(payload).hexdigest(),
                        record["sha256"],
                    )
            branch = load_object(
                INSTRUCTION_ROOT / "config/branch_compiler_spec.json"
            )
            self.assertEqual(
                self.contract["instruction_compiler_id"],
                branch["compiler_id"],
            )
            self.assertEqual(
                self.contract["instruction_compiler_spec_schema_version"],
                branch["schema_version"],
            )
            self.assertEqual(
                self.contract["instruction_conformance"][
                    "branch_compiler_spec_compile_algorithm"
                ],
                branch["compile_algorithm"],
            )

        normalized = next(
            resolution
            for resolution in self.normalization["resolutions"]
            if resolution["id"] == "p11_macos_xcode_targets_and_swift_oracle"
        )["decision"]
        conformance = self.contract["instruction_conformance"]
        self.assertEqual(
            conformance["independent_conformance_compiler_language"],
            normalized["reference_oracle_language"],
        )
        self.assertEqual(conformance["python_role"], normalized["python_role"])
        self.assertEqual(len(conformance["compile_steps"]), 15)
        self.assertIn("exactly 81", conformance["compile_steps"][5])
        self.assertIn("format-1.2", conformance["compile_steps"][-1])

    def test_v1_inheritance_and_replacement_partition_is_exact(self) -> None:
        inheritance = self.contract["v1_inheritance"]
        inherited = tuple(path.removeprefix("/") for path in inheritance[
            "exact_inherited_field_paths"
        ])
        replaced = tuple(path.removeprefix("/") for path in inheritance[
            "replaced_field_paths"
        ])
        metadata = tuple(path.removeprefix("/") for path in inheritance[
            "version_metadata_field_paths"
        ])
        self.assertEqual(
            inherited,
            (
                "canonical_branch",
                "temporal_disabled_semantics",
                "base_descriptor",
                "descriptor_application",
                "semantic_steps",
                "hard_compatibility",
                "penalty",
                "mass_and_ranking",
                "parameter_table",
                "failure_taxonomy",
                "runtime_invariants",
            ),
        )
        self.assertEqual(
            replaced,
            ("index_domain", "source_aligned_exact_semantics"),
        )
        self.assertEqual(metadata, ("schema_version", "contract_id", "status"))
        self.assertEqual(
            set(inherited) | set(replaced) | set(metadata),
            set(self.compiler_v1),
        )
        self.assertEqual(
            len(inherited) + len(replaced) + len(metadata),
            len(self.compiler_v1),
        )
        self.assertTrue(inheritance["partition_is_exact_and_complete"])
        self.assertEqual(
            canonical_sha256({name: self.compiler_v1[name] for name in inherited}),
            inheritance["exact_inherited_values_sha256"],
        )
        self.assertEqual(
            inheritance["replacement_paths"],
            {
                "/index_domain": "/plane_aware_extension/index_domain",
                "/source_aligned_exact_semantics": (
                    "/plane_aware_extension/source_aligned_exact_semantics"
                ),
            },
        )
        self.assertFalse(inheritance["v1_behavior_mutation_authorized"])

        binding_ids = set(inheritance["v1_artifact_binding_ids"])
        for relative, expected in EXPECTED_V1_FILE_HASHES.items():
            with self.subTest(v1_file=relative):
                self.assertEqual(file_sha256(ROOT / relative), expected)
                matching = [
                    binding
                    for binding in self.contract["authority_bindings"]
                    if binding["path"] == relative
                ]
                self.assertEqual(len(matching), 1)
                self.assertIn(matching[0]["id"], binding_ids)

    def test_plane_major_index_counts_and_leaf_visits_are_exact(self) -> None:
        index = self.contract["plane_aware_extension"]["index_domain"]
        self.assertEqual(
            index["iteration_order"],
            ["route", "plane", "phase", "context", "valid_state"],
        )
        self.assertEqual(index["planes"], [{"id": 0, "name": "luma"}, {"id": 1, "name": "chroma"}])
        self.assertEqual(index["plane_count"], 2)
        self.assertEqual(index["context_count"], 4)
        self.assertEqual(index["valid_state_count"], 256)
        self.assertEqual(
            index["logical_index"],
            self.plane["binary_format"]["format_1_2"]["logical_index_formula"],
        )

        for route in index["routes"]:
            phase_count = route["phase_count"]
            expected_count = 2 * phase_count * 4 * 256
            self.assertEqual(route["entry_count"], expected_count)
            self.assertEqual(route["canonical_leaf_count_per_cell"], 81)
            self.assertEqual(
                route["offline_leaf_evaluation_count"],
                expected_count * 81,
            )
            observed = {
                plane * (phase_count * 4 * 256)
                + (((phase * 4) + context) * 256)
                + state
                for plane in range(2)
                for phase in range(phase_count)
                for context in range(4)
                for state in range(256)
            }
            self.assertEqual(observed, set(range(expected_count)))

    def test_plane_selection_modes_and_source_exactness_are_closed(self) -> None:
        extension = self.contract["plane_aware_extension"]
        selection = extension["selection_semantics"]
        authority = self.plane["compiler_semantics"]
        self.assertEqual(
            selection["route_spatial_policy_ids"],
            authority["admissible_policy_ids"],
        )
        self.assertEqual(selection["mode_domain"], authority["mode_domain"])
        self.assertEqual(
            selection["coordinate_policy_domain"],
            authority["coordinate_policy_domain"],
        )
        self.assertEqual(
            selection["complete_vector_order"],
            [
                "direct_2x_luma",
                "direct_2x_chroma",
                "direct_3_over_2_luma",
                "direct_3_over_2_chroma",
            ],
        )
        self.assertTrue(selection["route_spatial_policy_shared_by_luma_and_chroma"])
        self.assertTrue(selection["mode_ordinal_is_sole_anisotropy_authority"])
        self.assertFalse(selection["global_anisotropy_strength_compiler_input_authorized"])
        self.assertTrue(selection["all_isotropic_route_plane_vector_forbidden"])
        self.assertFalse(selection["new_plane_specific_ranking_formula_authorized"])
        self.assertFalse(selection["selection_performed"])
        self.assertIsNone(selection["selected_winner"])
        self.assertFalse(selection["default_configuration_selected"])

        zero_strength_modes = [
            mode for mode in selection["mode_domain"]
            if mode["anisotropy_strength_q12"] == 0
        ]
        self.assertEqual(
            [(mode["mode_ordinal"], mode["use_anisotropy"]) for mode in zero_strength_modes],
            [(0, False), (1, True)],
        )

        source = extension["source_aligned_exact_semantics"]
        self.assertEqual(
            source["predicate"],
            self.plane["source_exact"]["format_1_2_predicate"],
        )
        self.assertTrue(source["format_1_2_plane_local"])
        self.assertFalse(source["other_plane_policy_affects_current_plane_exactness"])
        for current_plane_source_aligned in (False, True):
            for other_plane_source_aligned in (False, True):
                for phase_zero in (False, True):
                    expected = current_plane_source_aligned and phase_zero
                    observed = current_plane_source_aligned and phase_zero
                    with self.subTest(
                        current=current_plane_source_aligned,
                        other=other_plane_source_aligned,
                        phase_zero=phase_zero,
                    ):
                        self.assertEqual(observed, expected)

    def test_compiler_input_projection_is_exact_and_not_shared_bank_identity(
        self,
    ) -> None:
        boundary = self.contract["compiler_input_boundary"]
        projection = self.identity["compiler_projection_boundary"]
        self.assertEqual(boundary["schema_version"], "2.0.0")
        self.assertEqual(boundary["root_fields"], self.input_schema["required"])
        self.assertEqual(
            boundary["hash_binding_fields"],
            self.input_schema["properties"]["hash_bindings"]["required"],
        )
        for key in (
            "compiler_candidate_field_count",
            "compiler_candidate_fields",
            "shared_bank_candidate_field_count",
            "shared_bank_and_compiler_candidate_fields",
            "compiler_candidate_minus_shared_bank_candidate_fields",
            "shared_bank_candidate_minus_compiler_candidate_fields",
        ):
            self.assertEqual(boundary[key], projection[key])
        self.assertEqual(
            boundary["shared_bank_candidate_fields"],
            self.identity["identity"]["ordered_fields"],
        )
        self.assertEqual(boundary["compiler_candidate_field_count"], 34)
        self.assertEqual(boundary["shared_bank_candidate_field_count"], 23)
        self.assertFalse(boundary["compiler_input_is_shared_bank_identity"])
        self.assertFalse(boundary["concrete_locked_input_bound_by_this_preregistration"])

        compiler_fields = set(boundary["compiler_candidate_fields"])
        shared_fields = set(boundary["shared_bank_candidate_fields"])
        self.assertEqual(
            compiler_fields & shared_fields,
            set(boundary["shared_bank_and_compiler_candidate_fields"]),
        )
        self.assertEqual(
            compiler_fields - shared_fields,
            set(boundary["compiler_candidate_minus_shared_bank_candidate_fields"]),
        )
        self.assertEqual(
            shared_fields - compiler_fields,
            set(boundary["shared_bank_candidate_minus_compiler_candidate_fields"]),
        )

        properties = self.input_schema["properties"]
        route_schema = self.input_schema["$defs"]["routeSelection"]
        mapping = {
            **{
                f"{route}_{field}": (
                    route_schema,
                    self.input_template["routes"][route],
                    field,
                )
                for route in ("direct_2x", "direct_3_over_2")
                for field in (
                    "route_spatial_policy_id",
                    "luma_anisotropy_mode_ordinal",
                    "chroma_anisotropy_mode_ordinal",
                    "luma_coordinate_policy",
                    "chroma_coordinate_policy",
                    "analysis_grid_source_step",
                )
            },
            "boundary_mode": (
                self.input_schema,
                self.input_template,
                "boundary_mode",
            ),
            **{
                field: (
                    properties["operator_parameters"],
                    self.input_template["operator_parameters"],
                    field,
                )
                for field in (
                    "minimum_anisotropic_magnitude_unorm15",
                    "minimum_anisotropic_coherence_unorm15",
                    "detail_gain_q12",
                    "relaxed_limiter_alpha_q12",
                    "risk_detail_suppression_unorm15",
                    "low_pass_radius_q8_8",
                )
            },
            **{
                field: (
                    properties["semantic_steps"],
                    self.input_template["semantic_steps"],
                    field,
                )
                for field in (
                    "support_radius_step_q8_8",
                    "detail_gain_step_q12",
                    "regularization_step_q12",
                )
            },
            **{
                field: (
                    properties["compiler_policy"],
                    self.input_template["compiler_policy"],
                    field,
                )
                for field in (
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
        self.assertEqual(set(mapping), compiler_fields)
        for top_level in (
            "boundary_mode",
            "operator_parameters",
            "semantic_steps",
            "compiler_policy",
            "routes",
        ):
            self.assertIn(top_level, self.input_schema["required"])
        for candidate, (schema_node, template_node, property_name) in mapping.items():
            with self.subTest(candidate=candidate):
                self.assertIn(property_name, schema_node["properties"])
                self.assertIn(property_name, schema_node["required"])
                self.assertIn(property_name, template_node)

        self.assertNotIn(
            "anisotropy_strength_q12",
            set(all_keys(self.input_schema)),
        )
        for prohibited in boundary["prohibited_fields"]:
            self.assertNotIn(prohibited, set(all_keys(self.input_schema)))

    def test_binary_temporal_and_confidence_boundaries_match_preregistration(
        self,
    ) -> None:
        binary = self.contract["binary_format_boundary"]
        expected = self.plane["binary_format"]["format_1_2"]
        self.assertEqual(binary["format_1_2"], expected)
        self.assertEqual(binary["common_layout"], self.plane["binary_format"]["common_layout"])
        self.assertTrue(binary["format_1_1_behavior_and_bytes_frozen"])
        self.assertFalse(binary["compiler_contract_digest_stored_in_binary_header"])
        self.assertTrue(binary["external_manifest_contract_binding_required"])

        occupied: set[int] = set()
        for field in expected["header_extension"]:
            byte_range = set(range(field["offset"], field["offset"] + field["size"]))
            self.assertTrue(occupied.isdisjoint(byte_range))
            occupied.update(byte_range)
        self.assertEqual(occupied, {30, 31, *range(300, 320)})
        self.assertEqual(expected["version"], {"major": 1, "minor": 2})
        self.assertEqual(expected["swift_type_family"], "V3")
        self.assertTrue(expected["version_dispatch_before_extension_decode"])
        self.assertIn("plane-major logical_index", expected["entry_crc_change"])

        extension = self.contract["plane_aware_extension"]
        self.assertEqual(
            extension["temporal_semantics_through_g07"],
            self.plane["temporal_contexts"],
        )
        self.assertEqual(
            extension["post_g07_temporal_boundary"],
            self.plane["post_g07_temporal_boundary"],
        )
        confidence = extension["runtime_confidence"]
        self.assertEqual(confidence, self.plane["runtime_confidence"])
        self.assertEqual(confidence["header_abi_marker"], {"offset": 305, "value": 1})
        self.assertFalse(confidence["lut_value_storage"])
        self.assertFalse(confidence["selection_use_authorized"])
        self.assertFalse(confidence["operator_use_authorized"])
        self.assertFalse(confidence["consumer_rule_authorized"])

    def test_downstream_hash_topology_and_no_execution_boundary_are_closed(
        self,
    ) -> None:
        topology = self.contract["downstream_hash_topology"]
        self.assertEqual(
            topology["direction"],
            [
                "immutable_authorities",
                "compiler_contract_v2",
                "implementation_source_manifests_and_concrete_locked_input",
                "compiled_route_lut_bytes",
                "parity_runtime_and_release_manifests",
            ],
        )
        self.assertEqual(topology["contract_self_hash_omits_only"], "/artifact_sha256")
        self.assertTrue(topology["cycle_free"])
        self.assertFalse(topology["upstream_artifact_may_bind_downstream_result"])
        self.assertTrue(topology["compiler_inputs_sha256_must_not_be_repurposed"])
        self.assertTrue(
            topology[
                "external_manifest_required_because_header_has_only_six_legacy_input_digests"
            ]
        )
        self.assertEqual(
            set(topology["contract_must_not_bind"])
            & set(topology["downstream_required_bindings"]),
            {
                "compiler_contract_v2_file_sha256",
                "compiler_contract_v2_schema_file_sha256",
            },
        )
        authority_ids = {binding["id"] for binding in self.contract["authority_bindings"]}
        self.assertNotIn("compiler_contract_v2", authority_ids)
        self.assertFalse(
            authority_ids
            & {
                "concrete_locked_compiler_input",
                "production_compiler_source_manifest",
                "independent_compiler_source_manifest",
                "compiled_route_lut",
                "native_parity_result",
                "release_result",
            }
        )

        self.assertTrue(self.contract["execution_boundary"]["contract_derivation_implemented"])
        self.assertTrue(
            all(
                value is False
                for key, value in self.contract["execution_boundary"].items()
                if key != "contract_derivation_implemented"
            )
        )
        self.assertTrue(all(value is False for value in self.contract["data_access"].values()))
        self.assertEqual(self.contract["status"], "preregistered_not_executed")

    def test_full_const_schema_rejects_authority_semantic_and_scope_mutations(
        self,
    ) -> None:
        mutations: list[dict[str, object]] = []

        binding = deepcopy(self.contract)
        binding["authority_bindings"][0]["sha256"] = "1" * 64
        mutations.append(binding)

        inherited = deepcopy(self.contract)
        inherited["v1_inheritance"]["exact_inherited_field_paths"].reverse()
        mutations.append(inherited)

        index = deepcopy(self.contract)
        index["plane_aware_extension"]["index_domain"]["routes"][0]["entry_count"] -= 1
        mutations.append(index)

        selected = deepcopy(self.contract)
        selected["plane_aware_extension"]["selection_semantics"]["selected_winner"] = "candidate"
        mutations.append(selected)

        source = deepcopy(self.contract)
        source["plane_aware_extension"]["source_aligned_exact_semantics"][
            "other_plane_policy_affects_current_plane_exactness"
        ] = True
        mutations.append(source)

        header = deepcopy(self.contract)
        header["binary_format_boundary"]["format_1_2"]["header_extension"][0]["offset"] = 31
        mutations.append(header)

        identity = deepcopy(self.contract)
        identity["compiler_input_boundary"]["compiler_input_is_shared_bank_identity"] = True
        mutations.append(identity)

        topology = deepcopy(self.contract)
        topology["downstream_hash_topology"]["cycle_free"] = False
        mutations.append(topology)

        execution = deepcopy(self.contract)
        execution["execution_boundary"]["compiler_v2_implementation_claimed"] = True
        mutations.append(execution)

        holdout = deepcopy(self.contract)
        holdout["data_access"]["holdout_accessed"] = True
        mutations.append(holdout)

        extra = deepcopy(self.contract)
        extra["unregistered_extension"] = True
        mutations.append(extra)

        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.assertTrue(list(self.validator.iter_errors(mutation)))


if __name__ == "__main__":
    unittest.main()
