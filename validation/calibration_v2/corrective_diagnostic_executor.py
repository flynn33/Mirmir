"""Open-development executor for corrective ASH diagnostic evidence."""

from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Mapping, Protocol, Sequence
import uuid

from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COMPOSITION_SPECS,
    COORDINATE_CELLS,
    ROUTES,
    ROUTE_BLOCK_SPECS,
    artifact_file_binding,
    canonical_artifact_file_bytes,
    contract_route_for_evaluator_route,
    coordinate_anisotropy_dimension_contract,
    risk_state_dimension_contract,
    validate_coordinate_anisotropy_artifact,
    validate_corrective_diagnostic_envelope,
    validate_risk_state_artifact,
)
from validation.calibration_v2.production_evaluator import (
    WriterCapability,
    _validate_writer_round_trip,
    corpus_metric_bundle,
    degradation_native_input,
)
from validation.calibration_v2.runner import (
    LockedDegradationCache,
    spatial_degradation_profiles,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateContext,
    _planar_to_video_range_nv12,
)


COORDINATE_ARTIFACT_NAME = "coordinate-anisotropy-diagnostic.json"
RISK_ARTIFACT_NAME = "risk-state-diagnostic.json"
ENVELOPE_NAME = "corrective-diagnostic-envelope.json"
FAILURE_MANIFEST_NAME = "corrective-diagnostic-failure.json"
JOURNAL_DIRECTORY_NAME = "journal"
INPUT_SANITATION_RECEIPT_NAME = "input-sanitation-receipt.json"
EXECUTOR_PUBLICATION_RECEIPT_NAME = "executor-publication-receipt.json"
_HASH_CONTRACTS = {
    "output_plane_hash_contract": "active-nv12-code-bytes-sha256-v1",
    "normalized_plane_hash_contract": "mirmir-ash-normalized-plane-f64-be-v1",
    "analysis_grid_hash_contract": "mirmir-ash-analysis-grid-v3-be-v1",
}
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


class CorrectiveDiagnosticExecutionError(ValueError):
    """The open-development executor or publication failed closed."""


class CorrectiveNativeCapability(Protocol):
    configuration: Mapping[str, object]

    def diagnose_corrective_frame(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...

    def reopen_corrective_frame_output(
        self,
        document: Mapping[str, object],
        path: Path,
        *,
        width: int,
        height: int,
    ) -> PlanarFrame:
        ...

    def release_corrective_frame_outputs(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        ...


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CorrectiveDiagnosticExecutionError(message)


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _validated_native_sanitation_receipt(
    value: object,
) -> Mapping[str, object]:
    """Validate the complete identity-bound retained-stub receipt."""

    empty_sha256 = hashlib.sha256(b"").hexdigest()
    _require(isinstance(value, Mapping), "native sanitation receipt is absent")
    retained_path = value.get("retained_transaction_path")
    retained_identity = value.get("retained_transaction_identity")
    retained_stubs = value.get("retained_stubs")
    _require(
        value.get("status") == "sanitized_retained"
        and isinstance(retained_path, str)
        and Path(retained_path).is_absolute()
        and isinstance(retained_identity, Mapping)
        and set(retained_identity) == {"device", "inode"}
        and all(
            isinstance(retained_identity[field], int)
            and not isinstance(retained_identity[field], bool)
            and retained_identity[field] >= 0
            for field in ("device", "inode")
        )
        and value.get("retained_stub_count") == 17
        and isinstance(retained_stubs, list)
        and len(retained_stubs) == 17
        and _is_sha256(value.get("original_output_manifest_sha256")),
        "native sanitation receipt header differs",
    )
    original_names: set[str] = set()
    retained_names: set[str] = set()
    retained_identities: set[tuple[int, int]] = set()
    for row in retained_stubs:
        _require(
            isinstance(row, Mapping)
            and set(row)
            == {
                "original_name",
                "retained_name",
                "device",
                "inode",
                "size_bytes",
                "sha256",
            }
            and isinstance(row.get("original_name"), str)
            and bool(row["original_name"])
            and Path(str(row["original_name"])).name
            == row["original_name"]
            and isinstance(row.get("retained_name"), str)
            and bool(row["retained_name"])
            and Path(str(row["retained_name"])).name
            == row["retained_name"]
            and isinstance(row.get("device"), int)
            and not isinstance(row["device"], bool)
            and row["device"] >= 0
            and isinstance(row.get("inode"), int)
            and not isinstance(row["inode"], bool)
            and row["inode"] >= 0
            and row.get("size_bytes") == 0
            and row.get("sha256") == empty_sha256,
            "native sanitation retained stub differs",
        )
        original_names.add(str(row["original_name"]))
        retained_names.add(str(row["retained_name"]))
        retained_identities.add((int(row["device"]), int(row["inode"])))
    _require(
        len(original_names) == len(retained_names) == len(retained_identities) == 17
        and value.get("retained_stub_manifest_sha256")
        == canonical_sha256(retained_stubs),
        "native sanitation retained-stub manifest differs",
    )
    return json.loads(canonical_json_bytes(value))


def _seal(document: Mapping[str, object], field: str) -> dict[str, object]:
    result = json.loads(canonical_json_bytes(document))
    result[field] = canonical_sha256(result)
    return result


def _sha256_file(path: Path) -> str:
    before = os.stat(path, follow_symlinks=False)
    _require(stat.S_ISREG(before.st_mode), f"bound file is not regular: {path}")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        _require(
            (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"bound file identity changed: {path}",
        )
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    _require(
        (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino)
        and after.st_size == before.st_size
        and after.st_mtime_ns == before.st_mtime_ns,
        f"bound file changed while hashing: {path}",
    )
    return digest.hexdigest()


def _read_regular_at(
    parent_descriptor: int,
    name: str,
    label: str,
) -> tuple[bytes, tuple[int, int, int, int, int, str]]:
    before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    _require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} identity changed while opening",
        )
        digest = hashlib.sha256()
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    after_path = os.stat(
        name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    identity = (before.st_dev, before.st_ino)
    _require(
        (after.st_dev, after.st_ino) == identity
        and (after_path.st_dev, after_path.st_ino) == identity
        and after.st_uid == before.st_uid == after_path.st_uid
        and after.st_size == before.st_size == after_path.st_size
        and after.st_mtime_ns == before.st_mtime_ns == after_path.st_mtime_ns,
        f"{label} changed while reading",
    )
    payload = b"".join(chunks)
    return payload, (
        before.st_dev,
        before.st_ino,
        before.st_uid,
        before.st_size,
        before.st_mtime_ns,
        digest.hexdigest(),
    )


def _write_new_regular(
    path: Path,
    payload: bytes,
    *,
    parent_descriptor: int | None = None,
) -> tuple[int, int, int, int, int, str] | None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    name: str | Path = path if parent_descriptor is None else path.name
    descriptor = os.open(
        name,
        flags,
        0o600,
        dir_fd=parent_descriptor,
    )
    created = os.fstat(descriptor)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("corrective file write made no progress")
            offset += written
        os.fsync(descriptor)
    except BaseException as primary_error:
        try:
            opened = os.fstat(descriptor)
            _require(
                (opened.st_dev, opened.st_ino)
                == (created.st_dev, created.st_ino),
                "partial corrective file descriptor identity differs",
            )
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
            sanitized = os.fstat(descriptor)
            current = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            _require(
                sanitized.st_size == 0
                and (sanitized.st_dev, sanitized.st_ino)
                == (created.st_dev, created.st_ino)
                and current.st_size == 0
                and (current.st_dev, current.st_ino)
                == (created.st_dev, created.st_ino),
                "partial corrective file sanitation path differs; foreign file retained",
            )
            primary_error.sanitized_partial_file_path = path  # type: ignore[attr-defined]
        except BaseException as cleanup_error:
            combined = CorrectiveDiagnosticExecutionError(
                "corrective file write and non-destructive sanitation both failed"
            )
            combined.primary_error = primary_error  # type: ignore[attr-defined]
            combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
            raise combined from primary_error
        raise
    finally:
        os.close(descriptor)
    if parent_descriptor is None:
        _require(
            _sha256_file(path) == hashlib.sha256(payload).hexdigest(),
            "corrective file failed durable reopen verification",
        )
        return None
    reopened, identity = _read_regular_at(
        parent_descriptor,
        path.name,
        "corrective durable file",
    )
    _require(
        reopened == payload
        and identity[:2] == (created.st_dev, created.st_ino)
        and identity[5] == hashlib.sha256(payload).hexdigest(),
        "corrective descriptor-written file failed durable reopen verification",
    )
    return identity


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _qualified_error_type(error: BaseException) -> str:
    return f"{type(error).__module__}.{type(error).__qualname__}"


def _error_chain_evidence(error: BaseException) -> list[dict[str, object]]:
    """Capture primary, cause, context, and attached recovery errors once."""

    result: list[dict[str, object]] = []
    pending: list[tuple[str, BaseException]] = [("primary", error)]
    observed: set[int] = set()
    attachment_names = (
        "primary_error",
        "capture_error",
        "termination_error",
        "cleanup_error",
        "cleanup_failures",
        "cleanup_errors",
        "quarantine_error",
        "failure_manifest_error",
    )
    while pending:
        role, current = pending.pop(0)
        if id(current) in observed:
            continue
        observed.add(id(current))
        result.append(
            {
                "ordinal": len(result),
                "role": role,
                "error_type": _qualified_error_type(current),
                "message": str(current),
            }
        )
        if current.__cause__ is not None:
            pending.append((f"{role}.cause", current.__cause__))
        elif current.__context__ is not None:
            pending.append((f"{role}.context", current.__context__))
        for name in attachment_names:
            attached = getattr(current, name, None)
            if isinstance(attached, BaseException):
                pending.append((f"{role}.{name}", attached))
            elif isinstance(attached, (tuple, list)):
                for index, item in enumerate(attached):
                    if isinstance(item, BaseException):
                        pending.append((f"{role}.{name}[{index}]", item))
    return result


class _CorrectiveExecutionJournal:
    """Durable append-only call evidence and cleanup receipts for one run."""

    _GENESIS_SHA256 = hashlib.sha256(
        b"MIRMIR-P06-CORRECTIVE-DIAGNOSTIC-JOURNAL-V1\0"
    ).hexdigest()

    def __init__(
        self,
        work_root: Path,
        *,
        expected_work_identity: tuple[int, int] | None = None,
    ) -> None:
        self.work_root = work_root
        work_metadata = os.stat(work_root, follow_symlinks=False)
        self.work_root_identity = (work_metadata.st_dev, work_metadata.st_ino)
        _require(
            stat.S_ISDIR(work_metadata.st_mode)
            and (
                expected_work_identity is None
                or self.work_root_identity == expected_work_identity
            ),
            "corrective journal work root identity differs",
        )
        self.root = work_root / JOURNAL_DIRECTORY_NAME
        self.root.mkdir(mode=0o700)
        _fsync_directory(work_root)
        root_metadata = os.stat(self.root, follow_symlinks=False)
        self.root_identity = (root_metadata.st_dev, root_metadata.st_ino)
        self.tail_sha256 = self._GENESIS_SHA256
        self.paths: list[Path] = []
        self.entry_count = 0
        self.evidence_count = 0
        self.completed_call_count = 0
        self.guard_verification_count = 0
        self.active_call_ordinal: int | None = None
        self.active_request_sha256: str | None = None
        self.outputs_cleanup_state = "not_started"
        self.validation_accessed = False
        self.cleanup_receipts: list[Mapping[str, object]] = []
        self.published_bundle_state = "not_published"
        self.untrusted_bundle_path: str | None = None

    def _verify_storage_identities(self) -> None:
        _verify_directory_path_identity(
            self.work_root,
            self.work_root_identity,
        )
        _verify_directory_path_identity(self.root, self.root_identity)

    def rebase_work_root(self, retained_root: Path) -> None:
        """Rebind path labels after an identity-preserving exclusive rename."""

        previous_root = self.work_root
        relative_paths = [path.relative_to(previous_root) for path in self.paths]
        self.work_root = retained_root
        self.root = retained_root / JOURNAL_DIRECTORY_NAME
        self.paths = [retained_root / relative for relative in relative_paths]
        self._verify_storage_identities()

    def verify_guard(self, verify: object) -> None:
        _require(callable(verify), "bound input guard is not callable")
        verify()
        self.guard_verification_count += 1

    def begin_call(self, ordinal: int, request: Mapping[str, object]) -> None:
        self.active_call_ordinal = ordinal
        self.active_request_sha256 = canonical_sha256(request)
        self.outputs_cleanup_state = "not_started"

    def mark_native_response(self, diagnostic: Mapping[str, object]) -> None:
        self.validation_accessed = self.validation_accessed or (
            diagnostic.get("validation_accessed") is True
        )
        self.outputs_cleanup_state = "pending"

    def mark_cleanup_failed(self) -> None:
        self.outputs_cleanup_state = "failed"

    def mark_outputs_sanitized(self) -> None:
        self.outputs_cleanup_state = "sanitized_retained"

    def mark_published(self) -> None:
        self.published_bundle_state = "published_validated"

    def mark_published_untrusted(
        self,
        path: Path,
        *,
        state: str = "quarantined_untrusted",
    ) -> None:
        self.published_bundle_state = state
        self.untrusted_bundle_path = os.fspath(path)

    def _append(
        self,
        *,
        entry_kind: str,
        request_ordinal: int,
        evidence: Mapping[str, object],
    ) -> Mapping[str, object]:
        self._verify_storage_identities()
        sequence_ordinal = self.entry_count
        entry = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_corrective_diagnostic_call_journal_entry",
                "sequence_ordinal": sequence_ordinal,
                "request_ordinal": request_ordinal,
                "entry_kind": entry_kind,
                "previous_entry_sha256": self.tail_sha256,
                "evidence": evidence,
            },
            "entry_sha256",
        )
        path = self.root / f"{sequence_ordinal:06d}-{entry_kind}.json"
        payload = canonical_artifact_file_bytes(entry)
        _write_new_regular(path, payload)
        reopened_payload = path.read_bytes()
        _require(
            reopened_payload == payload,
            "corrective journal entry changed after durable write",
        )
        reopened = json.loads(reopened_payload)
        _require(
            isinstance(reopened, dict)
            and reopened == entry
            and canonical_artifact_file_bytes(reopened) == reopened_payload,
            "corrective journal entry is not canonical after reopen",
        )
        unsealed = dict(reopened)
        recorded_hash = unsealed.pop("entry_sha256", None)
        _require(
            recorded_hash == canonical_sha256(unsealed),
            "corrective journal entry self-hash differs",
        )
        _fsync_directory(self.root)
        self.paths.append(path)
        self.entry_count += 1
        self.tail_sha256 = str(recorded_hash)
        return reopened


    def append_call_evidence(
        self,
        *,
        request_ordinal: int,
        native_record: Mapping[str, object],
        coordinate_observations: Sequence[Mapping[str, object]],
        production_observation: Mapping[str, object],
        risk_record: Mapping[str, object],
        generic_route_lut: Mapping[str, object],
        production_route_lut: Mapping[str, object],
    ) -> None:
        self._append(
            entry_kind="call-evidence",
            request_ordinal=request_ordinal,
            evidence={
                "native_record": native_record,
                "coordinate_observations": list(coordinate_observations),
                "production_v2_observation": production_observation,
                "risk_record": risk_record,
                "generic_route_lut": generic_route_lut,
                "production_route_lut": production_route_lut,
            },
        )
        self.evidence_count += 1

    def append_cleanup_receipt(
        self,
        *,
        request_ordinal: int,
        native_record_sha256: str,
        native_cleanup_receipt: Mapping[str, object],
    ) -> None:
        receipt = _validated_native_sanitation_receipt(
            native_cleanup_receipt
        )
        self._append(
            entry_kind="output-cleanup",
            request_ordinal=request_ordinal,
            evidence={
                "native_record_sha256": native_record_sha256,
                "output_cleanup_status": "sanitized_retained",
                "native_cleanup_receipt": receipt,
            },
        )
        self.cleanup_receipts.append(receipt)
        self.completed_call_count += 1
        self.active_call_ordinal = None
        self.active_request_sha256 = None

    def _reopen_all(self) -> list[Mapping[str, object]]:
        self._verify_storage_identities()
        _require(
            sorted(path.name for path in self.root.iterdir())
            == sorted(path.name for path in self.paths),
            "corrective journal directory contains an unexpected entry",
        )
        previous = self._GENESIS_SHA256
        reopened_entries: list[Mapping[str, object]] = []
        for ordinal, path in enumerate(self.paths):
            payload = path.read_bytes()
            document = json.loads(payload)
            _require(
                isinstance(document, dict)
                and payload == canonical_artifact_file_bytes(document)
                and document.get("sequence_ordinal") == ordinal
                and document.get("previous_entry_sha256") == previous,
                "corrective journal order or canonical encoding differs",
            )
            unsealed = dict(document)
            entry_hash = unsealed.pop("entry_sha256", None)
            _require(
                entry_hash == canonical_sha256(unsealed),
                "corrective journal hash chain differs",
            )
            previous = str(entry_hash)
            reopened_entries.append(document)
        _require(previous == self.tail_sha256, "corrective journal tail differs")
        return reopened_entries

    def validate_complete(
        self,
        expected_call_evidence: Sequence[Mapping[str, object]],
    ) -> None:
        entries = self._reopen_all()
        _require(
            len(expected_call_evidence)
            == self.evidence_count
            == self.completed_call_count
            == len(self.cleanup_receipts)
            and len(entries) == len(expected_call_evidence) * 2,
            "corrective journal completion counts differ",
        )
        for request_ordinal, expected in enumerate(expected_call_evidence):
            evidence_entry = entries[request_ordinal * 2]
            cleanup_entry = entries[request_ordinal * 2 + 1]
            native_record = expected["native_record"]
            assert isinstance(native_record, Mapping)
            _require(
                evidence_entry.get("entry_kind") == "call-evidence"
                and evidence_entry.get("request_ordinal") == request_ordinal
                and evidence_entry.get("evidence") == expected
                and cleanup_entry.get("entry_kind") == "output-cleanup"
                and cleanup_entry.get("request_ordinal") == request_ordinal
                and cleanup_entry.get("evidence")
                == {
                    "native_record_sha256": native_record[
                        "native_record_sha256"
                    ],
                    "output_cleanup_status": "sanitized_retained",
                    "native_cleanup_receipt": self.cleanup_receipts[
                        request_ordinal
                    ],
                },
                "corrective journal differs from in-memory artifact evidence",
            )

    def fresh_guard_evidence(
        self,
        *,
        bound: object,
        verify: object,
    ) -> Mapping[str, object]:
        try:
            self.verify_guard(verify)
            documents = getattr(bound, "documents", None)
            official = getattr(
                bound,
                "live_holdout_preopen_verification",
                None,
            )
            if official is None and isinstance(documents, Mapping):
                official = documents.get("live_holdout_preopen_verification")
            live_binding = getattr(bound, "live_holdout_preopen_binding", None)
            live_verify = getattr(live_binding, "verify", None)
            if callable(live_verify):
                fresh = live_verify()
                _require(
                    isinstance(official, Mapping) and fresh == official,
                    "fresh live holdout guard differs from its bound state",
                )
                official = fresh
            _require(
                isinstance(official, Mapping),
                "official live holdout guard state is absent",
            )
            official_copy = json.loads(canonical_json_bytes(official))
            unopened = (
                official_copy.get("verification_status") == "pass"
                and official_copy.get("access_status") == "unopened"
                and official_copy.get("access_count") == 0
                and official_copy.get("open_intent_anchor_present") is False
                and official_copy.get("pixel_content_included") is False
            )
            return {
                "verify_unchanged_status": "pass",
                "official_live_holdout_state": official_copy,
                "holdout_accessed": not unopened,
                "guard_error_chain": [],
            }
        except BaseException as guard_error:
            return {
                "verify_unchanged_status": "fail",
                "official_live_holdout_state": None,
                "holdout_accessed": None,
                "guard_error_chain": _error_chain_evidence(guard_error),
            }

    def write_failure_manifest(
        self,
        *,
        primary_error: BaseException,
        guard_evidence: Mapping[str, object],
    ) -> Mapping[str, object]:
        self._verify_storage_identities()
        failure = _seal(
            {
                "schema_version": "1.0.0",
                "artifact_kind": "p06_open_development_corrective_diagnostic_failure",
                "status": "failed_closed",
                "split": "development",
                "selected_winner": None,
                "validation_accessed": self.validation_accessed,
                "holdout_accessed": guard_evidence["holdout_accessed"],
                "guard_evidence": guard_evidence,
                "guard_verification_count": self.guard_verification_count,
                "journal_entry_count": self.entry_count,
                "journal_evidence_count": self.evidence_count,
                "completed_call_count": self.completed_call_count,
                "journal_tail_sha256": self.tail_sha256,
                "active_call_ordinal": self.active_call_ordinal,
                "active_request_sha256": self.active_request_sha256,
                "outputs_cleanup_state": self.outputs_cleanup_state,
                "published_bundle_state": self.published_bundle_state,
                "untrusted_bundle_path": self.untrusted_bundle_path,
                "error_chain": _error_chain_evidence(primary_error),
            },
            "failure_record_sha256",
        )
        path = self.work_root / FAILURE_MANIFEST_NAME
        payload = canonical_artifact_file_bytes(failure)
        _write_new_regular(path, payload)
        _fsync_directory(self.work_root)
        reopened_payload = path.read_bytes()
        reopened = json.loads(reopened_payload)
        _require(
            isinstance(reopened, dict)
            and reopened == failure
            and reopened_payload == payload
            and canonical_artifact_file_bytes(reopened) == reopened_payload,
            "corrective failure manifest differs after durable reopen",
        )
        unsealed = dict(reopened)
        recorded = unsealed.pop("failure_record_sha256", None)
        _require(
            recorded == canonical_sha256(unsealed),
            "corrective failure manifest self-hash differs",
        )
        return reopened


