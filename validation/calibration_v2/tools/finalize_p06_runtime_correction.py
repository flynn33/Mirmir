#!/usr/bin/env python3
"""Validate, seal, and exclusively publish one P06 runtime-correction run."""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import uuid
from typing import Dict, Mapping, Sequence, Tuple


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
    manifest_sha256,
    validate_schema,
)


SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "p06-runtime-correction-artifact-manifest-v1.schema.json"
)
MANIFEST_NAME = "artifact-manifest.json"
RENAME_EXCL = 0x00000004
RENAME_NOFOLLOW_ANY = 0x00000010
RENAME_RESOLVE_BENEATH = 0x00000020
MANIFEST_TEMPORARY_PATTERN = re.compile(
    r"^\.artifact-manifest\.json\.[0-9a-f]{32}\.tmp$"
)


class RuntimeCorrectionArtifactError(RuntimeError):
    """The P06 correction artifact tree cannot be safely published."""


def _safe_relative(value: object, *, label: str) -> str:
    if not isinstance(value, str):
        raise RuntimeCorrectionArtifactError(f"{label} is not a string")
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or "\x00" in value
        or path.as_posix() != value
        or any(component in {"", ".", ".."} for component in path.parts)
    ):
        raise RuntimeCorrectionArtifactError(f"unsafe {label}: {value!r}")
    return value


