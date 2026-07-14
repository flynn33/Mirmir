"""Adversarial tests for atomic immutable evidence-wrapper publication."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

from validation.calibration_v2.tools import finalize_evidence_wrapper as wrapper
from validation.calibration_v2.tools.finalize_evidence_wrapper import (
    EvidenceWrapperError,
    finalize_evidence_wrapper,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_json_bytes


@unittest.skipUnless(
    hasattr(stat, "UF_IMMUTABLE"),
    "evidence-wrapper sealing requires macOS user-immutable flags",
)
class EvidenceWrapperFinalizerTests(unittest.TestCase):
    """Exercise successful publication and hostile path/state transitions."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="mirmir-evidence-wrapper-"
        )
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.project = self.root / "project"
        self.project.mkdir()
        self._git("init", "-q")
        self._git("config", "user.name", "Mirmir Test")
        self._git("config", "user.email", "mirmir-test@example.invalid")
        self.readme = self.project / "README.md"
        self.readme.write_bytes(b"evidence wrapper fixture\n")
        self._git("add", "README.md")
        self._git("commit", "-q", "-m", "Create fixture")
        self.parent = self.project / "Artifacts" / "ASH"
        self.parent.mkdir(parents=True)
        self.partial, self.final = self._new_wrapper("run")

    def tearDown(self) -> None:
        self._thaw_tree(self.project)
        self.temporary.cleanup()

    def _git(self, *arguments: str) -> bytes:
        result = subprocess.run(
            ["git", "-C", str(self.project), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            self.fail(result.stderr.decode("utf-8", errors="replace"))
        return result.stdout

    def _new_wrapper(self, name: str) -> tuple[Path, Path]:
        final = self.parent / name
        partial = self.parent / f".{name}.partial"
        partial.mkdir()
        return partial, final

    def _arguments(
        self,
        partial: Path | None = None,
        final: Path | None = None,
        **overrides: object,
    ) -> dict[str, object]:
        values: dict[str, object] = {
            "partial": partial or self.partial,
            "final": final or self.final,
            "gate_ids": ["G06", "P06"],
            "producer": "wrapper-test",
            "command": "python3 -m unittest wrapper-test",
            "platform": "macOS arm64 test platform",
            "machine": "test-machine",
            "project_root": self.project,
        }
        values.update(overrides)
        return values

    def _run_crashing_finalizer(
        self,
        *,
        partial: Path,
        final: Path,
        boundary: str,
    ) -> subprocess.CompletedProcess[bytes]:
        script = textwrap.dedent(
            f"""
            import os
            from pathlib import Path
            from unittest import mock
            from validation.calibration_v2.tools import finalize_evidence_wrapper as wrapper

            partial = Path({str(partial)!r})
            final = Path({str(final)!r})
            project = Path({str(self.project)!r})
            boundary = {boundary!r}
            if boundary == "post-rename":
                original = wrapper._seal_descriptor
                def injected(descriptor, *, label):
                    if label == "published artifact root":
                        os._exit(73)
                    return original(descriptor, label=label)
                patcher = mock.patch.object(
                    wrapper,
                    "_seal_descriptor",
                    side_effect=injected,
                )
            elif boundary in {{"marker-staged", "completion-staged"}}:
                original = wrapper._move_owned_entry
                prefix = (
                    ".evidence-wrapper-marker-"
                    if boundary == "marker-staged"
                    else ".evidence-wrapper-completion-"
                )
                exit_code = 81 if boundary == "marker-staged" else 82
                def injected(*args, **kwargs):
                    source = kwargs.get("preferred_source_name")
                    if (
                        isinstance(source, str)
                        and source.startswith(prefix)
                        and source.endswith(".tmp")
                    ):
                        os._exit(exit_code)
                    return original(*args, **kwargs)
                patcher = mock.patch.object(
                    wrapper,
                    "_move_owned_entry",
                    side_effect=injected,
                )
            elif boundary in {"marker-unsealed", "completion-unsealed"}:
                original = wrapper._seal_descriptor
                needle = (
                    "evidence-wrapper-transaction.json"
                    if boundary == "marker-unsealed"
                    else "evidence-wrapper-complete.json"
                )
                exit_code = 79 if boundary == "marker-unsealed" else 80
                def injected(descriptor, *, label):
                    if label.endswith(needle):
                        os._exit(exit_code)
                    return original(descriptor, label=label)
                patcher = mock.patch.object(
                    wrapper,
                    "_seal_descriptor",
                    side_effect=injected,
                )
            elif boundary in {{"active-cleanup", "completion-cleanup"}}:
                original = wrapper.os.unlink
                needle = (
                    "evidence-wrapper-transaction.json.cleanup-"
                    if boundary == "active-cleanup"
                    else "evidence-wrapper-complete.json.cleanup-"
                )
                exit_code = 77 if boundary == "active-cleanup" else 78
                def injected(path, *args, **kwargs):
                    if needle in os.fspath(path):
                        os._exit(exit_code)
                    return original(path, *args, **kwargs)
                patcher = mock.patch.object(
                    wrapper.os,
                    "unlink",
                    side_effect=injected,
                )
            else:
                original = wrapper._remove_owned_record
                calls = 0
                def injected(*args, **kwargs):
                    global calls
                    calls += 1
                    if calls == 1 and boundary == "both-records":
                        os._exit(74)
                    result = original(*args, **kwargs)
                    if calls == 1 and boundary == "completion-only":
                        os._exit(75)
                    if calls == 2 and boundary == "no-records":
                        os._exit(76)
                    return result
                patcher = mock.patch.object(
                    wrapper,
                    "_remove_owned_record",
                    side_effect=injected,
                )
            with patcher:
                wrapper.finalize_evidence_wrapper(
                    partial=partial,
                    final=final,
                    gate_ids=["G06", "P06"],
                    producer="wrapper-test",
                    command="crash-boundary-test",
                    platform="macOS arm64 test platform",
                    machine="test-machine",
                    project_root=project,
                )
            """
        )
        return subprocess.run(
            [sys.executable, "-c", script],
            cwd=wrapper.REPOSITORY_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    @staticmethod
    def _thaw_tree(root: Path) -> None:
        if not root.exists() or root.is_symlink():
            return
        for directory, directory_names, file_names in os.walk(
            root,
            topdown=True,
            followlinks=False,
        ):
            directory_path = Path(directory)
            try:
                metadata = os.stat(directory_path, follow_symlinks=False)
                os.chflags(
                    directory_path,
                    metadata.st_flags & ~stat.UF_IMMUTABLE,
                    follow_symlinks=False,
                )
                os.chmod(
                    directory_path,
                    stat.S_IMODE(metadata.st_mode) | stat.S_IWUSR | stat.S_IXUSR,
                )
            except FileNotFoundError:
                continue
            for name in file_names:
                path = directory_path / name
                if path.is_symlink():
                    continue
                try:
                    metadata = os.stat(path, follow_symlinks=False)
                    os.chflags(
                        path,
                        metadata.st_flags & ~stat.UF_IMMUTABLE,
                        follow_symlinks=False,
                    )
                    if stat.S_ISREG(metadata.st_mode):
                        os.chmod(path, stat.S_IMODE(metadata.st_mode) | stat.S_IWUSR)
                except FileNotFoundError:
                    continue
            directory_names.sort()

    @staticmethod
    def _write_at(
        directory_descriptor: int,
        name: str,
        payload: bytes,
        *,
        truncate: bool = False,
    ) -> None:
        flags = os.O_WRONLY | os.O_CREAT
        flags |= os.O_TRUNC if truncate else os.O_EXCL
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_descriptor)
        try:
            view = memoryview(payload)
            written = 0
            while written < len(view):
                count = os.write(descriptor, view[written:])
                if count <= 0:
                    raise AssertionError("fixture write stalled")
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _assert_frozen_tree(self, root: Path) -> None:
        for directory, _, file_names in os.walk(root):
            directory_path = Path(directory)
            metadata = os.stat(directory_path, follow_symlinks=False)
            self.assertEqual(metadata.st_mode & 0o222, 0)
            self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)
            for name in file_names:
                path = directory_path / name
                metadata = os.stat(path, follow_symlinks=False)
                self.assertTrue(stat.S_ISREG(metadata.st_mode))
                self.assertEqual(metadata.st_nlink, 1)
                self.assertEqual(metadata.st_mode & 0o222, 0)
                self.assertNotEqual(metadata.st_flags & stat.UF_IMMUTABLE, 0)

    def test_pass_publishes_canonical_exact_frozen_closure(self) -> None:
        (self.partial / "g06").mkdir()
        (self.partial / "g06" / "summary.json").write_bytes(b"{}\n")
        executable = self.partial / "runner.sh"
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)

        result = finalize_evidence_wrapper(**self._arguments())

        self.assertEqual(result, self.final)
        self.assertFalse(self.partial.exists())
        self.assertFalse((self.parent / "run.failed").exists())
        self.assertEqual(
            list(self.parent.glob(".run.evidence-wrapper-*")),
            [],
        )
        manifest_payload = (self.final / "artifact-manifest.json").read_bytes()
        manifest = json.loads(manifest_payload)
        self.assertEqual(manifest_payload, canonical_json_bytes(manifest) + b"\n")
        self.assertEqual(
            [row["path"] for row in manifest["artifacts"]],
            [
                "g06/summary.json",
                "publication-transaction.json",
                "runner.sh",
            ],
        )
        self.assertEqual(manifest["schema_version"], "2.0.0")
        self.assertEqual(manifest["directories"], ["g06"])
        self.assertEqual(
            manifest["project_commit"],
            self._git("rev-parse", "--verify", "HEAD").decode().strip(),
        )
        self.assertIs(manifest["working_tree_clean"], True)
        for row in manifest["artifacts"]:
            path = self.final / row["path"]
            payload = path.read_bytes()
            self.assertEqual(row["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertEqual(row["size_bytes"], len(payload))
            if row["path"] == "publication-transaction.json":
                self.assertEqual(
                    row["producer"],
                    "Mirmir evidence-wrapper recovery",
                )
                self.assertTrue(row["platform"])
                self.assertTrue(row["machine"])
                self.assertEqual(row["gate_ids"], ["G06", "P06"])
                continue
            self.assertEqual(row["producer"], "wrapper-test")
            self.assertEqual(row["command"], "python3 -m unittest wrapper-test")
            self.assertEqual(row["platform"], "macOS arm64 test platform")
            self.assertEqual(row["machine"], "test-machine")
            self.assertEqual(row["gate_ids"], ["G06", "P06"])
        self.assertNotEqual((self.final / "runner.sh").stat().st_mode & 0o111, 0)
        self._assert_frozen_tree(self.final)

    def test_existing_immutable_0400_mode_is_preserved(self) -> None:
        artifact = self.partial / "private.bin"
        artifact.write_bytes(b"private\n")
        artifact.chmod(0o400)
        os.chflags(artifact, artifact.stat().st_flags | stat.UF_IMMUTABLE)

        finalize_evidence_wrapper(**self._arguments())

        published = self.final / "private.bin"
        self.assertEqual(stat.S_IMODE(published.stat().st_mode), 0o400)
        self.assertNotEqual(published.stat().st_flags & stat.UF_IMMUTABLE, 0)

    def test_empty_directories_are_snapshotted_sealed_and_published(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        (self.partial / "empty" / "nested").mkdir(parents=True)

        finalize_evidence_wrapper(**self._arguments())

        self.assertTrue((self.final / "empty" / "nested").is_dir())
        manifest = json.loads((self.final / "artifact-manifest.json").read_bytes())
        self.assertEqual(manifest["directories"], ["empty", "empty/nested"])
        self._assert_frozen_tree(self.final)

    def test_empty_directory_added_after_snapshot_is_rejected(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._write_new_manifest

        def write_then_add_directory(
            root_descriptor: int,
            payload: bytes,
        ) -> None:
            nonlocal injected
            original(root_descriptor, payload)
            if not injected:
                injected = True
                os.mkdir("late-empty", dir_fd=root_descriptor)

        injected = False

        with mock.patch.object(
            wrapper,
            "_write_new_manifest",
            side_effect=write_then_add_directory,
        ), self.assertRaisesRegex(EvidenceWrapperError, "directory set changed"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())

    def test_unsafe_filesystem_path_is_rejected(self) -> None:
        (self.partial / "bad\\name.bin").write_bytes(b"unsafe\n")

        with self.assertRaisesRegex(EvidenceWrapperError, "unsafe artifact path"):
            finalize_evidence_wrapper(**self._arguments())

    def test_symlink_fifo_and_hardlink_are_rejected_without_fifo_blocking(self) -> None:
        cases = []
        symlink_partial, symlink_final = self._new_wrapper("symlink")
        (symlink_partial / "source.bin").write_bytes(b"source\n")
        (symlink_partial / "linked.bin").symlink_to("source.bin")
        cases.append((symlink_partial, symlink_final))

        fifo_partial, fifo_final = self._new_wrapper("fifo")
        (fifo_partial / "source.bin").write_bytes(b"source\n")
        os.mkfifo(fifo_partial / "pipe")
        cases.append((fifo_partial, fifo_final))

        hardlink_partial, hardlink_final = self._new_wrapper("hardlink")
        (hardlink_partial / "source.bin").write_bytes(b"source\n")
        os.link(hardlink_partial / "source.bin", hardlink_partial / "alias.bin")
        cases.append((hardlink_partial, hardlink_final))

        for partial, final in cases:
            with self.subTest(final=final.name), self.assertRaisesRegex(
                EvidenceWrapperError,
                "single-link regular file|linked or special",
            ):
                finalize_evidence_wrapper(**self._arguments(partial, final))
            self.assertFalse(final.exists())

    def test_duplicate_manifest_members_are_rejected(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._write_new_manifest

        def write_duplicate(root_descriptor: int, payload: bytes) -> None:
            nonlocal injected
            original(root_descriptor, payload)
            if injected:
                return
            injected = True
            duplicate = payload.replace(
                b'"schema_version":"2.0.0"',
                b'"schema_version":"2.0.0","schema_version":"2.0.0"',
                1,
            )
            self._write_at(
                root_descriptor,
                wrapper.MANIFEST_NAME,
                duplicate,
                truncate=True,
            )

        injected = False
        with mock.patch.object(
            wrapper,
            "_write_new_manifest",
            side_effect=write_duplicate,
        ), self.assertRaisesRegex(EvidenceWrapperError, "duplicate JSON member"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())

    def test_extra_path_after_manifest_is_rejected(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._write_new_manifest

        def write_then_add(root_descriptor: int, payload: bytes) -> None:
            nonlocal injected
            original(root_descriptor, payload)
            if not injected:
                injected = True
                self._write_at(root_descriptor, "extra.bin", b"extra\n")

        injected = False
        with mock.patch.object(
            wrapper,
            "_write_new_manifest",
            side_effect=write_then_add,
        ), self.assertRaisesRegex(EvidenceWrapperError, "file set changed"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())

    def test_mutated_path_after_manifest_is_rejected(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._write_new_manifest

        def write_then_mutate(root_descriptor: int, payload: bytes) -> None:
            nonlocal injected
            original(root_descriptor, payload)
            if not injected:
                injected = True
                self._write_at(
                    root_descriptor,
                    "payload.bin",
                    b"changed\n",
                    truncate=True,
                )

        injected = False
        with mock.patch.object(
            wrapper,
            "_write_new_manifest",
            side_effect=write_then_mutate,
        ), self.assertRaisesRegex(EvidenceWrapperError, "artifact changed"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())

    def test_destination_race_never_overwrites_or_quarantines_foreign_entry(
        self,
    ) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._rename_exclusive_at
        injected = False

        def race_destination(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            nonlocal injected
            if not injected and destination_name == self.final.name:
                injected = True
                os.mkdir(destination_name, dir_fd=parent_descriptor)
                destination_descriptor = os.open(
                    destination_name,
                    os.O_RDONLY | os.O_DIRECTORY,
                    dir_fd=parent_descriptor,
                )
                try:
                    self._write_at(
                        destination_descriptor,
                        "foreign.txt",
                        b"foreign\n",
                    )
                finally:
                    os.close(destination_descriptor)
                raise EvidenceWrapperError("injected destination race")
            original(parent_descriptor, source_name, destination_name)

        with mock.patch.object(
            wrapper,
            "_rename_exclusive_at",
            side_effect=race_destination,
        ), self.assertRaisesRegex(
            EvidenceWrapperError,
            "uncertain|substitut|destination race",
        ):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())
        foreign = list(self.parent.glob(".run.foreign-*/foreign.txt"))
        self.assertEqual(len(foreign), 1)
        self.assertEqual(foreign[0].read_bytes(), b"foreign\n")

    def test_source_substitution_never_leaves_foreign_canonical_final(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"owned\n")
        original = wrapper._rename_exclusive_at
        injected = False

        def substitute_source(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            nonlocal injected
            if not injected and destination_name == self.final.name:
                injected = True
                original(parent_descriptor, source_name, "owned-away")
                os.mkdir(source_name, dir_fd=parent_descriptor)
                foreign_descriptor = os.open(
                    source_name,
                    os.O_RDONLY | os.O_DIRECTORY,
                    dir_fd=parent_descriptor,
                )
                try:
                    self._write_at(
                        foreign_descriptor,
                        "foreign.txt",
                        b"foreign\n",
                    )
                finally:
                    os.close(foreign_descriptor)
                original(parent_descriptor, source_name, destination_name)
                return
            original(parent_descriptor, source_name, destination_name)

        with mock.patch.object(
            wrapper,
            "_rename_exclusive_at",
            side_effect=substitute_source,
        ), self.assertRaisesRegex(EvidenceWrapperError, "substitut"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertFalse((self.parent / "owned-away").exists())
        failed = self.parent / "run.failed"
        self.assertEqual((failed / "payload.bin").read_bytes(), b"owned\n")
        self.assertFalse((failed / "foreign.txt").exists())
        foreign = list(self.parent.glob(".run.foreign-*/foreign.txt"))
        self.assertEqual(len(foreign), 1)
        self.assertEqual(foreign[0].read_bytes(), b"foreign\n")

    def test_quarantine_source_substitution_never_moves_foreign_to_failed(
        self,
    ) -> None:
        (self.partial / "payload.bin").write_bytes(b"owned\n")
        original = wrapper._rename_exclusive_at
        calls = 0

        def substitute_during_failure_move(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            nonlocal calls
            if destination_name == self.final.name:
                calls += 1
            if calls == 1 and destination_name == self.final.name:
                original(parent_descriptor, source_name, destination_name)
                raise EvidenceWrapperError("force failure preservation")
            if destination_name == "run.failed" and source_name == "run":
                original(parent_descriptor, source_name, "owned-away")
                os.mkdir(source_name, dir_fd=parent_descriptor)
                foreign_descriptor = os.open(
                    source_name,
                    os.O_RDONLY | os.O_DIRECTORY,
                    dir_fd=parent_descriptor,
                )
                try:
                    self._write_at(
                        foreign_descriptor,
                        "foreign.txt",
                        b"foreign\n",
                    )
                finally:
                    os.close(foreign_descriptor)
                original(parent_descriptor, source_name, destination_name)
                return
            original(parent_descriptor, source_name, destination_name)

        with mock.patch.object(
            wrapper,
            "_rename_exclusive_at",
            side_effect=substitute_during_failure_move,
        ), self.assertRaises(EvidenceWrapperError):
            finalize_evidence_wrapper(**self._arguments())

        failed = self.parent / "run.failed"
        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertFalse((self.parent / "owned-away").exists())
        self.assertEqual((failed / "payload.bin").read_bytes(), b"owned\n")
        self.assertFalse((failed / "foreign.txt").exists())
        foreign = list(self.parent.glob(".run.failed.foreign-*/foreign.txt"))
        self.assertEqual(len(foreign), 1)
        self.assertEqual(foreign[0].read_bytes(), b"foreign\n")

    def test_after_seal_failure_is_preserved_and_next_clean_run_succeeds(
        self,
    ) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._require_repository_unchanged
        calls = 0

        def fail_second_check(*args: object, **kwargs: object) -> None:
            nonlocal calls
            calls += 1
            if calls == 2:
                raise EvidenceWrapperError("injected after-seal failure")
            original(*args, **kwargs)

        with mock.patch.object(
            wrapper,
            "_require_repository_unchanged",
            side_effect=fail_second_check,
        ), self.assertRaisesRegex(EvidenceWrapperError, "after-seal"):
            finalize_evidence_wrapper(**self._arguments())

        failed = self.parent / "run.failed"
        self.assertFalse(self.partial.exists())
        self.assertFalse(self.final.exists())
        self.assertTrue((failed / "wrapper-recovery.json").is_file())
        self._assert_frozen_tree(failed)

        next_partial, next_final = self._new_wrapper("next-run")
        (next_partial / "payload.bin").write_bytes(b"next\n")
        result = finalize_evidence_wrapper(
            **self._arguments(next_partial, next_final)
        )
        self.assertEqual(result, next_final)
        self._assert_frozen_tree(next_final)

    def test_completed_rename_then_error_quarantines_pinned_owned_root(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._rename_exclusive_at
        calls = 0

        def rename_then_fail(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            nonlocal calls
            original(parent_descriptor, source_name, destination_name)
            if destination_name == self.final.name:
                calls += 1
            if calls == 1 and destination_name == self.final.name:
                raise EvidenceWrapperError("injected post-rename failure")

        with mock.patch.object(
            wrapper,
            "_rename_exclusive_at",
            side_effect=rename_then_fail,
        ), self.assertRaisesRegex(EvidenceWrapperError, "uncertain|post-rename"):
            finalize_evidence_wrapper(**self._arguments())

        failed = self.parent / "run.failed"
        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertTrue(failed.is_dir())
        self._assert_frozen_tree(failed)

    def test_quarantine_cleanup_error_is_propagated_and_owned_root_stays_sealed(
        self,
    ) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._rename_exclusive_at
        calls = 0

        def rename_outage(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            nonlocal calls
            if calls == 0 and destination_name == self.final.name:
                calls += 1
                original(parent_descriptor, source_name, destination_name)
                raise EvidenceWrapperError("injected post-rename failure")
            if calls == 1:
                raise EvidenceWrapperError("injected quarantine rename outage")
            original(parent_descriptor, source_name, destination_name)

        with mock.patch.object(
            wrapper,
            "_rename_exclusive_at",
            side_effect=rename_outage,
        ), self.assertRaisesRegex(EvidenceWrapperError, "cleanup failed"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertTrue(self.final.is_dir())
        self.assertFalse((self.parent / "run.failed").exists())
        self._assert_frozen_tree(self.final)

    def test_post_manifest_creation_failure_is_preserved_without_partial(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._write_new_manifest
        injected = False

        def write_then_fail(root_descriptor: int, payload: bytes) -> None:
            nonlocal injected
            original(root_descriptor, payload)
            if not injected:
                injected = True
                raise EvidenceWrapperError("injected post-manifest failure")

        with mock.patch.object(
            wrapper,
            "_write_new_manifest",
            side_effect=write_then_fail,
        ), self.assertRaisesRegex(EvidenceWrapperError, "post-manifest"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        failed = self.parent / "run.failed"
        self.assertTrue((failed / "wrapper-recovery.json").is_file())
        self._assert_frozen_tree(failed)

    def test_repository_drift_after_publication_is_quarantined(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._require_repository_unchanged
        calls = 0

        def drift_on_third_check(
            project_root: Path,
            expected: wrapper.RepositoryState,
            expected_identity: os.stat_result,
        ) -> None:
            nonlocal calls
            calls += 1
            if calls == 3:
                self.readme.write_bytes(b"repository drift\n")
            original(project_root, expected, expected_identity)

        with mock.patch.object(
            wrapper,
            "_require_repository_unchanged",
            side_effect=drift_on_third_check,
        ), self.assertRaisesRegex(
            EvidenceWrapperError,
            "working tree is not clean|repository state changed",
        ):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())
        self._assert_frozen_tree(self.parent / "run.failed")

    def test_strict_final_reopen_failure_is_quarantined(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._verify_tree
        frozen_reopen_seen = False

        def fail_final_reopen(
            *args: object,
            **kwargs: object,
        ) -> wrapper.TreeSnapshot:
            nonlocal frozen_reopen_seen
            if kwargs.get("require_frozen") is True:
                frozen_reopen_seen = True
                raise EvidenceWrapperError("injected final reopen mismatch")
            return original(*args, **kwargs)

        with mock.patch.object(
            wrapper,
            "_verify_tree",
            side_effect=fail_final_reopen,
        ), self.assertRaisesRegex(EvidenceWrapperError, "final reopen mismatch"):
            finalize_evidence_wrapper(**self._arguments())

        self.assertTrue(frozen_reopen_seen)
        self.assertFalse(self.final.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())

    def test_crash_after_rename_is_recovered_to_failure_evidence(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")

        crashed = self._run_crashing_finalizer(
            partial=self.partial,
            final=self.final,
            boundary="post-rename",
        )

        self.assertEqual(crashed.returncode, 73, crashed.stderr.decode())
        self.assertTrue(self.final.is_dir())
        marker = self.parent / ".run.evidence-wrapper-transaction.json"
        self.assertTrue(marker.is_file())
        self.assertFalse(
            (self.parent / ".run.evidence-wrapper-complete.json").exists()
        )

        with self.assertRaisesRegex(
            EvidenceWrapperError,
            "recovered interrupted evidence wrapper",
        ):
            finalize_evidence_wrapper(**self._arguments())

        failed = self.parent / "run.failed"
        self.assertFalse(self.final.exists())
        self.assertFalse(self.partial.exists())
        self.assertFalse(marker.exists())
        recovery = json.loads((failed / "wrapper-recovery.json").read_bytes())
        self.assertEqual(recovery["recovery_kind"], "startup_recovery")
        self.assertEqual(recovery["error"]["type"], "InterruptedPublication")
        self._assert_frozen_tree(failed)

    def test_unsealed_atomic_control_records_recover_only_as_failure(self) -> None:
        for boundary, exit_code in (
            ("marker-unsealed", 79),
            ("completion-unsealed", 80),
        ):
            with self.subTest(boundary=boundary):
                partial, final = self._new_wrapper(boundary)
                (partial / "payload.bin").write_bytes(boundary.encode("utf-8"))
                crashed = self._run_crashing_finalizer(
                    partial=partial,
                    final=final,
                    boundary=boundary,
                )
                self.assertEqual(
                    crashed.returncode,
                    exit_code,
                    crashed.stderr.decode(),
                )
                marker = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-transaction.json"
                )
                self.assertTrue(marker.is_file())
                self.assertEqual(
                    os.stat(marker, follow_symlinks=False).st_flags
                    & stat.UF_IMMUTABLE,
                    0 if boundary == "marker-unsealed" else stat.UF_IMMUTABLE,
                )
                receipt = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-complete.json"
                )
                self.assertEqual(receipt.exists(), boundary == "completion-unsealed")
                if receipt.exists():
                    self.assertEqual(
                        os.stat(receipt, follow_symlinks=False).st_flags
                        & stat.UF_IMMUTABLE,
                        0,
                    )

                with self.assertRaisesRegex(
                    EvidenceWrapperError,
                    "recovered interrupted evidence wrapper",
                ):
                    finalize_evidence_wrapper(**self._arguments(partial, final))

                failed = self.parent / f"{final.name}.failed"
                self.assertTrue(failed.is_dir())
                self.assertFalse(final.exists())
                self.assertFalse(partial.exists())
                self.assertFalse(marker.exists())
                self.assertFalse(receipt.exists())
                recovery = json.loads(
                    (failed / "wrapper-recovery.json").read_bytes()
                )
                self.assertIn("unsealed", recovery["recovery_kind"])
                self._assert_frozen_tree(failed)

    def test_staged_atomic_control_records_recover_only_as_failure(self) -> None:
        for boundary, exit_code, kind in (
            ("marker-staged", 81, "marker"),
            ("completion-staged", 82, "completion"),
        ):
            with self.subTest(boundary=boundary):
                partial, final = self._new_wrapper(boundary)
                (partial / "payload.bin").write_bytes(boundary.encode("utf-8"))
                crashed = self._run_crashing_finalizer(
                    partial=partial,
                    final=final,
                    boundary=boundary,
                )
                self.assertEqual(
                    crashed.returncode,
                    exit_code,
                    crashed.stderr.decode(),
                )
                staged = list(
                    self.parent.glob(f".evidence-wrapper-{kind}-*.tmp")
                )
                self.assertEqual(len(staged), 1)
                marker = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-transaction.json"
                )
                receipt = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-complete.json"
                )
                self.assertEqual(marker.exists(), boundary == "completion-staged")
                self.assertFalse(receipt.exists())

                with self.assertRaisesRegex(
                    EvidenceWrapperError,
                    "recovered interrupted evidence wrapper",
                ):
                    finalize_evidence_wrapper(**self._arguments(partial, final))

                failed = self.parent / f"{final.name}.failed"
                self.assertTrue(failed.is_dir())
                self.assertFalse(final.exists())
                self.assertFalse(partial.exists())
                self.assertFalse(marker.exists())
                self.assertFalse(receipt.exists())
                self.assertFalse(staged[0].exists())
                recovery = json.loads(
                    (failed / "wrapper-recovery.json").read_bytes()
                )
                self.assertIn("unsealed", recovery["recovery_kind"])
                self._assert_frozen_tree(failed)

    def test_completion_receipt_boundaries_recover_idempotent_success(self) -> None:
        for boundary, exit_code in (
            ("both-records", 74),
            ("completion-only", 75),
            ("no-records", 76),
            ("active-cleanup", 77),
            ("completion-cleanup", 78),
        ):
            with self.subTest(boundary=boundary):
                partial, final = self._new_wrapper(boundary)
                (partial / "payload.bin").write_bytes(boundary.encode("utf-8"))
                crashed = self._run_crashing_finalizer(
                    partial=partial,
                    final=final,
                    boundary=boundary,
                )
                self.assertEqual(
                    crashed.returncode,
                    exit_code,
                    crashed.stderr.decode(),
                )
                marker = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-transaction.json"
                )
                receipt = (
                    self.parent
                    / f".{final.name}.evidence-wrapper-complete.json"
                )
                self.assertEqual(marker.exists(), boundary == "both-records")
                self.assertEqual(
                    receipt.exists(),
                    boundary
                    not in {"no-records", "completion-cleanup"},
                )

                result = finalize_evidence_wrapper(
                    **self._arguments(partial, final)
                )

                self.assertEqual(result, final)
                self.assertFalse(marker.exists())
                self.assertFalse(receipt.exists())
                self.assertEqual(
                    list(
                        self.parent.glob(
                            f".{final.name}.evidence-wrapper-*.cleanup-*"
                        )
                    ),
                    [],
                )
                self.assertFalse(partial.exists())
                self.assertFalse((self.parent / f"{final.name}.failed").exists())
                self._assert_frozen_tree(final)

    def test_repository_mutation_during_final_reopen_is_quarantined(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        original = wrapper._verify_tree

        def mutate_after_final_reopen(
            *args: object,
            **kwargs: object,
        ) -> wrapper.TreeSnapshot:
            result = original(*args, **kwargs)
            if kwargs.get("require_frozen") is True:
                self.readme.write_bytes(b"drift during final reopen\n")
            return result

        with mock.patch.object(
            wrapper,
            "_verify_tree",
            side_effect=mutate_after_final_reopen,
        ), self.assertRaisesRegex(
            EvidenceWrapperError,
            "working tree is not clean|repository state changed",
        ):
            finalize_evidence_wrapper(**self._arguments())

        self.assertFalse(self.final.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())
        self._assert_frozen_tree(self.parent / "run.failed")

    def test_provenance_mutation_during_final_reopen_is_quarantined(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        provenance_map = self.parent / "provenance-map.json"
        provenance_map.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "rules": [
                        {
                            "exact_path": "payload.bin",
                            "producer": "producer-a",
                            "command": "command-a",
                            "platform": "platform-a",
                            "machine": "machine-a",
                        }
                    ],
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        original = wrapper._verify_tree

        def mutate_after_final_reopen(
            *args: object,
            **kwargs: object,
        ) -> wrapper.TreeSnapshot:
            result = original(*args, **kwargs)
            if kwargs.get("require_frozen") is True:
                payload = provenance_map.read_text(encoding="utf-8")
                provenance_map.write_text(
                    payload.replace("producer-a", "producer-b"),
                    encoding="utf-8",
                )
            return result

        with mock.patch.object(
            wrapper,
            "_verify_tree",
            side_effect=mutate_after_final_reopen,
        ), self.assertRaisesRegex(EvidenceWrapperError, "provenance map changed"):
            finalize_evidence_wrapper(
                **self._arguments(provenance_map=provenance_map)
            )

        self.assertFalse(self.final.exists())
        self.assertTrue((self.parent / "run.failed").is_dir())
        self._assert_frozen_tree(self.parent / "run.failed")

    def test_aliased_parent_and_project_root_are_rejected(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        alias_parent = self.project / "artifact-alias"
        alias_parent.symlink_to(self.parent, target_is_directory=True)
        aliased_partial = alias_parent / self.partial.name
        aliased_final = alias_parent / self.final.name

        with self.assertRaisesRegex(EvidenceWrapperError, "aliased"):
            finalize_evidence_wrapper(
                **self._arguments(aliased_partial, aliased_final)
            )

        alias_project = self.root / "project-alias"
        alias_project.symlink_to(self.project, target_is_directory=True)
        with self.assertRaisesRegex(EvidenceWrapperError, "aliased"):
            finalize_evidence_wrapper(
                **self._arguments(project_root=alias_project)
            )

    def test_invalid_provenance_and_dirty_repo_fail_before_transaction_start(
        self,
    ) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        with self.assertRaisesRegex(EvidenceWrapperError, "supplied together"):
            finalize_evidence_wrapper(**self._arguments(platform=None))
        self.assertTrue(self.partial.is_dir())
        self.assertFalse(
            (self.parent / ".run.evidence-wrapper-transaction.json").exists()
        )
        self.assertFalse((self.partial / "artifact-manifest.json").exists())

        self.readme.write_bytes(b"dirty before transaction\n")
        with self.assertRaisesRegex(EvidenceWrapperError, "not clean"):
            finalize_evidence_wrapper(**self._arguments())
        self.assertTrue(self.partial.is_dir())
        self.assertFalse(
            (self.parent / ".run.evidence-wrapper-transaction.json").exists()
        )
        self.assertFalse((self.partial / "artifact-manifest.json").exists())

    def test_existing_final_or_failure_is_never_replaced(self) -> None:
        (self.partial / "payload.bin").write_bytes(b"payload\n")
        self.final.mkdir()
        (self.final / "foreign.txt").write_bytes(b"foreign final\n")
        with self.assertRaisesRegex(EvidenceWrapperError, "already exists"):
            finalize_evidence_wrapper(**self._arguments())
        self.assertEqual(
            (self.final / "foreign.txt").read_bytes(),
            b"foreign final\n",
        )

        shutil.rmtree(self.final)
        failed = self.parent / "run.failed"
        failed.mkdir()
        (failed / "foreign.txt").write_bytes(b"foreign failure\n")
        with self.assertRaisesRegex(EvidenceWrapperError, "already exists"):
            finalize_evidence_wrapper(**self._arguments())
        self.assertEqual(
            (failed / "foreign.txt").read_bytes(),
            b"foreign failure\n",
        )

    def test_provenance_map_exact_longest_prefix_and_fallback_are_deterministic(
        self,
    ) -> None:
        (self.partial / "g04" / "nested").mkdir(parents=True)
        (self.partial / "g05").mkdir()
        files = {
            "g04/base.json": b"base\n",
            "g04/nested/deep.json": b"deep\n",
            "g04/special.json": b"special\n",
            "g05/result.json": b"result\n",
            "other.txt": b"other\n",
        }
        for relative, payload in files.items():
            (self.partial / relative).write_bytes(payload)
        provenance_map = self.parent / "provenance-map.json"
        provenance_map.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "rules": [
                        {
                            "path_prefix": "g04",
                            "producer": "g04-producer",
                            "command": "g04-command",
                            "platform": "g04-platform",
                            "machine": "g04-machine",
                        },
                        {
                            "path_prefix": "g04/nested",
                            "producer": "nested-producer",
                            "command": "nested-command",
                            "platform": "nested-platform",
                            "machine": "nested-machine",
                        },
                        {
                            "exact_path": "g04/special.json",
                            "producer": "exact-producer",
                            "command": "exact-command",
                            "platform": "exact-platform",
                            "machine": "exact-machine",
                        },
                        {
                            "path_prefix": "g05",
                            "producer": "g05-producer",
                            "command": "g05-command",
                            "platform": "g05-platform",
                            "machine": "g05-machine",
                            "gate_ids": ["G05"],
                        },
                    ],
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        finalize_evidence_wrapper(
            **self._arguments(provenance_map=provenance_map)
        )

        manifest = json.loads((self.final / "artifact-manifest.json").read_bytes())
        by_path = {row["path"]: row for row in manifest["artifacts"]}
        self.assertEqual(by_path["g04/base.json"]["producer"], "g04-producer")
        self.assertEqual(
            by_path["g04/nested/deep.json"]["producer"],
            "nested-producer",
        )
        self.assertEqual(
            by_path["g04/special.json"]["producer"],
            "exact-producer",
        )
        self.assertEqual(by_path["g05/result.json"]["gate_ids"], ["G05"])
        self.assertEqual(by_path["other.txt"]["producer"], "wrapper-test")

    def test_ambiguous_and_unmatched_provenance_rules_fail_closed(self) -> None:
        cases = []
        ambiguous_partial, ambiguous_final = self._new_wrapper("ambiguous")
        (ambiguous_partial / "payload.bin").write_bytes(b"payload\n")
        ambiguous_map = self.parent / "ambiguous-map.json"
        duplicate_rule = {
            "exact_path": "payload.bin",
            "producer": "producer",
            "command": "command",
            "platform": "platform",
            "machine": "machine",
        }
        ambiguous_map.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "rules": [duplicate_rule, duplicate_rule],
                }
            ),
            encoding="utf-8",
        )
        cases.append(
            (
                ambiguous_partial,
                ambiguous_final,
                ambiguous_map,
                "ambiguous exact provenance",
            )
        )

        unmatched_partial, unmatched_final = self._new_wrapper("unmatched")
        (unmatched_partial / "payload.bin").write_bytes(b"payload\n")
        unmatched_map = self.parent / "unmatched-map.json"
        unmatched_map.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "rules": [
                        {
                            "exact_path": "different.bin",
                            "producer": "producer",
                            "command": "command",
                            "platform": "platform",
                            "machine": "machine",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        cases.append(
            (
                unmatched_partial,
                unmatched_final,
                unmatched_map,
                "unmatched artifact provenance",
            )
        )

        for partial, final, provenance_map, message in cases:
            with self.subTest(final=final.name), self.assertRaisesRegex(
                EvidenceWrapperError,
                message,
            ):
                finalize_evidence_wrapper(
                    **self._arguments(
                        partial,
                        final,
                        producer=None,
                        command=None,
                        platform=None,
                        machine=None,
                        provenance_map=provenance_map,
                    )
                )
            self.assertFalse(final.exists())


if __name__ == "__main__":
    unittest.main()
