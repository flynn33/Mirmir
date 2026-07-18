from __future__ import annotations

import ast
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import threading
import unittest
from unittest import mock

import validation.calibration_v2.release_lock as release_lock_module
import validation.calibration_v2.shared_bank_artifacts_v2 as shared_bank_module

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
    SharedBankArtifactPairV2,
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

_V1_RELEASE_LOCK_SOURCE_BINDINGS = frozenset(
    {
        "hashlib",
        "json",
        "validate_schema",
        "VIDEO_MAPPING_SCHEMA",
        "OPERATOR_BANK_SCHEMA",
        "_PARAMETER_ORDER_LENGTH",
        "_THRESHOLD_BANDS",
        "_SHARED_BANK_COORDINATES",
        "ReleaseLockError",
        "_sha256",
        "_require_sha256",
        "_canonical_bytes",
        "candidate_vector_sha256_for_plan",
        "shared_bank_configuration_sha256_for_plan",
        "_selection_binding",
        "video_mapping_document",
        "operator_bank_document",
    }
)
_V1_RELEASE_LOCK_SOURCE_SHA256 = (
    "879525fccc8a28a0c3d05debf6ff4505ff0901f5f6f732a5d4127f24fc98ea1f"
)


class _ModuleScopeBindingVisitor(ast.NodeVisitor):
    """Find names bound while executing one module-level statement."""

    def __init__(self) -> None:
        self.names: list[str] = []

    def visit_Name(self, node: ast.Name) -> None:
        if isinstance(node.ctx, (ast.Store, ast.Del)):
            self.names.append(node.id)

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            self.names.append(alias.asname or alias.name.partition(".")[0])

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        for alias in node.names:
            self.names.append(alias.asname or alias.name)

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.names.append(node.name)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self.names.append(node.name)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.names.append(node.name)


