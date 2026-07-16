"""Single-transaction publisher for the immutable P06 spatial release lock."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
import traceback
import uuid
from typing import Mapping

from validation.calibration_v2.native_adapter.factory import (
    NativeSwiftBuilder,
    P00NativeBuilder,
)
from validation.calibration_v2.macos_code_identity import static_code_identity
from validation.calibration_v2.release_lock import (
    P06_TRANSACTION_TOKEN_NAME,
    ReleaseLockError,
    build_configuration_lock_from_bindings,
    build_locked_quality_policy,
    build_lut_manifest,
    build_native_parity_manifest,
    build_p06_release_bundle_manifest,
    locked_compiler_input_document,
    locked_metric_policy_document,
    operator_bank_document,
    route_analysis_grid_selection_document,
    validate_dispatch_measurement_document,
    validate_p06_release_bundle_manifest,
    video_mapping_document,
)
from validation.calibration_v2.release_evidence import (
    IMPLEMENTATION_IDS,
    NATIVE_BENCHMARK_PROOF_NODE_ID,
    NATIVE_INTEGRATION_TEST_IDS,
    P00_FAILURE_ID,
    PYTHON_TEST_RUNNER_IDS,
    RELEASE_LOCK_TEST_MODULES,
    RELEASE_RUNTIME_TEST_IDS,
    SELECTED_CONTROL_IDS,
    SUPPORT_TREE_IDS,
    TEST_EVIDENCE_IDS,
    actionable_diagnostic_counts,
    publish_p06_evidence_closure,
)
from validation.calibration_v2.tools.finalize_p06_runtime_correction import (
    RuntimeCorrectionArtifactError,
    _fchflags,
    _open_directory,
    _rename_exclusive_at,
    _require_absent_at,
    runtime_correction_repository_state,
    verify_runtime_correction_copy,
)
from validation.quality.src.mirmir_quality.holdout import HashBinding
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    manifest_sha256,
    validate_schema,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
SCHEMAS_ROOT = CALIBRATION_ROOT / "schemas"
_PYTHON_ORACLE_SOURCES = (
    "validation/calibration_v2/reference/lut_oracle.py",
    "validation/calibration_v2/tools/compile_reference_luts.py",
    "validation/calibration_v2/contracts/lut-binary-contract-v1.json",
    "validation/calibration_v2/schemas/locked-compiler-input-v1.schema.json",
)
REQUIRED_G06_TEST_EVIDENCE_IDS = TEST_EVIDENCE_IDS
G06_TEST_EVIDENCE_SCHEMA = SCHEMAS_ROOT / "g06-test-evidence-v1.schema.json"
EVIDENCE_WRAPPER_MANIFEST_SCHEMA = (
    SCHEMAS_ROOT / "evidence-wrapper-artifact-manifest-v2.schema.json"
)
G06_OUTER_WRAPPER_BINDING_SCHEMA = (
    SCHEMAS_ROOT / "g06-outer-wrapper-manifest-binding-v1.schema.json"
)
G06_OUTER_WRAPPER_MANIFEST_NAME = "artifact-manifest.json"
G06_OUTER_WRAPPER_TRANSACTION_NAME = "publication-transaction.json"
G06_COPIED_OUTER_WRAPPER_MANIFEST_NAME = (
    "g06-outer-wrapper-artifact-manifest.json"
)
G06_OUTER_WRAPPER_BINDING_NAME = "g06-outer-wrapper-manifest-binding.json"
P06_RUNTIME_CORRECTION_MANIFEST_SCHEMA = (
    SCHEMAS_ROOT / "p06-runtime-correction-artifact-manifest-v1.schema.json"
)
NATIVE_BENCHMARK_SCHEMA = (
    SCHEMAS_ROOT / "control-aggregate-cache-native-benchmark-v1.schema.json"
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
P06_TRANSACTION_MARKER_SUFFIX = ".transaction.jsonl"
P06_FAILURE_RECORD_NAME = "release-failure.json"
P06_FAILURE_MANIFEST_NAME = "release-failure-manifest.json"
P06_FAILURE_TRANSACTION_MARKER_NAME = "release-transaction-marker.jsonl"


class P06ReleaseOrchestrationError(ReleaseLockError):
    """The selected calibration run could not be published as one release lock."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _json_exact_equal(left: object, right: object) -> bool:
    return canonical_json_bytes(left) == canonical_json_bytes(right)


def _native_benchmark_schema_binding() -> Mapping[str, object]:
    payload = _read_regular(NATIVE_BENCHMARK_SCHEMA)
    return {
        "path": NATIVE_BENCHMARK_SCHEMA_REPOSITORY_PATH,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _read_regular(path: Path) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise P06ReleaseOrchestrationError(f"required file is absent: {path}") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
    ):
        raise P06ReleaseOrchestrationError(f"required path is not a regular file: {path}")
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
            raise P06ReleaseOrchestrationError("file changed while opening")
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
        or after.st_nlink != 1
        or current.st_nlink != 1
        or after.st_size != before.st_size
        or current.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or current.st_mtime_ns != before.st_mtime_ns
    ):
        raise P06ReleaseOrchestrationError("file changed while reading")
    return b"".join(chunks)


def _decode_json_object(payload: bytes, *, path: Path) -> Mapping[str, object]:
    try:
        value = json.loads(
            payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                P06ReleaseOrchestrationError(f"non-finite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P06ReleaseOrchestrationError(f"invalid JSON file: {path}") from error
    if not isinstance(value, dict):
        raise P06ReleaseOrchestrationError(f"JSON top level is not an object: {path}")
    return value


def _read_json(path: Path) -> Mapping[str, object]:
    return _decode_json_object(_read_regular(path), path=path)


def _reject_duplicate_pairs(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise P06ReleaseOrchestrationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _write_new(path: Path, payload: bytes, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o700 if executable else 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("release publication made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _read_regular(path) != payload:
        raise P06ReleaseOrchestrationError(f"published bytes changed: {path}")


def _write_json(path: Path, document: Mapping[str, object]) -> None:
    _write_new(path, canonical_json_bytes(document) + b"\n")


def _copy_new(source: Path, destination: Path, *, executable: bool = False) -> None:
    _write_new(destination, _read_regular(source), executable=executable)


def _identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def _reject_aliased_directory(path: Path, *, label: str) -> os.stat_result:
    absolute = Path(os.path.abspath(path))
    cursor = Path(absolute.anchor)
    candidates = [cursor]
    for part in absolute.parts[1:]:
        cursor /= part
        candidates.append(cursor)
    for candidate in candidates:
        try:
            metadata = os.lstat(candidate)
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                f"{label} is unavailable: {candidate}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise P06ReleaseOrchestrationError(
                f"{label} traverses a symbolic alias: {candidate}"
            )
        if not stat.S_ISDIR(metadata.st_mode):
            raise P06ReleaseOrchestrationError(
                f"{label} ancestor is not a directory: {candidate}"
            )
    return os.stat(absolute, follow_symlinks=False)


def _require_parent_path_identity(
    path: Path,
    expected: os.stat_result,
) -> None:
    try:
        current = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise P06ReleaseOrchestrationError(
            "P06 release parent became unavailable"
        ) from error
    if not stat.S_ISDIR(current.st_mode) or _identity(current) != _identity(expected):
        raise P06ReleaseOrchestrationError("P06 release parent identity changed")


def _stat_directory_at(
    parent_descriptor: int,
    name: str,
    *,
    label: str,
) -> os.stat_result:
    try:
        metadata = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise P06ReleaseOrchestrationError(f"{label} is absent") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise P06ReleaseOrchestrationError(f"{label} is not a real directory")
    return metadata


def _require_directory_identity_at(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
    *,
    label: str,
) -> None:
    current = _stat_directory_at(parent_descriptor, name, label=label)
    if _identity(current) != _identity(expected):
        raise P06ReleaseOrchestrationError(f"{label} identity changed")


def _repository_state() -> tuple[Mapping[str, object], bool]:
    try:
        return runtime_correction_repository_state()
    except RuntimeCorrectionArtifactError as error:
        raise P06ReleaseOrchestrationError(
            "repository state could not be captured"
        ) from error


def _require_repository_state(
    expected: Mapping[str, object],
    *,
    label: str,
) -> None:
    observed, clean = _repository_state()
    if not clean or observed != expected:
        raise P06ReleaseOrchestrationError(f"repository state changed {label}")


def _rename_release_exclusive_at(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    try:
        _rename_exclusive_at(
            parent_descriptor,
            source_name,
            parent_descriptor,
            destination_name,
        )
        os.fsync(parent_descriptor)
    except (OSError, RuntimeCorrectionArtifactError) as error:
        raise P06ReleaseOrchestrationError(
            f"exclusive release publication failed: {source_name}"
        ) from error


def _entry_has_directory_identity_at(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
) -> bool:
    try:
        current = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except OSError:
        return False
    return stat.S_ISDIR(current.st_mode) and _identity(current) == _identity(expected)


def _owned_release_publication_name(
    *,
    parent_descriptor: int,
    destination_name: str,
    partial_name: str,
    failed_name: str,
    expected: os.stat_result,
) -> str | None:
    matches = []
    for candidate in (destination_name, partial_name, failed_name):
        if _entry_has_directory_identity_at(parent_descriptor, candidate, expected):
            matches.append(candidate)
    if len(matches) > 1:
        raise P06ReleaseOrchestrationError(
            "owned P06 release inode appears under multiple recognized names"
        )
    for candidate in matches:
        return candidate
    return None


def _open_owned_release_directory_at(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        current = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        expected_identity = _identity(expected)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or _identity(opened) != expected_identity
            or _identity(current) != expected_identity
        ):
            raise P06ReleaseOrchestrationError(
                "failed P06 publication root identity changed while opening"
            )
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _read_regular_at(
    directory_descriptor: int,
    name: str,
) -> tuple[bytes, os.stat_result]:
    try:
        before = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise P06ReleaseOrchestrationError(
            f"descriptor-relative file is absent: {name}"
        ) from error
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise P06ReleaseOrchestrationError(
            f"descriptor-relative path is not a single-link file: {name}"
        )
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, dir_fd=directory_descriptor)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise P06ReleaseOrchestrationError(
                f"descriptor-relative file changed while opening: {name}"
            )
        if _identity(opened) != _identity(before):
            raise P06ReleaseOrchestrationError(
                f"descriptor-relative file identity changed: {name}"
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
    current = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    if (
        _identity(after) != _identity(before)
        or _identity(current) != _identity(before)
        or not stat.S_ISREG(current.st_mode)
        or after.st_nlink != 1
        or current.st_nlink != 1
        or after.st_size != before.st_size
        or current.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or current.st_mtime_ns != before.st_mtime_ns
    ):
        raise P06ReleaseOrchestrationError(
            f"descriptor-relative file changed while reading: {name}"
        )
    return b"".join(chunks), after


def _write_new_at(
    directory_descriptor: int,
    name: str,
    payload: bytes,
    *,
    mode: int = 0o600,
) -> os.stat_result:
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, mode, dir_fd=directory_descriptor)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("descriptor-relative publication made no progress")
            offset += written
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    reopened, reopened_metadata = _read_regular_at(directory_descriptor, name)
    if reopened != payload or _identity(reopened_metadata) != _identity(metadata):
        raise P06ReleaseOrchestrationError(
            f"descriptor-relative published bytes changed: {name}"
        )
    os.fsync(directory_descriptor)
    return metadata


def _prepare_owned_release_for_quarantine(directory_descriptor: int) -> None:
    metadata = os.fstat(directory_descriptor)
    if hasattr(stat, "UF_IMMUTABLE") and getattr(
        metadata, "st_flags", 0
    ) & stat.UF_IMMUTABLE:
        _fchflags(
            directory_descriptor,
            metadata.st_flags & ~stat.UF_IMMUTABLE,
        )
    os.fchmod(directory_descriptor, 0o700)
    os.fsync(directory_descriptor)


def _release_tree_snapshot(
    root_descriptor: int,
    *,
    require_frozen: bool,
    require_root_frozen: bool = True,
) -> tuple[tuple[object, ...], ...]:
    if require_frozen and not hasattr(stat, "UF_IMMUTABLE"):
        raise P06ReleaseOrchestrationError(
            "macOS user-immutable flags are required for P06 release sealing"
        )
    records: list[tuple[object, ...]] = []
    def walk_error(error: OSError) -> None:
        raise P06ReleaseOrchestrationError(
            "P06 release tree could not be traversed"
        ) from error

    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        file_names.sort()
        relative_directory = PurePosixPath(directory).as_posix()
        if relative_directory == ".":
            relative_directory = ""
        directory_metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(directory_metadata.st_mode):
            raise P06ReleaseOrchestrationError(
                "P06 release tree contains a non-directory traversal root"
            )
        is_root = relative_directory == ""
        if require_frozen and (
            directory_metadata.st_mode
            & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
            or (
                (require_root_frozen or not is_root)
                and not getattr(directory_metadata, "st_flags", 0)
                & stat.UF_IMMUTABLE
            )
        ):
            raise P06ReleaseOrchestrationError(
                "P06 release directory is not sealed"
            )
        records.append(
            (
                relative_directory,
                "directory",
                directory_metadata.st_dev,
                directory_metadata.st_ino,
            )
        )
        for name in directory_names:
            metadata = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(metadata.st_mode):
                raise P06ReleaseOrchestrationError(
                    "P06 release tree contains a symbolic directory"
                )
        for name in file_names:
            before = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise P06ReleaseOrchestrationError(
                    "P06 release tree contains a non-regular file"
                )
            flags = (
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0)
            )
            file_descriptor = os.open(name, flags, dir_fd=descriptor)
            try:
                opened = os.fstat(file_descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_nlink != 1
                    or (opened.st_dev, opened.st_ino)
                    != (before.st_dev, before.st_ino)
                ):
                    raise P06ReleaseOrchestrationError(
                        "P06 release file changed while opening"
                    )
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(file_descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                after = os.fstat(file_descriptor)
                current = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (
                    (after.st_dev, after.st_ino)
                    != (before.st_dev, before.st_ino)
                    or (current.st_dev, current.st_ino)
                    != (before.st_dev, before.st_ino)
                    or after.st_size != before.st_size
                    or current.st_size != before.st_size
                    or after.st_mtime_ns != before.st_mtime_ns
                    or current.st_mtime_ns != before.st_mtime_ns
                ):
                    raise P06ReleaseOrchestrationError(
                        "P06 release file changed while hashing"
                    )
                if require_frozen and (
                    opened.st_mode
                    & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
                    or not getattr(opened, "st_flags", 0) & stat.UF_IMMUTABLE
                ):
                    raise P06ReleaseOrchestrationError(
                        "P06 release file is not sealed"
                    )
                relative = (
                    PurePosixPath(relative_directory) / name
                    if relative_directory
                    else PurePosixPath(name)
                ).as_posix()
                records.append(
                    (
                        relative,
                        "regular_file",
                        before.st_dev,
                        before.st_ino,
                        before.st_size,
                        digest.hexdigest(),
                        before.st_mode
                        & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH),
                    )
                )
            finally:
                os.close(file_descriptor)
    records.sort(key=lambda record: (str(record[0]), str(record[1])))
    if not records:
        raise P06ReleaseOrchestrationError("P06 release tree is empty")
    return tuple(records)


def _support_tree_snapshot(root_descriptor: int) -> tuple[object, ...]:
    content_snapshot = _release_tree_snapshot(
        root_descriptor,
        require_frozen=False,
    )
    metadata_records: list[tuple[object, ...]] = []

    def walk_error(error: OSError) -> None:
        raise P06ReleaseOrchestrationError(
            "P06 support tree could not be traversed"
        ) from error

    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        file_names.sort()
        relative_directory = "" if directory == "." else directory[2:]
        directory_metadata = os.fstat(descriptor)
        metadata_records.append(
            (
                relative_directory,
                "directory",
                directory_metadata.st_dev,
                directory_metadata.st_ino,
                stat.S_IMODE(directory_metadata.st_mode),
                getattr(directory_metadata, "st_flags", 0),
                directory_metadata.st_mtime_ns,
            )
        )
        for name in directory_names:
            child = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(child.st_mode):
                raise P06ReleaseOrchestrationError(
                    "P06 support tree contains a symbolic directory"
                )
        for name in file_names:
            payload, child = _read_regular_at(descriptor, name)
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            metadata_records.append(
                (
                    relative,
                    "regular_file",
                    child.st_dev,
                    child.st_ino,
                    len(payload),
                    _sha256(payload),
                    stat.S_IMODE(child.st_mode),
                    getattr(child, "st_flags", 0),
                    child.st_mtime_ns,
                )
            )
    metadata_records.sort(key=lambda record: (str(record[0]), str(record[1])))
    return content_snapshot, tuple(metadata_records)


def _open_support_tree_snapshots(
    support_roots: Mapping[str, Path],
) -> dict[str, tuple[Path, int, os.stat_result, tuple[object, ...]]]:
    snapshots: dict[
        str,
        tuple[Path, int, os.stat_result, tuple[object, ...]],
    ] = {}
    try:
        for identifier, raw_path in sorted(support_roots.items()):
            path = Path(os.path.abspath(raw_path))
            expected = _reject_aliased_directory(
                path,
                label=f"P06 support tree {identifier}",
            )
            descriptor = _open_directory(path)
            try:
                opened = os.fstat(descriptor)
                if _identity(opened) != _identity(expected):
                    raise P06ReleaseOrchestrationError(
                        f"P06 support tree changed while opening: {identifier}"
                    )
                snapshot = _support_tree_snapshot(descriptor)
            except Exception:
                os.close(descriptor)
                raise
            snapshots[identifier] = (path, descriptor, expected, snapshot)
    except Exception:
        for _, descriptor, _, _ in snapshots.values():
            os.close(descriptor)
        raise
    return snapshots


def _verify_support_tree_snapshots(
    snapshots: Mapping[
        str,
        tuple[Path, int, os.stat_result, tuple[object, ...]],
    ],
) -> None:
    for identifier, (path, descriptor, expected, snapshot) in sorted(
        snapshots.items()
    ):
        try:
            current = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                f"P06 support tree became unavailable: {identifier}"
            ) from error
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(current.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or _identity(current) != _identity(expected)
            or _identity(opened) != _identity(expected)
        ):
            raise P06ReleaseOrchestrationError(
                f"P06 support tree identity changed: {identifier}"
            )
        if _support_tree_snapshot(descriptor) != snapshot:
            raise P06ReleaseOrchestrationError(
                f"P06 support tree content or metadata changed: {identifier}"
            )


def _close_support_tree_snapshots(
    snapshots: Mapping[
        str,
        tuple[Path, int, os.stat_result, tuple[object, ...]],
    ],
) -> None:
    for _, descriptor, _, _ in snapshots.values():
        os.close(descriptor)


def _freeze_release_descendants(
    root_descriptor: int,
    *,
    expected_root_identity: os.stat_result,
) -> None:
    if not hasattr(stat, "UF_IMMUTABLE"):
        raise P06ReleaseOrchestrationError(
            "macOS user-immutable flags are required for P06 release sealing"
        )
    def walk_error(error: OSError) -> None:
        raise P06ReleaseOrchestrationError(
            "P06 release tree could not be traversed while sealing"
        ) from error

    for _, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            metadata = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(metadata.st_mode):
                raise P06ReleaseOrchestrationError(
                    "P06 release tree contains a symbolic directory"
                )
        for name in file_names:
            before = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise P06ReleaseOrchestrationError(
                    "P06 release tree contains a non-regular file before sealing"
                )
            file_descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=descriptor,
            )
            try:
                metadata = os.fstat(file_descriptor)
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_nlink != 1
                    or _identity(metadata) != _identity(before)
                ):
                    raise P06ReleaseOrchestrationError(
                        "P06 release file changed before sealing"
                    )
                executable_bits = metadata.st_mode & (
                    stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
                )
                sealed_mode = 0o444 | executable_bits
                file_flags = getattr(metadata, "st_flags", 0)
                if file_flags & stat.UF_IMMUTABLE:
                    if metadata.st_mode & 0o777 != sealed_mode:
                        raise P06ReleaseOrchestrationError(
                            "immutable P06 release file has an invalid mode"
                        )
                else:
                    os.fchmod(file_descriptor, sealed_mode)
                    _fchflags(
                        file_descriptor,
                        file_flags | stat.UF_IMMUTABLE,
                    )
                os.fsync(file_descriptor)
            finally:
                os.close(file_descriptor)
        directory_metadata = os.fstat(descriptor)
        directory_flags = getattr(directory_metadata, "st_flags", 0)
        if directory_flags & stat.UF_IMMUTABLE:
            if directory_metadata.st_mode & 0o777 != 0o555:
                raise P06ReleaseOrchestrationError(
                    "immutable P06 release directory has an invalid mode"
                )
        else:
            os.fchmod(descriptor, 0o555)
        os.fsync(descriptor)
    for directory, _, _, descriptor in os.fwalk(
        ".",
        topdown=False,
        onerror=walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        if directory == ".":
            continue
        metadata = os.fstat(descriptor)
        if not getattr(metadata, "st_flags", 0) & stat.UF_IMMUTABLE:
            _fchflags(descriptor, metadata.st_flags | stat.UF_IMMUTABLE)
        os.fsync(descriptor)
    root_metadata = os.fstat(root_descriptor)
    if (root_metadata.st_dev, root_metadata.st_ino) != (
        expected_root_identity.st_dev,
        expected_root_identity.st_ino,
    ):
        raise P06ReleaseOrchestrationError(
            "P06 release root identity changed before sealing"
        )
    if getattr(root_metadata, "st_flags", 0) & stat.UF_IMMUTABLE:
        raise P06ReleaseOrchestrationError(
            "P06 release root was sealed before public rename"
        )
    os.fchmod(root_descriptor, 0o555)
    os.fsync(root_descriptor)


def _seal_release_root(
    root_descriptor: int,
    *,
    expected_root_identity: os.stat_result,
) -> None:
    metadata = os.fstat(root_descriptor)
    if _identity(metadata) != _identity(expected_root_identity):
        raise P06ReleaseOrchestrationError(
            "P06 release root identity changed before final sealing"
        )
    if metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
        raise P06ReleaseOrchestrationError(
            "P06 release root is writable before final sealing"
        )
    flags = getattr(metadata, "st_flags", 0)
    if not flags & stat.UF_IMMUTABLE:
        _fchflags(root_descriptor, flags | stat.UF_IMMUTABLE)
    os.fsync(root_descriptor)


def _transaction_event(
    *,
    transaction_id: str,
    sequence: int,
    stage: str,
    destination_name: str,
    partial_name: str,
    failed_name: str,
    locked_utc: str,
    repository_state: Mapping[str, object],
    parent_identity: os.stat_result,
    root_identity: os.stat_result | None,
) -> Mapping[str, object]:
    event: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_release_transaction_event",
        "transaction_id": transaction_id,
        "sequence": sequence,
        "stage": stage,
        "destination_name": destination_name,
        "partial_name": partial_name,
        "failed_name": failed_name,
        "locked_utc": locked_utc,
        "repository_state": dict(repository_state),
        "parent_device": parent_identity.st_dev,
        "parent_inode": parent_identity.st_ino,
        "root_device": None if root_identity is None else root_identity.st_dev,
        "root_inode": None if root_identity is None else root_identity.st_ino,
        "holdout_accessed": False,
    }
    event["event_sha256"] = _sha256(canonical_json_bytes(event))
    return event


