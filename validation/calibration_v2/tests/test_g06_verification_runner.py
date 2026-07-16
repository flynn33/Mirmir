from __future__ import annotations

import copy
import hashlib
import io
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

from validation.calibration_v2.release_orchestrator import (
    REQUIRED_G06_TEST_EVIDENCE_IDS,
)
from validation.calibration_v2.tests.native_benchmark_fixture import (
    create_frozen_runtime_fixture,
    thaw_and_remove_runtime_fixture,
)
from validation.calibration_v2.tools import run_g06_verification as g06
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class G06ParserTests(unittest.TestCase):
    def test_unittest_parser_requires_terminal_arithmetic(self) -> None:
        counts = g06.parse_unittest_output(
            "................................................................\n"
            "----------------------------------------------------------------------\n"
            "Ran 150 tests in 41.901s\n\nOK\n"
        )
        self.assertEqual(counts["test_count"], 150)
        self.assertEqual(counts["passed"], 150)
        self.assertTrue(g06._test_counts_pass(counts))

        for rejected in (
            "Ran 3 tests in 0.1s\n\nOK (skipped=1)\n",
            (
                "Ran 5 tests in 0.1s\n\n"
                "OK (skipped=1, expected failures=1, unexpected successes=1)\n"
            ),
            "Ran 1 test in 0.1s\n\nOK\ntrailing output\n",
        ):
            with self.subTest(rejected=rejected), self.assertRaisesRegex(
                g06.G06VerificationError,
                "all-passed terminal summary",
            ):
                g06.parse_unittest_output(rejected)
        with self.assertRaisesRegex(
            g06.G06VerificationError,
            "all-passed terminal summary",
        ):
            g06.parse_unittest_output("Ran 1 test in 0.1s\n")
        for rejected in (
            (
                "Ran 1 test in 0.1s\n\nOK (skipped=1)\n"
                "Ran 1 test in 0.1s\n\nOK\n"
            ),
            "Ran 1 test in 0.1s\n\nFAILED (failures=1)\nOK\n",
        ):
            with self.subTest(rejected=rejected), self.assertRaises(
                g06.G06VerificationError
            ):
                g06.parse_unittest_output(rejected)

    def test_pytest_parser_counts_function_style_tests_and_rejects_skips(self) -> None:
        counts = g06.parse_pytest_output(
            "................................ [100%]\n165 passed in 77.92s\n"
        )
        self.assertEqual(counts["test_count"], 165)
        self.assertTrue(g06._test_counts_pass(counts))

        for rejected in (
            "4 passed, 1 skipped in 0.4s\n",
            "4 passed, 1 warning in 0.4s\n",
            "4 passed in 0.4s\ntrailing output\n",
        ):
            with self.subTest(rejected=rejected), self.assertRaisesRegex(
                g06.G06VerificationError,
                "all-passed terminal summary",
            ):
                g06.parse_pytest_output(rejected)
        with self.assertRaisesRegex(
            g06.G06VerificationError,
            "non-terminal outcome summary",
        ):
            g06.parse_pytest_output(
                "3 passed, 1 skipped in 0.2s\n4 passed in 0.3s\n"
            )

    def test_xcresult_and_diagnostic_parsers_are_fail_closed(self) -> None:
        counts = g06.parse_xcresult_summary(
            {
                "totalTestCount": 8,
                "passedTests": 8,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "result": "Passed",
            }
        )
        self.assertTrue(g06._test_counts_pass(counts))
        with self.assertRaisesRegex(g06.G06VerificationError, "arithmetic"):
            g06.parse_xcresult_summary(
                {
                    "totalTestCount": 8,
                    "passedTests": 7,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "result": "Passed",
                }
            )
        self.assertEqual(
            g06.parse_diagnostic_counts(
                "file.swift:1: warning: warning text\n"
                "file.swift:2: error: error text\n"
                "2026-07-11 appintentsmetadataprocessor[1:2] warning: "
                "no AppIntents dependency\n"
                "2026-07-11 Mirmir[1:2] connection error: unavailable\n"
            ),
            {"warning_count": 1, "error_count": 1},
        )
        self.assertTrue(
            g06._diagnostics_are_clean(
                {"warning_count": 0, "error_count": 0}
            )
        )
        self.assertFalse(
            g06._diagnostics_are_clean(
                {"warning_count": 1, "error_count": 0}
            )
        )


