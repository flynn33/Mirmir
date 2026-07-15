#!/usr/bin/env python3
"""Run the preregistered open-development P06 corrective diagnostics."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from typing import Mapping, Sequence
import uuid


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from validation.calibration_v2.corrective_diagnostic_executor import (  # noqa: E402
    COORDINATE_ARTIFACT_NAME,
    ENVELOPE_NAME,
    EXECUTOR_PUBLICATION_RECEIPT_NAME,
    INPUT_SANITATION_RECEIPT_NAME,
    JOURNAL_DIRECTORY_NAME,
    RISK_ARTIFACT_NAME,
    CorrectiveDiagnosticExecutor,
    _rename_directory_exclusive,
)
from validation.calibration_v2.corrective_diagnostics import (  # noqa: E402
    canonical_artifact_file_bytes,
    validate_coordinate_anisotropy_artifact,
    validate_corrective_diagnostic_envelope,
    validate_risk_state_artifact,
)
from validation.calibration_v2.corrective_preregistration import (  # noqa: E402
    validate_corrective_preregistration,
    verify_attempt_ledger_payload,
)
from validation.calibration_v2.g05.gate import (  # noqa: E402
    G05GateError,
    validate_g05_receipt,
)
from validation.calibration_v2.macos_code_identity import (  # noqa: E402
    static_code_identity,
)
from validation.calibration_v2.native_adapter.factory import (  # noqa: E402
    make_native_corrective_diagnostic_capability,
)
from validation.calibration_v2.production_providers import (  # noqa: E402
    production_writer_capability,
)
from validation.calibration_v2.runner import (  # noqa: E402
    LockedDegradationCache,
    bind_preregistered_inputs,
)
from validation.calibration_v2.tools.run_p06_production_calibration import (  # noqa: E402
    _live_holdout_preopen_binding,
)
from validation.quality.src.mirmir_quality.arrays import (  # noqa: E402
    frame_sha256,
)
from validation.quality.src.mirmir_quality.json_tools import (  # noqa: E402
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.samples import (  # noqa: E402
    load_development_samples,
)


_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_EVIDENCE_WRAPPER_MANIFEST_SCHEMA = (
    REPOSITORY_ROOT
    / "validation/calibration_v2/schemas/"
    "evidence-wrapper-artifact-manifest-v2.schema.json"
)


class CorrectiveDiagnosticCLIError(ValueError):
    """The corrective diagnostic CLI rejected an input or failed closed."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CorrectiveDiagnosticCLIError(message)


def _require_sha256(value: object, label: str) -> str:
    _require(
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value),
        f"{label} must be one lowercase SHA-256",
    )
    return str(value)


def _lexical_absolute(path: Path, label: str) -> Path:
    raw = os.fspath(path)
    _require(path.is_absolute(), f"{label} must be absolute")
    _require(
        os.path.normpath(raw) == raw and raw not in {"/", ""},
        f"{label} must be a normalized non-root absolute path",
    )
    return path


def _open_directory_nofollow(path: Path, label: str) -> int:
    absolute = _lexical_absolute(path, label)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(absolute.anchor, flags)
    try:
        for part in absolute.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            metadata = os.fstat(child)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(child)
                raise CorrectiveDiagnosticCLIError(
                    f"{label} traverses a non-directory"
                )
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


class _PinnedDirectory:
    def __init__(self, path: Path, label: str) -> None:
        self.path = _lexical_absolute(path, label)
        self.label = label
        self.descriptor = _open_directory_nofollow(self.path, label)
        metadata = os.fstat(self.descriptor)
        self.identity = (metadata.st_dev, metadata.st_ino)
        self.real_path = self.path.resolve(strict=True)
        _require(
            self.real_path == self.path,
            f"{label} contains a symbolic or aliased path component",
        )
        self.closed = False

    def binding(self) -> Mapping[str, object]:
        return {
            "lexical_path": os.fspath(self.path),
            "real_path": os.fspath(self.real_path),
            "device": self.identity[0],
            "inode": self.identity[1],
        }

    def verify(self) -> None:
        _require(not self.closed, f"{self.label} pin is closed")
        pinned = os.fstat(self.descriptor)
        reopened = _open_directory_nofollow(self.path, self.label)
        try:
            current = os.fstat(reopened)
        finally:
            os.close(reopened)
        _require(
            (pinned.st_dev, pinned.st_ino)
            == (current.st_dev, current.st_ino)
            == self.identity,
            f"{self.label} identity changed",
        )

    def close(self) -> None:
        if not self.closed:
            os.close(self.descriptor)
            self.closed = True