def _append_descriptor_bytes(
    descriptor: int,
    payload: bytes,
    *,
    label: str,
) -> None:
    if not payload:
        return
    before = os.fstat(descriptor)
    offset = os.lseek(descriptor, 0, os.SEEK_END)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size != offset
    ):
        raise P06ReleaseOrchestrationError(
            f"{label} is invalid before append"
        )
    try:
        written_total = 0
        while written_total < len(payload):
            written = os.write(descriptor, payload[written_total:])
            if written <= 0:
                raise OSError(f"{label} append made no progress")
            written_total += written
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if (
            _identity(after) != _identity(before)
            or after.st_nlink != 1
            or after.st_size != offset + len(payload)
        ):
            raise P06ReleaseOrchestrationError(
                f"{label} changed during append"
            )
    except BaseException as append_error:
        try:
            os.ftruncate(descriptor, offset)
            os.fsync(descriptor)
            rolled_back = os.fstat(descriptor)
            if (
                _identity(rolled_back) != _identity(before)
                or rolled_back.st_nlink != 1
                or rolled_back.st_size != offset
            ):
                raise P06ReleaseOrchestrationError(
                    f"{label} rollback differs"
                )
        except BaseException as rollback_error:
            raise P06ReleaseOrchestrationError(
                f"{label} append and rollback were incomplete"
            ) from rollback_error
        if isinstance(append_error, P06ReleaseOrchestrationError):
            raise
        raise P06ReleaseOrchestrationError(
            f"{label} append was incomplete"
        ) from append_error


def _transaction_marker_creation_id_at(
    parent_descriptor: int,
    marker_name: str,
) -> str | None:
    prefix = f"{marker_name}.creating-"
    names = sorted(
        name for name in os.listdir(parent_descriptor) if name.startswith(prefix)
    )
    if not names:
        return None
    if len(names) != 1:
        raise P06ReleaseOrchestrationError(
            "multiple P06 transaction marker creation stages exist"
        )
    transaction_id = names[0][len(prefix) :]
    if re.fullmatch(r"[0-9a-f]{32}", transaction_id) is None:
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker creation stage name is invalid"
        )
    return transaction_id


def _transaction_append_entries_at(
    parent_descriptor: int,
    marker_name: str,
) -> tuple[tuple[str, str, int, str, bool], ...]:
    prefix = f"{marker_name}.append-"
    names = sorted(
        name for name in os.listdir(parent_descriptor) if name.startswith(prefix)
    )
    entries = []
    pattern = re.compile(
        rf"{re.escape(prefix)}([0-9a-f]{{32}})-([0-9]+)-"
        r"([0-9a-f]{64})(\.creating)?"
    )
    for name in names:
        match = pattern.fullmatch(name)
        if match is None:
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar name is invalid"
            )
        sequence_text = match.group(2)
        sequence = int(sequence_text)
        if str(sequence) != sequence_text:
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar sequence is not canonical"
            )
        entries.append(
            (
                name,
                match.group(1),
                sequence,
                match.group(3),
                match.group(4) is not None,
            )
        )
    if len(entries) > 1:
        raise P06ReleaseOrchestrationError(
            "multiple P06 transaction append sidecars exist"
        )
    return tuple(entries)


def _unlink_owned_transaction_file(
    parent_descriptor: int,
    name: str,
    expected: os.stat_result,
) -> None:
    current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        _identity(current) != _identity(expected)
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
    ):
        raise P06ReleaseOrchestrationError(
            "P06 transaction staging file was replaced before removal"
        )
    os.unlink(name, dir_fd=parent_descriptor)
    os.fsync(parent_descriptor)


def _rename_transaction_file_exclusive_at(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    try:
        _rename_exclusive_at(
            parent_descriptor,
            source_name,
            parent_descriptor,
            destination_name,
        )
        os.fsync(parent_descriptor)
    except (OSError, RuntimeCorrectionArtifactError) as error:
        raise P06ReleaseOrchestrationError(
            f"exclusive P06 transaction file publication failed: {source_name}"
        ) from error


def _validated_transaction_event(
    event: Mapping[str, object],
    *,
    expected_sequence: int,
) -> None:
    supplied_hash = event.get("event_sha256")
    body = dict(event)
    body.pop("event_sha256", None)
    if (
        event.get("schema_version") != "1.0.0"
        or event.get("artifact_kind") != "p06_release_transaction_event"
        or event.get("sequence") != expected_sequence
        or supplied_hash != _sha256(canonical_json_bytes(body))
    ):
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker event is invalid"
        )


def _transaction_invariants_match(
    left: Mapping[str, object],
    right: Mapping[str, object],
) -> bool:
    invariant_fields = (
        "transaction_id",
        "destination_name",
        "partial_name",
        "failed_name",
        "locked_utc",
        "repository_state",
        "parent_device",
        "parent_inode",
        "holdout_accessed",
    )
    return all(left.get(field) == right.get(field) for field in invariant_fields)


def _append_transaction_event(
    parent_descriptor: int,
    marker_name: str,
    marker_descriptor: int,
    event: Mapping[str, object],
) -> None:
    payload = canonical_json_bytes(event) + b"\n"
    sequence = event.get("sequence")
    transaction_id = event.get("transaction_id")
    event_sha256 = event.get("event_sha256")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or re.fullmatch(r"[0-9a-f]{32}", str(transaction_id)) is None
        or re.fullmatch(r"[0-9a-f]{64}", str(event_sha256)) is None
    ):
        raise P06ReleaseOrchestrationError(
            "P06 transaction append event identity is invalid"
        )
    _validated_transaction_event(event, expected_sequence=sequence)
    if _transaction_append_entries_at(parent_descriptor, marker_name):
        raise P06ReleaseOrchestrationError(
            "a P06 transaction append sidecar already exists"
        )
    sidecar_name = (
        f"{marker_name}.append-{transaction_id}-{sequence}-{event_sha256}"
    )
    creation_name = f"{sidecar_name}.creating"
    flags = os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    creation_descriptor = os.open(
        creation_name,
        flags,
        0o600,
        dir_fd=parent_descriptor,
    )
    creation_identity = os.fstat(creation_descriptor)
    sidecar_identity: os.stat_result | None = None
    try:
        _append_descriptor_bytes(
            creation_descriptor,
            payload,
            label="P06 transaction append sidecar",
        )
        os.close(creation_descriptor)
        creation_descriptor = -1
        staged_payload, staged = _read_regular_at(
            parent_descriptor,
            creation_name,
        )
        if (
            staged_payload != payload
            or _identity(staged) != _identity(creation_identity)
        ):
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar differs before publication"
            )
        _rename_transaction_file_exclusive_at(
            parent_descriptor,
            creation_name,
            sidecar_name,
        )
        sidecar_identity = os.stat(
            sidecar_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if _identity(sidecar_identity) != _identity(creation_identity):
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar identity changed"
            )
        try:
            _append_descriptor_bytes(
                marker_descriptor,
                payload,
                label="P06 transaction marker",
            )
        except BaseException:
            _unlink_owned_transaction_file(
                parent_descriptor,
                sidecar_name,
                sidecar_identity,
            )
            raise
        _unlink_owned_transaction_file(
            parent_descriptor,
            sidecar_name,
            sidecar_identity,
        )
    except BaseException:
        if creation_descriptor >= 0:
            os.close(creation_descriptor)
        try:
            current = os.stat(
                creation_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            if _identity(current) == _identity(creation_identity):
                _unlink_owned_transaction_file(
                    parent_descriptor,
                    creation_name,
                    creation_identity,
                )
        raise


def _create_transaction_marker(
    parent_descriptor: int,
    marker_name: str,
    event: Mapping[str, object],
) -> tuple[int, os.stat_result]:
    transaction_id = event.get("transaction_id")
    if re.fullmatch(r"[0-9a-f]{32}", str(transaction_id)) is None:
        raise P06ReleaseOrchestrationError(
            "initial P06 transaction ID is invalid"
        )
    staging_name = f"{marker_name}.creating-{transaction_id}"
    expected_payload = canonical_json_bytes(event) + b"\n"
    flags = os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(
            staging_name,
            flags,
            0o600,
            dir_fd=parent_descriptor,
        )
        staging_identity = os.fstat(descriptor)
        staged_payload = b""
    except FileExistsError:
        staged_payload, staging_identity = _read_regular_at(
            parent_descriptor,
            staging_name,
        )
        if not expected_payload.startswith(staged_payload):
            raise P06ReleaseOrchestrationError(
                "interrupted P06 transaction marker creation differs"
            )
        descriptor = os.open(
            staging_name,
            os.O_RDWR
            | os.O_APPEND
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0),
            dir_fd=parent_descriptor,
        )
    try:
        opened = os.fstat(descriptor)
        if (
            _identity(opened) != _identity(staging_identity)
            or opened.st_nlink != 1
            or opened.st_size != len(staged_payload)
        ):
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker creation stage changed while opening"
            )
        _append_descriptor_bytes(
            descriptor,
            expected_payload[len(staged_payload) :],
            label="P06 transaction marker creation stage",
        )
        os.close(descriptor)
        descriptor = -1
        payload, staged = _read_regular_at(parent_descriptor, staging_name)
        if (
            payload != expected_payload
            or _identity(staged) != _identity(staging_identity)
        ):
            raise P06ReleaseOrchestrationError(
                "staged P06 transaction marker differs before publication"
            )
        _rename_transaction_file_exclusive_at(
            parent_descriptor,
            staging_name,
            marker_name,
        )
        marker_descriptor, marker_identity, events = _read_transaction_marker_at(
            parent_descriptor,
            marker_name,
        )
        if (
            _identity(marker_identity) != _identity(staging_identity)
            or len(events) != 1
            or not _json_exact_equal(events[0], event)
        ):
            os.close(marker_descriptor)
            raise P06ReleaseOrchestrationError(
                "published P06 transaction marker differs"
            )
        return marker_descriptor, marker_identity
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            current = os.stat(
                staging_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            if _identity(current) == _identity(staging_identity):
                os.unlink(staging_name, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
        raise


def _validated_transaction_events(
    payload: bytes,
    *,
    marker_name: str,
) -> tuple[Mapping[str, object], ...]:
    if not payload.endswith(b"\n"):
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker has an incomplete final event"
        )
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker is not UTF-8"
        ) from error
    if not lines:
        raise P06ReleaseOrchestrationError("P06 transaction marker is empty")
    events = []
    for sequence, line in enumerate(lines):
        event = _decode_json_object(line.encode("utf-8"), path=Path(marker_name))
        _validated_transaction_event(event, expected_sequence=sequence)
        if events and not _transaction_invariants_match(event, events[0]):
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker identity changed"
            )
        events.append(event)
    return tuple(events)


def _read_transaction_marker_at(
    parent_descriptor: int,
    marker_name: str,
    *,
    expected_identity: os.stat_result | None = None,
) -> tuple[int, os.stat_result, tuple[Mapping[str, object], ...]]:
    original_payload, expected = _read_regular_at(parent_descriptor, marker_name)
    if (
        expected_identity is not None
        and _identity(expected) != _identity(expected_identity)
    ):
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker ownership changed"
        )
    payload = original_payload
    has_incomplete_tail = not payload.endswith(b"\n")
    if has_incomplete_tail:
        final_newline = payload.rfind(b"\n")
        if final_newline < 0:
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker has an incomplete initial event"
            )
        payload = payload[: final_newline + 1]
    events = _validated_transaction_events(payload, marker_name=marker_name)
    append_entries = _transaction_append_entries_at(
        parent_descriptor,
        marker_name,
    )
    sidecar_name: str | None = None
    sidecar_identity: os.stat_result | None = None
    recover_incomplete_tail = False
    if append_entries:
        (
            sidecar_name,
            sidecar_transaction_id,
            sidecar_sequence,
            sidecar_event_sha256,
            sidecar_is_creating,
        ) = append_entries[0]
        sidecar_payload, sidecar_identity = _read_regular_at(
            parent_descriptor,
            sidecar_name,
        )
        if (
            sidecar_transaction_id != events[0].get("transaction_id")
            or (
                sidecar_sequence != len(events)
                and sidecar_sequence != len(events) - 1
            )
        ):
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar identity differs"
            )
        if sidecar_is_creating:
            if has_incomplete_tail or sidecar_sequence != len(events):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction marker tail has no durable append intent"
                )
            if not sidecar_payload.endswith(b"\n"):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction append creation stage is incomplete"
                )
            staged_event = _decode_json_object(
                sidecar_payload[:-1],
                path=Path(sidecar_name),
            )
            _validated_transaction_event(
                staged_event,
                expected_sequence=sidecar_sequence,
            )
            if (
                staged_event.get("event_sha256") != sidecar_event_sha256
                or not _transaction_invariants_match(
                    staged_event,
                    events[0],
                )
            ):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction append creation stage differs"
                )
        else:
            if not sidecar_payload.endswith(b"\n"):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction append sidecar is incomplete"
                )
            try:
                sidecar_event = _decode_json_object(
                    sidecar_payload[:-1],
                    path=Path(sidecar_name),
                )
            except P06ReleaseOrchestrationError:
                raise
            _validated_transaction_event(
                sidecar_event,
                expected_sequence=sidecar_sequence,
            )
            if (
                sidecar_event.get("event_sha256") != sidecar_event_sha256
                or not _transaction_invariants_match(sidecar_event, events[0])
            ):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction append sidecar differs"
                )
            if has_incomplete_tail:
                tail = original_payload[len(payload) :]
                if (
                    sidecar_sequence != len(events)
                    or not tail
                    or not sidecar_payload.startswith(tail)
                ):
                    raise P06ReleaseOrchestrationError(
                        "P06 transaction marker tail differs from durable append intent"
                    )
                recover_incomplete_tail = True
            elif sidecar_sequence == len(events):
                pass
            elif (
                sidecar_sequence != len(events) - 1
                or not original_payload.endswith(sidecar_payload)
                or not _json_exact_equal(events[-1], sidecar_event)
            ):
                raise P06ReleaseOrchestrationError(
                    "P06 transaction append completion differs"
                )
    elif has_incomplete_tail:
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker tail has no durable append intent"
        )
    flags = os.O_RDWR | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(marker_name, flags, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        reopened_chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            reopened_chunks.append(chunk)
        before_recovery = os.fstat(descriptor)
        current_before_recovery = os.stat(
            marker_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except BaseException:
        os.close(descriptor)
        raise
    if (
        b"".join(reopened_chunks) != original_payload
        or _identity(opened) != _identity(expected)
        or _identity(before_recovery) != _identity(expected)
        or _identity(current_before_recovery) != _identity(expected)
        or opened.st_size != expected.st_size
        or before_recovery.st_size != expected.st_size
        or current_before_recovery.st_size != expected.st_size
        or opened.st_mtime_ns != expected.st_mtime_ns
        or before_recovery.st_mtime_ns != expected.st_mtime_ns
        or current_before_recovery.st_mtime_ns != expected.st_mtime_ns
    ):
        os.close(descriptor)
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker changed while reopening"
        )
    if recover_incomplete_tail:
        try:
            os.ftruncate(descriptor, len(payload))
            os.fsync(descriptor)
            os.lseek(descriptor, 0, os.SEEK_SET)
            recovered_chunks = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                recovered_chunks.append(chunk)
            after = os.fstat(descriptor)
            current = os.stat(
                marker_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except BaseException:
            os.close(descriptor)
            raise
        if (
            b"".join(recovered_chunks) != payload
            or _identity(after) != _identity(expected)
            or _identity(current) != _identity(expected)
            or after.st_nlink != 1
            or current.st_nlink != 1
            or after.st_size != len(payload)
            or current.st_size != len(payload)
            or after.st_mtime_ns != current.st_mtime_ns
        ):
            os.close(descriptor)
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker tail recovery differs"
            )
        marker_identity = after
    else:
        marker_identity = opened
    if sidecar_name is not None and sidecar_identity is not None:
        try:
            _unlink_owned_transaction_file(
                parent_descriptor,
                sidecar_name,
                sidecar_identity,
            )
        except BaseException:
            os.close(descriptor)
            raise
    return descriptor, marker_identity, events


def _settle_owned_transaction_append_sidecar(
    parent_descriptor: int,
    marker_name: str,
    marker_descriptor: int,
    marker_identity: os.stat_result,
) -> None:
    if not _transaction_append_entries_at(parent_descriptor, marker_name):
        return
    current = os.fstat(marker_descriptor)
    if (
        _identity(current) != _identity(marker_identity)
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
    ):
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker ownership changed before sidecar recovery"
        )
    recovered_descriptor, recovered_identity, _ = _read_transaction_marker_at(
        parent_descriptor,
        marker_name,
        expected_identity=marker_identity,
    )
    try:
        if _identity(recovered_identity) != _identity(current):
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker identity changed during sidecar recovery"
            )
    finally:
        os.close(recovered_descriptor)