def _v1_release_lock_source_sha256(source: str) -> str:
    """Hash the exact source statements that transitively define V1 banks."""

    tree = ast.parse(source)
    records: list[dict[str, object]] = []
    binding_counts = {name: 0 for name in _V1_RELEASE_LOCK_SOURCE_BINDINGS}
    for node in tree.body:
        visitor = _ModuleScopeBindingVisitor()
        visitor.visit(node)
        matched_names = sorted(
            name
            for name in visitor.names
            if name in _V1_RELEASE_LOCK_SOURCE_BINDINGS
        )
        if not matched_names:
            continue
        segment = ast.get_source_segment(source, node)
        if segment is None:
            raise AssertionError("V1 source binding has no exact source segment")
        for name in matched_names:
            binding_counts[name] += 1
        records.append(
            {
                "bound_names": matched_names,
                "source": segment,
            }
        )
    nonunique = {
        name: count for name, count in binding_counts.items() if count != 1
    }
    if nonunique:
        raise AssertionError(f"V1 source bindings are not unique: {nonunique}")
    return _sha256(canonical_json_bytes(records))


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

    @staticmethod
    def write_pair_directory(
        directory: Path,
        pair: SharedBankArtifactPairV2,
    ) -> None:
        directory.mkdir()
        (directory / "candidate-mapping.json").write_bytes(pair.mapping_bytes)
        (directory / "candidate-operator-bank.json").write_bytes(
            pair.operator_bank_bytes
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

    def test_publish_pair_durable_reopen_and_exact_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "published-pair"
            fsync_kinds: list[int] = []
            real_fsync = os.fsync

            def record_fsync(descriptor: int) -> None:
                fsync_kinds.append(stat.S_IFMT(os.fstat(descriptor).st_mode))
                real_fsync(descriptor)

            with mock.patch.object(
                shared_bank_module.os,
                "fsync",
                side_effect=record_fsync,
            ), mock.patch.object(
                self.materializer,
                "validate",
                wraps=self.materializer.validate,
            ) as semantic_validate:
                first = self.materializer.publish_pair(target, self.pair)

            self.assertEqual(first, self.pair)
            self.assertEqual(
                {path.name for path in target.iterdir()},
                {
                    "candidate-mapping.json",
                    "candidate-operator-bank.json",
                },
            )
            self.assertEqual(
                (target / "candidate-mapping.json").read_bytes(),
                self.pair.mapping_bytes,
            )
            self.assertEqual(
                (target / "candidate-operator-bank.json").read_bytes(),
                self.pair.operator_bank_bytes,
            )
            self.assertGreaterEqual(semantic_validate.call_count, 3)
            self.assertGreaterEqual(fsync_kinds.count(stat.S_IFREG), 2)
            self.assertGreaterEqual(fsync_kinds.count(stat.S_IFDIR), 2)
            first_identity = (target.stat().st_dev, target.stat().st_ino)
            first_mapping_identity = (
                (target / "candidate-mapping.json").stat().st_dev,
                (target / "candidate-mapping.json").stat().st_ino,
            )

            second = self.materializer.publish_pair(target, self.pair)

            self.assertEqual(second, self.pair)
            self.assertEqual(
                (target.stat().st_dev, target.stat().st_ino),
                first_identity,
            )
            self.assertEqual(
                (
                    (target / "candidate-mapping.json").stat().st_dev,
                    (target / "candidate-mapping.json").stat().st_ino,
                ),
                first_mapping_identity,
            )
            self.assertFalse(
                any(
                    path.name.startswith(
                        shared_bank_module._staging_prefix(target.name)
                    )
                    for path in parent.iterdir()
                )
            )

    def test_publish_pair_rejects_unsafe_and_symlink_targets(
        self,
    ) -> None:
        with self.assertRaisesRegex(
            SharedBankArtifactV2Error,
            "absolute pathlib.Path",
        ):
            self.materializer.publish_pair(Path("relative-pair"), self.pair)

        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(
                    parent / "absent-parent" / "pair",
                    self.pair,
                )

            regular_target = parent / "regular-target"
            regular_target.write_bytes(b"preexisting")
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(regular_target, self.pair)
            self.assertEqual(regular_target.read_bytes(), b"preexisting")

            external_directory = parent / "external-directory"
            external_directory.mkdir()
            symlink_target = parent / "symlink-target"
            symlink_target.symlink_to(external_directory, target_is_directory=True)
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(symlink_target, self.pair)
            self.assertTrue(symlink_target.is_symlink())
            self.assertEqual(tuple(external_directory.iterdir()), ())

            real_parent = parent / "real-parent"
            real_parent.mkdir()
            linked_parent = parent / "linked-parent"
            linked_parent.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(
                    linked_parent / "pair",
                    self.pair,
                )
            self.assertFalse((real_parent / "pair").exists())

            external_file = parent / "external.json"
            external_file.write_bytes(b"external-sentinel")
            file_symlink_target = parent / "file-symlink-pair"
            file_symlink_target.mkdir()
            (file_symlink_target / "candidate-mapping.json").symlink_to(
                external_file
            )
            (file_symlink_target / "candidate-operator-bank.json").write_bytes(
                self.pair.operator_bank_bytes
            )
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(file_symlink_target, self.pair)
            self.assertEqual(external_file.read_bytes(), b"external-sentinel")
            self.assertTrue(
                (file_symlink_target / "candidate-mapping.json").is_symlink()
            )

    def test_publish_pair_preserves_preexisting_divergence(
        self,
    ) -> None:
        divergent = self.materializer.materialize(
            self.physical_initial,
            configuration_id="schema-v2-divergent-publish-001",
            mapping_seed_sha256=MAPPING_SEED_SHA256,
            operator_bank_seed_sha256=OPERATOR_SEED_SHA256,
        )
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()

            partial = parent / "partial"
            partial.mkdir()
            partial_mapping = partial / "candidate-mapping.json"
            partial_mapping.write_bytes(self.pair.mapping_bytes)
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(partial, self.pair)
            self.assertEqual(
                {path.name for path in partial.iterdir()},
                {"candidate-mapping.json"},
            )
            self.assertEqual(partial_mapping.read_bytes(), self.pair.mapping_bytes)

            extra = parent / "extra"
            self.write_pair_directory(extra, self.pair)
            (extra / "unexpected.json").write_bytes(b"preserve-me")
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(extra, self.pair)
            self.assertEqual(
                (extra / "unexpected.json").read_bytes(),
                b"preserve-me",
            )

            divergent_target = parent / "divergent"
            self.write_pair_directory(divergent_target, divergent)
            before = {
                path.name: path.read_bytes()
                for path in divergent_target.iterdir()
            }
            with self.assertRaises(SharedBankArtifactV2Error):
                self.materializer.publish_pair(divergent_target, self.pair)
            self.assertEqual(
                {
                    path.name: path.read_bytes()
                    for path in divergent_target.iterdir()
                },
                before,
            )

    def test_publish_pair_rejects_oversized_preexisting_file_before_read(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary).resolve() / "oversized-pair"
            self.write_pair_directory(target, self.pair)
            mapping_path = target / "candidate-mapping.json"
            oversized_bytes = self.pair.mapping_bytes + (b"x" * (1024 * 1024))
            mapping_path.write_bytes(oversized_bytes)

            with mock.patch.object(
                shared_bank_module.os,
                "read",
                side_effect=AssertionError("oversized target must not be read"),
            ), self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "published video mapping has an unexpected size",
            ):
                self.materializer.publish_pair(target, self.pair)

            self.assertEqual(mapping_path.stat().st_size, len(oversized_bytes))
            self.assertEqual(mapping_path.read_bytes(), oversized_bytes)

    def test_publish_pair_accepts_bounded_short_reads_of_stable_pair(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary).resolve() / "short-read-pair"
            self.write_pair_directory(target, self.pair)
            real_read = os.read
            requested_sizes: list[int] = []

            def short_read(descriptor: int, size: int) -> bytes:
                requested_sizes.append(size)
                return real_read(descriptor, min(size, 7))

            with mock.patch.object(
                shared_bank_module.os,
                "read",
                side_effect=short_read,
            ):
                reopened = self.materializer.publish_pair(target, self.pair)

            self.assertEqual(reopened, self.pair)
            self.assertGreater(len(requested_sizes), 2)
            self.assertTrue(
                all(
                    size
                    <= max(
                        len(self.pair.mapping_bytes),
                        len(self.pair.operator_bank_bytes),
                    )
                    + 1
                    for size in requested_sizes
                )
            )

    def test_publish_pair_interruption_quarantines_then_retries(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "interrupted-pair"
            real_rename = shared_bank_module._rename_directory_exclusive_at
            injected = False

            def fail_publication_once(
                source_parent_descriptor: int,
                source_name: str,
                destination_parent_descriptor: int,
                destination_name: str,
            ) -> None:
                nonlocal injected
                if destination_name == target.name and not injected:
                    injected = True
                    raise OSError(errno.EIO, "injected atomic publication failure")
                real_rename(
                    source_parent_descriptor,
                    source_name,
                    destination_parent_descriptor,
                    destination_name,
                )

            with mock.patch.object(
                shared_bank_module,
                "_rename_directory_exclusive_at",
                side_effect=fail_publication_once,
            ), self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "evidence preserved",
            ):
                self.materializer.publish_pair(target, self.pair)

            self.assertFalse(target.exists())
            quarantine_prefix = shared_bank_module._quarantine_prefix(
                target.name,
                "failed-temp",
            )
            quarantines = [
                path
                for path in parent.iterdir()
                if path.name.startswith(quarantine_prefix)
            ]
            self.assertEqual(len(quarantines), 1)
            self.assertEqual(
                {path.name for path in quarantines[0].iterdir()},
                {
                    "candidate-mapping.json",
                    "candidate-operator-bank.json",
                },
            )
            self.assertEqual(
                (quarantines[0] / "candidate-mapping.json").read_bytes(),
                self.pair.mapping_bytes,
            )

            published = self.materializer.publish_pair(target, self.pair)
            retried = self.materializer.publish_pair(target, self.pair)
            self.assertEqual(published, self.pair)
            self.assertEqual(retried, self.pair)

    def test_publish_pair_bounds_dead_owner_staging_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "stale-recovery-pair"
            staging_prefix = shared_bank_module._staging_prefix(target.name)
            stale = parent / f"{staging_prefix}999999.{('a' * 32)}"
            stale.mkdir()
            (stale / "interrupted-evidence.bin").write_bytes(b"preserve-stale")

            with mock.patch.object(
                shared_bank_module,
                "_pid_is_active",
                return_value=False,
            ):
                result = self.materializer.publish_pair(target, self.pair)

            self.assertEqual(result, self.pair)
            stale_quarantine_prefix = shared_bank_module._quarantine_prefix(
                target.name,
                "stale-temp",
            )
            quarantines = [
                path
                for path in parent.iterdir()
                if path.name.startswith(stale_quarantine_prefix)
            ]
            self.assertEqual(len(quarantines), 1)
            self.assertEqual(
                (quarantines[0] / "interrupted-evidence.bin").read_bytes(),
                b"preserve-stale",
            )

        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "bounded-stale-pair"
            staging_prefix = shared_bank_module._staging_prefix(target.name)
            stale_names = []
            for index in range(
                shared_bank_module._MAX_RECOGNIZED_STAGING_DIRECTORIES + 1
            ):
                name = f"{staging_prefix}{900000 + index}.{index:032x}"
                (parent / name).mkdir()
                stale_names.append(name)
            with mock.patch.object(
                shared_bank_module,
                "_pid_is_active",
                return_value=False,
            ), self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "too many recognized",
            ):
                self.materializer.publish_pair(target, self.pair)
            self.assertFalse(target.exists())
            self.assertTrue(all((parent / name).is_dir() for name in stale_names))

    def test_publish_pair_rejects_same_size_reopen_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "mutated-pair"
            real_rename = shared_bank_module._rename_directory_exclusive_at
            mutated = False

            def mutate_after_publish(
                source_parent_descriptor: int,
                source_name: str,
                destination_parent_descriptor: int,
                destination_name: str,
            ) -> None:
                nonlocal mutated
                real_rename(
                    source_parent_descriptor,
                    source_name,
                    destination_parent_descriptor,
                    destination_name,
                )
                if destination_name != target.name or mutated:
                    return
                mutated = True
                directory_descriptor = os.open(
                    destination_name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=destination_parent_descriptor,
                )
                try:
                    descriptor = os.open(
                        "candidate-mapping.json",
                        os.O_WRONLY | os.O_NOFOLLOW,
                        dir_fd=directory_descriptor,
                    )
                    try:
                        os.write(descriptor, b"[")
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)

            with mock.patch.object(
                shared_bank_module,
                "_rename_directory_exclusive_at",
                side_effect=mutate_after_publish,
            ), self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "evidence preserved",
            ):
                self.materializer.publish_pair(target, self.pair)

            self.assertFalse(target.exists())
            quarantine_prefix = shared_bank_module._quarantine_prefix(
                target.name,
                "failed-published",
            )
            quarantines = [
                path
                for path in parent.iterdir()
                if path.name.startswith(quarantine_prefix)
            ]
            self.assertEqual(len(quarantines), 1)
            mutated_bytes = (
                quarantines[0] / "candidate-mapping.json"
            ).read_bytes()
            self.assertEqual(len(mutated_bytes), len(self.pair.mapping_bytes))
            self.assertNotEqual(mutated_bytes, self.pair.mapping_bytes)

    def test_publish_pair_rejects_reopen_symlink_swap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "symlink-swap-pair"
            external = parent / "external-sentinel.json"
            external.write_bytes(b"external-sentinel")
            displaced_name = "displaced-candidate-mapping.json"
            real_rename = shared_bank_module._rename_directory_exclusive_at
            swapped = False

            def swap_after_publish(
                source_parent_descriptor: int,
                source_name: str,
                destination_parent_descriptor: int,
                destination_name: str,
            ) -> None:
                nonlocal swapped
                real_rename(
                    source_parent_descriptor,
                    source_name,
                    destination_parent_descriptor,
                    destination_name,
                )
                if destination_name != target.name or swapped:
                    return
                swapped = True
                directory_descriptor = os.open(
                    destination_name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=destination_parent_descriptor,
                )
                try:
                    os.rename(
                        "candidate-mapping.json",
                        displaced_name,
                        src_dir_fd=directory_descriptor,
                        dst_dir_fd=destination_parent_descriptor,
                    )
                    os.symlink(
                        os.fspath(external),
                        "candidate-mapping.json",
                        dir_fd=directory_descriptor,
                    )
                    os.fsync(directory_descriptor)
                    os.fsync(destination_parent_descriptor)
                finally:
                    os.close(directory_descriptor)

            with mock.patch.object(
                shared_bank_module,
                "_rename_directory_exclusive_at",
                side_effect=swap_after_publish,
            ), self.assertRaisesRegex(
                SharedBankArtifactV2Error,
                "evidence preserved",
            ):
                self.materializer.publish_pair(target, self.pair)

            self.assertFalse(target.exists())
            self.assertEqual(external.read_bytes(), b"external-sentinel")
            self.assertEqual(
                (parent / displaced_name).read_bytes(),
                self.pair.mapping_bytes,
            )
            quarantine_prefix = shared_bank_module._quarantine_prefix(
                target.name,
                "failed-published",
            )
            quarantines = [
                path
                for path in parent.iterdir()
                if path.name.startswith(quarantine_prefix)
            ]
            self.assertEqual(len(quarantines), 1)
            quarantined_link = quarantines[0] / "candidate-mapping.json"
            self.assertTrue(quarantined_link.is_symlink())
            self.assertEqual(os.readlink(quarantined_link), os.fspath(external))

    def test_publish_pair_concurrent_exact_publishers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            target = parent / "concurrent-pair"
            publisher_count = 4
            barrier = threading.Barrier(publisher_count)
            real_rename = shared_bank_module._rename_directory_exclusive_at

            def synchronized_rename(
                source_parent_descriptor: int,
                source_name: str,
                destination_parent_descriptor: int,
                destination_name: str,
            ) -> None:
                if destination_name == target.name:
                    barrier.wait(timeout=20)
                real_rename(
                    source_parent_descriptor,
                    source_name,
                    destination_parent_descriptor,
                    destination_name,
                )

            with mock.patch.object(
                shared_bank_module,
                "_rename_directory_exclusive_at",
                side_effect=synchronized_rename,
            ), ThreadPoolExecutor(max_workers=publisher_count) as executor:
                results = list(
                    executor.map(
                        lambda _: self.materializer.publish_pair(
                            target,
                            self.pair,
                        ),
                        range(publisher_count),
                    )
                )

            self.assertEqual(results, [self.pair] * publisher_count)
            self.assertEqual(
                {path.name for path in target.iterdir()},
                {
                    "candidate-mapping.json",
                    "candidate-operator-bank.json",
                },
            )
            self.assertFalse(
                any(
                    path.name.startswith(
                        shared_bank_module._staging_prefix(target.name)
                    )
                    for path in parent.iterdir()
                )
            )

    def test_v1_source_schemas_and_fixture_bytes_are_immutable(self) -> None:
        release_lock_source = RELEASE_LOCK_PATH.read_text(encoding="utf-8")
        self.assertEqual(
            _v1_release_lock_source_sha256(release_lock_source),
            _V1_RELEASE_LOCK_SOURCE_SHA256,
        )
        self.assertEqual(
            release_lock_module.VIDEO_MAPPING_SCHEMA,
            MAPPING_V1_SCHEMA_PATH,
        )
        self.assertEqual(
            release_lock_module.OPERATOR_BANK_SCHEMA,
            OPERATOR_V1_SCHEMA_PATH,
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

    def test_v1_source_lock_is_scoped_but_rejects_v1_drift(self) -> None:
        source = RELEASE_LOCK_PATH.read_text(encoding="utf-8")
        baseline = _v1_release_lock_source_sha256(source)
        additive_v3_source = source + (
            "\n\ndef additive_v3_extension(payload: bytes) -> str:\n"
            "    return _sha256(payload)\n"
        )
        self.assertEqual(
            _v1_release_lock_source_sha256(additive_v3_source),
            baseline,
        )

        changed_v1_source = source.replace(
            '"mapping_id": "ash-video-mapping-v2"',
            '"mapping_id": "ash-video-mapping-v2-drift"',
            1,
        )
        self.assertNotEqual(changed_v1_source, source)
        self.assertNotEqual(
            _v1_release_lock_source_sha256(changed_v1_source),
            baseline,
        )

        rebound_v1_source = source + (
            "\nvideo_mapping_document = operator_bank_document\n"
        )
        with self.assertRaisesRegex(
            AssertionError,
            "V1 source bindings are not unique",
        ):
            _v1_release_lock_source_sha256(rebound_v1_source)


if __name__ == "__main__":
    unittest.main()
