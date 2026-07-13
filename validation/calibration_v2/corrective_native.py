"""Fail-closed Python boundary for the native corrective diagnostic operation."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass, field
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Mapping, Sequence
import uuid

from validation.calibration_v2.corrective_diagnostics import (
    ANISOTROPY_CELLS,
    COORDINATE_CELLS,
    RISK_THRESHOLD_BANDS,
    RISK_WEIGHT_PAIRS,
    contract_route_for_evaluator_route,
)
from validation.quality.src.mirmir_quality.arrays import PlanarFrame, frame_sha256
from validation.quality.src.mirmir_quality.json_tools import (
    canonical_json_bytes,
    canonical_sha256,
    validate_schema,
)
from validation.quality.src.mirmir_quality.production_dry_run import (
    _video_range_nv12_to_planar,
)


CALIBRATION_ROOT = Path(__file__).resolve().parent
_COORDINATE_SCHEMA = (
    CALIBRATION_ROOT / "schemas" / "coordinate-model-contract-v3.schema.json"
)
_REQUEST_FIELDS = {
    "schema_version",
    "operation",
    "configuration_id",
    "compiler_inputs_sha256",
    "coordinate_model_contract_path",
    "coordinate_model_contract_sha256",
    "analysis_grid_source_step",
    "output_descriptors",
    "production_v2_reference_output_path",
    "frame",
}
_FRAME_FIELDS = {
    "request_id",
    "route",
    "input_path",
    "input_sha256",
    "input_width",
    "input_height",
    "output_path",
    "output_width",
    "output_height",
    "pixel_format",
    "matrix",
    "range",
    "chroma_siting",
}
_RESPONSE_FIELDS = {
    "schema_version",
    "status",
    "request_sha256",
    "corrective_diagnostic",
}
_DIAGNOSTIC_FIELDS = {
    "schema_version",
    "status",
    "split",
    "validation_accessed",
    "holdout_accessed",
    "selected_winner",
    "request_id",
    "target_route",
    "configuration_id",
    "compiler_inputs_sha256",
    "candidate_vector_sha256",
    "shared_bank_configuration_sha256",
    "mapping_sha256",
    "operator_bank_sha256",
    "metric_policy_sha256",
    "calibration_plan_sha256",
    "corpus_lock_bundle_sha256",
    "candidate_lut_runtime_manifest_sha256",
    "native_invocation_proof",
    "input_sha256",
    "coordinate_model_contract_file_sha256",
    "coordinate_oracle_matrix_sha256",
    "coordinate_experiment_dimensions_sha256",
    "analysis_grid_source_step",
    "analysis_cell_count",
    "output_plane_hash_contract",
    "normalized_plane_hash_contract",
    "analysis_grid_hash_contract",
    "analysis_grid_sha256",
    "generic_lut",
    "session_counters",
    "production_v2_reference",
    "cells",
    "risk_state",
}
_GENERIC_LUT_FIELDS = {
    "whole_file_sha256",
    "payload_sha256",
    "entry_count",
    "parameter_count",
    "header_crc32",
    "payload_crc32",
    "offline_path_evaluation_count",
    "runtime_tree_generation_count",
    "maximum_operator_evaluations",
    "serialization_rebind_contract",
    "original_coordinate_policy",
    "serialized_coordinate_policy",
    "serialization_rebind_applied",
    "serialization_rebind_sha256",
}
_SESSION_COUNTER_FIELDS = {
    "input_decode_count",
    "analysis_grid_build_count",
    "generic_compile_count_for_route",
    "generic_dispatch_count",
    "plane_diagnostic_count",
    "risk_diagnostic_count",
    "production_v2_dispatch_count",
    "output_write_count",
    "output_reopen_count",
}
_PRODUCTION_REFERENCE_FIELDS = {
    "output_path",
    "output_nv12_sha256",
    "output_frame_sha256",
    "planes",
    "lut_whole_file_sha256",
    "lut_payload_sha256",
    "lut_entry_count",
}
_CELL_FIELDS = {
    "ordinal",
    "block_id",
    "coordinate_cell_id",
    "anisotropy_cell_id",
    "output_path",
    "output_nv12_sha256",
    "output_frame_sha256",
    "planes",
}
_PLANE_FIELDS = {
    "coordinate_policy",
    "anisotropy_strength_q12",
    "sample_count",
    "output_plane_sha256",
    "normalized_plane_sha256",
    "source_aligned_entry_flag_sample_count",
    "source_aligned_sample_preservation_count",
    "numerical_fallback_count",
}
_PRODUCTION_PLANE_FIELDS = {
    "output_plane_sha256",
    "normalized_plane_sha256",
}
_RISK_FIELDS = {
    "analysis_grid_source_step",
    "analysis_cell_count",
    "baseline_analysis_grid_sha256",
    "cells",
}
_RISK_CELL_FIELDS = {
    "ordinal",
    "cell_id",
    "risk_weight_pair",
    "risk_threshold_band",
    "risk_zero_count",
    "risk_one_count",
    "risk_proxy_minimum_unorm15",
    "risk_proxy_maximum_unorm15",
    "risk_proxy_value_count",
    "risk_proxy_vector_sha256",
}
_EXPECTED_ENTRY_COUNT = {
    "direct-2x": 4_096,
    "direct-3over2": 9_216,
}
_CRC32_PATTERN = "0x00000000"
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


class CorrectiveNativeContractError(ValueError):
    """The native corrective request, response, or output bytes are invalid."""


@dataclass(frozen=True)
class CorrectiveOutputIdentity:
    """Identity and content bound to one native-created output leaf."""

    device: int
    inode: int
    owner_uid: int
    size_bytes: int
    mtime_ns: int
    sha256: str


@dataclass
class _DescriptorLease:
    descriptor: int

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


@dataclass(frozen=True)
class CorrectiveNativeRequestBinding:
    request: Mapping[str, object]
    route: str
    contract_route: str
    input_path: Path
    input_sha256: str
    input_size_bytes: int
    coordinate_contract_path: Path
    coordinate_contract_sha256: str
    coordinate_oracle_matrix_sha256: str
    coordinate_experiment_dimensions_sha256: str
    output_paths: tuple[Path, ...]
    output_directory: Path
    output_directory_identity: tuple[int, int]
    output_directory_uid: int
    output_directory_lease: _DescriptorLease
    output_width: int
    output_height: int
    output_identities: dict[str, CorrectiveOutputIdentity] = field(
        default_factory=dict
    )


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CorrectiveNativeContractError(message)


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _is_crc32(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == len(_CRC32_PATTERN)
        and value.startswith("0x")
        and all(character in "0123456789ABCDEF" for character in value[2:])
    )


def _serialization_rebind_sha256(
    *,
    route: str,
    original_policy: str,
    serialized_policy: str,
    applied: bool,
) -> str:
    payload = bytearray(
        b"MIRMIR-ASH-GENERIC-V3-DIAGNOSTIC-SERIALIZATION-REBIND-V1\0"
    )
    for value in (route, original_policy, serialized_policy):
        payload.extend(value.encode("utf-8"))
        payload.append(0)
    payload.append(1 if applied else 0)
    return hashlib.sha256(payload).hexdigest()


def _integer(value: object, label: str, *, minimum: int = 0) -> int:
    _require(
        isinstance(value, int) and not isinstance(value, bool) and value >= minimum,
        f"{label} is invalid",
    )
    return int(value)


def _object(value: object, fields: set[str], label: str) -> Mapping[str, object]:
    _require(isinstance(value, dict), f"{label} is not an object")
    _require(set(value) == fields, f"{label} field set differs")
    return value


def _sequence(value: object, count: int, label: str) -> Sequence[object]:
    _require(isinstance(value, list) and len(value) == count, f"{label} count differs")
    return value


def _absolute_lexical_path(value: object, label: str) -> Path:
    _require(isinstance(value, str), f"{label} is not a path string")
    path = Path(value)
    _require(
        path.is_absolute()
        and len(path.parts) > 1
        and "\x00" not in value
        and "//" not in value
        and all(part not in {".", ".."} for part in path.parts)
        and os.fspath(path) == value,
        f"{label} is not a safe absolute lexical path",
    )
    return path


def _open_directory_descriptor(path: Path) -> int:
    """Open an existing absolute directory chain without following symlinks."""

    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path.anchor, flags)
    try:
        for part in path.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            metadata = os.fstat(child)
            if not stat.S_ISDIR(metadata.st_mode):
                os.close(child)
                raise CorrectiveNativeContractError(
                    f"corrective directory component is not a directory: {path}"
                )
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _create_pinned_output_directory(
    paths: Sequence[Path],
) -> tuple[Path, tuple[int, int], int, _DescriptorLease]:
    parents = {path.parent for path in paths}
    _require(
        len(parents) == 1,
        "corrective outputs are not confined to one transaction directory",
    )
    output_directory = next(iter(parents))
    grandparent = _open_directory_descriptor(output_directory.parent)
    descriptor = -1
    created = False
    created_identity: tuple[int, int] | None = None
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        try:
            os.stat(
                output_directory.name,
                dir_fd=grandparent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise CorrectiveNativeContractError(
                "corrective output transaction directory already exists"
            )
        os.mkdir(output_directory.name, 0o700, dir_fd=grandparent)
        created = True
        descriptor = os.open(output_directory.name, flags, dir_fd=grandparent)
        metadata = os.fstat(descriptor)
        created_identity = (metadata.st_dev, metadata.st_ino)
        _require(
            stat.S_ISDIR(metadata.st_mode)
            and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) == 0o700
            and os.listdir(descriptor) == [],
            "corrective output transaction directory is not private and empty",
        )
        return (
            output_directory,
            (metadata.st_dev, metadata.st_ino),
            metadata.st_uid,
            _DescriptorLease(descriptor),
        )
    except BaseException as primary_error:
        if created:
            retained_path = output_directory
            try:
                quarantine_name = (
                    ".mirmir-corrective-creation-failure-"
                    f"{uuid.uuid4().hex}"
                )
                _rename_exclusive_at(
                    output_directory.name,
                    quarantine_name,
                    directory_descriptor=grandparent,
                )
                retained_path = output_directory.parent / quarantine_name
                quarantined = os.stat(
                    quarantine_name,
                    dir_fd=grandparent,
                    follow_symlinks=False,
                )
                if created_identity is not None:
                    _require(
                        stat.S_ISDIR(quarantined.st_mode)
                        and (quarantined.st_dev, quarantined.st_ino)
                        == created_identity,
                        "corrective creation-failure quarantine identity differs",
                    )
                os.fsync(grandparent)
            except BaseException as recovery_error:
                try:
                    primary_error.retained_creation_failure_path = retained_path  # type: ignore[attr-defined]
                    primary_error.creation_failure_recovery_error = recovery_error  # type: ignore[attr-defined]
                except BaseException:
                    combined = CorrectiveNativeContractError(
                        "corrective output directory creation and retention both failed"
                    )
                    combined.primary_error = primary_error  # type: ignore[attr-defined]
                    combined.cleanup_error = recovery_error  # type: ignore[attr-defined]
                    raise combined from primary_error
            else:
                try:
                    primary_error.retained_creation_failure_path = retained_path  # type: ignore[attr-defined]
                except BaseException:
                    pass
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        os.close(grandparent)


def _open_pinned_output_directory(
    paths: Sequence[Path],
) -> tuple[Path, tuple[int, int], int, _DescriptorLease]:
    parents = {path.parent for path in paths}
    _require(
        len(parents) == 1,
        "corrective outputs are not confined to one transaction directory",
    )
    output_directory = next(iter(parents))
    descriptor = _open_directory_descriptor(output_directory)
    metadata = os.fstat(descriptor)
    _require(
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) == 0o700,
        "corrective output transaction directory is not private",
    )
    return (
        output_directory,
        (metadata.st_dev, metadata.st_ino),
        metadata.st_uid,
        _DescriptorLease(descriptor),
    )


def _read_regular_at(
    parent_descriptor: int,
    name: str,
    label: str,
) -> tuple[bytes, CorrectiveOutputIdentity]:
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise CorrectiveNativeContractError(f"{label} is absent") from error
    _require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} identity changed while opening",
        )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    except OSError as error:
        raise CorrectiveNativeContractError(f"{label} could not be read") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after_path = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise CorrectiveNativeContractError(
            f"{label} disappeared after reading"
        ) from error
    identity = (before.st_dev, before.st_ino)
    _require(
        (after.st_dev, after.st_ino) == identity
        and (after_path.st_dev, after_path.st_ino) == identity
        and after.st_size == before.st_size == after_path.st_size
        and after.st_mtime_ns == before.st_mtime_ns == after_path.st_mtime_ns,
        f"{label} changed while reading",
    )
    payload = b"".join(chunks)
    return payload, CorrectiveOutputIdentity(
        device=before.st_dev,
        inode=before.st_ino,
        owner_uid=before.st_uid,
        size_bytes=before.st_size,
        mtime_ns=before.st_mtime_ns,
        sha256=hashlib.sha256(payload).hexdigest(),
    )


def _rename_exclusive_at(
    source_name: str,
    destination_name: str,
    *,
    directory_descriptor: int,
) -> None:
    if _RENAMEATX_NP is None:
        raise CorrectiveNativeContractError(
            "exclusive corrective quarantine rename is unavailable"
        )
    ctypes.set_errno(0)
    result = _RENAMEATX_NP(
        directory_descriptor,
        os.fsencode(source_name),
        directory_descriptor,
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


def _read_stable_regular(path: Path, label: str) -> bytes:
    try:
        before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise CorrectiveNativeContractError(f"{label} is absent") from error
    _require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
            f"{label} identity changed while opening",
        )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after_read = os.fstat(descriptor)
    except OSError as error:
        raise CorrectiveNativeContractError(f"{label} could not be read") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    try:
        after_path = os.stat(path, follow_symlinks=False)
    except OSError as error:
        raise CorrectiveNativeContractError(f"{label} disappeared after reading") from error
    identity = (before.st_dev, before.st_ino)
    _require(
        (after_read.st_dev, after_read.st_ino) == identity
        and (after_path.st_dev, after_path.st_ino) == identity
        and after_read.st_size == before.st_size
        and after_path.st_size == before.st_size
        and after_read.st_mtime_ns == before.st_mtime_ns
        and after_path.st_mtime_ns == before.st_mtime_ns,
        f"{label} changed while reading",
    )
    return b"".join(chunks)


def _strict_contract(payload: bytes) -> Mapping[str, object]:
    duplicate = False

    def pairs(values: Sequence[tuple[str, object]]) -> dict[str, object]:
        nonlocal duplicate
        result: dict[str, object] = {}
        for key, value in values:
            duplicate = duplicate or key in result
            result[key] = value
        return result

    def reject_constant(value: str) -> object:
        raise ValueError(f"nonstandard constant: {value}")

    try:
        document = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise CorrectiveNativeContractError(
            "coordinate contract is not strict JSON"
        ) from error
    _require(not duplicate, "coordinate contract repeats a JSON key")
    _require(isinstance(document, dict), "coordinate contract root is not an object")
    _require(
        payload == canonical_json_bytes(document) + b"\n",
        "coordinate contract is not canonical compact JSON plus LF",
    )
    try:
        validate_schema(document, _COORDINATE_SCHEMA)
    except (TypeError, ValueError) as error:
        raise CorrectiveNativeContractError(str(error)) from error
    return document


def _expected_output_geometry(route: str, width: int, height: int) -> tuple[int, int]:
    if route == "direct-2x":
        return width * 2, height * 2
    _require(route == "direct-3over2", "native corrective route is invalid")
    _require(width % 2 == 0 and height % 2 == 0, "3-over-2 input geometry is odd")
    return width * 3 // 2, height * 3 // 2


def validate_corrective_native_request(
    document: Mapping[str, object],
    *,
    configuration: Mapping[str, object],
    require_outputs_absent: bool,
) -> CorrectiveNativeRequestBinding:
    """Validate every request binding before allowing native execution."""

    request = _object(document, _REQUEST_FIELDS, "corrective request")
    _require(
        request.get("schema_version") == "1.0.0"
        and request.get("operation") == "diagnose_corrective_frame",
        "corrective request identity differs",
    )
    _require(
        request.get("configuration_id") == configuration.get("configuration_id")
        and request.get("compiler_inputs_sha256")
        == configuration.get("compiler_inputs_sha256")
        and _is_sha256(request.get("compiler_inputs_sha256")),
        "corrective request configuration identity differs",
    )
    frame = _object(request.get("frame"), _FRAME_FIELDS, "corrective frame")
    route = frame.get("route")
    _require(route in _EXPECTED_ENTRY_COUNT, "corrective frame route differs")
    assert isinstance(route, str)
    contract_route = contract_route_for_evaluator_route(route)
    request_id = frame.get("request_id")
    _require(
        isinstance(request_id, str) and 0 < len(request_id) <= 128,
        "corrective frame request ID is invalid",
    )
    width = _integer(frame.get("input_width"), "corrective input width", minimum=1)
    height = _integer(frame.get("input_height"), "corrective input height", minimum=1)
    output_width = _integer(frame.get("output_width"), "corrective output width", minimum=1)
    output_height = _integer(frame.get("output_height"), "corrective output height", minimum=1)
    _require(width % 2 == 0 and height % 2 == 0, "corrective input is not even 4:2:0")
    _require(
        (output_width, output_height)
        == _expected_output_geometry(route, width, height)
        and output_width % 2 == 0
        and output_height % 2 == 0,
        "corrective output geometry differs from route",
    )
    _require(
        frame.get("pixel_format") == "420v"
        and frame.get("matrix") == "BT.709"
        and frame.get("range") == "video"
        and frame.get("chroma_siting") == "left",
        "corrective frame pixel contract differs",
    )
    input_path = _absolute_lexical_path(frame.get("input_path"), "corrective input path")
    input_payload = _read_stable_regular(input_path, "corrective input")
    input_hash = hashlib.sha256(input_payload).hexdigest()
    _require(
        len(input_payload) == width * height * 3 // 2
        and frame.get("input_sha256") == input_hash,
        "corrective input byte binding differs",
    )

    contract_path = _absolute_lexical_path(
        request.get("coordinate_model_contract_path"),
        "coordinate contract path",
    )
    contract_payload = _read_stable_regular(contract_path, "coordinate contract")
    contract_hash = hashlib.sha256(contract_payload).hexdigest()
    _require(
        request.get("coordinate_model_contract_sha256") == contract_hash,
        "coordinate contract file hash differs",
    )
    contract = _strict_contract(contract_payload)
    oracle_hash = canonical_sha256(contract["coordinate_oracles"])
    dimensions_hash = canonical_sha256(contract["experiment_dimensions"])

    step = _integer(
        request.get("analysis_grid_source_step"),
        "corrective analysis-grid step",
        minimum=1,
    )
    _require(step in {1, 2, 4}, "corrective analysis-grid step is unsupported")
    candidate = configuration.get("candidate_vector")
    _require(isinstance(candidate, dict), "native configuration candidate vector is absent")
    _require(
        candidate.get(f"{contract_route}_analysis_grid_source_step") == step,
        "corrective analysis-grid step differs from the candidate",
    )

    descriptors = _sequence(
        request.get("output_descriptors"),
        len(COORDINATE_CELLS) * len(ANISOTROPY_CELLS),
        "corrective output descriptors",
    )
    output_paths: list[Path] = []
    for ordinal, raw in enumerate(descriptors):
        descriptor = _object(
            raw,
            {"ordinal", "coordinate_cell_id", "anisotropy_cell_id", "output_path"},
            "corrective output descriptor",
        )
        coordinate_index = ordinal // len(ANISOTROPY_CELLS)
        anisotropy_index = ordinal % len(ANISOTROPY_CELLS)
        _require(
            descriptor.get("ordinal") == ordinal
            and descriptor.get("coordinate_cell_id")
            == COORDINATE_CELLS[coordinate_index]["cell_id"]
            and descriptor.get("anisotropy_cell_id")
            == ANISOTROPY_CELLS[anisotropy_index]["cell_id"],
            "corrective output descriptor identity or order differs",
        )
        output_paths.append(
            _absolute_lexical_path(
                descriptor.get("output_path"),
                "corrective cell output path",
            )
        )
    production_path = _absolute_lexical_path(
        request.get("production_v2_reference_output_path"),
        "production-V2 output path",
    )
    _require(
        request.get("production_v2_reference_output_path") == frame.get("output_path"),
        "production-V2 output path differs from the frame",
    )
    output_paths.append(production_path)
    _require(
        len(set(output_paths)) == 17
        and input_path not in output_paths
        and contract_path not in output_paths,
        "corrective output paths are not unique",
    )
    if require_outputs_absent:
        (
            output_directory,
            output_directory_identity,
            output_directory_uid,
            output_directory_lease,
        ) = _create_pinned_output_directory(output_paths)
    else:
        (
            output_directory,
            output_directory_identity,
            output_directory_uid,
            output_directory_lease,
        ) = _open_pinned_output_directory(output_paths)
    return CorrectiveNativeRequestBinding(
        request=json.loads(canonical_json_bytes(request)),
        route=route,
        contract_route=contract_route,
        input_path=input_path,
        input_sha256=input_hash,
        input_size_bytes=len(input_payload),
        coordinate_contract_path=contract_path,
        coordinate_contract_sha256=contract_hash,
        coordinate_oracle_matrix_sha256=oracle_hash,
        coordinate_experiment_dimensions_sha256=dimensions_hash,
        output_paths=tuple(output_paths),
        output_directory=output_directory,
        output_directory_identity=output_directory_identity,
        output_directory_uid=output_directory_uid,
        output_directory_lease=output_directory_lease,
        output_width=output_width,
        output_height=output_height,
    )


def _binding_output_descriptor(binding: CorrectiveNativeRequestBinding) -> int:
    descriptor = binding.output_directory_lease.descriptor
    _require(descriptor >= 0, "corrective output transaction is closed")
    metadata = os.fstat(descriptor)
    _require(
        stat.S_ISDIR(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino)
        == binding.output_directory_identity
        and metadata.st_uid == binding.output_directory_uid,
        "pinned corrective output directory identity differs",
    )
    try:
        current = os.stat(binding.output_directory, follow_symlinks=False)
    except OSError as error:
        raise CorrectiveNativeContractError(
            "corrective output transaction path disappeared"
        ) from error
    _require(
        stat.S_ISDIR(current.st_mode)
        and (current.st_dev, current.st_ino) == binding.output_directory_identity
        and current.st_uid == binding.output_directory_uid,
        "corrective output transaction path identity differs",
    )
    return descriptor


def capture_corrective_native_outputs(
    binding: CorrectiveNativeRequestBinding,
    *,
    require_all: bool,
) -> None:
    """Capture native-created leaves by descriptor before recursive validation."""

    descriptor = _binding_output_descriptor(binding)
    expected_names = {path.name for path in binding.output_paths}
    actual_names = set(os.listdir(descriptor))
    unexpected = actual_names - expected_names
    _require(not unexpected, "corrective output transaction contains unknown entries")
    if require_all:
        _require(
            actual_names == expected_names,
            "corrective output transaction is incomplete",
        )
    for path in binding.output_paths:
        if path.name not in actual_names:
            continue
        payload, identity = _read_regular_at(
            descriptor,
            path.name,
            "corrective native output",
        )
        _require(
            identity.owner_uid == binding.output_directory_uid,
            "corrective native output owner differs",
        )
        previous = binding.output_identities.get(path.name)
        _require(
            previous is None or previous == identity,
            "corrective native output identity changed after capture",
        )
        _require(
            identity.sha256 == hashlib.sha256(payload).hexdigest(),
            "corrective native output captured hash differs",
        )
        binding.output_identities[path.name] = identity


def close_corrective_native_binding(
    binding: CorrectiveNativeRequestBinding,
) -> None:
    """Close the retained output-directory descriptor exactly once."""

    binding.output_directory_lease.close()


def _sanitize_captured_regular_at(
    directory_descriptor: int,
    name: str,
    expected: CorrectiveOutputIdentity,
) -> None:
    """Truncate only the descriptor-pinned captured inode and retain its stub."""

    _, current = _read_regular_at(
        directory_descriptor,
        name,
        "corrective output before sanitation",
    )
    _require(current == expected, "corrective output changed before sanitation")
    descriptor = os.open(
        name,
        os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino)
            == (expected.device, expected.inode),
            "foreign corrective output was preserved before sanitation",
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
        (sanitized.st_dev, sanitized.st_ino)
        == (expected.device, expected.inode)
        and sanitized.st_size == 0
        and (path_state.st_dev, path_state.st_ino)
        == (expected.device, expected.inode)
        and path_state.st_size == 0,
        "corrective sanitized stub path identity differs; foreign leaf preserved",
    )


def cleanup_corrective_native_outputs(
    binding: CorrectiveNativeRequestBinding,
) -> Mapping[str, object]:
    """Quarantine, sanitize pinned output inodes, and retain zero-byte stubs."""

    descriptor = _binding_output_descriptor(binding)
    recorded_names = set(binding.output_identities)
    actual_names = set(os.listdir(descriptor))
    failures: list[BaseException] = []
    if actual_names != recorded_names:
        failures.append(
            CorrectiveNativeContractError(
                "corrective output set differs from captured leaves; preserved"
            )
        )
    for name in sorted(actual_names & recorded_names):
        try:
            _, current = _read_regular_at(
                descriptor,
                name,
                "corrective cleanup pre-quarantine output",
            )
            if current != binding.output_identities[name]:
                raise CorrectiveNativeContractError(
                    f"replaced corrective output was preserved: {name}"
                )
        except BaseException as error:
            failures.append(error)
    if failures:
        error = CorrectiveNativeContractError(
            "corrective native output cleanup detected tamper; transaction preserved"
        )
        error.cleanup_failures = tuple(failures)  # type: ignore[attr-defined]
        error.preserved_transaction_path = binding.output_directory  # type: ignore[attr-defined]
        raise error from failures[0]

    grandparent = _open_directory_descriptor(binding.output_directory.parent)
    quarantine_name = (
        f".mirmir-corrective-quarantine-{uuid.uuid4().hex}"
    )
    quarantine_path = binding.output_directory.parent / quarantine_name
    quarantine_renamed = False
    sanitation_progress = False
    try:
        _rename_exclusive_at(
            binding.output_directory.name,
            quarantine_name,
            directory_descriptor=grandparent,
        )
        quarantine_renamed = True
        quarantined = os.stat(
            quarantine_name,
            dir_fd=grandparent,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISDIR(quarantined.st_mode)
            and (quarantined.st_dev, quarantined.st_ino)
            == binding.output_directory_identity,
            "quarantined corrective directory identity differs",
        )
        try:
            os.stat(
                binding.output_directory.name,
                dir_fd=grandparent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise CorrectiveNativeContractError(
                "corrective transaction path was recreated during quarantine"
            )

        quarantined_leaves: dict[str, str] = {}
        for name in sorted(recorded_names):
            private_name = f".owned-output-{uuid.uuid4().hex}"
            _rename_exclusive_at(
                name,
                private_name,
                directory_descriptor=descriptor,
            )
            quarantined_leaves[name] = private_name
            _, current = _read_regular_at(
                descriptor,
                private_name,
                "corrective quarantined output",
            )
            _require(
                current == binding.output_identities[name],
                f"corrective output replacement was quarantined and preserved: {name}",
            )
        _require(
            set(os.listdir(descriptor)) == set(quarantined_leaves.values()),
            "corrective quarantine changed while isolating leaves",
        )
        for original_name, private_name in quarantined_leaves.items():
            _, current = _read_regular_at(
                descriptor,
                private_name,
                "corrective quarantined output final check",
            )
            _require(
                current == binding.output_identities[original_name],
                "corrective quarantined output changed before sanitation",
            )
        sanitation_leaves: dict[str, str] = {}
        for original_name, private_name in quarantined_leaves.items():
            sanitation_name = f".owned-sanitized-stub-{uuid.uuid4().hex}"
            _rename_exclusive_at(
                private_name,
                sanitation_name,
                directory_descriptor=descriptor,
            )
            sanitation_leaves[original_name] = sanitation_name
            _, current = _read_regular_at(
                descriptor,
                sanitation_name,
                "corrective sanitation-isolated output",
            )
            _require(
                current == binding.output_identities[original_name],
                "foreign corrective output reached the sanitation set; preserved",
            )
        _require(
            set(os.listdir(descriptor)) == set(sanitation_leaves.values()),
            "corrective sanitation set changed before truncation",
        )
        for original_name, sanitation_name in sanitation_leaves.items():
            sanitation_progress = True
            _sanitize_captured_regular_at(
                descriptor,
                sanitation_name,
                binding.output_identities[original_name],
            )
        _require(
            set(os.listdir(descriptor)) == set(sanitation_leaves.values()),
            "corrective sanitized quarantine leaf set differs",
        )
        empty_sha256 = hashlib.sha256(b"").hexdigest()
        retained_stubs = []
        for original_name, sanitation_name in sorted(
            sanitation_leaves.items()
        ):
            payload, sanitized = _read_regular_at(
                descriptor,
                sanitation_name,
                "corrective retained sanitation stub",
            )
            _require(
                payload == b""
                and sanitized.size_bytes == 0
                and sanitized.sha256 == empty_sha256
                and (sanitized.device, sanitized.inode)
                == (
                    binding.output_identities[original_name].device,
                    binding.output_identities[original_name].inode,
                ),
                "corrective retained sanitation stub differs",
            )
            retained_stubs.append(
                {
                    "original_name": original_name,
                    "retained_name": sanitation_name,
                    "device": sanitized.device,
                    "inode": sanitized.inode,
                    "size_bytes": sanitized.size_bytes,
                    "sha256": sanitized.sha256,
                }
            )
        os.fsync(descriptor)
        os.fsync(grandparent)
        retained_transaction_identity = {
            "device": quarantined.st_dev,
            "inode": quarantined.st_ino,
        }
        return {
            "status": "sanitized_retained",
            "retained_transaction_path": os.fspath(quarantine_path),
            "retained_transaction_identity": retained_transaction_identity,
            "retained_stub_count": len(retained_stubs),
            "retained_stubs": retained_stubs,
            "retained_stub_manifest_sha256": canonical_sha256(
                retained_stubs
            ),
            "original_output_manifest_sha256": canonical_sha256(
                [
                    {
                        "original_name": name,
                        "sha256": binding.output_identities[name].sha256,
                        "size_bytes": binding.output_identities[name].size_bytes,
                    }
                    for name in sorted(binding.output_identities)
                ]
            ),
        }
    except BaseException as error:
        if sanitation_progress:
            message = (
                "corrective native output sanitation failed after irreversible progress"
            )
        else:
            message = (
                "corrective native output quarantine failed; evidence preserved"
            )
        wrapped = CorrectiveNativeContractError(message)
        wrapped.cleanup_failures = (error,)  # type: ignore[attr-defined]
        if not sanitation_progress:
            preserved = (
                quarantine_path
                if quarantine_renamed
                else binding.output_directory
            )
            try:
                metadata = os.stat(preserved, follow_symlinks=False)
            except OSError:
                pass
            else:
                if stat.S_ISDIR(metadata.st_mode):
                    wrapped.preserved_transaction_path = preserved  # type: ignore[attr-defined]
        elif quarantine_renamed:
            wrapped.sanitized_transaction_path = quarantine_path  # type: ignore[attr-defined]
        raise wrapped from error
    finally:
        os.close(grandparent)


def _nv12_hashes(payload: bytes, width: int, height: int) -> Mapping[str, str]:
    expected = width * height * 3 // 2
    _require(len(payload) == expected, "corrective output byte count differs")
    y_size = width * height
    chroma = payload[y_size:]
    cb = chroma[0::2]
    cr = chroma[1::2]
    _require(
        len(cb) == len(cr) == width * height // 4,
        "corrective output chroma byte count differs",
    )
    frame = _video_range_nv12_to_planar(payload, width=width, height=height)
    return {
        "output_nv12_sha256": hashlib.sha256(payload).hexdigest(),
        "output_frame_sha256": frame_sha256(frame),
        "y": hashlib.sha256(payload[:y_size]).hexdigest(),
        "cb": hashlib.sha256(cb).hexdigest(),
        "cr": hashlib.sha256(cr).hexdigest(),
    }


def reopen_corrective_output_frame(
    binding: CorrectiveNativeRequestBinding,
    path: Path,
    *,
    width: int,
    height: int,
) -> PlanarFrame:
    """Reopen one validated output as the common normalized 420v frame."""

    _require(path in binding.output_paths, "corrective output path is not bound")
    descriptor = _binding_output_descriptor(binding)
    payload, identity = _read_regular_at(
        descriptor,
        path.name,
        "corrective output",
    )
    _require(
        binding.output_identities.get(path.name) == identity,
        "corrective output identity differs from capture",
    )
    _nv12_hashes(payload, width, height)
    return _video_range_nv12_to_planar(payload, width=width, height=height)


def _validate_output_binding(
    evidence: Mapping[str, object],
    *,
    binding: CorrectiveNativeRequestBinding,
    path: Path,
    width: int,
    height: int,
    plane_objects: bool,
) -> None:
    _require(evidence.get("output_path") == os.fspath(path), "corrective output path differs")
    descriptor = _binding_output_descriptor(binding)
    payload, identity = _read_regular_at(
        descriptor,
        path.name,
        "corrective output",
    )
    _require(
        binding.output_identities.get(path.name) == identity,
        "corrective output identity differs from capture",
    )
    hashes = _nv12_hashes(payload, width, height)
    _require(
        evidence.get("output_nv12_sha256") == hashes["output_nv12_sha256"]
        and evidence.get("output_frame_sha256") == hashes["output_frame_sha256"],
        "corrective output whole-file or frame hash differs",
    )
    planes = evidence.get("planes")
    _require(isinstance(planes, dict) and set(planes) == {"y", "cb", "cr"}, "output planes differ")
    if plane_objects:
        for channel in ("y", "cb", "cr"):
            plane = _object(planes[channel], _PLANE_FIELDS, "corrective plane evidence")
            _require(
                plane.get("output_plane_sha256") == hashes[channel]
                and _is_sha256(plane.get("normalized_plane_sha256")),
                "corrective output plane hash differs",
            )
    else:
        for channel in ("y", "cb", "cr"):
            plane = _object(
                planes[channel],
                _PRODUCTION_PLANE_FIELDS,
                "production-V2 plane evidence",
            )
            _require(
                plane.get("output_plane_sha256") == hashes[channel]
                and _is_sha256(plane.get("normalized_plane_sha256")),
                "production-V2 output plane hash differs",
            )


def _validate_plane(
    plane: Mapping[str, object],
    *,
    policy: str,
    anisotropy: int,
    expected_samples: int,
) -> None:
    _require(
        plane.get("coordinate_policy") == policy
        and plane.get("anisotropy_strength_q12") == anisotropy
        and plane.get("sample_count") == expected_samples,
        "corrective plane policy, anisotropy, or sample count differs",
    )
    _require(
        _is_sha256(plane.get("output_plane_sha256"))
        and _is_sha256(plane.get("normalized_plane_sha256")),
        "plane output hash is invalid",
    )
    for field in (
        "source_aligned_entry_flag_sample_count",
        "source_aligned_sample_preservation_count",
        "numerical_fallback_count",
    ):
        value = _integer(plane.get(field), f"corrective plane {field}")
        _require(value <= expected_samples, f"corrective plane {field} exceeds the plane")
    _require(
        plane.get("source_aligned_entry_flag_sample_count") == 0,
        "generic corrective output used a source-aligned LUT entry flag",
    )


def validate_corrective_native_response(
    response: Mapping[str, object],
    *,
    binding: CorrectiveNativeRequestBinding,
    configuration: Mapping[str, object],
    native_executable_sha256: str,
    native_source_manifest_sha256: str,
    native_process_id: int,
) -> Mapping[str, object]:
    """Recursively validate the response and independently reopen all outputs."""

    _require(
        set(binding.output_identities)
        == {path.name for path in binding.output_paths},
        "corrective native outputs were not captured before validation",
    )
    outer = _object(response, _RESPONSE_FIELDS, "corrective response")
    request_hash = hashlib.sha256(canonical_json_bytes(binding.request)).hexdigest()
    _require(
        outer.get("schema_version") == "1.0.0"
        and outer.get("status") == "ok"
        and outer.get("request_sha256") == request_hash,
        "corrective response request binding differs",
    )
    diagnostic = _object(
        outer.get("corrective_diagnostic"),
        _DIAGNOSTIC_FIELDS,
        "corrective diagnostic",
    )
    frame = binding.request["frame"]
    assert isinstance(frame, dict)
    _require(
        diagnostic.get("schema_version") == "1.0.0"
        and diagnostic.get("status") == "development_diagnostic_no_selection"
        and diagnostic.get("split") == "development"
        and diagnostic.get("validation_accessed") is False
        and diagnostic.get("holdout_accessed") is False
        and diagnostic.get("selected_winner") is None,
        "corrective diagnostic access or selection state differs",
    )
    _require(
        diagnostic.get("request_id") == frame.get("request_id")
        and diagnostic.get("target_route") == binding.contract_route
        and diagnostic.get("configuration_id") == configuration.get("configuration_id")
        and diagnostic.get("compiler_inputs_sha256")
        == configuration.get("compiler_inputs_sha256")
        and diagnostic.get("input_sha256") == binding.input_sha256,
        "corrective diagnostic request identity differs",
    )
    provenance = {
        "candidate_vector_sha256": configuration.get(
            "serialized_candidate_vector_sha256"
        ),
        "shared_bank_configuration_sha256": configuration.get(
            "shared_bank_configuration_sha256"
        ),
        "mapping_sha256": configuration.get("mapping_sha256"),
        "operator_bank_sha256": configuration.get("operator_bank_sha256"),
        "metric_policy_sha256": configuration.get("metric_policy_sha256"),
        "calibration_plan_sha256": configuration.get("calibration_plan_sha256"),
        "corpus_lock_bundle_sha256": configuration.get("corpus_lock_bundle_sha256"),
        "candidate_lut_runtime_manifest_sha256": configuration.get(
            "candidate_lut_runtime_manifest_sha256"
        ),
    }
    _require(
        all(_is_sha256(value) for value in provenance.values())
        and all(diagnostic.get(field) == value for field, value in provenance.items()),
        "corrective diagnostic native configuration provenance differs",
    )
    invocation = _object(
        diagnostic.get("native_invocation_proof"),
        {"protocol", "process_id", "executable_sha256", "source_manifest_sha256"},
        "native invocation proof",
    )
    _require(
        invocation
        == {
            "protocol": "serve-candidate/diagnose_corrective_frame-v1",
            "process_id": native_process_id,
            "executable_sha256": native_executable_sha256,
            "source_manifest_sha256": native_source_manifest_sha256,
        }
        and _is_sha256(native_executable_sha256)
        and _is_sha256(native_source_manifest_sha256)
        and isinstance(native_process_id, int)
        and not isinstance(native_process_id, bool)
        and native_process_id > 0,
        "native invocation proof differs",
    )
    _require(
        diagnostic.get("coordinate_model_contract_file_sha256")
        == binding.coordinate_contract_sha256
        and diagnostic.get("coordinate_oracle_matrix_sha256")
        == binding.coordinate_oracle_matrix_sha256
        and diagnostic.get("coordinate_experiment_dimensions_sha256")
        == binding.coordinate_experiment_dimensions_sha256,
        "corrective coordinate-contract evidence differs",
    )
    reopened_input = _read_stable_regular(binding.input_path, "corrective input")
    _require(
        len(reopened_input) == binding.input_size_bytes
        and hashlib.sha256(reopened_input).hexdigest() == binding.input_sha256,
        "corrective input changed during native execution",
    )
    _require(
        hashlib.sha256(
            _read_stable_regular(binding.coordinate_contract_path, "coordinate contract")
        ).hexdigest()
        == binding.coordinate_contract_sha256,
        "coordinate contract changed during native execution",
    )
    step = _integer(diagnostic.get("analysis_grid_source_step"), "analysis-grid step", minimum=1)
    analysis_count = _integer(diagnostic.get("analysis_cell_count"), "analysis-cell count", minimum=1)
    _require(
        step == binding.request["analysis_grid_source_step"]
        and diagnostic.get("output_plane_hash_contract")
        == "active-nv12-code-bytes-sha256-v1"
        and diagnostic.get("normalized_plane_hash_contract")
        == "mirmir-ash-normalized-plane-f64-be-v1"
        and diagnostic.get("analysis_grid_hash_contract")
        == "mirmir-ash-analysis-grid-v3-be-v1"
        and _is_sha256(diagnostic.get("analysis_grid_sha256")),
        "corrective analysis-grid evidence differs",
    )

    expected_entry_count = _EXPECTED_ENTRY_COUNT[binding.route]
    generic = _object(diagnostic.get("generic_lut"), _GENERIC_LUT_FIELDS, "generic LUT")
    candidate = configuration.get("candidate_vector")
    _require(isinstance(candidate, dict), "native candidate vector is absent")
    original_policy = candidate.get(
        f"{binding.contract_route}_coordinate_policy"
    )
    serialized_policy = "half_pixel_center"
    rebind_applied = original_policy != serialized_policy
    _require(
        _is_sha256(generic.get("whole_file_sha256"))
        and _is_sha256(generic.get("payload_sha256"))
        and generic.get("entry_count") == expected_entry_count
        and _integer(generic.get("parameter_count"), "generic parameter count", minimum=1)
        >= 1
        and _is_crc32(generic.get("header_crc32"))
        and _is_crc32(generic.get("payload_crc32"))
        and generic.get("offline_path_evaluation_count")
        == expected_entry_count * 81
        and generic.get("runtime_tree_generation_count") == 0
        and generic.get("maximum_operator_evaluations") in {1, 2},
        "generic LUT evidence differs",
    )
    _require(
        original_policy
        in {"half_pixel_center", "source_aligned_rational"}
        and generic.get("serialization_rebind_contract")
        == "mirmir-ash-generic-v3-diagnostic-coordinate-policy-rebind-v1"
        and generic.get("original_coordinate_policy") == original_policy
        and generic.get("serialized_coordinate_policy") == serialized_policy
        and generic.get("serialization_rebind_applied") is rebind_applied
        and generic.get("serialization_rebind_sha256")
        == _serialization_rebind_sha256(
            route=binding.contract_route,
            original_policy=str(original_policy),
            serialized_policy=serialized_policy,
            applied=rebind_applied,
        ),
        "generic LUT serialization-rebind provenance differs",
    )
    counters = _object(
        diagnostic.get("session_counters"),
        _SESSION_COUNTER_FIELDS,
        "corrective session counters",
    )
    _require(
        counters
        == {
            "input_decode_count": 1,
            "analysis_grid_build_count": 1,
            "generic_compile_count_for_route": 1,
            "generic_dispatch_count": 1,
            "plane_diagnostic_count": 4,
            "risk_diagnostic_count": 1,
            "production_v2_dispatch_count": 1,
            "output_write_count": 17,
            "output_reopen_count": 17,
        },
        "corrective session counters differ",
    )

    production = _object(
        diagnostic.get("production_v2_reference"),
        _PRODUCTION_REFERENCE_FIELDS,
        "production-V2 reference",
    )
    route_luts = configuration.get("route_luts")
    _require(isinstance(route_luts, dict), "native configuration route LUTs are absent")
    route_lut = route_luts.get(binding.route)
    _require(isinstance(route_lut, dict), "native configuration route LUT is absent")
    _require(
        production.get("lut_whole_file_sha256") == route_lut.get("whole_file_sha256")
        and production.get("lut_payload_sha256") == route_lut.get("payload_sha256")
        and production.get("lut_entry_count") == expected_entry_count,
        "production-V2 LUT binding differs",
    )
    _validate_output_binding(
        production,
        binding=binding,
        path=binding.output_paths[-1],
        width=binding.output_width,
        height=binding.output_height,
        plane_objects=False,
    )

    cells = _sequence(diagnostic.get("cells"), 16, "corrective cells")
    for ordinal, raw in enumerate(cells):
        cell = _object(raw, _CELL_FIELDS, "corrective cell")
        coordinate_index = ordinal // len(ANISOTROPY_CELLS)
        anisotropy_index = ordinal % len(ANISOTROPY_CELLS)
        coordinate = COORDINATE_CELLS[coordinate_index]
        anisotropy = ANISOTROPY_CELLS[anisotropy_index]
        coordinate_id = coordinate["cell_id"]
        anisotropy_id = anisotropy["cell_id"]
        _require(
            cell.get("ordinal") == ordinal
            and cell.get("block_id")
            == f"{binding.contract_route}-{coordinate_id}-{anisotropy_id}"
            and cell.get("coordinate_cell_id") == coordinate_id
            and cell.get("anisotropy_cell_id") == anisotropy_id,
            "corrective cell identity or order differs",
        )
        _validate_output_binding(
            cell,
            binding=binding,
            path=binding.output_paths[ordinal],
            width=binding.output_width,
            height=binding.output_height,
            plane_objects=True,
        )
        planes = cell["planes"]
        assert isinstance(planes, dict)
        _validate_plane(
            planes["y"],
            policy=str(coordinate["luma_coordinate_policy"]),
            anisotropy=int(anisotropy["luma_anisotropy_strength_q12"]),
            expected_samples=binding.output_width * binding.output_height,
        )
        for channel in ("cb", "cr"):
            _validate_plane(
                planes[channel],
                policy=str(coordinate["chroma_coordinate_policy"]),
                anisotropy=int(anisotropy["chroma_anisotropy_strength_q12"]),
                expected_samples=binding.output_width * binding.output_height // 4,
            )

    risk = _object(diagnostic.get("risk_state"), _RISK_FIELDS, "risk-state evidence")
    _require(
        risk.get("analysis_grid_source_step") == step
        and risk.get("analysis_cell_count") == analysis_count
        and risk.get("baseline_analysis_grid_sha256")
        == diagnostic.get("analysis_grid_sha256"),
        "risk-state baseline grid differs",
    )
    risk_cells = _sequence(risk.get("cells"), 30, "risk-state cells")
    for ordinal, raw in enumerate(risk_cells):
        cell = _object(raw, _RISK_CELL_FIELDS, "risk-state cell")
        weight_index = ordinal // len(RISK_THRESHOLD_BANDS)
        band_index = ordinal % len(RISK_THRESHOLD_BANDS)
        zero = _integer(cell.get("risk_zero_count"), "risk-zero count")
        one = _integer(cell.get("risk_one_count"), "risk-one count")
        minimum = _integer(cell.get("risk_proxy_minimum_unorm15"), "risk minimum")
        maximum = _integer(cell.get("risk_proxy_maximum_unorm15"), "risk maximum")
        _require(
            cell.get("ordinal") == ordinal
            and cell.get("cell_id") == f"weight-{weight_index:02d}-band-{band_index:02d}"
            and cell.get("risk_weight_pair") == RISK_WEIGHT_PAIRS[weight_index]
            and cell.get("risk_threshold_band") == RISK_THRESHOLD_BANDS[band_index]
            and zero + one == analysis_count
            and minimum <= maximum <= 32_767
            and cell.get("risk_proxy_value_count") == analysis_count
            and _is_sha256(cell.get("risk_proxy_vector_sha256")),
            "risk-state cell evidence differs",
        )
    return json.loads(canonical_json_bytes(outer))


__all__ = [
    "CorrectiveNativeContractError",
    "CorrectiveNativeRequestBinding",
    "cleanup_corrective_native_outputs",
    "reopen_corrective_output_frame",
    "validate_corrective_native_request",
    "validate_corrective_native_response",
]