def _journal_evidence_from_artifacts(
    coordinate_artifact: Mapping[str, object],
    risk_artifact: Mapping[str, object],
) -> list[Mapping[str, object]]:
    """Reconstruct call-ordered journal payloads from finalized artifacts."""

    native_records = coordinate_artifact["native_records"]
    blocks = coordinate_artifact["route_cell_blocks"]
    production = coordinate_artifact["production_v2_reference"]
    bindings = coordinate_artifact["input_bindings"]
    risk_records = risk_artifact["frame_route_records"]
    _require(
        isinstance(native_records, list)
        and isinstance(blocks, list)
        and isinstance(production, Mapping)
        and isinstance(bindings, Mapping)
        and isinstance(risk_records, list),
        "corrective artifacts cannot reconstruct journal evidence",
    )
    reference_observations = production.get("observations")
    production_luts = production.get("route_luts")
    generic_luts = bindings.get("generic_route_luts")
    _require(
        isinstance(reference_observations, list)
        and isinstance(production_luts, list)
        and isinstance(generic_luts, list),
        "corrective artifact journal bindings are absent",
    )
    result: list[Mapping[str, object]] = []
    for request_ordinal, native_record in enumerate(native_records):
        _require(
            isinstance(native_record, Mapping)
            and native_record.get("ordinal") == request_ordinal,
            "corrective native record order differs while rebuilding journal",
        )
        native_hash = native_record.get("native_record_sha256")
        route = native_record.get("target_route")
        coordinate_observations: list[Mapping[str, object]] = []
        for block in blocks:
            if not isinstance(block, Mapping) or block.get("target_route") != route:
                continue
            observations = block.get("observations")
            _require(
                isinstance(observations, list),
                "corrective block observations are absent",
            )
            matches = [
                row
                for row in observations
                if isinstance(row, Mapping)
                and row.get("native_record_sha256") == native_hash
            ]
            _require(
                len(matches) == 1,
                "corrective artifact has an absent or repeated journal observation",
            )
            coordinate_observations.append(matches[0])
        production_matches = [
            row
            for row in reference_observations
            if isinstance(row, Mapping)
            and row.get("native_record_sha256") == native_hash
        ]
        risk_matches = [
            row
            for row in risk_records
            if isinstance(row, Mapping)
            and row.get("native_execution_sha256") == native_hash
        ]
        generic_matches = [
            row
            for row in generic_luts
            if isinstance(row, Mapping) and row.get("route") == route
        ]
        production_lut_matches = [
            row
            for row in production_luts
            if isinstance(row, Mapping) and row.get("route") == route
        ]
        _require(
            len(coordinate_observations) == 16
            and len(production_matches) == 1
            and len(risk_matches) == 1
            and len(generic_matches) == 1
            and len(production_lut_matches) == 1,
            "corrective artifact journal evidence cardinality differs",
        )
        result.append(
            {
                "native_record": native_record,
                "coordinate_observations": coordinate_observations,
                "production_v2_observation": production_matches[0],
                "risk_record": risk_matches[0],
                "generic_route_lut": generic_matches[0],
                "production_route_lut": production_lut_matches[0],
            }
        )
    return result


