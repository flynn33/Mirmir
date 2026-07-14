from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
from typing import Mapping

from validation.calibration_v2 import release_orchestrator as orchestrator
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
from validation.calibration_v2.tests.native_benchmark_fixture import (
    thaw_and_remove_runtime_fixture,
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


class _TransactionBoundStub:
    def verify_unchanged(self) -> None:
        return None


class P06ReleaseOrchestratorTests(unittest.TestCase):
    LOCKED_UTC = "2026-07-11T23:59:00Z"

    @staticmethod
    def _transaction_arguments(
        root: Path,
        destination: Path,
    ) -> dict[str, object]:
        support_paths = {
            "calibration_run_root": root / "support-calibration-run" / "run",
            "native_cache_root": root / "support-native-cache" / "cache",
            "open_split_root": root / "support-open-split",
            "evidence_root": root / "support-evidence" / "evidence",
            "writer_root": root / "support-writer" / "writer",
            "dispatch_measurement_root": (
                root / "support-dispatch" / "measurement"
            ),
            "p04_quality_root": root / "support-p04",
        }
        for path in support_paths.values():
            path.mkdir(parents=True, exist_ok=True)
            fixture = path / "fixture.bin"
            if not fixture.exists():
                fixture.write_bytes(b"support fixture\n")
        return {
            "repository_root": REPOSITORY_ROOT,
            "release_root": destination,
            **support_paths,
            "locked_utc": P06ReleaseOrchestratorTests.LOCKED_UTC,
            "bound_inputs": _TransactionBoundStub(),
            "test_evidence_paths": {},
            "preserved_failure_paths": {},
        }

    @classmethod
    def _fake_bundle(cls) -> dict[str, object]:
        return {"locked_utc": cls.LOCKED_UTC}

    @classmethod
    def _publish_fake_release(cls, **arguments: object) -> dict[str, object]:
        release = Path(arguments["release_root"])
        (release / "p06-release-bundle.json").write_bytes(b"{}\n")
        (release / "payload.bin").write_bytes(b"bound\n")
        return cls._fake_bundle()

    @staticmethod
    def _thaw_recognized(root: Path) -> None:
        for path in (
            root / "release",
            root / "release.failed",
            root / ".release.partial",
            *root.glob(".release.quarantine-*"),
        ):
            thaw_and_remove_runtime_fixture(path)

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
            with mock.patch.object(
                orchestrator,
                "_repository_state",
                return_value=({"snapshot": "clean"}, True),
            ), self.assertRaises(P06ReleaseOrchestrationError):
                build_p06_release_transaction(
                    **self._transaction_arguments(root, destination)
                )

    def test_transaction_rejects_an_unbound_repository_root(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-unbound-repository-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            arguments = self._transaction_arguments(root, root / "release")
            arguments["repository_root"] = root
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "bound release orchestrator checkout",
            ):
                build_p06_release_transaction(**arguments)

    def test_transaction_rejects_repository_drift_before_publication(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-repository-drift-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            initial_state = {"snapshot": "initial"}
            changed_state = {"snapshot": "changed"}

            def publish(**arguments: object) -> dict[str, object]:
                release = Path(arguments["release_root"])
                (release / "p06-release-bundle.json").write_bytes(b"{}\n")
                return self._fake_bundle()

            with mock.patch.object(
                orchestrator,
                "_repository_state",
                side_effect=(
                    (initial_state, True),
                    (changed_state, True),
                ),
            ), mock.patch.object(
                orchestrator,
                "_publish_release",
                side_effect=publish,
            ), self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "repository state changed",
            ):
                build_p06_release_transaction(
                    **self._transaction_arguments(root, destination)
                )

            failed = root / "release.failed"
            self.assertFalse(destination.exists())
            self.assertFalse((root / ".release.partial").exists())
            self.assertTrue(failed.is_dir())
            self.assertTrue((failed / "release-failure.json").is_file())
            thaw_and_remove_runtime_fixture(failed)

    def test_failure_evidence_error_is_propagated_after_quarantine(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-postrename-failure-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    side_effect=P06ReleaseOrchestrationError(
                        "injected semantic validation failure"
                    ),
                ), mock.patch.object(
                    orchestrator,
                    "_write_release_failure_evidence",
                    side_effect=OSError("injected failure-evidence write failure"),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "cleanup failed",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertFalse(destination.exists())
                failed = root / "release.failed"
                marker = root / ".release.transaction.jsonl"
                self.assertTrue(failed.is_dir())
                self.assertTrue(marker.is_file())
                self.assertFalse(
                    (failed / "release-failure-manifest.json").exists()
                )

                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "failure publication was recovered",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertFalse(marker.exists())
                self.assertTrue(
                    (failed / "release-failure-manifest.json").is_file()
                )
            finally:
                self._thaw_recognized(root)

    def test_completed_rename_followed_by_error_still_quarantines_destination(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-rename-error-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            original_rename = orchestrator._rename_release_exclusive_at
            rename_count = 0

            def rename_then_fail(
                parent_descriptor: int,
                source_name: str,
                target_name: str,
            ) -> None:
                nonlocal rename_count
                rename_count += 1
                original_rename(parent_descriptor, source_name, target_name)
                if rename_count == 1:
                    raise P06ReleaseOrchestrationError(
                        "injected post-rename directory sync failure"
                    )
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_rename_release_exclusive_at",
                    side_effect=rename_then_fail,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "post-rename directory sync failure",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )

                self.assertGreaterEqual(rename_count, 2)
                self.assertFalse(destination.exists())
                self.assertTrue((root / "release.failed").is_dir())
            finally:
                self._thaw_recognized(root)

    def test_durable_marker_recovers_crash_after_failed_rename(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-failed-rename-crash-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            failed = root / "release.failed"
            marker = root / ".release.transaction.jsonl"
            state = {"snapshot": "clean"}
            original_rename = orchestrator._rename_release_exclusive_at

            def rename_then_crash(
                parent_descriptor: int,
                source_name: str,
                target_name: str,
            ) -> None:
                original_rename(parent_descriptor, source_name, target_name)
                if target_name == failed.name:
                    raise KeyboardInterrupt("simulated death after failed rename")

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    side_effect=P06ReleaseOrchestrationError(
                        "injected semantic validation failure"
                    ),
                ), mock.patch.object(
                    orchestrator,
                    "_rename_release_exclusive_at",
                    side_effect=rename_then_crash,
                ), self.assertRaises(KeyboardInterrupt):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )

                self.assertTrue(failed.is_dir())
                self.assertTrue(marker.is_file())
                self.assertFalse(
                    (failed / "release-failure-manifest.json").exists()
                )
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "failure publication was recovered",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertFalse(marker.exists())
                manifest = json.loads(
                    (failed / "release-failure-manifest.json").read_bytes()
                )
                self.assertEqual(manifest["schema_version"], "2.0.0")
                self.assertEqual(
                    manifest["filesystem_closure_rule"],
                    "all_entries_except_failure_manifest_v1",
                )
                observed_paths = {
                    path.relative_to(failed).as_posix()
                    for path in failed.rglob("*")
                    if path.name != "release-failure-manifest.json"
                }
                self.assertEqual(
                    {row["path"] for row in manifest["filesystem_closure"]},
                    observed_paths,
                )
                self.assertEqual(manifest["schema_version"], "2.0.0")
                self.assertEqual(
                    manifest["filesystem_closure_rule"],
                    "all_entries_except_failure_manifest_v1",
                )
            finally:
                self._thaw_recognized(root)

    def test_parent_replacement_never_promotes_a_foreign_partial(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-parent-replacement-"
        ) as temporary:
            container = Path(temporary).resolve(strict=True)
            root = container / "release-parent"
            root.mkdir()
            moved = container / "owned-parent-moved"
            destination = root / "release"
            state = {"snapshot": "clean"}

            def publish(**arguments: object) -> dict[str, object]:
                release = Path(arguments["release_root"])
                (release / "p06-release-bundle.json").write_bytes(b"{}\n")
                (release / "payload.bin").write_bytes(b"owned\n")
                root.rename(moved)
                root.mkdir()
                foreign = root / ".release.partial"
                foreign.mkdir()
                (foreign / "foreign.txt").write_bytes(b"foreign\n")
                return self._fake_bundle()

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=publish,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "parent identity changed",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertFalse(destination.exists())
                self.assertEqual(
                    (root / ".release.partial" / "foreign.txt").read_bytes(),
                    b"foreign\n",
                )
                self.assertTrue((moved / "release.failed").is_dir())
            finally:
                thaw_and_remove_runtime_fixture(moved / "release.failed")

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_postseal_validation_failure_is_immutable_and_manifest_bound(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-postseal-failure-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            validation_count = 0

            def validate(**arguments: object) -> dict[str, object]:
                nonlocal validation_count
                validation_count += 1
                if validation_count == 3:
                    self.assertTrue(
                        (root / ".release.transaction.jsonl").is_file()
                    )
                    raise P06ReleaseOrchestrationError(
                        "injected postseal support validation failure"
                    )
                return self._fake_bundle()

            failed = root / "release.failed"
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    side_effect=validate,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "postseal support validation failure",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertEqual(validation_count, 3)
                self.assertFalse(destination.exists())
                self.assertTrue(failed.is_dir())
                failure = json.loads(
                    (failed / "release-failure.json").read_bytes()
                )
                manifest = json.loads(
                    (failed / "release-failure-manifest.json").read_bytes()
                )
                self.assertEqual(failure["transaction_stage"], "root_sealed")
                self.assertEqual(
                    failure["cleanup_outcome"],
                    "owned_inode_quarantined",
                )
                self.assertEqual(
                    manifest["artifacts"][0]["sha256"],
                    hashlib.sha256(
                        (failed / "release-failure.json").read_bytes()
                    ).hexdigest(),
                )
                marker_copy = failed / "release-transaction-marker.jsonl"
                marker_binding = next(
                    row
                    for row in manifest["artifacts"]
                    if row["path"] == marker_copy.name
                )
                self.assertEqual(
                    marker_binding,
                    {
                        "path": marker_copy.name,
                        "sha256": hashlib.sha256(
                            marker_copy.read_bytes()
                        ).hexdigest(),
                        "size_bytes": len(marker_copy.read_bytes()),
                    },
                )
                for path in (
                    failed,
                    failed / "release-failure.json",
                    failed / "release-failure-manifest.json",
                    marker_copy,
                ):
                    metadata = path.lstat()
                    self.assertEqual(metadata.st_mode & 0o222, 0)
                    self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)
            finally:
                thaw_and_remove_runtime_fixture(failed)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_final_support_snapshot_detects_postvalidation_mode_change(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-final-support-snapshot-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            arguments = self._transaction_arguments(root, destination)
            support_file = (
                Path(arguments["open_split_root"]) / "fixture.bin"
            )
            validation_count = 0

            def validate(**unused: object) -> dict[str, object]:
                nonlocal validation_count
                validation_count += 1
                if validation_count == 3:
                    support_file.chmod(0o400)
                return self._fake_bundle()

            failed = root / "release.failed"
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    side_effect=validate,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "support tree content or metadata changed",
                ):
                    build_p06_release_transaction(**arguments)
                self.assertEqual(validation_count, 3)
                self.assertFalse(destination.exists())
                self.assertTrue(failed.is_dir())
                self.assertFalse(
                    (root / ".release.transaction.jsonl").exists()
                )
            finally:
                support_file.chmod(0o600)
                self._thaw_recognized(root)

    def test_fifo_is_rejected_without_blocking_before_file_open(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-fifo-rejection-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            os.mkfifo(root / "substituted.fifo")
            descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "non-regular file",
                ):
                    orchestrator._release_tree_snapshot(
                        descriptor,
                        require_frozen=False,
                    )
            finally:
                os.close(descriptor)

    def test_failure_manifest_rejects_extra_entry_and_historical_version(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-failure-closure-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            transaction_id = "a" * 32
            try:
                orchestrator._write_release_failure_evidence(
                    descriptor,
                    error=RuntimeError("synthetic failure"),
                    stage="synthetic_stage",
                    outcome="owned_inode_quarantined",
                    outcome_name="release.failed",
                    transaction_id=transaction_id,
                    marker_payload=b'{"synthetic":true}\n',
                    root_identity=os.fstat(descriptor),
                )
                orchestrator._validate_release_failure_evidence(
                    descriptor,
                    transaction_id=transaction_id,
                    expected_marker_payload=b'{"synthetic":true}\n',
                    require_frozen=False,
                )
                extra = root / "unbound.bin"
                extra.write_bytes(b"unbound\n")
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "filesystem closure changed",
                ):
                    orchestrator._validate_release_failure_evidence(
                        descriptor,
                        transaction_id=transaction_id,
                        expected_marker_payload=b'{"synthetic":true}\n',
                        require_frozen=False,
                    )
                extra.unlink()
                manifest_path = root / "release-failure-manifest.json"
                historical = json.loads(manifest_path.read_bytes())
                historical["schema_version"] = "1.0.0"
                historical["manifest_sha256"] = orchestrator.manifest_sha256(
                    historical
                )
                manifest_path.write_bytes(
                    orchestrator.canonical_json_bytes(historical) + b"\n"
                )
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "manifest identity differs",
                ):
                    orchestrator._validate_release_failure_evidence(
                        descriptor,
                        transaction_id=transaction_id,
                        expected_marker_payload=b'{"synthetic":true}\n',
                        require_frozen=False,
                    )
            finally:
                os.close(descriptor)

    def test_failure_manifest_rejects_rehashed_marker_copy_substitution(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-failure-marker-binding-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            transaction_id = "b" * 32
            expected_marker = b'{"synthetic":true}\n'
            try:
                orchestrator._write_release_failure_evidence(
                    descriptor,
                    error=RuntimeError("synthetic failure"),
                    stage="synthetic_stage",
                    outcome="owned_inode_quarantined",
                    outcome_name="release.failed",
                    transaction_id=transaction_id,
                    marker_payload=expected_marker,
                    root_identity=os.fstat(descriptor),
                )
                substituted_marker = b'{"synthetic":false}\n'
                marker_path = root / "release-transaction-marker.jsonl"
                marker_path.write_bytes(substituted_marker)
                manifest_path = root / "release-failure-manifest.json"
                manifest = json.loads(manifest_path.read_bytes())
                marker_sha256 = hashlib.sha256(substituted_marker).hexdigest()
                for collection in (
                    manifest["artifacts"],
                    manifest["filesystem_closure"],
                ):
                    row = next(
                        item
                        for item in collection
                        if item["path"] == marker_path.name
                    )
                    row["sha256"] = marker_sha256
                    row["size_bytes"] = len(substituted_marker)
                manifest["manifest_sha256"] = orchestrator.manifest_sha256(
                    manifest
                )
                manifest_path.write_bytes(
                    orchestrator.canonical_json_bytes(manifest) + b"\n"
                )
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "differs from durable marker",
                ):
                    orchestrator._validate_release_failure_evidence(
                        descriptor,
                        transaction_id=transaction_id,
                        expected_marker_payload=expected_marker,
                        require_frozen=False,
                    )
            finally:
                os.close(descriptor)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_real_bundle_publication_validates_with_owned_transaction_token(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-real-bundle-token-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            selected_path = f"evaluations/{'b' * 64}.json"
            artifact_paths = (
                "calibration-selection.json",
                selected_path,
                "calibration-run-ledger.json",
                "live-holdout-preopen-verification.json",
                "dispatch-measurement.json",
                "locked-mapping.json",
                "locked-operator-bank.json",
                "locked-quality-policy.json",
                "locked-metric-policy.json",
                "locked-compiler-input.json",
                "route-analysis-grid-selection.json",
                "direct2x.ashlut",
                "direct3over2.ashlut",
                "native-lut-parity-manifest.json",
                "lut-manifest.json",
                "configuration-lock.json",
                "p06-evidence-closure.json",
            )
            observed_transaction_ids: list[str] = []

            def publish(**arguments: object) -> Mapping[str, object]:
                release = Path(arguments["release_root"])
                transaction_id = str(arguments["transaction_id"])
                observed_transaction_ids.append(transaction_id)
                self.assertEqual(
                    (release / orchestrator.P06_TRANSACTION_TOKEN_NAME).read_bytes(),
                    f"{transaction_id}\n".encode("ascii"),
                )
                for index, relative in enumerate(artifact_paths):
                    path = release.joinpath(*Path(relative).parts)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    payload = b"{}\n" if relative.endswith(".json") else (
                        f"artifact-{index}\n".encode("ascii")
                    )
                    path.write_bytes(payload)
                return orchestrator.build_p06_release_bundle_manifest(
                    release_root=release,
                    output_path=release / "p06-release-bundle.json",
                    configuration_id="ash-p06-spatial-v2-token-test",
                    locked_utc=self.LOCKED_UTC,
                    input_bundle_sha256="1" * 64,
                    corpus_lock_bundle_sha256="2" * 64,
                    selected_evaluation_path=selected_path,
                    transaction_id=transaction_id,
                )

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=publish,
                ), mock.patch(
                    "validation.calibration_v2.release_lock."
                    "_validate_p06_release_cross_bindings"
                ), mock.patch(
                    "validation.calibration_v2.release_lock."
                    "_validate_support_evidence_trees"
                ):
                    result = build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                    reopened = orchestrator.validate_p06_release_bundle_manifest(
                        release_root=destination,
                        manifest_path=destination / "p06-release-bundle.json",
                    )

                self.assertEqual(result, reopened)
                self.assertEqual(len(observed_transaction_ids), 1)
                self.assertFalse(
                    (destination / orchestrator.P06_TRANSACTION_TOKEN_NAME).exists()
                )
            finally:
                self._thaw_recognized(root)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_successful_transaction_returns_only_a_sealed_release(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-success-sealing-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}

            def publish(**arguments: object) -> dict[str, object]:
                release = Path(arguments["release_root"])
                (release / "p06-release-bundle.json").write_bytes(b"{}\n")
                executable = release / "bin" / "tool"
                executable.parent.mkdir()
                executable.write_bytes(b"executable\n")
                executable.chmod(0o700)
                (release / "payload.bin").write_bytes(b"payload\n")
                return self._fake_bundle()

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=publish,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ) as validate:
                    result = build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )

                self.assertEqual(result, self._fake_bundle())
                self.assertEqual(validate.call_count, 3)
                for path in (destination, destination / "bin"):
                    metadata = path.lstat()
                    self.assertEqual(
                        metadata.st_mode
                        & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH),
                        0,
                    )
                    self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)
                for path in (
                    destination / "p06-release-bundle.json",
                    destination / "payload.bin",
                    destination / "bin" / "tool",
                ):
                    metadata = path.lstat()
                    self.assertEqual(
                        metadata.st_mode
                        & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH),
                        0,
                    )
                    self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)
                self.assertNotEqual(
                    (destination / "bin" / "tool").stat().st_mode
                    & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH),
                    0,
                )
                self.assertEqual(
                    (destination / "payload.bin").stat().st_mode
                    & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH),
                    0,
                )
            finally:
                thaw_and_remove_runtime_fixture(destination)

    def test_raced_failure_path_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-failure-collision-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            state = {"snapshot": "clean"}
            failed = root / "release.failed"

            def publish(**arguments: object) -> dict[str, object]:
                release = Path(arguments["release_root"])
                (release / "p06-release-bundle.json").write_bytes(b"{}\n")
                (release / "payload.bin").write_bytes(b"bound\n")
                failed.mkdir()
                (failed / "foreign.txt").write_bytes(b"foreign\n")
                return self._fake_bundle()

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=publish,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "already exists",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )

                self.assertEqual(
                    (failed / "foreign.txt").read_bytes(),
                    b"foreign\n",
                )
                self.assertFalse((root / ".release.partial").exists())
                self.assertFalse(destination.exists())
                quarantines = list(root.glob(".release.quarantine-*"))
                self.assertEqual(len(quarantines), 1)
                self.assertTrue(
                    (quarantines[0] / "release-failure.json").is_file()
                )
            finally:
                self._thaw_recognized(root)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_total_failure_rename_outage_is_propagated_and_sealed(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-failure-rename-outage-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            partial = root / ".release.partial"
            state = {"snapshot": "clean"}
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_rename_release_exclusive_at",
                    side_effect=P06ReleaseOrchestrationError(
                        "injected total rename outage"
                    ),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "cleanup failed",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertTrue(partial.is_dir())
                failure = json.loads((partial / "release-failure.json").read_bytes())
                self.assertEqual(
                    failure["cleanup_outcome"],
                    "cleanup_failed_owned_inode_retained",
                )
                self.assertEqual(partial.stat().st_mode & 0o222, 0)
                self.assertNotEqual(
                    partial.stat().st_flags & stat.UF_IMMUTABLE,
                    0,
                )
                self.assertFalse((root / ".release.transaction.jsonl").exists())
            finally:
                thaw_and_remove_runtime_fixture(partial)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_quarantine_rename_outage_never_writes_failure_under_success_name(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-success-name-quarantine-outage-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            marker = root / ".release.transaction.jsonl"
            state = {"snapshot": "clean"}
            original_rename = orchestrator._rename_release_exclusive_at

            def publish_only_rename(
                parent_descriptor: int,
                source_name: str,
                target_name: str,
            ) -> None:
                if source_name == ".release.partial" and target_name == "release":
                    original_rename(parent_descriptor, source_name, target_name)
                    return
                raise P06ReleaseOrchestrationError(
                    "injected quarantine rename outage"
                )

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_rename_release_exclusive_at",
                    side_effect=publish_only_rename,
                ), mock.patch.object(
                    orchestrator,
                    "_seal_release_root",
                    side_effect=P06ReleaseOrchestrationError(
                        "injected root seal failure"
                    ),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "retained the success-named release and durable marker",
                ):
                    build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )

                self.assertTrue(destination.is_dir())
                self.assertTrue(marker.is_file())
                self.assertFalse((destination / "release-failure.json").exists())
                self.assertFalse(
                    (destination / "release-failure-manifest.json").exists()
                )

                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ):
                    recovered = build_p06_release_transaction(
                        **self._transaction_arguments(root, destination)
                    )
                self.assertEqual(recovered, self._fake_bundle())
                self.assertFalse(marker.exists())
                self.assertFalse((destination / "release-failure.json").exists())
            finally:
                self._thaw_recognized(root)

    def test_interrupted_initial_marker_stage_is_discovered_and_resumed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-initial-marker-resume-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            transaction_id = "1" * 32
            event = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            expected_payload = orchestrator.canonical_json_bytes(event) + b"\n"
            staging_name = f"{marker_name}.creating-{transaction_id}"
            staging_descriptor = os.open(
                staging_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=parent_descriptor,
            )
            try:
                prefix = expected_payload[: len(expected_payload) // 2]
                self.assertEqual(
                    os.write(staging_descriptor, prefix),
                    len(prefix),
                )
                os.fsync(staging_descriptor)
            finally:
                os.close(staging_descriptor)
            os.fsync(parent_descriptor)

            try:
                self.assertEqual(
                    orchestrator._transaction_marker_creation_id_at(
                        parent_descriptor,
                        marker_name,
                    ),
                    transaction_id,
                )
                marker_descriptor, _ = orchestrator._create_transaction_marker(
                    parent_descriptor,
                    marker_name,
                    event,
                )
                os.close(marker_descriptor)
                self.assertFalse((root / staging_name).exists())
                self.assertEqual((root / marker_name).read_bytes(), expected_payload)
                reopened, _, events = orchestrator._read_transaction_marker_at(
                    parent_descriptor,
                    marker_name,
                )
                os.close(reopened)
                self.assertEqual(events, (event,))
            finally:
                os.close(parent_descriptor)

    def test_initial_marker_rejects_same_content_inode_replacement(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-initial-marker-replacement-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            transaction_id = "8" * 32
            event = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            real_rename = orchestrator._rename_transaction_file_exclusive_at
            identities: dict[str, tuple[int, int]] = {}

            def replace_before_rename(
                directory_descriptor: int,
                source_name: str,
                destination_name: str,
            ) -> None:
                payload, staged = orchestrator._read_regular_at(
                    directory_descriptor,
                    source_name,
                )
                identities["staged"] = orchestrator._identity(staged)
                os.unlink(source_name, dir_fd=directory_descriptor)
                replacement = orchestrator._write_new_at(
                    directory_descriptor,
                    source_name,
                    payload,
                )
                identities["replacement"] = orchestrator._identity(replacement)
                real_rename(
                    directory_descriptor,
                    source_name,
                    destination_name,
                )

            try:
                with mock.patch.object(
                    orchestrator,
                    "_rename_transaction_file_exclusive_at",
                    side_effect=replace_before_rename,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "published P06 transaction marker differs",
                ):
                    orchestrator._create_transaction_marker(
                        parent_descriptor,
                        marker_name,
                        event,
                    )

                marker_metadata = os.stat(
                    marker_name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                self.assertNotEqual(
                    identities["staged"],
                    identities["replacement"],
                )
                self.assertEqual(
                    orchestrator._identity(marker_metadata),
                    identities["replacement"],
                )
                self.assertEqual(
                    (root / marker_name).read_bytes(),
                    orchestrator.canonical_json_bytes(event) + b"\n",
                )
                self.assertFalse(
                    (root / f"{marker_name}.creating-{transaction_id}").exists()
                )
            finally:
                os.close(parent_descriptor)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_build_adopts_interrupted_initial_marker_transaction_id(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-build-marker-resume-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            marker_name = ".release.transaction.jsonl"
            transaction_id = "7" * 32
            state = {"snapshot": "clean"}
            arguments = self._transaction_arguments(root, destination)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            event = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name=destination.name,
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state=state,
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            payload = orchestrator.canonical_json_bytes(event) + b"\n"
            staging = root / f"{marker_name}.creating-{transaction_id}"
            staging.write_bytes(payload[: len(payload) // 3])
            os.close(parent_descriptor)
            observed_transaction_ids: list[str] = []

            def publish(**publish_arguments: object) -> dict[str, object]:
                observed_transaction_ids.append(
                    str(publish_arguments["transaction_id"])
                )
                return self._publish_fake_release(**publish_arguments)

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=publish,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ):
                    result = build_p06_release_transaction(**arguments)

                self.assertEqual(result, self._fake_bundle())
                self.assertEqual(observed_transaction_ids, [transaction_id])
                self.assertTrue(destination.is_dir())
                self.assertFalse(staging.exists())
            finally:
                self._thaw_recognized(root)

    def test_transaction_append_handles_repeated_short_writes(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-short-marker-writes-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            initial = orchestrator._transaction_event(
                transaction_id="2" * 32,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                initial,
            )
            appended = orchestrator._transaction_event(
                transaction_id="2" * 32,
                sequence=1,
                stage="partial_created",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=os.fstat(parent_descriptor),
            )
            real_write = os.write

            def short_write(descriptor: int, payload: bytes) -> int:
                return real_write(descriptor, payload[: min(len(payload), 7)])

            try:
                with mock.patch.object(
                    orchestrator.os,
                    "write",
                    side_effect=short_write,
                ):
                    orchestrator._append_transaction_event(
                        parent_descriptor,
                        marker_name,
                        marker_descriptor,
                        appended,
                    )
                os.close(marker_descriptor)
                marker_descriptor = -1
                reopened, _, events = orchestrator._read_transaction_marker_at(
                    parent_descriptor,
                    marker_name,
                )
                os.close(reopened)
                self.assertEqual(events, (initial, appended))
                self.assertEqual(
                    orchestrator._transaction_append_entries_at(
                        parent_descriptor,
                        marker_name,
                    ),
                    (),
                )
            finally:
                if marker_descriptor >= 0:
                    os.close(marker_descriptor)
                os.close(parent_descriptor)

    def test_append_error_rolls_back_marker_and_removes_sidecar(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-marker-rollback-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            initial = orchestrator._transaction_event(
                transaction_id="3" * 32,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                initial,
            )
            initial_payload = (root / marker_name).read_bytes()
            marker_identity = os.fstat(marker_descriptor)
            appended = orchestrator._transaction_event(
                transaction_id="3" * 32,
                sequence=1,
                stage="partial_created",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=os.fstat(parent_descriptor),
            )
            real_write = os.write
            marker_write_count = 0

            def interrupted_write(descriptor: int, payload: bytes) -> int:
                nonlocal marker_write_count
                if (
                    orchestrator._identity(os.fstat(descriptor))
                    == orchestrator._identity(marker_identity)
                ):
                    marker_write_count += 1
                    if marker_write_count == 1:
                        return real_write(descriptor, payload[:11])
                    raise OSError("simulated marker write interruption")
                return real_write(descriptor, payload)

            try:
                with mock.patch.object(
                    orchestrator.os,
                    "write",
                    side_effect=interrupted_write,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "append was incomplete",
                ):
                    orchestrator._append_transaction_event(
                        parent_descriptor,
                        marker_name,
                        marker_descriptor,
                        appended,
                    )
                self.assertEqual((root / marker_name).read_bytes(), initial_payload)
                self.assertEqual(
                    orchestrator._transaction_append_entries_at(
                        parent_descriptor,
                        marker_name,
                    ),
                    (),
                )
            finally:
                os.close(marker_descriptor)
                os.close(parent_descriptor)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 failure sealing requires macOS user-immutable flags",
    )
    def test_append_sidecar_unlink_failure_recovers_without_orphan(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-sidecar-unlink-recovery-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            marker = root / ".release.transaction.jsonl"
            failed = root / "release.failed"
            state = {"snapshot": "clean"}
            arguments = self._transaction_arguments(root, destination)
            real_unlink = orchestrator._unlink_owned_transaction_file
            failures_remaining = 2

            def fail_published_sidecar_unlink(
                parent_descriptor: int,
                name: str,
                expected: os.stat_result,
            ) -> None:
                nonlocal failures_remaining
                if (
                    ".append-" in name
                    and not name.endswith(".creating")
                    and failures_remaining > 0
                ):
                    failures_remaining -= 1
                    raise P06ReleaseOrchestrationError(
                        "injected published-sidecar unlink failure"
                    )
                real_unlink(parent_descriptor, name, expected)

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    side_effect=self._publish_fake_release,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_unlink_owned_transaction_file",
                    side_effect=fail_published_sidecar_unlink,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "injected published-sidecar unlink failure",
                ):
                    build_p06_release_transaction(**arguments)

                sidecars = tuple(root.glob(f"{marker.name}.append-*"))
                self.assertEqual(len(sidecars), 1)
                self.assertTrue(marker.is_file())
                self.assertTrue(failed.is_dir())
                self.assertFalse(
                    (failed / "release-failure-manifest.json").exists()
                )

                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "failure publication was recovered",
                ):
                    build_p06_release_transaction(**arguments)

                self.assertFalse(marker.exists())
                self.assertFalse(sidecars[0].exists())
                self.assertTrue(
                    (failed / "release-failure-manifest.json").is_file()
                )
            finally:
                self._thaw_recognized(root)

    def test_unbound_marker_tail_is_rejected_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-unbound-marker-tail-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            event = orchestrator._transaction_event(
                transaction_id="4" * 32,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                event,
            )
            self.assertEqual(os.write(marker_descriptor, b"foreign-tail"), 12)
            os.fsync(marker_descriptor)
            os.close(marker_descriptor)
            before = (root / marker_name).read_bytes()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "no durable append intent",
                ):
                    orchestrator._read_transaction_marker_at(
                        parent_descriptor,
                        marker_name,
                    )
                self.assertEqual((root / marker_name).read_bytes(), before)
            finally:
                os.close(parent_descriptor)

    def test_incomplete_append_creation_sidecar_is_preserved_and_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-incomplete-sidecar-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            transaction_id = "6" * 32
            initial = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                initial,
            )
            os.close(marker_descriptor)
            appended = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=1,
                stage="partial_created",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=os.fstat(parent_descriptor),
            )
            sidecar_name = (
                f"{marker_name}.append-{transaction_id}-1-"
                f"{appended['event_sha256']}.creating"
            )
            sidecar = root / sidecar_name
            sidecar.write_bytes(
                (orchestrator.canonical_json_bytes(appended) + b"\n")[:31]
            )
            before_marker = root.joinpath(marker_name).read_bytes()
            before_sidecar = sidecar.read_bytes()
            try:
                with self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "creation stage is incomplete",
                ):
                    orchestrator._read_transaction_marker_at(
                        parent_descriptor,
                        marker_name,
                    )
                self.assertEqual(root.joinpath(marker_name).read_bytes(), before_marker)
                self.assertEqual(sidecar.read_bytes(), before_sidecar)
            finally:
                os.close(parent_descriptor)

    def test_marker_reopen_rejects_same_inode_byte_mutation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-marker-mutation-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            marker_name = ".release.transaction.jsonl"
            event = orchestrator._transaction_event(
                transaction_id="1" * 32,
                sequence=0,
                stage="intent_durable",
                destination_name="release",
                partial_name=".release.partial",
                failed_name="release.failed",
                locked_utc=self.LOCKED_UTC,
                repository_state={"snapshot": "clean"},
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                event,
            )
            os.close(marker_descriptor)
            original_read = orchestrator._read_regular_at
            mutated = False

            def read_then_mutate(
                directory_descriptor: int,
                name: str,
            ) -> tuple[bytes, os.stat_result]:
                nonlocal mutated
                result = original_read(directory_descriptor, name)
                if name == marker_name and not mutated:
                    mutated = True
                    descriptor = os.open(
                        name,
                        os.O_WRONLY | os.O_TRUNC,
                        dir_fd=directory_descriptor,
                    )
                    try:
                        payload = b"x" * len(result[0])
                        self.assertEqual(os.write(descriptor, payload), len(payload))
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                return result

            try:
                with mock.patch.object(
                    orchestrator,
                    "_read_regular_at",
                    side_effect=read_then_mutate,
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "changed while reopening",
                ):
                    orchestrator._read_transaction_marker_at(
                        parent_descriptor,
                        marker_name,
                    )
            finally:
                os.close(parent_descriptor)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 failure sealing requires macOS user-immutable flags",
    )
    def test_first_append_tail_recovers_through_token_bound_failure_evidence(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-first-append-tail-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            partial = root / ".release.partial"
            marker_name = ".release.transaction.jsonl"
            failed = root / "release.failed"
            transaction_id = "5" * 32
            state = {"snapshot": "clean"}
            arguments = self._transaction_arguments(root, destination)
            parent_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            initial = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                locked_utc=self.LOCKED_UTC,
                repository_state=state,
                parent_identity=os.fstat(parent_descriptor),
                root_identity=None,
            )
            marker_descriptor, _ = orchestrator._create_transaction_marker(
                parent_descriptor,
                marker_name,
                initial,
            )
            initial_payload = root.joinpath(marker_name).read_bytes()
            os.mkdir(partial.name, 0o700, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
            partial_identity = os.stat(
                partial.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            partial_descriptor = os.open(
                partial.name,
                os.O_RDONLY | os.O_DIRECTORY,
                dir_fd=parent_descriptor,
            )
            try:
                orchestrator._write_new_at(
                    partial_descriptor,
                    orchestrator.P06_TRANSACTION_TOKEN_NAME,
                    f"{transaction_id}\n".encode("ascii"),
                )
            finally:
                os.close(partial_descriptor)
            appended = orchestrator._transaction_event(
                transaction_id=transaction_id,
                sequence=1,
                stage="partial_created",
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                locked_utc=self.LOCKED_UTC,
                repository_state=state,
                parent_identity=os.fstat(parent_descriptor),
                root_identity=partial_identity,
            )
            appended_payload = orchestrator.canonical_json_bytes(appended) + b"\n"
            sidecar_name = (
                f"{marker_name}.append-{transaction_id}-1-"
                f"{appended['event_sha256']}"
            )
            orchestrator._write_new_at(
                parent_descriptor,
                sidecar_name,
                appended_payload,
            )
            tail = appended_payload[: len(appended_payload) // 2]
            self.assertEqual(os.write(marker_descriptor, tail), len(tail))
            os.fsync(marker_descriptor)
            os.close(marker_descriptor)
            os.close(parent_descriptor)

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), self.assertRaisesRegex(
                    P06ReleaseOrchestrationError,
                    "p06-release-bundle.json",
                ):
                    build_p06_release_transaction(**arguments)

                self.assertTrue(failed.is_dir())
                self.assertFalse(partial.exists())
                self.assertFalse(root.joinpath(marker_name).exists())
                self.assertFalse(root.joinpath(sidecar_name).exists())
                marker_copy = failed / "release-transaction-marker.jsonl"
                self.assertEqual(marker_copy.read_bytes(), initial_payload)
                failure = json.loads(
                    (failed / "release-failure.json").read_bytes()
                )
                self.assertEqual(failure["transaction_id"], transaction_id)
                self.assertEqual(
                    failure["cleanup_outcome"],
                    "owned_inode_quarantined",
                )
            finally:
                self._thaw_recognized(root)

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_root_sealed_sidecar_before_append_recovers_final(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-root-sealed-sidecar-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            marker = root / ".release.transaction.jsonl"
            state = {"snapshot": "clean"}
            arguments = self._transaction_arguments(root, destination)
            publisher = mock.Mock(side_effect=self._publish_fake_release)
            real_append = orchestrator._append_transaction_event
            crashed = False
            staged_sidecar: Path | None = None

            def crash_before_root_sealed_append(
                parent_descriptor: int,
                marker_name: str,
                marker_descriptor: int,
                event: Mapping[str, object],
            ) -> None:
                nonlocal crashed, staged_sidecar
                if event.get("stage") == "root_sealed" and not crashed:
                    crashed = True
                    sidecar_name = (
                        f"{marker_name}.append-{event['transaction_id']}-"
                        f"{event['sequence']}-{event['event_sha256']}"
                    )
                    orchestrator._write_new_at(
                        parent_descriptor,
                        sidecar_name,
                        orchestrator.canonical_json_bytes(event) + b"\n",
                    )
                    staged_sidecar = root / sidecar_name
                    raise KeyboardInterrupt(
                        "simulated process death before root-sealed append"
                    )
                real_append(
                    parent_descriptor,
                    marker_name,
                    marker_descriptor,
                    event,
                )

            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    publisher,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_append_transaction_event",
                    side_effect=crash_before_root_sealed_append,
                ), self.assertRaises(KeyboardInterrupt):
                    build_p06_release_transaction(**arguments)

                self.assertTrue(destination.is_dir())
                self.assertTrue(marker.is_file())
                self.assertIsNotNone(staged_sidecar)
                assert staged_sidecar is not None
                self.assertTrue(staged_sidecar.is_file())
                events = [
                    json.loads(line)
                    for line in marker.read_text(encoding="utf-8").splitlines()
                ]
                self.assertEqual(
                    events[-1]["stage"],
                    "published_descendants_sealed",
                )

                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    publisher,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ):
                    recovered = build_p06_release_transaction(**arguments)

                self.assertEqual(recovered, self._fake_bundle())
                self.assertEqual(publisher.call_count, 1)
                self.assertTrue(destination.is_dir())
                self.assertFalse(marker.exists())
                self.assertFalse(staged_sidecar.exists())
            finally:
                self._thaw_recognized(root)

    def test_crash_before_token_preserves_marker_and_ambiguous_partial(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-pretoken-crash-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            partial = root / ".release.partial"
            marker = root / ".release.transaction.jsonl"
            state = {"snapshot": "clean"}
            original_write = orchestrator._write_new_at

            def crash_before_token(
                directory_descriptor: int,
                name: str,
                payload: bytes,
                *,
                mode: int = 0o600,
            ) -> os.stat_result:
                if name == orchestrator.P06_TRANSACTION_TOKEN_NAME:
                    raise KeyboardInterrupt("simulated process death before token")
                return original_write(
                    directory_descriptor,
                    name,
                    payload,
                    mode=mode,
                )

            with mock.patch.object(
                orchestrator,
                "_repository_state",
                return_value=(state, True),
            ), mock.patch.object(
                orchestrator,
                "_write_new_at",
                side_effect=crash_before_token,
            ), self.assertRaises(KeyboardInterrupt):
                build_p06_release_transaction(
                    **self._transaction_arguments(root, destination)
                )
            self.assertTrue(partial.is_dir())
            self.assertTrue(marker.is_file())

            with mock.patch.object(
                orchestrator,
                "_repository_state",
                return_value=(state, True),
            ), self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "transaction-token",
            ):
                build_p06_release_transaction(
                    **self._transaction_arguments(root, destination)
                )
            self.assertTrue(partial.is_dir())
            self.assertTrue(marker.is_file())
            marker.unlink()
            partial.rmdir()

    @unittest.skipUnless(
        hasattr(stat, "UF_IMMUTABLE"),
        "P06 release sealing requires macOS user-immutable flags",
    )
    def test_durable_marker_recovers_a_valid_descendant_sealed_partial(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-crash-recovery-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            destination = root / "release"
            partial = root / ".release.partial"
            marker = root / ".release.transaction.jsonl"
            state = {"snapshot": "clean"}
            publisher = mock.Mock(side_effect=self._publish_fake_release)
            arguments = self._transaction_arguments(root, destination)
            try:
                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    publisher,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ), mock.patch.object(
                    orchestrator,
                    "_rename_release_exclusive_at",
                    side_effect=KeyboardInterrupt("simulated process death"),
                ), self.assertRaises(KeyboardInterrupt):
                    build_p06_release_transaction(**arguments)

                self.assertTrue(partial.is_dir())
                self.assertTrue(marker.is_file())
                events = [
                    json.loads(line)
                    for line in marker.read_text(encoding="utf-8").splitlines()
                ]
                self.assertEqual(events[-1]["stage"], "descendants_sealed")

                with mock.patch.object(
                    orchestrator,
                    "_repository_state",
                    return_value=(state, True),
                ), mock.patch.object(
                    orchestrator,
                    "_publish_release",
                    publisher,
                ), mock.patch.object(
                    orchestrator,
                    "validate_p06_release_bundle_manifest",
                    return_value=self._fake_bundle(),
                ):
                    recovered = build_p06_release_transaction(**arguments)

                self.assertEqual(recovered, self._fake_bundle())
                self.assertEqual(publisher.call_count, 1)
                self.assertTrue(destination.is_dir())
                self.assertFalse(partial.exists())
                self.assertFalse(marker.exists())
                self.assertNotEqual(
                    destination.stat().st_flags & stat.UF_IMMUTABLE,
                    0,
                )
            finally:
                self._thaw_recognized(root)

    def test_transaction_rejects_a_dangling_recognized_path(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-p06-dangling-partial-"
        ) as temporary:
            root = Path(temporary).resolve(strict=True)
            partial = root / ".release.partial"
            partial.symlink_to(root / "absent", target_is_directory=True)
            with self.assertRaisesRegex(
                P06ReleaseOrchestrationError,
                "already exists",
            ), mock.patch.object(
                orchestrator,
                "_repository_state",
                return_value=({"snapshot": "clean"}, True),
            ):
                build_p06_release_transaction(
                    **self._transaction_arguments(root, root / "release")
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