def _unlink_owned_marker(
    parent_descriptor: int,
    marker_name: str,
    expected: os.stat_result,
) -> None:
    try:
        current = os.stat(
            marker_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return
    if _identity(current) != _identity(expected):
        raise P06ReleaseOrchestrationError(
            "P06 transaction marker was replaced before removal"
        )
    os.unlink(marker_name, dir_fd=parent_descriptor)
    os.fsync(parent_descriptor)


def _failure_filesystem_closure(
    root_descriptor: int,
    *,
    require_frozen: bool,
) -> list[Mapping[str, object]]:
    if require_frozen and not hasattr(stat, "UF_IMMUTABLE"):
        raise P06ReleaseOrchestrationError(
            "macOS user-immutable flags are required for P06 failure evidence"
        )

    def walk_error(error: OSError) -> None:
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence tree could not be traversed"
        ) from error

    rows: list[Mapping[str, object]] = []
    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        directory_names.sort()
        file_names.sort()
        relative_directory = "" if directory == "." else directory[2:]
        directory_metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(directory_metadata.st_mode):
            raise P06ReleaseOrchestrationError(
                "P06 failure evidence contains a non-directory traversal root"
            )
        if require_frozen and (
            directory_metadata.st_mode
            & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
            or not getattr(directory_metadata, "st_flags", 0) & stat.UF_IMMUTABLE
        ):
            raise P06ReleaseOrchestrationError(
                "P06 failure evidence directory is not sealed"
            )
        if relative_directory:
            rows.append(
                {
                    "path": relative_directory,
                    "entry_kind": "directory",
                }
            )
        for name in directory_names:
            metadata = os.stat(
                name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(metadata.st_mode):
                raise P06ReleaseOrchestrationError(
                    "P06 failure evidence contains a symbolic directory"
                )
        for name in file_names:
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            if relative == P06_FAILURE_MANIFEST_NAME:
                continue
            payload, metadata = _read_regular_at(descriptor, name)
            if require_frozen and (
                metadata.st_mode
                & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
                or not getattr(metadata, "st_flags", 0) & stat.UF_IMMUTABLE
            ):
                raise P06ReleaseOrchestrationError(
                    "P06 failure evidence file is not sealed"
                )
            rows.append(
                {
                    "path": relative,
                    "entry_kind": "regular_file",
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                    "executable_mode_bits": metadata.st_mode
                    & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH),
                }
            )
    rows.sort(key=lambda row: (str(row["path"]), str(row["entry_kind"])))
    if not rows:
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence filesystem closure is empty"
        )
    return rows


def _validate_release_failure_evidence(
    root_descriptor: int,
    *,
    transaction_id: str,
    expected_marker_payload: bytes,
    require_frozen: bool,
) -> Mapping[str, object]:
    payload, metadata = _read_regular_at(
        root_descriptor,
        P06_FAILURE_MANIFEST_NAME,
    )
    manifest = _decode_json_object(
        payload,
        path=Path(P06_FAILURE_MANIFEST_NAME),
    )
    if payload != canonical_json_bytes(manifest) + b"\n":
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence manifest is not canonical"
        )
    expected_fields = {
        "schema_version",
        "artifact_kind",
        "transaction_id",
        "transaction_stage",
        "cleanup_outcome",
        "cleanup_entry_name",
        "root_device",
        "root_inode",
        "artifacts",
        "filesystem_closure_rule",
        "filesystem_closure",
        "holdout_accessed",
        "manifest_sha256",
    }
    if (
        set(manifest) != expected_fields
        or manifest.get("schema_version") != "2.0.0"
        or manifest.get("artifact_kind")
        != "p06_release_failure_evidence_manifest"
        or manifest.get("transaction_id") != transaction_id
        or manifest.get("filesystem_closure_rule")
        != "all_entries_except_failure_manifest_v1"
        or manifest.get("holdout_accessed") is not False
        or manifest.get("manifest_sha256") != manifest_sha256(manifest)
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence manifest identity differs"
        )
    root_metadata = os.fstat(root_descriptor)
    if (
        manifest.get("root_device") != root_metadata.st_dev
        or manifest.get("root_inode") != root_metadata.st_ino
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence root identity differs"
        )
    if require_frozen and (
        metadata.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
        or not getattr(metadata, "st_flags", 0) & stat.UF_IMMUTABLE
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence manifest is not sealed"
        )
    observed_closure = _failure_filesystem_closure(
        root_descriptor,
        require_frozen=require_frozen,
    )
    if manifest.get("filesystem_closure") != observed_closure:
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence filesystem closure changed"
        )
    artifacts = manifest.get("artifacts")
    closure_has_bundle = any(
        row.get("path") == "p06-release-bundle.json"
        for row in observed_closure
    )
    if (
        not isinstance(artifacts, list)
        or len(artifacts) != (3 if closure_has_bundle else 2)
        or any(not isinstance(row, dict) for row in artifacts)
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence artifact bindings differ"
        )
    expected_paths = [
        P06_FAILURE_RECORD_NAME,
        P06_FAILURE_TRANSACTION_MARKER_NAME,
    ]
    if closure_has_bundle:
        expected_paths.append("p06-release-bundle.json")
    if [row.get("path") for row in artifacts] != expected_paths:
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence artifact order differs"
        )
    for row in artifacts:
        name = str(row["path"])
        artifact_payload, _ = _read_regular_at(root_descriptor, name)
        if row != {
            "path": name,
            "sha256": _sha256(artifact_payload),
            "size_bytes": len(artifact_payload),
        }:
            raise P06ReleaseOrchestrationError(
                "P06 failure evidence artifact binding changed"
            )
    failure_payload, _ = _read_regular_at(
        root_descriptor,
        P06_FAILURE_RECORD_NAME,
    )
    failure = _decode_json_object(
        failure_payload,
        path=Path(P06_FAILURE_RECORD_NAME),
    )
    expected_failure_fields = {
        "schema_version",
        "artifact_kind",
        "transaction_id",
        "transaction_stage",
        "cleanup_outcome",
        "cleanup_entry_name",
        "error_type",
        "error",
        "traceback",
        "holdout_accessed",
        "manifest_sha256",
    }
    if (
        failure_payload != canonical_json_bytes(failure) + b"\n"
        or set(failure) != expected_failure_fields
        or failure.get("schema_version") != "1.0.0"
        or failure.get("artifact_kind")
        != "p06_release_publication_failure"
        or failure.get("transaction_id") != transaction_id
        or failure.get("transaction_stage")
        != manifest.get("transaction_stage")
        or failure.get("cleanup_outcome") != manifest.get("cleanup_outcome")
        or failure.get("cleanup_entry_name")
        != manifest.get("cleanup_entry_name")
        or failure.get("manifest_sha256") != manifest_sha256(failure)
        or failure.get("holdout_accessed") is not False
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence record identity differs"
        )
    marker_copy, _ = _read_regular_at(
        root_descriptor,
        P06_FAILURE_TRANSACTION_MARKER_NAME,
    )
    if (
        marker_copy != expected_marker_payload
        or not marker_copy
        or not marker_copy.endswith(b"\n")
    ):
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence marker copy differs from durable marker"
        )
    return manifest


def _write_release_failure_evidence(
    root_descriptor: int,
    *,
    error: BaseException,
    stage: str,
    outcome: str,
    outcome_name: str,
    transaction_id: str,
    marker_payload: bytes,
    root_identity: os.stat_result,
) -> None:
    if not marker_payload or not marker_payload.endswith(b"\n"):
        raise P06ReleaseOrchestrationError(
            "P06 failure transaction marker payload is incomplete"
        )
    _write_new_at(
        root_descriptor,
        P06_FAILURE_TRANSACTION_MARKER_NAME,
        marker_payload,
    )
    failure: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_release_publication_failure",
        "transaction_id": transaction_id,
        "transaction_stage": stage,
        "cleanup_outcome": outcome,
        "cleanup_entry_name": outcome_name,
        "error_type": type(error).__name__,
        "error": str(error),
        "traceback": "".join(
            traceback.format_exception(type(error), error, error.__traceback__)
        ),
        "holdout_accessed": False,
    }
    failure["manifest_sha256"] = manifest_sha256(failure)
    failure_payload = canonical_json_bytes(failure) + b"\n"
    _write_new_at(
        root_descriptor,
        P06_FAILURE_RECORD_NAME,
        failure_payload,
    )
    artifacts = [
        {
            "path": P06_FAILURE_RECORD_NAME,
            "sha256": _sha256(failure_payload),
            "size_bytes": len(failure_payload),
        },
        {
            "path": P06_FAILURE_TRANSACTION_MARKER_NAME,
            "sha256": _sha256(marker_payload),
            "size_bytes": len(marker_payload),
        },
    ]
    try:
        release_payload, _ = _read_regular_at(
            root_descriptor,
            "p06-release-bundle.json",
        )
    except P06ReleaseOrchestrationError:
        release_payload = None
    if release_payload is not None:
        artifacts.append(
            {
                "path": "p06-release-bundle.json",
                "sha256": _sha256(release_payload),
                "size_bytes": len(release_payload),
            }
        )
    failure_manifest: dict[str, object] = {
        "schema_version": "2.0.0",
        "artifact_kind": "p06_release_failure_evidence_manifest",
        "transaction_id": transaction_id,
        "transaction_stage": stage,
        "cleanup_outcome": outcome,
        "cleanup_entry_name": outcome_name,
        "root_device": root_identity.st_dev,
        "root_inode": root_identity.st_ino,
        "artifacts": artifacts,
        "filesystem_closure_rule": (
            "all_entries_except_failure_manifest_v1"
        ),
        "filesystem_closure": _failure_filesystem_closure(
            root_descriptor,
            require_frozen=False,
        ),
        "holdout_accessed": False,
    }
    failure_manifest["manifest_sha256"] = manifest_sha256(failure_manifest)
    _write_new_at(
        root_descriptor,
        P06_FAILURE_MANIFEST_NAME,
        canonical_json_bytes(failure_manifest) + b"\n",
    )


def _quarantine_release_publication_impl(
    *,
    parent_descriptor: int,
    destination_name: str,
    partial_name: str,
    failed_name: str,
    expected: os.stat_result,
    root_descriptor: int,
    marker_name: str,
    marker_descriptor: int,
    marker_identity: os.stat_result,
    transaction_id: str,
    stage: str,
    error: BaseException,
) -> str:
    owned = _owned_release_publication_name(
        parent_descriptor=parent_descriptor,
        destination_name=destination_name,
        partial_name=partial_name,
        failed_name=failed_name,
        expected=expected,
    )
    if owned is None:
        raise P06ReleaseOrchestrationError(
            "P06 cleanup failed: owned release inode has no recognized name"
        ) from error
    opened = os.fstat(root_descriptor)
    if _identity(opened) != _identity(expected):
        raise P06ReleaseOrchestrationError(
            "P06 cleanup failed: pinned root identity changed"
        ) from error
    _prepare_owned_release_for_quarantine(root_descriptor)
    outcome_name: str | None = failed_name if owned == failed_name else None
    rename_errors: list[BaseException] = []
    if outcome_name is None:
        candidates = [failed_name]
        candidates.extend(
            f".{destination_name}.quarantine-{uuid.uuid4().hex}" for _ in range(4)
        )
        for candidate in candidates:
            try:
                _require_absent_at(
                    parent_descriptor,
                    candidate,
                    label="P06 failure quarantine",
                )
            except RuntimeCorrectionArtifactError:
                continue
            try:
                _rename_release_exclusive_at(parent_descriptor, owned, candidate)
            except Exception as rename_error:
                rename_errors.append(rename_error)
                if _entry_has_directory_identity_at(
                    parent_descriptor,
                    candidate,
                    expected,
                ):
                    outcome_name = candidate
                    break
                continue
            if not _entry_has_directory_identity_at(
                parent_descriptor,
                candidate,
                expected,
            ):
                rename_errors.append(
                    P06ReleaseOrchestrationError(
                        "P06 cleanup rename destination identity differs"
                    )
                )
                continue
            outcome_name = candidate
            break
    if outcome_name is None and owned == destination_name:
        summary = "; ".join(
            f"{type(item).__name__}: {item}" for item in rename_errors
        ) or "all cleanup renames failed"
        raise P06ReleaseOrchestrationError(
            "P06 cleanup retained the success-named release and durable marker: "
            f"{summary}"
        ) from error
    _settle_owned_transaction_append_sidecar(
        parent_descriptor,
        marker_name,
        marker_descriptor,
        marker_identity,
    )
    marker_payload = b""
    try:
        os.lseek(marker_descriptor, 0, os.SEEK_SET)
        marker_chunks = []
        while True:
            chunk = os.read(marker_descriptor, 1024 * 1024)
            if not chunk:
                break
            marker_chunks.append(chunk)
        marker_payload = b"".join(marker_chunks)
        marker_current = os.fstat(marker_descriptor)
        if (
            _identity(marker_current) != _identity(marker_identity)
            or marker_current.st_nlink != 1
            or marker_current.st_size != len(marker_payload)
        ):
            raise P06ReleaseOrchestrationError(
                "P06 cleanup transaction marker changed while copying"
            )
    except OSError as marker_error:
        raise P06ReleaseOrchestrationError(
            "P06 cleanup failed while reading the transaction marker"
        ) from marker_error
    outcome = (
        "owned_inode_quarantined"
        if outcome_name is not None
        else "cleanup_failed_owned_inode_retained"
    )
    evidence_name = owned if outcome_name is None else outcome_name
    try:
        os.stat(
            P06_FAILURE_MANIFEST_NAME,
            dir_fd=root_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        _write_release_failure_evidence(
            root_descriptor,
            error=error,
            stage=stage,
            outcome=outcome,
            outcome_name=evidence_name,
            transaction_id=transaction_id,
            marker_payload=marker_payload,
            root_identity=expected,
        )
    else:
        _validate_release_failure_evidence(
            root_descriptor,
            transaction_id=transaction_id,
            expected_marker_payload=marker_payload,
            require_frozen=False,
        )
    _validate_release_failure_evidence(
        root_descriptor,
        transaction_id=transaction_id,
        expected_marker_payload=marker_payload,
        require_frozen=False,
    )
    before = _release_tree_snapshot(root_descriptor, require_frozen=False)
    _freeze_release_descendants(
        root_descriptor,
        expected_root_identity=expected,
    )
    _seal_release_root(
        root_descriptor,
        expected_root_identity=expected,
    )
    after = _release_tree_snapshot(root_descriptor, require_frozen=True)
    if after != before:
        raise P06ReleaseOrchestrationError(
            "P06 failure evidence tree changed while sealing"
        )
    _validate_release_failure_evidence(
        root_descriptor,
        transaction_id=transaction_id,
        expected_marker_payload=marker_payload,
        require_frozen=True,
    )
    evidence_name = owned if outcome_name is None else outcome_name
    _require_directory_identity_at(
        parent_descriptor,
        evidence_name,
        expected,
        label="sealed P06 failure evidence root",
    )
    if _transaction_append_entries_at(parent_descriptor, marker_name):
        raise P06ReleaseOrchestrationError(
            "P06 cleanup retained the durable marker because an append "
            "sidecar remains"
        )
    _unlink_owned_marker(
        parent_descriptor,
        marker_name,
        marker_identity,
    )
    if outcome_name is None:
        summary = "; ".join(
            f"{type(item).__name__}: {item}" for item in rename_errors
        ) or "all cleanup renames failed"
        raise P06ReleaseOrchestrationError(
            f"P06 cleanup failed after {type(error).__name__}: {summary}"
        ) from error
    return outcome_name


def _quarantine_release_publication(
    *,
    parent_descriptor: int,
    destination_name: str,
    partial_name: str,
    failed_name: str,
    expected: os.stat_result,
    root_descriptor: int,
    marker_name: str,
    marker_descriptor: int,
    marker_identity: os.stat_result,
    transaction_id: str,
    stage: str,
    error: BaseException,
) -> str:
    try:
        return _quarantine_release_publication_impl(
            parent_descriptor=parent_descriptor,
            destination_name=destination_name,
            partial_name=partial_name,
            failed_name=failed_name,
            expected=expected,
            root_descriptor=root_descriptor,
            marker_name=marker_name,
            marker_descriptor=marker_descriptor,
            marker_identity=marker_identity,
            transaction_id=transaction_id,
            stage=stage,
            error=error,
        )
    except P06ReleaseOrchestrationError:
        raise
    except Exception as cleanup_error:
        raise P06ReleaseOrchestrationError(
            "P06 cleanup failed while publishing durable failure evidence"
        ) from cleanup_error


def _safe_evidence_id(identifier: str) -> str:
    if (
        not isinstance(identifier, str)
        or not identifier
        or len(identifier) > 96
        or identifier[0] not in "abcdefghijklmnopqrstuvwxyz0123456789"
        or any(
            character not in "abcdefghijklmnopqrstuvwxyz0123456789._-"
            for character in identifier
        )
    ):
        raise P06ReleaseOrchestrationError("evidence ID is unsafe")
    return identifier


def _g06_raise_tree_walk_error(error: OSError) -> None:
    raise P06ReleaseOrchestrationError(
        f"G06 tree traversal failed: {error}"
    ) from error


def _copy_evidence_input(
    *,
    identifier: str,
    source: Path,
    release_root: Path,
    category: str,
) -> Path:
    identifier = _safe_evidence_id(identifier)
    source = source.resolve(strict=True)
    destination_root = release_root / category / identifier
    if source.is_symlink():
        raise P06ReleaseOrchestrationError("evidence input is symbolic")
    if source.is_file():
        destination = destination_root / source.name
        _copy_new(source, destination)
        return destination
    if not source.is_dir():
        raise P06ReleaseOrchestrationError("evidence input is not a file or directory")
    for current_name, directory_names, file_names in os.walk(
        source,
        topdown=True,
        onerror=_g06_raise_tree_walk_error,
        followlinks=False,
    ):
        current = Path(current_name)
        relative = current.relative_to(source)
        target = destination_root.joinpath(*relative.parts)
        target.mkdir(parents=True, exist_ok=True)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            if (current / name).is_symlink():
                raise P06ReleaseOrchestrationError(
                    "evidence directory contains a symbolic link"
                )
        for name in file_names:
            candidate = current / name
            if candidate.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "evidence directory contains a symbolic file"
                )
            _copy_new(candidate, target / name)
    return destination_root


