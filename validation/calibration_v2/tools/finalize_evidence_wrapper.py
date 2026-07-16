#!/usr/bin/env python3
"""Seal and exclusively publish one complete evidence-wrapper directory."""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import hashlib
import json
import os
import platform as platform_module
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import subprocess
import sys
import traceback
from typing import Dict, Mapping, Sequence, Tuple


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    validate_schema,
)


SCHEMA_PATH = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "evidence-wrapper-artifact-manifest-v2.schema.json"
)
MANIFEST_NAME = "artifact-manifest.json"
RECOVERY_NAME = "wrapper-recovery.json"
TRANSACTION_SCHEMA_VERSION = "1.0.0"
RENAME_EXCL = 0x00000004
RENAME_NOFOLLOW_ANY = 0x00000010
RENAME_RESOLVE_BENEATH = 0x00000020
GATE_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9._-]{1,31}$")


class EvidenceWrapperError(RuntimeError):
    """An evidence wrapper cannot be safely validated or published."""


@dataclass(frozen=True)
class FileSnapshot:
    """Identity and exact bytes digest for one descriptor-read regular file."""

    path: str
    sha256: str
    size_bytes: int
    device: int
    inode: int
    mode: int
    flags: int
    mtime_ns: int
    ctime_ns: int


@dataclass(frozen=True)
class DirectorySnapshot:
    """Identity and metadata for one descriptor-walked directory."""

    path: str
    device: int
    inode: int
    mode: int
    flags: int
    mtime_ns: int
    ctime_ns: int


@dataclass(frozen=True)
class TreeSnapshot:
    """The complete regular-file and directory closure below one root."""

    files: Tuple[FileSnapshot, ...]
    directories: Tuple[DirectorySnapshot, ...]


@dataclass(frozen=True)
class RepositoryState:
    """The clean checkout identity required throughout finalization."""

    project_commit: str
    tracked_diff_sha256: str
    untracked_paths_sha256: str


@dataclass(frozen=True)
class Provenance:
    """Provenance recorded for one manifest artifact row."""

    producer: str
    command: str
    platform: str
    machine: str
    gate_ids: Tuple[str, ...]


@dataclass(frozen=True)
class ProvenanceRule:
    """One exact-path or normalized-prefix provenance rule."""

    selector_kind: str
    selector: str
    provenance: Provenance
    ordinal: int


@dataclass(frozen=True)
class ExternalFileSnapshot:
    """A canonical path and identity-bound external input file."""

    path: Path
    payload: bytes
    metadata: FileSnapshot


@dataclass(frozen=True)
class TransactionMarker:
    """Durable sibling marker binding one publication attempt to a root inode."""

    name: str
    completion_name: str
    token: str
    document: Mapping[str, object]
    payload: bytes
    metadata: FileSnapshot


def _safe_relative(value: object, *, label: str) -> str:
    if not isinstance(value, str):
        raise EvidenceWrapperError(f"{label} is not a string")
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise EvidenceWrapperError(f"{label} is not valid UTF-8") from error
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or "\x00" in value
        or "//" in value
        or path.as_posix() != value
        or any(component in {"", ".", ".."} for component in path.parts)
    ):
        raise EvidenceWrapperError(f"unsafe {label}: {value!r}")
    return value


def _validate_gate_ids(values: Sequence[str], *, label: str) -> Tuple[str, ...]:
    if (
        isinstance(values, (str, bytes))
        or not values
        or len(values) != len(set(values))
        or any(
            not isinstance(value, str)
            or GATE_ID_PATTERN.fullmatch(value) is None
            for value in values
        )
    ):
        raise EvidenceWrapperError(f"{label} are invalid")
    return tuple(values)


def _validate_provenance(
    *,
    producer: object,
    command: object,
    platform: object,
    machine: object,
    gate_ids: Sequence[str],
    label: str,
) -> Provenance:
    fields = {
        "producer": producer,
        "command": command,
        "platform": platform,
        "machine": machine,
    }
    for field, value in fields.items():
        if not isinstance(value, str) or not value.strip():
            raise EvidenceWrapperError(f"{label} {field} is empty")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise EvidenceWrapperError(
                f"{label} {field} is not valid UTF-8"
            ) from error
    return Provenance(
        producer=str(producer),
        command=str(command),
        platform=str(platform),
        machine=str(machine),
        gate_ids=_validate_gate_ids(gate_ids, label=f"{label} gate IDs"),
    )


def _reject_duplicate_json_pairs(
    pairs: Sequence[Tuple[str, object]],
    *,
    label: str,
) -> Dict[str, object]:
    result: Dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceWrapperError(
                f"{label} contains a duplicate JSON member: {key}"
            )
        result[key] = value
    return result


def _strict_json(payload: bytes, *, label: str) -> object:
    try:
        text = payload.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=lambda pairs: _reject_duplicate_json_pairs(
                pairs,
                label=label,
            ),
            parse_constant=lambda token: (_ for _ in ()).throw(
                EvidenceWrapperError(
                    f"{label} contains a non-finite value: {token}"
                )
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceWrapperError(f"{label} is not valid UTF-8 JSON") from error


def _directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _regular_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _identity(metadata: os.stat_result) -> Tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def _require_canonical_directory(path: Path, *, label: str) -> os.stat_result:
    absolute = Path(os.path.abspath(path))
    try:
        resolved = absolute.resolve(strict=True)
        metadata = os.stat(absolute, follow_symlinks=False)
    except OSError as error:
        raise EvidenceWrapperError(f"{label} is absent: {absolute}") from error
    if resolved != absolute or not stat.S_ISDIR(metadata.st_mode):
        raise EvidenceWrapperError(
            f"{label} is aliased, linked, or not a real directory: {absolute}"
        )
    return metadata


def _open_directory(path: Path) -> int:
    try:
        return os.open(path, _directory_flags())
    except OSError as error:
        raise EvidenceWrapperError(f"cannot descriptor-open directory: {path}") from error


def _open_directory_at(parent_descriptor: int, name: str, *, label: str) -> int:
    try:
        return os.open(name, _directory_flags(), dir_fd=parent_descriptor)
    except OSError as error:
        raise EvidenceWrapperError(f"cannot descriptor-open {label}") from error


def _stat_at(
    parent_descriptor: int,
    name: str,
    *,
    label: str,
) -> os.stat_result:
    try:
        return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise EvidenceWrapperError(f"cannot inspect {label}") from error


def _require_absent_at(parent_descriptor: int, name: str, *, label: str) -> None:
    try:
        os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise EvidenceWrapperError(f"cannot inspect {label}") from error
    raise EvidenceWrapperError(f"{label} already exists")


def _read_regular_at(
    directory_descriptor: int,
    name: str,
    *,
    relative_path: str,
    collect: bool = False,
) -> Tuple[FileSnapshot, bytes | None]:
    before = _stat_at(
        directory_descriptor,
        name,
        label=f"artifact path {relative_path}",
    )
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise EvidenceWrapperError(
            f"artifact is not a single-link regular file: {relative_path}"
        )
    try:
        descriptor = os.open(
            name,
            _regular_flags(),
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise EvidenceWrapperError(
            f"artifact cannot be opened without traversal: {relative_path}"
        ) from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or _identity(opened) != _identity(before)
        ):
            raise EvidenceWrapperError(
                f"artifact identity changed while opening: {relative_path}"
            )
        digest = hashlib.sha256()
        size = 0
        chunks = [] if collect else None
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
            if chunks is not None:
                chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = _stat_at(
        directory_descriptor,
        name,
        label=f"artifact path {relative_path} after read",
    )
    invariant = (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_mtime_ns,
        opened.st_ctime_ns,
        opened.st_nlink,
        opened.st_mode,
    )
    if (
        invariant
        != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
            after.st_mode,
        )
        or _identity(current) != _identity(opened)
        or not stat.S_ISREG(current.st_mode)
        or current.st_nlink != 1
        or current.st_size != size
        or current.st_mtime_ns != opened.st_mtime_ns
        or current.st_ctime_ns != opened.st_ctime_ns
        or current.st_mode != opened.st_mode
    ):
        raise EvidenceWrapperError(
            f"artifact changed while being read: {relative_path}"
        )
    snapshot = FileSnapshot(
        path=relative_path,
        sha256=digest.hexdigest(),
        size_bytes=size,
        device=opened.st_dev,
        inode=opened.st_ino,
        mode=opened.st_mode,
        flags=opened.st_flags,
        mtime_ns=opened.st_mtime_ns,
        ctime_ns=opened.st_ctime_ns,
    )
    return snapshot, b"".join(chunks) if chunks is not None else None


def _walk_error(error: OSError) -> None:
    raise EvidenceWrapperError("descriptor walk failed") from error


def _snapshot_tree(root_descriptor: int) -> TreeSnapshot:
    files = []
    directories = []
    expected_directories: Dict[str, Tuple[int, int]] = {
        "": _identity(os.fstat(root_descriptor))
    }
    seen_directories = set()
    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=True,
        onerror=_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        relative_directory = "" if directory == "." else directory[2:]
        if relative_directory:
            _safe_relative(relative_directory, label="artifact directory path")
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or relative_directory in seen_directories
            or expected_directories.get(relative_directory) != _identity(metadata)
        ):
            raise EvidenceWrapperError(
                "artifact directory identity changed during descriptor walk"
            )
        seen_directories.add(relative_directory)
        directories.append(
            DirectorySnapshot(
                path=relative_directory,
                device=metadata.st_dev,
                inode=metadata.st_ino,
                mode=metadata.st_mode,
                flags=metadata.st_flags,
                mtime_ns=metadata.st_mtime_ns,
                ctime_ns=metadata.st_ctime_ns,
            )
        )
        directory_names.sort()
        for name in directory_names:
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            _safe_relative(relative, label="artifact directory path")
            child = _stat_at(
                descriptor,
                name,
                label=f"artifact directory {relative}",
            )
            if not stat.S_ISDIR(child.st_mode):
                raise EvidenceWrapperError(
                    f"artifact traversal entry is linked or special: {relative}"
                )
            if relative in expected_directories:
                raise EvidenceWrapperError(f"duplicate artifact directory: {relative}")
            expected_directories[relative] = _identity(child)
        for name in sorted(file_names):
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            _safe_relative(relative, label="artifact path")
            snapshot, _ = _read_regular_at(
                descriptor,
                name,
                relative_path=relative,
            )
            files.append(snapshot)
        for name in directory_names:
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            current = _stat_at(
                descriptor,
                name,
                label=f"artifact directory {relative} after scan",
            )
            if _identity(current) != expected_directories[relative]:
                raise EvidenceWrapperError(
                    f"artifact directory changed during scan: {relative}"
                )
    if seen_directories != set(expected_directories):
        raise EvidenceWrapperError("descriptor walk omitted an artifact directory")
    ordered_files = tuple(sorted(files, key=lambda item: item.path))
    if len({item.path for item in ordered_files}) != len(ordered_files):
        raise EvidenceWrapperError("artifact path set contains duplicates")
    return TreeSnapshot(
        files=ordered_files,
        directories=tuple(sorted(directories, key=lambda item: item.path)),
    )


