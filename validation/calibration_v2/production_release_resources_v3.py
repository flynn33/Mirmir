"""Export the exact six P08 product resources from one authenticated V3 release."""

from __future__ import annotations

import ctypes
import errno
import hashlib
import os
from pathlib import Path
import secrets
import stat
from typing import Mapping, Tuple

from validation.calibration_v2.calibration_persistence_v2 import (
    canonical_json_file_bytes_v2,
)
from validation.calibration_v2.release_lock import (
    P06_SUPPORT_EVIDENCE_ROOT_IDS,
    validate_p06_release_bundle_manifest,
)
from validation.quality.src.mirmir_quality.json_tools import canonical_sha256


P08_RELEASE_RESOURCES_V3: Tuple[Tuple[str, str], ...] = (
    ("lut_manifest", "lut-manifest-v3.json"),
    ("locked_compiler_input_v2", "locked-compiler-input-v2.json"),
    ("locked_mapping", "locked-mapping.json"),
    ("direct2x_lut", "direct2x.ashlut"),
    ("direct3over2_lut", "direct3over2.ashlut"),
    ("native_parity_manifest", "native-lut-parity-manifest-v3.json"),
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


class ProductionReleaseResourcesV3Error(ValueError):
    """The V3 release or exact-six publication differs from authority."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _strict_directory(path: Path, *, label: str) -> Path:
    if not isinstance(path, Path) or not path.is_absolute():
        raise ProductionReleaseResourcesV3Error(f"{label} is not absolute")
    normalized = Path(os.path.normpath(os.fspath(path)))
    if normalized != path:
        raise ProductionReleaseResourcesV3Error(
            f"{label} is not lexically normalized"
        )
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor /= part
        try:
            metadata = os.lstat(cursor)
        except OSError as error:
            raise ProductionReleaseResourcesV3Error(f"{label} is absent") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ProductionReleaseResourcesV3Error(
                f"{label} traverses a link or non-directory"
            )
    return path


def _read_file(path: Path, *, label: str) -> bytes:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ProductionReleaseResourcesV3Error(f"{label} is absent") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        raise ProductionReleaseResourcesV3Error(
            f"{label} is linked or is not singular regular bytes"
        )
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise ProductionReleaseResourcesV3Error(f"{label} changed while opening")
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
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
    ):
        raise ProductionReleaseResourcesV3Error(f"{label} changed while reading")
    return b"".join(chunks)


def _write_new_at(directory: int, name: str, payload: bytes) -> None:
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o444,
        dir_fd=directory,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise ProductionReleaseResourcesV3Error(
                    "exact-six publication made no progress"
                )
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _exclusive_rename(parent: int, source: str, destination: str) -> None:
    if _RENAMEATX_NP is None:
        raise ProductionReleaseResourcesV3Error(
            "exclusive no-follow directory publication is unavailable"
        )
    ctypes.set_errno(0)
    result = _RENAMEATX_NP(
        parent,
        os.fsencode(source),
        parent,
        os.fsencode(destination),
        _RENAME_EXCL | _RENAME_NOFOLLOW_ANY | _RENAME_RESOLVE_BENEATH,
    )
    if result == 0:
        return
    number = ctypes.get_errno() or errno.EIO
    if number in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError(number, os.strerror(number), destination)
    raise OSError(number, os.strerror(number), destination)


def _verify_exact_six(
    root: Path,
    expected: Mapping[str, bytes],
) -> Tuple[Mapping[str, object], ...]:
    _strict_directory(root, label="P08 exact-six resource root")
    before = os.lstat(root)
    expected_names = tuple(filename for _, filename in P08_RELEASE_RESOURCES_V3)
    if tuple(sorted(os.listdir(root))) != tuple(sorted(expected_names)):
        raise ProductionReleaseResourcesV3Error(
            "P08 resource root is not the exact authorized six-file set"
        )
    rows = []
    for identifier, filename in P08_RELEASE_RESOURCES_V3:
        payload = _read_file(root / filename, label=f"P08 resource {filename}")
        if payload != expected[filename]:
            raise ProductionReleaseResourcesV3Error(
                f"P08 resource bytes differ from V3 release: {filename}"
            )
        rows.append(
            {
                "release_artifact_id": identifier,
                "filename": filename,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
            }
        )
    after = os.lstat(root)
    if (
        before.st_dev,
        before.st_ino,
        before.st_mode,
        before.st_mtime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_mtime_ns,
    ):
        raise ProductionReleaseResourcesV3Error(
            "P08 exact-six resource root changed while reopening"
        )
    return tuple(rows)


def _publish_receipt(path: Path, document: Mapping[str, object]) -> None:
    payload = canonical_json_file_bytes_v2(document)
    if not path.is_absolute() or path.parent == path:
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt path is not absolute"
        )
    parent = _strict_directory(path.parent, label="exact-six receipt parent")
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            _write_new_at(descriptor, path.name, payload)
        except FileExistsError:
            if _read_file(path, label="existing exact-six receipt") != payload:
                raise ProductionReleaseResourcesV3Error(
                    "published exact-six receipt identifies different bytes"
                )
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def export_p08_release_resources_v3(
    *,
    release_root: Path,
    resource_root: Path,
    receipt_path: Path,
    support_evidence_roots: Mapping[str, Path],
) -> Mapping[str, object]:
    """Fully replay V3 support authority, then publish the exact six files."""

    release = _strict_directory(release_root, label="P06 V3 release root")
    release_identity = os.lstat(release)
    manifest_path = release / "p06-release-bundle.json"
    if (
        not isinstance(support_evidence_roots, Mapping)
        or set(support_evidence_roots) != P06_SUPPORT_EVIDENCE_ROOT_IDS
        or any(
            not isinstance(path, Path)
            for path in support_evidence_roots.values()
        )
    ):
        raise ProductionReleaseResourcesV3Error(
            "P08 export requires the exact six P06 support roots"
        )
    bundle = validate_p06_release_bundle_manifest(
        release_root=release,
        manifest_path=manifest_path,
        support_evidence_roots=support_evidence_roots,
    )
    if (
        bundle.get("schema_version") != "3.0.1"
        or bundle.get("bundle_id") != "mirmir-p06-spatial-release-lock-v3"
        or bundle.get("holdout_accessed") is not False
    ):
        raise ProductionReleaseResourcesV3Error(
            "P08 resources require one authenticated holdout-free V3 release"
        )
    artifacts = bundle.get("artifacts")
    if type(artifacts) is not list:
        raise ProductionReleaseResourcesV3Error("V3 release artifacts are absent")
    by_id = {
        str(row.get("id")): row for row in artifacts if type(row) is dict
    }
    expected: dict[str, bytes] = {}
    for identifier, filename in P08_RELEASE_RESOURCES_V3:
        row = by_id.get(identifier)
        if type(row) is not dict or row.get("path") != filename:
            raise ProductionReleaseResourcesV3Error(
                f"V3 release resource binding is absent: {identifier}"
            )
        payload = _read_file(release / filename, label=f"V3 release {filename}")
        if row.get("sha256") != _sha256(payload) or row.get("size_bytes") != len(
            payload
        ):
            raise ProductionReleaseResourcesV3Error(
                f"V3 release resource changed: {identifier}"
            )
        expected[filename] = payload

    if not resource_root.is_absolute():
        raise ProductionReleaseResourcesV3Error(
            "P08 exact-six resource root is not absolute"
        )
    normalized = Path(os.path.normpath(os.fspath(resource_root)))
    if normalized != resource_root or resource_root.parent == resource_root:
        raise ProductionReleaseResourcesV3Error(
            "P08 exact-six resource root is not lexically safe"
        )
    parent = _strict_directory(
        resource_root.parent,
        label="P08 exact-six resource parent",
    )
    receipt_normalized = Path(os.path.normpath(os.fspath(receipt_path)))
    try:
        receipt_normalized.relative_to(resource_root)
    except ValueError:
        pass
    else:
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt must be outside the six-file resource root"
        )
    if resource_root.exists() or resource_root.is_symlink():
        rows = _verify_exact_six(resource_root, expected)
    else:
        staging_prefix = f".{resource_root.name}.p06-v3-exact-six."
        foreign_staging = sorted(
            name
            for name in os.listdir(parent)
            if name.startswith(staging_prefix) and name.endswith(".partial")
        )
        if foreign_staging:
            raise ProductionReleaseResourcesV3Error(
                "foreign exact-six partial publication is present"
            )
        staging_name = (
            staging_prefix
            +
            f"{secrets.token_hex(16)}.partial"
        )
        parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        staging_descriptor = -1
        try:
            os.mkdir(staging_name, 0o700, dir_fd=parent_descriptor)
            staging_descriptor = os.open(
                staging_name,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_descriptor,
            )
            for _, filename in P08_RELEASE_RESOURCES_V3:
                _write_new_at(staging_descriptor, filename, expected[filename])
            os.fsync(staging_descriptor)
            try:
                _exclusive_rename(
                    parent_descriptor,
                    staging_name,
                    resource_root.name,
                )
            except FileExistsError:
                for _, filename in P08_RELEASE_RESOURCES_V3:
                    os.unlink(filename, dir_fd=staging_descriptor)
                os.close(staging_descriptor)
                staging_descriptor = -1
                os.rmdir(staging_name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
        finally:
            if staging_descriptor >= 0:
                os.close(staging_descriptor)
            os.close(parent_descriptor)
        rows = _verify_exact_six(resource_root, expected)

    release_manifest_payload = _read_file(
        manifest_path,
        label="P06 V3 release manifest",
    )
    core = {
        "schema_version": "1.0.0",
        "artifact_kind": "p08_exact_six_release_resource_receipt_v1",
        "status": "published_and_reopened",
        "release_bundle": {
            "path": "p06-release-bundle.json",
            "sha256": _sha256(release_manifest_payload),
            "size_bytes": len(release_manifest_payload),
            "artifact_sha256": bundle["artifact_sha256"],
        },
        "resource_root": os.fspath(resource_root),
        "resource_count": 6,
        "resources": list(rows),
        "resource_set_sha256": canonical_sha256(list(rows)),
        "support_evidence_root_ids": sorted(P06_SUPPORT_EVIDENCE_ROOT_IDS),
        "full_support_replay_performed": True,
        "holdout_accessed": False,
    }
    document = {**core, "artifact_sha256": canonical_sha256(core)}
    resource_identity = os.lstat(resource_root)
    _publish_receipt(receipt_path, document)
    reopened_resource_identity = os.lstat(resource_root)
    if (
        resource_identity.st_dev,
        resource_identity.st_ino,
        resource_identity.st_mode,
    ) != (
        reopened_resource_identity.st_dev,
        reopened_resource_identity.st_ino,
        reopened_resource_identity.st_mode,
    ):
        raise ProductionReleaseResourcesV3Error(
            "P08 exact-six resource root changed before receipt completion"
        )
    reopened_release_identity = os.lstat(release)
    if (
        release_identity.st_dev,
        release_identity.st_ino,
        release_identity.st_mode,
        release_identity.st_mtime_ns,
    ) != (
        reopened_release_identity.st_dev,
        reopened_release_identity.st_ino,
        reopened_release_identity.st_mode,
        reopened_release_identity.st_mtime_ns,
    ):
        raise ProductionReleaseResourcesV3Error(
            "P06 V3 release root changed during exact-six export"
        )
    return document


__all__ = [
    "P08_RELEASE_RESOURCES_V3",
    "ProductionReleaseResourcesV3Error",
    "export_p08_release_resources_v3",
]
