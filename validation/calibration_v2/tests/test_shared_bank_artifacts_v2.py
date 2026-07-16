from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from validation.calibration_v2.calibration_plan_codec import (
    materialize_candidate_vector_v2,
)
from validation.calibration_v2.reference.calibration_plan_v2 import (
    ATOMIC_STRUCTURAL_COORDINATE,
)
from validation.calibration_v2.release_lock import (
    operator_bank_document,
    video_mapping_document,
)
from validation.calibration_v2.shared_bank_artifacts_v2 import (
    CONTRACT_RELATIVE_PATH,
    CONTRACT_SCHEMA_RELATIVE_PATH,
    EXPECTED_CONTRACT_FILE_SHA256,
    EXPECTED_CONTRACT_SCHEMA_FILE_SHA256,
    EXPECTED_CONTRACT_SELF_SHA256,
    EXPECTED_MAPPING_SCHEMA_FILE_SHA256,
    EXPECTED_OPERATOR_SCHEMA_FILE_SHA256,
    MAPPING_SCHEMA_RELATIVE_PATH,
    OPERATOR_SCHEMA_RELATIVE_PATH,
    SharedBankArtifactMaterializerV2,
    SharedBankArtifactV2Error,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


ROOT = Path(__file__).resolve().parents[3]
CALIBRATION_ROOT = ROOT / "validation/calibration_v2"
PLAN_V1_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v1.json"
PLAN_V2_PATH = CALIBRATION_ROOT / "contracts/calibration-plan-v2.json"
IDENTITY_V2_PATH = (
    CALIBRATION_ROOT / "contracts/shared-bank-configuration-identity-v2.json"
)
IDENTITY_V2_SCHEMA_PATH = (
    CALIBRATION_ROOT / "schemas/shared-bank-configuration-identity-v2.schema.json"
)
MAPPING_V1_SCHEMA_PATH = CALIBRATION_ROOT / "schemas/video-mapping-v1.schema.json"
OPERATOR_V1_SCHEMA_PATH = CALIBRATION_ROOT / "schemas/operator-bank-v1.schema.json"
RELEASE_LOCK_PATH = CALIBRATION_ROOT / "release_lock.py"

MAPPING_SEED_SHA256 = (
    "2ebdffa39909012e3284888fd23ede66a68a8a2e270fdfc278b287d109a60e88"
)
OPERATOR_SEED_SHA256 = (
    "7909a226c80fae86a4f38a4f0e52bfb99205f47e1dcecb7c121d1eb62801b137"
)


def _decode(payload: bytes) -> dict[str, object]:
    value = json.loads(payload)
    if type(value) is not dict:
        raise AssertionError("expected JSON object")
    return value


def _encode(document: dict[str, object]) -> bytes:
    return canonical_json_bytes(document) + b"\n"


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class SharedBankArtifactsV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.materializer = SharedBankArtifactMaterializerV2()
        cls.scalar_initial = dict(cls.materializer.plan.scalar_initial_values)
        cls.physical_initial = cls.physical(0)
        cls.pair = cls.materializer.materialize(
            cls.physical_initial,
            configuration_id="schema-v2-fixture-001",
            mapping_seed_sha256=MAPPING_SEED_SHA256,
            operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
        )

    @classmethod
    def physical(
        cls,
        ordinal: int,
        **overrides: object,
    ) -> dict[str, object]:
        logical = {
            ATOMIC_STRUCTURAL_COORDINATE: ordinal,
            **cls.scalar_initial,
            **overrides,
        }
        return dict(
            materialize_candidate_vector_v2(
                logical,
                cls.materializer.plan,
            )
        )

    def validate_mutated(
        self,
        mapping: dict[str, object],
        operator: dict[str, object],
    ) -> None:
        mapping_bytes = _encode(mapping)
        operator_bytes = _encode(operator)
        self.materializer.validate(
            mapping_bytes,
            operator_bytes,
            mapping_sha256=_sha256(mapping_bytes),
            operator_bank_sha256=_sha256(operator_bytes),
        )

    def test_authorities_are_authenticated_before_materialization(self) -> None:
        self.assertEqual(
            _sha256((ROOT / CONTRACT_RELATIVE_PATH).read_bytes()),
            EXPECTED_CONTRACT_FILE_SHA256,
        )
        self.assertEqual(
            _sha256((ROOT / CONTRACT_SCHEMA_RELATIVE_PATH).read_bytes()),
            EXPECTED_CONTRACT_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            _sha256((ROOT / MAPPING_SCHEMA_RELATIVE_PATH).read_bytes()),
            EXPECTED_MAPPING_SCHEMA_FILE_SHA256,
        )
        self.assertEqual(
            _sha256((ROOT / OPERATOR_SCHEMA_RELATIVE_PATH).read_bytes()),
            EXPECTED_OPERATOR_SCHEMA_FILE_SHA256,
        )
        contract = _decode((ROOT / CONTRACT_RELATIVE_PATH).read_bytes())
        self.assertEqual(contract["artifact_sha256"], EXPECTED_CONTRACT_SELF_SHA256)

        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            copied_root = temporary_root / "validation/calibration_v2"
            shutil.copytree(CALIBRATION_ROOT, copied_root)
            relative_paths = (
                CONTRACT_RELATIVE_PATH,
                CONTRACT_SCHEMA_RELATIVE_PATH,
                MAPPING_SCHEMA_RELATIVE_PATH,
                OPERATOR_SCHEMA_RELATIVE_PATH,
                Path("validation/calibration_v2/contracts/calibration-plan-v2.json"),
                Path(
                    "validation/calibration_v2/contracts/"
                    "shared-bank-configuration-identity-v2.json"
                ),
                Path(
                    "validation/calibration_v2/schemas/"
                    "shared-bank-configuration-identity-v2.schema.json"
                ),
            )
            for relative_path in relative_paths:
                path = temporary_root / relative_path
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                with self.subTest(path=str(relative_path)), self.assertRaises(
                    SharedBankArtifactV2Error
                ):
                    SharedBankArtifactMaterializerV2(temporary_root)
                path.write_bytes(original)

    def test_all_256_structural_ordinals_materialize_and_reopen_exactly(self) -> None:
        seen_modes: dict[int, set[tuple[int, bool]]] = {}
        expected_order = list(self.materializer.plan.physical_candidate_order)
        for ordinal in range(256):
            physical = self.physical(ordinal)
            pair = self.materializer.materialize(
                physical,
                configuration_id=f"schema-v2-ordinal-{ordinal:03d}",
                mapping_seed_sha256=MAPPING_SEED_SHA256,
                operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
            )
            mapping = _decode(pair.mapping_bytes)
            operator = _decode(pair.operator_bank_bytes)
            items = mapping["candidate_identity"]["physical_candidate_items"]
            self.assertEqual([item[0] for item in items], expected_order)
            self.assertEqual([item[1] for item in items], list(physical.values()))
            self.assertEqual(
                mapping["candidate_identity"],
                operator["candidate_identity"],
            )
            self.assertEqual(pair.mapping_sha256, _sha256(pair.mapping_bytes))
            self.assertEqual(
                pair.operator_bank_sha256,
                _sha256(pair.operator_bank_bytes),
            )
            self.assertEqual(pair.mapping_bytes, _encode(mapping))
            self.assertEqual(pair.operator_bank_bytes, _encode(operator))
            for route in operator["routes"].values():
                for plane_name in ("luma", "chroma"):
                    plane = route[plane_name]
                    seen_modes.setdefault(
                        plane["anisotropy_mode_ordinal"],
                        set(),
                    ).add(
                        (
                            plane["resolved_anisotropy_strength_q12"],
                            plane["resolved_use_anisotropy"],
                        )
                    )

        self.assertEqual(
            seen_modes,
            {
                0: {(0, False)},
                1: {(0, True)},
                2: {(1024, True)},
                3: {(2048, True)},
                4: {(3072, True)},
                5: {(4096, True)},
            },
        )

    def test_candidate_count_type_domain_relation_ordinal_and_version_reject(self) -> None:
        missing = dict(self.physical_initial)
        missing.pop("penalty_phase_kernel_mismatch")
        boolean_alias = dict(self.physical_initial)
        boolean_alias["spatial_structural_vector_ordinal"] = False
        wrong_domain = dict(self.physical_initial)
        wrong_domain["analysis_epsilon_q0_30"] = -1
        wrong_factor = dict(self.physical_initial)
        wrong_factor["direct_2x_route_spatial_policy_id"] = 1
        all_isotropic = dict(self.physical_initial)
        for name in (
            "direct_2x_luma_anisotropy_mode_ordinal",
            "direct_2x_chroma_anisotropy_mode_ordinal",
            "direct_3_over_2_luma_anisotropy_mode_ordinal",
            "direct_3_over_2_chroma_anisotropy_mode_ordinal",
        ):
            all_isotropic[name] = 0
        relational = self.physical(
            0,
            edge_present_low_unorm15=9830,
            edge_present_high_unorm15=9830,
        )
        plan_v1 = _decode(PLAN_V1_PATH.read_bytes())
        vector_v1 = plan_v1["search"]["initial_vector_values"]

        for label, candidate in (
            ("missing", missing),
            ("boolean", boolean_alias),
            ("domain", wrong_domain),
            ("ordinal", wrong_factor),
            ("all_isotropic", all_isotropic),
            ("relation", relational),
            ("v1", vector_v1),
        ):
            with self.subTest(label=label), self.assertRaises(
                SharedBankArtifactV2Error
            ):
                self.materializer.materialize(
                    candidate,
                    configuration_id="schema-v2-reject-001",
                    mapping_seed_sha256=MAPPING_SEED_SHA256,
                    operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
                )

    def test_candidate_identity_order_hash_and_pair_divergence_reject(self) -> None:
        mapping = _decode(self.pair.mapping_bytes)
        operator = _decode(self.pair.operator_bank_bytes)

        swapped_mapping = deepcopy(mapping)
        items = swapped_mapping["candidate_identity"]["physical_candidate_items"]
        items[0], items[1] = items[1], items[0]
        with self.assertRaises(SharedBankArtifactV2Error):
            self.validate_mutated(swapped_mapping, operator)

        for field in (
            "candidate_vector_sha256",
            "shared_bank_configuration_sha256",
        ):
            changed_mapping = deepcopy(mapping)
            changed_operator = deepcopy(operator)
            changed_mapping["candidate_identity"][field] = "c" * 64
            changed_operator["candidate_identity"][field] = "c" * 64
            with self.subTest(field=field), self.assertRaises(
                SharedBankArtifactV2Error
            ):
                self.validate_mutated(changed_mapping, changed_operator)

        divergent = deepcopy(operator)
        divergent["candidate_identity"]["candidate_vector_sha256"] = "d" * 64
        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "identities diverge",
        ):
            self.validate_mutated(mapping, divergent)

    def test_authority_projection_and_mode_derived_mutations_reject(self) -> None:
        mapping = _decode(self.pair.mapping_bytes)
        operator = _decode(self.pair.operator_bank_bytes)

        authority_drift = deepcopy(mapping)
        authority_drift["materialization_authority"][
            "shared_bank_artifact_materialization_v2_file_sha256"
        ] = "e" * 64
        with self.assertRaises(SharedBankArtifactV2Error):
            self.validate_mutated(authority_drift, operator)

        mapping_projection = deepcopy(mapping)
        mapping_projection["risk_weights_unorm15"] = {
            "alternating_difference": 16383,
            "laplacian": 16384,
        }
        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "exact candidate materialization",
        ):
            self.validate_mutated(mapping_projection, operator)

        mode_mismatch = deepcopy(operator)
        mode_mismatch["routes"]["direct_3_over_2"]["chroma"][
            "resolved_anisotropy_strength_q12"
        ] = 0
        with self.assertRaises(SharedBankArtifactV2Error):
            self.validate_mutated(mapping, mode_mismatch)

        global_projection = deepcopy(operator)
        global_projection["operator_parameters"]["anisotropy_strength_q12"] = 3072
        with self.assertRaises(SharedBankArtifactV2Error):
            self.validate_mutated(mapping, global_projection)

    def test_canonical_file_and_complete_file_digest_mutations_reject(self) -> None:
        mapping_document = _decode(self.pair.mapping_bytes)
        unsorted_mapping = (
            json.dumps(
                dict(reversed(list(mapping_document.items()))),
                separators=(",", ":"),
            ).encode("utf-8")
            + b"\n"
        )
        duplicate_mapping = self.pair.mapping_bytes.replace(
            b'{"analysis_epsilon_q0_30":',
            b'{"schema_version":"2.0.0","analysis_epsilon_q0_30":',
            1,
        )
        for label, mapping_bytes in (
            ("missing_lf", self.pair.mapping_bytes[:-1]),
            ("extra_lf", self.pair.mapping_bytes + b"\n"),
            ("space", self.pair.mapping_bytes[:-1] + b" \n"),
            ("bom", b"\xef\xbb\xbf" + self.pair.mapping_bytes),
            ("key_order", unsorted_mapping),
            ("duplicate", duplicate_mapping),
        ):
            with self.subTest(label=label), self.assertRaises(
                SharedBankArtifactV2Error
            ):
                self.materializer.validate(
                    mapping_bytes,
                    self.pair.operator_bank_bytes,
                    mapping_sha256=_sha256(mapping_bytes),
                    operator_bank_sha256=self.pair.operator_bank_sha256,
                )

        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "complete-file SHA-256",
        ):
            self.materializer.validate(
                self.pair.mapping_bytes,
                self.pair.operator_bank_bytes,
                mapping_sha256="f" * 64,
                operator_bank_sha256=self.pair.operator_bank_sha256,
            )
        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "complete-file SHA-256",
        ):
            self.materializer.validate(
                self.pair.mapping_bytes,
                self.pair.operator_bank_bytes,
                mapping_sha256=self.pair.mapping_sha256,
                operator_bank_sha256="f" * 64,
            )

        changed_seed = deepcopy(mapping_document)
        changed_seed["mapping_seed_sha256"] = "c" * 64
        changed_seed_bytes = _encode(changed_seed)
        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "complete-file SHA-256",
        ):
            self.materializer.validate(
                changed_seed_bytes,
                self.pair.operator_bank_bytes,
                mapping_sha256=self.pair.mapping_sha256,
                operator_bank_sha256=self.pair.operator_bank_sha256,
            )

    def test_cross_version_pairing_and_projection_are_rejected(self) -> None:
        plan_v1 = _decode(PLAN_V1_PATH.read_bytes())
        vector_v1 = plan_v1["search"]["initial_vector_values"]
        mapping_v1 = _encode(
            video_mapping_document(
                vector=vector_v1,
                plan=plan_v1,
                configuration_id="schema-v1-fixture-001",
                mapping_seed_sha256=MAPPING_SEED_SHA256,
                status="calibration_candidate",
            )
        )
        operator_v1 = _encode(
            operator_bank_document(
                vector=vector_v1,
                plan=plan_v1,
                configuration_id="schema-v1-fixture-001",
                operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
                status="calibration_candidate",
            )
        )
        for mapping_bytes, operator_bytes in (
            (mapping_v1, operator_v1),
            (mapping_v1, self.pair.operator_bank_bytes),
            (self.pair.mapping_bytes, operator_v1),
        ):
            with self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "cross-version",
            ):
                self.materializer.validate(
                    mapping_bytes,
                    operator_bytes,
                    mapping_sha256=_sha256(mapping_bytes),
                    operator_bank_sha256=_sha256(operator_bytes),
                )

    def test_locked_state_preserves_exact_pair_identity(self) -> None:
        selection = {
            "calibration_selection_sha256": "a" * 64,
            "selected_evaluation_sha256": "b" * 64,
        }
        pair = self.materializer.materialize(
            self.physical_initial,
            configuration_id="schema-v2-locked-001",
            mapping_seed_sha256=MAPPING_SEED_SHA256,
            operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
            status="locked_before_p07",
            selection_binding=selection,
        )
        mapping = _decode(pair.mapping_bytes)
        operator = _decode(pair.operator_bank_bytes)
        self.assertEqual(mapping["selection_binding"], selection)
        self.assertEqual(operator["selection_binding"], selection)
        self.assertEqual(
            self.materializer.validate(
                pair.mapping_bytes,
                pair.operator_bank_bytes,
                mapping_sha256=pair.mapping_sha256,
                operator_bank_sha256=pair.operator_bank_sha256,
            ),
            pair,
        )

    def test_v1_source_schemas_and_fixture_bytes_are_immutable(self) -> None:
        self.assertEqual(
            _sha256(RELEASE_LOCK_PATH.read_bytes()),
            "339b2a40688023fabdae5378bf578f57622465b7de840d5c620023d6b91cbb40",
        )
        self.assertEqual(
            _sha256(MAPPING_V1_SCHEMA_PATH.read_bytes()),
            "307a61418e2cf4441c86167e4af48c59ce149a65b186455fe3194d9b18841b28",
        )
        self.assertEqual(
            _sha256(OPERATOR_V1_SCHEMA_PATH.read_bytes()),
            "157f4d3fa02af88e50a1daba3664aa442aae76b6378566a485b9c4d8a5c6ef07",
        )
        plan_v1 = _decode(PLAN_V1_PATH.read_bytes())
        vector_v1 = plan_v1["search"]["initial_vector_values"]
        mapping_v1 = _encode(
            video_mapping_document(
                vector=vector_v1,
                plan=plan_v1,
                configuration_id="schema-v1-fixture-001",
                mapping_seed_sha256=MAPPING_SEED_SHA256,
                status="calibration_candidate",
            )
        )
        operator_v1 = _encode(
            operator_bank_document(
                vector=vector_v1,
                plan=plan_v1,
                configuration_id="schema-v1-fixture-001",
                operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
                status="calibration_candidate",
            )
        )
        self.assertEqual(len(mapping_v1), 1236)
        self.assertEqual(
            _sha256(mapping_v1),
            "d58c0ce0a675f276579198b91b87ce66c612e8e12b9723865400e15cddd0b080",
        )
        self.assertEqual(len(operator_v1), 1257)
        self.assertEqual(
            _sha256(operator_v1),
            "1255660096e412d666c41f6149353e2a82a2268f4b002ed7d002de0a329ef508",
        )


if __name__ == "__main__":
    unittest.main()
