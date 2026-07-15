#!/usr/bin/env python3
"""Build or read-only verify the deterministic spatial-policy admissibility lock."""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import stat
import sys
import uuid
from typing import Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.reference.spatial_policy_admissibility_v2 import (  # noqa: E402
    SpatialPolicyContractError,
    build_spatial_policy_admissibility_manifest,
    validate_spatial_policy_admissibility_manifest_file,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
)


_RENAME_EXCL = 0x00000004
_RENAME_NOFOLLOW_ANY = 0x00000010
_RENAME_RESOLVE_BENEATH = 0x00000020
_LIBC = ctypes.CDLL(None, use_errno=True)
_RENAMEATX_NP = getattr(_LIBC, "renameatx_np", None)
if _RENAMEATX_NP is not None:
    _RENAMEATX_NP.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    _RENAMEATX_NP.restype = ctypes.c_int


def _open_directory_nofollow(
    path: Path, *, label: str
) -> tuple[int, os.stat_result, Path]:
    absolute = Path(os.path.abspath(path))
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(
        os, "O_NOFOLLOW", 0
    )
    try:
        descriptor = os.open(absolute.anchor, flags)
    except OSError as error:
        raise SpatialPolicyContractError(
            f"{label} root cannot be opened safely"
        ) from error
    try:
        metadata = os.fstat(descriptor)
        for component in absolute.parts[1:]:
            try:
                before = os.stat(
                    component, dir_fd=descriptor, follow_symlinks=False
                )
            except OSError as error:
                raise SpatialPolicyContractError(
                    f"{label} component is absent: {component}"
                ) from error
            if not stat.S_ISDIR(before.st_mode):
                raise SpatialPolicyContractError(
                    f"{label} component is not a real directory: {component}"
                )
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                raise SpatialPolicyContractError(
                    f"{label} component cannot be opened safely: {component}"
                ) from error
            child_metadata = os.fstat(child)
            if (
                not stat.S_ISDIR(child_metadata.st_mode)
                or (child_metadata.st_dev, child_metadata.st_ino)
                != (before.st_dev, before.st_ino)
            ):
                os.close(child)
                raise SpatialPolicyContractError(
                    f"{label} component changed while opening: {component}"
                )
            os.close(descriptor)
            descriptor = child
            metadata = child_metadata
        return descriptor, metadata, absolute
    except BaseException:
        os.close(descriptor)
        raise


def _verify_directory_identity(
    path: Path, expected: os.stat_result, *, label: str
) -> None:
    descriptor, current, _ = _open_directory_nofollow(path, label=label)
    try:
        if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            raise SpatialPolicyContractError(f"{label} identity changed")
    finally:
        os.close(descriptor)