def _g06_tree_binding(
    path: Path,
    *,
    artifact_id: str,
    artifact_kind: str,
) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_dir():
        raise P06ReleaseOrchestrationError(
            f"G06 tree artifact is absent or symbolic: {artifact_id}"
        )
    root = path.resolve(strict=True)
    rows: list[Mapping[str, object]] = []
    for current_name, directory_names, file_names in os.walk(
        root,
        topdown=True,
        onerror=_g06_raise_tree_walk_error,
        followlinks=False,
    ):
        current = Path(current_name)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            child = current / name
            if child.is_symlink():
                raise P06ReleaseOrchestrationError(
                    f"G06 tree artifact contains a symbolic directory: {artifact_id}"
                )
            rows.append(
                {
                    "path": child.relative_to(root).as_posix(),
                    "entry_kind": "directory",
                    "size_bytes": 0,
                }
            )
        for name in file_names:
            candidate = current / name
            if candidate.is_symlink():
                raise P06ReleaseOrchestrationError(
                    f"G06 tree artifact contains a symbolic file: {artifact_id}"
                )
            payload = _read_regular(candidate)
            rows.append(
                {
                    "path": candidate.relative_to(root).as_posix(),
                    "entry_kind": "regular_file",
                    "sha256": _sha256(payload),
                    "size_bytes": len(payload),
                }
            )
    rows.sort(key=lambda row: str(row["path"]))
    if not rows:
        raise P06ReleaseOrchestrationError(
            f"G06 tree artifact is empty: {artifact_id}"
        )
    file_rows = [row for row in rows if row["entry_kind"] == "regular_file"]
    if not file_rows:
        raise P06ReleaseOrchestrationError(
            f"G06 tree artifact contains no regular files: {artifact_id}"
        )
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "canonical_tree_manifest_sha256",
        "sha256": _sha256(canonical_json_bytes(rows)),
        "size_bytes": sum(int(row["size_bytes"]) for row in file_rows),
        "file_count": len(file_rows),
    }


def _g06_file_binding(
    path: Path,
    *,
    artifact_id: str,
    artifact_kind: str,
) -> Mapping[str, object]:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise P06ReleaseOrchestrationError(
            f"G06 file artifact is absent: {artifact_id}"
        ) from error
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
        raise P06ReleaseOrchestrationError(
            f"G06 file artifact mode or identity changed: {artifact_id}"
        )
    return {
        "artifact_id": artifact_id,
        "artifact_kind": artifact_kind,
        "digest_mode": "file_sha256",
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
        "file_count": 1,
        "executable_mode_bits": before.st_mode & 0o111,
    }


def _g06_source_binding(path: Path, repository_path: str) -> Mapping[str, object]:
    payload = _read_regular(path)
    return {
        "repository_path": repository_path,
        "sha256": _sha256(payload),
        "size_bytes": len(payload),
    }


def _verify_g06_artifact_binding(
    *,
    run_root: Path,
    binding: Mapping[str, object],
) -> Path:
    artifact_id = binding.get("artifact_id")
    artifact_kind = binding.get("artifact_kind")
    if not isinstance(artifact_id, str) or not isinstance(artifact_kind, str):
        raise P06ReleaseOrchestrationError("G06 artifact identity is invalid")
    try:
        path = _safe_child(run_root, artifact_id)
        lexical_path = run_root.resolve(strict=True).joinpath(
            *PurePosixPath(artifact_id).parts
        )
        _reject_symlinked_ancestors(lexical_path)
    except (OSError, ValueError) as error:
        raise P06ReleaseOrchestrationError(
            f"G06 artifact path is unavailable: {artifact_id}"
        ) from error
    _reject_symlinked_ancestors(path)
    digest_mode = binding.get("digest_mode")
    if digest_mode == "file_sha256":
        reopened = _g06_file_binding(
            path,
            artifact_id=artifact_id,
            artifact_kind=artifact_kind,
        )
    elif digest_mode == "canonical_tree_manifest_sha256":
        reopened = _g06_tree_binding(
            path,
            artifact_id=artifact_id,
            artifact_kind=artifact_kind,
        )
    else:
        raise P06ReleaseOrchestrationError(
            f"G06 artifact digest mode is invalid: {artifact_id}"
        )
    if reopened != dict(binding):
        raise P06ReleaseOrchestrationError(
            f"G06 artifact binding changed: {artifact_id}"
        )
    return path


def _g06_diagnostic_counts(text: str) -> Mapping[str, int]:
    return actionable_diagnostic_counts(text)


def _g06_parse_unittest_log(text: str) -> Mapping[str, object]:
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
        raise P06ReleaseOrchestrationError(
            "G06 unittest log lacks a passing terminal summary"
        )
    if re.search(r"(?m)^(?:FAILED(?: |$)|OK \()", text):
        raise P06ReleaseOrchestrationError("G06 unittest log reports failure")
    total = int(matches[0].group(1))
    if total <= 0:
        raise P06ReleaseOrchestrationError("G06 unittest count is zero")
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


def _g06_parse_pytest_log(text: str) -> Mapping[str, object]:
    nonempty_lines = [line.strip() for line in text.splitlines() if line.strip()]
    terminal = nonempty_lines[-1] if nonempty_lines else ""
    match = re.fullmatch(r"([0-9]+) passed in .+", terminal)
    if match is None:
        raise P06ReleaseOrchestrationError(
            "G06 pytest log lacks an all-passed terminal summary"
        )
    outcome_count = re.compile(
        r"(?i)(?:^|[\s,])(?:[0-9]+)\s+"
        r"(?:passed|failed|errors?|skipped|xfailed|xpassed|deselected|warnings?)"
        r"(?:$|[\s,])"
    )
    if any(outcome_count.search(line) for line in nonempty_lines[:-1]):
        raise P06ReleaseOrchestrationError(
            "G06 pytest log contains a non-terminal outcome summary"
        )
    total = int(match.group(1))
    if total <= 0:
        raise P06ReleaseOrchestrationError("G06 pytest count is zero")
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


def _g06_parse_xcresult_summary(document: Mapping[str, object]) -> Mapping[str, object]:
    names = (
        "totalTestCount",
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
    )
    values = []
    for name in names:
        value = document.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise P06ReleaseOrchestrationError(
                f"G06 xcresult count is invalid: {name}"
            )
        values.append(value)
    total, passed, failed, skipped, expected = values
    if (
        total <= 0
        or passed != total
        or failed != 0
        or skipped != 0
        or expected != 0
        or document.get("result") != "Passed"
    ):
        raise P06ReleaseOrchestrationError(
            "G06 xcresult summary is not strictly passing"
        )
    return {
        "test_count": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expected_failures": expected,
        "terminal_status": "passed",
    }


def _g06_text_artifact(
    run_root: Path,
    binding_by_id: Mapping[str, Mapping[str, object]],
    artifact_id: str,
) -> str:
    binding = binding_by_id.get(artifact_id)
    if (
        binding is None
        or binding.get("digest_mode") != "file_sha256"
        or binding.get("artifact_kind")
        not in {"command_log", "xcresult_summary"}
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 required log binding differs: {artifact_id}"
        )
    payload = _read_regular(_safe_child(run_root, artifact_id))
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise P06ReleaseOrchestrationError(
            f"G06 log is not strict UTF-8: {artifact_id}"
        ) from error


def _g06_require_artifacts(
    bindings: tuple[Mapping[str, object], ...],
    expected: tuple[tuple[str, str, str], ...],
) -> None:
    actual = tuple(
        (
            str(binding.get("artifact_id")),
            str(binding.get("artifact_kind")),
            str(binding.get("digest_mode")),
        )
        for binding in bindings
    )
    if actual != expected:
        raise P06ReleaseOrchestrationError("G06 group artifact closure differs")


def _g06_require_exact_execution_path(value: object, expected: Path) -> str:
    if (
        not isinstance(value, str)
        or not Path(value).is_absolute()
        or Path(os.path.abspath(value)) != Path(value)
        or Path(value) != expected
    ):
        raise P06ReleaseOrchestrationError(
            "G06 command contract execution path differs"
        )
    return value


def _g06_xcode_test_argv(
    *,
    configuration: str,
    derived: str,
    result_bundle: str,
    tests: tuple[str, ...],
    clean: bool,
) -> list[str]:
    return [
        "xcodebuild",
        "-project",
        "Mirmir.xcodeproj",
        "-scheme",
        "Mirmir",
        "-configuration",
        configuration,
        "-destination",
        "platform=macOS,arch=arm64",
        "-derivedDataPath",
        derived,
        "-resultBundlePath",
        result_bundle,
        "-enableCodeCoverage",
        "YES",
        "-parallel-testing-enabled",
        "NO",
        *(("-jobs", "1") if configuration == "Release" else ()),
        "CODE_SIGNING_ALLOWED=NO",
        *(("ENABLE_TESTABILITY=YES",) if configuration == "Release" else ()),
        *(f"-only-testing:MirmirTests/{name}" for name in tests),
        *(("clean", "test") if clean else ("test",)),
    ]


def _g06_require_command(
    command: Mapping[str, object],
    *,
    argv: list[str],
    log_id: str,
) -> None:
    log_binding = command.get("log_binding")
    if (
        command.get("argv") != argv
        or command.get("command_text") != shlex.join(argv)
        or not isinstance(log_binding, dict)
        or log_binding.get("artifact_id") != log_id
    ):
        raise P06ReleaseOrchestrationError("G06 command contract differs")


def _g06_declared_wrapper_closure(
    run_root: Path,
) -> tuple[set[str], set[str]]:
    """Derive the only allowed wrapper paths from the five G06 declarations."""

    run_prefix = f"g06/{run_root.name}"
    expected_files = {
        f"{run_prefix}/{identifier}.json"
        for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
    }
    expected_directories = {"g06", run_prefix}
    for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS:
        evidence_path = run_root / f"{identifier}.json"
        payload = _read_regular(evidence_path)
        document = _decode_json_object(payload, path=evidence_path)
        artifacts = document.get("artifacts")
        if not isinstance(artifacts, list):
            raise P06ReleaseOrchestrationError(
                "G06 declaration artifact closure is absent"
            )
        for binding in artifacts:
            if not isinstance(binding, dict):
                raise P06ReleaseOrchestrationError(
                    "G06 declaration artifact binding is invalid"
                )
            artifact_id = binding.get("artifact_id")
            if not isinstance(artifact_id, str):
                raise P06ReleaseOrchestrationError(
                    "G06 declaration artifact path is invalid"
                )
            relative = PurePosixPath(artifact_id)
            if (
                not artifact_id
                or artifact_id.startswith("/")
                or "\\" in artifact_id
                or relative.as_posix() != artifact_id
                or any(part in {"", ".", ".."} for part in relative.parts)
            ):
                raise P06ReleaseOrchestrationError(
                    "G06 declaration artifact path is unsafe"
                )
            artifact_path = run_root.joinpath(*relative.parts)
            for parent in relative.parents:
                if parent.as_posix() != ".":
                    expected_directories.add(
                        f"{run_prefix}/{parent.as_posix()}"
                    )
            digest_mode = binding.get("digest_mode")
            if digest_mode == "file_sha256":
                expected_files.add(f"{run_prefix}/{relative.as_posix()}")
                continue
            if digest_mode != "canonical_tree_manifest_sha256":
                raise P06ReleaseOrchestrationError(
                    "G06 declaration digest mode is invalid"
                )
            artifact_prefix = f"{run_prefix}/{relative.as_posix()}"
            expected_directories.add(artifact_prefix)
            if not artifact_path.is_dir() or artifact_path.is_symlink():
                continue
            for current_name, directory_names, file_names in os.walk(
                artifact_path,
                topdown=True,
                onerror=_g06_raise_tree_walk_error,
                followlinks=False,
            ):
                current = Path(current_name)
                current_relative = current.relative_to(artifact_path)
                current_prefix = artifact_prefix
                if current_relative.parts:
                    current_prefix = (
                        f"{artifact_prefix}/{current_relative.as_posix()}"
                    )
                    expected_directories.add(current_prefix)
                directory_names.sort()
                file_names.sort()
                for name in directory_names:
                    expected_directories.add(f"{current_prefix}/{name}")
                for name in file_names:
                    expected_files.add(f"{current_prefix}/{name}")
    return expected_files, expected_directories


def _g06_wrapper_transaction_contract(
    payload: bytes,
    *,
    wrapper_root: Path,
    wrapper_metadata: os.stat_result,
    project_commit: str,
) -> Mapping[str, object]:
    document = _decode_json_object(
        payload,
        path=wrapper_root / G06_OUTER_WRAPPER_TRANSACTION_NAME,
    )
    required = {
        "schema_version",
        "artifact_kind",
        "transaction_token",
        "created_utc",
        "project_commit",
        "partial_name",
        "final_name",
        "failure_name",
        "gate_ids",
        "root_device",
        "root_inode",
    }
    if (
        payload != canonical_json_bytes(document) + b"\n"
        or set(document) != required
        or document.get("schema_version") != "1.0.0"
        or document.get("artifact_kind")
        != "evidence_wrapper_publication_transaction"
        or not isinstance(document.get("transaction_token"), str)
        or re.fullmatch(r"[0-9a-f]{32}", str(document["transaction_token"]))
        is None
        or not isinstance(document.get("created_utc"), str)
        or re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:"
            r"[0-9]{2}(?:\.[0-9]{1,6})?Z",
            str(document["created_utc"]),
        )
        is None
        or document.get("project_commit") != project_commit
        or document.get("partial_name") != f".{wrapper_root.name}.partial"
        or document.get("final_name") != wrapper_root.name
        or document.get("failure_name") != f"{wrapper_root.name}.failed"
        or document.get("gate_ids") != ["G06", "P06"]
        or document.get("root_device") != wrapper_metadata.st_dev
        or document.get("root_inode") != wrapper_metadata.st_ino
    ):
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper transaction binding differs"
        )
    return document


