"""Authenticated immutable snapshots of multi-file evidence closures.

The capture boundary retains descriptors for the artifact root, every opened
parent directory, and every captured file.  macOS vnode events make a mutation
that occurs after an earlier pathname check observable at the final boundary;
capture fails closed when that facility is unavailable.  Semantic consumers
receive only immutable authenticated bytes and never depend on another rolling
filesystem reopen.

The successful result proves the returned snapshot bytes.  It does not claim
that a mutable filesystem remains unchanged after the final observation.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import threading
from types import MappingProxyType
from typing import Dict, Mapping, Optional, Tuple


CLOSURE_HASH_DOMAIN_V2 = "mirmir-p06-authenticated-closure-snapshot-v2"
_CLOSURE_HASH_PREFIX = CLOSURE_HASH_DOMAIN_V2.encode("ascii") + b"\x00"
_READ_CHUNK_SIZE = 1024 * 1024
_SAFE_RELATIVE_PATH_CHARACTERS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-"
)
_ZERO_SHA256 = "0" * 64


class AuthenticatedClosureSnapshotV2Error(ValueError):
    """A closure binding, captured byte, descriptor, or path is invalid."""


def _is_sha256(value: object) -> bool:
    return (
        type(value) is str
        and len(value) == 64
        and value != _ZERO_SHA256
        and all(character in "0123456789abcdef" for character in value)
    )


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_json_bytes(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise AuthenticatedClosureSnapshotV2Error(
            "closure identity cannot be canonically encoded"
        ) from error


@dataclass(frozen=True)
class ClosureFileBindingV2:
    """One exact regular-file binding beneath an artifact root."""

    path: str
    sha256: str
    size_bytes: int

    def __post_init__(self) -> None:
        if (
            type(self.path) is not str
            or not self.path
            or self.path.startswith("/")
            or "\\" in self.path
            or any(
                character not in _SAFE_RELATIVE_PATH_CHARACTERS
                for character in self.path
            )
            or any(part in {"", ".", ".."} for part in self.path.split("/"))
            or not _is_sha256(self.sha256)
            or type(self.size_bytes) is not int
            or self.size_bytes < 0
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "closure file binding is invalid"
            )


@dataclass(frozen=True)
class ClosureFileSnapshotV2:
    """Immutable bytes for one authenticated closure binding."""

    binding: ClosureFileBindingV2
    payload: bytes

    def __post_init__(self) -> None:
        if (
            type(self.binding) is not ClosureFileBindingV2
            or type(self.payload) is not bytes
            or len(self.payload) != self.binding.size_bytes
            or _sha256(self.payload) != self.binding.sha256
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "closure file snapshot differs from its binding"
            )


@dataclass(frozen=True, init=False)
class AuthenticatedClosureSnapshotV2:
    """A portable immutable view of one authenticated binding set."""

    _files: Tuple[ClosureFileSnapshotV2, ...]
    _by_path: Mapping[str, ClosureFileSnapshotV2]
    _closure_sha256: str

    def __init__(self, files: Tuple[ClosureFileSnapshotV2, ...]) -> None:
        if (
            type(files) is not tuple
            or not files
            or any(type(item) is not ClosureFileSnapshotV2 for item in files)
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "authenticated closure snapshot is empty or invalid"
            )
        ordered = tuple(sorted(files, key=lambda item: item.binding.path))
        paths = [item.binding.path for item in ordered]
        if len(set(paths)) != len(paths):
            raise AuthenticatedClosureSnapshotV2Error(
                "authenticated closure snapshot paths repeat"
            )
        object.__setattr__(self, "_files", ordered)
        object.__setattr__(
            self,
            "_by_path",
            MappingProxyType({item.binding.path: item for item in ordered}),
        )
        identity = {
            "hash_domain": CLOSURE_HASH_DOMAIN_V2,
            "files": [
                {
                    "path": item.binding.path,
                    "sha256": item.binding.sha256,
                    "size_bytes": item.binding.size_bytes,
                }
                for item in ordered
            ],
        }
        object.__setattr__(
            self,
            "_closure_sha256",
            _sha256(_CLOSURE_HASH_PREFIX + _canonical_json_bytes(identity)),
        )

    @property
    def files(self) -> Tuple[ClosureFileSnapshotV2, ...]:
        return self._files

    @property
    def bindings(self) -> Tuple[ClosureFileBindingV2, ...]:
        return tuple(item.binding for item in self._files)

    @property
    def closure_sha256(self) -> str:
        return self._closure_sha256

    def payload(self, binding: ClosureFileBindingV2) -> bytes:
        """Return bytes only when the complete binding triple matches."""

        if type(binding) is not ClosureFileBindingV2:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure lookup binding has wrong type"
            )
        item = self._by_path.get(binding.path)
        if item is None or item.binding != binding:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure lookup binding is absent or differs"
            )
        return item.payload

    def __len__(self) -> int:
        return len(self._files)


@dataclass(frozen=True)
class _StableIdentityV2:
    device: int
    inode: int
    mode: int
    link_count: int
    size_bytes: int
    modified_ns: int
    changed_ns: int

    @classmethod
    def from_status(cls, status: os.stat_result) -> "_StableIdentityV2":
        return cls(
            device=status.st_dev,
            inode=status.st_ino,
            mode=status.st_mode,
            link_count=status.st_nlink,
            size_bytes=status.st_size,
            modified_ns=status.st_mtime_ns,
            changed_ns=status.st_ctime_ns,
        )


@dataclass(frozen=True)
class _RetainedDirectoryV2:
    path: str
    parent_descriptor: int
    name: str
    descriptor: int
    identity: _StableIdentityV2


@dataclass(frozen=True)
class _RetainedFileV2:
    binding: ClosureFileBindingV2
    parent_descriptor: int
    name: str
    descriptor: int
    identity: _StableIdentityV2
    payload: bytes
    label: str


class AuthenticatedClosureCaptureV2:
    """Retain and watch one closure while snapshot-backed replay executes."""

    def __init__(
        self,
        root: Path,
        *,
        expected_root_identity: Optional[Tuple[int, int]] = None,
    ) -> None:
        supplied_root = Path(os.path.abspath(os.fspath(root)))
        if supplied_root.is_symlink():
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact root itself must not be a symlink"
            )
        if expected_root_identity is not None and (
            type(expected_root_identity) is not tuple
            or len(expected_root_identity) != 2
            or any(type(value) is not int for value in expected_root_identity)
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "expected closure artifact-root identity is invalid"
            )
        self.root = Path(os.path.realpath(os.fspath(supplied_root)))
        self._expected_root_identity = expected_root_identity
        self._state = "new"
        self._poisoned = False
        self._kqueue: Optional[object] = None
        self._root_descriptor: Optional[int] = None
        self._root_identity: Optional[_StableIdentityV2] = None
        self._root_components: Tuple[Tuple[str, int, int], ...] = ()
        self._directories: Dict[str, _RetainedDirectoryV2] = {}
        self._files: Dict[str, _RetainedFileV2] = {}
        self._owned_descriptors = []
        self._watch_labels: Dict[int, str] = {}
        self._snapshot: Optional[AuthenticatedClosureSnapshotV2] = None
        self._owner: Optional[Tuple[int, object]] = None

    @property
    def closed(self) -> bool:
        return self._state == "closed"

    @property
    def root_identity(self) -> Tuple[int, int]:
        """Return the retained artifact-root device/inode while active."""

        self._require_owner_execution()
        if self._state != "active" or self._root_descriptor is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact-root identity is unavailable"
            )
        status = os.fstat(self._root_descriptor)
        return status.st_dev, status.st_ino

    @property
    def captured_file_count(self) -> int:
        """Return the number of exact file bindings retained so far."""

        self._require_owner_execution()
        if self._state != "active":
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture is not active"
            )
        return len(self._files)

    def cancel_empty(self) -> None:
        """Close a replay scope that performed no filesystem-dependent read."""

        self._require_owner_execution()
        if (
            self._state != "active"
            or self._files
            or self._snapshot is not None
            or self._poisoned
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "only an unused closure capture can be cancelled"
            )
        self._close()

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )

    @staticmethod
    def _file_flags() -> int:
        return (
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )

    @staticmethod
    def _require_kqueue_support() -> None:
        required = (
            "kqueue",
            "kevent",
            "KQ_FILTER_VNODE",
            "KQ_EV_ADD",
            "KQ_EV_ENABLE",
            "KQ_EV_CLEAR",
            "KQ_NOTE_WRITE",
            "KQ_NOTE_DELETE",
            "KQ_NOTE_RENAME",
            "KQ_NOTE_ATTRIB",
            "KQ_NOTE_EXTEND",
            "KQ_NOTE_LINK",
            "KQ_NOTE_REVOKE",
        )
        if any(not hasattr(select, name) for name in required) or not callable(
            getattr(select, "kqueue", None)
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "authenticated closure capture requires macOS kqueue vnode support"
            )

    @staticmethod
    def _vnode_note_flags() -> int:
        return (
            select.KQ_NOTE_WRITE
            | select.KQ_NOTE_DELETE
            | select.KQ_NOTE_RENAME
            | select.KQ_NOTE_ATTRIB
            | select.KQ_NOTE_EXTEND
            | select.KQ_NOTE_LINK
            | select.KQ_NOTE_REVOKE
        )

    def _register_descriptor(self, descriptor: int, *, label: str) -> None:
        if self._kqueue is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure event queue is unavailable"
            )
        try:
            change = select.kevent(
                descriptor,
                filter=select.KQ_FILTER_VNODE,
                flags=(
                    select.KQ_EV_ADD
                    | select.KQ_EV_ENABLE
                    | select.KQ_EV_CLEAR
                ),
                fflags=self._vnode_note_flags(),
            )
            self._kqueue.control([change], 0, 0)
        except (OSError, ValueError) as error:
            raise AuthenticatedClosureSnapshotV2Error(
                f"{label} vnode watch cannot be registered"
            ) from error
        self._watch_labels[descriptor] = label

    @classmethod
    def _open_root(
        cls,
        root: Path,
    ) -> Tuple[int, Tuple[Tuple[str, int, int], ...]]:
        descriptor = None
        identities = []
        try:
            descriptor = os.open(os.sep, cls._directory_flags())
            for component in root.parts[1:]:
                opened = None
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened = os.open(
                        component,
                        cls._directory_flags(),
                        dir_fd=descriptor,
                    )
                    current = os.fstat(opened)
                    after = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    if opened is not None:
                        os.close(opened)
                    raise AuthenticatedClosureSnapshotV2Error(
                        "closure artifact-root component cannot be opened"
                    ) from error
                identity = (current.st_dev, current.st_ino)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(current.st_mode)
                    or not stat.S_ISDIR(after.st_mode)
                    or (before.st_dev, before.st_ino) != identity
                    or (after.st_dev, after.st_ino) != identity
                ):
                    os.close(opened)
                    raise AuthenticatedClosureSnapshotV2Error(
                        "closure artifact-root component identity changed"
                    )
                identities.append((component, *identity))
                os.close(descriptor)
                descriptor = opened
            if descriptor is None:
                raise AssertionError("root descriptor was not opened")
            return descriptor, tuple(identities)
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
            raise

    def _activate(self) -> None:
        self._require_kqueue_support()
        try:
            self._kqueue = select.kqueue()
        except OSError as error:
            raise AuthenticatedClosureSnapshotV2Error(
                "authenticated closure event queue cannot be opened"
            ) from error
        descriptor, components = self._open_root(self.root)
        self._root_descriptor = descriptor
        self._root_components = components
        self._owned_descriptors.append(descriptor)
        status = os.fstat(descriptor)
        if not stat.S_ISDIR(status.st_mode):
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact root is not a directory"
            )
        if (
            self._expected_root_identity is not None
            and (status.st_dev, status.st_ino) != self._expected_root_identity
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact root differs from its pinned identity"
            )
        self._root_identity = _StableIdentityV2.from_status(status)
        self._register_descriptor(descriptor, label="closure artifact root")

    def __enter__(self) -> "AuthenticatedClosureCaptureV2":
        if self._state != "new":
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture cannot be entered more than once"
            )
        self._owner = self._current_owner()
        self._state = "active"
        try:
            self._activate()
        except BaseException:
            self._close()
            raise
        return self

    @staticmethod
    def _current_owner() -> Tuple[int, object]:
        try:
            task: object = asyncio.current_task()
        except RuntimeError:
            task = None
        return threading.get_ident(), task

    def _require_owner_execution(self) -> None:
        if self._owner is None or self._owner != self._current_owner():
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture cannot cross its owner execution boundary"
            )

    def _require_active_unsealed(self) -> None:
        self._require_owner_execution()
        if self._state != "active":
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture is not active"
            )
        if self._snapshot is not None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture is already sealed"
            )
        if self._poisoned:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture previously failed"
            )

    def _open_parent_directory(self, path: str) -> int:
        if self._root_descriptor is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact root descriptor is unavailable"
            )
        parent_descriptor = self._root_descriptor
        prefix = []
        for component in path.split("/")[:-1]:
            prefix.append(component)
            relative_path = "/".join(prefix)
            retained = self._directories.get(relative_path)
            if retained is not None:
                parent_descriptor = retained.descriptor
                continue
            descriptor = None
            try:
                before = os.stat(
                    component,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                descriptor = os.open(
                    component,
                    self._directory_flags(),
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                ):
                    raise AuthenticatedClosureSnapshotV2Error(
                        f"closure directory {relative_path} identity changed"
                    )
                self._owned_descriptors.append(descriptor)
                self._register_descriptor(
                    descriptor,
                    label=f"closure directory {relative_path}",
                )
                after_descriptor = os.fstat(descriptor)
                after_path = os.stat(
                    component,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                opened_identity = _StableIdentityV2.from_status(opened)
                if (
                    opened_identity
                    != _StableIdentityV2.from_status(after_descriptor)
                    or opened_identity != _StableIdentityV2.from_status(after_path)
                ):
                    raise AuthenticatedClosureSnapshotV2Error(
                        f"closure directory {relative_path} changed while opening"
                    )
                retained = _RetainedDirectoryV2(
                    path=relative_path,
                    parent_descriptor=parent_descriptor,
                    name=component,
                    descriptor=descriptor,
                    identity=opened_identity,
                )
                self._directories[relative_path] = retained
                parent_descriptor = descriptor
            except OSError as error:
                if (
                    descriptor is not None
                    and descriptor not in self._owned_descriptors
                ):
                    os.close(descriptor)
                raise AuthenticatedClosureSnapshotV2Error(
                    f"closure directory {relative_path} cannot be safely opened"
                ) from error
            except BaseException:
                if (
                    descriptor is not None
                    and descriptor not in self._owned_descriptors
                ):
                    os.close(descriptor)
                raise
        return parent_descriptor

    @staticmethod
    def _read_descriptor(descriptor: int) -> bytes:
        chunks = []
        try:
            while True:
                chunk = os.read(descriptor, _READ_CHUNK_SIZE)
                if not chunk:
                    break
                chunks.append(chunk)
        except OSError as error:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure file changed or failed while reading"
            ) from error
        return b"".join(chunks)

    def capture(
        self,
        binding: ClosureFileBindingV2,
        *,
        label: str,
    ) -> bytes:
        """Capture one exact file and retain its descriptor until context exit."""

        try:
            self._require_active_unsealed()
            if type(binding) is not ClosureFileBindingV2:
                raise AuthenticatedClosureSnapshotV2Error(
                    "closure capture binding has wrong type"
                )
            if type(label) is not str or not label:
                raise AuthenticatedClosureSnapshotV2Error(
                    "closure capture label is invalid"
                )
            prior = self._files.get(binding.path)
            if prior is not None:
                if prior.binding != binding:
                    raise AuthenticatedClosureSnapshotV2Error(
                        "closure path identifies conflicting bindings"
                    )
                return prior.payload

            parent_descriptor = self._open_parent_directory(binding.path)
            name = binding.path.split("/")[-1]
            descriptor = None
            try:
                before_path = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                descriptor = os.open(
                    name,
                    self._file_flags(),
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(before_path.st_mode)
                    or not stat.S_ISREG(opened.st_mode)
                    or (before_path.st_dev, before_path.st_ino)
                    != (opened.st_dev, opened.st_ino)
                ):
                    raise AuthenticatedClosureSnapshotV2Error(
                        f"{label} is not a stable regular file"
                    )
                self._owned_descriptors.append(descriptor)
                self._register_descriptor(descriptor, label=label)
                payload = self._read_descriptor(descriptor)
                after_descriptor = os.fstat(descriptor)
                after_path = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                opened_identity = _StableIdentityV2.from_status(opened)
                if (
                    opened_identity
                    != _StableIdentityV2.from_status(after_descriptor)
                    or opened_identity != _StableIdentityV2.from_status(after_path)
                    or len(payload) != opened.st_size
                ):
                    raise AuthenticatedClosureSnapshotV2Error(
                        f"{label} changed while read and captured"
                    )
                if (
                    len(payload) != binding.size_bytes
                    or _sha256(payload) != binding.sha256
                ):
                    raise AuthenticatedClosureSnapshotV2Error(
                        f"{label} bytes differ from the closure binding"
                    )
                retained = _RetainedFileV2(
                    binding=binding,
                    parent_descriptor=parent_descriptor,
                    name=name,
                    descriptor=descriptor,
                    identity=opened_identity,
                    payload=bytes(payload),
                    label=label,
                )
                self._files[binding.path] = retained
                return retained.payload
            except OSError as error:
                if (
                    descriptor is not None
                    and descriptor not in self._owned_descriptors
                ):
                    os.close(descriptor)
                raise AuthenticatedClosureSnapshotV2Error(
                    f"{label} cannot be safely opened or inspected"
                ) from error
            except BaseException:
                if (
                    descriptor is not None
                    and descriptor not in self._owned_descriptors
                ):
                    os.close(descriptor)
                raise
        except BaseException:
            self._poisoned = True
            raise

    def snapshot(self) -> AuthenticatedClosureSnapshotV2:
        """Seal the captured binding set and return immutable authenticated bytes."""

        self._require_active_unsealed()
        if not self._files:
            self._poisoned = True
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture cannot seal an empty binding set"
            )
        snapshot = AuthenticatedClosureSnapshotV2(
            tuple(
                ClosureFileSnapshotV2(item.binding, item.payload)
                for item in self._files.values()
            )
        )
        self._snapshot = snapshot
        return snapshot

    def _before_final_directory_validation(self, path: str) -> None:
        """Instrumentation hook invoked before a retained directory is checked."""

    def _before_final_file_validation(self, path: str) -> None:
        """Instrumentation hook invoked before a retained file is checked."""

    @staticmethod
    def _path_status(
        parent_descriptor: int,
        name: str,
        *,
        label: str,
    ) -> os.stat_result:
        try:
            return os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise AuthenticatedClosureSnapshotV2Error(
                f"{label} path cannot be validated"
            ) from error

    def _verify_root_path(self) -> None:
        descriptor = None
        try:
            descriptor = os.open(os.sep, self._directory_flags())
            for component, device, inode in self._root_components:
                opened = None
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened = os.open(
                        component,
                        self._directory_flags(),
                        dir_fd=descriptor,
                    )
                    current = os.fstat(opened)
                    after = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    if opened is not None:
                        os.close(opened)
                    raise AuthenticatedClosureSnapshotV2Error(
                        "closure artifact-root path cannot be revalidated"
                    ) from error
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(current.st_mode)
                    or not stat.S_ISDIR(after.st_mode)
                    or (before.st_dev, before.st_ino) != (device, inode)
                    or (current.st_dev, current.st_ino) != (device, inode)
                    or (after.st_dev, after.st_ino) != (device, inode)
                ):
                    os.close(opened)
                    raise AuthenticatedClosureSnapshotV2Error(
                        "closure artifact-root path identity changed"
                    )
                os.close(descriptor)
                descriptor = opened
            if self._root_identity is None:
                raise AuthenticatedClosureSnapshotV2Error(
                    "closure artifact-root identity is unavailable"
                )
            if _StableIdentityV2.from_status(os.fstat(descriptor)) != (
                self._root_identity
            ):
                raise AuthenticatedClosureSnapshotV2Error(
                    "closure artifact root changed during verification"
                )
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _validate_live_closure(self) -> None:
        if self._snapshot is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture exited without sealing a snapshot"
            )
        if self._poisoned:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure capture cannot validate after a prior failure"
            )
        if self._root_descriptor is None or self._root_identity is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact-root descriptor is unavailable"
            )
        if _StableIdentityV2.from_status(os.fstat(self._root_descriptor)) != (
            self._root_identity
        ):
            raise AuthenticatedClosureSnapshotV2Error(
                "closure artifact root changed during verification"
            )
        for path, retained in sorted(
            self._directories.items(),
            key=lambda item: (item[0].count("/"), item[0]),
        ):
            self._before_final_directory_validation(path)
            descriptor_identity = _StableIdentityV2.from_status(
                os.fstat(retained.descriptor)
            )
            path_identity = _StableIdentityV2.from_status(
                self._path_status(
                    retained.parent_descriptor,
                    retained.name,
                    label=f"closure directory {path}",
                )
            )
            if (
                descriptor_identity != retained.identity
                or path_identity != retained.identity
                or not stat.S_ISDIR(descriptor_identity.mode)
            ):
                raise AuthenticatedClosureSnapshotV2Error(
                    f"closure directory {path} changed during final validation"
                )
        for path, retained in sorted(self._files.items()):
            self._before_final_file_validation(path)
            descriptor_identity = _StableIdentityV2.from_status(
                os.fstat(retained.descriptor)
            )
            path_identity = _StableIdentityV2.from_status(
                self._path_status(
                    retained.parent_descriptor,
                    retained.name,
                    label=retained.label,
                )
            )
            if (
                descriptor_identity != retained.identity
                or path_identity != retained.identity
                or not stat.S_ISREG(descriptor_identity.mode)
            ):
                raise AuthenticatedClosureSnapshotV2Error(
                    f"{retained.label} changed during final validation"
                )
        self._verify_root_path()
        self._drain_events()

    def _drain_events(self) -> None:
        if self._kqueue is None:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure event queue is unavailable"
            )
        try:
            events = self._kqueue.control(
                None,
                max(1, len(self._watch_labels)),
                0,
            )
        except (OSError, ValueError) as error:
            raise AuthenticatedClosureSnapshotV2Error(
                "closure filesystem events cannot be drained"
            ) from error
        if events:
            details = []
            for event in sorted(events, key=lambda item: item.ident):
                label = self._watch_labels.get(
                    event.ident,
                    f"descriptor {event.ident}",
                )
                details.append(f"{label}:0x{event.fflags:x}")
            raise AuthenticatedClosureSnapshotV2Error(
                "authenticated closure filesystem event detected during "
                f"verification ({', '.join(details)})"
            )

    def _close(self) -> None:
        queue = self._kqueue
        self._kqueue = None
        if queue is not None:
            try:
                queue.close()
            except OSError:
                pass
        for descriptor in reversed(self._owned_descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass
        self._owned_descriptors.clear()
        self._state = "closed"

    def __exit__(self, exception_type, exception, traceback) -> bool:
        self._require_owner_execution()
        if self.closed:
            return False
        validation_error: Optional[BaseException] = None
        try:
            if exception_type is None:
                self._validate_live_closure()
        except BaseException as error:
            validation_error = error
        finally:
            self._close()
        if validation_error is not None:
            raise validation_error
        return False


__all__ = [
    "AuthenticatedClosureCaptureV2",
    "AuthenticatedClosureSnapshotV2",
    "AuthenticatedClosureSnapshotV2Error",
    "CLOSURE_HASH_DOMAIN_V2",
    "ClosureFileBindingV2",
    "ClosureFileSnapshotV2",
]