class G06AtomicPublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repository_state = self._clean_repository_state()
        self.repository_state_patcher = mock.patch.object(
            g06,
            "runtime_correction_repository_state",
            return_value=(self.repository_state, True),
        )
        self.repository_state_patcher.start()

    def tearDown(self) -> None:
        self.repository_state_patcher.stop()

    @staticmethod
    def _mock_passed_executor(
        identifier: str,
    ) -> object:
        def execute(run_root: Path) -> g06.GroupResult:
            artifact_id = f"logs/{identifier}.log"
            path = g06._safe_child(run_root, artifact_id)
            g06._write_new(path, f"{identifier}: passed\n".encode("utf-8"))
            binding = g06._file_binding(
                path,
                run_root=run_root,
                artifact_kind="command_log",
            )
            command = {
                "command_index": 1,
                "argv": ["mock-command", identifier],
                "command_text": f"mock-command {identifier}",
                "working_directory": ".",
                "exit_code": 0,
                "timed_out": False,
                "duration_seconds": 0.0,
                "status": "passed",
                "log_binding": binding,
            }
            return g06.GroupResult(
                status="passed",
                started_utc="2026-07-11T00:00:00.000000Z",
                finished_utc="2026-07-11T00:00:01.000000Z",
                commands=(command,),
                artifacts=(binding,),
                summary={"mocked": True},
                failure_reason=None,
            )

        return execute

    def _runner(
        self,
        *,
        output_root: Path,
        run_id: str,
        executors: dict[str, object],
    ) -> g06.G06VerificationRunner:
        return g06.G06VerificationRunner(
            repository_root=REPOSITORY_ROOT,
            output_root=output_root,
            run_id=run_id,
            group_executors=executors,
        )

    def _exception_failure_archive(
        self,
        output_root: Path,
        run_id: str,
    ) -> Path:
        self.assertFalse((output_root / f".{run_id}.partial").exists())
        self.assertFalse((output_root / run_id).exists())
        self.assertFalse((output_root / f"{run_id}.failed").exists())
        self.assertFalse((output_root / f"{run_id}.failed-pending").exists())
        self.assertFalse(
            (output_root / f".{run_id}.g06-transaction.json").exists()
        )
        archives = sorted(
            path
            for path in output_root.glob(f"{run_id}.failed-recovery-*")
            if path.is_dir()
        )
        self.assertEqual(len(archives), 1)
        records = sorted(
            archives[0].glob("g06-failure-recovery-*.json")
        )
        self.assertEqual(len(records), 1)
        record = g06._read_json(records[0])
        unhashed = dict(record)
        declared = unhashed.pop("record_sha256")
        self.assertEqual(declared, canonical_sha256(unhashed))
        return archives[0]

    @staticmethod
    def _pending_transaction_state(
        output_root: Path,
        run_id: str,
        *,
        sibling_marker: bool,
    ) -> tuple[dict[str, str], dict[str, object]]:
        names = dict(g06._g06_transaction_names(run_id))
        token = hashlib.sha256(run_id.encode("utf-8")).hexdigest()[:32]
        parent_descriptor, output_metadata = g06._open_real_directory_path(
            output_root,
            label="test G06 output root",
        )
        try:
            os.mkdir(
                names["staging_name"],
                mode=0o700,
                dir_fd=parent_descriptor,
            )
            os.fsync(parent_descriptor)
            root_descriptor, root_metadata = g06._open_real_directory_at(
                parent_descriptor,
                names["staging_name"],
                label="test pending G06 root",
            )
            try:
                document = dict(
                    g06._g06_transaction_document(
                        run_id=run_id,
                        token=token,
                        output_metadata=output_metadata,
                        root_metadata=root_metadata,
                    )
                )
                payload = g06.canonical_json_bytes(document) + b"\n"
                g06._write_new_at(
                    root_descriptor,
                    g06.G06_TRANSACTION_TOKEN_NAME,
                    payload,
                    mode=0o600,
                    label="test G06 in-root token",
                )
                if sibling_marker:
                    g06._write_new_at(
                        parent_descriptor,
                        names["marker_name"],
                        payload,
                        mode=0o600,
                        label="test G06 sibling marker",
                    )
            finally:
                os.close(root_descriptor)
        finally:
            os.close(parent_descriptor)
        return names, document

    @staticmethod
    def _clean_repository_state() -> dict[str, object]:
        project_commit = g06._git_head(REPOSITORY_ROOT)
        empty_sha256 = hashlib.sha256(b"").hexdigest()
        dirty_state_sha256 = canonical_sha256(
            {
                "algorithm": (
                    "git-diff-head-binary-plus-content-bound-untracked-v1"
                ),
                "artifact_pathspec_exclusion": "Artifacts/**",
                "project_commit": project_commit,
                "tracked_diff_sha256": empty_sha256,
                "tracked_diff_size_bytes": 0,
                "ordered_untracked_files": [],
            }
        )
        return {
            "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
            "artifact_pathspec_exclusion": "Artifacts/**",
            "project_commit": project_commit,
            "tracked_diff_sha256": empty_sha256,
            "tracked_diff_size_bytes": 0,
            "untracked_file_count": 0,
            "ordered_untracked_files_sha256": canonical_sha256([]),
            "dirty_state_sha256": dirty_state_sha256,
        }

    def test_success_publishes_exact_five_ordered_self_hashed_files_atomically(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-publication-") as value:
            output = Path(value)
            executors = {
                identifier: self._mock_passed_executor(identifier)
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-pass",
                executors=executors,
            )
            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ):
                result = runner.run()
            self.assertEqual(result.status, "passed")
            self.assertEqual(
                result.path,
                (output / "g06-pass").resolve(strict=False),
            )
            self.assertFalse((output / ".g06-pass.partial").exists())
            self.assertEqual(
                [identifier for identifier, _ in result.evidence_paths],
                list(REQUIRED_G06_TEST_EVIDENCE_IDS),
            )
            self.assertEqual(
                sorted(path.name for path in result.path.glob("*.json")),
                sorted(
                    f"{identifier}.json"
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                ),
            )
            for ordinal, (identifier, path) in enumerate(result.evidence_paths, 1):
                document = g06._read_json(path)
                unhashed = dict(document)
                declared = unhashed.pop("evidence_sha256")
                self.assertEqual(document["evidence_id"], identifier)
                self.assertEqual(document["evidence_ordinal"], ordinal)
                self.assertEqual(declared, canonical_sha256(unhashed))

            for directory, _, file_names in os.walk(result.path):
                directory_metadata = os.stat(directory, follow_symlinks=False)
                self.assertEqual(directory_metadata.st_mode & 0o222, 0)
                self.assertNotEqual(
                    directory_metadata.st_flags & stat.UF_IMMUTABLE,
                    0,
                )
                for name in file_names:
                    metadata = os.stat(
                        Path(directory) / name,
                        follow_symlinks=False,
                    )
                    self.assertEqual(metadata.st_mode & 0o222, 0)
                    self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)

            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "already exists",
            ):
                runner.run()

    def test_late_commit_mutation_is_quarantined_before_marker_removal(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-late-commit-mutation-"
        ) as value:
            output = Path(value)
            run_id = "g06-late-commit-mutation"
            runner = self._runner(
                output_root=output,
                run_id=run_id,
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            original_commit = g06._commit_g06_transaction

            def mutate_then_commit(
                transaction: object,
                *,
                destination: Path,
                verify_committed: object,
            ) -> None:
                (destination / "late-unbound.txt").write_bytes(b"late mutation\n")
                original_commit(
                    transaction,
                    destination=destination,
                    verify_committed=verify_committed,
                )

            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                g06,
                "_commit_g06_transaction",
                side_effect=mutate_then_commit,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "run-tree closure differs",
            ):
                runner.run()

            self.assertFalse((output / run_id).exists())
            archive = self._exception_failure_archive(output, run_id)
            self.assertTrue((archive / "late-unbound.txt").is_file())

    def test_failure_is_preserved_and_remaining_evidence_is_not_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-failure-") as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
            calls: list[str] = []

            def fail(_run_root: Path) -> g06.GroupResult:
                calls.append(first)
                return g06.GroupResult(
                    status="failed",
                    started_utc="2026-07-11T00:00:00.000000Z",
                    finished_utc="2026-07-11T00:00:01.000000Z",
                    commands=(),
                    artifacts=(),
                    summary={"mocked": True},
                    failure_reason="mocked failure",
                )

            def must_not_run(_run_root: Path) -> g06.GroupResult:
                raise AssertionError("later evidence group must not run")

            executors = {
                identifier: (fail if identifier == first else must_not_run)
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            result = self._runner(
                output_root=output,
                run_id="g06-fail",
                executors=executors,
            ).run()
            self.assertEqual(calls, [first])
            self.assertEqual(result.status, "failed")
            self.assertEqual(
                result.path,
                (output / "g06-fail.failed").resolve(strict=False),
            )
            statuses = [
                g06._read_json(path)["status"]
                for _, path in result.evidence_paths
            ]
            self.assertEqual(statuses, ["failed", "not_run", "not_run", "not_run", "not_run"])

    def test_completed_success_rename_followed_by_error_is_quarantined(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-rename-error-"
        ) as value:
            output = Path(value)
            runner = self._runner(
                output_root=output,
                run_id="g06-rename-error",
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            original_rename = g06._rename_exclusive
            rename_count = 0

            def rename_then_fail(source: Path, destination: Path) -> None:
                nonlocal rename_count
                rename_count += 1
                original_rename(source, destination)
                if rename_count == 1:
                    raise g06.G06VerificationError(
                        "injected post-rename directory sync failure"
                    )

            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                g06,
                "_rename_exclusive",
                side_effect=rename_then_fail,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "post-rename directory sync failure",
            ):
                runner.run()

            self.assertEqual(rename_count, 1)
            archive = self._exception_failure_archive(
                output,
                "g06-rename-error",
            )
            self.assertTrue(
                (archive / "python_calibration_full_suite.json").is_file()
            )

    def test_quarantine_raises_when_every_exclusive_rename_fails(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-quarantine-outage-"
        ) as value:
            output = Path(value)
            final = output / "g06-quarantine-outage"
            final.mkdir()
            expected = final.stat()
            attempts = 0

            def fail_rename(_source: Path, _destination: Path) -> None:
                nonlocal attempts
                attempts += 1
                raise OSError("injected persistent exclusive rename failure")

            with mock.patch.object(
                g06,
                "_rename_exclusive",
                side_effect=fail_rename,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "could not be quarantined",
            ):
                g06._quarantine_g06_success(
                    final=final,
                    partial=output / ".g06-quarantine-outage.partial",
                    failed=output / "g06-quarantine-outage.failed",
                    expected=expected,
                )

            self.assertEqual(attempts, 6)
            self.assertTrue(final.is_dir())
            self.assertTrue(g06._path_has_directory_identity(final, expected))

    def test_success_recursively_syncs_before_exclusive_rename(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-sync-before-rename-"
        ) as value:
            output = Path(value)
            runner = self._runner(
                output_root=output,
                run_id="g06-sync-before-rename",
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            events: list[str] = []
            original_sync = g06._fsync_tree
            original_rename = g06._rename_exclusive

            def synchronize(path: Path) -> None:
                events.append("sync")
                original_sync(path)

            def rename(source: Path, destination: Path) -> None:
                events.append("rename")
                original_rename(source, destination)

            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                g06,
                "_fsync_tree",
                side_effect=synchronize,
            ), mock.patch.object(
                g06,
                "_rename_exclusive",
                side_effect=rename,
            ):
                result = runner.run()

            self.assertEqual(result.status, "passed")
            self.assertEqual(events[:2], ["sync", "rename"])

    def test_parent_sync_failure_quarantines_completed_success(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-parent-sync-failure-"
        ) as value:
            output = Path(value)
            final = output / "g06-parent-sync-failure"
            failed = output / "g06-parent-sync-failure.failed"
            runner = self._runner(
                output_root=output,
                run_id="g06-parent-sync-failure",
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            original_fsync = g06.os.fsync
            output_identity = output.stat()

            def rename_only(source: Path, destination: Path) -> None:
                os.rename(source, destination)

            def fail_published_parent_sync(descriptor: int) -> None:
                metadata = os.fstat(descriptor)
                if final.exists() and (
                    metadata.st_dev,
                    metadata.st_ino,
                ) == (output_identity.st_dev, output_identity.st_ino):
                    raise OSError("injected published-parent sync failure")
                original_fsync(descriptor)

            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                g06,
                "_rename_exclusive",
                side_effect=rename_only,
            ), mock.patch.object(
                g06.os,
                "fsync",
                side_effect=fail_published_parent_sync,
            ), self.assertRaisesRegex(
                OSError,
                "published-parent sync failure",
            ):
                runner.run()

            self.assertFalse(final.exists())
            self.assertFalse(failed.exists())
            self._exception_failure_archive(
                output,
                "g06-parent-sync-failure",
            )

    def test_tree_binding_surfaces_walk_errors(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-tree-walk-error-"
        ) as value:
            root = Path(value)
            tree = root / "tree"
            tree.mkdir()
            (tree / "artifact.txt").write_bytes(b"artifact\n")

            def fail_walk(*_arguments: object, **arguments: object) -> object:
                arguments["onerror"](PermissionError("injected walk denial"))
                return iter(())

            with mock.patch.object(
                g06.os,
                "walk",
                side_effect=fail_walk,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "tree traversal failed",
            ):
                g06._tree_binding(
                    tree,
                    run_root=root,
                    artifact_kind="xcresult",
                )

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires mkfifo")
    def test_recursive_sync_rejects_fifo_without_opening_it(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-fifo-sync-"
        ) as value:
            root = Path(value)
            os.mkfifo(root / "blocked.pipe")
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "non-regular or multiply linked",
            ):
                g06._fsync_tree(root)

    def test_release_retention_removes_unbound_derived_data_symlinks(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-release-retention-"
        ) as value:
            run_root = Path(value)
            derived = run_root / "build/release-derived-data"
            executable = (
                derived
                / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
            )
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"release-product\n")
            executable.chmod(0o755)
            framework = (
                derived
                / "Build/Products/Release/Mirmir.app/Contents/Frameworks/"
                "XCUnit.framework"
            )
            (framework / "Versions/A/Resources").mkdir(parents=True)
            (framework / "Versions/Current").symlink_to("A")
            (framework / "Resources").symlink_to("Versions/Current/Resources")

            retained = g06._retain_release_product_only(
                run_root=run_root,
                derived_data=derived,
                executable=executable,
            )

            self.assertTrue(retained)
            self.assertEqual(executable.read_bytes(), b"release-product\n")
            self.assertEqual(executable.stat().st_mode & 0o777, 0o755)
            self.assertFalse(framework.exists())
            self.assertFalse(any(path.is_symlink() for path in derived.rglob("*")))
            g06._fsync_tree(run_root)

    def test_native_derived_data_cleanup_does_not_follow_framework_symlinks(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-cleanup-"
        ) as value:
            run_root = Path(value)
            derived = run_root / "build/native-integration-derived-data"
            outside = run_root / "outside"
            outside.mkdir()
            sentinel = outside / "sentinel.txt"
            sentinel.write_bytes(b"preserve\n")
            framework = derived / "Build/Products/Debug/XCUnit.framework"
            framework.mkdir(parents=True)
            (framework / "Resources").symlink_to(outside, target_is_directory=True)

            g06._remove_unbound_derived_data(
                run_root=run_root,
                derived_data=derived,
                expected_relative_path="build/native-integration-derived-data",
            )

            self.assertFalse(derived.exists())
            self.assertEqual(sentinel.read_bytes(), b"preserve\n")
            g06._fsync_tree(run_root)

    def test_derived_data_cleanup_rejects_an_aliased_root(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-aliased-derived-root-"
        ) as value:
            run_root = Path(value)
            outside = run_root / "outside"
            outside.mkdir()
            sentinel = outside / "sentinel.txt"
            sentinel.write_bytes(b"preserve\n")
            derived = run_root / "build/native-integration-derived-data"
            derived.parent.mkdir()
            derived.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "linked or special and was removed",
            ):
                g06._remove_unbound_derived_data(
                    run_root=run_root,
                    derived_data=derived,
                    expected_relative_path="build/native-integration-derived-data",
                )

            self.assertEqual(sentinel.read_bytes(), b"preserve\n")
            self.assertFalse(derived.exists())
            self.assertFalse(derived.is_symlink())
            self.assertFalse((run_root / "build").exists())

    def test_derived_data_cleanup_confines_parent_swap_and_late_file(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-derived-parent-swap-"
        ) as value:
            run_root = Path(value)
            build = run_root / "build"
            derived = build / "native-integration-derived-data"
            (derived / "cache").mkdir(parents=True)
            (derived / "cache/payload.bin").write_bytes(b"cache\n")
            moved_build = run_root / "moved-build"
            original_rename_at = g06._rename_exclusive_at
            original_empty = g06._empty_directory_descriptor
            quarantine: Path | None = None
            empty_calls = 0

            def rename_then_move_parent(
                source_descriptor: int,
                source_name: str,
                destination_descriptor: int,
                destination_name: str,
                *,
                nofollow_any: bool = True,
            ) -> None:
                nonlocal quarantine
                original_rename_at(
                    source_descriptor,
                    source_name,
                    destination_descriptor,
                    destination_name,
                    nofollow_any=nofollow_any,
                )
                build.rename(moved_build)
                quarantine = moved_build / destination_name

            def inject_after_first_empty(descriptor: int) -> None:
                nonlocal empty_calls
                empty_calls += 1
                original_empty(descriptor)
                if empty_calls == 1:
                    assert quarantine is not None
                    (quarantine / "late-unbound").write_bytes(b"late\n")

            with mock.patch.object(
                g06,
                "_rename_exclusive_at",
                side_effect=rename_then_move_parent,
            ), mock.patch.object(
                g06,
                "_empty_directory_descriptor",
                side_effect=inject_after_first_empty,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "build parent identity changed",
            ):
                g06._remove_unbound_derived_data(
                    run_root=run_root,
                    derived_data=derived,
                    expected_relative_path=(
                        "build/native-integration-derived-data"
                    ),
                )

            self.assertGreaterEqual(empty_calls, 2)
            self.assertFalse(build.exists())
            self.assertFalse(moved_build.exists())
            self.assertEqual(g06._run_tree_entry_kinds(run_root), {})

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires mkfifo")
    def test_aliased_and_special_derived_roots_publish_failed_closure(
        self,
    ) -> None:
        for case in ("symlink", "fifo"):
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{case}-derived-failure-"
            ) as value:
                output = Path(value)
                outside = output / "outside"
                outside.mkdir()
                sentinel = outside / "sentinel.txt"
                sentinel.write_bytes(b"preserve\n")
                first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

                def fail_after_safe_cleanup(run_root: Path) -> g06.GroupResult:
                    derived = (
                        run_root / "build/native-integration-derived-data"
                    )
                    derived.parent.mkdir()
                    if case == "symlink":
                        derived.symlink_to(outside, target_is_directory=True)
                    else:
                        os.mkfifo(derived)
                    try:
                        g06._remove_unbound_derived_data(
                            run_root=run_root,
                            derived_data=derived,
                            expected_relative_path=(
                                "build/native-integration-derived-data"
                            ),
                        )
                    except g06.G06VerificationError as error:
                        reason = str(error)
                    else:
                        raise AssertionError("invalid DerivedData root was accepted")
                    return g06.GroupResult(
                        status="failed",
                        started_utc="2026-07-11T00:00:00.000000Z",
                        finished_utc="2026-07-11T00:00:01.000000Z",
                        commands=(),
                        artifacts=(),
                        summary={"cleanup_case": case},
                        failure_reason=reason,
                    )

                result = self._runner(
                    output_root=output,
                    run_id=f"g06-{case}-derived-failure",
                    executors={first: fail_after_safe_cleanup},
                ).run()

                self.assertEqual(result.status, "failed")
                self.assertFalse(
                    (output / f".g06-{case}-derived-failure.partial").exists()
                )
                failed = output / f"g06-{case}-derived-failure.failed"
                self.assertTrue(failed.is_dir())
                self.assertEqual(sentinel.read_bytes(), b"preserve\n")
                self.assertEqual(
                    g06._run_tree_entry_kinds(failed),
                    {
                        f"{identifier}.json": "regular_file"
                        for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                    },
                )

    def test_release_retention_rejects_a_multiply_linked_product_after_cleanup(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-hardlinked-release-product-"
        ) as value:
            run_root = Path(value)
            derived = run_root / "build/release-derived-data"
            executable = (
                derived
                / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
            )
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"release-product\n")
            executable.chmod(0o755)
            os.link(executable, derived / "product-alias")

            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "single-link regular file",
            ):
                g06._retain_release_product_only(
                    run_root=run_root,
                    derived_data=derived,
                    executable=executable,
                )

            self.assertFalse(derived.exists())
            g06._fsync_tree(run_root)

    def test_release_product_recreation_cannot_follow_parent_redirect(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-release-product-redirect-"
        ) as value:
            run_root = Path(value)
            derived = run_root / "build/release-derived-data"
            executable = (
                derived
                / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
            )
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"release-product\n")
            executable.chmod(0o755)
            outside = run_root.parent / f"{run_root.name}-outside"
            outside.mkdir()
            self.addCleanup(lambda: outside.rmdir() if outside.exists() else None)
            sentinel = outside / "sentinel.txt"
            sentinel.write_bytes(b"preserve\n")
            self.addCleanup(lambda: sentinel.unlink() if sentinel.exists() else None)
            original_write_at = g06._write_new_at
            redirected = False

            def redirect_before_write(
                parent_descriptor: int,
                name: str,
                payload: bytes,
                *,
                mode: int,
                label: str,
            ) -> os.stat_result:
                nonlocal redirected
                if label == "retained Release product" and not redirected:
                    contents = (
                        run_root
                        / "build/release-derived-data/Build/Products/Release/"
                        "Mirmir.app/Contents"
                    )
                    macos = contents / "MacOS"
                    macos.rename(contents / "MacOS-real")
                    macos.symlink_to(outside, target_is_directory=True)
                    redirected = True
                return original_write_at(
                    parent_descriptor,
                    name,
                    payload,
                    mode=mode,
                    label=label,
                )

            with mock.patch.object(
                g06,
                "_write_new_at",
                side_effect=redirect_before_write,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "parent MacOS identity changed",
            ):
                g06._retain_release_product_only(
                    run_root=run_root,
                    derived_data=derived,
                    executable=executable,
                )

            self.assertTrue(redirected)
            self.assertEqual(sentinel.read_bytes(), b"preserve\n")
            self.assertFalse((outside / "Mirmir").exists())
            self.assertFalse((run_root / "build").exists())
            self.assertEqual(g06._run_tree_entry_kinds(run_root), {})

    def test_release_group_retains_only_the_bound_product_and_passes_semantics(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-release-group-retention-"
        ) as value:
            output = Path(value)
            runner = self._runner(
                output_root=output,
                run_id="g06-release-retained",
                executors={},
            )
            run_root = output / ".g06-release-retained.partial"
            run_root.mkdir()
            summary_payload = (
                b'{"expectedFailures":0,"failedTests":0,"passedTests":1,'
                b'"result":"Passed","skippedTests":0,"totalTestCount":1}\n'
            )

            def execute_command(
                *,
                run_root: Path,
                command_index: int,
                argv: object,
                log_artifact_id: str,
                artifact_kind: str = "command_log",
                raw_output: bool = False,
            ) -> object:
                del raw_output
                if command_index == 1:
                    derived = run_root / "build/release-derived-data"
                    product = (
                        derived
                        / "Build/Products/Release/Mirmir.app/Contents/MacOS/"
                        "Mirmir"
                    )
                    product.parent.mkdir(parents=True)
                    product.write_bytes(b"release-product\n")
                    product.chmod(0o755)
                    framework = (
                        derived
                        / "Build/Products/Release/Mirmir.app/Contents/Frameworks/"
                        "XCUnit.framework"
                    )
                    (framework / "Versions/A/Resources").mkdir(parents=True)
                    (framework / "Versions/Current").symlink_to("A")
                    payload = b"** BUILD SUCCEEDED **\n"
                elif command_index == 2:
                    result = run_root / "artifacts/release-runtime.xcresult"
                    g06._write_new(result / "Info.plist", b"result-info\n")
                    payload = b"release runtime passed\n"
                else:
                    payload = summary_payload
                log_path = g06._safe_child(run_root, log_artifact_id)
                g06._write_new(log_path, payload)
                binding = g06._file_binding(
                    log_path,
                    run_root=run_root,
                    artifact_kind=artifact_kind,
                )
                argv_list = list(argv)
                return {
                    "command_index": command_index,
                    "argv": argv_list,
                    "command_text": " ".join(argv_list),
                    "working_directory": ".",
                    "exit_code": 0,
                    "timed_out": False,
                    "duration_seconds": 0.0,
                    "status": "passed",
                    "log_binding": binding,
                }

            with mock.patch.object(
                runner,
                "_execute_command",
                side_effect=execute_command,
            ):
                result = runner._xcode_release_runtime(run_root)

            self.assertEqual(result.status, "passed")
            derived = run_root / "build/release-derived-data"
            retained = (
                derived
                / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
            )
            self.assertEqual(retained.read_bytes(), b"release-product\n")
            self.assertEqual(retained.stat().st_mode & 0o777, 0o755)
            self.assertFalse(any(path.is_symlink() for path in derived.rglob("*")))
            product_binding = next(
                binding
                for binding in result.artifacts
                if binding["artifact_kind"] == "release_product"
            )
            self.assertEqual(product_binding["executable_mode_bits"], 0o111)
            document = runner._evidence_document(
                "xcode_release_runtime",
                3,
                result,
            )
            self.assertEqual(document["schema_version"], "1.2.0")
            missing_mode = copy.deepcopy(document)
            next(
                binding
                for binding in missing_mode["artifacts"]
                if binding["artifact_kind"] == "release_product"
            ).pop("executable_mode_bits")
            with self.assertRaises(ValueError):
                g06.validate_schema(missing_mode, g06.SCHEMA_PATH)
            from validation.calibration_v2 import release_orchestrator

            release_orchestrator._validate_g06_group_semantics(
                identifier="xcode_release_runtime",
                document=document,
                run_root=run_root,
                bindings=tuple(result.artifacts),
                execution_run_name="g06-release-retained",
            )
            g06._fsync_tree(run_root)

    def test_file_binding_detects_release_product_executable_mode_loss(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-release-mode-binding-"
        ) as value:
            run_root = Path(value)
            product = run_root / "Mirmir"
            product.write_bytes(b"release-product\n")
            product.chmod(0o755)
            before = g06._file_binding(
                product,
                run_root=run_root,
                artifact_kind="release_product",
            )
            self.assertEqual(before["executable_mode_bits"], 0o111)

            product.chmod(0o600)
            after = g06._file_binding(
                product,
                run_root=run_root,
                artifact_kind="release_product",
            )

            self.assertEqual(after["executable_mode_bits"], 0)
            self.assertNotEqual(before, after)

    def test_failed_release_command_prunes_derived_data_before_publication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-failed-release-cleanup-"
        ) as value:
            output = Path(value)
            runner: g06.G06VerificationRunner

            def failed_command(
                *,
                run_root: Path,
                command_index: int,
                argv: object,
                log_artifact_id: str,
                artifact_kind: str = "command_log",
                raw_output: bool = False,
            ) -> object:
                del raw_output
                self.assertEqual(command_index, 1)
                derived = run_root / "build/release-derived-data"
                framework = derived / "Build/Products/Release/XCUnit.framework"
                framework.mkdir(parents=True)
                (framework / "Resources").symlink_to("Versions/Current/Resources")
                log_path = g06._safe_child(run_root, log_artifact_id)
                g06._write_new(log_path, b"Release build failed\n")
                binding = g06._file_binding(
                    log_path,
                    run_root=run_root,
                    artifact_kind=artifact_kind,
                )
                argv_list = list(argv)
                return {
                    "command_index": command_index,
                    "argv": argv_list,
                    "command_text": " ".join(argv_list),
                    "working_directory": ".",
                    "exit_code": 1,
                    "timed_out": False,
                    "duration_seconds": 0.0,
                    "status": "failed",
                    "log_binding": binding,
                }

            def release_failure(run_root: Path) -> g06.GroupResult:
                with mock.patch.object(
                    runner,
                    "_execute_command",
                    side_effect=failed_command,
                ):
                    return runner._xcode_release_runtime(run_root)

            executors = {
                REQUIRED_G06_TEST_EVIDENCE_IDS[0]: self._mock_passed_executor(
                    REQUIRED_G06_TEST_EVIDENCE_IDS[0]
                ),
                REQUIRED_G06_TEST_EVIDENCE_IDS[1]: self._mock_passed_executor(
                    REQUIRED_G06_TEST_EVIDENCE_IDS[1]
                ),
                REQUIRED_G06_TEST_EVIDENCE_IDS[2]: release_failure,
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-failed-release-cleanup",
                executors=executors,
            )

            result = runner.run()

            self.assertEqual(result.status, "failed")
            failed = output / "g06-failed-release-cleanup.failed"
            self.assertTrue(failed.is_dir())
            self.assertFalse((failed / "build/release-derived-data").exists())
            self.assertFalse(any(path.is_symlink() for path in failed.rglob("*")))
            g06._fsync_tree(failed)

    def test_postrename_verification_failure_quarantines_success_path(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-postrename-failure-"
        ) as value:
            output = Path(value)
            runner = self._runner(
                output_root=output,
                run_id="g06-postrename-failure",
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            original_verify = runner._verify_published
            verification_count = 0

            def verify(*arguments: object, **keywords: object) -> object:
                nonlocal verification_count
                verification_count += 1
                result = original_verify(*arguments, **keywords)
                if verification_count == 2:
                    raise g06.G06VerificationError(
                        "injected reopened publication failure"
                    )
                return result

            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                runner,
                "_verify_published",
                side_effect=verify,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "reopened publication failure",
            ):
                runner.run()

            self.assertEqual(verification_count, 2)
            archive = self._exception_failure_archive(
                output,
                "g06-postrename-failure",
            )
            self.assertTrue((archive / "logs").is_dir())

    def test_passing_executor_overrides_must_satisfy_release_semantics(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-executor-semantics-"
        ) as value:
            output = Path(value)
            runner = self._runner(
                output_root=output,
                run_id="g06-invalid-executor-pass",
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )

            with mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "release semantics differ",
            ):
                runner.run()

            archive = self._exception_failure_archive(
                output,
                "g06-invalid-executor-pass",
            )
            self.assertEqual(
                len(list(archive.glob("*.json"))),
                len(REQUIRED_G06_TEST_EVIDENCE_IDS) + 1,
            )

    def test_mutated_artifact_publishes_failure_without_hidden_partial(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-mutation-") as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

            def mutate(run_root: Path) -> g06.GroupResult:
                executor = self._mock_passed_executor(first)
                result = executor(run_root)
                artifact_id = str(result.artifacts[0]["artifact_id"])
                g06._safe_child(run_root, artifact_id).write_bytes(b"mutated\n")
                return result

            executors = {
                identifier: (
                    mutate
                    if identifier == first
                    else self._mock_passed_executor(identifier)
                )
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-mutation",
                executors=executors,
            )
            with mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "artifact binding changed",
            ):
                runner.run()
            archive = self._exception_failure_archive(
                output,
                "g06-mutation",
            )
            self.assertEqual(
                (archive / f"logs/{first}.log").read_bytes(),
                b"mutated\n",
            )

    def test_unbound_regular_tree_blocks_publication_by_exact_closure(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-unbound-closure-"
        ) as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

            def add_unbound_tree(run_root: Path) -> g06.GroupResult:
                result = self._mock_passed_executor(first)(run_root)
                unbound = run_root / "moved-build/.derived.discard"
                unbound.mkdir(parents=True)
                (unbound / "late-unbound").write_bytes(b"late\n")
                return result

            executors = {
                identifier: (
                    add_unbound_tree
                    if identifier == first
                    else self._mock_passed_executor(identifier)
                )
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            runner = self._runner(
                output_root=output,
                run_id="g06-unbound-closure",
                executors=executors,
            )
            with mock.patch(
                "validation.calibration_v2.release_orchestrator."
                "_validate_g06_group_semantics"
            ), mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "run-tree closure differs",
            ):
                runner.run()

            archive = self._exception_failure_archive(
                output,
                "g06-unbound-closure",
            )
            self.assertIn(
                "moved-build/.derived.discard/late-unbound",
                g06._run_tree_entry_kinds(archive),
            )

    def test_pre_artifact_executor_contract_failure_has_no_hidden_partial(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-pre-artifact-failure-"
        ) as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

            def invalid(_run_root: Path) -> g06.GroupResult:
                return g06.GroupResult(
                    status="invalid",
                    started_utc="2026-07-11T00:00:00.000000Z",
                    finished_utc="2026-07-11T00:00:01.000000Z",
                    commands=(),
                    artifacts=(),
                    summary={},
                    failure_reason=None,
                )

            runner = self._runner(
                output_root=output,
                run_id="g06-pre-artifact-failure",
                executors={first: invalid},
            )
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "invalid status",
            ):
                runner.run()

            archive = self._exception_failure_archive(
                output,
                "g06-pre-artifact-failure",
            )
            self.assertEqual(
                [path.name for path in archive.iterdir()],
                [
                    next(
                        archive.glob("g06-failure-recovery-*.json")
                    ).name
                ],
            )

    def test_cancellation_after_artifact_generation_is_archived_and_reraised(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-cancellation-publication-"
        ) as value:
            output = Path(value)
            run_id = "g06-cancellation-publication"
            runner = self._runner(
                output_root=output,
                run_id=run_id,
                executors={
                    identifier: self._mock_passed_executor(identifier)
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                },
            )
            with mock.patch.object(
                runner,
                "_verified_native_runtime_evidence",
                return_value=(object(), {}),
            ), mock.patch.object(
                runner,
                "_require_runtime_copy_matches_frozen_source",
            ), mock.patch.object(
                runner,
                "_verify_published",
                side_effect=KeyboardInterrupt("injected cancellation"),
            ), self.assertRaisesRegex(
                KeyboardInterrupt,
                "injected cancellation",
            ):
                runner.run()

            archive = self._exception_failure_archive(output, run_id)
            record_path = next(
                archive.glob("g06-failure-recovery-*.json")
            )
            record = g06._read_json(record_path)
            self.assertEqual(record["cause_type"], "KeyboardInterrupt")
            self.assertEqual(record["cause_message"], "injected cancellation")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires mkfifo")
    def test_special_and_symlink_closure_failures_archive_without_traversal(
        self,
    ) -> None:
        for case in ("symlink", "fifo"):
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-{case}-closure-failure-"
            ) as value:
                output = Path(value)
                outside = output / "outside"
                outside.mkdir()
                sentinel = outside / "sentinel.txt"
                sentinel.write_bytes(b"preserve\n")
                first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]

                def add_special(run_root: Path) -> g06.GroupResult:
                    result = self._mock_passed_executor(first)(run_root)
                    special = run_root / "unbound-special"
                    if case == "symlink":
                        special.symlink_to(outside, target_is_directory=True)
                    else:
                        os.mkfifo(special)
                    return result

                executors = {
                    identifier: (
                        add_special
                        if identifier == first
                        else self._mock_passed_executor(identifier)
                    )
                    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
                }
                runner = self._runner(
                    output_root=output,
                    run_id=f"g06-{case}-closure-failure",
                    executors=executors,
                )
                with mock.patch(
                    "validation.calibration_v2.release_orchestrator."
                    "_validate_g06_group_semantics"
                ), mock.patch.object(
                    runner,
                    "_verified_native_runtime_evidence",
                    return_value=(object(), {}),
                ), mock.patch.object(
                    runner,
                    "_require_runtime_copy_matches_frozen_source",
                ), self.assertRaises(g06.G06VerificationError):
                    runner.run()

                archive = self._exception_failure_archive(
                    output,
                    f"g06-{case}-closure-failure",
                )
                preserved = archive / "unbound-special"
                if case == "symlink":
                    self.assertTrue(preserved.is_symlink())
                else:
                    self.assertTrue(stat.S_ISFIFO(preserved.lstat().st_mode))
                self.assertEqual(sentinel.read_bytes(), b"preserve\n")

    def test_failure_archive_retries_exclusive_rename_without_partial(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-failure-rename-retry-"
        ) as value:
            output = Path(value)
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
            runner = self._runner(
                output_root=output,
                run_id="g06-failure-rename-retry",
                executors={
                    first: lambda _root: g06.GroupResult(
                        status="invalid",
                        started_utc="2026-07-11T00:00:00.000000Z",
                        finished_utc="2026-07-11T00:00:01.000000Z",
                        commands=(),
                        artifacts=(),
                        summary={},
                        failure_reason=None,
                    )
                },
            )
            original_rename = g06._rename_exclusive_at
            archive_attempts = 0

            def fail_first_archive_rename(
                source_descriptor: int,
                source_name: str,
                destination_descriptor: int,
                destination_name: str,
                *,
                nofollow_any: bool = True,
            ) -> None:
                nonlocal archive_attempts
                if ".failed-recovery-" in destination_name:
                    archive_attempts += 1
                    if archive_attempts == 1:
                        raise OSError(
                            "injected first failure-archive rename failure"
                        )
                original_rename(
                    source_descriptor,
                    source_name,
                    destination_descriptor,
                    destination_name,
                    nofollow_any=nofollow_any,
                )

            with mock.patch.object(
                g06,
                "_rename_exclusive_at",
                side_effect=fail_first_archive_rename,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "invalid status",
            ):
                runner.run()

            self.assertEqual(archive_attempts, 2)
            self._exception_failure_archive(
                output,
                "g06-failure-rename-retry",
            )

    def test_persistent_archive_rename_failure_is_visible_and_recoverable(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-failure-rename-outage-"
        ) as value:
            output = Path(value)
            run_id = "g06-failure-rename-outage"
            first = REQUIRED_G06_TEST_EVIDENCE_IDS[0]
            runner = self._runner(
                output_root=output,
                run_id=run_id,
                executors={
                    first: lambda _root: g06.GroupResult(
                        status="invalid",
                        started_utc="2026-07-11T00:00:00.000000Z",
                        finished_utc="2026-07-11T00:00:01.000000Z",
                        commands=(),
                        artifacts=(),
                        summary={},
                        failure_reason=None,
                    )
                },
            )
            original_rename = g06._rename_exclusive_at
            rejected_archives = 0

            def reject_unique_archives(
                source_descriptor: int,
                source_name: str,
                destination_descriptor: int,
                destination_name: str,
                *,
                nofollow_any: bool = True,
            ) -> None:
                nonlocal rejected_archives
                if ".failed-recovery-" in destination_name:
                    rejected_archives += 1
                    raise OSError("injected persistent archive rename failure")
                original_rename(
                    source_descriptor,
                    source_name,
                    destination_descriptor,
                    destination_name,
                    nofollow_any=nofollow_any,
                )

            with mock.patch.object(
                g06,
                "_rename_exclusive_at",
                side_effect=reject_unique_archives,
            ), self.assertRaisesRegex(
                g06.G06VerificationError,
                "failure publication failed.*authenticated pending state",
            ):
                runner.run()

            self.assertEqual(rejected_archives, 8)
            names = g06._g06_transaction_names(run_id)
            self.assertFalse((output / names["partial_name"]).exists())
            self.assertTrue((output / names["staging_name"]).is_dir())
            self.assertTrue((output / names["marker_name"]).is_file())
            recovered = g06._recover_g06_transaction(
                output_root=output,
                run_id=run_id,
            )
            self.assertIsNotNone(recovered)
            self._exception_failure_archive(output, run_id)

    def test_crash_boundaries_recover_only_authenticated_transactions(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-crash-after-mkdir-"
        ) as value:
            output = Path(value)
            run_id = "g06-crash-after-mkdir"
            names = g06._g06_transaction_names(run_id)
            (output / names["staging_name"]).mkdir()
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "unauthenticated",
            ):
                g06._recover_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
            self.assertFalse((output / names["partial_name"]).exists())
            self.assertTrue((output / names["staging_name"]).is_dir())
            self.assertFalse((output / names["failed_name"]).exists())

        for boundary, sibling_marker in (
            ("token-write", False),
            ("marker-write", True),
        ):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-crash-{boundary}-"
            ) as value:
                output = Path(value)
                run_id = f"g06-crash-{boundary}"
                names, _ = self._pending_transaction_state(
                    output,
                    run_id,
                    sibling_marker=sibling_marker,
                )
                recovered = g06._recover_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
                self.assertIsNotNone(recovered)
                archive = self._exception_failure_archive(output, run_id)
                self.assertEqual(recovered, archive)
                record = g06._read_json(
                    next(archive.glob("g06-failure-recovery-*.json"))
                )
                self.assertEqual(
                    record["action"],
                    (
                        "recovered_interrupted_transaction"
                        if sibling_marker
                        else "recovered_pre_marker_transaction"
                    ),
                )
                self.assertFalse((output / names["staging_name"]).exists())

        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-crash-partial-rename-"
        ) as value:
            output = Path(value)
            run_id = "g06-crash-partial-rename"
            transaction = g06._begin_g06_transaction(
                output_root=output,
                run_id=run_id,
            )
            recovered = g06._recover_g06_transaction(
                output_root=output,
                run_id=run_id,
            )
            self.assertIsNotNone(recovered)
            archive = self._exception_failure_archive(output, run_id)
            self.assertEqual(
                g06._read_json(
                    next(archive.glob("g06-failure-recovery-*.json"))
                )["action"],
                "recovered_interrupted_transaction",
            )
            self.assertFalse((output / transaction.partial_name).exists())

        for boundary, destination_kind in (
            ("destination-rename-final", "final_name"),
            ("destination-rename-failed", "failed_name"),
            ("reopen", "final_name"),
        ):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-crash-{boundary}-"
            ) as value:
                output = Path(value)
                run_id = f"g06-crash-{boundary}"
                transaction = g06._begin_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
                source = output / transaction.partial_name
                destination = output / getattr(transaction, destination_kind)
                g06._rename_exclusive(source, destination)
                if boundary == "reopen":
                    descriptor = os.open(destination, os.O_RDONLY)
                    os.close(descriptor)
                recovered = g06._recover_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
                self.assertIsNotNone(recovered)
                archive = self._exception_failure_archive(output, run_id)
                self.assertEqual(
                    g06._read_json(
                        next(archive.glob("g06-failure-recovery-*.json"))
                    )["action"],
                    "recovered_interrupted_transaction",
                )
                self.assertFalse(destination.exists())

        for destination_kind in ("final_name", "failed_name"):
            with self.subTest(
                boundary="marker-removal",
                destination_kind=destination_kind,
            ), tempfile.TemporaryDirectory(
                prefix="mirmir-g06-crash-marker-removal-"
            ) as value:
                output = Path(value)
                run_id = f"g06-committed-{destination_kind}"
                transaction = g06._begin_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
                destination = output / getattr(transaction, destination_kind)
                g06._rename_exclusive(
                    output / transaction.partial_name,
                    destination,
                )
                g06._commit_g06_transaction(
                    transaction,
                    destination=destination,
                    verify_committed=lambda: None,
                )
                self.assertIsNone(
                    g06._recover_g06_transaction(
                        output_root=output,
                        run_id=run_id,
                    )
                )
                self.assertTrue(destination.is_dir())
                self.assertFalse(
                    (output / transaction.marker_name).exists()
                )

    def test_atomic_control_staging_is_recovered_or_rejected_by_authentication(
        self,
    ) -> None:
        for kind in ("root-token", "sibling-marker"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(
                prefix=f"mirmir-g06-staged-{kind}-"
            ) as value:
                output = Path(value)
                run_id = f"g06-staged-{kind}"
                names, document = self._pending_transaction_state(
                    output,
                    run_id,
                    sibling_marker=False,
                )
                payload = g06.canonical_json_bytes(document) + b"\n"
                token = str(document["transaction_token"])
                staged_name = f".{run_id}.g06-{kind}-{token}.tmp"
                if kind == "root-token":
                    canonical = output / names["staging_name"] / g06.G06_TRANSACTION_TOKEN_NAME
                    canonical.unlink()
                    parent = output / names["staging_name"]
                else:
                    parent = output
                parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    g06._write_new_at(
                        parent_descriptor,
                        staged_name,
                        payload,
                        mode=0o600,
                        label=f"test staged {kind}",
                    )
                finally:
                    os.close(parent_descriptor)

                recovered = g06._recover_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
                self.assertIsNotNone(recovered)
                archive = self._exception_failure_archive(output, run_id)
                self.assertEqual(recovered, archive)
                if kind == "root-token":
                    self.assertTrue((archive / staged_name).is_file())
                else:
                    self.assertFalse((output / staged_name).exists())

        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-staged-malformed-"
        ) as value:
            output = Path(value)
            run_id = "g06-staged-malformed"
            names = g06._g06_transaction_names(run_id)
            staging = output / names["staging_name"]
            staging.mkdir()
            staged_name = f".{run_id}.g06-root-token-{'a' * 32}.tmp"
            (staging / staged_name).write_bytes(b"{\n")
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "invalid JSON evidence",
            ):
                g06._recover_g06_transaction(
                    output_root=output,
                    run_id=run_id,
                )
            self.assertTrue((staging / staged_name).is_file())
            self.assertFalse((output / names["partial_name"]).exists())

    def test_tree_binding_includes_empty_directory_entries(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-tree-binding-") as value:
            run_root = Path(value)
            tree = run_root / "artifacts/tree"
            tree.mkdir(parents=True)
            (tree / "payload.bin").write_bytes(b"payload")
            before = g06._tree_binding(
                tree,
                run_root=run_root,
                artifact_kind="test_tree",
            )

            (tree / "empty").mkdir()
            after = g06._tree_binding(
                tree,
                run_root=run_root,
                artifact_kind="test_tree",
            )

            self.assertEqual(before["file_count"], after["file_count"])
            self.assertEqual(before["size_bytes"], after["size_bytes"])
            self.assertNotEqual(before["sha256"], after["sha256"])

    def test_xcode_commands_are_explicit_and_do_not_reference_holdout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-command-") as value:
            runner = self._runner(
                output_root=Path(value),
                run_id="g06-command",
                executors={},
            )
            command = runner._xcode_test_command(
                configuration="Debug",
                derived_data=Path(value) / "derived",
                result_bundle=Path(value) / "result.xcresult",
                tests=g06.NATIVE_INTEGRATION_TESTS,
                clean=True,
            )
            self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
            self.assertNotIn("ENABLE_TESTABILITY=YES", command)
            self.assertNotIn("-jobs", command)
            self.assertIn("-enableCodeCoverage", command)
            self.assertEqual(
                [value for value in command if value.startswith("-only-testing:")],
                [
                    f"-only-testing:MirmirTests/{name}"
                    for name in g06.NATIVE_INTEGRATION_TESTS
                ],
            )
            self.assertEqual(command[-2:], ("clean", "test"))

            release_command = runner._xcode_test_command(
                configuration="Release",
                derived_data=Path(value) / "release-derived",
                result_bundle=Path(value) / "release-result.xcresult",
                tests=g06.RELEASE_RUNTIME_TESTS,
                clean=False,
            )
            self.assertEqual(release_command[-1], "test")
            self.assertNotIn("clean", release_command)
            self.assertIn("ENABLE_TESTABILITY=YES", release_command)
            jobs_index = release_command.index("-jobs")
            self.assertEqual(
                release_command[jobs_index : jobs_index + 2],
                ("-jobs", "1"),
            )
            self.assertNotIn("holdout", " ".join(command).lower())
            self.assertNotIn("holdout", " ".join(release_command).lower())

    def test_cli_requires_the_frozen_runtime_root_and_manifest_file_hash(
        self,
    ) -> None:
        argv = [
            "run_g06_verification.py",
            "--repository-root",
            str(REPOSITORY_ROOT),
            "--output-root",
            str(REPOSITORY_ROOT / "Artifacts/ASH/g06-cli-test"),
            "--run-id",
            "g06-cli-test",
            "--native-runtime-evidence-root",
            str(REPOSITORY_ROOT / "Artifacts/ASH/runtime-cli-test"),
            "--expected-native-runtime-manifest-file-sha256",
            "0" * 64,
        ]
        with mock.patch.object(sys, "argv", argv):
            arguments = g06._arguments()
        self.assertEqual(
            arguments.native_runtime_evidence_root,
            REPOSITORY_ROOT / "Artifacts/ASH/runtime-cli-test",
        )
        self.assertEqual(
            arguments.expected_native_runtime_manifest_file_sha256,
            "0" * 64,
        )

        with mock.patch.object(sys, "argv", argv[:-2]), mock.patch.object(
            sys,
            "stderr",
            io.StringIO(),
        ), self.assertRaises(SystemExit):
            g06._arguments()

    def test_command_execution_removes_collection_affecting_environment(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-command-environment-"
        ) as value:
            root = Path(value)
            runner = self._runner(
                output_root=root / "publication",
                run_id="g06-command-environment",
                executors={},
            )
            run_root = root / "run"
            run_root.mkdir()
            captured: dict[str, str] = {}

            def execute(*_arguments: object, **arguments: object) -> object:
                captured.update(arguments["env"])
                return g06.subprocess.CompletedProcess(
                    args=arguments,
                    returncode=0,
                )

            with mock.patch.dict(
                os.environ,
                {
                    "PYTEST_ADDOPTS": "--ignore=validation/calibration_v2/tests",
                    "PYTEST_PLUGINS": "substituted_plugin",
                    "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT": "/tmp/substituted.json",
                    "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT": (
                        "/tmp/substituted-native.json"
                    ),
                    "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK": "0",
                    "PYTHONHOME": "/tmp/substituted-home",
                    "PYTHONOPTIMIZE": "2",
                    "PYTHONPATH": "/tmp/substituted-path",
                },
                clear=False,
            ), mock.patch.object(
                g06.subprocess,
                "run",
                side_effect=execute,
            ):
                result = runner._execute_command(
                    run_root=run_root,
                    command_index=1,
                    argv=("/usr/bin/true",),
                    log_artifact_id="logs/environment.log",
                )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(captured["PYTHONPATH"], str(REPOSITORY_ROOT))
            self.assertNotIn("PYTEST_ADDOPTS", captured)
            self.assertNotIn("PYTEST_PLUGINS", captured)
            self.assertNotIn("MIRMIR_AGGREGATE_BENCHMARK_OUTPUT", captured)
            self.assertNotIn(
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT",
                captured,
            )
            self.assertNotIn("MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK", captured)
            self.assertNotIn("PYTHONHOME", captured)
            self.assertEqual(captured["PYTHONOPTIMIZE"], "")

    def test_constructor_rejects_malformed_runtime_manifest_hash(self) -> None:
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-hash-format-",
            dir=artifacts_root,
        ) as value, self.assertRaisesRegex(
            g06.G06VerificationError,
            "not a lowercase SHA-256",
        ):
            g06.G06VerificationRunner(
                repository_root=REPOSITORY_ROOT,
                output_root=Path(value) / "publication",
                run_id="g06-native-hash-format",
                native_runtime_evidence_root=Path(value),
                expected_native_runtime_manifest_file_sha256="A" * 64,
            )

    def test_python_suite_binds_explicit_frozen_native_runtime(self) -> None:
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-runtime-",
            dir=artifacts_root,
        ) as value:
            root = Path(value)
            source, manifest_sha256, payload = create_frozen_runtime_fixture(
                root,
                repository_root=REPOSITORY_ROOT,
                repository_state=self.repository_state,
            )
            try:
                runner = g06.G06VerificationRunner(
                    repository_root=REPOSITORY_ROOT,
                    output_root=root / "publication",
                    run_id="g06-native-input",
                    native_runtime_evidence_root=source,
                    expected_native_runtime_manifest_file_sha256=(
                        manifest_sha256
                    ),
                )
                run_root = root / "run"
                run_root.mkdir()

                def command(**arguments: object) -> dict[str, object]:
                    argv = list(arguments["argv"])
                    artifact_id = str(arguments["log_artifact_id"])
                    log_path = g06._safe_child(run_root, artifact_id)
                    log_payload = (
                        b"1 passed in 0.01s\n"
                        if "pytest" in argv
                        else b"Ran 1 test in 0.01s\n\nOK\n"
                    )
                    g06._write_new(log_path, log_payload)
                    binding = g06._file_binding(
                        log_path,
                        run_root=run_root,
                        artifact_kind="command_log",
                    )
                    return {
                        "command_index": int(arguments["command_index"]),
                        "argv": argv,
                        "command_text": " ".join(argv),
                        "working_directory": ".",
                        "exit_code": 0,
                        "timed_out": False,
                        "duration_seconds": 0.0,
                        "status": "passed",
                        "log_binding": binding,
                    }

                with mock.patch.object(
                    runner,
                    "_execute_command",
                    side_effect=command,
                ):
                    result = runner._python_full_suite(run_root)
                self.assertEqual(result.status, "passed")
                copied_root = run_root / "inputs/native-runtime-evidence"
                copied = copied_root / "native-aggregate-benchmark.json"
                self.assertEqual(copied.read_bytes(), payload)
                self.assertEqual(
                    (copied_root / "artifact-manifest.json").read_bytes(),
                    (source / "artifact-manifest.json").read_bytes(),
                )
                runtime_binding = next(
                    binding
                    for binding in result.artifacts
                    if binding["artifact_kind"]
                    == "native_runtime_evidence_input"
                )
                self.assertEqual(
                    runtime_binding,
                    result.summary["native_runtime_evidence_input"],
                )
                self.assertEqual(
                    result.summary["native_runtime_source"][
                        "manifest_file_sha256"
                    ],
                    manifest_sha256,
                )
                pytest_command = result.commands[1]
                self.assertEqual(
                    pytest_command["argv"][:10],
                    [
                        "/usr/bin/env",
                        "PYTEST_ADDOPTS=",
                        "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1",
                        "PYTEST_PLUGINS=",
                        "PYTHONHOME=",
                        "PYTHONOPTIMIZE=",
                        f"PYTHONPATH={REPOSITORY_ROOT}",
                        "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT=",
                        "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=1",
                        (
                            "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                            f"{copied}"
                        ),
                    ],
                )
                self.assertEqual(
                    pytest_command["argv"][13:18],
                    [
                        "-c",
                        "/dev/null",
                        "-p",
                        "no:cacheprovider",
                        "--noconftest",
                    ],
                )
                native_proof_command = result.commands[2]
                self.assertEqual(
                    native_proof_command["argv"][-1],
                    g06.NATIVE_BENCHMARK_PROOF_NODE_ID,
                )
                self.assertEqual(
                    result.summary["required_runner_order"],
                    list(g06.PYTHON_TEST_RUNNER_IDS),
                )
                evidence = runner._evidence_document(
                    "python_calibration_full_suite",
                    1,
                    result,
                )
                self.assertEqual(evidence["schema_version"], "1.2.0")
                g06.validate_schema(evidence, g06.SCHEMA_PATH)
            finally:
                thaw_and_remove_runtime_fixture(source)

    def test_python_suite_rejects_missing_or_changed_native_runtime(
        self,
    ) -> None:
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-reject-",
            dir=artifacts_root,
        ) as value:
            root = Path(value)
            runner = self._runner(
                output_root=root / "publication",
                run_id="g06-native-missing",
                executors={},
            )
            run_root = root / "run"
            run_root.mkdir()
            with self.assertRaisesRegex(
                g06.G06VerificationError,
                "runtime evidence input is absent",
            ):
                runner._python_full_suite(run_root)

            source, manifest_sha256, _ = create_frozen_runtime_fixture(
                root,
                repository_root=REPOSITORY_ROOT,
                repository_state=self.repository_state,
            )
            try:
                with self.assertRaisesRegex(
                    g06.G06VerificationError,
                    "manifest file SHA-256 differs",
                ):
                    g06.G06VerificationRunner(
                        repository_root=REPOSITORY_ROOT,
                        output_root=root / "publication-2",
                        run_id="g06-native-hash-mismatch",
                        native_runtime_evidence_root=source,
                        expected_native_runtime_manifest_file_sha256="0" * 64,
                    )

                runner = g06.G06VerificationRunner(
                    repository_root=REPOSITORY_ROOT,
                    output_root=root / "publication-3",
                    run_id="g06-native-changed",
                    native_runtime_evidence_root=source,
                    expected_native_runtime_manifest_file_sha256=(
                        manifest_sha256
                    ),
                )
                manifest_path = source / "artifact-manifest.json"
                for path in (source, manifest_path):
                    flags = os.stat(path, follow_symlinks=False).st_flags
                    os.chflags(
                        path,
                        flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )
                    os.chmod(path, 0o755 if path.is_dir() else 0o644)
                manifest_path.write_bytes(b"changed-after-construction\n")
                changed_root = root / "changed-run"
                changed_root.mkdir()
                with self.assertRaisesRegex(
                    g06.G06VerificationError,
                    "changed before Python verification",
                ):
                    runner._python_full_suite(changed_root)
            finally:
                thaw_and_remove_runtime_fixture(source)

    def test_native_runtime_source_is_confined_before_verification(self) -> None:
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-confinement-"
        ) as outside_value, tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-symlink-",
            dir=artifacts_root,
        ) as inside_value:
            outside = Path(outside_value)
            with mock.patch.object(
                g06,
                "verify_frozen_runtime_correction",
            ) as verifier:
                with self.assertRaisesRegex(
                    g06.G06VerificationError,
                    "escapes the repository",
                ):
                    g06.G06VerificationRunner(
                        repository_root=REPOSITORY_ROOT,
                        output_root=outside / "publication",
                        run_id="g06-outside-runtime",
                        native_runtime_evidence_root=outside,
                        expected_native_runtime_manifest_file_sha256="0" * 64,
                    )
                verifier.assert_not_called()

            link = Path(inside_value) / "linked-runtime"
            link.symlink_to(outside, target_is_directory=True)
            with mock.patch.object(
                g06,
                "verify_frozen_runtime_correction",
            ) as verifier:
                with self.assertRaisesRegex(
                    g06.G06VerificationError,
                    "symbolic or non-directory ancestor",
                ):
                    g06.G06VerificationRunner(
                        repository_root=REPOSITORY_ROOT,
                        output_root=outside / "publication-2",
                        run_id="g06-linked-runtime",
                        native_runtime_evidence_root=link,
                        expected_native_runtime_manifest_file_sha256="0" * 64,
                    )
                verifier.assert_not_called()

    def test_native_runtime_rejects_current_dirty_repository_state(self) -> None:
        artifacts_root = REPOSITORY_ROOT / "Artifacts/ASH"
        artifacts_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="mirmir-g06-native-current-state-",
            dir=artifacts_root,
        ) as value:
            root = Path(value)
            source, manifest_sha256, _ = create_frozen_runtime_fixture(
                root,
                repository_root=REPOSITORY_ROOT,
                repository_state=self.repository_state,
            )
            try:
                with mock.patch.object(
                    g06,
                    "runtime_correction_repository_state",
                    return_value=(self.repository_state, False),
                ), self.assertRaisesRegex(
                    g06.G06VerificationError,
                    "current repository state differs",
                ):
                    g06.G06VerificationRunner(
                        repository_root=REPOSITORY_ROOT,
                        output_root=root / "publication",
                        run_id="g06-current-dirty",
                        native_runtime_evidence_root=source,
                        expected_native_runtime_manifest_file_sha256=(
                            manifest_sha256
                        ),
                    )
            finally:
                thaw_and_remove_runtime_fixture(source)

    def test_xcresult_is_bound_after_summary_tool_materializes_lazy_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mirmir-g06-xcresult-") as value:
            run_root = Path(value)
            runner = self._runner(
                output_root=run_root / "publication",
                run_id="g06-xcresult",
                executors={},
            )
            result_bundle = run_root / "artifacts/native-integration.xcresult"

            def command(**arguments: object) -> dict[str, object]:
                command_index = int(arguments["command_index"])
                artifact_id = str(arguments["log_artifact_id"])
                log_path = g06._safe_child(run_root, artifact_id)
                log_path.parent.mkdir(parents=True, exist_ok=True)
                argv = list(arguments["argv"])
                if command_index == 1:
                    result_bundle.mkdir(parents=True)
                    (result_bundle / "Info.plist").write_bytes(b"initial")
                    payload = b"** TEST SUCCEEDED **\n"
                else:
                    (result_bundle / "database.sqlite3").write_bytes(b"lazy")
                    payload = g06.canonical_json_bytes(
                        {
                            "totalTestCount": 1,
                            "passedTests": 1,
                            "failedTests": 0,
                            "skippedTests": 0,
                            "expectedFailures": 0,
                            "result": "Passed",
                        }
                    ) + b"\n"
                g06._write_new(log_path, payload)
                binding = g06._file_binding(
                    log_path,
                    run_root=run_root,
                    artifact_kind=str(arguments.get("artifact_kind", "command_log")),
                )
                return {
                    "command_index": command_index,
                    "argv": argv,
                    "command_text": " ".join(argv),
                    "working_directory": ".",
                    "exit_code": 0,
                    "timed_out": False,
                    "duration_seconds": 0.0,
                    "status": "passed",
                    "log_binding": binding,
                }

            with mock.patch.object(runner, "_execute_command", side_effect=command):
                result = runner._xcode_native_integration(run_root)
            self.assertEqual(result.status, "passed")
            xcresult = next(
                binding
                for binding in result.artifacts
                if binding["artifact_id"]
                == "artifacts/native-integration.xcresult"
            )
            self.assertEqual(xcresult["file_count"], 2)
            self.assertEqual(
                xcresult,
                g06._tree_binding(
                    result_bundle,
                    run_root=run_root,
                    artifact_kind="xcresult",
                ),
            )


if __name__ == "__main__":
    unittest.main()