def _g06_outer_wrapper_contract(run_root: Path) -> Mapping[str, object]:
    lexical_run = Path(os.path.abspath(run_root))
    if (
        not run_root.is_absolute()
        or lexical_run != run_root
        or run_root.parent.name != "g06"
        or run_root.name.startswith(".")
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", run_root.name)
        is None
    ):
        raise P06ReleaseOrchestrationError(
            "G06 evidence layout is not an exact wrapper/g06/run tree"
        )
    wrapper_root = run_root.parent.parent
    if (
        wrapper_root.name.startswith(".")
        or wrapper_root.name.endswith(".partial")
        or re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",
            wrapper_root.name,
        )
        is None
    ):
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper final name is invalid"
        )
    wrapper_metadata = _reject_aliased_directory(
        wrapper_root,
        label="G06 outer wrapper",
    )
    try:
        wrapper_descriptor = _open_directory(wrapper_root)
    except OSError as error:
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper could not be opened"
        ) from error
    try:
        opened_wrapper = os.fstat(wrapper_descriptor)
        current_wrapper = os.stat(wrapper_root, follow_symlinks=False)
        if (
            _identity(opened_wrapper) != _identity(wrapper_metadata)
            or _identity(current_wrapper) != _identity(wrapper_metadata)
        ):
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper identity changed while opening"
            )
        before = _release_tree_snapshot(
            wrapper_descriptor,
            require_frozen=True,
        )
        manifest_payload, manifest_metadata = _read_regular_at(
            wrapper_descriptor,
            G06_OUTER_WRAPPER_MANIFEST_NAME,
        )
        manifest = _decode_json_object(
            manifest_payload,
            path=wrapper_root / G06_OUTER_WRAPPER_MANIFEST_NAME,
        )
        try:
            validate_schema(manifest, EVIDENCE_WRAPPER_MANIFEST_SCHEMA)
        except ValueError as error:
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper artifact manifest schema differs"
            ) from error
        if manifest_payload != canonical_json_bytes(manifest) + b"\n":
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper artifact manifest is not canonical"
            )
        repository_state, repository_clean = _repository_state()
        project_commit = repository_state.get("project_commit")
        if (
            not repository_clean
            or not isinstance(project_commit, str)
            or re.fullmatch(r"[0-9a-f]{40}", project_commit) is None
            or manifest.get("project_commit") != project_commit
            or manifest.get("working_tree_clean") is not True
        ):
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper project provenance differs"
            )
        transaction_payload, _ = _read_regular_at(
            wrapper_descriptor,
            G06_OUTER_WRAPPER_TRANSACTION_NAME,
        )
        _g06_wrapper_transaction_contract(
            transaction_payload,
            wrapper_root=wrapper_root,
            wrapper_metadata=wrapper_metadata,
            project_commit=project_commit,
        )
        file_records = {
            str(record[0]): {
                "size_bytes": int(record[4]),
                "sha256": str(record[5]),
            }
            for record in before
            if record[1] == "regular_file"
        }
        directory_paths = {
            str(record[0]) for record in before if record[1] == "directory"
        }
        run_prefix = f"g06/{run_root.name}"
        declared_files, declared_directories = _g06_declared_wrapper_closure(
            run_root
        )
        if (
            "" not in directory_paths
            or "g06" not in directory_paths
            or run_prefix not in directory_paths
            or any(
                path not in {"", "g06"}
                and path != run_prefix
                and not path.startswith(f"{run_prefix}/")
                for path in directory_paths
            )
            or set(file_records)
            != declared_files
            | {G06_OUTER_WRAPPER_TRANSACTION_NAME}
            | {G06_OUTER_WRAPPER_MANIFEST_NAME}
            or directory_paths - {""} != declared_directories
        ):
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper artifact closure or artifact manifest path "
                "closure differs; a path overlaps or contains a foreign path"
            )
        expected_paths = sorted(
            path
            for path in file_records
            if path != G06_OUTER_WRAPPER_MANIFEST_NAME
        )
        artifacts = manifest.get("artifacts")
        declared_manifest_directories = manifest.get("directories")
        if (
            declared_manifest_directories != sorted(directory_paths - {""})
            or not isinstance(artifacts, list)
            or [
                record.get("path") if isinstance(record, dict) else None
                for record in artifacts
            ]
            != expected_paths
        ):
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper artifact manifest path closure differs"
            )
        for record in artifacts:
            if (
                not isinstance(record, dict)
                or record.get("gate_ids") != ["G06", "P06"]
                or not isinstance(record.get("producer"), str)
                or not str(record.get("producer"))
                or not isinstance(record.get("command"), str)
                or not str(record.get("command"))
                or not isinstance(record.get("platform"), str)
                or not str(record.get("platform"))
                or not isinstance(record.get("machine"), str)
                or not str(record.get("machine"))
            ):
                raise P06ReleaseOrchestrationError(
                    "G06 outer wrapper artifact provenance differs"
                )
            expected = file_records[str(record["path"])]
            if (
                record.get("sha256") != expected["sha256"]
                or record.get("size_bytes") != expected["size_bytes"]
            ):
                raise P06ReleaseOrchestrationError(
                    "G06 outer wrapper artifact binding differs"
                )
        after = _release_tree_snapshot(
            wrapper_descriptor,
            require_frozen=True,
        )
        observed_state, observed_clean = _repository_state()
        reopened_manifest, reopened_metadata = _read_regular_at(
            wrapper_descriptor,
            G06_OUTER_WRAPPER_MANIFEST_NAME,
        )
        try:
            current_wrapper_after = os.stat(
                wrapper_root,
                follow_symlinks=False,
            )
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper became unavailable during validation"
            ) from error
        if (
            after != before
            or observed_state != repository_state
            or not observed_clean
            or reopened_manifest != manifest_payload
            or _identity(reopened_metadata) != _identity(manifest_metadata)
            or _identity(os.fstat(wrapper_descriptor))
            != _identity(wrapper_metadata)
            or _identity(current_wrapper_after)
            != _identity(wrapper_metadata)
        ):
            raise P06ReleaseOrchestrationError(
                "G06 outer wrapper changed during validation"
            )
    finally:
        os.close(wrapper_descriptor)
    execution_wrapper = wrapper_root.parent / f".{wrapper_root.name}.partial"
    execution_root = (
        execution_wrapper / "g06" / f".{run_root.name}.partial"
    )
    return {
        "wrapper_root": wrapper_root,
        "wrapper_device": wrapper_metadata.st_dev,
        "wrapper_inode": wrapper_metadata.st_ino,
        "execution_wrapper": execution_wrapper,
        "execution_root": execution_root,
        "manifest_payload": manifest_payload,
        "manifest_sha256": _sha256(manifest_payload),
        "manifest_size_bytes": len(manifest_payload),
        "project_commit": project_commit,
    }


def _g06_native_runtime_source(
    *,
    runtime_root: Path,
) -> Mapping[str, object]:
    manifest_path = runtime_root / "artifact-manifest.json"
    manifest_payload = _read_regular(manifest_path)
    manifest_file_sha256 = _sha256(manifest_payload)
    try:
        verified = verify_runtime_correction_copy(
            runtime_root,
            expected_manifest_file_sha256=manifest_file_sha256,
        )
    except (RuntimeCorrectionArtifactError, ValueError) as error:
        raise P06ReleaseOrchestrationError(
            f"G06 native runtime closure validation failed: {error}"
        ) from error
    manifest = verified.manifest
    repository_root = manifest.get("root")
    repository_state = manifest.get("repository_state")
    project_commit = manifest.get("project_commit")
    current_repository_state, current_working_tree_clean = (
        runtime_correction_repository_state()
    )
    if (
        manifest.get("artifact_kind")
        != "p06_runtime_feasibility_correction_artifact_manifest"
        or manifest.get("holdout_accessed") is not False
        or manifest.get("working_tree_clean") is not True
        or not isinstance(repository_root, str)
        or PurePosixPath(repository_root).parts[:2] != ("Artifacts", "ASH")
        or len(PurePosixPath(repository_root).parts) < 3
        or not isinstance(repository_state, dict)
        or repository_state.get("project_commit") != project_commit
        or current_working_tree_clean is not True
        or current_repository_state != repository_state
    ):
        raise P06ReleaseOrchestrationError(
            "G06 native runtime manifest provenance differs"
        )

    artifacts = manifest.get("artifacts")
    assert isinstance(artifacts, list)
    benchmark_record: Mapping[str, object] | None = None
    for record in artifacts:
        assert isinstance(record, dict)
        if record.get("path") == "native-aggregate-benchmark.json":
            if (
                benchmark_record is not None
                or record.get("producer") != "pytest native aggregate benchmark"
                or record.get("gate_ids") != ["P06", "G06"]
            ):
                raise P06ReleaseOrchestrationError(
                    "G06 native runtime benchmark record differs"
                )
            benchmark_record = dict(record)
    if benchmark_record is None:
        raise P06ReleaseOrchestrationError(
            "G06 native runtime benchmark record is absent"
        )

    verified_files = dict(verified.files)
    benchmark_payload = verified_files.get("native-aggregate-benchmark.json")
    if benchmark_payload is None:
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark is absent from the verified snapshot"
        )
    try:
        benchmark = json.loads(
            benchmark_payload,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                P06ReleaseOrchestrationError(f"non-finite JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark is invalid JSON"
        ) from error
    if not isinstance(benchmark, dict):
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark is not an object"
        )
    if benchmark_payload != canonical_json_bytes(benchmark) + b"\n":
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark bytes are not canonical"
        )
    try:
        validate_schema(benchmark, NATIVE_BENCHMARK_SCHEMA)
    except ValueError as error:
        raise P06ReleaseOrchestrationError(
            f"G06 native aggregate benchmark schema validation failed: {error}"
        ) from error
    if benchmark.get("schema_binding") != _native_benchmark_schema_binding():
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark schema binding differs"
        )
    benchmark_unhashed = dict(benchmark)
    benchmark_evidence_sha256 = benchmark_unhashed.pop(
        "evidence_sha256",
        None,
    )
    run_identity = benchmark.get("run_identity")
    if not isinstance(run_identity, dict):
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark run identity is absent"
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
        or benchmark_evidence_sha256
        != _sha256(canonical_json_bytes(benchmark_unhashed))
        or run_identity.get("run_id") != manifest.get("run_id")
        or not isinstance(benchmark_repository_state, dict)
        or benchmark_repository_state.get("head_commit") != project_commit
        or benchmark_repository_state.get("is_dirty") is not False
        or final_bundle_linkage != expected_final_bundle_linkage
    ):
        raise P06ReleaseOrchestrationError(
            "G06 native aggregate benchmark finalized provenance differs"
        )

    return {
        "repository_root": repository_root,
        "manifest_file_sha256": manifest_file_sha256,
        "manifest_sha256": manifest["manifest_sha256"],
        "run_id": manifest["run_id"],
        "project_commit": project_commit,
        "benchmark_record": benchmark_record,
        "manifest_schema": _g06_source_binding(
            P06_RUNTIME_CORRECTION_MANIFEST_SCHEMA,
            (
                "validation/calibration_v2/schemas/"
                "p06-runtime-correction-artifact-manifest-v1.schema.json"
            ),
        ),
    }


def _validate_g06_group_semantics(
    *,
    identifier: str,
    document: Mapping[str, object],
    run_root: Path,
    bindings: tuple[Mapping[str, object], ...],
    execution_root: Path | None = None,
    execution_run_name: str | None = None,
) -> None:
    commands = document["commands"]
    summary = document["summary"]
    assert isinstance(commands, list)
    assert isinstance(summary, dict)
    expected_command_counts = {
        TEST_EVIDENCE_IDS[0]: 3,
        TEST_EVIDENCE_IDS[1]: 2,
        TEST_EVIDENCE_IDS[2]: 3,
        TEST_EVIDENCE_IDS[3]: 2,
        TEST_EVIDENCE_IDS[4]: 1,
    }
    if len(commands) != expected_command_counts.get(identifier):
        raise P06ReleaseOrchestrationError("G06 group command count differs")
    if execution_root is not None and execution_run_name is not None:
        raise P06ReleaseOrchestrationError(
            "G06 execution root contract is ambiguous"
        )
    command_execution_root = execution_root
    if command_execution_root is None:
        run_name = (
            execution_run_name
            if execution_run_name is not None
            else run_root.name
        )
        command_execution_root = run_root.parent / f".{run_name}.partial"
    binding_by_id = {
        str(binding["artifact_id"]): binding for binding in bindings
    }

    if identifier == TEST_EVIDENCE_IDS[0]:
        expected_artifacts = (
            ("logs/python-unittest-discovery.log", "command_log", "file_sha256"),
            ("logs/python-pytest.log", "command_log", "file_sha256"),
            (
                "logs/python-native-benchmark-proof.log",
                "command_log",
                "file_sha256",
            ),
            (
                "inputs/native-runtime-evidence",
                "native_runtime_evidence_input",
                "canonical_tree_manifest_sha256",
            ),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        unittest_command_argv = commands[0].get("argv")
        if (
            not isinstance(unittest_command_argv, list)
            or len(unittest_command_argv) != 10
        ):
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        python = unittest_command_argv[2]
        runtime_root = _safe_child(run_root, expected_artifacts[3][0])
        pytest_command_argv = commands[1].get("argv")
        if (
            not isinstance(pytest_command_argv, list)
            or len(pytest_command_argv) != 20
            or not isinstance(pytest_command_argv[9], str)
            or not pytest_command_argv[9].startswith(
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
            )
        ):
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        benchmark_path_text = pytest_command_argv[9].removeprefix(
            "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
        )
        expected_benchmark_path = (
            command_execution_root
            / "inputs/native-runtime-evidence/native-aggregate-benchmark.json"
        )
        _g06_require_exact_execution_path(
            benchmark_path_text,
            expected_benchmark_path,
        )
        unittest_argv = [
            "/usr/bin/env",
            "PYTHONOPTIMIZE=",
            python,
            "-m",
            "unittest",
            "discover",
            "-s",
            "validation/calibration_v2/tests",
            "-p",
            "test_*.py",
        ]
        pytest_argv = [
            "/usr/bin/env",
            "PYTEST_ADDOPTS=",
            "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1",
            "PYTEST_PLUGINS=",
            "PYTHONHOME=",
            "PYTHONOPTIMIZE=",
            f"PYTHONPATH={CALIBRATION_ROOT.parents[1]}",
            "MIRMIR_AGGREGATE_BENCHMARK_OUTPUT=",
            "MIRMIR_RUN_NATIVE_AGGREGATE_BENCHMARK=1",
            (
                "MIRMIR_NATIVE_AGGREGATE_BENCHMARK_OUTPUT="
                f"{benchmark_path_text}"
            ),
            python,
            "-m",
            "pytest",
            "-c",
            "/dev/null",
            "-p",
            "no:cacheprovider",
            "--noconftest",
            "-q",
            "validation/calibration_v2/tests",
        ]
        native_benchmark_proof_argv = [
            *pytest_argv[:-1],
            NATIVE_BENCHMARK_PROOF_NODE_ID,
        ]
        _g06_require_command(
            commands[0],
            argv=unittest_argv,
            log_id=expected_artifacts[0][0],
        )
        _g06_require_command(
            commands[1],
            argv=pytest_argv,
            log_id=expected_artifacts[1][0],
        )
        _g06_require_command(
            commands[2],
            argv=native_benchmark_proof_argv,
            log_id=expected_artifacts[2][0],
        )
        counts = (
            _g06_parse_unittest_log(
                _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
            ),
            _g06_parse_pytest_log(
                _g06_text_artifact(run_root, binding_by_id, expected_artifacts[1][0])
            ),
            _g06_parse_pytest_log(
                _g06_text_artifact(run_root, binding_by_id, expected_artifacts[2][0])
            ),
        )
        expected_summary = {
            "runners": [
                {"runner": runner, "counts": result}
                for runner, result in zip(PYTHON_TEST_RUNNER_IDS, counts)
            ],
            "aggregate_executed_test_count": sum(
                int(result["test_count"]) for result in counts
            ),
            "required_runner_order": list(PYTHON_TEST_RUNNER_IDS),
            "native_runtime_evidence_input": dict(
                binding_by_id[expected_artifacts[3][0]]
            ),
            "native_runtime_source": _g06_native_runtime_source(
                runtime_root=runtime_root,
            ),
        }
        if not _json_exact_equal(summary, expected_summary):
            raise P06ReleaseOrchestrationError("G06 Python summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[1]:
        expected_artifacts = (
            ("logs/xcode-native-integration.log", "command_log", "file_sha256"),
            (
                "artifacts/native-integration-xcresult-summary.log",
                "xcresult_summary",
                "file_sha256",
            ),
            (
                "artifacts/native-integration.xcresult",
                "xcresult",
                "canonical_tree_manifest_sha256",
            ),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        first_argv = commands[0]["argv"]
        if not isinstance(first_argv, list) or len(first_argv) < 13:
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        derived = _g06_require_exact_execution_path(
            first_argv[10],
            command_execution_root / "build/native-integration-derived-data",
        )
        result_bundle = _g06_require_exact_execution_path(
            first_argv[12],
            command_execution_root / "artifacts/native-integration.xcresult",
        )
        _g06_require_command(
            commands[0],
            argv=_g06_xcode_test_argv(
                configuration="Debug",
                derived=derived,
                result_bundle=result_bundle,
                tests=NATIVE_INTEGRATION_TEST_IDS,
                clean=True,
            ),
            log_id=expected_artifacts[0][0],
        )
        summary_argv = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
        ]
        _g06_require_command(
            commands[1],
            argv=summary_argv,
            log_id=expected_artifacts[1][0],
        )
        diagnostics = _g06_diagnostic_counts(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
        )
        if diagnostics["error_count"] != 0:
            raise P06ReleaseOrchestrationError("G06 native log contains errors")
        counts = _g06_parse_xcresult_summary(
            _read_json(_safe_child(run_root, expected_artifacts[1][0]))
        )
        expected_summary = {
            "configuration": "Debug",
            "scheme": "Mirmir",
            "destination": "platform=macOS,arch=arm64",
            "only_testing": list(NATIVE_INTEGRATION_TEST_IDS),
            "test_counts": counts,
            **diagnostics,
        }
        if not _json_exact_equal(summary, expected_summary):
            raise P06ReleaseOrchestrationError("G06 native summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[2]:
        expected_artifacts = (
            ("logs/xcode-release-build.log", "command_log", "file_sha256"),
            ("logs/xcode-release-runtime.log", "command_log", "file_sha256"),
            (
                "artifacts/release-runtime-xcresult-summary.log",
                "xcresult_summary",
                "file_sha256",
            ),
            (
                "artifacts/release-runtime.xcresult",
                "xcresult",
                "canonical_tree_manifest_sha256",
            ),
            (
                "build/release-derived-data/Build/Products/Release/"
                "Mirmir.app/Contents/MacOS/Mirmir",
                "release_product",
                "file_sha256",
            ),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        release_product_binding = binding_by_id.get(expected_artifacts[4][0])
        if (
            release_product_binding is None
            or release_product_binding.get("executable_mode_bits") != 0o111
        ):
            raise P06ReleaseOrchestrationError(
                "G06 retained Release product executable mode differs"
            )
        build_argv = commands[0]["argv"]
        if not isinstance(build_argv, list) or len(build_argv) < 11:
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        derived = _g06_require_exact_execution_path(
            build_argv[10],
            command_execution_root / "build/release-derived-data",
        )
        expected_build_argv = [
            "xcodebuild",
            "-project",
            "Mirmir.xcodeproj",
            "-scheme",
            "Mirmir",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS,arch=arm64",
            "-derivedDataPath",
            derived,
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_TESTABILITY=YES",
            "clean",
            "build",
        ]
        _g06_require_command(
            commands[0],
            argv=expected_build_argv,
            log_id=expected_artifacts[0][0],
        )
        runtime_argv = commands[1]["argv"]
        if not isinstance(runtime_argv, list) or len(runtime_argv) < 13:
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        result_bundle = _g06_require_exact_execution_path(
            runtime_argv[12],
            command_execution_root / "artifacts/release-runtime.xcresult",
        )
        _g06_require_command(
            commands[1],
            argv=_g06_xcode_test_argv(
                configuration="Release",
                derived=derived,
                result_bundle=result_bundle,
                tests=RELEASE_RUNTIME_TEST_IDS,
                clean=False,
            ),
            log_id=expected_artifacts[1][0],
        )
        summary_argv = [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_bundle,
        ]
        _g06_require_command(
            commands[2],
            argv=summary_argv,
            log_id=expected_artifacts[2][0],
        )
        build_log = _g06_text_artifact(
            run_root,
            binding_by_id,
            expected_artifacts[0][0],
        )
        runtime_log = _g06_text_artifact(
            run_root,
            binding_by_id,
            expected_artifacts[1][0],
        )
        build_diagnostics = _g06_diagnostic_counts(build_log)
        runtime_diagnostics = _g06_diagnostic_counts(runtime_log)
        if (
            build_diagnostics != {"warning_count": 0, "error_count": 0}
            or runtime_diagnostics != {"warning_count": 0, "error_count": 0}
            or "** BUILD SUCCEEDED **" not in build_log
        ):
            raise P06ReleaseOrchestrationError(
                "G06 Release logs are not zero-warning passing logs"
            )
        counts = _g06_parse_xcresult_summary(
            _read_json(_safe_child(run_root, expected_artifacts[2][0]))
        )
        expected_summary = {
            "configuration": "Release",
            "scheme": "Mirmir",
            "destination": "platform=macOS,arch=arm64",
            "only_testing": list(RELEASE_RUNTIME_TEST_IDS),
            "build_warning_count": 0,
            "build_error_count": 0,
            "runtime_warning_count": 0,
            "runtime_error_count": 0,
            "test_counts": counts,
        }
        if not _json_exact_equal(summary, expected_summary):
            raise P06ReleaseOrchestrationError("G06 Release summary differs from logs")
        return

    if identifier == TEST_EVIDENCE_IDS[3]:
        expected_artifacts = (
            ("logs/swiftlint-version.log", "command_log", "file_sha256"),
            ("logs/swiftlint-strict.log", "command_log", "file_sha256"),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        executable = commands[0]["argv"][0]
        _g06_require_command(
            commands[0],
            argv=[executable, "version"],
            log_id=expected_artifacts[0][0],
        )
        _g06_require_command(
            commands[1],
            argv=[executable, "lint", "--strict", "--config", ".swiftlint.yml"],
            log_id=expected_artifacts[1][0],
        )
        diagnostics = _g06_diagnostic_counts(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[1][0])
        )
        if diagnostics != {"warning_count": 0, "error_count": 0}:
            raise P06ReleaseOrchestrationError("G06 SwiftLint log is not clean")
        if not _json_exact_equal(summary, {"strict": True, **diagnostics}):
            raise P06ReleaseOrchestrationError("G06 SwiftLint summary differs")
        return

    if identifier == TEST_EVIDENCE_IDS[4]:
        expected_artifacts = (
            ("logs/release-lock-unit-suite.log", "command_log", "file_sha256"),
        )
        _g06_require_artifacts(bindings, expected_artifacts)
        command_argv = commands[0].get("argv")
        if not isinstance(command_argv, list) or len(command_argv) < 3:
            raise P06ReleaseOrchestrationError("G06 command contract differs")
        python = command_argv[2]
        argv = [
            "/usr/bin/env",
            "PYTHONOPTIMIZE=",
            python,
            "-m",
            "unittest",
            *RELEASE_LOCK_TEST_MODULES,
        ]
        _g06_require_command(
            commands[0],
            argv=argv,
            log_id=expected_artifacts[0][0],
        )
        counts = _g06_parse_unittest_log(
            _g06_text_artifact(run_root, binding_by_id, expected_artifacts[0][0])
        )
        expected_summary = {
            "modules": list(RELEASE_LOCK_TEST_MODULES),
            "test_counts": counts,
        }
        if not _json_exact_equal(summary, expected_summary):
            raise P06ReleaseOrchestrationError(
                "G06 release-lock summary differs from log"
            )
        return

    raise P06ReleaseOrchestrationError("G06 evidence ID has no semantic contract")


def _validate_g06_evidence_document(
    *,
    identifier: str,
    ordinal: int,
    source: Path,
    run_root: Path,
    execution_root: Path,
) -> tuple[
    Mapping[str, object],
    tuple[Mapping[str, object], ...],
    bytes,
]:
    if source.name != f"{identifier}.json":
        raise P06ReleaseOrchestrationError("G06 evidence filename differs")
    payload = _read_regular(source)
    document = _decode_json_object(payload, path=source)
    try:
        validate_schema(document, G06_TEST_EVIDENCE_SCHEMA)
    except ValueError as error:
        raise P06ReleaseOrchestrationError(
            f"G06 evidence schema validation failed: {identifier}"
        ) from error
    unhashed = dict(document)
    declared_sha256 = unhashed.pop("evidence_sha256", None)
    if declared_sha256 != _sha256(canonical_json_bytes(unhashed)):
        raise P06ReleaseOrchestrationError(
            f"G06 evidence self-hash differs: {identifier}"
        )
    expected_verifier_source = _g06_source_binding(
        CALIBRATION_ROOT / "tools/run_g06_verification.py",
        "validation/calibration_v2/tools/run_g06_verification.py",
    )
    expected_schema = _g06_source_binding(
        G06_TEST_EVIDENCE_SCHEMA,
        "validation/calibration_v2/schemas/g06-test-evidence-v1.schema.json",
    )
    if (
        document.get("verifier_source") != expected_verifier_source
        or document.get("evidence_schema") != expected_schema
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 verifier source or schema binding differs: {identifier}"
        )
    if (
        document.get("evidence_id") != identifier
        or document.get("evidence_ordinal") != ordinal
        or document.get("status") != "passed"
        or document.get("failure_reason") is not None
        or document.get("holdout_accessed") is not False
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 evidence identity or passing status differs: {identifier}"
        )
    commands = document.get("commands")
    artifacts = document.get("artifacts")
    if not isinstance(commands, list) or not commands:
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence has no commands: {identifier}"
        )
    if not isinstance(artifacts, list) or not artifacts:
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence has no artifacts: {identifier}"
        )
    if [command.get("command_index") for command in commands] != list(
        range(1, len(commands) + 1)
    ) or any(
        command.get("status") != "passed"
        or command.get("exit_code") != 0
        or command.get("timed_out") is not False
        for command in commands
    ):
        raise P06ReleaseOrchestrationError(
            f"G06 passing evidence contains a non-passing command: {identifier}"
        )
    bindings: list[Mapping[str, object]] = []
    binding_by_id: dict[str, Mapping[str, object]] = {}
    artifact_paths: list[PurePosixPath] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise P06ReleaseOrchestrationError("G06 artifact binding is invalid")
        artifact_id = artifact.get("artifact_id")
        if not isinstance(artifact_id, str):
            raise P06ReleaseOrchestrationError("G06 artifact ID is invalid")
        relative = PurePosixPath(artifact_id)
        _safe_child(run_root, artifact_id)
        if artifact_id in binding_by_id:
            raise P06ReleaseOrchestrationError(
                f"G06 artifact binding is duplicated: {artifact_id}"
            )
        evidence_relative = PurePosixPath(source.name)
        if (
            relative == evidence_relative
            or evidence_relative in relative.parents
            or relative in evidence_relative.parents
        ) or any(
            relative == prior
            or relative in prior.parents
            or prior in relative.parents
            for prior in artifact_paths
        ):
            raise P06ReleaseOrchestrationError(
                f"G06 artifact paths overlap: {artifact_id}"
            )
        binding = dict(artifact)
        binding_by_id[artifact_id] = binding
        artifact_paths.append(relative)
        bindings.append(binding)
    command_log_ids: list[str] = []
    for command in commands:
        log_binding = command.get("log_binding")
        if not isinstance(log_binding, dict):
            raise P06ReleaseOrchestrationError("G06 command log binding is invalid")
        artifact_id = log_binding.get("artifact_id")
        if (
            not isinstance(artifact_id, str)
            or binding_by_id.get(artifact_id) != log_binding
            or artifact_id in command_log_ids
            or log_binding.get("artifact_kind")
            not in {"command_log", "xcresult_summary"}
            or log_binding.get("digest_mode") != "file_sha256"
        ):
            raise P06ReleaseOrchestrationError(
                f"G06 command log closure differs: {identifier}"
            )
        command_log_ids.append(artifact_id)
    for binding in bindings:
        _verify_g06_artifact_binding(run_root=run_root, binding=binding)
    _validate_g06_group_semantics(
        identifier=identifier,
        document=document,
        run_root=run_root,
        bindings=tuple(bindings),
        execution_root=execution_root,
    )
    return document, tuple(bindings), payload


def _copy_g06_tree(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise P06ReleaseOrchestrationError(
            "G06 source tree is absent or symbolic"
        )
    if destination.exists() or destination.is_symlink():
        raise P06ReleaseOrchestrationError("G06 tree destination collides")
    destination.mkdir(parents=True, mode=0o700)
    for current_name, directory_names, file_names in os.walk(
        source,
        topdown=True,
        onerror=_g06_raise_tree_walk_error,
        followlinks=False,
    ):
        current = Path(current_name)
        relative = current.relative_to(source)
        target = destination.joinpath(*relative.parts)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            child = current / name
            if child.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "G06 source tree contains a symbolic directory"
                )
            (target / name).mkdir(mode=0o700)
        for name in file_names:
            child = current / name
            if child.is_symlink():
                raise P06ReleaseOrchestrationError(
                    "G06 source tree contains a symbolic file"
                )
            _copy_new(child, target / name)


def _reject_symlinked_ancestors(path: Path) -> None:
    absolute = Path(os.path.abspath(path))
    for candidate in (absolute, *absolute.parents):
        try:
            mode = os.lstat(candidate).st_mode
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                f"G06 evidence ancestor is unavailable: {candidate}"
            ) from error
        if stat.S_ISLNK(mode):
            raise P06ReleaseOrchestrationError(
                f"G06 evidence run root has a symbolic ancestor: {candidate}"
            )


def _g06_outer_wrapper_binding_document(
    contract: Mapping[str, object],
) -> Mapping[str, object]:
    wrapper_root = contract["wrapper_root"]
    execution_wrapper = contract["execution_wrapper"]
    if not isinstance(wrapper_root, Path) or not isinstance(
        execution_wrapper, Path
    ):
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper contract paths are invalid"
        )
    document: dict[str, object] = {
        "schema_version": "1.0.0",
        "artifact_kind": "p06_g06_outer_wrapper_manifest_binding",
        "source_wrapper": {
            "absolute_path": str(wrapper_root),
            "device": contract["wrapper_device"],
            "inode": contract["wrapper_inode"],
            "final_name": wrapper_root.name,
            "execution_partial_path": str(execution_wrapper),
        },
        "source_manifest_path": G06_OUTER_WRAPPER_MANIFEST_NAME,
        "copied_manifest_path": (
            "test-evidence/python_calibration_full_suite/"
            f"{G06_COPIED_OUTER_WRAPPER_MANIFEST_NAME}"
        ),
        "sha256": contract["manifest_sha256"],
        "size_bytes": contract["manifest_size_bytes"],
        "project_commit": contract["project_commit"],
        "manifest_schema": _g06_source_binding(
            EVIDENCE_WRAPPER_MANIFEST_SCHEMA,
            (
                "validation/calibration_v2/schemas/"
                "evidence-wrapper-artifact-manifest-v2.schema.json"
            ),
        ),
        "holdout_accessed": False,
    }
    document["manifest_sha256"] = manifest_sha256(document)
    try:
        validate_schema(document, G06_OUTER_WRAPPER_BINDING_SCHEMA)
    except ValueError as error:
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper binding schema validation failed"
        ) from error
    return document


