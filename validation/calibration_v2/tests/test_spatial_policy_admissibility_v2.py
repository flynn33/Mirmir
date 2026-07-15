from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from jsonschema import Draft202012Validator

from validation.calibration_v2.reference.spatial_policy_admissibility_v2 import (
    SpatialPolicyContractError,
    build_spatial_policy_admissibility_manifest,
    decode_policy_id,
    derive_policy_records,
    encode_policy_id,
    evaluate_postfix,
    load_and_validate_spatial_semantics_preregistration,
    validate_spatial_policy_admissibility_manifest,
    validate_spatial_policy_admissibility_manifest_file,
)
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
)


ROOT = Path(__file__).resolve().parents[3]
CONTRACT_PATH = (
    ROOT
    / "validation/calibration_v2/contracts/"
    "spatial-semantics-preregistration-v2.json"
)
CONTRACT_SCHEMA_PATH = (
    ROOT
    / "validation/calibration_v2/schemas/"
    "spatial-semantics-preregistration-v2.schema.json"
)
MANIFEST_PATH = (
    ROOT
    / "validation/calibration_v2/locks/"
    "spatial-policy-admissibility-manifest.json"
)
MANIFEST_SCHEMA_PATH = (
    ROOT
    / "validation/calibration_v2/schemas/"
    "spatial-policy-admissibility-manifest-v2.schema.json"
)
CLI_PATH = (
    ROOT
    / "validation/calibration_v2/tools/"
    "build_spatial_policy_admissibility_v2.py"
)
EXPECTED_ADMISSIBLE_IDS = [*range(8), *range(16, 24)]
EXPECTED_MISSING = {
    **{policy_id: [6, 7, 14, 15] for policy_id in range(8, 16)},
    **{policy_id: [6, 7, 14, 15] for policy_id in range(24, 32)},
    **{policy_id: [4, 6, 12, 14] for policy_id in range(32, 40)},
    **{
        policy_id: [4, 6, 7, 12, 14, 15]
        for policy_id in range(40, 48)
    },
}


def load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise AssertionError(f"expected a JSON object: {path}")
    return value


def all_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from all_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_keys(child)