def _validated_official_guard(value: object) -> Mapping[str, object]:
    _require(
        isinstance(value, Mapping)
        and value.get("verification_status") == "pass"
        and value.get("access_status") == "unopened"
        and value.get("access_count") == 0
        and value.get("open_intent_anchor_present") is False
        and value.get("pixel_content_included") is False,
        "official live holdout guard does not prove unopened state",
    )
    return json.loads(canonical_json_bytes(value))


def _fresh_bound_guard(
    *,
    bound: object,
    documents: Mapping[str, object],
    verify: object,
    journal: _CorrectiveExecutionJournal,
    expected: Mapping[str, object],
) -> Mapping[str, object]:
    journal.verify_guard(verify)
    current: object = getattr(
        bound,
        "live_holdout_preopen_verification",
        documents.get("live_holdout_preopen_verification"),
    )
    live_binding = getattr(bound, "live_holdout_preopen_binding", None)
    live_verify = getattr(live_binding, "verify", None)
    if callable(live_verify):
        current = live_verify()
    validated = _validated_official_guard(current)
    _require(
        validated == expected,
        "fresh official live holdout guard differs from the bound artifact state",
    )
    return validated


def _rename_directory_exclusive(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    if _RENAMEATX_NP is None:
        raise CorrectiveDiagnosticExecutionError(
            "exclusive corrective bundle publication is unavailable"
        )
    ctypes.set_errno(0)
    result = _RENAMEATX_NP(
        parent_descriptor,
        os.fsencode(source_name),
        parent_descriptor,
        os.fsencode(destination_name),
        _RENAME_EXCL | _RENAME_NOFOLLOW_ANY | _RENAME_RESOLVE_BENEATH,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno() or errno.EIO
    raise OSError(
        error_number,
        os.strerror(error_number),
        destination_name,
    )


def _open_directory_chain(path: Path, *, create: bool) -> int:
    _require(
        path.is_absolute()
        and all(part not in {"", ".", ".."} for part in path.parts[1:]),
        "corrective publication directory path is not safe and absolute",
    )
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            try:
                child = os.open(part, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, 0o755, dir_fd=descriptor)
                    os.fsync(descriptor)
                except FileExistsError:
                    pass
                child = os.open(part, flags, dir_fd=descriptor)
            metadata = os.fstat(child)
            _require(
                stat.S_ISDIR(metadata.st_mode),
                "corrective publication path component is not a directory",
            )
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _verify_directory_path_identity(
    path: Path,
    expected: tuple[int, int],
) -> None:
    descriptor = _open_directory_chain(path, create=False)
    try:
        metadata = os.fstat(descriptor)
        _require(
            (metadata.st_dev, metadata.st_ino) == expected,
            "corrective publication parent path identity changed",
        )
    finally:
        os.close(descriptor)


def _validate_owned_directory_at(
    *,
    parent_descriptor: int,
    directory_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
    expected_files: Mapping[str, tuple[int, int, int, int, int, str]],
    label: str,
) -> None:
    opened = os.fstat(directory_descriptor)
    current = os.stat(
        name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    _require(
        stat.S_ISDIR(opened.st_mode)
        and stat.S_ISDIR(current.st_mode)
        and (opened.st_dev, opened.st_ino) == expected_identity
        and (current.st_dev, current.st_ino) == expected_identity
        and set(os.listdir(directory_descriptor)) == set(expected_files),
        f"{label} directory identity or leaf set differs",
    )
    for filename, expected in expected_files.items():
        _, current_identity = _read_regular_at(
            directory_descriptor,
            filename,
            f"{label} leaf",
        )
        _require(
            current_identity == expected,
            f"{label} leaf identity differs",
        )


def _sanitize_regular_at(
    directory_descriptor: int,
    name: str,
    expected: tuple[int, int, int, int, int, str],
    label: str,
) -> None:
    _, current = _read_regular_at(directory_descriptor, name, label)
    _require(current == expected, f"{label} identity differs before sanitation")
    descriptor = os.open(
        name,
        os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        _require(
            (opened.st_dev, opened.st_ino) == expected[:2],
            f"{label} foreign inode was preserved",
        )
        os.ftruncate(descriptor, 0)
        os.fsync(descriptor)
        sanitized = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    path_state = os.stat(
        name,
        dir_fd=directory_descriptor,
        follow_symlinks=False,
    )
    _require(
        sanitized.st_size == 0
        and (sanitized.st_dev, sanitized.st_ino) == expected[:2]
        and path_state.st_size == 0
        and (path_state.st_dev, path_state.st_ino) == expected[:2],
        f"{label} sanitized stub path differs; foreign inode retained",
    )


def _sanitize_owned_input_directory(
    *,
    work_descriptor: int,
    input_descriptor: int,
    input_identity: tuple[int, int],
    file_identities: Mapping[str, tuple[int, int, int, int, int, str]],
) -> Mapping[str, object]:
    """Truncate only captured development-input inodes and retain their stubs."""

    _validate_owned_directory_at(
        parent_descriptor=work_descriptor,
        directory_descriptor=input_descriptor,
        name="inputs",
        expected_identity=input_identity,
        expected_files=file_identities,
        label="corrective development input sanitation",
    )
    empty_sha256 = hashlib.sha256(b"").hexdigest()
    retained_stubs = []
    for name, identity in sorted(file_identities.items()):
        _sanitize_regular_at(
            input_descriptor,
            name,
            identity,
            "corrective development input retained stub",
        )
        payload, sanitized = _read_regular_at(
            input_descriptor,
            name,
            "corrective development input sanitation reopen",
        )
        _require(
            payload == b""
            and sanitized[:2] == identity[:2]
            and sanitized[3] == 0
            and sanitized[5] == empty_sha256,
            "corrective development input retained stub differs",
        )
        retained_stubs.append(
            {
                "name": name,
                "device": sanitized[0],
                "inode": sanitized[1],
                "size_bytes": sanitized[3],
                "sha256": sanitized[5],
            }
        )
    _require(
        set(os.listdir(input_descriptor)) == set(file_identities),
        "corrective development input retained-stub set differs",
    )
    os.fsync(input_descriptor)
    return _seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_development_input_sanitation_receipt",
            "status": "sanitized_retained",
            "retained_directory_identity": {
                "device": input_identity[0],
                "inode": input_identity[1],
            },
            "retained_stub_count": len(retained_stubs),
            "retained_stubs": retained_stubs,
            "retained_stub_manifest_sha256": canonical_sha256(
                retained_stubs
            ),
            "original_input_manifest_sha256": canonical_sha256(
                [
                    {
                        "name": name,
                        "device": identity[0],
                        "inode": identity[1],
                        "owner_uid": identity[2],
                        "size_bytes": identity[3],
                        "mtime_ns": identity[4],
                        "sha256": identity[5],
                    }
                    for name, identity in sorted(file_identities.items())
                ]
            ),
        },
        "receipt_sha256",
    )


def _recursive_regular_file_manifest(
    directory_descriptor: int,
    *,
    prefix: str = "",
) -> list[Mapping[str, object]]:
    """Descriptor-walk one private tree and bind its exact paths and file hashes."""

    entries: list[Mapping[str, object]] = []
    for name in sorted(os.listdir(directory_descriptor)):
        _require(
            name not in {"", ".", ".."} and "/" not in name,
            "corrective evidence tree contains an invalid leaf name",
        )
        relative_path = f"{prefix}/{name}" if prefix else name
        metadata = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if stat.S_ISDIR(metadata.st_mode):
            entries.append(
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
                    "corrective evidence directory identity changed while opening",
                )
                entries.extend(
                    _recursive_regular_file_manifest(
                        child,
                        prefix=relative_path,
                    )
                )
            finally:
                os.close(child)
        elif stat.S_ISREG(metadata.st_mode):
            payload, identity = _read_regular_at(
                directory_descriptor,
                name,
                "corrective evidence manifest leaf",
            )
            entries.append(
                {
                    "relative_path": relative_path,
                    "entry_kind": "regular_file",
                    "size_bytes": identity[3],
                    "file_sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
        else:
            raise CorrectiveDiagnosticExecutionError(
                "corrective evidence tree contains a non-regular leaf"
            )
    return entries


def _reopen_native_sanitation_receipts(
    receipts: Sequence[Mapping[str, object]],
) -> tuple[list[Mapping[str, object]], int]:
    """Reopen every retained native directory and all identity-bound stubs."""

    validated_receipts = []
    paths: set[str] = set()
    stub_count = 0
    for value in receipts:
        receipt = _validated_native_sanitation_receipt(value)
        path = str(receipt["retained_transaction_path"])
        _require(path not in paths, "native sanitation receipt path repeats")
        paths.add(path)
        descriptor = _open_directory_chain(Path(path), create=False)
        try:
            opened = os.fstat(descriptor)
            expected_directory = receipt["retained_transaction_identity"]
            assert isinstance(expected_directory, Mapping)
            stubs = receipt["retained_stubs"]
            assert isinstance(stubs, list)
            _require(
                (opened.st_dev, opened.st_ino)
                == (
                    expected_directory["device"],
                    expected_directory["inode"],
                )
                and set(os.listdir(descriptor))
                == {str(row["retained_name"]) for row in stubs},
                "native sanitation retained directory differs on reopen",
            )
            for row in stubs:
                assert isinstance(row, Mapping)
                payload, identity = _read_regular_at(
                    descriptor,
                    str(row["retained_name"]),
                    "native sanitation retained stub reopen",
                )
                _require(
                    payload == b""
                    and identity[0] == row["device"]
                    and identity[1] == row["inode"]
                    and identity[3] == row["size_bytes"] == 0
                    and identity[5] == row["sha256"],
                    "native sanitation retained stub differs on reopen",
                )
                stub_count += 1
        finally:
            os.close(descriptor)
        validated_receipts.append(receipt)
    _require(
        len(validated_receipts) == 18 and stub_count == 306,
        "native sanitation aggregate closure differs",
    )
    return validated_receipts, stub_count


def _build_prepublication_execution_closure(
    *,
    work_root: Path,
    work_descriptor: int,
    work_identity: tuple[int, int],
    journal: _CorrectiveExecutionJournal,
    input_sanitation_receipt: Mapping[str, object],
) -> Mapping[str, object]:
    """Seal the immutable journal/sanitation tree before artifact publication."""

    opened = os.fstat(work_descriptor)
    _require(
        (opened.st_dev, opened.st_ino) == work_identity,
        "corrective prepublication work descriptor identity differs",
    )
    _verify_directory_path_identity(work_root, work_identity)
    entries = journal._reopen_all()
    _require(
        len(entries) == journal.entry_count == 36
        and journal.evidence_count == journal.completed_call_count == 18,
        "corrective prepublication journal closure differs",
    )
    journal_entry_bindings = []
    journal_descriptor = _open_directory_chain(journal.root, create=False)
    try:
        for path, entry in zip(journal.paths, entries):
            payload, _ = _read_regular_at(
                journal_descriptor,
                path.name,
                "corrective journal closure entry",
            )
            journal_entry_bindings.append(
                {
                    "name": path.name,
                    "sequence_ordinal": entry["sequence_ordinal"],
                    "request_ordinal": entry["request_ordinal"],
                    "entry_kind": entry["entry_kind"],
                    "previous_entry_sha256": entry[
                        "previous_entry_sha256"
                    ],
                    "entry_sha256": entry["entry_sha256"],
                    "file_sha256": hashlib.sha256(payload).hexdigest(),
                    "size_bytes": len(payload),
                }
            )
    finally:
        os.close(journal_descriptor)
    input_payload, _ = _read_regular_at(
        work_descriptor,
        INPUT_SANITATION_RECEIPT_NAME,
        "corrective input sanitation receipt closure",
    )
    _require(
        input_payload
        == canonical_artifact_file_bytes(input_sanitation_receipt),
        "corrective input sanitation receipt differs in closure",
    )
    native_receipts, retained_stub_count = (
        _reopen_native_sanitation_receipts(journal.cleanup_receipts)
    )
    recursive_entries = _recursive_regular_file_manifest(work_descriptor)
    recursive_entries.sort(key=lambda row: str(row["relative_path"]))
    return _seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_prepublication_execution_closure",
            "status": "sanitation_and_journal_closed_pending_publication",
            "work_root_path": os.fspath(work_root),
            "work_root_identity": {
                "device": work_identity[0],
                "inode": work_identity[1],
            },
            "journal": {
                "entry_count": journal.entry_count,
                "evidence_count": journal.evidence_count,
                "completed_call_count": journal.completed_call_count,
                "tail_sha256": journal.tail_sha256,
            },
            "journal_entry_bindings": journal_entry_bindings,
            "journal_entry_binding_manifest_sha256": canonical_sha256(
                journal_entry_bindings
            ),
            "input_sanitation_receipt": input_sanitation_receipt,
            "input_sanitation_receipt_file_sha256": hashlib.sha256(
                input_payload
            ).hexdigest(),
            "native_sanitation_receipt_count": len(native_receipts),
            "native_retained_stub_count": retained_stub_count,
            "native_sanitation_receipts": native_receipts,
            "native_sanitation_receipt_manifest_sha256": canonical_sha256(
                native_receipts
            ),
            "recursive_entry_count": len(recursive_entries),
            "recursive_entries": recursive_entries,
            "recursive_manifest_sha256": canonical_sha256(
                recursive_entries
            ),
            "expected_executor_publication_receipt_name": (
                EXECUTOR_PUBLICATION_RECEIPT_NAME
            ),
        },
        "prepublication_closure_sha256",
    )
def _cleanup_owned_staging(
    *,
    parent_descriptor: int,
    parent_path: Path,
    staging_descriptor: int,
    staging_name: str,
    staging_identity: tuple[int, int],
    file_identities: Mapping[str, tuple[int, int, int, int, int, str]],
) -> Path:
    """Quarantine, sanitize pinned staging inodes, and retain zero-byte stubs."""

    _validate_owned_directory_at(
        parent_descriptor=parent_descriptor,
        directory_descriptor=staging_descriptor,
        name=staging_name,
        expected_identity=staging_identity,
        expected_files=file_identities,
        label="corrective staging cleanup",
    )
    quarantine_name = f".{staging_name}.cleanup-{uuid.uuid4().hex}"
    quarantine_path = parent_path / quarantine_name
    renamed = False
    sanitation_progress = False
    try:
        _rename_directory_exclusive(
            parent_descriptor,
            staging_name,
            quarantine_name,
        )
        renamed = True
        quarantined = os.stat(
            quarantine_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(quarantined.st_mode)
            and (quarantined.st_dev, quarantined.st_ino) == staging_identity,
            "corrective staging quarantine identity differs",
        )
        private_files: dict[str, tuple[int, int, int, int, int, str]] = {}
        for filename, identity in file_identities.items():
            private_name = f".owned-staging-{uuid.uuid4().hex}"
            _rename_directory_exclusive(
                staging_descriptor,
                filename,
                private_name,
            )
            _, current = _read_regular_at(
                staging_descriptor,
                private_name,
                "corrective quarantined staging leaf",
            )
            _require(
                current == identity,
                "foreign staging leaf was quarantined and preserved",
            )
            private_files[private_name] = identity
        _require(
            set(os.listdir(staging_descriptor)) == set(private_files),
            "corrective staging quarantine leaf set changed",
        )
        sanitation_files: dict[str, tuple[int, int, int, int, int, str]] = {}
        for private_name, identity in private_files.items():
            sanitation_name = f".owned-staging-sanitized-stub-{uuid.uuid4().hex}"
            _rename_directory_exclusive(
                staging_descriptor,
                private_name,
                sanitation_name,
            )
            _, current = _read_regular_at(
                staging_descriptor,
                sanitation_name,
                "corrective staging sanitation leaf",
            )
            _require(
                current == identity,
                "foreign staging leaf reached the sanitation set; preserved",
            )
            sanitation_files[sanitation_name] = identity
        for sanitation_name, identity in sanitation_files.items():
            sanitation_progress = True
            _sanitize_regular_at(
                staging_descriptor,
                sanitation_name,
                identity,
                "corrective staging retained leaf",
            )
        _require(
            set(os.listdir(staging_descriptor)) == set(sanitation_files),
            "corrective staging sanitation leaf set differs",
        )
        for sanitation_name in sanitation_files:
            metadata = os.stat(
                sanitation_name,
                dir_fd=staging_descriptor,
                follow_symlinks=False,
            )
            _require(
                stat.S_ISREG(metadata.st_mode) and metadata.st_size == 0,
                "corrective staging retained stub differs",
            )
        os.fsync(staging_descriptor)
        os.fsync(parent_descriptor)
        return quarantine_path
    except BaseException as primary_error:
        wrapped = CorrectiveDiagnosticExecutionError(
                "corrective staging cleanup failed"
                + (
                " after irreversible sanitation progress"
                if sanitation_progress
                else "; evidence preserved"
            )
        )
        wrapped.primary_error = primary_error  # type: ignore[attr-defined]
        if not sanitation_progress:
            wrapped.preserved_staging_path = (  # type: ignore[attr-defined]
                quarantine_path if renamed else parent_path / staging_name
            )
        elif renamed:
            wrapped.sanitized_staging_path = quarantine_path  # type: ignore[attr-defined]
        raise wrapped from primary_error


def _quarantine_directory_at(
    *,
    parent_descriptor: int,
    parent_path: Path,
    source_name: str,
    expected_identity: tuple[int, int],
) -> Path:
    current = os.stat(
        source_name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    _require(
        stat.S_ISDIR(current.st_mode)
        and (current.st_dev, current.st_ino) == expected_identity,
        "corrective published bundle identity differs before quarantine",
    )
    quarantine_name = (
        f".{source_name}.mirmir-untrusted-{uuid.uuid4().hex}"
    )
    _rename_directory_exclusive(
        parent_descriptor,
        source_name,
        quarantine_name,
    )
    quarantined = os.stat(
        quarantine_name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    _require(
        stat.S_ISDIR(quarantined.st_mode)
        and (quarantined.st_dev, quarantined.st_ino) == expected_identity,
        "corrective untrusted bundle quarantine identity differs",
    )
    os.fsync(parent_descriptor)
    return parent_path / quarantine_name


def _quarantine_published_bundle(destination: Path) -> Path:
    """Move a published directory out of its success name without overwrite."""

    parent_descriptor = os.open(
        destination.parent,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    quarantine_name = (
        f".{destination.name}.mirmir-untrusted-{uuid.uuid4().hex}"
    )
    try:
        before = os.stat(
            destination.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(before.st_mode),
            "published corrective bundle is not a directory",
        )
        _rename_directory_exclusive(
            parent_descriptor,
            destination.name,
            quarantine_name,
        )
        after = os.stat(
            quarantine_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(after.st_mode)
            and (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino),
            "quarantined corrective bundle identity differs",
        )
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    return destination.parent / quarantine_name


def _finalize_completed_execution_evidence(
    *,
    output_root: Path,
    work_root: Path,
    work_descriptor: int,
    work_identity: tuple[int, int],
    prepublication_closure: Mapping[str, object],
    postcommit_guard: Mapping[str, object],
    coordinate_artifact: Mapping[str, object],
    risk_artifact: Mapping[str, object],
    envelope: Mapping[str, object],
) -> Mapping[str, object]:
    """Append the executor-scoped publication receipt and reopen full closure."""

    _verify_directory_path_identity(work_root, work_identity)
    published_descriptor = _open_directory_chain(output_root, create=False)
    try:
        expected_documents = {
            COORDINATE_ARTIFACT_NAME: (
                coordinate_artifact,
                "artifact_sha256",
            ),
            RISK_ARTIFACT_NAME: (risk_artifact, "artifact_sha256"),
            ENVELOPE_NAME: (envelope, "envelope_sha256"),
        }
        _require(
            set(os.listdir(published_descriptor)) == set(expected_documents),
            "published corrective bundle leaf set differs during completion",
        )
        published_bindings: dict[str, Mapping[str, object]] = {}
        for name, (document, self_hash_field) in expected_documents.items():
            payload, _ = _read_regular_at(
                published_descriptor,
                name,
                "published corrective completion artifact",
            )
            expected_payload = canonical_artifact_file_bytes(document)
            _require(
                payload == expected_payload
                and _is_sha256(document.get(self_hash_field)),
                "published corrective completion artifact differs",
            )
            published_bindings[name] = {
                "self_hash_field": self_hash_field,
                "self_sha256": document[self_hash_field],
                "file_sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
    finally:
        os.close(published_descriptor)
    guard = _validated_official_guard(postcommit_guard)
    publication_receipt = _seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_executor_publication_receipt",
            "status": (
                "executor_publication_validated_pending_cli_resource_close"
            ),
            "published_output_root": os.fspath(output_root),
            "prepublication_closure_sha256": prepublication_closure[
                "prepublication_closure_sha256"
            ],
            "published_artifacts": published_bindings,
            "postcommit_live_holdout_guard": guard,
            "postcommit_live_holdout_guard_sha256": canonical_sha256(guard),
        },
        "receipt_sha256",
    )
    receipt_payload = canonical_artifact_file_bytes(publication_receipt)
    receipt_identity = _write_new_regular(
        Path(EXECUTOR_PUBLICATION_RECEIPT_NAME),
        receipt_payload,
        parent_descriptor=work_descriptor,
    )
    assert receipt_identity is not None
    os.fsync(work_descriptor)
    reopened_receipt, reopened_identity = _read_regular_at(
        work_descriptor,
        EXECUTOR_PUBLICATION_RECEIPT_NAME,
        "executor publication receipt reopen",
    )
    _require(
        reopened_receipt == receipt_payload
        and reopened_identity == receipt_identity,
        "executor publication receipt differs after durable reopen",
    )
    _reopen_native_sanitation_receipts(
        prepublication_closure["native_sanitation_receipts"]
    )
    completed_entries = _recursive_regular_file_manifest(work_descriptor)
    completed_entries.sort(key=lambda row: str(row["relative_path"]))
    expected_entries = list(prepublication_closure["recursive_entries"])
    expected_entries.append(
        {
            "relative_path": EXECUTOR_PUBLICATION_RECEIPT_NAME,
            "entry_kind": "regular_file",
            "size_bytes": len(receipt_payload),
            "file_sha256": hashlib.sha256(receipt_payload).hexdigest(),
        }
    )
    expected_entries.sort(key=lambda row: str(row["relative_path"]))
    _require(
        completed_entries == expected_entries,
        "completed corrective evidence tree differs from its planned closure",
    )
    return _seal(
        {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_corrective_completed_evidence_binding",
            "work_root_path": os.fspath(work_root),
            "work_root_identity": {
                "device": work_identity[0],
                "inode": work_identity[1],
            },
            "prepublication_execution_closure": prepublication_closure,
            "executor_publication_receipt": publication_receipt,
            "executor_publication_receipt_file_sha256": hashlib.sha256(
                receipt_payload
            ).hexdigest(),
            "completed_recursive_entry_count": len(completed_entries),
            "completed_recursive_entries": completed_entries,
            "completed_recursive_manifest_sha256": canonical_sha256(
                completed_entries
            ),
        },
        "completed_evidence_binding_sha256",
    )


def publish_corrective_diagnostic_bundle(
    output_root: Path,
    *,
    coordinate_artifact: Mapping[str, object],
    risk_artifact: Mapping[str, object],
    envelope: Mapping[str, object],
    precommit_guard: object | None = None,
    postcommit_guard: object | None = None,
) -> Path:
    """Publish three validated siblings by one exclusive durable directory rename."""

    coordinate = validate_coordinate_anisotropy_artifact(coordinate_artifact)
    risk = validate_risk_state_artifact(risk_artifact)
    coordinate_payload = canonical_artifact_file_bytes(coordinate)
    risk_payload = canonical_artifact_file_bytes(risk)
    validated_envelope = validate_corrective_diagnostic_envelope(
        envelope,
        coordinate_artifact_payload=coordinate_payload,
        risk_state_artifact_payload=risk_payload,
    )
    envelope_payload = canonical_artifact_file_bytes(validated_envelope)

    raw_destination = Path(output_root)
    destination = (
        raw_destination
        if raw_destination.is_absolute()
        else Path.cwd() / raw_destination
    )
    _require(
        destination.name not in {"", ".", ".."}
        and all(part not in {"", ".", ".."} for part in destination.parts[1:]),
        "output root is invalid",
    )
    parent = destination.parent
    parent_descriptor = _open_directory_chain(parent, create=True)
    parent_metadata = os.fstat(parent_descriptor)
    parent_identity = (parent_metadata.st_dev, parent_metadata.st_ino)
    _verify_directory_path_identity(parent, parent_identity)
    staging_name = f".{destination.name}.mirmir-uncommitted-{uuid.uuid4().hex}"
    staging_descriptor = -1
    staging_identity: tuple[int, int] | None = None
    file_identities: dict[
        str,
        tuple[int, int, int, int, int, str],
    ] = {}
    staging_created = False
    renamed = False
    try:
        try:
            os.stat(
                destination.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError(destination)
        os.mkdir(staging_name, 0o700, dir_fd=parent_descriptor)
        staging_created = True
        staging_descriptor = os.open(
            staging_name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        staging_metadata = os.fstat(staging_descriptor)
        staging_identity = (
            staging_metadata.st_dev,
            staging_metadata.st_ino,
        )
        _require(
            stat.S_ISDIR(staging_metadata.st_mode)
            and staging_metadata.st_uid == os.getuid()
            and stat.S_IMODE(staging_metadata.st_mode) == 0o700
            and os.listdir(staging_descriptor) == [],
            "corrective publication staging directory is not private and empty",
        )
        payloads = {
            COORDINATE_ARTIFACT_NAME: coordinate_payload,
            RISK_ARTIFACT_NAME: risk_payload,
            ENVELOPE_NAME: envelope_payload,
        }
        for filename, payload in payloads.items():
            identity = _write_new_regular(
                Path(filename),
                payload,
                parent_descriptor=staging_descriptor,
            )
            assert identity is not None
            file_identities[filename] = identity
        _validate_owned_directory_at(
            parent_descriptor=parent_descriptor,
            directory_descriptor=staging_descriptor,
            name=staging_name,
            expected_identity=staging_identity,
            expected_files=file_identities,
            label="corrective staging precommit",
        )
        reopened_coordinate, _ = _read_regular_at(
            staging_descriptor,
            COORDINATE_ARTIFACT_NAME,
            "coordinate artifact staging reopen",
        )
        reopened_risk, _ = _read_regular_at(
            staging_descriptor,
            RISK_ARTIFACT_NAME,
            "risk artifact staging reopen",
        )
        reopened_envelope_payload, _ = _read_regular_at(
            staging_descriptor,
            ENVELOPE_NAME,
            "envelope staging reopen",
        )
        _require(
            reopened_coordinate == coordinate_payload
            and reopened_risk == risk_payload
            and reopened_envelope_payload == envelope_payload,
            "corrective staging payload differs after descriptor reopen",
        )
        reopened_envelope = json.loads(reopened_envelope_payload)
        validate_corrective_diagnostic_envelope(
            reopened_envelope,
            coordinate_artifact_payload=reopened_coordinate,
            risk_state_artifact_payload=reopened_risk,
        )
        os.fsync(staging_descriptor)
        _verify_directory_path_identity(parent, parent_identity)
        if precommit_guard is not None:
            _require(
                callable(precommit_guard),
                "corrective publication precommit guard is not callable",
            )
            precommit_guard()
        _verify_directory_path_identity(parent, parent_identity)
        _validate_owned_directory_at(
            parent_descriptor=parent_descriptor,
            directory_descriptor=staging_descriptor,
            name=staging_name,
            expected_identity=staging_identity,
            expected_files=file_identities,
            label="corrective staging commit",
        )
        _rename_directory_exclusive(
            parent_descriptor,
            staging_name,
            destination.name,
        )
        renamed = True
        published = os.stat(
            destination.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(published.st_mode)
            and (published.st_dev, published.st_ino) == staging_identity,
            "published corrective directory identity differs",
        )
        try:
            os.stat(
                staging_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise CorrectiveDiagnosticExecutionError(
                "corrective staging name survived publication"
            )
        final_descriptor = os.open(
            destination.name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        try:
            _validate_owned_directory_at(
                parent_descriptor=parent_descriptor,
                directory_descriptor=final_descriptor,
                name=destination.name,
                expected_identity=staging_identity,
                expected_files=file_identities,
                label="published corrective bundle",
            )
            final_coordinate, _ = _read_regular_at(
                final_descriptor,
                COORDINATE_ARTIFACT_NAME,
                "published coordinate artifact",
            )
            final_risk, _ = _read_regular_at(
                final_descriptor,
                RISK_ARTIFACT_NAME,
                "published risk artifact",
            )
            final_envelope_payload, _ = _read_regular_at(
                final_descriptor,
                ENVELOPE_NAME,
                "published envelope",
            )
            _require(
                final_coordinate == coordinate_payload
                and final_risk == risk_payload
                and final_envelope_payload == envelope_payload,
                "published corrective payload differs from precommit bytes",
            )
            validate_corrective_diagnostic_envelope(
                json.loads(final_envelope_payload),
                coordinate_artifact_payload=final_coordinate,
                risk_state_artifact_payload=final_risk,
            )
            os.fsync(final_descriptor)
        finally:
            os.close(final_descriptor)
        os.fsync(parent_descriptor)
        _verify_directory_path_identity(parent, parent_identity)
        if postcommit_guard is not None:
            _require(
                callable(postcommit_guard),
                "corrective publication postcommit guard is not callable",
            )
            postcommit_guard()
        _verify_directory_path_identity(parent, parent_identity)
    except BaseException as primary_error:
        if renamed and staging_identity is not None:
            try:
                untrusted = _quarantine_directory_at(
                    parent_descriptor=parent_descriptor,
                    parent_path=parent,
                    source_name=destination.name,
                    expected_identity=staging_identity,
                )
                primary_error.untrusted_bundle_path = untrusted  # type: ignore[attr-defined]
            except BaseException as quarantine_error:
                combined = CorrectiveDiagnosticExecutionError(
                    "corrective publication failed after rename and quarantine failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.quarantine_error = quarantine_error  # type: ignore[attr-defined]
                raise combined from primary_error
        elif (
            staging_created
            and staging_descriptor >= 0
            and staging_identity is not None
        ):
            try:
                retained_staging = _cleanup_owned_staging(
                    parent_descriptor=parent_descriptor,
                    parent_path=parent,
                    staging_descriptor=staging_descriptor,
                    staging_name=staging_name,
                    staging_identity=staging_identity,
                    file_identities=file_identities,
                )
                primary_error.retained_sanitized_staging_path = (  # type: ignore[attr-defined]
                    retained_staging
                )
            except BaseException as cleanup_error:
                combined = CorrectiveDiagnosticExecutionError(
                    "corrective publication and staging cleanup both failed"
                )
                combined.primary_error = primary_error  # type: ignore[attr-defined]
                combined.cleanup_error = cleanup_error  # type: ignore[attr-defined]
                combined.preserved_staging_path = getattr(  # type: ignore[attr-defined]
                    cleanup_error,
                    "preserved_staging_path",
                    parent / staging_name,
                )
                raise combined from primary_error
        raise
    finally:
        if staging_descriptor >= 0:
            os.close(staging_descriptor)
        os.close(parent_descriptor)
    return destination


def _metric_rows(
    *,
    block_id: str | None,
    route: str,
    input_frame_sha256: str,
    target: PlanarFrame,
    raw: PlanarFrame,
    writer: WriterCapability,
    writer_key: str,
    context: CandidateContext,
) -> list[dict[str, object]]:
    raw_metrics = dict(corpus_metric_bundle(target, raw))
    writer_result = writer.round_trip(
        control_key=writer_key,
        frame=raw,
        context=context,
    )
    decoded = _validate_writer_round_trip(
        writer=writer,
        result=writer_result,
        control_key=writer_key,
        raw_frame=raw,
        context=context,
    )
    decoded_metrics = dict(corpus_metric_bundle(target, decoded))
    decoded_metrics["writer_y_psnr_contribution_db"] = (
        float(decoded_metrics["y_psnr_db"])
        - float(raw_metrics["y_psnr_db"])
    )
    common = {
        "target_route": route,
        "input_frame_sha256": input_frame_sha256,
    }
    if block_id is not None:
        common["block_id"] = block_id
    return [
        _seal(
            {
                **common,
                "comparison_domain": "engine_raw",
                "candidate_output_frame_sha256": frame_sha256(raw),
                "writer_evidence_sha256": None,
                "metrics": raw_metrics,
            },
            "metric_row_sha256",
        ),
        _seal(
            {
                **common,
                "comparison_domain": "container_decoded",
                "candidate_output_frame_sha256": frame_sha256(decoded),
                "writer_evidence_sha256": writer_result.evidence_sha256,
                "metrics": decoded_metrics,
            },
            "metric_row_sha256",
        ),
    ]


class CorrectiveDiagnosticExecutor:
    """Execute the exact 32-block/30-risk-cell development experiment."""

    def __init__(
        self,
        *,
        repository_root: Path,
        output_root: Path,
        work_parent: Path,
        bound_inputs: object,
        loaded_development_samples: Sequence[
            tuple[Mapping[str, object], PlanarFrame]
        ],
        degradation_cache: LockedDegradationCache,
        native: CorrectiveNativeCapability,
        writer: WriterCapability,
        candidate_vector: Mapping[str, object],
        coordinate_contract_path: Path,
        video_profile_contract_path: Path,
        g04_lock_file_sha256: str,
        g05_lock_file_sha256: str,
        corrective_preregistration_file_sha256: str,
        corrective_preregistration_sha256: str,
    ) -> None:
        self.repository_root = repository_root.resolve(strict=True)
        self.output_root = output_root.absolute()
        self.work_parent = work_parent.resolve(strict=True)
        self.bound = bound_inputs
        self.loaded_samples = tuple(loaded_development_samples)
        self.cache = degradation_cache
        self.native = native
        self.writer = writer
        self.vector = dict(candidate_vector)
        self.coordinate_contract_path = coordinate_contract_path.resolve(strict=True)
        self.video_contract_path = video_profile_contract_path.resolve(strict=True)
        self.g04_lock_file_sha256 = g04_lock_file_sha256
        self.g05_lock_file_sha256 = g05_lock_file_sha256
        self.corrective_preregistration_file_sha256 = (
            corrective_preregistration_file_sha256
        )
        self.corrective_preregistration_sha256 = (
            corrective_preregistration_sha256
        )
        self.completed_evidence_path: Path | None = None
        self.completed_evidence_binding: Mapping[str, object] | None = None
        self._prepublication_closure: Mapping[str, object] | None = None
        self._postcommit_guard: Mapping[str, object] | None = None
        self._published_documents: tuple[
            Mapping[str, object],
            Mapping[str, object],
            Mapping[str, object],
        ] | None = None

    def _bound_interface(self) -> tuple[Mapping[str, object], object, object]:
        documents = getattr(self.bound, "documents", None)
        record = getattr(self.bound, "record", None)
        verify = getattr(self.bound, "verify_unchanged", None)
        _require(
            isinstance(documents, Mapping)
            and callable(record)
            and callable(verify),
            "corrective executor requires immutable bound inputs",
        )
        return documents, record, verify

    def _request(
        self,
        *,
        request_id: str,
        route: str,
        input_path: Path,
        input_payload: bytes,
        output_directory: Path,
        input_frame: PlanarFrame,
        target: PlanarFrame,
    ) -> dict[str, object]:
        configuration = self.native.configuration
        contract_route = contract_route_for_evaluator_route(route)
        descriptors = []
        for ordinal, (coordinate, anisotropy) in enumerate(
            (c, a) for c in COORDINATE_CELLS for a in ANISOTROPY_CELLS
        ):
            descriptors.append(
                {
                    "ordinal": ordinal,
                    "coordinate_cell_id": coordinate["cell_id"],
                    "anisotropy_cell_id": anisotropy["cell_id"],
                    "output_path": os.fspath(
                        output_directory
                        / (
                            f"cell-{ordinal:02d}-{coordinate['cell_id']}-"
                            f"{anisotropy['cell_id']}.nv12"
                        )
                    ),
                }
            )
        production_path = output_directory / "production-v2-reference.nv12"
        return {
            "schema_version": "1.0.0",
            "operation": "diagnose_corrective_frame",
            "configuration_id": configuration["configuration_id"],
            "compiler_inputs_sha256": configuration[
                "compiler_inputs_sha256"
            ],
            "coordinate_model_contract_path": os.fspath(
                self.coordinate_contract_path
            ),
            "coordinate_model_contract_sha256": _sha256_file(
                self.coordinate_contract_path
            ),
            "analysis_grid_source_step": self.vector[
                f"{contract_route}_analysis_grid_source_step"
            ],
            "output_descriptors": descriptors,
            "production_v2_reference_output_path": os.fspath(production_path),
            "frame": {
                "request_id": request_id,
                "route": route,
                "input_path": os.fspath(input_path),
                "input_sha256": hashlib.sha256(input_payload).hexdigest(),
                "input_width": input_frame.y.shape[1],
                "input_height": input_frame.y.shape[0],
                "output_path": os.fspath(production_path),
                "output_width": target.y.shape[1],
                "output_height": target.y.shape[0],
                "pixel_format": "420v",
                "matrix": "BT.709",
                "range": "video",
                "chroma_siting": "left",
            },
        }

    def run(self) -> Path:
        work_parent_descriptor = _open_directory_chain(
            self.work_parent,
            create=False,
        )
        work_descriptor = -1
        try:
            parent_metadata = os.fstat(work_parent_descriptor)
            _verify_directory_path_identity(
                self.work_parent,
                (parent_metadata.st_dev, parent_metadata.st_ino),
            )
            work_name = f".mirmir-corrective-execution-{uuid.uuid4().hex}"
            work_root = self.work_parent / work_name
            os.mkdir(work_name, 0o700, dir_fd=work_parent_descriptor)
            os.fsync(work_parent_descriptor)
            work_descriptor = os.open(
                work_name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=work_parent_descriptor,
            )
            work_metadata = os.fstat(work_descriptor)
            work_identity = (work_metadata.st_dev, work_metadata.st_ino)
            _require(
                stat.S_ISDIR(work_metadata.st_mode)
                and work_metadata.st_uid == os.getuid()
                and stat.S_IMODE(work_metadata.st_mode) == 0o700
                and os.listdir(work_descriptor) == [],
                "corrective work root is not a captured private directory",
            )
            journal = _CorrectiveExecutionJournal(
                work_root,
                expected_work_identity=work_identity,
            )
            try:
                result = self._run(
                    work_root=work_root,
                    work_descriptor=work_descriptor,
                    journal=journal,
                )
            except BaseException as primary_error:
                untrusted = getattr(primary_error, "untrusted_bundle_path", None)
                if isinstance(untrusted, Path):
                    journal.mark_published_untrusted(untrusted)
                verify = getattr(self.bound, "verify_unchanged", None)
                guard_evidence = journal.fresh_guard_evidence(
                    bound=self.bound,
                    verify=verify,
                )
                try:
                    journal.write_failure_manifest(
                        primary_error=primary_error,
                        guard_evidence=guard_evidence,
                    )
                except BaseException as manifest_error:
                    combined = CorrectiveDiagnosticExecutionError(
                        "corrective execution and durable failure recording both failed"
                    )
                    combined.primary_error = primary_error  # type: ignore[attr-defined]
                    combined.failure_manifest_error = manifest_error  # type: ignore[attr-defined]
                    combined.preserved_work_path = work_root  # type: ignore[attr-defined]
                    raise combined from primary_error
                try:
                    primary_error.preserved_work_path = work_root  # type: ignore[attr-defined]
                except BaseException:
                    combined = CorrectiveDiagnosticExecutionError(
                        "corrective execution failed with durable preserved evidence"
                    )
                    combined.primary_error = primary_error  # type: ignore[attr-defined]
                    combined.preserved_work_path = work_root  # type: ignore[attr-defined]
                    raise combined from primary_error
                raise
            else:
                journal.mark_published()
                try:
                    _require(
                        self._prepublication_closure is not None
                        and self._postcommit_guard is not None
                        and self._published_documents is not None,
                        "corrective completion state is absent after publication",
                    )
                    coordinate, risk, envelope = self._published_documents
                    completed_binding = _finalize_completed_execution_evidence(
                        output_root=result,
                        work_root=work_root,
                        work_descriptor=work_descriptor,
                        work_identity=work_identity,
                        prepublication_closure=self._prepublication_closure,
                        postcommit_guard=self._postcommit_guard,
                        coordinate_artifact=coordinate,
                        risk_artifact=risk,
                        envelope=envelope,
                    )
                    self.completed_evidence_path = work_root
                    self.completed_evidence_binding = completed_binding
                except BaseException as completion_error:
                    postpublication_error = CorrectiveDiagnosticExecutionError(
                        "validated corrective completion evidence finalization failed"
                    )
                    postpublication_error.primary_error = completion_error  # type: ignore[attr-defined]
                    try:
                        untrusted = _quarantine_published_bundle(result)
                        journal.mark_published_untrusted(untrusted)
                        postpublication_error.untrusted_bundle_path = untrusted  # type: ignore[attr-defined]
                    except BaseException as quarantine_error:
                        postpublication_error.quarantine_error = quarantine_error  # type: ignore[attr-defined]
                    guard_evidence = journal.fresh_guard_evidence(
                        bound=self.bound,
                        verify=getattr(self.bound, "verify_unchanged", None),
                    )
                    try:
                        journal.write_failure_manifest(
                            primary_error=postpublication_error,
                            guard_evidence=guard_evidence,
                        )
                    except BaseException as manifest_error:
                        postpublication_error.failure_manifest_error = manifest_error  # type: ignore[attr-defined]
                    postpublication_error.preserved_work_path = work_root  # type: ignore[attr-defined]
                    raise postpublication_error from completion_error
                return result
        finally:
            if work_descriptor >= 0:
                os.close(work_descriptor)
            os.close(work_parent_descriptor)

    def _run(
        self,
        *,
        work_root: Path,
        work_descriptor: int,
        journal: _CorrectiveExecutionJournal,
    ) -> Path:
        documents, record, verify = self._bound_interface()
        journal.verify_guard(verify)
        _require(
            len(self.loaded_samples) == 6,
            "corrective development sample count differs",
        )
        _require(
            _is_sha256(self.g04_lock_file_sha256)
            and _is_sha256(self.g05_lock_file_sha256)
            and _is_sha256(self.corrective_preregistration_file_sha256)
            and _is_sha256(self.corrective_preregistration_sha256),
            "G04/G05 or corrective preregistration hash is invalid",
        )
        configuration = self.native.configuration
        _require(
            configuration.get("candidate_vector") == self.vector,
            "native configuration differs from the requested candidate",
        )
        sample_lock = documents["development_sample_lock"]
        corpus = documents["corpus_lock"]
        degradation_policy = documents["degradation_policy"]
        metric_policy = documents["metric_policy_seed"]
        implementation_manifest = documents[
            "quality_harness_implementation_manifest"
        ]
        _require(
            isinstance(sample_lock, Mapping)
            and isinstance(corpus, Mapping)
            and isinstance(degradation_policy, Mapping)
            and isinstance(metric_policy, Mapping)
            and isinstance(implementation_manifest, Mapping),
            "corrective bound documents are incomplete",
        )
        official_guard = _validated_official_guard(
            documents.get("live_holdout_preopen_verification")
        )
        samples_by_id = {
            str(row["source_asset_id"]): row
            for row in sample_lock["samples"]
        }
        _require(
            [str(asset["source_asset_id"]) for asset, _ in self.loaded_samples]
            == [str(row["source_asset_id"]) for row in sample_lock["samples"]],
            "loaded development sample order differs from the lock",
        )
        input_root = work_root / "inputs"
        os.mkdir("inputs", 0o700, dir_fd=work_descriptor)
        os.fsync(work_descriptor)
        input_descriptor = os.open(
            "inputs",
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=work_descriptor,
        )
        try:
            input_metadata = os.fstat(input_descriptor)
            input_identity = (
                input_metadata.st_dev,
                input_metadata.st_ino,
            )
            _require(
                stat.S_ISDIR(input_metadata.st_mode)
                and input_metadata.st_uid == os.getuid()
                and stat.S_IMODE(input_metadata.st_mode) == 0o700
                and os.listdir(input_descriptor) == [],
                "corrective input root is not a captured private directory",
            )
        finally:
            os.close(input_descriptor)
        input_file_identities: dict[
            str,
            tuple[int, int, int, int, int, str],
        ] = {}
        coordinate_observations: dict[str, list[dict[str, object]]] = {
            f"{route}-{coordinate}-{anisotropy}": []
            for route, coordinate, anisotropy in ROUTE_BLOCK_SPECS
        }
        reference_observations: list[dict[str, object]] = []
        risk_records: list[dict[str, object]] = []
        native_records: list[dict[str, object]] = []
        generic_luts: dict[str, dict[str, object]] = {}
        production_luts: dict[str, dict[str, object]] = {}
        coordinate_file_hash = _sha256_file(self.coordinate_contract_path)
        video_file_hash = _sha256_file(self.video_contract_path)
        coordinate_document = json.loads(
            self.coordinate_contract_path.read_bytes()
        )
        video_document = json.loads(self.video_contract_path.read_bytes())
        expected_observation_count_by_route = {
            contract_route: sum(
                len(
                    spatial_degradation_profiles(
                        self.bound,
                        str(sample["target_route"]),
                    )
                )
                for sample in sample_lock["samples"]
                if contract_route_for_evaluator_route(
                    str(sample["target_route"])
                )
                == contract_route
            )
            for contract_route in ROUTES
        }
        development_sample_dimension_sha256 = canonical_sha256(
            [
                {
                    "ordinal": ordinal,
                    "source_asset_id": sample["source_asset_id"],
                    "target_route": sample["target_route"],
                    "target_frame_sha256": sample["target_frame_sha256"],
                }
                for ordinal, sample in enumerate(sample_lock["samples"])
            ]
        )
        degradation_profile_dimension_sha256 = canonical_sha256(
            [
                {
                    "target_route": evaluator_route,
                    "profiles": [
                        {
                            "ordinal": ordinal,
                            "profile_id": profile["id"],
                            "profile_sha256": canonical_sha256(profile),
                        }
                        for ordinal, profile in enumerate(
                            spatial_degradation_profiles(
                                self.bound,
                                evaluator_route,
                            )
                        )
                    ],
                }
                for evaluator_route in ("direct-2x", "direct-3over2")
            ]
        )
        call_ordinal = 0
        try:
            for asset, target in self.loaded_samples:
                source_id = str(asset["source_asset_id"])
                sample = samples_by_id.get(source_id)
                _require(
                    isinstance(sample, Mapping)
                    and frame_sha256(target)
                    == sample.get("target_frame_sha256"),
                    "loaded development pixels differ from their lock",
                )
                route = str(sample["target_route"])
                contract_route = contract_route_for_evaluator_route(route)
                categories = asset.get("categories")
                _require(
                    isinstance(categories, list)
                    and categories
                    and len(categories) == len(set(categories)),
                    "development asset categories are invalid",
                )
                for profile in spatial_degradation_profiles(self.bound, route):
                    journal.verify_guard(verify)
                    profile_id = str(profile["id"])
                    profile_hash = canonical_sha256(profile)
                    input_frame = self.cache.get_or_create(
                        source_asset_id=source_id,
                        target_frame=target,
                        target_frame_sha256=str(sample["target_frame_sha256"]),
                        profile_id=profile_id,
                        builder=lambda frame, p=profile: degradation_native_input(
                            frame,
                            p,
                        ),
                    )
                    input_payload = _planar_to_video_range_nv12(input_frame)
                    input_hash = hashlib.sha256(input_payload).hexdigest()
                    input_name = f"{input_hash}.nv12"
                    input_path = input_root / input_name
                    input_descriptor = os.open(
                        "inputs",
                        os.O_RDONLY
                        | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=work_descriptor,
                    )
                    try:
                        opened_input_root = os.fstat(input_descriptor)
                        current_input_root = os.stat(
                            "inputs",
                            dir_fd=work_descriptor,
                            follow_symlinks=False,
                        )
                        _require(
                            (opened_input_root.st_dev, opened_input_root.st_ino)
                            == input_identity
                            == (
                                current_input_root.st_dev,
                                current_input_root.st_ino,
                            ),
                            "corrective input root identity changed",
                        )
                        try:
                            reopened_payload, input_file_identity = (
                                _read_regular_at(
                                    input_descriptor,
                                    input_name,
                                    "cached corrective native input",
                                )
                            )
                        except FileNotFoundError:
                            created_identity = _write_new_regular(
                                Path(input_name),
                                input_payload,
                                parent_descriptor=input_descriptor,
                            )
                            assert created_identity is not None
                            input_file_identity = created_identity
                        else:
                            _require(
                                reopened_payload == input_payload
                                and input_file_identity[5] == input_hash,
                                "cached native input file differs",
                            )
                        previous_input_identity = input_file_identities.get(
                            input_name
                        )
                        _require(
                            previous_input_identity is None
                            or previous_input_identity == input_file_identity,
                            "cached native input identity changed",
                        )
                        input_file_identities[input_name] = input_file_identity
                    finally:
                        os.close(input_descriptor)
                    request_id = canonical_sha256(
                        {
                            "ordinal": call_ordinal,
                            "source_asset_id": source_id,
                            "degradation_profile_id": profile_id,
                            "target_route": route,
                            "input_frame_sha256": frame_sha256(input_frame),
                        }
                    )
                    output_directory = work_root / f"outputs-{call_ordinal:06d}"
                    request = self._request(
                        request_id=request_id,
                        route=route,
                        input_path=input_path,
                        input_payload=input_payload,
                        output_directory=output_directory,
                        input_frame=input_frame,
                        target=target,
                    )
                    journal.begin_call(call_ordinal, request)
                    released = False
                    cleanup_receipt: Mapping[str, object] | None = None
                    transaction_active = False
                    try:
                        response = self.native.diagnose_corrective_frame(request)
                        transaction_active = True
                        diagnostic = response.get("corrective_diagnostic")
                        _require(
                            isinstance(diagnostic, Mapping)
                            and diagnostic.get("status")
                            == "development_diagnostic_no_selection"
                            and diagnostic.get("split") == "development"
                            and diagnostic.get("validation_accessed") is False
                            and diagnostic.get("holdout_accessed") is False
                            and diagnostic.get("selected_winner") is None
                            and diagnostic.get("target_route") == contract_route
                            and all(
                                diagnostic.get(key) == value
                                for key, value in _HASH_CONTRACTS.items()
                            ),
                            "native corrective diagnostic state differs",
                        )
                        assert isinstance(diagnostic, Mapping)
                        journal.mark_native_response(diagnostic)
                        native_diagnostic_hash = canonical_sha256(diagnostic)
                        native_record = _seal(
                            {
                                "ordinal": call_ordinal,
                                "source_asset_id": source_id,
                                "degradation_profile_id": profile_id,
                                "target_route": contract_route,
                                "input_frame_sha256": frame_sha256(
                                    input_frame
                                ),
                                "input_nv12_sha256": input_hash,
                                "request": request,
                                "response": response,
                                "request_sha256": canonical_sha256(request),
                                "response_sha256": canonical_sha256(response),
                                "native_diagnostic_sha256": native_diagnostic_hash,
                            },
                            "native_record_sha256",
                        )
                        native_records.append(native_record)
                        native_hash = native_record["native_record_sha256"]
                        context = CandidateContext(
                            y_shape=target.y.shape,
                            cb_shape=target.cb.shape,
                            cr_shape=target.cr.shape,
                            target_route=route,
                        )
                        generic = diagnostic["generic_lut"]
                        generic_row = {
                            "route": contract_route,
                            "whole_file_sha256": generic[
                                "whole_file_sha256"
                            ],
                            "payload_sha256": generic["payload_sha256"],
                            "entry_count": generic["entry_count"],
                            "serialization_rebind_contract": generic[
                                "serialization_rebind_contract"
                            ],
                            "original_coordinate_policy": generic[
                                "original_coordinate_policy"
                            ],
                            "serialized_coordinate_policy": generic[
                                "serialized_coordinate_policy"
                            ],
                            "serialization_rebind_applied": generic[
                                "serialization_rebind_applied"
                            ],
                            "serialization_rebind_sha256": generic[
                                "serialization_rebind_sha256"
                            ],
                        }
                        previous_generic = generic_luts.get(contract_route)
                        _require(
                            previous_generic is None
                            or previous_generic == generic_row,
                            "generic route LUT changed between development frames",
                        )
                        generic_luts[contract_route] = generic_row
                        cells = diagnostic["cells"]
                        _require(
                            isinstance(cells, list) and len(cells) == 16,
                            "native corrective cell count differs",
                        )
                        common_identity = {
                            "target_route": contract_route,
                            "source_asset_id": source_id,
                            "source_family_id": asset["source_family_id"],
                            "categories": list(categories),
                            "degradation_profile_id": profile_id,
                            "degradation_profile_sha256": profile_hash,
                            "input_frame_sha256": frame_sha256(input_frame),
                        }
                        call_observations: list[dict[str, object]] = []
                        for cell in cells:
                            _require(isinstance(cell, Mapping), "native cell is invalid")
                            block_id = str(cell["block_id"])
                            raw = self.native.reopen_corrective_frame_output(
                                request,
                                Path(str(cell["output_path"])),
                                width=target.y.shape[1],
                                height=target.y.shape[0],
                            )
                            planes = {}
                            for channel in ("y", "cb", "cr"):
                                planes[channel] = _seal(
                                    cell["planes"][channel],
                                    "plane_evidence_sha256",
                                )
                            observation = _seal(
                                {
                                    "block_id": block_id,
                                    **common_identity,
                                    "candidate_output_nv12_sha256": cell[
                                        "output_nv12_sha256"
                                    ],
                                    "candidate_output_frame_sha256": cell[
                                        "output_frame_sha256"
                                    ],
                                    "planes": planes,
                                    "metric_rows": _metric_rows(
                                        block_id=block_id,
                                        route=contract_route,
                                        input_frame_sha256=frame_sha256(
                                            input_frame
                                        ),
                                        target=target,
                                        raw=raw,
                                        writer=self.writer,
                                        writer_key=(
                                            f"corrective-{block_id}-{request_id}"
                                        ),
                                        context=context,
                                    ),
                                    "native_record_sha256": native_hash,
                                },
                                "observation_sha256",
                            )
                            _require(
                                block_id in coordinate_observations,
                                "native block ID is outside the contract",
                            )
                            coordinate_observations[block_id].append(observation)
                            call_observations.append(observation)

                        production = diagnostic["production_v2_reference"]
                        raw_reference = self.native.reopen_corrective_frame_output(
                            request,
                            Path(str(production["output_path"])),
                            width=target.y.shape[1],
                            height=target.y.shape[0],
                        )
                        production_row = {
                            "route": contract_route,
                            "whole_file_sha256": production[
                                "lut_whole_file_sha256"
                            ],
                            "payload_sha256": production[
                                "lut_payload_sha256"
                            ],
                            "entry_count": production["lut_entry_count"],
                        }
                        previous_production = production_luts.get(contract_route)
                        _require(
                            previous_production is None
                            or previous_production == production_row,
                            "production-V2 route LUT changed between frames",
                        )
                        production_luts[contract_route] = production_row
                        production_observation = _seal(
                                {
                                    **common_identity,
                                    "candidate_output_nv12_sha256": production[
                                        "output_nv12_sha256"
                                    ],
                                    "candidate_output_frame_sha256": production[
                                        "output_frame_sha256"
                                    ],
                                    "planes": production["planes"],
                                    "metric_rows": _metric_rows(
                                        block_id=None,
                                        route=contract_route,
                                        input_frame_sha256=frame_sha256(
                                            input_frame
                                        ),
                                        target=target,
                                        raw=raw_reference,
                                        writer=self.writer,
                                        writer_key=(
                                            "corrective-production-v2-"
                                            f"{request_id}"
                                        ),
                                        context=context,
                                    ),
                                    "native_record_sha256": native_hash,
                                },
                                "observation_sha256",
                        )
                        reference_observations.append(production_observation)
                        risk = diagnostic["risk_state"]
                        sealed_cells = [
                            _seal(cell, "cell_sha256")
                            for cell in risk["cells"]
                        ]
                        risk_record = _seal(
                                {
                                    "ordinal": call_ordinal,
                                    "source_asset_id": source_id,
                                    "degradation_profile_id": profile_id,
                                    "degradation_profile_sha256": profile_hash,
                                    "target_route": contract_route,
                                    "input_frame_sha256": frame_sha256(
                                        input_frame
                                    ),
                                    "analysis_grid_source_step": risk[
                                        "analysis_grid_source_step"
                                    ],
                                    "analysis_cell_count": risk[
                                        "analysis_cell_count"
                                    ],
                                    "baseline_analysis_grid_sha256": risk[
                                        "baseline_analysis_grid_sha256"
                                    ],
                                    "native_execution_sha256": native_hash,
                                    "cells": sealed_cells,
                                },
                                "frame_route_record_sha256",
                        )
                        risk_records.append(risk_record)
                        journal.append_call_evidence(
                            request_ordinal=call_ordinal,
                            native_record=native_record,
                            coordinate_observations=call_observations,
                            production_observation=production_observation,
                            risk_record=risk_record,
                            generic_route_lut=generic_row,
                            production_route_lut=production_row,
                        )
                    finally:
                        if transaction_active:
                            try:
                                cleanup_receipt = (
                                    self.native.release_corrective_frame_outputs(
                                        request
                                    )
                                )
                                cleanup_receipt = (
                                    _validated_native_sanitation_receipt(
                                        cleanup_receipt
                                    )
                                )
                                released = True
                                journal.mark_outputs_sanitized()
                            except BaseException:
                                journal.mark_cleanup_failed()
                                raise
                    if not transaction_active:
                        raise CorrectiveDiagnosticExecutionError(
                            "native corrective transaction did not become active"
                        )
                    _require(released, "native corrective outputs were not released")
                    assert cleanup_receipt is not None
                    journal.append_cleanup_receipt(
                        request_ordinal=call_ordinal,
                        native_record_sha256=str(native_hash),
                        native_cleanup_receipt=cleanup_receipt,
                    )
                    journal.verify_guard(verify)
                    call_ordinal += 1

            _require(
                call_ordinal == 18
                and len(reference_observations) == 18
                and len(risk_records) == 18
                and set(generic_luts) == set(ROUTES)
                and set(production_luts) == set(ROUTES),
                "corrective development experiment cardinality differs",
            )
            blocks = []
            for ordinal, (route, coordinate, anisotropy) in enumerate(
                ROUTE_BLOCK_SPECS
            ):
                block_id = f"{route}-{coordinate}-{anisotropy}"
                observations = coordinate_observations[block_id]
                _require(
                    len(observations)
                    == expected_observation_count_by_route[route],
                    "route-cell block development coverage differs from the lock",
                )
                lut = generic_luts[route]
                blocks.append(
                    _seal(
                        {
                            "ordinal": ordinal,
                            "block_id": block_id,
                            "target_route": route,
                            "coordinate_cell_id": coordinate,
                            "anisotropy_cell_id": anisotropy,
                            "generic_lut_whole_file_sha256": lut[
                                "whole_file_sha256"
                            ],
                            "generic_lut_payload_sha256": lut[
                                "payload_sha256"
                            ],
                            "native_execution_sha256": canonical_sha256(
                                [
                                    row["native_record_sha256"]
                                    for row in observations
                                ]
                            ),
                            "observations": observations,
                        },
                        "block_sha256",
                    )
                )
            blocks_by_id = {str(row["block_id"]): row for row in blocks}
            compositions = []
            for ordinal, (composition_id, direct2, direct3) in enumerate(
                COMPOSITION_SPECS
            ):
                compositions.append(
                    _seal(
                        {
                            "ordinal": ordinal,
                            "composition_id": composition_id,
                            "direct_2x_block_id": direct2,
                            "direct_2x_block_sha256": blocks_by_id[direct2][
                                "block_sha256"
                            ],
                            "direct_3_over_2_block_id": direct3,
                            "direct_3_over_2_block_sha256": blocks_by_id[
                                direct3
                            ]["block_sha256"],
                        },
                        "composition_sha256",
                    )
                )

            first_native = reference_observations[0]["native_record_sha256"]
            _require(_is_sha256(first_native), "native record hash is invalid")
            quality_record = record("quality_harness_implementation_manifest")
            native_configuration_provenance = {
                field: configuration[field]
                for field in (
                    "serialized_candidate_vector_sha256",
                    "shared_bank_configuration_sha256",
                    "mapping_sha256",
                    "operator_bank_sha256",
                    "metric_policy_sha256",
                    "calibration_plan_sha256",
                    "corpus_lock_bundle_sha256",
                    "candidate_lut_runtime_manifest_sha256",
                )
            }
            native_configuration_provenance[
                "candidate_vector_sha256"
            ] = native_configuration_provenance.pop(
                "serialized_candidate_vector_sha256"
            )
            _require(
                all(
                    _is_sha256(value)
                    for value in native_configuration_provenance.values()
                ),
                "native configuration provenance is incomplete",
            )
            shared_bindings = {
                "base_candidate_vector_sha256": configuration[
                    "serialized_candidate_vector_sha256"
                ],
                "base_adapter_configuration_sha256": canonical_sha256(
                    configuration
                ),
                "compiler_inputs_sha256": configuration[
                    "compiler_inputs_sha256"
                ],
                "native_configuration_provenance": (
                    native_configuration_provenance
                ),
                "mapping_sha256": configuration["mapping_sha256"],
                "coordinate_model_contract_file_sha256": coordinate_file_hash,
                "coordinate_oracle_matrix_sha256": canonical_sha256(
                    coordinate_document["coordinate_oracles"]
                ),
                "coordinate_experiment_dimensions_sha256": canonical_sha256(
                    coordinate_document["experiment_dimensions"]
                ),
                "video_profile_contract_file_sha256": video_file_hash,
                "video_profile_contract_sha256": canonical_sha256(
                    video_document
                ),
                "quality_harness_implementation_manifest_file_sha256": quality_record[
                    "sha256"
                ],
                "quality_harness_implementation_manifest_sha256": implementation_manifest[
                    "manifest_sha256"
                ],
                "g04_lock_file_sha256": self.g04_lock_file_sha256,
                "g05_lock_file_sha256": self.g05_lock_file_sha256,
                "corrective_preregistration_file_sha256": (
                    self.corrective_preregistration_file_sha256
                ),
                "corrective_preregistration_sha256": (
                    self.corrective_preregistration_sha256
                ),
                "native_executable_sha256": configuration["swift_cli"][
                    "executable_sha256"
                ],
                "native_source_manifest_sha256": configuration["swift_cli"][
                    "source_manifest_sha256"
                ],
                "development_sample_lock_file_sha256": record(
                    "development_sample_lock"
                )["sha256"],
                "development_sample_lock_manifest_sha256": sample_lock[
                    "manifest_sha256"
                ],
                "expected_observation_count_by_route": (
                    expected_observation_count_by_route
                ),
                "development_sample_dimension_sha256": (
                    development_sample_dimension_sha256
                ),
                "degradation_profile_dimension_sha256": (
                    degradation_profile_dimension_sha256
                ),
                "corpus_lock_bundle_sha256": configuration[
                    "corpus_lock_bundle_sha256"
                ],
                "live_holdout_preopen_verification": official_guard,
                "live_holdout_preopen_verification_sha256": canonical_sha256(
                    official_guard
                ),
                "degradation_policy_sha256": degradation_policy[
                    "policy_sha256"
                ],
                "analysis_grid_hash_contract": _HASH_CONTRACTS[
                    "analysis_grid_hash_contract"
                ],
            }
            coordinate_contract = coordinate_document
            ordered_generic = [generic_luts[route] for route in ROUTES]
            ordered_production = [production_luts[route] for route in ROUTES]
            reference_manifest = {
                "candidate_vector_sha256": shared_bindings[
                    "base_candidate_vector_sha256"
                ],
                "adapter_configuration_sha256": shared_bindings[
                    "base_adapter_configuration_sha256"
                ],
                "compiler_inputs_sha256": configuration[
                    "compiler_inputs_sha256"
                ],
                "route_luts": ordered_production,
            }
            reference_output_manifest = [
                {
                    "target_route": row["target_route"],
                    "source_asset_id": row["source_asset_id"],
                    "degradation_profile_id": row[
                        "degradation_profile_id"
                    ],
                    "input_frame_sha256": row["input_frame_sha256"],
                    "candidate_output_nv12_sha256": row[
                        "candidate_output_nv12_sha256"
                    ],
                    "candidate_output_frame_sha256": row[
                        "candidate_output_frame_sha256"
                    ],
                    "planes": row["planes"],
                }
                for row in reference_observations
            ]
            coordinate_artifact = _seal(
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": (
                        "p06_open_development_coordinate_anisotropy_diagnostic"
                    ),
                    "status": "development_diagnostic_no_selection",
                    "split": "development",
                    "validation_accessed": False,
                    "holdout_accessed": False,
                    "selected_winner": None,
                    "input_bindings": {
                        **shared_bindings,
                        "compiler_inputs_sha256": configuration[
                            "compiler_inputs_sha256"
                        ],
                        "coordinate_oracle_matrix_sha256": canonical_sha256(
                            coordinate_contract["coordinate_oracles"]
                        ),
                        "coordinate_experiment_dimensions_sha256": canonical_sha256(
                            coordinate_contract["experiment_dimensions"]
                        ),
                        "generic_phase_compiler_source_sha256": _sha256_file(
                            self.repository_root
                            / "Mirmir/Modules/UpscalerEngine/ASH/ASHGenericPhaseCompilerDiagnosticV3.swift"
                        ),
                        "generic_phase_compilation_manifest_sha256": canonical_sha256(
                            ordered_generic
                        ),
                        "metric_policy_sha256": metric_policy[
                            "policy_sha256"
                        ],
                        "writer_settings_sha256": self.writer.settings_sha256,
                        "output_plane_hash_contract": _HASH_CONTRACTS[
                            "output_plane_hash_contract"
                        ],
                        "normalized_plane_hash_contract": _HASH_CONTRACTS[
                            "normalized_plane_hash_contract"
                        ],
                        "generic_route_luts": ordered_generic,
                    },
                    "dimension_contract": coordinate_anisotropy_dimension_contract(),
                    "native_records": native_records,
                    "production_v2_reference": {
                        "reference_manifest_sha256": canonical_sha256(
                            reference_manifest
                        ),
                        **reference_manifest,
                        "reference_evaluation_sha256": canonical_sha256(
                            reference_observations
                        ),
                        "reference_output_manifest_sha256": canonical_sha256(
                            reference_output_manifest
                        ),
                        "observations": reference_observations,
                    },
                    "route_cell_blocks": blocks,
                    "full_corpus_compositions": compositions,
                },
                "artifact_sha256",
            )
            risk_artifact = _seal(
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": (
                        "p06_open_development_risk_state_diagnostic"
                    ),
                    "status": "development_diagnostic_no_selection",
                    "split": "development",
                    "validation_accessed": False,
                    "holdout_accessed": False,
                    "selected_winner": None,
                    "input_bindings": {
                        **shared_bindings,
                        "mapping_sha256": configuration["mapping_sha256"],
                        "risk_state_diagnostic_source_sha256": _sha256_file(
                            self.repository_root
                            / "Mirmir/Modules/UpscalerEngine/ASH/ASHRiskStateDiagnosticV3.swift"
                        ),
                    },
                    "dimension_contract": risk_state_dimension_contract(),
                    "native_records": native_records,
                    "frame_route_records": risk_records,
                },
                "artifact_sha256",
            )
            envelope = _seal(
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": (
                        "p06_open_development_corrective_diagnostic_envelope"
                    ),
                    "status": "development_diagnostic_no_selection",
                    "split": "development",
                    "validation_accessed": False,
                    "holdout_accessed": False,
                    "selected_winner": None,
                    "coordinate_anisotropy_artifact": artifact_file_binding(
                        coordinate_artifact
                    ),
                    "risk_state_artifact": artifact_file_binding(
                        risk_artifact
                    ),
                },
                "envelope_sha256",
            )
            journal.validate_complete(
                _journal_evidence_from_artifacts(
                    coordinate_artifact,
                    risk_artifact,
                )
            )
            input_descriptor = os.open(
                "inputs",
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=work_descriptor,
            )
            try:
                input_sanitation_receipt = _sanitize_owned_input_directory(
                    work_descriptor=work_descriptor,
                    input_descriptor=input_descriptor,
                    input_identity=input_identity,
                    file_identities=input_file_identities,
                )
            finally:
                os.close(input_descriptor)
            receipt_payload = canonical_artifact_file_bytes(
                input_sanitation_receipt
            )
            receipt_identity = _write_new_regular(
                Path(INPUT_SANITATION_RECEIPT_NAME),
                receipt_payload,
                parent_descriptor=work_descriptor,
            )
            _require(
                receipt_identity is not None,
                "corrective input sanitation receipt was not retained",
            )
            os.fsync(work_descriptor)
            prepublication_closure = _build_prepublication_execution_closure(
                work_root=work_root,
                work_descriptor=work_descriptor,
                work_identity=journal.work_root_identity,
                journal=journal,
                input_sanitation_receipt=input_sanitation_receipt,
            )
            for artifact in (coordinate_artifact, risk_artifact):
                bindings = artifact["input_bindings"]
                assert isinstance(bindings, dict)
                bindings["completed_execution_evidence"] = (
                    prepublication_closure
                )
                artifact.pop("artifact_sha256", None)
                artifact["artifact_sha256"] = canonical_sha256(artifact)
            envelope = _seal(
                {
                    "schema_version": "1.0.0",
                    "artifact_kind": (
                        "p06_open_development_corrective_diagnostic_envelope"
                    ),
                    "status": "development_diagnostic_no_selection",
                    "split": "development",
                    "validation_accessed": False,
                    "holdout_accessed": False,
                    "selected_winner": None,
                    "coordinate_anisotropy_artifact": artifact_file_binding(
                        coordinate_artifact
                    ),
                    "risk_state_artifact": artifact_file_binding(
                        risk_artifact
                    ),
                },
                "envelope_sha256",
            )
            journal.validate_complete(
                _journal_evidence_from_artifacts(
                    coordinate_artifact,
                    risk_artifact,
                )
            )
            validate_coordinate_anisotropy_artifact(coordinate_artifact)
            validate_risk_state_artifact(risk_artifact)
            journal.verify_guard(verify)
            postcommit_evidence: dict[str, Mapping[str, object]] = {}

            def fresh_guard() -> Mapping[str, object]:
                return _fresh_bound_guard(
                    bound=self.bound,
                    documents=documents,
                    verify=verify,
                    journal=journal,
                    expected=official_guard,
                )

            def postcommit_guard() -> Mapping[str, object]:
                evidence = fresh_guard()
                postcommit_evidence["guard"] = evidence
                return evidence

            result = publish_corrective_diagnostic_bundle(
                self.output_root,
                coordinate_artifact=coordinate_artifact,
                risk_artifact=risk_artifact,
                envelope=envelope,
                precommit_guard=fresh_guard,
                postcommit_guard=postcommit_guard,
            )
            _require(
                postcommit_evidence.get("guard") == official_guard,
                "corrective postcommit guard evidence was not captured",
            )
            self._prepublication_closure = prepublication_closure
            self._postcommit_guard = postcommit_evidence["guard"]
            self._published_documents = (
                coordinate_artifact,
                risk_artifact,
                envelope,
            )
            return result
        except BaseException:
            raise


__all__ = [
    "COORDINATE_ARTIFACT_NAME",
    "CorrectiveDiagnosticExecutionError",
    "CorrectiveDiagnosticExecutor",
    "ENVELOPE_NAME",
    "RISK_ARTIFACT_NAME",
    "publish_corrective_diagnostic_bundle",
]
