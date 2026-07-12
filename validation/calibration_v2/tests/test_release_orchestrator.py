from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.release_evidence import (
    IMPLEMENTATION_IDS,
    P00_FAILURE_ID,
    SELECTED_CONTROL_IDS,
    SUPPORT_TREE_IDS,
    TEST_EVIDENCE_IDS,
    p06_evidence_closure_document,
)
from validation.calibration_v2.release_orchestrator import (
    P06ReleaseOrchestrationError,
    _configuration_bindings,
    _python_source_manifest,
    _safe_child,
    build_p06_release_transaction,
)
from validation.calibration_v2.release_lock import (
    ReleaseLockError,
    _validate_support_evidence_trees,
)
from validation.quality.src.mirmir_quality.holdout import REQUIRED_HASHES
from validation.quality.src.mirmir_quality.holdout import HashBinding


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class _BoundStub:
    _PATHS = {
        "degradation_policy": "validation/quality/policies/degradation-policy.json",
        "quality_harness_implementation_manifest": (
            "validation/quality/locks/quality-harness-implementation-manifest.json"
        ),
        "corpus_lock": "validation/quality/locks/corpus-lock.json",
    }

    def record(self, identifier: str) -> dict[str, object]:
        return {"path": self._PATHS[identifier]}


class P06ReleaseOrchestratorTests(unittest.TestCase):
    def test_python_oracle_manifest_binds_every_declared_source(self) -> None:
        manifest = _python_source_manifest(REPOSITORY_ROOT)
        self.assertEqual(manifest["implementation_role"], "independent_test_python")
        sources = manifest["sources"]
        self.assertEqual(len(sources), 4)
        for row in sources:
            path = REPOSITORY_ROOT.joinpath(*Path(row["path"]).parts)
            payload = path.read_bytes()
            self.assertEqual(row["size_bytes"], len(payload))
            self.assertEqual(row["sha256"], hashlib.sha256(payload).hexdigest())

    def test_configuration_bindings_exactly_match_holdout_fields_and_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            release = temporary_root / "release"
            p04 = temporary_root / "p04"
            release.mkdir()
            p04.mkdir()
            bindings = _configuration_bindings(
                repository_root=REPOSITORY_ROOT,
                release_root=release,
                p04_quality_root=p04,
                bound_inputs=_BoundStub(),
            )
        self.assertEqual(set(bindings), set(REQUIRED_HASHES))
        self.assertEqual(
            bindings[
                "quality_harness_implementation_manifest_sha256"
            ].digest_mode,
            "quality_harness_manifest",
        )
        self.assertEqual(
            bindings["route_luts_sha256"].digest_mode,
            "manifest_sha256",
        )
        self.assertEqual(
            bindings["corpus_manifest_sha256"].digest_mode,
            "manifest_sha256",
        )

    def test_safe_child_rejects_parent_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            with self.assertRaises(P06ReleaseOrchestrationError):
                _safe_child(root, "../outside.json")

    def test_transaction_refuses_existing_destination_before_input_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            destination = root / "release"
            destination.mkdir()
            with self.assertRaises(P06ReleaseOrchestrationError):
                build_p06_release_transaction(
                    repository_root=REPOSITORY_ROOT,
                    calibration_run_root=root,
                    release_root=destination,
                    native_cache_root=root / "native",
                    open_split_root=root,
                    evidence_root=root,
                    writer_root=root,
                    dispatch_measurement_root=root,
                    p04_quality_root=root,
                    locked_utc="2026-07-11T23:59:00Z",
                    bound_inputs=object(),
                    test_evidence_paths={},
                    preserved_failure_paths={},
                )

    def test_evidence_closure_derives_all_transitive_sets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            release = root / "release"
            run = root / "run"
            release.mkdir()
            run.mkdir()

            def make_file(relative: str) -> Path:
                path = release / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative + "\n", encoding="utf-8")
                return path

            configuration = {
                field: HashBinding(
                    path=make_file(f"configuration/{field}.json"),
                    root=release,
                    digest_mode=(
                        "quality_harness_manifest"
                        if field
                        == "quality_harness_implementation_manifest_sha256"
                        else "file_sha256"
                    ),
                )
                for field in REQUIRED_HASHES
            }
            implementation = {
                identifier: (
                    "release",
                    make_file(f"implementation/{identifier}.bin"),
                    release,
                )
                for identifier in IMPLEMENTATION_IDS
            }
            controls = {
                identifier: (
                    "release",
                    make_file(f"controls/{identifier}.json"),
                    release,
                )
                for identifier in SELECTED_CONTROL_IDS
            }
            tests = {}
            for identifier in TEST_EVIDENCE_IDS:
                directory = release / "tests" / identifier
                directory.mkdir(parents=True)
                (directory / f"{identifier}.json").write_text(
                    identifier + "\n",
                    encoding="utf-8",
                )
                tests[identifier] = ("release", directory, release)
            failures = {
                P00_FAILURE_ID: (
                    "release",
                    make_file("failures/p00.json"),
                    release,
                )
            }
            (run / "selection.json").write_text("{}\n", encoding="utf-8")
            support = {}
            for index, identifier in enumerate(SUPPORT_TREE_IDS):
                directory = root / f"support-{index}"
                directory.mkdir()
                (directory / "evidence.bin").write_bytes(identifier.encode("utf-8"))
                root_id = (
                    "open_split",
                    "calibration_evidence",
                    "native_cache",
                    "production_writer",
                    "dispatch_measurement",
                )[index]
                support[identifier] = (root_id, directory, root)
            with mock.patch(
                "validation.calibration_v2.release_evidence.hash_binding_digest",
                side_effect=lambda field, binding: hashlib.sha256(
                    field.encode("utf-8")
                ).hexdigest(),
            ):
                document = p06_evidence_closure_document(
                    configuration_id="ash-p06-test",
                    input_bundle_sha256="1" * 64,
                    corpus_lock_bundle_sha256="2" * 64,
                    configuration_bindings=configuration,
                    configuration_roots={"release": release},
                    implementation_artifacts=implementation,
                    macos_code_identities={
                        identifier: {
                            "schema_version": "1.0.0",
                            "artifact_kind": "macos_code_identity_v1",
                            "architecture": "arm64",
                            "file_sha256": ("a" if index == 0 else "b") * 64,
                            "unique_cdhash": ("c" if index == 0 else "d") * 40,
                            "all_cdhashes": [
                                ("c" if index == 0 else "d") * 40
                            ],
                            "digest_algorithms": [2],
                            "static_code_flags": 2,
                            "signing_kind": "ad_hoc",
                            "identifier": "local.mirmir.{}".format(identifier),
                        }
                        for index, identifier in enumerate(
                            (
                                "production_swift_executable",
                                "production_writer_executable",
                                "p00_native_executable",
                            )
                        )
                    },
                    selected_control_artifacts=controls,
                    support_evidence_trees=support,
                    test_evidence=tests,
                    preserved_failures=failures,
                    calibration_run_path=run,
                    calibration_run_root=root,
                )
            support_roots = {
                root_id: root
                for root_id in (
                    "open_split",
                    "calibration_evidence",
                    "native_cache",
                    "production_writer",
                    "dispatch_measurement",
                    "calibration_run",
                )
            }
            _validate_support_evidence_trees(
                document,
                support_evidence_roots=support_roots,
            )

            missing_run_root = dict(support_roots)
            del missing_run_root["calibration_run"]
            with self.assertRaisesRegex(ReleaseLockError, "roots are not exact"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=missing_run_root,
                )

            (root / "support-2/evidence.bin").write_bytes(b"changed")
            with self.assertRaisesRegex(ReleaseLockError, "changed"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=support_roots,
                )
            (root / "support-2/evidence.bin").write_bytes(
                SUPPORT_TREE_IDS[2].encode("utf-8")
            )

            (run / "selection.json").write_text(
                '{"tampered":true}\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ReleaseLockError,
                "complete_calibration_run_tree",
            ):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=support_roots,
                )
            (run / "selection.json").write_text("{}\n", encoding="utf-8")

            wrong_run_root = dict(support_roots)
            wrong_run_root["calibration_run"] = root / "support-0"
            with self.assertRaisesRegex(ReleaseLockError, "cannot be rebound"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=wrong_run_root,
                )

            mixed_root = root / "mixed-calibration-output"
            mixed_run = mixed_root / "run"
            mixed_run.mkdir(parents=True)
            (mixed_run / "selection.json").write_text(
                '{"different_run":true}\n',
                encoding="utf-8",
            )
            mixed_run_roots = dict(support_roots)
            mixed_run_roots["calibration_run"] = mixed_root
            with self.assertRaisesRegex(ReleaseLockError, "changed"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=mixed_run_roots,
                )

            real_run = root / "real-run"
            run.rename(real_run)
            run.symlink_to(real_run, target_is_directory=True)
            with self.assertRaisesRegex(ReleaseLockError, "cannot be rebound"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=support_roots,
                )
            run.unlink()
            real_run.rename(run)

            calibration_real_parent = root / "calibration-real-parent"
            calibration_alias_parent = root / "calibration-alias-parent"
            calibration_clone_root = calibration_real_parent / "output"
            calibration_clone_run = calibration_clone_root / "run"
            calibration_clone_run.mkdir(parents=True)
            (calibration_clone_run / "selection.json").write_text(
                "{}\n",
                encoding="utf-8",
            )
            calibration_alias_parent.symlink_to(
                calibration_real_parent,
                target_is_directory=True,
            )
            calibration_ancestor_link_roots = dict(support_roots)
            calibration_ancestor_link_roots["calibration_run"] = (
                calibration_alias_parent / "output"
            )
            with self.assertRaisesRegex(ReleaseLockError, "symbolic link"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=calibration_ancestor_link_roots,
                )

            support_real_parent = root / "support-real-parent"
            support_alias_parent = root / "support-alias-parent"
            support_clone_root = support_real_parent / "output"
            support_clone_tree = support_clone_root / "support-0"
            support_clone_tree.mkdir(parents=True)
            (support_clone_tree / "evidence.bin").write_bytes(
                SUPPORT_TREE_IDS[0].encode("utf-8")
            )
            support_alias_parent.symlink_to(
                support_real_parent,
                target_is_directory=True,
            )
            support_ancestor_link_roots = dict(support_roots)
            support_ancestor_link_roots["open_split"] = support_alias_parent / "output"
            with self.assertRaisesRegex(ReleaseLockError, "symbolic link"):
                _validate_support_evidence_trees(
                    document,
                    support_evidence_roots=support_ancestor_link_roots,
                )
        self.assertEqual(
            [row["id"] for row in document["configuration_bindings"]],
            list(REQUIRED_HASHES),
        )
        self.assertEqual(
            [row["id"] for row in document["implementation_artifacts"]],
            list(IMPLEMENTATION_IDS),
        )
        self.assertEqual(
            [row["id"] for row in document["support_evidence_trees"]],
            list(SUPPORT_TREE_IDS),
        )
        self.assertEqual(
            [row["id"] for row in document["test_evidence"]],
            list(TEST_EVIDENCE_IDS),
        )
        self.assertTrue(
            all(row["kind"] == "directory_tree" for row in document["test_evidence"])
        )
        self.assertEqual(document["holdout_accessed"], False)


if __name__ == "__main__":
    unittest.main()