def _stat_at_optional(parent_descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SpatialPolicyContractError(
            f"cannot inspect output entry: {name}"
        ) from error


def _require_absent_at(parent_descriptor: int, name: str) -> None:
    if _stat_at_optional(parent_descriptor, name) is not None:
        raise SpatialPolicyContractError(f"output path already exists: {name}")


def _rename_exclusive_at(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
) -> None:
    if _RENAMEATX_NP is None:
        raise SpatialPolicyContractError(
            "exclusive descriptor-pinned publication is unavailable"
        )
    ctypes.set_errno(0)
    result = _RENAMEATX_NP(
        source_parent_descriptor,
        os.fsencode(source_name),
        destination_parent_descriptor,
        os.fsencode(destination_name),
        _RENAME_EXCL | _RENAME_NOFOLLOW_ANY | _RENAME_RESOLVE_BENEATH,
    )
    if result == 0:
        return
    number = ctypes.get_errno() or errno.EIO
    if number == errno.EEXIST:
        raise SpatialPolicyContractError(
            f"output path already exists: {destination_name}"
        )
    raise SpatialPolicyContractError(
        f"exclusive manifest publication failed: {os.strerror(number)}"
    )


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise SpatialPolicyContractError("manifest write made no progress")
        offset += written


def _read_all(descriptor: int) -> bytes:
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def _verify_published_file(
    parent_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
    expected_payload: bytes,
) -> None:
    metadata = _stat_at_optional(parent_descriptor, name)
    if (
        metadata is None
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or (metadata.st_dev, metadata.st_ino) != expected_identity
        or metadata.st_size != len(expected_payload)
    ):
        raise SpatialPolicyContractError("published manifest identity is invalid")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise SpatialPolicyContractError(
            "published manifest cannot be reopened safely"
        ) from error
    try:
        opened = os.fstat(descriptor)
        payload = _read_all(descriptor)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = _stat_at_optional(parent_descriptor, name)
    if (
        current is None
        or (opened.st_dev, opened.st_ino) != expected_identity
        or (after.st_dev, after.st_ino) != expected_identity
        or (current.st_dev, current.st_ino) != expected_identity
        or opened.st_nlink != 1
        or after.st_nlink != 1
        or current.st_nlink != 1
        or opened.st_size != len(expected_payload)
        or after.st_size != len(expected_payload)
        or current.st_size != len(expected_payload)
        or opened.st_mtime_ns != after.st_mtime_ns
        or opened.st_ctime_ns != after.st_ctime_ns
        or payload != expected_payload
    ):
        raise SpatialPolicyContractError(
            "published manifest changed during reopen verification"
        )


def _remove_owned_output(
    parent_descriptor: int, name: str, expected_identity: tuple[int, int]
) -> None:
    current = _stat_at_optional(parent_descriptor, name)
    if current is None:
        return
    if (current.st_dev, current.st_ino) != expected_identity:
        raise SpatialPolicyContractError(
            "failed publication destination no longer names the owned inode"
        )
    os.unlink(name, dir_fd=parent_descriptor)
    os.fsync(parent_descriptor)


def _publish_exclusive(
    path: Path,
    manifest: Mapping[str, object],
    *,
    repository_root: Path,
) -> str:
    output = Path(os.path.abspath(path))
    if not output.name or output.name in {".", ".."}:
        raise SpatialPolicyContractError("output path has an invalid leaf name")
    parent_descriptor, parent_metadata, parent_path = _open_directory_nofollow(
        output.parent, label="output parent"
    )
    payload = canonical_json_bytes(manifest) + b"\n"
    stage_name = f".{output.name}.{uuid.uuid4().hex}.stage"
    temporary_name = "manifest.tmp"
    stage_descriptor = -1
    stage_identity: tuple[int, int] | None = None
    published_identity: tuple[int, int] | None = None
    descriptor = -1
    try:
        _require_absent_at(parent_descriptor, output.name)
        os.mkdir(stage_name, 0o700, dir_fd=parent_descriptor)
        stage_before = os.stat(
            stage_name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        stage_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(
            os, "O_NOFOLLOW", 0
        )
        stage_descriptor = os.open(
            stage_name, stage_flags, dir_fd=parent_descriptor
        )
        stage_opened = os.fstat(stage_descriptor)
        if (
            not stat.S_ISDIR(stage_opened.st_mode)
            or (stage_opened.st_dev, stage_opened.st_ino)
            != (stage_before.st_dev, stage_before.st_ino)
        ):
            raise SpatialPolicyContractError("private staging identity is invalid")
        stage_identity = (stage_opened.st_dev, stage_opened.st_ino)
        descriptor = os.open(
            temporary_name,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=stage_descriptor,
        )
        _write_all(descriptor, payload)
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
        temporary_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(temporary_metadata.st_mode)
            or temporary_metadata.st_nlink != 1
            or temporary_metadata.st_size != len(payload)
        ):
            raise SpatialPolicyContractError("temporary manifest identity is invalid")
        os.lseek(descriptor, 0, os.SEEK_SET)
        if _read_all(descriptor) != payload:
            raise SpatialPolicyContractError("temporary manifest byte verification failed")
        os.close(descriptor)
        descriptor = -1
        os.fsync(stage_descriptor)
        _require_absent_at(parent_descriptor, output.name)
        _verify_directory_identity(
            parent_path, parent_metadata, label="output parent"
        )
        _rename_exclusive_at(
            stage_descriptor,
            temporary_name,
            parent_descriptor,
            output.name,
        )
        published_identity = (
            temporary_metadata.st_dev,
            temporary_metadata.st_ino,
        )
        published = os.stat(
            output.name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if (published.st_dev, published.st_ino) != published_identity:
            raise SpatialPolicyContractError("published manifest inode changed")
        os.fsync(parent_descriptor)
        _verify_published_file(
            parent_descriptor, output.name, published_identity, payload
        )
        os.close(stage_descriptor)
        stage_descriptor = -1
        os.rmdir(stage_name, dir_fd=parent_descriptor)
        stage_identity = None
        os.fsync(parent_descriptor)
        _verify_directory_identity(
            parent_path, parent_metadata, label="output parent"
        )
        digest = validate_spatial_policy_admissibility_manifest_file(
            output,
            repository_root=repository_root,
        )
        _verify_directory_identity(
            parent_path, parent_metadata, label="output parent"
        )
        _verify_published_file(
            parent_descriptor, output.name, published_identity, payload
        )
        return digest
    except BaseException:
        cleanup_error: BaseException | None = None
        if descriptor >= 0:
            os.close(descriptor)
        if published_identity is not None:
            try:
                _remove_owned_output(
                    parent_descriptor, output.name, published_identity
                )
            except BaseException as error:
                cleanup_error = error
        if stage_descriptor >= 0:
            try:
                os.unlink(temporary_name, dir_fd=stage_descriptor)
            except FileNotFoundError:
                pass
            os.close(stage_descriptor)
        if stage_identity is not None:
            current_stage = _stat_at_optional(parent_descriptor, stage_name)
            if current_stage is not None and (
                current_stage.st_dev,
                current_stage.st_ino,
            ) == stage_identity:
                try:
                    os.rmdir(stage_name, dir_fd=parent_descriptor)
                    os.fsync(parent_descriptor)
                except OSError as error:
                    if cleanup_error is None:
                        cleanup_error = error
        if cleanup_error is not None:
            raise SpatialPolicyContractError(
                "manifest publication failed and owned cleanup was incomplete"
            ) from cleanup_error
        raise
    finally:
        os.close(parent_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--repository-root", required=True, type=Path)
    build.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--repository-root", required=True, type=Path)
    verify.add_argument("--manifest", required=True, type=Path)
    return parser


def _print_status(status: str, manifest_sha256: str) -> None:
    print(
        json.dumps(
            {
                "manifest_sha256": manifest_sha256,
                "status": status,
            },
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    repository_root = Path(os.path.abspath(arguments.repository_root))
    if repository_root != REPOSITORY_ROOT:
        raise SpatialPolicyContractError(
            "repository root must match the CLI implementation root"
        )
    if arguments.command == "build":
        manifest = build_spatial_policy_admissibility_manifest(repository_root)
        digest = _publish_exclusive(
            arguments.output,
            repository_root=repository_root,
            manifest=manifest,
        )
        _print_status("built_and_verified", digest)
        return 0
    digest = validate_spatial_policy_admissibility_manifest_file(
        arguments.manifest,
        repository_root=repository_root,
    )
    _print_status("verified", digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
