"""Concrete native writer and locked analytic-fixture providers for P06."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import stat
from typing import Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from validation.calibration_v2.production_evaluator import (
    ControlSelectionBundle,
    FIXED_DESCRIPTOR_IDS,
    ProductionEvaluatorError,
    WriterRoundTrip,
    _freeze_frame,
    _invoke_cached_fixed,
    _invoke_native_control,
    _prepare_native_output_cache,
    _validate_control_aggregate_origin_envelope,
    _validate_evidence_dependency_commit_result,
    _validate_writer_round_trip,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.common_writer import (
    CommonWriterInputFrame,
    PRODUCT_MEDIA_TYPES_PATH,
    ProductionWriterAuthorizedExecution,
    RationalTime,
    compile_production_writer,
    run_isolated_production_writer_cases,
)
from validation.quality.src.mirmir_quality.conformance import (
    _analytic_reference,
    _locked_analytic_fixtures,
)
from validation.quality.src.mirmir_quality.degradation import apply_degradation
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    read_json,
    write_json,
)
from validation.quality.src.mirmir_quality.metrics import (
    alias_energy,
    chroma_edge_displacement,
    edge_location_error,
    ringing,
    thin_line_retention,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    CandidateAdapter,
    CandidateContext,
    _planar_to_video_range_nv12,
    _round_trip_locked_bt709_video_range_nv12,
    _video_range_nv12_to_planar,
)


_CONTAINER_DECODED_LEGAL_RANGE_NORMALIZATION = {
    "scope": (
        "reopened isolated production HEVC writer 420v bytes before "
        "PlanarFrame conversion and container-decoded metrics only"
    ),
    "method": "nominal_video_range_clip_v1",
    "nominal_y_code_range": [16, 235],
    "nominal_chroma_code_range": [16, 240],
    "evidence": (
        "bind raw and normalized payload SHA-256 values and sizes, raw and "
        "normalized per-plane code ranges, and exact six-direction clip counts"
    ),
    "engine_raw_affected": False,
    "uniform_application": (
        "apply identically to every candidate, baseline, fixed operator, and "
        "ablation container-decoded output"
    ),
}


def production_writer_settings_document(
    *,
    executable_sha256: str,
    product_settings_source_sha256: str,
) -> Mapping[str, object]:
    """Return the canonical settings identity shared by P06/P07 recovery."""

    for value in (executable_sha256, product_settings_source_sha256):
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise ProductionEvaluatorError(
                "production-writer settings input SHA-256 is invalid"
            )
    return {
        "writer_id": "mirmir-product-hevc-avassetwriter-v1",
        "isolation": "one_frame_per_container",
        "pixel_contract": "bt709-video-range-420v-8bit-nv12-v1",
        "decoded_pixel_normalization": json.loads(
            canonical_json_bytes(
                _CONTAINER_DECODED_LEGAL_RANGE_NORMALIZATION
            )
        ),
        "executable_sha256": executable_sha256,
        "product_settings_source_sha256": product_settings_source_sha256,
    }


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_or_verify_json(path: Path, document: Mapping[str, object]) -> None:
    if path.exists():
        if read_json(path) != document:
            raise ProductionEvaluatorError(
                "content-addressed provider document changed"
            )
        return
    write_json(path, document)


def _normalize_decoded_video_range_nv12(
    payload: bytes,
    *,
    width: int,
    height: int,
) -> Tuple[bytes, Mapping[str, object]]:
    """Return nominal-range 420v bytes plus exact decoder-clipping evidence."""

    if width <= 0 or height <= 0 or width % 2 or height % 2:
        raise ProductionEvaluatorError(
            "decoded writer payload has invalid 4:2:0 geometry"
        )
    luma_size = width * height
    if len(payload) != luma_size * 3 // 2:
        raise ProductionEvaluatorError(
            "decoded writer payload byte count differs from geometry"
        )
    codes = np.frombuffer(payload, dtype=np.uint8).copy()
    y = codes[:luma_size]
    cb = codes[luma_size:][0::2]
    cr = codes[luma_size:][1::2]
    raw_ranges = {
        "y": [int(np.min(y)), int(np.max(y))],
        "cb": [int(np.min(cb)), int(np.max(cb))],
        "cr": [int(np.min(cr)), int(np.max(cr))],
    }
    clipped_counts = {
        "y_below_16": int(np.count_nonzero(y < 16)),
        "y_above_235": int(np.count_nonzero(y > 235)),
        "cb_below_16": int(np.count_nonzero(cb < 16)),
        "cb_above_240": int(np.count_nonzero(cb > 240)),
        "cr_below_16": int(np.count_nonzero(cr < 16)),
        "cr_above_240": int(np.count_nonzero(cr > 240)),
    }
    np.clip(y, 16, 235, out=y)
    np.clip(cb, 16, 240, out=cb)
    np.clip(cr, 16, 240, out=cr)
    normalized = codes.tobytes()
    evidence = {
        "method": "nominal_video_range_clip_v1",
        "nominal_y_code_range": [16, 235],
        "nominal_chroma_code_range": [16, 240],
        "raw_code_ranges": raw_ranges,
        "normalized_code_ranges": {
            "y": [int(np.min(y)), int(np.max(y))],
            "cb": [int(np.min(cb)), int(np.max(cb))],
            "cr": [int(np.min(cr)), int(np.max(cr))],
        },
        "clipped_sample_counts": clipped_counts,
        "total_clipped_sample_count": sum(clipped_counts.values()),
    }
    return normalized, evidence


class ContentAddressedEvidenceStore:
    """Persistent canonical evidence store for production calibration runs."""

    _TEMPORARY_FILE_PREFIX = ".mirmir-write-"
    _TEMPORARY_FILE_SUFFIX = ".tmp"

    def __init__(self, root: Path) -> None:
        self._root = Path(os.path.abspath(os.fspath(root)))
        self._documents = self._root / "documents"
        self._failures = self._root / "failures"
        self._control_aggregate_origins = (
            self._root / "control-aggregate-origins"
        )
        self._directory_identities: Dict[Path, Tuple[int, int]] = {}
        self._pending_control_aggregate_documents: Dict[str, str] = {}
        root_descriptor, root_components = self._create_and_pin_root(
            self._root
        )
        self._root_component_identities = root_components
        try:
            for directory, label in (
                (self._documents, "content-addressed document"),
                (self._failures, "content-addressed failure"),
                (
                    self._control_aggregate_origins,
                    "control-aggregate origin",
                ),
            ):
                name = directory.name
                created = False
                try:
                    os.mkdir(name, 0o700, dir_fd=root_descriptor)
                    created = True
                except FileExistsError:
                    pass
                except OSError as error:
                    raise ProductionEvaluatorError(
                        f"{label} directory cannot be created"
                    ) from error
                try:
                    before = os.stat(
                        name,
                        dir_fd=root_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise ProductionEvaluatorError(
                        f"{label} directory cannot be inspected"
                    ) from error
                if stat.S_ISLNK(before.st_mode):
                    raise ProductionEvaluatorError(
                        f"{label} directory must not be a symlink"
                    )
                if created:
                    os.fsync(root_descriptor)
                descriptor = self._open_directory_at(
                    root_descriptor,
                    name,
                    expected_identity=None,
                    label=label,
                )
                try:
                    opened = os.fstat(descriptor)
                    self._directory_identities[directory] = (
                        opened.st_dev,
                        opened.st_ino,
                    )
                finally:
                    os.close(descriptor)
        finally:
            os.close(root_descriptor)
        for directory in self._directory_identities:
            self._cleanup_temporary_files(directory)

    @staticmethod
    def _directory_open_flags() -> int:
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        return flags

    @classmethod
    def _create_and_pin_root(
        cls,
        root: Path,
    ) -> Tuple[int, Tuple[Tuple[str, int, int], ...]]:
        if not root.is_absolute():
            raise ProductionEvaluatorError(
                "content-addressed root path is not absolute"
            )
        descriptor = os.open(os.sep, cls._directory_open_flags())
        identities = []
        try:
            for component in root.parts[1:]:
                created = False
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    created = True
                except FileExistsError:
                    pass
                except OSError as error:
                    raise ProductionEvaluatorError(
                        "content-addressed root path component cannot be created"
                    ) from error
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened_descriptor = os.open(
                        component,
                        cls._directory_open_flags(),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise ProductionEvaluatorError(
                        "content-addressed root path contains a symlink or "
                        "unopenable component"
                    ) from error
                opened = os.fstat(opened_descriptor)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                ):
                    os.close(opened_descriptor)
                    raise ProductionEvaluatorError(
                        "content-addressed root path component identity changed"
                    )
                if created:
                    os.fsync(descriptor)
                identities.append(
                    (component, opened.st_dev, opened.st_ino)
                )
                os.close(descriptor)
                descriptor = opened_descriptor
            return descriptor, tuple(identities)
        except BaseException:
            os.close(descriptor)
            raise

    def _open_root_directory(self) -> int:
        descriptor = os.open(os.sep, self._directory_open_flags())
        try:
            for component, expected_device, expected_inode in (
                self._root_component_identities
            ):
                try:
                    before = os.stat(
                        component,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    opened_descriptor = os.open(
                        component,
                        self._directory_open_flags(),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise ProductionEvaluatorError(
                        "content-addressed root directory cannot be opened"
                    ) from error
                opened = os.fstat(opened_descriptor)
                if (
                    not stat.S_ISDIR(before.st_mode)
                    or not stat.S_ISDIR(opened.st_mode)
                    or (before.st_dev, before.st_ino)
                    != (opened.st_dev, opened.st_ino)
                    or (opened.st_dev, opened.st_ino)
                    != (expected_device, expected_inode)
                ):
                    os.close(opened_descriptor)
                    raise ProductionEvaluatorError(
                        "content-addressed root directory identity changed"
                    )
                os.close(descriptor)
                descriptor = opened_descriptor
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    @classmethod
    def _open_directory_at(
        cls,
        parent_descriptor: int,
        name: str,
        *,
        expected_identity: Tuple[int, int] | None,
        label: str,
    ) -> int:
        try:
            before = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(
                name,
                cls._directory_open_flags(),
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            raise ProductionEvaluatorError(
                f"{label} directory cannot be opened"
            ) from error
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(before.st_mode)
            or not stat.S_ISDIR(opened.st_mode)
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
            or (
                expected_identity is not None
                and (opened.st_dev, opened.st_ino) != expected_identity
            )
        ):
            os.close(descriptor)
            raise ProductionEvaluatorError(
                f"{label} directory identity changed"
            )
        return descriptor

    def _open_directory(self, directory: Path) -> int:
        labels = {
            self._documents: "content-addressed document",
            self._failures: "content-addressed failure",
            self._control_aggregate_origins: "control-aggregate origin",
        }
        identity = self._directory_identities.get(directory)
        label = labels.get(directory)
        if identity is None or label is None:
            raise ProductionEvaluatorError(
                "content-addressed store directory is not pinned"
            )
        root_descriptor = self._open_root_directory()
        try:
            return self._open_directory_at(
                root_descriptor,
                directory.name,
                expected_identity=identity,
                label=label,
            )
        finally:
            os.close(root_descriptor)

    @classmethod
    def _is_temporary_filename(cls, filename: str) -> bool:
        return (
            filename.startswith(cls._TEMPORARY_FILE_PREFIX)
            and filename.endswith(cls._TEMPORARY_FILE_SUFFIX)
        )

    def _cleanup_temporary_files(self, directory: Path) -> None:
        directory_descriptor = self._open_directory(directory)
        removed = False
        try:
            for filename in os.listdir(directory_descriptor):
                if not self._is_temporary_filename(filename):
                    continue
                try:
                    status = os.stat(
                        filename,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                if stat.S_ISDIR(status.st_mode):
                    raise ProductionEvaluatorError(
                        "temporary evidence path is a directory"
                    )
                os.unlink(filename, dir_fd=directory_descriptor)
                removed = True
            if removed:
                os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)

    @staticmethod
    def _open_regular_at(
        directory_descriptor: int,
        filename: str,
        *,
        label: str,
    ) -> int:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(
                filename,
                flags,
                dir_fd=directory_descriptor,
            )
        except OSError as error:
            raise ProductionEvaluatorError(f"{label} cannot be opened") from error
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise ProductionEvaluatorError(f"{label} is not a regular file")
        return descriptor

    @staticmethod
    def _read_descriptor(descriptor: int) -> bytes:
        os.lseek(descriptor, 0, os.SEEK_SET)
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)

    @classmethod
    def _read_regular_at(
        cls,
        directory_descriptor: int,
        filename: str,
        *,
        label: str,
    ) -> bytes:
        descriptor = cls._open_regular_at(
            directory_descriptor,
            filename,
            label=label,
        )
        try:
            return cls._read_descriptor(descriptor)
        finally:
            os.close(descriptor)

    @staticmethod
    def _write_at(
        directory_descriptor: int,
        filename: str,
        payload: bytes,
        *,
        label: str,
        fsync_file: bool = True,
    ) -> None:
        if fsync_file is not True:
            raise ProductionEvaluatorError(
                "atomic final publication requires a durable temporary file"
            )
        try:
            os.stat(
                filename,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            existing = ContentAddressedEvidenceStore._read_regular_at(
                directory_descriptor,
                filename,
                label=label,
            )
            if existing != payload:
                raise ProductionEvaluatorError(f"{label} changed")
            existing_descriptor = (
                ContentAddressedEvidenceStore._open_regular_at(
                    directory_descriptor,
                    filename,
                    label=label,
                )
            )
            try:
                os.fsync(existing_descriptor)
            finally:
                os.close(existing_descriptor)
            return

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        temporary_filename = (
            f"{ContentAddressedEvidenceStore._TEMPORARY_FILE_PREFIX}"
            f"{os.getpid()}-{secrets.token_hex(16)}"
            f"{ContentAddressedEvidenceStore._TEMPORARY_FILE_SUFFIX}"
        )
        descriptor = None
        try:
            descriptor = os.open(
                temporary_filename,
                flags,
                0o600,
                dir_fd=directory_descriptor,
            )
        except OSError as error:
            raise ProductionEvaluatorError(
                f"{label} temporary file cannot be created"
            ) from error
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise ProductionEvaluatorError(
                        f"{label} write made no progress"
                    )
                offset += written
            os.fsync(descriptor)
            try:
                os.link(
                    temporary_filename,
                    filename,
                    src_dir_fd=directory_descriptor,
                    dst_dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError:
                existing = ContentAddressedEvidenceStore._read_regular_at(
                    directory_descriptor,
                    filename,
                    label=label,
                )
                if existing != payload:
                    raise ProductionEvaluatorError(f"{label} changed")
                existing_descriptor = (
                    ContentAddressedEvidenceStore._open_regular_at(
                        directory_descriptor,
                        filename,
                        label=label,
                    )
                )
                try:
                    os.fsync(existing_descriptor)
                finally:
                    os.close(existing_descriptor)
            except OSError as error:
                raise ProductionEvaluatorError(
                    f"{label} cannot be atomically published"
                ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(
                    temporary_filename,
                    dir_fd=directory_descriptor,
                )
            except FileNotFoundError:
                pass

    @staticmethod
    def _stage_payload_at(
        directory_descriptor: int,
        payload: bytes,
        *,
        label: str,
    ) -> str:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        temporary_filename = (
            f"{ContentAddressedEvidenceStore._TEMPORARY_FILE_PREFIX}"
            f"{os.getpid()}-{secrets.token_hex(16)}"
            f"{ContentAddressedEvidenceStore._TEMPORARY_FILE_SUFFIX}"
        )
        descriptor = None
        try:
            descriptor = os.open(
                temporary_filename,
                flags,
                0o600,
                dir_fd=directory_descriptor,
            )
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise ProductionEvaluatorError(
                        f"{label} staged write made no progress"
                    )
                offset += written
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
                descriptor = None
            try:
                os.unlink(
                    temporary_filename,
                    dir_fd=directory_descriptor,
                )
            except FileNotFoundError:
                pass
            raise
        finally:
            if descriptor is not None:
                os.close(descriptor)
        return temporary_filename

    @staticmethod
    def _promote_staged_at(
        directory_descriptor: int,
        temporary_filename: str,
        filename: str,
        payload: bytes,
        *,
        label: str,
    ) -> None:
        descriptor = ContentAddressedEvidenceStore._open_regular_at(
            directory_descriptor,
            temporary_filename,
            label=f"staged {label}",
        )
        try:
            staged_payload = ContentAddressedEvidenceStore._read_descriptor(
                descriptor
            )
            if staged_payload != payload:
                raise ProductionEvaluatorError(f"staged {label} changed")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.link(
                temporary_filename,
                filename,
                src_dir_fd=directory_descriptor,
                dst_dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError:
            existing = ContentAddressedEvidenceStore._read_regular_at(
                directory_descriptor,
                filename,
                label=label,
            )
            if existing != payload:
                raise ProductionEvaluatorError(f"{label} changed")
            existing_descriptor = ContentAddressedEvidenceStore._open_regular_at(
                directory_descriptor,
                filename,
                label=label,
            )
            try:
                os.fsync(existing_descriptor)
            finally:
                os.close(existing_descriptor)
        except OSError as error:
            raise ProductionEvaluatorError(
                f"{label} cannot be atomically published"
            ) from error
        os.unlink(temporary_filename, dir_fd=directory_descriptor)

    def _write_pinned_file(
        self,
        directory: Path,
        filename: str,
        payload: bytes,
        *,
        label: str,
        fsync_directory: bool,
    ) -> None:
        directory_descriptor = self._open_directory(directory)
        try:
            self._write_at(
                directory_descriptor,
                filename,
                payload,
                label=label,
            )
            if fsync_directory:
                os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)

    def _publish_at(
        self,
        directory: Path,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        payload = canonical_json_bytes(document)
        digest = hashlib.sha256(payload).hexdigest()
        filename = f"{digest}.json"
        self._write_pinned_file(
            directory,
            filename,
            payload,
            label="content-addressed evidence",
            fsync_directory=True,
        )
        directory_descriptor = self._open_directory(directory)
        try:
            reopened_payload = self._read_regular_at(
                directory_descriptor,
                filename,
                label="content-addressed evidence",
            )
        finally:
            os.close(directory_descriptor)
        reopened = json.loads(reopened_payload)
        if (
            reopened != dict(document)
            or canonical_json_bytes(reopened) != reopened_payload
            or hashlib.sha256(reopened_payload).hexdigest() != digest
        ):
            raise ProductionEvaluatorError(
                "content-addressed evidence failed reopen verification"
            )
        return {"sha256": digest, "size_bytes": len(payload)}

    def publish(self, document: Mapping[str, object]) -> Mapping[str, object]:
        return self._publish_at(self._documents, document)

    def publish_control_aggregate_document(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        payload = canonical_json_bytes(document)
        digest = hashlib.sha256(payload).hexdigest()
        final_filename = f"{digest}.json"
        directory_descriptor = self._open_directory(self._documents)
        try:
            try:
                os.stat(
                    final_filename,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                temporary_filename = (
                    self._pending_control_aggregate_documents.get(digest)
                )
                if temporary_filename is None:
                    temporary_filename = self._stage_payload_at(
                        directory_descriptor,
                        payload,
                        label="control-aggregate document",
                    )
                    self._pending_control_aggregate_documents[digest] = (
                        temporary_filename
                    )
                reopened_payload = self._read_regular_at(
                    directory_descriptor,
                    temporary_filename,
                    label="staged control-aggregate document",
                )
            else:
                reopened_payload = self._read_regular_at(
                    directory_descriptor,
                    final_filename,
                    label="control-aggregate document",
                )
        finally:
            os.close(directory_descriptor)
        reopened = json.loads(reopened_payload)
        if (
            reopened != dict(document)
            or canonical_json_bytes(reopened) != reopened_payload
            or hashlib.sha256(reopened_payload).hexdigest() != digest
        ):
            raise ProductionEvaluatorError(
                "control-aggregate document failed staged reopen verification"
            )
        return {"sha256": digest, "size_bytes": len(payload)}

    def reopen(self, sha256: str) -> Mapping[str, object]:
        if (
            not isinstance(sha256, str)
            or len(sha256) != 64
            or any(character not in "0123456789abcdef" for character in sha256)
        ):
            raise ProductionEvaluatorError("evidence hash is invalid")
        payload = None
        filename = f"{sha256}.json"
        staged_filename = self._pending_control_aggregate_documents.get(
            sha256
        )
        if staged_filename is not None:
            directory_descriptor = self._open_directory(self._documents)
            try:
                payload = self._read_regular_at(
                    directory_descriptor,
                    staged_filename,
                    label="staged control-aggregate document",
                )
            finally:
                os.close(directory_descriptor)
        directories = (
            ()
            if payload is not None
            else (self._documents, self._failures)
        )
        for directory in directories:
            directory_descriptor = self._open_directory(directory)
            try:
                try:
                    os.stat(
                        filename,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                payload = self._read_regular_at(
                    directory_descriptor,
                    filename,
                    label="content-addressed evidence",
                )
                break
            finally:
                os.close(directory_descriptor)
        if payload is None:
            raise ProductionEvaluatorError("content-addressed evidence is absent")
        if hashlib.sha256(payload).hexdigest() != sha256:
            raise ProductionEvaluatorError("content-addressed evidence hash changed")
        document = json.loads(payload)
        if (
            not isinstance(document, dict)
            or canonical_json_bytes(document) != payload
        ):
            raise ProductionEvaluatorError(
                "content-addressed evidence is not an object"
            )
        return document

    def preserve_failure(
        self,
        document: Mapping[str, object],
    ) -> Mapping[str, object]:
        return self._publish_at(self._failures, document)

    def publish_control_aggregate_origin(
        self,
        *,
        identity: Mapping[str, object],
        origin: Mapping[str, object],
    ) -> Mapping[str, object]:
        result = self.publish_control_aggregate_origins_batch(
            ({"identity": identity, "origin": origin},)
        )
        identity_sha256 = canonical_sha256(identity)
        reopened = self.reopen_control_aggregate_origin(identity)
        if reopened is None:
            raise ProductionEvaluatorError(
                "control-aggregate origin failed reopen verification"
            )
        return {
            "identity_sha256": identity_sha256,
            "origin_manifest_sha256": reopened["origin_manifest_sha256"],
            "size_bytes": len(canonical_json_bytes(reopened)),
            "batch_record_sha256": result["record_sha256"],
        }

    def publish_control_aggregate_origins_batch(
        self,
        entries: Sequence[Mapping[str, Mapping[str, object]]],
    ) -> Mapping[str, object]:
        if not isinstance(entries, (list, tuple)) or not entries:
            raise ProductionEvaluatorError("control-aggregate origin batch is empty")
        validated_entries = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"identity", "origin"}:
                raise ProductionEvaluatorError(
                    "control-aggregate origin batch entry field set differs"
                )
            identity = entry["identity"]
            origin = _validate_control_aggregate_origin_envelope(
                entry["origin"],
                identity=identity,
            )
            validated_entries.append(
                (
                    identity,
                    origin,
                    canonical_sha256(identity),
                    canonical_json_bytes(origin),
                )
            )
        identity_values = [entry[2] for entry in validated_entries]
        if len(identity_values) != len(set(identity_values)):
            raise ProductionEvaluatorError(
                "control-aggregate origin batch identity is duplicated"
            )
        directory_descriptor = self._open_directory(
            self._control_aggregate_origins
        )
        try:
            for _, _, identity_sha256, payload in validated_entries:
                filename = f"{identity_sha256}.json"
                try:
                    os.stat(
                        filename,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                existing = self._read_regular_at(
                    directory_descriptor,
                    filename,
                    label="control-aggregate origin",
                )
                if existing != payload:
                    raise ProductionEvaluatorError(
                        "control-aggregate origin changed"
                    )
            for _, _, identity_sha256, payload in validated_entries:
                self._write_at(
                    directory_descriptor,
                    f"{identity_sha256}.json",
                    payload,
                    label="control-aggregate origin",
                )
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        for identity, origin, _, _ in validated_entries:
            if self.reopen_control_aggregate_origin(identity) != origin:
                raise ProductionEvaluatorError(
                    "control-aggregate origin batch failed reopen"
                )
        record: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_control_aggregate_origin_batch_commit",
            "published_count": len(validated_entries),
            "ordered_identity_sha256_values": identity_values,
            "ordered_origin_manifest_sha256_values": [
                entry[1]["origin_manifest_sha256"]
                for entry in validated_entries
            ],
        }
        record["record_sha256"] = canonical_sha256(record)
        return record

    def flush_control_aggregate_dependencies(
        self,
        ordered_document_sha256_values: Sequence[str],
    ) -> Mapping[str, object]:
        values = list(ordered_document_sha256_values)
        if (
            not values
            or len(values) != len(set(values))
            or any(
                not isinstance(value, str)
                or len(value) != 64
                or any(character not in "0123456789abcdef" for character in value)
                for value in values
            )
        ):
            raise ProductionEvaluatorError(
                "aggregate evidence dependency document order is invalid"
            )
        directory_descriptor = self._open_directory(self._documents)
        try:
            for value in values:
                temporary_filename = (
                    self._pending_control_aggregate_documents.get(value)
                )
                if temporary_filename is not None:
                    descriptor = self._open_regular_at(
                        directory_descriptor,
                        temporary_filename,
                        label="staged aggregate evidence dependency",
                    )
                    try:
                        payload = self._read_descriptor(descriptor)
                    finally:
                        os.close(descriptor)
                    if hashlib.sha256(payload).hexdigest() != value:
                        raise ProductionEvaluatorError(
                            "aggregate evidence dependency hash changed"
                        )
                    self._promote_staged_at(
                        directory_descriptor,
                        temporary_filename,
                        f"{value}.json",
                        payload,
                        label="aggregate evidence dependency",
                    )
                    self._pending_control_aggregate_documents.pop(
                        value,
                        None,
                    )
                else:
                    descriptor = self._open_regular_at(
                        directory_descriptor,
                        f"{value}.json",
                        label="aggregate evidence dependency",
                    )
                    try:
                        payload = self._read_descriptor(descriptor)
                        if hashlib.sha256(payload).hexdigest() != value:
                            raise ProductionEvaluatorError(
                                "aggregate evidence dependency hash changed"
                            )
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
            directory_identity = self._directory_identities[self._documents]
            record: Dict[str, object] = {
                "schema_version": "1.0.0",
                "artifact_kind": (
                    "p06_control_aggregate_evidence_dependency_commit"
                ),
                "ordered_document_sha256_values": values,
                "document_count": len(values),
                "documents_directory_identity_sha256": canonical_sha256(
                    {
                        "device": directory_identity[0],
                        "inode": directory_identity[1],
                    }
                ),
                "committed": True,
            }
            record["record_sha256"] = canonical_sha256(record)
            record_payload = canonical_json_bytes(record)
            document_sha256 = hashlib.sha256(record_payload).hexdigest()
            self._write_at(
                directory_descriptor,
                f"{document_sha256}.json",
                record_payload,
                label="aggregate evidence dependency commit",
            )
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        return _validate_evidence_dependency_commit_result(
            {
                "record": record,
                "document_sha256": document_sha256,
                "size_bytes": len(record_payload),
            },
            ordered_document_sha256_values=values,
        )

    def reopen_control_aggregate_origin(
        self,
        identity: Mapping[str, object],
    ) -> Mapping[str, object] | None:
        identity_sha256 = canonical_sha256(identity)
        filename = f"{identity_sha256}.json"
        directory_descriptor = self._open_directory(
            self._control_aggregate_origins
        )
        try:
            try:
                os.stat(
                    filename,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                return None
            payload = self._read_regular_at(
                directory_descriptor,
                filename,
                label="control-aggregate origin",
            )
        finally:
            os.close(directory_descriptor)
        try:
            value = json.loads(payload)
        except (TypeError, ValueError) as error:
            raise ProductionEvaluatorError(
                "control-aggregate origin is not canonical JSON"
            ) from error
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise ProductionEvaluatorError(
                "control-aggregate origin bytes are not canonical"
            )
        return _validate_control_aggregate_origin_envelope(
            value,
            identity=identity,
        )


def content_addressed_evidence_store(
    root: Path,
) -> ContentAddressedEvidenceStore:
    """Build the persistent canonical evidence store used by P06."""

    return ContentAddressedEvidenceStore(root)


class NativeProductionWriterCapability:
    """One-frame-per-container product writer with content-addressed reopen."""

    def __init__(
        self,
        evidence_root: Path,
        *,
        locked_executable: Optional[Path] = None,
        expected_executable_sha256: Optional[str] = None,
        expected_product_settings_source_sha256: Optional[str] = None,
        expected_settings_sha256: Optional[str] = None,
        authorized_execution: Optional[ProductionWriterAuthorizedExecution] = None,
    ) -> None:
        self._root = evidence_root.resolve()
        self._root.mkdir(parents=True, exist_ok=True)
        self._runs = self._root / "runs"
        self._evidence = self._root / "evidence"
        self._runs.mkdir(exist_ok=True)
        self._evidence.mkdir(exist_ok=True)
        secure_values = (
            locked_executable,
            expected_executable_sha256,
            expected_product_settings_source_sha256,
            expected_settings_sha256,
            authorized_execution,
        )
        if any(value is not None for value in secure_values) and any(
            value is None for value in secure_values
        ):
            raise ProductionEvaluatorError(
                "locked production-writer inputs must be complete"
            )
        if locked_executable is None:
            self._executable = self._root / "production-writer"
            if not self._executable.exists():
                compile_production_writer(self._executable)
        else:
            self._executable = locked_executable.absolute()
        if not self._executable.is_file() or not self._executable.stat().st_mode:
            raise ProductionEvaluatorError("production writer executable is absent")
        executable_sha256 = _sha256_file(self._executable)
        settings_source_sha256 = _sha256_file(PRODUCT_MEDIA_TYPES_PATH)
        if locked_executable is not None and (
            executable_sha256 != expected_executable_sha256
            or settings_source_sha256
            != expected_product_settings_source_sha256
        ):
            raise ProductionEvaluatorError(
                "locked production-writer executable/settings source differs"
            )
        self._authorized_execution = authorized_execution
        self._settings = production_writer_settings_document(
            executable_sha256=executable_sha256,
            product_settings_source_sha256=settings_source_sha256,
        )
        self.settings_sha256 = canonical_sha256(self._settings)
        if (
            expected_settings_sha256 is not None
            and self.settings_sha256 != expected_settings_sha256
        ):
            raise ProductionEvaluatorError(
                "locked production-writer settings identity differs"
            )

    def _paths(self, run_key: str) -> Mapping[str, Path]:
        root = self._runs / run_key / "case-000000"
        return {
            "root": root,
            "source": root / "case-000000-source.nv12",
            "source_lock": root / "case-000000-source-lock.json",
            "encoded": root / "case-000000.mp4",
            "report": root / "case-000000-report.json",
            "decoded_root": root / "case-000000-decoded",
        }

    def _decoded_payload(self, paths: Mapping[str, Path]) -> bytes:
        report = read_json(paths["report"])
        frames = report.get("decoder", {}).get("frames", [])
        if not isinstance(frames, list) or len(frames) != 1:
            raise ProductionEvaluatorError(
                "production writer report has no isolated decoded frame"
            )
        record = frames[0]
        if not isinstance(record, dict):
            raise ProductionEvaluatorError("production writer frame is invalid")
        payload_path = paths["decoded_root"] / str(record.get("payload_path"))
        payload = payload_path.read_bytes()
        if (
            len(payload) != record.get("payload_size_bytes")
            or hashlib.sha256(payload).hexdigest() != record.get("payload_sha256")
        ):
            raise ProductionEvaluatorError(
                "production writer decoded bytes failed reopen verification"
            )
        return payload

    def round_trip(
        self,
        *,
        control_key: str,
        frame: PlanarFrame,
        context: CandidateContext,
    ) -> WriterRoundTrip:
        if not control_key:
            raise ProductionEvaluatorError("writer control key is empty")
        if (
            frame.y.shape != context.y_shape
            or frame.cb.shape != context.cb_shape
            or frame.cr.shape != context.cr_shape
        ):
            raise ProductionEvaluatorError("writer frame geometry differs")
        input_hash = frame_sha256(frame)
        run_key = canonical_sha256(
            {
                "control_key": control_key,
                "input_frame_sha256": input_hash,
                "settings_sha256": self.settings_sha256,
                "target_route": context.target_route,
                "y_shape": list(context.y_shape),
                "cb_shape": list(context.cb_shape),
                "cr_shape": list(context.cr_shape),
            }
        )
        paths = self._paths(run_key)
        secure_writer = getattr(self, "_authorized_execution", None) is not None
        if secure_writer and paths["report"].exists():
            raise ProductionEvaluatorError(
                "secure production writer refuses cached path evidence"
            )
        verified_result = None
        if not paths["report"].exists():
            payload = _planar_to_video_range_nv12(frame)
            source_frame = CommonWriterInputFrame(
                case_id=run_key,
                nv12=payload,
                presentation_time=RationalTime(0, 600),
                duration=RationalTime(20, 600),
            )
            results = run_isolated_production_writer_cases(
                frames=(source_frame,),
                width=context.y_shape[1],
                height=context.y_shape[0],
                output_directory=self._runs / run_key,
                source_id=run_key,
                executable=self._executable,
                expected_dimensions=(
                    context.y_shape[1],
                    context.y_shape[0],
                ),
                authorized_execution=getattr(
                    self,
                    "_authorized_execution",
                    None,
                ),
            )
            if len(results) != 1 or results[0].case_id != run_key:
                raise ProductionEvaluatorError(
                    "production writer isolation result differs"
                )
            verified_result = results[0].result

        if secure_writer:
            if (
                verified_result is None
                or len(verified_result.decoded_frames) != 1
                or any(
                    value is None
                    for value in (
                        verified_result.report_payload_sha256,
                        verified_result.source_payload_sha256,
                        verified_result.source_lock_sha256,
                        verified_result.encoded_payload_sha256,
                    )
                )
            ):
                raise ProductionEvaluatorError(
                    "secure production writer retained result is incomplete"
                )
            report = verified_result.report
            raw_decoded_payload = verified_result.decoded_frames[0]
            encoded_sha256 = str(verified_result.encoded_payload_sha256)
            report_sha256 = str(verified_result.report_payload_sha256)
            source_payload_sha256 = str(verified_result.source_payload_sha256)
            source_lock_sha256 = str(verified_result.source_lock_sha256)
        else:
            report = read_json(paths["report"])
            raw_decoded_payload = self._decoded_payload(paths)
            encoded_sha256 = _sha256_file(paths["encoded"])
            report_sha256 = _sha256_file(paths["report"])
            source_payload_sha256 = _sha256_file(paths["source"])
            source_lock_sha256 = _sha256_file(paths["source_lock"])
        payload, normalization = _normalize_decoded_video_range_nv12(
            raw_decoded_payload,
            width=context.y_shape[1],
            height=context.y_shape[0],
        )
        decoded = _video_range_nv12_to_planar(
            payload,
            width=context.y_shape[1],
            height=context.y_shape[0],
        )
        decoded_hash = frame_sha256(decoded)
        evidence = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_isolated_production_writer_evidence",
            "control_key": control_key,
            "input_frame_sha256": input_hash,
            "decoded_frame_sha256": decoded_hash,
            "settings_sha256": self.settings_sha256,
            "encoded_sha256": encoded_sha256,
            "report_sha256": report_sha256,
            "source_payload_sha256": source_payload_sha256,
            "source_lock_sha256": source_lock_sha256,
            "decoded_payload_sha256": hashlib.sha256(
                raw_decoded_payload
            ).hexdigest(),
            "raw_decoded_payload_sha256": hashlib.sha256(
                raw_decoded_payload
            ).hexdigest(),
            "raw_decoded_payload_size_bytes": len(raw_decoded_payload),
            "normalized_decoded_payload_sha256": hashlib.sha256(
                payload
            ).hexdigest(),
            "normalized_decoded_payload_size_bytes": len(payload),
            "decoded_pixel_normalization": self._settings[
                "decoded_pixel_normalization"
            ],
            "decoder_legal_range_normalization": normalization,
            "comparison_domain": "container_decoded",
            "target_route": context.target_route,
            "reopened_and_verified": True,
        }
        encoder = report.get("encoder")
        if (
            report.get("artifact_kind") != "production_writer_actual_codec"
            or not isinstance(encoder, dict)
            or encoder.get("product_settings_source", {}).get("sha256")
            != self._settings["product_settings_source_sha256"]
            or report.get("encoded", {}).get("sha256")
            != evidence["encoded_sha256"]
        ):
            raise ProductionEvaluatorError(
                "production writer report identity differs from locked settings"
            )
        evidence_sha256 = canonical_sha256(evidence)
        _write_or_verify_json(
            self._evidence / f"{evidence_sha256}.json",
            evidence,
        )
        if self.reopen_evidence(evidence_sha256) != evidence:
            raise ProductionEvaluatorError(
                "writer evidence failed content-addressed reopen"
            )
        return WriterRoundTrip(
            decoded_frame=_freeze_frame(decoded),
            input_frame_sha256=input_hash,
            decoded_frame_sha256=decoded_hash,
            settings_sha256=self.settings_sha256,
            encoded_sha256=str(evidence["encoded_sha256"]),
            report_sha256=str(evidence["report_sha256"]),
            evidence_sha256=evidence_sha256,
            reopened_and_verified=True,
        )

    def reopen_evidence(self, evidence_sha256: str) -> Mapping[str, object]:
        path = self._evidence / f"{evidence_sha256}.json"
        if not path.is_file():
            raise ProductionEvaluatorError("writer evidence is absent")
        document = read_json(path)
        if canonical_sha256(document) != evidence_sha256:
            raise ProductionEvaluatorError("writer evidence hash changed")
        return document


def production_writer_capability(
    evidence_root: Path,
    *,
    locked_executable: Optional[Path] = None,
    expected_executable_sha256: Optional[str] = None,
    expected_product_settings_source_sha256: Optional[str] = None,
    expected_settings_sha256: Optional[str] = None,
    authorized_execution: Optional[ProductionWriterAuthorizedExecution] = None,
) -> NativeProductionWriterCapability:
    """Build the concrete product writer used by the calibration executor."""

    return NativeProductionWriterCapability(
        evidence_root,
        locked_executable=locked_executable,
        expected_executable_sha256=expected_executable_sha256,
        expected_product_settings_source_sha256=(
            expected_product_settings_source_sha256
        ),
        expected_settings_sha256=expected_settings_sha256,
        authorized_execution=authorized_execution,
    )


_ANALYTIC_FIELDS = (
    "edge_location_error_pixels",
    "ringing_overshoot",
    "ringing_undershoot",
    "alias_forbidden_band_ratio",
    "thin_line_retention_ratio",
    "thin_line_false_side_lobe_energy",
    "chroma_displacement_pixels",
)


def _analytic_metric_bundle(
    definition: Mapping[str, object],
    target: PlanarFrame,
    candidate: PlanarFrame,
    support: object,
) -> Mapping[str, object]:
    values: Dict[str, object] = {field: None for field in _ANALYTIC_FIELDS}
    kind = definition["fixture_kind"]
    measurement = definition["measurement_support"]
    if not isinstance(measurement, dict):
        raise ProductionEvaluatorError("analytic measurement support is invalid")
    if kind == "edge_profile":
        values["edge_location_error_pixels"] = edge_location_error(
            target.y,
            candidate.y,
            center=tuple(float(value) for value in measurement["center_xy"]),
            normal=tuple(float(value) for value in measurement["normal_xy"]),
            sample_count=int(measurement["sample_count"]),
        )
    elif kind == "ringing":
        if not isinstance(support, np.ndarray):
            raise ProductionEvaluatorError("ringing support is absent")
        result = ringing(target.y, candidate.y, support)
        values["ringing_overshoot"] = result["overshoot"]
        values["ringing_undershoot"] = result["undershoot"]
    elif kind == "thin_line":
        if not isinstance(support, np.ndarray):
            raise ProductionEvaluatorError("thin-line support is absent")
        result = thin_line_retention(target.y, candidate.y, support)
        values["thin_line_retention_ratio"] = result["retention_ratio"]
        values["thin_line_false_side_lobe_energy"] = result[
            "false_side_lobe_energy"
        ]
    elif kind == "alias":
        if not isinstance(support, np.ndarray):
            raise ProductionEvaluatorError("alias FFT support is absent")
        values["alias_forbidden_band_ratio"] = alias_energy(
            candidate.y,
            support,
        )["ratio"]
    elif kind == "chroma_displacement":
        luma_columns = measurement["luma_sample_columns"]
        chroma_columns = measurement["chroma_sample_columns"]
        coordinates = measurement["coordinates_luma_pixels"]
        if not all(
            isinstance(value, dict)
            for value in (luma_columns, chroma_columns, coordinates)
        ):
            raise ProductionEvaluatorError("chroma profile support is invalid")

        def indexes(specification: Mapping[str, object]) -> np.ndarray:
            start = int(specification["start"])
            step = int(specification["step"])
            count = int(specification["count"])
            return start + step * np.arange(count, dtype=np.int64)

        luma_index = indexes(luma_columns)
        chroma_index = indexes(chroma_columns)
        coordinate_values = (
            float(coordinates["start"])
            + float(coordinates["step"])
            * np.arange(int(coordinates["count"]), dtype=np.float64)
        )
        result = chroma_edge_displacement(
            candidate.y[int(measurement["luma_row"]), luma_index],
            candidate.cb[int(measurement["chroma_row"]), chroma_index],
            candidate.cr[int(measurement["chroma_row"]), chroma_index],
            coordinates=coordinate_values,
        )
        values["chroma_displacement_pixels"] = max(
            result["Cb"],
            result["Cr"],
        )
    else:
        raise ProductionEvaluatorError("analytic fixture kind is unsupported")
    if any(
        value is not None and not np.isfinite(float(value))
        for value in values.values()
    ):
        raise ProductionEvaluatorError("analytic metric is nonfinite")
    return values


class LockedAnalyticFixtureCapability:
    """Evaluate the 14 locked fixtures in both domains through native controls."""

    def __init__(
        self,
        *,
        metric_policy_sha256: str,
        degradation_policy: Mapping[str, object],
        writer: NativeProductionWriterCapability,
    ) -> None:
        self._manifest = _locked_analytic_fixtures(metric_policy_sha256)
        self.manifest_sha256 = str(self._manifest["manifest_sha256"])
        self._profiles = {
            str(profile["id"]): profile
            for profile in degradation_policy.get("profiles", [])
            if isinstance(profile, dict) and isinstance(profile.get("id"), str)
        }
        self._writer = writer

    def evaluate(
        self,
        *,
        adapter: CandidateAdapter,
        selection_bundle: ControlSelectionBundle,
        comparison_identities: Mapping[str, object],
    ) -> Mapping[str, object]:
        rows_by_domain: Dict[str, list[Mapping[str, object]]] = {
            "engine_raw": [],
            "container_decoded": [],
        }
        native_records: list[Mapping[str, object]] = []
        control_order = (
            "full_ash",
            "best_fixed",
            "conventional",
            "non_ash_selector",
            "state_only",
            "nearest_same_writer",
            "current_production_ash",
        )
        fixtures = self._manifest.get("fixtures")
        if not isinstance(fixtures, list) or len(fixtures) != 14:
            raise ProductionEvaluatorError("locked analytic fixture count differs")
        for definition in fixtures:
            if not isinstance(definition, dict):
                raise ProductionEvaluatorError("analytic fixture is not an object")
            target, support = _analytic_reference(definition)
            profile = self._profiles.get(str(definition["degradation_profile_id"]))
            if not isinstance(profile, dict):
                raise ProductionEvaluatorError("analytic degradation profile is absent")
            pre_boundary = apply_degradation(target, profile)
            if frame_sha256(pre_boundary) != definition["low_resolution_frame_sha256"]:
                raise ProductionEvaluatorError("analytic low-resolution hash changed")
            _, low_resolution = _round_trip_locked_bt709_video_range_nv12(
                pre_boundary
            )
            low_resolution = _freeze_frame(low_resolution)
            geometry = definition["target_geometry"]
            if not isinstance(geometry, dict):
                raise ProductionEvaluatorError("analytic target geometry is absent")
            context = CandidateContext(
                y_shape=tuple(int(value) for value in geometry["y"]),
                cb_shape=tuple(int(value) for value in geometry["cb"]),
                cr_shape=tuple(int(value) for value in geometry["cr"]),
                target_route=str(definition["target_route"]),
            )
            cache_token, cache_manifest, _ = _prepare_native_output_cache(
                adapter=adapter,
                frame=low_resolution,
                context=context,
                source_asset_id=str(definition["fixture_id"]),
                degradation_profile_id=None,
                degradation_profile_sha256=None,
                shared_bank_configuration_sha256=(
                    selection_bundle.shared_bank_configuration_sha256
                ),
            )
            for descriptor_id in FIXED_DESCRIPTOR_IDS:
                output, _ = _invoke_cached_fixed(
                    adapter=adapter,
                    cache_token=cache_token,
                    cache_manifest=cache_manifest,
                    descriptor_id=descriptor_id,
                    context=context,
                    shared_bank_configuration_sha256=(
                        selection_bundle.shared_bank_configuration_sha256
                    ),
                )
            raw_outputs: Dict[str, PlanarFrame] = {}
            for key in control_order:
                output, record = _invoke_native_control(
                    adapter=adapter,
                    request=selection_bundle.request(key),
                    low_resolution=low_resolution,
                    context=context,
                )
                _, boundary_output = _round_trip_locked_bt709_video_range_nv12(
                    output
                )
                if frame_sha256(boundary_output) != frame_sha256(output):
                    raise ProductionEvaluatorError(
                        "analytic native output is not on the common boundary"
                    )
                raw_outputs[key] = output
                native_records.append(record)
            raw_outputs["state_plus_branch"] = raw_outputs["full_ash"]
            if context.target_route == "direct-3over2":
                output, record = _invoke_native_control(
                    adapter=adapter,
                    request=selection_bundle.request("h07_direct_3_over_2"),
                    low_resolution=low_resolution,
                    context=context,
                )
                _, boundary_output = _round_trip_locked_bt709_video_range_nv12(
                    output
                )
                if frame_sha256(boundary_output) != frame_sha256(output):
                    raise ProductionEvaluatorError(
                        "analytic H07 output is not on the common boundary"
                    )
                raw_outputs["h07_direct_3_over_2"] = output
                native_records.append(record)

            decoded_outputs: Dict[str, PlanarFrame] = {}
            writer_evidence: Dict[str, str] = {}
            for key, output in raw_outputs.items():
                result = self._writer.round_trip(
                    control_key=f"analytic:{definition['fixture_id']}:{key}",
                    frame=output,
                    context=context,
                )
                decoded_outputs[key] = _validate_writer_round_trip(
                    writer=self._writer,
                    result=result,
                    control_key=f"analytic:{definition['fixture_id']}:{key}",
                    raw_frame=output,
                    context=context,
                )
                writer_evidence[key] = result.evidence_sha256

            for domain, outputs in (
                ("engine_raw", raw_outputs),
                ("container_decoded", decoded_outputs),
            ):
                output_hashes: Dict[str, object] = {
                    key: frame_sha256(value) for key, value in outputs.items()
                }
                metric_values: Dict[str, object] = {
                    key: _analytic_metric_bundle(
                        definition,
                        target,
                        value,
                        support,
                    )
                    for key, value in outputs.items()
                }
                output_hashes["h07_direct_3_over_2"] = output_hashes.get(
                    "h07_direct_3_over_2"
                )
                metric_values["h07_direct_3_over_2"] = metric_values.get(
                    "h07_direct_3_over_2"
                )
                row = {
                    "fixture_id": definition["fixture_id"],
                    "fixture_kind": definition["fixture_kind"],
                    "fixture_definition_sha256": canonical_sha256(definition),
                    "analytic_fixture_manifest_sha256": self.manifest_sha256,
                    "target_route": definition["target_route"],
                    "degraded_reference_frame_sha256": definition[
                        "low_resolution_frame_sha256"
                    ],
                    "input_frame_sha256": frame_sha256(low_resolution),
                    "comparison_domain": domain,
                    "comparison_identities": dict(comparison_identities),
                    "control_output_sha256_values": output_hashes,
                    "metrics_by_control": metric_values,
                    "writer_evidence_sha256_values": (
                        {key: None for key in output_hashes}
                        if domain == "engine_raw"
                        else {
                            **writer_evidence,
                            "h07_direct_3_over_2": writer_evidence.get(
                                "h07_direct_3_over_2"
                            ),
                        }
                    ),
                }
                rows_by_domain[domain].append(row)
        rows = rows_by_domain["engine_raw"] + rows_by_domain[
            "container_decoded"
        ]
        document: Dict[str, object] = {
            "schema_version": "1.0.0",
            "artifact_kind": "p06_analytic_fixture_results",
            "manifest_sha256": self.manifest_sha256,
            "shared_bank_configuration_sha256": (
                selection_bundle.shared_bank_configuration_sha256
            ),
            "ordinary_candidate_reconstruct_invocations": 0,
            "results": rows,
            "native_control_records": native_records,
            "status": "pass",
        }
        document["result_sha256"] = canonical_sha256(document)
        return document


def locked_analytic_fixture_capability(
    *,
    metric_policy_sha256: str,
    degradation_policy: Mapping[str, object],
    writer: NativeProductionWriterCapability,
) -> LockedAnalyticFixtureCapability:
    """Build the concrete locked analytic evaluator used by P06."""

    return LockedAnalyticFixtureCapability(
        metric_policy_sha256=metric_policy_sha256,
        degradation_policy=degradation_policy,
        writer=writer,
    )
