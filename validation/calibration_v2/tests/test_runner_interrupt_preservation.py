from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import uuid

from validation.calibration_v2 import runner


class CalibrationRunInterruptPreservationTests(unittest.TestCase):
    @staticmethod
    def _executor(output_root: Path, run_id: str) -> runner.CalibrationExecutor:
        executor = object.__new__(runner.CalibrationExecutor)
        executor.repository_root = output_root / "unused-repository"
        executor.output_root = output_root
        executor.run_id = run_id
        executor.live_holdout_preopen_binding = None
        executor.implementation_manifest_validator = None
        return executor

    @staticmethod
    def _recovery_history(path: Path) -> list[dict[str, object]]:
        directory = path / runner._RUN_RECOVERY_DIRECTORY
        return [
            json.loads(record_path.read_bytes())
            for record_path in sorted(directory.glob("*.json"))
        ]

    @staticmethod
    def _bound_inputs(root: Path) -> runner.BoundInputs:
        return runner.BoundInputs(
            repository_root=root,
            records=(),
            documents={},
            live_holdout_preopen_binding=None,
            live_holdout_preopen_verification={"status": "unopened"},
            bundle_sha256="b" * 64,
        )

    @staticmethod
    def _write_preserved_run(
        path: Path,
        bound: runner.BoundInputs,
    ) -> None:
        path.mkdir(mode=0o700)
        runner._write_json_atomic_durable(
            path / "input-bindings.json",
            {
                "bundle_sha256": bound.bundle_sha256,
                "records": list(bound.records),
                "live_holdout_preopen_verification": dict(
                    bound.live_holdout_preopen_verification
                ),
            },
        )
        attempts = b""
        (path / "attempts.ndjson").write_bytes(attempts)
        runner._write_json_atomic_durable(
            path / "failure.json",
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_calibration_failure",
                "run_id": path.name,
                "error_type": "RuntimeError",
                "error": "preserved",
                "attempt_count": 0,
                "attempt_ledger_sha256": hashlib.sha256(attempts).hexdigest(),
                "holdout_accessed": False,
                "release_locks_written": False,
            },
        )

    def _assert_preserved_base_exception(
        self,
        exception: BaseException,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-interrupt-preservation-"
        ) as value:
            output_root = Path(value) / "runs"
            run_id = type(exception).__name__.lower()
            executor = self._executor(output_root, run_id)
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=exception,
            ):
                with self.assertRaises(type(exception)) as raised:
                    executor.run()
            self.assertIs(raised.exception, exception)

            partial = output_root / f".{run_id}.partial"
            failed = output_root / f"{run_id}.failed"
            self.assertFalse(partial.exists())
            self.assertTrue(failed.is_dir())
            attempts = failed / "attempts.ndjson"
            self.assertEqual(attempts.read_bytes(), b"")
            failure = json.loads((failed / "failure.json").read_bytes())
            self.assertEqual(
                failure,
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": "p06_calibration_failure",
                    "run_id": run_id,
                    "error_type": type(exception).__name__,
                    "error": str(exception),
                    "attempt_count": 0,
                    "attempt_ledger_sha256": hashlib.sha256(b"").hexdigest(),
                    "holdout_accessed": False,
                    "release_locks_written": False,
                },
            )

    def test_attempt_ledger_rejects_entry_swap_after_creation(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-attempt-ledger-entry-swap-"
        ) as value:
            directory = Path(value)
            path = directory / "attempts.ndjson"
            directory_descriptor, _ = runner._open_directory_nofollow(directory)
            try:
                ledger = runner.AttemptLedger(
                    path,
                    directory_descriptor=directory_descriptor,
                )
            finally:
                runner.os.close(directory_descriptor)
            opened_inode = directory / "attempts.opened-inode"
            path.rename(opened_inode)
            path.write_bytes(b"replacement")

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "entry was replaced",
            ):
                ledger.append({"status": "must-not-append"})
            with self.assertRaisesRegex(
                runner.CalibrationError,
                "entry was replaced",
            ):
                ledger.close()
            self.assertEqual(opened_inode.read_bytes(), b"")
            self.assertEqual(path.read_bytes(), b"replacement")

    def test_preserved_run_rejects_symlinked_critical_children(self) -> None:
        for child_name in (
            "input-bindings.json",
            "attempts.ndjson",
            "failure.json",
        ):
            with self.subTest(child=child_name), tempfile.TemporaryDirectory(
                prefix="mirmir-preserved-child-symlink-"
            ) as value:
                root = Path(value)
                bound = self._bound_inputs(root)
                preserved = root / "preserved.failed"
                self._write_preserved_run(preserved, bound)
                child = preserved / child_name
                foreign = root / f"foreign-{child_name}"
                child.rename(foreign)
                child.symlink_to(foreign)

                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "symbolic or invalid entry",
                ):
                    runner.verify_preserved_run(preserved, bound)
                self.assertTrue(child.is_symlink())
                self.assertTrue(foreign.is_file())

    def test_preserved_run_rejects_attempt_swap_after_single_read(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-preserved-attempt-swap-"
        ) as value:
            root = Path(value)
            bound = self._bound_inputs(root)
            preserved = root / "preserved.failed"
            self._write_preserved_run(preserved, bound)
            attempts = preserved / "attempts.ndjson"
            opened_inode = preserved / "attempts.opened-inode"
            replacement = root / "replacement-attempts.ndjson"
            replacement.write_bytes(b'{"replacement":true}\n')
            real_read = runner._read_regular_at
            swapped = False

            def read_then_swap(
                directory_descriptor: int,
                name: str,
                **kwargs: object,
            ) -> bytes:
                nonlocal swapped
                payload = real_read(directory_descriptor, name, **kwargs)
                if name == "attempts.ndjson" and not swapped:
                    attempts.rename(opened_inode)
                    replacement.rename(attempts)
                    swapped = True
                return payload

            with mock.patch.object(
                runner,
                "_read_regular_at",
                side_effect=read_then_swap,
            ):
                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "changed while sealing|changed while verifying",
                ):
                    runner.verify_preserved_run(preserved, bound)
            self.assertEqual(opened_inode.read_bytes(), b"")
            self.assertEqual(attempts.read_bytes(), b'{"replacement":true}\n')

    def test_preserved_run_rejects_real_directory_replacement(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-preserved-directory-swap-"
        ) as value:
            root = Path(value)
            bound = self._bound_inputs(root)
            preserved = root / "preserved.failed"
            self._write_preserved_run(preserved, bound)
            moved = root / "preserved-opened-inode.failed"
            foreign_sentinel = preserved / "foreign.txt"
            real_read = runner._read_regular_at
            swapped = False

            def read_then_replace_directory(
                directory_descriptor: int,
                name: str,
                **kwargs: object,
            ) -> bytes:
                nonlocal swapped
                payload = real_read(directory_descriptor, name, **kwargs)
                if name == "input-bindings.json" and not swapped:
                    preserved.rename(moved)
                    preserved.mkdir()
                    foreign_sentinel.write_bytes(b"foreign")
                    swapped = True
                return payload

            with mock.patch.object(
                runner,
                "_read_regular_at",
                side_effect=read_then_replace_directory,
            ):
                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "directory changed while verifying",
                ):
                    runner.verify_preserved_run(preserved, bound)
            self.assertEqual(foreign_sentinel.read_bytes(), b"foreign")
            self.assertTrue((moved / "input-bindings.json").is_file())

    def test_preserved_run_requires_failure_boundary_fields(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-preserved-failure-boundary-"
        ) as value:
            root = Path(value)
            bound = self._bound_inputs(root)
            preserved = root / "preserved.failed"
            self._write_preserved_run(preserved, bound)
            failure_path = preserved / "failure.json"
            failure = json.loads(failure_path.read_bytes())
            failure["holdout_accessed"] = True
            failure_path.write_text(
                json.dumps(failure, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "failure does not bind",
            ):
                runner.verify_preserved_run(preserved, bound)

    def test_keyboard_interrupt_is_archived_then_reraised_unchanged(self) -> None:
        self._assert_preserved_base_exception(
            KeyboardInterrupt("operator interrupted calibration")
        )

    def test_system_exit_is_archived_then_reraised_unchanged(self) -> None:
        self._assert_preserved_base_exception(SystemExit(130))

    def test_ordinary_exception_keeps_wrapped_failure_contract(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-exception-preservation-"
        ) as value:
            output_root = Path(value) / "runs"
            executor = self._executor(output_root, "ordinary")
            primary = RuntimeError("ordinary calibration failure")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=primary,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as raised:
                    executor.run()
            self.assertIs(raised.exception.__cause__, primary)
            self.assertEqual(
                raised.exception.failure_path,
                output_root / "ordinary.failed",
            )

    def test_archive_failures_never_mask_keyboard_interrupt(self) -> None:
        durable_write = runner._write_json_atomic_durable

        def fail_failure_write(
            path: Path,
            value: object,
            **kwargs: object,
        ) -> None:
            if path.name == "failure.json":
                raise RuntimeError("archive write failure")
            durable_write(path, value, **kwargs)

        failures = {
            "ledger_close": mock.patch.object(
                runner.AttemptLedger,
                "close",
                side_effect=RuntimeError("archive close failure"),
            ),
            "ledger_verification": mock.patch.object(
                runner,
                "_verify_attempt_ledger_payload",
                side_effect=SystemExit(92),
            ),
            "failure_write": mock.patch.object(
                runner,
                "_write_json_atomic_durable",
                side_effect=fail_failure_write,
            ),
            "archive_replace": mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=RuntimeError("archive replace failure"),
            ),
        }
        for label, archive_failure in failures.items():
            with self.subTest(failure=label), tempfile.TemporaryDirectory(
                prefix="mirmir-run-archive-failure-"
            ) as value:
                output_root = Path(value) / "runs"
                executor = self._executor(output_root, label)
                primary = KeyboardInterrupt(f"primary interrupt: {label}")
                with mock.patch.object(
                    runner,
                    "bind_preregistered_inputs",
                    side_effect=primary,
                ), archive_failure:
                    with self.assertRaises(KeyboardInterrupt) as raised:
                        executor.run()
                self.assertIs(raised.exception, primary)

    def test_ordinary_exception_is_not_wrapped_when_archive_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-invalid-archive-"
        ) as value:
            output_root = Path(value) / "runs"
            executor = self._executor(output_root, "invalid-archive")
            primary = RuntimeError("ordinary primary without valid archive")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=primary,
            ), mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=RuntimeError("archive replace failure"),
            ):
                with self.assertRaises(RuntimeError) as raised:
                    executor.run()
            self.assertIs(raised.exception, primary)
            self.assertFalse((output_root / "invalid-archive.failed").exists())

    def test_rename_failure_partial_is_recovered_on_next_launch(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-rename-recovery-"
        ) as value:
            output_root = Path(value) / "runs"
            run_id = "rename-recovery"
            first = self._executor(output_root, run_id)
            first_error = RuntimeError("first run fails before binding")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=first_error,
            ), mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=OSError("injected atomic rename failure"),
            ):
                with self.assertRaises(RuntimeError) as raised:
                    first.run()
            self.assertIs(raised.exception, first_error)
            partial = output_root / f".{run_id}.partial"
            self.assertTrue(partial.is_dir())
            transaction = json.loads(
                (partial / runner._RUN_TRANSACTION_MARKER).read_bytes()
            )
            preserved_failure = json.loads((partial / "failure.json").read_bytes())

            second = self._executor(output_root, run_id)
            second_error = RuntimeError("second run reached a clean transaction")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=second_error,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as reraised:
                    second.run()
            self.assertIs(reraised.exception.__cause__, second_error)

            recovered = output_root / (
                f"{run_id}.recovered-{transaction['transaction_id']}.failed"
            )
            self.assertTrue(recovered.is_dir())
            self.assertEqual(
                json.loads((recovered / "failure.json").read_bytes()),
                preserved_failure,
            )
            self.assertFalse(partial.exists())
            self.assertTrue((output_root / f"{run_id}.failed").is_dir())

    def test_two_consecutive_crashes_preserve_transaction_keyed_history(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-consecutive-recovery-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "consecutive-recovery"
            first_transaction_id = str(uuid.uuid4())
            partial = output_root / f".{run_id}.partial"
            partial.mkdir(mode=0o700)
            runner._write_json_atomic_durable(
                partial / runner._RUN_TRANSACTION_MARKER,
                runner._run_transaction_marker(run_id, first_transaction_id),
            )

            real_publish = runner._rename_directory_exclusive_at
            publication_count = 0

            def fail_second_publication(*args: object, **kwargs: object) -> None:
                nonlocal publication_count
                publication_count += 1
                if publication_count == 2:
                    raise OSError("injected second transaction crash")
                real_publish(*args, **kwargs)

            first_executor = self._executor(output_root, run_id)
            first_error = RuntimeError("transaction B stops before binding")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=first_error,
            ), mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=fail_second_publication,
            ):
                with self.assertRaises(RuntimeError) as first_raised:
                    first_executor.run()
            self.assertIs(first_raised.exception, first_error)
            second_transaction = json.loads(
                (partial / runner._RUN_TRANSACTION_MARKER).read_bytes()
            )
            second_transaction_id = str(second_transaction["transaction_id"])
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(partial)
                },
                {first_transaction_id},
            )

            second_executor = self._executor(output_root, run_id)
            second_error = RuntimeError("transaction C reached clean execution")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=second_error,
            ):
                with self.assertRaises(
                    runner.CalibrationRunInterrupted
                ) as second_raised:
                    second_executor.run()
            self.assertIs(second_raised.exception.__cause__, second_error)

            second_recovered = output_root / (
                f"{run_id}.recovered-{second_transaction_id}.failed"
            )
            expected_ids = {first_transaction_id, second_transaction_id}
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(second_recovered)
                },
                expected_ids,
            )
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(
                        output_root / f"{run_id}.failed"
                    )
                },
                expected_ids,
            )

    def test_reverse_lexical_history_is_canonical_across_intent_retry(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-canonical-history-order-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "canonical-history-order"
            high_transaction_id = "ffffffff-ffff-4fff-8fff-ffffffffffff"
            low_transaction_id = "00000000-0000-4000-8000-000000000001"
            partial = output_root / f".{run_id}.partial"
            partial.mkdir(mode=0o700)
            runner._write_json_atomic_durable(
                partial / runner._RUN_TRANSACTION_MARKER,
                runner._run_transaction_marker(run_id, high_transaction_id),
            )
            real_uuid4 = runner.uuid.uuid4
            uuid_call_count = 0

            def reverse_transaction_uuid() -> uuid.UUID:
                nonlocal uuid_call_count
                uuid_call_count += 1
                if uuid_call_count == 3:
                    return uuid.UUID(low_transaction_id)
                return real_uuid4()

            real_publish = runner._rename_directory_exclusive_at
            publication_count = 0

            def fail_second_publication(*args: object, **kwargs: object) -> None:
                nonlocal publication_count
                publication_count += 1
                if publication_count == 2:
                    raise OSError("leave reverse-ordered second transaction partial")
                real_publish(*args, **kwargs)

            first = self._executor(output_root, run_id)
            first_error = RuntimeError("second transaction stops")
            with mock.patch.object(
                runner.uuid,
                "uuid4",
                side_effect=reverse_transaction_uuid,
            ), mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=fail_second_publication,
            ), mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=first_error,
            ):
                with self.assertRaises(RuntimeError) as first_raised:
                    first.run()
            self.assertIs(first_raised.exception, first_error)
            self.assertEqual(
                json.loads(
                    (partial / runner._RUN_TRANSACTION_MARKER).read_bytes()
                )["transaction_id"],
                low_transaction_id,
            )

            second = self._executor(output_root, run_id)
            with mock.patch.object(
                runner,
                "_remove_run_transaction_intent_at",
                side_effect=SystemExit(88),
            ):
                with self.assertRaises(SystemExit):
                    second.run()
            intent_path = output_root / runner._run_transaction_intent_name(run_id)
            self.assertTrue(intent_path.is_symlink())
            root_descriptor, _ = runner._open_directory_nofollow(output_root)
            try:
                intent = runner._read_run_transaction_intent_at(
                    root_descriptor,
                    run_id=run_id,
                )
            finally:
                runner.os.close(root_descriptor)
            canonical_pair = self._recovery_history(
                output_root
                / f"{run_id}.recovered-{low_transaction_id}.failed"
            )
            self.assertEqual(
                [record["stale_transaction_id"] for record in canonical_pair],
                [low_transaction_id, high_transaction_id],
            )
            self.assertEqual(
                intent["inherited_recovery_history_sha256"],
                runner.canonical_sha256(canonical_pair),
            )

            third = self._executor(output_root, run_id)
            final_error = RuntimeError("canonical history retry reached binding")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=final_error,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as raised:
                    third.run()
            self.assertIs(raised.exception.__cause__, final_error)
            failed_history = self._recovery_history(
                output_root / f"{run_id}.failed"
            )
            self.assertTrue(
                {low_transaction_id, high_transaction_id}.issubset(
                    {
                        str(record["stale_transaction_id"])
                        for record in failed_history
                    }
                )
            )

    def test_inherited_history_restores_after_empty_directory_crash(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-inherited-history-crash-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "inherited-history-crash"
            first_transaction_id = str(uuid.uuid4())
            partial = output_root / f".{run_id}.partial"
            partial.mkdir(mode=0o700)
            runner._write_json_atomic_durable(
                partial / runner._RUN_TRANSACTION_MARKER,
                runner._run_transaction_marker(run_id, first_transaction_id),
            )
            real_write_history = runner._write_recovery_history_at
            history_write_count = 0

            def crash_after_empty_history_directory(
                partial_descriptor: int,
                *,
                partial: Path,
                records: object,
            ) -> None:
                nonlocal history_write_count
                history_write_count += 1
                if history_write_count == 2:
                    history_descriptor = runner._open_or_create_child_directory_at(
                        partial_descriptor,
                        runner._RUN_RECOVERY_DIRECTORY,
                        display_path=partial / runner._RUN_RECOVERY_DIRECTORY,
                    )
                    runner.os.close(history_descriptor)
                    raise SystemExit(86)
                real_write_history(
                    partial_descriptor,
                    partial=partial,
                    records=records,
                )

            first = self._executor(output_root, run_id)
            with mock.patch.object(
                runner,
                "_write_recovery_history_at",
                side_effect=crash_after_empty_history_directory,
            ):
                with self.assertRaises(SystemExit):
                    first.run()
            second_transaction = json.loads(
                (partial / runner._RUN_TRANSACTION_MARKER).read_bytes()
            )
            second_transaction_id = str(second_transaction["transaction_id"])
            self.assertEqual(
                list((partial / runner._RUN_RECOVERY_DIRECTORY).iterdir()),
                [],
            )
            self.assertTrue(
                (
                    output_root / runner._run_transaction_intent_name(run_id)
                ).is_symlink()
            )

            second = self._executor(output_root, run_id)
            primary = RuntimeError("retry reached binding after inherited restore")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=primary,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as raised:
                    second.run()
            self.assertIs(raised.exception.__cause__, primary)
            recovered = output_root / (
                f"{run_id}.recovered-{second_transaction_id}.failed"
            )
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(recovered)
                },
                {first_transaction_id, second_transaction_id},
            )
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(
                        output_root / f"{run_id}.failed"
                    )
                },
                {first_transaction_id, second_transaction_id},
            )

    def test_recovered_archive_scan_closes_pre_intent_handoff_crash(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-pre-intent-handoff-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "pre-intent-handoff"
            transaction_id = str(uuid.uuid4())
            partial = output_root / f".{run_id}.partial"
            partial.mkdir(mode=0o700)
            runner._write_json_atomic_durable(
                partial / runner._RUN_TRANSACTION_MARKER,
                runner._run_transaction_marker(run_id, transaction_id),
            )
            real_create_intent = runner._create_run_transaction_intent_at

            def crash_before_inherited_intent(
                output_root_descriptor: int,
                **kwargs: object,
            ) -> object:
                if kwargs.get("inherited_recovery_history"):
                    raise SystemExit(87)
                return real_create_intent(output_root_descriptor, **kwargs)

            first = self._executor(output_root, run_id)
            with mock.patch.object(
                runner,
                "_create_run_transaction_intent_at",
                side_effect=crash_before_inherited_intent,
            ):
                with self.assertRaises(SystemExit):
                    first.run()
            recovered = output_root / (
                f"{run_id}.recovered-{transaction_id}.failed"
            )
            self.assertTrue(recovered.is_dir())
            self.assertFalse(partial.exists())
            self.assertFalse(
                (
                    output_root / runner._run_transaction_intent_name(run_id)
                ).is_symlink()
            )

            second = self._executor(output_root, run_id)
            primary = RuntimeError("scan-seeded run reached binding")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=primary,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as raised:
                    second.run()
            self.assertIs(raised.exception.__cause__, primary)
            self.assertEqual(
                {
                    record["stale_transaction_id"]
                    for record in self._recovery_history(
                        output_root / f"{run_id}.failed"
                    )
                },
                {transaction_id},
            )
    def test_torn_ledger_failure_is_retry_compatible_after_rename_failure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-torn-ledger-recovery-"
        ) as value:
            output_root = Path(value) / "runs"
            run_id = "torn-ledger"
            partial = output_root / f".{run_id}.partial"
            first = self._executor(output_root, run_id)
            first_error = RuntimeError("primary failure after torn ledger")

            def tear_ledger_then_fail(*_args: object, **_kwargs: object) -> None:
                descriptor = runner.os.open(
                    partial / "attempts.ndjson",
                    runner.os.O_WRONLY | runner.os.O_APPEND,
                )
                try:
                    runner.os.write(descriptor, b'{"torn":')
                    runner.os.fsync(descriptor)
                finally:
                    runner.os.close(descriptor)
                raise first_error

            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=tear_ledger_then_fail,
            ), mock.patch.object(
                runner,
                "_rename_directory_exclusive_at",
                side_effect=OSError("injected failure archive rename failure"),
            ):
                with self.assertRaises(RuntimeError) as first_raised:
                    first.run()
            self.assertIs(first_raised.exception, first_error)
            transaction = json.loads(
                (partial / runner._RUN_TRANSACTION_MARKER).read_bytes()
            )
            preserved_failure = json.loads((partial / "failure.json").read_bytes())
            self.assertEqual(preserved_failure["attempt_count"], 0)
            self.assertEqual((partial / "attempts.ndjson").read_bytes(), b'{"torn":')

            second = self._executor(output_root, run_id)
            second_error = RuntimeError("clean retry reached binding")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=second_error,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as reraised:
                    second.run()
            self.assertIs(reraised.exception.__cause__, second_error)
            recovered = output_root / (
                f"{run_id}.recovered-{transaction['transaction_id']}.failed"
            )
            self.assertEqual(
                json.loads((recovered / "failure.json").read_bytes()),
                preserved_failure,
            )
            self.assertEqual(
                (recovered / "attempts.ndjson").read_bytes(),
                b'{"torn":',
            )

    def test_existing_destination_is_untouched_and_creates_no_partial(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-existing-destination-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "existing"
            destination = output_root / run_id
            destination.mkdir()
            sentinel = destination / "user-owned.txt"
            sentinel.write_bytes(b"untouched")
            executor = self._executor(output_root, run_id)

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "overwrite is forbidden",
            ):
                executor.run()
            self.assertEqual(sentinel.read_bytes(), b"untouched")
            self.assertFalse((output_root / f".{run_id}.partial").exists())
            self.assertFalse((output_root / f"{run_id}.failed").exists())

    def test_disk_full_before_marker_publish_removes_empty_owned_partial(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-marker-disk-full-"
        ) as value:
            output_root = Path(value) / "runs"
            run_id = "marker-disk-full"
            executor = self._executor(output_root, run_id)
            disk_full = OSError("injected disk full while writing transaction marker")

            with mock.patch.object(runner.os, "write", side_effect=disk_full):
                with self.assertRaises(OSError) as raised:
                    executor.run()
            self.assertIs(raised.exception, disk_full)
            self.assertFalse((output_root / f".{run_id}.partial").exists())
            self.assertFalse((output_root / run_id).exists())
            self.assertFalse((output_root / f"{run_id}.failed").exists())
            self.assertEqual(list(output_root.iterdir()), [])

    def test_unknown_transaction_intent_is_preserved_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-unknown-intent-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "unknown-intent"
            intent = output_root / runner._run_transaction_intent_name(run_id)
            intent.symlink_to("foreign-unrecognized-target")
            executor = self._executor(output_root, run_id)

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "not a recognized owned intent",
            ):
                executor.run()
            self.assertTrue(intent.is_symlink())
            self.assertEqual(intent.readlink(), Path("foreign-unrecognized-target"))
            self.assertFalse((output_root / f".{run_id}.partial").exists())
            self.assertFalse((output_root / run_id).exists())
            self.assertFalse((output_root / f"{run_id}.failed").exists())

    def test_intent_recovers_every_pre_marker_publication_crash_window(
        self,
    ) -> None:
        cases = {
            "before_temp_create": "published_marker_from_durable_intent",
            "before_temp_write": "replaced_incomplete_marker_temporary",
            "after_temp_fsync": "completed_durable_marker_temporary",
            "after_marker_link": "removed_linked_marker_temporary",
        }
        for crash_window, expected_action in cases.items():
            with self.subTest(crash_window=crash_window), tempfile.TemporaryDirectory(
                prefix=f"mirmir-run-pre-marker-{crash_window}-"
            ) as value:
                output_root = Path(value) / "runs"
                output_root.mkdir()
                run_id = f"pre-marker-{crash_window}"
                transaction_id = str(uuid.uuid4())
                partial = output_root / f".{run_id}.partial"
                root_descriptor, _ = runner._open_directory_nofollow(output_root)
                try:
                    runner._create_run_transaction_intent_at(
                        root_descriptor,
                        run_id=run_id,
                        transaction_id=transaction_id,
                    )
                    runner.os.mkdir(
                        partial.name,
                        0o700,
                        dir_fd=root_descriptor,
                    )
                    runner.os.fsync(root_descriptor)
                finally:
                    runner.os.close(root_descriptor)

                marker = runner._run_transaction_marker(run_id, transaction_id)
                marker_payload = runner._json_artifact_bytes(marker)
                temporary_name = (
                    f".{runner._RUN_TRANSACTION_MARKER}.tmp-{uuid.uuid4().hex}"
                )
                if crash_window != "before_temp_create":
                    partial_descriptor, _ = runner._open_directory_nofollow(partial)
                    temporary_descriptor = runner.os.open(
                        temporary_name,
                        runner.os.O_WRONLY
                        | runner.os.O_CREAT
                        | runner.os.O_EXCL,
                        0o600,
                        dir_fd=partial_descriptor,
                    )
                    try:
                        if crash_window != "before_temp_write":
                            runner.os.write(temporary_descriptor, marker_payload)
                            runner.os.fsync(temporary_descriptor)
                    finally:
                        runner.os.close(temporary_descriptor)
                    if crash_window == "after_marker_link":
                        runner.os.link(
                            temporary_name,
                            runner._RUN_TRANSACTION_MARKER,
                            src_dir_fd=partial_descriptor,
                            dst_dir_fd=partial_descriptor,
                            follow_symlinks=False,
                        )
                    runner.os.fsync(partial_descriptor)
                    runner.os.close(partial_descriptor)

                intent_path = output_root / runner._run_transaction_intent_name(
                    run_id
                )
                self.assertTrue(intent_path.is_symlink())
                executor = self._executor(output_root, run_id)
                primary = RuntimeError("new run reached binding after intent recovery")
                with mock.patch.object(
                    runner,
                    "bind_preregistered_inputs",
                    side_effect=primary,
                ):
                    with self.assertRaises(
                        runner.CalibrationRunInterrupted
                    ) as raised:
                        executor.run()
                self.assertIs(raised.exception.__cause__, primary)

                recovered = output_root / (
                    f"{run_id}.recovered-{transaction_id}.failed"
                )
                history = self._recovery_history(recovered)
                self.assertEqual(len(history), 1)
                self.assertEqual(
                    history[0]["pre_marker_recovery_action"],
                    expected_action,
                )
                self.assertFalse(intent_path.is_symlink())
                self.assertEqual(
                    [
                        path.name
                        for path in recovered.iterdir()
                        if path.name.startswith(
                            f".{runner._RUN_TRANSACTION_MARKER}.tmp-"
                        )
                    ],
                    [],
                )

    def test_pre_marker_audit_survives_each_recovery_commit_boundary(self) -> None:
        boundaries = (
            "before_history",
            "history_before_final_link",
            "history_after_final_link",
            "before_intent_removal",
            "before_journal_removal",
            "before_archive_rename",
        )
        for boundary in boundaries:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory(
                prefix=f"mirmir-run-recovery-boundary-{boundary}-"
            ) as value:
                output_root = Path(value) / "runs"
                output_root.mkdir()
                run_id = f"recovery-boundary-{boundary}"
                transaction_id = str(uuid.uuid4())
                partial = output_root / f".{run_id}.partial"
                root_descriptor, _ = runner._open_directory_nofollow(output_root)
                try:
                    runner._create_run_transaction_intent_at(
                        root_descriptor,
                        run_id=run_id,
                        transaction_id=transaction_id,
                    )
                    runner.os.mkdir(
                        partial.name,
                        0o700,
                        dir_fd=root_descriptor,
                    )
                    runner.os.fsync(root_descriptor)
                finally:
                    runner.os.close(root_descriptor)

                if boundary == "before_history":
                    patcher = mock.patch.object(
                        runner,
                        "_write_recovery_history_at",
                        side_effect=SystemExit(81),
                    )
                elif boundary == "before_intent_removal":
                    patcher = mock.patch.object(
                        runner,
                        "_remove_run_transaction_intent_at",
                        side_effect=SystemExit(82),
                    )
                elif boundary == "before_journal_removal":
                    patcher = mock.patch.object(
                        runner,
                        "_remove_pre_marker_recovery_journal_at",
                        side_effect=SystemExit(83),
                    )
                elif boundary == "before_archive_rename":
                    patcher = mock.patch.object(
                        runner,
                        "_rename_directory_exclusive_at",
                        side_effect=OSError("injected recovery archive rename failure"),
                    )
                elif boundary == "history_before_final_link":
                    real_link = runner.os.link

                    def fail_history_link(
                        source_name: object,
                        destination_name: object,
                        *args: object,
                        **kwargs: object,
                    ) -> None:
                        if (
                            isinstance(destination_name, str)
                            and destination_name.endswith(".json")
                            and destination_name != runner._RUN_TRANSACTION_MARKER
                        ):
                            raise SystemExit(84)
                        real_link(source_name, destination_name, *args, **kwargs)

                    patcher = mock.patch.object(
                        runner.os,
                        "link",
                        side_effect=fail_history_link,
                    )
                else:
                    real_unlink = runner.os.unlink

                    def fail_history_cleanup(
                        name: object,
                        *args: object,
                        **kwargs: object,
                    ) -> None:
                        if isinstance(name, str) and name.endswith(
                            ".json.materialize"
                        ):
                            raise SystemExit(85)
                        real_unlink(name, *args, **kwargs)

                    patcher = mock.patch.object(
                        runner.os,
                        "unlink",
                        side_effect=fail_history_cleanup,
                    )

                first = self._executor(output_root, run_id)
                with patcher:
                    with self.assertRaises(BaseException):
                        first.run()
                self.assertTrue(partial.is_dir())

                second = self._executor(output_root, run_id)
                primary = RuntimeError("clean run reached binding after boundary retry")
                with mock.patch.object(
                    runner,
                    "bind_preregistered_inputs",
                    side_effect=primary,
                ):
                    with self.assertRaises(
                        runner.CalibrationRunInterrupted
                    ) as raised:
                        second.run()
                self.assertIs(raised.exception.__cause__, primary)

                recovered = output_root / (
                    f"{run_id}.recovered-{transaction_id}.failed"
                )
                history = self._recovery_history(recovered)
                self.assertEqual(len(history), 1)
                self.assertEqual(
                    history[0]["pre_marker_recovery_action"],
                    "published_marker_from_durable_intent",
                )
                self.assertFalse(
                    (
                        output_root
                        / runner._run_transaction_intent_name(run_id)
                    ).is_symlink()
                )
                self.assertFalse(
                    (recovered / runner._RUN_PREMARKER_RECOVERY_JOURNAL).is_symlink()
                )
                history_names = {
                    path.name
                    for path in (recovered / runner._RUN_RECOVERY_DIRECTORY).iterdir()
                }
                self.assertEqual(
                    history_names,
                    {runner._recovery_record_name(transaction_id)},
                )

    def test_recognized_stale_partial_is_archived_and_recovery_is_recorded(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-stale-run-recovery-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "stale-recovery"
            transaction_id = str(uuid.uuid4())
            partial = output_root / f".{run_id}.partial"
            partial.mkdir(mode=0o700)
            marker = runner._run_transaction_marker(run_id, transaction_id)
            runner._write_json_atomic_durable(
                partial / runner._RUN_TRANSACTION_MARKER,
                marker,
            )
            (partial / "interrupted-write.bin").write_bytes(b"partial")

            executor = self._executor(output_root, run_id)
            primary = RuntimeError("new clean attempt stops after recovery")
            with mock.patch.object(
                runner,
                "bind_preregistered_inputs",
                side_effect=primary,
            ):
                with self.assertRaises(runner.CalibrationRunInterrupted) as raised:
                    executor.run()
            self.assertIs(raised.exception.__cause__, primary)

            recovered = (
                output_root
                / f"{run_id}.recovered-{transaction_id}.failed"
            )
            failed = output_root / f"{run_id}.failed"
            self.assertTrue(recovered.is_dir())
            self.assertTrue(failed.is_dir())
            self.assertFalse(partial.exists())
            recovery_history = self._recovery_history(recovered)
            self.assertEqual(len(recovery_history), 1)
            recovery = recovery_history[0]
            self.assertEqual(recovery["run_id"], run_id)
            self.assertEqual(recovery["stale_transaction_id"], transaction_id)
            self.assertEqual(recovery["action"], "archived_recognized_stale_partial")
            self.assertEqual(
                recovery["record_sha256"],
                runner.canonical_sha256(
                    {
                        key: item
                        for key, item in recovery.items()
                        if key != "record_sha256"
                    }
                ),
            )
            self.assertEqual(self._recovery_history(failed), [recovery])
            self.assertEqual(
                (recovered / "interrupted-write.bin").read_bytes(),
                b"partial",
            )
            self.assertEqual((recovered / "attempts.ndjson").read_bytes(), b"")
            stale_failure = json.loads((recovered / "failure.json").read_bytes())
            self.assertEqual(
                stale_failure,
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": "p06_calibration_failure",
                    "run_id": run_id,
                    "error_type": "ProcessTerminatedBeforeFinalization",
                    "error": (
                        "recognized in-progress transaction remained after prior "
                        "process termination"
                    ),
                    "attempt_count": 0,
                    "attempt_ledger_sha256": hashlib.sha256(b"").hexdigest(),
                    "attempt_ledger_validation": "valid",
                    "transaction_id": transaction_id,
                    "transaction_state": "in_progress",
                    "holdout_accessed": False,
                    "release_locks_written": False,
                },
            )

    def test_stale_failure_rejects_missing_or_true_boundary_fields(self) -> None:
        mutations = (
            ("schema_version", "missing"),
            ("holdout_accessed", "missing"),
            ("holdout_accessed", True),
            ("release_locks_written", "missing"),
            ("release_locks_written", True),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory(
                prefix="mirmir-run-stale-failure-boundary-"
            ) as temporary:
                output_root = Path(temporary) / "runs"
                output_root.mkdir()
                run_id = f"stale-boundary-{field}-{value}"
                partial = output_root / f".{run_id}.partial"
                partial.mkdir(mode=0o700)
                runner._write_json_atomic_durable(
                    partial / runner._RUN_TRANSACTION_MARKER,
                    runner._run_transaction_marker(run_id, str(uuid.uuid4())),
                )
                attempts = b""
                (partial / "attempts.ndjson").write_bytes(attempts)
                failure = {
                    "schema_version": "1.0.0",
                    "artifact_kind": "p06_calibration_failure",
                    "run_id": run_id,
                    "error_type": "RuntimeError",
                    "error": "preserved",
                    "attempt_count": 0,
                    "attempt_ledger_sha256": hashlib.sha256(attempts).hexdigest(),
                    "holdout_accessed": False,
                    "release_locks_written": False,
                }
                if value == "missing":
                    failure.pop(field)
                else:
                    failure[field] = value
                runner._write_json_atomic_durable(
                    partial / "failure.json",
                    failure,
                )
                executor = self._executor(output_root, run_id)

                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "failure artifact does not bind",
                ):
                    executor.run()
                self.assertEqual(
                    json.loads((partial / "failure.json").read_bytes()),
                    failure,
                )

    def test_recovered_scan_rejects_missing_or_true_boundary_fields(self) -> None:
        mutations = (
            ("schema_version", "missing"),
            ("holdout_accessed", "missing"),
            ("holdout_accessed", True),
            ("release_locks_written", "missing"),
            ("release_locks_written", True),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory(
                prefix="mirmir-run-scanned-failure-boundary-"
            ) as temporary:
                output_root = Path(temporary) / "runs"
                output_root.mkdir()
                run_id = f"scan-boundary-{field}-{value}"
                transaction_id = str(uuid.uuid4())
                partial = output_root / f".{run_id}.partial"
                partial.mkdir(mode=0o700)
                runner._write_json_atomic_durable(
                    partial / runner._RUN_TRANSACTION_MARKER,
                    runner._run_transaction_marker(run_id, transaction_id),
                )
                root_descriptor, root_identity = runner._open_directory_nofollow(
                    output_root
                )
                try:
                    runner._recover_stale_run_transaction(
                        partial,
                        run_id=run_id,
                        output_root=output_root,
                        output_root_descriptor=root_descriptor,
                        output_root_identity=root_identity,
                    )
                finally:
                    runner.os.close(root_descriptor)
                recovered = output_root / (
                    f"{run_id}.recovered-{transaction_id}.failed"
                )
                failure_path = recovered / "failure.json"
                failure = json.loads(failure_path.read_bytes())
                if value == "missing":
                    failure.pop(field)
                else:
                    failure[field] = value
                failure_path.write_text(
                    json.dumps(failure, sort_keys=True, indent=2) + "\n",
                    encoding="utf-8",
                )
                executor = self._executor(output_root, run_id)

                with self.assertRaisesRegex(
                    runner.CalibrationError,
                    "archive binding differs",
                ):
                    executor.run()
                self.assertTrue(recovered.is_dir())
                self.assertFalse((output_root / f".{run_id}.partial").exists())

    def test_unknown_partial_is_preserved_and_rejected_without_clobber(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-unknown-run-partial-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            run_id = "unknown-partial"
            partial = output_root / f".{run_id}.partial"
            partial.mkdir()
            sentinel = partial / "user-owned.txt"
            sentinel.write_bytes(b"do-not-clobber")
            executor = self._executor(output_root, run_id)

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "not a recognized owned stale transaction",
            ):
                executor.run()
            self.assertEqual(sentinel.read_bytes(), b"do-not-clobber")
            self.assertFalse((output_root / run_id).exists())
            self.assertFalse((output_root / f"{run_id}.failed").exists())

    def test_symlinked_transaction_marker_is_preserved_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-symlinked-run-marker-"
        ) as value:
            base = Path(value)
            output_root = base / "runs"
            output_root.mkdir()
            run_id = "symlinked-marker"
            partial = output_root / f".{run_id}.partial"
            partial.mkdir()
            foreign_marker = base / "foreign-marker.json"
            runner._write_json_atomic_durable(
                foreign_marker,
                runner._run_transaction_marker(run_id, str(uuid.uuid4())),
            )
            marker = partial / runner._RUN_TRANSACTION_MARKER
            marker.symlink_to(foreign_marker)
            executor = self._executor(output_root, run_id)

            with self.assertRaisesRegex(
                runner.CalibrationError,
                "not a recognized owned stale transaction",
            ):
                executor.run()
            self.assertTrue(marker.is_symlink())
            self.assertTrue(foreign_marker.is_file())
            self.assertFalse((output_root / run_id).exists())
            self.assertFalse((output_root / f"{run_id}.failed").exists())

    def test_regular_read_rejects_directory_entry_swap_after_eof(self) -> None:
        for name in (runner._RUN_TRANSACTION_MARKER, "attempts.ndjson"):
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix="mirmir-run-read-entry-swap-"
            ) as value:
                directory = Path(value)
                path = directory / name
                path.write_bytes(b"original")
                moved = directory / f"{name}.opened-inode"
                replacement = directory / f"{name}.replacement"
                replacement.write_bytes(b"replacement")
                descriptor, _ = runner._open_directory_nofollow(directory)
                real_read = runner.os.read
                swapped = False

                def swap_after_eof(
                    file_descriptor: int,
                    size: int,
                ) -> bytes:
                    nonlocal swapped
                    payload = real_read(file_descriptor, size)
                    if payload == b"" and not swapped:
                        path.rename(moved)
                        replacement.rename(path)
                        swapped = True
                    return payload

                try:
                    with mock.patch.object(
                        runner.os,
                        "read",
                        side_effect=swap_after_eof,
                    ):
                        with self.assertRaisesRegex(
                            runner.CalibrationError,
                            "entry changed while reading",
                        ):
                            runner._read_regular_at(
                                descriptor,
                                name,
                                display_path=path,
                            )
                finally:
                    runner.os.close(descriptor)
                self.assertEqual(moved.read_bytes(), b"original")
                self.assertEqual(path.read_bytes(), b"replacement")

    def test_critical_child_swap_before_archive_is_quarantined(self) -> None:
        for child_name in (runner._RUN_TRANSACTION_MARKER, "attempts.ndjson"):
            with self.subTest(child=child_name), tempfile.TemporaryDirectory(
                prefix="mirmir-run-critical-child-swap-"
            ) as value:
                output_root = Path(value) / "runs"
                output_root.mkdir()
                run_id = f"critical-child-{child_name.strip('.').replace('.', '-')}"
                transaction_id = str(uuid.uuid4())
                partial = output_root / f".{run_id}.partial"
                partial.mkdir(mode=0o700)
                runner._write_json_atomic_durable(
                    partial / runner._RUN_TRANSACTION_MARKER,
                    runner._run_transaction_marker(run_id, transaction_id),
                )
                (partial / "attempts.ndjson").write_bytes(b"")
                real_publish = runner._rename_directory_exclusive_at

                def swap_child_then_publish(
                    source_name: str,
                    destination_name: str,
                    *,
                    directory_descriptor: int,
                ) -> None:
                    child = output_root / source_name / child_name
                    child.rename(output_root / source_name / f"{child_name}.validated")
                    child.write_bytes(b"replacement-after-validation")
                    real_publish(
                        source_name,
                        destination_name,
                        directory_descriptor=directory_descriptor,
                    )

                executor = self._executor(output_root, run_id)
                with mock.patch.object(
                    runner,
                    "_rename_directory_exclusive_at",
                    side_effect=swap_child_then_publish,
                ):
                    with self.assertRaisesRegex(
                        runner.CalibrationError,
                        "run tree binding differs",
                    ):
                        executor.run()

                recovered_name = (
                    f"{run_id}.recovered-{transaction_id}.failed"
                )
                recovered = output_root / recovered_name
                self.assertFalse(runner.os.path.lexists(recovered))
                quarantines = list(
                    output_root.glob(
                        f".{recovered_name}.identity-mismatch-*.quarantine"
                    )
                )
                self.assertEqual(len(quarantines), 1)
                quarantine = quarantines[0]
                self.assertEqual(
                    (quarantine / child_name).read_bytes(),
                    b"replacement-after-validation",
                )
                self.assertTrue(
                    (quarantine / f"{child_name}.validated").is_file()
                )
                self.assertFalse((output_root / f"{run_id}.failed").exists())

    def test_finalize_is_tree_then_rename_then_parent_durable(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-finalize-order-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            source = output_root / ".ordered.partial"
            source.mkdir()
            (source / "artifact.json").write_bytes(b"{}")
            destination = output_root / "ordered"
            root_descriptor, root_identity = runner._open_directory_nofollow(
                output_root
            )
            source_descriptor, source_identity = runner._open_directory_nofollow(
                source
            )
            events: list[str] = []
            real_rename = runner._rename_directory_exclusive_at

            def rename(*args: object, **kwargs: object) -> None:
                events.append("rename")
                real_rename(*args, **kwargs)

            try:
                with mock.patch.object(
                    runner,
                    "_fsync_run_tree_at",
                    side_effect=lambda _descriptor, **_kwargs: events.append("tree"),
                ), mock.patch.object(
                    runner,
                    "_rename_directory_exclusive_at",
                    side_effect=rename,
                ), mock.patch.object(
                    runner.os,
                    "fsync",
                    side_effect=lambda _descriptor: events.append("parent"),
                ):
                    runner._finalize_run_directory(
                        source,
                        destination,
                        output_root=output_root,
                        output_root_descriptor=root_descriptor,
                        output_root_identity=root_identity,
                        source_descriptor=source_descriptor,
                        source_identity=source_identity,
                    )
            finally:
                runner.os.close(source_descriptor)
                runner.os.close(root_descriptor)
            self.assertEqual(events, ["tree", "rename", "parent"])
            self.assertTrue(destination.is_dir())

    def test_exclusive_publish_does_not_replace_destination_inserted_by_race(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-exclusive-destination-race-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            source = output_root / ".exclusive.partial"
            source.mkdir()
            owned = source / "owned.txt"
            owned.write_bytes(b"owned")
            destination = output_root / "exclusive"
            root_descriptor, root_identity = runner._open_directory_nofollow(
                output_root
            )
            source_descriptor, source_identity = runner._open_directory_nofollow(
                source
            )
            real_publish = runner._rename_directory_exclusive_at

            def insert_destination_then_publish(
                source_name: str,
                destination_name: str,
                *,
                directory_descriptor: int,
            ) -> None:
                foreign = output_root / destination_name
                foreign.mkdir()
                (foreign / "foreign.txt").write_bytes(b"foreign")
                real_publish(
                    source_name,
                    destination_name,
                    directory_descriptor=directory_descriptor,
                )

            try:
                with mock.patch.object(
                    runner,
                    "_rename_directory_exclusive_at",
                    side_effect=insert_destination_then_publish,
                ):
                    with self.assertRaisesRegex(
                        runner.CalibrationError,
                        "appeared during exclusive publication",
                    ):
                        runner._finalize_run_directory(
                            source,
                            destination,
                            output_root=output_root,
                            output_root_descriptor=root_descriptor,
                            output_root_identity=root_identity,
                            source_descriptor=source_descriptor,
                            source_identity=source_identity,
                        )
            finally:
                runner.os.close(source_descriptor)
                runner.os.close(root_descriptor)
            self.assertEqual(owned.read_bytes(), b"owned")
            self.assertEqual(
                (destination / "foreign.txt").read_bytes(),
                b"foreign",
            )
            self.assertEqual(
                list(output_root.glob(".exclusive.identity-mismatch-*.quarantine")),
                [],
            )

    def test_child_swap_after_fsync_cannot_become_the_sealed_tree(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="mirmir-run-post-fsync-child-swap-"
        ) as value:
            output_root = Path(value) / "runs"
            output_root.mkdir()
            source = output_root / ".post-fsync.partial"
            source.mkdir()
            artifact = source / "artifact.json"
            artifact.write_bytes(b"original")
            destination = output_root / "post-fsync"
            root_descriptor, root_identity = runner._open_directory_nofollow(
                output_root
            )
            source_descriptor, source_identity = runner._open_directory_nofollow(
                source
            )
            real_fsync_tree = runner._fsync_run_tree_at

            def fsync_then_swap(*args: object, **kwargs: object) -> None:
                real_fsync_tree(*args, **kwargs)
                artifact.rename(source / "artifact.validated.json")
                artifact.write_bytes(b"replacement-not-fsynced")

            try:
                with mock.patch.object(
                    runner,
                    "_fsync_run_tree_at",
                    side_effect=fsync_then_swap,
                ):
                    with self.assertRaisesRegex(
                        runner.CalibrationError,
                        "changed across its durability commit",
                    ):
                        runner._finalize_run_directory(
                            source,
                            destination,
                            output_root=output_root,
                            output_root_descriptor=root_descriptor,
                            output_root_identity=root_identity,
                            source_descriptor=source_descriptor,
                            source_identity=source_identity,
                        )
            finally:
                runner.os.close(source_descriptor)
                runner.os.close(root_descriptor)
            self.assertFalse(destination.exists())
            self.assertEqual(artifact.read_bytes(), b"replacement-not-fsynced")
            self.assertEqual(
                (source / "artifact.validated.json").read_bytes(),
                b"original",
            )

    def test_post_publish_foreign_types_are_quarantined_from_canonical_name(
        self,
    ) -> None:
        for replacement_kind in ("directory", "symlink", "regular"):
            with self.subTest(kind=replacement_kind), tempfile.TemporaryDirectory(
                prefix=f"mirmir-run-post-publish-{replacement_kind}-"
            ) as value:
                output_root = Path(value) / "runs"
                output_root.mkdir()
                source = output_root / ".postcheck.partial"
                source.mkdir()
                (source / "owned.txt").write_bytes(b"owned")
                destination = output_root / "postcheck"
                owned_moved = output_root / ".postcheck.owned-moved"
                foreign_target = output_root / "foreign-target"
                foreign_target.mkdir()
                (foreign_target / "target.txt").write_bytes(b"target")
                root_descriptor, root_identity = runner._open_directory_nofollow(
                    output_root
                )
                source_descriptor, source_identity = (
                    runner._open_directory_nofollow(source)
                )
                real_publish = runner._rename_directory_exclusive_at

                def replace_after_publish(
                    source_name: str,
                    destination_name: str,
                    *,
                    directory_descriptor: int,
                ) -> None:
                    real_publish(
                        source_name,
                        destination_name,
                        directory_descriptor=directory_descriptor,
                    )
                    published = output_root / destination_name
                    published.rename(owned_moved)
                    if replacement_kind == "directory":
                        published.mkdir()
                        (published / "foreign.txt").write_bytes(b"foreign")
                    elif replacement_kind == "symlink":
                        published.symlink_to(foreign_target, target_is_directory=True)
                    else:
                        published.write_bytes(b"foreign")

                try:
                    with mock.patch.object(
                        runner,
                        "_rename_directory_exclusive_at",
                        side_effect=replace_after_publish,
                    ):
                        with self.assertRaisesRegex(
                            runner.CalibrationError,
                            "identity differs; invalid entry quarantined",
                        ):
                            runner._finalize_run_directory(
                                source,
                                destination,
                                output_root=output_root,
                                output_root_descriptor=root_descriptor,
                                output_root_identity=root_identity,
                                source_descriptor=source_descriptor,
                                source_identity=source_identity,
                            )
                finally:
                    runner.os.close(source_descriptor)
                    runner.os.close(root_descriptor)

                self.assertFalse(runner.os.path.lexists(destination))
                self.assertEqual(
                    (owned_moved / "owned.txt").read_bytes(),
                    b"owned",
                )
                quarantines = list(
                    output_root.glob(
                        ".postcheck.identity-mismatch-*.quarantine"
                    )
                )
                self.assertEqual(len(quarantines), 1)
                quarantine = quarantines[0]
                if replacement_kind == "directory":
                    self.assertEqual(
                        (quarantine / "foreign.txt").read_bytes(),
                        b"foreign",
                    )
                elif replacement_kind == "symlink":
                    self.assertTrue(quarantine.is_symlink())
                    self.assertEqual(quarantine.readlink(), foreign_target)
                    self.assertEqual(
                        (foreign_target / "target.txt").read_bytes(),
                        b"target",
                    )
                else:
                    self.assertEqual(quarantine.read_bytes(), b"foreign")

    def test_pinned_run_directories_reject_symlink_and_real_replacement(self) -> None:
        for target, replacement_kind in (
            ("partial", "symlink"),
            ("partial", "directory"),
            ("output", "symlink"),
            ("output", "directory"),
        ):
            with self.subTest(target=target, replacement=replacement_kind), \
                    tempfile.TemporaryDirectory(
                        prefix="mirmir-run-directory-substitution-"
                    ) as value:
                base = Path(value)
                output_root = base / "runs"
                output_root.mkdir()
                partial = output_root / ".substitution.partial"
                partial.mkdir()
                (partial / "owned.txt").write_bytes(b"owned")
                destination = output_root / "substitution"
                foreign = base / "foreign"
                foreign.mkdir()
                sentinel = foreign / "sentinel.txt"
                sentinel.write_bytes(b"foreign")
                root_descriptor, root_identity = runner._open_directory_nofollow(
                    output_root
                )
                partial_descriptor, partial_identity = (
                    runner._open_directory_nofollow(partial)
                )
                if target == "partial":
                    moved = output_root / ".substitution.original"
                    partial.rename(moved)
                    if replacement_kind == "symlink":
                        partial.symlink_to(foreign, target_is_directory=True)
                    else:
                        partial.mkdir()
                else:
                    moved = base / "runs-original"
                    output_root.rename(moved)
                    if replacement_kind == "symlink":
                        output_root.symlink_to(foreign, target_is_directory=True)
                    else:
                        output_root.mkdir()
                try:
                    with self.assertRaisesRegex(
                        runner.CalibrationError,
                        "replaced|symbolic",
                    ):
                        runner._finalize_run_directory(
                            partial,
                            destination,
                            output_root=output_root,
                            output_root_descriptor=root_descriptor,
                            output_root_identity=root_identity,
                            source_descriptor=partial_descriptor,
                            source_identity=partial_identity,
                        )
                finally:
                    runner.os.close(partial_descriptor)
                    runner.os.close(root_descriptor)
                self.assertEqual(sentinel.read_bytes(), b"foreign")
                self.assertFalse((foreign / "substitution").exists())


if __name__ == "__main__":
    unittest.main()
