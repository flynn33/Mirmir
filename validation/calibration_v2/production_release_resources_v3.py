"""Export the exact six P08 product resources from one authenticated V3 release."""

from __future__ import annotations

import ctypes
import errno
import hashlib
import os
from pathlib import Path
import secrets
import stat
from typing import Callable, Mapping, NamedTuple, Tuple

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


def _file_identity(metadata: os.stat_result) -> Tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


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
        try:
            exact_entries = os.listdir(cursor)
        except OSError as error:
            raise ProductionReleaseResourcesV3Error(
                f"{label} is absent"
            ) from error
        if part not in exact_entries:
            raise ProductionReleaseResourcesV3Error(
                f"{label} does not use exact directory entry spelling"
            )
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
        if _file_identity(opened) != _file_identity(metadata):
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
    try:
        reopened = os.lstat(path)
    except OSError as error:
        raise ProductionReleaseResourcesV3Error(
            f"{label} changed after reading"
        ) from error
    if (
        _file_identity(after) != _file_identity(metadata)
        or _file_identity(reopened) != _file_identity(metadata)
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
    bytes_completed = False
    close_completed = False
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
        bytes_completed = True
    finally:
        try:
            os.close(descriptor)
            close_completed = True
        finally:
            if not bytes_completed or not close_completed:
                try:
                    os.unlink(name, dir_fd=directory)
                except FileNotFoundError:
                    pass
                except OSError as cleanup_error:
                    raise ProductionReleaseResourcesV3Error(
                        "failed new-file bytes could not be removed"
                    ) from cleanup_error


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


def _quarantine_interrupted_partials(
    parent: Path,
    *,
    staging_prefix: str,
    label: str,
) -> None:
    interrupted = sorted(
        name
        for name in os.listdir(parent)
        if name.startswith(staging_prefix) and name.endswith(".partial")
    )
    if not interrupted:
        return
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in interrupted:
            failure_name = (
                f"{name}.interrupted.{secrets.token_hex(16)}.failed"
            )
            try:
                _exclusive_rename(
                    descriptor,
                    name,
                    failure_name,
                )
            except (OSError, ProductionReleaseResourcesV3Error) as error:
                raise ProductionReleaseResourcesV3Error(
                    f"{label} could not be quarantined"
                ) from error
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


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
    member_identities = {}
    for identifier, filename in P08_RELEASE_RESOURCES_V3:
        member = root / filename
        member_identity = _file_identity(os.lstat(member))
        payload = _read_file(member, label=f"P08 resource {filename}")
        if payload != expected[filename]:
            raise ProductionReleaseResourcesV3Error(
                f"P08 resource bytes differ from V3 release: {filename}"
            )
        if _file_identity(os.lstat(member)) != member_identity:
            raise ProductionReleaseResourcesV3Error(
                f"P08 resource changed while reopening: {filename}"
            )
        member_identities[filename] = member_identity
        rows.append(
            {
                "release_artifact_id": identifier,
                "filename": filename,
                "sha256": _sha256(payload),
                "size_bytes": len(payload),
            }
        )
    if tuple(sorted(os.listdir(root))) != tuple(sorted(expected_names)):
        raise ProductionReleaseResourcesV3Error(
            "P08 resource root changed across exact-six reopening"
        )
    for filename, identity in member_identities.items():
        try:
            reopened = os.lstat(root / filename)
        except OSError as error:
            raise ProductionReleaseResourcesV3Error(
                f"P08 resource changed across exact-six reopening: {filename}"
            ) from error
        if _file_identity(reopened) != identity:
            raise ProductionReleaseResourcesV3Error(
                f"P08 resource changed across exact-six reopening: {filename}"
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


class _ReceiptPublication(NamedTuple):
    published_new: bool
    inode_identity: Tuple[int, int]
    failure_name: str


def _quarantine_owned_receipt(
    path: Path,
    *,
    inode_identity: Tuple[int, int],
    failure_name: str,
) -> None:
    parent = _strict_directory(path.parent, label="exact-six receipt parent")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ProductionReleaseResourcesV3Error(
            "owned exact-six receipt is absent during quarantine"
        ) from error
    if (metadata.st_dev, metadata.st_ino) != inode_identity:
        raise ProductionReleaseResourcesV3Error(
            "owned exact-six receipt changed identity before quarantine"
        )
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        _exclusive_rename(
            descriptor,
            path.name,
            failure_name,
        )
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _publish_receipt(
    path: Path,
    document: Mapping[str, object],
    *,
    verify_before_commit: Callable[[], None],
) -> _ReceiptPublication:
    payload = canonical_json_file_bytes_v2(document)
    if not path.is_absolute() or path.parent == path:
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt path is not absolute"
        )
    parent = _strict_directory(path.parent, label="exact-six receipt parent")
    staging_prefix = f".{path.name}.p06-v3-exact-six-receipt."
    _quarantine_interrupted_partials(
        parent,
        staging_prefix=staging_prefix,
        label="interrupted exact-six receipt partial",
    )
    staging_name = f"{staging_prefix}{secrets.token_hex(16)}.partial"
    staging_path = parent / staging_name
    staging_failure_name = f"{staging_name}.failed"
    published_failure_name = f"{staging_name}.published.failed"
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    staging_present = False
    published_new = False
    published_identity = (0, 0)
    try:
        if path.exists() or path.is_symlink():
            if _read_file(path, label="existing exact-six receipt") != payload:
                raise ProductionReleaseResourcesV3Error(
                    "published exact-six receipt identifies different bytes"
                )
            verify_before_commit()
            if _read_file(path, label="reopened exact-six receipt") != payload:
                raise ProductionReleaseResourcesV3Error(
                    "published exact-six receipt identifies different bytes"
                )
            os.fsync(descriptor)
            metadata = os.lstat(path)
            return _ReceiptPublication(
                False,
                (metadata.st_dev, metadata.st_ino),
                "",
            )

        _write_new_at(descriptor, staging_name, payload)
        staging_present = True
        if _read_file(staging_path, label="staged exact-six receipt") != payload:
            raise ProductionReleaseResourcesV3Error(
                "staged exact-six receipt identifies different bytes"
            )
        verify_before_commit()
        if _read_file(
            staging_path,
            label="reopened staged exact-six receipt",
        ) != payload:
            raise ProductionReleaseResourcesV3Error(
                "staged exact-six receipt identifies different bytes"
            )
        staged_metadata = os.lstat(staging_path)
        try:
            _exclusive_rename(descriptor, staging_name, path.name)
        except FileExistsError:
            os.unlink(staging_name, dir_fd=descriptor)
            staging_present = False
        else:
            staging_present = False
            published_new = True
            published_identity = (
                staged_metadata.st_dev,
                staged_metadata.st_ino,
            )
        os.fsync(descriptor)
        if _read_file(path, label="published exact-six receipt") != payload:
            raise ProductionReleaseResourcesV3Error(
                "published exact-six receipt identifies different bytes"
            )
        metadata = os.lstat(path)
        if published_new and (
            metadata.st_dev,
            metadata.st_ino,
        ) != published_identity:
            raise ProductionReleaseResourcesV3Error(
                "published exact-six receipt changed identity"
            )
        return _ReceiptPublication(
            published_new,
            (metadata.st_dev, metadata.st_ino),
            published_failure_name if published_new else "",
        )
    except BaseException:
        if staging_present:
            try:
                _exclusive_rename(
                    descriptor,
                    staging_name,
                    staging_failure_name,
                )
                os.fsync(descriptor)
            except (
                OSError,
                ProductionReleaseResourcesV3Error,
            ) as preservation_error:
                raise ProductionReleaseResourcesV3Error(
                    "failed exact-six receipt partial could not be preserved"
                ) from preservation_error
        if published_new:
            try:
                _quarantine_owned_receipt(
                    path,
                    inode_identity=published_identity,
                    failure_name=published_failure_name,
                )
            except ProductionReleaseResourcesV3Error as quarantine_error:
                raise ProductionReleaseResourcesV3Error(
                    "failed published exact-six receipt could not be quarantined"
                ) from quarantine_error
        raise
    finally:
        os.close(descriptor)


def _paths_overlap(left: Path, right: Path) -> bool:
    return (
        left == right
        or left in right.parents
        or right in left.parents
    )


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
    strict_support_roots = {
        identifier: _strict_directory(
            support_evidence_roots[identifier],
            label=f"P06 support root {identifier}",
        )
        for identifier in sorted(P06_SUPPORT_EVIDENCE_ROOT_IDS)
    }
    release_manifest_payload = _read_file(
        manifest_path,
        label="P06 V3 release manifest",
    )
    bundle = validate_p06_release_bundle_manifest(
        release_root=release,
        manifest_path=manifest_path,
        support_evidence_roots=strict_support_roots,
    )
    if (
        bundle.get("schema_version") != "3.0.1"
        or bundle.get("bundle_id") != "mirmir-p06-spatial-release-lock-v3"
        or bundle.get("holdout_accessed") is not False
    ):
        raise ProductionReleaseResourcesV3Error(
            "P08 resources require one authenticated holdout-free V3 release"
        )
    if canonical_json_file_bytes_v2(bundle) != release_manifest_payload:
        raise ProductionReleaseResourcesV3Error(
            "P06 V3 release manifest bytes differ from validated authority"
        )
    if _read_file(
        manifest_path,
        label="reopened P06 V3 release manifest",
    ) != release_manifest_payload:
        raise ProductionReleaseResourcesV3Error(
            "P06 V3 release manifest changed during initial replay"
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
    if not isinstance(receipt_path, Path) or not receipt_path.is_absolute():
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt path is not absolute"
        )
    receipt_normalized = Path(os.path.normpath(os.fspath(receipt_path)))
    if receipt_normalized != receipt_path or receipt_path.parent == receipt_path:
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt path is not lexically safe"
        )
    protected_roots = {
        "release": release,
        **{
            f"support:{identifier}": strict_support_roots[identifier]
            for identifier in sorted(P06_SUPPORT_EVIDENCE_ROOT_IDS)
        },
    }
    for output_label, output_path in (
        ("resource_root", resource_root),
        ("receipt_path", receipt_path),
    ):
        for protected_label, protected_root in protected_roots.items():
            if _paths_overlap(output_path, protected_root):
                raise ProductionReleaseResourcesV3Error(
                    "P08 publication output overlaps protected input root: "
                    f"{output_label}/{protected_label}"
                )
    parent = _strict_directory(
        resource_root.parent,
        label="P08 exact-six resource parent",
    )
    try:
        receipt_normalized.relative_to(resource_root)
    except ValueError:
        pass
    else:
        raise ProductionReleaseResourcesV3Error(
            "exact-six receipt must be outside the six-file resource root"
        )
    _strict_directory(
        receipt_path.parent,
        label="exact-six receipt parent",
    )
    if resource_root.exists() or resource_root.is_symlink():
        rows = _verify_exact_six(resource_root, expected)
    else:
        staging_prefix = f".{resource_root.name}.p06-v3-exact-six."
        _quarantine_interrupted_partials(
            parent,
            staging_prefix=staging_prefix,
            label="interrupted exact-six partial",
        )
        staging_name = (
            staging_prefix
            +
            f"{secrets.token_hex(16)}.partial"
        )
        parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        staging_descriptor = -1
        staging_present = False
        try:
            os.mkdir(staging_name, 0o700, dir_fd=parent_descriptor)
            staging_present = True
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
                staging_present = False
            else:
                staging_present = False
            os.fsync(parent_descriptor)
        except BaseException:
            if staging_descriptor >= 0:
                os.close(staging_descriptor)
                staging_descriptor = -1
            if staging_present:
                failed_name = f"{staging_name}.failed"
                try:
                    _exclusive_rename(
                        parent_descriptor,
                        staging_name,
                        failed_name,
                    )
                    os.fsync(parent_descriptor)
                except (
                    OSError,
                    ProductionReleaseResourcesV3Error,
                ) as preservation_error:
                    raise ProductionReleaseResourcesV3Error(
                        "failed exact-six partial could not be preserved"
                    ) from preservation_error
            raise
        finally:
            if staging_descriptor >= 0:
                os.close(staging_descriptor)
            os.close(parent_descriptor)
        rows = _verify_exact_six(resource_root, expected)

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
    resource_root_identity = (
        resource_identity.st_dev,
        resource_identity.st_ino,
        resource_identity.st_mode,
    )
    release_root_identity = (
        release_identity.st_dev,
        release_identity.st_ino,
        release_identity.st_mode,
        release_identity.st_mtime_ns,
        release_identity.st_ctime_ns,
    )

    def verify_before_receipt_commit() -> None:
        reopened_bundle = validate_p06_release_bundle_manifest(
            release_root=release,
            manifest_path=manifest_path,
            support_evidence_roots=strict_support_roots,
        )
        if reopened_bundle != bundle:
            raise ProductionReleaseResourcesV3Error(
                "P06 V3 release authority changed during exact-six export"
            )
        if _read_file(
            manifest_path,
            label="final P06 V3 release manifest",
        ) != release_manifest_payload:
            raise ProductionReleaseResourcesV3Error(
                "P06 V3 release manifest bytes changed during exact-six export"
            )
        if _verify_exact_six(resource_root, expected) != rows:
            raise ProductionReleaseResourcesV3Error(
                "P08 exact-six resources changed before receipt commit"
            )
        reopened_resource = os.lstat(resource_root)
        if (
            reopened_resource.st_dev,
            reopened_resource.st_ino,
            reopened_resource.st_mode,
        ) != resource_root_identity:
            raise ProductionReleaseResourcesV3Error(
                "P08 exact-six resource root changed before receipt commit"
            )
        reopened_release = os.lstat(release)
        if (
            reopened_release.st_dev,
            reopened_release.st_ino,
            reopened_release.st_mode,
            reopened_release.st_mtime_ns,
            reopened_release.st_ctime_ns,
        ) != release_root_identity:
            raise ProductionReleaseResourcesV3Error(
                "P06 V3 release root changed during exact-six export"
            )

    publication = _publish_receipt(
        receipt_path,
        document,
        verify_before_commit=verify_before_receipt_commit,
    )
    try:
        if _verify_exact_six(resource_root, expected) != rows:
            raise ProductionReleaseResourcesV3Error(
                "P08 exact-six resources changed after receipt commit"
            )
        reopened_resource = os.lstat(resource_root)
        if (
            reopened_resource.st_dev,
            reopened_resource.st_ino,
            reopened_resource.st_mode,
        ) != resource_root_identity:
            raise ProductionReleaseResourcesV3Error(
                "P08 exact-six resource root changed after receipt commit"
            )
        if _read_file(
            receipt_path,
            label="terminal exact-six receipt",
        ) != canonical_json_file_bytes_v2(document):
            raise ProductionReleaseResourcesV3Error(
                "terminal exact-six receipt identifies different bytes"
            )
    except BaseException:
        if publication.published_new:
            try:
                _quarantine_owned_receipt(
                    receipt_path,
                    inode_identity=publication.inode_identity,
                    failure_name=publication.failure_name,
                )
            except ProductionReleaseResourcesV3Error as quarantine_error:
                raise ProductionReleaseResourcesV3Error(
                    "failed terminal exact-six receipt could not be quarantined"
                ) from quarantine_error
        raise
    return document


__all__ = [
    "P08_RELEASE_RESOURCES_V3",
    "ProductionReleaseResourcesV3Error",
    "export_p08_release_resources_v3",
]