class SpatialPolicyAdmissibilityV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = load_json(CONTRACT_PATH)
        cls.contract_schema = load_json(CONTRACT_SCHEMA_PATH)
        cls.manifest = load_json(MANIFEST_PATH)
        cls.manifest_schema = load_json(MANIFEST_SCHEMA_PATH)
        cls.records = derive_policy_records(cls.contract)

    def test_schemas_and_checked_in_documents_are_canonical(self) -> None:
        for schema_path, schema in (
            (CONTRACT_SCHEMA_PATH, self.contract_schema),
            (MANIFEST_SCHEMA_PATH, self.manifest_schema),
        ):
            with self.subTest(path=schema_path):
                Draft202012Validator.check_schema(schema)
                self.assertEqual(
                    schema_path.read_bytes(),
                    canonical_json_bytes(schema) + b"\n",
                )
        for document_path, document in (
            (CONTRACT_PATH, self.contract),
            (MANIFEST_PATH, self.manifest),
        ):
            with self.subTest(path=document_path):
                self.assertEqual(
                    document_path.read_bytes(),
                    canonical_json_bytes(document) + b"\n",
                )

    def test_contract_schema_self_hash_and_nonselection_state(self) -> None:
        self.assertEqual(
            load_and_validate_spatial_semantics_preregistration(ROOT),
            self.contract,
        )
        validator = Draft202012Validator(self.contract_schema)
        self.assertEqual(list(validator.iter_errors(self.contract)), [])
        self.assertEqual(
            self.contract["artifact_sha256"],
            manifest_sha256(self.contract, "artifact_sha256"),
        )
        self.assertEqual(
            self.contract["selection_state"],
            {
                "development_metrics_present": False,
                "execution_results_present": False,
                "selected_winner": None,
                "selection_performed": False,
            },
        )
        self.assertEqual(
            self.contract["data_access"],
            {
                "holdout_accessed": False,
                "media_payloads_accessed": False,
                "validation_accessed": False,
            },
        )
        self.assertEqual(
            self.contract["policy_id_encoding"][
                "legacy_compatibility_anchor_policy_id"
            ],
            0,
        )
        self.assertNotIn("admissible_policy_ids", set(all_keys(self.contract)))

    def test_postfix_programs_match_direct_boolean_equations(self) -> None:
        programs = self.contract["semantic_programs"]
        for state in range(256):
            bits = {
                f"b{index + 1}": (state >> (7 - index)) & 1
                for index in range(8)
            }
            for two_h_ge_n in (0, 1):
                for two_v_ge_n in (0, 1):
                    variables = {
                        **bits,
                        "A": bits["b8"],
                        "C": bits["b4"],
                        "E": bits["b3"],
                        "R": bits["b6"],
                        "T": bits["b5"],
                        "two_h_ge_n": two_h_ge_n,
                        "two_v_ge_n": two_v_ge_n,
                    }
                    variables["O"] = bits["b1"] ^ bits["b2"]
                    variables["P"] = two_h_ge_n ^ two_v_ge_n
                    direct = {
                        "O": variables["O"],
                        "P": variables["P"],
                        "K0": variables["T"]
                        ^ (variables["E"] & variables["O"])
                        ^ variables["P"],
                        "K1": variables["T"]
                        ^ (variables["E"] & variables["O"]),
                        "K2": variables["T"]
                        | (variables["E"] & variables["O"]),
                        "S0": variables["E"] & variables["C"],
                        "S1": variables["E"]
                        & variables["C"]
                        & (1 - variables["R"]),
                        "S2": variables["E"]
                        & variables["C"]
                        & (1 - variables["T"]),
                        "S3": variables["E"]
                        & variables["C"]
                        & (1 - variables["R"])
                        & (1 - variables["T"]),
                        "D0": variables["E"]
                        & variables["T"]
                        & (1 - variables["R"]),
                        "D1": variables["T"] & (1 - variables["R"]),
                        "L0": variables["A"] & (1 - variables["R"]),
                        "L1": variables["A"],
                    }
                    for group in ("derived", "kernel", "support", "detail", "limiter"):
                        for rule_id, tokens in programs[group].items():
                            with self.subTest(
                                state=state,
                                phase=(two_h_ge_n, two_v_ge_n),
                                rule=rule_id,
                            ):
                                self.assertEqual(
                                    evaluate_postfix(tokens, variables),
                                    direct[rule_id],
                                )

        invalid = (
            ([], {}),
            (["unknown"], {}),
            (["not"], {}),
            (["1", "1"], {}),
            (["value"], {"value": 2}),
        )
        for tokens, variables in invalid:
            with self.subTest(tokens=tokens, variables=variables):
                with self.assertRaises(SpatialPolicyContractError):
                    evaluate_postfix(tokens, variables)

    def test_policy_encoding_is_bijective_and_range_checked(self) -> None:
        decoded = []
        for policy_id in range(48):
            ordinals = decode_policy_id(policy_id)
            decoded.append(ordinals)
            self.assertEqual(encode_policy_id(*ordinals), policy_id)
        self.assertEqual(len(set(decoded)), 48)
        for policy_id in (-1, 48, True):
            with self.subTest(policy_id=policy_id):
                with self.assertRaises(SpatialPolicyContractError):
                    decode_policy_id(policy_id)
        for ordinals in ((3, 0, 0, 0), (0, 4, 0, 0), (0, 0, 2, 0), (0, 0, 0, 2)):
            with self.subTest(ordinals=ordinals):
                with self.assertRaises(SpatialPolicyContractError):
                    encode_policy_id(*ordinals)

    def test_route_local_coverage_and_missing_groups_are_exact(self) -> None:
        self.assertEqual(len(self.records), 48)
        self.assertEqual(
            [route["state_phase_context_count"] for route in self.contract["route_domain"]],
            [4096, 9216],
        )
        admissible = [
            record["policy_id"]
            for record in self.records
            if record["g05_semantically_admissible"]
        ]
        self.assertEqual(admissible, EXPECTED_ADMISSIBLE_IDS)
        for record in self.records:
            policy_id = record["policy_id"]
            self.assertEqual(
                [route["route"] for route in record["routes"]],
                ["direct_2x", "direct_3_over_2"],
            )
            self.assertEqual(
                [route["state_phase_row_count"] for route in record["routes"]],
                [1024, 2304],
            )
            expected_missing = EXPECTED_MISSING.get(policy_id, [])
            for route in record["routes"]:
                self.assertEqual(route["missing_descriptor_ids"], expected_missing)
                self.assertEqual(route["descriptor_complete"], not expected_missing)
                self.assertEqual(
                    sorted(
                        route["descriptor_ids"] + route["missing_descriptor_ids"]
                    ),
                    list(range(16)),
                )

    def test_mode_and_structural_cardinalities_are_exact(self) -> None:
        modes = self.contract["anisotropy_modes"]
        self.assertEqual(
            [mode["mode_ordinal"] for mode in modes["modes"]],
            list(range(6)),
        )
        self.assertEqual(modes["raw_mode_vector_count"], 6**4)
        self.assertEqual(modes["excluded_mode_vector_count"], 1)
        self.assertEqual(modes["admissible_mode_vector_count"], (6**4) - 1)
        self.assertEqual(
            modes["excluded_mode_vector"],
            ["q12_0_isotropic_v2"] * 4,
        )
        self.assertNotEqual(
            modes["modes"][0]["mode_id"],
            modes["modes"][1]["mode_id"],
        )
        cardinality = self.contract["structural_cardinality"]
        self.assertEqual(cardinality["raw_route_policy_assignment_count"], 48**2)
        self.assertEqual(
            cardinality["raw_structural_configuration_count"],
            (48**2) * (6**4),
        )
        self.assertEqual(
            cardinality["admissible_structural_configuration_count"],
            (16**2) * ((6**4) - 1),
        )

    def test_checked_lock_rebuilds_exactly_and_every_binding_reopens(self) -> None:
        expected = build_spatial_policy_admissibility_manifest(ROOT)
        self.assertEqual(self.manifest, expected)
        self.assertEqual(
            validate_spatial_policy_admissibility_manifest(
                self.manifest,
                repository_root=ROOT,
            ),
            self.manifest["manifest_sha256"],
        )
        self.assertEqual(
            validate_spatial_policy_admissibility_manifest_file(
                MANIFEST_PATH,
                repository_root=ROOT,
            ),
            self.manifest["manifest_sha256"],
        )
        bindings = self.manifest["input_bindings"]
        self.assertEqual(
            [binding["id"] for binding in bindings],
            sorted(binding["id"] for binding in bindings),
        )
        for binding in bindings:
            path = ROOT / binding["path"]
            payload = path.read_bytes()
            self.assertEqual(len(payload), binding["size_bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), binding["sha256"])

    def test_contract_and_manifest_mutations_are_rejected(self) -> None:
        formula_mutation = deepcopy(self.contract)
        formula_mutation["semantic_programs"]["kernel"]["K0"] = ["T"]
        formula_mutation["artifact_sha256"] = manifest_sha256(
            formula_mutation,
            "artifact_sha256",
        )
        self.assertTrue(
            list(
                Draft202012Validator(self.contract_schema).iter_errors(
                    formula_mutation
                )
            )
        )

        mutations = []
        wrong_binding = deepcopy(self.manifest)
        wrong_binding["input_bindings"][0]["sha256"] = "f" * 64
        wrong_binding["manifest_sha256"] = manifest_sha256(wrong_binding)
        mutations.append(("binding hash", wrong_binding))

        escaped_binding = deepcopy(self.manifest)
        escaped_binding["input_bindings"][0]["path"] = "../json_tools.py"
        escaped_binding["manifest_sha256"] = manifest_sha256(escaped_binding)
        mutations.append(("path escape", escaped_binding))

        reordered = deepcopy(self.manifest)
        reordered["policy_records"][0], reordered["policy_records"][1] = (
            reordered["policy_records"][1],
            reordered["policy_records"][0],
        )
        reordered["manifest_sha256"] = manifest_sha256(reordered)
        mutations.append(("policy order", reordered))

        duplicate = deepcopy(self.manifest)
        duplicate["policy_records"][1] = duplicate["policy_records"][0]
        duplicate["manifest_sha256"] = manifest_sha256(duplicate)
        mutations.append(("duplicate policy", duplicate))

        one_route = deepcopy(self.manifest)
        one_route["policy_records"][0]["routes"][1][
            "missing_descriptor_ids"
        ] = [15]
        one_route["policy_records"][0]["routes"][1]["descriptor_ids"] = list(
            range(15)
        )
        one_route["policy_records"][0]["routes"][1][
            "descriptor_complete"
        ] = False
        one_route["manifest_sha256"] = manifest_sha256(one_route)
        mutations.append(("one-route coverage", one_route))

        wrong_self_hash = deepcopy(self.manifest)
        wrong_self_hash["manifest_sha256"] = "f" * 64
        mutations.append(("self hash", wrong_self_hash))

        extra_result = deepcopy(self.manifest)
        extra_result["objective"] = []
        extra_result["manifest_sha256"] = manifest_sha256(extra_result)
        mutations.append(("objective field", extra_result))

        for label, mutation in mutations:
            with self.subTest(mutation=label):
                with self.assertRaises(SpatialPolicyContractError):
                    validate_spatial_policy_admissibility_manifest(
                        mutation,
                        repository_root=ROOT,
                    )

    def test_manifest_file_rejects_extra_lf_and_duplicate_keys(self) -> None:
        payload = MANIFEST_PATH.read_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            extra_lf = root / "extra-lf.json"
            extra_lf.write_bytes(payload + b"\n")
            duplicate = root / "duplicate.json"
            duplicate.write_bytes(
                payload.replace(
                    b"{",
                    b'{"schema_version":"2.0.0",',
                    1,
                )
            )
            for path in (extra_lf, duplicate):
                with self.subTest(path=path):
                    with self.assertRaises(SpatialPolicyContractError):
                        validate_spatial_policy_admissibility_manifest_file(
                            path,
                            repository_root=ROOT,
                        )

    def test_cli_build_is_deterministic_exclusive_and_verify_is_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            first = root / "first.json"
            second = root / "second.json"
            build_command = [
                "/usr/bin/python3",
                str(CLI_PATH),
                "build",
                "--repository-root",
                str(ROOT),
                "--output",
            ]
            first_result = subprocess.run(
                [*build_command, str(first)],
                check=True,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env={"PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            )
            second_result = subprocess.run(
                [*build_command, str(second)],
                check=True,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env={"PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            )
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.read_bytes(), MANIFEST_PATH.read_bytes())
            self.assertEqual(
                json.loads(first_result.stdout),
                {
                    "manifest_sha256": self.manifest["manifest_sha256"],
                    "status": "built_and_verified",
                },
            )
            self.assertEqual(first_result.stdout, second_result.stdout)

            before = (
                first.stat().st_ino,
                first.stat().st_size,
                first.stat().st_mtime_ns,
                hashlib.sha256(first.read_bytes()).hexdigest(),
            )
            verify_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(CLI_PATH),
                    "verify",
                    "--repository-root",
                    str(ROOT),
                    "--manifest",
                    str(first),
                ],
                check=True,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env={"PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            )
            after = (
                first.stat().st_ino,
                first.stat().st_size,
                first.stat().st_mtime_ns,
                hashlib.sha256(first.read_bytes()).hexdigest(),
            )
            self.assertEqual(after, before)
            self.assertEqual(
                json.loads(verify_result.stdout),
                {
                    "manifest_sha256": self.manifest["manifest_sha256"],
                    "status": "verified",
                },
            )

            refused = subprocess.run(
                [*build_command, str(first)],
                check=False,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env={"PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(
                hashlib.sha256(first.read_bytes()).hexdigest(),
                before[3],
            )

    def test_cli_refuses_symbolic_output_components(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            real_parent = root / "real-parent"
            real_parent.mkdir()
            symbolic_parent = root / "symbolic-parent"
            symbolic_parent.symlink_to(real_parent, target_is_directory=True)
            command = [
                "/usr/bin/python3",
                str(CLI_PATH),
                "build",
                "--repository-root",
                str(ROOT),
                "--output",
            ]
            environment = {
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPATH": str(ROOT),
            }
            parent_result = subprocess.run(
                [*command, str(symbolic_parent / "manifest.json")],
                check=False,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env=environment,
            )
            self.assertNotEqual(parent_result.returncode, 0)
            self.assertFalse((real_parent / "manifest.json").exists())

            target = root / "sentinel"
            target.write_bytes(b"sentinel")
            symbolic_leaf = real_parent / "manifest.json"
            symbolic_leaf.symlink_to(target)
            leaf_result = subprocess.run(
                [*command, str(symbolic_leaf)],
                check=False,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env=environment,
            )
            self.assertNotEqual(leaf_result.returncode, 0)
            self.assertTrue(symbolic_leaf.is_symlink())
            self.assertEqual(target.read_bytes(), b"sentinel")

            other_root = root / "other-root"
            other_root.mkdir()
            other_output = real_parent / "other-root.json"
            other_root_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(CLI_PATH),
                    "build",
                    "--repository-root",
                    str(other_root),
                    "--output",
                    str(other_output),
                ],
                check=False,
                capture_output=True,
                text=True,
                cwd=ROOT,
                env=environment,
            )
            self.assertNotEqual(other_root_result.returncode, 0)
            self.assertIn(
                "repository root must match the CLI implementation root",
                other_root_result.stderr,
            )
            self.assertFalse(other_output.exists())

    def test_late_validation_failure_removes_only_owned_publication(self) -> None:
        from validation.calibration_v2.tools import (
            build_spatial_policy_admissibility_v2 as cli,
        )

        manifest = build_spatial_policy_admissibility_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "manifest.json"
            with mock.patch.object(
                cli,
                "validate_spatial_policy_admissibility_manifest_file",
                side_effect=SpatialPolicyContractError("injected late failure"),
            ):
                with self.assertRaisesRegex(
                    SpatialPolicyContractError,
                    "injected late failure",
                ):
                    cli._publish_exclusive(
                        output,
                        manifest,
                        repository_root=ROOT,
                    )
            self.assertFalse(output.exists())
            self.assertEqual(list(root.iterdir()), [])

    def test_destination_replacement_after_rename_is_not_removed(self) -> None:
        from validation.calibration_v2.tools import (
            build_spatial_policy_admissibility_v2 as cli,
        )

        manifest = build_spatial_policy_admissibility_manifest(ROOT)
        sentinel = b"foreign replacement"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / "manifest.json"
            original_rename = cli._rename_exclusive_at

            def replace_after_rename(
                source_parent_descriptor: int,
                source_name: str,
                destination_parent_descriptor: int,
                destination_name: str,
            ) -> None:
                original_rename(
                    source_parent_descriptor,
                    source_name,
                    destination_parent_descriptor,
                    destination_name,
                )
                os.unlink(
                    destination_name,
                    dir_fd=destination_parent_descriptor,
                )
                descriptor = os.open(
                    destination_name,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=destination_parent_descriptor,
                )
                try:
                    offset = 0
                    while offset < len(sentinel):
                        written = os.write(descriptor, sentinel[offset:])
                        self.assertGreater(written, 0)
                        offset += written
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                os.fsync(destination_parent_descriptor)

            with mock.patch.object(
                cli,
                "_rename_exclusive_at",
                side_effect=replace_after_rename,
            ):
                with self.assertRaisesRegex(
                    SpatialPolicyContractError,
                    "owned cleanup was incomplete",
                ):
                    cli._publish_exclusive(
                        output,
                        manifest,
                        repository_root=ROOT,
                    )
            self.assertEqual(output.read_bytes(), sentinel)
            self.assertEqual(output.stat().st_nlink, 1)
            self.assertEqual(list(root.iterdir()), [output])

    def test_artifact_contains_no_quality_result_or_media_binding(self) -> None:
        self.assertEqual(self.manifest["selection_state"], self.contract["selection_state"])
        self.assertEqual(self.manifest["data_access"], self.contract["data_access"])
        keys = set(all_keys(self.manifest))
        for forbidden in (
            "objective",
            "rank",
            "quality_metrics",
            "selected_configuration",
            "terminal_vector",
        ):
            self.assertNotIn(forbidden, keys)
        for binding in self.manifest["input_bindings"]:
            self.assertTrue(binding["path"].startswith("validation/"))
            self.assertNotIn("Artifacts/", binding["path"])
            self.assertFalse(binding["path"].lower().endswith(".mp4"))


if __name__ == "__main__":
    unittest.main()