@dataclass(frozen=True)
class _RegularSnapshot:
    path: Path
    payload: bytes
    device: int
    inode: int
    size_bytes: int
    mtime_ns: int
    ctime_ns: int
    file_sha256: str

    @classmethod
    def capture(cls, path: Path, label: str) -> "_RegularSnapshot":
        absolute = _lexical_absolute(path, label)
        parent = _PinnedDirectory(absolute.parent, f"{label} parent")
        try:
            before = os.stat(
                absolute.name,
                dir_fd=parent.descriptor,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISREG(before.st_mode),
                f"{label} is not a regular file",
            )
            descriptor = os.open(
                absolute.name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent.descriptor,
            )
            try:
                opened = os.fstat(descriptor)
                _require(
                    (opened.st_dev, opened.st_ino)
                    == (before.st_dev, before.st_ino),
                    f"{label} changed while opening",
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
            final = os.stat(
                absolute.name,
                dir_fd=parent.descriptor,
                follow_symlinks=False,
            )
        finally:
            parent.close()
        stable = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        _require(
            stable(before) == stable(opened) == stable(after) == stable(final),
            f"{label} changed while reading",
        )
        payload = b"".join(chunks)
        _require(len(payload) == before.st_size, f"{label} read was truncated")
        return cls(
            path=absolute,
            payload=payload,
            device=before.st_dev,
            inode=before.st_ino,
            size_bytes=before.st_size,
            mtime_ns=before.st_mtime_ns,
            ctime_ns=before.st_ctime_ns,
            file_sha256=hashlib.sha256(payload).hexdigest(),
        )

    def binding(self) -> Mapping[str, object]:
        return {
            "lexical_path": os.fspath(self.path),
            "file_sha256": self.file_sha256,
            "size_bytes": self.size_bytes,
            "device": self.device,
            "inode": self.inode,
        }

    def verify(self, label: str) -> None:
        current = type(self).capture(self.path, label)
        _require(current == self, f"{label} changed after binding")


class _EphemeralLockedDegradationCache(LockedDegradationCache):
    """One-run cache whose in-memory pixels are explicitly discarded."""

    def __init__(self, degradation_policy_sha256: str) -> None:
        super().__init__(degradation_policy_sha256)
        self.closed = False

    def close(self) -> None:
        if not self.closed:
            self._frames.clear()
            self._hashes.clear()
            self.closed = True


def _strict_json_object(payload: bytes, label: str) -> Mapping[str, object]:
    def pairs(values: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in values:
            if key in result:
                raise CorrectiveDiagnosticCLIError(
                    f"{label} contains duplicate JSON key: {key}"
                )
            result[key] = value
        return result

    def constant(token: str) -> object:
        raise CorrectiveDiagnosticCLIError(
            f"{label} contains non-finite JSON number: {token}"
        )

    try:
        value = json.loads(
            payload,
            object_pairs_hook=pairs,
            parse_constant=constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorrectiveDiagnosticCLIError(f"{label} is not valid JSON") from error
    _require(isinstance(value, dict), f"{label} is not a JSON object")
    return value


def _fresh_unopened_guard(binding: object) -> Mapping[str, object]:
    verify = getattr(binding, "verify", None)
    _require(callable(verify), "live holdout binding has no verifier")
    value = verify()
    _require(
        isinstance(value, Mapping)
        and value.get("verification_status") == "pass"
        and value.get("access_status") == "unopened"
        and value.get("access_count") == 0
        and value.get("open_intent_anchor_present") is False
        and value.get("pixel_content_included") is False,
        "live holdout guard does not prove unopened zero-access state",
    )
    return json.loads(canonical_json_bytes(value))


def _run_git(repository_root: Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["/usr/bin/git", "-C", os.fspath(repository_root), *arguments],
        check=False,
        capture_output=True,
        env={
            "HOME": "/var/empty",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        },
    )
    _require(
        completed.returncode == 0,
        "repository Git state could not be bound: "
        + completed.stderr.decode("utf-8", errors="replace"),
    )
    return completed.stdout


def _repository_binding(root: _PinnedDirectory) -> Mapping[str, object]:
    head = _run_git(root.path, "rev-parse", "--verify", "HEAD").strip().decode()
    index_tree = _run_git(
        root.path,
        "rev-parse",
        "--verify",
        "HEAD^{tree}",
    ).strip().decode()
    _require(
        re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", head) is not None
        and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", index_tree)
        is not None,
        "repository Git object identity is invalid",
    )
    status_payload = _run_git(
        root.path,
        "status",
        "--porcelain=v2",
        "-z",
        "--untracked-files=no",
    )
    _require(
        status_payload == b"",
        "repository has tracked modifications; corrective pixel loading requires a clean tracked tree",
    )
    manifest: list[Mapping[str, object]] = []
    return {
        "root": root.binding(),
        "git_head_commit": head,
        "git_index_tree": index_tree,
        "tracked_status_sha256": hashlib.sha256(status_payload).hexdigest(),
        "tracked_status_size_bytes": len(status_payload),
        "modified_tracked_file_count": len(manifest),
        "modified_tracked_manifest_sha256": canonical_sha256(manifest),
    }


def _descendant_file(
    root: _PinnedDirectory,
    path: Path,
    label: str,
    expected_sha256: str,
) -> _RegularSnapshot:
    absolute = _lexical_absolute(path, label)
    try:
        absolute.relative_to(root.path)
    except ValueError as error:
        raise CorrectiveDiagnosticCLIError(
            f"{label} is outside its declared artifact root"
        ) from error
    snapshot = _RegularSnapshot.capture(absolute, label)
    _require(
        snapshot.file_sha256 == _require_sha256(expected_sha256, label),
        f"{label} differs from its explicit expected hash",
    )
    return snapshot


def _archive_closure(
    *,
    failed_root: _PinnedDirectory,
    records: Sequence[Mapping[str, object]],
    core_files: Mapping[str, _RegularSnapshot],
) -> tuple[Mapping[str, object], tuple[tuple[_RegularSnapshot, str], ...]]:
    """Reopen every JSON file referenced by the archived attempt chain."""

    cache: dict[str, _RegularSnapshot] = {}
    expected_by_path: dict[str, tuple[str, int]] = {}
    unique_snapshots: list[tuple[_RegularSnapshot, str]] = []
    references = []
    evaluation_paths: set[str] = set()
    control_paths: set[str] = set()

    def capture(
        binding: object,
        *,
        kind: str,
        sequence: int,
        ordinal: int,
    ) -> None:
        _require(isinstance(binding, Mapping), "archive reference is not an object")
        relative_value = binding.get("path")
        expected_sha256 = binding.get("sha256")
        expected_size = binding.get("size_bytes")
        _require(
            isinstance(relative_value, str)
            and isinstance(expected_size, int)
            and not isinstance(expected_size, bool)
            and expected_size > 0,
            "archive reference path or size is invalid",
        )
        _require_sha256(expected_sha256, "archive reference")
        relative = PurePosixPath(relative_value)
        _require(
            relative.as_posix() == relative_value
            and not relative.is_absolute()
            and relative.suffix == ".json"
            and all(part not in {"", ".", ".."} for part in relative.parts),
            "archive reference is not a safe relative JSON path",
        )
        expected = (str(expected_sha256), expected_size)
        prior = expected_by_path.get(relative_value)
        _require(
            prior is None or prior == expected,
            "archive path has inconsistent ledger bindings",
        )
        expected_by_path[relative_value] = expected
        if relative_value not in cache:
            path = failed_root.path.joinpath(*relative.parts)
            snapshot = _RegularSnapshot.capture(path, f"archived {kind} evidence")
            _require(
                snapshot.file_sha256 == expected_sha256
                and snapshot.size_bytes == expected_size,
                "archived evidence differs from its ledger binding",
            )
            document = _strict_json_object(
                snapshot.payload,
                f"archived {kind} evidence",
            )
            _require(
                snapshot.payload == canonical_json_bytes(document),
                "archived referenced evidence is not canonical JSON",
            )
            cache[relative_value] = snapshot
            unique_snapshots.append((snapshot, f"archived {kind} evidence"))
        references.append(
            {
                "sequence": sequence,
                "kind": kind,
                "ordinal": ordinal,
                "path": relative_value,
                "sha256": expected_sha256,
                "size_bytes": expected_size,
            }
        )
        (evaluation_paths if kind == "evaluation" else control_paths).add(
            relative_value
        )

    for sequence, record in enumerate(records):
        evaluation = record.get("evaluation")
        if evaluation is not None:
            capture(
                evaluation,
                kind="evaluation",
                sequence=sequence,
                ordinal=0,
            )
        controls = record.get("control_selection_artifacts", [])
        _require(isinstance(controls, list), "archive control bindings are invalid")
        for ordinal, control in enumerate(controls):
            capture(
                control,
                kind="control",
                sequence=sequence,
                ordinal=ordinal,
            )

    core_manifest = [
        {
            "kind": kind,
            "path": os.fspath(snapshot.path.relative_to(failed_root.path)),
            "sha256": snapshot.file_sha256,
            "size_bytes": snapshot.size_bytes,
        }
        for kind, snapshot in sorted(core_files.items())
    ]
    closure = {
        "attempt_count": len(records),
        "tail_record_sha256": records[-1]["record_sha256"],
        "core_files": core_manifest,
        "references": references,
        "referenced_binding_count": len(references),
        "unique_evaluation_file_count": len(evaluation_paths),
        "unique_control_file_count": len(control_paths),
    }
    return (
        {
            "referenced_binding_count": len(references),
            "unique_evaluation_file_count": len(evaluation_paths),
            "unique_control_file_count": len(control_paths),
            "archive_closure_manifest_sha256": canonical_sha256(closure),
        },
        tuple(unique_snapshots),
    )


def _validate_finalized_gate_manifest(
    *,
    gate_id: str,
    root: _PinnedDirectory,
    manifest_document: Mapping[str, object],
    manifest_payload: bytes,
    expected_source_commit: str,
) -> _RegularSnapshot:
    _require(
        gate_id != "G05" or not root.path.name.endswith(".failed"),
        "G05 artifact root is a failure namespace",
    )
    try:
        validate_schema(manifest_document, _EVIDENCE_WRAPPER_MANIFEST_SCHEMA)
    except ValueError as error:
        raise CorrectiveDiagnosticCLIError(
            f"{gate_id} artifact manifest schema validation failed: {error}"
        ) from error
    _require(
        manifest_payload == canonical_json_bytes(manifest_document) + b"\n",
        f"{gate_id} artifact manifest v2 is not canonical JSON",
    )
    rows = manifest_document.get("artifacts")
    directories = manifest_document.get("directories")
    _require(
        isinstance(rows, list)
        and [row.get("path") for row in rows if isinstance(row, Mapping)]
        == sorted(row["path"] for row in rows if isinstance(row, Mapping))
        and len({row["path"] for row in rows if isinstance(row, Mapping)})
        == len(rows)
        and isinstance(directories, list)
        and directories == sorted(directories),
        f"{gate_id} artifact manifest closure order or uniqueness differs",
    )
    transaction_rows = [
        row
        for row in rows
        if isinstance(row, Mapping)
        and row.get("path") == "publication-transaction.json"
    ]
    expected_gate_ids = ["G04"] if gate_id == "G04" else ["G05", "P05"]
    _require(
        len(transaction_rows) == 1
        and transaction_rows[0].get("gate_ids") == expected_gate_ids,
        f"{gate_id} artifact manifest lacks its exact publication transaction",
    )
    transaction_row = transaction_rows[0]
    transaction = _descendant_file(
        root,
        root.path / "publication-transaction.json",
        f"{gate_id} publication transaction",
        _require_sha256(
            transaction_row.get("sha256"),
            f"{gate_id} publication transaction",
        ),
    )
    _require(
        transaction.size_bytes == transaction_row.get("size_bytes"),
        f"{gate_id} publication transaction size differs",
    )
    document = _strict_json_object(
        transaction.payload,
        f"{gate_id} publication transaction",
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
    _require(
        set(document) == required
        and transaction.payload == canonical_json_bytes(document) + b"\n"
        and document.get("schema_version") == "1.0.0"
        and document.get("artifact_kind")
        == "evidence_wrapper_publication_transaction"
        and isinstance(document.get("transaction_token"), str)
        and re.fullmatch(r"[0-9a-f]{32}", str(document["transaction_token"]))
        is not None
        and isinstance(document.get("created_utc"), str)
        and re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:"
            r"[0-9]{2}(?:\.[0-9]{1,6})?Z",
            str(document["created_utc"]),
        )
        is not None
        and document.get("project_commit") == expected_source_commit
        and document.get("partial_name") == f".{root.path.name}.partial"
        and document.get("final_name") == root.path.name
        and document.get("failure_name") == f"{root.path.name}.failed"
        and document.get("gate_ids") == expected_gate_ids
        and type(document.get("root_device")) is int
        and document["root_device"] >= 0
        and type(document.get("root_inode")) is int
        and document.get("root_inode") == root.identity[1],
        f"{gate_id} publication transaction identity or root differs",
    )
    return transaction


def _validate_finalized_manifest_tree_closure(
    *,
    gate_id: str,
    root: _PinnedDirectory,
    manifest: _RegularSnapshot,
    manifest_document: Mapping[str, object],
) -> None:
    _require(
        manifest.path == root.path / "artifact-manifest.json",
        f"{gate_id} manifest is not the canonical artifact-root manifest",
    )
    rows = manifest_document.get("artifacts")
    directories = manifest_document.get("directories")
    _require(
        isinstance(rows, list) and isinstance(directories, list),
        f"{gate_id} manifest closure is absent",
    )
    expected_files = sorted(
        ("artifact-manifest.json", *(str(row["path"]) for row in rows))
    )
    _require(
        len(expected_files) == len(set(expected_files))
        and "artifact-manifest.json"
        not in {str(row["path"]) for row in rows},
        f"{gate_id} manifest file closure is ambiguous",
    )
    actual_files: list[str] = []
    actual_directories: list[str] = []
    root.verify()
    for current_name, child_directories, child_files in os.walk(
        root.path,
        topdown=True,
        followlinks=False,
    ):
        current = Path(current_name)
        _require(
            current.resolve(strict=True) == current,
            f"{gate_id} wrapper contains a linked directory",
        )
        child_directories.sort()
        child_files.sort()
        for name in child_directories:
            path = current / name
            metadata = os.lstat(path)
            _require(
                stat.S_ISDIR(metadata.st_mode)
                and not stat.S_ISLNK(metadata.st_mode),
                f"{gate_id} wrapper directory closure contains a non-directory",
            )
            actual_directories.append(path.relative_to(root.path).as_posix())
        for name in child_files:
            path = current / name
            metadata = os.lstat(path)
            _require(
                stat.S_ISREG(metadata.st_mode)
                and not stat.S_ISLNK(metadata.st_mode)
                and metadata.st_nlink == 1,
                f"{gate_id} wrapper file closure contains a linked file",
            )
            actual_files.append(path.relative_to(root.path).as_posix())
    _require(
        sorted(actual_files) == expected_files
        and sorted(actual_directories) == list(directories),
        f"{gate_id} finalized manifest tree closure differs",
    )
    for index, row in enumerate(rows):
        relative = PurePosixPath(str(row["path"]))
        snapshot = _RegularSnapshot.capture(
            root.path.joinpath(*relative.parts),
            f"{gate_id} manifest artifact {index}",
        )
        _require(
            snapshot.file_sha256 == row.get("sha256")
            and snapshot.size_bytes == row.get("size_bytes"),
            f"{gate_id} manifest artifact {index} bytes differ",
        )
    manifest.verify(f"{gate_id} artifact manifest")
    root.verify()


def _validate_gate_semantics(
    *,
    gate_id: str,
    root: _PinnedDirectory,
    manifest: _RegularSnapshot,
    receipt: _RegularSnapshot,
    report: _RegularSnapshot,
    expected_source_commit: str,
) -> tuple[_RegularSnapshot, ...]:
    manifest_document = _strict_json_object(
        manifest.payload,
        f"{gate_id} artifact manifest",
    )
    receipt_document = _strict_json_object(
        receipt.payload,
        f"{gate_id} test receipt",
    )
    _require(
        manifest_document.get("schema_version") == "2.0.0"
        and manifest_document.get("working_tree_clean") is True
        and isinstance(manifest_document.get("project_commit"), str)
        and manifest_document.get("project_commit") == expected_source_commit
        and re.fullmatch(
            r"(?:[0-9a-f]{40}|[0-9a-f]{64})",
            str(manifest_document.get("project_commit")),
        )
        is not None
        and isinstance(manifest_document.get("artifacts"), list),
        f"{gate_id} artifact manifest identity is invalid",
    )
    transaction_snapshot = _validate_finalized_gate_manifest(
        gate_id=gate_id,
        root=root,
        manifest_document=manifest_document,
        manifest_payload=manifest.payload,
        expected_source_commit=expected_source_commit,
    )
    entries = manifest_document["artifacts"]
    by_path = {
        row.get("path"): row
        for row in entries
        if isinstance(row, Mapping) and isinstance(row.get("path"), str)
    }
    _require(len(by_path) == len(entries), f"{gate_id} manifest paths are ambiguous")
    for snapshot, label in ((receipt, "receipt"), (report, "report")):
        relative = snapshot.path.relative_to(root.path).as_posix()
        row = by_path.get(relative)
        _require(
            isinstance(row, Mapping)
            and row.get("sha256") == snapshot.file_sha256
            and row.get("size_bytes") == snapshot.size_bytes
            and isinstance(row.get("gate_ids"), list)
            and gate_id in row["gate_ids"],
            f"{gate_id} {label} is not exact in its artifact manifest",
        )

    statuses = []

    def visit(value: object) -> None:
        if isinstance(value, Mapping):
            for key, child in value.items():
                if key == "status":
                    statuses.append(child)
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(receipt_document)
    _require(
        receipt_document.get("schema_version") == "1.0.0"
        and receipt_document.get("status") == "pass"
        and statuses
        and all(status == "pass" for status in statuses)
        and receipt_document.get("source_commit")
        == manifest_document["project_commit"]
        == expected_source_commit
        and receipt_document.get("holdout_accessed") is False,
        f"{gate_id} receipt does not prove an all-pass holdout-free gate",
    )
    bound_snapshots: list[_RegularSnapshot] = [transaction_snapshot]
    if gate_id == "G05":
        _require(
            receipt_document.get("gate") == "G05"
            and receipt_document.get("phase") == "P05",
            "G05 receipt gate or phase identity differs",
        )
        def bound_json(binding_name: str, label: str) -> Mapping[str, object]:
            binding = receipt_document.get(binding_name)
            _require(
                isinstance(binding, Mapping)
                and set(binding) == {"path", "sha256", "size_bytes"},
                f"G05 {label} binding is invalid",
            )
            relative_value = binding.get("path")
            expected_size = binding.get("size_bytes")
            _require(
                isinstance(relative_value, str)
                and isinstance(expected_size, int)
                and not isinstance(expected_size, bool)
                and expected_size > 0,
                f"G05 {label} binding path or size is invalid",
            )
            relative = PurePosixPath(relative_value)
            _require(
                relative.as_posix() == relative_value
                and not relative.is_absolute()
                and relative.suffix == ".json"
                and all(part not in {"", ".", ".."} for part in relative.parts),
                f"G05 {label} binding path is unsafe",
            )
            expected_sha256 = _require_sha256(
                binding.get("sha256"),
                f"G05 {label} binding",
            )
            snapshot = _descendant_file(
                root,
                root.path.joinpath(*relative.parts),
                f"G05 {label}",
                expected_sha256,
            )
            _require(
                snapshot.size_bytes == expected_size,
                f"G05 {label} binding size differs",
            )
            row = by_path.get(relative_value)
            _require(
                isinstance(row, Mapping)
                and row.get("sha256") == snapshot.file_sha256
                and row.get("size_bytes") == snapshot.size_bytes
                and isinstance(row.get("gate_ids"), list)
                and {"G05", "P05"}.issubset(set(row["gate_ids"])),
                f"G05 {label} is not exact in its artifact manifest",
            )
            document = _strict_json_object(snapshot.payload, f"G05 {label}")
            _require(
                snapshot.payload == canonical_json_bytes(document) + b"\n",
                f"G05 {label} is not canonical JSON",
            )
            bound_snapshots.append(snapshot)
            return document

        finding_register = bound_json("finding_register", "finding register")
        finding_self_hash = finding_register.get("register_sha256")
        finding_material = dict(finding_register)
        finding_material.pop("register_sha256", None)
        open_counts = finding_register.get("open_counts")
        findings = finding_register.get("findings")
        _require(
            finding_register.get("schema_version") == "2.0.0"
            and finding_register.get("source_commit") == expected_source_commit
            and finding_register.get("review_status") == "pass"
            and isinstance(open_counts, Mapping)
            and open_counts.get("severity_1") == 0
            and open_counts.get("severity_2") == 0
            and isinstance(findings, list)
            and (
                "total" not in open_counts
                or open_counts.get("total") == len(findings)
            )
            and not any(
                isinstance(finding, Mapping)
                and finding.get("status") == "open"
                and finding.get("severity") in {1, 2}
                for finding in findings
            )
            and finding_self_hash == canonical_sha256(finding_material),
            "G05 finding register does not prove a closed current-source review",
        )

        assessment = bound_json("assessment", "gate assessment")
        criteria = assessment.get("mandatory_criteria")
        _require(
            assessment.get("schema_version") == "2.0.0"
            and assessment.get("gate_id") == "G05"
            and assessment.get("phase") == "P05"
            and assessment.get("source_commit") == expected_source_commit
            and assessment.get("status") == "pass"
            and assessment.get("holdout_accessed") is False
            and assessment.get("finding_register_sha256") == finding_self_hash
            and isinstance(criteria, list)
            and len(criteria) == 8
            and all(
                isinstance(criterion, Mapping)
                and criterion.get("status") == "pass"
                for criterion in criteria
            ),
            "G05 assessment does not prove all current-source criteria",
        )
        upstream_bindings = bound_json("upstream_bindings", "upstream bindings")
        command_execution = bound_json(
            "command_execution",
            "command execution aggregate",
        )
        _require(
            receipt.payload == canonical_json_bytes(receipt_document) + b"\n",
            "G05 receipt is not canonical JSON",
        )
        try:
            validated = validate_g05_receipt(
                repository_root=REPOSITORY_ROOT,
                wrapper_root=root.path,
                receipt=receipt_document,
            )
        except G05GateError as error:
            raise CorrectiveDiagnosticCLIError(
                f"G05 receipt-bound document validation failed: {error}"
            ) from error
        _require(
            validated.assessment == assessment
            and validated.finding_register == finding_register
            and validated.upstream_bindings == upstream_bindings
            and validated.command_execution_aggregate == command_execution,
            "G05 independently validated receipt documents differ",
        )
        snapshots_by_relative = {
            snapshot.path.relative_to(root.path).as_posix(): snapshot
            for snapshot in bound_snapshots
        }
        for index, relative_value in enumerate(validated.reopened_relative_paths):
            if relative_value in snapshots_by_relative:
                continue
            relative = PurePosixPath(relative_value)
            _require(
                relative.as_posix() == relative_value
                and not relative.is_absolute()
                and all(part not in {"", ".", ".."} for part in relative.parts),
                f"G05 reopened evidence path {index} is unsafe",
            )
            row = by_path.get(relative_value)
            execution_stream = (
                relative_value.startswith("outputs/")
                and relative_value.endswith(".log")
            )
            _require(
                isinstance(row, Mapping)
                and type(row.get("size_bytes")) is int
                and (
                    row["size_bytes"] >= 0
                    if execution_stream
                    else row["size_bytes"] > 0
                )
                and isinstance(row.get("gate_ids"), list)
                and {"G05", "P05"}.issubset(set(row["gate_ids"])),
                f"G05 reopened evidence is absent from its artifact manifest: {relative_value}",
            )
            snapshot = _descendant_file(
                root,
                root.path.joinpath(*relative.parts),
                f"G05 reopened evidence {index}",
                _require_sha256(row.get("sha256"), f"G05 reopened evidence {index}"),
            )
            _require(
                snapshot.size_bytes == row["size_bytes"],
                f"G05 reopened evidence size differs: {relative_value}",
            )
            snapshots_by_relative[relative_value] = snapshot
            bound_snapshots.append(snapshot)
        expected_snapshot_paths = {
            *validated.reopened_relative_paths,
            "publication-transaction.json",
        }
        _require(
            len(snapshots_by_relative) == len(expected_snapshot_paths)
            and set(snapshots_by_relative) == expected_snapshot_paths,
            "G05 P06 snapshot closure differs from receipt validation",
        )
    try:
        report_text = report.payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CorrectiveDiagnosticCLIError(
            f"{gate_id} report is not UTF-8"
        ) from error
    _require(
        f"# {gate_id} " in report_text
        and "## Result: pass" in report_text
        and f"All {gate_id} criteria pass." in report_text,
        f"{gate_id} report does not state the exact passing result and criteria",
    )
    _validate_finalized_manifest_tree_closure(
        gate_id=gate_id,
        root=root,
        manifest=manifest,
        manifest_document=manifest_document,
    )
    return tuple(bound_snapshots)


def _require_distinct_roots(paths: Sequence[Path]) -> None:
    normalized = [_lexical_absolute(path, "execution root") for path in paths]
    for index, left in enumerate(normalized):
        for right in normalized[index + 1 :]:
            _require(
                left != right and left not in right.parents and right not in left.parents,
                "output, work, native-cache, and writer roots must be distinct and non-nested",
            )


def _live_binding_document(
    arguments: argparse.Namespace,
    fresh: Mapping[str, object],
) -> Mapping[str, object]:
    return {
        "live_ledger_path": os.fspath(
            _lexical_absolute(arguments.live_ledger_path, "live ledger path")
        ),
        "live_anchor_path": os.fspath(
            _lexical_absolute(arguments.live_anchor_path, "live anchor path")
        ),
        "live_preopen_receipt_path": os.fspath(
            _lexical_absolute(
                arguments.live_preopen_receipt_path,
                "live preopen receipt path",
            )
        ),
        "repository_sealed_copy_path": os.fspath(
            _lexical_absolute(
                arguments.repository_sealed_copy_path,
                "repository sealed-copy path",
            )
        ),
        "repository_attestation_path": os.fspath(
            _lexical_absolute(
                arguments.repository_attestation_path,
                "repository attestation path",
            )
        ),
        "expected_live_ledger_root_identity_sha256": _require_sha256(
            arguments.expected_live_ledger_root_identity_sha256,
            "expected live ledger-root identity",
        ),
        "expected_live_anchor_root_identity_sha256": _require_sha256(
            arguments.expected_live_anchor_root_identity_sha256,
            "expected live anchor-root identity",
        ),
        "expected_live_preopen_receipt_sha256": _require_sha256(
            arguments.expected_live_preopen_receipt_sha256,
            "expected live preopen receipt",
        ),
        "expected_repository_sealed_copy_sha256": _require_sha256(
            arguments.expected_repository_sealed_copy_sha256,
            "expected repository sealed copy",
        ),
        "expected_repository_attestation_sha256": _require_sha256(
            arguments.expected_repository_attestation_sha256,
            "expected repository attestation",
        ),
        "fresh_verification": json.loads(canonical_json_bytes(fresh)),
        "fresh_verification_sha256": canonical_sha256(fresh),
    }


def _runtime_binding(
    *,
    native: object,
    writer: object,
    bound: object,
    coordinate: _RegularSnapshot,
    coordinate_document: Mapping[str, object],
    video: _RegularSnapshot,
    video_document: Mapping[str, object],
) -> Mapping[str, object]:
    configuration = getattr(native, "configuration", None)
    executable = getattr(native, "executable", None)
    executable_path = getattr(executable, "path", None)
    _require(
        isinstance(configuration, Mapping)
        and isinstance(configuration.get("swift_cli"), Mapping)
        and isinstance(executable_path, Path),
        "native corrective identity is incomplete",
    )
    swift_cli = configuration["swift_cli"]
    writer_executable = getattr(writer, "_executable", None)
    writer_settings = getattr(writer, "_settings", None)
    writer_settings_sha256 = getattr(writer, "settings_sha256", None)
    _require(
        isinstance(writer_executable, Path)
        and isinstance(writer_settings, Mapping)
        and isinstance(writer_settings_sha256, str),
        "production writer identity is incomplete",
    )
    documents = getattr(bound, "documents", None)
    record = getattr(bound, "record", None)
    _require(
        isinstance(documents, Mapping) and callable(record),
        "bound implementation identity is incomplete",
    )
    quality = documents["quality_harness_implementation_manifest"]
    metric = documents["metric_policy_seed"]
    quality_file_sha256 = record("quality_harness_implementation_manifest")[
        "sha256"
    ]
    metric_file_sha256 = record("metric_policy_seed")["sha256"]
    metric_identity = {
        "quality_harness_implementation_manifest_file_sha256": quality_file_sha256,
        "quality_harness_implementation_manifest_sha256": quality[
            "manifest_sha256"
        ],
        "metric_policy_file_sha256": metric_file_sha256,
        "metric_policy_sha256": metric["policy_sha256"],
    }
    native_code_identity = static_code_identity(executable_path)
    writer_code_identity = static_code_identity(writer_executable)
    return {
        "native_executable_sha256": swift_cli["executable_sha256"],
        "native_source_manifest_sha256": swift_cli["source_manifest_sha256"],
        "native_code_identity_sha256": canonical_sha256(native_code_identity),
        "native_configuration_sha256": canonical_sha256(configuration),
        "writer_executable_sha256": writer_settings["executable_sha256"],
        "writer_product_settings_source_sha256": writer_settings[
            "product_settings_source_sha256"
        ],
        "writer_settings_sha256": writer_settings_sha256,
        "writer_code_identity_sha256": canonical_sha256(writer_code_identity),
        "coordinate_model_contract_file_sha256": coordinate.file_sha256,
        "coordinate_model_contract_sha256": canonical_sha256(
            coordinate_document
        ),
        "video_profile_contract_file_sha256": video.file_sha256,
        "video_profile_contract_sha256": canonical_sha256(video_document),
        **metric_identity,
        "metric_implementation_binding_sha256": canonical_sha256(
            metric_identity
        ),
    }


_JOURNAL_GENESIS_SHA256 = hashlib.sha256(
    b"MIRMIR-P06-CORRECTIVE-DIAGNOSTIC-JOURNAL-V1\0"
).hexdigest()
_EMPTY_FILE_SHA256 = hashlib.sha256(b"").hexdigest()


def _manifest_row(
    snapshot: _RegularSnapshot,
    *,
    relative_path: str,
) -> Mapping[str, object]:
    return {
        "relative_path": relative_path,
        "file_sha256": snapshot.file_sha256,
        "size_bytes": snapshot.size_bytes,
        "device": snapshot.device,
        "inode": snapshot.inode,
    }


def _private_directory_metadata(
    directory: _PinnedDirectory,
    label: str,
) -> os.stat_result:
    metadata = os.fstat(directory.descriptor)
    _require(
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) == 0o700,
        f"{label} is not an owner-private directory",
    )
    return metadata


def _native_original_output_manifest(
    native_record: Mapping[str, object],
    *,
    request_ordinal: int,
) -> list[dict[str, object]]:
    """Independently derive one call's exact active-row NV12 output manifest."""

    request = native_record.get("request")
    response = native_record.get("response")
    _require(
        isinstance(request, Mapping) and isinstance(response, Mapping),
        f"native record {request_ordinal} request or response is absent",
    )
    frame = request.get("frame")
    descriptors = request.get("output_descriptors")
    diagnostic = response.get("corrective_diagnostic")
    _require(
        isinstance(frame, Mapping)
        and frame.get("pixel_format") == "420v"
        and isinstance(descriptors, list)
        and len(descriptors) == 16
        and isinstance(diagnostic, Mapping),
        f"native record {request_ordinal} output contract differs",
    )
    width = frame.get("output_width")
    height = frame.get("output_height")
    _require(
        isinstance(width, int)
        and not isinstance(width, bool)
        and width > 0
        and width % 2 == 0
        and isinstance(height, int)
        and not isinstance(height, bool)
        and height > 0
        and height % 2 == 0,
        f"native record {request_ordinal} 420v geometry differs",
    )
    output_size_bytes = (
        width * height
        + (width // 2) * (height // 2) * 2
    )
    cells = diagnostic.get("cells")
    production = diagnostic.get("production_v2_reference")
    _require(
        isinstance(cells, list)
        and len(cells) == 16
        and isinstance(production, Mapping),
        f"native record {request_ordinal} output evidence differs",
    )
    manifest: list[dict[str, object]] = []
    for descriptor, cell in zip(descriptors, cells):
        _require(
            isinstance(descriptor, Mapping)
            and isinstance(cell, Mapping)
            and descriptor.get("output_path") == cell.get("output_path"),
            f"native record {request_ordinal} cell output binding differs",
        )
        output_path = descriptor["output_path"]
        _require(
            isinstance(output_path, str)
            and Path(output_path).is_absolute(),
            f"native record {request_ordinal} cell output path differs",
        )
        manifest.append(
            {
                "original_name": Path(output_path).name,
                "sha256": _require_sha256(
                    cell.get("output_nv12_sha256"),
                    f"native record {request_ordinal} cell output",
                ),
                "size_bytes": output_size_bytes,
            }
        )
    production_path = request.get("production_v2_reference_output_path")
    _require(
        isinstance(production_path, str)
        and Path(production_path).is_absolute()
        and production.get("output_path") == production_path,
        f"native record {request_ordinal} production output binding differs",
    )
    manifest.append(
        {
            "original_name": Path(production_path).name,
            "sha256": _require_sha256(
                production.get("output_nv12_sha256"),
                f"native record {request_ordinal} production output",
            ),
            "size_bytes": output_size_bytes,
        }
    )
    manifest.sort(key=lambda row: str(row["original_name"]))
    _require(
        len(manifest) == 17
        and len({str(row["original_name"]) for row in manifest}) == 17,
        f"native record {request_ordinal} output names repeat",
    )
    return manifest


def _validate_native_sanitation_receipt(
    value: object,
    *,
    request_ordinal: int,
    expected_original_output_manifest: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    required = {
        "status",
        "retained_transaction_path",
        "retained_transaction_identity",
        "retained_stub_count",
        "retained_stubs",
        "retained_stub_manifest_sha256",
        "original_output_manifest_sha256",
    }
    _require(
        isinstance(value, Mapping) and set(value) == required,
        f"native sanitation receipt {request_ordinal} field set differs",
    )
    identity = value["retained_transaction_identity"]
    stubs = value["retained_stubs"]
    path_value = value["retained_transaction_path"]
    _require(
        value["status"] == "sanitized_retained"
        and isinstance(path_value, str)
        and Path(path_value).is_absolute()
        and os.path.normpath(path_value) == path_value
        and bool(Path(path_value).name)
        and isinstance(identity, Mapping)
        and set(identity) == {"device", "inode"}
        and all(
            isinstance(identity[field], int)
            and not isinstance(identity[field], bool)
            and identity[field] >= 0
            for field in ("device", "inode")
        )
        and value["retained_stub_count"] == 17
        and isinstance(stubs, list)
        and len(stubs) == 17
        and _require_sha256(
            value["retained_stub_manifest_sha256"],
            f"native sanitation receipt {request_ordinal} stub manifest",
        )
        == value["retained_stub_manifest_sha256"]
        and value["original_output_manifest_sha256"]
        == canonical_sha256(expected_original_output_manifest),
        f"native sanitation receipt {request_ordinal} header differs",
    )
    expected_original_names = [
        str(row["original_name"])
        for row in expected_original_output_manifest
    ]
    observed_original_names: list[str] = []
    original_names: set[str] = set()
    retained_names: set[str] = set()
    retained_identities: set[tuple[int, int]] = set()
    for stub in stubs:
        _require(
            isinstance(stub, Mapping)
            and set(stub)
            == {
                "original_name",
                "retained_name",
                "device",
                "inode",
                "size_bytes",
                "sha256",
            },
            f"native sanitation receipt {request_ordinal} stub fields differ",
        )
        original_name = stub["original_name"]
        retained_name = stub["retained_name"]
        _require(
            isinstance(original_name, str)
            and bool(original_name)
            and Path(original_name).name == original_name
            and isinstance(retained_name, str)
            and bool(retained_name)
            and Path(retained_name).name == retained_name
            and isinstance(stub["device"], int)
            and not isinstance(stub["device"], bool)
            and stub["device"] >= 0
            and isinstance(stub["inode"], int)
            and not isinstance(stub["inode"], bool)
            and stub["inode"] >= 0
            and stub["size_bytes"] == 0
            and stub["sha256"] == _EMPTY_FILE_SHA256,
            f"native sanitation receipt {request_ordinal} stub differs",
        )
        observed_original_names.append(original_name)
        original_names.add(original_name)
        retained_names.add(retained_name)
        retained_identities.add((stub["device"], stub["inode"]))
    _require(
        observed_original_names == expected_original_names
        and len(original_names) == len(retained_names) == len(retained_identities) == 17
        and value["retained_stub_manifest_sha256"] == canonical_sha256(stubs),
        f"native sanitation receipt {request_ordinal} manifest differs",
    )
    return json.loads(canonical_json_bytes(value))


def _validate_input_sanitation_evidence(
    *,
    root: _PinnedDirectory,
) -> tuple[
    Mapping[str, object],
    Mapping[str, object],
    list[Mapping[str, object]],
]:
    receipt = _RegularSnapshot.capture(
        root.path / INPUT_SANITATION_RECEIPT_NAME,
        "completed input sanitation receipt",
    )
    document = _strict_json_object(
        receipt.payload,
        "completed input sanitation receipt",
    )
    required = {
        "schema_version",
        "artifact_kind",
        "status",
        "retained_directory_identity",
        "retained_stub_count",
        "retained_stubs",
        "retained_stub_manifest_sha256",
        "original_input_manifest_sha256",
        "receipt_sha256",
    }
    unsealed = dict(document)
    recorded_receipt_sha256 = unsealed.pop("receipt_sha256", None)
    identity = document.get("retained_directory_identity")
    stubs = document.get("retained_stubs")
    _require(
        set(document) == required
        and receipt.payload == canonical_artifact_file_bytes(document)
        and document.get("schema_version") == "1.0.0"
        and document.get("artifact_kind")
        == "p06_corrective_development_input_sanitation_receipt"
        and document.get("status") == "sanitized_retained"
        and isinstance(identity, Mapping)
        and set(identity) == {"device", "inode"}
        and all(
            isinstance(identity[field], int)
            and not isinstance(identity[field], bool)
            and identity[field] >= 0
            for field in ("device", "inode")
        )
        and isinstance(stubs, list)
        and 1 <= len(stubs) <= 18
        and document.get("retained_stub_count") == len(stubs)
        and _require_sha256(
            document.get("retained_stub_manifest_sha256"),
            "input sanitation retained-stub manifest",
        )
        == document.get("retained_stub_manifest_sha256")
        and _require_sha256(
            document.get("original_input_manifest_sha256"),
            "input sanitation original-input manifest",
        )
        == document.get("original_input_manifest_sha256")
        and recorded_receipt_sha256 == canonical_sha256(unsealed),
        "completed input sanitation receipt differs",
    )
    inputs = _PinnedDirectory(root.path / "inputs", "completed sanitized inputs")
    try:
        metadata = _private_directory_metadata(inputs, "completed sanitized inputs")
        _require(
            (metadata.st_dev, metadata.st_ino)
            == (identity["device"], identity["inode"]),
            "completed sanitized-input directory identity differs",
        )
        names: set[str] = set()
        identities: set[tuple[int, int]] = set()
        manifest: list[Mapping[str, object]] = []
        for stub in stubs:
            _require(
                isinstance(stub, Mapping)
                and set(stub)
                == {"name", "device", "inode", "size_bytes", "sha256"},
                "input sanitation retained-stub field set differs",
            )
            name = stub["name"]
            _require(
                isinstance(name, str)
                and re.fullmatch(r"[0-9a-f]{64}\.nv12", name) is not None
                and isinstance(stub["device"], int)
                and not isinstance(stub["device"], bool)
                and stub["device"] >= 0
                and isinstance(stub["inode"], int)
                and not isinstance(stub["inode"], bool)
                and stub["inode"] >= 0
                and stub["size_bytes"] == 0
                and stub["sha256"] == _EMPTY_FILE_SHA256,
                "input sanitation retained stub differs",
            )
            snapshot = _RegularSnapshot.capture(
                inputs.path / name,
                "completed sanitized input stub",
            )
            _require(
                snapshot.payload == b""
                and (snapshot.device, snapshot.inode)
                == (stub["device"], stub["inode"]),
                "completed sanitized input stub identity differs",
            )
            names.add(name)
            identities.add((stub["device"], stub["inode"]))
            manifest.append(
                _manifest_row(snapshot, relative_path=f"inputs/{name}")
            )
        _require(
            len(names) == len(identities) == len(stubs)
            and set(os.listdir(inputs.descriptor)) == names
            and document["retained_stub_manifest_sha256"]
            == canonical_sha256(stubs),
            "completed sanitized input manifest differs",
        )
        inputs.verify()
    finally:
        inputs.close()
    return (
        document,
        {
            "receipt_file_sha256": receipt.file_sha256,
            "receipt_size_bytes": receipt.size_bytes,
            "receipt_sha256": recorded_receipt_sha256,
            "retained_directory_identity": dict(identity),
            "retained_stub_count": len(stubs),
            "retained_stub_manifest_sha256": document[
                "retained_stub_manifest_sha256"
            ],
            "original_input_manifest_sha256": document[
                "original_input_manifest_sha256"
            ],
        },
        [
            _manifest_row(
                receipt,
                relative_path=INPUT_SANITATION_RECEIPT_NAME,
            ),
            *manifest,
        ],
    )


def _validate_completed_journal(
    *,
    root: _PinnedDirectory,
) -> tuple[
    Mapping[str, object],
    list[Mapping[str, object]],
    list[Mapping[str, object]],
    list[Mapping[str, object]],
]:
    journal = _PinnedDirectory(
        root.path / JOURNAL_DIRECTORY_NAME,
        "completed corrective journal",
    )
    try:
        _private_directory_metadata(journal, "completed corrective journal")
        expected_names = [
            f"{sequence:06d}-"
            + ("call-evidence" if sequence % 2 == 0 else "output-cleanup")
            + ".json"
            for sequence in range(36)
        ]
        _require(
            sorted(os.listdir(journal.descriptor)) == expected_names,
            "completed corrective journal leaf set differs",
        )
        previous = _JOURNAL_GENESIS_SHA256
        call_native_sha256: dict[int, str] = {}
        call_output_manifests: dict[
            int,
            list[dict[str, object]],
        ] = {}
        cleanup_receipts: list[Mapping[str, object]] = []
        file_manifest: list[Mapping[str, object]] = []
        entry_bindings: list[Mapping[str, object]] = []
        for sequence, name in enumerate(expected_names):
            snapshot = _RegularSnapshot.capture(
                journal.path / name,
                "completed corrective journal entry",
            )
            document = _strict_json_object(
                snapshot.payload,
                "completed corrective journal entry",
            )
            entry_kind = "call-evidence" if sequence % 2 == 0 else "output-cleanup"
            request_ordinal = sequence // 2
            unsealed = dict(document)
            entry_sha256 = unsealed.pop("entry_sha256", None)
            _require(
                set(document)
                == {
                    "schema_version",
                    "artifact_kind",
                    "sequence_ordinal",
                    "request_ordinal",
                    "entry_kind",
                    "previous_entry_sha256",
                    "evidence",
                    "entry_sha256",
                }
                and snapshot.payload == canonical_artifact_file_bytes(document)
                and document.get("schema_version") == "1.0.0"
                and document.get("artifact_kind")
                == "p06_corrective_diagnostic_call_journal_entry"
                and document.get("sequence_ordinal") == sequence
                and document.get("request_ordinal") == request_ordinal
                and document.get("entry_kind") == entry_kind
                and document.get("previous_entry_sha256") == previous
                and entry_sha256 == canonical_sha256(unsealed),
                "completed corrective journal chain differs",
            )
            evidence = document.get("evidence")
            if entry_kind == "call-evidence":
                _require(
                    isinstance(evidence, Mapping)
                    and set(evidence)
                    == {
                        "native_record",
                        "coordinate_observations",
                        "production_v2_observation",
                        "risk_record",
                        "generic_route_lut",
                        "production_route_lut",
                    }
                    and isinstance(evidence["coordinate_observations"], list)
                    and isinstance(evidence["production_v2_observation"], Mapping)
                    and isinstance(evidence["risk_record"], Mapping)
                    and isinstance(evidence["generic_route_lut"], Mapping)
                    and isinstance(evidence["production_route_lut"], Mapping),
                    "completed corrective call evidence differs",
                )
                native_record = evidence["native_record"]
                _require(
                    isinstance(native_record, Mapping)
                    and native_record.get("ordinal") == request_ordinal,
                    "completed corrective native record ordinal differs",
                )
                native_unsealed = dict(native_record)
                native_sha256 = native_unsealed.pop(
                    "native_record_sha256",
                    None,
                )
                _require(
                    native_sha256 == canonical_sha256(native_unsealed),
                    "completed corrective native record self-hash differs",
                )
                call_native_sha256[request_ordinal] = str(native_sha256)
                call_output_manifests[request_ordinal] = (
                    _native_original_output_manifest(
                        native_record,
                        request_ordinal=request_ordinal,
                    )
                )
            else:
                _require(
                    isinstance(evidence, Mapping)
                    and set(evidence)
                    == {
                        "native_record_sha256",
                        "output_cleanup_status",
                        "native_cleanup_receipt",
                    }
                    and evidence.get("native_record_sha256")
                    == call_native_sha256.get(request_ordinal)
                    and evidence.get("output_cleanup_status")
                    == "sanitized_retained",
                    "completed corrective cleanup evidence differs",
                )
                expected_output_manifest = call_output_manifests.get(
                    request_ordinal
                )
                _require(
                    expected_output_manifest is not None,
                    "completed corrective cleanup output manifest is absent",
                )
                receipt = _validate_native_sanitation_receipt(
                    evidence["native_cleanup_receipt"],
                    request_ordinal=request_ordinal,
                    expected_original_output_manifest=expected_output_manifest,
                )
                expected_cleanup_unsealed = {
                    "schema_version": "1.0.0",
                    "artifact_kind": (
                        "p06_corrective_diagnostic_call_journal_entry"
                    ),
                    "sequence_ordinal": sequence,
                    "request_ordinal": request_ordinal,
                    "entry_kind": "output-cleanup",
                    "previous_entry_sha256": previous,
                    "evidence": {
                        "native_record_sha256": call_native_sha256[
                            request_ordinal
                        ],
                        "output_cleanup_status": "sanitized_retained",
                        "native_cleanup_receipt": receipt,
                    },
                }
                _require(
                    unsealed == expected_cleanup_unsealed,
                    "completed corrective cleanup journal binding differs",
                )
                cleanup_receipts.append(receipt)
            previous = str(entry_sha256)
            entry_bindings.append(
                {
                    "name": name,
                    "sequence_ordinal": sequence,
                    "request_ordinal": request_ordinal,
                    "entry_kind": entry_kind,
                    "previous_entry_sha256": document[
                        "previous_entry_sha256"
                    ],
                    "entry_sha256": entry_sha256,
                    "file_sha256": snapshot.file_sha256,
                    "size_bytes": snapshot.size_bytes,
                }
            )
            file_manifest.append(
                _manifest_row(
                    snapshot,
                    relative_path=f"{JOURNAL_DIRECTORY_NAME}/{name}",
                )
            )
        _require(
            len(call_native_sha256) == len(cleanup_receipts) == 18,
            "completed corrective journal counts differ",
        )
        journal.verify()
    finally:
        journal.close()
    return (
        {
            "entry_count": 36,
            "call_evidence_count": 18,
            "cleanup_receipt_count": 18,
            "genesis_sha256": _JOURNAL_GENESIS_SHA256,
            "tail_entry_sha256": previous,
            "entry_file_manifest_sha256": canonical_sha256(file_manifest),
            "cleanup_receipts_sha256": canonical_sha256(cleanup_receipts),
        },
        cleanup_receipts,
        file_manifest,
        entry_bindings,
    )


def _validate_native_sanitation_directories(
    *,
    root: _PinnedDirectory,
    receipts: Sequence[Mapping[str, object]],
) -> Mapping[str, object]:
    _require(len(receipts) == 18, "native sanitation receipt count differs")
    transaction_paths: set[Path] = set()
    transaction_identities: set[tuple[int, int]] = set()
    transaction_manifest: list[Mapping[str, object]] = []
    for ordinal, receipt in enumerate(receipts):
        path = _lexical_absolute(
            Path(str(receipt["retained_transaction_path"])),
            f"native sanitation transaction {ordinal}",
        )
        _require(
            path.parent == root.path,
            "native sanitation transaction is outside the completed evidence root",
        )
        directory = _PinnedDirectory(
            path,
            f"native sanitation transaction {ordinal}",
        )
        try:
            metadata = _private_directory_metadata(
                directory,
                f"native sanitation transaction {ordinal}",
            )
            identity = receipt["retained_transaction_identity"]
            assert isinstance(identity, Mapping)
            _require(
                (metadata.st_dev, metadata.st_ino)
                == (identity["device"], identity["inode"]),
                f"native sanitation transaction {ordinal} identity differs",
            )
            stubs = receipt["retained_stubs"]
            assert isinstance(stubs, list)
            expected_names = {str(stub["retained_name"]) for stub in stubs}
            _require(
                set(os.listdir(directory.descriptor)) == expected_names,
                f"native sanitation transaction {ordinal} leaf set differs",
            )
            leaf_manifest: list[Mapping[str, object]] = []
            for stub in stubs:
                assert isinstance(stub, Mapping)
                name = str(stub["retained_name"])
                snapshot = _RegularSnapshot.capture(
                    directory.path / name,
                    f"native sanitation transaction {ordinal} stub",
                )
                _require(
                    snapshot.payload == b""
                    and (snapshot.device, snapshot.inode)
                    == (stub["device"], stub["inode"])
                    and snapshot.file_sha256 == _EMPTY_FILE_SHA256,
                    f"native sanitation transaction {ordinal} stub differs",
                )
                leaf_manifest.append(
                    _manifest_row(snapshot, relative_path=name)
                )
            directory.verify()
        finally:
            directory.close()
        transaction_paths.add(path)
        transaction_identities.add((identity["device"], identity["inode"]))
        transaction_manifest.append(
            {
                "request_ordinal": ordinal,
                "retained_transaction_path": os.fspath(path),
                "retained_transaction_identity": dict(identity),
                "native_cleanup_receipt_sha256": canonical_sha256(receipt),
                "retained_stub_count": len(stubs),
                "retained_stub_manifest_sha256": receipt[
                    "retained_stub_manifest_sha256"
                ],
                "original_output_manifest_sha256": receipt[
                    "original_output_manifest_sha256"
                ],
                "reopened_leaf_manifest_sha256": canonical_sha256(
                    leaf_manifest
                ),
            }
        )
    _require(
        len(transaction_paths) == len(transaction_identities) == 18,
        "native sanitation transactions are not distinct",
    )
    root.verify()
    return {
        "transaction_count": 18,
        "retained_stub_count": 18 * 17,
        "cleanup_receipts_sha256": canonical_sha256(receipts),
        "transactions": transaction_manifest,
        "transaction_manifest_sha256": canonical_sha256(
            transaction_manifest
        ),
    }


def _read_regular_at(
    directory_descriptor: int,
    name: str,
    label: str,
) -> tuple[bytes, os.stat_result]:
    _require(
        bool(name) and Path(name).name == name,
        f"{label} name is not one safe leaf",
    )
    before = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    _require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        _require(
            (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} identity changed while opening",
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
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    _require(
        stable(before) == stable(opened) == stable(after) == stable(current),
        f"{label} changed while reading",
    )
    payload = b"".join(chunks)
    _require(len(payload) == before.st_size, f"{label} read was truncated")
    return payload, before


def _recursive_evidence_manifest(
    directory_descriptor: int,
    *,
    prefix: str = "",
) -> list[Mapping[str, object]]:
    result: list[Mapping[str, object]] = []
    for name in sorted(os.listdir(directory_descriptor)):
        _require(
            name not in {"", ".", ".."} and "/" not in name,
            "completed evidence contains an invalid leaf name",
        )
        relative_path = f"{prefix}/{name}" if prefix else name
        metadata = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if stat.S_ISDIR(metadata.st_mode):
            result.append(
                {
                    "relative_path": relative_path,
                    "entry_kind": "directory",
                }
            )
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
            try:
                opened = os.fstat(child)
                _require(
                    (opened.st_dev, opened.st_ino)
                    == (metadata.st_dev, metadata.st_ino),
                    "completed evidence directory identity changed while opening",
                )
                result.extend(
                    _recursive_evidence_manifest(
                        child,
                        prefix=relative_path,
                    )
                )
            finally:
                os.close(child)
            current = os.stat(
                name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISDIR(current.st_mode)
                and (current.st_dev, current.st_ino)
                == (metadata.st_dev, metadata.st_ino),
                "completed evidence directory identity changed during traversal",
            )
        elif stat.S_ISREG(metadata.st_mode):
            payload, reopened = _read_regular_at(
                directory_descriptor,
                name,
                "completed evidence manifest leaf",
            )
            result.append(
                {
                    "relative_path": relative_path,
                    "entry_kind": "regular_file",
                    "size_bytes": reopened.st_size,
                    "file_sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
        else:
            raise CorrectiveDiagnosticCLIError(
                "completed evidence contains a non-regular leaf"
            )
    return result


def _completed_evidence_summary(
    *,
    binding: Mapping[str, object],
    work_parent: _PinnedDirectory,
    published_path: Path,
    published_summary: Mapping[str, object],
    expected_guard: Mapping[str, object],
) -> Mapping[str, object]:
    binding_document = json.loads(canonical_json_bytes(binding))
    required_binding_fields = {
        "schema_version",
        "artifact_kind",
        "work_root_path",
        "work_root_identity",
        "prepublication_execution_closure",
        "executor_publication_receipt",
        "executor_publication_receipt_file_sha256",
        "completed_recursive_entry_count",
        "completed_recursive_entries",
        "completed_recursive_manifest_sha256",
        "completed_evidence_binding_sha256",
    }
    binding_unsealed = dict(binding_document)
    binding_sha256 = binding_unsealed.pop(
        "completed_evidence_binding_sha256",
        None,
    )
    _require(
        set(binding_document) == required_binding_fields
        and binding_document.get("schema_version") == "1.0.0"
        and binding_document.get("artifact_kind")
        == "p06_corrective_completed_evidence_binding"
        and binding_sha256 == canonical_sha256(binding_unsealed),
        "completed corrective evidence binding differs",
    )
    path_value = binding_document.get("work_root_path")
    _require(
        isinstance(path_value, str),
        "completed corrective evidence path is absent",
    )
    absolute = _lexical_absolute(
        Path(path_value),
        "completed corrective evidence root",
    )
    _require(
        absolute.parent == work_parent.path
        and re.fullmatch(
            r"\.mirmir-corrective-execution-[0-9a-f]{32}",
            absolute.name,
        )
        is not None,
        "completed corrective evidence path is outside its pinned work parent",
    )
    prepublication = binding_document.get("prepublication_execution_closure")
    required_prepublication_fields = {
        "schema_version",
        "artifact_kind",
        "status",
        "work_root_path",
        "work_root_identity",
        "journal",
        "journal_entry_bindings",
        "journal_entry_binding_manifest_sha256",
        "input_sanitation_receipt",
        "input_sanitation_receipt_file_sha256",
        "native_sanitation_receipt_count",
        "native_retained_stub_count",
        "native_sanitation_receipts",
        "native_sanitation_receipt_manifest_sha256",
        "recursive_entry_count",
        "recursive_entries",
        "recursive_manifest_sha256",
        "expected_executor_publication_receipt_name",
        "prepublication_closure_sha256",
    }
    _require(
        isinstance(prepublication, Mapping)
        and set(prepublication) == required_prepublication_fields,
        "prepublication corrective evidence closure field set differs",
    )
    prepublication_unsealed = dict(prepublication)
    prepublication_sha256 = prepublication_unsealed.pop(
        "prepublication_closure_sha256",
        None,
    )
    work_identity = binding_document.get("work_root_identity")
    _require(
        prepublication.get("schema_version") == "1.0.0"
        and prepublication.get("artifact_kind")
        == "p06_corrective_prepublication_execution_closure"
        and prepublication.get("status")
        == "sanitation_and_journal_closed_pending_publication"
        and prepublication.get("work_root_path") == path_value
        and prepublication.get("work_root_identity") == work_identity
        and prepublication.get("expected_executor_publication_receipt_name")
        == EXECUTOR_PUBLICATION_RECEIPT_NAME
        and prepublication_sha256 == canonical_sha256(prepublication_unsealed),
        "prepublication corrective evidence closure differs",
    )
    _require(
        isinstance(work_identity, Mapping)
        and set(work_identity) == {"device", "inode"}
        and all(
            isinstance(work_identity[field], int)
            and not isinstance(work_identity[field], bool)
            and work_identity[field] >= 0
            for field in ("device", "inode")
        ),
        "completed corrective evidence root identity is invalid",
    )
    root = _PinnedDirectory(absolute, "completed corrective evidence root")
    try:
        root_metadata = _private_directory_metadata(
            root,
            "completed corrective evidence root",
        )
        _require(
            (root_metadata.st_dev, root_metadata.st_ino)
            == (work_identity["device"], work_identity["inode"]),
            "completed corrective evidence root identity differs",
        )
        completed_entries = binding_document.get("completed_recursive_entries")
        _require(
            isinstance(completed_entries, list)
            and binding_document.get("completed_recursive_entry_count")
            == len(completed_entries)
            and binding_document.get("completed_recursive_manifest_sha256")
            == canonical_sha256(completed_entries),
            "completed corrective recursive binding differs",
        )
        reopened_entries = _recursive_evidence_manifest(root.descriptor)
        _require(
            reopened_entries == completed_entries,
            "completed corrective evidence differs after resource close",
        )
        prepublication_entries = prepublication.get("recursive_entries")
        reopened_prepublication_entries = [
            row
            for row in reopened_entries
            if row.get("relative_path") != EXECUTOR_PUBLICATION_RECEIPT_NAME
        ]
        _require(
            isinstance(prepublication_entries, list)
            and prepublication.get("recursive_entry_count")
            == len(prepublication_entries)
            and prepublication.get("recursive_manifest_sha256")
            == canonical_sha256(prepublication_entries)
            and reopened_prepublication_entries == prepublication_entries,
            "prepublication corrective recursive binding differs after close",
        )
        input_document, input_summary, _ = (
            _validate_input_sanitation_evidence(root=root)
        )
        _require(
            input_document == prepublication.get("input_sanitation_receipt")
            and input_summary["receipt_file_sha256"]
            == prepublication.get("input_sanitation_receipt_file_sha256"),
            "completed input sanitation evidence differs from its closure",
        )
        (
            journal_summary,
            cleanup_receipts,
            _,
            journal_entry_bindings,
        ) = _validate_completed_journal(root=root)
        _require(
            prepublication.get("journal")
            == {
                "entry_count": journal_summary["entry_count"],
                "evidence_count": journal_summary["call_evidence_count"],
                "completed_call_count": journal_summary[
                    "cleanup_receipt_count"
                ],
                "tail_sha256": journal_summary["tail_entry_sha256"],
            }
            and prepublication.get("journal_entry_bindings")
            == journal_entry_bindings
            and prepublication.get("journal_entry_binding_manifest_sha256")
            == canonical_sha256(journal_entry_bindings)
            and prepublication.get("native_sanitation_receipts")
            == cleanup_receipts
            and prepublication.get("native_sanitation_receipt_count") == 18
            and prepublication.get("native_retained_stub_count") == 306
            and prepublication.get("native_sanitation_receipt_manifest_sha256")
            == canonical_sha256(cleanup_receipts),
            "completed journal or sanitation closure differs",
        )
        native_summary = _validate_native_sanitation_directories(
            root=root,
            receipts=cleanup_receipts,
        )
        publication_receipt_snapshot = _RegularSnapshot.capture(
            root.path / EXECUTOR_PUBLICATION_RECEIPT_NAME,
            "executor publication receipt",
        )
        publication_receipt = _strict_json_object(
            publication_receipt_snapshot.payload,
            "executor publication receipt",
        )
        publication_receipt_unsealed = dict(publication_receipt)
        publication_receipt_sha256 = publication_receipt_unsealed.pop(
            "receipt_sha256",
            None,
        )
        _require(
            publication_receipt
            == binding_document.get("executor_publication_receipt")
            and publication_receipt_snapshot.payload
            == canonical_artifact_file_bytes(publication_receipt)
            and publication_receipt_snapshot.file_sha256
            == binding_document.get(
                "executor_publication_receipt_file_sha256"
            )
            and publication_receipt_sha256
            == canonical_sha256(publication_receipt_unsealed),
            "executor publication receipt differs after resource close",
        )
        required_receipt_fields = {
            "schema_version",
            "artifact_kind",
            "status",
            "published_output_root",
            "prepublication_closure_sha256",
            "published_artifacts",
            "postcommit_live_holdout_guard",
            "postcommit_live_holdout_guard_sha256",
            "receipt_sha256",
        }
        published_artifacts = publication_receipt.get("published_artifacts")
        _require(
            set(publication_receipt) == required_receipt_fields
            and publication_receipt.get("schema_version") == "1.0.0"
            and publication_receipt.get("artifact_kind")
            == "p06_corrective_executor_publication_receipt"
            and publication_receipt.get("status")
            == "executor_publication_validated_pending_cli_resource_close"
            and publication_receipt.get("published_output_root")
            == os.fspath(published_path)
            and publication_receipt.get("prepublication_closure_sha256")
            == prepublication_sha256
            and publication_receipt.get("postcommit_live_holdout_guard")
            == expected_guard
            and publication_receipt.get(
                "postcommit_live_holdout_guard_sha256"
            )
            == canonical_sha256(expected_guard)
            and isinstance(published_artifacts, Mapping)
            and set(published_artifacts)
            == {COORDINATE_ARTIFACT_NAME, RISK_ARTIFACT_NAME, ENVELOPE_NAME},
            "executor publication receipt semantics differ",
        )
        published_by_name = {
            str(row["name"]): row for row in published_summary["artifacts"]
        }
        self_hash_fields = {
            COORDINATE_ARTIFACT_NAME: "artifact_sha256",
            RISK_ARTIFACT_NAME: "artifact_sha256",
            ENVELOPE_NAME: "envelope_sha256",
        }
        for name, expected_self_hash_field in self_hash_fields.items():
            artifact_binding = published_artifacts[name]
            summary_binding = published_by_name[name]
            _require(
                isinstance(artifact_binding, Mapping)
                and set(artifact_binding)
                == {
                    "self_hash_field",
                    "self_sha256",
                    "file_sha256",
                    "size_bytes",
                }
                and artifact_binding.get("self_hash_field")
                == expected_self_hash_field
                and artifact_binding.get("self_sha256")
                == summary_binding["artifact_sha256"]
                and artifact_binding.get("file_sha256")
                == summary_binding["file_sha256"]
                and artifact_binding.get("size_bytes")
                == summary_binding["size_bytes"],
                "executor publication artifact binding differs",
            )
        for artifact_name in (
            COORDINATE_ARTIFACT_NAME,
            RISK_ARTIFACT_NAME,
        ):
            snapshot = _RegularSnapshot.capture(
                published_path / artifact_name,
                "published artifact completed-evidence binding",
            )
            document = _strict_json_object(
                snapshot.payload,
                "published artifact completed-evidence binding",
            )
            artifact_input_bindings = document.get("input_bindings")
            _require(
                isinstance(artifact_input_bindings, Mapping)
                and artifact_input_bindings.get("completed_execution_evidence")
                == prepublication,
                "published artifact prepublication closure binding differs",
            )
        root.verify()
        work_parent.verify()
        body = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_completed_evidence_post_close",
            "status": "post_close_reopen_verified",
            "root": root.binding(),
            "completed_evidence_binding": binding_document,
            "completed_recursive_entry_count": len(reopened_entries),
            "completed_recursive_manifest_sha256": canonical_sha256(
                reopened_entries
            ),
            "input_sanitation": input_summary,
            "journal_closure": journal_summary,
            "native_output_sanitation": native_summary,
            "executor_publication_receipt": {
                "file_sha256": publication_receipt_snapshot.file_sha256,
                "size_bytes": publication_receipt_snapshot.size_bytes,
                "receipt_sha256": publication_receipt_sha256,
            },
        }
        return {
            **body,
            "completed_evidence_sha256": canonical_sha256(body),
        }
    finally:
        root.close()


def _published_summary(path: Path, run_id: str) -> Mapping[str, object]:
    root = _PinnedDirectory(path, "published corrective bundle")
    try:
        names = sorted(os.listdir(root.descriptor))
        expected = sorted(
            [COORDINATE_ARTIFACT_NAME, RISK_ARTIFACT_NAME, ENVELOPE_NAME]
        )
        _require(names == expected, "published corrective bundle has extra entries")
        coordinate = _RegularSnapshot.capture(
            path / COORDINATE_ARTIFACT_NAME,
            "published coordinate artifact",
        )
        risk = _RegularSnapshot.capture(
            path / RISK_ARTIFACT_NAME,
            "published risk artifact",
        )
        envelope = _RegularSnapshot.capture(
            path / ENVELOPE_NAME,
            "published envelope",
        )
        coordinate_document = _strict_json_object(
            coordinate.payload,
            "published coordinate artifact",
        )
        risk_document = _strict_json_object(
            risk.payload,
            "published risk artifact",
        )
        envelope_document = _strict_json_object(
            envelope.payload,
            "published envelope",
        )
        validate_coordinate_anisotropy_artifact(coordinate_document)
        validate_risk_state_artifact(risk_document)
        validate_corrective_diagnostic_envelope(
            envelope_document,
            coordinate_artifact_payload=coordinate.payload,
            risk_state_artifact_payload=risk.payload,
        )
        _require(
            coordinate.payload == canonical_artifact_file_bytes(coordinate_document)
            and risk.payload == canonical_artifact_file_bytes(risk_document)
            and envelope.payload == canonical_artifact_file_bytes(envelope_document),
            "published corrective artifact bytes are not canonical",
        )
        return {
            "schema_version": "1.0.0",
            "status": "corrective_diagnostics_published",
            "run_id": run_id,
            "published_root": os.fspath(path),
            "artifacts": [
                {
                    "name": COORDINATE_ARTIFACT_NAME,
                    "file_sha256": coordinate.file_sha256,
                    "size_bytes": coordinate.size_bytes,
                    "artifact_sha256": coordinate_document["artifact_sha256"],
                },
                {
                    "name": RISK_ARTIFACT_NAME,
                    "file_sha256": risk.file_sha256,
                    "size_bytes": risk.size_bytes,
                    "artifact_sha256": risk_document["artifact_sha256"],
                },
                {
                    "name": ENVELOPE_NAME,
                    "file_sha256": envelope.file_sha256,
                    "size_bytes": envelope.size_bytes,
                    "artifact_sha256": envelope_document["envelope_sha256"],
                },
            ],
            "validation_accessed": False,
            "holdout_accessed": False,
        }
    finally:
        root.close()


def _close_resources(resources: Sequence[object]) -> None:
    errors = []
    for resource in reversed(resources):
        close = getattr(resource, "close", None)
        if callable(close):
            try:
                close()
            except BaseException as error:
                errors.append(error)
    if errors:
        combined = CorrectiveDiagnosticCLIError(
            "corrective resource cleanup failed"
        )
        combined.cleanup_errors = tuple(errors)  # type: ignore[attr-defined]
        raise combined from errors[0]


def _write_new_file_at(directory_descriptor: int, name: str, payload: bytes) -> None:
    descriptor = os.open(
        name,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=directory_descriptor,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            _require(written > 0, "quarantine receipt write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _quarantine_published_output(
    output: Path,
    primary_error: BaseException,
) -> Path:
    """Remove a late-failed bundle from its success name and mark it untrusted."""

    parent = _PinnedDirectory(output.parent, "late-failure quarantine parent")
    quarantine_name = f".{output.name}.untrusted-{uuid.uuid4().hex}"
    try:
        metadata = os.stat(
            output.name,
            dir_fd=parent.descriptor,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(metadata.st_mode),
            "late-failed corrective output is not a directory",
        )
        _rename_directory_exclusive(
            parent.descriptor,
            output.name,
            quarantine_name,
        )
        os.fsync(parent.descriptor)
        quarantine = output.parent / quarantine_name
        directory = _PinnedDirectory(quarantine, "untrusted corrective bundle")
        try:
            _require(
                directory.identity == (metadata.st_dev, metadata.st_ino),
                "late-failed corrective output identity changed during quarantine",
            )
            entries = sorted(os.listdir(directory.descriptor))
            body = {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_corrective_diagnostic_untrusted_quarantine",
                "status": "failed_closed_untrusted",
                "original_success_path": os.fspath(output),
                "quarantine_path": os.fspath(quarantine),
                "quarantined_entries": entries,
                "primary_error_type": (
                    f"{type(primary_error).__module__}."
                    f"{type(primary_error).__qualname__}"
                ),
                "primary_error_message": str(primary_error),
            }
            receipt = {
                **body,
                "failure_receipt_sha256": canonical_sha256(body),
            }
            payload = canonical_artifact_file_bytes(receipt)
            _write_new_file_at(
                directory.descriptor,
                "CLI_FAILURE_RECEIPT.json",
                payload,
            )
            os.fsync(directory.descriptor)
        finally:
            directory.close()
        os.fsync(parent.descriptor)
        _require(not os.path.lexists(output), "late-failed success path still exists")
        return quarantine
    finally:
        parent.close()


def _attach_secondary(primary: BaseException, name: str, error: BaseException) -> None:
    try:
        setattr(primary, name, error)
    except BaseException:
        pass


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Execute the exact preregistered 32-block/30-risk-cell diagnostic "
            "against only the six open development samples."
        )
    )
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--open-split-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--work-parent", required=True, type=Path)
    parser.add_argument("--native-cache-root", required=True, type=Path)
    parser.add_argument("--writer-root", required=True, type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--preregistration-path", required=True, type=Path)
    parser.add_argument("--expected-preregistration-file-sha256", required=True)
    parser.add_argument("--failed-run-root", required=True, type=Path)
    parser.add_argument("--attempt-ledger-path", required=True, type=Path)
    parser.add_argument("--expected-attempt-ledger-sha256", required=True)
    parser.add_argument("--expected-attempt-count", required=True, type=int)
    parser.add_argument("--expected-attempt-tail-record-sha256", required=True)
    parser.add_argument("--failed-failure-record-path", required=True, type=Path)
    parser.add_argument("--expected-failed-failure-record-sha256", required=True)
    parser.add_argument("--failed-input-bindings-path", required=True, type=Path)
    parser.add_argument("--expected-failed-input-bindings-sha256", required=True)
    parser.add_argument("--failed-transaction-intent-path", required=True, type=Path)
    parser.add_argument("--expected-failed-transaction-intent-sha256", required=True)
    parser.add_argument("--expected-archive-referenced-binding-count", required=True, type=int)
    parser.add_argument("--expected-archive-unique-evaluation-file-count", required=True, type=int)
    parser.add_argument("--expected-archive-unique-control-file-count", required=True, type=int)
    parser.add_argument("--expected-archive-closure-manifest-sha256", required=True)
    parser.add_argument("--expected-source-sequence", required=True, type=int)
    parser.add_argument("--expected-source-record-sha256", required=True)
    parser.add_argument("--expected-source-candidate-vector-sha256", required=True)
    parser.add_argument("--expected-carry-forward-sequence", required=True, type=int)
    parser.add_argument("--expected-carry-forward-record-sha256", required=True)
    for gate in ("g04", "g05"):
        parser.add_argument(f"--{gate}-artifact-root", required=True, type=Path)
        parser.add_argument(f"--{gate}-manifest-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-manifest-sha256", required=True)
        parser.add_argument(f"--{gate}-receipt-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-receipt-sha256", required=True)
        parser.add_argument(f"--{gate}-report-path", required=True, type=Path)
        parser.add_argument(f"--expected-{gate}-report-sha256", required=True)
    parser.add_argument("--calibration-plan-path", required=True, type=Path)
    parser.add_argument("--expected-calibration-plan-file-sha256", required=True)
    parser.add_argument("--coordinate-model-contract-path", required=True, type=Path)
    parser.add_argument("--expected-coordinate-model-contract-file-sha256", required=True)
    parser.add_argument("--video-profile-contract-path", required=True, type=Path)
    parser.add_argument("--expected-video-profile-contract-file-sha256", required=True)
    parser.add_argument("--live-ledger-path", required=True, type=Path)
    parser.add_argument("--live-anchor-path", required=True, type=Path)
    parser.add_argument("--live-preopen-receipt-path", required=True, type=Path)
    parser.add_argument("--expected-live-ledger-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-anchor-root-identity-sha256", required=True)
    parser.add_argument("--expected-live-preopen-receipt-sha256", required=True)
    parser.add_argument("--repository-sealed-copy-path", required=True, type=Path)
    parser.add_argument("--expected-repository-sealed-copy-sha256", required=True)
    parser.add_argument("--repository-attestation-path", required=True, type=Path)
    parser.add_argument("--expected-repository-attestation-sha256", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=900.0)
    return parser.parse_args()


def _execute(
    arguments: argparse.Namespace,
    *,
    execution_started_utc: datetime,
    execution_started_ns: int,
) -> Mapping[str, object]:
    _require(
        isinstance(arguments.run_id, str) and _RUN_ID.fullmatch(arguments.run_id),
        "run ID is invalid",
    )
    _require(
        isinstance(arguments.timeout_seconds, (int, float))
        and not isinstance(arguments.timeout_seconds, bool)
        and 0 < float(arguments.timeout_seconds) <= 3600,
        "timeout must be in (0, 3600] seconds",
    )
    _require_distinct_roots(
        (
            arguments.output_root,
            arguments.work_parent,
            arguments.native_cache_root,
            arguments.writer_root,
        )
    )
    output = _lexical_absolute(arguments.output_root, "output root")
    _require(not os.path.lexists(output), "output root already exists")

    pins: list[_PinnedDirectory] = []
    resources: list[object] = []
    live_binding = None
    bound = None
    initial_guard = None
    primary_error: BaseException | None = None
    primary_traceback = None
    result: Mapping[str, object] | None = None
    snapshots: list[tuple[_RegularSnapshot, str]] = []
    executor_invoked = False
    published_path: Path | None = None
    completed_evidence_binding: Mapping[str, object] | None = None
    precleanup_published_summary: Mapping[str, object] | None = None
    try:
        repository = _PinnedDirectory(arguments.repository_root, "repository root")
        open_split = _PinnedDirectory(arguments.open_split_root, "open split root")
        output_parent = _PinnedDirectory(output.parent, "output parent")
        work = _PinnedDirectory(arguments.work_parent, "work parent")
        native_cache = _PinnedDirectory(arguments.native_cache_root, "native cache root")
        writer_root = _PinnedDirectory(arguments.writer_root, "writer root")
        failed_root = _PinnedDirectory(arguments.failed_run_root, "failed run root")
        g04_root = _PinnedDirectory(arguments.g04_artifact_root, "G04 artifact root")
        g05_root = _PinnedDirectory(arguments.g05_artifact_root, "G05 artifact root")
        pins.extend(
            (
                repository,
                open_split,
                output_parent,
                work,
                native_cache,
                writer_root,
                failed_root,
                g04_root,
                g05_root,
            )
        )
        _require(
            repository.path == REPOSITORY_ROOT.resolve(strict=True),
            "repository root differs from the loaded corrective source tree",
        )
        repository_state = _repository_binding(repository)

        preregistration = _RegularSnapshot.capture(
            arguments.preregistration_path,
            "corrective preregistration",
        )
        snapshots.append((preregistration, "corrective preregistration"))
        _require(
            preregistration.file_sha256
            == _require_sha256(
                arguments.expected_preregistration_file_sha256,
                "expected corrective preregistration file",
            ),
            "corrective preregistration differs from its explicit expected hash",
        )
        _require(
            preregistration.mtime_ns <= execution_started_ns
            and preregistration.ctime_ns <= execution_started_ns,
            "corrective preregistration was created or changed after execution began",
        )
        preregistration_document = _strict_json_object(
            preregistration.payload,
            "corrective preregistration",
        )

        ledger = _descendant_file(
            failed_root,
            arguments.attempt_ledger_path,
            "archived attempt ledger",
            arguments.expected_attempt_ledger_sha256,
        )
        snapshots.append((ledger, "archived attempt ledger"))
        records = verify_attempt_ledger_payload(ledger.payload)
        _require(
            len(records) == arguments.expected_attempt_count
            and len(records) > 0
            and records[-1]["record_sha256"]
            == _require_sha256(
                arguments.expected_attempt_tail_record_sha256,
                "expected attempt-ledger tail",
            ),
            "archived attempt-ledger count or tail differs",
        )
        failure_record = _descendant_file(
            failed_root,
            arguments.failed_failure_record_path,
            "archived failure record",
            arguments.expected_failed_failure_record_sha256,
        )
        failed_input_bindings = _descendant_file(
            failed_root,
            arguments.failed_input_bindings_path,
            "archived input bindings",
            arguments.expected_failed_input_bindings_sha256,
        )
        transaction_intent = _descendant_file(
            failed_root,
            arguments.failed_transaction_intent_path,
            "archived transaction intent",
            arguments.expected_failed_transaction_intent_sha256,
        )
        snapshots.extend(
            (
                (failure_record, "archived failure record"),
                (failed_input_bindings, "archived input bindings"),
                (transaction_intent, "archived transaction intent"),
            )
        )
        closure_binding, closure_snapshots = _archive_closure(
            failed_root=failed_root,
            records=records,
            core_files={
                "attempt_ledger": ledger,
                "failure_record": failure_record,
                "input_bindings": failed_input_bindings,
                "transaction_intent": transaction_intent,
            },
        )
        snapshots.extend(closure_snapshots)
        _require(
            closure_binding["referenced_binding_count"]
            == arguments.expected_archive_referenced_binding_count
            and closure_binding["unique_evaluation_file_count"]
            == arguments.expected_archive_unique_evaluation_file_count
            and closure_binding["unique_control_file_count"]
            == arguments.expected_archive_unique_control_file_count
            and closure_binding["archive_closure_manifest_sha256"]
            == _require_sha256(
                arguments.expected_archive_closure_manifest_sha256,
                "expected archive closure manifest",
            ),
            "archived evidence closure differs from explicit counts or hash",
        )

        g04_manifest = _descendant_file(
            g04_root,
            arguments.g04_manifest_path,
            "G04 artifact manifest",
            arguments.expected_g04_manifest_sha256,
        )
        g04_receipt = _descendant_file(
            g04_root,
            arguments.g04_receipt_path,
            "G04 receipt",
            arguments.expected_g04_receipt_sha256,
        )
        g04_report = _descendant_file(
            g04_root,
            arguments.g04_report_path,
            "G04 report",
            arguments.expected_g04_report_sha256,
        )
        g05_manifest = _descendant_file(
            g05_root,
            arguments.g05_manifest_path,
            "G05 artifact manifest",
            arguments.expected_g05_manifest_sha256,
        )
        g05_receipt = _descendant_file(
            g05_root,
            arguments.g05_receipt_path,
            "G05 receipt",
            arguments.expected_g05_receipt_sha256,
        )
        g05_report = _descendant_file(
            g05_root,
            arguments.g05_report_path,
            "G05 report",
            arguments.expected_g05_report_sha256,
        )
        snapshots.extend(
            (
                (g04_manifest, "G04 artifact manifest"),
                (g04_receipt, "G04 receipt"),
                (g04_report, "G04 report"),
                (g05_manifest, "G05 artifact manifest"),
                (g05_receipt, "G05 receipt"),
                (g05_report, "G05 report"),
            )
        )
        g04_gate_snapshots = _validate_gate_semantics(
            gate_id="G04",
            root=g04_root,
            manifest=g04_manifest,
            receipt=g04_receipt,
            report=g04_report,
            expected_source_commit=str(repository_state["git_head_commit"]),
        )
        g05_gate_snapshots = _validate_gate_semantics(
            gate_id="G05",
            root=g05_root,
            manifest=g05_manifest,
            receipt=g05_receipt,
            report=g05_report,
            expected_source_commit=str(repository_state["git_head_commit"]),
        )
        snapshots.extend(
            (snapshot, "G04 gate semantic binding")
            for snapshot in g04_gate_snapshots
        )
        snapshots.extend(
            (snapshot, "G05 gate semantic binding")
            for snapshot in g05_gate_snapshots
        )

        coordinate = _RegularSnapshot.capture(
            arguments.coordinate_model_contract_path,
            "coordinate-model contract",
        )
        video = _RegularSnapshot.capture(
            arguments.video_profile_contract_path,
            "video-profile contract",
        )
        _require(
            coordinate.file_sha256
            == _require_sha256(
                arguments.expected_coordinate_model_contract_file_sha256,
                "expected coordinate-model contract",
            )
            and video.file_sha256
            == _require_sha256(
                arguments.expected_video_profile_contract_file_sha256,
                "expected video-profile contract",
            ),
            "corrective contract file differs from its explicit expected hash",
        )
        snapshots.extend(
            ((coordinate, "coordinate-model contract"), (video, "video-profile contract"))
        )
        coordinate_document = _strict_json_object(
            coordinate.payload,
            "coordinate-model contract",
        )
        video_document = _strict_json_object(video.payload, "video-profile contract")

        live_binding = _live_holdout_preopen_binding(arguments)
        initial_guard = _fresh_unopened_guard(live_binding)
        bound = bind_preregistered_inputs(
            repository.path,
            live_holdout_preopen_binding=live_binding,
        )
        _require(
            getattr(bound, "live_holdout_preopen_verification", None)
            == initial_guard,
            "bound live guard differs from the fresh preexecution verification",
        )
        bound.verify_unchanged()

        plan_record = bound.record("calibration_plan")
        expected_plan_path = repository.path.joinpath(
            *PurePosixPath(str(plan_record["path"])).parts
        )
        _require(
            arguments.calibration_plan_path == expected_plan_path,
            "explicit calibration plan path differs from bound inputs",
        )
        plan_snapshot = _RegularSnapshot.capture(
            arguments.calibration_plan_path,
            "calibration plan",
        )
        _require(
            plan_snapshot.file_sha256
            == plan_record["sha256"]
            == _require_sha256(
                arguments.expected_calibration_plan_file_sha256,
                "expected calibration plan",
            ),
            "calibration plan differs from its explicit or bound hash",
        )
        snapshots.append((plan_snapshot, "calibration plan"))
        plan = bound.documents["calibration_plan"]

        # Validate the artifact's candidate and ledger derivation before building
        # either runtime.  Full current-input comparison follows runtime identity.
        validate_corrective_preregistration(
            preregistration_document,
            artifact_payload=preregistration.payload,
            expected_artifact_file_sha256=preregistration.file_sha256,
            expected_bindings=preregistration_document["bindings"],
            plan=plan,
            attempt_ledger_payload=ledger.payload,
            expected_source_sequence=arguments.expected_source_sequence,
            expected_source_record_sha256=arguments.expected_source_record_sha256,
            expected_source_candidate_vector_sha256=(
                arguments.expected_source_candidate_vector_sha256
            ),
            expected_carry_forward_sequence=(
                arguments.expected_carry_forward_sequence
            ),
            expected_carry_forward_record_sha256=(
                arguments.expected_carry_forward_record_sha256
            ),
            execution_not_before_utc=execution_started_utc,
        )
        vector = preregistration_document["candidate"]["vector"]

        native = make_native_corrective_diagnostic_capability(
            repository.path,
            cache_root=native_cache.path,
            bound_inputs=bound,
            vector=vector,
            timeout_seconds=float(arguments.timeout_seconds),
        )
        resources.append(native)
        writer = production_writer_capability(writer_root.path)
        resources.append(writer)

        sample_lock = bound.documents["development_sample_lock"]
        corpus = bound.documents["corpus_lock"]
        samples = sample_lock["samples"]
        _require(isinstance(samples, list) and len(samples) == 6, "development lock is not six samples")
        runtime_binding = _runtime_binding(
            native=native,
            writer=writer,
            bound=bound,
            coordinate=coordinate,
            coordinate_document=coordinate_document,
            video=video,
            video_document=video_document,
        )
        current_bindings = {
            "repository": repository_state,
            "g04": {
                "artifact_root": g04_root.binding(),
                "manifest": g04_manifest.binding(),
                "receipt": g04_receipt.binding(),
                "report": g04_report.binding(),
            },
            "g05": {
                "artifact_root": g05_root.binding(),
                "manifest": g05_manifest.binding(),
                "receipt": g05_receipt.binding(),
                "report": g05_report.binding(),
            },
            "calibration_plan": {
                "file": plan_snapshot.binding(),
                "document_sha256": canonical_sha256(plan),
            },
            "failed_run": {
                "archive_root": failed_root.binding(),
                "attempt_ledger": ledger.binding(),
                "failure_record": failure_record.binding(),
                "input_bindings": failed_input_bindings.binding(),
                "transaction_intent": transaction_intent.binding(),
                "attempt_count": len(records),
                "tail_record_sha256": records[-1]["record_sha256"],
                **closure_binding,
            },
            "live_holdout": _live_binding_document(
                arguments,
                initial_guard,
            ),
            "development_corpus": {
                "open_split_root": open_split.binding(),
                "corpus_lock_file_sha256": bound.record("corpus_lock")["sha256"],
                "corpus_lock_manifest_sha256": corpus["manifest_sha256"],
                "development_sample_lock_file_sha256": bound.record(
                    "development_sample_lock"
                )["sha256"],
                "development_sample_lock_manifest_sha256": sample_lock[
                    "manifest_sha256"
                ],
                "development_sample_count": len(samples),
                "development_sample_bindings_sha256": canonical_sha256(samples),
            },
            "runtime": runtime_binding,
            "execution_roots": {
                "run_id": arguments.run_id,
                "output_root_lexical_path": os.fspath(output),
                "output_parent": output_parent.binding(),
                "work_parent": work.binding(),
                "native_cache_root": native_cache.binding(),
                "writer_root": writer_root.binding(),
            },
        }
        validated_preregistration = validate_corrective_preregistration(
            preregistration_document,
            artifact_payload=preregistration.payload,
            expected_artifact_file_sha256=preregistration.file_sha256,
            expected_bindings=current_bindings,
            plan=plan,
            attempt_ledger_payload=ledger.payload,
            expected_source_sequence=arguments.expected_source_sequence,
            expected_source_record_sha256=arguments.expected_source_record_sha256,
            expected_source_candidate_vector_sha256=(
                arguments.expected_source_candidate_vector_sha256
            ),
            expected_carry_forward_sequence=(
                arguments.expected_carry_forward_sequence
            ),
            expected_carry_forward_record_sha256=(
                arguments.expected_carry_forward_record_sha256
            ),
            execution_not_before_utc=execution_started_utc,
        )
        _require(
            validated_preregistration == preregistration_document,
            "preregistration semantic reopen differs",
        )
        for snapshot, label in snapshots:
            snapshot.verify(label)
        for pin in pins:
            pin.verify()
        bound.verify_unchanged()
        _require(
            _fresh_unopened_guard(live_binding) == initial_guard,
            "live guard changed before development loading",
        )

        loaded = load_development_samples(
            sample_lock,
            corpus,
            sample_root=open_split.path,
            asset_root=open_split.path,
        )
        _require(len(loaded) == 6, "development loader did not return exactly six samples")
        expected_ids = [str(row["source_asset_id"]) for row in samples]
        _require(
            [str(asset.get("source_asset_id")) for asset, _ in loaded]
            == expected_ids,
            "development loader order differs from the sample lock",
        )
        frozen_loaded = []
        for (asset, frame), sample in zip(loaded, samples):
            _require(
                frame_sha256(frame) == sample["target_frame_sha256"],
                "development loader returned pixels outside their sample lock",
            )
            frozen_loaded.append((asset, LockedDegradationCache._freeze(frame)))
        _require(
            _fresh_unopened_guard(live_binding) == initial_guard,
            "live guard changed during development loading",
        )

        degradation_cache = _EphemeralLockedDegradationCache(
            str(bound.documents["degradation_policy"]["policy_sha256"])
        )
        resources.append(degradation_cache)
        executor = CorrectiveDiagnosticExecutor(
            repository_root=repository.path,
            output_root=output,
            work_parent=work.path,
            bound_inputs=bound,
            loaded_development_samples=tuple(frozen_loaded),
            degradation_cache=degradation_cache,
            native=native,
            writer=writer,
            candidate_vector=vector,
            coordinate_contract_path=coordinate.path,
            video_profile_contract_path=video.path,
            g04_lock_file_sha256=g04_receipt.file_sha256,
            g05_lock_file_sha256=g05_receipt.file_sha256,
            corrective_preregistration_file_sha256=(
                preregistration.file_sha256
            ),
            corrective_preregistration_sha256=str(
                preregistration_document["artifact_sha256"]
            ),
        )
        executor_invoked = True
        published_path = executor.run()
        _require(
            published_path == output,
            "executor published an unexpected output root",
        )
        completed_evidence_binding = executor.completed_evidence_binding
        _require(
            isinstance(completed_evidence_binding, Mapping),
            "executor did not expose its completed evidence binding",
        )
        bound.verify_unchanged()
        _require(
            _fresh_unopened_guard(live_binding) == initial_guard,
            "live guard changed after corrective execution",
        )
        for snapshot, label in snapshots:
            snapshot.verify(label)
        _require(
            _repository_binding(repository) == current_bindings["repository"],
            "repository tracked state changed during corrective execution",
        )
        precleanup_published_summary = _published_summary(
            published_path,
            arguments.run_id,
        )
    except BaseException as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        if live_binding is not None and initial_guard is not None:
            try:
                final_guard = _fresh_unopened_guard(live_binding)
                _require(
                    final_guard == initial_guard,
                    "live guard changed while closing corrective execution",
                )
            except BaseException as guard_error:
                if primary_error is None:
                    primary_error = guard_error
                    primary_traceback = guard_error.__traceback__
                else:
                    _attach_secondary(primary_error, "final_guard_error", guard_error)
        for pin in pins:
            try:
                pin.verify()
            except BaseException as pin_verify_error:
                if primary_error is None:
                    primary_error = pin_verify_error
                    primary_traceback = pin_verify_error.__traceback__
                else:
                    _attach_secondary(
                        primary_error,
                        "pin_verify_error",
                        pin_verify_error,
                    )
        try:
            _close_resources(resources)
        except BaseException as cleanup_error:
            if primary_error is None:
                primary_error = cleanup_error
                primary_traceback = cleanup_error.__traceback__
            else:
                _attach_secondary(primary_error, "cleanup_error", cleanup_error)
        if live_binding is not None and initial_guard is not None:
            try:
                _require(
                    _fresh_unopened_guard(live_binding) == initial_guard,
                    "live guard changed after corrective resource cleanup",
                )
            except BaseException as post_cleanup_guard_error:
                if primary_error is None:
                    primary_error = post_cleanup_guard_error
                    primary_traceback = post_cleanup_guard_error.__traceback__
                else:
                    _attach_secondary(
                        primary_error,
                        "post_cleanup_guard_error",
                        post_cleanup_guard_error,
                    )
        if (
            primary_error is None
            and published_path is not None
            and completed_evidence_binding is not None
            and precleanup_published_summary is not None
            and initial_guard is not None
        ):
            try:
                reopened_published_summary = _published_summary(
                    published_path,
                    arguments.run_id,
                )
                _require(
                    reopened_published_summary == precleanup_published_summary,
                    "published corrective summary changed during resource cleanup",
                )
                completed_summary = _completed_evidence_summary(
                    binding=completed_evidence_binding,
                    work_parent=work,
                    published_path=published_path,
                    published_summary=reopened_published_summary,
                    expected_guard=initial_guard,
                )
                _require(
                    _fresh_unopened_guard(live_binding) == initial_guard,
                    "live guard changed during completed-evidence reopen",
                )
                bound.verify_unchanged()
                for snapshot, label in snapshots:
                    snapshot.verify(label)
                _require(
                    _repository_binding(repository)
                    == current_bindings["repository"],
                    "repository tracked state changed during final evidence reopen",
                )
                for pin in pins:
                    pin.verify()
                result_body = {
                    **reopened_published_summary,
                    "completed_evidence": completed_summary,
                }
                result = {
                    **result_body,
                    "execution_result_sha256": canonical_sha256(result_body),
                }
            except BaseException as completed_evidence_error:
                primary_error = completed_evidence_error
                primary_traceback = completed_evidence_error.__traceback__
        for pin in reversed(pins):
            try:
                pin.close()
            except BaseException as pin_error:
                if primary_error is None:
                    primary_error = pin_error
                    primary_traceback = pin_error.__traceback__
                else:
                    _attach_secondary(primary_error, "pin_close_error", pin_error)
        if (
            primary_error is not None
            and executor_invoked
            and os.path.lexists(output)
        ):
            try:
                quarantine_path = _quarantine_published_output(
                    output,
                    primary_error,
                )
                try:
                    setattr(
                        primary_error,
                        "untrusted_quarantine_path",
                        quarantine_path,
                    )
                except BaseException:
                    pass
            except BaseException as quarantine_error:
                _attach_secondary(
                    primary_error,
                    "quarantine_error",
                    quarantine_error,
                )
    if primary_error is not None:
        raise primary_error.with_traceback(primary_traceback)
    assert result is not None
    return result


def main() -> int:
    execution_started_utc = datetime.now(timezone.utc)
    execution_started_ns = int(execution_started_utc.timestamp() * 1_000_000_000)
    result = _execute(
        _arguments(),
        execution_started_utc=execution_started_utc,
        execution_started_ns=execution_started_ns,
    )
    print(
        json.dumps(
            result,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