def _require_snapshot_unchanged(
    expected: TreeSnapshot,
    observed: TreeSnapshot,
    *,
    require_metadata: bool,
) -> None:
    if [item.path for item in observed.files] != [item.path for item in expected.files]:
        raise EvidenceWrapperError("artifact file set changed during finalization")
    if [item.path for item in observed.directories] != [
        item.path for item in expected.directories
    ]:
        raise EvidenceWrapperError("artifact directory set changed during finalization")
    for before, after in zip(expected.files, observed.files):
        if (
            before.path != after.path
            or before.sha256 != after.sha256
            or before.size_bytes != after.size_bytes
            or (before.device, before.inode) != (after.device, after.inode)
            or (
                require_metadata
                and (
                    before.mode,
                    before.flags,
                    before.mtime_ns,
                    before.ctime_ns,
                )
                != (after.mode, after.flags, after.mtime_ns, after.ctime_ns)
            )
        ):
            raise EvidenceWrapperError(
                f"artifact changed during finalization: {before.path}"
            )
    for before, after in zip(expected.directories, observed.directories):
        if (
            before.path != after.path
            or (before.device, before.inode) != (after.device, after.inode)
            or (
                require_metadata
                and (
                    before.mode,
                    before.flags,
                    before.mtime_ns,
                    before.ctime_ns,
                )
                != (after.mode, after.flags, after.mtime_ns, after.ctime_ns)
            )
        ):
            raise EvidenceWrapperError(
                f"artifact directory changed during finalization: {before.path or '<root>'}"
            )


def _read_external_regular(path: Path, *, label: str) -> ExternalFileSnapshot:
    absolute = Path(os.path.abspath(path))
    try:
        if absolute.resolve(strict=True) != absolute:
            raise EvidenceWrapperError(f"{label} is aliased: {absolute}")
    except OSError as error:
        raise EvidenceWrapperError(f"{label} is absent: {absolute}") from error
    parent_metadata = _require_canonical_directory(
        absolute.parent,
        label=f"{label} parent",
    )
    parent_descriptor = _open_directory(absolute.parent)
    try:
        if _identity(os.fstat(parent_descriptor)) != _identity(parent_metadata):
            raise EvidenceWrapperError(f"{label} parent changed while opening")
        metadata, payload = _read_regular_at(
            parent_descriptor,
            absolute.name,
            relative_path=absolute.name,
            collect=True,
        )
    finally:
        os.close(parent_descriptor)
    if payload is None:
        raise EvidenceWrapperError(f"{label} was not collected")
    return ExternalFileSnapshot(path=absolute, payload=payload, metadata=metadata)


def _require_external_unchanged(expected: ExternalFileSnapshot, *, label: str) -> None:
    observed = _read_external_regular(expected.path, label=label)
    if observed.payload != expected.payload or observed.metadata != expected.metadata:
        raise EvidenceWrapperError(f"{label} changed during finalization")


def _load_provenance_rules(
    source: ExternalFileSnapshot | None,
    *,
    default_gate_ids: Tuple[str, ...],
) -> Tuple[ProvenanceRule, ...]:
    if source is None:
        return ()
    document = _strict_json(source.payload, label="provenance map")
    if not isinstance(document, dict) or set(document) != {
        "schema_version",
        "rules",
    }:
        raise EvidenceWrapperError(
            "provenance map must contain only schema_version and rules"
        )
    if document.get("schema_version") != "1.0.0":
        raise EvidenceWrapperError("provenance map schema version is invalid")
    raw_rules = document.get("rules")
    if not isinstance(raw_rules, list) or not raw_rules:
        raise EvidenceWrapperError("provenance map rules are absent")
    rules = []
    for ordinal, raw_rule in enumerate(raw_rules):
        if not isinstance(raw_rule, dict):
            raise EvidenceWrapperError(f"provenance rule {ordinal} is not an object")
        selector_fields = set(raw_rule).intersection({"exact_path", "path_prefix"})
        allowed = {
            "exact_path",
            "path_prefix",
            "producer",
            "command",
            "platform",
            "machine",
            "gate_ids",
        }
        if len(selector_fields) != 1 or not set(raw_rule).issubset(allowed):
            raise EvidenceWrapperError(
                f"provenance rule {ordinal} must have one exact selector and no extra fields"
            )
        required = {"producer", "command", "platform", "machine"} | selector_fields
        if not required.issubset(raw_rule):
            raise EvidenceWrapperError(
                f"provenance rule {ordinal} is missing required fields"
            )
        selector_kind = next(iter(selector_fields))
        selector = _safe_relative(
            raw_rule[selector_kind],
            label=f"provenance rule {ordinal} selector",
        )
        if selector == MANIFEST_NAME:
            raise EvidenceWrapperError(
                "provenance map cannot select the reserved artifact manifest"
            )
        raw_gate_ids = raw_rule.get("gate_ids", list(default_gate_ids))
        if not isinstance(raw_gate_ids, list):
            raise EvidenceWrapperError(
                f"provenance rule {ordinal} gate IDs are not an array"
            )
        provenance = _validate_provenance(
            producer=raw_rule.get("producer"),
            command=raw_rule.get("command"),
            platform=raw_rule.get("platform"),
            machine=raw_rule.get("machine"),
            gate_ids=raw_gate_ids,
            label=f"provenance rule {ordinal}",
        )
        rules.append(
            ProvenanceRule(
                selector_kind=selector_kind,
                selector=selector,
                provenance=provenance,
                ordinal=ordinal,
            )
        )
    return tuple(rules)


def _resolve_provenance(
    paths: Sequence[str],
    *,
    rules: Sequence[ProvenanceRule],
    fallback: Provenance | None,
) -> Mapping[str, Provenance]:
    result = {}
    used_rules = set()
    for path in paths:
        exact = [
            rule
            for rule in rules
            if rule.selector_kind == "exact_path" and rule.selector == path
        ]
        if len(exact) > 1:
            raise EvidenceWrapperError(f"ambiguous exact provenance for {path}")
        if exact:
            selected = exact[0]
        else:
            prefixes = [
                rule
                for rule in rules
                if rule.selector_kind == "path_prefix"
                and (path == rule.selector or path.startswith(f"{rule.selector}/"))
            ]
            if prefixes:
                longest = max(len(rule.selector) for rule in prefixes)
                winners = [rule for rule in prefixes if len(rule.selector) == longest]
                if len(winners) != 1:
                    raise EvidenceWrapperError(
                        f"ambiguous longest-prefix provenance for {path}"
                    )
                selected = winners[0]
            else:
                selected = None
        if selected is not None:
            result[path] = selected.provenance
            used_rules.add(selected.ordinal)
        elif fallback is not None:
            result[path] = fallback
        else:
            raise EvidenceWrapperError(f"unmatched artifact provenance: {path}")
    unused = sorted(rule.ordinal for rule in rules if rule.ordinal not in used_rules)
    if unused:
        raise EvidenceWrapperError(f"unused provenance rules: {unused}")
    return result


def _git_bytes(project_root: Path, arguments: Sequence[str]) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(project_root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise EvidenceWrapperError(
            f"repository-state command failed ({result.returncode}): {diagnostic}"
        )
    return result.stdout


def _repository_state(project_root: Path) -> RepositoryState:
    top_level = _git_bytes(project_root, ("rev-parse", "--show-toplevel")).rstrip(
        b"\n"
    )
    try:
        decoded_top_level = top_level.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise EvidenceWrapperError("repository top-level path is not UTF-8") from error
    if Path(decoded_top_level) != project_root:
        raise EvidenceWrapperError("project root is not the bound repository top level")
    project_commit = _git_bytes(
        project_root,
        ("rev-parse", "--verify", "HEAD"),
    ).decode("ascii", errors="strict").strip()
    if re.fullmatch(r"[0-9a-f]{40}", project_commit) is None:
        raise EvidenceWrapperError("repository HEAD is not a lowercase SHA-1")
    tracked_diff = _git_bytes(
        project_root,
        (
            "diff",
            "--binary",
            "--no-ext-diff",
            "HEAD",
            "--",
            ".",
            ":(exclude)Artifacts/**",
        ),
    )
    untracked = _git_bytes(
        project_root,
        (
            "ls-files",
            "-z",
            "--others",
            "--exclude-standard",
            "--",
            ".",
            ":(exclude)Artifacts/**",
        ),
    )
    if tracked_diff or untracked:
        raise EvidenceWrapperError(
            "project working tree is not clean outside Artifacts"
        )
    return RepositoryState(
        project_commit=project_commit,
        tracked_diff_sha256=hashlib.sha256(tracked_diff).hexdigest(),
        untracked_paths_sha256=hashlib.sha256(untracked).hexdigest(),
    )


def _require_repository_unchanged(
    project_root: Path,
    expected: RepositoryState,
    expected_identity: os.stat_result,
) -> None:
    current_identity = _require_canonical_directory(
        project_root,
        label="project root",
    )
    if _identity(current_identity) != _identity(expected_identity):
        raise EvidenceWrapperError("project root identity changed during finalization")
    if _repository_state(project_root) != expected:
        raise EvidenceWrapperError("repository state changed during finalization")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00",
        "Z",
    )


def _build_manifest(
    snapshot: TreeSnapshot,
    *,
    project_commit: str,
    provenance: Mapping[str, Provenance],
) -> Mapping[str, object]:
    artifacts = []
    for item in snapshot.files:
        if item.path == MANIFEST_NAME:
            raise EvidenceWrapperError("artifact manifest already exists in partial root")
        record_provenance = provenance[item.path]
        artifacts.append(
            {
                "path": item.path,
                "sha256": item.sha256,
                "size_bytes": item.size_bytes,
                "producer": record_provenance.producer,
                "gate_ids": list(record_provenance.gate_ids),
                "command": record_provenance.command,
                "platform": record_provenance.platform,
                "machine": record_provenance.machine,
            }
        )
    manifest = {
        "schema_version": "2.0.0",
        "created_utc": _utc_now(),
        "project_commit": project_commit,
        "working_tree_clean": True,
        "directories": [
            item.path for item in snapshot.directories if item.path
        ],
        "artifacts": artifacts,
    }
    try:
        validate_schema(manifest, SCHEMA_PATH)
    except ValueError as error:
        raise EvidenceWrapperError("artifact manifest schema validation failed") from error
    return manifest


def _write_new_manifest(root_descriptor: int, payload: bytes) -> None:
    _require_absent_at(root_descriptor, MANIFEST_NAME, label="artifact manifest")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = -1
    created = False
    try:
        descriptor = os.open(MANIFEST_NAME, flags, 0o600, dir_fd=root_descriptor)
        created = True
        os.fchmod(descriptor, 0o644)
        view = memoryview(payload)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise EvidenceWrapperError("artifact manifest write stalled")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.fsync(root_descriptor)
    except BaseException as primary:
        if descriptor >= 0:
            os.close(descriptor)
            descriptor = -1
        if created:
            try:
                os.unlink(MANIFEST_NAME, dir_fd=root_descriptor)
                os.fsync(root_descriptor)
            except BaseException as cleanup:
                raise EvidenceWrapperError(
                    f"artifact manifest creation failed; cleanup failed: {cleanup}"
                ) from primary
        if isinstance(primary, EvidenceWrapperError):
            raise
        raise EvidenceWrapperError("artifact manifest creation failed") from primary
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _fchflags(descriptor: int, flags: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    fchflags = getattr(libc, "fchflags", None)
    if fchflags is None:
        raise EvidenceWrapperError("fchflags is unavailable")
    fchflags.argtypes = [ctypes.c_int, ctypes.c_uint32]
    fchflags.restype = ctypes.c_int
    if fchflags(descriptor, flags) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))


