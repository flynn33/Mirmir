#!/usr/bin/env python3
"""Run and atomically publish the five ordered pre-release G06 evidence files."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
import time
import traceback
import uuid
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.release_evidence import (  # noqa: E402
    NATIVE_BENCHMARK_PROOF_NODE_ID,
    NATIVE_INTEGRATION_TEST_IDS,
    PYTHON_TEST_RUNNER_IDS,
    RELEASE_LOCK_TEST_MODULES,
    RELEASE_RUNTIME_TEST_IDS,
    TEST_EVIDENCE_IDS,
    actionable_diagnostic_counts,
)
from validation.calibration_v2.tools.finalize_p06_runtime_correction import (  # noqa: E402
    RuntimeCorrectionArtifactError,
    VerifiedRuntimeCorrection,
    _fchflags,
    _rename_exclusive,
    _rename_exclusive_at,
    runtime_correction_repository_state,
    verify_frozen_runtime_correction,
    verify_runtime_correction_copy,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)


SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/g06-test-evidence-v1.schema.json"
)
RUNTIME_MANIFEST_SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "p06-runtime-correction-artifact-manifest-v1.schema.json"
)
NATIVE_BENCHMARK_SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "control-aggregate-cache-native-benchmark-v1.schema.json"
)
NATIVE_BENCHMARK_SCHEMA_REPOSITORY_PATH = (
    "validation/calibration_v2/schemas/"
    "control-aggregate-cache-native-benchmark-v1.schema.json"
)
NATIVE_BENCHMARK_REQUIRED_BINDING = (
    "the immutable correction-r2 artifact manifest must bind this benchmark's "
    "final SHA-256 and size under the same run_id"
)
RUNTIME_FINALIZER_REPOSITORY_PATH = (
    "validation/calibration_v2/tools/finalize_p06_runtime_correction.py"
)
VERIFIER_SOURCE_PATH = Path(__file__).resolve(strict=True)
REQUIRED_G06_TEST_EVIDENCE_IDS = TEST_EVIDENCE_IDS
NATIVE_INTEGRATION_TESTS = NATIVE_INTEGRATION_TEST_IDS
RELEASE_RUNTIME_TESTS = RELEASE_RUNTIME_TEST_IDS
G06_TRANSACTION_SCHEMA_VERSION = "1.0.0"
G06_TRANSACTION_TOKEN_NAME = "g06-publication-transaction.json"


class G06VerificationError(RuntimeError):
    """The verification run or its immutable evidence publication is invalid."""


@dataclass(frozen=True)
class GroupResult:
    status: str
    started_utc: str
    finished_utc: str
    commands: Tuple[Mapping[str, object], ...]
    artifacts: Tuple[Mapping[str, object], ...]
    summary: Mapping[str, object]
    failure_reason: Optional[str]


@dataclass(frozen=True)
class VerificationRunResult:
    status: str
    path: Path
    evidence_paths: Tuple[Tuple[str, Path], ...]


@dataclass(frozen=True)
class _G06PublicationTransaction:
    output_root: Path
    run_id: str
    token: str
    staging_name: str
    partial_name: str
    final_name: str
    failed_name: str
    marker_name: str
    root_metadata: os.stat_result
    marker_metadata: os.stat_result
    document: Mapping[str, object]


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def _validate_run_id(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or Path(value).name != value
        or Path(value).is_absolute()
        or "/" in value
        or "\\" in value
        or "\x00" in value
    ):
        raise G06VerificationError("run ID must be one safe filename component")
    return value


def _validate_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise G06VerificationError(f"{label} is not a lowercase SHA-256")
    return value


def _safe_relative(value: object) -> PurePosixPath:
    if not isinstance(value, str):
        raise G06VerificationError("artifact ID is not a string")
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise G06VerificationError(f"unsafe artifact ID: {value!r}")
    return path


def _safe_child(root: Path, artifact_id: str) -> Path:
    relative = _safe_relative(artifact_id)
    path = root.joinpath(*relative.parts)
    try:
        path.parent.resolve(strict=False).relative_to(root.resolve(strict=True))
    except ValueError as error:
        raise G06VerificationError("artifact path escapes the run root") from error
    return path


def _directory_identity(path: Path, *, label: str) -> os.stat_result:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"{label} is absent: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise G06VerificationError(f"{label} is linked or not a directory: {path}")
    return metadata


def _require_directory_identity(
    path: Path,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    current = _directory_identity(path, label=label)
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise G06VerificationError(f"{label} identity changed: {path}")


def _path_has_directory_identity(path: Path, expected: os.stat_result) -> bool:
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    return stat.S_ISDIR(current.st_mode) and (
        current.st_dev,
        current.st_ino,
    ) == (expected.st_dev, expected.st_ino)


def _identity(metadata: os.stat_result) -> Tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def _directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def _open_real_directory_path(
    path: Path,
    *,
    label: str,
) -> Tuple[int, os.stat_result]:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"{label} is absent: {path}") from error
    if not stat.S_ISDIR(before.st_mode):
        raise G06VerificationError(
            f"{label} is linked or not a directory: {path}"
        )
    try:
        descriptor = os.open(path, _directory_open_flags())
    except OSError as error:
        raise G06VerificationError(f"{label} could not be opened: {path}") from error
    try:
        opened = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or _identity(opened) != _identity(before)
            or _identity(current) != _identity(before)
        ):
            raise G06VerificationError(
                f"{label} identity changed while opening: {path}"
            )
        return descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def _stat_at(
    parent_descriptor: int,
    name: str,
) -> Optional[os.stat_result]:
    try:
        return os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return None


def _open_real_directory_at(
    parent_descriptor: int,
    name: str,
    *,
    label: str,
) -> Tuple[int, os.stat_result]:
    before = _stat_at(parent_descriptor, name)
    if before is None:
        raise G06VerificationError(f"{label} is absent")
    if not stat.S_ISDIR(before.st_mode):
        raise G06VerificationError(f"{label} is linked or not a directory")
    try:
        descriptor = os.open(
            name,
            _directory_open_flags(),
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        raise G06VerificationError(f"{label} could not be opened") from error
    try:
        opened = os.fstat(descriptor)
        current = _stat_at(parent_descriptor, name)
        if (
            current is None
            or not stat.S_ISDIR(opened.st_mode)
            or _identity(opened) != _identity(before)
            or _identity(current) != _identity(before)
        ):
            raise G06VerificationError(
                f"{label} identity changed while opening"
            )
        return descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def _require_entry_identity_at(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    current = _stat_at(parent_descriptor, name)
    if (
        current is None
        or stat.S_IFMT(current.st_mode) != stat.S_IFMT(expected.st_mode)
        or _identity(current) != _identity(expected)
    ):
        raise G06VerificationError(f"{label} identity changed")


def _require_path_identity(
    path: Path,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"{label} became unavailable") from error
    if (
        stat.S_IFMT(current.st_mode) != stat.S_IFMT(expected.st_mode)
        or _identity(current) != _identity(expected)
    ):
        raise G06VerificationError(f"{label} identity changed")


def _read_regular_at(
    parent_descriptor: int,
    name: str,
    *,
    label: str,
) -> Tuple[bytes, os.stat_result]:
    before = _stat_at(parent_descriptor, name)
    if before is None:
        raise G06VerificationError(f"{label} is absent")
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise G06VerificationError(
            f"{label} is not a single-link regular file"
        )
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise G06VerificationError(f"{label} could not be opened") from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or _identity(opened) != _identity(before)
        ):
            raise G06VerificationError(f"{label} changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = _stat_at(parent_descriptor, name)
    if (
        current is None
        or _identity(after) != _identity(before)
        or _identity(current) != _identity(before)
        or after.st_size != before.st_size
        or current.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or current.st_mtime_ns != before.st_mtime_ns
        or after.st_mode != before.st_mode
        or current.st_mode != before.st_mode
    ):
        raise G06VerificationError(f"{label} changed while reading")
    return b"".join(chunks), after


def _write_new_at(
    parent_descriptor: int,
    name: str,
    payload: bytes,
    *,
    mode: int,
    label: str,
) -> os.stat_result:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(
            name,
            flags,
            mode,
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        raise G06VerificationError(f"{label} could not be created") from error
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("descriptor-relative write made no progress")
            offset += written
        os.fsync(descriptor)
        created = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    reopened, current = _read_regular_at(
        parent_descriptor,
        name,
        label=label,
    )
    if (
        reopened != payload
        or _identity(current) != _identity(created)
        or current.st_mode & 0o777 != mode
    ):
        raise G06VerificationError(f"{label} changed after creation")
    os.fsync(parent_descriptor)
    return current


def _write_new_control_at(
    parent_descriptor: int,
    name: str,
    payload: bytes,
    *,
    mode: int,
    label: str,
    token: str,
    kind: str,
    run_id: str,
) -> os.stat_result:
    """Publish complete control bytes by exclusive rename from a private inode."""

    if kind not in {"root-token", "sibling-marker"}:
        raise G06VerificationError("G06 control record kind is invalid")
    validated_run_id = _validate_run_id(run_id)
    temporary_name = f".{validated_run_id}.g06-{kind}-{token}.tmp"
    if _stat_at(parent_descriptor, name) is not None:
        raise G06VerificationError(f"{label} already exists")
    if _stat_at(parent_descriptor, temporary_name) is not None:
        raise G06VerificationError(f"{label} staging path already exists")
    staged = _write_new_at(
        parent_descriptor,
        temporary_name,
        payload,
        mode=mode,
        label=f"{label} staging record",
    )
    try:
        _require_entry_identity_at(
            parent_descriptor,
            temporary_name,
            staged,
            label=f"{label} staging record",
        )
        _rename_exclusive_at(
            parent_descriptor,
            temporary_name,
            parent_descriptor,
            name,
        )
        os.fsync(parent_descriptor)
        _require_entry_identity_at(
            parent_descriptor,
            name,
            staged,
            label=label,
        )
        if _stat_at(parent_descriptor, temporary_name) is not None:
            raise G06VerificationError(f"{label} staging path survived publication")
        reopened, current = _read_regular_at(
            parent_descriptor,
            name,
            label=label,
        )
        if reopened != payload or _identity(current) != _identity(staged):
            raise G06VerificationError(f"{label} changed after atomic publication")
        return current
    except BaseException:
        current = _stat_at(parent_descriptor, temporary_name)
        if current is not None and _identity(current) == _identity(staged):
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
            except OSError:
                pass
        raise


def _seal_g06_descriptor(descriptor: int, *, label: str) -> None:
    if not hasattr(stat, "UF_IMMUTABLE"):
        raise G06VerificationError(
            "macOS user-immutable flags are required for G06 commit"
        )
    metadata = os.fstat(descriptor)
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    if metadata.st_mode & write_bits:
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) & ~write_bits)
        metadata = os.fstat(descriptor)
    if not metadata.st_flags & stat.UF_IMMUTABLE:
        try:
            _fchflags(descriptor, metadata.st_flags | stat.UF_IMMUTABLE)
        except OSError as error:
            raise G06VerificationError(f"{label} could not be frozen") from error
    os.fsync(descriptor)
    sealed = os.fstat(descriptor)
    if sealed.st_mode & write_bits or not sealed.st_flags & stat.UF_IMMUTABLE:
        raise G06VerificationError(f"{label} is not frozen")


def _freeze_g06_tree_at(root_descriptor: int) -> None:
    for directory, _, file_names, descriptor in os.fwalk(
        ".",
        topdown=False,
        onerror=_raise_tree_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        relative_directory = "" if directory == "." else directory[2:]
        for name in sorted(file_names):
            relative = name if not relative_directory else f"{relative_directory}/{name}"
            before = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise G06VerificationError(
                    f"G06 commit closure contains a special or multiply linked file: {relative}"
                )
            file_descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(file_descriptor)
                if _identity(opened) != _identity(before):
                    raise G06VerificationError(
                        f"G06 commit file changed while opening: {relative}"
                    )
                _seal_g06_descriptor(
                    file_descriptor,
                    label=f"G06 commit file {relative}",
                )
            finally:
                os.close(file_descriptor)
        _seal_g06_descriptor(
            descriptor,
            label=f"G06 commit directory {relative_directory or '<root>'}",
        )


def _require_g06_tree_frozen_at(root_descriptor: int) -> None:
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=_raise_tree_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        relative_directory = "" if directory == "." else directory[2:]
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_mode & write_bits
            or not metadata.st_flags & stat.UF_IMMUTABLE
        ):
            raise G06VerificationError(
                f"G06 commit directory is not frozen: {relative_directory or '<root>'}"
            )
        for name in directory_names:
            child = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(child.st_mode):
                raise G06VerificationError("G06 frozen closure contains a linked directory")
        for name in file_names:
            child = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if (
                not stat.S_ISREG(child.st_mode)
                or child.st_nlink != 1
                or child.st_mode & write_bits
                or not child.st_flags & stat.UF_IMMUTABLE
            ):
                raise G06VerificationError("G06 frozen closure contains a mutable file")


def _prepare_g06_root_for_failure(root_descriptor: int) -> None:
    metadata = os.fstat(root_descriptor)
    if hasattr(stat, "UF_IMMUTABLE") and metadata.st_flags & stat.UF_IMMUTABLE:
        try:
            _fchflags(root_descriptor, metadata.st_flags & ~stat.UF_IMMUTABLE)
        except OSError as error:
            raise G06VerificationError(
                "owned G06 failure root could not be thawed"
            ) from error
        metadata = os.fstat(root_descriptor)
    desired_mode = stat.S_IMODE(metadata.st_mode) | stat.S_IWUSR
    if stat.S_IMODE(metadata.st_mode) != desired_mode:
        os.fchmod(root_descriptor, desired_mode)
    os.fsync(root_descriptor)


def _quarantine_g06_success(
    *,
    final: Path,
    partial: Path,
    failed: Path,
    expected: os.stat_result,
) -> None:
    del partial
    if not _path_has_directory_identity(final, expected):
        if final.exists() or final.is_symlink():
            raise G06VerificationError(
                "G06 success path contains a foreign entry during quarantine"
            )
        return
    candidates = [
        failed.with_name(
            f"{failed.name}-recovery-{uuid.uuid4().hex}"
        )
        for _ in range(6)
    ]
    last_error: Optional[BaseException] = None
    for candidate in candidates:
        if candidate.exists() or candidate.is_symlink():
            continue
        try:
            _rename_exclusive(final, candidate)
            return
        except BaseException as error:
            last_error = error
            if not _path_has_directory_identity(final, expected):
                if final.exists() or final.is_symlink():
                    raise G06VerificationError(
                        "G06 success path was replaced during quarantine"
                    ) from error
                return
    raise G06VerificationError(
        "G06 success publication could not be quarantined"
    ) from last_error


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"evidence file is absent: {path}") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise G06VerificationError(f"evidence path is not a regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino)
            != (before.st_dev, before.st_ino)
        ):
            raise G06VerificationError("evidence file changed while opening")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = os.stat(path, follow_symlinks=False)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or (current.st_dev, current.st_ino)
        != (before.st_dev, before.st_ino)
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
        or after.st_size != before.st_size
        or current.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or current.st_mtime_ns != before.st_mtime_ns
    ):
        raise G06VerificationError("evidence file changed while reading")
    return b"".join(chunks)


def _decode_utf8(payload: bytes, *, label: str) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise G06VerificationError(
            f"G06 text evidence is not strict UTF-8: {label}"
        ) from error


def _raise_tree_walk_error(error: OSError) -> None:
    raise G06VerificationError(
        f"G06 tree traversal failed: {error}"
    ) from error


def _fsync_tree(path: Path) -> None:
    root_descriptor, root_metadata = _open_real_directory_path(
        path,
        label="G06 fsync root",
    )
    try:
        for _, directory_names, file_names, directory_descriptor in os.fwalk(
            ".",
            topdown=False,
            onerror=_raise_tree_walk_error,
            follow_symlinks=False,
            dir_fd=root_descriptor,
        ):
            directory_names.sort()
            file_names.sort()
            for name in directory_names:
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISDIR(metadata.st_mode):
                    raise G06VerificationError(
                        "G06 tree contains a symbolic or non-directory entry"
                    )
            for name in file_names:
                before = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                    raise G06VerificationError(
                        "G06 tree contains a non-regular or multiply linked file"
                    )
                descriptor = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_NONBLOCK", 0),
                    dir_fd=directory_descriptor,
                )
                try:
                    metadata = os.fstat(descriptor)
                    if (
                        not stat.S_ISREG(metadata.st_mode)
                        or metadata.st_nlink != 1
                        or _identity(metadata) != _identity(before)
                    ):
                        raise G06VerificationError(
                            "G06 tree file changed while opening for synchronization"
                        )
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            os.fsync(directory_descriptor)
        _require_path_identity(
            path,
            root_metadata,
            label="G06 fsync root",
        )
    finally:
        os.close(root_descriptor)


def _write_new(path: Path, payload: bytes, *, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, mode)
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("evidence publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _read_regular(path) != payload:
        raise G06VerificationError(f"published evidence changed: {path}")


def _derived_data_name(expected_relative_path: str) -> str:
    relative = _safe_relative(expected_relative_path)
    if (
        len(relative.parts) != 2
        or relative.parts[0] != "build"
        or relative.parts[1]
        not in {"native-integration-derived-data", "release-derived-data"}
    ):
        raise G06VerificationError("DerivedData cleanup path differs")
    return relative.parts[1]


def _unlink_invalid_entry_at(
    parent_descriptor: int,
    name: str,
    metadata: os.stat_result,
    *,
    label: str,
) -> None:
    if stat.S_ISDIR(metadata.st_mode):
        raise G06VerificationError(f"{label} unexpectedly became a directory")
    try:
        os.unlink(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise G06VerificationError(f"{label} could not be removed") from error
    if _stat_at(parent_descriptor, name) is not None:
        raise G06VerificationError(f"{label} removal was incomplete")


def _empty_directory_descriptor(root_descriptor: int) -> None:
    for _, directory_names, file_names, directory_descriptor in os.fwalk(
        ".",
        topdown=False,
        onerror=_raise_tree_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        file_names.sort()
        for name in file_names:
            os.unlink(name, dir_fd=directory_descriptor)
        for name in directory_names:
            metadata = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            if stat.S_ISDIR(metadata.st_mode):
                os.rmdir(name, dir_fd=directory_descriptor)
            else:
                os.unlink(name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)


def _remove_real_directory_at(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    quarantine_name = f".{name}.discard-{uuid.uuid4().hex}"
    if _stat_at(parent_descriptor, quarantine_name) is not None:
        raise G06VerificationError(
            f"{label} quarantine destination already exists"
        )
    try:
        _rename_exclusive_at(
            parent_descriptor,
            name,
            parent_descriptor,
            quarantine_name,
        )
    except (OSError, RuntimeCorrectionArtifactError) as error:
        raise G06VerificationError(f"{label} quarantine rename failed") from error
    _require_entry_identity_at(
        parent_descriptor,
        quarantine_name,
        expected,
        label=f"quarantined {label}",
    )
    quarantine_descriptor, opened = _open_real_directory_at(
        parent_descriptor,
        quarantine_name,
        label=f"quarantined {label}",
    )
    try:
        if _identity(opened) != _identity(expected):
            raise G06VerificationError(
                f"quarantined {label} identity changed while opening"
            )
        last_error: Optional[OSError] = None
        for _ in range(4):
            _empty_directory_descriptor(quarantine_descriptor)
            _require_entry_identity_at(
                parent_descriptor,
                quarantine_name,
                expected,
                label=f"emptied {label}",
            )
            try:
                os.rmdir(quarantine_name, dir_fd=parent_descriptor)
                last_error = None
                break
            except OSError as error:
                last_error = error
        if last_error is not None:
            raise G06VerificationError(
                f"{label} quarantine remained nonempty"
            ) from last_error
        os.fsync(parent_descriptor)
    finally:
        os.close(quarantine_descriptor)
    if (
        _stat_at(parent_descriptor, name) is not None
        or _stat_at(parent_descriptor, quarantine_name) is not None
    ):
        raise G06VerificationError(f"{label} cleanup was incomplete")


def _remove_derived_entry_at(
    build_descriptor: int,
    derived_name: str,
) -> Optional[G06VerificationError]:
    metadata = _stat_at(build_descriptor, derived_name)
    if metadata is None:
        return None
    if not stat.S_ISDIR(metadata.st_mode):
        _unlink_invalid_entry_at(
            build_descriptor,
            derived_name,
            metadata,
            label="invalid DerivedData root",
        )
        return G06VerificationError(
            "DerivedData root was linked or special and was removed"
        )
    _remove_real_directory_at(
        build_descriptor,
        derived_name,
        metadata,
        label="DerivedData root",
    )
    return None


def _remove_empty_build_at(
    run_descriptor: int,
    build_metadata: os.stat_result,
) -> Optional[G06VerificationError]:
    current = _stat_at(run_descriptor, "build")
    if current is not None and _identity(current) == _identity(build_metadata):
        try:
            os.rmdir("build", dir_fd=run_descriptor)
            os.fsync(run_descriptor)
        except OSError as error:
            return G06VerificationError(
                "DerivedData build parent remained nonempty"
            )
        return None
    if current is not None and not stat.S_ISDIR(current.st_mode):
        _unlink_invalid_entry_at(
            run_descriptor,
            "build",
            current,
            label="replacement DerivedData build parent",
        )
    for candidate in sorted(os.listdir(run_descriptor)):
        metadata = _stat_at(run_descriptor, candidate)
        if metadata is None or _identity(metadata) != _identity(build_metadata):
            continue
        try:
            os.rmdir(candidate, dir_fd=run_descriptor)
            os.fsync(run_descriptor)
        except OSError:
            return G06VerificationError(
                "moved DerivedData build parent remained nonempty"
            )
        break
    return G06VerificationError("DerivedData build parent identity changed")


def _open_build_at(
    run_descriptor: int,
) -> Tuple[Optional[int], Optional[os.stat_result], Optional[G06VerificationError]]:
    build_metadata = _stat_at(run_descriptor, "build")
    if build_metadata is None:
        return None, None, None
    if not stat.S_ISDIR(build_metadata.st_mode):
        _unlink_invalid_entry_at(
            run_descriptor,
            "build",
            build_metadata,
            label="invalid DerivedData build parent",
        )
        return (
            None,
            None,
            G06VerificationError(
                "DerivedData build parent was linked or special and was removed"
            ),
        )
    descriptor, opened = _open_real_directory_at(
        run_descriptor,
        "build",
        label="DerivedData build parent",
    )
    return descriptor, opened, None


def _remove_unbound_derived_data(
    *,
    run_root: Path,
    derived_data: Path,
    expected_relative_path: str,
) -> None:
    derived_name = _derived_data_name(expected_relative_path)
    if derived_data != run_root / "build" / derived_name:
        raise G06VerificationError("DerivedData cleanup path differs")
    run_descriptor, run_metadata = _open_real_directory_path(
        run_root,
        label="G06 run root",
    )
    build_descriptor: Optional[int] = None
    cleanup_error: Optional[G06VerificationError] = None
    try:
        build_descriptor, build_metadata, build_error = _open_build_at(
            run_descriptor
        )
        if build_error is not None:
            cleanup_error = build_error
        elif build_descriptor is not None and build_metadata is not None:
            try:
                cleanup_error = _remove_derived_entry_at(
                    build_descriptor,
                    derived_name,
                )
            except G06VerificationError as error:
                cleanup_error = error
            finally:
                os.close(build_descriptor)
                build_descriptor = None
            build_cleanup_error = _remove_empty_build_at(
                run_descriptor,
                build_metadata,
            )
            if cleanup_error is None:
                cleanup_error = build_cleanup_error
        _require_path_identity(
            run_root,
            run_metadata,
            label="G06 run root during DerivedData cleanup",
        )
    finally:
        if build_descriptor is not None:
            os.close(build_descriptor)
        os.close(run_descriptor)
    if cleanup_error is not None:
        raise cleanup_error


_RELEASE_PRODUCT_PARENT_COMPONENTS = (
    "Build",
    "Products",
    "Release",
    "Mirmir.app",
    "Contents",
    "MacOS",
)


def _snapshot_release_product_at(
    derived_descriptor: int,
) -> Tuple[Optional[bytes], Optional[int]]:
    descriptors = [os.dup(derived_descriptor)]
    try:
        current = descriptors[0]
        for component in _RELEASE_PRODUCT_PARENT_COMPONENTS:
            metadata = _stat_at(current, component)
            if metadata is None:
                return None, None
            child, _ = _open_real_directory_at(
                current,
                component,
                label=f"Release product parent {component}",
            )
            descriptors.append(child)
            current = child
        metadata = _stat_at(current, "Mirmir")
        if metadata is None:
            return None, None
        payload, product_metadata = _read_regular_at(
            current,
            "Mirmir",
            label="Release application product",
        )
        if product_metadata.st_mode & 0o111 != 0o111:
            raise G06VerificationError(
                "Release application product executable mode differs"
            )
        return payload, product_metadata.st_mode & 0o777
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _mkdir_open_real_at(
    parent_descriptor: int,
    name: str,
    *,
    label: str,
) -> Tuple[int, os.stat_result]:
    if _stat_at(parent_descriptor, name) is not None:
        raise G06VerificationError(f"{label} destination collides")
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise G06VerificationError(f"{label} could not be created") from error
    return _open_real_directory_at(
        parent_descriptor,
        name,
        label=label,
    )


def _recreate_release_product_at(
    *,
    run_descriptor: int,
    run_root: Path,
    run_metadata: os.stat_result,
    build_descriptor: int,
    build_metadata: os.stat_result,
    payload: bytes,
    mode: int,
) -> None:
    descriptors = [os.dup(build_descriptor)]
    relations: List[Tuple[int, str, os.stat_result, str]] = []
    try:
        current = descriptors[0]
        for component in (
            "release-derived-data",
            *_RELEASE_PRODUCT_PARENT_COMPONENTS,
        ):
            child, metadata = _mkdir_open_real_at(
                current,
                component,
                label=f"retained Release product parent {component}",
            )
            relations.append((current, component, metadata, component))
            descriptors.append(child)
            current = child
        _write_new_at(
            current,
            "Mirmir",
            payload,
            mode=mode,
            label="retained Release product",
        )
        for parent, name, metadata, label in relations:
            _require_entry_identity_at(
                parent,
                name,
                metadata,
                label=f"retained Release product parent {label}",
            )
        _require_entry_identity_at(
            run_descriptor,
            "build",
            build_metadata,
            label="retained Release product build parent",
        )
        _require_path_identity(
            run_root,
            run_metadata,
            label="G06 run root during Release product recreation",
        )
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _retain_release_product_descriptor_confined(
    *,
    run_root: Path,
) -> bool:
    run_descriptor, run_metadata = _open_real_directory_path(
        run_root,
        label="G06 run root",
    )
    build_descriptor: Optional[int] = None
    build_metadata: Optional[os.stat_result] = None
    try:
        build_descriptor, build_metadata, build_error = _open_build_at(
            run_descriptor
        )
        if build_error is not None:
            raise build_error
        if build_descriptor is None or build_metadata is None:
            return False
        derived_metadata = _stat_at(
            build_descriptor,
            "release-derived-data",
        )
        if derived_metadata is None:
            os.close(build_descriptor)
            build_descriptor = None
            cleanup_error = _remove_empty_build_at(
                run_descriptor,
                build_metadata,
            )
            if cleanup_error is not None:
                raise cleanup_error
            return False
        if not stat.S_ISDIR(derived_metadata.st_mode):
            invalid_error = _remove_derived_entry_at(
                build_descriptor,
                "release-derived-data",
            )
            os.close(build_descriptor)
            build_descriptor = None
            build_cleanup_error = _remove_empty_build_at(
                run_descriptor,
                build_metadata,
            )
            if invalid_error is not None:
                raise invalid_error
            if build_cleanup_error is not None:
                raise build_cleanup_error
            return False
        derived_descriptor, opened_derived = _open_real_directory_at(
            build_descriptor,
            "release-derived-data",
            label="Release DerivedData root",
        )
        snapshot_error: Optional[G06VerificationError] = None
        product_payload: Optional[bytes] = None
        product_mode: Optional[int] = None
        try:
            if _identity(opened_derived) != _identity(derived_metadata):
                raise G06VerificationError(
                    "Release DerivedData root identity changed"
                )
            try:
                product_payload, product_mode = _snapshot_release_product_at(
                    derived_descriptor
                )
            except G06VerificationError as error:
                snapshot_error = error
        finally:
            os.close(derived_descriptor)
        cleanup_error = _remove_derived_entry_at(
            build_descriptor,
            "release-derived-data",
        )
        if cleanup_error is not None:
            raise cleanup_error
        try:
            _require_entry_identity_at(
                run_descriptor,
                "build",
                build_metadata,
                label="Release product build parent",
            )
        except G06VerificationError:
            os.close(build_descriptor)
            build_descriptor = None
            _remove_empty_build_at(run_descriptor, build_metadata)
            raise
        if snapshot_error is not None or product_payload is None:
            os.close(build_descriptor)
            build_descriptor = None
            build_cleanup_error = _remove_empty_build_at(
                run_descriptor,
                build_metadata,
            )
            if snapshot_error is not None:
                raise snapshot_error
            if build_cleanup_error is not None:
                raise build_cleanup_error
            return False
        assert product_mode is not None
        try:
            _recreate_release_product_at(
                run_descriptor=run_descriptor,
                run_root=run_root,
                run_metadata=run_metadata,
                build_descriptor=build_descriptor,
                build_metadata=build_metadata,
                payload=product_payload,
                mode=product_mode,
            )
        except BaseException:
            try:
                _remove_derived_entry_at(
                    build_descriptor,
                    "release-derived-data",
                )
            finally:
                os.close(build_descriptor)
                build_descriptor = None
                _remove_empty_build_at(run_descriptor, build_metadata)
            raise
        _require_path_identity(
            run_root,
            run_metadata,
            label="G06 run root after Release product retention",
        )
        return True
    finally:
        if build_descriptor is not None:
            os.close(build_descriptor)
        os.close(run_descriptor)


def _retain_release_product_only(
    *,
    run_root: Path,
    derived_data: Path,
    executable: Path,
) -> bool:
    """Replace unbound DerivedData with its one byte-bound release product."""

    expected_derived = run_root / "build/release-derived-data"
    expected_executable = (
        expected_derived
        / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
    )
    if derived_data != expected_derived or executable != expected_executable:
        raise G06VerificationError("Release product retention paths differ")
    return _retain_release_product_descriptor_confined(
        run_root=run_root,
    )


def _write_json_new(path: Path, document: Mapping[str, object]) -> None:
    _write_new(path, canonical_json_bytes(document) + b"\n")


def _reject_duplicate_pairs(
    pairs: Sequence[Tuple[str, object]],
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise G06VerificationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _decode_json_object(payload: bytes, *, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                G06VerificationError(f"non-finite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise G06VerificationError(f"invalid JSON evidence: {label}") from error
    if not isinstance(value, dict):
        raise G06VerificationError("JSON evidence top level is not an object")
    return value


def _read_json(path: Path) -> Mapping[str, object]:
    return _decode_json_object(_read_regular(path), label=str(path))


def _g06_transaction_names(run_id: str) -> Mapping[str, str]:
    validated = _validate_run_id(run_id)
    return {
        "staging_name": f"{validated}.failed-pending",
        "partial_name": f".{validated}.partial",
        "final_name": validated,
        "failed_name": f"{validated}.failed",
        "marker_name": f".{validated}.g06-transaction.json",
    }


def _g06_transaction_document(
    *,
    run_id: str,
    token: str,
    output_metadata: os.stat_result,
    root_metadata: os.stat_result,
) -> Mapping[str, object]:
    names = _g06_transaction_names(run_id)
    if re.fullmatch(r"[0-9a-f]{32}", token) is None:
        raise G06VerificationError("G06 transaction token is invalid")
    document: Dict[str, object] = {
        "schema_version": G06_TRANSACTION_SCHEMA_VERSION,
        "artifact_kind": "g06_publication_transaction",
        "transaction_token": token,
        "created_utc": _utc_now(),
        "run_id": run_id,
        **names,
        "output_device": output_metadata.st_dev,
        "output_inode": output_metadata.st_ino,
        "root_device": root_metadata.st_dev,
        "root_inode": root_metadata.st_ino,
    }
    document["transaction_sha256"] = canonical_sha256(document)
    return document


def _validate_g06_transaction_document(
    document: Mapping[str, object],
    *,
    run_id: str,
    output_metadata: os.stat_result,
) -> Mapping[str, object]:
    names = _g06_transaction_names(run_id)
    required = {
        "schema_version",
        "artifact_kind",
        "transaction_token",
        "created_utc",
        "run_id",
        *names,
        "output_device",
        "output_inode",
        "root_device",
        "root_inode",
        "transaction_sha256",
    }
    unhashed = dict(document)
    declared_sha256 = unhashed.pop("transaction_sha256", None)
    if (
        set(document) != required
        or document.get("schema_version") != G06_TRANSACTION_SCHEMA_VERSION
        or document.get("artifact_kind") != "g06_publication_transaction"
        or document.get("run_id") != run_id
        or any(document.get(key) != value for key, value in names.items())
        or not isinstance(document.get("transaction_token"), str)
        or re.fullmatch(
            r"[0-9a-f]{32}",
            str(document["transaction_token"]),
        )
        is None
        or not isinstance(document.get("created_utc"), str)
        or re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:"
            r"[0-9]{2}(?:\.[0-9]{1,6})?Z",
            str(document["created_utc"]),
        )
        is None
        or document.get("output_device") != output_metadata.st_dev
        or document.get("output_inode") != output_metadata.st_ino
        or not isinstance(document.get("root_device"), int)
        or isinstance(document.get("root_device"), bool)
        or int(document["root_device"]) < 0
        or not isinstance(document.get("root_inode"), int)
        or isinstance(document.get("root_inode"), bool)
        or int(document["root_inode"]) < 1
        or not isinstance(declared_sha256, str)
        or declared_sha256 != canonical_sha256(unhashed)
    ):
        raise G06VerificationError("G06 transaction record is invalid")
    return dict(document)


def _read_g06_transaction_at(
    parent_descriptor: int,
    name: str,
    *,
    run_id: str,
    output_metadata: os.stat_result,
    label: str,
) -> Tuple[Mapping[str, object], os.stat_result]:
    payload, metadata = _read_regular_at(
        parent_descriptor,
        name,
        label=label,
    )
    document = _decode_json_object(payload, label=label)
    if payload != canonical_json_bytes(document) + b"\n":
        raise G06VerificationError(f"{label} is not canonical JSON")
    return (
        _validate_g06_transaction_document(
            document,
            run_id=run_id,
            output_metadata=output_metadata,
        ),
        metadata,
    )


def _g06_transaction_root_identity(
    document: Mapping[str, object],
) -> Tuple[int, int]:
    return int(document["root_device"]), int(document["root_inode"])


def _g06_owned_root_name_at(
    parent_descriptor: int,
    expected_identity: Tuple[int, int],
) -> Optional[str]:
    try:
        names = sorted(os.listdir(parent_descriptor))
    except OSError as error:
        raise G06VerificationError(
            "G06 transaction namespace could not be enumerated"
        ) from error
    matches = []
    for name in names:
        metadata = _stat_at(parent_descriptor, name)
        if (
            metadata is not None
            and stat.S_ISDIR(metadata.st_mode)
            and _identity(metadata) == expected_identity
        ):
            matches.append(name)
    if len(matches) > 1:
        raise G06VerificationError(
            "G06 transaction root has multiple namespace entries"
        )
    return matches[0] if matches else None


def _g06_failure_record(
    *,
    document: Mapping[str, object],
    action: str,
    source_name: str,
    cause: Optional[BaseException],
) -> Mapping[str, object]:
    record: Dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "g06_failure_recovery",
        "recorded_utc": _utc_now(),
        "run_id": document["run_id"],
        "transaction_token": document["transaction_token"],
        "root_device": document["root_device"],
        "root_inode": document["root_inode"],
        "action": action,
        "source_name": source_name,
        "cause_type": type(cause).__name__ if cause is not None else None,
        "cause_message": str(cause) if cause is not None else None,
        "cause_traceback": (
            "".join(
                traceback.format_exception(
                    type(cause),
                    cause,
                    cause.__traceback__,
                )
            )
            if cause is not None
            else None
        ),
    }
    record["record_sha256"] = canonical_sha256(record)
    return record


def _write_g06_failure_record_at(
    root_descriptor: int,
    *,
    document: Mapping[str, object],
    action: str,
    source_name: str,
    cause: Optional[BaseException],
) -> None:
    token = str(document["transaction_token"])
    name = f"g06-failure-recovery-{token}.json"
    record = _g06_failure_record(
        document=document,
        action=action,
        source_name=source_name,
        cause=cause,
    )
    payload = canonical_json_bytes(record) + b"\n"
    if _stat_at(root_descriptor, name) is not None:
        existing, _ = _read_regular_at(
            root_descriptor,
            name,
            label="G06 failure recovery record",
        )
        existing_document = _decode_json_object(
            existing,
            label="G06 failure recovery record",
        )
        unhashed = dict(existing_document)
        declared_sha256 = unhashed.pop("record_sha256", None)
        if (
            existing != canonical_json_bytes(existing_document) + b"\n"
            or existing_document.get("artifact_kind")
            != "g06_failure_recovery"
            or existing_document.get("run_id") != document["run_id"]
            or existing_document.get("transaction_token")
            != document["transaction_token"]
            or existing_document.get("root_device")
            != document["root_device"]
            or existing_document.get("root_inode") != document["root_inode"]
            or declared_sha256 != canonical_sha256(unhashed)
        ):
            raise G06VerificationError(
                "G06 failure recovery record changed"
            )
        return
    _write_new_at(
        root_descriptor,
        name,
        payload,
        mode=0o600,
        label="G06 failure recovery record",
    )


def _archive_owned_g06_root_at(
    parent_descriptor: int,
    *,
    document: Mapping[str, object],
    source_name: str,
    action: str,
    cause: Optional[BaseException],
) -> str:
    expected_identity = _g06_transaction_root_identity(document)
    current = _stat_at(parent_descriptor, source_name)
    if (
        current is None
        or not stat.S_ISDIR(current.st_mode)
        or _identity(current) != expected_identity
    ):
        raise G06VerificationError(
            "owned G06 transaction root changed before failure publication"
        )
    root_descriptor, opened = _open_real_directory_at(
        parent_descriptor,
        source_name,
        label="owned G06 transaction root",
    )
    try:
        if _identity(opened) != expected_identity:
            raise G06VerificationError(
                "owned G06 transaction descriptor identity changed"
            )
        _prepare_g06_root_for_failure(root_descriptor)
        _write_g06_failure_record_at(
            root_descriptor,
            document=document,
            action=action,
            source_name=source_name,
            cause=cause,
        )
        last_error: Optional[BaseException] = None
        token = str(document["transaction_token"])
        run_id = str(document["run_id"])
        for ordinal in range(1, 9):
            destination_name = (
                f"{run_id}.failed-recovery-{token}-{ordinal}"
            )
            if _stat_at(parent_descriptor, destination_name) is not None:
                continue
            try:
                _rename_exclusive_at(
                    parent_descriptor,
                    source_name,
                    parent_descriptor,
                    destination_name,
                )
            except BaseException as error:
                last_error = error
                source_after = _stat_at(parent_descriptor, source_name)
                destination_after = _stat_at(
                    parent_descriptor,
                    destination_name,
                )
                if (
                    source_after is None
                    and destination_after is not None
                    and stat.S_ISDIR(destination_after.st_mode)
                    and _identity(destination_after) == expected_identity
                ):
                    os.fsync(parent_descriptor)
                    return destination_name
                if (
                    source_after is None
                    or not stat.S_ISDIR(source_after.st_mode)
                    or _identity(source_after) != expected_identity
                ):
                    raise G06VerificationError(
                        "owned G06 transaction root changed during failure publication"
                    ) from error
                continue
            os.fsync(parent_descriptor)
            destination = _stat_at(parent_descriptor, destination_name)
            if (
                destination is None
                or not stat.S_ISDIR(destination.st_mode)
                or _identity(destination) != expected_identity
                or _stat_at(parent_descriptor, source_name) is not None
            ):
                raise G06VerificationError(
                    "G06 failure publication identity changed"
                )
            return destination_name
        pending_name = str(document["staging_name"])
        if (
            source_name != pending_name
            and _stat_at(parent_descriptor, pending_name) is None
        ):
            try:
                _rename_exclusive_at(
                    parent_descriptor,
                    source_name,
                    parent_descriptor,
                    pending_name,
                )
            except BaseException as pending_error:
                last_error = pending_error
            else:
                os.fsync(parent_descriptor)
                pending = _stat_at(parent_descriptor, pending_name)
                if (
                    pending is None
                    or not stat.S_ISDIR(pending.st_mode)
                    or _identity(pending) != expected_identity
                    or _stat_at(parent_descriptor, source_name) is not None
                ):
                    raise G06VerificationError(
                        "G06 pending failure publication identity changed"
                    )
                raise G06VerificationError(
                    "G06 failure archive remained in authenticated pending state"
                ) from last_error
        raise G06VerificationError(
            "G06 failure publication could not archive the owned root"
        ) from last_error
    finally:
        os.close(root_descriptor)


def _remove_g06_transaction_marker_at(
    parent_descriptor: int,
    *,
    marker_name: str,
    expected: Optional[os.stat_result],
    allow_absent: bool = False,
) -> None:
    current = _stat_at(parent_descriptor, marker_name)
    if current is None:
        if allow_absent:
            return
        raise G06VerificationError("G06 transaction marker is absent")
    if (
        expected is None
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
        or _identity(current) != _identity(expected)
    ):
        raise G06VerificationError(
            "G06 transaction marker changed before removal"
        )
    try:
        os.unlink(marker_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise G06VerificationError(
            "G06 transaction marker could not be removed"
        ) from error
    if _stat_at(parent_descriptor, marker_name) is not None:
        raise G06VerificationError(
            "G06 transaction marker survived removal"
        )


def _g06_root_token_at(
    parent_descriptor: int,
    source_name: str,
    *,
    run_id: str,
    output_metadata: os.stat_result,
) -> Optional[Mapping[str, object]]:
    root_descriptor, _ = _open_real_directory_at(
        parent_descriptor,
        source_name,
        label="G06 transaction root",
    )
    try:
        token_name = G06_TRANSACTION_TOKEN_NAME
        if _stat_at(root_descriptor, token_name) is None:
            staged = _g06_staged_control_at(
                root_descriptor,
                kind="root-token",
                run_id=run_id,
                output_metadata=output_metadata,
            )
            if staged is None:
                return None
            token_name, document, _ = staged
            return document
        document, _ = _read_g06_transaction_at(
            root_descriptor,
            token_name,
            run_id=run_id,
            output_metadata=output_metadata,
            label="G06 in-root transaction token",
        )
        return document
    finally:
        os.close(root_descriptor)


def _g06_staged_control_at(
    parent_descriptor: int,
    *,
    kind: str,
    run_id: str,
    output_metadata: os.stat_result,
) -> Optional[Tuple[str, Mapping[str, object], os.stat_result]]:
    if kind not in {"root-token", "sibling-marker"}:
        raise G06VerificationError("G06 staged control kind is invalid")
    pattern = re.compile(
        rf"^\.{re.escape(run_id)}\.g06-{re.escape(kind)}-"
        r"([0-9a-f]{32})\.tmp$"
    )
    try:
        names = sorted(os.listdir(parent_descriptor))
    except OSError as error:
        raise G06VerificationError(
            "G06 staged control namespace could not be enumerated"
        ) from error
    matches = [(name, pattern.fullmatch(name)) for name in names]
    matches = [(name, match) for name, match in matches if match is not None]
    if not matches:
        return None
    if len(matches) != 1:
        raise G06VerificationError("G06 staged control set is ambiguous")
    name, match = matches[0]
    if match is None:
        raise G06VerificationError("G06 staged control match disappeared")
    document, metadata = _read_g06_transaction_at(
        parent_descriptor,
        name,
        run_id=run_id,
        output_metadata=output_metadata,
        label=f"G06 staged {kind} control",
    )
    if document.get("transaction_token") != match.group(1):
        raise G06VerificationError("G06 staged control token differs")
    return name, document, metadata


def _remove_g06_staged_control_at(
    parent_descriptor: int,
    *,
    name: str,
    expected: os.stat_result,
) -> None:
    _require_entry_identity_at(
        parent_descriptor,
        name,
        expected,
        label="G06 staged control record",
    )
    try:
        os.unlink(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError as error:
        raise G06VerificationError(
            "G06 staged control record could not be removed"
        ) from error


def _recover_g06_transaction(
    *,
    output_root: Path,
    run_id: str,
) -> Optional[Path]:
    names = _g06_transaction_names(run_id)
    parent_descriptor, output_metadata = _open_real_directory_path(
        output_root,
        label="G06 output root",
    )
    try:
        marker_metadata = _stat_at(
            parent_descriptor,
            names["marker_name"],
        )
        staging_metadata = _stat_at(
            parent_descriptor,
            names["staging_name"],
        )
        staged_sibling = _g06_staged_control_at(
            parent_descriptor,
            kind="sibling-marker",
            run_id=run_id,
            output_metadata=output_metadata,
        )
        if (
            marker_metadata is None
            and staging_metadata is None
            and staged_sibling is None
        ):
            return None

        if marker_metadata is not None and staged_sibling is not None:
            raise G06VerificationError(
                "canonical and staged G06 sibling markers coexist"
            )

        if marker_metadata is not None:
            document, opened_marker = _read_g06_transaction_at(
                parent_descriptor,
                names["marker_name"],
                run_id=run_id,
                output_metadata=output_metadata,
                label="G06 sibling transaction marker",
            )
            source_name = _g06_owned_root_name_at(
                parent_descriptor,
                _g06_transaction_root_identity(document),
            )
            if source_name is None:
                raise G06VerificationError(
                    "marker-bound G06 transaction root is undiscoverable"
                )
            token_document = _g06_root_token_at(
                parent_descriptor,
                source_name,
                run_id=run_id,
                output_metadata=output_metadata,
            )
            if token_document is not None and token_document != document:
                raise G06VerificationError(
                    "G06 sibling marker and in-root token differ"
                )
            archive_name = _archive_owned_g06_root_at(
                parent_descriptor,
                document=document,
                source_name=source_name,
                action="recovered_interrupted_transaction",
                cause=None,
            )
            _remove_g06_transaction_marker_at(
                parent_descriptor,
                marker_name=names["marker_name"],
                expected=opened_marker,
            )
        else:
            if (
                staging_metadata is None
                or not stat.S_ISDIR(staging_metadata.st_mode)
            ):
                raise G06VerificationError(
                    "pending G06 staging entry is linked or special"
                )
            token_document = _g06_root_token_at(
                parent_descriptor,
                names["staging_name"],
                run_id=run_id,
                output_metadata=output_metadata,
            )
            if token_document is None:
                raise G06VerificationError(
                    "pending G06 staging root is unauthenticated"
                )
            if staged_sibling is not None and staged_sibling[1] != token_document:
                raise G06VerificationError(
                    "G06 staged sibling marker and in-root token differ"
                )
            if _identity(staging_metadata) != _g06_transaction_root_identity(
                token_document
            ):
                raise G06VerificationError(
                    "pending G06 staging root identity differs from its token"
                )
            archive_name = _archive_owned_g06_root_at(
                parent_descriptor,
                document=token_document,
                source_name=names["staging_name"],
                action="recovered_pre_marker_transaction",
                cause=None,
            )
            if staged_sibling is not None:
                _remove_g06_staged_control_at(
                    parent_descriptor,
                    name=staged_sibling[0],
                    expected=staged_sibling[2],
                )
        _require_path_identity(
            output_root,
            output_metadata,
            label="G06 output root after recovery",
        )
        if _stat_at(parent_descriptor, names["partial_name"]) is not None:
            raise G06VerificationError(
                "recognized G06 partial survived transaction recovery"
            )
        return output_root / archive_name
    finally:
        os.close(parent_descriptor)


def _begin_g06_transaction(
    *,
    output_root: Path,
    run_id: str,
) -> _G06PublicationTransaction:
    names = _g06_transaction_names(run_id)
    parent_descriptor, output_metadata = _open_real_directory_path(
        output_root,
        label="G06 output root",
    )
    token = uuid.uuid4().hex
    root_metadata: Optional[os.stat_result] = None
    marker_metadata: Optional[os.stat_result] = None
    document: Optional[Mapping[str, object]] = None
    try:
        if any(
            _stat_at(parent_descriptor, name) is not None
            for name in names.values()
        ):
            raise G06VerificationError(
                "G06 transaction namespace already exists"
            )
        try:
            os.mkdir(
                names["staging_name"],
                mode=0o700,
                dir_fd=parent_descriptor,
            )
            root_metadata = _stat_at(
                parent_descriptor,
                names["staging_name"],
            )
            if (
                root_metadata is None
                or not stat.S_ISDIR(root_metadata.st_mode)
            ):
                raise G06VerificationError(
                    "pending G06 staging root identity is invalid"
                )
            os.fsync(parent_descriptor)
        except (OSError, G06VerificationError) as error:
            raise G06VerificationError(
                "pending G06 staging root could not be created"
            ) from error
        root_descriptor, opened_root = _open_real_directory_at(
            parent_descriptor,
            names["staging_name"],
            label="pending G06 staging root",
        )
        try:
            if _identity(opened_root) != _identity(root_metadata):
                raise G06VerificationError(
                    "pending G06 staging root identity changed"
                )
            document = _g06_transaction_document(
                run_id=run_id,
                token=token,
                output_metadata=output_metadata,
                root_metadata=root_metadata,
            )
            payload = canonical_json_bytes(document) + b"\n"
            _write_new_control_at(
                root_descriptor,
                G06_TRANSACTION_TOKEN_NAME,
                payload,
                mode=0o600,
                label="G06 in-root transaction token",
                token=token,
                kind="root-token",
                run_id=run_id,
            )
            marker_metadata = _write_new_control_at(
                parent_descriptor,
                names["marker_name"],
                payload,
                mode=0o600,
                label="G06 sibling transaction marker",
                token=token,
                kind="sibling-marker",
                run_id=run_id,
            )
            _rename_exclusive_at(
                parent_descriptor,
                names["staging_name"],
                parent_descriptor,
                names["partial_name"],
            )
            os.fsync(parent_descriptor)
            _require_entry_identity_at(
                parent_descriptor,
                names["partial_name"],
                root_metadata,
                label="recognized G06 partial root",
            )
            os.unlink(G06_TRANSACTION_TOKEN_NAME, dir_fd=root_descriptor)
            os.fsync(root_descriptor)
            if _stat_at(root_descriptor, G06_TRANSACTION_TOKEN_NAME) is not None:
                raise G06VerificationError(
                    "G06 in-root transaction token survived activation"
                )
            _require_path_identity(
                output_root,
                output_metadata,
                label="G06 output root after transaction activation",
            )
        finally:
            os.close(root_descriptor)
        return _G06PublicationTransaction(
            output_root=output_root,
            run_id=run_id,
            token=token,
            staging_name=names["staging_name"],
            partial_name=names["partial_name"],
            final_name=names["final_name"],
            failed_name=names["failed_name"],
            marker_name=names["marker_name"],
            root_metadata=root_metadata,
            marker_metadata=marker_metadata,
            document=document,
        )
    except BaseException as primary:
        if root_metadata is not None:
            if document is None:
                document = _g06_transaction_document(
                    run_id=run_id,
                    token=token,
                    output_metadata=output_metadata,
                    root_metadata=root_metadata,
                )
            try:
                source_name = _g06_owned_root_name_at(
                    parent_descriptor,
                    _identity(root_metadata),
                )
                if source_name is None:
                    raise G06VerificationError(
                        "owned G06 setup root is undiscoverable"
                    )
                _archive_owned_g06_root_at(
                    parent_descriptor,
                    document=document,
                    source_name=source_name,
                    action="transaction_setup_failed",
                    cause=primary,
                )
                _remove_g06_transaction_marker_at(
                    parent_descriptor,
                    marker_name=names["marker_name"],
                    expected=marker_metadata,
                    allow_absent=True,
                )
            except BaseException as cleanup:
                raise G06VerificationError(
                    f"G06 transaction setup failed; failure publication failed: {cleanup}"
                ) from primary
        raise
    finally:
        os.close(parent_descriptor)


def _publish_g06_exception_failure(
    transaction: _G06PublicationTransaction,
    primary: BaseException,
) -> Path:
    parent_descriptor, output_metadata = _open_real_directory_path(
        transaction.output_root,
        label="G06 output root",
    )
    try:
        if (
            output_metadata.st_dev != transaction.document["output_device"]
            or output_metadata.st_ino != transaction.document["output_inode"]
        ):
            raise G06VerificationError(
                "G06 output root identity changed during failure publication"
            )
        source_name = _g06_owned_root_name_at(
            parent_descriptor,
            _identity(transaction.root_metadata),
        )
        if source_name is None:
            raise G06VerificationError(
                "owned G06 transaction root is undiscoverable after failure"
            )
        archive_name = _archive_owned_g06_root_at(
            parent_descriptor,
            document=transaction.document,
            source_name=source_name,
            action="in_process_failure_published",
            cause=primary,
        )
        _remove_g06_transaction_marker_at(
            parent_descriptor,
            marker_name=transaction.marker_name,
            expected=transaction.marker_metadata,
            allow_absent=True,
        )
        if _stat_at(parent_descriptor, transaction.partial_name) is not None:
            raise G06VerificationError(
                "recognized G06 partial survived failure publication"
            )
        return transaction.output_root / archive_name
    finally:
        os.close(parent_descriptor)


def _commit_g06_transaction(
    transaction: _G06PublicationTransaction,
    *,
    destination: Path,
    verify_committed: Callable[[], None],
) -> None:
    parent_descriptor, output_metadata = _open_real_directory_path(
        transaction.output_root,
        label="G06 output root",
    )
    try:
        if (
            output_metadata.st_dev != transaction.document["output_device"]
            or output_metadata.st_ino != transaction.document["output_inode"]
        ):
            raise G06VerificationError(
                "G06 output root identity changed during transaction commit"
            )
        if destination.name not in {
            transaction.final_name,
            transaction.failed_name,
        }:
            raise G06VerificationError(
                "G06 transaction destination is not canonical"
            )
        _require_entry_identity_at(
            parent_descriptor,
            destination.name,
            transaction.root_metadata,
            label="committed G06 publication root",
        )
        root_descriptor, opened_root = _open_real_directory_at(
            parent_descriptor,
            destination.name,
            label="committed G06 publication root",
        )
        try:
            if _identity(opened_root) != _identity(transaction.root_metadata):
                raise G06VerificationError(
                    "committed G06 root changed while pinning"
                )
            _freeze_g06_tree_at(root_descriptor)
            verify_committed()
            _require_entry_identity_at(
                parent_descriptor,
                destination.name,
                transaction.root_metadata,
                label="post-freeze G06 publication root",
            )
            _require_g06_tree_frozen_at(root_descriptor)
        finally:
            os.close(root_descriptor)
        _remove_g06_transaction_marker_at(
            parent_descriptor,
            marker_name=transaction.marker_name,
            expected=transaction.marker_metadata,
        )
        _require_path_identity(
            transaction.output_root,
            output_metadata,
            label="G06 output root after transaction commit",
        )
    finally:
        os.close(parent_descriptor)


def _repository_artifacts_ash_directory(
    repository_root: Path,
    value: Path,
) -> Tuple[Path, PurePosixPath]:
    path = Path(os.path.abspath(value))
    try:
        relative = path.relative_to(repository_root)
    except ValueError as error:
        raise G06VerificationError(
            "native runtime evidence root escapes the repository"
        ) from error
    relative_posix = PurePosixPath(relative.as_posix())
    if (
        len(relative_posix.parts) < 3
        or relative_posix.parts[:2] != ("Artifacts", "ASH")
    ):
        raise G06VerificationError(
            "native runtime evidence root is outside repository Artifacts/ASH"
        )
    current = repository_root
    for component in relative_posix.parts:
        current /= component
        try:
            metadata = os.stat(current, follow_symlinks=False)
        except OSError as error:
            raise G06VerificationError(
                f"native runtime evidence ancestor is absent: {current}"
            ) from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise G06VerificationError(
                "native runtime evidence has a symbolic or non-directory ancestor"
            )
    return path, relative_posix


def _git_head(repository_root: Path) -> str:
    completed = subprocess.run(
        ("git", "-C", str(repository_root), "rev-parse", "--verify", "HEAD"),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    value = completed.stdout.decode("ascii", errors="replace").strip()
    if completed.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise G06VerificationError("repository HEAD is unavailable")
    return value


def _native_runtime_source_provenance(
    verified: VerifiedRuntimeCorrection,
    *,
    repository_root: Path,
    repository_relative_root: PurePosixPath,
) -> Mapping[str, object]:
    manifest = verified.manifest
    project_commit = manifest.get("project_commit")
    repository_state = manifest.get("repository_state")
    if not isinstance(repository_state, dict):
        raise G06VerificationError(
            "native runtime manifest repository state is absent"
        )
    empty_sha256 = hashlib.sha256(b"").hexdigest()
    empty_records_sha256 = canonical_sha256([])
    expected_dirty_state_sha256 = canonical_sha256(
        {
            "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
            "artifact_pathspec_exclusion": "Artifacts/**",
            "project_commit": project_commit,
            "tracked_diff_sha256": empty_sha256,
            "tracked_diff_size_bytes": 0,
            "ordered_untracked_files": [],
        }
    )
    if (
        manifest.get("root") != repository_relative_root.as_posix()
        or manifest.get("holdout_accessed") is not False
        or manifest.get("working_tree_clean") is not True
        or project_commit != _git_head(repository_root)
        or repository_state
        != {
            "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
            "artifact_pathspec_exclusion": "Artifacts/**",
            "project_commit": project_commit,
            "tracked_diff_sha256": empty_sha256,
            "tracked_diff_size_bytes": 0,
            "untracked_file_count": 0,
            "ordered_untracked_files_sha256": empty_records_sha256,
            "dirty_state_sha256": expected_dirty_state_sha256,
        }
        or manifest.get("dirty_state_sha256") != expected_dirty_state_sha256
    ):
        raise G06VerificationError(
            "native runtime manifest does not bind the current clean repository"
        )
    current_repository_state, current_working_tree_clean = (
        runtime_correction_repository_state()
    )
    if (
        current_working_tree_clean is not True
        or current_repository_state != repository_state
    ):
        raise G06VerificationError(
            "current repository state differs from the clean native runtime source"
        )
    records = manifest.get("artifacts")
    if not isinstance(records, list):
        raise G06VerificationError("native runtime artifact records are absent")
    benchmark_records = [
        record
        for record in records
        if isinstance(record, dict)
        and record.get("path") == "native-aggregate-benchmark.json"
    ]
    if len(benchmark_records) != 1:
        raise G06VerificationError(
            "native runtime benchmark record is absent or duplicated"
        )
    benchmark_record = benchmark_records[0]
    if (
        benchmark_record.get("producer") != "pytest native aggregate benchmark"
        or benchmark_record.get("gate_ids") != ["P06", "G06"]
    ):
        raise G06VerificationError(
            "native runtime benchmark record semantics differ"
        )
    file_payloads = dict(verified.files)
    benchmark_payload = file_payloads.get("native-aggregate-benchmark.json")
    if benchmark_payload is None or (
        benchmark_record.get("sha256")
        != hashlib.sha256(benchmark_payload).hexdigest()
        or benchmark_record.get("size_bytes") != len(benchmark_payload)
    ):
        raise G06VerificationError("native runtime benchmark bytes differ")
    benchmark = _decode_json_object(
        benchmark_payload,
        label="native aggregate benchmark",
    )
    if benchmark_payload != canonical_json_bytes(benchmark) + b"\n":
        raise G06VerificationError(
            "native aggregate benchmark bytes are not canonical"
        )
    try:
        validate_schema(benchmark, NATIVE_BENCHMARK_SCHEMA_PATH)
    except ValueError as error:
        raise G06VerificationError(
            f"native aggregate benchmark schema validation failed: {error}"
        ) from error
    if benchmark.get("schema_binding") != _benchmark_schema_binding():
        raise G06VerificationError(
            "native aggregate benchmark schema binding differs"
        )
    benchmark_unhashed = dict(benchmark)
    benchmark_evidence_sha256 = benchmark_unhashed.pop(
        "evidence_sha256",
        None,
    )
    run_identity = benchmark.get("run_identity")
    if not isinstance(run_identity, dict):
        raise G06VerificationError(
            "native aggregate benchmark run identity is absent"
        )
    benchmark_repository_state = run_identity.get("repository_state")
    final_bundle_linkage = run_identity.get("final_bundle_linkage")
    expected_final_bundle_linkage = {
        "required_artifact_manifest_kind": manifest.get("artifact_kind"),
        "required_manifest_run_id": manifest.get("run_id"),
        "required_binding": NATIVE_BENCHMARK_REQUIRED_BINDING,
        "finalizer": RUNTIME_FINALIZER_REPOSITORY_PATH,
    }
    if (
        benchmark.get("artifact_kind")
        != "p06_control_aggregate_cache_native_benchmark"
        or benchmark.get("native_swift_execution") is not True
        or benchmark.get("production_corpus_accessed") is not False
        or benchmark.get("holdout_accessed") is not False
        or benchmark_evidence_sha256 != canonical_sha256(benchmark_unhashed)
        or run_identity.get("run_id") != manifest.get("run_id")
        or not isinstance(benchmark_repository_state, dict)
        or benchmark_repository_state.get("head_commit") != project_commit
        or benchmark_repository_state.get("is_dirty") is not False
        or final_bundle_linkage != expected_final_bundle_linkage
    ):
        raise G06VerificationError(
            "native aggregate benchmark finalized provenance differs"
        )
    return {
        "repository_root": repository_relative_root.as_posix(),
        "manifest_file_sha256": verified.manifest_file_sha256,
        "manifest_sha256": manifest["manifest_sha256"],
        "run_id": manifest["run_id"],
        "project_commit": project_commit,
        "benchmark_record": dict(benchmark_record),
        "manifest_schema": _repository_source_binding(
            RUNTIME_MANIFEST_SCHEMA_PATH
        ),
    }


def _copy_runtime_evidence_snapshot(
    verified: VerifiedRuntimeCorrection,
    *,
    destination: Path,
) -> None:
    if destination.exists() or destination.is_symlink():
        raise G06VerificationError(
            "native runtime evidence copy destination already exists"
        )
    destination.mkdir(parents=True, mode=0o700)
    for relative, payload in verified.files:
        safe = _safe_relative(relative)
        _write_new(destination.joinpath(*safe.parts), payload)


def _file_binding(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
) -> Mapping[str, object]:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise G06VerificationError(f"file artifact is absent: {path}") from error
    payload = _read_regular(path)
    current = os.stat(path, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
        or _identity(current) != _identity(before)
        or current.st_mode != before.st_mode
    ):
        raise G06VerificationError("file artifact mode or identity changed")
    artifact_id = path.relative_to(run_root).as_posix()
    _safe_relative(artifact_id)
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "file_sha256",
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
        "file_count": 1,
        "executable_mode_bits": before.st_mode & 0o111,
    }


def _tree_manifest_entries(path: Path) -> List[Mapping[str, object]]:
    if path.is_symlink() or not path.is_dir():
        raise G06VerificationError(f"tree evidence is absent or symbolic: {path}")
    entries: List[Mapping[str, object]] = []
    for current, directories, filenames in os.walk(
        path,
        onerror=_raise_tree_walk_error,
        followlinks=False,
    ):
        current_path = Path(current)
        directories.sort()
        for directory in directories:
            child = current_path / directory
            if child.is_symlink():
                raise G06VerificationError("tree evidence contains a symbolic directory")
            entries.append(
                {
                    "path": child.relative_to(path).as_posix(),
                    "entry_kind": "directory",
                    "size_bytes": 0,
                }
            )
        for filename in sorted(filenames):
            child = current_path / filename
            if child.is_symlink():
                raise G06VerificationError("tree evidence contains a symbolic file")
            payload = _read_regular(child)
            entries.append(
                {
                    "path": child.relative_to(path).as_posix(),
                    "entry_kind": "regular_file",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
    entries.sort(key=lambda row: str(row["path"]))
    if not entries:
        raise G06VerificationError("tree evidence is empty")
    file_entries = [row for row in entries if row["entry_kind"] == "regular_file"]
    if not file_entries:
        raise G06VerificationError("tree evidence contains no regular files")
    return entries


def _tree_binding_from_entries(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
    entries: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    file_entries = [row for row in entries if row["entry_kind"] == "regular_file"]
    artifact_id = path.relative_to(run_root).as_posix()
    _safe_relative(artifact_id)
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "canonical_tree_manifest_sha256",
        "sha256": canonical_sha256(entries),
        "size_bytes": sum(int(row["size_bytes"]) for row in file_entries),
        "file_count": len(file_entries),
    }


def _tree_binding_and_entries(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
) -> Tuple[Mapping[str, object], Tuple[Mapping[str, object], ...]]:
    entries = _tree_manifest_entries(path)
    return (
        _tree_binding_from_entries(
            path,
            run_root=run_root,
            artifact_kind=artifact_kind,
            entries=entries,
        ),
        tuple(entries),
    )


def _tree_binding(
    path: Path,
    *,
    run_root: Path,
    artifact_kind: str,
) -> Mapping[str, object]:
    binding, _ = _tree_binding_and_entries(
        path,
        run_root=run_root,
        artifact_kind=artifact_kind,
    )
    return binding


def _run_tree_entry_kinds(root: Path) -> Mapping[str, str]:
    root_descriptor, root_metadata = _open_real_directory_path(
        root,
        label="G06 closure root",
    )
    entries: Dict[str, str] = {}
    try:
        for directory, directory_names, file_names, descriptor in os.fwalk(
            ".",
            topdown=True,
            onerror=_raise_tree_walk_error,
            follow_symlinks=False,
            dir_fd=root_descriptor,
        ):
            directory_names.sort()
            file_names.sort()
            relative_directory = PurePosixPath(directory).as_posix()
            if relative_directory == ".":
                relative_directory = ""
            if relative_directory:
                entries[relative_directory] = "directory"
            for name in directory_names:
                metadata = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISDIR(metadata.st_mode):
                    raise G06VerificationError(
                        "G06 closure contains a symbolic or special directory"
                    )
            for name in file_names:
                metadata = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise G06VerificationError(
                        "G06 closure contains a non-regular or multiply linked file"
                    )
                relative = (
                    PurePosixPath(relative_directory) / name
                    if relative_directory
                    else PurePosixPath(name)
                ).as_posix()
                entries[relative] = "regular_file"
        _require_path_identity(
            root,
            root_metadata,
            label="G06 closure root",
        )
    finally:
        os.close(root_descriptor)
    return entries


def _declare_run_closure_entry(
    closure: Dict[str, str],
    path: str,
    entry_kind: str,
) -> None:
    relative = _safe_relative(path)
    normalized_kind = (
        "regular_file" if entry_kind == "regular_file" else "directory"
    )
    existing = closure.get(relative.as_posix())
    if existing is not None and existing != normalized_kind:
        raise G06VerificationError(
            f"G06 declared closure type conflicts: {relative.as_posix()}"
        )
    closure[relative.as_posix()] = normalized_kind
    for parent in relative.parents:
        if parent == PurePosixPath("."):
            continue
        parent_path = parent.as_posix()
        parent_existing = closure.get(parent_path)
        if parent_existing is not None and parent_existing != "directory":
            raise G06VerificationError(
                f"G06 declared closure parent conflicts: {parent_path}"
            )
        closure[parent_path] = "directory"


def _repository_source_binding(path: Path) -> Mapping[str, object]:
    payload = _read_regular(path)
    try:
        relative = path.resolve(strict=True).relative_to(REPOSITORY_ROOT).as_posix()
    except ValueError as error:
        raise G06VerificationError("verifier source escapes the repository") from error
    return {
        "repository_path": relative,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def _benchmark_schema_binding() -> Mapping[str, object]:
    payload = _read_regular(NATIVE_BENCHMARK_SCHEMA_PATH)
    return {
        "path": NATIVE_BENCHMARK_SCHEMA_REPOSITORY_PATH,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size_bytes": len(payload),
    }


def parse_unittest_output(text: str) -> Mapping[str, object]:
    matches = list(re.finditer(r"(?m)^Ran ([0-9]+) tests? in .+$", text))
    terminal = next(
        (line.strip() for line in reversed(text.splitlines()) if line.strip()),
        "",
    )
    if (
        len(matches) != 1
        or terminal != "OK"
        or len(re.findall(r"(?m)^OK$", text)) != 1
    ):
        raise G06VerificationError(
            "unittest log lacks an all-passed terminal summary"
        )
    if re.search(r"(?m)^(?:FAILED(?: |$)|OK \()", text):
        raise G06VerificationError("unittest log reports failure")
    total = int(matches[0].group(1))
    if total <= 0:
        raise G06VerificationError("unittest executed-test count is zero")
    return {
        "test_count": total,
        "passed": total,
        "failed": 0,
        "errors": 0,
        "skipped": 0,
        "expected_failures": 0,
        "unexpected_successes": 0,
        "terminal_status": "passed",
    }


def parse_pytest_output(text: str) -> Mapping[str, object]:
    nonempty_lines = [line.strip() for line in text.splitlines() if line.strip()]
    terminal = nonempty_lines[-1] if nonempty_lines else ""
    match = re.fullmatch(r"([0-9]+) passed in .+", terminal)
    if match is None:
        raise G06VerificationError(
            "pytest log lacks an all-passed terminal summary"
        )
    outcome_count = re.compile(
        r"(?i)(?:^|[\s,])(?:[0-9]+)\s+"
        r"(?:passed|failed|errors?|skipped|xfailed|xpassed|deselected|warnings?)"
        r"(?:$|[\s,])"
    )
    if any(outcome_count.search(line) for line in nonempty_lines[:-1]):
        raise G06VerificationError(
            "pytest log contains a non-terminal outcome summary"
        )
    total = int(match.group(1))
    if total <= 0:
        raise G06VerificationError("pytest executed-test count is zero")
    return {
        "test_count": total,
        "passed": total,
        "failed": 0,
        "skipped": 0,
        "errors": 0,
        "xfailed": 0,
        "xpassed": 0,
        "deselected": 0,
        "terminal_status": "passed",
    }


def parse_xcresult_summary(document: Mapping[str, object]) -> Mapping[str, object]:
    def count(name: str) -> int:
        value = document.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise G06VerificationError(f"xcresult summary count is invalid: {name}")
        return value

    total = count("totalTestCount")
    passed = count("passedTests")
    failed = count("failedTests")
    skipped = count("skippedTests")
    expected = count("expectedFailures")
    if total <= 0 or passed + failed + skipped + expected != total:
        raise G06VerificationError("xcresult summary arithmetic differs")
    result = document.get("result")
    if not isinstance(result, str) or not result:
        raise G06VerificationError("xcresult summary status is absent")
    return {
        "test_count": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expected_failures": expected,
        "terminal_status": "passed" if result == "Passed" else "failed",
    }


def parse_diagnostic_counts(text: str) -> Mapping[str, int]:
    return actionable_diagnostic_counts(text)


def _diagnostics_are_clean(counts: Mapping[str, object]) -> bool:
    return (
        counts.get("warning_count") == 0
        and counts.get("error_count") == 0
    )


def _test_counts_pass(counts: Mapping[str, object]) -> bool:
    return (
        counts.get("terminal_status") == "passed"
        and int(counts.get("test_count", 0)) > 0
        and all(
            int(counts.get(field, 0)) == 0
            for field in (
                "failed",
                "errors",
                "skipped",
                "expected_failures",
                "unexpected_successes",
                "xfailed",
                "xpassed",
                "deselected",
            )
        )
    )


class G06VerificationRunner:
    def __init__(
        self,
        *,
        repository_root: Path,
        output_root: Path,
        run_id: str,
        project: str = "Mirmir.xcodeproj",
        scheme: str = "Mirmir",
        destination: str = "platform=macOS,arch=arm64",
        python_executable: str = sys.executable,
        swiftlint_executable: str = "swiftlint",
        timeout_seconds: float = 3600.0,
        native_runtime_evidence_root: Optional[Path] = None,
        expected_native_runtime_manifest_file_sha256: Optional[str] = None,
        group_executors: Optional[
            Mapping[str, Callable[[Path], GroupResult]]
        ] = None,
    ) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        if repository_root.is_symlink() or not self.repository_root.is_dir():
            raise G06VerificationError("repository root is symbolic or not a directory")
        if self.repository_root != REPOSITORY_ROOT:
            raise G06VerificationError(
                "repository root differs from the bound G06 verifier checkout"
            )
        self.output_root = Path(os.path.abspath(output_root)).resolve(strict=False)
        self.run_id = _validate_run_id(run_id)
        project_relative = _safe_relative(project)
        self.project = project_relative.as_posix()
        project_path = self.repository_root.joinpath(*project_relative.parts)
        if project_path.is_symlink() or not project_path.is_dir():
            raise G06VerificationError("Xcode project is absent or symbolic")
        if not isinstance(scheme, str) or not scheme:
            raise G06VerificationError("Xcode scheme is absent")
        if not isinstance(destination, str) or not destination:
            raise G06VerificationError("Xcode destination is absent")
        if not isinstance(timeout_seconds, (int, float)) or timeout_seconds <= 0:
            raise G06VerificationError("command timeout must be positive")
        self.scheme = scheme
        self.destination = destination
        self.python_executable = python_executable
        self.swiftlint_executable = swiftlint_executable
        self.timeout_seconds = float(timeout_seconds)
        if (native_runtime_evidence_root is None) != (
            expected_native_runtime_manifest_file_sha256 is None
        ):
            raise G06VerificationError(
                "native runtime evidence root and expected manifest file SHA-256 "
                "must be provided together"
            )
        self.native_runtime_evidence_root: Optional[Path] = None
        self.native_runtime_repository_relative_root: Optional[
            PurePosixPath
        ] = None
        self.expected_native_runtime_manifest_file_sha256: Optional[str] = None
        self.native_runtime_source_provenance: Optional[
            Mapping[str, object]
        ] = None
        if native_runtime_evidence_root is not None:
            expected_manifest_file_sha256 = _validate_sha256(
                expected_native_runtime_manifest_file_sha256,
                label="expected native runtime manifest file SHA-256",
            )
            runtime_root, relative_root = _repository_artifacts_ash_directory(
                self.repository_root,
                native_runtime_evidence_root,
            )
            try:
                verified = verify_frozen_runtime_correction(
                    runtime_root,
                    expected_manifest_file_sha256=(
                        expected_manifest_file_sha256
                    ),
                    expected_root_label=relative_root.as_posix(),
                )
            except (RuntimeCorrectionArtifactError, ValueError) as error:
                raise G06VerificationError(
                    f"native runtime evidence is invalid: {error}"
                ) from error
            provenance = _native_runtime_source_provenance(
                verified,
                repository_root=self.repository_root,
                repository_relative_root=relative_root,
            )
            self.native_runtime_evidence_root = runtime_root
            self.native_runtime_repository_relative_root = relative_root
            self.expected_native_runtime_manifest_file_sha256 = (
                expected_manifest_file_sha256
            )
            self.native_runtime_source_provenance = provenance
        self.group_executors = dict(group_executors or {})

    def _execute_command(
        self,
        *,
        run_root: Path,
        command_index: int,
        argv: Sequence[str],
        log_artifact_id: str,
        artifact_kind: str = "command_log",
        raw_output: bool = False,
    ) -> Mapping[str, object]:
        if not argv or any(not isinstance(value, str) or not value for value in argv):
            raise G06VerificationError("command argv is empty or invalid")
        log_path = _safe_child(run_root, log_artifact_id)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(log_path, flags, 0o600)
        started = time.monotonic()
        timed_out = False
        exit_code = 127
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            if not raw_output:
                handle.write((f"command: {shlex.join(argv)}\n").encode("utf-8"))
                handle.write(b"working_directory: .\n")
                handle.flush()
            environment = os.environ.copy()
            for name in tuple(environment):
                if name.startswith("PYTEST_") or name in {
                    "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT",
                    "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT",
                    "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK",
                    "PYTHONHOME",
                    "PYTHONOPTIMIZE",
                    "PYTHONPATH",
                }:
                    environment.pop(name, None)
            environment["PYTHONOPTIMIZE"] = ""
            environment["PYTHONPATH"] = str(self.repository_root)
            try:
                completed = subprocess.run(
                    list(argv),
                    cwd=self.repository_root,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    timeout=self.timeout_seconds,
                    check=False,
                )
                exit_code = int(completed.returncode)
            except subprocess.TimeoutExpired:
                timed_out = True
                exit_code = 124
                handle.write(b"\ncommand_timed_out: true\n")
            except OSError as error:
                exit_code = 127
                handle.write(
                    (
                        "\ncommand_launch_error: "
                        f"{type(error).__name__}: {error}\n"
                    ).encode("utf-8", errors="replace")
                )
            handle.flush()
            os.fsync(handle.fileno())
        duration = round(max(0.0, time.monotonic() - started), 6)
        log_binding = _file_binding(
            log_path,
            run_root=run_root,
            artifact_kind=artifact_kind,
        )
        return {
            "command_index": command_index,
            "argv": list(argv),
            "command_text": shlex.join(argv),
            "working_directory": ".",
            "exit_code": exit_code,
            "timed_out": timed_out,
            "duration_seconds": duration,
            "status": "passed" if exit_code == 0 and not timed_out else "failed",
            "log_binding": log_binding,
        }

    @staticmethod
    def _artifacts_from_commands(
        commands: Sequence[Mapping[str, object]],
        extras: Sequence[Mapping[str, object]] = (),
    ) -> Tuple[Mapping[str, object], ...]:
        ordered: List[Mapping[str, object]] = []
        seen = set()
        for binding in [
            *(command["log_binding"] for command in commands),
            *extras,
        ]:
            assert isinstance(binding, dict)
            artifact_id = binding["artifact_id"]
            if artifact_id in seen:
                continue
            seen.add(artifact_id)
            ordered.append(dict(binding))
        return tuple(ordered)

    @staticmethod
    def _finish_group(
        *,
        started: str,
        commands: Sequence[Mapping[str, object]],
        artifacts: Sequence[Mapping[str, object]],
        summary: Mapping[str, object],
        passed: bool,
        failures: Sequence[str],
    ) -> GroupResult:
        reason = None if passed else "; ".join(failures) or "verification failed"
        return GroupResult(
            status="passed" if passed else "failed",
            started_utc=started,
            finished_utc=_utc_now(),
            commands=tuple(dict(command) for command in commands),
            artifacts=tuple(dict(binding) for binding in artifacts),
            summary=dict(summary),
            failure_reason=reason,
        )

    def _verified_native_runtime_evidence(
        self,
    ) -> Tuple[VerifiedRuntimeCorrection, Mapping[str, object]]:
        source_root = self.native_runtime_evidence_root
        relative_root = self.native_runtime_repository_relative_root
        expected_manifest_file_sha256 = (
            self.expected_native_runtime_manifest_file_sha256
        )
        expected_provenance = self.native_runtime_source_provenance
        if (
            source_root is None
            or relative_root is None
            or expected_manifest_file_sha256 is None
            or expected_provenance is None
        ):
            raise G06VerificationError(
                "native runtime evidence input is absent"
            )
        try:
            verified = verify_frozen_runtime_correction(
                source_root,
                expected_manifest_file_sha256=expected_manifest_file_sha256,
                expected_root_label=relative_root.as_posix(),
            )
        except (RuntimeCorrectionArtifactError, ValueError) as error:
            raise G06VerificationError(
                f"native runtime evidence changed before Python verification: {error}"
            ) from error
        provenance = _native_runtime_source_provenance(
            verified,
            repository_root=self.repository_root,
            repository_relative_root=relative_root,
        )
        if provenance != expected_provenance:
            raise G06VerificationError(
                "native runtime evidence provenance changed before Python verification"
            )
        return verified, provenance

    def _require_runtime_copy_matches_frozen_source(
        self,
        *,
        run_root: Path,
        frozen: VerifiedRuntimeCorrection,
        provenance: Mapping[str, object],
    ) -> None:
        relative_root = self.native_runtime_repository_relative_root
        expected_manifest_file_sha256 = (
            self.expected_native_runtime_manifest_file_sha256
        )
        if relative_root is None or expected_manifest_file_sha256 is None:
            raise G06VerificationError("native runtime evidence input is absent")
        document = _read_json(
            run_root / "python_calibration_full_suite.json"
        )
        summary = document.get("summary")
        if (
            not isinstance(summary, dict)
            or summary.get("native_runtime_source") != provenance
        ):
            raise G06VerificationError(
                "published Python evidence is not bound to the frozen runtime source"
            )
        copied_root = _safe_child(
            run_root,
            "inputs/native-runtime-evidence",
        )
        try:
            copied = verify_runtime_correction_copy(
                copied_root,
                expected_manifest_file_sha256=expected_manifest_file_sha256,
                expected_root_label=relative_root.as_posix(),
            )
        except (RuntimeCorrectionArtifactError, ValueError) as error:
            raise G06VerificationError(
                f"published native runtime copy is invalid: {error}"
            ) from error
        if (
            copied.manifest != frozen.manifest
            or copied.manifest_file_sha256 != frozen.manifest_file_sha256
            or copied.files != frozen.files
        ):
            raise G06VerificationError(
                "published native runtime copy differs from the frozen source"
            )

    def _python_full_suite(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        verified_runtime, runtime_provenance = (
            self._verified_native_runtime_evidence()
        )
        runtime_input = _safe_child(
            run_root,
            "inputs/native-runtime-evidence",
        )
        _copy_runtime_evidence_snapshot(
            verified_runtime,
            destination=runtime_input,
        )
        runtime_binding = _tree_binding(
            runtime_input,
            run_root=run_root,
            artifact_kind="native_runtime_evidence_input",
        )
        benchmark_input = runtime_input / "native-aggregate-benchmark.json"
        pytest_environment = (
            "/usr/bin/env",
            "PYTEST_ADDOPTS=",
            "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1",
            "PYTEST_PLUGINS=",
            "PYTHONHOME=",
            "PYTHONOPTIMIZE=",
            f"PYTHONPATH={self.repository_root}",
            "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT=",
            "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=1",
            (
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                f"{benchmark_input}"
            ),
        )
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=(
                    "/usr/bin/env",
                    "PYTHONOPTIMIZE=",
                    self.python_executable,
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "validation/calibration_v2/tests",
                    "-p",
                    "test_*.py",
                ),
                log_artifact_id="logs/python-unittest-discovery.log",
            ),
            self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=(
                    *pytest_environment,
                    self.python_executable,
                    "-m",
                    "pytest",
                    "-c",
                    "/dev/null",
                    "-p",
                    "no:cacheprovider",
                    "--noconftest",
                    "-q",
                    "validation/calibration_v2/tests",
                ),
                log_artifact_id="logs/python-pytest.log",
            ),
            self._execute_command(
                run_root=run_root,
                command_index=3,
                argv=(
                    *pytest_environment,
                    self.python_executable,
                    "-m",
                    "pytest",
                    "-c",
                    "/dev/null",
                    "-p",
                    "no:cacheprovider",
                    "--noconftest",
                    "-q",
                    NATIVE_BENCHMARK_PROOF_NODE_ID,
                ),
                log_artifact_id="logs/python-native-benchmark-proof.log",
            ),
        ]
        failures = []
        runner_rows = []
        for runner_id, command in zip(PYTHON_TEST_RUNNER_IDS, commands):
            log_id = str(command["log_binding"]["artifact_id"])
            text = _decode_utf8(
                _read_regular(_safe_child(run_root, log_id)),
                label=log_id,
            )
            try:
                counts = (
                    parse_unittest_output(text)
                    if runner_id == "unittest_discovery"
                    else parse_pytest_output(text)
                )
            except G06VerificationError as error:
                counts = {"parser_error": str(error)}
                failures.append(f"{runner_id}: {error}")
            if command["status"] != "passed":
                failures.append(f"{runner_id} command failed")
            if "parser_error" not in counts and not _test_counts_pass(counts):
                failures.append(f"{runner_id} reported non-passing or skipped tests")
            runner_rows.append({"runner": runner_id, "counts": counts})
        aggregate = sum(
            int(row["counts"].get("test_count", 0))
            for row in runner_rows
            if isinstance(row["counts"], dict)
        )
        artifacts = self._artifacts_from_commands(
            commands,
            extras=(runtime_binding,),
        )
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "runners": runner_rows,
                "aggregate_executed_test_count": aggregate,
                "required_runner_order": list(PYTHON_TEST_RUNNER_IDS),
                "native_runtime_evidence_input": runtime_binding,
                "native_runtime_source": runtime_provenance,
            },
            passed=not failures,
            failures=failures,
        )

    def _xcode_test_command(
        self,
        *,
        configuration: str,
        derived_data: Path,
        result_bundle: Path,
        tests: Sequence[str],
        clean: bool,
    ) -> Tuple[str, ...]:
        return (
            "xcodebuild",
            "-project",
            self.project,
            "-scheme",
            self.scheme,
            "-configuration",
            configuration,
            "-destination",
            self.destination,
            "-derivedDataPath",
            str(derived_data),
            "-resultBundlePath",
            str(result_bundle),
            "-enableCodeCoverage",
            "YES",
            "-parallel-testing-enabled",
            "NO",
            *(("-jobs", "1") if configuration == "Release" else ()),
            "CODE_SIGNING_ALLOWED=NO",
            *(("ENABLE_TESTABILITY=YES",) if configuration == "Release" else ()),
            *(f"-only-testing:MirmirTests/{name}" for name in tests),
            *(("clean", "test") if clean else ("test",)),
        )

    def _xcresult_summary(
        self,
        *,
        run_root: Path,
        command_index: int,
        result_bundle: Path,
        log_artifact_id: str,
    ) -> Mapping[str, object]:
        return self._execute_command(
            run_root=run_root,
            command_index=command_index,
            argv=(
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                str(result_bundle),
            ),
            log_artifact_id=log_artifact_id,
            artifact_kind="xcresult_summary",
            raw_output=True,
        )

    def _xcode_native_integration(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        derived = run_root / "build/native-integration-derived-data"
        result_bundle = run_root / "artifacts/native-integration.xcresult"
        result_bundle.parent.mkdir(parents=True, exist_ok=True)
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=self._xcode_test_command(
                    configuration="Debug",
                    derived_data=derived,
                    result_bundle=result_bundle,
                    tests=NATIVE_INTEGRATION_TESTS,
                    clean=True,
                ),
                log_artifact_id="logs/xcode-native-integration.log",
            )
        ]
        extras: List[Mapping[str, object]] = []
        failures = []
        counts: Mapping[str, object] = {"parser_error": "xcresult absent"}
        if result_bundle.is_dir() and not result_bundle.is_symlink():
            summary_command = self._xcresult_summary(
                run_root=run_root,
                command_index=2,
                result_bundle=result_bundle,
                log_artifact_id="artifacts/native-integration-xcresult-summary.log",
            )
            commands.append(summary_command)
            if summary_command["status"] == "passed":
                try:
                    counts = parse_xcresult_summary(
                        _read_json(
                            _safe_child(
                                run_root,
                                str(summary_command["log_binding"]["artifact_id"]),
                            )
                        )
                    )
                except G06VerificationError as error:
                    counts = {"parser_error": str(error)}
                    failures.append(str(error))
            else:
                failures.append("xcresult summary extraction failed")
            extras.append(
                _tree_binding(
                    result_bundle,
                    run_root=run_root,
                    artifact_kind="xcresult",
                )
            )
        else:
            failures.append("native integration xcresult is absent")
        build_log_id = str(commands[0]["log_binding"]["artifact_id"])
        build_log = _decode_utf8(
            _read_regular(_safe_child(run_root, build_log_id)),
            label=build_log_id,
        )
        diagnostics = parse_diagnostic_counts(build_log)
        if commands[0]["status"] != "passed":
            failures.append("native integration xcodebuild failed")
        if diagnostics["error_count"] != 0:
            failures.append("native integration log contains compiler errors")
        if "parser_error" not in counts and not _test_counts_pass(counts):
            failures.append("native integration tests failed or were skipped")
        elif "parser_error" in counts:
            failures.append("native integration result counts are unavailable")
        try:
            _remove_unbound_derived_data(
                run_root=run_root,
                derived_data=derived,
                expected_relative_path="build/native-integration-derived-data",
            )
        except (OSError, G06VerificationError) as error:
            failures.append(f"native DerivedData cleanup failed: {error}")
        artifacts = self._artifacts_from_commands(commands, extras)
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "configuration": "Debug",
                "scheme": self.scheme,
                "destination": self.destination,
                "only_testing": list(NATIVE_INTEGRATION_TESTS),
                "test_counts": counts,
                **diagnostics,
            },
            passed=not failures,
            failures=failures,
        )

    def _xcode_release_runtime(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        derived = run_root / "build/release-derived-data"
        build_command = self._execute_command(
            run_root=run_root,
            command_index=1,
            argv=(
                "xcodebuild",
                "-project",
                self.project,
                "-scheme",
                self.scheme,
                "-configuration",
                "Release",
                "-destination",
                self.destination,
                "-derivedDataPath",
                str(derived),
                "CODE_SIGNING_ALLOWED=NO",
                "ENABLE_TESTABILITY=YES",
                "clean",
                "build",
            ),
            log_artifact_id="logs/xcode-release-build.log",
        )
        commands = [build_command]
        extras: List[Mapping[str, object]] = []
        failures = []
        build_log_id = str(build_command["log_binding"]["artifact_id"])
        build_log = _decode_utf8(
            _read_regular(_safe_child(run_root, build_log_id)),
            label=build_log_id,
        )
        build_diagnostics = parse_diagnostic_counts(build_log)
        build_succeeded = (
            build_command["status"] == "passed"
            and "** BUILD SUCCEEDED **" in build_log
            and _diagnostics_are_clean(build_diagnostics)
        )
        if not build_succeeded:
            failures.append(
                "Release build failed, warned, errored, or lacks its success marker"
            )
        executable = derived / "Build/Products/Release/Mirmir.app/Contents/MacOS/Mirmir"
        product_exists_after_build = (
            executable.is_file() and not executable.is_symlink()
        )
        if not product_exists_after_build:
            failures.append("Release application executable is absent")

        runtime_counts: Mapping[str, object] = {"parser_error": "not run"}
        runtime_diagnostics = {"warning_count": 0, "error_count": 0}
        result_bundle = run_root / "artifacts/release-runtime.xcresult"
        if build_succeeded:
            result_bundle.parent.mkdir(parents=True, exist_ok=True)
            runtime_command = self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=self._xcode_test_command(
                    configuration="Release",
                    derived_data=derived,
                    result_bundle=result_bundle,
                    tests=RELEASE_RUNTIME_TESTS,
                    clean=False,
                ),
                log_artifact_id="logs/xcode-release-runtime.log",
            )
            commands.append(runtime_command)
            runtime_log_id = str(runtime_command["log_binding"]["artifact_id"])
            runtime_log = _decode_utf8(
                _read_regular(_safe_child(run_root, runtime_log_id)),
                label=runtime_log_id,
            )
            runtime_diagnostics = dict(parse_diagnostic_counts(runtime_log))
            if runtime_command["status"] != "passed":
                failures.append("Release runtime xcodebuild failed")
            if result_bundle.is_dir() and not result_bundle.is_symlink():
                summary_command = self._xcresult_summary(
                    run_root=run_root,
                    command_index=3,
                    result_bundle=result_bundle,
                    log_artifact_id="artifacts/release-runtime-xcresult-summary.log",
                )
                commands.append(summary_command)
                if summary_command["status"] == "passed":
                    try:
                        runtime_counts = parse_xcresult_summary(
                            _read_json(
                                _safe_child(
                                    run_root,
                                    str(
                                        summary_command["log_binding"]["artifact_id"]
                                    ),
                                )
                            )
                        )
                    except G06VerificationError as error:
                        runtime_counts = {"parser_error": str(error)}
                        failures.append(str(error))
                else:
                    failures.append("Release runtime xcresult extraction failed")
                extras.append(
                    _tree_binding(
                        result_bundle,
                        run_root=run_root,
                        artifact_kind="xcresult",
                    )
                )
            else:
                failures.append("Release runtime xcresult is absent")
        if not _diagnostics_are_clean(runtime_diagnostics):
            failures.append("Release runtime log contains warnings or compiler errors")
        if "parser_error" not in runtime_counts:
            if not _test_counts_pass(runtime_counts):
                failures.append("Release runtime tests failed or were skipped")
        else:
            failures.append("Release runtime result counts are unavailable")
        retained_product = False
        try:
            retained_product = _retain_release_product_only(
                run_root=run_root,
                derived_data=derived,
                executable=executable,
            )
        except (OSError, G06VerificationError) as error:
            failures.append(f"Release DerivedData retention failed: {error}")
        if retained_product:
            extras.append(
                _file_binding(
                    executable,
                    run_root=run_root,
                    artifact_kind="release_product",
                )
            )
        elif product_exists_after_build:
            failures.append("Release application executable disappeared during runtime tests")
        artifacts = self._artifacts_from_commands(commands, extras)
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=artifacts,
            summary={
                "configuration": "Release",
                "scheme": self.scheme,
                "destination": self.destination,
                "only_testing": list(RELEASE_RUNTIME_TESTS),
                "build_warning_count": build_diagnostics["warning_count"],
                "build_error_count": build_diagnostics["error_count"],
                "runtime_warning_count": runtime_diagnostics["warning_count"],
                "runtime_error_count": runtime_diagnostics["error_count"],
                "test_counts": runtime_counts,
            },
            passed=not failures,
            failures=failures,
        )

    def _swiftlint(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        commands = [
            self._execute_command(
                run_root=run_root,
                command_index=1,
                argv=(self.swiftlint_executable, "version"),
                log_artifact_id="logs/swiftlint-version.log",
            ),
            self._execute_command(
                run_root=run_root,
                command_index=2,
                argv=(
                    self.swiftlint_executable,
                    "lint",
                    "--strict",
                    "--config",
                    ".swiftlint.yml",
                ),
                log_artifact_id="logs/swiftlint-strict.log",
            ),
        ]
        lint_log_id = str(commands[1]["log_binding"]["artifact_id"])
        lint_log = _decode_utf8(
            _read_regular(_safe_child(run_root, lint_log_id)),
            label=lint_log_id,
        )
        diagnostics = parse_diagnostic_counts(lint_log)
        failures = []
        if any(command["status"] != "passed" for command in commands):
            failures.append("SwiftLint version or strict lint command failed")
        if diagnostics["warning_count"] or diagnostics["error_count"]:
            failures.append("SwiftLint strict reported violations")
        return self._finish_group(
            started=started,
            commands=commands,
            artifacts=self._artifacts_from_commands(commands),
            summary={
                "strict": True,
                **diagnostics,
            },
            passed=not failures,
            failures=failures,
        )

    def _release_lock_unit_suite(self, run_root: Path) -> GroupResult:
        started = _utc_now()
        command = self._execute_command(
            run_root=run_root,
            command_index=1,
            argv=(
                "/usr/bin/env",
                "PYTHONOPTIMIZE=",
                self.python_executable,
                "-m",
                "unittest",
                *RELEASE_LOCK_TEST_MODULES,
            ),
            log_artifact_id="logs/release-lock-unit-suite.log",
        )
        log_id = str(command["log_binding"]["artifact_id"])
        text = _decode_utf8(
            _read_regular(_safe_child(run_root, log_id)),
            label=log_id,
        )
        failures = []
        try:
            counts = parse_unittest_output(text)
        except G06VerificationError as error:
            counts = {"parser_error": str(error)}
            failures.append(str(error))
        if command["status"] != "passed":
            failures.append("release-lock unit command failed")
        if "parser_error" not in counts and not _test_counts_pass(counts):
            failures.append("release-lock unit tests failed or were skipped")
        return self._finish_group(
            started=started,
            commands=(command,),
            artifacts=self._artifacts_from_commands((command,)),
            summary={
                "modules": [
                    *RELEASE_LOCK_TEST_MODULES,
                ],
                "test_counts": counts,
            },
            passed=not failures,
            failures=failures,
        )

    @staticmethod
    def _not_run(prior_failure: str) -> GroupResult:
        now = _utc_now()
        return GroupResult(
            status="not_run",
            started_utc=now,
            finished_utc=now,
            commands=(),
            artifacts=(),
            summary={"prior_failed_evidence_id": prior_failure},
            failure_reason=f"not run because {prior_failure} failed",
        )

    @staticmethod
    def _evidence_document(
        identifier: str,
        ordinal: int,
        result: GroupResult,
    ) -> Mapping[str, object]:
        artifact_ids = [binding.get("artifact_id") for binding in result.artifacts]
        command_logs = [
            command.get("log_binding") for command in result.commands
        ]
        if (
            result.status == "passed"
            and (
                not result.commands
                or any(command.get("status") != "passed" for command in result.commands)
                or result.failure_reason is not None
            )
        ):
            raise G06VerificationError("passed evidence has incomplete commands")
        if result.status != "passed" and not result.failure_reason:
            raise G06VerificationError("non-passing evidence lacks a failure reason")
        if (
            len(artifact_ids) != len(set(artifact_ids))
            or any(binding not in result.artifacts for binding in command_logs)
        ):
            raise G06VerificationError("evidence artifact bindings are duplicated or incomplete")
        document: Dict[str, object] = {
            "schema_version": "1.2.0",
            "artifact_kind": "p06_g06_test_evidence",
            "evidence_id": identifier,
            "evidence_ordinal": ordinal,
            "status": result.status,
            "started_utc": result.started_utc,
            "finished_utc": result.finished_utc,
            "commands": [dict(value) for value in result.commands],
            "artifacts": [dict(value) for value in result.artifacts],
            "summary": dict(result.summary),
            "failure_reason": result.failure_reason,
            "holdout_accessed": False,
            "verifier_source": _repository_source_binding(VERIFIER_SOURCE_PATH),
            "evidence_schema": _repository_source_binding(SCHEMA_PATH),
        }
        document["evidence_sha256"] = canonical_sha256(document)
        validate_schema(document, SCHEMA_PATH)
        return document

    def _internal_failure_result(
        self,
        *,
        run_root: Path,
        identifier: str,
        started: str,
        error: BaseException,
    ) -> GroupResult:
        artifact_id = f"logs/{identifier}-internal-error.log"
        path = _safe_child(run_root, artifact_id)
        payload = (
            "".join(traceback.format_exception(type(error), error, error.__traceback__))
        ).encode("utf-8", errors="replace")
        _write_new(path, payload)
        binding = _file_binding(
            path,
            run_root=run_root,
            artifact_kind="internal_error",
        )
        return GroupResult(
            status="failed",
            started_utc=started,
            finished_utc=_utc_now(),
            commands=(),
            artifacts=(binding,),
            summary={"internal_error_type": type(error).__name__},
            failure_reason=f"{type(error).__name__}: {error}",
        )

    def _default_executors(self) -> Mapping[str, Callable[[Path], GroupResult]]:
        return {
            "python_calibration_full_suite": self._python_full_suite,
            "xcode_native_integration": self._xcode_native_integration,
            "xcode_release_runtime": self._xcode_release_runtime,
            "swiftlint": self._swiftlint,
            "release_lock_unit_suite": self._release_lock_unit_suite,
        }

    def _verify_published(
        self,
        root: Path,
        *,
        require_release_semantics: bool = False,
        execution_run_name: Optional[str] = None,
    ) -> Tuple[Tuple[str, Path], ...]:
        json_paths = sorted(path.name for path in root.glob("*.json"))
        expected_names = [f"{identifier}.json" for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS]
        if json_paths != sorted(expected_names):
            raise G06VerificationError("published G06 evidence file set differs")
        result = []
        expected_closure: Dict[str, str] = {}
        for ordinal, identifier in enumerate(REQUIRED_G06_TEST_EVIDENCE_IDS, 1):
            path = root / f"{identifier}.json"
            _declare_run_closure_entry(
                expected_closure,
                path.name,
                "regular_file",
            )
            document = _read_json(path)
            unhashed = dict(document)
            declared = unhashed.pop("evidence_sha256", None)
            if (
                document.get("evidence_id") != identifier
                or document.get("evidence_ordinal") != ordinal
                or declared != canonical_sha256(unhashed)
            ):
                raise G06VerificationError("published G06 evidence identity changed")
            validate_schema(document, SCHEMA_PATH)
            artifacts = document.get("artifacts")
            assert isinstance(artifacts, list)
            for binding in artifacts:
                assert isinstance(binding, dict)
                artifact_id = binding.get("artifact_id")
                digest_mode = binding.get("digest_mode")
                artifact_kind = binding.get("artifact_kind")
                if not isinstance(artifact_id, str) or not isinstance(
                    artifact_kind, str
                ):
                    raise G06VerificationError("artifact binding identity is invalid")
                artifact_path = _safe_child(root, artifact_id)
                if digest_mode == "file_sha256":
                    recomputed = _file_binding(
                        artifact_path,
                        run_root=root,
                        artifact_kind=artifact_kind,
                    )
                    _declare_run_closure_entry(
                        expected_closure,
                        artifact_id,
                        "regular_file",
                    )
                elif digest_mode == "canonical_tree_manifest_sha256":
                    recomputed, tree_entries = _tree_binding_and_entries(
                        artifact_path,
                        run_root=root,
                        artifact_kind=artifact_kind,
                    )
                    _declare_run_closure_entry(
                        expected_closure,
                        artifact_id,
                        "directory",
                    )
                    for entry in tree_entries:
                        entry_path = entry.get("path")
                        entry_kind = entry.get("entry_kind")
                        if not isinstance(entry_path, str) or entry_kind not in {
                            "directory",
                            "regular_file",
                        }:
                            raise G06VerificationError(
                                "tree artifact closure entry is invalid"
                            )
                        _declare_run_closure_entry(
                            expected_closure,
                            f"{artifact_id}/{entry_path}",
                            str(entry_kind),
                        )
                else:
                    raise G06VerificationError("artifact binding digest mode is invalid")
                if binding != recomputed:
                    raise G06VerificationError(
                        f"artifact binding changed: {artifact_id}"
                    )
            if require_release_semantics:
                from validation.calibration_v2.release_orchestrator import (
                    P06ReleaseOrchestrationError,
                    _validate_g06_group_semantics,
                )

                try:
                    _validate_g06_group_semantics(
                        identifier=identifier,
                        document=document,
                        run_root=root,
                        bindings=tuple(dict(binding) for binding in artifacts),
                        execution_run_name=execution_run_name,
                    )
                except P06ReleaseOrchestrationError as error:
                    raise G06VerificationError(
                        f"published G06 release semantics differ: {error}"
                    ) from error
            result.append((identifier, path))
        actual_closure = _run_tree_entry_kinds(root)
        if actual_closure != expected_closure:
            raise G06VerificationError(
                "published G06 run-tree closure differs"
            )
        return tuple(result)

    def run(self) -> VerificationRunResult:
        self.output_root.mkdir(parents=True, exist_ok=True)
        if self.output_root.is_symlink() or not self.output_root.is_dir():
            raise G06VerificationError("output root is symbolic or not a directory")
        _recover_g06_transaction(
            output_root=self.output_root,
            run_id=self.run_id,
        )
        names = _g06_transaction_names(self.run_id)
        final = self.output_root / names["final_name"]
        partial = self.output_root / names["partial_name"]
        failed = self.output_root / names["failed_name"]
        staging = self.output_root / names["staging_name"]
        marker = self.output_root / names["marker_name"]
        if any(
            path.exists() or path.is_symlink()
            for path in (final, partial, failed, staging, marker)
        ):
            raise G06VerificationError("run destination already exists")
        transaction = _begin_g06_transaction(
            output_root=self.output_root,
            run_id=self.run_id,
        )
        partial_identity = transaction.root_metadata
        try:
            defaults = self._default_executors()
            executors = {
                identifier: self.group_executors.get(
                    identifier,
                    defaults[identifier],
                )
                for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
            }
            prior_failure = None
            statuses = []
            for ordinal, identifier in enumerate(
                REQUIRED_G06_TEST_EVIDENCE_IDS,
                1,
            ):
                if prior_failure is not None:
                    result = self._not_run(prior_failure)
                else:
                    started = _utc_now()
                    try:
                        result = executors[identifier](partial)
                    except BaseException as error:
                        result = self._internal_failure_result(
                            run_root=partial,
                            identifier=identifier,
                            started=started,
                            error=error,
                        )
                    if result.status != "passed":
                        prior_failure = identifier
                if result.status not in {"passed", "failed", "not_run"}:
                    raise G06VerificationError(
                        "group executor returned an invalid status"
                    )
                document = self._evidence_document(identifier, ordinal, result)
                _write_json_new(partial / f"{identifier}.json", document)
                statuses.append(result.status)
            passed = statuses == ["passed"] * len(
                REQUIRED_G06_TEST_EVIDENCE_IDS
            )
            destination = final if passed else failed
            if passed:
                frozen_runtime, frozen_provenance = (
                    self._verified_native_runtime_evidence()
                )
                self._require_runtime_copy_matches_frozen_source(
                    run_root=partial,
                    frozen=frozen_runtime,
                    provenance=frozen_provenance,
                )
            self._verify_published(
                partial,
                require_release_semantics=passed,
                execution_run_name=self.run_id,
            )
            if destination.exists() or destination.is_symlink():
                raise G06VerificationError(
                    "publication destination appeared during run"
                )
            _require_directory_identity(
                partial,
                partial_identity,
                label="validated G06 partial publication root",
            )
            _fsync_tree(partial)
            _require_directory_identity(
                partial,
                partial_identity,
                label="durably synchronized G06 partial publication root",
            )
            _rename_exclusive(partial, destination)
            _require_directory_identity(
                destination,
                partial_identity,
                label="published G06 root",
            )
            evidence_paths = self._verify_published(
                destination,
                require_release_semantics=passed,
                execution_run_name=self.run_id if passed else None,
            )
            _require_directory_identity(
                destination,
                partial_identity,
                label="reopened G06 publication root",
            )
            descriptor = os.open(self.output_root, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            committed_evidence_paths: Optional[Tuple[Tuple[str, Path], ...]] = None

            def verify_committed() -> None:
                nonlocal committed_evidence_paths
                committed_evidence_paths = self._verify_published(
                    destination,
                    require_release_semantics=passed,
                    execution_run_name=self.run_id if passed else None,
                )

            _commit_g06_transaction(
                transaction,
                destination=destination,
                verify_committed=verify_committed,
            )
            if committed_evidence_paths is None:
                raise G06VerificationError(
                    "G06 commit verification did not produce evidence paths"
                )
            return VerificationRunResult(
                status="passed" if passed else "failed",
                path=destination,
                evidence_paths=committed_evidence_paths,
            )
        except BaseException as primary:
            try:
                _publish_g06_exception_failure(transaction, primary)
            except BaseException as cleanup:
                raise G06VerificationError(
                    "G06 verification failed; failure publication failed: "
                    f"{cleanup}"
                ) from primary
            raise


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run both Python suites, focused Xcode Debug/Release verification, "
            "SwiftLint strict, and release-lock tests without opening holdout data."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--project", default="Mirmir.xcodeproj")
    parser.add_argument("--scheme", default="Mirmir")
    parser.add_argument("--destination", default="platform=macOS,arch=arm64")
    parser.add_argument("--python-executable", default=sys.executable)
    parser.add_argument("--swiftlint-executable", default="swiftlint")
    parser.add_argument(
        "--native-runtime-evidence-root",
        required=True,
        type=Path,
    )
    parser.add_argument(
        "--expected-native-runtime-manifest-file-sha256",
        required=True,
    )
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    return parser.parse_args()


def main() -> int:
    arguments = _arguments()
    try:
        result = G06VerificationRunner(
            repository_root=arguments.repository_root,
            output_root=arguments.output_root,
            run_id=arguments.run_id,
            project=arguments.project,
            scheme=arguments.scheme,
            destination=arguments.destination,
            python_executable=arguments.python_executable,
            swiftlint_executable=arguments.swiftlint_executable,
            native_runtime_evidence_root=(
                arguments.native_runtime_evidence_root
            ),
            expected_native_runtime_manifest_file_sha256=(
                arguments.expected_native_runtime_manifest_file_sha256
            ),
            timeout_seconds=arguments.timeout_seconds,
        ).run()
    except (
        G06VerificationError,
        RuntimeCorrectionArtifactError,
        OSError,
        ValueError,
    ) as error:
        print(f"G06 verification setup failed: {error}", file=sys.stderr)
        return 2
    output = {
        "schema_version": "1.0.0",
        "status": result.status,
        "run_root": str(result.path.resolve(strict=True)),
        "holdout_accessed": False,
        "ordered_test_evidence": [
            {"id": identifier, "path": str(path.resolve(strict=True))}
            for identifier, path in result.evidence_paths
        ],
        "run_p06_production_calibration_arguments": [
            value
            for identifier, path in result.evidence_paths
            for value in ("--test-evidence", f"{identifier}={path.resolve(strict=True)}")
        ],
    }
    print(
        json.dumps(
            output,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0 if result.status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
