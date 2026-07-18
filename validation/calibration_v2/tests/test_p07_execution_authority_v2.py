from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from validation.calibration_v2.p07.execution_authority_v2 import (
    FILENAME,
    P07ExecutionAuthorityV2Error,
    SUPPORT_BINDING_ORDER,
    build_document,
    publish_new,
    verify,
)


def _sha(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _identity(path: Path) -> dict[str, object]:
    payload = path.read_bytes()
    cdhash = hashlib.sha1(payload).hexdigest()
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "macos_code_identity_v1",
        "architecture": "arm64",
        "file_sha256": hashlib.sha256(payload).hexdigest(),
        "unique_cdhash": cdhash,
        "all_cdhashes": [cdhash],
        "digest_algorithms": [1],
        "static_code_flags": 2,
        "signing_kind": "ad_hoc",
        "identifier": f"test.{path.name}",
    }


class P07ExecutionAuthorityV2Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.release = self.root / "release"
        self.repository = self.root / "repository"
        self.release.mkdir()
        (self.release / "bin").mkdir()
        (self.release / "sources").mkdir()
        (self.repository / "Mirmir/Modules/MediaPipeline").mkdir(parents=True)
        self.runtime_manifest = self.release / "candidate-runtime-v2.json"
        self.native = self.release / "bin/ash-calibration-cli"
        self.source_manifest = (
            self.release / "sources/production-swift-source-manifest.json"
        )
        self.settings = (
            self.repository / "Mirmir/Modules/MediaPipeline/MediaTypes.swift"
        )
        self.runtime_manifest.write_bytes(b'{"schema_version":"2.0.0"}\n')
        self.native.write_bytes(b"native-executable")
        self.native.chmod(0o755)
        self.source_manifest.write_bytes(b'{"sources":[]}\n')
        self.settings.write_bytes(b"struct OutputProfile {}\n")
        self.source_commit = "a" * 40
        source_gates = self.release / "source-gates"
        source_gates.mkdir()
        for gate_id in ("G04", "G05", "G06"):
            semantic = {
                "gate_id": gate_id,
                "source_commit": self.source_commit,
                "working_tree_clean": True,
                "holdout_accessed": False,
            }
            receipt = {
                "schema_version": "2.0.0",
                "artifact_kind": "p06_current_source_gate_receipt_v2",
                "gate_id": gate_id,
                "status": "pass",
                "source_commit": self.source_commit,
                "working_tree_clean": True,
                "holdout_accessed": False,
                "semantic_reopen": semantic,
                "gate_tree": {
                    "algorithm": "canonical-sorted-gate-tree-v2",
                    "entry_count": 1,
                    "tree_sha256": _sha(f"{gate_id}-tree"),
                },
            }
            (source_gates / f"{gate_id}.json").write_text(
                json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )

        self.support_roots: dict[str, Path] = {}
        self.support_paths: dict[str, Path] = {}
        for _, root_id in SUPPORT_BINDING_ORDER:
            root = self.root / f"{root_id}-root"
            tree = root / "bound-tree"
            tree.mkdir(parents=True)
            (tree / "evidence.json").write_bytes(root_id.encode("utf-8"))
            self.support_roots[root_id] = root
            self.support_paths[root_id] = tree
        self.writer = (
            self.support_paths["production_writer"] / "production-writer"
        )
        self.writer.write_bytes(b"writer-executable")
        self.writer.chmod(0o755)
        self.p00 = self.support_paths["native_cache"] / "p00-native"
        self.p00.write_bytes(b"p00-executable")
        self.p00.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _build(self) -> dict[str, object]:
        with patch(
            "validation.calibration_v2.p07.execution_authority_v2.static_code_identity",
            side_effect=_identity,
        ), patch(
            "validation.calibration_v2.current_source_gate_closure_v2.current_source_git_identity_v2",
            return_value=(self.source_commit, b""),
        ):
            return dict(build_document(
                configuration_id="ash-p06-0123456789abcdef01234567",
                candidate_vector_sha256=_sha("candidate"),
                shared_bank_configuration_sha256=_sha("bank"),
                calibration_plan_v2_file_sha256=_sha("plan"),
                input_bundle_sha256=_sha("input"),
                corpus_lock_bundle_sha256=_sha("corpus"),
                raw_output_contract_sha256=_sha("raw-output"),
                release_root=self.release,
                repository_root=self.repository,
                candidate_runtime_manifest_path=self.runtime_manifest,
                native_executable_path=self.native,
                native_source_manifest_path=self.source_manifest,
                production_writer_executable_path=self.writer,
                p00_executable_path=self.p00,
                product_settings_source_path=self.settings,
                support_evidence_roots=self.support_roots,
                support_evidence_paths=self.support_paths,
            ))

    def test_published_projection_reopens_every_exact_binding(self) -> None:
        document = self._build()
        publication = publish_new(self.release / FILENAME, document)
        with patch(
            "validation.calibration_v2.p07.execution_authority_v2.static_code_identity",
            side_effect=_identity,
        ), patch(
            "validation.calibration_v2.current_source_gate_closure_v2.current_source_git_identity_v2",
            return_value=(self.source_commit, b""),
        ):
            reopened = verify(
                release_root=self.release,
                repository_root=self.repository,
                expected_file_sha256=str(publication["sha256"]),
                expected_configuration_id=str(document["configuration_id"]),
                expected_shared_bank_configuration_sha256=str(
                    document["shared_bank_configuration_sha256"]
                ),
                expected_input_bundle_sha256=str(document["input_bundle_sha256"]),
                expected_corpus_lock_bundle_sha256=str(
                    document["corpus_lock_bundle_sha256"]
                ),
                support_evidence_roots=self.support_roots,
            )
        self.assertEqual(reopened, document)

    def test_release_hash_substitution_fails_before_binding_reopen(self) -> None:
        document = self._build()
        publish_new(self.release / FILENAME, document)
        with self.assertRaisesRegex(
            P07ExecutionAuthorityV2Error,
            "file hash differs from P06 V3",
        ):
            verify(
                release_root=self.release,
                repository_root=self.repository,
                expected_file_sha256=_sha("another-authority"),
                expected_configuration_id=str(document["configuration_id"]),
                expected_shared_bank_configuration_sha256=str(
                    document["shared_bank_configuration_sha256"]
                ),
                expected_input_bundle_sha256=str(document["input_bundle_sha256"]),
                expected_corpus_lock_bundle_sha256=str(
                    document["corpus_lock_bundle_sha256"]
                ),
                support_evidence_roots=self.support_roots,
            )

    def test_support_tree_mutation_fails_closed(self) -> None:
        document = self._build()
        publication = publish_new(self.release / FILENAME, document)
        (self.support_paths["dispatch_measurement"] / "after-lock.json").write_bytes(
            b"mutated"
        )
        with patch(
            "validation.calibration_v2.p07.execution_authority_v2.static_code_identity",
            side_effect=_identity,
        ), patch(
            "validation.calibration_v2.current_source_gate_closure_v2.current_source_git_identity_v2",
            return_value=(self.source_commit, b""),
        ), self.assertRaisesRegex(
            P07ExecutionAuthorityV2Error,
            "authority bytes changed: dispatch_measurement_tree",
        ):
            verify(
                release_root=self.release,
                repository_root=self.repository,
                expected_file_sha256=str(publication["sha256"]),
                expected_configuration_id=str(document["configuration_id"]),
                expected_shared_bank_configuration_sha256=str(
                    document["shared_bank_configuration_sha256"]
                ),
                expected_input_bundle_sha256=str(document["input_bundle_sha256"]),
                expected_corpus_lock_bundle_sha256=str(
                    document["corpus_lock_bundle_sha256"]
                ),
                support_evidence_roots=self.support_roots,
            )

    def test_code_identity_hash_must_equal_bound_file_hash(self) -> None:
        document = self._build()
        document["macos_code_identities"]["production_swift_executable"][
            "file_sha256"
        ] = _sha("substituted-executable")
        core = {key: value for key, value in document.items() if key != "artifact_sha256"}
        from validation.quality.src.mirmir_quality.json_tools import canonical_sha256

        document["artifact_sha256"] = canonical_sha256(core)
        with self.assertRaisesRegex(
            P07ExecutionAuthorityV2Error,
            "code identity differs from its file binding",
        ):
            publish_new(self.release / FILENAME, document)

    def test_symlinked_root_ancestor_is_rejected(self) -> None:
        alias = self.root / "release-alias"
        alias.symlink_to(self.release, target_is_directory=True)
        with self.assertRaisesRegex(
            P07ExecutionAuthorityV2Error,
            "traverses a symlink",
        ):
            build_document(
                configuration_id="ash-p06-0123456789abcdef01234567",
                candidate_vector_sha256=_sha("candidate"),
                shared_bank_configuration_sha256=_sha("bank"),
                calibration_plan_v2_file_sha256=_sha("plan"),
                input_bundle_sha256=_sha("input"),
                corpus_lock_bundle_sha256=_sha("corpus"),
                raw_output_contract_sha256=_sha("raw-output"),
                release_root=alias,
                repository_root=self.repository,
                candidate_runtime_manifest_path=alias / "candidate-runtime-v2.json",
                native_executable_path=alias / "bin/ash-calibration-cli",
                native_source_manifest_path=(
                    alias / "sources/production-swift-source-manifest.json"
                ),
                production_writer_executable_path=self.writer,
                p00_executable_path=self.p00,
                product_settings_source_path=self.settings,
                support_evidence_roots=self.support_roots,
                support_evidence_paths=self.support_paths,
            )


if __name__ == "__main__":
    unittest.main()
