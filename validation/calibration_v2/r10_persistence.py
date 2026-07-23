"""Durable tamper-evident persistence for R10 optimizer artifacts."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import stat
import threading
from typing import Iterator, Mapping, Sequence

from validation.calibration_v2.r10_optimizer import (
    R10Attempt,
    R10AttemptDisposition,
    R10Checkpoint,
    R10CheckpointReference,
    R10CheckpointStatus,
    R10EvaluationCatalog,
    R10FrozenPolicy,
    R10OptimizerError,
    R10RunResult,
    R10RunStatus,
    R10Selection,
    R10TerminalRecord,
    canonical_json_file_bytes_r10,
    checkpoint_from_document_r10,
    frozen_policy_from_document_r10,
    terminal_record_from_document_r10,
)


_SHA256_LENGTH = 64
_DIRECTORY_NAMES = frozenset({"checkpoints", "terminals", "frozen-policies"})
MAX_R10_ARTIFACT_BYTES = 64 * 1024 * 1024
_STORE_LOCK_REGISTRY_GUARD = threading.Lock()
_STORE_LOCK_REGISTRY: dict[tuple[int, int], threading.RLock] = {}


class R10PersistenceError(ValueError):
    """An R10 artifact path, byte relation, or publication is invalid."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _require_sha256(value: object, field: str) -> str:
    if (
        type(value) is not str
        or len(value) != _SHA256_LENGTH
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise R10PersistenceError(f"{field} must be one lowercase SHA-256")
    return value


def _safe_relative_path(value: object, field: str) -> str:
    if type(value) is not str or not value or "\\" in value:
        raise R10PersistenceError(f"{field} is invalid")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in {"", ".", ".."} for part in path.parts)
        or path.as_posix() != value
    ):
        raise R10PersistenceError(f"{field} is unsafe")
    return value


@dataclass(frozen=True)
class R10ArtifactBinding:
    path: str
    sha256: str
    size_bytes: int

    def __post_init__(self) -> None:
        _safe_relative_path(self.path, "artifact path")
        _require_sha256(self.sha256, "artifact SHA-256")
        if (
            type(self.size_bytes) is not int
            or self.size_bytes < 1
            or self.size_bytes > MAX_R10_ARTIFACT_BYTES
        ):
            raise R10PersistenceError("artifact size is invalid")


@dataclass(frozen=True)
class R10Publication:
    checkpoint: R10ArtifactBinding
    terminal: R10ArtifactBinding | None
    frozen_policy: R10ArtifactBinding | None

    def __post_init__(self) -> None:
        if type(self.checkpoint) is not R10ArtifactBinding:
            raise R10PersistenceError("publication checkpoint binding is invalid")
        if (self.terminal is None) == (self.frozen_policy is None):
            raise R10PersistenceError(
                "publication must contain exactly one terminal outcome"
            )
        if self.terminal is not None and type(self.terminal) is not R10ArtifactBinding:
            raise R10PersistenceError("publication terminal binding is invalid")
        if (
            self.frozen_policy is not None
            and type(self.frozen_policy) is not R10ArtifactBinding
        ):
            raise R10PersistenceError("publication frozen-policy binding is invalid")


def _decode_canonical_json(payload: bytes, label: str) -> Mapping[str, object]:
    def reject_duplicate_pairs(
        pairs: Sequence[tuple[str, object]],
    ) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise R10PersistenceError(f"{label} contains a duplicate key")
            result[key] = value
        return result

    def reject_nonfinite(token: str) -> object:
        raise R10PersistenceError(f"{label} contains non-finite JSON: {token}")

    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=reject_nonfinite,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise R10PersistenceError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise R10PersistenceError(f"{label} must be one JSON object")
    try:
        canonical = canonical_json_file_bytes_r10(value)
    except R10OptimizerError as error:
        raise R10PersistenceError(f"{label} is not canonicalizable") from error
    if canonical != payload:
        raise R10PersistenceError(f"{label} bytes are not canonical")
    return value