def _require_same_g06_outer_wrapper_contract(
    expected: Mapping[str, object],
    observed: Mapping[str, object],
) -> None:
    if dict(expected) != dict(observed):
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper changed during evidence handoff"
        )


def _copy_g06_test_evidence_set(
    *,
    test_evidence_paths: Mapping[str, Path],
    release_root: Path,
) -> Mapping[str, Path]:
    """Validate and copy the exact ordered G06 JSONs and declared closure."""

    if tuple(test_evidence_paths) != REQUIRED_G06_TEST_EVIDENCE_IDS:
        raise P06ReleaseOrchestrationError("G06 test evidence set or order differs")
    sources = [
        (identifier, Path(path))
        for identifier, path in test_evidence_paths.items()
    ]
    roots = []
    for identifier, source in sources:
        _reject_symlinked_ancestors(source.parent)
        _read_regular(source)
        if source.parent.is_symlink() or not source.parent.is_dir():
            raise P06ReleaseOrchestrationError("G06 evidence run root is symbolic")
        if source.name != f"{identifier}.json":
            raise P06ReleaseOrchestrationError("G06 evidence filename differs")
        roots.append(source.parent.resolve(strict=True))
    if not roots or any(root != roots[0] for root in roots[1:]):
        raise P06ReleaseOrchestrationError(
            "G06 evidence paths do not share one run root"
        )
    run_root = roots[0]
    expected_json_names = sorted(
        f"{identifier}.json" for identifier in REQUIRED_G06_TEST_EVIDENCE_IDS
    )
    actual_json_names = sorted(
        path.name for path in run_root.iterdir() if path.suffix == ".json"
    )
    if actual_json_names != expected_json_names:
        raise P06ReleaseOrchestrationError("G06 evidence root JSON set differs")
    wrapper_contract = _g06_outer_wrapper_contract(run_root)
    execution_root = wrapper_contract["execution_root"]
    if not isinstance(execution_root, Path):
        raise P06ReleaseOrchestrationError(
            "G06 outer wrapper execution root is invalid"
        )
    validated = []
    for ordinal, (identifier, source) in enumerate(sources, 1):
        document, bindings, payload = _validate_g06_evidence_document(
            identifier=identifier,
            ordinal=ordinal,
            source=source,
            run_root=run_root,
            execution_root=execution_root,
        )
        validated.append((identifier, source, document, bindings, payload))

    copied: dict[str, Path] = {}
    for identifier, source, document, bindings, payload in validated:
        destination_root = release_root / "test-evidence" / identifier
        if destination_root.exists() or destination_root.is_symlink():
            raise P06ReleaseOrchestrationError("G06 evidence destination collides")
        destination_root.mkdir(parents=True, mode=0o700)
        destination_json = destination_root / source.name
        _write_new(destination_json, payload)
        for binding in bindings:
            artifact_id = str(binding["artifact_id"])
            source_artifact = _verify_g06_artifact_binding(
                run_root=run_root,
                binding=binding,
            )
            destination_artifact = destination_root.joinpath(
                *PurePosixPath(artifact_id).parts
            )
            if binding["digest_mode"] == "file_sha256":
                _copy_new(source_artifact, destination_artifact)
                executable_mode_bits = binding.get("executable_mode_bits")
                if not isinstance(executable_mode_bits, int) or isinstance(
                    executable_mode_bits, bool
                ):
                    raise P06ReleaseOrchestrationError(
                        "G06 file artifact executable mode is invalid"
                    )
                os.chmod(
                    destination_artifact,
                    0o600 | executable_mode_bits,
                    follow_symlinks=False,
                )
            else:
                _copy_g06_tree(source_artifact, destination_artifact)
            _verify_g06_artifact_binding(
                run_root=destination_root,
                binding=binding,
            )
        if _read_regular(destination_json) != payload:
            raise P06ReleaseOrchestrationError(
                f"copied G06 evidence JSON changed: {identifier}"
            )
        if identifier == REQUIRED_G06_TEST_EVIDENCE_IDS[0]:
            manifest_payload = wrapper_contract["manifest_payload"]
            if not isinstance(manifest_payload, bytes):
                raise P06ReleaseOrchestrationError(
                    "G06 outer wrapper manifest payload is invalid"
                )
            copied_manifest = (
                destination_root / G06_COPIED_OUTER_WRAPPER_MANIFEST_NAME
            )
            _write_new(copied_manifest, manifest_payload)
            if _read_regular(copied_manifest) != manifest_payload:
                raise P06ReleaseOrchestrationError(
                    "copied G06 outer wrapper manifest changed"
                )
            binding_document = _g06_outer_wrapper_binding_document(
                wrapper_contract
            )
            binding_path = destination_root / G06_OUTER_WRAPPER_BINDING_NAME
            _write_json(binding_path, binding_document)
            reopened_binding = _read_json(binding_path)
            try:
                validate_schema(
                    reopened_binding,
                    G06_OUTER_WRAPPER_BINDING_SCHEMA,
                )
            except ValueError as error:
                raise P06ReleaseOrchestrationError(
                    "copied G06 outer wrapper binding schema differs"
                ) from error
            unhashed_binding = dict(reopened_binding)
            declared_binding_sha256 = unhashed_binding.pop(
                "manifest_sha256",
                None,
            )
            if (
                declared_binding_sha256
                != _sha256(canonical_json_bytes(unhashed_binding))
                or not _json_exact_equal(
                    reopened_binding,
                    binding_document,
                )
            ):
                raise P06ReleaseOrchestrationError(
                    "copied G06 outer wrapper binding changed"
                )
        copied[identifier] = destination_root
    observed_wrapper_contract = _g06_outer_wrapper_contract(run_root)
    _require_same_g06_outer_wrapper_contract(
        wrapper_contract,
        observed_wrapper_contract,
    )
    return copied


