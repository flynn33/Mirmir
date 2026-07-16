from __future__ import annotations

from dataclasses import FrozenInstanceError
import hashlib
import json
import os
from pathlib import Path
import stat
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from validation.calibration_v2 import authenticated_closure_snapshot_v2 as closure
from validation.calibration_v2.authenticated_closure_snapshot_v2 import (
    AuthenticatedClosureCaptureV2,
    AuthenticatedClosureSnapshotV2Error,
    CLOSURE_HASH_DOMAIN_V2,
    ClosureFileBindingV2,
)


def _write(root: Path, path: str, payload: bytes) -> ClosureFileBindingV2:
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    return ClosureFileBindingV2(
        path=path,
        sha256=hashlib.sha256(payload).hexdigest(),
        size_bytes=len(payload),
    )


def _manual_closure_sha256(bindings: tuple[ClosureFileBindingV2, ...]) -> str:
    identity = {
        "hash_domain": CLOSURE_HASH_DOMAIN_V2,
        "files": [
            {
                "path": binding.path,
                "sha256": binding.sha256,
                "size_bytes": binding.size_bytes,
            }
            for binding in sorted(bindings, key=lambda item: item.path)
        ],
    }
    canonical = json.dumps(
        identity,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(
        CLOSURE_HASH_DOMAIN_V2.encode("ascii") + b"\x00" + canonical
    ).hexdigest()


class AuthenticatedClosureSnapshotV2Tests(unittest.TestCase):
    def test_binding_validation_is_exact_and_empty_files_are_supported(self) -> None:
        digest = hashlib.sha256(b"").hexdigest()
        self.assertEqual(
            ClosureFileBindingV2("empty.bin", digest, 0).size_bytes,
            0,
        )
        invalid = (
            ("", digest, 0),
            ("/absolute", digest, 0),
            ("parent/../escape", digest, 0),
            ("parent//file", digest, 0),
            ("parent\\file", digest, 0),
            ("space name", digest, 0),
            ("file", "0" * 64, 0),
            ("file", digest.upper(), 0),
            ("file", digest, -1),
            ("file", digest, True),
        )
        for path, sha256, size_bytes in invalid:
            with self.subTest(path=path, sha256=sha256, size=size_bytes):
                with self.assertRaises(AuthenticatedClosureSnapshotV2Error):
                    ClosureFileBindingV2(path, sha256, size_bytes)

    def test_snapshot_lookup_order_digest_and_post_exit_scope_are_exact(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_payload = b"first\n"
            second_payload = b"second\n"
            first = _write(root, "a/first.json", first_payload)
            second = _write(root, "z-second.json", second_payload)
            capture = AuthenticatedClosureCaptureV2(root)
            with capture:
                self.assertEqual(
                    capture.capture(second, label="second evidence"),
                    second_payload,
                )
                self.assertEqual(
                    capture.capture(first, label="first evidence"),
                    first_payload,
                )
                self.assertEqual(
                    capture.capture(first, label="first evidence duplicate"),
                    first_payload,
                )
                snapshot = capture.snapshot()

            self.assertTrue(capture.closed)
            self.assertEqual(snapshot.bindings, (first, second))
            self.assertEqual(snapshot.payload(first), first_payload)
            self.assertEqual(snapshot.payload(second), second_payload)
            self.assertEqual(len(snapshot), 2)
            self.assertEqual(
                snapshot.closure_sha256,
                _manual_closure_sha256((second, first)),
            )
            with self.assertRaises(FrozenInstanceError):
                snapshot._closure_sha256 = "0" * 64

            wrong = ClosureFileBindingV2(
                first.path,
                hashlib.sha256(b"wrong\n").hexdigest(),
                len(b"wrong\n"),
            )
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "absent or differs",
            ):
                snapshot.payload(wrong)

            (root / first.path).write_bytes(b"other\n")
            self.assertEqual(snapshot.payload(first), first_payload)
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "bytes differ from the closure binding",
            ):
                with AuthenticatedClosureCaptureV2(root) as fresh:
                    fresh.capture(first, label="fresh first evidence")

    def test_conflicting_path_binding_poisoning_is_fail_closed(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            binding = _write(root, "same.json", b"same\n")
            conflicting = ClosureFileBindingV2(
                binding.path,
                hashlib.sha256(b"else\n").hexdigest(),
                len(b"else\n"),
            )
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "conflicting bindings",
            ):
                with AuthenticatedClosureCaptureV2(root) as capture:
                    capture.capture(binding, label="original binding")
                    capture.capture(conflicting, label="conflicting binding")

    def test_empty_or_unsealed_capture_cannot_succeed(self) -> None:
        with TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "without sealing",
            ):
                with AuthenticatedClosureCaptureV2(Path(temporary)):
                    pass

        with TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "empty binding set",
            ):
                with AuthenticatedClosureCaptureV2(Path(temporary)) as capture:
                    capture.snapshot()

        with TemporaryDirectory() as temporary:
            capture = AuthenticatedClosureCaptureV2(Path(temporary))
            with capture:
                self.assertEqual(capture.captured_file_count, 0)
                capture.cancel_empty()
            self.assertTrue(capture.closed)
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "not active",
            ):
                _ = capture.captured_file_count

    def test_capture_fails_closed_when_kqueue_is_unavailable(self) -> None:
        with TemporaryDirectory() as temporary:
            with patch.object(closure.select, "kqueue", None):
                with self.assertRaisesRegex(
                    AuthenticatedClosureSnapshotV2Error,
                    "requires macOS kqueue vnode support",
                ):
                    with AuthenticatedClosureCaptureV2(Path(temporary)):
                        pass

    def test_expected_root_identity_is_exact_and_enforced(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(os.path.realpath(temporary))
            status = root.stat()
            expected = (status.st_dev, status.st_ino)
            binding = _write(root, "root-bound.bin", b"root-bound\n")
            with AuthenticatedClosureCaptureV2(
                root,
                expected_root_identity=expected,
            ) as capture:
                self.assertEqual(capture.root_identity, expected)
                capture.capture(binding, label="root-bound evidence")
                capture.snapshot()
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "identity is unavailable",
            ):
                _ = capture.root_identity

            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "differs from its pinned identity",
            ):
                with AuthenticatedClosureCaptureV2(
                    root,
                    expected_root_identity=(expected[0], expected[1] + 1),
                ):
                    pass

            for invalid in ((expected[0],), [*expected], (True, expected[1])):
                with self.subTest(invalid=invalid):
                    with self.assertRaisesRegex(
                        AuthenticatedClosureSnapshotV2Error,
                        "expected closure artifact-root identity is invalid",
                    ):
                        AuthenticatedClosureCaptureV2(
                            root,
                            expected_root_identity=invalid,
                        )

    def _assert_late_mutation_rejected(self, mutation: str) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_payload = b"first\n"
            first = _write(root, "a-first.bin", first_payload)
            second = _write(root, "z-second.bin", b"second\n")
            first_path = root / first.path
            original_status = first_path.stat()
            displaced = root / "displaced-first.bin"
            alias = root / "first-alias.bin"
            callback_invoked = False
            descriptors: tuple[int, ...] = ()
            queue_descriptor = -1

            def mutate_earlier_file(path: str) -> None:
                nonlocal callback_invoked
                if path != second.path or callback_invoked:
                    return
                callback_invoked = True
                if mutation == "same-size-write-restored-mtime":
                    first_path.write_bytes(b"other\n")
                    os.utime(
                        first_path,
                        ns=(original_status.st_atime_ns, original_status.st_mtime_ns),
                    )
                elif mutation == "delete":
                    first_path.unlink()
                elif mutation == "rename-recreate":
                    first_path.rename(displaced)
                    first_path.write_bytes(first_payload)
                elif mutation == "attribute":
                    first_path.chmod(0o400)
                elif mutation == "hard-link":
                    os.link(first_path, alias)
                else:
                    raise AssertionError(f"unhandled mutation {mutation}")

            capture = AuthenticatedClosureCaptureV2(root)
            with patch.object(
                capture,
                "_before_final_file_validation",
                side_effect=mutate_earlier_file,
            ):
                with self.assertRaisesRegex(
                    AuthenticatedClosureSnapshotV2Error,
                    (
                        "filesystem event"
                        if mutation == "same-size-write-restored-mtime"
                        else "changed during verification|filesystem event"
                    ),
                ):
                    with capture:
                        capture.capture(first, label="first manifest row")
                        capture.capture(second, label="second manifest row")
                        capture.snapshot()
                        descriptors = tuple(capture._owned_descriptors)
                        self.assertIsNotNone(capture._kqueue)
                        queue_descriptor = capture._kqueue.fileno()
            self.assertTrue(callback_invoked)
            self.assertTrue(capture.closed)
            for descriptor in (*descriptors, queue_descriptor):
                with self.assertRaises(OSError):
                    os.fstat(descriptor)

    def test_late_file_events_cannot_escape_an_earlier_final_check(self) -> None:
        for mutation in (
            "same-size-write-restored-mtime",
            "delete",
            "rename-recreate",
            "attribute",
            "hard-link",
        ):
            with self.subTest(mutation=mutation):
                self._assert_late_mutation_rejected(mutation)

    def test_early_dependency_mutation_is_detected_after_later_capture(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            attempt = _write(root, "attempts-v2.ndjson", b"original-attempt\n")
            evaluation = _write(
                root,
                "evaluations/evaluation.json",
                b"evaluation\n",
            )
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "changed during final validation|filesystem event",
            ):
                with AuthenticatedClosureCaptureV2(root) as capture:
                    capture.capture(attempt, label="attempt ledger")
                    (root / attempt.path).write_bytes(b"other\n")
                    capture.capture(evaluation, label="development evaluation")
                    capture.snapshot()

    def test_parent_directory_swap_during_later_validation_is_detected(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            first_payload = b"first\n"
            first = _write(root, "a-parent/first.bin", first_payload)
            second = _write(root, "z-parent/second.bin", b"second\n")
            original_parent = root / "a-parent"
            displaced_parent = root / "a-parent-displaced"
            callback_invoked = False

            def swap_earlier_parent(path: str) -> None:
                nonlocal callback_invoked
                if path != second.path or callback_invoked:
                    return
                callback_invoked = True
                original_parent.rename(displaced_parent)
                original_parent.mkdir()
                (original_parent / "first.bin").write_bytes(first_payload)

            capture = AuthenticatedClosureCaptureV2(root)
            with patch.object(
                capture,
                "_before_final_file_validation",
                side_effect=swap_earlier_parent,
            ):
                with self.assertRaisesRegex(
                    AuthenticatedClosureSnapshotV2Error,
                    "changed during verification|filesystem event",
                ):
                    with capture:
                        capture.capture(first, label="first nested dependency")
                        capture.capture(second, label="second nested dependency")
                        capture.snapshot()
            self.assertTrue(callback_invoked)
            self.assertTrue(capture.closed)

    def test_symlink_roots_files_and_directory_components_are_rejected(self) -> None:
        with TemporaryDirectory() as temporary:
            container = Path(temporary)
            real_root = container / "real-root"
            real_root.mkdir()
            linked_root = container / "linked-root"
            linked_root.symlink_to(real_root, target_is_directory=True)
            with self.assertRaisesRegex(
                AuthenticatedClosureSnapshotV2Error,
                "root itself must not be a symlink",
            ):
                AuthenticatedClosureCaptureV2(linked_root)

            target_payload = b"target\n"
            target = _write(real_root, "target.bin", target_payload)
            linked_file = real_root / "linked.bin"
            linked_file.symlink_to(real_root / target.path)
            linked_binding = ClosureFileBindingV2(
                "linked.bin",
                target.sha256,
                target.size_bytes,
            )
            with self.assertRaises(AuthenticatedClosureSnapshotV2Error):
                with AuthenticatedClosureCaptureV2(real_root) as capture:
                    capture.capture(linked_binding, label="linked file")

            real_parent = real_root / "real-parent"
            real_parent.mkdir()
            (real_parent / "nested.bin").write_bytes(target_payload)
            (real_root / "linked-parent").symlink_to(
                real_parent,
                target_is_directory=True,
            )
            nested_binding = ClosureFileBindingV2(
                "linked-parent/nested.bin",
                target.sha256,
                target.size_bytes,
            )
            with self.assertRaises(AuthenticatedClosureSnapshotV2Error):
                with AuthenticatedClosureCaptureV2(real_root) as capture:
                    capture.capture(nested_binding, label="linked parent")

    def test_all_descriptors_close_after_success_and_body_failure(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            binding = _write(root, "nested/evidence.bin", b"evidence\n")
            capture = AuthenticatedClosureCaptureV2(root)
            with capture:
                capture.capture(binding, label="cleanup evidence")
                capture.snapshot()
                descriptors = tuple(capture._owned_descriptors)
                self.assertIsNotNone(capture._kqueue)
                queue_descriptor = capture._kqueue.fileno()
            self.assertTrue(capture.closed)
            for descriptor in (*descriptors, queue_descriptor):
                with self.subTest(success_descriptor=descriptor):
                    with self.assertRaises(OSError):
                        os.fstat(descriptor)

        class BodyFailure(RuntimeError):
            pass

        with TemporaryDirectory() as temporary:
            capture = AuthenticatedClosureCaptureV2(Path(temporary))
            descriptors = ()
            queue_descriptor = -1
            with self.assertRaises(BodyFailure):
                with capture:
                    descriptors = tuple(capture._owned_descriptors)
                    self.assertIsNotNone(capture._kqueue)
                    queue_descriptor = capture._kqueue.fileno()
                    raise BodyFailure("intentional body failure")
            self.assertTrue(capture.closed)
            for descriptor in (*descriptors, queue_descriptor):
                with self.subTest(failure_descriptor=descriptor):
                    with self.assertRaises(OSError):
                        os.fstat(descriptor)

    def test_file_mode_remains_regular_in_a_successful_capture(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            binding = _write(root, "regular.bin", b"regular\n")
            with AuthenticatedClosureCaptureV2(root) as capture:
                capture.capture(binding, label="regular evidence")
                retained = capture._files[binding.path]
                self.assertTrue(stat.S_ISREG(retained.identity.mode))
                capture.snapshot()


if __name__ == "__main__":
    unittest.main()