class R10PersistenceStore:
    """Tamper-evident exclusive publication within this API.

    Read-only sealing does not prevent privileged or direct OS mutation.
    Reopen operations detect such mutation against the retained bindings.
    """

    _TEMPORARY_PREFIX = ".r10-write-"
    _TEMPORARY_SUFFIX = ".tmp"

    def __init__(self, root: Path) -> None:
        if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
            raise R10PersistenceError(
                "R10 no-follow directory primitives are unavailable"
            )
        supplied = Path(os.path.abspath(os.fspath(root)))
        if "\x00" in os.fspath(supplied):
            raise R10PersistenceError("R10 artifact root path is invalid")
        try:
            supplied_status = os.lstat(supplied)
        except FileNotFoundError:
            supplied_status = None
        except OSError as error:
            raise R10PersistenceError(
                "R10 artifact root cannot be inspected"
            ) from error
        if supplied_status is not None and stat.S_ISLNK(supplied_status.st_mode):
            raise R10PersistenceError("R10 artifact root must not be a symlink")

        resolved = Path(os.path.realpath(os.fspath(supplied)))
        if not resolved.is_absolute() or resolved == Path(os.sep):
            raise R10PersistenceError("R10 artifact root is unsafe")
        self.root = resolved
        self._state_lock = threading.RLock()
        self._closed = True
        self._root_descriptor = -1
        self._root_components: tuple[tuple[str, int, int], ...] = ()
        self._root_identity = (-1, -1)
        self._directory_descriptors: dict[str, int] = {}
        self._directory_identities: dict[str, tuple[int, int]] = {}
        self._publication_thread_lock: threading.RLock | None = None

        root_descriptor = -1
        child_descriptors: dict[str, int] = {}
        try:
            root_descriptor, root_components = self._create_and_pin_root(resolved)
            root_status = os.fstat(root_descriptor)
            root_identity = (root_status.st_dev, root_status.st_ino)
            try:
                supplied_after = os.lstat(supplied)
            except OSError as error:
                raise R10PersistenceError(
                    "R10 supplied artifact root is unavailable"
                ) from error
            if (
                stat.S_ISLNK(supplied_after.st_mode)
                or not stat.S_ISDIR(supplied_after.st_mode)
                or (supplied_after.st_dev, supplied_after.st_ino)
                != root_identity
            ):
                raise R10PersistenceError(
                    "R10 supplied artifact root identity differs"
                )

            publication_lock = self._publication_lock_for_root(root_identity)
            with publication_lock:
                try:
                    fcntl.flock(root_descriptor, fcntl.LOCK_EX)
                except OSError as error:
                    raise R10PersistenceError(
                        "R10 artifact root cannot be locked"
                    ) from error
                try:
                    for name in sorted(_DIRECTORY_NAMES):
                        try:
                            os.mkdir(name, 0o700, dir_fd=root_descriptor)
                        except FileExistsError:
                            pass
                        except OSError as error:
                            raise R10PersistenceError(
                                f"R10 {name} directory cannot be created"
                            ) from error
                        descriptor, status = self._open_directory_at(
                            root_descriptor,
                            name,
                        )
                        child_descriptors[name] = descriptor
                        self._directory_identities[name] = (
                            status.st_dev,
                            status.st_ino,
                        )
                    os.fsync(root_descriptor)
                finally:
                    try:
                        fcntl.flock(root_descriptor, fcntl.LOCK_UN)
                    except OSError as error:
                        raise R10PersistenceError(
                            "R10 artifact root lock cannot be released"
                        ) from error

            self._root_descriptor = root_descriptor
            self._root_components = root_components
            self._root_identity = root_identity
            self._directory_descriptors = child_descriptors
            self._publication_thread_lock = publication_lock
            self._closed = False
            self._verify_store_identity()
        except BaseException:
            for descriptor in child_descriptors.values():
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            if root_descriptor >= 0:
                try:
                    os.close(root_descriptor)
                except OSError:
                    pass
            self._directory_descriptors = {}
            self._root_descriptor = -1
            self._closed = True
            raise

    def __enter__(self) -> "R10PersistenceStore":
        with self._state_lock:
            self._require_open()
            return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except BaseException:
            pass

    def close(self) -> None:
        """Close retained descriptors once; repeated close calls are harmless."""

        lock = getattr(self, "_state_lock", None)
        if lock is None:
            return
        with lock:
            if getattr(self, "_closed", True):
                return
            self._closed = True
            descriptors = tuple(self._directory_descriptors.values())
            self._directory_descriptors = {}
            root_descriptor = self._root_descriptor
            self._root_descriptor = -1
            first_error: OSError | None = None
            for descriptor in descriptors + (root_descriptor,):
                try:
                    os.close(descriptor)
                except OSError as error:
                    if first_error is None:
                        first_error = error
            if first_error is not None:
                raise R10PersistenceError(
                    "R10 artifact descriptors cannot be closed"
                ) from first_error

    @staticmethod
    def _directory_flags() -> int:
        return (
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0)
        )

    @classmethod
    def _create_and_pin_root(
        cls,
        root: Path,
    ) -> tuple[int, tuple[tuple[str, int, int], ...]]:
        descriptor = os.open(os.sep, cls._directory_flags())
        identities: list[tuple[str, int, int]] = []
        try:
            for component in root.parts[1:]:
                child = -1
                if not component or component in {".", ".."}:
                    raise R10PersistenceError(
                        "R10 artifact root component is unsafe"
                    )
                created = False
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    created = True
                except FileExistsError:
                    pass
                except OSError as error:
                    raise R10PersistenceError(
                        "R10 artifact root cannot be created"
                    ) from error
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    child = os.open(
                        component,
                        cls._directory_flags(),
                        dir_fd=descriptor,
                    )
                    opened = os.fstat(child)
                    after = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    if child >= 0:
                        os.close(child)
                    raise R10PersistenceError(
                        "R10 artifact root component is unsafe"
                    ) from error
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                    or (opened.st_dev, opened.st_ino)
                    != (after.st_dev, after.st_ino)
                ):
                    os.close(child)
                    raise R10PersistenceError(
                        "R10 artifact root component identity changed"
                    )
                if created:
                    try:
                        os.fsync(descriptor)
                    except OSError as error:
                        os.close(child)
                        raise R10PersistenceError(
                            "R10 artifact root creation cannot be synchronized"
                        ) from error
                identities.append(
                    (component, opened.st_dev, opened.st_ino)
                )
                os.close(descriptor)
                descriptor = child
            return descriptor, tuple(identities)
        except BaseException:
            os.close(descriptor)
            raise

    @classmethod
    def _open_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
    ) -> tuple[int, os.stat_result]:
        descriptor = -1
        try:
            before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(
                name,
                cls._directory_flags(),
                dir_fd=parent_descriptor,
            )
            opened = os.fstat(descriptor)
            after = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise R10PersistenceError(
                f"R10 {name} directory cannot be safely opened"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or (before.st_dev, before.st_ino)
            != (opened.st_dev, opened.st_ino)
            or (opened.st_dev, opened.st_ino)
            != (after.st_dev, after.st_ino)
        ):
            os.close(descriptor)
            raise R10PersistenceError(
                f"R10 {name} directory identity changed"
            )
        return descriptor, opened

    @staticmethod
    def _publication_lock_for_root(
        identity: tuple[int, int],
    ) -> threading.RLock:
        with _STORE_LOCK_REGISTRY_GUARD:
            lock = _STORE_LOCK_REGISTRY.get(identity)
            if lock is None:
                lock = threading.RLock()
                _STORE_LOCK_REGISTRY[identity] = lock
            return lock

    def _require_open(self) -> None:
        if self._closed or self._root_descriptor < 0:
            raise R10PersistenceError("R10 persistence store is closed")

    def _reopen_root_path(self) -> int:
        try:
            descriptor = os.open(os.sep, self._directory_flags())
        except OSError as error:
            raise R10PersistenceError(
                "R10 filesystem root cannot be safely opened"
            ) from error
        try:
            for component, expected_device, expected_inode in self._root_components:
                child = -1
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    child = os.open(
                        component,
                        self._directory_flags(),
                        dir_fd=descriptor,
                    )
                    opened = os.fstat(child)
                    after = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    if child >= 0:
                        os.close(child)
                    raise R10PersistenceError(
                        "R10 artifact root path cannot be safely reopened"
                    ) from error
                expected = (expected_device, expected_inode)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino) != expected
                    or (opened.st_dev, opened.st_ino) != expected
                    or (after.st_dev, after.st_ino) != expected
                ):
                    os.close(child)
                    raise R10PersistenceError(
                        "R10 artifact root path identity changed"
                    )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def _verify_store_identity(self) -> None:
        self._require_open()
        try:
            retained_root = os.fstat(self._root_descriptor)
        except OSError as error:
            raise R10PersistenceError(
                "R10 retained artifact root is unavailable"
            ) from error
        if (
            not stat.S_ISDIR(retained_root.st_mode)
            or (retained_root.st_dev, retained_root.st_ino)
            != self._root_identity
        ):
            raise R10PersistenceError(
                "R10 retained artifact root identity changed"
            )
        reopened_root = self._reopen_root_path()
        try:
            try:
                reopened_status = os.fstat(reopened_root)
            except OSError as error:
                raise R10PersistenceError(
                    "R10 reopened artifact root is unavailable"
                ) from error
        finally:
            os.close(reopened_root)
        if (
            reopened_status.st_dev,
            reopened_status.st_ino,
        ) != self._root_identity:
            raise R10PersistenceError("R10 artifact root path identity changed")

        for name in sorted(_DIRECTORY_NAMES):
            descriptor = self._directory_descriptors.get(name)
            expected = self._directory_identities.get(name)
            if descriptor is None or expected is None:
                raise R10PersistenceError(
                    "R10 artifact directory descriptor is unavailable"
                )
            try:
                retained = os.fstat(descriptor)
                named = os.stat(
                    name,
                    dir_fd=self._root_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise R10PersistenceError(
                    f"R10 {name} directory is unavailable"
                ) from error
            if (
                not stat.S_ISDIR(retained.st_mode)
                or not stat.S_ISDIR(named.st_mode)
                or (retained.st_dev, retained.st_ino) != expected
                or (named.st_dev, named.st_ino) != expected
            ):
                raise R10PersistenceError(
                    f"R10 {name} directory identity changed"
                )

    @contextmanager
    def _stable_operation(self) -> Iterator[None]:
        with self._state_lock:
            self._verify_store_identity()
            try:
                yield
            finally:
                self._verify_store_identity()

    @contextmanager
    def _serialized_publication(self) -> Iterator[None]:
        with self._state_lock:
            self._require_open()
            publication_lock = self._publication_thread_lock
            if publication_lock is None:
                raise R10PersistenceError(
                    "R10 publication serialization is unavailable"
                )
            with publication_lock:
                try:
                    fcntl.flock(self._root_descriptor, fcntl.LOCK_EX)
                except OSError as error:
                    raise R10PersistenceError(
                        "R10 artifact root cannot be locked"
                    ) from error
                try:
                    self._verify_store_identity()
                    try:
                        yield
                    finally:
                        self._verify_store_identity()
                finally:
                    try:
                        fcntl.flock(
                            self._root_descriptor,
                            fcntl.LOCK_UN,
                        )
                    except OSError as error:
                        raise R10PersistenceError(
                            "R10 artifact root lock cannot be released"
                        ) from error

    def _directory_descriptor(self, name: str) -> int:
        if name not in _DIRECTORY_NAMES:
            raise R10PersistenceError("R10 artifact directory is invalid")
        descriptor = self._directory_descriptors.get(name)
        if descriptor is None:
            raise R10PersistenceError(
                "R10 artifact directory descriptor is unavailable"
            )
        return descriptor

    @staticmethod
    def _stable_file_identity(status: os.stat_result) -> tuple[int, ...]:
        return (
            status.st_dev,
            status.st_ino,
            status.st_mode,
            status.st_nlink,
            status.st_size,
            status.st_mtime_ns,
            status.st_ctime_ns,
        )

    @classmethod
    def _read_regular_at(
        cls,
        directory_descriptor: int,
        name: str,
        *,
        expected_size: int,
        label: str,
    ) -> bytes:
        if (
            type(name) is not str
            or not name
            or name in {".", ".."}
            or "/" in name
            or "\\" in name
            or "\x00" in name
        ):
            raise R10PersistenceError(f"{label} read inputs are invalid")
        if (
            type(expected_size) is not int
            or expected_size < 1
            or expected_size > MAX_R10_ARTIFACT_BYTES
        ):
            raise R10PersistenceError(
                f"{label} read exceeds the fixed artifact boundary"
            )
        file_descriptor = -1
        try:
            before_path = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            file_descriptor = os.open(
                name,
                os.O_RDONLY
                | os.O_NOFOLLOW
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=directory_descriptor,
            )
            opened = os.fstat(file_descriptor)
        except OSError as error:
            if file_descriptor >= 0:
                os.close(file_descriptor)
            raise R10PersistenceError(f"{label} is unavailable") from error
        try:
            if (
                not stat.S_ISREG(before_path.st_mode)
                or not stat.S_ISREG(opened.st_mode)
                or before_path.st_nlink != 1
                or opened.st_nlink != 1
                or stat.S_IMODE(before_path.st_mode) != 0o400
                or stat.S_IMODE(opened.st_mode) != 0o400
                or (before_path.st_dev, before_path.st_ino)
                != (opened.st_dev, opened.st_ino)
            ):
                raise R10PersistenceError(
                    f"{label} is not one sealed regular file"
                )
            if opened.st_size != expected_size:
                raise R10PersistenceError(
                    f"{label} binding differs from bytes"
                )

            chunks: list[bytes] = []
            remaining = expected_size
            while remaining:
                try:
                    chunk = os.read(
                        file_descriptor,
                        min(1024 * 1024, remaining),
                    )
                except OSError as error:
                    raise R10PersistenceError(
                        f"{label} changed while reading"
                    ) from error
                if not chunk:
                    raise R10PersistenceError(
                        f"{label} binding differs from bytes"
                    )
                chunks.append(chunk)
                remaining -= len(chunk)
            try:
                trailing = os.read(file_descriptor, 1)
                after = os.fstat(file_descriptor)
                after_path = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise R10PersistenceError(
                    f"{label} changed while reading"
                ) from error
            payload = b"".join(chunks)
            expected_identity = cls._stable_file_identity(opened)
            if (
                trailing
                or len(payload) != expected_size
                or cls._stable_file_identity(before_path)
                != expected_identity
                or cls._stable_file_identity(after) != expected_identity
                or cls._stable_file_identity(after_path)
                != expected_identity
            ):
                raise R10PersistenceError(f"{label} changed while reading")
            return payload
        finally:
            os.close(file_descriptor)

    def _publish_named(
        self,
        *,
        directory_name: str,
        file_name: str,
        payload: bytes,
        label: str,
    ) -> R10ArtifactBinding:
        if (
            type(payload) is not bytes
            or not payload
            or len(payload) > MAX_R10_ARTIFACT_BYTES
            or type(file_name) is not str
            or not file_name
            or "/" in file_name
            or "\\" in file_name
            or "\x00" in file_name
            or file_name in {".", ".."}
        ):
            raise R10PersistenceError(f"{label} publication inputs are invalid")
        temporary = (
            f"{self._TEMPORARY_PREFIX}{os.getpid()}-"
            f"{secrets.token_hex(16)}{self._TEMPORARY_SUFFIX}"
        )
        with self._serialized_publication():
            directory_descriptor = self._directory_descriptor(directory_name)
            destination_exists = False
            try:
                existing = self._read_regular_at(
                    directory_descriptor,
                    file_name,
                    expected_size=len(payload),
                    label=label,
                )
            except R10PersistenceError:
                try:
                    os.stat(
                        file_name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    pass
                except OSError as error:
                    raise R10PersistenceError(
                        f"{label} cannot be inspected"
                    ) from error
                else:
                    raise R10PersistenceError(
                        f"{label} immutable-name collision"
                    )
            else:
                if existing != payload:
                    raise R10PersistenceError(
                        f"{label} immutable-name collision"
                    )
                try:
                    os.fsync(directory_descriptor)
                except OSError as error:
                    raise R10PersistenceError(
                        f"{label} cannot be durably reopened"
                    ) from error
                destination_exists = True

            if not destination_exists:
                file_descriptor = -1
                temporary_created = False
                temporary_identity: tuple[int, int] | None = None
                try:
                    file_descriptor = os.open(
                        temporary,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_NOFOLLOW
                        | getattr(os, "O_CLOEXEC", 0),
                        0o600,
                        dir_fd=directory_descriptor,
                    )
                    temporary_created = True
                    opened = os.fstat(file_descriptor)
                    temporary_identity = (
                        opened.st_dev,
                        opened.st_ino,
                    )
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or opened.st_nlink != 1
                    ):
                        raise R10PersistenceError(
                            f"{label} temporary is not private"
                        )
                    offset = 0
                    while offset < len(payload):
                        written = os.write(
                            file_descriptor,
                            payload[offset:],
                        )
                        if written <= 0:
                            raise R10PersistenceError(
                                f"{label} write made no progress"
                            )
                        offset += written
                    os.fchmod(file_descriptor, 0o400)
                    os.fsync(file_descriptor)
                    sealed = os.fstat(file_descriptor)
                    if (
                        not stat.S_ISREG(sealed.st_mode)
                        or sealed.st_nlink != 1
                        or sealed.st_size != len(payload)
                        or stat.S_IMODE(sealed.st_mode) != 0o400
                        or (sealed.st_dev, sealed.st_ino)
                        != (opened.st_dev, opened.st_ino)
                    ):
                        raise R10PersistenceError(
                            f"{label} temporary did not seal"
                        )
                    try:
                        os.link(
                            temporary,
                            file_name,
                            src_dir_fd=directory_descriptor,
                            dst_dir_fd=directory_descriptor,
                            follow_symlinks=False,
                        )
                    except FileExistsError:
                        try:
                            existing = self._read_regular_at(
                                directory_descriptor,
                                file_name,
                                expected_size=len(payload),
                                label=label,
                            )
                        except R10PersistenceError as error:
                            raise R10PersistenceError(
                                f"{label} immutable-name collision"
                            ) from error
                        if existing != payload:
                            raise R10PersistenceError(
                                f"{label} immutable-name collision"
                            )
                    os.fsync(directory_descriptor)
                except OSError as error:
                    raise R10PersistenceError(
                        f"{label} cannot be atomically published"
                    ) from error
                finally:
                    if file_descriptor >= 0:
                        os.close(file_descriptor)
                    if temporary_created:
                        try:
                            named_temporary = os.stat(
                                temporary,
                                dir_fd=directory_descriptor,
                                follow_symlinks=False,
                            )
                            if (
                                not stat.S_ISREG(named_temporary.st_mode)
                                or (
                                    named_temporary.st_dev,
                                    named_temporary.st_ino,
                                )
                                != temporary_identity
                            ):
                                raise R10PersistenceError(
                                    f"{label} temporary identity changed"
                                )
                            os.unlink(
                                temporary,
                                dir_fd=directory_descriptor,
                            )
                        except FileNotFoundError:
                            pass
                        except OSError as error:
                            raise R10PersistenceError(
                                f"{label} temporary cannot be removed"
                            ) from error
                        else:
                            try:
                                os.fsync(directory_descriptor)
                            except OSError as error:
                                raise R10PersistenceError(
                                    f"{label} temporary cleanup cannot "
                                    "be synchronized"
                                ) from error
        relative = f"{directory_name}/{file_name}"
        binding = R10ArtifactBinding(
            path=relative,
            sha256=_sha256(payload),
            size_bytes=len(payload),
        )
        if self._read_binding(binding, label) != payload:
            raise R10PersistenceError(f"{label} changed after publication")
        return binding

    def _read_binding(
        self,
        binding: R10ArtifactBinding,
        label: str,
    ) -> bytes:
        if type(binding) is not R10ArtifactBinding:
            raise R10PersistenceError(f"{label} binding has the wrong type")
        parts = PurePosixPath(binding.path).parts
        if len(parts) != 2 or parts[0] not in _DIRECTORY_NAMES:
            raise R10PersistenceError(f"{label} binding path is invalid")
        with self._stable_operation():
            payload = self._read_regular_at(
                self._directory_descriptor(parts[0]),
                parts[1],
                expected_size=binding.size_bytes,
                label=label,
            )
        if (
            len(payload) != binding.size_bytes
            or _sha256(payload) != binding.sha256
        ):
            raise R10PersistenceError(f"{label} binding differs from bytes")
        return payload

    def publish_checkpoint(
        self,
        checkpoint: R10Checkpoint,
    ) -> R10ArtifactBinding:
        if type(checkpoint) is not R10Checkpoint:
            raise R10PersistenceError("checkpoint has the wrong type")
        payload = checkpoint.canonical_file_bytes
        binding = self._publish_named(
            directory_name="checkpoints",
            file_name=f"{_sha256(payload)}.json",
            payload=payload,
            label="R10 checkpoint",
        )
        if self.reopen_checkpoint(binding) != checkpoint:
            raise R10PersistenceError("R10 checkpoint changed on typed reopen")
        return binding

    def reopen_checkpoint(
        self,
        binding: R10ArtifactBinding,
    ) -> R10Checkpoint:
        if type(binding) is not R10ArtifactBinding:
            raise R10PersistenceError("checkpoint binding has the wrong type")
        expected_path = f"checkpoints/{binding.sha256}.json"
        if binding.path != expected_path:
            raise R10PersistenceError("checkpoint path is not content-addressed")
        payload = self._read_binding(binding, "R10 checkpoint")
        document = _decode_canonical_json(payload, "R10 checkpoint")
        try:
            checkpoint = checkpoint_from_document_r10(document)
        except R10OptimizerError as error:
            raise R10PersistenceError(
                "R10 checkpoint semantic validation failed"
            ) from error
        if checkpoint.canonical_file_bytes != payload:
            raise R10PersistenceError(
                "R10 checkpoint typed encoding differs from bytes"
            )
        return checkpoint

    @staticmethod
    def _checkpoint_reference(
        binding: R10ArtifactBinding,
        checkpoint: R10Checkpoint,
    ) -> R10CheckpointReference:
        return R10CheckpointReference(
            path=binding.path,
            sha256=binding.sha256,
            size_bytes=binding.size_bytes,
            checkpoint_sha256=checkpoint.checkpoint_sha256,
        )

    @staticmethod
    def _ranked_attempts(
        attempts: Sequence[R10Attempt],
    ) -> tuple[R10Attempt, ...]:
        scored = tuple(
            attempt
            for attempt in attempts
            if attempt.disposition is R10AttemptDisposition.SCORED
        )
        return tuple(
            sorted(
                scored,
                key=lambda attempt: (
                    attempt.score.ranking_key()
                    if attempt.score is not None
                    else (),
                    attempt.candidate.canonical_bytes,
                ),
            )
        )

    @staticmethod
    def _require_evaluation_catalog_replay(
        checkpoint: R10Checkpoint,
        evaluation_catalog: R10EvaluationCatalog | None,
    ) -> None:
        if type(evaluation_catalog) is not R10EvaluationCatalog:
            raise R10PersistenceError(
                "exact R10 evaluation catalog is required"
            )
        if (
            evaluation_catalog.evaluator_sha256
            != checkpoint.processing_identity.evaluator_sha256
        ):
            raise R10PersistenceError(
                "R10 evaluation catalog identity differs from checkpoint"
            )
        for attempt in checkpoint.attempts:
            if attempt.disposition is not R10AttemptDisposition.SCORED:
                continue
            try:
                expected_score = evaluation_catalog.score_for(
                    attempt.candidate
                )
            except R10OptimizerError as error:
                raise R10PersistenceError(
                    "R10 evaluation catalog does not close a scored attempt"
                ) from error
            if expected_score != attempt.score:
                raise R10PersistenceError(
                    "R10 scored attempt differs from evaluation catalog"
                )

    def _require_frozen_policy_checkpoint(
        self,
        policy: R10FrozenPolicy,
        evaluation_catalog: R10EvaluationCatalog | None,
    ) -> R10Checkpoint:
        checkpoint_reference = policy.final_checkpoint
        checkpoint = self.reopen_checkpoint(
            R10ArtifactBinding(
                path=checkpoint_reference.path,
                sha256=checkpoint_reference.sha256,
                size_bytes=checkpoint_reference.size_bytes,
            )
        )
        if (
            checkpoint.status is not R10CheckpointStatus.COMPLETED
            or checkpoint.checkpoint_sha256
            != checkpoint_reference.checkpoint_sha256
            or checkpoint.processing_identity != policy.processing_identity
            or checkpoint.candidate_set_sha256 != policy.candidate_set_sha256
        ):
            raise R10PersistenceError(
                "frozen policy checkpoint dependency differs"
            )
        self._require_evaluation_catalog_replay(
            checkpoint,
            evaluation_catalog,
        )
        ranked = self._ranked_attempts(checkpoint.attempts)
        if not ranked or R10Selection.create(ranked) != policy.selection:
            raise R10PersistenceError(
                "frozen policy selection differs from checkpoint replay"
            )
        return checkpoint

    def _require_terminal_checkpoint(
        self,
        record: R10TerminalRecord,
        evaluation_catalog: R10EvaluationCatalog | None,
    ) -> R10Checkpoint:
        checkpoint_reference = record.checkpoint
        checkpoint = self.reopen_checkpoint(
            R10ArtifactBinding(
                path=checkpoint_reference.path,
                sha256=checkpoint_reference.sha256,
                size_bytes=checkpoint_reference.size_bytes,
            )
        )
        expected_status = (
            R10CheckpointStatus.CANCELLED
            if record.status is R10RunStatus.CANCELLED
            else R10CheckpointStatus.FAILED
        )
        if (
            checkpoint.status is not expected_status
            or checkpoint.checkpoint_sha256
            != checkpoint_reference.checkpoint_sha256
            or checkpoint.processing_identity != record.processing_identity
            or checkpoint.candidate_set_sha256 != record.candidate_set_sha256
            or checkpoint.terminal_code != record.terminal_code
        ):
            raise R10PersistenceError(
                "terminal record checkpoint dependency differs"
            )
        self._require_evaluation_catalog_replay(
            checkpoint,
            evaluation_catalog,
        )
        return checkpoint

    def publish_frozen_policy(
        self,
        policy: R10FrozenPolicy,
        *,
        evaluation_catalog: R10EvaluationCatalog | None = None,
    ) -> R10ArtifactBinding:
        if type(policy) is not R10FrozenPolicy:
            raise R10PersistenceError("frozen policy has the wrong type")
        self._require_frozen_policy_checkpoint(
            policy,
            evaluation_catalog,
        )
        payload = policy.canonical_file_bytes
        binding = self._publish_named(
            directory_name="frozen-policies",
            file_name=(
                f"{policy.processing_identity.identity_sha256}.json"
            ),
            payload=payload,
            label="R10 frozen fixture policy",
        )
        if (
            self.reopen_frozen_policy(
                binding,
                evaluation_catalog=evaluation_catalog,
            )
            != policy
        ):
            raise R10PersistenceError(
                "R10 frozen fixture policy changed on typed reopen"
            )
        return binding

    def reopen_frozen_policy(
        self,
        binding: R10ArtifactBinding,
        *,
        evaluation_catalog: R10EvaluationCatalog | None = None,
    ) -> R10FrozenPolicy:
        if type(binding) is not R10ArtifactBinding:
            raise R10PersistenceError("frozen-policy binding has the wrong type")
        parts = PurePosixPath(binding.path).parts
        if (
            len(parts) != 2
            or parts[0] != "frozen-policies"
            or not parts[1].endswith(".json")
        ):
            raise R10PersistenceError("frozen-policy binding path is invalid")
        payload = self._read_binding(binding, "R10 frozen fixture policy")
        document = _decode_canonical_json(
            payload,
            "R10 frozen fixture policy",
        )
        try:
            policy = frozen_policy_from_document_r10(document)
        except R10OptimizerError as error:
            raise R10PersistenceError(
                "R10 frozen fixture policy semantic validation failed"
            ) from error
        if (
            parts[1]
            != f"{policy.processing_identity.identity_sha256}.json"
            or policy.canonical_file_bytes != payload
        ):
            raise R10PersistenceError(
                "R10 frozen fixture policy identity differs from bytes"
            )
        self._require_frozen_policy_checkpoint(
            policy,
            evaluation_catalog,
        )
        return policy

    def publish_terminal_record(
        self,
        record: R10TerminalRecord,
        *,
        evaluation_catalog: R10EvaluationCatalog | None = None,
    ) -> R10ArtifactBinding:
        if type(record) is not R10TerminalRecord:
            raise R10PersistenceError("terminal record has the wrong type")
        self._require_terminal_checkpoint(
            record,
            evaluation_catalog,
        )
        payload = record.canonical_file_bytes
        binding = self._publish_named(
            directory_name="terminals",
            file_name=f"{_sha256(payload)}.json",
            payload=payload,
            label="R10 terminal record",
        )
        if (
            self.reopen_terminal_record(
                binding,
                evaluation_catalog=evaluation_catalog,
            )
            != record
        ):
            raise R10PersistenceError(
                "R10 terminal record changed on typed reopen"
            )
        return binding

    def reopen_terminal_record(
        self,
        binding: R10ArtifactBinding,
        *,
        evaluation_catalog: R10EvaluationCatalog | None = None,
    ) -> R10TerminalRecord:
        if type(binding) is not R10ArtifactBinding:
            raise R10PersistenceError("terminal binding has the wrong type")
        expected_path = f"terminals/{binding.sha256}.json"
        if binding.path != expected_path:
            raise R10PersistenceError("terminal path is not content-addressed")
        payload = self._read_binding(binding, "R10 terminal record")
        document = _decode_canonical_json(payload, "R10 terminal record")
        try:
            record = terminal_record_from_document_r10(document)
        except R10OptimizerError as error:
            raise R10PersistenceError(
                "R10 terminal record semantic validation failed"
            ) from error
        if record.canonical_file_bytes != payload:
            raise R10PersistenceError(
                "R10 terminal record typed encoding differs from bytes"
            )
        self._require_terminal_checkpoint(
            record,
            evaluation_catalog,
        )
        return record

    def publish_run_result(
        self,
        result: R10RunResult,
        *,
        evaluation_catalog: R10EvaluationCatalog | None = None,
    ) -> R10Publication:
        if type(result) is not R10RunResult:
            raise R10PersistenceError("run result has the wrong type")
        self._require_evaluation_catalog_replay(
            result.checkpoint,
            evaluation_catalog,
        )
        checkpoint_binding = self.publish_checkpoint(result.checkpoint)
        reference = self._checkpoint_reference(
            checkpoint_binding,
            result.checkpoint,
        )
        if result.status is R10RunStatus.SUCCEEDED:
            assert result.selection is not None
            policy = R10FrozenPolicy.create(
                processing_identity=result.checkpoint.processing_identity,
                candidate_set_sha256=result.checkpoint.candidate_set_sha256,
                selection=result.selection,
                final_checkpoint=reference,
            )
            policy_binding = self.publish_frozen_policy(
                policy,
                evaluation_catalog=evaluation_catalog,
            )
            return R10Publication(
                checkpoint=checkpoint_binding,
                terminal=None,
                frozen_policy=policy_binding,
            )

        assert result.terminal_code is not None
        record = R10TerminalRecord.create(
            processing_identity=result.checkpoint.processing_identity,
            candidate_set_sha256=result.checkpoint.candidate_set_sha256,
            status=result.status,
            terminal_code=result.terminal_code,
            checkpoint=reference,
        )
        terminal_binding = self.publish_terminal_record(
            record,
            evaluation_catalog=evaluation_catalog,
        )
        return R10Publication(
            checkpoint=checkpoint_binding,
            terminal=terminal_binding,
            frozen_policy=None,
        )