def _remove_write_bits(descriptor: int, metadata: os.stat_result) -> None:
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    if metadata.st_mode & write_bits:
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) & ~write_bits)


def _seal_descriptor(descriptor: int, *, label: str) -> None:
    if not hasattr(stat, "UF_IMMUTABLE"):
        raise EvidenceWrapperError(
            "macOS user-immutable flags are required for wrapper finalization"
        )
    metadata = os.fstat(descriptor)
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    if metadata.st_flags & stat.UF_IMMUTABLE:
        if metadata.st_mode & write_bits:
            raise EvidenceWrapperError(f"immutable {label} remains writable")
    else:
        _remove_write_bits(descriptor, metadata)
        current = os.fstat(descriptor)
        _fchflags(descriptor, current.st_flags | stat.UF_IMMUTABLE)
    os.fsync(descriptor)
    sealed = os.fstat(descriptor)
    if sealed.st_mode & write_bits or not sealed.st_flags & stat.UF_IMMUTABLE:
        raise EvidenceWrapperError(f"{label} did not become read-only and immutable")


def _fsync_tree(root_descriptor: int) -> None:
    for directory, directory_names, file_names, descriptor in os.fwalk(
        ".",
        topdown=False,
        onerror=_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        relative_directory = "" if directory == "." else directory[2:]
        for name in sorted(file_names):
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            file_descriptor = os.open(
                name,
                _regular_flags(),
                dir_fd=descriptor,
            )
            try:
                metadata = os.fstat(file_descriptor)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise EvidenceWrapperError(
                        f"artifact changed before recursive sync: {relative}"
                    )
                os.fsync(file_descriptor)
            finally:
                os.close(file_descriptor)
        for name in directory_names:
            child = _stat_at(
                descriptor,
                name,
                label="recursive sync directory",
            )
            if not stat.S_ISDIR(child.st_mode):
                raise EvidenceWrapperError(
                    "artifact traversal changed before recursive sync"
                )
        os.fsync(descriptor)


def _seal_descendants(root_descriptor: int) -> None:
    for directory, _, file_names, descriptor in os.fwalk(
        ".",
        topdown=False,
        onerror=_walk_error,
        follow_symlinks=False,
        dir_fd=root_descriptor,
    ):
        relative_directory = "" if directory == "." else directory[2:]
        for name in sorted(file_names):
            relative = (
                name
                if not relative_directory
                else f"{relative_directory}/{name}"
            )
            file_descriptor = os.open(
                name,
                _regular_flags(),
                dir_fd=descriptor,
            )
            try:
                metadata = os.fstat(file_descriptor)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    raise EvidenceWrapperError(
                        f"artifact changed before sealing: {relative}"
                    )
                _seal_descriptor(file_descriptor, label=f"artifact file {relative}")
            finally:
                os.close(file_descriptor)
        if relative_directory:
            _seal_descriptor(
                descriptor,
                label=f"artifact directory {relative_directory}",
            )
        else:
            root_metadata = os.fstat(descriptor)
            if root_metadata.st_flags & stat.UF_IMMUTABLE:
                raise EvidenceWrapperError(
                    "partial artifact root is immutable before publication"
                )
            _remove_write_bits(descriptor, root_metadata)
            os.fsync(descriptor)


def _rename_exclusive_at(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    _rename_exclusive_between(
        parent_descriptor,
        source_name,
        parent_descriptor,
        destination_name,
    )


def _rename_exclusive_between(
    source_parent_descriptor: int,
    source_name: str,
    destination_parent_descriptor: int,
    destination_name: str,
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx = getattr(libc, "renameatx_np", None)
    if renameatx is None:
        raise EvidenceWrapperError("renameatx_np is unavailable")
    renameatx.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx.restype = ctypes.c_int
    result = renameatx(
        source_parent_descriptor,
        os.fsencode(source_name),
        destination_parent_descriptor,
        os.fsencode(destination_name),
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH,
    )
    if result != 0:
        number = ctypes.get_errno()
        if number == errno.EEXIST:
            raise EvidenceWrapperError(
                f"exclusive destination already exists: {destination_name}"
            )
        raise EvidenceWrapperError(
            f"exclusive rename failed: {os.strerror(number)}"
        )


def _directory_entry_names(parent_descriptor: int) -> Tuple[str, ...]:
    try:
        names = os.listdir(parent_descriptor)
    except OSError as error:
        raise EvidenceWrapperError("cannot enumerate transaction namespace") from error
    if any(not isinstance(name, str) or name in {"", ".", ".."} for name in names):
        raise EvidenceWrapperError("transaction namespace contains an invalid name")
    return tuple(sorted(names))


def _names_for_identity(
    parent_descriptor: int,
    expected_identity: Tuple[int, int],
) -> Tuple[str, ...]:
    matches = []
    for name in _directory_entry_names(parent_descriptor):
        try:
            metadata = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            continue
        except OSError as error:
            raise EvidenceWrapperError(
                f"cannot inspect transaction namespace entry: {name}"
            ) from error
        if _identity(metadata) == expected_identity:
            matches.append(name)
    if len(matches) > 1:
        raise EvidenceWrapperError(
            "owned transaction identity has multiple namespace entries"
        )
    return tuple(matches)


def _foreign_name(base_name: str, token: str, ordinal: int) -> str:
    return f".{base_name}.foreign-{token}-{ordinal:02d}"


def _evacuate_foreign_entry(
    parent_descriptor: int,
    *,
    name: str,
    expected_identity: Tuple[int, int],
    token: str,
    start_ordinal: int,
) -> int:
    """Preserve a foreign collision under a neutral, exclusive sibling name."""

    ordinal = start_ordinal
    for _ in range(16):
        current = _entry_identity(parent_descriptor, name)
        if current is None or current == expected_identity:
            return ordinal
        destination = _foreign_name(name.lstrip("."), token, ordinal)
        ordinal += 1
        if _entry_identity(parent_descriptor, destination) is not None:
            continue
        foreign_identity = current
        try:
            _rename_exclusive_at(parent_descriptor, name, destination)
        except EvidenceWrapperError:
            continue
        moved = _entry_identity(parent_descriptor, destination)
        if moved != foreign_identity:
            continue
        if _entry_identity(parent_descriptor, name) is None:
            return ordinal
    raise EvidenceWrapperError(
        f"cannot clear foreign transaction namespace entry: {name}"
    )


def _move_owned_entry(
    parent_descriptor: int,
    *,
    preferred_source_name: str,
    destination_name: str,
    expected_identity: Tuple[int, int],
    token: str,
    fail_on_substitution: bool,
) -> bool:
    """Move one identity, evacuating foreign collisions and detecting substitution.

    Darwin does not expose a rename primitive that predicates on the source inode.
    This routine therefore validates both sides of every rename, preserves foreign
    entries under neutral names, rediscovers the pinned inode in the same parent,
    and never returns success after observing a substitution.
    """

    substitution_seen = False
    uncertain_rename_seen = False
    foreign_ordinal = 0
    for _ in range(16):
        destination_identity = _entry_identity(parent_descriptor, destination_name)
        if destination_identity == expected_identity:
            source_identity = _entry_identity(
                parent_descriptor,
                preferred_source_name,
            )
            if source_identity is not None:
                if source_identity != expected_identity:
                    substitution_seen = True
                    foreign_ordinal = _evacuate_foreign_entry(
                        parent_descriptor,
                        name=preferred_source_name,
                        expected_identity=expected_identity,
                        token=token,
                        start_ordinal=foreign_ordinal,
                    )
                else:
                    raise EvidenceWrapperError(
                        "owned transaction identity appears at source and destination"
                    )
            if fail_on_substitution and (
                substitution_seen or uncertain_rename_seen
            ):
                raise EvidenceWrapperError(
                    "transaction rename outcome was uncertain or substituted"
                )
            return substitution_seen
        if destination_identity is not None:
            substitution_seen = True
            foreign_ordinal = _evacuate_foreign_entry(
                parent_descriptor,
                name=destination_name,
                expected_identity=expected_identity,
                token=token,
                start_ordinal=foreign_ordinal,
            )

        preferred_identity = _entry_identity(
            parent_descriptor,
            preferred_source_name,
        )
        if preferred_identity == expected_identity:
            source_name = preferred_source_name
        else:
            if preferred_identity is not None:
                substitution_seen = True
                foreign_ordinal = _evacuate_foreign_entry(
                    parent_descriptor,
                    name=preferred_source_name,
                    expected_identity=expected_identity,
                    token=token,
                    start_ordinal=foreign_ordinal,
                )
            names = _names_for_identity(parent_descriptor, expected_identity)
            if not names:
                raise EvidenceWrapperError(
                    "owned transaction root is no longer discoverable in its parent"
                )
            source_name = names[0]
            if source_name != preferred_source_name:
                substitution_seen = True
        try:
            _rename_exclusive_at(
                parent_descriptor,
                source_name,
                destination_name,
            )
        except EvidenceWrapperError:
            uncertain_rename_seen = True
            continue
        if _entry_identity(parent_descriptor, destination_name) != expected_identity:
            substitution_seen = True
            continue
    try:
        _evacuate_foreign_entry(
            parent_descriptor,
            name=destination_name,
            expected_identity=expected_identity,
            token=token,
            start_ordinal=foreign_ordinal,
        )
    except EvidenceWrapperError:
        pass
    raise EvidenceWrapperError("owned transaction rename did not converge")


def _manifest_from_descriptor(
    root_descriptor: int,
) -> Tuple[Mapping[str, object], bytes]:
    _, payload = _read_regular_at(
        root_descriptor,
        MANIFEST_NAME,
        relative_path=MANIFEST_NAME,
        collect=True,
    )
    if payload is None:
        raise EvidenceWrapperError("artifact manifest was not collected")
    document = _strict_json(payload, label="artifact manifest")
    if not isinstance(document, dict):
        raise EvidenceWrapperError("artifact manifest is not an object")
    if payload != canonical_json_bytes(document) + b"\n":
        raise EvidenceWrapperError("artifact manifest bytes are not canonical JSON")
    try:
        validate_schema(document, SCHEMA_PATH)
    except ValueError as error:
        raise EvidenceWrapperError("artifact manifest schema validation failed") from error
    return document, payload


def _verify_tree(
    root_descriptor: int,
    *,
    expected_manifest: Mapping[str, object],
    expected_identity: os.stat_result,
    expected_raw_snapshot: TreeSnapshot,
    expected_closure_snapshot: TreeSnapshot | None = None,
    require_frozen: bool,
    require_descendants_frozen: bool = False,
) -> TreeSnapshot:
    if _identity(os.fstat(root_descriptor)) != _identity(expected_identity):
        raise EvidenceWrapperError("artifact root identity changed during verification")
    manifest, _ = _manifest_from_descriptor(root_descriptor)
    if manifest != expected_manifest:
        raise EvidenceWrapperError("artifact manifest content changed")
    snapshot = _snapshot_tree(root_descriptor)
    raw_files = [item for item in snapshot.files if item.path != MANIFEST_NAME]
    if len(raw_files) + 1 != len(snapshot.files):
        raise EvidenceWrapperError("artifact manifest path is absent or duplicated")
    observed_raw = TreeSnapshot(
        files=tuple(raw_files),
        directories=snapshot.directories,
    )
    _require_snapshot_unchanged(
        expected_raw_snapshot,
        observed_raw,
        require_metadata=False,
    )
    if expected_closure_snapshot is not None:
        _require_snapshot_unchanged(
            expected_closure_snapshot,
            snapshot,
            require_metadata=False,
        )
    rows = manifest.get("artifacts")
    declared_directories = manifest.get("directories")
    expected_directory_paths = [
        item.path for item in snapshot.directories if item.path
    ]
    if declared_directories != expected_directory_paths:
        raise EvidenceWrapperError(
            "artifact manifest directory closure changed"
        )
    if not isinstance(rows, list) or [row.get("path") for row in rows] != [
        item.path for item in raw_files
    ]:
        raise EvidenceWrapperError("artifact manifest path set or order changed")
    for row, item in zip(rows, raw_files):
        if (
            not isinstance(row, dict)
            or row.get("sha256") != item.sha256
            or row.get("size_bytes") != item.size_bytes
        ):
            raise EvidenceWrapperError(f"artifact bytes changed: {item.path}")
    expected_files = {item.path: item for item in expected_raw_snapshot.files}
    expected_directories = {
        item.path: item for item in expected_raw_snapshot.directories
    }
    observed_files = {item.path: item for item in raw_files}
    observed_directories = {item.path: item for item in snapshot.directories}
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    for path, before in expected_files.items():
        after = observed_files[path]
        expected_mode = stat.S_IMODE(before.mode)
        expected_flags = before.flags
        if require_frozen or require_descendants_frozen:
            expected_mode &= ~write_bits
            expected_flags |= stat.UF_IMMUTABLE
        if (
            stat.S_IMODE(after.mode) != expected_mode
            or after.flags != expected_flags
        ):
            raise EvidenceWrapperError(
                f"artifact file mode or flags changed unexpectedly: {path}"
            )
    for path, before in expected_directories.items():
        after = observed_directories[path]
        expected_mode = stat.S_IMODE(before.mode)
        expected_flags = before.flags
        if require_frozen or require_descendants_frozen:
            expected_mode &= ~write_bits
            if require_frozen or path:
                expected_flags |= stat.UF_IMMUTABLE
        if (
            stat.S_IMODE(after.mode) != expected_mode
            or after.flags != expected_flags
        ):
            raise EvidenceWrapperError(
                "artifact directory mode or flags changed unexpectedly: "
                f"{path or '<root>'}"
            )
    manifest_entry = next(
        item for item in snapshot.files if item.path == MANIFEST_NAME
    )
    expected_manifest_mode = 0o444 if (
        require_frozen or require_descendants_frozen
    ) else 0o644
    expected_manifest_flags = (
        stat.UF_IMMUTABLE if require_frozen or require_descendants_frozen else 0
    )
    if (
        stat.S_IMODE(manifest_entry.mode) != expected_manifest_mode
        or manifest_entry.flags != expected_manifest_flags
    ):
        raise EvidenceWrapperError(
            "artifact manifest mode or flags changed unexpectedly"
        )
    if require_frozen or require_descendants_frozen:
        for item in snapshot.files:
            if item.mode & write_bits:
                raise EvidenceWrapperError(f"artifact file is writable: {item.path}")
        for item in snapshot.directories:
            if item.mode & write_bits:
                raise EvidenceWrapperError(
                    f"artifact directory is writable: {item.path or '<root>'}"
                )
        for directory, _, file_names, descriptor in os.fwalk(
            ".",
            topdown=True,
            onerror=_walk_error,
            follow_symlinks=False,
            dir_fd=root_descriptor,
        ):
            relative_directory = "" if directory == "." else directory[2:]
            metadata = os.fstat(descriptor)
            if (
                (require_frozen or relative_directory)
                and not metadata.st_flags & stat.UF_IMMUTABLE
            ):
                raise EvidenceWrapperError(
                    f"artifact directory is mutable: {relative_directory or '<root>'}"
                )
            for name in sorted(file_names):
                relative = (
                    name
                    if not relative_directory
                    else f"{relative_directory}/{name}"
                )
                file_descriptor = os.open(
                    name,
                    _regular_flags(),
                    dir_fd=descriptor,
                )
                try:
                    file_metadata = os.fstat(file_descriptor)
                    if not file_metadata.st_flags & stat.UF_IMMUTABLE:
                        raise EvidenceWrapperError(
                            f"artifact file is mutable: {relative}"
                        )
                finally:
                    os.close(file_descriptor)
    return snapshot


def _entry_identity(
    parent_descriptor: int,
    name: str,
) -> Tuple[int, int] | None:
    try:
        metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise EvidenceWrapperError(f"cannot inspect transaction entry: {name}") from error
    return _identity(metadata)


def _transaction_marker_name(final_name: str) -> str:
    return f".{final_name}.evidence-wrapper-transaction.json"


def _transaction_completion_name(final_name: str) -> str:
    return f".{final_name}.evidence-wrapper-complete.json"


def _cleanup_record_name(name: str, token: str) -> str:
    return f".{name.lstrip('.')}.cleanup-{token}"


def _transaction_root_marker_name() -> str:
    return "publication-transaction.json"


def _write_new_regular_at(
    directory_descriptor: int,
    name: str,
    payload: bytes,
    *,
    mode: int,
    immutable: bool,
) -> FileSnapshot:
    _require_absent_at(directory_descriptor, name, label=f"record {name}")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor = -1
    created = False
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_descriptor)
        created = True
        view = memoryview(payload)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise EvidenceWrapperError(f"record write stalled: {name}")
            written += count
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        if immutable:
            _seal_descriptor(descriptor, label=f"transaction record {name}")
        metadata = os.fstat(descriptor)
        os.fsync(directory_descriptor)
    except BaseException as primary:
        if descriptor >= 0:
            os.close(descriptor)
            descriptor = -1
        if created:
            try:
                current = _entry_identity(directory_descriptor, name)
                if current is not None:
                    os.unlink(name, dir_fd=directory_descriptor)
                    os.fsync(directory_descriptor)
            except BaseException as cleanup:
                raise EvidenceWrapperError(
                    f"record creation failed; cleanup failed: {cleanup}"
                ) from primary
        if isinstance(primary, EvidenceWrapperError):
            raise
        raise EvidenceWrapperError(f"record creation failed: {name}") from primary
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return FileSnapshot(
        path=name,
        sha256=hashlib.sha256(payload).hexdigest(),
        size_bytes=len(payload),
        device=metadata.st_dev,
        inode=metadata.st_ino,
        mode=metadata.st_mode,
        flags=metadata.st_flags,
        mtime_ns=metadata.st_mtime_ns,
        ctime_ns=metadata.st_ctime_ns,
    )


def _publish_immutable_control_at(
    parent_descriptor: int,
    *,
    name: str,
    payload: bytes,
    token: str,
    kind: str,
) -> FileSnapshot:
    """Publish one complete immutable control record under its canonical name."""

    if kind not in {"marker", "completion"}:
        raise EvidenceWrapperError("transaction control kind is invalid")
    temporary_name = f".evidence-wrapper-{kind}-{token}.tmp"
    _require_absent_at(
        parent_descriptor,
        temporary_name,
        label="transaction control staging record",
    )
    _require_absent_at(
        parent_descriptor,
        name,
        label="transaction control record",
    )
    staged = _write_new_regular_at(
        parent_descriptor,
        temporary_name,
        payload,
        mode=0o400,
        immutable=False,
    )
    expected_identity = (staged.device, staged.inode)
    try:
        _move_owned_entry(
            parent_descriptor,
            preferred_source_name=temporary_name,
            destination_name=name,
            expected_identity=expected_identity,
            token=token,
            fail_on_substitution=True,
        )
        os.fsync(parent_descriptor)
        control_descriptor = _open_regular_owned_at(
            parent_descriptor,
            name,
            expected_identity=expected_identity,
            label=f"transaction control record {name}",
        )
        try:
            _seal_descriptor(
                control_descriptor,
                label=f"transaction control record {name}",
            )
        finally:
            os.close(control_descriptor)
        observed, reopened = _read_regular_at(
            parent_descriptor,
            name,
            relative_path=name,
            collect=True,
        )
        if (
            reopened != payload
            or (observed.device, observed.inode) != expected_identity
            or observed.mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
            or not observed.flags & stat.UF_IMMUTABLE
            or _entry_identity(parent_descriptor, temporary_name) is not None
        ):
            raise EvidenceWrapperError(
                "transaction control record changed during atomic publication"
            )
        return observed
    except BaseException as primary:
        if _entry_identity(parent_descriptor, temporary_name) == expected_identity:
            try:
                _remove_owned_record(
                    parent_descriptor,
                    name=temporary_name,
                    expected_identity=expected_identity,
                    token=token,
                )
            except BaseException as cleanup:
                raise EvidenceWrapperError(
                    f"transaction control publication failed; cleanup failed: {cleanup}"
                ) from primary
        raise


def _transaction_document(
    *,
    token: str,
    project_commit: str,
    partial_name: str,
    final_name: str,
    failure_name: str,
    root_identity: Tuple[int, int],
    gate_ids: Tuple[str, ...],
) -> Mapping[str, object]:
    return {
        "schema_version": TRANSACTION_SCHEMA_VERSION,
        "artifact_kind": "evidence_wrapper_publication_transaction",
        "transaction_token": token,
        "created_utc": _utc_now(),
        "project_commit": project_commit,
        "partial_name": partial_name,
        "final_name": final_name,
        "failure_name": failure_name,
        "gate_ids": list(gate_ids),
        "root_device": root_identity[0],
        "root_inode": root_identity[1],
    }


def _validate_transaction_document(
    document: object,
    *,
    partial_name: str,
    final_name: str,
    failure_name: str,
) -> Mapping[str, object]:
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
    if not isinstance(document, dict) or set(document) != required:
        raise EvidenceWrapperError("transaction marker structure is invalid")
    if (
        document.get("schema_version") != TRANSACTION_SCHEMA_VERSION
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
        or not isinstance(document.get("project_commit"), str)
        or re.fullmatch(r"[0-9a-f]{40}", str(document["project_commit"])) is None
        or document.get("partial_name") != partial_name
        or document.get("final_name") != final_name
        or document.get("failure_name") != failure_name
        or not isinstance(document.get("gate_ids"), list)
        or tuple(document["gate_ids"])
        != _validate_gate_ids(
            document["gate_ids"],
            label="transaction marker gate IDs",
        )
        or not isinstance(document.get("root_device"), int)
        or isinstance(document.get("root_device"), bool)
        or int(document["root_device"]) < 0
        or not isinstance(document.get("root_inode"), int)
        or isinstance(document.get("root_inode"), bool)
        or int(document["root_inode"]) < 1
    ):
        raise EvidenceWrapperError("transaction marker values are invalid")
    return document


def _load_transaction_marker(
    parent_descriptor: int,
    *,
    name: str,
    partial_name: str,
    final_name: str,
    failure_name: str,
    require_immutable: bool = True,
) -> TransactionMarker:
    metadata, payload = _read_regular_at(
        parent_descriptor,
        name,
        relative_path=name,
        collect=True,
    )
    assert payload is not None
    document = _validate_transaction_document(
        _strict_json(payload, label="transaction marker"),
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
    )
    if payload != canonical_json_bytes(document) + b"\n":
        raise EvidenceWrapperError("transaction marker is not canonical JSON")
    if (
        metadata.mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
        or (require_immutable and not metadata.flags & stat.UF_IMMUTABLE)
    ):
        raise EvidenceWrapperError("transaction marker is not immutable")
    return TransactionMarker(
        name=name,
        completion_name=_transaction_completion_name(final_name),
        token=str(document["transaction_token"]),
        document=document,
        payload=payload,
        metadata=metadata,
    )


def _create_transaction_marker(
    parent_descriptor: int,
    *,
    project_commit: str,
    partial_name: str,
    final_name: str,
    failure_name: str,
    root_identity: Tuple[int, int],
    gate_ids: Tuple[str, ...],
) -> TransactionMarker:
    token = secrets.token_hex(16)
    document = _transaction_document(
        token=token,
        project_commit=project_commit,
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
        root_identity=root_identity,
        gate_ids=gate_ids,
    )
    payload = canonical_json_bytes(document) + b"\n"
    name = _transaction_marker_name(final_name)
    metadata = _publish_immutable_control_at(
        parent_descriptor,
        name=name,
        payload=payload,
        token=token,
        kind="marker",
    )
    return TransactionMarker(
        name=name,
        completion_name=_transaction_completion_name(final_name),
        token=token,
        document=document,
        payload=payload,
        metadata=metadata,
    )


def _completion_document(marker: TransactionMarker) -> Mapping[str, object]:
    return {
        "schema_version": TRANSACTION_SCHEMA_VERSION,
        "artifact_kind": "evidence_wrapper_publication_complete",
        "transaction": marker.document,
        "completed_utc": _utc_now(),
    }


def _validate_completion_document(
    document: object,
    *,
    marker_document: Mapping[str, object],
) -> Mapping[str, object]:
    if (
        not isinstance(document, dict)
        or set(document) != {
            "schema_version",
            "artifact_kind",
            "transaction",
            "completed_utc",
        }
        or document.get("schema_version") != TRANSACTION_SCHEMA_VERSION
        or document.get("artifact_kind")
        != "evidence_wrapper_publication_complete"
        or document.get("transaction") != marker_document
        or not isinstance(document.get("completed_utc"), str)
    ):
        raise EvidenceWrapperError("transaction completion receipt is invalid")
    return document


def _create_completion_receipt(
    parent_descriptor: int,
    marker: TransactionMarker,
) -> FileSnapshot:
    document = _completion_document(marker)
    return _publish_immutable_control_at(
        parent_descriptor,
        name=marker.completion_name,
        payload=canonical_json_bytes(document) + b"\n",
        token=marker.token,
        kind="completion",
    )


def _load_completion_receipt(
    parent_descriptor: int,
    marker: TransactionMarker,
    *,
    require_immutable: bool = True,
) -> FileSnapshot:
    metadata, payload = _read_regular_at(
        parent_descriptor,
        marker.completion_name,
        relative_path=marker.completion_name,
        collect=True,
    )
    assert payload is not None
    document = _strict_json(payload, label="transaction completion receipt")
    _validate_completion_document(document, marker_document=marker.document)
    if payload != canonical_json_bytes(document) + b"\n":
        raise EvidenceWrapperError(
            "transaction completion receipt is not canonical JSON"
        )
    if (
        metadata.mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
        or (require_immutable and not metadata.flags & stat.UF_IMMUTABLE)
    ):
        raise EvidenceWrapperError("transaction completion receipt is not immutable")
    return metadata


def _remove_owned_record(
    parent_descriptor: int,
    *,
    name: str,
    expected_identity: Tuple[int, int],
    token: str,
) -> None:
    cleanup_name = _cleanup_record_name(name, token)
    if _entry_identity(parent_descriptor, cleanup_name) is not None:
        raise EvidenceWrapperError("transaction cleanup namespace already exists")
    descriptor = _open_regular_owned_at(
        parent_descriptor,
        name,
        expected_identity=expected_identity,
        label=f"transaction record {name}",
    )
    try:
        metadata = os.fstat(descriptor)
        if metadata.st_flags & stat.UF_IMMUTABLE:
            _fchflags(descriptor, metadata.st_flags & ~stat.UF_IMMUTABLE)
            os.fsync(descriptor)
        _move_owned_entry(
            parent_descriptor,
            preferred_source_name=name,
            destination_name=cleanup_name,
            expected_identity=expected_identity,
            token=token,
            fail_on_substitution=False,
        )
        if _entry_identity(parent_descriptor, cleanup_name) != expected_identity:
            raise EvidenceWrapperError("transaction cleanup identity changed")
        os.unlink(cleanup_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
        if _entry_identity(parent_descriptor, cleanup_name) is not None:
            raise EvidenceWrapperError("transaction cleanup record survived unlink")
    finally:
        os.close(descriptor)


def _open_regular_owned_at(
    parent_descriptor: int,
    name: str,
    *,
    expected_identity: Tuple[int, int],
    label: str,
) -> int:
    try:
        descriptor = os.open(name, _regular_flags(), dir_fd=parent_descriptor)
    except OSError as error:
        raise EvidenceWrapperError(f"cannot open {label}") from error
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or _identity(metadata) != expected_identity
    ):
        os.close(descriptor)
        raise EvidenceWrapperError(f"{label} identity changed")
    return descriptor


def _quarantine_owned_root(
    parent_descriptor: int,
    *,
    source_name: str,
    final_name: str,
    failure_name: str,
    root_descriptor: int,
    expected_identity: os.stat_result,
    token: str,
) -> None:
    expected = _identity(expected_identity)
    try:
        opened = os.fstat(root_descriptor)
        if _identity(opened) != expected:
            raise EvidenceWrapperError("pinned owned artifact root identity changed")
        if opened.st_flags & stat.UF_IMMUTABLE:
            _fchflags(root_descriptor, opened.st_flags & ~stat.UF_IMMUTABLE)
            os.fsync(root_descriptor)
        _move_owned_entry(
            parent_descriptor,
            preferred_source_name=source_name,
            destination_name=failure_name,
            expected_identity=expected,
            token=token,
            fail_on_substitution=False,
        )
        os.fsync(parent_descriptor)
        _seal_descriptor(root_descriptor, label="quarantined artifact root")
        if _entry_identity(parent_descriptor, failure_name) != expected:
            raise EvidenceWrapperError("quarantined artifact identity changed")
        final_identity = _entry_identity(parent_descriptor, final_name)
        if final_identity == expected:
            raise EvidenceWrapperError(
                "owned artifact root reappeared at canonical final path"
            )
    except BaseException as primary:
        try:
            _seal_descriptor(root_descriptor, label="failed artifact root")
        except BaseException as reseal:
            raise EvidenceWrapperError(
                f"quarantine failed and root reseal failed: {reseal}"
            ) from primary
        raise


def _clear_root_immutable_for_failure(root_descriptor: int) -> None:
    metadata = os.fstat(root_descriptor)
    if metadata.st_flags & stat.UF_IMMUTABLE:
        _fchflags(root_descriptor, metadata.st_flags & ~stat.UF_IMMUTABLE)
        os.fsync(root_descriptor)
        metadata = os.fstat(root_descriptor)
    required = stat.S_IWUSR | stat.S_IXUSR | stat.S_IRUSR
    desired = stat.S_IMODE(metadata.st_mode) | required
    if stat.S_IMODE(metadata.st_mode) != desired:
        os.fchmod(root_descriptor, desired)
        os.fsync(root_descriptor)


def _preserve_prior_manifest(
    root_descriptor: int,
    *,
    token: str,
) -> str | None:
    identity = _entry_identity(root_descriptor, MANIFEST_NAME)
    if identity is None:
        return None
    descriptor = _open_regular_owned_at(
        root_descriptor,
        MANIFEST_NAME,
        expected_identity=identity,
        label="provisional artifact manifest",
    )
    try:
        metadata = os.fstat(descriptor)
        if metadata.st_flags & stat.UF_IMMUTABLE:
            _fchflags(descriptor, metadata.st_flags & ~stat.UF_IMMUTABLE)
            os.fsync(descriptor)
    finally:
        os.close(descriptor)
    candidates = (
        "provisional-artifact-manifest.json",
        f"provisional-artifact-manifest-{token}.json",
    )
    destination = next(
        (
            name
            for name in candidates
            if _entry_identity(root_descriptor, name) is None
        ),
        None,
    )
    if destination is None:
        raise EvidenceWrapperError(
            "cannot preserve provisional artifact manifest without collision"
        )
    _move_owned_entry(
        root_descriptor,
        preferred_source_name=MANIFEST_NAME,
        destination_name=destination,
        expected_identity=identity,
        token=token,
        fail_on_substitution=False,
    )
    os.fsync(root_descriptor)
    return destination


def _recovery_provenance(marker: TransactionMarker) -> Provenance:
    return Provenance(
        producer="Mirmir evidence-wrapper recovery",
        command="finalize_evidence_wrapper transaction recovery",
        platform=platform_module.platform(),
        machine=platform_module.node() or platform_module.machine() or "unknown-machine",
        gate_ids=tuple(str(value) for value in marker.document["gate_ids"]),
    )


def _recovery_document(
    marker: TransactionMarker,
    *,
    recovery_kind: str,
    source_name: str,
    failure_name: str,
    error_type: str,
    error_message: str,
    error_traceback: str,
) -> Mapping[str, object]:
    return {
        "schema_version": "1.0.0",
        "artifact_kind": "evidence_wrapper_failure_recovery",
        "recovered_utc": _utc_now(),
        "recovery_kind": recovery_kind,
        "transaction_marker_sha256": hashlib.sha256(marker.payload).hexdigest(),
        "transaction": marker.document,
        "source_namespace": source_name,
        "failure_namespace": failure_name,
        "error": {
            "type": error_type,
            "message": error_message,
            "traceback": error_traceback,
        },
    }


def _rebuild_failure_manifest(
    root_descriptor: int,
    *,
    expected_identity: os.stat_result,
    marker: TransactionMarker,
    recovery_kind: str,
    source_name: str,
    failure_name: str,
    error_type: str,
    error_message: str,
    error_traceback: str,
) -> None:
    _clear_root_immutable_for_failure(root_descriptor)
    _preserve_prior_manifest(root_descriptor, token=marker.token)
    recovery_name = RECOVERY_NAME
    if _entry_identity(root_descriptor, recovery_name) is not None:
        recovery_name = f"wrapper-recovery-{marker.token}.json"
    recovery_document = _recovery_document(
        marker,
        recovery_kind=recovery_kind,
        source_name=source_name,
        failure_name=failure_name,
        error_type=error_type,
        error_message=error_message,
        error_traceback=error_traceback,
    )
    _write_new_regular_at(
        root_descriptor,
        recovery_name,
        canonical_json_bytes(recovery_document) + b"\n",
        mode=0o644,
        immutable=False,
    )
    raw_snapshot = _snapshot_tree(root_descriptor)
    if any(item.path == MANIFEST_NAME for item in raw_snapshot.files):
        raise EvidenceWrapperError(
            "failure evidence retained an unpreserved artifact manifest"
        )
    provenance_value = _recovery_provenance(marker)
    provenance = {
        item.path: provenance_value for item in raw_snapshot.files
    }
    manifest = _build_manifest(
        raw_snapshot,
        project_commit=str(marker.document["project_commit"]),
        provenance=provenance,
    )
    _write_new_manifest(
        root_descriptor,
        canonical_json_bytes(manifest) + b"\n",
    )
    closure_snapshot = _verify_tree(
        root_descriptor,
        expected_manifest=manifest,
        expected_identity=expected_identity,
        expected_raw_snapshot=raw_snapshot,
        require_frozen=False,
    )
    _fsync_tree(root_descriptor)
    _seal_descendants(root_descriptor)
    _verify_tree(
        root_descriptor,
        expected_manifest=manifest,
        expected_identity=expected_identity,
        expected_raw_snapshot=raw_snapshot,
        expected_closure_snapshot=closure_snapshot,
        require_frozen=False,
        require_descendants_frozen=True,
    )
    _seal_descriptor(root_descriptor, label="failure evidence root")
    _verify_tree(
        root_descriptor,
        expected_manifest=manifest,
        expected_identity=expected_identity,
        expected_raw_snapshot=raw_snapshot,
        expected_closure_snapshot=closure_snapshot,
        require_frozen=True,
    )


def _preserve_failure_evidence(
    parent_descriptor: int,
    *,
    root_descriptor: int,
    expected_identity: os.stat_result,
    marker: TransactionMarker,
    partial_name: str,
    final_name: str,
    failure_name: str,
    recovery_kind: str,
    error_type: str,
    error_message: str,
    error_traceback: str,
) -> str:
    expected = _identity(expected_identity)
    names = _names_for_identity(parent_descriptor, expected)
    if not names:
        raise EvidenceWrapperError(
            "owned transaction root is not discoverable for failure preservation"
        )
    source_name = names[0]
    actual_failure_name = failure_name
    collision = _entry_identity(parent_descriptor, actual_failure_name)
    if collision is not None and collision != expected:
        actual_failure_name = f"{failure_name}-{marker.token}"
        _require_absent_at(
            parent_descriptor,
            actual_failure_name,
            label="tokenized failure evidence directory",
        )
    _clear_root_immutable_for_failure(root_descriptor)
    _move_owned_entry(
        parent_descriptor,
        preferred_source_name=source_name,
        destination_name=actual_failure_name,
        expected_identity=expected,
        token=marker.token,
        fail_on_substitution=False,
    )
    for canonical_name in (partial_name, final_name):
        identity = _entry_identity(parent_descriptor, canonical_name)
        if identity is None:
            continue
        if identity == expected:
            raise EvidenceWrapperError(
                "owned transaction root remains at a canonical non-failure path"
            )
        _evacuate_foreign_entry(
            parent_descriptor,
            name=canonical_name,
            expected_identity=expected,
            token=marker.token,
            start_ordinal=0,
        )
    _rebuild_failure_manifest(
        root_descriptor,
        expected_identity=expected_identity,
        marker=marker,
        recovery_kind=recovery_kind,
        source_name=source_name,
        failure_name=actual_failure_name,
        error_type=error_type,
        error_message=error_message,
        error_traceback=error_traceback,
    )
    if _entry_identity(parent_descriptor, actual_failure_name) != expected:
        raise EvidenceWrapperError("failure evidence namespace identity changed")
    os.fsync(parent_descriptor)
    return actual_failure_name


def _verify_completed_wrapper(
    parent_descriptor: int,
    *,
    final_name: str,
    marker: TransactionMarker,
) -> None:
    expected_identity = (
        int(marker.document["root_device"]),
        int(marker.document["root_inode"]),
    )
    if _entry_identity(parent_descriptor, final_name) != expected_identity:
        raise EvidenceWrapperError(
            "completion receipt does not bind the canonical final root"
        )
    descriptor = _open_directory_at(
        parent_descriptor,
        final_name,
        label="completed evidence wrapper",
    )
    try:
        metadata = os.fstat(descriptor)
        if _identity(metadata) != expected_identity:
            raise EvidenceWrapperError("completed wrapper identity changed")
        manifest, payload = _manifest_from_descriptor(descriptor)
        if payload != canonical_json_bytes(manifest) + b"\n":
            raise EvidenceWrapperError("completed wrapper manifest is not canonical")
        if manifest.get("project_commit") != marker.document["project_commit"]:
            raise EvidenceWrapperError("completed wrapper project commit differs")
        snapshot = _snapshot_tree(descriptor)
        raw_files = [item for item in snapshot.files if item.path != MANIFEST_NAME]
        rows = manifest.get("artifacts")
        directories = manifest.get("directories")
        if (
            not isinstance(rows, list)
            or [row.get("path") if isinstance(row, dict) else None for row in rows]
            != [item.path for item in raw_files]
            or directories
            != [item.path for item in snapshot.directories if item.path]
        ):
            raise EvidenceWrapperError("completed wrapper closure differs")
        for row, item in zip(rows, raw_files):
            if (
                row.get("sha256") != item.sha256
                or row.get("size_bytes") != item.size_bytes
            ):
                raise EvidenceWrapperError(
                    f"completed wrapper artifact differs: {item.path}"
                )
        root_marker = next(
            (
                item
                for item in raw_files
                if item.path == _transaction_root_marker_name()
            ),
            None,
        )
        if root_marker is None or root_marker.sha256 != hashlib.sha256(
            marker.payload
        ).hexdigest():
            raise EvidenceWrapperError(
                "completed wrapper transaction marker differs"
            )
        _, root_marker_payload = _read_regular_at(
            descriptor,
            _transaction_root_marker_name(),
            relative_path=_transaction_root_marker_name(),
            collect=True,
        )
        if root_marker_payload != marker.payload:
            raise EvidenceWrapperError(
                "completed wrapper transaction marker bytes differ"
            )
        write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
        if metadata.st_mode & write_bits or not metadata.st_flags & stat.UF_IMMUTABLE:
            raise EvidenceWrapperError("completed wrapper root is not frozen")
        for item in snapshot.files:
            if item.mode & write_bits or not item.flags & stat.UF_IMMUTABLE:
                raise EvidenceWrapperError(
                    f"completed wrapper file is not frozen: {item.path}"
                )
        for item in snapshot.directories:
            if item.mode & write_bits or not item.flags & stat.UF_IMMUTABLE:
                raise EvidenceWrapperError(
                    "completed wrapper directory is not frozen: "
                    f"{item.path or '<root>'}"
                )
    finally:
        os.close(descriptor)


def _load_completion_without_active(
    parent_descriptor: int,
    *,
    completion_name: str,
    partial_name: str,
    final_name: str,
    failure_name: str,
) -> Tuple[TransactionMarker, FileSnapshot]:
    metadata, payload = _read_regular_at(
        parent_descriptor,
        completion_name,
        relative_path=completion_name,
        collect=True,
    )
    assert payload is not None
    document = _strict_json(payload, label="transaction completion receipt")
    if not isinstance(document, dict):
        raise EvidenceWrapperError("transaction completion receipt is invalid")
    transaction = _validate_transaction_document(
        document.get("transaction"),
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
    )
    _validate_completion_document(document, marker_document=transaction)
    if payload != canonical_json_bytes(document) + b"\n":
        raise EvidenceWrapperError(
            "transaction completion receipt is not canonical JSON"
        )
    if (
        metadata.mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)
        or not metadata.flags & stat.UF_IMMUTABLE
    ):
        raise EvidenceWrapperError("transaction completion receipt is not immutable")
    marker_payload = canonical_json_bytes(transaction) + b"\n"
    marker = TransactionMarker(
        name=_transaction_marker_name(final_name),
        completion_name=completion_name,
        token=str(transaction["transaction_token"]),
        document=transaction,
        payload=marker_payload,
        metadata=metadata,
    )
    return marker, metadata


def _load_root_marker_from_final(
    parent_descriptor: int,
    *,
    partial_name: str,
    final_name: str,
    failure_name: str,
) -> TransactionMarker | None:
    final_identity = _entry_identity(parent_descriptor, final_name)
    if final_identity is None:
        return None
    descriptor = _open_directory_at(
        parent_descriptor,
        final_name,
        label="completed evidence wrapper",
    )
    try:
        root_marker_identity = _entry_identity(
            descriptor,
            _transaction_root_marker_name(),
        )
        if root_marker_identity is None:
            return None
        metadata, payload = _read_regular_at(
            descriptor,
            _transaction_root_marker_name(),
            relative_path=_transaction_root_marker_name(),
            collect=True,
        )
    finally:
        os.close(descriptor)
    assert payload is not None
    document = _validate_transaction_document(
        _strict_json(payload, label="published transaction marker"),
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
    )
    if (
        payload != canonical_json_bytes(document) + b"\n"
        or (int(document["root_device"]), int(document["root_inode"]))
        != final_identity
    ):
        raise EvidenceWrapperError("published transaction marker differs")
    return TransactionMarker(
        name=_transaction_marker_name(final_name),
        completion_name=_transaction_completion_name(final_name),
        token=str(document["transaction_token"]),
        document=document,
        payload=payload,
        metadata=metadata,
    )


def _remove_cleanup_record_by_payload(
    parent_descriptor: int,
    *,
    name: str,
    expected_payload: bytes,
    token: str,
    completion_marker: TransactionMarker | None = None,
) -> None:
    if _entry_identity(parent_descriptor, name) is None:
        return
    metadata, payload = _read_regular_at(
        parent_descriptor,
        name,
        relative_path=name,
        collect=True,
    )
    assert payload is not None
    if completion_marker is None:
        if payload != expected_payload:
            raise EvidenceWrapperError("active marker cleanup payload differs")
    else:
        document = _strict_json(payload, label="completion cleanup receipt")
        _validate_completion_document(
            document,
            marker_document=completion_marker.document,
        )
        if payload != canonical_json_bytes(document) + b"\n":
            raise EvidenceWrapperError("completion cleanup receipt differs")
    _remove_owned_record(
        parent_descriptor,
        name=name,
        expected_identity=(metadata.device, metadata.inode),
        token=token,
    )


def _remove_interrupted_cleanup_records(
    parent_descriptor: int,
    marker: TransactionMarker,
) -> None:
    active_cleanup = _cleanup_record_name(marker.name, marker.token)
    completion_cleanup = _cleanup_record_name(
        marker.completion_name,
        marker.token,
    )
    _remove_cleanup_record_by_payload(
        parent_descriptor,
        name=active_cleanup,
        expected_payload=marker.payload,
        token=marker.token,
    )
    _remove_cleanup_record_by_payload(
        parent_descriptor,
        name=completion_cleanup,
        expected_payload=b"",
        token=marker.token,
        completion_marker=marker,
    )


def _recover_active_transaction_to_failure(
    parent_descriptor: int,
    *,
    marker: TransactionMarker,
    partial_name: str,
    final_name: str,
    failure_name: str,
    recovery_kind: str,
    error_message: str,
    completion_metadata: FileSnapshot | None = None,
) -> None:
    expected = (
        int(marker.document["root_device"]),
        int(marker.document["root_inode"]),
    )
    names = _names_for_identity(parent_descriptor, expected)
    if not names:
        raise EvidenceWrapperError(
            "stale transaction marker has no discoverable owned root"
        )
    source_name = names[0]
    root_descriptor = _open_directory_at(
        parent_descriptor,
        source_name,
        label="stale owned wrapper root",
    )
    try:
        expected_metadata = os.fstat(root_descriptor)
        actual_failure_name = _preserve_failure_evidence(
            parent_descriptor,
            root_descriptor=root_descriptor,
            expected_identity=expected_metadata,
            marker=marker,
            partial_name=partial_name,
            final_name=final_name,
            failure_name=failure_name,
            recovery_kind=recovery_kind,
            error_type="InterruptedPublication",
            error_message=error_message,
            error_traceback="unavailable after process termination",
        )
    finally:
        os.close(root_descriptor)
    _remove_owned_record(
        parent_descriptor,
        name=marker.name,
        expected_identity=(marker.metadata.device, marker.metadata.inode),
        token=marker.token,
    )
    if completion_metadata is not None:
        _remove_owned_record(
            parent_descriptor,
            name=marker.completion_name,
            expected_identity=(
                completion_metadata.device,
                completion_metadata.inode,
            ),
            token=marker.token,
        )
    raise EvidenceWrapperError(
        f"recovered interrupted evidence wrapper to {actual_failure_name}"
    )


def _promote_relevant_staged_controls(
    parent_descriptor: int,
    *,
    partial_name: str,
    final_name: str,
    failure_name: str,
) -> None:
    pattern = re.compile(
        r"^\.evidence-wrapper-(marker|completion)-([0-9a-f]{32})\.tmp$"
    )
    try:
        names = sorted(os.listdir(parent_descriptor))
    except OSError as error:
        raise EvidenceWrapperError(
            "transaction control staging namespace cannot be enumerated"
        ) from error
    relevant: Dict[str, Tuple[str, FileSnapshot, str]] = {}
    for name in names:
        match = pattern.fullmatch(name)
        if match is None:
            continue
        kind, token = match.groups()
        metadata, payload = _read_regular_at(
            parent_descriptor,
            name,
            relative_path=name,
            collect=True,
        )
        if payload is None:
            raise EvidenceWrapperError(
                "transaction control staging record payload is unavailable"
            )
        document = _strict_json(
            payload,
            label="transaction control staging record",
        )
        transaction = (
            document
            if kind == "marker"
            else document.get("transaction")
            if isinstance(document, dict)
            else None
        )
        if not isinstance(transaction, dict):
            raise EvidenceWrapperError(
                "transaction control staging record is invalid"
            )
        candidate_partial = transaction.get("partial_name")
        candidate_final = transaction.get("final_name")
        candidate_failure = transaction.get("failure_name")
        if not all(
            isinstance(value, str)
            for value in (
                candidate_partial,
                candidate_final,
                candidate_failure,
            )
        ):
            raise EvidenceWrapperError(
                "transaction control staging namespace is invalid"
            )
        if (
            candidate_final in {"", ".", ".."}
            or "/" in candidate_final
            or "\\" in candidate_final
            or "\x00" in candidate_final
            or candidate_partial != f".{candidate_final}.partial"
            or candidate_failure != f"{candidate_final}.failed"
        ):
            raise EvidenceWrapperError(
                "transaction control staging namespace is invalid"
            )
        validated = _validate_transaction_document(
            transaction,
            partial_name=candidate_partial,
            final_name=candidate_final,
            failure_name=candidate_failure,
        )
        if kind == "completion":
            _validate_completion_document(
                document,
                marker_document=validated,
            )
        if payload != canonical_json_bytes(document) + b"\n":
            raise EvidenceWrapperError(
                "transaction control staging record is not canonical JSON"
            )
        if token != validated["transaction_token"]:
            raise EvidenceWrapperError(
                "transaction control staging token differs"
            )
        if metadata.mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise EvidenceWrapperError(
                "transaction control staging record is writable"
            )
        if candidate_final != final_name:
            continue
        _validate_transaction_document(
            validated,
            partial_name=partial_name,
            final_name=final_name,
            failure_name=failure_name,
        )
        if kind in relevant:
            raise EvidenceWrapperError(
                "transaction control staging set is ambiguous"
            )
        relevant[kind] = (name, metadata, token)

    for kind in ("marker", "completion"):
        staged = relevant.get(kind)
        if staged is None:
            continue
        name, metadata, token = staged
        canonical_name = (
            _transaction_marker_name(final_name)
            if kind == "marker"
            else _transaction_completion_name(final_name)
        )
        if _entry_identity(parent_descriptor, canonical_name) is not None:
            raise EvidenceWrapperError(
                "canonical and staged transaction controls coexist"
            )
        expected_identity = (metadata.device, metadata.inode)
        _move_owned_entry(
            parent_descriptor,
            preferred_source_name=name,
            destination_name=canonical_name,
            expected_identity=expected_identity,
            token=token,
            fail_on_substitution=True,
        )
        os.fsync(parent_descriptor)
        if (
            _entry_identity(parent_descriptor, canonical_name)
            != expected_identity
            or _entry_identity(parent_descriptor, name) is not None
        ):
            raise EvidenceWrapperError(
                "transaction control staging promotion changed identity"
            )


def _recover_stale_transaction(
    parent_descriptor: int,
    *,
    partial_name: str,
    final_name: str,
    failure_name: str,
) -> Path | None:
    _promote_relevant_staged_controls(
        parent_descriptor,
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
    )
    marker_name = _transaction_marker_name(final_name)
    completion_name = _transaction_completion_name(final_name)
    marker_identity = _entry_identity(parent_descriptor, marker_name)
    completion_identity = _entry_identity(parent_descriptor, completion_name)
    if marker_identity is None and completion_identity is None:
        marker = _load_root_marker_from_final(
            parent_descriptor,
            partial_name=partial_name,
            final_name=final_name,
            failure_name=failure_name,
        )
        if marker is None:
            return None
        _remove_interrupted_cleanup_records(parent_descriptor, marker)
        _verify_completed_wrapper(
            parent_descriptor,
            final_name=final_name,
            marker=marker,
        )
        return Path(final_name)
    marker: TransactionMarker
    if marker_identity is not None:
        marker = _load_transaction_marker(
            parent_descriptor,
            name=marker_name,
            partial_name=partial_name,
            final_name=final_name,
            failure_name=failure_name,
            require_immutable=False,
        )
        marker_is_immutable = bool(marker.metadata.flags & stat.UF_IMMUTABLE)
        if completion_identity is not None:
            completion_metadata = _load_completion_receipt(
                parent_descriptor,
                marker,
                require_immutable=False,
            )
            completion_is_immutable = bool(
                completion_metadata.flags & stat.UF_IMMUTABLE
            )
            if not marker_is_immutable or not completion_is_immutable:
                _recover_active_transaction_to_failure(
                    parent_descriptor,
                    marker=marker,
                    partial_name=partial_name,
                    final_name=final_name,
                    failure_name=failure_name,
                    recovery_kind="startup_unsealed_control_recovery",
                    error_message=(
                        "an atomically published transaction control record "
                        "remained unsealed"
                    ),
                    completion_metadata=completion_metadata,
                )
            _verify_completed_wrapper(
                parent_descriptor,
                final_name=final_name,
                marker=marker,
            )
            _remove_owned_record(
                parent_descriptor,
                name=marker.name,
                expected_identity=(marker.metadata.device, marker.metadata.inode),
                token=marker.token,
            )
            _remove_owned_record(
                parent_descriptor,
                name=marker.completion_name,
                expected_identity=(
                    completion_metadata.device,
                    completion_metadata.inode,
                ),
                token=marker.token,
            )
            return Path(final_name)
        _recover_active_transaction_to_failure(
            parent_descriptor,
            marker=marker,
            partial_name=partial_name,
            final_name=final_name,
            failure_name=failure_name,
            recovery_kind=(
                "startup_recovery"
                if marker_is_immutable
                else "startup_unsealed_marker_recovery"
            ),
            error_message=(
                "a transaction marker remained without a completion receipt"
            ),
        )

    assert completion_identity is not None
    marker, completion_metadata = _load_completion_without_active(
        parent_descriptor,
        completion_name=completion_name,
        partial_name=partial_name,
        final_name=final_name,
        failure_name=failure_name,
    )
    _verify_completed_wrapper(
        parent_descriptor,
        final_name=final_name,
        marker=marker,
    )
    _remove_interrupted_cleanup_records(parent_descriptor, marker)
    _remove_owned_record(
        parent_descriptor,
        name=completion_name,
        expected_identity=(completion_metadata.device, completion_metadata.inode),
        token=marker.token,
    )
    return Path(final_name)


def _remove_record_if_owned(
    parent_descriptor: int,
    *,
    preferred_name: str,
    metadata: FileSnapshot,
    token: str,
) -> None:
    expected = (metadata.device, metadata.inode)
    names = _names_for_identity(parent_descriptor, expected)
    if not names:
        return
    _remove_owned_record(
        parent_descriptor,
        name=(preferred_name if preferred_name in names else names[0]),
        expected_identity=expected,
        token=token,
    )


def finalize_evidence_wrapper(
    *,
    partial: Path,
    final: Path,
    gate_ids: Sequence[str],
    project_root: Path,
    producer: str | None = None,
    command: str | None = None,
    platform: str | None = None,
    machine: str | None = None,
    provenance_map: Path | None = None,
) -> Path:
    """Validate, seal, publish, and strictly reopen one evidence wrapper."""

    partial = Path(os.path.abspath(partial))
    final = Path(os.path.abspath(final))
    project_root = Path(os.path.abspath(project_root))
    expected_partial = final.parent / f".{final.name}.partial"
    if (
        partial != expected_partial
        or partial.parent != final.parent
        or partial == final
        or final.name in {"", ".", ".."}
        or "/" in final.name
        or "\\" in final.name
        or "\x00" in final.name
    ):
        raise EvidenceWrapperError(
            "partial must be the deterministic .<final-name>.partial sibling"
        )
    failure_name = f"{final.name}.failed"
    default_gate_ids = _validate_gate_ids(gate_ids, label="CLI gate IDs")
    fallback_values = (producer, command, platform, machine)
    if all(value is None for value in fallback_values):
        fallback = None
    elif any(value is None for value in fallback_values):
        raise EvidenceWrapperError(
            "producer, command, platform, and machine must be supplied together "
            "as fallback"
        )
    else:
        fallback = _validate_provenance(
            producer=producer,
            command=command,
            platform=platform,
            machine=machine,
            gate_ids=default_gate_ids,
            label="global fallback provenance",
        )
    if provenance_map is None and fallback is None:
        raise EvidenceWrapperError(
            "a provenance map or explicit global fallback is required"
        )
    parent_identity = _require_canonical_directory(
        final.parent,
        label="artifact parent",
    )
    parent_descriptor = _open_directory(final.parent)
    root_descriptor = -1
    marker: TransactionMarker | None = None
    completion_metadata: FileSnapshot | None = None
    partial_identity: os.stat_result | None = None
    try:
        if _identity(os.fstat(parent_descriptor)) != _identity(parent_identity):
            raise EvidenceWrapperError("artifact parent changed while opening")

        recovered = _recover_stale_transaction(
            parent_descriptor,
            partial_name=partial.name,
            final_name=final.name,
            failure_name=failure_name,
        )
        if recovered is not None:
            return final

        provenance_source = (
            _read_external_regular(provenance_map, label="provenance map")
            if provenance_map is not None
            else None
        )
        if provenance_source is not None and (
            provenance_source.path == partial
            or partial in provenance_source.path.parents
        ):
            raise EvidenceWrapperError(
                "provenance map must remain outside the partial evidence wrapper"
            )
        rules = _load_provenance_rules(
            provenance_source,
            default_gate_ids=default_gate_ids,
        )
        project_identity = _require_canonical_directory(
            project_root,
            label="project root",
        )
        repository_state = _repository_state(project_root)
        partial_identity = _require_canonical_directory(
            partial,
            label="partial artifact root",
        )
        current_partial = _stat_at(
            parent_descriptor,
            partial.name,
            label="partial artifact root",
        )
        if (
            not stat.S_ISDIR(current_partial.st_mode)
            or _identity(current_partial) != _identity(partial_identity)
        ):
            raise EvidenceWrapperError("partial artifact root identity changed")
        _require_absent_at(
            parent_descriptor,
            final.name,
            label="final artifact directory",
        )
        _require_absent_at(
            parent_descriptor,
            failure_name,
            label="failure artifact directory",
        )
        root_descriptor = _open_directory_at(
            parent_descriptor,
            partial.name,
            label="partial artifact root",
        )
        if _identity(os.fstat(root_descriptor)) != _identity(partial_identity):
            raise EvidenceWrapperError("partial artifact changed while opening")

        initial_snapshot = _snapshot_tree(root_descriptor)
        if not initial_snapshot.files:
            raise EvidenceWrapperError("evidence wrapper has no artifact files")
        reserved_paths = {MANIFEST_NAME, _transaction_root_marker_name()}
        if any(item.path in reserved_paths for item in initial_snapshot.files):
            raise EvidenceWrapperError("artifact manifest already exists in partial root")
        resolved_provenance = _resolve_provenance(
            [item.path for item in initial_snapshot.files],
            rules=rules,
            fallback=fallback,
        )

        marker = _create_transaction_marker(
            parent_descriptor,
            project_commit=repository_state.project_commit,
            partial_name=partial.name,
            final_name=final.name,
            failure_name=failure_name,
            root_identity=_identity(partial_identity),
            gate_ids=default_gate_ids,
        )
        _write_new_regular_at(
            root_descriptor,
            _transaction_root_marker_name(),
            marker.payload,
            mode=0o644,
            immutable=False,
        )
        raw_snapshot = _snapshot_tree(root_descriptor)
        observed_initial = TreeSnapshot(
            files=tuple(
                item
                for item in raw_snapshot.files
                if item.path != _transaction_root_marker_name()
            ),
            directories=raw_snapshot.directories,
        )
        _require_snapshot_unchanged(
            initial_snapshot,
            observed_initial,
            require_metadata=False,
        )
        transaction_provenance = _recovery_provenance(marker)
        resolved_provenance = dict(resolved_provenance)
        resolved_provenance[_transaction_root_marker_name()] = (
            transaction_provenance
        )
        manifest = _build_manifest(
            raw_snapshot,
            project_commit=repository_state.project_commit,
            provenance=resolved_provenance,
        )
        _require_snapshot_unchanged(
            raw_snapshot,
            _snapshot_tree(root_descriptor),
            require_metadata=True,
        )
        if provenance_source is not None:
            _require_external_unchanged(provenance_source, label="provenance map")
        _require_repository_unchanged(
            project_root,
            repository_state,
            project_identity,
        )
        _write_new_manifest(
            root_descriptor,
            canonical_json_bytes(manifest) + b"\n",
        )
        closure_snapshot = _verify_tree(
            root_descriptor,
            expected_manifest=manifest,
            expected_identity=partial_identity,
            expected_raw_snapshot=raw_snapshot,
            require_frozen=False,
        )
        _fsync_tree(root_descriptor)
        _seal_descendants(root_descriptor)
        _verify_tree(
            root_descriptor,
            expected_manifest=manifest,
            expected_identity=partial_identity,
            expected_raw_snapshot=raw_snapshot,
            expected_closure_snapshot=closure_snapshot,
            require_frozen=False,
            require_descendants_frozen=True,
        )
        if provenance_source is not None:
            _require_external_unchanged(provenance_source, label="provenance map")
        _require_repository_unchanged(
            project_root,
            repository_state,
            project_identity,
        )
        current_partial = _stat_at(
            parent_descriptor,
            partial.name,
            label="partial artifact root before publication",
        )
        if (
            _identity(current_partial) != _identity(partial_identity)
            or _identity(os.fstat(root_descriptor)) != _identity(partial_identity)
        ):
            raise EvidenceWrapperError(
                "partial artifact root identity changed before publication"
            )
        current_parent = _require_canonical_directory(
            final.parent,
            label="artifact parent",
        )
        if _identity(current_parent) != _identity(parent_identity):
            raise EvidenceWrapperError("artifact parent identity changed")
        _require_absent_at(
            parent_descriptor,
            final.name,
            label="final artifact directory before publication",
        )
        _require_absent_at(
            parent_descriptor,
            failure_name,
            label="failure artifact directory before publication",
        )
        _verify_tree(
            root_descriptor,
            expected_manifest=manifest,
            expected_identity=partial_identity,
            expected_raw_snapshot=raw_snapshot,
            expected_closure_snapshot=closure_snapshot,
            require_frozen=False,
            require_descendants_frozen=True,
        )
        if _entry_identity(parent_descriptor, partial.name) != _identity(
            partial_identity
        ):
            raise EvidenceWrapperError(
                "partial artifact path changed at publication boundary"
            )
        _move_owned_entry(
            parent_descriptor,
            preferred_source_name=partial.name,
            destination_name=final.name,
            expected_identity=_identity(partial_identity),
            token=marker.token,
            fail_on_substitution=True,
        )
        os.fsync(parent_descriptor)
        if _entry_identity(parent_descriptor, final.name) != _identity(partial_identity):
            raise EvidenceWrapperError("published artifact identity changed")
        if _entry_identity(parent_descriptor, partial.name) is not None:
            raise EvidenceWrapperError("partial artifact path reappeared after publication")
        _seal_descriptor(root_descriptor, label="published artifact root")
        os.fsync(parent_descriptor)
        if provenance_source is not None:
            _require_external_unchanged(provenance_source, label="provenance map")
        _require_repository_unchanged(
            project_root,
            repository_state,
            project_identity,
        )

        reopened = _open_directory_at(
            parent_descriptor,
            final.name,
            label="published artifact root",
        )
        try:
            if _identity(os.fstat(reopened)) != _identity(partial_identity):
                raise EvidenceWrapperError(
                    "published artifact identity changed while reopening"
                )
            _verify_tree(
                reopened,
                expected_manifest=manifest,
                expected_identity=partial_identity,
                expected_raw_snapshot=raw_snapshot,
                expected_closure_snapshot=closure_snapshot,
                require_frozen=True,
            )
        finally:
            os.close(reopened)
        if provenance_source is not None:
            _require_external_unchanged(provenance_source, label="provenance map")
        _require_repository_unchanged(
            project_root,
            repository_state,
            project_identity,
        )
        if _entry_identity(parent_descriptor, final.name) != _identity(partial_identity):
            raise EvidenceWrapperError(
                "published artifact path changed after strict reopen"
            )
        current_parent = _require_canonical_directory(
            final.parent,
            label="artifact parent after publication",
        )
        if _identity(current_parent) != _identity(parent_identity):
            raise EvidenceWrapperError("artifact parent changed after publication")

        completion_metadata = _create_completion_receipt(
            parent_descriptor,
            marker,
        )
        _remove_owned_record(
            parent_descriptor,
            name=marker.name,
            expected_identity=(marker.metadata.device, marker.metadata.inode),
            token=marker.token,
        )
        _remove_owned_record(
            parent_descriptor,
            name=marker.completion_name,
            expected_identity=(
                completion_metadata.device,
                completion_metadata.inode,
            ),
            token=marker.token,
        )
        if (
            _entry_identity(parent_descriptor, marker.name) is not None
            or _entry_identity(parent_descriptor, marker.completion_name) is not None
        ):
            raise EvidenceWrapperError(
                "transaction records remain after successful publication"
            )
        return final
    except BaseException as primary:
        if marker is not None and root_descriptor >= 0 and partial_identity is not None:
            try:
                _preserve_failure_evidence(
                    parent_descriptor,
                    root_descriptor=root_descriptor,
                    expected_identity=partial_identity,
                    marker=marker,
                    partial_name=partial.name,
                    final_name=final.name,
                    failure_name=failure_name,
                    recovery_kind="in_process_failure",
                    error_type=type(primary).__name__,
                    error_message=str(primary),
                    error_traceback="".join(
                        traceback.format_exception(
                            type(primary),
                            primary,
                            primary.__traceback__,
                        )
                    ),
                )
                _remove_record_if_owned(
                    parent_descriptor,
                    preferred_name=marker.name,
                    metadata=marker.metadata,
                    token=marker.token,
                )
                if completion_metadata is not None:
                    _remove_record_if_owned(
                        parent_descriptor,
                        preferred_name=marker.completion_name,
                        metadata=completion_metadata,
                        token=marker.token,
                    )
            except BaseException as cleanup:
                try:
                    _seal_descriptor(
                        root_descriptor,
                        label="failed evidence root after cleanup error",
                    )
                except BaseException as reseal:
                    raise EvidenceWrapperError(
                        "evidence wrapper finalization failed; cleanup and "
                        f"reseal failed: {reseal}"
                    ) from primary
                raise EvidenceWrapperError(
                    f"evidence wrapper finalization failed; cleanup failed: {cleanup}"
                ) from primary
        if isinstance(primary, EvidenceWrapperError):
            raise
        raise EvidenceWrapperError("evidence wrapper finalization failed") from primary
    finally:
        if root_descriptor >= 0:
            os.close(root_descriptor)
        os.close(parent_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--partial", type=Path, required=True)
    parser.add_argument("--final", type=Path, required=True)
    parser.add_argument("--gate-id", dest="gate_ids", action="append", required=True)
    parser.add_argument("--producer")
    parser.add_argument("--command")
    parser.add_argument("--platform")
    parser.add_argument("--machine")
    parser.add_argument("--provenance-map", type=Path)
    parser.add_argument("--project-root", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    result = finalize_evidence_wrapper(
        partial=arguments.partial,
        final=arguments.final,
        gate_ids=arguments.gate_ids,
        producer=arguments.producer,
        command=arguments.command,
        platform=arguments.platform,
        machine=arguments.machine,
        provenance_map=arguments.provenance_map,
        project_root=arguments.project_root,
    )
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