def _safe_child(root: Path, relative_value: object) -> Path:
    if not isinstance(relative_value, str):
        raise P06ReleaseOrchestrationError("relative artifact path is absent")
    relative = PurePosixPath(relative_value)
    if (
        not relative_value
        or relative_value.startswith("/")
        or "\\" in relative_value
        or relative.as_posix() != relative_value
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise P06ReleaseOrchestrationError("relative artifact path is unsafe")
    absolute_root = root.resolve(strict=True)
    candidate = absolute_root.joinpath(*relative.parts)
    resolved_parent = candidate.parent.resolve(strict=True)
    try:
        resolved_parent.relative_to(absolute_root)
    except ValueError as error:
        raise P06ReleaseOrchestrationError("artifact path escapes its root") from error
    return resolved_parent / candidate.name


def _verify_binding(path: Path, binding: Mapping[str, object]) -> None:
    payload = _read_regular(path)
    if (
        binding.get("sha256") != _sha256(payload)
        or binding.get("size_bytes") != len(payload)
    ):
        raise P06ReleaseOrchestrationError("content-addressed binding changed")


def _run(command: tuple[str, ...], *, cwd: Path) -> bytes:
    result = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise P06ReleaseOrchestrationError(
            "release command failed: "
            + " ".join(command)
            + "\n"
            + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout


def _python_source_manifest(repository_root: Path) -> Mapping[str, object]:
    rows = []
    for relative in _PYTHON_ORACLE_SOURCES:
        payload = _read_regular(repository_root.joinpath(*PurePosixPath(relative).parts))
        rows.append(
            {"path": relative, "sha256": _sha256(payload), "size_bytes": len(payload)}
        )
    return {
        "schema_version": "1.0.0",
        "implementation_role": "independent_test_python",
        "python_implementation": sys.implementation.name,
        "python_version": sys.version,
        "sources": rows,
    }


def _configuration_bindings(
    *,
    repository_root: Path,
    release_root: Path,
    p04_quality_root: Path,
    bound_inputs: object,
) -> Mapping[str, HashBinding]:
    record = bound_inputs.record
    return {
        "mapping_sha256": HashBinding(
            path=release_root / "locked-mapping.json", root=release_root
        ),
        "operator_bank_sha256": HashBinding(
            path=release_root / "locked-operator-bank.json", root=release_root
        ),
        "quality_policy_sha256": HashBinding(
            path=release_root / "locked-quality-policy.json", root=release_root
        ),
        "metric_policy_sha256": HashBinding(
            path=release_root / "locked-metric-policy.json", root=release_root
        ),
        "metric_implementation_sha256": HashBinding(
            path=repository_root
            / "validation/quality/src/mirmir_quality/metrics.py",
            root=repository_root,
        ),
        "metric_conformance_sha256": HashBinding(
            path=p04_quality_root
            / "production-run/production-prechange/metric-conformance.json",
            root=p04_quality_root,
        ),
        "degradation_policy_sha256": HashBinding(
            path=repository_root.joinpath(*PurePosixPath(record("degradation_policy")["path"]).parts),
            root=repository_root,
        ),
        "actual_codec_fixture_sha256": HashBinding(
            path=repository_root
            / "validation/quality/fixtures/actual-h264-software-nv12-v1/actual-codec-fixture-lock.json",
            root=repository_root,
        ),
        "actual_codec_evidence_sha256": HashBinding(
            path=p04_quality_root
            / "production-run/production-prechange/actual-codec-evidence.json",
            root=p04_quality_root,
        ),
        "quality_harness_implementation_manifest_sha256": HashBinding(
            path=repository_root.joinpath(
                *PurePosixPath(
                    record("quality_harness_implementation_manifest")["path"]
                ).parts
            ),
            root=repository_root,
            digest_mode="quality_harness_manifest",
        ),
        "compiler_inputs_sha256": HashBinding(
            path=release_root / "locked-compiler-input.json", root=release_root
        ),
        "route_luts_sha256": HashBinding(
            path=release_root / "lut-manifest.json",
            root=release_root,
            digest_mode="manifest_sha256",
        ),
        "corpus_manifest_sha256": HashBinding(
            path=repository_root.joinpath(
                *PurePosixPath(record("corpus_lock")["path"]).parts
            ),
            root=repository_root,
            digest_mode="manifest_sha256",
        ),
    }


def _copy_selected_control_artifacts(
    *,
    run_root: Path,
    release_root: Path,
    selection: Mapping[str, object],
) -> None:
    rows = selection.get("selected_control_selection_artifacts")
    if not isinstance(rows, list) or len(rows) != 3:
        raise P06ReleaseOrchestrationError("selected controls are not exactly three")
    for binding in rows:
        if not isinstance(binding, dict):
            raise P06ReleaseOrchestrationError("selected control binding is invalid")
        source = _safe_child(run_root, binding.get("path"))
        destination = release_root.joinpath(*PurePosixPath(str(binding["path"])).parts)
        _verify_binding(source, binding)
        _copy_new(source, destination)
        _verify_binding(destination, binding)


def _publish_release(
    *,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    p04_quality_root: Path,
    transaction_id: str,
    locked_utc: str,
    bound_inputs: object,
    test_evidence_paths: Mapping[str, Path],
    preserved_failure_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    bound_inputs.verify_unchanged()
    selection_source = calibration_run_root / "selection.json"
    ledger_source = calibration_run_root / "calibration-run-ledger.json"
    selection = _read_json(selection_source)
    ledger = _read_json(ledger_source)
    validate_schema(selection, SCHEMAS_ROOT / "calibration-selection-v1.schema.json")
    validate_schema(ledger, SCHEMAS_ROOT / "calibration-run-ledger-v1.schema.json")
    if (
        selection.get("manifest_sha256") != manifest_sha256(selection)
        or ledger.get("manifest_sha256") != manifest_sha256(ledger)
        or selection.get("input_bundle_sha256") != bound_inputs.bundle_sha256
        or ledger.get("input_bundle_sha256") != bound_inputs.bundle_sha256
    ):
        raise P06ReleaseOrchestrationError("calibration selection or ledger is stale")
    _copy_new(selection_source, release_root / "calibration-selection.json")
    _copy_new(ledger_source, release_root / "calibration-run-ledger.json")
    selection_file_sha256 = _sha256(
        _read_regular(release_root / "calibration-selection.json")
    )

    selected_evaluation_sha256 = str(selection["selected_evaluation_sha256"])
    selected_relative = f"evaluations/{selected_evaluation_sha256}.json"
    selected_source = _safe_child(calibration_run_root, selected_relative)
    selected_payload = _read_regular(selected_source)
    if _sha256(selected_payload) != selected_evaluation_sha256:
        raise P06ReleaseOrchestrationError("selected evaluation content address differs")
    _write_new(release_root / selected_relative, selected_payload)
    evaluation = _read_json(release_root / selected_relative)
    validate_schema(evaluation, SCHEMAS_ROOT / "candidate-evaluation-v1.schema.json")
    _copy_selected_control_artifacts(
        run_root=calibration_run_root,
        release_root=release_root,
        selection=selection,
    )

    live = dict(bound_inputs.live_holdout_preopen_verification)
    if (
        selection.get("live_holdout_preopen_verification") != live
        or ledger.get("live_holdout_preopen_verification") != live
    ):
        raise P06ReleaseOrchestrationError("live preopen verification changed")
    _write_json(release_root / "live-holdout-preopen-verification.json", live)

    dispatch_wrapper = evaluation.get("dispatch_measurement")
    if not isinstance(dispatch_wrapper, dict):
        raise P06ReleaseOrchestrationError("selected dispatch evidence is absent")
    dispatch_bindings = dispatch_wrapper.get("measurement_evidence_bindings")
    dispatch_records = dispatch_wrapper.get("measurement_records")
    if (
        not isinstance(dispatch_bindings, list)
        or len(dispatch_bindings) != 1
        or not isinstance(dispatch_bindings[0], dict)
        or not isinstance(dispatch_records, list)
        or len(dispatch_records) != 1
        or not isinstance(dispatch_records[0], dict)
    ):
        raise P06ReleaseOrchestrationError("selected dispatch evidence is not singular")
    dispatch_source = _safe_child(
        dispatch_measurement_root,
        dispatch_bindings[0].get("path"),
    )
    _verify_binding(dispatch_source, dispatch_bindings[0])
    _copy_new(dispatch_source, release_root / "dispatch-measurement.json")
    dispatch_payload = _read_regular(release_root / "dispatch-measurement.json")
    dispatch = _read_json(release_root / "dispatch-measurement.json")
    if dispatch != dispatch_records[0]:
        raise P06ReleaseOrchestrationError("reopened dispatch bytes differ from evaluation")
    validate_dispatch_measurement_document(dispatch)

    tolerances = bound_inputs.documents["metric_performance_tolerances"]
    metric_policy = locked_metric_policy_document(
        metric_seed=bound_inputs.documents["metric_policy_seed"],
        tolerances=tolerances,
        tolerances_sha256=str(
            bound_inputs.record("metric_performance_tolerances")["sha256"]
        ),
        dispatch_measurement=dispatch,
        dispatch_measurement_file_sha256=_sha256(dispatch_payload),
        dispatch_measurement_size_bytes=len(dispatch_payload),
    )
    _write_json(release_root / "locked-metric-policy.json", metric_policy)
    metric_policy_file_sha256 = _sha256(
        _read_regular(release_root / "locked-metric-policy.json")
    )

    selected_controls = selection["selected_controls"]
    if not isinstance(selected_controls, dict):
        raise P06ReleaseOrchestrationError("selected controls are absent")
    build_locked_quality_policy(
        output_path=release_root / "locked-quality-policy.json",
        selected_controls=selected_controls,
        quality_policy_seed_sha256=str(selection["quality_policy_seed_sha256"]),
        baseline_ablation_contract=bound_inputs.documents[
            "baseline_ablation_contract"
        ],
        baseline_ablation_contract_sha256=str(
            selection["baseline_ablation_contract_sha256"]
        ),
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        shared_bank_configuration_sha256=str(
            selected_controls["shared_bank_configuration_sha256"]
        ),
    )

    vector = selection["selected_vector"]
    plan = bound_inputs.documents["calibration_plan"]
    if not isinstance(vector, dict):
        raise P06ReleaseOrchestrationError("selected vector is absent")
    configuration_id = f"ash-p06-{selection['selected_vector_sha256'][:24]}"
    runtime_summary = evaluation.get("runtime_summary")
    if (
        not isinstance(runtime_summary, dict)
        or runtime_summary.get("configuration_id") != configuration_id
    ):
        raise P06ReleaseOrchestrationError("selected native configuration differs")
    mapping = video_mapping_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        mapping_seed_sha256=str(bound_inputs.record("mapping_seed")["sha256"]),
        status="locked_before_p07",
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
    )
    operator_bank = operator_bank_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        operator_bank_seed_sha256=str(
            bound_inputs.record("operator_bank_seed")["sha256"]
        ),
        status="locked_before_p07",
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
    )
    _write_json(release_root / "locked-mapping.json", mapping)
    _write_json(release_root / "locked-operator-bank.json", operator_bank)
    mapping_file_sha256 = _sha256(_read_regular(release_root / "locked-mapping.json"))
    operator_file_sha256 = _sha256(
        _read_regular(release_root / "locked-operator-bank.json")
    )
    compiler_input = locked_compiler_input_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        mapping_sha256=mapping_file_sha256,
        operator_bank_sha256=operator_file_sha256,
        metric_policy_sha256=metric_policy_file_sha256,
        calibration_plan_sha256=str(
            bound_inputs.record("calibration_plan")["sha256"]
        ),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
    )
    _write_json(release_root / "locked-compiler-input.json", compiler_input)
    compiler_inputs_sha256 = str(
        compiler_input["hash_bindings"]["compiler_inputs_sha256"]
    )
    route_selection = route_analysis_grid_selection_document(
        vector=vector,
        plan=plan,
        configuration_id=configuration_id,
        calibration_selection_sha256=selection_file_sha256,
        selected_evaluation_sha256=selected_evaluation_sha256,
        mapping_sha256=mapping_file_sha256,
        operator_bank_sha256=operator_file_sha256,
        compiler_inputs_sha256=compiler_inputs_sha256,
    )
    _write_json(
        release_root / "route-analysis-grid-selection.json",
        route_selection,
    )

    native_builder = NativeSwiftBuilder(repository_root, native_cache_root)
    p00_builder = P00NativeBuilder(repository_root, native_cache_root)
    executable = native_builder.executable
    _copy_new(
        executable.path,
        release_root / "bin/ash-calibration-cli",
        executable=True,
    )
    _copy_new(
        executable.source_manifest_path,
        release_root / "sources/production-swift-source-manifest.json",
    )
    macos_code_identities = {
        "production_swift_executable": static_code_identity(
            release_root / "bin/ash-calibration-cli"
        ),
        "production_writer_executable": static_code_identity(
            writer_root / "production-writer"
        ),
        "p00_native_executable": static_code_identity(
            p00_builder.executable.path
        ),
    }
    _write_json(
        release_root / "sources/independent-python-source-manifest.json",
        _python_source_manifest(repository_root),
    )
    (release_root / "swift").mkdir()
    swift_output = _run(
        (
            str(release_root / "bin/ash-calibration-cli"),
            "compile-candidate",
            "--compiler-input",
            str(release_root / "locked-compiler-input.json"),
            "--mapping",
            str(release_root / "locked-mapping.json"),
            "--operator-bank",
            str(release_root / "locked-operator-bank.json"),
            "--output-directory",
            str(release_root / "swift"),
        ),
        cwd=repository_root,
    )
    _write_new(release_root / "swift/native-compile-summary.json", swift_output)
    _run(
        (
            sys.executable,
            str(repository_root / "validation/calibration_v2/tools/compile_reference_luts.py"),
            str(release_root / "locked-compiler-input.json"),
            str(release_root / "python"),
        ),
        cwd=repository_root,
    )
    build_native_parity_manifest(
        release_root=release_root,
        compiler_input_path=release_root / "locked-compiler-input.json",
        production_source_manifest_path=(
            "sources/production-swift-source-manifest.json"
        ),
        independent_source_manifest_path=(
            "sources/independent-python-source-manifest.json"
        ),
        output_path=release_root / "native-lut-parity-manifest.json",
        failure_output_path=release_root / "native-lut-parity-failure.json",
        conflict_record=str(plan["authority"]["conflict_record"]),
    )
    for filename in ("direct2x.ashlut", "direct3over2.ashlut"):
        _copy_new(release_root / "swift" / filename, release_root / filename)
    build_lut_manifest(
        repository_root=repository_root,
        release_root=release_root,
        output_path=release_root / "lut-manifest.json",
    )

    configuration_artifact_bindings = _configuration_bindings(
        repository_root=repository_root,
        release_root=release_root,
        p04_quality_root=p04_quality_root,
        bound_inputs=bound_inputs,
    )
    build_configuration_lock_from_bindings(
        output_path=release_root / "configuration-lock.json",
        locked_utc=locked_utc,
        artifact_bindings=configuration_artifact_bindings,
    )
    if P00_FAILURE_ID not in preserved_failure_paths:
        raise P06ReleaseOrchestrationError(
            "pinned P00 compatibility failure evidence is absent"
        )
    copied_tests = _copy_g06_test_evidence_set(
        test_evidence_paths=test_evidence_paths,
        release_root=release_root,
    )
    copied_failures = {
        identifier: _copy_evidence_input(
            identifier=identifier,
            source=path,
            release_root=release_root,
            category="preserved-failures",
        )
        for identifier, path in preserved_failure_paths.items()
    }
    control_rows = selection["selected_control_selection_artifacts"]
    assert isinstance(control_rows, list)
    control_paths = {
        str(row["control"]): release_root.joinpath(
            *PurePosixPath(str(row["path"])).parts
        )
        for row in control_rows
    }
    publish_p06_evidence_closure(
        output_path=release_root / "p06-evidence-closure.json",
        configuration_id=configuration_id,
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
        configuration_bindings=configuration_artifact_bindings,
        configuration_roots={
            "repository": repository_root,
            "release": release_root,
            "p04_quality": p04_quality_root,
        },
        implementation_artifacts={
            IMPLEMENTATION_IDS[0]: (
                "release",
                release_root / "bin/ash-calibration-cli",
                release_root,
            ),
            IMPLEMENTATION_IDS[1]: (
                "release",
                release_root / "sources/production-swift-source-manifest.json",
                release_root,
            ),
            IMPLEMENTATION_IDS[2]: (
                "release",
                release_root / "sources/independent-python-source-manifest.json",
                release_root,
            ),
            IMPLEMENTATION_IDS[3]: (
                "repository",
                repository_root / "validation/calibration_v2/release_orchestrator.py",
                repository_root,
            ),
            IMPLEMENTATION_IDS[4]: (
                "repository",
                repository_root
                / "validation/calibration_v2/tools/run_p06_production_calibration.py",
                repository_root,
            ),
        },
        macos_code_identities=macos_code_identities,
        selected_control_artifacts={
            identifier: ("release", control_paths[identifier], release_root)
            for identifier in SELECTED_CONTROL_IDS
        },
        support_evidence_trees={
            SUPPORT_TREE_IDS[0]: (
                "open_split",
                open_split_root / "quality-corpus-v1",
                open_split_root,
            ),
            SUPPORT_TREE_IDS[1]: (
                "calibration_evidence",
                evidence_root,
                evidence_root.parent,
            ),
            SUPPORT_TREE_IDS[2]: (
                "native_cache",
                native_cache_root,
                native_cache_root.parent,
            ),
            SUPPORT_TREE_IDS[3]: (
                "production_writer",
                writer_root,
                writer_root.parent,
            ),
            SUPPORT_TREE_IDS[4]: (
                "dispatch_measurement",
                dispatch_measurement_root,
                dispatch_measurement_root.parent,
            ),
        },
        test_evidence={
            identifier: ("release", path, release_root)
            for identifier, path in copied_tests.items()
        },
        preserved_failures={
            identifier: ("release", path, release_root)
            for identifier, path in copied_failures.items()
        },
        calibration_run_path=calibration_run_root,
        calibration_run_root=calibration_run_root.parent,
    )
    bound_inputs.verify_unchanged()
    bundle = build_p06_release_bundle_manifest(
        release_root=release_root,
        output_path=release_root / "p06-release-bundle.json",
        configuration_id=configuration_id,
        locked_utc=locked_utc,
        input_bundle_sha256=str(selection["input_bundle_sha256"]),
        corpus_lock_bundle_sha256=str(selection["corpus_lock_bundle_sha256"]),
        selected_evaluation_path=selected_relative,
        transaction_id=transaction_id,
    )
    bound_inputs.verify_unchanged()
    return bundle