def _lstat_directory(path: Path, *, label: str) -> os.stat_result:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise RuntimeCorrectionArtifactError(f"{label} is absent: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeCorrectionArtifactError(f"{label} is not a real directory: {path}")
    return metadata


def _require_absent(path: Path, *, label: str) -> None:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return
    except OSError as error:
        raise RuntimeCorrectionArtifactError(f"cannot inspect {label}: {path}") from error
    raise RuntimeCorrectionArtifactError(f"{label} already exists: {path}")


def _same_identity(
    path: Path,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    current = _lstat_directory(path, label=label)
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise RuntimeCorrectionArtifactError(f"{label} identity changed: {path}")


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise RuntimeCorrectionArtifactError(f"artifact file is absent: {path}") from error
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise RuntimeCorrectionArtifactError(
            f"artifact path is not a single-link regular file: {path}"
        )
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RuntimeCorrectionArtifactError(
            f"artifact file cannot be opened without link traversal: {path}"
        ) from error
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1 or (
            opened.st_dev,
            opened.st_ino,
        ) != (before.st_dev, before.st_ino):
            raise RuntimeCorrectionArtifactError(
                f"artifact file identity changed while opening: {path}"
            )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
        or after.st_size != opened.st_size
        or after.st_mtime_ns != opened.st_mtime_ns
    ):
        raise RuntimeCorrectionArtifactError(
            f"artifact file changed while being read: {path}"
        )
    return b"".join(chunks)


def _load_metadata(
    metadata_bytes: bytes,
    *,
    exact_paths: Sequence[str],
) -> Dict[str, Mapping[str, object]]:
    try:
        document = json.loads(metadata_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeCorrectionArtifactError(
            "artifact metadata is not valid JSON"
        ) from error
    if not isinstance(document, dict) or set(document) != {
        "schema_version",
        "artifact_kind",
        "records",
    }:
        raise RuntimeCorrectionArtifactError(
            "artifact metadata must contain only schema_version, artifact_kind, and records"
        )
    if document.get("schema_version") != "1.0.0" or document.get(
        "artifact_kind"
    ) != "p06_runtime_feasibility_correction_artifact_metadata":
        raise RuntimeCorrectionArtifactError("artifact metadata identity is invalid")
    raw_records = document.get("records")
    if not isinstance(raw_records, list) or not raw_records:
        raise RuntimeCorrectionArtifactError("artifact metadata records are absent")
    by_path: Dict[str, Mapping[str, object]] = {}
    required = {"path", "producer", "command", "platform", "gate_ids"}
    for raw_record in raw_records:
        if not isinstance(raw_record, dict) or set(raw_record) != required:
            raise RuntimeCorrectionArtifactError(
                "each artifact metadata record must have the exact declared fields"
            )
        relative = _safe_relative(raw_record.get("path"), label="artifact path")
        if relative == MANIFEST_NAME or relative in by_path:
            raise RuntimeCorrectionArtifactError(
                f"artifact metadata path is reserved or duplicated: {relative}"
            )
        for field in ("producer", "command", "platform"):
            value = raw_record.get(field)
            if not isinstance(value, str) or not value:
                raise RuntimeCorrectionArtifactError(
                    f"artifact metadata {field} is empty for {relative}"
                )
        gate_ids = raw_record.get("gate_ids")
        if (
            not isinstance(gate_ids, list)
            or not gate_ids
            or len(gate_ids) != len(set(gate_ids))
            or any(gate_id not in {"P06", "G06"} for gate_id in gate_ids)
        ):
            raise RuntimeCorrectionArtifactError(
                f"artifact metadata gate IDs are invalid for {relative}"
            )
        by_path[relative] = raw_record
    if set(by_path) != set(exact_paths):
        missing = sorted(set(exact_paths) - set(by_path))
        extra = sorted(set(by_path) - set(exact_paths))
        raise RuntimeCorrectionArtifactError(
            f"artifact metadata does not match exact file set; missing={missing}, extra={extra}"
        )
    return by_path


def _git_bytes(arguments: Sequence[str]) -> bytes:
    command = ["git", "-C", str(REPOSITORY_ROOT), *arguments]
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeCorrectionArtifactError(
            f"repository-state command failed ({result.returncode}): {diagnostic}"
        )
    return result.stdout


def _repository_state() -> Tuple[Mapping[str, object], bool]:
    project_commit = _git_bytes(("rev-parse", "--verify", "HEAD")).decode(
        "ascii"
    ).strip()
    if len(project_commit) != 40 or any(
        character not in "0123456789abcdef" for character in project_commit
    ):
        raise RuntimeCorrectionArtifactError("repository HEAD is not a SHA-1")
    tracked_diff = _git_bytes(
        (
            "diff",
            "--binary",
            "--no-ext-diff",
            "HEAD",
            "--",
            ".",
            ":(exclude)Artifacts/**",
        )
    )
    untracked_output = _git_bytes(
        (
            "ls-files",
            "-z",
            "--others",
            "--exclude-standard",
            "--",
            ".",
            ":(exclude)Artifacts/**",
        )
    )
    ordered_untracked_files = []
    raw_paths = [item for item in untracked_output.split(b"\x00") if item]
    for raw_path in raw_paths:
        try:
            relative = raw_path.decode("utf-8")
        except UnicodeDecodeError as error:
            raise RuntimeCorrectionArtifactError(
                "untracked repository path is not UTF-8"
            ) from error
        _safe_relative(relative, label="untracked repository path")
        path = REPOSITORY_ROOT.joinpath(*PurePosixPath(relative).parts)
        metadata = os.stat(path, follow_symlinks=False)
        if stat.S_ISREG(metadata.st_mode):
            payload = _read_regular(path)
            kind = "regular"
        elif stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            payload = os.fsencode(target)
            kind = "symbolic_link_target"
        else:
            raise RuntimeCorrectionArtifactError(
                f"untracked repository path has unsupported type: {relative}"
            )
        ordered_untracked_files.append(
            {
                "path": relative,
                "kind": kind,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    if [record["path"] for record in ordered_untracked_files] != sorted(
        record["path"] for record in ordered_untracked_files
    ):
        raise RuntimeCorrectionArtifactError(
            "git did not return untracked paths in canonical order"
        )
    dirty_document = {
        "algorithm": "git-diff-head-binary-plus-content-bound-untracked-v1",
        "artifact_pathspec_exclusion": "Artifacts/**",
        "project_commit": project_commit,
        "tracked_diff_sha256": hashlib.sha256(tracked_diff).hexdigest(),
        "tracked_diff_size_bytes": len(tracked_diff),
        "ordered_untracked_files": ordered_untracked_files,
    }
    dirty_state_sha256 = canonical_sha256(dirty_document)
    summary = {
        "algorithm": dirty_document["algorithm"],
        "artifact_pathspec_exclusion": dirty_document[
            "artifact_pathspec_exclusion"
        ],
        "project_commit": project_commit,
        "tracked_diff_sha256": dirty_document["tracked_diff_sha256"],
        "tracked_diff_size_bytes": len(tracked_diff),
        "untracked_file_count": len(ordered_untracked_files),
        "ordered_untracked_files_sha256": canonical_sha256(
            ordered_untracked_files
        ),
        "dirty_state_sha256": dirty_state_sha256,
    }
    return summary, not tracked_diff and not ordered_untracked_files


def _require_repository_state_unchanged(
    expected: Mapping[str, object],
    expected_clean: bool,
) -> None:
    observed, observed_clean = _repository_state()
    if observed != expected or observed_clean != expected_clean:
        raise RuntimeCorrectionArtifactError(
            "repository state changed during artifact finalization"
        )


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _open_directory(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return os.open(path, flags)


def _rename_exclusive_at(
    source_directory_descriptor: int,
    source_name: str,
    destination_directory_descriptor: int,
    destination_name: str,
    *,
    nofollow_any: bool = True,
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx = getattr(libc, "renameatx_np", None)
    if renameatx is None:
        raise RuntimeCorrectionArtifactError("renameatx_np is unavailable")
    renameatx.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx.restype = ctypes.c_int
    rename_flags = RENAME_EXCL | RENAME_RESOLVE_BENEATH
    if nofollow_any:
        rename_flags |= RENAME_NOFOLLOW_ANY
    result = renameatx(
        source_directory_descriptor,
        os.fsencode(source_name),
        destination_directory_descriptor,
        os.fsencode(destination_name),
        rename_flags,
    )
    if result != 0:
        number = ctypes.get_errno()
        if number == errno.EEXIST:
            raise RuntimeCorrectionArtifactError(
                f"exclusive rename destination already exists: {destination_name}"
            )
        raise OSError(number, os.strerror(number), destination_name)


def _scan_recognized_manifest_temporaries(
    root_descriptor: int,
) -> list[Mapping[str, object]]:
    actions = []
    for entry in sorted(os.scandir(root_descriptor), key=lambda item: item.name):
        if not MANIFEST_TEMPORARY_PATTERN.fullmatch(entry.name):
            continue
        metadata = entry.stat(follow_symlinks=False)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise RuntimeCorrectionArtifactError(
                "recognized manifest temporary is not a single-link regular file"
            )
        payload, opened = _read_regular_at(root_descriptor, entry.name)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise RuntimeCorrectionArtifactError(
                "recognized manifest temporary changed during scan"
            )
        actions.append(
            {
                "action": "removed_recognized_stale_manifest_temporary",
                "path": entry.name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    return actions


def _delete_recorded_manifest_temporaries(
    root_descriptor: int,
    *,
    recovery_actions: Sequence[Mapping[str, object]],
) -> None:
    for action in recovery_actions:
        name = action.get("path")
        if (
            action.get("action")
            != "removed_recognized_stale_manifest_temporary"
            or not isinstance(name, str)
            or not MANIFEST_TEMPORARY_PATTERN.fullmatch(name)
        ):
            raise RuntimeCorrectionArtifactError(
                "recorded manifest-temporary recovery action is invalid"
            )
        try:
            metadata = os.stat(
                name,
                dir_fd=root_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise RuntimeCorrectionArtifactError(
                "recorded manifest temporary is not a single-link regular file"
            )
        payload, opened = _read_regular_at(root_descriptor, name)
        if (
            len(payload) != action.get("size_bytes")
            or hashlib.sha256(payload).hexdigest() != action.get("sha256")
        ):
            raise RuntimeCorrectionArtifactError(
                "recorded manifest temporary bytes changed"
            )
        current = os.stat(
            name,
            dir_fd=root_descriptor,
            follow_symlinks=False,
        )
        if (current.st_dev, current.st_ino) != (
            opened.st_dev,
            opened.st_ino,
        ):
            raise RuntimeCorrectionArtifactError(
                "recorded manifest temporary identity changed"
            )
        os.unlink(name, dir_fd=root_descriptor)
        os.fsync(root_descriptor)


def _atomic_publish_new_manifest(
    root_descriptor: int,
    payload: bytes,
) -> None:
    _require_absent_at(
        root_descriptor,
        MANIFEST_NAME,
        label="artifact manifest",
    )
    temporary_name = f".{MANIFEST_NAME}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(
            temporary_name,
            flags,
            0o600,
            dir_fd=root_descriptor,
        )
        view = memoryview(payload)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise RuntimeCorrectionArtifactError("artifact manifest write stalled")
            written += count
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o444)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        _rename_exclusive_at(
            root_descriptor,
            temporary_name,
            root_descriptor,
            MANIFEST_NAME,
        )
        temporary_name = ""
        os.fsync(root_descriptor)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=root_descriptor)
                os.fsync(root_descriptor)
            except FileNotFoundError:
                pass


def _fchflags(descriptor: int, flags: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    fchflags = getattr(libc, "fchflags", None)
    if fchflags is None:
        raise RuntimeCorrectionArtifactError("fchflags is unavailable")
    fchflags.argtypes = [ctypes.c_int, ctypes.c_uint32]
    fchflags.restype = ctypes.c_int
    if fchflags(descriptor, flags) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def _read_regular_at(
    directory_descriptor: int,
    name: str,
) -> Tuple[bytes, os.stat_result]:
    try:
        before = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise RuntimeCorrectionArtifactError(
            f"descriptor-relative artifact file is absent: {name}"
        ) from error
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise RuntimeCorrectionArtifactError(
            f"descriptor-relative artifact is not a single-link file: {name}"
        )
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise RuntimeCorrectionArtifactError(
                f"descriptor-relative artifact changed while opening: {name}"
            )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
        or after.st_size != opened.st_size
        or after.st_mtime_ns != opened.st_mtime_ns
        or after.st_nlink != 1
    ):
        raise RuntimeCorrectionArtifactError(
            f"descriptor-relative artifact changed while reading: {name}"
        )
    return b"".join(chunks), after


def _walk_artifact_descriptor(
    root_descriptor: int,
) -> Tuple[
    Tuple[Tuple[str, bytes, os.stat_result], ...],
    Tuple[Tuple[str, os.stat_result], ...],
]:
    files = []
    directories = []
    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        relative_directory = "" if directory == "." else directory[2:]
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeCorrectionArtifactError(
                "descriptor walk encountered a non-directory"
            )
        directories.append((relative_directory, metadata))
        for name in directory_names:
            child = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(child.st_mode):
                raise RuntimeCorrectionArtifactError(
                    "descriptor walk encountered a linked traversal entry"
                )
        for name in sorted(file_names):
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            payload, file_metadata = _read_regular_at(descriptor, name)
            files.append((relative, payload, file_metadata))
    return tuple(sorted(files)), tuple(sorted(directories))


def _artifact_descriptor_snapshots(
    root_descriptor: int,
    *,
    ignored_paths: Sequence[str] = (),
) -> Tuple[Tuple[str, bytes, os.stat_result], ...]:
    files, _ = _walk_artifact_descriptor(root_descriptor)
    ignored = set(ignored_paths)
    available = {relative for relative, _, _ in files}
    if not ignored.issubset(available):
        raise RuntimeCorrectionArtifactError(
            "ignored recovery temporary is absent from descriptor snapshot"
        )
    return tuple(
        (relative, payload, metadata)
        for relative, payload, metadata in files
        if relative != MANIFEST_NAME and relative not in ignored
    )


def _verify_descriptor_snapshots_unchanged(
    root_descriptor: int,
    snapshots: Sequence[Tuple[str, bytes, os.stat_result]],
    *,
    ignored_paths: Sequence[str] = (),
) -> None:
    observed = _artifact_descriptor_snapshots(
        root_descriptor,
        ignored_paths=ignored_paths,
    )
    if [relative for relative, _, _ in observed] != [
        relative for relative, _, _ in snapshots
    ]:
        raise RuntimeCorrectionArtifactError(
            "descriptor-pinned artifact path set changed during finalization"
        )
    for expected, current in zip(snapshots, observed):
        relative, expected_payload, expected_metadata = expected
        current_relative, current_payload, current_metadata = current
        if (
            current_relative != relative
            or current_payload != expected_payload
            or (current_metadata.st_dev, current_metadata.st_ino)
            != (expected_metadata.st_dev, expected_metadata.st_ino)
            or current_metadata.st_size != expected_metadata.st_size
            or current_metadata.st_mtime_ns != expected_metadata.st_mtime_ns
        ):
            raise RuntimeCorrectionArtifactError(
                f"descriptor-pinned artifact changed during finalization: {relative}"
            )


def _freeze_tree_descriptor(root_descriptor: int) -> None:
    if not hasattr(stat, "UF_IMMUTABLE"):
        raise RuntimeCorrectionArtifactError(
            "macOS user-immutable flags are required for artifact finalization"
        )
    for _, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        for name in sorted(file_names):
            file_descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                metadata = os.fstat(file_descriptor)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise RuntimeCorrectionArtifactError(
                        "artifact file changed before descriptor sealing"
                    )
                if metadata.st_flags & stat.UF_IMMUTABLE:
                    if metadata.st_mode & (
                        stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
                    ):
                        raise RuntimeCorrectionArtifactError(
                            "immutable artifact file remains writable"
                        )
                else:
                    os.fchmod(file_descriptor, 0o444)
                    _fchflags(
                        file_descriptor,
                        metadata.st_flags | stat.UF_IMMUTABLE,
                    )
                os.fsync(file_descriptor)
            finally:
                os.close(file_descriptor)
        directory_metadata = os.fstat(descriptor)
        if directory_metadata.st_flags & stat.UF_IMMUTABLE:
            if directory_metadata.st_mode & (
                stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
            ):
                raise RuntimeCorrectionArtifactError(
                    "immutable artifact directory remains writable"
                )
        else:
            os.fchmod(descriptor, 0o555)
        os.fsync(descriptor)


def _seal_descendant_directories_descriptor(root_descriptor: int) -> None:
    for directory, _, _, descriptor in os.fwalk(
        ".",
        topdown=False,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        if directory == ".":
            continue
        metadata = os.fstat(descriptor)
        if not metadata.st_flags & stat.UF_IMMUTABLE:
            _fchflags(descriptor, metadata.st_flags | stat.UF_IMMUTABLE)
        os.fsync(descriptor)


def _seal_root_descriptor(
    root_descriptor: int,
    expected_identity: os.stat_result,
) -> None:
    metadata = os.fstat(root_descriptor)
    if (metadata.st_dev, metadata.st_ino) != (
        expected_identity.st_dev,
        expected_identity.st_ino,
    ):
        raise RuntimeCorrectionArtifactError(
            "pinned artifact root identity changed before sealing"
        )
    if not metadata.st_flags & stat.UF_IMMUTABLE:
        _fchflags(root_descriptor, metadata.st_flags | stat.UF_IMMUTABLE)
    os.fsync(root_descriptor)


def _verify_manifest_descriptor(
    root_descriptor: int,
    expected_manifest: Mapping[str, object],
    *,
    metadata_relative: str,
    require_directory_immutable: bool,
) -> None:
    files, directories = _walk_artifact_descriptor(root_descriptor)
    by_path = {relative: (payload, metadata) for relative, payload, metadata in files}
    manifest_entry = by_path.pop(MANIFEST_NAME, None)
    if manifest_entry is None:
        raise RuntimeCorrectionArtifactError("artifact manifest is absent")
    manifest_bytes, manifest_metadata = manifest_entry
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeCorrectionArtifactError("artifact manifest is not valid JSON") from error
    if manifest != expected_manifest:
        raise RuntimeCorrectionArtifactError("artifact manifest bytes changed")
    validate_schema(manifest, SCHEMA_PATH)
    if manifest.get("manifest_sha256") != manifest_sha256(manifest):
        raise RuntimeCorrectionArtifactError("artifact manifest self-hash is invalid")
    actual = tuple(sorted(by_path))
    expected_records = manifest.get("artifacts")
    if not isinstance(expected_records, list):
        raise RuntimeCorrectionArtifactError("artifact records are absent")
    if list(actual) != [
        record.get("path") for record in expected_records if isinstance(record, dict)
    ]:
        raise RuntimeCorrectionArtifactError("artifact manifest path set changed")
    for record, relative in zip(expected_records, actual):
        payload, _ = by_path[relative]
        if (
            record.get("size_bytes") != len(payload)
            or record.get("sha256") != hashlib.sha256(payload).hexdigest()
        ):
            raise RuntimeCorrectionArtifactError(
                f"artifact bytes changed: {record.get('path')}"
            )
    metadata_entry = by_path.get(metadata_relative)
    if metadata_entry is None:
        raise RuntimeCorrectionArtifactError(
            "artifact metadata is absent during descriptor verification"
        )
    declared_metadata = _load_metadata(
        metadata_entry[0],
        exact_paths=list(actual),
    )
    for record in expected_records:
        relative = str(record["path"])
        metadata_record = declared_metadata[relative]
        for field in ("producer", "command", "platform", "gate_ids"):
            if record.get(field) != metadata_record.get(field):
                raise RuntimeCorrectionArtifactError(
                    f"artifact metadata binding differs for {relative}"
                )
    for relative, metadata in directories:
        if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeCorrectionArtifactError(
                f"artifact directory is writable: {relative or '<root>'}"
            )
        if require_directory_immutable and not metadata.st_flags & stat.UF_IMMUTABLE:
            raise RuntimeCorrectionArtifactError(
                f"artifact directory is mutable: {relative or '<root>'}"
            )
    for relative, (_, metadata) in (
        (MANIFEST_NAME, (manifest_bytes, manifest_metadata)),
        *tuple((path, by_path[path]) for path in actual),
    ):
        if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeCorrectionArtifactError(
                f"artifact file is writable: {relative}"
            )
        if not metadata.st_flags & stat.UF_IMMUTABLE:
            raise RuntimeCorrectionArtifactError(
                f"artifact file is mutable: {relative}"
            )


def _rename_exclusive(source: Path, destination: Path) -> None:
    if source.parent != destination.parent:
        raise RuntimeCorrectionArtifactError(
            "exclusive directory rename requires sibling paths"
        )
    descriptor = _open_directory(source.parent)
    try:
        _rename_exclusive_at(
            descriptor,
            source.name,
            descriptor,
            destination.name,
        )
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def _parse_utc(value: object, *, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise RuntimeCorrectionArtifactError(f"{label} is not UTC Z time")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise RuntimeCorrectionArtifactError(f"{label} is invalid") from error
    if parsed.utcoffset() is None or parsed.utcoffset().total_seconds() != 0:
        raise RuntimeCorrectionArtifactError(f"{label} is not UTC")
    return parsed


def _parse_run_uuid(value: object) -> str:
    if not isinstance(value, str):
        raise RuntimeCorrectionArtifactError("run UUID is not a string")
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise RuntimeCorrectionArtifactError("run UUID is invalid") from error
    if str(parsed) != value or parsed.version not in {1, 2, 3, 4, 5}:
        raise RuntimeCorrectionArtifactError("run UUID is not canonical")
    return value


def _read_existing_manifest_descriptor(
    root_descriptor: int,
) -> Mapping[str, object] | None:
    try:
        os.stat(
            MANIFEST_NAME,
            dir_fd=root_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return None
    payload, _ = _read_regular_at(root_descriptor, MANIFEST_NAME)
    try:
        manifest = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeCorrectionArtifactError(
            "existing descriptor-pinned manifest is not valid JSON"
        ) from error
    if not isinstance(manifest, dict):
        raise RuntimeCorrectionArtifactError(
            "existing descriptor-pinned manifest is not an object"
        )
    validate_schema(manifest, SCHEMA_PATH)
    if manifest.get("manifest_sha256") != manifest_sha256(manifest):
        raise RuntimeCorrectionArtifactError(
            "existing descriptor-pinned manifest self-hash is invalid"
        )
    return manifest


def _build_manifest(
    *,
    root_descriptor: int,
    metadata_relative: str,
    run_id: str,
    run_uuid: str,
    started_utc: str,
    finished_utc: str,
    created_utc: str,
    root_label: str,
    repository_state: Mapping[str, object],
    working_tree_clean: bool,
    recovery_actions: Sequence[Mapping[str, object]],
    ignored_paths: Sequence[str] = (),
) -> Tuple[Mapping[str, object], Tuple[Tuple[str, bytes, os.stat_result], ...]]:
    snapshots = _artifact_descriptor_snapshots(
        root_descriptor,
        ignored_paths=ignored_paths,
    )
    by_path = {relative: payload for relative, payload, _ in snapshots}
    metadata_bytes = by_path.get(metadata_relative)
    if metadata_bytes is None:
        raise RuntimeCorrectionArtifactError("artifact metadata file is absent")
    metadata = _load_metadata(
        metadata_bytes,
        exact_paths=[relative for relative, _, _ in snapshots],
    )
    artifacts = []
    for relative, payload, _ in snapshots:
        record = metadata[relative]
        artifacts.append(
            {
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
                "producer": record["producer"],
                "command": record["command"],
                "platform": record["platform"],
                "gate_ids": record["gate_ids"],
            }
        )
    manifest = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_runtime_feasibility_correction_artifact_manifest",
        "run_id": run_id,
        "run_uuid": run_uuid,
        "started_utc": started_utc,
        "finished_utc": finished_utc,
        "created_utc": created_utc,
        "project_commit": repository_state["project_commit"],
        "working_tree_clean": working_tree_clean,
        "dirty_state_sha256": repository_state["dirty_state_sha256"],
        "repository_state": dict(repository_state),
        "root": root_label,
        "holdout_accessed": False,
        "artifacts": artifacts,
        "recovery_actions": [dict(action) for action in recovery_actions],
        "self_reference_boundary": (
            "artifact-manifest.json is excluded from its own ordered artifact list "
            "and bound by manifest_sha256 over this document without that field"
        ),
    }
    manifest["manifest_sha256"] = manifest_sha256(manifest)
    validate_schema(manifest, SCHEMA_PATH)
    _verify_descriptor_snapshots_unchanged(
        root_descriptor,
        snapshots,
        ignored_paths=ignored_paths,
    )
    return manifest, snapshots


def _stat_directory_at(
    descriptor: int,
    name: str,
    *,
    label: str,
) -> os.stat_result:
    try:
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except OSError as error:
        raise RuntimeCorrectionArtifactError(f"{label} is absent") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeCorrectionArtifactError(f"{label} is not a real directory")
    return metadata


def _require_absent_at(descriptor: int, name: str, *, label: str) -> None:
    try:
        os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise RuntimeCorrectionArtifactError(f"cannot inspect {label}") from error
    raise RuntimeCorrectionArtifactError(f"{label} already exists")


def _quarantine_final(
    parent_descriptor: int,
    final_name: str,
) -> str:
    quarantine = (
        f".{final_name}.{uuid.uuid4().hex}.identity-mismatch.quarantine"
    )
    _rename_exclusive_at(
        parent_descriptor,
        final_name,
        parent_descriptor,
        quarantine,
        nofollow_any=False,
    )
    os.fsync(parent_descriptor)
    return quarantine


def _require_expected_published_directory(
    parent_descriptor: int,
    final_name: str,
    expected_identity: os.stat_result,
    *,
    context: str,
) -> os.stat_result:
    try:
        observed = os.stat(
            final_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError as error:
        raise RuntimeCorrectionArtifactError(
            f"{context}: published entry is absent"
        ) from error
    if not stat.S_ISDIR(observed.st_mode) or (
        observed.st_dev,
        observed.st_ino,
    ) != (expected_identity.st_dev, expected_identity.st_ino):
        quarantine = _quarantine_final(parent_descriptor, final_name)
        raise RuntimeCorrectionArtifactError(
            f"{context}: canonical entry differs; quarantined as {quarantine}"
        )
    return observed


def finalize_runtime_correction(
    *,
    partial: Path,
    final: Path,
    metadata_path: Path,
    run_id: str,
    run_uuid: str,
    started_utc: str,
    finished_utc: str,
    root_label: str,
) -> Path:
    """Seal one recognized partial tree and publish it without replacement."""

    if partial.parent != final.parent or partial == final:
        raise RuntimeCorrectionArtifactError(
            "partial and final directories must be distinct siblings"
        )
    if not partial.name.startswith(f".{final.name}.") or not partial.name.endswith(
        ".partial"
    ):
        raise RuntimeCorrectionArtifactError(
            "partial directory name is not recognized for the final run"
        )
    _safe_relative(run_id, label="run ID")
    _parse_run_uuid(run_uuid)
    _safe_relative(root_label, label="root label")
    parsed_started = _parse_utc(started_utc, label="started UTC")
    parsed_finished = _parse_utc(finished_utc, label="finished UTC")
    if parsed_finished < parsed_started:
        raise RuntimeCorrectionArtifactError("finished UTC precedes started UTC")
    try:
        metadata_relative = metadata_path.relative_to(partial).as_posix()
    except ValueError as error:
        raise RuntimeCorrectionArtifactError(
            "artifact metadata must be inside the partial directory"
        ) from error
    _safe_relative(metadata_relative, label="artifact metadata path")
    repository_state, working_tree_clean = _repository_state()
    parent_identity = _lstat_directory(partial.parent, label="artifact parent")
    parent_descriptor = _open_directory(partial.parent)
    try:
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != (
            parent_identity.st_dev,
            parent_identity.st_ino,
        ):
            raise RuntimeCorrectionArtifactError(
                "artifact parent changed while being opened"
            )
        try:
            partial_metadata = os.stat(
                partial.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            partial_metadata = None
        except OSError as error:
            raise RuntimeCorrectionArtifactError(
                "cannot inspect partial artifact directory"
            ) from error
        if partial_metadata is None:
            final_identity = _stat_directory_at(
                parent_descriptor,
                final.name,
                label="final artifact directory",
            )
            final_descriptor = _open_directory(final)
            try:
                opened_final = os.fstat(final_descriptor)
                if (opened_final.st_dev, opened_final.st_ino) != (
                    final_identity.st_dev,
                    final_identity.st_ino,
                ):
                    raise RuntimeCorrectionArtifactError(
                        "final artifact changed while being opened"
                    )
                existing = _read_existing_manifest_descriptor(final_descriptor)
                if existing is None:
                    raise RuntimeCorrectionArtifactError(
                        "pre-existing final artifact has no manifest"
                    )
                created_utc = existing.get("created_utc")
                parsed_created = _parse_utc(created_utc, label="created UTC")
                if parsed_created < parsed_finished:
                    raise RuntimeCorrectionArtifactError(
                        "created UTC precedes finished UTC"
                    )
                expected_identity_fields = {
                    "run_id": run_id,
                    "run_uuid": run_uuid,
                    "started_utc": started_utc,
                    "finished_utc": finished_utc,
                    "root": root_label,
                    "project_commit": repository_state["project_commit"],
                    "working_tree_clean": working_tree_clean,
                    "dirty_state_sha256": repository_state[
                        "dirty_state_sha256"
                    ],
                    "repository_state": repository_state,
                    "holdout_accessed": False,
                }
                if any(
                    existing.get(field) != expected
                    for field, expected in expected_identity_fields.items()
                ):
                    raise RuntimeCorrectionArtifactError(
                        "pre-existing final artifact identity differs"
                    )
                _require_repository_state_unchanged(
                    repository_state,
                    working_tree_clean,
                )
                _require_absent_at(
                    parent_descriptor,
                    partial.name,
                    label="partial artifact directory",
                )
                _verify_manifest_descriptor(
                    final_descriptor,
                    existing,
                    metadata_relative=metadata_relative,
                    require_directory_immutable=False,
                )
                _freeze_tree_descriptor(final_descriptor)
                _verify_manifest_descriptor(
                    final_descriptor,
                    existing,
                    metadata_relative=metadata_relative,
                    require_directory_immutable=False,
                )
                _seal_descendant_directories_descriptor(final_descriptor)
                _require_expected_published_directory(
                    parent_descriptor,
                    final.name,
                    final_identity,
                    context="final artifact recovery before root seal",
                )
                _seal_root_descriptor(final_descriptor, final_identity)
                os.fsync(parent_descriptor)
                _verify_manifest_descriptor(
                    final_descriptor,
                    existing,
                    metadata_relative=metadata_relative,
                    require_directory_immutable=True,
                )
                _require_expected_published_directory(
                    parent_descriptor,
                    final.name,
                    final_identity,
                    context="final artifact recovery after root seal",
                )
                _same_identity(
                    partial.parent,
                    parent_identity,
                    label="artifact parent",
                )
                return final
            finally:
                os.close(final_descriptor)

        if not stat.S_ISDIR(partial_metadata.st_mode):
            raise RuntimeCorrectionArtifactError(
                "partial artifact directory is not a real directory"
            )
        partial_identity = partial_metadata

        _require_absent_at(
            parent_descriptor,
            final.name,
            label="final artifact directory",
        )
        partial_descriptor = _open_directory(partial)
        try:
            opened_partial = os.fstat(partial_descriptor)
            if (opened_partial.st_dev, opened_partial.st_ino) != (
                partial_identity.st_dev,
                partial_identity.st_ino,
            ):
                raise RuntimeCorrectionArtifactError(
                    "partial artifact directory changed while being opened"
                )
            existing = _read_existing_manifest_descriptor(partial_descriptor)
            if existing is None:
                recovery_actions = _scan_recognized_manifest_temporaries(
                    partial_descriptor,
                )
                ignored_paths = [
                    str(action["path"]) for action in recovery_actions
                ]
                created_utc = _utc_now()
            else:
                recovery_actions = list(existing.get("recovery_actions", []))
                _delete_recorded_manifest_temporaries(
                    partial_descriptor,
                    recovery_actions=recovery_actions,
                )
                unrecorded = _scan_recognized_manifest_temporaries(
                    partial_descriptor,
                )
                if unrecorded:
                    raise RuntimeCorrectionArtifactError(
                        "existing manifest has an unrecorded temporary"
                    )
                created_utc = existing.get("created_utc")
                ignored_paths = []
            parsed_created = _parse_utc(created_utc, label="created UTC")
            if parsed_created < parsed_finished:
                raise RuntimeCorrectionArtifactError(
                    "created UTC precedes finished UTC"
                )
            manifest, snapshots = _build_manifest(
                root_descriptor=partial_descriptor,
                metadata_relative=metadata_relative,
                run_id=run_id,
                run_uuid=run_uuid,
                started_utc=started_utc,
                finished_utc=finished_utc,
                created_utc=str(created_utc),
                root_label=root_label,
                repository_state=repository_state,
                working_tree_clean=working_tree_clean,
                recovery_actions=recovery_actions,
                ignored_paths=ignored_paths,
            )
            _require_repository_state_unchanged(
                repository_state,
                working_tree_clean,
            )
            if existing is None:
                _atomic_publish_new_manifest(
                    partial_descriptor,
                    canonical_json_bytes(manifest) + b"\n",
                )
                _delete_recorded_manifest_temporaries(
                    partial_descriptor,
                    recovery_actions=recovery_actions,
                )
                if _scan_recognized_manifest_temporaries(
                    partial_descriptor,
                ):
                    raise RuntimeCorrectionArtifactError(
                        "manifest publication left an unrecorded temporary"
                    )
            elif existing != manifest:
                raise RuntimeCorrectionArtifactError(
                    "existing partial artifact manifest identity differs"
                )
            _verify_descriptor_snapshots_unchanged(
                partial_descriptor,
                snapshots,
            )
            _freeze_tree_descriptor(partial_descriptor)
            _verify_manifest_descriptor(
                partial_descriptor,
                manifest,
                metadata_relative=metadata_relative,
                require_directory_immutable=False,
            )
            _seal_descendant_directories_descriptor(partial_descriptor)
            _require_repository_state_unchanged(
                repository_state,
                working_tree_clean,
            )
            current_source = _stat_directory_at(
                parent_descriptor,
                partial.name,
                label="partial artifact directory",
            )
            if (current_source.st_dev, current_source.st_ino) != (
                partial_identity.st_dev,
                partial_identity.st_ino,
            ) or (
                os.fstat(partial_descriptor).st_dev,
                os.fstat(partial_descriptor).st_ino,
            ) != (partial_identity.st_dev, partial_identity.st_ino):
                raise RuntimeCorrectionArtifactError(
                    "partial artifact identity changed before publication"
                )
            _same_identity(partial.parent, parent_identity, label="artifact parent")
            _require_absent_at(
                parent_descriptor,
                final.name,
                label="final artifact directory",
            )
            _rename_exclusive_at(
                parent_descriptor,
                partial.name,
                parent_descriptor,
                final.name,
            )
            os.fsync(parent_descriptor)
            _require_expected_published_directory(
                parent_descriptor,
                final.name,
                partial_identity,
                context="initial artifact publication",
            )
            try:
                _require_absent_at(
                    parent_descriptor,
                    partial.name,
                    label="partial artifact directory after publication",
                )
            except RuntimeCorrectionArtifactError as error:
                quarantine = _quarantine_final(parent_descriptor, final.name)
                raise RuntimeCorrectionArtifactError(
                    "partial artifact name reappeared after publication; "
                    f"quarantined final as {quarantine}"
                ) from error
            _same_identity(partial.parent, parent_identity, label="artifact parent")
            _seal_root_descriptor(partial_descriptor, partial_identity)
            os.fsync(parent_descriptor)
            _require_expected_published_directory(
                parent_descriptor,
                final.name,
                partial_identity,
                context="initial artifact publication after root seal",
            )
            _verify_manifest_descriptor(
                partial_descriptor,
                manifest,
                metadata_relative=metadata_relative,
                require_directory_immutable=True,
            )
            _same_identity(partial.parent, parent_identity, label="artifact parent")
            return final
        finally:
            os.close(partial_descriptor)
    finally:
        os.close(parent_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--partial", type=Path, required=True)
    parser.add_argument("--final", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-uuid", required=True)
    parser.add_argument("--started-utc", required=True)
    parser.add_argument("--finished-utc", required=True)
    parser.add_argument("--root-label", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    result = finalize_runtime_correction(
        partial=arguments.partial,
        final=arguments.final,
        metadata_path=arguments.metadata,
        run_id=arguments.run_id,
        run_uuid=arguments.run_uuid,
        started_utc=arguments.started_utc,
        finished_utc=arguments.finished_utc,
        root_label=arguments.root_label,
    )
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