def build_p06_release_transaction(
    *,
    repository_root: Path,
    calibration_run_root: Path,
    release_root: Path,
    native_cache_root: Path,
    open_split_root: Path,
    evidence_root: Path,
    writer_root: Path,
    dispatch_measurement_root: Path,
    p04_quality_root: Path,
    locked_utc: str,
    bound_inputs: object,
    test_evidence_paths: Mapping[str, Path],
    preserved_failure_paths: Mapping[str, Path],
) -> Mapping[str, object]:
    """Create, validate, and atomically publish one selected P06 release bundle."""

    destination = Path(os.path.abspath(release_root))
    partial = destination.with_name(f".{destination.name}.partial")
    failed = destination.with_name(f"{destination.name}.failed")
    marker = destination.with_name(
        f".{destination.name}{P06_TRANSACTION_MARKER_SUFFIX}"
    )
    if (
        destination.parent != partial.parent
        or destination.parent != failed.parent
        or destination.parent != marker.parent
        or destination.name in {"", ".", ".."}
    ):
        raise P06ReleaseOrchestrationError(
            "P06 release transaction paths are not safe siblings"
        )
    repository = repository_root.resolve(strict=True)
    bound_repository = CALIBRATION_ROOT.parents[1].resolve(strict=True)
    if repository != bound_repository:
        raise P06ReleaseOrchestrationError(
            "repository root differs from the bound release orchestrator checkout"
        )
    run = calibration_run_root.resolve(strict=True)
    dispatch_root = dispatch_measurement_root.resolve(strict=True)
    open_split = open_split_root.resolve(strict=True)
    evidence = evidence_root.resolve(strict=True)
    writer = writer_root.resolve(strict=True)
    native_cache = native_cache_root.resolve(strict=True)
    p04_root = p04_quality_root.resolve(strict=True)
    expected_repository_state, repository_clean = _repository_state()
    if not repository_clean:
        raise P06ReleaseOrchestrationError(
            "repository working tree is not clean at release publication start"
        )
    support_roots = {
        "open_split": open_split,
        "calibration_evidence": evidence.parent,
        "native_cache": native_cache.parent,
        "production_writer": writer.parent,
        "dispatch_measurement": dispatch_root.parent,
        "calibration_run": run.parent,
    }
    parent_identity = _reject_aliased_directory(
        destination.parent,
        label="P06 release parent",
    )
    support_snapshots = _open_support_tree_snapshots(support_roots)
    try:
        parent_descriptor = _open_directory(destination.parent)
    except Exception:
        _close_support_tree_snapshots(support_snapshots)
        raise
    opened_parent = os.fstat(parent_descriptor)
    if _identity(opened_parent) != _identity(parent_identity):
        os.close(parent_descriptor)
        _close_support_tree_snapshots(support_snapshots)
        raise P06ReleaseOrchestrationError(
            "P06 release parent changed while being opened"
        )

    def verify_final_sources(*, label: str) -> None:
        _require_repository_state(expected_repository_state, label=label)
        verifier = getattr(bound_inputs, "verify_unchanged", None)
        if not callable(verifier):
            raise P06ReleaseOrchestrationError(
                "bound input verifier is unavailable"
            )
        verifier()
        _verify_support_tree_snapshots(support_snapshots)

    def entry_metadata(name: str) -> os.stat_result | None:
        try:
            return os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            raise P06ReleaseOrchestrationError(
                f"cannot inspect recognized P06 transaction entry: {name}"
            ) from error

    def validate_owned_release(
        *,
        entry_name: str,
        entry_path: Path,
        root_descriptor: int,
        root_identity: os.stat_result,
        manifest_payload: bytes,
        expected_bundle: Mapping[str, object] | None,
    ) -> Mapping[str, object]:
        _require_parent_path_identity(destination.parent, parent_identity)
        _require_directory_identity_at(
            parent_descriptor,
            entry_name,
            root_identity,
            label="P06 release validation root",
        )
        descriptor_manifest, _ = _read_regular_at(
            root_descriptor,
            "p06-release-bundle.json",
        )
        if descriptor_manifest != manifest_payload:
            raise P06ReleaseOrchestrationError(
                "descriptor-pinned release manifest changed"
            )
        reopened = validate_p06_release_bundle_manifest(
            release_root=entry_path,
            manifest_path=entry_path / "p06-release-bundle.json",
            support_evidence_roots=support_roots,
        )
        _require_parent_path_identity(destination.parent, parent_identity)
        _require_directory_identity_at(
            parent_descriptor,
            entry_name,
            root_identity,
            label="P06 release validation root",
        )
        reopened_manifest, _ = _read_regular_at(
            root_descriptor,
            "p06-release-bundle.json",
        )
        if (
            reopened_manifest != manifest_payload
            or (
                expected_bundle is not None
                and not _json_exact_equal(reopened, expected_bundle)
            )
        ):
            raise P06ReleaseOrchestrationError(
                "P06 release bundle changed during semantic validation"
            )
        return reopened

    def validate_completed_final_without_marker() -> Mapping[str, object]:
        final_metadata = entry_metadata(destination.name)
        if final_metadata is None or not stat.S_ISDIR(final_metadata.st_mode):
            raise P06ReleaseOrchestrationError(
                "pre-existing P06 final is not a real directory"
            )
        final_descriptor = _open_owned_release_directory_at(
            parent_descriptor,
            destination.name,
            final_metadata,
        )
        try:
            before = _release_tree_snapshot(
                final_descriptor,
                require_frozen=True,
            )
            manifest_payload, _ = _read_regular_at(
                final_descriptor,
                "p06-release-bundle.json",
            )
            _require_repository_state(
                expected_repository_state,
                label="before completed-release recovery",
            )
            reopened = validate_owned_release(
                entry_name=destination.name,
                entry_path=destination,
                root_descriptor=final_descriptor,
                root_identity=final_metadata,
                manifest_payload=manifest_payload,
                expected_bundle=None,
            )
            if reopened.get("locked_utc") != locked_utc:
                raise P06ReleaseOrchestrationError(
                    "pre-existing P06 final belongs to a different transaction"
                )
            after = _release_tree_snapshot(
                final_descriptor,
                require_frozen=True,
            )
            if after != before:
                raise P06ReleaseOrchestrationError(
                    "pre-existing P06 final changed during recovery"
                )
            verify_final_sources(label="before completed-release return")
            return reopened
        finally:
            os.close(final_descriptor)

    marker_descriptor: int | None = None
    marker_identity: os.stat_result | None = None
    root_descriptor: int | None = None
    partial_identity: os.stat_result | None = None
    transaction_id = uuid.uuid4().hex
    sequence = 0
    stage = "preflight"
    recovery_quarantine_attempted = False

    def record_stage(next_stage: str) -> None:
        nonlocal sequence, stage
        if marker_descriptor is None:
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker descriptor is absent"
            )
        _append_transaction_event(
            parent_descriptor,
            marker.name,
            marker_descriptor,
            _transaction_event(
                transaction_id=transaction_id,
                sequence=sequence,
                stage=next_stage,
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                locked_utc=locked_utc,
                repository_state=expected_repository_state,
                parent_identity=parent_identity,
                root_identity=partial_identity,
            ),
        )
        os.fsync(parent_descriptor)
        sequence += 1
        stage = next_stage

    def remove_transaction_token() -> None:
        if root_descriptor is None:
            raise P06ReleaseOrchestrationError("P06 release root is not open")
        try:
            token_metadata = os.stat(
                P06_TRANSACTION_TOKEN_NAME,
                dir_fd=root_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        payload, opened = _read_regular_at(
            root_descriptor,
            P06_TRANSACTION_TOKEN_NAME,
        )
        if (
            payload != f"{transaction_id}\n".encode("ascii")
            or _identity(opened) != _identity(token_metadata)
        ):
            raise P06ReleaseOrchestrationError(
                "P06 partial transaction token differs"
            )
        current = os.stat(
            P06_TRANSACTION_TOKEN_NAME,
            dir_fd=root_descriptor,
            follow_symlinks=False,
        )
        if _identity(current) != _identity(opened):
            raise P06ReleaseOrchestrationError(
                "P06 partial transaction token was replaced"
            )
        os.unlink(P06_TRANSACTION_TOKEN_NAME, dir_fd=root_descriptor)
        os.fsync(root_descriptor)

    def finish_release(
        *,
        current_name: str,
        current_path: Path,
        manifest_payload: bytes,
        bundle: Mapping[str, object],
    ) -> Mapping[str, object]:
        if root_descriptor is None or partial_identity is None:
            raise P06ReleaseOrchestrationError(
                "P06 release root is not pinned for finalization"
            )
        current_bundle = validate_owned_release(
            entry_name=current_name,
            entry_path=current_path,
            root_descriptor=root_descriptor,
            root_identity=partial_identity,
            manifest_payload=manifest_payload,
            expected_bundle=bundle,
        )
        _require_repository_state(
            expected_repository_state,
            label="before descendant sealing",
        )
        before_sealing = _release_tree_snapshot(
            root_descriptor,
            require_frozen=False,
        )
        if current_name == partial.name:
            record_stage("validated_partial")
            _freeze_release_descendants(
                root_descriptor,
                expected_root_identity=partial_identity,
            )
            descendant_sealed = _release_tree_snapshot(
                root_descriptor,
                require_frozen=True,
                require_root_frozen=False,
            )
            if descendant_sealed != before_sealing:
                raise P06ReleaseOrchestrationError(
                    "P06 release tree changed while sealing descendants"
                )
            current_bundle = validate_owned_release(
                entry_name=partial.name,
                entry_path=partial,
                root_descriptor=root_descriptor,
                root_identity=partial_identity,
                manifest_payload=manifest_payload,
                expected_bundle=bundle,
            )
            _require_repository_state(
                expected_repository_state,
                label="after descendant sealing",
            )
            if (
                _release_tree_snapshot(
                    root_descriptor,
                    require_frozen=True,
                    require_root_frozen=False,
                )
                != before_sealing
            ):
                raise P06ReleaseOrchestrationError(
                    "P06 release tree changed after sealed validation"
                )
            record_stage("descendants_sealed")
            _require_parent_path_identity(destination.parent, parent_identity)
            for name, label in (
                (destination.name, "P06 release destination"),
                (failed.name, "P06 release failure path"),
            ):
                try:
                    _require_absent_at(parent_descriptor, name, label=label)
                except RuntimeCorrectionArtifactError as error:
                    raise P06ReleaseOrchestrationError(str(error)) from error
            _rename_release_exclusive_at(
                parent_descriptor,
                partial.name,
                destination.name,
            )
            current_name = destination.name
            current_path = destination
            record_stage("published_descendants_sealed")
            _require_parent_path_identity(destination.parent, parent_identity)
            _require_directory_identity_at(
                parent_descriptor,
                destination.name,
                partial_identity,
                label="published P06 release root",
            )
        else:
            if (
                _release_tree_snapshot(
                    root_descriptor,
                    require_frozen=True,
                    require_root_frozen=False,
                )
                != before_sealing
            ):
                raise P06ReleaseOrchestrationError(
                    "recovered P06 final is not descendant-sealed"
                )
        _seal_release_root(
            root_descriptor,
            expected_root_identity=partial_identity,
        )
        record_stage("root_sealed")
        fully_sealed = _release_tree_snapshot(
            root_descriptor,
            require_frozen=True,
        )
        if fully_sealed != before_sealing:
            raise P06ReleaseOrchestrationError(
                "P06 release tree changed during root sealing"
            )
        _require_repository_state(
            expected_repository_state,
            label="before final frozen semantic validation",
        )
        if marker_identity is None:
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker identity is absent"
            )
        final_bundle = validate_owned_release(
            entry_name=destination.name,
            entry_path=destination,
            root_descriptor=root_descriptor,
            root_identity=partial_identity,
            manifest_payload=manifest_payload,
            expected_bundle=current_bundle,
        )
        if (
            final_bundle.get("locked_utc") != locked_utc
            or _release_tree_snapshot(root_descriptor, require_frozen=True)
            != fully_sealed
        ):
            raise P06ReleaseOrchestrationError(
                "final frozen P06 release verification differs"
            )
        verify_final_sources(label="before final release marker removal")
        _unlink_owned_marker(
            parent_descriptor,
            marker.name,
            marker_identity,
        )
        return final_bundle

    try:
        staged_transaction_id = _transaction_marker_creation_id_at(
            parent_descriptor,
            marker.name,
        )
        append_entries = _transaction_append_entries_at(
            parent_descriptor,
            marker.name,
        )
        if staged_transaction_id is not None:
            transaction_id = staged_transaction_id
        recognized = {
            destination.name: entry_metadata(destination.name),
            partial.name: entry_metadata(partial.name),
            failed.name: entry_metadata(failed.name),
            marker.name: entry_metadata(marker.name),
        }
        if recognized[marker.name] is not None and staged_transaction_id is not None:
            raise P06ReleaseOrchestrationError(
                "P06 transaction marker conflicts with its creation stage"
            )
        if recognized[marker.name] is None and append_entries:
            raise P06ReleaseOrchestrationError(
                "P06 transaction append sidecar has no canonical marker"
            )
        if recognized[marker.name] is None:
            if recognized[destination.name] is not None:
                if staged_transaction_id is not None:
                    raise P06ReleaseOrchestrationError(
                        "completed P06 recovery conflicts with marker creation"
                    )
                if (
                    recognized[partial.name] is not None
                    or recognized[failed.name] is not None
                ):
                    raise P06ReleaseOrchestrationError(
                        "completed P06 recovery has conflicting recognized entries"
                    )
                return validate_completed_final_without_marker()
            if any(
                recognized[name] is not None
                for name in (partial.name, failed.name)
            ):
                raise P06ReleaseOrchestrationError(
                    "unrecognized P06 partial or failure path already exists"
                )
            initial_event = _transaction_event(
                transaction_id=transaction_id,
                sequence=0,
                stage="intent_durable",
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                locked_utc=locked_utc,
                repository_state=expected_repository_state,
                parent_identity=parent_identity,
                root_identity=None,
            )
            marker_descriptor, marker_identity = _create_transaction_marker(
                parent_descriptor,
                marker.name,
                initial_event,
            )
            sequence = 1
            stage = "intent_durable"
            os.mkdir(partial.name, 0o700, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
            partial_identity = _stat_directory_at(
                parent_descriptor,
                partial.name,
                label="P06 partial publication root",
            )
            root_descriptor = _open_owned_release_directory_at(
                parent_descriptor,
                partial.name,
                partial_identity,
            )
            _write_new_at(
                root_descriptor,
                P06_TRANSACTION_TOKEN_NAME,
                f"{transaction_id}\n".encode("ascii"),
            )
            record_stage("partial_created")
            _require_parent_path_identity(destination.parent, parent_identity)
            bundle = _publish_release(
                repository_root=repository,
                calibration_run_root=run,
                release_root=partial,
                native_cache_root=native_cache,
                open_split_root=open_split,
                evidence_root=evidence,
                writer_root=writer,
                dispatch_measurement_root=dispatch_root,
                p04_quality_root=p04_root,
                transaction_id=transaction_id,
                locked_utc=locked_utc,
                bound_inputs=bound_inputs,
                test_evidence_paths=test_evidence_paths,
                preserved_failure_paths=preserved_failure_paths,
            )
            record_stage("build_completed")
            _require_parent_path_identity(destination.parent, parent_identity)
            _require_directory_identity_at(
                parent_descriptor,
                partial.name,
                partial_identity,
                label="built P06 partial publication root",
            )
            manifest_payload, _ = _read_regular_at(
                root_descriptor,
                "p06-release-bundle.json",
            )
            remove_transaction_token()
            record_stage("transaction_token_removed")
            _require_repository_state(
                expected_repository_state,
                label="during release construction",
            )
            return finish_release(
                current_name=partial.name,
                current_path=partial,
                manifest_payload=manifest_payload,
                bundle=bundle,
            )

        marker_descriptor, marker_identity, events = _read_transaction_marker_at(
            parent_descriptor,
            marker.name,
        )
        first = events[0]
        if (
            first.get("destination_name") != destination.name
            or first.get("partial_name") != partial.name
            or first.get("failed_name") != failed.name
            or first.get("locked_utc") != locked_utc
            or first.get("repository_state") != expected_repository_state
            or first.get("parent_device") != parent_identity.st_dev
            or first.get("parent_inode") != parent_identity.st_ino
        ):
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction marker belongs to another transaction"
            )
        raw_transaction_id = first.get("transaction_id")
        if not isinstance(raw_transaction_id, str):
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction ID is invalid"
            )
        try:
            parsed_transaction_id = uuid.UUID(hex=raw_transaction_id)
        except ValueError as error:
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction ID is invalid"
            ) from error
        if parsed_transaction_id.hex != raw_transaction_id:
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction ID is not canonical"
            )
        transaction_id = raw_transaction_id
        sequence = len(events)
        stage = str(events[-1].get("stage"))
        rooted_events = [
            event
            for event in events
            if isinstance(event.get("root_device"), int)
            and isinstance(event.get("root_inode"), int)
        ]
        if rooted_events:
            expected_root_identity = (
                rooted_events[-1]["root_device"],
                rooted_events[-1]["root_inode"],
            )
            if any(
                (event["root_device"], event["root_inode"])
                != expected_root_identity
                for event in rooted_events
            ):
                raise P06ReleaseOrchestrationError(
                    "recognized P06 transaction root identity changed"
                )
        else:
            expected_root_identity = None
        owned_name = None
        for name in (destination.name, partial.name, failed.name):
            metadata = recognized[name]
            if metadata is None or not stat.S_ISDIR(metadata.st_mode):
                continue
            if expected_root_identity is None:
                if name != partial.name:
                    continue
                probe = _open_owned_release_directory_at(
                    parent_descriptor,
                    name,
                    metadata,
                )
                try:
                    token, _ = _read_regular_at(probe, P06_TRANSACTION_TOKEN_NAME)
                finally:
                    os.close(probe)
                if token != f"{transaction_id}\n".encode("ascii"):
                    continue
                expected_root_identity = _identity(metadata)
            if _identity(metadata) == expected_root_identity:
                if owned_name is not None:
                    raise P06ReleaseOrchestrationError(
                        "recognized P06 transaction inode has duplicate names"
                    )
                owned_name = name
                partial_identity = metadata
        if owned_name is None or partial_identity is None:
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction has no authenticated release root"
            )
        conflicting_names = [
            name
            for name in (destination.name, partial.name, failed.name)
            if name != owned_name and recognized[name] is not None
        ]
        if conflicting_names:
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction has a foreign conflicting entry"
            )
        root_descriptor = _open_owned_release_directory_at(
            parent_descriptor,
            owned_name,
            partial_identity,
        )
        if owned_name == failed.name:
            recovery_quarantine_attempted = True
            interrupted_failure = P06ReleaseOrchestrationError(
                "authenticated interrupted P06 failure publication"
            )
            _quarantine_release_publication(
                parent_descriptor=parent_descriptor,
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                expected=partial_identity,
                root_descriptor=root_descriptor,
                marker_name=marker.name,
                marker_descriptor=marker_descriptor,
                marker_identity=marker_identity,
                transaction_id=transaction_id,
                stage=stage,
                error=interrupted_failure,
            )
            raise P06ReleaseOrchestrationError(
                "authenticated interrupted P06 failure publication was recovered"
            )
        if owned_name == destination.name:
            recovered_root = os.fstat(root_descriptor)
            if not getattr(recovered_root, "st_flags", 0) & getattr(
                stat,
                "UF_IMMUTABLE",
                0,
            ):
                os.fchmod(
                    root_descriptor,
                    stat.S_IMODE(recovered_root.st_mode)
                    & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH),
                )
                os.fsync(root_descriptor)
        remove_transaction_token()
        manifest_payload, _ = _read_regular_at(
            root_descriptor,
            "p06-release-bundle.json",
        )
        recovered_bundle = validate_owned_release(
            entry_name=owned_name,
            entry_path=destination if owned_name == destination.name else partial,
            root_descriptor=root_descriptor,
            root_identity=partial_identity,
            manifest_payload=manifest_payload,
            expected_bundle=None,
        )
        if recovered_bundle.get("locked_utc") != locked_utc:
            raise P06ReleaseOrchestrationError(
                "recognized P06 transaction manifest differs"
            )
        record_stage("recovery_validated")
        return finish_release(
            current_name=owned_name,
            current_path=destination if owned_name == destination.name else partial,
            manifest_payload=manifest_payload,
            bundle=recovered_bundle,
        )
    except Exception as error:
        if (
            partial_identity is not None
            and root_descriptor is not None
            and marker_descriptor is not None
            and marker_identity is not None
            and not recovery_quarantine_attempted
        ):
            _quarantine_release_publication(
                parent_descriptor=parent_descriptor,
                destination_name=destination.name,
                partial_name=partial.name,
                failed_name=failed.name,
                expected=partial_identity,
                root_descriptor=root_descriptor,
                marker_name=marker.name,
                marker_descriptor=marker_descriptor,
                marker_identity=marker_identity,
                transaction_id=transaction_id,
                stage=stage,
                error=error,
            )
        elif marker_descriptor is not None and marker_identity is not None:
            recognized_root_remains = any(
                entry_metadata(name) is not None
                for name in (destination.name, partial.name, failed.name)
            )
            if not recognized_root_remains:
                try:
                    _unlink_owned_marker(
                        parent_descriptor,
                        marker.name,
                        marker_identity,
                    )
                except Exception as cleanup_error:
                    raise P06ReleaseOrchestrationError(
                        f"P06 cleanup failed before partial creation: {cleanup_error}"
                    ) from error
        raise
    finally:
        if root_descriptor is not None:
            os.close(root_descriptor)
        if marker_descriptor is not None:
            os.close(marker_descriptor)
        os.close(parent_descriptor)
        _close_support_tree_snapshots(support_snapshots)


__all__ = [
    "P06ReleaseOrchestrationError",
    "build_p06_release_transaction",
]
